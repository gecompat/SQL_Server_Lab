USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_InterpretDatabaseMailStatus
Version      : 1.0.0
Stand        : 2026-07-18
Typ          : Inline Table-valued Function
Zweck        : Klassifiziert aggregierte Database-Mail-Status ohne
               Seiteneffekte.
Datenschutz  : Verarbeitet ausschließlich den technischen Versandstatus; keine
               Adresse, Empfänger, Betreffzeile oder Nachricht.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_InterpretDatabaseMailStatus]
(
    @SentStatus varchar(8)
)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT
          [FindingCode] = CONVERT(varchar(100),
              CASE WHEN @SentStatus='failed' THEN 'DATABASE_MAIL_FAILED_IN_WINDOW'
                   WHEN @SentStatus IN ('unsent','retrying') THEN 'DATABASE_MAIL_PENDING_IN_WINDOW'
                   ELSE 'DATABASE_MAIL_STATUS_INFORMATIONAL' END)
        , [FindingSeverity] = CONVERT(varchar(16),
              CASE WHEN @SentStatus='failed' THEN 'HIGH'
                   WHEN @SentStatus IN ('unsent','retrying') THEN 'MEDIUM'
                   ELSE 'INFO' END)
);
GO
