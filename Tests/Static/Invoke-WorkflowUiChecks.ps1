#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$serverPath = Join-Path $repoRoot 'Tools/Start-SqlServerLabUi.ps1'
$workflowPath = Join-Path $repoRoot 'Public/Get-SqlServerLabWorkflow.ps1'
$actionPath = Join-Path $repoRoot 'Public/Invoke-SqlServerLabWorkflowAction.ps1'
$htmlPath = Join-Path $repoRoot 'Ui/index.html'
$scriptPath = Join-Path $repoRoot 'Ui/app.js'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Workflow UI Checks' -ForegroundColor Cyan

$serverText = Get-Content -LiteralPath $serverPath -Raw -Encoding utf8
$workflowText = Get-Content -LiteralPath $workflowPath -Raw -Encoding utf8
$actionText = Get-Content -LiteralPath $actionPath -Raw -Encoding utf8
$htmlText = Get-Content -LiteralPath $htmlPath -Raw -Encoding utf8
$scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8

Add-CheckResult -Name 'UI lauscht ausschliesslich auf Loopback' -Success (
    $serverText.Contains('http://127.0.0.1:$Port/') -and
    $serverText.Contains('[Net.IPAddress]::IsLoopback')
)
Add-CheckResult -Name 'UI stellt Workflow- und Hintergrundjob-API bereit' -Success (
    $serverText -match "/api/workflow" -and
    $serverText -match "/api/jobs" -and
    $serverText -match "/api/actions" -and
    $serverText -match 'Start-ThreadJob'
)
Add-CheckResult -Name 'Workflow fasst Baselines, SQL-Images und offene Builds zusammen' -Success (
    $workflowText -match 'WindowsBaselines' -and
    $workflowText -match 'SqlPreparedImages' -and
    $workflowText -match 'PendingSqlBuilds' -and
    $workflowText -match 'NextStep'
)
Add-CheckResult -Name 'UI-Aktionen halten Gastpasswoerter nur fluechtig' -Success (
    $actionText.Contains('[SecureString]$GuestPassword') -and
    $actionText.Contains('[SecureString]$SaPassword') -and
    $serverText -match 'ConvertTo-SecureString' -and
    $serverText -notmatch 'Write-Output.*GuestPassword' -and
    $serverText -notmatch 'Write-Output.*SaPassword'
)
Add-CheckResult -Name 'Browser-Oberflaeche zeigt Workflow und Live-Log' -Success (
    $htmlText -match 'GEFÜHRTER WORKFLOW' -and
    $htmlText -match 'Live-Log' -and
    $scriptText -match 'Nächster Schritt' -and
    $scriptText -match 'refreshJobs' -and
    $scriptText -match 'SQL-PrepareImage fortsetzen' -and
    $htmlText -match 'Neue Container-Umgebung' -and
    $scriptText -match 'CreateContainerDatabase' -and
    $scriptText -match 'dateToGerman'
)
Add-CheckResult -Name 'Evaluationdatum ist lesbar vorausgefüllt und Abbruch bleibt möglich' -Success (
    $htmlText -match 'type="text"' -and
    $htmlText -match 'TT\.MM\.JJJJ' -and
    $scriptText -match "event\.submitter\?\.value === 'cancel'" -and
    $scriptText -match 'parseGermanDate'
)
Add-CheckResult -Name 'UI-Jobs unterdrücken Modul-Ladeausgaben und zeigen Laufzeit' -Success (
    $serverText -match "InformationPreference = 'SilentlyContinue'" -and
    $serverText -match 'ElapsedSeconds' -and
    $scriptText -match 'job-progress'
)

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
