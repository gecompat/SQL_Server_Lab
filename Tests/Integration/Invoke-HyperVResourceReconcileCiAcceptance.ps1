#Requires -Version 7.2
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Fuehrt die manuelle, operationsgebundene CI-Akzeptanz fuer Hyper-V-Ressourcen-Reconcilee aus.
.DESCRIPTION
    Der CI-Einstieg akzeptiert eine explizite Slot-Quell-ID fuer eigene Clones;
    die Quelle ist niemals Cleanupziel. Die innere Acceptance laeuft in einem eigenen,
    nichtinteraktiven PowerShell-Kindprozess mit begrenzter Laufzeit. Der Parent
    verarbeitet ausschliesslich eine kleine, validierte Statusquittung und fuehrt
    erst nach bestaetigtem Kindprozess-Ende den operationsgebundenen Cleanup aus.
#>
[CmdletBinding()]
param(
    [string]$ArtifactId,
    [string]$CloneSourceRunId,
    [string]$MediaRoot='D:\Lab_Base',
    [ValidateSet('Enterprise','Standard','Eval')][string]$MediaEdition='Enterprise',
    [string]$StateRoot,
    [ValidateRange(60,7200)][int]$RunnerTimeoutSeconds=5400
)

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath=Join-Path $repoRoot 'SqlServerLab.psd1'
$acceptanceRunner=Join-Path $PSScriptRoot 'Invoke-HyperVResourceReconcileAcceptance.ps1'
$operationId=[string]$env:SQL_SERVER_LAB_TEST_OPERATION_ID
$module=$null;$primaryFailure=$null;$cleanupFailure=$null;$previousStateRoot=$env:SQL_SERVER_LAB_STATE
$mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_HyperV_Resource_Reconcile_CI_Acceptance');$mutexAcquired=$false
$childTerminationUnconfirmed=$false

function Assert-HyperVResourceReconcileCiAcceptance {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$ReasonCode)
    if(-not $Condition){throw $ReasonCode}
}
function Get-HyperVResourceReconcileCiRunnerReasonCode {
    param([Parameter(Mandatory)][object[]]$RunnerOutput)
    $stagePattern='(?<![A-Z0-9_])HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_(?:INITIALIZATION|DYNAMIC_MANIFEST|DYNAMIC_PROVISION|DYNAMIC_FORBIDDEN_DRIFT|DYNAMIC_FORBIDDEN_SQL_READINESS|DYNAMIC_FORBIDDEN_PLAN|DYNAMIC_FORBIDDEN_WHATIF|DYNAMIC_FORBIDDEN_APPLY|DYNAMIC_RESTART_SQL_READINESS|DYNAMIC_RESTART_SHUTDOWN_READINESS|DYNAMIC_LIVE_STOP|DYNAMIC_LIVE_CONFIGURE|DYNAMIC_LIVE_START|DYNAMIC_LIVE_VERIFY|DYNAMIC_LIVE_SQL_READINESS|DYNAMIC_LIVE_SHUTDOWN_READINESS|DYNAMIC_LIVE_PLAN|DYNAMIC_LIVE_WHATIF|DYNAMIC_LIVE_APPLY|DYNAMIC_LIVE_NOOP|STATIC_MANIFEST|STATIC_PROVISION|STATIC_DRIFT|STATIC_PLAN|STATIC_WHATIF|STATIC_APPLY|STATIC_SQL_READINESS|STATIC_NOOP|LEGACY_UNCLASSIFIED)_FAILED(?![A-Z0-9_])'
    $legacyPattern='(?<![A-Z0-9_])HYPERV_RESOURCE_ACCEPTANCE_[A-Z0-9]+(?:_[A-Z0-9]+)*(?![A-Z0-9_])'
    $stageCodes=foreach($entry in $RunnerOutput){
        $text=if($entry -is [Management.Automation.ErrorRecord]){[string]$entry.Exception.Message}else{[string]$entry}
        foreach($match in [regex]::Matches($text,$stagePattern)){$match.Value}
    }
    if(@($stageCodes).Count -gt 0){return @($stageCodes|Sort-Object -Unique|Select-Object -First 1)}
    foreach($entry in $RunnerOutput){
        $text=if($entry -is [Management.Automation.ErrorRecord]){[string]$entry.Exception.Message}else{[string]$entry}
        if([regex]::IsMatch($text,$legacyPattern)){return @('HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_LEGACY_UNCLASSIFIED_FAILED')}
    }
    return @()
}
function Get-HyperVResourceReconcileCiActivationReasonCode {
    param([Parameter(Mandatory)][object[]]$RunnerOutput)
    $activationPattern='(?<![A-Z0-9_])(?:WINDOWS_ACTIVATION_REQUIRED|WINDOWS_ACTIVATION_VERIFY_ONLY|WINDOWS_ACTIVATION_EGRESS_DENIED|WINDOWS_EVALUATION_EXPIRED|WINDOWS_ACTIVATION_(?:FAILED|REQUEST_FAILED|VERIFICATION_FAILED|LICENSE_DISCOVERY_FAILED|NETWORK_NOT_READY|NETWORK_CONFIGURATION_FAILED|PRODUCT_NOT_FOUND|EXISTING_EGRESS_UNAVAILABLE|GUEST_ADAPTER_NOT_FOUND|GUEST_OPERATION_FAILED|PERMANENT_BINDING_DRIFT)|HYPERV_WINDOWS_ACTIVATION_(?:FAILED|VERIFICATION_FAILED|OPERATION_FAILED|EXTERNAL_ADAPTER_NOT_CONNECTED|EXTERNAL_SWITCH_REQUIRED|GUEST_RECEIPT_INVALID|VM_MUST_BE_RUNNING)|HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_ACTIVATION_REASON_UNCLASSIFIED)(?![A-Z0-9_])'
    $codes=foreach($entry in $RunnerOutput){
        $text=if($entry -is [Management.Automation.ErrorRecord]){[string]$entry.Exception.Message}else{[string]$entry}
        foreach($match in [regex]::Matches($text,$activationPattern)){$match.Value}
    }
    if(@($codes).Count -gt 0){return @($codes|Sort-Object -Unique|Select-Object -First 1)}
    return @()
}
function Get-HyperVResourceReconcileCiProvisionReasonCode {
    param([Parameter(Mandatory)][object[]]$RunnerOutput)
    $provisionPattern='(?<![A-Z0-9_])(?:HYPERV_SQL_MEDIA_DIRECTORY_NOT_FOUND|HYPERV_RESOURCE_SLOT_SOURCE_(?:RUN_INVALID|STATE_SCOPE_INVALID|INSTANCE_INVALID|NOT_ELIGIBLE|VM_INVALID|DISK_INVALID|DISK_SCOPE_INVALID|ARTIFACT_INVALID|SECRET_MISSING))(?![A-Z0-9_])'
    $codes=foreach($entry in $RunnerOutput){
        $text=if($entry -is [Management.Automation.ErrorRecord]){[string]$entry.Exception.Message}else{[string]$entry}
        foreach($match in [regex]::Matches($text,$provisionPattern)){$match.Value}
    }
    if(@($codes).Count -gt 0){return @($codes|Sort-Object -Unique|Select-Object -First 1)}
    return @()
}
function New-HyperVResourceReconcileCiSupervisorRoot {
    [OutputType([string])]
    param([switch]$Synthetic)
    $root=Join-Path ([IO.Path]::GetTempPath()) ("sql-server-lab-hyperv-resource-ci-"+[guid]::NewGuid().ToString('N'))
    $created=New-Item -ItemType Directory -Path $root -ErrorAction Stop
    if($created.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'HYPERV_RESOURCE_RECONCILE_CI_SUPERVISOR_ROOT_INVALID'}
    if($Synthetic){return $root}
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User
    if(-not $identity){throw 'HYPERV_RESOURCE_RECONCILE_CI_SUPERVISOR_ROOT_INVALID'}
    $acl=Get-Acl -LiteralPath $root
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner($identity)
    $acl.SetAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    Set-Acl -LiteralPath $root -AclObject $acl
    return $root
}
function Test-HyperVResourceReconcileCiStageReceipt {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$ReceiptPath)
    if(-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)){return $null}
    $item=Get-Item -LiteralPath $ReceiptPath -Force
    if($item.Length -gt 1024 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){return $null}
    try{$receipt=Get-Content -LiteralPath $ReceiptPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 3}catch{return $null}
    $properties=@($receipt.PSObject.Properties.Name)
    if(@($properties|Where-Object{$_ -notin @('status','stage','reasonCode','activationReasonCode','provisionReasonCode')}).Count -ne 0 -or $properties.Count -ne 5){return $null}
    $status=[string]$receipt.status;$stage=[string]$receipt.stage;$reasonCode=[string]$receipt.reasonCode;$activationReasonCode=[string]$receipt.activationReasonCode;$provisionReasonCode=[string]$receipt.provisionReasonCode
    if($status -notin @('COMPLETED','FAILED') -or $stage -notin @('RUNNER_COMPLETED','RUNNER_FAILED')){return $null}
    if(($status -eq 'COMPLETED' -and ($stage -ne 'RUNNER_COMPLETED' -or -not [string]::IsNullOrEmpty($reasonCode) -or -not [string]::IsNullOrEmpty($activationReasonCode) -or -not [string]::IsNullOrEmpty($provisionReasonCode))) -or ($status -eq 'FAILED' -and $stage -ne 'RUNNER_FAILED')){return $null}
    if($status -eq 'COMPLETED'){return [pscustomobject]@{Status=$status;Stage=$stage;ReasonCode=$null;ActivationReasonCode=$null;ProvisionReasonCode=$null}}
    if($reasonCode -notmatch '^HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_(?:INITIALIZATION|DYNAMIC_MANIFEST|DYNAMIC_PROVISION|DYNAMIC_FORBIDDEN_DRIFT|DYNAMIC_FORBIDDEN_SQL_READINESS|DYNAMIC_FORBIDDEN_PLAN|DYNAMIC_FORBIDDEN_WHATIF|DYNAMIC_FORBIDDEN_APPLY|DYNAMIC_RESTART_SQL_READINESS|DYNAMIC_RESTART_SHUTDOWN_READINESS|DYNAMIC_LIVE_STOP|DYNAMIC_LIVE_CONFIGURE|DYNAMIC_LIVE_START|DYNAMIC_LIVE_VERIFY|DYNAMIC_LIVE_SQL_READINESS|DYNAMIC_LIVE_SHUTDOWN_READINESS|DYNAMIC_LIVE_PLAN|DYNAMIC_LIVE_WHATIF|DYNAMIC_LIVE_APPLY|DYNAMIC_LIVE_NOOP|STATIC_MANIFEST|STATIC_PROVISION|STATIC_DRIFT|STATIC_PLAN|STATIC_WHATIF|STATIC_APPLY|STATIC_SQL_READINESS|STATIC_NOOP|LEGACY_UNCLASSIFIED)_FAILED$'){return $null}
    $isProvisioningFailure=$reasonCode -match '^HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_(?:DYNAMIC|STATIC)_PROVISION_FAILED$'
    if($isProvisioningFailure -and -not [string]::IsNullOrEmpty($activationReasonCode) -and $activationReasonCode -notmatch '^(?:WINDOWS_ACTIVATION_REQUIRED|WINDOWS_ACTIVATION_VERIFY_ONLY|WINDOWS_ACTIVATION_EGRESS_DENIED|WINDOWS_EVALUATION_EXPIRED|WINDOWS_ACTIVATION_(?:FAILED|REQUEST_FAILED|VERIFICATION_FAILED|LICENSE_DISCOVERY_FAILED|PRODUCT_NOT_FOUND|EXISTING_EGRESS_UNAVAILABLE|GUEST_ADAPTER_NOT_FOUND|GUEST_OPERATION_FAILED|PERMANENT_BINDING_DRIFT)|HYPERV_WINDOWS_ACTIVATION_(?:FAILED|VERIFICATION_FAILED|OPERATION_FAILED|EXTERNAL_ADAPTER_NOT_CONNECTED|EXTERNAL_SWITCH_REQUIRED|GUEST_RECEIPT_INVALID|VM_MUST_BE_RUNNING)|HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_ACTIVATION_REASON_UNCLASSIFIED)$'){return $null}
    if($isProvisioningFailure -and -not [string]::IsNullOrEmpty($provisionReasonCode) -and $provisionReasonCode -notmatch '^(?:HYPERV_SQL_MEDIA_DIRECTORY_NOT_FOUND|HYPERV_RESOURCE_SLOT_SOURCE_(?:RUN_INVALID|STATE_SCOPE_INVALID|INSTANCE_INVALID|NOT_ELIGIBLE|VM_INVALID|DISK_INVALID|DISK_SCOPE_INVALID|ARTIFACT_INVALID|SECRET_MISSING))$'){return $null}
    if(-not $isProvisioningFailure -and (-not [string]::IsNullOrEmpty($activationReasonCode) -or -not [string]::IsNullOrEmpty($provisionReasonCode))){return $null}
    return [pscustomobject]@{Status=$status;Stage=$stage;ReasonCode=$reasonCode;ActivationReasonCode=if($isProvisioningFailure -and -not [string]::IsNullOrEmpty($activationReasonCode)){$activationReasonCode}else{$null};ProvisionReasonCode=if($isProvisioningFailure -and -not [string]::IsNullOrEmpty($provisionReasonCode)){$provisionReasonCode}else{$null}}
}
function Stop-HyperVResourceReconcileCiChildProcessTree {
    [OutputType([bool])]
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)
    try{if($Process.HasExited){return $true}}catch{return $false}
    if(-not $IsWindows){
        try{$Process.Kill($true);if(-not $Process.WaitForExit(15000)){return $false};$Process.Refresh();return $Process.HasExited}catch{return $false}
    }
    $taskKillPath=Join-Path $env:SystemRoot 'System32\taskkill.exe'
    if(-not (Test-Path -LiteralPath $taskKillPath -PathType Leaf)){return $false}
    try {
        $startInfo=[Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName=$taskKillPath;$startInfo.UseShellExecute=$false;$startInfo.CreateNoWindow=$true
        foreach($argument in @('/PID',[string]$Process.Id,'/T','/F')){[void]$startInfo.ArgumentList.Add($argument)}
        $terminator=[Diagnostics.Process]::Start($startInfo)
        if(-not $terminator.WaitForExit(15000)){try{$terminator.Kill($true)}catch{};return $false}
        if(-not $Process.WaitForExit(15000)){return $false}
        $Process.Refresh()
        return $Process.HasExited
    } catch { return $false }
}
function Invoke-HyperVResourceReconcileCiSupervisor {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$AcceptanceRunner,
        [string]$ArtifactId,
        [string]$CloneSourceRunId,
        [string]$MediaRoot='D:\Lab_Base',
        [string]$MediaEdition='Enterprise',
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$Run1OperationId,
        [Parameter(Mandatory)][string]$Run2OperationId,
        [ValidateRange(1,7200)][int]$TimeoutSeconds=5400,
        [string]$PowerShellPath=([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName),
        [switch]$Synthetic
    )
    $root=$null;$child=$null;$terminationConfirmed=$true;$timedOut=$false
    try {
        if(-not (Test-Path -LiteralPath $AcceptanceRunner -PathType Leaf) -or -not (Test-Path -LiteralPath $PowerShellPath -PathType Leaf)){throw 'HYPERV_RESOURCE_RECONCILE_CI_SUPERVISOR_INPUT_INVALID'}
        $root=New-HyperVResourceReconcileCiSupervisorRoot -Synthetic:$Synthetic
        $childScript=Join-Path $root 'runner.ps1';$receiptPath=Join-Path $root 'stage-receipt.json'
        $childContent=@'
[CmdletBinding()]
param([string]$AcceptanceRunner,[string]$ArtifactId,[string]$CloneSourceRunId,[string]$MediaRoot,[string]$MediaEdition,[string]$StateRoot,[string]$Run1OperationId,[string]$Run2OperationId,[string]$ReceiptPath)
$ErrorActionPreference='Stop'
function Get-ReasonCode {
    param([object[]]$RunnerOutput)
    $stagePattern='(?<![A-Z0-9_])HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_(?:INITIALIZATION|DYNAMIC_MANIFEST|DYNAMIC_PROVISION|DYNAMIC_FORBIDDEN_DRIFT|DYNAMIC_FORBIDDEN_SQL_READINESS|DYNAMIC_FORBIDDEN_PLAN|DYNAMIC_FORBIDDEN_WHATIF|DYNAMIC_FORBIDDEN_APPLY|DYNAMIC_RESTART_SQL_READINESS|DYNAMIC_RESTART_SHUTDOWN_READINESS|DYNAMIC_LIVE_STOP|DYNAMIC_LIVE_CONFIGURE|DYNAMIC_LIVE_START|DYNAMIC_LIVE_VERIFY|DYNAMIC_LIVE_SQL_READINESS|DYNAMIC_LIVE_SHUTDOWN_READINESS|DYNAMIC_LIVE_PLAN|DYNAMIC_LIVE_WHATIF|DYNAMIC_LIVE_APPLY|DYNAMIC_LIVE_NOOP|STATIC_MANIFEST|STATIC_PROVISION|STATIC_DRIFT|STATIC_PLAN|STATIC_WHATIF|STATIC_APPLY|STATIC_SQL_READINESS|STATIC_NOOP|LEGACY_UNCLASSIFIED)_FAILED(?![A-Z0-9_])'
    $legacyPattern='(?<![A-Z0-9_])HYPERV_RESOURCE_ACCEPTANCE_[A-Z0-9]+(?:_[A-Z0-9]+)*(?![A-Z0-9_])'
    $stageCodes=foreach($entry in $RunnerOutput){$text=if($entry -is [Management.Automation.ErrorRecord]){[string]$entry.Exception.Message}else{[string]$entry};foreach($match in [regex]::Matches($text,$stagePattern)){$match.Value}}
    if(@($stageCodes).Count -gt 0){return @($stageCodes|Sort-Object -Unique|Select-Object -First 1)}
    foreach($entry in $RunnerOutput){$text=if($entry -is [Management.Automation.ErrorRecord]){[string]$entry.Exception.Message}else{[string]$entry};if([regex]::IsMatch($text,$legacyPattern)){return @('HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_LEGACY_UNCLASSIFIED_FAILED')}}
    return @()
}
function Get-ActivationReasonCode {
    param([object[]]$RunnerOutput)
    $activationPattern='(?<![A-Z0-9_])(?:WINDOWS_ACTIVATION_REQUIRED|WINDOWS_ACTIVATION_VERIFY_ONLY|WINDOWS_ACTIVATION_EGRESS_DENIED|WINDOWS_EVALUATION_EXPIRED|WINDOWS_ACTIVATION_(?:FAILED|REQUEST_FAILED|VERIFICATION_FAILED|LICENSE_DISCOVERY_FAILED|NETWORK_NOT_READY|NETWORK_CONFIGURATION_FAILED|PRODUCT_NOT_FOUND|EXISTING_EGRESS_UNAVAILABLE|GUEST_ADAPTER_NOT_FOUND|GUEST_OPERATION_FAILED|PERMANENT_BINDING_DRIFT)|HYPERV_WINDOWS_ACTIVATION_(?:FAILED|VERIFICATION_FAILED|OPERATION_FAILED|EXTERNAL_ADAPTER_NOT_CONNECTED|EXTERNAL_SWITCH_REQUIRED|GUEST_RECEIPT_INVALID|VM_MUST_BE_RUNNING)|HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_ACTIVATION_REASON_UNCLASSIFIED)(?![A-Z0-9_])'
    $codes=foreach($entry in $RunnerOutput){$text=if($entry -is [Management.Automation.ErrorRecord]){[string]$entry.Exception.Message}else{[string]$entry};foreach($match in [regex]::Matches($text,$activationPattern)){$match.Value}}
    if(@($codes).Count -gt 0){return @($codes|Sort-Object -Unique|Select-Object -First 1)}
    return @()
}
function Get-ProvisionReasonCode {
    param([object[]]$RunnerOutput)
    $provisionPattern='(?<![A-Z0-9_])(?:HYPERV_SQL_MEDIA_DIRECTORY_NOT_FOUND|HYPERV_RESOURCE_SLOT_SOURCE_(?:RUN_INVALID|STATE_SCOPE_INVALID|INSTANCE_INVALID|NOT_ELIGIBLE|VM_INVALID|DISK_INVALID|DISK_SCOPE_INVALID|ARTIFACT_INVALID|SECRET_MISSING))(?![A-Z0-9_])'
    $codes=foreach($entry in $RunnerOutput){$text=if($entry -is [Management.Automation.ErrorRecord]){[string]$entry.Exception.Message}else{[string]$entry};foreach($match in [regex]::Matches($text,$provisionPattern)){$match.Value}}
    if(@($codes).Count -gt 0){return @($codes|Sort-Object -Unique|Select-Object -First 1)}
    return @()
}
$receipt=[ordered]@{status='FAILED';stage='RUNNER_FAILED';reasonCode=$null;activationReasonCode=$null;provisionReasonCode=$null};$exitCode=1
try {$runnerOutput=@(& $AcceptanceRunner -ArtifactId $ArtifactId -CloneSourceRunId $CloneSourceRunId -MediaRoot $MediaRoot -MediaEdition $MediaEdition -StateRoot $StateRoot -Run1OperationId $Run1OperationId -Run2OperationId $Run2OperationId -DeferCleanup *>&1);if($LASTEXITCODE -ne 0 -or @($runnerOutput|Where-Object{$_ -is [Management.Automation.ErrorRecord]}).Count -gt 0){$receipt.reasonCode=Get-ReasonCode -RunnerOutput $runnerOutput;if([string]$receipt.reasonCode -match '^HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_(?:DYNAMIC|STATIC)_PROVISION_FAILED$'){$receipt.activationReasonCode=Get-ActivationReasonCode -RunnerOutput $runnerOutput;$receipt.provisionReasonCode=Get-ProvisionReasonCode -RunnerOutput $runnerOutput}}else{$receipt.status='COMPLETED';$receipt.stage='RUNNER_COMPLETED';$exitCode=0}}catch{$receipt.reasonCode=Get-ReasonCode -RunnerOutput @($_);if([string]$receipt.reasonCode -match '^HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_(?:DYNAMIC|STATIC)_PROVISION_FAILED$'){$receipt.activationReasonCode=Get-ActivationReasonCode -RunnerOutput @($_);$receipt.provisionReasonCode=Get-ProvisionReasonCode -RunnerOutput @($_)}}finally{[IO.File]::WriteAllText($ReceiptPath,($receipt|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))}
exit $exitCode
'@
        [IO.File]::WriteAllText($childScript,$childContent,[Text.UTF8Encoding]::new($false))
        $startInfo=[Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName=$PowerShellPath;$startInfo.UseShellExecute=$false;$startInfo.CreateNoWindow=$true
        foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$childScript,'-AcceptanceRunner',$AcceptanceRunner,'-ArtifactId',[string]$ArtifactId,'-CloneSourceRunId',[string]$CloneSourceRunId,'-MediaRoot',$MediaRoot,'-MediaEdition',$MediaEdition,'-StateRoot',$StateRoot,'-Run1OperationId',$Run1OperationId,'-Run2OperationId',$Run2OperationId,'-ReceiptPath',$receiptPath)){[void]$startInfo.ArgumentList.Add($argument)}
        $child=[Diagnostics.Process]::Start($startInfo)
        $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while(-not $child.WaitForExit(250)){
            if([DateTime]::UtcNow -ge $deadline){$timedOut=$true;$terminationConfirmed=Stop-HyperVResourceReconcileCiChildProcessTree -Process $child;break}
        }
        if(-not $terminationConfirmed){return [pscustomobject]@{Status='RECOVERY_REQUIRED';Stage='RUNNER_TIMEOUT';ReasonCode='HYPERV_RESOURCE_RECONCILE_CI_RUNNER_TERMINATION_UNCONFIRMED';ActivationReasonCode=$null;ProvisionReasonCode=$null;TimedOut=$true;TerminationConfirmed=$false}}
        if($timedOut){return [pscustomobject]@{Status='FAILED';Stage='RUNNER_TIMEOUT';ReasonCode='HYPERV_RESOURCE_RECONCILE_CI_RUNNER_TIMEOUT';ActivationReasonCode=$null;ProvisionReasonCode=$null;TimedOut=$true;TerminationConfirmed=$true}}
        $receipt=Test-HyperVResourceReconcileCiStageReceipt -ReceiptPath $receiptPath
        if(-not $receipt){return [pscustomobject]@{Status='FAILED';Stage='RUNNER_RECEIPT';ReasonCode='HYPERV_RESOURCE_RECONCILE_CI_RUNNER_RECEIPT_INVALID';ActivationReasonCode=$null;ProvisionReasonCode=$null;TimedOut=$false;TerminationConfirmed=$true}}
        if($child.ExitCode -eq 0 -and $receipt.Status -eq 'COMPLETED'){return [pscustomobject]@{Status='COMPLETED';Stage=$receipt.Stage;ReasonCode=$null;ActivationReasonCode=$null;ProvisionReasonCode=$null;TimedOut=$false;TerminationConfirmed=$true}}
        return [pscustomobject]@{Status='FAILED';Stage=$receipt.Stage;ReasonCode=$receipt.ReasonCode;ActivationReasonCode=$receipt.ActivationReasonCode;ProvisionReasonCode=$receipt.ProvisionReasonCode;TimedOut=$false;TerminationConfirmed=$true}
    } finally {
        if($child){$child.Dispose()}
        if($root -and $terminationConfirmed -and (Test-Path -LiteralPath $root)){Remove-Item -LiteralPath $root -Recurse -Force}
    }
}
function Get-HyperVResourceReconcileCiOwnedRun {
    param([Parameter(Mandatory)]$Module,[Parameter(Mandatory)][string]$OperationId,[Parameter(Mandatory)][string]$StateRoot)
    & $Module {
        param($ExpectedOperationId,$Root)
        $owned=Get-LabOperationOwnedRun -OperationId $ExpectedOperationId -StateRoot $Root
        if(-not $owned){return $null}
        if([string]$owned.runId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
           [string]$owned.scopeId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
           [string]$owned.metadata.workflowOperationId -cne $ExpectedOperationId -or
           (-not [string]::IsNullOrWhiteSpace([string]$owned.metadata.workflowKind) -and [string]$owned.metadata.workflowKind -cne 'hyperv-lab')){throw 'HYPERV_RESOURCE_RECONCILE_CI_OWNED_RUN_STATE_INVALID'}
        $subRuns=@(Get-LabProviderSubRuns -RunId ([string]$owned.runId) -StateRoot $Root)
        if($subRuns.Count -ne 1 -or [string]$subRuns[0].provider -cne 'hyperv'){throw 'HYPERV_RESOURCE_RECONCILE_CI_OWNED_RUN_PROVIDER_INVALID'}
        $runDirectory=Join-Path (Join-Path $Root 'runs') ([string]$owned.runId)
        $plan=Get-CleanupPlan -RunDir $runDirectory
        $vmSteps=@($plan.steps|Where-Object{[string]$_.resourceType -eq 'vm'})
        if([string]$plan.runId -cne [string]$owned.runId -or [string]$plan.scopeId -cne [string]$owned.scopeId -or
           @($plan.steps|Where-Object{[string]$_.provider -ne 'hyperv' -or [string]$_.resourceType -notin @('vm','vhdx','ipam-lease')}).Count -gt 0 -or $vmSteps.Count -gt 1){throw 'HYPERV_RESOURCE_RECONCILE_CI_OWNED_RUN_CLEANUP_PLAN_INVALID'}
        if($vmSteps.Count -eq 0){
            if([string]$owned.metadata.purpose -cne 'resource-reconcile-native-evidence' -or
               [string]$owned.state -notin @('PROVISIONING','CLEANUP_PENDING') -or
               (Test-Path -LiteralPath (Join-Path $runDirectory 'connection-info.json'))){throw 'HYPERV_RESOURCE_RECONCILE_CI_EARLY_CLEANUP_INVALID'}
            foreach($step in @($plan.steps|Where-Object resourceType -eq 'vhdx')){
                if(-not (Test-HyperVPathWithinRunDirectory -Path ([string]$step.resourceId) -RunDirectory $runDirectory)){throw 'HYPERV_RESOURCE_RECONCILE_CI_EARLY_CLEANUP_SCOPE_INVALID'}
            }
            return [pscustomobject]@{RunId=[string]$owned.runId;ScopeId=[string]$owned.scopeId;VmName=$null;VhdxPaths=@($plan.steps|Where-Object resourceType -eq 'vhdx'|ForEach-Object resourceId)}
        }
        if([string]::IsNullOrWhiteSpace([string]$vmSteps[0].resourceId)){throw 'HYPERV_RESOURCE_RECONCILE_CI_OWNED_RUN_CLEANUP_PLAN_INVALID'}
        $plannedVmName=[string]$vmSteps[0].resourceId
        $connectionPath=Join-Path $runDirectory 'connection-info.json'
        if(Test-Path -LiteralPath $connectionPath -PathType Leaf){
            $context=Get-HyperVLabWorkflowRun -RunId ([string]$owned.runId) -StateRoot $Root
            if([string]$context.Run.scopeId -cne [string]$owned.scopeId -or [string]$context.Instance.provider -cne 'hyperv' -or [string]::IsNullOrWhiteSpace([string]$context.Instance.vmName) -or [string]::IsNullOrWhiteSpace([string]$context.Instance.vmId)){throw 'HYPERV_RESOURCE_RECONCILE_CI_OWNED_RUN_CONNECTION_INVALID'}
            $contextVmId=[guid]::Empty
            if([string]$context.Instance.vmName -cne $plannedVmName -or -not [guid]::TryParse([string]$context.Instance.vmId,[ref]$contextVmId)){throw 'HYPERV_RESOURCE_RECONCILE_CI_OWNED_VM_OWNERSHIP_INVALID'}
            $managed=Get-HyperVManagedVM -VMName $plannedVmName -ExpectedRunId ([string]$owned.runId) -ExpectedScopeId ([string]$owned.scopeId)
            if(-not $managed -or [string]$managed.VM.Id -cne $contextVmId.ToString()){throw 'HYPERV_RESOURCE_RECONCILE_CI_OWNED_VM_OWNERSHIP_INVALID'}
        } else {
            $existingVm=@(Get-VM -Name $plannedVmName -ErrorAction SilentlyContinue)
            if($existingVm.Count -ne 0 -and -not (Get-HyperVManagedVM -VMName $plannedVmName -ExpectedRunId ([string]$owned.runId) -ExpectedScopeId ([string]$owned.scopeId))){throw 'HYPERV_RESOURCE_RECONCILE_CI_OWNED_VM_OWNERSHIP_INVALID'}
        }
        [pscustomobject]@{RunId=[string]$owned.runId;ScopeId=[string]$owned.scopeId;VmName=$plannedVmName;VhdxPaths=@($plan.steps|Where-Object{[string]$_.resourceType -eq 'vhdx'}|ForEach-Object{[string]$_.resourceId}|Where-Object{$_})}
    } $OperationId $StateRoot
}
function Invoke-HyperVResourceReconcileCiCleanup {
    param([Parameter(Mandatory)]$Module,[Parameter(Mandatory)][string]$OperationId,[Parameter(Mandatory)][string]$StateRoot)
    $owned=Get-HyperVResourceReconcileCiOwnedRun -Module $Module -OperationId $OperationId -StateRoot $StateRoot
    if(-not $owned){return $null}
    $result=& $Module {param($RunId,$Root)Remove-SqlServerLab -RunId $RunId -StateRoot $Root -Force -Confirm:$false} $owned.RunId $StateRoot
    if([string]$result.RunId -cne $owned.RunId -or [string]$result.Status -notin @('REMOVED','COMPLETED','ALREADY_REMOVED')){throw 'HYPERV_RESOURCE_RECONCILE_CI_OWNED_RUN_CLEANUP_FAILED'}
    & $Module {param($CleanupOwned)if($CleanupOwned.VmName -and @(Get-VM -Name $CleanupOwned.VmName -ErrorAction SilentlyContinue).Count -ne 0){throw 'HYPERV_RESOURCE_RECONCILE_CI_CLEANUP_VM_POSTCONDITION_FAILED'};foreach($path in @($CleanupOwned.VhdxPaths|Sort-Object -Unique)){if(Test-Path -LiteralPath $path){throw 'HYPERV_RESOURCE_RECONCILE_CI_CLEANUP_VHDX_POSTCONDITION_FAILED'}}} $owned
    return $result
}

try {
    Assert-HyperVResourceReconcileCiAcceptance ($operationId -match '^github-[0-9]+-[0-9]+$') 'HYPERV_RESOURCE_RECONCILE_CI_OPERATION_CONTEXT_INVALID'
    $run1OperationId="$operationId-resource-r1";$run2OperationId="$operationId-resource-r2"
    try{$mutexAcquired=$mutex.WaitOne([TimeSpan]::FromMinutes(15))}catch [Threading.AbandonedMutexException]{$mutexAcquired=$true;Write-Host 'HYPERV_RESOURCE_RECONCILE_CI_HOST_LOCK_ABANDONED_RECOVERED' -ForegroundColor Yellow}
    Assert-HyperVResourceReconcileCiAcceptance $mutexAcquired 'HYPERV_RESOURCE_RECONCILE_CI_HOST_LOCK_TIMEOUT'
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent());Assert-HyperVResourceReconcileCiAcceptance $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) 'HYPERV_RESOURCE_RECONCILE_CI_RUNNER_NOT_ELEVATED'
    Get-Command Get-VM -ErrorAction Stop|Out-Null
    $module=Import-Module $modulePath -Force -PassThru
    if(-not $StateRoot){$StateRoot=& $module {Get-LabStateRoot}};$env:SQL_SERVER_LAB_STATE=$StateRoot
    if($CloneSourceRunId -and $ArtifactId){throw 'HYPERV_RESOURCE_RECONCILE_CI_SOURCE_AMBIGUOUS'}
    if($CloneSourceRunId){
        $sourceId=[guid]::Empty
        if(-not [guid]::TryParse($CloneSourceRunId,[ref]$sourceId)){throw 'HYPERV_RESOURCE_RECONCILE_CI_SOURCE_INVALID'}
        if([IO.Path]::GetFullPath($MediaRoot).TrimEnd('\') -ine 'D:\Lab_Base'){throw 'HYPERV_RESOURCE_RECONCILE_CI_MEDIA_ROOT_INVALID'}
    } else {
    if($ArtifactId){$artifact=& $module {param($Id,$Root)Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root} $ArtifactId $StateRoot}
    else {$artifact=& $module {param($Root)@(Get-HyperVImageArtifact -StateRoot $Root|Where-Object{[string]$_.artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$_.sql.version -eq '2025' -and [string]$_.licenseType -ne 'test-only'}|Sort-Object{[datetime]$_.registeredAt} -Descending|Select-Object -First 1)[0]} $StateRoot}
    Assert-HyperVResourceReconcileCiAcceptance ([bool]$artifact) 'HYPERV_RESOURCE_RECONCILE_CI_SQL_PREPARED_ARTIFACT_INVALID'
    $eligibility=& $module {param($Candidate)[pscustomobject]@{Evaluation=Test-HyperVImageArtifactEvaluationEligibility -Artifact $Candidate;Child=Test-HyperVImageArtifactChildValidationEligibility -Artifact $Candidate}} $artifact
    Assert-HyperVResourceReconcileCiAcceptance ([string]$artifact.artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$artifact.sql.version -eq '2025' -and [string]$artifact.integrityVerification.status -in @('VERIFIED_CACHE','VERIFIED_HASH') -and [bool]$eligibility.Evaluation.Eligible -and [bool]$eligibility.Child.Eligible) 'HYPERV_RESOURCE_RECONCILE_CI_SQL_PREPARED_ARTIFACT_INVALID'
    $ArtifactId=[string]$artifact.artifactId
    }
    $supervision=Invoke-HyperVResourceReconcileCiSupervisor -AcceptanceRunner $acceptanceRunner -ArtifactId $ArtifactId -CloneSourceRunId $CloneSourceRunId -MediaRoot $MediaRoot -MediaEdition $MediaEdition -StateRoot $StateRoot -Run1OperationId $run1OperationId -Run2OperationId $run2OperationId -TimeoutSeconds $RunnerTimeoutSeconds
    if(-not $supervision.TerminationConfirmed){$childTerminationUnconfirmed=$true;throw 'HYPERV_RESOURCE_RECONCILE_CI_RUNNER_TERMINATION_UNCONFIRMED_RECOVERY_REQUIRED'}
    if($supervision.TimedOut){throw 'HYPERV_RESOURCE_RECONCILE_CI_RUNNER_TIMEOUT'}
    if($supervision.Status -ne 'COMPLETED'){
        if($supervision.ReasonCode){Write-Host "HYPERV_RESOURCE_RECONCILE_CI_RUNNER_REASON_CODE=$($supervision.ReasonCode)" -ForegroundColor Red}
        if($supervision.ActivationReasonCode){Write-Host "HYPERV_RESOURCE_RECONCILE_CI_RUNNER_ACTIVATION_REASON_CODE=$($supervision.ActivationReasonCode)" -ForegroundColor Red}
        if($supervision.ProvisionReasonCode){Write-Host "HYPERV_RESOURCE_RECONCILE_CI_RUNNER_PROVISION_REASON_CODE=$($supervision.ProvisionReasonCode)" -ForegroundColor Red}
        throw 'HYPERV_RESOURCE_RECONCILE_CI_RUNNER_FAILED'
    }
    Write-Host 'PASS: Isolierte Hyper-V-Ressourcen-Reconcile-Akzeptanz wurde ausgefuehrt.' -ForegroundColor Green
}
catch{$primaryFailure=$_}
finally {
    if($module -and -not $childTerminationUnconfirmed){
        foreach($childOperationId in @("$operationId-resource-r1","$operationId-resource-r2")){
            try{$null=Invoke-HyperVResourceReconcileCiCleanup -Module $module -OperationId $childOperationId -StateRoot $StateRoot}
            catch{$cleanupFailure=$_;break}
        }
    }
    if([string]::IsNullOrWhiteSpace($previousStateRoot)){Remove-Item Env:SQL_SERVER_LAB_STATE -ErrorAction SilentlyContinue}else{$env:SQL_SERVER_LAB_STATE=$previousStateRoot}
    if($module){Remove-Module $module.Name -Force -ErrorAction SilentlyContinue};if($mutexAcquired){$mutex.ReleaseMutex()};$mutex.Dispose()
}
if($primaryFailure){Write-Host 'HYPERV_RESOURCE_RECONCILE_CI_FAILURE_KIND=PRIMARY' -ForegroundColor Red}
if($cleanupFailure){Write-Host 'HYPERV_RESOURCE_RECONCILE_CI_FAILURE_KIND=CLEANUP' -ForegroundColor Red}
if($primaryFailure -and $cleanupFailure){throw 'HYPERV_RESOURCE_RECONCILE_CI_EXECUTION_AND_CLEANUP_FAILED'}
if($primaryFailure){throw 'HYPERV_RESOURCE_RECONCILE_CI_EXECUTION_FAILED'}
if($cleanupFailure){throw 'HYPERV_RESOURCE_RECONCILE_CI_CLEANUP_FAILED'}
Write-Host 'Native Hyper-V-Ressourcen-Reconcile-CI-Akzeptanz erfolgreich.' -ForegroundColor Green
