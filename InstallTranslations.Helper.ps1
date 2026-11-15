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
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $stream = $null
        try {
            $stream = New-Object IO.FileStream(
                $Path,
                [IO.FileMode]::Create,
                [IO.FileAccess]::Write,
                [IO.FileShare]::ReadWrite
            )
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
            return
        } catch [IO.IOException] {
            if ($attempt -eq 20) { throw }
            Start-Sleep -Milliseconds 25
        } finally {
            if ($stream) { $stream.Dispose() }
        }
    }
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
        # Progress is informational and must never abort subscriptions or a
        # config update if the UI happens to read the file at the same moment.
        try {
            Write-HelperJson -Path $ProgressPath -Value ([pscustomobject]@{
                Kind = 'Progress'; Stage = $stage; Done = $done; Total = $total; Name = $name
            })
        } catch {}
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
