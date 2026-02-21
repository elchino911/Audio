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

$workspacePath = Resolve-Workspace -ProvidedWorkspace $Workspace
$statePath = Join-Path $workspacePath "tools\launcher\.runtime\mic-bridge.session.json"

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

function Stop-AllBridgeProcessesBestEffort {
    $procs = Get-Process -Name "windows-receiver" -ErrorAction SilentlyContinue
    if (-not $procs) { return 0 }
    $stopped = 0
    foreach ($proc in $procs) {
        Stop-ManagedProcess -ProcessId ([int]$proc.Id) -Label "Windows mic bridge"
        $stopped++
    }
    return $stopped
}

if (-not (Test-Path $statePath)) {
    $stopped = Stop-AllBridgeProcessesBestEffort
    if ($stopped -gt 0) {
        Write-Host "No habia sesion registrada; se detuvieron $stopped proceso(s) windows-receiver."
    } else {
        Write-Host "No hay sesion activa de windows mic bridge."
    }
    exit 0
}

$state = Get-Content $statePath -Raw | ConvertFrom-Json
$bridgeProcessId = [int]$state.Pid
if ($bridgeProcessId -gt 0) {
    Stop-ManagedProcess -ProcessId $bridgeProcessId -Label "Windows mic bridge"
}

$extraStopped = Stop-AllBridgeProcessesBestEffort
if ($extraStopped -gt 0) {
    Write-Host "Se detuvieron $extraStopped proceso(s) bridge adicionales."
}

Remove-Item $statePath -Force -ErrorAction SilentlyContinue
