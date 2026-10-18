<#
.SYNOPSIS
    Installiert SQL Server Integration Services gezielt in einen bestehenden eigenen Windows-SQL-2025-Run.
.DESCRIPTION
    Bindet Run und Instanz vor jeder Mutation erneut und installiert ausschließlich das
    vorhandene, hashgebundene Integration-Services-Feature aus einer lokalen SQL-2025-
    Enterprise-ISO. Die Datenbank-Engine wird nicht neu installiert. Es gibt keinen
    Download, Build oder Beschaffungsschritt. Der gesamte Run bleibt der Cleanup-Scope.
    Eine Neuinstallation von IS ist auf SQL 2025 Enterprise Developer begrenzt;
    andere Editionen werden vor Medienanbindung und Setup abgewiesen.
    Setup läuft einmalig unter SYSTEM, unabhängig vom Administratorprofil.
    Die Feature-/Editionsregistrierung wird vor und nach einem geordneten
    Windows-Neustart geprüft. Vorhandene Dateien allein gelten nicht als
    installierte IS-Komponente. Ein vorhandener SSISDB-Katalog bleibt erhalten.
.PARAMETER RunId
    Eindeutige RunId eines laufenden eigenen Hyper-V-Windows-SQL-2025-Runs.
.PARAMETER InstanceId
    Registrierte SQL-Instanz des Runs. Standard ist primary.
.PARAMETER MediaRoot
    Lokaler Medienroot mit der bereits vorhandenen SQL-2025-Enterprise-ISO.
.PARAMETER SqlMediaPath
    Relativer Pfad zur freigegebenen SQL-2025-Enterprise-ISO im Medienroot.
.PARAMETER ExpectedSqlMediaSha256
    Erwarteter SHA-256-Wert der ISO; der Lauf prüft ihn am gehaltenen Dateihandle.
.PARAMETER StateRoot
    Optionaler lokaler StateRoot der gebundenen Lab-Registrierung.
.PARAMETER SetupTimeoutSeconds
    Harte Obergrenze für das gastseitige IS-Setup ohne Engine-Neuinstallation.
.EXAMPLE
    Install-SqlServerLabSsisComponent -RunId $runId -InstanceId primary -MediaRoot $mediaRoot `
      -SqlMediaPath 'SQL/2025/Enterprise/ISO/SQLServer2025-x64-ENU-EntDev.iso' `
      -ExpectedSqlMediaSha256 $sha256
.OUTPUTS
    Geheimnisfreie SqlServerLab.SsisComponent/1.0-Receipt. Entfernen des zugehörigen
    Runs entfernt auch die nachinstallierte Komponente.
#>
function Install-SqlServerLabSsisComponent {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][guid]$RunId,
        [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,63}$')][string]$InstanceId='primary',
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$SqlMediaPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSqlMediaSha256,
        [string]$StateRoot=(Get-LabStateRoot),
        [ValidateRange(300,3600)][int]$SetupTimeoutSeconds=1800
    )
    if(-not $PSCmdlet.ShouldProcess("eigener Hyper-V-Run $RunId/$InstanceId",'nur SQL Integration Services nachinstallieren und VM neu starten')){return}
    Install-LabSsisExistingComponent -RunId $RunId -InstanceId $InstanceId -MediaRoot $MediaRoot -SqlMediaPath $SqlMediaPath `
        -ExpectedSqlMediaSha256 $ExpectedSqlMediaSha256 -StateRoot $StateRoot -SetupTimeoutSeconds $SetupTimeoutSeconds
}
