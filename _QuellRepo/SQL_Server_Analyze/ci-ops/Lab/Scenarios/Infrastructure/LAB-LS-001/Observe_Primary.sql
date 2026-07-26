SET NOCOUNT ON;

DECLARE @LogShippingJson nvarchar(max);
DECLARE @BackupChainJson nvarchar(max);
DECLARE @InfrastructureJson nvarchar(max);

EXEC [LabAnalyze].[monitor].[USP_LogShippingStatus]
      @MaxZeilen = 100
    , @ResultSetArt = 'NONE'
    , @JsonErzeugen = 1
    , @Json = @LogShippingJson OUTPUT
    , @PrintMeldungen = 0;

EXEC [LabAnalyze].[monitor].[USP_BackupChainAnalysis]
      @DatabaseNames = N'LabLs001'
    , @HighImpactConfirmed = 1
    , @HistoryDays = 1
    , @MitRestoreEvidence = 0
    , @MaxZeilen = 100
    , @ResultSetArt = 'NONE'
    , @JsonErzeugen = 1
    , @Json = @BackupChainJson OUTPUT
    , @PrintMeldungen = 0;

EXEC [LabAnalyze].[monitor].[USP_InfrastructureAnalysis]
      @MitAgent = 0
    , @MitAgentJobs = 0
    , @MitResourceGovernor = 0
    , @MitAvailabilityGroups = 0
    , @MitBackupRecovery = 0
    , @MitLogShipping = 1
    , @MitReplication = 0
    , @MitDataCapture = 0
    , @MitReplicationDetails = 0
    , @MitBackupChain = 1
    , @MitAvailabilityDeep = 0
    , @MitAgentMonitoring = 0
    , @DatabaseNames = N'LabLs001'
    , @HighImpactConfirmed = 1
    , @MaxZeilen = 100
    , @ResultSetArt = 'NONE'
    , @JsonErzeugen = 1
    , @Json = @InfrastructureJson OUTPUT
    , @PrintMeldungen = 0;

SELECT N'LAB_ANALYZER_JSON=' +
(
    SELECT
          JSON_QUERY(@LogShippingJson) AS [logShipping]
        , JSON_QUERY(@BackupChainJson) AS [backupChain]
        , JSON_QUERY(@InfrastructureJson) AS [infrastructure]
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
);
