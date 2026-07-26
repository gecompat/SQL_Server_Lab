:ON ERROR EXIT

USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 120_SQL_Server_2025_Regex_Matrix.sql
Zweck        : Validiert die SQL-Server-2025-Regex-Funktionen, das Parsing der
               frameworkweiten regex:/regexi:-Pattern und das Feature-Gate bei
               Compatibility Levels unter 170.
Voraussetzung: Framework ist installiert. Ausführung als sysadmin.
Datenschutz  : Ausschließlich synthetische Werte und generische Statusausgaben.
Nebenwirkung : Setzt den Compatibility Level der synthetischen Testdatenbank
               kurzzeitig auf 160 und anschließend zwingend wieder auf 170.
===============================================================================
*/
SET NOCOUNT ON;

IF TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'))<>17
    THROW 54400,N'Die Regex-Matrix ist für SQL Server 2025 vorgesehen.',1;

IF COALESCE((SELECT [compatibility_level] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id]=DB_ID()),0)<>170
    THROW 54401,N'Die Regex-Matrix benötigt Compatibility Level 170.',1;
GO

RAISERROR(N'REGEX_MATRIX_2025 phase=engine',10,1) WITH NOWAIT;
GO

IF NOT REGEXP_LIKE(N'Example42',N'^Example[0-9]+$')
    THROW 54402,N'REGEXP_LIKE erkannte den synthetischen Basistreffer nicht.',1;

IF REGEXP_LIKE(N'example42',N'^Example[0-9]+$')
    THROW 54403,N'REGEXP_LIKE verletzte die erwartete Groß-/Kleinschreibung.',1;

IF NOT REGEXP_LIKE(N'example42',N'^Example[0-9]+$','i')
    THROW 54404,N'REGEXP_LIKE mit i-Flag erkannte den synthetischen Treffer nicht.',1;
GO

RAISERROR(N'REGEX_MATRIX_2025 phase=parser',10,1) WITH NOWAIT;
GO

DECLARE @Mode varchar(8),@Pattern nvarchar(4000),@Flags varchar(8),@IsValid bit;

SELECT @Mode=[PatternMode],@Pattern=[PatternValue],@Flags=[RegexFlags],@IsValid=[IsValid]
FROM [monitor].[TVF_ParsePattern](N'regex:^Example[0-9]+$');

IF @Mode<>'REGEX' OR @Pattern<>N'^Example[0-9]+$' OR @IsValid<>1
    THROW 54405,N'Das regex:-Pattern wurde nicht gemäß Frameworkvertrag geparst.',1;

SELECT @Mode=[PatternMode],@Pattern=[PatternValue],@Flags=[RegexFlags],@IsValid=[IsValid]
FROM [monitor].[TVF_ParsePattern](N'regexi:^example[0-9]+$');

IF @Mode<>'REGEXI' OR @Pattern<>N'^example[0-9]+$' OR @IsValid<>1 OR CHARINDEX('i',COALESCE(@Flags,''))=0
    THROW 54406,N'Das regexi:-Pattern wurde nicht gemäß Frameworkvertrag geparst.',1;
GO

RAISERROR(N'REGEX_MATRIX_2025 phase=framework_170',10,1) WITH NOWAIT;
GO

DECLARE @SessionsJson nvarchar(max)=NULL,@XeJson nvarchar(max)=NULL;
DECLARE @SessionsStatus varchar(40),@XeStatus varchar(40);

EXEC [monitor].[USP_CurrentSessions]
      @LoginNamePattern=N'regexi:^sa$'
    , @AktuelleSessionEinbeziehen=1
    , @MitSqlText=0
    , @MaxZeilen=10
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@SessionsJson OUTPUT
    , @PrintMeldungen=0;

SET @SessionsStatus=JSON_VALUE(@SessionsJson,'$.meta.statusCode');
IF ISJSON(@SessionsJson)<>1 OR @SessionsStatus NOT IN('AVAILABLE','AVAILABLE_LIMITED')
    THROW 54407,N'USP_CurrentSessions erfüllte den Regex-Vertrag bei Compatibility Level 170 nicht.',1;

EXEC [monitor].[USP_ExtendedEventsSessions]
      @ExtendedEventSessionNamePattern=N'regexi:^system_.*$'
    , @MitLaufzeitstatus=1
    , @MitEvents=0
    , @MitActions=0
    , @MitTargets=0
    , @MitFeldern=0
    , @MaxZeilen=20
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@XeJson OUTPUT
    , @PrintMeldungen=0;

SET @XeStatus=JSON_VALUE(@XeJson,'$.meta.statusCode');
IF ISJSON(@XeJson)<>1 OR @XeStatus NOT IN('AVAILABLE','AVAILABLE_LIMITED')
    THROW 54408,N'USP_ExtendedEventsSessions erfüllte den Regex-Vertrag bei Compatibility Level 170 nicht.',1;
GO

RAISERROR(N'REGEX_MATRIX_2025 phase=feature_gate_160',10,1) WITH NOWAIT;
GO

DECLARE @DatabaseName sysname=(SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID());
DECLARE @AlterSql nvarchar(max)=N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET COMPATIBILITY_LEVEL = 160;';
EXEC [sys].[sp_executesql] @AlterSql;
GO

BEGIN TRY
    DECLARE @SessionsJson nvarchar(max)=NULL,@XeJson nvarchar(max)=NULL;
    DECLARE @SessionsStatus varchar(40),@XeStatus varchar(40);

    EXEC [monitor].[USP_CurrentSessions]
          @LoginNamePattern=N'regexi:^sa$'
        , @AktuelleSessionEinbeziehen=1
        , @MitSqlText=0
        , @MaxZeilen=10
        , @ResultSetArt='NONE'
        , @JsonErzeugen=1
        , @Json=@SessionsJson OUTPUT
        , @PrintMeldungen=0;

    SET @SessionsStatus=JSON_VALUE(@SessionsJson,'$.meta.statusCode');
    IF ISJSON(@SessionsJson)<>1 OR @SessionsStatus<>'UNAVAILABLE_FEATURE'
        THROW 54409,N'USP_CurrentSessions sperrte Regex unter Compatibility Level 160 nicht kontrolliert.',1;

    EXEC [monitor].[USP_ExtendedEventsSessions]
          @ExtendedEventSessionNamePattern=N'regexi:^system_.*$'
        , @MitLaufzeitstatus=0
        , @MitEvents=0
        , @MitActions=0
        , @MitTargets=0
        , @MitFeldern=0
        , @MaxZeilen=20
        , @ResultSetArt='NONE'
        , @JsonErzeugen=1
        , @Json=@XeJson OUTPUT
        , @PrintMeldungen=0;

    SET @XeStatus=JSON_VALUE(@XeJson,'$.meta.statusCode');
    IF ISJSON(@XeJson)<>1 OR @XeStatus<>'UNAVAILABLE_FEATURE'
        THROW 54410,N'USP_ExtendedEventsSessions sperrte Regex unter Compatibility Level 160 nicht kontrolliert.',1;
END TRY
BEGIN CATCH
    DECLARE @ErrorMessage nvarchar(2048)=ERROR_MESSAGE();
    DECLARE @DatabaseName sysname=(SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID());
    DECLARE @RestoreSql nvarchar(max)=N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET COMPATIBILITY_LEVEL = 170;';
    EXEC [sys].[sp_executesql] @RestoreSql;
    THROW 54411,@ErrorMessage,1;
END CATCH;
GO

DECLARE @DatabaseName sysname=(SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID());
DECLARE @RestoreSql nvarchar(max)=N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET COMPATIBILITY_LEVEL = 170;';
EXEC [sys].[sp_executesql] @RestoreSql;
GO

RAISERROR(N'REGEX_MATRIX_2025 phase=restored_170',10,1) WITH NOWAIT;
GO

IF COALESCE((SELECT [compatibility_level] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id]=DB_ID()),0)<>170
    THROW 54412,N'Der Compatibility Level wurde nach der negativen Gate-Prüfung nicht auf 170 zurückgestellt.',1;

IF NOT REGEXP_LIKE(N'Example2025',N'^Example[0-9]+$')
    THROW 54413,N'REGEXP_LIKE war nach Wiederherstellung von Compatibility Level 170 nicht verfügbar.',1;
GO

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],
       CAST(0 AS bit) AS [IsPartial],
       CAST(10 AS int) AS [ExecutedContracts],
       CAST(170 AS int) AS [CompatibilityLevel],
       N'SQL Server 2025 regex matrix completed with synthetic values only.' AS [Detail];
GO
