#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft hostseitige Job-Rueckmeldung, Ausgaben, Fehler und begrenztes Cleanup.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
foreach($source in @('ConsoleUi','ActionProgress','JobProgress')){. (Join-Path $repoRoot "Private/$source.ps1")}
$reports=[Collections.Generic.List[object]]::new()
$receivePreferences=[Collections.Generic.List[string]]::new()
function Receive-Job {
    [CmdletBinding()]
    param($Job)
    $receivePreferences.Add([string]$ProgressPreference)
    Microsoft.PowerShell.Core\Receive-Job -Job $Job -ErrorAction Stop
}
$start=${function:Start-LabActionProgress}
function Start-LabActionProgress {param($Phase);$context=& $start -Phase $Phase;$context.Enabled=$true;return $context}
function Write-Progress {
    param($Id,$Activity,$Status,$CurrentOperation,$PercentComplete,[switch]$Completed)
    $reports.Add([pscustomobject]@{Status=$Status;Detail=$CurrentOperation;Percent=$PercentComplete;Completed=[bool]$Completed})
}
function Assert-JobProgress {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "FAIL: $Name"};Write-Host "PASS: $Name"}
$jobs=[Collections.Generic.List[object]]::new()
try {
    $other=Start-Job {'unrelated'};$jobs.Add($other)
    $job=Start-Job {Start-Sleep -Seconds 6;[pscustomobject]@{Value=17};'synthetic-output'};$jobs.Add($job)
    $jobId=$job.Id
    $output=@(Receive-LabProgressJob -Job $job)
    Assert-JobProgress ($output.Count -eq 2 -and $output[0].Value -eq 17 -and $output[1] -eq 'synthetic-output') 'Job-Ergebnisobjekte und Reihenfolge bleiben erhalten'
    Assert-JobProgress (@($reports | Where-Object {-not $_.Completed}).Count -gt 0 -and $reports[-1].Completed) 'Stiller sechssekündiger Job meldet Host-Heartbeat und Abschluss'
    Assert-JobProgress (@($reports | Where-Object {-not $_.Completed -and $_.Percent -ne -1}).Count -eq 0) 'Keine erfundenen Prozentwerte für Gastjobs'
    Assert-JobProgress ($null -eq (Get-Job -Id $jobId -ErrorAction SilentlyContinue) -and $null -ne (Get-Job -Id $other.Id -ErrorAction SilentlyContinue)) 'Cleanup entfernt genau den eigenen Job'
    $job=Start-Job {Write-Error -Message 'SYNTHETIC_OPEN_ERROR' -Category OpenError -ErrorAction Stop};$jobs.Add($job)
    $category='';$failure=''
    try{Receive-LabProgressJob -Job $job}catch{$category=[string]$_.CategoryInfo.Category;$failure=$_.Exception.Message}
    Assert-JobProgress ($category -eq 'OpenError' -and $failure -match 'SYNTHETIC_OPEN_ERROR') 'OpenError bleibt fuer den bestehenden Remoting-Retry erkennbar'
    $job=Start-Job {Start-Sleep -Seconds 20};$jobs.Add($job);$jobId=$job.Id
    $failure='';$elapsed=[Diagnostics.Stopwatch]::StartNew()
    try{Receive-LabProgressJob -Job $job -TimeoutSeconds 1}catch{$failure=$_.Exception.Message}
    Assert-JobProgress ($failure -eq 'GUEST_JOB_OPERATION_TIMEOUT' -and $elapsed.Elapsed.TotalSeconds -lt 10 -and $null -eq (Get-Job -Id $jobId -ErrorAction SilentlyContinue)) 'Deadline stoppt und entfernt den eigenen laufenden Job'
    $shared=Start-LabActionProgress -Phase GuestWait
    $job=Start-Job {23};$jobs.Add($job)
    $result=Receive-LabProgressJob -Job $job -Progress $shared
    Assert-JobProgress ($result -eq 23 -and -not $shared.Completed) 'Geborgter Reporter bleibt fuer weitere Probes offen'
    $shared.StartedAt=[datetime]::UtcNow.AddSeconds(-6);$before=$reports.Count
    Wait-LabProgressDelay -Progress $shared -Milliseconds 300
    Assert-JobProgress ($reports.Count -gt $before) 'Auch hostseitige Poll-Pausen aktualisieren den gemeinsamen Reporter'
    Stop-LabActionProgress -Progress $shared
    Assert-JobProgress (($reports | ConvertTo-Json -Compress) -notmatch 'SYNTHETIC_OPEN_ERROR|synthetic-output|unrelated') 'Native Fehler und Ausgaben bleiben aus der Fortschrittsanzeige'
    Assert-JobProgress ($receivePreferences.Count -gt 0 -and @($receivePreferences | Where-Object {$_ -ne 'SilentlyContinue'}).Count -eq 0) 'Spaete Gast-ProgressRecords werden beim Empfang unterdrueckt'
}
finally {
    foreach($ownedJob in $jobs){if(Get-Job -Id $ownedJob.Id -ErrorAction SilentlyContinue){Stop-Job -Job $ownedJob;Remove-Job -Job $ownedJob}}
}
