function Save-SqlServerLabResourceSet {
    <#
    .SYNOPSIS
        Stellt katalogisierte Sample- und External-Runtime-Ressourcen vorab bereit.
    .DESCRIPTION
        Nutzt vorhandene verifizierte Caches, importiert optional aus einem
        älteren Media Root oder lädt fehlende Dateien aus den katalogisierten
        HTTP(S)-Quellen. Jede Datei wird vor der atomaren Veröffentlichung mit
        SHA-256 geprüft. Der Befehl installiert weder SQL Server noch Samples.

        Ressourcen ohne Katalog-SHA-256 bleiben fail-closed, bis
        -TrustUnknownArtifact ausdrücklich angegeben wird. Diese Freigabe gilt
        nur für die beim Lauf gehashten Bytes und erzeugt einen lokalen Trust
        Record.
    .PARAMETER ResourceId
        Eine oder mehrere IDs im Format sample:<id>:<variant> oder
        software:<id>:<variant>.
    .PARAMETER MediaRoot
        Ziel-Media-Root. Ohne Angabe gilt die lokale Konfiguration.
    .PARAMETER TestDataRoot
        Ziel der sichtbaren Sample-Bibliothek.
    .PARAMETER SourceMediaRoot
        Optionaler älterer Media Root für einen hashverifizierten lokalen
        Import vor einem Netzwerkdownload.
    .PARAMETER TrustUnknownArtifact
        Erteilt die einmalige lokale Vertrauensfreigabe für Sample-Bytes ohne
        katalogisierte SHA-256. Ohne den Switch lautet der Status TRUST_REQUIRED.
    .PARAMETER StateRoot
        Optionaler lokaler State Root für Trust, Staging und Quarantäne.
    .EXAMPLE
        Save-SqlServerLabResourceSet -ResourceId 'sample:northwind:script' -MediaRoot 'D:\Lab_Base'
    .EXAMPLE
        Save-SqlServerLabResourceSet -ResourceId 'sample:adventureworks-2019:lightweight' -MediaRoot 'D:\Lab1_Base' -SourceMediaRoot 'D:\Lab_Base_Old' -TrustUnknownArtifact
    .EXAMPLE
        Save-SqlServerLabResourceSet -ResourceId 'software:sql-python:sql2022-python-windows-hyperv' -MediaRoot 'D:\Lab_Base' -WhatIf
    .OUTPUTS
        PSCustomObject je Ressourcen-ID mit READY, TRUST_REQUIRED oder PLANNED.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$ResourceId,
        [string]$MediaRoot,
        [string]$TestDataRoot,
        [string]$SourceMediaRoot,
        [switch]$TrustUnknownArtifact,
        [string]$StateRoot
    )

    $roots = Get-LabResourceSetRoots -MediaRoot $MediaRoot -TestDataRoot $TestDataRoot -StateRoot $StateRoot -SourceMediaRoot $SourceMediaRoot
    foreach ($id in @($ResourceId | Select-Object -Unique)) {
        $definition = Get-LabResourceSetDefinition -ResourceId $id
        $plan = Get-SqlServerLabResourcePlan -ResourceId $id -MediaRoot $roots.MediaRoot -TestDataRoot $roots.TestDataRoot `
            -StateRoot $roots.StateRoot -SourceMediaRoot $roots.SourceMediaRoot
        if ($plan.Status -eq 'DRIFT' -or $plan.Acquisition -eq 'SOURCE_INVALID') {
            throw "RESOURCE_SET_INTEGRITY_BLOCKED: $id / $($plan.SourceReason)"
        }
        if ($definition.Kind -eq 'sample' -and $plan.TrustStatus -eq 'TRUST_REQUIRED' -and -not $TrustUnknownArtifact) {
            [PSCustomObject][ordered]@{
                Contract = 'SqlServerLab.ResourceSet/1.0'
                ResourceId = $id
                Status = 'TRUST_REQUIRED'
                Acquisition = 'NONE'
                AlreadyPresent = $false
                ArtifactCount = 1
                Message = 'Für dieses Sample ist -TrustUnknownArtifact oder ein vorhandener lokaler Trust Record erforderlich.'
            }
            continue
        }
        $targetRoot = if ($definition.Kind -eq 'sample') { $roots.TestDataRoot } else { $roots.MediaRoot }
        $targetSafety = Test-LabPathWithinRoot -Root $targetRoot -Path $plan.Target
        if (-not $targetSafety.Valid) { throw "RESOURCE_SET_TARGET_PATH_UNSAFE: $($targetSafety.Reason)" }
        if ($plan.Status -eq 'READY') {
            [PSCustomObject][ordered]@{ Contract='SqlServerLab.ResourceSet/1.0'; ResourceId=$id; Status='READY'; Acquisition='NONE'; AlreadyPresent=$true; ArtifactCount=$plan.ArtifactCount }
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($plan.Target, "$id hashverifiziert bereitstellen")) {
            [PSCustomObject][ordered]@{ Contract='SqlServerLab.ResourceSet/1.0'; ResourceId=$id; Status='PLANNED'; Acquisition=$plan.Acquisition; AlreadyPresent=$false; ArtifactCount=$plan.ArtifactCount }
            continue
        }

        if ($definition.Kind -eq 'sample') {
            $sample = $definition.Sample
            $candidate = Get-LabSampleResourceImportCandidate -Sample $sample -SourceMediaRoot $roots.SourceMediaRoot
            $arguments = @{
                Source=[string]$sample.Source; ArtifactType=[string]$sample.ArtifactType; SampleId=[string]$sample.SampleId
                SampleVariant=[string]$sample.Variant; Category=[string]$sample.Category
                HandlerContractVersion=[string]$sample.HandlerContractVersion; Compatibility=[int]$sample.Compatibility; ExpectedOutputs=@($sample.ExpectedDatabases | ForEach-Object { [PSCustomObject]@{name=$_;kind='database'} })
                StateRoot=$roots.StateRoot; TestDataRoot=$roots.TestDataRoot
            }
            if ($sample.ExpectedSha256) { $arguments.ExpectedSha256 = [string]$sample.ExpectedSha256 }
            if ($TrustUnknownArtifact) { $arguments.TrustUnknownArtifact = $true }
            $result = if ($plan.Acquisition -in @('IMPORT', 'IMPORT_REQUIRES_TRUST') -and $candidate -and $candidate.Status -eq 'AVAILABLE') {
                Import-LabArtifact -SourcePath $candidate.Path @arguments
            }
            else {
                $arguments.TrustPolicy = if ($sample.TrustPolicy) { [string]$sample.TrustPolicy } else { 'interactive-once' }
                if (-not $TrustUnknownArtifact) { $arguments.NonInteractive = $true }
                Resolve-LabArtifact @arguments
            }
            [PSCustomObject][ordered]@{
                Contract='SqlServerLab.ResourceSet/1.0'; ResourceId=$id; Status=[string]$result.Status
                Acquisition=if($result.Status -eq 'TRUST_REQUIRED'){'NONE'}elseif($result.CacheStatus -eq 'IMPORTED'){'IMPORT'}elseif($result.CacheStatus -eq 'HIT'){'CACHE'}else{'DOWNLOAD'}
                AlreadyPresent=$false; ArtifactCount=1; Sha256=$result.Sha256; Resource=$result.Path; Message=$result.Message
            }
            continue
        }

        $softwareStatus = Get-LabSoftwareResourceReadOnlyStatus -SoftwarePlan $definition.SoftwarePlan `
            -MediaRoot $roots.MediaRoot -SourceMediaRoot $roots.SourceMediaRoot
        foreach ($artifact in @($softwareStatus.Artifacts)) {
            $artifactSafety = Test-LabPathWithinRoot -Root $roots.MediaRoot -Path ([string]$artifact.TargetPath)
            if (-not $artifactSafety.Valid) { throw "RESOURCE_SET_TARGET_PATH_UNSAFE: $($artifactSafety.Reason)" }
        }
        if ($roots.SourceMediaRoot) {
            $null = Import-LabExternalRuntimeWindowsMedia -SoftwarePlans @($definition.SoftwarePlan) `
                -MediaRoot $roots.MediaRoot -SourceMediaRoot $roots.SourceMediaRoot
        }
        $artifacts = @(Resolve-LabExternalRuntimeWindowsMedia -SoftwarePlans @($definition.SoftwarePlan) `
            -MediaRoot $roots.MediaRoot -Acquire)
        [PSCustomObject][ordered]@{
            Contract='SqlServerLab.ResourceSet/1.0'; ResourceId=$id; Status='READY'; Acquisition=$plan.Acquisition
            AlreadyPresent=$false; ArtifactCount=$artifacts.Count
            Sha256=$null; Resource=(Join-Path $roots.MediaRoot 'ExternalLanguages/Windows'); Message='Alle katalogisierten Offline-Artefakte sind SHA-256-verifiziert.'
        }
    }
}
