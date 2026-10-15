
#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^hyperv-sql-prepared-sealed-[a-f0-9]{64}$')][string]$ArtifactId,
    [Parameter(Mandatory)][string]$MediaRoot,
    [Parameter(Mandatory)][string]$SqlMediaPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSqlMediaSha256,
    [string]$StateRoot,
    [Parameter(Mandatory)][string]$EvidencePath
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module=$null;$mutex=$null;$runId=$null;$receipt=$null;$cleanup=$null;$primaryFailure=$null
function Assert-SsisFixtureAcceptance {
    param([bool]$Condition,[string]$Name)
    if(-not $Condition){throw "SSISDB_FIXTURE_ACCEPTANCE_FAILED:$Name"}
    Write-Host "PASS: $Name"
}
function Write-SsisFixtureEvidence {
    param($Receipt,$Cleanup,[string]$Path)
    $evidence=[ordered]@{
        Contract='SqlServerLab.SsisCatalogFixtureAcceptance/1.0'
        Status='PASSED'
        ExecutedAtUtc=[DateTime]::UtcNow.ToString('o')
        Provider='hyperv'
        OperatingSystem='windows'
        RunId=[string]$Receipt.Target.RunId
        InstanceId=[string]$Receipt.Target.InstanceId
        BindingStatus=[string]$Receipt.Target.BindingStatus
        SourceBinding=[string]$Receipt.Source.ConnectionBinding
        ConsumerRights=[string]$Receipt.Source.ConsumerRights
        SqlEngineMajor=[int]$Receipt.Sql.EngineMajor
        SsisMajor=[int]$Receipt.Ssis.Major
        Catalog=[string]$Receipt.Ssis.Catalog
        ExecutionIds=[ordered]@{
            Success=[string]$Receipt.Fixture.ExecutionIds.Success
            Failure=[string]$Receipt.Fixture.ExecutionIds.Failure
            Incomplete=[string]$Receipt.Fixture.ExecutionIds.Incomplete
        }
        ExecutionStatus=[ordered]@{
            Success=[int]$Receipt.Fixture.ExecutionStatus.Success
            Failure=[int]$Receipt.Fixture.ExecutionStatus.Failure
            Incomplete=[int]$Receipt.Fixture.ExecutionStatus.Incomplete
        }
        CatalogViews=@($Receipt.Fixture.CatalogViews)
        Cleanup=[string]$Cleanup.Cleanup
        CleanupStatus=[string]$Cleanup.Status
    }
    $directory=Split-Path -Parent $Path
    if($directory){$null=New-Item -ItemType Directory -Force -Path $directory}
    $temporary="$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try{$evidence|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $temporary -Encoding utf8;Move-Item -LiteralPath $temporary -Destination $Path -Force}
    finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}}
}
try {
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    Assert-SsisFixtureAcceptance ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Runner arbeitet erhöht'
    $null=Get-VMHost -ErrorAction Stop
    $mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke')
    $acquired=$false
    try { try{$acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10))}catch [Threading.AbandonedMutexException]{$acquired=$true};if(-not $acquired){throw 'SSISDB_FIXTURE_HOST_LOCK_TIMEOUT'} }
    catch {$mutex.Dispose();$mutex=$null;throw}
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    if(-not $StateRoot){$StateRoot=& $module {Get-LabStateRoot}}
    $receipt=New-SqlServerLabSsisCatalogFixture -ArtifactId $ArtifactId -MediaRoot $MediaRoot -SqlMediaPath $SqlMediaPath -ExpectedSqlMediaSha256 $ExpectedSqlMediaSha256 -StateRoot $StateRoot -Confirm:$false
    $runId=[string]$receipt.Target.RunId
    Assert-SsisFixtureAcceptance ($receipt.ContractVersion -ceq 'SqlServerLab.SsisCatalogFixture/1.0') 'Öffentlicher Fixture-Vertrag'
    Assert-SsisFixtureAcceptance ($receipt.Provider -ceq 'hyperv' -and $receipt.OperatingSystem -ceq 'windows' -and $receipt.Target.BindingStatus -ceq 'BOUND') 'Host-, Instanz- und Runbindung'
    Assert-SsisFixtureAcceptance ($receipt.Source.Status -ceq 'OWNED_READY' -and $receipt.Source.ConnectionBinding -ceq 'OWNED_PREPARED_HYPERV_RUN' -and $receipt.Source.ConsumerRights -ceq 'SYSADMIN_OBSERVED') 'Eigene Quelle und Rechtebindung'
    Assert-SsisFixtureAcceptance ($receipt.Sql.EngineMajor -eq 17 -and $receipt.Ssis.Major -eq 17 -and $receipt.Ssis.Catalog -ceq 'SSISDB_OBSERVED') 'Beobachtete SQL- und SSISDB-Version'
    Assert-SsisFixtureAcceptance (@($receipt.Fixture.CatalogViews) -contains 'catalog.executions' -and @($receipt.Fixture.CatalogViews) -contains 'catalog.event_messages') 'Reale Catalog-Views beobachtet'
    $ids=@($receipt.Fixture.ExecutionIds.Success,$receipt.Fixture.ExecutionIds.Failure,$receipt.Fixture.ExecutionIds.Incomplete)
    Assert-SsisFixtureAcceptance ($ids.Count -eq 3 -and @($ids|Select-Object -Unique).Count -eq 3 -and @($ids|Where-Object {[string]::IsNullOrWhiteSpace([string]$_)}).Count -eq 0) 'Drei eigene Execution-IDs'
    Assert-SsisFixtureAcceptance ($receipt.Fixture.ExecutionStatus.Success -in @(7,9) -and $receipt.Fixture.ExecutionStatus.Failure -in @(4,6,9) -and $receipt.Fixture.ExecutionStatus.Incomplete -eq 1) 'Erfolgs-, Fehler- und unvollständiger Loggingfall'
}
catch {$primaryFailure=$_}
finally {
    if($runId -and $module){
        try {
            $cleanup=Remove-SqlServerLab -RunId $runId -StateRoot $StateRoot -Force -Confirm:$false
            if($cleanup.Status -ne 'REMOVED' -or $cleanup.Cleanup -ne 'CLEANUP_SUCCEEDED'){throw 'SSISDB_FIXTURE_CLEANUP_INCOMPLETE'}
        } catch {
            if($primaryFailure){$primaryFailure=[System.Management.Automation.RuntimeException]::new('SSISDB_FIXTURE_ACCEPTANCE_AND_CLEANUP_FAILED')}
            else{$primaryFailure=$_}
        }
    }
    if(-not $primaryFailure -and $receipt -and $cleanup){Write-SsisFixtureEvidence -Receipt $receipt -Cleanup $cleanup -Path $EvidencePath}
    if($module){Remove-Module $module.Name -Force -ErrorAction SilentlyContinue}
    if($mutex){$mutex.ReleaseMutex();$mutex.Dispose()}
}
if($primaryFailure){throw $primaryFailure}
Write-Host 'SSISDB_FIXTURE_ACCEPTANCE_PASSED'

