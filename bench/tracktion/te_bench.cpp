// Headless benchmark driver for Tracktion Engine: the same workloads as
// bench/*.lua run on this DAW. Prints one JSON object per run on stdout.
//
//   te_bench startup
//   te_bench render  <tracks> <audio|midi> <fx 0|1> <automation 0|1> <threads> <bars> <wav>
//   te_bench blocks  <tracks> <audio|midi> <fx 0|1> <automation 0|1> <threads> <buffer> <seconds> <wav>
//   te_bench edit    <clips>
//   te_bench notes   <notes>
//   te_bench saveload <tracks> <clips per track> <dir>
//   te_bench memory  <tracks> <clips per track> <undo steps>
//
// Sample rate 48 kHz, block 512, 120 BPM 4/4, 24-bit WAV output, matching the
// DAW's defaults. `threads` is the number of CPUs Tracktion may use for the
// render graph: 1 means the calling thread only.

#include <JuceHeader.h>

#include <chrono>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace te = tracktion;
using Clock = std::chrono::steady_clock;

static double msSince (Clock::time_point t)
{
    return std::chrono::duration<double, std::milli> (Clock::now() - t).count();
}

static long rssKb()
{
    std::ifstream f ("/proc/self/status");
    std::string line;
    while (std::getline (f, line))
        if (line.rfind ("VmRSS:", 0) == 0)
            return std::stol (line.substr (6));
    return -1;
}

static int cpusForAudio = 1;

struct Behaviour : te::EngineBehaviour
{
    int getNumberOfCPUsToUseForAudio() override { return cpusForAudio; }
    bool autoInitialiseDeviceManager() override { return false; }

    // Tracktion's defaults allow 400 tracks per edit and 1500 clips per
    // track, and Edit::ensureNumberOfAudioTracks loops forever at the track
    // limit. Raise both so the larger workloads can run at all.
    te::EditLimits getEditLimits() override
    {
        te::EditLimits limits;
        limits.maxNumTracks = 4096;
        limits.maxClipsInTrack = 100000;
        return limits;
    }
};

static std::unique_ptr<te::Engine> makeEngine()
{
    return std::make_unique<te::Engine> ("te_bench", nullptr, std::make_unique<Behaviour>());
}

static std::unique_ptr<te::Edit> makeEdit (te::Engine& engine, int tracks)
{
    auto edit = te::Edit::createSingleTrackEdit (engine, te::Edit::EditRole::forEditing);
    edit->ensureNumberOfAudioTracks (tracks);
    return edit;
}

static te::Plugin::Ptr addPlugin (te::Edit& edit, te::AudioTrack& track, const char* type, int index)
{
    auto plugin = edit.getPluginCache().createNewPlugin (type, {});
    track.pluginList.insertPlugin (plugin, index, nullptr);
    return plugin;
}

/// A bar is 2 seconds at 120 BPM in 4/4.
static constexpr double barSeconds = 2.0;

/// The DAW's MIDI workload: per bar, a four-note chord on the first beat and
/// eight eighth notes of a bass line, each half a beat long.
static void fillMidi (te::MidiClip& clip, int bars, int trackIndex)
{
    auto& seq = clip.getSequence();
    for (int bar = 0; bar < bars; ++bar)
    {
        const double b = bar * 4.0;
        for (int i = 0; i < 4; ++i)
            seq.addNote (48 + (trackIndex % 12) + i * 4, te::BeatPosition::fromBeats (b),
                         te::BeatDuration::fromBeats (2.0), 100, 0, nullptr);
        for (int i = 0; i < 8; ++i)
            seq.addNote (36 + (trackIndex % 12) + (i % 3) * 7, te::BeatPosition::fromBeats (b + i * 0.5),
                         te::BeatDuration::fromBeats (0.5), 90, 0, nullptr);
    }
}

static int finishRender (te::Engine&, te::Edit&, int tracks, bool midi, bool fx, bool automation, int threads,
                         int bars, double seconds, double buildMs);

/// The render workload, built into `edit`.
static void buildWorkload (te::Edit& edit, bool midi, bool fx, bool automation, int bars, const juce::File& wav);

static int cmdRender (int tracks, bool midi, bool fx, bool automation, int threads, int bars, const juce::File& wav)
{
    cpusForAudio = threads;
    auto t0 = Clock::now();
    auto engine = makeEngine();
    auto edit = makeEdit (*engine, tracks);
    const double seconds = bars * barSeconds;
    buildWorkload (*edit, midi, fx, automation, bars, wav);
    const double buildMs = msSince (t0);
    return finishRender (*engine, *edit, tracks, midi, fx, automation, threads, bars, seconds, buildMs);
}

static void buildWorkload (te::Edit& edit_, bool midi, bool fx, bool automation, int bars, const juce::File& wav)
{
    auto* edit = &edit_;
    const double seconds = bars * barSeconds;
    int i = 0;
    for (auto track : te::getAudioTracks (*edit))
    {
        if (midi)
        {
            auto synth = addPlugin (*edit, *track, te::FourOscPlugin::xmlTypeName, 0);
            if (auto osc = dynamic_cast<te::FourOscPlugin*> (synth.get()))
            {
                // Closest to the DAW's synth: one saw oscillator, a low-pass
                // filter, 16 voices, no built-in effects.
                osc->oscParams[0]->waveShapeValue = te::Oscillator::saw;
                osc->filterTypeValue = 1;
                osc->voicesValue = 16;
            }
            auto clip = track->insertMIDIClip (te::TimeRange (te::TimePosition(), te::TimePosition::fromSeconds (seconds)), nullptr);
            fillMidi (*clip, bars, i);
        }
        else
        {
            // One clip per bar, each playing the first 2 s of the file.
            for (int bar = 0; bar < bars; ++bar)
            {
                te::ClipPosition pos { te::TimeRange (te::TimePosition::fromSeconds (bar * barSeconds),
                                                      te::TimePosition::fromSeconds ((bar + 1) * barSeconds)) };
                track->insertWaveClip ("a", wav, pos, false);
            }
        }
        if (fx)
            addPlugin (*edit, *track, te::DelayPlugin::xmlTypeName, -1);
        if (automation)
        {
            auto vol = track->getVolumePlugin();
            auto& curve = vol->volParam->getCurve();
            for (int bar = 0; bar <= bars; ++bar)
                curve.addPoint (te::TimePosition::fromSeconds (bar * barSeconds), bar % 2 ? 0.6f : 0.9f, 0.0f, nullptr);
        }
        ++i;
    }
}

static int finishRender (te::Engine& engine_, te::Edit& edit_, int tracks, bool midi, bool fx, bool automation, int threads,
                         int bars, double seconds, double buildMs)
{
    auto* engine = &engine_;
    auto* edit = &edit_;
    te::Renderer::Parameters p (*edit);
    auto out = juce::File::getSpecialLocation (juce::File::tempDirectory).getChildFile ("te_bench_render.wav");
    out.deleteFile();
    p.destFile = out;
    p.audioFormat = engine->getAudioFileFormatManager().getWavFormat();
    p.bitDepth = 24;
    p.blockSizeForAudio = 512;
    p.sampleRateForAudio = 48000.0;
    p.time = te::TimeRange (te::TimePosition(), te::TimePosition::fromSeconds (seconds));
    p.tracksToDo = te::toBitSet (te::getAllTracks (*edit));
    p.usePlugins = true;
    p.useMasterPlugins = true;
    p.checkNodesForAudio = false;

    auto t1 = Clock::now();
    auto task = te::render_utils::createRenderTask (p, "bench", nullptr, nullptr);
    const double prepareMs = msSince (t1);
    std::vector<double> steps;
    auto t2 = Clock::now();
    if (task != nullptr)
    {
        for (;;)
        {
            auto s = Clock::now();
            auto status = task->runJob();
            steps.push_back (msSince (s));
            if (status != juce::ThreadPoolJob::jobNeedsRunningAgain)
                break;
        }
    }
    const double renderMs = msSince (t2);
    std::sort (steps.begin(), steps.end());
    auto pct = [&] (double q) { return steps.empty() ? 0.0 : steps[std::min (steps.size() - 1, (size_t) (q * (double) steps.size()))]; };

    std::printf ("{\"engine\":\"tracktion\",\"workload\":\"render\",\"tracks\":%d,\"kind\":\"%s\",\"fx\":%d,\"automation\":%d,"
                 "\"threads\":%d,\"bars\":%d,\"audio_seconds\":%.3f,\"build_ms\":%.3f,\"prepare_ms\":%.3f,\"render_ms\":%.3f,"
                 "\"realtime_x\":%.2f,\"steps\":%zu,\"block_p50_ms\":%.4f,\"block_p99_ms\":%.4f,\"block_max_ms\":%.4f,"
                 "\"file_bytes\":%lld,\"rss_kb\":%ld}\n",
                 tracks, midi ? "midi" : "audio", fx ? 1 : 0, automation ? 1 : 0, threads, bars, seconds, buildMs, prepareMs,
                 renderMs, seconds * 1000.0 / renderMs, steps.size(), pct (0.5), pct (0.99), steps.empty() ? 0.0 : steps.back(),
                 (long long) out.getSize(), rssKb());
    out.deleteFile();
    return 0;
}

/// Add, move and delete `clips` empty MIDI clips on one track, each as its own
/// undoable transaction, then undo and redo all of it.
static int cmdEdit (int clips)
{
    auto engine = makeEngine();
    auto edit = makeEdit (*engine, 1);
    auto& um = edit->getUndoManager();
    um.setMaxNumberOfStoredUnits (0, 1000000);
    auto track = te::getAudioTracks (*edit)[0];

    auto t = Clock::now();
    std::vector<te::MidiClip::Ptr> made;
    for (int i = 0; i < clips; ++i)
    {
        um.beginNewTransaction();
        made.push_back (track->insertMIDIClip (te::TimeRange (te::TimePosition::fromSeconds (i * 2.0), te::TimePosition::fromSeconds (i * 2.0 + 2.0)), nullptr));
    }
    const double addMs = msSince (t);

    t = Clock::now();
    for (auto& c : made)
    {
        um.beginNewTransaction();
        c->setStart (c->getPosition().getStart() + te::TimeDuration::fromSeconds (1.0), false, true);
    }
    const double moveMs = msSince (t);

    t = Clock::now();
    for (auto& c : made)
    {
        um.beginNewTransaction();
        c->removeFromParent();
    }
    const double deleteMs = msSince (t);
    made.clear();

    const int steps = clips * 3;
    t = Clock::now();
    int undone = 0;
    while (um.canUndo() && undone < steps) { um.undo(); ++undone; }
    const double undoMs = msSince (t);
    const int after = track->getClips().size();
    t = Clock::now();
    int redone = 0;
    while (um.canRedo()) { um.redo(); ++redone; }
    const double redoMs = msSince (t);

    std::printf ("{\"engine\":\"tracktion\",\"workload\":\"edit\",\"clips\":%d,\"add_ms\":%.3f,\"move_ms\":%.3f,\"delete_ms\":%.3f,"
                 "\"undo_ms\":%.3f,\"undo_steps\":%d,\"redo_ms\":%.3f,\"redo_steps\":%d,\"clips_after_undo\":%d,\"rss_kb\":%ld}\n",
                 clips, addMs, moveMs, deleteMs, undoMs, undone, redoMs, redone, after, rssKb());
    return 0;
}

/// Add `notes` notes to one clip one at a time (one transaction each), then
/// move each, then delete each.
static int cmdNotes (int notes)
{
    auto engine = makeEngine();
    auto edit = makeEdit (*engine, 1);
    auto& um = edit->getUndoManager();
    um.setMaxNumberOfStoredUnits (0, 1000000);
    auto track = te::getAudioTracks (*edit)[0];
    auto clip = track->insertMIDIClip (te::TimeRange (te::TimePosition(), te::TimePosition::fromSeconds (notes * 0.5 + 2)), nullptr);
    auto& seq = clip->getSequence();

    auto t = Clock::now();
    for (int i = 0; i < notes; ++i)
    {
        um.beginNewTransaction();
        seq.addNote (36 + i % 48, te::BeatPosition::fromBeats (i * 0.25), te::BeatDuration::fromBeats (0.25), 100, 0, &um);
    }
    const double addMs = msSince (t);

    t = Clock::now();
    for (auto n : seq.getNotes())
    {
        um.beginNewTransaction();
        n->setStartAndLength (n->getStartBeat() + te::BeatDuration::fromBeats (0.125), n->getLengthBeats(), &um);
    }
    const double moveMs = msSince (t);

    t = Clock::now();
    while (seq.getNumNotes() > 0)
    {
        um.beginNewTransaction();
        seq.removeNote (*seq.getNotes().getLast(), &um);
    }
    const double deleteMs = msSince (t);

    std::printf ("{\"engine\":\"tracktion\",\"workload\":\"notes\",\"notes\":%d,\"add_ms\":%.3f,\"move_ms\":%.3f,\"delete_ms\":%.3f,\"rss_kb\":%ld}\n",
                 notes, addMs, moveMs, deleteMs, rssKb());
    return 0;
}

static void buildLarge (te::Edit& edit, int clipsPerTrack)
{
    int i = 0;
    for (auto track : te::getAudioTracks (edit))
    {
        addPlugin (edit, *track, te::FourOscPlugin::xmlTypeName, 0);
        addPlugin (edit, *track, te::DelayPlugin::xmlTypeName, -1);
        for (int c = 0; c < clipsPerTrack; ++c)
        {
            auto clip = track->insertMIDIClip (te::TimeRange (te::TimePosition::fromSeconds (c * barSeconds), te::TimePosition::fromSeconds ((c + 1) * barSeconds)), nullptr);
            fillMidi (*clip, 1, i);
        }
        ++i;
    }
}

static int cmdSaveLoad (int tracks, int clipsPerTrack, const juce::File& dir)
{
    auto engine = makeEngine();
    auto t = Clock::now();
    auto edit = makeEdit (*engine, tracks);
    buildLarge (*edit, clipsPerTrack);
    const double buildMs = msSince (t);
    auto file = dir.getChildFile ("te_bench_project.tracktionedit");

    t = Clock::now();
    te::EditFileOperations (*edit).writeToFile (file, false);
    const double saveMs = msSince (t);
    const auto bytes = file.getSize();
    edit.reset();

    t = Clock::now();
    auto loaded = te::loadEditFromFile (*engine, file, te::Edit::EditRole::forEditing);
    const double loadMs = msSince (t);
    const int loadedTracks = te::getAudioTracks (*loaded).size();
    file.deleteFile();

    std::printf ("{\"engine\":\"tracktion\",\"workload\":\"saveload\",\"tracks\":%d,\"clips_per_track\":%d,\"build_ms\":%.3f,"
                 "\"save_ms\":%.3f,\"load_ms\":%.3f,\"file_bytes\":%lld,\"loaded_tracks\":%d,\"rss_kb\":%ld}\n",
                 tracks, clipsPerTrack, buildMs, saveMs, loadMs, (long long) bytes, loadedTracks, rssKb());
    return 0;
}

static int cmdMemory (int tracks, int clipsPerTrack, int undoSteps)
{
    const long base = rssKb();
    auto engine = makeEngine();
    const long withEngine = rssKb();
    auto edit = makeEdit (*engine, tracks);
    auto& um = edit->getUndoManager();
    um.setMaxNumberOfStoredUnits (0, 1000000);
    buildLarge (*edit, clipsPerTrack);
    const long built = rssKb();
    // Undo history: change one note's velocity per step on a large clip.
    auto track = te::getAudioTracks (*edit)[0];
    auto clip = dynamic_cast<te::MidiClip*> (track->getClips()[0]);
    for (int i = 0; i < undoSteps; ++i)
    {
        um.beginNewTransaction();
        auto n = clip->getSequence().getNotes()[i % clip->getSequence().getNumNotes()];
        n->setVelocity (1 + i % 126, &um);
    }
    const long withUndo = rssKb();
    std::printf ("{\"engine\":\"tracktion\",\"workload\":\"memory\",\"tracks\":%d,\"clips_per_track\":%d,\"undo_steps\":%d,"
                 "\"rss_start_kb\":%ld,\"rss_engine_kb\":%ld,\"rss_built_kb\":%ld,\"rss_undo_kb\":%ld}\n",
                 tracks, clipsPerTrack, undoSteps, base, withEngine, built, withUndo);
    return 0;
}

/// Real-time playback through the hosted audio device: the engine's own
/// block processing, called back to back, timing every block.
static int cmdBlocks (int tracks, bool midi, bool fx, bool automation, int threads, int buffer, double seconds, const juce::File& wav)
{
    cpusForAudio = threads;
    auto engine = makeEngine();
    auto& dm = engine->getDeviceManager();
    dm.setCpuLimitBeforeMuting (1000.0);
    auto& io = dm.getHostedAudioDeviceInterface();
    te::HostedAudioDeviceInterface::Parameters params;
    params.sampleRate = 48000.0;
    params.blockSize = buffer;
    params.inputChannels = 0;
    params.outputChannels = 2;
    io.initialise (params);
    io.prepareToPlay (params.sampleRate, buffer);
    dm.dispatchPendingUpdates();

    auto edit = makeEdit (*engine, tracks);
    buildWorkload (*edit, midi, fx, automation, 16, wav);
    auto& transport = edit->getTransport();
    transport.setLoopRange (te::TimeRange (te::TimePosition(), te::TimePosition::fromSeconds (32.0)));
    transport.looping = true;
    transport.setPosition (te::TimePosition());
    transport.play (false);

    juce::AudioBuffer<float> audio (2, buffer);
    juce::MidiBuffer midiIn;
    // Warm up, as the DAW's script does, then measure.
    const int warm = (int) (0.2 * params.sampleRate / buffer);
    const int count = (int) (seconds * params.sampleRate / buffer);
    std::vector<double> times;
    times.reserve ((size_t) count);
    float peak = 0;
    for (int i = 0; i < warm + count; ++i)
    {
        audio.clear();
        auto t = Clock::now();
        io.processBlock (audio, midiIn);
        if (i >= warm)
            times.push_back (msSince (t));
        peak = std::max (peak, audio.getMagnitude (0, buffer));
    }
    transport.stop (false, false);
    std::sort (times.begin(), times.end());
    double sum = 0;
    for (auto t : times) sum += t;
    auto pct = [&] (double q) { return times[std::min (times.size() - 1, (size_t) (q * (double) times.size()))]; };
    const double budget = buffer * 1000.0 / params.sampleRate;
    std::printf ("{\"engine\":\"tracktion\",\"workload\":\"blocks\",\"tracks\":%d,\"kind\":\"%s\",\"fx\":%d,\"automation\":%d,"
                 "\"threads\":%d,\"buffer\":%d,\"seconds\":%.1f,\"edits\":0,\"blocks\":%zu,\"budget_ms\":%.4f,\"mean_ms\":%.4f,"
                 "\"p50_ms\":%.4f,\"p99_ms\":%.4f,\"p999_ms\":%.4f,\"max_ms\":%.4f,\"max_load\":%.3f,\"peak\":%.4f}\n",
                 tracks, midi ? "midi" : "audio", fx ? 1 : 0, automation ? 1 : 0, threads, buffer, seconds, times.size(), budget,
                 sum / (double) times.size(), pct (0.5), pct (0.99), pct (0.999), times.back(), times.back() / budget, peak);
    return 0;
}

static int cmdStartup()
{
    auto t = Clock::now();
    auto engine = makeEngine();
    auto edit = makeEdit (*engine, 1);
    std::printf ("{\"engine\":\"tracktion\",\"workload\":\"startup\",\"in_process_ms\":%.3f,\"rss_kb\":%ld}\n", msSince (t), rssKb());
    return 0;
}

int main (int argc, char** argv)
{
    juce::ScopedJuceInitialiser_GUI init;
    std::vector<std::string> a (argv + 1, argv + argc);
    auto num = [&] (size_t i, int def) { return i < a.size() ? std::stoi (a[i]) : def; };
    if (a.empty()) { std::cerr << "usage: see te_bench.cpp\n"; return 2; }
    int rc = 2;
    if (a[0] == "startup") rc = cmdStartup();
    else if (a[0] == "render" && a.size() >= 8)
        rc = cmdRender (num (1, 1), a[2] == "midi", num (3, 0) != 0, num (4, 0) != 0, num (5, 1), num (6, 16), juce::File (a[7]));
    else if (a[0] == "blocks" && a.size() >= 9)
        rc = cmdBlocks (num (1, 1), a[2] == "midi", num (3, 0) != 0, num (4, 0) != 0, num (5, 1), num (6, 256), std::stod (a[7]), juce::File (a[8]));
    else if (a[0] == "edit") rc = cmdEdit (num (1, 1000));
    else if (a[0] == "notes") rc = cmdNotes (num (1, 1000));
    else if (a[0] == "saveload" && a.size() >= 4) rc = cmdSaveLoad (num (1, 100), num (2, 8), juce::File (a[3]));
    else if (a[0] == "memory") rc = cmdMemory (num (1, 100), num (2, 8), num (3, 1000));
    std::fflush (stdout);
    return rc;
}
