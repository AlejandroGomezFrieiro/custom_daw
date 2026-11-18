namespace PawUtau.Engine;

/// <summary>Command line: paw-utau-engine --socket &lt;path&gt; [--data-dir ..] [--cache-dir ..] [--log-level ..]</summary>
public sealed class Options
{
    public string SocketPath = "";
    public string DataDir = "";
    public string CacheDir = "";
    public string OpenUtauDir = "";   // source of the Singers/Dependencies/Resamplers symlinks
    public string LogLevel = "info";
    public string WorldlineLib = "";
    public string ConvertPath = "";   // --convert: one-shot project import (no socket)
    public string OutPath = "";
    public string ExportPath = "";    // --export: one-shot .ustx writer from the extension's JSON description
    public string InstallPath = "";   // --install: one-shot singer / dependency installer (archive, .vogeon, .oudep)
    public string SingerType = "";    // --singer-type: classic | diffsinger | enunu | ... (default: detected)
    public string ArchiveEncoding = ""; // --archive-encoding: file name encoding of the archive (default: detected)
    public string TextEncoding = "";  // --text-encoding: character.txt / oto.ini encoding (default: character.yaml, else shift_jis)
    public string InstallTo = "";     // --install-to: OpenUtau folder to install into; wins over --openutau-dir/--data-dir in any order
    public bool OneShot => ConvertPath.Length > 0 || ExportPath.Length > 0 || InstallPath.Length > 0;

    public static Options Parse(string[] args)
    {
        var o = new Options();
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i];
            string Next() => i + 1 < args.Length ? args[++i] : throw new ArgumentException($"missing value for {a}");
            switch (a)
            {
                case "--socket": o.SocketPath = Next(); break;
                case "--data-dir": o.DataDir = Next(); break;
                case "--cache-dir": o.CacheDir = Next(); break;
                case "--openutau-dir": o.OpenUtauDir = Next(); break;
                case "--log-level": o.LogLevel = Next().ToLowerInvariant(); break;
                case "--worldline": o.WorldlineLib = Next(); break;
                case "--convert": o.ConvertPath = Next(); break;
                case "--out": o.OutPath = Next(); break;
                case "--export": o.ExportPath = Next(); break;
                case "--install": o.InstallPath = Next(); break;
                case "--singer-type": o.SingerType = Next(); break;
                case "--archive-encoding": o.ArchiveEncoding = Next(); break;
                case "--text-encoding": o.TextEncoding = Next(); break;
                case "--install-to": o.InstallTo = Next(); break;
                case "-h": case "--help":
                    Console.Error.WriteLine("usage: paw-utau-engine --socket <path> | --convert <project file> --out <file.lua> | --export <json> --out <file.ustx|.ust|.mid> | --install <archive|.vogeon|.oudep> [--singer-type t] [--archive-encoding e] [--text-encoding e]  [--data-dir <dir>] [--cache-dir <dir>] [--openutau-dir <dir>] [--log-level trace|debug|info|warn|error]");
                    Environment.Exit(0); break;
                default: throw new ArgumentException($"unknown argument {a}");
            }
        }
        if (o.ConvertPath.Length > 0 || o.ExportPath.Length > 0) { if (o.OutPath.Length == 0) throw new ArgumentException("--convert / --export need --out"); }
        else if (o.InstallPath.Length == 0 && o.SocketPath.Length == 0) throw new ArgumentException("--socket is required");
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string xdgData = Environment.GetEnvironmentVariable("XDG_DATA_HOME") is { Length: > 0 } d ? d : Path.Combine(home, ".local", "share");
        string xdgCache = Environment.GetEnvironmentVariable("XDG_CACHE_HOME") is { Length: > 0 } c ? c : Path.Combine(home, ".cache");
        // one-shot modes get their own data dir: bootstrap rebuilds the tool folders, which must not happen under a running daemon
        if (o.DataDir.Length == 0) o.DataDir = Path.Combine(xdgData, "paw", "utau", o.OneShot ? "openutau-data-tool" : "openutau-data");
        if (o.CacheDir.Length == 0) o.CacheDir = Path.Combine(xdgCache, "paw", "utau");
        if (o.OpenUtauDir.Length == 0) o.OpenUtauDir = Path.Combine(xdgData, "OpenUtau");
        // an explicit install target beats wrapper scripts that append their own --openutau-dir / --data-dir
        if (o.InstallTo.Length > 0)
        {
            o.OpenUtauDir = Path.GetFullPath(o.InstallTo);
            o.DataDir = Path.Combine(o.OpenUtauDir, ".paw-utau-data");
        }
        return o;
    }
}
