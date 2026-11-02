[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$config=Join-Path $ProjectRoot 'config\accounts.json'
$log=Join-Path $ProjectRoot 'logs\manager.log'
$mutex=[Threading.Mutex]::new($false,'Local\CodexAccountManager.AddAccount')
if(-not$mutex.WaitOne(0)){throw 'Another account login is already running'}
function Write-Log([string]$m){Add-Content -LiteralPath $log -Value ((Get-Date).ToString('o')+' [ADD] '+$m) -Encoding UTF8}
function Next-Key([object[]]$items){$used=@();foreach($item in $items){$v=[string]$item.Key;if($v.Length -eq 1){$used+=[int][char]$v}};foreach($n in 65..90){if($used -notcontains $n){return [char]$n}};throw 'No free account key'}
function Send-Rpc($p,[string]$json){$p.StandardInput.WriteLine($json);$p.StandardInput.Flush()}
try{$raw=Get-Content -LiteralPath $config -Raw|ConvertFrom-Json;if($raw.PSObject.Properties['value'] -and $raw.PSObject.Properties['Count']){$items=@($raw.value)}else{$items=@($raw)}}catch{throw "Cannot read accounts registry: $($_.Exception.Message)"}
$key=Next-Key $items
$key=[string]$key;$newHome=Join-Path $env:USERPROFILE ('.codex-account-'+$key.ToLower());$state=Join-Path $env:LOCALAPPDATA ('CodexAccountManager\QuotaState\'+$key);$userData=Join-Path $env:LOCALAPPDATA ('CodexAccountManager\'+$key+'\UserData')
if(Test-Path -LiteralPath $newHome){if(@($items|Where-Object {[string]$_.Key -eq $key}).Count -gt 0){throw "Target Home exists: $newHome"};Write-Log "account=$key reusing unregistered login Home"}
New-Item -ItemType Directory -Force $newHome,$state,$userData|Out-Null
$exe=Get-ChildItem (Join-Path $env:USERPROFILE '.codex\packages\app-server-daemon\releases') -Filter codex.exe -Recurse -File|Select-Object -First 1 -ExpandProperty FullName
if(-not$exe){throw 'Codex app-server executable not found'}
$si=[Diagnostics.ProcessStartInfo]::new();$si.FileName=$exe;$si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true;$si.Environment['CODEX_HOME']=$newHome
if($si.ArgumentList){foreach($x in @('app-server','--listen','stdio://','-c',('sqlite_home="'+$state+'"'))){[void]$si.ArgumentList.Add($x)}}else{$si.Arguments='app-server --listen stdio:// -c sqlite_home="'+$state+'"'}
$p=[Diagnostics.Process]::new();$p.StartInfo=$si;[void]$p.Start();$errTask=$p.StandardError.ReadToEndAsync();$deadline=(Get-Date).AddMinutes(10);$id=0;$loginId=$null;$account=$null
try {
 Send-Rpc $p '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-account-manager","title":"Codex Account Manager","version":"0.4.0"}}}'
 Send-Rpc $p '{"jsonrpc":"2.0","method":"initialized","params":{}}'
 Send-Rpc $p '{"jsonrpc":"2.0","id":2,"method":"account/login/start","params":{"type":"chatgpt","useHostedLoginSuccessPage":true,"appBrand":"chatgpt"}}'
 while((Get-Date)-lt$deadline){$line=$p.StandardOutput.ReadLine();if($null-eq$line){if($p.HasExited){throw 'App Server exited during login'};Start-Sleep -Milliseconds 100;continue};try{$j=$line|ConvertFrom-Json}catch{continue};if($j.id -eq 2){$loginId=[string]$j.result.loginId;$url=[string]$j.result.authUrl;if(-not$url){throw 'Login response did not contain authUrl'};Start-Process $url;Write-Log "account=$key login browser opened"}elseif($j.method -eq 'account/login/completed' -and ([string]$j.params.loginId -eq $loginId)) {if(-not$j.params.success){throw "Login failed: $($j.params.error)"};break}}
 if(-not$loginId){throw 'No loginId received'}
 Send-Rpc $p '{"jsonrpc":"2.0","id":3,"method":"account/read","params":{}}'
 while((Get-Date)-lt$deadline){$line=$p.StandardOutput.ReadLine();if($null-eq$line){continue};try{$j=$line|ConvertFrom-Json}catch{continue};if($j.id -eq 3){$account=$j.result.account;break}}
 if(-not$account.email){throw 'Login completed but account/read returned no email'}
 $saved=[pscustomobject]@{Key=$key;Email=[string]$account.email;Plan=[string]$account.planType;Home=$newHome;State=$state;UserData=$userData;CreatedAt=(Get-Date).ToString('o');Status='verified'}
 $raw2=Get-Content -LiteralPath $config -Raw|ConvertFrom-Json;if($raw2.PSObject.Properties['value'] -and $raw2.PSObject.Properties['Count']){$current=@($raw2.value)}else{$current=@($raw2)};if(@($current|Where-Object {[string]$_.Key -eq $key}).Count -gt 0){throw "Account key $key was taken during login"};$items=@($current)+$saved;$tmp=$config+'.tmp-'+[guid]::NewGuid().ToString('N');$items|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $tmp -Encoding UTF8;Move-Item -LiteralPath $tmp -Destination $config -Force
 Write-Log "account=$key login verified email=$($account.email)";Write-Output ($saved|ConvertTo-Json -Depth 5)
} finally {if($p -and -not$p.HasExited){$p.Kill()};if($p){$p.Dispose()};$mutex.ReleaseMutex();$mutex.Dispose()}
