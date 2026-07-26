USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 187_Table_Output_Runtime_Contract.sql
Zweck        : Prüft Strukturadaption, typisierten Insert, Append, kontrollierte
               Schemaabweichung und die öffentliche TABLE-Ausgabe ausschließlich
               mit synthetischen lokalen #Temp-Tabellen.
Datenschutz  : Keine realen Laufzeitwerte werden persistiert oder ausgegeben.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE TABLE [#TableOutputRuntimeContract_Failure]
(
      [TestName] sysname NOT NULL
    , [Detail] nvarchar(2048) NOT NULL
);

CREATE TABLE [#TableOutputRuntimeContract_Source]
(
      [Id] int NOT NULL
    , [Name] nvarchar(40) COLLATE Latin1_General_100_CI_AS NULL
    , [Amount] decimal(19,4) NULL
    , [CapturedUtc] datetime2(3) NOT NULL
);

INSERT [#TableOutputRuntimeContract_Source] ([Id],[Name],[Amount],[CapturedUtc])
VALUES
      (1,N'Example A',CONVERT(decimal(19,4),12.3456),CONVERT(datetime2(3),'2026-01-01T00:00:00.000'))
    , (2,N'Example B',NULL,CONVERT(datetime2(3),'2026-01-02T00:00:00.000'));

CREATE TABLE [#TableOutputRuntimeContract_AdaptTarget] ([ArbitraryDummy] int NULL);

DECLARE @Rows bigint,@Status varchar(40),@ErrorNumber int,@ErrorMessage nvarchar(2048);

EXEC [monitor].[InternalWriteResultTable]
      @SourceTable=N'#TableOutputRuntimeContract_Source'
    , @TargetTable=N'#TableOutputRuntimeContract_AdaptTarget'
    , @InsertedRows=@Rows OUTPUT
    , @StatusCode=@Status OUTPUT
    , @ErrorNumber=@ErrorNumber OUTPUT
    , @ErrorMessage=@ErrorMessage OUTPUT;

IF @Status<>'AVAILABLE' OR @Rows<>2
    INSERT [#TableOutputRuntimeContract_Failure] VALUES(N'ARBITRARY_DUMMY_ADAPT',CONCAT(N'Erwartet AVAILABLE/2, erhalten ',COALESCE(@Status,N'NULL'),N'/',COALESCE(CONVERT(nvarchar(30),@Rows),N'NULL'),N': ',COALESCE(@ErrorMessage,N'')));

IF EXISTS
(
    SELECT 1
    FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
    JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id]=[c].[object_id]
    WHERE [t].[name] LIKE N'#TableOutputRuntimeContract_AdaptTarget%'
      AND [c].[name]=N'ArbitraryDummy'
)
OR NOT EXISTS
(
    SELECT 1
    FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
    JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id]=[c].[object_id]
    WHERE [t].[name] LIKE N'#TableOutputRuntimeContract_AdaptTarget%'
      AND [c].[name]=N'Id'
      AND [c].[system_type_id]=56
)
OR NOT EXISTS
(
    SELECT 1
    FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
    JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id]=[c].[object_id]
    WHERE [t].[name] LIKE N'#TableOutputRuntimeContract_AdaptTarget%'
      AND [c].[name]=N'Name'
      AND [c].[max_length]=80
)
    INSERT [#TableOutputRuntimeContract_Failure] VALUES(N'NATIVE_COLUMN_SHAPE',N'Beliebige Dummy-Spalte oder native int-/nvarchar-Struktur stimmt nach der Adaption nicht.');

IF NOT EXISTS
(
    SELECT 1
    FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
    JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id]=[c].[object_id]
    WHERE [t].[name] LIKE N'#TableOutputRuntimeContract_AdaptTarget%'
      AND [c].[name]=N'Amount'
      AND [c].[precision]=19
      AND [c].[scale]=4
      AND [c].[is_nullable]=1
)
    INSERT [#TableOutputRuntimeContract_Failure] VALUES(N'DECIMAL_SHAPE',N'Precision, Scale oder Nullability der decimal-Spalte wurden nicht erhalten.');

IF NOT EXISTS
(
    SELECT 1
    FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
    JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id]=[c].[object_id]
    WHERE [t].[name] LIKE N'#TableOutputRuntimeContract_AdaptTarget%'
      AND [c].[name]=N'CapturedUtc'
      AND [c].[scale]=3
      AND [c].[is_nullable]=0
)
    INSERT [#TableOutputRuntimeContract_Failure] VALUES(N'DATETIME_SHAPE',N'Scale oder Nullability der datetime2-Spalte wurden nicht erhalten.');

DECLARE @AdaptedRowCount bigint;
EXEC [sys].[sp_executesql]
      N'SELECT @RowCount=COUNT_BIG(*) FROM [#TableOutputRuntimeContract_AdaptTarget];'
    , N'@RowCount bigint OUTPUT'
    , @RowCount=@AdaptedRowCount OUTPUT;

IF @AdaptedRowCount<>2
    INSERT [#TableOutputRuntimeContract_Failure] VALUES(N'ADAPTED_ROWS',N'Die Struktur wurde angepasst, aber die erwarteten zwei synthetischen Zeilen wurden nicht geschrieben.');

CREATE TABLE [#TableOutputRuntimeContract_ExactTarget]
(
      [Id] int NOT NULL
    , [Name] nvarchar(40) COLLATE Latin1_General_100_CI_AS NULL
    , [Amount] decimal(19,4) NULL
    , [CapturedUtc] datetime2(3) NOT NULL
);

SET @Rows=NULL;SET @Status=NULL;SET @ErrorNumber=NULL;SET @ErrorMessage=NULL;
EXEC [monitor].[InternalWriteResultTable]
      @SourceTable=N'#TableOutputRuntimeContract_Source'
    , @TargetTable=N'#TableOutputRuntimeContract_ExactTarget'
    , @InsertedRows=@Rows OUTPUT
    , @StatusCode=@Status OUTPUT
    , @ErrorNumber=@ErrorNumber OUTPUT
    , @ErrorMessage=@ErrorMessage OUTPUT;

IF @Status<>'AVAILABLE'
   OR @Rows<>2
   OR (SELECT COUNT_BIG(*) FROM [#TableOutputRuntimeContract_ExactTarget])<>2
   OR NOT EXISTS
      (
          SELECT 1
          FROM [#TableOutputRuntimeContract_ExactTarget]
          WHERE [Id]=1
            AND [Name]=N'Example A'
            AND [Amount]=CONVERT(decimal(19,4),12.3456)
      )
    INSERT [#TableOutputRuntimeContract_Failure] VALUES(N'TYPED_INSERT',N'Die synthetischen typisierten Zeilen wurden nicht unverändert in eine exakt passende Zieltabelle kopiert.');

SET @Rows=NULL;SET @Status=NULL;SET @ErrorNumber=NULL;SET @ErrorMessage=NULL;
EXEC [monitor].[InternalWriteResultTable]
      @SourceTable=N'#TableOutputRuntimeContract_Source'
    , @TargetTable=N'#TableOutputRuntimeContract_ExactTarget'
    , @InsertedRows=@Rows OUTPUT
    , @StatusCode=@Status OUTPUT
    , @ErrorNumber=@ErrorNumber OUTPUT
    , @ErrorMessage=@ErrorMessage OUTPUT;

IF @Status<>'AVAILABLE' OR @Rows<>2 OR (SELECT COUNT_BIG(*) FROM [#TableOutputRuntimeContract_ExactTarget])<>4
    INSERT [#TableOutputRuntimeContract_Failure] VALUES(N'EXACT_SCHEMA_APPEND',N'Eine bereits exakt passende Zieltabelle wurde nicht korrekt ergänzt.');

CREATE TABLE [#TableOutputRuntimeContract_NonEmptyMismatch] ([Id] bigint NOT NULL);
INSERT [#TableOutputRuntimeContract_NonEmptyMismatch] VALUES(99);
SET @Rows=NULL;SET @Status=NULL;SET @ErrorNumber=NULL;SET @ErrorMessage=NULL;
EXEC [monitor].[InternalWriteResultTable]
      @SourceTable=N'#TableOutputRuntimeContract_Source'
    , @TargetTable=N'#TableOutputRuntimeContract_NonEmptyMismatch'
    , @InsertedRows=@Rows OUTPUT
    , @StatusCode=@Status OUTPUT
    , @ErrorNumber=@ErrorNumber OUTPUT
    , @ErrorMessage=@ErrorMessage OUTPUT;

IF @Status<>'TARGET_SCHEMA_MISMATCH'
   OR (SELECT COUNT_BIG(*) FROM [#TableOutputRuntimeContract_NonEmptyMismatch])<>1
   OR EXISTS
      (
          SELECT 1
          FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
          JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
            ON [t].[object_id]=[c].[object_id]
          WHERE [t].[name] LIKE N'#TableOutputRuntimeContract_NonEmptyMismatch%'
            AND [c].[name]=N'Name'
      )
    INSERT [#TableOutputRuntimeContract_Failure] VALUES(N'SCHEMA_MISMATCH_SAFE',N'Eine gefüllte abweichende Zieltabelle wurde nicht kontrolliert und unverändert abgelehnt.');

CREATE TABLE [#TableOutputRuntimeContract_NonEmptyDummy] ([AnyTextColumn] nvarchar(12) NULL);
INSERT [#TableOutputRuntimeContract_NonEmptyDummy] VALUES(N'keep');
SET @Rows=NULL;SET @Status=NULL;SET @ErrorNumber=NULL;SET @ErrorMessage=NULL;
EXEC [monitor].[InternalWriteResultTable]
      @SourceTable=N'#TableOutputRuntimeContract_Source'
    , @TargetTable=N'#TableOutputRuntimeContract_NonEmptyDummy'
    , @InsertedRows=@Rows OUTPUT
    , @StatusCode=@Status OUTPUT
    , @ErrorNumber=@ErrorNumber OUTPUT
    , @ErrorMessage=@ErrorMessage OUTPUT;

IF @Status<>'TARGET_SCHEMA_MISMATCH'
   OR NOT EXISTS
      (
          SELECT 1
          FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
          JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
            ON [t].[object_id]=[c].[object_id]
          WHERE [t].[name] LIKE N'#TableOutputRuntimeContract_NonEmptyDummy%'
            AND [c].[name]=N'AnyTextColumn'
      )
    INSERT [#TableOutputRuntimeContract_Failure] VALUES(N'NONEMPTY_DUMMY_SAFE',N'Eine gefüllte Ein-Spalten-Tabelle wurde nicht kontrolliert und unverändert abgelehnt.');

SET @Status=NULL;SET @ErrorMessage=NULL;
EXEC [monitor].[InternalWriteResultTable]
      @SourceTable=N'#TableOutputRuntimeContract_Source'
    , @TargetTable=N'dbo.ExamplePermanentTarget'
    , @StatusCode=@Status OUTPUT
    , @ErrorMessage=@ErrorMessage OUTPUT;
IF @Status<>'INVALID_PARAMETER'
    INSERT [#TableOutputRuntimeContract_Failure] VALUES(N'LOCAL_TEMP_ONLY',N'Ein permanenter Tabellenname wurde nicht abgelehnt.');

CREATE TABLE [#TableOutputRuntimeContract_PublicTarget] ([SeedColumn] uniqueidentifier NULL);
BEGIN TRY
    EXEC [monitor].[USP_CheckAnalyseAccess]
          @ResultSetArt=' table '
        , @ResultTablesJson=N'{"access":"#TableOutputRuntimeContract_PublicTarget"}'
        , @PrintMeldungen=0;

    IF EXISTS
       (
           SELECT 1
           FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
           JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
             ON [t].[object_id]=[c].[object_id]
           WHERE [t].[name] LIKE N'#TableOutputRuntimeContract_PublicTarget%'
             AND [c].[name]=N'SeedColumn'
       )
       OR 2<>(
           SELECT COUNT(*)
           FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
           JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
             ON [t].[object_id]=[c].[object_id]
           WHERE [t].[name] LIKE N'#TableOutputRuntimeContract_PublicTarget%'
             AND [c].[name] IN (N'AnalysisClass',N'StatusCode')
       )
        INSERT [#TableOutputRuntimeContract_Failure] VALUES(N'PUBLIC_TABLE_MODE',N'Die öffentliche Procedure hat ihre primäre native Ergebnisstruktur nicht in das benannte TABLE-Ziel geschrieben.');
END TRY
BEGIN CATCH
    INSERT [#TableOutputRuntimeContract_Failure] VALUES(N'PUBLIC_TABLE_MODE',CONCAT(N'Öffentlicher TABLE-Aufruf fehlgeschlagen: ',ERROR_MESSAGE()));
END CATCH;

CREATE TABLE [#TableOutputRuntimeContract_PublicMismatch] ([WrongColumn] int NULL);
INSERT [#TableOutputRuntimeContract_PublicMismatch] VALUES(1);
BEGIN TRY
    EXEC [monitor].[USP_CheckAnalyseAccess]
          @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"access":"#TableOutputRuntimeContract_PublicMismatch"}'
        , @PrintMeldungen=0;
    INSERT [#TableOutputRuntimeContract_Failure] VALUES(N'PUBLIC_PREFLIGHT_ERROR',N'Die öffentliche Procedure hat ein gefülltes Ziel nicht im Preflight mit Fehler 51011 abgelehnt.');
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>51011
        INSERT [#TableOutputRuntimeContract_Failure] VALUES(N'PUBLIC_PREFLIGHT_ERROR',CONCAT(N'Erwartet Fehler 51011, erhalten ',ERROR_NUMBER(),N': ',ERROR_MESSAGE()));
END CATCH;

IF NOT EXISTS
   (
       SELECT 1
       FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
       JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
         ON [t].[object_id]=[c].[object_id]
       WHERE [t].[name] LIKE N'#TableOutputRuntimeContract_PublicMismatch%'
         AND [c].[name]=N'WrongColumn'
   )
   OR EXISTS
   (
       SELECT 1
       FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
       JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
         ON [t].[object_id]=[c].[object_id]
       WHERE [t].[name] LIKE N'#TableOutputRuntimeContract_PublicMismatch%'
         AND [c].[name]=N'AnalysisClass'
   )
    INSERT [#TableOutputRuntimeContract_Failure] VALUES(N'PUBLIC_SCHEMA_UNCHANGED',N'Die öffentliche Procedure hat eine abweichende Zielstruktur verändert.');

SELECT [TestName],[Detail] FROM [#TableOutputRuntimeContract_Failure] ORDER BY [TestName];
IF EXISTS(SELECT 1 FROM [#TableOutputRuntimeContract_Failure])
    THROW 54700,N'Der TABLE-Ausgabevertrag ist verletzt.',1;
GO
