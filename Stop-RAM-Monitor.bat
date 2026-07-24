@echo off
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -like 'powershell*' -and $_.CommandLine -match 'RamMonitor' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
echo RAM Monitor stopped.
ping -n 3 127.0.0.1 >nul
