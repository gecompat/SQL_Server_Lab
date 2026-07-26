USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_TempDBConfiguration
Version      : 2.0.0
Stand        : 2026-07-15
Zweck        : Analysiert TempDB-Dateien, Größenverteilung, Growth und
               Konfiguration. Ein früherer CTE-Laufzeitfehler ist behoben.
Datenquellen : tempdb.sys.database_files, sys.configurations
Vertrag      : Resultset 1 ist immer Modulstatus; @ResultSetArt=NONE unterdrückt Resultsets; RAW und CONSOLE liefern unterschiedliche Projektionen. Optional JSON.
===============================================================================
*/

CREATE OR ALTER PROCEDURE [monitor].[USP_TempDBConfiguration]
 @PrintMeldungen bit=1,@Hilfe bit=0,@ResultSetArt varchar(16)='CONSOLE'
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
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'files',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';IF @Hilfe=1 BEGIN PRINT N'monitor.USP_TempDBConfiguration';RETURN;END;
 DECLARE @T datetime2(3)=SYSUTCDATETIME(),@S varchar(40)='AVAILABLE',@P bit=0,@E int=NULL,@M nvarchar(2048)=NULL;
 IF @ResultSetArtNormalisiert NOT IN('RAW','CONSOLE','NONE') SELECT @S='INVALID_PARAMETER',@P=1,@M=N'@ResultSetArt muss CONSOLE, RAW, TABLE oder NONE enthalten.';
 CREATE TABLE [#TempDBConfiguration_F]([file_id] int,[name] sysname,[type_desc] nvarchar(60),[physical_name] nvarchar(260),[SizeMb] decimal(19,2),[GrowthValue] decimal(19,2),[GrowthType] varchar(10),[max_size] int,[is_percent_growth] bit);
 CREATE TABLE [#TempDBConfiguration_Cfg]([name] nvarchar(128),[value_in_use] sql_variant);
 SET LOCK_TIMEOUT 0;BEGIN TRY
  INSERT [#TempDBConfiguration_F] SELECT [file_id],[name],[type_desc],[physical_name],CONVERT(decimal(19,2),[size]*8.0/1024),CONVERT(decimal(19,2),CASE WHEN [is_percent_growth]=1 THEN [growth] ELSE [growth]*8.0/1024 END),CASE WHEN [is_percent_growth]=1 THEN'PERCENT'ELSE'MB'END,[max_size],[is_percent_growth] FROM [tempdb].[sys].[database_files] WITH (NOLOCK);
  INSERT [#TempDBConfiguration_Cfg] SELECT [name],[value_in_use] FROM [sys].[configurations] WITH (NOLOCK) WHERE [name] IN('tempdb metadata memory-optimized','tempdb deferred drop','mixed page allocation');
 END TRY BEGIN CATCH SELECT @S=CASE WHEN ERROR_NUMBER()IN(229,297,300,371,916)THEN'DENIED_PERMISSION'WHEN ERROR_NUMBER()=1222 THEN'TIMEOUT'ELSE'ERROR_HANDLED'END,@P=1,@E=ERROR_NUMBER(),@M=ERROR_MESSAGE();END CATCH;
 SELECT @StatusCodeOut=@S,@IsPartialOut=@P,@ErrorNumberOut=@E,@ErrorMessageOut=@M;IF @PrintMeldungen=1 AND @S<>'AVAILABLE'RAISERROR(N'USP_TempDBConfiguration: %s',10,1,@M) WITH NOWAIT;
 IF @ResultSetArtNormalisiert<>'NONE' BEGIN SELECT CAST('2.0' AS varchar(16)) [ContractVersion],@T [CollectionTimeUtc],N'monitor.USP_TempDBConfiguration' [ModuleName],@S [StatusCode],@P [IsPartial],@E [ErrorNumber],@M [ErrorMessage];IF @ResultSetArtNormalisiert='RAW' BEGIN SELECT * FROM [#TempDBConfiguration_F] ORDER BY [file_id];SELECT * FROM [#TempDBConfiguration_Cfg] ORDER BY [name]; END ELSE BEGIN SELECT N'files' [Ergebnis],[x].* FROM [#TempDBConfiguration_F] [x] ORDER BY [file_id];SELECT N'configuration' [Ergebnis],[x].* FROM [#TempDBConfiguration_Cfg] [x] ORDER BY [name]; END;END;
 IF @JsonErzeugen=1 BEGIN DECLARE @Meta nvarchar(max)=(SELECT N'TempDBConfiguration' [resultName],1 [schemaVersion],@T [generatedAtUtc],@S [statusCode],@P [isPartial],@E [errorNumber],@M [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),@J0 nvarchar(max)=(SELECT * FROM [#TempDBConfiguration_F] ORDER BY [file_id] FOR JSON PATH,INCLUDE_NULL_VALUES),@J1 nvarchar(max)=(SELECT [name],CONVERT(nvarchar(4000),[value_in_use]) [value_in_use] FROM [#TempDBConfiguration_Cfg] ORDER BY [name] FOR JSON PATH,INCLUDE_NULL_VALUES);SET @Json=CONCAT(N'{"meta":',COALESCE(@Meta,N'{}'),N',"files":',COALESCE(@J0,N'[]'),N',"configuration":',COALESCE(@J1,N'[]'),N',"warnings":[]}');END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#TempDBConfiguration_F'
            , @ResultLabel=N'TempDBConfiguration'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#TempDBConfiguration_F'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
