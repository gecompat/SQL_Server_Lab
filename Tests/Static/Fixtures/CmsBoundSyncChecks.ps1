param([Parameter(Mandatory)][string]$Repository)
$ErrorActionPreference='Stop'
. (Join-Path $Repository 'Private/CmsBoundSync.ps1')
$expectedKey='a'*64
$runId='11111111-2222-4333-8444-555555555555'
$stateRoot=Join-Path ([IO.Path]::GetTempPath()) ('mock-cms-sync-'+[guid]::NewGuid().ToString('N'))
$case=[pscustomobject]@{Stage='ok';SelectionReads=0;RuntimeReads=0;Exports=0;Secrets=0;Sql=0;Credential=$null}
function Get-LabCmsInspectionSelection {
    param($StateRoot)
    $case.SelectionReads++
    [pscustomobject]@{
        RunId=$runId; StateRoot=$script:stateRoot; Provider='podman'
        Key=if ($case.Stage -eq 'stale' -or ($case.Stage -eq 'drift' -and $case.SelectionReads -ge 3)) { 'b'*64 } else { $expectedKey }
        Layout=@{CmsShowGeneratedPasswordInName=($case.Stage -eq 'alias')}
    }
}
function Get-LabContainerResourceLockName { param($StateRoot,$RunId) 'SQL_Server_Lab_Bound_Sync_Fixture_'+$StateRoot.GetHashCode() }
function Get-LabCmsInspectionRuntimeBinding {
    param($Selection)
    $case.RuntimeReads++
    [pscustomobject]@{Key=if ($case.Stage -eq 'native-drift' -and $case.RuntimeReads -gt 1) {'different'}else{'native'}
        HostName='127.0.0.1';Port=61433;ExpectedMajor=17}
}
function Export-SqlServerLabCmsSyncScript {
    [CmdletBinding()]
    param($StateRoot,$CmsProvider,[switch]$InMemory)
    if (-not $InMemory -or $CmsProvider -cne 'podman') { throw 'SYNTHETIC_EXPORT_INVALID' }
    $case.Exports++
    [pscustomobject]@{IncludesGeneratedPasswordAliases=$false;Entries=2;ScriptContent='SYNTHETIC_SQL_PAYLOAD'}
}
function Assert-LabCmsInspectionReadPath { param($Root,$Path) }
function Get-LabSecret {
    [CmdletBinding()]
    param($Path,$Name)
    if ($Name -cne 'sa-password') { throw 'SYNTHETIC_SECRET_NAME_INVALID' }
    $case.Secrets++
    $case.Credential=[SecureString]::new()
    return $case.Credential
}
function Invoke-LabCmsSqlInMemory {
    param($HostName,$Port,$SaPassword,$Query,$ExpectedSqlMajor)
    if ($HostName -cne '127.0.0.1' -or $Port -ne 61433 -or $SaPassword -isnot [SecureString] -or
        $Query -cne 'SYNTHETIC_SQL_PAYLOAD' -or $ExpectedSqlMajor -ne 17) { throw 'SYNTHETIC_SQL_BINDING_INVALID' }
    $case.Sql++
    [pscustomobject]@{Success=($case.Stage -ne 'sql-fail');Message='SYNTHETIC_RAW_FAILURE'}
}

$success=Invoke-LabCmsBoundSync -ExpectedRegistrationKey $expectedKey -StateRoot $stateRoot
if ($case.Sql -ne 1 -or $case.Secrets -ne 1 -or $case.Exports -ne 1 -or $case.RuntimeReads -ne 2 -or
    $success.Status -cne 'SYNCHRONIZED' -or $success.RunId -cne $runId -or $success.Entries -ne 2 -or
    ($success | ConvertTo-Json -Compress) -match 'SYNTHETIC|127\.0\.0\.1') { throw 'SYNTHETIC_CMS_BOUND_SUCCESS_INVALID' }
$disposed = try { $copy=$case.Credential.Copy(); $copy.Dispose(); $false } catch { $true }
if (-not $disposed) { throw 'SYNTHETIC_CMS_BOUND_CREDENTIAL_RETAINED' }
foreach($blocked in @(
    @{Stage='stale';Exports=0;Code='CMS_BOUND_SYNC_SELECTION_CHANGED'},
    @{Stage='alias';Exports=0;Code='CMS_BOUND_SYNC_SCOPE_UNSUPPORTED'},
    @{Stage='drift';Exports=1;Code='CMS_BOUND_SYNC_SELECTION_CHANGED'},
    @{Stage='native-drift';Exports=1;Code='CMS_BOUND_SYNC_SELECTION_CHANGED'},
    @{Stage='sql-fail';Exports=1;Code='CMS_BOUND_SYNC_SQL_UNCONFIRMED'}
)){
    $case.Stage=$blocked.Stage
    $case.SelectionReads=0; $case.RuntimeReads=0; $case.Exports=0; $case.Secrets=0; $case.Sql=0
    $errorCode=try{Invoke-LabCmsBoundSync -ExpectedRegistrationKey $expectedKey -StateRoot $stateRoot | Out-Null; 'NO_ERROR'}
        catch{$_.Exception.Message}
    $expectedEffects=[int]($blocked.Stage -ceq 'sql-fail')
    if($errorCode -cne $blocked.Code -or $case.Exports -ne $blocked.Exports -or $case.Secrets -ne $expectedEffects -or $case.Sql -ne $expectedEffects){
        throw ('SYNTHETIC_CMS_BOUND_CASE_INVALID: '+$blocked.Stage)
    }
}
'CMS BOUND SYNC CORE: 6 PASS'
