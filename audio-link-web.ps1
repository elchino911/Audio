param(
    [int]$Port = 47831,
    [string]$BindHost = "127.0.0.1",
    [string]$Workspace = "",
    [switch]$NoOpenBrowser,
    [string]$Token = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$server = Join-Path $PSScriptRoot "tools\web-ui\server.ps1"
if (-not (Test-Path $server)) {
    throw "No se encontro servidor web: $server"
}

$args = @(
    "-Port", "$Port",
    "-BindHost", "$BindHost"
)
if ($Workspace) { $args += @("-Workspace", $Workspace) }
if (-not $NoOpenBrowser) { $args += "-OpenBrowser" }
if ($Token) { $args += @("-Token", $Token) }

& powershell -NoProfile -ExecutionPolicy Bypass -File $server @args
exit $LASTEXITCODE
