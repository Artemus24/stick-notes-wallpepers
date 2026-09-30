@echo off
cd /d "%~dp0"
if not exist "%~dp0editor.ps1" (
  echo editor.ps1 is not in this folder.
  pause
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0editor.ps1"
if errorlevel 1 pause
