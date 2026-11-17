using ReaUtau.Protocol;

namespace ReaUtau.Engine;

/// <summary>
/// The outbound half of the engine &lt;-&gt; extension stream. Split out from <see cref="Connection"/> so the message
/// dispatcher (<see cref="Session"/>) can be driven by a socket, a test double, or the smoke client without changes.
/// </summary>
public interface IEngineConnection
{
    bool IsOpen { get; }
    void Send<T>(T msg) where T : IMessage;
    void SendPhraseAudio(PhraseAudio meta, ReadOnlySpan<float> samples);
    void Close();
}
