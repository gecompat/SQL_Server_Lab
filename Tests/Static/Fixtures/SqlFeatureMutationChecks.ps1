# Isolated fixture: executes the public mutator with synthetic boundaries only.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repo 'Public/Set-SqlServerLabFeature.ps1')
. (Join-Path $repo 'Private/SqlFeatures.ps1')
. (Join-Path $repo 'Providers/HyperV/HyperVSqlFeatures.ps1')
$runId=[guid]::NewGuid();$scope=[guid]::NewGuid().ToString();$runtime='a'*64
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-feature-fixture-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$script:fullText=0;$script:effects=0;$script:writes=0;$script:denyRemoval=$false;$script:loseReply=$false;$script:reads=0;$script:build='17.0.1000.7'
$script:syntheticRun=[pscustomobject]@{scopeId=$scope;metadata=[pscustomobject]@{desiredState=[pscustomobject]@{Instances=@([pscustomobject]@{Id='primary';Intents=[pscustomobject]@{}})}}}
$script:syntheticInstance=[pscustomobject]@{id='primary';provider='docker';version='2025'}
function Get-LabStateRoot {$root}
function Get-LabEnvironmentResourceContext {[pscustomobject]@{Connection=[pscustomobject]@{instances=@($script:syntheticInstance)};Run=$script:syntheticRun}}
function Assert-LabResourceChangeAllowed {}
function Get-LabPersistedDesiredState {[pscustomobject]@{Status='VALID'}}
function Get-LabContainerResourceLockName {param([guid]$RunId,[string]$StateRoot)'SQL_FEATURE_FIXTURE_'+$RunId.ToString('N')}
function Get-LabSqlFeatureContext {
    [pscustomobject]@{RunId=$runId.ToString();InstanceId='primary';Provider='docker';SqlVersion='2025';RuntimeId=$runtime;Run=$script:syntheticRun;Instance=$script:syntheticInstance;RunDirectory=$root;StateRoot=$root}
}
function Get-LabSqlFeatureObservation {$script:reads++;[pscustomobject]@{FullText=$script:fullText;FileStream=0;Build=$script:build}}
function Assert-LabSqlFeatureRemovalSafe {if($script:denyRemoval){throw 'SQL_FEATURE_DEPENDENCIES_EXIST'}}
function Invoke-LabContainerFullTextChange {param($Context,[bool]$Enabled)$script:effects++;$script:fullText=[int]$Enabled;if($script:loseReply){throw 'SYNTHETIC_REPLY_LOST'}}
function Write-LabArtifactJsonAtomic {param([string]$Path,$InputObject)$script:writes++;$InputObject|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $Path}
$parameters=@{RunId=$runId;InstanceId='primary';Feature='FullText';StateRoot=$root;Confirm=$false}
function Assert-MutationFixture {param([bool]$Condition,[string]$Name)if(-not $Condition){throw "SQL_FEATURE_MUTATION_CHECK_FAILED: $Name"};Write-Host "PASS: $Name"}
try {
    $null=Set-SqlServerLabFeature @parameters -Enabled $true -WhatIf
    Assert-MutationFixture ($script:effects -eq 0 -and $script:writes -eq 0) 'WhatIf observes but writes/mutates nothing'
    foreach($otherName in @('container-reconcile-journal.json','hyperv-test-database-reconcile.local.journal.json')){
        $otherJournal=Join-Path $root $otherName
        [IO.File]::WriteAllText($otherJournal,'{"Status":"RECOVERY_REQUIRED"}')
        $failed=$false
        try{$null=Set-SqlServerLabFeature @parameters -Enabled $true}catch{$failed=$_.Exception.Message -eq 'SQL_FEATURE_OTHER_RECOVERY_PENDING'}
        Assert-MutationFixture ($failed -and $script:effects -eq 0) ('Foreign pending resource recovery blocks feature mutation: '+$otherName)
        Remove-Item -LiteralPath $otherJournal
    }
    $parameters.Feature='fulltext'
    $result=Set-SqlServerLabFeature @parameters -Enabled $true
    $parameters.Feature='FullText'
    Assert-MutationFixture ($result.Enabled -and $result.Feature -ceq 'FullText' -and $script:effects -eq 1 -and $script:syntheticRun.metadata.desiredState.Instances[0].Intents.SqlFeatures.fullText) 'Enable canonicalizes accepted CLI casing and persists exact boolean intent'
    $null=Set-SqlServerLabFeature @parameters -Enabled $true
    Assert-MutationFixture ($script:effects -eq 1) 'Repeated enable is a measured no-op'
    $script:denyRemoval=$true;$failed=$false
    try{$null=Set-SqlServerLabFeature @parameters -Enabled $false}catch{$failed=$_.Exception.Message -eq 'SQL_FEATURE_DEPENDENCIES_EXIST'}
    Assert-MutationFixture ($failed -and $script:effects -eq 1 -and $script:fullText -eq 1) 'Dependent data blocks removal before effect'
    $script:denyRemoval=$false;$script:loseReply=$true;$failed=$false
    try{$null=Set-SqlServerLabFeature @parameters -Enabled $false}catch{$failed=$_.Exception.Message -eq 'SYNTHETIC_REPLY_LOST'}
    Assert-MutationFixture ($failed -and $script:effects -eq 2 -and $script:fullText -eq 0) 'Lost reply leaves actual mutation observable'
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Private/EnvironmentResources.ps1'),[ref]$tokens,[ref]$parseErrors)
    $guard=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-LabResourceChangeAllowed'},$true)
    . ([scriptblock]::Create($guard.Extent.Text))
    function Test-LabAutomatedTestEnvironmentRun {$false}
    function Get-LabConnectionCenterCmsConfiguration {$null}
    $resourceRun=Join-Path (Join-Path $root 'runs') $runId.ToString()
    $null=New-Item -ItemType Directory -Path $resourceRun -Force
    [IO.File]::WriteAllText((Join-Path $resourceRun 'sql-feature-primary-FullText.json'),'{"Status":"RECOVERY_REQUIRED"}')
    $failed=$false
    try{Assert-LabResourceChangeAllowed -RunId $runId -StateRoot $root}catch{$failed=$_.Exception.Message -eq 'SQL_FEATURE_RECOVERY_REQUIRED_NO_REPLAY'}
    Assert-MutationFixture $failed 'Actual shared resource guard preserves pending feature recovery'
    Assert-LabResourceChangeAllowed -RunId $runId -StateRoot $root -SqlFeatureOperation
    $failed=$false
    try{$null=Set-SqlServerLabFeature -RunId $runId -InstanceId primary -Feature FileStream -Enabled $false -StateRoot $root -Confirm:$false}catch{$failed=$_.Exception.Message -eq 'SQL_FEATURE_RECOVERY_REQUIRED_NO_REPLAY'}
    Assert-MutationFixture ($failed -and $script:effects -eq 2) 'Pending feature recovery blocks other feature changes'
    $script:loseReply=$false;$failed=$false
    try{$null=Set-SqlServerLabFeature @parameters -Enabled $false}catch{$failed=$_.Exception.Message -eq 'SQL_FEATURE_RECOVERY_REQUIRED_NO_REPLAY'}
    Assert-MutationFixture ($failed -and $script:effects -eq 2) 'Unknown outcome never replays setup'
    $script:build='17.0.1000.8';$failed=$false
    try{$null=Set-SqlServerLabFeature @parameters -Enabled $false -Resume}catch{$failed=$_.Exception.Message -eq 'SQL_FEATURE_RECOVERY_BUILD_CHANGED_NO_REPLAY'}
    Assert-MutationFixture ($failed -and $script:effects -eq 2) 'Recovery rejects engine build drift without replay'
    $script:build='17.0.1000.7'
    $resume=Set-SqlServerLabFeature @parameters -Enabled $false -Resume
    Assert-MutationFixture ($resume.Status -eq 'VERIFIED' -and $script:effects -eq 2 -and -not $script:syntheticRun.metadata.desiredState.Instances[0].Intents.SqlFeatures.fullText) 'Resume observes reached state and commits without effect'
    $script:syntheticInstance.provider='podman';$reads=$script:reads;$failed=$false
    try{$null=Set-SqlServerLabFeature -RunId $runId -InstanceId primary -Feature FileStream -Enabled $true -StateRoot $root -Confirm:$false}catch{$failed=$_.Exception.Message -like 'SQL_FEATURE_FILESTREAM_WINDOWS_REQUIRED*'}
    Assert-MutationFixture ($failed -and $script:reads -eq $reads -and $script:effects -eq 2) 'Linux FILESTREAM rejects before SQL/credential boundary'
    $script:syntheticInstance=[pscustomobject]@{id='primary';provider='hyperv';sqlVersion='2025'}
    function Get-LabSqlFeatureContext {throw 'SYNTHETIC_HYPERV_CONTEXT_REACHED'}
    $reached=$false
    try{$null=Set-SqlServerLabFeature @parameters -Enabled $true -WhatIf}catch{$reached=$_.Exception.Message -eq 'SYNTHETIC_HYPERV_CONTEXT_REACHED'}
    Assert-MutationFixture ($reached -and $script:effects -eq 2) 'Actual public preflight accepts Hyper-V sqlVersion without container version field'
    $script:hyperVRuntime=[guid]::NewGuid().ToString();$script:consumerMode='active';$script:consumerReads=0
    $script:syntheticRun.metadata.desiredState.Instances[0].Intents.SqlFeatures.fullText=$true
    function Get-LabSqlFeatureContext {
        [pscustomobject]@{RunId=$runId.ToString();InstanceId='primary';Provider='hyperv';SqlVersion='2025';RuntimeId=$script:hyperVRuntime;Run=$script:syntheticRun;Instance=$script:syntheticInstance;RunDirectory=$root;StateRoot=$root}
    }
    function Invoke-LabSqlFeatureGuest {param($Context,$ScriptBlock,$Arguments)$script:consumerReads++;& $ScriptBlock @Arguments}
    function Get-Process {
        [CmdletBinding()]param()
        if($script:consumerMode -eq 'unknown'){throw 'SYNTHETIC_CONSUMER_READ_FAILURE'}
        [pscustomobject]@{ProcessName=$(if($script:consumerMode -eq 'active'){'ScenarioEngine'}else{'sqlservr'})}
    }
    $pending=[pscustomobject]@{Contract='SqlServerLab.SqlFeatureOperation/1.0';RunId=$runId.ToString();ScopeId=$scope;InstanceId='primary';Provider='hyperv';RuntimeId=$script:hyperVRuntime;Feature='FullText';Enabled=$false;Build=$script:build;Status='RECOVERY_REQUIRED';Recovery='OBSERVE_ONLY_NO_REPLAY'}
    $pending|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root 'sql-feature-primary-FullText.json')
    foreach($mode in @('active','unknown')){
        $script:consumerMode=$mode;$failed=$false
        $expected=if($mode -eq 'active'){'SQL_FEATURE_SETUP_CONSUMER_ACTIVE_NO_REPLAY'}else{'SQL_FEATURE_SETUP_CONSUMER_END_UNKNOWN_NO_REPLAY'}
        try{$null=Set-SqlServerLabFeature @parameters -Enabled $false -Resume}catch{$failed=$_.Exception.Message -ceq $expected}
        $journal=Get-Content -LiteralPath (Join-Path $root 'sql-feature-primary-FullText.json') -Raw|ConvertFrom-Json
        Assert-MutationFixture ($failed -and $journal.Status -ceq 'RECOVERY_REQUIRED' -and $script:effects -eq 2 -and $script:syntheticRun.metadata.desiredState.Instances[0].Intents.SqlFeatures.fullText) ('Reached Hyper-V target retains recovery for consumer '+$mode)
    }
    $script:consumerMode='ended'
    $resume=Set-SqlServerLabFeature @parameters -Enabled $false -Resume
    $journal=Get-Content -LiteralPath (Join-Path $root 'sql-feature-primary-FullText.json') -Raw|ConvertFrom-Json
    Assert-MutationFixture ($resume.Status -ceq 'VERIFIED' -and $journal.Status -ceq 'COMPLETED' -and $script:effects -eq 2 -and $script:consumerReads -eq 3 -and -not $script:syntheticRun.metadata.desiredState.Instances[0].Intents.SqlFeatures.fullText) 'Hyper-V Resume commits only after actual consumer-end predicate without setup replay'
    $adapterAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Providers/HyperV/HyperVSqlFeatures.ps1'),[ref]$null,[ref]$null)
    $outcomeFunction=$adapterAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-FileStreamWmiOutcome'},$true)
    if(-not $outcomeFunction){throw 'SQL_FEATURE_WMI_FIXTURE_ACTUAL_GUARD_MISSING'}
    . ([scriptblock]::Create($outcomeFunction.Extent.Text))
    foreach($code in @([uint32]0,[uint32]3011,[uint32]2147945411)){
        Assert-FileStreamWmiOutcome -Outcome ([pscustomobject]@{ReturnValue=$code})
        Assert-MutationFixture $true ('Actual WMI guard accepts success/service restart: {0:X8}' -f $code)
    }
    foreach($code in @([uint32]5,[uint32]2147942405,[uint32]3010,[uint32]2147945410)){
        $failed=$false
        try{Assert-FileStreamWmiOutcome -Outcome ([pscustomobject]@{ReturnValue=$code})}catch{$failed=$_.Exception.Message -ceq ('SQL_FEATURE_FILESTREAM_WMI_FAILED: 0x{0:X8}' -f $code)}
        Assert-MutationFixture $failed ('Actual WMI guard rejects failure/OS reboot: {0:X8}' -f $code)
    }
    foreach($outcome in @($null,[pscustomobject]@{})){
        $failed=$false
        try{Assert-FileStreamWmiOutcome -Outcome $outcome}catch{$failed=$_.Exception.Message -ceq 'SQL_FEATURE_FILESTREAM_WMI_OUTCOME_UNKNOWN_NO_REPLAY'}
        Assert-MutationFixture $failed 'Unknown WMI outcome remains a failure'
    }
} finally {
    $absolute=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $absolute.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -notmatch '^sql-feature-fixture-[a-f0-9]{32}$'){throw 'SQL_FEATURE_FIXTURE_CLEANUP_SCOPE_INVALID'}
    Remove-Item -LiteralPath $absolute -Recurse -Force
}
