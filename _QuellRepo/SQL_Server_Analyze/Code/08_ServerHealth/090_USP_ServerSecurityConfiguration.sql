USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ServerSecurityConfiguration
Version      : 2.0.1
Stand        : 2026-07-15
Zweck        : Liest die Sicherheits- und Dienstkonfiguration, ohne sie zu
               verändern.
Datenquellen : sys.configurations, sys.dm_server_services, SERVERPROPERTY
Vertrag      : Resultset 1 ist immer Modulstatus; @ResultSetArt=NONE unterdrückt
               Resultsets und liefert Status ausschließlich über OUTPUT-Parameter.
===============================================================================
*/

CREATE OR ALTER PROCEDURE [monitor].[USP_ServerSecurityConfiguration]
    @PrintMeldungen  bit = 1,
    @Hilfe           bit = 0,
    @ResultSetArt    varchar(16) = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen    bit = 0,
    @Json             nvarchar(max) = NULL OUTPUT,
    @StatusCodeOut   varchar(40) = NULL OUTPUT,
    @IsPartialOut    bit = NULL OUTPUT,
    @ErrorNumberOut  int = NULL OUTPUT,
    @ErrorMessageOut nvarchar(2048) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;SET @Json=NULL;DECLARE @ResultSetArtNormalisiert varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'configuration',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @MonitorPrintMessage nvarchar(2048);

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_ServerSecurityConfiguration';
        RETURN;
    END;

    DECLARE
        @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME(),
        @StatusCode        varchar(40) = 'AVAILABLE',
        @IsPartial         bit = 0,
        @ErrorNumber       int = NULL,
        @ErrorMessage      nvarchar(2048) = NULL;

    IF @ResultSetArtNormalisiert NOT IN('RAW','CONSOLE','NONE') BEGIN SET @StatusCode='INVALID_PARAMETER';SET @IsPartial=1;SET @ErrorMessage=N'@ResultSetArt muss CONSOLE, RAW, TABLE oder NONE enthalten.';END;

    CREATE TABLE [#ServerSecurityConfiguration_SourceStatus]
    (
        [SourceName]   sysname        NOT NULL,
        [StatusCode]   varchar(40)    NOT NULL,
        [ErrorNumber]  int            NULL,
        [ErrorMessage] nvarchar(2048) NULL
    );

    CREATE TABLE [#ServerSecurityConfiguration_Configuration]
    (
        [ConfigurationName] nvarchar(128) NOT NULL,
        [ConfiguredValue]   sql_variant   NULL,
        [RunningValue]      sql_variant   NULL,
        [Finding]           varchar(60)   NOT NULL
    );

    CREATE TABLE [#ServerSecurityConfiguration_Services]
    (
        [ServiceName]                      nvarchar(256) NULL,
        [ServiceAccount]                   nvarchar(256) NULL,
        [StartupTypeDescription]           nvarchar(60)  NULL,
        [StatusDescription]                nvarchar(60)  NULL,
        [InstantFileInitializationEnabled] nvarchar(10)  NULL,
        [InstantFileInitializationFinding] varchar(40)   NOT NULL
    );

    CREATE TABLE [#ServerSecurityConfiguration_Properties]
    (
        [MachineName]                 sysname       NULL,
        [ServerName]                  sysname       NULL,
        [Edition]                     nvarchar(128) NULL,
        [IsWindowsAuthenticationOnly] int           NULL,
        [CallerIsSysadmin]            int           NULL
    );

    SET LOCK_TIMEOUT 0;

    BEGIN TRY
        INSERT [#ServerSecurityConfiguration_Configuration]
        (
            [ConfigurationName],
            [ConfiguredValue],
            [RunningValue],
            [Finding]
        )
        SELECT
            [c].[name],
            [c].[value],
            [c].[value_in_use],
            CASE
                WHEN [c].[name] = N'xp_cmdshell'
                     AND CONVERT(int, [c].[value_in_use]) = 1
                    THEN 'XPCMDSHELL_ENABLED'
                WHEN [c].[name] = N'Ole Automation Procedures'
                     AND CONVERT(int, [c].[value_in_use]) = 1
                    THEN 'OLE_AUTOMATION_ENABLED'
                WHEN [c].[name] = N'clr strict security'
                     AND CONVERT(int, [c].[value_in_use]) = 0
                    THEN 'CLR_STRICT_SECURITY_OFF'
                WHEN [c].[name] = N'external scripts enabled'
                     AND CONVERT(int, [c].[value_in_use]) = 1
                    THEN 'EXTERNAL_SCRIPTS_ENABLED'
                ELSE 'OK_OR_CONTEXT_DEPENDENT'
            END
        FROM [sys].[configurations] AS c WITH (NOLOCK)
        WHERE [c].[name] IN
        (
            N'xp_cmdshell',
            N'Ole Automation Procedures',
            N'clr enabled',
            N'clr strict security',
            N'external scripts enabled',
            N'remote admin connections',
            N'contained database authentication'
        );

        INSERT [#ServerSecurityConfiguration_SourceStatus] VALUES
            (N'sys.configurations', 'AVAILABLE', NULL, NULL);
    END TRY
    BEGIN CATCH
        INSERT [#ServerSecurityConfiguration_SourceStatus] VALUES
        (
            N'sys.configurations',
            CASE
                WHEN ERROR_NUMBER() IN (229, 297, 300, 371) THEN 'DENIED_PERMISSION'
                WHEN ERROR_NUMBER() = 1222 THEN 'TIMEOUT'
                ELSE 'ERROR_HANDLED'
            END,
            ERROR_NUMBER(),
            ERROR_MESSAGE()
        );
    END CATCH;

    BEGIN TRY
        INSERT [#ServerSecurityConfiguration_Services]
        (
            [ServiceName],
            [ServiceAccount],
            [StartupTypeDescription],
            [StatusDescription],
            [InstantFileInitializationEnabled],
            [InstantFileInitializationFinding]
        )
        SELECT
            [s].[servicename],
            [s].[service_account],
            [s].[startup_type_desc],
            [s].[status_desc],
            CONVERT(nvarchar(10), [s].[instant_file_initialization_enabled]),
            CASE
                WHEN CONVERT(nvarchar(10), [s].[instant_file_initialization_enabled]) = N'Y'
                    THEN 'IFI_ENABLED'
                ELSE 'IFI_NOT_CONFIRMED'
            END
        FROM [sys].[dm_server_services] AS s WITH (NOLOCK);

        INSERT [#ServerSecurityConfiguration_SourceStatus] VALUES
            (N'sys.dm_server_services', 'AVAILABLE', NULL, NULL);
    END TRY
    BEGIN CATCH
        INSERT [#ServerSecurityConfiguration_SourceStatus] VALUES
        (
            N'sys.dm_server_services',
            CASE
                WHEN ERROR_NUMBER() IN (229, 297, 300, 371) THEN 'DENIED_PERMISSION'
                WHEN ERROR_NUMBER() = 1222 THEN 'TIMEOUT'
                ELSE 'ERROR_HANDLED'
            END,
            ERROR_NUMBER(),
            ERROR_MESSAGE()
        );
    END CATCH;

    BEGIN TRY
        INSERT [#ServerSecurityConfiguration_Properties]
        (
            [MachineName],
            [ServerName],
            [Edition],
            [IsWindowsAuthenticationOnly],
            [CallerIsSysadmin]
        )
        SELECT
            CONVERT(sysname, SERVERPROPERTY(N'MachineName')),
            CONVERT(sysname, SERVERPROPERTY(N'ServerName')),
            CONVERT(nvarchar(128), SERVERPROPERTY(N'Edition')),
            CONVERT(int, SERVERPROPERTY(N'IsIntegratedSecurityOnly')),
            CONVERT(int, IS_SRVROLEMEMBER(N'sysadmin'));

        INSERT [#ServerSecurityConfiguration_SourceStatus] VALUES
            (N'SERVERPROPERTY', 'AVAILABLE', NULL, NULL);
    END TRY
    BEGIN CATCH
        INSERT [#ServerSecurityConfiguration_SourceStatus] VALUES
        (
            N'SERVERPROPERTY',
            'ERROR_HANDLED',
            ERROR_NUMBER(),
            ERROR_MESSAGE()
        );
    END CATCH;



    IF EXISTS
    (
        SELECT 1
        FROM [#ServerSecurityConfiguration_SourceStatus] AS s
        WHERE [s].[StatusCode] <> 'AVAILABLE'
    )
    BEGIN
        SELECT
            @IsPartial = 1,
            @StatusCode = CASE
                WHEN EXISTS
                (
                    SELECT 1
                    FROM [#ServerSecurityConfiguration_SourceStatus] AS s
                    WHERE [s].[StatusCode] = 'AVAILABLE'
                )
                    THEN 'PARTIAL'
                ELSE
                (
                    SELECT TOP (1) [s].[StatusCode]
                    FROM [#ServerSecurityConfiguration_SourceStatus] AS s
                    WHERE [s].[StatusCode] <> 'AVAILABLE'
                    ORDER BY [s].[SourceName]
                )
            END,
            @ErrorNumber =
            (
                SELECT TOP (1) [s].[ErrorNumber]
                FROM [#ServerSecurityConfiguration_SourceStatus] AS s
                WHERE [s].[StatusCode] <> 'AVAILABLE'
                ORDER BY [s].[SourceName]
            ),
            @ErrorMessage =
            (
                SELECT TOP (1) [s].[ErrorMessage]
                FROM [#ServerSecurityConfiguration_SourceStatus] AS s
                WHERE [s].[StatusCode] <> 'AVAILABLE'
                ORDER BY [s].[SourceName]
            );
    END;

    SELECT
        @StatusCodeOut = @StatusCode,
        @IsPartialOut = @IsPartial,
        @ErrorNumberOut = @ErrorNumber,
        @ErrorMessageOut = @ErrorMessage;

    IF @PrintMeldungen = 1
       AND @StatusCode <> 'AVAILABLE'
    BEGIN
        BEGIN
    SET @MonitorPrintMessage = FORMATMESSAGE(N'USP_ServerSecurityConfiguration: %s', COALESCE(@ErrorMessage, N'eine Quelle ist nicht verfügbar'));
    RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
END;
    END;

    IF @ResultSetArtNormalisiert<>'NONE'
    BEGIN
      SELECT CAST('2.0' AS varchar(16)) [ContractVersion],@CollectionTimeUtc [CollectionTimeUtc],N'monitor.USP_ServerSecurityConfiguration' [ModuleName],@StatusCode [StatusCode],@IsPartial [IsPartial],@ErrorNumber [ErrorNumber],@ErrorMessage [ErrorMessage];
      IF @ResultSetArtNormalisiert='RAW' BEGIN SELECT * FROM [#ServerSecurityConfiguration_SourceStatus] ORDER BY [SourceName];SELECT * FROM [#ServerSecurityConfiguration_Configuration] ORDER BY [ConfigurationName];SELECT * FROM [#ServerSecurityConfiguration_Services] ORDER BY [ServiceName];SELECT * FROM [#ServerSecurityConfiguration_Properties];END
      ELSE BEGIN SELECT N'Sicherheitsquelle' [Ergebnis],[x].* FROM [#ServerSecurityConfiguration_SourceStatus] [x] ORDER BY [SourceName];SELECT N'Sicherheitskonfiguration' [Ergebnis],[ConfigurationName] [Einstellung],CONVERT(nvarchar(4000),[ConfiguredValue]) [konfiguriert],CONVERT(nvarchar(4000),[RunningValue]) [aktiv],[Finding] [Bewertung] FROM [#ServerSecurityConfiguration_Configuration] ORDER BY [ConfigurationName];SELECT N'SQL-Dienst' [Ergebnis],[x].* FROM [#ServerSecurityConfiguration_Services] [x] ORDER BY [ServiceName];SELECT N'Server-Eigenschaft' [Ergebnis],[x].* FROM [#ServerSecurityConfiguration_Properties] [x];END;
    END;
    IF @JsonErzeugen=1 BEGIN DECLARE @Meta nvarchar(max)=(SELECT N'ServerSecurityConfiguration' [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@StatusCode [statusCode],@IsPartial [isPartial],@ErrorNumber [errorNumber],@ErrorMessage [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),@Sources nvarchar(max)=(SELECT * FROM [#ServerSecurityConfiguration_SourceStatus] ORDER BY [SourceName] FOR JSON PATH,INCLUDE_NULL_VALUES),@Cfg nvarchar(max)=(SELECT [ConfigurationName],CONVERT(nvarchar(4000),[ConfiguredValue]) [ConfiguredValue],CONVERT(nvarchar(4000),[RunningValue]) [RunningValue],[Finding] FROM [#ServerSecurityConfiguration_Configuration] ORDER BY [ConfigurationName] FOR JSON PATH,INCLUDE_NULL_VALUES),@Services nvarchar(max)=(SELECT * FROM [#ServerSecurityConfiguration_Services] ORDER BY [ServiceName] FOR JSON PATH,INCLUDE_NULL_VALUES),@Props nvarchar(max)=(SELECT * FROM [#ServerSecurityConfiguration_Properties] FOR JSON PATH,INCLUDE_NULL_VALUES);SET @Json=CONCAT(N'{"meta":',COALESCE(@Meta,N'{}'),N',"sources":',COALESCE(@Sources,N'[]'),N',"configuration":',COALESCE(@Cfg,N'[]'),N',"services":',COALESCE(@Services,N'[]'),N',"properties":',COALESCE(@Props,N'[]'),N',"warnings":[]}');END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#ServerSecurityConfiguration_Configuration'
            , @ResultLabel=N'ServerSecurityConfiguration'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#ServerSecurityConfiguration_Configuration'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
