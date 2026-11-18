using System.Text;
using OpenUtau.Core;
using OpenUtau.Core.Util;
using SharpCompress.Archives;
using SharpCompress.Common;
using SharpCompress.Readers;

namespace PawUtau.Engine;

/// <summary>
/// One-shot singer installer: <c>paw-utau-engine --install &lt;file&gt;</c>, as OpenUtau's GUI installs dropped files:
/// a voicebank archive (zip/rar/7z/uar) via <see cref="OpenUtau.Classic.VoicebankInstaller"/>, a Vogen singer (.vogeon) or a
/// dependency package (.oudep, e.g. a vocoder). The target is the OpenUtau data folder (--openutau-dir, default
/// ~/.local/share/OpenUtau), which the engine's Singers/Dependencies link to. Singer type and archive file name encoding are
/// detected unless given. Prints one "installed: &lt;kind&gt; &lt;path&gt;" line per installed folder/file; exit 0 on success.
/// </summary>
static class Install
{
    public static int Run(Options o)
    {
        var file = Path.GetFullPath(o.InstallPath);
        if (!File.Exists(file)) return Fail("no such file " + file);
        // the engine's Singers / Dependencies are links to the OpenUtau folders: make sure they exist so the link is created
        Directory.CreateDirectory(Path.Combine(o.OpenUtauDir, "Singers"));
        Directory.CreateDirectory(Path.Combine(o.OpenUtauDir, "Dependencies"));
        Bootstrap.Init(o);
        try
        {
            foreach (var line in InstallFile(o, file)) Console.Out.WriteLine(line);
            return 0;
        }
        catch (Exception e)
        {
            return Fail(e.InnerException?.Message ?? e.Message);
        }
    }

    /// <summary>The error goes to stdout too ("error: ..."): wrappers may send stderr to a log file.</summary>
    static int Fail(string message)
    {
        Console.Error.WriteLine("paw-utau-engine: install failed: " + message);
        Console.Out.WriteLine("error: " + message);
        return 1;
    }

    static IEnumerable<string> InstallFile(Options o, string file)
    {
        string ext = Path.GetExtension(file).ToLowerInvariant();
        string singers = PathManager.Inst.SingersInstallPath;
        if (ext == OpenUtau.Core.Vogen.VogenSingerInstaller.FileExt)
        {
            var dest = Path.Combine(singers, Path.GetFileName(file));
            if (File.Exists(dest)) throw new IOException($"{Path.GetFileName(file)} is already installed");
            File.Copy(file, dest);
            return new[] { $"installed: vogen {Resolve(o, dest)}" };
        }
        if (ext == PackageManager.OudepExt)
        {
            var before = Snapshot(PathManager.Inst.DependencyPath);
            PackageManager.Inst.InstallFromFileAsync(file).GetAwaiter().GetResult();
            return Changed(PathManager.Inst.DependencyPath, before).Select(d => $"installed: dependency {Resolve(o, d)}").ToArray();
        }

        var archiveEnc = o.ArchiveEncoding.Length > 0 ? Encoding.GetEncoding(o.ArchiveEncoding) : DetectArchiveEncoding(file);
        var (detectedType, yamlEncoding, roots) = Inspect(file, archiveEnc);
        string type = o.SingerType.Length > 0 ? o.SingerType : detectedType;
        var textEnc = o.TextEncoding.Length > 0 ? Encoding.GetEncoding(o.TextEncoding)
            : yamlEncoding != null ? Encoding.GetEncoding(yamlEncoding) : Encoding.GetEncoding("shift_jis");
        var snapshot = Snapshot(singers);
        new OpenUtau.Classic.VoicebankInstaller(singers, (_, _) => { }, archiveEnc, textEnc).Install(file, type);
        // new folders, else the archive's root folders (a reinstall over an existing singer)
        var dirs = Changed(singers, snapshot).ToList();
        if (dirs.Count == 0)
            dirs = roots.Select(r => Path.Combine(singers, r)).Where(Directory.Exists).ToList();
        if (dirs.Count == 0) dirs.Add(Path.Combine(singers, Path.GetFileNameWithoutExtension(file).Trim()));
        return dirs.Select(d => $"installed: {type} {Resolve(o, d)}").ToArray();
    }

    /// <summary>Archive file names: UTF-8 unless that decoding produces replacement characters (old Japanese zips are
    /// Shift_JIS without the UTF-8 flag).</summary>
    public static Encoding DetectArchiveEncoding(string file)
    {
        try
        {
            using var a = ArchiveFactory.OpenArchive(file, new ReaderOptions { ArchiveEncoding = new ArchiveEncoding { Forced = Encoding.UTF8 } });
            if (a.Entries.Any(e => (e.Key ?? "").Contains('�'))) return Encoding.GetEncoding("shift_jis");
        }
        catch (Exception e) when (e is not IOException) { }
        return Encoding.UTF8;
    }

    /// <summary>Singer type from the archive's contents (character.yaml singer_type, a DiffSinger dsconfig.yaml, an ENUNU
    /// enuconfig.yaml; else classic), character.yaml's text_file_encoding, and the root folder names.</summary>
    public static (string Type, string? TextEncoding, List<string> Roots) Inspect(string file, Encoding archiveEnc)
    {
        using var a = ArchiveFactory.OpenArchive(file, new ReaderOptions { ArchiveEncoding = new ArchiveEncoding { Forced = archiveEnc } });
        if (a.Entries.Any(e => e.IsEncrypted)) throw new InvalidOperationException("encrypted archives are not supported");
        var keys = a.Entries.Where(e => !e.IsDirectory).Select(e => (e.Key ?? "").Replace('\\', '/')).ToList();
        string? type = null, enc = null;
        var yaml = a.Entries.Where(e => !e.IsDirectory && Path.GetFileName((e.Key ?? "").Replace('\\', '/')) == "character.yaml")
            .OrderBy(e => (e.Key ?? "").Count(c => c == '/' || c == '\\')).FirstOrDefault();
        if (yaml != null)
        {
            using var s = yaml.OpenEntryStream();
            using var r = new StreamReader(s, Encoding.UTF8);
            foreach (var line in r.ReadToEnd().Split('\n'))
            {
                var t = line.Trim().TrimStart('﻿');
                if (t.StartsWith("singer_type:")) type = t["singer_type:".Length..].Trim().Trim('"', '\'');
                if (t.StartsWith("text_file_encoding:")) enc = t["text_file_encoding:".Length..].Trim().Trim('"', '\'');
            }
        }
        if (string.IsNullOrEmpty(type))
            type = keys.Any(k => Path.GetFileName(k) == "dsconfig.yaml") ? "diffsinger"
                : keys.Any(k => Path.GetFileName(k) == "enuconfig.yaml") ? "enunu"
                : "classic";
        var roots = keys.Where(k => k.Contains('/')).Select(k => k[..k.IndexOf('/')]).Distinct().ToList();
        if (!string.IsNullOrEmpty(enc)) { try { Encoding.GetEncoding(enc); } catch { enc = null; } }
        return (type!, string.IsNullOrEmpty(enc) ? null : enc, roots);
    }

    static Dictionary<string, DateTime> Snapshot(string dir) =>
        Directory.Exists(dir) ? Directory.GetDirectories(dir).ToDictionary(d => d, Directory.GetLastWriteTimeUtc) : new();

    static IEnumerable<string> Changed(string dir, Dictionary<string, DateTime> before) =>
        Directory.Exists(dir) ? Directory.GetDirectories(dir).Where(d => !before.ContainsKey(d)) : Enumerable.Empty<string>();

    /// <summary>Report the real location (inside the OpenUtau folder), not the engine's link.</summary>
    static string Resolve(Options o, string path)
    {
        foreach (var d in new[] { "Singers", "Dependencies" })
        {
            var link = Path.Combine(o.DataDir, d);
            if (path.StartsWith(link + Path.DirectorySeparatorChar))
                return Path.Combine(o.OpenUtauDir, d) + path[link.Length..];
        }
        return path;
    }
}
