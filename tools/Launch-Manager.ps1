$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$log=Join-Path $project 'logs\startup-errors.log'
try {
    $script=Join-Path $project 'src\CodexAccountManager.ps1'
    $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script + '"'
    Start-Process -FilePath $ps -Verb RunAs -WorkingDirectory $project -ArgumentList $arguments -PassThru | Out-Null
} catch {
    Add-Content -LiteralPath $log -Value ("$(Get-Date -Format o) [LAUNCH] type=$($_.Exception.GetType().FullName) message=$($_.Exception.Message)") -Encoding UTF8
    exit 1
}
