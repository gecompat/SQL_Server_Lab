#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft die endgültige Löschung eines frischen eigenen SQL-2025-Instanzstores.
.DESCRIPTION
    Docker und Podman sind getrennte Nachweise. Der Supervisor hält den gemeinsamen
    Runtime-Testmutex, legt einen privaten isolierten StateRoot an und persistiert
    die eigene Operation vor New. Arbeits- und Cleanup-Prozesse sind zeitbegrenzt.
    Rohdaten bleiben privat lokal; ausgegeben wird ausschließlich der geschlossene
    Ergebnisstatus. Auch erfolgreiche lokale Evidence bleibt zur Prüfung erhalten.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [ValidateRange(60,3600)][int]$TimeoutSeconds=1200,
    [ValidateRange(30,900)][int]$CleanupTimeoutSeconds=300,
    [switch]$RuntimeMutexAlreadyHeld)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repo 'Tests/Common/RetainedStoreRemovalSupervisor.ps1')
$root=$null;$mutex=$null;$acquired=$false;$module=$null;$inputObject=$null
$primary=[pscustomobject]@{Status='FAILED';Reason='NOT_STARTED';TerminationConfirmed=$true;Assertions=0}
$cleanup=[pscustomobject]@{Status='NOT_EXECUTED';Reason='NOT_STARTED';TerminationConfirmed=$true;Assertions=0}
try {
    if(-not $RuntimeMutexAlreadyHeld){
        $name=if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}
        $mutex=[Threading.Mutex]::new($false,$name)
        try{$acquired=$mutex.WaitOne([TimeSpan]::FromSeconds(30))}catch [Threading.AbandonedMutexException]{$acquired=$true}
        if(-not $acquired){throw 'ACCEPTANCE_RUNTIME_MUTEX_TIMEOUT'}
    }
    $root=New-RetainedStoreAcceptanceRoot
    $module=Import-Module (Join-Path $repo 'SQLServerLab.psd1') -Force -PassThru
    $context=& $module {param($Provider)Get-LabRetainedStoreRuntimeContext -Provider $Provider} $Provider
    $inputObject=[pscustomobject]@{
        OperationId=[guid]::NewGuid().ToString('D');ControllerId=[guid]::NewGuid().ToString('D')
        Provider=$Provider;RuntimeScopeId=$context.RuntimeScopeId
        CreatedAt=[datetime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText((Join-Path $root 'operation.json'),($inputObject|ConvertTo-Json -Compress))
    $arguments=@{EvidenceRoot=$root;OperationId=$inputObject.OperationId;WorkerPath=(Join-Path $repo 'Tests/Common/RetainedStoreRemovalAcceptanceWorker.ps1')}
    $sequence=Invoke-RetainedStoreAcceptanceSequence @arguments -TimeoutSeconds $TimeoutSeconds -CleanupTimeoutSeconds $CleanupTimeoutSeconds
    $primary=$sequence.Primary;$cleanup=$sequence.Cleanup
}
catch {
    if($root){$_|Out-String|Set-Content -LiteralPath (Join-Path $root 'supervisor.private-error.log')}
    $primary=[pscustomobject]@{Status='FAILED';Reason='SUPERVISOR_FAILED';TerminationConfirmed=$false;Assertions=0}
}
finally {
    if($module){Remove-Module $module -Force}
    if($acquired){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
}
$success=$primary.Status -ceq 'COMPLETED' -and $cleanup.Status -ceq 'COMPLETED'
$receipt=[ordered]@{
    Status=if($success){'PASS'}else{'FAIL'};Provider=$Provider
    PrimaryReason=$primary.Reason;CleanupStatus=$cleanup.Status;CleanupReason=$cleanup.Reason
    Assertions=$primary.Assertions;CompletedAt=[datetime]::UtcNow.ToString('o')
}
if($root){
    [IO.File]::WriteAllText((Join-Path $root 'summary.json'),($receipt|ConvertTo-Json -Compress))
    $index=Join-Path $repo '.artifacts/test-runs/retained-store-removal'
    $null=New-Item -ItemType Directory -Path $index -Force
    $private=[ordered]@{EvidenceRoot=$root;Operation=$inputObject;Summary=$receipt}
    $name='native-'+$Provider+'-'+[guid]::NewGuid().ToString('N')+'.json'
    [IO.File]::WriteAllText((Join-Path $index $name),($private|ConvertTo-Json -Depth 10))
}
Write-Host "RETAINED_STORE_ACCEPTANCE: $($receipt.Status); PRIMARY=$($receipt.PrimaryReason); CLEANUP=$($receipt.CleanupStatus); CLEANUP_REASON=$($receipt.CleanupReason); ASSERTIONS=$($receipt.Assertions)"
if(-not $success){exit 1}
