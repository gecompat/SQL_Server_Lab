USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_StatementText
Version      : 1.0.0
Stand        : 2026-07-16
Typ          : Inline Table-valued Function
Zweck        : Ermittelt aus einem SQL-Batch und den Byte-Offsets eines Requests
               das exakt laufende Statement sowie transparente Zeichen- und
               Zeilenpositionen.
Hinweis      : statement_start_offset und statement_end_offset sind Byte-
               Positionen innerhalb eines nvarchar-Texts. NULL bedeutet, dass
               kein Statement-Offset verfügbar ist; -1 beim Ende bedeutet das
               Ende des Batches beziehungsweise persistenten Moduls.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_StatementText]
(
      @BatchText                  nvarchar(max)
    , @StatementStartOffsetBytes  int
    , @StatementEndOffsetBytes    int
)
RETURNS TABLE
AS
RETURN
(
    WITH [Normalized] AS
    (
        SELECT
              [BatchText] = @BatchText
            , [BatchLengthBytes] = DATALENGTH(@BatchText)
            , [HasOffsets] = CONVERT(bit, CASE WHEN @StatementStartOffsetBytes IS NULL THEN 0 ELSE 1 END)
            , [StartOffsetBytes] =
                CASE
                    WHEN @BatchText IS NULL THEN NULL
                    WHEN @StatementStartOffsetBytes IS NULL THEN 0
                    ELSE @StatementStartOffsetBytes
                END
            , [EndOffsetBytes] =
                CASE
                    WHEN @BatchText IS NULL THEN NULL
                    WHEN @StatementEndOffsetBytes IS NULL OR @StatementEndOffsetBytes = -1
                        THEN DATALENGTH(@BatchText)
                    ELSE @StatementEndOffsetBytes
                END
    ),
    [Validated] AS
    (
        SELECT
              [BatchText]
            , [BatchLengthBytes]
            , [HasOffsets]
            , [StartOffsetBytes]
            , [EndOffsetBytes]
            , [IsOffsetValid] = CONVERT
              (
                  bit,
                  CASE
                      WHEN [BatchText] IS NULL THEN 0
                      WHEN [StartOffsetBytes] IS NULL OR [EndOffsetBytes] IS NULL THEN 0
                      WHEN [StartOffsetBytes] < 0 OR [EndOffsetBytes] < 0 THEN 0
                      WHEN [StartOffsetBytes] > [EndOffsetBytes] THEN 0
                      WHEN [StartOffsetBytes] > [BatchLengthBytes] THEN 0
                      WHEN [EndOffsetBytes] > [BatchLengthBytes] THEN 0
                      WHEN [StartOffsetBytes] % 2 <> 0 OR [EndOffsetBytes] % 2 <> 0 THEN 0
                      ELSE 1
                  END
              )
        FROM [Normalized]
    ),
    [Extracted] AS
    (
        SELECT
              [BatchText]
            , [BatchLengthBytes]
            , [HasOffsets]
            , [StartOffsetBytes]
            , [EndOffsetBytes]
            , [IsOffsetValid]
            , [StatementText] =
                CASE
                    WHEN [BatchText] IS NULL THEN NULL
                    WHEN [IsOffsetValid] = 0 THEN NULL
                    ELSE SUBSTRING
                    (
                          [BatchText]
                        , ([StartOffsetBytes] / 2) + 1
                        , (([EndOffsetBytes] - [StartOffsetBytes]) / 2) + 1
                    )
                END
        FROM [Validated]
    ),
    [Measured] AS
    (
        SELECT
              [BatchText]
            , [BatchLengthBytes]
            , [HasOffsets]
            , [StartOffsetBytes]
            , [EndOffsetBytes]
            , [IsOffsetValid]
            , [StatementText]
            , [StatementLengthBytes] = DATALENGTH([StatementText])
            , [StatementStartCharacter] =
                CASE WHEN [IsOffsetValid] = 1 THEN ([StartOffsetBytes] / 2) + 1 END
            , [StatementStartLine] =
                CASE
                    WHEN [IsOffsetValid] = 0 THEN NULL
                    ELSE 1
                       + LEN(LEFT([BatchText], [StartOffsetBytes] / 2))
                       - LEN(REPLACE(LEFT([BatchText], [StartOffsetBytes] / 2), NCHAR(10), N''))
                END
        FROM [Extracted]
    )
    SELECT
          [HasStatementOffsets] = [HasOffsets]
        , [IsStatementOffsetValid] = [IsOffsetValid]
        , [StatementStartOffsetBytes] = CASE WHEN [HasOffsets] = 1 THEN [StartOffsetBytes] END
        , [StatementEndOffsetBytes] =
            CASE
                WHEN [HasOffsets] = 0 THEN NULL
                WHEN @StatementEndOffsetBytes IS NULL OR @StatementEndOffsetBytes = -1 THEN -1
                ELSE [EndOffsetBytes]
            END
        , [StatementStartCharacter]
        , [StatementEndCharacter] =
            CASE
                WHEN [StatementLengthBytes] IS NULL OR [StatementLengthBytes] = 0 THEN NULL
                ELSE [StatementStartCharacter] + ([StatementLengthBytes] / 2) - 1
            END
        , [StatementStartLine]
        , [StatementEndLine] =
            CASE
                WHEN [StatementText] IS NULL THEN NULL
                ELSE [StatementStartLine]
                   + LEN([StatementText])
                   - LEN(REPLACE([StatementText], NCHAR(10), N''))
            END
        , [StatementCharacterCount] = CASE WHEN [StatementLengthBytes] IS NULL THEN NULL ELSE [StatementLengthBytes] / 2 END
        , [BatchCharacterCount] = CASE WHEN [BatchLengthBytes] IS NULL THEN NULL ELSE [BatchLengthBytes] / 2 END
        , [StatementText]
    FROM [Measured]
);
GO
