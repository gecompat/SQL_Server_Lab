USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 177_P1_Agent_Runtime_Contract.sql
Zweck        : Prüft Laufzeitverträge für vier P1-Agent- und Alert-Fälle.
Datenschutz  : Es werden keine Adressen, Empfänger, Jobbefehle, Schrittinhalte
               oder freien Mail-/Fehlermeldungstexte gelesen oder persistiert.
Nebenwirkung : Keine Änderung an SQL Agent, Alerts, Operatoren, Jobs oder Mail.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ExecutedCases TABLE([CaseId] varchar(40) NOT NULL PRIMARY KEY);
DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit,@ErrorNumber int,@ErrorMessage nvarchar(2048);

/* AGENT-MISSING: ein frisches disposable Target besitzt keine kritischen Benutzer-Alerts. */
EXEC [monitor].[USP_AgentMonitoringAnalysis]
     @HistoryHours=24,@MitJobStatus=0,@MitDatabaseMail=0,@MaxZeilen=100,
     @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@ErrorNumber OUTPUT,@ErrorMessageOut=@ErrorMessage OUTPUT;
IF ISJSON(@Json)<>1 OR @Status NOT IN('AVAILABLE_WITH_FINDING','AVAILABLE_LIMITED')
   OR NOT EXISTS
      (
          SELECT 1
          FROM OPENJSON(@Json,N'$.findings')
          WITH ([FindingCode] varchar(100) N'$.FindingCode',[Severity] varchar(16) N'$.Severity')
          WHERE [FindingCode]='REQUIRED_AGENT_ALERT_MISSING' AND [Severity]='HIGH'
      )
    THROW 55100,N'P1-Vertrag AGENT-MISSING fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('AGENT-MISSING');

/* AGENT-ROUTE: aktivierter Alert ohne Job oder Operatorroute ist hoch priorisiert. */
IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_InterpretAgentAlertRoute](1,0,0)
    WHERE [FindingCode]='ENABLED_ALERT_WITHOUT_ACTION' AND [FindingSeverity]='HIGH'
)
    THROW 55101,N'P1-Vertrag AGENT-ROUTE fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('AGENT-ROUTE');

/* AGENT-JOB: letzter fehlgeschlagener Lauf im Sichtfenster bleibt von Jobtext getrennt. */
IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_InterpretAgentJobState]
         (1,0,CONVERT(datetime,'2026-07-18T12:00:00',126),
              CONVERT(datetime,'2026-07-18T11:00:00',126),1,1)
    WHERE [FindingCode]='LATEST_JOB_RUN_FAILED_IN_WINDOW' AND [FindingSeverity]='HIGH'
)
    THROW 55102,N'P1-Vertrag AGENT-JOB fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('AGENT-JOB');

/* AGENT-MAIL: aggregierter Failed-Status wird ohne Mailinhalt hoch priorisiert. */
IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_InterpretDatabaseMailStatus]('failed')
    WHERE [FindingCode]='DATABASE_MAIL_FAILED_IN_WINDOW' AND [FindingSeverity]='HIGH'
)
    THROW 55103,N'P1-Vertrag AGENT-MAIL fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('AGENT-MAIL');

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>4
    THROW 55104,N'Der P1-Agent-Vertrag hat nicht alle vorgesehenen Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'Vier P1-Agent-/Alert-Fälle wurden ohne Änderung von msdb- oder Agentobjekten geprüft.' AS [Detail]
FROM @ExecutedCases;
GO
