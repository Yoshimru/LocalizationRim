Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:RimWorldAppId = '294100'
$script:RussianPattern = '(?i)(russian|русск|русифик|перевод|(^|[\s._\-\[\(])(ru|rus)([\s._\-\]\)]|$))'
$script:TranslationPattern = '(?i)(translation|language\s*pack|locali[sz]ation|русск|русифик|перевод)'

function Get-RFDefaultConfigPath {
    Join-Path $env:USERPROFILE 'AppData\LocalLow\Ludeon Studios\RimWorld by Ludeon Studios\Config\ModsConfig.xml'
}

function Get-RFSteamPath {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($registryPath in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )) {
        try {
            $value = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
            foreach ($name in @('SteamPath', 'InstallPath')) {
                if ($value.$name) { $candidates.Add([string]$value.$name) }
            }
        } catch {}
    }
    $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam'))
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'Steam')) }
    return $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

function Get-RFWorkshopRoots {
    $steamPath = Get-RFSteamPath
    if (-not $steamPath) { return @() }

    $roots = New-Object System.Collections.Generic.List[string]
    $defaultRoot = Join-Path $steamPath "steamapps\workshop\content\$script:RimWorldAppId"
    if (Test-Path -LiteralPath $defaultRoot) { $roots.Add($defaultRoot) }

    $libraryFile = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $libraryFile) {
        $raw = Get-Content -LiteralPath $libraryFile -Raw -ErrorAction SilentlyContinue
        foreach ($match in [regex]::Matches([string]$raw, '"path"\s+"([^"]+)"')) {
            $library = $match.Groups[1].Value -replace '\\\\', '\'
            $root = Join-Path $library "steamapps\workshop\content\$script:RimWorldAppId"
            if ((Test-Path -LiteralPath $root) -and -not $roots.Contains($root)) { $roots.Add($root) }
        }
    }
    return @($roots.ToArray() | Sort-Object -Unique)
}

function Get-RFAboutPath {
    param([Parameter(Mandatory)][string]$ModPath)
    $direct = Join-Path $ModPath 'About\About.xml'
    if (Test-Path -LiteralPath $direct) { return $direct }
    return Get-ChildItem -LiteralPath $ModPath -Filter 'About.xml' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -ieq 'About' } |
        Select-Object -First 1 -ExpandProperty FullName
}

function Get-RFXmlList {
    param($Node)
    if ($null -eq $Node) { return @() }
    return @($Node.SelectNodes('li') | ForEach-Object {
        $packageNode = $_.SelectSingleNode('packageId')
        if ($packageNode) { ([string]$packageNode.InnerText).Trim() } else { ([string]$_.InnerText).Trim() }
    } | Where-Object { $_ })
}

function Get-RFConditionalModIds {
    param([Parameter(Mandatory)][string]$ModPath)
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($fileName in @('loadFolders.xml', 'LoadFolders.xml')) {
        $loadFoldersPath = Join-Path $ModPath $fileName
        if (-not (Test-Path -LiteralPath $loadFoldersPath)) { continue }
        try {
            [xml]$loadFolders = [IO.File]::ReadAllText($loadFoldersPath, [Text.UTF8Encoding]::new($false))
            foreach ($node in @($loadFolders.SelectNodes('//*[@IfModActive]'))) {
                $raw = [string]$node.Attributes['IfModActive'].Value
                foreach ($id in @($raw -split '[,;\s]+' | Where-Object { $_ })) { $ids.Add($id) }
            }
        } catch {}
    }
    return @($ids | Select-Object -Unique)
}

function Get-RFModMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModPath,
        [string]$WorkshopId = ''
    )
    $aboutPath = Get-RFAboutPath -ModPath $ModPath
    if (-not $aboutPath) { return $null }
    try { [xml]$xml = [IO.File]::ReadAllText($aboutPath, [Text.UTF8Encoding]::new($false)) }
    catch { return $null }
    $meta = $xml.ModMetaData
    if ($null -eq $meta) { return $null }

    $packageNode = $meta.SelectSingleNode('packageId')
    $packageId = if ($packageNode) { ([string]$packageNode.InnerText).Trim() } else { '' }
    if (-not $packageId) { return $null }
    $nameNode = $meta.SelectSingleNode('name')
    $descriptionNode = $meta.SelectSingleNode('description')
    $name = if ($nameNode) { ([string]$nameNode.InnerText).Trim() } else { '' }
    $description = if ($descriptionNode) { [regex]::Replace([string]$descriptionNode.InnerText, '\s+', ' ').Trim() } else { '' }

    $languageRoots = New-Object System.Collections.Generic.List[object]
    $rootLanguages = Join-Path $ModPath 'Languages'
    if (Test-Path -LiteralPath $rootLanguages) { $languageRoots.Add((Get-Item -LiteralPath $rootLanguages)) }
    foreach ($topDirectory in Get-ChildItem -LiteralPath $ModPath -Directory -ErrorAction SilentlyContinue) {
        $nestedLanguages = Join-Path $topDirectory.FullName 'Languages'
        if (Test-Path -LiteralPath $nestedLanguages) { $languageRoots.Add((Get-Item -LiteralPath $nestedLanguages)) }
        foreach ($secondDirectory in Get-ChildItem -LiteralPath $topDirectory.FullName -Directory -ErrorAction SilentlyContinue) {
            $deepLanguages = Join-Path $secondDirectory.FullName 'Languages'
            if (Test-Path -LiteralPath $deepLanguages) { $languageRoots.Add((Get-Item -LiteralPath $deepLanguages)) }
        }
    }
    $languageDirs = @($languageRoots | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue })
    $russianDirs = @($languageDirs | Where-Object { $_.Name -match '(?i)^(russian|рус)' })
    $russianFileCount = 0
    foreach ($directory in $russianDirs) {
        $russianFileCount += @(Get-ChildItem -LiteralPath $directory.FullName -File -Recurse -ErrorAction SilentlyContinue).Count
    }

    $dependencies = @(Get-RFXmlList $meta.SelectSingleNode('modDependencies'))
    $loadAfter = @(Get-RFXmlList $meta.SelectSingleNode('loadAfter'))
    $coveredPackageIds = @(Get-RFConditionalModIds -ModPath $ModPath)
    $identityText = "$packageId $name"
    $looksLikeTranslation = (($identityText -match $script:TranslationPattern) -or ($identityText -match $script:RussianPattern)) -and ($russianDirs.Count -gt 0)

    [pscustomobject]@{
        WorkshopId = [string]$WorkshopId
        PackageId = $packageId
        Name = if ($name) { $name } else { $packageId }
        Path = $ModPath
        AboutPath = $aboutPath
        Description = $description
        Dependencies = $dependencies
        LoadAfter = $loadAfter
        CoveredPackageIds = $coveredPackageIds
        SupportedVersions = @(Get-RFXmlList $meta.SelectSingleNode('supportedVersions'))
        HasBuiltInRussian = ($russianDirs.Count -gt 0)
        RussianFiles = $russianFileCount
        Languages = @($languageDirs | Select-Object -ExpandProperty Name -Unique)
        IsTranslation = $looksLikeTranslation
        InstalledTranslation = ''
        InstalledTranslationId = ''
        InstalledTranslationActive = $false
        Source = 'installed'
        SteamUrl = if ($WorkshopId) { "https://steamcommunity.com/sharedfiles/filedetails/?id=$WorkshopId" } else { '' }
    }
}

function Get-RFInstalledMods {
    [CmdletBinding()]
    param([string[]]$WorkshopRoots = (Get-RFWorkshopRoots))
    $mods = New-Object System.Collections.Generic.List[object]
    foreach ($root in @($WorkshopRoots)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($directory in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
            $mod = Get-RFModMetadata -ModPath $directory.FullName -WorkshopId $directory.Name
            if ($null -ne $mod) { $mods.Add($mod) }
        }
    }
    return $mods.ToArray()
}

function Get-RFActiveMods {
    [CmdletBinding()]
    param(
        [string]$ConfigPath = (Get-RFDefaultConfigPath),
        [string[]]$WorkshopRoots = (Get-RFWorkshopRoots)
    )
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Не найден ModsConfig.xml: $ConfigPath" }
    [xml]$config = [IO.File]::ReadAllText($ConfigPath, [Text.UTF8Encoding]::new($false))
    $activeIds = @($config.ModsConfigData.activeMods.li | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    $activeSet = @{}
    foreach ($id in $activeIds) { if ($id) { $activeSet[$id] = $true } }

    $installed = @(Get-RFInstalledMods -WorkshopRoots $WorkshopRoots)
    $byPackage = @{}
    foreach ($mod in $installed) {
        $key = $mod.PackageId.ToLowerInvariant()
        if (-not $byPackage.ContainsKey($key)) { $byPackage[$key] = $mod }
    }

    $active = New-Object System.Collections.Generic.List[object]
    foreach ($id in $activeIds) {
        if ($byPackage.ContainsKey($id)) {
            $active.Add($byPackage[$id])
        } else {
            $active.Add([pscustomobject]@{
                WorkshopId = ''; PackageId = $id; Name = $id; Path = ''; AboutPath = ''; Description = ''
                Dependencies = @(); LoadAfter = @(); CoveredPackageIds = @(); SupportedVersions = @(); HasBuiltInRussian = $false
                RussianFiles = 0; Languages = @(); IsTranslation = ($id -match $script:RussianPattern)
                InstalledTranslation = ''; InstalledTranslationId = ''; InstalledTranslationActive = $false
                Source = 'missing'; SteamUrl = ''
            })
        }
    }

    $activeByPackage = @{}
    foreach ($mod in $active) { $activeByPackage[$mod.PackageId.ToLowerInvariant()] = $mod }
    # Check every installed language mod, not only enabled ones. This lets the
    # UI distinguish an active translation from one downloaded in Workshop but
    # not currently enabled in ModsConfig.xml.
    foreach ($translation in @($installed | Where-Object { $_.IsTranslation })) {
        $translationIsActive = $activeSet.ContainsKey($translation.PackageId.ToLowerInvariant())
        $targetKeys = @(@($translation.Dependencies) + @($translation.LoadAfter) |
            ForEach-Object { ([string]$_).ToLowerInvariant() } |
            Where-Object { $_ -and $activeByPackage.ContainsKey($_) -and $_ -notmatch '^(ludeon\.|brrainz\.harmony$)' } |
            Select-Object -Unique)
        $conditionalCoverageKeys = @($translation.CoveredPackageIds |
            ForEach-Object { ([string]$_).ToLowerInvariant() } |
            Where-Object { $_ -and $activeByPackage.ContainsKey($_) -and $_ -notmatch '^ludeon\.' } |
            Select-Object -Unique)
        $translationText = Get-RFNormalizedText "$($translation.Name) $($translation.Description) $($translation.PackageId)"
        $nameMatchedKeys = @($targetKeys | Where-Object {
            $targetName = Get-RFNormalizedText $activeByPackage[$_].Name
            $targetName -and $translationText.Contains($targetName)
        })
        $matchedKeys = @(@($conditionalCoverageKeys) + @($nameMatchedKeys) | Select-Object -Unique)
        if ($matchedKeys.Count -eq 0 -and $targetKeys.Count -eq 1) { $matchedKeys = $targetKeys }
        if ($matchedKeys.Count -eq 0) {
            # Some language mods do not declare the original as a dependency or
            # in loadAfter. Infer the relation only from strong identifiers:
            # an identical title after removing "rus"/"Russian", or the
            # original packageId embedded in the translation packageId.
            $translationName = Get-RFNormalizedText $translation.Name
            $translationPackage = $translation.PackageId.ToLowerInvariant()
            $matchedKeys = @($activeByPackage.Keys | Where-Object {
                $candidate = $activeByPackage[$_]
                if ($candidate.IsTranslation -or $candidate -eq $translation) { return $false }
                $candidateName = Get-RFNormalizedText $candidate.Name
                $sameCleanName = $translationName -and $candidateName -and $translationName -eq $candidateName
                $packageInsideTranslation = $_.Length -ge 6 -and $translationPackage.Contains($_)
                return $sameCleanName -or $packageInsideTranslation
            })
        }
        if ($matchedKeys.Count -eq 0) {
            # Last-resort title comparison for translations such as
            # "Rus [NL] Facial Animation" vs "[NL] Facial Animation - WIP".
            # Require almost identical sets of meaningful words so similarly
            # named add-ons and compatibility patches are not linked.
            $nameStopWords = @('mod', 'wip', 'continued', 'forked', 'unofficial', 'language', 'pack')
            $translationTokens = @(($translationName -split ' ') |
                Where-Object { $_.Length -ge 3 -and $nameStopWords -notcontains $_ } |
                Select-Object -Unique)
            if ($translationTokens.Count -ge 2) {
                $matchedKeys = @($activeByPackage.Keys | Where-Object {
                    $candidate = $activeByPackage[$_]
                    if ($candidate.IsTranslation -or $candidate -eq $translation) { return $false }
                    $candidateTokens = @((Get-RFNormalizedText $candidate.Name) -split ' ' |
                        Where-Object { $_.Length -ge 3 -and $nameStopWords -notcontains $_ } |
                        Select-Object -Unique)
                    if ($candidateTokens.Count -lt 2) { return $false }
                    $common = @($translationTokens | Where-Object { $candidateTokens -contains $_ }).Count
                    $largest = [Math]::Max($translationTokens.Count, $candidateTokens.Count)
                    return $common -ge 2 -and ($common / $largest) -ge 0.85
                })
            }
        }
        foreach ($key in $matchedKeys) {
            $target = $activeByPackage[$key]
            # Prefer an enabled translation if several installed candidates
            # point to the same original.
            if (-not $target.InstalledTranslation -or ($translationIsActive -and -not $target.InstalledTranslationActive)) {
                $target.InstalledTranslation = $translation.Name
                $target.InstalledTranslationId = $translation.WorkshopId
                $target.InstalledTranslationActive = $translationIsActive
            }
        }
    }
    return $active.ToArray()
}

function Get-RFWorkshopDetails {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$WorkshopIds)
    if ($WorkshopIds.Count -eq 0) { return @() }
    $pairs = New-Object System.Collections.Generic.List[string]
    $pairs.Add('itemcount=' + $WorkshopIds.Count)
    for ($index = 0; $index -lt $WorkshopIds.Count; $index++) {
        $pairs.Add(('publishedfileids%5B{0}%5D={1}' -f $index, [uri]::EscapeDataString($WorkshopIds[$index])))
    }
    $body = $pairs -join '&'
    Add-Type -AssemblyName System.Net.Http
    $client = New-RFHttpClient
    try {
        $content = New-Object System.Net.Http.ByteArrayContent(, [Text.Encoding]::ASCII.GetBytes($body))
        $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/x-www-form-urlencoded')
        $httpResponse = $client.PostAsync('https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/', $content).GetAwaiter().GetResult()
        $httpResponse.EnsureSuccessStatusCode() | Out-Null
        $bytes = $httpResponse.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $response = ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
        return @($response.response.publishedfiledetails)
    } finally {
        $client.Dispose()
    }
}

function Get-RFModByWorkshopId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkshopId,
        [string[]]$WorkshopRoots = (Get-RFWorkshopRoots)
    )
    $id = ([regex]::Match($WorkshopId, '\d{6,}')).Value
    if (-not $id) { throw 'Укажите ссылку Steam Workshop или числовой Workshop ID.' }
    foreach ($root in @($WorkshopRoots)) {
        $path = Join-Path $root $id
        if (Test-Path -LiteralPath $path) {
            $installed = Get-RFModMetadata -ModPath $path -WorkshopId $id
            if ($installed) { return $installed }
        }
    }
    $details = @(Get-RFWorkshopDetails -WorkshopIds @($id)) | Select-Object -First 1
    if (-not $details -or [int]$details.result -ne 1) { throw "Steam Workshop не вернул данные для ID $id." }
    $detailTags = @($details.tags | ForEach-Object { [string]$_.tag })
    $detailIdentity = "$($details.title) $($details.description)"
    return [pscustomobject]@{
        WorkshopId = $id; PackageId = ''; Name = [string]$details.title; Path = ''; AboutPath = ''
        Description = [string]$details.description; Dependencies = @(); LoadAfter = @(); CoveredPackageIds = @()
        SupportedVersions = @($detailTags | Where-Object { $_ -match '^1\.\d+$' })
        HasBuiltInRussian = $false; RussianFiles = 0; Languages = @()
        IsTranslation = (($detailTags -match '(?i)^Translation$') -and ($detailIdentity -match $script:RussianPattern))
        InstalledTranslation = ''; InstalledTranslationId = ''; InstalledTranslationActive = $false; Source = 'steam';
        SteamUrl = "https://steamcommunity.com/sharedfiles/filedetails/?id=$id"
    }
}

function ConvertFrom-RFHtmlText {
    param([AllowNull()][string]$Text)
    if (-not $Text) { return '' }
    $withoutTags = [regex]::Replace($Text, '<[^>]+>', ' ')
    return [regex]::Replace([System.Net.WebUtility]::HtmlDecode($withoutTags), '\s+', ' ').Trim()
}

function Add-RFJsonResults {
    param(
        $Node,
        [System.Collections.Generic.List[object]]$Output,
        [System.Collections.Generic.HashSet[string]]$Seen
    )
    if ($null -eq $Node) { return }
    if ($Node -is [string]) {
        $text = [string]$Node
        if (($text.StartsWith('{') -and $text.EndsWith('}')) -or ($text.StartsWith('[') -and $text.EndsWith(']'))) {
            try { Add-RFJsonResults -Node ($text | ConvertFrom-Json) -Output $Output -Seen $Seen } catch {}
        }
        return
    }
    if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [pscustomobject])) {
        foreach ($item in $Node) { Add-RFJsonResults -Node $item -Output $Output -Seen $Seen }
        return
    }
    if (-not ($Node -is [psobject])) { return }

    $resultsProperty = $Node.PSObject.Properties['results']
    if ($resultsProperty -and $resultsProperty.Value) {
        foreach ($item in @($resultsProperty.Value)) {
            $id = [string]$item.publishedfileid
            if (-not $id -or -not $Seen.Add($id)) { continue }
            $tags = @($item.tags | ForEach-Object { if ($_.display_name) { [string]$_.display_name } else { [string]$_.tag } })
            $Output.Add([pscustomobject]@{
                WorkshopId = $id
                Title = ConvertFrom-RFHtmlText ([string]$item.title)
                Description = ConvertFrom-RFHtmlText ([string]$item.short_description)
                Tags = $tags
                Updated = [long]$item.time_updated
                Url = "https://steamcommunity.com/sharedfiles/filedetails/?id=$id"
            })
        }
    }
    foreach ($property in $Node.PSObject.Properties) {
        if ($property.Name -ne 'results') { Add-RFJsonResults -Node $property.Value -Output $Output -Seen $Seen }
    }
}

function ConvertFrom-RFWorkshopSearchHtml {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Html)
    $match = [regex]::Match($Html, '<script[^>]*id=["'']valve-ssr-data["''][^>]*>(.*?)</script>', 'Singleline,IgnoreCase')
    if (-not $match.Success) { return @() }
    try { $root = $match.Groups[1].Value | ConvertFrom-Json }
    catch { return @() }
    $output = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    Add-RFJsonResults -Node $root -Output $output -Seen $seen
    return $output.ToArray()
}

function Get-RFNormalizedText {
    param([AllowNull()][string]$Text)
    $value = ([string]$Text).ToLowerInvariant()
    $value = [regex]::Replace($value, $script:RussianPattern, ' ')
    $value = [regex]::Replace($value, '(?i)language\s*pack|translation|locali[sz]ation', ' ')
    $value = [regex]::Replace($value, '[^a-zа-яё0-9]+', ' ')
    return [regex]::Replace($value, '\s+', ' ').Trim()
}

function Get-RFCandidateScore {
    param($Source, $Candidate)
    $sourceName = Get-RFNormalizedText $Source.Name
    $sourcePackage = Get-RFNormalizedText (($Source.PackageId -replace '\.', ' '))
    $title = Get-RFNormalizedText $Candidate.Title
    $allTextRaw = "$($Candidate.Title) $($Candidate.Description)"
    $allText = Get-RFNormalizedText $allTextRaw
    $tags = @($Candidate.Tags)
    $score = 0
    $reasons = New-Object System.Collections.Generic.List[string]

    if ($tags -match '(?i)^Translation$') { $score += 25; $reasons.Add('тег Translation') }
    if ($allTextRaw -match $script:RussianPattern) { $score += 20; $reasons.Add('русский перевод') }
    if ($Source.WorkshopId -and $Candidate.Description -match [regex]::Escape($Source.WorkshopId)) {
        $score += 140; $reasons.Add('ссылка на оригинал')
    }
    if ($Source.PackageId -and $Candidate.Description -match [regex]::Escape($Source.PackageId)) {
        $score += 100; $reasons.Add('packageId оригинала')
    }
    if ($sourceName -and $title -eq $sourceName) { $score += 150; $reasons.Add('точное название') }
    elseif ($sourceName -and $title.Contains($sourceName)) { $score += 115; $reasons.Add('название в заголовке') }
    elseif ($sourceName -and $allText.Contains($sourceName)) { $score += 20; $reasons.Add('название в описании') }

    $stopWords = @('mod','rimworld','expanded','expansion','faction','race','framework','continued','forked','the','and','for','with')
    $tokens = @($sourceName.Split(' ') | Where-Object { $_.Length -ge 3 -and $stopWords -notcontains $_ } | Select-Object -Unique)
    $matched = @($tokens | Where-Object { $allText -match ('(^| )' + [regex]::Escape($_) + '( |$)') })
    if ($tokens.Count -gt 0) {
        $coverage = $matched.Count / $tokens.Count
        $score += [int](45 * $coverage)
        if ($matched.Count -gt 0) { $reasons.Add("совпало слов: $($matched.Count)/$($tokens.Count)") }
    }
    [pscustomobject]@{ Score = $score; Reasons = @($reasons) }
}

function New-RFHttpClient {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('Mozilla/5.0 (Windows NT 10.0; Win64; x64) RussifierFinder/1.0')
    return $client
}

function Get-RFSearchUrl {
    param($Source)
    $searchName = if ($Source.Name -and $Source.Name -notmatch '[�]') { $Source.Name } else { $Source.PackageId }
    $query = "$searchName Russian"
    return 'https://steamcommunity.com/workshop/browse/?appid=294100&searchtext=' + [uri]::EscapeDataString($query) + '&browsesort=textsearch&section=items&numperpage=30&l=english'
}

function Find-RFRussifiers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Mods,
        [ValidateRange(1, 16)][int]$Concurrency = 6,
        [ValidateRange(1, 20)][int]$MaxCandidates = 5,
        [ValidateRange(0, 500)][int]$MinimumScore = 120,
        [switch]$IncludeWithRussian,
        [scriptblock]$OnProgress
    )
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $allMods = @($Mods)
    $searchable = @($allMods | Where-Object {
        -not $_.IsTranslation -and $_.Name -and
        $_.Source -ne 'missing' -and
        ($IncludeWithRussian -or (-not $_.HasBuiltInRussian -and -not $_.InstalledTranslation))
    })
    $resultMap = @{}
    foreach ($mod in $allMods) {
        $key = if ($mod.WorkshopId) { "w:$($mod.WorkshopId)" } else { "p:$($mod.PackageId)" }
        if ($mod.IsTranslation) {
            $resultMap[$key] = [pscustomobject]@{ Mod = $mod; Status = 'Это русификатор'; SearchUrl = ''; Candidates = @(); Error = '' }
        } elseif ($mod.Source -eq 'missing') {
            $resultMap[$key] = [pscustomobject]@{ Mod = $mod; Status = 'Файлы мода не найдены'; SearchUrl = ''; Candidates = @(); Error = '' }
        } elseif ($mod.InstalledTranslation -and -not $IncludeWithRussian) {
            $translationStatus = if ($mod.InstalledTranslationActive) { 'Уже активен' } else { 'Установлен, но не активен' }
            $resultMap[$key] = [pscustomobject]@{ Mod = $mod; Status = "${translationStatus}: $($mod.InstalledTranslation)"; SearchUrl = ''; Candidates = @(); Error = '' }
        } elseif ($mod.HasBuiltInRussian -and -not $IncludeWithRussian) {
            $resultMap[$key] = [pscustomobject]@{ Mod = $mod; Status = 'Русский встроен'; SearchUrl = ''; Candidates = @(); Error = '' }
        }
    }

    $client = New-RFHttpClient
    $pending = New-Object System.Collections.Queue
    foreach ($mod in $searchable) { $pending.Enqueue($mod) }
    $running = New-Object System.Collections.Generic.List[object]
    $rawBySource = @{}
    $completed = 0
    try {
        while ($pending.Count -gt 0 -or $running.Count -gt 0) {
            while ($pending.Count -gt 0 -and $running.Count -lt $Concurrency) {
                $mod = $pending.Dequeue()
                $url = Get-RFSearchUrl $mod
                $running.Add([pscustomobject]@{ Mod = $mod; Url = $url; Task = $client.GetStringAsync($url) })
            }
            $tasks = [System.Threading.Tasks.Task[]]@($running | ForEach-Object { $_.Task })
            $finishedIndex = [System.Threading.Tasks.Task]::WaitAny($tasks)
            $entry = $running[$finishedIndex]
            $running.RemoveAt($finishedIndex)
            $sourceKey = if ($entry.Mod.WorkshopId) { "w:$($entry.Mod.WorkshopId)" } else { "p:$($entry.Mod.PackageId)" }
            try {
                $html = $entry.Task.GetAwaiter().GetResult()
                $parsed = @(ConvertFrom-RFWorkshopSearchHtml -Html $html)
                $rawBySource[$sourceKey] = @($parsed | Where-Object {
                    $_.WorkshopId -ne $entry.Mod.WorkshopId -and
                    (($_.Tags -match '(?i)^Translation$') -or ("$($_.Title) $($_.Description)" -match $script:TranslationPattern)) -and
                    ("$($_.Title) $($_.Description)" -match $script:RussianPattern)
                } | Select-Object -First 15)
                $resultMap[$sourceKey] = [pscustomobject]@{ Mod = $entry.Mod; Status = 'Поиск завершён'; SearchUrl = $entry.Url; Candidates = @(); Error = '' }
            } catch {
                $rawBySource[$sourceKey] = @()
                $resultMap[$sourceKey] = [pscustomobject]@{ Mod = $entry.Mod; Status = 'Ошибка Steam'; SearchUrl = $entry.Url; Candidates = @(); Error = $_.Exception.Message }
            }
            $completed++
            if ($OnProgress) { & $OnProgress $completed $searchable.Count $entry.Mod.Name }
        }
    } finally {
        $client.Dispose()
    }

    $candidateIds = @($rawBySource.Values | ForEach-Object { $_ } | Select-Object -ExpandProperty WorkshopId -Unique)
    $detailsById = @{}
    for ($offset = 0; $offset -lt $candidateIds.Count; $offset += 100) {
        $last = [Math]::Min($offset + 99, $candidateIds.Count - 1)
        if ($last -lt $offset) { break }
        $chunk = @($candidateIds[$offset..$last])
        try {
            foreach ($detail in @(Get-RFWorkshopDetails -WorkshopIds $chunk)) {
                if ([int]$detail.result -eq 1) { $detailsById[[string]$detail.publishedfileid] = $detail }
            }
        } catch {}
    }

    foreach ($sourceKey in @($rawBySource.Keys)) {
        $record = $resultMap[$sourceKey]
        $scored = New-Object System.Collections.Generic.List[object]
        foreach ($rawCandidate in @($rawBySource[$sourceKey])) {
            $detail = $detailsById[$rawCandidate.WorkshopId]
            $candidate = if ($detail) {
                [pscustomobject]@{
                    WorkshopId = [string]$detail.publishedfileid
                    Title = ConvertFrom-RFHtmlText ([string]$detail.title)
                    Description = ConvertFrom-RFHtmlText ([string]$detail.description)
                    Tags = @($detail.tags | ForEach-Object { [string]$_.tag })
                    Updated = [long]$detail.time_updated
                    Url = "https://steamcommunity.com/sharedfiles/filedetails/?id=$($detail.publishedfileid)"
                }
            } else { $rawCandidate }
            $rating = Get-RFCandidateScore -Source $record.Mod -Candidate $candidate
            if ($rating.Score -ge $MinimumScore) {
                $scored.Add([pscustomobject]@{
                    WorkshopId = $candidate.WorkshopId; Title = $candidate.Title; Url = $candidate.Url
                    Score = $rating.Score; Reasons = @($rating.Reasons); Tags = @($candidate.Tags)
                    Versions = @($candidate.Tags | Where-Object { $_ -match '^1\.\d+$' })
                    Updated = $candidate.Updated
                })
            }
        }
        $record.Candidates = @($scored | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Updated'; Descending = $true } | Select-Object -First $MaxCandidates)
        if ($record.Status -ne 'Ошибка Steam') {
            $record.Status = if ($record.Candidates.Count -gt 0) { "Найдено: $($record.Candidates.Count)" } else { 'Не найдено' }
        }
    }

    $ordered = New-Object System.Collections.Generic.List[object]
    foreach ($mod in $allMods) {
        $key = if ($mod.WorkshopId) { "w:$($mod.WorkshopId)" } else { "p:$($mod.PackageId)" }
        if ($resultMap.ContainsKey($key)) { $ordered.Add($resultMap[$key]) }
    }
    return $ordered.ToArray()
}

function Get-RFRimSortSteamworksPath {
    $candidates = @(
        (Join-Path $env:USERPROFILE 'Desktop\RimSort'),
        (Join-Path $env:USERPROFILE 'AppData\Local\RimSort'),
        $PSScriptRoot
    )
    foreach ($directory in $candidates) {
        if ((Test-Path -LiteralPath (Join-Path $directory 'SteamworksPy64.dll')) -and
            (Test-Path -LiteralPath (Join-Path $directory 'steam_api64.dll')) -and
            (Test-Path -LiteralPath (Join-Path $directory 'steam_appid.txt'))) {
            return $directory
        }
    }
    throw 'Не найдены SteamworksPy64.dll и steam_api64.dll. Установите или распакуйте RimSort на рабочий стол.'
}

function Initialize-RFSteamNative {
    param([Parameter(Mandatory)][string]$SteamworksPath)
    if (-not ('RFSteamNative' -as [type])) {
        $dllPath = (Join-Path $SteamworksPath 'SteamworksPy64.dll').Replace('"', '""')
        $source = @"
using System;
using System.Runtime.InteropServices;
public static class RFSteamNative {
    [DllImport(@"$dllPath", CallingConvention = CallingConvention.Cdecl)] public static extern int SteamInit();
    [DllImport(@"$dllPath", CallingConvention = CallingConvention.Cdecl)] public static extern void SteamShutdown();
    [DllImport(@"$dllPath", CallingConvention = CallingConvention.Cdecl)] public static extern void RunCallbacks();
    [DllImport(@"$dllPath", CallingConvention = CallingConvention.Cdecl)] public static extern uint Workshop_GetNumSubscribedItems();
    [DllImport(@"$dllPath", CallingConvention = CallingConvention.Cdecl)] public static extern uint Workshop_GetItemState(ulong publishedFileId);
    [DllImport(@"$dllPath", CallingConvention = CallingConvention.Cdecl)] public static extern void Workshop_SubscribeItem(ulong publishedFileId);
}
"@
        Add-Type -TypeDefinition $source -Language CSharp
    }
    $status = [RFSteamNative]::SteamInit()
    switch ($status) {
        0 { return }
        2 { throw 'Steam не запущен.' }
        3 { throw 'Steam не подключён или пользователь не вошёл в аккаунт.' }
        default { throw "Не удалось инициализировать Steamworks (код $status)." }
    }
}

function Install-RFTranslations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$WorkshopIds,
        [string]$ConfigPath = (Get-RFDefaultConfigPath),
        [string[]]$WorkshopRoots = (Get-RFWorkshopRoots),
        [ValidateRange(10, 900)][int]$DownloadTimeoutSeconds = 240,
        [switch]$KeepRimSortOpen,
        [scriptblock]$OnProgress
    )
    $ids = @($WorkshopIds | ForEach-Object { ([regex]::Match([string]$_, '\d{6,}')).Value } | Where-Object { $_ } | Select-Object -Unique)
    if ($ids.Count -eq 0) { throw 'Не выбраны корректные Workshop ID.' }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Не найден ModsConfig.xml: $ConfigPath" }
    if (@($WorkshopRoots | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) { throw 'Не найдена папка Workshop RimWorld.' }

    $rimWorld = @(Get-Process -Name 'RimWorldWin64', 'RimWorld' -ErrorAction SilentlyContinue)
    if ($rimWorld.Count -gt 0) { throw 'Закройте RimWorld перед изменением ModsConfig.xml.' }
    if (-not $KeepRimSortOpen) {
        $rimSort = @(Get-Process -Name 'RimSort' -ErrorAction SilentlyContinue)
        foreach ($process in $rimSort) {
            $null = $process.CloseMainWindow()
            if (-not $process.WaitForExit(10000)) { throw 'Закройте RimSort и повторите установку.' }
        }
    }

    $steamworksPath = Get-RFRimSortSteamworksPath
    $oldCurrentDirectory = [Environment]::CurrentDirectory
    $initialized = $false
    $alreadySubscribed = New-Object System.Collections.Generic.List[string]
    $newlySubscribed = New-Object System.Collections.Generic.List[string]
    $subscriptionFailed = New-Object System.Collections.Generic.List[string]
    try {
        [Environment]::CurrentDirectory = $steamworksPath
        Initialize-RFSteamNative -SteamworksPath $steamworksPath
        $initialized = $true
        $index = 0
        foreach ($id in $ids) {
            $index++
            $state = [RFSteamNative]::Workshop_GetItemState([uint64]$id)
            if (($state -band 1) -ne 0) {
                $alreadySubscribed.Add($id)
            } else {
                [RFSteamNative]::Workshop_SubscribeItem([uint64]$id)
            }
            [RFSteamNative]::RunCallbacks()
            if ($OnProgress) { & $OnProgress 'subscribe' $index $ids.Count "Подписка: $id" }
        }

        $subscribeDeadline = [DateTime]::UtcNow.AddSeconds(45)
        $pendingSubscription = @($ids | Where-Object { $alreadySubscribed -notcontains $_ })
        while ($pendingSubscription.Count -gt 0 -and [DateTime]::UtcNow -lt $subscribeDeadline) {
            [RFSteamNative]::RunCallbacks()
            foreach ($id in @($pendingSubscription)) {
                $state = [RFSteamNative]::Workshop_GetItemState([uint64]$id)
                if (($state -band 1) -ne 0) { $newlySubscribed.Add($id) }
            }
            $pendingSubscription = @($pendingSubscription | Where-Object { $newlySubscribed -notcontains $_ })
            if ($pendingSubscription.Count -gt 0) { Start-Sleep -Milliseconds 250 }
        }
        foreach ($id in $pendingSubscription) { $subscriptionFailed.Add($id) }
    } finally {
        if ($initialized) { [RFSteamNative]::SteamShutdown() }
        [Environment]::CurrentDirectory = $oldCurrentDirectory
    }

    $subscribed = @($alreadySubscribed.ToArray()) + @($newlySubscribed.ToArray())
    $downloaded = New-Object System.Collections.Generic.List[object]
    $pendingDownloads = @($subscribed)
    $downloadDeadline = [DateTime]::UtcNow.AddSeconds($DownloadTimeoutSeconds)
    while ($pendingDownloads.Count -gt 0 -and [DateTime]::UtcNow -lt $downloadDeadline) {
        foreach ($id in @($pendingDownloads)) {
            $modPath = $null
            foreach ($root in $WorkshopRoots) {
                $candidatePath = Join-Path $root $id
                if (Test-Path -LiteralPath $candidatePath) { $modPath = $candidatePath; break }
            }
            if (-not $modPath) { continue }
            $metadata = Get-RFModMetadata -ModPath $modPath -WorkshopId $id
            if ($metadata -and $metadata.HasBuiltInRussian) { $downloaded.Add($metadata) }
        }
        $downloadedIds = @($downloaded | Select-Object -ExpandProperty WorkshopId -Unique)
        $pendingDownloads = @($pendingDownloads | Where-Object { $downloadedIds -notcontains $_ })
        if ($OnProgress) { & $OnProgress 'download' $downloadedIds.Count $subscribed.Count "Загружено: $($downloadedIds.Count)/$($subscribed.Count)" }
        if ($pendingDownloads.Count -gt 0) { Start-Sleep -Seconds 1 }
    }

    [xml]$config = [IO.File]::ReadAllText($ConfigPath, [Text.UTF8Encoding]::new($false))
    $activeBefore = @($config.ModsConfigData.activeMods.li | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    $toAdd = @($downloaded | Where-Object { $activeBefore -notcontains $_.PackageId.ToLowerInvariant() })
    $alreadyActive = @($downloaded | Where-Object { $activeBefore -contains $_.PackageId.ToLowerInvariant() })
    $backupPath = ''
    if ($toAdd.Count -gt 0) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupPath = Join-Path (Split-Path -Parent $ConfigPath) "ModsConfig.before-russifier-finder.$timestamp.xml"
        Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -ErrorAction Stop
        try {
            $raw = [IO.File]::ReadAllText($ConfigPath, [Text.UTF8Encoding]::new($false))
            $lines = @($toAdd | ForEach-Object { '    <li>' + [Security.SecurityElement]::Escape($_.PackageId.ToLowerInvariant()) + '</li>' })
            $block = ($lines -join "`r`n") + "`r`n"
            $updated = [regex]::Replace($raw, '(?m)^(\s*</activeMods>)', { param($match) $block + $match.Groups[1].Value }, 1)
            if ($updated -eq $raw) { throw 'Не найден закрывающий тег activeMods.' }
            [IO.File]::WriteAllText($ConfigPath, $updated, [Text.UTF8Encoding]::new($false))
            [xml]$verify = [IO.File]::ReadAllText($ConfigPath, [Text.UTF8Encoding]::new($false))
            $activeAfter = @($verify.ModsConfigData.activeMods.li | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
            $missingPackages = @($toAdd | Where-Object { $activeAfter -notcontains $_.PackageId.ToLowerInvariant() })
            if ($missingPackages.Count -gt 0) { throw "Проверка конфига не пройдена: $($missingPackages.PackageId -join ', ')" }
        } catch {
            Copy-Item -LiteralPath $backupPath -Destination $ConfigPath -Force
            throw "Не удалось обновить ModsConfig.xml; резервная копия восстановлена. $($_.Exception.Message)"
        }
    }

    $failed = New-Object System.Collections.Generic.List[object]
    foreach ($id in $subscriptionFailed) { $failed.Add([pscustomobject]@{ WorkshopId = $id; Reason = 'Steam не подтвердил подписку' }) }
    foreach ($id in $pendingDownloads) { $failed.Add([pscustomobject]@{ WorkshopId = $id; Reason = 'Файлы не загрузились за отведённое время' }) }
    [pscustomobject]@{
        Kind = 'InstallResult'
        Requested = $ids
        AlreadySubscribed = $alreadySubscribed.ToArray()
        NewlySubscribed = $newlySubscribed.ToArray()
        Downloaded = @($downloaded | Select-Object WorkshopId, PackageId, Name -Unique)
        Added = @($toAdd | Select-Object WorkshopId, PackageId, Name)
        AlreadyActive = @($alreadyActive | Select-Object WorkshopId, PackageId, Name)
        Failed = $failed.ToArray()
        BackupPath = $backupPath
    }
}

function Export-RFReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][string]$Path
    )
    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -eq '.json') {
        $Results | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
        return
    }
    if ($extension -eq '.csv') {
        $rows = foreach ($result in $Results) {
            if ($result.Candidates.Count -eq 0) {
                [pscustomobject]@{ Mod = $result.Mod.Name; PackageId = $result.Mod.PackageId; Status = $result.Status; Russifier = ''; Score = ''; Versions = ''; Url = $result.SearchUrl }
            } else {
                foreach ($candidate in $result.Candidates) {
                    [pscustomobject]@{ Mod = $result.Mod.Name; PackageId = $result.Mod.PackageId; Status = $result.Status; Russifier = $candidate.Title; Score = $candidate.Score; Versions = ($candidate.Versions -join ', '); Url = $candidate.Url }
                }
            }
        }
        $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
        return
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Русификаторы RimWorld</title>')
    $lines.Add('<style>body{font:15px Segoe UI,Arial,sans-serif;max-width:1200px;margin:32px auto;padding:0 20px;color:#202124}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ddd;padding:8px;text-align:left;vertical-align:top}th{background:#f3f4f6}tr:nth-child(even){background:#fafafa}.ok{color:#137333}.muted{color:#666}a{color:#065fd4}</style></head><body>')
    $lines.Add('<h1>Русификаторы для сборки RimWorld</h1>')
    $lines.Add('<p class="muted">Создано: ' + [System.Net.WebUtility]::HtmlEncode((Get-Date).ToString('yyyy-MM-dd HH:mm')) + '</p>')
    $lines.Add('<table><thead><tr><th>Мод</th><th>Статус</th><th>Русификатор</th><th>Совпадение</th><th>Версии</th><th>Ссылка</th></tr></thead><tbody>')
    foreach ($result in $Results) {
        $modName = [System.Net.WebUtility]::HtmlEncode([string]$result.Mod.Name)
        $status = [System.Net.WebUtility]::HtmlEncode([string]$result.Status)
        if ($result.Candidates.Count -eq 0) {
            $urlCell = if ($result.SearchUrl) { '<a href="' + [System.Net.WebUtility]::HtmlEncode($result.SearchUrl) + '">Ручной поиск</a>' } else { '' }
            $lines.Add("<tr><td>$modName</td><td>$status</td><td></td><td></td><td></td><td>$urlCell</td></tr>")
        } else {
            foreach ($candidate in $result.Candidates) {
                $title = [System.Net.WebUtility]::HtmlEncode([string]$candidate.Title)
                $url = [System.Net.WebUtility]::HtmlEncode([string]$candidate.Url)
                $versions = [System.Net.WebUtility]::HtmlEncode(($candidate.Versions -join ', '))
                $lines.Add(('<tr><td>{0}</td><td class="ok">{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td><a href="{5}">Steam Workshop</a></td></tr>' -f $modName, $status, $title, $candidate.Score, $versions, $url))
            }
        }
    }
    $lines.Add('</tbody></table></body></html>')
    [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($false))
}

Export-ModuleMember -Function @(
    'Get-RFDefaultConfigPath', 'Get-RFWorkshopRoots', 'Get-RFModMetadata', 'Get-RFInstalledMods',
    'Get-RFActiveMods', 'Get-RFModByWorkshopId', 'ConvertFrom-RFWorkshopSearchHtml',
    'Get-RFCandidateScore', 'Find-RFRussifiers', 'Install-RFTranslations', 'Export-RFReport'
)
