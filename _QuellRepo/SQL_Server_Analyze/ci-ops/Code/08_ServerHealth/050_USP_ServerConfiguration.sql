USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ServerConfiguration
Version      : 2.0.0
Stand        : 2026-07-15
Zweck        : Liefert die zentrale Serverkonfiguration mit kontextabhängigen
               Review-Hinweisen.
Datenquellen : sys.configurations, sys.dm_os_sys_info
Vertrag      : Resultset 1 ist immer Modulstatus; @ResultSetArt=NONE unterdrückt Resultsets; RAW und CONSOLE liefern unterschiedliche Projektionen. Optional JSON.
===============================================================================
*/

CREATE OR ALTER PROCEDURE [monitor].[USP_ServerConfiguration]
 @NurKernparameter bit=1,@PrintMeldungen bit=1,@Hilfe bit=0,@ResultSetArt varchar(16)='CONSOLE'
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
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'configuration',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';IF @Hilfe=1 BEGIN PRINT N'monitor.USP_ServerConfiguration';RETURN;END;
 DECLARE @T datetime2(3)=SYSUTCDATETIME(),@S varchar(40)='AVAILABLE',@P bit=0,@E int=NULL,@M nvarchar(2048)=NULL,@Schedulers int=NULL;
 IF @ResultSetArtNormalisiert NOT IN('RAW','CONSOLE','NONE') SELECT @S='INVALID_PARAMETER',@P=1,@M=N'@ResultSetArt muss CONSOLE, RAW, TABLE oder NONE enthalten.';
 CREATE TABLE [#ServerConfiguration_C]([configuration_id] int,[name] nvarchar(128),[minimum] sql_variant,[maximum] sql_variant,[ConfiguredValue] sql_variant,[RunningValue] sql_variant,[is_dynamic] bit,[is_advanced] bit,[Finding] varchar(60),[Interpretation] nvarchar(1000));
 SET LOCK_TIMEOUT 0;BEGIN TRY
  SELECT @Schedulers=[scheduler_count] FROM [sys].[dm_os_sys_info] WITH (NOLOCK);
  INSERT [#ServerConfiguration_C] SELECT [configuration_id],[name],[minimum],[maximum],[value],[value_in_use],[is_dynamic],[is_advanced],
   CASE WHEN [value]<>[value_in_use] THEN'RECONFIGURE_OR_RESTART_PENDING' WHEN [name]='cost threshold for parallelism'AND CONVERT(int,[value_in_use])<=5 THEN'LOW_DEFAULT_REVIEW' WHEN [name]='max server memory (MB)'AND CONVERT(bigint,[value_in_use])>=2147483647 THEN'UNBOUNDED_MEMORY_REVIEW' WHEN [name] IN('xp_cmdshell','Ole Automation Procedures')AND CONVERT(int,[value_in_use])=1 THEN'SECURITY_REVIEW' ELSE'OK_OR_CONTEXT_DEPENDENT'END,
   CASE WHEN [name]='max degree of parallelism'THEN CONCAT(N'0 bedeutet automatische Nutzung bis zur Enginegrenze; gegen NUMA, Scheduleranzahl ',@Schedulers,N', Workload und Parallelism-Waits bewerten.') WHEN [name]='cost threshold for parallelism'THEN N'Der Standardwert 5 ist häufig nur ein Ausgangspunkt; Änderungen ausschließlich workloadbasiert.' WHEN [name]='max server memory (MB)'THEN N'OS-, Agent-, SSIS-/ETL- und sonstige Prozessreserve berücksichtigen.' ELSE N'Kontext-, Sicherheits- und Herstelleranforderungen prüfen; keine automatische Änderung.'END
  FROM [sys].[configurations] WITH (NOLOCK) WHERE @NurKernparameter=0 OR [name] IN('max degree of parallelism','cost threshold for parallelism','max server memory (MB)','min server memory (MB)','optimize for ad hoc workloads','backup compression default','remote admin connections','contained database authentication','clr enabled','clr strict security','xp_cmdshell','Ole Automation Procedures','external scripts enabled','blocked process threshold (s)','query wait (s)','affinity mask','affinity64 mask');
 END TRY BEGIN CATCH SELECT @S=CASE WHEN ERROR_NUMBER()IN(229,297,300,371)THEN'DENIED_PERMISSION'WHEN ERROR_NUMBER()=1222 THEN'TIMEOUT'ELSE'ERROR_HANDLED'END,@P=1,@E=ERROR_NUMBER(),@M=ERROR_MESSAGE();END CATCH;
 SELECT @StatusCodeOut=@S,@IsPartialOut=@P,@ErrorNumberOut=@E,@ErrorMessageOut=@M;IF @PrintMeldungen=1 AND @S<>'AVAILABLE'RAISERROR(N'USP_ServerConfiguration: %s',10,1,@M) WITH NOWAIT;
 IF @ResultSetArtNormalisiert<>'NONE' BEGIN SELECT CAST('2.0' AS varchar(16)) [ContractVersion],@T [CollectionTimeUtc],N'monitor.USP_ServerConfiguration' [ModuleName],@S [StatusCode],@P [IsPartial],@E [ErrorNumber],@M [ErrorMessage];IF @ResultSetArtNormalisiert='RAW' BEGIN SELECT * FROM [#ServerConfiguration_C] ORDER BY [name]; END ELSE BEGIN SELECT N'configuration' [Ergebnis],[x].* FROM [#ServerConfiguration_C] [x] ORDER BY [name]; END;END;
 IF @JsonErzeugen=1 BEGIN DECLARE @Meta nvarchar(max)=(SELECT N'ServerConfiguration' [resultName],1 [schemaVersion],@T [generatedAtUtc],@S [statusCode],@P [isPartial],@E [errorNumber],@M [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),@J0 nvarchar(max)=(SELECT [configuration_id],[name],CONVERT(nvarchar(4000),[minimum]) [minimum],CONVERT(nvarchar(4000),[maximum]) [maximum],CONVERT(nvarchar(4000),[ConfiguredValue]) [ConfiguredValue],CONVERT(nvarchar(4000),[RunningValue]) [RunningValue],[is_dynamic],[is_advanced],[Finding],[Interpretation] FROM [#ServerConfiguration_C] ORDER BY [name] FOR JSON PATH,INCLUDE_NULL_VALUES);SET @Json=CONCAT(N'{"meta":',COALESCE(@Meta,N'{}'),N',"configuration":',COALESCE(@J0,N'[]'),N',"warnings":[]}');END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#ServerConfiguration_C'
            , @ResultLabel=N'ServerConfiguration'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#ServerConfiguration_C'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
