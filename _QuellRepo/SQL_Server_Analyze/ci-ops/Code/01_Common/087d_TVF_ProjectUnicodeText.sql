USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_ProjectUnicodeText
Version      : 1.0.0
Stand        : 2026-07-21
Typ          : Inline Table-Valued Function
Zweck        : Projiziert einen bereits materialisierten Unicode-MAX-Wert mit
               messbarer, aufhebbarer und Surrogate-sicherer Begrenzung.
Semantik     : NULL oder 0 als Grenze bedeutet unbegrenzt; negative Grenzen
               validiert die aufrufende Procedure vor Verwendung der Funktion.
Unicode      : Latin1_General_100_CI_AS_SC zählt und schneidet UTF-16-
               Surrogate-Paare als ein Zeichen. Ein angehängtes Nicht-Leerzeichen
               sorgt dafür, dass abschließende Leerzeichen mitgezählt werden.
Nebenwirkung : Keine. Die Funktion liest keine System- oder Benutzerdaten.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_ProjectUnicodeText]
(
      @Value         nvarchar(max)
    , @MaxCharacters int
)
RETURNS TABLE
AS
RETURN
(
    SELECT
          [OriginalCharacters] =
              CASE WHEN @Value IS NULL THEN CONVERT(bigint,NULL)
                   ELSE [m].[CharacterCount] END
        , [OriginalBytes] = CONVERT(bigint,DATALENGTH(@Value))
        , [IsTruncated] = CONVERT
          (
              bit,
              CASE WHEN @Value IS NOT NULL
                         AND @MaxCharacters IS NOT NULL
                         AND @MaxCharacters > 0
                         AND [m].[CharacterCount] > @MaxCharacters
                   THEN 1 ELSE 0 END
          )
        , [ProjectedValue] = CONVERT
          (
              nvarchar(max),
              CASE WHEN @Value IS NULL THEN NULL
                   WHEN @MaxCharacters IS NULL OR @MaxCharacters = 0 THEN @Value
                   WHEN [m].[CharacterCount] <= @MaxCharacters THEN @Value
                   ELSE LEFT(@Value COLLATE Latin1_General_100_CI_AS_SC,@MaxCharacters)
              END
          )
    FROM
    (
        SELECT [CharacterCount] = CONVERT
        (
            bigint,
            LEN((@Value + NCHAR(1)) COLLATE Latin1_General_100_CI_AS_SC) - 1
        )
    ) AS [m]
);
GO
