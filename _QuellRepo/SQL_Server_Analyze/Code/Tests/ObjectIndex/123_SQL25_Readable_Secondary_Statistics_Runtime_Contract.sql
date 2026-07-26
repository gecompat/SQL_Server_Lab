USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 123_SQL25_Readable_Secondary_Statistics_Runtime_Contract.sql
Zweck        : Prüft SQL25-004 auf SQL Server 2019, 2022 und 2025:
               versionsadaptive sys.stats-Herkunftsfelder, aktuelle
               Datenbankrolle, TABLE/JSON, Begrenzung, leeren oder durch
               Metadata Visibility eingeschränkten Scope und LOCK_TIMEOUT.
Datenschutz  : Ausschließlich kurzlebige generische Example*-Objekte und
               synthetische numerische Verteilungswerte. Querytexte, Pläne,
               Zugangsdaten, externe Systeme und reale Replikatnamen werden
               nicht verwendet.
Nebenwirkung : Eine generische Tabelle, zwei Statistiken und ein Benutzer ohne
               Login werden im Erfolgs- wie im Fehlerpfad entfernt.
Grenze       : Die CI-Container bilden keine Availability Group. Secondary-,
               Geo-Secondary- und Partial-Metadaten werden deshalb über den
               öffentlichen Rollencodevertrag synthetisch geprüft; der echte
               Katalogpfad wird auf SQL Server 2025 gegen die dort verfügbaren
               sys.stats-Spalten ausgeführt.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ProductMajorVersion int=
    TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'));
DECLARE @Json nvarchar(max)=NULL;
DECLARE @RestrictedJson nvarchar(max)=NULL;
DECLARE @OriginalLockTimeout int=@@LOCK_TIMEOUT;
DECLARE @InvocationSql nvarchar(max)=N'
SET LOCK_TIMEOUT 743;
EXEC [monitor].[USP_Statistics]
      @DatabaseNames=@pDatabaseNames
    , @FullObjectNames=@pFullObjectNames
    , @MaxZeilen=@pMaxZeilen
    , @LockTimeoutMs=0
    , @ResultSetArt=''TABLE''
    , @ResultTablesJson=@pResultTablesJson
    , @JsonErzeugen=1
    , @Json=@pJson OUTPUT
    , @PrintMeldungen=0;
IF @@LOCK_TIMEOUT<>743
    THROW 55740,N''SQL25-004 USP_Statistics stellt LOCK_TIMEOUT nicht wieder her.'',1;';
DECLARE @Impersonating bit=0;
DECLARE @ExecutedCases TABLE
(
    [CaseId] varchar(64) NOT NULL PRIMARY KEY
);

BEGIN TRY
    IF USER_ID(N'ExampleReadableSecondaryStatisticsUser') IS NOT NULL
        DROP USER [ExampleReadableSecondaryStatisticsUser];
    DROP TABLE IF EXISTS [dbo].[ExampleReadableSecondaryStatistics];

    CREATE TABLE [dbo].[ExampleReadableSecondaryStatistics]
    (
          [ExampleId] int NOT NULL
        , [ExampleGroup] int NULL
        , [ExampleValue] int NULL
    );

    INSERT [dbo].[ExampleReadableSecondaryStatistics]
    (
        [ExampleId],[ExampleGroup],[ExampleValue]
    )
    VALUES
          (1,1,10)
        , (2,1,20)
        , (3,2,30)
        , (4,3,40);

    CREATE STATISTICS [ExampleReadableSecondaryStatistics_Group]
        ON [dbo].[ExampleReadableSecondaryStatistics]([ExampleGroup])
        WITH FULLSCAN;
    CREATE STATISTICS [ExampleReadableSecondaryStatistics_Value]
        ON [dbo].[ExampleReadableSecondaryStatistics]([ExampleValue])
        WITH FULLSCAN;

    CREATE TABLE [#SQL25ReadableSecondaryStatisticsRuntimeContract_Statistics]
    (
        [Seed] bit NULL
    );

    EXEC [sys].[sp_executesql]
          @InvocationSql
        , N'@pDatabaseNames nvarchar(max),@pFullObjectNames nvarchar(max),
            @pMaxZeilen int,@pResultTablesJson nvarchar(max),
            @pJson nvarchar(max) OUTPUT'
        , @pDatabaseNames=N'[DeineDatenbank]'
        , @pFullObjectNames=N'[dbo].[ExampleReadableSecondaryStatistics]'
        , @pMaxZeilen=10
        , @pResultTablesJson=
          N'{"statistics":"#SQL25ReadableSecondaryStatisticsRuntimeContract_Statistics"}'
        , @pJson=@Json OUTPUT;

    IF @@LOCK_TIMEOUT<>@OriginalLockTimeout
        THROW 55750,N'SQL25-004 Runtimevertrag verändert den äußeren LOCK_TIMEOUT.',1;

    IF ISJSON(@Json)<>1
       OR TRY_CONVERT(int,JSON_VALUE(@Json,N'$.meta.schemaVersion'))<>2
       OR (SELECT COUNT_BIG(*)
           FROM [#SQL25ReadableSecondaryStatisticsRuntimeContract_Statistics])<>2
       OR NOT EXISTS
          (
              SELECT 1
              FROM OPENJSON(@Json,N'$.statistics')
              WITH
              (
                    [StatisticsName] sysname N'$.StatisticsName'
                  , [IsTemporary] bit N'$.IsTemporary'
                  , [CurrentReplicaRole] varchar(40) N'$.CurrentReplicaRole'
                  , [CurrentReplicaRoleStatus] varchar(40)
                    N'$.CurrentReplicaRoleStatus'
                  , [ReplicaRoleId] tinyint N'$.ReplicaRoleId'
                  , [ReplicaRoleDesc] nvarchar(60) N'$.ReplicaRoleDesc'
                  , [ReplicaName] sysname N'$.ReplicaName'
                  , [ReplicaMetadataStatus] varchar(40)
                    N'$.ReplicaMetadataStatus'
              )
              WHERE [StatisticsName]=
                    N'ExampleReadableSecondaryStatistics_Group'
                AND [IsTemporary]=0
                AND [CurrentReplicaRole] IN
                    ('HADR_DISABLED','PRIMARY','SECONDARY',
                     'NOT_IN_AG_OR_UNKNOWN')
                AND [CurrentReplicaRoleStatus] IN
                    ('AVAILABLE','NOT_APPLICABLE')
                AND [ReplicaMetadataStatus] IS NOT NULL
          )
        THROW 55741,N'SQL25-004 TABLE-/JSON-Grundvertrag fehlgeschlagen.',1;

    INSERT @ExecutedCases VALUES('NAMED-TABLE-JSON');
    INSERT @ExecutedCases VALUES('CURRENT-REPLICA-ROLE');
    INSERT @ExecutedCases VALUES('LOCK-TIMEOUT-RESTORATION');

    IF COALESCE(@ProductMajorVersion,0)<17
    BEGIN
        IF EXISTS
           (
               SELECT 1
               FROM [#SQL25ReadableSecondaryStatisticsRuntimeContract_Statistics]
               WHERE [ReplicaRoleId] IS NOT NULL
                  OR [ReplicaRoleDesc] IS NOT NULL
                  OR [ReplicaName] IS NOT NULL
                  OR [ReplicaMetadataStatus]<>'UNAVAILABLE_VERSION'
           )
           OR NOT EXISTS
              (
                  SELECT 1
                  FROM OPENJSON(@Json,N'$.databaseStatus')
                  WITH
                  (
                        [StatusCode] varchar(40) N'$.StatusCode'
                      , [Detail] nvarchar(2000) N'$.Detail'
                  )
                  WHERE [StatusCode]='AVAILABLE'
                    AND [Detail] LIKE
                        N'%ReplicaMetadataStatus=UNAVAILABLE_VERSION%'
              )
            THROW 55742,N'SQL25-004 Versionsgrenze auf SQL Server 2019/2022 fehlgeschlagen.',1;

        INSERT @ExecutedCases VALUES('UNAVAILABLE-VERSION');
    END
    ELSE
    BEGIN
        IF EXISTS
           (
               SELECT 1
               FROM [#SQL25ReadableSecondaryStatisticsRuntimeContract_Statistics]
               WHERE [ReplicaMetadataStatus] NOT IN
                     ('AVAILABLE','NOT_RECORDED','PARTIAL_METADATA')
           )
            THROW 55743,N'SQL25-004 SQL-Server-2025-Katalogpfad ist nicht verfügbar.',1;

        IF EXISTS
           (
               SELECT 1
               FROM [#SQL25ReadableSecondaryStatisticsRuntimeContract_Statistics]
               WHERE [ReplicaRoleId] IS NOT NULL
                 AND
                 (
                     [ReplicaRoleId] NOT BETWEEN 1 AND 4
                     OR [ReplicaRoleDesc] IS NULL
                     OR [ReplicaRoleDesc]
                        COLLATE Latin1_General_100_CI_AI<>
                        CASE [ReplicaRoleId]
                             WHEN 1 THEN N'Primary'
                             WHEN 2 THEN N'Secondary'
                             WHEN 3 THEN N'Geo Secondary'
                             WHEN 4 THEN N'Geo HA Secondary'
                        END
                 )
           )
            THROW 55744,N'SQL25-004 tatsächliche Herkunftsrolle ist inkonsistent.',1;

        INSERT @ExecutedCases VALUES('SQL2025-CATALOG');
        INSERT @ExecutedCases VALUES('PRIMARY-OR-NOT-RECORDED');
    END;

    DECLARE @SyntheticReplicaRoles TABLE
    (
          [ReplicaRoleId] tinyint NULL
        , [ReplicaRoleDesc] nvarchar(60) NULL
        , [ReplicaName] sysname NULL
        , [ExpectedStatus] varchar(40) NOT NULL
    );

    INSERT @SyntheticReplicaRoles
    (
        [ReplicaRoleId],[ReplicaRoleDesc],[ReplicaName],[ExpectedStatus]
    )
    VALUES
          (1,N'Primary',NULL,'AVAILABLE')
        , (1,N'PRIMARY',NULL,'AVAILABLE')
        , (2,N'Secondary',N'ExampleSecondaryReplica','AVAILABLE')
        , (3,N'Geo Secondary',N'ExampleGeoSecondary','AVAILABLE')
        , (4,N'Geo HA Secondary',N'ExampleGeoHASecondary','AVAILABLE')
        , (2,NULL,NULL,'PARTIAL_METADATA')
        , (NULL,NULL,NULL,'NOT_RECORDED');

    IF EXISTS
       (
           SELECT 1
           FROM @SyntheticReplicaRoles
           WHERE [ExpectedStatus]<>
                 CASE
                      WHEN [ReplicaRoleId] IS NULL
                       AND [ReplicaRoleDesc] IS NULL
                       AND [ReplicaName] IS NULL
                          THEN 'NOT_RECORDED'
                      WHEN [ReplicaRoleId] BETWEEN 1 AND 4
                       AND [ReplicaRoleDesc]
                           COLLATE Latin1_General_100_CI_AI=
                           CASE [ReplicaRoleId]
                                WHEN 1 THEN N'Primary'
                                WHEN 2 THEN N'Secondary'
                                WHEN 3 THEN N'Geo Secondary'
                                WHEN 4 THEN N'Geo HA Secondary'
                           END
                       AND ([ReplicaRoleId]=1 OR [ReplicaName] IS NOT NULL)
                          THEN 'AVAILABLE'
                      ELSE 'PARTIAL_METADATA'
                 END
       )
        THROW 55745,N'SQL25-004 Rollencode-/Partial-Metadatenvertrag fehlgeschlagen.',1;

    INSERT @ExecutedCases VALUES('SECONDARY-ROLE-MAPPING');
    INSERT @ExecutedCases VALUES('PARTIAL-METADATA-MAPPING');

    CREATE TABLE [#SQL25ReadableSecondaryStatisticsRuntimeContract_Bounded]
    (
        [Seed] bit NULL
    );

    SET @Json=NULL;
    EXEC [sys].[sp_executesql]
          @InvocationSql
        , N'@pDatabaseNames nvarchar(max),@pFullObjectNames nvarchar(max),
            @pMaxZeilen int,@pResultTablesJson nvarchar(max),
            @pJson nvarchar(max) OUTPUT'
        , @pDatabaseNames=N'[DeineDatenbank]'
        , @pFullObjectNames=N'[dbo].[ExampleReadableSecondaryStatistics]'
        , @pMaxZeilen=1
        , @pResultTablesJson=
          N'{"statistics":"#SQL25ReadableSecondaryStatisticsRuntimeContract_Bounded"}'
        , @pJson=@Json OUTPUT;

    IF @@LOCK_TIMEOUT<>@OriginalLockTimeout
       OR (SELECT COUNT_BIG(*)
           FROM [#SQL25ReadableSecondaryStatisticsRuntimeContract_Bounded])<>1
       OR (SELECT COUNT_BIG(*)
           FROM OPENJSON(@Json,N'$.statistics'))<>1
        THROW 55746,N'SQL25-004 Begrenzungs- oder LOCK_TIMEOUT-Vertrag fehlgeschlagen.',1;

    INSERT @ExecutedCases VALUES('BOUNDED-OUTPUT');

    CREATE TABLE [#SQL25ReadableSecondaryStatisticsRuntimeContract_Empty]
    (
        [Seed] bit NULL
    );

    SET @Json=NULL;
    EXEC [sys].[sp_executesql]
          @InvocationSql
        , N'@pDatabaseNames nvarchar(max),@pFullObjectNames nvarchar(max),
            @pMaxZeilen int,@pResultTablesJson nvarchar(max),
            @pJson nvarchar(max) OUTPUT'
        , @pDatabaseNames=N'[DeineDatenbank]'
        , @pFullObjectNames=N'[dbo].[ExampleReadableSecondaryStatisticsMissing]'
        , @pMaxZeilen=10
        , @pResultTablesJson=
          N'{"statistics":"#SQL25ReadableSecondaryStatisticsRuntimeContract_Empty"}'
        , @pJson=@Json OUTPUT;

    IF @@LOCK_TIMEOUT<>@OriginalLockTimeout
       OR EXISTS
          (
              SELECT 1
              FROM [#SQL25ReadableSecondaryStatisticsRuntimeContract_Empty]
          )
       OR NOT EXISTS
          (
              SELECT 1
              FROM OPENJSON(@Json,N'$.databaseStatus')
              WITH
              (
                    [StatusCode] varchar(40) N'$.StatusCode'
                  , [Detail] nvarchar(2000) N'$.Detail'
              )
              WHERE [StatusCode]='AVAILABLE_LIMITED'
                AND [Detail] LIKE N'%RowScope=EMPTY_OR_RESTRICTED%'
          )
        THROW 55747,N'SQL25-004 Leer-/Sichtbarkeitsgrenze fehlgeschlagen.',1;

    INSERT @ExecutedCases VALUES('EMPTY-OR-RESTRICTED-SCOPE');

    CREATE USER [ExampleReadableSecondaryStatisticsUser] WITHOUT LOGIN;
    GRANT EXECUTE ON SCHEMA::[monitor]
        TO [ExampleReadableSecondaryStatisticsUser];
    DENY VIEW DEFINITION
        TO [ExampleReadableSecondaryStatisticsUser];

    CREATE TABLE [#SQL25ReadableSecondaryStatisticsRuntimeContract_Restricted]
    (
        [Seed] bit NULL
    );

    SET @RestrictedJson=NULL;
    EXECUTE AS USER=N'ExampleReadableSecondaryStatisticsUser';
    SET @Impersonating=1;

    EXEC [sys].[sp_executesql]
          @InvocationSql
        , N'@pDatabaseNames nvarchar(max),@pFullObjectNames nvarchar(max),
            @pMaxZeilen int,@pResultTablesJson nvarchar(max),
            @pJson nvarchar(max) OUTPUT'
        , @pDatabaseNames=N'[DeineDatenbank]'
        , @pFullObjectNames=N'[dbo].[ExampleReadableSecondaryStatistics]'
        , @pMaxZeilen=10
        , @pResultTablesJson=
          N'{"statistics":"#SQL25ReadableSecondaryStatisticsRuntimeContract_Restricted"}'
        , @pJson=@RestrictedJson OUTPUT;

    REVERT;
    SET @Impersonating=0;

    IF @@LOCK_TIMEOUT<>@OriginalLockTimeout
       OR ISJSON(@RestrictedJson)<>1
       OR EXISTS
          (
              SELECT 1
              FROM [#SQL25ReadableSecondaryStatisticsRuntimeContract_Restricted]
          )
       OR NOT EXISTS
          (
              SELECT 1
              FROM OPENJSON(@RestrictedJson,N'$.databaseStatus')
              WITH
              (
                    [StatusCode] varchar(40) N'$.StatusCode'
                  , [Detail] nvarchar(2000) N'$.Detail'
              )
              WHERE [StatusCode] IN
                    ('AVAILABLE_LIMITED','DENIED_PERMISSION','PARTIAL')
                AND
                (
                    [StatusCode]='DENIED_PERMISSION'
                    OR [Detail] LIKE N'%RowScope=EMPTY_OR_RESTRICTED%'
                    OR [Detail] LIKE N'%ReplicaMetadataStatus=DENIED_METADATA%'
                )
          )
        THROW 55748,N'SQL25-004 eingeschränkte Metadata Visibility wird nicht explizit begrenzt.',1;

    INSERT @ExecutedCases VALUES('RESTRICTED-METADATA');

    DROP USER [ExampleReadableSecondaryStatisticsUser];
    DROP TABLE [dbo].[ExampleReadableSecondaryStatistics];
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
        IF USER_ID(N'ExampleReadableSecondaryStatisticsUser') IS NOT NULL
            DROP USER [ExampleReadableSecondaryStatisticsUser];
        DROP TABLE IF EXISTS [dbo].[ExampleReadableSecondaryStatistics];
    END TRY
    BEGIN CATCH
    END CATCH;

    THROW 55749,@CatchMessage,1;
END CATCH;

IF @@LOCK_TIMEOUT<>@OriginalLockTimeout
    THROW 55750,N'SQL25-004 Runtimevertrag stellt äußeren LOCK_TIMEOUT nicht wieder her.',1;

IF NOT EXISTS
   (
       SELECT 1
       FROM @ExecutedCases
       WHERE [CaseId]='NAMED-TABLE-JSON'
   )
   OR NOT EXISTS
      (
          SELECT 1
          FROM @ExecutedCases
          WHERE [CaseId]='CURRENT-REPLICA-ROLE'
      )
   OR NOT EXISTS
      (
          SELECT 1
          FROM @ExecutedCases
          WHERE [CaseId]='SECONDARY-ROLE-MAPPING'
      )
   OR NOT EXISTS
      (
          SELECT 1
          FROM @ExecutedCases
          WHERE [CaseId]='PARTIAL-METADATA-MAPPING'
      )
   OR NOT EXISTS
      (
          SELECT 1
          FROM @ExecutedCases
          WHERE [CaseId]='BOUNDED-OUTPUT'
      )
   OR NOT EXISTS
      (
          SELECT 1
          FROM @ExecutedCases
          WHERE [CaseId]='EMPTY-OR-RESTRICTED-SCOPE'
      )
   OR NOT EXISTS
      (
          SELECT 1
          FROM @ExecutedCases
          WHERE [CaseId]='RESTRICTED-METADATA'
      )
   OR NOT EXISTS
      (
          SELECT 1
          FROM @ExecutedCases
          WHERE [CaseId]='LOCK-TIMEOUT-RESTORATION'
      )
    THROW 55751,N'SQL25-004 hat nicht alle gemeinsamen Runtimefälle ausgeführt.',1;

IF COALESCE(@ProductMajorVersion,0)<17
   AND NOT EXISTS
       (
           SELECT 1
           FROM @ExecutedCases
           WHERE [CaseId]='UNAVAILABLE-VERSION'
       )
    THROW 55752,N'SQL25-004 hat den Versionsfall nicht ausgeführt.',1;

IF COALESCE(@ProductMajorVersion,0)>=17
   AND
   (
       NOT EXISTS
       (
           SELECT 1
           FROM @ExecutedCases
           WHERE [CaseId]='SQL2025-CATALOG'
       )
       OR NOT EXISTS
          (
              SELECT 1
              FROM @ExecutedCases
              WHERE [CaseId]='PRIMARY-OR-NOT-RECORDED'
          )
   )
    THROW 55753,N'SQL25-004 hat den SQL-Server-2025-Katalogfall nicht ausgeführt.',1;

SELECT
      CAST('AVAILABLE' AS varchar(40)) [StatusCode]
    , CAST(0 AS bit) [IsPartial]
    , @ProductMajorVersion [ProductMajorVersion]
    , (SELECT COUNT_BIG(*) FROM @ExecutedCases) [ExecutedCases]
    , N'SQL25-004 Readable-Secondary-Statistikvertrag vollständig bestanden.'
      [Detail];
GO
