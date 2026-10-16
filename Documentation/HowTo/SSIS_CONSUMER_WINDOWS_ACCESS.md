# Eigene SSIS-Katalogoperationen mit Windows-Authentifizierung

Lab stellt Umgebung und Zugang bereit. SQL_Server_Analyze verantwortet seine
eigenen ISPACs, fachlichen Testfaelle, Referenzabfragen, Objektidentitaeten und
deren Cleanup. Die vorhandenen Lab-Ausfuehrungen werden dabei nur gelesen.

## Ein vorhandener Zugangsweg

`Invoke-SqlServerLabScript -WindowsAuthentication` erweitert den bestehenden
Skriptbefehl. Er verwendet denselben `Invoke-HyperVPowerShellDirect`-Transport,
denselben Run-/Instanz-/VM-Binder und denselben geschuetzten Gast-Secretstore
wie die vorhandenen SSIS-Operationen. Es gibt keinen weiteren Remote-Endpunkt,
Dienst oder Kennwortexport. SQL verbindet sich **im Gast** mit Windows-
Authentifizierung zur gespeicherten Port-/Instanzbindung. Die aktuelle
Windows-Identitaet des Hostclients wird nicht als SQL-Login weitergereicht.

Voraussetzungen: PowerShell 7.2 auf dem Hyper-V-Host, ein laufender eigener
Windows-SQL-Run und ein Operatorprozess mit den vorhandenen Hyper-V-/
PowerShell-Direct-Rechten, der dessen DPAPI-geschuetzte Gastanmeldung lesen kann.
Fehlende Anmeldung oder Rechte
ergeben keinen SQL-Auth-Fallback. Der administrative Gastzugang ist keine
Sandbox fuer fremde oder ungepruefte SQL-Skripte. Diese Freigabe ist auf eigene
synthetische Consumerobjekte in der bezeichneten Labinstanz zu begrenzen.

`Get-SqlServerLabGeneratedWindowsAccess` bleibt auf generierte Kennwoerter
beschraenkt. `Get-SqlServerLabGeneratedSqlAccess` eignet sich weiterhin fuer
den vorhandenen lesenden Analyzezugang; sein SA-Login ersetzt diese
Windows-Authentifizierung fuer Katalogoperationen nicht.

## Aufruf aus Analyze

Alle folgenden Variablen stammen aus dem lokalen Consumerworkflow. Skripte und
Ownership-Receipts gehoeren in einen geschuetzten, nicht versionierten eigenen
Arbeitsbereich. Sie enthalten keine Kennwoerter. `$stateRoot` ist der bereits
konfigurierte Lab-StateRoot; `$labModulePath` bezeichnet das Modul des
freigegebenen Labstands. Beide stammen aus der vorhandenen lokalen Integration.

```powershell
Import-Module $labModulePath -Force
$runId = '53fbfd35-08bc-439a-baa1-680f13eb471e'
$target = @{
    RunId = $runId
    InstanceId = 'primary'
    StateRoot = $stateRoot
    WindowsAuthentication = $true
    Database = 'SSISDB'
    KeepConnection = $true
    TimeoutSeconds = 300
}

# Reine Verbindungspruefung; Ergebnis ausschließlich lokal auswerten.
[IO.File]::WriteAllText($probeSqlPath, 'SELECT 1 AS Connected;')
$probe = Invoke-SqlServerLabScript @target -ScriptPath $probeSqlPath
if (-not $probe.Success -or $probe.Authentication -ne 'Windows' -or
    $probe.AuthScheme -notin @('NTLM','KERBEROS')) { throw 'Windows-Zugang fehlt.' }
```

Der Befehl verifiziert SQL-Version, SQL-Instanz und Windows-Authscheme vor
jedem neu geoeffneten SQL-Kanal. `-KeepConnection` behaelt eine Verbindung fuer
alle `GO`-Batches; ohne den Schalter wird jeder Batch neu verbunden und geprueft.
T-SQL-Variablen bleiben auch auf derselben Verbindung auf ihren Batch begrenzt.
`WhatIf` fuehrt kein SQL aus und liest keine Gastcredentials.

## Eigenen Ordner anlegen und Identitaet festhalten

Vor dem ersten Schreibaufruf einen eindeutigen Consumer-Operationstoken und
den vorgesehenen Ordnernamen lokal quittieren. Nach bestaetigter Anlage die
zurueckgegebene `FolderId` in derselben Ownership-Receipt ergaenzen.

Inhalt von `$createSqlPath`:

```sql
IF EXISTS(SELECT 1 FROM catalog.folders WHERE name=@folder)
    THROW 51000,'CONSUMER_FOLDER_ALREADY_EXISTS',1;
DECLARE @id bigint;
EXEC catalog.create_folder @folder_name=@folder,@folder_id=@id OUTPUT;
SELECT @id AS FolderId;
```

```powershell
$folderName = 'Analyze_' + [guid]::NewGuid().ToString('N')
$created = Invoke-SqlServerLabScript @target -ScriptPath $createSqlPath `
    -Parameters @{ folder = $folderName }
if (-not $created.Success) { throw 'Anlage unbestaetigt; eigenen Zustand pruefen.' }
$folderId = [long]$created.ResultSets[0].Rows[0][0]
```

## Eigenes ISPAC bereitstellen und ausfuehren

Analyze erzeugt das ISPAC selbst. `$projectName` muss dessen internem
Projektnamen entsprechen. Inhalt von `$deploySqlPath`:

```sql
IF NOT EXISTS(SELECT 1 FROM catalog.folders WHERE folder_id=@folderId AND name=@folder)
    THROW 51000,'CONSUMER_FOLDER_BINDING_CHANGED',1;
IF EXISTS(SELECT 1 FROM catalog.projects WHERE folder_id=@folderId AND name=@project)
    THROW 51000,'CONSUMER_PROJECT_ALREADY_EXISTS',1;
DECLARE @operation bigint;
EXEC catalog.deploy_project @folder_name=@folder,@project_name=@project,
    @project_stream=@stream,@operation_id=@operation OUTPUT;
SELECT project_id,object_version_lsn FROM catalog.projects
    WHERE folder_id=@folderId AND name=@project;
```

```powershell
$deployed = Invoke-SqlServerLabScript @target -ScriptPath $deploySqlPath `
    -Parameters @{ folder=$folderName; folderId=$folderId; project=$projectName
                   stream=[IO.File]::ReadAllBytes($ownIspacPath) }
if (-not $deployed.Success) { throw 'Deployment unbestaetigt; eigenen Zustand pruefen.' }
$projectId = [long]$deployed.ResultSets[0].Rows[0][0]
$projectVersion = [long]$deployed.ResultSets[0].Rows[0][1]
```

Analyze speichert Projekt-ID und Version vor dem naechsten Schritt. Inhalt
von `$createExecutionSqlPath`:

```sql
IF NOT EXISTS(SELECT 1 FROM catalog.projects WHERE folder_id=@folderId
    AND project_id=@projectId AND name=@project AND object_version_lsn=@version)
    THROW 51000,'CONSUMER_PROJECT_BINDING_CHANGED',1;
DECLARE @id bigint;
EXEC catalog.create_execution @folder_name=@folder,@project_name=@project,
    @package_name=@package,@use32bitruntime=0,@reference_id=NULL,@execution_id=@id OUTPUT;
SELECT @id AS ExecutionId;
```

```powershell
$execution = Invoke-SqlServerLabScript @target -ScriptPath $createExecutionSqlPath `
    -Parameters @{ folder=$folderName; folderId=$folderId; project=$projectName
                   projectId=$projectId; version=$projectVersion; package=$ownPackageName }
if (-not $execution.Success) { throw 'Ausfuehrungsanlage unbestaetigt.' }
$executionId = [long]$execution.ResultSets[0].Rows[0][0]
# Die ID vor dem Start in der eigenen Ownership-Receipt speichern.
```

Inhalt von `$startSqlPath`:

```sql
IF NOT EXISTS(SELECT 1 FROM catalog.executions WHERE execution_id=@id
    AND folder_name=@folder AND project_name=@project AND project_lsn=@version AND status=1)
    THROW 51000,'CONSUMER_EXECUTION_BINDING_CHANGED',1;
DECLARE @level smallint=1;
EXEC catalog.set_execution_parameter_value @execution_id=@id,@object_type=50,
    @parameter_name=N'LOGGING_LEVEL',@parameter_value=@level;
EXEC catalog.start_execution @execution_id=@id;
```

```powershell
$started = Invoke-SqlServerLabScript @target -ScriptPath $startSqlPath `
    -Parameters @{ id=$executionId; folder=$folderName; project=$projectName; version=$projectVersion }
if (-not $started.Success) { throw 'Start unbestaetigt; keinen automatischen Retry ausloesen.' }
```

Ein eigenes Ergebnisskript verwendet beispielsweise
`SELECT status FROM catalog.executions WHERE execution_id=@id AND project_lsn=@version;`
und `SELECT event_message_id,message_type FROM catalog.event_messages WHERE operation_id=@id;`.
Aufrufe erhalten `-Parameters @{id=$executionId;version=$projectVersion}`.
Analyze wartet mit eigener endlicher Deadline auf den fachlich erwarteten
Endzustand und wertet seine Fehler-/Erfolgsfaelle selbst aus.
Globale Logging- und Retentionvorgaben bleiben erhalten. Die IDs **10/11/12**
der Lab-Quelle werden weder gestartet noch gestoppt oder geloescht.

## Ausschliesslich eigene Objekte entfernen

Vor Cleanup eigene aktive Ausfuehrungen identitaetsgebunden beenden und ihren
Abschluss bestaetigen. Keine automatische Wiederholung bei verlorener Antwort.
Folgendes Beispiel verweigert aktive Ausfuehrungen, Versionsdrift und zusaetzliche
Projekte oder Umgebungen. Als `$projectId=0` ist es auch fuer einen eigenen
noch leeren Ordner geeignet. Inhalt von `$cleanupSqlPath`:

```sql
SET XACT_ABORT ON;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
BEGIN TRANSACTION;
IF NOT EXISTS(SELECT 1 FROM catalog.folders WHERE folder_id=@folderId AND name=@folder)
    THROW 51000,'CONSUMER_FOLDER_BINDING_CHANGED',1;
IF EXISTS(SELECT 1 FROM catalog.environments WHERE folder_id=@folderId)
 OR EXISTS(SELECT 1 FROM catalog.projects WHERE folder_id=@folderId AND project_id<>@projectId)
    THROW 51000,'CONSUMER_FOREIGN_OBJECT_RETAINED',1;
IF @projectId>0
BEGIN
    IF NOT EXISTS(SELECT 1 FROM catalog.projects WHERE folder_id=@folderId
        AND project_id=@projectId AND name=@project AND object_version_lsn=@version)
        THROW 51000,'CONSUMER_PROJECT_BINDING_CHANGED',1;
    IF EXISTS(SELECT 1 FROM catalog.executions WHERE folder_name=@folder
        AND project_name=@project AND status IN(2,5,8))
        THROW 51000,'CONSUMER_ACTIVE_EXECUTION_RETAINED',1;
    EXEC catalog.delete_project @folder_name=@folder,@project_name=@project;
END;
EXEC catalog.delete_folder @folder_name=@folder;
COMMIT TRANSACTION;
```

```powershell
$cleaned = Invoke-SqlServerLabScript @target -ScriptPath $cleanupSqlPath `
    -Parameters @{ folder=$folderName; folderId=$folderId; project=$projectName
                   projectId=$projectId; version=$projectVersion }
if (-not $cleaned.Success) { throw 'Cleanup unbestaetigt; Ownership-Receipt erhalten.' }
```

Anschliessend die Abwesenheit der quittierten aktiven Objekte pruefen.
Projektversions- und Operationshistorie verbleiben bis zur normalen
Herstellerretention. Weder `Remove-SqlServerLabSsisCatalogFixture` noch
`Remove-SqlServerLab` ist ein Cleanup fuer Analyzeobjekte in der erhaltenen Quelle.

## Rueckgabe und Fehlerbehandlung

`Success` und `Outcome=SUCCEEDED` bestaetigen die abgeschlossenen SQL-Batches,
keinen spaeteren asynchronen Paketabschluss. `ResultSets` enthaelt je
`Batch`, `Columns` und `Rows`. Ausgaben sind Consumerdaten und werden vom
Befehl nicht automatisch protokolliert. Ergebnisobjekte nicht pauschal loggen.
Parameter unterstuetzen `string`, `int`, `long`, `bool`, `byte[]` und `null`;
die Namen werden als SQL-Parameter gebunden, nicht in SQL-Text eingesetzt.

Grenzen: UTF-8-Skript maximal 4 MiB/256 Batches; maximal 32 Parameter mit
zusammen 16 MiB; Ausgabe maximal 1024 Zeilen, 64 Spalten je Resultset,
128 Resultsets und 1 MiB Gesamtprojektion. Binaere Ausgabespalten sind nicht
unterstuetzt. Keine sqlcmd-Metabefehle oder Variablensubstitution.

Nach Versand bedeutet ein Fehler **unbestaetigter Zustand**, nicht Rollback.
`FAILED_UNCONFIRMED`, ein Timeout oder eine verlorene Antwort verlangen die
Pruefung der eigenen Ownership-Receipt und Objekte vor einem weiteren Aufruf.
Die Exception traegt bei Transportfehlern `OperationId`, `Dispatched` und
`JournalRecorded` sowie einen festen `ReasonCode` in `Exception.Data`. Das runlokale Journal enthaelt Bindung,
Skripthash und Status, keine SQL-Texte, Parameter, Ergebnisdaten oder Secrets.
Rohe SQL-Fehlertexte werden nicht ausgegeben; `ErrorCode` und gegebenenfalls
`SqlErrorNumber` dienen der lokalen Diagnose. Eigene konkrete Testskripte
bleiben deshalb klein und protokollieren ihre bestaetigten Objekt-IDs.

Der bestehende SSISDB-Vertrag und seine Leseabnahme bleiben unter
[SSISDB-Testquelle](../Architecture/SSISDB_TEST_FIXTURE.md) dokumentiert.
Der neue Harness `Tests/Integration/Invoke-WindowsSqlConsumerAcceptance.ps1`
prueft den oeffentlichen Windowsweg am explizit bezeichneten bestehenden Run,
ohne die vorhandene Lab-Fixture zu erneuern.
Die [lokale native Abnahme vom 2026-10-16](../Quality/WINDOWS_SQL_CONSUMER_ACCEPTANCE_2026-10-16.md)
belegt diesen Weg einschließlich Deployment, Paketstart und eigenem Cleanup.
