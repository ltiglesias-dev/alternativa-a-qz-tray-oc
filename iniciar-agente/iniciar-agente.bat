@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0iniciar-agente-oculto.ps1"
if errorlevel 1 powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('No se pudo iniciar el agente. Ejecutá integracion\instalar-agente.bat para configurarlo.', 'Agendarte Printer Agent')"
exit /b 0
