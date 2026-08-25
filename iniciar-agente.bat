@echo off
setlocal
set "AGENT_DIR=%LOCALAPPDATA%\AgendartePrinterAgent"
if not exist "%AGENT_DIR%\server.js" (
    echo Primero ejecuta instalar-agente.bat
    pause
    exit /b 1
)
node "%AGENT_DIR%\server.js" --config "%AGENT_DIR%\config.json"
