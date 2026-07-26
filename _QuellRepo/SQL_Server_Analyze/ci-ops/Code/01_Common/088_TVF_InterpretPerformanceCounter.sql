USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_InterpretPerformanceCounter
Version      : 1.0.0
Stand        : 2026-07-18
Zweck        : Interpretiert ein Performance-Counter-Paar deterministisch und
               ohne Seiteneffekte einschließlich Reset- und
               Basiscountervertrag.
Grenzen      : Keine DMV-Abfrage, keine Persistenz und keine Alarmgrenzen.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_InterpretPerformanceCounter]
(
      @CounterType      int
    , @BeforeValue      bigint
    , @AfterValue       bigint
    , @BaseBeforeValue  bigint
    , @BaseAfterValue   bigint
    , @SampleSeconds    decimal(19,6)
)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT
          CASE
              WHEN @CounterType = 65792 THEN 'RAW_SNAPSHOT'
              WHEN @CounterType IN (272696320, 272696576) THEN 'RATE_PER_SECOND'
              WHEN @CounterType = 537003264 THEN 'FRACTION_DELTA_PERCENT'
              WHEN @CounterType = 1073874176 THEN 'AVERAGE_DELTA_RATIO'
              ELSE 'RAW_UNINTERPRETED'
          END AS [Interpretation]
        , CONVERT(decimal(38,6),
          CASE
              WHEN @CounterType = 65792
                  THEN CONVERT(decimal(38,6), @AfterValue)
              WHEN @CounterType IN (272696320, 272696576)
               AND @SampleSeconds > 0
               AND @AfterValue >= @BeforeValue
                  THEN (CONVERT(decimal(38,6), @AfterValue)
                       -CONVERT(decimal(38,6), @BeforeValue)) / NULLIF(@SampleSeconds, 0)
              WHEN @CounterType = 537003264
               AND @SampleSeconds > 0
               AND @AfterValue >= @BeforeValue
               AND @BaseAfterValue > @BaseBeforeValue
                  THEN 100.0 * (CONVERT(decimal(38,6), @AfterValue)
                               -CONVERT(decimal(38,6), @BeforeValue))
                       / NULLIF(CONVERT(decimal(38,6), @BaseAfterValue)
                               -CONVERT(decimal(38,6), @BaseBeforeValue), 0)
              WHEN @CounterType = 1073874176
               AND @SampleSeconds > 0
               AND @AfterValue >= @BeforeValue
               AND @BaseAfterValue > @BaseBeforeValue
                  THEN (CONVERT(decimal(38,6), @AfterValue)
                       -CONVERT(decimal(38,6), @BeforeValue))
                       / NULLIF(CONVERT(decimal(38,6), @BaseAfterValue)
                               -CONVERT(decimal(38,6), @BaseBeforeValue), 0)
              WHEN @CounterType IN (272696320, 272696576, 537003264, 1073874176)
                  THEN NULL
              ELSE CONVERT(decimal(38,6), @AfterValue)
          END) AS [MetricValue]
        , CASE
              WHEN @CounterType IN (272696320, 272696576) THEN 'PER_SECOND'
              WHEN @CounterType = 537003264 THEN 'PERCENT'
              WHEN @CounterType = 1073874176 THEN 'AVERAGE'
              WHEN @CounterType = 65792 THEN 'RAW_VALUE'
              ELSE 'RAW_UNINTERPRETED'
          END AS [MetricUnit]
        , CASE
              WHEN @CounterType IN (272696320, 272696576, 537003264, 1073874176)
               AND COALESCE(@SampleSeconds, 0) <= 0 THEN 'SAMPLE_REQUIRED_FOR_DELTA_METRIC'
              WHEN @CounterType IN (272696320, 272696576, 537003264, 1073874176)
               AND @AfterValue < @BeforeValue THEN 'COUNTER_RESET_DURING_SAMPLE'
              WHEN @CounterType IN (537003264, 1073874176)
               AND (@BaseBeforeValue IS NULL OR @BaseAfterValue IS NULL) THEN 'BASE_COUNTER_MISSING'
              WHEN @CounterType IN (537003264, 1073874176)
               AND @BaseAfterValue < @BaseBeforeValue THEN 'BASE_COUNTER_RESET_DURING_SAMPLE'
              WHEN @CounterType IN (537003264, 1073874176)
               AND @BaseAfterValue = @BaseBeforeValue THEN 'BASE_COUNTER_DELTA_ZERO'
              WHEN @CounterType NOT IN
                   (65792, 272696320, 272696576, 537003264, 1073874176)
                  THEN 'COUNTER_TYPE_NOT_AUTOMATICALLY_INTERPRETED'
              ELSE 'VALUE_AVAILABLE'
          END AS [FindingCode]
);
GO
