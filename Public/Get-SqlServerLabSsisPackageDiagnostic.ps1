<#
.SYNOPSIS
    Beobachtet Gastkomponenten und LoadFromXML eines eigenen hashgebundenen SSIS-Pakets.
.DESCRIPTION
    Verwendet die geschützte Gastanmeldung und die vorhandene Run-/Instanz-/VM-Bindung.
    Liest genau ein lokales DTSX oder einen exakten DTSX-Eintrag aus einem ISPAC.
    Lädt es in der x64-SSIS-Runtime derselben SQL-Hauptversion ausschließlich im Speicher.
    Kein Deployment, SQL, Execute, Validate, AcquireConnections, Setup oder Einstellungswechsel.
    Komponenten laden ihren eigenen Deserialisierungscode: dies ist keine Sandbox.
    Nur eigene vertrauenswürdige synthetische Labpakete verwenden. Rohe Meldungstexte,
    Paketinhalt, Pfade und Credentials werden nicht ausgegeben oder gespeichert.
.PARAMETER RunId
    Bereits laufender eigener Hyper-V-/Windows-/SQL-2019-, -2022- oder -2025-Run.
.PARAMETER InstanceId
    Registrierte SQL-Instanz, standardmäßig primary.
.PARAMETER StateRoot
    Bereits konfigurierter lokaler StateRoot.
.PARAMETER IspacPath
    Absoluter lokaler ISPAC-Pfad ohne Reparse Points, maximal 16 MiB und 256 Einträge.
.PARAMETER PackageName
    Exakter DTSX-Eintrag im ISPAC-Root; keine Verzeichnisse oder Wildcards, maximal 8 MiB.
.PARAMETER PackagePath
    Alternativ ein absolutes lokales DTSX, maximal 8 MiB.
.PARAMETER ExpectedSha256
    Erwarteter SHA-256 des gesamten ISPAC beziehungsweise DTSX aus dem eigenen Receipt.
.PARAMETER TimeoutSeconds
    Harte Frist des einmaligen Gasttransports, 10 bis 120 Sekunden, standardmäßig 60.
.EXAMPLE
    Get-SqlServerLabSsisPackageDiagnostic -RunId $runId -IspacPath $ownIspacPath -PackageName ExampleBasicSuccess.dtsx -ExpectedSha256 $receipt.Sha256
.OUTPUTS
    SqlServerLab.SsisPackageDiagnostic/1.0 mit Hashes, Runtime, Bitness, Komponenten und Fehlercodes.
    OBSERVED belegt nur fehlerfreies Laden, keine ausführbare oder fachlich akzeptierte Pipeline.
#>
function Get-SqlServerLabSsisPackageDiagnostic {
    [CmdletBinding(DefaultParameterSetName='Ispac')]
    param(
        [Parameter(Mandatory)][guid]$RunId,
        [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,63}$')][string]$InstanceId='primary',
        [string]$StateRoot=(Get-LabStateRoot),
        [Parameter(Mandatory,ParameterSetName='Ispac')][string]$IspacPath,
        [Parameter(Mandatory,ParameterSetName='Ispac')][ValidatePattern('^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\.dtsx$')][string]$PackageName,
        [Parameter(Mandatory,ParameterSetName='Package')][string]$PackagePath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256,
        [ValidateRange(10,120)][int]$TimeoutSeconds=60
    )
    if (-not (Test-LabSsisWindowsHost)) { throw 'SSIS_DIAGNOSTIC_WINDOWS_HOST_REQUIRED' }
    if ($RunId -eq [guid]::Empty) { throw 'SSIS_DIAGNOSTIC_RUN_INVALID' }
    $ispac=$PSCmdlet.ParameterSetName -ceq 'Ispac'
    $path=if($ispac){$IspacPath}else{$PackagePath}
    $artifact=Read-LabSsisDiagnosticPackage -Path $path -ExpectedSha256 $ExpectedSha256 -PackageName $PackageName -Ispac:$ispac
    Invoke-LabSsisPackageDiagnostic -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot -Artifact $artifact -TimeoutSeconds $TimeoutSeconds
}
