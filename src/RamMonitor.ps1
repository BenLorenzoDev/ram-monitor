# RAM Monitor - simple GUI
# Shows live memory usage + top processes, alerts when usage crosses the threshold,
# logs spikes to ram-spikes.log / usage history to ram-usage.csv, and offers
# actions: end a selected process, restart Explorer, open Task Manager, plus
# live suggestions based on what is actually consuming memory.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -MemberDefinition '[DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr hProcess); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow); [DllImport("shell32.dll", SetLastError = true)] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);' -Name 'Psapi' -Namespace 'Win32'
# Own taskbar identity: our windows get the app icon instead of PowerShell's
try { [void][Win32.Psapi]::SetCurrentProcessExplicitAppUserModelID('BenLorenzoDev.RamMonitor') } catch {}
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
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MemApi {
    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORYSTATUSEX {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);
    public static MEMORYSTATUSEX Get() {
        MEMORYSTATUSEX m = new MEMORYSTATUSEX();
        m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        GlobalMemoryStatusEx(ref m);
        return m;
    }
}
'@
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GlassApi {
    [StructLayout(LayoutKind.Sequential)]
    struct AccentPolicy { public int AccentState; public int AccentFlags; public uint GradientColor; public int AnimationId; }
    [StructLayout(LayoutKind.Sequential)]
    struct WinCompAttrData { public int Attribute; public IntPtr Data; public int SizeOfData; }
    [DllImport("user32.dll")]
    static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref WinCompAttrData data);
    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    // state: 0 = off, 1 = solid tint, 3 = blur-behind, 4 = acrylic. tint is AABBGGRR.
    public static void SetAccent(IntPtr hwnd, int state, uint tint) {
        AccentPolicy ap = new AccentPolicy();
        ap.AccentState = state; ap.AccentFlags = 2; ap.GradientColor = tint; ap.AnimationId = 0;
        int size = Marshal.SizeOf(ap);
        IntPtr p = Marshal.AllocHGlobal(size);
        Marshal.StructureToPtr(ap, p, false);
        WinCompAttrData d = new WinCompAttrData();
        d.Attribute = 19; d.Data = p; d.SizeOfData = size;   // WCA_ACCENT_POLICY
        SetWindowCompositionAttribute(hwnd, ref d);
        Marshal.FreeHGlobal(p);
    }
    public static void RoundCorners(IntPtr hwnd) { int v = 2; DwmSetWindowAttribute(hwnd, 33, ref v, 4); }
    public static void DarkTitleBar(IntPtr hwnd) { int v = 1; DwmSetWindowAttribute(hwnd, 20, ref v, 4); }
}
'@
[System.Windows.Forms.Application]::EnableVisualStyles()

# Glassmorphism: real acrylic blur-behind from the desktop compositor (same
# effect Task Manager / Terminal use). All calls are try/catch no-ops on
# systems without the API, leaving the plain dark theme.
# PS 5.1 parses 8-digit hex literals as negative Int32, so [uint32]0xB2281E1E
# throws - parse from a hex string instead.
function HexTint([string]$hex) { [uint32]::Parse($hex, [System.Globalization.NumberStyles]::HexNumber) }
$script:GlassNormal = HexTint 'B2281E1E'   # ~70% dark tint over the blur (AABBGGRR)
$script:GlassHover  = HexTint 'D2281E1E'   # a touch more solid under the cursor
$script:GlassSolid  = HexTint 'FF2C2426'   # fully opaque - used while dragging (blur-while-drag lags)
function Set-Glass([System.Windows.Forms.Form]$f, [int]$state, [uint32]$tint) {
    try { [GlassApi]::SetAccent($f.Handle, $state, $tint) } catch {}
}

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
# Cached copies of the threshold fields. Timers/paints read these instead of
# the controls - reading NumericUpDown.Value force-validates half-typed text.
$script:AlertPct = 85
$script:AutoPct  = 80
$script:LastAutoOpt      = [datetime]::MinValue
$script:AutoOptStrikes   = 0
$script:AutoOptSuspended = $false
$script:OptGlowLevel     = 0   # 0 = calm, 1 = high (orange pulse), 2 = critical (red pulse)
$script:GlowPhase        = 0.0
$script:Optimizing       = $false

# Optimize exceptions: process names the user has protected (ticked in the list)
$script:OptCsv     = Join-Path $script:LogDir 'optimize-history.csv'
$script:OptDetCsv  = Join-Path $script:LogDir 'optimize-details.csv'
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
    # GlobalMemoryStatusEx is microseconds vs tens of ms for WMI - keeps the UI thread free
    $m = [MemApi]::Get()
    $usedBytes = $m.ullTotalPhys - $m.ullAvailPhys
    [pscustomobject]@{
        TotalGB = [math]::Round($m.ullTotalPhys / 1GB, 1)
        UsedGB  = [math]::Round($usedBytes / 1GB, 1)
        Pct     = [math]::Round(($usedBytes / $m.ullTotalPhys) * 100, 1)
    }
}

# Human-friendly size: switches to GB once the amount crosses 1 GB
function Format-MB([double]$mb) {
    if ($mb -ge 1024) { '{0:N1} GB' -f ($mb / 1024) } else { '{0:N0} MB' -f $mb }
}

function Get-TopProcesses {
    # Hashtable aggregation - much faster than Group-Object on ~200+ processes
    $agg = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        $n = $p.ProcessName
        $e = $agg[$n]
        if ($e) { $e.Count++; $e.Mem += $p.WorkingSet64 }
        else    { $agg[$n] = @{ Count = 1; Mem = $p.WorkingSet64 } }
    }
    $rows = foreach ($k in $agg.Keys) {
        [pscustomobject]@{
            Name  = $k
            Count = $agg[$k].Count
            MemMB = [math]::Round($agg[$k].Mem / 1MB, 0)
        }
    }
    $rows | Sort-Object MemMB -Descending
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
            $lines += ('  {0}: +{1} (now {2}){3}' -f $g.Name, (Format-MB $g.DeltaMB), (Format-MB $g.NowMB), $tag)
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
# ---------- style system ----------
# Every UI style is a complete palette here. The picker (monitor dropdown or
# widget right-click > Style) calls Apply-Theme, which reassigns the live
# palette vars below and restyles every control. Add a new style = add an
# entry to this table, nothing else.
function C([int]$r, [int]$g, [int]$b, [int]$a = 255) { [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }
$script:Themes = [ordered]@{
    'Midnight Glass' = @{
        Bg = C 32 32 36;      Card = C 40 40 46;    Text = C 235 235 240
        Sub = C 165 165 175;  Border = C 70 70 80
        HeadBg = C 52 52 60;  HeadText = C 200 200 210
        BtnBg = C 55 55 64;   BtnHover = C 70 70 80; BtnBorder = C 84 84 96
        Accent = C 104 78 214; AccentHover = C 122 96 232
        GraphGrid = C 52 52 60; GraphLine = C 168 130 255; GraphFill = C 155 120 255 60
        Axis = C 140 140 150; Status = C 140 140 150
        WidgetBg = C 30 30 32; WidgetSub = C 150 150 155
        BarBg = C 62 62 66;   SparkBg = C 38 38 42;  SparkLine = C 110 170 235
        GlassState = 4
        GlassNormal = HexTint 'B2281E1E'; GlassHover = HexTint 'D2281E1E'; GlassSolid = HexTint 'FF2C2426'
    }
}
$script:StyleName = 'Midnight Glass'

# Live palette. Paint handlers read these at draw time, so a theme switch only
# needs to reassign them; per-control properties are re-set by Apply-Theme.
$t0 = $script:Themes[$script:StyleName]
$cBg = $t0.Bg; $cCard = $t0.Card; $cText = $t0.Text; $cSub = $t0.Sub; $cBorder = $t0.Border
$cHeadBg = $t0.HeadBg; $cHeadText = $t0.HeadText
$cBtnBg = $t0.BtnBg; $cBtnHover = $t0.BtnHover; $cBtnBorder = $t0.BtnBorder
$cAccent = $t0.Accent; $cAccentHover = $t0.AccentHover
$cGraphGrid = $t0.GraphGrid; $cGraphLine = $t0.GraphLine; $cGraphFill = $t0.GraphFill
$cAxis = $t0.Axis; $cStatus = $t0.Status
$cWidgetBg = $t0.WidgetBg; $cWidgetSub = $t0.WidgetSub
$cBarBg = $t0.BarBg; $cSparkBg = $t0.SparkBg; $cSparkLine = $t0.SparkLine
$script:GlassState = $t0.GlassState

function Style-DarkButton($b, [bool]$accent = $false) {
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize  = 1
    $b.FlatAppearance.BorderColor = $cBtnBorder
    $b.BackColor = if ($accent) { $cAccent } else { $cBtnBg }
    $b.FlatAppearance.MouseOverBackColor = if ($accent) { $cAccentHover } else { $cBtnHover }
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
}

$form = New-Object System.Windows.Forms.Form
$form.Text            = 'RAM Monitor'
$form.Size            = New-Object System.Drawing.Size(1000, 700)
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
$lv.Size          = New-Object System.Drawing.Size(504, 292)
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
    $bg = New-Object System.Drawing.SolidBrush($cHeadBg)
    $e.Graphics.FillRectangle($bg, $e.Bounds); $bg.Dispose()
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $tb = New-Object System.Drawing.SolidBrush($cHeadText)
    $r = New-Object System.Drawing.RectangleF(($e.Bounds.X + 6), $e.Bounds.Y, ($e.Bounds.Width - 6), $e.Bounds.Height)
    $e.Graphics.DrawString($e.Header.Text, $s.Font, $tb, $r, $fmt)
    $tb.Dispose(); $fmt.Dispose()
})
$lv.Add_DrawItem({ param($s, $e) $e.DrawDefault = $true })
$lv.Add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })

$btnKill = New-Object System.Windows.Forms.Button
$btnKill.Location = New-Object System.Drawing.Point(20, 596)
$btnKill.Size     = New-Object System.Drawing.Size(170, 30)
$btnKill.Text     = 'End selected process'

$btnTaskMgr = New-Object System.Windows.Forms.Button
$btnTaskMgr.Location = New-Object System.Drawing.Point(198, 596)
$btnTaskMgr.Size     = New-Object System.Drawing.Size(150, 30)
$btnTaskMgr.Text     = 'Open Task Manager'

$btnOptimize = New-Object System.Windows.Forms.Button
$btnOptimize.Location = New-Object System.Drawing.Point(356, 596)
$btnOptimize.Size     = New-Object System.Drawing.Size(168, 30)
$btnOptimize.Font     = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnOptimize.Text     = 'Optimize RAM'

Style-DarkButton $btnSnapshot
Style-DarkButton $btnOpenLogs
Style-DarkButton $btnKill
Style-DarkButton $btnTaskMgr
Style-DarkButton $btnOptimize $true

$lblSug = New-Object System.Windows.Forms.Label
$lblSug.Location  = New-Object System.Drawing.Point(544, 12)
$lblSug.Size      = New-Object System.Drawing.Size(250, 18)
$lblSug.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblSug.ForeColor = $cText
$lblSug.Text      = 'Suggested actions'

$txtSuggest = New-Object System.Windows.Forms.TextBox
$txtSuggest.Location    = New-Object System.Drawing.Point(544, 32)
$txtSuggest.Size        = New-Object System.Drawing.Size(420, 170)
$txtSuggest.Multiline   = $true
$txtSuggest.ReadOnly    = $true
$txtSuggest.ScrollBars  = 'Vertical'
$txtSuggest.Font        = New-Object System.Drawing.Font('Segoe UI', 9)
$txtSuggest.BackColor   = $cCard
$txtSuggest.ForeColor   = $cText
$txtSuggest.BorderStyle = 'FixedSingle'

$lblEv = New-Object System.Windows.Forms.Label
$lblEv.Location  = New-Object System.Drawing.Point(544, 214)
$lblEv.Size      = New-Object System.Drawing.Size(250, 18)
$lblEv.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblEv.ForeColor = $cText
$lblEv.Text      = 'Alerts and events'

$txtEvents = New-Object System.Windows.Forms.TextBox
$txtEvents.Location    = New-Object System.Drawing.Point(544, 234)
$txtEvents.Size        = New-Object System.Drawing.Size(420, 392)
$txtEvents.Multiline   = $true
$txtEvents.ReadOnly    = $true
$txtEvents.ScrollBars  = 'Vertical'
$txtEvents.Font        = New-Object System.Drawing.Font('Consolas', 8.25)
$txtEvents.BackColor   = $cCard
$txtEvents.ForeColor   = $cText
$txtEvents.BorderStyle = 'FixedSingle'

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location  = New-Object System.Drawing.Point(20, 636)
$lblStatus.Size      = New-Object System.Drawing.Size(944, 16)
$lblStatus.ForeColor = $cStatus
$lblStatus.Text      = 'Tick = protected from Optimize  |  Ctrl+Alt+O = optimize anywhere  |  X returns to widget'

# UI style picker (top-right corner); the widget's right-click menu has the same list
$lblStyle = New-Object System.Windows.Forms.Label
$lblStyle.Location  = New-Object System.Drawing.Point(800, 14)
$lblStyle.Size      = New-Object System.Drawing.Size(40, 18)
$lblStyle.ForeColor = $cSub
$lblStyle.Text      = 'Style'
$cboStyle = New-Object System.Windows.Forms.ComboBox
$cboStyle.Location      = New-Object System.Drawing.Point(842, 10)
$cboStyle.Size          = New-Object System.Drawing.Size(122, 22)
$cboStyle.DropDownStyle = 'DropDownList'
$cboStyle.FlatStyle     = 'Flat'
$cboStyle.BackColor     = $cCard
$cboStyle.ForeColor     = $cText
[void]$cboStyle.Items.AddRange(@($script:Themes.Keys))
$cboStyle.Add_SelectedIndexChanged({
    if (-not $script:SettingStyle -and $cboStyle.SelectedItem) { Apply-Theme ([string]$cboStyle.SelectedItem) }
})

$form.Controls.AddRange(@(
    $lblPct, $lblDetail, $lblGraphCap, $cboWin, $pnlGraph,
    $lblThr, $numThreshold, $lblPctSign,
    $chkLog, $btnSnapshot, $btnOpenLogs,
    $chkAuto, $numAuto, $lblAutoPct, $lblAutoInfo, $lv,
    $btnKill, $btnTaskMgr, $btnOptimize,
    $lblSug, $txtSuggest, $lblEv, $txtEvents, $lblStatus,
    $lblStyle, $cboStyle
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
    $gridPen = New-Object System.Drawing.Pen($cGraphGrid, 1)
    foreach ($i in 1..3) { $gy = [int]($h * $i / 4); $g.DrawLine($gridPen, 0, $gy, $w, $gy) }
    foreach ($i in 1..9) { $gx = [int]($w * $i / 10); $g.DrawLine($gridPen, $gx, 0, $gx, $h) }
    $gridPen.Dispose()
    $ty = [int]($h * (1 - [int]$script:AlertPct / 100))
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
            $fill = New-Object System.Drawing.SolidBrush($cGraphFill)
            $g.FillPolygon($fill, $poly.ToArray())
            $fill.Dispose()
            $pen = New-Object System.Drawing.Pen($cGraphLine, 2)
            $g.DrawLines($pen, $pts.ToArray())
            $pen.Dispose()
        }
    }
    $fnt = New-Object System.Drawing.Font('Segoe UI', 7)
    $lb  = New-Object System.Drawing.SolidBrush($cAxis)
    $g.DrawString('100%', $fnt, $lb, 4, 2)
    $g.DrawString("Alert $([int]$script:AlertPct)%", $fnt, $lb, ($w - 62), [single][math]::Max(2, $ty - 15))
    $winLabel = if ($script:GraphWinSec -ge 120) { "$([int]($script:GraphWinSec / 60)) min ago" } else { "$($script:GraphWinSec) sec ago" }
    $g.DrawString($winLabel, $fnt, $lb, 4, ($h - 16))
    $g.DrawString('now', $fnt, $lb, ($w - 32), ($h - 16))
    $lb.Dispose(); $fnt.Dispose()
    $bp = New-Object System.Drawing.Pen($cBorder, 1)
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
        if ($script:GraphHist.Count -gt 650) {
            $script:GraphHist = $script:GraphHist[($script:GraphHist.Count - 600)..($script:GraphHist.Count - 1)]
        }

        $lblPct.Text    = "$($mem.Pct) %"
        $lblDetail.Text = "$($mem.UsedGB) GB of $($mem.TotalGB) GB in use ($([math]::Round($mem.TotalGB - $mem.UsedGB, 1)) GB free)"

        $wColor =
            if ($mem.Pct -ge $script:AlertPct) { [System.Drawing.Color]::FromArgb(235, 80, 80) }
            elseif ($mem.Pct -ge 70)              { [System.Drawing.Color]::Orange }
            else                                  { [System.Drawing.Color]::FromArgb(90, 200, 120) }
        $freeGB = [math]::Round($mem.TotalGB - $mem.UsedGB, 1)
        $lblPct.ForeColor   = $wColor
        $lblWPct.Text       = "$([math]::Round($mem.Pct))%"
        $lblWPct.ForeColor  = $wColor
        $lblWGB.Text        = "$($mem.UsedGB) / $($mem.TotalGB) GB"
        $lblWFree.Text      = "$freeGB GB still free"
        $lblWStatus.Text    =
            if ($mem.Pct -ge $script:AlertPct) { 'CRITICAL' }
            elseif ($mem.Pct -ge 70)              { 'HIGH' }
            else                                  { 'OK' }
        $lblWStatus.ForeColor = $wColor
        $wBarFill.BackColor = $wColor
        $wBarFill.Width     = [int][math]::Max(2, 228 * [math]::Min(100, $mem.Pct) / 100)
        $widget.BackColor   =
            if ($mem.Pct -ge $script:AlertPct) { [System.Drawing.Color]::FromArgb(70, 25, 25) }
            else                                  { $cWidgetBg }
        $script:OptGlowLevel =
            if ($mem.Pct -ge $script:AlertPct) { 2 }
            elseif ($mem.Pct -ge 70)              { 1 }
            else                                  { 0 }
        $pnlGraph.Invalidate()
        $wSpark.Invalidate()

        # Auto-optimize: hands-free trim with cooldown and self-suspend guard
        if ($chkAuto.Checked -and -not $script:AutoOptSuspended -and
            $mem.Pct -ge [int]$script:AutoPct -and
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
                $txtEvents.AppendText("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] AUTO-optimize triggered at $($mem.Pct)% (limit $([int]$script:AutoPct)%)`r`n")
                Do-Optimize -Auto
            }
        }
        if ($script:AutoOptSuspended -and $mem.Pct -lt ([int]$script:AutoPct - 15)) {
            $script:AutoOptSuspended = $false
            $script:AutoOptStrikes   = 0
            $txtEvents.AppendText("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] AUTO-optimize re-armed (usage back to normal)`r`n")
        }
        $lblAutoInfo.Text =
            if ($script:AutoOptSuspended) { 'SUSPENDED - not helping; restart the leaking app (see events)' }
            else { '10 min cooldown; suspends itself if it stops helping' }
        $lblAutoInfo.ForeColor =
            if ($script:AutoOptSuspended) { [System.Drawing.Color]::Orange }
            else { $cSub }
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
                $lblWTrend.ForeColor = $cWidgetSub
            }
        } else {
            $lblWTrend.Text      = 'Trend: gathering data...'
            $lblWTrend.ForeColor = $cWidgetSub
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

        $sugText = Get-SuggestionText $mem $top ([int]$script:AlertPct)
        if ($txtSuggest.Text -ne $sugText) { $txtSuggest.Text = $sugText }

        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        if ($chkLog.Checked) {
            "$ts,$($mem.Pct),$($mem.UsedGB),$($mem.TotalGB)" | Add-Content $script:UsageCsv
        }

        if ($mem.Pct -ge $script:AlertPct -and
            ((Get-Date) - $script:LastAlert).TotalSeconds -ge 120) {
            $script:LastAlert = Get-Date
            $culprits = ($top | Select-Object -First 3 | ForEach-Object {
                "$($_.Name) ($([math]::Round($_.MemMB / 1024, 1)) GB)"
            }) -join ', '
            $txtEvents.AppendText("[$ts] SPIKE $($mem.Pct)% - top: $culprits`r`n")
            Write-Snapshot "ALERT >= $($script:AlertPct)%" $mem $top
            $tip = "Memory at $($mem.Pct)% - $culprits"
            $analysis = Get-SpikeAnalysis $mem $top
            if ($analysis) {
                foreach ($l in $analysis.Lines) { $txtEvents.AppendText("    $l`r`n") }
                ($analysis.Lines | ForEach-Object { "  $_" }) + '' | Add-Content $script:SpikeLog
                if ($analysis.TopGainer) {
                    $tip = "Memory at $($mem.Pct)% - likely cause: $($analysis.TopGainer)"
                }
            }
            $txtEvents.AppendText("`r`n")
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
        $note = " NOTE: this includes your terminal/CLI session."
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

# Click FX: the bolt gets "struck by its own lightning" - shake + white/gold strobe
function Start-OptimizeJolt([System.Windows.Forms.Button]$b) {
    try {
        $orig     = $b.Location
        $origBack = $b.BackColor
        $rnd = New-Object System.Random
        for ($i = 0; $i -lt 8; $i++) {
            $b.Location  = New-Object System.Drawing.Point(($orig.X + $rnd.Next(-2, 3)), ($orig.Y + $rnd.Next(-2, 3)))
            $b.BackColor = if ($i % 2) { [System.Drawing.Color]::FromArgb(255, 240, 140) } else { [System.Drawing.Color]::White }
            $b.ForeColor = if ($i % 2) { [System.Drawing.Color]::FromArgb(90, 60, 220) } else { [System.Drawing.Color]::FromArgb(255, 170, 0) }
            $b.Refresh()
            Start-Sleep -Milliseconds 30
        }
        $b.Location  = $orig
        $b.BackColor = $origBack
        $b.ForeColor = [System.Drawing.Color]::White
        $b.Refresh()
    } catch {}
}

# Result FX: the full launch program. When an optimize starts, a rocket appears
# on its pad next to the bolt - engine sputtering, smoke billowing, airframe
# rumbling - for as long as the trim is running. The moment the result is in,
# THAT same rocket lifts off, climbs, and bursts into a firework with the freed
# amount revealed inside the explosion. Everything is drawn GDI+ inside ONE
# fixed transparency-keyed window (no form movement), so it stays smooth even
# when the system is under pressure.
# Phases: 0 = prep on the pad, 1 = launch, 2 = boom.
function New-RocketFx {
    $t = New-Object System.Windows.Forms.Form
    $t.FormBorderStyle = 'None'
    $t.ShowInTaskbar   = $false
    $t.StartPosition   = 'Manual'
    $t.TopMost         = $true
    $t.ClientSize      = New-Object System.Drawing.Size(240, 300)
    $key = [System.Drawing.Color]::FromArgb(1, 2, 3)   # never drawn, so it becomes see-through
    $t.BackColor       = $key
    $t.TransparencyKey = $key
    try {
        [System.Windows.Forms.Form].GetProperty('DoubleBuffered',
            [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($t, $true, $null)
    } catch {}
    $st = @{
        Form = $t; Rnd = (New-Object System.Random); Timer = $null
        Phase = 0; PhaseFrame = 0; LaunchFrames = 45
        StartY = 258.0; ApexY = 70.0; RocketY = 258.0; RocketX = 120.0
        Puffs = @(); Parts = @(); Text = ''; Color = [System.Drawing.Color]::White
    }
    $t.Tag = $st
    $t.Add_Paint({
        param($s, $e)
        try {
            $st = $s.Tag
            $g  = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            foreach ($p in $st.Puffs) {               # smoke: pad billow + flight trail
                $a = [int](110 * ($p.Life / [double]$p.MaxLife))
                if ($a -gt 0) {
                    $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($a, 200, 200, 210))
                    $g.FillEllipse($br, [single]($p.X - $p.R), [single]($p.Y - $p.R), [single]($p.R * 2), [single]($p.R * 2))
                    $br.Dispose()
                }
            }
            if ($st.Phase -lt 2) {
                $pb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(95, 95, 108))
                $g.FillRectangle($pb, 104, 286, 32, 4)   # launch pad platform
                $g.FillRectangle($pb, 108, 290, 4, 8)
                $g.FillRectangle($pb, 128, 290, 4, 8)
                $pb.Dispose()
                $cx = [int]$st.RocketX
                $y  = [int]$st.RocketY
                # Flame: sputtering ignition on the pad, full burn once flying
                $fl = if ($st.Phase -eq 0) {
                          if ($st.Rnd.NextDouble() -lt 0.25) { 0 } else { 3 + $st.Rnd.Next(0, 7) }
                      } else { 10 + $st.Rnd.Next(0, 9) }
                if ($fl -gt 0) {
                    $fc = if ($st.PhaseFrame % 2) { [System.Drawing.Color]::FromArgb(255, 200, 60) }
                          else                    { [System.Drawing.Color]::FromArgb(255, 120, 30) }
                    $fb = New-Object System.Drawing.SolidBrush($fc)
                    $g.FillPolygon($fb, [System.Drawing.Point[]]@(
                        (New-Object System.Drawing.Point(($cx - 4), ($y + 24))),
                        (New-Object System.Drawing.Point(($cx + 4), ($y + 24))),
                        (New-Object System.Drawing.Point($cx, ($y + 24 + $fl)))))
                    $fb.Dispose()
                }
                $vb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(140, 110, 240))
                $g.FillPolygon($vb, [System.Drawing.Point[]]@(   # nose cone
                    (New-Object System.Drawing.Point(($cx - 6), $y)),
                    (New-Object System.Drawing.Point(($cx + 6), $y)),
                    (New-Object System.Drawing.Point($cx, ($y - 12)))))
                $g.FillPolygon($vb, [System.Drawing.Point[]]@(   # left fin
                    (New-Object System.Drawing.Point(($cx - 6), ($y + 14))),
                    (New-Object System.Drawing.Point(($cx - 6), ($y + 24))),
                    (New-Object System.Drawing.Point(($cx - 12), ($y + 26)))))
                $g.FillPolygon($vb, [System.Drawing.Point[]]@(   # right fin
                    (New-Object System.Drawing.Point(($cx + 6), ($y + 14))),
                    (New-Object System.Drawing.Point(($cx + 6), ($y + 24))),
                    (New-Object System.Drawing.Point(($cx + 12), ($y + 26)))))
                $bb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(238, 238, 245))
                $g.FillRectangle($bb, ($cx - 6), $y, 12, 24)     # body
                $bb.Dispose()
                $wb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(90, 170, 255))
                $g.FillEllipse($wb, ($cx - 3), ($y + 5), 7, 7)   # porthole
                $wb.Dispose(); $vb.Dispose()
            } else {
                $b  = $st.PhaseFrame
                $cx = [int]$st.RocketX
                $ay = [int]$st.ApexY
                if ($b -lt 6) {                       # initial white flash
                    $r  = 8 + 4 * $b
                    $fa = [int](210 - 30 * $b)
                    $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($fa, 255, 255, 255))
                    $g.FillEllipse($br, ($cx - $r), ($ay - $r), ($r * 2), ($r * 2))
                    $br.Dispose()
                }
                $a = [int][math]::Max(0, 235 - $b * 2.6)
                if ($a -gt 0) {
                    foreach ($p in $st.Parts) {       # firework streaks
                        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($a, $p.Col), 2)
                        $x1 = $cx + [math]::Cos($p.Ang) * [math]::Max(0, $p.Dist - $p.Len)
                        $y1 = $ay + [math]::Sin($p.Ang) * [math]::Max(0, $p.Dist - $p.Len)
                        $x2 = $cx + [math]::Cos($p.Ang) * $p.Dist
                        $y2 = $ay + [math]::Sin($p.Ang) * $p.Dist
                        $g.DrawLine($pen, [single]$x1, [single]$y1, [single]$x2, [single]$y2)
                        $pen.Dispose()
                    }
                }
                if ($b -ge 4) {                       # the payload: freed amount
                    $font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
                    $sz   = $g.MeasureString($st.Text, $font)
                    $tx   = $cx - $sz.Width / 2
                    $ty   = $ay - $sz.Height / 2
                    $sh = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(200, 20, 20, 24))
                    $g.DrawString($st.Text, $font, $sh, [single]($tx + 1), [single]($ty + 1)); $sh.Dispose()
                    $tb = New-Object System.Drawing.SolidBrush($st.Color)
                    $g.DrawString($st.Text, $font, $tb, [single]$tx, [single]$ty); $tb.Dispose()
                    $font.Dispose()
                }
            }
        } catch {}
    })
    $btnScreen = $widget.PointToScreen($btnWOpt.Location)
    $x = $btnScreen.X + [int]($btnWOpt.Width / 2) - [int]($t.Width / 2)
    $y = $btnScreen.Y - $t.Height - 2
    $wa = [System.Windows.Forms.Screen]::FromPoint($btnScreen).WorkingArea
    $x  = [math]::Max($wa.Left, [math]::Min($x, $wa.Right - $t.Width))
    $y  = [math]::Max($wa.Top, $y)
    $t.Location = New-Object System.Drawing.Point($x, $y)
    [void][Win32.Psapi]::ShowWindow($t.Handle, 4)   # show without stealing focus
    $anim = New-Object System.Windows.Forms.Timer
    $anim.Interval = 15
    $anim.Tag = $st
    $st.Timer = $anim
    $anim.Add_Tick({
        param($sender, $e)
        try {
            $st = $sender.Tag
            $st.PhaseFrame++
            foreach ($p in $st.Puffs) { $p.X += $p.VX; $p.R += $p.Grow; $p.Life-- }   # smoke physics
            $st.Puffs = @($st.Puffs | Where-Object { $_.Life -gt 0 })
            if ($st.Phase -eq 0) {
                $st.RocketX = 120 + $st.Rnd.Next(-1, 2)          # airframe rumble
                if ($st.Puffs.Count -lt 44) {                    # smoke billows out sideways
                    $st.Puffs += @{ X = 120 + $st.Rnd.Next(-6, 7); Y = 283 + $st.Rnd.Next(-2, 3)
                                    VX = ($st.Rnd.NextDouble() - 0.5) * 2.6
                                    R = 2 + $st.Rnd.Next(0, 3); Grow = 0.14; Life = 30; MaxLife = 30 }
                }
                if ($st.PhaseFrame -gt 3600) {                   # safety: never idle forever
                    $sender.Stop(); $st.Form.Close(); $st.Form.Dispose(); $sender.Dispose()
                    $script:Rocket = $null
                    return
                }
            } elseif ($st.Phase -eq 1) {
                $st.RocketX = 120.0
                $pr = $st.PhaseFrame / [double]$st.LaunchFrames
                $st.RocketY = $st.StartY - ($st.StartY - $st.ApexY) * ($pr * $pr)   # accelerating climb
                if ($st.PhaseFrame -le 10) {                     # liftoff blast across the pad
                    $st.Puffs += @{ X = 120 + $st.Rnd.Next(-8, 9); Y = 284 + $st.Rnd.Next(-2, 3)
                                    VX = ($st.Rnd.NextDouble() - 0.5) * 4.0
                                    R = 3 + $st.Rnd.Next(0, 4); Grow = 0.2; Life = 34; MaxLife = 34 }
                }
                $st.Puffs += @{ X = 120 + $st.Rnd.Next(-4, 5); Y = $st.RocketY + 26 + $st.Rnd.Next(0, 7)
                                VX = 0.0; R = 2 + $st.Rnd.Next(0, 4); Grow = 0.0; Life = 14; MaxLife = 14 }
                if ($st.PhaseFrame -ge $st.LaunchFrames) { $st.Phase = 2; $st.PhaseFrame = 0 }
            } else {
                foreach ($p in $st.Parts) { $p.Dist += $p.Spd; $p.Spd *= 0.955 }
                if ($st.PhaseFrame -ge 75) { $st.Form.Opacity = [math]::Max(0, $st.Form.Opacity - 0.04) }
                if ($st.Form.Opacity -le 0.03 -or $st.PhaseFrame -ge 115) {
                    $sender.Stop(); $st.Form.Close(); $st.Form.Dispose(); $sender.Dispose()
                    $script:Rocket = $null
                    return
                }
            }
            $st.Form.Invalidate()
        } catch { $sender.Stop(); $sender.Dispose(); $script:Rocket = $null }
    })
    $anim.Start()
    $script:Rocket = $st
    return $st
}

# Called when an optimize begins: put the rocket on the pad, engines sputtering.
function Start-RocketPrep {
    try {
        if ($script:Rocket) {   # a previous boom still fading - clear the pad first
            try {
                $script:Rocket.Timer.Stop(); $script:Rocket.Timer.Dispose()
                $script:Rocket.Form.Close(); $script:Rocket.Form.Dispose()
            } catch {}
            $script:Rocket = $null
        }
        [void](New-RocketFx)
    } catch {}
}

# Called with the result: arm the waiting rocket and launch it. If somehow no
# rocket is on the pad, one is created and launches immediately.
function Show-FreedToast([int]$freedMB) {
    try {
        $color =
            if ($freedMB -ge 1000)   { [System.Drawing.Color]::FromArgb(120, 235, 150) }
            elseif ($freedMB -ge 100){ [System.Drawing.Color]::FromArgb(255, 210, 80) }
            else                     { [System.Drawing.Color]::FromArgb(170, 170, 180) }
        $text = if ($freedMB -ge 1) { "+$(Format-MB $freedMB) freed" } else { 'already lean' }
        $palette =
            if ($freedMB -ge 1000) { @([System.Drawing.Color]::FromArgb(120, 235, 150),
                                       [System.Drawing.Color]::FromArgb(255, 210, 80),
                                       [System.Drawing.Color]::FromArgb(160, 130, 255),
                                       [System.Drawing.Color]::White) }
            elseif ($freedMB -ge 100) { @([System.Drawing.Color]::FromArgb(255, 210, 80),
                                          [System.Drawing.Color]::FromArgb(255, 150, 60),
                                          [System.Drawing.Color]::White) }
            else                      { @([System.Drawing.Color]::FromArgb(190, 190, 200),
                                          [System.Drawing.Color]::White) }
        $st = $script:Rocket
        if (-not $st -or $st.Form.IsDisposed) { $st = New-RocketFx }
        $rnd = $st.Rnd
        $st.Text  = $text
        $st.Color = $color
        $st.Parts = @(1..(@(8, 12, 18)[[int]($freedMB -ge 100) + [int]($freedMB -ge 1000)]) | ForEach-Object {
            @{ Ang  = $rnd.NextDouble() * 6.2832
               Spd  = 2.0 + $rnd.NextDouble() * 2.6
               Dist = 0.0
               Len  = 6 + $rnd.Next(0, 8)
               Col  = $palette[$rnd.Next(0, $palette.Count)] }
        })
        $st.Phase      = 1   # liftoff
        $st.PhaseFrame = 0
    } catch {}
}

# One-click optimize: trim unused memory from every process EXCEPT system
# processes and the user's ticked exceptions. Never closes anything.
function Do-Optimize([switch]$Auto) {
    if ($script:Optimizing) { return }
    $script:Optimizing = $true
    Start-OptimizeJolt $btnWOpt
    Start-RocketPrep   # rocket on the pad, engines sputtering, until the result is in
    $memBefore = Get-MemInfo
    $skip = @('System','Idle','Registry','MemCompression','Memory Compression','csrss','wininit',
              'winlogon','smss','lsass','services','audiodg','dwm','fontdrvhost',
              'MsMpEng','SecurityHealthService','bdservicehost','bdagent','bdntwrk')
    $before = [int64]0; $after = [int64]0; $trimmed = 0
    $perProc = @{}
    $protectedHit = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $scan = 0
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        $scan++
        # Pump often enough that the launch-pad animation keeps moving during the trim
        if ($scan % 6 -eq 0) { try { [System.Windows.Forms.Application]::DoEvents() } catch {} }
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
                if (-not $perProc.ContainsKey($p.ProcessName)) {
                    $perProc[$p.ProcessName] = @{ Before = [int64]0; After = [int64]0; Count = 0 }
                }
                $entry = $perProc[$p.ProcessName]
                $entry.Before += $ws
                $entry.After  += $p.WorkingSet64
                $entry.Count++
            }
        } catch {}
    }
    $freedMB  = [math]::Max(0, [math]::Round(($before - $after) / 1MB))
    $memAfter = Get-MemInfo
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $trigger  = if ($Auto) { 'auto' } else { 'manual' }
    $protList = ($protectedHit | Sort-Object) -join '; '
    $protMsg  = if ($protectedHit.Count) { " Protected: $protList." } else { '' }
    # Per-process results (aggregated by name), for the details log + event line
    $procRows = @(foreach ($k in $perProc.Keys) {
        $entry = $perProc[$k]
        $f = [math]::Round(($entry.Before - $entry.After) / 1MB)
        if ($f -ge 1) {
            [pscustomobject]@{
                Name     = $k
                Count    = $entry.Count
                BeforeMB = [math]::Round($entry.Before / 1MB)
                AfterMB  = [math]::Round($entry.After / 1MB)
                FreedMB  = $f
            }
        }
    }) | Sort-Object FreedMB -Descending
    $tag = if ($Auto) { 'AUTO Optimize' } else { 'Optimize' }
    $bullet = [string][char]0x2022
    $txtEvents.AppendText("[$ts] ${tag}: $($memBefore.Pct)% -> $($memAfter.Pct)% | freed ~$(Format-MB $freedMB) across $trimmed processes`r`n")
    foreach ($r in ($procRows | Select-Object -First 5)) {
        $txtEvents.AppendText(("   $bullet {0} {1,9}`r`n" -f $r.Name.PadRight(28), (Format-MB $r.FreedMB)))
    }
    if ($protectedHit.Count) {
        $txtEvents.AppendText("   $bullet protected: $(($protectedHit | Sort-Object) -join ', ')`r`n")
    }
    $txtEvents.AppendText("`r`n")
    if (-not (Test-Path $script:OptDetCsv)) {
        'timestamp,process,instances,beforeMB,afterMB,freedMB,trigger' | Out-File $script:OptDetCsv -Encoding utf8
    }
    $detLines = foreach ($r in $procRows) {
        $n = $r.Name
        if ($n -match '[,"]') { $n = '"' + ($n -replace '"', '""') + '"' }
        "$ts,$n,$($r.Count),$($r.BeforeMB),$($r.AfterMB),$($r.FreedMB),$trigger"
    }
    if ($detLines) { $detLines | Add-Content $script:OptDetCsv }
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
    $notify.BalloonTipText  = "RAM $($memBefore.Pct)% -> $($memAfter.Pct)% - freed ~$(Format-MB $freedMB) across $trimmed processes.$protMsg"
    $notify.ShowBalloonTip(8000)
    $script:Optimizing = $false
    Update-Stats          # heavy refresh first, so the toast animates on an idle thread
    Show-FreedToast $freedMB
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
$widget.Size            = New-Object System.Drawing.Size(250, 176)
$widget.StartPosition   = 'Manual'
$widget.TopMost         = $true
$widget.ShowInTaskbar   = $false
$widget.BackColor       = $cWidgetBg
# Translucency comes from the acrylic glass tint, not layered Opacity -
# a layered window (Opacity < 1) disables the compositor's blur entirely.

$lblWTitle = New-Object System.Windows.Forms.Label
$lblWTitle.Location  = New-Object System.Drawing.Point(10, 6)
$lblWTitle.Size      = New-Object System.Drawing.Size(110, 14)
$lblWTitle.Font      = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
$lblWTitle.ForeColor = $cWidgetSub
$lblWTitle.Text      = 'MEMORY (RAM)'

$lblWStatus = New-Object System.Windows.Forms.Label
$lblWStatus.Location  = New-Object System.Drawing.Point(130, 5)
$lblWStatus.Size      = New-Object System.Drawing.Size(110, 16)
$lblWStatus.Font      = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
$lblWStatus.TextAlign = 'MiddleRight'
$lblWStatus.ForeColor = [System.Drawing.Color]::White
$lblWStatus.Text      = '...'

$lblWPct = New-Object System.Windows.Forms.Label
$lblWPct.Location  = New-Object System.Drawing.Point(8, 20)
$lblWPct.Size      = New-Object System.Drawing.Size(90, 34)
$lblWPct.Font      = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
$lblWPct.ForeColor = [System.Drawing.Color]::White
$lblWPct.Text      = '--%'

$lblWGB = New-Object System.Windows.Forms.Label
$lblWGB.Location  = New-Object System.Drawing.Point(102, 22)
$lblWGB.Size      = New-Object System.Drawing.Size(138, 17)
$lblWGB.Font      = New-Object System.Drawing.Font('Segoe UI', 9.5)
$lblWGB.ForeColor = [System.Drawing.Color]::White
$lblWGB.Text      = '-- / -- GB'

$lblWFree = New-Object System.Windows.Forms.Label
$lblWFree.Location  = New-Object System.Drawing.Point(102, 40)
$lblWFree.Size      = New-Object System.Drawing.Size(138, 14)
$lblWFree.Font      = New-Object System.Drawing.Font('Segoe UI', 7.5)
$lblWFree.ForeColor = $cWidgetSub
$lblWFree.Text      = 'reading...'

$wBarBg = New-Object System.Windows.Forms.Panel
$wBarBg.Location  = New-Object System.Drawing.Point(10, 58)
$wBarBg.Size      = New-Object System.Drawing.Size(230, 8)
$wBarBg.BackColor = $cBarBg

$wBarFill = New-Object System.Windows.Forms.Panel
$wBarFill.Location  = New-Object System.Drawing.Point(1, 1)
$wBarFill.Size      = New-Object System.Drawing.Size(2, 6)
$wBarFill.BackColor = [System.Drawing.Color]::FromArgb(90, 200, 120)
$wBarBg.Controls.Add($wBarFill)

$wSpark = New-Object System.Windows.Forms.Panel
$wSpark.Location  = New-Object System.Drawing.Point(10, 70)
$wSpark.Size      = New-Object System.Drawing.Size(230, 34)
$wSpark.BackColor = $cSparkBg

$lblWTop = New-Object System.Windows.Forms.Label
$lblWTop.Location  = New-Object System.Drawing.Point(10, 108)
$lblWTop.Size      = New-Object System.Drawing.Size(230, 13)
$lblWTop.Font      = New-Object System.Drawing.Font('Segoe UI', 7.5)
$lblWTop.ForeColor = [System.Drawing.Color]::Gainsboro
$lblWTop.Text      = 'Top: reading...'

$lblWTrend = New-Object System.Windows.Forms.Label
$lblWTrend.Location  = New-Object System.Drawing.Point(10, 121)
$lblWTrend.Size      = New-Object System.Drawing.Size(230, 14)
$lblWTrend.Font      = New-Object System.Drawing.Font('Segoe UI', 7.5)
$lblWTrend.ForeColor = $cWidgetSub
$lblWTrend.Text      = 'Trend: gathering data...'

# Full-width optimize action bar - the widget's hero button, glows by severity
$btnWOpt = New-Object System.Windows.Forms.Button
$btnWOpt.Location  = New-Object System.Drawing.Point(10, 139)
$btnWOpt.Size      = New-Object System.Drawing.Size(230, 30)
$btnWOpt.FlatStyle = 'Flat'
$btnWOpt.FlatAppearance.BorderSize = 0
$btnWOpt.FlatAppearance.MouseOverBackColor = $cAccentHover
$btnWOpt.BackColor = $cAccent
$btnWOpt.ForeColor = [System.Drawing.Color]::White
$btnWOpt.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnWOpt.Text      = ([string][char]0x26A1) + ' OPTIMIZE RAM'
$btnWOpt.Cursor    = [System.Windows.Forms.Cursors]::Hand

$widget.Controls.AddRange(@(
    $lblWTitle, $lblWStatus, $lblWPct, $lblWGB, $lblWFree,
    $wBarBg, $wSpark, $lblWTop, $lblWTrend, $btnWOpt
))

$btnWOpt.Add_Click({
    $btnWOpt.Enabled = $false
    $oldText = $btnWOpt.Text
    $btnWOpt.Text = 'OPTIMIZING...'
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
    $ty = [int](($h - 2) * (1 - [int]$script:AlertPct / 100)) + 1
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
    $pen = New-Object System.Drawing.Pen($cSparkLine, 2)
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

# Drag to move (no title bar), remember position, hover = more solid glass.
# While dragging, the blur is swapped for a solid tint: moving an acrylic
# window forces the compositor to re-blur every frame, which lags.
$script:Drag = $null
$dragDown = {
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:Drag = @{ Cursor = [System.Windows.Forms.Cursor]::Position; Form = $widget.Location }
        Set-Glass $widget 1 $script:GlassSolid
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
        Set-Glass $widget $script:GlassState $script:GlassHover
    }
}
$openFull   = { $form.Show(); $form.Activate() }
$hoverEnter = { Set-Glass $widget $script:GlassState $script:GlassHover }
$hoverLeave = {
    $p = $widget.PointToClient([System.Windows.Forms.Cursor]::Position)
    if (-not $widget.ClientRectangle.Contains($p)) { Set-Glass $widget $script:GlassState $script:GlassNormal }
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
# Style submenu mirrors the monitor's picker (inserted after the index wiring above)
$styleMenu = New-Object System.Windows.Forms.ToolStripMenuItem('Style')
foreach ($tn in @($script:Themes.Keys)) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem([string]$tn)
    $mi.Add_Click({ param($s, $e) Apply-Theme $s.Text })
    [void]$styleMenu.DropDownItems.Add($mi)
}
[void]$menu.Items.Insert(3, $styleMenu)

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

# ---------- style engine ----------
# Reassigns the live palette (paint handlers pick that up on the next frame)
# and restyles every control property that was set at construction time.
$script:SettingStyle = $false
function Apply-Theme([string]$name) {
    $t = $script:Themes[$name]
    if (-not $t) { return }
    $script:StyleName = $name
    $script:cBg = $t.Bg; $script:cCard = $t.Card; $script:cText = $t.Text
    $script:cSub = $t.Sub; $script:cBorder = $t.Border
    $script:cHeadBg = $t.HeadBg; $script:cHeadText = $t.HeadText
    $script:cBtnBg = $t.BtnBg; $script:cBtnHover = $t.BtnHover; $script:cBtnBorder = $t.BtnBorder
    $script:cAccent = $t.Accent; $script:cAccentHover = $t.AccentHover
    $script:cGraphGrid = $t.GraphGrid; $script:cGraphLine = $t.GraphLine; $script:cGraphFill = $t.GraphFill
    $script:cAxis = $t.Axis; $script:cStatus = $t.Status
    $script:cWidgetBg = $t.WidgetBg; $script:cWidgetSub = $t.WidgetSub
    $script:cBarBg = $t.BarBg; $script:cSparkBg = $t.SparkBg; $script:cSparkLine = $t.SparkLine
    $script:GlassState  = $t.GlassState
    $script:GlassNormal = $t.GlassNormal; $script:GlassHover = $t.GlassHover; $script:GlassSolid = $t.GlassSolid
    # monitor window
    $form.BackColor = $t.Bg; $form.ForeColor = $t.Text
    $lblPct.ForeColor = $t.Text
    foreach ($c in @($lblThr, $lblPctSign, $lblAutoPct, $chkLog, $chkAuto, $lblSug, $lblEv)) { $c.ForeColor = $t.Text }
    foreach ($c in @($lblDetail, $lblGraphCap, $lblStyle)) { $c.ForeColor = $t.Sub }
    $lblStatus.ForeColor = $t.Status
    foreach ($c in @($cboWin, $cboStyle, $numThreshold, $numAuto)) { $c.BackColor = $t.Card; $c.ForeColor = $t.Text }
    $pnlGraph.BackColor = $t.Card
    $lv.BackColor = $t.Card; $lv.ForeColor = $t.Text
    foreach ($c in @($txtSuggest, $txtEvents)) { $c.BackColor = $t.Card; $c.ForeColor = $t.Text }
    foreach ($b in @($btnSnapshot, $btnOpenLogs, $btnKill, $btnTaskMgr)) { Style-DarkButton $b }
    Style-DarkButton $btnOptimize $true
    # widget
    $widget.BackColor = $t.WidgetBg
    foreach ($c in @($lblWTitle, $lblWFree, $lblWTrend)) { $c.ForeColor = $t.WidgetSub }
    $wBarBg.BackColor = $t.BarBg
    $wSpark.BackColor = $t.SparkBg
    $btnWOpt.BackColor = $t.Accent
    $btnWOpt.FlatAppearance.MouseOverBackColor = $t.AccentHover
    # glass tint/state per style
    Set-Glass $widget $t.GlassState $t.GlassNormal
    Set-Glass $form   $t.GlassState $t.GlassNormal
    # sync both pickers without re-triggering
    $script:SettingStyle = $true
    try {
        $cboStyle.SelectedItem = $name
        foreach ($mi in $styleMenu.DropDownItems) { $mi.Checked = ($mi.Text -eq $name) }
    } catch {}
    $script:SettingStyle = $false
    $form.Refresh(); $widget.Refresh()
    Save-Settings
}

# ---------- persisted settings (thresholds + auto-optimize + style) ----------
$script:SetFile = Join-Path $script:LogDir 'settings.txt'
function Save-Settings {
    @(
        "alertPct=$([int]$script:AlertPct)",
        "autoEnabled=$(if ($chkAuto.Checked) { 1 } else { 0 })",
        "autoPct=$([int]$script:AutoPct)",
        "style=$($script:StyleName)"
    ) | Out-File $script:SetFile -Encoding utf8
}
if (Test-Path $script:SetFile) {
    try {
        $kv = @{}
        Get-Content $script:SetFile | ForEach-Object {
            $pair = $_ -split '=', 2
            if ($pair.Count -eq 2) { $kv[$pair[0].Trim()] = $pair[1].Trim() }
        }
        if ($kv['alertPct']) { $script:AlertPct = [math]::Min(99, [math]::Max(50, [int]$kv['alertPct'])); $numThreshold.Value = $script:AlertPct }
        if ($kv['autoPct'])  { $script:AutoPct  = [math]::Min(99, [math]::Max(50, [int]$kv['autoPct']));  $numAuto.Value = $script:AutoPct }
        $chkAuto.Checked = ($kv['autoEnabled'] -eq '1')
        if ($kv['style'] -and $script:Themes[$kv['style']]) { $script:StyleName = $kv['style'] }
    } catch {}
}
# Apply the persisted (or default) style once everything exists - this also
# syncs the picker, the menu checkmarks, and the glass tints.
Apply-Theme $script:StyleName
$numThreshold.Add_ValueChanged({ $script:AlertPct = [int]$numThreshold.Value; Save-Settings })
$numAuto.Add_ValueChanged({ $script:AutoPct = [int]$numAuto.Value; Save-Settings })
$numThreshold.Add_Enter({ $numThreshold.Select(0, 10) })
$numAuto.Add_Enter({ $numAuto.Select(0, 10) })
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
            $txtEvents.AppendText("[$($c[0])] earlier Optimize: $($c[3])% -> $($c[4])%, freed ~$(Format-MB ([double]$c[1])) across $($c[2]) processes`r`n")
        }
    }
    $txtEvents.AppendText("`r`n")
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$script:TickCount = 0
$timer.Add_Tick({
    if ($script:Optimizing -or $script:Drag) { return }   # never compete with a drag
    $script:TickCount++
    if ($script:TickCount % 3 -eq 0) { Update-Stats } else { Update-Fast }
})

# Pulsing glow on the widget's optimize button when memory runs high
$glowTimer = New-Object System.Windows.Forms.Timer
$glowTimer.Interval = 120
$glowTimer.Add_Tick({
    if ($script:Drag) { return }
    if ($script:Optimizing) {
        # electric crackle while the trim is running
        $script:GlowPhase += 1
        $btnWOpt.BackColor =
            if ([int]$script:GlowPhase % 2) { [System.Drawing.Color]::FromArgb(255, 240, 140) }
            else                            { [System.Drawing.Color]::FromArgb(150, 110, 255) }
        return
    }
    if ($script:OptGlowLevel -eq 0) {
        $calm = $cAccent
        if ($btnWOpt.BackColor -ne $calm) {
            $btnWOpt.BackColor = $calm
            $btnWOpt.FlatAppearance.BorderSize = 0
        }
        return
    }
    $script:GlowPhase += $(if ($script:OptGlowLevel -eq 2) { 0.55 } else { 0.28 })
    $t = 0.5 + 0.5 * [math]::Sin($script:GlowPhase)
    if ($script:OptGlowLevel -eq 2) {
        $r = [int](200 + 55 * $t); $g = [int](45 + 45 * $t); $b = [int](45 + 45 * $t)
    } else {
        $r = [int](205 + 50 * $t); $g = [int](125 + 50 * $t); $b = [int](25 + 30 * $t)
    }
    $btnWOpt.BackColor = [System.Drawing.Color]::FromArgb($r, $g, $b)
    $btnWOpt.FlatAppearance.BorderSize  = 1
    $btnWOpt.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(
        [math]::Min(255, $r + 45), [math]::Min(255, $g + 45), [math]::Min(255, $b + 45))
})

$widget.Add_Shown({ Update-Stats; $timer.Start(); $glowTimer.Start() })
$widget.Add_FormClosed({
    $timer.Stop()
    $glowTimer.Stop()
    if ($script:HotKey) { try { $script:HotKey.Dispose() } catch {} }
    $notify.Visible = $false
    $notify.Dispose()
    if (-not $form.IsDisposed) { $form.Dispose() }
})

# Widget is the app host: closing it (right-click > Exit) ends monitoring
# Glass on. Applied to the window handles before they are shown; the accent
# sticks to the handle, so hiding/showing the monitor keeps its glass.
try {
    [GlassApi]::RoundCorners($widget.Handle)
    Set-Glass $widget $script:GlassState $script:GlassNormal
    [GlassApi]::DarkTitleBar($form.Handle)
    Set-Glass $form $script:GlassState $script:GlassNormal
} catch {}

[void]$widget.ShowDialog()
