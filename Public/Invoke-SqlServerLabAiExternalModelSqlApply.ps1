<#
.SYNOPSIS
    Erstellt ein geplantes SQL External Model in einem eigenen SQL-2025-Run.
.DESCRIPTION
    Bindet einen unveränderten SQL-Plan an dessen frisches Preflight-Receipt,
    journalisiert vor der ersten Mutation und erstellt transaktional zuerst den
    SQL-seitigen Ownership-Receipt, danach Credential und External Model.
    Ein unbekannter Ausgang wird niemals blind wiederholt. Mit Resume wird der
    gebundene SQL-Zustand geprüft; Teilzustände bleiben als Recoverybedarf stehen.
.PARAMETER SqlPlan
    Ergebnis von Get-SqlServerLabAiExternalModelSqlPlan.
.PARAMETER PreflightReceipt
    Passendes Ergebnis von Test-SqlServerLabAiExternalModelSqlPreflight.
.PARAMETER RunId
    Eigener SQL-2025-Docker-, Podman- oder Hyper-V-Run. Hyper-V-Receipts und
    Journal binden zusätzlich die VMId.
.PARAMETER InstanceId
    SQL-Instanz, standardmäßig primary.
.PARAMETER CredentialSecret
    Geheimnis für das Database Scoped Credential als SecureString.
.PARAMETER StateRoot
    Optionaler lokaler Run-State.
.PARAMETER Resume
    Prüft einen zuvor journalisierten unbekannten Ausgang. Ein abgelaufener
    Nachweis darf dabei nur eine bereits vollständige SQL-Postcondition bestätigen.
.OUTPUTS
    Sanitisiertes SqlServerLab.AiExternalModelSqlApplyReceipt/1.0.
#>
function Invoke-SqlServerLabAiExternalModelSqlApply {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)]$SqlPlan,
        [Parameter(Mandatory)]$PreflightReceipt,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$RunId,
        [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,63}$')][string]$InstanceId='primary',
        [Parameter(Mandatory)][Security.SecureString]$CredentialSecret,
        [string]$StateRoot,
        [switch]$Resume
    )
    if($PSCmdlet.ShouldProcess("Run $RunId / Instanz $InstanceId / Datenbank $($SqlPlan.DatabaseName)",'SQL Ownership-Receipt, Database Scoped Credential und External Model erstellen')){
        $arguments=@{SqlPlan=$SqlPlan;PreflightReceipt=$PreflightReceipt;RunId=$RunId;InstanceId=$InstanceId;CredentialSecret=$CredentialSecret;Resume=$Resume}
        if($PSBoundParameters.ContainsKey('StateRoot')){$arguments.StateRoot=$StateRoot}
        Invoke-LabAiExternalModelSqlApply @arguments
    }
}
