<p align="center">
  <img src="assets/icon.png" width="96" alt="RAM Monitor icon">
</p>

<h1 align="center">RAM Monitor</h1>

<p align="center">
  A lightweight, always-on-top RAM monitoring widget for Windows with spike auto-analysis
  and safe one-click memory optimization.<br>
  <b>One PowerShell script. Zero dependencies. Nothing to install.</b>
</p>

<p align="center">
  <img src="assets/widget.png" alt="Widget - all good">
  <img src="assets/widget-high.png" alt="Widget - high usage">
  <img src="assets/widget-critical.png" alt="Widget - critical">
</p>
<p align="center"><i>The widget as pressure rises: all good &rarr; high (70%+) &rarr; critical (your alert level) - the whole widget turns red and the optimize bar pulses.</i></p>

---

## Run it (60 seconds)

Works on any Windows 10 / 11 machine. No install, no admin rights, no internet needed.

1. **Get the code** — either:
   - Click **Code → Download ZIP** on this page, then extract it anywhere, **or**
   - `git clone https://github.com/BenLorenzoDev/ram-monitor.git`
2. **Double-click `Start-RAM-Monitor.bat`** (in the folder you just extracted/cloned).
3. Done — the widget appears in the **top-right corner** of your screen and starts monitoring immediately.

**To stop it:** right-click the widget → **Exit RAM Monitor**. (If it's ever unresponsive, double-click `Stop-RAM-Monitor.bat`.)

### Prefer a real .exe?

Build one locally in seconds — it uses the C# compiler that ships with Windows, nothing to install:

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-exe.ps1
```

That creates **`RamMonitor.exe`** in the repo root: double-clickable, no console window, proper icon — same app. **Add an antivirus exclusion for the folder first**: an unsigned exe that starts hidden PowerShell looks exactly like a malware dropper to AV engines, which is also why the repo doesn't ship a prebuilt exe.

### Start with Windows / desktop shortcut

Create a shortcut to `RamMonitor.exe` (or to
`powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File <path>\src\RamMonitor.ps1` if you skipped the exe),
set its icon to `ram-monitor.ico`, and drop it on your desktop — or into your Startup folder (`Win+R` → `shell:startup`) to launch on login.

## What it does

- **Watches your RAM every second** in a small always-on-top widget: usage %, OK / HIGH / CRITICAL verdict, GB used and free, live sparkline, top consumers, and trend.
- **Tells you what caused a spike** — when usage crosses your alert level it diffs the last ~5 minutes of per-process history and names *who grew*, not just who is biggest.
- **Frees memory safely with one click** (⚡ Optimize) — trims unused working-set memory from every process. **It never closes an app and never loses your work.**
- **Lets you protect apps** — tick any process in the monitor and Optimize will always skip it.
- **Can optimize itself** — optional auto-optimize fires at a level you set, built for the moment your PC is too laggy to even reach the button. Guard-railed so it can't spam itself.
- **Logs everything** to plain CSV/text files so you can analyze usage and optimize history later.

## How to operate

### The widget

| You do | It does |
|---|---|
| **Drag** it | Moves anywhere; the position is remembered |
| **Hover** any element | Explanatory tooltip |
| **Double-click** it | Opens the full monitor window |
| **Right-click** it | Menu: Open full monitor · Optimize RAM now · Snapshot now · Exit |
| Press **⚡ OPTIMIZE RAM** | One-tap optimize (respects your protected apps) |
| Press **`Ctrl+Alt+O`** (from *any* app) | Same optimize, from the keyboard — no mouse needed |

Reading it at a glance:

| Element | Meaning |
|---|---|
| **Status** (top-right) | `OK` (green) / `HIGH` (orange, ≥70%) / `CRITICAL` (red, ≥ your alert level) |
| **Big %** + GB lines | Share of physical RAM in use, `used / total GB`, and how much is still free |
| **Bar + sparkline** | Usage now, and over the last 10 minutes; the dashed red line is your alert level |
| **Top:** line | The two biggest memory consumers right now |
| **Trend** line | `Rising / Falling / Stable` with the GB change over ~5 minutes |
| **⚡ button glow** | Calm violet = fine · pulsing orange = 70%+ · fast red pulse = past your alert level. When it's flashing, it's worth a tap |

The whole widget tints red when you cross your alert threshold.

> Note: apps in true fullscreen (games, F11 video) draw over everything, including this widget. Normal maximized windows do not.

### The full monitor

<p align="center">
  <img src="assets/monitor.png" alt="RAM Monitor full window" width="850">
</p>

Double-click the widget to open it. Two-column, Task Manager-style dark window — closing it (X) just returns you to the widget, the app keeps running.

**Left column — live data:**

- **Graph** — updates every second; pick the time window (60 s / 5 min / 10 min); your alert level is the dashed red line.
- **Alert at [85]%** — when usage crosses this, you get a Windows notification with the spike analysis.
- **Auto-optimize at [80]%** — tick to enable hands-free optimizing (see below).
- **Process list** — top 15 memory consumers, grouped by app (all Chrome processes = one row), refreshed every 3 s. **Tick a row's checkbox to protect that app from Optimize** — your picks are saved.
- **End selected process** — closes all instances of the selected app after showing you how much RAM you'll get back. System processes and antivirus are refused; `explorer` gets a safe restart offer instead.
- **Open Task Manager** / **Optimize RAM** / **Snapshot** / **Open logs** buttons.

**Right column — what to do and what happened:**

- **Suggested actions** — live advice based on what is actually eating memory (browser → close tabs; dev server climbing → restart it; Docker/WSL idle → `wsl --shutdown`; antivirus scanning → leave it alone). Switches to urgent phrasing above your alert level.
- **Alerts and events** — tall running log of every spike (with its analysis), optimize (with per-app results), snapshot, and ended process. Recent history is preloaded when you open the app.

### Styles

<p align="center">
  <img src="assets/widget-calm.png" alt="Calm style widget">
</p>
<p align="center"><i>The Calm style: same data, delivered gently — "All good" instead of OK/CRITICAL shouting.</i></p>

Pick a UI style from the **Style** dropdown (top-right of the monitor) or widget right-click → **Style**. Your choice persists.

- **Midnight Glass** — dark theme with real acrylic blur-behind (the same compositor effect Task Manager uses), rounded corners, violet accent.
- **Midnight Solid** — identical design with the glass off; guaranteed rendering on every monitor/GPU combination.
- **Calm** — an emotionally intelligent design: low-arousal sage/teal palette, supportive verdicts (*All good / Getting busy / Attention*), warm amber guidance instead of red alarm, and a slow breathing glow instead of flashing. Same information, less stress.

**Multi-monitor note:** on hybrid-GPU machines (e.g. laptop iGPU + dedicated GPU), some screens can't composite the acrylic and text may vanish inside the blur. The app handles this per screen: widget right-click → **Glass on screens** lets you tick/untick each display, and windows automatically switch between glass and solid as you drag them between screens. On dual-GPU systems the default is glass on the primary screen only.

### Optimizing RAM — what actually happens

<p align="center">
  <img src="assets/rocket.gif" alt="Optimize rocket launch sequence">
</p>
<p align="center"><i>Every optimize is a launch program: the rocket preps on the pad while the trim runs, then lifts off and bursts into a firework with the freed amount.</i></p>

Trigger it any way you like: widget ⚡, `Ctrl+Alt+O`, right-click menu, or the monitor's button. Every time:

1. All running processes are enumerated.
2. Windows system processes, antivirus, the app itself, and **everything you've ticked as protected** are skipped.
3. Each remaining process's *working set* is trimmed — memory held but not actively used is released. The app keeps running; nothing closes; no work is lost.
4. The result is measured and reported: notification + event-log entry + CSV rows. Example: `RAM 69% -> 58%, freed ~5.8 GB across 148 processes · Top freed: chrome 850 MB, Discord 320 MB`.

Honest caveats: a just-trimmed app can be briefly sluggish while it reloads what it needs (that's what protecting it is for), and freed memory partially refills as apps touch their data again. Optimize is quick relief before launching something heavy — if one process climbs back relentlessly, that's a leak; the analysis will name it, and the durable fix is restarting that app.

### Auto-optimize

Tick **Auto-optimize at [80]%** in the monitor (80% by default — *below* the alert level, because trimming works best before pressure peaks). Guardrails:

1. **Cooldown** — auto-runs are at least 10 minutes apart.
2. **Self-suspend** — if two consecutive auto-runs bring no lasting relief, something is leaking; it suspends itself and names the fastest-growing process so you know what to restart.
3. **Auto re-arm** — once usage falls well below the trigger, it arms again.

Auto-runs are logged with `trigger=auto` so you can audit exactly what it did.

### Your data

Everything is logged next to the script (personal, gitignored):

| File | Contents |
|---|---|
| `ram-usage.csv` | Usage curve: `timestamp, usedPercent, usedGB, totalGB` every 3 s |
| `ram-spikes.log` | Process-table snapshot + growth analysis for every alert / manual snapshot |
| `optimize-history.csv` | One row per optimize: freed MB, RAM % before/after, protected apps, manual/auto |
| `optimize-details.csv` | Per-process results for every optimize — which apps actually release memory |
| `optimize-exceptions.txt` | Your protected apps, one per line |
| `settings.txt` / `widget-position.txt` | Your thresholds, auto-optimize toggle, widget position |

---

## Why this exists

Task Manager tells you how much RAM is in use *right now*, but not **what caused the spike five minutes ago** while you were busy working. RAM Monitor watches continuously, keeps a rolling per-process history, and when usage crosses your threshold it tells you exactly which process ballooned:

```
===== 2026-07-25 00:41:03 | ALERT >= 85% | used 87.2% (27.4 / 31.4 GB) =====
  Auto-analysis: RAM 62% -> 87% over the last 6 min.
  Biggest growth in that window:
    chrome: +2,100 MB (now 4,900 MB)
    node: +900 MB (now 1,400 MB)
    Code: +800 MB (now 800 MB) (started in that window)
```

The Windows notification carries the headline: *"Memory at 87% — likely cause: chrome +2.1 GB"*.

## How it works

Single-file WinForms app (`src/RamMonitor.ps1`, no compilation, no modules):

- **Two refresh lanes** — a 1-second fast path reads memory via a direct Win32 call (`GlobalMemoryStatusEx`, ~0.1 ms) and redraws the graph/widget; a 3-second slow path does the heavier work: per-process totals, list rebuild, suggestions, CSV logging, alert checks. Steady-state CPU cost is negligible.
- **Optimize** — P/Invokes `psapi.dll!EmptyWorkingSet` per process; access-denied processes are silently skipped (that's Windows protecting them, which is fine).
- **Hotkey** — a tiny `NativeWindow` subclass (compiled inline via `Add-Type`) registers `Ctrl+Alt+O` with `user32!RegisterHotKey`.
- **Graphs** — custom GDI+ `Paint` handlers (double-buffered), no charting libraries.
- **Widget** — borderless `TopMost` form: manual drag handling, tray icon, balloon notifications, context menu. The widget is the app host; the full monitor hides (not closes) back to it.
- **Glass** — real acrylic blur-behind from the desktop compositor (the same effect Task Manager and Windows Terminal use), enabled per window via `SetWindowCompositionAttribute`; rounded corners and the dark title bar via `DwmSetWindowAttribute`. While dragging, the widget swaps to a solid tint (re-blurring a moving window lags) and back to glass on release. Falls back silently to the plain dark theme where the API is unavailable.
- **Icon** — generated programmatically; `tools/make-icon.ps1` rebuilds `ram-monitor.ico` (8 sizes, 16–256 px).

## Repo layout

| Path | Purpose |
|---|---|
| `Start-RAM-Monitor.bat` / `Stop-RAM-Monitor.bat` | End-user entry points: launch the widget / force-stop it |
| `src/RamMonitor.ps1` | The entire application |
| `ram-monitor.ico` | App icon (multi-resolution) |
| `tools/` | Developer scripts: icon generator, optional native-exe launcher build |
| `assets/` | Images used by this README |

The optional exe launcher (`tools/build-exe.ps1` + `tools/launcher.cs`) is covered in [Run it](#prefer-a-real-exe) — including why the repo ships no prebuilt binary.

## Troubleshooting

- **Widget doesn't appear** — run `Stop-RAM-Monitor.bat` then `Start-RAM-Monitor.bat` for a clean restart.
- **Text missing / window looks broken on one monitor** — that screen can't composite the acrylic glass (common with hybrid-GPU laptops). Widget right-click → **Glass on screens** → untick that screen; it renders solid there from then on. Or switch the style to **Midnight Solid**.
- **Antivirus flags files** — the app legitimately does AV-suspicious-looking things (trims process memory, registers a global hotkey, runs as hidden PowerShell). Everything is plain inspectable text; add a folder exclusion if your AV complains.
- **Scripts blocked** — the launchers pass `-ExecutionPolicy Bypass`, so no policy change is needed; if you run the .ps1 directly, use the same flag.
- **No notifications** — Windows Focus Assist / Do Not Disturb suppresses balloon tips; the event log in the full monitor always records everything regardless.

## License

[MIT](LICENSE) — do whatever you like, attribution appreciated.
