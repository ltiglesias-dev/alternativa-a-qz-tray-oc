$ErrorActionPreference = 'Stop'

$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installDir = Join-Path ($env:LOCALAPPDATA) 'AgendartePrinterAgent'
$configPath = Join-Path $installDir 'config.json'
$tokenPath = Join-Path $installDir 'token.txt'
$taskName = 'Agendarte Printer Agent'

function Normalize-Origin([string]$value) {
    $candidate = $value.Trim()
    if (-not $candidate) { return $null }
    if ($candidate -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $candidate = 'http://' + $candidate
    }
    try {
        return ([Uri]$candidate).GetLeftPart([UriPartial]::Authority).TrimEnd('/')
    } catch {
        return $null
    }
}

Write-Host ''
Write-Host '=== Instalador Agendarte Printer Agent ===' -ForegroundColor Cyan
Write-Host 'El agente imprimirá tickets ESC/POS directamente en las impresoras configuradas.'
Write-Host ''

$originInput = Read-Host 'Web autorizada (ej: https://agendarte.uy o http://localhost)'
$origins = @($originInput -split ',' | ForEach-Object { Normalize-Origin $_ } | Where-Object { $_ } | Select-Object -Unique)
if ($origins.Count -eq 0) {
    throw 'No se ingresó una URL válida.'
}

try {
    $availablePrinters = @(Get-Printer | Sort-Object Name)
} catch {
    throw 'No se pudieron consultar las impresoras de Windows. Ejecutá este instalador en Windows con las impresoras instaladas.'
}

if ($availablePrinters.Count -gt 0) {
    Write-Host ''
    Write-Host 'Impresoras detectadas:' -ForegroundColor Yellow
    for ($i = 0; $i -lt $availablePrinters.Count; $i++) {
        Write-Host ("[{0}] {1}  (Puerto: {2})" -f ($i + 1), $availablePrinters[$i].Name, $availablePrinters[$i].PortName)
    }
} else {
    Write-Warning 'Windows no informó impresoras instaladas.'
}

$count = 0
while ($count -lt 1) {
    $count = 0
    [int]::TryParse((Read-Host '¿Cuántas impresoras querés configurar?'), [ref]$count) | Out-Null
    if ($count -lt 1) { Write-Warning 'Ingresá un número mayor o igual a 1.' }
}

$printerConfigs = @()
for ($i = 1; $i -le $count; $i++) {
    do {
        $printerName = (Read-Host ("Nombre exacto de la impresora #{0}" -f $i)).Trim()
        $found = @($availablePrinters | Where-Object { $_.Name -eq $printerName })
        if (-not $printerName) {
            Write-Warning 'El nombre no puede estar vacío.'
        } elseif ($found.Count -eq 0) {
            $continue = Read-Host "No se encontró '$printerName'. ¿Usarlo igualmente? (S/N)"
            if ($continue -match '^[sS]$') { break }
            $printerName = ''
        }
    } while (-not $printerName)

    $role = (Read-Host ("Rol opcional para '$printerName' (mostrador/cocina/otro)" )).Trim()
    if (-not $role) { $role = 'impresora-' + $i }
    $printerConfigs += [ordered]@{
        name = $printerName
        role = $role
        paperWidth = '58mm'
    }
}

$tokenBytes = New-Object byte[] 24
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($tokenBytes)
$token = [Convert]::ToBase64String($tokenBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceDir 'server.js') -Destination (Join-Path $installDir 'server.js') -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'print-raw.ps1') -Destination (Join-Path $installDir 'print-raw.ps1') -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'package.json') -Destination (Join-Path $installDir 'package.json') -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'ejecutar-agente-oculto.ps1') -Destination (Join-Path $installDir 'ejecutar-agente-oculto.ps1') -Force

$config = [ordered]@{
    port = 8765
    allowedOrigins = @($origins)
    token = $token
    paperWidth = '58mm'
    printers = @($printerConfigs)
}
$configJson = $config | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($configPath, $configJson, [System.Text.UTF8Encoding]::new($false))
$tokenFile = @(
    'Agendarte Printer Agent'
    '======================='
    ('Generado: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
    ('Token: ' + $token)
) -join [Environment]::NewLine
[System.IO.File]::WriteAllText($tokenPath, $tokenFile, [System.Text.UTF8Encoding]::new($false))

$serverPath = Join-Path $installDir 'server.js'

# Si se reinstala y cambia el token, detener la instancia anterior para que
# no siga atendiendo con la configuración vieja.
try { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Milliseconds 300
Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($serverPath) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}

$runnerPath = Join-Path $installDir 'ejecutar-agente-oculto.ps1'
$powershell = Get-Command powershell.exe -ErrorAction Stop
$runnerArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $runnerPath
$action = New-ScheduledTaskAction -Execute $powershell.Source -Argument $runnerArguments -WorkingDirectory $installDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Agente local de impresión ESC/POS de Agendarte' -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Milliseconds 800
$healthHeaders = @{ Authorization = 'Bearer ' + $token }
try {
    Invoke-WebRequest -Uri ('http://127.0.0.1:{0}/health' -f $config.port) -Headers $healthHeaders -TimeoutSec 5 | Out-Null
} catch {
    throw 'La configuración se guardó, pero el agente no pudo iniciarse. Ejecutá iniciar-agente\iniciar-agente.bat para ver el error.'
}

Write-Host ''
Write-Host 'Instalación completada.' -ForegroundColor Green
Write-Host ('Directorio: ' + $installDir)
Write-Host ('Web autorizada: ' + ($origins -join ', '))
Write-Host ('Impresoras: ' + (($printerConfigs | ForEach-Object { $_.name }) -join ', '))
Write-Host 'El agente se iniciará automáticamente al iniciar sesión en Windows.'
Write-Host ''
Write-Host 'Token local para integrar la web:' -ForegroundColor Yellow
Write-Host $token
Write-Host ('Archivo con el token vigente: ' + $tokenPath)
Write-Host ''
Write-Host 'API: http://127.0.0.1:8765/health'
Write-Host 'Para probar: POST http://127.0.0.1:8765/test'
Read-Host 'Presioná Enter para cerrar'
