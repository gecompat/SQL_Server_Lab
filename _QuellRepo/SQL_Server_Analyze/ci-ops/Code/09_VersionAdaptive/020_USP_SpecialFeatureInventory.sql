USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_SpecialFeatureInventory
Version      : 1.2.0
Stand        : 2026-07-23
Typ          : Stored Procedure
Zweck        : Inventarisiert leichtgewichtig die im sichtbaren Metadatenscope
               genutzten oder lediglich konfigurierten SQL-Server-
               Spezialfeatures und verweist auf passende Deep-Dive-Module.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : Datenbank- und Objektkataloge für In-Memory OLTP, Temporal,
               Service Broker, Full-Text, Data Capture, Verschlüsselung, CLR,
               External Tables/Runtimes, FILESTREAM, Graph, Spatial, XML,
               native JSON-/Vector-Typen und benutzerdefinierte Typen.
Abgrenzung   : Das Ergebnis ist ein Nutzungsinventar, kein Gesundheitsurteil.
               Nicht sichtbare Metadaten können zu Nullzählungen führen.
               Externe Locations, Credentials, Service-Broker-Payloads,
               CLR-Binaries und Moduldefinitionen werden nicht gelesen.
Kosten       : LOW. Ausschließlich aggregierte Systemkatalogabfragen; keine
               Benutzertabellen-, Payload-, Definitions- oder Datenscans.
Locking      : Der angeforderte LOCK_TIMEOUT gilt für die Katalogpfade; der
               vorherige Sessionwert wird vor der Ausgabe wiederhergestellt.
Änderungen   : 1.2.0 - Native-JSON-Erkennung auf das implementierte
                         JSON-Indexinventar in USP_ObjectInventory geroutet.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_SpecialFeatureInventory]
      @DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @NurErkannteFeatures              bit            = 0
    , @MaxZeilen                        int            = 2000
    , @LockTimeoutMs                    int            = 0
    , @ResultSetArt                     varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
    , @StatusCodeOut                    varchar(40)     = NULL OUTPUT
    , @IsPartialOut                     bit            = NULL OUTPUT
    , @ErrorNumberOut                   int            = NULL OUTPUT
    , @ErrorMessageOut                  nvarchar(2048)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json = NULL;
    DECLARE @OriginalLockTimeout int=@@LOCK_TIMEOUT;
    DECLARE @LockTimeoutSql nvarchar(64);

    DECLARE @OutputMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @OutputMode = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @OutputMode = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'features',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Now datetime2(3)=SYSUTCDATETIME();
    DECLARE @Major int=TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'));
    DECLARE @StatusCode varchar(40)='AVAILABLE';
    DECLARE @IsPartial bit=0;
    DECLARE @ErrorNumber int=NULL;
    DECLARE @ErrorMessage nvarchar(2048)=NULL;
    DECLARE @PrintMessage nvarchar(2048);
    DECLARE @Limit bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0
                               THEN CONVERT(bigint,9223372036854775807)
                               WHEN @MaxZeilen<0 THEN CONVERT(bigint,0)
                               ELSE CONVERT(bigint,@MaxZeilen) END;
    DECLARE @ExternalScriptsConfigured bit=NULL;
    DECLARE @ExternalScriptsConfigurationAvailable bit=1;

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_SpecialFeatureInventory';
        PRINT N'Die Procedure führt eine leichtgewichtige Nutzungsinventur sichtbarer Spezialfeature-Metadaten durch und gibt kein Gesundheitsurteil ab.';
        PRINT N'@DatabaseNames=N''[Db1]|[Db2]''; NULL=alle; N'''' bedeutet keine Einschränkung. Pattern separat.';
        PRINT N'@NurErkannteFeatures=1 unterdrückt NOT_DETECTED_VISIBLE_SCOPE und UNAVAILABLE_VERSION in der Ausgabe.';
        PRINT N'Die Datenbankauswahl wird nicht vorab begrenzt; ein positiver Wert in @MaxZeilen begrenzt die Ausgaben, während NULL oder 0 keine Begrenzung setzt.';
        PRINT N'@ResultSetArt=CONSOLE|RAW|TABLE|NONE; TABLE verwendet @ResultTablesJson; @JsonErzeugen=1 erzeugt @Json OUTPUT.';
        PRINT N'Keine externen Locations, Credentials, Payloads, CLR-Binaries oder Moduldefinitionen werden gelesen.';
        PRINT N'Für native JSON-Spalten verweist das Inventar auf USP_ObjectInventory; dort werden capability-adaptiv JSON-Index- und Pfadmetadaten gelesen, jedoch keine JSON-Dokumentwerte.';
        RETURN;
    END;

    IF @SystemdatenbankenEinbeziehen IS NULL OR @NurErkannteFeatures IS NULL
       OR @JsonErzeugen IS NULL OR @PrintMeldungen IS NULL
 OR @MaxZeilen<0
       OR @LockTimeoutMs IS NULL OR @LockTimeoutMs NOT BETWEEN 0 AND 60000
       OR @OutputMode NOT IN ('RAW','CONSOLE','NONE')
    BEGIN
        SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,
               @ErrorMessage=N'Ungültiger Bit-, Mengen-, Lock-Timeout- oder Ausgabeparameter.';
    END;

    IF @StatusCode='AVAILABLE'
    BEGIN
        SET @LockTimeoutSql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(20),@LockTimeoutMs)+N';';
        EXEC [sys].[sp_executesql] @LockTimeoutSql;
    END;

    BEGIN TRY
        SELECT @ExternalScriptsConfigured=CONVERT(bit,[value_in_use])
        FROM [sys].[configurations] WITH (NOLOCK)
        WHERE [name]=N'external scripts enabled';
    END TRY
    BEGIN CATCH
        SET @ExternalScriptsConfigured=NULL;
        SET @ExternalScriptsConfigurationAvailable=0;
    END CATCH;

    CREATE TABLE [#SpecialFeatureInventory_DatabaseCandidates]
    (
          [DatabaseId] int NOT NULL
        , [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [StateDesc] nvarchar(60) NULL
        , [UserAccessDesc] nvarchar(60) NULL
        , [IsReadOnly] bit NULL
        , [CompatibilityLevel] tinyint NULL
        , [CollationName] sysname NULL
        , [RecoveryModelDesc] nvarchar(60) NULL
        , [IsSystemDatabase] bit NULL
        , [RequestedOrdinal] int NULL
    );
    CREATE TABLE [#SpecialFeatureInventory_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NOT NULL
    );
    CREATE TABLE [#SpecialFeatureInventory_DatabaseStatus]
    (
          [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [FeatureRows] bigint NOT NULL
        , [DetectedFeatureRows] bigint NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [Detail] nvarchar(1000) NULL
    );
    CREATE TABLE [#SpecialFeatureInventory_FeatureInventory]
    (
          [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [FeatureCode] varchar(64) NOT NULL
        , [FeatureFamily] nvarchar(120) NOT NULL
        , [DetectionStatus] varchar(40) NOT NULL
        , [DetectedItemCount] bigint NULL
        , [ConfigurationState] nvarchar(120) NULL
        , [SourceObjects] nvarchar(1000) NOT NULL
        , [RecommendedModule] sysname NULL
        , [RecommendedModuleStatus] varchar(40) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );

    DECLARE @CrossDatabaseRequested bit=0;
    IF @StatusCode='AVAILABLE'
    BEGIN
        EXEC [monitor].[USP_PrepareDatabaseCandidates]
              @DatabaseNames=@DatabaseNames
            , @SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen
            , @DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

            , @AnalysisClass=NULL
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT
            , @CrossDatabaseRequested=@CrossDatabaseRequested OUTPUT,@CandidateTable=N'#SpecialFeatureInventory_DatabaseCandidates',@WarningTable=N'#SpecialFeatureInventory_DatabaseCandidateWarnings';
    END;

    INSERT [#SpecialFeatureInventory_DatabaseStatus]
    ([DatabaseName],[StatusCode],[IsPartial],[FeatureRows],[DetectedFeatureRows],[ErrorNumber],[ErrorMessage],[Detail])
    SELECT [DatabaseName],'AVAILABLE',0,0,0,NULL,NULL,
           N'Aggregierte, sichtbare Katalogmetadaten; eine Nullzählung beweist keine Feature-Abwesenheit.'
    FROM [#SpecialFeatureInventory_DatabaseCandidates];

    INSERT [#SpecialFeatureInventory_DatabaseStatus]
    ([DatabaseName],[StatusCode],[IsPartial],[FeatureRows],[DetectedFeatureRows],[ErrorNumber],[ErrorMessage],[Detail])
    SELECT [RequestedName],[StatusCode],1,0,0,NULL,[ErrorMessage],N'Explizit angeforderte Datenbank nicht auswertbar.'
    FROM [#SpecialFeatureInventory_DatabaseCandidateWarnings];

    IF @StatusCode='AVAILABLE' AND NOT EXISTS(SELECT 1 FROM [#SpecialFeatureInventory_DatabaseCandidates])
    BEGIN
        SET @StatusCode='NOT_APPLICABLE';
        SET @ErrorMessage=N'Keine auswertbare Datenbank im gewählten Scope.';
    END;

    IF @StatusCode='AVAILABLE'
    BEGIN
        DECLARE @DbName sysname,@Sql nvarchar(max);
        DECLARE [DatabaseCursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [DatabaseName]
            FROM [#SpecialFeatureInventory_DatabaseCandidates]
            ORDER BY COALESCE([RequestedOrdinal],[DatabaseId]),[DatabaseId];
        OPEN [DatabaseCursor];
        FETCH NEXT FROM [DatabaseCursor] INTO @DbName;

        WHILE @@FETCH_STATUS=0
        BEGIN
            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
DECLARE @MemoryOptimized bigint=0,@Temporal bigint=0,@Broker bigint=0,@FullText bigint=0;
DECLARE @ChangeTracking bigint=0,@Cdc bigint=0,@Encryption bigint=0,@Clr bigint=0;
DECLARE @ExternalTables bigint=0,@ExternalRuntime bigint=0,@FileStream bigint=0,@Graph bigint=0;
DECLARE @Spatial bigint=0,@Xml bigint=0,@NativeJson bigint=0,@Vector bigint=0,@UserTypes bigint=0;
DECLARE @BrokerEnabled bit=0,@CdcEnabled bit=0,@Encrypted bit=0;

SELECT @BrokerEnabled=COALESCE([is_broker_enabled],0),
       @CdcEnabled=COALESCE([is_cdc_enabled],0),
       @Encrypted=COALESCE([is_encrypted],0)
FROM [sys].[databases] WITH (NOLOCK)
WHERE [database_id]=DB_ID();

SELECT @MemoryOptimized=COUNT_BIG(*)
FROM [sys].[tables] WITH (NOLOCK)
WHERE [is_ms_shipped]=0 AND [is_memory_optimized]=1;
SELECT @MemoryOptimized=@MemoryOptimized+COUNT_BIG(*)
FROM [sys].[filegroups] WITH (NOLOCK)
WHERE [type]=''FX'';

SELECT @Temporal=COUNT_BIG(*)
FROM [sys].[tables] WITH (NOLOCK)
WHERE [is_ms_shipped]=0 AND [temporal_type]=2;

SELECT @Broker=COUNT_BIG(*)
FROM [sys].[service_queues] WITH (NOLOCK)
WHERE [is_ms_shipped]=0;
SELECT @Broker=@Broker+COUNT_BIG(*)
FROM [sys].[services] [svc] WITH (NOLOCK)
JOIN [sys].[service_queues] [q] WITH (NOLOCK) ON [q].[object_id]=[svc].[service_queue_id]
WHERE [q].[is_ms_shipped]=0;
SET @Broker=@Broker+CONVERT(bigint,@BrokerEnabled);

SELECT @FullText=COUNT_BIG(*) FROM [sys].[fulltext_catalogs] WITH (NOLOCK);
SELECT @FullText=@FullText+COUNT_BIG(*) FROM [sys].[fulltext_indexes] WITH (NOLOCK);

SELECT @ChangeTracking=COUNT_BIG(*) FROM [sys].[change_tracking_tables] WITH (NOLOCK);
SELECT @ChangeTracking=@ChangeTracking+COUNT_BIG(*)
FROM [sys].[change_tracking_databases] WITH (NOLOCK)
WHERE [database_id]=DB_ID();

SELECT @Cdc=COUNT_BIG(*)
FROM [sys].[tables] WITH (NOLOCK)
WHERE [is_ms_shipped]=0 AND [is_tracked_by_cdc]=1;
SET @Cdc=@Cdc+CONVERT(bigint,@CdcEnabled);

SELECT @Encryption=COUNT_BIG(*)
FROM [sys].[columns] [c] WITH (NOLOCK)
JOIN [sys].[objects] [o] WITH (NOLOCK) ON [o].[object_id]=[c].[object_id]
WHERE [o].[is_ms_shipped]=0 AND [c].[encryption_type] IS NOT NULL;
SELECT @Encryption=@Encryption+COUNT_BIG(*) FROM [sys].[column_master_keys] WITH (NOLOCK);
SELECT @Encryption=@Encryption+COUNT_BIG(*) FROM [sys].[column_encryption_keys] WITH (NOLOCK);
SET @Encryption=@Encryption+CONVERT(bigint,@Encrypted);

SELECT @Clr=COUNT_BIG(*)
FROM [sys].[assemblies] WITH (NOLOCK)
WHERE [is_user_defined]=1;

SELECT @ExternalTables=COUNT_BIG(*) FROM [sys].[external_tables] WITH (NOLOCK);
SELECT @ExternalTables=@ExternalTables+COUNT_BIG(*) FROM [sys].[external_data_sources] WITH (NOLOCK);

SELECT @ExternalRuntime=COUNT_BIG(*) FROM [sys].[external_languages] WITH (NOLOCK);
SELECT @ExternalRuntime=@ExternalRuntime+COUNT_BIG(*) FROM [sys].[external_libraries] WITH (NOLOCK);

SELECT @FileStream=COUNT_BIG(*)
FROM [sys].[columns] [c] WITH (NOLOCK)
JOIN [sys].[objects] [o] WITH (NOLOCK) ON [o].[object_id]=[c].[object_id]
WHERE [o].[is_ms_shipped]=0 AND [c].[is_filestream]=1;
SELECT @FileStream=@FileStream+COUNT_BIG(*)
FROM [sys].[tables] WITH (NOLOCK)
WHERE [is_ms_shipped]=0 AND [is_filetable]=1;

SELECT @Graph=COUNT_BIG(*)
FROM [sys].[tables] WITH (NOLOCK)
WHERE [is_ms_shipped]=0 AND ([is_node]=1 OR [is_edge]=1);

SELECT @Spatial=COUNT_BIG(*)
FROM [sys].[columns] [c] WITH (NOLOCK)
JOIN [sys].[objects] [o] WITH (NOLOCK) ON [o].[object_id]=[c].[object_id]
JOIN [sys].[types] [t] WITH (NOLOCK) ON [t].[user_type_id]=[c].[user_type_id]
WHERE [o].[is_ms_shipped]=0 AND [o].[type] IN (''U'',''V'') AND [t].[name] IN (N''geometry'',N''geography'');

SELECT @Xml=COUNT_BIG(*)
FROM [sys].[columns] [c] WITH (NOLOCK)
JOIN [sys].[objects] [o] WITH (NOLOCK) ON [o].[object_id]=[c].[object_id]
JOIN [sys].[types] [t] WITH (NOLOCK) ON [t].[user_type_id]=[c].[user_type_id]
WHERE [o].[is_ms_shipped]=0 AND [o].[type] IN (''U'',''V'') AND [t].[name]=N''xml'';
SELECT @Xml=@Xml+COUNT_BIG(*) FROM [sys].[xml_indexes] WITH (NOLOCK);

SELECT @NativeJson=COUNT_BIG(*)
FROM [sys].[columns] [c] WITH (NOLOCK)
JOIN [sys].[objects] [o] WITH (NOLOCK) ON [o].[object_id]=[c].[object_id]
JOIN [sys].[types] [t] WITH (NOLOCK) ON [t].[user_type_id]=[c].[user_type_id]
WHERE [o].[is_ms_shipped]=0 AND [o].[type] IN (''U'',''V'')
  AND [t].[name]=N''json'' AND [t].[is_user_defined]=0;

SELECT @Vector=COUNT_BIG(*)
FROM [sys].[columns] [c] WITH (NOLOCK)
JOIN [sys].[objects] [o] WITH (NOLOCK) ON [o].[object_id]=[c].[object_id]
JOIN [sys].[types] [t] WITH (NOLOCK) ON [t].[user_type_id]=[c].[user_type_id]
WHERE [o].[is_ms_shipped]=0 AND [o].[type] IN (''U'',''V'')
  AND [t].[name]=N''vector'' AND [t].[is_user_defined]=0;

SELECT @UserTypes=COUNT_BIG(*)
FROM [sys].[types] WITH (NOLOCK)
WHERE [is_user_defined]=1;

INSERT [#SpecialFeatureInventory_FeatureInventory]
([DatabaseName],[FeatureCode],[FeatureFamily],[DetectionStatus],[DetectedItemCount],[ConfigurationState],[SourceObjects],[RecommendedModule],[RecommendedModuleStatus],[EvidenceLimit])
VALUES
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''IN_MEMORY_OLTP'',N''In-Memory OLTP'',CASE WHEN @MemoryOptimized>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@MemoryOptimized,NULL,N''sys.tables|sys.filegroups'',N''USP_InMemoryOltpAnalysis'',''IMPLEMENTED'',N''Gezählt werden sichtbare memory-optimized Tabellen und XTP-Dateigruppen; Zustand und Speicherverbrauch sind erst im getrennten Deep-Dive-Modul bewertet.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''TEMPORAL'',N''Temporal Tables'',CASE WHEN @Temporal>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@Temporal,NULL,N''sys.tables'',N''USP_TemporalAnalysis'',''IMPLEMENTED'',N''Gezählt werden sichtbare systemversionierte Current-Tabellen; Zuordnung, Retention, approximative Kapazität und Indexbaseline liegen im getrennten Deep-Dive-Modul, nicht jedoch ein Nachweis der Zeilenkonsistenz.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''SERVICE_BROKER'',N''Service Broker'',CASE WHEN @Broker>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@Broker,CASE WHEN @BrokerEnabled=1 THEN N''ENABLED'' ELSE N''DISABLED'' END,N''sys.databases|sys.service_queues|sys.services'',N''USP_ServiceBrokerAnalysis'',''IMPLEMENTED'',N''Broker-Aktivierung und sichtbare Objekte werden gezählt; Queue-Schalter, approximative Kapazität, Aktivierungs-DMVs, Transmission und Conversation-Zustände liegen im getrennten Deep-Dive-Modul, Nachrichtenkörper bleiben ausgeschlossen.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''FULL_TEXT'',N''Full-Text'',CASE WHEN @FullText>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@FullText,NULL,N''sys.fulltext_catalogs|sys.fulltext_indexes'',N''USP_FullTextAnalysis'',''IMPLEMENTED'',N''Kataloge und Indizes werden gezählt; isolierte Population-, Batch-, Fragment-, Semantik- und serverweite Laufzeitevidenz liegt im getrennten Deep-Dive-Modul, Inhalte und Crawl-Logs bleiben ausgeschlossen.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''CHANGE_TRACKING'',N''Change Tracking'',CASE WHEN @ChangeTracking>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@ChangeTracking,NULL,N''sys.change_tracking_databases|sys.change_tracking_tables'',N''USP_DataCaptureDeepAnalysis'',''IMPLEMENTED'',N''Datenbank- und Tabellenmetadaten werden gezählt; das Deep-Dive-Modul bewertet MinValidVersion nur gegen einen explizit gelieferten Consumer-Wasserstand.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''CDC'',N''Change Data Capture'',CASE WHEN @Cdc>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@Cdc,CASE WHEN @CdcEnabled=1 THEN N''ENABLED'' ELSE N''DISABLED'' END,N''sys.databases|sys.tables'',N''USP_DataCaptureDeepAnalysis'',''IMPLEMENTED'',N''CDC-Aktivierung und sichtbare erfasste Tabellen werden gezählt; isolierte Scan-, Fehler-, Job- und Cleanup-Evidenz liegt im Deep-Dive-Modul.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''ENCRYPTION'',N''Encryption'',CASE WHEN @Encryption>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@Encryption,CASE WHEN @Encrypted=1 THEN N''DATABASE_ENCRYPTED'' ELSE N''DATABASE_NOT_ENCRYPTED'' END,N''sys.databases|sys.columns|sys.column_master_keys|sys.column_encryption_keys'',N''USP_EncryptionAnalysis'',''IMPLEMENTED'',N''TDE-Flag, verschlüsselte Spalten und Schlüsselmetadaten werden gezählt; Secrets, Schlüsselmaterial und geschützte Werte werden nicht gelesen.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''CLR'',N''CLR'',CASE WHEN @Clr>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@Clr,NULL,N''sys.assemblies'',N''USP_ClrAnalysis'',''IMPLEMENTED'',N''Nur benutzerdefinierte Assemblyzeilen werden gezählt; Assemblyname, CLR-Identität, Binary und Moduldefinitionen werden nicht ausgegeben.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''EXTERNAL_TABLES'',N''External Tables und Data Sources'',CASE WHEN @ExternalTables>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@ExternalTables,NULL,N''sys.external_tables|sys.external_data_sources'',NULL,''NOT_PLANNED'',N''Objektzahlen werden aggregiert; Locations, Connection Options, Credentials und Remote-Namen werden nicht gelesen.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''EXTERNAL_RUNTIME'',N''External Languages und Libraries'',CASE WHEN @ExternalRuntime>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@ExternalRuntime,NULL,N''sys.external_languages|sys.external_libraries'',N''USP_ExternalRuntimeAnalysis'',''IMPLEMENTED'',N''Nur aggregierte Katalogzeilen; Namen, Dateien, Pfade, Besitzer und Libraryinhalte werden nicht gelesen.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''EXTERNAL_SCRIPTS'',N''External Scripts Configuration'',CASE WHEN @pExternalScriptsConfigured=1 THEN ''CONFIGURED_ONLY'' WHEN @pExternalScriptsConfigured=0 THEN ''NOT_DETECTED_VISIBLE_SCOPE'' ELSE ''SOURCE_UNAVAILABLE'' END,NULL,CASE WHEN @pExternalScriptsConfigured=1 THEN N''ENABLED'' WHEN @pExternalScriptsConfigured=0 THEN N''DISABLED'' ELSE N''UNKNOWN'' END,N''sys.configurations'',N''USP_ExternalRuntimeAnalysis'',''IMPLEMENTED'',N''Die Serverkonfiguration beweist keine tatsächliche Skriptausführung; Moduldefinitionen und Laufzeithistorie werden nicht durchsucht.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''FILESTREAM_FILETABLE'',N''FILESTREAM und FileTable'',CASE WHEN @FileStream>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@FileStream,NULL,N''sys.columns|sys.tables'',NULL,''NOT_PLANNED'',N''Sichtbare FILESTREAM-Spalten und FileTables werden gezählt; Dateipfade und Inhalte werden nicht gelesen.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''GRAPH'',N''Graph'',CASE WHEN @Graph>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@Graph,NULL,N''sys.tables'',NULL,''NOT_PLANNED'',N''Sichtbare Node- und Edge-Tabellen werden gezählt; Daten und Graphqualität sind nicht bewertet.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''SPATIAL'',N''Spatial'',CASE WHEN @Spatial>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@Spatial,NULL,N''sys.columns|sys.types'',NULL,''NOT_PLANNED'',N''Sichtbare geometry-/geography-Spalten werden gezählt; räumliche Daten und Indizes sind nicht bewertet.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''XML'',N''XML'',CASE WHEN @Xml>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@Xml,NULL,N''sys.columns|sys.types|sys.xml_indexes'',NULL,''NOT_PLANNED'',N''Sichtbare XML-Spalten und XML-Indizes werden gezählt; XML-Inhalte und Schema-Definitionen werden nicht gelesen.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''JSON_NATIVE'',N''Native JSON'',CASE WHEN @pMajor IS NULL THEN ''SOURCE_UNAVAILABLE'' WHEN @pMajor<17 THEN ''UNAVAILABLE_VERSION'' WHEN @NativeJson>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@NativeJson,NULL,N''sys.columns|sys.types'',N''USP_ObjectInventory'',''IMPLEMENTED'',N''Erkannt wird nur der native JSON-Systemtyp ab SQL Server 2025; JSON in Zeichenketten oder Moduldefinitionen ist katalogseitig nicht zuverlässig inventarisierbar. Sichtbare JSON-Indizes und SQL/JSON-Pfade werden im ObjectInventory getrennt inventarisiert.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''VECTOR'',N''Vector'',CASE WHEN @pMajor IS NULL THEN ''SOURCE_UNAVAILABLE'' WHEN @pMajor<17 THEN ''UNAVAILABLE_VERSION'' WHEN @Vector>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@Vector,NULL,N''sys.columns|sys.types'',N''USP_VectorIndexAnalysis'',''IMPLEMENTED'',N''Erkannt werden sichtbare Spalten des nativen Vector-Systemtyps; Inhalte und Indexgesundheit sind nicht bewertet. Für sichtbare Vector-Indizes steht die capability-adaptive Laufzeitanalyse bereit.''),
((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),''USER_DEFINED_TYPES'',N''User-defined Types'',CASE WHEN @UserTypes>0 THEN ''DETECTED'' ELSE ''NOT_DETECTED_VISIBLE_SCOPE'' END,@UserTypes,NULL,N''sys.types'',NULL,''NOT_PLANNED'',N''Benutzerdefinierte Typzeilen werden aggregiert; Typnamen, Definitionen, Besitzer und Assemblydetails werden nicht ausgegeben.'');';

                EXEC [sys].[sp_executesql]
                      @Sql
                    , N'@pMajor int,@pExternalScriptsConfigured bit'
                    , @pMajor=@Major
                    , @pExternalScriptsConfigured=@ExternalScriptsConfigured;

                UPDATE [#SpecialFeatureInventory_DatabaseStatus]
                SET [FeatureRows]=(SELECT COUNT_BIG(*) FROM [#SpecialFeatureInventory_FeatureInventory] [f] WHERE [f].[DatabaseName]=@DbName),
                    [DetectedFeatureRows]=(SELECT COUNT_BIG(*) FROM [#SpecialFeatureInventory_FeatureInventory] [f]
                                           WHERE [f].[DatabaseName]=@DbName
                                             AND [f].[DetectionStatus] IN ('DETECTED','CONFIGURED_ONLY'))
                WHERE [DatabaseName]=@DbName;
            END TRY
            BEGIN CATCH
                UPDATE [#SpecialFeatureInventory_DatabaseStatus]
                SET [StatusCode]=CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                                      WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                                      WHEN ERROR_NUMBER() IN (207,208) THEN 'UNAVAILABLE_OBJECT'
                                      ELSE 'ERROR_HANDLED' END,
                    [IsPartial]=1,[ErrorNumber]=ERROR_NUMBER(),[ErrorMessage]=ERROR_MESSAGE(),
                    [Detail]=N'Featureinventur für diese Datenbank fehlgeschlagen; andere Datenbanken bleiben erhalten.'
                WHERE [DatabaseName]=@DbName;
            END CATCH;

            FETCH NEXT FROM [DatabaseCursor] INTO @DbName;
        END;
        CLOSE [DatabaseCursor];
        DEALLOCATE [DatabaseCursor];
    END;

    IF EXISTS(SELECT 1 FROM [#SpecialFeatureInventory_DatabaseStatus] WHERE [StatusCode]<>'AVAILABLE')
    BEGIN
        SET @IsPartial=1;
        IF EXISTS(SELECT 1 FROM [#SpecialFeatureInventory_FeatureInventory])
            SET @StatusCode='AVAILABLE_LIMITED';
        ELSE
            SELECT TOP (1) @StatusCode=[StatusCode],@ErrorNumber=[ErrorNumber],@ErrorMessage=[ErrorMessage]
            FROM [#SpecialFeatureInventory_DatabaseStatus]
            WHERE [StatusCode]<>'AVAILABLE'
            ORDER BY [DatabaseName];
    END;

    IF @ExternalScriptsConfigurationAvailable=0 AND EXISTS(SELECT 1 FROM [#SpecialFeatureInventory_FeatureInventory])
    BEGIN
        SET @IsPartial=1;
        IF @StatusCode='AVAILABLE' SET @StatusCode='AVAILABLE_LIMITED';
        IF @ErrorMessage IS NULL
            SET @ErrorMessage=N'Die Serverkonfiguration für External Scripts war nicht lesbar; übrige Featurezeilen bleiben erhalten.';
    END;

    IF NOT EXISTS(SELECT 1 FROM [#SpecialFeatureInventory_DatabaseStatus]) AND @StatusCode<>'AVAILABLE'
        INSERT [#SpecialFeatureInventory_DatabaseStatus]
        VALUES(NULL,@StatusCode,1,0,0,@ErrorNumber,@ErrorMessage,N'Keine Featureinventur ausgeführt.');

    SELECT @StatusCodeOut=@StatusCode,@IsPartialOut=@IsPartial,
           @ErrorNumberOut=@ErrorNumber,@ErrorMessageOut=@ErrorMessage;

    IF @PrintMeldungen=1 AND @StatusCode NOT IN ('AVAILABLE','NOT_APPLICABLE')
    BEGIN
        SET @PrintMessage=FORMATMESSAGE(N'WARNUNG USP_SpecialFeatureInventory %s: %s',
                         @StatusCode,COALESCE(@ErrorMessage,N'Teilergebnis oder Evidenzlücke.'));
        RAISERROR(N'%s',10,1,@PrintMessage) WITH NOWAIT;
    END;

    SET @LockTimeoutSql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(20),@OriginalLockTimeout)+N';';
    EXEC [sys].[sp_executesql] @LockTimeoutSql;

    IF @JsonErzeugen=1
    BEGIN
        DECLARE @MetaJson nvarchar(max)=
            (SELECT N'SpecialFeatureInventory' [resultName],1 [schemaVersion],@Now [generatedAtUtc],
                    @StatusCode [statusCode],@IsPartial [isPartial],@Major [productMajorVersion],
                    @NurErkannteFeatures [detectedOnly],
                    (SELECT COUNT_BIG(*) FROM [#SpecialFeatureInventory_FeatureInventory]) [featureRowCount],
                    (SELECT COUNT_BIG(*) FROM [#SpecialFeatureInventory_FeatureInventory]
                     WHERE [DetectionStatus] IN ('DETECTED','CONFIGURED_ONLY')) [detectedFeatureRowCount]
             FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @DatabaseJson nvarchar(max)=
            (SELECT * FROM [#SpecialFeatureInventory_DatabaseStatus] ORDER BY [DatabaseName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @FeatureJson nvarchar(max)=
            (SELECT TOP (@Limit) *
             FROM [#SpecialFeatureInventory_FeatureInventory]
             WHERE @NurErkannteFeatures=0 OR [DetectionStatus] IN ('DETECTED','CONFIGURED_ONLY')
             ORDER BY [DatabaseName],[FeatureCode]
             FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@MetaJson,N'{}'),
                         N',"databaseStatus":',COALESCE(@DatabaseJson,N'[]'),
                         N',"features":',COALESCE(@FeatureJson,N'[]'),N'}');
    END;

    IF @OutputMode='RAW'
    BEGIN
        SELECT N'USP_SpecialFeatureInventory' [ModuleName],@Now [CollectionTimeUtc],
               @StatusCode [StatusCode],@IsPartial [IsPartial],@Major [ProductMajorVersion],
               (SELECT COUNT_BIG(*) FROM [#SpecialFeatureInventory_FeatureInventory]) [FeatureRowCount],
               (SELECT COUNT_BIG(*) FROM [#SpecialFeatureInventory_FeatureInventory]
                WHERE [DetectionStatus] IN ('DETECTED','CONFIGURED_ONLY')) [DetectedFeatureRowCount],
               @ErrorNumber [ErrorNumber],@ErrorMessage [ErrorMessage],
               N'Nutzungsinventar sichtbarer Metadaten; kein Gesundheitsurteil.' [Detail];
        SELECT * FROM [#SpecialFeatureInventory_DatabaseStatus] ORDER BY [DatabaseName];
        SELECT TOP (@Limit) *
        FROM [#SpecialFeatureInventory_FeatureInventory]
        WHERE @NurErkannteFeatures=0 OR [DetectionStatus] IN ('DETECTED','CONFIGURED_ONLY')
        ORDER BY [DatabaseName],[FeatureCode];
    END
    ELSE IF @OutputMode='CONSOLE'
    BEGIN
        SELECT N'Spezialfeature-Inventur' [Ergebnis],@Now [Stand_UTC],@StatusCode [Status],
               @IsPartial [Teilergebnis],@Major [Major_Version],
               (SELECT COUNT_BIG(*) FROM [#SpecialFeatureInventory_FeatureInventory]
                WHERE [DetectionStatus] IN ('DETECTED','CONFIGURED_ONLY')) [Erkannte_Featurezeilen],
               @ErrorMessage [Hinweis];
        SELECT N'Datenbankstatus Spezialfeature-Inventur' [Ergebnis],
               [DatabaseName] [Datenbank],[StatusCode] [Status],[FeatureRows] [Featurezeilen],
               [DetectedFeatureRows] [Erkannt],[IsPartial] [Teilweise],[Detail] [Hinweis]
        FROM [#SpecialFeatureInventory_DatabaseStatus]
        ORDER BY [DatabaseName];
        SELECT TOP (@Limit) N'Spezialfeature' [Ergebnis],
               [DatabaseName] [Datenbank],[FeatureCode] [Featurecode],[FeatureFamily] [Featurefamilie],
               [DetectionStatus] [Erkennungsstatus],[DetectedItemCount] [Erkannte_Elemente],
               [ConfigurationState] [Konfiguration],[RecommendedModule] [Empfohlenes_Modul],
               [RecommendedModuleStatus] [Modulstatus],[EvidenceLimit] [Aussagegrenze]
        FROM [#SpecialFeatureInventory_FeatureInventory]
        WHERE @NurErkannteFeatures=0 OR [DetectionStatus] IN ('DETECTED','CONFIGURED_ONLY')
        ORDER BY [DatabaseName],[FeatureCode];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#SpecialFeatureInventory_FeatureInventory'
            , @ResultLabel=N'SpecialFeatureInventory'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#SpecialFeatureInventory_FeatureInventory'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
