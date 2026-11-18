using System.Reflection;
using System.Text.Json;
using OpenUtau.Core.DiffSinger;
using OpenUtau.Core.Render;
using Serilog;

namespace PawUtau.Engine;

/// <summary>
/// SynthV-style automatic pitch: a renderer with a pitch model (DiffSinger dspitch) sings its own AI pitch, and the
/// user's pitch deviation (PITD) is applied ON TOP of it. Stock OpenUtau renders the flat note pitch + PITD and only
/// uses the pitch model when the user bakes it ("Load rendered pitch").
///
/// The live phrase is never mutated: a MemberwiseClone gets the new pitch array and a masked hash (the same trick as
/// OpenUtau's xsy variants), so the renderer's own disk cache keeps AI and manual renders apart while the scheduler
/// keeps identifying the phrase by its original hash.
///
/// Takes: the pitch model is a diffusion sampler with no seed, so every call draws a new melody. Each phrase
/// content (<see cref="TakeKey"/>) owns a set of takes and a current one; the set is persisted under the engine cache
/// (ai-takes/), so a melody stays the same across edits of other phrases, pitch edits and sessions until the user asks
/// for a retake (whole phrase or selected notes, OpenUtau's partial retake) or picks another take.
/// </summary>
static class AiPitch
{
    const ulong HashMask = 0x4149504954434831; // "AIPITCH1"
    const int PitchInterval = 5;               // RenderPhrase.pitches spacing in ticks
    public const int MaxTakesPerPhrase = 16;

    static readonly MethodInfo cloneMethod =
        typeof(object).GetMethod("MemberwiseClone", BindingFlags.NonPublic | BindingFlags.Instance)!;
    static readonly FieldInfo pitchesField =
        typeof(RenderPhrase).GetField("pitches", BindingFlags.Public | BindingFlags.Instance)
        ?? throw new MissingMemberException("OpenUtau.Core internal changed, cannot find RenderPhrase.pitches");
    static readonly PropertyInfo hashProp =
        typeof(RenderPhrase).GetProperty("hash", BindingFlags.Public | BindingFlags.Instance)
        ?? throw new MissingMemberException("OpenUtau.Core internal changed, cannot find RenderPhrase.hash");

    public static void SelfCheck() { _ = pitchesField; _ = hashProp; }

    /// <summary>Where take sets are persisted (set at bootstrap; null = memory only).</summary>
    public static string? Directory;

    sealed class TakeSet
    {
        public readonly List<RenderPitchResult> Takes = new();
        public int Current;
    }

    sealed class TakeFile
    {
        public int Current { get; set; }
        public List<TakeData> Takes { get; set; } = new();
    }

    sealed class TakeData
    {
        public float[] Ticks { get; set; } = Array.Empty<float>();
        public float[] Tones { get; set; } = Array.Empty<float>();
        public bool[]? Voiced { get; set; }
    }

    static readonly System.Collections.Concurrent.ConcurrentDictionary<ulong, TakeSet> sets = new();
    const int MaxSets = 4096;

    /// <summary>Everything the model sees except the user's deviation: phones (preEffectHash) + base pitch (notes,
    /// transitions, vibrato).</summary>
    public static ulong TakeKey(RenderPhrase src)
    {
        var bytes = new byte[8 + src.pitchesBeforeDeviation.Length * 4];
        BitConverter.TryWriteBytes(bytes.AsSpan(0, 8), src.preEffectHash);
        Buffer.BlockCopy(src.pitchesBeforeDeviation, 0, bytes, 8, src.pitchesBeforeDeviation.Length * 4);
        return K4os.Hash.xxHash.XXH64.DigestOf(bytes);
    }

    static string? PathOf(ulong key) => Directory == null ? null : Path.Combine(Directory, $"{key:x16}.json");

    static TakeSet? Load(ulong key)
    {
        var path = PathOf(key);
        if (path == null || !File.Exists(path)) return null;
        try
        {
            var f = JsonSerializer.Deserialize<TakeFile>(File.ReadAllText(path));
            if (f == null || f.Takes.Count == 0) return null;
            var set = new TakeSet();
            foreach (var t in f.Takes) set.Takes.Add(new RenderPitchResult { ticks = t.Ticks, tones = t.Tones, voiced = t.Voiced });
            set.Current = Math.Clamp(f.Current, 0, set.Takes.Count - 1);
            return set;
        }
        catch (Exception e)
        {
            Log.Warning("AI take file {Path} unreadable: {Message}", path, e.Message);
            return null;
        }
    }

    static void Save(ulong key, TakeSet set)
    {
        var path = PathOf(key);
        if (path == null) return;
        try
        {
            System.IO.Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var f = new TakeFile { Current = set.Current };
            foreach (var t in set.Takes) f.Takes.Add(new TakeData { Ticks = t.ticks, Tones = t.tones, Voiced = t.voiced });
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(f));
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception e) { Log.Warning("AI take file {Path} not saved: {Message}", path, e.Message); }
    }

    static TakeSet? GetSet(ulong key)
    {
        if (sets.TryGetValue(key, out var s)) return s;
        s = Load(key);
        if (s == null) return null;
        if (sets.Count >= MaxSets) sets.Clear();
        return sets.GetOrAdd(key, s);
    }

    /// <summary>Take set key of a unison voice: the lead (0) uses the phrase content key, doubles their own sets.</summary>
    static ulong VoiceKey(RenderPhrase src, int voice) =>
        voice == 0 ? TakeKey(src) : TakeKey(src) ^ (0x9E3779B97F4A7C15UL * (ulong)voice);

    /// <summary>The current take of the phrase, predicting (and persisting) the first one when there is none.</summary>
    static RenderPitchResult? Current(IRenderer renderer, RenderPhrase src, int voice = 0)
    {
        ulong key = VoiceKey(src, voice);
        var set = GetSet(key);
        if (set != null) lock (set) return set.Takes[set.Current];
        var rp = renderer.LoadRenderedPitch(src);
        if (rp == null) return null;
        set = new TakeSet();
        set.Takes.Add(rp);
        if (sets.Count >= MaxSets) sets.Clear();
        set = sets.GetOrAdd(key, set);
        lock (set) { Save(key, set); return set.Takes[set.Current]; }
    }

    /// <summary>(current, count) for the phrase; (0, 0) when no take exists yet.</summary>
    public static (int Current, int Count) Info(RenderPhrase src)
    {
        var set = GetSet(TakeKey(src));
        if (set == null) return (0, 0);
        lock (set) return (set.Current, set.Takes.Count);
    }

    /// <summary>
    /// A new take becomes the current one. <paramref name="notePositions"/> (absolute note ticks) limits it to
    /// those notes, the rest keeping the current take (OpenUtau's partial retake); null or every note = the whole phrase.
    /// </summary>
    public static bool Retake(IRenderer renderer, RenderPhrase src, HashSet<int>? notePositions)
    {
        if (!renderer.SupportsRenderPitch || src.pitchesBeforeDeviation == null) return false;
        ulong key = TakeKey(src);
        var cur = Current(renderer, src);
        RenderPitchResult? next;
        if (notePositions != null && notePositions.Count > 0 && cur != null && renderer is DiffSingerRenderer ds)
        {
            // the existing pitch the partial retake keeps: the current take, without the user's deviation
            var basis = Clone(src, AiCents(src, cur, withDeviation: false), src.hash);
            next = ds.LoadRenderedPitch(basis, notePositions);
        }
        else
        {
            next = renderer.LoadRenderedPitch(src);
        }
        if (next?.tones == null || next.ticks == null) return false;
        var set = GetSet(key)!;
        lock (set)
        {
            set.Takes.Add(next);
            while (set.Takes.Count > MaxTakesPerPhrase) set.Takes.RemoveAt(0);
            set.Current = set.Takes.Count - 1;
            Save(key, set);
        }
        return true;
    }

    /// <summary>Make take <paramref name="index"/> (0-based, clamped) current. True when it changed.</summary>
    public static bool Select(RenderPhrase src, int index)
    {
        ulong key = TakeKey(src);
        var set = GetSet(key);
        if (set == null) return false;
        lock (set)
        {
            int i = Math.Clamp(index, 0, set.Takes.Count - 1);
            if (i == set.Current) return false;
            set.Current = i;
            Save(key, set);
            return true;
        }
    }

    /// <summary>Forget every take (tests).</summary>
    public static void ClearMemory() { sets.Clear(); timbres.Clear(); }

    // ---- timbre takes (Phase 5 A2) -------------------------------------------------------------------------------------------
    // DiffSinger's variance and acoustic models sample at random, but OpenUtau caches their results keyed by the exact inputs,
    // so a phrase always sounds the same. A timbre take k > 0 adds k * TimbreStep cents to the pitch input: inaudible, but a
    // different input, so the models sample anew (and that sample is cached for take k). Persisted per phrase content like
    // pitch takes (<key>.timbre.json: current, count).
    const float TimbreStep = 0.004f;
    sealed class TimbreSet { public int Current { get; set; } public int Count { get; set; } = 1; }
    static readonly System.Collections.Concurrent.ConcurrentDictionary<ulong, TimbreSet> timbres = new();

    static TimbreSet Timbre(ulong key)
    {
        if (timbres.TryGetValue(key, out var t)) return t;
        t = new TimbreSet();
        var path = Directory == null ? null : Path.Combine(Directory, $"{key:x16}.timbre.json");
        if (path != null && File.Exists(path))
        {
            try { t = JsonSerializer.Deserialize<TimbreSet>(File.ReadAllText(path)) ?? t; } catch { }
        }
        return timbres.GetOrAdd(key, t);
    }

    static void SaveTimbre(ulong key, TimbreSet t)
    {
        if (Directory == null) return;
        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            File.WriteAllText(Path.Combine(Directory, $"{key:x16}.timbre.json"), JsonSerializer.Serialize(t));
        }
        catch (Exception e) { Log.Warning("timbre take not saved: {Message}", e.Message); }
    }

    public static (int Current, int Count) TimbreInfo(RenderPhrase src)
    {
        var t = Timbre(TakeKey(src));
        lock (t) return (t.Current, t.Count);
    }

    /// <summary>A new timbre take becomes current.</summary>
    public static bool RetakeTimbre(RenderPhrase src)
    {
        ulong key = TakeKey(src);
        var t = Timbre(key);
        lock (t) { t.Count++; t.Current = t.Count - 1; SaveTimbre(key, t); }
        return true;
    }

    public static bool SelectTimbre(RenderPhrase src, int index)
    {
        ulong key = TakeKey(src);
        var t = Timbre(key);
        lock (t)
        {
            int i = Math.Clamp(index, 0, t.Count - 1);
            if (i == t.Current) return false;
            t.Current = i;
            SaveTimbre(key, t);
            return true;
        }
    }

    /// <summary>The phrase with its current timbre take applied (unchanged for take 0). <paramref name="src"/> is the
    /// original phrase (its content key), <paramref name="phrase"/> the one about to render (AI pitch / unison voice).</summary>
    public static RenderPhrase WithTimbre(RenderPhrase src, RenderPhrase phrase)
    {
        if (phrase.pitches == null) return phrase;
        var t = Timbre(TakeKey(src));
        int k;
        lock (t) k = t.Current;
        if (k <= 0) return phrase;
        var pitches = new float[phrase.pitches.Length];
        for (int i = 0; i < pitches.Length; i++) pitches[i] = phrase.pitches[i] + k * TimbreStep;
        return Clone(phrase, pitches, phrase.hash ^ (0x54494D4252450000UL + (ulong)k));   // "TIMBRE" + k
    }

    /// <summary>The phrase to render: AI pitch + the user's deviation, or <paramref name="src"/> when unavailable.</summary>
    public static RenderPhrase Apply(IRenderer renderer, RenderPhrase src, int voice = 0)
    {
        if (!renderer.SupportsRenderPitch || src.pitches == null || src.pitchesBeforeDeviation == null) return src;
        RenderPitchResult? rp;
        try { rp = Current(renderer, src, voice); }
        catch (Exception e)
        {
            Log.Warning("AI pitch unavailable for phrase {Hash:x16}: {Message}", src.hash, e.Message);
            return src;
        }
        if (rp?.tones == null || rp.ticks == null || rp.tones.Length < 2 || rp.ticks.Length != rp.tones.Length) return src;
        // the take is part of the render identity: another take must not hit the renderer's disk cache of this one
        ulong takeId = K4os.Hash.xxHash.XXH64.DigestOf(System.Runtime.InteropServices.MemoryMarshal.AsBytes(rp.tones.AsSpan()));
        return Clone(src, AiCents(src, rp, withDeviation: true), src.hash ^ HashMask ^ takeId);
    }

    /// <summary>The phrase's pitch curve (cents, every 5 ticks) from a take, plus the user's deviation when asked.</summary>
    static float[] AiCents(RenderPhrase src, RenderPitchResult rp, bool withDeviation)
    {
        var pitches = new float[src.pitches.Length];
        int k = 0;
        for (int i = 0; i < pitches.Length; i++)
        {
            float deviation = withDeviation && i < src.pitchesBeforeDeviation.Length ? src.pitches[i] - src.pitchesBeforeDeviation[i] : 0;
            float basePitch = withDeviation ? src.pitches[i] : (i < src.pitchesBeforeDeviation.Length ? src.pitchesBeforeDeviation[i] : src.pitches[i]);
            // pitches[i] sits at phrase-relative tick 5*i - leading; LoadRenderedPitch ticks are phrase-relative too
            double t = (double)i * PitchInterval - src.leading;
            while (k + 1 < rp.ticks.Length && rp.ticks[k + 1] <= t) k++;
            bool voiced = rp.voiced == null || k >= rp.voiced.Length || rp.voiced[k];
            if (!voiced || t < rp.ticks[0] || t > rp.ticks[^1])
            {
                pitches[i] = basePitch;               // outside the model's output / unvoiced: keep the note pitch
                continue;
            }
            double ai = rp.tones[k];
            if (k + 1 < rp.ticks.Length && rp.ticks[k + 1] > rp.ticks[k])
            {
                double f = (t - rp.ticks[k]) / (rp.ticks[k + 1] - rp.ticks[k]);
                ai += (rp.tones[k + 1] - rp.tones[k]) * Math.Clamp(f, 0, 1);
            }
            pitches[i] = (float)(ai * 100.0) + deviation;
        }
        return pitches;
    }

    /// <summary>The phrase sung <paramref name="cents"/> higher (track pitch shift), with a hash of its own.</summary>
    public static RenderPhrase Shifted(RenderPhrase src, int cents)
    {
        if (src.pitches == null || cents == 0) return src;
        var pitches = new float[src.pitches.Length];
        for (int i = 0; i < pitches.Length; i++) pitches[i] = src.pitches[i] + cents;
        return Clone(src, pitches, src.hash ^ (0x5348494654000000UL + (ulong)(cents + 100)));   // "SHIFT" + cents
    }

    /// <summary>A unison voice: the phrase detuned by <paramref name="cents"/>, with a hash of its own.</summary>
    public static RenderPhrase Detuned(RenderPhrase src, double cents, int voice)
    {
        if (src.pitches == null || (cents == 0 && voice == 0)) return src;
        var pitches = new float[src.pitches.Length];
        for (int i = 0; i < pitches.Length; i++) pitches[i] = src.pitches[i] + (float)cents;
        ulong salt = 0xC2B2AE3D27D4EB4FUL * (ulong)(voice + 1) ^ (ulong)BitConverter.DoubleToInt64Bits(cents);
        return Clone(src, pitches, src.hash ^ salt);
    }

    static RenderPhrase Clone(RenderPhrase src, float[] pitches, ulong hash)
    {
        var copy = (RenderPhrase)cloneMethod.Invoke(src, null)!;
        pitchesField.SetValue(copy, pitches);
        hashProp.SetValue(copy, hash);
        return copy;
    }
}
