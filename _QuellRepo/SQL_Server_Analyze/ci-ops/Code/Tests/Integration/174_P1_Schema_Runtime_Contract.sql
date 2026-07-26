USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 174_P1_Schema_Runtime_Contract.sql
Zweck        : Prüft Laufzeitverträge für vier P1-Schema- und Designfälle.
Datenschutz  : Nur generische synthetische Objekte; Resultate werden nicht
               in Repository- oder Downloadartefakte übernommen.
Nebenwirkung : Sämtliche generisch benannten DDL-Fixtures werden im Erfolgs-
               und Fehlerpfad ausdrücklich entfernt.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit;
DECLARE @ExecutedCases TABLE([CaseId] varchar(40) NOT NULL PRIMARY KEY);

BEGIN TRY
    DROP TABLE IF EXISTS [dbo].[ExampleSchemaChild];
    DROP TABLE IF EXISTS [dbo].[ExampleSchemaParent];
    DROP TABLE IF EXISTS [dbo].[ExampleDuplicateIndex];
    DROP TABLE IF EXISTS [dbo].[ExampleIdentityRange];

    CREATE TABLE [dbo].[ExampleSchemaParent]
    (
        [ParentId] int NOT NULL CONSTRAINT [PK_ExampleSchemaParent] PRIMARY KEY
    );
    CREATE TABLE [dbo].[ExampleSchemaChild]
    (
        [ChildId] int NOT NULL CONSTRAINT [PK_ExampleSchemaChild] PRIMARY KEY,
        [ParentId] int NULL,
        [CheckedValue] int NULL CONSTRAINT [CK_ExampleSchemaChild_Value] CHECK ([CheckedValue]>=0),
        CONSTRAINT [FK_ExampleSchemaChild_Parent] FOREIGN KEY([ParentId])
            REFERENCES [dbo].[ExampleSchemaParent]([ParentId])
    );
    ALTER TABLE [dbo].[ExampleSchemaChild]
        NOCHECK CONSTRAINT [CK_ExampleSchemaChild_Value];
    ALTER TABLE [dbo].[ExampleSchemaChild]
        CHECK CONSTRAINT [CK_ExampleSchemaChild_Value];

    CREATE TABLE [dbo].[ExampleDuplicateIndex]
    (
        [KeyValue] int NOT NULL,[IncludedValue] int NULL
    );
    CREATE INDEX [IX_ExampleDuplicateIndex_A]
        ON [dbo].[ExampleDuplicateIndex]([KeyValue]) INCLUDE([IncludedValue]);
    CREATE INDEX [IX_ExampleDuplicateIndex_B]
        ON [dbo].[ExampleDuplicateIndex]([KeyValue]) INCLUDE([IncludedValue]);

    CREATE TABLE [dbo].[ExampleIdentityRange]
    (
        [IdentityValue] tinyint IDENTITY(250,1) NOT NULL,
        [Payload] tinyint NULL
    );
    INSERT [dbo].[ExampleIdentityRange] DEFAULT VALUES;

    EXEC [monitor].[USP_SchemaDesignAnalysis]
         @DatabaseNames=N'',@IdentityWarnPercent=80,
         @MaxZeilen=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,
         @PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;

    IF @Status='AVAILABLE_LIMITED'
    BEGIN
        DECLARE @TechnicalErrorNumber int=
           (SELECT TOP (1) [ErrorNumber]
            FROM OPENJSON(@Json,N'$.warnings')
            WITH ([ErrorNumber] int N'$.ErrorNumber')
            WHERE [ErrorNumber] IS NOT NULL ORDER BY [ErrorNumber]);
        RAISERROR(N'P1-Schemavertrag technischer Fehlercode=%d; Meldungsinhalt wird nicht ausgegeben.',16,1,@TechnicalErrorNumber);
    END;

    IF ISJSON(@Json)<>1 OR @Status<>'AVAILABLE_WITH_FINDING'
        THROW 54800,N'P1-Schemavertrag lieferte keinen gültigen Befundstatus.',1;

    IF NOT EXISTS
       (SELECT 1 FROM OPENJSON(@Json,N'$.findings')
        WITH ([FindingCode] varchar(100) N'$.FindingCode',[ObjectName] sysname N'$.ObjectName')
        WHERE [FindingCode]='CHECK_CONSTRAINT_NOT_TRUSTED'
          AND [ObjectName]=N'ExampleSchemaChild')
        THROW 54801,N'P1-Vertrag SCH-CONSTRAINT fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('SCH-CONSTRAINT');

    IF NOT EXISTS
       (SELECT 1 FROM OPENJSON(@Json,N'$.findings')
        WITH ([FindingCode] varchar(100) N'$.FindingCode',[ObjectName] sysname N'$.ObjectName')
        WHERE [FindingCode]='FOREIGN_KEY_WITHOUT_SUPPORTING_INDEX'
          AND [ObjectName]=N'ExampleSchemaChild')
        THROW 54802,N'P1-Vertrag SCH-FK fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('SCH-FK');

    IF NOT EXISTS
       (SELECT 1 FROM OPENJSON(@Json,N'$.findings')
        WITH ([FindingCode] varchar(100) N'$.FindingCode',[ObjectName] sysname N'$.ObjectName')
        WHERE [FindingCode]='EXACT_INDEX_DEFINITION_DUPLICATE'
          AND [ObjectName]=N'ExampleDuplicateIndex')
        THROW 54803,N'P1-Vertrag SCH-DUP fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('SCH-DUP');

    IF NOT EXISTS
       (SELECT 1 FROM OPENJSON(@Json,N'$.findings')
        WITH ([FindingCode] varchar(100) N'$.FindingCode',[ObjectName] sysname N'$.ObjectName',
              [MetricValue] decimal(38,4) N'$.MetricValue')
        WHERE [FindingCode]='IDENTITY_TYPE_RANGE_USAGE'
          AND [ObjectName]=N'ExampleIdentityRange' AND [MetricValue]>=80)
        THROW 54804,N'P1-Vertrag SCH-RANGE fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('SCH-RANGE');

    DROP TABLE [dbo].[ExampleSchemaChild];
    DROP TABLE [dbo].[ExampleSchemaParent];
    DROP TABLE [dbo].[ExampleDuplicateIndex];
    DROP TABLE [dbo].[ExampleIdentityRange];
END TRY
BEGIN CATCH
    BEGIN TRY
        DROP TABLE IF EXISTS [dbo].[ExampleSchemaChild];
        DROP TABLE IF EXISTS [dbo].[ExampleSchemaParent];
        DROP TABLE IF EXISTS [dbo].[ExampleDuplicateIndex];
        DROP TABLE IF EXISTS [dbo].[ExampleIdentityRange];
    END TRY
    BEGIN CATCH
    END CATCH;
    THROW;
END CATCH;

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>4
    THROW 54805,N'Der P1-Schemavertrag hat nicht alle vorgesehenen Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'Vier synthetische P1-Schemafälle wurden vollständig bereinigt.' AS [Detail]
FROM @ExecutedCases;
GO
