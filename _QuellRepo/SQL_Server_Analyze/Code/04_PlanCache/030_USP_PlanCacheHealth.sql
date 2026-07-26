USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_PlanCacheHealth
Version      : 2.0.0
Stand        : 2026-07-15
Typ          : Stored Procedure
Zweck        : Bewertet Größe, Wiederverwendung und Zusammensetzung des aktuellen
               Plan Cache ohne Showplan-XML.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : sys.dm_exec_cached_plans, sys.dm_exec_sql_text,
               sys.dm_exec_plan_attributes, sys.configurations.
Parameter    : @AnalyseModus, @MitDatenbankVerteilung, @MitSingleUseDetails,
               @MaxZeilen, @MaxSqlTextZeichen, @PrintMeldungen, @Hilfe.
Resultsets   : 1. Modulstatus. 2. Gesamtkennzahlen. 3. Verteilung nach Cache-/Objekttyp.
               4. optionale Datenbankverteilung. 5. optionale Single-use-Details.
Berechtigung : VIEW SERVER STATE bzw. SQL Server 2022+ VIEW SERVER PERFORMANCE STATE.
Eigenlast    : Basis gruppiert die Plan-Cache-DMV. Datenbankverteilung und Details
               sind opt-in und PLAN_CACHE_DEEP-geschützt.
Locking      : Keine Benutzerobjekte.
Partial      : Optionale Resultsets werden unabhängig behandelt.
Beispiele    : EXEC monitor.USP_PlanCacheHealth;
               EXEC monitor.USP_PlanCacheHealth @AnalyseModus='VOLL',@MitDatenbankVerteilung=1,@MitSingleUseDetails=1;
               EXEC monitor.USP_PlanCacheHealth @Hilfe=1;
Änderungen   : 1.0.1 - Stabile Summenzeile auch bei leerem Zwischenergebnis.
               1.0.0 - Erstfassung Phase 3.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_PlanCacheHealth]
      @AnalyseModus               varchar(16) = 'SUMMARY'
    , @MitDatenbankVerteilung     bit         = 0
    , @MitSingleUseDetails        bit         = 0
    , @MaxZeilen                  int         = 100
    , @HighImpactConfirmed        bit         = 0
    , @MaxSqlTextZeichen          int         = 4000
    , @ResultSetArt               varchar(16) = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen               bit         = 0
    , @Json                        nvarchar(max) = NULL OUTPUT
    , @PrintMeldungen             bit         = 1
    , @Hilfe                      bit         = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;
    SET @Json=NULL;
    DECLARE @ResultSetArtNormalisiert varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'overview',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @EffectiveMaxZeilen bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxZeilen) END;
    DECLARE @MonitorPrintMessage nvarchar(2048);
    SET @AnalyseModus=UPPER(LTRIM(RTRIM(COALESCE(@AnalyseModus,'SUMMARY'))));
    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_PlanCacheHealth';
        PRINT N'@AnalyseModus SUMMARY oder VOLL. VOLL prüft PLAN_CACHE_DEEP.';
        PRINT N'@MitDatenbankVerteilung bit=0: wertet dbid-Planattribute aus; benötigt VOLL.';
        PRINT N'@MitSingleUseDetails bit=0: liefert begrenzte Texte großer Single-use-Pläne; benötigt VOLL.';
        PRINT N'@MaxZeilen int=100; @MaxSqlTextZeichen positiv = gekürzt, NULL/0 = vollständig; @ResultSetArt CONSOLE (Default)|RAW|TABLE|NONE; optional @Json OUTPUT.';
        PRINT N'@PrintMeldungen bit=1; @Hilfe bit=0.';
        PRINT N'usecounts kann durch Showplan-Nutzung beeinflusst werden; Resultate sind eine Momentaufnahme.';
        RETURN;
    END;

    DECLARE @CollectionTimeUtc datetime2(3)=SYSUTCDATETIME(),@StatusCode varchar(40)='AVAILABLE',@IsPartial bit=0,@RowCount bigint=0,
            @ErrorNumber int=NULL,@ErrorMessage nvarchar(2048)=NULL,@Detail nvarchar(2000)=NULL,@Allowed bit=1,
            @RequiredPermission nvarchar(256)=CASE WHEN TRY_CONVERT([int],SERVERPROPERTY(N'ProductMajorVersion'))>=16 THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END;
    CREATE TABLE [#PlanCacheHealth_Summary]([CacheObjectType] nvarchar(34),[ObjectType] nvarchar(16),[PlanCount] bigint,[TotalSizeBytes] bigint,[SingleUsePlanCount] bigint,[SingleUseSizeBytes] bigint,[TotalUseCounts] bigint,[AverageUseCount] decimal(19,4));
    CREATE TABLE [#PlanCacheHealth_Db]([DatabaseId] int NULL,[DatabaseName] sysname NULL,[PlanCount] bigint,[TotalSizeBytes] bigint,[SingleUsePlanCount] bigint);
    CREATE TABLE [#PlanCacheHealth_Single]([PlanHandle] varbinary(64),[CacheObjectType] nvarchar(34),[ObjectType] nvarchar(16),[UseCounts] int,[SizeBytes] int,[DatabaseId] int NULL,[DatabaseName] sysname NULL,[SqlTextCharacters] bigint NULL,[SqlTextBytes] bigint NULL,[SqlTextIsTruncated] bit NOT NULL DEFAULT(0),[SqlText] nvarchar(max));

    IF @AnalyseModus NOT IN('SUMMARY','VOLL') OR @MaxZeilen<0 OR @ResultSetArtNormalisiert NOT IN('RAW','CONSOLE','NONE') OR @MaxSqlTextZeichen < 0
    BEGIN SET @StatusCode='INVALID_PARAMETER';SET @ErrorMessage=N'Ungültiger Parameterwert.';END;
    IF @StatusCode='AVAILABLE' AND (@AnalyseModus='VOLL' OR @MitDatenbankVerteilung=1 OR @MitSingleUseDetails=1)
        EXEC [monitor].[InternalCheckAnalysisPath] @AnalysisClass='PLAN_CACHE_DEEP',@HighImpactConfirmed=@HighImpactConfirmed,@StatusCode=@StatusCode OUTPUT,@ErrorMessage=@ErrorMessage OUTPUT;
    IF @StatusCode='AVAILABLE' AND @AnalyseModus='SUMMARY' AND (@MitDatenbankVerteilung=1 OR @MitSingleUseDetails=1)
    BEGIN SET @StatusCode='INVALID_PARAMETER';SET @ErrorMessage=N'Detailresultsets erfordern @AnalyseModus=VOLL.';END;

    IF @StatusCode='AVAILABLE'
    BEGIN TRY
        INSERT [#PlanCacheHealth_Summary]
        SELECT [cp].[cacheobjtype],[cp].[objtype],COUNT_BIG(*),SUM(CONVERT(bigint,[cp].[size_in_bytes])),
               SUM(CASE WHEN [cp].[usecounts]<=1 THEN CONVERT(bigint,1) ELSE 0 END),SUM(CASE WHEN [cp].[usecounts]<=1 THEN CONVERT(bigint,[cp].[size_in_bytes]) ELSE 0 END),
               SUM(CONVERT(bigint,[cp].[usecounts])),CONVERT(decimal(19,4),AVG(CONVERT(decimal(19,4),[cp].[usecounts])))
        FROM [sys].[dm_exec_cached_plans] AS cp WITH (NOLOCK)
        GROUP BY [cp].[cacheobjtype],[cp].[objtype] OPTION(MAXDOP 1);
        SET @RowCount=@@ROWCOUNT;SET @Detail=N'Plan-Cache-Zusammenfassung erfolgreich.';
    END TRY
    BEGIN CATCH
        SET @ErrorNumber=ERROR_NUMBER();SET @ErrorMessage=ERROR_MESSAGE();SET @IsPartial=1;
        SET @StatusCode=CASE WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END;
    END CATCH;

    IF @StatusCode='AVAILABLE' AND @MitDatenbankVerteilung=1
    BEGIN TRY
        INSERT [#PlanCacheHealth_Db]
        SELECT TRY_CONVERT([int],[pa].[value]),[d].[name],COUNT_BIG(*),SUM(CONVERT(bigint,[cp].[size_in_bytes])),SUM(CASE WHEN [cp].[usecounts]<=1 THEN CONVERT(bigint,1) ELSE 0 END)
        FROM [sys].[dm_exec_cached_plans] AS cp WITH (NOLOCK)
        OUTER APPLY (SELECT TOP(1) [value] FROM sys.dm_exec_plan_attributes([cp].[plan_handle]) WHERE [attribute]='dbid') AS pa
        LEFT JOIN [master].[sys].[databases] AS [d] WITH (NOLOCK)
          ON [d].[database_id]=TRY_CONVERT([int],[pa].[value])
        GROUP BY TRY_CONVERT([int],[pa].[value]),[d].[name] OPTION(MAXDOP 1);
    END TRY BEGIN CATCH SET @IsPartial=1;SET @StatusCode='PARTIAL';IF @ErrorMessage IS NULL BEGIN SET @ErrorNumber=ERROR_NUMBER();SET @ErrorMessage=ERROR_MESSAGE();END;END CATCH;

    IF @StatusCode IN('AVAILABLE','PARTIAL') AND @MitSingleUseDetails=1
    BEGIN TRY
        ;WITH C AS
        (
            SELECT TOP (@EffectiveMaxZeilen) [cp].[plan_handle],[cp].[cacheobjtype],[cp].[objtype],[cp].[usecounts],[cp].[size_in_bytes]
            FROM [sys].[dm_exec_cached_plans] AS cp WITH (NOLOCK) WHERE [cp].[usecounts]<=1 ORDER BY [cp].[size_in_bytes] DESC
        )
        INSERT [#PlanCacheHealth_Single]
        SELECT [c].[plan_handle],[c].[cacheobjtype],[c].[objtype],[c].[usecounts],[c].[size_in_bytes],TRY_CONVERT([int],[pa].[value]),[d].[name],NULL,NULL,CONVERT(bit,0),[st].[text]
        FROM [C] AS c OUTER APPLY sys.dm_exec_sql_text([c].[plan_handle]) AS st
        OUTER APPLY (SELECT TOP(1) [value] FROM sys.dm_exec_plan_attributes([c].[plan_handle]) WHERE [attribute]='dbid') AS pa
        LEFT JOIN [master].[sys].[databases] AS [d] WITH (NOLOCK)
          ON [d].[database_id]=TRY_CONVERT([int],[pa].[value]);

        DECLARE @TruncatedValueCount bigint=0,@LargestRequiredCharacters bigint=NULL;
        EXEC [monitor].[InternalProjectUnicodeTextColumn]
              @SourceTable=N'#PlanCacheHealth_Single',@TextColumn=N'SqlText'
            , @CharactersColumn=N'SqlTextCharacters',@BytesColumn=N'SqlTextBytes'
            , @IsTruncatedColumn=N'SqlTextIsTruncated',@MaxCharacters=@MaxSqlTextZeichen
            , @TruncatedValueCount=@TruncatedValueCount OUTPUT,@LargestRequiredCharacters=@LargestRequiredCharacters OUTPUT;
        EXEC [monitor].[InternalEmitTruncationWarning]
              @TruncatedValueCount=@TruncatedValueCount,@ParameterName=N'@MaxSqlTextZeichen'
            , @ParameterValue=@MaxSqlTextZeichen,@LargestRequiredCharacters=@LargestRequiredCharacters
            , @PrintMeldungen=@PrintMeldungen;
    END TRY BEGIN CATCH SET @IsPartial=1;SET @StatusCode='PARTIAL';IF @ErrorMessage IS NULL BEGIN SET @ErrorNumber=ERROR_NUMBER();SET @ErrorMessage=ERROR_MESSAGE();END;END CATCH;

    IF @PrintMeldungen=1 AND @StatusCode NOT IN('AVAILABLE') BEGIN
    SET @MonitorPrintMessage = FORMATMESSAGE(N'WARNUNG USP_PlanCacheHealth: %s - %s', @StatusCode, COALESCE(@ErrorMessage,N''));
    RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
END;
    IF @ResultSetArtNormalisiert<>'NONE'
    BEGIN
        SELECT N'USP_PlanCacheHealth' [ModuleName],@CollectionTimeUtc [CollectionTimeUtc],@StatusCode [StatusCode],@IsPartial [IsPartial],@RowCount [RowCount],
               @RequiredPermission [RequiredPermission],@ErrorNumber [ErrorNumber],@ErrorMessage [ErrorMessage],@Detail [Detail];
        IF @ResultSetArtNormalisiert='RAW'
        BEGIN
            SELECT COALESCE(SUM([PlanCount]),0) AS [PlanCount],COALESCE(SUM([TotalSizeBytes]),0) AS [TotalSizeBytes],CONVERT(decimal(19,2),COALESCE(SUM([TotalSizeBytes]),0)/1048576.0) AS [TotalSizeMb],COALESCE(SUM([SingleUsePlanCount]),0) AS [SingleUsePlanCount],COALESCE(SUM([SingleUseSizeBytes]),0) AS [SingleUseSizeBytes],CONVERT(decimal(9,2),100.0*SUM([SingleUseSizeBytes])/NULLIF(SUM([TotalSizeBytes]),0)) AS [SingleUseMemoryPercent],(SELECT TOP(1) [value_in_use] FROM [sys].[configurations] WITH (NOLOCK) WHERE [name]='optimize for ad hoc workloads') AS [OptimizeForAdHocWorkloads] FROM [#PlanCacheHealth_Summary];
            SELECT * FROM [#PlanCacheHealth_Summary] ORDER BY [TotalSizeBytes] DESC,[PlanCount] DESC;
            IF @MitDatenbankVerteilung=1 SELECT * FROM [#PlanCacheHealth_Db] ORDER BY [TotalSizeBytes] DESC,[PlanCount] DESC;
            IF @MitSingleUseDetails=1 SELECT * FROM [#PlanCacheHealth_Single] ORDER BY [SizeBytes] DESC,[PlanHandle];
        END
        ELSE
        BEGIN
            SELECT N'Plan-Cache Übersicht' AS [Ergebnis],COALESCE(SUM([PlanCount]),0) AS [Pläne],CONCAT(CONVERT(varchar(40),CONVERT(decimal(19,2),COALESCE(SUM([TotalSizeBytes]),0)/1048576.0)),N' MB') AS [Größe],COALESCE(SUM([SingleUsePlanCount]),0) AS [Single-use-Pläne],CONCAT(CONVERT(varchar(40),CONVERT(decimal(9,2),100.0*SUM([SingleUseSizeBytes])/NULLIF(SUM([TotalSizeBytes]),0))),N' %') AS [Single-use-Speicher],(SELECT TOP(1) [value_in_use] FROM [sys].[configurations] WITH (NOLOCK) WHERE [name]='optimize for ad hoc workloads') AS [Optimize for ad hoc] FROM [#PlanCacheHealth_Summary];
            SELECT N'Plan-Cache Kategorie' AS [Ergebnis],[CacheObjectType] AS [Cacheobjekt],[ObjectType] AS [Objekttyp],[PlanCount] AS [Pläne],CONCAT(CONVERT(varchar(40),CONVERT(decimal(19,2),[TotalSizeBytes]/1048576.0)),N' MB') AS [Größe],[SingleUsePlanCount] AS [Single-use],[AverageUseCount] AS [Ø Verwendung] FROM [#PlanCacheHealth_Summary] ORDER BY [TotalSizeBytes] DESC,[PlanCount] DESC;
            IF @MitDatenbankVerteilung=1 SELECT N'Plan-Cache Datenbank' AS [Ergebnis],[DatabaseId] AS [Datenbank-ID],[DatabaseName] AS [Datenbank],[PlanCount] AS [Pläne],CONCAT(CONVERT(varchar(40),CONVERT(decimal(19,2),[TotalSizeBytes]/1048576.0)),N' MB') AS [Größe],[SingleUsePlanCount] AS [Single-use] FROM [#PlanCacheHealth_Db] ORDER BY [TotalSizeBytes] DESC,[PlanCount] DESC;
            IF @MitSingleUseDetails=1 SELECT N'Single-use Plan' AS [Ergebnis],[DatabaseName] AS [Datenbank],[UseCounts] AS [Verwendungen],CONCAT(CONVERT(varchar(40),CONVERT(decimal(19,2),[SizeBytes]/1048576.0)),N' MB') AS [Größe],[PlanHandle] AS [Planhandle],[DatabaseName] AS [Datenbank SQL],[SqlText] AS [SQL-Text] FROM [#PlanCacheHealth_Single] ORDER BY [SizeBytes] DESC,[PlanHandle];
        END;
    END;
    IF @JsonErzeugen=1
    BEGIN
        DECLARE @MetaJson nvarchar(max)=(SELECT N'PlanCacheHealth' [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@StatusCode [statusCode],@IsPartial [isPartial],@ErrorNumber [errorNumber],@ErrorMessage [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @OverviewJson nvarchar(max)=(SELECT COALESCE(SUM([PlanCount]),0) [planCount],COALESCE(SUM([TotalSizeBytes]),0) [totalSizeBytes],CONVERT(decimal(19,2),COALESCE(SUM([TotalSizeBytes]),0)/1048576.0) [totalSizeMb],COALESCE(SUM([SingleUsePlanCount]),0) [singleUsePlanCount],COALESCE(SUM([SingleUseSizeBytes]),0) [singleUseSizeBytes],CONVERT(decimal(9,2),100.0*SUM([SingleUseSizeBytes])/NULLIF(SUM([TotalSizeBytes]),0)) [singleUseMemoryPercent] FROM [#PlanCacheHealth_Summary] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @CategoriesJson nvarchar(max)=(SELECT * FROM [#PlanCacheHealth_Summary] ORDER BY [TotalSizeBytes] DESC,[PlanCount] DESC FOR JSON PATH,INCLUDE_NULL_VALUES),@DatabasesJson nvarchar(max)=(SELECT * FROM [#PlanCacheHealth_Db] ORDER BY [TotalSizeBytes] DESC,[PlanCount] DESC FOR JSON PATH,INCLUDE_NULL_VALUES),@SingleJson nvarchar(max)=(SELECT * FROM [#PlanCacheHealth_Single] ORDER BY [SizeBytes] DESC,[PlanHandle] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@MetaJson,N'{}'),N',"overview":',COALESCE(@OverviewJson,N'{}'),N',"categories":',COALESCE(@CategoriesJson,N'[]'),N',"databases":',COALESCE(@DatabasesJson,N'[]'),N',"singleUsePlans":',COALESCE(@SingleJson,N'[]'),N',"warnings":[]}');
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#PlanCacheHealth_Summary'
            , @ResultLabel=N'PlanCacheHealth'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#PlanCacheHealth_Summary'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
