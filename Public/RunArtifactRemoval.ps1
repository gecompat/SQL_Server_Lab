<#
.SYNOPSIS
    Prüft verbliebene Metadaten genau eines entfernten SQL-Lab-Runs.
.DESCRIPTION
    Read-only Vorschau für moderne REMOVED-Runs unter registriertem Lab_Data/State.
    Unvollständiger Cleanup, vorhandene Ressourcen, Retention, Referenzen und
    unbekannte Evidence blockieren. Native Ressourcen und Sicherungen werden
    nicht gelöscht. Ein Recoveryjournal bleibt bis zum erfolgreichen Resume.
.PARAMETER RunId
    Exakte Run-ID. Keine automatische oder globale Auswahl.
.PARAMETER StateRoot
    Registrierter State-Root des Runs.
.PARAMETER DataRoot
    Registrierter Lab_Data-Root desselben Controllers.
.OUTPUTS
    PSCustomObject mit Status, CanApply, PlanKey, FileCount und ReasonCode.
.EXAMPLE
    Get-SqlServerLabRunArtifactRemovalPlan -RunId $runId -StateRoot $stateRoot -DataRoot $dataRoot
#>
function Get-SqlServerLabRunArtifactRemovalPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$RunId,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$DataRoot
    )
    try {
        $context=Get-LabRunArtifactRemovalContext -RunId $RunId -StateRoot $StateRoot -DataRoot $DataRoot
        [pscustomobject]@{RunId=$RunId;Status=$context.Status;CanApply=$context.CanApply;PlanKey=$context.PlanKey;FileCount=$context.FileCount;ReasonCode=$null}
    }
    catch {
        $code=if ($_.Exception.Message -cmatch '^RUN_ARTIFACT_[A-Z_]+$') {$_.Exception.Message} else {'RUN_ARTIFACT_EVIDENCE_UNVERIFIABLE'}
        [pscustomobject]@{RunId=$RunId;Status='BLOCKED';CanApply=$false;PlanKey=$null;FileCount=0;ReasonCode=$code}
    }
}

<#
.SYNOPSIS
    Entfernt geprüfte Metadaten genau eines bereits entfernten SQL-Lab-Runs.
.DESCRIPTION
    Revalidiert die Vorschau vor Mutation. Verschiebt das Runverzeichnis atomar
    in einen eigenen Recovery-Scope und löscht nur bytegebundene Metadaten sowie
    leere gebundene Runverzeichnisse. Teilfehler werden sichtbar journalisiert;
    derselbe Run und PlanKey nehmen den Vorgang wieder auf. Ein kleiner lokaler
    Abschlussreceipt bleibt erhalten. Retention und fremde Ressourcen blockieren.
.PARAMETER RunId
    Exakte Run-ID aus der Vorschau.
.PARAMETER ExpectedPlanKey
    Unveränderter PlanKey einer ausdrücklichen Vorschau.
.PARAMETER StateRoot
    Registrierter State-Root des Runs.
.PARAMETER DataRoot
    Registrierter Lab_Data-Root desselben Controllers.
.OUTPUTS
    PSCustomObject mit RunId, Status und Changed.
.EXAMPLE
    Invoke-SqlServerLabRunArtifactRemoval -RunId $plan.RunId -ExpectedPlanKey $plan.PlanKey -StateRoot $stateRoot -DataRoot $dataRoot
#>
function Invoke-SqlServerLabRunArtifactRemoval {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$RunId,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedPlanKey,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$DataRoot
    )
    if (-not $PSCmdlet.ShouldProcess($RunId,'Geprüfte Run-Artefakte endgültig entfernen')) {
        return [pscustomobject]@{RunId=$RunId;Status='CANCELLED';Changed=$false}
    }
    try { Invoke-LabRunArtifactRemoval -RunId $RunId -ExpectedPlanKey $ExpectedPlanKey -StateRoot $StateRoot -DataRoot $DataRoot }
    catch {
        $code=if ($_.Exception.Message -cmatch '^RUN_ARTIFACT_[A-Z_]+$') {$_.Exception.Message} else {'RUN_ARTIFACT_EVIDENCE_UNVERIFIABLE'}
        throw $code
    }
}
