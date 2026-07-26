# [monitor].[USP_TempDBConfiguration]

**Bereich:** Server Health<br>
**Zweck:** Bewertet TempDB-Dateien, Größen, Wachstum, Gleichheit und Konfigurationsrisiken.<br>
**Beobachtungsart:** Katalogsnapshot<br>
**Kostenklasse:** LOW

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Ist TempDB hinsichtlich Dateianzahl, Größe, Growth, Layout und Optionen robust konfiguriert?** Sie unterstützt die Entscheidung, ob eine Instanzressource oder Konfiguration als belastbare Spur zum Symptom passt und welche unabhängige OS-, Verlaufs- oder Workloadevidenz fehlt.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige OS-/Hypervisorursache und ohne Delta oder Verlauf keine belastbare Aussage über einen dauerhaften Engpass. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_TempDBConfiguration]
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `files`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset entspricht eine Zeile einer TempDB-Datei, Konfigurationseigenschaft oder einem Finding.

## So lesen

Berücksichtigen Sie Dateianzahl, Größen-/Growth-Gleichheit, Autogrowth-Einheit, freien Platz, Version Store und Contentionkontext gemeinsam.

## Warum kann das problematisch sein?

Ungleich große Datenfiles werden proportional unterschiedlich genutzt; kleine Growthschritte erzeugen viele Wachstumsereignisse.

## Wann ist es kein Problem?

Nicht jede Instanz benötigt acht Dateien. CPU, Contention und Workload entscheiden.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Vier gleich große Dateien ohne Contention können besser sein als acht ungleich große. Prüfen Sie Current TempDB, Filegrowth-Historie und Contention.

**Ähnlich aussehender Gegenfall:** Nicht jede Instanz benötigt acht Dateien. CPU, Contention und Workload entscheiden. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Server-DMVs können plattform-, editions- oder berechtigungsbedingt fehlen. NULL und PARTIAL sind dann Evidenzgrenzen, keine Nullmessung.

Für `USP_TempDBConfiguration` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW |
| Standardpfad | Liest alle aktuellen TempDB-Dateizeilen sowie genau drei bekannte TempDB-Konfigurationsnamen. CONSOLE/TABLE exportieren die Dateisicht; RAW/JSON enthalten zusätzlich die Konfigurationssicht. |
| Teuerster Pfad | Gegenüber dem Standard existiert kein tiefer Modus. Viele TempDB-Dateien und gleichzeitige JSON-/RAW-Ausgabe verbreitern nur die kleine Katalogmenge; Dateiinhalte und Allokationsseiten werden nicht gelesen. |
| Haupttreiber | Anzahl der Zeilen in `tempdb.sys.database_files`; die `sys.configurations`-Quelle ist auf drei Namen begrenzt. Dateigröße beeinflusst die Abfragekosten nicht. |
| Skalierung | Linear mit der Zahl der TempDB-Dateien. Umrechnung von Pages in MB, Growthtyp und Sortierung nach `file_id` sind konstante beziehungsweise sehr kleine CPU-Arbeit. |
| Ressourcen | Zwei kurze Katalogabfragen und kleine Temp-Tabellen. Kein Zugriff auf `sys.dm_db_file_space_usage`, Dateiinhalte, PFS/GAM/SGAM oder Nutzerobjekte. |
| Begrenzungswirkung | Es gibt bewusst kein `@MaxZeilen`: die vollständige Dateiliste ist Teil der Konfigurationsbewertung. `@ResultSetArt = 'NONE'` spart nur Ausgabe, nicht die beiden Quellabfragen. |
| Locking und Nebenwirkungen | Read-only; kurze Metadatenzugriffe auf TempDB und Serverkonfiguration. Gleichzeitiges Datei-ADD/GROWTH kann dazu führen, dass Dateiliste und Konfigurationssicht verschiedene Momente abbilden. |
| Schutzmechanismus | Kein Gate und kein Scopeparameter. Die feste Begrenzung ist die reale TempDB-Dateizahl plus genau drei abgefragte Konfigurationsnamen; Benutzerdaten, Allokationsseiten und Dateiinhalte liegen außerhalb des implementierten Pfads. |
| Sicherer Einsatz | CONSOLE ist kostengünstig; physische Dateipfade aus RAW/JSON/TABLE nur im geschützten Betriebskontext speichern oder weitergeben. |
| Aussagegrenze | Die Procedure bewertet Konfiguration, nicht aktuelle TempDB-Auslastung, Latchkonkurrenz oder Dateilatenz. Gleiche Dateigröße beweist weder gleichmäßiges Autogrowth noch proportionale Nutzung. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Ist TempDB hinsichtlich Dateianzahl, Größe, Growth, Layout und Optionen robust konfiguriert?

### Technischer Hintergrund

TempDB wird bei jedem Start neu erstellt. Datafiles bilden Allocationkonkurrenz ab; gleich große Dateien begünstigen Proportional Fill. Autogrowth ist Notfallkapazität, kein laufendes Sizingmodell. Version Store, Internal/User Objects verursachen Runtimebelegung.

### Datenkette

`sys.configurations`, `tempdb.sys.database_files`.

### Source Select

Dateigröße, Wachstum und Ablage kommen direkt aus dem TempDB-Dateikatalog:

```sql
SELECT
      [f].[file_id]
    , [f].[name] AS [LogicalFileName]
    , [f].[type_desc]
    , [f].[size] * 8.0 / 1024.0 AS [SizeMb]
    , [f].[growth]
    , [f].[is_percent_growth]
    , [f].[physical_name]
FROM [tempdb].[sys].[database_files] AS [f] WITH (NOLOCK)
WHERE [f].[state] = 0
ORDER BY [f].[type], [f].[file_id];
```

**Wichtig für die Eigenlast:** Die Quelle ist klein und benötigt keinen Nutzdatenscan. `physical_name` kann in realen Resultsets umgebungsspezifisch sein; nicht ungeprüft exportieren. Die Procedure ändert weder Dateigröße noch Anzahl oder Wachstum.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Katalog- und Dateistand; der TempDB-Inhalt besteht seit dem Engine-Start.

### Bewertung und Gegenprobe

Prüfen Sie Datafile Count relativ zu Workload und CPU, gleiche Initialgröße und Growth, absolute Growthgröße, Volumeplatz, Logfile und versionsabhängige Optionen. Begründen Sie Änderungen anhand gemessener Contention und nicht anhand einer pauschalen Maximalzahl.

### Typische Fehlinterpretation

Mehr Dateien lösen nicht jeden PAGELATCH-Wait; zu viele Dateien erhöhen Verwaltung/Recovery/Storage. Gleichheit beweist keine ausreichende Kapazität.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_CurrentTempDB`, Internal Contention, Current IO.

## Primärquellen

- [tempdb database](https://learn.microsoft.com/en-us/sql/relational-databases/databases/tempdb-database?view=sql-server-ver17)

[Technische Detailbeschreibung](../08_Server_Health.md#4-monitorusp_tempdbconfiguration)
