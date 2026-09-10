#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
foreach($source in @('ConsoleUi','ActionProgress','SessionTransferProgress')){. (Join-Path $repoRoot "Private/$source.ps1")}
$reports=[Collections.Generic.List[object]]::new()
$start=${function:Start-LabActionProgress}
function Start-LabActionProgress {param($Phase);$context=& $start -Phase $Phase;$context.Enabled=$true;return $context}
function Write-Progress {param($Id,$Activity,$Status,$CurrentOperation,$PercentComplete,[switch]$Completed);$reports.Add([pscustomobject]@{Status=$Status;Detail=$CurrentOperation;Percent=$PercentComplete;Completed=[bool]$Completed})}
function Assert-SessionProgress {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "FAIL: $Name"};Write-Host "PASS: $Name"}
$pipeline=[powershell]::Create()
$null=$pipeline.AddScript('Write-Progress -Activity "synthetic-private-path" -Status "synthetic-secret"; Start-Sleep -Seconds 6; [pscustomobject]@{Value=17}; "second"')
$result=@(Invoke-LabProgressPipeline -Pipeline $pipeline)
Assert-SessionProgress ($result.Count -eq 2 -and $result[0].Value -eq 17 -and $result[1] -eq 'second') 'Objekte und Reihenfolge bleiben erhalten'
Assert-SessionProgress (@($reports|Where-Object {-not $_.Completed}).Count -gt 0 -and $reports[-1].Completed) 'Stille Pipeline meldet Heartbeat und Abschluss'
Assert-SessionProgress (($reports|ConvertTo-Json -Compress) -notmatch 'synthetic-private-path|synthetic-secret') 'Rohe ProgressRecords gelangen nicht zur Hostanzeige'
Assert-SessionProgress (@($reports|Where-Object {-not $_.Completed -and $_.Percent -ne -1}).Count -eq 0) 'Keine erfundenen Prozentwerte'
$pipeline=[powershell]::Create();$null=$pipeline.AddScript('Write-Error "SYNTHETIC_COPY_FAILURE" -Category PermissionDenied -ErrorAction Stop')
$failure='';$category=''
try {Invoke-LabProgressPipeline -Pipeline $pipeline}catch{$failure=$_.Exception.Message;$category=[string]$_.CategoryInfo.Category}
Assert-SessionProgress ($failure -match 'SYNTHETIC_COPY_FAILURE' -and $category -eq 'PermissionDenied') 'Terminating ErrorRecord bleibt erhalten'
$pipeline=[powershell]::Create();$null=$pipeline.AddScript('Start-Sleep -Seconds 20')
$elapsed=[Diagnostics.Stopwatch]::StartNew();$failure=''
try {Invoke-LabProgressPipeline -Pipeline $pipeline -TimeoutSeconds 1}catch{$failure=$_.Exception.Message}
Assert-SessionProgress ($failure -eq 'SESSION_TRANSFER_OPERATION_TIMEOUT' -and $elapsed.Elapsed.TotalSeconds -lt 10 -and $reports[-1].Completed) 'Timeout stoppt eigene Pipeline und bereinigt Anzeige'
$shared=Start-LabActionProgress -Phase Transfer
$pipeline=[powershell]::Create();$null=$pipeline.AddScript('23')
$result=Invoke-LabProgressPipeline -Pipeline $pipeline -Progress $shared
Assert-SessionProgress ($result -eq 23 -and -not $shared.Completed) 'Geborgter Reporter bleibt offen'
Stop-LabActionProgress -Progress $shared
