#Requires -Version 7.2
<# .SYNOPSIS Interne IS-only-Abnahme auf einem frischen eigenen Windows-2025-Slot. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ArtifactId,[Parameter(Mandatory)][string]$MediaRoot,
    [Parameter(Mandatory)][string]$SqlMediaPath,[Parameter(Mandatory)][string]$ExpectedSqlMediaSha256,
    [Parameter(Mandatory)][string]$StateRoot)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$root=& $module {param($Root) Assert-LabDiagnosticPath -Path $Root} $StateRoot
& $module {param($Root,$Repository) Assert-LabSsisEvidenceLocation -StateRoot $Root -RepositoryRoot $Repository} $root $repoRoot
$evidence=Join-Path $root ('ssis-install-evidence-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $evidence -ErrorAction Stop
$log=Join-Path $evidence 'local.log'
$capture=@{Result=$null};$parameters=$PSBoundParameters
try {
    & { $capture.Result=& $module {param($Parameters) Invoke-LabSsisOwnedInstall @Parameters} $parameters } *> $log
} catch {
    throw (& $module {param($Failure,$Path) New-LabSsisLocalFailure -Failure $Failure -LogPath $Path} $_ $log)
}
$capture.Result
