USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ConfigureSnapshotTarget
Version      : 1.0.0
Stand        : 2026-07-21
Zweck        : Aktiviert ein explizit installiertes SC-023-Ziel und schreibt
               alle bekannten Collector-/Retentionwerte typisiert.
Nebenwirkung : Persistente Konfiguration in Framework- und Snapshot-Datenbank.
Rechte       : Vergibt keine Rechte; DDL-/DML- und EXECUTE-Rechte sind extern.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_ConfigureSnapshotTarget]
      @TargetDatabaseName       sysname
    , @IsEnabled                bit          = 1
    , @SchedulerType            varchar(16)  = 'EXTERNAL'
    , @CollectionIntervalSeconds smallint     = 30
    , @MaxRows                  int           = 1000
    , @PayloadEnabled           bit           = 0
    , @RawRetentionDays         smallint      = 14
    , @PayloadRetentionDays     smallint      = 7
    , @RollupRetentionDays      smallint      = 180
    , @SoftBudgetMB             int           = 10240
    , @PurgeIntervalMinutes     smallint      = 60
    , @PurgeBatchRows           int           = 10000
    , @BudgetAction             varchar(32)   = 'PURGE_EXPIRED_THEN_STOP'
    , @PrintMeldungen           bit           = 1
    , @Hilfe                    bit           = 0
    , @StatusCodeOut            varchar(40)   = NULL OUTPUT
    , @IsPartialOut             bit           = NULL OUTPUT
    , @ErrorNumberOut           int           = NULL OUTPUT
    , @ErrorMessageOut          nvarchar(2048)= NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET LOCK_TIMEOUT 0;

    SELECT @StatusCodeOut='AVAILABLE',@IsPartialOut=0,@ErrorNumberOut=NULL,@ErrorMessageOut=NULL;

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_ConfigureSnapshotTarget';
        PRINT N'Konfiguriert das separat installierte SC-023-Ziel. Keine Datenbank, Rechte oder Schedulerobjekte werden erstellt.';
        PRINT N'Alle Retention-, Intervall-, Payload- und Budgetwerte sind typisiert; einzig PURGE_EXPIRED_THEN_STOP ist im ersten Slice zulässig.';
        RETURN;
    END;

    SET @SchedulerType=UPPER(LTRIM(RTRIM(COALESCE(@SchedulerType,''))));
    SET @BudgetAction=UPPER(LTRIM(RTRIM(COALESCE(@BudgetAction,''))));

    IF NULLIF(LTRIM(RTRIM(@TargetDatabaseName)),N'') IS NULL
       OR @SchedulerType NOT IN ('MANUAL','EXTERNAL','SQL_AGENT')
       OR @IsEnabled IS NULL OR @IsEnabled NOT IN (0,1)
    BEGIN
        SELECT @StatusCodeOut='INVALID_PARAMETER',@IsPartialOut=1,
               @ErrorMessageOut=N'Ungültiger Zielname, Aktivierungswert oder Scheduler-Typ.';
        RETURN;
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM [master].[sys].[databases] WITH (NOLOCK)
        WHERE [name]=@TargetDatabaseName
          AND [state]=0
          AND [is_read_only]=0
    )
    BEGIN
        SELECT @StatusCodeOut='TARGET_UNAVAILABLE',@IsPartialOut=1,
               @ErrorMessageOut=N'Die konfigurierte Snapshot-Datenbank ist nicht online und schreibbar.';
        RETURN;
    END;

    DECLARE @Sql nvarchar(max),@TargetQuoted nvarchar(258)=QUOTENAME(@TargetDatabaseName),
            @TargetStatus varchar(40),@TargetError int,@TargetMessage nvarchar(2048);

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @Sql=N'EXEC '+@TargetQuoted+N'.[snapshot].[InternalConfigureSnapshotPolicy]
              @CollectionIntervalSeconds=@p1,@MaxRows=@p2,@PayloadEnabled=@p3,
              @RawRetentionDays=@p4,@PayloadRetentionDays=@p5,@RollupRetentionDays=@p6,
              @SoftBudgetMB=@p7,@PurgeIntervalMinutes=@p8,@PurgeBatchRows=@p9,
              @BudgetAction=@p10,@StatusCodeOut=@s OUTPUT,@ErrorNumberOut=@e OUTPUT,
              @ErrorMessageOut=@m OUTPUT;';
        EXEC [sys].[sp_executesql] @Sql,
             N'@p1 smallint,@p2 int,@p3 bit,@p4 smallint,@p5 smallint,@p6 smallint,@p7 int,@p8 smallint,@p9 int,@p10 varchar(32),@s varchar(40) OUTPUT,@e int OUTPUT,@m nvarchar(2048) OUTPUT',
             @CollectionIntervalSeconds,@MaxRows,@PayloadEnabled,@RawRetentionDays,@PayloadRetentionDays,@RollupRetentionDays,
             @SoftBudgetMB,@PurgeIntervalMinutes,@PurgeBatchRows,@BudgetAction,
             @s=@TargetStatus OUTPUT,@e=@TargetError OUTPUT,@m=@TargetMessage OUTPUT;

        IF @TargetStatus<>'AVAILABLE'
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT @StatusCodeOut=@TargetStatus,@IsPartialOut=1,@ErrorNumberOut=@TargetError,@ErrorMessageOut=@TargetMessage;
            RETURN;
        END;

        UPDATE [monitor].[SnapshotTargetConfiguration]
        SET [TargetDatabaseName]=@TargetDatabaseName,[IsEnabled]=@IsEnabled,
            [DefaultSchedulerType]=@SchedulerType,[PackageContractVersion]=1,
            [LastUpdatedUtc]=SYSUTCDATETIME()
        WHERE [ConfigurationId]=1;

        IF @@ROWCOUNT<>1
            THROW 53701,N'Die Framework-Zielkonfiguration fehlt.',1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
        SELECT @StatusCodeOut=CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371)
                                   THEN 'DENIED_PERMISSION' ELSE 'TARGET_UNAVAILABLE' END,
               @IsPartialOut=1,@ErrorNumberOut=ERROR_NUMBER(),@ErrorMessageOut=ERROR_MESSAGE();
    END CATCH;

    IF @PrintMeldungen=1 AND @StatusCodeOut<>'AVAILABLE'
    BEGIN
        DECLARE @PrintMessage nvarchar(2048)=COALESCE(@ErrorMessageOut,CONVERT(nvarchar(2048),@StatusCodeOut));
        RAISERROR(N'USP_ConfigureSnapshotTarget: %s',10,1,@PrintMessage) WITH NOWAIT;
    END;
END;
GO
