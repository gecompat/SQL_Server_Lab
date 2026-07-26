USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 190_Wave1_Output_Xml_Version_Runtime_Contract.sql
Zweck        : Prüft Welle 1: Unicode-sichere sichtbare Kürzung, native XML-
               Typen, Provenienz und Offline-Build-/Lifecycle-Bewertung.
Datenschutz  : Ausschließlich generische Temp-Tabellen, synthetische Unicode-
               und XML-Werte sowie öffentliche Microsoft-Buildmetadaten. Es
               werden keine Laufzeitresultsets als Artefakte persistiert.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE TABLE [#Wave1OutputXmlVersionRuntimeContract_Failure]
(
      [TestName] sysname NOT NULL
    , [Detail] nvarchar(2048) NOT NULL
);

/* Unicode-Zeichen, abschließende Leerzeichen und Grenze 0. */
DECLARE @EmojiText nvarchar(max)=NCHAR(55357)+NCHAR(56832)+N'X';

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ProjectUnicodeText](@EmojiText,1)
    WHERE [OriginalCharacters]=2
      AND [OriginalBytes]=6
      AND [IsTruncated]=1
      AND DATALENGTH([ProjectedValue])=4
)
    INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
    VALUES(N'UNICODE_SURROGATE',N'Ein UTF-16-Surrogatpaar wurde nicht als ein Zeichen projiziert.');

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ProjectUnicodeText](N'A  ',2)
    WHERE [OriginalCharacters]=3
      AND [OriginalBytes]=6
      AND [IsTruncated]=1
      AND DATALENGTH([ProjectedValue])=4
)
    INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
    VALUES(N'UNICODE_TRAILING_SPACES',N'Abschließende Leerzeichen wurden nicht vollständig gemessen.');

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ProjectUnicodeText](@EmojiText,0)
    WHERE [OriginalCharacters]=2
      AND [IsTruncated]=0
      AND [ProjectedValue]=@EmojiText
)
    INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
    VALUES(N'UNLIMITED_OUTPUT',N'Die Grenze 0 lieferte nicht den vollständigen Wert.');

CREATE TABLE [#Wave1OutputXmlVersionRuntimeContract_Projection]
(
      [Value] nvarchar(max) NULL
    , [ValueCharacters] bigint NULL
    , [ValueBytes] bigint NULL
    , [ValueIsTruncated] bit NOT NULL DEFAULT(0)
);
INSERT [#Wave1OutputXmlVersionRuntimeContract_Projection]([Value]) VALUES(@EmojiText);

DECLARE @TruncatedCount bigint,@LargestRequired bigint;
EXEC [monitor].[InternalProjectUnicodeTextColumn]
      @SourceTable=N'#Wave1OutputXmlVersionRuntimeContract_Projection'
    , @TextColumn=N'Value'
    , @CharactersColumn=N'ValueCharacters'
    , @BytesColumn=N'ValueBytes'
    , @IsTruncatedColumn=N'ValueIsTruncated'
    , @MaxCharacters=1
    , @TruncatedValueCount=@TruncatedCount OUTPUT
    , @LargestRequiredCharacters=@LargestRequired OUTPUT;

IF @TruncatedCount<>1 OR @LargestRequired<>2
   OR NOT EXISTS
      (
          SELECT 1 FROM [#Wave1OutputXmlVersionRuntimeContract_Projection]
          WHERE [ValueCharacters]=2 AND [ValueBytes]=6
            AND [ValueIsTruncated]=1 AND DATALENGTH([Value])=4
      )
    INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
    VALUES(N'COLUMN_PROJECTION',N'Die materialisierte Textprojektion lieferte inkonsistente Metriken.');

/* XML wird aus dem vollständigen Quellwert kontrolliert typisiert. */
DECLARE @XmlValue xml,@XmlStatus varchar(40),@XmlError int,@XmlMessage nvarchar(2048);
DECLARE @LongValidXml nvarchar(max)=N'<root>'+REPLICATE(CONVERT(nvarchar(max),N'x'),5000)+N'</root>';
EXEC [monitor].[InternalParseXmlText]
      @XmlText=@LongValidXml,@XmlValue=@XmlValue OUTPUT,@StatusCode=@XmlStatus OUTPUT
    , @ErrorNumber=@XmlError OUTPUT,@ErrorMessage=@XmlMessage OUTPUT;
IF @XmlStatus<>'AVAILABLE' OR @XmlValue IS NULL
    INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
    VALUES(N'XML_LONG_VALID',N'Ein langes gültiges XML wurde nicht nativ materialisiert.');

EXEC [monitor].[InternalParseXmlText]
      @XmlText=N'<root>',@XmlValue=@XmlValue OUTPUT,@StatusCode=@XmlStatus OUTPUT
    , @ErrorNumber=@XmlError OUTPUT,@ErrorMessage=@XmlMessage OUTPUT;
IF @XmlStatus<>'XML_INVALID' OR @XmlValue IS NOT NULL
    INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
    VALUES(N'XML_INVALID',N'Ungültiges XML wurde nicht vom Größen-/Tiefenlimit unterschieden.');

EXEC [monitor].[InternalParseXmlText]
      @XmlText=N'   ',@XmlValue=@XmlValue OUTPUT,@StatusCode=@XmlStatus OUTPUT
    , @ErrorNumber=@XmlError OUTPUT,@ErrorMessage=@XmlMessage OUTPUT;
IF @XmlStatus<>'XML_EMPTY' OR @XmlValue IS NULL
    INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
    VALUES(N'XML_EMPTY',N'Leeres beziehungsweise weißraumhaltiges XML wurde nicht explizit klassifiziert.');

EXEC [monitor].[InternalParseXmlText]
      @XmlText=NULL,@XmlValue=@XmlValue OUTPUT,@StatusCode=@XmlStatus OUTPUT
    , @ErrorNumber=@XmlError OUTPUT,@ErrorMessage=@XmlMessage OUTPUT;
IF @XmlStatus<>'SOURCE_NULL' OR @XmlValue IS NOT NULL
    INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
    VALUES(N'XML_SOURCE_NULL',N'Ein fehlender XML-Quellwert wurde nicht explizit klassifiziert.');

DECLARE @DeepXml nvarchar(max)=REPLICATE(N'<n>',129)+REPLICATE(N'</n>',129);
EXEC [monitor].[InternalParseXmlText]
      @XmlText=@DeepXml,@XmlValue=@XmlValue OUTPUT,@StatusCode=@XmlStatus OUTPUT
    , @ErrorNumber=@XmlError OUTPUT,@ErrorMessage=@XmlMessage OUTPUT;
IF @XmlStatus<>'XML_UNAVAILABLE_LIMIT' OR @XmlValue IS NOT NULL
    INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
    VALUES(N'XML_DEPTH_LIMIT',N'Ein XML-Tiefenlimit wurde nicht vom ungültigen XML unterschieden.');

/* Öffentliche Offline-Buildbewertung und benannte TABLE-Ausgabe. */
CREATE TABLE [#Wave1OutputXmlVersionRuntimeContract_Server]([Seed] bit NULL);
CREATE TABLE [#Wave1OutputXmlVersionRuntimeContract_Build]([Seed] bit NULL);
CREATE TABLE [#Wave1OutputXmlVersionRuntimeContract_Lifecycle]([Seed] bit NULL);
CREATE TABLE [#Wave1OutputXmlVersionRuntimeContract_References]([Seed] bit NULL);

DECLARE @ServerStatus varchar(40),@ServerPartial bit,@ServerError int,@ServerMessage nvarchar(2048);
BEGIN TRY
    EXEC [monitor].[USP_ServerVersionInformation]
          @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"serverVersion":"#Wave1OutputXmlVersionRuntimeContract_Server","buildAssessment":"#Wave1OutputXmlVersionRuntimeContract_Build","lifecycle":"#Wave1OutputXmlVersionRuntimeContract_Lifecycle","references":"#Wave1OutputXmlVersionRuntimeContract_References"}'
        , @PrintMeldungen=0
        , @StatusCodeOut=@ServerStatus OUTPUT
        , @IsPartialOut=@ServerPartial OUTPUT
        , @ErrorNumberOut=@ServerError OUTPUT
        , @ErrorMessageOut=@ServerMessage OUTPUT;

    IF @ServerStatus NOT IN('AVAILABLE','AVAILABLE_LIMITED')
       OR (SELECT COUNT_BIG(*) FROM [#Wave1OutputXmlVersionRuntimeContract_Server])<>1
       OR (SELECT COUNT_BIG(*) FROM [#Wave1OutputXmlVersionRuntimeContract_Build])<>1
       OR (SELECT COUNT_BIG(*) FROM [#Wave1OutputXmlVersionRuntimeContract_Lifecycle])<>1
       OR (SELECT COUNT_BIG(*) FROM [#Wave1OutputXmlVersionRuntimeContract_References])<5
        INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
        VALUES(N'SERVER_VERSION_TABLE',N'Die benannte Serverversionsausgabe war unvollständig oder nicht verfügbar.');

    IF EXISTS
       (
           SELECT 1 FROM [#Wave1OutputXmlVersionRuntimeContract_Build]
           WHERE [AssessmentStatus] NOT IN('EXACT_MATCH','OLDER_KNOWN_BUILD','BUILD_NEWER_THAN_OFFLINE_CATALOG','UNKNOWN_BUILD','PREVIEW_BUILD','ON_DEMAND_BUILD')
              OR [CatalogAsOfDate]<>'2026-07-21'
              OR [BuildOverviewUrl] NOT LIKE N'https://learn.microsoft.com/%'
       )
        INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
        VALUES(N'BUILD_ASSESSMENT',N'Die Offline-Buildbewertung verletzt ihren Status- oder Quellenvertrag.');
END TRY
BEGIN CATCH
    INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
    VALUES(N'SERVER_VERSION_TABLE',CONCAT(N'Die TABLE-Abnahme der Serverversion ist fehlgeschlagen: ',ERROR_NUMBER(),N'.'));
END CATCH;

DECLARE @ServerJson nvarchar(max);
EXEC [monitor].[USP_ServerVersionInformation]
      @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@ServerJson OUTPUT,@PrintMeldungen=0;
IF ISJSON(@ServerJson)<>1
   OR JSON_VALUE(@ServerJson,N'$.meta.resultName')<>N'ServerVersionInformation'
    INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
    VALUES(N'SERVER_VERSION_JSON',N'Die Serverversionsausgabe lieferte keinen gültigen JSON-Vertrag.');

IF NOT EXISTS
(
    SELECT 1 FROM [monitor].[SqlServerBuildCatalog] WITH (NOLOCK)
    WHERE [BuildVersion] IN('15.0.4480.2','16.0.4265.3','17.0.4065.4')
    GROUP BY [CatalogAsOfDate]
    HAVING COUNT(*)=3 AND [CatalogAsOfDate]='2026-07-21'
)
    INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
    VALUES(N'BUILD_CATALOG',N'Der aktuelle öffentliche Offline-Buildseed ist unvollständig.');

IF 3<>(SELECT COUNT(*) FROM [monitor].[SqlServerLifecycleCatalog] WITH (NOLOCK)
       WHERE [ProductMajorVersion] IN(15,16,17) AND [CatalogAsOfDate]='2026-07-21')
    INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
    VALUES(N'LIFECYCLE_CATALOG',N'Der Lifecycle-Seed für SQL Server 2019, 2022 und 2025 ist unvollständig.');

/* Native XML-Spaltentypen über die öffentlichen TABLE-Pfade. */
CREATE TABLE [#Wave1OutputXmlVersionRuntimeContract_RuntimePlans]([Seed] bit NULL);
CREATE TABLE [#Wave1OutputXmlVersionRuntimeContract_ChangedPlans]([Seed] bit NULL);
CREATE TABLE [#Wave1OutputXmlVersionRuntimeContract_ForcedPlans]([Seed] bit NULL);
CREATE TABLE [#Wave1OutputXmlVersionRuntimeContract_CachedPlans]([Seed] bit NULL);

BEGIN TRY
    EXEC [monitor].[USP_QueryStoreRuntimeStats]
          @QueryStoreDatabaseNames=N'[DeineDatenbank]',@MitPlanXml=0,@MaxZeilen=1
        , @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"runtimeStats":"#Wave1OutputXmlVersionRuntimeContract_RuntimePlans"}'
        , @PrintMeldungen=0;
    EXEC [monitor].[USP_QueryStorePlanChanges]
          @QueryStoreDatabaseNames=N'[DeineDatenbank]',@MitPlanXml=0,@MaxZeilen=1
        , @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"plans":"#Wave1OutputXmlVersionRuntimeContract_ChangedPlans"}'
        , @PrintMeldungen=0;
    EXEC [monitor].[USP_QueryStoreForcedPlans]
          @QueryStoreDatabaseNames=N'[DeineDatenbank]',@MitPlanXml=0,@MaxZeilen=1
        , @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"forcedPlans":"#Wave1OutputXmlVersionRuntimeContract_ForcedPlans"}'
        , @PrintMeldungen=0;
    EXEC [monitor].[USP_PlanDetails]
          @SessionIds=N'32767',@MitPlanAttributes=0,@MitCompilePlan=0
        , @MitTextPlan=0,@MitLastActualPlan=0,@MitLivePlan=0,@MaxAnalyseobjekte=1
        , @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"plans":"#Wave1OutputXmlVersionRuntimeContract_CachedPlans"}'
        , @PrintMeldungen=0;
END TRY
BEGIN CATCH
    INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
    VALUES(N'NATIVE_XML_TABLE_CALLS',CONCAT(N'Ein öffentlicher TABLE-Pfad ist fehlgeschlagen: ',ERROR_NUMBER(),N'.'));
END CATCH;

IF 4<>
(
    SELECT COUNT(*)
    FROM
    (
        VALUES
          (N'#Wave1OutputXmlVersionRuntimeContract_RuntimePlans',N'QueryPlan')
        , (N'#Wave1OutputXmlVersionRuntimeContract_ChangedPlans',N'QueryPlan')
        , (N'#Wave1OutputXmlVersionRuntimeContract_ForcedPlans',N'QueryPlan')
        , (N'#Wave1OutputXmlVersionRuntimeContract_CachedPlans',N'QueryPlanXml')
    ) AS [required]([TablePrefix],[ColumnName])
    WHERE EXISTS
    (
        SELECT 1
        FROM [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
        INNER JOIN [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
          ON [c].[object_id]=[t].[object_id]
        WHERE [t].[name] LIKE [required].[TablePrefix]+N'%'
          AND [c].[name]=[required].[ColumnName]
          AND [c].[system_type_id]=241
    )
)
    INSERT [#Wave1OutputXmlVersionRuntimeContract_Failure]
    VALUES(N'NATIVE_XML_TABLE_TYPES',N'Nicht alle öffentlichen TABLE-Pfade materialisierten natives xml.');

SELECT [TestName],[Detail]
FROM [#Wave1OutputXmlVersionRuntimeContract_Failure]
ORDER BY [TestName],[Detail];

IF EXISTS(SELECT 1 FROM [#Wave1OutputXmlVersionRuntimeContract_Failure])
    THROW 54721,N'Der Welle-1-Laufzeitvertrag ist verletzt.',1;
GO
:ON ERROR EXIT
