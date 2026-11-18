using System.Reflection;
using K4os.Hash.xxHash;
using OpenUtau.Api;
using OpenUtau.Core;
using OpenUtau.Core.Ustx;
using PawUtau.Protocol;
using Serilog;

namespace PawUtau.Engine;

/// <summary>A tiny UCommand for mutations OpenUtau has no stock command for; still goes through DocManager (validate, impact, phonemizer triggers).</summary>
sealed class ActionCommand : UCommand
{
    readonly string name;
    readonly Action exec, undo;
    readonly ValidateOptions vo;
    readonly OpenUtau.Core.Pipeline.ImpactSet impact;
    public ActionCommand(string name, Action exec, Action undo, ValidateOptions vo, OpenUtau.Core.Pipeline.ImpactSet impact)
    { this.name = name; this.exec = exec; this.undo = undo; this.vo = vo; this.impact = impact; }
    public override ValidateOptions ValidateOptions => vo;
    public override OpenUtau.Core.Pipeline.ImpactSet Impact => impact;
    public override void Execute() => exec();
    public override void Unexecute() => undo();
    public override string ToString() => name;
}

public sealed class MirrorResult
{
    public HashSet<string> TouchedTracks = new();
    public HashSet<string> RemovedTracks = new();
    public HashSet<string> TouchedParts = new();
    public HashSet<string> RemovedParts = new();
    /// <summary>Parts whose trackId changed: the scheduler has to forget the old track assignment.</summary>
    public HashSet<string> MovedParts = new();
    public bool TempoChanged;
    public List<(uint code, string msg)> Errors = new();
}

sealed class TrackEntry
{
    public string Id = "";
    public UTrack Track = null!;
    public string ConfigKey = "";
    public bool Muted;   // from TrackInfo.Muted: muted tracks are not rendered (nothing audible to wait for)
    public int KeyShift;          // track option keyshift (semitones, -12..12): sung tones = written + this (Phase 5 A6)
    public int PitchShift;        // track option pitchshift (cents, -50..50): added to the sung pitch at render time
    public bool AiPitch = true;   // track option pitchmode: "ai" (default) sings the renderer's pitch model + PITD, "manual" = notes + PITD
}

sealed class PartEntry
{
    public string Id = "";
    public string TrackId = "";
    public UVoicePart Part = null!;
    public int WantedDuration;
    public bool Muted;   // from PartInfo.Muted (item or take muted)
    public Dictionary<uint, UNote> Notes = new();
    public Dictionary<uint, (int pos, int dur, int tone, byte[] payload)> Sigs = new();
    public Dictionary<UNote, uint> Ids = new(ReferenceEqualityComparer.Instance);
}

/// <summary>
/// The engine's mirror of the extension's project: trackId -> UTrack, partId -> UVoicePart, noteId -> UNote.
/// All methods run on the pump thread. Changes are DocManager commands inside one undo group (UndoLimit is 1, so history is not retained).
/// </summary>
public sealed class ProjectMirror
{
    readonly Dictionary<string, TrackEntry> tracks = new();
    readonly Dictionary<string, PartEntry> parts = new();
    internal UProject Project => DocManager.Inst.Project;

    internal IEnumerable<PartEntry> Parts => parts.Values;
    internal bool TryGetTrack(string id, out TrackEntry t) => tracks.TryGetValue(id, out t!);
    internal bool TryGetPart(string id, out PartEntry p) => parts.TryGetValue(id, out p!);
    public IEnumerable<string> TrackIds => tracks.Keys.ToArray();

    // ---- SyncProject ---------------------------------------------------------------------------------------------------------
    public MirrorResult Sync(SyncProject s)
    {
        var old = new HashSet<string>(tracks.Keys);
        tracks.Clear();
        parts.Clear();
        var project = OpenUtau.Core.Format.Ustx.Create();
        project.tracks.Clear();
        DocManager.Inst.ExecuteCmd(new LoadProjectNotification(project));
        var d = new ApplyDelta
        {
            Seq = s.Seq, ReplaceTempo = true, Tempos = s.Tempos, TimeSigs = s.TimeSigs,
            UpsertTracks = s.Tracks,
            UpsertParts = s.Parts.Select(p => p.Info).ToArray(),
            UpsertNotes = s.Parts.Select(p => new PartNotes { PartId = p.Info.PartId, Notes = p.Notes }).ToArray(),
            ReplaceCurves = s.Parts.Where(p => p.Curves.Length > 0).Select(p => new PartCurves { PartId = p.Info.PartId, Curves = p.Curves }).ToArray(),
        };
        var res = Apply(d, deferValidate: true, forceTempo: true);
        foreach (var id in old) if (!tracks.ContainsKey(id)) res.RemovedTracks.Add(id);
        return res;
    }

    /// <summary>Track id -> AI pitch on (thread-safe view for the render worker; the mirror itself is pump-thread only).</summary>
    public readonly System.Collections.Concurrent.ConcurrentDictionary<string, bool> AiPitchFlags = new();
    /// <summary>Unison settings per track (track options unison*), read by the render workers; absent = one voice.</summary>
    public readonly System.Collections.Concurrent.ConcurrentDictionary<string, UnisonSettings> UnisonByTrack = new();
    /// <summary>Track pitch shift in cents (track option pitchshift), read by the render workers; absent = 0.</summary>
    public readonly System.Collections.Concurrent.ConcurrentDictionary<string, int> PitchShiftByTrack = new();

    // ---- SetTrackConfig ------------------------------------------------------------------------------------------------------
    public MirrorResult SetTrackConfig(string trackId, TrackConfig cfg)
    {
        var res = new MirrorResult();
        if (!tracks.TryGetValue(trackId, out var te))
        {
            res.Errors.Add((ErrorCode.InvalidState, $"SetTrackConfig for unknown track {trackId}"));
            return res;
        }
        DocManager.Inst.StartUndoGroup("paw-utau-config");
        try { ConfigureTrack(te, cfg, res); res.TouchedTracks.Add(trackId); }
        finally { DocManager.Inst.EndUndoGroup(); }
        return res;
    }

    // ---- ApplyDelta ----------------------------------------------------------------------------------------------------------
    public MirrorResult Apply(ApplyDelta d, bool deferValidate = false, bool forceTempo = false)
    {
        var res = new MirrorResult();
        var dm = DocManager.Inst;
        var project = dm.Project;
        dm.StartUndoGroup("paw-utau-delta", deferValidate);
        try
        {
            // 1. removeTracks (with their parts)
            foreach (var tid in d.RemoveTracks)
            {
                if (!tracks.TryGetValue(tid, out var te)) continue;
                foreach (var pid in parts.Where(kv => kv.Value.TrackId == tid).Select(kv => kv.Key).ToArray())
                {
                    parts.Remove(pid);
                    res.RemovedParts.Add(pid);
                }
                dm.ExecuteCmd(new RemoveTrackCommand(project, te.Track));
                tracks.Remove(tid);
                res.RemovedTracks.Add(tid);
            }
            // 2. removeParts
            foreach (var pid in d.RemoveParts)
            {
                if (!parts.TryGetValue(pid, out var pe)) continue;
                dm.ExecuteCmd(new RemovePartCommand(project, pe.Part));
                parts.Remove(pid);
                res.TouchedTracks.Add(pe.TrackId);
                res.RemovedParts.Add(pid);
            }
            // 3. upsertTracks
            foreach (var ti in d.UpsertTracks)
            {
                if (!tracks.TryGetValue(ti.TrackId, out var te))
                {
                    var t = new UTrack(project) { TrackName = ti.Name };
                    t.TrackNo = project.tracks.Count;
                    dm.ExecuteCmd(new AddTrackCommand(project, t));
                    te = new TrackEntry { Id = ti.TrackId, Track = t };
                    tracks[ti.TrackId] = te;
                }
                else if (te.Track.TrackName != ti.Name)
                {
                    dm.ExecuteCmd(new RenameTrackCommand(project, te.Track, ti.Name));
                }
                te.Muted = ti.Muted;
                ConfigureTrack(te, ti.Config, res);
                res.TouchedTracks.Add(ti.TrackId);
            }
            // 4. upsertParts
            foreach (var pi in d.UpsertParts)
            {
                if (!tracks.TryGetValue(pi.TrackId, out var te))
                {
                    res.Errors.Add((ErrorCode.InvalidState, $"upsertParts {pi.PartId}: unknown track {pi.TrackId}"));
                    continue;
                }
                int pos = (int)pi.PosTick, dur = Math.Max(1, (int)pi.DurTick);
                if (!parts.TryGetValue(pi.PartId, out var pe))
                {
                    var part = new UVoicePart { name = pi.Name, trackNo = te.Track.TrackNo, position = pos, Duration = dur };
                    dm.ExecuteCmd(new AddPartCommand(project, part));
                    pe = new PartEntry { Id = pi.PartId, TrackId = pi.TrackId, Part = part, WantedDuration = dur };
                    parts[pi.PartId] = pe;
                }
                else
                {
                    var part = pe.Part;
                    if (pe.TrackId != pi.TrackId)
                    {
                        res.TouchedTracks.Add(pe.TrackId);
                        res.MovedParts.Add(pe.Id);
                    }
                    if (part.position != pos || part.trackNo != te.Track.TrackNo)
                        dm.ExecuteCmd(new MovePartCommand(project, part, pos, te.Track.TrackNo));
                    if (part.Duration != dur || part.name != pi.Name)
                    {
                        int oldDur = part.Duration; string oldName = part.name;
                        dm.ExecuteCmd(new ActionCommand("Resize part", () => { part.Duration = dur; part.name = pi.Name; },
                            () => { part.Duration = oldDur; part.name = oldName; },
                            new ValidateOptions { SkipTiming = true, Part = part, SkipPhonemizer = true, SkipPhoneme = true },
                            OpenUtau.Core.Pipeline.ImpactSet.PartOf(part)));
                    }
                    pe.TrackId = pi.TrackId;
                    pe.WantedDuration = dur;
                }
                pe.Muted = pi.Muted;
                res.TouchedTracks.Add(pi.TrackId);
                res.TouchedParts.Add(pi.PartId);
            }
            // 5. tempo
            if (d.ReplaceTempo) ApplyTempo(project, d.Tempos, d.TimeSigs, res, forceTempo);
            // 6. removeNotes
            foreach (var rn in d.RemoveNotes)
            {
                if (!parts.TryGetValue(rn.PartId, out var pe)) { res.Errors.Add((ErrorCode.InvalidState, $"removeNotes: unknown part {rn.PartId}")); continue; }
                var list = new List<UNote>();
                foreach (var id in rn.Ids)
                    if (pe.Notes.Remove(id, out var n)) { list.Add(n); pe.Ids.Remove(n); pe.Sigs.Remove(id); }
                if (list.Count > 0) dm.ExecuteCmd(new RemoveNoteCommand(pe.Part, list));
                res.TouchedParts.Add(rn.PartId); res.TouchedTracks.Add(pe.TrackId);
            }
            // 7. upsertNotes
            foreach (var un in d.UpsertNotes)
            {
                if (!parts.TryGetValue(un.PartId, out var pe)) { res.Errors.Add((ErrorCode.InvalidState, $"upsertNotes: unknown part {un.PartId}")); continue; }
                var track = tracks[pe.TrackId].Track;
                var remove = new List<UNote>();
                var add = new List<UNote>();
                foreach (var nm in un.Notes)
                {
                    if (pe.Sigs.TryGetValue(nm.Id, out var sig) && sig.pos == nm.PosTick && sig.dur == nm.DurTick && sig.tone == nm.Tone
                        && sig.payload.AsSpan().SequenceEqual(nm.Payload)) continue;   // unchanged: do not disturb OpenUtau's hashes
                    if (pe.Notes.Remove(nm.Id, out var old)) { remove.Add(old); pe.Ids.Remove(old); }
                    var n = NoteMapper.Build(project, track, nm, tracks[pe.TrackId].KeyShift);
                    add.Add(n);
                    pe.Notes[nm.Id] = n; pe.Ids[n] = nm.Id; pe.Sigs[nm.Id] = (nm.PosTick, nm.DurTick, nm.Tone, nm.Payload);
                }
                if (remove.Count > 0) dm.ExecuteCmd(new RemoveNoteCommand(pe.Part, remove));
                if (add.Count > 0) dm.ExecuteCmd(new AddNoteCommand(pe.Part, add));
                if (remove.Count + add.Count > 0) { res.TouchedParts.Add(un.PartId); res.TouchedTracks.Add(pe.TrackId); }
            }
            // 8. replaceCurves
            foreach (var pc in d.ReplaceCurves)
            {
                if (!parts.TryGetValue(pc.PartId, out var pe)) { res.Errors.Add((ErrorCode.InvalidState, $"replaceCurves: unknown part {pc.PartId}")); continue; }
                var track = tracks[pe.TrackId].Track;
                foreach (var cd in pc.Curves) ReplaceCurve(project, track, pe, cd, res);
            }
            // AddNoteCommand may grow a part past what the extension says; restore the authoritative length.
            foreach (var pid in res.TouchedParts)
            {
                if (!parts.TryGetValue(pid, out var pe) || pe.Part.Duration == pe.WantedDuration) continue;
                var part = pe.Part; int want = pe.WantedDuration, had = part.Duration;
                dm.ExecuteCmd(new ActionCommand("Fix part length", () => part.Duration = want, () => part.Duration = had,
                    new ValidateOptions { SkipTiming = true, Part = part, SkipPhonemizer = true, SkipPhoneme = true },
                    OpenUtau.Core.Pipeline.ImpactSet.PartOf(part)));
            }
        }
        finally
        {
            dm.EndUndoGroup();
        }
        // Every validate rebuilds TimeAxis.Timestamp (DateTime.Now), and it is part of every phrase hash. Stamp it back to
        // a content hash of the tempo map after each batch, so hashes are stable across deltas, validates and restarts.
        StampTimeAxis(project);
        return res;
    }

    // ---- tracks --------------------------------------------------------------------------------------------------------------
    /// <summary>
    /// The phonemizer to use when the config names none (or names one that cannot serve this singer), mirroring the
    /// OpenUtau GUI: the user's per-singer choice (Preferences.SingerPhonemizers, imported read-only from their OpenUtau
    /// prefs), then the bank's default_phonemizer. A phonemizer of another singer family (e.g. a DiffSinger phonemizer
    /// on a classic bank) never survives a singer change: it would fail in SetSinger and nothing would ever render.
    /// </summary>
    internal static PhonemizerFactory? DefaultPhonemizerFor(USinger? singer)
    {
        if (singer == null || !singer.Found) return null;
        if (!string.IsNullOrEmpty(singer.Id) && OpenUtau.Core.Util.Preferences.Default.SingerPhonemizers.TryGetValue(singer.Id, out var pref))
        {
            var f = PhonemizerFactory.Get(pref);
            if (f != null) return f;
        }
        if (!string.IsNullOrEmpty(singer.DefaultPhonemizer))
        {
            var f = PhonemizerFactory.Get(singer.DefaultPhonemizer);
            if (f != null) return f;
        }
        return null;
    }

    static bool PhonemizerFits(Type phonemizerType, USinger? singer)
    {
        if (singer == null || !singer.Found) return true;
        bool ds = typeof(OpenUtau.Core.DiffSinger.DiffSingerBasePhonemizer).IsAssignableFrom(phonemizerType)
            || phonemizerType.Namespace == "OpenUtau.Core.DiffSinger";
        bool enunu = phonemizerType.Namespace?.Contains("Enunu") == true;
        bool vogen = phonemizerType.Namespace == "OpenUtau.Core.Vogen";
        return singer.SingerType switch
        {
            USingerType.DiffSinger => !enunu && !vogen,
            USingerType.Enunu => !ds && !vogen,
            USingerType.Vogen => vogen,
            _ => !ds && !enunu && !vogen,
        };
    }

    /// <summary>
    /// Track option "exprgraph" = the text of an OpenUtau expression graph file (format openutau_expression_graph,
    /// as OpenUtau exports it): the graph goes into the project library under a track-owned id and becomes the track's
    /// override; the expressions it reads or writes are added when the project lacks them. Empty = no graph. Problems
    /// (unreadable file, another renderer, a graph that cannot run) are reported as ConfigAdjusted.
    /// </summary>
    void ApplyExpressionGraph(TrackEntry te, string text, MirrorResult res)
    {
        var project = DocManager.Inst.Project;
        int idx = project.tracks.IndexOf(te.Track);
        if (idx < 0) return;
        string ownId = "pawutau_" + new string(te.Id.Where(char.IsLetterOrDigit).ToArray()).ToLowerInvariant();
        OpenUtau.Core.ExpressionGraph.UExpressionGraph? graph = null;
        GraphInfo? info = null;
        if (text.Length > 0)
        {
            try
            {
                var file = Yaml.DefaultDeserializer.Deserialize<OpenUtau.Core.ExpressionGraph.ExpressionGraphFile>(text);
                if (file?.format != OpenUtau.Core.ExpressionGraph.ExpressionGraphFile.FormatName || file.graph == null)
                    throw new InvalidDataException("not an OpenUtau expression graph file");
                foreach (var d in file.expressions)
                    if (d != null && !string.IsNullOrEmpty(d.abbr) && !project.expressions.ContainsKey(d.abbr))
                        project.RegisterExpression(d.Clone());
                graph = file.graph.Clone();
                graph.id = ownId;
                info = new GraphInfo { Name = graph.name ?? "", Renderer = graph.renderer ?? "" };
                MapCustomInputs(project, file, graph, info, res);
                info.Outputs.AddRange(graph.nodes
                    .Where(n => n.type == OpenUtau.Core.ExpressionGraph.GraphNodeTypes.CurveOutput
                             || n.type == OpenUtau.Core.ExpressionGraph.GraphNodeTypes.PhonemeOutput)
                    .Select(n => n.GetString("abbr") ?? "").Where(a => a.Length > 0).Distinct());
                string? renderer = te.Track.RendererSettings?.renderer;
                if (graph.renderer != null && renderer != null && OpenUtau.Core.Render.Renderers.GetExpressionGraphSlot(graph.renderer)
                    != OpenUtau.Core.Render.Renderers.GetExpressionGraphSlot(renderer))
                    res.Errors.Add((ErrorCode.ConfigAdjusted, $"expression graph \"{graph.name}\" is made for {graph.renderer}, the track renders with {renderer}: it is not used"));
                if (OpenUtau.Core.ExpressionGraph.ExpressionGraphProgram.Compile(graph, out var err) == null)
                {
                    res.Errors.Add((ErrorCode.ConfigAdjusted, $"expression graph \"{graph.name}\" cannot run: {err}"));
                    info.Problems.Add("cannot run: " + err);
                }
            }
            catch (Exception e)
            {
                res.Errors.Add((ErrorCode.ConfigAdjusted, "expression graph not loaded: " + e.Message));
                graph = null;
                info = new GraphInfo();
                info.Problems.Add("not loaded: " + e.Message);
            }
        }
        if (info != null) GraphInfos[te.Id] = info; else GraphInfos.TryRemove(te.Id, out _);
        bool had = project.tracks[idx].ExpressionGraph == ownId;
        if (graph == null && !had) return;
        OpenUtau.Core.ExpressionGraph.ExpressionGraphEdits.Apply(project, draft =>
        {
            draft.Remove(ownId);
            if (graph != null)
            {
                draft.Graphs.Add(graph);
                draft.TrackOverrides[idx] = ownId;
            }
        });
        foreach (var pe in parts.Values.Where(p => p.TrackId == te.Id)) res.TouchedParts.Add(pe.Id);
    }

    /// <summary>What a track's expression graph reads and writes, for the editor (batch edit "graph").</summary>
    public sealed class GraphInfo
    {
        public string Name = "", Renderer = "";
        public readonly List<(string Lane, string Name, double Min, double Max)> Inputs = new();
        public readonly List<string> Outputs = new();
        public readonly List<string> Problems = new();
    }
    public readonly System.Collections.Concurrent.ConcurrentDictionary<string, GraphInfo> GraphInfos = new();

    /// <summary>
    /// Custom curves a graph reads (curve inputs whose expression has no lane of its own) are mapped onto the macro lanes
    /// mc1..mc8 (CC 24..31, 0..100), in node order. An input with another range gets a map_range node so the graph still
    /// sees its own units. The lanes are registered as curve expressions named after the graph's inputs.
    /// </summary>
    static void MapCustomInputs(UProject project, OpenUtau.Core.ExpressionGraph.ExpressionGraphFile file,
        OpenUtau.Core.ExpressionGraph.UExpressionGraph graph, GraphInfo info, MirrorResult res)
    {
        var known = PawUtau.Protocol.CurveDef.All.Select(d => d.Abbr).ToHashSet();
        var lanes = new Dictionary<string, string>();
        foreach (var node in graph.nodes.ToList())
        {
            if (node.type != OpenUtau.Core.ExpressionGraph.GraphNodeTypes.CurveInput
                && node.type != OpenUtau.Core.ExpressionGraph.GraphNodeTypes.MaskedCurveInput) continue;
            string abbr = node.GetString("abbr") ?? "";
            if (abbr.Length == 0) continue;
            if (known.Contains(abbr))
            {
                if (abbr.StartsWith("mc") && info.Inputs.All(i => i.Lane != abbr)) info.Inputs.Add((abbr, abbr.ToUpperInvariant(), 0, 100));
                continue;
            }
            var d = file.expressions.FirstOrDefault(e => e?.abbr == abbr);
            double min = d?.min ?? 0, max = d?.max ?? 100;
            if (!lanes.TryGetValue(abbr, out var lane))
            {
                if (lanes.Count >= 8)
                {
                    res.Errors.Add((ErrorCode.ConfigAdjusted, $"expression graph reads more than 8 custom curves; \"{abbr}\" has no lane"));
                    info.Problems.Add($"no lane for {abbr}");
                    continue;
                }
                lane = "mc" + (lanes.Count + 1);
                lanes[abbr] = lane;
                info.Inputs.Add((lane, string.IsNullOrEmpty(d?.name) ? abbr : d!.name, min, max));
                if (!project.expressions.ContainsKey(lane))
                    project.RegisterExpression(new UExpressionDescriptor(d?.name ?? abbr, lane, 0, 100, 0) { type = UExpressionType.Curve });
            }
            node.Set("abbr", lane);
            if (Math.Abs(min) > 1e-9 || Math.Abs(max - 100) > 1e-9)
            {
                // lane 0..100 -> the graph's own range, in front of everything the input fed
                var map = OpenUtau.Core.ExpressionGraph.ExpressionGraphEdits.AddNode(graph,
                    OpenUtau.Core.ExpressionGraph.GraphNodeTypes.MapRange, node.x + 120, node.y);
                map.Set("in_min", 0f); map.Set("in_max", 100f); map.Set("out_min", (float)min); map.Set("out_max", (float)max);
                foreach (var link in graph.links.Where(l => l.from == node.id)) link.from = map.id;
                OpenUtau.Core.ExpressionGraph.ExpressionGraphEdits.TryLink(graph, node.id, map.id,
                    OpenUtau.Core.ExpressionGraph.GraphNodeTypes.Value);
            }
        }
    }

    static string Option(TrackConfig cfg, string key) =>
        cfg.Options?.FirstOrDefault(kv => kv.Key == key)?.Value ?? "";

    void ConfigureTrack(TrackEntry te, TrackConfig cfg, MirrorResult res)
    {
        string key = string.Join("\u0001", cfg.SingerId, cfg.Phonemizer, cfg.Renderer, cfg.Resampler, cfg.Wavtool,
            string.Join(",", (cfg.Options ?? Array.Empty<KeyValue>()).Select(kv => kv.Key + "=" + kv.Value)));
        if (key == te.ConfigKey) return;
        var dm = DocManager.Inst; var project = dm.Project; var track = te.Track;
        // singer
        USinger? singer = track.Singer;
        string wantSinger = cfg.SingerId;
        string haveSinger = track.Singer?.Id ?? "";
        if (wantSinger != haveSinger)
        {
            if (wantSinger.Length == 0) singer = null;
            else if (SingerManager.Inst.Singers.TryGetValue(wantSinger, out var s)) singer = s;
            else
            {
                singer = USinger.CreateMissing(wantSinger);
                res.Errors.Add((ErrorCode.SingerNotFound, $"singer '{wantSinger}' not found for track {te.Id}"));
            }
            dm.ExecuteCmd(new TrackChangeSingerCommand(project, track, singer!));
        }
        // phonemizer: explicit, else the singer's default (user preference, then bank default); an incompatible current or
        // requested phonemizer falls back to the default, then to OpenUtau's DefaultPhonemizer
        PhonemizerFactory? factory = null;
        if (cfg.Phonemizer.Length > 0)
        {
            factory = PhonemizerFactory.Get(cfg.Phonemizer);
            if (factory == null) res.Errors.Add((ErrorCode.ConfigAdjusted, $"phonemizer '{cfg.Phonemizer}' not found; using the singer default"));
            else if (!PhonemizerFits(factory.type, singer))
            {
                res.Errors.Add((ErrorCode.ConfigAdjusted, $"phonemizer '{cfg.Phonemizer}' cannot serve singer '{singer?.Id}'; using its default"));
                factory = null;
            }
        }
        if (factory == null && (cfg.Phonemizer.Length > 0 || wantSinger != haveSinger || !PhonemizerFits(track.Phonemizer.GetType(), singer)))
        {
            factory = DefaultPhonemizerFor(singer);
            if (factory == null && !PhonemizerFits(track.Phonemizer.GetType(), singer))
                factory = PhonemizerFactory.Get(typeof(DefaultPhonemizer));
        }
        if (factory != null && track.Phonemizer.GetType() != factory.type)
            dm.ExecuteCmd(new TrackChangePhonemizerCommand(project, track, factory.Create()));
        // renderer: explicit when the singer type supports it, else the type's default (as the OpenUtau GUI does)
        string? renderer = cfg.Renderer.Length > 0 ? cfg.Renderer : null;
        if (singer != null && singer.Found)
        {
            var supported = OpenUtau.Core.Render.Renderers.GetSupportedRenderers(singer.SingerType);
            if (renderer == null || !supported.Contains(renderer))
            {
                if (renderer != null)
                    res.Errors.Add((ErrorCode.ConfigAdjusted, $"renderer '{renderer}' does not support singer '{singer.Id}'; using its default"));
                renderer = OpenUtau.Core.Render.Renderers.GetDefaultRenderer(singer.SingerType);
            }
            // without libworldline (the release asset) a WORLDLINE renderer would throw: CLASSIC with the user's resamplers sings
            if (!Bootstrap.WorldlineAvailable && Bootstrap.IsWorldlineRenderer(renderer) && supported.Contains(OpenUtau.Core.Render.Renderers.CLASSIC))
            {
                if (cfg.Renderer.Length > 0)
                    res.Errors.Add((ErrorCode.ConfigAdjusted, $"{renderer} needs libworldline.so, which is not installed; using CLASSIC"));
                renderer = OpenUtau.Core.Render.Renderers.CLASSIC;
            }
        }
        var rs = new URenderSettings
        {
            renderer = renderer,
            resampler = cfg.Resampler.Length > 0 ? cfg.Resampler : null,
            wavtool = cfg.Wavtool.Length > 0 ? cfg.Wavtool : null,
        };
        dm.ExecuteCmd(new TrackChangeRenderSettingCommand(project, track, rs));
        // the renderer's own curves (DiffSinger energy/velocity/expressiveness/voice-colour blends, VOICEVOX ...): stock
        // OpenUtau only knows them after the user adds them in the expressions dialog; register them so they just work
        try
        {
            var r = track.RendererSettings?.Renderer;
            if (r != null && singer != null && singer.Found)
                foreach (var d in r.GetSuggestedExpressions(singer, track.RendererSettings) ?? Array.Empty<UExpressionDescriptor>())
                    if (d != null && !string.IsNullOrEmpty(d.abbr) && !project.expressions.ContainsKey(d.abbr))
                        project.RegisterExpression(d.Clone());
        }
        catch (Exception e) { Serilog.Log.Debug("suggested expressions unavailable: {Message}", e.Message); }
        // macro lanes always exist, so a macro curve drawn before a graph is chosen is kept and feeds it later
        for (int i = 1; i <= 8; i++)
            if (!project.expressions.ContainsKey("mc" + i))
                project.RegisterExpression(new UExpressionDescriptor($"macro {i}", "mc" + i, 0, 100, 0) { type = UExpressionType.Curve });
        // voice colour (track option "subbank" = colour name): the track-level default of the CLR expression, i.e. which
        // subbank/speaker every note uses unless it sets its own clr. Validate first so VoiceColorExp exists.
        track.Validate(new ValidateOptions { SkipTiming = true }, project);
        string color = Option(cfg, "subbank");
        if (track.VoiceColorExp != null)
        {
            int idx = color.Length > 0 ? Array.IndexOf(track.VoiceColorExp.options, color) : 0;
            if (idx < 0)
            {
                res.Errors.Add((ErrorCode.ConfigAdjusted, $"voice colour '{color}' not in singer '{singer?.Id}'"));
                idx = 0;
            }
            if ((int)track.VoiceColorExp.CustomDefaultValue != idx)
            {
                track.VoiceColorExp.CustomDefaultValue = idx;
                foreach (var pe in parts.Values.Where(p => p.TrackId == te.Id)) res.TouchedParts.Add(pe.Id);
            }
        }
        te.AiPitch = Option(cfg, "pitchmode") != "manual";
        AiPitchFlags[te.Id] = te.AiPitch;   // read by the render worker thread
        var uni = UnisonSettings.Parse(k => Option(cfg, k));
        if (uni != null) UnisonByTrack[te.Id] = uni; else UnisonByTrack.TryRemove(te.Id, out _);
        ApplyExpressionGraph(te, Option(cfg, "exprgraph"), res);
        ApplyShift(te, Option(cfg, "keyshift"), Option(cfg, "pitchshift"), res);
        te.ConfigKey = key;
    }

    /// Track options keyshift / pitchshift (Phase 5 A6): the track sings transposed without touching its MIDI. On a change
    /// every note of the track is rebuilt with tone + key shift; the pitch shift is added to the phrase pitch by the render
    /// workers (after AI pitch, so it is exact), its parts are re-rendered.
    void ApplyShift(TrackEntry te, string key, string cents, MirrorResult res)
    {
        int k = int.TryParse(key, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var kv) ? Math.Clamp(kv, -12, 12) : 0;
        int c = double.TryParse(cents, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var cv) ? (int)Math.Round(Math.Clamp(cv, -50, 50)) : 0;
        if (k == te.KeyShift && c == te.PitchShift) return;
        bool rebuild = k != te.KeyShift;
        te.KeyShift = k; te.PitchShift = c;
        if (c != 0) PitchShiftByTrack[te.Id] = c; else PitchShiftByTrack.TryRemove(te.Id, out _);
        var project = DocManager.Inst.Project;
        foreach (var pe in parts.Values.Where(p => p.TrackId == te.Id))
        {
            res.TouchedParts.Add(pe.Id);
            if (!rebuild || pe.Notes.Count == 0) continue;
            var remove = pe.Notes.Values.ToList();
            var add = new List<UNote>();
            var ids = pe.Notes.Keys.ToList();
            foreach (var id in ids)
            {
                var sig = pe.Sigs[id];
                var n = NoteMapper.Build(project, te.Track, new NoteMsg { Id = id, PosTick = sig.pos, DurTick = sig.dur, Tone = sig.tone, Payload = sig.payload }, k);
                pe.Ids.Remove(pe.Notes[id]);
                pe.Notes[id] = n; pe.Ids[n] = id;
                add.Add(n);
            }
            DocManager.Inst.ExecuteCmd(new RemoveNoteCommand(pe.Part, remove));
            DocManager.Inst.ExecuteCmd(new AddNoteCommand(pe.Part, add));
        }
        res.TouchedTracks.Add(te.Id);
    }

    // ---- tempo / time signatures ----------------------------------------------------------------------------------------------
    void ApplyTempo(UProject project, TempoPoint[] tempos, TimeSigPoint[] sigs, MirrorResult res, bool force)
    {
        var newTempos = tempos.OrderBy(t => t.PosTick).Select(t => new UTempo((int)t.PosTick, t.Bpm)).ToList();
        if (newTempos.Count == 0 || newTempos[0].position != 0) newTempos.Insert(0, new UTempo(0, newTempos.Count > 0 ? newTempos[0].bpm : 120));
        var newSigs = new List<UTimeSignature>();
        {
            int bar = 0; long prevTick = 0; int prevNum = 4, prevDen = 4;
            foreach (var s in sigs.OrderBy(x => x.PosTick))
            {
                long ticksPerBar = prevNum * (480L * 4 / prevDen);
                if (newSigs.Count > 0) bar += (int)((s.PosTick - prevTick + ticksPerBar - 1) / ticksPerBar);   // a marker off a bar line rounds up to the next bar
                newSigs.Add(new UTimeSignature(newSigs.Count == 0 ? 0 : bar, s.Numerator, s.Denominator));
                prevTick = s.PosTick; prevNum = s.Numerator; prevDen = s.Denominator;
                if (newSigs.Count == 1) prevTick = 0;
            }
            if (newSigs.Count == 0) newSigs.Add(new UTimeSignature(0, 4, 4));
        }
        bool same = project.tempos.Count == newTempos.Count && project.timeSignatures.Count == newSigs.Count
            && project.tempos.Zip(newTempos).All(p => p.First.position == p.Second.position && p.First.bpm == p.Second.bpm)
            && project.timeSignatures.Zip(newSigs).All(p => p.First.barPosition == p.Second.barPosition && p.First.beatPerBar == p.Second.beatPerBar && p.First.beatUnit == p.Second.beatUnit);
        if (same && !force) return;
        var oldT = project.tempos; var oldS = project.timeSignatures;
        DocManager.Inst.ExecuteCmd(new ActionCommand("Replace tempo map",
            () => { project.tempos = newTempos; project.timeSignatures = newSigs; },
            () => { project.tempos = oldT; project.timeSignatures = oldS; },
            new ValidateOptions { SkipTiming = false }, OpenUtau.Core.Pipeline.ImpactSet.All));
        res.TempoChanged = true;
    }

    /// <summary>
    /// TimeAxis.Timestamp (DateTime.Now at every BuildSegments) is part of every RenderPhrase hash. Replace it with a content hash of the
    /// tempo map so phrase hashes are stable across validates and across engine restarts (protocol: "the respawned engine produces
    /// identical hashes for unchanged phrases").
    /// </summary>
    static void StampTimeAxis(UProject project)
    {
        var ms = new MemoryStream();
        using (var w = new BinaryWriter(ms))
        {
            foreach (var t in project.tempos) { w.Write(t.position); w.Write(t.bpm); }
            foreach (var s in project.timeSignatures) { w.Write(s.barPosition); w.Write(s.beatPerBar); w.Write(s.beatUnit); }
        }
        long stamp = (long)(XXH64.DigestOf(ms.ToArray()) & 0x7fffffffffffffffUL);
        typeof(TimeAxis).GetProperty("Timestamp", BindingFlags.Public | BindingFlags.Instance)!.GetSetMethod(true)!.Invoke(project.timeAxis, new object[] { stamp });
    }

    // ---- curves --------------------------------------------------------------------------------------------------------------
    void ReplaceCurve(UProject project, UTrack track, PartEntry pe, CurveData cd, MirrorResult res)
    {
        string abbr = cd.Abbr.ToLowerInvariant();
        var part = pe.Part;
        var existing = part.curves.FirstOrDefault(c => c.abbr == abbr);
        var oldXs = existing?.xs.ToArray(); var oldYs = existing?.ys.ToArray();
        if (cd.Knots.Length == 0)
        {
            if (existing == null) return;
            DocManager.Inst.ExecuteCmd(new ActionCommand("Clear curve " + abbr, () => part.curves.Remove(existing),
                () => part.curves.Add(existing), CurveValidate(part), OpenUtau.Core.Pipeline.ImpactSet.CurvesOf(part, abbr)));
        }
        else
        {
            if (!track.TryGetExpDescriptor(project, abbr, out var desc))
            {
                res.Errors.Add((ErrorCode.ConfigAdjusted, $"replaceCurves: ignoring unknown expression '{abbr}'"));
                return;
            }
            var (xs, ys) = CcShape.SampleKnotsOnGrid(cd.Knots, Math.Max(pe.WantedDuration, part.Duration));
            for (int i = 0; i < ys.Length; i++) ys[i] = (int)Math.Clamp(ys[i], desc.min, desc.max);
            bool wasNew = existing == null;
            var curve = existing ?? new UCurve(desc);
            DocManager.Inst.ExecuteCmd(new ActionCommand("Set curve " + abbr, () =>
            {
                if (wasNew) part.curves.Add(curve);
                curve.xs.Clear(); curve.ys.Clear(); curve.xs.AddRange(xs); curve.ys.AddRange(ys);
            }, () =>
            {
                if (wasNew) part.curves.Remove(curve);
                else { curve.xs.Clear(); curve.ys.Clear(); curve.xs.AddRange(oldXs!); curve.ys.AddRange(oldYs!); }
            }, CurveValidate(part), OpenUtau.Core.Pipeline.ImpactSet.CurvesOf(part, abbr)));
        }
        res.TouchedParts.Add(pe.Id); res.TouchedTracks.Add(pe.TrackId);
    }

    static ValidateOptions CurveValidate(UVoicePart part) =>
        new() { SkipTiming = true, Part = part, SkipPhonemizer = true, SkipPhoneme = true };

    // ---- outbound helpers (pump thread) ----------------------------------------------------------------------------------------
    public Phonemes? BuildPhonemes(string partId, ulong seq)
    {
        if (!parts.TryGetValue(partId, out var pe)) return null;
        var byNote = new Dictionary<uint, List<PhonemeInfo>>();
        foreach (var ph in pe.Part.phonemes.ToArray())
        {
            if (ph.Parent == null || !pe.Ids.TryGetValue(ph.Parent, out var nid)) continue;
            bool overridden = ph.Parent.phonemeOverrides.Any(o => o.index == ph.index && !o.IsEmpty);
            var info = new PhonemeInfo
            {
                Phoneme = ph.phoneme ?? "", Alias = ph.phonemeMapped ?? "", StartTick = ph.position, EndTick = ph.End,
                PreutterMs = (float)ph.preutter, OverlapMs = (float)ph.overlap,
                Flags = (byte)((ph.Error ? PhonemeFlags.Error : 0) | (overridden ? PhonemeFlags.Overridden : 0)),
            };
            if (!byNote.TryGetValue(nid, out var l)) byNote[nid] = l = new();
            l.Add(info);
        }
        return new Phonemes
        {
            PartId = partId, Seq = seq,
            Notes = pe.Notes.Keys.OrderBy(k => pe.Notes[k].position).Select(id => new NotePhonemes
            { NoteId = id, Phonemes = byNote.TryGetValue(id, out var l) ? l.ToArray() : Array.Empty<PhonemeInfo>() }).ToArray(),
        };
    }

    public string? PartIdOf(UVoicePart part) => parts.FirstOrDefault(kv => ReferenceEquals(kv.Value.Part, part)).Key;
    public string? TrackIdOf(UTrack track) => tracks.FirstOrDefault(kv => ReferenceEquals(kv.Value.Track, track)).Key;
}
