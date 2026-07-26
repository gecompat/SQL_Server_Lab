USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 167_Special_Case_API_Contract.sql
Zweck        : Prüft den metadatenbasierten API-Vertrag der Spezialfallmodule.
Nebenwirkung : keine fachlichen Scans und keine Persistenz.
===============================================================================
*/
SET NOCOUNT ON;

DECLARE @Expected TABLE
(
      [ProcedureName] sysname NOT NULL
    , [RequiredParameter] sysname NOT NULL
);

INSERT @Expected
VALUES
(N'USP_DatabaseIntegrityAnalysis',N'@ResultSetArt'),
(N'USP_DatabaseIntegrityAnalysis',N'@Json'),
(N'USP_DatabaseIntegrityAnalysis',N'@BackupHistoryDays'),
(N'USP_DatabaseCapacityAnalysis',N'@ResultSetArt'),
(N'USP_PerformanceCounters',N'@SampleSeconds'),
(N'USP_CriticalEngineEvents',N'@MitServerDiagnostics'),
(N'USP_IntelligentQueryProcessingAnalysis',N'@DatabaseNames'),
(N'USP_InternalContentionAnalysis',N'@SampleSeconds'),
(N'USP_BufferPoolAnalysis',N'@MitBufferPoolVerteilung'),
(N'USP_BackupChainAnalysis',N'@HistoryDays'),
(N'USP_SchemaDesignAnalysis',N'@IdentityWarnPercent'),
(N'USP_StatisticsDistributionAnalysis',N'@MaxVerteilungsStatistiken'),
(N'USP_StatisticsDistributionAnalysis',N'@SkewWarnFaktor'),
(N'USP_ObjectAnalysis',N'@MitStatisticsDistribution'),
(N'USP_AvailabilityDeepAnalysis',N'@MitClusterNetzwerken'),
(N'USP_AgentMonitoringAnalysis',N'@HistoryHours'),
(N'USP_DiagnosticFindings',N'@NurAbPrioritaet'),
(N'USP_DiagnosticFindings',N'@MitStatistikverteilung'),
(N'USP_DiagnosticFindings',N'@Json'),
(N'USP_SpecialFeatureInventory',N'@NurErkannteFeatures'),
(N'USP_SpecialFeatureInventory',N'@StatusCodeOut'),
(N'USP_InMemoryOltpAnalysis',N'@MitHashIndexStats'),
(N'USP_InMemoryOltpAnalysis',N'@HashAvgChainWarn'),
(N'USP_InMemoryOltpAnalysis',N'@StatusCodeOut'),
(N'USP_TemporalAnalysis',N'@HistorySizeWarnMb'),
(N'USP_TemporalAnalysis',N'@MinHistoryMbForRatioWarn'),
(N'USP_TemporalAnalysis',N'@StatusCodeOut'),
(N'USP_ServiceBrokerAnalysis',N'@TransmissionAgeWarnMinutes'),
(N'USP_ServiceBrokerAnalysis',N'@QueueRowsWarn'),
(N'USP_ServiceBrokerAnalysis',N'@StatusCodeOut'),
(N'USP_FullTextAnalysis',N'@PopulationAgeWarnMinutes'),
(N'USP_FullTextAnalysis',N'@QueryableFragmentWarn'),
(N'USP_FullTextAnalysis',N'@StatusCodeOut'),
(N'USP_DataCaptureDeepAnalysis',N'@ChangeTrackingClientVersion'),
(N'USP_DataCaptureDeepAnalysis',N'@CdcLatencyWarnSeconds'),
(N'USP_DataCaptureDeepAnalysis',N'@ReplicationPendingCommandWarn'),
(N'USP_DataCaptureDeepAnalysis',N'@StatusCodeOut'),
(N'USP_EncryptionAnalysis',N'@TdeTransitionWarnMinutes'),
(N'USP_EncryptionAnalysis',N'@ExpliziteBackupverschluesselungErwartet'),
(N'USP_EncryptionAnalysis',N'@StatusCodeOut'),
(N'USP_MaintenanceOperations',N'@ResumablePausedWarnMinutes'),
(N'USP_MaintenanceOperations',N'@JobNames'),
(N'USP_MaintenanceOperations',N'@StatusCodeOut');

DECLARE @Missing nvarchar(max);

SELECT @Missing = STRING_AGG(CONCAT([e].[ProcedureName],N'.',[e].[RequiredParameter]),N', ')
FROM @Expected AS [e]
WHERE NOT EXISTS
(
    SELECT 1
    FROM [sys].[procedures] AS [p] WITH (NOLOCK)
    JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[p].[schema_id]
    JOIN [sys].[parameters] AS [x] WITH (NOLOCK) ON [x].[object_id]=[p].[object_id]
    WHERE [s].[name]=N'monitor'
      AND [p].[name]=[e].[ProcedureName]
      AND [x].[name]=[e].[RequiredParameter]
);

IF @Missing IS NOT NULL
BEGIN
    DECLARE @Message nvarchar(2048)=CONCAT(N'Fehlende Spezialfall-API: ',@Missing);
    THROW 54100,@Message,1;
END;

DECLARE @ProcedureMetadata TABLE
(
      [ProcedureName] sysname NOT NULL PRIMARY KEY
    , [ObjectId] int NOT NULL
    , [Definition] nvarchar(max) NULL
);

INSERT @ProcedureMetadata ([ProcedureName],[ObjectId],[Definition])
SELECT [p].[name],[p].[object_id],[m].[definition]
FROM [sys].[procedures] AS [p] WITH (NOLOCK)
JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
  ON [s].[schema_id]=[p].[schema_id]
LEFT JOIN [sys].[sql_modules] AS [m] WITH (NOLOCK)
  ON [m].[object_id]=[p].[object_id]
WHERE [s].[name]=N'monitor';

DECLARE @DiagnosticFindingsObjectId int =
    (SELECT [ObjectId] FROM @ProcedureMetadata WHERE [ProcedureName]=N'USP_DiagnosticFindings');
DECLARE @ServerHealthAnalysisObjectId int =
    (SELECT [ObjectId] FROM @ProcedureMetadata WHERE [ProcedureName]=N'USP_ServerHealthAnalysis');

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[sql_expression_dependencies] AS [d] WITH (NOLOCK)
    WHERE [d].[referencing_id]=@DiagnosticFindingsObjectId
      AND [d].[referenced_entity_name]=N'USP_DatabaseIntegrityAnalysis'
)
    THROW 54101,N'USP_DiagnosticFindings besitzt keine erkennbare Abhängigkeit zur Integritätsevidenz.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[parameters] WITH (NOLOCK)
    WHERE [object_id]=@ServerHealthAnalysisObjectId
      AND [name]=N'@MitFindings'
)
    THROW 54102,N'Der Server-Health-Orchestrator veröffentlicht @MitFindings nicht.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[sql_expression_dependencies] AS [d] WITH (NOLOCK)
    WHERE [d].[referencing_id]=@DiagnosticFindingsObjectId
      AND [d].[referenced_entity_name]=N'USP_StatisticsDistributionAnalysis'
)
    THROW 54103,N'USP_DiagnosticFindings besitzt keine erkennbare Abhängigkeit zur Statistikverteilung.',1;

DECLARE @InMemoryDefinition nvarchar(max)=
    (SELECT [Definition] FROM @ProcedureMetadata WHERE [ProcedureName]=N'USP_InMemoryOltpAnalysis');
IF @InMemoryDefinition IS NULL
    THROW 54104,N'Die Definition der In-Memory-OLTP-Analyse ist nicht sichtbar.',1;

IF @InMemoryDefinition LIKE N'%[[]relative_file_path[]]%'
 OR @InMemoryDefinition LIKE N'%[[]container_id[]]%'
 OR @InMemoryDefinition LIKE N'%[[]xtp_transaction_id[]]%'
 OR @InMemoryDefinition LIKE N'%[[]transaction_id[]]%'
 OR @InMemoryDefinition LIKE N'%[[]session_id[]]%'
 OR @InMemoryDefinition LIKE N'%[[]memory_address[]]%'
    THROW 54105,N'Die In-Memory-OLTP-Analyse referenziert einen ausgeschlossenen Detailidentifikator.',1;

DECLARE @TemporalDefinition nvarchar(max)=
    (SELECT [Definition] FROM @ProcedureMetadata WHERE [ProcedureName]=N'USP_TemporalAnalysis');
IF @TemporalDefinition IS NULL
    THROW 54106,N'Die Definition der Temporal-Tables-Analyse ist nicht sichtbar.',1;

DECLARE @MissingTemporalSources nvarchar(2048)=NULL;
IF CHARINDEX(N'[sys].[periods]',@TemporalDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingTemporalSources=N'sys.periods';
IF CHARINDEX(N'[history_table_id]',@TemporalDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingTemporalSources=CONCAT_WS(N', ',@MissingTemporalSources,N'history_table_id');
IF CHARINDEX(N'[sys].[dm_db_partition_stats]',@TemporalDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingTemporalSources=CONCAT_WS(N', ',@MissingTemporalSources,N'sys.dm_db_partition_stats');
IF @MissingTemporalSources IS NOT NULL
BEGIN
    DECLARE @TemporalSourceMessage nvarchar(2048)=CONCAT(N'Die Temporal-Tables-Analyse besitzt nicht alle erwarteten read-only Metadatenquellen: ',@MissingTemporalSources,N'.');
    THROW 54107,@TemporalSourceMessage,1;
END;

IF @TemporalDefinition LIKE N'%FOR SYSTEM_TIME AS OF%'
 OR @TemporalDefinition LIKE N'%FOR SYSTEM_TIME ALL%'
 OR @TemporalDefinition LIKE N'%SYSTEM_VERSIONING = OFF%'
    THROW 54108,N'Die Temporal-Tables-Analyse enthält einen ausgeschlossenen Nutzdaten- oder Änderungszugriff.',1;

DECLARE @BrokerDefinition nvarchar(max)=
    (SELECT [Definition] FROM @ProcedureMetadata WHERE [ProcedureName]=N'USP_ServiceBrokerAnalysis');
IF @BrokerDefinition IS NULL
    THROW 54109,N'Die Definition der Service-Broker-Analyse ist nicht sichtbar.',1;

DECLARE @MissingBrokerSources nvarchar(2048)=NULL;
IF CHARINDEX(N'[sys].[service_queues]',@BrokerDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingBrokerSources=N'sys.service_queues';
IF CHARINDEX(N'[sys].[transmission_queue]',@BrokerDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingBrokerSources=CONCAT_WS(N', ',@MissingBrokerSources,N'sys.transmission_queue');
IF CHARINDEX(N'[sys].[conversation_endpoints]',@BrokerDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingBrokerSources=CONCAT_WS(N', ',@MissingBrokerSources,N'sys.conversation_endpoints');
IF CHARINDEX(N'[sys].[dm_broker_queue_monitors]',@BrokerDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingBrokerSources=CONCAT_WS(N', ',@MissingBrokerSources,N'sys.dm_broker_queue_monitors');
IF @MissingBrokerSources IS NOT NULL
BEGIN
    DECLARE @BrokerSourceMessage nvarchar(2048)=CONCAT(N'Die Service-Broker-Analyse besitzt nicht alle erwarteten read-only Metadatenquellen: ',@MissingBrokerSources,N'.');
    THROW 54110,@BrokerSourceMessage,1;
END;

IF @BrokerDefinition LIKE N'%[[]message_body[]]%'
 OR @BrokerDefinition LIKE N'%RECEIVE TOP%'
 OR @BrokerDefinition LIKE N'%ALTER QUEUE [[]%'
 OR @BrokerDefinition LIKE N'%END CONVERSATION [[]%'
    THROW 54111,N'Die Service-Broker-Analyse enthält einen ausgeschlossenen Payload- oder Änderungszugriff.',1;

DECLARE @FullTextDefinition nvarchar(max)=
    (SELECT [Definition] FROM @ProcedureMetadata WHERE [ProcedureName]=N'USP_FullTextAnalysis');
IF @FullTextDefinition IS NULL
    THROW 54112,N'Die Definition der Full-Text-Analyse ist nicht sichtbar.',1;

DECLARE @MissingFullTextSources nvarchar(2048)=NULL;
IF CHARINDEX(N'[sys].[fulltext_indexes]',@FullTextDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingFullTextSources=N'sys.fulltext_indexes';
IF CHARINDEX(N'[sys].[dm_fts_index_population]',@FullTextDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingFullTextSources=CONCAT_WS(N', ',@MissingFullTextSources,N'sys.dm_fts_index_population');
IF CHARINDEX(N'[sys].[dm_fts_outstanding_batches]',@FullTextDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingFullTextSources=CONCAT_WS(N', ',@MissingFullTextSources,N'sys.dm_fts_outstanding_batches');
IF CHARINDEX(N'[sys].[fulltext_index_fragments]',@FullTextDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingFullTextSources=CONCAT_WS(N', ',@MissingFullTextSources,N'sys.fulltext_index_fragments');
IF @MissingFullTextSources IS NOT NULL
BEGIN
    DECLARE @FullTextSourceMessage nvarchar(2048)=CONCAT(N'Die Full-Text-Analyse besitzt nicht alle erwarteten read-only Metadatenquellen: ',@MissingFullTextSources,N'.');
    THROW 54113,@FullTextSourceMessage,1;
END;

IF CHARINDEX(N'[sys].[dm_fts_index_keywords',@FullTextDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'[sys].[fulltext_stopwords]',@FullTextDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'FULLTEXTCATALOGPROPERTY',@FullTextDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR @FullTextDefinition LIKE N'%ALTER FULLTEXT CATALOG [[]%'
 OR CHARINDEX(N'START FULL POPULATION;',@FullTextDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
    THROW 54114,N'Die Full-Text-Analyse enthält einen ausgeschlossenen Inhalts-, Pfad- oder Änderungszugriff.',1;

DECLARE @DataCaptureDefinition nvarchar(max)=
    (SELECT [Definition] FROM @ProcedureMetadata WHERE [ProcedureName]=N'USP_DataCaptureDeepAnalysis');
IF @DataCaptureDefinition IS NULL
    THROW 54115,N'Die Data-Capture-Tiefenanalyse ist nicht sichtbar.',1;

DECLARE @MissingDataCaptureSources nvarchar(2048)=NULL;
IF CHARINDEX(N'[sys].[change_tracking_tables]',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingDataCaptureSources=N'sys.change_tracking_tables';
IF CHARINDEX(N'[cdc].[change_tables]',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingDataCaptureSources=CONCAT_WS(N', ',@MissingDataCaptureSources,N'cdc.change_tables');
IF CHARINDEX(N'[sys].[dm_cdc_log_scan_sessions]',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingDataCaptureSources=CONCAT_WS(N', ',@MissingDataCaptureSources,N'sys.dm_cdc_log_scan_sessions');
IF CHARINDEX(N'[sys].[dm_cdc_errors]',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingDataCaptureSources=CONCAT_WS(N', ',@MissingDataCaptureSources,N'sys.dm_cdc_errors');
IF CHARINDEX(N'[dbo].[MSdistribution_status]',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingDataCaptureSources=CONCAT_WS(N', ',@MissingDataCaptureSources,N'MSdistribution_status');
IF CHARINDEX(N'[dbo].[MSlogreader_history]',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingDataCaptureSources=CONCAT_WS(N', ',@MissingDataCaptureSources,N'MSlogreader_history');
IF CHARINDEX(N'[dbo].[MSmerge_sessions]',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    SET @MissingDataCaptureSources=CONCAT_WS(N', ',@MissingDataCaptureSources,N'MSmerge_sessions');
IF @MissingDataCaptureSources IS NOT NULL
BEGIN
    DECLARE @DataCaptureSourceMessage nvarchar(2048)=CONCAT(N'Die Data-Capture-Tiefenanalyse besitzt nicht alle erwarteten read-only Metadatenquellen: ',@MissingDataCaptureSources,N'.');
    THROW 54116,@DataCaptureSourceMessage,1;
END;

IF CHARINDEX(N'CHANGETABLE(',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'[error_message]',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'[comments]',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'[publisher_login]',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'[subscriber_login]',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'[publisher_password]',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'[subscriber_password]',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'[xact_seqno]',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'[command_id]',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'sp_replmonitorsubscriptionpendingcmds',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'ALTER DATABASE ',@DataCaptureDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
    THROW 54117,N'Die Data-Capture-Tiefenanalyse enthält einen ausgeschlossenen Nutzdaten-, Credential-, Command- oder Änderungszugriff.',1;

DECLARE @EncryptionDefinition nvarchar(max)=
    (SELECT [Definition] FROM @ProcedureMetadata WHERE [ProcedureName]=N'USP_EncryptionAnalysis');
IF @EncryptionDefinition IS NULL
    THROW 54118,N'Die Verschluesselungsanalyse ist nicht sichtbar.',1;

IF CHARINDEX(N'[sys].[dm_database_encryption_keys]',@EncryptionDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
 OR CHARINDEX(N'[sys].[certificates]',@EncryptionDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
 OR CHARINDEX(N'[dbo].[backupset]',@EncryptionDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
 OR CHARINDEX(N'[sys].[column_master_keys]',@EncryptionDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    THROW 54119,N'Der Verschluesselungsanalyse fehlt mindestens eine erwartete read-only Metadatenquelle.',1;

IF CHARINDEX(N'[key_path]',@EncryptionDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'[signature]',@EncryptionDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'[encrypted_value]',@EncryptionDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'[user_name]',@EncryptionDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'[physical_device_name]',@EncryptionDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
    THROW 54120,N'Die Verschluesselungsanalyse referenziert ausgeschlossene Schluessel-, Konto- oder Medieninformationen.',1;

DECLARE @MaintenanceDefinition nvarchar(max)=
    (SELECT [Definition] FROM @ProcedureMetadata WHERE [ProcedureName]=N'USP_MaintenanceOperations');
IF @MaintenanceDefinition IS NULL
    THROW 54121,N'Die Wartungsoperationsanalyse ist nicht sichtbar.',1;

IF CHARINDEX(N'[sys].[index_resumable_operations]',@MaintenanceDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
 OR CHARINDEX(N'[sys].[dm_exec_requests]',@MaintenanceDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
 OR CHARINDEX(N'[sys].[dm_tran_persistent_version_store_stats]',@MaintenanceDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
 OR CHARINDEX(N'[dbo].[sysjobactivity]',@MaintenanceDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)=0
    THROW 54122,N'Der Wartungsoperationsanalyse fehlt mindestens eine erwartete read-only Quelle.',1;

IF CHARINDEX(N'[sql_text]',@MaintenanceDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'[wait_resource]',@MaintenanceDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'[owner_sid]',@MaintenanceDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'[step_name]',@MaintenanceDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'sp_start_job',@MaintenanceDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
 OR CHARINDEX(N'sp_stop_job',@MaintenanceDefinition COLLATE SQL_Latin1_General_CP1_CS_AS)>0
    THROW 54123,N'Die Wartungsoperationsanalyse referenziert ausgeschlossene Inhalts-, Identitaets- oder Aenderungsdaten.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],
       CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [VerifiedContractEntries],
       N'Nur Katalog- und Abhängigkeitsprüfung; keine fachlichen Scans.' AS [Detail]
FROM @Expected;
GO
