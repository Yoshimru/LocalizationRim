param(
    [switch]$Cli,
    [string]$ConfigPath = '',
    [string]$WorkshopRoot = '',
    [string[]]$WorkshopId = @(),
    [string]$OutputPath = '',
    [ValidateRange(1, 16)][int]$Concurrency = 6,
    [ValidateRange(1, 20)][int]$MaxCandidates = 5,
    [switch]$IncludeWithRussian
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'RussifierFinder.Core.psm1'
Import-Module $modulePath -Force

function Invoke-RFCommandLine {
    $roots = if ($WorkshopRoot) { @($WorkshopRoot) } else { @(Get-RFWorkshopRoots) }
    $mods = New-Object System.Collections.Generic.List[object]
    if ($WorkshopId.Count -gt 0) {
        foreach ($rawId in $WorkshopId) {
            foreach ($id in @(([string]$rawId) -split '[,;\s]+' | Where-Object { $_ })) {
                $mods.Add((Get-RFModByWorkshopId -WorkshopId $id -WorkshopRoots $roots))
            }
        }
    } else {
        $effectiveConfig = if ($ConfigPath) { $ConfigPath } else { Get-RFDefaultConfigPath }
        foreach ($mod in @(Get-RFActiveMods -ConfigPath $effectiveConfig -WorkshopRoots $roots)) { $mods.Add($mod) }
    }
    if ($mods.Count -eq 0) { throw 'Не найдено ни одного мода для поиска.' }

    Write-Host "Модов: $($mods.Count). Поиск в Steam Workshop..."
    $results = @(Find-RFRussifiers -Mods $mods.ToArray() -Concurrency $Concurrency -MaxCandidates $MaxCandidates `
        -IncludeWithRussian:$IncludeWithRussian -OnProgress {
            param($done, $total, $name)
            Write-Host ("[{0}/{1}] {2}" -f $done, $total, $name)
        })

    $rows = foreach ($result in $results) {
        if ($result.Candidates.Count -eq 0) {
            [pscustomobject]@{ Mod = $result.Mod.Name; Status = $result.Status; Russifier = ''; Score = ''; Url = $result.SearchUrl }
        } else {
            foreach ($candidate in $result.Candidates) {
                [pscustomobject]@{ Mod = $result.Mod.Name; Status = $result.Status; Russifier = $candidate.Title; Score = $candidate.Score; Url = $candidate.Url }
            }
        }
    }
    $rows | Format-Table -AutoSize
    if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot 'russifier_report.html' }
    Export-RFReport -Results $results -Path $OutputPath
    Write-Host "Отчёт: $OutputPath"
}

if ($Cli) {
    Invoke-RFCommandLine
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:mods = @()
$script:results = @()
$script:currentJob = $null
$script:jobMode = ''
$script:jobItems = New-Object System.Collections.Generic.List[object]
$script:lastReport = ''

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Поиск русификаторов RimWorld'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1280, 820)
$form.MinimumSize = New-Object System.Drawing.Size(1050, 680)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$main = New-Object System.Windows.Forms.TableLayoutPanel
$main.Dock = 'Fill'
$main.Padding = New-Object System.Windows.Forms.Padding(10)
$main.ColumnCount = 1
$main.RowCount = 7
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 44)))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 56)))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$form.Controls.Add($main)

function New-PathRow {
    param([string]$Label, [string]$Value, [scriptblock]$BrowseAction)
    $panel = New-Object System.Windows.Forms.TableLayoutPanel
    $panel.Dock = 'Top'; $panel.AutoSize = $true; $panel.ColumnCount = 3
    [void]$panel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 150)))
    [void]$panel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$panel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 100)))
    $caption = New-Object System.Windows.Forms.Label
    $caption.Text = $Label; $caption.AutoSize = $true; $caption.Anchor = 'Left'; $caption.Padding = New-Object System.Windows.Forms.Padding(0, 7, 0, 0)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Text = $Value; $box.Dock = 'Fill'
    $button = New-Object System.Windows.Forms.Button
    $button.Text = 'Обзор...'; $button.Dock = 'Fill'; $button.Add_Click($BrowseAction)
    [void]$panel.Controls.Add($caption, 0, 0); [void]$panel.Controls.Add($box, 1, 0); [void]$panel.Controls.Add($button, 2, 0)
    return [pscustomobject]@{ Panel = $panel; TextBox = $box }
}

$defaultConfig = if ($ConfigPath) { $ConfigPath } else { Get-RFDefaultConfigPath }
$defaultRoots = @(Get-RFWorkshopRoots)
$defaultWorkshop = if ($WorkshopRoot) { $WorkshopRoot } elseif ($defaultRoots.Count -gt 0) { $defaultRoots[0] } else { '' }

$configRow = New-PathRow 'ModsConfig.xml:' $defaultConfig {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'ModsConfig.xml|ModsConfig.xml|XML-файлы|*.xml|Все файлы|*.*'
    if ($dialog.ShowDialog() -eq 'OK') { $configRow.TextBox.Text = $dialog.FileName }
}
$workshopRow = New-PathRow 'Папка Workshop:' $defaultWorkshop {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Выберите папку steamapps\workshop\content\294100'
    if ($dialog.ShowDialog() -eq 'OK') { $workshopRow.TextBox.Text = $dialog.SelectedPath }
}
[void]$main.Controls.Add($configRow.Panel, 0, 0)
[void]$main.Controls.Add($workshopRow.Panel, 0, 1)

$actions = New-Object System.Windows.Forms.FlowLayoutPanel
$actions.Dock = 'Fill'; $actions.AutoSize = $true; $actions.WrapContents = $false
$loadButton = New-Object System.Windows.Forms.Button
$loadButton.Text = 'Загрузить активную сборку'; $loadButton.AutoSize = $true
$idLabel = New-Object System.Windows.Forms.Label
$idLabel.Text = '  Отдельный мод (ссылка или ID):'; $idLabel.AutoSize = $true; $idLabel.Padding = New-Object System.Windows.Forms.Padding(0, 7, 0, 0)
$idBox = New-Object System.Windows.Forms.TextBox
$idBox.Width = 260
$addButton = New-Object System.Windows.Forms.Button
$addButton.Text = 'Добавить'; $addButton.AutoSize = $true
$filterLabel = New-Object System.Windows.Forms.Label
$filterLabel.Text = '  Фильтр:'; $filterLabel.AutoSize = $true; $filterLabel.Padding = New-Object System.Windows.Forms.Padding(0, 7, 0, 0)
$filterBox = New-Object System.Windows.Forms.TextBox
$filterBox.Width = 160
$categoryLabel = New-Object System.Windows.Forms.Label
$categoryLabel.Text = '  Категория:'; $categoryLabel.AutoSize = $true; $categoryLabel.Padding = New-Object System.Windows.Forms.Padding(0, 7, 0, 0)
$categoryBox = New-Object System.Windows.Forms.ComboBox
$categoryBox.Width = 225; $categoryBox.DropDownStyle = 'DropDownList'
[void]$categoryBox.Items.AddRange(@(
    'Все категории', 'Нужен поиск', 'Русификатор активен',
    'Русификатор установлен (не активен)', 'Встроенный русский',
    'Русификаторы', 'Файлы не найдены'
))
$categoryBox.SelectedIndex = 0
$actions.Controls.AddRange(@($loadButton, $idLabel, $idBox, $addButton, $filterLabel, $filterBox, $categoryLabel, $categoryBox))
[void]$main.Controls.Add($actions, 0, 2)

$modsGrid = New-Object System.Windows.Forms.DataGridView
$modsGrid.Dock = 'Fill'; $modsGrid.AllowUserToAddRows = $false; $modsGrid.AllowUserToDeleteRows = $false
$modsGrid.AllowUserToResizeRows = $false; $modsGrid.RowHeadersVisible = $false; $modsGrid.SelectionMode = 'FullRowSelect'
$modsGrid.MultiSelect = $true; $modsGrid.AutoSizeColumnsMode = 'Fill'; $modsGrid.BackgroundColor = [Drawing.Color]::White
$checkColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$checkColumn.Name = 'Check'; $checkColumn.HeaderText = 'Искать'; $checkColumn.Width = 55; $checkColumn.FillWeight = 12
[void]$modsGrid.Columns.Add($checkColumn)
foreach ($definition in @(
    @('Category', 'Категория', 24), @('Name', 'Мод', 38), @('PackageId', 'Package ID', 28), @('State', 'Состояние', 38)
)) {
    $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $definition[0]; $column.HeaderText = $definition[1]; $column.FillWeight = $definition[2]; $column.ReadOnly = $true
    [void]$modsGrid.Columns.Add($column)
}
[void]$main.Controls.Add($modsGrid, 0, 3)

$searchPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$searchPanel.Dock = 'Fill'; $searchPanel.AutoSize = $true; $searchPanel.WrapContents = $false
$selectAllButton = New-Object System.Windows.Forms.Button
$selectAllButton.Text = 'Отметить нуждающиеся'; $selectAllButton.AutoSize = $true
$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = 'Снять отметки'; $clearButton.AutoSize = $true
$searchCheckedButton = New-Object System.Windows.Forms.Button
$searchCheckedButton.Text = 'Искать для отмеченных'; $searchCheckedButton.AutoSize = $true
$searchAllButton = New-Object System.Windows.Forms.Button
$searchAllButton.Text = 'Проверить всю сборку'; $searchAllButton.AutoSize = $true
$includeBox = New-Object System.Windows.Forms.CheckBox
$includeBox.Text = 'искать даже при наличии русского'; $includeBox.AutoSize = $true; $includeBox.Padding = New-Object System.Windows.Forms.Padding(8, 6, 0, 0)
$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = 'Остановить'; $cancelButton.AutoSize = $true; $cancelButton.Enabled = $false
$searchPanel.Controls.AddRange(@($selectAllButton, $clearButton, $searchCheckedButton, $searchAllButton, $includeBox, $cancelButton))
[void]$main.Controls.Add($searchPanel, 0, 4)

$resultsGrid = New-Object System.Windows.Forms.DataGridView
$resultsGrid.Dock = 'Fill'; $resultsGrid.AllowUserToAddRows = $false; $resultsGrid.AllowUserToDeleteRows = $false
$resultsGrid.AllowUserToResizeRows = $false; $resultsGrid.RowHeadersVisible = $false; $resultsGrid.ReadOnly = $false
$resultsGrid.SelectionMode = 'FullRowSelect'; $resultsGrid.MultiSelect = $false; $resultsGrid.AutoSizeColumnsMode = 'Fill'
$resultsGrid.BackgroundColor = [Drawing.Color]::White; $resultsGrid.EditMode = 'EditOnEnter'
$installColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$installColumn.Name = 'Install'; $installColumn.HeaderText = 'Уст.'; $installColumn.FillWeight = 6
$installColumn.ReadOnly = $false; $installColumn.SortMode = 'NotSortable'
[void]$resultsGrid.Columns.Add($installColumn)
foreach ($definition in @(
    @('ResultCategory', 'Результат', 17), @('Mod', 'Мод', 24), @('Status', 'Статус', 16),
    @('Russifier', 'Русификатор', 28), @('Score', 'Оценка', 7),
    @('Versions', 'Версии', 8), @('Link', 'Ссылка', 9)
)) {
    $column = if ($definition[0] -eq 'Link') {
        New-Object System.Windows.Forms.DataGridViewLinkColumn
    } elseif ($definition[0] -eq 'Russifier') {
        New-Object System.Windows.Forms.DataGridViewComboBoxColumn
    } else {
        New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    }
    $column.Name = $definition[0]; $column.HeaderText = $definition[1]; $column.FillWeight = $definition[2]
    $column.ReadOnly = $definition[0] -ne 'Russifier'
    if ($definition[0] -eq 'Link') { $column.TrackVisitedState = $false }
    if ($definition[0] -eq 'Russifier') { $column.DisplayStyle = 'DropDownButton'; $column.FlatStyle = 'Flat' }
    if ($definition[0] -ne 'Russifier') { $column.SortMode = 'Automatic' }
    [void]$resultsGrid.Columns.Add($column)
}
[void]$main.Controls.Add($resultsGrid, 0, 5)

$bottom = New-Object System.Windows.Forms.TableLayoutPanel
$bottom.Dock = 'Fill'; $bottom.AutoSize = $true; $bottom.ColumnCount = 6
[void]$bottom.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$bottom.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 180)))
[void]$bottom.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 145)))
[void]$bottom.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 210)))
[void]$bottom.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 100)))
[void]$bottom.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 100)))
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Загрузите сборку или добавьте отдельный мод.'; $statusLabel.AutoSize = $true; $statusLabel.Anchor = 'Left'
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Dock = 'Fill'; $progress.Style = 'Blocks'
$selectFoundButton = New-Object System.Windows.Forms.Button
$selectFoundButton.Text = 'Отметить найденные'; $selectFoundButton.Dock = 'Fill'; $selectFoundButton.Enabled = $false
$installButton = New-Object System.Windows.Forms.Button
$installButton.Text = 'Установить выбранные'; $installButton.Dock = 'Fill'; $installButton.Enabled = $false
$exportButton = New-Object System.Windows.Forms.Button
$exportButton.Text = 'Экспорт...'; $exportButton.Dock = 'Fill'; $exportButton.Enabled = $false
$openReportButton = New-Object System.Windows.Forms.Button
$openReportButton.Text = 'Открыть отчёт'; $openReportButton.Dock = 'Fill'; $openReportButton.Enabled = $false
[void]$bottom.Controls.Add($statusLabel, 0, 0); [void]$bottom.Controls.Add($progress, 1, 0)
[void]$bottom.Controls.Add($selectFoundButton, 2, 0); [void]$bottom.Controls.Add($installButton, 3, 0)
[void]$bottom.Controls.Add($exportButton, 4, 0); [void]$bottom.Controls.Add($openReportButton, 5, 0)
[void]$main.Controls.Add($bottom, 0, 6)

function Get-ModStateText {
    param($Mod)
    if ($Mod.Source -eq 'missing') { return 'Файлы не найдены' }
    if ($Mod.IsTranslation) { return 'Русификатор' }
    if ($Mod.InstalledTranslation) {
        if ($Mod.InstalledTranslationActive) { return "Активен: $($Mod.InstalledTranslation)" }
        return "Установлен, но выключен: $($Mod.InstalledTranslation)"
    }
    if ($Mod.HasBuiltInRussian) { return 'Русский встроен' }
    return 'Нужен поиск'
}

function Get-ModCategory {
    param($Mod)
    if ($Mod.Source -eq 'missing') { return 'Файлы не найдены' }
    if ($Mod.IsTranslation) { return 'Русификаторы' }
    if ($Mod.InstalledTranslation) {
        if ($Mod.InstalledTranslationActive) { return 'Русификатор активен' }
        return 'Русификатор установлен (не активен)'
    }
    if ($Mod.HasBuiltInRussian) { return 'Встроенный русский' }
    return 'Нужен поиск'
}

function Get-ModCategoryOrder {
    param([string]$Category)
    switch ($Category) {
        'Нужен поиск' { return 1 }
        'Русификатор активен' { return 2 }
        'Русификатор установлен (не активен)' { return 3 }
        'Встроенный русский' { return 4 }
        'Русификаторы' { return 5 }
        'Файлы не найдены' { return 6 }
        default { return 99 }
    }
}

function Get-ModCategoryColor {
    param([string]$Category)
    switch ($Category) {
        'Нужен поиск' { return [Drawing.Color]::FromArgb(255, 247, 214) }
        'Русификатор активен' { return [Drawing.Color]::FromArgb(220, 242, 220) }
        'Русификатор установлен (не активен)' { return [Drawing.Color]::FromArgb(226, 238, 250) }
        'Встроенный русский' { return [Drawing.Color]::FromArgb(224, 245, 237) }
        'Русификаторы' { return [Drawing.Color]::FromArgb(238, 238, 238) }
        'Файлы не найдены' { return [Drawing.Color]::FromArgb(248, 220, 223) }
        default { return [Drawing.Color]::White }
    }
}

function Test-ModNeedsSearch {
    param($Mod)
    return $Mod.Source -ne 'missing' -and -not $Mod.IsTranslation -and -not $Mod.HasBuiltInRussian -and -not $Mod.InstalledTranslation
}

function Update-ModGrid {
    $query = $filterBox.Text.Trim()
    $selectedCategory = [string]$categoryBox.SelectedItem
    $modsGrid.Rows.Clear()
    $sortedMods = @($script:mods | Sort-Object `
        @{ Expression = { Get-ModCategoryOrder (Get-ModCategory $_) } },
        @{ Expression = { $_.Name } })
    foreach ($mod in $sortedMods) {
        $category = Get-ModCategory $mod
        if ($query -and "$($mod.Name) $($mod.PackageId)" -notlike "*$query*") { continue }
        if ($selectedCategory -and $selectedCategory -ne 'Все категории' -and $category -ne $selectedCategory) { continue }
        $index = $modsGrid.Rows.Add((Test-ModNeedsSearch $mod), $category, $mod.Name, $mod.PackageId, (Get-ModStateText $mod))
        $row = $modsGrid.Rows[$index]
        $row.Tag = $mod
        $row.DefaultCellStyle.BackColor = Get-ModCategoryColor $category
    }
    $needSearch = @($script:mods | Where-Object { (Get-ModCategory $_) -eq 'Нужен поиск' }).Count
    $withTranslation = @($script:mods | Where-Object { (Get-ModCategory $_) -in @('Русификатор активен', 'Русификатор установлен (не активен)') }).Count
    $builtIn = @($script:mods | Where-Object { (Get-ModCategory $_) -eq 'Встроенный русский' }).Count
    $statusLabel.Text = "Показано: $($modsGrid.Rows.Count)/$($script:mods.Count) | Нужен поиск: $needSearch | Есть русификатор: $withTranslation | Встроенный: $builtIn"
}

function Set-BusyState {
    param([bool]$Busy, [string]$Text)
    foreach ($control in @($loadButton, $addButton, $searchCheckedButton, $searchAllButton, $selectAllButton, $clearButton)) { $control.Enabled = -not $Busy }
    $cancelButton.Enabled = $Busy
    $installButton.Enabled = -not $Busy -and @($resultsGrid.Rows | Where-Object { -not $_.Cells['Install'].ReadOnly }).Count -gt 0
    $selectFoundButton.Enabled = $installButton.Enabled
    if ($Busy) { $progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 25 } else { $progress.Style = 'Blocks'; $progress.MarqueeAnimationSpeed = 0 }
    if ($Text) { $statusLabel.Text = $Text }
}

function Get-CandidateDisplayText {
    param($Candidate)
    return "$($Candidate.Title)  —  рейтинг $($Candidate.Score)  [$($Candidate.WorkshopId)]"
}

function Get-ResultCategory {
    param($Result)
    if (@($Result.Candidates).Count -gt 0) { return 'Найден перевод' }
    $status = [string]$Result.Status
    if ($status -match '^Не найдено') { return 'Перевод не найден' }
    if ($status -match '^Ошибка') { return 'Ошибка поиска' }
    if ($status -match '^Уже активен') { return 'Русификатор активен' }
    if ($status -match '^Установлен, но не активен') { return 'Русификатор установлен' }
    if ($status -eq 'Русский встроен') { return 'Встроенный русский' }
    if ($status -eq 'Это русификатор') { return 'Языковой мод' }
    if ($status -eq 'Файлы мода не найдены') { return 'Файлы не найдены' }
    return 'Прочее'
}

function Get-ResultCategoryOrder {
    param([string]$Category)
    switch ($Category) {
        'Найден перевод' { return 1 }
        'Перевод не найден' { return 2 }
        'Ошибка поиска' { return 3 }
        'Русификатор активен' { return 4 }
        'Русификатор установлен' { return 5 }
        'Встроенный русский' { return 6 }
        'Языковой мод' { return 7 }
        'Файлы не найдены' { return 8 }
        default { return 99 }
    }
}

function Get-ResultCategoryColor {
    param([string]$Category)
    switch ($Category) {
        'Найден перевод' { return [Drawing.Color]::FromArgb(214, 242, 218) }
        'Перевод не найден' { return [Drawing.Color]::FromArgb(255, 243, 205) }
        'Ошибка поиска' { return [Drawing.Color]::FromArgb(248, 215, 218) }
        'Русификатор активен' { return [Drawing.Color]::FromArgb(220, 242, 220) }
        'Русификатор установлен' { return [Drawing.Color]::FromArgb(220, 235, 250) }
        'Встроенный русский' { return [Drawing.Color]::FromArgb(224, 245, 237) }
        'Языковой мод' { return [Drawing.Color]::FromArgb(238, 238, 238) }
        'Файлы не найдены' { return [Drawing.Color]::FromArgb(242, 222, 222) }
        default { return [Drawing.Color]::White }
    }
}

function Set-ResultRowStyle {
    param($Row, [string]$Category)
    $color = Get-ResultCategoryColor $Category
    $Row.DefaultCellStyle.BackColor = $color
    $Row.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(
        [Math]::Max(0, $color.R - 35),
        [Math]::Max(0, $color.G - 35),
        [Math]::Max(0, $color.B - 35)
    )
    $Row.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::Black
}

function Set-ResultRowCandidate {
    param($Row, $Candidate)
    if (-not $Candidate) {
        $Row.Cells['Score'].Value = ''
        $Row.Cells['Versions'].Value = ''
        $Row.Cells['Link'].Value = ''
        $Row.Cells['Link'].Tag = ''
        return
    }
    $Row.Cells['Score'].Value = $Candidate.Score
    $Row.Cells['Versions'].Value = (@($Candidate.Versions) -join ', ')
    $Row.Cells['Link'].Value = 'Steam Workshop'
    $Row.Cells['Link'].Tag = $Candidate.Url
}

function Add-ResultRows {
    param($Result)
    $category = Get-ResultCategory $Result
    if (@($Result.Candidates).Count -eq 0) {
        $link = if ($Result.SearchUrl) { 'Ручной поиск' } else { '' }
        $index = $resultsGrid.Rows.Add($false, $category, $Result.Mod.Name, $Result.Status, $null, '', '', $link)
        $row = $resultsGrid.Rows[$index]
        $row.Tag = $Result
        $row.Cells['Install'].ReadOnly = $true
        $row.Cells['Link'].Tag = $Result.SearchUrl
        Set-ResultRowStyle -Row $row -Category $category
    } else {
        $candidates = @($Result.Candidates | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Updated'; Descending = $true })
        $index = $resultsGrid.Rows.Add($false, $category, $Result.Mod.Name, $Result.Status, $null, '', '', '')
        $row = $resultsGrid.Rows[$index]
        $row.Tag = $Result
        $row.Cells['Install'].ReadOnly = $false
        $comboCell = [System.Windows.Forms.DataGridViewComboBoxCell]$row.Cells['Russifier']
        foreach ($candidate in $candidates) {
            [void]$comboCell.Items.Add((Get-CandidateDisplayText $candidate))
        }
        $comboCell.Value = Get-CandidateDisplayText $candidates[0]
        Set-ResultRowCandidate -Row $row -Candidate $candidates[0]
        Set-ResultRowStyle -Row $row -Category $category
    }
}

function Start-LoadJob {
    if ($script:currentJob) { return }
    if (-not (Test-Path -LiteralPath $configRow.TextBox.Text)) { [Windows.Forms.MessageBox]::Show('Не найден ModsConfig.xml.', 'Ошибка', 'OK', 'Error'); return }
    if (-not (Test-Path -LiteralPath $workshopRow.TextBox.Text)) { [Windows.Forms.MessageBox]::Show('Не найдена папка Workshop.', 'Ошибка', 'OK', 'Error'); return }
    $script:jobItems.Clear(); $script:jobMode = 'load'; $script:results = @()
    $resultsGrid.Rows.Clear()
    $installButton.Enabled = $false; $selectFoundButton.Enabled = $false
    $exportButton.Enabled = $false; $openReportButton.Enabled = $false
    $script:currentJob = Start-Job -ScriptBlock {
        param($module, $config, $root)
        Import-Module $module -Force
        Get-RFActiveMods -ConfigPath $config -WorkshopRoots @($root)
    } -ArgumentList $modulePath, $configRow.TextBox.Text, $workshopRow.TextBox.Text
    Set-BusyState $true 'Чтение активной сборки и языковых папок...'
}

function Start-SearchJob {
    param([object[]]$Mods)
    if ($script:currentJob) { return }
    if ($Mods.Count -eq 0) { [Windows.Forms.MessageBox]::Show('Не выбраны моды для поиска.', 'Поиск', 'OK', 'Information'); return }
    $json = $Mods | ConvertTo-Json -Depth 8 -Compress
    $script:jobItems.Clear(); $script:jobMode = 'search'; $script:results = @(); $resultsGrid.Rows.Clear()
    $installButton.Enabled = $false; $selectFoundButton.Enabled = $false
    $include = $includeBox.Checked
    $script:currentJob = Start-Job -ScriptBlock {
        param($module, $modsJson, $parallel, $max, $includeExisting)
        Import-Module $module -Force
        $decodedMods = $modsJson | ConvertFrom-Json
        # Windows PowerShell 5.1 returns a top-level JSON array as one Object[].
        # Passing @($decodedMods) would wrap it again, making the whole mod list
        # look like a single mod named "System.Object[]".
        $mods = if ($decodedMods -is [System.Array]) { [object[]]$decodedMods } else { @($decodedMods) }
        Find-RFRussifiers -Mods $mods -Concurrency $parallel -MaxCandidates $max -IncludeWithRussian:$includeExisting -OnProgress {
            param($done, $total, $name)
            [pscustomobject]@{ Kind = 'Progress'; Done = $done; Total = $total; Name = $name }
        }
    } -ArgumentList $modulePath, $json, $Concurrency, $MaxCandidates, $include
    $progress.Style = 'Blocks'; $progress.Minimum = 0; $progress.Maximum = [Math]::Max(1, $Mods.Count); $progress.Value = 0
    Set-BusyState $true "Запущен поиск для $($Mods.Count) модов..."
    $progress.Style = 'Blocks'
}

function Get-SelectedTranslationCandidates {
    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($row in $resultsGrid.Rows) {
        if ($row.Cells['Install'].ReadOnly -or $row.Cells['Install'].Value -ne $true) { continue }
        $result = $row.Tag
        if (-not $result -or @($result.Candidates).Count -eq 0) { continue }
        $selectedText = [string]$row.Cells['Russifier'].Value
        $candidate = @($result.Candidates | Where-Object { (Get-CandidateDisplayText $_) -eq $selectedText } | Select-Object -First 1)
        if ($candidate.Count -gt 0) { $selected.Add($candidate[0]) }
    }
    return @($selected | Sort-Object WorkshopId -Unique)
}

function Start-InstallJob {
    $candidates = @(Get-SelectedTranslationCandidates)
    if ($candidates.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show('Отметьте найденные русификаторы в колонке «Уст.».', 'Установка', 'OK', 'Information')
        return
    }
    $message = "Будет оформлена подписка на $($candidates.Count) русификаторов.`r`n`r`nПосле загрузки они будут добавлены в ModsConfig.xml. Перед изменением создаётся резервная копия. RimWorld должен быть закрыт; открытый RimSort будет закрыт автоматически.`r`n`r`nПродолжить?"
    if ([Windows.Forms.MessageBox]::Show($message, 'Подписка и добавление', 'YesNo', 'Question') -ne 'Yes') { return }
    $operationId = [guid]::NewGuid().ToString('N')
    $requestPath = Join-Path $env:TEMP "rf-install-$operationId-request.json"
    $resultPath = Join-Path $env:TEMP "rf-install-$operationId-result.json"
    $progressPath = Join-Path $env:TEMP "rf-install-$operationId-progress.json"
    $stdoutPath = Join-Path $env:TEMP "rf-install-$operationId-stdout.log"
    $stderrPath = Join-Path $env:TEMP "rf-install-$operationId-stderr.log"
    $helperPath = Join-Path $PSScriptRoot 'InstallTranslations.Helper.ps1'
    $request = [pscustomobject]@{
        ModulePath = $modulePath
        WorkshopIds = @($candidates.WorkshopId)
        ConfigPath = $configRow.TextBox.Text
        WorkshopRoots = @($workshopRow.TextBox.Text)
        KeepRimSortOpen = $false
    }
    [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Depth 5 -Compress), [Text.UTF8Encoding]::new($false))
    $script:jobItems.Clear(); $script:jobMode = 'install'
    $script:currentJob = Start-Job -ScriptBlock {
        param($helper, $requestFile, $resultFile, $progressFile, $stdoutFile, $stderrFile)
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -RequestPath "{1}" -ResultPath "{2}" -ProgressPath "{3}"' -f `
            $helper, $requestFile, $resultFile, $progressFile
        $process = $null
        $lastProgress = ''
        try {
            $process = Start-Process powershell.exe -ArgumentList $arguments -RedirectStandardOutput $stdoutFile `
                -RedirectStandardError $stderrFile -WindowStyle Hidden -PassThru
            while (-not $process.HasExited) {
                if (Test-Path -LiteralPath $progressFile) {
                    try {
                        $progressJson = [IO.File]::ReadAllText($progressFile, [Text.UTF8Encoding]::new($false))
                        if ($progressJson -and $progressJson -ne $lastProgress) {
                            $lastProgress = $progressJson
                            Write-Output ($progressJson | ConvertFrom-Json)
                        }
                    } catch {}
                }
                Start-Sleep -Milliseconds 300
                $process.Refresh()
            }
            if (Test-Path -LiteralPath $progressFile) {
                try {
                    $progressJson = [IO.File]::ReadAllText($progressFile, [Text.UTF8Encoding]::new($false))
                    if ($progressJson -and $progressJson -ne $lastProgress) { Write-Output ($progressJson | ConvertFrom-Json) }
                } catch {}
            }
            if (-not (Test-Path -LiteralPath $resultFile)) {
                $nativeError = if (Test-Path -LiteralPath $stderrFile) { [IO.File]::ReadAllText($stderrFile) } else { '' }
                throw "Вспомогательный процесс не создал отчёт. $nativeError"
            }
            $result = ([IO.File]::ReadAllText($resultFile, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
            if (-not $result.Success) { throw [string]$result.Error }
            Write-Output $result.Report
        } finally {
            Remove-Item $requestFile, $resultFile, $progressFile, $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
        }
    } -ArgumentList $helperPath, $requestPath, $resultPath, $progressPath, $stdoutPath, $stderrPath
    Set-BusyState $true "Установка $($candidates.Count) русификаторов..."
    $cancelButton.Enabled = $false
    $progress.Style = 'Blocks'; $progress.Minimum = 0; $progress.Maximum = [Math]::Max(1, $candidates.Count); $progress.Value = 0
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
  try {
    if (-not $script:currentJob) { return }
    # Steamworks writes harmless diagnostics such as "Setting breakpad
    # minidump AppID" to stderr. Do not let Receive-Job promote those lines to
    # terminating UI exceptions when the global ErrorActionPreference is Stop.
    foreach ($item in @(Receive-Job -Job $script:currentJob -ErrorAction SilentlyContinue)) {
        if ($item.PSObject.Properties['Kind'] -and $item.Kind -eq 'Progress') {
            $progress.Maximum = [Math]::Max(1, [int]$item.Total)
            $progress.Value = [Math]::Min($progress.Maximum, [int]$item.Done)
            $statusLabel.Text = "Поиск: $($item.Done)/$($item.Total) — $($item.Name)"
        } else { $script:jobItems.Add($item) }
    }
    if ($script:currentJob.State -in @('Completed', 'Failed', 'Stopped')) {
        $state = $script:currentJob.State
        $reason = if ($script:currentJob.ChildJobs.Count -gt 0) { [string]$script:currentJob.ChildJobs[0].JobStateInfo.Reason } else { '' }
        Remove-Job -Job $script:currentJob -Force -ErrorAction SilentlyContinue
        $script:currentJob = $null
        Set-BusyState $false ''
        if ($state -eq 'Failed') {
            $statusLabel.Text = "Ошибка: $reason"
            [Windows.Forms.MessageBox]::Show("Операция завершилась ошибкой.`r`n$reason", 'Ошибка', 'OK', 'Error')
        } elseif ($state -eq 'Stopped') {
            $statusLabel.Text = 'Операция остановлена.'
        } elseif ($script:jobMode -eq 'load') {
            $script:mods = @($script:jobItems.ToArray())
            Update-ModGrid
        } elseif ($script:jobMode -eq 'search') {
            $script:results = @($script:jobItems.ToArray() | Sort-Object `
                @{ Expression = { Get-ResultCategoryOrder (Get-ResultCategory $_) } },
                @{ Expression = { $_.Mod.Name } })
            foreach ($result in $script:results) { Add-ResultRows $result }
            $found = @($script:results | Where-Object { @($_.Candidates).Count -gt 0 }).Count
            $notFound = @($script:results | Where-Object { (Get-ResultCategory $_) -eq 'Перевод не найден' }).Count
            $errors = @($script:results | Where-Object { (Get-ResultCategory $_) -eq 'Ошибка поиска' }).Count
            $statusLabel.Text = "Готово. Проверено: $($script:results.Count) | Найдено: $found | Не найдено: $notFound | Ошибки: $errors"
            $exportButton.Enabled = $script:results.Count -gt 0
            $openReportButton.Enabled = $false
            $installButton.Enabled = $found -gt 0
            $selectFoundButton.Enabled = $found -gt 0
        } elseif ($script:jobMode -eq 'install') {
            $report = @($script:jobItems | Where-Object { $_.PSObject.Properties['Kind'] -and $_.Kind -eq 'InstallResult' } | Select-Object -Last 1)
            if ($report.Count -eq 0) {
                [Windows.Forms.MessageBox]::Show('Steam не вернул отчёт об установке.', 'Установка', 'OK', 'Error')
            } else {
                $item = $report[0]
                $summary = "Подписка завершена.`r`n`r`nДобавлено в список модов: $(@($item.Added).Count)`r`nУже были активны: $(@($item.AlreadyActive).Count)`r`nНе удалось установить: $(@($item.Failed).Count)"
                if ($item.BackupPath) { $summary += "`r`n`r`nРезервная копия:`r`n$($item.BackupPath)" }
                $icon = if (@($item.Failed).Count -gt 0) { 'Warning' } else { 'Information' }
                [Windows.Forms.MessageBox]::Show($summary, 'Установка русификаторов', 'OK', $icon)
                foreach ($row in $resultsGrid.Rows) { $row.Cells['Install'].Value = $false }
                Start-LoadJob
            }
        }
    }
  } catch {
    $message = $_.Exception.Message
    if ($script:currentJob) {
        Stop-Job -Job $script:currentJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:currentJob -Force -ErrorAction SilentlyContinue
        $script:currentJob = $null
    }
    Set-BusyState $false ''
    $statusLabel.Text = "Ошибка интерфейса: $message"
    [Windows.Forms.MessageBox]::Show("Операция остановлена, но приложение продолжит работу.`r`n`r`n$message", 'Ошибка', 'OK', 'Error') | Out-Null
  }
})
$timer.Start()

$loadButton.Add_Click({ Start-LoadJob })
$addButton.Add_Click({
    if (-not $idBox.Text.Trim()) { return }
    try {
        $mod = Get-RFModByWorkshopId -WorkshopId $idBox.Text.Trim() -WorkshopRoots @($workshopRow.TextBox.Text)
        $existing = @($script:mods | Where-Object { $_.WorkshopId -eq $mod.WorkshopId })
        if ($existing.Count -eq 0) { $script:mods += $mod }
        $idBox.Clear(); Update-ModGrid
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Не удалось добавить мод', 'OK', 'Error') }
})
$filterBox.Add_TextChanged({ Update-ModGrid })
$categoryBox.Add_SelectedIndexChanged({ Update-ModGrid })
$selectAllButton.Add_Click({ foreach ($row in $modsGrid.Rows) { $row.Cells['Check'].Value = Test-ModNeedsSearch $row.Tag } })
$clearButton.Add_Click({ foreach ($row in $modsGrid.Rows) { $row.Cells['Check'].Value = $false } })
$selectFoundButton.Add_Click({ foreach ($row in $resultsGrid.Rows) { if (-not $row.Cells['Install'].ReadOnly) { $row.Cells['Install'].Value = $true } } })
$installButton.Add_Click({ Start-InstallJob })
$searchCheckedButton.Add_Click({
    $selected = @($modsGrid.Rows | Where-Object { $_.Cells['Check'].Value -eq $true } | ForEach-Object { $_.Tag })
    Start-SearchJob -Mods $selected
})
$searchAllButton.Add_Click({ Start-SearchJob -Mods @($script:mods) })
$cancelButton.Add_Click({ if ($script:currentJob) { Stop-Job -Job $script:currentJob } })
$resultsGrid.Add_CellDoubleClick({
    param($sender, $eventArgs)
    if ($eventArgs.RowIndex -lt 0) { return }
    $url = [string]$resultsGrid.Rows[$eventArgs.RowIndex].Cells['Link'].Tag
    if ($url) { Start-Process $url }
})
$resultsGrid.Add_CurrentCellDirtyStateChanged({
    if ($resultsGrid.IsCurrentCellDirty -and $resultsGrid.CurrentCell.OwningColumn.Name -eq 'Russifier') {
        $resultsGrid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) | Out-Null
    }
})
$resultsGrid.Add_CellValueChanged({
    param($sender, $eventArgs)
    if ($eventArgs.RowIndex -lt 0 -or $resultsGrid.Columns[$eventArgs.ColumnIndex].Name -ne 'Russifier') { return }
    $row = $resultsGrid.Rows[$eventArgs.RowIndex]
    $result = $row.Tag
    if (-not $result -or @($result.Candidates).Count -eq 0) { return }
    $selectedText = [string]$row.Cells['Russifier'].Value
    $candidate = @($result.Candidates | Where-Object { (Get-CandidateDisplayText $_) -eq $selectedText } | Select-Object -First 1)
    if ($candidate.Count -gt 0) { Set-ResultRowCandidate -Row $row -Candidate $candidate[0] }
})
$resultsGrid.Add_DataError({ param($sender, $eventArgs) $eventArgs.ThrowException = $false })
$resultsGrid.Add_CellContentClick({
    param($sender, $eventArgs)
    if ($eventArgs.RowIndex -lt 0 -or $resultsGrid.Columns[$eventArgs.ColumnIndex].Name -ne 'Link') { return }
    $url = [string]$resultsGrid.Rows[$eventArgs.RowIndex].Cells['Link'].Tag
    if ($url) { Start-Process $url }
})
$exportButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'HTML-отчёт|*.html|JSON|*.json|CSV|*.csv'
    $dialog.FileName = 'russifier_report.html'
    $dialog.InitialDirectory = $PSScriptRoot
    if ($dialog.ShowDialog() -eq 'OK') {
        try {
            Export-RFReport -Results $script:results -Path $dialog.FileName
            $script:lastReport = $dialog.FileName
            $openReportButton.Enabled = $true
            $statusLabel.Text = "Отчёт сохранён: $($dialog.FileName)"
        } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Ошибка экспорта', 'OK', 'Error') }
    }
})
$openReportButton.Add_Click({ if ($script:lastReport -and (Test-Path -LiteralPath $script:lastReport)) { Start-Process $script:lastReport } })
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:currentJob -and $script:jobMode -eq 'install') {
        [Windows.Forms.MessageBox]::Show('Дождитесь завершения подписки и обновления ModsConfig.xml.', 'Установка выполняется', 'OK', 'Warning') | Out-Null
        $eventArgs.Cancel = $true
        return
    }
    if ($script:currentJob) {
        Stop-Job -Job $script:currentJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:currentJob -Force -ErrorAction SilentlyContinue
    }
})

[void]$form.ShowDialog()
