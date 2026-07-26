USE [DeineDatenbank];
GO

CREATE OR ALTER FUNCTION [monitor].[TVF_QueryStoreWaitCategoryInfo](@WaitCategoryDesc nvarchar(128))
RETURNS TABLE
AS
RETURN
(
    SELECT
          CONVERT(nvarchar(64), UPPER(REPLACE(COALESCE(@WaitCategoryDesc, N'Unknown'), N' ', N'_'))) AS [WaitGroup]
        , CONVERT
          (
              nvarchar(1000)
            , CASE @WaitCategoryDesc
                  WHEN N'CPU' THEN N'CPU-Verbrauch oder Schedulerzeit während der Queryausführung.'
                  WHEN N'Worker Thread' THEN N'Warten auf verfügbare Workerthreads.'
                  WHEN N'Lock' THEN N'Warten auf inkompatible Locks.'
                  WHEN N'Latch' THEN N'Interne Synchronisationslatches.'
                  WHEN N'Buffer Latch' THEN N'Latches auf Seiten im Buffer Pool, häufig Hot-Page-Contention.'
                  WHEN N'Buffer IO' THEN N'Warten auf Daten-I/O für Seiten.'
                  WHEN N'Tran Log IO' THEN N'Warten auf Transaktionslog-I/O.'
                  WHEN N'Network IO' THEN N'Warten auf Netzwerk oder Clientabnahme.'
                  WHEN N'Parallelism' THEN N'Synchronisation paralleler Ausführungszweige.'
                  WHEN N'Memory' THEN N'Warten auf Query- oder interne Speicherressourcen.'
                  WHEN N'Other Disk IO' THEN N'Sonstiger persistenter I/O außerhalb Buffer- und Log-I/O.'
                  ELSE N'Query-Store-Wait-Kategorie für eine interne oder externe Ressource.'
              END
          ) AS [Meaning]
        , CONVERT
          (
              nvarchar(1200)
            , CASE @WaitCategoryDesc
                  WHEN N'CPU' THEN N'CPU-intensive Pläne, Scans, Sorts, Hashes oder hohe Parallelität.'
                  WHEN N'Lock' THEN N'Konkurrierende oder lange Transaktionen.'
                  WHEN N'Buffer IO' THEN N'Cache Misses, große Reads oder langsamer Storage.'
                  WHEN N'Tran Log IO' THEN N'Commit-intensive Workloads oder langsames Log-I/O.'
                  WHEN N'Memory' THEN N'Große Memory Grants oder viele konkurrierende Queries.'
                  ELSE N'Abhängig von Plan, Workload und betroffener Ressource.'
              END
          ) AS [TypicalOccurrence]
        , CONVERT
          (
              nvarchar(1200)
            , CASE @WaitCategoryDesc
                  WHEN N'CPU' THEN N'Durchsatz und Antwortzeit werden durch CPU limitiert.'
                  WHEN N'Worker Thread' THEN N'Queries können verzögert starten oder die Instanz wirkt blockiert.'
                  WHEN N'Lock' THEN N'Blocking, Timeouts und lange Antwortzeiten.'
                  WHEN N'Buffer IO' THEN N'Queries warten auf Seiten vom Storage.'
                  WHEN N'Tran Log IO' THEN N'Commit-Latenz und Schreibdurchsatz verschlechtern sich.'
                  ELSE N'Hohe Werte zeigen einen relevanten Stall-Punkt der Queryausführung; mit Runtime Stats und Plan korrelieren.'
              END
          ) AS [HighWaitImpact]
        , CONVERT
          (
              nvarchar(1500)
            , CASE @WaitCategoryDesc
                  WHEN N'CPU' THEN N'Top CPU Queries, Pläne, Scheduler und Parallelität prüfen.'
                  WHEN N'Lock' THEN N'Blocking, offene Transaktionen, Indizes und Isolation prüfen.'
                  WHEN N'Buffer IO' THEN N'File-Latenz, Reads, Scans, Buffer Pool und Indizes prüfen.'
                  WHEN N'Tran Log IO' THEN N'Log-Latenz, Growth, Commit-Rate und AG-Pfad prüfen.'
                  WHEN N'Memory' THEN N'Memory Grants, Cardinality und Sort-/Hash-Operatoren prüfen.'
                  ELSE N'Query Store Runtime Stats, Planwechsel und betroffene Query/Plan-Kombination prüfen.'
              END
          ) AS [RecommendedChecks]
);
GO
