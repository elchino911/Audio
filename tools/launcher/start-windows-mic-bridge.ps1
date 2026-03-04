param(
    [int]$Port = 50010,
    [ValidateSet("udp", "tcp")]
    [string]$Transport = "tcp",
    [string]$OutputDevice = "",
    [int]$TargetBufferMs = 30,
    [int]$MaxBufferMs = 250,
    [switch]$SkipBuild,
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

function Quote-Arg {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    if ($Value -match '[\s"]') {
        $escaped = $Value -replace '"', '\"'
        return '"' + $escaped + '"'
    }
    return $Value
}

$workspacePath = Resolve-Workspace -ProvidedWorkspace $Workspace
$receiverDir = Join-Path $workspacePath "windows-receiver"
$receiverProject = Join-Path $receiverDir "Cargo.toml"
$receiverExe = Join-Path $receiverDir "target\release\windows-receiver.exe"
$runtimeDir = Join-Path $workspacePath "tools\launcher\.runtime"
$statePath = Join-Path $runtimeDir "mic-bridge.session.json"
$logPath = Join-Path $runtimeDir "mic-bridge.log"
$errPath = Join-Path $runtimeDir "mic-bridge.err.log"

if (-not (Test-Path $receiverDir)) {
    throw "No existe windows-receiver: $receiverDir"
}
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null

if (Test-Path $statePath) {
    try {
        $old = Get-Content $statePath -Raw | ConvertFrom-Json
        if ($old.Pid) {
            Stop-Process -Id ([int]$old.Pid) -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    Remove-Item $statePath -Force -ErrorAction SilentlyContinue
}

if (Test-Path $logPath) { Remove-Item $logPath -Force -ErrorAction SilentlyContinue }
if (Test-Path $errPath) { Remove-Item $errPath -Force -ErrorAction SilentlyContinue }

if ((-not $SkipBuild -or -not (Test-Path $receiverExe)) -and (Test-Path $receiverProject)) {
    $cargoExe = Resolve-Exe -CommandName "cargo" -FallbackPaths @(
        "$env:USERPROFILE\.cargo\bin\cargo.exe"
    )
    Write-Host "Compilando windows-receiver (--release)..."
    Push-Location $receiverDir
    try {
        & $cargoExe build --release
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path $receiverExe)) {
    throw "No se encontro binario windows-receiver: $receiverExe"
}

if ((-not (Test-Path $receiverProject)) -and (-not $SkipBuild)) {
    Write-Host "Usando windows-receiver precompilado del paquete: $receiverExe"
}

$args = @(
    "--transport", $Transport,
    "--port", "$Port",
    "--target-buffer-ms", "$TargetBufferMs",
    "--max-buffer-ms", "$MaxBufferMs"
)
if ($OutputDevice -and $OutputDevice.Trim().Length -gt 0) {
    $args += @("--output-device", $OutputDevice)
}
$argLine = ($args | ForEach-Object { Quote-Arg $_ }) -join " "

$proc = Start-Process -FilePath $receiverExe `
    -ArgumentList $argLine `
    -WorkingDirectory $receiverDir `
    -PassThru `
    -WindowStyle Hidden `
    -RedirectStandardOutput $logPath `
    -RedirectStandardError $errPath

$state = [ordered]@{
    StartedAt = (Get-Date).ToString("s")
    Pid = $proc.Id
    Port = $Port
    Transport = $Transport
    OutputDevice = $OutputDevice
    TargetBufferMs = $TargetBufferMs
    MaxBufferMs = $MaxBufferMs
}
$state | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8

Write-Host "Windows mic bridge iniciado. PID: $($proc.Id)"
Write-Host "Logs: $logPath | $errPath"
