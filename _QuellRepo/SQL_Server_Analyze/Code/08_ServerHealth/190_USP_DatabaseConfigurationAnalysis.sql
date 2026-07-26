USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_DatabaseConfigurationAnalysis
Version      : 1.0.0
Stand        : 2026-07-21
Zweck        : Inventarisiert sichtbare Datenbankoptionen, Database Scoped
               Configurations und Query-Store-Einstellungen und trennt lokale
               Variation von Abweichungen gegen ein explizites Sollprofil.
Profil       : JSON-Array aus settingScope, settingName und expectedValue.
               Ohne Profil wird ausschließlich lokale Variation ausgewiesen.
Abgrenzung   : Variation oder Profilabweichung ist ein Review-Befund, keine
               universelle Fehlkonfiguration und keine automatische DDL-Anweisung.
Eigenlast    : Serverkatalog einmal; je sichtbarer Datenbank zwei kleine
               Katalogabfragen mit LOCK_TIMEOUT 0 und isoliertem Partialstatus.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_DatabaseConfigurationAnalysis]
      @DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @ProfileJson                    nvarchar(max)  = NULL
    , @MaxZeilen                      int            = 2000
    , @ResultSetArt                   varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max)  = NULL
    , @JsonErzeugen                   bit            = 0
    , @Json                           nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                 bit            = 1
    , @Hilfe                          bit            = 0
    , @StatusCodeOut                  varchar(40)    = NULL OUTPUT
    , @IsPartialOut                   bit            = NULL OUTPUT
    , @ErrorNumberOut                 int            = NULL OUTPUT
    , @ErrorMessageOut                nvarchar(2048) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json=NULL;

    DECLARE @CapturedAtUtc datetime2(3)=SYSUTCDATETIME();
    DECLARE @OutputMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @ConsoleResultRequested bit=CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))))='CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @StatusCode varchar(40)='AVAILABLE';
    DECLARE @IsPartial bit=0;
    DECLARE @ErrorNumber int=NULL;
    DECLARE @ErrorMessage nvarchar(2048)=NULL;
    DECLARE @CrossDatabaseRequested bit=0;
    DECLARE @Limit bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxZeilen) END;

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_DatabaseConfigurationAnalysis';
        PRINT N'Ohne Filter werden alle sichtbaren, online befindlichen Benutzerdatenbanken lokal verglichen.';
        PRINT N'@ProfileJson ist optional: [{"settingScope":"DATABASE|SCOPED|QUERY_STORE","settingName":"...","expectedValue":"..."}].';
        PRINT N'Ohne Profil bedeutet drift ausschließlich lokale Variation; mit Profil werden zusätzlich PROFILE_MISMATCH-Zeilen erzeugt.';
        PRINT N'RCSI, Parameterisierung, Statistik- und andere Optionen bleiben workloadabhängig; kein Befund ändert Konfiguration.';
        PRINT N'@ResultSetArt=CONSOLE|RAW|TABLE|NONE; TABLE-Namen: moduleStatus, settings, drift, profile, sourceStatus, warnings.';
        RETURN;
    END;

    CREATE TABLE [#DatabaseConfigurationAnalysis_ResultTableMap]
    (
          [ResultName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL PRIMARY KEY
        , [TargetTable] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL UNIQUE
    );
    CREATE TABLE [#DatabaseConfigurationAnalysis_DatabaseCandidates]
    (
          [DatabaseId] int NOT NULL PRIMARY KEY
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
    CREATE TABLE [#DatabaseConfigurationAnalysis_CandidateWarnings]
    (
          [RequestedName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );
    CREATE TABLE [#DatabaseConfigurationAnalysis_Profile]
    (
          [ProfileOrdinal] int NOT NULL PRIMARY KEY
        , [SettingScope] varchar(32) NOT NULL
        , [SettingName] nvarchar(128) NOT NULL
        , [ExpectedValue] nvarchar(4000) NOT NULL
    );
    CREATE TABLE [#DatabaseConfigurationAnalysis_Settings]
    (
          [CapturedAtUtc] datetime2(3) NOT NULL
        , [DatabaseId] int NOT NULL
        , [DatabaseName] sysname NOT NULL
        , [SettingScope] varchar(32) NOT NULL
        , [SettingName] nvarchar(128) NOT NULL
        , [ActualValue] nvarchar(4000) NULL
        , [SecondaryValue] nvarchar(4000) NULL
        , [IsDefault] bit NULL
        , [SourceObject] nvarchar(256) NOT NULL
        , [SourceStatus] varchar(40) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE INDEX [IX_DatabaseConfiguration_Settings]
      ON [#DatabaseConfigurationAnalysis_Settings]([SettingScope],[SettingName],[DatabaseId]);
    CREATE TABLE [#DatabaseConfigurationAnalysis_Drift]
    (
          [CapturedAtUtc] datetime2(3) NOT NULL
        , [DriftType] varchar(32) NOT NULL
        , [DatabaseId] int NULL
        , [DatabaseName] sysname NULL
        , [SettingScope] varchar(32) NOT NULL
        , [SettingName] nvarchar(128) NOT NULL
        , [ActualValue] nvarchar(4000) NULL
        , [ReferenceValue] nvarchar(4000) NULL
        , [MatchingDatabaseCount] int NULL
        , [ComparedDatabaseCount] int NOT NULL
        , [FindingCode] varchar(80) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#DatabaseConfigurationAnalysis_SourceStatus]
    (
          [SourceOrdinal] int IDENTITY(1,1) NOT NULL PRIMARY KEY
        , [DatabaseId] int NULL
        , [DatabaseName] sysname NULL
        , [SourceName] sysname NOT NULL
        , [SourceObject] nvarchar(256) NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [ReturnedRowCount] bigint NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#DatabaseConfigurationAnalysis_Warnings]
    (
          [WarningOrdinal] int IDENTITY(1,1) NOT NULL PRIMARY KEY
        , [DatabaseName] sysname NULL
        , [SourceName] sysname NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [Message] nvarchar(2048) NOT NULL
    );
    CREATE TABLE [#DatabaseConfigurationAnalysis_ModuleStatus]
    (
          [ModuleName] sysname NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [CrossDatabaseRequested] bit NOT NULL
        , [DatabaseCount] int NOT NULL
        , [SettingRowCount] bigint NOT NULL
        , [DriftRowCount] bigint NOT NULL
        , [ProfileEntryCount] int NOT NULL
        , [HasMoreSettingRows] bit NOT NULL
        , [HasMoreDriftRows] bit NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    IF @MaxZeilen<0 OR @SystemdatenbankenEinbeziehen IS NULL OR @JsonErzeugen IS NULL OR @PrintMeldungen IS NULL
       OR @OutputMode NOT IN('CONSOLE','RAW','TABLE','NONE')
       OR (@DatabaseNames IS NOT NULL AND @DatabaseNamePattern IS NOT NULL)
       OR (@OutputMode<>'TABLE' AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL)
       OR (@ProfileJson IS NOT NULL AND
           (ISJSON(@ProfileJson)<>1 OR LEFT(LTRIM(@ProfileJson),1)<>N'['))
    BEGIN
        SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,
               @ErrorMessage=N'Ungültiger Filter-, Profil-, Zeilen- oder Ausgabeparameter.';
    END;

    IF @StatusCode='AVAILABLE' AND @ProfileJson IS NOT NULL
    BEGIN
        BEGIN TRY
            INSERT [#DatabaseConfigurationAnalysis_Profile]([ProfileOrdinal],[SettingScope],[SettingName],[ExpectedValue])
            SELECT TRY_CONVERT(int,[j].[key])+1,UPPER(LTRIM(RTRIM([p].[SettingScope]))),
                   LTRIM(RTRIM([p].[SettingName])),[p].[ExpectedValue]
            FROM OPENJSON(@ProfileJson) AS [j]
            CROSS APPLY OPENJSON([j].[value])
            WITH
            (
                  [SettingScope] varchar(32) '$.settingScope'
                , [SettingName] nvarchar(128) '$.settingName'
                , [ExpectedValue] nvarchar(4000) '$.expectedValue'
            ) AS [p];
        END TRY
        BEGIN CATCH
            SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,
                   @ErrorNumber=ERROR_NUMBER(),
                   @ErrorMessage=N'@ProfileJson enthält keinen gültigen Arrayeintrag.';
        END CATCH;

        IF @StatusCode='AVAILABLE' AND
           (NOT EXISTS(SELECT 1 FROM [#DatabaseConfigurationAnalysis_Profile])
           OR EXISTS
              (
                  SELECT 1 FROM [#DatabaseConfigurationAnalysis_Profile]
                  WHERE [SettingScope] NOT IN('DATABASE','SCOPED','QUERY_STORE')
                     OR NULLIF([SettingName],N'') IS NULL OR [ExpectedValue] IS NULL
              )
           OR EXISTS
              (
                  SELECT [SettingScope],[SettingName]
                  FROM [#DatabaseConfigurationAnalysis_Profile]
                  GROUP BY [SettingScope],[SettingName]
                  HAVING COUNT_BIG(*)>1
              ))
            SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,
                   @ErrorMessage=N'@ProfileJson muss ein nicht leeres Array eindeutiger DATABASE-, SCOPED- oder QUERY_STORE-Einträge sein.';
    END;

    IF @StatusCode='AVAILABLE' AND @OutputMode='TABLE'
        EXEC [monitor].[InternalPrepareResultTables]
              @ResultTablesJson=@ResultTablesJson
            , @AllowedResultNames=N'moduleStatus|settings|drift|profile|sourceStatus|warnings'
            , @MappingTable=N'#DatabaseConfigurationAnalysis_ResultTableMap'
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT
            , @ThrowOnError=1;

    IF @StatusCode='AVAILABLE'
        EXEC [monitor].[USP_PrepareDatabaseCandidates]
              @DatabaseNames=@DatabaseNames
            , @SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen
            , @DatabaseNamePattern=@DatabaseNamePattern
            , @AnalysisClass='STANDARD_CURRENT'
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT
            , @CrossDatabaseRequested=@CrossDatabaseRequested OUTPUT
            , @CandidateTable=N'#DatabaseConfigurationAnalysis_DatabaseCandidates'
            , @WarningTable=N'#DatabaseConfigurationAnalysis_CandidateWarnings';

    SET LOCK_TIMEOUT 0;

    IF @StatusCode='AVAILABLE'
    BEGIN TRY
        INSERT [#DatabaseConfigurationAnalysis_Settings]
        SELECT @CapturedAtUtc,[d].[database_id],[d].[name],'DATABASE',[v].[SettingName],[v].[ActualValue],NULL,NULL,
               N'master.sys.databases','AVAILABLE',
               N'Sichtbarer aktueller Serverkatalogzustand; Wertunterschiede sind ohne Workload- und Betriebsprofil keine Fehlkonfiguration.'
        FROM [master].[sys].[databases] AS [d] WITH (NOLOCK)
        INNER JOIN [#DatabaseConfigurationAnalysis_DatabaseCandidates] AS [c] ON [c].[DatabaseId]=[d].[database_id]
        CROSS APPLY
        (
            VALUES
              (CONVERT(nvarchar(128),N'COMPATIBILITY_LEVEL'),CONVERT(nvarchar(4000),[d].[compatibility_level]))
            , (N'COLLATION',CONVERT(nvarchar(4000),[d].[collation_name]))
            , (N'RECOVERY_MODEL',CONVERT(nvarchar(4000),[d].[recovery_model_desc]))
            , (N'PAGE_VERIFY',CONVERT(nvarchar(4000),[d].[page_verify_option_desc]))
            , (N'AUTO_CLOSE',CASE [d].[is_auto_close_on] WHEN 1 THEN N'ON' ELSE N'OFF' END)
            , (N'AUTO_SHRINK',CASE [d].[is_auto_shrink_on] WHEN 1 THEN N'ON' ELSE N'OFF' END)
            , (N'AUTO_CREATE_STATS',CASE [d].[is_auto_create_stats_on] WHEN 1 THEN N'ON' ELSE N'OFF' END)
            , (N'AUTO_UPDATE_STATS',CASE [d].[is_auto_update_stats_on] WHEN 1 THEN N'ON' ELSE N'OFF' END)
            , (N'AUTO_UPDATE_STATS_ASYNC',CASE [d].[is_auto_update_stats_async_on] WHEN 1 THEN N'ON' ELSE N'OFF' END)
            , (N'READ_COMMITTED_SNAPSHOT',CASE [d].[is_read_committed_snapshot_on] WHEN 1 THEN N'ON' ELSE N'OFF' END)
            , (N'SNAPSHOT_ISOLATION',CONVERT(nvarchar(4000),[d].[snapshot_isolation_state_desc]))
            , (N'PARAMETERIZATION',CASE [d].[is_parameterization_forced] WHEN 1 THEN N'FORCED' ELSE N'SIMPLE' END)
            , (N'QUERY_STORE',CASE [d].[is_query_store_on] WHEN 1 THEN N'ON' ELSE N'OFF' END)
            , (N'ACCELERATED_DATABASE_RECOVERY',CASE [d].[is_accelerated_database_recovery_on] WHEN 1 THEN N'ON' ELSE N'OFF' END)
        ) AS [v]([SettingName],[ActualValue]);

        INSERT [#DatabaseConfigurationAnalysis_SourceStatus]
        SELECT [DatabaseId],[DatabaseName],N'databaseOptions',N'master.sys.databases',@CapturedAtUtc,'AVAILABLE',0,
               (SELECT COUNT_BIG(*) FROM [#DatabaseConfigurationAnalysis_Settings] AS [s] WHERE [s].[DatabaseId]=[c].[DatabaseId] AND [s].[SettingScope]='DATABASE'),
               NULL,NULL,N'Ein Katalogsnapshot; nicht sichtbare Datenbanken fehlen und einzelne Optionen bleiben workloadabhängig.'
        FROM [#DatabaseConfigurationAnalysis_DatabaseCandidates] AS [c];
    END TRY
    BEGIN CATCH
        INSERT [#DatabaseConfigurationAnalysis_SourceStatus]
        VALUES(NULL,NULL,N'databaseOptions',N'master.sys.databases',@CapturedAtUtc,
               CASE WHEN ERROR_NUMBER() IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,
               1,0,ERROR_NUMBER(),ERROR_MESSAGE(),N'Datenbanklokale Quellen können unabhängig davon teilweise verfügbar bleiben.');
    END CATCH;

    IF @StatusCode='AVAILABLE' AND EXISTS
    (
        SELECT 1
        FROM [master].[sys].[all_columns] AS [ac] WITH (NOLOCK)
        INNER JOIN [master].[sys].[all_objects] AS [ao] WITH (NOLOCK) ON [ao].[object_id]=[ac].[object_id]
        INNER JOIN [master].[sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[ao].[schema_id]
        WHERE [s].[name]=N'sys' AND [ao].[name]=N'databases' AND [ac].[name]=N'is_optimized_locking_on'
    )
    BEGIN TRY
        EXEC [sys].[sp_executesql]
            N'INSERT [#DatabaseConfigurationAnalysis_Settings]
              SELECT @CapturedAtUtc,[d].[database_id],[d].[name],''DATABASE'',N''OPTIMIZED_LOCKING'',
                     CASE [d].[is_optimized_locking_on] WHEN 1 THEN N''ON'' ELSE N''OFF'' END,NULL,NULL,
                     N''master.sys.databases'',''AVAILABLE'',
                     N''Versionsabhängiger sichtbarer Katalogzustand; Aktivierung ist ohne Workloadkontext keine automatische Empfehlung.''
              FROM [master].[sys].[databases] AS [d] WITH (NOLOCK)
              INNER JOIN [#DatabaseConfigurationAnalysis_DatabaseCandidates] AS [c] ON [c].[DatabaseId]=[d].[database_id];',
            N'@CapturedAtUtc datetime2(3)',@CapturedAtUtc=@CapturedAtUtc;
    END TRY
    BEGIN CATCH
        INSERT [#DatabaseConfigurationAnalysis_Warnings]([DatabaseName],[SourceName],[StatusCode],[ErrorNumber],[Message])
        VALUES(NULL,N'databaseOptions',CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,ERROR_NUMBER(),ERROR_MESSAGE());
    END CATCH;

    IF @StatusCode='AVAILABLE'
    BEGIN
        DECLARE @DatabaseId int,@DatabaseName sysname,@Sql nvarchar(max);
        DECLARE [DatabaseCursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [DatabaseId],[DatabaseName]
            FROM [#DatabaseConfigurationAnalysis_DatabaseCandidates]
            ORDER BY COALESCE([RequestedOrdinal],[DatabaseId]),[DatabaseId];
        OPEN [DatabaseCursor]; FETCH NEXT FROM [DatabaseCursor] INTO @DatabaseId,@DatabaseName;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @Sql=N'
            BEGIN TRY
                INSERT [#DatabaseConfigurationAnalysis_Settings]
                SELECT @CapturedAtUtc,@DatabaseId,@DatabaseName,''SCOPED'',CONVERT(nvarchar(128),[name]),
                       CONVERT(nvarchar(4000),[value]),CONVERT(nvarchar(4000),[value_for_secondary]),[is_value_default],
                       N''sys.database_scoped_configurations'',''AVAILABLE'',
                       N''Datenbanklokaler Katalogzustand; Wert, Secondary-Wert und Defaultstatus werden getrennt erhalten.''
                FROM '+QUOTENAME(@DatabaseName)+N'.[sys].[database_scoped_configurations] WITH (NOLOCK);
                DECLARE @ScopedRows bigint=@@ROWCOUNT;
                INSERT [#DatabaseConfigurationAnalysis_SourceStatus]
                VALUES(@DatabaseId,@DatabaseName,N''scopedConfigurations'',N''sys.database_scoped_configurations'',@CapturedAtUtc,''AVAILABLE'',0,@ScopedRows,NULL,NULL,
                       N''Eine Zeile je verfügbarer Scoped Configuration; Einstellungen können versionsabhängig hinzukommen.'');
            END TRY
            BEGIN CATCH
                INSERT [#DatabaseConfigurationAnalysis_SourceStatus]
                VALUES(@DatabaseId,@DatabaseName,N''scopedConfigurations'',N''sys.database_scoped_configurations'',@CapturedAtUtc,
                       CASE WHEN ERROR_NUMBER() IN(229,262,297,300,371,916) THEN ''DENIED_PERMISSION'' WHEN ERROR_NUMBER()=1222 THEN ''TIMEOUT'' ELSE ''ERROR_HANDLED'' END,
                       1,0,ERROR_NUMBER(),ERROR_MESSAGE(),N''Andere Datenbanken und Quellen werden weiter verarbeitet.'');
            END CATCH;
            BEGIN TRY
                INSERT [#DatabaseConfigurationAnalysis_Settings]
                SELECT @CapturedAtUtc,@DatabaseId,@DatabaseName,''QUERY_STORE'',[v].[SettingName],[v].[ActualValue],NULL,NULL,
                       N''sys.database_query_store_options'',''AVAILABLE'',
                       N''Aktueller Query-Store-Konfigurations- und Zustandswert; gewünschter und tatsächlicher Zustand sind getrennt zu bewerten.''
                FROM '+QUOTENAME(@DatabaseName)+N'.[sys].[database_query_store_options] AS [q] WITH (NOLOCK)
                CROSS APPLY
                (VALUES
                    (CONVERT(nvarchar(128),N''DESIRED_STATE''),CONVERT(nvarchar(4000),[q].[desired_state_desc])),
                    (N''ACTUAL_STATE'',CONVERT(nvarchar(4000),[q].[actual_state_desc])),
                    (N''READONLY_REASON'',CONVERT(nvarchar(4000),[q].[readonly_reason])),
                    (N''CURRENT_STORAGE_SIZE_MB'',CONVERT(nvarchar(4000),[q].[current_storage_size_mb])),
                    (N''MAX_STORAGE_SIZE_MB'',CONVERT(nvarchar(4000),[q].[max_storage_size_mb])),
                    (N''STALE_QUERY_THRESHOLD_DAYS'',CONVERT(nvarchar(4000),[q].[stale_query_threshold_days])),
                    (N''FLUSH_INTERVAL_SECONDS'',CONVERT(nvarchar(4000),[q].[flush_interval_seconds])),
                    (N''INTERVAL_LENGTH_MINUTES'',CONVERT(nvarchar(4000),[q].[interval_length_minutes])),
                    (N''QUERY_CAPTURE_MODE'',CONVERT(nvarchar(4000),[q].[query_capture_mode_desc])),
                    (N''SIZE_BASED_CLEANUP_MODE'',CONVERT(nvarchar(4000),[q].[size_based_cleanup_mode_desc])),
                    (N''WAIT_STATS_CAPTURE_MODE'',CONVERT(nvarchar(4000),[q].[wait_stats_capture_mode_desc]))
                ) AS [v]([SettingName],[ActualValue]);
                DECLARE @QueryStoreRows bigint=@@ROWCOUNT;
                INSERT [#DatabaseConfigurationAnalysis_SourceStatus]
                VALUES(@DatabaseId,@DatabaseName,N''queryStoreOptions'',N''sys.database_query_store_options'',@CapturedAtUtc,''AVAILABLE'',0,@QueryStoreRows,NULL,NULL,
                       N''Konfiguration und aktueller Zustand; Query-Store-Inhalt und Workloadwirkung werden nicht gelesen.'');
            END TRY
            BEGIN CATCH
                INSERT [#DatabaseConfigurationAnalysis_SourceStatus]
                VALUES(@DatabaseId,@DatabaseName,N''queryStoreOptions'',N''sys.database_query_store_options'',@CapturedAtUtc,
                       CASE WHEN ERROR_NUMBER() IN(229,262,297,300,371,916) THEN ''DENIED_PERMISSION'' WHEN ERROR_NUMBER()=1222 THEN ''TIMEOUT'' ELSE ''ERROR_HANDLED'' END,
                       1,0,ERROR_NUMBER(),ERROR_MESSAGE(),N''Andere Datenbanken und Quellen werden weiter verarbeitet.'');
            END CATCH;';
            BEGIN TRY
                EXEC [sys].[sp_executesql] @Sql,
                     N'@DatabaseId int,@DatabaseName sysname,@CapturedAtUtc datetime2(3)',
                     @DatabaseId=@DatabaseId,@DatabaseName=@DatabaseName,@CapturedAtUtc=@CapturedAtUtc;
            END TRY
            BEGIN CATCH
                INSERT [#DatabaseConfigurationAnalysis_SourceStatus]
                VALUES(@DatabaseId,@DatabaseName,N'databaseLocalCatalogs',N'sys.database_scoped_configurations|sys.database_query_store_options',@CapturedAtUtc,
                       CASE WHEN ERROR_NUMBER() IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,
                       1,0,ERROR_NUMBER(),ERROR_MESSAGE(),N'Dynamische Kompilierungs- oder Zustandsänderung; andere Datenbanken werden weiter verarbeitet.');
            END CATCH;
            FETCH NEXT FROM [DatabaseCursor] INTO @DatabaseId,@DatabaseName;
        END;
        CLOSE [DatabaseCursor]; DEALLOCATE [DatabaseCursor];
    END;

    IF @StatusCode='AVAILABLE'
    BEGIN
        ;WITH [ValueCounts] AS
        (
            SELECT [SettingScope],[SettingName],[ActualValue],COUNT(*) AS [ValueDatabaseCount]
            FROM [#DatabaseConfigurationAnalysis_Settings]
            GROUP BY [SettingScope],[SettingName],[ActualValue]
        ),
        [RankedValues] AS
        (
            SELECT [SettingScope],[SettingName],[ActualValue],[ValueDatabaseCount],
                   SUM([ValueDatabaseCount]) OVER(PARTITION BY [SettingScope],[SettingName]) AS [ComparedDatabaseCount],
                   ROW_NUMBER() OVER(PARTITION BY [SettingScope],[SettingName] ORDER BY [ValueDatabaseCount] DESC,[ActualValue]) AS [ReferenceRank],
                   COUNT(*) OVER(PARTITION BY [SettingScope],[SettingName]) AS [DistinctValueCount]
            FROM [ValueCounts]
        ),
        [ReferenceValues] AS
        (
            SELECT [SettingScope],[SettingName],[ActualValue] AS [ReferenceValue],[ValueDatabaseCount],[ComparedDatabaseCount]
            FROM [RankedValues] WHERE [ReferenceRank]=1 AND [DistinctValueCount]>1
        )
        INSERT [#DatabaseConfigurationAnalysis_Drift]
        SELECT @CapturedAtUtc,'LOCAL_VARIATION',[s].[DatabaseId],[s].[DatabaseName],[s].[SettingScope],[s].[SettingName],
               [s].[ActualValue],[r].[ReferenceValue],[vc].[ValueDatabaseCount],[r].[ComparedDatabaseCount],
               'LOCAL_CONFIGURATION_VARIATION',
               N'Der häufigste sichtbare Wert ist nur eine lokale Vergleichsreferenz und kein Sollwert; Gleichstand wird deterministisch nach Wert aufgelöst.'
        FROM [#DatabaseConfigurationAnalysis_Settings] AS [s]
        INNER JOIN [ReferenceValues] AS [r] ON [r].[SettingScope]=[s].[SettingScope] AND [r].[SettingName]=[s].[SettingName]
        INNER JOIN [ValueCounts] AS [vc] ON [vc].[SettingScope]=[s].[SettingScope] AND [vc].[SettingName]=[s].[SettingName]
                                        AND ISNULL([vc].[ActualValue],N'<NULL>')=ISNULL([s].[ActualValue],N'<NULL>')
        WHERE ISNULL([s].[ActualValue],N'<NULL>') COLLATE SQL_Latin1_General_CP1_CI_AS
             <>ISNULL([r].[ReferenceValue],N'<NULL>') COLLATE SQL_Latin1_General_CP1_CI_AS;

        INSERT [#DatabaseConfigurationAnalysis_Drift]
        SELECT @CapturedAtUtc,'PROFILE_MISMATCH',[s].[DatabaseId],[s].[DatabaseName],[s].[SettingScope],[s].[SettingName],
               [s].[ActualValue],[p].[ExpectedValue],NULL,1,'EXPLICIT_PROFILE_MISMATCH',
               N'Explizit geliefertes Sollprofil; der Befund ist eine Abweichung, aber ohne Change-Freigabe keine Änderungsanweisung.'
        FROM [#DatabaseConfigurationAnalysis_Settings] AS [s]
        INNER JOIN [#DatabaseConfigurationAnalysis_Profile] AS [p]
          ON [p].[SettingScope]=[s].[SettingScope]
         AND [p].[SettingName] COLLATE SQL_Latin1_General_CP1_CI_AS=[s].[SettingName] COLLATE SQL_Latin1_General_CP1_CI_AS
        WHERE ISNULL([s].[ActualValue],N'<NULL>') COLLATE SQL_Latin1_General_CP1_CI_AS
             <>ISNULL([p].[ExpectedValue],N'<NULL>') COLLATE SQL_Latin1_General_CP1_CI_AS;

        INSERT [#DatabaseConfigurationAnalysis_Warnings]([DatabaseName],[SourceName],[StatusCode],[ErrorNumber],[Message])
        SELECT NULL,N'profile','PROFILE_SETTING_NOT_VISIBLE',NULL,
               CONCAT(N'Profileintrag nicht in sichtbarer Evidenz gefunden: ',[p].[SettingScope],N'/',[p].[SettingName],N'.')
        FROM [#DatabaseConfigurationAnalysis_Profile] AS [p]
        WHERE NOT EXISTS
        (
            SELECT 1 FROM [#DatabaseConfigurationAnalysis_Settings] AS [s]
            WHERE [s].[SettingScope]=[p].[SettingScope]
              AND [s].[SettingName] COLLATE SQL_Latin1_General_CP1_CI_AS=[p].[SettingName] COLLATE SQL_Latin1_General_CP1_CI_AS
        );
    END;

    INSERT [#DatabaseConfigurationAnalysis_Warnings]([DatabaseName],[SourceName],[StatusCode],[ErrorNumber],[Message])
    SELECT [DatabaseName],[SourceName],[StatusCode],[ErrorNumber],COALESCE([ErrorMessage],N'Quelle nicht verfügbar.')
    FROM [#DatabaseConfigurationAnalysis_SourceStatus] WHERE [IsPartial]=1;
    INSERT [#DatabaseConfigurationAnalysis_Warnings]([DatabaseName],[SourceName],[StatusCode],[ErrorNumber],[Message])
    SELECT [RequestedName],N'databaseCandidates',[StatusCode],NULL,COALESCE([ErrorMessage],N'Datenbank nicht verarbeitet.')
    FROM [#DatabaseConfigurationAnalysis_CandidateWarnings];

    IF @StatusCode='AVAILABLE' AND EXISTS(SELECT 1 FROM [#DatabaseConfigurationAnalysis_Warnings] WHERE [StatusCode] NOT IN('PROFILE_SETTING_NOT_VISIBLE'))
        SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;

    IF @StatusCode NOT IN('AVAILABLE','AVAILABLE_LIMITED')
        SET @IsPartial=1;

    SELECT TOP(1) @ErrorNumber=[ErrorNumber],@ErrorMessage=[Message]
    FROM [#DatabaseConfigurationAnalysis_Warnings]
    WHERE [StatusCode] NOT IN('PROFILE_SETTING_NOT_VISIBLE')
    ORDER BY [WarningOrdinal];

    DECLARE @SettingRows bigint=(SELECT COUNT_BIG(*) FROM [#DatabaseConfigurationAnalysis_Settings]);
    DECLARE @DriftRows bigint=(SELECT COUNT_BIG(*) FROM [#DatabaseConfigurationAnalysis_Drift]);
    INSERT [#DatabaseConfigurationAnalysis_ModuleStatus]
    VALUES(N'USP_DatabaseConfigurationAnalysis',@CapturedAtUtc,@StatusCode,@IsPartial,@CrossDatabaseRequested,
           (SELECT COUNT(*) FROM [#DatabaseConfigurationAnalysis_DatabaseCandidates]),
           CASE WHEN @SettingRows>@Limit THEN @Limit ELSE @SettingRows END,
           CASE WHEN @DriftRows>@Limit THEN @Limit ELSE @DriftRows END,
           (SELECT COUNT(*) FROM [#DatabaseConfigurationAnalysis_Profile]),
           CONVERT(bit,CASE WHEN @Limit<9223372036854775807 AND @SettingRows>@Limit THEN 1 ELSE 0 END),
           CONVERT(bit,CASE WHEN @Limit<9223372036854775807 AND @DriftRows>@Limit THEN 1 ELSE 0 END),
           @ErrorNumber,@ErrorMessage);

    IF @JsonErzeugen=1
    BEGIN
        DECLARE @MetaJson nvarchar(max)=(SELECT N'DatabaseConfigurationAnalysis' [resultName],1 [schemaVersion],@CapturedAtUtc [generatedAtUtc],@StatusCode [statusCode],@IsPartial [isPartial],CASE WHEN @ProfileJson IS NULL THEN 'LOCAL_COMPARISON' ELSE 'LOCAL_AND_EXPLICIT_PROFILE' END [comparisonMode],@ErrorNumber [errorNumber],@ErrorMessage [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @SettingsJson nvarchar(max)=(SELECT TOP(@Limit) * FROM [#DatabaseConfigurationAnalysis_Settings] ORDER BY [DatabaseName],[SettingScope],[SettingName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @DriftJson nvarchar(max)=(SELECT TOP(@Limit) * FROM [#DatabaseConfigurationAnalysis_Drift] ORDER BY [DriftType],[SettingScope],[SettingName],[DatabaseName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @ProfileOutputJson nvarchar(max)=(SELECT * FROM [#DatabaseConfigurationAnalysis_Profile] ORDER BY [ProfileOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @SourceJson nvarchar(max)=(SELECT * FROM [#DatabaseConfigurationAnalysis_SourceStatus] ORDER BY [SourceOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @WarningsJson nvarchar(max)=(SELECT * FROM [#DatabaseConfigurationAnalysis_Warnings] ORDER BY [WarningOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@MetaJson,N'{}'),N',"settings":',COALESCE(@SettingsJson,N'[]'),N',"drift":',COALESCE(@DriftJson,N'[]'),N',"profile":',COALESCE(@ProfileOutputJson,N'[]'),N',"sourceStatus":',COALESCE(@SourceJson,N'[]'),N',"warnings":',COALESCE(@WarningsJson,N'[]'),N'}');
    END;

    IF @ConsoleResultRequested=1
        EXEC [monitor].[InternalEmitConsoleResult] @SourceTable=N'#DatabaseConfigurationAnalysis_Drift',@ResultLabel=N'Datenbankkonfiguration und Drift',@EmptyMessage=N'Keine lokale Variation oder Profilabweichung sichtbar';
    ELSE IF @OutputMode='RAW'
    BEGIN
        SELECT * FROM [#DatabaseConfigurationAnalysis_ModuleStatus];
        SELECT TOP(@Limit) * FROM [#DatabaseConfigurationAnalysis_Settings] ORDER BY [DatabaseName],[SettingScope],[SettingName];
        SELECT TOP(@Limit) * FROM [#DatabaseConfigurationAnalysis_Drift] ORDER BY [DriftType],[SettingScope],[SettingName],[DatabaseName];
        SELECT * FROM [#DatabaseConfigurationAnalysis_Profile] ORDER BY [ProfileOrdinal];
        SELECT * FROM [#DatabaseConfigurationAnalysis_SourceStatus] ORDER BY [SourceOrdinal];
        SELECT * FROM [#DatabaseConfigurationAnalysis_Warnings] ORDER BY [WarningOrdinal];
    END
    ELSE IF @OutputMode='TABLE'
    BEGIN
        DECLARE @ResultName sysname,@TargetTable sysname,@SourceTable sysname;
        DECLARE [ResultCursor] CURSOR LOCAL FAST_FORWARD FOR SELECT [ResultName],[TargetTable] FROM [#DatabaseConfigurationAnalysis_ResultTableMap] ORDER BY [ResultName];
        OPEN [ResultCursor]; FETCH NEXT FROM [ResultCursor] INTO @ResultName,@TargetTable;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @SourceTable=CASE @ResultName WHEN N'moduleStatus' THEN N'#DatabaseConfigurationAnalysis_ModuleStatus' WHEN N'settings' THEN N'#DatabaseConfigurationAnalysis_Settings' WHEN N'drift' THEN N'#DatabaseConfigurationAnalysis_Drift' WHEN N'profile' THEN N'#DatabaseConfigurationAnalysis_Profile' WHEN N'sourceStatus' THEN N'#DatabaseConfigurationAnalysis_SourceStatus' WHEN N'warnings' THEN N'#DatabaseConfigurationAnalysis_Warnings' END;
            EXEC [monitor].[InternalWriteResultTable] @SourceTable=@SourceTable,@TargetTable=@TargetTable,@ThrowOnError=1;
            FETCH NEXT FROM [ResultCursor] INTO @ResultName,@TargetTable;
        END;
        CLOSE [ResultCursor]; DEALLOCATE [ResultCursor];
    END;

    IF @PrintMeldungen=1 AND @StatusCode<>'AVAILABLE'
    BEGIN
        DECLARE @PrintMessage nvarchar(2048)=LEFT(CONCAT(N'USP_DatabaseConfigurationAnalysis: ',@StatusCode,N'. ',COALESCE(@ErrorMessage,N'Siehe warnings-Resultset.')),2048);
        RAISERROR(N'%s',10,1,@PrintMessage) WITH NOWAIT;
    END;
    SELECT @StatusCodeOut=@StatusCode,@IsPartialOut=@IsPartial,@ErrorNumberOut=@ErrorNumber,@ErrorMessageOut=@ErrorMessage;
END;
GO
