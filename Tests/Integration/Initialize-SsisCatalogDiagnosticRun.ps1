#Requires -Version 7.2
<#
.SYNOPSIS
    Richtet einmalig einen eigenen Prepared-SQL-/IS-Run für fokussierte SSISDB-Diagnose ein.
.DESCRIPTION
    Behält den gebundenen Run ausdrücklich für folgende ExistingRun-Prüfungen.
    Nach Fixturefehlern wird weder der SQL-Slot neu aufgebaut noch dessen Zustand
    verworfen. Cleanup ausschließlich über Remove-SqlServerLab mit quittierter RunId.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^hyperv-sql-prepared-sealed-[a-f0-9]{64}$')][string]$ArtifactId,
    [Parameter(Mandatory)][string]$MediaRoot,
    [Parameter(Mandatory)][string]$SqlMediaPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSqlMediaSha256,
    [Parameter(Mandatory)][string]$StateRoot
)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
& $module {param($Root,$Repo) Assert-LabSsisEvidenceLocation -StateRoot $Root -RepositoryRoot $Repo} $StateRoot $repoRoot
$diagnostics=Join-Path $StateRoot 'diagnostics';$null=New-Item -ItemType Directory -Path $diagnostics -Force
$token=[guid]::NewGuid().ToString('N')
$log=Join-Path $diagnostics ('ssis-diagnostic-'+$token+'.private.log')
$recordPath=Join-Path $diagnostics ('ssis-diagnostic-'+$token+'.json')
$manifestPath=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ssis-diagnostic-'+$token+'.json')
$record=[pscustomobject]@{Status='PREPARING';RunId=$null;ScopeId=$null;Cleanup='REMOVE_EXACT_OWNED_RUN';OperationId=[string]$env:SQL_SERVER_LAB_TEST_OPERATION_ID}
function Invoke-PrivateSsisDiagnosticStep {
    param([scriptblock]$Step)
    & $Step 3>&1 6>&1 | ForEach-Object {
        if($_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord]){$_|Out-String|Add-Content -LiteralPath $log}else{$_}
    }
}
$guest=$null;$sa=$null
try {
    $approved=& $module {param($Root,$Relative,$Hash) Open-LabSsisApprovedMedia -MediaRoot $Root -SqlMediaPath $Relative -ExpectedSha256 $Hash} $MediaRoot $SqlMediaPath $ExpectedSqlMediaSha256
    $approved.Handle.Dispose()
    $guest=& $module {New-HyperVSqlUnattendedPassword};$sa=& $module {New-HyperVSqlUnattendedPassword}
    $manifest=@{name='ssis-diagnostic-fixture';instances=@(@{
        id='primary';provider='hyperv';os='windows';version='2025'
        windowsActivation=@{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='NotRequested';EgressPolicy='Denied'}
        hyperv=@{preparedImageId=$ArtifactId;memoryStartupMB=4096;processorCount=2;autostart='off';guestPasswordMode='prompt'}
    })}
    $manifest|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $manifestPath -Encoding utf8
    $created=Invoke-PrivateSsisDiagnosticStep {SqlServerLab\New-SqlServerLab -Manifest $manifestPath -GuestPassword $guest -SqlSaPassword $sa -NonInteractive -StateRoot $StateRoot}
    $record.RunId=[string]$created.RunId;$record.ScopeId=[string]$created.ScopeId;$record.Status='SQL_RUN_RETAINED'
    & $module {param($Path,$Record) Write-LabArtifactJsonAtomic -Path $Path -InputObject $Record} $recordPath $record
    Invoke-PrivateSsisDiagnosticStep {
        & $module {
            param($Id,$Root,$Password)
            $lab=Get-HyperVLabWorkflowRun -RunId $Id -StateRoot $Root
            Save-LabHyperVSqlSaPassword -RunDirectory $lab.RunDirectory -SqlSaPassword $Password -Generated
            Start-LabSsisOwnedProvisioningRun -RunId ([guid]$Id) -StateRoot $Root
        } $record.RunId $StateRoot $sa
    }
    $component=Invoke-PrivateSsisDiagnosticStep {SqlServerLab\Install-SqlServerLabSsisComponent -RunId ([guid]$record.RunId) -StateRoot $StateRoot -MediaRoot $MediaRoot -SqlMediaPath $SqlMediaPath -ExpectedSqlMediaSha256 $ExpectedSqlMediaSha256 -Confirm:$false}
    $record.Status='READY_FOR_EXISTING_RUN_DIAGNOSIS'
    & $module {param($Path,$Record) Write-LabArtifactJsonAtomic -Path $Path -InputObject $Record} $recordPath $record
    [pscustomobject]@{RunId=$record.RunId;Status=$record.Status;ComponentStatus=[string]$component.Status;Cleanup=$record.Cleanup}
} catch {
    $_.Exception.ToString()|Add-Content -LiteralPath $log
    $record.Status=if($record.RunId){'FAILED_OWN_RUN_RETAINED_FOR_DIAGNOSIS'}else{'PREPARATION_FAILED'}
    & $module {param($Path,$Record) Write-LabArtifactJsonAtomic -Path $Path -InputObject $Record} $recordPath $record
    throw ('SSIS_DIAGNOSTIC_PREPARATION_FAILED; RetainedRunId='+[string]$record.RunId)
} finally {
    if($guest){$guest.Dispose()};if($sa){$sa.Dispose()}
    if(Test-Path -LiteralPath $manifestPath){Remove-Item -LiteralPath $manifestPath -Force}
}
