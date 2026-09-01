#Requires -Version 7.2
<#
.SYNOPSIS
    Baut ein isoliertes SQL-Prepared-Artifact und fuehrt den nativen Hyper-V-SQL-Port-Reconcile aus.
.DESCRIPTION
    Verwendet den realen N4-Prepared-Image-Runner mit expliziter Aufbewahrung,
    uebergibt Artifact-ID und State Root an die SQL-Port-Abnahme und entfernt
    beide nur nach erfolgreichem Reconcile und Cleanup.
#>
[CmdletBinding()]
param([string]$MediaRoot='D:\Lab_Base',[ValidateRange(300,3600)][int]$TimeoutSeconds=1200,[ValidateRange(600,10800)][int]$SetupTimeoutSeconds=7200)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path;$modulePath=Join-Path $repoRoot 'SqlServerLab.psd1'
$preparedRunner=Join-Path $PSScriptRoot 'Invoke-HyperVSqlPreparedImageAcceptance.ps1';$portRunner=Join-Path $PSScriptRoot 'Invoke-HyperVSqlPortReconcileAcceptance.ps1'
$retainedStateRoot=$null;$retainedArtifactId=$null;$productionStateRoot=$null;$testFailed=$false
function Invoke-BootstrapChildProcess {param([Parameter(Mandatory)][string[]]$Arguments)$lines=[Collections.Generic.List[string]]::new();& pwsh @Arguments 2>&1|ForEach-Object{$line=[string]$_;$lines.Add($line);Write-Host $line};[PSCustomObject]@{ExitCode=$LASTEXITCODE;Lines=@($lines)}}
function Assert-RetainedStateRootScope {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedParent)
    $resolved=[IO.Path]::GetFullPath($Path).TrimEnd('\');$parent=[IO.Path]::GetFullPath($ExpectedParent).TrimEnd('\')
    if(-not [IO.Directory]::GetParent($resolved).FullName.TrimEnd('\').Equals($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^n4sql-[a-f0-9]{8}$'){throw 'HYPERV_SQL_PORT_BOOTSTRAP_STATE_SCOPE_INVALID'};$resolved
}
try{
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent());if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'HYPERV_SQL_PORT_BOOTSTRAP_REQUIRES_ELEVATED_RUNNER'}
    $resolvedMediaRoot=(Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path;Import-Module $modulePath -Force;$module=Get-Module SqlServerLab;$productionStateRoot=&$module{Get-LabStateRoot}
    Write-Host 'SQL-Port-Bootstrap 1/2: isoliertes SQL-2025-Prepared-Artifact erstellen.' -ForegroundColor Cyan
    $prepared=Invoke-BootstrapChildProcess -Arguments @('-NoProfile','-File',$preparedRunner,'-MediaRoot',$resolvedMediaRoot,'-TimeoutSeconds',[string]$TimeoutSeconds,'-SetupTimeoutSeconds',[string]$SetupTimeoutSeconds,'-RetainPreparedArtifact')
    if([int]$prepared.ExitCode -ne 0){throw "HYPERV_SQL_PORT_BOOTSTRAP_PREPARED_FAILED: ExitCode=$($prepared.ExitCode)"}
    $states=@($prepared.Lines|Where-Object{$_ -like 'RETAINED_STATE_ROOT=*'});$artifacts=@($prepared.Lines|Where-Object{$_ -like 'RETAINED_ARTIFACT_ID=*'})
    if($states.Count -ne 1 -or $artifacts.Count -ne 1){throw 'HYPERV_SQL_PORT_BOOTSTRAP_MARKERS_INVALID'}
    $retainedStateRoot=Assert-RetainedStateRootScope -Path ($states[0].Substring('RETAINED_STATE_ROOT='.Length)) -ExpectedParent $productionStateRoot;$retainedArtifactId=$artifacts[0].Substring('RETAINED_ARTIFACT_ID='.Length)
    if($retainedArtifactId -notmatch '^hyperv-sql-prepared-sealed-[a-f0-9]{64}$'){throw 'HYPERV_SQL_PORT_BOOTSTRAP_ARTIFACT_ID_INVALID'}
    Write-Host 'SQL-Port-Bootstrap 2/2: nativen Drift/Plan/WhatIf/Restart-Zyklus ausfuehren.' -ForegroundColor Cyan
    $port=Invoke-BootstrapChildProcess -Arguments @('-NoProfile','-File',$portRunner,'-ArtifactId',$retainedArtifactId,'-StateRoot',$retainedStateRoot,'-KeepOnFailure')
    if([int]$port.ExitCode -ne 0){throw "HYPERV_SQL_PORT_BOOTSTRAP_RECONCILE_FAILED: ExitCode=$($port.ExitCode)"}
}
catch{$testFailed=$true;Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red}
finally{
    if($retainedStateRoot){try{$root=Assert-RetainedStateRootScope -Path $retainedStateRoot -ExpectedParent $productionStateRoot;if($testFailed){throw 'HYPERV_SQL_PORT_BOOTSTRAP_RECOVERY_REQUIRED'};if(-not $retainedArtifactId){throw 'HYPERV_SQL_PORT_BOOTSTRAP_ARTIFACT_ID_REQUIRED_FOR_CLEANUP'};$cleanup=&$module{param($Id,$Root)Remove-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root} $retainedArtifactId $root;if([string]$cleanup.Status -ne 'REMOVED'){throw "HYPERV_SQL_PORT_BOOTSTRAP_ARTIFACT_CLEANUP_INCOMPLETE: $([string]$cleanup.Status)"};$remaining=&$module{param($Id,$Root)Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root -SkipIntegrityCheck} $retainedArtifactId $root;if($remaining){throw 'HYPERV_SQL_PORT_BOOTSTRAP_ARTIFACT_CLEANUP_POSTCONDITION_FAILED'};if(Test-Path $root){Remove-Item -LiteralPath $root -Recurse -Force};if(Test-Path $root){throw 'HYPERV_SQL_PORT_BOOTSTRAP_STATE_CLEANUP_INCOMPLETE'};Write-Host 'PASS: Isoliertes Prepared-Artifact und State Root wurden entfernt.' -ForegroundColor Green}catch{$testFailed=$true;Write-Host "RECOVERY_REQUIRED: $($_.Exception.Message)" -ForegroundColor Red;Write-Host "RETAINED_STATE_ROOT=$retainedStateRoot";if($retainedArtifactId){Write-Host "RETAINED_ARTIFACT_ID=$retainedArtifactId"}}}
}
if($testFailed){exit 1};Write-Host 'Native Hyper-V-SQL-Port-Reconcile-Abnahme mit isoliertem Bootstrap erfolgreich.' -ForegroundColor Green;exit 0
