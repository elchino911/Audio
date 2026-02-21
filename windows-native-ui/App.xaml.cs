using System.Configuration;
using System.Data;
using System.Windows;

namespace AudioLinkNativeUI;

public partial class App : Application
{
    public static string? WorkspaceFromArgs { get; private set; }

    protected override void OnStartup(StartupEventArgs e)
    {
        ParseArgs(e.Args);
        base.OnStartup(e);
    }

    private static void ParseArgs(string[] args)
    {
        if (args.Length == 0)
        {
            return;
        }

        for (var i = 0; i < args.Length; i++)
        {
            if (args[i].Equals("--workspace", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                WorkspaceFromArgs = args[i + 1];
                i++;
            }
        }
    }
}

