:ON ERROR EXIT

USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 110_SQL_Server_2022_Permission_Matrix.sql
Zweck        : Validiert das kontrollierte Verhalten des Frameworks unter
               abgestuften SQL-Server-2022+-Berechtigungen und Gruppenregeln.
Voraussetzung: Framework ist installiert. Ausführung als sysadmin im SQLCMD-
               Modus mit der Laufzeitvariable PermissionMatrixPassword.
Datenschutz  : Ausschließlich synthetische Login-, Benutzer- und Rollennamen.
Nebenwirkung : Erzeugt temporär synthetische Logins, Benutzer und eine Rolle;
               stellt die leere Standardpolicy wieder her und räumt auf.
===============================================================================
*/
SET NOCOUNT ON;

IF TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'))<>$(ExpectedMajorVersion)
    THROW 54200,N'Die Berechtigungsmatrix laeuft nicht auf der erwarteten SQL-Server-Hauptversion.',1;

IF IS_SRVROLEMEMBER(N'sysadmin')<>1
    THROW 54201,N'Die Berechtigungsmatrix muss aus einem sysadmin-Testkontext gestartet werden.',1;
GO

RAISERROR(N'PERMISSION_MATRIX phase=setup',10,1) WITH NOWAIT;
GO

/* Wiederholbare Bereinigung vor dem Aufbau. */
USE [DeineDatenbank];
GO

IF DATABASE_PRINCIPAL_ID(N'ExampleMonitorDeepRole') IS NOT NULL
BEGIN
    IF DATABASE_PRINCIPAL_ID(N'ExampleGroupMemberUser') IS NOT NULL
       AND IS_ROLEMEMBER(N'ExampleMonitorDeepRole',N'ExampleGroupMemberUser')=1
        ALTER ROLE [ExampleMonitorDeepRole] DROP MEMBER [ExampleGroupMemberUser];
END;
GO

DROP USER IF EXISTS [ExampleRestrictedUser];
DROP USER IF EXISTS [ExampleViewServerStateUser];
DROP USER IF EXISTS [ExampleViewServerPerformanceUser];
DROP USER IF EXISTS [ExampleViewDatabaseStateUser];
DROP USER IF EXISTS [ExampleViewDatabasePerformanceUser];
DROP USER IF EXISTS [ExampleGroupMemberUser];
DROP ROLE IF EXISTS [ExampleMonitorDeepRole];
GO

USE [master];
GO
IF EXISTS(SELECT 1 FROM [sys].[server_principals] WITH (NOLOCK) WHERE [name]=N'ExampleRestrictedLogin') DROP LOGIN [ExampleRestrictedLogin];
IF EXISTS(SELECT 1 FROM [sys].[server_principals] WITH (NOLOCK) WHERE [name]=N'ExampleViewServerStateLogin') DROP LOGIN [ExampleViewServerStateLogin];
IF EXISTS(SELECT 1 FROM [sys].[server_principals] WITH (NOLOCK) WHERE [name]=N'ExampleViewServerPerformanceLogin') DROP LOGIN [ExampleViewServerPerformanceLogin];
IF EXISTS(SELECT 1 FROM [sys].[server_principals] WITH (NOLOCK) WHERE [name]=N'ExampleViewDatabaseStateLogin') DROP LOGIN [ExampleViewDatabaseStateLogin];
IF EXISTS(SELECT 1 FROM [sys].[server_principals] WITH (NOLOCK) WHERE [name]=N'ExampleViewDatabasePerformanceLogin') DROP LOGIN [ExampleViewDatabasePerformanceLogin];
IF EXISTS(SELECT 1 FROM [sys].[server_principals] WITH (NOLOCK) WHERE [name]=N'ExampleGroupMemberLogin') DROP LOGIN [ExampleGroupMemberLogin];
GO

DECLARE @Password nvarchar(128)=N'$(PermissionMatrixPassword)';
IF NULLIF(@Password,N'') IS NULL OR @Password=N'$' + N'(PermissionMatrixPassword)'
    THROW 54202,N'Die SQLCMD-Laufzeitvariable PermissionMatrixPassword fehlt.',1;

DECLARE @Sql nvarchar(max)=N'';
SELECT @Sql=STRING_AGG(
    N'CREATE LOGIN ' + QUOTENAME([LoginName])
    + N' WITH PASSWORD=N''' + REPLACE(@Password,N'''',N'''''')
    + N''', CHECK_POLICY=OFF, CHECK_EXPIRATION=OFF;',NCHAR(10))
FROM
(
    VALUES
      (CONVERT(sysname,N'ExampleRestrictedLogin')),
      (CONVERT(sysname,N'ExampleViewServerStateLogin')),
      (CONVERT(sysname,N'ExampleViewServerPerformanceLogin')),
      (CONVERT(sysname,N'ExampleViewDatabaseStateLogin')),
      (CONVERT(sysname,N'ExampleViewDatabasePerformanceLogin')),
      (CONVERT(sysname,N'ExampleGroupMemberLogin'))
) AS [v]([LoginName]);
EXEC [sys].[sp_executesql] @Sql;

GRANT VIEW SERVER STATE TO [ExampleViewServerStateLogin];
GRANT VIEW SERVER PERFORMANCE STATE TO [ExampleViewServerPerformanceLogin];
GO

USE [DeineDatenbank];
GO

CREATE USER [ExampleRestrictedUser] FOR LOGIN [ExampleRestrictedLogin];
CREATE USER [ExampleViewServerStateUser] FOR LOGIN [ExampleViewServerStateLogin];
CREATE USER [ExampleViewServerPerformanceUser] FOR LOGIN [ExampleViewServerPerformanceLogin];
CREATE USER [ExampleViewDatabaseStateUser] FOR LOGIN [ExampleViewDatabaseStateLogin];
CREATE USER [ExampleViewDatabasePerformanceUser] FOR LOGIN [ExampleViewDatabasePerformanceLogin];
CREATE USER [ExampleGroupMemberUser] FOR LOGIN [ExampleGroupMemberLogin];
GO

CREATE ROLE [ExampleMonitorDeepRole];
ALTER ROLE [ExampleMonitorDeepRole] ADD MEMBER [ExampleGroupMemberUser];
GO

GRANT VIEW DATABASE STATE TO [ExampleViewDatabaseStateUser];
GRANT VIEW DATABASE PERFORMANCE STATE TO [ExampleViewDatabasePerformanceUser];
GO

GRANT SELECT ON SCHEMA::[monitor] TO [ExampleRestrictedUser];
GRANT EXECUTE ON SCHEMA::[monitor] TO [ExampleRestrictedUser];
GRANT SELECT ON SCHEMA::[monitor] TO [ExampleViewServerStateUser];
GRANT EXECUTE ON SCHEMA::[monitor] TO [ExampleViewServerStateUser];
GRANT SELECT ON SCHEMA::[monitor] TO [ExampleViewServerPerformanceUser];
GRANT EXECUTE ON SCHEMA::[monitor] TO [ExampleViewServerPerformanceUser];
GRANT SELECT ON SCHEMA::[monitor] TO [ExampleViewDatabaseStateUser];
GRANT EXECUTE ON SCHEMA::[monitor] TO [ExampleViewDatabaseStateUser];
GRANT SELECT ON SCHEMA::[monitor] TO [ExampleViewDatabasePerformanceUser];
GRANT EXECUTE ON SCHEMA::[monitor] TO [ExampleViewDatabasePerformanceUser];
GRANT SELECT ON SCHEMA::[monitor] TO [ExampleGroupMemberUser];
GRANT EXECUTE ON SCHEMA::[monitor] TO [ExampleGroupMemberUser];
GO

CREATE TABLE [#SQL_Server_2022_Permission_Matrix_PermissionMatrix]
(
      [ScenarioCode] varchar(48) NOT NULL PRIMARY KEY
    , [EffectiveContext] sysname NOT NULL
    , [HasViewServerState] bit NOT NULL
    , [HasViewServerPerformanceState] bit NOT NULL
    , [HasViewDatabaseState] bit NOT NULL
    , [HasViewDatabasePerformanceState] bit NOT NULL
    , [CurrentSessionsStatus] varchar(40) NULL
    , [CurrentSessionsIsPartial] bit NULL
    , [CurrentSessionsErrorNumber] int NULL
    , [CurrentSessionsCapabilityPermission] sysname NULL
    , [CurrentSessionsCapabilityHasPermission] bit NULL
    , [CurrentSessionsCapabilityStatus] varchar(40) NULL
    , [QueryStorePerformanceRequiredRows] int NOT NULL
    , [QueryStorePerformanceGrantedRows] int NOT NULL
    , [PlanCacheDeepAllowed] bit NULL
    , [PlanCacheDeepAccessReason] varchar(20) NULL
    , [AllJsonValid] bit NOT NULL
);
GO

RAISERROR(N'PERMISSION_MATRIX phase=open_policy',10,1) WITH NOWAIT;
GO

/* Leere Standardpolicy muss geschützte Klassen offen lassen. */
DECLARE @OpenPolicyAllowed bit=NULL,@OpenPolicyReason varchar(20)=NULL;
BEGIN TRY
    EXECUTE AS LOGIN=N'ExampleRestrictedLogin';
    SELECT @OpenPolicyAllowed=[IsAllowed],@OpenPolicyReason=[AccessReason]
    FROM [monitor].[VW_AnalyseAccessCurrent]
    WHERE [AnalysisClass]='PLAN_CACHE_DEEP';
    REVERT;
END TRY
BEGIN CATCH
    IF SUSER_SNAME()<>ORIGINAL_LOGIN() REVERT;
    THROW;
END CATCH;

IF @OpenPolicyAllowed<>1 OR @OpenPolicyReason<>'OPEN_POLICY'
    THROW 54203,N'Die leere Standardpolicy öffnet eine geschützte Analyseklasse nicht wie vorgesehen.',1;
GO

RAISERROR(N'PERMISSION_MATRIX phase=protected_policy',10,1) WITH NOWAIT;
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
            , CAST(N'ExampleMonitorDeepRole' AS nvarchar(256))
            , CAST(1 AS bit)
            , CAST(NULL AS datetime2(0))
            , CAST(NULL AS datetime2(0))
            , CAST(100 AS smallint)
            , CAST(N'Synthetic permission-matrix role.' AS nvarchar(1000))
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

DECLARE @Scenarios TABLE
(
      [ScenarioOrdinal] int NOT NULL PRIMARY KEY
    , [ScenarioCode] varchar(48) NOT NULL
    , [LoginName] sysname NOT NULL
);

INSERT @Scenarios
VALUES
  (1,'RESTRICTED','ExampleRestrictedLogin'),
  (2,'VIEW_SERVER_STATE','ExampleViewServerStateLogin'),
  (3,'VIEW_SERVER_PERFORMANCE_STATE','ExampleViewServerPerformanceLogin'),
  (4,'VIEW_DATABASE_STATE','ExampleViewDatabaseStateLogin'),
  (5,'VIEW_DATABASE_PERFORMANCE_STATE','ExampleViewDatabasePerformanceLogin'),
  (6,'GROUP_MEMBER','ExampleGroupMemberLogin');

DECLARE @ScenarioOrdinal int=1,@ScenarioCount int=(SELECT COUNT(*) FROM @Scenarios);
DECLARE @ScenarioCode varchar(48),@LoginName sysname,@Sql nvarchar(max);

WHILE @ScenarioOrdinal<=@ScenarioCount
BEGIN
    SELECT @ScenarioCode=[ScenarioCode],@LoginName=[LoginName]
    FROM @Scenarios
    WHERE [ScenarioOrdinal]=@ScenarioOrdinal;

    SET @Sql=N'
    EXECUTE AS LOGIN=N''' + REPLACE(@LoginName,N'''',N'''''') + N''';

    DECLARE @SessionJson nvarchar(max)=NULL,@StandardJson nvarchar(max)=NULL,@QueryStoreJson nvarchar(max)=NULL;
    DECLARE @SessionStatus varchar(40)=NULL,@SessionPartial bit=NULL,@SessionErrorNumber int=NULL;
    DECLARE @CapabilityPermission sysname=NULL,@CapabilityHasPermission bit=NULL,@CapabilityStatus varchar(40)=NULL;
    DECLARE @QueryStoreRequiredRows int=0,@QueryStoreGrantedRows int=0;
    DECLARE @PlanAllowed bit=NULL,@PlanReason varchar(20)=NULL;
    DECLARE @HasViewServerState bit=NULL,@HasViewServerPerformanceState bit=NULL;
    DECLARE @HasViewDatabaseState bit=NULL,@HasViewDatabasePerformanceState bit=NULL;

    RAISERROR(N''PERMISSION_MATRIX step=current_sessions'',10,1) WITH NOWAIT;
    EXEC [monitor].[USP_CurrentSessions]
          @AktuelleSessionEinbeziehen=1
        , @MitSqlText=0
        , @MaxZeilen=5
        , @ResultSetArt=''NONE''
        , @JsonErzeugen=1
        , @Json=@SessionJson OUTPUT
        , @PrintMeldungen=0;

    RAISERROR(N''PERMISSION_MATRIX step=standard_capabilities'',10,1) WITH NOWAIT;
    EXEC [monitor].[USP_CheckFrameworkCapabilities]
          @DatabaseNames=N''''

        , @AnalyseKlasse=''STANDARD_CURRENT''
        , @MitGruppenpruefung=0
        , @ResultSetArt=''NONE''
        , @JsonErzeugen=1
        , @Json=@StandardJson OUTPUT
        , @PrintMeldungen=0;

    RAISERROR(N''PERMISSION_MATRIX step=query_store_capabilities'',10,1) WITH NOWAIT;
    EXEC [monitor].[USP_CheckFrameworkCapabilities]
          @DatabaseNames=N''''

        , @AnalyseKlasse=''QUERY_STORE_CURRENT''
        , @MitGruppenpruefung=0
        , @ResultSetArt=''NONE''
        , @JsonErzeugen=1
        , @Json=@QueryStoreJson OUTPUT
        , @PrintMeldungen=0;

    RAISERROR(N''PERMISSION_MATRIX step=parse_results'',10,1) WITH NOWAIT;
    SELECT
          @SessionStatus=JSON_VALUE(@SessionJson,''$.meta.statusCode'')
        , @SessionPartial=TRY_CONVERT(bit,JSON_VALUE(@SessionJson,''$.meta.isPartial''))
        , @SessionErrorNumber=TRY_CONVERT(int,JSON_VALUE(@SessionJson,''$.meta.errorNumber''));

    SELECT TOP(1)
          @CapabilityPermission=[RequiredPermission]
        , @CapabilityHasPermission=[HasRequiredPermission]
        , @CapabilityStatus=[StatusCode]
    FROM OPENJSON(@StandardJson,''$.capabilities'')
    WITH
    (
          [FeatureCode] varchar(64) ''$.FeatureCode''
        , [RequiredPermission] sysname ''$.RequiredPermission''
        , [HasRequiredPermission] bit ''$.HasRequiredPermission''
        , [StatusCode] varchar(40) ''$.StatusCode''
    )
    WHERE [FeatureCode]=''CURRENT_SESSIONS'';

    SELECT
          @QueryStoreRequiredRows=COUNT(*)
        , @QueryStoreGrantedRows=COALESCE(SUM(CASE WHEN [HasRequiredPermission]=1 THEN 1 ELSE 0 END),0)
    FROM OPENJSON(@QueryStoreJson,''$.capabilities'')
    WITH
    (
          [ScopeType] varchar(16) ''$.ScopeType''
        , [RequiredPermission] sysname ''$.RequiredPermission''
        , [HasRequiredPermission] bit ''$.HasRequiredPermission''
    )
    WHERE [ScopeType]=''DATABASE''
      AND [RequiredPermission]=''VIEW DATABASE PERFORMANCE STATE'';

    RAISERROR(N''PERMISSION_MATRIX step=policy_lookup'',10,1) WITH NOWAIT;
    SELECT @PlanAllowed=[IsAllowed],@PlanReason=[AccessReason]
    FROM [monitor].[VW_AnalyseAccessCurrent]
    WHERE [AnalysisClass]=''PLAN_CACHE_DEEP'';

    SET @HasViewServerState=CONVERT(bit,HAS_PERMS_BY_NAME(NULL,NULL,N''VIEW SERVER STATE''));
    SET @HasViewServerPerformanceState=CONVERT(bit,HAS_PERMS_BY_NAME(NULL,NULL,N''VIEW SERVER PERFORMANCE STATE''));
    SET @HasViewDatabaseState=CONVERT(bit,HAS_PERMS_BY_NAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),N''DATABASE'',N''VIEW DATABASE STATE''));
    SET @HasViewDatabasePerformanceState=CONVERT(bit,HAS_PERMS_BY_NAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),N''DATABASE'',N''VIEW DATABASE PERFORMANCE STATE''));
    SELECT
          @HasViewServerState=COALESCE(@HasViewServerState,0)
        , @HasViewServerPerformanceState=COALESCE(@HasViewServerPerformanceState,0)
        , @HasViewDatabaseState=COALESCE(@HasViewDatabaseState,0)
        , @HasViewDatabasePerformanceState=COALESCE(@HasViewDatabasePerformanceState,0);

    RAISERROR(N''PERMISSION_MATRIX step=insert_result'',10,1) WITH NOWAIT;
    INSERT [#SQL_Server_2022_Permission_Matrix_PermissionMatrix]
    (
          [ScenarioCode],[EffectiveContext]
        , [HasViewServerState],[HasViewServerPerformanceState]
        , [HasViewDatabaseState],[HasViewDatabasePerformanceState]
        , [CurrentSessionsStatus],[CurrentSessionsIsPartial],[CurrentSessionsErrorNumber]
        , [CurrentSessionsCapabilityPermission],[CurrentSessionsCapabilityHasPermission]
        , [CurrentSessionsCapabilityStatus]
        , [QueryStorePerformanceRequiredRows],[QueryStorePerformanceGrantedRows]
        , [PlanCacheDeepAllowed],[PlanCacheDeepAccessReason],[AllJsonValid]
    )
    VALUES
    (
          @ScenarioCode,N''' + REPLACE(@LoginName,N'''',N'''''') + N'''
        , @HasViewServerState
        , @HasViewServerPerformanceState
        , @HasViewDatabaseState
        , @HasViewDatabasePerformanceState
        , @SessionStatus,@SessionPartial,@SessionErrorNumber
        , @CapabilityPermission,@CapabilityHasPermission,@CapabilityStatus
        , @QueryStoreRequiredRows,@QueryStoreGrantedRows
        , @PlanAllowed,@PlanReason
        , CONVERT(bit,1)
    );

    RAISERROR(N''PERMISSION_MATRIX step=revert'',10,1) WITH NOWAIT;
    REVERT;';

    RAISERROR(N'PERMISSION_MATRIX scenario=%s',10,1,@ScenarioCode) WITH NOWAIT;
    BEGIN TRY
        EXEC [sys].[sp_executesql] @Sql,N'@ScenarioCode varchar(48)',@ScenarioCode=@ScenarioCode;
    END TRY
    BEGIN CATCH
    DECLARE @ScenarioErrorNumber int=ERROR_NUMBER();
    DECLARE @ScenarioErrorLine int=ERROR_LINE();
    DECLARE @ScenarioErrorProcedure sysname=ERROR_PROCEDURE();
    DECLARE @ScenarioErrorText nvarchar(2048)=ERROR_MESSAGE();
    BEGIN TRY
        REVERT;
    END TRY
    BEGIN CATCH
        SET @ScenarioErrorText=@ScenarioErrorText;
    END CATCH;
    DECLARE @ScenarioError nvarchar(2048)=CONCAT(N'Permission scenario ',@ScenarioCode,N' failed; number=',@ScenarioErrorNumber,N'; procedure=',COALESCE(@ScenarioErrorProcedure,N'<dynamic>'),N'; line=',@ScenarioErrorLine,N': ',@ScenarioErrorText);
    THROW 54209,@ScenarioError,1;
END CATCH;
    SET @ScenarioOrdinal+=1;
END;
GO

RAISERROR(N'PERMISSION_MATRIX phase=sysadmin',10,1) WITH NOWAIT;
GO

/* Sysadmin-Bypass im ursprünglichen Testkontext. */
DECLARE @SessionJson nvarchar(max)=NULL,@StandardJson nvarchar(max)=NULL,@QueryStoreJson nvarchar(max)=NULL;
DECLARE @SessionStatus varchar(40)=NULL,@SessionPartial bit=NULL,@SessionErrorNumber int=NULL;
DECLARE @CapabilityPermission sysname=NULL,@CapabilityHasPermission bit=NULL,@CapabilityStatus varchar(40)=NULL;
DECLARE @QueryStoreRequiredRows int=0,@QueryStoreGrantedRows int=0;
DECLARE @PlanAllowed bit=NULL,@PlanReason varchar(20)=NULL;
DECLARE @HasViewServerState bit=NULL,@HasViewServerPerformanceState bit=NULL;
DECLARE @HasViewDatabaseState bit=NULL,@HasViewDatabasePerformanceState bit=NULL;

EXEC [monitor].[USP_CurrentSessions]
      @AktuelleSessionEinbeziehen=1
    , @MitSqlText=0
    , @MaxZeilen=5
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@SessionJson OUTPUT
    , @PrintMeldungen=0;

EXEC [monitor].[USP_CheckFrameworkCapabilities]
      @DatabaseNames=N''

    , @AnalyseKlasse='STANDARD_CURRENT'
    , @MitGruppenpruefung=0
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@StandardJson OUTPUT
    , @PrintMeldungen=0;

EXEC [monitor].[USP_CheckFrameworkCapabilities]
      @DatabaseNames=N''

    , @AnalyseKlasse='QUERY_STORE_CURRENT'
    , @MitGruppenpruefung=0
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@QueryStoreJson OUTPUT
    , @PrintMeldungen=0;

SELECT
      @SessionStatus=JSON_VALUE(@SessionJson,'$.meta.statusCode')
    , @SessionPartial=TRY_CONVERT(bit,JSON_VALUE(@SessionJson,'$.meta.isPartial'))
    , @SessionErrorNumber=TRY_CONVERT(int,JSON_VALUE(@SessionJson,'$.meta.errorNumber'));

SELECT TOP(1)
      @CapabilityPermission=[RequiredPermission]
    , @CapabilityHasPermission=[HasRequiredPermission]
    , @CapabilityStatus=[StatusCode]
FROM OPENJSON(@StandardJson,'$.capabilities')
WITH
(
      [FeatureCode] varchar(64) '$.FeatureCode'
    , [RequiredPermission] sysname '$.RequiredPermission'
    , [HasRequiredPermission] bit '$.HasRequiredPermission'
    , [StatusCode] varchar(40) '$.StatusCode'
)
WHERE [FeatureCode]='CURRENT_SESSIONS';

SELECT
      @QueryStoreRequiredRows=COUNT(*)
    , @QueryStoreGrantedRows=COALESCE(SUM(CASE WHEN [HasRequiredPermission]=1 THEN 1 ELSE 0 END),0)
FROM OPENJSON(@QueryStoreJson,'$.capabilities')
WITH
(
      [ScopeType] varchar(16) '$.ScopeType'
    , [RequiredPermission] sysname '$.RequiredPermission'
    , [HasRequiredPermission] bit '$.HasRequiredPermission'
)
WHERE [ScopeType]='DATABASE'
  AND [RequiredPermission]='VIEW DATABASE PERFORMANCE STATE';

SELECT @PlanAllowed=[IsAllowed],@PlanReason=[AccessReason]
FROM [monitor].[VW_AnalyseAccessCurrent]
WHERE [AnalysisClass]='PLAN_CACHE_DEEP';

SET @HasViewServerState=CONVERT(bit,HAS_PERMS_BY_NAME(NULL,NULL,N'VIEW SERVER STATE'));
SET @HasViewServerPerformanceState=CONVERT(bit,HAS_PERMS_BY_NAME(NULL,NULL,N'VIEW SERVER PERFORMANCE STATE'));
SET @HasViewDatabaseState=CONVERT(bit,HAS_PERMS_BY_NAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),N'DATABASE',N'VIEW DATABASE STATE'));
SET @HasViewDatabasePerformanceState=CONVERT(bit,HAS_PERMS_BY_NAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),N'DATABASE',N'VIEW DATABASE PERFORMANCE STATE'));
SELECT
      @HasViewServerState=COALESCE(@HasViewServerState,0)
    , @HasViewServerPerformanceState=COALESCE(@HasViewServerPerformanceState,0)
    , @HasViewDatabaseState=COALESCE(@HasViewDatabaseState,0)
    , @HasViewDatabasePerformanceState=COALESCE(@HasViewDatabasePerformanceState,0);

INSERT [#SQL_Server_2022_Permission_Matrix_PermissionMatrix]
VALUES
(
      'SYSADMIN','ExampleSysadminContext'
    , @HasViewServerState
    , @HasViewServerPerformanceState
    , @HasViewDatabaseState
    , @HasViewDatabasePerformanceState
    , @SessionStatus,@SessionPartial,@SessionErrorNumber,@CapabilityPermission,@CapabilityHasPermission,@CapabilityStatus
    , @QueryStoreRequiredRows,@QueryStoreGrantedRows,@PlanAllowed,@PlanReason
    , CONVERT(bit,1)
);
GO

SELECT
      [ScenarioCode]
    , [HasViewServerState]
    , [HasViewServerPerformanceState]
    , [HasViewDatabaseState]
    , [HasViewDatabasePerformanceState]
    , [CurrentSessionsStatus]
    , [CurrentSessionsIsPartial]
    , [CurrentSessionsErrorNumber]
    , [CurrentSessionsCapabilityPermission]
    , [CurrentSessionsCapabilityHasPermission]
    , [CurrentSessionsCapabilityStatus]
    , [QueryStorePerformanceRequiredRows]
    , [QueryStorePerformanceGrantedRows]
    , [PlanCacheDeepAllowed]
    , [PlanCacheDeepAccessReason]
FROM [#SQL_Server_2022_Permission_Matrix_PermissionMatrix]
ORDER BY CASE [ScenarioCode]
    WHEN 'RESTRICTED' THEN 1
    WHEN 'VIEW_SERVER_STATE' THEN 2
    WHEN 'VIEW_SERVER_PERFORMANCE_STATE' THEN 3
    WHEN 'VIEW_DATABASE_STATE' THEN 4
    WHEN 'VIEW_DATABASE_PERFORMANCE_STATE' THEN 5
    WHEN 'GROUP_MEMBER' THEN 6
    WHEN 'SYSADMIN' THEN 7
    ELSE 99 END;
GO

RAISERROR(N'PERMISSION_MATRIX phase=assertions',10,1) WITH NOWAIT;
GO

/* Verbindliche Erwartungsmatrix. */
IF (SELECT COUNT(*) FROM [#SQL_Server_2022_Permission_Matrix_PermissionMatrix])<>7
    THROW 54210,N'Die Berechtigungsmatrix enthält nicht alle erwarteten Szenarien.',1;

IF EXISTS(SELECT 1 FROM [#SQL_Server_2022_Permission_Matrix_PermissionMatrix] WHERE [AllJsonValid]=0)
    THROW 54211,N'Mindestens ein Berechtigungsszenario lieferte kein gültiges JSON.',1;

IF EXISTS
(
    SELECT 1 FROM [#SQL_Server_2022_Permission_Matrix_PermissionMatrix]
    WHERE [ScenarioCode]='RESTRICTED'
      AND NOT
      (
[HasViewServerState]=0 AND [HasViewServerPerformanceState]=0
AND [HasViewDatabaseState]=0 AND [HasViewDatabasePerformanceState]=0
AND [CurrentSessionsStatus] IN('DENIED_PERMISSION','AVAILABLE_LIMITED')
AND [CurrentSessionsIsPartial]=1
AND [CurrentSessionsCapabilityPermission]='VIEW SERVER PERFORMANCE STATE'
AND [CurrentSessionsCapabilityHasPermission]=0
AND [CurrentSessionsCapabilityStatus]='AVAILABLE_LIMITED'
AND [QueryStorePerformanceRequiredRows]>0
AND [QueryStorePerformanceGrantedRows]=0
AND [PlanCacheDeepAllowed]=0 AND [PlanCacheDeepAccessReason]='NO_MATCH'
      )
)
    THROW 54212,N'Das vollständig eingeschränkte Szenario verletzt den erwarteten kontrollierten Denied-/Limited-Vertrag.',1;

IF EXISTS
(
    SELECT 1 FROM [#SQL_Server_2022_Permission_Matrix_PermissionMatrix]
    WHERE [ScenarioCode]='VIEW_SERVER_STATE'
      AND NOT
      (
[HasViewServerState]=1 AND [HasViewServerPerformanceState]=1
AND [HasViewDatabaseState]=1 AND [HasViewDatabasePerformanceState]=1
AND (([CurrentSessionsStatus]='AVAILABLE' AND [CurrentSessionsIsPartial]=0)
  OR ([CurrentSessionsStatus]='AVAILABLE_LIMITED' AND [CurrentSessionsIsPartial]=1))
AND [CurrentSessionsCapabilityPermission]='VIEW SERVER PERFORMANCE STATE'
AND [CurrentSessionsCapabilityHasPermission]=1
AND [CurrentSessionsCapabilityStatus]='AVAILABLE'
AND [QueryStorePerformanceRequiredRows]>0
AND [QueryStorePerformanceGrantedRows]=[QueryStorePerformanceRequiredRows]
AND [PlanCacheDeepAllowed]=0 AND [PlanCacheDeepAccessReason]='NO_MATCH'
      )
)
    THROW 54213,N'Die SQL-Server-2022-Implikation von VIEW SERVER STATE wurde nicht korrekt erkannt.',1;

IF EXISTS
(
    SELECT 1 FROM [#SQL_Server_2022_Permission_Matrix_PermissionMatrix]
    WHERE [ScenarioCode]='VIEW_SERVER_PERFORMANCE_STATE'
      AND NOT
      (
[HasViewServerState]=0 AND [HasViewServerPerformanceState]=1
AND [HasViewDatabaseState]=0 AND [HasViewDatabasePerformanceState]=1
AND (([CurrentSessionsStatus]='AVAILABLE' AND [CurrentSessionsIsPartial]=0)
  OR ([CurrentSessionsStatus]='AVAILABLE_LIMITED' AND [CurrentSessionsIsPartial]=1))
AND [CurrentSessionsCapabilityPermission]='VIEW SERVER PERFORMANCE STATE'
AND [CurrentSessionsCapabilityHasPermission]=1
AND [CurrentSessionsCapabilityStatus]='AVAILABLE'
AND [QueryStorePerformanceRequiredRows]>0
AND [QueryStorePerformanceGrantedRows]=[QueryStorePerformanceRequiredRows]
AND [PlanCacheDeepAllowed]=0 AND [PlanCacheDeepAccessReason]='NO_MATCH'
      )
)
    THROW 54214,N'Das eigenständige Recht VIEW SERVER PERFORMANCE STATE wurde nicht korrekt abgegrenzt.',1;

IF EXISTS
(
    SELECT 1 FROM [#SQL_Server_2022_Permission_Matrix_PermissionMatrix]
    WHERE [ScenarioCode]='VIEW_DATABASE_STATE'
      AND NOT
      (
[HasViewServerState]=0 AND [HasViewServerPerformanceState]=0
AND [HasViewDatabaseState]=1 AND [HasViewDatabasePerformanceState]=1
AND [CurrentSessionsStatus] IN('DENIED_PERMISSION','AVAILABLE_LIMITED')
AND [CurrentSessionsIsPartial]=1
AND [QueryStorePerformanceRequiredRows]>0
AND [QueryStorePerformanceGrantedRows]=[QueryStorePerformanceRequiredRows]
AND [PlanCacheDeepAllowed]=0 AND [PlanCacheDeepAccessReason]='NO_MATCH'
      )
)
    THROW 54215,N'Die SQL-Server-2022-Implikation von VIEW DATABASE STATE wurde nicht korrekt erkannt.',1;

IF EXISTS
(
    SELECT 1 FROM [#SQL_Server_2022_Permission_Matrix_PermissionMatrix]
    WHERE [ScenarioCode]='VIEW_DATABASE_PERFORMANCE_STATE'
      AND NOT
      (
[HasViewServerState]=0 AND [HasViewServerPerformanceState]=0
AND [HasViewDatabaseState]=0 AND [HasViewDatabasePerformanceState]=1
AND [CurrentSessionsStatus] IN('DENIED_PERMISSION','AVAILABLE_LIMITED')
AND [CurrentSessionsIsPartial]=1
AND [QueryStorePerformanceRequiredRows]>0
AND [QueryStorePerformanceGrantedRows]=[QueryStorePerformanceRequiredRows]
AND [PlanCacheDeepAllowed]=0 AND [PlanCacheDeepAccessReason]='NO_MATCH'
      )
)
    THROW 54216,N'Das eigenständige Recht VIEW DATABASE PERFORMANCE STATE wurde nicht korrekt abgegrenzt.',1;

IF EXISTS
(
    SELECT 1 FROM [#SQL_Server_2022_Permission_Matrix_PermissionMatrix]
    WHERE [ScenarioCode]='GROUP_MEMBER'
      AND NOT
      (
[HasViewServerState]=0 AND [HasViewServerPerformanceState]=0
AND [HasViewDatabaseState]=0 AND [HasViewDatabasePerformanceState]=0
AND [CurrentSessionsStatus] IN('DENIED_PERMISSION','AVAILABLE_LIMITED')
AND [CurrentSessionsIsPartial]=1
AND [CurrentSessionsCapabilityHasPermission]=0
AND [CurrentSessionsCapabilityStatus]='AVAILABLE_LIMITED'
AND [QueryStorePerformanceGrantedRows]=0
AND [PlanCacheDeepAllowed]=1 AND [PlanCacheDeepAccessReason]='IS_MEMBER'
      )
)
    THROW 54217,N'Die IS_MEMBER-Fallbackprüfung für die synthetische Datenbankrolle ist fehlgeschlagen.',1;

IF EXISTS
(
    SELECT 1 FROM [#SQL_Server_2022_Permission_Matrix_PermissionMatrix]
    WHERE [ScenarioCode]='SYSADMIN'
      AND NOT
      (
[HasViewServerState]=1 AND [HasViewServerPerformanceState]=1
AND [HasViewDatabaseState]=1 AND [HasViewDatabasePerformanceState]=1
AND [CurrentSessionsStatus]='AVAILABLE' AND [CurrentSessionsIsPartial]=0
AND [CurrentSessionsCapabilityHasPermission]=1
AND [CurrentSessionsCapabilityStatus]='AVAILABLE'
AND [QueryStorePerformanceRequiredRows]>0
AND [QueryStorePerformanceGrantedRows]=[QueryStorePerformanceRequiredRows]
AND [PlanCacheDeepAllowed]=1 AND [PlanCacheDeepAccessReason]='SYSADMIN'
      )
)
    THROW 54218,N'Der sysadmin-Bypass der Gruppenpolicy ist fehlgeschlagen.',1;
GO

/* P0 INT-DENIED und CAP-DENIED: serverweite Quellen unter einem wirklich eingeschränkten Login. */
DECLARE @P0IntegrityJson nvarchar(max)=NULL,@P0CapacityJson nvarchar(max)=NULL;
DECLARE @P0IntegrityStatus varchar(40)=NULL,@P0CapacityStatus varchar(40)=NULL;
DECLARE @P0IntegrityPartial bit=NULL,@P0CapacityPartial bit=NULL;

BEGIN TRY
    EXECUTE AS LOGIN=N'ExampleRestrictedLogin';

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
    THROW 54219,N'Der P0-Fall INT-DENIED verletzt den kontrollierten Limited-/Denied-Vertrag.',1;

IF ISJSON(@P0CapacityJson)<>1
   OR @P0CapacityStatus NOT IN('DENIED_PERMISSION','AVAILABLE_LIMITED','DENIED_GROUP')
   OR COALESCE(@P0CapacityPartial,0)<>1
    THROW 54220,N'Der P0-Fall CAP-DENIED verletzt den kontrollierten Limited-/Denied-Vertrag.',1;
GO

SELECT
      CAST('AVAILABLE' AS varchar(40)) AS [StatusCode]
    , CAST(0 AS bit) AS [IsPartial]
    , COUNT(*) AS [ExecutedScenarios]
    , SUM(CASE WHEN [CurrentSessionsStatus]='AVAILABLE' THEN 1 ELSE 0 END) AS [FullCurrentSessionScenarios]
    , SUM(CASE WHEN [CurrentSessionsStatus]='AVAILABLE_LIMITED' THEN 1 ELSE 0 END) AS [LimitedCurrentSessionScenarios]
    , SUM(CASE WHEN [PlanCacheDeepAllowed]=1 THEN 1 ELSE 0 END) AS [AllowedProtectedClassScenarios]
    , N'SQL Server 2022+ permission matrix completed with synthetic principals only.' AS [Detail]
FROM [#SQL_Server_2022_Permission_Matrix_PermissionMatrix];
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

IF IS_ROLEMEMBER(N'ExampleMonitorDeepRole',N'ExampleGroupMemberUser')=1
    ALTER ROLE [ExampleMonitorDeepRole] DROP MEMBER [ExampleGroupMemberUser];
GO
DROP USER [ExampleRestrictedUser];
DROP USER [ExampleViewServerStateUser];
DROP USER [ExampleViewServerPerformanceUser];
DROP USER [ExampleViewDatabaseStateUser];
DROP USER [ExampleViewDatabasePerformanceUser];
DROP USER [ExampleGroupMemberUser];
DROP ROLE [ExampleMonitorDeepRole];
GO

USE [master];
GO
DROP LOGIN [ExampleRestrictedLogin];
DROP LOGIN [ExampleViewServerStateLogin];
DROP LOGIN [ExampleViewServerPerformanceLogin];
DROP LOGIN [ExampleViewDatabaseStateLogin];
DROP LOGIN [ExampleViewDatabasePerformanceLogin];
DROP LOGIN [ExampleGroupMemberLogin];
GO
