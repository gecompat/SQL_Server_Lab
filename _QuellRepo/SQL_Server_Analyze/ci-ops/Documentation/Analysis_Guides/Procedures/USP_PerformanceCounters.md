# [monitor].[USP_PerformanceCounters]

**Bereich:** Server Health<br>
**Zweck:** Liest typisierte SQL-Server-Performance-Counter und berechnet bei Bedarf Sample-/Delta-Werte.<br>
**Beobachtungsart:** kumulative Datei-/Counterwerte + optionale Stichprobe<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Wie werden SQL-Server-Performance-Counter korrekt als Raw, Ratio, Rate oder Delta interpretiert?** Sie unterstützt die Entscheidung, ob eine Instanzressource oder Konfiguration als belastbare Spur zum Symptom passt und welche unabhängige OS-, Verlaufs- oder Workloadevidenz fehlt.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige OS-/Hypervisorursache und ohne Delta oder Verlauf keine belastbare Aussage über einen dauerhaften Engpass. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_PerformanceCounters]
      @SampleSeconds = 5,
      @MaxZeilen = 100,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `counters`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einem Counter beziehungsweise einer normalisierten Countermessung für eine Instanzbezeichnung.

## So lesen

`UNAVAILABLE_OBJECT` mit `IsPartial=1` bedeutet, dass die Instanz keine aktivierten oder nach Ausschluss alleinstehender Basiscounter keine auswertbaren Zeilen aus `sys.dm_os_performance_counters` bereitstellt. In diesem Zustand werden weder Snapshotwerte noch Raten synthetisiert.

Objektname, Countername und Instanzname allein sind nicht die vollständige technische Identität: `cntr_type` gehört zum Schlüssel. Gleich benannte Zeilen unterschiedlicher Typen werden deshalb getrennt gesampelt und nicht miteinander verrechnet.

Die reine Funktion `monitor.TVF_InterpretPerformanceCounter` kapselt denselben Rechenpfad. Sie ermöglicht einen deterministischen Resetnachweis mit fallendem Vorher-/Nachher-Wert, ohne einen Serverneustart während einer laufenden Procedure zu simulieren.

Unterscheiden Sie Countertyp, Raw Value, Base, Delta, Samplezeit und normalisierten Wert.

## Warum kann das problematisch sein?

Rate- und Fraction-Counter werden ohne Typ/Base schnell falsch interpretiert. Kumulative Rohwerte spiegeln oft nur Uptime wider.

## Wann ist es kein Problem?

Ein einzelner hoher kumulativer Wert oder eine alte Faustregel ohne Baseline ist keine Diagnose.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Page Life Expectancy besitzt keine universelle feste Grenze. Ein abrupter Einbruch plus Memory Pressure und I/O ist relevanter als ein einzelner Wert. Prüfen Sie Memory, I/O und Workload.

**Ähnlich aussehender Gegenfall:** Ein einzelner hoher kumulativer Wert oder eine alte Faustregel ohne Baseline ist keine Diagnose. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Server-DMVs können plattform-, editions- oder berechtigungsbedingt fehlen. NULL und PARTIAL sind dann Evidenzgrenzen, keine Nullmessung.

Für `USP_PerformanceCounters` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Mit Default `@SampleSeconds = 0` werden zwei unmittelbar aufeinanderfolgende Snapshots der ausgewählten Counter aufgenommen und typabhängig interpretiert; es gibt kein WAITFOR. Kumulative Counter bleiben kumulativ, Rate-/Bruchtypen benötigen für belastbare Werte ein echtes Sample. |
| Teuerster Pfad | Alle Counter/Instanzen, 60 Sekunden und unbegrenzte Ausgabe. Die gefilterte Countermenge wird zweimal gelesen; parallele Aufrufe halten jeweils eine Session und duplizieren die Snapshotarbeit. |
| Haupttreiber | Anzahl ausgewählter `(object_name, counter_name, instance_name)`-Kombinationen. Objekt-/Counternamen filtern bereits den ersten Snapshot; benötigte `base`-Counter werden automatisch mit aufgenommen. |
| Skalierung | Der zweite Snapshot joint nur auf die im ersten gefundenen Schlüssel. Berechnung und Speicher wachsen daher mit der gefilterten Countermenge; Sampledauer erhöht die Verbindungszeit linear, nicht die Anzahl der Counter. |
| Ressourcen | Zwei Lesezugriffe auf `sys.dm_os_performance_counters`, ein kleiner Startzeitlookup, Temp-Tabellen und CPU für typabhängige Delta-/Ratiointerpretation; optional eine wartende Verbindung. |
| Begrenzungswirkung | Objekt-/Counterlisten reduzieren die Quellmenge wirksam. `@MaxZeilen` wird dagegen erst bei RAW/CONSOLE/JSON/TABLE-Ausgabe angewandt und spart weder Snapshots noch Counterinterpretation. |
| Locking und Nebenwirkungen | Read-only. WAITFOR hält keine Nutzdatenlocks absichtlich, belegt aber die Session. Restart oder Counterrückgang zwischen den Messpunkten wird als Resetkontext behandelt; die Procedure setzt keine Counter zurück. |
| Schutzmechanismus | Kein High-Impact-Gate. Objekt-/Counterlisten reduzieren beide Snapshots früh und `@SampleSeconds` ist auf 60 begrenzt; `@MaxZeilen` ist ausdrücklich nur ein Ausgabelimit. Mehrere parallele Sampler werden durch die Procedure nicht zentral verhindert. |
| Sicherer Einsatz | Fünf Sekunden, `@MaxZeilen = 100`, möglichst konkrete Objekt-/Counternamen und nur ein Sampler. Für eine Baseline mehrere getrennte Intervalle mit identischem Filter erfassen. |
| Aussagegrenze | Ein Rohwert ohne Countertyp/Base ist nicht interpretierbar. Kurze Samples können Bursts überbetonen, lange Samples Spitzen glätten. Das Ausgabelimit ist keine repräsentative Stichprobe und kann zusammengehörige Zähler-/Basezeilen unterschiedlich sichtbar machen. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Wie werden SQL-Server-Performance-Counter korrekt als Raw, Ratio, Rate oder Delta interpretiert?

### Technischer Hintergrund

`sys.dm_os_performance_counters` enthält Counter mit `cntr_type`. Manche sind Momentwerte, manche kumulative Zähler, manche benötigen Basecounter und manche Differenz/Zeit. Instanznamen trennen Total, DB, Buffer Node oder Objektinstanzen.

### Datenkette

`sys.dm_os_performance_counters`, `sys.dm_os_sys_info`.

### Source Select

Der direkte Grundzugriff liest nur die benötigten Counter- und Instanznamen:

```sql
SELECT
      [pc].[object_name]
    , [pc].[counter_name]
    , [pc].[instance_name]
    , [pc].[cntr_value]
    , [pc].[cntr_type]
FROM [sys].[dm_os_performance_counters] AS [pc] WITH (NOLOCK)
WHERE [pc].[counter_name] IN
      (N'Page life expectancy',
       N'Batch Requests/sec',
       N'Page reads/sec')
  AND [pc].[instance_name] IN (N'', N'_Total');
```

**Wichtig für die Eigenlast:** Counter- und Instanzlisten in der DMV-Abfrage anwenden. Base-Counter und zwei Messpunkte nur für Countertypen lesen, die diese Berechnung benötigen; `@MaxZeilen` ist sonst lediglich ein Ausgabelimit.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Rohstand oder ein Frameworksample; der Resetzeitpunkt entspricht typischerweise dem Engine-Start.

### Bewertung und Gegenprobe

Prüfen Sie zuerst den Countertyp. Bewerten Sie eine Ratio mit der passenden Base, eine Rate als Delta pro Zeit und kumulative Counter zusammen mit der Uptime. Dokumentieren Sie Instance Name und Units. Verwenden Sie mehrere Counter als zusammenhängende Evidenzkette.

### Typische Fehlinterpretation

Raw `cntr_value` ist nicht allgemein Prozent oder pro Sekunde. Basecounter aus anderer Instanz/Probe erzeugt falsche Ratio.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Server Memory/CPU/IO, Current State und OS-Counter.

## Primärquellen

- [sys.dm_os_performance_counters](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-performance-counters-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../08_Server_Health.md#13-monitorusp_performancecounters)
