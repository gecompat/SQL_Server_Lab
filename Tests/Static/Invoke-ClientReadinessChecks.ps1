#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Private/ClientReadiness.ps1')
$mode='success';$calls=0
function Initialize-LabHostToolPath {
    param($Name)
    if($mode -eq 'resolution'){throw 'synthetic-private-override'}
    [pscustomobject]@{Available=($mode -ne 'missing');Invocation=$(if($mode -eq 'alias'){'synthetic-alias'}else{Join-Path ([IO.Path]::GetTempPath()) 'synthetic-runtime.exe'})}
}
function Invoke-LabProgressNativeCommand {
    param($FilePath,$ArgumentList,$Phase,$TimeoutSeconds)
    $script:calls++
    if($ArgumentList.Count -ne 3 -or ($ArgumentList -join ' ') -ne 'info --format json' -or $TimeoutSeconds -ne 20){throw 'MUTATING_OR_UNBOUNDED_READINESS_PROBE'}
    switch($mode){
        'execution-denied' {throw [ComponentModel.Win32Exception]::new(5)}
        'timeout' {throw 'LAB_NATIVE_OPERATION_TIMEOUT'}
        'denied' {return [pscustomobject]@{ExitCode=1;Output=@('permission denied synthetic-private-socket')}}
        'unreachable' {return [pscustomobject]@{ExitCode=1;Output=@('synthetic-private-endpoint unavailable')}}
        'invalid' {return [pscustomobject]@{ExitCode=0;Output=@('not-json')}}
        'empty' {return [pscustomobject]@{ExitCode=0;Output=@('{}')}}
        default {return [pscustomobject]@{ExitCode=0;Output=@('{"ServerVersion":"synthetic","host":{"arch":"amd64"},"version":{"Version":"synthetic"}}')}}
    }
}
function Assert-ClientReadiness {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "FAIL: $Name"};Write-Host "PASS: $Name"}
$expected=@{success='PROVIDER_REACHABLE';missing='TOOL_NOT_INSTALLED';resolution='TOOL_RESOLUTION_FAILED';alias='TOOL_NATIVE_PATH_REQUIRED';'execution-denied'='TOOL_EXECUTION_DENIED';timeout='PROVIDER_PROBE_TIMEOUT';denied='PROVIDER_ACCESS_DENIED';unreachable='PROVIDER_UNREACHABLE';invalid='PROVIDER_RESPONSE_INVALID';empty='PROVIDER_RESPONSE_INVALID'}
foreach($case in $expected.Keys){
    $mode=$case;$calls=0
    $result=Get-LabClientRuntimeReadiness -Provider docker
    Assert-ClientReadiness ($result.Code -eq $expected[$case]) "Runtime-Klasse $case bleibt unterscheidbar"
    Assert-ClientReadiness (($result | ConvertTo-Json -Compress) -notmatch 'synthetic-private') "Runtime-Klasse $case unterdrueckt Rohdaten"
    if($case -in @('missing','resolution','alias')){Assert-ClientReadiness ($calls -eq 0) "Runtime-Klasse $case startet keine CLI"}
}
$mode='success'
Assert-ClientReadiness ((Get-LabClientRuntimeReadiness -Provider podman).Code -eq 'PROVIDER_REACHABLE') 'Podman akzeptiert seinen eigenen strukturierten Infovertrag'
$missingRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-readiness-absent-'+[guid]::NewGuid().ToString('N'))
$result=Test-LabClientReadiness -RepositoryRoot $missingRoot
Assert-ClientReadiness ($result.Status -eq 'NOT_READY' -and $result.MissingPrerequisites -contains 'REPOSITORY_INCOMPLETE') 'Unvollstaendiger Checkout liefert strukturierten Bootstrapfehler'
Assert-ClientReadiness (-not (Test-Path -LiteralPath $missingRoot) -and -not $result.MutationAllowed -and -not $result.SkillLoaderVerified) 'Bootstrap erzeugt keinen Root und behauptet weder Mutation noch Skill-Erkennung'

$fixtureModule=New-Module -ScriptBlock {
    $script:ModuleLoadErrors=@();$script:storageMode='ready'
    function SyntheticPublicCommand {}
    function Get-LabClientRuntimeReadiness {param($Provider);[pscustomobject]@{Category='Reachability';Code='PROVIDER_REACHABLE';Status='PASS';NextStep=''}}
    function Get-LabStorageConfiguration {
        if($script:storageMode -eq 'invalid'){throw 'synthetic-private-catalog'}
        if($script:storageMode -eq 'missing'){return [pscustomobject]@{ControllerId=$null;DefaultLocationId=$null}}
        [pscustomobject]@{ControllerId='synthetic';DefaultLocationId='synthetic'}
    }
    function Test-LabAdministrator {return $false}
    Export-ModuleMember -Function SyntheticPublicCommand
}
function Test-ModuleManifest {[CmdletBinding()]param($Path);[pscustomobject]@{Name='synthetic'}}
function Import-Module {[CmdletBinding()]param($Name,[switch]$Force,[switch]$PassThru);return $fixtureModule}
function Import-PowerShellDataFile {param($Path);@{FunctionsToExport=@('SyntheticPublicCommand')}}
$result=Test-LabClientReadiness -RepositoryRoot $repoRoot -Provider docker
Assert-ClientReadiness ($result.Status -eq 'READY') 'Vollstaendiger Bootstrap liefert READY'
& $fixtureModule {$script:storageMode='missing'}
$result=Test-LabClientReadiness -RepositoryRoot $repoRoot -Provider docker -Operation Create
Assert-ClientReadiness ($result.Status -eq 'NOT_READY' -and $result.MissingPrerequisites -contains 'STORAGE_CONFIGURATION_REQUIRED') 'Create blockiert ohne Storage-Konfiguration'
$result=Test-LabClientReadiness -RepositoryRoot $repoRoot -Provider docker -Operation Inspect
Assert-ClientReadiness ($result.Status -eq 'READY_WITH_WARNINGS' -and $result.Warnings -contains 'STORAGE_CONFIGURATION_REQUIRED') 'Inspect kann fehlende Storage-Konfiguration read-only melden'
& $fixtureModule {$script:storageMode='invalid'}
$result=Test-LabClientReadiness -RepositoryRoot $repoRoot
Assert-ClientReadiness ($result.MissingPrerequisites -contains 'STORAGE_CONFIGURATION_INVALID' -and ($result|ConvertTo-Json -Depth 6) -notmatch 'synthetic-private-catalog') 'Defekter Katalog bleibt erhalten und sein Inhalt verborgen'
& $fixtureModule {$script:storageMode='ready'}
$result=Test-LabClientReadiness -RepositoryRoot $repoRoot -Provider hyperv -Operation PrepareImage
Assert-ClientReadiness ($result.MissingPrerequisites -contains 'ELEVATION_REQUIRED') 'Offline-Imageoperation benoetigt zusaetzliche Privilegien'
$result=Test-LabClientReadiness -RepositoryRoot $repoRoot -Provider docker -Operation PrepareImage
Assert-ClientReadiness ($result.MissingPrerequisites -contains 'OPERATION_PROVIDER_UNSUPPORTED') 'Offline-Hyper-V-Operation wird fuer Docker nicht freigegeben'
function Import-PowerShellDataFile {param($Path);@{FunctionsToExport=@('MissingSyntheticCommand')}}
$result=Test-LabClientReadiness -RepositoryRoot $repoRoot
Assert-ClientReadiness ($result.MissingPrerequisites -contains 'MODULE_EXPORTS_MISSING') 'Fehlender oeffentlicher Export blockiert Bootstrap'
& $fixtureModule {$script:ModuleLoadErrors=@('synthetic-private-import-error')}
$result=Test-LabClientReadiness -RepositoryRoot $repoRoot
Assert-ClientReadiness ($result.MissingPrerequisites -contains 'MODULE_IMPORT_FAILED' -and ($result|ConvertTo-Json -Depth 6) -notmatch 'synthetic-private-import-error') 'Teilweise fehlgeschlagener Modulimport wird nicht als bereit gemeldet'
