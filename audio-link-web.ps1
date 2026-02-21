param(
    [int]$Port = 47831,
    [int]$MaxPortShift = 30,
    [string]$BindHost = "127.0.0.1",
    [string]$Workspace = "",
    [switch]$NoOpenBrowser,
    [string]$Token = "",
    [switch]$NoStopExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$server = Join-Path $PSScriptRoot "tools\web-ui\server.ps1"
if (-not (Test-Path $server)) {
    throw "No se encontro servidor web: $server"
}

if (-not $NoStopExisting) {
    $serverPathLower = $server.ToLowerInvariant()
    $selfPid = $PID
    $existing = Get-CimInstance Win32_Process |
        Where-Object {
            $_.ProcessId -ne $selfPid -and
            $_.Name -match '^powershell(\.exe)?$' -and
            $_.CommandLine -and
            $_.CommandLine.ToLowerInvariant().Contains($serverPathLower)
        }
    foreach ($proc in $existing) {
        try {
            Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction Stop
            Write-Host "Cerrada instancia previa Web UI PID $($proc.ProcessId)"
        } catch {
            Write-Warning "No se pudo cerrar instancia previa PID $($proc.ProcessId): $($_.Exception.Message)"
        }
    }
}

$args = @(
    "-Port", "$Port",
    "-MaxPortShift", "$MaxPortShift",
    "-BindHost", "$BindHost"
)
if ($Workspace) { $args += @("-Workspace", $Workspace) }
if (-not $NoOpenBrowser) { $args += "-OpenBrowser" }
if ($Token) { $args += @("-Token", $Token) }

& powershell -NoProfile -ExecutionPolicy Bypass -File $server @args
exit $LASTEXITCODE
