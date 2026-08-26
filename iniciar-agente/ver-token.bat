@echo off
setlocal
set "TOKEN_FILE=%LOCALAPPDATA%\AgendartePrinterAgent\token.txt"
if not exist "%TOKEN_FILE%" (
    set "CONFIG_FILE=%LOCALAPPDATA%\AgendartePrinterAgent\config.json"
    if exist "%CONFIG_FILE%" (
        echo Todavia no existe token.txt; abriendo la configuracion actual.
        start "" notepad.exe "%CONFIG_FILE%"
        exit /b 0
    )
    echo Todavia no existe una instalacion del agente. Ejecuta ..\integracion\instalar-agente.bat.
    pause
    exit /b 1
)
start "" notepad.exe "%TOKEN_FILE%"
