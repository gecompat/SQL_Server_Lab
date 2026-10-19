#Requires -Version 7.2
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path)
$ErrorActionPreference='Stop'
$module=New-Module -Name ('PublicIdentityCharacterization_'+[guid]::NewGuid().ToString('N')) -ScriptBlock {
 param($PublicPath)
 . $PublicPath
} -ArgumentList (Join-Path $RepoRoot 'Public/Invoke-SqlServerLabWorkflowAction.ps1')
try{
 $result=& $module {
  $script:passed=0;$script:failed=0;$script:effects=0
  $id=[guid]'74187f38-5a9d-4982-aadf-2598e3d05162'
  $password=[securestring]::new();$password.AppendChar('x');$password.MakeReadOnly()
  function Check([bool]$Value,[string]$Label){if($Value){$script:passed++;Write-Host "PASS: $Label"}else{$script:failed++;Write-Host "FAIL: $Label"}}
  function Write-LabInfo {}
  function Write-LabSuccess {}
  function Test-HyperVAvailable {[pscustomobject]@{Available=$true;Message='synthetic'}}
  Set-Variable -Name IsWindows -Scope Script -Value $true -Force
  function Complete-HyperVLabSqlImage {
   param($RunId,$Credential,$SqlSaPassword,$StateRoot='synthetic-default',$MediaRoot,$ExpectedVmId)
   $script:effects++
   [pscustomobject]@{State=$StateRoot;StateBound=$PSBoundParameters.ContainsKey('StateRoot');Id=$ExpectedVmId;IdBound=$PSBoundParameters.ContainsKey('ExpectedVmId')}
  }
  function Enable-HyperVLabHostSqlAccess {
   param($RunId,$Credential,$SqlSaPassword,$SwitchName,$StateRoot='synthetic-default',$ExpectedVmId)
   $script:effects++
   [pscustomobject]@{State=$StateRoot;StateBound=$PSBoundParameters.ContainsKey('StateRoot');Id=$ExpectedVmId;IdBound=$PSBoundParameters.ContainsKey('ExpectedVmId')}
  }
  foreach($action in @('CompleteHyperVLabSql','EnableHyperVLabHostSqlAccess')){
   $script:effects=0
   $v=Invoke-SqlServerLabWorkflowAction -Action $action -BuildId '23f2608d-46db-43f8-8e40-8ed3da00a1db' -GuestPassword $password -StateRoot 'C:/synthetic/selected-state'
   Check ($v.Result.StateBound -and $v.Result.State -ceq 'C:/synthetic/selected-state' -and $script:effects -eq 1) "$action forwards explicit root unchanged"
   $script:effects=0;$blocked=$false
   try{$null=Invoke-SqlServerLabWorkflowAction -Action $action -BuildId '23f2608d-46db-43f8-8e40-8ed3da00a1db' -GuestPassword $password -StateRoot ' '}catch{$blocked=$_.Exception.Message -match 'STATE_ROOT_REQUIRED'}
   Check ($blocked -and $script:effects -eq 0) "$action rejects explicit empty root before core"
   $script:effects=0;$v=$null
   try{$v=Invoke-SqlServerLabWorkflowAction -Action $action -BuildId '23f2608d-46db-43f8-8e40-8ed3da00a1db' -GuestPassword $password -StateRoot 'C:/synthetic/selected-state' -ExpectedVmId $id}catch{}
   Check ($v -and $v.Result.IdBound -and $v.Result.Id -eq $id -and $v.Result.State -ceq 'C:/synthetic/selected-state' -and $script:effects -eq 1) "$action propagates selected immutable identity"
   $script:effects=0;$blocked=$false
   try{$null=Invoke-SqlServerLabWorkflowAction -Action $action -BuildId '23f2608d-46db-43f8-8e40-8ed3da00a1db' -GuestPassword $password -ExpectedVmId $id}catch{$blocked=$_.Exception.Message -match 'STATE_ROOT_REQUIRED'}
   Check ($blocked -and $script:effects -eq 0) "$action requires explicit root for selected identity"
   $script:effects=0;$blocked=$false
   try{$null=Invoke-SqlServerLabWorkflowAction -Action $action -BuildId '23f2608d-46db-43f8-8e40-8ed3da00a1db' -GuestPassword $password -StateRoot 'C:/synthetic/selected-state' -ExpectedVmId ([guid]::Empty)}catch{$blocked=$_.Exception.Message -match 'EXPECTED_VM_ID_REQUIRED'}
   Check ($blocked -and $script:effects -eq 0) "$action rejects empty selected VMId before core"
   $script:effects=0
   $v=Invoke-SqlServerLabWorkflowAction -Action $action -BuildId '23f2608d-46db-43f8-8e40-8ed3da00a1db' -GuestPassword $password
   Check (-not $v.Result.StateBound -and -not $v.Result.IdBound -and $script:effects -eq 1) "$action keeps omitted defaults"
  }
  [pscustomobject]@{Passed=$script:passed;Failed=$script:failed;NativeActions=0;GuestBodies=0;SyntheticCoreCallsOnly=$true}
 }
 Write-Host ('PUBLIC SQL ENTRY: '+$result.Passed+' PASS / '+$result.Failed+' FAIL')
 if($result.Failed){throw 'PUBLIC_SQL_ENTRY_FAILED'}
 $result
}finally{Remove-Module $module -Force}