:ON ERROR EXIT

USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 110_SQL_Server_2019_Permission_Matrix.sql
Zweck        : Validiert das kontrollierte Verhalten des Frameworks unter den
               SQL-Server-2019-Berechtigungen VIEW SERVER STATE und
               VIEW DATABASE STATE sowie unter Gruppenregeln.
Voraussetzung: Framework ist installiert. Ausführung als sysadmin im SQLCMD-
               Modus mit der Laufzeitvariable PermissionMatrixPassword.
Datenschutz  : Ausschließlich synthetische Login-, Benutzer- und Rollennamen.
Nebenwirkung : Erzeugt temporär synthetische Logins, Benutzer und eine Rolle;
               stellt die leere Standardpolicy wieder her und räumt auf.
===============================================================================
*/
SET NOCOUNT ON;

IF TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'))<>15
    THROW 54300,N'Die Berechtigungsmatrix ist für SQL Server 2019 vorgesehen.',1;

IF IS_SRVROLEMEMBER(N'sysadmin')<>1
    THROW 54301,N'Die Berechtigungsmatrix muss aus einem sysadmin-Testkontext gestartet werden.',1;
GO

RAISERROR(N'PERMISSION_MATRIX_2019 phase=setup',10,1) WITH NOWAIT;
GO

/* Wiederholbare Bereinigung vor dem Aufbau. */
USE [DeineDatenbank];
GO

IF DATABASE_PRINCIPAL_ID(N'Example2019MonitorDeepRole') IS NOT NULL
BEGIN
    IF DATABASE_PRINCIPAL_ID(N'Example2019GroupMemberUser') IS NOT NULL
       AND IS_ROLEMEMBER(N'Example2019MonitorDeepRole',N'Example2019GroupMemberUser')=1
        ALTER ROLE [Example2019MonitorDeepRole] DROP MEMBER [Example2019GroupMemberUser];
END;
GO

DROP USER IF EXISTS [Example2019RestrictedUser];
DROP USER IF EXISTS [Example2019ViewServerStateUser];
DROP USER IF EXISTS [Example2019ViewDatabaseStateUser];
DROP USER IF EXISTS [Example2019GroupMemberUser];
DROP ROLE IF EXISTS [Example2019MonitorDeepRole];
GO

USE [master];
GO
IF EXISTS(SELECT 1 FROM [sys].[server_principals] WITH (NOLOCK) WHERE [name]=N'Example2019RestrictedLogin') DROP LOGIN [Example2019RestrictedLogin];
IF EXISTS(SELECT 1 FROM [sys].[server_principals] WITH (NOLOCK) WHERE [name]=N'Example2019ViewServerStateLogin') DROP LOGIN [Example2019ViewServerStateLogin];
IF EXISTS(SELECT 1 FROM [sys].[server_principals] WITH (NOLOCK) WHERE [name]=N'Example2019ViewDatabaseStateLogin') DROP LOGIN [Example2019ViewDatabaseStateLogin];
IF EXISTS(SELECT 1 FROM [sys].[server_principals] WITH (NOLOCK) WHERE [name]=N'Example2019GroupMemberLogin') DROP LOGIN [Example2019GroupMemberLogin];
GO

DECLARE @Password nvarchar(128)=N'$(PermissionMatrixPassword)';
IF NULLIF(@Password,N'') IS NULL OR @Password=N'$' + N'(PermissionMatrixPassword)'
    THROW 54302,N'Die SQLCMD-Laufzeitvariable PermissionMatrixPassword fehlt.',1;

DECLARE @CreateLoginSql nvarchar(max)=N'';
SELECT @CreateLoginSql=STRING_AGG(
    N'CREATE LOGIN ' + QUOTENAME([LoginName])
    + N' WITH PASSWORD=N''' + REPLACE(@Password,N'''',N'''''' )
    + N''', CHECK_POLICY=OFF, CHECK_EXPIRATION=OFF;',NCHAR(10))
FROM
(
    VALUES
      (CONVERT(sysname,N'Example2019RestrictedLogin')),
      (CONVERT(sysname,N'Example2019ViewServerStateLogin')),
      (CONVERT(sysname,N'Example2019ViewDatabaseStateLogin')),
      (CONVERT(sysname,N'Example2019GroupMemberLogin'))
) AS [v]([LoginName]);
EXEC [sys].[sp_executesql] @CreateLoginSql;

GRANT VIEW SERVER STATE TO [Example2019ViewServerStateLogin];
GO

USE [DeineDatenbank];
GO
CREATE USER [Example2019RestrictedUser] FOR LOGIN [Example2019RestrictedLogin];
CREATE USER [Example2019ViewServerStateUser] FOR LOGIN [Example2019ViewServerStateLogin];
CREATE USER [Example2019ViewDatabaseStateUser] FOR LOGIN [Example2019ViewDatabaseStateLogin];
CREATE USER [Example2019GroupMemberUser] FOR LOGIN [Example2019GroupMemberLogin];
GO

CREATE ROLE [Example2019MonitorDeepRole];
ALTER ROLE [Example2019MonitorDeepRole] ADD MEMBER [Example2019GroupMemberUser];
GRANT VIEW DATABASE STATE TO [Example2019ViewDatabaseStateUser];
GO

GRANT SELECT ON SCHEMA::[monitor] TO [Example2019RestrictedUser];
GRANT EXECUTE ON SCHEMA::[monitor] TO [Example2019RestrictedUser];
GRANT SELECT ON SCHEMA::[monitor] TO [Example2019ViewServerStateUser];
GRANT EXECUTE ON SCHEMA::[monitor] TO [Example2019ViewServerStateUser];
GRANT SELECT ON SCHEMA::[monitor] TO [Example2019ViewDatabaseStateUser];
GRANT EXECUTE ON SCHEMA::[monitor] TO [Example2019ViewDatabaseStateUser];
GRANT SELECT ON SCHEMA::[monitor] TO [Example2019GroupMemberUser];
GRANT EXECUTE ON SCHEMA::[monitor] TO [Example2019GroupMemberUser];
GO

CREATE TABLE [#SQL_Server_2019_Permission_Matrix_PermissionMatrix2019]
(
      [ScenarioCode] varchar(48) NOT NULL PRIMARY KEY
    , [EffectiveContext] sysname NOT NULL
    , [HasViewServerState] bit NOT NULL
    , [HasViewDatabaseState] bit NOT NULL
    , [CurrentSessionsStatus] varchar(40) NULL
    , [CurrentSessionsIsPartial] bit NULL
    , [CurrentSessionsCapabilityPermission] sysname NULL
    , [CurrentSessionsCapabilityHasPermission] bit NULL
    , [CurrentSessionsCapabilityStatus] varchar(40) NULL
    , [QueryStoreStateRequiredRows] int NOT NULL
    , [QueryStoreStateGrantedRows] int NOT NULL
    , [PlanCacheDeepAllowed] bit NULL
    , [PlanCacheDeepAccessReason] varchar(20) NULL
    , [AllJsonValid] bit NOT NULL
);
GO

/* Leere Standardpolicy muss geschützte Klassen öffnen. */
DECLARE @OpenPolicyAllowed bit=NULL,@OpenPolicyReason varchar(20)=NULL;
BEGIN TRY
    EXECUTE AS LOGIN=N'Example2019RestrictedLogin';
    SELECT @OpenPolicyAllowed=[IsAllowed],@OpenPolicyReason=[AccessReason]
    FROM [monitor].[VW_AnalyseAccessCurrent]
    WHERE [AnalysisClass]='PLAN_CACHE_DEEP';
    REVERT;
END TRY
BEGIN CATCH
    REVERT;
    THROW;
END CATCH;

IF @OpenPolicyAllowed<>1 OR @OpenPolicyReason<>'OPEN_POLICY'
    THROW 54303,N'Die leere Standardpolicy öffnet eine geschützte Analyseklasse nicht wie vorgesehen.',1;
GO

/* Aktive synthetische Policy: Zugriff nur über die Testrolle oder sysadmin. */
CREATE OR ALTER VIEW [monitor].[VW_AnalyseAccessPolicy]
AS
    SELECT
          [p].[AnalysisClass]
        , [p].[ADGroupName]
        , [p].[IsEnabled]
        , [p].[ValidFromUtc]
        , [p].[ValidToUtc]
        , [p].[Priority]
        , [p].[Comment]
    FROM
    (
        VALUES
        (
              CAST('PLAN_CACHE_DEEP' AS varchar(64))
            , CAST(N'Example2019MonitorDeepRole' AS nvarchar(256))
            , CAST(1 AS bit)
            , CAST(NULL AS datetime2(0))
            , CAST(NULL AS datetime2(0))
            , CAST(100 AS smallint)
            , CAST(N'Synthetic SQL Server 2019 permission-matrix role.' AS nvarchar(1000))
        )
    ) AS [p]
    (
          [AnalysisClass]
        , [ADGroupName]
        , [IsEnabled]
        , [ValidFromUtc]
        , [ValidToUtc]
        , [Priority]
        , [Comment]
    );
GO

/* Szenario 1: vollständig eingeschränkt. */
RAISERROR(N'PERMISSION_MATRIX_2019 scenario=RESTRICTED',10,1) WITH NOWAIT;
BEGIN TRY
    EXECUTE AS LOGIN=N'Example2019RestrictedLogin';
    DECLARE @SessionJson1 nvarchar(max)=NULL,@StandardJson1 nvarchar(max)=NULL,@QueryStoreJson1 nvarchar(max)=NULL;
    DECLARE @SessionStatus1 varchar(40)=NULL,@SessionPartial1 bit=NULL;
    DECLARE @CapabilityPermission1 sysname=NULL,@CapabilityHasPermission1 bit=NULL,@CapabilityStatus1 varchar(40)=NULL;
    DECLARE @QueryStoreRequired1 int=0,@QueryStoreGranted1 int=0,@PlanAllowed1 bit=NULL,@PlanReason1 varchar(20)=NULL;
    DECLARE @HasVss1 bit=CONVERT(bit,COALESCE(HAS_PERMS_BY_NAME(NULL,NULL,N'VIEW SERVER STATE'),0));
    DECLARE @HasVds1 bit=CONVERT(bit,COALESCE(HAS_PERMS_BY_NAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),N'DATABASE',N'VIEW DATABASE STATE'),0));

    EXEC [monitor].[USP_CurrentSessions] @AktuelleSessionEinbeziehen=1,@MitSqlText=0,@MaxZeilen=5,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@SessionJson1 OUTPUT,@PrintMeldungen=0;
    EXEC [monitor].[USP_CheckFrameworkCapabilities] @DatabaseNames=N'',@AnalyseKlasse='STANDARD_CURRENT',@MitGruppenpruefung=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@StandardJson1 OUTPUT,@PrintMeldungen=0;
    EXEC [monitor].[USP_CheckFrameworkCapabilities] @DatabaseNames=N'',@AnalyseKlasse='QUERY_STORE_CURRENT',@MitGruppenpruefung=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@QueryStoreJson1 OUTPUT,@PrintMeldungen=0;

    SELECT @SessionStatus1=JSON_VALUE(@SessionJson1,'$.meta.statusCode'),@SessionPartial1=TRY_CONVERT(bit,JSON_VALUE(@SessionJson1,'$.meta.isPartial'));
    SELECT TOP(1) @CapabilityPermission1=[RequiredPermission],@CapabilityHasPermission1=[HasRequiredPermission],@CapabilityStatus1=[StatusCode]
    FROM OPENJSON(@StandardJson1,'$.capabilities') WITH([FeatureCode] varchar(64) '$.FeatureCode',[RequiredPermission] sysname '$.RequiredPermission',[HasRequiredPermission] bit '$.HasRequiredPermission',[StatusCode] varchar(40) '$.StatusCode')
    WHERE [FeatureCode]='CURRENT_SESSIONS';
    SELECT @QueryStoreRequired1=COUNT(*),@QueryStoreGranted1=COALESCE(SUM(CASE WHEN [HasRequiredPermission]=1 THEN 1 ELSE 0 END),0)
    FROM OPENJSON(@QueryStoreJson1,'$.capabilities') WITH([ScopeType] varchar(16) '$.ScopeType',[RequiredPermission] sysname '$.RequiredPermission',[HasRequiredPermission] bit '$.HasRequiredPermission')
    WHERE [ScopeType]='DATABASE' AND [RequiredPermission]='VIEW DATABASE STATE';
    SELECT @PlanAllowed1=[IsAllowed],@PlanReason1=[AccessReason] FROM [monitor].[VW_AnalyseAccessCurrent] WHERE [AnalysisClass]='PLAN_CACHE_DEEP';

    INSERT [#SQL_Server_2019_Permission_Matrix_PermissionMatrix2019]
    VALUES('RESTRICTED',N'Example2019RestrictedLogin',@HasVss1,@HasVds1,@SessionStatus1,@SessionPartial1,@CapabilityPermission1,COALESCE(@CapabilityHasPermission1,0),@CapabilityStatus1,@QueryStoreRequired1,@QueryStoreGranted1,@PlanAllowed1,@PlanReason1,CONVERT(bit,CASE WHEN ISJSON(@SessionJson1)=1 AND ISJSON(@StandardJson1)=1 AND ISJSON(@QueryStoreJson1)=1 THEN 1 ELSE 0 END));
    REVERT;
END TRY
BEGIN CATCH
    REVERT;
    THROW;
END CATCH;
GO

/* Szenario 2: VIEW SERVER STATE. */
RAISERROR(N'PERMISSION_MATRIX_2019 scenario=VIEW_SERVER_STATE',10,1) WITH NOWAIT;
BEGIN TRY
    EXECUTE AS LOGIN=N'Example2019ViewServerStateLogin';
    DECLARE @SessionJson2 nvarchar(max)=NULL,@StandardJson2 nvarchar(max)=NULL,@QueryStoreJson2 nvarchar(max)=NULL;
    DECLARE @SessionStatus2 varchar(40)=NULL,@SessionPartial2 bit=NULL;
    DECLARE @CapabilityPermission2 sysname=NULL,@CapabilityHasPermission2 bit=NULL,@CapabilityStatus2 varchar(40)=NULL;
    DECLARE @QueryStoreRequired2 int=0,@QueryStoreGranted2 int=0,@PlanAllowed2 bit=NULL,@PlanReason2 varchar(20)=NULL;
    DECLARE @HasVss2 bit=CONVERT(bit,COALESCE(HAS_PERMS_BY_NAME(NULL,NULL,N'VIEW SERVER STATE'),0));
    DECLARE @HasVds2 bit=CONVERT(bit,COALESCE(HAS_PERMS_BY_NAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),N'DATABASE',N'VIEW DATABASE STATE'),0));

    EXEC [monitor].[USP_CurrentSessions] @AktuelleSessionEinbeziehen=1,@MitSqlText=0,@MaxZeilen=5,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@SessionJson2 OUTPUT,@PrintMeldungen=0;
    EXEC [monitor].[USP_CheckFrameworkCapabilities] @DatabaseNames=N'',@AnalyseKlasse='STANDARD_CURRENT',@MitGruppenpruefung=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@StandardJson2 OUTPUT,@PrintMeldungen=0;
    EXEC [monitor].[USP_CheckFrameworkCapabilities] @DatabaseNames=N'',@AnalyseKlasse='QUERY_STORE_CURRENT',@MitGruppenpruefung=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@QueryStoreJson2 OUTPUT,@PrintMeldungen=0;

    SELECT @SessionStatus2=JSON_VALUE(@SessionJson2,'$.meta.statusCode'),@SessionPartial2=TRY_CONVERT(bit,JSON_VALUE(@SessionJson2,'$.meta.isPartial'));
    SELECT TOP(1) @CapabilityPermission2=[RequiredPermission],@CapabilityHasPermission2=[HasRequiredPermission],@CapabilityStatus2=[StatusCode]
    FROM OPENJSON(@StandardJson2,'$.capabilities') WITH([FeatureCode] varchar(64) '$.FeatureCode',[RequiredPermission] sysname '$.RequiredPermission',[HasRequiredPermission] bit '$.HasRequiredPermission',[StatusCode] varchar(40) '$.StatusCode')
    WHERE [FeatureCode]='CURRENT_SESSIONS';
    SELECT @QueryStoreRequired2=COUNT(*),@QueryStoreGranted2=COALESCE(SUM(CASE WHEN [HasRequiredPermission]=1 THEN 1 ELSE 0 END),0)
    FROM OPENJSON(@QueryStoreJson2,'$.capabilities') WITH([ScopeType] varchar(16) '$.ScopeType',[RequiredPermission] sysname '$.RequiredPermission',[HasRequiredPermission] bit '$.HasRequiredPermission')
    WHERE [ScopeType]='DATABASE' AND [RequiredPermission]='VIEW DATABASE STATE';
    SELECT @PlanAllowed2=[IsAllowed],@PlanReason2=[AccessReason] FROM [monitor].[VW_AnalyseAccessCurrent] WHERE [AnalysisClass]='PLAN_CACHE_DEEP';

    INSERT [#SQL_Server_2019_Permission_Matrix_PermissionMatrix2019]
    VALUES('VIEW_SERVER_STATE',N'Example2019ViewServerStateLogin',@HasVss2,@HasVds2,@SessionStatus2,@SessionPartial2,@CapabilityPermission2,COALESCE(@CapabilityHasPermission2,0),@CapabilityStatus2,@QueryStoreRequired2,@QueryStoreGranted2,@PlanAllowed2,@PlanReason2,CONVERT(bit,CASE WHEN ISJSON(@SessionJson2)=1 AND ISJSON(@StandardJson2)=1 AND ISJSON(@QueryStoreJson2)=1 THEN 1 ELSE 0 END));
    REVERT;
END TRY
BEGIN CATCH
    REVERT;
    THROW;
END CATCH;
GO

/* Szenario 3: VIEW DATABASE STATE. */
RAISERROR(N'PERMISSION_MATRIX_2019 scenario=VIEW_DATABASE_STATE',10,1) WITH NOWAIT;
BEGIN TRY
    EXECUTE AS LOGIN=N'Example2019ViewDatabaseStateLogin';
    DECLARE @SessionJson3 nvarchar(max)=NULL,@StandardJson3 nvarchar(max)=NULL,@QueryStoreJson3 nvarchar(max)=NULL;
    DECLARE @SessionStatus3 varchar(40)=NULL,@SessionPartial3 bit=NULL;
    DECLARE @CapabilityPermission3 sysname=NULL,@CapabilityHasPermission3 bit=NULL,@CapabilityStatus3 varchar(40)=NULL;
    DECLARE @QueryStoreRequired3 int=0,@QueryStoreGranted3 int=0,@PlanAllowed3 bit=NULL,@PlanReason3 varchar(20)=NULL;
    DECLARE @HasVss3 bit=CONVERT(bit,COALESCE(HAS_PERMS_BY_NAME(NULL,NULL,N'VIEW SERVER STATE'),0));
    DECLARE @HasVds3 bit=CONVERT(bit,COALESCE(HAS_PERMS_BY_NAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),N'DATABASE',N'VIEW DATABASE STATE'),0));

    EXEC [monitor].[USP_CurrentSessions] @AktuelleSessionEinbeziehen=1,@MitSqlText=0,@MaxZeilen=5,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@SessionJson3 OUTPUT,@PrintMeldungen=0;
    EXEC [monitor].[USP_CheckFrameworkCapabilities] @DatabaseNames=N'',@AnalyseKlasse='STANDARD_CURRENT',@MitGruppenpruefung=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@StandardJson3 OUTPUT,@PrintMeldungen=0;
    EXEC [monitor].[USP_CheckFrameworkCapabilities] @DatabaseNames=N'',@AnalyseKlasse='QUERY_STORE_CURRENT',@MitGruppenpruefung=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@QueryStoreJson3 OUTPUT,@PrintMeldungen=0;

    SELECT @SessionStatus3=JSON_VALUE(@SessionJson3,'$.meta.statusCode'),@SessionPartial3=TRY_CONVERT(bit,JSON_VALUE(@SessionJson3,'$.meta.isPartial'));
    SELECT TOP(1) @CapabilityPermission3=[RequiredPermission],@CapabilityHasPermission3=[HasRequiredPermission],@CapabilityStatus3=[StatusCode]
    FROM OPENJSON(@StandardJson3,'$.capabilities') WITH([FeatureCode] varchar(64) '$.FeatureCode',[RequiredPermission] sysname '$.RequiredPermission',[HasRequiredPermission] bit '$.HasRequiredPermission',[StatusCode] varchar(40) '$.StatusCode')
    WHERE [FeatureCode]='CURRENT_SESSIONS';
    SELECT @QueryStoreRequired3=COUNT(*),@QueryStoreGranted3=COALESCE(SUM(CASE WHEN [HasRequiredPermission]=1 THEN 1 ELSE 0 END),0)
    FROM OPENJSON(@QueryStoreJson3,'$.capabilities') WITH([ScopeType] varchar(16) '$.ScopeType',[RequiredPermission] sysname '$.RequiredPermission',[HasRequiredPermission] bit '$.HasRequiredPermission')
    WHERE [ScopeType]='DATABASE' AND [RequiredPermission]='VIEW DATABASE STATE';
    SELECT @PlanAllowed3=[IsAllowed],@PlanReason3=[AccessReason] FROM [monitor].[VW_AnalyseAccessCurrent] WHERE [AnalysisClass]='PLAN_CACHE_DEEP';

    INSERT [#SQL_Server_2019_Permission_Matrix_PermissionMatrix2019]
    VALUES('VIEW_DATABASE_STATE',N'Example2019ViewDatabaseStateLogin',@HasVss3,@HasVds3,@SessionStatus3,@SessionPartial3,@CapabilityPermission3,COALESCE(@CapabilityHasPermission3,0),@CapabilityStatus3,@QueryStoreRequired3,@QueryStoreGranted3,@PlanAllowed3,@PlanReason3,CONVERT(bit,CASE WHEN ISJSON(@SessionJson3)=1 AND ISJSON(@StandardJson3)=1 AND ISJSON(@QueryStoreJson3)=1 THEN 1 ELSE 0 END));
    REVERT;
END TRY
BEGIN CATCH
    REVERT;
    THROW;
END CATCH;
GO

/* Szenario 4: Rollenmitglied. */
RAISERROR(N'PERMISSION_MATRIX_2019 scenario=GROUP_MEMBER',10,1) WITH NOWAIT;
BEGIN TRY
    EXECUTE AS LOGIN=N'Example2019GroupMemberLogin';
    DECLARE @SessionJson4 nvarchar(max)=NULL,@StandardJson4 nvarchar(max)=NULL,@QueryStoreJson4 nvarchar(max)=NULL;
    DECLARE @SessionStatus4 varchar(40)=NULL,@SessionPartial4 bit=NULL;
    DECLARE @CapabilityPermission4 sysname=NULL,@CapabilityHasPermission4 bit=NULL,@CapabilityStatus4 varchar(40)=NULL;
    DECLARE @QueryStoreRequired4 int=0,@QueryStoreGranted4 int=0,@PlanAllowed4 bit=NULL,@PlanReason4 varchar(20)=NULL;
    DECLARE @HasVss4 bit=CONVERT(bit,COALESCE(HAS_PERMS_BY_NAME(NULL,NULL,N'VIEW SERVER STATE'),0));
    DECLARE @HasVds4 bit=CONVERT(bit,COALESCE(HAS_PERMS_BY_NAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),N'DATABASE',N'VIEW DATABASE STATE'),0));

    EXEC [monitor].[USP_CurrentSessions] @AktuelleSessionEinbeziehen=1,@MitSqlText=0,@MaxZeilen=5,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@SessionJson4 OUTPUT,@PrintMeldungen=0;
    EXEC [monitor].[USP_CheckFrameworkCapabilities] @DatabaseNames=N'',@AnalyseKlasse='STANDARD_CURRENT',@MitGruppenpruefung=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@StandardJson4 OUTPUT,@PrintMeldungen=0;
    EXEC [monitor].[USP_CheckFrameworkCapabilities] @DatabaseNames=N'',@AnalyseKlasse='QUERY_STORE_CURRENT',@MitGruppenpruefung=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@QueryStoreJson4 OUTPUT,@PrintMeldungen=0;

    SELECT @SessionStatus4=JSON_VALUE(@SessionJson4,'$.meta.statusCode'),@SessionPartial4=TRY_CONVERT(bit,JSON_VALUE(@SessionJson4,'$.meta.isPartial'));
    SELECT TOP(1) @CapabilityPermission4=[RequiredPermission],@CapabilityHasPermission4=[HasRequiredPermission],@CapabilityStatus4=[StatusCode]
    FROM OPENJSON(@StandardJson4,'$.capabilities') WITH([FeatureCode] varchar(64) '$.FeatureCode',[RequiredPermission] sysname '$.RequiredPermission',[HasRequiredPermission] bit '$.HasRequiredPermission',[StatusCode] varchar(40) '$.StatusCode')
    WHERE [FeatureCode]='CURRENT_SESSIONS';
    SELECT @QueryStoreRequired4=COUNT(*),@QueryStoreGranted4=COALESCE(SUM(CASE WHEN [HasRequiredPermission]=1 THEN 1 ELSE 0 END),0)
    FROM OPENJSON(@QueryStoreJson4,'$.capabilities') WITH([ScopeType] varchar(16) '$.ScopeType',[RequiredPermission] sysname '$.RequiredPermission',[HasRequiredPermission] bit '$.HasRequiredPermission')
    WHERE [ScopeType]='DATABASE' AND [RequiredPermission]='VIEW DATABASE STATE';
    SELECT @PlanAllowed4=[IsAllowed],@PlanReason4=[AccessReason] FROM [monitor].[VW_AnalyseAccessCurrent] WHERE [AnalysisClass]='PLAN_CACHE_DEEP';

    INSERT [#SQL_Server_2019_Permission_Matrix_PermissionMatrix2019]
    VALUES('GROUP_MEMBER',N'Example2019GroupMemberLogin',@HasVss4,@HasVds4,@SessionStatus4,@SessionPartial4,@CapabilityPermission4,COALESCE(@CapabilityHasPermission4,0),@CapabilityStatus4,@QueryStoreRequired4,@QueryStoreGranted4,@PlanAllowed4,@PlanReason4,CONVERT(bit,CASE WHEN ISJSON(@SessionJson4)=1 AND ISJSON(@StandardJson4)=1 AND ISJSON(@QueryStoreJson4)=1 THEN 1 ELSE 0 END));
    REVERT;
END TRY
BEGIN CATCH
    REVERT;
    THROW;
END CATCH;
GO

/* Szenario 5: sysadmin. */
RAISERROR(N'PERMISSION_MATRIX_2019 scenario=SYSADMIN',10,1) WITH NOWAIT;
DECLARE @SessionJson5 nvarchar(max)=NULL,@StandardJson5 nvarchar(max)=NULL,@QueryStoreJson5 nvarchar(max)=NULL;
DECLARE @SessionStatus5 varchar(40)=NULL,@SessionPartial5 bit=NULL;
DECLARE @CapabilityPermission5 sysname=NULL,@CapabilityHasPermission5 bit=NULL,@CapabilityStatus5 varchar(40)=NULL;
DECLARE @QueryStoreRequired5 int=0,@QueryStoreGranted5 int=0,@PlanAllowed5 bit=NULL,@PlanReason5 varchar(20)=NULL;
DECLARE @HasVss5 bit=CONVERT(bit,COALESCE(HAS_PERMS_BY_NAME(NULL,NULL,N'VIEW SERVER STATE'),0));
DECLARE @HasVds5 bit=CONVERT(bit,COALESCE(HAS_PERMS_BY_NAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),N'DATABASE',N'VIEW DATABASE STATE'),0));

EXEC [monitor].[USP_CurrentSessions] @AktuelleSessionEinbeziehen=1,@MitSqlText=0,@MaxZeilen=5,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@SessionJson5 OUTPUT,@PrintMeldungen=0;
EXEC [monitor].[USP_CheckFrameworkCapabilities] @DatabaseNames=N'',@AnalyseKlasse='STANDARD_CURRENT',@MitGruppenpruefung=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@StandardJson5 OUTPUT,@PrintMeldungen=0;
EXEC [monitor].[USP_CheckFrameworkCapabilities] @DatabaseNames=N'',@AnalyseKlasse='QUERY_STORE_CURRENT',@MitGruppenpruefung=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@QueryStoreJson5 OUTPUT,@PrintMeldungen=0;

SELECT @SessionStatus5=JSON_VALUE(@SessionJson5,'$.meta.statusCode'),@SessionPartial5=TRY_CONVERT(bit,JSON_VALUE(@SessionJson5,'$.meta.isPartial'));
SELECT TOP(1) @CapabilityPermission5=[RequiredPermission],@CapabilityHasPermission5=[HasRequiredPermission],@CapabilityStatus5=[StatusCode]
FROM OPENJSON(@StandardJson5,'$.capabilities') WITH([FeatureCode] varchar(64) '$.FeatureCode',[RequiredPermission] sysname '$.RequiredPermission',[HasRequiredPermission] bit '$.HasRequiredPermission',[StatusCode] varchar(40) '$.StatusCode')
WHERE [FeatureCode]='CURRENT_SESSIONS';
SELECT @QueryStoreRequired5=COUNT(*),@QueryStoreGranted5=COALESCE(SUM(CASE WHEN [HasRequiredPermission]=1 THEN 1 ELSE 0 END),0)
FROM OPENJSON(@QueryStoreJson5,'$.capabilities') WITH([ScopeType] varchar(16) '$.ScopeType',[RequiredPermission] sysname '$.RequiredPermission',[HasRequiredPermission] bit '$.HasRequiredPermission')
WHERE [ScopeType]='DATABASE' AND [RequiredPermission]='VIEW DATABASE STATE';
SELECT @PlanAllowed5=[IsAllowed],@PlanReason5=[AccessReason] FROM [monitor].[VW_AnalyseAccessCurrent] WHERE [AnalysisClass]='PLAN_CACHE_DEEP';

INSERT [#SQL_Server_2019_Permission_Matrix_PermissionMatrix2019]
VALUES('SYSADMIN',N'Example2019SysadminContext',@HasVss5,@HasVds5,@SessionStatus5,@SessionPartial5,@CapabilityPermission5,COALESCE(@CapabilityHasPermission5,0),@CapabilityStatus5,@QueryStoreRequired5,@QueryStoreGranted5,@PlanAllowed5,@PlanReason5,CONVERT(bit,CASE WHEN ISJSON(@SessionJson5)=1 AND ISJSON(@StandardJson5)=1 AND ISJSON(@QueryStoreJson5)=1 THEN 1 ELSE 0 END));
GO

RAISERROR(N'PERMISSION_MATRIX_2019 phase=assertions',10,1) WITH NOWAIT;
SELECT [ScenarioCode],[HasViewServerState],[HasViewDatabaseState],[CurrentSessionsStatus],[CurrentSessionsIsPartial],[CurrentSessionsCapabilityPermission],[CurrentSessionsCapabilityHasPermission],[CurrentSessionsCapabilityStatus],[QueryStoreStateRequiredRows],[QueryStoreStateGrantedRows],[PlanCacheDeepAllowed],[PlanCacheDeepAccessReason],[AllJsonValid]
FROM [#SQL_Server_2019_Permission_Matrix_PermissionMatrix2019]
ORDER BY [ScenarioCode];

IF (SELECT COUNT(*) FROM [#SQL_Server_2019_Permission_Matrix_PermissionMatrix2019])<>5
    THROW 54310,N'Die SQL-Server-2019-Berechtigungsmatrix enthält nicht alle erwarteten Szenarien.',1;

IF EXISTS(SELECT 1 FROM [#SQL_Server_2019_Permission_Matrix_PermissionMatrix2019] WHERE [AllJsonValid]=0)
    THROW 54311,N'Mindestens ein SQL-Server-2019-Berechtigungsszenario lieferte kein gültiges JSON.',1;

IF EXISTS
(
    SELECT 1 FROM [#SQL_Server_2019_Permission_Matrix_PermissionMatrix2019]
    WHERE [ScenarioCode]='RESTRICTED'
      AND NOT
      (
          [HasViewServerState]=0 AND [HasViewDatabaseState]=0
          AND [CurrentSessionsStatus] IN('DENIED_PERMISSION','AVAILABLE_LIMITED')
          AND [CurrentSessionsIsPartial]=1
          AND [CurrentSessionsCapabilityPermission]='VIEW SERVER STATE'
          AND [CurrentSessionsCapabilityHasPermission]=0
          AND [CurrentSessionsCapabilityStatus] IN('AVAILABLE_LIMITED','AVAILABLE_UNVERIFIED','DENIED_PERMISSION')
          AND [QueryStoreStateRequiredRows]>0 AND [QueryStoreStateGrantedRows]=0
          AND [PlanCacheDeepAllowed]=0 AND [PlanCacheDeepAccessReason]='NO_MATCH'
      )
)
    THROW 54312,N'Das vollständig eingeschränkte SQL-Server-2019-Szenario verletzt den Limited-/Denied-Vertrag.',1;

IF EXISTS
(
    SELECT 1 FROM [#SQL_Server_2019_Permission_Matrix_PermissionMatrix2019]
    WHERE [ScenarioCode]='VIEW_SERVER_STATE'
      AND NOT
      (
          [HasViewServerState]=1
          AND [CurrentSessionsStatus] IN('AVAILABLE','AVAILABLE_LIMITED')
          AND [CurrentSessionsCapabilityPermission]='VIEW SERVER STATE'
          AND [CurrentSessionsCapabilityHasPermission]=1
          AND [CurrentSessionsCapabilityStatus] IN('AVAILABLE','AVAILABLE_LIMITED')
      )
)
    THROW 54313,N'Das SQL-Server-2019-Szenario VIEW SERVER STATE erfüllt den Server-State-Vertrag nicht.',1;

IF EXISTS
(
    SELECT 1 FROM [#SQL_Server_2019_Permission_Matrix_PermissionMatrix2019]
    WHERE [ScenarioCode]='VIEW_DATABASE_STATE'
      AND NOT
      (
          [HasViewDatabaseState]=1
          AND [QueryStoreStateRequiredRows]>0
          AND [QueryStoreStateGrantedRows]=[QueryStoreStateRequiredRows]
      )
)
    THROW 54314,N'Das SQL-Server-2019-Szenario VIEW DATABASE STATE erfüllt den Query-Store-Vertrag nicht.',1;

IF EXISTS
(
    SELECT 1 FROM [#SQL_Server_2019_Permission_Matrix_PermissionMatrix2019]
    WHERE [ScenarioCode]='GROUP_MEMBER'
      AND NOT([PlanCacheDeepAllowed]=1 AND [PlanCacheDeepAccessReason]='IS_MEMBER')
)
    THROW 54315,N'Die SQL-Server-2019-IS_MEMBER-Fallbackprüfung ist fehlgeschlagen.',1;

IF EXISTS
(
    SELECT 1 FROM [#SQL_Server_2019_Permission_Matrix_PermissionMatrix2019]
    WHERE [ScenarioCode]='SYSADMIN'
      AND NOT([PlanCacheDeepAllowed]=1 AND [PlanCacheDeepAccessReason]='SYSADMIN')
)
    THROW 54316,N'Der SQL-Server-2019-sysadmin-Bypass ist fehlgeschlagen.',1;
GO

/* P0 INT-DENIED und CAP-DENIED: serverweite Quellen unter einem wirklich eingeschränkten Login. */
DECLARE @P0IntegrityJson nvarchar(max)=NULL,@P0CapacityJson nvarchar(max)=NULL;
DECLARE @P0IntegrityStatus varchar(40)=NULL,@P0CapacityStatus varchar(40)=NULL;
DECLARE @P0IntegrityPartial bit=NULL,@P0CapacityPartial bit=NULL;

BEGIN TRY
    EXECUTE AS LOGIN=N'Example2019RestrictedLogin';

    EXEC [monitor].[USP_DatabaseIntegrityAnalysis]
          @DatabaseNames=N''

        , @MitPageDetails=0
        , @MaxZeilen=20
        , @ResultSetArt='NONE'
        , @JsonErzeugen=1
        , @Json=@P0IntegrityJson OUTPUT
        , @PrintMeldungen=0
        , @StatusCodeOut=@P0IntegrityStatus OUTPUT
        , @IsPartialOut=@P0IntegrityPartial OUTPUT;

    EXEC [monitor].[USP_DatabaseCapacityAnalysis]
          @DatabaseNames=N''

        , @MinVolumeFreePercent=0
        , @MaxZeilen=20
        , @ResultSetArt='NONE'
        , @JsonErzeugen=1
        , @Json=@P0CapacityJson OUTPUT
        , @PrintMeldungen=0
        , @StatusCodeOut=@P0CapacityStatus OUTPUT
        , @IsPartialOut=@P0CapacityPartial OUTPUT;

    REVERT;
END TRY
BEGIN CATCH
    IF SUSER_SNAME()<>ORIGINAL_LOGIN() REVERT;
    THROW;
END CATCH;

IF ISJSON(@P0IntegrityJson)<>1
   OR @P0IntegrityStatus NOT IN('DENIED_PERMISSION','AVAILABLE_LIMITED','DENIED_GROUP')
   OR COALESCE(@P0IntegrityPartial,0)<>1
    THROW 54317,N'Der P0-Fall INT-DENIED verletzt den kontrollierten Limited-/Denied-Vertrag.',1;

IF ISJSON(@P0CapacityJson)<>1
   OR @P0CapacityStatus NOT IN('DENIED_PERMISSION','AVAILABLE_LIMITED','DENIED_GROUP')
   OR COALESCE(@P0CapacityPartial,0)<>1
    THROW 54318,N'Der P0-Fall CAP-DENIED verletzt den kontrollierten Limited-/Denied-Vertrag.',1;
GO

SELECT
      CAST('AVAILABLE' AS varchar(40)) AS [StatusCode]
    , CAST(0 AS bit) AS [IsPartial]
    , COUNT(*) AS [ExecutedScenarios]
    , N'SQL Server 2019 permission matrix completed with synthetic principals only.' AS [Detail]
FROM [#SQL_Server_2019_Permission_Matrix_PermissionMatrix2019];
GO

/* Standardpolicy wiederherstellen. */
CREATE OR ALTER VIEW [monitor].[VW_AnalyseAccessPolicy]
AS
    SELECT
          [p].[AnalysisClass]
        , [p].[ADGroupName]
        , [p].[IsEnabled]
        , [p].[ValidFromUtc]
        , [p].[ValidToUtc]
        , [p].[Priority]
        , [p].[Comment]
    FROM
    (
        VALUES
        (
              CAST(NULL AS varchar(64))
            , CAST(NULL AS nvarchar(256))
            , CAST(NULL AS bit)
            , CAST(NULL AS datetime2(0))
            , CAST(NULL AS datetime2(0))
            , CAST(NULL AS smallint)
            , CAST(NULL AS nvarchar(1000))
        )
    ) AS [p]
    (
          [AnalysisClass]
        , [ADGroupName]
        , [IsEnabled]
        , [ValidFromUtc]
        , [ValidToUtc]
        , [Priority]
        , [Comment]
    )
    WHERE 1=0;
GO

IF IS_ROLEMEMBER(N'Example2019MonitorDeepRole',N'Example2019GroupMemberUser')=1
    ALTER ROLE [Example2019MonitorDeepRole] DROP MEMBER [Example2019GroupMemberUser];
DROP USER [Example2019RestrictedUser];
DROP USER [Example2019ViewServerStateUser];
DROP USER [Example2019ViewDatabaseStateUser];
DROP USER [Example2019GroupMemberUser];
DROP ROLE [Example2019MonitorDeepRole];
GO

USE [master];
GO
DROP LOGIN [Example2019RestrictedLogin];
DROP LOGIN [Example2019ViewServerStateLogin];
DROP LOGIN [Example2019ViewDatabaseStateLogin];
DROP LOGIN [Example2019GroupMemberLogin];
GO
