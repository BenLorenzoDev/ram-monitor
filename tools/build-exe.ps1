# OPTIONAL: builds "RamMonitor.exe" (repo root) from tools/launcher.cs using
# the C# compiler bundled with the .NET Framework on every Windows machine.
# (No space in the name: paths an AV once quarantined can stay blocked even
# after a folder exclusion, so the original "RAM Monitor.exe" name is burned.)
#
# FAIR WARNING: an unsigned exe that launches hidden PowerShell matches the
# behavior profile of malware droppers. Most antivirus products (Bitdefender,
# Defender, etc.) will quarantine or delete it unless you add an exclusion for
# this folder FIRST. The Start-RAM-Monitor.bat / desktop-shortcut route avoids
# this entirely, which is why the repo does not ship a prebuilt exe.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-exe.ps1
$root = Split-Path -Parent $PSScriptRoot
$csc  = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'csc.exe not found - .NET Framework 4.x is required (preinstalled on Windows 10/11).' }

$out = Join-Path $root 'RamMonitor.exe'
& $csc /nologo /target:winexe /out:"$out" /win32icon:"$(Join-Path $root 'ram-monitor.ico')" `
    /r:System.Windows.Forms.dll "$(Join-Path $PSScriptRoot 'launcher.cs')"
if ($LASTEXITCODE -eq 0) { "Built: $out" } else { throw "csc failed with exit code $LASTEXITCODE" }
