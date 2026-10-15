@echo off
setlocal
cd /d "%~dp0"
if not exist "%~dp0NetRescue.ps1" (
  echo Please copy or extract the entire toolkit first.
  pause
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0NetRescue.ps1" -CleanupReports
echo.
pause
endlocal
