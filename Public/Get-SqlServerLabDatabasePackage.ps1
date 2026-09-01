<#
.SYNOPSIS
    Listet katalogisierte Datenbankpakete anhand ihrer stabilen ID.
.DESCRIPTION
    Liest den schema-validierten DATABASE_PACKAGE-Katalog und liefert eine
    geheimnis- und pfadfreie Auswahlansicht für CLI und Browser. Ohne
    VerifyIntegrity werden große Paketobjekte nicht bei jeder Inventur erneut
    gehasht. VerifyIntegrity revalidiert die konkrete Auswahl vollständig.

    Die Ausgabe autorisiert keinen Attach. Bis eine Zielinstanz samt sicherer
    Provider- und Pfadabbildung gebunden ist, bleibt AttachStatus auf
    TARGET_BINDING_REQUIRED.
.PARAMETER DatabasePackageId
    Optionale stabile Paket-ID. Ohne Angabe werden alle Einträge aufgelistet.
.PARAMETER DataRoot
    Optionaler registrierter Data Root. Ohne Angabe gilt der konfigurierte
    Standard.
.PARAMETER VerifyIntegrity
    Hasht alle Objekte der ausgewählten Pakete und prüft das Manifest erneut.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Pfadfreie Paket-Auswahl mit
    stabiler DatabasePackageId, Verfügbarkeit, Inhaltsumfang und Attach-Sperre.
.EXAMPLE
    Get-SqlServerLabDatabasePackage
.EXAMPLE
    Get-SqlServerLabDatabasePackage -DatabasePackageId $id -VerifyIntegrity
#>
function Get-SqlServerLabDatabasePackage {
    [CmdletBinding()]
    param(
        [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$DatabasePackageId,
        [string]$DataRoot,
        [switch]$VerifyIntegrity
    )

    if(-not $DataRoot){$DataRoot=Get-LabDataRootDefault}
    if(-not $DataRoot){throw 'DATABASE_PACKAGE_DATA_ROOT_REQUIRED'}
    $items=@(Get-LabDatabasePackageSelection -DataRoot $DataRoot)
    if($DatabasePackageId){
        $items=@($items|Where-Object DatabasePackageId -eq $DatabasePackageId)
        if($items.Count -ne 1){throw 'DATABASE_PACKAGE_NOT_FOUND'}
    }
    foreach($item in $items){
        if($VerifyIntegrity){
            $null=Get-LabDatabasePackage -DatabasePackageId ([string]$item.DatabasePackageId) -DataRoot $DataRoot
            $item.IntegrityValidation='VERIFIED'
        }
        $item
    }
}
