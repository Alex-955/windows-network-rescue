@echo off
setlocal
cd /d "%~dp0"
if not exist "%~dp0NetRescue.ps1" (
  echo Please extract the entire ZIP first. NetRescue.ps1 is missing.
  pause
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0NetRescue.ps1"
if errorlevel 1 (
  echo.
  echo The tool stopped. Please keep this message for diagnosis.
  pause
)
endlocal
