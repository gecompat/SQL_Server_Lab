<#
.SYNOPSIS
    Erfasst die beobachtete Edition eines laufenden SQL-2025-Hyper-V-Gastes.
.DESCRIPTION
    Liest genau eine gebundene Instanz mit verwalteten Gast-/SQL-Credentials.
    Ersetzt ausschließlich den runlokalen Evidence-Receipt atomar. Bekannte
    Evaluation- und Developer-Editionen erhalten NO_DEADLINE ohne erfundene
    Ablaufzeit. Eine frische Developer-Evidence ergibt im EvaluationWatch
    NOT_APPLICABLE. Fehler bewahren den vorherigen Receipt. Keine VM-, SQL-,
    Lizenz-, Netzwerk- oder Connection-State-Änderung. Die Gültigkeit beträgt
    24 Stunden; positive Evaluation-/Deadline-Native-Evidence bleibt getrennt.
.PARAMETER RunId
    ID eines laufenden eigenen Hyper-V-Runs mit genau einer SQL-2025-Instanz.
.PARAMETER StateRoot
    Vorhandener lokaler State-Root. Root und Pfade dürfen keine Reparse Points enthalten.
.PARAMETER TimeoutSeconds
    Maximale Gasttransport-Wartezeit in Sekunden, Standard 90. SQL-Verbindungen
    und Abfragen besitzen zusätzlich begrenzte Timeouts.
.OUTPUTS
    Sanitisierter Status UPDATED mit Run-/Instanz-/Evidence-IDs, Lizenzklasse
    und Gültigkeit. Keine VM-Namen, Endpunkte, Pfade oder Secrets.
.EXAMPLE
    Update-SqlServerLabSqlGuestEvaluationEvidence -RunId $run.RunId -WhatIf
.EXAMPLE
    Update-SqlServerLabSqlGuestEvaluationEvidence -RunId $run.RunId -StateRoot $stateRoot
#>
function Update-SqlServerLabSqlGuestEvaluationEvidence {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][guid]$RunId,[string]$StateRoot,[ValidateRange(30,300)][int]$TimeoutSeconds=90)
    if($RunId -eq [guid]::Empty){throw 'SQL_GUEST_CAPTURE_RUN_ID_INVALID'}
    if(-not $PSCmdlet.ShouldProcess($RunId.ToString(),'SQL-Edition im gebundenen Gast lesen und lokalen Evidence-Receipt ersetzen')){return}
    try {
        if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
        Invoke-LabSqlGuestEvaluationCapture -RunId $RunId -StateRoot $StateRoot -TimeoutSeconds $TimeoutSeconds
    }
    catch {
        $code=[string]$_.Exception.Message
        if($code -notmatch '^SQL_GUEST_CAPTURE_(PATH_INVALID|BINDING_INVALID|IMAGE_INVALID|LOCKED|BINDING_CHANGED|PRIOR_INVALID|EDITION_UNSUPPORTED|CREDENTIAL_REQUIRED|PROBE_INVALID|PROBE_FAILED|SQL_IDENTITY_CHANGED|RECEIPT_INVALID)$'){$code='SQL_GUEST_CAPTURE_FAILED'}
        throw $code
    }
}
