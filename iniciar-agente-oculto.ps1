$ErrorActionPreference = 'Stop'
$installDir = Join-Path ($env:LOCALAPPDATA) 'AgendartePrinterAgent'
$taskName = 'Agendarte Printer Agent'
$serverPath = Join-Path $installDir 'server.js'
$configPath = Join-Path $installDir 'config.json'

if (-not (Test-Path $serverPath) -or -not (Test-Path $configPath)) {
    throw 'Primero configurá el agente desde instalar-agente.bat.'
}

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Start-ScheduledTask -TaskName $taskName
    exit 0
}

$node = Get-Command node -ErrorAction Stop
$arguments = '"{0}" --config "{1}"' -f $serverPath, $configPath
Start-Process -FilePath $node.Source -ArgumentList $arguments -WorkingDirectory $installDir -WindowStyle Hidden
