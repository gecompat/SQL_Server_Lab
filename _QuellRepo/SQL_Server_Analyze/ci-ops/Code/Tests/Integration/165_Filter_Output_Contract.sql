USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 165_Filter_Output_Contract.sql
Zweck        : Prüft zentrale Listen-, Pattern-, Ausgabe- und JSON-Verträge
               gegen eine installierte Frameworkinstanz. Der Test ist lesend;
               er begrenzt Datenbank-, Analyseobjekt- und Ergebnisumfang.
Voraussetzung: Vollständige Frameworkinstallation. SQL Server 2019 oder neuer.
Hinweis      : regex:/regexi: werden auf Servern unter SQL Server 2025 mit
               Compatibility Level 170 erwartungsgemäß als UNAVAILABLE_FEATURE
               geprüft. Der Test erzeugt keine dauerhaften Objekte.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET LOCK_TIMEOUT 5000;
GO

CREATE TABLE [#Filter_Output_Contract_Failure]
(
      [TestName] sysname NOT NULL
    , [Detail] nvarchar(2048) NOT NULL
);

CREATE TABLE [#Filter_Output_Contract_PublicProcedureResult]
(
      [ProcedureName] sysname NOT NULL
    , [TestStatus] varchar(16) NOT NULL
    , [JsonStatus] varchar(32) NULL
    , [ErrorNumber] int NULL
    , [ErrorMessage] nvarchar(2048) NULL
);

/* Bracket-aware Pipe-Listen: Trennung nur außerhalb von [ ... ]. */
IF (SELECT COUNT(*) FROM [monitor].[TVF_ParsePipeList](N'[A|B]|[C]]D]|E') WHERE [IsValid]=1) <> 3
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'TVF_ParsePipeList_valid',N'Gültige bracket-aware Pipe-Liste wurde nicht in drei Elemente zerlegt.');

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParsePipeList](N'[A|B]|[C]]D]|E')
    WHERE [ItemOrdinal]=1 AND [ItemText]=N'[A|B]' AND [IsBracketQuoted]=1 AND [IsValid]=1
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'TVF_ParsePipeList_bracket_pipe',N'Pipe innerhalb eines bracket-quotierten Elements wurde nicht erhalten.');

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParsePipeList](N'A||B')
    WHERE [ItemOrdinal]=2 AND [IsValid]=0 AND [ErrorCode]='EMPTY_ITEM'
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'TVF_ParsePipeList_empty_item',N'Leeres Pipe-Listenelement wurde nicht als ungültig erkannt.');

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParsePipeList](N'[A|B')
    WHERE [IsValid]=0 AND [ErrorCode]='INVALID_BRACKET_SYNTAX'
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'TVF_ParsePipeList_bracket_syntax',N'Nicht geschlossene Klammer wurde nicht als ungültig erkannt.');


/* Numerische Listen: Pipe, Beistrich und Strichpunkt sind gleichwertig. */
IF (SELECT COUNT(*) FROM [monitor].[TVF_ParseBigintList](N'11, 22;33|44') WHERE [IsValid]=1) <> 4
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'TVF_ParseBigintList_delimiters',N'Gemischte numerische Trennzeichen wurden nicht in vier gültige Elemente zerlegt.');

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParseBigintList](N'11, 22;33|44')
    WHERE [ItemOrdinal]=2 AND [ItemText]=N'22' AND [NumberValue]=22 AND [IsValid]=1
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'TVF_ParseBigintList_ordinal',N'Beistrich-getrenntes numerisches Listenelement wurde nicht korrekt normalisiert.');

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParseBigintList](N'11,;22')
    WHERE [ItemOrdinal]=2 AND [IsValid]=0 AND [ErrorCode]='EMPTY_ITEM'
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'TVF_ParseBigintList_empty_item',N'Leeres numerisches Listenelement zwischen gemischten Trennzeichen wurde nicht erkannt.');

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParseSqlNameList](N'[A|B]|[C]]D]')
    WHERE [ItemOrdinal]=1 AND [NameValue]=N'A|B' AND [IsValid]=1
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'TVF_ParseSqlNameList',N'Bracket-quotierter einteiliger SQL-Name wurde nicht korrekt entquotet.');

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParseFullObjectNameList](N'[ExampleDatabase].[dbo].[A|B]|[dbo].[C]')
    WHERE [ItemOrdinal]=1 AND [DatabaseName]=N'ExampleDatabase' AND [SchemaName]=N'dbo' AND [ObjectName]=N'A|B' AND [IsValid]=1
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'TVF_ParseFullObjectNameList',N'Dreiteiliger bracket-aware Objektname wurde nicht korrekt verarbeitet.');

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParseFullObjectNameList](N'[Server].[DeineDatenbank].[dbo].[Objekt]')
    WHERE [IsValid]=0 AND [ErrorCode]='FOUR_PART_NAME_NOT_ALLOWED'
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'TVF_ParseFullObjectNameList_four_part',N'Verbotener vierteiliger Objektname wurde nicht abgelehnt.');

/* Pattern-Präfixe sind case-insensitiv, der Patterninhalt bleibt unverändert. */
IF NOT EXISTS
(
    SELECT 1 FROM [monitor].[TVF_ParsePattern](N'LiKe:Ab_%')
    WHERE [PatternMode]='LIKE' AND [PatternValue]=N'Ab_%' AND [IsValid]=1
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'TVF_ParsePattern_like',N'LIKE-Pattern wurde nicht korrekt normalisiert.');

IF NOT EXISTS
(
    SELECT 1 FROM [monitor].[TVF_ParsePattern](N'ReGeX:^Ab.+$')
    WHERE [PatternMode]='REGEX' AND [RegexFlags]='c' AND [IsValid]=1
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'TVF_ParsePattern_regex',N'regex:-Pattern wurde nicht korrekt normalisiert.');

IF NOT EXISTS
(
    SELECT 1 FROM [monitor].[TVF_ParsePattern](N'ReGeXi:^ab.+$')
    WHERE [PatternMode]='REGEXI' AND [RegexFlags]='i' AND [IsValid]=1
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'TVF_ParsePattern_regexi',N'regexi:-Pattern wurde nicht korrekt normalisiert.');

IF NOT EXISTS
(
    SELECT 1 FROM [monitor].[TVF_ParsePattern](N'regex:')
    WHERE [IsValid]=0 AND [ErrorCode]='EMPTY_PATTERN'
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'TVF_ParsePattern_empty',N'Leeres Pattern nach Präfix wurde nicht abgelehnt.');

/* Metadatengetriebene Tool-Hintergrundklassifikation mit echter LIKE-Semantik. */
IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [table] WITH (NOLOCK)
    JOIN [sys].[schemas] AS [schema] WITH (NOLOCK)
      ON [schema].[schema_id] = [table].[schema_id]
    WHERE [schema].[name] = N'monitor'
      AND [table].[name] = N'ToolBackgroundQueryPattern'
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'ToolBackground_pattern_table',N'Die Steuertabelle ToolBackgroundQueryPattern fehlt.');

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ToolBackgroundQueryInfo]
         (N'Microsoft SQL Server Management Studio - GitHub Copilot')
    WHERE [IsToolBackgroundQuery]=1
      AND [ToolBackgroundRuleCode]='SSMS_GITHUB_COPILOT'
      AND [ToolBackgroundConfidence]='HIGH'
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'ToolBackground_copilot',N'Der dokumentierte Copilot-Clientname wurde nicht hoch-konfident klassifiziert.');

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ToolBackgroundQueryInfo]
         (N'Microsoft SQL Server Management Studio - Object Explorer Details')
    WHERE [IsToolBackgroundQuery]=1
      AND [ToolBackgroundRuleCode]='SSMS_OBJECT_EXPLORER'
      AND [ToolBackgroundConfidence]='MEDIUM'
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'ToolBackground_like',N'Das Object-Explorer-LIKE-Muster mit Suffix wurde nicht ausgewertet.');

IF EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ToolBackgroundQueryInfo](N'Example Business Application')
    WHERE [IsToolBackgroundQuery]<>0
       OR [ToolBackgroundRuleCode] IS NOT NULL
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'ToolBackground_nonmatch',N'Eine nicht passende Fachanwendung wurde fälschlich als Tool-Hintergrundabfrage klassifiziert.');

IF EXISTS
(
    SELECT [required].[ProcedureName]
    FROM (VALUES
          (N'USP_CurrentSessions'),(N'USP_CurrentRequests'),
          (N'USP_CurrentBlocking'),(N'USP_CurrentWaits'),
          (N'USP_CurrentOverview')) AS [required]([ProcedureName])
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM [sys].[procedures] AS [procedure] WITH (NOLOCK)
        JOIN [sys].[schemas] AS [schema] WITH (NOLOCK)
          ON [schema].[schema_id]=[procedure].[schema_id]
        JOIN [sys].[parameters] AS [parameter] WITH (NOLOCK)
          ON [parameter].[object_id]=[procedure].[object_id]
        WHERE [schema].[name]=N'monitor'
          AND [procedure].[name]=[required].[ProcedureName]
          AND [parameter].[name]=N'@ToolHintergrundabfragenEinbeziehen'
    )
)
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'ToolBackground_public_parameter',N'Der öffentliche Tool-Hintergrundparameter fehlt bei mindestens einer Current-State-Procedure.');

BEGIN TRY
    CREATE TABLE [#Filter_Output_Contract_Blocking]([Dummy] int NULL);
    EXEC [monitor].[USP_CurrentBlocking]
          @BlockingObjektTiefe='NONE'
        , @ToolHintergrundabfragenEinbeziehen=1
        , @MitSqlText=0
        , @MaxZeilen=1
        , @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"blockingChains":"#Filter_Output_Contract_Blocking"}'
        , @PrintMeldungen=0;

    IF
    (
        SELECT COUNT(DISTINCT [column].[name])
        FROM [tempdb].[sys].[tables] AS [table] WITH (NOLOCK)
        JOIN [tempdb].[sys].[columns] AS [column] WITH (NOLOCK)
          ON [column].[object_id] = [table].[object_id]
        WHERE [table].[name] LIKE N'#Filter_Output_Contract_Blocking%'
          AND [column].[name] IN
              (
                  N'BlockingChain', N'RootBlockerProgramName'
                , N'RootBlockerOpenTransactionCount', N'RootBlockerStatementSource'
                , N'RootBlockerStatement', N'BlockedToolBackgroundRuleCode'
              )
    ) <> 6
        INSERT [#Filter_Output_Contract_Failure] VALUES(N'CurrentBlocking_chain_schema',N'Der TABLE-Vertrag enthält nicht alle Ketten-, Root-Blocker- und Toolklassifikationsspalten.');

    DROP TABLE [#Filter_Output_Contract_Blocking];
END TRY
BEGIN CATCH
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'CurrentBlocking_chain_runtime',CONCAT(N'Blocking-Kettenvertrag konnte nicht materialisiert werden: ',ERROR_MESSAGE()));
    DROP TABLE IF EXISTS [#Filter_Output_Contract_Blocking];
END CATCH;

/* Repräsentative reale Consumer: exakte Listen, LIKE und Konfliktvalidierung. */
DECLARE @SelfSessionIds nvarchar(20)=CONVERT(nvarchar(20),@@SPID);
DECLARE @Json nvarchar(max);

EXEC [monitor].[USP_CurrentSessions]
      @SessionIds=@SelfSessionIds
    , @AktuelleSessionEinbeziehen=1
    , @MaxZeilen=1
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@Json OUTPUT
    , @PrintMeldungen=0;
IF ISJSON(@Json)<>1
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'USP_CurrentSessions_exact_list',N'Exakte Sessionliste erzeugte kein gültiges JSON.');

SET @Json=NULL;
EXEC [monitor].[USP_CurrentSessions]
      @SessionIds=@SelfSessionIds
    , @LoginNamePattern=N'like:%'
    , @MaxZeilen=1
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@Json OUTPUT
    , @PrintMeldungen=0;
IF ISJSON(@Json)<>1
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'USP_CurrentSessions_like',N'LIKE-Filter erzeugte kein gültiges JSON.');

SET @Json=NULL;
EXEC [monitor].[USP_CurrentSessions]
      @LoginNames=N'[NoSuchLogin]'
    , @LoginNamePattern=N'like:%'
    , @MaxZeilen=1
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@Json OUTPUT
    , @PrintMeldungen=0;
IF JSON_VALUE(@Json,N'$.meta.statusCode')<>N'INVALID_PARAMETER'
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'USP_CurrentSessions_list_pattern_conflict',N'Gleichzeitige exakte Liste und Pattern wurden nicht als INVALID_PARAMETER zurückgewiesen.');

SET @Json=NULL;
EXEC [monitor].[USP_CurrentWaits]
      @WaitTypes=N'[__MonitorTestWaitA]|[__MonitorTestWaitB]'
    , @MaxZeilen=1
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@Json OUTPUT
    , @PrintMeldungen=0;
IF ISJSON(@Json)<>1
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'USP_CurrentWaits_exact_list',N'Exakte Waitliste erzeugte kein gültiges JSON.');

SET @Json=NULL;
EXEC [monitor].[USP_CurrentWaits]
      @WaitTypePattern=N'like:__MonitorTestWait%'
    , @MaxZeilen=1
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@Json OUTPUT
    , @PrintMeldungen=0;
IF ISJSON(@Json)<>1
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'USP_CurrentWaits_like',N'LIKE-Waitfilter erzeugte kein gültiges JSON.');

SET @Json=NULL;
EXEC [monitor].[USP_CurrentWaits]
      @WaitTypePattern=N'regex:^__MonitorTestWait.*$'
    , @MaxZeilen=1
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@Json OUTPUT
    , @PrintMeldungen=0;
IF TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'))<17
   AND JSON_VALUE(@Json,N'$.meta.statusCode')<>N'UNAVAILABLE_FEATURE'
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'USP_CurrentWaits_regex_version_fallback',N'Regex wurde auf einem Server vor SQL Server 2025 nicht als UNAVAILABLE_FEATURE ausgewiesen.');
IF TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'))>=17 AND ISJSON(@Json)<>1
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'USP_CurrentWaits_regex',N'Regex-Waitfilter erzeugte kein gültiges JSON.');

SET @Json=NULL;
EXEC [monitor].[USP_CheckFrameworkCapabilities]
      @DatabaseNames=N''

    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@Json OUTPUT
    , @PrintMeldungen=0;
IF ISJSON(@Json)<>1
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'USP_CheckFrameworkCapabilities_database_scope',N'Aktueller Datenbankscope erzeugte kein gültiges JSON.');

SET @Json=NULL;
EXEC [monitor].[USP_CheckFrameworkCapabilities]
      @DatabaseNamePattern=N'like:%'

    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@Json OUTPUT
    , @PrintMeldungen=0;
IF ISJSON(@Json)<>1
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'USP_CheckFrameworkCapabilities_database_like',N'Datenbank-LIKE-Filter erzeugte kein gültiges JSON.');

/* Query Store: dynamische Regressionsermittlung muss ohne abgefangene SQL-Fehler laufen. */
SET @Json=NULL;
EXEC [monitor].[USP_QueryStoreRegressions]
      @QueryStoreDatabaseNames=N''

    , @MaxZeilen=10
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@Json OUTPUT
    , @PrintMeldungen=0;
IF ISJSON(@Json)<>1
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'USP_QueryStoreRegressions_json',N'Query-Store-Regressionsanalyse erzeugte kein gültiges JSON.');
ELSE IF JSON_VALUE(@Json,N'$.meta.statusCode')=N'ERROR_HANDLED'
     OR EXISTS
     (
         SELECT 1
         FROM OPENJSON(@Json,N'$.warnings')
         WITH
         (
               [StatusCode] varchar(40) N'$.StatusCode'
             , [ErrorNumber] int N'$.ErrorNumber'
         ) AS [w]
         WHERE [w].[StatusCode]=N'ERROR_HANDLED' OR [w].[ErrorNumber]=209
     )
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'USP_QueryStoreRegressions_dynamic_sql',N'Query-Store-Regressionsanalyse enthielt einen abgefangenen dynamischen SQL-Fehler.');

/* Alle öffentlichen Procedures: NONE+JSON mit sicheren Begrenzungen. */
DECLARE @ProcedureName sysname,@ObjectId int,@Sql nvarchar(max),@Arguments nvarchar(max);
DECLARE [ProcedureCursor] CURSOR LOCAL FAST_FORWARD FOR
SELECT [p].[name],[p].[object_id]
FROM [sys].[procedures] AS [p] WITH (NOLOCK)
JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[p].[schema_id]
WHERE [s].[name]=N'monitor'
  AND [p].[name] NOT LIKE N'Internal%'
  AND [p].[name] NOT LIKE N'USP_Prepare%'
ORDER BY [p].[name];

OPEN [ProcedureCursor];
FETCH NEXT FROM [ProcedureCursor] INTO @ProcedureName,@ObjectId;
WHILE @@FETCH_STATUS=0
BEGIN
    SET @Arguments=N'@ResultSetArt=N''NONE'',@JsonErzeugen=1,@Json=@Json OUTPUT';
    IF EXISTS(SELECT 1 FROM [sys].[parameters] WITH (NOLOCK) WHERE [object_id]=@ObjectId AND [name]=N'@DatabaseNames') SET @Arguments+=N',@DatabaseNames=N''''';
    IF EXISTS(SELECT 1 FROM [sys].[parameters] WITH (NOLOCK) WHERE [object_id]=@ObjectId AND [name]=N'@QueryStoreDatabaseNames') SET @Arguments+=N',@QueryStoreDatabaseNames=N''''';
    IF EXISTS(SELECT 1 FROM [sys].[parameters] WITH (NOLOCK) WHERE [object_id]=@ObjectId AND [name]=N'@MaxZeilen') SET @Arguments+=N',@MaxZeilen=1';
    IF EXISTS(SELECT 1 FROM [sys].[parameters] WITH (NOLOCK) WHERE [object_id]=@ObjectId AND [name]=N'@MaxAnalyseobjekte') SET @Arguments+=N',@MaxAnalyseobjekte=1';
    IF EXISTS(SELECT 1 FROM [sys].[parameters] WITH (NOLOCK) WHERE [object_id]=@ObjectId AND [name]=N'@LockTimeoutMs') SET @Arguments+=N',@LockTimeoutMs=5000';
    IF EXISTS(SELECT 1 FROM [sys].[parameters] WITH (NOLOCK) WHERE [object_id]=@ObjectId AND [name]=N'@PrintMeldungen') SET @Arguments+=N',@PrintMeldungen=0';

    SET @Sql=N'
BEGIN TRY
    DECLARE @Json nvarchar(max);
    EXEC [monitor].'+QUOTENAME(@ProcedureName)+N' '+@Arguments+N';
    INSERT [#Filter_Output_Contract_PublicProcedureResult]([ProcedureName],[TestStatus],[JsonStatus])
    VALUES(N'''+REPLACE(@ProcedureName,N'''',N'''''')+N''',''PASS'',CASE WHEN ISJSON(@Json)=1 THEN ''VALID_JSON'' ELSE ''MISSING_OR_INVALID_JSON'' END);
END TRY
BEGIN CATCH
    INSERT [#Filter_Output_Contract_PublicProcedureResult]([ProcedureName],[TestStatus],[ErrorNumber],[ErrorMessage])
    VALUES(N'''+REPLACE(@ProcedureName,N'''',N'''''')+N''',''FAIL'',ERROR_NUMBER(),ERROR_MESSAGE());
END CATCH;';
    EXEC [sys].[sp_executesql] @Sql;
    FETCH NEXT FROM [ProcedureCursor] INTO @ProcedureName,@ObjectId;
END;
CLOSE [ProcedureCursor];
DEALLOCATE [ProcedureCursor];

INSERT [#Filter_Output_Contract_Failure]([TestName],[Detail])
SELECT [ProcedureName],CONCAT(N'NONE/JSON-Laufzeittest fehlgeschlagen: ',COALESCE([ErrorMessage],[JsonStatus],N'Unbekannter Fehler.'))
FROM [#Filter_Output_Contract_PublicProcedureResult]
WHERE [TestStatus]<>'PASS' OR [JsonStatus]<>'VALID_JSON';

/* Repräsentative RAW- und CONSOLE-Ausführung derselben öffentlichen API. */
BEGIN TRY
    EXEC [monitor].[USP_CurrentRequests]
          @SessionIds=@SelfSessionIds
        , @AktuelleSessionEinbeziehen=1
        , @MaxZeilen=1
        , @ResultSetArt='RAW'
        , @PrintMeldungen=0;
    EXEC [monitor].[USP_CurrentRequests]
          @SessionIds=@SelfSessionIds
        , @AktuelleSessionEinbeziehen=1
        , @MaxZeilen=1
        , @ResultSetArt='CONSOLE'
        , @PrintMeldungen=0;
    EXEC [monitor].[USP_CheckFrameworkCapabilities]
          @DatabaseNames=N''

        , @ResultSetArt='RAW'
        , @PrintMeldungen=0;
    EXEC [monitor].[USP_CheckFrameworkCapabilities]
          @DatabaseNames=N''

        , @ResultSetArt='CONSOLE'
        , @PrintMeldungen=0;
END TRY
BEGIN CATCH
    INSERT [#Filter_Output_Contract_Failure] VALUES(N'RAW_CONSOLE_contract',CONCAT(N'RAW- oder CONSOLE-Ausführung fehlgeschlagen: ',ERROR_MESSAGE()));
END CATCH;

SELECT [TestName],[Detail] FROM [#Filter_Output_Contract_Failure] ORDER BY [TestName];
SELECT [TestStatus],[JsonStatus],COUNT(*) AS [ProcedureCount]
FROM [#Filter_Output_Contract_PublicProcedureResult]
GROUP BY [TestStatus],[JsonStatus]
ORDER BY [TestStatus],[JsonStatus];

IF EXISTS(SELECT 1 FROM [#Filter_Output_Contract_Failure])
    THROW 54130,N'Der Filter-, Ausgabe- oder JSON-Vertrag ist verletzt.',1;
GO
