# Referenz der unterstützenden Frameworkobjekte

Stand: 2026-07-21

Diese Referenz ergänzt die [Procedure-Referenz](Procedure_Reference.md). Sie
beschreibt alle inventarisierten Framework- und optionalen Paketobjekte, die
keine öffentliche `USP_*`-Analyse sind. Maßgeblich für die Abdeckung ist
[`Metadata/Inventory/Objects.csv`](../../Metadata/Inventory/Objects.csv).

Jeder Objektabschnitt dokumentiert Aufgabe, Schnittstelle, vorgesehene
Verwendung, Last-/Sperrverhalten und Stabilitätsgrenze. Die drei Analysis-
Navigator-Views besitzen einen dokumentierten lesenden Katalogvertrag. Alle
übrigen internen Bausteine sind auffindbar, aber kein eigenständiger
Analyseendpunkt. Anwendungen verwenden grundsätzlich die
[öffentlichen Analyse-Procedures](../Analysis_Guides/Object_Index.md).

## Abdeckung

| Objektklasse | Inventarisiert | Dokumentationsumfang |
|---|---:|---|
| Views | 8 | ein Abschnitt je View |
| Table-Valued Functions (TVFs) | 27 | ein Abschnitt je TVF |
| Scalar-Valued Functions (SVFs) | 0 | derzeit keine SVF installiert |
| Interne Procedures | 16 | ein Abschnitt je Procedure |
| Tabellen | 17 | ein Abschnitt je Tabelle |

## Direktnavigation

### Views

| Objekt | Schema | Quelle |
|---|---|---|
| [`VW_ModuleStatusCatalog`](#monitorvw_modulestatuscatalog) | `monitor` | `Code/01_Common/010_VW_ModuleStatusCatalog.sql` |
| [`VW_AnalyseClassCatalog`](#monitorvw_analyseclasscatalog) | `monitor` | `Code/01_Common/020_VW_AnalyseClassCatalog.sql` |
| [`VW_AnalysisCatalog`](#monitorvw_analysiscatalog) | `monitor` | `Code/01_Common/021_VW_AnalysisCatalog.sql` |
| [`VW_AnalysisSearchTerm`](#monitorvw_analysissearchterm) | `monitor` | `Code/01_Common/022_VW_AnalysisSearchTerm.sql` |
| [`VW_AnalysisRelation`](#monitorvw_analysisrelation) | `monitor` | `Code/01_Common/023_VW_AnalysisRelation.sql` |
| [`VW_AnalyseAccessPolicy`](#monitorvw_analyseaccesspolicy) | `monitor` | `Code/01_Common/030_VW_AnalyseAccessPolicy.sql` |
| [`VW_AnalyseAccessCurrent`](#monitorvw_analyseaccesscurrent) | `monitor` | `Code/01_Common/040_VW_AnalyseAccessCurrent.sql` |
| [`VW_FrameworkFeatureCatalog`](#monitorvw_frameworkfeaturecatalog) | `monitor` | `Code/01_Common/060_VW_FrameworkFeatureCatalog.sql` |

### Table-Valued Functions (TVFs)

| Objekt | Schema | Quelle |
|---|---|---|
| [`TVF_WaitTypeInfo`](#monitortvf_waittypeinfo) | `monitor` | `Code/01_Common/075_TVF_WaitTypeInfo.sql` |
| [`TVF_WaitTypeSources`](#monitortvf_waittypesources) | `monitor` | `Code/01_Common/075a_TVF_WaitTypeSources.sql` |
| [`TVF_QueryStoreWaitCategoryInfo`](#monitortvf_querystorewaitcategoryinfo) | `monitor` | `Code/01_Common/076_TVF_QueryStoreWaitCategoryInfo.sql` |
| [`TVF_ParsePipeList`](#monitortvf_parsepipelist) | `monitor` | `Code/01_Common/078_TVF_ParsePipeList.sql` |
| [`TVF_ParsePattern`](#monitortvf_parsepattern) | `monitor` | `Code/01_Common/079_TVF_ParsePattern.sql` |
| [`TVF_ParseSqlNameList`](#monitortvf_parsesqlnamelist) | `monitor` | `Code/01_Common/080_TVF_ParseSqlNameList.sql` |
| [`TVF_ParseFullObjectNameList`](#monitortvf_parsefullobjectnamelist) | `monitor` | `Code/01_Common/081_TVF_ParseFullObjectNameList.sql` |
| [`TVF_DatabaseCandidates`](#monitortvf_databasecandidates) | `monitor` | `Code/01_Common/082_TVF_DatabaseCandidates.sql` |
| [`TVF_ParseBigintList`](#monitortvf_parsebigintlist) | `monitor` | `Code/01_Common/085_TVF_ParseBigintList.sql` |
| [`TVF_ParseStringList`](#monitortvf_parsestringlist) | `monitor` | `Code/01_Common/086_TVF_ParseStringList.sql` |
| [`TVF_ParseBlockingResource`](#monitortvf_parseblockingresource) | `monitor` | `Code/01_Common/086a_TVF_ParseBlockingResource.sql` |
| [`TVF_StatementText`](#monitortvf_statementtext) | `monitor` | `Code/01_Common/087_TVF_StatementText.sql` |
| [`TVF_ToolBackgroundQueryInfo`](#monitortvf_toolbackgroundqueryinfo) | `monitor` | `Code/01_Common/087c_TVF_ToolBackgroundQueryInfo.sql` |
| [`TVF_ProjectUnicodeText`](#monitortvf_projectunicodetext) | `monitor` | `Code/01_Common/087d_TVF_ProjectUnicodeText.sql` |
| [`TVF_ClassifyErrorLogEvent`](#monitortvf_classifyerrorlogevent) | `monitor` | `Code/01_Common/087e_TVF_ClassifyErrorLogEvent.sql` |
| [`TVF_InterpretPerformanceCounter`](#monitortvf_interpretperformancecounter) | `monitor` | `Code/01_Common/088_TVF_InterpretPerformanceCounter.sql` |
| [`TVF_InterpretContentionCounter`](#monitortvf_interpretcontentioncounter) | `monitor` | `Code/01_Common/089_TVF_InterpretContentionCounter.sql` |
| [`TVF_InterpretAvailabilityDatabaseState`](#monitortvf_interpretavailabilitydatabasestate) | `monitor` | `Code/01_Common/090_TVF_InterpretAvailabilityDatabaseState.sql` |
| [`TVF_InterpretAvailabilitySeedingState`](#monitortvf_interpretavailabilityseedingstate) | `monitor` | `Code/01_Common/091_TVF_InterpretAvailabilitySeedingState.sql` |
| [`TVF_InterpretAgentAlertRoute`](#monitortvf_interpretagentalertroute) | `monitor` | `Code/01_Common/092_TVF_InterpretAgentAlertRoute.sql` |
| [`TVF_InterpretAgentJobState`](#monitortvf_interpretagentjobstate) | `monitor` | `Code/01_Common/093_TVF_InterpretAgentJobState.sql` |
| [`TVF_InterpretDatabaseMailStatus`](#monitortvf_interpretdatabasemailstatus) | `monitor` | `Code/01_Common/094_TVF_InterpretDatabaseMailStatus.sql` |
| [`TVF_ParseStatisticsIoText`](#monitortvf_parsestatisticsiotext) | `monitor` | `Code/04_PlanCache/044_TVF_ParseStatisticsIoText.sql` |
| [`TVF_ParseStatisticsTimeText`](#monitortvf_parsestatisticstimetext) | `monitor` | `Code/04_PlanCache/045_TVF_ParseStatisticsTimeText.sql` |
| [`TVF_ExecutionPlanObjectReferences`](#monitortvf_executionplanobjectreferences) | `monitor` | `Code/04_PlanCache/046_TVF_ExecutionPlanObjectReferences.sql` |
| [`TVF_ExecutionPlanStatisticsUsage`](#monitortvf_executionplanstatisticsusage) | `monitor` | `Code/04_PlanCache/047_TVF_ExecutionPlanStatisticsUsage.sql` |
| [`TVF_ExecutionPlanColumnReferences`](#monitortvf_executionplancolumnreferences) | `monitor` | `Code/04_PlanCache/048_TVF_ExecutionPlanColumnReferences.sql` |

### Interne Procedures

| Objekt | Schema | Quelle |
|---|---|---|
| [`InternalCheckAnalysisPath`](#monitorinternalcheckanalysispath) | `monitor` | `Code/01_Common/083a_USP_InternalCheckAnalysisPath.sql` |
| [`InternalWriteResultTable`](#monitorinternalwriteresulttable) | `monitor` | `Code/01_Common/095_USP_InternalWriteResultTable.sql` |
| [`InternalPrepareResultTables`](#monitorinternalprepareresulttables) | `monitor` | `Code/01_Common/096_USP_InternalPrepareResultTables.sql` |
| [`InternalPrepareSingleResultTable`](#monitorinternalpreparesingleresulttable) | `monitor` | `Code/01_Common/097_USP_InternalPrepareSingleResultTable.sql` |
| [`InternalEmitConsoleResult`](#monitorinternalemitconsoleresult) | `monitor` | `Code/01_Common/098_USP_InternalEmitConsoleResult.sql` |
| [`InternalProjectUnicodeTextColumn`](#monitorinternalprojectunicodetextcolumn) | `monitor` | `Code/01_Common/098_USP_InternalProjectUnicodeTextColumn.sql` |
| [`InternalEmitTruncationWarning`](#monitorinternalemittruncationwarning) | `monitor` | `Code/01_Common/099_USP_InternalEmitTruncationWarning.sql` |
| [`InternalParseXmlText`](#monitorinternalparsexmltext) | `monitor` | `Code/01_Common/099a_USP_InternalParseXmlText.sql` |
| [`InternalCaptureCurrentStateSnapshot`](#monitorinternalcapturecurrentstatesnapshot) | `monitor` | `Code/02_CurrentState/005_InternalCaptureCurrentStateSnapshot.sql` |
| [`InternalCollectExecutionPlanMetadata`](#monitorinternalcollectexecutionplanmetadata) | `monitor` | `Code/04_PlanCache/049_InternalCollectExecutionPlanMetadata.sql` |
| [`InternalAnalyzeExecutionPlan`](#monitorinternalanalyzeexecutionplan) | `monitor` | `Code/04_PlanCache/051_InternalAnalyzeExecutionPlan.sql` |
| [`InternalConfigureSnapshotPolicy`](#snapshotinternalconfiguresnapshotpolicy) | `snapshot` | `Code/10_SnapshotBaseline/020_InternalConfigureSnapshotPolicy.sql` |
| [`InternalPrepareCollectionCycle`](#snapshotinternalpreparecollectioncycle) | `snapshot` | `Code/10_SnapshotBaseline/040_InternalPrepareCollectionCycle.sql` |
| [`InternalCompletePerformanceCounterCycle`](#snapshotinternalcompleteperformancecountercycle) | `snapshot` | `Code/10_SnapshotBaseline/050_InternalCompletePerformanceCounterCycle.sql` |
| [`InternalFinalizeCollectionCycle`](#snapshotinternalfinalizecollectioncycle) | `snapshot` | `Code/10_SnapshotBaseline/060_InternalFinalizeCollectionCycle.sql` |
| [`InternalPurgeExpiredData`](#snapshotinternalpurgeexpireddata) | `snapshot` | `Code/10_SnapshotBaseline/070_InternalPurgeExpiredData.sql` |

### Tabellen

| Objekt | Schema | Quelle |
|---|---|---|
| [`ToolBackgroundQueryPattern`](#monitortoolbackgroundquerypattern) | `monitor` | `Code/01_Common/087a_ToolBackgroundQueryPattern.sql` |
| [`SqlServerBuildCatalog`](#monitorsqlserverbuildcatalog) | `monitor` | `Code/09_VersionAdaptive/011_SqlServerBuildCatalog.sql` |
| [`SqlServerLifecycleCatalog`](#monitorsqlserverlifecyclecatalog) | `monitor` | `Code/09_VersionAdaptive/012_SqlServerLifecycleCatalog.sql` |
| [`PlanAnalysisProfile`](#monitorplananalysisprofile) | `monitor` | `Code/04_PlanCache/041_PlanAnalysisProfile.sql` |
| [`PlanAnalysisRuleThreshold`](#monitorplananalysisrulethreshold) | `monitor` | `Code/04_PlanCache/042_PlanAnalysisRuleThreshold.sql` |
| [`PlanAnalysisProfileAssignment`](#monitorplananalysisprofileassignment) | `monitor` | `Code/04_PlanCache/043_PlanAnalysisProfileAssignment.sql` |
| [`SnapshotTargetConfiguration`](#monitorsnapshottargetconfiguration) | `monitor` | `Code/10_SnapshotBaseline/010_SnapshotTargetConfiguration.sql` |
| [`PackageVersion`](#snapshotpackageversion) | `snapshot` | `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql` |
| [`RetentionPolicy`](#snapshotretentionpolicy) | `snapshot` | `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql` |
| [`CollectorPolicy`](#snapshotcollectorpolicy) | `snapshot` | `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql` |
| [`CaptureRun`](#snapshotcapturerun) | `snapshot` | `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql` |
| [`ModuleStatus`](#snapshotmodulestatus) | `snapshot` | `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql` |
| [`Scope`](#snapshotscope) | `snapshot` | `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql` |
| [`MetricDefinition`](#snapshotmetricdefinition) | `snapshot` | `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql` |
| [`MetricSample`](#snapshotmetricsample) | `snapshot` | `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql` |
| [`PayloadSnapshot`](#snapshotpayloadsnapshot) | `snapshot` | `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql` |
| [`PurgeRun`](#snapshotpurgerun) | `snapshot` | `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql` |

## Views

### `[monitor].[VW_ModuleStatusCatalog]`

Quelle: `Code/01_Common/010_VW_ModuleStatusCatalog.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Stellt den gemeinsamen Katalog der Modul- und Statusbezeichnungen bereit, damit Ausgaben und Orchestratoren dieselben technischen Zustände benennen. |
| Schnittstelle | Parameterlose, read-only View. Der Spaltenvertrag wird durch das `SELECT` der kanonischen Quelle festgelegt; die View besitzt keinen eigenen Datenspeicher. |
| Verwendung | Framework-Procedures lesen diese Projektion, um Status-, Policy- oder Capability-Entscheidungen einheitlich zu treffen. Für Diagnoseaufrufe bleibt die jeweilige öffentliche `USP_*`-Procedure der unterstützte Einstieg. |
| Last und Sperren | Read-only Projektion über konstante Framework-Metadaten. Der Aufruf schreibt nichts; CPU- und I/O-Kosten sind klein und unabhängig von der Größe der überwachten Benutzerdatenbanken. |
| Vertrag | Unterstützendes Objekt, kein eigenständiger Analyseendpunkt. Spalten können mit internen Frameworkversionen erweitert werden; Verbraucher verwenden die dokumentierten öffentlichen Procedures. |

### `[monitor].[VW_AnalyseClassCatalog]`

Quelle: `Code/01_Common/020_VW_AnalyseClassCatalog.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Liefert die Klassifikation von Analysepfaden, insbesondere für Kosten- und Zugriffsentscheidungen. Sie ist eine Lesesicht auf Frameworkmetadaten. |
| Schnittstelle | Parameterlose, read-only View. Der Spaltenvertrag wird durch das `SELECT` der kanonischen Quelle festgelegt; die View besitzt keinen eigenen Datenspeicher. |
| Verwendung | Framework-Procedures lesen diese Projektion, um Status-, Policy- oder Capability-Entscheidungen einheitlich zu treffen. Für Diagnoseaufrufe bleibt die jeweilige öffentliche `USP_*`-Procedure der unterstützte Einstieg. |
| Last und Sperren | Read-only Projektion über konstante Framework-Metadaten. Der Aufruf schreibt nichts; CPU- und I/O-Kosten sind klein und unabhängig von der Größe der überwachten Benutzerdatenbanken. |
| Vertrag | Unterstützendes Objekt, kein eigenständiger Analyseendpunkt. Spalten können mit internen Frameworkversionen erweitert werden; Verbraucher verwenden die dokumentierten öffentlichen Procedures. |

### `[monitor].[VW_AnalysisCatalog]`

Quelle: `Code/01_Common/021_VW_AnalysisCatalog.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Ordnet jede öffentliche Procedure genau einer primären Navigationsrolle und einem Primärbereich zu. Ergänzt werden Anzeigename, Scope, Evidenzart, Kostenband, repräsentative Analyseklasse, Voraussetzungen, Paket, sicherer Aufruf und Dokumentationspfade. |
| Schnittstelle | Parameterlose read-only View mit genau einer Zeile je öffentlicher Procedure. Schlüssel ist `ProcedureName`. Die Spalten `NavigationRole`, `PrimaryAreaCode`, `ScopeCode`, `EvidenceType`, `CostRangeCode` und `PackageCode` verwenden dokumentierte Codewerte. |
| Verwendung | `USP_AnalysisNavigator` nutzt die View als kanonische fachliche Objektbasis. Power User können sie direkt per `SELECT` nach Rolle, Bereich, Scope, Paket oder Kostenband filtern. Mehrfachzuordnungen stehen absichtlich nicht als doppelte Zeilen, sondern in Suchbegriffen und Relationen. |
| Last und Sperren | Konstante `VALUES`-Projektion ohne Tabellen-, DMV- oder Systemkatalogzugriff. CPU und Ergebnistransfer wachsen nur mit der kleinen öffentlichen Objektzahl; keine Schreib- oder fachlichen Sperrwirkungen. |
| Vertrag | Dokumentierte lesende Katalogschnittstelle. `ProcedureName` bleibt mit dem öffentlichen Objektinventar synchron. Neue Procedures oder zusätzliche Codewerte können Zeilen beziehungsweise Werte ergänzen; Verbraucher dürfen keine feste Zeilenzahl voraussetzen. `RepresentativeAnalysisClass` ist keine vollständige Laufzeitfreigabe. |

Wesentliche Spaltengruppen:

- Identität: `ProcedureName`, `DisplayName`, `Purpose`;
- Navigation: `PrimaryAreaCode`, `PrimaryAreaName`, `NavigationRole`, `DefaultRank`;
- Scope und Evidenz: `ScopeCode`, `EvidenceType`, `PrerequisiteSummary`;
- Kosten: `CostRangeCode`, `RepresentativeAnalysisClass`, Target- und High-Impact-Flags;
- Paket und Verwendung: `PackageCode`, `SafeCall`, `DocumentationPath`, `RunbookPath`.

### `[monitor].[VW_AnalysisSearchTerm]`

Quelle: `Code/01_Common/022_VW_AnalysisSearchTerm.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Liefert deutsche und englische Symptome, Ziele, Synonyme und technische Begriffe für jede öffentliche Procedure. Ein fachliches Gewicht priorisiert spezifische gegenüber allgemeinen Begriffen; `MatchReason` erklärt den Treffer. |
| Schnittstelle | Parameterlose read-only View. Granularität ist eine Suchphrase je `ProcedureName`, `SearchTerm` und `LanguageCode`. `LanguageCode` ist `de` oder `en`; `SearchWeight` liegt zwischen 1 und 100. |
| Verwendung | Der Navigator bewertet exakte und teilweise Phrasentreffer und verwendet `MatchReason` für `WhyMatched`. Direkte Abfragen eignen sich zur Begriffsübersicht einer Procedure oder zur Suche nach einem bekannten Synonym. |
| Last und Sperren | Konstante `VALUES`-Projektion. Keine produktiven Quellen und keine Schreibzugriffe. Suchkosten wachsen linear mit der kleinen Phrasezahl und werden im Navigator durch Suchtext- und Ergebnisgrenzen kontrolliert. |
| Vertrag | Dokumentierte lesende Suchschnittstelle. Jede öffentliche Procedure besitzt mindestens einen deutschen und einen englischen Begriff. Gewichte und Phrasen dürfen fachlich präzisiert werden; sie sind keine dauerhaften Business-Keys. |

`SearchTerm` ist bewusst nicht eindeutig über alle Procedures. Begriffe wie `CPU hoch`, `blocking` oder `memory pressure` können mehrere plausible Pfade besitzen; Procedure, Gewicht, Rolle und Trefferart bestimmen die Reihenfolge.

### `[monitor].[VW_AnalysisRelation]`

Quelle: `Code/01_Common/023_VW_AnalysisRelation.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Verbindet öffentliche Procedures durch fachlich begründete nächste Schritte. Die View unterscheidet Vertiefung, unabhängige Gegenprobe, alternativen Evidenzpfad und Vorbereitung. |
| Schnittstelle | Parameterlose read-only View. Eine Zeile verbindet `FromProcedureName` über `RelationType` mit `ToProcedureName`. `RelationPriority` gilt je Ausgangsprocedure und Relationstyp; `ConditionSummary` beschreibt, wann der Übergang sinnvoll ist. |
| Verwendung | Der Navigator zeigt die höchstpriorisierte Relation je Treffer. Direkte Abfragen liefern alle Alternativen eines Ausgangsobjekts. Keine Relation führt die Zielprocedure aus und keine Relation behauptet automatisch Kausalität. |
| Last und Sperren | Konstante `VALUES`-Projektion ohne fachliche Datenquelle. Keine Schreibzugriffe; Kosten sind unabhängig von Benutzer- und Systemdatenmengen. |
| Vertrag | Dokumentierte lesende Relationsschnittstelle. Gültige Typen sind `REFINE_WITH`, `CONFIRM_WITH`, `ALTERNATIVE_TO` und `PREPARE_WITH`. Beide Endpunkte müssen öffentliche Katalogobjekte sein; Selbstbeziehungen sind ausgeschlossen. Weitere begründete Relationen dürfen ergänzt werden. |

Die Relationstypen bedeuten:

- `REFINE_WITH`: dasselbe Signal genauer untersuchen;
- `CONFIRM_WITH`: einen anderen Mess- oder Evidenzpfad gegenprüfen;
- `ALTERNATIVE_TO`: bei einer anderen verfügbaren Eingabe einen geeigneteren Zugang wählen;
- `PREPARE_WITH`: eine dokumentierte Voraussetzung oder Betriebsfolge herstellen.

### `[monitor].[VW_AnalyseAccessPolicy]`

Quelle: `Code/01_Common/030_VW_AnalyseAccessPolicy.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Zeigt die konfigurierte interne Analysezugriffspolicy. Die View vergibt weder SQL-Server-Rechte noch verändert sie die Policy. |
| Schnittstelle | Parameterlose, read-only View. Der Spaltenvertrag wird durch das `SELECT` der kanonischen Quelle festgelegt; die View besitzt keinen eigenen Datenspeicher. |
| Verwendung | Framework-Procedures lesen diese Projektion, um Status-, Policy- oder Capability-Entscheidungen einheitlich zu treffen. Für Diagnoseaufrufe bleibt die jeweilige öffentliche `USP_*`-Procedure der unterstützte Einstieg. |
| Last und Sperren | Read-only Projektion über konstante Framework-Metadaten. Der Aufruf schreibt nichts; CPU- und I/O-Kosten sind klein und unabhängig von der Größe der überwachten Benutzerdatenbanken. |
| Vertrag | Unterstützendes Objekt, kein eigenständiger Analyseendpunkt. Spalten können mit internen Frameworkversionen erweitert werden; Verbraucher verwenden die dokumentierten öffentlichen Procedures. |

### `[monitor].[VW_AnalyseAccessCurrent]`

Quelle: `Code/01_Common/040_VW_AnalyseAccessCurrent.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Projiziert die für die aktuelle Ausführung relevante Zugriffsauswertung. Sie ist die lesbare Grundlage der internen Berechtigungsschiene. |
| Schnittstelle | Parameterlose, read-only View. Der Spaltenvertrag wird durch das `SELECT` der kanonischen Quelle festgelegt; die View besitzt keinen eigenen Datenspeicher. |
| Verwendung | Framework-Procedures lesen diese Projektion, um Status-, Policy- oder Capability-Entscheidungen einheitlich zu treffen. Für Diagnoseaufrufe bleibt die jeweilige öffentliche `USP_*`-Procedure der unterstützte Einstieg. |
| Last und Sperren | Liest die kleine Policy-View und `sys.login_token`; der Katalogzugriff verwendet `NOLOCK`. Die View schreibt nichts und hält keine dauerhaften Sperren. |
| Vertrag | Unterstützendes Objekt, kein eigenständiger Analyseendpunkt. Spalten können mit internen Frameworkversionen erweitert werden; Verbraucher verwenden die dokumentierten öffentlichen Procedures. |

### `[monitor].[VW_FrameworkFeatureCatalog]`

Quelle: `Code/01_Common/060_VW_FrameworkFeatureCatalog.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Katalogisiert Framework-Features und deren Voraussetzungen, damit Procedures Verfügbarkeit und Teilresultate konsistent ausweisen können. |
| Schnittstelle | Parameterlose, read-only View. Der Spaltenvertrag wird durch das `SELECT` der kanonischen Quelle festgelegt; die View besitzt keinen eigenen Datenspeicher. |
| Verwendung | Framework-Procedures lesen diese Projektion, um Status-, Policy- oder Capability-Entscheidungen einheitlich zu treffen. Für Diagnoseaufrufe bleibt die jeweilige öffentliche `USP_*`-Procedure der unterstützte Einstieg. |
| Last und Sperren | Read-only Projektion über konstante Framework-Metadaten. Der Aufruf schreibt nichts; CPU- und I/O-Kosten sind klein und unabhängig von der Größe der überwachten Benutzerdatenbanken. |
| Vertrag | Unterstützendes Objekt, kein eigenständiger Analyseendpunkt. Spalten können mit internen Frameworkversionen erweitert werden; Verbraucher verwenden die dokumentierten öffentlichen Procedures. |

## Table-Valued Functions (TVFs)

### `[monitor].[TVF_WaitTypeInfo]`

Quelle: `Code/01_Common/075_TVF_WaitTypeInfo.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Ordnet Wait-Typen der kuratierten Einordnung und Interpretation zu. |
| Schnittstelle | Inline TVF; Eingaben: `@WaitType nvarchar(120)`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; Katalog- oder Metadatenreads verwenden `NOLOCK`. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_WaitTypeSources]`

Quelle: `Code/01_Common/075a_TVF_WaitTypeSources.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Liefert quellenbezogene Metadaten zu einem Wait-Typ für die Dokumentations- und Evidenzausgabe. |
| Schnittstelle | Inline TVF; Eingaben: `@WaitType nvarchar(120)`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; Katalog- oder Metadatenreads verwenden `NOLOCK`. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_QueryStoreWaitCategoryInfo]`

Quelle: `Code/01_Common/076_TVF_QueryStoreWaitCategoryInfo.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Übersetzt Query-Store-Waitkategorien in die Frameworkklassifikation. |
| Schnittstelle | Inline TVF; Eingaben: `@WaitCategoryDesc nvarchar(128)`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_ParsePipeList]`

Quelle: `Code/01_Common/078_TVF_ParsePipeList.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Parst eine Pipe-getrennte Liste unter Beachtung geklammerter SQL-Identifier. |
| Schnittstelle | Multi-statement TVF; Eingaben: `@List nvarchar(max)`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Der Parser arbeitet sequenziell; CPU skaliert mit der Länge des Eingabetexts; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_ParsePattern]`

Quelle: `Code/01_Common/079_TVF_ParsePattern.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Normalisiert einen unterstützten Patternfilter und trennt dessen Modus vom eigentlichen Suchmuster. |
| Schnittstelle | Inline TVF; Eingaben: `@Pattern nvarchar(4000)`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_ParseSqlNameList]`

Quelle: `Code/01_Common/080_TVF_ParseSqlNameList.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Zerlegt eine Liste von SQL-Namen in sicher weiterverarbeitbare Bestandteile. |
| Schnittstelle | Inline TVF; Eingaben: `@List nvarchar(max)`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_ParseFullObjectNameList]`

Quelle: `Code/01_Common/081_TVF_ParseFullObjectNameList.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Parst mehrteilige Objektnamen für datenbankübergreifende Filter. |
| Schnittstelle | Inline TVF; Eingabe: `@List nvarchar(max)`. Die Funktion liefert Listenelemente mit aufgelösten Datenbank-, Schema- und Objektnamen sowie Validierungsstatus und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_DatabaseCandidates]`

Quelle: `Code/01_Common/082_TVF_DatabaseCandidates.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Ermittelt die Kandidatenmenge für die Datenbankauswahl; die aufrufende Procedure verantwortet anschließend Scope und Zugriffsprüfung. |
| Schnittstelle | Inline TVF; Eingaben: `@DatabaseNames nvarchar(max) = NULL`; `@SystemdatenbankenEinbeziehen bit = 0`; `@DatabaseNamePattern nvarchar(4000) = NULL`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; Katalog- oder Metadatenreads verwenden `NOLOCK`. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_ParseBigintList]`

Quelle: `Code/01_Common/085_TVF_ParseBigintList.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Zerlegt numerische `bigint`-Listen für explizite IDs oder Schwellenwerte. |
| Schnittstelle | Inline TVF; Eingaben: `@List nvarchar(max)`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_ParseStringList]`

Quelle: `Code/01_Common/086_TVF_ParseStringList.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Parst generische Zeichenlisten ohne SQL-Identifiersemantik. |
| Schnittstelle | Inline TVF; Eingaben: `@List nvarchar(max)`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_ParseBlockingResource]`

Quelle: `Code/01_Common/086a_TVF_ParseBlockingResource.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Extrahiert strukturierte Informationen aus einer Blocking-Ressourcenbeschreibung. |
| Schnittstelle | Multi-statement TVF; Eingaben: `@WaitResource nvarchar(3072)`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Der Parser arbeitet sequenziell; CPU skaliert mit der Länge des Eingabetexts; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_StatementText]`

Quelle: `Code/01_Common/087_TVF_StatementText.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Ermittelt mittels Statement-Offsets den aktuell relevanten Statementausschnitt eines Batchtexts. |
| Schnittstelle | Inline TVF; Eingaben: `@BatchText nvarchar(max)`; `@StatementStartOffsetBytes int`; `@StatementEndOffsetBytes int`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_ToolBackgroundQueryInfo]`

Quelle: `Code/01_Common/087c_TVF_ToolBackgroundQueryInfo.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Klassifiziert bekannte Hintergrundabfragen von Clienttools anhand der metadatengesteuerten Regeln. |
| Schnittstelle | Inline TVF; Eingaben: `@ProgramName nvarchar(128)`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; Katalog- oder Metadatenreads verwenden `NOLOCK`. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_ProjectUnicodeText]`

Quelle: `Code/01_Common/087d_TVF_ProjectUnicodeText.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Projiziert Unicode-Langtext mit dem gemeinsamen Kürzungs- und Statusvertrag. |
| Schnittstelle | Inline TVF; Eingaben: `@Value nvarchar(max)`; `@MaxCharacters int`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_ClassifyErrorLogEvent]`

Quelle: `Code/01_Common/087e_TVF_ClassifyErrorLogEvent.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Ordnet begrenzt gelesene Errorlog-Ereignisse einer technischen Kategorie zu. |
| Schnittstelle | Inline TVF; Eingaben: `@ProductName varchar(32)`; `@RuleCategory varchar(80)`; `@MessageText nvarchar(max)`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_InterpretPerformanceCounter]`

Quelle: `Code/01_Common/088_TVF_InterpretPerformanceCounter.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Berechnet die sichere Delta- und Resetinterpretation für Performance Counter. |
| Schnittstelle | Inline TVF; Eingaben: `@CounterType int`; `@BeforeValue bigint`; `@AfterValue bigint`; `@BaseBeforeValue bigint`; `@BaseAfterValue bigint`; `@SampleSeconds decimal(19, 6)`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_InterpretContentionCounter]`

Quelle: `Code/01_Common/089_TVF_InterpretContentionCounter.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Bewertet die Counter-Differenz für interne Contention ohne einen Befund zu erzwingen. |
| Schnittstelle | Inline TVF; Eingaben: `@BeforeValue bigint`; `@AfterValue bigint`; `@RequestedSampleSeconds tinyint`; `@ActualSampleSeconds decimal(19, 6)`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_InterpretAvailabilityDatabaseState]`

Quelle: `Code/01_Common/090_TVF_InterpretAvailabilityDatabaseState.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Klassifiziert den beobachteten Availability-Datenbankzustand. |
| Schnittstelle | Inline TVF; Eingaben: `@IsSuspended bit`; `@SynchronizationHealthDesc nvarchar(60)`; `@SynchronizationStateDesc nvarchar(60)`; `@LogSendQueueSizeKb bigint`; `@RedoQueueSizeKb bigint`; `@SecondaryLagSeconds bigint`; `@QueueWarnMb bigint`; `@SecondaryLagWarnSeconds int`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_InterpretAvailabilitySeedingState]`

Quelle: `Code/01_Common/091_TVF_InterpretAvailabilitySeedingState.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Klassifiziert den Status des Availability-Seeding. |
| Schnittstelle | Inline TVF; Eingaben: `@FailureCode int`; `@TransferredSizeBytes bigint`; `@DatabaseSizeBytes bigint`; `@TransferRateBytesPerSecond bigint`; `@EndTimeUtc datetime`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_InterpretAgentAlertRoute]`

Quelle: `Code/01_Common/092_TVF_InterpretAgentAlertRoute.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Interpretiert den konfigurierten SQL-Agent-Alert-Routingzustand. |
| Schnittstelle | Inline TVF; Eingaben: `@IsEnabled bit`; `@HasJobAction bit`; `@NotificationCount bigint`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_InterpretAgentJobState]`

Quelle: `Code/01_Common/093_TVF_InterpretAgentJobState.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Übersetzt den Agent-Jobstatus in eine einheitliche technische Einordnung. |
| Schnittstelle | Inline TVF; Eingaben: `@IsEnabled tinyint`; `@LatestRunStatus int`; `@LatestRunDateTime datetime`; `@CutoffLocal datetime`; `@ScheduleCount bigint`; `@EnabledScheduleCount bigint`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_InterpretDatabaseMailStatus]`

Quelle: `Code/01_Common/094_TVF_InterpretDatabaseMailStatus.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Ordnet den sichtbaren Database-Mail-Zustand der Frameworkklassifikation zu. |
| Schnittstelle | Inline TVF; Eingaben: `@SentStatus varchar(8)`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Die Berechnung ist set-basiert und skaliert mit den Eingabezeilen; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_ParseStatisticsIoText]`

Quelle: `Code/04_PlanCache/044_TVF_ParseStatisticsIoText.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Parst die textuelle `STATISTICS IO`-Evidenz in strukturierte Werte. |
| Schnittstelle | Multi-statement TVF; Eingaben: `@StatisticsIoText nvarchar(max)`; `@StatisticsLanguage varchar(16) = 'AUTO'`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Der Parser arbeitet sequenziell; CPU skaliert mit der Länge des Eingabetexts; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_ParseStatisticsTimeText]`

Quelle: `Code/04_PlanCache/045_TVF_ParseStatisticsTimeText.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Parst die textuelle `STATISTICS TIME`-Evidenz in strukturierte Werte. |
| Schnittstelle | Multi-statement TVF; Eingaben: `@StatisticsTimeText nvarchar(max)`; `@StatisticsLanguage varchar(16) = 'AUTO'`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | Der Parser arbeitet sequenziell; CPU skaliert mit der Länge des Eingabetexts; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_ExecutionPlanObjectReferences]`

Quelle: `Code/04_PlanCache/046_TVF_ExecutionPlanObjectReferences.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Extrahiert objektbezogene Referenzen aus einem Showplan-XML. |
| Schnittstelle | Inline TVF; Eingaben: `@PlanXml xml`; `@StatementId int = NULL`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | XML-Shredding skaliert mit Anzahl und Größe der übergebenen Planelemente; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_ExecutionPlanStatisticsUsage]`

Quelle: `Code/04_PlanCache/047_TVF_ExecutionPlanStatisticsUsage.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Extrahiert die im Showplan dokumentierte Statistikverwendung. |
| Schnittstelle | Inline TVF; Eingaben: `@PlanXml xml`; `@StatementId int = NULL`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | XML-Shredding skaliert mit Anzahl und Größe der übergebenen Planelemente; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

### `[monitor].[TVF_ExecutionPlanColumnReferences]`

Quelle: `Code/04_PlanCache/048_TVF_ExecutionPlanColumnReferences.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Extrahiert Spaltenreferenzen aus dem Showplan für die Plandiagnose. |
| Schnittstelle | Inline TVF; Eingaben: `@PlanXml xml`; `@StatementId int = NULL`. Die Funktion liefert eine relationale Zeile oder Zeilenmenge und verändert keine persistenten Daten. |
| Verwendung | Die Funktion wird innerhalb öffentlicher Analysen per `JOIN`, `APPLY` oder direktem `SELECT` verwendet. Ein Direktaufruf eignet sich nur für Entwicklung und Tests, nicht als stabiler Integrationsvertrag. |
| Last und Sperren | XML-Shredding skaliert mit Anzahl und Größe der übergebenen Planelemente; die Funktion führt keine persistenten Schreiboperationen aus. Der aufrufende öffentliche Analysepfad bestimmt die Gesamtlast. |
| Vertrag | Unterstützende TVF, keine scalar-valued function. Parameter und Rückgabespalten sind interne Implementierungsdetails und können sich zusammen mit den aufrufenden Procedures ändern. |

## Interne Procedures

### `[monitor].[InternalCheckAnalysisPath]`

Quelle: `Code/01_Common/083a_USP_InternalCheckAnalysisPath.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Prüft vor der Ausführung den internen Kosten- und Berechtigungspfad. |
| Schnittstelle | Interne Stored Procedure; Parameter: `@AnalysisClass varchar(64)`; `@HighImpactConfirmed bit`; `@StatusCode varchar(40) OUTPUT`; `@ErrorMessage nvarchar(2048) OUTPUT`. Status-, Fehler- und weitere OUTPUT-Parameter werden ausschließlich zwischen Frameworkbausteinen weitergereicht. |
| Verwendung | Öffentliche Procedures im Schema `monitor` rufen diesen Baustein zur Orchestrierung auf. Anwendungen sollen ihn weder direkt ausführen noch von seiner Parameterreihenfolge oder seinen temporären Zwischenstrukturen abhängen. |
| Last und Sperren | Die Procedure koordiniert interne Verarbeitung ohne fachliche Persistenz unter `LOCK_TIMEOUT 0`. Sie darf nur über den zugehörigen öffentlichen Einstieg ausgeführt werden. |
| Vertrag | Nicht öffentlicher Vertrag. Fehlerbehandlung, OUTPUT-Parameter und Seiteneffekte sind nur für den versiongleichen internen Aufrufer zugesichert. |

### `[monitor].[InternalWriteResultTable]`

Quelle: `Code/01_Common/095_USP_InternalWriteResultTable.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Schreibt eine kanonische Ergebnismenge in eine bereits vorbereitete lokale Ergebnistabelle. |
| Schnittstelle | Interne Stored Procedure; Parameter: `@SourceTable sysname`; `@TargetTable sysname`; `@InsertedRows bigint = NULL OUTPUT`; `@StatusCode varchar(40) = NULL OUTPUT`; `@ErrorNumber int = NULL OUTPUT`; `@ErrorMessage nvarchar(2048) = NULL OUTPUT`; `@ThrowOnError bit = 0`. Status-, Fehler- und weitere OUTPUT-Parameter werden ausschließlich zwischen Frameworkbausteinen weitergereicht. |
| Verwendung | Öffentliche Procedures im Schema `monitor` rufen diesen Baustein zur Orchestrierung auf. Anwendungen sollen ihn weder direkt ausführen noch von seiner Parameterreihenfolge oder seinen temporären Zwischenstrukturen abhängen. |
| Last und Sperren | Die Procedure schreibt nur in die ausdrücklich vorgesehenen Framework-, Snapshot- oder lokalen Ergebnisspeicher und kann lokale Temp-Tabellen materialisieren, unter `LOCK_TIMEOUT 0`. Sie darf nur über den zugehörigen öffentlichen Einstieg ausgeführt werden. |
| Vertrag | Nicht öffentlicher Vertrag. Fehlerbehandlung, OUTPUT-Parameter und Seiteneffekte sind nur für den versiongleichen internen Aufrufer zugesichert. |

### `[monitor].[InternalPrepareResultTables]`

Quelle: `Code/01_Common/096_USP_InternalPrepareResultTables.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Bereitet alle im TABLE-Vertrag angeforderten lokalen Ergebnistabellen vor. |
| Schnittstelle | Interne Stored Procedure; Parameter: `@ResultTablesJson nvarchar(max)`; `@AllowedResultNames nvarchar(max)`; `@MappingTable sysname`; `@StatusCode varchar(40) = NULL OUTPUT`; `@ErrorMessage nvarchar(2048) = NULL OUTPUT`; `@ThrowOnError bit = 0`. Status-, Fehler- und weitere OUTPUT-Parameter werden ausschließlich zwischen Frameworkbausteinen weitergereicht. |
| Verwendung | Öffentliche Procedures im Schema `monitor` rufen diesen Baustein zur Orchestrierung auf. Anwendungen sollen ihn weder direkt ausführen noch von seiner Parameterreihenfolge oder seinen temporären Zwischenstrukturen abhängen. |
| Last und Sperren | Die Procedure schreibt nur in die ausdrücklich vorgesehenen Framework-, Snapshot- oder lokalen Ergebnisspeicher und kann lokale Temp-Tabellen materialisieren, unter `LOCK_TIMEOUT 0`. Sie darf nur über den zugehörigen öffentlichen Einstieg ausgeführt werden. |
| Vertrag | Nicht öffentlicher Vertrag. Fehlerbehandlung, OUTPUT-Parameter und Seiteneffekte sind nur für den versiongleichen internen Aufrufer zugesichert. |

### `[monitor].[InternalPrepareSingleResultTable]`

Quelle: `Code/01_Common/097_USP_InternalPrepareSingleResultTable.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Validiert und richtet eine einzelne lokale Ergebnistabelle des TABLE-Vertrags ein. |
| Schnittstelle | Interne Stored Procedure; Parameter: `@ResultTablesJson nvarchar(max)`; `@ResultName sysname`; `@TargetTable sysname OUTPUT`; `@ThrowOnError bit = 1`. Status-, Fehler- und weitere OUTPUT-Parameter werden ausschließlich zwischen Frameworkbausteinen weitergereicht. |
| Verwendung | Öffentliche Procedures im Schema `monitor` rufen diesen Baustein zur Orchestrierung auf. Anwendungen sollen ihn weder direkt ausführen noch von seiner Parameterreihenfolge oder seinen temporären Zwischenstrukturen abhängen. |
| Last und Sperren | Die Procedure koordiniert interne Verarbeitung ohne fachliche Persistenz und kann lokale Temp-Tabellen materialisieren, unter `LOCK_TIMEOUT 0`. Sie darf nur über den zugehörigen öffentlichen Einstieg ausgeführt werden. |
| Vertrag | Nicht öffentlicher Vertrag. Fehlerbehandlung, OUTPUT-Parameter und Seiteneffekte sind nur für den versiongleichen internen Aufrufer zugesichert. |

### `[monitor].[InternalEmitConsoleResult]`

Quelle: `Code/01_Common/098_USP_InternalEmitConsoleResult.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Erzeugt die standardisierte CONSOLE-Darstellung aus der kanonischen Datenbasis. |
| Schnittstelle | Interne Stored Procedure; Parameter: `@SourceTable sysname`; `@ResultLabel nvarchar(200)`; `@EmptyMessage nvarchar(200)`; `@StatusCode varchar(40) = NULL`; `@StatusMessage nvarchar(2048) = NULL`. Status-, Fehler- und weitere OUTPUT-Parameter werden ausschließlich zwischen Frameworkbausteinen weitergereicht. |
| Verwendung | Öffentliche Procedures im Schema `monitor` rufen diesen Baustein zur Orchestrierung auf. Anwendungen sollen ihn weder direkt ausführen noch von seiner Parameterreihenfolge oder seinen temporären Zwischenstrukturen abhängen. |
| Last und Sperren | Die Procedure koordiniert interne Verarbeitung ohne fachliche Persistenz und kann lokale Temp-Tabellen materialisieren, unter `LOCK_TIMEOUT 0`. Sie darf nur über den zugehörigen öffentlichen Einstieg ausgeführt werden. |
| Vertrag | Nicht öffentlicher Vertrag. Fehlerbehandlung, OUTPUT-Parameter und Seiteneffekte sind nur für den versiongleichen internen Aufrufer zugesichert. |

### `[monitor].[InternalProjectUnicodeTextColumn]`

Quelle: `Code/01_Common/098_USP_InternalProjectUnicodeTextColumn.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Projiziert eine Langtextspalte für Ausgabearten mit konsistenter Kürzung. |
| Schnittstelle | Interne Stored Procedure; Parameter: `@SourceTable sysname`; `@TextColumn sysname`; `@CharactersColumn sysname`; `@BytesColumn sysname`; `@IsTruncatedColumn sysname`; `@MaxCharacters int`; `@TruncatedValueCount bigint OUTPUT`; `@LargestRequiredCharacters bigint OUTPUT`. Status-, Fehler- und weitere OUTPUT-Parameter werden ausschließlich zwischen Frameworkbausteinen weitergereicht. |
| Verwendung | Öffentliche Procedures im Schema `monitor` rufen diesen Baustein zur Orchestrierung auf. Anwendungen sollen ihn weder direkt ausführen noch von seiner Parameterreihenfolge oder seinen temporären Zwischenstrukturen abhängen. |
| Last und Sperren | Die Procedure schreibt nur in die ausdrücklich vorgesehenen Framework-, Snapshot- oder lokalen Ergebnisspeicher unter `LOCK_TIMEOUT 0`. Sie darf nur über den zugehörigen öffentlichen Einstieg ausgeführt werden. |
| Vertrag | Nicht öffentlicher Vertrag. Fehlerbehandlung, OUTPUT-Parameter und Seiteneffekte sind nur für den versiongleichen internen Aufrufer zugesichert. |

### `[monitor].[InternalEmitTruncationWarning]`

Quelle: `Code/01_Common/099_USP_InternalEmitTruncationWarning.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Meldet eine sichtbare Textkürzung einschließlich des passenden Parameterhinweises. |
| Schnittstelle | Interne Stored Procedure; Parameter: `@TruncatedValueCount bigint`; `@ParameterName sysname`; `@ParameterValue int`; `@LargestRequiredCharacters bigint`; `@PrintMeldungen bit = 1`. Status-, Fehler- und weitere OUTPUT-Parameter werden ausschließlich zwischen Frameworkbausteinen weitergereicht. |
| Verwendung | Öffentliche Procedures im Schema `monitor` rufen diesen Baustein zur Orchestrierung auf. Anwendungen sollen ihn weder direkt ausführen noch von seiner Parameterreihenfolge oder seinen temporären Zwischenstrukturen abhängen. |
| Last und Sperren | Die Procedure koordiniert interne Verarbeitung ohne fachliche Persistenz unter `LOCK_TIMEOUT 0`. Sie darf nur über den zugehörigen öffentlichen Einstieg ausgeführt werden. |
| Vertrag | Nicht öffentlicher Vertrag. Fehlerbehandlung, OUTPUT-Parameter und Seiteneffekte sind nur für den versiongleichen internen Aufrufer zugesichert. |

### `[monitor].[InternalParseXmlText]`

Quelle: `Code/01_Common/099a_USP_InternalParseXmlText.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Parst Text defensiv zu XML und liefert dafür einen strukturierten Status. |
| Schnittstelle | Interne Stored Procedure; Parameter: `@XmlText nvarchar(max)`; `@XmlValue xml = NULL OUTPUT`; `@StatusCode varchar(40) = NULL OUTPUT`; `@ErrorNumber int = NULL OUTPUT`; `@ErrorMessage nvarchar(2048) = NULL OUTPUT`. Status-, Fehler- und weitere OUTPUT-Parameter werden ausschließlich zwischen Frameworkbausteinen weitergereicht. |
| Verwendung | Öffentliche Procedures im Schema `monitor` rufen diesen Baustein zur Orchestrierung auf. Anwendungen sollen ihn weder direkt ausführen noch von seiner Parameterreihenfolge oder seinen temporären Zwischenstrukturen abhängen. |
| Last und Sperren | Die Procedure koordiniert interne Verarbeitung ohne fachliche Persistenz unter `LOCK_TIMEOUT 0`. Sie darf nur über den zugehörigen öffentlichen Einstieg ausgeführt werden. |
| Vertrag | Nicht öffentlicher Vertrag. Fehlerbehandlung, OUTPUT-Parameter und Seiteneffekte sind nur für den versiongleichen internen Aufrufer zugesichert. |

### `[monitor].[InternalCaptureCurrentStateSnapshot]`

Quelle: `Code/02_CurrentState/005_InternalCaptureCurrentStateSnapshot.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Materialisiert die von einem Current-State-Orchestrator angeforderten primären DMV- und Textquellen einmalig in aufruflokalen Temp-Tabellen. |
| Schnittstelle | Interne Stored Procedure; Parameter: `@SnapshotId uniqueidentifier`; elf quellenbezogene `@Capture*`-Schalter; `@MaxSqlTextHandles int = 1000`. Der Aufrufer legt den Temp-Table-Vertrag Version 2 an und besitzt dessen Lebensdauer. |
| Verwendung | `USP_CurrentOverview` ruft den Baustein vor Sessions, Requests, Blocking, Waits, Transactions, Memory Grants, TempDB und I/O auf. Einzelaufrufe der Children übergeben keine Parent-ID und lesen ihre Quellen frisch. |
| Last und Sperren | Read-only unter `LOCK_TIMEOUT 0`. Nur aktivierte Quellen werden gelesen; SQL-Handles werden dedupliziert und optional begrenzt. Fehler einer Quelle werden isoliert in der Source-Status-Tabelle festgehalten. |
| Vertrag | Nicht öffentlicher, aufruflokaler Vertrag. Snapshot-ID und Temp-Tabellen dürfen nur innerhalb desselben Orchestratoraufrufs verwendet werden; spätere oder fremde IDs werden abgelehnt. |

### `[monitor].[InternalCollectExecutionPlanMetadata]`

Quelle: `Code/04_PlanCache/049_InternalCollectExecutionPlanMetadata.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Sammelt die für die eigenständige Ausführungsplananalyse erforderlichen Metadaten. |
| Schnittstelle | Interne Stored Procedure; Parameter: `@PlanXml xml`; `@StatistikEvidenzModus varchar(16) = 'USED'`; `@HistogrammModus varchar(16) = 'NONE'`; `@QuellumgebungBestaetigt bit = 0`; `@MitPredicateHistogramMap bit = 1`; `@MaxStatistiken int = 100`; `@MaxHistogrammSchritte int = 20000`; `@LockTimeoutMs int = 0`; `@HighImpactConfirmed bit = 0`; `@StatusCodeOut varchar(40) = NULL OUTPUT`; `@IsPartialOut bit = NULL OUTPUT`; `@ErrorNumberOut int = NULL OUTPUT`; `@ErrorMessageOut nvarchar(2048) = NULL OUTPUT`. Status-, Fehler- und weitere OUTPUT-Parameter werden ausschließlich zwischen Frameworkbausteinen weitergereicht. |
| Verwendung | Öffentliche Procedures im Schema `monitor` rufen diesen Baustein zur Orchestrierung auf. Anwendungen sollen ihn weder direkt ausführen noch von seiner Parameterreihenfolge oder seinen temporären Zwischenstrukturen abhängen. |
| Last und Sperren | Die Procedure schreibt nur in die ausdrücklich vorgesehenen Framework-, Snapshot- oder lokalen Ergebnisspeicher und kann lokale Temp-Tabellen materialisieren, unter `LOCK_TIMEOUT 0`. Sie darf nur über den zugehörigen öffentlichen Einstieg ausgeführt werden. |
| Vertrag | Nicht öffentlicher Vertrag. Fehlerbehandlung, OUTPUT-Parameter und Seiteneffekte sind nur für den versiongleichen internen Aufrufer zugesichert. |

### `[monitor].[InternalAnalyzeExecutionPlan]`

Quelle: `Code/04_PlanCache/051_InternalAnalyzeExecutionPlan.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Führt die interne Regel- und Evidenzanalyse eines Showplan-XML durch. |
| Schnittstelle | Interne Stored Procedure; Parameter: `@AnalysisObjectId int`; `@PlanXml xml`; `@PlanSource varchar(24)`; `@RuntimeCounterScope varchar(32)`; `@WorkloadProfile varchar(32) = 'BALANCED'`; `@MinSeverity varchar(16) = 'INFO'`; `@EvidenceJson nvarchar(max) = NULL`; `@MitThreadRuntime bit = 0`; `@EvidenzDatenschutzModus varchar(24) = 'DERIVED_ONLY'`; `@IdentifierDatenschutzModus varchar(16) = 'RAW'`; `@StatusCodeOut varchar(40) = NULL OUTPUT`; `@IsPartialOut bit = NULL OUTPUT`; `@ErrorNumberOut int = NULL OUTPUT`; `@ErrorMessageOut nvarchar(2048) = NULL OUTPUT`. Status-, Fehler- und weitere OUTPUT-Parameter werden ausschließlich zwischen Frameworkbausteinen weitergereicht. |
| Verwendung | Öffentliche Procedures im Schema `monitor` rufen diesen Baustein zur Orchestrierung auf. Anwendungen sollen ihn weder direkt ausführen noch von seiner Parameterreihenfolge oder seinen temporären Zwischenstrukturen abhängen. |
| Last und Sperren | Die Procedure schreibt nur in die ausdrücklich vorgesehenen Framework-, Snapshot- oder lokalen Ergebnisspeicher und kann lokale Temp-Tabellen materialisieren, unter `LOCK_TIMEOUT 0`. Sie darf nur über den zugehörigen öffentlichen Einstieg ausgeführt werden. |
| Vertrag | Nicht öffentlicher Vertrag. Fehlerbehandlung, OUTPUT-Parameter und Seiteneffekte sind nur für den versiongleichen internen Aufrufer zugesichert. |

### `[snapshot].[InternalConfigureSnapshotPolicy]`

Quelle: `Code/10_SnapshotBaseline/020_InternalConfigureSnapshotPolicy.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Validiert und schreibt die typisierten Zielpolicies transaktional. |
| Schnittstelle | Interne Stored Procedure; Parameter: `@CollectionIntervalSeconds smallint`; `@MaxRows int`; `@PayloadEnabled bit`; `@RawRetentionDays smallint`; `@PayloadRetentionDays smallint`; `@RollupRetentionDays smallint`; `@SoftBudgetMB int`; `@PurgeIntervalMinutes smallint`; `@PurgeBatchRows int`; `@BudgetAction varchar(32)`; `@StatusCodeOut varchar(40) OUTPUT`; `@ErrorNumberOut int OUTPUT`; `@ErrorMessageOut nvarchar(2048) OUTPUT`. Status-, Fehler- und weitere OUTPUT-Parameter werden ausschließlich zwischen Frameworkbausteinen weitergereicht. |
| Verwendung | Öffentliche Procedures im Schema `monitor` rufen diesen Baustein zur Orchestrierung auf. Anwendungen sollen ihn weder direkt ausführen noch von seiner Parameterreihenfolge oder seinen temporären Zwischenstrukturen abhängen. |
| Last und Sperren | Die Procedure schreibt nur in die ausdrücklich vorgesehenen Framework-, Snapshot- oder lokalen Ergebnisspeicher unter `LOCK_TIMEOUT 0`. Sie darf nur über den zugehörigen öffentlichen Einstieg ausgeführt werden. |
| Vertrag | Nicht öffentlicher Vertrag. Fehlerbehandlung, OUTPUT-Parameter und Seiteneffekte sind nur für den versiongleichen internen Aufrufer zugesichert. |

### `[snapshot].[InternalPrepareCollectionCycle]`

Quelle: `Code/10_SnapshotBaseline/040_InternalPrepareCollectionCycle.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Prüft Due-Zeit und Softbudget vor jedem Quellread und eröffnet den Lauf. |
| Schnittstelle | Interne Stored Procedure; Parameter: `@SourceDatabaseName sysname`; `@SchedulerType varchar(16)`; `@RunEvenIfNotDue bit`; `@CaptureRunIdOut bigint OUTPUT`; `@ShouldCollectOut bit OUTPUT`; `@StatusCodeOut varchar(40) OUTPUT`; `@ErrorMessageOut nvarchar(2048) OUTPUT`. Status-, Fehler- und weitere OUTPUT-Parameter werden ausschließlich zwischen Frameworkbausteinen weitergereicht. |
| Verwendung | Öffentliche Procedures im Schema `monitor` rufen diesen Baustein zur Orchestrierung auf. Anwendungen sollen ihn weder direkt ausführen noch von seiner Parameterreihenfolge oder seinen temporären Zwischenstrukturen abhängen. |
| Last und Sperren | Die Procedure schreibt nur in die ausdrücklich vorgesehenen Framework-, Snapshot- oder lokalen Ergebnisspeicher unter `LOCK_TIMEOUT 0`. Sie darf nur über den zugehörigen öffentlichen Einstieg ausgeführt werden. |
| Vertrag | Nicht öffentlicher Vertrag. Fehlerbehandlung, OUTPUT-Parameter und Seiteneffekte sind nur für den versiongleichen internen Aufrufer zugesichert. |

### `[snapshot].[InternalCompletePerformanceCounterCycle]`

Quelle: `Code/10_SnapshotBaseline/050_InternalCompletePerformanceCounterCycle.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Normalisiert den transient übergebenen Performance-Counter-JSON-Vertrag und persistiert optionale Payloads. |
| Schnittstelle | Interne Stored Procedure; Parameter: `@CaptureRunId bigint`; `@CollectorJson nvarchar(max)`; `@SourceStatusCode varchar(40)`; `@SourceIsPartial bit`; `@SourceErrorNumber int`; `@SourceErrorMessage nvarchar(2048)`; `@StatusCodeOut varchar(40) OUTPUT`; `@IsPartialOut bit OUTPUT`; `@ErrorNumberOut int OUTPUT`; `@ErrorMessageOut nvarchar(2048) OUTPUT`. Status-, Fehler- und weitere OUTPUT-Parameter werden ausschließlich zwischen Frameworkbausteinen weitergereicht. |
| Verwendung | Öffentliche Procedures im Schema `monitor` rufen diesen Baustein zur Orchestrierung auf. Anwendungen sollen ihn weder direkt ausführen noch von seiner Parameterreihenfolge oder seinen temporären Zwischenstrukturen abhängen. |
| Last und Sperren | Die Procedure schreibt nur in die ausdrücklich vorgesehenen Framework-, Snapshot- oder lokalen Ergebnisspeicher und kann lokale Temp-Tabellen materialisieren, unter `LOCK_TIMEOUT 0`. Sie darf nur über den zugehörigen öffentlichen Einstieg ausgeführt werden. |
| Vertrag | Nicht öffentlicher Vertrag. Fehlerbehandlung, OUTPUT-Parameter und Seiteneffekte sind nur für den versiongleichen internen Aufrufer zugesichert. |

### `[snapshot].[InternalFinalizeCollectionCycle]`

Quelle: `Code/10_SnapshotBaseline/060_InternalFinalizeCollectionCycle.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Schließt einen eröffneten Lauf mit Status und technischen Zeilensummen ab. |
| Schnittstelle | Interne Stored Procedure; Parameter: `@CaptureRunId bigint`; `@StatusCode varchar(40)`; `@IsPartial bit`; `@ErrorNumber int`; `@ErrorMessage nvarchar(2048)`. Status-, Fehler- und weitere OUTPUT-Parameter werden ausschließlich zwischen Frameworkbausteinen weitergereicht. |
| Verwendung | Öffentliche Procedures im Schema `monitor` rufen diesen Baustein zur Orchestrierung auf. Anwendungen sollen ihn weder direkt ausführen noch von seiner Parameterreihenfolge oder seinen temporären Zwischenstrukturen abhängen. |
| Last und Sperren | Die Procedure schreibt nur in die ausdrücklich vorgesehenen Framework-, Snapshot- oder lokalen Ergebnisspeicher unter `LOCK_TIMEOUT 0`. Sie darf nur über den zugehörigen öffentlichen Einstieg ausgeführt werden. |
| Vertrag | Nicht öffentlicher Vertrag. Fehlerbehandlung, OUTPUT-Parameter und Seiteneffekte sind nur für den versiongleichen internen Aufrufer zugesichert. |

### `[snapshot].[InternalPurgeExpiredData]`

Quelle: `Code/10_SnapshotBaseline/070_InternalPurgeExpiredData.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Entfernt ausschließlich abgelaufene Evidenz child-first in begrenzten Batches. |
| Schnittstelle | Interne Stored Procedure; Parameter: `@MaxBatches int`; `@Force bit`; `@PurgeRunIdOut bigint OUTPUT`; `@StatusCodeOut varchar(40) OUTPUT`; `@BudgetExceededOut bit OUTPUT`; `@ErrorNumberOut int OUTPUT`; `@ErrorMessageOut nvarchar(2048) OUTPUT`. Status-, Fehler- und weitere OUTPUT-Parameter werden ausschließlich zwischen Frameworkbausteinen weitergereicht. |
| Verwendung | Öffentliche Procedures im Schema `monitor` rufen diesen Baustein zur Orchestrierung auf. Anwendungen sollen ihn weder direkt ausführen noch von seiner Parameterreihenfolge oder seinen temporären Zwischenstrukturen abhängen. |
| Last und Sperren | Die Procedure schreibt nur in die ausdrücklich vorgesehenen Framework-, Snapshot- oder lokalen Ergebnisspeicher unter `LOCK_TIMEOUT 0`. Sie darf nur über den zugehörigen öffentlichen Einstieg ausgeführt werden. |
| Vertrag | Nicht öffentlicher Vertrag. Fehlerbehandlung, OUTPUT-Parameter und Seiteneffekte sind nur für den versiongleichen internen Aufrufer zugesichert. |

## Tabellen

### `[monitor].[ToolBackgroundQueryPattern]`

Quelle: `Code/01_Common/087a_ToolBackgroundQueryPattern.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Enthält die pflegbaren, metadatengesteuerten Erkennungsmuster für Tool-Hintergrundabfragen. Direkte Änderungen außerhalb des dokumentierten Administrationswegs sind nicht Teil des öffentlichen Vertrags. |
| Schnittstelle | Persistente Tabelle mit 11 in der Quelle typisierten Spalten: `RuleCode`, `Priority`, `IsEnabled`, `ProgramNameLikePattern`, `ToolBackgroundCategory`, `ToolBackgroundDetection`, `ToolBackgroundConfidence`, `SourceUrl`, `SourceNotes`, `IsFrameworkDefault`, `LastVerifiedUtc`. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle wird von den zugehörigen Framework-Procedures gelesen oder gepflegt. Direkte DML kann Katalog- oder Analyseverträge verletzen und ist daher kein unterstützter Betriebsweg. |
| Last und Sperren | Kleine, überwiegend read-only Framework-Metadatentabelle. DML erfolgt nur über Installer oder den dokumentierten Konfigurationspfad; Analysen lesen wenige Zeilen. Sperren bleiben auf die kurze Metadatenpflege begrenzt. |
| Vertrag | Persistenter interner Frameworkvertrag. Schema und Seeds werden über den Installer gepflegt; direkte Abhängigkeiten externer Anwendungen sind nicht unterstützt. |

### `[monitor].[SqlServerBuildCatalog]`

Quelle: `Code/09_VersionAdaptive/011_SqlServerBuildCatalog.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Stellt die kuratierte Build- und Servicingzuordnung für die Offlinebewertung der Serverversion bereit. |
| Schnittstelle | Persistente Tabelle mit 16 in der Quelle typisierten Spalten: `BuildVersion`, `ProductMajorVersion`, `BuildNumber`, `RevisionNumber`, `ReleaseName`, `ServicingBranch`, `KnowledgeBaseNumber`, `ReleaseDate`, `PlatformScope`, `IsSecurityRelease`, `IsLatestInBranch`, `BuildOverviewUrl` sowie 4 weitere Spalten. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle wird von den zugehörigen Framework-Procedures gelesen oder gepflegt. Direkte DML kann Katalog- oder Analyseverträge verletzen und ist daher kein unterstützter Betriebsweg. |
| Last und Sperren | Kleine, überwiegend read-only Framework-Metadatentabelle. DML erfolgt nur über Installer oder den dokumentierten Konfigurationspfad; Analysen lesen wenige Zeilen. Sperren bleiben auf die kurze Metadatenpflege begrenzt. |
| Vertrag | Persistenter interner Frameworkvertrag. Schema und Seeds werden über den Installer gepflegt; direkte Abhängigkeiten externer Anwendungen sind nicht unterstützt. |

### `[monitor].[SqlServerLifecycleCatalog]`

Quelle: `Code/09_VersionAdaptive/012_SqlServerLifecycleCatalog.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Stellt die kuratierte Lifecyclezuordnung für die Offlinebewertung bereit. |
| Schnittstelle | Persistente Tabelle mit 9 in der Quelle typisierten Spalten: `ProductMajorVersion`, `ProductName`, `StartDate`, `MainstreamEndDate`, `ExtendedEndDate`, `LifecyclePolicy`, `LifecycleUrl`, `CatalogAsOfDate`, `SourceRetrievedAtUtc`. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle wird von den zugehörigen Framework-Procedures gelesen oder gepflegt. Direkte DML kann Katalog- oder Analyseverträge verletzen und ist daher kein unterstützter Betriebsweg. |
| Last und Sperren | Kleine, überwiegend read-only Framework-Metadatentabelle. DML erfolgt nur über Installer oder den dokumentierten Konfigurationspfad; Analysen lesen wenige Zeilen. Sperren bleiben auf die kurze Metadatenpflege begrenzt. |
| Vertrag | Persistenter interner Frameworkvertrag. Schema und Seeds werden über den Installer gepflegt; direkte Abhängigkeiten externer Anwendungen sind nicht unterstützt. |

### `[monitor].[PlanAnalysisProfile]`

Quelle: `Code/04_PlanCache/041_PlanAnalysisProfile.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Definiert benannte Analyseprofile für die Ausführungsplananalyse. |
| Schnittstelle | Persistente Tabelle mit 7 in der Quelle typisierten Spalten: `ProfileCode`, `Description`, `Priority`, `IsEnabled`, `IsFrameworkDefault`, `SeedVersion`, `LastUpdatedUtc`. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle wird von den zugehörigen Framework-Procedures gelesen oder gepflegt. Direkte DML kann Katalog- oder Analyseverträge verletzen und ist daher kein unterstützter Betriebsweg. |
| Last und Sperren | Kleine, überwiegend read-only Framework-Metadatentabelle. DML erfolgt nur über Installer oder den dokumentierten Konfigurationspfad; Analysen lesen wenige Zeilen. Sperren bleiben auf die kurze Metadatenpflege begrenzt. |
| Vertrag | Persistenter interner Frameworkvertrag. Schema und Seeds werden über den Installer gepflegt; direkte Abhängigkeiten externer Anwendungen sind nicht unterstützt. |

### `[monitor].[PlanAnalysisRuleThreshold]`

Quelle: `Code/04_PlanCache/042_PlanAnalysisRuleThreshold.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Hinterlegt je Analyseprofil die Schwellenwerte der Plananalyse-Regeln. |
| Schnittstelle | Persistente Tabelle mit 24 in der Quelle typisierten Spalten: `RuleCode`, `ProfileCode`, `Severity`, `IsEnabled`, `MinRatio`, `MaxRatio`, `MinAbsoluteRows`, `MinRowsRead`, `MinRowsNotReturned`, `MinRowsNotReturnedPercent`, `MinExecutionCount`, `MinLogicalReadsPerExecution` sowie 12 weitere Spalten. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle wird von den zugehörigen Framework-Procedures gelesen oder gepflegt. Direkte DML kann Katalog- oder Analyseverträge verletzen und ist daher kein unterstützter Betriebsweg. |
| Last und Sperren | Kleine, überwiegend read-only Framework-Metadatentabelle. DML erfolgt nur über Installer oder den dokumentierten Konfigurationspfad; Analysen lesen wenige Zeilen. Sperren bleiben auf die kurze Metadatenpflege begrenzt. |
| Vertrag | Persistenter interner Frameworkvertrag. Schema und Seeds werden über den Installer gepflegt; direkte Abhängigkeiten externer Anwendungen sind nicht unterstützt. |

### `[monitor].[PlanAnalysisProfileAssignment]`

Quelle: `Code/04_PlanCache/043_PlanAnalysisProfileAssignment.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Ordnet einer Plananalyse ein passendes Profil zu. |
| Schnittstelle | Persistente Tabelle mit 16 in der Quelle typisierten Spalten: `AssignmentId`, `Priority`, `IsEnabled`, `ProfileCode`, `DatabaseNamePattern`, `SchemaNamePattern`, `ObjectNamePattern`, `QueryHash`, `QueryStoreQueryId`, `StatementId`, `ProgramNameLikePattern`, `ResourcePoolId` sowie 4 weitere Spalten. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle wird von den zugehörigen Framework-Procedures gelesen oder gepflegt. Direkte DML kann Katalog- oder Analyseverträge verletzen und ist daher kein unterstützter Betriebsweg. |
| Last und Sperren | Kleine, überwiegend read-only Framework-Metadatentabelle. DML erfolgt nur über Installer oder den dokumentierten Konfigurationspfad; Analysen lesen wenige Zeilen. Sperren bleiben auf die kurze Metadatenpflege begrenzt. |
| Vertrag | Persistenter interner Frameworkvertrag. Schema und Seeds werden über den Installer gepflegt; direkte Abhängigkeiten externer Anwendungen sind nicht unterstützt. |

### `[monitor].[SnapshotTargetConfiguration]`

Quelle: `Code/10_SnapshotBaseline/010_SnapshotTargetConfiguration.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Hält als typisierter Singleton das ausdrücklich konfigurierte lokale Snapshotziel. Ohne separate Paketinstallation bleibt der Frameworkkern zustandslos. |
| Schnittstelle | Persistente Tabelle mit 8 in der Quelle typisierten Spalten: `ConfigurationId`, `TargetDatabaseName`, `IsEnabled`, `DefaultSchedulerType`, `PackageContractVersion`, `SeedVersion`, `LastUpdatedUtc`, `RowVersion`. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle wird von den zugehörigen Framework-Procedures gelesen oder gepflegt. Direkte DML kann Katalog- oder Analyseverträge verletzen und ist daher kein unterstützter Betriebsweg. |
| Last und Sperren | Kleine Singleton-Konfiguration. Nur die öffentliche Konfigurations-Procedure schreibt transaktional; normale Prüfungen lesen eine Zeile. Daraus entstehen keine volumenabhängigen Scans oder anhaltenden Nutzerdatensperren. |
| Vertrag | Persistenter interner Frameworkvertrag. Schema und Seeds werden über den Installer gepflegt; direkte Abhängigkeiten externer Anwendungen sind nicht unterstützt. |

### `[snapshot].[PackageVersion]`

Quelle: `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Versioniert Paket und Zielschema und protokolliert den letzten Installerlauf. |
| Schnittstelle | Persistente Tabelle mit 5 in der Quelle typisierten Spalten: `PackageCode`, `PackageVersion`, `SchemaVersion`, `InstalledAtUtc`, `LastInstallerRunUtc`. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle gehört zum optionalen Snapshot-/Baseline-Paket und wird ausschließlich von dessen Installations-, Collection- und Retentionpfaden verwaltet. Direkte DML ist kein unterstützter Betriebsweg. |
| Last und Sperren | Kleine Paketmetadatentabelle. Der versionierte Installer aktualisiert genau die SC-023-Zeile; Betriebsprüfungen lesen sie punktuell. Dadurch entstehen nur kurze Schlüssel- und Zeilensperren, keine volumenabhängigen Scans. |
| Vertrag | Persistenter interner Paketvertrag. Schemaänderungen erfolgen ausschließlich über den versionierten SC-023-Installer; außerhalb des Pakets besteht keine Kompatibilitätszusage. |

### `[snapshot].[RetentionPolicy]`

Quelle: `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Definiert typisierte Retention-, Batch- und Softbudgetgrenzen. |
| Schnittstelle | Persistente Tabelle mit 11 in der Quelle typisierten Spalten: `RetentionPolicyCode`, `RawRetentionDays`, `PayloadRetentionDays`, `RollupRetentionDays`, `SoftBudgetMB`, `PurgeIntervalMinutes`, `PurgeBatchRows`, `BudgetAction`, `IsFrameworkDefault`, `SeedVersion`, `LastUpdatedUtc`. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle gehört zum optionalen Snapshot-/Baseline-Paket und wird ausschließlich von dessen Installations-, Collection- und Retentionpfaden verwaltet. Direkte DML ist kein unterstützter Betriebsweg. |
| Last und Sperren | Kleine Policytabelle. Die öffentliche Konfiguration schreibt die ausgewählte Policy transaktional; Collection und Purge lesen wenige Zeilen. Die Last ist nicht von der Menge persistierter Samples abhängig. |
| Vertrag | Persistenter interner Paketvertrag. Schemaänderungen erfolgen ausschließlich über den versionierten SC-023-Installer; außerhalb des Pakets besteht keine Kompatibilitätszusage. |

### `[snapshot].[CollectorPolicy]`

Quelle: `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Begrenzt Intervall, Zeilenumfang und optionales Payload je Collector. |
| Schnittstelle | Persistente Tabelle mit 9 in der Quelle typisierten Spalten: `CollectorCode`, `IsEnabled`, `CollectionIntervalSeconds`, `MaxRows`, `PayloadEnabled`, `RetentionPolicyCode`, `IsFrameworkDefault`, `SeedVersion`, `LastUpdatedUtc`. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle gehört zum optionalen Snapshot-/Baseline-Paket und wird ausschließlich von dessen Installations-, Collection- und Retentionpfaden verwaltet. Direkte DML ist kein unterstützter Betriebsweg. |
| Last und Sperren | Kleine Policytabelle. Die öffentliche Konfiguration aktualisiert Collectorgrenzen transaktional; der Scheduler liest die aktive Zeile. Sperren bleiben auf kurze Schlüssel- und Zeilenzugriffe begrenzt. |
| Vertrag | Persistenter interner Paketvertrag. Schemaänderungen erfolgen ausschließlich über den versionierten SC-023-Installer; außerhalb des Pakets besteht keine Kompatibilitätszusage. |

### `[snapshot].[CaptureRun]`

Quelle: `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Speichert Lauf, Schedulerherkunft, UTC-Grenzen, Reset-Epoche und Gesamtstatus. |
| Schnittstelle | Persistente Tabelle mit 15 in der Quelle typisierten Spalten: `CaptureRunId`, `CollectorCode`, `SchedulerType`, `StartedAtUtc`, `EndedAtUtc`, `SourceDatabaseName`, `SqlServerStartTimeUtc`, `ResetEpochId`, `ContractVersion`, `StatusCode`, `IsPartial`, `ErrorNumber` sowie 3 weitere Spalten. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle gehört zum optionalen Snapshot-/Baseline-Paket und wird ausschließlich von dessen Installations-, Collection- und Retentionpfaden verwaltet. Direkte DML ist kein unterstützter Betriebsweg. |
| Last und Sperren | Persistenter Snapshot-Speicher. Collection erzeugt protokollierte Inserts; Retention löscht abgelaufene Zeilen child-first und begrenzt in Batches. Fremdschlüssel und Indizes bestimmen die kurzzeitigen Zeilen- und Schlüsselsperren. |
| Vertrag | Persistenter interner Paketvertrag. Schemaänderungen erfolgen ausschließlich über den versionierten SC-023-Installer; außerhalb des Pakets besteht keine Kompatibilitätszusage. |

### `[snapshot].[ModuleStatus]`

Quelle: `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Bewahrt Partialität, Fehlergrenze und Evidenzlimit je Laufmodul. |
| Schnittstelle | Persistente Tabelle mit 9 in der Quelle typisierten Spalten: `ModuleStatusId`, `CaptureRunId`, `ModuleName`, `CollectionTimeUtc`, `StatusCode`, `IsPartial`, `ErrorNumber`, `ErrorMessage`, `EvidenceLimit`. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle gehört zum optionalen Snapshot-/Baseline-Paket und wird ausschließlich von dessen Installations-, Collection- und Retentionpfaden verwaltet. Direkte DML ist kein unterstützter Betriebsweg. |
| Last und Sperren | Persistenter Snapshot-Speicher. Collection erzeugt protokollierte Inserts; Retention löscht abgelaufene Zeilen child-first und begrenzt in Batches. Fremdschlüssel und Indizes bestimmen die kurzzeitigen Zeilen- und Schlüsselsperren. |
| Vertrag | Persistenter interner Paketvertrag. Schemaänderungen erfolgen ausschließlich über den versionierten SC-023-Installer; außerhalb des Pakets besteht keine Kompatibilitätszusage. |

### `[snapshot].[Scope]`

Quelle: `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Ordnet gehashte technische Scopeidentitäten den persistierten Samples zu. |
| Schnittstelle | Persistente Tabelle mit 6 in der Quelle typisierten Spalten: `ScopeId`, `ScopeType`, `ParentScopeId`, `ScopeKeyHash`, `ScopeIdentityJson`, `CreatedAtUtc`. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle gehört zum optionalen Snapshot-/Baseline-Paket und wird ausschließlich von dessen Installations-, Collection- und Retentionpfaden verwaltet. Direkte DML ist kein unterstützter Betriebsweg. |
| Last und Sperren | Persistenter Snapshot-Speicher. Collection erzeugt protokollierte Inserts; Retention löscht abgelaufene Zeilen child-first und begrenzt in Batches. Fremdschlüssel und Indizes bestimmen die kurzzeitigen Zeilen- und Schlüsselsperren. |
| Vertrag | Persistenter interner Paketvertrag. Schemaänderungen erfolgen ausschließlich über den versionierten SC-023-Installer; außerhalb des Pakets besteht keine Kompatibilitätszusage. |

### `[snapshot].[MetricDefinition]`

Quelle: `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Versioniert Metrikcode, Datentyp, Einheit und Bedeutung. |
| Schnittstelle | Persistente Tabelle mit 9 in der Quelle typisierten Spalten: `MetricDefinitionId`, `MetricCode`, `ValueType`, `Unit`, `ContractVersion`, `Description`, `IsFrameworkDefault`, `SeedVersion`, `LastUpdatedUtc`. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle gehört zum optionalen Snapshot-/Baseline-Paket und wird ausschließlich von dessen Installations-, Collection- und Retentionpfaden verwaltet. Direkte DML ist kein unterstützter Betriebsweg. |
| Last und Sperren | Kleine, versionierte Definitions- und Seedtabelle. Der Installer pflegt Definitionen; Collection löst Metrik-IDs per indexiertem Lookup auf und verändert die Definitionen nicht. Die Last wächst nicht mit der Samplehistorie. |
| Vertrag | Persistenter interner Paketvertrag. Schemaänderungen erfolgen ausschließlich über den versionierten SC-023-Installer; außerhalb des Pakets besteht keine Kompatibilitätszusage. |

### `[snapshot].[MetricSample]`

Quelle: `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Speichert genau einen typisierten Wert je Lauf, Scope und Metrikdefinition. |
| Schnittstelle | Persistente Tabelle mit 11 in der Quelle typisierten Spalten: `MetricSampleId`, `CaptureRunId`, `ScopeId`, `MetricDefinitionId`, `CollectedAtUtc`, `ResetEpochId`, `NumericValue`, `BigintValue`, `StringValue`, `QualityCode`, `IsPartial`. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle gehört zum optionalen Snapshot-/Baseline-Paket und wird ausschließlich von dessen Installations-, Collection- und Retentionpfaden verwaltet. Direkte DML ist kein unterstützter Betriebsweg. |
| Last und Sperren | Persistenter Snapshot-Speicher. Collection erzeugt protokollierte Inserts; Retention löscht abgelaufene Zeilen child-first und begrenzt in Batches. Fremdschlüssel und Indizes bestimmen die kurzzeitigen Zeilen- und Schlüsselsperren. |
| Vertrag | Persistenter interner Paketvertrag. Schemaänderungen erfolgen ausschließlich über den versionierten SC-023-Installer; außerhalb des Pakets besteht keine Kompatibilitätszusage. |

### `[snapshot].[PayloadSnapshot]`

Quelle: `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Hält optional den vollständigen komprimierten und hashgebundenen Collectorvertrag im autorisierten Zielsystem. |
| Schnittstelle | Persistente Tabelle mit 10 in der Quelle typisierten Spalten: `PayloadSnapshotId`, `CaptureRunId`, `ModuleName`, `CapturedAtUtc`, `PayloadFormat`, `PayloadContractVersion`, `CompressionType`, `PayloadHash`, `Payload`, `UncompressedCharacterCount`. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle gehört zum optionalen Snapshot-/Baseline-Paket und wird ausschließlich von dessen Installations-, Collection- und Retentionpfaden verwaltet. Direkte DML ist kein unterstützter Betriebsweg. |
| Last und Sperren | Persistenter Snapshot-Speicher. Collection erzeugt protokollierte Inserts; Retention löscht abgelaufene Zeilen child-first und begrenzt in Batches. Fremdschlüssel und Indizes bestimmen die kurzzeitigen Zeilen- und Schlüsselsperren. |
| Vertrag | Persistenter interner Paketvertrag. Schemaänderungen erfolgen ausschließlich über den versionierten SC-023-Installer; außerhalb des Pakets besteht keine Kompatibilitätszusage. |

### `[snapshot].[PurgeRun]`

Quelle: `Code/10_SnapshotBaseline/030_Snapshot_Target_Schema.sql`

| Dimension | Beschreibung |
|---|---|
| Aufgabe | Protokolliert ausschließlich technische Summen begrenzter Retentionläufe. |
| Schnittstelle | Persistente Tabelle mit 15 in der Quelle typisierten Spalten: `PurgeRunId`, `StartedAtUtc`, `EndedAtUtc`, `StatusCode`, `BatchesExecuted`, `MetricRowsDeleted`, `PayloadRowsDeleted`, `ModuleRowsDeleted`, `CaptureRunsDeleted`, `ScopeRowsDeleted`, `UsedDataMbBefore`, `UsedDataMbAfter` sowie 3 weitere Spalten. Schlüssel, Constraints und Defaults sind Bestandteil des Installationsskripts. |
| Verwendung | Die Tabelle gehört zum optionalen Snapshot-/Baseline-Paket und wird ausschließlich von dessen Installations-, Collection- und Retentionpfaden verwaltet. Direkte DML ist kein unterstützter Betriebsweg. |
| Last und Sperren | Schreibt pro Retentionlauf eine technische Laufzeile und aktualisiert deren Summen. Diese Metadaten sind klein gegenüber den Sampletabellen; die eigentlichen Löschkosten entstehen in den child-first verarbeiteten Evidenztabellen. |
| Vertrag | Persistenter interner Paketvertrag. Schemaänderungen erfolgen ausschließlich über den versionierten SC-023-Installer; außerhalb des Pakets besteht keine Kompatibilitätszusage. |
