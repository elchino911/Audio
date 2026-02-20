param(
    [Parameter(Mandatory = $true)]
    [string]$TargetIp,

    [Parameter(Mandatory = $true)]
    [int]$JitterMs,

    [string]$DeviceSerial = "",
    [ValidateSet("desktop", "mic")]
    [string]$Source = "desktop",
    [string]$DesktopDevice = "",
    [int]$FrameMs = 5,
    [int]$Port = 50000,
    [ValidateSet("udp", "tcp")]
    [string]$Transport = "udp",
    [int]$DurationSec = 40,
    [string]$Label = "",
    [string]$Workspace = "C:\Users\RX\Proyectos\Audio",
    [string]$ReferenceAudioFile = "",
    [int]$ReferenceAudioWarmupMs = 1200,
    [int]$ReferenceAudioStartTimeoutMs = 8000,
    [switch]$DisableReferenceAudio,
    [switch]$SkipAnalyze,
    [switch]$AllowLoopbackTarget,
    [switch]$AutoStartReceiver
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

    $out = & $AdbExe devices 2>$null
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

function Quote-Arg {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    if ($Value -match '[\s"]') {
        $escaped = $Value -replace '"', '\"'
        return '"' + $escaped + '"'
    }
    return $Value
}

function Stop-StaleCaptureProcesses {
    # Cierra senders anteriores.
    Get-CimInstance Win32_Process -Filter "Name='windows-sender.exe'" -ErrorAction SilentlyContinue |
    ForEach-Object {
        try {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
            Write-Host "Cerrado sender previo PID $($_.ProcessId)"
        } catch {
            Write-Warning "No se pudo cerrar sender previo PID $($_.ProcessId): $($_.Exception.Message)"
        }
    }

    # Cierra adb logcat previos que suelen dejar lock en receiver_*.log.
    Get-CimInstance Win32_Process -Filter "Name='adb.exe'" -ErrorAction SilentlyContinue |
    ForEach-Object {
        $cmd = ""
        try { $cmd = [string]$_.CommandLine } catch {}
        if ($cmd -match '\blogcat\b') {
            try {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
                Write-Host "Cerrado adb/logcat previo PID $($_.ProcessId)"
            } catch {
                Write-Warning "No se pudo cerrar adb/logcat PID $($_.ProcessId): $($_.Exception.Message)"
            }
        }
    }
}

function Remove-IfExists {
    param(
        [string]$Path,
        [int]$RetryCount = 4,
        [int]$DelayMs = 250
    )

    if (-not (Test-Path $Path)) {
        return
    }

    for ($i = 0; $i -lt $RetryCount; $i++) {
        try {
            Remove-Item $Path -Force -ErrorAction Stop
            return
        } catch {
            if ($i -ge ($RetryCount - 1)) {
                throw "No se pudo limpiar '$Path' porque sigue en uso. Error: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

function Resolve-ReferenceAudioFile {
    param(
        [string]$WorkspacePath,
        [string]$ReferencePath
    )

    if ($ReferencePath -and $ReferencePath.Trim().Length -gt 0) {
        $candidate = $ReferencePath.Trim()
        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            $candidate = Join-Path $WorkspacePath $candidate
        }
        if (-not (Test-Path $candidate -PathType Leaf)) {
            throw "No existe archivo de audio de referencia: $candidate"
        }
        return (Resolve-Path $candidate).Path
    }

    $supportedExt = @(".wav", ".flac", ".mp3", ".m4a", ".aac", ".ogg", ".wma")
    $files = @(Get-ChildItem -Path $WorkspacePath -File | Where-Object {
        $supportedExt -contains $_.Extension.ToLowerInvariant()
    } | Sort-Object Name)

    if ($files.Count -eq 0) {
        throw "No se encontro audio de referencia en la raiz ($WorkspacePath). Coloca un archivo .wav/.mp3/.m4a o usa -ReferenceAudioFile."
    }
    if ($files.Count -gt 1) {
        $names = ($files | ForEach-Object { $_.Name }) -join ", "
        throw "Hay multiples audios en raiz ($names). Usa -ReferenceAudioFile para elegir uno."
    }
    return $files[0].FullName
}

function Start-ReferenceAudioPlayback {
    param([string]$FilePath)

    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    if ($ext -eq ".wav") {
        try {
            $player = New-Object System.Media.SoundPlayer
            $player.SoundLocation = $FilePath
            $player.Load()
            $player.PlayLooping()
            return @{
                Engine = "SoundPlayer"
                Player = $player
            }
        } catch {
            throw "No se pudo iniciar reproduccion WAV de referencia ($FilePath). Error: $($_.Exception.Message)"
        }
    }

    try {
        $player = New-Object -ComObject "WMPlayer.OCX"
        $player.settings.setMode("loop", $true) | Out-Null
        $player.URL = $FilePath
        $player.controls.play() | Out-Null
        return @{
            Engine = "WMP"
            Player = $player
        }
    } catch {
        throw "No se pudo iniciar reproduccion de referencia ($FilePath). Error: $($_.Exception.Message)"
    }
}

function Get-WmpPlayStateText {
    param([int]$State)

    switch ($State) {
        0 { return "undefined" }
        1 { return "stopped" }
        2 { return "paused" }
        3 { return "playing" }
        4 { return "scan-forward" }
        5 { return "scan-reverse" }
        6 { return "buffering" }
        7 { return "waiting" }
        8 { return "media-ended" }
        9 { return "transitioning" }
        10 { return "ready" }
        11 { return "reconnecting" }
        12 { return "last" }
        default { return "unknown" }
    }
}

function Wait-ReferenceAudioPlaybackReady {
    param(
        $Playback,
        [int]$TimeoutMs = 8000,
        [int]$PollMs = 150
    )

    $engine = "WMP"
    $player = $Playback
    if ($Playback -is [hashtable]) {
        $engine = [string]$Playback.Engine
        $player = $Playback.Player
    }

    if ($engine -eq "SoundPlayer") {
        return @{
            IsReady = $true
            State = 3
            StateText = "playing"
            WaitedMs = 0
            Engine = $engine
        }
    }

    $start = Get-Date
    $deadline = $start.AddMilliseconds([Math]::Max(1000, $TimeoutMs))
    $lastState = -1
    while ((Get-Date) -lt $deadline) {
        try {
            $lastState = [int]$player.playState
        } catch {
            $lastState = -1
        }

        if ($lastState -in @(3, 6, 7)) {
            return @{
                IsReady = $true
                State = $lastState
                StateText = Get-WmpPlayStateText -State $lastState
                WaitedMs = [int]((Get-Date) - $start).TotalMilliseconds
                Engine = $engine
            }
        }

        # Reintenta play si quedo parado o termino.
        if ($lastState -in @(1, 8, 10, -1)) {
            try { $player.controls.play() | Out-Null } catch {}
        }

        Start-Sleep -Milliseconds ([Math]::Max(50, $PollMs))
    }

    return @{
        IsReady = $false
        State = $lastState
        StateText = Get-WmpPlayStateText -State $lastState
        WaitedMs = [int]((Get-Date) - $start).TotalMilliseconds
        Engine = $engine
    }
}

function Stop-ReferenceAudioPlayback {
    param($Playback)
    if ($null -eq $Playback) { return }

    $engine = "WMP"
    $player = $Playback
    if ($Playback -is [hashtable]) {
        $engine = [string]$Playback.Engine
        $player = $Playback.Player
    }

    if ($engine -eq "SoundPlayer") {
        try { $player.Stop() } catch {}
        return
    }

    try { $player.controls.stop() | Out-Null } catch {}
    try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($player) } catch {}
}

if (-not $Label) {
    $Label = "${JitterMs}ms"
}

if (-not $AllowLoopbackTarget) {
    if ($TargetIp -eq "127.0.0.1" -or $TargetIp -eq "localhost") {
        throw "TargetIp=$TargetIp apunta a tu propio PC. Usa la IP real del telefono (ej: 192.168.x.x) o pasa -AllowLoopbackTarget."
    }
}

$reportsDir = Join-Path $Workspace "reports"
$senderDir = Join-Path $Workspace "windows-sender"
$reportScript = Join-Path $Workspace "tools\audio-report\audio_report.py"

if (-not (Test-Path $senderDir)) {
    throw "No existe directorio sender: $senderDir"
}
if (-not (Test-Path $reportScript)) {
    throw "No existe script de reporte: $reportScript"
}

$adbExe = Resolve-Exe -CommandName "adb" -FallbackPaths @(
    "$env:USERPROFILE\AppData\Local\Android\Sdk\platform-tools\adb.exe"
)
$cargoExe = Resolve-Exe -CommandName "cargo" -FallbackPaths @(
    "$env:USERPROFILE\.cargo\bin\cargo.exe"
)
$pythonExe = Resolve-Exe -CommandName "python" -FallbackPaths @()
$senderExe = Join-Path $senderDir "target\release\windows-sender.exe"
$referenceAudioPath = $null
$referenceAudioPlayer = $null

if ($Source -eq "desktop" -and -not $DisableReferenceAudio) {
    $referenceAudioPath = Resolve-ReferenceAudioFile -WorkspacePath $Workspace -ReferencePath $ReferenceAudioFile
} elseif ($Source -eq "mic" -and $ReferenceAudioFile) {
    Write-Warning "Se ignora -ReferenceAudioFile porque Source=mic."
}

$device = Resolve-AndroidSerial -AdbExe $adbExe -PreferredSerial $DeviceSerial

New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
$senderLog = Join-Path $reportsDir ("sender_{0}.log" -f $Label)
$senderErrLog = Join-Path $reportsDir ("sender_{0}.err.log" -f $Label)
$receiverLog = Join-Path $reportsDir ("receiver_{0}.log" -f $Label)
$receiverErrLog = Join-Path $reportsDir ("receiver_{0}.err.log" -f $Label)

Write-Host "Dispositivo Android: $device"
Write-Host "Target IP: $TargetIp"
Write-Host "Jitter (manual en app): $JitterMs ms"
Write-Host "Label: $Label"
Write-Host "Duracion: $DurationSec s"
Write-Host "Source: $Source"
Write-Host "Transport: $Transport"
if ($DesktopDevice) {
    Write-Host "Desktop device: $DesktopDevice"
}
if ($referenceAudioPath) {
    Write-Host "Audio referencia: $referenceAudioPath"
}
Write-Host "Sender log: $senderLog"
Write-Host "Receiver log: $receiverLog"

# Cierra procesos colgados de corridas anteriores antes de tocar logs.
Stop-StaleCaptureProcesses

foreach ($f in @($senderLog, $senderErrLog, $receiverLog, $receiverErrLog)) {
    Remove-IfExists -Path $f
}

Write-Host "Compilando sender (--release)..."
Push-Location $senderDir
try {
    & $cargoExe build --release
} finally {
    Pop-Location
}
if (-not (Test-Path $senderExe)) {
    throw "No se encontro binario sender: $senderExe"
}

& $adbExe -s $device logcat -c | Out-Null

$autoStart = $AutoStartReceiver.IsPresent
if ($autoStart) {
    Write-Host "Iniciando receiver Android..."
    $startArgs = @(
        "-s", $device, "shell", "am", "start-foreground-service",
        "-n", "com.audiolink.receiver/.UdpAudioService",
        "-a", "com.audiolink.receiver.action.START",
        "--ei", "extra_port", "$Port",
        "--ei", "extra_jitter_ms", "$JitterMs",
        "--es", "extra_transport", "$Transport"
    )
    & $adbExe @startArgs 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
}

$receiverArgs = @(
    "-s", $device, "logcat",
    "-v", "brief",
    "UdpAudioService:I",
    "*:S"
)
$receiverProc = Start-Process -FilePath $adbExe `
    -ArgumentList $receiverArgs `
    -PassThru `
    -WindowStyle Hidden `
    -RedirectStandardOutput $receiverLog `
    -RedirectStandardError $receiverErrLog

Start-Sleep -Seconds 1

if ($referenceAudioPath) {
    Write-Host "Reproduciendo audio de referencia (loop)..."
    $referenceAudioPlayer = Start-ReferenceAudioPlayback -FilePath $referenceAudioPath
    if ($ReferenceAudioWarmupMs -gt 0) {
        Start-Sleep -Milliseconds $ReferenceAudioWarmupMs
    }
    $ready = Wait-ReferenceAudioPlaybackReady -Playback $referenceAudioPlayer -TimeoutMs $ReferenceAudioStartTimeoutMs
    $playState = [int]$ready.State
    $playStateText = [string]$ready.StateText
    $volumeText = "n/a"
    $muteText = "n/a"
    if ($referenceAudioPlayer -is [hashtable] -and [string]$referenceAudioPlayer.Engine -eq "WMP") {
        try { $volumeText = [string]$referenceAudioPlayer.Player.settings.volume } catch {}
        try { $muteText = [string]$referenceAudioPlayer.Player.settings.mute } catch {}
    }
    Write-Host "Audio referencia estado: $playStateText ($playState), engine=$($ready.Engine), waited=$($ready.WaitedMs)ms, volume=$volumeText mute=$muteText"
    if (-not $ready.IsReady) {
        throw "El audio de referencia no paso a estado activo en $($ready.WaitedMs)ms (estado final: $playStateText/$playState). Prueba con otro archivo (ideal .wav) o aumenta -ReferenceAudioStartTimeoutMs."
    }
}

$senderArgs = @(
    "--target-ip", $TargetIp,
    "--port", "$Port",
    "--frame-ms", "$FrameMs",
    "--transport", "$Transport",
    "--source", "$Source"
)
if ($DesktopDevice -and $Source -eq "desktop") {
    $senderArgs += @("--desktop-device", $DesktopDevice)
}
$senderArgLine = ($senderArgs | ForEach-Object { Quote-Arg $_ }) -join " "
$senderProc = Start-Process -FilePath $senderExe `
    -ArgumentList $senderArgLine `
    -WorkingDirectory $senderDir `
    -PassThru `
    -WindowStyle Hidden `
    -RedirectStandardOutput $senderLog `
    -RedirectStandardError $senderErrLog
Write-Host "Sender PID: $($senderProc.Id)"

try {
    Write-Host "Capturando..."
    Start-Sleep -Seconds $DurationSec
}
finally {
    if ($senderProc -and -not $senderProc.HasExited) {
        Stop-Process -Id $senderProc.Id -Force
    }
    if ($receiverProc -and -not $receiverProc.HasExited) {
        Stop-Process -Id $receiverProc.Id -Force
    }
    Stop-ReferenceAudioPlayback -Playback $referenceAudioPlayer
    $referenceAudioPlayer = $null
    if ($autoStart) {
        $stopArgs = @(
            "-s", $device, "shell", "am", "startservice",
            "-n", "com.audiolink.receiver/.UdpAudioService",
            "-a", "com.audiolink.receiver.action.STOP"
        )
        & $adbExe @stopArgs 2>&1 | Out-Null
    }
}

Write-Host "Captura finalizada."

if (Test-Path $senderErrLog) {
    $errSize = (Get-Item $senderErrLog).Length
    if ($errSize -gt 0) {
        Add-Content -Path $senderLog -Value ""
        Add-Content -Path $senderLog -Value "----- STDERR -----"
        Get-Content $senderErrLog | Add-Content -Path $senderLog
    }
}

if (Test-Path $receiverErrLog) {
    $errSize = (Get-Item $receiverErrLog).Length
    if ($errSize -gt 0) {
        Add-Content -Path $receiverLog -Value ""
        Add-Content -Path $receiverLog -Value "----- STDERR -----"
        Get-Content $receiverErrLog | Add-Content -Path $receiverLog
    }
}

$receiverText = ""
if (Test-Path $receiverLog) {
    $receiverText = Get-Content $receiverLog -Raw -ErrorAction SilentlyContinue
}
if (-not $receiverText -or $receiverText -notmatch "stats rx=") {
    Write-Warning "No se detectaron stats del receiver. Asegurate de iniciar la app y pulsar Start antes de correr el test."
}

if (-not $SkipAnalyze) {
    $jsonOut = Join-Path $reportsDir "audio_report.json"
    $mdOut = Join-Path $reportsDir "audio_report.md"
    & $pythonExe $reportScript --logs-dir $reportsDir --out-json $jsonOut --out-md $mdOut
    Write-Host "Reporte actualizado:"
    Write-Host "  $jsonOut"
    Write-Host "  $mdOut"
}
