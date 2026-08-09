function Get-SqlServerLabGeneratedSqlAccess {
    <#
    .SYNOPSIS
        Liefert die generierten SQL-Zugangsdaten eines Hyper-V-Labs.
    .DESCRIPTION
        Entschlüsselt das ausschließlich bei automatischer Generierung im
        run-lokalen Secret Store abgelegte SA-Passwort und erstellt daraus
        einen kopierfertigen Connection-String. Benutzerdefinierte Passwörter
        werden nicht gespeichert und können mit diesem Befehl nicht abgerufen
        werden. Das Passwort bleibt aus Run-State, connection-info.json und
        normalen Statusausgaben entfernt.
    .PARAMETER RunId
        Run-ID des bereitgestellten Hyper-V-SQL-Labs.
    .PARAMETER StateRoot
        Optionaler abweichender State Root.
    .EXAMPLE
        Get-SqlServerLabGeneratedSqlAccess -RunId 01234567-89ab-cdef-0123-456789abcdef
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot
    )

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    if ([string]$lab.Instance.workload -ne 'sql') {
        throw 'HYPERV_LAB_GENERATED_SQL_ACCESS_NOT_APPLICABLE'
    }
    $sqlSaPassword = Get-LabSecret -Path $lab.RunDirectory -Name 'generated-sql-sa-password'
    if (-not $sqlSaPassword) {
        throw 'HYPERV_LAB_GENERATED_SQL_ACCESS_NOT_FOUND: Für diesen Run wurde kein automatisch generiertes SA-Passwort gespeichert.'
    }
    $hostSqlAccess = [PSCustomObject]@{ ConnectionString = [string]$lab.Instance.connectionString }
    return New-HyperVTransientGeneratedSqlAccess -HostSqlAccess $hostSqlAccess `
        -SqlSaPassword $sqlSaPassword -Generated -Persisted
}
