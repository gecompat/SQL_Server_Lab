# [monitor].[USP_OSInformation]

**Bereich:** Server Health<br>
**Zweck:** Zeigt Betriebssystem, Virtualisierung, Speicher, Zeit, Uptime und Plattformgrenzen.<br>
**Beobachtungsart:** Snapshot<br>
**Kostenklasse:** LOW

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Betriebssystem-, Host-, Virtualisierungs- und Ressourceninformationen sieht SQL Server?** Sie unterstützt die Entscheidung, ob eine Instanzressource oder Konfiguration als belastbare Spur zum Symptom passt und welche unabhängige OS-, Verlaufs- oder Workloadevidenz fehlt.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige OS-/Hypervisorursache und ohne Delta oder Verlauf keine belastbare Aussage über einen dauerhaften Engpass. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_OSInformation]
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `host`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset beschreibt eine Zeile eine OS-/Plattformeigenschaft oder eine Zusammenfassung.

## So lesen

Berücksichtigen Sie OS-Version, Virtualisierung, Speicher, Zeit, Uptime und Plattform gemeinsam.

## Warum kann das problematisch sein?

Sehr geringe Uptime erklärt resetete DMVs; Zeitabweichungen erschweren Ereigniskorrelation; Memory-/VM-Grenzen beeinflussen SQL.

## Wann ist es kein Problem?

Virtualisierung ist nicht automatisch langsam.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Index Usage zeigt 0 Reads, OS Uptime zwei Stunden: Beobachtungsfenster zu kurz für eine Löschung. Korrelieren Sie CPU, Memory, I/O und Hypervisor-Monitoring.

**Ähnlich aussehender Gegenfall:** Virtualisierung ist nicht automatisch langsam. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Server-DMVs können plattform-, editions- oder berechtigungsbedingt fehlen. NULL und PARTIAL sind dann Evidenzgrenzen, keine Nullmessung.

Für `USP_OSInformation` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW |
| Standardpfad | Liest vier unabhängige Quellen: Host, OS-Speicher, SQL-Prozessspeicher und Dienststatus. Jede Quelle hat eigenen Status, sodass fehlende Serviceberechtigung die Memorysicht nicht verdeckt. |
| Teuerster Pfad | Kein Deep-Pfad. RAW/JSON geben alle vier kleinen Resultsets plus SourceStatus aus; die Zahl SQL-bezogener Dienste ist gewöhnlich einstellig. |
| Haupttreiber | Feste Ein-Zeilen-DMVs und Zahl der SQL-Dienste in `sys.dm_server_services`. Datenbanken, Sessions und OS-Prozesse außerhalb SQL Server werden nicht enumeriert. |
| Skalierung | Praktisch konstant pro Instanz. Serialisierung wächst gering mit Dienstzeilen; Memorygröße beeinflusst nur Werte, nicht Abfragearbeit. |
| Ressourcen | Vier kurze SQLOS-/Service-DMV-Lesezugriffe und kleine Temp-Tabellen. Kein WMI, Registryscan, Dateisystem-I/O oder WAITFOR. |
| Begrenzungswirkung | Kein Scope-/Zeilenlimit nötig. `NONE` unterdrückt Resultsets, die vier Quellen werden für Status/JSON-Vertrag weiterhin versucht. |
| Locking und Nebenwirkungen | Read-only ohne Nutzdatenlocks. Speicherzustand und Dienststatus sind getrennte Momentaufnahmen; partieller SourceStatus ist erwartbarer als ein Abbruch des Gesamtmoduls. |
| Schutzmechanismus | Kein Gate und kein Scopeparameter. Die Procedure ist durch vier fest gewählte SQL-seitige Quellen mit eigener Statusbehandlung begrenzt; sie startet weder WMI-/Shellaufrufe noch eine Enumeration fremder Prozesse oder Dateisysteme. |
| Sicherer Einsatz | CONSOLE direkt nutzen; Dienstkonto, Prozess-ID und Hostdetails aus RAW/JSON nur im geschützten Betriebskontext teilen. SourceStatus je Teilquelle mit speichern. |
| Aussagegrenze | Die Procedure zeigt SQL-seitig sichtbare OS-/Prozesswerte, keine vollständige Hosttelemetrie, VM-Steal-Time oder Containerlimits. Ein momentaner Low-Memory-Flag benötigt Verlauf und OS-Gegenprobe. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Betriebssystem-, Host-, Virtualisierungs- und Ressourceninformationen sieht SQL Server?

### Technischer Hintergrund

Host-/Windows-/Linux-DMVs liefern OS-Version, Hostplattform, Memory/Pagefile, Startzeit und Virtualization/Containerhinweise soweit verfügbar. SQL Server sieht im Gast nicht zwingend Hypervisor-Steal, SAN- oder Hostcontention vollständig.

### Datenkette

`sys.dm_os_host_info`, `sys.dm_os_process_memory`, `sys.dm_os_sys_memory`, `sys.dm_server_services`.

### Source Select

Die wichtigsten Host-, System- und Prozessspeicherwerte sind jeweils Singleton-DMVs und können ohne Nutzdatenjoin kombiniert werden:

```sql
SELECT
      [h].[host_platform]
    , [h].[host_distribution]
    , [sm].[total_physical_memory_kb]
    , [sm].[available_physical_memory_kb]
    , [pm].[physical_memory_in_use_kb]
    , [pm].[process_physical_memory_low]
FROM [sys].[dm_os_host_info] AS [h] WITH (NOLOCK)
CROSS JOIN [sys].[dm_os_sys_memory] AS [sm] WITH (NOLOCK)
CROSS JOIN [sys].[dm_os_process_memory] AS [pm] WITH (NOLOCK);
```

**Wichtig für die Eigenlast:** Diese Quellen liefern wenige Zeilen. Dienstinformationen aus `sys.dm_server_services` sind ein getrennter kleiner Zweig; es werden keine OS-Dateien oder externen Befehle ausgeführt.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Gast-/Instanzkontext; OS-/Engine-Startzeiten können verschieden sein.

### Bewertung und Gegenprobe

Korrelieren Sie Betriebssystem- und Buildsupport, virtuelle beziehungsweise physische Plattform, Memory und Commit, Pagefile, Uptime und Instanzbuild. Ergänzen Sie für eine Performanceanalyse CPU-, Storage- und Memorytelemetrie außerhalb von SQL Server.

### Typische Fehlinterpretation

Unauffällige Gastwerte schließen Hostengpass nicht aus. Pagefile vorhanden/benutzt ist allein keine SQL-Memorydiagnose.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Server CPU/Memory/IO und OS-/Hypervisormonitoring.

## Primärquellen

- [sys.dm_os_host_info](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-host-info-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../08_Server_Health.md#8-monitorusp_osinformation)
