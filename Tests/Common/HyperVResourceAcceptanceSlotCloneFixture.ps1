# Synthetische Vertragspruefung ohne Providerressourcen.
param([Parameter(Mandatory)][string]$HelperPath)
$ErrorActionPreference='Stop'
. $HelperPath
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-slot-clone-contract-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixtureRoot
try {
    $sourceFile=Join-Path $fixtureRoot 'source.vhdx';[IO.File]::WriteAllText($sourceFile,'synthetic source')
    $runDir=Join-Path $fixtureRoot 'owned';$null=New-Item -ItemType Directory -Path $runDir
    $manifestPath=Join-Path $fixtureRoot 'manifest.json'
    @{name='synthetic-slot-clone';instances=@(@{hyperv=@{memoryStartupMB=6144;memoryMinimumMB=1024;memoryMaximumMB=8192;processorCount=4;dynamicMemoryEnabled=$true}})}|ConvertTo-Json -Depth 10|Set-Content $manifestPath
    $sourceId=[guid]'11111111-1111-1111-1111-111111111111';$scopeId='22222222-2222-2222-2222-222222222222';$vmId='33333333-3333-3333-3333-333333333333'
    $script:sourceState='Off';$script:sourceSqlPlan=$null;$script:sourceScopeValid=$true;$script:snapshots=@();$script:sourceVersion='2025'
    $script:events=[Collections.Generic.List[string]]::new();$script:connection=$null;$script:failCopy=$false
    function New-FixtureSourceContext { [pscustomobject]@{Run=[pscustomobject]@{runId=$sourceId.ToString();scopeId=$scopeId;state='STOPPED'};RunDirectory=$fixtureRoot;Instance=[pscustomobject]@{workload='windows';baseKind='windows-baseline';windowsProvisioning=[pscustomobject]@{state='COMPLETE';computerName='synthetic-source';imageState='COMPLETE'};sqlDeploymentPlan=$script:sourceSqlPlan;vmName='synthetic-source';vmId=$vmId;imageArtifactId='synthetic-artifact'}} }
    function Get-HyperVLabWorkflowRun { throw 'MUTATING_SOURCE_GETTER_MUST_NOT_RUN' }
    function Get-LabRunState { $r=(New-FixtureSourceContext).Run;$r|Add-Member -NotePropertyName metadata -NotePropertyValue ([pscustomobject]@{workflowKind='hyperv-lab'});$r }
    function Test-LabPathWithinRoot { [pscustomobject]@{Valid=$true} }
    function Write-FixtureSource {
        $dir=Join-Path (Join-Path $fixtureRoot 'runs') $sourceId.ToString()
        $null=New-Item -ItemType Directory -Path $dir -Force
        $i=(New-FixtureSourceContext).Instance
        $i|Add-Member -NotePropertyName provider -NotePropertyValue hyperv
        @{instances=@($i)}|ConvertTo-Json -Depth 10|Set-Content (Join-Path $dir 'connection-info.json')
    }
    function Get-HyperVManagedVM { [pscustomobject]@{VM=[pscustomobject]@{State=$script:sourceState;Generation=2;Id=$vmId};Identity=[pscustomobject]@{childVhdxPath=$sourceFile}} }
    function Get-VMSnapshot { $script:snapshots }
    function Get-VMHardDiskDrive { [pscustomobject]@{Path=$sourceFile} }
    function Test-HyperVPathWithinRunDirectory { $script:sourceScopeValid }
    function Get-HyperVImageArtifact { [pscustomobject]@{artifactId='synthetic-artifact';artifactState='OS_SEALED';operatingSystem=[pscustomobject]@{version=$script:sourceVersion};integrityVerification=[pscustomobject]@{status='VERIFIED_HASH'}} }
    function Get-LabSecret { $secret=[securestring]::new();$secret.AppendChar('x');$secret }
    function Read-LabManifest { [pscustomobject]@{} }
    function Resolve-HyperVSqlInstallationMedia { [pscustomobject]@{HashStatus='SIDECAR_READY';IsoPath='synthetic.iso';RelativePath='SQL/2025/Enterprise/ISO/synthetic.iso'} }
    function Confirm-HyperVSqlInstallationMediaVersion { $script:events.Add('media') }
    function Resolve-LabHyperVNetworkBoundPlan { [pscustomobject]@{Status='READY'} }
    function Get-VHD { param($Path) [pscustomobject]@{ParentPath=$null;VhdType='Dynamic'} }
    function Invoke-WithLabWorkflowOperationContext { param($OperationId,$ScriptBlock) $script:events.Add('operation');& $ScriptBlock }
    function New-LabDesiredStateSnapshot { [pscustomobject]@{synthetic=$true} }
    function New-LabRunState { param($Metadata) if(-not $Metadata.desiredState.synthetic){throw 'missing desired state'};$script:events.Add('state');[pscustomobject]@{RunId='44444444-4444-4444-4444-444444444444';ScopeId='55555555-5555-5555-5555-555555555555';RunDir=$runDir} }
    function New-CleanupPlan { $script:events.Add('cleanup-plan') }
    function Set-LabRunState {}
    function Set-LabProviderSubRunState {}
    function Initialize-LabHyperVResourceBinding { [pscustomobject]@{HyperVResourceRoot=$runDir} }
    function Assert-LabHyperVBoundPath { param($Binding,$Path) $Path }
    function Add-CleanupStep { param($ResourceType) $script:events.Add('cleanup-'+$ResourceType) }
    function Convert-VHD { param($Path,$DestinationPath,$VHDType) $script:events.Add('copy');if($script:failCopy){throw 'synthetic copy failure'};[IO.File]::WriteAllText($DestinationPath,'synthetic independent copy') }
    function Invoke-LabHyperVNetworkBoundPlan { [pscustomobject]@{Name='synthetic-network';Intent='hostOnly';Subnet='192.0.2.0';PrefixLength=24;HostAddress='192.0.2.1';Gateway=$null;DnsServers=@()} }
    function Reserve-LabHyperVNetworkAddress { $script:events.Add('lease');[pscustomobject]@{address='192.0.2.5'} }
    function Write-LabArtifactJsonAtomic { param($Path,$InputObject) if($Path.EndsWith('connection-info.json')){$script:connection=$InputObject;$script:events.Add('connection')} }
    function New-HyperVInstance { $script:events.Add('vm');[pscustomobject]@{VMName='synthetic-clone';VMId='66666666-6666-6666-6666-666666666666';NetworkBinding=$null} }
    function Get-LabTimestamp { '2026-01-01T00:00:00Z' }
    function Save-LabSecret { $script:events.Add('secret') }
    function Set-HyperVLabSqlDeploymentPlan { $script:events.Add('sql-plan') }
    function Set-VMMemory { $script:events.Add('memory') }
    function Invoke-HyperVLabSqlSlotInstall { $script:events.Add('sql-install');[pscustomobject]@{State='SQL_SLOT_READY'} }
    function Assert-Fixture { param([bool]$Condition,[string]$Name) if(-not $Condition){throw ('SLOT_CLONE_CONTRACT_FAILED: '+$Name)} }
    Write-FixtureSource
    $null=Get-HyperVResourceAcceptanceSlotSource -SourceRunId $sourceId -StateRoot $fixtureRoot
    foreach($case in @('running','sql','scope','checkpoint','version')){
        $script:sourceState=if($case -eq 'running'){'Running'}else{'Off'}
        $script:sourceSqlPlan=if($case -eq 'sql'){@{state='PLANNED'}}else{$null}
        $script:sourceScopeValid=$case -ne 'scope';$script:snapshots=if($case -eq 'checkpoint'){@('synthetic')}else{@()};$script:sourceVersion=if($case -eq 'version'){'2022'}else{'2025'}
        Write-FixtureSource
        $blocked=$false;try{$null=Get-HyperVResourceAcceptanceSlotSource -SourceRunId $sourceId -StateRoot $fixtureRoot}catch{$blocked=$true};Assert-Fixture $blocked $case
    }
    $script:sourceState='Off';$script:sourceSqlPlan=$null;$script:sourceScopeValid=$true;$script:snapshots=@();$script:sourceVersion='2025'
    Write-FixtureSource
    $cloneArguments=@{SourceRunId=$sourceId;ManifestPath=$manifestPath;OperationId='github-1-1-resource-r1';MediaRoot=$fixtureRoot;SqlPassword=(Get-LabSecret);StateRoot=$fixtureRoot}
    $result=New-HyperVResourceAcceptanceSlotClone @cloneArguments
    Assert-Fixture ($result.State -eq 'RUNNING') 'complete transaction'
    $eventSnapshot=@($script:events)
    Assert-Fixture ([array]::IndexOf($eventSnapshot,'cleanup-plan') -lt [array]::IndexOf($eventSnapshot,'copy') -and [array]::IndexOf($eventSnapshot,'cleanup-vhdx') -lt [array]::IndexOf($eventSnapshot,'copy')) 'copy has prior cleanup'
    Assert-Fixture ([array]::IndexOf($eventSnapshot,'cleanup-ipam-lease') -lt [array]::IndexOf($eventSnapshot,'vm') -and [array]::IndexOf($eventSnapshot,'connection') -lt [array]::IndexOf($eventSnapshot,'sql-install')) 'lease and connection precede SQL'
    Assert-Fixture ($script:connection.instances[0].windowsActivationIntent.Strategy -eq 'VerifyOnly' -and $script:connection.instances[0].windowsActivationIntent.EgressPolicy -eq 'Denied') 'verification only'
    Assert-Fixture ((Get-Content $sourceFile -Raw) -ceq 'synthetic source') 'source unchanged'
    $script:events.Clear();$script:failCopy=$true;$failed=$false
    try{$null=New-HyperVResourceAcceptanceSlotClone @cloneArguments}catch{$failed=$_.Exception.Message -eq 'synthetic copy failure'}
    Assert-Fixture ($failed -and $script:events.Contains('cleanup-vhdx') -and -not $script:events.Contains('vm') -and -not $script:events.Contains('sql-install')) 'copy failure stops before VM or SQL'
    $handle=[IO.File]::Open($sourceFile,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$handle.Dispose()
    $true
} finally {
    $expected=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) (Split-Path $fixtureRoot -Leaf)))
    if($expected -cne [IO.Path]::GetFullPath($fixtureRoot) -or (Split-Path $fixtureRoot -Leaf) -notlike 'sql-lab-slot-clone-contract-*'){throw 'SLOT_CLONE_FIXTURE_CLEANUP_SCOPE_INVALID'}
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
