# [monitor].[USP_AnalysisNavigator]

**Bereich:** Einstieg und Orientierung<br>
**Zweck:** Findet priorisierte Framework-Procedures nach Symptom, Ziel, Scope, Fachbegriff oder technischem Namen, ohne eine Diagnose auszuführen.<br>
**Beobachtungsart:** statische Frameworkmetadaten und lokale Installationssicht<br>
**Kostenklasse:** `LOW`

## Entscheidungsfrage und Einsatz

Diese Procedure beantwortet: **Welche vorhandene Analyse passt zu meiner Beobachtung, womit beginne ich sicher und welche zweite Auswertung kann den Befund vertiefen oder unabhängig bestätigen?** Sie ist der bevorzugte Einstieg, wenn die fachliche Situation bekannt ist, aber kein Procedurename. Typische Eingaben sind `Benutzer warten`, `CPU hoch`, `query regression`, `TempDB wächst`, `Plan XML`, `Deadlock`, `AG Lag`, `Backup` oder ein bereits bekannter Objektname.

Ohne Suchtext liefert der Navigator eine kurze, kuratierte Startliste. Mit `@Bereich`, `@Scope` oder `@Navigationsrolle` kann der Benutzer die Objektlandschaft systematisch durchsuchen. Die Ausgabe verbindet verständlichen Anzeigenamen, technische Procedure, Rolle, Scope, Evidenzart, Kostenband, repräsentative Analyseklasse, Voraussetzung, Paketstatus, sicheren Beispielaufruf und eine begründete Folgebeziehung.

Der Navigator ist bewusst nur ein Wegweiser. Er führt weder den ersten Treffer noch irgendeine Folgeprocedure aus. Dadurch ist eine Suche nach einem Begriff kein versteckter Live-Snapshot, kein Plan-Cache-Zugriff und kein Cross-Database-Lauf.

## Nicht beantwortete Fragen

Der Navigator diagnostiziert keine SQL-Server-Störung. `RelevanceScore` ist keine Schwere, keine Konfidenz der Root Cause und keine Messung der aktuellen Instanz. `IsInstalled = 1` beweist nur, dass die öffentliche Procedure lokal unter `[monitor]` existiert; der Wert beweist nicht, dass der aktuelle Login alle benötigten Quellen lesen darf oder dass Query Store, Extended Events, Availability Groups oder ein Spezialfeature verfügbar sind.

`RepresentativeAnalysisClass`, `AnalysisLevel` und `RequiresGroupGate` beschreiben einen repräsentativen Kostenpfad. Viele Ziel-Procedures besitzen abhängig von Detailparametern mehrere Pfade. Der Navigator ersetzt deshalb weder den `@Hilfe=1`-Vertrag noch die Laufzeitprüfung einer Ziel-Procedure. Auch `SafeCall` ist ein begrenzter Einstieg, keine universell passende Produktionsanweisung. Datenbank-, Objekt-, Session-, Zeit- und Planfilter müssen bewusst an die reale Fragestellung angepasst werden.

Die Procedure bewertet nicht, ob eine vorgeschlagene Änderung fachlich zulässig ist. Sie führt kein `KILL`, DDL, Plan Forcing, Failover, Repair oder Setup aus.

## Sicherer Einstieg

Führen Sie eine freie Symptomsuche mit folgendem Aufruf aus:

```sql
EXEC [monitor].[USP_AnalysisNavigator]
      @Suchbegriff = N'Benutzer warten',
      @MaxZeilen = 8,
      @ResultSetArt = 'CONSOLE';
```

Rufen Sie mit folgendem Beispiel die wichtigsten Startpunkte ab:

```sql
EXEC [monitor].[USP_AnalysisNavigator]
      @NurInstallierte = 1,
      @ResultSetArt = 'CONSOLE';
```

Führen Sie mit folgendem Beispiel eine technische Bereichssuche ohne fachliche Quellabfrage aus:

```sql
EXEC [monitor].[USP_AnalysisNavigator]
      @Bereich = 'QUERY_STORE',
      @Navigationsrolle = 'ENTRY',
      @NurInstallierte = 0,
      @MaxZeilen = 20,
      @ResultSetArt = 'RAW';
```

`@NurInstallierte = 0` ist der vollständige Katalogmodus und zeigt auch optionale Paketobjekte. Prüfen Sie vor dem Kopieren eines Aufrufs deshalb `IsInstalled`. Der Navigator verwendet ausschließlich synthetische Beispiele in `SafeCall`; dort angezeigte Platzhalter wie `[ExampleDatabase]`, `[ExampleSchema]` oder `[ExampleObject]` müssen bewusst ersetzt werden.

## Resultsets und Leserichtung

`CONSOLE` liefert genau die beschriftete Treffermenge `navigation`. Bei einer gültigen Suche ohne Treffer erscheint eine verständliche Leerzeile mit `NO_MATCH`. `RAW` liefert zuerst den Modulstatus und danach das native Resultset `navigation`. `TABLE` exportiert ausschließlich `navigation` in die unter `@ResultTablesJson` zugeordnete lokale Temp-Tabelle. `NONE` unterdrückt alle Resultsets. `@JsonErzeugen = 1` liefert `meta` und `navigation` aus derselben Materialisierung.

Berücksichtigen Sie im RAW-Status zuerst `StatusCode`, `IsPartial`, `ErrorNumber`, `ErrorMessage` und die normalisierten Filter. Interpretieren Sie erst danach die Treffer. `INVALID_PARAMETER` unterscheidet sich von `NO_MATCH`: Im ersten Fall war ein Wert wie Bereich, Scope, Rolle, Zeilenlimit oder Suchtextlänge ungültig; im zweiten Fall war die Anfrage gültig, aber die Schnittmenge leer.

## Eine Zeile bedeutet

Eine Zeile in `navigation` ist genau ein priorisierter Vorschlag für eine öffentliche Framework-Procedure. Sie ist kein ausgeführter Diagnosebefund, kein gemessener SQL-Server-Zustand und keine automatisch bestätigte Kausalkette.

`Rank` nummeriert die aktuelle Ergebnismenge. `RelevanceScore` entsteht aus exakten Namens-, Anzeigenamen- und Suchbegriffstreffern, Teilphrasen, wesentlichen Tokens und einem kleinen Rollenbonus. Der Score ist nur innerhalb desselben Aufrufs sinnvoll. Filter- oder Katalogänderungen können Rang und Score verändern.

`NavigationRole` trennt sichere Einstiege von Folge-, Target-, Setup- und Supportpfaden. `NextProcedureName` ist höchstens eine priorisierte Relation. Weitere Relationen können in `VW_AnalysisRelation` vorhanden sein. `RelationType` beschreibt, ob die nächste Procedure vertieft, bestätigt, einen alternativen Evidenzpfad anbietet oder eine Voraussetzung vorbereitet.

## So lesen

1. **Treffergrund:** Berücksichtigen Sie `WhyMatched`. Ein exakter Symptomtreffer ist aussagekräftiger als eine Übereinstimmung nur über einen allgemeinen Bereichsbegriff.
2. **Rolle:** `ENTRY` eignet sich für den ersten Aufruf. `FOLLOW_UP` erwartet bereits ein Signal. `TARGETED` benötigt ein bekanntes Ziel. `SETUP` hat eine Betriebswirkung oder prüft einen Setupvertrag. `SUPPORT` ist kein normaler Analyseaufruf.
3. **Scope und Evidenz:** `ScopeCode` und `EvidenceType` bestimmen, was bekannt sein und welche Zeitgrenze später beachtet werden muss. Ein `LIVE_SNAPSHOT` beantwortet keine historische Frage; `PERSISTED_HISTORY` ist von Capture und Retention abhängig.
4. **Kosten:** Berücksichtigen Sie `CostRangeCode`, `AnalysisLevel`, `RequiresGroupGate`, `RequiresKnownTarget`, `RequiresHighImpactForSafeStart` und `HighImpactPathAvailable` gemeinsam. Keines dieser Felder darf allein als Freigabe verstanden werden.
5. **Paketstatus:** Prüfen Sie `PackageCode` und `IsInstalled`. Ein nicht installiertes optionales Paket bleibt sichtbar, damit der Funktionsumfang auffindbar ist.
6. **Voraussetzung:** Berücksichtigen Sie `PrerequisiteSummary` vor `SafeCall`. Zeitfenster, Plan-XML, Query Store, XE-Session oder expliziter Datenbankscope können entscheidend sein.
7. **Erster Aufruf:** Führen Sie `SafeCall` nicht ungeprüft aus. Prüfen Sie zunächst Platzhalter, Scope und Schutzparameter und lesen Sie danach die vollständige Procedure-Seite unter `DocumentationPath`.
8. **Gegenprobe:** Verwenden Sie `NextStep` und `RelationType`. Eine Vertiefung desselben Signals ist weniger unabhängig als eine Gegenprobe aus einer anderen Quelle.

## Warum kann das problematisch sein?

Das eigentliche Problem, das der Navigator reduziert, ist eine falsche oder zu teure erste Analyse. Wer bei unbekannter Objektlandschaft alphabetisch sucht, kann eine technisch öffentliche Support-Procedure, einen Targetpfad ohne Ziel oder einen High-Impact-Pfad auswählen. Ebenso kann ein universeller Orchestrator unnötig viele Quellen lesen, obwohl ein enger Live- oder Objektpfad genügt.

Auch ein fachlich passender Treffer kann falsch eingesetzt werden. Ein Query-Store-Pfad beantwortet bei deaktiviertem oder leerem Query Store keine Live-Frage. Eine aktuelle Blockinganalyse kann einen bereits beendeten Deadlock nicht rekonstruieren. Ein physischer Indexscan ist für die bloße Frage nach Nutzung unnötig teuer. Der Navigator macht diese Unterschiede über Rolle, Scope, Evidenz- und Kostenfelder sichtbar, kann aber die Entscheidung des Benutzers nicht ersetzen.

Ein weiterer Risikofaktor ist das ungeprüfte Kopieren von `SafeCall`. Der Aufruf ist synthetisch und absichtlich begrenzt. Platzhalter und tatsächliche Zielsystemrechte müssen dennoch vor der Ausführung geprüft werden.

## Wann ist es kein Problem?

Mehrere Treffer sind normal. Eine Beobachtung wie `CPU hoch` kann gleichzeitig zu aktuellen Requests, Worker Pressure, Query Stats und Server-Topologie passen. Der Navigator soll die Mehrdimensionalität nicht verstecken, sondern einen geeigneten Einstieg vor den Folgepfaden priorisieren.

Ein `IsInstalled = 0` ist ebenfalls kein Frameworkfehler. Das Snapshot-/Baseline-Paket ist optional, und ein eigenständiges PLAN-001-Paket kann nur einen Teil des Gesamtkatalogs lokal bereitstellen. Umgekehrt ist `IsInstalled = 1` erwartbar, ohne dass das zugehörige SQL-Server-Feature aktiv ist.

Ein niedrigerer Rang bedeutet nicht, dass die Procedure schlechter ist. Er besagt nur, dass sie zur aktuellen Texteingabe oder Filterkombination weniger direkt passt. Bei bekanntem technischen Ziel kann ein `TARGETED`-Treffer die richtige Wahl sein, obwohl ein allgemeiner `ENTRY`-Treffer höher steht.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall `ExampleBlockingSearch`:** Die Eingabe `Benutzer warten` liefert `USP_CurrentBlocking` vor `USP_CurrentMemoryGrants`. Das ist plausibel, weil der Begriff im Blockingkatalog exakt und hoch gewichtet ist. Der Treffer beweist dennoch kein Blocking. Erst der begrenzte Live-Aufruf kann eine aktuelle Kette zeigen; `USP_CurrentTransactions` oder der historische XE-Pfad liefern die Gegenprobe.

**Synthetischer Mehrdeutigkeitsfall `ExampleCpuSearch`:** `CPU hoch` priorisiert `USP_CurrentRequests`. `USP_WorkerPressureAnalysis` bleibt relevant, wenn Runnable Queues oder THREADPOOL-Signale vermutet werden. Ein Server mit hoher produktiver analytischer Last kann viel CPU nutzen, ohne dass ein einzelner Plan fehlerhaft ist. Deshalb sind Purpose, Scope und NextStep wichtiger als der Score allein.

**Synthetischer Paketfall `ExampleSnapshotSearch`:** Die Suche nach `Snapshot Baseline` kann `USP_RunSnapshotCollectionCycle` mit `PackageCode = SNAPSHOT_OPTIONAL` und `IsInstalled = 0` zeigen. Das ist eine vollständige Discovery-Antwort, aber kein ausführbarer lokaler Aufruf. Berücksichtigen Sie zuerst Paketvertrag und Zielkonfiguration.

**Gegenbeispiel `ExampleExactProcedure`:** Bei `[monitor].[USP_IndexPhysicalStats]` steht der exakte Name sehr hoch. Das bedeutet nicht, dass ein physischer Scan die passende Antwort auf `Index ungenutzt` ist. Für die Nutzungsfrage bleibt `USP_IndexUsage` der sichere Einstieg; physische Stats beantworten Fragmentierung und Seitendichte unter einem anderen Kostenmodell.

## Leere oder partielle Ausgabe

`NO_MATCH` bedeutet, dass keine Katalogzeile nach Suchtext und allen Filtern übrig blieb. Häufige Ursachen sind ein zu langer oder sehr spezifischer Satz, ein fachlich unpassender Bereichsfilter, `@NurInstallierte = 1` bei einem optionalen Paket oder eine Kombination aus Rolle und Scope, die es nicht gibt. Suchtext verkürzen und Filter einzeln entfernen.

`INVALID_PARAMETER` wird für unbekannte Bereichs- oder Scopecodes, ungültige Rollen, mehr als 400 Suchzeichen, negative oder über 100 liegende positive `@MaxZeilen`-Werte und eine ungültige Ausgabeart verwendet. `NULL` und `0` bedeuten vertragsgemäß keine Ergebnisbegrenzung. Bei TABLE ist ein fehlendes, unbekanntes oder nicht lokales Ziel ein harter Vertragsfehler des gemeinsamen TABLE-Helpers.

`LOCK_TIMEOUT` oder `ERROR_HANDLED` kann die lokale Installationsprüfung oder Katalogauswertung betreffen. Das Framework führt auch dann keine fachliche Analyse aus. Eine leere Ausgabe ist nie ein Beweis, dass keine geeignete Procedure oder keine reale Störung existiert.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | `LOW` |
| Standardpfad | konstante Katalogviews, höchstens 12 Ergebnisse und lokale Installationssicht |
| Teuerster Pfad | mit `@MaxZeilen = 0` oder `NULL` alle passenden Katalogergebnisse, Token- und Phrasensuche über alle Katalogbegriffe sowie JSON- oder TABLE-Ausgabe; weiterhin nur Frameworkmetadaten |
| Haupttreiber | Zahl der Katalog- und Suchbegriffzeilen, Suchtexttokens, Ergebnisbreite und JSON-Transfer |
| Skalierung | linear mit Procedures, Suchphrasen und relevanten Tokens; unabhängig von der Größe produktiver Datenbanken und Laufzeitquellen |
| Ressourcen | geringe CPU- und Temp-Table-Nutzung; keine fachliche DMV-, Plan-, XML-, Eventfile- oder Benutzertabellenarbeit |
| Begrenzungswirkung | positive `@MaxZeilen`-Werte begrenzen Ausgabe und Transfer auf höchstens 100 Treffer; `0` oder `NULL` heben nur diese Ergebnisgrenze auf; 400 Suchzeichen und höchstens 200 Zeichen je Token begrenzen die Sucharbeit |
| Locking und Nebenwirkungen | `LOCK_TIMEOUT 0`; `sys.schemas` und `sys.procedures` werden `WITH (NOLOCK)` nur zur lokalen Existenzprüfung gelesen; keine Konfigurationsänderung, kein Child-Call, keine Persistenz und keine Rechtevergabe |
| Schutzmechanismus | 400-Zeichen-Suchgrenze, Obergrenze 100 für positive Zeilenlimits, explizite Filtervalidierung und vollständige Materialisierung vor Ausgabe; der vollständige Modus bleibt durch die feste Kataloggröße begrenzt |
| Sicherer Einsatz | zunächst ohne Filter oder mit engem Suchbegriff aufrufen, `WhyMatched`, Rolle, Scope, Kosten und `IsInstalled` prüfen und erst danach die Ziel-Procedure separat starten |
| Aussagegrenze | katalogbasierte Auswahl, keine Diagnose; Score nicht versionsübergreifend als stabiler Kennwert verwenden |

## Technische Vertiefung

[Technische Detailbeschreibung](../../Reference/Analysis_Navigator.md)

### Leitfrage

Wie lässt sich eine große öffentliche Objektlandschaft nach Anwenderbeobachtung durchsuchen, ohne die stabile zweigeteilte SQL-API zu verändern und ohne beim Suchen bereits produktive Diagnosearbeit auszulösen?

### Technischer Hintergrund

`VW_AnalysisCatalog` normalisiert genau eine fachliche Hauptzeile je öffentlicher Procedure. `VW_AnalysisSearchTerm` erlaubt Mehrfachzuordnungen und DE/EN-Synonyme. `VW_AnalysisRelation` bildet gerichtete Übergänge ab. Diese Trennung verhindert, dass Zweck, Suchwörter und Folgeanalysen in mehreren READMEs voneinander abweichen.

Die Procedure normalisiert freie Texte explizit mit `Latin1_General_100_CI_AI`. Sie entfernt für einen Namensvergleich Klammern und das Präfix `monitor.`. Wesentliche Tokens mit mindestens drei Zeichen werden über `STRING_SPLIT` gewonnen; häufige deutsche und englische Stoppwörter werden entfernt. Exakte Namen und Phrasen erhalten deutlich mehr Gewicht als Tokenüberschneidungen. Ein Rollenbonus entscheidet nur innerhalb fachlich ähnlicher Treffer.

### Datenkette

1. Ausgabe-, Zeilen-, Textlängen-, Bereichs-, Scope- und Rollenparameter werden validiert.
2. Bei TABLE wird das benannte lokale Ziel `navigation` durch den gemeinsamen Helper geprüft.
3. Freier Suchtext wird in relevante Tokens zerlegt.
4. Der öffentliche Katalog wird mit der repräsentativen Analyseklasse und der lokalen `sys.procedures`-Sicht angereichert.
5. Pro Procedure werden beste Suchphrase, Tokendeckung und höchstpriorisierte Relation bestimmt.
6. Filter, Installationswunsch und Startlistenvertrag werden angewandt.
7. Kandidaten werden nach Relevanz, Rolle, Anzeigename und Procedure deterministisch begrenzt.
8. CONSOLE, RAW, TABLE und JSON verwenden dieselbe Temp-Table-Materialisierung.

### Source Select

Der Navigator liest ausschließlich Frameworkmetadaten und prüft, ob die katalogisierte Procedure lokal installiert ist:

```sql
SELECT
      [c].[ProcedureName]
    , [c].[PrimaryAreaCode]
    , [c].[NavigationRole]
    , [ac].[AnalysisLevel]
    , [p].[object_id]
FROM [monitor].[VW_AnalysisCatalog] AS [c]
LEFT JOIN [monitor].[VW_AnalyseClassCatalog] AS [ac]
  ON [ac].[AnalysisClass] = [c].[RepresentativeAnalysisClass]
LEFT JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
  ON [s].[name] = N'monitor'
LEFT JOIN [sys].[procedures] AS [p] WITH (NOLOCK)
  ON [p].[schema_id] = [s].[schema_id]
 AND [p].[name] = [c].[ProcedureName]
WHERE [c].[PrimaryAreaCode] = 'LIVE';
```

**Wichtig für die Eigenlast:** Bereichs-, Scope- und Rollenfilter wirken vor der gewichteten Suchterm- und Relationsauswertung. Die Metadatenmengen sind klein; freier Suchtext löst keine fachliche Diagnose aus.

### Zeit- und Scope-Modell

Der fachliche Katalog ist releasebezogen statisch. Nur `IsInstalled` ist eine lokale Momentaufnahme der Schema-/Procedure-Metadaten. Die Procedure untersucht keine andere Datenbank und keine fachliche Serverquelle. Dokumentationspfade sind relativ zur mitgelieferten Dokumentation; SQL Server prüft ihre externe Erreichbarkeit nicht.

### Bewertung und Gegenprobe

Die Qualität eines Treffers wird zuerst an `WhyMatched`, Rolle und Scope geprüft. Danach werden Voraussetzungen und Kosten gelesen. Die tatsächliche Eignung bestätigt erst die Dokumentation der Ziel-Procedure. Nach deren Ausführung folgt eine unabhängige Evidenz entsprechend `CONFIRM_WITH`, sofern verfügbar.

### Typische Fehlinterpretation

Der höchste Score sei die bewiesene Root Cause; `ENTRY` sei immer billig; `IsInstalled` bedeute ausreichende Rechte; `RequiresGroupGate = 0` bedeute risikofreie Vollausführung; oder `SafeCall` könne unverändert in jeder Umgebung ausgeführt werden. Alle fünf Schlüsse sind falsch. Die Felder navigieren zu einem Vertrag, sie ersetzen ihn nicht.

### Folgeanalyse

Die Folgeanalyse ist nicht fest vorgegeben. Sie wird aus dem gewählten Treffer und seiner priorisierten Relation abgeleitet. Alle Alternativen stehen in `VW_AnalysisRelation`. Verwenden Sie bei unbekannter Resultsetsemantik zuerst den [Einsteiger-Leseleitfaden](../Beginner_Reading_Guide.md) und danach die konkrete Procedure-Seite.

## Primärquellen

- [sys.procedures](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-procedures-transact-sql?view=sql-server-ver17)
- [sys.schemas](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/schemas-catalog-views-sys-schemas?view=sql-server-ver17)
- [STRING_SPLIT](https://learn.microsoft.com/en-us/sql/t-sql/functions/string-split-transact-sql?view=sql-server-ver17)
- [Collation und Unicode-Unterstützung](https://learn.microsoft.com/en-us/sql/relational-databases/collations/collation-and-unicode-support?view=sql-server-ver17)
- [FOR JSON](https://learn.microsoft.com/en-us/sql/relational-databases/json/format-query-results-as-json-with-for-json-sql-server?view=sql-server-ver17)

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md) · [Technische Signatur](../../Reference/Procedure_Reference.md) · [Hier beginnen](../Start_Here.md)
