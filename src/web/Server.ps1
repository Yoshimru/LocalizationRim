param(
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$Token,
    [Parameter(Mandatory)][string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try{[Diagnostics.Process]::GetCurrentProcess().PriorityClass='AboveNormal'}catch{}
try {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class RFPowerThrottling {
    [StructLayout(LayoutKind.Sequential)] public struct State { public uint Version; public uint ControlMask; public uint StateMask; }
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetProcessInformation(IntPtr hProcess, int infoClass, ref State state, int size);
    public static void Disable() {
        var state = new State { Version = 1, ControlMask = 1, StateMask = 0 };
        SetProcessInformation(Process.GetCurrentProcess().Handle, 4, ref state, Marshal.SizeOf(typeof(State)));
    }
}
'@
    [RFPowerThrottling]::Disable()
} catch {}
$srcRoot = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $srcRoot 'modules\RussifierFinder.Core.psm1'
$machinePath = Join-Path $srcRoot 'modules\MachineTranslation.psm1'
Import-Module $corePath -Force
Import-Module $machinePath -Force

$script:mods = @()
$script:results = @()
$script:configPath = Get-RFDefaultConfigPath
$roots = @(Get-RFWorkshopRoots)
$script:workshopRoot = if ($roots.Count) { $roots[0] } else { '' }
$script:running = $true
$webRoot = Join-Path $ProjectRoot 'web'

function Get-ModCategory($mod) {
    if ($mod.Source -eq 'missing') { return 'Файлы не найдены' }
    if ($mod.IsTranslation) { return 'Русификаторы' }
    if ($mod.IsLocalization) { return 'Локализаторы других языков' }
    if ($mod.InstalledTranslation) {
        if ($mod.InstalledTranslationActive) { return 'Русификатор активен' }
        return 'Русификатор установлен (не активен)'
    }
    if ($mod.HasBuiltInRussian) { return 'Встроенный русский' }
    if ($mod.TranslationNotRequired) { return 'Перевод не требуется' }
    return 'Нужен поиск'
}

function Get-ModState($mod) {
    $category = Get-ModCategory $mod
    if ($category -eq 'Русификатор активен') { return "Активен: $($mod.InstalledTranslation)" }
    if ($category -eq 'Русификатор установлен (не активен)') { return "Установлен, но выключен: $($mod.InstalledTranslation)" }
    if ($category -eq 'Встроенный русский') { return 'Русский встроен' }
    if ($category -eq 'Русификаторы') { return 'Русификатор' }
    if ($category -eq 'Локализаторы других языков') { return 'Локализатор: ' + (@($mod.LocalizationLanguages) -join ', ') }
    if ($category -eq 'Перевод не требуется') { return 'Визуальный или совместимый патч без пользовательского текста' }
    return $category
}

function Convert-ModDto($mod) {
    [pscustomobject]@{
        name = [string]$mod.Name; packageId = [string]$mod.PackageId; workshopId = [string]$mod.WorkshopId
        steamUrl = [string]$mod.SteamUrl; category = Get-ModCategory $mod; state = Get-ModState $mod
        needsSearch = (Get-ModCategory $mod) -eq 'Нужен поиск'
        canActivate = [bool]($mod.InstalledTranslation -and -not $mod.InstalledTranslationActive -and $mod.InstalledTranslationId)
        installedTranslationId = [string]$mod.InstalledTranslationId
    }
}

function Convert-ResultDto($result) {
    $category = if (@($result.Candidates).Count) { 'Найден перевод' }
        elseif ($result.Status -eq 'Не найдено') { 'Перевод не найден' }
        elseif ($result.Status -match '^Ошибка') { 'Ошибка поиска' }
        elseif ($result.Status -match '^Уже активен') { 'Русификатор активен' }
        elseif ($result.Status -match '^Установлен, но не активен') { 'Русификатор установлен' }
        elseif ($result.Status -eq 'Русский встроен') { 'Встроенный русский' }
        elseif ($result.Status -eq 'Это русификатор') { 'Языковой мод' }
        elseif ($result.Status -match '^Локализатор:') { 'Другой локализатор' }
        elseif ($result.Status -eq 'Перевод не требуется') { 'Перевод не требуется' }
        elseif ($result.Status -eq 'Файлы мода не найдены') { 'Файлы не найдены' }
        else { [string]$result.Status }
    [pscustomobject]@{
        packageId = [string]$result.Mod.PackageId; mod = [string]$result.Mod.Name
        status = [string]$result.Status; category = $category; searchUrl = [string]$result.SearchUrl
        candidates = @($result.Candidates | ForEach-Object {
            [pscustomobject]@{ workshopId=[string]$_.WorkshopId; title=[string]$_.Title; url=[string]$_.Url; score=[int]$_.Score; versions=@($_.Versions) }
        })
    }
}

function Read-Body($request) {
    $reader = New-Object IO.StreamReader($request.InputStream, $request.ContentEncoding)
    try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if (-not $raw) { return [pscustomobject]@{} }
    return $raw | ConvertFrom-Json
}

function Send-Json($context, $value, [int]$status = 200) {
    $json = $value | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $context.Response.StatusCode = $status; $context.Response.ContentType = 'application/json; charset=utf-8'
    $context.Response.ContentLength64 = $bytes.Length
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length); $context.Response.Close()
}

function Start-EventStream($context) {
    $context.Response.StatusCode = 200
    $context.Response.ContentType = 'application/x-ndjson; charset=utf-8'
    $context.Response.SendChunked = $true
    $context.Response.KeepAlive = $true
}

function Write-Event($context, $value) {
    $json = ($value | ConvertTo-Json -Depth 12 -Compress) + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Close-EventStream($context) {
    try { $context.Response.OutputStream.Close() } catch {}
    try { $context.Response.Close() } catch {}
}

function Send-File($context, [string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { $context.Response.StatusCode=404; $context.Response.Close(); return }
    $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
    $context.Response.ContentType = switch ($ext) { '.html' {'text/html; charset=utf-8'} '.css' {'text/css; charset=utf-8'} '.js' {'application/javascript; charset=utf-8'} default {'application/octet-stream'} }
    $bytes = [IO.File]::ReadAllBytes($path); $context.Response.ContentLength64=$bytes.Length
    $context.Response.OutputStream.Write($bytes,0,$bytes.Length); $context.Response.Close()
}

function Get-StateDto {
    $categories = @($script:mods | Group-Object { Get-ModCategory $_ } | ForEach-Object { [pscustomobject]@{ name=$_.Name; count=$_.Count } })
    [pscustomobject]@{
        configPath=$script:configPath; workshopRoot=$script:workshopRoot
        mods=@($script:mods | ForEach-Object { Convert-ModDto $_ })
        results=@($script:results | ForEach-Object { Convert-ResultDto $_ })
        categories=$categories
    }
}

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
try {
    while ($script:running) {
        $context = $listener.GetContext(); $request=$context.Request
        try {
            $path = $request.Url.AbsolutePath
            if ($path -eq '/health') { Send-Json $context @{ok=$true}; continue }
            if ($path -eq '/' -or $path -eq '/index.html') { Send-File $context (Join-Path $webRoot 'index.html'); continue }
            if ($path.StartsWith('/assets/')) { Send-File $context (Join-Path $webRoot $path.TrimStart('/').Replace('/','\')); continue }
            $provided = [string]$request.Headers['X-RF-Token']
            if ($provided -ne $Token -and [string]$request.QueryString['token'] -ne $Token) { Send-Json $context @{error='unauthorized'} 401; continue }
            if ($path -eq '/api/stream/load' -and $request.HttpMethod -eq 'POST') {
                Start-EventStream $context
                try {
                    $body=Read-Body $request
                    if($body.PSObject.Properties['configPath'] -and $body.configPath){$script:configPath=[string]$body.configPath}
                    if($body.PSObject.Properties['workshopRoot'] -and $body.workshopRoot){$script:workshopRoot=[string]$body.workshopRoot}
                    Write-Event $context @{type='progress';percent=3;title='Загрузка сборки';step='Чтение ModsConfig.xml'}
                    $script:mods=@(Get-RFActiveMods -ConfigPath $script:configPath -WorkshopRoots @($script:workshopRoot) -OnProgress {
                        param($done,$total,$name);$percent=if($total){5+[Math]::Floor(78*$done/$total)}else{50};Write-Event $context @{type='progress';percent=$percent;title='Сканирование модов';step="$done из $total — $name"}
                    })
                    Write-Event $context @{type='progress';percent=90;title='Анализ локализаций';step='Связывание переводов с оригинальными модами'}
                    $script:results=@();Write-Event $context @{type='progress';percent=97;title='Обновление интерфейса';step='Сортировка категорий'}
                    Write-Event $context @{type='result';data=(Get-StateDto)}
                } catch { Write-Event $context @{type='error';error=$_.Exception.Message} } finally { Close-EventStream $context };continue
            }
            if ($path -eq '/api/stream/search' -and $request.HttpMethod -eq 'POST') {
                Start-EventStream $context
                try {
                    $body=Read-Body $request;$ids=@();if($body.PSObject.Properties['packageIds']){$ids=@($body.packageIds)}
                    if($ids.Count){$targets=@($script:mods|Where-Object{$ids-contains$_.PackageId})}else{$targets=@($script:mods)}
                    $includeExisting=$body.PSObject.Properties['includeExisting'] -and [bool]$body.includeExisting
                    Write-Event $context @{type='progress';percent=2;title='Поиск переводов';step="Подготовлено модов: $($targets.Count)"}
                    $script:results=@(Find-RFRussifiers -Mods $targets -Concurrency 6 -MaxCandidates 5 -IncludeWithRussian:$includeExisting -OnProgress {
                        param($done,$total,$name);if($done-eq1-or$done-eq$total-or$done%5-eq0){$percent=if($total){5+[Math]::Floor(78*$done/$total)}else{50};Write-Event $context @{type='progress';percent=$percent;title='Запросы Steam Workshop';step="$done из $total — $name"}}
                    })
                    Write-Event $context @{type='progress';percent=92;title='Проверка кандидатов';step='Оценка совпадений, версий и package ID'}
                    Write-Event $context @{type='progress';percent=97;title='Подготовка результатов';step="Найдено строк: $($script:results.Count)"}
                    Write-Event $context @{type='result';data=(Get-StateDto)}
                } catch { Write-Event $context @{type='error';error=$_.Exception.Message} } finally { Close-EventStream $context };continue
            }
            if ($path -eq '/api/stream/install' -and $request.HttpMethod -eq 'POST') {
                Start-EventStream $context
                try {
                    $body=Read-Body $request;Write-Event $context @{type='progress';percent=2;title='Установка переводов';step='Подключение к Steamworks'}
                    $report=Install-RFTranslations -WorkshopIds @($body.workshopIds) -ConfigPath $script:configPath -WorkshopRoots @($script:workshopRoot) -OnProgress {
                        param($stage,$done,$total,$name);$base=if($stage-eq'subscribe'){8}else{48};$span=if($stage-eq'subscribe'){35}else{35};$percent=if($total){$base+[Math]::Floor($span*$done/$total)}else{$base};$title=if($stage-eq'subscribe'){'Подписка в Steam'}else{'Загрузка файлов'};Write-Event $context @{type='progress';percent=$percent;title=$title;step="$done из $total — $name"}
                    }
                    Write-Event $context @{type='progress';percent=88;title='Обновление ModsConfig.xml';step='Создание резервной копии и добавление package ID'}
                    $script:mods=@(Get-RFActiveMods -ConfigPath $script:configPath -WorkshopRoots @($script:workshopRoot));$script:results=@()
                    Write-Event $context @{type='progress';percent=97;title='Перезагрузка сборки';step='Пересчёт категорий и состояний'}
                    Write-Event $context @{type='result';data=@{ok=$true;report=$report;state=(Get-StateDto)}}
                } catch { Write-Event $context @{type='error';error=$_.Exception.Message} } finally { Close-EventStream $context };continue
            }
            if ($path -eq '/api/stream/machine' -and $request.HttpMethod -eq 'POST') {
                Start-EventStream $context
                try {
                    $body=Read-Body $request;$ids=@($body.packageIds);$targets=@($script:mods|Where-Object{$ids-contains$_.PackageId});Write-Event $context @{type='progress';percent=8;title='Машинный перевод';step='Проверка Auto Translation'}
                    $settings=Get-RFMachineSettings $ProjectRoot;Write-Event $context @{type='progress';percent=30;title='Настройка провайдера';step="Провайдер: $($settings.Provider)"}
                    $report=Enable-RFMachineTranslation -Mods $targets -Settings $settings -ConfigPath $script:configPath -WorkshopRoots @($script:workshopRoot) -ProjectRoot $ProjectRoot
                    Write-Event $context @{type='progress';percent=85;title='Обновление списка';step="Назначено модов: $($targets.Count)"}
                    $script:mods=@(Get-RFActiveMods -ConfigPath $script:configPath -WorkshopRoots @($script:workshopRoot));Write-Event $context @{type='progress';percent=96;title='Готово к запуску';step='Перевод начнётся при запуске RimWorld'}
                    Write-Event $context @{type='result';data=@{ok=$true;report=$report;state=(Get-StateDto)}}
                } catch { Write-Event $context @{type='error';error=$_.Exception.Message} } finally { Close-EventStream $context };continue
            }
            if ($path -eq '/api/state' -and $request.HttpMethod -eq 'GET') { Send-Json $context (Get-StateDto); continue }
            if ($path -eq '/api/load' -and $request.HttpMethod -eq 'POST') {
                $body=Read-Body $request
                if($body.PSObject.Properties['configPath'] -and $body.configPath){$script:configPath=[string]$body.configPath}
                if($body.PSObject.Properties['workshopRoot'] -and $body.workshopRoot){$script:workshopRoot=[string]$body.workshopRoot}
                $script:mods=@(Get-RFActiveMods -ConfigPath $script:configPath -WorkshopRoots @($script:workshopRoot));$script:results=@();Send-Json $context (Get-StateDto);continue
            }
            if ($path -eq '/api/add' -and $request.HttpMethod -eq 'POST') {
                $body=Read-Body $request;$mod=Get-RFModByWorkshopId -WorkshopId ([string]$body.workshopId -replace '\s','') -WorkshopRoots @($script:workshopRoot)
                $exists=@($script:mods|Where-Object{$_.WorkshopId-eq$mod.WorkshopId}).Count -gt 0
                if(-not $exists){$script:mods=@($script:mods)+@($mod)}
                Send-Json $context (Get-StateDto);continue
            }
            if ($path -eq '/api/search' -and $request.HttpMethod -eq 'POST') {
                $body=Read-Body $request;$ids=@();if($body.PSObject.Properties['packageIds']){$ids=@($body.packageIds)}
                if($ids.Count){$targets=@($script:mods|Where-Object{$ids-contains$_.PackageId})}else{$targets=@($script:mods)}
                $includeExisting=$body.PSObject.Properties['includeExisting'] -and [bool]$body.includeExisting
                $script:results=@(Find-RFRussifiers -Mods $targets -Concurrency 6 -MaxCandidates 5 -IncludeWithRussian:$includeExisting);Send-Json $context (Get-StateDto);continue
            }
            if ($path -eq '/api/install' -and $request.HttpMethod -eq 'POST') {
                $body=Read-Body $request;$report=Install-RFTranslations -WorkshopIds @($body.workshopIds) -ConfigPath $script:configPath -WorkshopRoots @($script:workshopRoot);$script:mods=@(Get-RFActiveMods -ConfigPath $script:configPath -WorkshopRoots @($script:workshopRoot));$script:results=@();Send-Json $context @{ok=$true;report=$report;state=(Get-StateDto)};continue
            }
            if ($path -eq '/api/machine' -and $request.HttpMethod -eq 'POST') {
                $body=Read-Body $request;$ids=@($body.packageIds);$targets=@($script:mods|Where-Object{$ids-contains$_.PackageId});$settings=Get-RFMachineSettings $ProjectRoot
                $report=Enable-RFMachineTranslation -Mods $targets -Settings $settings -ConfigPath $script:configPath -WorkshopRoots @($script:workshopRoot) -ProjectRoot $ProjectRoot
                $script:mods=@(Get-RFActiveMods -ConfigPath $script:configPath -WorkshopRoots @($script:workshopRoot));Send-Json $context @{ok=$true;report=$report;state=(Get-StateDto)};continue
            }
            if ($path -eq '/api/settings' -and $request.HttpMethod -eq 'GET') {
                $s=Get-RFMachineSettings $ProjectRoot;Send-Json $context @{provider=$s.Provider;baseUrl=$s.BaseUrl;model=$s.Model;maxConcurrency=$s.MaxConcurrency;requestTimeoutSeconds=$s.RequestTimeoutSeconds;customPrompt=$s.CustomPrompt;apiKeyPresent=[bool]$s.ApiKeyProtected};continue
            }
            if ($path -eq '/api/settings' -and $request.HttpMethod -eq 'POST') {
                $b=Read-Body $request;$s=Get-RFMachineSettings $ProjectRoot;$s.Provider=[string]$b.provider;$s.BaseUrl=[string]$b.baseUrl;$s.Model=[string]$b.model;$s.MaxConcurrency=[int]$b.maxConcurrency;$s.RequestTimeoutSeconds=[int]$b.requestTimeoutSeconds;$s.CustomPrompt=[string]$b.customPrompt
                Save-RFMachineSettings -ProjectRoot $ProjectRoot -Settings $s -PlainApiKey ([string]$b.apiKey)|Out-Null;Send-Json $context @{ok=$true};continue
            }
            if ($path -eq '/api/settings/test' -and $request.HttpMethod -eq 'POST') {
                $b=Read-Body $request;$s=Get-RFMachineSettings $ProjectRoot
                if($b.PSObject.Properties['provider']){$s.Provider=[string]$b.provider};if($b.PSObject.Properties['baseUrl']){$s.BaseUrl=[string]$b.baseUrl};if($b.PSObject.Properties['model']){$s.Model=[string]$b.model};if($b.PSObject.Properties['requestTimeoutSeconds']){$s.RequestTimeoutSeconds=[int]$b.requestTimeoutSeconds};if($b.PSObject.Properties['customPrompt']){$s.CustomPrompt=[string]$b.customPrompt}
                $plainKey=if($b.PSObject.Properties['apiKey']){[string]$b.apiKey}else{''};$test=Test-RFMachineTranslationProvider -Settings $s -PlainApiKey $plainKey -ProjectRoot $ProjectRoot
                Send-Json $context @{ok=$true;test=$test};continue
            }
            if ($path -eq '/api/remove-active' -and $request.HttpMethod -eq 'POST') {$b=Read-Body $request;$r=Remove-RFModFromActiveList -PackageId ([string]$b.packageId) -ConfigPath $script:configPath;$script:mods=@(Get-RFActiveMods -ConfigPath $script:configPath -WorkshopRoots @($script:workshopRoot));Send-Json $context @{ok=$true;report=$r;state=(Get-StateDto)};continue}
            if ($path -eq '/api/unsubscribe' -and $request.HttpMethod -eq 'POST') {$b=Read-Body $request;$r=Uninstall-RFWorkshopMod -WorkshopId ([string]$b.workshopId) -PackageId ([string]$b.packageId) -ConfigPath $script:configPath;$script:mods=@(Get-RFActiveMods -ConfigPath $script:configPath -WorkshopRoots @($script:workshopRoot));Send-Json $context @{ok=$true;report=$r;state=(Get-StateDto)};continue}
            if ($path -eq '/api/open' -and $request.HttpMethod -eq 'POST') {$b=Read-Body $request;if($b.url){Start-Process ([string]$b.url)};Send-Json $context @{ok=$true};continue}
            if ($path -eq '/api/export' -and $request.HttpMethod -eq 'POST') {$runtime=Join-Path $ProjectRoot 'runtime';New-Item -ItemType Directory $runtime -Force|Out-Null;$reportPath=Join-Path $runtime 'russifier_report.html';Export-RFReport -Results $script:results -Path $reportPath;Start-Process $reportPath;Send-Json $context @{ok=$true;path=$reportPath};continue}
            if ($path -eq '/api/shutdown') {$script:running=$false;Send-Json $context @{ok=$true};continue}
            Send-Json $context @{error='not found'} 404
        } catch { Send-Json $context @{error=$_.Exception.Message;details=[string]$_} 500 }
    }
} finally { $listener.Stop();$listener.Close() }
