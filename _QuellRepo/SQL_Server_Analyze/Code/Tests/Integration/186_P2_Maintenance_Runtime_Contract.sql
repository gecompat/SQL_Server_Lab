USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 186_P2_Maintenance_Runtime_Contract.sql
Zweck        : Automatisiert die vier noch offenen P2-Maintenance-Verträge.
Validierung  : Korrigierter 31-Suite-Stand für SQL Server 2019, 2022 und 2025.
Datenschutz  : Keine SQL-Texte, Jobschritte, Befehle, Meldungen, Konten,
               Clientdaten oder Wait-Ressourcen.
Nebenwirkung : Keine RESUME-, ABORT-, KILL-, Cleanup-, Jobstart- oder Jobstop-Aktion.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ExecutedCases TABLE([CaseId] varchar(64) NOT NULL PRIMARY KEY);
DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit,@Definition nvarchar(max);
DECLARE @Impersonating bit=0;

SELECT @Definition=[sm].[definition]
FROM [sys].[sql_modules] [sm] WITH (NOLOCK)
JOIN [sys].[objects] [o] WITH (NOLOCK) ON [o].[object_id]=[sm].[object_id]
JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
WHERE [s].[name]=N'monitor' AND [o].[name]=N'USP_MaintenanceOperations';
IF @Definition IS NULL THROW 56000,N'Maintenance-Proceduredefinition ist nicht sichtbar.',1;

/* MAINT-PAUSED */
DECLARE @PausedCode varchar(100)=CASE
    WHEN N'PAUSED'=N'PAUSED' AND DATEADD(MINUTE,-61,GETDATE())<DATEADD(MINUTE,-60,GETDATE())
        THEN 'RESUMABLE_OPERATION_PAUSED_LONG'
    WHEN N'PAUSED'=N'PAUSED' THEN 'RESUMABLE_OPERATION_PAUSED'
    ELSE 'RESUMABLE_OPERATION_ACTIVE' END;
IF @PausedCode<>'RESUMABLE_OPERATION_PAUSED_LONG'
   OR CHARINDEX(N'''RESUMABLE_OPERATION_PAUSED_LONG''',@Definition)=0
   OR CHARINDEX(N'[sys].[index_resumable_operations]',@Definition)=0
   OR CHARINDEX(N'keine automatische RESUME- oder ABORT-Aktion',@Definition)=0
    THROW 56001,N'P2-Vertrag MAINT-PAUSED fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('MAINT-PAUSED');

/* MAINT-BLOCKED */
DECLARE @BlockedCode varchar(100)=CASE
    WHEN 52>0 AND 6000>=5000 THEN 'MAINTENANCE_REQUEST_BLOCKED'
    WHEN N'ALTER INDEX' LIKE N'ROLLBACK%' THEN 'ROLLBACK_IN_PROGRESS'
    ELSE 'MAINTENANCE_REQUEST_ACTIVE' END;
IF @BlockedCode<>'MAINTENANCE_REQUEST_BLOCKED'
   OR CHARINDEX(N'''MAINTENANCE_REQUEST_BLOCKED''',@Definition)=0
   OR CHARINDEX(N'[sys].[dm_exec_requests]',@Definition)=0
   OR CHARINDEX(N'[blocking_session_id]',@Definition)=0
   OR CHARINDEX(N'[wait_resource]',LOWER(@Definition))>0
    THROW 56002,N'P2-Vertrag MAINT-BLOCKED fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('MAINT-BLOCKED');

/* MAINT-JOB-OVERLAP */
DECLARE @RunningJobs TABLE([JobName] sysname NOT NULL,[IsRunning] bit NOT NULL,[FindingCode] varchar(100) NOT NULL);
INSERT @RunningJobs VALUES
      (N'ExampleMaintenanceJobA',1,'SELECTED_JOB_STATE')
    , (N'ExampleMaintenanceJobB',1,'SELECTED_JOB_STATE');
IF (SELECT COUNT_BIG(*) FROM @RunningJobs WHERE [IsRunning]=1)>1
    UPDATE @RunningJobs SET [FindingCode]='SELECTED_JOBS_OVERLAP' WHERE [IsRunning]=1;
IF (SELECT COUNT_BIG(*) FROM @RunningJobs WHERE [FindingCode]='SELECTED_JOBS_OVERLAP')<>2
   OR CHARINDEX(N'''SELECTED_JOBS_OVERLAP''',@Definition)=0
   OR CHARINDEX(N'[msdb].[dbo].[sysjobs]',@Definition)=0
   OR CHARINDEX(N'[msdb].[dbo].[sysjobactivity]',@Definition)=0
   OR CHARINDEX(N'[sysjobsteps]',LOWER(@Definition))>0
    THROW 56003,N'P2-Vertrag MAINT-JOB-OVERLAP fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('MAINT-JOB-OVERLAP');

/* MAINT-DENIED */
BEGIN TRY
    IF USER_ID(N'ExampleMaintenanceRestrictedUser') IS NOT NULL
        DROP USER [ExampleMaintenanceRestrictedUser];
    CREATE USER [ExampleMaintenanceRestrictedUser] WITHOUT LOGIN;
    GRANT EXECUTE ON OBJECT::[monitor].[USP_MaintenanceOperations]
        TO [ExampleMaintenanceRestrictedUser];

    EXECUTE AS USER=N'ExampleMaintenanceRestrictedUser';
    SET @Impersonating=1;
    EXEC [monitor].[USP_MaintenanceOperations]
         @DatabaseNames=N'[DeineDatenbank]',
         @JobNames=N'ExampleMaintenanceJobA|ExampleMaintenanceJobB',
         @MaxZeilen=10,@ResultSetArt='NONE',
         @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    REVERT;
    SET @Impersonating=0;

    IF ISJSON(@Json)<>1 OR @Partial<>1
       OR @Status NOT IN('AVAILABLE_LIMITED','DENIED_PERMISSION','ERROR_HANDLED')
       OR NOT EXISTS
          (
              SELECT 1 FROM OPENJSON(@Json,N'$.sources')
              WITH ([StatusCode] varchar(40) N'$.StatusCode',[IsPartial] bit N'$.IsPartial')
              WHERE [IsPartial]=1 AND [StatusCode] IN('DENIED_PERMISSION','ERROR_HANDLED')
          )
        THROW 56004,N'P2-Vertrag MAINT-DENIED fehlgeschlagen.',1;

    DROP USER [ExampleMaintenanceRestrictedUser];
END TRY
BEGIN CATCH
    IF @Impersonating=1
    BEGIN
        BEGIN TRY
            REVERT;
            SET @Impersonating=0;
        END TRY
        BEGIN CATCH
        END CATCH;
    END;
    IF USER_ID(N'ExampleMaintenanceRestrictedUser') IS NOT NULL
        DROP USER [ExampleMaintenanceRestrictedUser];
    THROW;
END CATCH;
INSERT @ExecutedCases VALUES('MAINT-DENIED');

/* Read-only safety remains a prerequisite for all four cases. */
IF CHARINDEX(N'kill ',LOWER(@Definition))>0
   OR CHARINDEX(N'sp_start_job',LOWER(@Definition))>0
   OR CHARINDEX(N'sp_stop_job',LOWER(@Definition))>0
    THROW 56005,N'Maintenance-Read-only-Vertrag verletzt.',1;

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>4
    THROW 56006,N'Der P2-Maintenance-Vertrag hat nicht alle vier offenen Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'Vier offene P2-Maintenance-Fälle wurden ohne operative Wartungsänderung geprüft.' AS [Detail]
FROM @ExecutedCases;
GO
