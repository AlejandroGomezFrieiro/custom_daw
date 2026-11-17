using System.Net.Sockets;
using System.Threading.Channels;
using ReaUtau.Protocol;

namespace ReaUtau.Engine;

/// <summary>Client side of the UDS: one atomic frame per queued buffer, written by a single writer task.</summary>
public sealed class Connection : IDisposable, IEngineConnection
{
    readonly Socket sock;
    readonly NetworkStream stream;
    readonly Channel<byte[]> outq = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true });
    readonly Task writer;
    volatile bool closed;
    public event Action? Closed;

    Connection(Socket s)
    {
        sock = s;
        stream = new NetworkStream(s, ownsSocket: false);
        writer = Task.Run(WriteLoop);
    }

    public static Connection Connect(string path, TimeSpan retryFor)
    {
        var deadline = DateTime.UtcNow + retryFor;
        while (true)
        {
            var s = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            try
            {
                s.Connect(new UnixDomainSocketEndPoint(path));
                return new Connection(s);
            }
            catch (SocketException) when (DateTime.UtcNow < deadline)
            {
                s.Dispose();
                Thread.Sleep(100);
            }
        }
    }

    async Task WriteLoop()
    {
        try
        {
            await foreach (var buf in outq.Reader.ReadAllAsync())
                await FrameWriter.WriteAsync(stream, buf).ConfigureAwait(false);
        }
        catch (Exception) { MarkClosed(); }
    }

    void MarkClosed()
    {
        if (closed) return;
        closed = true;
        Closed?.Invoke();
    }

    public bool IsOpen => !closed;

    public void Send<T>(T msg) where T : IMessage
    {
        if (closed) return;
        outq.Writer.TryWrite(FrameWriter.Build(msg));
    }

    public void SendPhraseAudio(PhraseAudio meta, ReadOnlySpan<float> samples)
    {
        if (closed) return;
        outq.Writer.TryWrite(FrameWriter.BuildPhraseAudio(meta, samples));
    }

    /// <summary>Next frame; null on EOF / error (connection is then marked closed).</summary>
    public async Task<Frame?> ReadAsync(CancellationToken ct)
    {
        try
        {
            var f = await FrameReader.ReadAsync(stream, ct).ConfigureAwait(false);
            if (f == null) MarkClosed();
            return f;
        }
        catch (ProtocolException) { throw; }
        catch (Exception) when (!ct.IsCancellationRequested) { MarkClosed(); return null; }
    }

    /// <summary>Flush everything queued, then close.</summary>
    public void Close()
    {
        if (!closed) outq.Writer.TryComplete();
        try { writer.Wait(TimeSpan.FromSeconds(3)); } catch { }
        closed = true;
        try { sock.Shutdown(SocketShutdown.Both); } catch { }
        try { sock.Close(); } catch { }
    }

    public void Dispose() => Close();
}
