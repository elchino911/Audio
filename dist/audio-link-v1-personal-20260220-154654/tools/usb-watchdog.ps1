param(
    [string]$Workspace = "",
    [string]$StatePath = "",
    [int]$IntervalMs = 1500
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

function Write-WatchdogLog {
    param([string]$Message)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "[$ts] $Message"
}

function Test-ProcessRunning {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    try {
        $null = Get-Process -Id $ProcessId -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Load-State {
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

function Save-State {
    param(
        $StateObject,
        [string]$Path
    )
    $StateObject | ConvertTo-Json | Set-Content -Path $Path -Encoding UTF8
}

function Ensure-Forward {
    param(
        [string]$AdbExe,
        [string]$Serial,
        [int]$Port
    )

    $listResult = Invoke-AdbSafe -AdbExe $AdbExe -CommandArgs @(
        "-s", $Serial, "forward", "--list"
    )
    if ($listResult.ExitCode -ne 0) {
        return @{
            Ok = $false
            Changed = $false
            Message = (($listResult.Output | Out-String).Trim())
        }
    }

    $pattern = "^$([regex]::Escape($Serial))\s+tcp:$Port\s+tcp:$Port$"
    $exists = $false
    foreach ($line in $listResult.Output) {
        if ([string]$line -match $pattern) {
            $exists = $true
            break
        }
    }
    if ($exists) {
        return @{
            Ok = $true
            Changed = $false
            Message = "forward ok"
        }
    }

    $removeResult = Invoke-AdbSafe -AdbExe $AdbExe -CommandArgs @(
        "-s", $Serial, "forward", "--remove", "tcp:$Port"
    )
    if ($removeResult.ExitCode -ne 0) {
        $removeText = ($removeResult.Output | Out-String).Trim()
        if ($removeText -notmatch "listener 'tcp:$Port' not found") {
            return @{
                Ok = $false
                Changed = $false
                Message = "forward remove fallo: $removeText"
            }
        }
    }

    $forwardResult = Invoke-AdbSafe -AdbExe $AdbExe -CommandArgs @(
        "-s", $Serial, "forward", "tcp:$Port", "tcp:$Port"
    )
    if ($forwardResult.ExitCode -ne 0) {
        return @{
            Ok = $false
            Changed = $false
            Message = "forward set fallo: $(($forwardResult.Output | Out-String).Trim())"
        }
    }

    return @{
        Ok = $true
        Changed = $true
        Message = "forward recreado"
    }
}

function Start-Receiver {
    param(
        [string]$AdbExe,
        [string]$Serial,
        [int]$Port,
        [int]$JitterMs,
        [string]$Transport
    )

    $stopArgs = @(
        "-s", $Serial, "shell", "am", "startservice",
        "-n", "com.audiolink.receiver/.UdpAudioService",
        "-a", "com.audiolink.receiver.action.STOP"
    )
    $null = Invoke-AdbSafe -AdbExe $AdbExe -CommandArgs $stopArgs
    Start-Sleep -Milliseconds 250

    $startArgs = @(
        "-s", $Serial, "shell", "am", "start-foreground-service",
        "-n", "com.audiolink.receiver/.UdpAudioService",
        "-a", "com.audiolink.receiver.action.START",
        "--ei", "extra_port", "$Port",
        "--ei", "extra_jitter_ms", "$JitterMs",
        "--es", "extra_transport", "$Transport"
    )
    return Invoke-AdbSafe -AdbExe $AdbExe -CommandArgs $startArgs
}

function Build-SenderArgs {
    param($State)
    $args = @(
        "--target-ip", [string]$State.TargetIp,
        "--port", [string]$State.Port,
        "--frame-ms", [string]$State.FrameMs,
        "--transport", [string]$State.Transport,
        "--source", [string]$State.Source
    )
    $desktopDevice = [string]$State.DesktopDevice
    if ($desktopDevice -and [string]$State.Source -eq "desktop") {
        $args += @("--desktop-device", $desktopDevice)
    }
    return $args
}

function Restart-Sender {
    param($State)
    $senderExe = [string]$State.SenderExe
    $senderDir = [string]$State.SenderDir
    $senderLog = [string]$State.SenderLog
    $senderErrLog = [string]$State.SenderErrLog
    if (-not (Test-Path $senderExe)) {
        throw "No existe sender exe: $senderExe"
    }
    if (-not (Test-Path $senderDir)) {
        throw "No existe sender dir: $senderDir"
    }

    $senderArgs = Build-SenderArgs -State $State
    $proc = Start-Process -FilePath $senderExe `
        -ArgumentList $senderArgs `
        -WorkingDirectory $senderDir `
        -PassThru `
        -WindowStyle Hidden `
        -RedirectStandardOutput $senderLog `
        -RedirectStandardError $senderErrLog
    return $proc.Id
}

$workspacePath = Resolve-Workspace -ProvidedWorkspace $Workspace
if (-not $StatePath) {
    $StatePath = Join-Path $workspacePath "tools\launcher\.runtime\session.json"
}

$adbExe = Resolve-Exe -CommandName "adb" -FallbackPaths @(
    "$env:USERPROFILE\AppData\Local\Android\Sdk\platform-tools\adb.exe"
)

$sleepMs = [Math]::Max(500, $IntervalMs)
$deviceWasOnline = $false

Write-WatchdogLog "watchdog iniciado (pid=$PID, interval=${sleepMs}ms)"

while ($true) {
    if (-not (Test-Path $StatePath)) {
        Write-WatchdogLog "state no existe; watchdog finaliza."
        break
    }

    $state = Load-State -Path $StatePath
    if ($null -eq $state) {
        Start-Sleep -Milliseconds $sleepMs
        continue
    }
    if ([string]$state.Mode -ne "usb" -or -not [bool]$state.AutoReconnectUsb) {
        Write-WatchdogLog "modo no-usb o autoReconnect desactivado; watchdog finaliza."
        break
    }

    $currentWatchdogPid = [int]$state.WatchdogPid
    if ($currentWatchdogPid -ne $PID) {
        if ($currentWatchdogPid -gt 0 -and (Test-ProcessRunning -ProcessId $currentWatchdogPid)) {
            Write-WatchdogLog "otro watchdog activo ($currentWatchdogPid); salida."
            break
        }
        $state.WatchdogPid = $PID
        Save-State -StateObject $state -Path $StatePath
    }

    $senderPid = [int]$state.SenderPid
    if (-not (Test-ProcessRunning -ProcessId $senderPid)) {
        try {
            $newSenderPid = Restart-Sender -State $state
            $state.SenderPid = $newSenderPid
            Save-State -StateObject $state -Path $StatePath
            Write-WatchdogLog "sender reiniciado pid=$newSenderPid"
        } catch {
            Write-WatchdogLog "fallo al reiniciar sender: $($_.Exception.Message)"
        }
    }

    $serial = [string]$state.DeviceSerial
    if (-not $serial) {
        Start-Sleep -Milliseconds $sleepMs
        continue
    }

    $stateResult = Invoke-AdbSafe -AdbExe $adbExe -CommandArgs @(
        "-s", $serial, "get-state"
    )
    $stateText = (($stateResult.Output | Out-String).Trim())
    $isOnline = ($stateResult.ExitCode -eq 0 -and $stateText -match "\bdevice\b")

    if ($isOnline -and -not $deviceWasOnline) {
        Write-WatchdogLog "dispositivo reconectado ($serial)"
    }
    if (-not $isOnline -and $deviceWasOnline) {
        Write-WatchdogLog "dispositivo desconectado ($serial)"
    }

    if ($isOnline) {
        $forward = Ensure-Forward -AdbExe $adbExe -Serial $serial -Port ([int]$state.Port)
        if (-not $forward.Ok) {
            Write-WatchdogLog "forward no listo: $($forward.Message)"
        } elseif ($forward.Changed) {
            Write-WatchdogLog "forward restaurado"
        }

        $needKick = $forward.Changed -or -not $deviceWasOnline
        if ($needKick -and -not [bool]$state.SkipReceiverStart) {
            $receiver = Start-Receiver `
                -AdbExe $adbExe `
                -Serial $serial `
                -Port ([int]$state.Port) `
                -JitterMs ([int]$state.JitterMs) `
                -Transport ([string]$state.Transport)
            if ($receiver.ExitCode -ne 0) {
                Write-WatchdogLog "no se pudo iniciar receiver: $(($receiver.Output | Out-String).Trim())"
            } else {
                Write-WatchdogLog "receiver refrescado"
            }
        }
    }

    $deviceWasOnline = $isOnline
    Start-Sleep -Milliseconds $sleepMs
}
