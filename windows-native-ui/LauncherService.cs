using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace AudioLinkNativeUI;

public sealed class LauncherService
{
    public async Task<CommandResult> RunAudioLinkAsync(
        string workspacePath,
        IReadOnlyList<string> audioLinkArgs,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        var scriptPath = Path.Combine(workspacePath, "tools", "launcher", "audio-link.ps1");
        if (!File.Exists(scriptPath))
        {
            throw new FileNotFoundException($"No se encontro launcher: {scriptPath}");
        }

        var args = new List<string>
        {
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", scriptPath
        };
        args.AddRange(audioLinkArgs);

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (timeout.HasValue && timeout.Value > TimeSpan.Zero)
        {
            cts.CancelAfter(timeout.Value);
        }

        return await RunProcessAsync(
            "powershell.exe",
            args,
            workspacePath,
            cts.Token,
            timeout);
    }

    public async Task<DesktopDeviceProbeResult> ListDesktopDevicesAsync(
        string workspacePath,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        var senderDir = Path.Combine(workspacePath, "windows-sender");
        var senderExe = Path.Combine(senderDir, "target", "release", "windows-sender.exe");
        if (!Directory.Exists(senderDir))
        {
            throw new DirectoryNotFoundException($"No existe windows-sender: {senderDir}");
        }

        if (!File.Exists(senderExe))
        {
            var cargoExe = ResolveCargoPath();
            if (string.IsNullOrWhiteSpace(cargoExe))
            {
                throw new InvalidOperationException("No se encontro cargo para compilar windows-sender.");
            }

            var build = await RunProcessAsync(
                cargoExe,
                new[] { "build", "--release" },
                senderDir,
                cancellationToken,
                timeout);

            if (!build.Success || !File.Exists(senderExe))
            {
                throw new InvalidOperationException(
                    $"No se pudo compilar windows-sender (--release).\n{build.OutputTrimmed}");
            }
        }

        var probe = await RunProcessAsync(
            senderExe,
            new[] { "--list-desktop-devices" },
            senderDir,
            cancellationToken,
            timeout);

        if (!probe.Success)
        {
            throw new InvalidOperationException($"Fallo al listar dispositivos.\n{probe.OutputTrimmed}");
        }

        var devices = ParseDesktopDeviceOutput(probe.StdOut);
        return new DesktopDeviceProbeResult(devices, probe);
    }

    public static string? ResolveCargoPath()
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var entry in path.Split(Path.PathSeparator))
        {
            try
            {
                if (string.IsNullOrWhiteSpace(entry))
                {
                    continue;
                }

                var candidate = Path.Combine(entry.Trim(), "cargo.exe");
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
            catch
            {
            }
        }

        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var fallback = Path.Combine(userProfile, ".cargo", "bin", "cargo.exe");
        return File.Exists(fallback) ? fallback : null;
    }

    private static IReadOnlyList<DesktopDevice> ParseDesktopDeviceOutput(string output)
    {
        var result = new List<DesktopDevice>();
        var lines = output.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        var rx = new Regex(@"^\*\s+(.+?)(\s+\[default\])?$", RegexOptions.Compiled);

        foreach (var raw in lines)
        {
            var line = raw.Trim();
            var match = rx.Match(line);
            if (!match.Success)
            {
                continue;
            }

            var name = match.Groups[1].Value.Trim();
            if (string.IsNullOrWhiteSpace(name))
            {
                continue;
            }

            var isDefault = line.EndsWith("[default]", StringComparison.OrdinalIgnoreCase);
            result.Add(new DesktopDevice(name, isDefault));
        }

        return result;
    }

    private static async Task<CommandResult> RunProcessAsync(
        string fileName,
        IEnumerable<string> arguments,
        string workingDirectory,
        CancellationToken cancellationToken,
        TimeSpan? timeout = null)
    {
        using var process = new Process();
        process.StartInfo.FileName = fileName;
        process.StartInfo.WorkingDirectory = workingDirectory;
        process.StartInfo.UseShellExecute = false;
        process.StartInfo.CreateNoWindow = true;
        process.StartInfo.RedirectStandardOutput = true;
        process.StartInfo.RedirectStandardError = true;
        process.StartInfo.StandardOutputEncoding = Encoding.UTF8;
        process.StartInfo.StandardErrorEncoding = Encoding.UTF8;

        foreach (var arg in arguments)
        {
            process.StartInfo.ArgumentList.Add(arg);
        }

        if (!process.Start())
        {
            throw new InvalidOperationException($"No se pudo iniciar proceso: {fileName}");
        }

        var stdOutTask = process.StandardOutput.ReadToEndAsync();
        var stdErrTask = process.StandardError.ReadToEndAsync();
        using var registration = cancellationToken.Register(() =>
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            catch
            {
            }
        });

        try
        {
            await process.WaitForExitAsync(cancellationToken);
        }
        catch (OperationCanceledException ex)
        {
            if (timeout.HasValue && timeout.Value > TimeSpan.Zero)
            {
                throw new TimeoutException(
                    $"Tiempo de espera agotado ({(int)timeout.Value.TotalSeconds}s) al ejecutar comando.",
                    ex);
            }

            throw;
        }

        await Task.WhenAll(stdOutTask, stdErrTask);

        return new CommandResult(
            process.ExitCode == 0,
            process.ExitCode,
            stdOutTask.Result,
            stdErrTask.Result);
    }
}

public sealed record CommandResult(
    bool Success,
    int ExitCode,
    string StdOut,
    string StdErr)
{
    public string OutputTrimmed
    {
        get
        {
            var output = string.IsNullOrWhiteSpace(StdErr)
                ? StdOut
                : string.IsNullOrWhiteSpace(StdOut)
                    ? StdErr
                    : $"{StdOut}\n{StdErr}";
            return output.Trim();
        }
    }
}

public sealed record DesktopDevice(string Name, bool IsDefault);

public sealed record DesktopDeviceProbeResult(
    IReadOnlyList<DesktopDevice> Devices,
    CommandResult RawResult);
