#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft Northwind, Chinook und persistentes Retrieval in einem eigenen Podman-Run.
.DESCRIPTION
    Der Parent persistiert die Operation vor New und überwacht getrennte Prozesse
    für Acceptance und Cleanup. Lokale Rohdaten bleiben im privaten Evidence-Root.
#>
[CmdletBinding()]
param(
    [ValidateRange(1024,65535)][int]$LocalPort=11434,
    [ValidateRange(1,3600)][int]$TimeoutSeconds=900,
    [ValidateRange(1,900)][int]$CleanupTimeoutSeconds=240,
    [switch]$RuntimeMutexAlreadyHeld
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Tests/Common/AiPodmanSamplesReferenceSupervisor.ps1')
$mutex=$null;$held=$false
try {
    if(-not $RuntimeMutexAlreadyHeld){
        $name=if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}
        $mutex=[Threading.Mutex]::new($false,$name)
        try{$held=$mutex.WaitOne([TimeSpan]::FromMinutes(10))}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw 'AI_PODMAN_SAMPLES_RUNTIME_LOCKED'}
    }
    $root=New-AiPodmanSamplesReferenceRoot
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    # Every native process in this read-only probe has a bounded timeout.
    $scope=& $module { Get-LabAiPodmanSetupRuntimeScope }
    if($scope.Status -cne 'AVAILABLE' -or $scope.RuntimeId -cnotmatch '^runtime-scope-[a-f0-9]{24}$'){
        throw 'AI_PODMAN_SAMPLES_RUNTIME_UNAVAILABLE'
    }
    $operation=[ordered]@{
        OperationId=[guid]::NewGuid().ToString('D');RuntimeScopeId=$scope.RuntimeId
        StateRoot=(Join-Path $root 'state');DataRoot=(Join-Path $root 'Lab_Data')
        CollectionId=[guid]::NewGuid().ToString('D');LocalPort=$LocalPort;NewStarted=$false
    }
    $null=New-Item -ItemType Directory -Path $operation.StateRoot,$operation.DataRoot
    [IO.File]::WriteAllText((Join-Path $root 'operation.json'),($operation|ConvertTo-Json -Compress))
    $result=Invoke-AiPodmanSamplesReferenceSequence -EvidenceRoot $root -OperationId $operation.OperationId `
        -WorkerPath (Join-Path $repoRoot 'Tests/Integration/Support/Invoke-AiPodmanSamplesReferenceWorker.ps1') `
        -TimeoutSeconds $TimeoutSeconds -CleanupTimeoutSeconds $CleanupTimeoutSeconds
    Write-Host ('PRIMARY='+$result.Primary.Status+'; PRIMARY_REASON='+$result.Primary.Reason+
        '; CLEANUP='+$result.Cleanup.Status+'; CLEANUP_REASON='+$result.Cleanup.Reason)
    if($result.Primary.Status -cne 'COMPLETED' -or $result.Cleanup.Status -cne 'COMPLETED'){
        throw 'AI_PODMAN_SAMPLES_REFERENCE_FAILED'
    }
    Write-Host ('PASS: AI_PODMAN_SAMPLES_REFERENCE_COMPLETED; ASSERTIONS='+$result.Primary.Assertions)
}
finally {if($mutex){if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}}
