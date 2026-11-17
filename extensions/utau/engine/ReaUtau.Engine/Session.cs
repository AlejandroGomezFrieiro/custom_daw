using System.Text.RegularExpressions;
using OpenUtau.Api;
using OpenUtau.Core;
using OpenUtau.Core.Render;
using OpenUtau.Core.Ustx;
using ReaUtau.Protocol;
using Log = Serilog.Log;
using ProtoError = ReaUtau.Protocol.Error;
using ProtoLog = ReaUtau.Protocol.Log;
using ProtoProgress = ReaUtau.Protocol.Progress;
using RenderProgress = OpenUtau.Core.Render.Progress;

namespace ReaUtau.Engine;

/// <summary>
/// One connection's protocol state machine and project mirror. All project mutations, notifications and rendering
/// scheduling happen on <see cref="Bootstrap.Pump"/> (the engine's UI thread); socket I/O only decodes frames and calls
/// <see cref="Handle"/>.
///
/// A Session is created per connection. It keeps no state across connections: a fresh Session starts with an empty
/// mirror and the extension always sends a full SyncProject (section 4).
/// </summary>
public sealed class Session : IDisposable
{
    static readonly Regex phoneticHintPattern = new(@"\[(.*)\]", RegexOptions.Compiled);

    readonly IEngineConnection conn;
    readonly ProjectMirror mirror = new();
    readonly RenderScheduler? scheduler;
    bool helloReceived;
    bool synced;
    bool shutdown;
    ulong seq;
    CancellationTokenSource? auditionCts;

    public Session(IEngineConnection conn, bool enableRendering = true)
    {
        this.conn = conn;
        if (enableRendering)
        {
            scheduler = new RenderScheduler(conn);
            scheduler.AiPitchFor = tid => !mirror.AiPitchFlags.TryGetValue(tid, out var on) || on;
            scheduler.UnisonFor = tid => mirror.UnisonByTrack.TryGetValue(tid, out var u) ? u : null;
            scheduler.PitchShiftFor = tid => mirror.PitchShiftByTrack.TryGetValue(tid, out var c) ? c : 0;
        }
        Bootstrap.Listener.Phonemized += OnPhonemized;
        Bootstrap.Listener.ErrorRaised += OnErrorRaised;
        Bootstrap.Listener.ProgressChanged += OnProgress;
    }

    internal ProjectMirror Mirror => mirror;
    internal RenderScheduler? Scheduler => scheduler;
    public bool ShutdownRequested => shutdown;

    // ---- inbound -----------------------------------------------------------------------------------------------------------
    /// <summary>Decode one frame and run it on the pump. Throws <see cref="ProtocolException"/> for an unparsable body.</summary>
    public void Handle(Frame frame)
    {
        var msg = Codec.DecodeAny(frame);
        if (msg == null)
        {
            conn.Send(new ProtoLog
            {
                Level = ReaUtau.Protocol.LogLevel.Warn,
                Source = "protocol",
                Message = $"unknown message type 0x{frame.Type:x2} ignored",
            });
            return;
        }
        Handle(msg);
    }

    /// <summary>Run one message on the pump. Exposed for tests and the smoke client.</summary>
    public void Handle(IMessage msg) => Bootstrap.Pump.Invoke(() => Dispatch(msg));

    /// <summary>Protocol-level fatal error (bad framing/body): send it, then close after the writer flushes.</summary>
    public void SendFatal(uint code, string message)
    {
        conn.Send(new ProtoError { Code = code, Message = message, Fatal = true, RefSeq = 0 });
        conn.Close();
    }

    void Dispatch(IMessage msg)
    {
        switch (msg)
        {
            case Hello h: OnHello(h); break;
            case Ping p: conn.Send(new Pong { Nonce = p.Nonce }); break;
            case Pong: break;
            case SyncProject s: OnSyncProject(s); break;
            case ApplyDelta d: OnApplyDelta(d); break;
            case Transport t: scheduler?.SetTransport(t); break;
            case SetRenderPolicy p: if (scheduler != null) scheduler.Policy = p; break;
            case SetTrackConfig c: OnSetTrackConfig(c); break;
            case RequestSingers r: OnRequestSingers(r); break;
            case RequestRenderers: Lists.SendRenderers(conn); break;
            case RequestPhonemizers: Lists.SendPhonemizers(conn); break;
            case RunBatchEdit b: OnRunBatchEdit(b); break;
            case Shutdown:
                shutdown = true;
                scheduler?.Dispose();
                conn.Close();
                break;
            case Audition a: OnAudition(a); break;
            case Invalidate i: OnInvalidate(i); break;
            case ProtoLog l: Log.Debug("extension log [{Level}] {Source}: {Message}", l.Level, l.Source, l.Message); break;
            case ProtoError e: Log.Warning("extension error 0x{Code:x}: {Message}", e.Code, e.Message); break;
            default:
                conn.Send(new ProtoLog
                {
                    Level = ReaUtau.Protocol.LogLevel.Warn,
                    Source = "protocol",
                    Message = $"unexpected message {msg.GetType().Name} from extension",
                });
                break;
        }
    }

    // ---- handshake / lifecycle ---------------------------------------------------------------------------------------------
    void OnHello(Hello h)
    {
        if (helloReceived)
        {
            SendError(ErrorCode.InvalidState, "duplicate Hello", false, 0);
            return;
        }
        helloReceived = true;
        uint peerMajor = h.ProtocolVersion >> 16;
        if (peerMajor != Proto.Major)
        {
            SendError(ErrorCode.VersionMismatch, $"protocol major {peerMajor} != {Proto.Major}", true, 0);
            conn.Close();
            return;
        }
        if (h.Role != ReaUtau.Protocol.Role.Extension)
            Log.Warning("peer Hello role {Role}, expected extension", h.Role);
        Lists.SendSingers(conn);
        Lists.SendRenderers(conn);
        Lists.SendPhonemizers(conn);
        Log.Information("extension Hello: version {Version}, protocol {Protocol:x8}, pid {Pid}",
            h.Version, h.ProtocolVersion, h.Pid);
    }

    // ---- batch edits --------------------------------------------------------------------------------------------------------
    /// <summary>
    /// "retake" (P4.1): AI pitch takes of the phrases of the given parts. Args JSON:
    /// <c>{"action": "info" | "new" | "prev" | "next" | "select", "index": n, "notes": [noteId, ...], "whole": bool}</c>.
    /// With notes, only the phrases containing them are changed, and "new" re-rolls only those notes (the rest of the phrase
    /// keeps the current take) unless "whole"; without notes every phrase of the parts is. The answer's message is JSON:
    /// <c>{"error": str|null, "changed": n, "phrases": [{"hash": "dec", "start": tick, "current": i, "count": n,
    /// "notes": [ids]}]}</c> for every phrase of the parts. Changed phrases are rendered again.
    /// </summary>
    void OnRunBatchEdit(RunBatchEdit b)
    {
        if (b.Name == "graph")
        {
            // the expression graph of a track (args {"track": id}): name, inputs (macro lanes), outputs, problems
            string tid = "";
            try
            {
                using var gd = System.Text.Json.JsonDocument.Parse(b.Args.Length > 0 ? b.Args : "{}");
                if (gd.RootElement.TryGetProperty("track", out var t)) tid = t.GetString() ?? "";
            }
            catch { }
            object payload = mirror.GraphInfos.TryGetValue(tid, out var gi)
                ? new
                {
                    graph = true, name = gi.Name, renderer = gi.Renderer,
                    inputs = gi.Inputs.Select(i => new { lane = i.Lane, name = i.Name, min = i.Min, max = i.Max }).ToArray(),
                    outputs = gi.Outputs.ToArray(), problems = gi.Problems.ToArray(),
                }
                : new { graph = false };
            conn.Send(new BatchEditResult { RequestId = b.RequestId, Ok = true, Message = System.Text.Json.JsonSerializer.Serialize(payload) });
            return;
        }
        if (b.Name != "retake")
        {
            conn.Send(new BatchEditResult { RequestId = b.RequestId, Ok = false, Message = $"unknown batch edit '{b.Name}'" });
            return;
        }
        if (!RequireSync(0)) return;
        string action = "info";
        string kind = "pitch";
        int index = 0;
        bool whole = false;
        var noteIds = new HashSet<uint>(b.NoteIds);
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(b.Args.Length > 0 ? b.Args : "{}");
            var root = doc.RootElement;
            if (root.TryGetProperty("action", out var a) && a.ValueKind == System.Text.Json.JsonValueKind.String) action = a.GetString()!;
            if (root.TryGetProperty("index", out var ix) && ix.ValueKind == System.Text.Json.JsonValueKind.Number) index = ix.GetInt32();
            if (root.TryGetProperty("whole", out var wh) && wh.ValueKind == System.Text.Json.JsonValueKind.True) whole = true;
            if (root.TryGetProperty("kind", out var kd) && kd.ValueKind == System.Text.Json.JsonValueKind.String) kind = kd.GetString()!;
            if (root.TryGetProperty("notes", out var ns) && ns.ValueKind == System.Text.Json.JsonValueKind.Array)
                foreach (var n in ns.EnumerateArray()) if (n.TryGetUInt32(out var id)) noteIds.Add(id);
        }
        catch (Exception e)
        {
            conn.Send(new BatchEditResult { RequestId = b.RequestId, Ok = false, Message = "bad arguments: " + e.Message });
            return;
        }
        // snapshot on the pump thread (the mirror is not thread safe); the pitch model runs in the background
        var work = new List<(string TrackId, ulong Hash, RenderPhrase Phrase, uint[] Ids, HashSet<int>? Partial, bool Hit, bool Ai)>();
        foreach (var pid in b.PartIds)
        {
            if (!mirror.TryGetPart(pid, out var pe) || scheduler == null) continue;
            bool ai = !mirror.AiPitchFlags.TryGetValue(pe.TrackId, out var on) || on;
            foreach (var (hash, phrase) in scheduler.PhrasesOf(pe.TrackId, pid))
            {
                // RenderPhrase.position is absolute (part position + first phoneme), RenderNote.position phrase-relative,
                // UNote.position part-relative: compare in absolute ticks (also what OpenUtau's partial retake expects)
                int partPos = pe.Part.position;
                var positions = phrase.notes.Select(n => phrase.position + n.position).ToHashSet();
                var ids = pe.Notes.Where(kv => positions.Contains(partPos + kv.Value.position)).Select(kv => kv.Key).OrderBy(x => x).ToArray();
                var sel = pe.Notes.Where(kv => noteIds.Contains(kv.Key) && positions.Contains(partPos + kv.Value.position))
                    .Select(kv => partPos + kv.Value.position).ToHashSet();
                bool hit = noteIds.Count == 0 || sel.Count > 0;
                // every note of the phrase selected = a whole-phrase retake
                HashSet<int>? partial = whole || noteIds.Count == 0 || sel.Count >= positions.Count ? null : sel;
                work.Add((pe.TrackId, hash, phrase, ids, partial, hit, ai));
            }
        }
        Task.Run(() =>
        {
            string? error = null;
            var changed = new List<(string TrackId, ulong Hash)>();
            var phrases = new List<object>();
            foreach (var w in work)
            {
                var renderer = OuInternals.RendererOf(w.Phrase);
                if (w.Hit && action != "info" && kind == "timbre")
                {
                    if (renderer.SingerType != OpenUtau.Core.Ustx.USingerType.DiffSinger)
                        error = "timbre retakes need a DiffSinger voice (other renderers always sound the same)";
                    else
                    {
                        var (vc, _) = AiPitch.TimbreInfo(w.Phrase);
                        bool ch = action switch
                        {
                            "new" => AiPitch.RetakeTimbre(w.Phrase),
                            "prev" => AiPitch.SelectTimbre(w.Phrase, vc - 1),
                            "next" => AiPitch.SelectTimbre(w.Phrase, vc + 1),
                            "select" => AiPitch.SelectTimbre(w.Phrase, index),
                            _ => false,
                        };
                        if (ch) changed.Add((w.TrackId, w.Hash));
                    }
                }
                else if (w.Hit && action != "info")
                {
                    if (!w.Ai || !renderer.SupportsRenderPitch)
                    {
                        error = "AI pitch is off on this track, or its renderer has no pitch model";
                    }
                    else
                    {
                        try
                        {
                            var (cur, _) = AiPitch.Info(w.Phrase);
                            bool ch = action switch
                            {
                                "new" => AiPitch.Retake(renderer, w.Phrase, w.Partial),
                                "prev" => AiPitch.Select(w.Phrase, cur - 1),
                                "next" => AiPitch.Select(w.Phrase, cur + 1),
                                "select" => AiPitch.Select(w.Phrase, index),
                                _ => false,
                            };
                            if (ch) changed.Add((w.TrackId, w.Hash));
                        }
                        catch (Exception e)
                        {
                            Log.Warning(e, "retake failed for phrase {Hash:x16}", w.Hash);
                            error = "retake failed: " + e.Message;
                        }
                    }
                }
                var (current, count) = AiPitch.Info(w.Phrase);
                var (vcurrent, vcount) = AiPitch.TimbreInfo(w.Phrase);
                phrases.Add(new { hash = w.Hash.ToString(), start = w.Phrase.position, current, count, vcurrent, vcount, notes = w.Ids });
            }
            foreach (var g in changed.GroupBy(c => c.TrackId))
                scheduler?.InvalidatePhrases(g.Key, g.Select(c => c.Hash).ToArray());
            var msg = System.Text.Json.JsonSerializer.Serialize(new { error, changed = changed.Count, phrases });
            conn.Send(new BatchEditResult { RequestId = b.RequestId, Ok = error == null, Message = msg });
        });
    }

    bool RequireSync(ulong refSeq)
    {
        if (synced) return true;
        SendError(ErrorCode.InvalidState, "SyncProject must be sent before project state messages", false, refSeq);
        return false;
    }

    // ---- project state -----------------------------------------------------------------------------------------------------
    void OnSyncProject(SyncProject s)
    {
        synced = true;
        seq = s.Seq;
        scheduler?.Reset(s.Seq);
        var res = mirror.Sync(s);
        ReportErrors(res, s.Seq);
        ScheduleDirty(res, allParts: true);
    }

    void OnApplyDelta(ApplyDelta d)
    {
        if (!RequireSync(d.Seq)) return;
        seq = d.Seq;
        var res = mirror.Apply(d);
        ReportErrors(res, d.Seq);
        if (res.TempoChanged) scheduler?.InvalidateAllCaches();
        ScheduleDirty(res, allParts: res.TempoChanged);
    }

    void OnSetTrackConfig(SetTrackConfig c)
    {
        if (!RequireSync(0)) return;
        var res = mirror.SetTrackConfig(c.TrackId, c.Config);
        ReportErrors(res, seq);
        foreach (var tid in res.TouchedTracks) scheduler?.InvalidateTrack(tid);
        ScheduleDirty(res, allParts: false);
    }

    void OnInvalidate(Invalidate i)
    {
        if (!RequireSync(0)) return;
        if (!mirror.TryGetTrack(i.TrackId, out _))
        {
            SendError(ErrorCode.InvalidState, $"Invalidate: unknown track {i.TrackId}", false, seq);
            return;
        }
        var project = mirror.Project;
        if (i.PartId.Length > 0)
        {
            if (!mirror.TryGetPart(i.PartId, out var pe))
            {
                SendError(ErrorCode.InvalidState, $"Invalidate: unknown part {i.PartId}", false, seq);
                return;
            }
            scheduler?.InvalidatePart(i.TrackId, i.PartId);
            project.Validate(new ValidateOptions { SkipTiming = true, Part = pe.Part });
            SchedulePart(pe);
            return;
        }
        scheduler?.InvalidateTrack(i.TrackId);
        project.Validate(new ValidateOptions { SkipTiming = true });
        foreach (var pe in mirror.Parts.Where(p => p.TrackId == i.TrackId)) SchedulePart(pe);
    }

    /// <summary>Parts touched by a delta plus every part of a touched track; re-schedules only what changed.</summary>
    void ScheduleDirty(MirrorResult res, bool allParts)
    {
        foreach (var pid in res.RemovedParts) scheduler?.RemovePart(pid);
        foreach (var pid in res.MovedParts) scheduler?.RemovePart(pid);
        foreach (var tid in res.RemovedTracks) scheduler?.RemoveTrack(tid);

        if (scheduler == null) return;
        if (allParts)
        {
            // Tempo replace moved every start time: re-publish every track, replacing placeholders part by part.
            foreach (var pe in mirror.Parts) SchedulePart(pe);
            return;
        }
        var ids = new HashSet<string>(res.TouchedParts);
        foreach (var tid in res.TouchedTracks)
            foreach (var pe in mirror.Parts)
                if (pe.TrackId == tid) ids.Add(pe.Id);
        ids.ExceptWith(res.RemovedParts);
        foreach (var id in ids)
            if (mirror.TryGetPart(id, out var pe)) SchedulePart(pe);
    }

    void SchedulePart(PartEntry pe)
    {
        if (scheduler == null) return;
        // Muted tracks/items are never mixed: do not spend render time on them (and drop their placeholders so an offline
        // render never waits for them). Un-muting arrives as a delta that touches the track and schedules it again.
        if (pe.Muted || (mirror.TryGetTrack(pe.TrackId, out var te) && te.Muted))
        {
            scheduler.RemovePart(pe.Id);
            return;
        }
        // Wait for the phonemizer when the part is stale; a part whose phonemes are current (a move, a curve edit)
        // can be snapshotted right away. Phonemized drives the stale case (see OnPhonemized).
        if (pe.Part.PhonemesUpToDate) scheduler.SchedulePart(pe.TrackId, pe.Id, pe.Part, seq);
        else scheduler.MarkPartWaiting(pe.TrackId, pe.Id, pe.Part, seq);
    }

    void OnRequestSingers(RequestSingers r)
    {
        if (r.Rescan)
        {
            try { SingerManager.Inst.SearchAllSingers(); }
            catch (Exception e) { Log.Warning(e, "singer rescan failed"); }
        }
        Lists.SendSingers(conn);
    }

    // ---- notifications (pump thread) ---------------------------------------------------------------------------------------
    void OnPhonemized(UVoicePart part)
    {
        if (!synced) return;
        string? partId = mirror.PartIdOf(part);
        if (partId == null || !mirror.TryGetPart(partId, out var pe)) return;

        var phonemes = mirror.BuildPhonemes(partId, seq);
        if (phonemes != null) conn.Send(phonemes);

        if (scheduler == null || !scheduler.IsWaiting(part)) return;
        if (!part.PhonemesUpToDate) return;   // an older response landed; wait for the newest request
        scheduler.SchedulePart(pe.TrackId, pe.Id, part, seq);
    }

    void OnErrorRaised(Exception? e, string message)
    {
        if (message.Length == 0 && e != null) message = e.Message;
        if (message.Length == 0) message = "engine error";
        SendError(ErrorCode.Internal, message, false, seq);
    }

    void OnProgress(double progress, string info)
    {
        if (!helloReceived || info.Length == 0) return;
        conn.Send(new ProtoProgress
        {
            TaskId = "openutau",
            Label = info,
            Fraction = (float)Math.Clamp(progress / 100.0, 0.0, 1.0),
            Queued = 0,
        });
    }

    // ---- audition ----------------------------------------------------------------------------------------------------------
    sealed class AuditionSnapshot
    {
        public USinger? Singer;
        public Type? PhonemizerType;
        public string PhonemizerName = "";
        public string PhonemizerTag = "";
        public string PhonemizerLanguage = "";
        public URenderSettings Settings = new();
        public UTempo[] Tempos = Array.Empty<UTempo>();
        public UTimeSignature[] Sigs = Array.Empty<UTimeSignature>();
        public Dictionary<string, UExpressionDescriptor> Expressions = new();
    }

    void OnAudition(Audition a)
    {
        if (!RequireSync(0)) return;
        if (!mirror.TryGetTrack(a.TrackId, out var te))
        {
            SendError(ErrorCode.InvalidState, $"Audition: unknown track {a.TrackId}", false, seq);
            return;
        }
        var live = te.Track;
        var project = mirror.Project;
        var snap = new AuditionSnapshot
        {
            Singer = live.Singer,
            PhonemizerType = live.Phonemizer?.GetType(),
            PhonemizerName = live.Phonemizer?.Name ?? "",
            PhonemizerTag = live.Phonemizer?.Tag ?? "",
            PhonemizerLanguage = live.Phonemizer?.Language ?? "",
            Settings = live.RendererSettings.Clone(),
            Tempos = project.tempos.Select(t => new UTempo(t.position, t.bpm)).ToArray(),
            Sigs = project.timeSignatures.Select(s => new UTimeSignature(s.barPosition, s.beatPerBar, s.beatUnit)).ToArray(),
            Expressions = new Dictionary<string, UExpressionDescriptor>(project.expressions),
        };

        auditionCts?.Cancel();
        auditionCts?.Dispose();
        var cts = new CancellationTokenSource();
        auditionCts = cts;
        ulong requestSeq = seq;
        Task.Run(() => RenderAudition(snap, a, requestSeq, cts));
    }

    /// <summary>
    /// Renders one note through a throwaway project so the mirrored project is never touched. Runs off the pump because
    /// DiffSinger/classic rendering is slow. The answer is a purpose=1 PhraseAudio with phraseHash = requestId.
    /// </summary>
    void RenderAudition(AuditionSnapshot snap, Audition a, ulong requestSeq, CancellationTokenSource cts)
    {
        try
        {
            if (snap.Singer == null)
            {
                SendError(ErrorCode.SingerNotFound, $"Audition: track {a.TrackId} has no singer", false, requestSeq);
                return;
            }
            var project = new UProject
            {
                tempos = snap.Tempos.ToList(),
                timeSignatures = snap.Sigs.ToList(),
                expressions = new Dictionary<string, UExpressionDescriptor>(snap.Expressions),
            };
            project.timeAxis.BuildSegments(project);
            project.tracks.Clear();

            var track = new UTrack(project) { TrackName = "audition", TrackNo = 0 };
            track.Singer = snap.Singer;
            if (snap.PhonemizerType != null)
            {
                var factory = PhonemizerFactory.Get(snap.PhonemizerType);
                var phonemizer = factory?.Create() ?? Activator.CreateInstance(snap.PhonemizerType) as Phonemizer;
                if (phonemizer == null) throw new InvalidOperationException("cannot create the track's phonemizer");
                phonemizer.Name = snap.PhonemizerName;
                phonemizer.Tag = snap.PhonemizerTag;
                phonemizer.Language = snap.PhonemizerLanguage;
                track.Phonemizer = phonemizer;
            }
            track.RendererSettings = snap.Settings.Clone();
            track.RendererSettings.Validate(track);
            project.tracks.Add(track);
            track.Validate(new ValidateOptions { SkipTiming = true }, project);

            int durTicks = Math.Max(10, project.timeAxis.MsPosToTickPos(Math.Max(1, a.DurationMs)));
            var part = new UVoicePart { name = "audition", trackNo = 0, position = 0, Duration = durTicks };
            var note = project.CreateNote(a.Tone, 0, durTicks);
            note.lyric = string.IsNullOrWhiteSpace(a.Lyric) ? "a" : a.Lyric;
            part.notes.Add(note);
            project.parts.Add(part);

            // Notes only: sets Prev/Next/ExtendedDuration and note error state without asking DocManager's phonemizer runner.
            part.Validate(new ValidateOptions { SkipTiming = true, SkipPhonemizer = true, SkipPhoneme = true }, project, track);
            if (!Phonemize(project, track, part, note, cts)) return;
            if (cts.IsCancellationRequested) return;

            var phrases = RenderPhrase.FromPart(project, track, part);
            if (phrases.Count == 0)
            {
                SendError(ErrorCode.RenderFailed, $"Audition: no renderable phrase for \"{note.lyric}\"", false, requestSeq);
                return;
            }
            var renderer = OuInternals.RendererOf(phrases[0]);
            var progress = new RenderProgress(Math.Max(1, phrases[0].phones.Length));
            var res = renderer.Render(phrases[0], progress, 0, cts).GetAwaiter().GetResult();
            if (cts.IsCancellationRequested || res?.samples == null || res.samples.Length == 0) return;

            conn.SendPhraseAudio(new PhraseAudio
            {
                TrackId = a.TrackId,
                PhraseHash = a.RequestId,
                StartSec = 0,
                SampleRate = 44100,
                Channels = 1,
                Quality = Quality.Final,
                Purpose = Purpose.Audition,
                Seq = requestSeq,
            }, res.samples);
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            Log.Error(e, "audition failed for track {Track}", a.TrackId);
            SendError(ErrorCode.RenderFailed, $"audition failed: {e.Message}", false, requestSeq);
        }
        finally
        {
            if (ReferenceEquals(auditionCts, cts)) { auditionCts = null; cts.Dispose(); }
        }
    }

    /// <summary>Runs the track's phonemizer once for a single note and turns the result into validated UPhonemes.</summary>
    static bool Phonemize(UProject project, UTrack track, UVoicePart part, UNote note, CancellationTokenSource cts)
    {
        var phonemizer = track.Phonemizer;
        if (phonemizer == null) return false;

        string lyric = note.lyric;
        string? hint = null;
        var match = phoneticHintPattern.Match(lyric);
        if (match.Success)
        {
            hint = match.Groups[1].Value.Trim();
            lyric = lyric.Remove(match.Index, match.Length);
        }
        var pnote = new Phonemizer.Note
        {
            lyric = lyric.Trim(),
            phoneticHint = hint,
            tone = note.tone,
            position = part.position + note.position,
            duration = note.duration,
            phonemeAttributes = Array.Empty<Phonemizer.PhonemeAttributes>(),
        };

        cts.Token.ThrowIfCancellationRequested();
        phonemizer.SetSinger(track.Singer);
        phonemizer.SetTiming(project.timeAxis);
        phonemizer.SetUp(new[] { new[] { pnote } }, project, track);
        Phonemizer.Result result;
        try
        {
            result = phonemizer.Process(new[] { pnote }, null, null, null, null, Array.Empty<Phonemizer.Note>());
        }
        finally
        {
            try { phonemizer.CleanUp(); } catch (Exception e) { Log.Warning(e, "audition phonemizer cleanup failed"); }
        }

        var phonemes = result.phonemes ?? Array.Empty<Phonemizer.Phoneme>();
        for (int i = 0; i < phonemes.Length; i++)
        {
            string name = phonemes[i].phoneme;
            if (phonemizer.LegacyMapping && track.Singer.TryGetMappedOto(name, note.tone, out var oto)) name = oto.Alias;
            part.phonemes.Add(new UPhoneme
            {
                rawPosition = phonemes[i].position + note.position - part.position,
                rawPhoneme = name,
                index = phonemes[i].index ?? i,
                Parent = note,
            });
        }
        note.phonemeIndexes = part.phonemes.Select(p => p.index).OrderBy(i => i).ToArray();
        // Validate the phonemes (oto/preutter/overlap/envelope) but keep the part's phrase list out of the shared builder.
        OuInternals.MarkPhonemesStale(part);
        part.Validate(new ValidateOptions { SkipTiming = true, SkipPhonemizer = true }, project, track);
        return part.phonemes.Any(p => !p.Error);
    }

    // ---- outbound helpers --------------------------------------------------------------------------------------------------
    void ReportErrors(MirrorResult res, ulong refSeq)
    {
        foreach (var (code, msg) in res.Errors) SendError(code, msg, false, refSeq);
    }

    void SendError(uint code, string message, bool fatal, ulong refSeq) =>
        conn.Send(new ProtoError { Code = code, Message = message, Fatal = fatal, RefSeq = refSeq });

    public void Dispose()
    {
        Bootstrap.Listener.Phonemized -= OnPhonemized;
        Bootstrap.Listener.ErrorRaised -= OnErrorRaised;
        Bootstrap.Listener.ProgressChanged -= OnProgress;
        auditionCts?.Cancel();
        auditionCts?.Dispose();
        auditionCts = null;
        scheduler?.Dispose();
    }
}
