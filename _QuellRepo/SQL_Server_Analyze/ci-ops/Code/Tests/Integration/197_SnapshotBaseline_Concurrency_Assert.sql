USE [SQLServerAnalyzeTest];
GO
SET NOCOUNT ON;
UPDATE [monitor].[SnapshotTargetConfiguration] SET [IsEnabled]=1 WHERE [ConfigurationId]=1;
DECLARE @Status varchar(40),@Partial bit,@Error int,@Message nvarchar(2048),@RunId bigint;
EXEC [monitor].[USP_RunSnapshotCollectionCycle]
     @SchedulerType='EXTERNAL',@RunEvenIfNotDue=1,@ResultSetArt='NONE',@PrintMeldungen=0,
     @CaptureRunIdOut=@RunId OUTPUT,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@Error OUTPUT,@ErrorMessageOut=@Message OUTPUT;
IF @Status<>'SKIPPED_CONCURRENT' OR @RunId IS NOT NULL
    THROW 53741,N'SC023_CONCURRENCY_ASSERT_FAILED',1;
PRINT N'SC023_CONCURRENCY_CONTRACT PASS';
GO
