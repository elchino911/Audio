param(
    [string]$BindHost = "127.0.0.1",
    [int]$Port = 47831,
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

function Get-StatusObject {
    param(
        [string]$WorkspacePath,
        [string]$RuntimeDir
    )
    $downStatePath = Join-Path $RuntimeDir "session.json"
    $bridgeStatePath = Join-Path $RuntimeDir "mic-bridge.session.json"
    $downState = Read-JsonOrNull -Path $downStatePath
    $bridgeState = Read-JsonOrNull -Path $bridgeStatePath

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

    return [ordered]@{
        workspace = $WorkspacePath
        runtimeDir = $RuntimeDir
        downlink = $down
        uplinkBridge = $bridge
        uplinkMic = [ordered]@{
            hint = "Revisa logcat tag MicSenderService"
        }
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
    $action = "$($Payload.action)".ToLowerInvariant()
    if ($action -notin @("start", "stop", "restart", "status", "logs")) {
        throw "action invalida: '$action'"
    }
    $profile = "$($Payload.profile)".ToLowerInvariant()
    if ($profile -eq "") { $profile = "both" }
    if ($profile -notin @("both", "downlink", "uplink")) {
        throw "profile invalido: '$profile'"
    }

    $args = @(
        "-Action", $action,
        "-Profile", $profile,
        "-Workspace", $WorkspacePath
    )

    if ($Payload.deviceSerial) {
        $args += @("-DeviceSerial", "$($Payload.deviceSerial)")
    }

    if ($Payload.down) {
        $down = $Payload.down
        if ($down.mode) { $args += @("-DownMode", "$($down.mode)") }
        if ($down.targetIp) { $args += @("-DownTargetIp", "$($down.targetIp)") }
        if ($down.port) { $args += @("-DownPort", "$($down.port)") }
        if ($down.frameMs) { $args += @("-DownFrameMs", "$($down.frameMs)") }
        if ($down.jitterMs) { $args += @("-DownJitterMs", "$($down.jitterMs)") }
        if ($down.source) { $args += @("-DownSource", "$($down.source)") }
        if ($down.transport) { $args += @("-DownTransport", "$($down.transport)") }
        if ($down.desktopDevice) { $args += @("-DownDesktopDevice", "$($down.desktopDevice)") }
        if ($down.skipBuild -eq $true) { $args += "-DownSkipBuild" }
        if ($down.skipReceiverStart -eq $true) { $args += "-DownSkipReceiverStart" }
        if ($null -ne $down.autoReconnectUsb) { $args += @("-DownAutoReconnectUsb", "$($down.autoReconnectUsb)") }
        if ($down.usbWatchdogIntervalMs) { $args += @("-DownUsbWatchdogIntervalMs", "$($down.usbWatchdogIntervalMs)") }
    }

    if ($Payload.up) {
        $up = $Payload.up
        if ($up.targetIp) { $args += @("-UpTargetIp", "$($up.targetIp)") }
        if ($up.port) { $args += @("-UpPort", "$($up.port)") }
        if ($up.frameMs) { $args += @("-UpFrameMs", "$($up.frameMs)") }
        if ($up.transport) { $args += @("-UpTransport", "$($up.transport)") }
        if ($up.micSource) { $args += @("-UpMicSource", "$($up.micSource)") }
        if ($up.outputDevice) { $args += @("-UpOutputDevice", "$($up.outputDevice)") }
        if ($up.targetBufferMs) { $args += @("-UpTargetBufferMs", "$($up.targetBufferMs)") }
        if ($up.maxBufferMs) { $args += @("-UpMaxBufferMs", "$($up.maxBufferMs)") }
        if ($up.skipBuildBridge -eq $true) { $args += "-UpSkipBuildBridge" }
        if ($up.noRestartMic -eq $true) { $args += "-UpNoRestartMic" }
    }

    if ($Payload.logs -and $Payload.logs.tail) {
        $args += @("-Tail", "$($Payload.logs.tail)")
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

$listener = New-Object System.Net.HttpListener
$prefix = "http://${BindHost}:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()

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
