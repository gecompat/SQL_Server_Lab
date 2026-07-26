USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 181_P2_Temporal_Runtime_Contract.sql
Zweck        : Automatisiert die 13 P2-Temporal-Verträge.
Datenschutz  : Generische leere Tabellen; keine Current-/History-Nutzdaten.
Nebenwirkung : Kurzlebige Temporal-DDL und rückgesetzter Datenbankschalter.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ExecutedCases TABLE([CaseId] varchar(64) NOT NULL PRIMARY KEY);
DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit;
DECLARE @Definition nvarchar(max),@Sql nvarchar(max);
DECLARE @DatabaseName sysname=(SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID());
DECLARE @RetentionWasEnabled bit=
(
    SELECT [is_temporal_history_retention_enabled]
    FROM [sys].[databases] WITH (NOLOCK)
    WHERE [database_id]=DB_ID()
);

SELECT @Definition=[sm].[definition]
FROM [sys].[sql_modules] [sm] WITH (NOLOCK)
JOIN [sys].[objects] [o] WITH (NOLOCK) ON [o].[object_id]=[sm].[object_id]
JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
WHERE [s].[name]=N'monitor' AND [o].[name]=N'USP_TemporalAnalysis';
IF @Definition IS NULL THROW 55500,N'Temporal-Proceduredefinition ist nicht sichtbar.',1;

BEGIN TRY
    /* Wiederanlaufsichere Bereinigung. */
    IF EXISTS(SELECT 1 FROM [sys].[tables] WITH (NOLOCK) WHERE [name]=N'ExampleTemporalIndexed' AND [temporal_type]=2)
        ALTER TABLE [dbo].[ExampleTemporalIndexed] SET (SYSTEM_VERSIONING=OFF);
    IF EXISTS(SELECT 1 FROM [sys].[tables] WITH (NOLOCK) WHERE [name]=N'ExampleTemporalMissingIndex' AND [temporal_type]=2)
        ALTER TABLE [dbo].[ExampleTemporalMissingIndex] SET (SYSTEM_VERSIONING=OFF);
    DROP TABLE IF EXISTS [dbo].[ExampleTemporalIndexed];
    DROP TABLE IF EXISTS [dbo].[ExampleTemporalIndexedHistory];
    DROP TABLE IF EXISTS [dbo].[ExampleTemporalMissingIndex];
    DROP TABLE IF EXISTS [dbo].[ExampleTemporalMissingIndexHistory];

    /* TEMPORAL-NONE */
    EXEC [monitor].[USP_TemporalAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@MaxZeilen=10,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1 OR @Status NOT IN('NOT_APPLICABLE','AVAILABLE_LIMITED')
       OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.temporalTables'))<>0
        THROW 55501,N'P2-Vertrag TEMPORAL-NONE fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('TEMPORAL-NONE');

    CREATE TABLE [dbo].[ExampleTemporalIndexed]
    (
        [Id] int NOT NULL CONSTRAINT [PK_ExampleTemporalIndexed] PRIMARY KEY,
        [ValidFrom] datetime2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL
            CONSTRAINT [DF_ExampleTemporalIndexed_From] DEFAULT SYSUTCDATETIME(),
        [ValidTo] datetime2 GENERATED ALWAYS AS ROW END HIDDEN NOT NULL
            CONSTRAINT [DF_ExampleTemporalIndexed_To] DEFAULT CONVERT(datetime2,'9999-12-31 23:59:59.9999999'),
        PERIOD FOR SYSTEM_TIME([ValidFrom],[ValidTo])
    )
    WITH
    (
        SYSTEM_VERSIONING=ON
        (
            HISTORY_TABLE=[dbo].[ExampleTemporalIndexedHistory],
            DATA_CONSISTENCY_CHECK=OFF,
            HISTORY_RETENTION_PERIOD=7 DAYS
        )
    );
    CREATE INDEX [IX_ExampleTemporalIndexedHistory_Period]
        ON [dbo].[ExampleTemporalIndexedHistory]([ValidTo],[ValidFrom]);

    CREATE TABLE [dbo].[ExampleTemporalMissingIndexHistory]
    (
        [Id] int NOT NULL,
        [PeriodStart] datetime2 NOT NULL,
        [PeriodEnd] datetime2 NOT NULL
    );
    CREATE TABLE [dbo].[ExampleTemporalMissingIndex]
    (
        [Id] int NOT NULL CONSTRAINT [PK_ExampleTemporalMissingIndex] PRIMARY KEY,
        [PeriodStart] datetime2 GENERATED ALWAYS AS ROW START NOT NULL
            CONSTRAINT [DF_ExampleTemporalMissingIndex_From] DEFAULT SYSUTCDATETIME(),
        [PeriodEnd] datetime2 GENERATED ALWAYS AS ROW END NOT NULL
            CONSTRAINT [DF_ExampleTemporalMissingIndex_To] DEFAULT CONVERT(datetime2,'9999-12-31 23:59:59.9999999'),
        PERIOD FOR SYSTEM_TIME([PeriodStart],[PeriodEnd])
    )
    WITH
    (
        SYSTEM_VERSIONING=ON
        (
            HISTORY_TABLE=[dbo].[ExampleTemporalMissingIndexHistory],
            DATA_CONSISTENCY_CHECK=OFF
        )
    );

    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXEC [monitor].[USP_TemporalAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@ObjectNamePattern=N'like:ExampleTemporal%',
         @HistorySizeWarnMb=0,@HistoryRowsWarn=0,@HistoryToCurrentRatioWarn=1,@MinHistoryMbForRatioWarn=0,
         @MaxZeilen=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,
         @PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;

    IF ISJSON(@Json)<>1 OR @Status NOT IN('AVAILABLE','AVAILABLE_WITH_FINDING','AVAILABLE_LIMITED')
        THROW 55502,N'Temporal-Fixtures lieferten keinen gültigen Vertrag.',1;

    IF NOT EXISTS
    (
        SELECT 1 FROM OPENJSON(@Json,N'$.temporalTables')
        WITH
        (
            [CurrentTableName] sysname N'$.CurrentTableName',
            [HistoryTableName] sysname N'$.HistoryTableName',
            [PeriodStartColumnName] sysname N'$.PeriodStartColumnName',
            [PeriodEndColumnName] sysname N'$.PeriodEndColumnName',
            [PeriodStartIsHidden] bit N'$.PeriodStartIsHidden',
            [PeriodEndIsHidden] bit N'$.PeriodEndIsHidden',
            [RetentionMode] varchar(16) N'$.RetentionMode',
            [HasPeriodLeadingHistoryIndex] bit N'$.HasPeriodLeadingHistoryIndex'
        )
        WHERE [CurrentTableName]=N'ExampleTemporalIndexed'
          AND [HistoryTableName]=N'ExampleTemporalIndexedHistory'
          AND [PeriodStartColumnName]=N'ValidFrom'
          AND [PeriodEndColumnName]=N'ValidTo'
          AND [PeriodStartIsHidden]=1 AND [PeriodEndIsHidden]=1
          AND [RetentionMode]='FINITE'
          AND [HasPeriodLeadingHistoryIndex]=1
    )
        THROW 55503,N'Temporal Mapping-, Hidden-, Retention- oder Indexvertrag fehlgeschlagen.',1;

    INSERT @ExecutedCases VALUES
          ('TEMPORAL-MAPPING'),('TEMPORAL-HIDDEN-PERIOD'),('TEMPORAL-RETENTION-FINITE');

    IF NOT EXISTS
    (
        SELECT 1 FROM OPENJSON(@Json,N'$.temporalTables')
        WITH ([CurrentTableName] sysname N'$.CurrentTableName',[HasPeriodLeadingHistoryIndex] bit N'$.HasPeriodLeadingHistoryIndex')
        WHERE [CurrentTableName]=N'ExampleTemporalMissingIndex' AND [HasPeriodLeadingHistoryIndex]=0
    )
       OR NOT EXISTS
          (
              SELECT 1 FROM OPENJSON(@Json,N'$.findings')
              WITH ([ObjectName] sysname N'$.ObjectName',[FindingCode] varchar(120) N'$.FindingCode')
              WHERE [ObjectName]=N'ExampleTemporalMissingIndex' AND [FindingCode]='HISTORY_PERIOD_INDEX_REVIEW'
          )
        THROW 55504,N'P2-Vertrag TEMPORAL-INDEX fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('TEMPORAL-INDEX');

    /* TEMPORAL-RETENTION-DISABLED */
    SET @Sql=N'ALTER DATABASE '+QUOTENAME(@DatabaseName)+N' SET TEMPORAL_HISTORY_RETENTION OFF;';
    EXEC [sys].[sp_executesql] @Sql;
    SET @Json=NULL;
    EXEC [monitor].[USP_TemporalAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@ObjectNames=N'ExampleTemporalIndexed',
         @MaxZeilen=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,
         @PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF NOT EXISTS
    (
        SELECT 1 FROM OPENJSON(@Json,N'$.findings')
        WITH ([FindingCode] varchar(120) N'$.FindingCode')
        WHERE [FindingCode]='RETENTION_CONFIGURED_DATABASE_CLEANUP_DISABLED'
    )
        THROW 55505,N'P2-Vertrag TEMPORAL-RETENTION-DISABLED fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('TEMPORAL-RETENTION-DISABLED');

    IF @RetentionWasEnabled=1
    BEGIN
        SET @Sql=N'ALTER DATABASE '+QUOTENAME(@DatabaseName)+N' SET TEMPORAL_HISTORY_RETENTION ON;';
        EXEC [sys].[sp_executesql] @Sql;
    END;

    /* TEMPORAL-FILTER */
    SET @Json=NULL;
    EXEC [monitor].[USP_TemporalAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@ObjectNames=N'ExampleTemporalIndexed',
         @MaxZeilen=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,
         @PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.temporalTables'))<>1
       OR JSON_VALUE(@Json,N'$.temporalTables[0].CurrentTableName')<>N'ExampleTemporalIndexed'
        THROW 55506,N'P2-Vertrag TEMPORAL-FILTER fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('TEMPORAL-FILTER');

    /* TEMPORAL-BOUNDED */
    SET @Json=NULL;
    EXEC [monitor].[USP_TemporalAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@ObjectNamePattern=N'like:ExampleTemporal%',
         @MaxZeilen=1,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,
         @PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.temporalTables'))>1
       OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.databaseStatus'))<>1
        THROW 55507,N'P2-Vertrag TEMPORAL-BOUNDED fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('TEMPORAL-BOUNDED');

    /* Statische/synthetische Grenzen für nicht portabel erzwingbare Zustände. */
    IF CHARINDEX(N'''LARGE_HISTORY_SIZE_CONTEXT''',@Definition)=0
       OR CHARINDEX(N'''HISTORY_TO_CURRENT_RATIO_CONTEXT''',@Definition)=0
       OR CHARINDEX(N'[CurrentIsMemoryOptimized]',@Definition)=0
       OR CHARINDEX(N'''AVAILABLE_LIMITED''',@Definition)=0
       OR CHARINDEX(N'''TEMPORAL_EVIDENCE_GAP''',@Definition)=0
        THROW 55508,N'Temporal-Kapazitäts-, Memory- oder Denied-Vertrag fehlt.',1;
    INSERT @ExecutedCases VALUES
          ('TEMPORAL-INFINITE-LARGE'),('TEMPORAL-RATIO'),('TEMPORAL-MEMORY-OPTIMIZED'),('TEMPORAL-DENIED');

    /* TEMPORAL-DISABLED-LIMIT */
    ALTER TABLE [dbo].[ExampleTemporalMissingIndex] SET (SYSTEM_VERSIONING=OFF);
    SET @Json=NULL;
    EXEC [monitor].[USP_TemporalAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@ObjectNames=N'ExampleTemporalMissingIndex',
         @MaxZeilen=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,
         @PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.temporalTables'))<>0
       OR CHARINDEX(N'früher getrennten Tabellenpaare',@Definition)=0
        THROW 55509,N'P2-Vertrag TEMPORAL-DISABLED-LIMIT fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('TEMPORAL-DISABLED-LIMIT');

    ALTER TABLE [dbo].[ExampleTemporalIndexed] SET (SYSTEM_VERSIONING=OFF);
    DROP TABLE [dbo].[ExampleTemporalIndexed];
    DROP TABLE [dbo].[ExampleTemporalIndexedHistory];
    DROP TABLE [dbo].[ExampleTemporalMissingIndex];
    DROP TABLE [dbo].[ExampleTemporalMissingIndexHistory];

    IF @RetentionWasEnabled=0
    BEGIN
        SET @Sql=N'ALTER DATABASE '+QUOTENAME(@DatabaseName)+N' SET TEMPORAL_HISTORY_RETENTION OFF;';
        EXEC [sys].[sp_executesql] @Sql;
    END;
END TRY
BEGIN CATCH
    BEGIN TRY
        IF EXISTS(SELECT 1 FROM [sys].[tables] WITH (NOLOCK) WHERE [name]=N'ExampleTemporalIndexed' AND [temporal_type]=2)
            ALTER TABLE [dbo].[ExampleTemporalIndexed] SET (SYSTEM_VERSIONING=OFF);
        IF EXISTS(SELECT 1 FROM [sys].[tables] WITH (NOLOCK) WHERE [name]=N'ExampleTemporalMissingIndex' AND [temporal_type]=2)
            ALTER TABLE [dbo].[ExampleTemporalMissingIndex] SET (SYSTEM_VERSIONING=OFF);
        DROP TABLE IF EXISTS [dbo].[ExampleTemporalIndexed];
        DROP TABLE IF EXISTS [dbo].[ExampleTemporalIndexedHistory];
        DROP TABLE IF EXISTS [dbo].[ExampleTemporalMissingIndex];
        DROP TABLE IF EXISTS [dbo].[ExampleTemporalMissingIndexHistory];
        SET @Sql=N'ALTER DATABASE '+QUOTENAME(@DatabaseName)+N' SET TEMPORAL_HISTORY_RETENTION '+CASE WHEN @RetentionWasEnabled=1 THEN N'ON' ELSE N'OFF' END+N';';
        EXEC [sys].[sp_executesql] @Sql;
    END TRY
    BEGIN CATCH
    END CATCH;
    THROW;
END CATCH;

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>13
    THROW 55510,N'Der P2-Temporal-Vertrag hat nicht alle 13 Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'13 P2-Temporal-Fälle wurden ohne Current-/History-Nutzdatenzugriff geprüft.' AS [Detail]
FROM @ExecutedCases;
GO
