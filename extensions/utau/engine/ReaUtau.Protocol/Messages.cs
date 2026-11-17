// ReaUtau engine <-> extension wire protocol message types. Mirror of native/common/protocol.h; field order == [Key] order ==
// msgpack array order. See docs/protocol.md. Every body is a msgpack ARRAY; minor versions append fields at the end.
using MessagePack;

namespace ReaUtau.Protocol;

public static class Proto
{
    public const uint Major = 1, Minor = 0;
    public const uint Version = (Major << 16) | Minor;
    public const uint MaxFrameBytes = 256u * 1024u * 1024u;
    public const int TicksPerQuarter = 480;
    public const int CurveGridTicks = 5;
}

public static class MsgType
{
    public const byte Hello = 0x01, Error = 0x02, Log = 0x03, Ping = 0x04, Pong = 0x05;
    public const byte SyncProject = 0x10, ApplyDelta = 0x11, Transport = 0x12, SetTrackConfig = 0x13, RequestSingers = 0x14,
        RequestRenderers = 0x15, RequestPhonemizers = 0x16, RunBatchEdit = 0x17, SetRenderPolicy = 0x18, Shutdown = 0x19,
        Audition = 0x1A, Invalidate = 0x1B;
    public const byte PhraseLayout = 0x40, Phonemes = 0x41, RenderedPitch = 0x42, Progress = 0x43, SingerList = 0x44,
        RendererList = 0x45, PhonemizerList = 0x46, BatchEditResult = 0x47;
    public const byte PhraseAudio = 0x80;
    public static bool HasPayload(byte t) => t >= 0x80;
}

public static class Role { public const byte Extension = 0, Engine = 1; }
public static class ErrorCode { public const uint VersionMismatch = 1, BadFrame = 2, UnknownMessage = 3, InvalidState = 4, SingerNotFound = 5, RenderFailed = 6, Internal = 7, ConfigAdjusted = 8; }
public static class LogLevel { public const byte Trace = 0, Debug = 1, Info = 2, Warn = 3, Error = 4; }
public static class Quality { public const byte Draft = 0, Final = 1; }
public static class Purpose { public const byte Phrase = 0, Audition = 1; }
public static class PhraseStateKind { public const byte Pending = 0, Rendering = 1, Draft = 2, Final = 3, Error = 4; }
public static class PhonemeFlags { public const byte Error = 1, Overridden = 2; }
public static class ExprKind { public const byte Numerical = 0, Curve = 1, Options = 2, Flag = 3; }

/// <summary>Implemented by every top-level message; <see cref="Type"/> is its frame type byte.</summary>
public interface IMessage { byte Type { get; } }

// ---- shared value types ----------------------------------------------------------------------------------------
[MessagePackObject] public sealed class KeyValue
{
    [Key(0)] public string Key = ""; [Key(1)] public string Value = "";
}

/// <summary>Sparse curve knot. Tick = OpenUtau ticks relative to PART start (fractional allowed).</summary>
[MessagePackObject] public sealed class Knot
{
    [Key(0)] public double Tick; [Key(1)] public double Value; [Key(2)] public byte Shape; [Key(3)] public float Tension;
}
[MessagePackObject] public sealed class CurveData
{
    [Key(0)] public string Abbr = ""; [Key(1)] public Knot[] Knots = Array.Empty<Knot>();
}
[MessagePackObject] public sealed class TempoPoint
{
    [Key(0)] public long PosTick; [Key(1)] public double Bpm = 120; [Key(2)] public double TimeSec;
}
[MessagePackObject] public sealed class TimeSigPoint
{
    [Key(0)] public long PosTick; [Key(1)] public byte Numerator = 4; [Key(2)] public byte Denominator = 4;
}
[MessagePackObject] public sealed class TrackConfig
{
    [Key(0)] public string SingerId = ""; [Key(1)] public string Phonemizer = ""; [Key(2)] public string Renderer = "";
    [Key(3)] public string Resampler = ""; [Key(4)] public string Wavtool = ""; [Key(5)] public float PitchBendRange = 12;
    [Key(6)] public KeyValue[] Options = Array.Empty<KeyValue>();
}
[MessagePackObject] public sealed class TrackInfo
{
    [Key(0)] public string TrackId = ""; [Key(1)] public string Name = ""; [Key(2)] public bool Muted; [Key(3)] public TrackConfig Config = new();
}
[MessagePackObject] public sealed class PartInfo
{
    [Key(0)] public string PartId = ""; [Key(1)] public string TrackId = ""; [Key(2)] public long PosTick; [Key(3)] public long DurTick;
    [Key(4)] public string Name = ""; [Key(5)] public bool Muted;
}
/// <summary>Payload = the type-15 NotePayload msgpack (<see cref="NotePayload"/>), carried verbatim.</summary>
[MessagePackObject] public sealed class NoteMsg
{
    [Key(0)] public uint Id; [Key(1)] public int PosTick; [Key(2)] public int DurTick; [Key(3)] public int Tone = 60;
    [Key(4)] public byte[] Payload = Array.Empty<byte>();
}
[MessagePackObject] public sealed class PartData
{
    [Key(0)] public PartInfo Info = new(); [Key(1)] public NoteMsg[] Notes = Array.Empty<NoteMsg>(); [Key(2)] public CurveData[] Curves = Array.Empty<CurveData>();
}
[MessagePackObject] public sealed class PartNoteIds
{
    [Key(0)] public string PartId = ""; [Key(1)] public uint[] Ids = Array.Empty<uint>();
}
[MessagePackObject] public sealed class PartNotes
{
    [Key(0)] public string PartId = ""; [Key(1)] public NoteMsg[] Notes = Array.Empty<NoteMsg>();
}
[MessagePackObject] public sealed class PartCurves
{
    [Key(0)] public string PartId = ""; [Key(1)] public CurveData[] Curves = Array.Empty<CurveData>();
}

// ---- both directions ---------------------------------------------------------------------------------------------
[MessagePackObject] public sealed class Hello : IMessage
{
    [IgnoreMember] public byte Type => MsgType.Hello;
    [Key(0)] public uint ProtocolVersion = Proto.Version; [Key(1)] public byte Role = ReaUtau.Protocol.Role.Extension;
    [Key(2)] public string Version = ""; [Key(3)] public string OpenUtauVersion = ""; [Key(4)] public uint Pid;
    [Key(5)] public string[] Capabilities = Array.Empty<string>();
}
[MessagePackObject] public sealed class Error : IMessage
{
    [IgnoreMember] public byte Type => MsgType.Error;
    [Key(0)] public uint Code; [Key(1)] public string Message = ""; [Key(2)] public bool Fatal; [Key(3)] public ulong RefSeq;
}
[MessagePackObject] public sealed class Log : IMessage
{
    [IgnoreMember] public byte Type => MsgType.Log;
    [Key(0)] public byte Level = LogLevel.Info; [Key(1)] public string Source = ""; [Key(2)] public string Message = "";
}
[MessagePackObject] public sealed class Ping : IMessage
{
    [IgnoreMember] public byte Type => MsgType.Ping; [Key(0)] public ulong Nonce;
}
[MessagePackObject] public sealed class Pong : IMessage
{
    [IgnoreMember] public byte Type => MsgType.Pong; [Key(0)] public ulong Nonce;
}

// ---- extension -> engine -------------------------------------------------------------------------------------------
[MessagePackObject] public sealed class SyncProject : IMessage
{
    [IgnoreMember] public byte Type => MsgType.SyncProject;
    [Key(0)] public ulong Seq; [Key(1)] public string ProjectId = "";
    [Key(2)] public TempoPoint[] Tempos = Array.Empty<TempoPoint>(); [Key(3)] public TimeSigPoint[] TimeSigs = Array.Empty<TimeSigPoint>();
    [Key(4)] public TrackInfo[] Tracks = Array.Empty<TrackInfo>(); [Key(5)] public PartData[] Parts = Array.Empty<PartData>();
}
[MessagePackObject] public sealed class ApplyDelta : IMessage
{
    [IgnoreMember] public byte Type => MsgType.ApplyDelta;
    [Key(0)] public ulong Seq; [Key(1)] public bool ReplaceTempo;
    [Key(2)] public TempoPoint[] Tempos = Array.Empty<TempoPoint>(); [Key(3)] public TimeSigPoint[] TimeSigs = Array.Empty<TimeSigPoint>();
    [Key(4)] public string[] RemoveTracks = Array.Empty<string>(); [Key(5)] public TrackInfo[] UpsertTracks = Array.Empty<TrackInfo>();
    [Key(6)] public string[] RemoveParts = Array.Empty<string>(); [Key(7)] public PartInfo[] UpsertParts = Array.Empty<PartInfo>();
    [Key(8)] public PartNoteIds[] RemoveNotes = Array.Empty<PartNoteIds>(); [Key(9)] public PartNotes[] UpsertNotes = Array.Empty<PartNotes>();
    [Key(10)] public PartCurves[] ReplaceCurves = Array.Empty<PartCurves>();
}
[MessagePackObject] public sealed class Transport : IMessage
{
    [IgnoreMember] public byte Type => MsgType.Transport;
    [Key(0)] public bool Playing; [Key(1)] public double PosSec; [Key(2)] public double EditCursorSec;
}
[MessagePackObject] public sealed class SetTrackConfig : IMessage
{
    [IgnoreMember] public byte Type => MsgType.SetTrackConfig;
    [Key(0)] public string TrackId = ""; [Key(1)] public TrackConfig Config = new();
}
[MessagePackObject] public sealed class RequestSingers : IMessage
{
    [IgnoreMember] public byte Type => MsgType.RequestSingers; [Key(0)] public bool Rescan;
}
[MessagePackObject] public sealed class RequestRenderers : IMessage { [IgnoreMember] public byte Type => MsgType.RequestRenderers; }
[MessagePackObject] public sealed class RequestPhonemizers : IMessage { [IgnoreMember] public byte Type => MsgType.RequestPhonemizers; }
[MessagePackObject] public sealed class RunBatchEdit : IMessage
{
    [IgnoreMember] public byte Type => MsgType.RunBatchEdit;
    [Key(0)] public ulong RequestId; [Key(1)] public string Name = ""; [Key(2)] public string[] PartIds = Array.Empty<string>();
    [Key(3)] public uint[] NoteIds = Array.Empty<uint>(); [Key(4)] public string Args = "";
}
[MessagePackObject] public sealed class SetRenderPolicy : IMessage
{
    [IgnoreMember] public byte Type => MsgType.SetRenderPolicy;
    [Key(0)] public bool DraftWhilePlaying = true; [Key(1)] public byte DsDraftSteps = 4; [Key(2)] public byte DsFinalSteps;
    [Key(3)] public uint FinalDelayMs = 1500; [Key(4)] public byte RenderThreads; [Key(5)] public bool RenderAhead = true;
}
[MessagePackObject] public sealed class Shutdown : IMessage { [IgnoreMember] public byte Type => MsgType.Shutdown; }
[MessagePackObject] public sealed class Audition : IMessage
{
    [IgnoreMember] public byte Type => MsgType.Audition;
    [Key(0)] public ulong RequestId; [Key(1)] public string TrackId = ""; [Key(2)] public int Tone = 60;
    [Key(3)] public string Lyric = ""; [Key(4)] public uint DurationMs = 500;
}
[MessagePackObject] public sealed class Invalidate : IMessage
{
    [IgnoreMember] public byte Type => MsgType.Invalidate; [Key(0)] public string TrackId = ""; [Key(1)] public string PartId = "";
}

// ---- engine -> extension ---------------------------------------------------------------------------------------------
/// <summary>Meta of a PhraseAudio frame; the raw payload is frames*channels little-endian f32 samples.</summary>
[MessagePackObject] public sealed class PhraseAudio : IMessage
{
    [IgnoreMember] public byte Type => MsgType.PhraseAudio;
    [Key(0)] public string TrackId = ""; [Key(1)] public ulong PhraseHash; [Key(2)] public double StartSec;
    [Key(3)] public uint SampleRate = 44100; [Key(4)] public byte Channels = 1; [Key(5)] public byte Quality = ReaUtau.Protocol.Quality.Final;
    [Key(6)] public uint Frames; [Key(7)] public ulong Seq; [Key(8)] public byte Purpose = ReaUtau.Protocol.Purpose.Phrase;
}
[MessagePackObject] public sealed class PhraseState
{
    [Key(0)] public ulong Hash; [Key(1)] public double StartSec; [Key(2)] public double EndSec; [Key(3)] public byte State;
}
[MessagePackObject] public sealed class PhraseLayout : IMessage
{
    [IgnoreMember] public byte Type => MsgType.PhraseLayout;
    [Key(0)] public string TrackId = ""; [Key(1)] public ulong Seq; [Key(2)] public PhraseState[] Phrases = Array.Empty<PhraseState>();
}
[MessagePackObject] public sealed class PhonemeInfo
{
    [Key(0)] public string Phoneme = ""; [Key(1)] public string Alias = ""; [Key(2)] public int StartTick; [Key(3)] public int EndTick;
    [Key(4)] public float PreutterMs; [Key(5)] public float OverlapMs; [Key(6)] public byte Flags;
}
[MessagePackObject] public sealed class NotePhonemes
{
    [Key(0)] public uint NoteId; [Key(1)] public PhonemeInfo[] Phonemes = Array.Empty<PhonemeInfo>();
}
[MessagePackObject] public sealed class Phonemes : IMessage
{
    [IgnoreMember] public byte Type => MsgType.Phonemes;
    [Key(0)] public string PartId = ""; [Key(1)] public ulong Seq; [Key(2)] public NotePhonemes[] Notes = Array.Empty<NotePhonemes>();
}
[MessagePackObject] public sealed class RenderedPitch : IMessage
{
    [IgnoreMember] public byte Type => MsgType.RenderedPitch;
    [Key(0)] public string PartId = ""; [Key(1)] public ulong Seq; [Key(2)] public uint TickStep = Proto.CurveGridTicks; [Key(3)] public int StartTick;
    /// <summary>Packed little-endian f32, absolute pitch in cents (MIDI 60 = 6000); negative = no data.</summary>
    [Key(4)] public byte[] Cents = Array.Empty<byte>();
}
[MessagePackObject] public sealed class Progress : IMessage
{
    [IgnoreMember] public byte Type => MsgType.Progress;
    [Key(0)] public string TaskId = ""; [Key(1)] public string Label = ""; [Key(2)] public float Fraction = -1; [Key(3)] public uint Queued;
}
[MessagePackObject] public sealed class Subbank
{
    [Key(0)] public string Color = ""; [Key(1)] public string Prefix = ""; [Key(2)] public string Suffix = "";
}
[MessagePackObject] public sealed class SingerInfo
{
    [Key(0)] public string Id = ""; [Key(1)] public string Name = ""; [Key(2)] public string SingerType = ""; [Key(3)] public string ImagePath = "";
    [Key(4)] public string Location = ""; [Key(5)] public string Author = ""; [Key(6)] public string[] VoiceColors = Array.Empty<string>();
    [Key(7)] public Subbank[] Subbanks = Array.Empty<Subbank>(); [Key(8)] public string DefaultPhonemizer = "";
}
[MessagePackObject] public sealed class SingerList : IMessage
{
    [IgnoreMember] public byte Type => MsgType.SingerList; [Key(0)] public SingerInfo[] Singers = Array.Empty<SingerInfo>();
}
[MessagePackObject] public sealed class ExpressionDesc
{
    [Key(0)] public string Abbr = ""; [Key(1)] public string Name = ""; [Key(2)] public float Min; [Key(3)] public float Max;
    [Key(4)] public float DefaultValue; [Key(5)] public byte Kind; [Key(6)] public string[] Options = Array.Empty<string>();
}
[MessagePackObject] public sealed class RendererInfo
{
    [Key(0)] public string Id = ""; [Key(1)] public string Name = ""; [Key(2)] public string[] SingerTypes = Array.Empty<string>();
    [Key(3)] public ExpressionDesc[] Expressions = Array.Empty<ExpressionDesc>();
}
[MessagePackObject] public sealed class RendererList : IMessage
{
    [IgnoreMember] public byte Type => MsgType.RendererList;
    [Key(0)] public RendererInfo[] Renderers = Array.Empty<RendererInfo>(); [Key(1)] public string[] Resamplers = Array.Empty<string>();
    [Key(2)] public string[] Wavtools = Array.Empty<string>();
}
[MessagePackObject] public sealed class PhonemizerInfo
{
    [Key(0)] public string Id = ""; [Key(1)] public string Name = ""; [Key(2)] public string Tag = ""; [Key(3)] public string Language = "";
}
[MessagePackObject] public sealed class PhonemizerList : IMessage
{
    [IgnoreMember] public byte Type => MsgType.PhonemizerList; [Key(0)] public PhonemizerInfo[] Phonemizers = Array.Empty<PhonemizerInfo>();
}
[MessagePackObject] public sealed class BatchEditResult : IMessage
{
    [IgnoreMember] public byte Type => MsgType.BatchEditResult;
    [Key(0)] public ulong RequestId; [Key(1)] public bool Ok; [Key(2)] public string Message = "";
    [Key(3)] public PartNoteIds[] RemoveNotes = Array.Empty<PartNoteIds>(); [Key(4)] public PartNotes[] UpsertNotes = Array.Empty<PartNotes>();
}
