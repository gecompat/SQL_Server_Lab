USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ServerMemory
Version      : 2.0.0
Stand        : 2026-07-15
Zweck        : Liefert Angaben zu Betriebssystem-, Prozess- und SQL-Speicher,
               Memory Model, Clerks und Grants.
Datenquellen : sys.dm_os_sys_memory, sys.dm_os_process_memory, sys.dm_os_sys_info, sys.configurations, sys.dm_os_memory_clerks, sys.dm_exec_query_memory_grants
Vertrag      : Resultset 1 ist immer Modulstatus; @ResultSetArt=NONE unterdrückt Resultsets; RAW und CONSOLE liefern unterschiedliche Projektionen. Optional JSON.
===============================================================================
*/

CREATE OR ALTER PROCEDURE [monitor].[USP_ServerMemory]
 @MaxZeilen int=100,@PrintMeldungen bit=1,@Hilfe bit=0,@ResultSetArt varchar(16)='CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen bit=0,@Json nvarchar(max)=NULL OUTPUT,
 @StatusCodeOut varchar(40)=NULL OUTPUT,@IsPartialOut bit=NULL OUTPUT,@ErrorNumberOut int=NULL OUTPUT,@ErrorMessageOut nvarchar(2048)=NULL OUTPUT
AS
BEGIN
 SET NOCOUNT ON;SET @Json=NULL;DECLARE @ResultSetArtNormalisiert varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'summary',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @EffectiveMaxZeilen bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxZeilen) END;IF @Hilfe=1 BEGIN PRINT N'monitor.USP_ServerMemory @MaxZeilen=100';RETURN;END;
 DECLARE @T datetime2(3)=SYSUTCDATETIME(),@S varchar(40)='AVAILABLE',@P bit=0,@E int=NULL,@M nvarchar(2048)=NULL;
 IF @ResultSetArtNormalisiert NOT IN('RAW','CONSOLE','NONE') SELECT @S='INVALID_PARAMETER',@P=1,@M=N'@ResultSetArt muss CONSOLE, RAW, TABLE oder NONE enthalten.';
 CREATE TABLE [#ServerMemory_Summary]([total_physical_memory_kb] bigint,[available_physical_memory_kb] bigint,[system_memory_state_desc] nvarchar(256),[physical_memory_in_use_kb] bigint,[locked_page_allocations_kb] bigint,[large_page_allocations_kb] bigint,[process_physical_memory_low] bit,[process_virtual_memory_low] bit,[committed_kb] bigint,[committed_target_kb] bigint,[visible_target_kb] bigint,[sql_memory_model_desc] nvarchar(60),[min_server_memory_mb] bigint,[max_server_memory_mb] bigint,[LPIMAssessment] varchar(50),[MemoryFinding] varchar(60));
 CREATE TABLE [#ServerMemory_C]([type] nvarchar(60),[pages_kb] bigint,[virtual_memory_committed_kb] bigint,[awe_allocated_kb] bigint,[shared_memory_committed_kb] bigint);
 CREATE TABLE [#ServerMemory_G]([ActiveOrWaitingGrants] bigint,[RequestedMemoryKb] bigint,[GrantedMemoryKb] bigint,[UsedMemoryKb] bigint,[WaitingGrantCount] bigint);
 IF @MaxZeilen<0 SELECT @S='INVALID_PARAMETER',@P=1,@M=N'@MaxZeilen darf nicht negativ sein; NULL/0 bedeutet unbegrenzt.';
 ELSE BEGIN SET LOCK_TIMEOUT 0;BEGIN TRY
  INSERT [#ServerMemory_Summary]
  SELECT [sm].[total_physical_memory_kb],[sm].[available_physical_memory_kb],[sm].[system_memory_state_desc],[pm].[physical_memory_in_use_kb],[pm].[locked_page_allocations_kb],[pm].[large_page_allocations_kb],[pm].[process_physical_memory_low],[pm].[process_virtual_memory_low],[si].[committed_kb],[si].[committed_target_kb],[si].[visible_target_kb],[si].[sql_memory_model_desc],
    MIN(CASE WHEN [c].[name]='min server memory (MB)' THEN CONVERT(bigint,[c].[value_in_use]) END),MAX(CASE WHEN [c].[name]='max server memory (MB)' THEN CONVERT(bigint,[c].[value_in_use]) END),
    CASE WHEN [si].[sql_memory_model_desc] LIKE '%LOCK%' OR [pm].[locked_page_allocations_kb]>0 THEN 'LOCKED_PAGES_IN_USE_OR_MODEL' ELSE 'LPIM_NOT_CONFIRMED_BY_RUNTIME' END,
    CASE WHEN [pm].[process_physical_memory_low]=1 OR [pm].[process_virtual_memory_low]=1 THEN 'PROCESS_MEMORY_LOW' WHEN [si].[committed_target_kb]<[si].[committed_kb] THEN 'TARGET_BELOW_COMMITTED' WHEN [sm].[available_physical_memory_kb]<1048576 THEN 'LOW_OS_FREE_MEMORY_REVIEW' ELSE 'OK_SNAPSHOT' END
  FROM [sys].[dm_os_sys_memory] sm WITH (NOLOCK) CROSS JOIN [sys].[dm_os_process_memory] pm WITH (NOLOCK) CROSS JOIN [sys].[dm_os_sys_info] si WITH (NOLOCK) CROSS JOIN [sys].[configurations] c WITH (NOLOCK)
  WHERE [c].[name] IN('min server memory (MB)','max server memory (MB)') GROUP BY [sm].[total_physical_memory_kb],[sm].[available_physical_memory_kb],[sm].[system_memory_state_desc],[pm].[physical_memory_in_use_kb],[pm].[locked_page_allocations_kb],[pm].[large_page_allocations_kb],[pm].[process_physical_memory_low],[pm].[process_virtual_memory_low],[si].[committed_kb],[si].[committed_target_kb],[si].[visible_target_kb],[si].[sql_memory_model_desc];
  INSERT [#ServerMemory_C] SELECT TOP (@EffectiveMaxZeilen)[type],SUM([pages_kb]),SUM([virtual_memory_committed_kb]),SUM([awe_allocated_kb]),SUM([shared_memory_committed_kb]) FROM [sys].[dm_os_memory_clerks] WITH (NOLOCK) GROUP BY [type] ORDER BY SUM([pages_kb])+SUM([virtual_memory_committed_kb])DESC OPTION(MAXDOP 1);
  INSERT [#ServerMemory_G] SELECT COUNT_BIG(*),SUM(CONVERT(bigint,[requested_memory_kb])),SUM(CONVERT(bigint,[granted_memory_kb])),SUM(CONVERT(bigint,[used_memory_kb])),SUM(CONVERT(bigint,CASE WHEN [grant_time] IS NULL THEN 1 ELSE 0 END)) FROM [sys].[dm_exec_query_memory_grants] WITH (NOLOCK);
 END TRY BEGIN CATCH SELECT @S=CASE WHEN ERROR_NUMBER()IN(229,297,300,371)THEN'DENIED_PERMISSION'WHEN ERROR_NUMBER()=1222 THEN'TIMEOUT'ELSE'ERROR_HANDLED'END,@P=1,@E=ERROR_NUMBER(),@M=ERROR_MESSAGE();END CATCH;END;
 SELECT @StatusCodeOut=@S,@IsPartialOut=@P,@ErrorNumberOut=@E,@ErrorMessageOut=@M;IF @PrintMeldungen=1 AND @S<>'AVAILABLE'RAISERROR(N'USP_ServerMemory: %s',10,1,@M) WITH NOWAIT;
 IF @ResultSetArtNormalisiert<>'NONE' BEGIN SELECT CAST('2.0' AS varchar(16)) [ContractVersion],@T [CollectionTimeUtc],N'monitor.USP_ServerMemory' [ModuleName],@S [StatusCode],@P [IsPartial],@E [ErrorNumber],@M [ErrorMessage];IF @ResultSetArtNormalisiert='RAW' BEGIN SELECT * FROM [#ServerMemory_Summary] ;SELECT * FROM [#ServerMemory_C] ORDER BY [pages_kb] DESC;SELECT * FROM [#ServerMemory_G] ; END ELSE BEGIN SELECT N'summary' [Ergebnis],[x].* FROM [#ServerMemory_Summary] [x] ;SELECT N'memoryClerks' [Ergebnis],[x].* FROM [#ServerMemory_C] [x] ORDER BY [pages_kb] DESC;SELECT N'memoryGrants' [Ergebnis],[x].* FROM [#ServerMemory_G] [x] ; END;END;
 IF @JsonErzeugen=1 BEGIN DECLARE @Meta nvarchar(max)=(SELECT N'ServerMemory' [resultName],1 [schemaVersion],@T [generatedAtUtc],@S [statusCode],@P [isPartial],@E [errorNumber],@M [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),@J0 nvarchar(max)=(SELECT * FROM [#ServerMemory_Summary]  FOR JSON PATH,INCLUDE_NULL_VALUES),@J1 nvarchar(max)=(SELECT * FROM [#ServerMemory_C] ORDER BY [pages_kb] DESC FOR JSON PATH,INCLUDE_NULL_VALUES),@J2 nvarchar(max)=(SELECT * FROM [#ServerMemory_G]  FOR JSON PATH,INCLUDE_NULL_VALUES);SET @Json=CONCAT(N'{"meta":',COALESCE(@Meta,N'{}'),N',"summary":',COALESCE(@J0,N'[]'),N',"memoryClerks":',COALESCE(@J1,N'[]'),N',"memoryGrants":',COALESCE(@J2,N'[]'),N',"warnings":[]}');END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#ServerMemory_Summary'
            , @ResultLabel=N'ServerMemory'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#ServerMemory_Summary'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
