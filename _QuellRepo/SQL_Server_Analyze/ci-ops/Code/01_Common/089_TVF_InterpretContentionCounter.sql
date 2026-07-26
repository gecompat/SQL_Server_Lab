USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_InterpretContentionCounter
Zweck        : Stellt den Rechenvertrag für monotone Latch-/Spinlockzähler
               ohne Seiteneffekte bereit.
Datenschutz  : Verarbeitet ausschließlich übergebene technische Zahlenwerte.
Grenzen      : Ein fallender Wert kennzeichnet einen Reset; die betroffene
               Differenz und Rate bleiben NULL.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_InterpretContentionCounter]
(
      @BeforeValue            bigint
    , @AfterValue             bigint
    , @RequestedSampleSeconds tinyint
    , @ActualSampleSeconds    decimal(19,6)
)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT
          CASE
              WHEN @RequestedSampleSeconds=0 THEN @AfterValue
              WHEN @AfterValue>=@BeforeValue THEN @AfterValue-@BeforeValue
          END AS [CounterValue]
        , CASE
              WHEN @RequestedSampleSeconds>0 AND @AfterValue>=@BeforeValue
              THEN CONVERT(decimal(19,4),
                   1.0*(@AfterValue-@BeforeValue)/NULLIF(@ActualSampleSeconds,0))
          END AS [RatePerSecond]
        , CONVERT(bit,CASE
              WHEN @RequestedSampleSeconds>0 AND @AfterValue<@BeforeValue THEN 1
              ELSE 0
          END) AS [CounterResetDetected]
);
GO
