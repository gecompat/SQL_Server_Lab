USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ServerFeatureCapabilities
Version      : 3.2.0
Stand        : 2026-07-23
Typ          : Stored Procedure
Zweck        : Erkennt zusätzliche Diagnosefunktionen versionsadaptiv für eine
               explizite Datenbankliste oder alle zulässigen Datenbanken.
SQL-Version  : SQL Server 2019 oder neuer.
Parameter    : @DatabaseNames, @DatabaseNamePattern,
               @SystemdatenbankenEinbeziehen,
               @MitSpezialindizes, @MitQueryStoreReplicas,
               @MitPlattformdetails, @MaxZeilen, @ResultSetArt,
               @JsonErzeugen, @Json OUTPUT, @PrintMeldungen, @Hilfe.
Semantik     : bracket-aware Pipe-Liste; NULL/N''=alle. Pattern ist
               separat und mit exakter Liste gegenseitig exklusiv.
Ausgabe      : RAW/CONSOLE/NONE sowie JSON mit benannten Arrays.
Locking      : Systemkataloge READUNCOMMITTED/NOLOCK; kein OBJECT_ID-Aufruf für
               versionsabhängige Objekterkennung. Der vorherige LOCK_TIMEOUT
               wird wiederhergestellt.
Änderungen   : 3.2.0 - SQL25-002: JSON-Indizes mit Array-Option und
                         Pfadanzahl capability-adaptiv inventarisiert.
               3.1.0 - External-Runtime- und SQL-CLR-Quellen ergänzt.
               3.0.0 - @AlleDatenbanken entfernt; zentraler Datenbankvertrag,
                         Ausgabevertrag und katalogbasierte Featureerkennung.
               2.1.0 - Vorheriger Stand.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_ServerFeatureCapabilities]
      @DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MitSpezialindizes                bit            = 1
    , @MitQueryStoreReplicas            bit            = 1
    , @MitPlattformdetails              bit            = 1
    , @MaxZeilen                        int            = 5000
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json = NULL;
    DECLARE @OriginalLockTimeout int=@@LOCK_TIMEOUT;
    DECLARE @LockTimeoutSql nvarchar(64);

    DECLARE @ResultSetArtNormalisiert varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'capabilities',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @EffectiveMaxZeilen bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0 THEN CONVERT(bigint,9223372036854775807) WHEN @MaxZeilen > 0 THEN CONVERT(bigint,@MaxZeilen) ELSE CONVERT(bigint,0) END;
    DECLARE @MonitorPrintMessage nvarchar(2048);

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_ServerFeatureCapabilities';
        PRINT N'@DatabaseNames=N''[Db1]|[Db2]''; NULL=alle; N'''' bedeutet keine Einschränkung.';
        PRINT N'@DatabaseNamePattern unterstützt like:, regex:, regexi: und ist exklusiv zu @DatabaseNames.';
        PRINT N'Die Datenbankauswahl wird nicht vorab begrenzt; @MaxZeilen begrenzt jedes fachliche Resultset global.';
        PRINT N'@MitSpezialindizes=1 inventarisiert capability-adaptiv Vector- und JSON-Indizes; JSON-Dokumentwerte und SQL/JSON-Pfadwerte werden hier nicht ausgegeben.';
        PRINT N'@ResultSetArt=CONSOLE (Default)|RAW|TABLE|NONE (case-insensitiv); @JsonErzeugen=1 erzeugt @Json OUTPUT.';
        RETURN;
    END;

    SET @LockTimeoutSql=N'SET LOCK_TIMEOUT 0;';
    EXEC [sys].[sp_executesql] @LockTimeoutSql;

    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();
    DECLARE @Major int = TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion'));
    DECLARE @Version nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY(N'ProductVersion'));
    DECLARE @Edition nvarchar(256) = CONVERT(nvarchar(256), SERVERPROPERTY(N'Edition'));
    DECLARE @Platform nvarchar(60) = NULL;
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @CrossDatabaseRequested bit = 0;
    DECLARE @Db sysname;
    DECLARE @Sql nvarchar(max);
    DECLARE @JsonProbeSql nvarchar(max);
    DECLARE @HasJsonIndexes bit,@HasJsonIndexPaths bit;
    DECLARE @JsonIndexesSchemaValid bit,@JsonIndexPathsSchemaValid bit;
    DECLARE @JsonIndexAvailability varchar(40),@JsonIndexCount bigint;

    BEGIN TRY
        SELECT TOP (1) @Platform = [host_platform]
        FROM [sys].[dm_os_host_info] WITH (NOLOCK);
    END TRY
    BEGIN CATCH
        SET @Platform = N'UNKNOWN';
    END CATCH;

    CREATE TABLE [#ServerFeatureCapabilities_DatabaseCandidates]
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
    CREATE TABLE [#ServerFeatureCapabilities_DatabaseCandidateWarnings]([RequestedName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL,[StatusCode] varchar(40) NOT NULL,[ErrorMessage] nvarchar(2048) NOT NULL);
    CREATE TABLE [#ServerFeatureCapabilities_Capabilities]
    (
          [ScopeName] nvarchar(128) NOT NULL
        , [FeatureName] nvarchar(128) NOT NULL
        , [AvailabilityStatus] varchar(40) NOT NULL
        , [LogicPath] nvarchar(256) NULL
        , [MinimumKnownMajorVersion] int NULL
        , [SourceObject] nvarchar(512) NULL
        , [Detail] nvarchar(2000) NULL
        , [RequiredPermission] nvarchar(512) NULL
    );
    CREATE TABLE [#ServerFeatureCapabilities_DatabaseFeatures]
    (
          [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [CompatibilityLevel] tinyint NULL
        , [StateDesc] nvarchar(60) NULL
        , [FeatureName] nvarchar(128) NOT NULL
        , [AvailabilityStatus] varchar(40) NOT NULL
        , [FeatureValue] nvarchar(4000) NULL
        , [LogicPath] nvarchar(256) NULL
        , [Detail] nvarchar(2000) NULL
    );
    CREATE TABLE [#ServerFeatureCapabilities_SpecialIndexes]
    (
          [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [SchemaName] sysname NULL
        , [ObjectName] sysname NULL
        , [IndexName] sysname NULL
        , [IndexFamily] nvarchar(60) NULL
        , [IndexDetails] nvarchar(2000) NULL
        , [AvailabilityStatus] varchar(40) NOT NULL
    );
    CREATE TABLE [#ServerFeatureCapabilities_Errors]
    (
          [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [ModuleName] sysname NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    IF @MaxZeilen < 0 OR @ResultSetArtNormalisiert NOT IN ('RAW','CONSOLE','NONE')
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'Ungültige Mengen- oder Ausgabeparameter.';
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        EXEC [monitor].[USP_PrepareDatabaseCandidates]
              @DatabaseNames = @DatabaseNames
            , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
            , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

            , @AnalysisClass = 'OBJECT_ANALYSIS_CURRENT'
            , @StatusCode = @StatusCode OUTPUT
            , @ErrorMessage = @ErrorMessage OUTPUT
            , @CrossDatabaseRequested = @CrossDatabaseRequested OUTPUT,@CandidateTable=N'#ServerFeatureCapabilities_DatabaseCandidates',@WarningTable=N'#ServerFeatureCapabilities_DatabaseCandidateWarnings';
    END;

    INSERT [#ServerFeatureCapabilities_Capabilities]
    VALUES
      (N'SERVER',N'PERFORMANCE_STATE_PERMISSION','AVAILABLE',CASE WHEN @Major >= 16 THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END,15,NULL,N'Berechtigungsbezeichnung wird versionsabhängig ausgewiesen.',NULL),
      (N'SERVER',N'ZSTD_BACKUP_COMPRESSION',CASE WHEN @Major >= 17 THEN 'AVAILABLE' ELSE 'UNAVAILABLE_VERSION' END,CASE WHEN @Major >= 17 THEN N'Algorithmus 3/ZSTD kann ausgewertet werden.' ELSE N'Vor SQL Server 2025 nicht verfügbar.' END,17,N'msdb backup metadata',CASE WHEN @Major >= 17 THEN N'ZSTD wird unterstützt.' ELSE N'ZSTD-spezifische Information ist auf dieser Version nicht möglich.' END,N'msdb read permissions'),
      (N'SERVER',N'RESOURCE_GOVERNOR_STANDARD_EDITION',CASE WHEN @Major >= 17 THEN 'AVAILABLE' ELSE 'UNAVAILABLE_VERSION' END,N'Edition-/Versionsprüfung',17,N'sys.resource_governor_configuration',CASE WHEN @Major >= 17 THEN N'Resource Governor kann auch in Standard Edition verfügbar sein.' ELSE N'Ältere Editionsgrenzen gelten; die reale Katalogverfügbarkeit wird separat geprüft.' END,N'VIEW SERVER STATE/PERFORMANCE STATE'),
      (N'SERVER',N'EXTERNAL_LANGUAGE_CATALOG',CASE WHEN @Major >= 15 THEN 'AVAILABLE' ELSE 'UNAVAILABLE_VERSION' END,N'Datenbankkataloge werden je Ziel isoliert gelesen.',15,N'sys.external_languages|sys.external_language_files|sys.external_libraries|sys.external_library_files',N'Verfügbarkeit bedeutet Katalogsupport; Registrierung beweist keine Runtime-Startfähigkeit.',N'Metadata visibility; optional CATALOG_DEEP'),
      (N'SERVER',N'EXTERNAL_SCRIPT_REQUESTS',CASE WHEN @Major >= 15 THEN 'AVAILABLE' ELSE 'UNAVAILABLE_VERSION' END,N'USP_ExternalRuntimeAnalysis isoliert den Zugriff.',15,N'sys.dm_external_script_requests|sys.dm_exec_requests',N'Nur aktuell aktive Requests; keine Script- oder Batchtexte.',CASE WHEN @Major >= 16 THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END),
      (N'SERVER',N'EXTERNAL_RESOURCE_POOLS',CASE WHEN @Major >= 15 THEN 'AVAILABLE' ELSE 'UNAVAILABLE_VERSION' END,N'USP_ExternalRuntimeAnalysis isoliert den Zugriff.',15,N'sys.dm_resource_governor_external_resource_pools',N'Kumulative Poolwerte; Linux-Einheiten sind plattformspezifisch zu interpretieren.',CASE WHEN @Major >= 16 THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END),
      (N'SERVER',N'LAUNCHPAD_SERVICE_STATE',CASE WHEN @Major >= 15 THEN 'AVAILABLE' ELSE 'UNAVAILABLE_VERSION' END,N'Nur aggregierter Servicezustand wird ausgegeben.',15,N'sys.dm_server_services',N'Der Servicestatus beweist keine Startfähigkeit einer konkreten Runtime.',CASE WHEN @Major >= 16 THEN N'VIEW SERVER SECURITY STATE' ELSE N'VIEW SERVER STATE' END),
      (N'SERVER',N'CLR_HOST_RUNTIME',CASE WHEN @Major >= 15 THEN 'AVAILABLE' ELSE 'UNAVAILABLE_VERSION' END,N'USP_ClrAnalysis isoliert Host-, AppDomain-, Task- und Ladequellen.',15,N'sys.dm_clr_properties|sys.dm_clr_appdomains|sys.dm_clr_loaded_assemblies|sys.dm_clr_tasks',N'Host- und Live-DMVs bilden keine vollständige CLR-Aufrufhistorie.',CASE WHEN @Major >= 16 THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END),
      (N'SERVER',N'CLR_TRUSTED_ASSEMBLIES',CASE WHEN @Major >= 15 THEN 'AVAILABLE' ELSE 'UNAVAILABLE_VERSION' END,N'Nur bei expliziter Berechtigungsanalyse wird die Zeilenanzahl gelesen.',15,N'sys.trusted_assemblies',N'Hashes und Beschreibungen bleiben ausgeschlossen; deshalb entsteht kein Assembly-Trust-Nachweis.',N'VIEW SERVER STATE beziehungsweise Metadatensichtbarkeit; CATALOG_DEEP');

    IF @MitPlattformdetails = 1
    BEGIN
        INSERT [#ServerFeatureCapabilities_Capabilities]
        SELECT
              N'SERVER'
            , [v].[FeatureName]
            , CASE WHEN @Platform <> N'Linux' THEN 'UNAVAILABLE_PLATFORM'
                   WHEN EXISTS(SELECT 1 FROM [master].[sys].[all_objects] AS [o] WITH (NOLOCK) JOIN [master].[sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id] WHERE [o].[name] = [v].[ObjectName] AND [s].[name]=N'sys') THEN 'AVAILABLE'
                   ELSE 'UNAVAILABLE_VERSION' END
            , CASE WHEN @Platform <> N'Linux' THEN N'Fallback auf allgemeine OS-/SQL-Prozess-DMVs.'
                   WHEN EXISTS(SELECT 1 FROM [master].[sys].[all_objects] AS [o] WITH (NOLOCK) JOIN [master].[sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id] WHERE [o].[name] = [v].[ObjectName] AND [s].[name]=N'sys') THEN N'Native Linux-Host-DMV.'
                   ELSE N'Fallback auf allgemeine OS-/SQL-Prozess-DMVs.' END
            , 17
            , N'sys.' + [v].[ObjectName]
            , CASE WHEN @Platform <> N'Linux' THEN N'Linux-spezifische Quelle ist auf dieser Plattform nicht anwendbar.'
                   WHEN EXISTS(SELECT 1 FROM [master].[sys].[all_objects] AS [o] WITH (NOLOCK) JOIN [master].[sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id] WHERE [o].[name] = [v].[ObjectName] AND [s].[name]=N'sys') THEN N'Quelle verfügbar.'
                   ELSE N'Diese Hostinformation ist auf Build/CU nicht verfügbar.' END
            , N'VIEW SERVER STATE/PERFORMANCE STATE'
        FROM (VALUES
             (N'LINUX_CPU_HOST_STATS',N'dm_os_linux_cpu_stats'),
             (N'LINUX_DISK_HOST_STATS',N'dm_os_linux_disk_stats'),
             (N'LINUX_NETWORK_HOST_STATS',N'dm_os_linux_net_stats'),
             (N'LINUX_VM_HOST_STATS',N'dm_os_linux_vm_stats')) AS [v]([FeatureName],[ObjectName]);
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        DECLARE [DatabaseCursor] CURSOR LOCAL FAST_FORWARD FOR
        SELECT [DatabaseName]
        FROM [#ServerFeatureCapabilities_DatabaseCandidates]
        ORDER BY COALESCE([RequestedOrdinal],[DatabaseId]),[DatabaseId];
        OPEN [DatabaseCursor];
        FETCH NEXT FROM [DatabaseCursor] INTO @Db;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @Sql = N'USE ' + QUOTENAME(@Db) + N';
DECLARE @HasQueryStoreReplicas bit = CONVERT(bit,CASE WHEN EXISTS
(
    SELECT 1 FROM [sys].[views] AS [v] WITH (NOLOCK)
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[v].[schema_id]
    WHERE [s].[name]=N''sys'' AND [v].[name]=N''query_store_replicas''
) THEN 1 ELSE 0 END);

' + CASE WHEN @Major >= 17 THEN N'
INSERT [#ServerFeatureCapabilities_DatabaseFeatures]
SELECT [d].[name],[d].[compatibility_level],[d].[state_desc],N''OPTIMIZED_LOCKING'',
       ''AVAILABLE'',CONVERT(nvarchar(100),[d].[is_optimized_locking_on]),
       N''sys.databases.is_optimized_locking_on'',N''Zusammen mit ADR und RCSI interpretieren.''
FROM [sys].[databases] AS [d] WITH (NOLOCK) WHERE [d].[database_id]=DB_ID();
' ELSE N'
INSERT [#ServerFeatureCapabilities_DatabaseFeatures]
SELECT [d].[name],[d].[compatibility_level],[d].[state_desc],N''OPTIMIZED_LOCKING'',
       ''UNAVAILABLE_VERSION'',NULL,N''Fallback: allgemeine Locking-/Blocking-DMVs.'',
       N''sys.databases.is_optimized_locking_on ist vor SQL Server 2025 nicht verfügbar.''
FROM [sys].[databases] AS [d] WITH (NOLOCK) WHERE [d].[database_id]=DB_ID();
' END + N'

INSERT [#ServerFeatureCapabilities_DatabaseFeatures]
SELECT (SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),[d].[compatibility_level],[d].[state_desc],N''QUERY_STORE_READABLE_SECONDARY'',
       CASE WHEN @HasQueryStoreReplicas=1 THEN ''AVAILABLE'' ELSE ''UNAVAILABLE_VERSION'' END,
       CASE WHEN @HasQueryStoreReplicas=1 THEN N''Systemview vorhanden'' END,
       CASE WHEN @HasQueryStoreReplicas=1 THEN N''Replica-Gruppen berücksichtigen.'' ELSE N''Fallback ohne Replica-Dimension.'' END,
       CASE WHEN @HasQueryStoreReplicas=1 THEN N''Quelle verfügbar.'' ELSE N''Replica-spezifische Query-Store-Information nicht verfügbar.'' END
FROM [sys].[databases] AS [d] WITH (NOLOCK) WHERE [d].[database_id]=DB_ID();

IF @IncludeSpecialIndexes=1
BEGIN
    IF EXISTS
    (
        SELECT 1 FROM [sys].[views] AS [v] WITH (NOLOCK)
        INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[v].[schema_id]
        WHERE [s].[name]=N''sys'' AND [v].[name]=N''vector_indexes''
    )
    BEGIN
        EXEC(N''INSERT [#ServerFeatureCapabilities_SpecialIndexes]
        SELECT (SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),[s].[name],[o].[name],[v].[name],N''''VECTOR'''',
               CONCAT(N''''type='''',CONVERT(nvarchar(60),[v].[vector_index_type]),N''''; metric='''',CONVERT(nvarchar(60),[v].[distance_metric]),N''''; disabled='''',CONVERT(nvarchar(10),[v].[is_disabled])),''''AVAILABLE''''
        FROM [sys].[vector_indexes] AS [v] WITH (NOLOCK)
        INNER JOIN [sys].[objects] AS [o] WITH (NOLOCK) ON [o].[object_id]=[v].[object_id]
        INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id];'');
    END
    ELSE
        INSERT [#ServerFeatureCapabilities_DatabaseFeatures]
        SELECT (SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),[d].[compatibility_level],[d].[state_desc],N''VECTOR_INDEX_METADATA'',''UNAVAILABLE_VERSION'',NULL,N''Fallback: allgemeines Indexinventar.'',N''Vector-Index-Metadaten nicht verfügbar.''
        FROM [sys].[databases] AS [d] WITH (NOLOCK) WHERE [d].[database_id]=DB_ID();
END;

IF @IncludeQueryStoreReplicas=1 AND @HasQueryStoreReplicas=1
BEGIN
    EXEC(N''INSERT [#ServerFeatureCapabilities_DatabaseFeatures]
    SELECT (SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),[d].[compatibility_level],[d].[state_desc],N''''QUERY_STORE_REPLICA_GROUP_COUNT'''',''''AVAILABLE'''',CONVERT(nvarchar(100),(SELECT COUNT_BIG(*) FROM [sys].[query_store_replicas] WITH (NOLOCK))),N''''sys.query_store_replicas'''',N''''Replica-Gruppen bei Query-Store-Auswertungen berücksichtigen.''''
    FROM [sys].[databases] AS [d] WITH (NOLOCK) WHERE [d].[database_id]=DB_ID();'');
END;';

                EXEC [sys].[sp_executesql]
                      @Sql
                    , N'@IncludeSpecialIndexes bit,@IncludeQueryStoreReplicas bit'
                    , @IncludeSpecialIndexes = @MitSpezialindizes
                    , @IncludeQueryStoreReplicas = @MitQueryStoreReplicas;

                IF @MitSpezialindizes=1
                BEGIN
                    SELECT
                          @HasJsonIndexes=0
                        , @HasJsonIndexPaths=0
                        , @JsonIndexesSchemaValid=0
                        , @JsonIndexPathsSchemaValid=0
                        , @JsonIndexCount=0
                        , @JsonIndexAvailability=CASE
                              WHEN @Major IS NULL OR @Major<17 THEN 'UNAVAILABLE_VERSION'
                              ELSE 'NOT_COLLECTED' END;

                    IF @Major IS NULL OR @Major<17
                    BEGIN
                        INSERT [#ServerFeatureCapabilities_DatabaseFeatures]
                        (
                              [DatabaseName],[CompatibilityLevel],[StateDesc]
                            , [FeatureName],[AvailabilityStatus],[FeatureValue]
                            , [LogicPath],[Detail]
                        )
                        SELECT
                              [DatabaseName],[CompatibilityLevel],[StateDesc]
                            , N'JSON_INDEX_METADATA','UNAVAILABLE_VERSION',NULL
                            , N'Fallback: allgemeines Indexinventar ohne JSON-spezifische Spalten.'
                            , N'sys.json_indexes und sys.json_index_paths werden vor SQL Server 2025 nicht referenziert.'
                        FROM [#ServerFeatureCapabilities_DatabaseCandidates]
                        WHERE [DatabaseName]=@Db;
                    END
                    ELSE
                    BEGIN
                        BEGIN TRY
                            SET @JsonProbeSql=N'USE '+QUOTENAME(@Db)+N';
SELECT
      @pHasJsonIndexesOut=CONVERT(bit,CASE WHEN EXISTS
      (
          SELECT 1
          FROM [sys].[all_objects] AS [o] WITH (NOLOCK)
          INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
             ON [s].[schema_id]=[o].[schema_id]
          WHERE [s].[name]=N''sys'' AND [o].[name]=N''json_indexes''
      ) THEN 1 ELSE 0 END)
    , @pHasJsonIndexPathsOut=CONVERT(bit,CASE WHEN EXISTS
      (
          SELECT 1
          FROM [sys].[all_objects] AS [o] WITH (NOLOCK)
          INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
             ON [s].[schema_id]=[o].[schema_id]
          WHERE [s].[name]=N''sys'' AND [o].[name]=N''json_index_paths''
      ) THEN 1 ELSE 0 END);

SELECT @pJsonIndexesSchemaValidOut=CONVERT(bit,CASE
    WHEN @pHasJsonIndexesOut=1 AND
         (
             SELECT COUNT(DISTINCT [c].[name])
             FROM [sys].[all_columns] AS [c] WITH (NOLOCK)
             INNER JOIN [sys].[all_objects] AS [o] WITH (NOLOCK)
                ON [o].[object_id]=[c].[object_id]
             INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
                ON [s].[schema_id]=[o].[schema_id]
             WHERE [s].[name]=N''sys'' AND [o].[name]=N''json_indexes''
               AND [c].[name] IN
                   (N''object_id'',N''index_id'',N''name'',N''is_disabled'',N''optimize_for_array_search'')
         )=5 THEN 1 ELSE 0 END);

SELECT @pJsonIndexPathsSchemaValidOut=CONVERT(bit,CASE
    WHEN @pHasJsonIndexPathsOut=1 AND
         (
             SELECT COUNT(DISTINCT [c].[name])
             FROM [sys].[all_columns] AS [c] WITH (NOLOCK)
             INNER JOIN [sys].[all_objects] AS [o] WITH (NOLOCK)
                ON [o].[object_id]=[c].[object_id]
             INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
                ON [s].[schema_id]=[o].[schema_id]
             WHERE [s].[name]=N''sys'' AND [o].[name]=N''json_index_paths''
               AND [c].[name] IN (N''object_id'',N''index_id'',N''path'')
         )=3 THEN 1 ELSE 0 END);';
                            EXEC [sys].[sp_executesql]
                                  @JsonProbeSql
                                , N'@pHasJsonIndexesOut bit OUTPUT,@pHasJsonIndexPathsOut bit OUTPUT,
                                    @pJsonIndexesSchemaValidOut bit OUTPUT,@pJsonIndexPathsSchemaValidOut bit OUTPUT'
                                , @pHasJsonIndexesOut=@HasJsonIndexes OUTPUT
                                , @pHasJsonIndexPathsOut=@HasJsonIndexPaths OUTPUT
                                , @pJsonIndexesSchemaValidOut=@JsonIndexesSchemaValid OUTPUT
                                , @pJsonIndexPathsSchemaValidOut=@JsonIndexPathsSchemaValid OUTPUT;

                            IF @HasJsonIndexes=0
                                SET @JsonIndexAvailability='UNAVAILABLE_FEATURE';
                            ELSE IF @JsonIndexesSchemaValid=0
                                SET @JsonIndexAvailability='UNAVAILABLE_SOURCE_SCHEMA';
                            ELSE
                            BEGIN
                                SET @JsonIndexAvailability=CASE
                                    WHEN @HasJsonIndexPaths=1 AND @JsonIndexPathsSchemaValid=1
                                    THEN 'AVAILABLE'
                                    ELSE 'AVAILABLE_LIMITED' END;

                                SET @Sql=N'USE '+QUOTENAME(@Db)+N';
'+CASE WHEN @HasJsonIndexPaths=1 AND @JsonIndexPathsSchemaValid=1 THEN N'
;WITH [JsonPathAgg] AS
(
    SELECT [p].[object_id],[p].[index_id],COUNT_BIG(*) AS [JsonPathCount]
    FROM [sys].[json_index_paths] AS [p] WITH (NOLOCK)
    GROUP BY [p].[object_id],[p].[index_id]
)
INSERT [#ServerFeatureCapabilities_SpecialIndexes]
SELECT
      @pDatabaseName,[s].[name],[o].[name],[j].[name],N''JSON''
    , CONCAT
      (
            N''array_search='',CONVERT(nvarchar(10),[j].[optimize_for_array_search])
          , N''; path_count='',COALESCE(CONVERT(nvarchar(30),[p].[JsonPathCount]),N''0'')
          , N''; disabled='',CONVERT(nvarchar(10),[j].[is_disabled])
      )
    , N''AVAILABLE''
FROM [sys].[json_indexes] AS [j] WITH (NOLOCK)
INNER JOIN [sys].[objects] AS [o] WITH (NOLOCK)
   ON [o].[object_id]=[j].[object_id]
INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
   ON [s].[schema_id]=[o].[schema_id]
LEFT JOIN [JsonPathAgg] AS [p]
   ON [p].[object_id]=[j].[object_id] AND [p].[index_id]=[j].[index_id];'
                                ELSE N'
INSERT [#ServerFeatureCapabilities_SpecialIndexes]
SELECT
      @pDatabaseName,[s].[name],[o].[name],[j].[name],N''JSON''
    , CONCAT
      (
            N''array_search='',CONVERT(nvarchar(10),[j].[optimize_for_array_search])
          , N''; path_count=UNAVAILABLE''
          , N''; disabled='',CONVERT(nvarchar(10),[j].[is_disabled])
      )
    , N''AVAILABLE_LIMITED''
FROM [sys].[json_indexes] AS [j] WITH (NOLOCK)
INNER JOIN [sys].[objects] AS [o] WITH (NOLOCK)
   ON [o].[object_id]=[j].[object_id]
INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
   ON [s].[schema_id]=[o].[schema_id];' END;

                                EXEC [sys].[sp_executesql]
                                      @Sql
                                    , N'@pDatabaseName sysname'
                                    , @pDatabaseName=@Db;

                                SELECT @JsonIndexCount=COUNT_BIG(*)
                                FROM [#ServerFeatureCapabilities_SpecialIndexes]
                                WHERE [DatabaseName]=@Db AND [IndexFamily]=N'JSON';

                                IF @JsonIndexCount=0 AND @JsonIndexAvailability='AVAILABLE'
                                    SET @JsonIndexAvailability='AVAILABLE_EMPTY_OR_RESTRICTED';
                            END;

                            INSERT [#ServerFeatureCapabilities_DatabaseFeatures]
                            (
                                  [DatabaseName],[CompatibilityLevel],[StateDesc]
                                , [FeatureName],[AvailabilityStatus],[FeatureValue]
                                , [LogicPath],[Detail]
                            )
                            SELECT
                                  [DatabaseName],[CompatibilityLevel],[StateDesc]
                                , N'JSON_INDEX_METADATA',@JsonIndexAvailability
                                , CASE WHEN @JsonIndexAvailability IN
                                           ('AVAILABLE','AVAILABLE_LIMITED','AVAILABLE_EMPTY_OR_RESTRICTED')
                                       THEN CONVERT(nvarchar(100),@JsonIndexCount) END
                                , N'ObjectInventory liefert sichtbare Pfade; diese Capability-Ausgabe enthält nur Pfadanzahl und Indexoptionen.'
                                , CASE
                                      WHEN @JsonIndexAvailability='UNAVAILABLE_FEATURE'
                                      THEN N'Der konkrete SQL-Server-2025-Build stellt sys.json_indexes nicht bereit.'
                                      WHEN @JsonIndexAvailability='UNAVAILABLE_SOURCE_SCHEMA'
                                      THEN N'sys.json_indexes ist vorhanden, aber das benötigte Pflichtschema weicht ab.'
                                      WHEN @JsonIndexAvailability='AVAILABLE_LIMITED'
                                      THEN N'JSON-Indizes sind sichtbar; sys.json_index_paths fehlt oder weicht im Pflichtschema ab.'
                                      WHEN @JsonIndexAvailability='AVAILABLE_EMPTY_OR_RESTRICTED'
                                      THEN N'Keine JSON-Indexzeile ist sichtbar; Metadata Visibility unterscheidet leeren Scope und verborgene Objekte nicht sicher.'
                                      ELSE N'JSON-Indizes und Pfadanzahl sind sichtbar; JSON-Dokumentwerte und Pfadwerte werden hier nicht ausgegeben.'
                                  END
                            FROM [#ServerFeatureCapabilities_DatabaseCandidates]
                            WHERE [DatabaseName]=@Db;
                        END TRY
                        BEGIN CATCH
                            INSERT [#ServerFeatureCapabilities_Errors]
                            VALUES(@Db,N'JsonIndexCapabilities',ERROR_NUMBER(),ERROR_MESSAGE());
                            INSERT [#ServerFeatureCapabilities_DatabaseFeatures]
                            (
                                  [DatabaseName],[CompatibilityLevel],[StateDesc]
                                , [FeatureName],[AvailabilityStatus],[FeatureValue]
                                , [LogicPath],[Detail]
                            )
                            SELECT
                                  [DatabaseName],[CompatibilityLevel],[StateDesc]
                                , N'JSON_INDEX_METADATA'
                                , CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916)
                                       THEN 'DENIED_PERMISSION'
                                       WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                                       ELSE 'ERROR_HANDLED' END
                                , NULL,N'JSON-Index-Quellen sind isoliert; andere Capabilities bleiben erhalten.'
                                , N'Die JSON-Index-Capability- oder Katalogabfrage scheiterte.'
                            FROM [#ServerFeatureCapabilities_DatabaseCandidates]
                            WHERE [DatabaseName]=@Db;
                            SET @IsPartial=1;
                        END CATCH;
                    END;
                END;
            END TRY
            BEGIN CATCH
                INSERT [#ServerFeatureCapabilities_Errors] VALUES(@Db,N'DatabaseCapabilities',ERROR_NUMBER(),ERROR_MESSAGE());
                SET @IsPartial = 1;
            END CATCH;

            FETCH NEXT FROM [DatabaseCursor] INTO @Db;
        END;
        CLOSE [DatabaseCursor];
        DEALLOCATE [DatabaseCursor];
    END;

    INSERT [#ServerFeatureCapabilities_Errors]([DatabaseName],[ModuleName],[ErrorNumber],[ErrorMessage])
    SELECT [RequestedName],N'DatabaseSelection',NULL,[ErrorMessage]
    FROM [#ServerFeatureCapabilities_DatabaseCandidateWarnings];

    IF EXISTS(SELECT 1 FROM [#ServerFeatureCapabilities_Errors])
    BEGIN
        SET @StatusCode = CASE WHEN EXISTS(SELECT 1 FROM [#ServerFeatureCapabilities_DatabaseFeatures]) THEN 'PARTIAL_RESULT' ELSE 'ERROR_HANDLED' END;
        SET @IsPartial = 1;
    END;

    IF @StatusCode <> 'AVAILABLE' AND @PrintMeldungen = 1
    BEGIN
        SET @MonitorPrintMessage=FORMATMESSAGE(N'WARNUNG USP_ServerFeatureCapabilities %s: %s',@StatusCode,COALESCE(@ErrorMessage,N'Teilergebnis.'));
        RAISERROR(N'%s',10,1,@MonitorPrintMessage) WITH NOWAIT;
    END;

    SET @LockTimeoutSql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(20),@OriginalLockTimeout)+N';';
    EXEC [sys].[sp_executesql] @LockTimeoutSql;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @JsonMeta nvarchar(max)=(SELECT N'ServerFeatureCapabilities' [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@StatusCode [statusCode],@IsPartial [isPartial],@Major [productMajorVersion],@Version [productVersion],@Edition [edition],@Platform [hostPlatform],@ErrorMessage [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @JsonCapabilities nvarchar(max)=(SELECT TOP(@EffectiveMaxZeilen) * FROM [#ServerFeatureCapabilities_Capabilities] ORDER BY [ScopeName],[FeatureName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @JsonDatabaseFeatures nvarchar(max)=(SELECT TOP(@EffectiveMaxZeilen) * FROM [#ServerFeatureCapabilities_DatabaseFeatures] ORDER BY [DatabaseName],[FeatureName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @JsonSpecialIndexes nvarchar(max)=(SELECT TOP(@EffectiveMaxZeilen) * FROM [#ServerFeatureCapabilities_SpecialIndexes] ORDER BY [DatabaseName],[SchemaName],[ObjectName],[IndexName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @JsonWarnings nvarchar(max)=(SELECT * FROM [#ServerFeatureCapabilities_Errors] ORDER BY [DatabaseName],[ModuleName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@JsonMeta,N'{}'),N',"capabilities":',COALESCE(@JsonCapabilities,N'[]'),N',"databaseFeatures":',COALESCE(@JsonDatabaseFeatures,N'[]'),N',"specialIndexes":',COALESCE(@JsonSpecialIndexes,N'[]'),N',"warnings":',COALESCE(@JsonWarnings,N'[]'),N'}');
    END;

    IF @ResultSetArtNormalisiert='RAW'
    BEGIN
        SELECT N'monitor.USP_ServerFeatureCapabilities' [ModuleName],@CollectionTimeUtc [CollectionTimeUtc],@StatusCode [StatusCode],@IsPartial [IsPartial],@Major [ProductMajorVersion],@Version [ProductVersion],@Edition [Edition],@Platform [HostPlatform],@ErrorMessage [ErrorMessage];
        SELECT TOP(@EffectiveMaxZeilen) * FROM [#ServerFeatureCapabilities_Capabilities] ORDER BY [ScopeName],[FeatureName];
        SELECT TOP(@EffectiveMaxZeilen) * FROM [#ServerFeatureCapabilities_DatabaseFeatures] ORDER BY [DatabaseName],[FeatureName];
        IF @MitSpezialindizes=1 SELECT TOP(@EffectiveMaxZeilen) * FROM [#ServerFeatureCapabilities_SpecialIndexes] ORDER BY [DatabaseName],[SchemaName],[ObjectName],[IndexName];
        SELECT * FROM [#ServerFeatureCapabilities_Errors] ORDER BY [DatabaseName],[ModuleName];
    END
    ELSE IF @ResultSetArtNormalisiert='CONSOLE'
    BEGIN
        SELECT N'Server-Feature-Capabilities' [Ergebnis],@CollectionTimeUtc [Stand_UTC],@StatusCode [Status],@Major [Major_Version],@Version [Produktversion],@Edition [Edition],@Platform [Plattform],@ErrorMessage [Hinweis];
        SELECT TOP(@EffectiveMaxZeilen) N'Server-Capability' [Ergebnis],[ScopeName] [Scope],[FeatureName] [Feature],[AvailabilityStatus] [Verfügbarkeit],[LogicPath] [Logik/Fallback],[SourceObject] [Quelle],[Detail] [Hinweis],[RequiredPermission] [Erforderliche_Berechtigung] FROM [#ServerFeatureCapabilities_Capabilities] ORDER BY [ScopeName],[FeatureName];
        SELECT TOP(@EffectiveMaxZeilen) N'Datenbank-Capability' [Ergebnis],[DatabaseName] [Datenbank],[CompatibilityLevel] [Compatibility_Level],[FeatureName] [Feature],[AvailabilityStatus] [Verfügbarkeit],[FeatureValue] [Wert],[LogicPath] [Logik/Fallback],[Detail] [Hinweis] FROM [#ServerFeatureCapabilities_DatabaseFeatures] ORDER BY [DatabaseName],[FeatureName];
        IF @MitSpezialindizes=1 SELECT TOP(@EffectiveMaxZeilen) N'Spezialindex' [Ergebnis],[DatabaseName] [Datenbank],[SchemaName] [Schema],[ObjectName] [Objekt],[IndexName] [Index],[IndexFamily] [Indexfamilie],[IndexDetails] [Details],[AvailabilityStatus] [Verfügbarkeit] FROM [#ServerFeatureCapabilities_SpecialIndexes] ORDER BY [DatabaseName],[SchemaName],[ObjectName],[IndexName];
        SELECT N'Capability-Warnung' [Ergebnis],[DatabaseName] [Datenbank],[ModuleName] [Modul],[ErrorNumber] [Fehlernummer],[ErrorMessage] [Fehlermeldung] FROM [#ServerFeatureCapabilities_Errors] ORDER BY [DatabaseName],[ModuleName];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#ServerFeatureCapabilities_Capabilities'
            , @ResultLabel=N'ServerFeatureCapabilities'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#ServerFeatureCapabilities_Capabilities'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
