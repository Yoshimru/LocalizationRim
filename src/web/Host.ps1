param([Parameter(Mandatory)][string]$ProjectRoot)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
try{[Diagnostics.Process]::GetCurrentProcess().PriorityClass='AboveNormal'}catch{}
$tcp=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$tcp.Start();$port=([Net.IPEndPoint]$tcp.LocalEndpoint).Port;$tcp.Stop()
$token=[guid]::NewGuid().ToString('N');$runtime=Join-Path $ProjectRoot 'runtime';New-Item -ItemType Directory $runtime -Force|Out-Null
$server=Join-Path $PSScriptRoot 'Server.ps1';$stdout=Join-Path $runtime 'web-backend.log';$stderr=Join-Path $runtime 'web-backend-error.log'
$args='-NoProfile -ExecutionPolicy Bypass -File "{0}" -Port {1} -Token "{2}" -ProjectRoot "{3}"' -f $server,$port,$token,$ProjectRoot
$process=Start-Process powershell.exe -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
try{$process.PriorityClass='AboveNormal'}catch{}
$base="http://127.0.0.1:$port";$client=New-Object Net.WebClient;$ready=$false
for($i=0;$i-lt80;$i++){try{$null=$client.DownloadString("$base/health");$ready=$true;break}catch{Start-Sleep -Milliseconds100}}
if(-not$ready){throw "HTTP backend не запустился. См. $stderr"}
$sdk=Join-Path $ProjectRoot 'bin\webview2';$env:PATH="$sdk;$env:PATH"
Add-Type -Path (Join-Path $sdk 'Microsoft.Web.WebView2.Core.dll')
$form=New-Object Windows.Forms.Form;$form.Text='LocalizationRim';$form.StartPosition='CenterScreen';$form.Size=New-Object Drawing.Size(1440,900);$form.MinimumSize=New-Object Drawing.Size(1050,700);$form.BackColor=[Drawing.Color]::FromArgb(12,18,28)
$surface=New-Object Windows.Forms.Panel;$surface.Dock='Fill';$surface.BackColor=[Drawing.Color]::FromArgb(12,18,28);[void]$form.Controls.Add($surface)
$form.Show();[Windows.Forms.Application]::DoEvents()
$userData=Join-Path $runtime 'webview2-user-data'
$browserArguments='--disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows'
$environmentOptions=[Microsoft.Web.WebView2.Core.CoreWebView2EnvironmentOptions]::new($browserArguments,$null,$null,$false,$null)
$environmentTask=[Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($null,$userData,$environmentOptions)
while(-not$environmentTask.IsCompleted){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 15}
$environment=$environmentTask.GetAwaiter().GetResult()
$controllerTask=$environment.CreateCoreWebView2ControllerAsync($surface.Handle)
while(-not$controllerTask.IsCompleted){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 15}
$controller=$controllerTask.GetAwaiter().GetResult();$controller.Bounds=$surface.ClientRectangle;$controller.IsVisible=$true
$surface.Add_Resize({if($controller){$controller.Bounds=$surface.ClientRectangle}})
$controller.CoreWebView2.Navigate("$base/?token=$token")
$form.Add_FormClosed({try{$controller.Close()}catch{};try{$wc=New-Object Net.WebClient;$wc.Headers.Add('X-RF-Token',$token);$null=$wc.DownloadString("$base/api/shutdown")}catch{};if(-not$process.HasExited){Stop-Process $process -Force}})
[Windows.Forms.Application]::Run($form)
