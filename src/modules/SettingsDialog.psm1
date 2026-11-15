Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-RFSettingsDialog {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$MachineModulePath,
        [System.Windows.Forms.IWin32Window]$Owner
    )
    Import-Module $MachineModulePath -Force
    $settings = Get-RFMachineSettings -ProjectRoot $ProjectRoot
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Настройки LocalizationRim'
    $form.StartPosition = 'CenterParent'
    $form.Size = New-Object Drawing.Size(620, 510)
    $form.MinimumSize = New-Object Drawing.Size(620, 510)
    $form.Font = New-Object Drawing.Font('Segoe UI', 9)

    $table = New-Object Windows.Forms.TableLayoutPanel
    $table.Dock = 'Fill'; $table.Padding = New-Object Windows.Forms.Padding(12); $table.ColumnCount = 2; $table.RowCount = 9
    [void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 185)))
    [void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$form.Controls.Add($table)

    function Add-RowLabel([string]$Text, [int]$Row) {
        $label = New-Object Windows.Forms.Label
        $label.Text = $Text; $label.AutoSize = $true; $label.Anchor = 'Left'
        [void]$table.Controls.Add($label, 0, $Row)
    }

    Add-RowLabel 'Провайдер:' 0
    $provider = New-Object Windows.Forms.ComboBox
    $provider.DropDownStyle = 'DropDownList'; $provider.Dock = 'Fill'
    [void]$provider.Items.AddRange(@('Google', 'Yandex', 'AgentRouter'))
    $provider.SelectedItem = [string]$settings.Provider
    if ($provider.SelectedIndex -lt 0) { $provider.SelectedIndex = 0 }
    [void]$table.Controls.Add($provider, 1, 0)

    Add-RowLabel 'OpenAI Base URL:' 1
    $baseUrl = New-Object Windows.Forms.TextBox; $baseUrl.Dock = 'Fill'; $baseUrl.Text = [string]$settings.BaseUrl
    [void]$table.Controls.Add($baseUrl, 1, 1)
    Add-RowLabel 'Модель:' 2
    $model = New-Object Windows.Forms.TextBox; $model.Dock = 'Fill'; $model.Text = [string]$settings.Model
    [void]$table.Controls.Add($model, 1, 2)
    Add-RowLabel 'API-ключ:' 3
    $apiKey = New-Object Windows.Forms.TextBox; $apiKey.Dock = 'Fill'; $apiKey.UseSystemPasswordChar = $true
    $apiKey.Text = Unprotect-RFMachineApiKey ([string]$settings.ApiKeyProtected)
    [void]$table.Controls.Add($apiKey, 1, 3)

    Add-RowLabel 'Параллельные запросы:' 4
    $concurrency = New-Object Windows.Forms.NumericUpDown
    $concurrency.Minimum = 1; $concurrency.Maximum = 16; $concurrency.Value = [Math]::Max(1, [Math]::Min(16, [int]$settings.MaxConcurrency)); $concurrency.Width = 90
    [void]$table.Controls.Add($concurrency, 1, 4)
    Add-RowLabel 'Тайм-аут, секунд:' 5
    $timeout = New-Object Windows.Forms.NumericUpDown
    $timeout.Minimum = 10; $timeout.Maximum = 600; $timeout.Value = [Math]::Max(10, [Math]::Min(600, [int]$settings.RequestTimeoutSeconds)); $timeout.Width = 90
    [void]$table.Controls.Add($timeout, 1, 5)
    Add-RowLabel 'Промпт AgentRouter:' 6
    $prompt = New-Object Windows.Forms.TextBox
    $prompt.Dock = 'Fill'; $prompt.Multiline = $true; $prompt.ScrollBars = 'Vertical'; $prompt.Height = 120; $prompt.Text = [string]$settings.CustomPrompt
    [void]$table.Controls.Add($prompt, 1, 6)

    $hint = New-Object Windows.Forms.Label
    $hint.Text = 'Google и Yandex работают без API-ключа. Для AgentRouter укажите OpenAI-compatible URL, модель и ключ. Ключ хранится в config/settings.json в зашифрованном для текущего пользователя виде.'
    $hint.AutoSize = $true; $hint.MaximumSize = New-Object Drawing.Size(550, 0); $hint.ForeColor = [Drawing.Color]::DimGray
    $table.SetColumnSpan($hint, 2); [void]$table.Controls.Add($hint, 0, 7)

    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.FlowDirection = 'RightToLeft'; $buttons.Dock = 'Fill'; $buttons.AutoSize = $true
    $save = New-Object Windows.Forms.Button; $save.Text = 'Сохранить'; $save.AutoSize = $true; $save.DialogResult = 'OK'
    $cancel = New-Object Windows.Forms.Button; $cancel.Text = 'Отмена'; $cancel.AutoSize = $true; $cancel.DialogResult = 'Cancel'
    $buttons.Controls.AddRange(@($save, $cancel)); $table.SetColumnSpan($buttons, 2); [void]$table.Controls.Add($buttons, 0, 8)
    $form.AcceptButton = $save; $form.CancelButton = $cancel

    $updateProviderState = {
        $enabled = [string]$provider.SelectedItem -eq 'AgentRouter'
        $baseUrl.Enabled = $enabled; $model.Enabled = $enabled; $apiKey.Enabled = $enabled; $prompt.Enabled = $enabled
    }
    $provider.Add_SelectedIndexChanged($updateProviderState); & $updateProviderState

    $dialogResult = if ($Owner) { $form.ShowDialog($Owner) } else { $form.ShowDialog() }
    if ($dialogResult -ne 'OK') { return $false }
    $settings.Provider = [string]$provider.SelectedItem
    $settings.BaseUrl = $baseUrl.Text.TrimEnd('/')
    $settings.Model = $model.Text.Trim()
    $settings.MaxConcurrency = [int]$concurrency.Value
    $settings.RequestTimeoutSeconds = [int]$timeout.Value
    $settings.CustomPrompt = $prompt.Text
    Save-RFMachineSettings -ProjectRoot $ProjectRoot -Settings $settings -PlainApiKey $apiKey.Text | Out-Null
    return $true
}

Export-ModuleMember -Function 'Show-RFSettingsDialog'
