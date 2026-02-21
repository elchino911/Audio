param(
    [string]$DeviceSerial = ""
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
$statePath = Join-Path $workspacePath "tools\launcher\.runtime\mic-sender.session.json"

$args = @(
    "-s", $device, "shell", "am", "startservice",
    "-n", "com.audiolink.receiver/.MicSenderService",
    "-a", "com.audiolink.receiver.action.MIC_STOP"
)

Write-Host "Deteniendo MicSenderService en $device"
& $adbExe @args
Remove-Item $statePath -Force -ErrorAction SilentlyContinue
