param(
    [Parameter(Mandatory = $true)]
    [string]$OriginsFile
)

$ErrorActionPreference = 'Stop'
$policyPath = 'HKLM:\Software\Policies\Microsoft\Edge\LoopbackNetworkAllowedForUrls'
$json = [System.IO.File]::ReadAllText($OriginsFile, [System.Text.UTF8Encoding]::new($false))
$origins = @($json | ConvertFrom-Json)
if ($origins.Count -eq 0) { throw 'No se recibieron webs autorizadas.' }

New-Item -Path $policyPath -Force | Out-Null
$current = Get-ItemProperty -Path $policyPath -ErrorAction SilentlyContinue
if ($current) {
    $current.PSObject.Properties |
        Where-Object { $_.Name -match '^\d+$' } |
        ForEach-Object { Remove-ItemProperty -Path $policyPath -Name $_.Name -ErrorAction SilentlyContinue }
}

$index = 1
foreach ($origin in $origins) {
    New-ItemProperty -Path $policyPath -Name ([string]$index) -PropertyType String -Value ([string]$origin) -Force | Out-Null
    $index++
}

exit 0
