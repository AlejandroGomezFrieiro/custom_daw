using System.Reflection;
using OpenUtau.Core.Render;
using OpenUtau.Core.Ustx;

namespace ReaUtau.Engine;

/// <summary>
/// The few OpenUtau.Core internals the engine needs, reached by reflection (cached FieldInfo/MethodInfo; validated once at startup
/// so a version bump of the submodule fails loudly before Hello instead of mid-render):
///   RenderPhrase.renderer              (internal field)   - to call IRenderer.Render per phrase instead of RenderMixdown
///   UVoicePart.phraseGeneration        (internal field)   - generation of the newest phrase build requested for the part
///   UVoicePart.WaitPhraseSource(TimeSpan) (internal)      - blocks until the async PhraseSourceBuilder applied that generation
/// Everything else (IRenderer, RenderPhrase.hash/Layout/phones, UVoicePart.renderPhrases, PhonemesUpToDate) is public.
/// Why reflection and not [assembly: IgnoresAccessChecksTo]: Roslyn does not honour the attribute at compile time, so the generator
/// package would be needed to rewrite a reference assembly; three reflected members are less moving parts.
/// </summary>
public static class OuInternals
{
    const BindingFlags NP = BindingFlags.NonPublic | BindingFlags.Public | BindingFlags.Instance;
    static readonly FieldInfo rendererField = typeof(RenderPhrase).GetField("renderer", NP) ?? throw Missing("RenderPhrase.renderer");
    static readonly FieldInfo generationField = typeof(UVoicePart).GetField("phraseGeneration", NP) ?? throw Missing("UVoicePart.phraseGeneration");
    static readonly FieldInfo notesTimestampField = typeof(UVoicePart).GetField("notesTimestamp", NP) ?? throw Missing("UVoicePart.notesTimestamp");
    static readonly FieldInfo phonemesTimestampField = typeof(UVoicePart).GetField("phonemesTimestamp", NP) ?? throw Missing("UVoicePart.phonemesTimestamp");
    static readonly MethodInfo waitMethod = typeof(UVoicePart).GetMethod("WaitPhraseSource", NP) ?? throw Missing("UVoicePart.WaitPhraseSource");

    static Exception Missing(string what) => new MissingMemberException("OpenUtau.Core internal changed, cannot find " + what);

    /// <summary>Forces the static constructor (and thus the reflection lookups) to run.</summary>
    public static void SelfCheck() { _ = rendererField; _ = notesTimestampField; _ = phonemesTimestampField; }

    public static IRenderer RendererOf(RenderPhrase p) => (IRenderer)rendererField.GetValue(p)!;
    public static long GenerationOf(UVoicePart p) => (long)generationField.GetValue(p)!;
    public static bool WaitPhraseSource(UVoicePart p, TimeSpan timeout) => (bool)waitMethod.Invoke(p, new object[] { timeout })!;

    /// <summary>
    /// Makes <see cref="UVoicePart.PhonemesUpToDate"/> false, so a direct validate of a temporary (audition) part runs the
    /// phoneme pass but does not hand a throwaway phrase build to the shared PhraseSourceBuilder.
    /// </summary>
    public static void MarkPhonemesStale(UVoicePart p)
    {
        notesTimestampField.SetValue(p, 1L);
        phonemesTimestampField.SetValue(p, 0L);
    }

    public static RenderPhrase[] PhrasesOf(UVoicePart p)
    {
        lock (p) return p.renderPhrases.ToArray();
    }
}
