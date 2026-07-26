USE [DeineDatenbank];
GO

/* Kataloggestützte Wait-Taxonomie mit exaktem Lookup und regelbasiertem Fallback anhand der Wait Group. */
CREATE OR ALTER FUNCTION [monitor].[TVF_WaitTypeInfo](@WaitType nvarchar(120))
RETURNS TABLE
AS
RETURN
(
    SELECT
          @WaitType AS [WaitType]
        , COALESCE([c].[WaitGroup], [f].[WaitGroup]) AS [WaitGroup]
        , COALESCE([c].[Severity], [f].[Severity]) AS [Severity]
        , COALESCE([c].[IsGenerallyBenign], [f].[IsGenerallyBenign]) AS [IsGenerallyBenign]
        , COALESCE([c].[Meaning], [f].[Meaning]) AS [Meaning]
        , COALESCE([c].[TypicalOccurrence], [f].[TypicalOccurrence]) AS [TypicalOccurrence]
        , COALESCE([c].[HighWaitImpact], [f].[HighWaitImpact]) AS [HighWaitImpact]
        , COALESCE([c].[RecommendedChecks], [f].[RecommendedChecks]) AS [RecommendedChecks]
        , COALESCE([c].[DefaultAssessment], CASE WHEN [f].[IsGenerallyBenign]=1 THEN 'EXPECTED_OR_IDLE' ELSE 'CONTEXT_DEPENDENT' END) AS [DefaultAssessment]
        , COALESCE([c].[AssessmentBasis], N'Fallback anhand der Wait Group: Erst aktiven Task, Ressource, Delta und Workloadwirkung bestätigen.') AS [AssessmentBasis]
        , COALESCE([c].[CommonCauses], [f].[TypicalOccurrence]) AS [CommonCauses]
        , COALESCE([c].[PerformanceImpact], [f].[HighWaitImpact]) AS [PerformanceImpact]
        , COALESCE([c].[Mitigation], N'Nicht den Wait Type unterdrücken; die nachgewiesene Ressourcen- oder Komponentenursache beheben.') AS [Mitigation]
        , COALESCE([c].[CounterEvidence], N'Kein aktiver Task und kein reproduzierbares Lastdelta sprechen gegen einen aktuellen Engpass.') AS [CounterEvidence]
        , [c].[RelatedWaitTypes] AS [RelatedWaitTypes]
        , COALESCE([c].[MeasurementGuidance], N'Aktive Tasks und ein belastungsbezogenes Delta gemeinsam bewerten.') AS [MeasurementGuidance]
        , COALESCE([c].[AnalysisConfidence], 'FAMILY_INFERENCE') AS [AnalysisConfidence]
        , COALESCE([c].[HelpUrl], CASE WHEN @WaitType IS NOT NULL THEN N'https://www.sqlskills.com/help/waits/' + @WaitType END) AS [HelpUrl]
        , COALESCE([c].[DescriptionSource], 'FAMILY_FALLBACK') AS [DescriptionSource]
        , COALESCE([c].[DescriptionQuality], 'GENERIC') AS [DescriptionQuality]
        , [c].[SourceReference] AS [SourceReference]
        , CONVERT(int,(SELECT COUNT_BIG(*) FROM [monitor].[WaitTypeCatalogSource] AS [src] WITH (NOLOCK) WHERE [src].[WaitType]=[c].[WaitType])) AS [SourceCount]
        , CONVERT
          (
              nvarchar(400)
            , CASE
                  WHEN [c].[WaitType] IS NOT NULL THEN N'Exakter Katalogtreffer; DescriptionQuality beachten.'
                  ELSE N'Fallback anhand der Wait Group; Detailseite und Workload-Kontext prüfen.'
              END
          ) AS [InterpretationScope]
        , CONVERT(varchar(20), CASE WHEN [c].[WaitType] IS NOT NULL THEN 'EXACT' ELSE 'FAMILY_FALLBACK' END) AS [CatalogMatchType]
    FROM (VALUES (1)) AS [v]([n])
    OUTER APPLY
    (
        SELECT TOP (1) *
        FROM [monitor].[WaitTypeCatalog] WITH (NOLOCK)
        WHERE [WaitType] = @WaitType
    ) AS [c]
    CROSS APPLY
    (
        SELECT
              CONVERT
              (
                  nvarchar(64)
                , CASE
                      WHEN @WaitType IS NULL THEN N'KEIN_WAIT'
                      WHEN @WaitType LIKE N'LCK[_]%' THEN N'LOCKING'
                      WHEN @WaitType LIKE N'PAGEIOLATCH[_]%' OR @WaitType LIKE N'IO[_]%' OR @WaitType LIKE N'%IO_COMPLETION%' THEN N'STORAGE_DATA_IO'
                      WHEN @WaitType LIKE N'WRITELOG%' OR @WaitType LIKE N'LOGBUFFER%' OR @WaitType LIKE N'LOG_RATE_GOVERNOR%' THEN N'TRANSACTION_LOG'
                      WHEN @WaitType LIKE N'PAGELATCH[_]%' THEN N'IN_MEMORY_LATCH'
                      WHEN @WaitType LIKE N'LATCH[_]%' OR @WaitType = N'CMEMTHREAD' THEN N'INTERNAL_SYNCHRONIZATION'
                      WHEN @WaitType IN (N'SOS_SCHEDULER_YIELD', N'THREADPOOL') OR @WaitType LIKE N'SOS_WORK_DISPATCHER%' THEN N'CPU_SCHEDULER'
                      WHEN @WaitType LIKE N'CX%' OR @WaitType = N'EXCHANGE' THEN N'PARALLELISM'
                      WHEN @WaitType LIKE N'RESOURCE_SEMAPHORE%' OR @WaitType LIKE N'MEMORY_ALLOCATION%' THEN N'MEMORY'
                      WHEN @WaitType LIKE N'ASYNC_NETWORK_IO%' OR @WaitType LIKE N'NET[_]%' OR @WaitType = N'NETWORK_IO' THEN N'NETWORK_CLIENT'
                      WHEN @WaitType LIKE N'HADR[_]%' OR @WaitType LIKE N'DBMIRROR[_]%' OR @WaitType LIKE N'PWAIT_HADR%' THEN N'HA_REPLICATION'
                      WHEN @WaitType LIKE N'BACKUP%' OR @WaitType LIKE N'RESTORE%' THEN N'BACKUP_RESTORE'
                      WHEN @WaitType LIKE N'QDS[_]%' OR @WaitType LIKE N'QUERY_STORE%' THEN N'QUERY_STORE'
                      WHEN @WaitType LIKE N'XTP[_]%' OR @WaitType LIKE N'WAIT_XTP%' THEN N'IN_MEMORY_OLTP'
                      WHEN @WaitType LIKE N'FT[_]%' THEN N'FULLTEXT'
                      WHEN @WaitType LIKE N'CLR[_]%' THEN N'CLR'
                      WHEN @WaitType LIKE N'PREEMPTIVE[_]%' OR @WaitType IN (N'OLEDB', N'REMOTE_QUERY', N'EXTERNAL_SCRIPT_NETWORK_IO') THEN N'EXTERNAL_OR_PREEMPTIVE'
                      WHEN @WaitType LIKE N'XE[_]%' OR @WaitType LIKE N'SQLTRACE[_]%' THEN N'TRACING_XEVENTS'
                      WHEN @WaitType LIKE N'BROKER[_]%' THEN N'SERVICE_BROKER'
                      WHEN @WaitType LIKE N'REPL[_]%' THEN N'REPLICATION'
                      WHEN @WaitType LIKE N'SLEEP%'
                        OR @WaitType IN
                           (
                               N'HADR_WORK_QUEUE', N'HADR_TIMER_TASK', N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP'
                             , N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP', N'LAZYWRITER_SLEEP'
                             , N'DIRTY_PAGE_POLL', N'REQUEST_FOR_DEADLOCK_SEARCH', N'SERVER_IDLE_CHECK'
                             , N'WAITFOR', N'ONDEMAND_TASK_QUEUE', N'RESOURCE_QUEUE'
                             , N'DISPATCHER_QUEUE_SEMAPHORE', N'LOGMGR_QUEUE', N'SP_SERVER_DIAGNOSTICS_SLEEP'
                             , N'XE_DISPATCHER_WAIT', N'XE_DISPATCHER_JOIN', N'XE_TIMER_EVENT'
                           ) THEN N'BENIGN_BACKGROUND'
                      WHEN @WaitType LIKE N'%STATISTICS%' THEN N'STATISTICS'
                      ELSE N'OTHER_OR_NEW'
                  END
              ) AS [WaitGroup]
            , CONVERT
              (
                  tinyint
                , CASE
                      WHEN @WaitType = N'THREADPOOL' THEN 5
                      WHEN @WaitType LIKE N'LCK[_]%'
                        OR @WaitType LIKE N'RESOURCE_SEMAPHORE%'
                        OR @WaitType = N'SOS_SCHEDULER_YIELD' THEN 4
                      WHEN @WaitType LIKE N'SLEEP%' THEN 0
                      ELSE 2
                  END
              ) AS [Severity]
            , CONVERT
              (
                  bit
                , CASE
                      WHEN @WaitType LIKE N'SLEEP%'
                        OR @WaitType IN
                           (
                               N'HADR_WORK_QUEUE', N'HADR_TIMER_TASK', N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP'
                             , N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP', N'LAZYWRITER_SLEEP'
                             , N'DIRTY_PAGE_POLL', N'REQUEST_FOR_DEADLOCK_SEARCH', N'SERVER_IDLE_CHECK'
                             , N'WAITFOR', N'ONDEMAND_TASK_QUEUE', N'RESOURCE_QUEUE'
                             , N'DISPATCHER_QUEUE_SEMAPHORE', N'LOGMGR_QUEUE', N'SP_SERVER_DIAGNOSTICS_SLEEP'
                             , N'XE_DISPATCHER_WAIT', N'XE_DISPATCHER_JOIN', N'XE_TIMER_EVENT'
                           ) THEN 1
                      ELSE 0
                  END
              ) AS [IsGenerallyBenign]
            , CONVERT
              (
                  nvarchar(1000)
                , CASE
                      WHEN @WaitType IS NULL THEN N'Der Request wartet aktuell nicht.'
                      WHEN @WaitType LIKE N'LCK[_]%' THEN N'Warten auf einen inkompatiblen Lock.'
                      WHEN @WaitType LIKE N'PAGEIOLATCH[_]%' THEN N'Warten auf das Lesen einer Datenseite vom Storage.'
                      WHEN @WaitType LIKE N'PAGELATCH[_]%' THEN N'In-Memory-Seitenlatch; kein physischer I/O-Wait.'
                      WHEN @WaitType LIKE N'WRITELOG%' THEN N'Warten auf dauerhaftes Schreiben ins Transaktionslog.'
                      ELSE N'Spezialisierter oder neuer Wait Type.'
                  END
              ) AS [Meaning]
            , CONVERT(nvarchar(1200), N'Auftreten anhand der zugeordneten Komponente, aktueller Tasks und Delta-Messung bewerten.') AS [TypicalOccurrence]
            , CONVERT
              (
                  nvarchar(1200)
                , CASE
                      WHEN @WaitType LIKE N'SLEEP%' THEN N'Hohe kumulative Werte sind meist erwartbar.'
                      ELSE N'Hohe Delta-Werte können Latenz oder Durchsatz beeinträchtigen.'
                  END
              ) AS [HighWaitImpact]
            , CONVERT(nvarchar(1500), N'Delta, aktive Requests, resource_description, Ausführungsplan und SQLskills-Detailseite prüfen.') AS [RecommendedChecks]
    ) AS [f]
);
GO
