# Execution-Plan-Analyse – Architektur- und Implementierungsvertrag

**Stand:** 2026-07-21
**Status:** `IMPLEMENTED_ACTIONS_GATE`
**Backlog:** `PLAN-001`
**Zielversionen:** SQL Server 2019, 2022 und 2025
**Mindestversion:** SQL Server 2019

> Diese Datei beschreibt die implementierte eigenständige und frameworkintegrierte Execution-Plan-Analyse. Der eingefrorene maschinenlesbare V1-Vertrag steht in [`ExecutionPlanAnalysis_Public_Contract.json`](../../Metadata/Quality/ExecutionPlanAnalysis_Public_Contract.json). Exakte Parameterdeklarationen, Resultsets und Installerabhängigkeiten werden zusätzlich durch die dort referenzierten Inventare festgelegt und automatisch gegen die kanonischen SQL-Quellen geprüft. Beispiele verwenden ausschließlich synthetische Bezeichner. Reale Plan-, Parameter-, Histogramm-, Objekt-, Server-, Benutzer- oder Geschäftsdaten dürfen nicht in Repositorydateien, Tests, Fixtures oder andere herunterladbare Artefakte übernommen werden.

## 1. Zielbild

Die Analyse unterstützt zwei gleichwertige Betriebsarten:

1. **Standalone:** Ein vorhandenes Showplan-XML und optionale zusätzliche Ausführungsevidenz werden direkt übergeben. Der Standardpfad liest weder Plan Cache noch Query Store noch Benutzerobjekte.
2. **Frameworkintegriert:** Bestehende Frameworkmodule beschaffen Pläne aus Plan Cache, Last Known Actual Plan, einer laufenden Session oder Query Store und verwenden anschließend dieselbe zentrale Analyse-Engine.

Der Standalone-Pfad kann auch einen Plan analysieren, der von einer anderen SQL-Server-Instanz stammt. Die Version des analysierenden Servers wird dabei nicht stillschweigend als Quellversion des Plans interpretiert.

### 1.1 Kernziele

- statementgenaue Zuordnung innerhalb von Mehrstatement-Batches und Stored Procedures;
- operatorbezogener Baum mit Parent, Child-Ordinal, Tiefe und stabilem Pfad;
- saubere Trennung von Compile-, Last-Actual-, Live-, Query-Store- und importierter Evidenz;
- versionsadaptive Auswertung für SQL Server 2019, 2022 und 2025;
- optionale Evidenz aus `SET STATISTICS IO`, `SET STATISTICS TIME`, aktuellem Statistikzustand und Histogrammverteilung;
- workloadabhängige, konfigurierbare Schwellenwerte ohne frei ausführbare Regeln in Metadaten;
- getrennte Felder für Severity, Confidence, Evidenzquelle und Aussagegrenze;
- keine automatische Queryausführung, kein automatisches Tuning, kein automatisches Index-DDL;
- geringe und begrenzbare Eigenlast.

### 1.2 Nichtziele

- keine allgemeine Query-Execution-Engine innerhalb des Frameworks;
- keine automatische Aktivierung von `LAST_QUERY_PLAN_STATS`, Profiling, Traceflags oder Extended Events;
- keine automatische Wiederholung fremder SQL-Batches zur Messung;
- keine Behauptung einer exakten linearen Operatorausführungsreihenfolge;
- keine automatische Indexerstellung oder Statistikaktualisierung;
- keine Persistenz realer Runtimewerte im Repository.

## 2. Bestehender Hauptbefund

`sys.dm_exec_query_stats` liefert statementbezogene Kandidaten, während `sys.dm_exec_query_plan(plan_handle)` den Plan des gesamten Batch- beziehungsweise Cacheobjekts zurückgeben kann. Die bestehende `monitor.USP_ShowplanAnalysis` hält Statementoffsets in der Kandidatentabelle, verarbeitet später jedoch das vollständige Plan-XML nur noch über `plan_handle`.

Vor der Erweiterung muss deshalb die Identität auf mindestens folgende Schlüssel umgestellt werden:

```text
PlanDocumentId
StatementOrdinal
StatementId beziehungsweise StatementCompId
NodeId
```

Ein Planhandle wird einmal geladen und einmal technisch zerlegt. Statementkandidaten werden danach mit den passenden Statementelementen korreliert. `NodeId` ist ohne Statementbezug kein ausreichender Schlüssel.

## 3. Gesamtarchitektur

```text
Planbeschaffung
    ↓
Plan- und Evidenznormalisierung
    ↓
technisches Planmodell
    ↓
optionale zielgerichtete Metadatenanreicherung
    ↓
Kennzahlen
    ↓
workload- und evidenzabhängige Regeln
    ↓
Findings und Folgeanalysen
```

### 3.1 Implementierte öffentliche Objekte

```text
monitor.USP_ExecutionPlanAnalysis
monitor.USP_CreateExecutionEvidenceJson
monitor.TVF_ParseStatisticsIoText
monitor.TVF_ParseStatisticsTimeText
monitor.TVF_ExecutionPlanObjectReferences
monitor.TVF_ExecutionPlanStatisticsUsage
monitor.TVF_ExecutionPlanColumnReferences
```

### 3.2 Implementierte interne Objekte

```text
monitor.InternalAnalyzeExecutionPlan
monitor.InternalCollectExecutionPlanMetadata
```

### 3.3 Implementierte Steuertabellen

```text
monitor.PlanAnalysisProfile
monitor.PlanAnalysisRuleThreshold
monitor.PlanAnalysisProfileAssignment
```

### 3.4 Bestehende Integrationsobjekte

Zwingend betroffen:

```text
monitor.USP_ShowplanAnalysis
```

Später abhängig vom realisierten Scope:

```text
monitor.USP_PlanCacheAnalysis
monitor.USP_PlanDetails
monitor.USP_QueryStats
monitor.USP_IntelligentQueryProcessingAnalysis
```

## 4. Objektzuständigkeiten

### 4.1 `monitor.USP_ExecutionPlanAnalysis`

Öffentlicher Standalone-Einstieg für genau ein Plan-XML-Dokument oder genau eine alternative Planquelle. Die Procedure:

- validiert Planquelle, Ausgabevertrag, Limits und Evidenz;
- bestimmt Planherkunft und Runtime-Counter-Scope;
- baut Statement-, Operator-, Runtime-, Predicate-, Objekt-, Index- und Statistikmodelle auf;
- wendet das ausgewählte Workloadprofil und den Regelsatz an;
- liefert benannte RAW-, TABLE- und JSON-Ergebnisse sowie ein kompaktes CONSOLE-Hauptergebnis;
- führt kein übergebenes SQL aus.

### 4.2 `monitor.InternalAnalyzeExecutionPlan`

Interne zentrale Analyse-Engine. Sie erhält ein Plan-XML, optionales Evidenz-JSON, vorbereitete Temp-Tabellen und den bereits ermittelten Workloadkontext. Sie schreibt ausschließlich in die bereitgestellten lokalen Temp-Tabellen. Standalone- und Multi-Plan-Pfad verwenden dadurch dieselbe technische Interpretation und dieselben Findingcodes.

### 4.3 `monitor.USP_ShowplanAnalysis`

Bestehender Multi-Plan-Wrapper. Seine Verantwortung ist:

1. Kandidaten selektieren;
2. statementbezogene Identität erhalten;
3. eindeutige Planhandles bestimmen;
4. jeden Plan nur einmal laden;
5. die zentrale interne Analyse-Engine aufrufen;
6. Ergebnisse wieder mit Kandidat und Statement verbinden;
7. Plan-Eviction, Timeout und partielle Quellen je Plan isolieren.

### 4.4 `monitor.USP_CreateExecutionEvidenceJson`

Kanonischer Erzeuger und Normalisierer des Evidenz-JSON. Die Procedure:

- parst bereits vorliegende `STATISTICS IO`- und `STATISTICS TIME`-Meldungen;
- übernimmt Compilezeit-Statistikverwendung aus dem Plan;
- validiert extern übergebenes Statistik- und Objektmetadaten-JSON;
- kann bei bestätigter Quellumgebung zielgerichtet aktuelle Objekt-, Index- und Statistikmetadaten sammeln;
- korreliert Predicate-, Compile- und Runtimewerte lokal mit Histogrammschritten;
- entfernt oder tokenisiert sensible Werte erst nach dem lokalen Matching;
- führt keine Query aus.

### 4.5 Extractor-Funktionen

Die drei Extractor-Funktionen lesen ausschließlich das übergebene XML und greifen auf keine Datenbankkataloge zu.

#### `monitor.TVF_ExecutionPlanObjectReferences`

Normalisiert Referenzen aus Access Paths, DML Targets, Statistics Usage, Missing Index, Column References, Function References und Remote-Elementen.

Implementierte Spalten:

```text
ReferenceOrdinal
StatementOrdinal
StatementId
StatementCompId
NodeId
ReferenceType
ReferenceSource
DatabaseName
SchemaName
ObjectName
IndexName
AliasName
StorageType
PlanObjectId
PlanIndexId
IsTemporaryObject
IsTableVariable
IsRemoteObject
IsDmlTarget
ResolutionCapability
SourceElement
```

#### `monitor.TVF_ExecutionPlanStatisticsUsage`

Eine Zeile je im Plan verwendeter Statistik und Statement:

```text
StatisticsUsageOrdinal
StatementOrdinal
StatementId
StatementCompId
DatabaseName
SchemaName
ObjectName
StatisticsName
LastUpdateAtCompile
ModificationCountAtCompile
SamplingPercentAtCompile
SourceElement
ParseStatus
```

#### `monitor.TVF_ExecutionPlanColumnReferences`

Normalisiert Spaltenrollen für gezielte Index- und Statistikauflösung:

```text
StatementOrdinal
StatementId
NodeId
ColumnUsage
ExpressionContext
DatabaseName
SchemaName
ObjectName
AliasName
ColumnName
IsSeekColumn
IsResidualPredicateColumn
IsJoinColumn
IsGroupByColumn
IsOrderByColumn
IsOutputColumn
IsPartitionColumn
```

## 5. Öffentliche Signatur von `USP_ExecutionPlanAnalysis`

Die folgende V1-Signatur ist eingefroren. Änderungen an Namen, Reihenfolge, Datentypen, OUTPUT-Eigenschaft oder Defaults benötigen eine neue Contract-Version:

```sql
CREATE OR ALTER PROCEDURE [monitor].[USP_ExecutionPlanAnalysis]
      @PlanXml                        xml             = NULL
    , @PlanHandle                     varbinary(64)   = NULL
    , @SessionIds                     nvarchar(max)   = NULL
    , @RequestId                      int             = NULL
    , @QueryStoreDatabaseName         sysname         = NULL
    , @QueryStorePlanId               bigint          = NULL
    , @PlanQuelle                     varchar(24)      = 'AUTO'
    , @StatementId                    int             = NULL
    , @StatementQueryHash             binary(8)       = NULL
    , @StatementQueryPlanHash         binary(8)       = NULL
    , @EvidenzJson                    nvarchar(max)   = NULL
    , @StatisticsIoText               nvarchar(max)   = NULL
    , @StatisticsTimeText             nvarchar(max)   = NULL
    , @StatisticsLanguage             varchar(16)     = 'AUTO'
    , @StatistikEvidenzModus          varchar(16)     = 'PLAN_ONLY'
    , @HistogrammModus                varchar(16)     = 'NONE'
    , @MetadatenQuellenmodus          varchar(16)     = 'EVIDENCE_ONLY'
    , @QuellumgebungBestaetigt        bit             = 0
    , @MitPredicateHistogramMap       bit             = 1
    , @AnalyseTiefe                   varchar(16)     = 'STANDARD'
    , @WorkloadProfil                 varchar(32)     = 'AUTO'
    , @Regelsatz                      varchar(32)      = 'DEFAULT'
    , @MinSchweregrad                 varchar(16)     = 'INFO'
    , @MitThreadRuntime               bit             = 0
    , @MitSqlText                     bit             = 0
    , @EvidenzDatenschutzModus        varchar(24)      = 'DERIVED_ONLY'
    , @IdentifierDatenschutzModus     varchar(16)      = 'RAW'
    , @SensitiveDataConfirmed         bit             = 0
    , @MaxOperatoren                  int             = 50000
    , @MaxFindings                    int             = 5000
    , @MaxStatistiken                 int             = 100
    , @MaxHistogrammSchritte          int             = 20000
    , @MaxDurationSeconds             int             = 30
    , @LockTimeoutMs                  int             = 0
    , @HighImpactConfirmed            bit             = 0
    , @ResultSetArt                   varchar(16)      = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max)   = NULL
    , @JsonErzeugen                   bit             = 0
    , @Json                           nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                 bit             = 1
    , @Hilfe                          bit             = 0
    , @StatusCodeOut                  varchar(40)     = NULL OUTPUT
    , @IsPartialOut                   bit             = NULL OUTPUT
    , @ErrorNumberOut                 int             = NULL OUTPUT
    , @ErrorMessageOut                nvarchar(2048)  = NULL OUTPUT;
```

### 5.1 Planquellen

Pro Aufruf ist genau eine Planquellengruppe zulässig:

- `@PlanXml`: echter Standalone-Pfad;
- `@PlanHandle`: `COMPILE`, `LAST_ACTUAL` oder `AUTO`;
- `@SessionIds` und optional `@RequestId`: aktueller, möglicherweise partieller Live-Plan;
- `@QueryStoreDatabaseName` und `@QueryStorePlanId`: Query-Store-Plan.

`AUTO` versucht Last Actual und fällt bei Nichtverfügbarkeit auf Compile zurück. Der tatsächliche Fallback wird ausgegeben. Query-Store-Pläne sind Compile-/Estimated-Evidenz; Runtimewerte stammen aus getrennten Quellen.

## 6. Öffentliche Signatur von `USP_CreateExecutionEvidenceJson`

```sql
CREATE OR ALTER PROCEDURE [monitor].[USP_CreateExecutionEvidenceJson]
      @PlanXml                       xml             = NULL
    , @StatisticsIoText              nvarchar(max)   = NULL
    , @StatisticsTimeText            nvarchar(max)   = NULL
    , @StatisticsLanguage            varchar(16)     = 'AUTO'
    , @StatisticsEvidenceJson        nvarchar(max)   = NULL
    , @ObjectMetadataJson            nvarchar(max)   = NULL
    , @StatistikEvidenzModus         varchar(16)     = 'PLAN_ONLY'
    , @HistogrammModus               varchar(16)     = 'NONE'
    , @MetadatenQuellenmodus         varchar(16)     = 'EVIDENCE_ONLY'
    , @QuellumgebungBestaetigt       bit             = 0
    , @EvidenzDatenschutzModus       varchar(24)     = 'DERIVED_ONLY'
    , @IdentifierDatenschutzModus    varchar(16)     = 'RAW'
    , @SensitiveDataConfirmed        bit             = 0
    , @MitPredicateHistogramMap      bit             = 1
    , @StatementId                   int             = NULL
    , @StatementOrdinal              int             = NULL
    , @SameExecutionAsPlanConfirmed  bit             = NULL
    , @CapturedAtUtc                 datetime2(3)    = NULL
    , @SourceProductVersion          nvarchar(128)   = NULL
    , @SourceCompatibilityLevel      smallint        = NULL
    , @SourceEngineEdition           int             = NULL
    , @MaxStatistiken                int             = 100
    , @MaxHistogrammSchritte         int             = 20000
    , @LockTimeoutMs                 int             = 0
    , @HighImpactConfirmed           bit             = 0
    , @AdditionalEvidenceJson        nvarchar(max)   = NULL
    , @ExistingEvidenceJson          nvarchar(max)   = NULL
    , @RawTextHandling               varchar(16)     = 'HASH_ONLY'
    , @StrictValidation              bit             = 1
    , @ResultSetArt                  varchar(16)     = 'CONSOLE'
    , @ResultTablesJson              nvarchar(max)   = NULL
    , @JsonErzeugen                  bit             = 1
    , @Json                          nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                bit             = 1
    , @Hilfe                         bit             = 0
    , @StatusCodeOut                 varchar(40)     = NULL OUTPUT
    , @IsPartialOut                  bit             = NULL OUTPUT
    , @ErrorNumberOut                int             = NULL OUTPUT
    , @ErrorMessageOut               nvarchar(2048)  = NULL OUTPUT;
```

### 6.1 Statistik-Evidenzmodi

```text
NONE
PLAN_ONLY
USED
RELEVANT
OBJECT_ALL
```

- `PLAN_ONLY`: nur `OptimizerStatsUsage` aus dem XML;
- `USED`: aktueller Zustand exakt der im Plan verwendeten Statistiken;
- `RELEVANT`: zusätzlich Statistiken auf Seek-, Residual-, Join-, Group-, Order- und Partition-Predicate-Spalten;
- `OBJECT_ALL`: alle sichtbaren Statistiken referenzierter Objekte; High-Impact-Pfad.

Default ist `PLAN_ONLY`.

### 6.2 Histogrammmodi

```text
NONE
SUMMARY
STEPS
```

- `NONE`: keine Histogrammdaten;
- `SUMMARY`: nur abgeleitete Verteilungskennzahlen;
- `STEPS`: vollständige Schritte, weiterhin unter Datenschutzsteuerung; High-Impact-Pfad.

Default ist `NONE`.

### 6.3 Metadatenquellenmodi

```text
EVIDENCE_ONLY
CURRENT_SERVER
```

`CURRENT_SERVER` ist nur mit `@QuellumgebungBestaetigt = 1` zulässig. Ein importierter Plan wird nie automatisch gegen ähnlich benannte lokale Datenbanken oder Objekte aufgelöst.

## 7. Evidenz-JSON

### 7.1 Zielstruktur

```json
{
  "meta": {
    "resultName": "ExecutionEvidence",
    "schemaVersion": 1
  },
  "capture": {},
  "sourceEnvironment": {},
  "planIdentity": {},
  "statisticsIo": [],
  "statisticsTime": [],
  "statistics": {
    "planUsage": [],
    "currentSnapshot": [],
    "histogramSummaries": [],
    "histogramSteps": []
  },
  "objectReferences": [],
  "predicateHistogramMappings": [],
  "collectionStatus": [],
  "warnings": [],
  "rawInput": {},
  "importedEvidence": {},
  "additionalEvidence": null
}
```

Das Analyse-JSON weist in `meta.evidencePrivacyMode` und `meta.identifierPrivacyMode` die für seine Ausgabe tatsächlich angewendeten Modi aus. Dadurch kann ein Consumer die Datenschutzprojektion prüfen, ohne Identifier- oder Rohwerte auszuwerten.

Das Plan-XML wird standardmäßig nicht im Evidenz-JSON dupliziert. `planIdentity` enthält nur korrelationsfähige Merkmale wie Planhash, Statement-ID, Query Hash und Query Plan Hash.

### 7.2 Capture-Confidence

```text
CONFIRMED
PLAN_AND_MESSAGES_CAPTURED_TOGETHER
QUERY_AND_PLAN_IDENTITY_MATCH
STATEMENT_MAPPING_INFERRED
PLAN_LEVEL_ONLY
UNCONFIRMED
```

Eine direkte operatorbezogene Korrelation setzt ausreichende Confidence voraus. Andernfalls bleiben `STATISTICS IO` und `STATISTICS TIME` auf Statement- oder Planebene.

### 7.3 Raw-Text-Handling

```text
NONE
HASH_ONLY
INCLUDE
```

Default ist `HASH_ONLY`. Gespeichert werden nur Länge und Capture-spezifischer Hash. `INCLUDE` benötigt `@SensitiveDataConfirmed = 1` und `@IdentifierDatenschutzModus = 'RAW'`, weil Rohzeilen sensible Werte und nicht zuverlässig einzeln anonymisierbare Identifikatoren enthalten können. `INCLUDE` ist kein Repositorymodus und darf reale Meldungsinhalte nicht in Tests, Dokumentation oder Artefakte übernehmen.

## 8. Statistik- und Histogramm-Evidenz

### 8.1 Drei Zeitstände

Statistikdaten werden getrennt modelliert:

1. **Compilezeit:** aus `OptimizerStatsUsage/StatisticsInfo` im Plan;
2. **aktueller Snapshot:** aus `sys.stats`, `sys.stats_columns`, `sys.columns`, `sys.indexes` und `sys.dm_db_stats_properties` der bestätigten Quellumgebung;
3. **Verteilung:** optional aus `sys.dm_db_stats_histogram` oder einer daraus abgeleiteten Zusammenfassung.

### 8.2 Compilezeitwerte

```text
StatementOrdinal
DatabaseName
SchemaName
ObjectName
StatisticsName
LastUpdateAtCompile
ModificationCountAtCompile
SamplingPercentAtCompile
EvidenceSource
```

### 8.3 Aktueller Statistikzustand

```text
DatabaseName
SchemaName
ObjectName
ObjectId
StatisticsId
StatisticsName
IsIndexStatistics
IsAutoCreated
IsUserCreated
IsFiltered
FilterDefinitionStatus
NoRecompute
IsIncremental
HasPersistedSample
LastUpdated
Rows
RowsSampled
SamplePercent
Steps
UnfilteredRows
ModificationCounter
ModificationPercent
PersistedSamplePercent
CollectionStatus
CapturedAtUtc
```

Eine leere DMF-Ausgabe bedeutet nicht `0`, sondern einen expliziten Status wie `NOT_VISIBLE`, `NO_LONGER_EXISTS`, `UNAVAILABLE_PERMISSION` oder `UNAVAILABLE_SOURCE`.

### 8.4 Statistikspalten

```text
StatisticsId
StatisticsName
StatisticsColumnOrdinal
ColumnId
ColumnName
IsHistogramColumn
```

Nur die erste Statistikspalte besitzt ein Histogramm. Ein Predicate auf einer späteren Spalte wird mit `NON_LEADING_STATISTICS_COLUMN` gekennzeichnet und keinem Histogrammschritt zugeordnet.

## 9. Datenschutz für Histogramme, Parameter und Predicates

### 9.1 Risiko

`RANGE_HI_KEY`, Parameterwerte, Literale, `IN`-Listen, Filterdefinitionen und Partitionsgrenzen können personenbezogene, kundenbezogene, organisatorische oder proprietäre Informationen enthalten. Konkrete Werte sind für die Verteilungsanalyse meistens nicht notwendig.

### 9.2 Datenschutzmodi

```text
DERIVED_ONLY
TOKENIZED
RAW
STRUCTURE_ONLY
```

Default ist `DERIVED_ONLY`.

- `DERIVED_ONLY`: Rohwerte werden nur lokal für das Matching verwendet und nicht ausgegeben;
- `TOKENIZED`: capturebezogene, nicht captureübergreifend vergleichbare Tokens;
- `RAW`: konkrete Werte, nur nach `@SensitiveDataConfirmed = 1`;
- `STRUCTURE_ONLY`: auch Tokens entfallen; nur Struktur und Verteilungsmetriken.

`RAW` ohne Bestätigung liefert `SENSITIVE_DATA_CONFIRMATION_REQUIRED`.

`@MitSqlText = 1` ist ein separater sensibler Ausgabepfad und benötigt ebenfalls `@SensitiveDataConfirmed = 1`, weil `StatementText` Literale und proprietären SQL-Text enthalten kann. Die übrigen strukturierten Werte folgen weiterhin dem gewählten Evidenz-Datenschutzmodus.

### 9.3 Identifier-Datenschutz

```text
RAW
TOKENIZED
OMIT
```

Der separate `@IdentifierDatenschutzModus` gilt für Datenbank-, Schema-, Objekt-, Index-, Statistik- und Spaltennamen. Repositorybeispiele verwenden ausschließlich `Example*`-Bezeichner.

### 9.4 Verarbeitungsreihenfolge

1. Das Verfahren liest Histogrammwerte lokal und kurzfristig.
2. Es normalisiert Predicate- und Parameterwerte lokal.
3. Es gleicht die Werte mit Histogramm und Statistikspalten ab.
4. Es speichert die abgeleiteten Beziehungen.
5. Es entfernt oder tokenisiert die Rohwerte.
6. Erst danach erzeugt es das Evidenz-JSON.

Die Anonymisierung darf nicht vor dem Mapping erfolgen.

### 9.5 Predicate-Histogramm-Mapping

Ein eigenes normalisiertes Resultset ist die Quelle der Wahrheit:

```text
PredicateReferenceId
StatementOrdinal
NodeId
StatisticsReferenceId
ColumnReferenceId
PredicateKind
ValueSource
MappingStatus
MappingConfidence
MatchedStepOrdinal
FirstMatchedStepOrdinal
LastMatchedStepOrdinal
CoveredStepCount
MatchesRangeHighKey
IsBelowHistogram
IsAboveHistogram
IsWithinRange
HistogramStepDistance
CumulativeRowMassBetweenValuesPercent
SensitiveValueStatus
EvidenceLimit
```

`ValueSource` unterscheidet mindestens:

```text
COMPILED_PARAMETER
RUNTIME_PARAMETER
LITERAL
IN_LIST_VALUE
RANGE_LOWER_BOUNDARY
RANGE_UPPER_BOUNDARY
```

`MappingStatus` unterscheidet mindestens:

```text
EXACT_RANGE_HIGH_KEY
WITHIN_HISTOGRAM_RANGE
BELOW_HISTOGRAM_MINIMUM
ABOVE_HISTOGRAM_MAXIMUM
RANGE_COVERS_MULTIPLE_STEPS
PARTIAL_LOWER_STEP
PARTIAL_UPPER_STEP
MULTIPLE_DISCRETE_STEPS
NON_LEADING_STATISTICS_COLUMN
NON_SARGABLE_EXPRESSION
TYPE_CONVERSION_FAILED
COLLATION_CONTEXT_UNAVAILABLE
AMBIGUOUS_STATISTICS_MATCH
NOT_MAPPABLE
```

Histogrammschritte können zusätzlich Convenience-Felder wie `IsCompileValueTarget`, `IsRuntimeValueTarget`, `IsInsidePredicateRange` und `PredicateMatchCount` erhalten. Sie ersetzen das Mappingresultset nicht.

### 9.6 Tokenisierung

Ein einfacher ungesalzener Hash ist für kleine oder vorhersehbare Wertebereiche nicht ausreichend. `TOKENIZED` verwendet einen zufälligen Capture-Salt, Datentypinformation und den normalisierten Wert. Der Salt wird nicht ins JSON geschrieben. Captureübergreifende Gleichheitsvergleiche sind standardmäßig nicht möglich.

## 10. Zielgerichtete Metadatenermittlung

`monitor.InternalCollectExecutionPlanMetadata` verwendet die Extractor-Funktionen, dedupliziert erst für den Katalogzugriff und gruppiert nach Datenbank. Die Objektauflösung erfolgt relational über Systemkataloge und nicht über `OBJECT_ID()` oder `OBJECT_NAME()`.

Vorgesehener Zugriff je bestätigter Datenbank:

```text
sys.schemas
sys.objects
sys.tables
sys.views
sys.indexes
sys.index_columns
sys.columns
sys.stats
sys.stats_columns
sys.dm_db_stats_properties
sys.dm_db_stats_histogram
```

`sys.dm_db_stats_properties` erhält die zuvor relational ermittelten `object_id`- und `stats_id`-Werte.

Katalogzugriffe verwenden `SET LOCK_TIMEOUT 0` beziehungsweise den kontrollierten Parameterwert und behandeln jede Datenbank isoliert. Einzelne nicht auflösbare Objekte machen die übrige Analyse nicht ungültig.

## 11. Sonderfälle der Objektauflösung

```text
TEMP_OBJECT_NOT_RESOLVABLE
TEMP_OBJECT_RESOLVED_IN_CURRENT_SESSION
TEMP_OBJECT_EXPIRED
TABLE_VARIABLE_PLAN_ONLY
REMOTE_OBJECT_NO_LOCAL_METADATA
INTERNAL_WORKTABLE
INTERNAL_WORKFILE
SPOOL_STORAGE
SYNONYM_RESOLUTION_UNAVAILABLE
```

Views werden nach dem im Plan tatsächlich sichtbaren Zugriff beurteilt. Indexed Views können als physischer Zugriff auftreten. Remote Objects werden nicht lokal aufgelöst. Temporäre Objekte und Tabellenvariablen bleiben planbezogene Evidenz, wenn die Quellstruktur nicht mehr existiert.

## 12. `STATISTICS IO` und `STATISTICS TIME`

### 12.1 Nutzen

`STATISTICS IO` ergänzt objektbezogene Seitenarbeit, Worktable-/Workfile-Aktivität, LOB Reads, Read-Ahead und Scan Count. `STATISTICS TIME` ergänzt Parse-/Compile- und Execution-CPU sowie Elapsed Time.

### 12.2 Aussagegrenze

`STATISTICS IO` liefert objektbezogene Summen und keine sichere allgemeine Operatorzuordnung. Eine operatorbezogene Korrelation ist nur zulässig, wenn genau ein passender Access-Operator existiert, Statement und Objekt eindeutig sind und dieselbe Ausführung bestätigt wurde.

### 12.3 Parserstatus

```text
PARSED
PARSED_PARTIAL
UNSUPPORTED_LANGUAGE
AMBIGUOUS_STATEMENT_MAPPING
UNRECOGNIZED_FORMAT
```

Initial werden `DE`, `EN` und `AUTO` vorgesehen. Sprachabhängiges Raw-Text-Parsing ist best effort. Strukturierte Evidenz besitzt höhere Confidence.

### 12.4 Keine automatische Messung

Die SQL-Procedures führen kein beliebiges SQL aus. Ein späterer separater Client-Collector kann ausdrücklich durch den Benutzer gestartete Abfragen mit `STATISTICS XML`, `STATISTICS IO` und `STATISTICS TIME` erfassen und anschließend Plan XML plus Evidenz-JSON an das Framework übergeben.

## 13. Statement- und Operatorplanmodell

### 13.1 Planidentität

```text
PlanDocumentId
PlanDocumentHash
PlanSource
RuntimeCounterScope
ShowplanVersion
ShowplanBuild
SourceProductVersion
CompatibilityLevel
CardinalityEstimationModelVersion
IsPlanComplete
```

`RuntimeCounterScope`:

```text
NONE
LAST_COMPLETED_EXECUTION
CURRENT_PARTIAL_EXECUTION
IMPORTED_ACTUAL
QUERY_STORE_AGGREGATE
UNKNOWN
```

### 13.2 Statements

```text
PlanDocumentId
StatementOrdinal
StatementId
StatementCompId
StatementType
StatementText
StatementQueryHash
StatementQueryPlanHash
StatementSubTreeCost
StatementEstimatedRows
OptimizationLevel
EarlyAbortReason
CompileTimeMs
CompileCpuMs
CompileMemoryKb
CardinalityEstimationModelVersion
RetrievedFromCache
NonParallelPlanReason
```

`StatementOrdinal` ist eine eigene deterministische Sequenz und der interne Schlüssel.

### 13.3 Operatorbaum

```text
PlanDocumentId
StatementOrdinal
NodeId
ParentNodeId
ChildOrdinal
Depth
OperatorPath
PhysicalOp
LogicalOp
EstimateRows
EstimatedRowsRead
EstimateExecutions
EstimateRebinds
EstimateRewinds
EstimateCpu
EstimateIo
AverageRowSize
EstimatedTotalSubtreeCost
Parallel
EstimatedExecutionMode
ActualExecutionMode
Ordered
ScanDirection
```

Der Baum ist keine lineare zeitliche Ablaufbeschreibung. Datenfluss, Demand-Richtung, blockierende Operatoren und parallele Regionen werden getrennt beschrieben.

### 13.4 Runtime Counter

Granularität:

```text
PlanDocumentId
StatementOrdinal
NodeId
ThreadId
BrickId
```

Werte:

```text
ActualRows
ActualRowsRead
ActualExecutions
ActualRebinds
ActualRewinds
ActualEndOfScans
ActualScans
ActualLogicalReads
ActualPhysicalReads
ActualReadAheads
ActualCpuMs
ActualElapsedMs
ActualLobLogicalReads
ActualLobPhysicalReads
```

Threadwerte werden zuerst vollständig und paarweise erfasst. Aggregation erfolgt danach.

## 14. Sichere `ActualRowsRead`-Kennzahlen

`ActualRows` und `ActualRowsRead` werden nur aus derselben Runtime-Counter-Zeile gepaart. Zusätzlich werden erfasst:

```text
RuntimeCounterCount
RowsReadCounterCount
RowsReadCounterCoveragePercent
PairedActualRows
PairedActualRowsRead
RowsReadNotReturned
RowsReadNotReturnedPercent
```

`ResidualDiscardPercent` wird nur bezeichnet, wenn im selben Access-Operator tatsächlich ein residuales Predicate nachgewiesen wurde.

Statuswerte:

```text
AVAILABLE
NO_RUNTIME_INFORMATION
ACTUAL_ROWS_READ_NOT_AVAILABLE
NOT_APPLICABLE_OPERATOR
PARTIAL_COUNTER_COVERAGE
INCONSISTENT_COUNTERS
ZERO_ROWS_READ
```

Sichere Berechnung:

```sql
CASE
    WHEN [PairedActualRowsRead] IS NULL
      OR [PairedActualRows] IS NULL
        THEN NULL
    WHEN [PairedActualRowsRead] <= 0
        THEN NULL
    WHEN [PairedActualRows] < 0
      OR [PairedActualRows] > [PairedActualRowsRead]
        THEN NULL
    ELSE
        CONVERT
        (
            decimal(19,6),
            CONVERT(decimal(38,12), 100)
            *
            (
                CONVERT(decimal(38,12), [PairedActualRowsRead])
                -
                CONVERT(decimal(38,12), [PairedActualRows])
            )
            /
            CONVERT(decimal(38,12), [PairedActualRowsRead])
        )
END
```

Die Konvertierung erfolgt vor der Subtraktion, damit auch ein vorgelagerter `bigint`-Overflow vermieden wird.

## 15. Cardinality-Kennzahlen

```text
EstimatedRowsPerExecution
EstimatedExecutions
EstimatedRowsTotal
ActualRowsPerExecution
ActualExecutions
ActualRowsTotal
AbsoluteRowDifference
ActualToEstimatedRatio
CardinalityLog10Error
EstimatedFlowBytes
ActualFlowBytes
```

Heuristische Größenordnung:

```text
ABS(LOG10((ActualRowsTotal + 1) / (EstimatedRowsTotal + 1)))
```

Eine relative Abweichung erzeugt erst zusammen mit absoluter Arbeit, Wiederholung und Workloadwirkung ein höheres Finding. Rebinds, Rewinds und tatsächliche Ausführungsanzahl werden einbezogen.

## 16. Workloadprofile und Schwellenwerte

### 16.1 Profile

```text
LATENCY_SENSITIVE
BALANCED
THROUGHPUT
MAINTENANCE
UNKNOWN
```

- `LATENCY_SENSITIVE`: CPU, Reads und Dauer je Ausführung sowie hohe Frequenz;
- `THROUGHPUT`: Gesamtmenge, Spill, TempDB, DOP, Grant und Gesamtdurchsatz;
- `MAINTENANCE`: große Scans und Sorts können erwartbar sein, bleiben aber sichtbar;
- `BALANCED`: neutraler Default;
- `UNKNOWN`: keine workloadabhängige Verschärfung.

### 16.2 Profilauflösung

Priorität:

1. expliziter Parameter;
2. Query-Store-Query-ID;
3. Datenbank plus Query Hash;
4. Objekt plus Statement;
5. Resource Pool oder Workload Group;
6. Datenbankzuordnung;
7. automatische Klassifikation;
8. `BALANCED`.

Ausgegeben werden `ProfileResolutionSource` und `ProfileResolutionConfidence`.

### 16.3 Steuertabellen

`PlanAnalysisRuleThreshold` enthält nur Datenwerte wie Mindestverhältnis, Mindestzeilen, Mindestreads, Mindesthäufigkeit, Mindestdauer, Mindest-CPU, Mindestspill, Mindestmemory, Mindestversion und erforderliches Evidenzniveau. Ausführbare SQL-Ausdrücke, freie WHERE-Fragmente oder EAV-Regelprogramme sind verboten. Die Regelimplementierung bleibt in geprüftem T-SQL.

Severity kann als Maximum aus Per-Execution- und Cumulative-Impact bestimmt werden. Ein häufiges kleines OLTP-Problem und eine einzelne sehr große Batchausführung bleiben dadurch beide erkennbar.

## 17. Indexverwendung und Reihenfolge

### 17.1 Seek-Eignung

Zu vergleichen sind Indexschlüsselreihenfolge, Seek Predicates, Gleichheitspräfix, erste Range-Spalte, nicht eingeschränkte führende Spalten und Residual Predicates.

Findingcodes:

```text
INDEX_LEADING_KEY_NOT_CONSTRAINED
INDEX_KEY_ORDER_LIMITS_SEEK
LATER_KEY_USED_AS_RESIDUAL
RANGE_KEY_PREVENTS_DEEPER_SEEK
```

Die Aussage lautet nicht „Index ist falsch“, sondern beschreibt die konkrete Einschränkung dieses Zugriffspfads.

### 17.2 Sortierreihenfolge

Zu vergleichen sind Required Order, Index Key Order, ASC/DESC, Equality Prefix, Scan Direction, Ordered-Attribut und gegebenenfalls Exchange-Operatoren. Ein vollständig umgekehrter Schlüssel kann über Backward Scan weiterhin geeignet sein.

Findingcodes:

```text
INDEX_ORDER_DOES_NOT_SATISFY_REQUIRED_ORDER
INDEX_ORDER_SUPPORTS_PARTIAL_REQUIRED_ORDER
EXPENSIVE_SORT_POTENTIALLY_AVOIDABLE
INDEX_BACKWARD_SCAN
ORDER_PRESERVATION_LOST_BY_EXCHANGE
```

`INDEX_BACKWARD_SCAN` ist standardmäßig nur `INFO`. Ein Indexreview wird erst durch relevante Sortmenge, Spill, CPU, Häufigkeit oder kumulative Last priorisiert.

## 18. Regelgruppen

### 18.1 Cardinality

```text
CARDINALITY_UNDERESTIMATE
CARDINALITY_OVERESTIMATE
CARDINALITY_ERROR_HIGH_IMPACT
ZERO_ESTIMATE_WITH_ACTUAL_ROWS
ESTIMATE_ERROR_PROPAGATION
```

### 18.2 Access und Datenmengen

```text
ROWS_READ_NOT_RETURNED
RESIDUAL_PREDICATE_HIGH_DISCARD
SEEK_WITH_HIGH_RESIDUAL_WORK
SCAN_WITH_LOW_RETURN_RATE
LARGE_SCAN_HIGH_WORK
```

### 18.3 Loops und Lookups

```text
LOOKUP_PRESENT
LOOKUP_HIGH_EXECUTION_COUNT
LOOKUP_HIGH_READ_VOLUME
NESTED_LOOPS_INNER_WORK_AMPLIFICATION
NESTED_LOOPS_SCAN_AMPLIFICATION
```

### 18.4 Sort, Hash und TempDB

```text
SORT_SPILL
HASH_SPILL
HASH_RECURSION
HASH_BAILOUT
EXCHANGE_SPILL
LARGE_BLOCKING_SORT
SORT_HIGH_ROW_WIDTH
```

### 18.5 Memory Grant

```text
MEMORY_GRANT_OVER
MEMORY_GRANT_WAIT
MEMORY_GRANT_UNDER_WITH_SPILL
MEMORY_GRANT_FEEDBACK_ACTIVE
MEMORY_GRANT_FEEDBACK_DISABLED
```

`MaxUsedMemory = GrantedMemory` allein ist kein Undergrant-Beweis.

### 18.6 Parallelismus

```text
PARALLEL_THREAD_SKEW
PARALLEL_ZERO_WORKERS
SERIAL_PLAN_HIGH_WORK
FORCED_SERIALIZATION
INEFFECTIVE_PARALLELISM_REVIEW
```

### 18.7 Row Goals, Spools und Merge

```text
ROW_GOAL_PRESENT
ROW_GOAL_LARGE_ACTUAL_ROWS
ROW_GOAL_NESTED_LOOPS_AMPLIFICATION
ROW_GOAL_SCAN_REPEATED
EAGER_INDEX_SPOOL_HIGH_WORK
LARGE_TABLE_SPOOL
SPOOL_REBUILT_REPEATEDLY
SPOOL_NOT_EFFECTIVELY_REUSED
MANY_TO_MANY_MERGE_HIGH_REWINDS
```

### 18.8 Conversions und Compile

```text
PLAN_AFFECTING_CONVERT
SEEK_BLOCKING_IMPLICIT_CONVERT
CARDINALITY_AFFECTING_CONVERT
NON_SARGABLE_PREDICATE_REVIEW
OPTIMIZER_TIMEOUT
OPTIMIZER_MEMORY_LIMIT
HIGH_COMPILE_CPU
HIGH_COMPILE_MEMORY
FREQUENT_HIGH_COST_RECOMPILE
TRIVIAL_PLAN_CONTEXT
```

### 18.9 Statistik-Korrelation

```text
STATISTICS_USED_AT_COMPILE
STATISTICS_NO_LONGER_EXISTS
STATISTICS_UPDATED_SINCE_COMPILE
STATISTICS_CHANGED_AFTER_PLAN_COMPILE
STATISTICS_HIGH_MODIFICATION_AT_COMPILE
STATISTICS_HIGH_CURRENT_MODIFICATION
STATISTICS_LOW_SAMPLE_AT_COMPILE
STATISTICS_LOW_CURRENT_SAMPLE
STATISTICS_SAMPLE_CHANGED
STATISTICS_FILTER_MISMATCH_REVIEW
STATISTICS_LEADING_COLUMN_MISMATCH
PREDICATE_WITHOUT_RELEVANT_STATISTICS
CARDINALITY_ERROR_CORRELATED_WITH_STATISTICS
HISTOGRAM_SKEW_CORRELATED_WITH_PARAMETER
COMPILED_RUNTIME_DIFFERENT_HISTOGRAM_STEPS
COMPILED_RUNTIME_LARGE_DISTRIBUTION_DISTANCE
RUNTIME_VALUE_OUTSIDE_COMPILE_HISTOGRAM_RANGE
PARAMETER_SENSITIVITY_DISTRIBUTION_EVIDENCE
```

## 19. Findingvertrag

```text
FindingOrdinal
FindingCode
Category
Severity
Confidence
EvidenceLevel
PlanDocumentId
StatementOrdinal
StatementId
NodeId
PhysicalOp
LogicalOp
MetricName
MetricValue
MetricUnit
ThresholdValue
ThresholdSource
WorkloadProfile
Summary
Evidence
EvidenceLimit
CounterEvidence
RecommendedNextCheck
```

Severity:

```text
INFO
LOW
MEDIUM
HIGH
CRITICAL
```

Confidence:

```text
EXPLICIT_RUNTIME_WARNING
RUNTIME_MEASURED
RUNTIME_CORRELATED
RUNTIME_INFERRED
COMPILE_WARNING
COMPILE_HEURISTIC
HISTORICAL_CORRELATION
```

## 20. Versionsadaptive Verarbeitung

### 20.1 Entscheidungsgrundlagen

```text
ServerMajorVersion
ServerProductVersion
ShowplanVersion
ShowplanBuild
CompatibilityLevel
CardinalityEstimationModelVersion
PlanSource
tatsächlich vorhandene XML-Attribute und Elemente
```

Die Major Version allein genügt nicht, weil Attribute durch Service Packs oder CUs verfügbar werden können.

### 20.2 Zielmatrix

- SQL Server 2019: Compile Showplan, Last Known Actual bei aktivierter Quelle, Runtime Counter, Query-Stats-Grants und Spills;
- SQL Server 2022 und Compatibility Level 160: zusätzlich PSP, Query Variants, Query Store Plan Feedback, persistiertes Memory Grant Feedback, CE- und DOP-Feedback;
- SQL Server 2025 und Compatibility Level 170: zusätzlich OPPO und weitere IQP-Erweiterungen.

### 20.3 Implementierungsregeln

- XML wird nach tatsächlichem Vorhandensein von Attributen ausgewertet;
- fehlende Informationen ergeben `NULL` plus Capability-Status;
- unbekannte zukünftige Elemente brechen den Parser nicht ab;
- versionsabhängige Katalog- und DMV-Abfragen werden nur in geeigneten Dynamic-SQL-Zweigen kompiliert;
- Quellversion und Version des analysierenden Servers bleiben getrennt;
- jede Regel besitzt eine erforderliche Capability und ein Mindest-Evidenzniveau.

## 21. Capability-Resultset

```text
AnalysisObjectId
FeatureCode
IsAvailable
AvailabilityReason
EvidenceSource
Detail
```

Die in V1 eingefrorenen Capabilitycodes sind:

```text
STATEMENTS
OPERATOR_TREE
EXECUTION_EVIDENCE_JSON
ACTUAL_RUNTIME
ACTUAL_ROWS_READ
THREAD_RUNTIME
PSP_VARIANT
OPPO_VARIANT
```

`AvailabilityReason` unterscheidet insbesondere `AVAILABLE`, fehlende XML-Attribute, nicht angeforderte Threaddetails, ungültige externe Evidenz und nicht auflösbare Operatorpfade. Neue Capabilitycodes sind additive V1-Erweiterungen; Umdeutung oder Entfernung eines bestehenden Codes benötigt eine neue Contract-Version.

## 22. Resultsets

CONSOLE liefert im Normalfall genau das menschenorientierte Hauptresultset `findings`.

RAW, TABLE und JSON können folgende benannte Resultsets liefern:

```text
moduleStatus
capabilities
planDocuments
statements
operatorTree
operatorRuntime
operatorThreadRuntime
accessPaths
statisticsUsage
parametersAndVariants
memoryAndSpills
executionEvidence
histogramSummaries
histogramSteps
predicateHistogramMappings
findings
```

`USP_CreateExecutionEvidenceJson` besitzt den separaten CONSOLE-Default `captureStatus` und die V1-Resultsets `captureStatus`, `statisticsIo`, `statisticsTime`, `planStatisticsUsage`, `objectReferences`, `currentStatistics`, `histogramSummaries`, `histogramSteps`, `predicateHistogramMappings`, `collectionStatus` und `warnings`.

Jedes benannte Resultset besitzt `schemaVersion = 1`. Exakte Spalten, Datentypen, NULL-Eigenschaften, Reihenfolge und Exportfähigkeit stehen im kanonischen [`Metadata/Inventory/ResultSets.csv`](../../Metadata/Inventory/ResultSets.csv). Änderungen werden dort und im maschinenlesbaren Public Contract gemeinsam versioniert.

## 23. Eigenlast und Locking

- Plan-XML je Plan einmal laden und einmal technisch zerlegen;
- keine wiederholten vollständigen XML-Scans je Findingregel;
- Statements, RelOps, Runtime Counter, Predicates und Warnings in relationalen Stagingtabellen materialisieren;
- aktuelle Statistik- und Query-Store-Anreicherung standardmäßig deaktiviert;
- Histogrammzugriff erst nach Kandidateneingrenzung;
- Per-Thread-Ausgabe opt-in;
- Time-, Operator-, Finding-, Statistik- und Histogrammbudgets;
- planweise Fehlerisolation;
- `SET LOCK_TIMEOUT 0` beziehungsweise expliziter kontrollierter Wert für einzelne Kataloganreicherungen;
- keine Abfrage von Benutzerdaten zur Ermittlung der Verteilung;
- kein automatisches Tuning und keine Konfigurationsänderung.

## 24. Tests und Abnahmekriterien

### 24.1 Planstruktur

- ein Statement;
- mehrere Statements im selben Batch;
- gleiche `NodeId` in unterschiedlichen Statements;
- verschachtelte Operatorbäume;
- unbekannte zusätzliche XML-Attribute;
- fehlende optionale Elemente.

### 24.2 Estimated und Actual

- Compile Plan ohne Runtime Counter;
- Last Actual Plan;
- partieller Live Plan;
- fehlendes, partiell vorhandenes und inkonsistentes `ActualRowsRead`;
- null gelesene oder zurückgegebene Zeilen;
- sehr große `bigint`-Werte ohne Overflow.

### 24.3 Operatorregeln

- kleiner und großer Lookup;
- Scan mit hoher und niedriger Selektivität;
- Sort mit und ohne Spill;
- Hash- und Exchange-Spill;
- Eager Spool;
- Many-to-Many Merge;
- Row Goal;
- Parallel Thread Skew.

### 24.4 Indexreihenfolge

- vollständiger Equality Prefix;
- nicht eingeschränkte führende Schlüsselspalte;
- Range auf mittlerer Schlüsselspalte;
- spätere Schlüssel nur residual;
- vollständig passendes `ORDER BY`;
- rückwärts lesbarer Index;
- teilweise passende gemischte ASC-/DESC-Reihenfolge;
- zusätzlicher Sort trotz Index.

### 24.5 Statistik und Datenschutz

- Compilezeit-Statistics Usage;
- aktueller Snapshot unverändert, geändert, nicht sichtbar und nicht mehr vorhanden;
- Histogramm `SUMMARY` und `STEPS`;
- führende und nicht führende Statistikspalte;
- Equality-, Range- und `IN`-Mapping;
- Compile- und Runtimewert in demselben und in verschiedenen Steps;
- `DERIVED_ONLY`, `TOKENIZED`, `RAW` und `STRUCTURE_ONLY`;
- Nachweis, dass `DERIVED_ONLY` keine konkreten Histogramm-, Parameter- oder Literalwerte ausgibt;
- `RAW` ohne Bestätigung wird abgelehnt;
- keine realen Werte in Fixtures oder Testartefakten.

### 24.6 Evidenzparser

- deutsche und englische `STATISTICS IO`-Meldungen;
- Worktable, Workfile und LOB Reads;
- mehrere Statements und Objekte;
- deutsche und englische `STATISTICS TIME`-Meldungen;
- unvollständige und unbekannte Formate.

### 24.7 Versionsmatrix

GitHub Actions testet SQL Server 2019, 2022 und 2025. Nicht verfügbare Features liefern Capability-Status und `NULL`, keinen Compile- oder Laufzeitfehler.

### 24.8 Ausgabevertrag

- CONSOLE genau ein fachliches Hauptresultset;
- RAW nativ typisiert;
- TABLE mit semantisch benannten Resultsets;
- gültiges versioniertes JSON;
- `NONE` ohne Resultsets;
- JSON-OUTPUT unabhängig von CONSOLE;
- kein zweiter Systemzugriff für den Export bereits materialisierter Daten.

## 25. Umsetzungswellen

Die Wellen dokumentieren den Implementierungsweg und den Umfang des eingefrorenen V1-Kerns. Nicht im V1-Resultsetinventar enthaltene Vertiefungen bleiben mögliche spätere Erweiterungen und sind kein stillschweigender Bestandteil des Public Contracts.

### Welle 0 – Vertragsfreeze – abgeschlossen für V1

- öffentliche und interne Objektrollen;
- Parameter;
- Resultsetnamen und Schemata;
- Evidenz-JSON-Schema;
- Finding- und Capabilitycodes;
- Installer-Dependency-Manifest;
- ausführbare statische und synthetische Runtime-Contracts.

### Welle 1 – XML-Extractor und Standalone-Kern – abgeschlossen für V1

- Objekt-, Statistik- und Spalten-Extractor;
- Statementidentität;
- Operatorbaum;
- Runtime Counter;
- sichere `ActualRowsRead`- und Cardinality-Kennzahlen;
- direkter `@PlanXml`-Aufruf.

### Welle 2 – Evidenzerzeugung – abgeschlossen für V1

- `STATISTICS IO`-/`TIME`-Parser;
- `USP_CreateExecutionEvidenceJson`;
- Capture-Confidence;
- JSON-Validierung und Raw-Text-Handling.

### Welle 3 – Statistik, Histogramm und Datenschutz – abgeschlossen für V1

- zielgerichteter Metadata Collector;
- Compile-/Current-State-Korrelation;
- Histogrammzusammenfassung und Mapping;
- Datenschutzmodi und `sensitiveDataStatus`.

### Welle 4 – Regeln und Workloadprofile – V1-Kern abgeschlossen

- Profile und Schwellenwerttabellen;
- Severity und Confidence;
- Cardinality-, Access-, Lookup-, Scan-, Spill-, Grant- und Parallelismusregeln.

### Welle 5 – Index- und Predicate-Analyse – V1-Basismodell implementiert

- Seek Keys und Residual Predicates;
- Schlüsselpräfix und Range-Position;
- ASC/DESC, Required Order, Backward Scan und Sortvermeidung.

### Welle 6 – SQL-Versionen und IQP – abgeschlossen für V1

- SQL-2019-Capabilities;
- PSP und Plan Feedback für 2022+;
- OPPO für 2025+;
- unbekannte zukünftige Showplan-Elemente.

### Welle 7 – Frameworkintegration – zentraler Wrapperpfad implementiert

- `USP_ShowplanAnalysis` auf den zentralen Kern umstellen;
- Planhandles deduplizieren;
- `USP_PlanCacheAnalysis` weiterleiten;
- Überschneidungen mit `USP_PlanDetails` und IQP-Modulen reduzieren.

### Welle 8 – Dokumentation und Release Gate – abgeschlossen für V1

- Procedure-Seiten;
- synthetische Beispiele;
- Resultset- und Systemquelleninventar;
- SQL-2019/2022/2025-Release-Gates;
- Eigenlast-, Privacy- und Outputtests.

## 26. Installationsmodell

Die Implementierung besitzt einen eigenen Teilinstaller:

```text
Code/Install/Install_ExecutionPlanAnalysis.sql
```

Dieser installiert nur die Standalone-Execution-Plan-Analyse und ihre tatsächliche transitive Abhängigkeitsschließung. `Code/Install/Install_All.sql` integriert dieselben Objekte in identischer Reihenfolge und installiert anschließend die übrigen Frameworkmodule und Integrationswrapper. Der verbindliche Detailvertrag steht in [`Execution_Plan_Analysis_Installation_Contract.md`](Execution_Plan_Analysis_Installation_Contract.md).

## 27. Für V1 entschiedene Vertragsfragen

1. `@AnalyseTiefe` ersetzt keine expliziten Detailparameter. `FULL` kennzeichnet den ressourcenintensiven Pfad und benötigt die High-Impact-Bestätigung; Statistik-, Histogramm- und Threaddetails bleiben separat steuerbar.
2. `TOKENIZED`-Werte sind absichtlich component- beziehungsweise capture-lokal und nicht als stabiler Join-Key zwischen getrennten Procedure-Aufrufen oder Outputbereichen zugesagt. Fachliche Korrelation verwendet abgeleitete Ordinals und Mappingstatus.
3. `OBJECT_ALL` bleibt im öffentlichen Standalone-Objekt verfügbar, ist aber ein bestätigungspflichtiger High-Impact-Pfad.
4. Alle im Public Contract aufgelisteten V1-Resultsets sind TABLE-exportierbar. Neue Resultsets sind nur additiv innerhalb V1; bestehende Schemata werden nicht stillschweigend geändert.
5. Query-Store-Feedbackdetails werden nicht durch einen zweiten Collector in `USP_ExecutionPlanAnalysis` dupliziert. Sie kommen über bestehende IQP-/Query-Store-Module oder über normalisierte externe Evidenz.
6. Ein späterer Client-Collector ist nicht Bestandteil des eingefrorenen Repositoryvertrags und bleibt ein getrennt zu entscheidendes Artefakt.

## 28. Hauptentscheidung

Die neue Auswertung besteht aus drei strikt getrennten Ebenen:

```text
1. Planmodell
   objektive Extraktion ohne Bewertung

2. Execution Evidence
   optionale Laufzeitevidenz aus Actual Plan,
   STATISTICS IO, STATISTICS TIME, Statistikzustand und Histogramm

3. Bewertungsmodell
   versions-, evidenz- und workloadabhängige Regeln
```

`monitor.USP_ExecutionPlanAnalysis` ist der eigenständige öffentliche Einstieg.
`monitor.USP_CreateExecutionEvidenceJson` ist der standardisierte Evidenzerzeuger.
`monitor.USP_ShowplanAnalysis` bleibt der Multi-Plan- und Plan-Cache-Wrapper.

Ein fehlendes oder falsch eingestuftes Finding darf nie dazu führen, dass die zugrunde liegenden technischen Werte oder deren Verfügbarkeitsstatus verloren gehen.
