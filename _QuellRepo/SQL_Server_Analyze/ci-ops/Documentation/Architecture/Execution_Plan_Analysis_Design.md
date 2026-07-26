# Execution-Plan-Analyse – Architektur und Laufzeitvertrag

## Zweck

Die Execution-Plan-Analyse untersucht ein Showplan-XML statement- und operatorgenau. Sie verbindet Planstruktur, Schätzungen, Laufzeitzähler, Warnungen, Objekt-/Statistikreferenzen und optional normalisierte externe Execution Evidence. Die Analyse bleibt lesend und führt den untersuchten Plan nicht aus.

Der Kern ist sowohl Bestandteil des vollständigen Frameworks als auch eigenständig installierbar. Beide Installationswege verwenden dieselben SQL-Objekte und denselben Resultsetvertrag.

## Öffentliche Einstiege

| Procedure | Aufgabe |
|---|---|
| `[monitor].[USP_ExecutionPlanAnalysis]` | nimmt Plan-XML, Planhandle oder Query-Store-Identität entgegen, normalisiert Dokumente und liefert statements, operators, warnings, references, predicates, statistics, findings und optionale Histogramme |
| `[monitor].[USP_CreateExecutionEvidenceJson]` | normalisiert begrenzte `STATISTICS IO`, `STATISTICS TIME`, Laufzeit-, Statistik- und Histogramminformationen in einen versionierten Evidence-Envelope |

`USP_ExecutionPlanAnalysis` ist der fachliche Einstieg. `USP_CreateExecutionEvidenceJson` ist sinnvoll, wenn Messwerte außerhalb des Plan-XMLs kontrolliert mitgeführt werden sollen.

## Unterstützende Objekte

| Objekt | Rolle |
|---|---|
| `InternalCollectExecutionPlanMetadata` | sammelt Plan-, Objekt-, Statistik- und Histogrammmetadaten unter expliziten Grenzen |
| `InternalAnalyzeExecutionPlan` | materialisiert Statements, Operatoren, Warnungen, Optimizerkontext, Runtimefeedback, Planmerkmale, Prädikate, Referenzen und Findings |
| `TVF_ParseStatisticsIoText` | zerlegt begrenzte, explizit gelieferte `SET STATISTICS IO`-Ausgabe |
| `TVF_ParseStatisticsTimeText` | zerlegt begrenzte, explizit gelieferte `SET STATISTICS TIME`-Ausgabe |
| `TVF_ExecutionPlanObjectReferences` | projiziert Objektbezüge aus Showplan-XML |
| `TVF_ExecutionPlanStatisticsUsage` | projiziert Statistikverwendung und relevante Metadatenbezüge |
| `TVF_ExecutionPlanColumnReferences` | projiziert Spalten- und Prädikatsreferenzen |
| `PlanAnalysisProfile` | beschreibt Workloadprofil und aktive Regelmenge |
| `PlanAnalysisRuleThreshold` | hält typisierte, nicht ausführbare Schwellenwerte je Regel und Profil |
| `PlanAnalysisProfileAssignment` | ordnet verfügbare Scopeinformationen einem Profil zu |

Die internen Procedures und TVFs sind kein alternativer öffentlicher Vertrag. Ihre vollständigen Schnittstellen stehen in der [Objektreferenz](../Reference/Object_Reference.md).

## Eingabequellen

Genau ein primärer Planpfad wird pro Aufruf gewählt:

1. **Direktes XML:** `@PlanXml` enthält ein Showplan-Dokument.
2. **Planhandle:** `@PlanHandle` löst einen aktuell gecachten Plan auf.
3. **Query Store:** Datenbank sowie Query-/Planidentität bestimmen genau einen persistierten Query-Store-Plan.

Direktes XML ist der unabhängigste Pfad und benötigt keinen Zugriff auf Plan Cache oder Query Store. Ein Planhandle ist flüchtig und kann zwischen Auswahl und Zugriff evictet werden. Query Store ist von Enablement, Capture, Retention, Leserechten und Datenbankstatus abhängig.

Mehrdeutige oder fehlende Primäreingaben führen zu einem strukturierten Parameter- oder Verfügbarkeitsstatus. Die Procedure wählt nicht still irgendeinen Plan.

## Plan-Dokumentmodell

Ein Aufruf kann mehrere Showplan-Dokumente und darin mehrere Statements enthalten. Die interne Identität trennt deshalb:

- `AnalysisObjectId`: Plan-Dokument im Aufruf;
- `StatementOrdinal` und `StatementId`: Statement innerhalb des Dokuments;
- `NodeId`: Operator innerhalb eines Statements;
- Query- und Planhash, sofern vom Showplan geliefert;
- Source- und Runtime-Scope, um tatsächliche Zähler von reinen Schätzungen zu trennen.

Ein XML-Dokument kann estimated, actual, live-derived, unvollständig oder versionsbedingt nur teilweise interpretierbar sein. `IsPlanComplete`, `HasRuntimeCounters`, Showplanversion und Quellproduktversion werden deshalb nicht aus dem Vorhandensein einzelner Attribute geraten.

## Normalisierungspipeline

1. Eingabevertrag, Limits, Ausgabeart und Datenschutzmodus werden geprüft.
2. Der Plan wird aus genau einer Quelle gelesen und als Dokument materialisiert.
3. Statementknoten werden mit Compile-, Cardinality-, DOP-, Grant- und Zeitkontext projiziert.
4. RelOp-Knoten werden rekursiv, aber begrenzt als Operatoren materialisiert.
5. Warnungen, Waits, Spills, Memory Grants, Parallelität und Laufzeitzähler werden separat normalisiert.
6. Objekt-, Spalten-, Statistik- und Prädikatsreferenzen werden ohne dynamische Ausführung gelesen.
7. Optionale Metadatenauflösung erfolgt nur für ausdrücklich erlaubte Datenbanken und Scopes.
8. Regeln erzeugen Findings aus bereits materialisierter Evidenz.
9. CONSOLE, RAW, TABLE und JSON verwenden dieselbe Aufrufmaterialisierung.

Planhandle-Aufrufe materialisieren zusätzlich einen gezielten Cachekontext aus
Cached Plans, Query Stats und Plan Attributes. In der Mehrplananalyse entsteht
dieser Kontext bereits während der begrenzten Kandidatenauswahl und wird über
eine aufruflokale Temp-Tabelle an die Einplanengine weitergereicht. Dadurch
wird die Query-Stats-Quelle innerhalb desselben Pfads nicht erneut gelesen.

## Statementebene

Die Statementprojektion enthält, soweit vorhanden:

- Statementtyp und Statementtext beziehungsweise geschützte Darstellung;
- Query Hash und Query Plan Hash;
- geschätzte und tatsächliche Zeilen-/Ausführungsinformationen;
- Compilezeit, Compile-CPU und Compile-Memory;
- Cardinality-Estimation-Modell;
- DOP und Parallelitätskontext;
- angeforderten, gewährten, verwendeten und idealen Memory Grant;
- Optimierungsabbruchgründe;
- Parameter- und Sensitivity-Metadaten;
- Laufzeitdauer, CPU und Reads, wenn der Quellplan sie tatsächlich enthält.

Statementwerte gelten nicht automatisch für jeden darunterliegenden Operator. Compilewerte sind keine Laufzeitzähler. Ein tatsächlicher Plan kann Zähler je Thread, je Ausführung oder kumuliert enthalten; `RuntimeCounterScope` begrenzt die Interpretation.

## Operatorebene

Eine Operatorzeile beschreibt einen `RelOp` innerhalb genau eines Statements. Typische Felder sind:

- physischer und logischer Operator;
- geschätzte Zeilen, Zeilengröße, Kosten und Ausführungszahl;
- tatsächliche Zeilen, Batches, Rebinds, Rewinds und Ausführungen;
- tatsächliche Zeit- und CPUwerte, sofern vorhanden;
- Ordered-, Parallel-, Mode- und Partitionseigenschaften;
- Join-, Scan-, Seek-, Sort-, Aggregate-, Spool- und Exchangekontext;
- Parent-/Child-Beziehung über Node-IDs.

Schätzabweichungen werden nicht nur als Verhältnis bewertet. Sehr kleine absolute Mengen können ein extremes Verhältnis erzeugen, ohne relevant zu sein. Umgekehrt kann eine moderate relative Abweichung bei hoher Ausführungszahl, großen Reads oder hohem Memory Grant erheblich sein.

## Warnungen, Spills und Memory

Showplanwarnungen werden als strukturierte Evidenz projiziert, nicht nur als Freitext:

- Sort- und Hash-Spills einschließlich Level und Datenmenge, soweit geliefert;
- Memory-Grant-Warnungen;
- Plan-affecting converts;
- fehlende Join-Prädikate oder unverbundene Joins;
- Columns-with-no-statistics;
- Wait- und Runtime-Warnungen;
- unvollständige oder abgeschnittene Planinformation.

Ein Spill beweist keine allgemeine Speicherkonfigurationsstörung. Kardinalität, Grant, Konkurrenz, TempDB und wiederholte Laufzeitwirkung sind gemeinsam zu prüfen. Ein großer Grant ohne Queue oder Pressure kann unkritisch sein.

## Objekt-, Statistik- und Prädikatsmodell

Objektreferenzen werden nach Datenbank, Schema, Objekt, Index und Alias getrennt. Spaltenreferenzen behalten Statement- und Node-Kontext. Statistikverwendung enthält Name, Aktualitäts- und Modifikationsinformationen nur dann, wenn sie im Plan oder über den ausdrücklich freigegebenen Metadatenpfad verfügbar sind.

Prädikate werden strukturell klassifiziert, beispielsweise Seek-, Residual-, Join-, Filter- oder Probe-Prädikat. Wertdarstellungen unterliegen dem gewählten Datenschutzmodus. Ein Prädikat allein beweist weder Selektivität noch SARGability; Operatorform, Konvertierung, Statistik und tatsächliche Zeilen sind die Gegenprobe.

## Histogrammkorrelation

Histogrammzugriff ist ein gezielter, optionaler Metadatenpfad. Er benötigt einen bekannten Datenbank-/Objektscope, passende Rechte, enge Limits und eine ausdrückliche Freigabe, wenn der High-Impact-Vertrag greift.

Die Korrelation trennt:

- Statistik und führende Spalte;
- Zahl und Umfang der Histogrammschritte;
- dominanten Schritt, Tail und Verteilung;
- Bezug eines Prädikats zu `RANGE_HI_KEY`;
- unterhalb/oberhalb des sichtbaren Histogramms;
- tatsächlichen Wert, geschützte Darstellung oder Hash-Token.

Histogrammgrenzen können fachliche Schlüssel enthalten. `DERIVED_ONLY` bleibt der sichere Modus: abgeleitete Kennwerte und Status ohne ungeschützte Grenzwerte. Ein Histogramm ist eine Stichprobe des Statistikzustands, keine vollständige Datenverteilung.

## Execution Evidence JSON

Der Evidence-Envelope ergänzt Pläne um ausdrücklich gelieferte Messwerte. Er besitzt eine Version, Source-/Capture-Metadaten, Validierungsstatus und getrennte Arrays für IO, TIME, Statistiken, Histogramme und weitere freigegebene Evidenz.

Wichtige Regeln:

- keine SQL-Ausführung innerhalb des Parsers;
- keine stillen Einheitenumrechnungen ohne dokumentierte Einheit;
- ungültige oder nicht zuordenbare Zeilen werden als Status ausgewiesen;
- Plan-, Statement-, Datenbank- und Objektkorrelation benötigt explizite Schlüssel;
- fehlende Evidenz bleibt `NULL` beziehungsweise leer und wird nicht als Nullmessung erfunden;
- JSON-Größe, Textlänge, Objektzahl und Histogrammzahl sind begrenzt.

## Profile und Findings

Profile unterscheiden zulässige Schwerpunkte, etwa OLTP, Reporting oder General. Regeln bleiben fest im T-SQL-Vertrag; Tabellen enthalten nur typisierte Werte wie Mindestzeilen, Verhältnis, Reads, CPU, Dauer, Spillmenge oder erforderliches Evidenzniveau. Freie SQL-Fragmente oder ausführbare Regeltexte sind ausgeschlossen.

Ein Finding enthält:

- stabilen Findingcode und Kategorie;
- Severity und Confidence;
- Evidenzniveau und Scope;
- Statement- und optional Operatorbezug;
- Metrik, Messwert, Einheit und Schwelle;
- Zusammenfassung, konkrete Evidenz, Evidenzgrenze und nächste Gegenprobe.

Severity ist keine automatische Änderungsanweisung. Confidence beschreibt die Stärke der sichtbaren Evidenz, nicht die Sicherheit einer Geschäftsursache.

## Resultsets

Der native Vertrag umfasst abhängig von Quelle und aktivierten Pfaden unter anderem:

- `planDocuments`
- `statements`
- `operators`
- `warnings`
- `memoryGrants`
- `waitStats`
- `objectReferences`
- `columnReferences`
- `statisticsUsage`
- `predicates`
- `parametersAndVariants` als bestehende Legacy-Projektion
- `parameters` als kanonischer DIAG-003-Evidenzvertrag
- `planWarnings` als normalisierte explizite Compile-/Runtimewarnungen
- `optimizerContext` als Statement-, Compile- und Cachekontext
- `runtimeFeedback` als gemessene beziehungsweise abgeleitete Runtimebeobachtung
- `queryStoreContext` als gezielter persistierter Plan-/Runtimekontext
- `feedbackAndVariants` als Planmerkmale, persistiertes Feedback, Hints und Variantenbeziehungen
- `histogramSummaries`
- `histogramSteps`
- `predicateHistogramMappings`
- `findings`

Die exakten Spalten, Typen, Nullability, Reihenfolge und TABLE-Fähigkeit stehen im [Resultsetinventar](../Reference/Resultset_Conventions.md) und in `Metadata/Inventory/ResultSets.csv`.

CONSOLE priorisiert Findings und lesbare Kernaussagen. RAW liefert Status und
native Resultsets. TABLE schreibt ausschließlich explizit benannte Ergebnisse
in lokale Temp-Tabellen. JSON enthält denselben Aufrufstand.

### Parameter-Evidenz

`parameters` bewahrt Attributpräsenz, SQL-NULL-Semantik, Quelltyp,
Quellbeobachtungszeit, Session-/Requestbezug sowie Current-/Last-known- und
Vollständigkeitskennzeichen. Fehlende Runtimeattribute, SQL-`NULL`,
Cache-Eviction, beendete Requests und die nicht allgemein zugänglichen lokalen
Variablen besitzen getrennte Statuswerte. Die Parameterliste wird pro Plan nur
einmal zerlegt; `parametersAndVariants` wird aus derselben
Aufrufmaterialisierung erzeugt. `USP_ShowplanAnalysis` aggregiert diese
Child-Evidenz kandidatengenau und führt keine zweite Parameter-XQuery aus.

### Plan- und Optimizerkontext

Die fünf DIAG-005-Resultsets bewahren Quelle, Erfassungszeit,
Current-/Last-known-Semantik und Messung gegenüber Ableitung. Fehlende
Warnungen, nicht erhobene Laufzeitwerte und nicht anwendbarer Query Store sind
unterschiedliche Statuszustände; Warnungen unterhalb von `@MinSchweregrad`
werden als erfolgreicher Filterzustand statt als Quellfehler ausgewiesen.
Jede fachliche Zeile enthält eine
False-Positive- beziehungsweise Evidenzgrenze; das Vorhandensein eines
Warnungs-, Feedback- oder Variantenmarkers ist kein automatischer
Ursachennachweis.

Bei der Query-Store-Planquelle werden Plan-/Querymetadaten und
Runtimeaggregate gezielt über die angeforderte Plan-ID gelesen. Kataloge, die
erst ab SQL Server 2022 verfügbar sind, stehen ausschließlich in
versionsadaptivem Dynamic SQL. `sys.query_store_query_text` wird nicht gelesen.
Ein erfolgreicher, aber leerer Zusatzquellen-Read, eine nicht unterstützte
Serverversion und ein fehlgeschlagener Read besitzen getrennte Statuszeilen;
`QueryHintFailureCount` summiert die von SQL Server gemeldeten Fehlerzählungen.
Feedback- und Hintpayloads sind in `DERIVED_ONLY` und `STRUCTURE_ONLY`
ausgelassen, in `TOKENIZED` nur gehasht und im RAW-Modus nur nach
`SensitiveDataConfirmed=1` sichtbar.

## Kosten- und Schutzmodell

| Pfad | Typisches Kostenprofil | Hauptgrenze |
|---|---|---|
| direktes einzelnes Plan-XML, abgeleitete Werte | niedrig bis mittel | XML-Größe, Statements, Operatoren |
| einzelnes Planhandle | mittel | Cachezugriff und Plan-XML |
| einzelner Query-Store-Plan | mittel | Datenbank-/Query-Store-Sicht |
| breite Operator-/Referenzprojektion | mittel | Planstruktur und Ergebnismenge |
| Metadatenauflösung | mittel bis hoch | Datenbank-/Objektzahl und Rechte |
| Histogramme mit Wertbezug | hoch, opt-in | Statistikzahl, Schritte, sensible Werte |
| große externe Evidence | mittel bis hoch | JSON-, Text- und Parsergrenzen |

Der Kern verändert weder Plan Cache noch Query Store, Statistiken, Indizes oder Konfiguration. Er erzwingt keinen Plan und führt keinen Querytext aus.

## Datenschutz

Plan-XML kann SQL-Text, Objekt- und Spaltennamen, Parameterdarstellungen, Literale und interne Topologie enthalten. Histogramme können Schlüsselgrenzen enthalten. Evidence JSON kann reale Mess- und Textwerte bündeln.

Deshalb:

- zunächst `DERIVED_ONLY` und kleine Limits verwenden;
- Plan- und Evidence-Dateien nur kontrolliert übertragen und aufbewahren;
- TABLE- und JSON-Ausgaben wie die ursprüngliche Evidenz schützen;
- Text- oder Histogrammfreigabe nicht mit High-Impact-Freigabe verwechseln;
- eine gekürzte oder geschützte Darstellung als solche in der Aussagegrenze behalten.

Siehe [Datenschutz und Laufzeitausgaben](Runtime_Data_Privacy.md).

## Standalone-Grenze

Das eigenständige Paket benötigt weder Current State, die Query-Store-Analyseverfahren, Extended Events noch Server Health. Die direkte Query-Store-Planauflösung ist ein enger Quelladapter, keine Abhängigkeit von den Query-Store-Analyseprocedures. Der Analysis Navigator gehört nur zum vollständigen Framework und ist keine Voraussetzung der eigenständigen Plananalyse.

Der Installations- und Abhängigkeitsvertrag steht unter [Execution-Plan-Analyse – Installation](Execution_Plan_Analysis_Installation_Contract.md).

## Aussagegrenzen

- Ein Plan zeigt technische Ausführungsstrategie, nicht automatisch Geschäftsursache oder SLA-Wirkung.
- Estimated Plans besitzen keine tatsächlichen Laufzeitzähler.
- Actual-Planzähler können je SQL-Server-Version, Operator, Thread und Ausführungsmodus variieren.
- Cache- und Query-Store-Plan können nicht derselben konkreten Ausführung entsprechen.
- Query Store aggregiert Intervalle; ein Plan-XML ist keine vollständige Historie.
- Ein Finding ist eine priorisierte Prüfthese, keine automatische Tuningmaßnahme.
- Fehlende Warnung beweist nicht, dass ein Problem außerhalb des sichtbaren Plans nicht existiert.

## Weiterführende Dokumentation

- [Procedure-Seite `USP_ExecutionPlanAnalysis`](../Analysis_Guides/Procedures/USP_ExecutionPlanAnalysis.md)
- [Procedure-Seite `USP_CreateExecutionEvidenceJson`](../Analysis_Guides/Procedures/USP_CreateExecutionEvidenceJson.md)
- [Plan-Cache-Leitfaden](../Analysis_Guides/04_Plan_Cache.md)
- [Installation](Execution_Plan_Analysis_Installation_Contract.md)
- [Objektreferenz](../Reference/Object_Reference.md)
- [Procedure-Referenz](../Reference/Procedure_Reference.md)
