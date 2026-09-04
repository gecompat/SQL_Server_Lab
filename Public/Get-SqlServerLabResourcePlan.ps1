function Get-SqlServerLabResourcePlan {
    <#
    .SYNOPSIS
        Plant katalogisierte Downloads und lokale Bestandsimporte read-only.
    .DESCRIPTION
        Prüft Sample-Artefakte und Windows-/Hyper-V-External-Runtime-Medien
        gegen Katalog, SHA-256, lokalen Cache und optional einen älteren Media
        Root. Der Befehl verändert weder Dateien noch Trust Store.
    .PARAMETER ResourceId
        Eine oder mehrere IDs im Format sample:<id>:<variant> oder
        software:<id>:<variant>. Ohne Angabe werden alle unterstützten
        Ressourcen geplant.
    .PARAMETER MediaRoot
        Ziel-Media-Root. Ohne Angabe gilt die lokale Konfiguration.
    .PARAMETER TestDataRoot
        Ziel der sichtbaren Sample-Bibliothek. Ohne Angabe gilt die lokale
        Konfiguration beziehungsweise <MediaRoot>\Testdaten.
    .PARAMETER SourceMediaRoot
        Optionaler älterer Media Root. Nur exakt kataloggebundene und beim
        Apply erneut gehashte Dateien werden als Importkandidaten angeboten.
    .PARAMETER StateRoot
        Optionaler lokaler State Root für die read-only Trust-Statusprüfung.
    .EXAMPLE
        Get-SqlServerLabResourcePlan -ResourceId 'sample:northwind:script' -MediaRoot 'D:\Lab_Base'
    .EXAMPLE
        Get-SqlServerLabResourcePlan -MediaRoot 'D:\Lab1_Base' -SourceMediaRoot 'D:\Lab_Base_Old'
    .OUTPUTS
        PSCustomObject je Ressourcen-ID mit Ziel-, Trust- und Acquisition-Status.
    #>
    [CmdletBinding()]
    param(
        [string[]]$ResourceId,
        [string]$MediaRoot,
        [string]$TestDataRoot,
        [string]$SourceMediaRoot,
        [string]$StateRoot
    )

    $roots = Get-LabResourceSetRoots -MediaRoot $MediaRoot -TestDataRoot $TestDataRoot -StateRoot $StateRoot -SourceMediaRoot $SourceMediaRoot
    $ids = if (@($ResourceId).Count -gt 0) { @($ResourceId | Select-Object -Unique) } else { @(Get-LabResourceSetDefaultId) }
    foreach ($id in $ids) {
        $definition = Get-LabResourceSetDefinition -ResourceId $id
        if ($definition.Kind -eq 'sample') {
            $target = Get-LabSampleResourceReadOnlyStatus -Sample $definition.Sample -TestDataRoot $roots.TestDataRoot -StateRoot $roots.StateRoot
            $candidate = Get-LabSampleResourceImportCandidate -Sample $definition.Sample -SourceMediaRoot $roots.SourceMediaRoot
            $acquisition = if ($target.Status -eq 'READY') { 'NONE' }
                elseif ($target.CacheStatus -eq 'READY') { 'PUBLISH_FROM_CACHE' }
                elseif ($candidate -and $candidate.Status -eq 'AVAILABLE' -and
                    -not $definition.Sample.ExpectedSha256 -and $target.TrustStatus -eq 'TRUST_REQUIRED') { 'IMPORT_REQUIRES_TRUST' }
                elseif ($candidate -and $candidate.Status -eq 'AVAILABLE') { 'IMPORT' }
                elseif ($candidate -and $candidate.Status -eq 'INVALID') { 'SOURCE_INVALID' }
                elseif (-not $definition.Sample.ExpectedSha256 -and $target.TrustStatus -eq 'TRUST_REQUIRED') { 'TRUST_REQUIRED' }
                else { 'DOWNLOAD' }
            [PSCustomObject][ordered]@{
                Contract='SqlServerLab.ResourcePlan/1.0'; ResourceId=$id; Kind='sample'; Status=$target.Status
                Acquisition=$acquisition; ArtifactCount=1; ReadyCount=if($target.Status -eq 'READY'){1}else{0}
                TrustStatus=$target.TrustStatus; ExpectedSha256=$target.KnownSha256
                DownloadSizeMB=$definition.Sample.DownloadSizeMB; Target=$target.LibraryDirectory
                SourceCandidate=if($candidate){$candidate.Path}else{$null}; SourceStatus=if($candidate){$candidate.Status}else{'NOT_CONFIGURED'}
                SourceReason=if($candidate -and $candidate.PSObject.Properties['Reason']){$candidate.Reason}else{$null}
            }
            continue
        }

        $target = Get-LabSoftwareResourceReadOnlyStatus -SoftwarePlan $definition.SoftwarePlan -MediaRoot $roots.MediaRoot -SourceMediaRoot $roots.SourceMediaRoot
        $acquisition = if ($target.Status -eq 'READY') { 'NONE' }
            elseif ($target.ImportAvailableCount -eq ($target.ArtifactCount - $target.ReadyCount)) { 'IMPORT' }
            elseif ($target.ImportAvailableCount -gt 0) { 'IMPORT_AND_DOWNLOAD' }
            else { 'DOWNLOAD' }
        [PSCustomObject][ordered]@{
            Contract='SqlServerLab.ResourcePlan/1.0'; ResourceId=$id; Kind='software'; Status=$target.Status
            Acquisition=$acquisition; ArtifactCount=$target.ArtifactCount; ReadyCount=$target.ReadyCount
            TrustStatus='catalog-verified'; ExpectedSha256=$null; DownloadSizeMB=$null
            Target=(Join-Path $roots.MediaRoot 'ExternalLanguages/Windows'); SourceCandidate=$roots.SourceMediaRoot
            SourceStatus=if($target.ImportAvailableCount -gt 0){'AVAILABLE'}else{'NOT_AVAILABLE'}; SourceReason=$null
        }
    }
}
