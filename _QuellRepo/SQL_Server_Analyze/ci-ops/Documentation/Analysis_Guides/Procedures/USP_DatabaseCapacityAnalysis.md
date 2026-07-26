# [monitor].[USP_DatabaseCapacityAnalysis]

**Bereich:** Server Health<br>
**Zweck:** Bewertet Dateien, Volumes, freien Platz, Autogrowth, MaxSize und Wachstumsspielraum.<br>
**Beobachtungsart:** Snapshot ohne Wachstumsprognose<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Wie viel Datei-/Volumeplatz bleibt, wie sind Growth/MaxSize konfiguriert und welche Kapazitätsrisiken sind sichtbar?** Sie unterstützt die Entscheidung, ob eine Instanzressource oder Konfiguration als belastbare Spur zum Symptom passt und welche unabhängige OS-, Verlaufs- oder Workloadevidenz fehlt.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige OS-/Hypervisorursache und ohne Delta oder Verlauf keine belastbare Aussage über einen dauerhaften Engpass. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_DatabaseCapacityAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @ResultSetArt = 'CONSOLE';
```

Für vollständige Volumenevidenz ist auf SQL Server 2019 `VIEW SERVER STATE`, ab SQL Server 2022 `VIEW SERVER PERFORMANCE STATE` erforderlich. Fehlt dieses Recht, bleibt zulässige Dateievidenz sichtbar, der Status lautet jedoch ausdrücklich `AVAILABLE_LIMITED` mit `IsPartial=1`.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `capacity`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset entspricht eine Zeile einer Datenbankdatei, einem Volume, einer Datenbankaggregation oder einem Finding.

## So lesen

Berücksichtigen Sie Dateigröße, belegt/frei, Volume Free, Growthsetting, MaxSize und absoluten Wachstumsspielraum gemeinsam.

## Warum kann das problematisch sein?

Wenig freier Raum plus kleine häufige Autogrowths kann Pausen erzeugen; MaxSize oder volles Volume kann Wachstum vollständig verhindern.

## Wann ist es kein Problem?

Niedriger Prozentwert bei sehr großem Volume kann absolut ausreichend sein; hoher Prozentwert auf kleinem Volume nicht.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** 5 % von 20 TB = 1 TB; 20 % von 10 GB = 2 GB. Berücksichtigen Sie Prozent und absolute Menge gemeinsam. Prüfen Sie Wachstumstrend, Log-/Backupstatus und Storage.

**Ähnlich aussehender Gegenfall:** Niedriger Prozentwert bei sehr großem Volume kann absolut ausreichend sein; hoher Prozentwert auf kleinem Volume nicht. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Server-DMVs können plattform-, editions- oder berechtigungsbedingt fehlen. NULL und PARTIAL sind dann Evidenzgrenzen, keine Nullmessung.

Für `USP_DatabaseCapacityAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Eine `ExampleDatabase`; pro Datei werden Kataloggröße, `FILEPROPERTY(...,'SpaceUsed')`, Volume-Freiraum und der nächste Autogrowth-Schritt als Snapshot bewertet. |
| Teuerster Pfad | Alle sichtbaren Datenbanken, unbegrenzte Ausgabe und viele Daten-/Logdateien auf zahlreichen Volumes. Es gibt keinen History-, Growth- oder Benutzerdatenscan. |
| Haupttreiber | Zahl gewählter Datenbanken und ihrer Daten-/Logdateien; für jede Datei werden Kataloggröße, belegte Seiten und Volumeinformationen korreliert. Dateigröße verändert die Werte, nicht proportional die Metadatenarbeit. |
| Skalierung | Aufwand wächst ungefähr mit Datenbanken und Dateien. Volumeabfragen können je Datei wiederholt werden; Sortierung und Resultat bleiben im Verhältnis zur Dateimenge klein. |
| Ressourcen | Katalog-/Dateimetadaten-I/O, CPU für dynamische Datenbankabfragen und `sys.dm_os_volume_stats`; kleine temporäre Ergebnistabelle. Keine msdb- oder Memory-Clerk-Abfrage. |
| Begrenzungswirkung | Datenbankliste/-pattern begrenzen den Cursor früh. `@NurProblematisch` und `@MaxZeilen` wirken erst auf die vollständig erzeugten Dateibewertungen und begrenzen `FILEPROPERTY`-/Volumezugriffe nicht. |
| Locking und Nebenwirkungen | Read-only; kurze Metadatenzugriffe und nicht atomare Runtime-DMVs. Es wird weder CHECKDB noch Growth noch Konfigurationsänderung ausgeführt. |
| Schutzmechanismus | `SERVER_HEALTH_CURRENT` muss freigegeben sein, verlangt laut Klassenkatalog keine High-Impact-Bestätigung. Wirksamer Schutz ist eine einzelne Datenbank; `@HighImpactConfirmed` öffnet keinen weiteren Pfad. |
| Sicherer Einsatz | Eine `ExampleDatabase`, Problemscope und endliches Limit; erst nach Sichtung von Dateianzahl und Laufzeit weitere Datenbanken aufnehmen. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Snapshot ohne Wachstumsprognose“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Wie viel Datei-/Volumeplatz bleibt, wie sind Growth/MaxSize konfiguriert und welche Kapazitätsrisiken sind sichtbar?

### Technischer Hintergrund

Database Files wachsen innerhalb Volume-/MaxSizegrenzen. Percent Growth erzeugt mit wachsender Datei zunehmend große Schritte; kleine Growthsteps erzeugen häufige Growth Events. Loggrowth/Zero Initialization und Datafile IFI unterscheiden sich.

### Datenkette

`sys.database_files`, `sys.dm_os_volume_stats`, `sys.sp_executesql`.

### Source Select

Im Kontext einer bereits ausgewählten Datenbank werden Dateikatalog und Volume-Information verbunden:

```sql
SELECT
      DB_NAME() AS [DatabaseName]
    , [f].[file_id]
    , [f].[name] AS [LogicalFileName]
    , [f].[type_desc]
    , [f].[size] * 8.0 / 1024.0 AS [SizeMb]
    , [v].[volume_mount_point]
    , [v].[available_bytes]
FROM [sys].[database_files] AS [f] WITH (NOLOCK)
OUTER APPLY [sys].[dm_os_volume_stats](DB_ID(), [f].[file_id]) AS [v]
WHERE [f].[state] = 0;
```

**Wichtig für die Eigenlast:** Begrenzen Sie zuerst die Datenbankkandidaten. `dm_os_volume_stats` nur für deren Dateien aufrufen; `@MaxZeilen` reduziert sonst gegebenenfalls nur die spätere Ausgabe, nicht die Zahl der Volume-Auflösungen.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Snapshot. Ohne historische Messpunkte lässt sich weder eine Wachstumsrate noch eine Prognose ableiten.

### Bewertung und Gegenprobe

Berücksichtigen Sie absolute freie MB und Prozent, Dateigröße, Growthtyp und -schritt, MaxSize, Volume Free, Dateityp und geplante Workloadspitzen gemeinsam. Autogrowth dient als Sicherheitsnetz; die Kapazität sollte proaktiv geplant werden.

### Typische Fehlinterpretation

Viel freier Platz im File bedeutet nicht freien Volumeplatz; viel Volumeplatz bedeutet nicht passende MaxSize/Growth. Forecast aus einem Snapshot ist Heuristik.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Current Log/IO, Backup-/Loadplanung und externes Capacitytrendmonitoring.

## Primärquellen

- [sys.dm_os_volume_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-volume-stats-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../08_Server_Health.md#12-monitorusp_databasecapacityanalysis)
