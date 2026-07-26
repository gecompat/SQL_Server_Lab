# Installation in SQL Server Management Studio (SSMS)

Diese Anleitung beschreibt die vollständige Erstinstallation und die anschließende Funktionsprüfung. Der empfohlene Weg erzeugt zunächst einen eigenständigen Installer und führt danach nur eine SQL-Datei in SSMS aus.

## 1. Voraussetzungen prüfen

Benötigt werden:

- SQL Server 2019 oder neuer;
- SQL Server Management Studio (SSMS);
- Windows PowerShell oder PowerShell 7 zum Erzeugen des eigenständigen Installers;
- eine lokale Kopie dieses Repositorys;
- für die einmalige Installation ausreichende DDL-Rechte in der Installationsdatenbank. Für die Erstinstallation ist die Datenbankrolle `db_owner` der einfachste verlässliche Weg;
- Das Framework verwendet durchgängig explizite `COLLATE`-Klauseln und
  funktioniert grundsätzlich auf beliebigen Collations. Getestet und
  garantiert wird ausschließlich `SQL_Latin1_General_CP1_CS_AS` für
  Server, `tempdb` und Installationsdatenbank.

Das Framework vergibt keine Benutzer-, Datenbank- oder Serverberechtigungen und ändert keine Serverkonfiguration.

## 2. Repository herunterladen

1. Auf der GitHub-Seite des Repositorys **Code** und danach **Download ZIP** wählen. Alternativ das Repository mit Git klonen.
2. Die ZIP-Datei vollständig in ein lokales Verzeichnis entpacken, beispielsweise `C:\Tools\SQL_Server_Analyze`.
3. Die Verzeichnisstruktur unverändert lassen. Der Build und der alternative SQLCMD-Installer verwenden relative Pfade.
4. Lesen Sie vor der Verwendung die Datei `LICENSE.md`.

## 3. Zielinstanz und Collation kontrollieren

1. Starten Sie SSMS.
2. Mit der SQL-Server-Instanz verbinden, auf der das Framework installiert werden soll.
3. **Neue Abfrage** öffnen und folgende Vorprüfung ausführen:

```sql
SELECT
      TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion')) AS [ProductMajorVersion]
    , CONVERT(sysname, SERVERPROPERTY(N'ProductVersion'))     AS [ProductVersion]
    , CONVERT(sysname, SERVERPROPERTY(N'Edition'))            AS [Edition]
    , CONVERT(sysname, SERVERPROPERTY(N'Collation'))          AS [ServerCollation]
    , (SELECT [collation_name]
       FROM [master].[sys].[databases] WITH (NOLOCK)
       WHERE [name] = N'tempdb')                              AS [TempDbCollation];
```

Der derzeitige Release- und Teststand ist freigegeben, wenn:

- `ProductMajorVersion` mindestens `15` ist.

Die Collation-Prüfung ist informativ: Der Installer gibt bei abweichender
Server-, `tempdb`- oder Installationsdatenbank-Collation eine **Warnung** aus,
blockiert die Installation jedoch nicht.

### Collation-Architektur

Das Framework verwendet in allen Vergleichen, `GROUP BY`-Klauseln,
Temp-Tabellen-Spalten und TVF-Rückgabewerten durchgängig explizite
`COLLATE SQL_Latin1_General_CP1_CS_AS`-Angaben. Dadurch:

- hängt kein Vergleich oder JOIN von der Standard-Collation der
  Installationsdatenbank oder von `tempdb` ab;
- treten keine Collation-Konflikte zwischen Frameworktabellen,
  Systemkatalogen und `#Temp`-Tabellen auf;
- ist das Verhalten bei Filterlisten, Objektnamenvergleichen und
  Deduplizierung deterministisch und collation-unabhängig.

**Einschränkung:** Getestet und automatisiert nachgewiesen ist ausschließlich
`SQL_Latin1_General_CP1_CS_AS`. Bei abweichender Collation kann sich das
Verhalten bei Filterlisten mit bracket-quotierten Objektnamen unterscheiden,
wenn die Zieldatenbank Objekte enthält, deren Namen sich nur in der
Groß-/Kleinschreibung unterscheiden. Für produktive Systeme wird die
getestete Collation empfohlen.

## 4. Installationsdatenbank anlegen oder prüfen

Das Framework legt die Datenbank nicht selbst an. `[DeineDatenbank]` ist im
gesamten folgenden Ablauf durch den lokal gewählten Datenbanknamen zu ersetzen.

### Neue Datenbank

```sql
USE [master];
GO

CREATE DATABASE [DeineDatenbank]
COLLATE SQL_Latin1_General_CP1_CS_AS;
GO
```

### Vorhandene Datenbank

```sql
SELECT
      [name]
    , [state_desc]
    , [user_access_desc]
    , [is_read_only]
    , [collation_name]
FROM [master].[sys].[databases] WITH (NOLOCK)
WHERE [name] = N'DeineDatenbank';
```

Erwartet werden `ONLINE`, `MULTI_USER`, `is_read_only = 0` und die Collation `SQL_Latin1_General_CP1_CS_AS`.

## 5. Eigenständigen Installer erzeugen

Dieser Schritt benötigt keine SQL-Server-Verbindung und verändert den Server nicht.

1. Öffnen Sie PowerShell.
2. In das Installationsverzeichnis der entpackten Repositorykopie wechseln:

```powershell
Set-Location 'C:\Tools\SQL_Server_Analyze\Code\Install'
```

3. Den Build ausführen:

```powershell
.\Build-StandaloneInstaller.ps1
```

4. Die Erfolgsmeldung kontrollieren. Im Unterverzeichnis `generated` muss nun die Datei `Install_All.generated.sql` liegen.

Das Buildskript übernimmt die kanonischen SQL-Dateien in ihrer abhängigkeitssicheren Reihenfolge. `generated/Install_All.generated.sql` ist ein lokales Build-Artefakt und wird nicht in Git versioniert. Falls die lokale PowerShell-Richtlinie das Skript blockiert, dürfen Sie die Richtlinie nicht unkontrolliert umgehen. Klären Sie die Ausführung stattdessen mit der zuständigen Administration oder verwenden Sie den alternativen SQLCMD-Weg.

## 6. Installer in SSMS vorbereiten

1. Wählen Sie in SSMS **Datei > Öffnen > Datei**.
2. Öffnen Sie `Code\Install\generated\Install_All.generated.sql`.
3. Nur die erste Zeile anpassen:

```sql
USE [DeineDatenbank];
```

4. Kontrollieren, dass das Abfragefenster mit der richtigen Serverinstanz verbunden ist.
5. Die gesamte Datei ausführen, nicht nur einen markierten Ausschnitt.

Der generierte Installer enthält keine `:r`-Anweisungen. Für ihn muss der SQLCMD-Modus in SSMS daher nicht aktiviert werden.

## 7. Installation ausführen

1. Im Installerfenster **Ausführen** wählen oder `F5` drücken.
2. Warten Sie bis zum Ende und kontrollieren Sie insbesondere die Registerkarte **Meldungen**.
3. Gehen Sie bei einem Fehler nicht von einer vollständigen Installation aus. Beheben Sie die Ursache und führen Sie anschließend den gesamten Installer erneut aus.

Die Frameworkobjekte liegen danach in der gewählten Datenbank im Schema `[monitor]`. Der Installer verwendet `CREATE OR ALTER` sowie idempotente DDL-/DML-Logik und kann deshalb auch für Upgrades erneut vollständig ausgeführt werden.

## 8. Version und Kernobjekte prüfen

Ein neues Abfragefenster öffnen und ausführen:

```sql
USE [DeineDatenbank];
GO

SELECT
      [FrameworkName]
    , [FrameworkVersion]
FROM [monitor].[FrameworkVersion] WITH (NOLOCK);

SELECT COUNT_BIG(*) AS [MonitorProcedureCount]
FROM [sys].[procedures] AS [p] WITH (NOLOCK)
JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
  ON [s].[schema_id] = [p].[schema_id]
WHERE [s].[name] = N'monitor';
```

Die Versionsabfrage muss genau eine Frameworkzeile liefern. Die Prozedurzahl muss größer als `0` sein.

## 9. Smoke-Test ausführen

1. Öffnen Sie in SSMS die Datei `Code\Tests\Integration\110_Smoke_Test.sql`.
2. Beide Vorkommen von `[DeineDatenbank]` durch den lokal gewählten, korrekt
   geklammerten Datenbanknamen ersetzen.
3. Führen Sie die gesamte Datei mit `F5` aus.

Der letzte Ergebnisdatensatz muss unter anderem enthalten:

- `StatusCode = AVAILABLE`;
- `IsPartial = 0`;
- `Detail = Kompakter Smoke Test erfolgreich.`

Ein Fehler im Smoke-Test ist kein Grund, einzelne Prüfungen zu löschen oder auszukommentieren. Prüfen Sie zuerst die Meldung und den vorherigen Installationslauf.

## 10. Analysebereitschaft und Berechtigungen prüfen

```sql
USE [DeineDatenbank];
GO

EXEC [monitor].[USP_CheckFrameworkCapabilities]
     @ResultSetArt = 'CONSOLE';

EXEC [monitor].[USP_CheckAnalyseAccess]
     @ResultSetArt = 'CONSOLE';
```

Diese Prüfungen trennen technische SQL-Server-Berechtigungen von der internen Ressourcenschutz-Policy. `DENIED_PERMISSION`, `AVAILABLE_LIMITED` oder partielle Resultsets können auf fehlende Laufzeitrechte oder nicht verfügbare Features hinweisen; sie bedeuten nicht automatisch, dass die Frameworkobjekte fehlerhaft installiert wurden.

Typische Laufzeitrechte sind:

- SQL Server 2019: je nach Analyse `VIEW SERVER STATE` und `VIEW DATABASE STATE`;
- SQL Server 2022 oder neuer: je nach Quelle `VIEW SERVER PERFORMANCE STATE` und `VIEW DATABASE PERFORMANCE STATE`;
- einzelne Sicherheits-, SQL-Agent-, `msdb`-, Query-Store-, Extended-Events- oder featurebezogene Quellen können zusätzliche Rechte verlangen.

Die tatsächlich erforderlichen Rechte hängen vom aufgerufenen Modul ab. Das Framework erteilt sie bewusst nicht automatisch. Nach dem Ersttest das Laufzeitkonto und die interne Policy anhand der [Administrationsanleitung](../Operations/Authorization_Administration.md) einrichten.

### Optional: persistentes Snapshot-/Baseline-Paket SC-023

`Install_All.sql` installiert keine Persistenz. Für restartfeste Performance-
Counter-Baselines sind eine eigene Snapshot-Datenbank, anschließend
`Install_SnapshotBaseline_Target.sql` in deren Verbindungskontext und danach
`Install_SnapshotBaseline_Framework.sql` in der Frameworkdatenbank erforderlich.
Alternativ erzeugt `Code/Install/Build-SnapshotBaselineInstallers.ps1` unter
`Code/Install/generated/` zwei vollständig eingebettete Installer ohne
SQLCMD-Abhängigkeit. Der Target-Installer wird weiterhin in der ausdrücklich
ausgewählten Snapshotdatenbank ausgeführt; erst danach folgt der
Framework-Installer in der Frameworkdatenbank.
Das Paket erstellt keine Datenbank, Berechtigungen oder Schedulerobjekte. Siehe
[Snapshot-/Baseline-Betrieb](../Operations/Snapshot_Baseline_Operations.md).

## 11. Erste Analyse starten

Ermitteln Sie zuerst einen passenden Einstieg anhand des Symptoms oder Analyseziels:

```sql
USE [DeineDatenbank];
GO

EXEC [monitor].[USP_AnalysisNavigator]
     @Suchbegriff = N'Etwas ist jetzt langsam',
     @NurInstallierte = 1,
     @ResultSetArt = 'CONSOLE';
```

Der Navigator führt keine vorgeschlagene Analyse aus.

Eine leichte, begrenzte Übersicht:

```sql
USE [DeineDatenbank];
GO

EXEC [monitor].[USP_CurrentOverview]
     @MitSqlText    = 0,
     @SampleSeconds = 0,
     @MaxZeilen     = 100,
     @ResultSetArt  = 'CONSOLE';
```

Ein aktuelles Wait-Delta:

```sql
EXEC [monitor].[USP_CurrentWaits]
     @SampleSeconds     = 15,
     @TopWaitPercentage = 95,
     @MaxZeilen         = 100,
     @ResultSetArt      = 'CONSOLE';
```

Weitere ausführbare Beispiele stehen in `Code\Examples\040_Schnellreferenz_Aufrufe.sql`.

## 12. Alternative: Installation im SQLCMD-Modus von SSMS

Der Include-Installer `Code\Install\Install_All.sql` bindet die kanonischen
Einzeldateien mit `:r` in ihrer abhängigkeitssicheren Reihenfolge ein. Dieser Weg
installiert unmittelbar aus den Quelldateien und benötigt keinen vorher
generierten Gesamtinstaller. Er eignet sich besonders für Entwicklung und für
Administratoren, die den einbezogenen Quellbestand einzeln kontrollieren wollen.

Der SQLCMD-Modus ersetzt den Datenbankplatzhalter nicht automatisch. Weil jede
kanonische SQL-Datei auch einzeln ausführbar bleibt, muss `[DeineDatenbank]` vor
der Installation in allen eingebundenen Dateien ersetzt werden.

### 12.1 Separate Arbeitskopie anlegen

1. Das Repository vollständig herunterladen oder klonen.
2. Für die Installation eine separate lokale Arbeitskopie verwenden. Dadurch
   bleiben die heruntergeladenen Originaldateien unverändert und können später
   mit Git beziehungsweise dem Download verglichen werden.
3. Die Verzeichnisse unter `Code` nicht verschieben oder einzeln kopieren. Die
   `:r`-Anweisungen in `Install_All.sql` benötigen die vorhandene relative
   Verzeichnisstruktur.

Beispielstruktur:

```text
SQL_Server_Analyze-SqlCmd\
└── Code\
    ├── 00_Setup\
    ├── 01_Common\
    ├── ...
    ├── 09_VersionAdaptive\
    └── Install\
        └── Install_All.sql
```

### 12.2 Datenbankplatzhalter in der Arbeitskopie ersetzen

Vor dem Ersetzen muss die Installationsdatenbank gemäß den Schritten 3 und 4
dieser Anleitung geprüft beziehungsweise angelegt worden sein.

Mit einem Editor, der **Suchen und Ersetzen in Dateien** unterstützt:

1. Wählen Sie als Suchbereich ausschließlich den Ordner `Code` der Arbeitskopie.
2. Nach dem exakten Text `[DeineDatenbank]` suchen.
3. Ersetzen Sie den Platzhalter durch den korrekt geklammerten lokalen Datenbanknamen.
4. Nur Dateien mit der Endung `.sql` ändern.
5. Anschließend repositoryweit prüfen, dass unter `Code` kein
   `[DeineDatenbank]` mehr vorkommt.

Alternativ kann die Ersetzung reproduzierbar mit PowerShell erfolgen. Das
folgende Skript fragt den Namen ab, klammert auch eine schließende eckige Klammer
im Namen korrekt und bearbeitet ausschließlich `.sql`-Dateien unter `Code`:

```powershell
$RepositoryRoot = 'C:\Tools\SQL_Server_Analyze-SqlCmd'
$DatabaseName = Read-Host 'Name der Installationsdatenbank'

if ([string]::IsNullOrWhiteSpace($DatabaseName)) {
    throw 'Der Datenbankname darf nicht leer sein.'
}

$QuotedDatabaseName = '[' + $DatabaseName.Replace(']', ']]') + ']'
$Utf8WithoutBom = [Text.UTF8Encoding]::new($false)

Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'Code') `
              -Filter '*.sql' -File -Recurse |
    ForEach-Object {
        $Content = [IO.File]::ReadAllText($_.FullName)
        $UpdatedContent = $Content.Replace(
            '[DeineDatenbank]',
            $QuotedDatabaseName
        )
        if ($UpdatedContent -ne $Content) {
            [IO.File]::WriteAllText(
                $_.FullName,
                $UpdatedContent,
                $Utf8WithoutBom
            )
        }
    }

$Remaining = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'Code') `
                           -Filter '*.sql' -File -Recurse |
    Select-String -SimpleMatch '[DeineDatenbank]'

if ($Remaining) {
    throw 'Der Datenbankplatzhalter ist noch in SQL-Dateien vorhanden.'
}
```

Dieser Schritt verändert nur die lokale Arbeitskopie und führt noch kein SQL
aus.

### 12.3 Include-Installer in SSMS öffnen

1. SSMS starten und mit der vorgesehenen SQL-Server-Instanz verbinden.
2. Über **Datei > Öffnen > Datei** genau die vorbereitete Datei
   `Code\Install\Install_All.sql` öffnen. Kein neues leeres Abfragefenster
   verwenden und den Inhalt nicht in ein solches kopieren.
3. Kontrollieren, dass die erste `USE`-Anweisung den gewählten Datenbanknamen
   enthält.
4. Prüfen, dass darunter `:r`-Zeilen für `00_Setup` bis
   `09_VersionAdaptive` vorhanden sind.
5. Führen Sie das Abfragefenster noch nicht aus.

### 12.4 SQLCMD-Modus aktivieren und kontrollieren

1. Im aktiven Installerfenster **Abfrage > SQLCMD-Modus** auswählen.
2. Kontrollieren, dass der Menüeintrag aktiviert ist. Der SQLCMD-Modus gilt nur
   für das jeweilige Abfragefenster.
3. Die `:ON ERROR EXIT`- und `:r`-Zeilen müssen nun als SQLCMD-Befehle mit
   schattiertem Hintergrund dargestellt werden. Bleiben sie gewöhnlicher
   SQL-Text, ist der Modus nicht aktiv.

SQLCMD-Modus ist in SSMS standardmäßig nicht aktiv. Microsoft dokumentiert die
Aktivierung, die farbliche Kennzeichnung und die Unterstützung von `:r` unter
[Microsoft Learn: SQLCMD-Skripts mit dem Abfrage-Editor bearbeiten](https://learn.microsoft.com/de-de/ssms/scripting/sqlcmd-scripts-query-editor).

### 12.5 Verbindung und Ausführung prüfen

Vor `F5` kontrollieren:

- Das Abfragefenster ist mit der richtigen Serverinstanz verbunden.
- Die Installationsdatenbank existiert und ist `ONLINE` sowie beschreibbar.
- Die Collationprüfungen aus Schritt 3 waren erfolgreich.
- Der Datenbankplatzhalter ist vollständig ersetzt.
- Die Arbeitskopie enthält weiterhin alle von `:r` referenzierten Dateien.
- Der ausführende Login besitzt die erforderlichen DDL-Rechte.

Danach:

1. Sicherstellen, dass kein Text im Abfragefenster markiert ist. Andernfalls
   würde SSMS nur den markierten Ausschnitt ausführen.
2. **Ausführen** wählen oder `F5` drücken.
3. Die Verarbeitung bis zum Ende abwarten.
4. Die Registerkarte **Meldungen** kontrollieren. `:ON ERROR EXIT` beendet den
   Include-Installer beim ersten SQL-Fehler; nach einem Fehler ist die
   Installation als unvollständig zu behandeln.

### 12.6 SQLCMD-Installation verifizieren

Nach einem fehlerfreien Installerlauf dieselben Prüfungen wie beim empfohlenen
Weg durchführen:

1. Kontrollieren Sie Version und Kernobjekte gemäß Schritt 8.
2. `Code\Tests\Integration\110_Smoke_Test.sql` aus derselben vorbereiteten
   Arbeitskopie öffnen und vollständig ausführen. Der Datenbankplatzhalter ist
   dort durch die repositoryweite Ersetzung bereits gesetzt.
3. Führen Sie die Capability- und Berechtigungsprüfung aus Schritt 10 aus.
4. Erst danach mit den begrenzten Beispielaufrufen aus Schritt 11 beginnen.

### 12.7 Typische SQLCMD-Fehler

| Meldung oder Beobachtung | Ursache | Maßnahme |
|---|---|---|
| Syntaxfehler bei `:` oder `:r` | SQLCMD-Modus war nicht aktiv | Im betroffenen Abfragefenster **Abfrage > SQLCMD-Modus** aktivieren und Darstellung kontrollieren |
| `A fatal scripting error occurred. File ... could not be opened` | Include-Datei fehlt oder relative Verzeichnisstruktur wurde verändert | Vollständige Arbeitskopie wiederherstellen und `Install_All.sql` direkt aus `Code\Install` öffnen |
| Datenbank `DeineDatenbank` nicht gefunden | Platzhalter wurde nicht vollständig ersetzt | Ersetzung und abschließende Suche unter `Code` wiederholen |
| Installation endet nach dem ersten SQL-Fehler | `:ON ERROR EXIT` arbeitet wie vorgesehen | Erste SQL-Fehlermeldung beheben und anschließend den vollständigen Installer erneut ausführen |
| `:r`-Zeilen bleiben unmarkiert | Falsches Fenster oder Modus nicht aktiv | Installerfenster aktivieren und SQLCMD-Modus erneut einschalten |
| Installer funktioniert, Analyse ist partiell | Laufzeitberechtigung oder Feature fehlt | Schritt 10 und die Berechtigungsdokumentation verwenden |

Der eigenständige Installer bleibt die einfachere SSMS-Variante. Der
SQLCMD-Modus ist fachlich gleichwertig, verlangt aber eine vollständige,
konsistent vorbereitete Arbeitskopie der Einzeldateien.

## Upgrade

1. Die gewünschte neue Repositoryversion separat herunterladen oder auschecken.
2. Den eigenständigen Installer aus genau diesem Stand neu erzeugen.
3. Setzen Sie den Datenbanknamen in der ersten Zeile.
4. Führen Sie den gesamten Installer erneut aus.
5. Wiederholen Sie die Versionsprüfung und den Smoke-Test.

Frameworkeigene Standardzeilen im Wait-Katalog werden aktualisiert; eigene Katalogzeilen bleiben erhalten. Vor produktiven Upgrades gelten die üblichen Sicherungs-, Change- und Rückfallprozesse der Umgebung.

## Häufige Fehler

| Meldung oder Symptom | Wahrscheinliche Ursache | Maßnahme |
|---|---|---|
| Datenbank `DeineDatenbank` nicht gefunden | Platzhalter wurde nicht ersetzt | Erste `USE`-Zeile beziehungsweise Testdatei korrigieren |
| Der Installer meldet eine nicht unterstützte Server-, `tempdb`- oder Datenbank-Collation | Eine der drei Collations liegt außerhalb der derzeit getesteten und freigegebenen Plattformgrenze | Installation abbrechen; die Prüfung nicht umgehen und erst einen Frameworkstand mit nachgewiesener Collation-Portabilität verwenden |
| Syntaxfehler bei `:r` | Include-Installer ohne SQLCMD-Modus ausgeführt | SQLCMD-Modus aktivieren oder generierten Installer verwenden |
| Include-Datei nicht gefunden | Repository unvollständig, verschoben oder falscher Ausführungskontext | Repository vollständig entpacken oder generierten Installer verwenden |
| `CREATE`/`ALTER`/`CREATE SCHEMA` verweigert | DDL-Rechte fehlen | Installation mit einem dafür freigegebenen Konto ausführen |
| Frameworkobjekte fehlen oder Smoke-Test meldet falsche Version | Installer wurde nicht vollständig oder aus einem gemischten Stand ausgeführt | Meldungen prüfen, konsistenten Repositorystand verwenden und vollständig erneut installieren |
| Analyse liefert `DENIED_PERMISSION` oder `AVAILABLE_LIMITED` | Laufzeitrecht oder optionale Quelle fehlt | Capability-Ausgabe und Berechtigungsdokumentation prüfen |

## Abgrenzung

Es gibt bewusst keine persistente Installationshistorie, keine automatische Rechtevergabe und keine implizite Datenspeicherung. Git ist die maßgebliche Versions- und Integritätsquelle; ein zusätzliches, bei jeder Änderung nachzuführendes Dateihash-Manifest wird nicht verwendet.

Ein realer Compile- und Laufzeittest auf der konkreten Zielversion, Edition, Plattform und Berechtigungsstufe bleibt erforderlich.

## Teilinstallation der Execution-Plan-Analyse

Für eine eigenständig nutzbare Plananalyse verwenden Sie `Code/Install/Install_ExecutionPlanAnalysis.sql` im SQLCMD-Modus. Alternativ erzeugt `Code/Install/Build-ExecutionPlanAnalysisInstaller.ps1` unter `Code/Install/generated/` einen vollständig eingebetteten Installer. Verfügbar sind danach mindestens `monitor.USP_ExecutionPlanAnalysis` und `monitor.USP_CreateExecutionEvidenceJson`; Query Store, Current State, Extended Events und Server Health werden nicht mitinstalliert.
