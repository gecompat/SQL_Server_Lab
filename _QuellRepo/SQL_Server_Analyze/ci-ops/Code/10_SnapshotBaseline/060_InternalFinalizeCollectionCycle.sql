/* Finalisiert einen bereits eröffneten SC-023-Lauf ohne Quellzugriff. */
CREATE OR ALTER PROCEDURE [snapshot].[InternalFinalizeCollectionCycle]
      @CaptureRunId    bigint
    , @StatusCode      varchar(40)
    , @IsPartial       bit
    , @ErrorNumber     int
    , @ErrorMessage    nvarchar(2048)
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;

    UPDATE [snapshot].[CaptureRun]
    SET [EndedAtUtc]=SYSUTCDATETIME(),
        [StatusCode]=@StatusCode,
        [IsPartial]=@IsPartial,
        [ErrorNumber]=@ErrorNumber,
        [ErrorMessage]=@ErrorMessage,
        [MetricSampleCount]=(SELECT COUNT_BIG(*) FROM [snapshot].[MetricSample] WHERE [CaptureRunId]=@CaptureRunId),
        [PayloadCount]=(SELECT COUNT_BIG(*) FROM [snapshot].[PayloadSnapshot] WHERE [CaptureRunId]=@CaptureRunId)
    WHERE [CaptureRunId]=@CaptureRunId;
END;
GO
