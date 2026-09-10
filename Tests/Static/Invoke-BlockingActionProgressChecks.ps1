#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Private/ConsoleUi.ps1')
. (Join-Path $repoRoot 'Private/ActionProgress.ps1')
. (Join-Path $repoRoot 'Private/BlockingActionProgress.ps1')
. (Join-Path $repoRoot 'Private/HyperVLegacyWindowsEvaluationTemplate.ps1')
. (Join-Path $repoRoot 'Private/HyperVSqlAcceptanceEnvironment.ps1')
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
# Der SQL-Host wartet zwischen einzelnen WMI-Aufrufen auf den Gast-Receipt.
# Der synthetische Transport erzeugt weder Share, Task noch Datei. Die echte
# Wartefunktion und der echte Reporter laufen bis Rueckgabe und Cleanup.
& {
    $fixture=[pscustomobject]@{Sleeps=0;Heartbeat=$false;DriveRemoved=$false;TaskRemoved=$false;Owner=$null;Failure=$false}
    function Connect-HyperVLegacyWindowsWmiScope { param($Address,$Namespace,$Credential) [pscustomobject]@{} }
    function New-PSDrive { param($Name,$PSProvider,$Root,$Credential) [pscustomobject]@{Name=$Name} }
    function New-Item { param($Path,$ItemType,[switch]$Force) }
    function Set-Content { param($LiteralPath,$Value,$Encoding) }
    function Remove-Item { param($LiteralPath,[switch]$Force) }
    function Join-Path { param($Path,$ChildPath) "$Path/$ChildPath" }
    function Test-Path { param($LiteralPath,$PathType) $true }
    function Import-Csv {
        param($LiteralPath)
        if($fixture.Failure){return [pscustomobject]@{status='FAILED';errorCode='SYNTHETIC_FAILURE'}}
        [pscustomobject]@{status='COMPLETED';rowCount=7}
    }
    function Invoke-HyperVLegacyWindowsProcess {
        param($Scope,$CommandLine)
        if($CommandLine -match '/Delete'){$fixture.TaskRemoved=$true}
        1
    }
    function Remove-PSDrive { param($Name,[switch]$Force) $fixture.DriveRemoved=$true }
    function Start-Sleep {
        param($Seconds)
        $fixture.Sleeps++
        if($fixture.Sleeps -eq 2){
            $fixture.Owner=$script:LabBlockingActionHandle
            if($fixture.Owner){
                [Threading.Thread]::Sleep(5600)
                $fixture.Heartbeat=@($fixture.Owner.Pipeline.Streams.Progress).Count -gt 0
            }
        }
    }
    $credential=[pscredential]::new('synthetic',[securestring]::new())
    $invocation=@{Address='192.0.2.10';Credential=$credential;BuildId='00000000-0000-0000-0000-000000000001';Action='Synthetic';ScriptContent='synthetic';TimeoutSeconds=30}
    $receipt=Invoke-HyperVLegacyGuestSystemScript @invocation
    Assert-BlockingProgress ($fixture.Heartbeat -and $receipt.rowCount -eq 7) 'Legacy-SQL-Receipt-Wartephase besitzt einen durchgehenden Heartbeat und erhaelt die Ausgabe'
    Assert-BlockingProgress ($fixture.DriveRemoved -and $fixture.TaskRemoved -and $fixture.Owner.Completed -and $null -eq $script:LabBlockingActionHandle) 'Legacy-SQL-Erfolg beendet Transport und eigenen Reporter'
    $fixture.Failure=$true
    $fixture.DriveRemoved=$false;$fixture.TaskRemoved=$false
    $preserved=$false
    try{Invoke-HyperVLegacyGuestSystemScript @invocation | Out-Null}
    catch{$preserved=$_.Exception.Message -eq 'HYPERV_LEGACY_SYSTEM_TASK_FAILED: Synthetic/SYNTHETIC_FAILURE'}
    Assert-BlockingProgress ($preserved -and $fixture.DriveRemoved -and $fixture.TaskRemoved -and $script:lastBlockingProgress.Completed -and $null -eq $script:LabBlockingActionHandle) 'Legacy-SQL-Receipt-Fehler behaelt Ursache und bereinigt Transport und Reporter'
    $fixture.Failure=$false
    $parent=Start-LabBlockingActionProgress -Phase GuestWait
    try {
        $null=Invoke-HyperVLegacyGuestSystemScript @invocation
        Assert-BlockingProgress (-not $parent.Completed -and [object]::ReferenceEquals($parent,$script:LabBlockingActionHandle)) 'Legacy-SQL-Unteraufruf beendet keinen Reporter des aufrufenden Setups'
    }
    finally {Stop-LabBlockingActionProgress -Handle $parent}
    function Connect-HyperVLegacyWindowsWmiScope { param($Address,$Namespace,$Credential) throw 'SYNTHETIC_CONNECT_FAILURE' }
    $preserved=$false
    try{Invoke-HyperVLegacyGuestSystemScript @invocation | Out-Null}
    catch{$preserved=$_.Exception.Message -eq 'SYNTHETIC_CONNECT_FAILURE'}
    Assert-BlockingProgress ($preserved -and $script:lastBlockingProgress.Completed -and $null -eq $script:LabBlockingActionHandle) 'Legacy-SQL-Verbindungsfehler vor Transportbeginn beendet den Reporter'
}
Write-Host 'BLOCKING ACTION PROGRESS CHECKS: PASS'
