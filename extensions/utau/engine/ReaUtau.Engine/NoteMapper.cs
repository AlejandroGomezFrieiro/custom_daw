using OpenUtau.Core.Ustx;
using ReaUtau.Protocol;
using Log = Serilog.Log;
using PitchPoint = OpenUtau.Core.Ustx.PitchPoint;

namespace ReaUtau.Engine;

/// <summary>NoteMsg (+ type-15 payload) -> UNote. Mapping table: docs/protocol.md section 6.2.</summary>
static class NoteMapper
{
    /// <param name="keyShift">track key shift in semitones (added to the tone)</param>
    public static UNote Build(UProject project, UTrack track, NoteMsg m, int keyShift = 0)
    {
        var n = project.CreateNote(Math.Clamp(m.Tone + keyShift, 0, 127), m.PosTick, Math.Max(1, m.DurTick));
        if (!NotePayload.TryDecode(m.Payload, out var p))
        {
            Log.Warning("note {Id}: undecodable payload ({Len} bytes), using defaults", m.Id, m.Payload.Length);
            n.lyric = "a";
            return n;
        }
        n.lyric = p.Lyric;
        n.tuning = p.Tuning;
        n.PhonemizerOverride = p.PhonemizerOverride.Length > 0 ? p.PhonemizerOverride : null;
        if (p.HasPitch && p.Pitch.Count > 0)
        {
            n.pitch = new UPitch { snapFirst = p.SnapFirst };
            foreach (var pt in p.Pitch)
                n.pitch.data.Add(new PitchPoint(pt.XMs, pt.YDeci, (PitchPointShape)Math.Min(pt.Shape, (byte)4)));
            n.pitch.data.Sort();
        }
        else if (p.HasPitch) n.pitch.snapFirst = p.SnapFirst;
        if (p.HasVibrato)
        {
            var v = p.Vibrato;
            n.vibrato.length = v.Length; n.vibrato.period = v.Period; n.vibrato.depth = v.Depth;
            n.vibrato.@in = v.In; n.vibrato.@out = v.Out; n.vibrato.shift = v.Shift; n.vibrato.drift = v.Drift; n.vibrato.volLink = v.VolLink;
        }
        foreach (var o in p.PhonemeOverrides)
        {
            var uo = new UPhonemeOverride { index = (int)o.Index };
            if ((o.Mask & OverrideMask.Phoneme) != 0) uo.phoneme = o.Phoneme;
            if ((o.Mask & OverrideMask.Offset) != 0) uo.offset = o.Offset;
            if ((o.Mask & OverrideMask.Preutter) != 0) uo.preutterDelta = o.PreutterDelta;
            if ((o.Mask & OverrideMask.Overlap) != 0) uo.overlapDelta = o.OverlapDelta;
            if ((o.Mask & OverrideMask.Attack) != 0) uo.attackTimeDelta = o.AttackTimeDelta;
            if ((o.Mask & OverrideMask.Release) != 0) uo.releaseTimeDelta = o.ReleaseTimeDelta;
            if (!uo.IsEmpty) n.phonemeOverrides.Add(uo);
        }
        foreach (var e in p.Expressions)
        {
            string abbr = e.Abbr.ToLowerInvariant();
            if (!track.TryGetExpDescriptor(project, abbr, out var desc)) continue;
            // index -1 = whole note: phoneme indexes are unknown before phonemization, so cover the first ones (extra indexes are ignored).
            int lo = e.Index < 0 ? 0 : e.Index, hi = e.Index < 0 ? 9 : e.Index;
            for (int i = lo; i <= hi; i++)
                n.phonemeExpressions.Add(new UExpression(desc) { index = i, value = e.Value });
        }
        ApplyLyricSyntax(project, track, n);
        return n;
    }

    /// Lyric syntax (Phase 5 A7), SynthV style:
    /// <c>br</c> / <c>breath</c> / <c>息</c> = a breath: DiffSinger sings its breath phoneme AP; a classic bank uses its own
    /// "br" or "息" sample when it has one. A trailing <c>'</c> = emphasis: the mark is dropped and the note gets a stronger
    /// consonant (velocity 160 on its first phoneme) and +15 % volume, unless the note sets those itself.
    public static void ApplyLyricSyntax(UProject project, UTrack track, UNote n)
    {
        var lyric = n.lyric?.Trim() ?? "";
        if (lyric == "br" || lyric == "breath" || lyric == "息")
        {
            var singer = track.Singer;
            if (singer?.SingerType == USingerType.DiffSinger) n.lyric = "AP";
            else if (singer != null)
            {
                if (singer.TryGetMappedOto("br", n.tone, out _)) n.lyric = "br";
                else if (singer.TryGetMappedOto("息", n.tone, out _)) n.lyric = "息";
            }
            return;
        }
        if (lyric.Length > 1 && lyric.EndsWith('\''))
        {
            n.lyric = lyric.TrimEnd('\'');
            void Add(string abbr, int lo, int hi, float value)
            {
                if (n.phonemeExpressions.Any(x => x.abbr == abbr)) return;
                if (!track.TryGetExpDescriptor(project, abbr, out var desc)) return;
                for (int i = lo; i <= hi; i++) n.phonemeExpressions.Add(new UExpression(desc) { index = i, value = value });
            }
            Add(OpenUtau.Core.Format.Ustx.VEL, 0, 0, 160);
            Add(OpenUtau.Core.Format.Ustx.VOL, 0, 9, 115);
        }
    }
}
