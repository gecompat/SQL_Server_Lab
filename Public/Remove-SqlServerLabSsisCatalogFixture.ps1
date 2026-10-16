<#
.SYNOPSIS
    Entfernt ausschließlich eine retained SSISDB-Fixture aus einem bestehenden eigenen Run.
.DESCRIPTION
    Liest die run-lokale Receipt, bindet den laufenden Hyper-V-Run vor der Mutation
    erneut und löscht zunächst das nachgewiesene eigene Projekt, danach den leeren
    LabFixture-Katalogordner. Projekt-ID und Version werden geprüft. Zusätzliche
    fremde Projekte oder Umgebungen verhindern die Löschung.
    Der SQL-Run, SSISDB, fremde Katalogordner und globale Katalogeinstellungen bleiben erhalten.
    Versions- und Operationshistorie folgt weiterhin der unveränderten SSIS-Retention.
.PARAMETER RunId
    Eindeutige RunId des laufenden eigenen Hyper-V-SQL-Runs.
.PARAMETER InstanceId
    Registrierte SQL-Instanz des Runs. Standard ist primary.
.PARAMETER StateRoot
    Optionaler lokaler StateRoot.
.OUTPUTS
    Geheimnisfreie Receipt über die gezielte Entfernung des eigenen Katalogordners.
#>
function Remove-SqlServerLabSsisCatalogFixture {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][guid]$RunId,
        [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,63}$')][string]$InstanceId='primary',
        [string]$StateRoot=(Get-LabStateRoot)
    )
    if(-not $PSCmdlet.ShouldProcess("eigene SSISDB-Fixture in $RunId/$InstanceId",'nur nachgewiesenes eigenes Projekt und leeren Katalogordner entfernen')){return}
    Remove-LabSsisExistingCatalogFixture -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
}
