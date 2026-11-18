using OpenUtau.Api;
using OpenUtau.Core;
using OpenUtau.Core.Render;
using OpenUtau.Core.Ustx;
using OpenUtau.Core.Util;
using PawUtau.Protocol;
using Log = Serilog.Log;
using ProtoPhraseLayout = PawUtau.Protocol.PhraseLayout;
using RenderProgress = OpenUtau.Core.Render.Progress;

namespace PawUtau.Engine;

/// <summary>
/// Renders OpenUtau phrases one at a time and pushes them to the extension as PhraseAudio frames.
///
/// Placement : a phrase's audio starts at <see cref="RenderPhrase.Layout"/>.StartMs, i.e.
/// <c>renderer.Layout(phrase).positionMs - leadingMs</c> -- the slot offset RenderEngine itself uses when mixing, so
/// sample 0 sits before the first note by the renderer's leading pre-utterance (preutterance for classic, the model head
/// for DiffSinger). The first sample is therefore heard exactly where paw plays the note.
///
/// Audio is cached per (trackId, RenderPhrase.hash). The hash is a content hash (singer, renderer, wavtool, phonemes,
/// curves, tempo-map stamp), so an unchanged phrase is never re-rendered and survives a move in time (only startSec changes).
///
/// PhraseLayout is sent before any PhraseAudio of a new hash and on every state change. While a part is being
/// re-phonemized its previous entries stay in the layout as placeholders (state Rendering), which is what lets the
/// extension keep the old clip audible (stale-while-revalidate).
/// </summary>
public sealed class RenderScheduler : IDisposable
{
    const uint SampleRate = 44100;
    const int TickStep = Proto.CurveGridTicks;
    const long MaxCachedSamples = 40L * 1024 * 1024;   // ~15 min of mono f32; LRU beyond that

    sealed class CachedAudio
    {
        public float[] Samples = Array.Empty<float>();
        public byte Channels = 1;               // 2 = interleaved stereo (unison)
        public bool Sent;
        public double SentStartSec = double.NaN;
    }

    sealed class PhraseEntry
    {
        public string PartId = "";
        public ulong Hash;
        public double StartSec, EndSec;
        public RenderPhrase Phrase = null!;
        public UVoicePart Part = null!;
    }

    sealed class PartRuntime
    {
        public string PartId = "";
        public UVoicePart? Part;
        public List<PhraseEntry> Entries = new();
        public bool Waiting;      // phonemization / phrase build in flight: keep the old entries as placeholders
        public long Token;
    }

    sealed class TrackRuntime
    {
        public string Id = "";
        public readonly Dictionary<string, PartRuntime> Parts = new();
        public readonly Dictionary<ulong, CachedAudio> Cache = new();
        public readonly Dictionary<ulong, byte> States = new();   // hash -> PhraseStateKind
        public readonly HashSet<(ulong Hash, byte Quality)> Active = new();
        public ulong Seq;
        /// <summary>No PhraseLayout has been sent for this track yet (new connection / new track). Keeps old clips alive
        /// across an engine restart until the first real phrase list is known (protocol section 7.2, rule 4).</summary>
        public bool Quiet = true;
    }

    sealed class RenderJob
    {
        public string TrackId = "";
        public string PartId = "";
        public ulong Hash;
        public UVoicePart Part = null!;
        public RenderPhrase Phrase = null!;
        public double StartSec, EndSec;
        public byte Quality = PawUtau.Protocol.Quality.Final;
        public ulong Seq;
        /// <summary>DiffSinger job: OpenUtau serializes DiffSinger renders behind a static lock, so at most one runs.</summary>
        public bool IsDs;
        public readonly CancellationTokenSource Cts = new();
        public readonly DateTime Created = DateTime.UtcNow;
        public volatile bool Cancelled;
        /// <summary>Replaced by a newer job for the same hash (a retake): its Active slot belongs to the new job.</summary>
        public bool Superseded;

        public double Distance(double playheadSec)
        {
            if (playheadSec >= StartSec && playheadSec <= EndSec) return 0;
            return Math.Min(Math.Abs(StartSec - playheadSec), Math.Abs(EndSec - playheadSec));
        }
    }

    readonly IEngineConnection conn;
    readonly object gate = new();
    readonly Dictionary<string, TrackRuntime> tracks = new();
    readonly List<RenderJob> queue = new();
    readonly HashSet<RenderJob> running = new(ReferenceEqualityComparer.Instance);
    readonly List<Thread> workers = new();
    /// <summary>DiffSinger jobs being rendered (0 or 1). Only one is let through: OpenUtau's DiffSinger renderer holds a static
    /// lock anyway, a second one would just park a worker that classic phrases or other tracks could use, and the
    /// temporary DiffSinger step override in Preferences must not be changed under a running render.</summary>
    int dsInFlight;
    readonly HashSet<UVoicePart> waitingParts = new(ReferenceEqualityComparer.Instance);

    volatile bool stopping;
    SetRenderPolicy policy = new();
    volatile bool playing;
    double playheadSec;
    double editCursorSec;

    /// <summary>Per track: render with the renderer's AI pitch as the base (set by the session from the track config).</summary>
    public Func<string, bool>? AiPitchFor;
    /// <summary>Per track: unison settings (null = one voice).</summary>
    public Func<string, UnisonSettings?>? UnisonFor;
    /// <summary>Per track: pitch shift in cents added to the sung pitch (track option pitchshift).</summary>
    public Func<string, int>? PitchShiftFor;

    public RenderScheduler(IEngineConnection conn)
    {
        this.conn = conn;
        for (int i = 0; i < WorkerCount; i++)
        {
            var t = new Thread(WorkerLoop) { IsBackground = true, Name = $"paw-utau-render-{i}" };
            workers.Add(t);
            t.Start();
        }
    }

    /// <summary>Render workers: PAW_UTAU_RENDER_WORKERS, else 2..4 by core count. One may run DiffSinger, the others take
    /// classic phrases and other tracks so they never queue behind a multi-second DiffSinger render.</summary>
    public static int WorkerCount
    {
        get
        {
            if (int.TryParse(Environment.GetEnvironmentVariable("PAW_UTAU_RENDER_WORKERS"), out var n) && n > 0) return Math.Min(n, 16);
            return Math.Clamp(Environment.ProcessorCount / 4, 2, 4);
        }
    }

    // ---- policy / transport -----------------------------------------------------------------------------------------------
    public SetRenderPolicy Policy
    {
        get { lock (gate) return policy; }
        set { lock (gate) policy = value; }
    }

    public void SetTransport(Transport t)
    {
        playing = t.Playing;
        playheadSec = t.PosSec;
        editCursorSec = t.EditCursorSec;
    }

    /// <summary>Full SyncProject / new connection: the logical layout restarts, the cache is dropped.</summary>
    public void Reset(ulong seq)
    {
        lock (gate)
        {
            foreach (var job in queue) Cancel(job);
            queue.Clear();
            tracks.Clear();
            waitingParts.Clear();
            Monitor.PulseAll(gate);
        }
    }

    public bool IsWaiting(UVoicePart part) { lock (gate) return waitingParts.Contains(part); }

    // ---- inputs from the session (pump thread) ----------------------------------------------------------------------------
    /// <summary>The part changed and needs a phrase build once phonemization is done. Old entries stay as placeholders.</summary>
    public void MarkPartWaiting(string trackId, string partId, UVoicePart part, ulong seq)
    {
        lock (gate)
        {
            var tr = Track(trackId, seq);
            var pr = Part(tr, partId);
            pr.Token++;
            pr.Waiting = true;
            pr.Part = part;
            waitingParts.Add(part);
            PublishLayout(tr);
        }
    }

    /// <summary>Phonemes for the part are up to date: snapshot the phrases off the pump and render what is new.</summary>
    public void SchedulePart(string trackId, string partId, UVoicePart part, ulong seq)
    {
        long token;
        lock (gate)
        {
            var tr = Track(trackId, seq);
            var pr = Part(tr, partId);
            token = ++pr.Token;
            pr.Part = part;
            pr.Waiting = false;
            tr.Seq = seq;
            waitingParts.Remove(part);
            foreach (var job in queue)
                if (job.TrackId == trackId && job.PartId == partId && !JobStillWanted(tr, job)) Cancel(job);
            queue.RemoveAll(j => j.Cancelled);
            Monitor.PulseAll(gate);
        }
        Task.Run(() =>
        {
            // Blocks this pool thread, never the pump: the phrase builder posts its result to the pump.
            if (!OuInternals.WaitPhraseSource(part, TimeSpan.FromSeconds(30)))
                Log.Warning("phrase build for part {Part} did not finish in time", partId);
            ApplyPartPhrases(trackId, partId, token, part, OuInternals.PhrasesOf(part), seq);
        });
    }

    public void RemovePart(string partId)
    {
        lock (gate)
        {
            foreach (var tr in tracks.Values)
            {
                if (!tr.Parts.Remove(partId)) continue;
                foreach (var job in queue) if (job.PartId == partId) Cancel(job);
                queue.RemoveAll(j => j.Cancelled);
                PublishLayout(tr);
            }
        }
    }

    public void RemoveTrack(string trackId)
    {
        lock (gate)
        {
            if (!tracks.Remove(trackId, out var tr)) return;
            foreach (var job in queue) if (job.TrackId == trackId) Cancel(job);
            queue.RemoveAll(j => j.Cancelled);
            _ = tr;
        }
    }

    /// <summary>
    /// Drop cached audio for a track (track config change / Invalidate) and keep the previous phrases in the layout as
    /// Pending placeholders until the caller replaces them with a new phrase snapshot. This is the stale-while-revalidate
    /// path: old clips stay audible while the new renderer/singer works.
    /// </summary>
    public void InvalidateTrack(string trackId)
    {
        lock (gate)
        {
            if (!tracks.TryGetValue(trackId, out var tr)) return;
            tr.Cache.Clear();
            tr.States.Clear();
            foreach (var job in queue) if (job.TrackId == trackId) Cancel(job);
            queue.RemoveAll(j => j.Cancelled);
            foreach (var pr in tr.Parts.Values) { pr.Waiting = true; pr.Token++; }
            PublishLayout(tr);
        }
    }

    /// <summary>Invalidate one part: forget its phrases and its cached audio, re-render once the caller re-phonemizes.</summary>
    /// <summary>The phrases of a part as currently scheduled: (scheduler hash, phrase).</summary>
    public List<(ulong Hash, RenderPhrase Phrase)> PhrasesOf(string trackId, string partId)
    {
        lock (gate)
        {
            if (!tracks.TryGetValue(trackId, out var tr) || !tr.Parts.TryGetValue(partId, out var pr)) return new();
            return pr.Entries.Select(e => (e.Hash, e.Phrase)).ToList();
        }
    }

    /// <summary>
    /// Render these phrases again although their content hash is unchanged (an AI pitch retake / take change): drop
    /// their audio, cancel queued and running renders (a running one would bring back the old take) and enqueue them.
    /// </summary>
    public void InvalidatePhrases(string trackId, IReadOnlyCollection<ulong> hashes)
    {
        lock (gate)
        {
            if (!tracks.TryGetValue(trackId, out var tr)) return;
            var set = new HashSet<ulong>(hashes);
            foreach (var job in queue.Concat(running))
                if (job.TrackId == trackId && set.Contains(job.Hash)) { Cancel(job); job.Superseded = true; }
            queue.RemoveAll(j => j.Cancelled);
            foreach (var h in set)
            {
                tr.Cache.Remove(h);
                tr.Active.Remove((h, Quality.Draft));
                tr.Active.Remove((h, Quality.Final));
                tr.States[h] = PhraseStateKind.Pending;
            }
            foreach (var e in tr.Parts.Values.SelectMany(p => p.Entries).Where(e => set.Contains(e.Hash)).GroupBy(e => e.Hash).Select(g => g.First()))
                EnsureAudio(tr, e);
            PublishLayout(tr);
        }
    }

    public void InvalidatePart(string trackId, string partId)
    {
        lock (gate)
        {
            if (!tracks.TryGetValue(trackId, out var tr) || !tr.Parts.TryGetValue(partId, out var pr)) return;
            foreach (var e in pr.Entries) tr.Cache.Remove(e.Hash);
            pr.Entries.Clear();
            pr.Waiting = true;
            pr.Token++;
            foreach (var job in queue) if (job.TrackId == trackId && job.PartId == partId) Cancel(job);
            queue.RemoveAll(j => j.Cancelled);
            PublishLayout(tr);
        }
    }

    /// <summary>Tempo map changed: every start time and phrase hash changed. Keep the old entries as placeholders, drop audio.</summary>
    public void InvalidateAllCaches()
    {
        lock (gate)
        {
            foreach (var tr in tracks.Values)
            {
                tr.Cache.Clear();
                tr.States.Clear();
                foreach (var job in queue) if (job.TrackId == tr.Id) Cancel(job);
                foreach (var pr in tr.Parts.Values) { pr.Waiting = true; pr.Token++; }
                PublishLayout(tr);
            }
            queue.RemoveAll(j => j.Cancelled);
        }
    }

    // ---- phrase snapshots --------------------------------------------------------------------------------------------------
    void ApplyPartPhrases(string trackId, string partId, long token, UVoicePart part, RenderPhrase[] phrases, ulong seq)
    {
        var now = new List<PhraseEntry>(phrases.Length);
        foreach (var p in phrases)
            now.Add(new PhraseEntry
            {
                PartId = partId, Hash = p.hash, StartSec = p.Layout.StartMs / 1000.0, EndSec = p.Layout.EndMs / 1000.0,
                Phrase = p, Part = part,
            });

        lock (gate)
        {
            if (!tracks.TryGetValue(trackId, out var tr)) return;
            if (!tr.Parts.TryGetValue(partId, out var pr) || pr.Token != token) return;   // superseded
            pr.Entries = now;
            pr.Waiting = false;
            pr.Part = part;
            tr.Seq = seq;
            waitingParts.Remove(part);
            foreach (var job in queue)
                if (job.TrackId == trackId && job.PartId == partId && !now.Any(e => e.Hash == job.Hash)) Cancel(job);
            queue.RemoveAll(j => j.Cancelled);
            foreach (var e in now) EnsureAudio(tr, e);
            PublishLayout(tr, hasPhrases: true);
            Monitor.PulseAll(gate);
        }
    }

    /// <summary>Sends the cached audio of an entry (a phrase that only moved), otherwise queues a render.</summary>
    void EnsureAudio(TrackRuntime tr, PhraseEntry e)
    {
        if (tr.Cache.TryGetValue(e.Hash, out var cached) && cached.Samples.Length > 0)
        {
            if (cached.Sent && Math.Abs(cached.SentStartSec - e.StartSec) < 1e-6) return;
            cached.Sent = true;
            cached.SentStartSec = e.StartSec;
            tr.States[e.Hash] = PhraseStateKind.Final;
            SendAudio(tr, e, cached.Samples, Quality.Final, tr.Seq, cached.Channels);
            return;
        }
        if (tr.Active.Contains((e.Hash, Quality.Final)) || tr.Active.Contains((e.Hash, Quality.Draft))) return;
        // Fast draft for DiffSinger: every phrase without audio is "the first render after an edit" (or is needed while playing),
        // so draft first whenever the policy enables it; the final pass follows after finalDelayMs of idle time.
        bool draft = policy.DraftWhilePlaying && policy.DsDraftSteps > 0
            && OuInternals.RendererOf(e.Phrase).SingerType == USingerType.DiffSinger;
        Enqueue(tr, e, draft ? Quality.Draft : Quality.Final);
    }

    void Enqueue(TrackRuntime tr, PhraseEntry e, byte quality, bool force = false)
    {
        if (stopping) return;
        if (!force && tr.Active.Contains((e.Hash, quality))) return;
        tr.Active.Add((e.Hash, quality));
        var job = new RenderJob
        {
            TrackId = tr.Id, PartId = e.PartId, Hash = e.Hash, Part = e.Part, Phrase = e.Phrase,
            StartSec = e.StartSec, EndSec = e.EndSec, Quality = quality, Seq = tr.Seq,
            IsDs = OuInternals.RendererOf(e.Phrase).SingerType == USingerType.DiffSinger,
        };
        bool hadDraft = tr.States.TryGetValue(e.Hash, out var st) && st == PhraseStateKind.Draft;
        if (!(quality == Quality.Final && hadDraft)) tr.States[e.Hash] = PhraseStateKind.Pending;
        queue.Add(job);
        PublishLayout(tr);
        Monitor.PulseAll(gate);
    }

    static bool JobStillWanted(TrackRuntime tr, RenderJob job) =>
        tr.Parts.Values.Any(p => p.Entries.Any(e => e.Hash == job.Hash));

    static void Cancel(RenderJob job)
    {
        job.Cancelled = true;
        try { job.Cts.Cancel(); } catch (ObjectDisposedException) { }
    }

    // ---- worker ------------------------------------------------------------------------------------------------------------
    void WorkerLoop()
    {
        while (true)
        {
            RenderJob? job = null;
            lock (gate)
            {
                if (stopping) return;
                queue.RemoveAll(j => j.Cancelled);
                if (queue.Count == 0) { Monitor.Wait(gate, 100); continue; }
                double head = playing ? playheadSec : editCursorSec;
                double best = double.MaxValue;
                int bestAt = -1;
                for (int i = 0; i < queue.Count; i++)
                {
                    var j = queue[i];
                    if (tracks.TryGetValue(j.TrackId, out var trj) && j.Seq < trj.Seq) j.Seq = trj.Seq;   // newer state, same content
                    if (j.IsDs && dsInFlight > 0) continue;   // leave it for the worker that finishes the running DiffSinger job
                    double d = j.Distance(head);
                    if (d < best) { best = d; bestAt = i; }
                }
                if (bestAt < 0) { Monitor.Wait(gate, 100); continue; }
                job = queue[bestAt];
                queue.RemoveAt(bestAt);
                running.Add(job);
                if (job.IsDs) dsInFlight++;
                if (tracks.TryGetValue(job.TrackId, out var tr) &&
                    (!tr.States.TryGetValue(job.Hash, out var st) || st != PhraseStateKind.Draft))
                {
                    tr.States[job.Hash] = PhraseStateKind.Rendering;
                    PublishLayout(tr);
                }
            }
            RenderOne(job);
        }
    }

    void RenderOne(RenderJob job)
    {
        var cts = job.Cts;
        try
        {
            var renderer = OuInternals.RendererOf(job.Phrase);
            bool isDs = renderer.SingerType == USingerType.DiffSinger;
            byte quality = job.Quality;
            int steps;
            lock (gate) steps = quality == Quality.Draft ? policy.DsDraftSteps : policy.DsFinalSteps;

            var progress = new RenderProgress(Math.Max(1, job.Phrase.phones.Length));
            // SynthV-style automatic pitch (track option pitchmode, on by default for renderers with a pitch model)
            var sw = System.Diagnostics.Stopwatch.StartNew();
            bool ai = AiPitchFor?.Invoke(job.TrackId) ?? false;
            int shift = PitchShiftFor?.Invoke(job.TrackId) ?? 0;
            var phrase = AiPitch.Shifted(AiPitch.WithTimbre(job.Phrase, ai ? AiPitch.Apply(renderer, job.Phrase) : job.Phrase), shift);
            long aiMs = sw.ElapsedMilliseconds;
            var res = RenderWith(renderer, phrase, job, progress, isDs && steps > 0 ? steps : 0, cts);
            Log.Information("timing phrase {Hash:x16} q={Quality} phones={Phones} ai={Ai}ms render={Render}ms queued={Queued}ms",
                job.Hash, quality, job.Phrase.phones.Length, aiMs, sw.ElapsedMilliseconds - aiMs,
                (long)(DateTime.UtcNow - job.Created).TotalMilliseconds - sw.ElapsedMilliseconds);
            if (job.Cancelled || cts.IsCancellationRequested || res?.samples == null || res.samples.Length == 0) return;

            var samples = res.samples;
            byte channels = 1;
            // unison: the final pass adds the doubles (drafts stay the lead alone, so edits answer quickly)
            var uni = UnisonFor?.Invoke(job.TrackId);
            if (uni != null && quality == Quality.Final)
            {
                var swU = System.Diagnostics.Stopwatch.StartNew();
                var mixed = Unison.Mix(uni, samples, (int)SampleRate,
                    v => AiPitch.Detuned(AiPitch.Shifted(AiPitch.WithTimbre(job.Phrase, ai ? AiPitch.Apply(renderer, job.Phrase, v) : job.Phrase), shift), Unison.Voice(uni, v).Cents, v),
                    p => RenderWith(renderer, p, job, progress, isDs && steps > 0 ? steps : 0, cts)?.samples,
                    () => job.Cancelled || cts.IsCancellationRequested);
                if (mixed == null) return;
                samples = mixed;
                channels = 2;
                Log.Information("unison phrase {Hash:x16}: {Voices} voices in {Ms} ms", job.Hash, uni.Voices, swU.ElapsedMilliseconds);
            }

            lock (gate)
            {
                if (job.Cancelled || !tracks.TryGetValue(job.TrackId, out var tr)) return;
                // The part may have moved while this phrase rendered; the hash says the content is unchanged, so take
                // the current placement (startSec = project time of sample 0, from the phrase's Layout).
                var entry = tr.Parts.Values.SelectMany(p => p.Entries).FirstOrDefault(x => x.Hash == job.Hash);
                if (entry == null) return;
                if (quality == Quality.Final)
                {
                    tr.Cache[job.Hash] = new CachedAudio { Samples = samples, Channels = channels, Sent = true, SentStartSec = entry.StartSec };
                    tr.States[job.Hash] = PhraseStateKind.Final;
                    TrimCache(tr);
                }
                else tr.States[job.Hash] = PhraseStateKind.Draft;
                SendAudio(tr, entry, samples, quality, tr.Seq, channels);
                PublishLayout(tr);

                // DiffSinger draft-then-final: the draft frame is already audible, queue the final pass now.
                if (quality == Quality.Draft && !job.Cancelled)
                {
                    tr.Active.Remove((job.Hash, Quality.Draft));
                    Enqueue(tr, entry, Quality.Final, force: true);
                }
            }

            if (quality == Quality.Final) SendSungPitch(job, phrase);
        }
        catch (Exception e)
        {
            Log.Error(e, "render failed for phrase {Hash:x16}", job.Hash);
            lock (gate)
            {
                if (tracks.TryGetValue(job.TrackId, out var tr))
                {
                    tr.States[job.Hash] = PhraseStateKind.Error;
                    PublishLayout(tr);
                }
            }
            // the classic renderers without libworldline and without a resampler: say what to do, not "cannot load worldline"
            string why = !Bootstrap.WorldlineAvailable && MissesWorldline(e) && OuInternals.RendererOf(job.Phrase).SingerType == USingerType.Classic
                ? Bootstrap.NoResamplerMessage : e.Message;
            SendError(ErrorCode.RenderFailed, $"render failed: {why}", false, job.Seq);
            conn.Send(new PawUtau.Protocol.Log { Level = LogLevel.Error, Source = "render", Message = $"phrase {job.Hash:x16}: {why}" });
        }
        finally
        {
            lock (gate)
            {
                if (tracks.TryGetValue(job.TrackId, out var tr) && !job.Superseded) tr.Active.Remove((job.Hash, job.Quality));
                running.Remove(job);
                if (job.IsDs) { dsInFlight--; Monitor.PulseAll(gate); }
            }
            job.Cts.Dispose();
        }
    }

    static bool MissesWorldline(Exception? e)
    {
        for (var x = e; x != null; x = x.InnerException)
            if (x is DllNotFoundException || (x is AggregateException ag && ag.InnerExceptions.Any(MissesWorldline))) return true;
        return false;
    }

    /// <summary>Render with an optional DiffSinger step override (policy.dsDraftSteps / dsFinalSteps, 0 = OpenUtau prefs).</summary>
    static RenderResult? RenderWith(IRenderer renderer, RenderPhrase phrase, RenderJob job, RenderProgress progress, int steps, CancellationTokenSource cts)
    {
        // draft: fewer diffusion steps for the acoustic AND the variance model (the variance pass dominates a cold phrase);
        // only one DiffSinger job is in flight (dsInFlight), so the temporary preference override cannot race
        int old = Preferences.Default.DiffSingerSteps, oldVar = Preferences.Default.DiffSingerStepsVariance;
        bool overrideSteps = steps > 0 && steps != old && renderer.SingerType == USingerType.DiffSinger;
        if (overrideSteps)
        {
            Preferences.Default.DiffSingerSteps = steps;
            if (job.Quality == PawUtau.Protocol.Quality.Draft) Preferences.Default.DiffSingerStepsVariance = Math.Min(oldVar, steps);
        }
        try { return renderer.Render(phrase, progress, job.Part.trackNo, cts).GetAwaiter().GetResult(); }
        finally
        {
            if (overrideSteps) { Preferences.Default.DiffSingerSteps = old; Preferences.Default.DiffSingerStepsVariance = oldVar; }
        }
    }

    void TrimCache(TrackRuntime tr)
    {
        long total = tr.Cache.Values.Sum(c => (long)c.Samples.Length);
        if (total <= MaxCachedSamples) return;
        foreach (var key in tr.Cache.Keys.ToArray())
        {
            if (total <= MaxCachedSamples) break;
            if (tr.States.TryGetValue(key, out var st) && st == PhraseStateKind.Rendering) continue;
            if (!tr.Cache.TryGetValue(key, out var c)) continue;
            total -= c.Samples.Length;
            tr.Cache.Remove(key);
        }
    }

    // ---- outbound ----------------------------------------------------------------------------------------------------------
    void SendAudio(TrackRuntime tr, PhraseEntry e, float[] samples, byte quality, ulong seq, byte channels = 1) =>
        conn.SendPhraseAudio(new PhraseAudio
        {
            TrackId = tr.Id, PhraseHash = e.Hash, StartSec = e.StartSec, SampleRate = SampleRate,
            Channels = channels, Quality = quality, Seq = seq, Purpose = Purpose.Phrase,
        }, samples);

    void SendError(uint code, string message, bool fatal, ulong seq) =>
        conn.Send(new Error { Code = code, Message = message, Fatal = fatal, RefSeq = seq });

    /// <summary>Complete current phrase list of a track: time ordered, one entry per content hash.</summary>
    void PublishLayout(TrackRuntime tr, bool hasPhrases = false)
    {
        if (hasPhrases) tr.Quiet = false;
        if (tr.Quiet) return;   // nothing known yet on this connection: keep the extension's clips alive
        var entries = tr.Parts.Values
            .SelectMany(p => p.Entries)
            .GroupBy(e => e.Hash)
            .Select(g => g.OrderBy(e => e.StartSec).First())
            .OrderBy(e => e.StartSec)
            .ToArray();
        // The extension drops the clip of every hash that leaves the layout (protocol 7.2). Forget that cached audio was sent,
        // so it is pushed again if the hash comes back (a muted/removed part that returns, an undo, a moved item).
        var live = new HashSet<ulong>(entries.Select(e => e.Hash));
        foreach (var kv in tr.Cache)
            if (!live.Contains(kv.Key)) kv.Value.Sent = false;
        conn.Send(new ProtoPhraseLayout
        {
            TrackId = tr.Id,
            Seq = tr.Seq,
            Phrases = entries.Select(e => new PhraseState
            {
                Hash = e.Hash, StartSec = e.StartSec, EndSec = e.EndSec,
                State = tr.States.TryGetValue(e.Hash, out var st) ? st : PhraseStateKind.Pending,
            }).ToArray(),
        });
    }

    /// <summary>Rendered pitch on the 5-tick curve grid, in cents (MIDI 60 = 6000), part-relative ticks, &lt;0 = no data.</summary>
    /// <summary>
    /// The pitch the phrase is actually sung with (its final pitch array: notes + transitions + vibrato + PITD, or the AI
    /// pitch + PITD in AI mode), on the 5-tick grid relative to the part. This is what the editor draws over the notes.
    /// </summary>
    void SendSungPitch(RenderJob job, RenderPhrase phrase)
    {
        try
        {
            var p = phrase.pitches;
            if (p == null || p.Length == 0) return;
            int first = job.Phrase.position - job.Part.position - job.Phrase.leading;   // part tick of p[0] (5-tick spacing)
            int startTick = (int)Math.Floor((double)first / TickStep) * TickStep;
            int lead = (first - startTick) / TickStep;
            var cents = new float[p.Length + lead];
            for (int i = 0; i < lead; i++) cents[i] = -1f;
            Array.Copy(p, 0, cents, lead, p.Length);
            conn.Send(new RenderedPitch
            {
                PartId = job.PartId, Seq = job.Seq, TickStep = TickStep, StartTick = startTick,
                Cents = Codec.PackF32(cents),
            });
        }
        catch (Exception e)
        {
            Log.Warning("sung pitch for {Hash:x16} unavailable: {Message}", job.Hash, e.Message);
        }
    }

    void SendRenderedPitch(RenderJob job, IRenderer renderer)
    {
        try
        {
            var rp = renderer.LoadRenderedPitch(job.Phrase);
            if (rp?.tones == null || rp.ticks == null || rp.tones.Length == 0 || rp.ticks.Length == 0) return;
            int offset = job.Phrase.position - job.Part.position;
            double firstTick = rp.ticks[0] + offset;
            double lastTick = rp.ticks[^1] + offset;
            int startTick = (int)Math.Floor(firstTick / TickStep) * TickStep;
            int endTick = (int)Math.Ceiling(lastTick / TickStep) * TickStep;
            if (endTick <= startTick) return;
            int n = (endTick - startTick) / TickStep + 1;
            if (n > 4 * 1024 * 1024) return;
            var cents = new float[n];
            Array.Fill(cents, -1f);
            for (int k = 0; k < rp.tones.Length; k++)
            {
                if (rp.voiced != null && k < rp.voiced.Length && !rp.voiced[k]) continue;
                double t0 = rp.ticks[k] + offset, y0 = rp.tones[k] * 100.0;
                double t1 = k + 1 < rp.tones.Length ? rp.ticks[k + 1] + offset : t0;
                double y1 = k + 1 < rp.tones.Length ? rp.tones[k + 1] * 100.0 : y0;
                int i0 = Math.Max(0, (int)Math.Round((t0 - startTick) / TickStep));
                int i1 = Math.Min(n - 1, (int)Math.Round((t1 - startTick) / TickStep));
                if (i1 < i0) i1 = i0;
                if (i1 == i0 && t1 > t0) i1 = Math.Min(n - 1, i0 + 1);
                for (int i = i0; i <= i1; i++)
                {
                    double f = t1 > t0 ? (startTick + i * TickStep - t0) / (t1 - t0) : 0;
                    cents[i] = (float)(y0 + (y1 - y0) * Math.Clamp(f, 0, 1));
                }
            }
            conn.Send(new RenderedPitch
            {
                PartId = job.PartId, Seq = job.Seq, TickStep = TickStep, StartTick = startTick,
                Cents = Codec.PackF32(cents),
            });
        }
        catch (Exception e)
        {
            Log.Debug("rendered pitch unavailable for phrase {Hash:x16}: {Message}", job.Hash, e.Message);
        }
    }

    // ---- helpers -----------------------------------------------------------------------------------------------------------
    TrackRuntime Track(string trackId, ulong seq)
    {
        if (!tracks.TryGetValue(trackId, out var tr))
        {
            tr = new TrackRuntime { Id = trackId };
            tracks[trackId] = tr;
        }
        if (seq > tr.Seq) tr.Seq = seq;
        return tr;
    }

    static PartRuntime Part(TrackRuntime tr, string partId)
    {
        if (!tr.Parts.TryGetValue(partId, out var pr))
        {
            pr = new PartRuntime { PartId = partId };
            tr.Parts[partId] = pr;
        }
        return pr;
    }

    public void Dispose()
    {
        stopping = true;
        lock (gate)
        {
            foreach (var job in queue) Cancel(job);
            queue.Clear();
            Monitor.PulseAll(gate);
        }
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(5);
        foreach (var t in workers)
        {
            var left = deadline - DateTime.UtcNow;
            t.Join(left > TimeSpan.Zero ? left : TimeSpan.Zero);
        }
    }
}
