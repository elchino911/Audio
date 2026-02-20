param(
    [string]$Workspace = "",
    [string]$OutDir = "",
    [ValidateSet("release", "debug")]
    [string]$AndroidBuildType = "release",
    [switch]$SkipWindows,
    [switch]$SkipAndroid,
    [switch]$SkipZip,
    [string]$KeystorePath = "",
    [string]$KeystoreAlias = "",
    [string]$KeystorePassword = "",
    [string]$KeyPassword = ""
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

function Resolve-ApkSigner {
    $sdkRoot = $env:ANDROID_HOME
    if (-not $sdkRoot) {
        $sdkRoot = $env:ANDROID_SDK_ROOT
    }
    if (-not $sdkRoot) {
        $sdkRoot = Join-Path $env:LOCALAPPDATA "Android\Sdk"
    }

    $buildToolsDir = Join-Path $sdkRoot "build-tools"
    if (-not (Test-Path $buildToolsDir)) {
        throw "No existe build-tools en Android SDK: $buildToolsDir"
    }

    $candidate = Get-ChildItem -Path $buildToolsDir -Directory |
    Sort-Object Name -Descending |
    Select-Object -First 1
    if (-not $candidate) {
        throw "No hay versiones de build-tools para localizar apksigner."
    }

    $apksigner = Join-Path $candidate.FullName "apksigner.bat"
    if (-not (Test-Path $apksigner)) {
        throw "No se encontro apksigner.bat en $($candidate.FullName)"
    }
    return $apksigner
}

function Ensure-JavaForGradle {
    if (Get-Command java -ErrorAction SilentlyContinue) {
        return
    }

    $candidates = @()
    if ($env:JAVA_HOME) {
        $candidates += $env:JAVA_HOME
    }
    $candidates += @(
        "$env:ProgramFiles\Android\Android Studio\jbr",
        "$env:ProgramFiles\Android\Android Studio\jre",
        "$env:ProgramFiles\Java\jdk-21",
        "$env:ProgramFiles\Java\jdk-17",
        "$env:ProgramFiles\Microsoft\jdk-17.0.*/"
    )

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $resolved = $null
        if ($c.Contains("*") -or $c.Contains("?")) {
            $resolved = Get-ChildItem -Path $c -Directory -ErrorAction SilentlyContinue |
            Select-Object -First 1 |
            ForEach-Object { $_.FullName }
        } else {
            $resolved = $c
        }
        if (-not $resolved) { continue }
        $javaExe = Join-Path $resolved "bin\java.exe"
        if (Test-Path $javaExe) {
            $env:JAVA_HOME = $resolved
            $env:Path = "$resolved\bin;$env:Path"
            Write-Host "JAVA_HOME configurado automaticamente: $resolved"
            return
        }
    }

    throw "No se encontro Java. Instala JDK 17+ o Android Studio y vuelve a ejecutar."
}

$workspacePath = Resolve-Workspace -ProvidedWorkspace $Workspace
$outRoot = if ($OutDir) { $OutDir } else { Join-Path $workspacePath "dist" }
$senderDir = Join-Path $workspacePath "windows-sender"
$androidDir = Join-Path $workspacePath "android-receiver"
$senderExe = Join-Path $senderDir "target\release\windows-sender.exe"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$packageDir = Join-Path $outRoot ("audio-link-v1-personal-{0}" -f $timestamp)
$windowsOutDir = Join-Path $packageDir "windows"
$androidOutDir = Join-Path $packageDir "android"
$toolsOutDir = Join-Path $packageDir "tools"

New-Item -ItemType Directory -Path $windowsOutDir -Force | Out-Null
New-Item -ItemType Directory -Path $androidOutDir -Force | Out-Null
New-Item -ItemType Directory -Path $toolsOutDir -Force | Out-Null

if (-not $SkipWindows) {
    $cargoExe = Resolve-Exe -CommandName "cargo" -FallbackPaths @(
        "$env:USERPROFILE\.cargo\bin\cargo.exe"
    )
    Write-Host "Compilando windows-sender (--release)..."
    Push-Location $senderDir
    try {
        & $cargoExe build --release
    } finally {
        Pop-Location
    }

    if (-not (Test-Path $senderExe)) {
        throw "No se encontro binario sender: $senderExe"
    }
    Copy-Item $senderExe (Join-Path $windowsOutDir "windows-sender.exe") -Force
}

if (-not $SkipAndroid) {
    Ensure-JavaForGradle
    $isWindows = $env:OS -eq "Windows_NT"
    $gradleCmd = if ($isWindows) { ".\gradlew.bat" } else { "./gradlew" }
    $gradleTask = if ($AndroidBuildType -eq "release") { "assembleRelease" } else { "assembleDebug" }
    Write-Host "Compilando android-receiver ($gradleTask)..."
    Push-Location $androidDir
    try {
        & $gradleCmd $gradleTask
    } finally {
        Pop-Location
    }

    $apkPath = if ($AndroidBuildType -eq "release") {
        Join-Path $androidDir "app\build\outputs\apk\release\app-release-unsigned.apk"
    } else {
        Join-Path $androidDir "app\build\outputs\apk\debug\app-debug.apk"
    }
    if (-not (Test-Path $apkPath)) {
        throw "No se encontro APK generado: $apkPath"
    }

    if (
        $AndroidBuildType -eq "release" -and
        $KeystorePath -and
        $KeystoreAlias -and
        $KeystorePassword
    ) {
        $apksigner = Resolve-ApkSigner
        $signedApk = Join-Path $androidOutDir "audio-receiver-release-signed.apk"
        $kp = if ($KeyPassword) { $KeyPassword } else { $KeystorePassword }
        Copy-Item $apkPath $signedApk -Force
        & $apksigner sign `
            --ks $KeystorePath `
            --ks-key-alias $KeystoreAlias `
            --ks-pass "pass:$KeystorePassword" `
            --key-pass "pass:$kp" `
            $signedApk
    } else {
        $name = if ($AndroidBuildType -eq "release") {
            "audio-receiver-release-unsigned.apk"
        } else {
            "audio-receiver-debug.apk"
        }
        Copy-Item $apkPath (Join-Path $androidOutDir $name) -Force
    }
}

Copy-Item (Join-Path $workspacePath "tools\launcher\start-audio-link.ps1") $toolsOutDir -Force
Copy-Item (Join-Path $workspacePath "tools\launcher\stop-audio-link.ps1") $toolsOutDir -Force
Copy-Item (Join-Path $workspacePath "tools\launcher\usb-watchdog.ps1") $toolsOutDir -Force
Copy-Item (Join-Path $workspacePath "README.md") $packageDir -Force

Write-Host "Paquete generado:"
Write-Host "  $packageDir"

if (-not $SkipZip) {
    $zipPath = "$packageDir.zip"
    if (Test-Path $zipPath) {
        Remove-Item $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $packageDir "*") -DestinationPath $zipPath
    Write-Host "ZIP generado:"
    Write-Host "  $zipPath"
}
