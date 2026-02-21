param(
    [string]$Workspace = ""
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

    if (-not (Is-ProcessRunning -ProcessId $ProcessId)) {
        Write-Host "$Label no estaba en ejecucion (PID $ProcessId)."
        return
    }

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

    Write-Host "$Label detenido (PID $ProcessId)."
}

function Stop-AllSendersBestEffort {
    $senders = Get-Process -Name "windows-sender" -ErrorAction SilentlyContinue
    if (-not $senders) {
        return 0
    }
    $stopped = 0
    foreach ($proc in $senders) {
        Stop-ManagedProcess -ProcessId ([int]$proc.Id) -Label "Sender"
        $stopped++
    }
    return $stopped
}

$workspacePath = Resolve-Workspace -ProvidedWorkspace $Workspace
$runtimeDir = Join-Path $workspacePath "tools\launcher\.runtime"
$statePath = Join-Path $runtimeDir "session.json"

if (-not (Test-Path $statePath)) {
    $stopped = Stop-AllSendersBestEffort
    if ($stopped -gt 0) {
        Write-Host "No habia sesion registrada; se detuvieron $stopped proceso(s) windows-sender."
    } else {
        Write-Host "No hay sesion activa registrada."
    }
    exit 0
}

$state = Get-Content $statePath -Raw | ConvertFrom-Json
$senderPid = [int]$state.SenderPid
$watchdogPid = [int]$state.WatchdogPid
$port = [int]$state.Port
$deviceSerial = [string]$state.DeviceSerial
$mode = [string]$state.Mode

if ($watchdogPid -gt 0) {
    Stop-ManagedProcess -ProcessId $watchdogPid -Label "Watchdog"
}

if ($senderPid -gt 0) {
    Stop-ManagedProcess -ProcessId $senderPid -Label "Sender"
}

# Si quedaron senders huerfanos (sin estado), cerrarlos tambien.
$extraStopped = Stop-AllSendersBestEffort
if ($extraStopped -gt 0) {
    Write-Host "Se detuvieron $extraStopped proceso(s) sender adicionales."
}

if ($deviceSerial) {
    $adbExe = Resolve-Exe -CommandName "adb" -FallbackPaths @(
        "$env:USERPROFILE\AppData\Local\Android\Sdk\platform-tools\adb.exe"
    )

    $stopArgs = @(
        "-s", $deviceSerial, "shell", "am", "startservice",
        "-n", "com.audiolink.receiver/.UdpAudioService",
        "-a", "com.audiolink.receiver.action.STOP"
    )
    $null = Invoke-AdbSafe -AdbExe $adbExe -CommandArgs $stopArgs

    if ($mode -eq "usb" -and $port -gt 0) {
        $removeResult = Invoke-AdbSafe -AdbExe $adbExe -CommandArgs @(
            "-s", $deviceSerial, "forward", "--remove", "tcp:$port"
        )
        if ($removeResult.ExitCode -ne 0) {
            $removeText = ($removeResult.Output | Out-String).Trim()
            if ($removeText -notmatch "listener 'tcp:$port' not found") {
                Write-Warning "No se pudo remover adb forward: $removeText"
            }
        }
        Write-Host "adb forward tcp:$port removido."
    }
}

Remove-Item $statePath -Force -ErrorAction SilentlyContinue
Write-Host "Sesion cerrada."
