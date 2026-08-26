param(
    [switch]$Worker,
    [string]$RequestPath,
    [string]$ResultPath
)

$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configuratorScriptPath = $MyInvocation.MyCommand.Path
$installDir = Join-Path ($env:LOCALAPPDATA) 'AgendartePrinterAgent'
$configPath = Join-Path $installDir 'config.json'
$tokenPath = Join-Path $installDir 'token.txt'
$taskName = 'Agendarte Printer Agent'

function Normalize-Origin([string]$value) {
    $candidate = $value.Trim()
    if (-not $candidate) { return $null }
    if ($candidate -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $candidate = 'http://' + $candidate }
    try { return ([Uri]$candidate).GetLeftPart([UriPartial]::Authority).TrimEnd('/') } catch { return $null }
}

function Get-InstalledPrinters {
    try {
        return @(Get-Printer | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; Port = [string]$_.PortName; Display = ('{0}  (Puerto: {1})' -f $_.Name, $_.PortName) }
        })
    } catch {
        try {
            return @(Get-CimInstance Win32_Printer | Sort-Object Name | ForEach-Object {
                [pscustomobject]@{ Name = [string]$_.Name; Port = ''; Display = [string]$_.Name }
            })
        } catch { return @() }
    }
}

function New-AgentToken {
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Stop-Agent {
    try { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Milliseconds 250
    $serverPath = Join-Path $installDir 'server.js'
    Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($serverPath) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}

function Get-ErrorDetails($errorRecord) {
    $message = ''
    if ($errorRecord -and $errorRecord.Exception) { $message = [string]$errorRecord.Exception.Message }
    if ([string]::IsNullOrWhiteSpace($message) -and $errorRecord) { $message = ([string]($errorRecord | Out-String)).Trim() }
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = 'Error sin detalle. Revisá que Node.js esté instalado, que el puerto 8765 esté libre y consultá configurator-error.log.'
    }
    return $message
}

function Save-ConfiguratorError([string]$details) {
    try {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        $logPath = Join-Path $installDir 'configurator-error.log'
        $entry = ('[{0}] {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $details, [Environment]::NewLine)
        [System.IO.File]::AppendAllText($logPath, $entry, [System.Text.UTF8Encoding]::new($false))
    } catch {}
}

function Set-EdgeLoopbackPolicy([string[]]$origins) {
    # Edge admite esta política por usuario, por lo que no requiere elevar
    # permisos ni modificar la configuración de otras cuentas de Windows.
    $policyPath = 'HKCU:\Software\Policies\Microsoft\Edge\LoopbackNetworkAllowedForUrls'
    try {
        New-Item -Path $policyPath -Force | Out-Null
        $current = Get-ItemProperty -Path $policyPath -ErrorAction SilentlyContinue
        if ($current) {
            $current.PSObject.Properties |
                Where-Object { $_.Name -match '^\d+$' } |
                ForEach-Object { Remove-ItemProperty -Path $policyPath -Name $_.Name -ErrorAction SilentlyContinue }
        }
        $index = 1
        foreach ($origin in @($origins)) {
            New-ItemProperty -Path $policyPath -Name ([string]$index) -PropertyType String -Value ([string]$origin) -Force | Out-Null
            $index++
        }
        return $true
    } catch {
        return $false
    }
}

function Install-Agent([string[]]$origins, [object[]]$selectedPrinters) {
    $token = New-AgentToken
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceDir 'server.js') -Destination (Join-Path $installDir 'server.js') -Force
    Copy-Item -LiteralPath (Join-Path $sourceDir 'print-raw.ps1') -Destination (Join-Path $installDir 'print-raw.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $sourceDir 'package.json') -Destination (Join-Path $installDir 'package.json') -Force
    Copy-Item -LiteralPath (Join-Path $sourceDir 'ejecutar-agente-oculto.ps1') -Destination (Join-Path $installDir 'ejecutar-agente-oculto.ps1') -Force

    $printerConfigs = @()
    for ($i = 0; $i -lt $selectedPrinters.Count; $i++) {
        $printerConfigs += [ordered]@{ name = [string]$selectedPrinters[$i].Name; role = ('impresora-' + ($i + 1)); paperWidth = '58mm' }
    }
    $config = [ordered]@{ port = 8765; allowedOrigins = @($origins); token = $token; paperWidth = '58mm'; printers = @($printerConfigs) }
    [System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    $tokenText = @('Agendarte Printer Agent', '=======================', ('Generado: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')), ('Token: ' + $token)) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($tokenPath, $tokenText, [System.Text.UTF8Encoding]::new($false))

    Stop-Agent
    $serverPath = Join-Path $installDir 'server.js'
    $runnerPath = Join-Path $installDir 'ejecutar-agente-oculto.ps1'
    $powershell = Get-Command powershell.exe -ErrorAction Stop
    $runnerArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $runnerPath
    $action = New-ScheduledTaskAction -Execute $powershell.Source -Argument $runnerArguments -WorkingDirectory $installDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Agente local de impresión ESC/POS de Agendarte' -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    $edgePolicyApplied = Set-EdgeLoopbackPolicy $origins
    # La interfaz recibe el token apenas termina la instalación. La salud del
    # agente se comprueba desde el temporizador de la ventana para que una
    # demora de localhost nunca deje el configurador bloqueado.
    return [pscustomobject]@{ Token = $token; EdgePolicyApplied = $edgePolicyApplied }
}

if ($Worker) {
    try {
        if (-not (Test-Path -LiteralPath $RequestPath)) { throw 'No se encontró la solicitud de configuración.' }
        $requestJson = [System.IO.File]::ReadAllText($RequestPath, [System.Text.UTF8Encoding]::new($false))
        $payload = $requestJson | ConvertFrom-Json
        $installResult = Install-Agent $payload.Origins $payload.Printers
        $result = [pscustomobject]@{
            Success = $true
            Token = $installResult.Token
            Printers = @($payload.Printers)
            EdgePolicyApplied = [bool]$installResult.EdgePolicyApplied
            Error = ''
        }
    } catch {
        $details = Get-ErrorDetails $_
        Save-ConfiguratorError $details
        $result = [pscustomobject]@{
            Success = $false
            Token = ''
            Printers = @()
            EdgePolicyApplied = $false
            Error = $details
        }
    }
    # Escribimos primero un archivo temporal para que la ventana nunca intente
    # leer el JSON mientras todavía se está escribiendo.
    $partialResultPath = $ResultPath + '.tmp'
    [System.IO.File]::WriteAllText($partialResultPath, ($result | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $partialResultPath -Destination $ResultPath -Force
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function New-Label([string]$text, [int]$x, [int]$y, [int]$width = 150) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $text
    $label.Location = New-Object System.Drawing.Point($x, $y)
    $label.Size = New-Object System.Drawing.Size($width, 24)
    return $label
}

function Show-Notice([string]$message, [string]$title = 'Agendarte Printer Agent') {
    # Usamos únicamente la sobrecarga de dos textos. Windows PowerShell 5.1
    # puede confundir las sobrecargas que reciben enums de Windows Forms.
    [System.Windows.Forms.MessageBox]::Show([string]$message, [string]$title) | Out-Null
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Agendarte Printer Agent'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(720, 650)
$form.MinimumSize = New-Object System.Drawing.Size(720, 650)
$form.BackColor = [System.Drawing.Color]::White

$title = New-Label 'Agendarte Printer Agent' 28 20 500
$title.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($title)
$subtitle = New-Label 'Configuración del agente local de impresión silenciosa' 30 56 620
$subtitle.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($subtitle)

$form.Controls.Add((New-Label 'Web autorizada (podés separar varias con coma)' 30 100 560))
$originsBox = New-Object System.Windows.Forms.TextBox
$originsBox.Location = New-Object System.Drawing.Point(30, 126)
$originsBox.Size = New-Object System.Drawing.Size(640, 28)
$originsBox.Text = 'https://agendarte.uy'
$form.Controls.Add($originsBox)

$form.Controls.Add((New-Label 'Impresoras instaladas en Windows' 30 176 350))
$printerList = New-Object System.Windows.Forms.CheckedListBox
$printerList.Location = New-Object System.Drawing.Point(30, 202)
$printerList.Size = New-Object System.Drawing.Size(640, 150)
$printerList.CheckOnClick = $true
$printerList.DisplayMember = 'Display'
$form.Controls.Add($printerList)

$refresh = New-Object System.Windows.Forms.Button
$refresh.Text = 'Actualizar impresoras'
$refresh.Location = New-Object System.Drawing.Point(30, 362)
$refresh.Size = New-Object System.Drawing.Size(180, 34)
$form.Controls.Add($refresh)

$status = New-Label 'El agente todavía no fue configurado.' 30 415 640
$status.ForeColor = [System.Drawing.Color]::DarkSlateGray
$form.Controls.Add($status)

$tokenLabel = New-Label 'Token generado (guardado también en token.txt)' 30 452 450
$form.Controls.Add($tokenLabel)
$tokenBox = New-Object System.Windows.Forms.TextBox
$tokenBox.Location = New-Object System.Drawing.Point(30, 478)
$tokenBox.Size = New-Object System.Drawing.Size(520, 28)
$tokenBox.ReadOnly = $true
$form.Controls.Add($tokenBox)

$copy = New-Object System.Windows.Forms.Button
$copy.Text = 'Copiar'
$copy.Location = New-Object System.Drawing.Point(560, 476)
$copy.Size = New-Object System.Drawing.Size(110, 32)
$copy.Enabled = $false
$form.Controls.Add($copy)

$save = New-Object System.Windows.Forms.Button
$save.Text = 'Guardar y activar agente'
$save.Location = New-Object System.Drawing.Point(30, 535)
$save.Size = New-Object System.Drawing.Size(230, 38)
$save.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$save.ForeColor = [System.Drawing.Color]::White
$save.FlatStyle = 'Flat'
$save.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($save)

$folder = New-Object System.Windows.Forms.Button
$folder.Text = 'Abrir carpeta del agente'
$folder.Location = New-Object System.Drawing.Point(280, 535)
$folder.Size = New-Object System.Drawing.Size(190, 38)
$form.Controls.Add($folder)

$installProcess = $null
$installTimer = New-Object System.Windows.Forms.Timer
$installTimer.Interval = 250

function Complete-Install([object]$result) {
    $save.Enabled = $true
    if (-not $result.Success) {
        $installTimer.Stop()
        $status.Text = 'No se pudo completar la configuración.'
        $details = Get-ErrorDetails $result.Error
        Show-Notice $details 'Error de configuración'
        return
    }
    $tokenBox.Text = $result.Token
    $copy.Enabled = $true
    $installTimer.Stop()
    if ($result.EdgePolicyApplied) {
        $permissionStatus = ' Permiso local de Edge configurado.'
    } else {
        $permissionStatus = ' Edge no permitió configurar la política; aceptá el permiso una vez en el navegador.'
    }
    $status.Text = ('Agente activo en segundo plano. Token listo para copiar.' + $permissionStatus + ' Impresoras: ' + (($result.Printers | ForEach-Object { $_.Name }) -join ', '))
}

$installTimer.Add_Tick({
    if (-not $installProcess) { return }
    if (Test-Path -LiteralPath $script:resultPath) {
        try {
            $resultJson = [System.IO.File]::ReadAllText($script:resultPath, [System.Text.UTF8Encoding]::new($false))
            $result = $resultJson | ConvertFrom-Json
            Complete-Install $result
        } catch {
            $installTimer.Stop()
            $details = Get-ErrorDetails $_
            Save-ConfiguratorError $details
            $save.Enabled = $true
            $status.Text = 'No se pudo completar la configuración.'
            Show-Notice $details 'Error de configuración'
        } finally {
            Remove-Item -LiteralPath $script:requestPath, $script:resultPath -Force -ErrorAction SilentlyContinue
            $script:installProcess = $null
        }
    } elseif ($installProcess.HasExited) {
        $installTimer.Stop()
        $details = 'El proceso de configuración terminó sin devolver un resultado. Consultá configurator-error.log.'
        Save-ConfiguratorError $details
        $save.Enabled = $true
        $status.Text = 'No se pudo completar la configuración.'
        Show-Notice $details 'Error de configuración'
        $script:installProcess = $null
    }
})

function Refresh-PrinterList {
    $printerList.Items.Clear()
    foreach ($printer in @(Get-InstalledPrinters)) { [void]$printerList.Items.Add($printer, $false) }
    if ($printerList.Items.Count -eq 0) { $status.Text = 'No se detectaron impresoras. Instalá la impresora y actualizá la lista.' }
}

$refresh.Add_Click({ Refresh-PrinterList })
$copy.Add_Click({ if ($tokenBox.Text) { [System.Windows.Forms.Clipboard]::SetText($tokenBox.Text); $status.Text = 'Token copiado al portapapeles.' } })
$folder.Add_Click({ if (Test-Path $installDir) { Start-Process explorer.exe $installDir } else { [System.Windows.Forms.MessageBox]::Show('La carpeta todavía no existe. Guardá la configuración primero.', 'Agendarte Printer Agent') } })
$save.Add_Click({
    try {
        $origins = @($originsBox.Text -split ',' | ForEach-Object { Normalize-Origin $_ } | Where-Object { $_ } | Select-Object -Unique)
        $selected = @($printerList.CheckedItems | ForEach-Object { $_ })
        if ($origins.Count -eq 0) { throw 'Ingresá al menos una web autorizada válida.' }
        if ($selected.Count -eq 0) { throw 'Seleccioná al menos una impresora.' }
        $save.Enabled = $false
        $status.Text = 'Guardando configuración y activando el agente...'
        $form.Refresh()
        $selectedForInstall = @($selected)
        $operationId = [Guid]::NewGuid().ToString('N')
        $script:requestPath = Join-Path ([IO.Path]::GetTempPath()) ('agendarte-agent-' + $operationId + '.request.json')
        $script:resultPath = Join-Path ([IO.Path]::GetTempPath()) ('agendarte-agent-' + $operationId + '.result.json')
        $payload = [pscustomobject]@{ Origins = @($origins); Printers = @($selectedForInstall) }
        [IO.File]::WriteAllText($script:requestPath, ($payload | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $powershell = Get-Command powershell.exe -ErrorAction Stop
        $workerArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Worker -RequestPath "{1}" -ResultPath "{2}"' -f $configuratorScriptPath, $script:requestPath, $script:resultPath
        $script:installProcess = Start-Process -FilePath $powershell.Source -ArgumentList $workerArguments -WorkingDirectory $sourceDir -WindowStyle Hidden -PassThru
        $installTimer.Start()
    } catch {
        $details = Get-ErrorDetails $_
        Save-ConfiguratorError $details
        $save.Enabled = $true
        $status.Text = 'No se pudo completar la configuración.'
        Show-Notice $details 'Error de configuración'
    }
})

Refresh-PrinterList
[void]$form.ShowDialog()
