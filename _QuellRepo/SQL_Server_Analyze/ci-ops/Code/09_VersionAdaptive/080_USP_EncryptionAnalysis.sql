USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_EncryptionAnalysis
Version      : 1.0.0
Stand        : 2026-07-18
Zweck        : Bewertet den sichtbaren Lebenszyklus von TDE, Schutzertifikaten,
               expliziter Backupverschluesselung, Always Encrypted und Ledger.
Methodik     : Read-only Metadatenanalyse mit je Quelle isolierter Fehlergrenze.
Datenschutz  : Liest keine Schluesselpfade, Thumbprints, verschluesselten Werte,
               Backupmedien, SQL-Texte, Konten oder privaten Schluessel.
Grenzen      : Metadaten und lokale Zertifikat-Backuphistorie beweisen weder den
               Besitz externer Schluesselkopien noch die Wiederherstellbarkeit.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_EncryptionAnalysis]
      @DatabaseNames                              nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen               bit            = 0
    , @DatabaseNamePattern                        nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @NurProblematisch                           bit            = 0
    , @TdeTransitionWarnMinutes                   int            = 60
    , @CertificateExpiryWarnDays                  int            = 90
    , @ExpliziteBackupverschluesselungErwartet    bit            = 0
    , @BackupLookbackDays                         int            = 35
    , @MaxZeilen                                  int            = 1000
    , @LockTimeoutMs                              int            = 0
    , @ResultSetArt                               varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                               bit            = 0
    , @Json                                       nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                             bit            = 1
    , @Hilfe                                      bit            = 0
    , @StatusCodeOut                              varchar(40)    = NULL OUTPUT
    , @IsPartialOut                               bit            = NULL OUTPUT
    , @ErrorNumberOut                             int            = NULL OUTPUT
    , @ErrorMessageOut                            nvarchar(2048) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json = NULL;

    DECLARE @Now datetime2(3)=SYSUTCDATETIME();
    DECLARE @OutputMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @OutputMode = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @OutputMode = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'databases',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Limit bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0
                               THEN CONVERT(bigint,9223372036854775807)
                               ELSE CONVERT(bigint,@MaxZeilen) END;
    DECLARE @Major int=TRY_CONVERT(int,SERVERPROPERTY('ProductMajorVersion'));
    DECLARE @StatusCode varchar(40)='AVAILABLE';
    DECLARE @IsPartial bit=0;
    DECLARE @ErrorNumber int=NULL;
    DECLARE @ErrorMessage nvarchar(2048)=NULL;
    DECLARE @CrossDatabaseRequested bit=0;

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_EncryptionAnalysis';
        PRINT N'Bewertet TDE, Zertifikatlebenszyklus, explizite Backupverschluesselung sowie aggregierte Always-Encrypted- und Ledger-Metadaten.';
        PRINT N'Es werden keine Schlüsselpfade, Thumbprints, verschlüsselten Werte, Backupmedien, Konten oder privaten Schlüssel gelesen.';
        PRINT N'Ein Zertifikat ohne lokale Backuphistorie ist nur ein Hinweis; ein externer Export kann trotzdem existieren.';
        RETURN;
    END;

    CREATE TABLE [#EncryptionAnalysis_DatabaseCandidates]
    (
          [DatabaseId] int NOT NULL PRIMARY KEY
        , [DatabaseName] sysname NOT NULL
        , [StateDesc] nvarchar(60) NULL
        , [UserAccessDesc] nvarchar(60) NULL
        , [IsReadOnly] bit NULL
        , [CompatibilityLevel] tinyint NULL
        , [CollationName] sysname NULL
        , [RecoveryModelDesc] nvarchar(60) NULL
        , [IsSystemDatabase] bit NULL
        , [RequestedOrdinal] int NULL
    );
    CREATE TABLE [#EncryptionAnalysis_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );
    CREATE TABLE [#EncryptionAnalysis_SourceStatus]
    (
          [SourceName] nvarchar(128) NOT NULL PRIMARY KEY
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [Detail] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#EncryptionAnalysis_Encryption]
    (
          [DatabaseId] int NOT NULL PRIMARY KEY
        , [DatabaseName] sysname NOT NULL
        , [IsEncrypted] bit NULL
        , [EncryptionState] int NULL
        , [EncryptionStateDesc] nvarchar(60) NULL
        , [PercentComplete] real NULL
        , [EncryptionScanState] int NULL
        , [EncryptionScanStateDesc] nvarchar(60) NULL
        , [EncryptionScanModifyDate] datetime NULL
        , [KeyAlgorithm] nvarchar(32) NULL
        , [KeyLength] int NULL
        , [EncryptorType] nvarchar(32) NULL
        , [ProtectorName] sysname NULL
        , [ProtectorExpiryDate] datetime NULL
        , [ProtectorPrivateKeyLastBackupDate] datetime NULL
        , [LatestFullBackupFinishDate] datetime NULL
        , [LatestFullBackupExplicitlyEncrypted] bit NULL
        , [LatestFullBackupAlgorithm] nvarchar(32) NULL
        , [LatestFullBackupEncryptorType] nvarchar(32) NULL
        , [ColumnMasterKeyCount] bigint NULL
        , [ColumnEncryptionKeyCount] bigint NULL
        , [EncryptedColumnCount] bigint NULL
        , [LedgerTableCount] bigint NULL
        , [FindingCode] varchar(100) NULL
        , [FindingSeverity] varchar(16) NULL
        , [EvidenceLimit] nvarchar(1000) NULL
    );

    IF @MaxZeilen<0 OR @LockTimeoutMs<0
       OR @TdeTransitionWarnMinutes<1 OR @TdeTransitionWarnMinutes>525600
       OR @CertificateExpiryWarnDays<1 OR @CertificateExpiryWarnDays>36500
       OR @BackupLookbackDays<1 OR @BackupLookbackDays>3650
       OR @OutputMode NOT IN ('RAW','CONSOLE','NONE')
    BEGIN
        SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,
               @ErrorMessage=N'Ungueltiger Grenzwert, Datenbank-, Zeilen- oder Ausgabeparameter.';
    END;

    IF @StatusCode='AVAILABLE'
    BEGIN
        EXEC [monitor].[USP_PrepareDatabaseCandidates]
              @DatabaseNames=@DatabaseNames
            , @SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen
            , @DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

            , @AnalysisClass=NULL
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT
            , @CrossDatabaseRequested=@CrossDatabaseRequested OUTPUT,@CandidateTable=N'#EncryptionAnalysis_DatabaseCandidates',@WarningTable=N'#EncryptionAnalysis_DatabaseCandidateWarnings';
    END;

    SET LOCK_TIMEOUT 0;

    INSERT [#EncryptionAnalysis_Encryption]([DatabaseId],[DatabaseName],[IsEncrypted],[FindingCode],[FindingSeverity],[EvidenceLimit])
    SELECT [DatabaseId],[DatabaseName],NULL,'SOURCE_PENDING','INFO',
           N'Read-only Metadaten; Schluesselbesitz und Wiederherstellbarkeit werden nicht bewiesen.'
    FROM [#EncryptionAnalysis_DatabaseCandidates];

    IF @StatusCode='AVAILABLE'
    BEGIN
        BEGIN TRY
            UPDATE [e]
            SET [IsEncrypted]=[d].[is_encrypted],
                [EncryptionState]=[k].[encryption_state],
                [EncryptionStateDesc]=CASE [k].[encryption_state]
                    WHEN 0 THEN N'NO_DATABASE_KEY' WHEN 1 THEN N'UNENCRYPTED'
                    WHEN 2 THEN N'ENCRYPTION_IN_PROGRESS' WHEN 3 THEN N'ENCRYPTED'
                    WHEN 4 THEN N'KEY_CHANGE_IN_PROGRESS' WHEN 5 THEN N'DECRYPTION_IN_PROGRESS'
                    WHEN 6 THEN N'PROTECTION_CHANGE_IN_PROGRESS' END,
                [PercentComplete]=[k].[percent_complete],
                [EncryptionScanState]=[k].[encryption_scan_state],
                [EncryptionScanStateDesc]=CASE [k].[encryption_scan_state]
                    WHEN 0 THEN N'NONE' WHEN 1 THEN N'RUNNING' WHEN 2 THEN N'SUSPENDED'
                    WHEN 3 THEN N'ABORTED' WHEN 4 THEN N'COMPLETE' END,
                [EncryptionScanModifyDate]=[k].[encryption_scan_modify_date],
                [KeyAlgorithm]=[k].[key_algorithm],
                [KeyLength]=[k].[key_length],
                [EncryptorType]=[k].[encryptor_type],
                [ProtectorName]=[c].[name],
                [ProtectorExpiryDate]=[c].[expiry_date],
                [ProtectorPrivateKeyLastBackupDate]=[c].[pvt_key_last_backup_date]
            FROM [#EncryptionAnalysis_Encryption] AS [e]
            JOIN [sys].[databases] AS [d] WITH (NOLOCK) ON [d].[database_id]=[e].[DatabaseId]
            LEFT JOIN [sys].[dm_database_encryption_keys] AS [k] WITH (NOLOCK) ON [k].[database_id]=[e].[DatabaseId]
            LEFT JOIN [master].[sys].[certificates] AS [c] WITH (NOLOCK)
              ON [k].[encryptor_type]=N'CERTIFICATE' AND [c].[thumbprint]=[k].[encryptor_thumbprint];

            INSERT [#EncryptionAnalysis_SourceStatus] VALUES
            (N'sys.dm_database_encryption_keys + master.sys.certificates','AVAILABLE',0,
             N'TDE-Zustand und sichtbare Zertifikatmetadaten gelesen; Thumbprints und Schluesselmaterial werden nicht ausgegeben.');
        END TRY
        BEGIN CATCH
            INSERT [#EncryptionAnalysis_SourceStatus] VALUES
            (N'sys.dm_database_encryption_keys + master.sys.certificates',
             CASE WHEN ERROR_NUMBER() IN (229,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,
             N'TDE- oder Zertifikatmetadaten waren nicht vollstaendig lesbar; die uebrigen Quellen werden weiter ausgewertet.');
            SELECT @IsPartial=1,@ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE();
        END CATCH;

        BEGIN TRY
            ;WITH [LatestFull] AS
            (
                SELECT [bs].[database_name],[bs].[backup_finish_date],[bs].[key_algorithm],[bs].[encryptor_type],
                       ROW_NUMBER() OVER(PARTITION BY [bs].[database_name]
                                         ORDER BY [bs].[backup_finish_date] DESC,[bs].[backup_set_id] DESC) AS [rn]
                FROM [msdb].[dbo].[backupset] AS [bs] WITH (NOLOCK)
                JOIN [#EncryptionAnalysis_DatabaseCandidates] AS [d]
                  ON [d].[DatabaseName] COLLATE SQL_Latin1_General_CP1_CS_AS
                   = [bs].[database_name] COLLATE SQL_Latin1_General_CP1_CS_AS
                WHERE [bs].[type]='D' AND [bs].[is_copy_only]=0
                  AND [bs].[backup_finish_date]>=DATEADD(DAY,-@BackupLookbackDays,GETDATE())
            )
            UPDATE [e]
            SET [LatestFullBackupFinishDate]=[b].[backup_finish_date],
                [LatestFullBackupExplicitlyEncrypted]=CONVERT(bit,CASE WHEN [b].[key_algorithm] IS NULL THEN 0 ELSE 1 END),
                [LatestFullBackupAlgorithm]=[b].[key_algorithm],
                [LatestFullBackupEncryptorType]=[b].[encryptor_type]
            FROM [#EncryptionAnalysis_Encryption] AS [e]
            JOIN [LatestFull] AS [b]
              ON [b].[rn]=1
             AND [b].[database_name] COLLATE SQL_Latin1_General_CP1_CS_AS
               = [e].[DatabaseName] COLLATE SQL_Latin1_General_CP1_CS_AS;

            INSERT [#EncryptionAnalysis_SourceStatus] VALUES
            (N'msdb.dbo.backupset','AVAILABLE',0,
             N'Nur Zeitpunkt und Verschluesselungsart des letzten Full-Backups im Sichtfenster; keine Medien-, Konto- oder Serverdaten.');
        END TRY
        BEGIN CATCH
            INSERT [#EncryptionAnalysis_SourceStatus] VALUES
            (N'msdb.dbo.backupset',CASE WHEN ERROR_NUMBER() IN (229,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,
             N'Backupverschluesselungsmetadaten waren nicht lesbar; andere Quellen bleiben auswertbar.');
            SELECT @IsPartial=1,@ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE();
        END CATCH;

        BEGIN TRY
            DECLARE @DatabaseId int,@DatabaseName sysname,@Sql nvarchar(max);
            DECLARE [database_cursor] CURSOR LOCAL FAST_FORWARD FOR
                SELECT [DatabaseId],[DatabaseName] FROM [#EncryptionAnalysis_DatabaseCandidates]
                WHERE [StateDesc]=N'ONLINE' AND [DatabaseId]<>2 ORDER BY [DatabaseId];
            OPEN [database_cursor];
            FETCH NEXT FROM [database_cursor] INTO @DatabaseId,@DatabaseName;
            WHILE @@FETCH_STATUS=0
            BEGIN
                BEGIN TRY
                    SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; UPDATE [e] SET '
                        +N'[ColumnMasterKeyCount]=(SELECT COUNT_BIG(*) FROM '+QUOTENAME(@DatabaseName)+N'.[sys].[column_master_keys] WITH (NOLOCK)),'
                        +N'[ColumnEncryptionKeyCount]=(SELECT COUNT_BIG(*) FROM '+QUOTENAME(@DatabaseName)+N'.[sys].[column_encryption_keys] WITH (NOLOCK)),'
                        +N'[EncryptedColumnCount]=(SELECT COUNT_BIG(*) FROM '+QUOTENAME(@DatabaseName)+N'.[sys].[columns] WITH (NOLOCK) WHERE [encryption_type] IS NOT NULL)'
                        +CASE WHEN @Major>=16 THEN
                          N',[LedgerTableCount]=(SELECT COUNT_BIG(*) FROM '+QUOTENAME(@DatabaseName)+N'.[sys].[tables] WITH (NOLOCK) WHERE [ledger_type]<>0)'
                          ELSE N',[LedgerTableCount]=NULL' END
                        +N' FROM [#EncryptionAnalysis_Encryption] AS [e] WHERE [e].[DatabaseId]=@pDatabaseId;';
                    EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseId int',@pDatabaseId=@DatabaseId;
                END TRY
                BEGIN CATCH
                    SET @IsPartial=1;
                    IF NOT EXISTS(SELECT 1 FROM [#EncryptionAnalysis_DatabaseCandidateWarnings] WHERE [RequestedName]=@DatabaseName)
                        INSERT [#EncryptionAnalysis_DatabaseCandidateWarnings] VALUES
                        (@DatabaseName,CASE WHEN ERROR_NUMBER() IN (229,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
                         N'Aggregierte Always-Encrypted- oder Ledger-Metadaten waren fuer diese Datenbank nicht lesbar.');
                END CATCH;
                FETCH NEXT FROM [database_cursor] INTO @DatabaseId,@DatabaseName;
            END;
            CLOSE [database_cursor];
            DEALLOCATE [database_cursor];

            INSERT [#EncryptionAnalysis_SourceStatus] VALUES
            (N'sys.column_master_keys + sys.column_encryption_keys + sys.columns + sys.tables','AVAILABLE',@IsPartial,
             CASE WHEN @Major>=16 THEN N'Nur aggregierte Objektanzahlen; keine Schluesselpfade, Signaturen, Werte oder Objektnamen.'
                  ELSE N'Nur aggregierte Always-Encrypted-Anzahlen; Ledger ist vor SQL Server 2022 nicht verfuegbar.' END);
        END TRY
        BEGIN CATCH
            IF CURSOR_STATUS('local','database_cursor')>=0 CLOSE [database_cursor];
            IF CURSOR_STATUS('local','database_cursor')>-3 DEALLOCATE [database_cursor];
            INSERT [#EncryptionAnalysis_SourceStatus] VALUES
            (N'sys.column_master_keys + sys.column_encryption_keys + sys.columns + sys.tables','ERROR_HANDLED',1,
             N'Die datenbanklokale Aggregation wurde abgefangen; TDE- und Backupquellen bleiben auswertbar.');
            SELECT @IsPartial=1,@ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE();
        END CATCH;

        UPDATE [e]
        SET [FindingCode]=CASE
                WHEN [EncryptionScanState]=3 THEN 'TDE_SCAN_ABORTED'
                WHEN [EncryptionScanState]=2 THEN 'TDE_SCAN_SUSPENDED'
                WHEN [EncryptionState] IN (2,4,5,6)
                 AND [EncryptionScanModifyDate]<DATEADD(MINUTE,-@TdeTransitionWarnMinutes,SYSUTCDATETIME())
                    THEN 'TDE_TRANSITION_LONG_RUNNING'
                WHEN [IsEncrypted]=1 AND [EncryptorType]=N'CERTIFICATE' AND [ProtectorName] IS NULL
                    THEN 'TDE_PROTECTOR_NOT_VISIBLE'
                WHEN [IsEncrypted]=1 AND [ProtectorExpiryDate]<DATEADD(DAY,@CertificateExpiryWarnDays,GETDATE())
                    THEN 'TDE_CERTIFICATE_EXPIRY_WINDOW'
                WHEN [IsEncrypted]=1 AND [EncryptorType]=N'CERTIFICATE' AND [ProtectorPrivateKeyLastBackupDate] IS NULL
                    THEN 'LOCAL_CERTIFICATE_EXPORT_EVIDENCE_MISSING'
                WHEN @ExpliziteBackupverschluesselungErwartet=1
                 AND [LatestFullBackupFinishDate] IS NULL THEN 'FULL_BACKUP_EVIDENCE_MISSING'
                WHEN @ExpliziteBackupverschluesselungErwartet=1
                 AND [LatestFullBackupExplicitlyEncrypted]=0 THEN 'EXPLICIT_BACKUP_ENCRYPTION_MISSING'
                WHEN [IsEncrypted]=1 THEN 'TDE_METADATA_CONSISTENT'
                ELSE 'DATABASE_NOT_TDE_ENCRYPTED' END,
            [FindingSeverity]=CASE
                WHEN [EncryptionScanState] IN (2,3) THEN 'HIGH'
                WHEN [EncryptionState] IN (2,4,5,6)
                 AND [EncryptionScanModifyDate]<DATEADD(MINUTE,-@TdeTransitionWarnMinutes,SYSUTCDATETIME()) THEN 'MEDIUM'
                WHEN [IsEncrypted]=1 AND [EncryptorType]=N'CERTIFICATE' AND [ProtectorName] IS NULL THEN 'MEDIUM'
                WHEN [IsEncrypted]=1 AND [ProtectorExpiryDate]<DATEADD(DAY,@CertificateExpiryWarnDays,GETDATE()) THEN 'MEDIUM'
                WHEN @ExpliziteBackupverschluesselungErwartet=1
                 AND ([LatestFullBackupFinishDate] IS NULL OR [LatestFullBackupExplicitlyEncrypted]=0) THEN 'MEDIUM'
                ELSE 'INFO' END,
            [EvidenceLimit]=CASE
                WHEN [IsEncrypted]=1 AND [EncryptorType]=N'CERTIFICATE' AND [ProtectorPrivateKeyLastBackupDate] IS NULL
                    THEN N'Kein lokaler Exportzeitpunkt sichtbar; externe Schluesselkopien koennen dennoch existieren.'
                WHEN @ExpliziteBackupverschluesselungErwartet=1
                    THEN N'TDE und explizite Backupverschluesselung sind getrennte Schutzmechanismen; ein Test-Restore bleibt erforderlich.'
                ELSE N'Read-only Metadaten; Schluesselbesitz und Wiederherstellbarkeit werden nicht bewiesen.' END
        FROM [#EncryptionAnalysis_Encryption] AS [e];

        IF EXISTS(SELECT 1 FROM [#EncryptionAnalysis_SourceStatus] WHERE [IsPartial]=1)
            SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
        ELSE IF EXISTS(SELECT 1 FROM [#EncryptionAnalysis_Encryption]
                       WHERE [FindingSeverity] IN ('HIGH','MEDIUM'))
            SET @StatusCode='AVAILABLE_WITH_FINDING';
    END;

    SELECT @StatusCodeOut=@StatusCode,@IsPartialOut=@IsPartial,
           @ErrorNumberOut=@ErrorNumber,@ErrorMessageOut=@ErrorMessage;

    IF @JsonErzeugen=1
    BEGIN
        DECLARE @MetaJson nvarchar(max)=(SELECT N'EncryptionAnalysis' AS [resultName],1 AS [schemaVersion],
            @Now AS [generatedAtUtc],@StatusCode AS [statusCode],@IsPartial AS [isPartial],@Major AS [productMajorVersion]
            FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
        DECLARE @DataJson nvarchar(max)=(SELECT TOP (@Limit) * FROM [#EncryptionAnalysis_Encryption]
            WHERE @NurProblematisch=0 OR [FindingSeverity] IN ('HIGH','MEDIUM')
            ORDER BY CASE [FindingSeverity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,[DatabaseId]
            FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @SourceJson nvarchar(max)=(SELECT * FROM [#EncryptionAnalysis_SourceStatus] ORDER BY [SourceName]
            FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @WarningJson nvarchar(max)=(SELECT * FROM [#EncryptionAnalysis_DatabaseCandidateWarnings] ORDER BY [RequestedName]
            FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@MetaJson,N'{}'),N',"databases":',COALESCE(@DataJson,N'[]'),
                         N',"sources":',COALESCE(@SourceJson,N'[]'),N',"warnings":',COALESCE(@WarningJson,N'[]'),N'}');
    END;

    IF @OutputMode='RAW'
    BEGIN
        SELECT N'USP_EncryptionAnalysis' AS [ModuleName],@Now AS [CollectionTimeUtc],@StatusCode AS [StatusCode],
               @IsPartial AS [IsPartial],@Major AS [ProductMajorVersion],@ErrorNumber AS [ErrorNumber],@ErrorMessage AS [ErrorMessage];
        SELECT TOP (@Limit) * FROM [#EncryptionAnalysis_Encryption]
        WHERE @NurProblematisch=0 OR [FindingSeverity] IN ('HIGH','MEDIUM')
        ORDER BY CASE [FindingSeverity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,[DatabaseId];
        SELECT * FROM [#EncryptionAnalysis_SourceStatus] ORDER BY [SourceName];
        SELECT * FROM [#EncryptionAnalysis_DatabaseCandidateWarnings] ORDER BY [RequestedName];
    END
    ELSE IF @OutputMode='CONSOLE'
    BEGIN
        SELECT N'Verschluesselungsanalyse' AS [Ergebnis],@Now AS [Stand_UTC],@StatusCode AS [Status],
               @IsPartial AS [Teilweise],@ErrorMessage AS [Hinweis];
        SELECT TOP (@Limit) N'Verschluesselung' AS [Ergebnis],[DatabaseName] AS [Datenbank],
               [IsEncrypted] AS [TDE_Aktiv],[EncryptionStateDesc] AS [TDE_Status],
               [EncryptionScanStateDesc] AS [Scan_Status],[PercentComplete] AS [Fortschritt_Prozent],
               [ProtectorName] AS [Schutzobjekt],[ProtectorExpiryDate] AS [Ablaufdatum],
               [LatestFullBackupFinishDate] AS [Letztes_Full],
               [LatestFullBackupExplicitlyEncrypted] AS [Full_Explizit_Verschluesselt],
               [ColumnMasterKeyCount] AS [Column_Master_Keys],[ColumnEncryptionKeyCount] AS [Column_Encryption_Keys],
               [EncryptedColumnCount] AS [Verschluesselte_Spalten],[LedgerTableCount] AS [Ledger_Tabellen],
               [FindingCode] AS [Befund],[FindingSeverity] AS [Prioritaet],[EvidenceLimit] AS [Evidenzgrenze]
        FROM [#EncryptionAnalysis_Encryption]
        WHERE @NurProblematisch=0 OR [FindingSeverity] IN ('HIGH','MEDIUM')
        ORDER BY CASE [FindingSeverity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,[DatabaseId];
        SELECT N'Quellenstatus' AS [Ergebnis],[SourceName] AS [Quelle],[StatusCode] AS [Status],[Detail] AS [Hinweis]
        FROM [#EncryptionAnalysis_SourceStatus] ORDER BY [SourceName];
        SELECT N'Datenbankwarnung' AS [Ergebnis],[RequestedName] AS [Datenbank],[StatusCode] AS [Status],[ErrorMessage] AS [Meldung]
        FROM [#EncryptionAnalysis_DatabaseCandidateWarnings] ORDER BY [RequestedName];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#EncryptionAnalysis_Encryption'
            , @ResultLabel=N'EncryptionAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#EncryptionAnalysis_Encryption'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
