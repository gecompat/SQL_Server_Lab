# Hier beginnen: die passende Analyse finden

Diese Seite ist der kürzeste sichere Einstieg in SQL Server Analyze. Sie beginnt bei einer Beobachtung und führt zu einer geeigneten ersten Procedure. Ein technischer Objektname muss dafür nicht bekannt sein.

## Direkt im installierten Framework suchen

Der Analysis Navigator durchsucht deutsch- und englischsprachige Symptome, Ziele, Fachbegriffe und Procedurenamen. Er liest ausschließlich statische Frameworkmetadaten und führt keine gefundene Analyse aus.

```sql
EXEC [monitor].[USP_AnalysisNavigator]
      @Suchbegriff = N'Benutzer warten';
```

Ohne Suchbegriff zeigt er eine kurze, priorisierte Auswahl sicherer Einstiege:

```sql
EXEC [monitor].[USP_AnalysisNavigator];
```

Die wichtigsten Ergebnisspalten sind:

- `ProcedureName` und `DisplayName`: technischer und verständlicher Name;
- `WhyMatched`: warum die Procedure zur Eingabe passt;
- `NavigationRole`: Einstieg, Folgeanalyse, zielgerichtete Analyse, Setup oder Support;
- `ScopeCode` und `EvidenceType`: benötigter Untersuchungsumfang und Art der Evidenz;
- `CostRangeCode`, `AnalysisLevel` und `RequiresGroupGate`: Kosten- und Freigabekontext;
- `RequiresKnownTarget` und `RequiresHighImpactForSafeStart`: ob zuerst ein konkretes Ziel oder eine Bestätigung erforderlich ist;
- `SafeCall`: begrenzter erster Aufruf;
- `NextProcedureName`, `RelationType` und `NextStep`: fachlich begründete Folge- oder Gegenprobe;
- `IsInstalled` und `PackageCode`: lokale Verfügbarkeit und Paketgrenze;
- `RunbookPath` und `DocumentationPath`: vertiefende Dokumentation.

Der vollständige Such-, Bewertungs- und Ausgabevertrag steht in der [Navigator-Referenz](../Reference/Analysis_Navigator.md). Die [Procedure-Seite](Procedures/USP_AnalysisNavigator.md) erklärt Grenzen und Leserichtung.

## Schnellwahl nach Beobachtung

| Beobachtung oder Ziel | Sicherer erster Einstieg | Danach typischerweise | Vertiefung |
|---|---|---|---|
| Etwas ist **jetzt** langsam, ohne klaren Schwerpunkt | `USP_CurrentOverview` | auffälliges Teilergebnis gezielt wiederholen | [Live-Triage](02_Current_State.md) |
| Benutzer warten oder ein Request hängt | `USP_CurrentBlocking` | `USP_CurrentTransactions` | [Blocking-Runbook](Runbooks/01_User_Hangs_Blocking.md) |
| CPU ist aktuell hoch | `USP_CurrentRequests` | `USP_QueryStats`, danach Plan oder Query Store | [High-CPU-Runbook](Runbooks/02_High_CPU.md) |
| Eine Query wurde über Zeit langsamer | `USP_QueryStoreRegressions` | `USP_QueryStorePlanChanges` | [Regression-Runbook](Runbooks/03_Query_Regression.md) |
| Ein Showplan-XML liegt bereits vor | `USP_ExecutionPlanAnalysis` | Laufzeitevidenz oder Query Store gegenprüfen | [Plananalyse](../Architecture/Execution_Plan_Analysis_Design.md) |
| TempDB wächst oder läuft voll | `USP_CurrentTempDB` | `USP_TempDBConfiguration` | [TempDB-Runbook](Runbooks/04_TempDB_Growth.md) |
| Das Transaktionslog läuft voll | `USP_CurrentLog` | `USP_CurrentTransactions`, `USP_BackupRecovery` | [Log-Runbook](Runbooks/05_Transaction_Log_Full.md) |
| Requests warten auf Memory Grants | `USP_CurrentMemoryGrants` | `USP_ServerMemory`, anschließend Plananalyse | [Grant-Runbook](Runbooks/06_Memory_Grant_Queue.md) |
| I/O-Latenz oder Dateiproblem wird vermutet | `USP_CurrentIO` | `USP_CurrentRequests`, `USP_PerformanceCounters` | [I/O-Runbook](Runbooks/07_IO_Latency.md) |
| Ein Index erscheint ungenutzt | `USP_IndexUsage` | Query- und Planbezug prüfen | [Index-Runbook](Runbooks/08_Unused_Index.md) |
| Objekt, Index oder Statistik ist verdächtig | `USP_ObjectAnalysis` | spezialisierten Objektpfad auswählen | [Objektanalyse](03_Object_Index.md) |
| Backup- oder Integritätsrisiko | `USP_DatabaseIntegrityAnalysis` | `USP_BackupRecovery`, Restoreevidenz | [Backup-/Integrity-Runbook](Runbooks/09_Backup_Integrity_Risk.md) |
| Availability Group zeigt Lag | `USP_AvailabilityDeepAnalysis` | Logzustand und Infrastrukturpfad | [AG-Lag-Runbook](Runbooks/10_Availability_Group_Lag.md) |
| Agentjob schlägt fehl oder läuft zu lange | `USP_AgentJobs` | `USP_AgentMonitoringAnalysis` | [Infrastruktur](07_Infrastructure.md) |
| Servergrundzustand ist unklar | `USP_ServerHealthAnalysis` | Memory, Worker, Configuration oder Findings | [Server Health](08_Server_Health.md) |
| Datenbanken wachsen oder Volumes werden knapp | `USP_DatabaseCapacityAnalysis` | aktuelle I/O- und Wachstumsursache prüfen | [Server Health](08_Server_Health.md) |
| Deadlock liegt in Extended Events vor | `USP_ExtendedEventsDeadlocks` | aktuellen Blockingzustand gegenprüfen | [Extended Events](06_Extended_Events.md) |
| Backup, Agent, AG und Betrieb gemeinsam sichten | `USP_InfrastructureAnalysis` | betroffenen Infrastrukturpfad vertiefen | [Infrastruktur](07_Infrastructure.md) |
| SQL-Server-Build, CU oder Lifecycle prüfen | `USP_ServerVersionInformation` | `USP_ServerFeatureCapabilities` | [Versionsadaptive Analyse](09_Version_Adaptive.md) |
| Verwendete Spezialfeatures sind unbekannt | `USP_SpecialFeatureInventory` | nur das erkannte Feature vertiefen | [Spezialfeatures](09_Version_Adaptive.md) |

## Die Navigationsrollen

Der Katalog behandelt nicht jede öffentliche Procedure als gleichwertigen Einstieg:

| Rolle | Bedeutung | Erwartung vor dem Aufruf |
|---|---|---|
| `ENTRY` | sinnvoller erster Diagnoseaufruf für eine erkennbare Situation | Symptom, Ziel oder grober Scope genügt |
| `FOLLOW_UP` | vertieft oder bestätigt ein bereits sichtbares Signal | Ausgangsbefund und passende Gegenfrage kennen |
| `TARGETED` | untersucht ein bestimmtes Objekt, eine Query, Session, Datenbank oder ein Plan-XML | Ziel und Filter vorab festlegen |
| `SETUP` | prüft oder konfiguriert einen Framework- beziehungsweise Paketvertrag | Betriebsabsicht und Auswirkungen verstehen |
| `SUPPORT` | technische Hilfsschnittstelle, kein normaler Diagnoseeinstieg | nur nach dokumentiertem Aufrufvertrag verwenden |

Eine Procedure kann fachlich zu mehreren Situationen passen. Deshalb bleiben die SQL-Objekte im einheitlichen Schema `[monitor]`; Themen, Synonyme und Beziehungen bilden die Mehrfachzuordnung ab.

## In vier Schritten vom Treffer zur belastbaren Aussage

1. **Treffer prüfen.** `WhyMatched`, Scope, Voraussetzung, Paketstatus und sicheren Aufruf lesen. Ein nicht installiertes optionales Paket wird angezeigt, aber nicht ausgeführt.
2. **Beginnen Sie mit einem kleinen Scope.** Verwenden Sie `SafeCall` als Orientierung, setzen Sie Ziel und Filter bewusst und lesen Sie zunächst `CONSOLE`. Aktivieren Sie High-Impact-Pfade nur bei fachlichem Bedarf und mit expliziter Bestätigung.
3. **Status vor Fachwerten lesen.** In `RAW` zuerst `StatusCode`, `IsPartial`, Zeilenlimit, Berechtigungs- und Quellenstatus prüfen. Eine leere oder partielle Ausgabe ist keine automatische Entwarnung.
4. **Unabhängig bestätigen.** `NextProcedureName` und `RelationType` nutzen. `REFINE_WITH` vertieft dasselbe Signal, `CONFIRM_WITH` liefert eine andere Evidenz, `ALTERNATIVE_TO` bietet einen anderen Zugang und `PREPARE_WITH` stellt eine Voraussetzung her.

## Suche eingrenzen

Bereiche, Scopes und Rollen lassen sich unabhängig vom Suchtext kombinieren:

```sql
EXEC [monitor].[USP_AnalysisNavigator]
      @Suchbegriff = N'Latenz',
      @Bereich = 'OPERATIONS',
      @Navigationsrolle = 'ENTRY',
      @MaxZeilen = 10;
```

Der folgende Aufruf beschränkt die Anzeige auf lokal installierte Procedures:

```sql
EXEC [monitor].[USP_AnalysisNavigator]
      @Scope = 'PLAN_XML',
      @NurInstallierte = 1;
```

Der Standardwert `@NurInstallierte = 0` liefert bewusst den vollständigen Katalog, damit optionale Pakete auffindbar bleiben. Prüfen Sie vor einem Aufruf immer `IsInstalled`.

## Wenn kein Treffer erscheint

`NO_MATCH` bedeutet ausschließlich, dass Suchtext und aktive Filter keine Katalogzeile ergaben. Dann:

1. Verkürzen Sie den Suchbegriff, beispielsweise auf `blocking`, `CPU`, `TempDB`, `Plan`, `Backup`, `Deadlock` oder `AG Lag`.
2. Entfernen Sie Filter oder lesen Sie gültige Codes direkt aus `monitor.VW_AnalysisCatalog`.
3. Navigieren Sie in der [vollständigen Procedure-Übersicht](Procedures/README.md) nach Bereich.
4. Verwenden Sie für ein bekanntes Symptom das [Runbook-Verzeichnis](Runbooks/README.md).
5. Öffnen Sie für technische Objekte den [vollständigen Objektindex](Object_Index.md).

## Weiterführende Leserichtung

- [Einsteiger-Leseleitfaden](Beginner_Reading_Guide.md): Resultsets korrekt lesen.
- [Parameter-Lesehilfe](Parameter_Reading_Guide.md): Filter, Limits, Ausgabearten und sichere Aufrufe.
- [Gemeinsame Verträge](Common_Contracts.md): Status, Partialität, Zeitbezug und Kostenmodell.
- [Technische Grundlagen](Technical_Foundations.md): Evidenz-, Reset-, Scope- und Gegenprobenmodell.
- [Procedure-Referenz](../Reference/Procedure_Reference.md): vollständige Signaturen und Defaults.
- [Objektreferenz](../Reference/Object_Reference.md): alle Views, TVFs, internen Procedures und Tabellen.
