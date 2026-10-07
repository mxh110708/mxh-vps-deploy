@echo off
setlocal
if exist "%~dp0runtime\powershell\pwsh.exe" (
  set "PATH=%~dp0runtime\powershell;%~dp0runtime\python;%~dp0runtime\openssh;%PATH%"
)
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7.4 or newer is required.
  pause
  exit /b 1
)
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-VPSDeploy.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" pause
exit /b %EXIT_CODE%
