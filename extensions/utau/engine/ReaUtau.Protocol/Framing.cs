// Frame layer: `u32 LE length | u8 msgType | body` (length = 1 + body length). Types >= 0x80 carry a raw payload:
// body = `u32 LE metaLen | msgpack meta | payload`. Mirror of native/common/protocol.{h,cpp}.
using System.Buffers.Binary;
using System.Runtime.InteropServices;
using MessagePack;

namespace ReaUtau.Protocol;

public sealed class Frame
{
    public byte Type;
    /// <summary>msgpack body; for payload types only the meta part.</summary>
    public byte[] Body = Array.Empty<byte>();
    /// <summary>Raw payload (payload types only).</summary>
    public byte[] Payload = Array.Empty<byte>();
}

public class ProtocolException : Exception
{
    public ProtocolException(string message) : base(message) { }
}

public static class Codec
{
    public static readonly MessagePackSerializerOptions Options = MessagePackSerializerOptions.Standard;

    public static byte[] Serialize<T>(T value) => MessagePackSerializer.Serialize(value, Options);

    /// <summary>Strict: the whole buffer must be consumed.</summary>
    public static T Deserialize<T>(ReadOnlyMemory<byte> bytes)
    {
        try
        {
            var v = MessagePackSerializer.Deserialize<T>(bytes, Options, out int read);
            if (read != bytes.Length) throw new ProtocolException("trailing bytes after message body");
            return v;
        }
        catch (MessagePackSerializationException e) { throw new ProtocolException("malformed message body: " + e.Message); }
    }

    public static bool TryDeserialize<T>(ReadOnlyMemory<byte> bytes, out T? value)
    {
        try { value = Deserialize<T>(bytes); return true; }
        catch (ProtocolException) { value = default; return false; }
    }

    public static T Decode<T>(Frame f) where T : IMessage, new()
    {
        if (f.Type != new T().Type) throw new ProtocolException($"frame type 0x{f.Type:x2} is not {typeof(T).Name}");
        return Deserialize<T>(f.Body);
    }

    /// <summary>Decodes any known message frame; returns null for an unknown type.</summary>
    public static IMessage? DecodeAny(Frame f) => f.Type switch
    {
        MsgType.Hello => Deserialize<Hello>(f.Body),
        MsgType.Error => Deserialize<Error>(f.Body),
        MsgType.Log => Deserialize<Log>(f.Body),
        MsgType.Ping => Deserialize<Ping>(f.Body),
        MsgType.Pong => Deserialize<Pong>(f.Body),
        MsgType.SyncProject => Deserialize<SyncProject>(f.Body),
        MsgType.ApplyDelta => Deserialize<ApplyDelta>(f.Body),
        MsgType.Transport => Deserialize<Transport>(f.Body),
        MsgType.SetTrackConfig => Deserialize<SetTrackConfig>(f.Body),
        MsgType.RequestSingers => Deserialize<RequestSingers>(f.Body),
        MsgType.RequestRenderers => Deserialize<RequestRenderers>(f.Body),
        MsgType.RequestPhonemizers => Deserialize<RequestPhonemizers>(f.Body),
        MsgType.RunBatchEdit => Deserialize<RunBatchEdit>(f.Body),
        MsgType.SetRenderPolicy => Deserialize<SetRenderPolicy>(f.Body),
        MsgType.Shutdown => Deserialize<Shutdown>(f.Body),
        MsgType.Audition => Deserialize<Audition>(f.Body),
        MsgType.Invalidate => Deserialize<Invalidate>(f.Body),
        MsgType.PhraseLayout => Deserialize<PhraseLayout>(f.Body),
        MsgType.Phonemes => Deserialize<Phonemes>(f.Body),
        MsgType.RenderedPitch => Deserialize<RenderedPitch>(f.Body),
        MsgType.Progress => Deserialize<Progress>(f.Body),
        MsgType.SingerList => Deserialize<SingerList>(f.Body),
        MsgType.RendererList => Deserialize<RendererList>(f.Body),
        MsgType.PhonemizerList => Deserialize<PhonemizerList>(f.Body),
        MsgType.BatchEditResult => Deserialize<BatchEditResult>(f.Body),
        MsgType.PhraseAudio => Deserialize<PhraseAudio>(f.Body),
        _ => null,
    };

    /// <summary>Valid when payload size == frames*channels*4 and channels is 1 or 2.</summary>
    public static bool PhraseAudioValid(PhraseAudio m, Frame f) =>
        m.Channels is >= 1 and <= 2 && (long)f.Payload.Length == (long)m.Frames * m.Channels * 4;

    public static byte[] PackF32(ReadOnlySpan<float> v)
    {
        var b = new byte[v.Length * 4];
        for (int i = 0; i < v.Length; i++) BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(i * 4), v[i]);
        return b;
    }
    public static float[] UnpackF32(ReadOnlySpan<byte> b)
    {
        var v = new float[b.Length / 4];
        for (int i = 0; i < v.Length; i++) v[i] = BinaryPrimitives.ReadSingleLittleEndian(b.Slice(i * 4));
        return v;
    }
}

public static class FrameWriter
{
    public static byte[] Build(byte type, ReadOnlySpan<byte> body)
    {
        var f = new byte[5 + body.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(f, (uint)(1 + body.Length));
        f[4] = type;
        body.CopyTo(f.AsSpan(5));
        return f;
    }

    public static byte[] Build<T>(T msg) where T : IMessage => Build(msg.Type, Codec.Serialize(msg));

    public static byte[] BuildPayload(byte type, ReadOnlySpan<byte> meta, ReadOnlySpan<byte> payload)
    {
        var f = new byte[5 + 4 + meta.Length + payload.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(f, (uint)(1 + 4 + meta.Length + payload.Length));
        f[4] = type;
        BinaryPrimitives.WriteUInt32LittleEndian(f.AsSpan(5), (uint)meta.Length);
        meta.CopyTo(f.AsSpan(9));
        payload.CopyTo(f.AsSpan(9 + meta.Length));
        return f;
    }

    public static byte[] BuildPhraseAudio(PhraseAudio meta, ReadOnlySpan<float> samples)
    {
        meta.Frames = (uint)(samples.Length / Math.Max(1, (int)meta.Channels));
        return BuildPayload(MsgType.PhraseAudio, Codec.Serialize(meta), Codec.PackF32(samples));
    }

    public static async Task WriteAsync(Stream s, byte[] frame, CancellationToken ct = default)
    {
        await s.WriteAsync(frame, ct).ConfigureAwait(false);
        await s.FlushAsync(ct).ConfigureAwait(false);
    }
}

/// <summary>Incremental parser (mirror of the C++ FrameReader): feed bytes, pull frames.</summary>
public sealed class FrameParser
{
    private byte[] _buf = new byte[4096];
    private int _start, _end;

    public int Buffered => _end - _start;

    public void Feed(ReadOnlySpan<byte> data)
    {
        if (_start > 0 && _start >= _buf.Length / 2)
        {
            Buffer.BlockCopy(_buf, _start, _buf, 0, _end - _start);
            _end -= _start;
            _start = 0;
        }
        if (_end + data.Length > _buf.Length) Array.Resize(ref _buf, Math.Max(_buf.Length * 2, _end + data.Length));
        data.CopyTo(_buf.AsSpan(_end));
        _end += data.Length;
    }

    /// <summary>Returns the next complete frame or null if more bytes are needed. Throws ProtocolException on a corrupt stream.</summary>
    public Frame? Next()
    {
        int avail = _end - _start;
        if (avail < 4) return null;
        uint len = BinaryPrimitives.ReadUInt32LittleEndian(_buf.AsSpan(_start));
        if (len < 1 || len > Proto.MaxFrameBytes) throw new ProtocolException($"invalid frame length {len}");
        if (avail < 4 + (long)len) return null;
        var f = new Frame { Type = _buf[_start + 4] };
        var body = _buf.AsSpan(_start + 5, (int)len - 1);
        if (MsgType.HasPayload(f.Type))
        {
            if (body.Length < 4) throw new ProtocolException("payload frame too short");
            uint metaLen = BinaryPrimitives.ReadUInt32LittleEndian(body);
            if (metaLen > body.Length - 4) throw new ProtocolException("payload frame meta length out of range");
            f.Body = body.Slice(4, (int)metaLen).ToArray();
            f.Payload = body.Slice(4 + (int)metaLen).ToArray();
        }
        else f.Body = body.ToArray();
        _start += 4 + (int)len;
        if (_start == _end) _start = _end = 0;
        return f;
    }
}

public static class FrameReader
{
    /// <summary>Reads one frame from a stream; null on clean EOF at a frame boundary.</summary>
    public static async Task<Frame?> ReadAsync(Stream s, CancellationToken ct = default)
    {
        var head = new byte[4];
        int got = await ReadFullAsync(s, head, ct).ConfigureAwait(false);
        if (got == 0) return null;
        if (got < 4) throw new EndOfStreamException("EOF inside frame header");
        uint len = BinaryPrimitives.ReadUInt32LittleEndian(head);
        if (len < 1 || len > Proto.MaxFrameBytes) throw new ProtocolException($"invalid frame length {len}");
        var rest = new byte[len];
        if (await ReadFullAsync(s, rest, ct).ConfigureAwait(false) < len) throw new EndOfStreamException("EOF inside frame");
        var p = new FrameParser();
        p.Feed(head);
        p.Feed(rest);
        return p.Next();
    }

    private static async Task<int> ReadFullAsync(Stream s, byte[] buf, CancellationToken ct)
    {
        int n = 0;
        while (n < buf.Length)
        {
            int r = await s.ReadAsync(buf.AsMemory(n), ct).ConfigureAwait(false);
            if (r == 0) break;
            n += r;
        }
        return n;
    }
}
