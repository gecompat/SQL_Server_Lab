#Requires -Version 7.2
<#
.SYNOPSIS
    Separater, ausdrücklich freigegebener Windows-2025-Poolnachweis.
.DESCRIPTION
    Erzeugt genau ein eigenes Mitglied. Keine bestehende Umgebung wird
    übernommen. Erfolg räumt ausschließlich dieses eigene Mitglied auf;
    Fehler bewahren State und Child zur Recovery und versuchen einen eigenen
    Stop. Kein UAC, Download, Secretoutput oder automatischer Retry.
.PARAMETER ConfirmSqlSlotInstallation
    Prüft zusätzlich den Workflow-Aufruf des Browsers für genau dieses
    übernommene Poolmitglied. Erwartet den isolierten StateRoot als Standard.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][ValidatePattern('^hyperv-os-sealed-[a-f0-9]{64}$')][string]$ArtifactId,
    [Parameter(Mandatory)][string]$SqlMediaPath,
    [Parameter(Mandatory)][string]$MediaRoot,
    [ValidateSet('Enterprise','Standard','Eval')][string]$MediaEdition='Eval',
    [switch]$RetainEvidenceInStateRoot,
    [switch]$ConfirmNativeExecution,
    [switch]$ConfirmOwnCleanup,
    [switch]$ConfirmSqlSlotInstallation
)
$ErrorActionPreference='Stop'
if(-not $ConfirmNativeExecution -or -not $ConfirmOwnCleanup){throw 'WINDOWS_POOL_NATIVE_EXPLICIT_EXECUTION_AND_CLEANUP_REQUIRED'}
if(-not $IsWindows){throw 'WINDOWS_POOL_NATIVE_WINDOWS_REQUIRED'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
try{$elevated=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}finally{$identity.Dispose()}
if(-not $elevated){throw 'WINDOWS_POOL_NATIVE_ELEVATED_LANE_REQUIRED'}
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module=Import-Module (Join-Path $repo SqlServerLab.psd1) -Force -PassThru
. (Join-Path $repo 'Tests/Common/WindowsPoolNativeAcceptance.ps1')
$media=Resolve-WindowsPoolNativeSqlMedia -Module $module -MediaRoot $MediaRoot -MediaEdition $MediaEdition -SqlMediaPath $SqlMediaPath
$StateRoot=& $module {param($root) Resolve-LabWindowsPoolRoot -StateRoot $root} $StateRoot
if ($ConfirmSqlSlotInstallation) {
    $defaults = & $module { [pscustomobject]@{ StateRoot=(Get-LabStateRoot); MediaRoot=(Get-LabMediaRootDefault) } }
    if (-not $defaults.StateRoot -or -not $defaults.MediaRoot -or
        [IO.Path]::GetFullPath($defaults.StateRoot).TrimEnd('\','/') -ine [IO.Path]::GetFullPath($StateRoot).TrimEnd('\','/') -or
        [IO.Path]::GetFullPath($defaults.MediaRoot).TrimEnd('\','/') -ine [IO.Path]::GetFullPath($MediaRoot).TrimEnd('\','/')) {
        throw 'WINDOWS_POOL_NATIVE_SQL_SLOT_BOUND_DEFAULTS_REQUIRED'
    }
}
$baseline=@(Get-SqlServerLabHyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot -VerifyIntegrity)
if($baseline.Count -ne 1 -or $baseline[0].IntegrityStatus -cne 'VERIFIED' -or $baseline[0].ArtifactState -cne 'OS_SEALED' -or
    $baseline[0].OperatingSystem.Version -notmatch '2025' -or $baseline[0].OperatingSystem.InstallationType -cne 'desktop-experience' -or
    $baseline[0].Evaluation.Status -cne 'EVALUATION_VALID' -or $baseline[0].TemplateValidation.Status -cne 'CHILD_BOOT_VERIFIED'){
    throw 'WINDOWS_POOL_NATIVE_VERIFIED_2025_DESKTOP_BASELINE_REQUIRED'
}
$parentPath=& $module {param($id,$root) (Get-HyperVImageArtifact -ArtifactId $id -StateRoot $root).Path} $ArtifactId $StateRoot
$parentBefore=Get-WindowsPoolNativeParentFingerprint -Path $parentPath
$poolId=[guid]::NewGuid();$prefix='c-pool-native-'+$poolId.ToString('N').Substring(0,10)
$evidenceBase=if($RetainEvidenceInStateRoot){Join-Path $StateRoot 'test-evidence/windows-pool-native'}else{Join-Path $repo '.artifacts/windows-pool-native'}
$evidenceDirectory=Join-Path $evidenceBase $poolId.ToString('N')
if($RetainEvidenceInStateRoot -and -not (& $module {param($Root,$Path) (Test-LabPathWithinRoot -Root $Root -Path $Path).Valid} $StateRoot $evidenceDirectory)){
    throw 'WINDOWS_POOL_NATIVE_EVIDENCE_PATH_UNSAFE'
}
$null=New-Item -ItemType Directory -Path $evidenceDirectory -Force
$report=[ordered]@{ContractVersion='SqlServerLab.WindowsPoolNativeAcceptance/1.0';PoolId=$poolId.ToString();ArtifactId=$ArtifactId
    Status='RUNNING';Checks=@();RunIds=@();OriginalBindings=@();OriginalError=$null;OriginalCause=$null;PreparationErrors=@();StopErrors=@();CleanupErrors=@();CleanupConfirmed=$true
    ParentBefore=$parentBefore;ParentAfter=$null}
$success=$false
$sqlSetupAttempted=$false
$bindings=[ordered]@{}
function Get-OwnNativeMembers {
    $runs=@(& $module {param($root,$pool)
        @(Get-LabWindowsPoolRuns -StateRoot $root | Where-Object {$_.metadata.windowsPoolMember.poolId -ceq $pool})
    } $StateRoot $poolId.ToString())
    $initialSnapshots=@(foreach($run in $runs){[pscustomobject]@{Run=$run;RunDirectory=(Join-Path (Join-Path $StateRoot runs) $run.runId);VmId=[string]$run.metadata.windowsPoolMember.vmId;ChildPaths=@();AdapterIds=@()}})
    Update-WindowsPoolNativeAcceptanceBindings -Bindings $bindings -Snapshots $initialSnapshots -PoolId $poolId.ToString()
    $report.RunIds=@($bindings.Keys);$report.OriginalBindings=@($bindings.Values)
    $snapshots=@(& $module {
        param($runs,$root)
        foreach($run in $runs){
            $directory=Split-Path -Parent (Get-LabWindowsPoolMemberPath -RunId $run.runId -StateRoot $root)
            $vms=@(Get-HyperVLabVMs -RunId $run.runId -ScopeId $run.scopeId)
            if($vms.Count -gt 1){throw 'WINDOWS_POOL_NATIVE_OWN_SCOPE_MISMATCH'}
            $vmId=[string]$run.metadata.windowsPoolMember.vmId;$adapters=@();$children=@()
            if($vms.Count){
                $managed=Get-HyperVManagedVM -VMName $vms[0].VMName -ExpectedRunId $run.runId -ExpectedScopeId $run.scopeId
                Assert-LabWindowsPoolNotes -Identity $managed.Identity -StateRoot $root -Run $run
                if($vmId -and $vmId -cne [string]$managed.VM.Id){throw 'WINDOWS_POOL_NATIVE_ORIGINAL_BINDING_CHANGED'}
                $vmId=[string]$managed.VM.Id
                $children=@([string]$managed.Identity.childVhdxPath)+@($managed.Identity.additionalDrives|ForEach-Object {[string]$_.path})
                $adapters=@(Get-VMNetworkAdapter -VM $managed.VM -ErrorAction Stop|ForEach-Object {[string]$_.Id})
            }
            $cleanupPath=Join-Path $directory cleanup-plan.json
            if(Test-Path -LiteralPath $cleanupPath -PathType Leaf){
                if(-not(Test-LabPathWithinRoot -Root $root -Path $cleanupPath).Valid){throw 'WINDOWS_POOL_NATIVE_OWN_SCOPE_MISMATCH'}
                $plan=Read-LabWorkflowJson -Path $cleanupPath
                if($plan.runId -cne $run.runId -or $plan.scopeId -cne $run.scopeId -or @($plan.steps|Where-Object {$_.provider -and $_.provider -cne 'hyperv'}).Count){throw 'WINDOWS_POOL_NATIVE_OWN_SCOPE_MISMATCH'}
                $children+=@($plan.steps|Where-Object resourceType -ceq 'vhdx'|ForEach-Object {[string]$_.resourceId})
            }
            $ipamPath=Get-LabHyperVIpamPath -StateRoot $root
            if(-not(Test-LabPathWithinRoot -Root $root -Path $ipamPath).Valid){throw 'WINDOWS_POOL_NATIVE_OWN_IPAM_UNKNOWN'}
            [pscustomobject]@{Run=$run;RunDirectory=$directory;VmId=$vmId;ChildPaths=@($children|Where-Object {$_}|Sort-Object -Unique);AdapterIds=$adapters;IpamRequired=(Test-Path -LiteralPath $ipamPath -PathType Leaf)}
        }
    } $runs $StateRoot)
    Update-WindowsPoolNativeAcceptanceBindings -Bindings $bindings -Snapshots $snapshots -PoolId $poolId.ToString()
    $report.RunIds=@($bindings.Keys);$report.OriginalBindings=@($bindings.Values)
    $runs
}
function Invoke-ConfirmedMember([string]$runId,[string]$action,$sqlPlan=$null){
    $preview=(Invoke-SqlServerLabWorkflowAction -Action PlanWindowsPoolMember -RunId $runId -StateRoot $StateRoot -SlotReserveOperation $action -SlotReserveSqlPlan $sqlPlan).Result
    if($preview.PoolId -cne $poolId.ToString()){throw 'WINDOWS_POOL_NATIVE_OWN_SCOPE_MISMATCH'}
    (Invoke-SqlServerLabWorkflowAction -Action ApplyWindowsPoolMember -SlotReservePreviewId $preview.PreviewId -ConfirmSlotReserveMember).Result
}
try{
    $configuration=@{Count=1;NamePrefix=$prefix;PoolId=$poolId;ArtifactId=$ArtifactId;GenerateAdministratorPasswords=$true;StateRoot=$StateRoot
        Region='AT';SystemLocale='de-AT';UiLanguage=$baseline[0].OperatingSystem.Language;InputLocale='0407:00000407';TimeZone='W. Europe Standard Time'}
    $created=New-SqlServerLabWindowsSlotPool @configuration -Confirm:$false
    $report.PreparationErrors=@($created.Slots|Where-Object OriginalError|Select-Object Index,OriginalError,CleanupError,DiagnosticError)
    if($created.Status -cne 'COMPLETE' -or @($created.Slots).Count -ne 1){throw 'WINDOWS_POOL_NATIVE_PREPARATION_FAILED'}
    $own=@(Get-OwnNativeMembers);if($own.Count -ne 1){throw 'WINDOWS_POOL_NATIVE_OWN_SCOPE_MISMATCH'}
    $runId=$own[0].runId
    $inventory=(Invoke-SqlServerLabWorkflowAction -Action GetSlotReserveState -StateRoot $StateRoot).Result
    $row=@($inventory.Rows | Where-Object Reference -ceq $runId)
    if($row.Count -ne 1 -or $row[0].MemberState -cne 'FREE' -or $row[0].Evidence -cne 'CURRENT'){throw 'WINDOWS_POOL_NATIVE_FRESH_OFF_MEMBER_REQUIRED'}
    $report.Checks+='REAL_GUEST_CAPTURE_BOUND_OFF_AVAILABLE'
    $resumed=New-SqlServerLabWindowsSlotPool @configuration -Confirm:$false
    if($resumed.Status -cne 'COMPLETE' -or $resumed.Slots[0].RunId -cne $runId -or $resumed.Slots[0].Action -cne 'REUSED_BOUND_MEMBER'){throw 'WINDOWS_POOL_NATIVE_RESUME_ID_CHANGED'}
    $report.Checks+='SAME_POOL_OPERATION_RESUME'
    $preview=(Invoke-SqlServerLabWorkflowAction -Action PlanWindowsPoolMember -RunId $runId -StateRoot $StateRoot -SlotReserveOperation Claim).Result
    $null=Invoke-SqlServerLabWorkflowAction -Action CancelWindowsPoolMember -SlotReservePreviewId $preview.PreviewId
    if((Get-OwnNativeMembers)[0].metadata.windowsPoolMember.state -cne 'FREE'){throw 'WINDOWS_POOL_NATIVE_CANCEL_MUTATED'}
    $report.Checks+='PREVIEW_CANCEL_NO_MUTATION'
    $claim=Invoke-ConfirmedMember $runId Claim
    if($claim.Status -cne 'CLAIMED'){throw 'WINDOWS_POOL_NATIVE_CLAIM_FAILED'}
    $blocked=$false;try{$null=Stop-SqlServerLab -RunId $runId -StateRoot $StateRoot -Confirm:$false}catch{$blocked=$_.Exception.Message -like 'WINDOWS_POOL_MEMBER_RESERVED*'}
    if(-not $blocked){throw 'WINDOWS_POOL_NATIVE_DIRECT_BYPASS_NOT_BLOCKED'}
    $report.Checks+='DIRECT_LIFECYCLE_GUARD'
    $released=Invoke-ConfirmedMember $runId Release
    if($released.Status -cne 'RELEASED'){throw 'WINDOWS_POOL_NATIVE_SAFE_RELEASE_FAILED'}
    $claim=Invoke-ConfirmedMember $runId Claim
    $sql=@{SqlVersion='2025';DeploymentMode='adhoc-install';MediaEdition=$media.MediaEdition;SqlMediaPath=$media.RelativePath
        SqlFeatures=@('SQLENGINE');ProcessorCount=4;MemoryStartupMB=$(if($ConfirmSqlSlotInstallation){6144}else{2048})}
    $consumed=Invoke-ConfirmedMember $runId Consume $sql
    if($consumed.Status -cne 'CONSUMED'){throw 'WINDOWS_POOL_NATIVE_CONSUME_FAILED'}
    $report.Checks+='SQL_PLAN_AND_ACTUAL_CPU_RAM_CONSUMED'
    if ($ConfirmSqlSlotInstallation) {
        $binding = $bindings[$runId]
        if (-not $binding.VmId) { throw 'WINDOWS_POOL_NATIVE_ORIGINAL_BINDING_INCOMPLETE' }
        $view = Get-SqlServerLabWorkflow -MediaRoot $MediaRoot
        $sqlPreview = Get-WindowsPoolNativeSqlContinuationPlan -Workflow $view -RunId $runId -MediaEdition $media.MediaEdition
        $sqlSetupAttempted = $true
        $installed = (Invoke-SqlServerLabWorkflowAction -Action InstallHyperVLabSqlSlot -RunId $runId -ExpectedPlanKey $sqlPreview.PlanKey).Result
        if ($installed.RunId -cne $runId -or $installed.State -cne 'SQL_SLOT_READY' -or @($installed.PSObject.Properties).Count -ne 2) {
            throw 'WINDOWS_POOL_NATIVE_SQL_SLOT_RESULT_INVALID'
        }
        $report.Checks += 'BROWSER_WORKFLOW_ACTION_INSTALLED_BOUND_SQL_SLOT'
        $ready = & $module {
            param($Root,$Binding)
            $lab = Get-HyperVLabWorkflowRun -RunId $Binding.RunId -StateRoot $Root -ExpectedVmId ([guid]$Binding.VmId) -NoWrite
            if ($lab.Run.scopeId -cne $Binding.ScopeId -or $lab.Run.state -cne 'RUNNING' -or
                $lab.Instance.sqlDeploymentPlan.state -cne 'SQL_SLOT_READY') { throw 'WINDOWS_POOL_NATIVE_SQL_SLOT_BINDING_CHANGED' }
            $guest = $sa = $null
            try {
                $guest = Get-LabSecret -Path $lab.RunDirectory -Name 'guest-administrator-password'
                $sa = Get-LabSecret -Path $lab.RunDirectory -Name 'generated-sql-sa-password'
                if (-not $sa) { $sa = Get-LabSecret -Path $lab.RunDirectory -Name 'sa-password' }
                if (-not $guest -or -not $sa) { throw 'WINDOWS_POOL_NATIVE_SQL_SLOT_CREDENTIAL_UNAVAILABLE' }
                Wait-HyperVGuestSqlReady -VMName $lab.Instance.vmName -ExpectedRunId $Binding.RunId -ExpectedScopeId $Binding.ScopeId `
                    -ExpectedVmId ([guid]$Binding.VmId) -StateRoot $Root -Credential ([PSCredential]::new('Administrator',$guest)) `
                    -SaPassword $sa -ExpectedMajorVersion 17 -TimeoutSeconds 180
            }
            finally {
                if ($guest) { $guest.Dispose() }
                if ($sa) { $sa.Dispose() }
            }
        } $StateRoot $binding
        if (-not $ready.Ready -or $ready.MajorVersion -ne 17 -or $ready.RunId -cne $runId -or $ready.ScopeId -cne $binding.ScopeId) {
            throw 'WINDOWS_POOL_NATIVE_SQL_SLOT_GUEST_NOT_READY'
        }
        $report.Checks += 'SQL_2025_READY_INSIDE_THE_SAME_OWNED_VM'
    }
    $success=$true
}catch{
    $report.OriginalCause=Get-WindowsPoolNativeFailureDetail -Failure $_ -Fallback WINDOWS_POOL_NATIVE_ACCEPTANCE_FAILED
    $report.OriginalError=$report.OriginalCause.Code;$report.Status='RECOVERY_REQUIRED'
}
finally{
    # Rediscovery validates retained identities; names never replace ownership.
    $discoveryValid=$false
    try{$own=@(Get-OwnNativeMembers);$discoveryValid=$true}catch{$report.StopErrors+=@{Code='WINDOWS_POOL_NATIVE_OWN_INVENTORY_FAILED'}}
    foreach($binding in @($bindings.Values)){
        $stop=$null
        try{
            $run=& $module {param($id,$root) Get-LabRunState -RunId $id -StateRoot $root} $binding.RunId $StateRoot
            if($run.scopeId -cne $binding.ScopeId -or $run.metadata.windowsPoolMember.poolId -cne $poolId.ToString() -or
                ($run.metadata.windowsPoolMember.vmId -and [string]$run.metadata.windowsPoolMember.vmId -cne $binding.VmId) -or
                (-not $run.metadata.windowsPoolMember.vmId -and -not $discoveryValid)){throw 'OWN_BINDING_CHANGED'}
            if($run.metadata.windowsPoolMember.state -in @('PREPARING','CLAIMED','RECOVERY_REQUIRED')){
                $stop=Invoke-ConfirmedMember $run.runId Stop
                if($stop.Status -cne 'STOPPED_CLAIM_HELD'){throw 'OWN_STOP_FAILED'}
            }elseif($run.state -notin @('STOPPED','REMOVED')){$null=Stop-SqlServerLab -RunId $run.runId -StateRoot $StateRoot -Confirm:$false}
            elseif ($sqlSetupAttempted -and $run.state -ceq 'STOPPED' -and $run.metadata.windowsPoolMember.state -ceq 'CONSUMED') {
                # Setup can boot the child before persisting RUNNING.
                $null = & $module {
                    param($Root,$Binding)
                    $lab = Get-HyperVLabWorkflowRun -RunId $Binding.RunId -StateRoot $Root -ExpectedVmId ([guid]$Binding.VmId) -NoWrite
                    if ($lab.Run.scopeId -cne $Binding.ScopeId) { throw 'WINDOWS_POOL_NATIVE_SQL_SLOT_BINDING_CHANGED' }
                    Stop-HyperVInstance -VMName $lab.Instance.vmName -ExpectedRunId $Binding.RunId -ExpectedScopeId $Binding.ScopeId `
                        -ExpectedVmId $Binding.VmId -ExpectedInstanceId $lab.Instance.id -StateRoot $Root
                } $StateRoot $binding
            }
        }catch{$report.StopErrors+=@{RunId=$binding.RunId;Code='WINDOWS_POOL_NATIVE_OWN_STOP_FAILED';Cause=(Get-WindowsPoolNativeFailureDetail -Failure $_ -Fallback WINDOWS_POOL_NATIVE_OWN_STOP_FAILED);OperationFailure=($stop|Select-Object OriginalError,CauseCode,CleanupError,DiagnosticError)};continue}
        if($success -and $discoveryValid){
            try{
                $fresh=@(Get-OwnNativeMembers | Where-Object runId -ceq $run.runId)[0]
                if($fresh.metadata.windowsPoolMember.state -ceq 'CONSUMED'){
                    $removed=Remove-SqlServerLab -RunId $run.runId -StateRoot $StateRoot -Force -Confirm:$false
                }else{$removed=Invoke-ConfirmedMember $run.runId Cleanup}
                if($removed.Status -cne 'REMOVED'){throw 'OWN_CLEANUP_FAILED'}
                $tombstone=@(Get-OwnNativeMembers | Where-Object runId -ceq $run.runId)[0]
                if($tombstone.state -cne 'REMOVED' -or $tombstone.metadata.windowsPoolMember.state -cne 'REMOVED'){throw 'OWN_TERMINAL_NOT_REMOVED'}
                $remaining=& $module {param($run,$scope) @(Get-HyperVLabVMs -RunId $run -ScopeId $scope)} $run.runId $run.scopeId
                $vmById=@(Get-VM -ErrorAction Stop|Where-Object {[string]$_.Id -ceq $binding.VmId})
                $children=@($binding.ChildPaths|Where-Object {Test-Path -LiteralPath $_})
                $adapterIds=@(Get-VMNetworkAdapter -All -ErrorAction Stop|Where-Object {[string]$_.Id -cin $binding.AdapterIds}|ForEach-Object {[string]$_.Id})
                $ipam = Get-WindowsPoolNativeIpamEvidence -Module $module -StateRoot $StateRoot -RunId $binding.RunId -ScopeId $binding.ScopeId
                Assert-WindowsPoolNativeCleanupProof -Binding $binding -Run $tombstone -LiveVms @(@($remaining)+$vmById) `
                    -ExistingChildren $children -LiveAdapterIds $adapterIds -ActiveLeases $ipam.ActiveLeases -SecretExists (Test-Path -LiteralPath (Join-Path $binding.RunDirectory secrets)) `
                    -IpamAvailable $ipam.Available
                $report.Checks+='OWN_VM_CHILD_ADAPTER_IPAM_SECRET_ABSENCE'
            }catch{
                $report.CleanupErrors+=@{RunId=$run.runId;Code='WINDOWS_POOL_NATIVE_OWN_CLEANUP_FAILED';Cause=(Get-WindowsPoolNativeFailureDetail -Failure $_ -Fallback WINDOWS_POOL_NATIVE_OWN_CLEANUP_FAILED)}
            }
        }
    }
    try{
        $report.ParentAfter=Get-WindowsPoolNativeParentFingerprint -Path $parentPath
        Assert-WindowsPoolNativeParentUnchanged -Before $parentBefore -After $report.ParentAfter
        $verified=@(Get-SqlServerLabHyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot -VerifyIntegrity)
        if($verified.Count -ne 1 -or $verified[0].IntegrityStatus -cne 'VERIFIED'){throw 'OWN_PARENT_INTEGRITY_FAILED'}
        $report.Checks+='INDEPENDENT_PARENT_HASH_METADATA_PROTECTION_UNCHANGED'
    }catch{$report.CleanupErrors+=@{Code='WINDOWS_POOL_NATIVE_PARENT_POSTCONDITION_FAILED'}}
    if($success -and $discoveryValid -and $bindings.Count -eq 1 -and -not $report.StopErrors.Count -and -not $report.CleanupErrors.Count){$report.Status='PASS'}
    elseif($success){$report.Status='CLEANUP_RECOVERY_REQUIRED'}
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $evidenceDirectory acceptance.json) -Encoding utf8
}
if($report.Status -cne 'PASS'){throw ('WINDOWS_POOL_NATIVE_'+$report.Status+': own evidence retained at '+$evidenceDirectory)}
Write-Host ('Windows pool native acceptance: PASS; own member removed; evidence='+$evidenceDirectory)
