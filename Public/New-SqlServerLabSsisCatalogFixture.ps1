<#
.SYNOPSIS
    Erstellt eine eigene, laufende Windows-SSISDB-Fixture für eine Analysequelle.
.DESCRIPTION
    Erstellt eine SSISDB-Fixture in einem ausdrücklich gebundenen vorhandenen
    Windows-2025-SQL-Run oder in einem neuen eigenen Run aus einem geprüften
    Windows-2025-Artifact. Der vorhandene Run muss SSIS bereits enthalten;
    dieser Cmdlet installiert keine Komponenten in einem fremden oder ungebundenen
    Ziel. Die Fixture enthält genau drei eigene Fälle: Erfolg, Fehler und eine
    erzeugte, nicht gestartete Ausführung. Die Rückgabe enthält keine Credentials,
    Endpunkte oder lokalen Pfade.

    Der Run und sein eindeutig benannter Katalogordner bleiben für einen Consumer
    erhalten. Remove-SqlServerLab entfernt anschließend den gesamten eigenen Run
    und damit auch die Fixture. Dieser Cmdlet lädt keine Medien nach, baut keine
    Drittsoftware und ändert keine fremden SSISDB-Ressourcen.
.PARAMETER ArtifactId
    Geprüftes, lokales Windows-2025-Parent-Artifact.
.PARAMETER MediaRoot
    Lokaler Medienroot mit der bereits vorhandenen SQL-2025-ISO.
.PARAMETER SqlMediaPath
    Relativer Pfad zur freigegebenen SQL-2025-Enterprise-ISO im Medienroot.
.PARAMETER ExpectedSqlMediaSha256
    Erwarteter SHA-256-Wert der ISO; der Lauf prüft ihn am gehaltenen Dateihandle.
.PARAMETER RunId
    Eindeutige RunId eines bereits laufenden eigenen Hyper-V-SQL-2025-Runs.
.PARAMETER InstanceId
    Registrierte SQL-Instanz des vorhandenen Runs. Standard ist primary.
.PARAMETER StateRoot
    Optionaler lokaler StateRoot.
.EXAMPLE
    New-SqlServerLabSsisCatalogFixture -ArtifactId $artifactId -MediaRoot $mediaRoot `
      -SqlMediaPath 'SQL/2025/Enterprise/ISO/SQLServer2025-x64-ENU-EntDev.iso' `
      -ExpectedSqlMediaSha256 $sha256
.OUTPUTS
    Geheimnisfreie `SqlServerLab.SsisCatalogFixture/1.0`-Receipt mit Runbindung,
    eigenen Execution-IDs, beobachteten Katalogviews und Cleanup-Status.
#>
function New-SqlServerLabSsisCatalogFixture {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory,ParameterSetName='NewRun')][ValidatePattern('^hyperv-sql-prepared-sealed-[a-f0-9]{64}$')][string]$ArtifactId,
        [Parameter(Mandatory,ParameterSetName='NewRun')][string]$MediaRoot,
        [Parameter(Mandatory,ParameterSetName='NewRun')][string]$SqlMediaPath,
        [Parameter(Mandatory,ParameterSetName='NewRun')][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSqlMediaSha256,
        [Parameter(Mandatory,ParameterSetName='ExistingRun')][guid]$RunId,
        [Parameter(ParameterSetName='ExistingRun')][ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,63}$')][string]$InstanceId='primary',
        [string]$StateRoot=(Get-LabStateRoot)
    )
    $target=if($PSCmdlet.ParameterSetName -eq 'ExistingRun'){"bestehender eigener Hyper-V-Run $RunId/$InstanceId"}else{'neuer eigener Hyper-V-Windows-Run'}
    if(-not $PSCmdlet.ShouldProcess($target,'SSISDB-Fixture mit drei synthetischen Ausführungen erstellen')){return}
    $fixture=if($PSCmdlet.ParameterSetName -eq 'ExistingRun'){
        Invoke-LabSsisExistingCatalogFixture -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    }else{
        Invoke-LabSsisPreparedFixtureRun -ArtifactId $ArtifactId -MediaRoot $MediaRoot -SqlMediaPath $SqlMediaPath `
            -ExpectedSqlMediaSha256 $ExpectedSqlMediaSha256 -StateRoot $StateRoot
    }
    if($fixture.Status -cne 'SSISDB_FIXTURE_ACCEPTED' -or $fixture.SourceBinding -notin @('OWNED_HYPERV_WINDOWS_RUN','OWNED_EXISTING_HYPERV_RUN','OWNED_PREPARED_HYPERV_RUN')){throw 'SSIS_FIXTURE_RECEIPT_INVALID'}
    [pscustomobject][ordered]@{
        ContractVersion='SqlServerLab.SsisCatalogFixture/1.0'
        Provider='hyperv'
        OperatingSystem='windows'
        Target=[pscustomobject][ordered]@{RunId=[string]$fixture.RunId;InstanceId=[string]$fixture.InstanceId;BindingStatus='BOUND'}
        Source=[pscustomobject][ordered]@{Status='OWNED_READY';ConnectionBinding=[string]$fixture.SourceBinding;ConsumerRights='SYSADMIN_OBSERVED'}
        Fixture=[pscustomobject][ordered]@{Status='READY';ExecutionIds=$fixture.ExecutionIds;ExecutionStatus=$fixture.ExecutionStatus;CatalogViews=@($fixture.CatalogViews);FolderName=[string]$fixture.FolderName;ProjectName=[string]$fixture.ProjectName}
        Sql=[pscustomobject][ordered]@{EngineMajor=[int]$fixture.EngineMajor}
        Ssis=[pscustomobject][ordered]@{Major=[int]$fixture.SsisMajor;Catalog='SSISDB_OBSERVED'}
        Cleanup=$(if([string]$fixture.SourceBinding -eq 'OWNED_EXISTING_HYPERV_RUN'){'REMOVE_OWNED_FIXTURE_TO_CLEANUP'}else{'REMOVE_RUN_TO_CLEANUP'})
        Status='READY_FOR_READ_ONLY_ANALYSIS'
    }
}
