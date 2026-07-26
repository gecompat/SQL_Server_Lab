USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_InterpretAvailabilityDatabaseState
Version      : 1.0.0
Stand        : 2026-07-18
Typ          : Inline Table-valued Function
Zweck        : Klassifiziert den Zustand einer AG-Datenbank ohne Seiteneffekte.
Datenschutz  : Verarbeitet ausschließlich übergebene technische Status- und
               Zählerwerte; keine Namen, Texte oder Umgebungswerte.
Grenzen      : Momentaufnahme. Queue- und Lag-Grenzen sind Sichtungswerte und
               beweisen weder Ursache noch zukünftige Catch-up-Zeit.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_InterpretAvailabilityDatabaseState]
(
      @IsSuspended                  bit
    , @SynchronizationHealthDesc    nvarchar(60)
    , @SynchronizationStateDesc     nvarchar(60)
    , @LogSendQueueSizeKb           bigint
    , @RedoQueueSizeKb              bigint
    , @SecondaryLagSeconds          bigint
    , @QueueWarnMb                  bigint
    , @SecondaryLagWarnSeconds      int
)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT
          [FindingCode] = CONVERT(varchar(100),
              CASE WHEN @IsSuspended = 1 THEN 'DATA_MOVEMENT_SUSPENDED'
                   WHEN @SynchronizationHealthDesc = N'NOT_HEALTHY' THEN 'DATABASE_NOT_HEALTHY'
                   WHEN @SynchronizationStateDesc = N'NOT_SYNCHRONIZING' THEN 'DATABASE_NOT_SYNCHRONIZING'
                   WHEN CONVERT(decimal(38,0),COALESCE(@LogSendQueueSizeKb,0)) >= CONVERT(decimal(38,0),@QueueWarnMb)*1024 THEN 'LOG_SEND_QUEUE_THRESHOLD'
                   WHEN CONVERT(decimal(38,0),COALESCE(@RedoQueueSizeKb,0)) >= CONVERT(decimal(38,0),@QueueWarnMb)*1024 THEN 'REDO_QUEUE_THRESHOLD'
                   WHEN COALESCE(@SecondaryLagSeconds,0) >= @SecondaryLagWarnSeconds THEN 'SECONDARY_LAG_THRESHOLD'
                   ELSE 'DATABASE_STATE_ACCEPTABLE' END)
        , [FindingSeverity] = CONVERT(varchar(16),
              CASE WHEN @IsSuspended = 1
                         OR @SynchronizationHealthDesc = N'NOT_HEALTHY'
                         OR @SynchronizationStateDesc = N'NOT_SYNCHRONIZING' THEN 'HIGH'
                   WHEN CONVERT(decimal(38,0),COALESCE(@LogSendQueueSizeKb,0)) >= CONVERT(decimal(38,0),@QueueWarnMb)*1024
                         OR CONVERT(decimal(38,0),COALESCE(@RedoQueueSizeKb,0)) >= CONVERT(decimal(38,0),@QueueWarnMb)*1024
                         OR COALESCE(@SecondaryLagSeconds,0) >= @SecondaryLagWarnSeconds THEN 'MEDIUM'
                   ELSE 'INFO' END)
);
GO
