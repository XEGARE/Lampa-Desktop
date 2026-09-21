@echo off
chcp 65001 > nul
cd /d "%~dp0"

set "PS_EXE=powershell"
where pwsh > nul 2>&1
if not errorlevel 1 set "PS_EXE=pwsh"

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Build-Release.ps1" -SkipRelease %*
echo.
pause
