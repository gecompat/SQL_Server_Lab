USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_InterpretAgentAlertRoute
Version      : 1.0.0
Stand        : 2026-07-18
Typ          : Inline Table-valued Function
Zweck        : Klassifiziert die Aktion eines Agent-Alerts ohne Seiteneffekte.
Datenschutz  : Verarbeitet nur Schalter und aggregierte Anzahl; keine Operator-
               oder Empfängerdaten.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_InterpretAgentAlertRoute]
(
      @IsEnabled          bit
    , @HasJobAction       bit
    , @NotificationCount  bigint
)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT
          [FindingCode] = CONVERT(varchar(100),
              CASE WHEN @IsEnabled=1 AND COALESCE(@HasJobAction,0)=0
                         AND COALESCE(@NotificationCount,0)=0 THEN 'ENABLED_ALERT_WITHOUT_ACTION'
                   WHEN @IsEnabled=0 THEN 'ALERT_DISABLED'
                   ELSE 'ALERT_ROUTE_PRESENT' END)
        , [FindingSeverity] = CONVERT(varchar(16),
              CASE WHEN @IsEnabled=1 AND COALESCE(@HasJobAction,0)=0
                         AND COALESCE(@NotificationCount,0)=0 THEN 'HIGH'
                   ELSE 'INFO' END)
);
GO
