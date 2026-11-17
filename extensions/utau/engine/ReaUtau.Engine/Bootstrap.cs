using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using OpenUtau.Api;
using OpenUtau.Core;
using OpenUtau.Core.Util;
using Serilog.Core;
using Serilog.Events;
using ReaUtau.Protocol;

namespace ReaUtau.Engine;

/// <summary>Serilog sink: stderr always, and protocol Log frames once a connection exists (earlier lines are kept and flushed on attach).</summary>
public sealed class ProtocolLogSink : ILogEventSink
{
    readonly object gate = new();
    readonly List<(byte level, string src, string msg)> early = new();
    Connection? conn;

    public static byte Map(LogEventLevel l) => l switch
    {
        LogEventLevel.Verbose => LogLevel.Trace, LogEventLevel.Debug => LogLevel.Debug, LogEventLevel.Information => LogLevel.Info,
        LogEventLevel.Warning => LogLevel.Warn, _ => LogLevel.Error,
    };

    public void Attach(Connection c)
    {
        lock (gate)
        {
            conn = c;
            foreach (var (level, src, msg) in early) c.Send(new Log { Level = level, Source = src, Message = msg });
            early.Clear();
        }
    }
    public void Detach() { lock (gate) conn = null; }

    public void Emit(LogEvent e)
    {
        string src = e.Properties.TryGetValue("SourceContext", out var sc) ? sc.ToString().Trim('"') : "openutau";
        string msg = e.RenderMessage() + (e.Exception != null ? " " + e.Exception : "");
        byte level = Map(e.Level);
        Console.Error.WriteLine($"[{e.Timestamp:HH:mm:ss.fff} {e.Level.ToString()[..3].ToUpperInvariant()}] {msg}");
        lock (gate)
        {
            if (conn != null) conn.Send(new Log { Level = level, Source = src, Message = msg });
            else if (early.Count < 500) early.Add((level, src, msg));
        }
    }
}

/// <summary>Routes DocManager notifications we care about.</summary>
sealed class NotificationListener : ICmdSubscriber
{
    public event Action<OpenUtau.Core.Ustx.UVoicePart>? Phonemized;
    public event Action<Exception?, string>? ErrorRaised;
    public event Action<double, string>? ProgressChanged;
    public void OnNext(UCommand cmd, bool isUndo)
    {
        if (cmd is PhonemizedNotification pn) Phonemized?.Invoke(pn.part);
        else if (cmd is ErrorMessageNotification en) ErrorRaised?.Invoke(en.e, en.message ?? "");
        else if (cmd is ProgressBarNotification pgn) ProgressChanged?.Invoke(pgn.Progress, pgn.Info ?? "");
    }
}

public static class Bootstrap
{
    public static PumpScheduler Pump { get; private set; } = null!;

    /// <summary>libworldline.so was found. The release asset ships none (GPL-2.0 parts, doc-25): then the WORLDLINE renderers
    /// and OpenUtau's two built-in resamplers (WORLDLINE-R, hifisampler) cannot run, and classic singers use CLASSIC with the
    /// resamplers of the user's OpenUtau folder. True until <see cref="Init"/> finds the file missing.</summary>
    public static bool WorldlineAvailable { get; internal set; } = true;

    /// <summary>The one short message a classic track shows when it has nothing to render with.</summary>
    public const string NoResamplerMessage = "No resampler: add one to OpenUtau's Resamplers folder (README).";

    public static bool IsWorldlineRenderer(string? id) => id != null && id.StartsWith("WORLDLINE", StringComparison.Ordinal);

    /// <summary>OpenUtau's own two resamplers need libworldline; the others are the user's executables.</summary>
    static bool IsUserResampler(OpenUtau.Classic.IResampler r) => r.GetType().Name == "ExeResampler";
    public static ProtocolLogSink Sink { get; } = new();
    internal static NotificationListener Listener { get; } = new();
    public static string OpenUtauVersion => typeof(DocManager).Assembly.GetName().Version?.ToString() ?? "unknown";

    static LogEventLevel ParseLevel(string s) => s switch
    {
        "trace" => LogEventLevel.Verbose, "debug" => LogEventLevel.Debug, "warn" or "warning" => LogEventLevel.Warning,
        "error" => LogEventLevel.Error, _ => LogEventLevel.Information,
    };

    /// <summary>Everything the P0.a spike proved necessary, in the same order.</summary>
    public static void Init(Options o)
    {
        var sw = Stopwatch.StartNew();
        OuInternals.SelfCheck();
        AiPitch.SelfCheck();

        // 1. scratch DataPath: symlinks to the user's banks, OUR prefs.json (Preferences.Save() can never touch the user's OpenUtau prefs).
        PrepareDataDir(o);
        Directory.CreateDirectory(o.CacheDir);
        AiPitch.Directory = Path.Combine(o.CacheDir, "ai-takes");   // AI pitch takes persist across sessions (P4.1)

        // 2. native worldline (OpenUtau.Core P/Invokes "worldline"). The nixpkgs build is ABI-incompatible; ship the submodule's.
        string wl = o.WorldlineLib.Length > 0 ? o.WorldlineLib
            : Environment.GetEnvironmentVariable("REAUTAU_WORLDLINE_LIB") is { Length: > 0 } e ? e
            : Path.Combine(AppContext.BaseDirectory, "libworldline.so");
        NativeLibrary.SetDllImportResolver(typeof(DocManager).Assembly, (name, asm, path) =>
            name == "worldline" && File.Exists(wl) ? NativeLibrary.Load(wl) : IntPtr.Zero);
        WorldlineAvailable = File.Exists(wl);

        // 3. shift_jis oto.ini / character.txt
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

        // 4. paths BEFORE anything touches Preferences (its static ctor reads PrefsFilePath)
        SetPrivate(PathManager.Inst, "DataPath", o.DataDir);
        SetPrivate(PathManager.Inst, "CachePath", o.CacheDir);

        // 5. logging
        var level = new LoggingLevelSwitch(ParseLevel(o.LogLevel));
        Serilog.Log.Logger = new Serilog.LoggerConfiguration().MinimumLevel.ControlledBy(level).WriteTo.Sink(Sink).CreateLogger();
        DocManager.Inst.AddSubscriber(Listener);

        // 6. our own "UI thread", then DocManager
        Pump = new PumpScheduler();
        Pump.Invoke(() =>
        {
            DocManager.Inst.PostOnUIThread = Pump.Post;
            DocManager.Inst.Initialize(Pump.Thread, Pump);   // plugins/phonemizers, PhonemizerRunner, PhraseSourceBuilder
            SingerManager.Inst.SearchAllSingers();
            ImportUserPreferences(o);
            // links, plus loader wrappers for generic Linux binaries. One-shot modes (convert/export/install) never render, and
            // must not rebuild the folders under a daemon that may share the data dir.
            if (!o.OneShot)
                foreach (var d in new[] { "Resamplers", "Wavtools" })
                    ToolMirror.Build(Path.Combine(o.OpenUtauDir, d), Path.Combine(o.DataDir, d));
            if (!o.OneShot) ConfigureWine(o);                                  // before the tool scan: .exe resamplers/wavtools are only listed with Wine
            OpenUtau.Classic.ToolsManager.Inst.Initialize();  // resamplers + wavtools (REQUIRED, else classic tracks have no resampler)
            if (!o.OneShot) WarmUpWine();
            if (!WorldlineAvailable) UseClassicWithUserResamplers();
            Preferences.Default.PreRender = false;            // never pre-render from DocManager notifications; the scheduler drives rendering
            Preferences.Default.UndoLimit = 1;                // the mirror is not user-undoable; keep the undo queue from retaining commands
        });
        Serilog.Log.Information("bootstrap done in {Ms} ms: {N} singers, data={Data} cache={Cache}", sw.ElapsedMilliseconds,
            SingerManager.Inst.Singers.Count, o.DataDir, o.CacheDir);
    }

    /// <summary>
    /// Take the singer-related choices the user made in their own OpenUtau (per-singer phonemizer, default classic
    /// renderer, Wine path) so a bank behaves here as it does there. Read-only: their prefs.json is never written.
    /// </summary>
    static void ImportUserPreferences(Options o)
    {
        var path = Path.Combine(o.OpenUtauDir, "prefs.json");
        if (!File.Exists(path)) return;
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(path));
            var root = doc.RootElement;
            if (root.TryGetProperty("SingerPhonemizers", out var sp) && sp.ValueKind == System.Text.Json.JsonValueKind.Object)
                foreach (var kv in sp.EnumerateObject())
                    if (kv.Value.ValueKind == System.Text.Json.JsonValueKind.String)
                        Preferences.Default.SingerPhonemizers[kv.Name] = kv.Value.GetString()!;
            if (root.TryGetProperty("DefaultRenderer", out var dr) && dr.ValueKind == System.Text.Json.JsonValueKind.String
                && !string.IsNullOrEmpty(dr.GetString()))
                Preferences.Default.DefaultRenderer = dr.GetString()!;
            if (root.TryGetProperty("DefaultResamplers", out var drs) && drs.ValueKind == System.Text.Json.JsonValueKind.Object
                && drs.TryGetProperty("CLASSIC", out var cr) && cr.ValueKind == System.Text.Json.JsonValueKind.String
                && !string.IsNullOrEmpty(cr.GetString()))
                Preferences.Default.DefaultResamplers["CLASSIC"] = cr.GetString()!;
            if (root.TryGetProperty("WinePath", out var wp) && wp.ValueKind == System.Text.Json.JsonValueKind.String
                && !string.IsNullOrEmpty(wp.GetString()))
                Preferences.Default.WinePath = wp.GetString()!;
        }
        catch (Exception e)
        {
            Serilog.Log.Warning(e, "could not read OpenUtau preferences {Path}", path);
        }
    }

    /// <summary>No libworldline: classic tracks default to CLASSIC with the user's resampler (their own default for CLASSIC from
    /// their prefs when installed, else the first one), never to the renderer that would throw. Without any resampler the
    /// render fails with <see cref="NoResamplerMessage"/>, see RenderScheduler.</summary>
    static void UseClassicWithUserResamplers()
    {
        var prefs = Preferences.Default;
        if (IsWorldlineRenderer(prefs.DefaultRenderer)) prefs.DefaultRenderer = OpenUtau.Core.Render.Renderers.CLASSIC;
        var user = OpenUtau.Classic.ToolsManager.Inst.Resamplers.Where(IsUserResampler).Select(r => r.ToString()!).ToList();
        if (user.Count == 0)
        {
            Serilog.Log.Warning(NoResamplerMessage);
            return;
        }
        string key = OpenUtau.Core.Render.Renderers.CLASSIC;
        if (!prefs.DefaultResamplers.TryGetValue(key, out var cur) || !user.Contains(cur))
            prefs.DefaultResamplers[key] = user[0];
    }

    /// <summary>Wine for Windows resamplers, wavtools and legacy UTAU plugins (OpenUtau's WinePath). EXPERIMENTAL and opt-in
    /// (P3.2 is deferred): resampler calls through Wine still hit OpenUtau's 60 s timeout inside the engine although the same
    /// calls work from a shell (see TRACKER notes). REAUTAU_WINE=&lt;path&gt; or "auto" (wine on PATH) enables it; otherwise
    /// it is off, also when the user's OpenUtau has a WinePath, so no .exe tool that would hang is offered. OpenUtau is
    /// given <see cref="WriteWineRunner"/>'s script instead of wine itself.</summary>
    static void ConfigureWine(Options o)
    {
        var env = Environment.GetEnvironmentVariable("REAUTAU_WINE");
        string wine;
        if (string.IsNullOrEmpty(env) || string.Equals(env, "off", StringComparison.OrdinalIgnoreCase)) wine = "";
        else if (string.Equals(env, "auto", StringComparison.OrdinalIgnoreCase)) wine = FindOnPath("wine") ?? "";
        else wine = env;
        Preferences.Default.WinePath = "";
        if (wine.Length > 0 && File.Exists(wine))
        {
            // no Mono/Gecko installer dialogs and no debug spam when a call has to create the prefix
            if (Environment.GetEnvironmentVariable("WINEDLLOVERRIDES") == null) Environment.SetEnvironmentVariable("WINEDLLOVERRIDES", "mscoree,mshtml=");
            if (Environment.GetEnvironmentVariable("WINEDEBUG") == null) Environment.SetEnvironmentVariable("WINEDEBUG", "-all");
            Preferences.Default.WinePath = WriteWineRunner(o, wine);
        }
        Serilog.Log.Information("wine: {Wine}", Preferences.Default.WinePath.Length > 0 ? wine + " (experimental)" : "off (set REAUTAU_WINE to try Windows resamplers)");
    }

    /// <summary>
    /// A wrapper OpenUtau runs instead of wine. Wine starts wineserver and its services (winedevice.exe) from whichever call
    /// comes first, and they inherit that call's stdout/stderr: OpenUtau's ProcessRunner then waits for an EOF that never
    /// comes and kills the resampler after 60 s. The wrapper starts them itself, detached from any pipe, once per 5 minutes
    /// (wineserver stays 10 minutes after the last client) and under a lock so parallel resampler threads wait for it.
    /// </summary>
    static string WriteWineRunner(Options o, string wine)
    {
        var path = Path.Combine(o.DataDir, "wine-run");
        var server = Path.Combine(Path.GetDirectoryName(wine) ?? "", "wineserver");
        string q(string s) => "'" + s.Replace("'", "'\\''") + "'";
        File.WriteAllText(path, $$"""
            #!/bin/sh
            # ReaUtau: runs Windows resamplers/wavtools/plugins for OpenUtau (generated by reautau-engine)
            WINE={{q(wine)}}
            SERVER={{q(server)}}
            KEY=$(printf '%s' "${WINEPREFIX:-$HOME/.wine}" | cksum | cut -d' ' -f1)
            DIR={{q(o.DataDir)}}
            STAMP="$DIR/wine-ready-$KEY"
            (
              command -v flock >/dev/null 2>&1 && flock 9
              now=$(date +%s)
              last=$(stat -c %Y "$STAMP" 2>/dev/null || echo 0)
              if [ $((now - last)) -gt 300 ]; then
                [ -x "$SERVER" ] && "$SERVER" -p600 </dev/null >/dev/null 2>&1
                "$WINE" cmd /c exit </dev/null >/dev/null 2>&1
              fi
              touch "$STAMP"
            ) 9>"$DIR/wine-ready.lock"
            exec "$WINE" "$@"

            """);
        File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        foreach (var stale in Directory.EnumerateFiles(o.DataDir, "wine-ready-*")) File.Delete(stale);   // re-check on each start
        return path;
    }

    /// <summary>Start Wine in the background when a Windows tool is installed, so the first render does not pay for it.</summary>
    static void WarmUpWine()
    {
        var runner = Preferences.Default.WinePath;
        if (runner.Length == 0) return;
        var tm = OpenUtau.Classic.ToolsManager.Inst;
        bool any = tm.Resamplers.Select(r => r.ToString()).Concat(tm.Wavtools.Select(w => w.ToString()))
            .Any(n => n.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || n.EndsWith(".bat", StringComparison.OrdinalIgnoreCase));
        if (!any) return;
        Task.Run(() =>
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            try
            {
                var psi = new System.Diagnostics.ProcessStartInfo(runner) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
                psi.ArgumentList.Add("cmd"); psi.ArgumentList.Add("/c"); psi.ArgumentList.Add("exit");
                using var p = System.Diagnostics.Process.Start(psi)!;
                var outTask = p.StandardOutput.ReadToEndAsync();
                var errTask = p.StandardError.ReadToEndAsync();
                bool done = p.WaitForExit(180000);
                Serilog.Log.Information("wine warm-up {State} in {Ms} ms", done ? "done" : "timed out", sw.ElapsedMilliseconds);
            }
            catch (Exception e) { Serilog.Log.Warning(e, "wine warm-up failed ({Wine})", runner); }
        });
    }


    static string? FindOnPath(string exe)
    {
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(':', StringSplitOptions.RemoveEmptyEntries))
        {
            var p = Path.Combine(dir, exe);
            if (File.Exists(p)) return p;
        }
        return null;
    }

    static void PrepareDataDir(Options o)
    {
        Directory.CreateDirectory(o.DataDir);
        foreach (var d in new[] { "Singers", "Dependencies" })
        {
            var src = Path.Combine(o.OpenUtauDir, d);
            var dst = Path.Combine(o.DataDir, d);
            if (Directory.Exists(src) && !Directory.Exists(dst) && !File.Exists(dst))
                Directory.CreateSymbolicLink(dst, src);
        }
        // the user's phonemizer plugins (DLLs) and legacy plugin descriptors, as links: OpenUtau deletes an old builtin DLL inside
        // Plugins at startup, so the user's folder itself is never handed over (its own builtin copy is skipped)
        ToolMirror.Build(Path.Combine(o.OpenUtauDir, "Plugins"), Path.Combine(o.DataDir, "Plugins"),
            name => !name.Equals("OpenUtau.Plugin.Builtin.dll", StringComparison.OrdinalIgnoreCase));
        var prefs = Path.Combine(o.DataDir, "prefs.json");
        if (!File.Exists(prefs))
            File.WriteAllText(prefs, "{\n \"DefaultRenderer\": \"WORLDLINE-R\",\n \"NumRenderThreads\": 4,\n \"OnnxRunner\": \"CPU\",\n \"DiffSingerSteps\": 20,\n \"DiffSingerTensorCache\": true,\n \"PreRender\": false\n}\n");
    }

    static void SetPrivate(object o, string prop, object value) =>
        o.GetType().GetProperty(prop, BindingFlags.Public | BindingFlags.Instance)!.GetSetMethod(true)!.Invoke(o, new[] { value });
}
