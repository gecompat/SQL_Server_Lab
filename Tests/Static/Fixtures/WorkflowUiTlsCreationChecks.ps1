$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$script:passed=0
function Check([string]$name,[bool]$ok){if(-not $ok){throw ('TLS_CREATION_FOCUS_FAILED: '+$name)};$script:passed++}
. (Join-Path $repo 'Private/AuthenticatedTlsRequest.ps1')
. (Join-Path $repo 'Private/SecretProvider.ps1')
. (Join-Path $repo 'Private/SaPasswordPolicy.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsUiCreation.ps1')
. (Join-Path $repo 'Tools/WorkflowUiTlsCreation.ps1')
$p=@{RequestId='11111111111111111111111111111111';Provider='docker';Version='2025-CU9';Profile='compact';LabName='synthetic-lab';
 SaPassword='SYNTHETIC_ONLY!a9';TlsCandidateId='44444444-4444-4444-4444-444444444444';TlsControllerId='55555555-5555-5555-5555-555555555555';TlsLocationId='66666666-6666-6666-6666-666666666666'}
$body=$p|ConvertTo-Json -Compress
Check 'closed valid selection' ((Get-LabTlsUiCreationRequest $body).Provider -ceq 'docker')
foreach($version in @('2019-CU32','2022-CU27')){
 $selected=$p.Clone();$selected.Version=$version
 Check ('closed authenticated SQL profile '+$version) ((Get-LabTlsUiCreationRequest ($selected|ConvertTo-Json -Compress)).Version -ceq $version)
}
foreach($key in @('StateRoot','DataRoot','PersistentData','TrustServerCertificate','AutoStart')){
 $bad=$p.Clone();$bad[$key]='synthetic';$reject=$false;try{Get-LabTlsUiCreationRequest ($bad|ConvertTo-Json -Compress)|Out-Null}catch{$reject=$_.Exception.Message -ceq 'TLS_CREATION_REQUEST_REJECTED'}
 Check ('browser authority rejected '+$key) $reject
}
foreach($bad in @($body.Replace('"docker"','true'),$body.Replace('"docker"','["docker"]'),$body.Replace('"2025-CU9"','"2022-CU26"'),
 $body.Replace('"2025-CU9"','"2019"'),$body.Replace('"2025-CU9"','"2022-cu27"'),$body.Replace('"2025-CU9"','["2022-CU27"]'),
 $body.Replace('"docker"','"hyperv"'),$body.Replace('"SYNTHETIC_ONLY!a9"','"short"'),$body.Replace('"Provider":"docker"','"Provider":"docker","provider":"podman"'),'{"Provider":"docker"}',($body+'x'))){
 $reject=$false;try{Get-LabTlsUiCreationRequest $bad|Out-Null}catch{$reject=$_.Exception.Message -ceq 'TLS_CREATION_REQUEST_REJECTED'}
 Check 'invalid scalar/duplicate/profile/password yields fixed error' $reject
}
$id='22222222222222222222222222222222';$store=New-UiTlsCreationStore
$ticket=[hashtable]::Synchronized(@{Id=$id;SessionId=$store.SessionId;Job=[pscustomobject]@{State='Completed'};Status='COMPLETE';Provider='docker';Version='2025-CU9';
 LabName='synthetic-lab';RunId='33333333-3333-3333-3333-333333333333';RunState='RUNNING';Port=15000;StateRoot='C:/SYNTHETIC_PRIVATE_ROOT';
 SaPassword='SYNTHETIC_NEVER_PROJECT';ActionJob=$null;ActionStatus='NONE';LiveResult=$null})
$store.Tickets[$id]=$ticket
$view=Get-UiTlsCreationView $store $id
Check 'sanitized closed target DTO' (($view|ConvertTo-Json -Compress) -cnotmatch 'PRIVATE_ROOT|NEVER_PROJECT|StateRoot|SessionId' -and @($view.PSObject.Properties).Count -eq 12 -and $view.Encrypt -eq $true -and $view.TrustServerCertificate -eq $false)
foreach($version in @('2019-CU32','2022-CU27','2025-CU9')){
 $ticket.Version=$version
 Check ('DTO preserves selected ticket profile '+$version) ((Get-UiTlsCreationView $store $id).Version -ceq $version)
}
$ticket.Job=$null;$ticket.Status='UNCONFIRMED'
Check 'failed dispatch is unconfirmed' ((Get-UiTlsCreationView $store $id).Status -ceq 'UNCONFIRMED')
$ticket.SessionId='foreign';$reject=$false;try{Get-UiTlsCreationView $store $id|Out-Null}catch{$reject=$true};Check 'foreign session target rejected' $reject
foreach($bad in @('{"Ref":"22222222222222222222222222222222","Action":"Remove","RequestId":"11111111111111111111111111111111","StateRoot":"C:/foreign"}',
 '{"Ref":"22222222222222222222222222222222","Action":"Remove","RequestId":"11111111111111111111111111111111","action":"Live"}',
 '{"Ref":"22222222222222222222222222222222","Action":true,"RequestId":"11111111111111111111111111111111"}')){
 $reject=$false;try{Get-UiTlsTargetRequest $bad|Out-Null}catch{$reject=$true};Check 'closed target action input' $reject
}
# Actual canonical creator, synthetic provider/authority leaves. A rejected
# allocation hook must prevent the first owned policy/run effect.
. (Join-Path $repo 'Private/AuthenticatedTlsLab.ps1')
function Assert-LabTlsCaCandidateCapability {}
function Get-LabTlsSqlProfile {param($Version) [pscustomobject]@{Version=$Version;Image='synthetic:image'}}
function Assert-LabTlsSqlCatalogProfile {param($Profile)}
function New-LabTlsRuntimeBudget {param($Provider) [pscustomobject]@{Provider=$Provider}}
function Invoke-LabTlsContainer {param($Arguments,$InputText,$Budget) if($Arguments[0] -ceq 'image'){'sha256:'+('a'*64)}else{'synthetic-info'}}
function Register-LabTlsOperationalAuthority {param($DataRoot,$Controller,$Location,$Candidate) [pscustomobject]@{Authority=[pscustomobject]@{NotAfterUtc=[DateTimeOffset]::UtcNow.AddDays(3).ToString('o')};Native=[pscustomobject]@{UserSid='SYNTHETIC_SID'}}}
function Initialize-LabTlsCaPrivateDirectory {param($Path,$UserSid)}
function Get-LabTlsRuntimePin {param($Budget) [pscustomobject]@{Invocation='synthetic';Endpoint='synthetic';IdentityPath='';IdentitySha256=''}}
$script:policyEffects=0;$script:observed=$false
function Initialize-LabOwnedHostPolicy {param($StateRoot,$RuntimePins,$ParentOperationId) $script:policyEffects++;if(-not $script:observed){throw 'EFFECT_BEFORE_CUSTODY'};throw 'SYNTHETIC_POLICY_BOUNDARY'}
$script:syntheticRoot=Join-Path ([IO.Path]::GetTempPath()) ('synthetic-tls-no-io-'+[guid]::NewGuid().ToString('n'))
$parameters=@{TrustServerCertificate=$false;Provider='docker';Version='2025-CU9';DataRoot=$script:syntheticRoot;TlsCandidateId=$p.TlsCandidateId;TlsControllerId=$p.TlsControllerId;TlsLocationId=$p.TlsLocationId}
$failed=$false;try{New-LabAuthenticatedTlsEnvironment -Parameters $parameters -AllocationObserver {param($audit,$state) throw 'SYNTHETIC_CUSTODY_REJECTED'}|Out-Null}catch{$failed=$_.Exception.Message -ceq 'SYNTHETIC_CUSTODY_REJECTED'}
Check 'custody failure before any policy/run effect' ($failed -and $script:policyEffects -eq 0)
$failed=$false;try{New-LabAuthenticatedTlsEnvironment -Parameters $parameters -AllocationObserver {param($audit,$state) if($state -cne (Join-Path $script:syntheticRoot ('State/authenticated-tls-labs/'+$audit))){throw 'WRONG_ALLOCATION'};$script:observed=$true}|Out-Null}catch{$failed=$_.Exception.Message -ceq 'SYNTHETIC_POLICY_BOUNDARY'}
Check 'canonical allocation before policy boundary' ($failed -and $script:policyEffects -eq 1 -and $script:observed)
# Exercise the actual UI wrapper and its callback, not only the hook in the
# creator. Only native facts, file writes and the canonical provider leaf are
# injected; a rejected private receipt must prevent that leaf's effects.
function Assert-LabDiagnosticPath {param($Path) [IO.Path]::GetFullPath($Path)}
function Get-LabTlsWindowsProcessFacts {[pscustomobject]@{UserSid='SYNTHETIC_SID'}}
function ConvertTo-LabTlsRegistryWriterBytes {param($Value) ,[Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 8 -Compress))}
function Write-LabTlsCaPrivateFile {param($Path,$UserSid,$Bytes) if($script:rejectReceipt){throw 'SYNTHETIC_RECEIPT_REFUSED'};$script:allocationReceipt=[Text.Encoding]::UTF8.GetString($Bytes)|ConvertFrom-Json}
function New-LabAuthenticatedTlsEnvironment {param($Parameters,$AllocationObserver)
 $audit='99999999-9999-9999-9999-999999999999';$state=Join-Path $Parameters.DataRoot ('State/authenticated-tls-labs/'+$audit)
 & $AllocationObserver $audit $state
 $script:wrapperEffects++
 [pscustomobject]@{RunId='33333333-3333-3333-3333-333333333333';StateRoot=$state}
}
function Get-LabTlsOwnBinding {param($StateRoot,$RunId,$InstanceId) [pscustomobject]@{Record=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.2';AuditId=$script:wrapperTicket.AuditId;Provider='docker';Port=15000}}}
$script:rejectReceipt=$true;$script:wrapperEffects=0
$script:wrapperTicket=@{Id='22222222222222222222222222222222';SessionId='77777777777777777777777777777777';RequestId=$p.RequestId;StateRoot=$null}
Invoke-LabTlsUiCreation -Parameters ($p.Clone()) -Ticket $script:wrapperTicket -DataRoot $script:syntheticRoot
Check 'UI wrapper refuses effects if private allocation receipt fails' ($script:wrapperEffects -eq 0 -and $script:wrapperTicket.Status -ceq 'REJECTED' -and -not $script:wrapperTicket.StateRoot)
$script:rejectReceipt=$false;$script:wrapperTicket=@{Id='22222222222222222222222222222222';SessionId='77777777777777777777777777777777';RequestId=$p.RequestId;StateRoot=$null}
Invoke-LabTlsUiCreation -Parameters ($p.Clone()) -Ticket $script:wrapperTicket -DataRoot $script:syntheticRoot
Check 'actual UI callback binds exact canonical allocation before success' ($script:wrapperEffects -eq 1 -and $script:wrapperTicket.Status -ceq 'COMPLETE' -and $script:allocationReceipt.StateRoot -ceq $script:wrapperTicket.StateRoot -and $script:allocationReceipt.RequestId -ceq $p.RequestId)
$crossProfile=$p.Clone();$crossProfile.Version='2019-CU32'
$script:wrapperTicket=@{Id='22222222222222222222222222222222';SessionId='77777777777777777777777777777777';RequestId=$p.RequestId;StateRoot=$null}
Invoke-LabTlsUiCreation -Parameters $crossProfile -Ticket $script:wrapperTicket -DataRoot $script:syntheticRoot
Check 'different canonical SQL profile cannot complete the selected creation' ($script:wrapperTicket.Status -ceq 'UNCONFIRMED')
# Exercise the real target resolver and canonical profile decoder together.
# Only filesystem, process facts, runtime-pin read and policy leaves are synthetic.
$profileModule=New-Module -Name SyntheticTlsUiProfileBinding -ArgumentList $repo -ScriptBlock {
 param($repo)
 . (Join-Path $repo 'Private/AuthenticatedTlsLab.ps1')
 . (Join-Path $repo 'Private/AuthenticatedTlsUiCreation.ps1')
 function Assert-LabDiagnosticPath {param($Path) [IO.Path]::GetFullPath($Path)}
 function Assert-LabTlsLabRoot {param($Root)}
 function Get-LabTlsWindowsProcessFacts {[pscustomobject]@{UserSid='SYNTHETIC_SID'}}
 function Read-LabTlsCaPrivateFile {param($Path,$UserSid,$MaxBytes) ,[byte[]]@()}
 function Read-LabTlsLabRecord {param($Bytes) $script:targetRecord}
 function Get-LabTlsRecordedRuntimePin {param($Record,$Root)}
 function Get-LabOwnedHostRunPolicy {param($RunId,$StateRoot) $script:policyReads++;[pscustomobject]@{PolicyId='SYNTHETIC_POLICY'}}
}
$profileFacts=& $profileModule {
 $data=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'SYNTHETIC_NO_IO_TLS_PROFILE'))
 $audit='99999999-9999-9999-9999-999999999999';$run='33333333-3333-3333-3333-333333333333'
 $state=Join-Path $data ('State/authenticated-tls-labs/'+$audit)
 foreach($version in @('2019-CU32','2022-CU27','2025-CU9')){
  $fields=@{ContractVersion=if($version -ceq '2025-CU9'){'SqlServerLab.AuthenticatedTlsLab/0.2'}else{'SqlServerLab.AuthenticatedTlsLab/0.3'};
   AuditId=$audit;DataRoot=$data;RunId=$run;InstanceId='primary';Provider='docker';RuntimeBinding=[pscustomobject]@{PolicyId='SYNTHETIC_POLICY'}}
  if($version -cne '2025-CU9'){$fields.SqlProfileId=$version}
  $script:targetRecord=[pscustomobject]$fields
  $ticket=@{Status='COMPLETE';StateRoot=$state;RunId=$run;AuditId=$audit;Provider='docker';Version=$version}
  $script:policyReads=0;$target=Get-LabTlsUiCreationTarget $ticket
  [pscustomobject]@{Name='fresh canonical profile matches ticket '+$version;Passed=($target.RunId -ceq $run -and $script:policyReads -eq 1)}
  foreach($wrong in @('UNKNOWN_PROFILE',$(if($version -ceq '2025-CU9'){'2019-CU32'}else{'2025-CU9'}))){
   $ticket.Version=$wrong;$script:policyReads=0;$rejected=$false
   try{Get-LabTlsUiCreationTarget $ticket|Out-Null}catch{$rejected=$_.Exception.Message -ceq 'TLS_CREATION_TARGET_CHANGED'}
   [pscustomobject]@{Name='profile drift stops before target policy/action '+$version+'/'+$wrong;Passed=($rejected -and $script:policyReads -eq 0)}
  }
 }
}
foreach($fact in $profileFacts){Check $fact.Name $fact.Passed}
# Real ThreadJobs and exact request deduplication; only the SQL creation/action
# leaf is synthetic. No product runtime, CA, trust or original state is read.
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ui-tls-focus-'+[guid]::NewGuid().ToString('n'))
$moduleFile=Join-Path $testRoot 'SqlServerLab.psm1';$jobs=@{}
try {
 $null=[IO.Directory]::CreateDirectory($testRoot)
 $source=@'
. '__REPO__/Private/AuthenticatedTlsRequest.ps1'
. '__REPO__/Private/SecretProvider.ps1'
. '__REPO__/Private/SaPasswordPolicy.ps1'
. '__REPO__/Private/AuthenticatedTlsUiCreation.ps1'
function Get-LabDataRootDefault {'__ROOT__'}
function Get-LabTlsLiveQualificationUtcNow {[DateTimeOffset]::UtcNow}
function Invoke-LabTlsUiCreation {param($Parameters,$Ticket,$DataRoot)
 $Ticket.RunId='33333333-3333-3333-3333-333333333333';$Ticket.StateRoot=$DataRoot;$Ticket.Status='COMPLETE';$Ticket.RunState='RUNNING';$Ticket.Port=15000
}
function Invoke-LabTlsUiTargetAction {param($Ticket,$Action) if($Action -cne 'Remove'){throw 'SYNTHETIC_ACTION_NOT_SELECTED'};$Ticket.RunState='REMOVED'}
'@
 [IO.File]::WriteAllText($moduleFile,$source.Replace('__REPO__',$repo.Replace("'","''")).Replace('__ROOT__',$testRoot.Replace("'","''")),[Text.UTF8Encoding]::new($false))
 Import-Module $moduleFile -Force
 function Test-UiTlsLiveQualificationAvailable {$true}
 $store=New-UiTlsCreationStore
 $accepted=Start-UiTlsCreationWork -Store $store -Jobs $jobs -PersistentJobs @{} -ModulePath $moduleFile -Body $body
 $duplicate=Start-UiTlsCreationWork -Store $store -Jobs $jobs -PersistentJobs @{} -ModulePath $moduleFile -Body $body
 Check 'same request returns same reference and one worker' ($accepted.Ref -ceq $duplicate.Ref -and $jobs.Count -eq 1 -and $store.Tickets.Count -eq 1)
 $bad=$p.Clone();$bad.SaPassword='OTHER_SYNTHETIC!a9';$reject=$false
 try{Start-UiTlsCreationWork -Store $store -Jobs $jobs -PersistentJobs @{} -ModulePath $moduleFile -Body ($bad|ConvertTo-Json -Compress)|Out-Null}catch{$reject=$true}
 Check 'changed bytes cannot reuse request identity' ($reject -and $jobs.Count -eq 1)
 $job=@($jobs.Values)[0].Job
 Check 'real creation worker terminal' ([bool](Wait-Job $job -Timeout 15))
 $view=Get-UiTlsCreationView $store $accepted.Ref
 Check 'only scoped sanitized worker result reaches view' ($view.Status -ceq 'COMPLETE' -and $view.Port -eq 15000 -and ($view|ConvertTo-Json -Compress) -cnotmatch 'StateRoot|SYNTHETIC_ONLY')
 $actionBody=@{Ref=$accepted.Ref;Action='Remove';RequestId='77777777777777777777777777777777'}|ConvertTo-Json -Compress
 $null=Start-UiTlsCreationWork -Store $store -Jobs $jobs -PersistentJobs @{} -ModulePath $moduleFile -Body $actionBody -TargetAction
 $actionJob=$store.Tickets[$accepted.Ref].ActionJob
 Check 'real action worker terminal' ([bool](Wait-Job $actionJob -Timeout 15))
 Check 'target action stays in same custody record' ((Get-UiTlsCreationView $store $accepted.Ref).RunState -ceq 'REMOVED' -and $jobs.Count -eq 2)
 $store.Tickets[$accepted.Ref].Status='UNCONFIRMED'
 $next=$p.Clone();$next.RequestId='88888888888888888888888888888888';$reject=$false
 try{Start-UiTlsCreationWork -Store $store -Jobs $jobs -PersistentJobs @{} -ModulePath $moduleFile -Body ($next|ConvertTo-Json -Compress)|Out-Null}catch{$reject=$_.Exception.Message -ceq 'TLS_CREATION_PRIOR_OUTCOME_UNCONFIRMED'}
 Check 'new RequestId cannot bypass terminal unconfirmed creation' ($reject -and $jobs.Count -eq 2 -and $store.Tickets.Count -eq 1 -and (Test-UiTlsCreationBlocked $store))
 $filled=@{};1..256|ForEach-Object{$filled[[string]$_]=[pscustomobject]@{}}
 $reject=$false;try{Start-UiTlsCreationWork -Store $store -Jobs $jobs -PersistentJobs $filled -ModulePath $moduleFile -Body $body|Out-Null}catch{$reject=$true}
 Check 'combined job capacity refuses another worker' ($reject -and $jobs.Count -eq 2)
 $foreign=New-UiTlsCreationStore;$foreign.Tickets[$accepted.Ref]=$store.Tickets[$accepted.Ref]
 $reject=$false;try{Get-UiTlsCreationView $foreign $accepted.Ref|Out-Null}catch{$reject=$true}
 Check 'another server start cannot adopt existing reference' $reject
}finally{
 foreach($entry in $jobs.Values){if($entry.Job.State -cnotin @('Completed','Failed','Stopped')){Stop-Job $entry.Job};Remove-Job $entry.Job -Force}
 Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
 if([IO.File]::Exists($moduleFile)){[IO.File]::Delete($moduleFile)}
 if([IO.Directory]::Exists($testRoot)){[IO.Directory]::Delete($testRoot)}
}
. (Join-Path $repo 'Private/AuthenticatedTlsUiCreation.ps1')
function Get-LabTlsUiCreationTarget {param($Ticket) [pscustomobject]@{RunId='33333333-3333-3333-3333-333333333333';StateRoot='SYNTHETIC_ONLY'}}
function Start-SqlServerLab {param($RunId,$StateRoot) [pscustomobject]@{Status=$script:receiptStatus;Errors=$script:receiptErrors}}
function Stop-SqlServerLab {param($RunId,$StateRoot,[switch]$Force,[switch]$SkipHostMemoryRelease,[switch]$Confirm) [pscustomobject]@{Status=$script:receiptStatus;Errors=$script:receiptErrors}}
foreach($action in @('Start','Stop')){
 foreach($status in @('STOPPED_WITH_ERRORS','RECOVERY_REQUIRED',@('RUNNING','RUNNING'),$true)){
  $script:receiptStatus=$status;$script:receiptErrors=1;$t=@{RunState='BEFORE'};$reject=$false
  try{Invoke-LabTlsUiTargetAction -Ticket $t -Action $action|Out-Null}catch{$reject=$true}
  Check ('structured or non-scalar lifecycle failure not promoted '+$action) ($reject -and $t.RunState -ceq 'BEFORE')
 }
 $script:receiptStatus=if($action -ceq 'Start'){'RUNNING'}else{'STOPPED'};$script:receiptErrors=0;$t=@{RunState='BEFORE'}
 Invoke-LabTlsUiTargetAction -Ticket $t -Action $action|Out-Null
 Check ('actual canonical success receipt required '+$action) ($t.RunState -ceq $script:receiptStatus)
}
@{Status='PASS';Cases=$script:passed;ProviderActions=0;ActualCanonicalAllocation=$true}|ConvertTo-Json -Compress
