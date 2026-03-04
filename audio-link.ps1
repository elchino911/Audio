param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$launcher = Join-Path $PSScriptRoot "tools\launcher\audio-link.ps1"
if (-not (Test-Path $launcher)) {
    throw "No se encontro launcher unificado: $launcher"
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $launcher @Args
exit $LASTEXITCODE
