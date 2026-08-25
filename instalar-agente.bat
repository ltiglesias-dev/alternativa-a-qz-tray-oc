@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-agent.ps1"
if errorlevel 1 (
    echo.
    echo La instalacion no pudo completarse.
    pause
)
