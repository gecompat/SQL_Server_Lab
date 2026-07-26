USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ClrAnalysis
Version      : 1.0.0
Stand        : 2026-07-22
Typ          : Stored Procedure
Zweck        : Analysiert SQL-CLR-Konfiguration, benutzerdefinierte Assemblies,
               Module, Abhängigkeiten, Host Properties, AppDomains, geladene
               Assemblies, CLR Tasks, aktive Requests, Speicher und Counter.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : sys.configurations, sys.databases, sys.assemblies,
               sys.assembly_modules, sys.assembly_references,
               sys.assembly_types, sys.dm_clr_properties,
               sys.dm_clr_appdomains, sys.dm_clr_loaded_assemblies,
               sys.dm_clr_tasks, sys.dm_os_tasks, sys.dm_exec_requests,
               sys.dm_exec_sessions, sys.dm_os_memory_clerks,
               sys.dm_os_performance_counters und optional
               sys.trusted_assemblies.
Datenschutz  : Liest keine Assembly-Binärinhalte, Hashes, Moduldefinitionen,
               SQL-Texte oder Pläne. Principal- und Sitzungskontext sind
               getrennte Opt-ins.
Methodik     : Jede Server-DMV wird einmal je Messpunkt materialisiert.
               Geladene Assemblies werden über AppDomain-Datenbank und
               assembly_id vorsichtig mit sichtbaren Katalogzeilen verbunden.
Grenzen      : assembly_id ist nur innerhalb einer Datenbank eindeutig. Ohne
               Binärhash ist keine exakte Zuordnung zu trusted assemblies
               möglich; die Analyse behauptet daher keinen Trustnachweis.
Kosten       : MEDIUM; Modul- und Dependency-Kataloge skalieren mit der Zahl
               sichtbarer CLR-Objekte. Sampling wartet höchstens 60 Sekunden.
Nebenwirkung : Rein lesend; aktiviert CLR nicht und lädt keine Assembly.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_ClrAnalysis]
      @DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @AssemblyNames                    nvarchar(max)  = NULL
    , @AssemblyNamePattern              nvarchar(4000) = NULL
    , @SampleSeconds                    tinyint         = 0
    , @MitModulzuordnung                bit             = 1
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

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_ClrAnalysis';
        PRINT N'Die Procedure analysiert ausschließlich SQL CLR; die out-of-process C# Language Extension gehört zu USP_ExternalRuntimeAnalysis.';
        PRINT N'@MitModulzuordnung=1 liest sichtbare CLR-Module, Assemblyreferenzen und CLR-Typen ohne Moduldefinitionen oder Binärinhalte.';
        PRINT N'@MitBerechtigungsanalyse=1 ergänzt sichtbare Owner- und EXECUTE-AS-Principals sowie die Anzahl trusted assemblies; ein Hashabgleich bleibt ausgeschlossen.';
        PRINT N'@MitSitzungskontext=1 ergänzt Login, Host und Clientprogramm für aktive Managed-Code-Requests.';
        PRINT N'@SampleSeconds=0 liefert Counter-Momentaufnahmen; Werte von 1 bis 60 erzeugen ein Counter-Deltafenster.';
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
            OR @MitModulzuordnung IS NULL OR @MitBerechtigungsanalyse IS NULL
            OR @MitSitzungskontext IS NULL OR @NurProblematisch IS NULL
            OR @JsonErzeugen IS NULL OR @PrintMeldungen IS NULL
            OR @SampleSeconds IS NULL OR @SampleSeconds>60
            OR @MaxZeilen IS NULL OR @MaxZeilen<0
            OR @LockTimeoutMs IS NULL OR @LockTimeoutMs NOT BETWEEN 0 AND 60000)
        SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,@ErrorMessage=N'Ungültiger Bit-, Sample-, Zeilen- oder Lock-Timeout-Parameter.';

    CREATE TABLE [#ClrAnalysis_DatabaseCandidates]
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
    CREATE TABLE [#ClrAnalysis_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );
    CREATE TABLE [#ClrAnalysis_AssemblyFilters]
    (
          [ItemOrdinal] int NOT NULL
        , [AssemblyName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , PRIMARY KEY ([AssemblyName])
    );
    CREATE TABLE [#ClrAnalysis_Configuration]
    (
          [CollectedAtUtc] datetime2(3) NOT NULL
        , [ProductMajorVersion] int NULL
        , [HostPlatform] nvarchar(60) NULL
        , [ClrEnabledConfiguredValue] int NULL
        , [ClrEnabledValueInUse] int NULL
        , [ClrStrictSecurityConfiguredValue] int NULL
        , [ClrStrictSecurityValueInUse] int NULL
        , [LightweightPoolingConfiguredValue] int NULL
        , [LightweightPoolingValueInUse] int NULL
        , [TrustedAssemblyCount] bigint NULL
        , [TrustedAssemblyStatus] varchar(40) NOT NULL
        , [RequiredPerformancePermission] nvarchar(128) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ClrAnalysis_DatabaseStatus]
    (
          [DatabaseId] int NULL
        , [DatabaseName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [IsTrustworthyOn] bit NULL
        , [AssemblyCount] bigint NOT NULL
        , [HighPermissionAssemblyCount] bigint NOT NULL
        , [ModuleCount] bigint NOT NULL
        , [SourceFailureCount] int NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ClrAnalysis_SourceStatus]
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
    CREATE TABLE [#ClrAnalysis_Assemblies]
    (
          [DatabaseId] int NOT NULL
        , [DatabaseName] sysname NOT NULL
        , [AssemblyId] int NOT NULL
        , [AssemblyName] sysname NOT NULL
        , [ClrName] nvarchar(4000) NULL
        , [PermissionSetDesc] nvarchar(60) NULL
        , [IsVisible] bit NULL
        , [CreateDate] datetime NULL
        , [ModifyDate] datetime NULL
        , [OwnerName] sysname NULL
        , [IsLoaded] bit NOT NULL
        , [LastVisibleLoadTime] datetime NULL
        , [TrustVerificationStatus] varchar(40) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ClrAnalysis_AssemblyModules]
    (
          [DatabaseName] sysname NOT NULL
        , [SchemaName] sysname NOT NULL
        , [ObjectName] sysname NOT NULL
        , [ObjectType] char(2) NOT NULL
        , [ObjectTypeDesc] nvarchar(60) NULL
        , [AssemblyName] sysname NOT NULL
        , [AssemblyClass] sysname NULL
        , [AssemblyMethod] sysname NULL
        , [ExecuteAsPrincipal] sysname NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ClrAnalysis_AssemblyDependencies]
    (
          [DatabaseName] sysname NOT NULL
        , [DependencyKind] varchar(40) NOT NULL
        , [AssemblyName] sysname NOT NULL
        , [ReferencedAssemblyName] sysname NULL
        , [SchemaName] sysname NULL
        , [TypeName] sysname NULL
        , [AssemblyClass] sysname NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ClrAnalysis_Properties]
    (
          [PropertyName] nvarchar(128) NOT NULL
        , [PropertyValue] nvarchar(128) NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ClrAnalysis_AppDomains]
    (
          [AppDomainAddress] varbinary(8) NOT NULL
        , [AppDomainId] int NULL
        , [CreationTime] datetime NULL
        , [DatabaseId] int NULL
        , [DatabaseName] sysname NULL
        , [State] nvarchar(128) NULL
        , [StrongRefCount] int NULL
        , [WeakRefCount] int NULL
        , [Cost] int NULL
        , [Value] int NULL
        , [TotalProcessorTimeMs] bigint NULL
        , [TotalAllocatedMemoryKb] bigint NULL
        , [SurvivedMemoryKb] bigint NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ClrAnalysis_LoadedAssemblies]
    (
          [AppDomainAddress] varbinary(8) NOT NULL
        , [AssemblyId] int NOT NULL
        , [LoadTime] datetime NULL
        , [DatabaseId] int NULL
        , [DatabaseName] sysname NULL
        , [AppDomainId] int NULL
        , [AssemblyName] sysname NULL
        , [MappingStatus] varchar(40) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ClrAnalysis_Tasks]
    (
          [TaskAddress] varbinary(8) NOT NULL
        , [SosTaskAddress] varbinary(8) NULL
        , [AppDomainAddress] varbinary(8) NULL
        , [DatabaseName] sysname NULL
        , [AppDomainId] int NULL
        , [TaskState] nvarchar(128) NULL
        , [AbortState] nvarchar(128) NULL
        , [TaskType] nvarchar(128) NULL
        , [AffinityCount] int NULL
        , [ForcedYieldCount] int NULL
        , [SessionId] smallint NULL
        , [RequestId] int NULL
        , [MappingStatus] varchar(40) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ClrAnalysis_ActiveRequests]
    (
          [SessionId] smallint NOT NULL
        , [RequestId] int NOT NULL
        , [DatabaseName] sysname NULL
        , [RequestStatus] nvarchar(30) NULL
        , [Command] nvarchar(32) NULL
        , [BlockingSessionId] smallint NULL
        , [WaitType] nvarchar(60) NULL
        , [WaitTimeMs] int NULL
        , [ElapsedTimeMs] int NULL
        , [CpuTimeMs] int NULL
        , [Reads] bigint NULL
        , [LogicalReads] bigint NULL
        , [Writes] bigint NULL
        , [LoginName] sysname NULL
        , [HostName] nvarchar(128) NULL
        , [ProgramName] nvarchar(128) NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ClrAnalysis_Memory]
    (
          [MemoryClerkType] nvarchar(60) NOT NULL
        , [ClerkCount] bigint NOT NULL
        , [PagesKb] bigint NULL
        , [VirtualMemoryReservedKb] bigint NULL
        , [VirtualMemoryCommittedKb] bigint NULL
        , [SharedMemoryReservedKb] bigint NULL
        , [SharedMemoryCommittedKb] bigint NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ClrAnalysis_CounterSamples]
    (
          [SamplePoint] char(2) NOT NULL
        , [ReadAtUtc] datetime2(3) NOT NULL
        , [CounterName] nvarchar(128) NOT NULL
        , [InstanceName] nvarchar(128) NOT NULL
        , [CounterType] int NOT NULL
        , [CounterValue] bigint NOT NULL
    );
    CREATE TABLE [#ClrAnalysis_PerformanceCounters]
    (
          [CounterName] nvarchar(128) NOT NULL
        , [InstanceName] nvarchar(128) NOT NULL
        , [CounterType] int NOT NULL
        , [CounterValue] bigint NOT NULL
        , [Interpretation] varchar(40) NOT NULL
        , [MetricValue] decimal(38,6) NULL
        , [MetricUnit] varchar(40) NOT NULL
        , [FindingCode] varchar(80) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ClrAnalysis_Findings]
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
    CREATE TABLE [#ClrAnalysis_Warnings]
    (
          [WarningCode] varchar(120) NOT NULL
        , [Detail] nvarchar(1000) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );

    BEGIN TRY
        DECLARE @AssemblyPatternMode varchar(8),@AssemblyPatternValue nvarchar(4000),@AssemblyRegexFlags varchar(8),@AssemblyPatternValid bit;
        SELECT @AssemblyPatternMode=[PatternMode],@AssemblyPatternValue=[PatternValue],
               @AssemblyRegexFlags=[RegexFlags],@AssemblyPatternValid=[IsValid]
        FROM [monitor].[TVF_ParsePattern](@AssemblyNamePattern);
        IF @StatusCode='AVAILABLE'
           AND (@AssemblyPatternValid=0 OR (@AssemblyNames IS NOT NULL AND @AssemblyNamePattern IS NOT NULL))
            SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,@ErrorMessage=N'@AssemblyNamePattern ist ungültig oder wurde zusammen mit @AssemblyNames angegeben.';
        IF @StatusCode='AVAILABLE' AND @AssemblyPatternMode IN('REGEX','REGEXI')
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
            INSERT [#ClrAnalysis_AssemblyFilters]([ItemOrdinal],[AssemblyName])
            SELECT [ItemOrdinal],[NameValue]
            FROM [monitor].[TVF_ParseSqlNameList](@AssemblyNames)
            WHERE [IsValid]=1;
            IF EXISTS(SELECT 1 FROM [monitor].[TVF_ParseSqlNameList](@AssemblyNames) WHERE [IsValid]=0)
                SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,@ErrorMessage=N'@AssemblyNames enthält mindestens einen ungültigen SQL-Namen.';
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
                , @AnalysisClass='CLR_CURRENT'
                , @StatusCode=@StatusCode OUTPUT
                , @ErrorMessage=@ErrorMessage OUTPUT
                , @CrossDatabaseRequested=@CrossDatabaseRequested OUTPUT
                , @CandidateTable=N'#ClrAnalysis_DatabaseCandidates'
                , @WarningTable=N'#ClrAnalysis_DatabaseCandidateWarnings';
            IF @StatusCode<>'AVAILABLE' SET @IsPartial=1;
        END;

        INSERT [#ClrAnalysis_DatabaseStatus]
        ([DatabaseId],[DatabaseName],[StatusCode],[IsPartial],[IsTrustworthyOn],[AssemblyCount],[HighPermissionAssemblyCount],[ModuleCount],[SourceFailureCount],[EvidenceLimit])
        SELECT [c].[DatabaseId],[c].[DatabaseName],'PENDING',0,[d].[is_trustworthy_on],0,0,0,0,
               N'Sichtbare Katalogmetadaten; fehlende Metadata Visibility kann Assemblies oder Module ausblenden.'
        FROM [#ClrAnalysis_DatabaseCandidates] [c]
        LEFT JOIN [sys].[databases] [d] WITH (NOLOCK) ON [d].[database_id]=[c].[DatabaseId];
        INSERT [#ClrAnalysis_DatabaseStatus]
        ([DatabaseId],[DatabaseName],[StatusCode],[IsPartial],[IsTrustworthyOn],[AssemblyCount],[HighPermissionAssemblyCount],[ModuleCount],[SourceFailureCount],[ErrorMessage],[EvidenceLimit])
        SELECT NULL,[RequestedName],[StatusCode],1,NULL,0,0,0,1,[ErrorMessage],N'Explizit angeforderte Datenbank war nicht auswertbar.'
        FROM [#ClrAnalysis_DatabaseCandidateWarnings];

        SET @LockTimeoutSql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(20),@LockTimeoutMs)+N';';
        EXEC [sys].[sp_executesql] @LockTimeoutSql;

        IF @StatusCode='AVAILABLE'
        BEGIN
            INSERT [#ClrAnalysis_Configuration]
            ([CollectedAtUtc],[ProductMajorVersion],[HostPlatform],[ClrEnabledConfiguredValue],[ClrEnabledValueInUse],
             [ClrStrictSecurityConfiguredValue],[ClrStrictSecurityValueInUse],[LightweightPoolingConfiguredValue],
             [LightweightPoolingValueInUse],[TrustedAssemblyCount],[TrustedAssemblyStatus],[RequiredPerformancePermission],[EvidenceLimit])
            SELECT @Now,@Major,@HostPlatform,
                   MAX(CASE WHEN [name]=N'clr enabled' THEN TRY_CONVERT(int,[value]) END),
                   MAX(CASE WHEN [name]=N'clr enabled' THEN TRY_CONVERT(int,[value_in_use]) END),
                   MAX(CASE WHEN [name]=N'clr strict security' THEN TRY_CONVERT(int,[value]) END),
                   MAX(CASE WHEN [name]=N'clr strict security' THEN TRY_CONVERT(int,[value_in_use]) END),
                   MAX(CASE WHEN [name]=N'lightweight pooling' THEN TRY_CONVERT(int,[value]) END),
                   MAX(CASE WHEN [name]=N'lightweight pooling' THEN TRY_CONVERT(int,[value_in_use]) END),
                   NULL,CASE WHEN @MitBerechtigungsanalyse=1 THEN 'PENDING' ELSE 'NOT_REQUESTED' END,
                   @RequiredPerformancePermission,
                   N'Konfigurationswerte und Hostzustand sind getrennte Evidenz; CLR Host Properties beweisen nicht, dass Benutzer-CLR aktiviert ist.'
            FROM [sys].[configurations] WITH (NOLOCK)
            WHERE [name] IN(N'clr enabled',N'clr strict security',N'lightweight pooling');
            INSERT [#ClrAnalysis_SourceStatus]
            VALUES(NULL,'CLR_CONFIGURATION','AVAILABLE',0,1,N'VIEW SERVER STATE beziehungsweise Metadatensichtbarkeit',SYSUTCDATETIME(),NULL,NULL,N'Nur drei dokumentierte Konfigurationsoptionen.');

            IF @MitBerechtigungsanalyse=1
            BEGIN TRY
                DECLARE @TrustedCount bigint;
                SELECT @TrustedCount=COUNT_BIG(*) FROM [sys].[trusted_assemblies] WITH (NOLOCK);
                UPDATE [#ClrAnalysis_Configuration] SET [TrustedAssemblyCount]=@TrustedCount,[TrustedAssemblyStatus]='COUNT_AVAILABLE';
                INSERT [#ClrAnalysis_SourceStatus]
                VALUES(NULL,'TRUSTED_ASSEMBLIES','AVAILABLE',0,@TrustedCount,N'VIEW SERVER STATE beziehungsweise Metadatensichtbarkeit',SYSUTCDATETIME(),NULL,NULL,N'Nur Zeilenanzahl; Hash und description werden nicht gelesen.');
            END TRY
            BEGIN CATCH
                UPDATE [#ClrAnalysis_Configuration] SET [TrustedAssemblyStatus]='SOURCE_UNAVAILABLE';
                INSERT [#ClrAnalysis_SourceStatus]
                VALUES(NULL,'TRUSTED_ASSEMBLIES',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,0,N'VIEW SERVER STATE beziehungsweise Metadatensichtbarkeit',SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Trust-List-Zählung isoliert fehlgeschlagen.');
            END CATCH;

            BEGIN TRY
                INSERT [#ClrAnalysis_Properties]
                SELECT [name],[value],N'Directory- und sonstige Pfadproperties sind bewusst ausgeschlossen; Hostzustand ist kein Nachweis für clr enabled.'
                FROM [sys].[dm_clr_properties] WITH (NOLOCK)
                WHERE [name] IN(N'state',N'version');
                INSERT [#ClrAnalysis_SourceStatus]
                VALUES(NULL,'CLR_PROPERTIES','AVAILABLE',0,@@ROWCOUNT,@RequiredPerformancePermission,SYSUTCDATETIME(),NULL,NULL,N'Nur state und version; Installationsverzeichnis wird nicht gelesen.');
            END TRY
            BEGIN CATCH
                INSERT [#ClrAnalysis_SourceStatus]
                VALUES(NULL,'CLR_PROPERTIES',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,0,@RequiredPerformancePermission,SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'CLR Host Properties isoliert fehlgeschlagen.');
            END CATCH;

            BEGIN TRY
                INSERT [#ClrAnalysis_AppDomains]
                SELECT [a].[appdomain_address],[a].[appdomain_id],[a].[creation_time],[a].[db_id],[d].[name],[a].[state],
                       [a].[strong_refcount],[a].[weak_refcount],[a].[cost],[a].[value],[a].[total_processor_time_ms],
                       [a].[total_allocated_memory_kb],[a].[survived_memory_kb],
                       N'AppDomain-Momentaufnahme; creation_time ist wegen Caching nicht der Zeitpunkt einer konkreten CLR-Ausführung.'
                FROM [sys].[dm_clr_appdomains] [a] WITH (NOLOCK)
                LEFT JOIN [sys].[databases] [d] WITH (NOLOCK) ON [d].[database_id]=[a].[db_id]
                WHERE EXISTS(SELECT 1 FROM [#ClrAnalysis_DatabaseCandidates] [c] WHERE [c].[DatabaseId]=[a].[db_id]);
                INSERT [#ClrAnalysis_SourceStatus]
                VALUES(NULL,'CLR_APPDOMAINS','AVAILABLE',0,@@ROWCOUNT,@RequiredPerformancePermission,SYSUTCDATETIME(),NULL,NULL,N'AppDomain-Name und User-ID werden nicht ausgegeben.');
            END TRY
            BEGIN CATCH
                INSERT [#ClrAnalysis_SourceStatus]
                VALUES(NULL,'CLR_APPDOMAINS',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,0,@RequiredPerformancePermission,SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'AppDomainquelle isoliert fehlgeschlagen.');
            END CATCH;

            BEGIN TRY
                INSERT [#ClrAnalysis_LoadedAssemblies]
                SELECT [l].[appdomain_address],[l].[assembly_id],[l].[load_time],
                       [a].[DatabaseId],[a].[DatabaseName],[a].[AppDomainId],NULL,'CATALOG_PENDING',
                       N'assembly_id wird nur zusammen mit der über AppDomain ermittelten Datenbank korreliert.'
                FROM [sys].[dm_clr_loaded_assemblies] [l] WITH (NOLOCK)
                JOIN [#ClrAnalysis_AppDomains] [a] ON [a].[AppDomainAddress]=[l].[appdomain_address];
                INSERT [#ClrAnalysis_SourceStatus]
                VALUES(NULL,'CLR_LOADED_ASSEMBLIES','AVAILABLE',0,@@ROWCOUNT,@RequiredPerformancePermission,SYSUTCDATETIME(),NULL,NULL,N'Server-DMV; Datenbankkontext wird ausschließlich über AppDomain korreliert.');
            END TRY
            BEGIN CATCH
                INSERT [#ClrAnalysis_SourceStatus]
                VALUES(NULL,'CLR_LOADED_ASSEMBLIES',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,0,@RequiredPerformancePermission,SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Loaded-Assembly-Quelle isoliert fehlgeschlagen.');
            END CATCH;

            BEGIN TRY
                INSERT [#ClrAnalysis_Tasks]
                SELECT [t].[task_address],[t].[sos_task_address],[t].[appdomain_address],
                       [a].[DatabaseName],[a].[AppDomainId],[t].[state],[t].[abort_state],[t].[type],
                       [t].[affinity_count],[t].[forced_yield_count],[ot].[session_id],[ot].[request_id],
                       CASE WHEN [ot].[task_address] IS NULL THEN 'REQUEST_UNMAPPED' ELSE 'REQUEST_MAPPED' END,
                       N'Best-effort-Korrelation von sos_task_address zu sys.dm_os_tasks.task_address; ein CLR Task ist keine Aufrufhistorie.'
                FROM [sys].[dm_clr_tasks] [t] WITH (NOLOCK)
                LEFT JOIN [#ClrAnalysis_AppDomains] [a] ON [a].[AppDomainAddress]=[t].[appdomain_address]
                LEFT JOIN [sys].[dm_os_tasks] [ot] WITH (NOLOCK) ON [ot].[task_address]=[t].[sos_task_address]
                WHERE [a].[AppDomainAddress] IS NOT NULL;
                INSERT [#ClrAnalysis_SourceStatus]
                VALUES(NULL,'CLR_TASKS','AVAILABLE',0,@@ROWCOUNT,@RequiredPerformancePermission,SYSUTCDATETIME(),NULL,NULL,N'Adressen dienen nur der Laufzeitkorrelation; keine SQL-Texte oder Pläne.');
            END TRY
            BEGIN CATCH
                INSERT [#ClrAnalysis_SourceStatus]
                VALUES(NULL,'CLR_TASKS',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,0,@RequiredPerformancePermission,SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'CLR-Task-Quelle isoliert fehlgeschlagen.');
            END CATCH;

            BEGIN TRY
                INSERT [#ClrAnalysis_ActiveRequests]
                SELECT [r].[session_id],[r].[request_id],[d].[name],[r].[status],[r].[command],[r].[blocking_session_id],
                       [r].[wait_type],[r].[wait_time],[r].[total_elapsed_time],[r].[cpu_time],[r].[reads],[r].[logical_reads],[r].[writes],
                       CASE WHEN @MitSitzungskontext=1 THEN [s].[login_name] END,
                       CASE WHEN @MitSitzungskontext=1 THEN [s].[host_name] END,
                       CASE WHEN @MitSitzungskontext=1 THEN [s].[program_name] END,
                       N'Aktive Request-Momentaufnahme; executing_managed_code ist keine Historie und beweist keine bestimmte Assemblymethode.'
                FROM [sys].[dm_exec_requests] [r] WITH (NOLOCK)
                LEFT JOIN [sys].[dm_exec_sessions] [s] WITH (NOLOCK) ON [s].[session_id]=[r].[session_id]
                LEFT JOIN [sys].[databases] [d] WITH (NOLOCK) ON [d].[database_id]=[r].[database_id]
                WHERE [r].[executing_managed_code]=1
                  AND EXISTS(SELECT 1 FROM [#ClrAnalysis_DatabaseCandidates] [c] WHERE [c].[DatabaseId]=[r].[database_id]);
                INSERT [#ClrAnalysis_SourceStatus]
                VALUES(NULL,'MANAGED_CODE_REQUESTS','AVAILABLE',0,@@ROWCOUNT,@RequiredPerformancePermission,SYSUTCDATETIME(),NULL,NULL,N'Kein Batchtext, SQL-Text oder Plan.');
            END TRY
            BEGIN CATCH
                INSERT [#ClrAnalysis_SourceStatus]
                VALUES(NULL,'MANAGED_CODE_REQUESTS',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,0,@RequiredPerformancePermission,SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Managed-Code-Requestquelle isoliert fehlgeschlagen.');
            END CATCH;

            BEGIN TRY
                INSERT [#ClrAnalysis_Memory]
                SELECT [type],COUNT_BIG(*),SUM(CONVERT(bigint,[pages_kb])),SUM(CONVERT(bigint,[virtual_memory_reserved_kb])),
                       SUM(CONVERT(bigint,[virtual_memory_committed_kb])),SUM(CONVERT(bigint,[shared_memory_reserved_kb])),
                       SUM(CONVERT(bigint,[shared_memory_committed_kb])),
                       N'Aktuelle Memory-Clerk-Aggregation; hohe Werte werden ohne Workloadbaseline nicht pauschal als Fehler klassifiziert.'
                FROM [sys].[dm_os_memory_clerks] WITH (NOLOCK)
                WHERE [type] IN(N'MEMORYCLERK_SQLCLR',N'MEMORYCLERK_SQLCLRASSEMBLY')
                GROUP BY [type];
                INSERT [#ClrAnalysis_SourceStatus]
                VALUES(NULL,'CLR_MEMORY_CLERKS','AVAILABLE',0,@@ROWCOUNT,@RequiredPerformancePermission,SYSUTCDATETIME(),NULL,NULL,N'Nur aggregierte CLR-Clerks; keine Speicheradressen.');
            END TRY
            BEGIN CATCH
                INSERT [#ClrAnalysis_SourceStatus]
                VALUES(NULL,'CLR_MEMORY_CLERKS',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,0,@RequiredPerformancePermission,SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Memory-Clerk-Quelle isoliert fehlgeschlagen.');
            END CATCH;

            SET @MeasurementStartUtc=SYSUTCDATETIME();
            BEGIN TRY
                INSERT [#ClrAnalysis_CounterSamples]
                SELECT 'T1',SYSUTCDATETIME(),[counter_name],[instance_name],[cntr_type],[cntr_value]
                FROM [sys].[dm_os_performance_counters] WITH (NOLOCK)
                WHERE [object_name] LIKE N'%:CLR%';
                INSERT [#ClrAnalysis_SourceStatus]
                VALUES(NULL,'CLR_COUNTERS_T1','AVAILABLE',0,@@ROWCOUNT,@RequiredPerformancePermission,SYSUTCDATETIME(),NULL,NULL,N'Originale SQL-Server-Counterwerte; cntr_type steuert die Interpretation.');
            END TRY
            BEGIN CATCH
                INSERT [#ClrAnalysis_SourceStatus]
                VALUES(NULL,'CLR_COUNTERS_T1',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,0,@RequiredPerformancePermission,SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'CLR-Counterquelle isoliert fehlgeschlagen.');
            END CATCH;

            IF @SampleSeconds>0
            BEGIN
                DECLARE @Delay char(8)=CONVERT(char(8),DATEADD(SECOND,@SampleSeconds,CONVERT(datetime,'19000101',112)),108);
                WAITFOR DELAY @Delay;
                BEGIN TRY
                    INSERT [#ClrAnalysis_CounterSamples]
                    SELECT 'T2',SYSUTCDATETIME(),[counter_name],[instance_name],[cntr_type],[cntr_value]
                    FROM [sys].[dm_os_performance_counters] WITH (NOLOCK)
                    WHERE [object_name] LIKE N'%:CLR%';
                    INSERT [#ClrAnalysis_SourceStatus]
                    VALUES(NULL,'CLR_COUNTERS_T2','AVAILABLE',0,@@ROWCOUNT,@RequiredPerformancePermission,SYSUTCDATETIME(),NULL,NULL,N'Zweiter Messpunkt desselben Samplefensters.');
                END TRY
                BEGIN CATCH
                    INSERT [#ClrAnalysis_SourceStatus]
                    VALUES(NULL,'CLR_COUNTERS_T2',CASE WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,0,@RequiredPerformancePermission,SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Zweiter CLR-Countermesspunkt isoliert fehlgeschlagen.');
                END CATCH;
            END;
            SET @MeasurementEndUtc=SYSUTCDATETIME();
        END;

        DECLARE @AssemblyPredicate nvarchar(max)=
            N' AND (NOT EXISTS(SELECT 1 FROM [#ClrAnalysis_AssemblyFilters]) OR EXISTS(SELECT 1 FROM [#ClrAnalysis_AssemblyFilters] [f] WHERE [f].[AssemblyName]=[a].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
        IF @AssemblyPatternMode='LIKE'
            SET @AssemblyPredicate+=N' AND [a].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @pPattern COLLATE SQL_Latin1_General_CP1_CS_AS';
        IF @AssemblyPatternMode IN('REGEX','REGEXI')
            SET @AssemblyPredicate+=N' AND REGEXP_LIKE([a].[name],@pPattern,@pRegexFlags)';

        DECLARE @Db sysname,@DbId int,@CompatibilityLevel int,@Sql nvarchar(max),@Rows bigint;
        IF @StatusCode='AVAILABLE'
        BEGIN
            DECLARE [DatabaseCursor] CURSOR LOCAL FAST_FORWARD FOR
                SELECT [DatabaseName],[DatabaseId],[CompatibilityLevel]
                FROM [#ClrAnalysis_DatabaseCandidates]
                ORDER BY COALESCE([RequestedOrdinal],[DatabaseId]),[DatabaseId];
            OPEN [DatabaseCursor]; FETCH NEXT FROM [DatabaseCursor] INTO @Db,@DbId,@CompatibilityLevel;
            WHILE @@FETCH_STATUS=0
            BEGIN
                IF @AssemblyPatternMode IN('REGEX','REGEXI') AND COALESCE(@CompatibilityLevel,0)<170
                BEGIN
                    UPDATE [#ClrAnalysis_DatabaseStatus]
                    SET [StatusCode]='UNAVAILABLE_FEATURE',[IsPartial]=1,[SourceFailureCount]=[SourceFailureCount]+1,
                        [ErrorMessage]=N'Regex-Pattern benötigen Compatibility Level 170.'
                    WHERE [DatabaseName]=@Db;
                    INSERT [#ClrAnalysis_SourceStatus]
                    VALUES(@Db,'FILTER_CONTRACT','UNAVAILABLE_FEATURE',1,0,N'Compatibility Level 170',SYSUTCDATETIME(),NULL,N'Regex-Pattern nicht ausführbar.',N'Keine CLR-Katalogquelle wurde für diese Datenbank gelesen.');
                    FETCH NEXT FROM [DatabaseCursor] INTO @Db,@DbId,@CompatibilityLevel;
                    CONTINUE;
                END;

                BEGIN TRY
                    SET @Sql=N'USE '+QUOTENAME(@Db)+N';
INSERT [#ClrAnalysis_Assemblies]
([DatabaseId],[DatabaseName],[AssemblyId],[AssemblyName],[ClrName],[PermissionSetDesc],[IsVisible],[CreateDate],[ModifyDate],[OwnerName],[IsLoaded],[LastVisibleLoadTime],[TrustVerificationStatus],[EvidenceLimit])
SELECT @pDatabaseId,@pDatabaseName,[a].[assembly_id],[a].[name],[a].[clr_name],[a].[permission_set_desc],[a].[is_visible],[a].[create_date],[a].[modify_date],'
 + CASE WHEN @MitBerechtigungsanalyse=1 THEN N'[dp].[name]' ELSE N'CONVERT(sysname,NULL)' END + N',
       0,NULL,''NOT_EVALUATED_BINARY_EXCLUDED'',
       N''Benutzerdefinierte Assemblymetadaten; sys.assembly_files.content und Hashwerte sind ausgeschlossen.''
FROM [sys].[assemblies] [a] WITH (NOLOCK) '
 + CASE WHEN @MitBerechtigungsanalyse=1 THEN N'LEFT JOIN [sys].[database_principals] [dp] WITH (NOLOCK) ON [dp].[principal_id]=[a].[principal_id] ' ELSE N'' END
 + N'WHERE [a].[is_user_defined]=1 '+@AssemblyPredicate+N'; SET @pRows=@@ROWCOUNT;';
                    SET @Rows=0;
                    EXEC [sys].[sp_executesql] @Sql,
                         N'@pDatabaseId int,@pDatabaseName sysname,@pPattern nvarchar(4000),@pRegexFlags varchar(8),@pRows bigint OUTPUT',
                         @pDatabaseId=@DbId,@pDatabaseName=@Db,@pPattern=@AssemblyPatternValue,@pRegexFlags=@AssemblyRegexFlags,@pRows=@Rows OUTPUT;
                    INSERT [#ClrAnalysis_SourceStatus]
                    VALUES(@Db,'CLR_ASSEMBLIES','AVAILABLE',0,@Rows,N'Metadatensichtbarkeit',SYSUTCDATETIME(),NULL,NULL,N'Keine Binärinhalte oder Hashes.');
                END TRY
                BEGIN CATCH
                    INSERT [#ClrAnalysis_SourceStatus]
                    VALUES(@Db,'CLR_ASSEMBLIES',CASE WHEN ERROR_NUMBER()=1222 THEN 'LOCK_TIMEOUT' WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,0,N'Metadatensichtbarkeit',SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Assemblykatalog isoliert fehlgeschlagen.');
                END CATCH;

                IF @MitModulzuordnung=1
                BEGIN
                    BEGIN TRY
                        SET @Sql=N'USE '+QUOTENAME(@Db)+N';
INSERT [#ClrAnalysis_AssemblyModules]
([DatabaseName],[SchemaName],[ObjectName],[ObjectType],[ObjectTypeDesc],[AssemblyName],[AssemblyClass],[AssemblyMethod],[ExecuteAsPrincipal],[EvidenceLimit])
SELECT @pDatabaseName,[s].[name],[o].[name],[o].[type],[o].[type_desc],[a].[name],[am].[assembly_class],[am].[assembly_method],'
 + CASE WHEN @MitBerechtigungsanalyse=1 THEN N'[dp].[name]' ELSE N'CONVERT(sysname,NULL)' END + N',
       N''Objekt- und Implementierungsmetadaten ohne Moduldefinition oder SQL-Text.''
FROM [sys].[assembly_modules] [am] WITH (NOLOCK)
JOIN [sys].[objects] [o] WITH (NOLOCK) ON [o].[object_id]=[am].[object_id]
JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
JOIN [sys].[assemblies] [a] WITH (NOLOCK) ON [a].[assembly_id]=[am].[assembly_id] '
 + CASE WHEN @MitBerechtigungsanalyse=1 THEN N'LEFT JOIN [sys].[database_principals] [dp] WITH (NOLOCK) ON [dp].[principal_id]=[am].[execute_as_principal_id] ' ELSE N'' END
 + N'WHERE [a].[is_user_defined]=1 '+@AssemblyPredicate+N'; SET @pRows=@@ROWCOUNT;';
                        SET @Rows=0;
                        EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pPattern nvarchar(4000),@pRegexFlags varchar(8),@pRows bigint OUTPUT',
                             @pDatabaseName=@Db,@pPattern=@AssemblyPatternValue,@pRegexFlags=@AssemblyRegexFlags,@pRows=@Rows OUTPUT;
                        INSERT [#ClrAnalysis_SourceStatus]
                        VALUES(@Db,'CLR_ASSEMBLY_MODULES','AVAILABLE',0,@Rows,N'Metadatensichtbarkeit',SYSUTCDATETIME(),NULL,NULL,N'Keine Moduldefinitionen.');
                    END TRY
                    BEGIN CATCH
                        INSERT [#ClrAnalysis_SourceStatus]
                        VALUES(@Db,'CLR_ASSEMBLY_MODULES',CASE WHEN ERROR_NUMBER()=1222 THEN 'LOCK_TIMEOUT' WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,0,N'Metadatensichtbarkeit',SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Modulkatalog isoliert fehlgeschlagen.');
                    END CATCH;

                    BEGIN TRY
                        SET @Sql=N'USE '+QUOTENAME(@Db)+N';
INSERT [#ClrAnalysis_AssemblyDependencies]
([DatabaseName],[DependencyKind],[AssemblyName],[ReferencedAssemblyName],[SchemaName],[TypeName],[AssemblyClass],[EvidenceLimit])
SELECT @pDatabaseName,''ASSEMBLY_REFERENCE'',[a].[name],[ra].[name],NULL,NULL,NULL,
       N''Direkte Assemblyreferenz; rekursive oder binäre Abhängigkeiten werden nicht aufgelöst.''
FROM [sys].[assembly_references] [ar] WITH (NOLOCK)
JOIN [sys].[assemblies] [a] WITH (NOLOCK) ON [a].[assembly_id]=[ar].[assembly_id]
JOIN [sys].[assemblies] [ra] WITH (NOLOCK) ON [ra].[assembly_id]=[ar].[referenced_assembly_id]
WHERE [a].[is_user_defined]=1 '+@AssemblyPredicate+N'
UNION ALL
SELECT @pDatabaseName,''ASSEMBLY_TYPE'',[a].[name],NULL,[s].[name],[at].[name],[at].[assembly_class],
       N''Sichtbarer CLR-Typ; assembly_qualified_name und Binärinhalt sind ausgeschlossen.''
FROM [sys].[assembly_types] [at] WITH (NOLOCK)
JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[at].[schema_id]
JOIN [sys].[assemblies] [a] WITH (NOLOCK) ON [a].[assembly_id]=[at].[assembly_id]
WHERE [a].[is_user_defined]=1 '+@AssemblyPredicate+N'; SET @pRows=@@ROWCOUNT;';
                        SET @Rows=0;
                        EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pPattern nvarchar(4000),@pRegexFlags varchar(8),@pRows bigint OUTPUT',
                             @pDatabaseName=@Db,@pPattern=@AssemblyPatternValue,@pRegexFlags=@AssemblyRegexFlags,@pRows=@Rows OUTPUT;
                        INSERT [#ClrAnalysis_SourceStatus]
                        VALUES(@Db,'CLR_ASSEMBLY_DEPENDENCIES','AVAILABLE',0,@Rows,N'Metadatensichtbarkeit',SYSUTCDATETIME(),NULL,NULL,N'Direkte Referenzen und CLR-Typen; keine Binaryanalyse.');
                    END TRY
                    BEGIN CATCH
                        INSERT [#ClrAnalysis_SourceStatus]
                        VALUES(@Db,'CLR_ASSEMBLY_DEPENDENCIES',CASE WHEN ERROR_NUMBER()=1222 THEN 'LOCK_TIMEOUT' WHEN ERROR_NUMBER() IN(229,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,0,N'Metadatensichtbarkeit',SYSUTCDATETIME(),ERROR_NUMBER(),ERROR_MESSAGE(),N'Dependency-Katalog isoliert fehlgeschlagen.');
                    END CATCH;
                END;

                UPDATE [ds]
                SET [AssemblyCount]=(SELECT COUNT_BIG(*) FROM [#ClrAnalysis_Assemblies] [a] WHERE [a].[DatabaseName]=[ds].[DatabaseName]),
                    [HighPermissionAssemblyCount]=(SELECT COUNT_BIG(*) FROM [#ClrAnalysis_Assemblies] [a] WHERE [a].[DatabaseName]=[ds].[DatabaseName] AND [a].[PermissionSetDesc] IN(N'EXTERNAL_ACCESS',N'UNSAFE_ACCESS')),
                    [ModuleCount]=(SELECT COUNT_BIG(*) FROM [#ClrAnalysis_AssemblyModules] [m] WHERE [m].[DatabaseName]=[ds].[DatabaseName])
                FROM [#ClrAnalysis_DatabaseStatus] [ds] WHERE [ds].[DatabaseName]=@Db;

                FETCH NEXT FROM [DatabaseCursor] INTO @Db,@DbId,@CompatibilityLevel;
            END;
            CLOSE [DatabaseCursor]; DEALLOCATE [DatabaseCursor];
        END;

        UPDATE [l]
        SET [AssemblyName]=[a].[AssemblyName],[MappingStatus]='CATALOG_MAPPED'
        FROM [#ClrAnalysis_LoadedAssemblies] [l]
        JOIN [#ClrAnalysis_Assemblies] [a] ON [a].[DatabaseId]=[l].[DatabaseId] AND [a].[AssemblyId]=[l].[AssemblyId];
        UPDATE [a]
        SET [IsLoaded]=1,[LastVisibleLoadTime]=[x].[LoadTime]
        FROM [#ClrAnalysis_Assemblies] [a]
        CROSS APPLY
        (
            SELECT MAX([l].[LoadTime]) AS [LoadTime]
            FROM [#ClrAnalysis_LoadedAssemblies] [l]
            WHERE [l].[DatabaseId]=[a].[DatabaseId] AND [l].[AssemblyId]=[a].[AssemblyId]
        ) [x]
        WHERE [x].[LoadTime] IS NOT NULL;

        INSERT [#ClrAnalysis_PerformanceCounters]
        SELECT [a].[CounterName],[a].[InstanceName],[a].[CounterType],COALESCE([b].[CounterValue],[a].[CounterValue]),
               [i].[Interpretation],[i].[MetricValue],[i].[MetricUnit],[i].[FindingCode],
               N'Counterinterpretation basiert auf cntr_type; CLR Execution ist kumulative Laufzeit und keine per-Request-Zuordnung.'
        FROM [#ClrAnalysis_CounterSamples] [a]
        LEFT JOIN [#ClrAnalysis_CounterSamples] [b]
          ON [b].[SamplePoint]='T2' AND [b].[CounterName]=[a].[CounterName]
         AND [b].[InstanceName]=[a].[InstanceName] AND [b].[CounterType]=[a].[CounterType]
        CROSS APPLY [monitor].[TVF_InterpretPerformanceCounter]
        (
              [a].[CounterType],[a].[CounterValue],COALESCE([b].[CounterValue],[a].[CounterValue])
            , NULL,NULL
            , CONVERT(decimal(19,6),CASE WHEN @SampleSeconds>0 THEN DATEDIFF_BIG(MICROSECOND,[a].[ReadAtUtc],[b].[ReadAtUtc])/1000000.0 ELSE 0 END)
        ) [i]
        WHERE [a].[SamplePoint]='T1';

        INSERT [#ClrAnalysis_Findings]
        ([DatabaseName],[ObjectType],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
        SELECT NULL,'SERVER_CONFIGURATION',NULL,'WARN','HIGH','CLR_STRICT_SECURITY_DISABLED',
               'ClrStrictSecurityValueInUse',[ClrStrictSecurityValueInUse],1,
               N'clr strict security ist deaktiviert.',
               N'Der Befund bewertet die dokumentierte Sicherheitsoption; er beweist keine konkrete Ausnutzbarkeit einer Assembly.',
               N'Assemblysignierung, trusted assemblies, Permission Sets und dokumentierte Migrationsgründe prüfen.'
        FROM [#ClrAnalysis_Configuration]
        WHERE COALESCE([ClrStrictSecurityValueInUse],0)=0;

        INSERT [#ClrAnalysis_Findings]
        SELECT NULL,'SERVER_CONFIGURATION',NULL,'WARN','HIGH','CLR_LIGHTWEIGHT_POOLING_CONFLICT',
               'LightweightPoolingValueInUse',[LightweightPoolingValueInUse],0,
               N'clr enabled und lightweight pooling sind gleichzeitig aktiv.',
               N'SQL CLR wird nach Herstellerdokumentation unter lightweight pooling nicht unterstützt.',
               N'Eine der beiden Optionen nach Change-Control deaktivieren; dieses Analysemodul ändert keine Konfiguration.'
        FROM [#ClrAnalysis_Configuration]
        WHERE [ClrEnabledValueInUse]=1 AND [LightweightPoolingValueInUse]=1;

        INSERT [#ClrAnalysis_Findings]
        SELECT [a].[DatabaseName],'ASSEMBLY',[a].[AssemblyName],'WARN','HIGH','USER_ASSEMBLY_WHILE_CLR_DISABLED',
               'ClrEnabledValueInUse',[c].[ClrEnabledValueInUse],1,
               N'Eine benutzerdefinierte Assembly ist sichtbar, während clr enabled nicht aktiv ist.',
               N'Die Katalogzeile beweist keine aktuell geladene oder ausgeführte Assembly.',
               N'Prüfen, ob die Assembly noch benötigt wird oder CLR beabsichtigt deaktiviert ist.'
        FROM [#ClrAnalysis_Assemblies] [a]
        CROSS JOIN [#ClrAnalysis_Configuration] [c]
        WHERE COALESCE([c].[ClrEnabledValueInUse],0)=0;

        INSERT [#ClrAnalysis_Findings]
        SELECT [DatabaseName],'ASSEMBLY',[AssemblyName],'WARN','HIGH','UNSUPPORTED_CLR_PERMISSION_SET_ON_LINUX',
               'PermissionSet',CASE [PermissionSetDesc] WHEN N'EXTERNAL_ACCESS' THEN 2 WHEN N'UNSAFE_ACCESS' THEN 3 END,1,
               CONCAT(N'Die Assembly verwendet ',[PermissionSetDesc],N' auf SQL Server unter Linux.'),
               N'EXTERNAL_ACCESS und UNSAFE sind für SQL CLR unter Linux nicht unterstützt; die Analyse lädt die Assembly nicht.',
               N'Zielplattform, Permission Set und externe Abhängigkeiten vor Deployment oder Failover prüfen.'
        FROM [#ClrAnalysis_Assemblies]
        WHERE UPPER(COALESCE(@HostPlatform,N''))='LINUX' AND [PermissionSetDesc] IN(N'EXTERNAL_ACCESS',N'UNSAFE_ACCESS');

        INSERT [#ClrAnalysis_Findings]
        SELECT [a].[DatabaseName],'ASSEMBLY',[a].[AssemblyName],'WARN','HIGH','TRUSTWORTHY_DATABASE_WITH_HIGH_PERMISSION_ASSEMBLY',
               'IsTrustworthyOn',[ds].[IsTrustworthyOn],0,
               CONCAT(N'Die Datenbank ist TRUSTWORTHY ON und enthält eine Assembly mit Permission Set ',[a].[PermissionSetDesc],N'.'),
               N'Der Befund beweist keine Privilege Escalation; Owner-, Signatur- und Trustkontext sind separat zu prüfen.',
               N'Datenbankowner, Signaturen, trusted assemblies und erforderlichen Permission Set prüfen.'
        FROM [#ClrAnalysis_Assemblies] [a]
        JOIN [#ClrAnalysis_DatabaseStatus] [ds] ON [ds].[DatabaseName]=[a].[DatabaseName]
        WHERE [ds].[IsTrustworthyOn]=1 AND [a].[PermissionSetDesc] IN(N'EXTERNAL_ACCESS',N'UNSAFE_ACCESS');

        INSERT [#ClrAnalysis_Findings]
        SELECT [DatabaseName],'ASSEMBLY',[AssemblyName],'INFO','HIGH','ASSEMBLY_TRUST_MAPPING_NOT_VERIFIED',
               NULL,NULL,NULL,
               N'Die exakte Zuordnung dieser Assembly zur serverweiten Trust List wurde nicht geprüft.',
               N'Ein belastbarer Abgleich benötigt den SHA2_512-Hash des Assembly-Binärinhalts; dieser Privacy- und Kostenpfad ist ausgeschlossen.',
               N'Bei Security-Review den Hashabgleich kontrolliert außerhalb des Standardpfads durchführen.'
        FROM [#ClrAnalysis_Assemblies]
        WHERE [PermissionSetDesc] IN(N'EXTERNAL_ACCESS',N'UNSAFE_ACCESS');

        INSERT [#ClrAnalysis_Findings]
        SELECT NULL,'CLR_HOST',N'state','WARN','HIGH','CLR_HOST_INITIALIZATION_FAILED',
               NULL,NULL,NULL,
               CONCAT(N'Der CLR Host meldet den Zustand ',[PropertyValue],N'.'),
               N'sys.dm_clr_properties beschreibt den Hostzustand, nicht die Aktivierung von Benutzer-CLR.',
               N'SQL Server Errorlog, Memory Pressure und Hostinitialisierung prüfen.'
        FROM [#ClrAnalysis_Properties]
        WHERE [PropertyName]=N'state' AND [PropertyValue] LIKE N'%permanently failed%';

        INSERT [#ClrAnalysis_Findings]
        SELECT [DatabaseName],'ACTIVE_REQUEST',CONCAT(CONVERT(nvarchar(20),[SessionId]),N':',CONVERT(nvarchar(20),[RequestId])),
               'WARN','HIGH','ACTIVE_MANAGED_CODE_REQUEST_BLOCKED','BlockingSessionId',[BlockingSessionId],0,
               CONCAT(N'Der aktive Managed-Code-Request ist durch Session ',CONVERT(nvarchar(20),[BlockingSessionId]),N' geblockt.'),
               N'Momentaufnahme; executing_managed_code identifiziert keine bestimmte Assemblymethode.',
               N'USP_CurrentBlocking für die vollständige Blockerkette ausführen.'
        FROM [#ClrAnalysis_ActiveRequests]
        WHERE COALESCE([BlockingSessionId],0)>0;

        INSERT [#ClrAnalysis_Findings]
        SELECT [DatabaseName],'CLR_TASK',CONVERT(nvarchar(34),[TaskAddress],1),'INFO','MEDIUM','CLR_TASK_REQUEST_UNMAPPED',
               'ForcedYieldCount',[ForcedYieldCount],NULL,
               N'Ein aktueller CLR Task konnte nicht zu einem sichtbaren sys.dm_os_tasks-Request gemappt werden.',
               N'Task- und Requestlebenszeiten können zwischen den DMV-Lesezeitpunkten wechseln; fehlende Zuordnung ist kein Fehlerbeweis.',
               N'Bei wiederholtem Auftreten CLR Tasks, AppDomainzustand und aktuelle Requests gemeinsam erfassen.'
        FROM [#ClrAnalysis_Tasks]
        WHERE [MappingStatus]='REQUEST_UNMAPPED';

        INSERT [#ClrAnalysis_Findings]
        SELECT [DatabaseName],'LOADED_ASSEMBLY',CONVERT(nvarchar(20),[AssemblyId]),'INFO','LOW','LOADED_ASSEMBLY_CATALOG_UNMAPPED',
               NULL,NULL,NULL,
               N'Eine geladene Assembly-DMV-Zeile konnte keiner sichtbaren benutzerdefinierten Assembly im AppDomain-Datenbankkontext zugeordnet werden.',
               N'Systemassembly, Metadatensichtbarkeit, Filter oder zwischenzeitlicher Unload können die Zuordnung verhindern.',
               N'Filter und Metadatenrechte prüfen; keine globale Zuordnung nur über assembly_id vornehmen.'
        FROM [#ClrAnalysis_LoadedAssemblies]
        WHERE [MappingStatus]<>'CATALOG_MAPPED';

        INSERT [#ClrAnalysis_Warnings]
        VALUES('ASSEMBLY_TRUST_HASH_EXCLUDED',N'Die Analyse liest weder sys.assembly_files.content noch Trusted-Assembly-Hashes und kann deshalb keinen Assembly-zu-Trust-List-Nachweis erzeugen.',N'Die Anzahl trusted assemblies ist bei Opt-in nur serverweite Kontextevidenz.');
        IF UPPER(COALESCE(@HostPlatform,N''))='LINUX'
            INSERT [#ClrAnalysis_Warnings]
            VALUES('LINUX_CLR_PLATFORM_LIMIT',N'SQL CLR unter Linux unterstützt nur SAFE Assemblies; Assembly-Builds müssen weiterhin auf .NET Framework basieren.',N'Die Analyse führt keinen Lade- oder Ausführungstest durch.');

        UPDATE [ds]
        SET [SourceFailureCount]=(SELECT COUNT(*) FROM [#ClrAnalysis_SourceStatus] [ss] WHERE [ss].[DatabaseName]=[ds].[DatabaseName] AND [ss].[IsPartial]=1),
            [IsPartial]=CONVERT(bit,CASE WHEN EXISTS(SELECT 1 FROM [#ClrAnalysis_SourceStatus] [ss] WHERE [ss].[DatabaseName]=[ds].[DatabaseName] AND [ss].[IsPartial]=1) THEN 1 ELSE 0 END),
            [StatusCode]=CASE WHEN EXISTS(SELECT 1 FROM [#ClrAnalysis_SourceStatus] [ss] WHERE [ss].[DatabaseName]=[ds].[DatabaseName] AND [ss].[IsPartial]=1) THEN 'AVAILABLE_LIMITED'
                              WHEN [AssemblyCount]=0 THEN 'NOT_APPLICABLE_VISIBLE_SCOPE' ELSE 'AVAILABLE' END
        FROM [#ClrAnalysis_DatabaseStatus] [ds]
        WHERE [StatusCode]='PENDING';

        IF @StatusCode='AVAILABLE'
        BEGIN
            IF EXISTS(SELECT 1 FROM [#ClrAnalysis_SourceStatus] WHERE [IsPartial]=1)
                SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
            ELSE IF EXISTS(SELECT 1 FROM [#ClrAnalysis_Findings] WHERE [Severity]='WARN')
                SET @StatusCode='AVAILABLE_WITH_FINDING';
            ELSE IF EXISTS(SELECT 1 FROM [#ClrAnalysis_Configuration] WHERE COALESCE([ClrEnabledValueInUse],0)=0)
                 AND NOT EXISTS(SELECT 1 FROM [#ClrAnalysis_Assemblies])
                SET @StatusCode='NOT_APPLICABLE';
            ELSE IF EXISTS(SELECT 1 FROM [#ClrAnalysis_Configuration] WHERE COALESCE([ClrEnabledValueInUse],0)=0)
                SET @StatusCode='FEATURE_DISABLED';
        END;

        SELECT @ErrorNumber=COALESCE(@ErrorNumber,MIN([ErrorNumber])),@ErrorMessage=COALESCE(@ErrorMessage,MIN([ErrorMessage]))
        FROM [#ClrAnalysis_SourceStatus] WHERE [IsPartial]=1;

        IF @MaxZeilen>0 AND
           (
               (SELECT COUNT_BIG(*) FROM [#ClrAnalysis_Findings] WHERE @NurProblematisch=0 OR [Severity]='WARN')>@Limit
            OR (SELECT COUNT_BIG(*) FROM [#ClrAnalysis_Assemblies])>@Limit
            OR (SELECT COUNT_BIG(*) FROM [#ClrAnalysis_AssemblyModules])>@Limit
            OR (SELECT COUNT_BIG(*) FROM [#ClrAnalysis_AssemblyDependencies])>@Limit
            OR (SELECT COUNT_BIG(*) FROM [#ClrAnalysis_AppDomains])>@Limit
            OR (SELECT COUNT_BIG(*) FROM [#ClrAnalysis_LoadedAssemblies])>@Limit
            OR (SELECT COUNT_BIG(*) FROM [#ClrAnalysis_Tasks])>@Limit
           )
        BEGIN
            INSERT [#ClrAnalysis_Warnings]
            VALUES('RESULTSET_TRUNCATED',N'Mindestens ein fachliches Resultset enthält mehr Zeilen als @MaxZeilen und wird erst nach globaler Sortierung begrenzt.',N'@MaxZeilen=0 liefert alle materialisierten Zeilen.');
            IF @PrintMeldungen=1 RAISERROR(N'RESULTSET_TRUNCATED: Verwenden Sie @MaxZeilen=0 oder einen höheren Wert für die vollständige Ausgabe.',10,1) WITH NOWAIT;
        END;

        IF @JsonErzeugen=1
        BEGIN
            SELECT @Json=(
                SELECT
                    JSON_QUERY((SELECT N'USP_ClrAnalysis' AS [module],@Now AS [collectedAtUtc],@MeasurementStartUtc AS [measurementStartUtc],@MeasurementEndUtc AS [measurementEndUtc],@StatusCode AS [statusCode],@IsPartial AS [isPartial],@ErrorNumber AS [errorNumber],@ErrorMessage AS [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER)) AS [meta],
                    JSON_QUERY(COALESCE((SELECT * FROM [#ClrAnalysis_Configuration] FOR JSON PATH),N'[]')) AS [configuration],
                    JSON_QUERY(COALESCE((SELECT * FROM [#ClrAnalysis_DatabaseStatus] ORDER BY [DatabaseName] FOR JSON PATH),N'[]')) AS [databaseStatus],
                    JSON_QUERY(COALESCE((SELECT * FROM [#ClrAnalysis_SourceStatus] ORDER BY [DatabaseName],[SourceCode],[ReadAtUtc] FOR JSON PATH),N'[]')) AS [sourceStatus],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ClrAnalysis_Findings] WHERE @NurProblematisch=0 OR [Severity]='WARN' ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[FindingOrdinal] FOR JSON PATH),N'[]')) AS [findings],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ClrAnalysis_Assemblies] ORDER BY [DatabaseName],[AssemblyName] FOR JSON PATH),N'[]')) AS [assemblies],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ClrAnalysis_AssemblyModules] ORDER BY [DatabaseName],[SchemaName],[ObjectName] FOR JSON PATH),N'[]')) AS [assemblyModules],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ClrAnalysis_AssemblyDependencies] ORDER BY [DatabaseName],[AssemblyName],[DependencyKind] FOR JSON PATH),N'[]')) AS [assemblyDependencies],
                    JSON_QUERY(COALESCE((SELECT * FROM [#ClrAnalysis_Properties] ORDER BY [PropertyName] FOR JSON PATH),N'[]')) AS [clrProperties],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ClrAnalysis_AppDomains] ORDER BY [TotalProcessorTimeMs] DESC,[DatabaseName],[AppDomainId] FOR JSON PATH),N'[]')) AS [appDomains],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ClrAnalysis_LoadedAssemblies] ORDER BY [LoadTime] DESC,[DatabaseName],[AssemblyName] FOR JSON PATH),N'[]')) AS [loadedAssemblies],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ClrAnalysis_Tasks] ORDER BY [ForcedYieldCount] DESC,[DatabaseName] FOR JSON PATH),N'[]')) AS [clrTasks],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ClrAnalysis_ActiveRequests] ORDER BY [WaitTimeMs] DESC,[SessionId],[RequestId] FOR JSON PATH),N'[]')) AS [activeRequests],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ClrAnalysis_Memory] ORDER BY [PagesKb] DESC,[MemoryClerkType] FOR JSON PATH),N'[]')) AS [memory],
                    JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ClrAnalysis_PerformanceCounters] ORDER BY [CounterName],[InstanceName] FOR JSON PATH),N'[]')) AS [performanceCounters],
                    JSON_QUERY(COALESCE((SELECT * FROM [#ClrAnalysis_Warnings] ORDER BY [WarningCode] FOR JSON PATH),N'[]')) AS [warnings]
                FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
        END;

        IF @OutputMode='RAW'
        BEGIN
            SELECT N'USP_ClrAnalysis' AS [Module],@Now AS [CollectedAtUtc],@MeasurementStartUtc AS [MeasurementStartUtc],@MeasurementEndUtc AS [MeasurementEndUtc],@StatusCode AS [StatusCode],@IsPartial AS [IsPartial],@ErrorNumber AS [ErrorNumber],@ErrorMessage AS [ErrorMessage],N'Read-only SQL-CLR-Evidenz; keine Assembly-Binaries, Hashes, Moduldefinitionen, SQL-Texte, Pläne oder Testausführung.' AS [EvidenceLimit];
            SELECT * FROM [#ClrAnalysis_Configuration];
            SELECT * FROM [#ClrAnalysis_DatabaseStatus] ORDER BY [DatabaseName];
            SELECT * FROM [#ClrAnalysis_SourceStatus] ORDER BY [DatabaseName],[SourceCode],[ReadAtUtc];
            SELECT TOP(@Limit) * FROM [#ClrAnalysis_Findings] WHERE @NurProblematisch=0 OR [Severity]='WARN' ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[FindingOrdinal];
            SELECT TOP(@Limit) * FROM [#ClrAnalysis_Assemblies] ORDER BY [DatabaseName],[AssemblyName];
            SELECT TOP(@Limit) * FROM [#ClrAnalysis_AssemblyModules] ORDER BY [DatabaseName],[SchemaName],[ObjectName];
            SELECT TOP(@Limit) * FROM [#ClrAnalysis_AssemblyDependencies] ORDER BY [DatabaseName],[AssemblyName],[DependencyKind];
            SELECT * FROM [#ClrAnalysis_Properties] ORDER BY [PropertyName];
            SELECT TOP(@Limit) * FROM [#ClrAnalysis_AppDomains] ORDER BY [TotalProcessorTimeMs] DESC,[DatabaseName],[AppDomainId];
            SELECT TOP(@Limit) * FROM [#ClrAnalysis_LoadedAssemblies] ORDER BY [LoadTime] DESC,[DatabaseName],[AssemblyName];
            SELECT TOP(@Limit) * FROM [#ClrAnalysis_Tasks] ORDER BY [ForcedYieldCount] DESC,[DatabaseName];
            SELECT TOP(@Limit) * FROM [#ClrAnalysis_ActiveRequests] ORDER BY [WaitTimeMs] DESC,[SessionId],[RequestId];
            SELECT TOP(@Limit) * FROM [#ClrAnalysis_Memory] ORDER BY [PagesKb] DESC,[MemoryClerkType];
            SELECT TOP(@Limit) * FROM [#ClrAnalysis_PerformanceCounters] ORDER BY [CounterName],[InstanceName];
            SELECT * FROM [#ClrAnalysis_Warnings] ORDER BY [WarningCode];
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
        SET @PrintMessage=LEFT(CONCAT(N'USP_ClrAnalysis: ',@StatusCode,N'. ',COALESCE(@ErrorMessage,N'Siehe strukturierte Quellenstatus.')),2048);
        RAISERROR(N'%s',10,1,@PrintMessage) WITH NOWAIT;
    END;
    SELECT @StatusCodeOut=@StatusCode,@IsPartialOut=@IsPartial,@ErrorNumberOut=@ErrorNumber,@ErrorMessageOut=@ErrorMessage;
    IF @ConsoleResultRequested=1
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#ClrAnalysis_Findings'
            , @ResultLabel=N'ClrAnalysis'
            , @EmptyMessage=N'Keine SQL-CLR-Findings im gewählten Scope';
    IF @TableResultRequested=1
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable=N'#ClrAnalysis_Findings'
            , @TargetTable=@TableTarget
            , @ThrowOnError=1;
END;
GO
