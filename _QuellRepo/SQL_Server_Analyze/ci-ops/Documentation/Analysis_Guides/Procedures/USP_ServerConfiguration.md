# [monitor].[USP_ServerConfiguration]

**Bereich:** Server Health<br>
**Zweck:** Zeigt konfigurierte und aktive Serveroptionen mit Bewertungscontext.<br>
**Beobachtungsart:** Katalogsnapshot<br>
**Kostenklasse:** LOW

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Serveroptionen weichen von Default/Empfehlung ab und welche Werte sind tatsächlich aktiv?** Sie unterstützt die Entscheidung, ob eine Instanzressource oder Konfiguration als belastbare Spur zum Symptom passt und welche unabhängige OS-, Verlaufs- oder Workloadevidenz fehlt.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige OS-/Hypervisorursache und ohne Delta oder Verlauf keine belastbare Aussage über einen dauerhaften Engpass. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ServerConfiguration]
      @NurKernparameter = 1,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `configuration`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einer Serverkonfigurationsoption.

## So lesen

Vergleichen Sie Configured Value, Run Value, Dynamic/Advanced-Status, Default und Beschreibung.

## Warum kann das problematisch sein?

Abweichende Run Values können ausstehendes Reconfigure/Restart anzeigen; extreme Werte können Ressourcen falsch begrenzen.

## Wann ist es kein Problem?

Abweichung vom Default ist kein Fehler. Produktive Systeme benötigen oft bewusste Anpassungen.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Niedriges max server memory kann absichtlich Speicher für andere Dienste reservieren. Prüfen Sie erst OS-, Workload- und Memorykontext.

**Ähnlich aussehender Gegenfall:** Abweichung vom Default ist kein Fehler. Produktive Systeme benötigen oft bewusste Anpassungen. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Server-DMVs können plattform-, editions- oder berechtigungsbedingt fehlen. NULL und PARTIAL sind dann Evidenzgrenzen, keine Nullmessung.

Für `USP_ServerConfiguration` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW |
| Standardpfad | `@NurKernparameter = 1` liest eine feste Liste betriebsrelevanter Optionen und eine Schedulerzahl für Kontext/Findinglogik. Konfigurierter und aktiver Wert werden gemeinsam ausgegeben. |
| Teuerster Pfad | `@NurKernparameter = 0` liest alle Zeilen aus `sys.configurations`; auch das bleibt ein kleiner Serverkatalog ohne Child- oder Historienpfad. |
| Haupttreiber | Anzahl der Serverkonfigurationsoptionen. Die Procedure liest keine `sp_configure`-Änderungshistorie und keine Database-Scoped Configurations. |
| Skalierung | Linear mit wenigen hundert Konfigurationszeilen; CASE-Bewertung und Sortierung sind gering. Resultgröße ist unabhängig von Datenbank-/Workloadgröße. |
| Ressourcen | Eine SQLOS-Infozeile, ein Serverkatalogscan und eine kleine Temp-Tabelle. Kein `RECONFIGURE`, XML, Sampling oder Cross-Database-SQL. |
| Begrenzungswirkung | Der Kernparameter-Schalter reduziert Quelle und Ausgabe fachlich; ein Max-Rows-Parameter existiert nicht. `NONE` unterdrückt nur Resultsets, nicht die Erhebung. |
| Locking und Nebenwirkungen | Read-only. Werte können zwischen `dm_os_sys_info` und `sys.configurations` geändert werden; die Procedure selbst setzt keine Option und führt kein `RECONFIGURE` aus. |
| Schutzmechanismus | Kein Gate. `@NurKernparameter = 1` ist der einzige fachliche Scope und hält Quelle wie Ausgabe bei der fest definierten Kernliste; auch der Vollpfad bleibt ein read-only Scan von `sys.configurations` ohne Konfigurationsänderung. |
| Sicherer Einsatz | Mit `@NurKernparameter = 1` starten; erst für ein Konfigurationsaudit auf alle Optionen erweitern. Ausgabe enthält keine Kennwörter oder Dateipfade. |
| Aussagegrenze | Ein Finding markiert Reviewbedarf, nicht automatisch Fehlkonfiguration. Edition, Workload, NUMA, verfügbare RAM-/CPU-Ressourcen und Änderungsfenster müssen separat berücksichtigt werden. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Serveroptionen weichen von Default/Empfehlung ab und welche Werte sind tatsächlich aktiv?

### Technischer Hintergrund

`sys.configurations` besitzt configured `value` und `value_in_use`, Dynamic/Advanced Flags. Manche Änderungen greifen sofort, andere nach RECONFIGURE oder Restart. Optionen beeinflussen Parallelität, Memory, Security, Remotezugriff und Engineverhalten.

### Datenkette

`sys.configurations`, `sys.dm_os_sys_info`.

### Source Select

Der Konfigurationskern liest dokumentierten und aktiven Wert direkt aus `sys.configurations`:

```sql
SELECT
      [c].[configuration_id]
    , [c].[name]
    , [c].[value]
    , [c].[value_in_use]
    , [c].[is_dynamic]
    , [c].[is_advanced]
FROM [sys].[configurations] AS [c] WITH (NOLOCK)
WHERE [c].[name] IN
      (N'max server memory (MB)',
       N'max degree of parallelism',
       N'cost threshold for parallelism');
```

**Wichtig für die Eigenlast:** Die Quelle ist klein. Konfigurationsnamen bereits im Quellselect begrenzen; die Procedure liest nur und führt weder `sp_configure` noch `RECONFIGURE` aus.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Konfigurationsstand; einige Änderungen an `value` sind noch nicht in use.

### Bewertung und Gegenprobe

Berücksichtigen Sie Configured und In Use, Is Dynamic, Is Advanced, Version und Edition, Workload und Änderungsgrund gemeinsam. Priorisieren Sie Abweichungen, korrigieren Sie diese jedoch nicht automatisch.

### Typische Fehlinterpretation

Der Standardwert ist nicht in jedem Kontext geeignet, und eine bekannte Empfehlung gilt nicht universell. Mehrere Optionen interagieren, etwa MAXDOP mit Cost Threshold oder Max Memory mit der Betriebssystemreserve.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Spezifische Topologie-/Memory-/Securitymodule und kontrolliertes Changeverfahren.

## Primärquellen

- [sys.configurations](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-configurations-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../08_Server_Health.md#5-monitorusp_serverconfiguration)
