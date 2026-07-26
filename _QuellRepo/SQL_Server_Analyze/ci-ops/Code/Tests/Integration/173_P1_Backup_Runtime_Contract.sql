USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 173_P1_Backup_Runtime_Contract.sql
Zweck        : Prüft Laufzeitverträge für vier P1-Backupkettenfälle.
Datenschutz  : Ausschließlich die synthetische Testdatenbank wird verwendet.
               Laufzeitwerte werden nicht in Repositoryartefakte übernommen.
Nebenwirkung : Erzeugt kurzlebige msdb-Backuphistorie und eine generische Datei
               im Default-Backupverzeichnis des disposable Targets, stellt das
               Recovery Model wieder her und löscht die Testhistorie.
Grenze       : Es wird bewusst kein Restore ausgeführt.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit;
DECLARE @DatabaseName sysname=(SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID());
DECLARE @OriginalRecovery nvarchar(60) =
       (SELECT [recovery_model_desc] FROM [sys].[databases] WITH (NOLOCK) WHERE [name]=@DatabaseName);
DECLARE @DatabaseQuoted nvarchar(258)=QUOTENAME(@DatabaseName);
DECLARE @BackupDevice nvarchar(128)=N'SQL_Server_Analyze_P1_Backup_Runtime.bak';
DECLARE @BackupSql nvarchar(max);
DECLARE @ExecutedCases TABLE([CaseId] varchar(40) NOT NULL PRIMARY KEY);

BEGIN TRY
    EXEC [msdb].[dbo].[sp_delete_database_backuphistory] @database_name=@DatabaseName;
    EXEC(N'ALTER DATABASE '+@DatabaseQuoted+N' SET RECOVERY SIMPLE WITH NO_WAIT;');
    CHECKPOINT;

    /* BKP-FULL: ohne sichtbares nicht-copy-only Full bleibt die Lücke explizit. */
    EXEC [monitor].[USP_BackupChainAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@HistoryDays=1,
         @MitRestoreEvidence=1,@MaxZeilen=0,@ResultSetArt='NONE',
         @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1 OR @Status<>'AVAILABLE_WITH_FINDING'
       OR NOT EXISTS
          (SELECT 1 FROM OPENJSON(@Json,N'$.summary')
           WITH ([FindingCode] varchar(100) N'$.FindingCode',[Severity] varchar(16) N'$.FindingSeverity')
           WHERE [FindingCode]='FULL_BACKUP_EVIDENCE_MISSING' AND [Severity]='HIGH')
        THROW 54700,N'P1-Vertrag BKP-FULL fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('BKP-FULL');

    /* Ein checksummiertes Full liefert die Baseline für Restore- und Diff-Fälle. */
    SET @BackupSql=N'BACKUP DATABASE '+@DatabaseQuoted+N' TO DISK=N'''
                  +REPLACE(@BackupDevice,N'''',N'''''')+N''' WITH INIT,CHECKSUM;';
    EXEC [sys].[sp_executesql] @BackupSql;

    /* BKP-RESTORE: fehlende Restorehistorie ist Evidenzlücke, kein Restorebeweis. */
    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXEC [monitor].[USP_BackupChainAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@HistoryDays=1,
         @MitRestoreEvidence=1,@MaxZeilen=0,@ResultSetArt='NONE',
         @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1
       OR NOT EXISTS
          (SELECT 1 FROM OPENJSON(@Json,N'$.summary')
           WITH ([LatestRestoreDate] datetime2 N'$.LatestRestoreDate',
                 [FindingCode] varchar(100) N'$.FindingCode')
           WHERE [LatestRestoreDate] IS NULL AND [FindingCode]='RESTORE_EVIDENCE_MISSING')
        THROW 54701,N'P1-Vertrag BKP-RESTORE fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('BKP-RESTORE');

    /* BKP-DIFF: ein Diff der älteren Fullbasis passt nicht zum neuesten Full. */
    SET @BackupSql=N'BACKUP DATABASE '+@DatabaseQuoted+N' TO DISK=N'''
                  +REPLACE(@BackupDevice,N'''',N'''''')+N''' WITH DIFFERENTIAL,INIT,CHECKSUM;';
    EXEC [sys].[sp_executesql] @BackupSql;
    SET @BackupSql=N'BACKUP DATABASE '+@DatabaseQuoted+N' TO DISK=N'''
                  +REPLACE(@BackupDevice,N'''',N'''''')+N''' WITH INIT,CHECKSUM;';
    EXEC [sys].[sp_executesql] @BackupSql;

    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXEC [monitor].[USP_BackupChainAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@HistoryDays=1,
         @MitRestoreEvidence=1,@MaxZeilen=0,@ResultSetArt='NONE',
         @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1
       OR NOT EXISTS
          (SELECT 1 FROM OPENJSON(@Json,N'$.summary')
           WITH ([LatestMatchingDifferentialFinish] datetime2 N'$.LatestMatchingDifferentialFinish')
           WHERE [LatestMatchingDifferentialFinish] IS NULL)
       OR NOT EXISTS
          (SELECT 1
           FROM OPENJSON(@Json,N'$.backups')
           WITH ([BackupType] char(1) N'$.BackupType',[DifferentialBaseLsn] decimal(25,0) N'$.DifferentialBaseLsn') AS [d]
           CROSS JOIN
           (SELECT TOP (1) [CheckpointLsn]
            FROM OPENJSON(@Json,N'$.backups')
            WITH ([BackupType] char(1) N'$.BackupType',[CheckpointLsn] decimal(25,0) N'$.CheckpointLsn',
                  [BackupFinishDate] datetime2 N'$.BackupFinishDate',[BackupSetId] int N'$.BackupSetId')
            WHERE [BackupType]='D'
            ORDER BY [BackupFinishDate] DESC,[BackupSetId] DESC) AS [f]
           WHERE [d].[BackupType]='I' AND [d].[DifferentialBaseLsn]<>[f].[CheckpointLsn])
        THROW 54702,N'P1-Vertrag BKP-DIFF fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('BKP-DIFF');

    /* BKP-LOG: ein kontrollierter Recovery-Model-Reset erzeugt eine sichtbare Lücke. */
    EXEC(N'ALTER DATABASE '+@DatabaseQuoted+N' SET RECOVERY FULL WITH NO_WAIT;');
    SET @BackupSql=N'BACKUP DATABASE '+@DatabaseQuoted+N' TO DISK=N'''
                  +REPLACE(@BackupDevice,N'''',N'''''')+N''' WITH INIT,CHECKSUM;';
    EXEC [sys].[sp_executesql] @BackupSql;
    SET @BackupSql=N'BACKUP LOG '+@DatabaseQuoted+N' TO DISK=N'''
                  +REPLACE(@BackupDevice,N'''',N'''''')+N''' WITH INIT,CHECKSUM;';
    EXEC [sys].[sp_executesql] @BackupSql;
    EXEC(N'ALTER DATABASE '+@DatabaseQuoted+N' SET RECOVERY SIMPLE WITH NO_WAIT;');
    CHECKPOINT;
    EXEC(N'ALTER DATABASE '+@DatabaseQuoted+N' SET RECOVERY FULL WITH NO_WAIT;');
    SET @BackupSql=N'BACKUP DATABASE '+@DatabaseQuoted+N' TO DISK=N'''
                  +REPLACE(@BackupDevice,N'''',N'''''')+N''' WITH INIT,CHECKSUM;';
    EXEC [sys].[sp_executesql] @BackupSql;
    SET @BackupSql=N'BACKUP LOG '+@DatabaseQuoted+N' TO DISK=N'''
                  +REPLACE(@BackupDevice,N'''',N'''''')+N''' WITH INIT,CHECKSUM;';
    EXEC [sys].[sp_executesql] @BackupSql;

    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXEC [monitor].[USP_BackupChainAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@HistoryDays=1,
         @MitRestoreEvidence=1,@MaxZeilen=0,@ResultSetArt='NONE',
         @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1
       OR NOT EXISTS
          (SELECT 1 FROM OPENJSON(@Json,N'$.summary')
           WITH ([GapCount] bigint N'$.LogGapCountInWindow',[FindingCode] varchar(100) N'$.FindingCode')
           WHERE [GapCount]>0 AND [FindingCode]='LOG_CHAIN_GAP_IN_VISIBLE_HISTORY')
        THROW 54703,N'P1-Vertrag BKP-LOG fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('BKP-LOG');

    EXEC [msdb].[dbo].[sp_delete_database_backuphistory] @database_name=@DatabaseName;
    EXEC(N'ALTER DATABASE '+@DatabaseQuoted+N' SET RECOVERY '+@OriginalRecovery+N' WITH NO_WAIT;');
END TRY
BEGIN CATCH
    BEGIN TRY
        EXEC [msdb].[dbo].[sp_delete_database_backuphistory] @database_name=@DatabaseName;
        EXEC(N'ALTER DATABASE '+@DatabaseQuoted+N' SET RECOVERY '+@OriginalRecovery+N' WITH NO_WAIT;');
    END TRY
    BEGIN CATCH
    END CATCH;
    THROW;
END CATCH;

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>4
    THROW 54704,N'Der P1-Backupvertrag hat nicht alle vorgesehenen Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'Vier synthetische P1-Backupkettenfälle wurden ohne persistierte Laufzeitausgabe ausgeführt.' AS [Detail]
FROM @ExecutedCases;
GO
