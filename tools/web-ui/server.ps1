param(
    [string]$BindHost = "127.0.0.1",
    [int]$Port = 47831,
    [int]$MaxPortShift = 30,
    [string]$Workspace = "",
    [switch]$OpenBrowser,
    [string]$Token = ""
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

function Test-ProcessAlive {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    try {
        $null = Get-Process -Id $ProcessId -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Read-JsonOrNull {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return $null
    }
    try {
        return Get-Content $Path -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Resolve-AdbExe {
    $cmd = Get-Command "adb" -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    $fallback = Join-Path $env:USERPROFILE "AppData\Local\Android\Sdk\platform-tools\adb.exe"
    if (Test-Path $fallback) {
        return $fallback
    }
    return $null
}

function Test-MicSenderServiceRunning {
    param(
        [string]$AdbExe,
        [string]$DeviceSerial
    )
    if (-not $AdbExe -or -not $DeviceSerial) {
        return $null
    }
    try {
        $out = & $AdbExe -s $DeviceSerial shell dumpsys activity services com.audiolink.receiver/.MicSenderService 2>$null | Out-String
        if (-not $out) { return $null }
        if ($out -match "ServiceRecord\{" -and $out -match "MicSenderService") {
            return $true
        }
        if (
            $out -match "No services match" -or
            $out -match "Nothing to dump" -or
            $out -match "not found"
        ) {
            return $false
        }
        return $null
    } catch {
        return $null
    }
}

function Get-StatusObject {
    param(
        [string]$WorkspacePath,
        [string]$RuntimeDir
    )
    $downStatePath = Join-Path $RuntimeDir "session.json"
    $bridgeStatePath = Join-Path $RuntimeDir "mic-bridge.session.json"
    $micStatePath = Join-Path $RuntimeDir "mic-sender.session.json"
    $downState = Read-JsonOrNull -Path $downStatePath
    $bridgeState = Read-JsonOrNull -Path $bridgeStatePath
    $micState = Read-JsonOrNull -Path $micStatePath
    function Get-StateProp {
        param(
            [object]$Obj,
            [string]$Name,
            [object]$Default = $null
        )
        if ($null -eq $Obj) { return $Default }
        $p = $Obj.PSObject.Properties[$Name]
        if ($null -eq $p) { return $Default }
        return $p.Value
    }

    $down = $null
    if ($downState) {
        $downPid = [int]$downState.SenderPid
        $down = [ordered]@{
            running = (Test-ProcessAlive -ProcessId $downPid)
            pid = $downPid
            mode = "$($downState.Mode)"
            transport = "$($downState.Transport)"
            targetIp = "$($downState.TargetIp)"
            port = [int]$downState.Port
            source = "$($downState.Source)"
        }
    } else {
        $down = [ordered]@{
            running = $false
            pid = 0
            mode = ""
            transport = ""
            targetIp = ""
            port = 0
            source = ""
        }
    }

    $bridge = $null
    if ($bridgeState) {
        $bridgePid = [int]$bridgeState.Pid
        $bridge = [ordered]@{
            running = (Test-ProcessAlive -ProcessId $bridgePid)
            pid = $bridgePid
            transport = "$($bridgeState.Transport)"
            port = [int]$bridgeState.Port
            outputDevice = "$($bridgeState.OutputDevice)"
            targetBufferMs = [int]$bridgeState.TargetBufferMs
            maxBufferMs = [int]$bridgeState.MaxBufferMs
        }
    } else {
        $bridge = [ordered]@{
            running = $false
            pid = 0
            transport = ""
            port = 0
            outputDevice = ""
            targetBufferMs = 0
            maxBufferMs = 0
        }
    }

    $mic = [ordered]@{
        running = $false
        runningKnown = $false
        deviceSerial = ""
        targetIp = ""
        port = 0
        transport = ""
        mode = ""
        startedAt = ""
        hint = "Revisa logcat tag MicSenderService"
    }
    if ($micState) {
        $micSerial = "$((Get-StateProp -Obj $micState -Name 'DeviceSerial' -Default ''))"
        if (-not $micSerial -and $downState -and $downState.DeviceSerial) {
            $micSerial = "$($downState.DeviceSerial)"
        }

        $mic.runningKnown = $false
        $micRunningProbe = Test-MicSenderServiceRunning -AdbExe (Resolve-AdbExe) -DeviceSerial $micSerial
        if ($null -ne $micRunningProbe) {
            $mic.runningKnown = $true
            $mic.running = [bool]$micRunningProbe
        }

        $mic.deviceSerial = $micSerial
        $mic.targetIp = "$((Get-StateProp -Obj $micState -Name 'TargetIp' -Default ''))"
        $mic.port = [int](Get-StateProp -Obj $micState -Name 'Port' -Default 0)
        $mic.transport = "$((Get-StateProp -Obj $micState -Name 'Transport' -Default ''))"
        $mic.mode = "$((Get-StateProp -Obj $micState -Name 'MicSource' -Default ''))"
        $mic.startedAt = "$((Get-StateProp -Obj $micState -Name 'StartedAt' -Default ''))"
        if ($mic.runningKnown) {
            $mic.hint = if ($mic.running) { "MicSenderService activo" } else { "MicSenderService detenido" }
        }
    }

    return [ordered]@{
        workspace = $WorkspacePath
        runtimeDir = $RuntimeDir
        downlink = $down
        uplinkBridge = $bridge
        uplinkMic = $mic
        logFiles = [ordered]@{
            downOut = (Join-Path $RuntimeDir "sender.log")
            downErr = (Join-Path $RuntimeDir "sender.err.log")
            upOut = (Join-Path $RuntimeDir "mic-bridge.log")
            upErr = (Join-Path $RuntimeDir "mic-bridge.err.log")
        }
        server = [ordered]@{
            host = $BindHost
            port = $Port
        }
    }
}

function Read-RequestBody {
    param([System.Net.HttpListenerRequest]$Request)
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
}

function Write-JsonResponse {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [object]$Data,
        [int]$StatusCode = 200
    )
    $json = $Data | ConvertTo-Json -Depth 12
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = "application/json; charset=utf-8"
    $Response.ContentLength64 = $buffer.Length
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Response.OutputStream.Close()
}

function Write-TextResponse {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [string]$Text,
        [string]$ContentType = "text/plain; charset=utf-8",
        [int]$StatusCode = 200
    )
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $buffer.Length
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Response.OutputStream.Close()
}

function Get-MimeType {
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        ".html" { return "text/html; charset=utf-8" }
        ".css" { return "text/css; charset=utf-8" }
        ".js" { return "application/javascript; charset=utf-8" }
        ".json" { return "application/json; charset=utf-8" }
        ".svg" { return "image/svg+xml" }
        ".png" { return "image/png" }
        ".jpg" { return "image/jpeg" }
        ".ico" { return "image/x-icon" }
        default { return "application/octet-stream" }
    }
}

function Build-AudioLinkArgsFromPayload {
    param(
        [pscustomobject]$Payload,
        [string]$WorkspacePath
    )
    function Get-Prop {
        param(
            [object]$Obj,
            [string]$Name,
            [object]$Default = $null
        )
        if ($null -eq $Obj) { return $Default }
        $prop = $Obj.PSObject.Properties[$Name]
        if ($null -eq $prop) { return $Default }
        return $prop.Value
    }

    $action = "$((Get-Prop -Obj $Payload -Name 'action' -Default ''))".ToLowerInvariant()
    if ($action -notin @("start", "stop", "restart", "status", "logs")) {
        throw "action invalida: '$action'"
    }
    $profile = "$((Get-Prop -Obj $Payload -Name 'profile' -Default ''))".ToLowerInvariant()
    if ($profile -eq "") { $profile = "both" }
    if ($profile -notin @("both", "downlink", "uplink")) {
        throw "profile invalido: '$profile'"
    }

    $args = @(
        "-Action", $action,
        "-Profile", $profile,
        "-Workspace", $WorkspacePath
    )

    $deviceSerial = Get-Prop -Obj $Payload -Name "deviceSerial" -Default ""
    if ($deviceSerial) {
        $args += @("-DeviceSerial", "$deviceSerial")
    }

    $down = Get-Prop -Obj $Payload -Name "down"
    if ($down) {
        $downMode = Get-Prop -Obj $down -Name "mode" -Default ""
        $downTargetIp = Get-Prop -Obj $down -Name "targetIp" -Default ""
        $downPort = Get-Prop -Obj $down -Name "port"
        $downFrameMs = Get-Prop -Obj $down -Name "frameMs"
        $downJitterMs = Get-Prop -Obj $down -Name "jitterMs"
        $downSource = Get-Prop -Obj $down -Name "source" -Default ""
        $downTransport = Get-Prop -Obj $down -Name "transport" -Default ""
        $downDesktopDevice = Get-Prop -Obj $down -Name "desktopDevice" -Default ""
        $downSkipBuild = Get-Prop -Obj $down -Name "skipBuild" -Default $false
        $downSkipReceiverStart = Get-Prop -Obj $down -Name "skipReceiverStart" -Default $false
        $downAutoReconnectUsb = Get-Prop -Obj $down -Name "autoReconnectUsb"
        $downUsbWatchdogIntervalMs = Get-Prop -Obj $down -Name "usbWatchdogIntervalMs"

        if ($downMode) { $args += @("-DownMode", "$downMode") }
        if ($downTargetIp) { $args += @("-DownTargetIp", "$downTargetIp") }
        if ($downPort) { $args += @("-DownPort", "$downPort") }
        if ($downFrameMs) { $args += @("-DownFrameMs", "$downFrameMs") }
        if ($downJitterMs) { $args += @("-DownJitterMs", "$downJitterMs") }
        if ($downSource) { $args += @("-DownSource", "$downSource") }
        if ($downTransport) { $args += @("-DownTransport", "$downTransport") }
        if ($downDesktopDevice) { $args += @("-DownDesktopDevice", "$downDesktopDevice") }
        if ($downSkipBuild -eq $true) { $args += "-DownSkipBuild" }
        if ($downSkipReceiverStart -eq $true) { $args += "-DownSkipReceiverStart" }
        if ($null -ne $downAutoReconnectUsb) { $args += @("-DownAutoReconnectUsb", "$downAutoReconnectUsb") }
        if ($downUsbWatchdogIntervalMs) { $args += @("-DownUsbWatchdogIntervalMs", "$downUsbWatchdogIntervalMs") }
    }

    $up = Get-Prop -Obj $Payload -Name "up"
    if ($up) {
        $upTargetIp = Get-Prop -Obj $up -Name "targetIp" -Default ""
        $upPort = Get-Prop -Obj $up -Name "port"
        $upFrameMs = Get-Prop -Obj $up -Name "frameMs"
        $upTransport = Get-Prop -Obj $up -Name "transport" -Default ""
        $upMicSource = Get-Prop -Obj $up -Name "micSource" -Default ""
        $upOutputDevice = Get-Prop -Obj $up -Name "outputDevice" -Default ""
        $upTargetBufferMs = Get-Prop -Obj $up -Name "targetBufferMs"
        $upMaxBufferMs = Get-Prop -Obj $up -Name "maxBufferMs"
        $upSkipBuildBridge = Get-Prop -Obj $up -Name "skipBuildBridge" -Default $false
        $upNoRestartMic = Get-Prop -Obj $up -Name "noRestartMic" -Default $false

        if ($upTargetIp) { $args += @("-UpTargetIp", "$upTargetIp") }
        if ($upPort) { $args += @("-UpPort", "$upPort") }
        if ($upFrameMs) { $args += @("-UpFrameMs", "$upFrameMs") }
        if ($upTransport) { $args += @("-UpTransport", "$upTransport") }
        if ($upMicSource) { $args += @("-UpMicSource", "$upMicSource") }
        if ($upOutputDevice) { $args += @("-UpOutputDevice", "$upOutputDevice") }
        if ($upTargetBufferMs) { $args += @("-UpTargetBufferMs", "$upTargetBufferMs") }
        if ($upMaxBufferMs) { $args += @("-UpMaxBufferMs", "$upMaxBufferMs") }
        if ($upSkipBuildBridge -eq $true) { $args += "-UpSkipBuildBridge" }
        if ($upNoRestartMic -eq $true) { $args += "-UpNoRestartMic" }
    }

    $logs = Get-Prop -Obj $Payload -Name "logs"
    if ($logs) {
        $tail = Get-Prop -Obj $logs -Name "tail"
        if ($tail) {
            $args += @("-Tail", "$tail")
        }
    }

    return $args
}

function Invoke-AudioLinkAction {
    param(
        [string]$AudioLinkScript,
        [string[]]$Args
    )
    $cmdArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $AudioLinkScript
    ) + $Args
    $output = & powershell @cmdArgs 2>&1 | Out-String
    return $output
}

function Parse-QueryString {
    param([string]$RawQuery)
    $result = @{}
    if (-not $RawQuery) { return $result }
    $pairs = $RawQuery.TrimStart('?').Split('&', [System.StringSplitOptions]::RemoveEmptyEntries)
    foreach ($pair in $pairs) {
        $parts = $pair.Split('=', 2)
        $k = [System.Uri]::UnescapeDataString($parts[0])
        $v = if ($parts.Length -gt 1) { [System.Uri]::UnescapeDataString($parts[1]) } else { "" }
        $result[$k] = $v
    }
    return $result
}

function Read-LogTail {
    param(
        [string]$Path,
        [int]$Tail = 80
    )
    if (-not (Test-Path $Path)) {
        return ""
    }
    return (Get-Content $Path -Tail $Tail | Out-String)
}

$workspacePath = Resolve-Workspace -ProvidedWorkspace $Workspace
$runtimeDir = Join-Path $workspacePath "tools\launcher\.runtime"
$publicDir = Join-Path $PSScriptRoot "public"
$audioLinkScript = Join-Path $workspacePath "audio-link.ps1"

if (-not (Test-Path $audioLinkScript)) {
    throw "No se encontro audio-link.ps1 en $workspacePath"
}
if (-not (Test-Path $publicDir)) {
    throw "No se encontro carpeta public: $publicDir"
}

if (-not (Test-Path $runtimeDir)) {
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
}

if (-not $Token) {
    $Token = ""
}

$listener = $null
$prefix = ""
$lastStartError = $null

for ($shift = 0; $shift -le $MaxPortShift; $shift++) {
    $candidatePort = $Port + $shift
    $candidatePrefix = "http://${BindHost}:$candidatePort/"
    $candidateListener = New-Object System.Net.HttpListener
    $candidateListener.Prefixes.Add($candidatePrefix)
    try {
        $candidateListener.Start()
        $listener = $candidateListener
        $Port = $candidatePort
        $prefix = $candidatePrefix
        if ($shift -gt 0) {
            Write-Warning "Puerto solicitado ocupado. Se uso puerto alterno: $Port"
        }
        break
    } catch [System.Net.HttpListenerException] {
        $lastStartError = $_.Exception
        $candidateListener.Close()
        $msg = $lastStartError.Message.ToLowerInvariant()
        if (
            $msg.Contains("conflict") -or
            $msg.Contains("conflicto") -or
            $msg.Contains("existing")
        ) {
            continue
        }
        throw
    } catch {
        $candidateListener.Close()
        throw
    }
}

if (-not $listener) {
    if ($lastStartError) {
        throw "No se pudo iniciar HttpListener entre puertos $Port..$($Port + $MaxPortShift): $($lastStartError.Message)"
    }
    throw "No se pudo iniciar HttpListener."
}

Write-Host "Audio Link Web UI server activo en $prefix"
if ($Token) {
    Write-Host "Token API: $Token"
} else {
    Write-Host "Token API: deshabilitado (solo localhost)"
}
Write-Host "Presiona Ctrl+C para detener."

if ($OpenBrowser) {
    if ($Token) {
        Start-Process "$prefix?token=$Token" | Out-Null
    } else {
        Start-Process $prefix | Out-Null
    }
}

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        try {
            $req = $ctx.Request
            $res = $ctx.Response
            $path = $req.Url.AbsolutePath

            if ($path.StartsWith("/api/")) {
                $qs = Parse-QueryString -RawQuery $req.Url.Query
                if ($Token) {
                    $tokenHeader = "$($req.Headers["X-AudioLink-Token"])"
                    $tokenQuery = if ($qs.ContainsKey("token")) { "$($qs["token"])" } else { "" }
                    if ($tokenHeader -ne $Token -and $tokenQuery -ne $Token) {
                        Write-JsonResponse -Response $res -StatusCode 401 -Data @{
                            ok = $false
                            error = "unauthorized"
                        }
                        continue
                    }
                }

                if ($path -eq "/api/status" -and $req.HttpMethod -eq "GET") {
                    $status = Get-StatusObject -WorkspacePath $workspacePath -RuntimeDir $runtimeDir
                    Write-JsonResponse -Response $res -Data @{
                        ok = $true
                        status = $status
                    }
                    continue
                }

                if ($path -eq "/api/logs" -and $req.HttpMethod -eq "GET") {
                    $tail = if ($qs.ContainsKey("tail")) { [Math]::Max(1, [int]$qs["tail"]) } else { 80 }
                    $profile = if ($qs.ContainsKey("profile")) { "$($qs["profile"])" } else { "both" }
                    $logs = [ordered]@{}
                    if ($profile -eq "both" -or $profile -eq "downlink") {
                        $logs["downOut"] = Read-LogTail -Path (Join-Path $runtimeDir "sender.log") -Tail $tail
                        $logs["downErr"] = Read-LogTail -Path (Join-Path $runtimeDir "sender.err.log") -Tail $tail
                    }
                    if ($profile -eq "both" -or $profile -eq "uplink") {
                        $logs["upOut"] = Read-LogTail -Path (Join-Path $runtimeDir "mic-bridge.log") -Tail $tail
                        $logs["upErr"] = Read-LogTail -Path (Join-Path $runtimeDir "mic-bridge.err.log") -Tail $tail
                    }
                    Write-JsonResponse -Response $res -Data @{
                        ok = $true
                        logs = $logs
                    }
                    continue
                }

                if ($path -eq "/api/action" -and $req.HttpMethod -eq "POST") {
                    $body = Read-RequestBody -Request $req
                    if (-not $body) {
                        throw "body vacio"
                    }
                    $payload = $body | ConvertFrom-Json
                    $args = Build-AudioLinkArgsFromPayload -Payload $payload -WorkspacePath $workspacePath
                    $output = Invoke-AudioLinkAction -AudioLinkScript $audioLinkScript -Args $args
                    $status = Get-StatusObject -WorkspacePath $workspacePath -RuntimeDir $runtimeDir
                    Write-JsonResponse -Response $res -Data @{
                        ok = $true
                        output = $output
                        invokedArgs = $args
                        status = $status
                    }
                    continue
                }

                if ($path -eq "/api/shutdown" -and $req.HttpMethod -eq "POST") {
                    Write-JsonResponse -Response $res -Data @{
                        ok = $true
                        message = "server stopping"
                    }
                    break
                }

                Write-JsonResponse -Response $res -StatusCode 404 -Data @{
                    ok = $false
                    error = "not_found"
                }
                continue
            }

            $relativePath = $path.TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($relativePath)) {
                $relativePath = "index.html"
            }

            $safePath = $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            $filePath = Join-Path $publicDir $safePath
            $fullPath = [System.IO.Path]::GetFullPath($filePath)
            $publicRoot = [System.IO.Path]::GetFullPath($publicDir)

            if (-not $fullPath.StartsWith($publicRoot)) {
                Write-TextResponse -Response $res -StatusCode 403 -Text "Forbidden"
                continue
            }

            if (-not (Test-Path $fullPath -PathType Leaf)) {
                Write-TextResponse -Response $res -StatusCode 404 -Text "Not found"
                continue
            }

            $bytes = [System.IO.File]::ReadAllBytes($fullPath)
            $res.StatusCode = 200
            $res.ContentType = Get-MimeType -Path $fullPath
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
            $res.OutputStream.Close()
        } catch {
            try {
                Write-JsonResponse -Response $ctx.Response -StatusCode 500 -Data @{
                    ok = $false
                    error = "$($_.Exception.Message)"
                }
            } catch {
            }
        }
    }
} finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
}
