USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 168_Special_Case_Runtime_Contract.sql
Zweck        : Führt alle P2-Spezialfallmodule gegen die synthetische leere
               Testdatenbank aus und validiert JSON- und Statusvertrag.
Datenschutz  : Persistiert keine Laufzeitausgabe; keine fachlichen Testdaten.
===============================================================================
*/
SET NOCOUNT ON;

DECLARE @DatabaseNames nvarchar(max)=QUOTENAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()));
DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit,@ErrorNumber int,@ErrorMessage nvarchar(2048);
DECLARE @Results TABLE
(
      [ModuleName] sysname NOT NULL
    , [StatusCode] varchar(40) NULL
    , [IsPartial] bit NULL
    , [JsonValid] bit NOT NULL
);

SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL; SET @ErrorNumber=NULL; SET @ErrorMessage=NULL;
EXEC [monitor].[USP_SpecialFeatureInventory]
     @DatabaseNames=@DatabaseNames,@MaxZeilen=20,@ResultSetArt='NONE',
     @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,
     @IsPartialOut=@Partial OUTPUT,@ErrorNumberOut=@ErrorNumber OUTPUT,@ErrorMessageOut=@ErrorMessage OUTPUT,
     @HighImpactConfirmed=1;
INSERT @Results VALUES(N'USP_SpecialFeatureInventory',@Status,@Partial,CONVERT(bit,COALESCE(ISJSON(@Json),0)));

SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_InMemoryOltpAnalysis]
     @DatabaseNames=@DatabaseNames,@MaxZeilen=20,@ResultSetArt='NONE',
     @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;
INSERT @Results VALUES(N'USP_InMemoryOltpAnalysis',@Status,@Partial,CONVERT(bit,COALESCE(ISJSON(@Json),0)));

SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_TemporalAnalysis]
     @DatabaseNames=@DatabaseNames,@MaxZeilen=20,@ResultSetArt='NONE',
     @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;
INSERT @Results VALUES(N'USP_TemporalAnalysis',@Status,@Partial,CONVERT(bit,COALESCE(ISJSON(@Json),0)));

SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_ServiceBrokerAnalysis]
     @DatabaseNames=@DatabaseNames,@MaxZeilen=20,@ResultSetArt='NONE',
     @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;
INSERT @Results VALUES(N'USP_ServiceBrokerAnalysis',@Status,@Partial,CONVERT(bit,COALESCE(ISJSON(@Json),0)));

SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_FullTextAnalysis]
     @DatabaseNames=@DatabaseNames,@MaxZeilen=20,@ResultSetArt='NONE',
     @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;
INSERT @Results VALUES(N'USP_FullTextAnalysis',@Status,@Partial,CONVERT(bit,COALESCE(ISJSON(@Json),0)));

SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_DataCaptureDeepAnalysis]
     @DatabaseNames=@DatabaseNames,@MaxZeilen=20,@ResultSetArt='NONE',
     @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;
INSERT @Results VALUES(N'USP_DataCaptureDeepAnalysis',@Status,@Partial,CONVERT(bit,COALESCE(ISJSON(@Json),0)));

SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_EncryptionAnalysis]
     @DatabaseNames=@DatabaseNames,@MaxZeilen=20,@ResultSetArt='NONE',
     @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;
INSERT @Results VALUES(N'USP_EncryptionAnalysis',@Status,@Partial,CONVERT(bit,COALESCE(ISJSON(@Json),0)));

SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_MaintenanceOperations]
     @DatabaseNames=@DatabaseNames,@MaxZeilen=20,@ResultSetArt='NONE',
     @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;
INSERT @Results VALUES(N'USP_MaintenanceOperations',@Status,@Partial,CONVERT(bit,COALESCE(ISJSON(@Json),0)));

IF EXISTS(SELECT 1 FROM @Results WHERE [JsonValid]=0 OR [StatusCode] IS NULL
          OR [StatusCode] IN ('INVALID_PARAMETER','INTERNAL_ERROR','ERROR_HANDLED'))
BEGIN
    DECLARE @Failed nvarchar(2048);
    SELECT @Failed=STRING_AGG(CONCAT([ModuleName],N'=',COALESCE([StatusCode],N'NULL'),N'/JSON=',[JsonValid]),N', ')
    FROM @Results WHERE [JsonValid]=0 OR [StatusCode] IS NULL
          OR [StatusCode] IN ('INVALID_PARAMETER','INTERNAL_ERROR','ERROR_HANDLED');
    THROW 54130,@Failed,1;
END;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedModules],
       N'Alle P2-Spezialfallmodule lieferten einen gueltigen Laufzeit-, Status- und JSON-Vertrag.' AS [Detail]
FROM @Results;
GO
