using OpenUtau.Core.Render;

namespace PawUtau.Engine;

/// <summary>
/// Unison / doubling (SynthV 2's "Unison", called "Doubling" in its beta): one track sings with up to 16 voices.
/// Track options: <c>unison</c> = voice count (1 = off), <c>unison_spacing</c> = stereo spread 0..100 %,
/// <c>unison_pitch</c> = detune spread in cents, <c>unison_timing</c> = timing spread in ms, <c>unison_level</c> = level
/// of the doubles in dB relative to the lead.
///
/// The lead is the phrase as edited (the user's AI take); every other voice renders the same phrase with its own AI pitch
/// take (the pitch model is stochastic, which gives natural variation; takes persist like the lead's), a fixed detune
/// and a fixed timing offset. Voices are spread over the stereo field (the lead nearest the centre) and summed with
/// 1/sqrt(n) gain so the ensemble stays about as loud as one voice. Everything per voice is deterministic, so the same
/// settings always sound the same.
/// </summary>
public sealed record UnisonSettings(int Voices, double Spacing, double DetuneCents, double TimingMs, double LevelDb)
{
    public const int MaxVoices = 16;

    public static UnisonSettings? Parse(Func<string, string> option)
    {
        if (!int.TryParse(option("unison"), out var n) || n < 2) return null;
        static double D(string s, double def) =>
            double.TryParse(s, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v) ? v : def;
        return new UnisonSettings(
            Math.Min(n, MaxVoices),
            Math.Clamp(D(option("unison_spacing"), 60), 0, 100),
            Math.Clamp(D(option("unison_pitch"), 8), 0, 100),
            Math.Clamp(D(option("unison_timing"), 20), 0, 200),
            Math.Clamp(D(option("unison_level"), 0), -24, 6));
    }
}

public static class Unison
{
    /// <summary>Per-voice placement: pan -1..1, detune cents, timing offset ms. Voice 0 is the lead.</summary>
    public static (double Pan, double Cents, double Ms) Voice(UnisonSettings u, int voice)
    {
        int n = u.Voices;
        // evenly spread positions; the lead takes the most central one, the others fill outwards alternating sides
        var order = Enumerable.Range(0, n).OrderBy(k => Math.Abs(k - (n - 1) / 2.0)).ThenBy(k => k).ToArray();
        double x = n == 1 ? 0 : -1 + 2.0 * order[voice] / (n - 1);
        double pan = x * u.Spacing / 100.0;
        if (voice == 0) return (pan, 0, 0);
        // deterministic, well spread offsets (golden-ratio sequence) in -1..1
        double r1 = Frac(voice * 0.6180339887) * 2 - 1;
        double r2 = Frac(voice * 0.7548776662 + 0.3) * 2 - 1;
        return (pan, r1 * u.DetuneCents, r2 * u.TimingMs);
    }

    static double Frac(double v) => v - Math.Floor(v);

    /// <summary>
    /// Render the doubles of a phrase and mix them with the lead into interleaved stereo. <paramref name="renderVoice"/>
    /// renders one voice phrase (mono at <paramref name="sampleRate"/>); <paramref name="voicePhrase"/> builds the phrase of
    /// voice v (its AI take, detuned). Returns null when cancelled.
    /// </summary>
    public static float[]? Mix(UnisonSettings u, float[] lead, int sampleRate, Func<int, RenderPhrase> voicePhrase,
        Func<RenderPhrase, float[]?> renderVoice, Func<bool> cancelled)
    {
        int frames = lead.Length;
        var outBuf = new float[frames * 2];
        double norm = 1.0 / Math.Sqrt(u.Voices);
        double doubles = Math.Pow(10, u.LevelDb / 20.0);
        for (int v = 0; v < u.Voices; v++)
        {
            if (cancelled()) return null;
            float[]? s = v == 0 ? lead : renderVoice(voicePhrase(v));
            if (s == null || s.Length == 0) continue;
            var (pan, _, ms) = Voice(u, v);
            // equal-power pan scaled so that the centre is unity on both channels (as a mono clip plays)
            double theta = (pan + 1) * Math.PI / 4;
            double g = norm * (v == 0 ? 1.0 : doubles) * Math.Sqrt(2);
            float gl = (float)(g * Math.Cos(theta)), gr = (float)(g * Math.Sin(theta));
            int shift = (int)Math.Round(ms / 1000.0 * sampleRate);   // > 0: later
            for (int i = 0; i < frames; i++)
            {
                int j = i - shift;
                if (j < 0 || j >= s.Length) continue;
                float x = s[j];
                outBuf[2 * i] += x * gl;
                outBuf[2 * i + 1] += x * gr;
            }
        }
        return outBuf;
    }
}
