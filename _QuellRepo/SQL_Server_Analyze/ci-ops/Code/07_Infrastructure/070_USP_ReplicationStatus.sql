USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ReplicationStatus
Version      : 1.1.0
Stand        : 2026-07-14
Typ          : Stored Procedure
Zweck        : Inventarisiert sichtbare Replication-Rollen, Publikationen, Subscriptions und Agentfehler.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : sys.databases, distribution.dbo.MSpublications/MSsubscriptions/MSdistribution_agents/MSrepl_errors, msdb Agent-Metadaten
Parameter    : @MitDistributionDetails, @MaxZeilen, @PrintMeldungen, @Hilfe
Resultsets   : 1. Modulstatus. 2. Server-/Datenbankrollen. 3. Publikationen. 4. Subscriptions. 5. Agentfehler.
Berechtigung : Nur lesender Zugriff auf die genannten Systemobjekte. Das
               Framework vergibt keine Rechte und ändert keine Konfiguration.
Eigenlast    : Mittel; optionale Distribution-DB-Auswertung.
Locking      : LOCK_TIMEOUT 0; keine fachlichen Schreibzugriffe.
Partial      : Fehlende Features, Objekte oder Rechte werden strukturiert als
               Partial Result behandelt; andere Module bleiben ausführbar.
Änderungen   : 1.1.0 - Negative @MaxZeilen-Werte werden vor Rechte- und
               Datenzugriffen strukturiert abgewiesen.
               1.0.0 - Erstfassung Phase 6.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_ReplicationStatus]
 @MitDistributionDetails bit=0,@MaxZeilen int=5000,@HighImpactConfirmed bit=0,@ResultSetArt varchar(16)='CONSOLE'
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
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'databases',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @EffectiveMaxZeilen bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxZeilen) END;
 IF @Hilfe=1 BEGIN PRINT N'monitor.USP_ReplicationStatus'; PRINT N'@MitDistributionDetails bit=0: liest die konfigurierte Distribution-Datenbank.'; PRINT N'@MaxZeilen int=5000: positive Werte begrenzen; NULL/0 = unbegrenzt; negative Werte sind ungültig. @PrintMeldungen bit=1; @Hilfe bit=0.'; RETURN; END;
 DECLARE @CollectionTimeUtc datetime2(3)=SYSUTCDATETIME(),@StatusCode varchar(40)='AVAILABLE',@IsPartial bit=0,@ErrorNumber int=NULL,@ErrorMessage nvarchar(2048)=NULL,@DistDb sysname=NULL,@sql nvarchar(max),@Allowed bit=1;
 IF @MaxZeilen<0 SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,@ErrorMessage=N'@MaxZeilen darf nicht negativ sein; NULL/0 bedeutet unbegrenzt.';
 CREATE TABLE [#ReplicationStatus_Db]([DatabaseName] sysname,[IsPublished] bit,[IsSubscribed] bit,[IsMergePublished] bit,[IsDistributor] bit);
 CREATE TABLE [#ReplicationStatus_Pub]([PublicationId] int,[PublisherDatabase] sysname,[PublicationName] sysname,[PublicationType] int,[ImmediateSync] bit,[AllowPush] bit,[AllowPull] bit,[Status] int);
 CREATE TABLE [#ReplicationStatus_Sub]([PublisherDatabase] sysname,[PublicationName] sysname,[SubscriberName] sysname,[SubscriberDatabase] sysname,[SubscriptionType] int,[Status] int,[AgentId] int,[LastAction] nvarchar(4000),[LastTimestamp] datetime);
 CREATE TABLE [#ReplicationStatus_Err]([ErrorId] int,[ErrorTime] datetime,[SourceName] nvarchar(100),[ErrorCode] int,[ErrorText] nvarchar(4000));
 IF @StatusCode='AVAILABLE' AND @MitDistributionDetails=1 EXEC [monitor].[InternalCheckAnalysisPath] @AnalysisClass='ENTERPRISE_TOPOLOGY_DEEP',@HighImpactConfirmed=@HighImpactConfirmed,@StatusCode=@StatusCode OUTPUT,@ErrorMessage=@ErrorMessage OUTPUT;
 IF @ResultSetArtNormalisiert NOT IN ('RAW','CONSOLE','NONE') SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,@ErrorMessage=N'@ResultSetArt muss CONSOLE, RAW, TABLE oder NONE enthalten.';
 SET LOCK_TIMEOUT 0;
 IF @StatusCode='AVAILABLE' BEGIN TRY
  INSERT [#ReplicationStatus_Db] SELECT TOP (@EffectiveMaxZeilen) [name],[is_published],[is_subscribed],[is_merge_published],[is_distributor] FROM [sys].[databases] WITH (NOLOCK) WHERE [is_published]=1 OR [is_subscribed]=1 OR [is_merge_published]=1 OR [is_distributor]=1 ORDER BY [name];
  IF @MitDistributionDetails=1
  BEGIN
   SELECT TOP(1) @DistDb=[name] FROM [sys].[databases] WITH (NOLOCK) WHERE [is_distributor]=1 AND [state]=0;
   IF @DistDb IS NULL BEGIN SET @IsPartial=1; IF NOT EXISTS(SELECT 1 FROM [#ReplicationStatus_Db]) SET @StatusCode='UNAVAILABLE_FEATURE'; SET @ErrorMessage=N'Keine online sichtbare Distribution-Datenbank gefunden.'; END
   ELSE BEGIN
    SET @sql=N'IF EXISTS(SELECT 1 FROM '+QUOTENAME(@DistDb)+N'.[sys].[tables] AS [t] WITH (NOLOCK) JOIN '+QUOTENAME(@DistDb)+N'.[sys].[schemas] AS [sc] WITH (NOLOCK) ON [sc].[schema_id]=[t].[schema_id] WHERE [sc].[name]=N''dbo'' AND [t].[name]=N''MSpublications'') INSERT [#ReplicationStatus_Pub] ([PublicationId],[PublisherDatabase],[PublicationName],[PublicationType],[ImmediateSync],[AllowPush],[AllowPull],[Status]) SELECT TOP (@EffectiveMaxZeilen) [publication_id],[publisher_db],[publication],[publication_type],[immediate_sync],[allow_push],[allow_pull],[status] FROM '+QUOTENAME(@DistDb)+N'.[dbo].[MSpublications] WITH (NOLOCK) ORDER BY [publisher_db],[publication];';
    EXEC [sys].[sp_executesql] @sql,N'@EffectiveMaxZeilen bigint',@EffectiveMaxZeilen=@EffectiveMaxZeilen;
    SET @sql=N'IF EXISTS(SELECT 1 FROM '+QUOTENAME(@DistDb)+N'.[sys].[tables] AS [t] WITH (NOLOCK) JOIN '+QUOTENAME(@DistDb)+N'.[sys].[schemas] AS [sc] WITH (NOLOCK) ON [sc].[schema_id]=[t].[schema_id] WHERE [sc].[name]=N''dbo'' AND [t].[name]=N''MSsubscriptions'') INSERT [#ReplicationStatus_Sub] ([PublisherDatabase],[PublicationName],[SubscriberName],[SubscriberDatabase],[SubscriptionType],[Status],[AgentId],[LastAction],[LastTimestamp]) SELECT TOP (@EffectiveMaxZeilen) [s].[publisher_db],[p].[publication],[a].[subscriber_name],[s].[subscriber_db],[s].[subscription_type],[s].[status],[s].[agent_id],[h].[comments],[h].[time] FROM '+QUOTENAME(@DistDb)+N'.[dbo].[MSsubscriptions] AS [s] WITH (NOLOCK) LEFT JOIN '+QUOTENAME(@DistDb)+N'.[dbo].[MSpublications] AS [p] WITH (NOLOCK) ON [p].[publication_id]=[s].[publication_id] LEFT JOIN '+QUOTENAME(@DistDb)+N'.[dbo].[MSdistribution_agents] AS [a] WITH (NOLOCK) ON [a].[id]=[s].[agent_id] OUTER APPLY (SELECT TOP (1) [dh].[comments],[dh].[time] FROM '+QUOTENAME(@DistDb)+N'.[dbo].[MSdistribution_history] AS [dh] WITH (NOLOCK) WHERE [dh].[agent_id]=[s].[agent_id] ORDER BY [dh].[time] DESC) AS [h] ORDER BY [s].[publisher_db],[p].[publication];';
    EXEC [sys].[sp_executesql] @sql,N'@EffectiveMaxZeilen bigint',@EffectiveMaxZeilen=@EffectiveMaxZeilen;
    SET @sql=N'IF EXISTS(SELECT 1 FROM '+QUOTENAME(@DistDb)+N'.[sys].[tables] AS [t] WITH (NOLOCK) JOIN '+QUOTENAME(@DistDb)+N'.[sys].[schemas] AS [sc] WITH (NOLOCK) ON [sc].[schema_id]=[t].[schema_id] WHERE [sc].[name]=N''dbo'' AND [t].[name]=N''MSrepl_errors'') INSERT [#ReplicationStatus_Err] ([ErrorId],[ErrorTime],[SourceName],[ErrorCode],[ErrorText]) SELECT TOP (@EffectiveMaxZeilen) [id],[time],[source_name],[error_code],[error_text] FROM '+QUOTENAME(@DistDb)+N'.[dbo].[MSrepl_errors] WITH (NOLOCK) ORDER BY [time] DESC;';
    EXEC [sys].[sp_executesql] @sql,N'@EffectiveMaxZeilen bigint',@EffectiveMaxZeilen=@EffectiveMaxZeilen;
   END
  END
 END TRY BEGIN CATCH SELECT @StatusCode='ERROR_HANDLED',@IsPartial=1,@ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(); IF @PrintMeldungen=1 RAISERROR(N'Replication konnte nicht vollständig gelesen werden: %s',10,1,@ErrorMessage) WITH NOWAIT; END CATCH;

 IF @ResultSetArtNormalisiert<>'NONE'
 BEGIN
  SELECT @CollectionTimeUtc AS [CollectionTimeUtc],CAST(N'monitor.USP_ReplicationStatus' AS nvarchar(256)) AS [ModuleName],@StatusCode AS [StatusCode],@IsPartial AS [IsPartial],@ErrorNumber AS [ErrorNumber],@ErrorMessage AS [ErrorMessage];
  IF @ResultSetArtNormalisiert='RAW'
  BEGIN SELECT * FROM [#ReplicationStatus_Db] ORDER BY [DatabaseName];SELECT * FROM [#ReplicationStatus_Pub] ORDER BY [PublisherDatabase],[PublicationName];SELECT * FROM [#ReplicationStatus_Sub] ORDER BY [PublisherDatabase],[PublicationName];SELECT * FROM [#ReplicationStatus_Err] ORDER BY [ErrorTime] DESC;END
  ELSE
  BEGIN SELECT N'Replikations-Datenbank' [Ergebnis],[x].* FROM [#ReplicationStatus_Db] [x] ORDER BY [DatabaseName];SELECT N'Replikations-Publikation' [Ergebnis],[x].* FROM [#ReplicationStatus_Pub] [x] ORDER BY [PublisherDatabase],[PublicationName];SELECT N'Replikations-Subscription' [Ergebnis],[x].* FROM [#ReplicationStatus_Sub] [x] ORDER BY [PublisherDatabase],[PublicationName];SELECT N'Replikationsfehler' [Ergebnis],[x].* FROM [#ReplicationStatus_Err] [x] ORDER BY [ErrorTime] DESC;END
 END;
 IF @JsonErzeugen=1
 BEGIN
  DECLARE @MetaJson nvarchar(max)=(SELECT N'ReplicationStatus' [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@StatusCode [statusCode],@IsPartial [isPartial],@ErrorNumber [errorNumber],@ErrorMessage [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
  DECLARE @DbJson nvarchar(max)=(SELECT * FROM [#ReplicationStatus_Db] ORDER BY [DatabaseName] FOR JSON PATH,INCLUDE_NULL_VALUES),@PubJson nvarchar(max)=(SELECT * FROM [#ReplicationStatus_Pub] ORDER BY [PublisherDatabase],[PublicationName] FOR JSON PATH,INCLUDE_NULL_VALUES),@SubJson nvarchar(max)=(SELECT * FROM [#ReplicationStatus_Sub] ORDER BY [PublisherDatabase],[PublicationName] FOR JSON PATH,INCLUDE_NULL_VALUES),@ErrJson nvarchar(max)=(SELECT * FROM [#ReplicationStatus_Err] ORDER BY [ErrorTime] DESC FOR JSON PATH,INCLUDE_NULL_VALUES);
  SET @Json=CONCAT(N'{"meta":',COALESCE(@MetaJson,N'{}'),N',"databases":',COALESCE(@DbJson,N'[]'),N',"publications":',COALESCE(@PubJson,N'[]'),N',"subscriptions":',COALESCE(@SubJson,N'[]'),N',"errors":',COALESCE(@ErrJson,N'[]'),N'}');
 END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#ReplicationStatus_Db'
            , @ResultLabel=N'ReplicationStatus'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#ReplicationStatus_Db'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
