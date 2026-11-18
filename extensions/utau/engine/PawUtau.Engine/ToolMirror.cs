using System.Runtime.InteropServices;

namespace PawUtau.Engine;

/// <summary>
/// The engine's Resamplers/ and Wavtools/ folders. Every entry of the user's OpenUtau folder is linked, except a
/// generic-Linux ELF executable whose program interpreter does not exist (NixOS without nix-ld): it gets a /bin/sh wrapper
/// of the same name that runs it through the glibc loader this engine runs on, with the library folders of this process.
/// The name stays identical, so .ustx resampler references keep working. The user's files are never written.
/// </summary>
static class ToolMirror
{
    const string Marker = "# paw-utau-loader-wrapper";

    public static void Build(string src, string dst, Func<string, bool>? include = null)
    {
        // an older data dir linked the whole folder: replace the link (never its target) with our own folder
        var info = new DirectoryInfo(dst);
        if (info.Exists && info.LinkTarget != null) info.Delete();
        else if (!info.Exists && File.Exists(dst)) File.Delete(dst);
        Directory.CreateDirectory(dst);
        foreach (var e in new DirectoryInfo(dst).EnumerateFileSystemInfos())
        {
            // only remove what we made: links (the target is untouched) and our wrappers
            if (e.LinkTarget != null) { if (e is DirectoryInfo d) d.Delete(); else e.Delete(); }
            else if (e is FileInfo f && IsWrapper(f.FullName)) f.Delete();
        }
        if (!Directory.Exists(src)) return;
        foreach (var e in new DirectoryInfo(src).EnumerateFileSystemInfos())
        {
            if (include != null && !include(e.Name)) continue;
            var target = Path.Combine(dst, e.Name);
            if (File.Exists(target) || Directory.Exists(target)) continue;   // a user file of ours with that name: keep it
            if (e is FileInfo f && NeedsLoader(f.FullName) && Loader() is { } ld)
            {
                File.WriteAllText(target, "#!/bin/sh\n" + Marker + " for " + f.FullName + "\n"
                    + $"exec '{ld.Interp}' --library-path '{ld.LibraryPath}' '{f.FullName.Replace("'", "'\\''")}' \"$@\"\n");
                File.SetUnixFileMode(target, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute
                    | UnixFileMode.GroupRead | UnixFileMode.GroupExecute | UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
                Serilog.Log.Information("tool {Name}: generic Linux binary, run through {Loader}", e.Name, ld.Interp);
                continue;
            }
            if (e is DirectoryInfo) Directory.CreateSymbolicLink(target, e.FullName);
            else File.CreateSymbolicLink(target, e.FullName);
        }
    }

    static bool IsWrapper(string path)
    {
        try
        {
            using var r = new StreamReader(path);
            r.ReadLine();
            return r.ReadLine()?.StartsWith(Marker) == true;
        }
        catch { return false; }
    }

    /// <summary>True for an ELF executable whose PT_INTERP loader is missing on this system, or is NixOS's stub-ld (which
    /// only prints "NixOS cannot run dynamically linked executables"; with nix-ld installed the link points elsewhere).</summary>
    public static bool NeedsLoader(string path)
    {
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Linux)) return false;
        var interp = Interpreter(path);
        if (interp == null) return false;
        if (!File.Exists(interp)) return true;
        try
        {
            var real = File.ResolveLinkTarget(interp, returnFinalTarget: true)?.FullName ?? interp;
            return real.Contains("-stub-ld");
        }
        catch { return false; }
    }

    /// <summary>The PT_INTERP path of a 64-bit little-endian ELF file, or null.</summary>
    public static string? Interpreter(string path)
    {
        try
        {
            using var fs = File.OpenRead(path);
            using var br = new BinaryReader(fs);
            var ident = br.ReadBytes(16);
            if (ident.Length < 16 || ident[0] != 0x7f || ident[1] != 'E' || ident[2] != 'L' || ident[3] != 'F') return null;
            if (ident[4] != 2 || ident[5] != 1) return null;   // ELFCLASS64, little-endian
            fs.Position = 0x20; long phoff = br.ReadInt64();
            fs.Position = 0x36; int phentsize = br.ReadUInt16(); int phnum = br.ReadUInt16();
            for (int i = 0; i < phnum; i++)
            {
                fs.Position = phoff + (long)i * phentsize;
                uint type = br.ReadUInt32();
                if (type != 3) continue;   // PT_INTERP
                fs.Position = phoff + (long)i * phentsize + 8; long off = br.ReadInt64();
                fs.Position = phoff + (long)i * phentsize + 32; long size = br.ReadInt64();
                fs.Position = off;
                return System.Text.Encoding.ASCII.GetString(br.ReadBytes((int)Math.Min(size, 4096))).TrimEnd('\0');
            }
            return null;
        }
        catch { return null; }
    }

    public sealed record LoaderInfo(string Interp, string LibraryPath);
    static LoaderInfo? loader;
    static bool loaderProbed;

    /// <summary>This process's own glibc loader and the folders of the C/C++ runtime libraries it has loaded.</summary>
    public static LoaderInfo? Loader()
    {
        if (loaderProbed) return loader;
        loaderProbed = true;
        try
        {
            var interp = Interpreter("/proc/self/exe");
            if (interp == null || !File.Exists(interp)) return null;
            var dirs = new List<string> { Path.GetDirectoryName(interp)! };
            foreach (var line in File.ReadLines("/proc/self/maps"))
            {
                int slash = line.IndexOf('/');
                if (slash < 0) continue;
                var file = line[slash..];
                var name = Path.GetFileName(file);
                if (name.StartsWith("libstdc++.so") || name.StartsWith("libgcc_s.so") || name.StartsWith("libm.so") || name.StartsWith("libc.so"))
                {
                    var d = Path.GetDirectoryName(file)!;
                    if (!dirs.Contains(d)) dirs.Add(d);
                }
            }
            loader = new LoaderInfo(interp, string.Join(":", dirs));
        }
        catch (Exception e) { Serilog.Log.Warning(e, "could not find this process's loader"); }
        return loader;
    }
}
