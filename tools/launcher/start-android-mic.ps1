param(
    [Parameter(Mandatory = $true)]
    [string]$TargetIp,
    [int]$Port = 50010,
    [int]$FrameMs = 5,
    [ValidateSet("udp", "tcp")]
    [string]$Transport = "tcp",
    [ValidateSet("auto", "phone", "bluetooth")]
    [string]$MicSource = "auto",
    [string]$DeviceSerial = "",
    [switch]$NoRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-Exe {
    param(
        [string]$CommandName,
        [string[]]$FallbackPaths
    )

    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    foreach ($p in $FallbackPaths) {
        if (Test-Path $p) {
            return $p
        }
    }

    throw "No se encontro ejecutable para '$CommandName'."
}

function Resolve-AndroidSerial {
    param(
        [string]$AdbExe,
        [string]$PreferredSerial
    )

    if ($PreferredSerial -and $PreferredSerial.Trim().Length -gt 0) {
        return $PreferredSerial.Trim()
    }

    $out = & $AdbExe devices
    $serials = @()
    foreach ($line in $out) {
        if ($line -match "^(\S+)\s+device$") {
            $s = $Matches[1]
            if ($s -notmatch "^emulator-") {
                $serials += $s
            }
        }
    }

    if ($serials.Count -eq 1) {
        return $serials[0]
    }
    if ($serials.Count -eq 0) {
        throw "No hay dispositivo Android fisico conectado por ADB."
    }
    throw "Hay multiples dispositivos fisicos. Pasa -DeviceSerial <serial>."
}

function Resolve-Workspace {
    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$adbExe = Resolve-Exe -CommandName "adb" -FallbackPaths @(
    "$env:USERPROFILE\AppData\Local\Android\Sdk\platform-tools\adb.exe"
)
$device = Resolve-AndroidSerial -AdbExe $adbExe -PreferredSerial $DeviceSerial
$workspacePath = Resolve-Workspace
$runtimeDir = Join-Path $workspacePath "tools\launcher\.runtime"
$statePath = Join-Path $runtimeDir "mic-sender.session.json"
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null

$stopArgs = @(
    "-s", $device, "shell", "am", "startservice",
    "-n", "com.audiolink.receiver/.MicSenderService",
    "-a", "com.audiolink.receiver.action.MIC_STOP"
)

$args = @(
    "-s", $device, "shell", "am", "start-foreground-service",
    "-n", "com.audiolink.receiver/.MicSenderService",
    "-a", "com.audiolink.receiver.action.MIC_START",
    "--es", "extra_target_ip", "$TargetIp",
    "--ei", "extra_port", "$Port",
    "--ei", "extra_frame_ms", "$FrameMs",
    "--es", "extra_transport", "$Transport",
    "--es", "extra_input_mode", "$MicSource"
)

if (-not $NoRestart) {
    Write-Host "Reinicio limpio: deteniendo MicSenderService previo..."
    & $adbExe @stopArgs | Out-Null
    Start-Sleep -Milliseconds 600
}

Write-Host "Iniciando MicSenderService en $device -> ${TargetIp}:$Port ($Transport, frame=${FrameMs}ms, source=$MicSource)"
& $adbExe @args

$state = [ordered]@{
    StartedAt = (Get-Date).ToString("s")
    DeviceSerial = $device
    TargetIp = $TargetIp
    Port = $Port
    FrameMs = $FrameMs
    Transport = $Transport
    MicSource = $MicSource
}
$state | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8
