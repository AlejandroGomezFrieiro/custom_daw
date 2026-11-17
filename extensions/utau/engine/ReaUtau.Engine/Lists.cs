using OpenUtau.Api;
using OpenUtau.Core;
using OpenUtau.Core.Render;
using OpenUtau.Core.Ustx;
using ReaUtau.Protocol;
using Log = Serilog.Log;

namespace ReaUtau.Engine;

/// <summary>Builds the three unsolicited registries from OpenUtau's own sources (docs/protocol.md section 7.3).</summary>
static class Lists
{
    static readonly string[] RendererIds =
    {
        Renderers.WORLDLINE_R, Renderers.WORLDLINE_R11, Renderers.WORLDLINE_R2, Renderers.CLASSIC,
        Renderers.ENUNU, Renderers.VOGEN, Renderers.DIFFSINGER, Renderers.VOICEVOX,
    };

    // multi-bank DiffSinger packs ship a top-level character.txt, which OpenUtau also registers as an empty classic
    // singer ("No Name (...)"): a classic singer with no oto.ini anywhere in its folder cannot sing - hide it
    static readonly System.Collections.Concurrent.ConcurrentDictionary<string, bool> singable = new();
    static bool Singable(USinger s)
    {
        if (s.SingerType != USingerType.Classic || string.IsNullOrEmpty(s.Location)) return true;
        return singable.GetOrAdd(s.Location, loc =>
        {
            try { return Directory.EnumerateFiles(loc, "oto.ini", SearchOption.AllDirectories).Any(); }
            catch { return true; }
        });
    }

    public static void SendSingers(IEngineConnection conn)
    {
        var singers = SingerManager.Inst.Singers.Values
            .Where(Singable)
            .OrderBy(s => s.Name, StringComparer.OrdinalIgnoreCase)
            .Select(s => new SingerInfo
            {
                Id = s.Id,
                Name = s.Name,
                SingerType = TypeName(s.SingerType),
                ImagePath = s.Avatar ?? "",
                Location = s.Location ?? "",
                Author = s.Author ?? "",
                VoiceColors = s.Subbanks.Select(b => b.Color).ToHashSet().OrderBy(c => c).ToArray(),
                Subbanks = s.Subbanks
                    .Select(b => new Subbank { Color = b.Color ?? "", Prefix = b.Prefix ?? "", Suffix = b.Suffix ?? "" })
                    .ToArray(),
                DefaultPhonemizer = ProjectMirror.DefaultPhonemizerFor(s)?.type.FullName ?? s.DefaultPhonemizer ?? "",
            })
            .ToArray();
        conn.Send(new SingerList { Singers = singers });
    }

    public static void SendRenderers(IEngineConnection conn)
    {
        var renderers = RendererIds.Select(id => Describe(id)).ToArray();
        // without libworldline OpenUtau's two built-in resamplers cannot run: not offered (an empty list is what the track
        // panel turns into the "no resampler" message)
        var resamplers = OpenUtau.Classic.ToolsManager.Inst.Resamplers
            .Where(r => Bootstrap.WorldlineAvailable || r.GetType().Name == "ExeResampler")
            .Select(r => r.ToString()).ToArray();
        var wavtools = OpenUtau.Classic.ToolsManager.Inst.Wavtools.Select(w => w.ToString()).ToArray();
        conn.Send(new RendererList { Renderers = renderers, Resamplers = resamplers, Wavtools = wavtools });
    }

    public static void SendPhonemizers(IEngineConnection conn)
    {
        var phonemizers = PhonemizerFactory.GetAll()
            .Where(f => f?.type != null)
            .OrderBy(f => f.tag)
            .ThenBy(f => f.name)
            .Select(f => new PhonemizerInfo
            {
                Id = f.type.FullName ?? f.type.Name,
                Name = f.name ?? "",
                Tag = f.tag ?? "",
                Language = f.language ?? "",
            })
            .ToArray();
        conn.Send(new PhonemizerList { Phonemizers = phonemizers });
    }

    static RendererInfo Describe(string id)
    {
        var singerTypes = Enum.GetValues<USingerType>()
            .Where(t => Renderers.GetSupportedRenderers(t).Contains(id))
            .Select(TypeName)
            .Distinct()
            .ToArray();
        ExpressionDesc[] expressions = Array.Empty<ExpressionDesc>();
        try
        {
            var renderer = Renderers.GetOrCreate(id);
            if (renderer != null)
            {
                // One representative singer supplies voice-color/extension expressions (DiffSinger, ENUNU).
                USinger? singer = singerTypes.Length > 0
                    ? SingerManager.Inst.Singers.Values.FirstOrDefault(s => singerTypes.Contains(TypeName(s.SingerType)))
                    : null;
                var settings = new URenderSettings { renderer = id };
                if (singer != null) settings.Validate(new UTrack(new UProject()) { Singer = singer });
                // the standard project expressions this renderer honours (OpenUtau greys out the others), then its own
                // suggested extras (DiffSinger energy/velocity/voice-colour blends, ...)
                var proto = new UProject();
                OpenUtau.Core.Format.Ustx.AddDefaultExpressions(proto);
                var standard = proto.expressions.Values
                    .Where(d => d != null && SafeSupports(renderer, d));
                var suggested = (renderer.GetSuggestedExpressions(singer!, settings) ?? Array.Empty<UExpressionDescriptor>())
                    .Where(d => d != null);
                expressions = standard.Concat(suggested)
                    .GroupBy(d => d.abbr).Select(gr => gr.First())
                    .Select(Map)
                    .ToArray();
            }
        }
        catch (Exception e)
        {
            Log.Debug("renderer {Renderer}: expression list unavailable: {Message}", id, e.Message);
        }
        return new RendererInfo
        {
            Id = id,
            Name = id,
            SingerTypes = singerTypes,
            Expressions = expressions,
        };
    }

    static bool SafeSupports(IRenderer r, UExpressionDescriptor d)
    {
        try { return r.SupportsExpression(d); } catch { return false; }
    }

    static ExpressionDesc Map(UExpressionDescriptor d) => new()
    {
        Abbr = d.abbr ?? "",
        Name = d.name ?? "",
        Min = d.min,
        Max = d.max,
        DefaultValue = d.CustomDefaultValue,
        Kind = d.isFlag ? ExprKind.Flag
            : d.type == UExpressionType.Options ? ExprKind.Options
            : d.type == UExpressionType.Curve ? ExprKind.Curve
            : ExprKind.Numerical,
        Options = d.options ?? Array.Empty<string>(),
    };

    /// <summary>USingerType lower-cased as the protocol expects; note OpenUtau's own map calls Classic "utau".</summary>
    public static string TypeName(USingerType t) => t switch
    {
        USingerType.Classic => "classic",
        USingerType.Enunu => "enunu",
        USingerType.Vogen => "vogen",
        USingerType.DiffSinger => "diffsinger",
        USingerType.Voicevox => "voicevox",
        _ => t.ToString().ToLowerInvariant(),
    };
}
