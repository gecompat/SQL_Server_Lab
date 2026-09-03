<#
.SYNOPSIS
    Listet die lokale Hyper-V-Image-Registry als pfadfreie, read-only Auswahl.
.DESCRIPTION
    Liefert veröffentlichte OS- und SQL-Prepared-Images mit ihrem
    Evaluierungs- und Referenzstatus. Die Standardabfrage liest nur die
    Registry-Metadaten; -VerifyIntegrity hasht jede ausgewählte Parent-VHDX
    erneut. Die Ausgabe startet keinen Build, lädt keine Medien nach und
    autorisiert weder Refresh noch Löschung.
.PARAMETER ArtifactId
    Optionale inhaltsadressierte Artifact-ID. Ohne Angabe werden alle
    veröffentlichten Images aufgelistet.
.PARAMETER MinimumEvaluationDaysRemaining
    Restlaufzeit, ab der ein Evaluation-Image als ablaufend gilt.
.PARAMETER VerifyIntegrity
    Prüft den SHA-256-Wert und den Read-only-Status der ausgewählten Parent-VHDX.
.PARAMETER StateRoot
    Optionaler lokaler State-Root.
.OUTPUTS
    PSCustomObject mit stabilen IDs, sanitisierten Metadaten, Evaluierungs- und
    Referenzstatus. Lokale Pfade, Secrets und Source-URLs werden nicht ausgegeben.
.EXAMPLE
    Get-SqlServerLabHyperVImageArtifact

.EXAMPLE
    Get-SqlServerLabHyperVImageArtifact -ArtifactId $artifactId -VerifyIntegrity
#>
function Get-SqlServerLabHyperVImageArtifact {
    [CmdletBinding()]
    param(
        [ValidatePattern('^hyperv-[a-z0-9-]+-[a-f0-9]{64}$')][string]$ArtifactId,
        [ValidateRange(0, 3650)][int]$MinimumEvaluationDaysRemaining = 30,
        [switch]$VerifyIntegrity,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $artifacts = @(Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot -SkipIntegrityCheck:(-not $VerifyIntegrity) | Where-Object { $_ })
    if ($ArtifactId -and $artifacts.Count -ne 1) { throw 'HYPERV_ARTIFACT_NOT_FOUND' }

    $activeRuns = @(Get-LabActiveRuns -StateRoot $StateRoot)
    $windowsBuilds = @(Get-HyperVImageBuildPlans -StateRoot $StateRoot)
    $sqlBuilds = @(Get-HyperVSqlImageBuildPlans -StateRoot $StateRoot)
    $now = [datetime]::UtcNow

    foreach ($artifact in $artifacts) {
        $evaluationExpiresAt = if ($artifact.license.evaluationExpiresAt) {
            ([datetime]$artifact.license.evaluationExpiresAt).ToUniversalTime()
        }
        else { $null }
        $evaluationStatus = if ([string]$artifact.license.type -ne 'evaluation') {
            'NOT_EVALUATION'
        }
        elseif (-not $evaluationExpiresAt) {
            'EVALUATION_EXPIRY_UNKNOWN'
        }
        elseif ($evaluationExpiresAt -le $now) {
            'EVALUATION_EXPIRED'
        }
        elseif (($evaluationExpiresAt - $now).TotalDays -lt $MinimumEvaluationDaysRemaining) {
            'EVALUATION_EXPIRING'
        }
        else { 'EVALUATION_VALID' }
        $refresh = switch ($evaluationStatus) {
            'EVALUATION_EXPIRED' {
                [PSCustomObject]@{
                    Action='MANUAL_REBUILD_REQUIRED'; Reasons=@('evaluation-expired')
                    MutationAllowed=$false; RetainExisting=$true
                }
            }
            'EVALUATION_EXPIRING' {
                [PSCustomObject]@{
                    Action='MANUAL_REBUILD_RECOMMENDED'; Reasons=@('evaluation-expiring')
                    MutationAllowed=$false; RetainExisting=$true
                }
            }
            'EVALUATION_EXPIRY_UNKNOWN' {
                [PSCustomObject]@{
                    Action='EVALUATION_REVIEW_REQUIRED'; Reasons=@('evaluation-expiry-unknown')
                    MutationAllowed=$false; RetainExisting=$true
                }
            }
            default {
                [PSCustomObject]@{
                    Action='NO_ACTION'; Reasons=@(); MutationAllowed=$false; RetainExisting=$true
                }
            }
        }

        $buildReferenceCount = @($windowsBuilds | Where-Object {
            [string]$_.artifact.artifactId -eq [string]$artifact.artifactId
        }).Count + @($sqlBuilds | Where-Object {
            [string]$_.artifact.artifactId -eq [string]$artifact.artifactId -or
            [string]$_.parentArtifact.artifactId -eq [string]$artifact.artifactId
        }).Count
        $runReferenceCount = @($activeRuns | Where-Object {
            [string]$_.metadata.imageArtifactId -eq [string]$artifact.artifactId
        }).Count

        [PSCustomObject]@{
            ContractVersion = 'SqlServerLab.HyperVImageArtifactInventory/1.0'
            ArtifactId = [string]$artifact.artifactId
            ArtifactState = [string]$artifact.artifactState
            DisplayName = [string]$artifact.displayName
            RegisteredAt = [string]$artifact.registeredAt
            IntegrityStatus = if ($VerifyIntegrity) { 'VERIFIED' } else { 'NOT_VERIFIED' }
            OperatingSystem = [PSCustomObject]@{
                Id = [string]$artifact.operatingSystem.id
                Version = [string]$artifact.operatingSystem.version
                Edition = [string]$artifact.operatingSystem.edition
                InstallationType = [string]$artifact.operatingSystem.installationType
                Language = [string]$artifact.operatingSystem.language
                Architecture = [string]$artifact.operatingSystem.architecture
            }
            Sql = [PSCustomObject]@{
                Prepared = [bool]$artifact.sqlPrepared
                Version = [string]$artifact.sql.version
                Edition = [string]$artifact.sql.edition
                Build = [string]$artifact.sql.build
                LicenseType = [string]$artifact.sql.license.type
            }
            Evaluation = [PSCustomObject]@{
                LicenseType = [string]$artifact.license.type
                ExpiresAt = if ($evaluationExpiresAt) { $evaluationExpiresAt.ToString('o') } else { $null }
                Status = $evaluationStatus
                MinimumDaysRemaining = $MinimumEvaluationDaysRemaining
            }
            Refresh = $refresh
            References = [PSCustomObject]@{
                ActiveRuns = $runReferenceCount
                ActiveBuilds = $buildReferenceCount
                Status = if (($runReferenceCount + $buildReferenceCount) -gt 0) { 'IN_USE' } else { 'UNREFERENCED' }
            }
        }
    }
}
