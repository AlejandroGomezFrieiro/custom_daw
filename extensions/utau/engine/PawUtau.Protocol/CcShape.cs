// Exact evaluator for the shapes of curve points (square, linear, slow start/end, fast start, fast end, bezier).
// A segment between consecutive points i, i+1 uses the shape/tension stored on point i; shapes are functions of the
// PPQ (here: tick) position. Bezier segments depend on the neighbouring points, so evaluate over the whole list.
namespace PawUtau.Protocol;

public static class CcShapeId { public const int Square = 0, Linear = 1, SlowStartEnd = 2, FastStart = 3, FastEnd = 4, Bezier = 5; }

public struct CcPoint
{
    public double Ppq, Value;
    public int Shape;
    public double Tension;
    public CcPoint(double ppq, double value, int shape = CcShapeId.Square, double tension = 0) { Ppq = ppq; Value = value; Shape = shape; Tension = tension; }
}

public struct SegmentContext
{
    public double Span = 1.0;
    public bool HasPrev;
    public double PrevValue, PrevSpan = 1.0;
    public bool HasNext;
    public double NextValue, NextSpan = 1.0;
    public SegmentContext() { }
}

public readonly record struct BezierCtrl(double X1, double Y1, double X2, double Y2);

public readonly record struct RawCc(double Ppq, int Cc, int Value, int Shape = CcShapeId.Square, double Tension = 0);

public static class CcShape
{
    public const int Cc14Max = 16383;
    public const int PitchbendCenter = 8192;

    private static double BezierYAt(BezierCtrl c, double t)
    {
        double Bx(double u) { double m = 1.0 - u; return 3.0 * m * m * u * c.X1 + 3.0 * m * u * u * c.X2 + u * u * u; }
        double Dbx(double u) { double m = 1.0 - u; return 3.0 * m * m * c.X1 + 6.0 * m * u * (c.X2 - c.X1) + 3.0 * u * u * (1.0 - c.X2); }
        double lo = 0.0, hi = 1.0, uu = t;
        for (int i = 0; i < 64; i++)
        {
            double x = Bx(uu) - t;
            if (Math.Abs(x) < 1e-13) break;
            if (x > 0) hi = uu; else lo = uu;
            double d = Dbx(uu);
            double nu = d > 1e-12 ? uu - x / d : 0.5 * (lo + hi);
            if (!(nu > lo && nu < hi)) nu = 0.5 * (lo + hi);
            uu = nu;
        }
        double mm = 1.0 - uu;
        return 3.0 * mm * mm * uu * c.Y1 + 3.0 * mm * uu * uu * c.Y2 + uu * uu * uu;
    }

    private static double Clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

    public static BezierCtrl BezierControl(double tension, double v0, double v1, in SegmentContext ctx)
    {
        double k = Clamp(tension, -1.0, 1.0);
        double delta = v1 - v0;
        double y1 = 0.0, y2 = 1.0;
        if (delta != 0.0)
        {
            double inTerm = ctx.HasPrev ? (v0 - ctx.PrevValue) * (ctx.Span / ctx.PrevSpan) : 0.0;
            double outTerm = ctx.HasNext ? (ctx.NextValue - v1) * (ctx.Span / ctx.NextSpan) : 0.0;
            y1 = Clamp(0.125 * (inTerm + delta) / delta, 0.0, 1.0);
            y2 = Clamp(1.0 - 0.125 * (delta + outTerm) / delta, 0.0, 1.0);
        }
        if (k >= 0.0) return new BezierCtrl(0.25 + 0.75 * k, (1.0 - k) * y1, 0.75 + 0.25 * k, (1.0 - k) * y2);
        return new BezierCtrl(0.25 * (1.0 + k), y1 + (-k) * (1.0 - y1), 0.75 * (1.0 + k), y2 + (-k) * (1.0 - y2));
    }

    private static double UnitShape(int shape, double tension, double t, double v0, double v1, in SegmentContext ctx)
    {
        if (t <= 0.0) return 0.0;
        if (t >= 1.0) return 1.0;
        switch (shape)
        {
            case CcShapeId.Linear: return t;
            case CcShapeId.SlowStartEnd: return t * t * (3.0 - 2.0 * t);
            case CcShapeId.FastStart: { double m = 1.0 - t; return 1.0 - m * m * m; }
            case CcShapeId.FastEnd: return t * t * t;
            case CcShapeId.Bezier: return BezierYAt(BezierControl(tension, v0, v1, ctx), t);
            default: return 0.0;
        }
    }

    public static double ShapeUnit(int shape, double tension, double t01) => UnitShape(shape, tension, t01, 0.0, 1.0, new SegmentContext());

    public static double EvalShape(int shape, double tension, double t01, double v0, double v1) =>
        EvalSegment(shape, tension, t01, v0, v1, new SegmentContext());

    public static double EvalSegment(int shape, double tension, double t01, double v0, double v1, in SegmentContext ctx) =>
        v0 + (v1 - v0) * UnitShape(shape, tension, t01, v0, v1, ctx);

    private static SegmentContext ContextFor(ReadOnlySpan<CcPoint> pts, int i)
    {
        var c = new SegmentContext { Span = pts[i + 1].Ppq - pts[i].Ppq };
        if (i > 0 && pts[i].Ppq > pts[i - 1].Ppq) { c.HasPrev = true; c.PrevValue = pts[i - 1].Value; c.PrevSpan = pts[i].Ppq - pts[i - 1].Ppq; }
        if (i + 2 < pts.Length && pts[i + 2].Ppq > pts[i + 1].Ppq) { c.HasNext = true; c.NextValue = pts[i + 2].Value; c.NextSpan = pts[i + 2].Ppq - pts[i + 1].Ppq; }
        return c;
    }

    /// <summary>pts sorted by ppq ascending (ties allowed: the last tied point wins). Holds the first/last value outside the list.</summary>
    public static double EvalPoints(ReadOnlySpan<CcPoint> pts, double ppq)
    {
        int n = pts.Length;
        if (n == 0) return 0.0;
        if (ppq < pts[0].Ppq) return pts[0].Value;
        int lo = 0, hi = n;
        while (hi - lo > 1)
        {
            int mid = (lo + hi) / 2;
            if (pts[mid].Ppq <= ppq) lo = mid; else hi = mid;
        }
        var a = pts[lo];
        if (lo + 1 >= n) return a.Value;
        var b = pts[lo + 1];
        double span = b.Ppq - a.Ppq;
        if (span <= 0.0) return a.Value;
        var ctx = a.Shape == CcShapeId.Bezier ? ContextFor(pts, lo) : new SegmentContext();
        return EvalSegment(a.Shape, a.Tension, (ppq - a.Ppq) / span, a.Value, b.Value, ctx);
    }

    /// <summary>out[i] = value at start + i*step. O(n + count).</summary>
    public static void SamplePoints(ReadOnlySpan<CcPoint> pts, double start, double step, Span<double> output)
    {
        int n = pts.Length, seg = 0, ctxSeg = -1;
        var ctx = new SegmentContext();
        for (int i = 0; i < output.Length; i++)
        {
            double p = start + step * i;
            if (n == 0) { output[i] = 0.0; continue; }
            if (p < pts[0].Ppq) { output[i] = pts[0].Value; continue; }
            while (seg + 1 < n && pts[seg + 1].Ppq <= p) seg++;
            if (seg + 1 >= n) { output[i] = pts[seg].Value; continue; }
            double span = pts[seg + 1].Ppq - pts[seg].Ppq;
            if (span <= 0.0) { output[i] = pts[seg].Value; continue; }
            if (pts[seg].Shape == CcShapeId.Bezier && ctxSeg != seg) { ctx = ContextFor(pts, seg); ctxSeg = seg; }
            output[i] = EvalSegment(pts[seg].Shape, pts[seg].Tension, (p - pts[seg].Ppq) / span, pts[seg].Value, pts[seg + 1].Value,
                pts[seg].Shape == CcShapeId.Bezier ? ctx : new SegmentContext());
        }
    }

    // ---- 14-bit helpers ---------------------------------------------------------------------------------------------
    public static int Combine14(int msb, int lsb) => ((msb & 127) << 7) | (lsb & 127);
    public static void Split14(int v14, out int msb, out int lsb)
    {
        v14 = Math.Clamp(v14, 0, Cc14Max);
        msb = v14 >> 7; lsb = v14 & 127;
    }
    public static int LsbFor(int msbCc) => msbCc + 32;

    public static double PitchbendToSemitones(double v14, double range) => (v14 - PitchbendCenter) / PitchbendCenter * range;
    public static int SemitonesToPitchbend(double semis, double range)
    {
        if (range <= 0.0) return PitchbendCenter;
        double v = PitchbendCenter + semis / range * PitchbendCenter;
        return (int)Math.Round(Math.Clamp(v, 0.0, Cc14Max), MidpointRounding.AwayFromZero);
    }
    public static double PitchbendToCents(int v14, double range) => PitchbendToSemitones(v14, range) * 100.0;

    /// <summary>Merge MSB (cc n) and LSB (cc n+32) events into 14-bit points (same rules as build_14bit_points).</summary>
    public static List<CcPoint> Build14BitPoints(IEnumerable<RawCc> events, int msbCc)
    {
        int lsbCc = LsbFor(msbCc);
        var sel = events.Where(e => e.Cc == msbCc || e.Cc == lsbCc).OrderBy(e => e.Ppq).ToList();  // OrderBy is stable
        var outp = new List<CcPoint>();
        int msb = 0, lsb = 0, i = 0;
        while (i < sel.Count)
        {
            double ppq = sel[i].Ppq;
            bool haveMsb = false, haveLsb = false;
            int shape = CcShapeId.Square, lsbShape = CcShapeId.Square;
            double tension = 0, lsbTension = 0;
            for (; i < sel.Count && sel[i].Ppq == ppq; i++)
            {
                if (sel[i].Cc == msbCc) { msb = sel[i].Value & 127; haveMsb = true; shape = sel[i].Shape; tension = sel[i].Tension; }
                else { lsb = sel[i].Value & 127; haveLsb = true; lsbShape = sel[i].Shape; lsbTension = sel[i].Tension; }
            }
            if (!haveMsb) { shape = lsbShape; tension = lsbTension; }
            if (haveMsb && !haveLsb) lsb = 0;
            outp.Add(new CcPoint(ppq, Combine14(msb, lsb), shape, tension));
        }
        return outp;
    }

    /// <summary>
    /// Engine helper: sample a part's sparse knots onto OpenUtau's 5-tick grid (x = 0, 5, 10, ... through durTick, inclusive of
    /// the last grid point &lt;= durTick). Values are rounded half away from zero because UCurve stores ints.
    /// </summary>
    public static (int[] Xs, int[] Ys) SampleKnotsOnGrid(Knot[] knots, int durTick, int step = Proto.CurveGridTicks)
    {
        var pts = new CcPoint[knots.Length];
        for (int i = 0; i < knots.Length; i++) pts[i] = new CcPoint(knots[i].Tick, knots[i].Value, knots[i].Shape, knots[i].Tension);
        int count = durTick / step + 1;
        var vals = new double[count];
        SamplePoints(pts, 0, step, vals);
        var xs = new int[count];
        var ys = new int[count];
        for (int i = 0; i < count; i++) { xs[i] = i * step; ys[i] = (int)Math.Round(vals[i], MidpointRounding.AwayFromZero); }
        return (xs, ys);
    }
}

/// <summary>Mapping raw 14-bit curve values to OpenUtau units.</summary>
public sealed record CurveDef(string Abbr, int CcMsb, double Min, double Max, double Default, int PbChan = 0)
{
    public static readonly CurveDef[] All =
    {
        new("pitd", -1, -1200, 1200, 0), new("dyn", 16, -240, 120, 0), new("tenc", 17, -100, 100, 0), new("brec", 18, -100, 100, 0),
        new("genc", 19, -100, 100, 0), new("voic", 20, 0, 100, 100), new("shfc", 21, -1200, 1200, 0), new("grwc", 22, 0, 100, 0),
        new("xsy", 23, 0, 100, 0),
        // renderer-specific curves on pitchbend lanes, MIDI channels 2..16
        new("velc", -1, 0, 200, 100, 1), new("ene", -1, -100, 100, 0, 2), new("pexp", -1, 0, 100, 100, 3),
        new("volc", -1, 0, 200, 100, 4), new("smoc", -1, 0, 10, 0, 5),
        new("cl01", -1, 0, 100, 0, 6), new("cl02", -1, 0, 100, 0, 7), new("cl03", -1, 0, 100, 0, 8), new("cl04", -1, 0, 100, 0, 9),
        new("cl05", -1, 0, 100, 0, 10), new("cl06", -1, 0, 100, 0, 11), new("cl07", -1, 0, 100, 0, 12), new("cl08", -1, 0, 100, 0, 13),
        new("cl09", -1, 0, 100, 0, 14), new("cl10", -1, 0, 100, 0, 15),
        // macro lanes: custom input curves of a track's expression graph, CC 24..31
        new("mc1", 24, 0, 100, 0), new("mc2", 25, 0, 100, 0), new("mc3", 26, 0, 100, 0), new("mc4", 27, 0, 100, 0),
        new("mc5", 28, 0, 100, 0), new("mc6", 29, 0, 100, 0), new("mc7", 30, 0, 100, 0), new("mc8", 31, 0, 100, 0),
    };
    public static CurveDef? Find(string abbr) => All.FirstOrDefault(d => d.Abbr == abbr);
    public static CurveDef? FindByCc(int cc) => All.FirstOrDefault(d => d.CcMsb == cc);

    public double Raw14ToValue(double raw, double pitchBendRange = 12.0)
    {
        double v = CcMsb < 0 && PbChan == 0 ? (raw - 8192.0) / 8192.0 * pitchBendRange * 100.0 : Min + raw / 16383.0 * (Max - Min);
        return Math.Clamp(v, Min, Max);
    }
    public int ValueToRaw14(double value, double pitchBendRange = 12.0)
    {
        double raw = CcMsb < 0 && PbChan == 0 ? 8192.0 + value / (pitchBendRange * 100.0) * 8192.0 : (value - Min) / (Max - Min) * 16383.0;
        return (int)Math.Round(Math.Clamp(raw, 0.0, 16383.0), MidpointRounding.AwayFromZero);
    }
}
