// Per-note payload of REAPER's type-15 notation event (docs/storage-format.md, "Payload schema"). Mirror of
// native/common/notation_payload.{h,cpp}. Map with short string keys in canonical order: v id ly po tu pp vb ph ex, then unknown keys.
using System.Buffers;
using System.Text;
using MessagePack;

namespace ReaUtau.Protocol;

public static class PitchShape { public const byte IO = 0, Linear = 1, In = 2, Out = 3; }
public static class OverrideMask { public const byte Phoneme = 1, Offset = 2, Preutter = 4, Overlap = 8, Attack = 16, Release = 32; }

public sealed class PitchPoint { public float XMs, YDeci; public byte Shape; }
public sealed class Vibrato { public float Length, Period = 175, Depth = 25, In = 10, Out = 10, Shift, Drift, VolLink; }
public sealed class PhonemeOverride
{
    public uint Index; public byte Mask; public string Phoneme = ""; public int Offset;
    public float PreutterDelta, OverlapDelta, AttackTimeDelta, ReleaseTimeDelta;
}
public sealed class Expression { public string Abbr = ""; public float Value; public int Index = -1; }
public sealed class UnknownEntry { public string Key = ""; public byte[] Raw = Array.Empty<byte>(); }

public sealed class NotePayload
{
    public const int CurrentVersion = 1;
    public const int MaxEventBytes = 3500;

    public uint Version = CurrentVersion;
    public uint Id;
    public string Lyric = "";
    public string PhonemizerOverride = "";
    public int Tuning;
    public bool HasPitch, SnapFirst = true;
    public List<PitchPoint> Pitch = new();
    public bool HasVibrato;
    public Vibrato Vibrato = new();
    public List<PhonemeOverride> PhonemeOverrides = new();
    public List<Expression> Expressions = new();
    public List<UnknownEntry> Unknown = new();

    public byte[] Encode()
    {
        var buf = new ArrayBufferWriter<byte>();
        var w = new MessagePackWriter(buf);
        uint entries = 3;
        if (PhonemizerOverride.Length > 0) entries++;
        if (Tuning != 0) entries++;
        if (HasPitch) entries++;
        if (HasVibrato) entries++;
        if (PhonemeOverrides.Count > 0) entries++;
        if (Expressions.Count > 0) entries++;
        entries += (uint)Unknown.Count;
        w.WriteMapHeader((int)entries);
        w.Write("v"); w.Write(Version);
        w.Write("id"); w.Write(Id);
        w.Write("ly"); w.Write(Lyric);
        if (PhonemizerOverride.Length > 0) { w.Write("po"); w.Write(PhonemizerOverride); }
        if (Tuning != 0) { w.Write("tu"); w.Write(Tuning); }
        if (HasPitch)
        {
            w.Write("pp");
            w.WriteArrayHeader(2);
            w.Write(SnapFirst);
            w.WriteArrayHeader(Pitch.Count);
            foreach (var p in Pitch) { w.WriteArrayHeader(3); w.Write(p.XMs); w.Write(p.YDeci); w.Write(p.Shape); }
        }
        if (HasVibrato)
        {
            w.Write("vb");
            w.WriteArrayHeader(8);
            foreach (var f in new[] { Vibrato.Length, Vibrato.Period, Vibrato.Depth, Vibrato.In, Vibrato.Out, Vibrato.Shift, Vibrato.Drift, Vibrato.VolLink }) w.Write(f);
        }
        if (PhonemeOverrides.Count > 0)
        {
            w.Write("ph");
            w.WriteArrayHeader(PhonemeOverrides.Count);
            foreach (var o in PhonemeOverrides)
            {
                w.WriteArrayHeader(8);
                w.Write(o.Index); w.Write(o.Mask); w.Write(o.Phoneme); w.Write(o.Offset);
                w.Write(o.PreutterDelta); w.Write(o.OverlapDelta); w.Write(o.AttackTimeDelta); w.Write(o.ReleaseTimeDelta);
            }
        }
        if (Expressions.Count > 0)
        {
            w.Write("ex");
            w.WriteArrayHeader(Expressions.Count);
            foreach (var e in Expressions) { w.WriteArrayHeader(3); w.Write(e.Abbr); w.Write(e.Value); w.Write(e.Index); }
        }
        foreach (var u in Unknown) { w.Write(u.Key); w.WriteRaw(u.Raw); }
        w.Flush();
        return buf.WrittenSpan.ToArray();
    }

    /// <summary>False on malformed input or version 0. Unknown keys are preserved in <see cref="Unknown"/>.</summary>
    public static bool TryDecode(ReadOnlyMemory<byte> data, out NotePayload payload)
    {
        payload = new NotePayload { Version = 0 };
        try
        {
            var r = new MessagePackReader(data);
            int entries = r.ReadMapHeader();
            for (int i = 0; i < entries; i++)
            {
                string key = r.ReadString() ?? "";
                switch (key)
                {
                    case "v": payload.Version = r.ReadUInt32(); break;
                    case "id": payload.Id = r.ReadUInt32(); break;
                    case "ly": payload.Lyric = r.ReadString() ?? ""; break;
                    case "po": payload.PhonemizerOverride = r.ReadString() ?? ""; break;
                    case "tu": payload.Tuning = r.ReadInt32(); break;
                    case "pp":
                    {
                        int c = r.ReadArrayHeader();
                        if (c < 2) return false;
                        payload.SnapFirst = r.ReadBoolean();
                        int m = r.ReadArrayHeader();
                        for (int k = 0; k < m; k++)
                        {
                            int cc = r.ReadArrayHeader();
                            if (cc < 3) return false;
                            var p = new PitchPoint { XMs = r.ReadSingle(), YDeci = r.ReadSingle(), Shape = r.ReadByte() };
                            for (int q = 3; q < cc; q++) r.Skip();
                            payload.Pitch.Add(p);
                        }
                        for (int k = 2; k < c; k++) r.Skip();
                        payload.HasPitch = true;
                        break;
                    }
                    case "vb":
                    {
                        int c = r.ReadArrayHeader();
                        if (c < 8) return false;
                        var v = payload.Vibrato;
                        v.Length = r.ReadSingle(); v.Period = r.ReadSingle(); v.Depth = r.ReadSingle(); v.In = r.ReadSingle();
                        v.Out = r.ReadSingle(); v.Shift = r.ReadSingle(); v.Drift = r.ReadSingle(); v.VolLink = r.ReadSingle();
                        for (int k = 8; k < c; k++) r.Skip();
                        payload.HasVibrato = true;
                        break;
                    }
                    case "ph":
                    {
                        int c = r.ReadArrayHeader();
                        for (int k = 0; k < c; k++)
                        {
                            int m = r.ReadArrayHeader();
                            if (m < 8) return false;
                            var o = new PhonemeOverride
                            {
                                Index = r.ReadUInt32(), Mask = r.ReadByte(), Phoneme = r.ReadString() ?? "", Offset = r.ReadInt32(),
                                PreutterDelta = r.ReadSingle(), OverlapDelta = r.ReadSingle(), AttackTimeDelta = r.ReadSingle(), ReleaseTimeDelta = r.ReadSingle(),
                            };
                            for (int q = 8; q < m; q++) r.Skip();
                            payload.PhonemeOverrides.Add(o);
                        }
                        break;
                    }
                    case "ex":
                    {
                        int c = r.ReadArrayHeader();
                        for (int k = 0; k < c; k++)
                        {
                            int m = r.ReadArrayHeader();
                            if (m < 3) return false;
                            var e = new Expression { Abbr = r.ReadString() ?? "", Value = r.ReadSingle(), Index = r.ReadInt32() };
                            for (int q = 3; q < m; q++) r.Skip();
                            payload.Expressions.Add(e);
                        }
                        break;
                    }
                    default:
                    {
                        var start = r.Position;
                        r.Skip();
                        payload.Unknown.Add(new UnknownEntry { Key = key, Raw = r.Sequence.Slice(start, r.Position).ToArray() });
                        break;
                    }
                }
            }
            return r.End && payload.Version != 0;
        }
        catch (Exception e) when (e is MessagePackSerializationException or EndOfStreamException or OverflowException or InvalidOperationException)
        {
            return false;
        }
    }
}

/// <summary>base64url + NOTE event line handling; mirrors notation_payload.cpp and reaper/ReaUtau/spikes/storage/notation_codec.lua.</summary>
public static class NotationCodec
{
    private const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

    public static string B64UrlEncode(ReadOnlySpan<byte> d)
    {
        var sb = new StringBuilder((d.Length + 2) / 3 * 4);
        for (int i = 0; i < d.Length; i += 3)
        {
            uint a = d[i], b = i + 1 < d.Length ? d[i + 1] : 0u, c = i + 2 < d.Length ? d[i + 2] : 0u;
            uint v = (a << 16) | (b << 8) | c;
            int k = Math.Min(d.Length - i, 3) + 1;
            for (int j = 0; j < k; j++) sb.Append(Alphabet[(int)((v >> (18 - 6 * j)) & 63)]);
        }
        return sb.ToString();
    }

    public static byte[]? B64UrlDecode(string s)
    {
        if (s.Length % 4 == 1) return null;
        var o = new List<byte>(s.Length * 3 / 4);
        for (int i = 0; i < s.Length; i += 4)
        {
            uint v = 0; int k = 0;
            for (int j = 0; j < 4; j++)
            {
                v <<= 6;
                if (i + j < s.Length)
                {
                    int x = Alphabet.IndexOf(s[i + j]);
                    if (x < 0) return null;
                    v |= (uint)x; k++;
                }
            }
            for (int j = 0; j + 1 < k; j++) o.Add((byte)(v >> (16 - 8 * j)));
        }
        return o.ToArray();
    }

    private static bool IsSpace(char c) => c is ' ' or '\t' or '\n' or '\r' or '\v' or '\f';

    public static (int Chan, int Pitch, string Tail)? ParseNoteEvent(string m)
    {
        int i = 0;
        void SkipWs() { while (i < m.Length && IsSpace(m[i])) i++; }
        bool Num(out int val)
        {
            int st = i; long v = 0;
            while (i < m.Length && m[i] >= '0' && m[i] <= '9') { v = v * 10 + (m[i] - '0'); i++; if (v > 100000) { val = 0; return false; } }
            val = (int)v;
            return i > st;
        }
        if (!m.StartsWith("NOTE", StringComparison.Ordinal)) return null;
        i = 4;
        if (i >= m.Length || !IsSpace(m[i])) return null;
        SkipWs();
        if (!Num(out int ch)) return null;
        if (i >= m.Length || !IsSpace(m[i])) return null;
        SkipWs();
        if (!Num(out int pitch)) return null;
        SkipWs();
        return (ch, pitch, m.Substring(i));
    }

    private static bool FindCustom(string m, int from, out int s, out int e, out int valueStart)
    {
        for (int i = from; i + 6 <= m.Length; i++)
        {
            if (string.CompareOrdinal(m, i, "custom", 0, 6) != 0) continue;
            if (i > 0 && !IsSpace(m[i - 1])) continue;
            int j = i + 6;
            if (j >= m.Length || !IsSpace(m[j])) continue;
            while (j < m.Length && IsSpace(m[j])) j++;
            int vs = j;
            while (j < m.Length && !IsSpace(m[j])) j++;
            if (j == vs) continue;
            s = i; e = j; valueStart = vs;
            return true;
        }
        s = e = valueStart = 0;
        return false;
    }

    public static string? GetCustom(string m)
    {
        int from = 0;
        while (from < m.Length && FindCustom(m, from, out _, out int e, out int vs))
        {
            string val = m.Substring(vs, e - vs);
            if (val.StartsWith("reautau:", StringComparison.Ordinal) && val.Length > 8) return val.Substring(8);
            from = e;
        }
        return null;
    }

    public static string SetCustom(string m, string b64)
    {
        string repl = "custom reautau:" + b64;
        if (FindCustom(m, 0, out int s, out int e, out _)) return m.Substring(0, s) + repl + m.Substring(e);
        return m + " " + repl;
    }

    public static string MakeNoteEvent(int chan, int pitch, string b64) => $"NOTE {chan} {pitch} custom reautau:{b64}";

    public static NotePayload? PayloadFromEvent(string msg)
    {
        var v = GetCustom(msg);
        if (v == null) return null;
        var bytes = B64UrlDecode(v);
        if (bytes == null) return null;
        return NotePayload.TryDecode(bytes, out var p) ? p : null;
    }

    /// <summary>Empty string when the event would exceed <see cref="NotePayload.MaxEventBytes"/> (spill to P_EXT).</summary>
    public static string EventWithPayload(string msg, NotePayload p)
    {
        string o = SetCustom(msg, B64UrlEncode(p.Encode()));
        return Encoding.UTF8.GetByteCount(o) > NotePayload.MaxEventBytes ? "" : o;
    }
}
