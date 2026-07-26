USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ExternalRuntimeAnalysis
Version      : 1.0.0
Stand        : 2026-07-22
Typ          : Stored Procedure
Zweck        : Analysiert Konfiguration, registrierte Sprachen und Libraries,
               aktive External-Script-Requests, External Resource Pools sowie
               kumulative Runtime- und Performance-Counter-Evidenz.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : SERVERPROPERTY, sys.configurations, sys.dm_server_services,
               sys.external_languages, sys.external_language_files,
               sys.external_libraries, sys.external_library_files,
               sys.dm_external_script_requests, sys.dm_exec_requests,
               sys.dm_exec_sessions,
               sys.dm_external_script_execution_stats,
               sys.dm_resource_governor_external_resource_pools und
               sys.dm_os_performance_counters.
Datenschutz  : Liest keine Scripttexte, Parameter, Environment Variables,
               Binärinhalte oder Dateipfade. Konten und Clientkontext werden
               ausschließlich mit @MitSitzungskontext=1 ausgegeben.
Methodik     : Jede optionale Quelle wird einmal je Messpunkt materialisiert.
               Ein Sample verwendet ein gemeinsames Intervall und verwirft
               Deltas bei Reset, Zählerrückgang oder Poolversionswechsel.
Grenzen      : Registrierung und Konfiguration beweisen weder Installation
               noch Startfähigkeit einer konkreten Runtime. Request-CPU ist
               Engine-Evidenz und enthält keine belegte externe Prozess-CPU.
Kosten       : MEDIUM; optionales Sampling wartet höchstens 60 Sekunden.
Nebenwirkung : Rein lesend; führt kein externes Script aus und ändert weder
               Launchpad-, Resource-Governor- noch Serverkonfiguration.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_ExternalRuntimeAnalysis]
      @DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @LanguageNames                    nvarchar(max)  = NULL
    , @LanguageNamePattern              nvarchar(4000) = NULL
    , @SampleSeconds                    tinyint         = 0
    , @MitDateimetadaten                bit             = 0
    , @MitBerechtigungsanalyse          bit             = 0
    , @MitSitzungskontext               bit             = 0
    , @NurProblematisch                 bit             = 0
    , @MaxZeilen                        int             = 100
    , @LockTimeoutMs                    int             = 0
    , @ResultSetArt                     varchar(16)     = 'CONSOLE'
    , @ResultTablesJson                 nvarchar(max)   = NULL
    , @JsonErzeugen                     bit             = 0
    , @Json                             nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                   bit             = 1
    , @Hilfe                            bit             = 0
    , @StatusCodeOut                    varchar(40)     = NULL OUTPUT
    , @IsPartialOut                     bit             = NULL OUTPUT
    , @ErrorNumberOut                   int             = NULL OUTPUT
    , @ErrorMessageOut                  nvarchar(2048)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json=NULL;

    DECLARE @OriginalLockTimeout int=@@LOCK_TIMEOUT;
    DECLARE @LockTimeoutSql nvarchar(100);
    DECLARE @Now datetime2(3)=SYSUTCDATETIME();
    DECLARE @MeasurementStartUtc datetime2(3)=NULL,@MeasurementEndUtc datetime2(3)=NULL;
    DECLARE @Major int=TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'));
    DECLARE @HostPlatform nvarchar(60)=TRY_CONVERT(nvarchar(60),SERVERPROPERTY(N'HostPlatform'));
    DECLARE @OutputModeRequested varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @OutputMode varchar(16)=@OutputModeRequested;
    DECLARE @TableResultRequested bit=CONVERT(bit,CASE WHEN @OutputModeRequested='TABLE' THEN 1 ELSE 0 END);
    DECLARE @ConsoleResultRequested bit=CONVERT(bit,CASE WHEN @OutputModeRequested='CONSOLE' THEN 1 ELSE 0 END);
    DECLARE @TableTarget sysname=NULL;
    DECLARE @StatusCode varchar(40)='AVAILABLE',@IsPartial bit=0;
    DECLARE @ErrorNumber int=NULL,@ErrorMessage nvarchar(2048)=NULL,@PrintMessage nvarchar(2048)=NULL;
    DECLARE @Limit bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0
                               THEN CONVERT(bigint,9223372036854775807)
                               ELSE CONVERT(bigint,@MaxZeilen) END;
    DECLARE @RequiredPerformancePermission nvarchar(128)=CASE WHEN COALESCE(@Major,0)>=16 THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END;
    DECLARE @RequiredServicePermission nvarchar(128)=CASE WHEN COALESCE(@Major,0)>=16 THEN N'VIEW SERVER SECURITY STATE' ELSE N'VIEW SERVER STATE' END;

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_ExternalRuntimeAnalysis';
        PRINT N'Die Procedure analysiert External Languages, Libraries, aktive External-Script-Requests, External Resource Pools und Runtime-Counter, ohne externen Code auszuführen.';
        PRINT N'@SampleSeconds=0 liefert Momentaufnahmen; Werte von 1 bis 60 erzeugen ein gemeinsames Deltafenster für Pools, Execution Stats und Performance Counter.';
        PRINT N'@MitDateimetadaten=1 liest ausschließlich Dateiname und Plattform, niemals Inhalt, Parameter, Environment Variables oder Pfade.';
        PRINT N'@MitBerechtigungsanalyse=1 ergänzt sichtbare Ownernamen und benötigt den CATALOG_DEEP-Pfad sowie @HighImpactConfirmed=1.';
        PRINT N'@MitSitzungskontext=1 ergänzt Login, Host, Clientprogramm und External Worker Account; die Standardausgabe lässt diese Identitäten aus.';
        PRINT N'@ResultSetArt=CONSOLE|RAW|TABLE|NONE; TABLE schreibt das primäre Resultset findings über @ResultTablesJson.';
        RETURN;
    END;

    IF @OutputModeRequested NOT IN('CONSOLE','RAW','TABLE','NONE')
        SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,@ErrorMessage=N'@ResultSetArt muss CONSOLE, RAW, TABLE oder NONE sein.';
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL
        THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1
        EXEC [monitor].[InternalPrepareSingleResultTable]
              @ResultTablesJson=@ResultTablesJson
            , @ResultName=N'findings'
            , @TargetTable=@TableTarget OUTPUT
            , @ThrowOnError=1;
    IF @TableResultRequested=1 OR @ConsoleResultRequested=1 SET @OutputMode='NONE';

    IF @StatusCode='AVAILABLE'
       AND (@SystemdatenbankenEinbeziehen IS NULL OR @HighImpactConfirmed IS NULL
            OR @MitDateimetadaten IS NULL OR @MitBerechtigungsanalyse IS NULL
            OR @MitSitzungskontext IS NULL OR @NurProblematisch IS NULL
            OR @JsonErzeugen IS NULL OR @PrintMeldungen IS NULL
            OR @SampleSeconds IS NULL OR @SampleSeconds>60
            OR @MaxZeilen IS NULL OR @MaxZeilen<0
            OR @LockTimeoutMs IS NULL OR @LockTimeoutMs NOT BETWEEN 0 AND 60000)
        SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,@ErrorMessage=N'Ungültiger Bit-, Sample-, Zeilen- oder Lock-Timeout-Parameter.';

    CREATE TABLE [#ExternalRuntimeAnalysis_DatabaseCandidates]
    (
          [DatabaseId] int NOT NULL PRIMARY KEY
        , [DatabaseName] sysname NOT NULL
        , [StateDesc] nvarchar(60) NULL
        , [UserAccessDesc] nvarchar(60) NULL
        , [IsReadOnly] bit NULL
        , [CompatibilityLevel] tinyint NULL
        , [CollationName] sysname NULL
        , [RecoveryModelDesc] nvarchar(60) NULL
        , [IsSystemDatabase] bit NULL
        , [RequestedOrdinal] int NULL
    );
    CREATE TABLE [#ExternalRuntimeAnalysis_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );
    CREATE TABLE [#ExternalRuntimeAnalysis_LanguageFilters]
    (
          [ItemOrdinal] int NOT NULL
        , [LanguageName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , PRIMARY KEY ([LanguageName])
    );
    CREATE TABLE [#ExternalRuntimeAnalysis_Configuration]
    (
          [CollectedAtUtc] datetime2(3) NOT NULL
        , [ProductMajorVersion] int NULL
        , [HostPlatform] nvarchar(60) NULL
        , [IsAdvancedAnalyticsInstalled] int NULL
        , [ExternalScriptsConfiguredValue] int NULL
        , [ExternalScriptsValueInUse] int NULL
        , [LaunchpadServiceCount] int NULL
        , [LaunchpadRunningCount] int NULL
        , [LaunchpadStatus] varchar(40) NOT NULL
        , [RequiredPerformancePermission] nvarchar(128) NOT NULL
        , [RequiredServicePermission] nvarchar(128) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ExternalRuntimeAnalysis_DatabaseStatus]
    (
          [DatabaseName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [LanguageCount] bigint NOT NULL
        , [LibraryCount] bigint NOT NULL
        , [SourceFailureCount] int NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ExternalRuntimeAnalysis_SourceStatus]
    (
          [DatabaseName] sysname NULL
        , [SourceCode] varchar(80) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [RowCount] bigint NOT NULL
        , [RequiredPermission] nvarchar(256) NULL
        , [ReadAtUtc] datetime2(3) NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ExternalRuntimeAnalysis_Languages]
    (
          [DatabaseName] sysname NOT NULL
        , [ExternalLanguageId] int NOT NULL
        , [LanguageName] sysname NOT NULL
        , [CreateDate] datetime2 NULL
        , [OwnerName] sysname NULL
        , [FileName] sysname NULL
        , [FilePlatformDesc] nvarchar(60) NULL
        , [FileMetadataStatus] varchar(40) NOT NULL
        , [AssessmentStatus] varchar(40) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ExternalRuntimeAnalysis_Libraries]
    (
          [DatabaseName] sysname NOT NULL
        , [ExternalLibraryId] int NOT NULL
        , [LibraryName] sysname NOT NULL
        , [LanguageName] sysname NULL
        , [ScopeDesc] varchar(7) NULL
        , [OwnerName] sysname NULL
        , [FilePlatformDesc] nvarchar(60) NULL
        , [FileMetadataStatus] varchar(40) NOT NULL
        , [AssessmentStatus] varchar(40) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ExternalRuntimeAnalysis_ActiveRequests]
    (
          [ExternalScriptRequestId] uniqueidentifier NOT NULL
        , [LanguageName] nvarchar(128) NULL
        , [DegreeOfParallelism] int NULL
        , [SessionId] smallint NULL
        , [RequestId] int NULL
        , [DatabaseName] sysname NULL
        , [RequestStatus] nvarchar(30) NULL
        , [Command] nvarchar(32) NULL
        , [BlockingSessionId] smallint NULL
        , [WaitType] nvarchar(60) NULL
        , [WaitTimeMs] int NULL
        , [ElapsedTimeMs] int NULL
        , [EngineCpuTimeMs] int NULL
        , [Reads] bigint NULL
        , [LogicalReads] bigint NULL
        , [Writes] bigint NULL
        , [LoginName] sysname NULL
        , [HostName] nvarchar(128) NULL
        , [ProgramName] nvarchar(128) NULL
        , [ExternalWorkerAccount] nvarchar(256) NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ExternalRuntimeAnalysis_PoolSamples]
    (
          [SamplePoint] char(2) NOT NULL
        , [ReadAtUtc] datetime2(3) NOT NULL
        , [ExternalPoolId] int NOT NULL
        , [PoolName] sysname NOT NULL
        , [PoolVersion] int NULL
        , [MaxCpuPercent] int NULL
        , [MaxProcesses] int NULL
        , [MaxMemoryPercent] int NULL
        , [StatisticsStartTime] datetime NULL
        , [PeakMemoryKb] bigint NULL
        , [WriteIoCount] bigint NULL
        , [ReadIoCount] bigint NULL
        , [TotalCpuKernelMs] bigint NULL
        , [TotalCpuUserMs] bigint NULL
        , [ActiveProcessesCount] int NULL
    );
    CREATE TABLE [#ExternalRuntimeAnalysis_ExternalPools]
    (
          [ExternalPoolId] int NOT NULL
        , [PoolName] sysname NOT NULL
        , [MaxCpuPercent] int NULL
        , [MaxProcesses] int NULL
        , [MaxMemoryPercent] int NULL
        , [StatisticsStartTime] datetime NULL
        , [PeakMemoryKb] bigint NULL
        , [ActiveProcessesCount] int NULL
        , [SampleSeconds] decimal(19,6) NULL
        , [CpuKernelDelta] bigint NULL
        , [CpuUserDelta] bigint NULL
        , [ReadIoDelta] bigint NULL
        , [WriteIoDelta] bigint NULL
        , [DeltaStatus] varchar(40) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ExternalRuntimeAnalysis_ExecutionStatSamples]
    (
          [SamplePoint] char(2) NOT NULL
        , [ReadAtUtc] datetime2(3) NOT NULL
        , [LanguageName] nvarchar(128) NOT NULL
        , [CounterName] nvarchar(256) NOT NULL
        , [CounterValue] bigint NOT NULL
    );
    CREATE TABLE [#ExternalRuntimeAnalysis_ExecutionStats]
    (
          [LanguageName] nvarchar(128) NOT NULL
        , [CounterName] nvarchar(256) NOT NULL
        , [CounterValue] bigint NOT NULL
        , [CounterDelta] bigint NULL
        , [DeltaStatus] varchar(40) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ExternalRuntimeAnalysis_CounterSamples]
    (
          [SamplePoint] char(2) NOT NULL
        , [ReadAtUtc] datetime2(3) NOT NULL
        , [CounterName] nvarchar(128) NOT NULL
        , [InstanceName] nvarchar(128) NOT NULL
        , [CounterType] int NOT NULL
        , [CounterValue] bigint NOT NULL
    );
    CREATE TABLE [#ExternalRuntimeAnalysis_PerformanceCounters]
    (
          [CounterName] nvarchar(128) NOT NULL
        , [InstanceName] nvarchar(128) NOT NULL
        , [CounterType] int NOT NULL
        , [CounterValue] bigint NOT NULL
        , [CounterDelta] bigint NULL
        , [DeltaStatus] varchar(40) NOT NULL
        , [Interpretation] varchar(40) NOT NULL
        , [MetricValue] decimal(38,6) NULL
        , [MetricUnit] varchar(40) NOT NULL
        , [FindingCode] varchar(80) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ExternalRuntimeAnalysis_Findings]
    (
          [FindingOrdinal] bigint IDENTITY(1,1) NOT NULL PRIMARY KEY
        , [DatabaseName] sysname NULL
        , [ObjectType] varchar(40) NOT NULL
        , [ObjectName] nvarchar(512) NULL
        , [Severity] varchar(16) NOT NULL
        , [Confidence] varchar(16) NOT NULL
        , [FindingCode] varchar(120) NOT NULL
        , [MetricName] varchar(80) NULL
        , [MetricValue] decimal(38,4) NULL
        , [ThresholdValue] decimal(38,4) NULL
        , [Evidence] nvarchar(1000) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
        , [RecommendedNextCheck] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ExternalRuntimeAnalysis_Warnings]
    (
          [WarningCode] varchar(120) NOT NULL
        , [Detail] nvarchar(1000) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );

    BEGIN TRY
        DECLARE @LanguagePatternMode varchar(8),@LanguagePatternValue nvarchar(4000),@LanguageRegexFlags varchar(8),@LanguagePatternValid bit;
        SELECT @LanguagePatternMode=[PatternMode],@LanguagePatternValue=[PatternValue],
               @LanguageRegexFlags=[RegexFlags],@LanguagePatternValid=[IsValid]
        FROM [monitor].[TVF_ParsePattern](@LanguageNamePattern);

        IF @StatusCode='AVAILABLE'
           AND (@LanguagePatternValid=0 OR (@LanguageNames IS NOT NULL AND @LanguageNamePattern IS NOT NULL))
            SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,@ErrorMessage=N'@LanguageNamePattern ist ungültig oder wurde zusammen mit @LanguageNames angegeben.';
        IF @StatusCode='AVAILABLE' AND @LanguagePatternMode IN('REGEX','REGEXI')
           AND
           (
               COALESCE(@Major,0)<17
               OR NOT EXISTS
                  (
                      SELECT 1
                      FROM [master].[sys].[databases] [d] WITH (NOLOCK)
                      WHERE [d].[database_id]=DB_ID() AND [d].[compatibility_level]>=170
                  )
           )
            SELECT @StatusCode='UNAVAILABLE_FEATURE',@IsPartial=1,@ErrorMessage=N'Regex-Pattern benötigen SQL Server 2025 und Compatibility Level 170 in der Frameworkdatenbank.';

        IF @StatusCode='AVAILABLE'
        BEGIN
            INSERT [#ExternalRuntimeAnalysis_LanguageFilters]([ItemOrdinal],[LanguageName])
            SELECT [ItemOrdinal],[NameValue]
            FROM [monitor].[TVF_ParseSqlNameList](@LanguageNames)
            WHERE [IsValid]=1;
            IF EXISTS(SELECT 1 FROM [monitor].[TVF_ParseSqlNameList](@LanguageNames) WHERE [IsValid]=0)
                SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,@ErrorMessage=N'@LanguageNames enthält mindestens einen ungültigen SQL-Namen.';
        END;

        IF @StatusCode='AVAILABLE' AND @MitBerechtigungsanalyse=1
        BEGIN
            EXEC [monitor].[InternalCheckAnalysisPath]
                  @AnalysisClass='CATALOG_DEEP'
                , @HighImpactConfirmed=@HighImpactConfirmed
                , @StatusCode=@StatusCode OUTPUT
                , @ErrorMessage=@ErrorMessage OUTPUT;
            IF @StatusCode<>'AVAILABLE' SET @IsPartial=1;
        END;

        DECLARE @CrossDatabaseRequested bit=0;
        IF @StatusCode='AVAILABLE'
        BEGIN
            EXEC [monitor].[USP_PrepareDatabaseCandidates]
                  @DatabaseNames=@DatabaseNames
                , @SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen
                , @DatabaseNamePattern=@DatabaseNamePattern
                , @HighImpactConfirmed=@HighImpactConfirmed
                , @AnalysisClass='EXTERNAL_RUNTIME_CURRENT'
                , @StatusCode=@StatusCode OUTPUT
                , @ErrorMessage=@ErrorMessage OUTPUT
                , @CrossDatabaseRequested=@CrossDatabaseRequested OUTPUT
                , @CandidateTable=N'#ExternalRuntimeAnalysis_DatabaseCandidates'
                , @WarningTable=N'#ExternalRuntimeAnalysis_DatabaseCandidateWarnings';
            IF @StatusCode<>'AVAILABLE' SET @IsPartial=1;
        END;

        INSERT [#ExternalRuntimeAnalysis_DatabaseStatus]
        ([DatabaseName],[StatusCode],[IsPartial],[LanguageCount],[LibraryCount],[SourceFailureCount],[EvidenceLimit])
        SELECT [DatabaseName],'PENDING',0,0,0,0,N'Sichtbare Datenbankkataloge; fehlende Metadatenrechte können zu Unterzählung führen.'
        FROM [#ExternalRuntimeAnalysis_DatabaseCandidates];
        INSERT [#ExternalRuntimeAnalysis_DatabaseStatus]
        ([DatabaseName],[StatusCode],[IsPartial],[LanguageCount],[LibraryCount],[SourceFailureCount],[ErrorMessage],[EvidenceLimit])
        SELECT [RequestedName],[StatusCode],1,0,0,1,[ErrorMessage],N'Explizit angeforderte Datenbank war nicht auswertbar.'
        FROM [#ExternalRuntimeAnalysis_DatabaseCandidateWarnings];

        SET @LockTimeoutSql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(20),@LockTimeoutMs)+N';';
        EXEC [sys].[sp_executesql] @LockTimeoutSql;

        IF @StatusCode='AVAILABLE'
        BEGIN
            INSERT [#ExternalRuntimeAnalysis_Configuration]
            ([CollectedAtUtc],[ProductMajorVersion],[HostPlatform],[IsAdvancedAnalyticsInstalled],
             [ExternalScriptsConfiguredValue],[ExternalScriptsValueInUse],[LaunchpadServiceCount],
             [LaunchpadRunningCount],[LaunchpadStatus],[RequiredPerformancePermission],
             [RequiredServicePermission],[EvidenceLimit])
            SELECT @Now,@Major,@HostPlatform,
                   TRY_CONVERT(int,SERVERPROPERTY(N'IsAdvancedAnalyticsInstalled')),
                   MAX(CASE WHEN [name]=N'external scripts enabled' THEN TRY_CONVERT(int,[value]) END),
                   MAX(CASE WHEN [name]=N'external scripts enabled' THEN TRY_CONVERT(int,[value_in_use]) END),
                   NULL,NULL,'SOURCE_PENDING',@RequiredPerformancePermission,@RequiredServicePermission,
                   N'Konfiguration, Installationsproperty und Servicestatus sind getrennte Evidenz und beweisen keine Runtime-Startfähigkeit.'
            FROM [sys].[configurations] WITH (NOLOCK)
            WHERE [name]=N'external scripts enabled';
            INSERT [#ExternalRuntimeAnalysis_SourceStatus]
            VALUES(NULL,'SERVER_CONFIGURATION','AVAILABLE',0,1,N'VIEW SERVER STATE beziehungsweise Metadatensichtbarkeit',SYSUTCDATETIME(),NULL,NULL,
                   N'Nur external scripts enabled und SERVERPROPERTY(IsAdvancedAnalyticsInstalled).');

            BEGIN TRY
                DECLARE @LaunchpadServiceCount int,@LaunchpadRunningCount int;
                SELECT @LaunchpadServiceCount=COUNT_BIG(*),
                       @LaunchpadRunningCount=COALESCE(SUM(CASE WHEN [status]=4 THEN 1 ELSE 0 END),0)
                FROM [sys].[dm_server_services] WITH (NOLOCK)
                WHERE [servicename] LIKE N'%Launchpad%';
                UPDATE [#ExternalRuntimeAnalysis_Configuration]
                SET [LaunchpadServiceCount]=@LaunchpadServiceCount,
                    [LaunchpadRunningCount]=@LaunchpadRunningCount,
                    [LaunchpadStatus]=CASE WHEN @LaunchpadServiceCount=0 THEN 'NOT_VISIBLE'
                                           WHEN @LaunchpadRunningCount=@LaunchpadServiceCount THEN 'RUNNING'
                                           WHEN @LaunchpadRunningCount=0 THEN 'STOPPED'
                                           ELSE 'PARTIALLY_RUNNING' END;
                INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                VALUES(NULL,'LAUNCHPAD_SERVICE','AVAILABLE',0,@LaunchpadServiceCount,@RequiredServicePermission,SYSUTCDATETIME(),NULL,NULL,
                       N'Nur aggregierter Launchpad-Servicezustand; Dienstkonto, Pfad und Instanzname werden nicht ausgegeben.');
            END TRY
            BEGIN CATCH
                UPDATE [#ExternalRuntimeAnalysis_Configuration] SET [LaunchpadStatus]='SOURCE_UNAVAILABLE';
                INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                VALUES(NULL,'LAUNCHPAD_SERVICE',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,0,
                       @RequiredServicePermission,SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Launchpad-Status konnte nicht gelesen werden; andere Evidenz bleibt gültig.');
            END CATCH;
        END;

        DECLARE @Db sysname,@CompatibilityLevel int,@Sql nvarchar(max),@Rows bigint;
        DECLARE @LanguagePredicate nvarchar(max)=
            N' AND (NOT EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_LanguageFilters]) OR EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_LanguageFilters] [f] WHERE [f].[LanguageName]=[el].[language] COLLATE SQL_Latin1_General_CP1_CS_AS))';
        DECLARE @LibraryLanguagePredicate nvarchar(max)=
            N' AND (NOT EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_LanguageFilters]) OR EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_LanguageFilters] [f] WHERE [f].[LanguageName]=[lib].[language] COLLATE SQL_Latin1_General_CP1_CS_AS))';
        IF @LanguagePatternMode='LIKE'
        BEGIN
            SET @LanguagePredicate+=N' AND [el].[language] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @pPattern COLLATE SQL_Latin1_General_CP1_CS_AS';
            SET @LibraryLanguagePredicate+=N' AND [lib].[language] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @pPattern COLLATE SQL_Latin1_General_CP1_CS_AS';
        END;
        IF @LanguagePatternMode IN('REGEX','REGEXI')
        BEGIN
            SET @LanguagePredicate+=N' AND REGEXP_LIKE([el].[language],@pPattern,@pRegexFlags)';
            SET @LibraryLanguagePredicate+=N' AND REGEXP_LIKE([lib].[language],@pPattern,@pRegexFlags)';
        END;

        IF @StatusCode='AVAILABLE'
        BEGIN
            DECLARE [DatabaseCursor] CURSOR LOCAL FAST_FORWARD FOR
                SELECT [DatabaseName],[CompatibilityLevel]
                FROM [#ExternalRuntimeAnalysis_DatabaseCandidates]
                ORDER BY COALESCE([RequestedOrdinal],[DatabaseId]),[DatabaseId];
            OPEN [DatabaseCursor];
            FETCH NEXT FROM [DatabaseCursor] INTO @Db,@CompatibilityLevel;
            WHILE @@FETCH_STATUS=0
            BEGIN
                IF @LanguagePatternMode IN('REGEX','REGEXI') AND COALESCE(@CompatibilityLevel,0)<170
                BEGIN
                    UPDATE [#ExternalRuntimeAnalysis_DatabaseStatus]
                    SET [StatusCode]='UNAVAILABLE_FEATURE',[IsPartial]=1,[SourceFailureCount]=[SourceFailureCount]+1,
                        [ErrorMessage]=N'Regex-Pattern benötigen Compatibility Level 170.'
                    WHERE [DatabaseName]=@Db;
                    INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                    VALUES(@Db,'FILTER_CONTRACT','UNAVAILABLE_FEATURE',1,0,N'Compatibility Level 170',SYSUTCDATETIME(),NULL,N'Regex-Pattern nicht ausführbar.',N'Keine Katalogquelle wurde für diese Datenbank gelesen.');
                    FETCH NEXT FROM [DatabaseCursor] INTO @Db,@CompatibilityLevel;
                    CONTINUE;
                END;

                BEGIN TRY
                    SET @Sql=N'USE '+QUOTENAME(@Db)+N';
INSERT [#ExternalRuntimeAnalysis_Languages]
([DatabaseName],[ExternalLanguageId],[LanguageName],[CreateDate],[OwnerName],[FileName],[FilePlatformDesc],[FileMetadataStatus],[AssessmentStatus],[EvidenceLimit])
SELECT @pDatabaseName,[el].[external_language_id],[el].[language],[el].[create_date],'
 + CASE WHEN @MitBerechtigungsanalyse=1 THEN N'[dp].[name]' ELSE N'CONVERT(sysname,NULL)' END + N',
       NULL,NULL,'+CASE WHEN @MitDateimetadaten=1 THEN N'''PENDING''' ELSE N'''NOT_REQUESTED''' END+N',
       ''REGISTERED_STARTABILITY_UNVERIFIED'',
       N''Registrierung beweist weder installierte Runtime noch erfolgreiche Initialisierung.''
FROM [sys].[external_languages] [el] WITH (NOLOCK) '
 + CASE WHEN @MitBerechtigungsanalyse=1 THEN N'LEFT JOIN [sys].[database_principals] [dp] WITH (NOLOCK) ON [dp].[principal_id]=[el].[principal_id] ' ELSE N'' END
 + N'WHERE 1=1 '+@LanguagePredicate+N'; SET @pRows=@@ROWCOUNT;';
                    SET @Rows=0;
                    EXEC [sys].[sp_executesql] @Sql,
                         N'@pDatabaseName sysname,@pPattern nvarchar(4000),@pRegexFlags varchar(8),@pRows bigint OUTPUT',
                         @pDatabaseName=@Db,@pPattern=@LanguagePatternValue,@pRegexFlags=@LanguageRegexFlags,@pRows=@Rows OUTPUT;
                    INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                    VALUES(@Db,'EXTERNAL_LANGUAGES','AVAILABLE',0,@Rows,N'Metadatensichtbarkeit',SYSUTCDATETIME(),NULL,NULL,N'Keine Binärinhalte, Parameter oder Environment Variables.');
                END TRY
                BEGIN CATCH
                    INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                    VALUES(@Db,'EXTERNAL_LANGUAGES',CASE WHEN ERROR_NUMBER()=1222 THEN 'LOCK_TIMEOUT' WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER() IN(207,208) THEN 'SOURCE_UNAVAILABLE' ELSE 'ERROR_HANDLED' END,1,0,N'Metadatensichtbarkeit',SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Sprachenkatalog isoliert fehlgeschlagen.');
                END CATCH;

                IF @MitDateimetadaten=1
                BEGIN TRY
                    SET @Sql=N'USE '+QUOTENAME(@Db)+N';
INSERT [#ExternalRuntimeAnalysis_Languages]
([DatabaseName],[ExternalLanguageId],[LanguageName],[CreateDate],[OwnerName],[FileName],[FilePlatformDesc],[FileMetadataStatus],[AssessmentStatus],[EvidenceLimit])
SELECT @pDatabaseName,[el].[external_language_id],[el].[language],[el].[create_date],'
 + CASE WHEN @MitBerechtigungsanalyse=1 THEN N'[dp].[name]' ELSE N'CONVERT(sysname,NULL)' END + N',
       [elf].[file_name],[elf].[platform_desc],''AVAILABLE'',''REGISTERED_STARTABILITY_UNVERIFIED'',
       N''Nur Dateiname und Plattform; content, parameters und environment_variables sind ausgeschlossen.''
FROM [sys].[external_languages] [el] WITH (NOLOCK)
JOIN [sys].[external_language_files] [elf] WITH (NOLOCK) ON [elf].[external_language_id]=[el].[external_language_id] '
 + CASE WHEN @MitBerechtigungsanalyse=1 THEN N'LEFT JOIN [sys].[database_principals] [dp] WITH (NOLOCK) ON [dp].[principal_id]=[el].[principal_id] ' ELSE N'' END
 + N'WHERE 1=1 '+@LanguagePredicate+N';
SET @pRows=@@ROWCOUNT;
DELETE [base] FROM [#ExternalRuntimeAnalysis_Languages] [base]
WHERE [base].[DatabaseName]=@pDatabaseName AND [base].[FileMetadataStatus]=''PENDING''
  AND EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_Languages] [f]
             WHERE [f].[DatabaseName]=[base].[DatabaseName] AND [f].[ExternalLanguageId]=[base].[ExternalLanguageId]
               AND [f].[FileMetadataStatus]=''AVAILABLE'');
UPDATE [#ExternalRuntimeAnalysis_Languages] SET [FileMetadataStatus]=''NO_FILE_ROW_VISIBLE''
WHERE [DatabaseName]=@pDatabaseName AND [FileMetadataStatus]=''PENDING'';';
                    SET @Rows=0;
                    EXEC [sys].[sp_executesql] @Sql,
                         N'@pDatabaseName sysname,@pPattern nvarchar(4000),@pRegexFlags varchar(8),@pRows bigint OUTPUT',
                         @pDatabaseName=@Db,@pPattern=@LanguagePatternValue,@pRegexFlags=@LanguageRegexFlags,@pRows=@Rows OUTPUT;
                    INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                    VALUES(@Db,'EXTERNAL_LANGUAGE_FILES','AVAILABLE',0,@Rows,N'Metadatensichtbarkeit',SYSUTCDATETIME(),NULL,NULL,N'content, parameters und environment_variables werden nicht referenziert.');
                END TRY
                BEGIN CATCH
                    UPDATE [#ExternalRuntimeAnalysis_Languages] SET [FileMetadataStatus]='ERROR_HANDLED'
                    WHERE [DatabaseName]=@Db AND [FileMetadataStatus]='PENDING';
                    INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                    VALUES(@Db,'EXTERNAL_LANGUAGE_FILES',CASE WHEN ERROR_NUMBER()=1222 THEN 'LOCK_TIMEOUT' WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER() IN(207,208) THEN 'SOURCE_UNAVAILABLE' ELSE 'ERROR_HANDLED' END,1,0,N'Metadatensichtbarkeit',SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Dateimetadaten isoliert fehlgeschlagen; Sprachzeilen bleiben erhalten.');
                END CATCH;

                BEGIN TRY
                    SET @Sql=N'USE '+QUOTENAME(@Db)+N';
INSERT [#ExternalRuntimeAnalysis_Libraries]
([DatabaseName],[ExternalLibraryId],[LibraryName],[LanguageName],[ScopeDesc],[OwnerName],[FilePlatformDesc],[FileMetadataStatus],[AssessmentStatus],[EvidenceLimit])
SELECT @pDatabaseName,[lib].[external_library_id],[lib].[name],[lib].[language],[lib].[scope_desc],'
 + CASE WHEN @MitBerechtigungsanalyse=1 THEN N'[dp].[name]' ELSE N'CONVERT(sysname,NULL)' END + N',
       NULL,'+CASE WHEN @MitDateimetadaten=1 THEN N'''PENDING''' ELSE N'''NOT_REQUESTED''' END+N',
       ''REGISTERED_STARTABILITY_UNVERIFIED'',
       N''Libraryregistrierung beweist weder Packageinstallation außerhalb des Katalogs noch erfolgreiche Ausführung.''
FROM [sys].[external_libraries] [lib] WITH (NOLOCK) '
 + CASE WHEN @MitBerechtigungsanalyse=1 THEN N'LEFT JOIN [sys].[database_principals] [dp] WITH (NOLOCK) ON [dp].[principal_id]=[lib].[principal_id] ' ELSE N'' END
 + N'WHERE 1=1 '+@LibraryLanguagePredicate+N'; SET @pRows=@@ROWCOUNT;';
                    SET @Rows=0;
                    EXEC [sys].[sp_executesql] @Sql,
                         N'@pDatabaseName sysname,@pPattern nvarchar(4000),@pRegexFlags varchar(8),@pRows bigint OUTPUT',
                         @pDatabaseName=@Db,@pPattern=@LanguagePatternValue,@pRegexFlags=@LanguageRegexFlags,@pRows=@Rows OUTPUT;
                    INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                    VALUES(@Db,'EXTERNAL_LIBRARIES','AVAILABLE',0,@Rows,N'Metadatensichtbarkeit',SYSUTCDATETIME(),NULL,NULL,N'Libraryinhalt wird nicht gelesen.');
                END TRY
                BEGIN CATCH
                    INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                    VALUES(@Db,'EXTERNAL_LIBRARIES',CASE WHEN ERROR_NUMBER()=1222 THEN 'LOCK_TIMEOUT' WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER() IN(207,208) THEN 'SOURCE_UNAVAILABLE' ELSE 'ERROR_HANDLED' END,1,0,N'Metadatensichtbarkeit',SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Librarykatalog isoliert fehlgeschlagen.');
                END CATCH;

                IF @MitDateimetadaten=1
                BEGIN TRY
                    SET @Sql=N'USE '+QUOTENAME(@Db)+N';
INSERT [#ExternalRuntimeAnalysis_Libraries]
([DatabaseName],[ExternalLibraryId],[LibraryName],[LanguageName],[ScopeDesc],[OwnerName],[FilePlatformDesc],[FileMetadataStatus],[AssessmentStatus],[EvidenceLimit])
SELECT @pDatabaseName,[lib].[external_library_id],[lib].[name],[lib].[language],[lib].[scope_desc],'
 + CASE WHEN @MitBerechtigungsanalyse=1 THEN N'[dp].[name]' ELSE N'CONVERT(sysname,NULL)' END + N',
       [lf].[platform_desc],''AVAILABLE'',''REGISTERED_STARTABILITY_UNVERIFIED'',
       N''Nur Plattformmetadaten; content ist ausgeschlossen.''
FROM [sys].[external_libraries] [lib] WITH (NOLOCK)
JOIN [sys].[external_library_files] [lf] WITH (NOLOCK) ON [lf].[external_library_id]=[lib].[external_library_id] '
 + CASE WHEN @MitBerechtigungsanalyse=1 THEN N'LEFT JOIN [sys].[database_principals] [dp] WITH (NOLOCK) ON [dp].[principal_id]=[lib].[principal_id] ' ELSE N'' END
 + N'WHERE 1=1 '+@LibraryLanguagePredicate+N';
SET @pRows=@@ROWCOUNT;
DELETE [base] FROM [#ExternalRuntimeAnalysis_Libraries] [base]
WHERE [base].[DatabaseName]=@pDatabaseName AND [base].[FileMetadataStatus]=''PENDING''
  AND EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_Libraries] [f]
             WHERE [f].[DatabaseName]=[base].[DatabaseName] AND [f].[ExternalLibraryId]=[base].[ExternalLibraryId]
               AND [f].[FileMetadataStatus]=''AVAILABLE'');
UPDATE [#ExternalRuntimeAnalysis_Libraries] SET [FileMetadataStatus]=''NO_FILE_ROW_VISIBLE''
WHERE [DatabaseName]=@pDatabaseName AND [FileMetadataStatus]=''PENDING'';';
                    SET @Rows=0;
                    EXEC [sys].[sp_executesql] @Sql,
                         N'@pDatabaseName sysname,@pPattern nvarchar(4000),@pRegexFlags varchar(8),@pRows bigint OUTPUT',
                         @pDatabaseName=@Db,@pPattern=@LanguagePatternValue,@pRegexFlags=@LanguageRegexFlags,@pRows=@Rows OUTPUT;
                    INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                    VALUES(@Db,'EXTERNAL_LIBRARY_FILES','AVAILABLE',0,@Rows,N'Metadatensichtbarkeit',SYSUTCDATETIME(),NULL,NULL,N'content wird nicht referenziert.');
                END TRY
                BEGIN CATCH
                    UPDATE [#ExternalRuntimeAnalysis_Libraries] SET [FileMetadataStatus]='ERROR_HANDLED'
                    WHERE [DatabaseName]=@Db AND [FileMetadataStatus]='PENDING';
                    INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                    VALUES(@Db,'EXTERNAL_LIBRARY_FILES',CASE WHEN ERROR_NUMBER()=1222 THEN 'LOCK_TIMEOUT' WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER() IN(207,208) THEN 'SOURCE_UNAVAILABLE' ELSE 'ERROR_HANDLED' END,1,0,N'Metadatensichtbarkeit',SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Library-Dateimetadaten isoliert fehlgeschlagen.');
                END CATCH;

                UPDATE [ds]
                SET [LanguageCount]=(SELECT COUNT_BIG(DISTINCT [ExternalLanguageId]) FROM [#ExternalRuntimeAnalysis_Languages] [l] WHERE [l].[DatabaseName]=[ds].[DatabaseName]),
                    [LibraryCount]=(SELECT COUNT_BIG(DISTINCT [ExternalLibraryId]) FROM [#ExternalRuntimeAnalysis_Libraries] [l] WHERE [l].[DatabaseName]=[ds].[DatabaseName])
                FROM [#ExternalRuntimeAnalysis_DatabaseStatus] [ds]
                WHERE [ds].[DatabaseName]=@Db;

                FETCH NEXT FROM [DatabaseCursor] INTO @Db,@CompatibilityLevel;
            END;
            CLOSE [DatabaseCursor]; DEALLOCATE [DatabaseCursor];
        END;

        DECLARE @RuntimeLanguagePredicate nvarchar(max)=
            N' AND (NOT EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_LanguageFilters]) OR EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_LanguageFilters] [f] WHERE [f].[LanguageName]=[er].[language] COLLATE SQL_Latin1_General_CP1_CS_AS))';
        DECLARE @StatsLanguagePredicate nvarchar(max)=
            N' AND (NOT EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_LanguageFilters]) OR EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_LanguageFilters] [f] WHERE [f].[LanguageName]=[es].[language] COLLATE SQL_Latin1_General_CP1_CS_AS))';
        IF @LanguagePatternMode='LIKE'
        BEGIN
            SET @RuntimeLanguagePredicate+=N' AND [er].[language] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @pPattern COLLATE SQL_Latin1_General_CP1_CS_AS';
            SET @StatsLanguagePredicate+=N' AND [es].[language] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @pPattern COLLATE SQL_Latin1_General_CP1_CS_AS';
        END;
        IF @LanguagePatternMode IN('REGEX','REGEXI')
        BEGIN
            SET @RuntimeLanguagePredicate+=N' AND REGEXP_LIKE([er].[language],@pPattern,@pRegexFlags)';
            SET @StatsLanguagePredicate+=N' AND REGEXP_LIKE([es].[language],@pPattern,@pRegexFlags)';
        END;

        IF @StatusCode='AVAILABLE'
        BEGIN
            BEGIN TRY
                SET @Sql=N'INSERT [#ExternalRuntimeAnalysis_ActiveRequests]
([ExternalScriptRequestId],[LanguageName],[DegreeOfParallelism],[SessionId],[RequestId],[DatabaseName],[RequestStatus],[Command],
 [BlockingSessionId],[WaitType],[WaitTimeMs],[ElapsedTimeMs],[EngineCpuTimeMs],[Reads],[LogicalReads],[Writes],
 [LoginName],[HostName],[ProgramName],[ExternalWorkerAccount],[EvidenceLimit])
SELECT [er].[external_script_request_id],[er].[language],[er].[degree_of_parallelism],
       [r].[session_id],[r].[request_id],[d].[name],[r].[status],[r].[command],[r].[blocking_session_id],
       [r].[wait_type],[r].[wait_time],[r].[total_elapsed_time],[r].[cpu_time],[r].[reads],[r].[logical_reads],[r].[writes],'
 + CASE WHEN @MitSitzungskontext=1 THEN N'[s].[login_name],[s].[host_name],[s].[program_name],[er].[external_user_name]' ELSE N'NULL,NULL,NULL,NULL' END + N',
       N''Aktive Momentaufnahme; Engine-CPU enthält keine belegte externe Prozess-CPU und abgeschlossene Requests fehlen.''
FROM [sys].[dm_external_script_requests] [er] WITH (NOLOCK)
LEFT JOIN [sys].[dm_exec_requests] [r] WITH (NOLOCK) ON [r].[external_script_request_id]=[er].[external_script_request_id]
LEFT JOIN [sys].[dm_exec_sessions] [s] WITH (NOLOCK) ON [s].[session_id]=[r].[session_id]
LEFT JOIN [sys].[databases] [d] WITH (NOLOCK) ON [d].[database_id]=COALESCE([r].[database_id],[s].[database_id])
WHERE 1=1 '+@RuntimeLanguagePredicate+N'
  AND (COALESCE([r].[database_id],[s].[database_id]) IS NULL
       OR EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_DatabaseCandidates] [c]
                 WHERE [c].[DatabaseId]=COALESCE([r].[database_id],[s].[database_id]))); SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,
                     N'@pPattern nvarchar(4000),@pRegexFlags varchar(8),@pRows bigint OUTPUT',
                     @pPattern=@LanguagePatternValue,@pRegexFlags=@LanguageRegexFlags,@pRows=@Rows OUTPUT;
                INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                VALUES(NULL,'ACTIVE_EXTERNAL_REQUESTS','AVAILABLE',0,@Rows,@RequiredPerformancePermission,SYSUTCDATETIME(),NULL,NULL,N'Dokumentierter Join über external_script_request_id; keine Script- oder Batchtexte.');
            END TRY
            BEGIN CATCH
                INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                VALUES(NULL,'ACTIVE_EXTERNAL_REQUESTS',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER() IN(207,208) THEN 'SOURCE_UNAVAILABLE' ELSE 'ERROR_HANDLED' END,1,0,@RequiredPerformancePermission,SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Aktive Requests isoliert fehlgeschlagen.');
            END CATCH;

            SET @MeasurementStartUtc=SYSUTCDATETIME();
            BEGIN TRY
                INSERT [#ExternalRuntimeAnalysis_PoolSamples]
                SELECT 'T1',SYSUTCDATETIME(),[external_pool_id],[name],[pool_version],[max_cpu_percent],[max_processes],[max_memory_percent],
                       [statistics_start_time],[peak_memory_kb],[write_io_count],[read_io_count],[total_cpu_kernel_ms],[total_cpu_user_ms],[active_processes_count]
                FROM [sys].[dm_resource_governor_external_resource_pools] WITH (NOLOCK);
                INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                VALUES(NULL,'EXTERNAL_POOLS_T1','AVAILABLE',0,@@ROWCOUNT,@RequiredPerformancePermission,SYSUTCDATETIME(),NULL,NULL,N'Kumulative Poolwerte; Linux-Einheiten benötigen die dokumentierte Plattformgegenprüfung.');
            END TRY
            BEGIN CATCH
                INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                VALUES(NULL,'EXTERNAL_POOLS_T1',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER() IN(207,208) THEN 'SOURCE_UNAVAILABLE' ELSE 'ERROR_HANDLED' END,1,0,@RequiredPerformancePermission,SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Poolquelle isoliert fehlgeschlagen.');
            END CATCH;

            BEGIN TRY
                SET @Sql=N'INSERT [#ExternalRuntimeAnalysis_ExecutionStatSamples]
SELECT ''T1'',SYSUTCDATETIME(),[es].[language],[es].[counter_name],CONVERT(bigint,[es].[counter_value])
FROM [sys].[dm_external_script_execution_stats] [es] WITH (NOLOCK)
WHERE 1=1 '+@StatsLanguagePredicate+N'; SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,N'@pPattern nvarchar(4000),@pRegexFlags varchar(8),@pRows bigint OUTPUT',
                     @pPattern=@LanguagePatternValue,@pRegexFlags=@LanguageRegexFlags,@pRows=@Rows OUTPUT;
                INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                VALUES(NULL,'EXECUTION_STATS_T1','AVAILABLE',0,@Rows,@RequiredPerformancePermission,SYSUTCDATETIME(),NULL,NULL,N'Featuretelemetrie registrierter Funktionen; keine allgemeine Script-Ausführungshistorie.');
            END TRY
            BEGIN CATCH
                INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                VALUES(NULL,'EXECUTION_STATS_T1',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER() IN(207,208) THEN 'SOURCE_UNAVAILABLE' ELSE 'ERROR_HANDLED' END,1,0,@RequiredPerformancePermission,SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Execution-Stats-Quelle isoliert fehlgeschlagen.');
            END CATCH;

            BEGIN TRY
                INSERT [#ExternalRuntimeAnalysis_CounterSamples]
                SELECT 'T1',SYSUTCDATETIME(),[counter_name],[instance_name],[cntr_type],[cntr_value]
                FROM [sys].[dm_os_performance_counters] WITH (NOLOCK)
                WHERE [object_name] LIKE N'%External Scripts%';
                INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                VALUES(NULL,'EXTERNAL_COUNTERS_T1','AVAILABLE',0,@@ROWCOUNT,@RequiredPerformancePermission,SYSUTCDATETIME(),NULL,NULL,N'Originale SQL-Server-Counterwerte; cntr_type steuert die Interpretation.');
            END TRY
            BEGIN CATCH
                INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                VALUES(NULL,'EXTERNAL_COUNTERS_T1',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,0,@RequiredPerformancePermission,SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Performance-Counter-Quelle isoliert fehlgeschlagen.');
            END CATCH;

            IF @SampleSeconds>0
            BEGIN
                DECLARE @Delay char(8)=CONVERT(char(8),DATEADD(SECOND,@SampleSeconds,CONVERT(datetime,'19000101',112)),108);
                WAITFOR DELAY @Delay;

                BEGIN TRY
                    INSERT [#ExternalRuntimeAnalysis_PoolSamples]
                    SELECT 'T2',SYSUTCDATETIME(),[external_pool_id],[name],[pool_version],[max_cpu_percent],[max_processes],[max_memory_percent],
                           [statistics_start_time],[peak_memory_kb],[write_io_count],[read_io_count],[total_cpu_kernel_ms],[total_cpu_user_ms],[active_processes_count]
                    FROM [sys].[dm_resource_governor_external_resource_pools] WITH (NOLOCK);
                    INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                    VALUES(NULL,'EXTERNAL_POOLS_T2','AVAILABLE',0,@@ROWCOUNT,@RequiredPerformancePermission,SYSUTCDATETIME(),NULL,NULL,N'Zweiter Messpunkt desselben Samplefensters.');
                END TRY
                BEGIN CATCH
                    INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                    VALUES(NULL,'EXTERNAL_POOLS_T2',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER() IN(207,208) THEN 'SOURCE_UNAVAILABLE' ELSE 'ERROR_HANDLED' END,1,0,@RequiredPerformancePermission,SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Zweiter Poolmesspunkt isoliert fehlgeschlagen.');
                END CATCH;

                BEGIN TRY
                    SET @Sql=N'INSERT [#ExternalRuntimeAnalysis_ExecutionStatSamples]
SELECT ''T2'',SYSUTCDATETIME(),[es].[language],[es].[counter_name],CONVERT(bigint,[es].[counter_value])
FROM [sys].[dm_external_script_execution_stats] [es] WITH (NOLOCK)
WHERE 1=1 '+@StatsLanguagePredicate+N'; SET @pRows=@@ROWCOUNT;';
                    SET @Rows=0;
                    EXEC [sys].[sp_executesql] @Sql,N'@pPattern nvarchar(4000),@pRegexFlags varchar(8),@pRows bigint OUTPUT',
                         @pPattern=@LanguagePatternValue,@pRegexFlags=@LanguageRegexFlags,@pRows=@Rows OUTPUT;
                    INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                    VALUES(NULL,'EXECUTION_STATS_T2','AVAILABLE',0,@Rows,@RequiredPerformancePermission,SYSUTCDATETIME(),NULL,NULL,N'Zweiter Messpunkt der persistenten Featuretelemetrie.');
                END TRY
                BEGIN CATCH
                    INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                    VALUES(NULL,'EXECUTION_STATS_T2',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER() IN(207,208) THEN 'SOURCE_UNAVAILABLE' ELSE 'ERROR_HANDLED' END,1,0,@RequiredPerformancePermission,SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Zweiter Execution-Stats-Messpunkt isoliert fehlgeschlagen.');
                END CATCH;

                BEGIN TRY
                    INSERT [#ExternalRuntimeAnalysis_CounterSamples]
                    SELECT 'T2',SYSUTCDATETIME(),[counter_name],[instance_name],[cntr_type],[cntr_value]
                    FROM [sys].[dm_os_performance_counters] WITH (NOLOCK)
                    WHERE [object_name] LIKE N'%External Scripts%';
                    INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                    VALUES(NULL,'EXTERNAL_COUNTERS_T2','AVAILABLE',0,@@ROWCOUNT,@RequiredPerformancePermission,SYSUTCDATETIME(),NULL,NULL,N'Zweiter Messpunkt desselben Samplefensters.');
                END TRY
                BEGIN CATCH
                    INSERT [#ExternalRuntimeAnalysis_SourceStatus]
                    VALUES(NULL,'EXTERNAL_COUNTERS_T2',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,0,@RequiredPerformancePermission,SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Zweiter Countermesspunkt isoliert fehlgeschlagen.');
                END CATCH;
            END;
            SET @MeasurementEndUtc=SYSUTCDATETIME();
        END;

        INSERT [#ExternalRuntimeAnalysis_ExternalPools]
        SELECT [a].[ExternalPoolId],[a].[PoolName],COALESCE([b].[MaxCpuPercent],[a].[MaxCpuPercent]),
               COALESCE([b].[MaxProcesses],[a].[MaxProcesses]),COALESCE([b].[MaxMemoryPercent],[a].[MaxMemoryPercent]),
               COALESCE([b].[StatisticsStartTime],[a].[StatisticsStartTime]),COALESCE([b].[PeakMemoryKb],[a].[PeakMemoryKb]),
               COALESCE([b].[ActiveProcessesCount],[a].[ActiveProcessesCount]),
               CONVERT(decimal(19,6),CASE WHEN @SampleSeconds>0 THEN DATEDIFF_BIG(MICROSECOND,[a].[ReadAtUtc],[b].[ReadAtUtc])/1000000.0 END),
               CASE WHEN [b].[ExternalPoolId] IS NOT NULL AND [a].[StatisticsStartTime]=[b].[StatisticsStartTime]
                          AND [a].[PoolVersion]=[b].[PoolVersion] AND [b].[TotalCpuKernelMs]>=[a].[TotalCpuKernelMs]
                    THEN [b].[TotalCpuKernelMs]-[a].[TotalCpuKernelMs] END,
               CASE WHEN [b].[ExternalPoolId] IS NOT NULL AND [a].[StatisticsStartTime]=[b].[StatisticsStartTime]
                          AND [a].[PoolVersion]=[b].[PoolVersion] AND [b].[TotalCpuUserMs]>=[a].[TotalCpuUserMs]
                    THEN [b].[TotalCpuUserMs]-[a].[TotalCpuUserMs] END,
               CASE WHEN [b].[ExternalPoolId] IS NOT NULL AND [a].[StatisticsStartTime]=[b].[StatisticsStartTime]
                          AND [a].[PoolVersion]=[b].[PoolVersion] AND [b].[ReadIoCount]>=[a].[ReadIoCount]
                    THEN [b].[ReadIoCount]-[a].[ReadIoCount] END,
               CASE WHEN [b].[ExternalPoolId] IS NOT NULL AND [a].[StatisticsStartTime]=[b].[StatisticsStartTime]
                          AND [a].[PoolVersion]=[b].[PoolVersion] AND [b].[WriteIoCount]>=[a].[WriteIoCount]
                    THEN [b].[WriteIoCount]-[a].[WriteIoCount] END,
               CASE WHEN @SampleSeconds=0 THEN 'NOT_SAMPLED'
                    WHEN [b].[ExternalPoolId] IS NULL THEN 'T2_UNAVAILABLE'
                    WHEN [a].[StatisticsStartTime]<>[b].[StatisticsStartTime] OR [a].[PoolVersion]<>[b].[PoolVersion] THEN 'RESET_BOUNDARY'
                    WHEN [b].[TotalCpuKernelMs]<[a].[TotalCpuKernelMs] OR [b].[TotalCpuUserMs]<[a].[TotalCpuUserMs]
                      OR [b].[ReadIoCount]<[a].[ReadIoCount] OR [b].[WriteIoCount]<[a].[WriteIoCount] THEN 'RESET_BOUNDARY'
                    ELSE 'DELTA_AVAILABLE' END,
               CASE WHEN UPPER(COALESCE(@HostPlatform,N''))='LINUX'
                    THEN N'Linux bezieht Poolwerte aus cgroups; die herstellerdokumentierte Einheitenabweichung ist vor plattformübergreifenden Vergleichen zu berücksichtigen.'
                    ELSE N'Kumulative Poolwerte gelten seit statistics_start_time; Deltas werden nur innerhalb derselben Resetepoche berechnet.' END
        FROM [#ExternalRuntimeAnalysis_PoolSamples] [a]
        LEFT JOIN [#ExternalRuntimeAnalysis_PoolSamples] [b]
          ON [b].[SamplePoint]='T2' AND [b].[ExternalPoolId]=[a].[ExternalPoolId]
        WHERE [a].[SamplePoint]='T1';

        INSERT [#ExternalRuntimeAnalysis_ExecutionStats]
        SELECT [a].[LanguageName],[a].[CounterName],COALESCE([b].[CounterValue],[a].[CounterValue]),
               CASE WHEN [b].[CounterValue]>=[a].[CounterValue] THEN [b].[CounterValue]-[a].[CounterValue] END,
               CASE WHEN @SampleSeconds=0 THEN 'NOT_SAMPLED' WHEN [b].[CounterName] IS NULL THEN 'T2_UNAVAILABLE'
                    WHEN [b].[CounterValue]<[a].[CounterValue] THEN 'RESET_BOUNDARY' ELSE 'DELTA_AVAILABLE' END,
               N'Die Werte erfassen registrierte Featurefunktionen und sind keine vollständige Historie beliebiger Scripts oder Packages.'
        FROM [#ExternalRuntimeAnalysis_ExecutionStatSamples] [a]
        LEFT JOIN [#ExternalRuntimeAnalysis_ExecutionStatSamples] [b]
          ON [b].[SamplePoint]='T2' AND [b].[LanguageName]=[a].[LanguageName] AND [b].[CounterName]=[a].[CounterName]
        WHERE [a].[SamplePoint]='T1';

        INSERT [#ExternalRuntimeAnalysis_PerformanceCounters]
        SELECT [a].[CounterName],[a].[InstanceName],[a].[CounterType],COALESCE([b].[CounterValue],[a].[CounterValue]),
               CASE WHEN @SampleSeconds>0 AND [b].[CounterValue]>=[a].[CounterValue]
                    THEN [b].[CounterValue]-[a].[CounterValue] END,
               CASE WHEN @SampleSeconds=0 THEN 'NOT_SAMPLED'
                    WHEN [b].[CounterName] IS NULL THEN 'T2_UNAVAILABLE'
                    WHEN [b].[CounterValue]<[a].[CounterValue] THEN 'RESET_BOUNDARY'
                    ELSE 'DELTA_AVAILABLE' END,
               [i].[Interpretation],[i].[MetricValue],[i].[MetricUnit],[i].[FindingCode],
               N'Counterinterpretation basiert auf cntr_type; bei fehlendem zweiten Messpunkt bleibt eine Deltaaussage aus.'
        FROM [#ExternalRuntimeAnalysis_CounterSamples] [a]
        LEFT JOIN [#ExternalRuntimeAnalysis_CounterSamples] [b]
          ON [b].[SamplePoint]='T2' AND [b].[CounterName]=[a].[CounterName]
         AND [b].[InstanceName]=[a].[InstanceName] AND [b].[CounterType]=[a].[CounterType]
        CROSS APPLY [monitor].[TVF_InterpretPerformanceCounter]
        (
              [a].[CounterType],[a].[CounterValue],COALESCE([b].[CounterValue],[a].[CounterValue])
            , NULL,NULL
            , CONVERT(decimal(19,6),CASE WHEN @SampleSeconds>0 THEN DATEDIFF_BIG(MICROSECOND,[a].[ReadAtUtc],[b].[ReadAtUtc])/1000000.0 ELSE 0 END)
        ) [i]
        WHERE [a].[SamplePoint]='T1';

        INSERT [#ExternalRuntimeAnalysis_Findings]
        ([DatabaseName],[ObjectType],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
        SELECT NULL,'SERVER_CONFIGURATION',NULL,'WARN','HIGH','EXTERNAL_SCRIPTS_ENABLED_WITHOUT_INSTALLED_FEATURE_EVIDENCE',
               'IsAdvancedAnalyticsInstalled',[IsAdvancedAnalyticsInstalled],1,
               N'external scripts enabled ist aktiv, SERVERPROPERTY(IsAdvancedAnalyticsInstalled) liefert jedoch nicht 1.',
               N'Die Property beweist keine konkrete Runtimeinstallation; der Widerspruch ist eine Konfigurationsprüfung.',
               N'Installationsumfang und Launchpad-Konfiguration auf dem Host getrennt prüfen.'
        FROM [#ExternalRuntimeAnalysis_Configuration]
        WHERE [ExternalScriptsValueInUse]=1 AND COALESCE([IsAdvancedAnalyticsInstalled],0)<>1;

        INSERT [#ExternalRuntimeAnalysis_Findings]
        SELECT NULL,'LAUNCHPAD',NULL,'WARN','HIGH','LAUNCHPAD_NOT_RUNNING',
               'LaunchpadRunningCount',[LaunchpadRunningCount],[LaunchpadServiceCount],
               N'External Scripts ist aktiv, aber keine sichtbare Launchpad-Servicezeile ist im Status Running.',
               N'Der Befund setzt eine erfolgreich gelesene Servicequelle voraus; er führt keinen Starttest aus.',
               N'Servicezustand, Event Log und externe Extensibility Logs auf dem Host prüfen.'
        FROM [#ExternalRuntimeAnalysis_Configuration]
        WHERE [ExternalScriptsValueInUse]=1 AND [LaunchpadStatus] IN('NOT_VISIBLE','STOPPED','PARTIALLY_RUNNING');

        INSERT [#ExternalRuntimeAnalysis_Findings]
        SELECT [x].[DatabaseName],'DATABASE_REGISTRATION',NULL,'WARN','HIGH','REGISTERED_RUNTIME_WHILE_EXTERNAL_SCRIPTS_DISABLED',
               'RegisteredObjectCount',[x].[RegisteredObjectCount],1,
               N'Mindestens eine External Language oder Library ist sichtbar, während external scripts enabled nicht aktiv ist.',
               N'Registrierung beweist keine frühere oder aktuelle erfolgreiche Ausführung.',
               N'Prüfen, ob die Deaktivierung beabsichtigt ist und ob die registrierten Objekte noch benötigt werden.'
        FROM
        (
            SELECT [r].[DatabaseName],COUNT_BIG(*) AS [RegisteredObjectCount]
            FROM
            (
                SELECT DISTINCT [DatabaseName],'LANGUAGE' AS [ObjectType],[ExternalLanguageId] AS [ObjectId]
                FROM [#ExternalRuntimeAnalysis_Languages]
                UNION ALL
                SELECT DISTINCT [DatabaseName],'LIBRARY',[ExternalLibraryId]
                FROM [#ExternalRuntimeAnalysis_Libraries]
            ) [r]
            GROUP BY [r].[DatabaseName]
        ) [x]
        CROSS JOIN [#ExternalRuntimeAnalysis_Configuration] [c]
        WHERE COALESCE([c].[ExternalScriptsValueInUse],0)=0;

        INSERT [#ExternalRuntimeAnalysis_Findings]
        SELECT [DatabaseName],'EXTERNAL_LANGUAGE',[LanguageName],'WARN','HIGH','LANGUAGE_FILE_PLATFORM_MISMATCH',
               'PlatformMismatch',1,0,
               CONCAT(N'Die registrierte Dateiplattform ',[FilePlatformDesc],N' stimmt nicht mit HostPlatform ',COALESCE(@HostPlatform,N'<unbekannt>'),N' überein.'),
               N'Nur die registrierte Plattformmetadatenzeile wird verglichen; Binärinhalt und reale Ladefähigkeit bleiben ungeprüft.',
               N'Language-Extension-Paket und plattformspezifische Registrierung prüfen.'
        FROM [#ExternalRuntimeAnalysis_Languages]
        WHERE [FileMetadataStatus]='AVAILABLE' AND [FilePlatformDesc] IS NOT NULL
          AND UPPER([FilePlatformDesc])<>UPPER(COALESCE(@HostPlatform,N''));

        INSERT [#ExternalRuntimeAnalysis_Findings]
        SELECT [DatabaseName],'ACTIVE_REQUEST',CONVERT(nvarchar(36),[ExternalScriptRequestId]),'WARN','HIGH','ACTIVE_EXTERNAL_REQUEST_BLOCKED',
               'BlockingSessionId',[BlockingSessionId],0,
               CONCAT(N'Der aktive External-Script-Request ist durch Session ',CONVERT(nvarchar(20),[BlockingSessionId]),N' geblockt.'),
               N'Momentaufnahme; der Blockingzustand kann unmittelbar wechseln.',
               N'USP_CurrentBlocking für die vollständige Blockerkette ausführen.'
        FROM [#ExternalRuntimeAnalysis_ActiveRequests]
        WHERE COALESCE([BlockingSessionId],0)>0;

        INSERT [#ExternalRuntimeAnalysis_Findings]
        SELECT NULL,'EXTERNAL_POOL',[PoolName],'WARN','HIGH','EXTERNAL_POOL_PROCESS_LIMIT_REACHED',
               'ActiveProcessesCount',[ActiveProcessesCount],[MaxProcesses],
               N'Die aktive Prozesszahl erreicht oder überschreitet das konfigurierte, von null verschiedene max_processes.',
               N'Ein einzelner Messpunkt beweist keine anhaltende Sättigung; max_processes=0 bedeutet unbegrenzt.',
               N'Wiederholt messen und Warteschlangen, Laufzeiten sowie Resource-Governor-Zuordnung prüfen.'
        FROM [#ExternalRuntimeAnalysis_ExternalPools]
        WHERE COALESCE([MaxProcesses],0)>0 AND [ActiveProcessesCount]>=[MaxProcesses];

        INSERT [#ExternalRuntimeAnalysis_Findings]
        SELECT NULL,'PERFORMANCE_COUNTER',[CounterName],'WARN','HIGH','EXTERNAL_SCRIPT_EXECUTION_ERRORS_IN_SAMPLE',
               'CounterDelta',[CounterDelta],0,
               N'Der Counter Execution Errors ist im gültigen Samplefenster gestiegen.',
               N'Der Counter schließt laut Herstellerdokumentation nicht alle R- oder Python-Fehler ein und enthält keine Fehlerursache.',
               N'Errorlog, vorhandene Extended Events und externe Launchpad-Logs im gleichen Zeitfenster prüfen.'
        FROM [#ExternalRuntimeAnalysis_PerformanceCounters]
        WHERE [CounterName]=N'Execution Errors' AND [CounterDelta]>0
          AND [DeltaStatus]='DELTA_AVAILABLE';

        INSERT [#ExternalRuntimeAnalysis_Findings]
        SELECT [DatabaseName],'EXTERNAL_LANGUAGE',[LanguageName],'INFO','MEDIUM','REGISTERED_RUNTIME_STARTABILITY_UNVERIFIED',
               NULL,NULL,NULL,
               N'Die Language Extension ist im Datenbankkatalog registriert.',
               N'Die Analyse führt keinen externen Code aus; Installation, Abhängigkeiten und Startfähigkeit bleiben daher unverifiziert.',
               N'Installations- und Betriebsnachweise der konkreten Runtime außerhalb dieses T-SQL-Moduls prüfen.'
        FROM [#ExternalRuntimeAnalysis_Languages]
        WHERE [FileName] IS NULL OR [FileMetadataStatus]<>'AVAILABLE';

        IF UPPER(COALESCE(@HostPlatform,N''))='LINUX'
            INSERT [#ExternalRuntimeAnalysis_Warnings]
            VALUES('LINUX_EXTERNAL_POOL_UNIT_CONTRACT',N'External-Pool-Statistiken werden auf Linux aus cgroups bezogen; dokumentierte Einheitenabweichungen verhindern ungeprüfte plattformübergreifende Vergleiche.',N'Rohwerte und Deltas bleiben sichtbar, werden aber nicht pauschal als KB-, I/O- oder Millisekunden-SLA klassifiziert.');
        INSERT [#ExternalRuntimeAnalysis_Warnings]
        VALUES('EXECUTION_STATS_SCOPE',N'sys.dm_external_script_execution_stats erfasst registrierte Featurefunktionen und keine allgemeine Historie beliebiger Scripts.',N'Ein fehlender Zähler beweist weder fehlende Runtimeaktivität noch fehlerfreie Ausführung.');

        UPDATE [ds]
        SET [SourceFailureCount]=(SELECT COUNT(*) FROM [#ExternalRuntimeAnalysis_SourceStatus] [ss] WHERE [ss].[DatabaseName]=[ds].[DatabaseName] AND [ss].[IsPartial]=1),
            [IsPartial]=CONVERT(bit,CASE WHEN EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_SourceStatus] [ss] WHERE [ss].[DatabaseName]=[ds].[DatabaseName] AND [ss].[IsPartial]=1) THEN 1 ELSE 0 END),
            [StatusCode]=CASE WHEN EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_SourceStatus] [ss] WHERE [ss].[DatabaseName]=[ds].[DatabaseName] AND [ss].[IsPartial]=1) THEN 'AVAILABLE_LIMITED'
                              WHEN [LanguageCount]+[LibraryCount]=0 THEN 'NOT_APPLICABLE_VISIBLE_SCOPE' ELSE 'AVAILABLE' END
        FROM [#ExternalRuntimeAnalysis_DatabaseStatus] [ds]
        WHERE [StatusCode]='PENDING';

        IF @StatusCode='AVAILABLE'
        BEGIN
            IF EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_SourceStatus] WHERE [IsPartial]=1)
                SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
            ELSE IF EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_Findings] WHERE [Severity]='WARN')
                SET @StatusCode='AVAILABLE_WITH_FINDING';
            ELSE IF EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_Configuration] WHERE COALESCE([ExternalScriptsValueInUse],0)=0)
                SET @StatusCode=CASE WHEN EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_Languages]) OR EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_Libraries]) OR EXISTS(SELECT 1 FROM [#ExternalRuntimeAnalysis_ExecutionStats]) THEN 'FEATURE_DISABLED' ELSE 'NOT_APPLICABLE' END;
        END;

        SELECT @ErrorNumber=COALESCE(@ErrorNumber,MIN([ErrorNumber])),@ErrorMessage=COALESCE(@ErrorMessage,MIN([ErrorMessage]))
        FROM [#ExternalRuntimeAnalysis_SourceStatus] WHERE [IsPartial]=1;

        IF @MaxZeilen>0 AND
           (
               (SELECT COUNT_BIG(*) FROM [#ExternalRuntimeAnalysis_Findings] WHERE @NurProblematisch=0 OR [Severity]='WARN')>@Limit
            OR (SELECT COUNT_BIG(*) FROM [#ExternalRuntimeAnalysis_Languages])>@Limit
            OR (SELECT COUNT_BIG(*) FROM [#ExternalRuntimeAnalysis_Libraries])>@Limit
            OR (SELECT COUNT_BIG(*) FROM [#ExternalRuntimeAnalysis_ActiveRequests])>@Limit
            OR (SELECT COUNT_BIG(*) FROM [#ExternalRuntimeAnalysis_ExecutionStats])>@Limit
            OR (SELECT COUNT_BIG(*) FROM [#ExternalRuntimeAnalysis_PerformanceCounters])>@Limit
           )
        BEGIN
            INSERT [#ExternalRuntimeAnalysis_Warnings]
            VALUES('RESULTSET_TRUNCATED',N'Mindestens ein fachliches Resultset enthält mehr Zeilen als @MaxZeilen und wird erst nach globaler Sortierung begrenzt.',N'@MaxZeilen=0 liefert alle materialisierten Zeilen.');
            IF @PrintMeldungen=1 RAISERROR(N'RESULTSET_TRUNCATED: Verwenden Sie @MaxZeilen=0 oder einen höheren Wert für die vollständige Ausgabe.',10,1) WITH NOWAIT;
        END;

        IF @JsonErzeugen=1
        BEGIN
            SELECT @Json=(
                SELECT
                    JSON_QUERY((SELECT N'USP_ExternalRuntimeAnalysis' AS [module],@Now AS [collectedAtUtc],@MeasurementStartUtc AS [measurementStartUtc],@MeasurementEndUtc AS [measurementEndUtc],@StatusCode AS [statusCode],@IsPartial AS [isPartial],@ErrorNumber AS [errorNumber],@ErrorMessage AS [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER)) AS [meta],
                    JSON_QUERY(COALESCE((SELECT * FROM [#ExternalRuntimeAnalysis_Configuration] FOR JSON PATH),N'[]')) AS [configuration],
                    JSON_QUERY(COALESCE((SELECT * FROM [#ExternalRuntimeAnalysis_DatabaseStatus] ORDER BY [DatabaseName] FOR JSON PATH),N'[]')) AS [databaseStatus],
                    JSON_QUERY(COALESCE((SELECT * FROM [#ExternalRuntimeAnalysis_SourceStatus] ORDER BY [DatabaseName],[SourceCode],[ReadAtUtc] FOR JSON PATH),N'[]')) AS [sourceStatus],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ExternalRuntimeAnalysis_Findings] WHERE @NurProblematisch=0 OR [Severity]='WARN' ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[FindingOrdinal] FOR JSON PATH),N'[]')) AS [findings],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ExternalRuntimeAnalysis_Languages] ORDER BY [DatabaseName],[LanguageName],[FileName] FOR JSON PATH),N'[]')) AS [languages],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ExternalRuntimeAnalysis_Libraries] ORDER BY [DatabaseName],[LanguageName],[LibraryName] FOR JSON PATH),N'[]')) AS [libraries],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ExternalRuntimeAnalysis_ActiveRequests] ORDER BY [WaitTimeMs] DESC,[SessionId] FOR JSON PATH),N'[]')) AS [activeRequests],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ExternalRuntimeAnalysis_ExternalPools] ORDER BY [ActiveProcessesCount] DESC,[PoolName] FOR JSON PATH),N'[]')) AS [externalPools],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ExternalRuntimeAnalysis_ExecutionStats] ORDER BY [LanguageName],[CounterName] FOR JSON PATH),N'[]')) AS [executionStats],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ExternalRuntimeAnalysis_PerformanceCounters] ORDER BY [CounterName],[InstanceName] FOR JSON PATH),N'[]')) AS [performanceCounters],
                    JSON_QUERY(COALESCE((SELECT * FROM [#ExternalRuntimeAnalysis_Warnings] ORDER BY [WarningCode] FOR JSON PATH),N'[]')) AS [warnings]
                FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
        END;

        IF @OutputMode='RAW'
        BEGIN
            SELECT N'USP_ExternalRuntimeAnalysis' AS [Module],@Now AS [CollectedAtUtc],@MeasurementStartUtc AS [MeasurementStartUtc],@MeasurementEndUtc AS [MeasurementEndUtc],@StatusCode AS [StatusCode],@IsPartial AS [IsPartial],@ErrorNumber AS [ErrorNumber],@ErrorMessage AS [ErrorMessage],N'Read-only External-Runtime-Evidenz; keine Scripttexte, Parameter, Environment Variables, Binärinhalte oder Testausführung.' AS [EvidenceLimit];
            SELECT * FROM [#ExternalRuntimeAnalysis_Configuration];
            SELECT * FROM [#ExternalRuntimeAnalysis_DatabaseStatus] ORDER BY [DatabaseName];
            SELECT * FROM [#ExternalRuntimeAnalysis_SourceStatus] ORDER BY [DatabaseName],[SourceCode],[ReadAtUtc];
            SELECT TOP(@Limit) * FROM [#ExternalRuntimeAnalysis_Findings] WHERE @NurProblematisch=0 OR [Severity]='WARN' ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[FindingOrdinal];
            SELECT TOP(@Limit) * FROM [#ExternalRuntimeAnalysis_Languages] ORDER BY [DatabaseName],[LanguageName],[FileName];
            SELECT TOP(@Limit) * FROM [#ExternalRuntimeAnalysis_Libraries] ORDER BY [DatabaseName],[LanguageName],[LibraryName];
            SELECT TOP(@Limit) * FROM [#ExternalRuntimeAnalysis_ActiveRequests] ORDER BY [WaitTimeMs] DESC,[SessionId];
            SELECT TOP(@Limit) * FROM [#ExternalRuntimeAnalysis_ExternalPools] ORDER BY [ActiveProcessesCount] DESC,[PoolName];
            SELECT TOP(@Limit) * FROM [#ExternalRuntimeAnalysis_ExecutionStats] ORDER BY [LanguageName],[CounterName];
            SELECT TOP(@Limit) * FROM [#ExternalRuntimeAnalysis_PerformanceCounters] ORDER BY [CounterName],[InstanceName];
            SELECT * FROM [#ExternalRuntimeAnalysis_Warnings] ORDER BY [WarningCode];
        END;
    END TRY
    BEGIN CATCH
        SELECT @StatusCode=CASE WHEN ERROR_NUMBER()=1222 THEN 'LOCK_TIMEOUT' ELSE 'ERROR_HANDLED' END,
               @IsPartial=1,@ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE();
    END CATCH;

    SET @LockTimeoutSql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(20),@OriginalLockTimeout)+N';';
    EXEC [sys].[sp_executesql] @LockTimeoutSql;

    IF @PrintMeldungen=1 AND @StatusCode NOT IN('AVAILABLE','NOT_APPLICABLE')
    BEGIN
        SET @PrintMessage=LEFT(CONCAT(N'USP_ExternalRuntimeAnalysis: ',@StatusCode,N'. ',COALESCE(@ErrorMessage,N'Siehe strukturierte Quellenstatus.')),2048);
        RAISERROR(N'%s',10,1,@PrintMessage) WITH NOWAIT;
    END;

    SELECT @StatusCodeOut=@StatusCode,@IsPartialOut=@IsPartial,@ErrorNumberOut=@ErrorNumber,@ErrorMessageOut=@ErrorMessage;
    IF @ConsoleResultRequested=1
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#ExternalRuntimeAnalysis_Findings'
            , @ResultLabel=N'ExternalRuntimeAnalysis'
            , @EmptyMessage=N'Keine External-Runtime-Findings im gewählten Scope';
    IF @TableResultRequested=1
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable=N'#ExternalRuntimeAnalysis_Findings'
            , @TargetTable=@TableTarget
            , @ThrowOnError=1;
END;
GO
