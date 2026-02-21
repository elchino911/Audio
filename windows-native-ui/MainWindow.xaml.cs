using System.Diagnostics;
using System.IO;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace AudioLinkNativeUI;

public partial class MainWindow : Window
{
    private readonly LauncherService _launcher = new();
    private readonly DispatcherTimer _statusTimer = new() { Interval = TimeSpan.FromSeconds(2.5) };
    private static readonly TimeSpan StatusTimeout = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan LogsTimeout = TimeSpan.FromSeconds(25);
    private static readonly TimeSpan DevicesTimeout = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan HardUiActionTimeout = TimeSpan.FromSeconds(28);

    private readonly SolidColorBrush _runningBrush = new(Color.FromRgb(16, 185, 129));
    private readonly SolidColorBrush _stoppedBrush = new(Color.FromRgb(245, 158, 11));
    private readonly SolidColorBrush _unknownBrush = new(Color.FromRgb(168, 85, 247));

    private string _workspacePath = string.Empty;
    private UiMode _currentMode = UiMode.Basic;
    private AppPage _currentPage = AppPage.Dashboard;
    private bool _busy;
    private bool _statusRefreshing;
    private bool _muteEventsSuppressed;
    private bool _downWasRunningBeforeMute;
    private bool _upWasRunningBeforeMute;
    private StatusSnapshot _lastStatus = StatusSnapshot.Empty;

    public MainWindow()
    {
        InitializeComponent();
        SeedControls();
        _statusTimer.Tick += StatusTimer_Tick;
    }

    private void SeedControls()
    {
        FillCombo(UiModeCombo, ["Basico", "Avanzado"], "Basico");
        FillCombo(GlobalProfileCombo, ["both", "downlink", "uplink"], "both");
        FillCombo(LogsProfileCombo, ["both", "downlink", "uplink"], "both");
        FillCombo(LogsTailCombo, ["40", "80", "120", "200"], "80");

        FillCombo(DownModeCombo, ["network", "usb"], "network");
        FillCombo(DownSourceCombo, ["desktop", "mic"], "desktop");
        FillCombo(DownPortCombo, ["50000"], "50000");
        FillCombo(DownFrameCombo, ["2", "5", "10", "15", "20"], "5");
        FillCombo(DownJitterCombo, ["10", "15", "20", "25", "30", "35", "40", "50"], "20");
        FillCombo(DownTransportCombo, ["udp", "tcp"], "udp");
        FillCombo(DownAutoReconnectCombo, ["true", "false"], "true");
        DownUsbWatchdogBox.Text = "1500";

        FillCombo(UpPortCombo, ["50010"], "50010");
        FillCombo(UpFrameCombo, ["2", "5", "10", "15", "20"], "5");
        FillCombo(UpTransportCombo, ["tcp", "udp"], "tcp");
        FillCombo(UpMicSourceCombo, ["auto", "phone", "bluetooth"], "auto");
        FillCombo(UpTargetBufferCombo, ["30", "50", "80", "100"], "50");
        FillCombo(UpMaxBufferCombo, ["150", "250", "500", "1000"], "250");
        UpOutputDeviceBox.Text = "CABLE Input (VB-Audio Virtual Cable)";

        DownTargetIpBox.Text = string.Empty;
        UpTargetIpBox.Text = GetLocalIpv4Hint();
        UplinkBasicHintText.Text = "Modo basico: solo bridge de escucha en Windows. Android define destino/puerto/frame/transporte.";
        DownSkipBuildCheck.IsChecked = true;
        UpSkipBuildBridgeCheck.IsChecked = true;
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        try
        {
            _muteEventsSuppressed = true;
            _workspacePath = ResolveWorkspacePath();
            WorkspaceBox.Text = _workspacePath;
            ApplyMode(UiMode.Basic);
            ShowPage(AppPage.Dashboard);
            DownSourceCombo_SelectionChanged(this, new SelectionChangedEventArgs(Selector.SelectionChangedEvent, new List<object>(), new List<object>()));

            await RunWithLoadingAsync("Inicializando UI nativa...", async () =>
            {
                using var initCts = new CancellationTokenSource(TimeSpan.FromSeconds(45));
                await RefreshStatusAsync(logOutput: false, initCts.Token);
                await ReloadDesktopDevicesAsync(logOutput: false, initCts.Token);
                await ReloadLogsAsync(logOutput: false, initCts.Token);
            });

            AppendActionOutput("UI nativa lista.");
            _statusTimer.Start();
        }
        finally
        {
            _muteEventsSuppressed = false;
        }
    }

    private async void StatusTimer_Tick(object? sender, EventArgs e)
    {
        if (_statusRefreshing || _busy)
        {
            return;
        }

        _statusRefreshing = true;
        try
        {
            await RefreshStatusAsync(logOutput: false);
        }
        catch
        {
        }
        finally
        {
            _statusRefreshing = false;
        }
    }

    private async Task RefreshStatusAsync(bool logOutput, CancellationToken cancellationToken = default)
    {
        var args = new List<string>
        {
            "-Action", "status",
            "-Profile", "both",
            "-Workspace", WorkspaceBox.Text.Trim()
        };

        var result = await _launcher.RunAudioLinkAsync(WorkspaceBox.Text.Trim(), args, StatusTimeout, cancellationToken);
        var output = result.OutputTrimmed;
        if (!result.Success)
        {
            throw new InvalidOperationException($"Status fallo: {output}");
        }

        _lastStatus = ParseStatus(output);
        UpdateStatusUi(_lastStatus);

        if (logOutput)
        {
            AppendActionOutput(output);
        }
    }

    private async Task ReloadLogsAsync(bool logOutput, CancellationToken cancellationToken = default)
    {
        var profile = SelectedText(LogsProfileCombo, "both");
        var tail = SelectedText(LogsTailCombo, "80");
        var args = new List<string>
        {
            "-Action", "logs",
            "-Profile", profile,
            "-Workspace", WorkspaceBox.Text.Trim(),
            "-Tail", tail
        };

        var result = await _launcher.RunAudioLinkAsync(WorkspaceBox.Text.Trim(), args, LogsTimeout, cancellationToken);
        var output = result.OutputTrimmed;
        LogsOutputBox.Text = output;
        if (logOutput)
        {
            AppendActionOutput(output);
        }
    }

    private async Task ReloadDesktopDevicesAsync(bool logOutput, CancellationToken cancellationToken = default)
    {
        var selectedName = GetSelectedDesktopDeviceValue();
        var probe = await _launcher.ListDesktopDevicesAsync(WorkspaceBox.Text.Trim(), DevicesTimeout, cancellationToken);

        var options = new List<DeviceOption>
        {
            new("", "(default output)")
        };
        options.AddRange(probe.Devices.Select(d => new DeviceOption(d.Name, d.IsDefault ? $"{d.Name} (default)" : d.Name)));

        DownDesktopDeviceCombo.Items.Clear();
        foreach (var option in options)
        {
            DownDesktopDeviceCombo.Items.Add(option);
        }

        var match = options.FirstOrDefault(o => o.Name.Equals(selectedName, StringComparison.OrdinalIgnoreCase));
        if (match is not null)
        {
            DownDesktopDeviceCombo.SelectedItem = match;
        }
        else if (!string.IsNullOrWhiteSpace(selectedName))
        {
            DownDesktopDeviceCombo.Text = selectedName;
        }
        else
        {
            DownDesktopDeviceCombo.SelectedIndex = 0;
        }

        if (logOutput)
        {
            AppendActionOutput($"Desktop devices: {probe.Devices.Count}");
        }
    }

    private async Task ExecuteActionAsync(string action, string profile, bool? forceUpStartAndroidMic = null, bool refreshLogs = true)
    {
        if (_busy)
        {
            AppendActionOutput("Hay una accion en curso, espera a que termine.");
            return;
        }

        _busy = true;
        SetLoading(true, $"Ejecutando {action}:{profile}...");
        try
        {
            ValidateBeforeAction(action, profile);

            using var hardCts = new CancellationTokenSource(HardUiActionTimeout);
            await Task.Run(async () =>
            {
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(hardCts.Token);
                cts.CancelAfter(GetActionTimeout(action) + TimeSpan.FromSeconds(5));
                var args = BuildActionArgs(action, profile, forceUpStartAndroidMic);
                CommandResult result;
                string output;
                try
                {
                    result = await _launcher.RunAudioLinkAsync(
                        WorkspaceBox.Text.Trim(),
                        args,
                        GetActionTimeout(action),
                        cts.Token);
                    output = result.OutputTrimmed;
                }
                catch (TimeoutException)
                {
                    var applied = await VerifyStateAfterTimeoutAsync(action, profile);
                    if (!applied)
                    {
                        throw;
                    }
                    AppendActionOutput($"Aviso: timeout esperando respuesta de script, pero el estado '{action}:{profile}' ya se aplico.");
                    await RefreshStatusAsync(logOutput: false);
                    return;
                }
                catch (OperationCanceledException)
                {
                    var applied = await VerifyStateAfterTimeoutAsync(action, profile);
                    if (!applied)
                    {
                        throw new TimeoutException($"Tiempo agotado en accion {action}:{profile}.");
                    }
                    AppendActionOutput($"Aviso: accion {action}:{profile} se aplico pero la respuesta no llego a tiempo.");
                    await RefreshStatusAsync(logOutput: false);
                    return;
                }

                if (!result.Success)
                {
                    throw new InvalidOperationException(ExtractFriendlyError(output));
                }

                if (!string.IsNullOrWhiteSpace(output))
                {
                    AppendActionOutput(output);
                }

                await RefreshStatusAsync(logOutput: false, cts.Token);
                if (refreshLogs && _currentMode == UiMode.Advanced)
                {
                    await ReloadLogsAsync(logOutput: false, cts.Token);
                }
            }, hardCts.Token);
        }
        catch (TimeoutException ex)
        {
            AppendActionOutput($"ERROR: {ex.Message}");
        }
        catch (OperationCanceledException)
        {
            AppendActionOutput($"ERROR: Tiempo agotado en accion {action}:{profile}.");
        }
        catch (Exception ex)
        {
            AppendActionOutput($"ERROR: {ex.Message}");
        }
        finally
        {
            SetLoading(false, string.Empty);
            _busy = false;
        }
    }

    private static TimeSpan GetActionTimeout(string action)
    {
        if (action.Equals("start", StringComparison.OrdinalIgnoreCase) ||
            action.Equals("restart", StringComparison.OrdinalIgnoreCase))
        {
            return TimeSpan.FromSeconds(18);
        }
        if (action.Equals("stop", StringComparison.OrdinalIgnoreCase))
        {
            return TimeSpan.FromSeconds(20);
        }
        return TimeSpan.FromSeconds(30);
    }

    private async Task<bool> VerifyStateAfterTimeoutAsync(string action, string profile)
    {
        try
        {
            using var verifyCts = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            var args = new List<string>
            {
                "-Action", "status",
                "-Profile", "both",
                "-Workspace", WorkspaceBox.Text.Trim()
            };
            var result = await _launcher.RunAudioLinkAsync(
                WorkspaceBox.Text.Trim(),
                args,
                TimeSpan.FromSeconds(8),
                verifyCts.Token);
            if (!result.Success)
            {
                return false;
            }

            var status = ParseStatus(result.OutputTrimmed);
            var includesDown = profile.Equals("both", StringComparison.OrdinalIgnoreCase) ||
                               profile.Equals("downlink", StringComparison.OrdinalIgnoreCase);
            var includesUp = profile.Equals("both", StringComparison.OrdinalIgnoreCase) ||
                             profile.Equals("uplink", StringComparison.OrdinalIgnoreCase);
            var expectRunning = !action.Equals("stop", StringComparison.OrdinalIgnoreCase);

            var ok = true;
            if (includesDown)
            {
                ok = ok && status.DownRunning == expectRunning;
            }
            if (includesUp)
            {
                ok = ok && status.UpRunning == expectRunning;
            }
            return ok;
        }
        catch
        {
            return false;
        }
    }

    private void ValidateBeforeAction(string action, string profile)
    {
        if (!action.Equals("start", StringComparison.OrdinalIgnoreCase) &&
            !action.Equals("restart", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        var includeDown = profile.Equals("both", StringComparison.OrdinalIgnoreCase) ||
                          profile.Equals("downlink", StringComparison.OrdinalIgnoreCase);
        if (!includeDown)
        {
            return;
        }

        var downMode = SelectedText(DownModeCombo, "network");
        var downIp = DownTargetIpBox.Text.Trim();
        if (downMode.Equals("network", StringComparison.OrdinalIgnoreCase) &&
            string.IsNullOrWhiteSpace(downIp))
        {
            throw new InvalidOperationException("Downlink en modo network requiere Target IP (IP del Android receptor).");
        }
    }

    private static string ExtractFriendlyError(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return "Error desconocido.";
        }

        var text = raw.Replace('\r', '\n');
        var lines = text.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(l => l.Trim())
            .Where(l => !string.IsNullOrWhiteSpace(l))
            .ToList();

        if (lines.Count == 0)
        {
            return "Error desconocido.";
        }

        foreach (var line in lines)
        {
            if (line.StartsWith("No se pudo completar", StringComparison.OrdinalIgnoreCase) ||
                line.StartsWith("Downlink en modo", StringComparison.OrdinalIgnoreCase) ||
                line.StartsWith("Uplink requiere", StringComparison.OrdinalIgnoreCase))
            {
                return line;
            }
        }

        return lines[0];
    }

    private List<string> BuildActionArgs(string action, string profile, bool? forceUpStartAndroidMic)
    {
        var args = new List<string>
        {
            "-Action", action,
            "-Profile", profile,
            "-Workspace", WorkspaceBox.Text.Trim(),
            "-DownMode", SelectedText(DownModeCombo, "network"),
            "-DownPort", SelectedText(DownPortCombo, "50000"),
            "-DownFrameMs", SelectedText(DownFrameCombo, "5"),
            "-DownJitterMs", SelectedText(DownJitterCombo, "20"),
            "-DownSource", SelectedText(DownSourceCombo, "desktop"),
            "-DownTransport", SelectedText(DownTransportCombo, "udp"),
            "-DownAutoReconnectUsb", SelectedText(DownAutoReconnectCombo, "true"),
            "-DownUsbWatchdogIntervalMs", ReadIntText(DownUsbWatchdogBox.Text, 1500).ToString(),
            "-UpPort", SelectedText(UpPortCombo, "50010"),
            "-UpFrameMs", SelectedText(UpFrameCombo, "5"),
            "-UpTransport", SelectedText(UpTransportCombo, "tcp"),
            "-UpMicSource", SelectedText(UpMicSourceCombo, "auto"),
            "-UpOutputDevice", UpOutputDeviceBox.Text.Trim(),
            "-UpTargetBufferMs", SelectedText(UpTargetBufferCombo, "50"),
            "-UpMaxBufferMs", SelectedText(UpMaxBufferCombo, "250")
        };

        var upStartAndroidMic = forceUpStartAndroidMic ?? (_currentMode == UiMode.Advanced && (UpStartAndroidMicCheck.IsChecked ?? true));
        args.Add("-UpStartAndroidMic");
        args.Add(upStartAndroidMic ? "1" : "0");

        var serial = DeviceSerialBox.Text.Trim();
        if (!string.IsNullOrWhiteSpace(serial))
        {
            args.Add("-DeviceSerial");
            args.Add(serial);
        }

        var downTargetIp = DownTargetIpBox.Text.Trim();
        if (!string.IsNullOrWhiteSpace(downTargetIp))
        {
            args.Add("-DownTargetIp");
            args.Add(downTargetIp);
        }

        var desktopDevice = GetSelectedDesktopDeviceValue();
        if (!string.IsNullOrWhiteSpace(desktopDevice))
        {
            args.Add("-DownDesktopDevice");
            args.Add(desktopDevice);
        }

        var upTargetIp = UpTargetIpBox.Text.Trim();
        if (!string.IsNullOrWhiteSpace(upTargetIp))
        {
            args.Add("-UpTargetIp");
            args.Add(upTargetIp);
        }

        if (DownSkipBuildCheck.IsChecked == true)
        {
            args.Add("-DownSkipBuild");
        }
        if (DownSkipReceiverCheck.IsChecked == true)
        {
            args.Add("-DownSkipReceiverStart");
        }
        if (UpSkipBuildBridgeCheck.IsChecked == true)
        {
            args.Add("-UpSkipBuildBridge");
        }
        if (UpNoRestartMicCheck.IsChecked == true)
        {
            args.Add("-UpNoRestartMic");
        }

        return args;
    }

    private static StatusSnapshot ParseStatus(string output)
    {
        var snapshot = StatusSnapshot.Empty;
        var lines = output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries);
        var downRx = new Regex(@"downlink:\s+running=(True|False)\s+pid=(\d+)\s+mode=(\S+)\s+transport=(\S+)\s+target=(\S+)", RegexOptions.IgnoreCase);
        var upRx = new Regex(@"uplink-bridge:\s+running=(True|False)\s+pid=(\d+)\s+transport=(\S+)\s+port=(\d+)", RegexOptions.IgnoreCase);

        foreach (var line in lines)
        {
            var text = line.Trim();
            if (text.StartsWith("downlink:", StringComparison.OrdinalIgnoreCase))
            {
                if (text.Contains("stopped", StringComparison.OrdinalIgnoreCase))
                {
                    snapshot = snapshot with { DownRunning = false, DownDetail = "sin sesion activa" };
                    continue;
                }

                var m = downRx.Match(text);
                if (m.Success)
                {
                    snapshot = snapshot with
                    {
                        DownRunning = m.Groups[1].Value.Equals("True", StringComparison.OrdinalIgnoreCase),
                        DownDetail = $"{m.Groups[3].Value} {m.Groups[4].Value} {m.Groups[5].Value} pid={m.Groups[2].Value}"
                    };
                }
            }
            else if (text.StartsWith("uplink-bridge:", StringComparison.OrdinalIgnoreCase))
            {
                if (text.Contains("stopped", StringComparison.OrdinalIgnoreCase))
                {
                    snapshot = snapshot with { UpRunning = false, UpDetail = "sin sesion activa" };
                    continue;
                }

                var m = upRx.Match(text);
                if (m.Success)
                {
                    snapshot = snapshot with
                    {
                        UpRunning = m.Groups[1].Value.Equals("True", StringComparison.OrdinalIgnoreCase),
                        UpDetail = $"{m.Groups[3].Value} port={m.Groups[4].Value} pid={m.Groups[2].Value}"
                    };
                }
            }
            else if (text.StartsWith("uplink-android-mic:", StringComparison.OrdinalIgnoreCase))
            {
                var idx = text.IndexOf(':');
                snapshot = snapshot with { UpMicDetail = idx >= 0 ? text[(idx + 1)..].Trim() : text };
            }
        }

        return snapshot;
    }

    private void UpdateStatusUi(StatusSnapshot status)
    {
        SetStatus(DownStatusText, status.DownRunning, status.DownDetail, DownStatusDetailText);
        SetStatus(UpBridgeStatusText, status.UpRunning, status.UpDetail, UpBridgeStatusDetailText);
        SetStatus(UpMicStatusText, null, status.UpMicDetail, UpMicStatusDetailText);
    }

    private void SetStatus(TextBlock label, bool? running, string detail, TextBlock detailLabel)
    {
        if (running is null)
        {
            label.Text = "unknown";
            label.Foreground = _unknownBrush;
        }
        else if (running.Value)
        {
            label.Text = "running";
            label.Foreground = _runningBrush;
        }
        else
        {
            label.Text = "stopped";
            label.Foreground = _stoppedBrush;
        }

        detailLabel.Text = detail;
    }

    private void ApplyMode(UiMode mode)
    {
        _currentMode = mode;
        CurrentModeBadge.Text = mode == UiMode.Basic ? " BASICO" : " AVANZADO";
        var advVisibility = mode == UiMode.Advanced ? Visibility.Visible : Visibility.Collapsed;
        DownAdvancedPanel.Visibility = advVisibility;
        UplinkAdvancedPanel.Visibility = advVisibility;
        NavDiagnosticsButton.Visibility = advVisibility;
        ActionOutputBox.Visibility = advVisibility;
        LogsOutputBox.Visibility = advVisibility;
        LogsProfileCombo.Visibility = advVisibility;
        LogsTailCombo.Visibility = advVisibility;
        UplinkBasicHintText.Visibility = mode == UiMode.Basic ? Visibility.Visible : Visibility.Collapsed;

        if (mode == UiMode.Basic && _currentPage == AppPage.Diagnostics)
        {
            ShowPage(AppPage.Dashboard);
        }
    }

    private void ShowPage(AppPage page)
    {
        _currentPage = page;
        DashboardView.Visibility = page == AppPage.Dashboard ? Visibility.Visible : Visibility.Collapsed;
        DownlinkView.Visibility = page == AppPage.Downlink ? Visibility.Visible : Visibility.Collapsed;
        UplinkView.Visibility = page == AppPage.Uplink ? Visibility.Visible : Visibility.Collapsed;
        DiagnosticsView.Visibility = page == AppPage.Diagnostics ? Visibility.Visible : Visibility.Collapsed;

        var inactive = (Brush)FindResource("Card");
        var active = new SolidColorBrush(Color.FromRgb(44, 61, 89));
        foreach (var btn in new[] { NavDashboardButton, NavDownlinkButton, NavUplinkButton, NavDiagnosticsButton })
        {
            btn.Background = inactive;
        }
        (page switch
        {
            AppPage.Dashboard => NavDashboardButton,
            AppPage.Downlink => NavDownlinkButton,
            AppPage.Uplink => NavUplinkButton,
            _ => NavDiagnosticsButton
        }).Background = active;
    }

    private async Task RunWithLoadingAsync(string text, Func<Task> operation)
    {
        SetLoading(true, text);
        try
        {
            await operation();
        }
        finally
        {
            SetLoading(false, string.Empty);
        }
    }

    private void SetLoading(bool show, string text)
    {
        LoadingText.Text = text;
        LoadingOverlay.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
    }

    private void AppendActionOutput(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return;
        }

        var line = $"[{DateTime.Now:HH:mm:ss}] {text.TrimEnd()}";
        ActionOutputBox.AppendText($"{line}{Environment.NewLine}");
        QuickActionOutputBox.AppendText($"{line}{Environment.NewLine}");
        ActionOutputBox.ScrollToEnd();
        QuickActionOutputBox.ScrollToEnd();
    }

    private static void FillCombo(ComboBox combo, IEnumerable<string> values, string selected)
    {
        combo.Items.Clear();
        foreach (var value in values)
        {
            combo.Items.Add(value);
        }
        combo.SelectedItem = selected;
    }

    private static string SelectedText(ComboBox combo, string fallback)
    {
        return combo.SelectedItem?.ToString() ?? combo.Text?.Trim() ?? fallback;
    }

    private static int ReadIntText(string text, int fallback)
    {
        return int.TryParse(text.Trim(), out var n) ? n : fallback;
    }

    private string GetSelectedDesktopDeviceValue()
    {
        if (DownDesktopDeviceCombo.SelectedItem is DeviceOption opt)
        {
            return opt.Name;
        }
        var text = DownDesktopDeviceCombo.Text.Trim();
        if (text.StartsWith("("))
        {
            return string.Empty;
        }
        return text.Replace(" (default)", string.Empty, StringComparison.OrdinalIgnoreCase).Trim();
    }

    private static string GetLocalIpv4Hint()
    {
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up)
            {
                continue;
            }

            var props = ni.GetIPProperties();
            foreach (var uni in props.UnicastAddresses)
            {
                if (uni.Address.AddressFamily == AddressFamily.InterNetwork && !uni.Address.ToString().StartsWith("127."))
                {
                    return uni.Address.ToString();
                }
            }
        }
        return string.Empty;
    }

    private static string ResolveWorkspacePath()
    {
        var fromArgs = App.WorkspaceFromArgs;
        if (!string.IsNullOrWhiteSpace(fromArgs))
        {
            var argPath = Path.GetFullPath(fromArgs);
            if (File.Exists(Path.Combine(argPath, "tools", "launcher", "audio-link.ps1")))
            {
                return argPath;
            }
        }

        foreach (var seed in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
        {
            var current = new DirectoryInfo(seed);
            while (current is not null)
            {
                if (File.Exists(Path.Combine(current.FullName, "tools", "launcher", "audio-link.ps1")))
                {
                    return current.FullName;
                }
                current = current.Parent;
            }
        }

        return Directory.GetCurrentDirectory();
    }

    private async Task ToggleMuteInputAsync(bool mute)
    {
        if (_muteEventsSuppressed)
        {
            return;
        }

        if (mute)
        {
            _downWasRunningBeforeMute = _lastStatus.DownRunning;
            if (_downWasRunningBeforeMute)
            {
                await ExecuteActionAsync("stop", "downlink");
            }
            AppendActionOutput("Mute entrada activado.");
        }
        else
        {
            if (_downWasRunningBeforeMute)
            {
                await ExecuteActionAsync("start", "downlink");
            }
            _downWasRunningBeforeMute = false;
            AppendActionOutput("Mute entrada desactivado.");
        }
    }

    private async Task ToggleMuteOutputAsync(bool mute)
    {
        if (_muteEventsSuppressed)
        {
            return;
        }

        if (mute)
        {
            _upWasRunningBeforeMute = _lastStatus.UpRunning;
            if (_upWasRunningBeforeMute)
            {
                await ExecuteActionAsync("stop", "uplink", forceUpStartAndroidMic: false);
            }
            AppendActionOutput("Mute salida activado.");
        }
        else
        {
            if (_upWasRunningBeforeMute)
            {
                await ExecuteActionAsync("start", "uplink", forceUpStartAndroidMic: false);
            }
            _upWasRunningBeforeMute = false;
            AppendActionOutput("Mute salida desactivado.");
        }
    }

    private async void StartAllButton_Click(object sender, RoutedEventArgs e) => await ExecuteActionAsync("start", SelectedText(GlobalProfileCombo, "both"));
    private async void StopAllButton_Click(object sender, RoutedEventArgs e) => await ExecuteActionAsync("stop", SelectedText(GlobalProfileCombo, "both"));
    private async void StartDownlinkButton_Click(object sender, RoutedEventArgs e) => await ExecuteActionAsync("start", "downlink");
    private async void StopDownlinkButton_Click(object sender, RoutedEventArgs e) => await ExecuteActionAsync("stop", "downlink");
    private async void StartUplinkButton_Click(object sender, RoutedEventArgs e) => await ExecuteActionAsync("start", "uplink");
    private async void StopUplinkButton_Click(object sender, RoutedEventArgs e) => await ExecuteActionAsync("stop", "uplink");
    private async void RefreshStatusButton_Click(object sender, RoutedEventArgs e) => await RefreshStatusAsync(logOutput: true);
    private async void ReloadDesktopDevicesButton_Click(object sender, RoutedEventArgs e) => await ReloadDesktopDevicesAsync(logOutput: true);
    private async void ReloadLogsButton_Click(object sender, RoutedEventArgs e) => await ReloadLogsAsync(logOutput: true);

    private void NavDashboardButton_Click(object sender, RoutedEventArgs e) => ShowPage(AppPage.Dashboard);
    private void NavDownlinkButton_Click(object sender, RoutedEventArgs e) => ShowPage(AppPage.Downlink);
    private void NavUplinkButton_Click(object sender, RoutedEventArgs e) => ShowPage(AppPage.Uplink);
    private void NavDiagnosticsButton_Click(object sender, RoutedEventArgs e)
    {
        if (_currentMode == UiMode.Advanced)
        {
            ShowPage(AppPage.Diagnostics);
        }
    }

    private void UiModeCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var mode = SelectedText(UiModeCombo, "Basico").Equals("Avanzado", StringComparison.OrdinalIgnoreCase)
            ? UiMode.Advanced
            : UiMode.Basic;
        ApplyMode(mode);
    }

    private void DownSourceCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var enabled = SelectedText(DownSourceCombo, "desktop").Equals("desktop", StringComparison.OrdinalIgnoreCase);
        DownDesktopDeviceCombo.IsEnabled = enabled;
        ReloadDesktopDevicesButton.IsEnabled = enabled;
    }

    private async void MuteInputToggle_Checked(object sender, RoutedEventArgs e) => await ToggleMuteInputAsync(true);
    private async void MuteInputToggle_Unchecked(object sender, RoutedEventArgs e) => await ToggleMuteInputAsync(false);
    private async void MuteOutputToggle_Checked(object sender, RoutedEventArgs e) => await ToggleMuteOutputAsync(true);
    private async void MuteOutputToggle_Unchecked(object sender, RoutedEventArgs e) => await ToggleMuteOutputAsync(false);

    private void OpenRuntimeFolderButton_Click(object sender, RoutedEventArgs e)
    {
        var runtime = Path.Combine(WorkspaceBox.Text.Trim(), "tools", "launcher", ".runtime");
        Directory.CreateDirectory(runtime);
        Process.Start(new ProcessStartInfo("explorer.exe", runtime) { UseShellExecute = true });
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2)
        {
            WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
            return;
        }
        DragMove();
    }

    private void MinimizeButton_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

    private enum UiMode { Basic, Advanced }
    private enum AppPage { Dashboard, Downlink, Uplink, Diagnostics }

    private sealed record DeviceOption(string Name, string Display)
    {
        public override string ToString() => Display;
    }

    private sealed record StatusSnapshot(bool DownRunning, string DownDetail, bool UpRunning, string UpDetail, string UpMicDetail)
    {
        public static readonly StatusSnapshot Empty = new(false, "sin sesion activa", false, "sin sesion activa", "revisa logcat tag MicSenderService");
    }
}
