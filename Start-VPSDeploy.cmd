@echo off
setlocal
if exist "%~dp0MXH-VPS-Deploy.exe" (
  start "" "%~dp0MXH-VPS-Deploy.exe"
  exit /b 0
)
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7.4 or newer is required. Install it and run this file again.
  pause
  exit /b 1
)
pwsh.exe -NoLogo -NoProfile -Command "if ($PSVersionTable.PSVersion -lt [version]'7.4') { exit 1 }"
if errorlevel 1 (
  echo PowerShell 7.4 or newer is required.
  pause
  exit /b 1
)
start "" pwsh.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Start-VPSDeploy.Gui.ps1" %*
exit /b 0
