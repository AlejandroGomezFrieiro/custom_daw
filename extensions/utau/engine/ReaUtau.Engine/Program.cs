using ReaUtau.Protocol;

namespace ReaUtau.Engine;

public static class Program
{
    public static int Main(string[] args)
    {
        Options opts;
        try { opts = Options.Parse(args); }
        catch (ArgumentException e) { Console.Error.WriteLine("reautau-engine: " + e.Message); return 2; }
        try
        {
            if (opts.ConvertPath.Length > 0) return Convert.Run(opts);
            if (opts.ExportPath.Length > 0) return Export.Run(opts);
            if (opts.InstallPath.Length > 0) return Install.Run(opts);
            return new EngineHost(opts).Run();
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("reautau-engine: fatal: " + e);
            return 1;
        }
    }
}
