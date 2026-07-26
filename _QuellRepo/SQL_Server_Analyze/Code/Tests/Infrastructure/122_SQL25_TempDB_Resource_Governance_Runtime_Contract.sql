USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 122_SQL25_TempDB_Resource_Governance_Runtime_Contract.sql
Zweck        : Prüft SQL25-003 auf SQL Server 2019, 2022 und 2025:
               Versions-/Schemagrenze, Kein-Limit-, MB-/Prozent- und
               Vorrangsemantik, aktuelle/Peak-Nutzung, Verletzungs- und
               Resetfenster, eingeschränkte Rechte, TABLE/JSON,
               CurrentOverview-Routing und LOCK_TIMEOUT-Wiederherstellung.
Datenschutz  : Ausschließlich kurzlebige generische Example*-Workload-Groups
               und ein synthetischer Benutzer ohne Login. Querytexte, Pläne,
               Zugangsdaten, externe Systeme und Nutzdaten werden nicht
               verwendet.
Nebenwirkung : Im isolierten SQL-Server-2025-CI-Lauf werden drei synthetische
               Workload Groups angelegt, Resource Governor reconfiguriert und
               dessen Statistiken einmal zurückgesetzt. Groups, Benutzer und
               ursprünglicher Enable-Zustand werden im Erfolgs- und Fehlerpfad
               wiederhergestellt.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ProductMajorVersion int=
    TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'));
DECLARE @OriginalLockTimeout int=@@LOCK_TIMEOUT;
DECLARE @OriginalResourceGovernorEnabled bit=NULL;
DECLARE @ResourceGovernorStateCaptured bit=0;
DECLARE @CatalogColumnsValid bit=0;
DECLARE @RuntimeColumnsValid bit=0;
DECLARE @GroupsCreated bit=0;
DECLARE @Impersonating bit=0;
DECLARE @Sql nvarchar(max);
DECLARE @CurrentJson nvarchar(max);
DECLARE @ResourceGovernorJson nvarchar(max);
DECLARE @RestrictedJson nvarchar(max);
DECLARE @OverviewJson nvarchar(max);
DECLARE @BeforeResetStatisticsStartTime datetime;
DECLARE @ExecutedCases TABLE
(
    [CaseId] varchar(80) NOT NULL PRIMARY KEY
);

CREATE TABLE [#SQL25TempDBResourceGovernanceRuntimeContract_CurrentTempDB]([Seed] bit NULL);
CREATE TABLE [#SQL25TempDBResourceGovernanceRuntimeContract_ResourceGovernor]([Seed] bit NULL);
CREATE TABLE [#SQL25TempDBResourceGovernanceRuntimeContract_CurrentOverview]([Seed] bit NULL);
CREATE TABLE [#SQL25TempDBResourceGovernanceRuntimeContract_ActiveCurrentTempDB]([Seed] bit NULL);
CREATE TABLE [#SQL25TempDBResourceGovernanceRuntimeContract_ActiveResourceGovernor]([Seed] bit NULL);
CREATE TABLE [#SQL25TempDBResourceGovernanceRuntimeContract_ResetResourceGovernor]([Seed] bit NULL);

BEGIN TRY
    SET @Sql=N'    SET LOCK_TIMEOUT 731;
    EXEC [monitor].[USP_CurrentTempDB]
          @MitDateien=0
        , @MaxZeilen=50
        , @ResultSetArt=''TABLE''
        , @ResultTablesJson=
              N''{"tempdbGovernance":"#SQL25TempDBResourceGovernanceRuntimeContract_CurrentTempDB"}''
        , @JsonErzeugen=1
        , @Json=@OutputJson OUTPUT
        , @PrintMeldungen=0;

    IF @@LOCK_TIMEOUT<>731
        THROW 55820,N''SQL25-003 CurrentTempDB stellt LOCK_TIMEOUT nicht wieder her.'',1;';
    EXEC [sys].[sp_executesql] @Sql
        , N'@OutputJson nvarchar(max) OUTPUT'
        , @OutputJson=@CurrentJson OUTPUT;
    IF ISJSON(@CurrentJson)<>1
       OR JSON_QUERY(@CurrentJson,N'$.tempdbGovernance') IS NULL
       OR NOT EXISTS
          (
              SELECT 1
              FROM [#SQL25TempDBResourceGovernanceRuntimeContract_CurrentTempDB]
              WHERE [SourceStatusCode] IS NOT NULL
                AND [EffectiveLimitSource] IS NOT NULL
          )
        THROW 55821,N'SQL25-003 CurrentTempDB TABLE-/JSON-Grundvertrag fehlt.',1;
    INSERT @ExecutedCases VALUES('CURRENT-TEMPDB-TABLE-JSON');

    SET @Sql=N'    SET LOCK_TIMEOUT 733;
    EXEC [monitor].[USP_ResourceGovernorAnalysis]
          @MitSessions=0
        , @MaxZeilen=50
        , @ResultSetArt=''TABLE''
        , @ResultTablesJson=
              N''{"tempdbGovernance":"#SQL25TempDBResourceGovernanceRuntimeContract_ResourceGovernor"}''
        , @JsonErzeugen=1
        , @Json=@OutputJson OUTPUT
        , @PrintMeldungen=0;

    IF @@LOCK_TIMEOUT<>733
        THROW 55822,N''SQL25-003 ResourceGovernorAnalysis stellt LOCK_TIMEOUT nicht wieder her.'',1;';
    EXEC [sys].[sp_executesql] @Sql
        , N'@OutputJson nvarchar(max) OUTPUT'
        , @OutputJson=@ResourceGovernorJson OUTPUT;
    IF ISJSON(@ResourceGovernorJson)<>1
       OR JSON_QUERY(@ResourceGovernorJson,N'$.tempdbGovernance') IS NULL
       OR NOT EXISTS
          (
              SELECT 1
              FROM [#SQL25TempDBResourceGovernanceRuntimeContract_ResourceGovernor]
              WHERE [SourceStatusCode] IS NOT NULL
                AND [EffectiveLimitSource] IS NOT NULL
          )
        THROW 55823,N'SQL25-003 ResourceGovernorAnalysis TABLE-/JSON-Grundvertrag fehlt.',1;
    INSERT @ExecutedCases VALUES('RESOURCE-GOVERNOR-TABLE-JSON');

    SET @Sql=N'    SET LOCK_TIMEOUT 735;
    EXEC [monitor].[USP_CurrentOverview]
          @MitSessions=0
        , @MitRequests=0
        , @MitBlocking=0
        , @MitWaits=0
        , @MitTransactions=0
        , @MitMemoryGrants=0
        , @MitTempDB=1
        , @MitIO=0
        , @MitLog=0
        , @MitSqlText=0
        , @MaxZeilen=50
        , @ResultSetArt=''TABLE''
        , @ResultTablesJson=
              N''{"tempdbGovernance":"#SQL25TempDBResourceGovernanceRuntimeContract_CurrentOverview"}''
        , @JsonErzeugen=1
        , @Json=@OutputJson OUTPUT
        , @PrintMeldungen=0;

    IF @@LOCK_TIMEOUT<>735
        THROW 55824,N''SQL25-003 CurrentOverview stellt LOCK_TIMEOUT nicht wieder her.'',1;';
    EXEC [sys].[sp_executesql] @Sql
        , N'@OutputJson nvarchar(max) OUTPUT'
        , @OutputJson=@OverviewJson OUTPUT;
    IF ISJSON(@OverviewJson)<>1
       OR JSON_QUERY(@OverviewJson,N'$.tempdbSessions.tempdbGovernance') IS NULL
       OR NOT EXISTS
          (
              SELECT 1
              FROM [#SQL25TempDBResourceGovernanceRuntimeContract_CurrentOverview]
              WHERE [SourceStatusCode] IS NOT NULL
          )
        THROW 55825,N'SQL25-003 CurrentOverview-Parent-Routing fehlt.',1;
    INSERT @ExecutedCases VALUES('CURRENT-OVERVIEW-PARENT-ROUTING');

    IF @ProductMajorVersion IS NULL OR @ProductMajorVersion<17
    BEGIN
        IF EXISTS
           (
               SELECT 1
               FROM [#SQL25TempDBResourceGovernanceRuntimeContract_CurrentTempDB]
               WHERE [SourceStatusCode]<>'UNAVAILABLE_VERSION'
                  OR [IsPartial]<>1
                  OR [EffectiveLimitSource]<>'UNAVAILABLE'
           )
           OR EXISTS
           (
               SELECT 1
               FROM [#SQL25TempDBResourceGovernanceRuntimeContract_ResourceGovernor]
               WHERE [SourceStatusCode]<>'UNAVAILABLE_VERSION'
                  OR [IsPartial]<>1
                  OR [EffectiveLimitSource]<>'UNAVAILABLE'
           )
           OR EXISTS
           (
               SELECT 1
               FROM [#SQL25TempDBResourceGovernanceRuntimeContract_CurrentOverview]
               WHERE [SourceStatusCode]<>'UNAVAILABLE_VERSION'
                  OR [IsPartial]<>1
           )
            THROW 55826,N'SQL25-003 Versionsgrenze ist auf SQL Server 2019/2022 nicht explizit.',1;

        INSERT @ExecutedCases VALUES('UNAVAILABLE-VERSION');
    END
    ELSE
    BEGIN
        BEGIN TRY
            SELECT
                  @CatalogColumnsValid=CONVERT
                  (
                      bit,
                      CASE WHEN SUM
                           (
                               CASE
                                   WHEN [o].[name]=N'resource_governor_workload_groups'
                                    AND [c].[name] IN
                                        (N'group_max_tempdb_data_mb',
                                         N'group_max_tempdb_data_percent')
                                       THEN 1 ELSE 0
                               END
                           )=2 THEN 1 ELSE 0 END
                  )
                , @RuntimeColumnsValid=CONVERT
                  (
                      bit,
                      CASE WHEN SUM
                           (
                               CASE
                                   WHEN [o].[name]=N'dm_resource_governor_workload_groups'
                                    AND [c].[name] IN
                                        (N'tempdb_data_space_kb',
                                         N'peak_tempdb_data_space_kb',
                                         N'total_tempdb_data_limit_violation_count')
                                       THEN 1 ELSE 0
                               END
                           )=3 THEN 1 ELSE 0 END
                  )
            FROM [sys].[all_columns] AS [c] WITH (NOLOCK)
            INNER JOIN [sys].[all_objects] AS [o] WITH (NOLOCK)
              ON [o].[object_id]=[c].[object_id]
            INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
              ON [s].[schema_id]=[o].[schema_id]
            WHERE [s].[name]=N'sys'
              AND [o].[name] IN
                  (N'resource_governor_workload_groups',
                   N'dm_resource_governor_workload_groups');
        END TRY
        BEGIN CATCH
            SELECT @CatalogColumnsValid=0,@RuntimeColumnsValid=0;
        END CATCH;

        IF @CatalogColumnsValid=0 OR @RuntimeColumnsValid=0
        BEGIN
            IF EXISTS
               (
                   SELECT 1
                   FROM [#SQL25TempDBResourceGovernanceRuntimeContract_CurrentTempDB]
                   WHERE [SourceStatusCode] NOT IN
                         ('UNAVAILABLE_SOURCE_SCHEMA','DENIED_PERMISSION',
                          'TIMEOUT','ERROR_HANDLED','AVAILABLE_LIMITED')
                      OR [IsPartial]<>1
               )
               OR EXISTS
               (
                   SELECT 1
                   FROM [#SQL25TempDBResourceGovernanceRuntimeContract_ResourceGovernor]
                   WHERE [SourceStatusCode] NOT IN
                         ('UNAVAILABLE_SOURCE_SCHEMA','DENIED_PERMISSION',
                          'TIMEOUT','ERROR_HANDLED','AVAILABLE_LIMITED')
                      OR [IsPartial]<>1
               )
                THROW 55827,N'SQL25-003 fehlendes SQL-2025-Quellschema wird nicht explizit begrenzt.',1;

            INSERT @ExecutedCases VALUES('EXPLICIT-SOURCE-SCHEMA-BOUNDARY');
        END
        ELSE
        BEGIN
            SELECT
                  @OriginalResourceGovernorEnabled=[is_enabled]
                , @ResourceGovernorStateCaptured=1
            FROM [sys].[resource_governor_configuration] WITH (NOLOCK);

            IF EXISTS
               (
                   SELECT 1
                   FROM [sys].[resource_governor_workload_groups] WITH (NOLOCK)
                   WHERE [name] IN
                         (N'ExampleTempdbGovernanceNoLimit',
                          N'ExampleTempdbGovernanceMb',
                          N'ExampleTempdbGovernancePercent')
               )
            BEGIN
                SET @Sql=N'';
                IF EXISTS
                   (
                       SELECT 1
                       FROM [sys].[resource_governor_workload_groups] WITH (NOLOCK)
                       WHERE [name]=N'ExampleTempdbGovernanceNoLimit'
                   )
                    SET @Sql+=N'DROP WORKLOAD GROUP [ExampleTempdbGovernanceNoLimit];';
                IF EXISTS
                   (
                       SELECT 1
                       FROM [sys].[resource_governor_workload_groups] WITH (NOLOCK)
                       WHERE [name]=N'ExampleTempdbGovernanceMb'
                   )
                    SET @Sql+=N'DROP WORKLOAD GROUP [ExampleTempdbGovernanceMb];';
                IF EXISTS
                   (
                       SELECT 1
                       FROM [sys].[resource_governor_workload_groups] WITH (NOLOCK)
                       WHERE [name]=N'ExampleTempdbGovernancePercent'
                   )
                    SET @Sql+=N'DROP WORKLOAD GROUP [ExampleTempdbGovernancePercent];';
                SET @Sql+=N'ALTER RESOURCE GOVERNOR RECONFIGURE;';
                EXEC [sys].[sp_executesql] @Sql;
            END;

            SET @Sql=N'
CREATE WORKLOAD GROUP [ExampleTempdbGovernanceNoLimit] USING [default];
CREATE WORKLOAD GROUP [ExampleTempdbGovernanceMb]
WITH
(
      GROUP_MAX_TEMPDB_DATA_MB=64
    , GROUP_MAX_TEMPDB_DATA_PERCENT=50
)
USING [default];
CREATE WORKLOAD GROUP [ExampleTempdbGovernancePercent]
WITH (GROUP_MAX_TEMPDB_DATA_PERCENT=25)
USING [default];
ALTER RESOURCE GOVERNOR RECONFIGURE;';
            EXEC [sys].[sp_executesql] @Sql;
            SET @GroupsCreated=1;


            SET @CurrentJson=NULL;
            SET @Sql=N'            SET LOCK_TIMEOUT 737;
            EXEC [monitor].[USP_CurrentTempDB]
                  @MitDateien=0
                , @MaxZeilen=100
                , @ResultSetArt=''TABLE''
                , @ResultTablesJson=
                      N''{"tempdbGovernance":"#SQL25TempDBResourceGovernanceRuntimeContract_ActiveCurrentTempDB"}''
                , @JsonErzeugen=1
                , @Json=@OutputJson OUTPUT
                , @PrintMeldungen=0;
            IF @@LOCK_TIMEOUT<>737
                THROW 55828,N''SQL25-003 CurrentTempDB verändert LOCK_TIMEOUT im aktiven Pfad.'',1;';
            EXEC [sys].[sp_executesql] @Sql
                , N'@OutputJson nvarchar(max) OUTPUT'
                , @OutputJson=@CurrentJson OUTPUT;

            SET @ResourceGovernorJson=NULL;
            SET @Sql=N'            SET LOCK_TIMEOUT 739;
            EXEC [monitor].[USP_ResourceGovernorAnalysis]
                  @MitSessions=0
                , @MaxZeilen=100
                , @ResultSetArt=''TABLE''
                , @ResultTablesJson=
                      N''{"tempdbGovernance":"#SQL25TempDBResourceGovernanceRuntimeContract_ActiveResourceGovernor"}''
                , @JsonErzeugen=1
                , @Json=@OutputJson OUTPUT
                , @PrintMeldungen=0;
            IF @@LOCK_TIMEOUT<>739
                THROW 55829,N''SQL25-003 ResourceGovernorAnalysis verändert LOCK_TIMEOUT im aktiven Pfad.'',1;';
            EXEC [sys].[sp_executesql] @Sql
                , N'@OutputJson nvarchar(max) OUTPUT'
                , @OutputJson=@ResourceGovernorJson OUTPUT;

            IF NOT EXISTS
               (
                   SELECT 1
                   FROM [#SQL25TempDBResourceGovernanceRuntimeContract_ActiveResourceGovernor]
                   WHERE [GroupName]=N'ExampleTempdbGovernanceNoLimit'
                     AND [ConfiguredGroupMaxTempdbDataMb] IS NULL
                     AND [ConfiguredGroupMaxTempdbDataPercent] IS NULL
                     AND [EffectiveGroupMaxTempdbDataMb] IS NULL
                     AND [EffectiveLimitSource]='NO_LIMIT_CONFIGURED'
                     AND [SourceStatusCode]='AVAILABLE'
                     AND [IsPartial]=0
               )
                THROW 55830,N'SQL25-003 neutraler Kein-Limit-Vertrag fehlt.',1;
            INSERT @ExecutedCases VALUES('NO-LIMIT-CONFIGURED');

            IF NOT EXISTS
               (
                   SELECT 1
                   FROM [#SQL25TempDBResourceGovernanceRuntimeContract_ActiveResourceGovernor]
                   WHERE [GroupName]=N'ExampleTempdbGovernanceMb'
                     AND [ConfiguredGroupMaxTempdbDataMb]=64
                     AND [ConfiguredGroupMaxTempdbDataPercent]=50
                     AND [EffectiveGroupMaxTempdbDataMb]=64
                     AND [EffectiveLimitSource]='FIXED_MB_EFFECTIVE'
                     AND [IsPercentLimitEffective]=0
                     AND [IsResourceGovernorEnabled]=1
                     AND [ReconfigurationPending]=0
               )
                THROW 55831,N'SQL25-003 MB-Vorrang vor Prozentlimit fehlt.',1;
            INSERT @ExecutedCases VALUES('MB-LIMIT-PRECEDENCE');

            IF NOT EXISTS
               (
                   SELECT 1
                   FROM [#SQL25TempDBResourceGovernanceRuntimeContract_ActiveResourceGovernor]
                   WHERE [GroupName]=N'ExampleTempdbGovernancePercent'
                     AND [ConfiguredGroupMaxTempdbDataMb] IS NULL
                     AND [ConfiguredGroupMaxTempdbDataPercent]=25
                     AND
                     (
                         (
                             [EffectiveLimitSource]='PERCENT_EFFECTIVE'
                             AND [IsPercentLimitEffective]=1
                             AND [EffectiveGroupMaxTempdbDataMb] IS NOT NULL
                         )
                         OR
                         (
                             [EffectiveLimitSource]='PERCENT_NOT_EFFECTIVE'
                             AND [IsPercentLimitEffective]=0
                             AND [EffectiveGroupMaxTempdbDataMb] IS NULL
                         )
                     )
               )
                THROW 55832,N'SQL25-003 Prozentlimit-Wirksamkeit ist inkonsistent.',1;
            INSERT @ExecutedCases VALUES('PERCENT-LIMIT-EFFECTIVE-OR-EXPLICITLY-INEFFECTIVE');

            IF EXISTS
               (
                   SELECT 1
                   FROM [#SQL25TempDBResourceGovernanceRuntimeContract_ActiveResourceGovernor]
                   WHERE [GroupName] LIKE N'ExampleTempdbGovernance%'
                     AND
                     (
                         [TempdbDataSpaceMb] IS NULL
                         OR [PeakTempdbDataSpaceMb] IS NULL
                         OR [PeakTempdbDataSpaceMb]<[TempdbDataSpaceMb]
                         OR [TotalTempdbDataLimitViolationCount] IS NULL
                         OR [TotalTempdbDataLimitViolationCount]<0
                         OR [HasRecordedLimitViolation]<>
                            CONVERT
                            (
                                bit,
                                CASE WHEN [TotalTempdbDataLimitViolationCount]>0
                                     THEN 1 ELSE 0 END
                            )
                         OR [StatisticsStartTime] IS NULL
                     )
               )
                THROW 55833,N'SQL25-003 Runtime-, Peak-, Verletzungs- oder Fenstervertrag fehlt.',1;

            IF NOT EXISTS
               (
                   SELECT 1
                   FROM [#SQL25TempDBResourceGovernanceRuntimeContract_ActiveCurrentTempDB]
                   WHERE [GroupName]=N'ExampleTempdbGovernanceMb'
                     AND [EffectiveLimitSource]='FIXED_MB_EFFECTIVE'
                     AND [ConfiguredGroupMaxTempdbDataMb]=64
               )
                THROW 55834,N'SQL25-003 CurrentTempDB übernimmt den aktiven Governancevertrag nicht.',1;
            INSERT @ExecutedCases VALUES('CURRENT-PEAK-VIOLATION-WINDOW');

            SELECT @BeforeResetStatisticsStartTime=[StatisticsStartTime]
            FROM [#SQL25TempDBResourceGovernanceRuntimeContract_ActiveResourceGovernor]
            WHERE [GroupName]=N'ExampleTempdbGovernanceMb';

            EXEC [sys].[sp_executesql]
                 N'ALTER RESOURCE GOVERNOR RESET STATISTICS;';

            SET @Sql=N'            SET LOCK_TIMEOUT 741;
            EXEC [monitor].[USP_ResourceGovernorAnalysis]
                  @MitSessions=0
                , @MaxZeilen=100
                , @ResultSetArt=''TABLE''
                , @ResultTablesJson=
                      N''{"tempdbGovernance":"#SQL25TempDBResourceGovernanceRuntimeContract_ResetResourceGovernor"}''
                , @JsonErzeugen=0
                , @PrintMeldungen=0;
            IF @@LOCK_TIMEOUT<>741
                THROW 55835,N''SQL25-003 Resetpfad verändert LOCK_TIMEOUT.'',1;';
            EXEC [sys].[sp_executesql] @Sql;

            IF NOT EXISTS
               (
                   SELECT 1
                   FROM [#SQL25TempDBResourceGovernanceRuntimeContract_ResetResourceGovernor]
                   WHERE [GroupName]=N'ExampleTempdbGovernanceMb'
                     AND [TotalTempdbDataLimitViolationCount]=0
                     AND [HasRecordedLimitViolation]=0
                     AND [StatisticsStartTime]>=@BeforeResetStatisticsStartTime
               )
                THROW 55836,N'SQL25-003 Resetfenster wird nicht korrekt ausgewiesen.',1;
            INSERT @ExecutedCases VALUES('VIOLATION-RESET-WINDOW');

            IF USER_ID(N'ExampleTempdbGovernanceDenied') IS NOT NULL
                DROP USER [ExampleTempdbGovernanceDenied];
            CREATE USER [ExampleTempdbGovernanceDenied] WITHOUT LOGIN;
            GRANT EXECUTE ON OBJECT::[monitor].[USP_ResourceGovernorAnalysis]
                TO [ExampleTempdbGovernanceDenied];
            GRANT EXECUTE ON OBJECT::[monitor].[USP_CurrentTempDB]
                TO [ExampleTempdbGovernanceDenied];

            SET @RestrictedJson=NULL;
            EXECUTE AS USER=N'ExampleTempdbGovernanceDenied';
            SET @Impersonating=1;
            EXEC [monitor].[USP_ResourceGovernorAnalysis]
                  @MitSessions=0
                , @MaxZeilen=20
                , @ResultSetArt='NONE'
                , @JsonErzeugen=1
                , @Json=@RestrictedJson OUTPUT
                , @PrintMeldungen=0;
            REVERT;
            SET @Impersonating=0;

            IF ISJSON(@RestrictedJson)<>1
               OR JSON_QUERY(@RestrictedJson,N'$.tempdbGovernance') IS NULL
               OR NOT EXISTS
                  (
                      SELECT 1
                      FROM OPENJSON(@RestrictedJson,N'$.tempdbGovernance')
                      WITH
                      (
                            [SourceStatusCode] varchar(40) N'$.SourceStatusCode'
                          , [IsPartial] bit N'$.IsPartial'
                      )
                      WHERE [SourceStatusCode] IN
                            ('AVAILABLE','AVAILABLE_EMPTY_OR_RESTRICTED',
                             'AVAILABLE_LIMITED','DENIED_PERMISSION',
                             'UNAVAILABLE_SOURCE_SCHEMA','ERROR_HANDLED')
                        AND [IsPartial] IS NOT NULL
                  )
                THROW 55837,N'SQL25-003 eingeschränkter Sicherheitskontext wird nicht explizit begrenzt.',1;
            INSERT @ExecutedCases VALUES('RESTRICTED-PERMISSION');

            DROP USER [ExampleTempdbGovernanceDenied];

            SET @Sql=N'
DROP WORKLOAD GROUP [ExampleTempdbGovernanceNoLimit];
DROP WORKLOAD GROUP [ExampleTempdbGovernanceMb];
DROP WORKLOAD GROUP [ExampleTempdbGovernancePercent];
ALTER RESOURCE GOVERNOR RECONFIGURE;';
            EXEC [sys].[sp_executesql] @Sql;
            SET @GroupsCreated=0;

            IF @OriginalResourceGovernorEnabled=0
                EXEC [sys].[sp_executesql]
                     N'ALTER RESOURCE GOVERNOR DISABLE;';
        END;
    END;

END TRY
BEGIN CATCH
    DECLARE @CatchMessage nvarchar(2048)=ERROR_MESSAGE();

    IF @Impersonating=1
    BEGIN TRY
        REVERT;
        SET @Impersonating=0;
    END TRY
    BEGIN CATCH
    END CATCH;

    BEGIN TRY
        IF USER_ID(N'ExampleTempdbGovernanceDenied') IS NOT NULL
            DROP USER [ExampleTempdbGovernanceDenied];

        IF @ProductMajorVersion>=17
           AND @CatalogColumnsValid=1
           AND @RuntimeColumnsValid=1
        BEGIN
            SET @Sql=N'';
            IF EXISTS
               (
                   SELECT 1
                   FROM [sys].[resource_governor_workload_groups] WITH (NOLOCK)
                   WHERE [name]=N'ExampleTempdbGovernanceNoLimit'
               )
                SET @Sql+=N'DROP WORKLOAD GROUP [ExampleTempdbGovernanceNoLimit];';
            IF EXISTS
               (
                   SELECT 1
                   FROM [sys].[resource_governor_workload_groups] WITH (NOLOCK)
                   WHERE [name]=N'ExampleTempdbGovernanceMb'
               )
                SET @Sql+=N'DROP WORKLOAD GROUP [ExampleTempdbGovernanceMb];';
            IF EXISTS
               (
                   SELECT 1
                   FROM [sys].[resource_governor_workload_groups] WITH (NOLOCK)
                   WHERE [name]=N'ExampleTempdbGovernancePercent'
               )
                SET @Sql+=N'DROP WORKLOAD GROUP [ExampleTempdbGovernancePercent];';

            IF NULLIF(@Sql,N'') IS NOT NULL
            BEGIN
                SET @Sql+=N'ALTER RESOURCE GOVERNOR RECONFIGURE;';
                EXEC [sys].[sp_executesql] @Sql;
            END;

            IF @ResourceGovernorStateCaptured=1
               AND @OriginalResourceGovernorEnabled=0
                EXEC [sys].[sp_executesql]
                     N'ALTER RESOURCE GOVERNOR DISABLE;';
        END;
    END TRY
    BEGIN CATCH
    END CATCH;

    THROW 55838,@CatchMessage,1;
END CATCH;

IF @@LOCK_TIMEOUT<>@OriginalLockTimeout
    THROW 55839,N'SQL25-003 Runtimevertrag hat LOCK_TIMEOUT nicht abschließend wiederhergestellt.',1;

SELECT
      CAST('AVAILABLE' AS varchar(40)) [StatusCode]
    , CAST(0 AS bit) [IsPartial]
    , @ProductMajorVersion [ProductMajorVersion]
    , (SELECT COUNT_BIG(*) FROM @ExecutedCases) [ExecutedCases]
    , CASE
          WHEN @ProductMajorVersion<17
              THEN N'SQL25-003 Versionsgrenze und bestehender Frameworkvertrag bestanden.'
          WHEN EXISTS
               (
                   SELECT 1
                   FROM @ExecutedCases
                   WHERE [CaseId]='EXPLICIT-SOURCE-SCHEMA-BOUNDARY'
               )
              THEN N'SQL25-003 capability-adaptive SQL-Server-2025-Schemagrenze bestanden.'
          ELSE N'SQL25-003 aktiver TempDB-Resource-Governance-Vertrag bestanden.'
      END [Detail];
GO
