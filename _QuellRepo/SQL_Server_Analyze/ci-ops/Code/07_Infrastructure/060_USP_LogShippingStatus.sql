USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_LogShippingStatus
Version      : 1.0.1
Stand        : 2026-07-14
Typ          : Stored Procedure
Zweck        : Liest vorhandene Log-Shipping-Konfiguration und Monitorzustände für Primary- und Secondary-Datenbanken.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : msdb.dbo.log_shipping_primary_databases, log_shipping_monitor_primary, log_shipping_monitor_secondary, log_shipping_secondary_databases
Parameter    : @MaxZeilen, @PrintMeldungen, @Hilfe
Resultsets   : 1. Modulstatus. 2. Primary. 3. Secondary.
Berechtigung : Nur lesender Zugriff auf die genannten Systemobjekte. Das
               Framework vergibt keine Rechte und ändert keine Konfiguration.
Eigenlast    : Gering.
Locking      : LOCK_TIMEOUT 0; keine fachlichen Schreibzugriffe.
Partial      : Fehlende Features, Objekte oder Rechte werden strukturiert als
               Partial Result behandelt; andere Module bleiben ausführbar.
Änderungen   : 1.0.1 - Alertschwellen und History-Retention aus den
               Log-Shipping-Monitor-Tabellen gelesen.
               1.0.0 - Erstfassung Phase 6.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_LogShippingStatus]
 @MaxZeilen int=5000,@ResultSetArt varchar(16)='CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen bit=0,@Json nvarchar(max)=NULL OUTPUT,@PrintMeldungen bit=1,@Hilfe bit=0
AS
BEGIN
 SET NOCOUNT ON;
 SET @Json=NULL;
 DECLARE @ResultSetArtNormalisiert varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'primary',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @EffectiveMaxZeilen bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxZeilen) END;
 IF @Hilfe=1 BEGIN PRINT N'monitor.USP_LogShippingStatus'; PRINT N'@MaxZeilen int=5000: positive Werte begrenzen; NULL/0 = unbegrenzt; negative Werte sind ungültig. @PrintMeldungen bit=1; @Hilfe bit=0.'; RETURN; END;
 DECLARE @CollectionTimeUtc datetime2(3)=SYSUTCDATETIME(),@StatusCode varchar(40)='AVAILABLE',@IsPartial bit=0,@ErrorNumber int=NULL,@ErrorMessage nvarchar(2048)=NULL;
 IF @MaxZeilen<0 SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,@ErrorMessage=N'@MaxZeilen darf nicht negativ sein; NULL/0 bedeutet unbegrenzt.';
 CREATE TABLE [#LogShippingStatus_P]([PrimaryServer] sysname,[PrimaryDatabase] sysname,[BackupDirectory] nvarchar(500),[BackupShare] nvarchar(500),[BackupRetentionPeriod] int,[BackupThreshold] int,[ThresholdAlertEnabled] bit,[LastBackupFile] nvarchar(500),[LastBackupDate] datetime,[BackupAgeMinutes] int,[LastBackupDateUtc] datetime,[HistoryRetentionPeriod] int);
 CREATE TABLE [#LogShippingStatus_S]([SecondaryServer] sysname,[SecondaryDatabase] sysname,[PrimaryServer] sysname,[PrimaryDatabase] sysname,[RestoreDelay] int,[RestoreThreshold] int,[ThresholdAlertEnabled] bit,[LastCopiedFile] nvarchar(500),[LastCopiedDate] datetime,[CopyAgeMinutes] int,[LastRestoredFile] nvarchar(500),[LastRestoredDate] datetime,[RestoreAgeMinutes] int,[LastRestoredLatency] int,[RestoreMode] int,[DisconnectUsers] bit);
 IF @ResultSetArtNormalisiert NOT IN ('RAW','CONSOLE','NONE') SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,@ErrorMessage=N'@ResultSetArt muss CONSOLE, RAW, TABLE oder NONE enthalten.';
 SET LOCK_TIMEOUT 0;
 IF @StatusCode='AVAILABLE'
 BEGIN
  BEGIN TRY
  IF (SELECT COUNT(*)
      FROM [msdb].[sys].[tables] AS [t] WITH (NOLOCK)
      JOIN [msdb].[sys].[schemas] AS [s] WITH (NOLOCK)
        ON [s].[schema_id]=[t].[schema_id]
      WHERE [s].[name]=N'dbo'
        AND [t].[name] IN
            (N'log_shipping_primary_databases',N'log_shipping_monitor_primary',N'log_shipping_secondary_databases',N'log_shipping_monitor_secondary'))<>4
  BEGIN
   SET @StatusCode='UNAVAILABLE_FEATURE';
   SET @ErrorMessage=N'Erforderliche Log-Shipping-Konfigurations- oder Monitor-Tabellen sind nicht vorhanden.';
  END
  ELSE BEGIN
   INSERT [#LogShippingStatus_P]
   (
       [PrimaryServer], [PrimaryDatabase], [BackupDirectory], [BackupShare],
       [BackupRetentionPeriod], [BackupThreshold], [ThresholdAlertEnabled],
       [LastBackupFile], [LastBackupDate], [BackupAgeMinutes],
       [LastBackupDateUtc], [HistoryRetentionPeriod]
   )
   SELECT TOP (@EffectiveMaxZeilen)
       [mp].[primary_server], [p].[primary_database], [p].[backup_directory],
       [p].[backup_share], [p].[backup_retention_period], [mp].[backup_threshold],
       [mp].[threshold_alert_enabled], [mp].[last_backup_file],
       [mp].[last_backup_date], DATEDIFF(MINUTE, [mp].[last_backup_date], GETDATE()),
       [mp].[last_backup_date_utc], [mp].[history_retention_period]
   FROM [msdb].[dbo].[log_shipping_primary_databases] AS [p] WITH (NOLOCK)
   LEFT JOIN [msdb].[dbo].[log_shipping_monitor_primary] AS [mp] WITH (NOLOCK)
     ON [mp].[primary_id] = [p].[primary_id]
   ORDER BY [p].[primary_database];

   INSERT [#LogShippingStatus_S]
   (
       [SecondaryServer], [SecondaryDatabase], [PrimaryServer], [PrimaryDatabase],
       [RestoreDelay], [RestoreThreshold], [ThresholdAlertEnabled],
       [LastCopiedFile], [LastCopiedDate], [CopyAgeMinutes],
       [LastRestoredFile], [LastRestoredDate], [RestoreAgeMinutes],
       [LastRestoredLatency], [RestoreMode], [DisconnectUsers]
   )
   SELECT TOP (@EffectiveMaxZeilen)
       [ms].[secondary_server], [s].[secondary_database], [ms].[primary_server],
       [ms].[primary_database], [s].[restore_delay], [ms].[restore_threshold],
       [ms].[threshold_alert_enabled], [ms].[last_copied_file],
       [ms].[last_copied_date], DATEDIFF(MINUTE, [ms].[last_copied_date], GETDATE()),
       [ms].[last_restored_file], [ms].[last_restored_date],
       DATEDIFF(MINUTE, [ms].[last_restored_date], GETDATE()),
       [ms].[last_restored_latency], [s].[restore_mode], [s].[disconnect_users]
   FROM [msdb].[dbo].[log_shipping_secondary_databases] AS [s] WITH (NOLOCK)
   LEFT JOIN [msdb].[dbo].[log_shipping_monitor_secondary] AS [ms] WITH (NOLOCK)
     ON [ms].[secondary_id] = [s].[secondary_id]
   ORDER BY [s].[secondary_database];
  END
  END TRY BEGIN CATCH SELECT @StatusCode='ERROR_HANDLED',@IsPartial=1,@ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(); IF @PrintMeldungen=1 RAISERROR(N'Log Shipping konnte nicht vollständig gelesen werden: %s',10,1,@ErrorMessage) WITH NOWAIT; END CATCH;
 END;

 IF @ResultSetArtNormalisiert<>'NONE'
 BEGIN
  SELECT @CollectionTimeUtc AS [CollectionTimeUtc],CAST(N'monitor.USP_LogShippingStatus' AS nvarchar(256)) AS [ModuleName],@StatusCode AS [StatusCode],@IsPartial AS [IsPartial],@ErrorNumber AS [ErrorNumber],@ErrorMessage AS [ErrorMessage];
  IF @ResultSetArtNormalisiert='RAW'
  BEGIN SELECT * FROM [#LogShippingStatus_P] ORDER BY [PrimaryDatabase];SELECT * FROM [#LogShippingStatus_S] ORDER BY [SecondaryDatabase];END
  ELSE
  BEGIN
   SELECT N'Log-Shipping Primary' AS [Ergebnis],[x].*,CASE WHEN [BackupAgeMinutes] IS NULL THEN N'kein Zeitpunkt' ELSE CONCAT([BackupAgeMinutes],N' min') END AS [Backup-Alter] FROM [#LogShippingStatus_P] AS [x] ORDER BY [PrimaryDatabase];
   SELECT N'Log-Shipping Secondary' AS [Ergebnis],[x].*,CASE WHEN [RestoreAgeMinutes] IS NULL THEN N'kein Zeitpunkt' ELSE CONCAT([RestoreAgeMinutes],N' min') END AS [Restore-Alter] FROM [#LogShippingStatus_S] AS [x] ORDER BY [SecondaryDatabase];
  END
 END;
 IF @JsonErzeugen=1
 BEGIN
  DECLARE @MetaJson nvarchar(max)=(SELECT N'LogShippingStatus' [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@StatusCode [statusCode],@IsPartial [isPartial],@ErrorNumber [errorNumber],@ErrorMessage [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
  DECLARE @PrimaryJson nvarchar(max)=(SELECT * FROM [#LogShippingStatus_P] ORDER BY [PrimaryDatabase] FOR JSON PATH,INCLUDE_NULL_VALUES);
  DECLARE @SecondaryJson nvarchar(max)=(SELECT * FROM [#LogShippingStatus_S] ORDER BY [SecondaryDatabase] FOR JSON PATH,INCLUDE_NULL_VALUES);
  SET @Json=CONCAT(N'{"meta":',COALESCE(@MetaJson,N'{}'),N',"primary":',COALESCE(@PrimaryJson,N'[]'),N',"secondary":',COALESCE(@SecondaryJson,N'[]'),N'}');
 END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#LogShippingStatus_P'
            , @ResultLabel=N'LogShippingStatus'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#LogShippingStatus_P'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
