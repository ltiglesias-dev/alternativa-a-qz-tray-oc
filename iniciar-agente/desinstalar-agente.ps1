$ErrorActionPreference = 'SilentlyContinue'
$taskName = 'Agendarte Printer Agent'
$installDir = Join-Path ($env:LOCALAPPDATA) 'AgendartePrinterAgent'
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
Write-Host 'Tarea de inicio eliminada.'
Write-Host ('Los archivos de configuración permanecen en: ' + $installDir)
Read-Host 'Presioná Enter para cerrar'
