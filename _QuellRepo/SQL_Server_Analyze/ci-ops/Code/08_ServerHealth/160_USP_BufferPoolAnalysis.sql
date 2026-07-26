USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_BufferPoolAnalysis
Version      : 1.0.0
Stand        : 2026-07-17
Zweck        : Liefert eine korrelierte Momentaufnahme von Prozess-,
               Betriebssystem-, Resource-Semaphore-, Memory-Clerk- und
               Buffer-Pool-Evidenz.
Datenquellen : sys.dm_os_process_memory, sys.dm_os_sys_memory,
               sys.dm_exec_query_resource_semaphores,
               sys.dm_os_memory_clerks und optional sys.dm_os_buffer_descriptors.
Kosten       : Basis LOW; Buffer-Pool-Verteilung kann auf großen Instanzen HIGH
               sein und ist deshalb standardmäßig deaktiviert.
Grenzen      : Eine Momentaufnahme beweist keinen Trend und berechnet keine
               automatische max-server-memory-Empfehlung.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_BufferPoolAnalysis]
      @MitMemoryClerks          bit            = 1
    , @MitBufferPoolVerteilung  bit            = 0
    , @MaxZeilen                int            = 100
    , @ResultSetArt             varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen             bit            = 0
    , @Json                     nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen           bit            = 1
    , @Hilfe                    bit            = 0
    , @StatusCodeOut            varchar(40)    = NULL OUTPUT
    , @IsPartialOut             bit            = NULL OUTPUT
    , @ErrorNumberOut           int            = NULL OUTPUT
    , @ErrorMessageOut          nvarchar(2048) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;
    SET @Json = NULL;

    DECLARE @OutputMode varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @OutputMode = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @OutputMode = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'memory',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Limit bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0
                                 THEN CONVERT(bigint, 9223372036854775807)
                                 ELSE CONVERT(bigint, @MaxZeilen) END;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_BufferPoolAnalysis';
        PRINT N'Die Procedure liefert eine korrelierte Momentaufnahme, aber keine Trend- oder Konfigurationsempfehlung.';
        PRINT N'@MitBufferPoolVerteilung=0 ist der sichere Standard; 1 scannt sys.dm_os_buffer_descriptors.';
        PRINT N'@MaxZeilen positiv; NULL/0 = unbegrenzt. @ResultSetArt=CONSOLE|RAW|TABLE|NONE; TABLE verwendet @ResultTablesJson.';
        RETURN;
    END;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;

    CREATE TABLE [#BufferPoolAnalysis_MemorySnapshot]
    (
          [PhysicalMemoryInUseKb] bigint NULL
        , [LockedPageAllocationsKb] bigint NULL
        , [LargePageAllocationsKb] bigint NULL
        , [MemoryUtilizationPercent] int NULL
        , [AvailableCommitLimitKb] bigint NULL
        , [ProcessPhysicalMemoryLow] bit NULL
        , [ProcessVirtualMemoryLow] bit NULL
        , [TotalPhysicalMemoryKb] bigint NULL
        , [AvailablePhysicalMemoryKb] bigint NULL
        , [AvailablePhysicalMemoryPercent] decimal(9,2) NULL
        , [SystemMemoryStateDesc] nvarchar(256) NULL
        , [FindingCode] varchar(80) NOT NULL
        , [FindingSeverity] varchar(16) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#BufferPoolAnalysis_ResourceSemaphores]
    (
          [PoolId] int NULL
        , [ResourceSemaphoreId] smallint NULL
        , [TotalMemoryKb] bigint NULL
        , [AvailableMemoryKb] bigint NULL
        , [GrantedMemoryKb] bigint NULL
        , [UsedMemoryKb] bigint NULL
        , [GranteeCount] int NULL
        , [WaiterCount] int NULL
        , [TimeoutErrorCount] bigint NULL
        , [ForcedGrantCount] bigint NULL
    );
    CREATE TABLE [#BufferPoolAnalysis_MemoryClerks]
    (
          [ClerkType] nvarchar(60) NOT NULL
        , [PagesKb] bigint NULL
        , [VirtualMemoryReservedKb] bigint NULL
        , [VirtualMemoryCommittedKb] bigint NULL
        , [LockedOrAweKb] bigint NULL
        , [ClerkCount] bigint NOT NULL
    );
    CREATE TABLE [#BufferPoolAnalysis_BufferPool]
    (
          [DatabaseId] int NOT NULL
        , [DatabaseName] sysname NULL
        , [CachedPages] bigint NOT NULL
        , [CachedSizeMb] decimal(19,2) NOT NULL
        , [DirtyPages] bigint NOT NULL
        , [DirtySizeMb] decimal(19,2) NOT NULL
        , [FreeSpaceMb] decimal(19,2) NOT NULL
        , [NumaNodeCount] bigint NOT NULL
    );

    IF @MaxZeilen < 0 OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
    BEGIN
        SELECT @StatusCode = 'INVALID_PARAMETER', @IsPartial = 1,
               @ErrorMessage = N'Ungültiger Zeilen- oder Ausgabeparameter.';
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        BEGIN TRY
            INSERT [#BufferPoolAnalysis_MemorySnapshot]
            SELECT
                  [p].[physical_memory_in_use_kb]
                , [p].[locked_page_allocations_kb]
                , [p].[large_page_allocations_kb]
                , [p].[memory_utilization_percentage]
                , [p].[available_commit_limit_kb]
                , [p].[process_physical_memory_low]
                , [p].[process_virtual_memory_low]
                , [s].[total_physical_memory_kb]
                , [s].[available_physical_memory_kb]
                , CONVERT(decimal(9,2), 100.0 * [s].[available_physical_memory_kb]
                  / NULLIF([s].[total_physical_memory_kb], 0))
                , [s].[system_memory_state_desc]
                , CASE WHEN [p].[process_physical_memory_low] = 1 THEN 'PROCESS_PHYSICAL_MEMORY_LOW'
                       WHEN [p].[process_virtual_memory_low] = 1 THEN 'PROCESS_VIRTUAL_MEMORY_LOW'
                       WHEN [s].[available_physical_memory_kb] * 100.0
                            / NULLIF([s].[total_physical_memory_kb], 0) < 5 THEN 'OS_AVAILABLE_MEMORY_BELOW_5_PERCENT'
                       ELSE 'NO_MEMORY_PRESSURE_FLAG' END
                , CASE WHEN [p].[process_physical_memory_low] = 1
                            OR [p].[process_virtual_memory_low] = 1 THEN 'HIGH'
                       WHEN [s].[available_physical_memory_kb] * 100.0
                            / NULLIF([s].[total_physical_memory_kb], 0) < 5 THEN 'MEDIUM'
                       ELSE 'INFO' END
                , N'Momentaufnahme; Verlauf, andere Prozesse und Betriebssystemgrenzen separat prüfen.'
            FROM [sys].[dm_os_process_memory] AS [p] WITH (NOLOCK)
            CROSS JOIN [sys].[dm_os_sys_memory] AS [s] WITH (NOLOCK);

            INSERT [#BufferPoolAnalysis_ResourceSemaphores]
            SELECT
                  [pool_id], [resource_semaphore_id], [total_memory_kb]
                , [available_memory_kb], [granted_memory_kb], [used_memory_kb]
                , [grantee_count], [waiter_count], [timeout_error_count]
                , [forced_grant_count]
            FROM [sys].[dm_exec_query_resource_semaphores] WITH (NOLOCK);
        END TRY
        BEGIN CATCH
            SELECT @StatusCode = CASE WHEN ERROR_NUMBER() IN (229, 297, 300, 371)
                                      THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
                   @IsPartial = 1, @ErrorNumber = ERROR_NUMBER(), @ErrorMessage = ERROR_MESSAGE();
        END CATCH;

        IF @StatusCode IN ('AVAILABLE', 'AVAILABLE_LIMITED') AND @MitMemoryClerks = 1
        BEGIN
            BEGIN TRY
                INSERT [#BufferPoolAnalysis_MemoryClerks]
                SELECT
                      [type], SUM(CONVERT(bigint, [pages_kb]))
                    , SUM(CONVERT(bigint, [virtual_memory_reserved_kb]))
                    , SUM(CONVERT(bigint, [virtual_memory_committed_kb]))
                    , SUM(CONVERT(bigint, [awe_allocated_kb]))
                      + SUM(CONVERT(bigint, [shared_memory_committed_kb]))
                    , COUNT_BIG(*)
                FROM [sys].[dm_os_memory_clerks] WITH (NOLOCK)
                GROUP BY [type];
            END TRY
            BEGIN CATCH
                SELECT @IsPartial = 1, @StatusCode = 'AVAILABLE_LIMITED';
                IF @ErrorNumber IS NULL
                    SELECT @ErrorNumber = ERROR_NUMBER(),
                           @ErrorMessage = CONCAT(N'Memory Clerks nicht lesbar: ', ERROR_MESSAGE());
            END CATCH;
        END;

        IF @StatusCode IN ('AVAILABLE', 'AVAILABLE_LIMITED') AND @MitBufferPoolVerteilung = 1
        BEGIN
            BEGIN TRY
                INSERT [#BufferPoolAnalysis_BufferPool]
                SELECT
                      [b].[database_id], [d].[name], COUNT_BIG(*)
                    , CONVERT(decimal(19,2), COUNT_BIG(*) * 8.0 / 1024.0)
                    , SUM(CONVERT(bigint, CASE WHEN [is_modified] = 1 THEN 1 ELSE 0 END))
                    , CONVERT(decimal(19,2),
                      SUM(CONVERT(bigint, CASE WHEN [is_modified] = 1 THEN 1 ELSE 0 END)) * 8.0 / 1024.0)
                    , CONVERT(decimal(19,2), SUM(CONVERT(bigint, [free_space_in_bytes])) / 1048576.0)
                    , COUNT_BIG(DISTINCT [numa_node])
                FROM [sys].[dm_os_buffer_descriptors] AS [b] WITH (NOLOCK)
                LEFT JOIN [master].[sys].[databases] AS [d] WITH (NOLOCK)
                  ON [d].[database_id]=[b].[database_id]
                GROUP BY [b].[database_id],[d].[name];
            END TRY
            BEGIN CATCH
                SELECT @IsPartial = 1, @StatusCode = 'AVAILABLE_LIMITED';
                IF @ErrorNumber IS NULL
                    SELECT @ErrorNumber = ERROR_NUMBER(),
                           @ErrorMessage = CONCAT(N'Buffer-Pool-Verteilung nicht lesbar: ', ERROR_MESSAGE());
            END CATCH;
        END;

        IF (EXISTS (SELECT 1 FROM [#BufferPoolAnalysis_ResourceSemaphores] WHERE [WaiterCount] > 0)
            OR EXISTS (SELECT 1 FROM [#BufferPoolAnalysis_MemorySnapshot] WHERE [FindingCode] <> 'NO_MEMORY_PRESSURE_FLAG'))
           AND @StatusCode = 'AVAILABLE'
            SET @StatusCode = 'AVAILABLE_WITH_FINDING';
    END;

    SELECT @StatusCodeOut = @StatusCode, @IsPartialOut = @IsPartial,
           @ErrorNumberOut = @ErrorNumber, @ErrorMessageOut = @ErrorMessage;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
            (SELECT N'BufferPoolAnalysis' AS [resultName], 1 AS [schemaVersion],
                    @Now AS [generatedAtUtc], @StatusCode AS [statusCode], @IsPartial AS [isPartial],
                    @MitBufferPoolVerteilung AS [bufferPoolDistributionCollected]
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @SnapshotJson nvarchar(max) =
            (SELECT * FROM [#BufferPoolAnalysis_MemorySnapshot] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @SemaphoreJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#BufferPoolAnalysis_ResourceSemaphores]
             ORDER BY [WaiterCount] DESC, [PoolId], [ResourceSemaphoreId]
             FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @ClerkJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#BufferPoolAnalysis_MemoryClerks]
             ORDER BY [PagesKb] DESC, [ClerkType] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @BufferJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#BufferPoolAnalysis_BufferPool]
             ORDER BY [CachedPages] DESC, [DatabaseId] FOR JSON PATH, INCLUDE_NULL_VALUES);
        SET @Json = CONCAT(N'{"meta":', COALESCE(@MetaJson, N'{}'),
                           N',"memory":', COALESCE(@SnapshotJson, N'[]'),
                           N',"resourceSemaphores":', COALESCE(@SemaphoreJson, N'[]'),
                           N',"memoryClerks":', COALESCE(@ClerkJson, N'[]'),
                           N',"bufferPool":', COALESCE(@BufferJson, N'[]'), N'}');
    END;

    IF @OutputMode = 'RAW'
    BEGIN
        SELECT N'USP_BufferPoolAnalysis' AS [ModuleName], @Now AS [CollectionTimeUtc],
               @StatusCode AS [StatusCode], @IsPartial AS [IsPartial],
               @MitBufferPoolVerteilung AS [BufferPoolDistributionCollected],
               @ErrorNumber AS [ErrorNumber], @ErrorMessage AS [ErrorMessage],
               N'Momentaufnahme; Buffer-Pool-Scan ist opt-in.' AS [Detail];
        SELECT * FROM [#BufferPoolAnalysis_MemorySnapshot];
        SELECT TOP (@Limit) * FROM [#BufferPoolAnalysis_ResourceSemaphores]
        ORDER BY [WaiterCount] DESC, [PoolId], [ResourceSemaphoreId];
        SELECT TOP (@Limit) * FROM [#BufferPoolAnalysis_MemoryClerks] ORDER BY [PagesKb] DESC, [ClerkType];
        SELECT TOP (@Limit) * FROM [#BufferPoolAnalysis_BufferPool] ORDER BY [CachedPages] DESC, [DatabaseId];
    END
    ELSE IF @OutputMode = 'CONSOLE'
    BEGIN
        SELECT N'Buffer Pool und Speicherdruck' AS [Ergebnis], @Now AS [Stand_UTC],
               @StatusCode AS [Status], @IsPartial AS [Teilweise], @ErrorMessage AS [Hinweis];
        SELECT N'Speichermomentaufnahme' AS [Ergebnis], [PhysicalMemoryInUseKb] AS [SQL_Physisch_KB],
               [AvailablePhysicalMemoryKb] AS [OS_Verfuegbar_KB],
               [AvailablePhysicalMemoryPercent] AS [OS_Verfuegbar_Prozent],
               [ProcessPhysicalMemoryLow] AS [SQL_Physisch_Niedrig],
               [ProcessVirtualMemoryLow] AS [SQL_Virtuell_Niedrig],
               [FindingCode] AS [Befund], [FindingSeverity] AS [Prioritaet], [EvidenceLimit] AS [Grenze]
        FROM [#BufferPoolAnalysis_MemorySnapshot];
        SELECT TOP (@Limit) N'Resource Semaphore' AS [Ergebnis], [PoolId] AS [Pool_ID],
               [ResourceSemaphoreId] AS [Semaphore_ID], [AvailableMemoryKb] AS [Verfuegbar_KB],
               [GrantedMemoryKb] AS [Zugewiesen_KB], [GranteeCount] AS [Zuteilungen],
               [WaiterCount] AS [Wartende], [TimeoutErrorCount] AS [Timeouts]
        FROM [#BufferPoolAnalysis_ResourceSemaphores]
        ORDER BY [WaiterCount] DESC, [PoolId], [ResourceSemaphoreId];
        SELECT TOP (@Limit) N'Memory Clerk' AS [Ergebnis], [ClerkType] AS [Typ],
               [PagesKb] AS [Pages_KB], [VirtualMemoryCommittedKb] AS [Virtuell_Committed_KB],
               [LockedOrAweKb] AS [Locked_oder_AWE_KB], [ClerkCount] AS [Instanzen]
        FROM [#BufferPoolAnalysis_MemoryClerks] ORDER BY [PagesKb] DESC, [ClerkType];
        SELECT TOP (@Limit) N'Buffer-Pool-Verteilung' AS [Ergebnis], [DatabaseName] AS [Datenbank],
               [CachedSizeMb] AS [Cache_MB], [DirtySizeMb] AS [Dirty_MB],
               [FreeSpaceMb] AS [Freiraum_in_Seiten_MB], [NumaNodeCount] AS [NUMA_Nodes]
        FROM [#BufferPoolAnalysis_BufferPool] ORDER BY [CachedPages] DESC, [DatabaseId];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#BufferPoolAnalysis_MemorySnapshot'
            , @ResultLabel=N'BufferPoolAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#BufferPoolAnalysis_MemorySnapshot'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
