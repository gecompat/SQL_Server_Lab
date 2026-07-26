/*
===============================================================================
Objekt       : snapshot.InternalCompletePerformanceCounterCycle
Version      : 1.0.0
Stand        : 2026-07-21
Zweck        : Persistiert einen transient übergebenen Performance-Counter-
               JSON-Vertrag als typisierte Samples und optionales Rohpayload.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [snapshot].[InternalCompletePerformanceCounterCycle]
      @CaptureRunId       bigint
    , @CollectorJson      nvarchar(max)
    , @SourceStatusCode   varchar(40)
    , @SourceIsPartial    bit
    , @SourceErrorNumber  int
    , @SourceErrorMessage nvarchar(2048)
    , @StatusCodeOut      varchar(40) OUTPUT
    , @IsPartialOut       bit OUTPUT
    , @ErrorNumberOut     int OUTPUT
    , @ErrorMessageOut    nvarchar(2048) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;

    SELECT @StatusCodeOut=COALESCE(@SourceStatusCode,'ERROR_HANDLED'),
           @IsPartialOut=COALESCE(@SourceIsPartial,1),
           @ErrorNumberOut=@SourceErrorNumber,
           @ErrorMessageOut=@SourceErrorMessage;

    CREATE TABLE [#InternalCompletePerformanceCounterCycle_Counters]
    (
          [ObjectName] nvarchar(128) NOT NULL
        , [CounterName] nvarchar(128) NOT NULL
        , [InstanceName] nvarchar(128) NOT NULL
        , [CounterType] int NOT NULL
        , [MetricValue] decimal(38,6) NULL
        , [MetricUnit] varchar(40) NULL
        , [AfterValue] bigint NULL
        , [FindingCode] varchar(80) NULL
        , [ScopeKeyHash] varbinary(32) NULL
        , [ScopeIdentityJson] nvarchar(max) NULL
    );

    BEGIN TRY
        IF @CollectorJson IS NULL OR ISJSON(@CollectorJson)<>1
        BEGIN
            SELECT @StatusCodeOut=CASE WHEN @SourceStatusCode IN ('DENIED_PERMISSION','UNAVAILABLE_OBJECT')
                                       THEN @SourceStatusCode ELSE 'ERROR_HANDLED' END,
                   @IsPartialOut=1,
                   @ErrorMessageOut=COALESCE(@SourceErrorMessage,N'Der Collector lieferte keinen gültigen JSON-Vertrag.');
        END
        ELSE
        BEGIN
            INSERT [#InternalCompletePerformanceCounterCycle_Counters]
            (
                  [ObjectName],[CounterName],[InstanceName],[CounterType]
                , [MetricValue],[MetricUnit],[AfterValue],[FindingCode]
            )
            SELECT
                  [ObjectName],[CounterName],[InstanceName],[CounterType]
                , [MetricValue],[MetricUnit],[AfterValue],[FindingCode]
            FROM OPENJSON(@CollectorJson,N'$.counters')
            WITH
            (
                  [ObjectName] nvarchar(128) N'$.ObjectName'
                , [CounterName] nvarchar(128) N'$.CounterName'
                , [InstanceName] nvarchar(128) N'$.InstanceName'
                , [CounterType] int N'$.CounterType'
                , [MetricValue] decimal(38,6) N'$.MetricValue'
                , [MetricUnit] varchar(40) N'$.MetricUnit'
                , [AfterValue] bigint N'$.AfterValue'
                , [FindingCode] varchar(80) N'$.FindingCode'
            )
            WHERE [ObjectName] IS NOT NULL
              AND [CounterName] IS NOT NULL
              AND [InstanceName] IS NOT NULL
              AND [CounterType] IS NOT NULL;

            UPDATE [c]
            SET [ScopeIdentityJson]=[j].[ScopeIdentityJson],
                [ScopeKeyHash]=HASHBYTES('SHA2_256',CONVERT(varbinary(max),[j].[ScopeIdentityJson]))
            FROM [#InternalCompletePerformanceCounterCycle_Counters] AS [c]
            CROSS APPLY
            (
                SELECT
                (
                    SELECT [c].[ObjectName] AS [objectName],
                           [c].[CounterName] AS [counterName],
                           [c].[InstanceName] AS [instanceName],
                           [c].[CounterType] AS [counterType],
                           [c].[MetricUnit] AS [metricUnit]
                    FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES
                ) AS [ScopeIdentityJson]
            ) AS [j];

            DECLARE @SqlServerStartTimeUtc datetime2(3)=TRY_CONVERT(datetime2(3),JSON_VALUE(@CollectorJson,N'$.meta.sqlServerStartTime')),
                    @ResetEpochId uniqueidentifier,
                    @Now datetime2(3)=SYSUTCDATETIME(),
                    @ServerScopeId bigint,
                    @RawMetricDefinitionId bigint,
                    @InterpretedMetricDefinitionId bigint,
                    @PayloadEnabled bit=0;

            SELECT TOP (1) @ResetEpochId=[ResetEpochId]
            FROM [snapshot].[CaptureRun]
            WHERE [SqlServerStartTimeUtc]=@SqlServerStartTimeUtc
              AND [ResetEpochId] IS NOT NULL
            ORDER BY [CaptureRunId] DESC;
            IF @ResetEpochId IS NULL SET @ResetEpochId=NEWID();

            IF NOT EXISTS
            (
                SELECT 1
                FROM [snapshot].[Scope]
                WHERE [ScopeType]='SERVER'
                  AND [ParentScopeId] IS NULL
                  AND [ScopeKeyHash]=HASHBYTES('SHA2_256',CONVERT(varbinary(max),N'{"scope":"SERVER"}'))
            )
                INSERT [snapshot].[Scope]
                ([ScopeType],[ParentScopeId],[ScopeKeyHash],[ScopeIdentityJson],[CreatedAtUtc])
                VALUES
                ('SERVER',NULL,HASHBYTES('SHA2_256',CONVERT(varbinary(max),N'{"scope":"SERVER"}')),N'{"scope":"SERVER"}',@Now);

            SELECT @ServerScopeId=[ScopeId]
            FROM [snapshot].[Scope]
            WHERE [ScopeType]='SERVER'
              AND [ParentScopeId] IS NULL
              AND [ScopeKeyHash]=HASHBYTES('SHA2_256',CONVERT(varbinary(max),N'{"scope":"SERVER"}'));

            INSERT [snapshot].[Scope]
            ([ScopeType],[ParentScopeId],[ScopeKeyHash],[ScopeIdentityJson],[CreatedAtUtc])
            SELECT 'PERFORMANCE_COUNTER',@ServerScopeId,[c].[ScopeKeyHash],[c].[ScopeIdentityJson],@Now
            FROM [#InternalCompletePerformanceCounterCycle_Counters] AS [c]
            WHERE NOT EXISTS
            (
                SELECT 1
                FROM [snapshot].[Scope] AS [s]
                WHERE [s].[ScopeType]='PERFORMANCE_COUNTER'
                  AND [s].[ParentScopeId]=@ServerScopeId
                  AND [s].[ScopeKeyHash]=[c].[ScopeKeyHash]
            )
            GROUP BY [c].[ScopeKeyHash],[c].[ScopeIdentityJson];

            SELECT @RawMetricDefinitionId=[MetricDefinitionId]
            FROM [snapshot].[MetricDefinition]
            WHERE [MetricCode]='PERFORMANCE_COUNTER_RAW';
            SELECT @InterpretedMetricDefinitionId=[MetricDefinitionId]
            FROM [snapshot].[MetricDefinition]
            WHERE [MetricCode]='PERFORMANCE_COUNTER_INTERPRETED';

            INSERT [snapshot].[MetricSample]
            (
                  [CaptureRunId],[ScopeId],[MetricDefinitionId],[CollectedAtUtc]
                , [ResetEpochId],[BigintValue],[QualityCode],[IsPartial]
            )
            SELECT @CaptureRunId,[s].[ScopeId],@RawMetricDefinitionId,@Now,@ResetEpochId,
                   [c].[AfterValue],COALESCE(NULLIF([c].[FindingCode],''),'MEASURED'),@IsPartialOut
            FROM [#InternalCompletePerformanceCounterCycle_Counters] AS [c]
            JOIN [snapshot].[Scope] AS [s]
              ON [s].[ScopeType]='PERFORMANCE_COUNTER'
             AND [s].[ParentScopeId]=@ServerScopeId
             AND [s].[ScopeKeyHash]=[c].[ScopeKeyHash]
            WHERE [c].[AfterValue] IS NOT NULL;

            INSERT [snapshot].[MetricSample]
            (
                  [CaptureRunId],[ScopeId],[MetricDefinitionId],[CollectedAtUtc]
                , [ResetEpochId],[NumericValue],[QualityCode],[IsPartial]
            )
            SELECT @CaptureRunId,[s].[ScopeId],@InterpretedMetricDefinitionId,@Now,@ResetEpochId,
                   [c].[MetricValue],COALESCE(NULLIF([c].[FindingCode],''),'MEASURED'),@IsPartialOut
            FROM [#InternalCompletePerformanceCounterCycle_Counters] AS [c]
            JOIN [snapshot].[Scope] AS [s]
              ON [s].[ScopeType]='PERFORMANCE_COUNTER'
             AND [s].[ParentScopeId]=@ServerScopeId
             AND [s].[ScopeKeyHash]=[c].[ScopeKeyHash]
            WHERE [c].[MetricValue] IS NOT NULL;

            SELECT @PayloadEnabled=[PayloadEnabled]
            FROM [snapshot].[CollectorPolicy]
            WHERE [CollectorCode]='PERFORMANCE_COUNTERS';

            IF @PayloadEnabled=1
                INSERT [snapshot].[PayloadSnapshot]
                (
                      [CaptureRunId],[ModuleName],[CapturedAtUtc],[PayloadFormat]
                    , [PayloadContractVersion],[CompressionType],[PayloadHash]
                    , [Payload],[UncompressedCharacterCount]
                )
                VALUES
                (
                      @CaptureRunId,N'monitor.USP_PerformanceCounters',@Now,'JSON',1,'GZIP'
                    , HASHBYTES('SHA2_256',CONVERT(varbinary(max),@CollectorJson))
                    , COMPRESS(@CollectorJson),CONVERT(bigint,LEN(@CollectorJson))
                );

            UPDATE [snapshot].[CaptureRun]
            SET [SqlServerStartTimeUtc]=@SqlServerStartTimeUtc,
                [ResetEpochId]=@ResetEpochId
            WHERE [CaptureRunId]=@CaptureRunId;
        END;

        INSERT [snapshot].[ModuleStatus]
        (
              [CaptureRunId],[ModuleName],[CollectionTimeUtc],[StatusCode]
            , [IsPartial],[ErrorNumber],[ErrorMessage],[EvidenceLimit]
        )
        VALUES
        (
              @CaptureRunId,N'monitor.USP_PerformanceCounters',SYSUTCDATETIME(),@StatusCodeOut
            , @IsPartialOut,@ErrorNumberOut,@ErrorMessageOut
            , N'@SampleSeconds=0; CollectorPolicy.MaxRows begrenzt die persistierte Collectorprojektion.'
        );
    END TRY
    BEGIN CATCH
        SELECT @StatusCodeOut=CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371)
                                   THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
               @IsPartialOut=1,@ErrorNumberOut=ERROR_NUMBER(),@ErrorMessageOut=ERROR_MESSAGE();
        INSERT [snapshot].[ModuleStatus]
        ([CaptureRunId],[ModuleName],[CollectionTimeUtc],[StatusCode],[IsPartial],[ErrorNumber],[ErrorMessage],[EvidenceLimit])
        VALUES
        (@CaptureRunId,N'monitor.USP_PerformanceCounters',SYSUTCDATETIME(),@StatusCodeOut,1,@ErrorNumberOut,@ErrorMessageOut,
         N'Persistenz wurde kontrolliert als partiell markiert.');
    END CATCH;
END;
GO
