param(
    [string]$Workspace = "",
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64",
    [switch]$NoBuild,
    [switch]$BuildOnly,
    [switch]$Legacy,
    [switch]$HeadlessStatus
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

function Invoke-LegacyUi {
    param(
        [string]$WorkspacePath,
        [bool]$Headless
    )
    $legacy = Join-Path $PSScriptRoot "audio-link-ui-legacy.ps1"
    if (-not (Test-Path $legacy)) {
        throw "No se encontro UI legacy: $legacy"
    }

    $args = @("-Workspace", $WorkspacePath)
    if ($Headless) { $args += "-HeadlessStatus" }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $legacy @args
    exit $LASTEXITCODE
}

function Invoke-LegacyUiIfAvailable {
    param(
        [string]$WorkspacePath,
        [bool]$Headless,
        [bool]$BuildOnly
    )
    $legacy = Join-Path $PSScriptRoot "audio-link-ui-legacy.ps1"
    if (-not (Test-Path $legacy)) {
        return $false
    }

    if ($BuildOnly) {
        Write-Host "UI nativa no disponible. Se usara UI legacy."
        exit 0
    }

    Write-Host "UI nativa no disponible. Abriendo UI legacy..."
    Invoke-LegacyUi -WorkspacePath $WorkspacePath -Headless $Headless
    return $true
}

function Resolve-Dotnet {
    $cmd = Get-Command "dotnet" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "No se encontro dotnet en PATH."
}

$workspacePath = Resolve-Workspace -ProvidedWorkspace $Workspace
if ($Legacy) {
    Invoke-LegacyUi -WorkspacePath $workspacePath -Headless ([bool]$HeadlessStatus)
}

if ($HeadlessStatus) {
    $audioLink = Join-Path $workspacePath "audio-link.ps1"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $audioLink -Action status -Profile both -Workspace $workspacePath
    exit $LASTEXITCODE
}

$portableExe = Join-Path $workspacePath "ui-native\AudioLinkNativeUI.exe"
$packagedExe = Join-Path $workspacePath "dist\audio-link-native-ui\AudioLinkNativeUI.exe"
$project = Join-Path $workspacePath "windows-native-ui\AudioLinkNativeUI.csproj"
if (-not (Test-Path $project)) {
    if (Test-Path $portableExe) {
        Write-Host "UI nativa portable detectada: $portableExe"
        if ($BuildOnly) {
            exit 0
        }
        Start-Process -FilePath $portableExe -ArgumentList @("--workspace", $workspacePath)
        exit 0
    }
    if (Test-Path $packagedExe) {
        Write-Host "UI nativa publicada detectada: $packagedExe"
        if ($BuildOnly) {
            exit 0
        }
        Start-Process -FilePath $packagedExe -ArgumentList @("--workspace", $workspacePath)
        exit 0
    }
    if (Invoke-LegacyUiIfAvailable -WorkspacePath $workspacePath -Headless ([bool]$HeadlessStatus) -BuildOnly ([bool]$BuildOnly)) {
        exit 0
    }
    throw "No existe proyecto UI nativa ni fallback legacy: $project"
}

$publishDir = Join-Path $workspacePath "dist\audio-link-native-ui"
$exePath = Join-Path $publishDir "AudioLinkNativeUI.exe"
$dotnet = Resolve-Dotnet

if (-not $NoBuild -or -not (Test-Path $exePath)) {
    New-Item -ItemType Directory -Path $publishDir -Force | Out-Null
    Write-Host "Compilando UI nativa..."
    & $dotnet publish $project -c $Configuration -r $Runtime --self-contained false -p:PublishSingleFile=false -o $publishDir
    if ($LASTEXITCODE -ne 0) {
        throw "Fallo dotnet publish para UI nativa."
    }
}

if (-not (Test-Path $exePath)) {
    throw "No se encontro ejecutable UI nativa: $exePath"
}

Write-Host "UI nativa lista: $exePath"
if ($BuildOnly) {
    exit 0
}

Start-Process -FilePath $exePath -ArgumentList @("--workspace", $workspacePath)
