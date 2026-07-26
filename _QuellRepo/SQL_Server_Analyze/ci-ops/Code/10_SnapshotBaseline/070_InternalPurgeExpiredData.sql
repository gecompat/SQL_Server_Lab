/*
===============================================================================
Objekt       : snapshot.InternalPurgeExpiredData
Version      : 1.0.0
Stand        : 2026-07-21
Zweck        : Löscht ausschließlich abgelaufene Snapshotdaten child-first in
               begrenzten Batches; nicht abgelaufene Daten bleiben erhalten.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [snapshot].[InternalPurgeExpiredData]
      @MaxBatches        int
    , @Force             bit
    , @PurgeRunIdOut     bigint OUTPUT
    , @StatusCodeOut     varchar(40) OUTPUT
    , @BudgetExceededOut bit OUTPUT
    , @ErrorNumberOut    int OUTPUT
    , @ErrorMessageOut   nvarchar(2048) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET LOCK_TIMEOUT 0;

    DECLARE @Now datetime2(3)=SYSUTCDATETIME(),
            @RawRetentionDays smallint,
            @PayloadRetentionDays smallint,
            @PurgeIntervalMinutes smallint,
            @BatchRows int,
            @SoftBudgetMB bigint,
            @UsedBefore decimal(19,3),
            @UsedAfter decimal(19,3),
            @LastPurgeUtc datetime2(3),
            @Batch int=0,
            @Deleted int,
            @Rows int,
            @MetricDeleted bigint=0,
            @PayloadDeleted bigint=0,
            @ModuleDeleted bigint=0,
            @RunsDeleted bigint=0,
            @ScopeDeleted bigint=0;

    SELECT @PurgeRunIdOut=NULL,@StatusCodeOut='AVAILABLE',@BudgetExceededOut=0,
           @ErrorNumberOut=NULL,@ErrorMessageOut=NULL;

    IF @MaxBatches NOT BETWEEN 1 AND 1000
    BEGIN
        SELECT @StatusCodeOut='INVALID_PARAMETER',@ErrorMessageOut=N'@MaxBatches muss zwischen 1 und 1000 liegen.';
        RETURN;
    END;

    SELECT @RawRetentionDays=[RawRetentionDays],
           @PayloadRetentionDays=[PayloadRetentionDays],
           @PurgeIntervalMinutes=[PurgeIntervalMinutes],
           @BatchRows=[PurgeBatchRows],
           @SoftBudgetMB=[SoftBudgetMB]
    FROM [snapshot].[RetentionPolicy]
    WHERE [RetentionPolicyCode]='DEFAULT';

    SELECT TOP (1) @LastPurgeUtc=[EndedAtUtc]
    FROM [snapshot].[PurgeRun]
    WHERE [StatusCode] IN ('AVAILABLE','AVAILABLE_LIMITED')
      AND [EndedAtUtc] IS NOT NULL
    ORDER BY [PurgeRunId] DESC;

    SELECT @UsedBefore=CONVERT(decimal(19,3),COALESCE(SUM(CONVERT(decimal(38,3),[size]))*8.0/1024.0,0))
    FROM [sys].[database_files] WITH (NOLOCK)
    WHERE [type]=0;

    IF @Force=0
       AND @UsedBefore<=@SoftBudgetMB
       AND @LastPurgeUtc IS NOT NULL
       AND DATEADD(MINUTE,@PurgeIntervalMinutes,@LastPurgeUtc)>@Now
    BEGIN
        SELECT @StatusCodeOut='SKIPPED_NOT_DUE',@BudgetExceededOut=0;
        RETURN;
    END;

    INSERT [snapshot].[PurgeRun]
    ([StartedAtUtc],[StatusCode],[UsedDataMbBefore],[SoftBudgetMb])
    VALUES (@Now,'RUNNING',@UsedBefore,@SoftBudgetMB);
    SET @PurgeRunIdOut=CONVERT(bigint,SCOPE_IDENTITY());

    BEGIN TRY
        WHILE @Batch<@MaxBatches
        BEGIN
            SET @Deleted=0;
            BEGIN TRANSACTION;

            DELETE TOP (@BatchRows) [m]
            FROM [snapshot].[MetricSample] AS [m]
            WHERE [m].[CollectedAtUtc]<DATEADD(DAY,-@RawRetentionDays,@Now);
            SET @Rows=@@ROWCOUNT;
            SET @MetricDeleted+=@Rows;
            SET @Deleted+=@Rows;

            DELETE TOP (@BatchRows) [p]
            FROM [snapshot].[PayloadSnapshot] AS [p]
            WHERE [p].[CapturedAtUtc]<DATEADD(DAY,-@PayloadRetentionDays,@Now);
            SET @Rows=@@ROWCOUNT;
            SET @PayloadDeleted+=@Rows;
            SET @Deleted+=@Rows;

            DELETE TOP (@BatchRows) [m]
            FROM [snapshot].[ModuleStatus] AS [m]
            JOIN [snapshot].[CaptureRun] AS [r]
              ON [r].[CaptureRunId]=[m].[CaptureRunId]
            WHERE [r].[StartedAtUtc]<DATEADD(DAY,-@RawRetentionDays,@Now)
              AND NOT EXISTS (SELECT 1 FROM [snapshot].[MetricSample] AS [x] WHERE [x].[CaptureRunId]=[r].[CaptureRunId])
              AND NOT EXISTS (SELECT 1 FROM [snapshot].[PayloadSnapshot] AS [x] WHERE [x].[CaptureRunId]=[r].[CaptureRunId]);
            SET @Rows=@@ROWCOUNT;
            SET @ModuleDeleted+=@Rows;
            SET @Deleted+=@Rows;

            DELETE TOP (@BatchRows) [r]
            FROM [snapshot].[CaptureRun] AS [r]
            WHERE [r].[StartedAtUtc]<DATEADD(DAY,-@RawRetentionDays,@Now)
              AND NOT EXISTS (SELECT 1 FROM [snapshot].[MetricSample] AS [m] WHERE [m].[CaptureRunId]=[r].[CaptureRunId])
              AND NOT EXISTS (SELECT 1 FROM [snapshot].[PayloadSnapshot] AS [p] WHERE [p].[CaptureRunId]=[r].[CaptureRunId])
              AND NOT EXISTS (SELECT 1 FROM [snapshot].[ModuleStatus] AS [s] WHERE [s].[CaptureRunId]=[r].[CaptureRunId]);
            SET @Rows=@@ROWCOUNT;
            SET @RunsDeleted+=@Rows;
            SET @Deleted+=@Rows;

            DELETE TOP (@BatchRows) [s]
            FROM [snapshot].[Scope] AS [s]
            WHERE [s].[ScopeType]<>'SERVER'
              AND NOT EXISTS (SELECT 1 FROM [snapshot].[MetricSample] AS [m] WHERE [m].[ScopeId]=[s].[ScopeId])
              AND NOT EXISTS (SELECT 1 FROM [snapshot].[Scope] AS [c] WHERE [c].[ParentScopeId]=[s].[ScopeId]);
            SET @Rows=@@ROWCOUNT;
            SET @ScopeDeleted+=@Rows;
            SET @Deleted+=@Rows;

            COMMIT TRANSACTION;
            SET @Batch+=1;
            IF @Deleted=0 BREAK;
        END;

        SELECT @UsedAfter=CONVERT(decimal(19,3),COALESCE(SUM(CONVERT(decimal(38,3),[size]))*8.0/1024.0,0))
        FROM [sys].[database_files] WITH (NOLOCK)
        WHERE [type]=0;

        SET @BudgetExceededOut=CASE WHEN @UsedAfter>@SoftBudgetMB THEN 1 ELSE 0 END;
        SET @StatusCodeOut=CASE WHEN @Batch>=@MaxBatches AND @Deleted>0 THEN 'AVAILABLE_LIMITED' ELSE 'AVAILABLE' END;

        UPDATE [snapshot].[PurgeRun]
        SET [EndedAtUtc]=SYSUTCDATETIME(),[StatusCode]=@StatusCodeOut,
            [BatchesExecuted]=@Batch,[MetricRowsDeleted]=@MetricDeleted,
            [PayloadRowsDeleted]=@PayloadDeleted,[ModuleRowsDeleted]=@ModuleDeleted,
            [CaptureRunsDeleted]=@RunsDeleted,[ScopeRowsDeleted]=@ScopeDeleted,
            [UsedDataMbAfter]=@UsedAfter
        WHERE [PurgeRunId]=@PurgeRunIdOut;
    END TRY
    BEGIN CATCH
        IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
        SELECT @StatusCodeOut=CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371)
                                   THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
               @BudgetExceededOut=1,@ErrorNumberOut=ERROR_NUMBER(),@ErrorMessageOut=ERROR_MESSAGE();
        UPDATE [snapshot].[PurgeRun]
        SET [EndedAtUtc]=SYSUTCDATETIME(),[StatusCode]=@StatusCodeOut,
            [BatchesExecuted]=@Batch,[MetricRowsDeleted]=@MetricDeleted,
            [PayloadRowsDeleted]=@PayloadDeleted,[ModuleRowsDeleted]=@ModuleDeleted,
            [CaptureRunsDeleted]=@RunsDeleted,[ScopeRowsDeleted]=@ScopeDeleted,
            [ErrorNumber]=@ErrorNumberOut,[ErrorMessage]=@ErrorMessageOut
        WHERE [PurgeRunId]=@PurgeRunIdOut;
    END CATCH;
END;
GO
