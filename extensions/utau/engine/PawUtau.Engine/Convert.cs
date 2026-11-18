using System.Globalization;
using System.Text;
using OpenUtau.Core;
using OpenUtau.Core.Format;
using OpenUtau.Core.Ustx;

namespace PawUtau.Engine;

/// <summary>
/// One-shot converter: <c>paw-utau-engine --convert &lt;file&gt; --out &lt;file.lua&gt;</c>. Any project OpenUtau can read
/// (.ustx, .ust, .vsqx, .mid, .svp, MusicXML, ...) is loaded with OpenUtau's own format code and written as a plain Lua
/// table (`return { ... }`) that the extension (lua/utau/import.lua) turns into vocal tracks, clips, notes, payloads and curves.
/// Ticks are OpenUtau ticks (480 per quarter note); part positions are absolute, note positions part-relative.
/// </summary>
static class Convert
{
    public static int Run(Options o)
    {
        Bootstrap.Init(o);
        UProject? project = null;
        Exception? error = null;
        Bootstrap.Pump.Invoke(() =>
        {
            try { project = Formats.ReadProject(new[] { o.ConvertPath }); }
            catch (Exception e) { error = e; }
        });
        if (project == null)
        {
            Console.Error.WriteLine("paw-utau-engine: cannot read " + o.ConvertPath + (error != null ? ": " + error.Message : ""));
            return 1;
        }
        var sb = new StringBuilder();
        Write(sb, project, o.ConvertPath);
        File.WriteAllText(o.OutPath, sb.ToString(), new UTF8Encoding(false));
        return 0;
    }

    static string S(string? s)
    {
        var sb = new StringBuilder("\"");
        foreach (char c in s ?? "")
        {
            switch (c)
            {
                case '\\': sb.Append("\\\\"); break;
                case '"': sb.Append("\\\""); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                default:
                    if (c < 0x20) sb.Append('\\').Append(((int)c).ToString("000")); else sb.Append(c);
                    break;
            }
        }
        return sb.Append('"').ToString();
    }

    static string N(double v) => double.IsFinite(v) ? v.ToString("R", CultureInfo.InvariantCulture) : "0";

    static void Write(StringBuilder sb, UProject p, string source)
    {
        sb.Append("return {\n  version = 1, source = ").Append(S(source)).Append(", resolution = ").Append(p.resolution).Append(",\n");
        sb.Append("  tempos = {");
        foreach (var t in p.tempos) sb.Append("{pos=").Append(t.position).Append(",bpm=").Append(N(t.bpm)).Append("},");
        sb.Append("},\n  timesigs = {");
        foreach (var t in p.timeSignatures)
            sb.Append("{bar=").Append(t.barPosition).Append(",num=").Append(t.beatPerBar).Append(",den=").Append(t.beatUnit).Append("},");
        sb.Append("},\n  tracks = {\n");
        for (int ti = 0; ti < p.tracks.Count; ti++)
        {
            var tr = p.tracks[ti];
            sb.Append("    { name = ").Append(S(tr.TrackName)).Append(", singer = ").Append(S(tr.Singer?.Id ?? ""))
              .Append(", phonemizer = ").Append(S(tr.Phonemizer?.GetType().FullName ?? ""))
              .Append(", renderer = ").Append(S(tr.RendererSettings?.renderer ?? ""))
              .Append(", mute = ").Append(tr.Mute ? "true" : "false").Append(",\n      parts = {\n");
            foreach (var part in p.parts.OfType<UVoicePart>().Where(x => x.trackNo == ti))
            {
                sb.Append("        { name = ").Append(S(part.name)).Append(", pos = ").Append(part.position)
                  .Append(", dur = ").Append(part.Duration).Append(",\n          notes = {\n");
                foreach (var n in part.notes) WriteNote(sb, n);
                sb.Append("          },\n          curves = {\n");
                foreach (var c in part.curves)
                {
                    if (c.xs.Count == 0) continue;
                    sb.Append("            { abbr = ").Append(S(c.abbr)).Append(", xs = {").Append(string.Join(",", c.xs))
                      .Append("}, ys = {").Append(string.Join(",", c.ys)).Append("} },\n");
                }
                sb.Append("          },\n        },\n");
            }
            sb.Append("      },\n    },\n");
        }
        sb.Append("  },\n}\n");
    }

    static void WriteNote(StringBuilder sb, UNote n)
    {
        sb.Append("            { pos = ").Append(n.position).Append(", dur = ").Append(n.duration).Append(", tone = ").Append(n.tone)
          .Append(", lyric = ").Append(S(n.lyric));
        if (n.tuning != 0) sb.Append(", tu = ").Append(n.tuning);
        if (!string.IsNullOrEmpty(n.PhonemizerOverride)) sb.Append(", po = ").Append(S(n.PhonemizerOverride));
        var v = n.vibrato;
        if (v != null && v.length > 0)
            sb.Append(", vb = {").Append(string.Join(",", new[] { v.length, v.period, v.depth, v.@in, v.@out, v.shift, v.drift, v.volLink }
                .Select(x => N(x)))).Append('}');
        if (n.pitch != null && n.pitch.data.Count > 0)
        {
            sb.Append(", pp = { snap = ").Append(n.pitch.snapFirst ? "true" : "false").Append(", pts = {");
            foreach (var pt in n.pitch.data) sb.Append('{').Append(N(pt.X)).Append(',').Append(N(pt.Y)).Append(',').Append((int)pt.shape).Append("},");
            sb.Append("} }");
        }
        // per-phoneme expressions: one value over every index -> a whole-note expression (index -1)
        var exps = n.phonemeExpressions.GroupBy(e => e.abbr).ToList();
        if (exps.Count > 0)
        {
            sb.Append(", ex = {");
            foreach (var g in exps)
            {
                var vals = g.Select(e => e.value).Distinct().ToList();
                if (vals.Count == 1) sb.Append("{").Append(S(g.Key)).Append(',').Append(N(vals[0])).Append(",-1},");
                else foreach (var e in g) sb.Append("{").Append(S(g.Key)).Append(',').Append(N(e.value)).Append(',').Append(e.index).Append("},");
            }
            sb.Append('}');
        }
        if (n.phonemeOverrides.Count > 0)
        {
            sb.Append(", ph = {");
            foreach (var o in n.phonemeOverrides)
            {
                sb.Append("{index=").Append(o.index);
                if (o.phoneme != null) sb.Append(",phoneme=").Append(S(o.phoneme));
                if (o.offset.HasValue) sb.Append(",offset=").Append(o.offset.Value);
                if (o.preutterDelta.HasValue) sb.Append(",pre=").Append(N(o.preutterDelta.Value));
                if (o.overlapDelta.HasValue) sb.Append(",ovl=").Append(N(o.overlapDelta.Value));
                if (o.attackTimeDelta.HasValue) sb.Append(",atk=").Append(N(o.attackTimeDelta.Value));
                if (o.releaseTimeDelta.HasValue) sb.Append(",rel=").Append(N(o.releaseTimeDelta.Value));
                sb.Append("},");
            }
            sb.Append('}');
        }
        sb.Append(" },\n");
    }
}
