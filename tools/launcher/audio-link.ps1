param(
    [ValidateSet("start", "stop", "restart", "status", "logs")]
    [string]$Action = "status",

    [ValidateSet("both", "downlink", "uplink")]
    [string]$Profile = "both",

    [string]$Workspace = "",
    [string]$DeviceSerial = "",

    # Downlink: Windows (desktop/mic) -> Android receiver
    [ValidateSet("network", "usb")]
    [string]$DownMode = "network",
    [string]$DownTargetIp = "",
    [int]$DownPort = 50000,
    [int]$DownFrameMs = 5,
    [int]$DownJitterMs = 20,
    [ValidateSet("desktop", "mic")]
    [string]$DownSource = "desktop",
    [string]$DownDesktopDevice = "",
    [ValidateSet("udp", "tcp")]
    [string]$DownTransport = "udp",
    [switch]$DownSkipBuild,
    [switch]$DownSkipReceiverStart,
    [object]$DownAutoReconnectUsb = $true,
    [int]$DownUsbWatchdogIntervalMs = 1500,

    # Uplink: Android mic -> Windows bridge
    [string]$UpTargetIp = "",
    [int]$UpPort = 50010,
    [int]$UpFrameMs = 5,
    [ValidateSet("udp", "tcp")]
    [string]$UpTransport = "tcp",
    [ValidateSet("auto", "phone", "bluetooth")]
    [string]$UpMicSource = "auto",
    [string]$UpOutputDevice = "CABLE Input (VB-Audio Virtual Cable)",
    [int]$UpTargetBufferMs = 50,
    [int]$UpMaxBufferMs = 250,
    [switch]$UpSkipBuildBridge,
    [switch]$UpNoRestartMic,

    # Logs/status helpers
    [int]$Tail = 40,
    [switch]$Follow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-Workspace {
    param([string]$ProvidedWorkspace)
    if ($ProvidedWorkspace -and $ProvidedWorkspace.Trim().Length -gt 0) {
        return (Resolve-Path $ProvidedWorkspace).Path
    }
    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Include-Profile {
    param(
        [string]$CurrentProfile,
        [string]$Needle
    )
    return $CurrentProfile -eq "both" -or $CurrentProfile -eq $Needle
}

function Read-JsonOrNull {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return $null
    }
    try {
        return (Get-Content $Path -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-ProcessAlive {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    try {
        $null = Get-Process -Id $ProcessId -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-PrimaryIPv4 {
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.IPAddress -ne "127.0.0.1" -and
                $_.PrefixOrigin -ne "WellKnown"
            } |
            Sort-Object -Property InterfaceMetric, SkipAsSource
        if ($ips -and $ips.Count -gt 0) {
            return $ips[0].IPAddress
        }
    } catch {
    }
    return ""
}

function Convert-ToBooleanValue {
    param(
        [object]$Value,
        [bool]$Default,
        [string]$ParamName = "bool"
    )
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }
    if (
        $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64]
    ) {
        return ([int64]$Value -ne 0)
    }

    $text = "$Value".Trim().ToLowerInvariant()
    switch ($text) {
        "true" { return $true }
        "false" { return $false }
        "1" { return $true }
        "0" { return $false }
        "yes" { return $true }
        "no" { return $false }
        "on" { return $true }
        "off" { return $false }
        default {
            Write-Warning "Parametro $ParamName invalido ('$Value'). Usando valor por defecto: $Default"
            return $Default
        }
    }
}

function Show-Log {
    param(
        [string]$Title,
        [string]$Path,
        [int]$TailLines,
        [bool]$FollowMode
    )
    Write-Host ""
    Write-Host "[$Title] $Path"
    if (-not (Test-Path $Path)) {
        Write-Host "(sin archivo de log)"
        return
    }
    if ($FollowMode) {
        Get-Content $Path -Tail $TailLines -Wait
    } else {
        Get-Content $Path -Tail $TailLines
    }
}

function Start-Downlink {
    param(
        [string]$ScriptPath,
        [string]$WorkspacePath,
        [string]$Device
    )
    if ($DownMode -eq "network" -and -not $DownTargetIp) {
        throw "Downlink en modo network requiere -DownTargetIp."
    }

    $args = @{
        Mode = $DownMode
        Port = $DownPort
        FrameMs = $DownFrameMs
        JitterMs = $DownJitterMs
        Source = $DownSource
        Transport = $DownTransport
        Workspace = $WorkspacePath
        AutoReconnectUsb = $script:DownAutoReconnectUsbValue
        UsbWatchdogIntervalMs = $DownUsbWatchdogIntervalMs
    }
    if ($DownMode -eq "network") { $args.TargetIp = $DownTargetIp }
    if ($DownDesktopDevice) { $args.DesktopDevice = $DownDesktopDevice }
    if ($Device) { $args.DeviceSerial = $Device }
    if ($DownSkipBuild) { $args.SkipBuild = $true }
    if ($DownSkipReceiverStart) { $args.SkipReceiverStart = $true }

    & $ScriptPath @args
}

function Stop-Downlink {
    param(
        [string]$ScriptPath,
        [string]$WorkspacePath
    )
    & $ScriptPath -Workspace $WorkspacePath
}

function Start-Uplink {
    param(
        [string]$StartBridgeScript,
        [string]$StartMicScript,
        [string]$WorkspacePath,
        [string]$Device
    )
    $targetIp = $UpTargetIp
    if (-not $targetIp) {
        $targetIp = Get-PrimaryIPv4
        if ($targetIp) {
            Write-Host "UpTargetIp no especificado, usando IPv4 local detectada: $targetIp"
        } else {
            throw "Uplink requiere -UpTargetIp (no se pudo detectar IP local automaticamente)."
        }
    }

    $bridgeArgs = @{
        Port = $UpPort
        Transport = $UpTransport
        OutputDevice = $UpOutputDevice
        TargetBufferMs = $UpTargetBufferMs
        MaxBufferMs = $UpMaxBufferMs
        Workspace = $WorkspacePath
    }
    if ($UpSkipBuildBridge) { $bridgeArgs.SkipBuild = $true }
    & $StartBridgeScript @bridgeArgs

    $micArgs = @{
        TargetIp = $targetIp
        Port = $UpPort
        FrameMs = $UpFrameMs
        Transport = $UpTransport
        MicSource = $UpMicSource
    }
    if ($Device) { $micArgs.DeviceSerial = $Device }
    if ($UpNoRestartMic) { $micArgs.NoRestart = $true }
    & $StartMicScript @micArgs
}

function Stop-Uplink {
    param(
        [string]$StopBridgeScript,
        [string]$StopMicScript,
        [string]$WorkspacePath,
        [string]$Device
    )
    $micArgs = @{}
    if ($Device) { $micArgs.DeviceSerial = $Device }
    & $StopMicScript @micArgs
    & $StopBridgeScript -Workspace $WorkspacePath
}

$workspacePath = Resolve-Workspace -ProvidedWorkspace $Workspace
$DownAutoReconnectUsbValue = Convert-ToBooleanValue -Value $DownAutoReconnectUsb -Default $true -ParamName "DownAutoReconnectUsb"
$launcherDir = Join-Path $workspacePath "tools\launcher"

$startDownlinkScript = Join-Path $launcherDir "start-audio-link.ps1"
$stopDownlinkScript = Join-Path $launcherDir "stop-audio-link.ps1"
$startBridgeScript = Join-Path $launcherDir "start-windows-mic-bridge.ps1"
$stopBridgeScript = Join-Path $launcherDir "stop-windows-mic-bridge.ps1"
$startMicScript = Join-Path $launcherDir "start-android-mic.ps1"
$stopMicScript = Join-Path $launcherDir "stop-android-mic.ps1"

$runtimeDir = Join-Path $workspacePath "tools\launcher\.runtime"
$downStatePath = Join-Path $runtimeDir "session.json"
$bridgeStatePath = Join-Path $runtimeDir "mic-bridge.session.json"
$downLogPath = Join-Path $runtimeDir "sender.log"
$downErrPath = Join-Path $runtimeDir "sender.err.log"
$bridgeLogPath = Join-Path $runtimeDir "mic-bridge.log"
$bridgeErrPath = Join-Path $runtimeDir "mic-bridge.err.log"

if (-not (Test-Path $runtimeDir)) {
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
}

if ($Action -eq "restart") {
    if (Include-Profile -CurrentProfile $Profile -Needle "uplink") {
        Stop-Uplink -StopBridgeScript $stopBridgeScript -StopMicScript $stopMicScript -WorkspacePath $workspacePath -Device $DeviceSerial
    }
    if (Include-Profile -CurrentProfile $Profile -Needle "downlink") {
        Stop-Downlink -ScriptPath $stopDownlinkScript -WorkspacePath $workspacePath
    }
    Start-Sleep -Milliseconds 300
    if (Include-Profile -CurrentProfile $Profile -Needle "downlink") {
        Start-Downlink -ScriptPath $startDownlinkScript -WorkspacePath $workspacePath -Device $DeviceSerial
    }
    if (Include-Profile -CurrentProfile $Profile -Needle "uplink") {
        Start-Uplink -StartBridgeScript $startBridgeScript -StartMicScript $startMicScript -WorkspacePath $workspacePath -Device $DeviceSerial
    }
    return
}

switch ($Action) {
    "start" {
        if (Include-Profile -CurrentProfile $Profile -Needle "downlink") {
            Start-Downlink -ScriptPath $startDownlinkScript -WorkspacePath $workspacePath -Device $DeviceSerial
        }
        if (Include-Profile -CurrentProfile $Profile -Needle "uplink") {
            Start-Uplink -StartBridgeScript $startBridgeScript -StartMicScript $startMicScript -WorkspacePath $workspacePath -Device $DeviceSerial
        }
    }
    "stop" {
        if (Include-Profile -CurrentProfile $Profile -Needle "uplink") {
            Stop-Uplink -StopBridgeScript $stopBridgeScript -StopMicScript $stopMicScript -WorkspacePath $workspacePath -Device $DeviceSerial
        }
        if (Include-Profile -CurrentProfile $Profile -Needle "downlink") {
            Stop-Downlink -ScriptPath $stopDownlinkScript -WorkspacePath $workspacePath
        }
    }
    "status" {
        if (Include-Profile -CurrentProfile $Profile -Needle "downlink") {
            $downState = Read-JsonOrNull -Path $downStatePath
            if ($downState) {
                $senderPid = [int]$downState.SenderPid
                $alive = Test-ProcessAlive -ProcessId $senderPid
                Write-Host "downlink: running=$alive pid=$senderPid mode=$($downState.Mode) transport=$($downState.Transport) target=$($downState.TargetIp):$($downState.Port)"
            } else {
                Write-Host "downlink: stopped"
            }
        }

        if (Include-Profile -CurrentProfile $Profile -Needle "uplink") {
            $bridgeState = Read-JsonOrNull -Path $bridgeStatePath
            if ($bridgeState) {
                $bridgePid = [int]$bridgeState.Pid
                $alive = Test-ProcessAlive -ProcessId $bridgePid
                Write-Host "uplink-bridge: running=$alive pid=$bridgePid transport=$($bridgeState.Transport) port=$($bridgeState.Port)"
            } else {
                Write-Host "uplink-bridge: stopped"
            }
            Write-Host "uplink-android-mic: revisar en logcat tag MicSenderService"
        }
    }
    "logs" {
        if ($Tail -lt 1) { $Tail = 1 }
        if ($Follow -and $Profile -eq "both") {
            throw "-Follow con -Profile both no es soportado. Usa downlink o uplink."
        }

        if (Include-Profile -CurrentProfile $Profile -Needle "downlink") {
            Show-Log -Title "downlink stdout" -Path $downLogPath -TailLines $Tail -FollowMode ([bool]$Follow)
            if (-not $Follow) {
                Show-Log -Title "downlink stderr" -Path $downErrPath -TailLines $Tail -FollowMode $false
            }
        }
        if (Include-Profile -CurrentProfile $Profile -Needle "uplink") {
            Show-Log -Title "uplink bridge stdout" -Path $bridgeLogPath -TailLines $Tail -FollowMode ([bool]$Follow)
            if (-not $Follow) {
                Show-Log -Title "uplink bridge stderr" -Path $bridgeErrPath -TailLines $Tail -FollowMode $false
            }
        }
    }
}
