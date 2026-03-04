param(
    [ValidateSet("network", "usb")]
    [string]$Mode = "network",

    [string]$TargetIp = "",
    [int]$Port = 50000,
    [int]$FrameMs = 5,
    [int]$JitterMs = 20,
    [ValidateSet("desktop", "mic")]
    [string]$Source = "desktop",
    [string]$DesktopDevice = "",
    [ValidateSet("udp", "tcp")]
    [string]$Transport = "udp",
    [string]$DeviceSerial = "",
    [string]$Workspace = "",
    [switch]$SkipBuild,
    [switch]$SkipReceiverStart,
    [bool]$AutoReconnectUsb = $true,
    [int]$UsbWatchdogIntervalMs = 1500
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

function Is-ProcessRunning {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    try {
        $null = Get-Process -Id $ProcessId -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Stop-ManagedProcess {
    param(
        [int]$ProcessId,
        [string]$Label
    )
    if ($ProcessId -le 0) { return }
    if (-not (Is-ProcessRunning -ProcessId $ProcessId)) { return }

    $stopErr = $null
    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    } catch {
        $stopErr = $_.Exception.Message
        try {
            & taskkill /PID $ProcessId /F /T 2>$null | Out-Null
        } catch {
        }
    }

    Start-Sleep -Milliseconds 120
    if (Is-ProcessRunning -ProcessId $ProcessId) {
        if (-not $stopErr) {
            $stopErr = "proceso sigue en ejecucion tras intento de cierre"
        }
        throw "No se pudo detener $Label (PID $ProcessId): $stopErr"
    }
}

function Stop-ExistingSession {
    param([string]$StatePath)
    if (-not (Test-Path $StatePath)) {
        return
    }

    try {
        $state = Get-Content $StatePath -Raw | ConvertFrom-Json
        if ($state.SenderPid) {
            Stop-ManagedProcess -ProcessId ([int]$state.SenderPid) -Label "Sender previo"
        }
        if ($state.WatchdogPid) {
            Stop-ManagedProcess -ProcessId ([int]$state.WatchdogPid) -Label "Watchdog previo"
        }
        Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
    } catch {
        throw "No se pudo cerrar sesion previa desde estado: $($_.Exception.Message)"
    }
}

function Stop-OrphanSenders {
    $procs = Get-Process -Name "windows-sender" -ErrorAction SilentlyContinue
    if (-not $procs) { return 0 }
    $stopped = 0
    foreach ($proc in $procs) {
        Stop-ManagedProcess -ProcessId ([int]$proc.Id) -Label "Sender huerfano"
        $stopped++
    }
    return $stopped
}

function Save-State {
    param(
        [hashtable]$State,
        [string]$StatePath
    )
    $State | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
}

function Reset-LogFileBestEffort {
    param(
        [string]$Path,
        [int]$Retries = 15,
        [int]$DelayMs = 120
    )
    if (-not (Test-Path $Path)) {
        return
    }
    for ($i = 0; $i -le $Retries; $i++) {
        try {
            Remove-Item -Path $Path -Force -ErrorAction Stop
            return
        } catch {
            if ($i -ge $Retries) {
                Write-Warning "No se pudo limpiar log bloqueado: $Path. Continuando."
                return
            }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

function Invoke-AdbSafe {
    param(
        [string]$AdbExe,
        [string[]]$CommandArgs
    )
    $tmpDir = [System.IO.Path]::GetTempPath()
    $stdoutPath = Join-Path $tmpDir ("adb-out-{0}.log" -f ([System.Guid]::NewGuid().ToString("N")))
    $stderrPath = Join-Path $tmpDir ("adb-err-{0}.log" -f ([System.Guid]::NewGuid().ToString("N")))
    try {
        $proc = Start-Process `
            -FilePath $AdbExe `
            -ArgumentList $CommandArgs `
            -PassThru `
            -Wait `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath

        $stdout = if (Test-Path $stdoutPath) { Get-Content $stdoutPath -ErrorAction SilentlyContinue } else { @() }
        $stderr = if (Test-Path $stderrPath) { Get-Content $stderrPath -ErrorAction SilentlyContinue } else { @() }
        return @{
            Output = @($stdout + $stderr)
            ExitCode = $proc.ExitCode
        }
    } finally {
        if (Test-Path $stdoutPath) { Remove-Item $stdoutPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $stderrPath) { Remove-Item $stderrPath -Force -ErrorAction SilentlyContinue }
    }
}

function Is-TransientAdbUsbError {
    param([string]$Text)
    if (-not $Text) { return $false }
    return (
        $Text -match "device offline" -or
        $Text -match "device unauthorized" -or
        $Text -match "no devices/emulators found" -or
        $Text -match "device '\S+' not found"
    )
}

$workspacePath = Resolve-Workspace -ProvidedWorkspace $Workspace
$senderDir = Join-Path $workspacePath "windows-sender"
$senderProject = Join-Path $senderDir "Cargo.toml"
$senderExe = Join-Path $senderDir "target\release\windows-sender.exe"
$runtimeDir = Join-Path $workspacePath "tools\launcher\.runtime"
$statePath = Join-Path $runtimeDir "session.json"
$senderLog = Join-Path $runtimeDir "sender.log"
$senderErrLog = Join-Path $runtimeDir "sender.err.log"
$adbExe = $null
$device = $null
$effectiveTransport = $Transport
$effectiveTargetIp = $TargetIp
$shouldStartReceiver = -not [bool]$SkipReceiverStart

if (-not (Test-Path $senderDir)) {
    throw "No existe directorio sender: $senderDir"
}

New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
Stop-ExistingSession -StatePath $statePath
$orphanStopped = Stop-OrphanSenders
if ($orphanStopped -gt 0) {
    Write-Host "Se detuvieron $orphanStopped proceso(s) sender huerfanos antes de iniciar."
}

Reset-LogFileBestEffort -Path $senderLog
Reset-LogFileBestEffort -Path $senderErrLog

if ($Mode -eq "usb") {
    $effectiveTransport = "tcp"
    $effectiveTargetIp = "127.0.0.1"
}

if ($Mode -eq "network" -and -not $effectiveTargetIp) {
    throw "En modo network debes pasar -TargetIp <ip_del_android>."
}

if ($Mode -eq "usb") {
    $adbExe = Resolve-Exe -CommandName "adb" -FallbackPaths @(
        "$env:USERPROFILE\AppData\Local\Android\Sdk\platform-tools\adb.exe"
    )
    $device = Resolve-AndroidSerial -AdbExe $adbExe -PreferredSerial $DeviceSerial
} elseif ($shouldStartReceiver) {
    try {
        $adbExe = Resolve-Exe -CommandName "adb" -FallbackPaths @(
            "$env:USERPROFILE\AppData\Local\Android\Sdk\platform-tools\adb.exe"
        )
        $device = Resolve-AndroidSerial -AdbExe $adbExe -PreferredSerial $DeviceSerial
    } catch {
        Write-Warning "No se pudo usar ADB para iniciar receiver automaticamente: $($_.Exception.Message)"
        Write-Warning "Continuando en modo network sin arranque ADB. Inicia la app Android manualmente y pulsa Start."
        $shouldStartReceiver = $false
        $adbExe = $null
        $device = $null
    }
}

if ((-not $SkipBuild -or -not (Test-Path $senderExe)) -and (Test-Path $senderProject)) {
    $cargoExe = Resolve-Exe -CommandName "cargo" -FallbackPaths @(
        "$env:USERPROFILE\.cargo\bin\cargo.exe"
    )
    Write-Host "Compilando sender (--release)..."
    Push-Location $senderDir
    try {
        & $cargoExe build --release
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path $senderExe)) {
    throw "No se encontro binario sender: $senderExe"
}

if ((-not (Test-Path $senderProject)) -and (-not $SkipBuild)) {
    Write-Host "Usando sender precompilado del paquete: $senderExe"
}

if ($Mode -eq "usb") {
    Write-Host "Configurando adb forward tcp:$Port -> tcp:$Port en dispositivo $device"
    $usbForwardReady = $true

    $removeResult = Invoke-AdbSafe -AdbExe $adbExe -CommandArgs @(
        "-s", $device, "forward", "--remove", "tcp:$Port"
    )
    if ($removeResult.ExitCode -ne 0) {
        $removeText = ($removeResult.Output | Out-String).Trim()
        if ($removeText -notmatch "listener 'tcp:$Port' not found") {
            if (Is-TransientAdbUsbError -Text $removeText) {
                $usbForwardReady = $false
                Write-Warning "ADB/USB no disponible todavia: $removeText"
                Write-Warning "Se iniciara igual; el watchdog restaurara forward al reconectar."
            } else {
                throw "adb forward --remove fallo: $removeText"
            }
        }
    }

    if ($usbForwardReady) {
        $forwardResult = Invoke-AdbSafe -AdbExe $adbExe -CommandArgs @(
            "-s", $device, "forward", "tcp:$Port", "tcp:$Port"
        )
        if ($forwardResult.ExitCode -ne 0) {
            $forwardText = ($forwardResult.Output | Out-String).Trim()
            if (Is-TransientAdbUsbError -Text $forwardText) {
                $usbForwardReady = $false
                Write-Warning "No se pudo crear adb forward por estado USB/ADB: $forwardText"
                Write-Warning "Se iniciara igual; el watchdog restaurara forward al reconectar."
            } else {
                throw "adb forward fallo: $forwardText"
            }
        }
    }

    if ($usbForwardReady) {
        Write-Host "adb forward listo."
    }
}

if ($shouldStartReceiver -and $adbExe -and $device) {
    Write-Host "Iniciando receiver Android..."
    $stopArgs = @(
        "-s", $device, "shell", "am", "startservice",
        "-n", "com.audiolink.receiver/.UdpAudioService",
        "-a", "com.audiolink.receiver.action.STOP"
    )
    $null = Invoke-AdbSafe -AdbExe $adbExe -CommandArgs $stopArgs
    Start-Sleep -Milliseconds 300

    $launchMainArgs = @(
        "-s", $device, "shell", "am", "start",
        "-n", "com.audiolink.receiver/.MainActivity"
    )
    $null = Invoke-AdbSafe -AdbExe $adbExe -CommandArgs $launchMainArgs

    $startArgs = @(
        "-s", $device, "shell", "am", "start-foreground-service",
        "-n", "com.audiolink.receiver/.UdpAudioService",
        "-a", "com.audiolink.receiver.action.START",
        "--ei", "extra_port", "$Port",
        "--ei", "extra_jitter_ms", "$JitterMs",
        "--es", "extra_transport", "$effectiveTransport"
    )
    $startResult = Invoke-AdbSafe -AdbExe $adbExe -CommandArgs $startArgs
    if ($startResult.ExitCode -ne 0) {
        $startText = ($startResult.Output | Out-String).Trim()
        if ($startText -match "not exported") {
            Write-Warning "No se pudo arrancar el servicio por ADB (servicio no exportado en la APK instalada)."
            Write-Warning "Reinstala la app Android con la version nueva y mientras tanto inicia manualmente la app y pulsa Start."
        } else {
            Write-Warning "No se pudo arrancar receiver por ADB: $startText"
            Write-Warning "Inicia manualmente la app y pulsa Start."
        }
    } else {
        Start-Sleep -Milliseconds 600
    }
}

$senderArgs = @(
    "--target-ip", $effectiveTargetIp,
    "--port", "$Port",
    "--frame-ms", "$FrameMs",
    "--transport", "$effectiveTransport",
    "--source", "$Source"
)
if ($DesktopDevice -and $Source -eq "desktop") {
    $senderArgs += @("--desktop-device", "$DesktopDevice")
}

$senderProc = Start-Process -FilePath $senderExe `
    -ArgumentList $senderArgs `
    -WorkingDirectory $senderDir `
    -PassThru `
    -WindowStyle Hidden `
    -RedirectStandardOutput $senderLog `
    -RedirectStandardError $senderErrLog

$state = [ordered]@{
    StartedAt = (Get-Date).ToString("s")
    Mode = $Mode
    Port = $Port
    JitterMs = $JitterMs
    FrameMs = $FrameMs
    Source = $Source
    Transport = $effectiveTransport
    TargetIp = $effectiveTargetIp
    DeviceSerial = if ($device) { $device } else { "" }
    DesktopDevice = $DesktopDevice
    SenderDir = $senderDir
    SenderExe = $senderExe
    SenderLog = $senderLog
    SenderErrLog = $senderErrLog
    SkipReceiverStart = (-not [bool]$shouldStartReceiver)
    AutoReconnectUsb = $AutoReconnectUsb
    UsbWatchdogIntervalMs = $UsbWatchdogIntervalMs
    SenderPid = $senderProc.Id
    WatchdogPid = 0
}
Save-State -State $state -StatePath $statePath

if ($Mode -eq "usb" -and $AutoReconnectUsb) {
    $watchdogScript = Join-Path $workspacePath "tools\launcher\usb-watchdog.ps1"
    if (Test-Path $watchdogScript) {
        $watchdogLog = Join-Path $runtimeDir "watchdog.log"
        $watchdogErrLog = Join-Path $runtimeDir "watchdog.err.log"
        if (Test-Path $watchdogLog) { Remove-Item $watchdogLog -Force -ErrorAction SilentlyContinue }
        if (Test-Path $watchdogErrLog) { Remove-Item $watchdogErrLog -Force -ErrorAction SilentlyContinue }

        $watchdogArgs = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $watchdogScript,
            "-Workspace", $workspacePath,
            "-StatePath", $statePath,
            "-IntervalMs", "$UsbWatchdogIntervalMs"
        )
        $watchdogProc = Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList $watchdogArgs `
            -PassThru `
            -WindowStyle Hidden `
            -RedirectStandardOutput $watchdogLog `
            -RedirectStandardError $watchdogErrLog

        $state.WatchdogPid = $watchdogProc.Id
        Save-State -State $state -StatePath $statePath
        Write-Host "Watchdog USB activo (PID $($watchdogProc.Id), intervalo ${UsbWatchdogIntervalMs}ms)."
        Write-Host "Watchdog logs: $watchdogLog | $watchdogErrLog"
    } else {
        Write-Warning "No se encontro usb-watchdog.ps1; auto-reconexion deshabilitada."
    }
}

Write-Host "Sender iniciado. PID: $($senderProc.Id)"
Write-Host "Modo: $Mode | Transport: $effectiveTransport | Target: ${effectiveTargetIp}:$Port"
Write-Host "Log stdout: $senderLog"
Write-Host "Log stderr: $senderErrLog"
