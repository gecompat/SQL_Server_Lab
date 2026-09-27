# Dot-sourced by the Windows external-runtime contract suite. No VM or SQL access.
. (Join-Path $repoRoot 'Tests/Common/CSharpNativeAcceptance.ps1')
$dispatch=[pscustomobject]@{EventName='workflow_dispatch';Ref='refs/heads/main';Repository='gecompat/SQL_Server_Lab';EventRepository='gecompat/SQL_Server_Lab';ExpectedCommit=('a'*40);CheckoutCommit=('a'*40);Dirty=$false;ArtifactId=('hyperv-os-sealed-'+('b'*64))}
$caught='';try{Assert-CSharpNativeDispatch $dispatch}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp native: manueller sauberer Main-Checkout akzeptiert' -Success (-not $caught)
foreach($case in @(
    @{Property='EventName';Value='pull_request'},@{Property='Ref';Value='refs/heads/feature'},
    @{Property='Repository';Value='synthetic/fork'},@{Property='EventRepository';Value='synthetic/fork'},
    @{Property='ExpectedCommit';Value='bad'},@{Property='CheckoutCommit';Value=('c'*40)},
    @{Property='Dirty';Value=$true},@{Property='ArtifactId';Value=('hyperv-sql-prepared-sealed-'+('b'*64))})){
    $copy=$dispatch.PSObject.Copy();$copy.($case.Property)=$case.Value
    $caught='';try{Assert-CSharpNativeDispatch $copy}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name ('CSharp native: Dispatch sperrt '+$case.Property) -Success ($caught -like 'CSHARP_NATIVE_*')
}
$nativeRoot=Join-Path $temporaryRoot 'native-tests';$null=New-Item -ItemType Directory -Path $nativeRoot
$syntheticFile=Join-Path $nativeRoot 'payload';[IO.File]::WriteAllText($syntheticFile,'synthetic')
$hash=(Get-FileHash $syntheticFile).Hash.ToLowerInvariant()
$caught='';try{Assert-CSharpNativeFile $syntheticFile $hash}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp native: gebundene Datei akzeptiert' -Success (-not $caught)
$caught='';try{Assert-CSharpNativeFile $syntheticFile ('0'*64)}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp native: Hashdrift vor Verwendung abgewiesen' -Success ($caught -ceq 'CSHARP_NATIVE_FILE_HASH')
$caught='';try{Assert-CSharpNativeFile $syntheticFile $hash -MaximumBytes 1}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp native: Größenlimit vor Verwendung' -Success ($caught -ceq 'CSHARP_NATIVE_FILE_SIZE')
$syntheticWorker=Join-Path $nativeRoot 'worker.ps1'
'param($PlanPath) Write-Output "synthetic stdout"; [Console]::Error.WriteLine("synthetic stderr"); exit 7'|Set-Content $syntheticWorker
$child=Invoke-CSharpNativeChild -Worker $syntheticWorker -PlanPath $syntheticFile -OutputRoot $nativeRoot -TimeoutSeconds 10
Add-CheckResult -Name 'CSharp native: echter Kindprozess bewahrt Exitcode und lokale Logs' -Success ($child.Terminated -and $child.ExitCode -eq 7 -and ([IO.File]::ReadAllText((Join-Path $nativeRoot 'worker.stderr.log'))) -match 'synthetic stderr')
'param($PlanPath) Start-Sleep -Seconds 30'|Set-Content $syntheticWorker
$caught='';$terminated=$false
try{Invoke-CSharpNativeChild -Worker $syntheticWorker -PlanPath $syntheticFile -OutputRoot $nativeRoot -TimeoutSeconds 1}catch{$caught=$_.Exception.Message;$terminated=$_.Exception.Data['CSharpChildTerminated']}
Add-CheckResult -Name 'CSharp native: echter Timeout bestätigt Kindprozessende vor Cleanup' -Success ($caught -ceq 'CSHARP_NATIVE_CHILD_TIMEOUT' -and $terminated)
$nativeModule=New-Module -ScriptBlock {
    $script:Removed=$false;$script:Foreign=$false
    $script:Owned=[pscustomobject]@{runId='11111111-1111-1111-1111-111111111111';scopeId='22222222-2222-2222-2222-222222222222';metadata=@{workflowOperationId='synthetic-operation';workflowKind='hyperv-lab'}}
    function Get-LabOperationOwnedRun {param($OperationId,$StateRoot) $script:Owned}
    function Get-LabProviderSubRuns {param($RunId,$StateRoot) [pscustomobject]@{provider='hyperv'}}
    function Get-CleanupPlan {param($RunDir) [pscustomobject]@{runId=$script:Owned.runId;scopeId=$script:Owned.scopeId;steps=@([pscustomobject]@{provider='hyperv';resourceType='vm';resourceId='synthetic-own-vm'})}}
    function Get-VM {param($Name) if($script:Foreign){[pscustomobject]@{Id='33333333-3333-3333-3333-333333333333'}}}
    function Get-HyperVManagedVM {param($VMName,$ExpectedRunId,$ExpectedScopeId) throw 'CSHARP_NATIVE_FOREIGN_VM'}
    function Remove-SqlServerLab {[CmdletBinding(SupportsShouldProcess)]param($RunId,$StateRoot,[switch]$Force) $script:Removed=$true;[pscustomobject]@{RunId=$RunId;Status='REMOVED';Cleanup='CLEANUP_SUCCEEDED'}}
}
$null=Invoke-CSharpNativeCleanup -Module $nativeModule -OperationId 'synthetic-operation' -StateRoot $nativeRoot
Add-CheckResult -Name 'CSharp native: partieller Arrange ohne Connection-Info scopegebunden bereinigt' -Success (& $nativeModule {$script:Removed})
& $nativeModule {$script:Removed=$false;$script:Foreign=$true}
$caught='';try{Invoke-CSharpNativeCleanup -Module $nativeModule -OperationId 'synthetic-operation' -StateRoot $nativeRoot}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp native: fremde VM sperrt Remove' -Success ($caught -ceq 'CSHARP_NATIVE_FOREIGN_VM' -and -not(& $nativeModule {$script:Removed}))
& $nativeModule {$script:Foreign=$false;$script:Owned.metadata.workflowOperationId='another-operation'}
$caught='';try{Invoke-CSharpNativeCleanup -Module $nativeModule -OperationId 'synthetic-operation' -StateRoot $nativeRoot}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp native: fremde Operation sperrt Remove' -Success ($caught -ceq 'CSHARP_NATIVE_OWNED_RUN_STATE_INVALID' -and -not(& $nativeModule {$script:Removed}))
& $nativeModule {
    $script:Owned.metadata.workflowOperationId='synthetic-operation';$script:Removed=$false
    Set-Item -LiteralPath Function:script:Get-CleanupPlan -Value {param($RunDir)[pscustomobject]@{runId=$script:Owned.runId;scopeId=$script:Owned.scopeId;steps=@()}}
    Set-Item -LiteralPath Function:script:Get-VM -Value {param($Name)throw 'An empty VM plan must not enumerate VMs'}
}
$null=Invoke-CSharpNativeCleanup -Module $nativeModule -OperationId 'synthetic-operation' -StateRoot $nativeRoot
Add-CheckResult -Name 'CSharp native: früher Arrange ohne VM-Schritt bleibt bereinigbar' -Success (& $nativeModule {$script:Removed})
& $nativeModule {
    Set-Item -LiteralPath Function:script:Remove-SqlServerLab -Value {param($RunId,$StateRoot,[switch]$Force,[switch]$Confirm)[pscustomobject]@{RunId=$RunId;Status='REMOVED';Cleanup='CLEANUP_FAILED'}}
}
$caught='';try{Invoke-CSharpNativeCleanup -Module $nativeModule -OperationId 'synthetic-operation' -StateRoot $nativeRoot}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp native: Cleanupfehler bleibt trotz REMOVED sichtbar' -Success ($caught -ceq 'CSHARP_NATIVE_OWNED_RUN_CLEANUP_FAILED')
Remove-Module $nativeModule -Force -ErrorAction SilentlyContinue
foreach($path in @('Tests/Common/CSharpNativeAcceptance.ps1','Tests/Integration/Invoke-CSharpHyperVAcceptance.ps1','Tests/Integration/Invoke-CSharpHyperVAcceptanceWorker.ps1','Tests/Integration/Fixtures/CSharp/guest.ps1')){
    $parseErrors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $path),[ref]$null,[ref]$parseErrors)
    Add-CheckResult -Name ('CSharp native: Parser '+$path) -Success (@($parseErrors).Count -eq 0)
}
$guestAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tests/Integration/Fixtures/CSharp/guest.ps1'),[ref]$null,[ref]$null)
$credentialFunction=$guestAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-CSharpNativeSqlCredential'},$true)
. ([scriptblock]::Create($credentialFunction.Extent.Text))
$mutable=[Security.SecureString]::new();$mutable.AppendChar('x')
$login=New-CSharpNativeSqlCredential $mutable
try{
    Add-CheckResult -Name 'CSharp native: SQL-Credential kopiert veränderliches Gastsecret read-only' -Success ($login.Secret.IsReadOnly() -and -not $mutable.IsReadOnly() -and $login.Credential.UserId -ceq 'sa')
}finally{$login.Secret.Dispose();$mutable.Dispose()}
& {
    $script:copyService=@([pscustomobject]@{Id='synthetic-6C09BB55-D683-4DA0-8931-C9BF705F6480';Enabled=$false})
    $script:copyEnabled=$false
    function Get-VMIntegrationService {param($VM)$script:copyService}
    function Enable-VMIntegrationService {param($VMIntegrationService)$script:copyEnabled=$true}
    Enable-CSharpNativeGuestCopy -VM ([pscustomobject]@{Id='synthetic'})
    Add-CheckResult -Name 'CSharp native: deaktivierten Dateikopierdienst einschalten' -Success $script:copyEnabled
    $script:copyService=@();$script:copyEnabled=$false
    $caught='';try{Enable-CSharpNativeGuestCopy -VM ([pscustomobject]@{Id='synthetic'})}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name 'CSharp native: fehlenden Dateikopierdienst nicht übergehen' -Success ($caught -ceq 'CSHARP_NATIVE_GUEST_COPY_SERVICE_MISSING' -and -not $script:copyEnabled)
}
& {
    $script:guestServiceTouched=$false
    function Get-FileHash {param($LiteralPath,$Algorithm)[pscustomobject]@{Hash=('0'*64)}}
    function Get-Service {param($Name)$script:guestServiceTouched=$true;throw 'Unexpected guest service access'}
    $caught=''
    try{& (Join-Path $repoRoot 'Tests/Integration/Fixtures/CSharp/guest.ps1') -Stage Configure -Root ('C:\SqlServerLab\CSharpAcceptance\'+('a'*32)) -PackageSha256 ('b'*64) -ProbeSha256 ('c'*64) -SqlSha256 ('d'*64)}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name 'CSharp native: Gastkopie-Hashdrift stoppt vor Dienst oder SQL' -Success ($caught -ceq 'CSHARP_NATIVE_GUEST_HASH' -and -not $script:guestServiceTouched)
}
$nativeWorkflow=Get-Content (Join-Path $repoRoot '.github/workflows/csharp-native-acceptance.yml') -Raw
Add-CheckResult -Name 'CSharp native: Workflow bindet Main-SHA, eigenen Runner und kein hartes Cancel' -Success (
    $nativeWorkflow.Contains("github.ref == 'refs/heads/main'") -and $nativeWorkflow.Contains('ref: ${{ github.sha }}') -and
    $nativeWorkflow.Contains('runs-on: [self-hosted, SQL_Lab, Hyper-V]') -and $nativeWorkflow.Contains('cancel-in-progress: false') -and
    $nativeWorkflow.Contains('timeout-minutes: 180') -and $nativeWorkflow.Contains('*> $localLog'))
$failureException=New-CSharpNativeFailureException -PrimaryFailure 'CSHARP_NATIVE_CHILD_TIMEOUT' -CleanupFailure 'CSHARP_NATIVE_CHILD_TERMINATION_UNCONFIRMED'
try{throw $failureException}catch{$diagnostic=Get-CSharpNativeFailureDiagnostic $_}
Add-CheckResult -Name 'CSharp native: Remote-Diagnose bewahrt Recovery getrennt vom Hauptfehler' -Success ($diagnostic.RecoveryRequired -and $diagnostic.ReasonCode -ceq 'CSHARP_NATIVE_RECOVERY_REQUIRED' -and $diagnostic.PrimaryFailure -ceq 'CSHARP_NATIVE_CHILD_TIMEOUT' -and $diagnostic.CleanupFailure -ceq 'CSHARP_NATIVE_CHILD_TERMINATION_UNCONFIRMED')
try{throw (New-CSharpNativeFailureException -PrimaryFailure 'synthetic private path' -CleanupFailure 'synthetic private detail')}catch{$diagnostic=Get-CSharpNativeFailureDiagnostic $_}
Add-CheckResult -Name 'CSharp native: Remote-Diagnose gibt keine privaten Fehlerdetails aus' -Success (($diagnostic|ConvertTo-Json -Compress) -notmatch 'synthetic private' -and $diagnostic.RecoveryRequired)
$attemptPath=Join-Path $nativeRoot 'native-attempt.json'
Add-CheckResult -Name 'CSharp native: Infrastrukturfehler ohne Sprachprobe bleibt NOT_EXECUTED' -Success ((Get-CSharpNativeSqlStatus -AttemptPath $attemptPath -OperationId 'synthetic' -Commit ('a'*40) -Passed $false) -ceq 'NOT_EXECUTED')
@{Status='SQL_PROBE_STARTED';OperationId='synthetic';Commit=('a'*40)}|ConvertTo-Json|Set-Content $attemptPath
Add-CheckResult -Name 'CSharp native: begonnene fehlgeschlagene Probe bleibt FAILED' -Success ((Get-CSharpNativeSqlStatus -AttemptPath $attemptPath -OperationId 'synthetic' -Commit ('a'*40) -Passed $false) -ceq 'FAILED')
Add-CheckResult -Name 'CSharp native: vollständiger eigener SQL-Nachweis PASSED' -Success ((Get-CSharpNativeSqlStatus -AttemptPath $attemptPath -OperationId 'synthetic' -Commit ('a'*40) -Passed $true) -ceq 'PASSED')
