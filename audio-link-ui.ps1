param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$launcher = Join-Path $PSScriptRoot "tools\launcher\audio-link-ui.ps1"
if (-not (Test-Path $launcher)) {
    throw "No se encontro UI launcher: $launcher"
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $launcher @Args
exit $LASTEXITCODE
