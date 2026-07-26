USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_InterpretAgentJobState
Version      : 1.0.0
Stand        : 2026-07-18
Typ          : Inline Table-valued Function
Zweck        : Klassifiziert den letzten Jobstatus und die zugehörigen
               Zeitpläne ohne Seiteneffekte.
Datenschutz  : Verarbeitet nur technische Status-, Zeit- und Anzahlwerte; keine
               Jobschritte, Befehle oder Meldungstexte.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_InterpretAgentJobState]
(
      @IsEnabled             tinyint
    , @LatestRunStatus       int
    , @LatestRunDateTime     datetime
    , @CutoffLocal           datetime
    , @ScheduleCount         bigint
    , @EnabledScheduleCount  bigint
)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT
          [FindingCode] = CONVERT(varchar(100),
              CASE WHEN @IsEnabled=1 AND @LatestRunStatus=0
                         AND @LatestRunDateTime>=@CutoffLocal THEN 'LATEST_JOB_RUN_FAILED_IN_WINDOW'
                   WHEN @IsEnabled=1 AND COALESCE(@ScheduleCount,0)>0
                         AND COALESCE(@EnabledScheduleCount,0)=0 THEN 'ALL_ATTACHED_SCHEDULES_DISABLED'
                   WHEN @IsEnabled=1 AND COALESCE(@ScheduleCount,0)=0 THEN 'ENABLED_JOB_WITHOUT_SCHEDULE'
                   ELSE 'JOB_STATE_INFORMATIONAL' END)
        , [FindingSeverity] = CONVERT(varchar(16),
              CASE WHEN @IsEnabled=1 AND @LatestRunStatus=0
                         AND @LatestRunDateTime>=@CutoffLocal THEN 'HIGH'
                   WHEN @IsEnabled=1 AND COALESCE(@ScheduleCount,0)>0
                         AND COALESCE(@EnabledScheduleCount,0)=0 THEN 'MEDIUM'
                   ELSE 'INFO' END)
);
GO
