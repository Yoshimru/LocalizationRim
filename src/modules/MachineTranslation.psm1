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
        CustomPrompt = 'You are a professional Russian localization editor for RimWorld mods. Translate the provided source text into fluent, concise Russian that fits RimWorld terminology and tone. Preserve XML/HTML/BBCode tags, def names, keys, URLs, escaped sequences, line breaks, numbers and placeholders such as {0}, {1}, %s, %d, [PAWN_nameDef], <color>, \n and similar tokens exactly. Keep proper names consistent across strings. Do not translate code identifiers. Do not add explanations, notes, quotation marks or Markdown fences. Return only the translated text.'
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
    $legacyPrompt = 'Translate RimWorld mod text into natural Russian. Preserve XML tags, placeholders, formatting tokens, proper names and line breaks. Return only the translation.'
    if ([string]$stored.CustomPrompt -eq $legacyPrompt) { $stored.CustomPrompt = $defaults.CustomPrompt }
    return $stored
}

function Test-RFMachineTranslationProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Settings,
        [string]$PlainApiKey = '',
        [string]$ProjectRoot = ''
    )
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $provider = [string]$Settings.Provider
    $watch = [Diagnostics.Stopwatch]::StartNew()
    if ($provider -eq 'Google') {
        $url = 'https://translate.google.com/translate_a/single?client=gtx&sl=en&tl=ru&dt=t&ie=UTF-8&oe=UTF-8&q=' + [uri]::EscapeDataString('Hello, colonist!')
        $client = New-Object Net.Http.HttpClient
        try {
            $client.Timeout = [TimeSpan]::FromSeconds([int]$Settings.RequestTimeoutSeconds)
            $raw = $client.GetStringAsync($url).GetAwaiter().GetResult()
            $json = $raw | ConvertFrom-Json
            $translated = (@($json[0] | ForEach-Object { [string]$_[0] }) -join '')
        } finally { $client.Dispose() }
    } elseif ($provider -eq 'Yandex') {
        $url = 'https://browser.translate.yandex.net/api/v1/tr.json/translate?lang=ru&text=' + [uri]::EscapeDataString('Hello, colonist!') + '&srv=browser_video_translation'
        $client = New-Object Net.Http.HttpClient
        try {
            $client.Timeout = [TimeSpan]::FromSeconds([int]$Settings.RequestTimeoutSeconds)
            $content = New-Object Net.Http.StringContent('')
            $raw = $client.PostAsync($url, $content).GetAwaiter().GetResult().Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $json = $raw | ConvertFrom-Json
            $translated = [string]$json.text[0]
        } finally { $client.Dispose() }
    } elseif ($provider -eq 'AgentRouter') {
        if (-not $Settings.Model) { throw 'Не указана модель AgentRouter.' }
        if (-not $ProjectRoot) { throw 'Не указан путь LocalizationRim для AgentRouter CLI bridge.' }
        $bridge = Join-Path $ProjectRoot 'bin\AgentRouterBridge.exe'
        if (-not (Test-Path -LiteralPath $bridge)) { throw 'Не найден bin\AgentRouterBridge.exe.' }
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $bridge
        $psi.Arguments = '--model "' + ([string]$Settings.Model).Replace('"','') + '"'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        $process = [Diagnostics.Process]::Start($psi)
        try {
            $process.StandardInput.Write(([string]$Settings.CustomPrompt) + "`n`nTranslate into Russian and return only the translation: Hello, colonist!")
            $process.StandardInput.Close()
            $raw = $process.StandardOutput.ReadToEnd(); $stderr = $process.StandardError.ReadToEnd()
            if (-not $process.WaitForExit([int]$Settings.RequestTimeoutSeconds * 1000)) { try{$process.Kill()}catch{}; throw 'OpenCode CLI превысил тайм-аут.' }
            if ($process.ExitCode -ne 0) { throw $(if($stderr){$stderr}else{$raw}) }
            $json = $raw | ConvertFrom-Json
            if ($json.is_error) { throw [string]$json.result }
            $translated = [string]$json.result
        } finally { $process.Dispose() }
    } else { throw "Неизвестный провайдер: $provider" }
    $watch.Stop()
    if (-not $translated) { throw 'Провайдер вернул пустой ответ.' }
    [pscustomobject]@{ Provider=$provider; Success=$true; LatencyMs=$watch.ElapsedMilliseconds; Response=$translated.Trim() }
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

function Set-RFAutoTranslationCliSettings {
    param([xml]$Document, $Root, $Settings, [string]$CliPath)
    $dictionary = $Root.SelectSingleNode('TranslatorSettings')
    if (-not $dictionary) { $dictionary=$Document.CreateElement('TranslatorSettings');[void]$Root.AppendChild($dictionary) }
    $keys=$dictionary.SelectSingleNode('keys');if(-not$keys){$keys=$Document.CreateElement('keys');[void]$dictionary.AppendChild($keys)}
    $values=$dictionary.SelectSingleNode('values');if(-not$values){$values=$Document.CreateElement('values');[void]$dictionary.AppendChild($values)}
    $keyNodes=@($keys.SelectNodes('li'));$valueNodes=@($values.SelectNodes('li'));$index=-1
    for($i=0;$i-lt$keyNodes.Count;$i++){if([string]$keyNodes[$i].InnerText-eq'Claude Code (CLI)'){$index=$i;break}}
    if($index-lt0){$keyNode=$Document.CreateElement('li');$keyNode.InnerText='Claude Code (CLI)';[void]$keys.AppendChild($keyNode);$valueNode=$Document.CreateElement('li');$class=$Document.CreateAttribute('Class');$class.Value='AutoTranslation.Translators.TranslatorSettings_AIModel';[void]$valueNode.Attributes.Append($class);[void]$values.AppendChild($valueNode)}else{$valueNode=$valueNodes[$index]}
    Set-RFXmlChildValue $Document $valueNode 'UserSelectedModel' ([string]$Settings.Model)|Out-Null
    Set-RFXmlChildValue $Document $valueNode 'UserCustomPrompt' ([string]$Settings.CustomPrompt)|Out-Null
    Set-RFXmlChildValue $Document $valueNode 'CliPath' $CliPath|Out-Null
    Set-RFXmlChildValue $Document $valueNode 'EnableBatchTranslation' 'True'|Out-Null
    Set-RFXmlChildValue $Document $valueNode 'BatchSizeTokens' '2000'|Out-Null
    Set-RFXmlChildValue $Document $valueNode 'RequestTimeoutSeconds' ([string]$Settings.RequestTimeoutSeconds)|Out-Null
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
    Set-RFXmlChildValue $document $root 'AutoTranslation_TranslatorName' $(if ($Settings.Provider -eq 'AgentRouter') { 'Claude Code (CLI)' } else { [string]$Settings.Provider }) | Out-Null
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
        if (-not $Settings.Model) { throw 'Для Agent Router не указана модель.' }
        $bridge = Join-Path $ProjectRoot 'bin\AgentRouterBridge.exe'
        if (-not (Test-Path -LiteralPath $bridge)) { throw 'Не найден bin\AgentRouterBridge.exe.' }
        Set-RFAutoTranslationCliSettings $document $root $Settings $bridge
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
    'Unprotect-RFMachineApiKey', 'Test-RFMachineTranslationProvider', 'Enable-RFMachineTranslation'
)
