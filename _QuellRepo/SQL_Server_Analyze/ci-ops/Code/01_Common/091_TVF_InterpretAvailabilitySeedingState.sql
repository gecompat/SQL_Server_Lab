USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_InterpretAvailabilitySeedingState
Version      : 1.0.0
Stand        : 2026-07-18
Typ          : Inline Table-valued Function
Zweck        : Berechnet und klassifiziert den Zustand eines physischen
               Seedings ohne Seiteneffekte.
Datenschutz  : Verarbeitet ausschließlich übergebene technische Zahlen- und
               Zeitwerte; freie Fehlermeldungen werden nicht benötigt.
Grenzen      : Fortschritt basiert auf sichtbaren Bytezählern. Kompression,
               Momentaufnahme und aktuelle Transferrate begrenzen die Aussage.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_InterpretAvailabilitySeedingState]
(
      @FailureCode                   int
    , @TransferredSizeBytes          bigint
    , @DatabaseSizeBytes             bigint
    , @TransferRateBytesPerSecond    bigint
    , @EndTimeUtc                    datetime
)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT
          [ProgressPercent] = CONVERT(decimal(9,4),
              CASE WHEN COALESCE(@DatabaseSizeBytes,0) <= 0 THEN NULL
                   WHEN COALESCE(@TransferredSizeBytes,0) <= 0 THEN 0
                   WHEN @TransferredSizeBytes >= @DatabaseSizeBytes THEN 100
                   ELSE CONVERT(decimal(38,6),@TransferredSizeBytes)*100.0
                        /NULLIF(CONVERT(decimal(38,6),@DatabaseSizeBytes),0) END)
        , [RemainingBytes] = CONVERT(bigint,
              CASE WHEN COALESCE(@DatabaseSizeBytes,0) <= COALESCE(@TransferredSizeBytes,0) THEN 0
                   ELSE @DatabaseSizeBytes-COALESCE(@TransferredSizeBytes,0) END)
        , [FindingCode] = CONVERT(varchar(100),
              CASE WHEN COALESCE(@FailureCode,0) <> 0 THEN 'SEEDING_FAILED'
                   WHEN @EndTimeUtc IS NOT NULL
                        AND COALESCE(@TransferredSizeBytes,0) >= COALESCE(@DatabaseSizeBytes,0) THEN 'SEEDING_COMPLETED'
                   WHEN @EndTimeUtc IS NULL
                        AND COALESCE(@DatabaseSizeBytes,0) > COALESCE(@TransferredSizeBytes,0)
                        AND COALESCE(@TransferRateBytesPerSecond,0) = 0 THEN 'SEEDING_NO_CURRENT_THROUGHPUT'
                   WHEN @EndTimeUtc IS NULL THEN 'SEEDING_IN_PROGRESS'
                   ELSE 'SEEDING_STATE_REVIEW' END)
        , [FindingSeverity] = CONVERT(varchar(16),
              CASE WHEN COALESCE(@FailureCode,0) <> 0 THEN 'HIGH'
                   WHEN @EndTimeUtc IS NULL
                        AND COALESCE(@DatabaseSizeBytes,0) > COALESCE(@TransferredSizeBytes,0)
                        AND COALESCE(@TransferRateBytesPerSecond,0) = 0 THEN 'MEDIUM'
                   WHEN @EndTimeUtc IS NOT NULL
                        AND COALESCE(@TransferredSizeBytes,0) < COALESCE(@DatabaseSizeBytes,0) THEN 'MEDIUM'
                   ELSE 'INFO' END)
);
GO
