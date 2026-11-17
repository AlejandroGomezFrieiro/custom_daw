using System.Text.Json;
using OpenUtau.Api;
using OpenUtau.Core;
using OpenUtau.Core.Format;
using OpenUtau.Core.Ustx;
using ReaUtau.Protocol;

namespace ReaUtau.Engine;

/// <summary>
/// One-shot exporter: <c>reautau-engine --export &lt;project.json&gt; --out &lt;file.ustx&gt;</c>. The REAPER side writes
/// its vocal tracks as JSON (notes carry the type-15 payload verbatim, base64; curves are knots in OpenUtau units and
/// part-relative ticks); this builds a UProject with the same mapping the live engine uses (NoteMapper, CcShape) and
/// saves it with OpenUtau's own writer, so the project opens in the OpenUtau GUI.
/// </summary>
static class Export
{
    public static int Run(Options o)
    {
        Bootstrap.Init(o);
        JsonDocument doc;
        try { doc = JsonDocument.Parse(File.ReadAllText(o.ExportPath)); }
        catch (Exception e) { Console.Error.WriteLine("reautau-engine: cannot read " + o.ExportPath + ": " + e.Message); return 1; }
        Exception? error = null;
        Bootstrap.Pump.Invoke(() =>
        {
            try
            {
                var project = Build(doc.RootElement);
                foreach (var written in Save(project, o.OutPath)) Console.Out.WriteLine(written);
            }
            catch (Exception e) { error = e; }
        });
        if (error != null) { Console.Error.WriteLine("reautau-engine: export failed: " + error); return 1; }
        return 0;
    }

    /// <summary>Write the project in the format of the output extension: .ustx (default), .mid (MIDI with lyrics, one track
    /// per voice part) or .ust (UTAU: one file per voice part; the first gets the requested name, the others "-2", "-3"...).
    /// Returns the files written.</summary>
    public static List<string> Save(UProject project, string path)
    {
        var ext = Path.GetExtension(path).ToLowerInvariant();
        if (ext is ".mid" or ".midi")
        {
            OpenUtau.Core.Format.MidiWriter.Save(path, project);
            return new() { path };
        }
        if (ext == ".ust")
        {
            var parts = project.parts.OfType<UVoicePart>().Where(p => p.notes.Count > 0)
                .OrderBy(p => p.trackNo).ThenBy(p => p.position).ToList();
            if (parts.Count == 0) throw new InvalidOperationException("no notes to export");
            var files = new List<string>();
            string stem = Path.Combine(Path.GetDirectoryName(path) ?? ".", Path.GetFileNameWithoutExtension(path));
            for (int i = 0; i < parts.Count; i++)
            {
                string file = i == 0 ? path : $"{stem}-{i + 1}.ust";
                OpenUtau.Classic.Ust.SavePart(project, parts[i], file);
                files.Add(file);
            }
            return files;
        }
        Ustx.Save(path, project);
        return new() { path };
    }

    static string Str(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
    static int Int(JsonElement e, string name, int def = 0) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? (int)Math.Round(v.GetDouble()) : def;
    static double Num(JsonElement e, string name, double def = 0) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : def;
    static IEnumerable<JsonElement> Arr(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Array ? v.EnumerateArray() : Enumerable.Empty<JsonElement>();

    static UProject Build(JsonElement root)
    {
        var project = Ustx.Create();
        var tempos = Arr(root, "tempos").Select(t => new UTempo(Int(t, "pos"), Num(t, "bpm", 120))).ToList();
        if (tempos.Count > 0) project.tempos = tempos;
        var sigs = Arr(root, "timesigs").Select(t => new UTimeSignature(Int(t, "bar"), Int(t, "num", 4), Int(t, "den", 4))).ToList();
        if (sigs.Count > 0) project.timeSignatures = sigs;
        project.tracks.Clear();
        uint nextId = 1;
        foreach (var jt in Arr(root, "tracks"))
        {
            var track = new UTrack(project) { TrackName = Str(jt, "name"), TrackNo = project.tracks.Count };
            string singerId = Str(jt, "singer");
            if (singerId.Length > 0)
                track.Singer = SingerManager.Inst.Singers.TryGetValue(singerId, out var s) ? s : USinger.CreateMissing(singerId);
            var factory = Str(jt, "phonemizer") is { Length: > 0 } ph ? PhonemizerFactory.Get(ph) : null;
            factory ??= ProjectMirror.DefaultPhonemizerFor(track.Singer);
            if (factory != null) track.Phonemizer = factory.Create();
            track.RendererSettings = new URenderSettings { renderer = Str(jt, "renderer") is { Length: > 0 } r ? r : null };
            track.Mute = jt.TryGetProperty("mute", out var m) && m.ValueKind == JsonValueKind.True;
            project.tracks.Add(track);
            // renderer curves (energy, voice-colour blends ...) must be known to the project to be saved
            try
            {
                track.RendererSettings.Validate(track);
                var rend = track.RendererSettings.Renderer;
                if (rend != null && track.Singer is { Found: true })
                    foreach (var d in rend.GetSuggestedExpressions(track.Singer, track.RendererSettings) ?? Array.Empty<UExpressionDescriptor>())
                        if (d != null && !project.expressions.ContainsKey(d.abbr)) project.RegisterExpression(d.Clone());
            }
            catch { /* singer not installed here: standard expressions only */ }

            foreach (var jp in Arr(jt, "parts"))
            {
                var part = new UVoicePart { name = Str(jp, "name"), trackNo = track.TrackNo, position = Int(jp, "pos") };
                int dur = Math.Max(1, Int(jp, "dur"));
                foreach (var jn in Arr(jp, "notes"))
                {
                    byte[] payload = Str(jn, "payload") is { Length: > 0 } b64 ? Convert64(b64) : Array.Empty<byte>();
                    var msg = new NoteMsg { Id = nextId++, PosTick = Int(jn, "pos"), DurTick = Math.Max(1, Int(jn, "dur")), Tone = Int(jn, "tone", 60), Payload = payload };
                    var note = NoteMapper.Build(project, track, msg);
                    part.notes.Add(note);
                    dur = Math.Max(dur, msg.PosTick + msg.DurTick);
                }
                part.Duration = dur;
                foreach (var jc in Arr(jp, "curves"))
                {
                    string abbr = Str(jc, "abbr").ToLowerInvariant();
                    if (!track.TryGetExpDescriptor(project, abbr, out var desc)) continue;
                    var knots = Arr(jc, "knots").Select(k =>
                    {
                        var a = k.EnumerateArray().ToArray();
                        return new Knot { Tick = a[0].GetDouble(), Value = a[1].GetDouble(), Shape = (byte)a[2].GetInt32(), Tension = (float)a[3].GetDouble() };
                    }).ToArray();
                    if (knots.Length == 0) continue;
                    var (xs, ys) = CcShape.SampleKnotsOnGrid(knots, dur);
                    var curve = new UCurve(desc);
                    // drop runs at the default value: OpenUtau stores sparse curves
                    for (int i = 0; i < xs.Length; i++)
                    {
                        bool keep = ys[i] != (int)desc.defaultValue || i == 0 || i == xs.Length - 1
                            || ys[i - 1] != (int)desc.defaultValue || ys[i + 1] != (int)desc.defaultValue;
                        if (keep) { curve.xs.Add(xs[i]); curve.ys.Add(ys[i]); }
                    }
                    part.curves.Add(curve);
                }
                project.parts.Add(part);
            }
        }
        project.ValidateFull();
        return project;
    }

    static byte[] Convert64(string s)
    {
        s = s.Replace('-', '+').Replace('_', '/');
        switch (s.Length % 4) { case 2: s += "=="; break; case 3: s += "="; break; }
        return System.Convert.FromBase64String(s);
    }
}
