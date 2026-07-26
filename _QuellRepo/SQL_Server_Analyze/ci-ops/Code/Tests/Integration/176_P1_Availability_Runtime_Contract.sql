USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 176_P1_Availability_Runtime_Contract.sql
Zweck        : Prüft Laufzeitverträge für vier P1-Availability-Fälle.
Datenschutz  : Ausschließlich technische SERVERPROPERTY-Werte und vollständig
               synthetische Status-/Zählerwerte; keine Clusterobjekte werden erzeugt.
Nebenwirkung : Keine. Es erfolgt kein Failover, Suspend, Resume oder Seeding.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ExecutedCases TABLE([CaseId] varchar(40) NOT NULL PRIMARY KEY);
DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit,@ErrorNumber int,@ErrorMessage nvarchar(2048);

/* AG-NONE: disposable Linux-Ziele besitzen kein aktiviertes HADR. */
IF COALESCE(TRY_CONVERT(int,SERVERPROPERTY(N'IsHadrEnabled')),0)=1
    THROW 55000,N'P1-Vertrag AG-NONE benötigt ein Target ohne aktiviertes HADR.',1;

EXEC [monitor].[USP_AvailabilityDeepAnalysis]
     @MaxZeilen=10,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,
     @PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@ErrorNumber OUTPUT,@ErrorMessageOut=@ErrorMessage OUTPUT;
IF ISJSON(@Json)<>1 OR @Status<>'NOT_APPLICABLE' OR @Partial<>0 OR @ErrorNumber IS NOT NULL
   OR JSON_VALUE(@Json,N'$.meta.statusCode')<>N'NOT_APPLICABLE'
   OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.replicas'))<>0
   OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.databases'))<>0
   OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.seeding'))<>0
    THROW 55001,N'P1-Vertrag AG-NONE fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('AG-NONE');

/* AG-SUSPEND: Suspendierung besitzt Priorität und hohe Severity. */
IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_InterpretAvailabilityDatabaseState]
         (1,N'HEALTHY',N'SYNCHRONIZED',0,0,0,1024,60)
    WHERE [FindingCode]='DATA_MOVEMENT_SUSPENDED' AND [FindingSeverity]='HIGH'
)
    THROW 55002,N'P1-Vertrag AG-SUSPEND fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('AG-SUSPEND');

/* AG-QUEUE: Schwellwert wird in MB konfiguriert und gegen KB-DMV-Werte geprüft. */
IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_InterpretAvailabilityDatabaseState]
         (0,N'HEALTHY',N'SYNCHRONIZING',1048576,0,0,1024,60)
    WHERE [FindingCode]='LOG_SEND_QUEUE_THRESHOLD' AND [FindingSeverity]='MEDIUM'
)
    THROW 55003,N'P1-Vertrag AG-QUEUE fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('AG-QUEUE');

/* AG-SEED: sichtbare Bytezähler liefern begrenzten Fortschritt ohne freie Meldungstexte. */
IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_InterpretAvailabilitySeedingState](NULL,400,1000,100,NULL)
    WHERE [ProgressPercent]=40.0000 AND [RemainingBytes]=600
      AND [FindingCode]='SEEDING_IN_PROGRESS' AND [FindingSeverity]='INFO'
)
    THROW 55004,N'P1-Vertrag AG-SEED fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('AG-SEED');

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>4
    THROW 55005,N'Der P1-Availability-Vertrag hat nicht alle vorgesehenen Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'Vier P1-Availability-Fälle wurden ohne Cluster- oder Konfigurationsänderung geprüft.' AS [Detail]
FROM @ExecutedCases;
GO
