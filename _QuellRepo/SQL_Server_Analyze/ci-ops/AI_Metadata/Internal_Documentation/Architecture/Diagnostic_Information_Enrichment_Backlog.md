# Zukunftsvertrag für zusätzliche Diagnoseinformationen

Stand: 2026-07-23
Status: `IMPLEMENTED_ACTIONS_GATE`
Backlog: `DIAG-001` bis `DIAG-007`

Umgesetzt und im Release-Gate für SQL Server 2019, 2022 und 2025 verankert sind
`DIAG-001`, `DIAG-002`, `DIAG-003`, `DIAG-004`, `DIAG-006` und `DIAG-007`.
`DIAG-004` ist mit seinem öffentlichen Request-Kontextvertrag abgeschlossen.
`DIAG-005` ist mit fünf kanonischen Plan-/Optimizerresultsets, gezieltem
Query-Store-Kontext und versionsübergreifendem Runtimevertrag abgeschlossen.

Die gemeinsame laufinterne Evidenzbasis materialisiert Sessions, Requests,
Connections, Waiting Tasks, Memory Grants, Resource Semaphores,
Resource-Governor-Zuordnung, Tasks, Scheduler, Transaktionen, TempDB-Nutzung
und begrenzten SQL-Text je aktivierter Quelle einmal. Input Buffer bleibt eine
gezielte Post-Candidate-Quelle von `USP_CurrentRequests`. Alle überlappenden
Current-State-Consumer innerhalb von `USP_CurrentOverview` verwenden dieselbe
Snapshot-ID; Einzelaufrufe lesen weiterhin frisch.

## Ziel

Dieser Vertrag bündelt umgesetzte und zukünftige Erweiterungen für
Serverversions-, Build-, Statement-, Parameter-, Plan- und
Laufzeitinformationen. Offene Abschnitte sind ein verbindlicher
To-do-Rahmen. Neue Informationen müssen in den frameworkweiten Datenbank-,
CONSOLE-, RAW-, JSON- und benannten TABLE-Vertrag integriert werden, ohne
Quellen mehrfach zu lesen.

Der bestehende Kern liefert bereits viele Einzelinformationen. Insbesondere
`USP_CurrentRequests`, `USP_QueryStats`, `USP_PlanDetails`,
`USP_ShowplanAnalysis`, die Query-Store-Module,
`USP_ServerFeatureCapabilities` und `USP_OSInformation` sind vor einer
Implementierung als vorhandene Quellen und mögliche Materialisierungs-Owner zu
prüfen. Neue Procedures dürfen diese Quellen in einem Overview- oder Exportaufruf
nicht erneut lesen.

## DIAG-001: Serverversion, Build, CU und Lifecycle

Status: `IMPLEMENTED_ACTIONS_GATE` durch
`monitor.USP_ServerVersionInformation`, `monitor.SqlServerBuildCatalog` und
`monitor.SqlServerLifecycleCatalog`.

Eine leichte Procedure, Arbeitstitel `monitor.USP_ServerVersionInformation`,
soll ohne High-Impact-Gate die technische Instanzversion und eine offline
reproduzierbare Buildbewertung liefern.

### Direkt aus der Instanz

- `ProductVersion`, `ProductMajorVersion`, `ProductMinorVersion` und
  `ProductBuild`;
- `ProductLevel`, `ProductUpdateLevel`, `ProductUpdateReference` und
  `ProductBuildType`;
- `ResourceVersion`, `ResourceLastUpdateDateTime` und `BuildClrVersion`;
- `Edition`, `EditionID`, `EngineEdition` und abgeleitete Engineklasse;
- Plattform, Distribution, OS-Release, OS-SKU und OS-LCID;
- SQL-Server-Startzeit, Uptime, Prozess-ID und letzter sichtbarer Dienststart;
- `IsClustered`, `IsHadrEnabled`, `HadrManagerStatus`, `IsLocalDB` und
  relevante installierte Featureflags;
- Server- und `tempdb`-Collation sowie optional der Compatibility-Level-Kontext
  sichtbarer Datenbanken.

`LicenseType` und `NumLicenses` werden nicht als Lizenznachweis verwendet, weil
SQL Server diese Eigenschaften nicht belastbar pflegt. Identitäts- und
Pfadwerte wie Server-, Host-, Instanz-, Dienstkonto-, Backup-, Daten- und
Logpfade gehören nicht in die normale CONSOLE-Projektion; eine technisch
begründete RAW-Ausgabe bleibt getrennt zu entscheiden.

### Offline-Buildkatalog

Ein versionierter Frameworkkatalog soll mindestens enthalten:

- vollständige Engine-Buildnummer;
- Major Version und Releasebezeichnung, beispielsweise `CU26`;
- Servicing-Zweig `RTM`, `CU`, `GDR`, `CU_GDR` oder `OD`;
- KB-Nummer, Veröffentlichungsdatum und Plattformscope;
- Kennzeichnung eines Security-Releases, soweit durch die Primärquelle belegt;
- stabile Microsoft-Buildübersicht und konkrete KB-URL;
- Katalogstand, Primärquelle und Quellabrufdatum;
- je Servicing-Zweig den neuesten im Katalog bekannten Build.

Die Procedure darf vollständig offline `EXACT_MATCH`, `UNKNOWN_BUILD`,
`BUILD_NEWER_THAN_OFFLINE_CATALOG`, `OLDER_KNOWN_BUILD`, `CATALOG_STALE`,
`PREVIEW_BUILD`, `ON_DEMAND_BUILD` oder `SERVICING_BRANCH_AMBIGUOUS` melden.
Eine unbekannte oder höhere Buildnummer ist niemals automatisch veraltet. Eine
CU-Differenz darf nur innerhalb eines eindeutig bestimmten, vergleichbaren
Servicing-Zweigs berechnet werden.

Stabile Buildübersichten können anhand der Major Version offline zugeordnet
werden. Das Öffnen der URL benötigt Internet, ihre Erzeugung nicht:

- SQL Server 2019: `https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2019/build-versions`
- SQL Server 2022: `https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions`
- SQL Server 2025: `https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2025/build-versions`
- versionsübergreifend: `https://learn.microsoft.com/en-us/troubleshoot/sql/releases/download-and-install-latest-updates`

Zusätzlich soll ein kleiner Offline-Lifecycle-Katalog Veröffentlichungsdatum,
Ende von Mainstream und Extended Support, Katalogstand und offizielle
Lifecycle-URL enthalten. Eine Buildnummer allein beweist weder vollständige
Security-Patches noch Verwundbarkeit, ausstehenden Neustart oder betriebliche
Freigabe der neuesten CU.

Vorgesehene benannte Resultsets:

- `serverVersion`;
- `buildAssessment`;
- `lifecycle`;
- `instanceFeatures`;
- `databaseCompatibility`;
- `references`;
- `warnings`.

## DIAG-002: Native strukturierte Datentypen erhalten

Status: `IMPLEMENTED_ACTIONS_GATE` für PlanDetails, Query Store, Deadlocks,
Extended Events und kritische Engine-Ereignisse; native TABLE-Schemata und
Fallbackstatus werden durch den Welle-1-Vertrag geschützt.

XML-Daten müssen als SQL-Datentyp `xml` materialisiert und ausgegeben werden,
wenn die Quelle valides XML liefert. Dies gilt insbesondere für Showplan XML,
Deadlockgraphen und Extended-Events-XML. In SSMS bleibt ein Showplan dadurch
direkt anklickbar und kann grafisch geöffnet werden.

Verbindliche Regeln:

1. Liefert die Systemquelle bereits `xml`, wird nicht zuerst nach
   `nvarchar(max)` konvertiert.
2. Liefert eine Quelle XML als Text, wird das ungekürzte Original kontrolliert
   in `xml` konvertiert. `TRY_CAST` beziehungsweise `TRY_CONVERT` ist nur dort
   zulässig, wo Datentyp und Länge dies zuverlässig erlauben. Insbesondere ist
   die dokumentierte `TRY_CAST`-Grenze für `nvarchar(max)` oberhalb von 4.000
   und `varchar(max)` oberhalb von 8.000 Zeichen zu berücksichtigen.
3. Ein Parsefehler erzeugt `XML_INVALID`, ein Quell- oder XML-Tiefenlimit
   `XML_UNAVAILABLE_LIMIT`; beides bleibt von einem tatsächlichen leeren XML
   unterscheidbar.
4. Bei nicht als `xml` lieferbaren, zu tief verschachtelten oder nur textuell
   verfügbaren Plänen darf ein separates Textfallback erhalten bleiben. Das
   primäre Planfeld bleibt typisiert und wird nicht stillschweigend durch Text
   ersetzt.
5. Plantext wird nicht vor der XML-Konvertierung gekürzt. Größenbegrenzungen
   wählen ganze Pläne beziehungsweise Zeilen aus und markieren ausgelassene
   Ergebnisse.
6. Showplan-Namespace, Rootstruktur und Encoding werden nicht verändert.
7. TABLE-Ziele erhalten eine echte `xml`-Spalte. Das Resultsetinventar muss den
   Typ ausweisen und der TABLE-Writer muss ihn unverändert übernehmen.
8. JSON kann XML technisch nur als String transportieren. Der JSON-Vertrag
   kennzeichnet deshalb Format und Encoding; er ersetzt nicht den nativen XML-
   Vertrag von RAW, CONSOLE und TABLE.
9. CONSOLE zeigt einen Plan nur in einer fachlich passenden Detailstufe. Eine
   große XML-Spalte darf das normale Ein-Grid-Ziel nicht unkontrolliert
   verdrängen.

Frameworkweit zu prüfen sind mindestens Query-Store-Pläne, die derzeit teils
als `nvarchar(max)` materialisiert werden, Plan-Cache-Pläne, Live-/Last-Actual-
Pläne, Deadlock-XML und Extended-Events-Eventdaten.

## Öffentlicher Zielvertrag für DIAG-003 bis DIAG-005

Die folgenden Namen bilden die umgesetzten Zielverträge. Procedure,
TABLE-Schema, JSON, Inventar und Runtimevertrag stimmen für DIAG-003 bis
DIAG-005 überein.

| Work Item | Kanonische Resultsets | Mindestprovenienz |
|---|---|---|
| `DIAG-003` | `parameters` | Candidate-, Session-, Request-, Statement-, Query- und Planbezug; getrennte Compile-/Runtimepräsenz; Quelle, Quellzeit, Aktualität, Vollständigkeit und Status |
| `DIAG-004` | `snapshotStatus`, `requestContext`, `statements`, `batches`, `inputBuffers` | Snapshot-ID, Quelle und eigener Capture-Zeitpunkt; Requestende, Berechtigung, Trunkierung und Auslassungsgrund |
| `DIAG-005` | `planWarnings`, `optimizerContext`, `runtimeFeedback`, `queryStoreContext`, `feedbackAndVariants` | Planquelle, Planzeitbezug, Current-/Last-known-Semantik, Messung gegenüber Ableitung und False-Positive-Grenze |

`parametersAndVariants` bleibt bis zur expliziten Migration ein bestehendes
Legacy-Resultset. Es darf nicht stillschweigend in `parameters` umbenannt
werden. Der neue Vertrag muss fehlendes XML-Attribut, erfassten SQL-`NULL`,
nicht erhobenen Wert und nicht verfügbare Quelle unterscheidbar halten.

## DIAG-003: Parameter- und Variablenwerte

Status: `IMPLEMENTED_ACTIONS_GATE`.

Das kanonische Resultset `parameters` ist in
`USP_ExecutionPlanAnalysis` für genau einen Plan und in
`USP_ShowplanAnalysis` kandidatengenau für mehrere Pläne umgesetzt.
`parametersAndVariants` bleibt als additive Legacy-Ausgabe unverändert
erhalten. Die zentrale Engine zerlegt die Showplan-`ParameterList` genau
einmal; der Legacy-Vertrag wird aus derselben Materialisierung projiziert.

Jede Parameterzeile enthält, soweit die Quelle dies bereitstellt:

- Candidate-, Session-, Request-, Statement-, Query- und Planbezug;
- Parametername und Showplan-Datentyp;
- getrennte Presence-Flags für `ParameterCompiledValue` und
  `ParameterRuntimeValue`;
- eigene SQL-NULL-Kennzeichen und Status je Compile- und Runtimewert;
- expliziten Datenschutzstatus sowie RAW-Wert oder aufruflokalen Token nur im
  gewählten Modus;
- `ValueSource`, `SourceObservedAtUtc` und nur bei einem Live-Plan einen
  bekannten `ValueCapturedAtUtc`;
- `IsCurrentExecution`, `IsLastKnownExecution`, `IsComplete` und eine
  konkrete Evidenzgrenze.

Die Quellwerte `COMPILE_PLAN`, `LIVE_PLAN`, `LAST_ACTUAL_PLAN`,
`QUERY_STORE_PLAN`, `IMPORTED_PLAN` und `PLAN_CACHE_ATTEMPT` bewahren die
unterschiedliche Zeitsemantik. Ein nicht mehr auflösbares Planhandle liefert
`PLAN_EVICTED`; ein nicht mehr laufender gezielter Request liefert
`REQUEST_FINISHED`. Fehlende Attribute bleiben `NOT_COLLECTED`; die
lexikalische Showplan-Repräsentation `NULL` beziehungsweise `(NULL)` wird
dagegen mit Presence-Flag und `SQL_NULL` gekennzeichnet.

SQL Server stellt keine allgemeine DMV bereit, über die zu einem fremden
laufenden Statement sämtliche aktuellen lokalen T-SQL-Variablenwerte gelesen
werden können. Deshalb enthält der Vertrag zusätzlich eine
`SOURCE_BOUNDARY`-Zeile mit `LOCAL_VARIABLE_NOT_EXPOSED`; sie ist keine
behauptete Parameterzeile. Input Buffer bleibt eine getrennte Textquelle und
wird nicht heuristisch als vollständige Parameterliste interpretiert.

| Quelle | Umgesetzte Information | Aussagegrenze |
|---|---|---|
| kompiliertes Showplan XML | Name, Datentyp und vorhandener Compilewert | kein aktueller Laufzeitwert |
| Live-Showplan | vorhandener Compile- und Runtimewert mit Session-/Requestbezug | aktuelle Ausführung kann noch partiell sein |
| Last Actual Plan | letzter bekannter Runtimewert, falls im XML vorhanden | nicht zwingend der aktuelle Aufruf; exakter Wertzeitpunkt unbekannt |
| Query Store | kompiliertes Planattribut, falls vorhanden | keine vollständige Wertliste je Ausführung |
| importierter Plan | vorhandene Compile-/Runtimeattribute | ursprünglicher Erfassungszeitpunkt und Aktualität können unbekannt sein |
| Input Buffer und Extended Events | als getrennte externe Text- beziehungsweise Eventquelle möglich | nicht Bestandteil einer automatisch aktivierten Erfassung |

Das Framework aktiviert weder Traceflag 2446 noch
`FORCE_SHOWPLAN_RUNTIME_PARAMETER_COLLECTION`, `LAST_QUERY_PLAN_STATS` oder
eine Extended-Events-Session. Planbeschaffung und XML-Shredding erfolgen je
Kandidat weiterhin einmal. `USP_ShowplanAnalysis` liest die bereits
normalisierte Child-Ausgabe und führt keine zweite Parameter-XQuery aus.

Parameterwerte können Zugangsdaten, Tokens, personenbezogene Werte oder
Geschäftsdaten enthalten. `DERIVED_ONLY` bleibt Standard; `RAW` benötigt
`@SensitiveDataConfirmed = 1`, `TOKENIZED` erzeugt nur aufruflokal
korrelierbare Tokens. Repositorytests verwenden ausschließlich synthetische
`Example*`-Werte.

## DIAG-004: Statement- und Requestkontext

Status: `IMPLEMENTED_ACTIONS_GATE`.

`USP_CurrentRequests` liefert die kanonischen Resultsets `snapshotStatus`,
`requestContext`, `statements`, `batches` und `inputBuffers` in RAW, JSON und
über benannte TABLE-Ziele. Fehlender Text, ungültige Offsets, bewusste
Nicht-Erhebung, Trunkierung, Berechtigungsgrenzen und ein zwischen Snapshot und
Post-Candidate-Read beendeter Request besitzen unterscheidbare Statuswerte.

`USP_CurrentSessions`, `USP_CurrentRequests`, `USP_CurrentBlocking`,
`USP_CurrentWaits`, `USP_CurrentTransactions`,
`USP_CurrentMemoryGrants`, `USP_CurrentTempDB` und `USP_CurrentIO`
konsumieren in `USP_CurrentOverview` dieselbe aufruflokale Snapshot-ID.
Quellen tragen eigene Erfassungszeitpunkte; der Vertrag behauptet keine
transaktionale Atomizität zwischen verschiedenen DMVs. Einzelaufrufe können
keine Parent-Daten wiederverwenden und lesen weiterhin frisch.

Der abgeschlossene DIAG-004-Scope umfasst:

- aktuelles Statement und vollständiger Batch mit gültigen Byte- und
  Zeichenoffsets, Zeilenbereich, Länge und Trunkierungsstatus;
- Modul-, Datenbank-, Schema- und Objektbezug ohne blockierende
  `OBJECT_NAME()`-/`OBJECT_ID()`-Auflösung;
- Input-Buffer-Typ, Parameteranzahl und ungekürzter beziehungsweise bewusst
  begrenzter Inputtext;
- Session-, Request-, Connection-, Task-, Scheduler- und Execution-Context;
- Startzeit, Dauer, CPU, Reads, Writes, Logical Reads, Row Count,
  Percent Complete und geschätzte Restzeit;
- Wait, Blocking, offene Transaktion, Isolation Level und Waitresource;
- Memory Grant, tatsächliche Nutzung, Idealwert und TempDB-Evidenz;
- DOP, Parallel Worker, Workload Group und Resource Pool;
- Query Hash, Plan Hash, SQL Handle, Plan Handle und Statement SQL Handle;
- Verbindungsprotokoll, Transport, Verschlüsselung und Authentisierung;
- Client-, Host-, Programm- und Loginangaben nur in fachlich begründeten
  Detail- beziehungsweise RAW-Pfaden.

Die Informationen stammen innerhalb eines Overview-Aufrufs aus demselben
aufruflokalen Snapshot oder weisen bei gezielten Post-Candidate-Quellen ihren
abweichenden Erfassungszeitpunkt aus. Ein Join auf später erneut gelesene DMVs
wird nicht als atomare Sicht dargestellt.

Operatorbezogene Spill-Evidenz, Plan-Generation, Compile- beziehungsweise
Recompile-Zeitpunkt und Cachealter gehören zum getrennten DIAG-005-Vertrag und
werden nicht als Bestandteil des Request-Kontextvertrags ausgewiesen.

## DIAG-005: Plan-, Query-Store- und Optimizerkontext

Status: `IMPLEMENTED_ACTIONS_GATE`.

`USP_ExecutionPlanAnalysis` erzeugt aus der einmal beschafften und einmal
zerlegten Planquelle die Resultsets `planWarnings`, `optimizerContext`,
`runtimeFeedback`, `queryStoreContext` und `feedbackAndVariants`.
`USP_ShowplanAnalysis` aggregiert sie mit Candidate-ID und Planhandle; sein
bereits bei der Kandidatenauswahl erfasster Cachekontext wird von der
Einplanengine wiederverwendet. Ein direkter Planhandle-Aufruf verwendet
stattdessen genau einen gezielten Cachekontext-Read.

Neben dem anklickbaren XML sind folgende Informationen sinnvoll:

- Planquelle: Compile, Live, Last Actual, Query Store oder Extended Event;
- Optimization Level, Early Abort Reason, Cardinality Estimation Model,
  Statement- und Subtree-Cost;
- geschätzte und tatsächliche Zeilen, Rows Read, Ausführungen und Abweichung;
- Memory Grant, Grant Wait, Max Used Memory, Spilltypen und Spillvolumen;
- Parallelität, tatsächlicher DOP, Worker, Skew und Exchange-Waits;
- verwendete Objekte, Indizes und Statistiken einschließlich
  Aktualitäts-/Samplingevidenz;
- Missing-Index-Hinweise mit der bestehenden False-Positive-Grenze;
- implizite Konvertierungen, Planwarnungen, residuale Prädikate, Row Goals,
  Sort-/Hashwarnungen und nicht parallele Gründe;
- Adaptive Join, Batch Mode, Memory Grant Feedback, DOP Feedback,
  Cardinality Feedback, PSP- und OPPO-Varianten;
- Query-Store-Query-/Plan-ID, Force-/Hintstatus, Forcefehler,
  Regressions- und Planwechselkontext;
- Cacheobjekttyp, Use Count, Plangröße, Set Options, Compile User und weitere
  dokumentierte Planattribute;
- Vergleich von Compile- und Runtimeparametern als mögliche
  Parameter-Sensitivitätsevidenz, niemals als alleiniger Ursachenbeweis.

Query-Store-Plan- und Querymetadaten sowie Runtimeaggregate werden nur für die
ausdrücklich angeforderte Plan-ID gelesen. Feedback, Query-Store-Hints und
Varianten sind auf SQL Server 2022 und neuer über versionsadaptives Dynamic
SQL geschützt; SQL Server 2019 erhält einen expliziten Nichtverfügbarkeits-
beziehungsweise Nichtanwendbarkeitsstatus. Querytexte werden nicht gelesen.
Feedback- und Hintpayloads sind in `DERIVED_ONLY` und `STRUCTURE_ONLY`
ausgelassen, in `TOKENIZED` nur als SHA-256-Token und nur im bestätigten
`RAW`-Modus lesbar.

Jede Zeile weist Quelle und Erfassungszeit sowie Current-/Last-known-Semantik
aus. `IsMeasured`, `IsDerived` beziehungsweise `IsInferred` trennen Messung
und Ableitung. Die False-Positive-Grenze verhindert insbesondere, dass eine
einzelne Warnung, ein einzelner Plan oder das bloße Vorhandensein von PSP,
OPPO oder Optimizerfeedback automatisch als Ursachen- oder Tuningnachweis
interpretiert wird.

Teure XML-, Plan-Cache-, Live-Plan-, Last-Actual- und Extended-Events-Pfade
bleiben gezielt, begrenzt und laufintern wiederverwendet. Es wird weder
automatisch getunt noch Tracing aktiviert.

## DIAG-006: Provenienz, Zeitbezug und Evidenzgrenzen

Status: `IMPLEMENTED_ACTIONS_GATE` als verbindlicher Querschnittsvertrag für
neue und in Welle 1 migrierte Resultsets.

Jede neue Information benötigt, soweit fachlich relevant:

- `SourceType` und konkretes Quellobjekt;
- `CapturedAtUtc` sowie gegebenenfalls Compile-, Start-, Last-Execution- oder
  Intervallzeit;
- Scope und Granularität;
- `IsCurrent`, `IsLastKnown`, `IsCumulative` oder `IsAggregated`;
- `StatusCode`, Partialität und Fehler-/Auslassungsgrund;
- Berechtigungs-, Versions-, Plattform-, Konfigurations- und Cachegrenze;
- Trunkierungs-, Zeilenlimit- und Payloadstatus;
- Hinweis, ob der Wert direkt gemessen, aus XML gelesen oder inferiert wurde.

Freitext `NULL` reicht nicht aus, um nicht vorhanden, nicht erhoben, nicht
berechtigt, nicht unterstützt, evictet, zu groß, zu tief oder ungültig zu
unterscheiden.

## DIAG-007: Ausgabe-, Inventar- und Testvertrag

Status: `IMPLEMENTED_ACTIONS_GATE` für alle Resultsets aus DIAG-003 bis
DIAG-005.

Vor einer Umsetzung werden alle neuen Resultsets semantisch benannt und in
`Metadata/Inventory/ResultSets.csv` mit stabilen Schemas erfasst. TABLE-Ziele
werden vor Systemzugriffen validiert. Alle Exporte verwenden ausschließlich die
im selben Aufruf materialisierten Daten.

Erforderliche Tests auf SQL Server 2019, 2022 und 2025:

- native XML-Spalte ist in RAW und TABLE tatsächlich `xml` und in SSMS als
  Showplan verwendbar;
- valides, ungültiges, leeres, sehr großes und zu tiefes XML bleiben
  unterscheidbar;
- Query-Store-Plantext wird ohne vorherige Kürzung kontrolliert konvertiert;
- Compilewert, Runtimewert, fehlende Erfassung und echter SQL-`NULL` bleiben
  semantisch getrennt;
- lokaler Variablenwert wird nicht erfunden;
- Input Buffer, Request, Plan und Query Store behalten eigenen Zeitbezug;
- Requestende und Cache-Eviction erzeugen partielle, nicht falsche Ergebnisse;
- eingeschränkte Berechtigungen deaktivieren nur das betroffene Teilresultset;
- Plan- und Parameterquellen werden pro Aufruf höchstens einmal gelesen;
- High-Impact-Abbruch erfolgt vor dem teuren Zugriff;
- CONSOLE bleibt kompakt, RAW vollständig und TABLE/JSON schemafest;
- Datenschutz-, Nonblocking-, Dokumentations- und Commit-Gates bleiben grün.

## Offizielle Primärquellen

- `SERVERPROPERTY`: https://learn.microsoft.com/en-us/sql/t-sql/functions/serverproperty-transact-sql?view=sql-server-ver17
- aktuelle SQL-Server-Builds: https://learn.microsoft.com/en-us/troubleshoot/sql/releases/download-and-install-latest-updates
- Live-Showplan: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-query-statistics-xml-transact-sql?view=sql-server-ver17
- Last Actual Plan: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-query-plan-stats-transact-sql?view=sql-server-ver17
- Input Buffer: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-input-buffer-transact-sql?view=sql-server-ver17
- `TRY_CAST`: https://learn.microsoft.com/en-us/sql/t-sql/functions/try-cast-transact-sql?view=sql-server-ver17
- Extended-Events-Actual-Showplan: https://learn.microsoft.com/en-us/shows/sql-workshops/extended-event-query-post-execution-showplan-in-sql-server

## Empfohlene Umsetzungsreihenfolge

1. `DIAG-002` umfasst das frameworkweite XML-Typaudit und die Korrektur der verlustbehafteten `nvarchar(max)`-Planpfade.
2. `DIAG-001` umfasst eine leichte Serverversions-Procedure und einen versionierten Offline-Build- und Lifecycle-Katalog.
3. `DIAG-003` erweitert die vorhandene Parameterextraktion um stabile Provenienz und einen TABLE-Vertrag.
4. `DIAG-004` konsolidiert den Statement- und Requestkontext ohne erneute DMV-Lesung.
5. `DIAG-005` ergänzt zusätzliche Plan- und Optimizerinformationen nach Priorität und ist abgeschlossen.
6. `DIAG-006` und `DIAG-007` schließen den Provenienz-, Inventar- und Testvertrag in jeder vertikalen Umsetzung gleichzeitig ab.
