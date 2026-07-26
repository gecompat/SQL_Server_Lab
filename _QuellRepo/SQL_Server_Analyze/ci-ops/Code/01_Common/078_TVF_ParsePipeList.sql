USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_ParsePipeList
Version      : 1.1.0
Stand        : 2026-07-15
Typ          : Multi-statement Table-valued Function
Zweck        : Zerlegt eine Pipe-Liste. Das Zeichen | trennt ausschließlich
               außerhalb bracket-quotierter Bereiche. Innerhalb von [...] ist
               | Bestandteil des Werts; ]] maskiert eine schließende Klammer.
SQL-Version  : SQL Server 2019 oder neuer.
Parameter    : @List nvarchar(max).
Resultset    : ItemOrdinal, ItemText, IsBracketQuoted, IsValid, ErrorCode,
               ErrorMessage.
Collation    : Werte werden unter SQL_Latin1_General_CP1_CS_AS zurückgegeben.
Hinweis      : Die Funktion validiert die Listenstruktur. Die fachliche Prüfung
               als sysname, Zahl, Hash oder Multipart-Identifier erfolgt beim
               jeweiligen Verbraucher.
Beispiele    : SELECT * FROM monitor.TVF_ParsePipeList(N'dbo|monitor');
               SELECT * FROM monitor.TVF_ParsePipeList(
                   N'[Das ist | ein komischer Objektname]|[der auch]|der_auch');
Änderungen   : 1.1.0 - Nicht maskierte schließende Klammern, leere Elemente und
                         überlange Listenelemente werden zuverlässig erkannt.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_ParsePipeList]
(
    @List nvarchar(max)
)
RETURNS @Items TABLE
(
      [ItemOrdinal]      int             NOT NULL
    , [ItemText]         nvarchar(4000)  COLLATE SQL_Latin1_General_CP1_CS_AS NULL
    , [IsBracketQuoted]  bit             NOT NULL
    , [IsValid]          bit             NOT NULL
    , [ErrorCode]        varchar(40)     COLLATE SQL_Latin1_General_CP1_CS_AS NULL
    , [ErrorMessage]     nvarchar(4000)  COLLATE SQL_Latin1_General_CP1_CS_AS NULL
)
AS
BEGIN
    IF @List IS NULL
        RETURN;

    DECLARE @Length int = DATALENGTH(@List) / 2;
    DECLARE @Position int = 1;
    DECLARE @StartPosition int = 1;
    DECLARE @ItemOrdinal int = 0;
    DECLARE @InBracket bit = 0;
    DECLARE @ItemHasSyntaxError bit = 0;
    DECLARE @Character nchar(1);
    DECLARE @NextCharacter nchar(1);

    IF @Length = 0
    BEGIN
        INSERT @Items
        (
              [ItemOrdinal], [ItemText], [IsBracketQuoted], [IsValid]
            , [ErrorCode], [ErrorMessage]
        )
        VALUES
        (
              1, N'', 0, 0
            , 'EMPTY_LIST', N'Die Liste darf nicht leer sein.'
        );
        RETURN;
    END;

    WHILE @Position <= @Length + 1
    BEGIN
        SET @Character = CASE WHEN @Position <= @Length
                              THEN SUBSTRING(@List, @Position, 1)
                         END;
        SET @NextCharacter = CASE WHEN @Position < @Length
                                  THEN SUBSTRING(@List, @Position + 1, 1)
                             END;

        IF @Position <= @Length AND @InBracket = 1
        BEGIN
            IF @Character = N']'
            BEGIN
                IF @NextCharacter = N']'
                    SET @Position += 1;
                ELSE
                    SET @InBracket = 0;
            END;
        END
        ELSE IF @Position <= @Length AND @Character = N'['
        BEGIN
            SET @InBracket = 1;
        END
        ELSE IF @Position <= @Length AND @Character = N']'
        BEGIN
            SET @ItemHasSyntaxError = 1;
        END
        ELSE IF @Position = @Length + 1 OR @Character = N'|'
        BEGIN
            DECLARE @RawLength int = @Position - @StartPosition;
            DECLARE @RawItem nvarchar(4000) =
                CASE WHEN @RawLength <= 4000
                     THEN CONVERT(nvarchar(4000), SUBSTRING(@List, @StartPosition, @RawLength))
                END;
            DECLARE @ItemText nvarchar(4000) = LTRIM(RTRIM(@RawItem));
            DECLARE @IsBracketQuoted bit = CONVERT
            (
                bit,
                CASE WHEN @ItemText IS NOT NULL
                           AND LEFT(@ItemText, 1) = N'['
                           AND RIGHT(@ItemText, 1) = N']'
                     THEN 1 ELSE 0 END
            );
            DECLARE @ErrorCode varchar(40) =
                CASE WHEN @RawLength > 4000 THEN 'ITEM_TOO_LONG'
                     WHEN @ItemText = N'' THEN 'EMPTY_ITEM'
                     WHEN @ItemHasSyntaxError = 1 OR @InBracket = 1 THEN 'INVALID_BRACKET_SYNTAX'
                END;

            SET @ItemOrdinal += 1;

            INSERT @Items
            (
                  [ItemOrdinal], [ItemText], [IsBracketQuoted], [IsValid]
                , [ErrorCode], [ErrorMessage]
            )
            VALUES
            (
                  @ItemOrdinal
                , @ItemText
                , @IsBracketQuoted
                , CONVERT(bit, CASE WHEN @ErrorCode IS NULL THEN 1 ELSE 0 END)
                , @ErrorCode
                , CASE @ErrorCode
                      WHEN 'ITEM_TOO_LONG' THEN N'Ein Listenelement darf höchstens 4000 Zeichen enthalten.'
                      WHEN 'EMPTY_ITEM' THEN N'Ein Listenelement darf nicht leer sein.'
                      WHEN 'INVALID_BRACKET_SYNTAX' THEN N'Die bracket-quotierte Schreibweise ist syntaktisch ungültig oder nicht abgeschlossen.'
                  END
            );

            SET @StartPosition = @Position + 1;
            SET @ItemHasSyntaxError = 0;
        END;

        SET @Position += 1;
    END;

    RETURN;
END;
GO
