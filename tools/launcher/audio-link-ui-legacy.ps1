param(
    [string]$Workspace = "",
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

function Invoke-AudioLinkCommand {
    param(
        [string]$WorkspacePath,
        [string[]]$ExtraArgs
    )
    $entry = Join-Path $WorkspacePath "audio-link.ps1"
    if (-not (Test-Path $entry)) {
        throw "No se encontro launcher principal: $entry"
    }
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $entry
    ) + $ExtraArgs
    return (& powershell @args 2>&1 | Out-String)
}

$workspacePath = Resolve-Workspace -ProvidedWorkspace $Workspace
$runtimeDir = Join-Path $workspacePath "tools\launcher\.runtime"

if ($HeadlessStatus) {
    $out = Invoke-AudioLinkCommand -WorkspacePath $workspacePath -ExtraArgs @("-Action", "status", "-Profile", "both")
    Write-Host $out
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = "Audio Link Control Center"
$form.Size = New-Object System.Drawing.Size(980, 740)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(900, 680)

$font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Font = $font

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = "Fill"

$tabControl = New-Object System.Windows.Forms.TabPage
$tabControl.Text = "Control"
$tabs.TabPages.Add($tabControl) | Out-Null

$tabLogs = New-Object System.Windows.Forms.TabPage
$tabLogs.Text = "Logs"
$tabs.TabPages.Add($tabLogs) | Out-Null

$form.Controls.Add($tabs)

$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Dock = "Top"
$panelTop.Height = 400
$tabControl.Controls.Add($panelTop)

$panelBottom = New-Object System.Windows.Forms.Panel
$panelBottom.Dock = "Fill"
$tabControl.Controls.Add($panelBottom)

$outputBox = New-Object System.Windows.Forms.TextBox
$outputBox.Multiline = $true
$outputBox.ReadOnly = $true
$outputBox.ScrollBars = "Vertical"
$outputBox.Dock = "Fill"
$outputBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$panelBottom.Controls.Add($outputBox)

$busyLabel = New-Object System.Windows.Forms.Label
$busyLabel.AutoSize = $true
$busyLabel.Text = ""
$busyLabel.Location = New-Object System.Drawing.Point(10, 8)
$busyLabel.ForeColor = [System.Drawing.Color]::DarkOrange
$panelBottom.Controls.Add($busyLabel)

function Append-Output {
    param([string]$Text)
    $ts = (Get-Date).ToString("HH:mm:ss")
    $outputBox.AppendText("[$ts] $Text`r`n")
}

function Set-UiBusy {
    param(
        [bool]$Busy,
        [string]$Message = ""
    )
    $form.UseWaitCursor = $Busy
    $busyLabel.Text = if ($Busy) { $Message } else { "" }
}

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 140, [int]$H = 22)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    return $l
}

function New-TextBox {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 210)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Text = $Text
    $t.Location = New-Object System.Drawing.Point($X, $Y)
    $t.Size = New-Object System.Drawing.Size($W, 24)
    return $t
}

function New-Combo {
    param([string[]]$Items, [string]$Value, [int]$X, [int]$Y, [int]$W = 120)
    $c = New-Object System.Windows.Forms.ComboBox
    $c.DropDownStyle = "DropDownList"
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, 24)
    foreach ($it in $Items) { $null = $c.Items.Add($it) }
    $c.SelectedItem = $Value
    return $c
}

function New-Num {
    param([int]$Value, [int]$Min, [int]$Max, [int]$X, [int]$Y, [int]$W = 90)
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Location = New-Object System.Drawing.Point($X, $Y)
    $n.Size = New-Object System.Drawing.Size($W, 24)
    $n.Minimum = $Min
    $n.Maximum = $Max
    $n.Value = $Value
    return $n
}

$groupGlobal = New-Object System.Windows.Forms.GroupBox
$groupGlobal.Text = "Global"
$groupGlobal.Location = New-Object System.Drawing.Point(10, 8)
$groupGlobal.Size = New-Object System.Drawing.Size(940, 70)
$panelTop.Controls.Add($groupGlobal)

$groupGlobal.Controls.Add((New-Label -Text "Profile" -X 16 -Y 30 -W 60))
$cmbProfile = New-Combo -Items @("both", "downlink", "uplink") -Value "both" -X 80 -Y 26 -W 110
$groupGlobal.Controls.Add($cmbProfile)

$groupGlobal.Controls.Add((New-Label -Text "Device Serial" -X 220 -Y 30 -W 90))
$txtSerial = New-TextBox -Text "" -X 315 -Y 26 -W 170
$groupGlobal.Controls.Add($txtSerial)

$groupGlobal.Controls.Add((New-Label -Text "Workspace" -X 510 -Y 30 -W 75))
$txtWorkspace = New-TextBox -Text $workspacePath -X 590 -Y 26 -W 330
$groupGlobal.Controls.Add($txtWorkspace)

$groupDown = New-Object System.Windows.Forms.GroupBox
$groupDown.Text = "Downlink (Windows -> Android)"
$groupDown.Location = New-Object System.Drawing.Point(10, 86)
$groupDown.Size = New-Object System.Drawing.Size(940, 145)
$panelTop.Controls.Add($groupDown)

$groupDown.Controls.Add((New-Label -Text "Mode" -X 16 -Y 28 -W 50))
$cmbDownMode = New-Combo -Items @("network", "usb") -Value "network" -X 70 -Y 24 -W 90
$groupDown.Controls.Add($cmbDownMode)

$groupDown.Controls.Add((New-Label -Text "Target IP" -X 180 -Y 28 -W 60))
$txtDownIp = New-TextBox -Text "" -X 245 -Y 24 -W 140
$groupDown.Controls.Add($txtDownIp)

$groupDown.Controls.Add((New-Label -Text "Port" -X 400 -Y 28 -W 40))
$numDownPort = New-Num -Value 50000 -Min 1 -Max 65535 -X 445 -Y 24 -W 85
$groupDown.Controls.Add($numDownPort)

$groupDown.Controls.Add((New-Label -Text "Frame ms" -X 545 -Y 28 -W 60))
$numDownFrame = New-Num -Value 5 -Min 1 -Max 20 -X 610 -Y 24 -W 70
$groupDown.Controls.Add($numDownFrame)

$groupDown.Controls.Add((New-Label -Text "Jitter ms" -X 700 -Y 28 -W 60))
$numDownJitter = New-Num -Value 20 -Min 5 -Max 250 -X 765 -Y 24 -W 70
$groupDown.Controls.Add($numDownJitter)

$groupDown.Controls.Add((New-Label -Text "Source" -X 16 -Y 64 -W 50))
$cmbDownSource = New-Combo -Items @("desktop", "mic") -Value "desktop" -X 70 -Y 60 -W 90
$groupDown.Controls.Add($cmbDownSource)

$groupDown.Controls.Add((New-Label -Text "Transport" -X 180 -Y 64 -W 60))
$cmbDownTransport = New-Combo -Items @("udp", "tcp") -Value "udp" -X 245 -Y 60 -W 80
$groupDown.Controls.Add($cmbDownTransport)

$groupDown.Controls.Add((New-Label -Text "Desktop Device (optional)" -X 345 -Y 64 -W 160))
$txtDesktopDevice = New-TextBox -Text "" -X 510 -Y 60 -W 325
$groupDown.Controls.Add($txtDesktopDevice)

$chkDownSkipBuild = New-Object System.Windows.Forms.CheckBox
$chkDownSkipBuild.Text = "Skip build"
$chkDownSkipBuild.Location = New-Object System.Drawing.Point(70, 100)
$chkDownSkipBuild.Size = New-Object System.Drawing.Size(95, 24)
$groupDown.Controls.Add($chkDownSkipBuild)

$chkDownSkipReceiver = New-Object System.Windows.Forms.CheckBox
$chkDownSkipReceiver.Text = "Skip Android receiver start"
$chkDownSkipReceiver.Location = New-Object System.Drawing.Point(180, 100)
$chkDownSkipReceiver.Size = New-Object System.Drawing.Size(210, 24)
$groupDown.Controls.Add($chkDownSkipReceiver)

$groupUp = New-Object System.Windows.Forms.GroupBox
$groupUp.Text = "Uplink (Android mic -> Windows)"
$groupUp.Location = New-Object System.Drawing.Point(10, 239)
$groupUp.Size = New-Object System.Drawing.Size(940, 145)
$panelTop.Controls.Add($groupUp)

$groupUp.Controls.Add((New-Label -Text "Target IP" -X 16 -Y 28 -W 60))
$txtUpIp = New-TextBox -Text "" -X 80 -Y 24 -W 140
$groupUp.Controls.Add($txtUpIp)

$groupUp.Controls.Add((New-Label -Text "Port" -X 240 -Y 28 -W 40))
$numUpPort = New-Num -Value 50010 -Min 1 -Max 65535 -X 285 -Y 24 -W 85
$groupUp.Controls.Add($numUpPort)

$groupUp.Controls.Add((New-Label -Text "Frame ms" -X 390 -Y 28 -W 60))
$numUpFrame = New-Num -Value 5 -Min 1 -Max 20 -X 455 -Y 24 -W 70
$groupUp.Controls.Add($numUpFrame)

$groupUp.Controls.Add((New-Label -Text "Transport" -X 545 -Y 28 -W 60))
$cmbUpTransport = New-Combo -Items @("tcp", "udp") -Value "tcp" -X 610 -Y 24 -W 80
$groupUp.Controls.Add($cmbUpTransport)

$groupUp.Controls.Add((New-Label -Text "Mic source" -X 705 -Y 28 -W 65))
$cmbUpMicSource = New-Combo -Items @("auto", "phone", "bluetooth") -Value "auto" -X 775 -Y 24 -W 120
$groupUp.Controls.Add($cmbUpMicSource)

$groupUp.Controls.Add((New-Label -Text "Output Device (Windows)" -X 16 -Y 64 -W 140))
$txtUpOutputDevice = New-TextBox -Text "CABLE Input (VB-Audio Virtual Cable)" -X 160 -Y 60 -W 340
$groupUp.Controls.Add($txtUpOutputDevice)

$groupUp.Controls.Add((New-Label -Text "Target buffer ms" -X 520 -Y 64 -W 95))
$numUpTargetBuffer = New-Num -Value 50 -Min 5 -Max 1000 -X 620 -Y 60 -W 80
$groupUp.Controls.Add($numUpTargetBuffer)

$groupUp.Controls.Add((New-Label -Text "Max buffer ms" -X 720 -Y 64 -W 85))
$numUpMaxBuffer = New-Num -Value 250 -Min 20 -Max 3000 -X 810 -Y 60 -W 80
$groupUp.Controls.Add($numUpMaxBuffer)

$chkUpSkipBuild = New-Object System.Windows.Forms.CheckBox
$chkUpSkipBuild.Text = "Skip bridge build"
$chkUpSkipBuild.Location = New-Object System.Drawing.Point(160, 100)
$chkUpSkipBuild.Size = New-Object System.Drawing.Size(140, 24)
$groupUp.Controls.Add($chkUpSkipBuild)

$chkUpNoRestart = New-Object System.Windows.Forms.CheckBox
$chkUpNoRestart.Text = "No restart mic service"
$chkUpNoRestart.Location = New-Object System.Drawing.Point(320, 100)
$chkUpNoRestart.Size = New-Object System.Drawing.Size(160, 24)
$groupUp.Controls.Add($chkUpNoRestart)

$panelButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$panelButtons.Dock = "Bottom"
$panelButtons.Height = 44
$panelButtons.FlowDirection = "LeftToRight"
$tabControl.Controls.Add($panelButtons)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "Start"
$btnStart.Width = 120
$panelButtons.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = "Stop"
$btnStop.Width = 120
$panelButtons.Controls.Add($btnStop)

$btnRestart = New-Object System.Windows.Forms.Button
$btnRestart.Text = "Restart"
$btnRestart.Width = 120
$panelButtons.Controls.Add($btnRestart)

$btnStatus = New-Object System.Windows.Forms.Button
$btnStatus.Text = "Status"
$btnStatus.Width = 120
$panelButtons.Controls.Add($btnStatus)

$btnLogs = New-Object System.Windows.Forms.Button
$btnLogs.Text = "Logs"
$btnLogs.Width = 120
$panelButtons.Controls.Add($btnLogs)

$btnOpenRuntime = New-Object System.Windows.Forms.Button
$btnOpenRuntime.Text = "Open Runtime Folder"
$btnOpenRuntime.Width = 170
$panelButtons.Controls.Add($btnOpenRuntime)

$logsBox = New-Object System.Windows.Forms.TextBox
$logsBox.Multiline = $true
$logsBox.ReadOnly = $true
$logsBox.ScrollBars = "Vertical"
$logsBox.Dock = "Fill"
$logsBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$tabLogs.Controls.Add($logsBox)

function Collect-Args {
    param([string]$ActionName)
    $ws = $txtWorkspace.Text.Trim()
    $args = @(
        "-Action", $ActionName,
        "-Profile", $cmbProfile.SelectedItem.ToString(),
        "-Workspace", $ws
    )

    $serial = $txtSerial.Text.Trim()
    if ($serial) { $args += @("-DeviceSerial", $serial) }

    $args += @(
        "-DownMode", $cmbDownMode.SelectedItem.ToString(),
        "-DownPort", ([int]$numDownPort.Value).ToString(),
        "-DownFrameMs", ([int]$numDownFrame.Value).ToString(),
        "-DownJitterMs", ([int]$numDownJitter.Value).ToString(),
        "-DownSource", $cmbDownSource.SelectedItem.ToString(),
        "-DownTransport", $cmbDownTransport.SelectedItem.ToString()
    )
    $downIp = $txtDownIp.Text.Trim()
    if ($downIp) { $args += @("-DownTargetIp", $downIp) }
    $downDev = $txtDesktopDevice.Text.Trim()
    if ($downDev) { $args += @("-DownDesktopDevice", $downDev) }
    if ($chkDownSkipBuild.Checked) { $args += "-DownSkipBuild" }
    if ($chkDownSkipReceiver.Checked) { $args += "-DownSkipReceiverStart" }

    $args += @(
        "-UpPort", ([int]$numUpPort.Value).ToString(),
        "-UpFrameMs", ([int]$numUpFrame.Value).ToString(),
        "-UpTransport", $cmbUpTransport.SelectedItem.ToString(),
        "-UpMicSource", $cmbUpMicSource.SelectedItem.ToString(),
        "-UpOutputDevice", $txtUpOutputDevice.Text.Trim(),
        "-UpTargetBufferMs", ([int]$numUpTargetBuffer.Value).ToString(),
        "-UpMaxBufferMs", ([int]$numUpMaxBuffer.Value).ToString()
    )
    $upIp = $txtUpIp.Text.Trim()
    if ($upIp) { $args += @("-UpTargetIp", $upIp) }
    if ($chkUpSkipBuild.Checked) { $args += "-UpSkipBuildBridge" }
    if ($chkUpNoRestart.Checked) { $args += "-UpNoRestartMic" }

    return @{
        Workspace = $ws
        Args = $args
    }
}

function Refresh-LogsTab {
    try {
        $collected = Collect-Args -ActionName "logs"
        $collected.Args += @("-Tail", "80")
        $out = Invoke-AudioLinkCommand -WorkspacePath $collected.Workspace -ExtraArgs $collected.Args
        $logsBox.Text = $out
    } catch {
        $logsBox.Text = "ERROR: $($_.Exception.Message)"
    }
}

$actionWorker = New-Object System.ComponentModel.BackgroundWorker

$actionWorker.DoWork += {
    param($sender, $e)
    $payload = $e.Argument
    try {
        $out = Invoke-AudioLinkCommand -WorkspacePath $payload.Workspace -ExtraArgs $payload.Args
        $e.Result = @{
            Ok = $true
            Output = $out
            ActionName = $payload.ActionName
            RefreshLogs = [bool]$payload.RefreshLogs
        }
    } catch {
        $e.Result = @{
            Ok = $false
            Error = $_.Exception.Message
            ActionName = $payload.ActionName
            RefreshLogs = $false
        }
    }
}

$actionWorker.RunWorkerCompleted += {
    param($sender, $e)
    Set-UiBusy -Busy $false
    if ($e.Error) {
        Append-Output "ERROR: $($e.Error.Exception.Message)"
        return
    }
    $res = $e.Result
    if (-not $res.Ok) {
        Append-Output "ERROR: $($res.Error)"
        return
    }
    if ($res.Output) {
        Append-Output ($res.Output.TrimEnd())
    }
    if ($res.RefreshLogs) {
        Refresh-LogsTab
    }
}

function Run-ActionAsync {
    param(
        [string]$ActionName,
        [bool]$RefreshLogs = $true
    )
    if ($actionWorker.IsBusy) {
        Append-Output "Hay una accion en curso. Espera a que termine."
        return
    }
    try {
        $collected = Collect-Args -ActionName $ActionName
        Append-Output "Running action=$ActionName profile=$($cmbProfile.SelectedItem)"
        Set-UiBusy -Busy $true -Message "Ejecutando '$ActionName'..."
        $actionWorker.RunWorkerAsync(@{
            ActionName = $ActionName
            Workspace = $collected.Workspace
            Args = $collected.Args
            RefreshLogs = $RefreshLogs
        })
    } catch {
        Set-UiBusy -Busy $false
        Append-Output "ERROR: $($_.Exception.Message)"
    }
}

$btnStart.Add_Click({ Run-ActionAsync -ActionName "start" -RefreshLogs $true })
$btnStop.Add_Click({ Run-ActionAsync -ActionName "stop" -RefreshLogs $true })
$btnRestart.Add_Click({ Run-ActionAsync -ActionName "restart" -RefreshLogs $true })
$btnStatus.Add_Click({ Run-ActionAsync -ActionName "status" -RefreshLogs $true })
$btnLogs.Add_Click({ Run-ActionAsync -ActionName "logs" -RefreshLogs $true })
$btnOpenRuntime.Add_Click({
    if (-not (Test-Path $runtimeDir)) {
        New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    }
    Start-Process explorer.exe $runtimeDir
})

Append-Output "Workspace: $workspacePath"
Append-Output "Tip: usa Profile=downlink o uplink para acciones parciales."
Run-ActionAsync -ActionName "status" -RefreshLogs $true

[void]$form.ShowDialog()
