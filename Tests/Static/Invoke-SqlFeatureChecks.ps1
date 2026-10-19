#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
$count=0
function Assert-Feature {param([bool]$Condition,[string]$Name) if(-not $Condition){throw "SQL_FEATURE_CHECK_FAILED: $Name"};$script:count++;Write-Host "PASS: $Name"}
try {
    foreach($provider in @('docker','podman','hyperv')){
        $declared=if($provider -eq 'hyperv'){[pscustomobject]@{provider=$provider;sqlVersion='2025'}}else{[pscustomobject]@{provider=$provider;version='2025'}}
        $version=& $module {param($i)Get-LabSqlFeatureVersion -Instance $i} $declared
        Assert-Feature ($version -ceq '2025') "$provider authoritative connection version field"
        $resolved=& $module {param($p)Resolve-LabSqlFeatureIntent -Intent ([pscustomobject]@{fullText=$true;fileStream=$false}) -Provider $p -SqlVersion 2025} $provider
        Assert-Feature ($resolved.fullText -and -not $resolved.fileStream) "$provider explicit booleans"
        $absent=& $module {param($p)Resolve-LabSqlFeatureIntent -Intent $null -Provider $p -SqlVersion 2025} $provider
        Assert-Feature ($null -eq $absent) "$provider absent intent preserves defaults"
        if($provider -ne 'hyperv'){
            $rejected=$false
            try{& $module {param($p)Resolve-LabSqlFeatureIntent -Intent ([pscustomobject]@{fileStream=$true}) -Provider $p -SqlVersion 2025} $provider}catch{$rejected=$_.Exception.Message -like 'SQL_FEATURE_FILESTREAM_WINDOWS_REQUIRED*'}
            Assert-Feature $rejected "$provider FILESTREAM rejects before runtime"
        }
    }
    $missing=$false
    try{& $module {Get-LabSqlFeatureVersion -Instance ([pscustomobject]@{provider='hyperv';version='2025'})}}catch{$missing=$_.Exception.Message -eq 'SQL_FEATURE_ENGINE_VERSION_UNKNOWN'}
    Assert-Feature $missing 'Hyper-V never substitutes an unrelated container version field'
    foreach($intent in @([pscustomobject]@{fullText='false'},[pscustomobject]@{fulltext=$true},[pscustomobject]@{fullText=1},[pscustomobject]@{unknown=$true},[pscustomobject]@{})){
        $rejected=$false
        try{& $module {param($i)Resolve-LabSqlFeatureIntent -Intent $i -Provider docker -SqlVersion 2025} $intent}catch{$rejected=$_.Exception.Message -eq 'SQL_FEATURE_INTENT_INVALID'}
        Assert-Feature $rejected 'Malformed or ambiguous intent rejected'
    }
    $schema=Get-Content (Join-Path $repo 'Schemas/lab-manifest.schema.json') -Raw|ConvertFrom-Json -Depth 100
    Assert-Feature ($schema.definitions.instance.properties.sqlFeatures.additionalProperties -eq $false) 'Manifest rejects unknown feature fields'
    Assert-Feature ((Get-Command Set-SqlServerLabFeature).Parameters.ContainsKey('WhatIf')) 'Public mutation supports WhatIf'
    $source=Get-Content (Join-Path $repo 'Private/SqlFeatures.ps1') -Raw
    $shell=Get-Content (Join-Path $repo 'Tools/Set-SqlServerLabFullText.sh') -Raw
    Assert-Feature ($shell.Contains('prefix="$build-"') -and $shell.Contains('apt-get $apt_opts download') -and $shell.Contains('sqlservr.fts.sfp') -and -not $shell.Contains('apt-get install')) 'Signed package follows observed engine build without engine installation'
    Assert-Feature ($source.Contains('SQL_FEATURE_DEPENDENCIES_EXIST') -and $source.Contains('HAS_DBACCESS')) 'Removal fails closed on dependencies and incomplete inventory'
    Assert-Feature ($source.Contains('-NoRetry') -and $source.Contains('-ExpectedVmId')) 'Guest mutation binds VM ID without replay'
    $selection=& (Join-Path $repo 'Tools/Get-CiTestSelection.ps1') -ChangedPath 'Tools/Set-SqlServerLabFullText.sh'
    Assert-Feature ($selection.Docker -and $selection.Podman -and -not $selection.HyperV -and -not $selection.DocumentationOnly -and 'Invoke-SqlFeatureChecks.ps1' -in $selection.StaticChecks) 'Container installer selects both providers and feature contract'
    $selection=& (Join-Path $repo 'Tools/Get-CiTestSelection.ps1') -ChangedPath 'Providers/HyperV/HyperVSqlFeatures.ps1'
    Assert-Feature ($selection.HyperV -and 'Invoke-SqlFeatureChecks.ps1' -in $selection.StaticChecks) 'Windows adapter selects Hyper-V and feature contract'
    $selection=& (Join-Path $repo 'Tools/Get-CiTestSelection.ps1') -ChangedPath 'Tests/Static/Fixtures/SqlFeatureReadinessChecks.ps1'
    Assert-Feature ('Invoke-SqlFeatureChecks.ps1' -in $selection.StaticChecks) 'Standalone database readiness fixture changes execute the feature suite'
    $selection=& (Join-Path $repo 'Tools/Get-CiTestSelection.ps1') -ChangedPath @('Tools/Set-SqlServerLabFullText.sh','Private/Common.ps1')
    Assert-Feature ($selection.Docker -and $selection.Podman -and $selection.HyperV -and $selection.Mixed -and $selection.Adapter) 'Mixed shared-source change preserves conservative matrix'
} finally {Remove-Module $module.Name -Force}
& (Join-Path $PSScriptRoot 'Fixtures/SqlFeatureMutationChecks.ps1')
& (Join-Path $PSScriptRoot 'Fixtures/SqlFeatureReadinessChecks.ps1')
& (Join-Path $PSScriptRoot 'Fixtures/SqlFeatureReconcileChecks.ps1')
Write-Host "SQL FEATURE CHECKS: PASS ($count assertions)"
