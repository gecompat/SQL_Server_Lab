# [monitor].[USP_TraceFlags]

**Bereich:** Server Health<br>
**Zweck:** Inventarisiert aktive globale und sessionbezogene Trace Flags.<br>
**Beobachtungsart:** Snapshot<br>
**Kostenklasse:** LOW

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche globalen oder sessionbezogenen Trace Flags sind aktiv und welche Engineverhaltensänderung ist damit verbunden?** Sie unterstützt die Entscheidung, ob eine Instanzressource oder Konfiguration als belastbare Spur zum Symptom passt und welche unabhängige OS-, Verlaufs- oder Workloadevidenz fehlt.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige OS-/Hypervisorursache und ohne Delta oder Verlauf keine belastbare Aussage über einen dauerhaften Engpass. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_TraceFlags]
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `traceFlags`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einem aktiven Trace Flag und seinem Scope.

## So lesen

Prüfen Sie Flagnummer, global/session Scope, Aktivierungsquelle, Version und dokumentierte Bedeutung.

## Warum kann das problematisch sein?

Undokumentierte oder veraltete Flags können Optimizer- oder Engineverhalten unerwartet verändern.

## Wann ist es kein Problem?

Dokumentierte Flags können bewusste Workarounds oder Diagnosehilfen sein.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Ein altes Kompatibilitätsflag nach Upgrade kann neue Standardverbesserungen überdecken. Prüfen Sie Startup Parameters, Microsoft-Dokumentation und Changehistorie.

**Ähnlich aussehender Gegenfall:** Dokumentierte Flags können bewusste Workarounds oder Diagnosehilfen sein. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Server-DMVs können plattform-, editions- oder berechtigungsbedingt fehlen. NULL und PARTIAL sind dann Evidenzgrenzen, keine Nullmessung.

Für `USP_TraceFlags` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW |
| Standardpfad | Führt genau einmal `DBCC TRACESTATUS(-1) WITH NO_INFOMSGS` aus und gibt die aktiven globalen/sessionbezogenen Flags aus. CONSOLE, RAW, TABLE und JSON projizieren dieselbe materialisierte kleine Quelle. |
| Teuerster Pfad | Gegenüber dem Standard gibt es keinen tieferen Quellpfad; zusätzliche Ausgabeformate erhöhen nur Serialisierung und Transfer der bereits ermittelten Flagzeilen. |
| Haupttreiber | Anzahl aktuell aktiver Trace Flags. Es werden weder Konfigurationskataloge noch Scheduler-DMVs, Startupdateien oder Datenbankobjekte gescannt. |
| Skalierung | Die DBCC-Ausgabe ist instanzweit und gewöhnlich sehr klein. Sortierung nach Flagnummer und JSON-/TABLE-Ausgabe wachsen linear mit den aktiven Flags. |
| Ressourcen | Geringe CPU und eine kleine Temp-Tabelle für die vier DBCC-Spalten `TraceFlag`, `Status`, `GlobalFlag`, `SessionFlag`. |
| Begrenzungswirkung | Die Procedure besitzt weder Scopefilter noch `@MaxZeilen`; es wird absichtlich die vollständige aktive Flagliste ausgegeben. `@ResultSetArt = 'NONE'` unterdrückt Ausgabe, spart aber den DBCC-Aufruf nicht. |
| Locking und Nebenwirkungen | `DBCC TRACESTATUS` liest nur Zustand und aktiviert/deaktiviert kein Flag. Es werden keine Nutzdatenlocks absichtlich gehalten; die Flagkonfiguration kann sich unmittelbar nach dem Snapshot ändern. |
| Schutzmechanismus | Kein Gate und kein Limit. Der Quellvertrag ist konstruktiv auf genau einen read-only `DBCC TRACESTATUS(-1)`-Aufruf begrenzt; die Procedure setzt oder löscht keine Trace Flags. Ausgabeunterdrückung ist kein Quellkostenschutz. |
| Sicherer Einsatz | CONSOLE im Standardpfad und Status zuerst lesen. Die Ausgabe enthält Flagnummer und Scope, aber keine Pfade, SQL-Texte oder Konfigurationswerte. |
| Aussagegrenze | Der Snapshot zeigt nur aktive Flags und erklärt weder ihren Zweck noch, ob sie per Startup, globalem DBCC oder Session gesetzt wurden. Für Supportstatus und Wirkung sind SQL-Version, Scope und separate Startparameter-/Konfigurationsquellen nötig. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche globalen oder sessionbezogenen Trace Flags sind aktiv und welche Engineverhaltensänderung ist damit verbunden?

### Technischer Hintergrund

Trace Flags aktivieren Diagnose- oder Verhaltenspfade auf globaler/sessionbezogener Scope. Manche wurden durch Database Scoped Configurations oder neuere Defaults ersetzt; Supportstatus ist versionsabhängig. Startupparameter können globale Flags früh setzen.

### Datenkette

`DBCC TRACESTATUS(-1)` → Temp-Tabelle → nach Flagnummer sortierte
CONSOLE-/RAW-/TABLE-/JSON-Projektion. Es gibt keine Childmodule.

### Source Select

Kein `SELECT` auf eine DMV: Die Engine stellt aktive Trace Flags über einen DBCC-Befehl bereit. Der direkte Quellaufruf lautet:

```sql
DBCC TRACESTATUS(-1) WITH NO_INFOMSGS;
```

Die Procedure fängt dieses Resultset in einer lokalen Temp-Tabelle ab und projiziert es sortiert in die Ausgabeformate.

**Wichtig für die Eigenlast:** Der Befehl liefert nur aktive globale und sessionbezogene Flags und ändert keinen Zustand. Es existiert kein serverseitiger Flagfilter; Filterung erfolgt erst nach der kleinen DBCC-Ausgabe.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Runtimezustand. Sessionflags gelten nur im jeweiligen Kontext; globale Flags gelten bis zur Deaktivierung oder zum Neustart.

### Bewertung und Gegenprobe

Prüfen Sie Flagnummer, Scope, Startupbezug, dokumentierter Zweck, Version und aktuelle Notwendigkeit. Behandeln Sie undokumentierte Flags besonders vorsichtig.

### Typische Fehlinterpretation

Aktiv heißt nicht, dass jeder Workloadpfad betroffen ist. Ein früher notwendiges Flag kann nach Upgrade redundant oder schädlich sein.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_StartupParameters`, Server Configuration und offizielle versionsspezifische Dokumentation.

## Primärquellen

- [DBCC TRACESTATUS](https://learn.microsoft.com/en-us/sql/t-sql/database-console-commands/dbcc-tracestatus-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../08_Server_Health.md#6-monitorusp_traceflags)
