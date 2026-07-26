USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 171_P1_Contention_Runtime_Contract.sql
Zweck        : Prüft deterministische und begrenzte Verträge für die vier
               P1-Fälle der internen Contention-Analyse.
Datenschutz  : Nur synthetische Zahlenwerte und technische Zustände; keine
               Laufzeitausgabe wird in Repositoryartefakte geschrieben.
Nebenwirkung : Eine reale Ein-Sekunden-Messung; keine Zähler werden gelöscht.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit,@ErrorNumber int;
DECLARE @ErrorMessage nvarchar(2048);
DECLARE @FailureMessage nvarchar(2048);
DECLARE @ExecutedCases TABLE([CaseId] varchar(40) NOT NULL PRIMARY KEY);

/* CONT-DELTA: Produktionsrechenpfad und reale Sample-Metadaten. */
IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_InterpretContentionCounter](100,125,1,CONVERT(decimal(19,6),0.5))
    WHERE [CounterValue]=25 AND [RatePerSecond]=50.0000 AND [CounterResetDetected]=0
)
    THROW 54500,N'P1-Vertrag CONT-DELTA fehlgeschlagen.',1;

EXEC [monitor].[USP_InternalContentionAnalysis]
     @SampleSeconds=1,@MitSpinlocks=1,@MitHotPages=0,@MitPageDetails=0,
     @MaxZeilen=100,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,
     @PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@ErrorNumber OUTPUT,@ErrorMessageOut=@ErrorMessage OUTPUT;
IF ISJSON(@Json)<>1
    THROW 54501,N'P1-Laufzeitvertrag CONT-DELTA lieferte keinen gültigen JSON-Vertrag.',1;
IF @Status NOT IN('AVAILABLE','AVAILABLE_WITH_FINDING')
BEGIN
    IF CHARINDEX(N'#LatchStart',COALESCE(@ErrorMessage,N''))>0
        THROW 54510,N'P1-Laufzeitvertrag CONT-DELTA: SNAPSHOT_KEY_LATCH_START.',1;
    IF CHARINDEX(N'#LatchEnd',COALESCE(@ErrorMessage,N''))>0
        THROW 54511,N'P1-Laufzeitvertrag CONT-DELTA: SNAPSHOT_KEY_LATCH_END.',1;
    IF CHARINDEX(N'#SpinStart',COALESCE(@ErrorMessage,N''))>0
        THROW 54512,N'P1-Laufzeitvertrag CONT-DELTA: SNAPSHOT_KEY_SPIN_START.',1;
    IF CHARINDEX(N'#SpinEnd',COALESCE(@ErrorMessage,N''))>0
        THROW 54513,N'P1-Laufzeitvertrag CONT-DELTA: SNAPSHOT_KEY_SPIN_END.',1;
    SET @FailureMessage=CONCAT(N'P1-Laufzeitvertrag CONT-DELTA: technischer Status; ErrorNumber=',
                               COALESCE(CONVERT(varchar(20),@ErrorNumber),'NULL'),N'.');
    THROW 54506,@FailureMessage,1;
END;
IF NOT EXISTS
      (SELECT 1 FROM OPENJSON(@Json,N'$.meta')
       WITH ([Requested] int N'$.requestedSampleSeconds',[Actual] decimal(19,6) N'$.actualSampleSeconds')
       WHERE [Requested]=1 AND [Actual]>0)
    THROW 54507,N'P1-Laufzeitvertrag CONT-DELTA verletzte den Sample-Metavertrag.',1;
IF EXISTS
      (SELECT 1 FROM OPENJSON(@Json,N'$.latches')
       WITH ([MeasurementKind] varchar(30) N'$.MeasurementKind')
       WHERE [MeasurementKind]<>'SAMPLE_DELTA')
    THROW 54508,N'P1-Laufzeitvertrag CONT-DELTA verletzte den Latch-Messartvertrag.',1;
IF EXISTS
      (SELECT 1 FROM OPENJSON(@Json,N'$.spinlocks')
       WITH ([MeasurementKind] varchar(30) N'$.MeasurementKind')
       WHERE [MeasurementKind]<>'SAMPLE_DELTA')
    THROW 54509,N'P1-Laufzeitvertrag CONT-DELTA verletzte den Spinlock-Messartvertrag.',1;
INSERT @ExecutedCases VALUES('CONT-DELTA');

/* CONT-CUM: Sample 0 liefert nur eindeutig kumulative Werte ohne Rate. */
SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_InternalContentionAnalysis]
     @SampleSeconds=0,@MitSpinlocks=1,@MitHotPages=0,@MitPageDetails=0,
     @MaxZeilen=100,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,
     @PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT;
IF ISJSON(@Json)<>1 OR @Status NOT IN('AVAILABLE','AVAILABLE_WITH_FINDING')
   OR NOT EXISTS
      (SELECT 1 FROM OPENJSON(@Json,N'$.meta')
       WITH ([Requested] int N'$.requestedSampleSeconds') WHERE [Requested]=0)
   OR EXISTS
      (SELECT 1 FROM OPENJSON(@Json,N'$.latches')
       WITH ([MeasurementKind] varchar(30) N'$.MeasurementKind',
             [Rate] decimal(19,4) N'$.WaitsPerSecond',[Reset] bit N'$.CounterResetDetected')
       WHERE [MeasurementKind]<>'CUMULATIVE_SINCE_START' OR [Rate] IS NOT NULL OR [Reset]<>0)
   OR EXISTS
      (SELECT 1 FROM OPENJSON(@Json,N'$.spinlocks')
       WITH ([MeasurementKind] varchar(30) N'$.MeasurementKind',
             [Rate] decimal(19,4) N'$.CollisionsPerSecond',[Reset] bit N'$.CounterResetDetected')
       WHERE [MeasurementKind]<>'CUMULATIVE_SINCE_START' OR [Rate] IS NOT NULL OR [Reset]<>0)
    THROW 54502,N'P1-Vertrag CONT-CUM fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('CONT-CUM');

/* CONT-RESET: fallender synthetischer Counter nutzt exakt den Produktionspfad. */
IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_InterpretContentionCounter](9,3,1,CONVERT(decimal(19,6),1))
    WHERE [CounterValue] IS NULL AND [RatePerSecond] IS NULL AND [CounterResetDetected]=1
)
    THROW 54503,N'P1-Vertrag CONT-RESET fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('CONT-RESET');

/* CONT-PAGE: opt-in-Auflösung bleibt auf höchstens eine aktuelle Zeile begrenzt. */
SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_InternalContentionAnalysis]
     @SampleSeconds=0,@MitSpinlocks=0,@MitHotPages=1,@MitPageDetails=1,
     @MaxZeilen=1,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,
     @PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT;
IF ISJSON(@Json)<>1 OR @Status NOT IN('AVAILABLE','AVAILABLE_WITH_FINDING')
   OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.hotPages'))>1
    THROW 54504,N'P1-Vertrag CONT-PAGE fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('CONT-PAGE');

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>4
    THROW 54505,N'Der P1-Contention-Vertrag hat nicht alle vorgesehenen Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'Vier P1-Contention-Fälle wurden ohne persistierte Laufzeitausgabe ausgeführt.' AS [Detail]
FROM @ExecutedCases;
GO
