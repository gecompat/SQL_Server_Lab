<#
.SYNOPSIS
    Inventarisiert Datenbank-Migrationsabhaengigkeiten read-only.
.DESCRIPTION
    Bindet eine direkte SQL-Verbindung oder eine gespeicherte Run-/Instanz-ID
    an den schema-validierten PSR-010-Core. Das Ergebnis enthaelt nur
    Kategorien, Counts und sanitisierte Migrationsgrenzen. Host, Port,
    Zugangsdaten, Objekt- und Schluesselnamen werden nicht persistiert oder in
    das Ergebnis uebernommen.

    Die Inventur exportiert oder veraendert keine Serverobjekte, Datenbanken,
    TDE-Schluessel oder externen Services. Nicht SQL-seitig beweisbare Bereiche
    bleiben sichtbar NOT_OBSERVABLE.
.PARAMETER HostName
    Hostname oder IP-Adresse der SQL-Quelle im direkten Modus.
.PARAMETER Port
    SQL-Port der Quelle im direkten Modus.
.PARAMETER Provider
    Providerklassifikation der direkten Quelle.
.PARAMETER RunId
    Bevorzugte stabile Run-Identitaet der SQL-Quelle.
.PARAMETER InstanceId
    Instanz-ID innerhalb des gespeicherten Runs. Standard ist primary.
.PARAMETER SaPassword
    SA-Kennwort als fluechtiges SecureString. Es wird nicht in das Ergebnis
    uebernommen oder gespeichert.
.PARAMETER DatabaseName
    Zu inventarisierende Datenbank.
.PARAMETER TdeRecoveryEvidenceVerified
    Bestaetigt ausschließlich, dass eine getrennte TDE-Recovery-Evidence
    bereits verifiziert wurde. Das Cmdlet uebertraegt kein Keymaterial.
.PARAMETER StateRoot
    Optionaler State-Root fuer die Run-Aufloesung.
.OUTPUTS
    SqlServerLab.DatabaseMigrationDependencyInventory/1.0 mit sanitisierter
    Source-Bindung, Abhaengigkeitskategorien, Counts und Migrationsgrenzen.
.EXAMPLE
    Get-SqlServerLabDatabaseMigrationDependency -RunId $runId `
        -DatabaseName AppDb -SaPassword $password
.EXAMPLE
    Get-SqlServerLabDatabaseMigrationDependency -HostName 127.0.0.1 `
        -Port 1433 -Provider external -DatabaseName AppDb -SaPassword $password
#>
function Get-SqlServerLabDatabaseMigrationDependency {
    [CmdletBinding(DefaultParameterSetName='RunBased')]
    param(
        [Parameter(ParameterSetName='Direct')][string]$HostName='127.0.0.1',
        [Parameter(ParameterSetName='Direct',Mandatory)][ValidateRange(1,65535)][int]$Port,
        [Parameter(ParameterSetName='Direct',Mandatory)]
        [ValidateSet('docker','podman','hyperv','external')][string]$Provider,
        [Parameter(ParameterSetName='RunBased',Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$RunId,
        [Parameter(ParameterSetName='RunBased')][string]$InstanceId='primary',
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$DatabaseName,
        [switch]$TdeRecoveryEvidenceVerified,
        [string]$StateRoot
    )

    if($PSCmdlet.ParameterSetName -eq 'RunBased'){
        $target=Resolve-LabRunInstance -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $HostName=[string]$target.HostName
        $Port=[int]$target.Port
        $Provider=[string]$target.Provider
    }

    Get-LabDatabaseMigrationDependencyInventory -HostName $HostName -Port $Port `
        -SaPassword $SaPassword -DatabaseName $DatabaseName -Provider $Provider `
        -RunId $RunId -InstanceId $InstanceId `
        -TdeRecoveryEvidenceVerified ([bool]$TdeRecoveryEvidenceVerified)
}
