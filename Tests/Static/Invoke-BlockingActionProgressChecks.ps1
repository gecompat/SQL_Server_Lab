#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Private/ConsoleUi.ps1')
. (Join-Path $repoRoot 'Private/ActionProgress.ps1')
. (Join-Path $repoRoot 'Private/BlockingActionProgress.ps1')
. (Join-Path $repoRoot 'Private/HyperVLegacyWindowsEvaluationTemplate.ps1')
function Assert-BlockingProgress {
    param([bool]$Condition,[string]$Name)
    if(-not $Condition){throw "FAIL: $Name"}
    Write-Host "PASS: $Name"
}
$progress=Start-LabActionProgress -Phase GuestWait
$progress.Enabled=$false
$silent=Start-LabBlockingActionProgress -Progress $progress
Stop-LabBlockingActionProgress -Handle $silent
Assert-BlockingProgress ($null -eq $silent.Pipeline -and -not $progress.Completed) 'Nichtinteraktive Aufrufe erzeugen keinen Worker und behalten geliehene Contexts'

$progress=Start-LabActionProgress -Phase GuestWait
$progress.Enabled=$true
$handle=Start-LabBlockingActionProgress -Progress $progress
try {
    $nested=Start-LabBlockingActionProgress -Phase GuestWait
    Stop-LabBlockingActionProgress -Handle $nested
    Assert-BlockingProgress ($nested.Borrowed -and -not $handle.Pending.IsCompleted) 'Verschachtelte WMI-Schritte teilen genau einen Reporter'
    # Kein PowerShell-Polling im aufrufenden Thread: simuliert blockierendes COM.
    [Threading.Thread]::Sleep(6400)
    $records=@($handle.Pipeline.Streams.Progress)
    Assert-BlockingProgress ($records.Count -ge 2 -and $records.Count -le 3 -and
        $records[0].StatusDescription -match '00:05.*Auf Gast warten' -and
        @($records | Where-Object PercentComplete -ne -1).Count -eq 0) 'Blockierter Hauptthread erhaelt gedrosselten Heartbeat ab fuenf Sekunden'
    $progress.Phase='Cleanup'
    [Threading.Thread]::Sleep(350)
    Assert-BlockingProgress ($handle.Pipeline.Streams.Progress[-1].StatusDescription -match 'Aufraeumen') 'Phasenwechsel verwendet denselben formatierten Reporter'
    $progress.Phase='secret=synthetic-private-path'
    [Threading.Thread]::Sleep(350)
    Assert-BlockingProgress (($handle.Pipeline.Streams.Progress | ConvertTo-Json -Depth 4) -notmatch 'synthetic-private-path|secret=') 'Auch der Worker gibt nur freigegebene Phasen aus'
}
finally {Stop-LabBlockingActionProgress -Handle $handle}
Assert-BlockingProgress ($handle.Completed -and -not $progress.Completed -and $null -eq $script:LabBlockingActionHandle) 'Worker-Cleanup laesst geliehenen Reporter beim Besitzer'
Stop-LabActionProgress -Progress $progress
Stop-LabBlockingActionProgress -Handle $handle

$originalStart=${function:Start-LabActionProgress}
function Start-LabActionProgress {
    param($Phase,[datetime]$Now=[datetime]::UtcNow)
    $script:lastBlockingProgress=& $originalStart -Phase $Phase -Now $Now
    $script:lastBlockingProgress.Enabled=$true
    $script:lastBlockingProgress
}
function Get-VMNetworkAdapter {
    [CmdletBinding()]
    param($VMName,$Name)
    throw 'SYNTHETIC_WMI_FAILURE'
}
$failurePreserved=$false
try{Get-HyperVLegacyWindowsGuestIPv4 -VMName synthetic -AdapterName synthetic | Out-Null}
catch{$failurePreserved=$_.Exception.Message -eq 'SYNTHETIC_WMI_FAILURE'}
Assert-BlockingProgress ($failurePreserved -and $script:lastBlockingProgress.Completed -and $null -eq $script:LabBlockingActionHandle) 'Legacy-Fehler bleibt erhalten und beendet seinen eigenen Worker'

# Wirklicher Pipeline-Abbruch waehrend eines synchronen .NET-Aufrufs. Die
# bestehende native Abbruchlatenz bleibt erhalten, danach muss finally greifen.
$cancelState=[hashtable]::Synchronized(@{Started=$false;Cleaned=$false;Progress=$null})
$ownerRunspace=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($Host)
$ownerRunspace.Open()
$owner=[Management.Automation.PowerShell]::Create()
$owner.Runspace=$ownerRunspace
try {
    $cancelWorker={
        param($Directory,$State)
        . (Join-Path $Directory 'ConsoleUi.ps1')
        . (Join-Path $Directory 'ActionProgress.ps1')
        . (Join-Path $Directory 'BlockingActionProgress.ps1')
        $State.Progress=Start-LabActionProgress -Phase GuestWait
        $State.Progress.Enabled=$true
        $ownedHandle=Start-LabBlockingActionProgress -Progress $State.Progress
        try {$State.Started=$true;[Threading.Thread]::Sleep(8000)}
        finally {
            Stop-LabBlockingActionProgress -Handle $ownedHandle
            Stop-LabActionProgress -Progress $State.Progress
            $State.Cleaned=$ownedHandle.Completed
        }
    }
    $null=$owner.AddScript($cancelWorker.ToString()).AddArgument((Join-Path $repoRoot 'Private')).AddArgument($cancelState)
    $pending=$owner.BeginInvoke()
    $startDeadline=[datetime]::UtcNow.AddSeconds(10)
    while(-not $cancelState.Started -and [datetime]::UtcNow -lt $startDeadline){[Threading.Thread]::Sleep(20)}
    Assert-BlockingProgress $cancelState.Started 'Abbruchfixture startet ihren eigenen Reporter'
    [Threading.Thread]::Sleep(5500)
    $owner.Stop()
    Assert-BlockingProgress ($pending.IsCompleted -and $cancelState.Cleaned -and $cancelState.Progress.Completed) 'Pipeline-Abbruch bereinigt Anzeige und Reporter-Runspace nach Rueckkehr des nativen Aufrufs'
}
finally {$owner.Dispose();$ownerRunspace.Dispose()}
Write-Host 'BLOCKING ACTION PROGRESS CHECKS: PASS'
