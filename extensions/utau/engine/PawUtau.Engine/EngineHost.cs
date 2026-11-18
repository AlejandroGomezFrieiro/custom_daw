using System.Reflection;
using PawUtau.Protocol;
using Log = Serilog.Log;

namespace PawUtau.Engine;

/// <summary>
/// Process lifetime: bootstrap OpenUtau, connect to the extension's listening Unix socket (retrying while the extension
/// is still starting), send the engine Hello, then serve frames until EOF or <c>Shutdown</c>.
///
/// The engine sends Hello immediately after connecting and does not wait for the extension's Hello (protocol section 4);
/// the extension treats the engine's Hello as "ready". One process serves one connection: on disconnect it exits and the
/// supervisor respawns it, and the next connection starts with a full SyncProject.
/// </summary>
public sealed class EngineHost
{
    static readonly string[] Capabilities = { "classic", "diffsinger", "worldline" };
    static readonly TimeSpan ConnectFor = TimeSpan.FromSeconds(30);

    readonly Options opts;

    public EngineHost(Options opts) => this.opts = opts;

    public int Run()
    {
        Bootstrap.Init(opts);
        Log.Information("connecting to {Socket}", opts.SocketPath);

        using var conn = Connection.Connect(opts.SocketPath, ConnectFor);
        Log.Information("connected to {Socket}", opts.SocketPath);

        try
        {
            conn.Send(new Hello
            {
                ProtocolVersion = Proto.Version,
                Role = PawUtau.Protocol.Role.Engine,
                Version = EngineVersion(),
                OpenUtauVersion = Bootstrap.OpenUtauVersion,
                Pid = (uint)Environment.ProcessId,
                Capabilities = Capabilities,
            });

            // Attach only after Hello: Attach flushes bootstrap log lines, and those must not precede the engine Hello.
            Bootstrap.Sink.Attach(conn);

            using var session = new Session(conn);
            using var stop = new CancellationTokenSource();
            conn.Closed += stop.Cancel;

            while (!session.ShutdownRequested)
            {
                Frame? frame;
                try { frame = conn.ReadAsync(stop.Token).GetAwaiter().GetResult(); }
                catch (OperationCanceledException) { break; }
                catch (ProtocolException e)
                {
                    // Corrupt framing is unrecoverable on this stream: report it fatally and let the supervisor resync.
                    Log.Error("protocol error: {Message}", e.Message);
                    session.SendFatal(ErrorCode.BadFrame, e.Message);
                    break;
                }
                if (frame == null) break;
                try { session.Handle(frame); }
                catch (ProtocolException e)
                {
                    Log.Error("protocol error: {Message}", e.Message);
                    session.SendFatal(ErrorCode.BadFrame, e.Message);
                    break;
                }
                catch (Exception e)
                {
                    Log.Error(e, "unhandled message error");
                    session.SendFatal(ErrorCode.Internal, e.Message);
                    break;
                }
            }
        }
        finally
        {
            Bootstrap.Sink.Detach();
        }

        Log.Information("engine exiting");
        return 0;
    }

    static string EngineVersion()
    {
        var asm = typeof(EngineHost).Assembly;
        return asm.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? asm.GetName().Version?.ToString(3)
            ?? "0.0.0";
    }
}
