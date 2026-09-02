function New-LabPublicDatabasePackageAttachResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('BLOCKED', 'PLANNED', 'ATTACHED')][string]$Status,
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [bool]$TargetCopyVerified = $false,
        [bool]$AttachInvoked = $false,
        [bool]$PostconditionVerified = $false,
        [string[]]$Blockers = @()
    )

    $result = [PSCustomObject][ordered]@{
        ContractVersion = 'SqlServerLab.DatabasePackageAttachResult/1.0'
        Status = $Status
        DatabasePackageId = [string]$Package.Record.DatabasePackageId
        DatabaseName = [string]$Package.Record.DatabaseName
        TargetRunId = $RunId
        TargetInstanceId = $InstanceId
        Provider = 'hyperv'
        TargetBinding = 'RUN_SQL_DEFAULT_DATA'
        TargetSqlMajorVersion = [int]$Context.TargetEvidence.SqlMajorVersion
        TargetFileStreamCapable = [bool]$Context.TargetEvidence.FileStreamEnabled
        IntegrityValidation = 'VERIFIED'
        Mode = 'COPY_THEN_ATTACH'
        TargetCopyVerified = $TargetCopyVerified
        AttachInvoked = $AttachInvoked
        PostconditionVerified = $PostconditionVerified
        MigrationBoundary = $Plan.MigrationBoundary
        Blockers = @($Blockers | Sort-Object -Unique)
        Recovery = if ($Status -eq 'ATTACHED') { 'NOT_REQUIRED' } else { 'NOT_STARTED' }
        CompletedAt = Get-LabTimestamp
    }
    try {
        $valid = $result | ConvertTo-Json -Depth 40 |
            Test-Json -SchemaFile (Join-Path $script:SchemasPath 'database-package-attach-result.schema.json') -ErrorAction Stop
    }
    catch {
        throw "DATABASE_PACKAGE_ATTACH_RESULT_SCHEMA_INVALID: $($_.Exception.Message)"
    }
    if (-not $valid) { throw 'DATABASE_PACKAGE_ATTACH_RESULT_SCHEMA_INVALID' }
    return $result
}

function Invoke-SqlServerLabDatabasePackageAttach {
    <#
    .SYNOPSIS
        Attached ein unveraenderliches Datenbankpaket an einen Hyper-V-Lab-Run.
    .DESCRIPTION
        Waehlt das Paket ausschliesslich per stabiler DatabasePackageId und das
        Ziel per RunId/InstanceId. Der Zielpfad wird nicht als Parameter
        akzeptiert, sondern live aus dem von SQL Server gemeldeten
        Default-Data-Verzeichnis des scopegebundenen Hyper-V-Gasts abgeleitet.

        Vor jeder Mutation werden Paketinhalt, VM-Eigentum, SQL-Version,
        FILESTREAM-Capability, Datenbankname und leeres Ziel erneut geprueft.
        Anschliessend wird eine unabhaengige Kopie im Gast erzeugt, dort per
        SHA-256 verifiziert und erst danach attached. Paketobjekte bleiben
        unveraendert. TDE-Pakete bleiben ohne eigenen Ziel-Key-Vertrag
        fail-closed.
    .PARAMETER DatabasePackageId
        Stabile ID des katalogisierten, wiederverwendbaren Datenbankpakets.
    .PARAMETER RunId
        Stabile ID des laufenden Hyper-V-Ziel-Runs.
    .PARAMETER InstanceId
        Instanz-ID innerhalb des Ziel-Runs. Standard ist primary.
    .PARAMETER GuestCredential
        Fluechtiges lokales Administratorcredential fuer PowerShell Direct.
        Es wird weder im Journal noch im Rueckgabeobjekt gespeichert.
    .PARAMETER DataRoot
        Registrierter Lab_Data-Root der Datenbankpaketbibliothek. Ohne Angabe
        wird der konfigurierte Standard verwendet.
    .PARAMETER StateRoot
        Optionaler State-Root fuer die Run-Aufloesung.
    .OUTPUTS
        SqlServerLab.DatabasePackageAttachResult/1.0. Das Ergebnis enthaelt
        stabile IDs, Capability- und Postcondition-Status, aber keine Host- oder
        Gastpfade, Hashes oder Credentials.
    .EXAMPLE
        Invoke-SqlServerLabDatabasePackageAttach -DatabasePackageId $packageId -RunId $lab.RunId -GuestCredential $credential -WhatIf

        Verifiziert Paket und Zielbindung und liefert den mutationsfreien Plan.
    .EXAMPLE
        Invoke-SqlServerLabDatabasePackageAttach -DatabasePackageId $packageId -RunId $lab.RunId -GuestCredential $credential -Confirm:$false

        Kopiert das Paket in das gebundene SQL-Default-Data-Verzeichnis des
        Hyper-V-Gasts, verifiziert die Kopie und attached die Datenbank.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$DatabasePackageId,
        [Parameter(Mandatory)][string]$RunId,
        [string]$InstanceId = 'primary',
        [Parameter(Mandatory)][PSCredential]$GuestCredential,
        [string]$DataRoot,
        [string]$StateRoot
    )

    if (-not $DataRoot) { $DataRoot = Get-LabDataRootDefault }
    if (-not $DataRoot) { throw 'DATABASE_PACKAGE_DATA_ROOT_REQUIRED' }
    $DataRoot = Resolve-LabDataRootForUse -DataRoot $DataRoot

    # Get-LabDatabasePackage performs the expensive full hash validation only
    # for the concrete package selected for use.
    $package = Get-LabDatabasePackage -DatabasePackageId $DatabasePackageId -DataRoot $DataRoot
    $context = Get-LabHyperVDatabasePackageAttachContext -Package $package -RunId $RunId `
        -InstanceId $InstanceId -Credential $GuestCredential -StateRoot $StateRoot
    $plan = Get-LabDatabasePackageAttachPlan -Package $package `
        -TargetEvidence $context.TargetEvidence -TargetDirectory ([string]$context.TargetDirectory)

    if ([string]$plan.Status -ne 'READY') {
        return New-LabPublicDatabasePackageAttachResult -Status BLOCKED -Package $package -Plan $plan `
            -Context $context -RunId $RunId -InstanceId $InstanceId -Blockers @($plan.Blockers)
    }
    if (-not $PSCmdlet.ShouldProcess(
            "$RunId/$InstanceId",
            "Copy and attach database package $DatabasePackageId")) {
        return New-LabPublicDatabasePackageAttachResult -Status PLANNED -Package $package -Plan $plan `
            -Context $context -RunId $RunId -InstanceId $InstanceId
    }

    $attached = Invoke-LabHyperVDatabasePackageAttachPlan -Plan $plan -Package $package `
        -Context $context -Credential $GuestCredential -Confirm:$false -WhatIf:$false
    $journal = Get-Content -LiteralPath ([string]$attached.JournalPath) -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    $null = Test-LabDatabasePackageAttachJournal -Journal $journal
    return New-LabPublicDatabasePackageAttachResult -Status ATTACHED -Package $package -Plan $plan `
        -Context $context -RunId $RunId -InstanceId $InstanceId `
        -TargetCopyVerified ([bool]$journal.TargetCopyVerified) `
        -AttachInvoked ([bool]$journal.AttachInvoked) `
        -PostconditionVerified ([bool]$journal.PostconditionVerified)
}
