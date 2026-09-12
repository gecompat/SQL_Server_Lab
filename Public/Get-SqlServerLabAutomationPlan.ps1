<#
.SYNOPSIS
    Beschreibt einen versionierten lokalen Automation-API-Plan ohne Ausführung.
.DESCRIPTION
    Projiziert eine kleine, feste Auswahl bestehender öffentlicher Plan-/Action-
    Verträge. Der Befehl liest keinen Lab-State, verbindet keine Runtime und
    schreibt nichts. Er führt keine Action aus und ersetzt weder deren
    Revalidierung noch Locks, Idempotenz, Resume, Autorisierung oder Audit.
    Terraform, Ansible, DSC und Pulumi sind nicht implementiert.
.PARAMETER Action
    Der fachliche Name des bestehenden Planvertrags: Reconcile, Maintenance,
    PersistentStorageRemoval, RunStateUpgrade, PortableLabImport oder
    HyperVRecoveryPoint. Fehlende oder unbekannte Werte liefern einen
    sanitisierten BLOCKED-Vertrag.
.OUTPUTS
    SqlServerLab.AutomationApiPlan/1.0 mit einer nicht ausführbaren Plan- und
    Result-Projektion. PlanId und PlanKey sind für denselben gültigen Action-
    Wert deterministisch.
.EXAMPLE
    Get-SqlServerLabAutomationPlan -Action Reconcile
#>
function Get-SqlServerLabAutomationPlan {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Action)

    return Get-LabAutomationApiPlan -Action $Action
}
