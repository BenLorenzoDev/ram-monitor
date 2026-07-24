# RAM Monitor - simple GUI
# Shows live memory usage + top processes, alerts when usage crosses the threshold,
# logs spikes to ram-spikes.log / usage history to ram-usage.csv, and offers
# actions: end a selected process, restart Explorer, open Task Manager, plus
# live suggestions based on what is actually consuming memory.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -MemberDefinition '[DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr hProcess);' -Name 'Psapi' -Namespace 'Win32'
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class RamHotKey : NativeWindow, IDisposable {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, int mods, int vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    public event EventHandler Pressed;
    public RamHotKey() { CreateHandle(new CreateParams()); }
    public bool Register(int mods, int vk) { return RegisterHotKey(this.Handle, 1, mods, vk); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312) { var h = Pressed; if (h != null) h(this, EventArgs.Empty); }
        base.WndProc(ref m);
    }
    public void Dispose() { UnregisterHotKey(this.Handle, 1); this.DestroyHandle(); }
}
'@
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:LogDir   = Join-Path $env:USERPROFILE 'ram-monitor'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir | Out-Null }
$script:UsageCsv = Join-Path $script:LogDir 'ram-usage.csv'
$script:SpikeLog = Join-Path $script:LogDir 'ram-spikes.log'
if (-not (Test-Path $script:UsageCsv)) {
    'timestamp,usedPercent,usedGB,totalGB' | Out-File $script:UsageCsv -Encoding utf8
}
$script:LastAlert = [datetime]::MinValue
$script:History   = @()   # rolling per-process memory snapshots for spike auto-analysis
$script:GraphHist   = @() # 1-second usage samples for the graph
$script:GraphWinSec = 60  # graph window: 60 / 300 / 600 seconds
$script:LastMem     = $null
$script:LastAutoOpt      = [datetime]::MinValue
$script:AutoOptStrikes   = 0
$script:AutoOptSuspended = $false

# Optimize exceptions: process names the user has protected (ticked in the list)
$script:OptCsv     = Join-Path $script:LogDir 'optimize-history.csv'
$script:ExFile     = Join-Path $script:LogDir 'optimize-exceptions.txt'
$script:Exceptions = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
if (Test-Path $script:ExFile) {
    Get-Content $script:ExFile | Where-Object { $_.Trim() } | ForEach-Object { [void]$script:Exceptions.Add($_.Trim()) }
}
function Save-Exceptions {
    $script:Exceptions | Sort-Object | Out-File $script:ExFile -Encoding utf8
}
$script:RebuildingLv = $false

function Get-MemInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $usedGB  = [math]::Round($totalGB - $freeGB, 1)
    [pscustomobject]@{
        TotalGB = $totalGB
        UsedGB  = $usedGB
        Pct     = [math]::Round(($usedGB / $totalGB) * 100, 1)
    }
}

function Get-TopProcesses {
    Get-Process -ErrorAction SilentlyContinue |
        Group-Object ProcessName | ForEach-Object {
            [pscustomobject]@{
                Name  = $_.Name
                Count = $_.Count
                MemMB = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB, 0)
            }
        } | Sort-Object MemMB -Descending
}

function Write-Snapshot([string]$reason, $mem, $top) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $lines = @("===== $ts | $reason | used $($mem.Pct)% ($($mem.UsedGB) / $($mem.TotalGB) GB) =====")
    $lines += ($top | Select-Object -First 15 | Format-Table -AutoSize | Out-String).TrimEnd()
    $lines += ''
    $lines | Add-Content $script:SpikeLog
}

# Compare current per-process memory against ~5 minutes ago to find what grew
function Get-SpikeAnalysis($mem, $top) {
    if ($script:History.Count -lt 2) { return $null }
    $target = (Get-Date).AddMinutes(-5)
    $ref = $script:History | Where-Object { $_.Time -le $target } | Select-Object -Last 1
    if (-not $ref) { $ref = $script:History[0] }
    $minutes = [math]::Round(((Get-Date) - $ref.Time).TotalMinutes, 1)
    $gainers = foreach ($p in $top) {
        $old = if ($ref.Mem.ContainsKey($p.Name)) { $ref.Mem[$p.Name] } else { 0 }
        $delta = $p.MemMB - $old
        if ($delta -ge 100) {
            [pscustomobject]@{
                Name    = $p.Name
                DeltaMB = $delta
                NowMB   = $p.MemMB
                IsNew   = (-not $ref.Mem.ContainsKey($p.Name))
            }
        }
    }
    $gainers = @($gainers | Sort-Object DeltaMB -Descending | Select-Object -First 5)
    $lines = @("Auto-analysis: RAM $($ref.Pct)% -> $($mem.Pct)% over the last $minutes min.")
    if ($gainers.Count) {
        $lines += 'Biggest growth in that window:'
        foreach ($g in $gainers) {
            $tag = if ($g.IsNew) { ' (started in that window)' } else { '' }
            $lines += ('  {0}: +{1:N0} MB (now {2:N0} MB){3}' -f $g.Name, $g.DeltaMB, $g.NowMB, $tag)
        }
    } else {
        $lines += 'No single process grew much - memory rose gradually across many processes.'
    }
    $topGainer = $null
    if ($gainers.Count) {
        $g0 = $gainers[0]
        $amount = if ($g0.DeltaMB -ge 1024) { "+$([math]::Round($g0.DeltaMB / 1024, 1)) GB" } else { "+$($g0.DeltaMB) MB" }
        $topGainer = "$($g0.Name) $amount"
    }
    [pscustomobject]@{ Lines = $lines; TopGainer = $topGainer }
}

# Per-process advice for the suggestions panel
function Get-Advice($p) {
    $gb = [math]::Round($p.MemMB / 1024, 1)
    switch -Regex ($p.Name) {
        '^(chrome|msedge|firefox|brave|opera|arc)$' {
            "- $($p.Name) ($gb GB, $($p.Count) procs): every tab is its own process. Close unused/heavy tabs (video, Figma, Docs) or restart the browser to reclaim it all."; break }
        '^Discord$' {
            "- Discord ($gb GB): quit it fully (system tray icon > Quit) while working - it idles above 1 GB."; break }
        '^(Code|devenv|idea64|rider64|webstorm64|pycharm64|studio64)$' {
            "- $($p.Name) ($gb GB): IDE memory grows over long sessions - restarting the IDE reclaims it."; break }
        '^(node|esbuild|vite|tsserver|java|dotnet|python)$' {
            "- $($p.Name) ($gb GB, $($p.Count) procs): build/dev-server processes. If it keeps climbing, restart the dev server - long-running watchers leak."; break }
        '^(vmmem|vmmemWSL|Docker Desktop|com\.docker\.backend)$' {
            "- $($p.Name) ($gb GB): Docker/WSL virtual machine. Run 'wsl --shutdown' when done, or cap it in %UserProfile%\.wslconfig (e.g. memory=8GB)."; break }
        '^bdservicehost$' {
            "- Bitdefender ($gb GB): likely a scan in progress - it settles afterwards. Do not end it."; break }
        '^msedgewebview2$' {
            "- WebView2 ($gb GB): embedded browser used by other apps (Wispr Flow, widgets) - closing those apps frees this too."; break }
        '^(Wispr Flow|WisprFlow)$' {
            "- Wispr Flow ($gb GB): restart it if it keeps growing between sessions."; break }
        '^(svchost|dwm|explorer|RuntimeBroker|fontdrvhost)$' { break }
        default {
            if ($gb -ge 1) { "- $($p.Name) ($gb GB): not needed right now? Close it normally, or select it above and click 'End process'." } }
    }
}

function Get-SuggestionText($mem, $top, [int]$threshold) {
    $tips = @()
    foreach ($p in ($top | Select-Object -First 6)) {
        $t = Get-Advice $p
        if ($t) { $tips += $t }
    }
    $lines = @()
    if ($mem.Pct -ge $threshold) {
        $lines += "!! RAM at $($mem.Pct)% - act now:"
        $lines += $tips
        $lines += '- Save your work first, then close the biggest optional app above.'
        $lines += '- Still climbing after closing apps? A reboot clears memory leaks fastest.'
    } else {
        $lines += "RAM at $($mem.Pct)% - biggest consumers and what you could trim:"
        $lines += $tips
    }
    $lines -join "`r`n"
}

# ---------- UI (dark, Task Manager style) ----------
$cBg     = [System.Drawing.Color]::FromArgb(32, 32, 36)
$cCard   = [System.Drawing.Color]::FromArgb(40, 40, 46)
$cText   = [System.Drawing.Color]::FromArgb(235, 235, 240)
$cSub    = [System.Drawing.Color]::FromArgb(165, 165, 175)
$cBorder = [System.Drawing.Color]::FromArgb(70, 70, 80)

function Style-DarkButton($b, [bool]$accent = $false) {
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize  = 1
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(84, 84, 96)
    $b.BackColor = if ($accent) { [System.Drawing.Color]::FromArgb(104, 78, 214) }
                   else         { [System.Drawing.Color]::FromArgb(55, 55, 64) }
    $b.FlatAppearance.MouseOverBackColor =
        if ($accent) { [System.Drawing.Color]::FromArgb(122, 96, 232) }
        else         { [System.Drawing.Color]::FromArgb(70, 70, 80) }
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
}

$form = New-Object System.Windows.Forms.Form
$form.Text            = 'RAM Monitor'
$form.Size            = New-Object System.Drawing.Size(560, 940)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor       = $cBg
$form.ForeColor       = $cText

$lblPct = New-Object System.Windows.Forms.Label
$lblPct.Location  = New-Object System.Drawing.Point(20, 12)
$lblPct.Size      = New-Object System.Drawing.Size(160, 46)
$lblPct.Font      = New-Object System.Drawing.Font('Segoe UI', 26, [System.Drawing.FontStyle]::Bold)
$lblPct.ForeColor = $cText
$lblPct.Text      = '-- %'

$lblDetail = New-Object System.Windows.Forms.Label
$lblDetail.Location  = New-Object System.Drawing.Point(190, 22)
$lblDetail.Size      = New-Object System.Drawing.Size(334, 20)
$lblDetail.Font      = New-Object System.Drawing.Font('Segoe UI', 10)
$lblDetail.ForeColor = $cSub
$lblDetail.Text      = 'reading...'

$lblGraphCap = New-Object System.Windows.Forms.Label
$lblGraphCap.Location  = New-Object System.Drawing.Point(190, 42)
$lblGraphCap.Size      = New-Object System.Drawing.Size(200, 16)
$lblGraphCap.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
$lblGraphCap.ForeColor = $cSub
$lblGraphCap.Text      = 'Memory usage, graph window:'

$cboWin = New-Object System.Windows.Forms.ComboBox
$cboWin.Location      = New-Object System.Drawing.Point(404, 36)
$cboWin.Size          = New-Object System.Drawing.Size(120, 22)
$cboWin.DropDownStyle = 'DropDownList'
$cboWin.FlatStyle     = 'Flat'
$cboWin.BackColor     = $cCard
$cboWin.ForeColor     = $cText
[void]$cboWin.Items.AddRange(@('60 seconds', '5 minutes', '10 minutes'))
$cboWin.SelectedIndex = 0
$cboWin.Add_SelectedIndexChanged({
    $script:GraphWinSec = @(60, 300, 600)[$cboWin.SelectedIndex]
    $pnlGraph.Invalidate()
})

$pnlGraph = New-Object System.Windows.Forms.Panel
$pnlGraph.Location  = New-Object System.Drawing.Point(20, 64)
$pnlGraph.Size      = New-Object System.Drawing.Size(504, 150)
$pnlGraph.BackColor = $cCard

$lblThr = New-Object System.Windows.Forms.Label
$lblThr.Location  = New-Object System.Drawing.Point(20, 230)
$lblThr.Size      = New-Object System.Drawing.Size(52, 20)
$lblThr.ForeColor = $cText
$lblThr.Text      = 'Alert at'

$numThreshold = New-Object System.Windows.Forms.NumericUpDown
$numThreshold.Location  = New-Object System.Drawing.Point(74, 226)
$numThreshold.Size      = New-Object System.Drawing.Size(52, 24)
$numThreshold.Minimum   = 50
$numThreshold.Maximum   = 99
$numThreshold.Value     = 85
$numThreshold.BackColor = $cCard
$numThreshold.ForeColor = $cText

$lblPctSign = New-Object System.Windows.Forms.Label
$lblPctSign.Location  = New-Object System.Drawing.Point(128, 230)
$lblPctSign.Size      = New-Object System.Drawing.Size(18, 20)
$lblPctSign.ForeColor = $cText
$lblPctSign.Text      = '%'

$chkLog = New-Object System.Windows.Forms.CheckBox
$chkLog.Location  = New-Object System.Drawing.Point(152, 228)
$chkLog.Size      = New-Object System.Drawing.Size(150, 22)
$chkLog.ForeColor = $cText
$chkLog.Text      = 'Log usage to CSV'
$chkLog.Checked   = $true

$btnSnapshot = New-Object System.Windows.Forms.Button
$btnSnapshot.Location = New-Object System.Drawing.Point(330, 224)
$btnSnapshot.Size     = New-Object System.Drawing.Size(90, 28)
$btnSnapshot.Text     = 'Snapshot'

$btnOpenLogs = New-Object System.Windows.Forms.Button
$btnOpenLogs.Location = New-Object System.Drawing.Point(426, 224)
$btnOpenLogs.Size     = New-Object System.Drawing.Size(98, 28)
$btnOpenLogs.Text     = 'Open logs'

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Location  = New-Object System.Drawing.Point(20, 258)
$chkAuto.Size      = New-Object System.Drawing.Size(126, 22)
$chkAuto.ForeColor = $cText
$chkAuto.Text      = 'Auto-optimize at'
$chkAuto.Checked   = $false

$numAuto = New-Object System.Windows.Forms.NumericUpDown
$numAuto.Location  = New-Object System.Drawing.Point(148, 256)
$numAuto.Size      = New-Object System.Drawing.Size(52, 24)
$numAuto.Minimum   = 50
$numAuto.Maximum   = 99
$numAuto.Value     = 80
$numAuto.BackColor = $cCard
$numAuto.ForeColor = $cText

$lblAutoPct = New-Object System.Windows.Forms.Label
$lblAutoPct.Location  = New-Object System.Drawing.Point(202, 260)
$lblAutoPct.Size      = New-Object System.Drawing.Size(18, 20)
$lblAutoPct.ForeColor = $cText
$lblAutoPct.Text      = '%'

$lblAutoInfo = New-Object System.Windows.Forms.Label
$lblAutoInfo.Location  = New-Object System.Drawing.Point(226, 260)
$lblAutoInfo.Size      = New-Object System.Drawing.Size(298, 20)
$lblAutoInfo.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
$lblAutoInfo.ForeColor = $cSub
$lblAutoInfo.Text      = '10 min cooldown; suspends itself if it stops helping'

$lv = New-Object System.Windows.Forms.ListView
$lv.Location      = New-Object System.Drawing.Point(20, 296)
$lv.Size          = New-Object System.Drawing.Size(504, 280)
$lv.View          = 'Details'
$lv.FullRowSelect = $true
$lv.GridLines     = $false
$lv.HideSelection = $false
$lv.MultiSelect   = $false
$lv.CheckBoxes    = $true
$lv.BackColor     = $cCard
$lv.ForeColor     = $cText
$lv.BorderStyle   = 'FixedSingle'
[void]$lv.Columns.Add('Process', 264)
[void]$lv.Columns.Add('Instances', 90)
[void]$lv.Columns.Add('Memory (MB)', 128)

# Dark column headers (default headers ignore BackColor)
$lv.OwnerDraw = $true
$lv.Add_DrawColumnHeader({
    param($s, $e)
    $bg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(52, 52, 60))
    $e.Graphics.FillRectangle($bg, $e.Bounds); $bg.Dispose()
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $tb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(200, 200, 210))
    $r = New-Object System.Drawing.RectangleF(($e.Bounds.X + 6), $e.Bounds.Y, ($e.Bounds.Width - 6), $e.Bounds.Height)
    $e.Graphics.DrawString($e.Header.Text, $s.Font, $tb, $r, $fmt)
    $tb.Dispose(); $fmt.Dispose()
})
$lv.Add_DrawItem({ param($s, $e) $e.DrawDefault = $true })
$lv.Add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })

$btnKill = New-Object System.Windows.Forms.Button
$btnKill.Location = New-Object System.Drawing.Point(20, 584)
$btnKill.Size     = New-Object System.Drawing.Size(170, 30)
$btnKill.Text     = 'End selected process'

$btnTaskMgr = New-Object System.Windows.Forms.Button
$btnTaskMgr.Location = New-Object System.Drawing.Point(198, 584)
$btnTaskMgr.Size     = New-Object System.Drawing.Size(150, 30)
$btnTaskMgr.Text     = 'Open Task Manager'

$btnOptimize = New-Object System.Windows.Forms.Button
$btnOptimize.Location = New-Object System.Drawing.Point(356, 584)
$btnOptimize.Size     = New-Object System.Drawing.Size(168, 30)
$btnOptimize.Font     = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnOptimize.Text     = 'Optimize RAM'

Style-DarkButton $btnSnapshot
Style-DarkButton $btnOpenLogs
Style-DarkButton $btnKill
Style-DarkButton $btnTaskMgr
Style-DarkButton $btnOptimize $true

$lblSug = New-Object System.Windows.Forms.Label
$lblSug.Location  = New-Object System.Drawing.Point(20, 624)
$lblSug.Size      = New-Object System.Drawing.Size(250, 18)
$lblSug.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblSug.ForeColor = $cText
$lblSug.Text      = 'Suggested actions'

$txtSuggest = New-Object System.Windows.Forms.TextBox
$txtSuggest.Location    = New-Object System.Drawing.Point(20, 644)
$txtSuggest.Size        = New-Object System.Drawing.Size(504, 105)
$txtSuggest.Multiline   = $true
$txtSuggest.ReadOnly    = $true
$txtSuggest.ScrollBars  = 'Vertical'
$txtSuggest.Font        = New-Object System.Drawing.Font('Segoe UI', 9)
$txtSuggest.BackColor   = $cCard
$txtSuggest.ForeColor   = $cText
$txtSuggest.BorderStyle = 'FixedSingle'

$lblEv = New-Object System.Windows.Forms.Label
$lblEv.Location  = New-Object System.Drawing.Point(20, 757)
$lblEv.Size      = New-Object System.Drawing.Size(250, 18)
$lblEv.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblEv.ForeColor = $cText
$lblEv.Text      = 'Alerts and events'

$txtEvents = New-Object System.Windows.Forms.TextBox
$txtEvents.Location    = New-Object System.Drawing.Point(20, 777)
$txtEvents.Size        = New-Object System.Drawing.Size(504, 82)
$txtEvents.Multiline   = $true
$txtEvents.ReadOnly    = $true
$txtEvents.ScrollBars  = 'Vertical'
$txtEvents.Font        = New-Object System.Drawing.Font('Consolas', 8.25)
$txtEvents.BackColor   = $cCard
$txtEvents.ForeColor   = $cText
$txtEvents.BorderStyle = 'FixedSingle'

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location  = New-Object System.Drawing.Point(20, 865)
$lblStatus.Size      = New-Object System.Drawing.Size(504, 16)
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 150)
$lblStatus.Text      = 'Tick = protected from Optimize  |  Ctrl+Alt+O = optimize anywhere  |  X returns to widget'

$form.Controls.AddRange(@(
    $lblPct, $lblDetail, $lblGraphCap, $cboWin, $pnlGraph,
    $lblThr, $numThreshold, $lblPctSign,
    $chkLog, $btnSnapshot, $btnOpenLogs,
    $chkAuto, $numAuto, $lblAutoPct, $lblAutoInfo, $lv,
    $btnKill, $btnTaskMgr, $btnOptimize,
    $lblSug, $txtSuggest, $lblEv, $txtEvents, $lblStatus
))

# Flicker-free redraws for the big graph
try {
    [System.Windows.Forms.Panel].GetProperty('DoubleBuffered',
        [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($pnlGraph, $true, $null)
} catch {}

# Task Manager style area graph: grid, filled usage curve, alert line
$pnlGraph.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $w = $s.Width; $h = $s.Height
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $gridPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(52, 52, 60), 1)
    foreach ($i in 1..3) { $gy = [int]($h * $i / 4); $g.DrawLine($gridPen, 0, $gy, $w, $gy) }
    foreach ($i in 1..9) { $gx = [int]($w * $i / 10); $g.DrawLine($gridPen, $gx, 0, $gx, $h) }
    $gridPen.Dispose()
    $ty = [int]($h * (1 - [int]$numThreshold.Value / 100))
    $tpen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(170, 220, 90, 90), 1)
    $tpen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
    $g.DrawLine($tpen, 0, $ty, $w, $ty)
    $tpen.Dispose()
    $hist = $script:GraphHist
    $win  = [double]$script:GraphWinSec
    if ($hist.Count -ge 2) {
        $now = Get-Date
        $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        foreach ($entry in $hist) {
            $age = ($now - $entry.Time).TotalSeconds
            if ($age -gt $win) { continue }
            $pts.Add((New-Object System.Drawing.PointF(
                [single]($w * (1 - $age / $win)),
                [single]($h * (1 - $entry.Pct / 100)))))
        }
        if ($pts.Count -ge 2) {
            $poly = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
            $poly.AddRange($pts)
            $poly.Add((New-Object System.Drawing.PointF($pts[$pts.Count - 1].X, $h)))
            $poly.Add((New-Object System.Drawing.PointF($pts[0].X, $h)))
            $fill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(60, 155, 120, 255))
            $g.FillPolygon($fill, $poly.ToArray())
            $fill.Dispose()
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(168, 130, 255), 2)
            $g.DrawLines($pen, $pts.ToArray())
            $pen.Dispose()
        }
    }
    $fnt = New-Object System.Drawing.Font('Segoe UI', 7)
    $lb  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(140, 140, 150))
    $g.DrawString('100%', $fnt, $lb, 4, 2)
    $g.DrawString("Alert $([int]$numThreshold.Value)%", $fnt, $lb, ($w - 62), [single][math]::Max(2, $ty - 15))
    $winLabel = if ($script:GraphWinSec -ge 120) { "$([int]($script:GraphWinSec / 60)) min ago" } else { "$($script:GraphWinSec) sec ago" }
    $g.DrawString($winLabel, $fnt, $lb, 4, ($h - 16))
    $g.DrawString('now', $fnt, $lb, ($w - 32), ($h - 16))
    $lb.Dispose(); $fnt.Dispose()
    $bp = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70, 70, 80), 1)
    $g.DrawRectangle($bp, 0, 0, ($w - 1), ($h - 1))
    $bp.Dispose()
})

# Custom app icon (falls back to the system icon if the .ico is missing)
$script:AppIcon = $null
try {
    $icoPath = Join-Path $script:LogDir 'ram-monitor.ico'
    if (Test-Path $icoPath) { $script:AppIcon = New-Object System.Drawing.Icon($icoPath) }
} catch {}
if ($script:AppIcon) { $form.Icon = $script:AppIcon }

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon    = if ($script:AppIcon) { $script:AppIcon } else { [System.Drawing.SystemIcons]::Information }
$notify.Text    = 'RAM Monitor'
$notify.Visible = $true

function Confirm-Action([string]$msg) {
    [System.Windows.Forms.MessageBox]::Show($msg, 'RAM Monitor',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning) -eq [System.Windows.Forms.DialogResult]::Yes
}

# ---------- refresh logic ----------
# Fast path (every second): memory reading, graph, widget gauges
function Update-Fast {
    try {
        $mem = Get-MemInfo
        $script:LastMem = $mem
        $script:GraphHist += ,@{ Time = Get-Date; Pct = $mem.Pct; UsedGB = $mem.UsedGB }
        $gcut = (Get-Date).AddSeconds(-600)
        $script:GraphHist = @($script:GraphHist | Where-Object { $_.Time -ge $gcut })

        $lblPct.Text    = "$($mem.Pct) %"
        $lblDetail.Text = "$($mem.UsedGB) GB of $($mem.TotalGB) GB in use ($([math]::Round($mem.TotalGB - $mem.UsedGB, 1)) GB free)"

        $wColor =
            if ($mem.Pct -ge $numThreshold.Value) { [System.Drawing.Color]::FromArgb(235, 80, 80) }
            elseif ($mem.Pct -ge 70)              { [System.Drawing.Color]::Orange }
            else                                  { [System.Drawing.Color]::FromArgb(90, 200, 120) }
        $freeGB = [math]::Round($mem.TotalGB - $mem.UsedGB, 1)
        $lblPct.ForeColor   = $wColor
        $lblWPct.Text       = "$([math]::Round($mem.Pct))%"
        $lblWPct.ForeColor  = $wColor
        $lblWGB.Text        = "$($mem.UsedGB) / $($mem.TotalGB) GB"
        $lblWFree.Text      = "$freeGB GB still free"
        $lblWStatus.Text    =
            if ($mem.Pct -ge $numThreshold.Value) { 'CRITICAL' }
            elseif ($mem.Pct -ge 70)              { 'HIGH' }
            else                                  { 'OK' }
        $lblWStatus.ForeColor = $wColor
        $wBarFill.BackColor = $wColor
        $wBarFill.Width     = [int][math]::Max(2, 210 * [math]::Min(100, $mem.Pct) / 100)
        $widget.BackColor   =
            if ($mem.Pct -ge $numThreshold.Value) { [System.Drawing.Color]::FromArgb(70, 25, 25) }
            else                                  { [System.Drawing.Color]::FromArgb(30, 30, 32) }
        $pnlGraph.Invalidate()
        $wSpark.Invalidate()

        # Auto-optimize: hands-free trim with cooldown and self-suspend guard
        if ($chkAuto.Checked -and -not $script:AutoOptSuspended -and
            $mem.Pct -ge [int]$numAuto.Value -and
            ((Get-Date) - $script:LastAutoOpt).TotalMinutes -ge 10) {
            $now = Get-Date
            if (($now - $script:LastAutoOpt).TotalMinutes -le 20) { $script:AutoOptStrikes++ }
            else { $script:AutoOptStrikes = 0 }
            if ($script:AutoOptStrikes -ge 2) {
                # Two trims in a row brought no lasting relief: stop and diagnose
                $script:AutoOptSuspended = $true
                $suspect = ''
                try {
                    $a = Get-SpikeAnalysis $mem (Get-TopProcesses)
                    if ($a -and $a.TopGainer) { $suspect = " Likely leak: $($a.TopGainer)." }
                } catch {}
                $txtEvents.AppendText("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] AUTO-optimize suspended - trims are not lasting.$suspect Restart that app, then re-tick Auto-optimize.`r`n")
                $notify.BalloonTipTitle = 'RAM Monitor'
                $notify.BalloonTipText  = "Auto-optimize suspended - it is not helping.$suspect Restart that app."
                $notify.ShowBalloonTip(10000)
            } else {
                $script:LastAutoOpt = $now
                $txtEvents.AppendText("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] AUTO-optimize triggered at $($mem.Pct)% (limit $([int]$numAuto.Value)%)`r`n")
                Do-Optimize -Auto
            }
        }
        if ($script:AutoOptSuspended -and $mem.Pct -lt ([int]$numAuto.Value - 15)) {
            $script:AutoOptSuspended = $false
            $script:AutoOptStrikes   = 0
            $txtEvents.AppendText("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] AUTO-optimize re-armed (usage back to normal)`r`n")
        }
        $lblAutoInfo.Text =
            if ($script:AutoOptSuspended) { 'SUSPENDED - not helping; restart the leaking app (see events)' }
            else { '10 min cooldown; suspends itself if it stops helping' }
        $lblAutoInfo.ForeColor =
            if ($script:AutoOptSuspended) { [System.Drawing.Color]::Orange }
            else { [System.Drawing.Color]::FromArgb(165, 165, 175) }
    } catch { }
}

# Slow path (every 3 seconds): process list, suggestions, logging, alerts
function Update-Stats {
    try {
        Update-Fast
        $mem = $script:LastMem
        if (-not $mem) { return }
        $top = Get-TopProcesses

        $snap = @{}
        foreach ($p in $top) { $snap[$p.Name] = $p.MemMB }
        $script:History += ,@{ Time = Get-Date; Pct = $mem.Pct; UsedGB = $mem.UsedGB; Mem = $snap }
        $cutoff = (Get-Date).AddMinutes(-10)
        $script:History = @($script:History | Where-Object { $_.Time -ge $cutoff })

        $lblWTop.Text = 'Top: ' + (($top | Select-Object -First 2 | ForEach-Object {
            "$($_.Name) $([math]::Round($_.MemMB / 1024, 1)) GB" }) -join ', ')
        $trendRef = $script:History | Where-Object { $_.Time -le (Get-Date).AddMinutes(-5) } | Select-Object -Last 1
        if (-not $trendRef -and $script:History.Count -gt 1) { $trendRef = $script:History[0] }
        if ($trendRef) {
            $mins = [math]::Max(1, [math]::Round(((Get-Date) - $trendRef.Time).TotalMinutes))
            $dGB  = [math]::Round($mem.UsedGB - $trendRef.UsedGB, 1)
            if ($dGB -ge 0.3) {
                $lblWTrend.Text      = "Rising: +$dGB GB in last $mins min"
                $lblWTrend.ForeColor = [System.Drawing.Color]::Orange
            } elseif ($dGB -le -0.3) {
                $lblWTrend.Text      = "Falling: $dGB GB in last $mins min"
                $lblWTrend.ForeColor = [System.Drawing.Color]::FromArgb(90, 200, 120)
            } else {
                $lblWTrend.Text      = "Stable over last $mins min"
                $lblWTrend.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 155)
            }
        } else {
            $lblWTrend.Text      = 'Trend: gathering data...'
            $lblWTrend.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 155)
        }
        $wSpark.Invalidate()

        $selected = if ($lv.SelectedItems.Count -gt 0) { $lv.SelectedItems[0].Text } else { $null }
        $script:RebuildingLv = $true
        $lv.BeginUpdate()
        $lv.Items.Clear()
        foreach ($p in ($top | Select-Object -First 15)) {
            $item = New-Object System.Windows.Forms.ListViewItem($p.Name)
            [void]$item.SubItems.Add($p.Count.ToString())
            [void]$item.SubItems.Add(('{0:N0}' -f $p.MemMB))
            if ($p.Name -eq $selected) { $item.Selected = $true }
            $item.Checked = $script:Exceptions.Contains($p.Name)
            [void]$lv.Items.Add($item)
        }
        $lv.EndUpdate()
        $script:RebuildingLv = $false

        $sugText = Get-SuggestionText $mem $top ([int]$numThreshold.Value)
        if ($txtSuggest.Text -ne $sugText) { $txtSuggest.Text = $sugText }

        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        if ($chkLog.Checked) {
            "$ts,$($mem.Pct),$($mem.UsedGB),$($mem.TotalGB)" | Add-Content $script:UsageCsv
        }

        if ($mem.Pct -ge $numThreshold.Value -and
            ((Get-Date) - $script:LastAlert).TotalSeconds -ge 120) {
            $script:LastAlert = Get-Date
            $culprits = ($top | Select-Object -First 3 | ForEach-Object {
                "$($_.Name) ($([math]::Round($_.MemMB / 1024, 1)) GB)"
            }) -join ', '
            $txtEvents.AppendText("[$ts] SPIKE $($mem.Pct)% - top: $culprits`r`n")
            Write-Snapshot "ALERT >= $($numThreshold.Value)%" $mem $top
            $tip = "Memory at $($mem.Pct)% - $culprits"
            $analysis = Get-SpikeAnalysis $mem $top
            if ($analysis) {
                foreach ($l in $analysis.Lines) { $txtEvents.AppendText("    $l`r`n") }
                ($analysis.Lines | ForEach-Object { "  $_" }) + '' | Add-Content $script:SpikeLog
                if ($analysis.TopGainer) {
                    $tip = "Memory at $($mem.Pct)% - likely cause: $($analysis.TopGainer)"
                }
            }
            $notify.BalloonTipTitle = 'RAM Alert'
            $notify.BalloonTipText  = $tip
            $notify.ShowBalloonTip(10000)
        }
    } catch { }
}

# ---------- actions ----------
$btnKill.Add_Click({
    if ($lv.SelectedItems.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Select a process in the list first.', 'RAM Monitor')
        return
    }
    $name = $lv.SelectedItems[0].Text
    $protected = @('svchost','csrss','wininit','winlogon','lsass','services','smss',
                   'System','Idle','Registry','MemCompression','Memory Compression',
                   'dwm','fontdrvhost','RuntimeBroker','bdservicehost')
    if ($protected -contains $name) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "'$name' is a Windows/security system process - ending it can crash or expose the system. Leave it alone; it is managed automatically.",
            'RAM Monitor')
        return
    }
    if ($name -eq 'explorer') {
        if (Confirm-Action 'Restart Windows Explorer? Your desktop and taskbar will briefly disappear and come back.') {
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer }
            $txtEvents.AppendText("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] restarted Explorer`r`n")
        }
        return
    }
    $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
    if (-not $procs) { return }
    $mb = [math]::Round(($procs | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
    $note = ''
    if ($name -match '^(claude|powershell|pwsh|WindowsTerminal|cmd)$') {
        $note = " NOTE: this includes your terminal/Claude Code session."
    }
    if (Confirm-Action "End all $($procs.Count) '$name' process(es) (~$mb MB)? Unsaved work in that app will be lost.$note") {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        $txtEvents.AppendText("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ended $name (freed ~$mb MB)`r`n")
        Start-Sleep -Milliseconds 500
        Update-Stats
    }
})

$btnTaskMgr.Add_Click({ Start-Process taskmgr.exe })

function Do-Snapshot {
    $mem = Get-MemInfo
    $top = Get-TopProcesses
    Write-Snapshot 'manual snapshot' $mem $top
    $analysis = Get-SpikeAnalysis $mem $top
    if ($analysis) {
        ($analysis.Lines | ForEach-Object { "  $_" }) + '' | Add-Content $script:SpikeLog
    }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $txtEvents.AppendText("[$ts] snapshot saved at $($mem.Pct)%`r`n")
}
$btnSnapshot.Add_Click({ Do-Snapshot })

# One-click optimize: trim unused memory from every process EXCEPT system
# processes and the user's ticked exceptions. Never closes anything.
function Do-Optimize([switch]$Auto) {
    $memBefore = Get-MemInfo
    $skip = @('System','Idle','Registry','MemCompression','Memory Compression','csrss','wininit',
              'winlogon','smss','lsass','services','audiodg','dwm','fontdrvhost',
              'MsMpEng','SecurityHealthService','bdservicehost','bdagent','bdntwrk')
    $before = [int64]0; $after = [int64]0; $trimmed = 0
    $protectedHit = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($p.Id -eq $PID) { continue }
        if ($skip -contains $p.ProcessName) { continue }
        if ($script:Exceptions.Contains($p.ProcessName)) { [void]$protectedHit.Add($p.ProcessName); continue }
        try {
            $ws = $p.WorkingSet64
            if ([Win32.Psapi]::EmptyWorkingSet($p.Handle)) {
                $p.Refresh()
                $before += $ws
                $after  += $p.WorkingSet64
                $trimmed++
            }
        } catch {}
    }
    $freedMB  = [math]::Max(0, [math]::Round(($before - $after) / 1MB))
    $memAfter = Get-MemInfo
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $trigger  = if ($Auto) { 'auto' } else { 'manual' }
    $protList = ($protectedHit | Sort-Object) -join '; '
    $protMsg  = if ($protectedHit.Count) { " Protected: $protList." } else { '' }
    $tag = if ($Auto) { 'AUTO Optimize' } else { 'Optimize' }
    $txtEvents.AppendText("[$ts] ${tag}: $($memBefore.Pct)% -> $($memAfter.Pct)% | trimmed $trimmed processes, freed ~$freedMB MB.$protMsg`r`n")
    if (-not (Test-Path $script:OptCsv)) {
        'timestamp,freedMB,processesTrimmed,usedPctBefore,usedPctAfter,usedGBBefore,usedGBAfter,protected,trigger' |
            Out-File $script:OptCsv -Encoding utf8
    } elseif ((Get-Content $script:OptCsv -First 1) -notmatch 'trigger') {
        $all = Get-Content $script:OptCsv
        @($all[0] + ',trigger') + @($all | Select-Object -Skip 1 | ForEach-Object { $_ + ',manual' }) |
            Out-File $script:OptCsv -Encoding utf8
    }
    "$ts,$freedMB,$trimmed,$($memBefore.Pct),$($memAfter.Pct),$($memBefore.UsedGB),$($memAfter.UsedGB),$protList,$trigger" |
        Add-Content $script:OptCsv
    $notify.BalloonTipTitle = if ($Auto) { 'RAM Auto-Optimize' } else { 'RAM Optimize' }
    $notify.BalloonTipText  = "RAM $($memBefore.Pct)% -> $($memAfter.Pct)% - freed ~$freedMB MB across $trimmed processes.$protMsg"
    $notify.ShowBalloonTip(8000)
    Update-Stats
}

$btnOptimize.Add_Click({
    $btnOptimize.Enabled = $false
    try { Do-Optimize } finally { $btnOptimize.Enabled = $true }
})

$lv.Add_ItemChecked({
    param($s, $e)
    if ($script:RebuildingLv) { return }
    $name = $e.Item.Text
    if ($e.Item.Checked) { [void]$script:Exceptions.Add($name) } else { [void]$script:Exceptions.Remove($name) }
    Save-Exceptions
})

$btnOpenLogs.Add_Click({ Start-Process $script:LogDir })

# ---------- widget (always-on-top mini view) ----------
$widget = New-Object System.Windows.Forms.Form
$widget.Text            = 'RAM Monitor Widget'
$widget.FormBorderStyle = 'None'
$widget.Size            = New-Object System.Drawing.Size(232, 134)
$widget.StartPosition   = 'Manual'
$widget.TopMost         = $true
$widget.ShowInTaskbar   = $false
$widget.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 32)
$widget.Opacity         = 0.92

$lblWTitle = New-Object System.Windows.Forms.Label
$lblWTitle.Location  = New-Object System.Drawing.Point(10, 6)
$lblWTitle.Size      = New-Object System.Drawing.Size(110, 14)
$lblWTitle.Font      = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
$lblWTitle.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 155)
$lblWTitle.Text      = 'MEMORY (RAM)'

$lblWStatus = New-Object System.Windows.Forms.Label
$lblWStatus.Location  = New-Object System.Drawing.Point(120, 5)
$lblWStatus.Size      = New-Object System.Drawing.Size(102, 16)
$lblWStatus.Font      = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
$lblWStatus.TextAlign = 'MiddleRight'
$lblWStatus.ForeColor = [System.Drawing.Color]::White
$lblWStatus.Text      = '...'

$lblWPct = New-Object System.Windows.Forms.Label
$lblWPct.Location  = New-Object System.Drawing.Point(8, 20)
$lblWPct.Size      = New-Object System.Drawing.Size(80, 32)
$lblWPct.Font      = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
$lblWPct.ForeColor = [System.Drawing.Color]::White
$lblWPct.Text      = '--%'

$lblWGB = New-Object System.Windows.Forms.Label
$lblWGB.Location  = New-Object System.Drawing.Point(92, 24)
$lblWGB.Size      = New-Object System.Drawing.Size(132, 16)
$lblWGB.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
$lblWGB.ForeColor = [System.Drawing.Color]::White
$lblWGB.Text      = '-- / -- GB'

$lblWFree = New-Object System.Windows.Forms.Label
$lblWFree.Location  = New-Object System.Drawing.Point(92, 40)
$lblWFree.Size      = New-Object System.Drawing.Size(132, 14)
$lblWFree.Font      = New-Object System.Drawing.Font('Segoe UI', 7.5)
$lblWFree.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 155)
$lblWFree.Text      = 'reading...'

$wBarBg = New-Object System.Windows.Forms.Panel
$wBarBg.Location  = New-Object System.Drawing.Point(10, 58)
$wBarBg.Size      = New-Object System.Drawing.Size(212, 8)
$wBarBg.BackColor = [System.Drawing.Color]::FromArgb(62, 62, 66)

$wBarFill = New-Object System.Windows.Forms.Panel
$wBarFill.Location  = New-Object System.Drawing.Point(1, 1)
$wBarFill.Size      = New-Object System.Drawing.Size(2, 6)
$wBarFill.BackColor = [System.Drawing.Color]::FromArgb(90, 200, 120)
$wBarBg.Controls.Add($wBarFill)

$wSpark = New-Object System.Windows.Forms.Panel
$wSpark.Location  = New-Object System.Drawing.Point(10, 70)
$wSpark.Size      = New-Object System.Drawing.Size(212, 30)
$wSpark.BackColor = [System.Drawing.Color]::FromArgb(38, 38, 42)

$lblWTop = New-Object System.Windows.Forms.Label
$lblWTop.Location  = New-Object System.Drawing.Point(10, 102)
$lblWTop.Size      = New-Object System.Drawing.Size(174, 13)
$lblWTop.Font      = New-Object System.Drawing.Font('Segoe UI', 7.5)
$lblWTop.ForeColor = [System.Drawing.Color]::Gainsboro
$lblWTop.Text      = 'Top: reading...'

$lblWTrend = New-Object System.Windows.Forms.Label
$lblWTrend.Location  = New-Object System.Drawing.Point(10, 115)
$lblWTrend.Size      = New-Object System.Drawing.Size(174, 14)
$lblWTrend.Font      = New-Object System.Drawing.Font('Segoe UI', 7.5)
$lblWTrend.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 155)
$lblWTrend.Text      = 'Trend: gathering data...'

# One-tap optimize button (lightning bolt), respects the saved exceptions
$btnWOpt = New-Object System.Windows.Forms.Button
$btnWOpt.Location  = New-Object System.Drawing.Point(188, 103)
$btnWOpt.Size      = New-Object System.Drawing.Size(34, 27)
$btnWOpt.FlatStyle = 'Flat'
$btnWOpt.FlatAppearance.BorderSize = 0
$btnWOpt.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(122, 96, 232)
$btnWOpt.BackColor = [System.Drawing.Color]::FromArgb(104, 78, 214)
$btnWOpt.ForeColor = [System.Drawing.Color]::White
$btnWOpt.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnWOpt.Text      = [string][char]0x26A1
$btnWOpt.Cursor    = [System.Windows.Forms.Cursors]::Hand

$widget.Controls.AddRange(@(
    $lblWTitle, $lblWStatus, $lblWPct, $lblWGB, $lblWFree,
    $wBarBg, $wSpark, $lblWTop, $lblWTrend, $btnWOpt
))

$btnWOpt.Add_Click({
    $btnWOpt.Enabled = $false
    $oldText = $btnWOpt.Text
    $btnWOpt.Text = '...'
    $btnWOpt.Refresh()
    try { Do-Optimize } finally { $btnWOpt.Text = $oldText; $btnWOpt.Enabled = $true }
})

# Reduce sparkline flicker on redraw
try {
    [System.Windows.Forms.Panel].GetProperty('DoubleBuffered',
        [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($wSpark, $true, $null)
} catch {}

# 10-minute usage graph; dashed line marks the alert threshold
$wSpark.Add_Paint({
    param($s, $e)
    $hist = $script:History
    if ($hist.Count -lt 2) { return }
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $w = $s.Width; $h = $s.Height
    $ty = [int](($h - 2) * (1 - [int]$numThreshold.Value / 100)) + 1
    $tpen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(150, 200, 80, 80), 1)
    $tpen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
    $g.DrawLine($tpen, 0, $ty, $w, $ty)
    $tpen.Dispose()
    $n = $hist.Count
    $pts = New-Object 'System.Collections.Generic.List[System.Drawing.Point]'
    for ($i = 0; $i -lt $n; $i++) {
        $x = [int](($w - 1) * $i / ($n - 1))
        $y = [int](($h - 2) * (1 - $hist[$i].Pct / 100)) + 1
        $pts.Add((New-Object System.Drawing.Point($x, $y)))
    }
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(110, 170, 235), 2)
    $g.DrawLines($pen, $pts.ToArray())
    $pen.Dispose()
})

$wTip = New-Object System.Windows.Forms.ToolTip
$wTip.SetToolTip($lblWPct,    'Share of physical RAM currently in use')
$wTip.SetToolTip($lblWStatus, 'OK: healthy | HIGH: keep an eye | CRITICAL: close something')
$wTip.SetToolTip($wSpark,     'Usage over the last 10 minutes - dashed line is your alert level')
$wTip.SetToolTip($lblWTop,    'Biggest memory users right now')
$wTip.SetToolTip($lblWTrend,  'How much memory use changed recently')
$wTip.SetToolTip($lblWGB,     'Used / total physical RAM')
$wTip.SetToolTip($lv,          'Tick a process to protect it from Optimize RAM')
$wTip.SetToolTip($btnWOpt,     'Optimize RAM now - trims all apps except your ticked exceptions')
$wTip.SetToolTip($btnOptimize, 'Trim unused memory from all processes except ticked ones. Never closes apps. Hotkey: Ctrl+Alt+O')
$wTip.SetToolTip($chkAuto,     'Hands-free: optimizes automatically when usage crosses this level. 10-minute cooldown; suspends itself if trims stop helping (leak detected).')

# Restore last position (default: top-right corner of the working area)
$script:PosFile = Join-Path $script:LogDir 'widget-position.txt'
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$loc = New-Object System.Drawing.Point(($wa.Right - $widget.Width - 12), ($wa.Top + 12))
if (Test-Path $script:PosFile) {
    try {
        $parts = (Get-Content $script:PosFile -First 1) -split ','
        if ($parts.Count -eq 2) {
            $cand = New-Object System.Drawing.Point([int]$parts[0], [int]$parts[1])
            $onScreen = [System.Windows.Forms.Screen]::AllScreens |
                Where-Object { $_.WorkingArea.Contains($cand) }
            if ($onScreen) { $loc = $cand }
        }
    } catch {}
}
# Clamp fully on-screen (the widget got bigger between versions)
$wa2 = [System.Windows.Forms.Screen]::FromPoint($loc).WorkingArea
$loc = New-Object System.Drawing.Point(
    ([math]::Min([math]::Max($loc.X, $wa2.Left), $wa2.Right - $widget.Width)),
    ([math]::Min([math]::Max($loc.Y, $wa2.Top),  $wa2.Bottom - $widget.Height)))
$widget.Location = $loc

# Drag to move (no title bar), remember position, hover = fully opaque
$script:Drag = $null
$dragDown = {
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:Drag = @{ Cursor = [System.Windows.Forms.Cursor]::Position; Form = $widget.Location }
    }
}
$dragMove = {
    if ($script:Drag) {
        $cur = [System.Windows.Forms.Cursor]::Position
        $widget.Location = New-Object System.Drawing.Point(
            ($script:Drag.Form.X + $cur.X - $script:Drag.Cursor.X),
            ($script:Drag.Form.Y + $cur.Y - $script:Drag.Cursor.Y))
    }
}
$dragUp = {
    if ($script:Drag) {
        $script:Drag = $null
        "$($widget.Location.X),$($widget.Location.Y)" | Out-File $script:PosFile
    }
}
$openFull   = { $form.Show(); $form.Activate() }
$hoverEnter = { $widget.Opacity = 1.0 }
$hoverLeave = {
    $p = $widget.PointToClient([System.Windows.Forms.Cursor]::Position)
    if (-not $widget.ClientRectangle.Contains($p)) { $widget.Opacity = 0.92 }
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Open full monitor')
[void]$menu.Items.Add('Optimize RAM now')
[void]$menu.Items.Add('Snapshot now')
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add('Exit RAM Monitor')
$menu.Items[0].Add_Click($openFull)
$menu.Items[1].Add_Click({ Do-Optimize })
$menu.Items[2].Add_Click({ Do-Snapshot })
$menu.Items[4].Add_Click({ $widget.Close() })

foreach ($c in @($widget, $lblWTitle, $lblWStatus, $lblWPct, $lblWGB, $lblWFree,
                 $wBarBg, $wBarFill, $wSpark, $lblWTop, $lblWTrend)) {
    $c.Add_MouseDown($dragDown)
    $c.Add_MouseMove($dragMove)
    $c.Add_MouseUp($dragUp)
    $c.Add_MouseDoubleClick($openFull)
    $c.Add_MouseEnter($hoverEnter)
    $c.Add_MouseLeave($hoverLeave)
    $c.ContextMenuStrip = $menu
}

# Closing the full window hides it back to the widget instead of exiting
$form.Add_FormClosing({
    param($s, $e)
    if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        $s.Hide()
    }
})

$notify.Add_MouseDoubleClick($openFull)

if ($script:AppIcon) { $widget.Icon = $script:AppIcon }

# ---------- persisted settings (thresholds + auto-optimize) ----------
$script:SetFile = Join-Path $script:LogDir 'settings.txt'
function Save-Settings {
    @(
        "alertPct=$([int]$numThreshold.Value)",
        "autoEnabled=$(if ($chkAuto.Checked) { 1 } else { 0 })",
        "autoPct=$([int]$numAuto.Value)"
    ) | Out-File $script:SetFile -Encoding utf8
}
if (Test-Path $script:SetFile) {
    try {
        $kv = @{}
        Get-Content $script:SetFile | ForEach-Object {
            $pair = $_ -split '=', 2
            if ($pair.Count -eq 2) { $kv[$pair[0].Trim()] = $pair[1].Trim() }
        }
        if ($kv['alertPct']) { $numThreshold.Value = [math]::Min(99, [math]::Max(50, [int]$kv['alertPct'])) }
        if ($kv['autoPct'])  { $numAuto.Value      = [math]::Min(99, [math]::Max(50, [int]$kv['autoPct'])) }
        $chkAuto.Checked = ($kv['autoEnabled'] -eq '1')
    } catch {}
}
$numThreshold.Add_ValueChanged({ Save-Settings })
$numAuto.Add_ValueChanged({ Save-Settings })
$chkAuto.Add_CheckedChanged({
    $script:AutoOptSuspended = $false
    $script:AutoOptStrikes   = 0
    Save-Settings
})

# ---------- global hotkey: Ctrl+Alt+O = optimize now ----------
$script:HotKey = $null
try {
    $script:HotKey = New-Object RamHotKey
    if ($script:HotKey.Register(0x0003, 0x4F)) {
        $script:HotKey.add_Pressed({ Do-Optimize })
    }
} catch {}

# Preload recent optimize history (from any earlier session) into the events box
if (Test-Path $script:OptCsv) {
    Get-Content $script:OptCsv | Select-Object -Skip 1 | Select-Object -Last 5 | ForEach-Object {
        $c = $_ -split ','
        if ($c.Count -ge 5) {
            $txtEvents.AppendText("[$($c[0])] earlier Optimize: $($c[3])% -> $($c[4])%, freed ~$($c[1]) MB across $($c[2]) processes`r`n")
        }
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$script:TickCount = 0
$timer.Add_Tick({
    $script:TickCount++
    if ($script:TickCount % 3 -eq 0) { Update-Stats } else { Update-Fast }
})

$widget.Add_Shown({ Update-Stats; $timer.Start() })
$widget.Add_FormClosed({
    $timer.Stop()
    if ($script:HotKey) { try { $script:HotKey.Dispose() } catch {} }
    $notify.Visible = $false
    $notify.Dispose()
    if (-not $form.IsDisposed) { $form.Dispose() }
})

# Widget is the app host: closing it (right-click > Exit) ends monitoring
[void]$widget.ShowDialog()
