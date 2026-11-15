param(
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][string]$ResultPath,
    [Parameter(Mandatory)][string]$ProgressPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-HelperJson {
    param([string]$Path, $Value)
    $json = $Value | ConvertTo-Json -Depth 10 -Compress
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

try {
    $request = ([IO.File]::ReadAllText($RequestPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    Import-Module ([string]$request.ModulePath) -Force
    $ids = if ($request.WorkshopIds -is [System.Array]) { [string[]]$request.WorkshopIds } else { @([string]$request.WorkshopIds) }
    $roots = if ($request.WorkshopRoots -is [System.Array]) { [string[]]$request.WorkshopRoots } else { @([string]$request.WorkshopRoots) }
    $keepRimSortOpen = $request.PSObject.Properties['KeepRimSortOpen'] -and [bool]$request.KeepRimSortOpen
    $output = @(Install-RFTranslations -WorkshopIds $ids -ConfigPath ([string]$request.ConfigPath) -WorkshopRoots $roots `
        -KeepRimSortOpen:$keepRimSortOpen -OnProgress {
        param($stage, $done, $total, $name)
        Write-HelperJson -Path $ProgressPath -Value ([pscustomobject]@{
            Kind = 'Progress'; Stage = $stage; Done = $done; Total = $total; Name = $name
        })
    })
    $report = @($output | Where-Object { $_.PSObject.Properties['Kind'] -and $_.Kind -eq 'InstallResult' } | Select-Object -Last 1)
    if ($report.Count -eq 0) { throw 'Не получен итоговый отчёт установки.' }
    Write-HelperJson -Path $ResultPath -Value ([pscustomobject]@{ Success = $true; Report = $report[0] })
    exit 0
} catch {
    Write-HelperJson -Path $ResultPath -Value ([pscustomobject]@{
        Success = $false
        Error = $_.Exception.Message
        Details = [string]$_
    })
    exit 1
}
