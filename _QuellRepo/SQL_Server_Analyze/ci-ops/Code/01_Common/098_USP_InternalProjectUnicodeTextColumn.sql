USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.InternalProjectUnicodeTextColumn
Version      : 1.0.0
Stand        : 2026-07-21
Typ          : Interne Stored Procedure
Zweck        : Projiziert eine bereits materialisierte nvarchar(max)-Spalte
               Unicode-sicher und befüllt deren Längen-/Kürzungsmetadaten.
Grenze       : Liest ausschließlich die übergebene lokale Temp-Tabelle; kein
               erneuter Zugriff auf die fachliche Systemquelle.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[InternalProjectUnicodeTextColumn]
      @SourceTable               sysname
    , @TextColumn                sysname
    , @CharactersColumn          sysname
    , @BytesColumn               sysname
    , @IsTruncatedColumn         sysname
    , @MaxCharacters             int
    , @TruncatedValueCount       bigint OUTPUT
    , @LargestRequiredCharacters bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;

    IF @SourceTable IS NULL OR LEFT(@SourceTable,1)<>N'#'
       OR LEFT(@SourceTable,2)=N'##'
       OR @TextColumn IS NULL OR @CharactersColumn IS NULL
       OR @BytesColumn IS NULL OR @IsTruncatedColumn IS NULL
       OR @MaxCharacters<0
        THROW 51021,N'InternalProjectUnicodeTextColumn benötigt eine lokale Temp-Tabelle, gültige Spalten und einen nichtnegativen Grenzwert.',1;

    DECLARE @Sql nvarchar(max)=N'
UPDATE [source]
SET '+QUOTENAME(@CharactersColumn)+N'=[projection].[OriginalCharacters],
    '+QUOTENAME(@BytesColumn)+N'=[projection].[OriginalBytes],
    '+QUOTENAME(@IsTruncatedColumn)+N'=[projection].[IsTruncated],
    '+QUOTENAME(@TextColumn)+N'=[projection].[ProjectedValue]
FROM '+QUOTENAME(@SourceTable)+N' AS [source]
CROSS APPLY [monitor].[TVF_ProjectUnicodeText]([source].'+QUOTENAME(@TextColumn)+N',@Limit) AS [projection];

SELECT @Count=COUNT_BIG(*),@Largest=MAX('+QUOTENAME(@CharactersColumn)+N')
FROM '+QUOTENAME(@SourceTable)+N'
WHERE '+QUOTENAME(@IsTruncatedColumn)+N'=1;';

    SET @TruncatedValueCount=0;
    SET @LargestRequiredCharacters=NULL;
    EXEC [sys].[sp_executesql]
          @Sql
        , N'@Limit int,@Count bigint OUTPUT,@Largest bigint OUTPUT'
        , @Limit=@MaxCharacters
        , @Count=@TruncatedValueCount OUTPUT
        , @Largest=@LargestRequiredCharacters OUTPUT;
END;
GO
