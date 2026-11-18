// Per-note payload: what the extension sends of each note (lua/utau/payload.lua is the other side). Map with short string keys in canonical order: v id ly po tu pp vb ph ex, then unknown keys.
using System.Buffers;
using System.Text;
using MessagePack;

namespace PawUtau.Protocol;

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
