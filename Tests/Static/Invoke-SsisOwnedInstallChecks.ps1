#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Private/SsisOwnedInstall.ps1')
$passed=0;$failed=0
function Check {param($Name,$Success)if($Success){$script:passed++;Write-Host "PASS $Name"}else{$script:failed++;Write-Host "FAIL $Name"}}
foreach($case in @('same','child','outside')){
    $path=switch($case){same{$repoRoot};child{Join-Path $repoRoot 'synthetic-state'};outside{Join-Path ([IO.Path]::GetTempPath()) 'synthetic-state'}}
    $blocked=$false;try{Assert-LabSsisEvidenceLocation -StateRoot $path -RepositoryRoot $repoRoot}catch{$blocked=$true}
    Check "Lokale Evidence $case" ($blocked -eq ($case -ne 'outside'))
}
$localFailure=& {
    function Add-Content {throw 'SYNTHETIC_PRIVATE_STORAGE_FAILURE'}
    $errorObject=[InvalidOperationException]::new('SYNTHETIC_PRIVATE_PRIMARY')
    $errorObject.Data['PrimaryFailure']='SYNTHETIC_PRIVATE_PRIMARY';$errorObject.Data['CleanupFailure']='SYNTHETIC_PRIVATE_CLEANUP';$errorObject.Data['RecoveryRequired']=$true
    $record=[Management.Automation.ErrorRecord]::new($errorObject,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null)
    @(New-LabSsisLocalFailure -Failure $record -LogPath 'synthetic.log' *>&1)
}
Check 'Diagnose-Schreibfehler verdrängt Primär-/Cleanupfehler nicht und exportiert keine Rohdaten' ($localFailure.Count -eq 1 -and $localFailure[0].Data['PrimaryFailure'] -eq 'SSIS_INSTALL_OPERATION_FAILED' -and $localFailure[0].Data['CleanupFailure'] -eq 'SSIS_INSTALL_CLEANUP_FAILED' -and $localFailure[0].Data['RecoveryRequired'] -and $localFailure[0].Data['EvidenceFailure'] -eq 'SSIS_INSTALL_DIAGNOSTIC_WRITE_FAILED' -and ($localFailure|Out-String) -notmatch 'SYNTHETIC_PRIVATE')
$operation='ssis-install-'+('a'*32);$vm=[guid]'11111111-1111-1111-1111-111111111111'
function New-SyntheticBinding {
    @{Lab=[pscustomobject]@{Run=@{metadata=@{workflowOperationId=$operation;workflowKind='hyperv-lab'}};
        Instance=@{provider='hyperv';vmId=$vm.ToString();workload='windows';windowsProvisioning=@{state='COMPLETE'}}};
      Managed=@{VM=@{Id=$vm;State='Off'}};OperationId=$operation;Sha256='a'*64;VmId=$vm;SqlVersion='2025';MediaEdition='Enterprise';Features=@('SQLENGINE','IS')}
}
foreach($case in @('valid','operation','hash','vm','provider','workload','running','version','edition','extra-feature','missing-feature')){
    $binding=New-SyntheticBinding
    switch($case){operation{$binding.Lab.Run.metadata.workflowOperationId='other'};hash{$binding.Sha256='x'};vm{$binding.Managed.VM.Id=[guid]::NewGuid()};
        provider{$binding.Lab.Instance.provider='docker'};workload{$binding.Lab.Instance.workload='sql'};running{$binding.Managed.VM.State='Running'};
        version{$binding.SqlVersion='2022'};edition{$binding.MediaEdition='Standard'};'extra-feature'{$binding.Features+= 'SDK'};'missing-feature'{$binding.Features=@('SQLENGINE')}}
    $blocked=$false;try{Assert-LabSsisInstallBinding @binding}catch{$blocked=$true}
    Check "Produktbindung $case" ($blocked -eq ($case -ne 'valid'))
}
$arguments=@(Get-LabSsisSetupArguments)
Check 'Setup benötigt keine Dienstsecrets und deaktiviert beide Updatequellen' ($arguments.Count -eq 4 -and $arguments -contains '/UpdateEnabled=False' -and $arguments -contains '/USEMICROSOFTUPDATE=False' -and $arguments -contains '/ISSVCACCOUNT="NT AUTHORITY\NETWORK SERVICE"' -and $arguments -contains '/ISSVCStartupType=Automatic')

$temporary=Join-Path ([IO.Path]::GetTempPath()) ('ssis-offline-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temporary
$file=Join-Path $temporary 'synthetic.iso';[IO.File]::WriteAllText($file,'SYNTHETIC_ISO_BYTES')
$hash=(Get-FileHash -LiteralPath $file).Hash
try {
    $mediaCases=& {
        function Assert-LabDiagnosticPath {param($Path) $Path}
        function Resolve-HyperVSqlInstallationMedia { [pscustomobject]@{IsoPath=$file;HashStatus=$(if($mode -eq 'sidecar-missing'){'MISSING'}else{'SIDECAR_READY'});ExpectedSha256=$(if($mode -eq 'sidecar-drift'){'f'*64}else{$hash})} }
        $values=@{}
        foreach($mode in @('valid','sidecar-missing','sidecar-drift','content-drift')){
            $held=$null;$blocked=$false
            if($mode -eq 'content-drift'){[IO.File]::WriteAllText($file,'CHANGED_SYNTHETIC_BYTES')}
            try{$held=Open-LabSsisApprovedMedia -MediaRoot $temporary -SqlMediaPath 'SQL/synthetic.iso' -ExpectedSha256 $hash}catch{$blocked=$true}
            finally{if($held){$held.Handle.Dispose()}}
            $values[$mode]=$blocked
        }
        $values
    }
    foreach($name in $mediaCases.Keys){Check "Echter Samehandle-Hash $name" ($mediaCases[$name] -eq ($name -ne 'valid'))}
}finally{[IO.File]::Delete($file);[IO.Directory]::Delete($temporary)}

foreach($mode in @('success','partial-arrange','verify-fault','cleanup-fault','both')){
    $events=[Collections.Generic.List[string]]::new();$caught=$null;$result=$null
    try{
        $result=Invoke-LabSsisOwnedTransaction -Arrange {$events.Add('arrange');if($mode -in @('partial-arrange','both')){throw 'SYNTHETIC_PRIMARY'};'own-run'} `
            -Verify {param($Run)$events.Add('verify');if($Run -ne 'own-run'){throw 'binding'};if($mode -eq 'verify-fault'){throw 'SYNTHETIC_PRIMARY'}} `
            -Cleanup {$events.Add('cleanup');if($mode -in @('cleanup-fault','both')){throw 'SYNTHETIC_CLEANUP'}}
    }catch{$caught=$_}
    Check "Cleanup läuft nach jedem begonnenen Arrange: $mode" ($events[-1] -eq 'cleanup' -and @($events|Where-Object {$_ -eq 'cleanup'}).Count -eq 1)
    if($mode -eq 'success'){Check 'PASS setzt erfolgreiche Verify und Cleanup voraus, ETL bleibt offen' ($result.Status -eq 'IS_INSTALL_AND_RESTART_PASSED' -and $result.Etl -eq 'NOT_EXECUTED' -and $result.SsisDb -eq 'NOT_PROVISIONED')}
    else{Check "Primär- und Cleanupfehler getrennt: $mode" ($caught.Exception.Data['RecoveryRequired'] -eq ($mode -in @('cleanup-fault','both')) -and [bool]$caught.Exception.Data['PrimaryFailure'] -eq ($mode -ne 'cleanup-fault'))}
}

# Execute the actual plan function, proving rejection precedes any VM mutation.
$tokens=$null;$errors=$null
$source=Join-Path $repoRoot 'Private/HyperVLabEnvironment.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
Check 'Geänderter produktiver Installer ist parsebar' ($errors.Count -eq 0)
$planAst=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-HyperVLabSqlDeploymentPlan'},$true)
. ([scriptblock]::Create($planAst.Extent.Text))
$planCases=& {
    function Get-HyperVLabWorkflowRun { $lab }
    function Get-HyperVManagedVM { $managed }
    function Set-VMProcessor { $events.Add('processor') }
    function Set-VMMemory { $events.Add('memory') }
    function Write-LabArtifactJsonAtomic { $events.Add('persist') }
    function Get-LabTimestamp {'synthetic'}
    $values=@{}
    foreach($case in @('normal','ssis','unbound-is','old-version','existing-plan')){
        $binding=New-SyntheticBinding;$lab=$binding.Lab;$managed=$binding.Managed
        $lab|Add-Member NoteProperty RunDirectory $repoRoot;$lab|Add-Member NoteProperty Connection @{}
        $lab.Run.runId='synthetic';$lab.Run.scopeId='synthetic';$lab.Instance.vmName='synthetic'
        $events=[Collections.Generic.List[string]]::new();$blocked=$false
        $parameters=@{RunId='synthetic';SqlVersion='2025';DeploymentMode='adhoc-install';MediaEdition='Enterprise';SqlMediaPath='SQL/synthetic.iso'}
        if($case -ne 'normal'){$parameters.SqlFeatures=@('SQLENGINE','IS')}
        if($case -in @('ssis','old-version','existing-plan')){$parameters.SsisOperationId=$operation;$parameters.ExpectedSqlMediaSha256='a'*64;$parameters.ExpectedVmId=$vm}
        if($case -eq 'old-version'){$parameters.SqlVersion='2022'}
        if($case -eq 'existing-plan'){$lab.Instance.sqlDeploymentPlan=@{state='PLANNED'}}
        try{$null=Set-HyperVLabSqlDeploymentPlan @parameters}catch{$blocked=$true}
        $values[$case]=@{Blocked=$blocked;Events=@($events);Plan=$lab.Instance.sqlDeploymentPlan}
    }
    $values
}
foreach($case in @('unbound-is','old-version','existing-plan')){Check "Plan $case vor Hardwaremutation blockiert" ($planCases[$case].Blocked -and $planCases[$case].Events.Count -eq 0)}
Check 'Normaler Nicht-IS-Plan behält Defaults ohne Bindung' (-not $planCases.normal.Blocked -and -not $planCases.normal.Plan.ssisBinding -and @($planCases.normal.Plan.features).Count -eq 3)
Check 'IS-Plan persistiert explizite Freigabe und VM-Bindung' (-not $planCases.ssis.Blocked -and $planCases.ssis.Plan.ssisBinding.VmId -eq $vm.ToString() -and $planCases.ssis.Plan.ssisBinding.OperationId -ceq $operation)
$installAst=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-HyperVLabSqlSlotInstall'},$true)
$assignment=$installAst.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$arguments' -and $n.Right.Extent.Text -match '/ACTION=Install'},$true)
$append=$installAst.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Extent.Text -eq '$arguments += @($SsisArguments)'},$true)
$setupArguments=& {
    $features=@('SQLENGINE','IS');$SsisArguments=@(Get-LabSsisSetupArguments)
    . ([scriptblock]::Create($assignment.Extent.Text))
    . ([scriptblock]::Create($append.Extent.Text))
    $arguments
}
Check 'Tatsächliche Gast-Setupargumente enthalten IS und Updatesperre ohne SDK/ScaleOut' ($setupArguments -contains '/FEATURES=SQLENGINE,IS' -and $setupArguments -contains '/UpdateEnabled=False' -and $setupArguments -contains '/USEMICROSOFTUPDATE=False' -and ($setupArguments -join ' ') -notmatch '(?:SDK|IS_Master|IS_Worker)')
$cleanupCases=& {
    function Get-LabOperationOwnedRun {if($mode -ne 'no-run'){$owned}}
    function Get-CleanupPlan {$plan}
    function Test-HyperVPathWithinRunDirectory {$mode -ne 'foreign-path'}
    function Get-HyperVManagedVM {[pscustomobject]@{VM=@{Id=$(if($mode -eq 'vm-drift'){[guid]::NewGuid()}else{$vm})}}}
    function Remove-SqlServerLab {$events.Add('remove');[pscustomobject]@{RunId=$owned.runId;Status='REMOVED';Cleanup=$(if($mode -eq 'remove-fault'){'FAILED'}else{'CLEANUP_SUCCEEDED'})}}
    function Get-VM {if($mode -eq 'vm-remains'){@{Id=$vm}}}
    function Test-Path {$mode -eq 'disk-remains'}
    $values=@{}
    foreach($mode in @('no-run','partial-before-vm','valid','foreign-operation','foreign-plan','foreign-path','vm-drift','remove-fault','vm-remains','disk-remains')){
        $events=[Collections.Generic.List[string]]::new()
        $owned=[pscustomobject]@{runId='22222222-2222-2222-2222-222222222222';scopeId='33333333-3333-3333-3333-333333333333';metadata=@{workflowKind='hyperv-lab';workflowOperationId=$operation}}
        $plan=[pscustomobject]@{runId=$owned.runId;scopeId=$owned.scopeId;steps=@(@{provider='hyperv';resourceType='vhdx';resourceId='synthetic.vhdx'})}
        if($mode -ne 'partial-before-vm'){$plan.steps+=@{provider='hyperv';resourceType='vm';resourceId='synthetic-vm'}}
        if($mode -eq 'foreign-operation'){$owned.metadata.workflowOperationId='other'}
        if($mode -eq 'foreign-plan'){$plan.steps[0].provider='docker'}
        $blocked=$false;try{Remove-LabSsisOperationRun -OperationId $operation -StateRoot $repoRoot -ExpectedVmId $vm.ToString()}catch{$blocked=$true}
        $values[$mode]=@{Blocked=$blocked;Removed=($events.Count -eq 1)}
    }
    $values
}
foreach($case in @('foreign-operation','foreign-plan','foreign-path','vm-drift')){Check "Echter Cleanup $case vor Remove blockiert" ($cleanupCases[$case].Blocked -and -not $cleanupCases[$case].Removed)}
foreach($case in @('remove-fault','vm-remains','disk-remains')){Check "Echter Cleanup $case meldet Recovery" ($cleanupCases[$case].Blocked -and $cleanupCases[$case].Removed)}
Check 'Partial Arrange vor VM wird nur operationseigen bereinigt' ($cleanupCases['partial-before-vm'].Removed -and -not $cleanupCases['partial-before-vm'].Blocked)
Check 'Kein Run führt zu keiner Löschung' (-not $cleanupCases['no-run'].Removed -and -not $cleanupCases['no-run'].Blocked)
Check 'Eigener vollständiger Cleanup bestätigt Postconditions' ($cleanupCases.valid.Removed -and -not $cleanupCases.valid.Blocked)
$guest=Get-LabSsisInstallGuestProbe
$readerAst=$guest.Ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-SsisInstalledSql'},$true)
. ([scriptblock]::Create($readerAst.Extent.Text))
foreach($case in @('valid','legacy-developer-label','wrong-major','standard-developer','enterprise-paid','not-sysadmin','existing-catalog','duplicate','query-fault')){
    $table=[Data.DataTable]::new()
    foreach($column in @('Major','Edition','Sysadmin','Catalogs')){$null=$table.Columns.Add($column,$(if($column -eq 'Edition'){[string]}else{[int]}))}
    $edition=switch($case){'legacy-developer-label'{'Developer Edition (64-bit)'};'standard-developer'{'Standard Developer Edition (64-bit)'};'enterprise-paid'{'Enterprise Edition (64-bit)'};default{'Enterprise Developer Edition (64-bit)'}}
    $null=$table.Rows.Add(@($(if($case -eq 'wrong-major'){16}else{17}),$edition,$(if($case -eq 'not-sysadmin'){0}else{1}),$(if($case -eq 'existing-catalog'){1}else{0})))
    if($case -eq 'duplicate'){$null=$table.Rows.Add($table.Rows[0].ItemArray)}
    $command=[pscustomobject]@{CommandText='';CommandTimeout=0;Table=$table;Case=$case;Disposed=$false}
    $command|Add-Member ScriptMethod ExecuteReader {if($this.Case -eq 'query-fault'){throw 'SYNTHETIC_QUERY_FAILURE'};return ,$this.Table.CreateDataReader()}
    $command|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    $connection=[pscustomobject]@{Command=$command};$connection|Add-Member ScriptMethod CreateCommand {return $this.Command}
    $blocked=$false;try{Read-SsisInstalledSql -Connection $connection}catch{$blocked=$true}
    Check "Tatsächlicher SQL-Gastleser $case, begrenzt und entsorgt" ($blocked -eq ($case -notin @('valid','legacy-developer-label')) -and $command.Disposed -and $command.CommandTimeout -eq 30)
    $table.Dispose()
}
Write-Host "SSIS OWNED INSTALL CHECKS: $passed PASS, $failed FAIL; native NOT_EXECUTED"
if($failed){exit 1}
