#Requires -Version 7.2
<#
.SYNOPSIS
    Checks the actual read-only CMS worker against one fresh owned SQL 2025 run.
.DESCRIPTION
    Requires an already reachable Docker or Podman runtime. The exact fresh
    sql-lab-cms-inspection-<GUID N> parent receives separate parent/State policies.
    Registration and synthetic CMS metadata are arrangement, completed before
    inspection. This does not test sync, SSMS, member connections or least privilege.
    Unreturned creation, custody drift or failed acceptance retains the parent.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [Parameter(Mandatory)][string]$DataRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$ParentOperationId
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repo Tests/Common/OwnedHostTestScope.ps1)
. (Join-Path $repo Tests/Common/ConnectionCenterCmsInspectionAcceptance.ps1)
$root=Assert-CmsInspectionAcceptanceLayout -DataRoot $DataRoot -RepositoryRoot $repo
$mutex=$null;$locked=$false;$module=$null;$scope=$null;$custody=$null;$evidence=$null
$unreturnedCreation=$false;$completed=$false;$primaryError=$null;$cleanupError=$null;$cleanup=$null;$readiness=$null
$observations=[Collections.Generic.List[object]]::new()
$oldState=$env:SQL_SERVER_LAB_STATE;$oldData=$env:SQL_SERVER_LAB_DATA_ROOT
try {
    $mutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}))
    $locked=$mutex.WaitOne([TimeSpan]::FromSeconds(60))
    if(-not $locked){throw 'CMS_ACCEPTANCE_MUTEX_TIMEOUT'}
    $resolution=@(& (Join-Path $repo Tools/Initialize-SqlServerLabHostTools.ps1) -Name $Provider)[0]
    if(-not $resolution.Available){throw 'CMS_ACCEPTANCE_TOOL_UNAVAILABLE'}
    $module=Import-Module (Join-Path $repo SqlServerLab.psd1) -Force -PassThru -DisableNameChecking
    $evidence=New-CmsInspectionAcceptanceEvidenceDirectory -Module $module -RepositoryRoot $repo
    $scope=New-CmsInspectionAcceptanceScope -Module $module -DataRoot $root -Provider $Provider -ParentOperationId $ParentOperationId
    # The real NoProfile worker inherits these exact roots, not a parent mock.
    $env:SQL_SERVER_LAB_STATE=$scope.StateRoot;$env:SQL_SERVER_LAB_DATA_ROOT=$scope.DataRoot
    Assert-CmsInspectionAcceptanceRoute $module $scope $Provider
    $readiness=Test-SqlServerLabPrerequisite -Provider $Provider -StateRoot $scope.StateRoot
    if($readiness.Status -cne 'RESOURCE_OK'){throw 'CMS_ACCEPTANCE_READINESS_BLOCKED'}
    $password=[Security.SecureString]::new()
    foreach($character in ('CmsInspection!aA7_'+[guid]::NewGuid().ToString('N')).ToCharArray()){$password.AppendChar($character)}
    $password.MakeReadOnly();$unreturnedCreation=$true
    try {
        $lab=New-SqlServerLab -Version 2025 -Provider $Provider -Profile compact -Cpu 1 -MemoryMB 2560 -LabName cms-inspection -StateRoot $scope.StateRoot -SaPassword $password -SkipAssessment
    }finally{$password.Dispose()}
    $parsed=[guid]::Empty
    if(-not [guid]::TryParseExact([string]$lab.RunId,'D',[ref]$parsed) -or $parsed -eq [guid]::Empty){throw 'CMS_ACCEPTANCE_RETURNED_RUN_INVALID'}
    $custody=Get-CmsInspectionAcceptanceCustody -Module $module -Scope $scope -RunId $lab.RunId -Provider $Provider
    $unreturnedCreation=$false
    if($lab.State -cne 'Running'){throw 'CMS_ACCEPTANCE_INSTALLATION_NOT_RUNNING'}
    $custody|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $evidence custody.private.json) -Encoding utf8
    # This run was created by this invocation; never adopt a caller-selected run.
    $null=Register-SqlServerLabCmsEnvironment -RunId $custody.RunId -StateRoot $scope.StateRoot
    $before=Get-CmsInspectionAcceptanceFileBinding -DataRoot $root
    $view=(Invoke-SqlServerLabWorkflowAction -Action GetCmsInspectionState).Result
    Assert-CmsInspectionAcceptanceResult $view $custody $Provider $view.SelectionKey NOT_CHECKED CMS_INSPECTION_NOT_CHECKED
    if($view.SelectionKey -cnotmatch '^[a-f0-9]{64}$'){throw 'CMS_ACCEPTANCE_SELECTION_KEY'}
    $wrongKey=if($view.SelectionKey -ceq ('a'*64)){'b'*64}else{'a'*64}
    $stale=(Invoke-SqlServerLabWorkflowAction -Action InspectCms -ExpectedPlanKey $wrongKey).Result
    Assert-CmsInspectionAcceptanceResult $stale $custody $Provider $view.SelectionKey UNKNOWN CMS_INSPECTION_SELECTION_CHANGED
    $emptyBefore=Invoke-CmsInspectionAcceptanceSql $module $scope $custody
    $missing=(Invoke-SqlServerLabWorkflowAction -Action InspectCms -ExpectedPlanKey $view.SelectionKey).Result
    Assert-CmsInspectionAcceptanceRoute $module $scope $Provider
    Assert-CmsInspectionAcceptanceResult $missing $custody $Provider $view.SelectionKey UNKNOWN CMS_INSPECTION_SQL_RESULT_INVALID
    $emptyAfter=Invoke-CmsInspectionAcceptanceSql $module $scope $custody
    $after=Get-CmsInspectionAcceptanceFileBinding -DataRoot $root
    if(($emptyBefore|ConvertTo-Json -Compress) -cne ($emptyAfter|ConvertTo-Json -Compress) -or
        ($before|ConvertTo-Json -Depth 5 -Compress) -cne ($after|ConvertTo-Json -Depth 5 -Compress)){throw 'CMS_ACCEPTANCE_NEGATIVE_WRITE'}
    $observations.Add([pscustomobject]@{Stage='MISSING_ROOT';Status=$missing.Status;Code=$missing.Code;FilesEqual=$true;CmsTablesEqual=$true})
    # Separate own SQL arrangement: managed 2 groups/1 server, plus unmanaged
    # controls. Synthetic server names are never resolved or contacted.
    $sqlBefore=Invoke-CmsInspectionAcceptanceSql $module $scope $custody -Arrange
    $before=Get-CmsInspectionAcceptanceFileBinding -DataRoot $root
    for($ordinal=1;$ordinal -le 2;$ordinal++){
        Assert-CmsInspectionAcceptanceRoute $module $scope $Provider
        $current=(Invoke-SqlServerLabWorkflowAction -Action GetCmsInspectionState).Result
        Assert-CmsInspectionAcceptanceResult $current $custody $Provider $view.SelectionKey NOT_CHECKED CMS_INSPECTION_NOT_CHECKED
        $result=(Invoke-SqlServerLabWorkflowAction -Action InspectCms -ExpectedPlanKey $current.SelectionKey).Result
        Assert-CmsInspectionAcceptanceRoute $module $scope $Provider
        Assert-CmsInspectionAcceptanceResult $result $custody $Provider $current.SelectionKey OBSERVED CMS_INSPECTION_OBSERVED
        $currentSql=Invoke-CmsInspectionAcceptanceSql $module $scope $custody
        $currentFiles=Get-CmsInspectionAcceptanceFileBinding -DataRoot $root
        if(($sqlBefore|ConvertTo-Json -Compress) -cne ($currentSql|ConvertTo-Json -Compress) -or
            ($before|ConvertTo-Json -Depth 5 -Compress) -cne ($currentFiles|ConvertTo-Json -Depth 5 -Compress)){throw 'CMS_ACCEPTANCE_INSPECTION_WRITE'}
        $observations.Add([pscustomobject]@{Stage='MANAGED_FIXTURE';Ordinal=$ordinal;Status=$result.Status;Code=$result.Code;SqlMajor=$result.SqlMajor;ManagedGroupCount=$result.ManagedGroupCount;ManagedServerCount=$result.ManagedServerCount})
    }
    $sqlAfter=Invoke-CmsInspectionAcceptanceSql $module $scope $custody
    $after=Get-CmsInspectionAcceptanceFileBinding -DataRoot $root
    if(($sqlBefore|ConvertTo-Json -Compress) -cne ($sqlAfter|ConvertTo-Json -Compress) -or
        ($before|ConvertTo-Json -Depth 5 -Compress) -cne ($after|ConvertTo-Json -Depth 5 -Compress)){throw 'CMS_ACCEPTANCE_INSPECTION_WRITE'}
    [pscustomobject]@{Before=$before;After=$after;Equal=$true;CmsTablesBefore=$sqlBefore;CmsTablesAfter=$sqlAfter;CmsTablesEqual=$true}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $evidence readonly-bindings.private.json) -Encoding utf8
    $completed=$true
}catch{$primaryError=$_}
finally{
    try{$cleanup=Remove-CmsInspectionAcceptanceScope -Module $module -Scope $scope -Custody $custody -Provider $Provider -UnreturnedCreation $unreturnedCreation -Completed $completed -EvidenceRoot $evidence}
    catch{$cleanupError=$_}
    finally{
        $env:SQL_SERVER_LAB_STATE=$oldState;$env:SQL_SERVER_LAB_DATA_ROOT=$oldData
        try{if($locked){$mutex.ReleaseMutex()}}catch{if(-not $cleanupError){$cleanupError=$_}}
        try{if($mutex){$mutex.Dispose()}}catch{if(-not $cleanupError){$cleanupError=$_}}
    }
}
$status=if($primaryError -or $cleanupError -or -not $completed -or $cleanup.Status -cne 'CLEANED'){'RECOVERY_REQUIRED'}else{'PASS'}
$receipt=[pscustomobject]@{Contract='SqlServerLab.CmsNativeAcceptance/1.0';Provider=$Provider;Status=$status;Readiness=$(if($readiness){$readiness.Status}else{'NOT_EXECUTED'});
    Observations=@($observations);StaleSelectionVeto=$(if($completed){'PASS'}else{'NOT_CONFIRMED'});ReadonlyFilesAndCmsTables=$(if($completed){'PASS'}else{'NOT_CONFIRMED'});
    Cleanup=$cleanup;UnreturnedCreation=$unreturnedCreation;PrimaryFailure=[bool]$primaryError;CleanupFailure=[bool]$cleanupError;
    Sync='NOT_EXECUTED';Ssms='NOT_EXECUTED';MemberConnections='NOT_EXECUTED';LeastPrivilege='NOT_EXECUTED';AtomicFilesystemProof=$false}
try{
    if($evidence){& $module {param($Path)$null=Assert-LabOwnedHostPath $Path} $evidence;$receipt|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $evidence result.private.json) -Encoding utf8}
}finally{if($module){Remove-Module $module -Force}}
if($primaryError){if($cleanupError){$primaryError.Exception.Data['CmsCleanupRecoveryRequired']=$true};throw $primaryError}
if($status -cne 'PASS'){throw 'CMS_ACCEPTANCE_RECOVERY_REQUIRED'}
Write-Host 'PASS: own native CMS worker/SQL inspection and receipt-bound cleanup.'
