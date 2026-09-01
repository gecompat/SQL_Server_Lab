function Backup-SqlServerLabDatabase {
    <#
    .SYNOPSIS
        Erstellt ein verifiziertes Backup in der Lab_Data-Backup-Bibliothek.
    .DESCRIPTION
        Sichert eine Datenbank providerneutral mit CHECKSUM, prueft das erzeugte
        Medium per RESTORE VERIFYONLY WITH CHECKSUM, hasht den Export und
        veroeffentlicht erst danach ein sanitiertes REUSABLE-Receipt.
    .PARAMETER HostName
        Hostname oder IP-Adresse der SQL-Quelle im direkten Modus.
    .PARAMETER Port
        Host-Port der SQL-Quelle im direkten Modus.
    .PARAMETER SaPassword
        SA-Kennwort als SecureString; es wird nicht in Receipt oder Bibliothek gespeichert.
    .PARAMETER DatabaseName
        Name der vollständig zu sichernden Quelldatenbank.
    .PARAMETER Provider
        Expliziter Quellprovider docker, podman oder hyperv.
    .PARAMETER ContainerName
        Eindeutiger SQL_Server_Lab-Container im direkten Docker-/Podman-Modus.
    .PARAMETER RunId
        Bevorzugte stabile Run-Identitaet des Quellsystems.
    .PARAMETER InstanceId
        Instanz-ID innerhalb des gespeicherten Runs. Standard ist primary.
    .PARAMETER GuestCredential
        Flüchtiges Gast-Administratorcredential für den Hyper-V-Export.
    .PARAMETER DataRoot
        Bereits registrierter Lab_Data-Root fuer Bibliothek und Receipt.
    .PARAMETER StateRoot
        Optionaler State-Root für die Run- und Hyper-V-Auflösung.
    .OUTPUTS
        PSCustomObject mit BackupSetId, Bibliothekspfad, SHA-256, Größe,
        Provider und FILESTREAM-Metadatum.
    .EXAMPLE
        Backup-SqlServerLabDatabase -RunId $lab.RunId -DatabaseName AppDb -SaPassword $pw -DataRoot D:\Lab_Data
    #>
    [CmdletBinding(DefaultParameterSetName='Direct')]
    param(
        [Parameter(ParameterSetName='Direct')][string]$HostName='127.0.0.1',
        [Parameter(ParameterSetName='Direct',Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$DatabaseName,
        [Parameter(ParameterSetName='Direct')][ValidateSet('docker','podman','hyperv')][string]$Provider,
        [Parameter(ParameterSetName='Direct')][string]$ContainerName,
        [Parameter(ParameterSetName='RunBased',Mandatory)][string]$RunId,
        [Parameter(ParameterSetName='RunBased')][string]$InstanceId='primary',
        [PSCredential]$GuestCredential,
        [string]$DataRoot,
        [string]$StateRoot
    )

    if ($PSCmdlet.ParameterSetName -eq 'RunBased') {
        $target = Resolve-LabRunInstance -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $HostName=[string]$target.HostName; $Port=[int]$target.Port; $Provider=[string]$target.Provider
        $ContainerName=[string]$target.ContainerName
    }
    if (-not $DataRoot) { $DataRoot=Get-LabDataRootDefault }
    $DataRoot=Resolve-LabDataRootForUse -DataRoot $DataRoot
    $arguments=@{
        HostName=$HostName; Port=$Port; SaPassword=$SaPassword; DatabaseName=$DatabaseName
        ContainerName=$ContainerName; RunId=$RunId; InstanceId=$InstanceId
        GuestCredential=$GuestCredential; DataRoot=$DataRoot; StateRoot=$StateRoot
    }
    if ($Provider) { $arguments.Provider=$Provider }
    New-LabDatabaseLibraryBackup @arguments
}
