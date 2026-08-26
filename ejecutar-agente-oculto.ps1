$ErrorActionPreference = 'Stop'

$installDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverPath = Join-Path $installDir 'server.js'
$configPath = Join-Path $installDir 'config.json'

if (-not (Test-Path $serverPath) -or -not (Test-Path $configPath)) {
    throw 'No se encontró la instalación del agente.'
}

$node = Get-Command node -ErrorAction Stop
$arguments = '"{0}" --config "{1}"' -f $serverPath, $configPath
$process = Start-Process -FilePath $node.Source -ArgumentList $arguments -WorkingDirectory $installDir -WindowStyle Hidden -PassThru
$process.WaitForExit()
exit $process.ExitCode
