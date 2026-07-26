USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_StartupParameters
Version      : 2.0.0
Stand        : 2026-07-15
Zweck        : Liefert Startparameter und Registry-basierte Dienstparameter
               einschließlich eines Plattformhinweises.
Datenquellen : sys.dm_server_registry
Vertrag      : Resultset 1 ist immer Modulstatus; @ResultSetArt=NONE unterdrückt Resultsets; RAW und CONSOLE liefern unterschiedliche Projektionen. Optional JSON.
===============================================================================
*/

CREATE OR ALTER PROCEDURE [monitor].[USP_StartupParameters]
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
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'startupParameters',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';IF @Hilfe=1 BEGIN PRINT N'monitor.USP_StartupParameters';RETURN;END;
 DECLARE @T datetime2(3)=SYSUTCDATETIME(),@S varchar(40)='AVAILABLE',@P bit=0,@E int=NULL,@M nvarchar(2048)=NULL,@Platform nvarchar(60)=NULL;
 IF @ResultSetArtNormalisiert NOT IN('RAW','CONSOLE','NONE') SELECT @S='INVALID_PARAMETER',@P=1,@M=N'@ResultSetArt muss CONSOLE, RAW, TABLE oder NONE enthalten.';
 CREATE TABLE [#StartupParameters_X]([registry_key] nvarchar(512),[value_name] nvarchar(256),[value_data] nvarchar(2048),[ParameterType] varchar(40));
 BEGIN TRY SELECT TOP(1)@Platform=[host_platform] FROM [sys].[dm_os_host_info] WITH (NOLOCK);END TRY BEGIN CATCH END CATCH;
 IF NOT EXISTS(SELECT 1 FROM [master].[sys].[all_objects] AS [o] WITH (NOLOCK) JOIN [master].[sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id] WHERE [s].[name]=N'sys' AND [o].[name]=N'dm_server_registry') SELECT @S=CASE WHEN @Platform=N'Linux'THEN'UNAVAILABLE_PLATFORM'ELSE'UNAVAILABLE_OBJECT'END,@P=1,@M=N'sys.dm_server_registry ist nicht verfügbar; Startparameter können auf dieser Plattform/Version nicht über diese Quelle gelesen werden.';
 ELSE BEGIN SET LOCK_TIMEOUT 0;BEGIN TRY INSERT [#StartupParameters_X] SELECT [registry_key],[value_name],CONVERT(nvarchar(2048),[value_data]),CASE WHEN CONVERT(nvarchar(2048),[value_data])LIKE'-T%'OR CONVERT(nvarchar(2048),[value_data])LIKE'-t%'THEN'TRACE_FLAG'WHEN CONVERT(nvarchar(2048),[value_data])LIKE'-d%'THEN'MASTER_DATA_PATH'WHEN CONVERT(nvarchar(2048),[value_data])LIKE'-l%'THEN'MASTER_LOG_PATH'WHEN CONVERT(nvarchar(2048),[value_data])LIKE'-e%'THEN'ERRORLOG_PATH'ELSE'OTHER'END FROM [sys].[dm_server_registry] WITH (NOLOCK) WHERE [value_name] LIKE'SQLArg%'OR [value_name] IN('ImagePath','ObjectName');END TRY BEGIN CATCH SELECT @S=CASE WHEN ERROR_NUMBER()IN(229,297,300,371)THEN'DENIED_PERMISSION'ELSE'ERROR_HANDLED'END,@P=1,@E=ERROR_NUMBER(),@M=ERROR_MESSAGE();END CATCH;END;
 SELECT @StatusCodeOut=@S,@IsPartialOut=@P,@ErrorNumberOut=@E,@ErrorMessageOut=@M;IF @PrintMeldungen=1 AND @S<>'AVAILABLE'RAISERROR(N'USP_StartupParameters: %s',10,1,@M) WITH NOWAIT;
 IF @ResultSetArtNormalisiert<>'NONE' BEGIN SELECT CAST('2.0' AS varchar(16)) [ContractVersion],@T [CollectionTimeUtc],N'monitor.USP_StartupParameters' [ModuleName],@S [StatusCode],@P [IsPartial],@E [ErrorNumber],@M [ErrorMessage];IF @ResultSetArtNormalisiert='RAW' BEGIN SELECT * FROM [#StartupParameters_X] ORDER BY [registry_key],[value_name]; END ELSE BEGIN SELECT N'startupParameters' [Ergebnis],[x].* FROM [#StartupParameters_X] [x] ORDER BY [registry_key],[value_name]; END;END;
 IF @JsonErzeugen=1 BEGIN DECLARE @Meta nvarchar(max)=(SELECT N'StartupParameters' [resultName],1 [schemaVersion],@T [generatedAtUtc],@S [statusCode],@P [isPartial],@E [errorNumber],@M [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),@J0 nvarchar(max)=(SELECT * FROM [#StartupParameters_X] ORDER BY [registry_key],[value_name] FOR JSON PATH,INCLUDE_NULL_VALUES);SET @Json=CONCAT(N'{"meta":',COALESCE(@Meta,N'{}'),N',"startupParameters":',COALESCE(@J0,N'[]'),N',"warnings":[]}');END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#StartupParameters_X'
            , @ResultLabel=N'StartupParameters'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#StartupParameters_X'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
