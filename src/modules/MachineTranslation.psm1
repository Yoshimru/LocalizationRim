Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-RFMachineSettingsDefaults {
    [pscustomobject]@{
        Provider = 'Google'
        BaseUrl = 'https://agentrouter.org/v1'
        Model = 'gpt-5.6-sol'
        ApiKeyProtected = ''
        MaxConcurrency = 5
        RequestTimeoutSeconds = 60
        CustomPrompt = 'Translate RimWorld mod text into natural Russian. Preserve XML tags, placeholders, formatting tokens, proper names and line breaks. Return only the translation.'
    }
}

function Get-RFMachineSettings {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $configDirectory = Join-Path $ProjectRoot 'config'
    $path = Join-Path $configDirectory 'settings.json'
    $defaults = Get-RFMachineSettingsDefaults
    if (-not (Test-Path -LiteralPath $path)) { return $defaults }
    try { $stored = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json }
    catch { return $defaults }
    foreach ($property in $defaults.PSObject.Properties) {
        if (-not $stored.PSObject.Properties[$property.Name]) {
            $stored | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
        }
    }
    return $stored
}

function Protect-RFMachineApiKey {
    param([string]$ApiKey)
    if (-not $ApiKey) { return '' }
    Add-Type -AssemblyName System.Security
    $bytes = [Text.Encoding]::UTF8.GetBytes($ApiKey)
    $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($protected)
}

function Unprotect-RFMachineApiKey {
    param([string]$ProtectedValue)
    if (-not $ProtectedValue) { return '' }
    try {
        Add-Type -AssemblyName System.Security
        $bytes = [Convert]::FromBase64String($ProtectedValue)
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($plain)
    } catch { return '' }
}

function Save-RFMachineSettings {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Settings,
        [string]$PlainApiKey = ''
    )
    $configDirectory = Join-Path $ProjectRoot 'config'
    if (-not (Test-Path -LiteralPath $configDirectory)) { New-Item -ItemType Directory -Path $configDirectory | Out-Null }
    if ($PlainApiKey) { $Settings.ApiKeyProtected = Protect-RFMachineApiKey $PlainApiKey }
    $path = Join-Path $configDirectory 'settings.json'
    [IO.File]::WriteAllText($path, ($Settings | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    return $path
}

function Set-RFXmlChildValue {
    param([xml]$Document, $Parent, [string]$Name, [string]$Value)
    $node = $Parent.SelectSingleNode($Name)
    if (-not $node) {
        $node = $Document.CreateElement($Name)
        [void]$Parent.AppendChild($node)
    }
    $node.InnerText = $Value
    return $node
}

function Get-RFAutoTranslationSettingsDocument {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        return [xml][IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
    }
    return [xml]'<?xml version="1.0" encoding="utf-8"?><SettingsBlock><ModSettings Class="AutoTranslation.Settings" /></SettingsBlock>'
}

function Set-RFAutoTranslationAiSettings {
    param([xml]$Document, $Root, $Settings, [string]$ApiKey)
    $dictionary = $Root.SelectSingleNode('TranslatorSettings')
    if (-not $dictionary) {
        $dictionary = $Document.CreateElement('TranslatorSettings')
        [void]$Root.AppendChild($dictionary)
    }
    $keys = $dictionary.SelectSingleNode('keys')
    if (-not $keys) { $keys = $Document.CreateElement('keys'); [void]$dictionary.AppendChild($keys) }
    $values = $dictionary.SelectSingleNode('values')
    if (-not $values) { $values = $Document.CreateElement('values'); [void]$dictionary.AppendChild($values) }
    $keyNodes = @($keys.SelectNodes('li'))
    $valueNodes = @($values.SelectNodes('li'))
    $index = -1
    for ($i = 0; $i -lt $keyNodes.Count; $i++) {
        if ([string]$keyNodes[$i].InnerText -eq 'OpenAI Compatible (Local/Other)') { $index = $i; break }
    }
    if ($index -lt 0) {
        $keyNode = $Document.CreateElement('li'); $keyNode.InnerText = 'OpenAI Compatible (Local/Other)'; [void]$keys.AppendChild($keyNode)
        $valueNode = $Document.CreateElement('li'); $class = $Document.CreateAttribute('Class'); $class.Value = 'AutoTranslation.Translators.TranslatorSettings_AIModel'; [void]$valueNode.Attributes.Append($class); [void]$values.AppendChild($valueNode)
    } else { $valueNode = $valueNodes[$index] }
    Set-RFXmlChildValue $Document $valueNode 'UserAPIKey' $ApiKey | Out-Null
    Set-RFXmlChildValue $Document $valueNode 'UserSelectedModel' ([string]$Settings.Model) | Out-Null
    Set-RFXmlChildValue $Document $valueNode 'UserCustomBaseURL' ([string]$Settings.BaseUrl) | Out-Null
    Set-RFXmlChildValue $Document $valueNode 'UserCustomPrompt' ([string]$Settings.CustomPrompt) | Out-Null
    Set-RFXmlChildValue $Document $valueNode 'EnableBatchTranslation' 'True' | Out-Null
    Set-RFXmlChildValue $Document $valueNode 'BatchSizeTokens' '2000' | Out-Null
    Set-RFXmlChildValue $Document $valueNode 'RequestTimeoutSeconds' ([string]$Settings.RequestTimeoutSeconds) | Out-Null
}

function Get-RFRimWorldInstallPath {
    param([string[]]$WorkshopRoots)
    foreach ($root in $WorkshopRoots) {
        try {
            $steamApps = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $root))
            $candidate = Join-Path $steamApps 'common\RimWorld'
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        } catch {}
    }
    foreach ($candidate in @(
        'C:\Program Files (x86)\Steam\steamapps\common\RimWorld',
        'C:\Program Files\Steam\steamapps\common\RimWorld'
    )) { if (Test-Path -LiteralPath $candidate) { return $candidate } }
    throw 'Не найдена папка установки RimWorld.'
}

function Install-RFEmbeddedAutoTranslation {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string[]]$WorkshopRoots
    )
    $source = Join-Path $ProjectRoot 'resources\AutoTranslation'
    if (-not (Test-Path -LiteralPath (Join-Path $source '1.7\Assemblies\AutoTranslation.dll'))) {
        throw 'В комплекте LocalizationRim отсутствуют файлы встроенного Auto Translation.'
    }
    $rimWorld = Get-RFRimWorldInstallPath -WorkshopRoots $WorkshopRoots
    $modsRoot = Join-Path $rimWorld 'Mods'
    $destination = Join-Path $modsRoot '3278005460'
    if (-not (Test-Path -LiteralPath $destination)) { New-Item -ItemType Directory -Path $destination -Force | Out-Null }
    foreach ($folder in @('About', 'Languages', '1.5', '1.6', '1.7')) {
        $from = Join-Path $source $folder
        $to = Join-Path $destination $folder
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $destination -Recurse -Force }
    }
    foreach ($file in @('LICENSE.GPL-3.0.txt', 'THIRD_PARTY_NOTICE.md')) {
        $from = Join-Path $source $file
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination (Join-Path $destination $file) -Force }
    }
    $metadata = Get-RFModMetadata -ModPath $destination -WorkshopId '3278005460'
    if (-not $metadata -or $metadata.PackageId -ine 'seohyeon.autotranslation') {
        throw 'Не удалось развернуть встроенный Auto Translation.'
    }
    return $metadata
}

function Enable-RFMachineTranslation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Mods,
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string[]]$WorkshopRoots,
        [Parameter(Mandatory)][string]$ProjectRoot
    )
    if ($Mods.Count -eq 0) { throw 'Не выбраны моды для машинного перевода.' }
    $engine = @()
    foreach ($rootPath in $WorkshopRoots) {
        $enginePath = Join-Path $rootPath '3278005460'
        if (Test-Path -LiteralPath $enginePath) {
            $metadata = Get-RFModMetadata -ModPath $enginePath -WorkshopId '3278005460'
            if ($metadata -and $metadata.PackageId -ieq 'seohyeon.autotranslation') { $engine = @($metadata); break }
        }
    }
    $deployedEmbedded = $false
    if ($engine.Count -eq 0) {
        $engine = @(Install-RFEmbeddedAutoTranslation -ProjectRoot $ProjectRoot -WorkshopRoots $WorkshopRoots)
        $deployedEmbedded = $true
    }
    $activation = Add-RFPackageToActiveList -PackageId $engine[0].PackageId -ConfigPath $ConfigPath
    [xml]$modsConfig = [IO.File]::ReadAllText($ConfigPath, [Text.UTF8Encoding]::new($false))
    $activeIds = @($modsConfig.ModsConfigData.activeMods.li | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    $selectedIds = @($Mods | Select-Object -ExpandProperty PackageId -Unique | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $settingsPath = Join-Path (Split-Path -Parent $ConfigPath) "Mod_$($engine[0].WorkshopId)_AutoTranslation.xml"
    $document = Get-RFAutoTranslationSettingsDocument $settingsPath
    $root = $document.SelectSingleNode('/SettingsBlock/ModSettings')
    Set-RFXmlChildValue $document $root 'AutoTranslation_TranslatorName' $(if ($Settings.Provider -eq 'AgentRouter') { 'OpenAI Compatible (Local/Other)' } else { [string]$Settings.Provider }) | Out-Null
    Set-RFXmlChildValue $document $root 'AutoTranslation_EnableAutoTranslation' 'True' | Out-Null
    Set-RFXmlChildValue $document $root 'AutoTranslation_AutoTranslateNewMods' 'False' | Out-Null
    Set-RFXmlChildValue $document $root 'AutoTranslation_TargetLanguageOverride' 'Russian' | Out-Null
    Set-RFXmlChildValue $document $root 'AutoTranslation_MaxConcurrency' ([string]$Settings.MaxConcurrency) | Out-Null
    $blackList = $root.SelectSingleNode('AutoTranslation_WhiteListModPackageIds')
    if (-not $blackList) { $blackList = $document.CreateElement('AutoTranslation_WhiteListModPackageIds'); [void]$root.AppendChild($blackList) }
    $blackList.RemoveAll()
    foreach ($id in $activeIds | Where-Object { $selectedIds -notcontains $_ -and $_ -ne 'seohyeon.autotranslation' }) {
        $node = $document.CreateElement('li'); $node.InnerText = $id; [void]$blackList.AppendChild($node)
    }
    if ($Settings.Provider -eq 'AgentRouter') {
        $apiKey = Unprotect-RFMachineApiKey ([string]$Settings.ApiKeyProtected)
        if (-not $apiKey) { throw 'Для Agent Router не указан API-ключ.' }
        if (-not $Settings.Model) { throw 'Для Agent Router не указана модель.' }
        Set-RFAutoTranslationAiSettings $document $root $Settings $apiKey
    }
    $backupPath = ''
    if (Test-Path -LiteralPath $settingsPath) {
        $backupPath = "$settingsPath.before-russifier-finder.$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').bak"
        Copy-Item $settingsPath $backupPath
    }
    $document.Save($settingsPath)
    [pscustomobject]@{
        EnginePackageId = $engine[0].PackageId
        EngineActivated = $activation.Added
        EmbeddedEngineDeployed = $deployedEmbedded
        SelectedMods = $selectedIds
        Provider = $Settings.Provider
        SettingsPath = $settingsPath
        BackupPath = $backupPath
    }
}

Export-ModuleMember -Function @(
    'Get-RFMachineSettings', 'Save-RFMachineSettings', 'Protect-RFMachineApiKey',
    'Unprotect-RFMachineApiKey', 'Enable-RFMachineTranslation'
)
