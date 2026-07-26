USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 185_P2_Encryption_Runtime_Contract.sql
Zweck        : Automatisiert die sieben noch offenen P2-Encryption-Verträge.
Datenschutz  : Keine Schlüsselpfade, Thumbprints, Werte, Medien oder Konten.
Nebenwirkung : Nur ein kurzlebiger synthetischer Datenbankbenutzer.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ExecutedCases TABLE([CaseId] varchar(64) NOT NULL PRIMARY KEY);
DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit,@Definition nvarchar(max);
DECLARE @Impersonating bit=0;

SELECT @Definition=[sm].[definition]
FROM [sys].[sql_modules] [sm] WITH (NOLOCK)
JOIN [sys].[objects] [o] WITH (NOLOCK) ON [o].[object_id]=[sm].[object_id]
JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
WHERE [s].[name]=N'monitor' AND [o].[name]=N'USP_EncryptionAnalysis';
IF @Definition IS NULL THROW 55900,N'Encryption-Proceduredefinition ist nicht sichtbar.',1;

/* Synthetische Zustandsmatrix entspricht der dokumentierten CASE-Priorität. */
DECLARE @States TABLE
(
      [CaseId] varchar(64) NOT NULL PRIMARY KEY
    , [EncryptionScanState] int NULL
    , [EncryptionState] int NULL
    , [TransitionOld] bit NOT NULL
    , [IsEncrypted] bit NOT NULL
    , [EncryptorType] nvarchar(32) NULL
    , [ProtectorVisible] bit NOT NULL
    , [CertificateInWindow] bit NOT NULL
    , [ExportVisible] bit NOT NULL
    , [ExpectedCode] varchar(100) NOT NULL
);
INSERT @States VALUES
      ('ENC-TRANSITION',0,2,1,1,N'CERTIFICATE',1,0,1,'TDE_TRANSITION_LONG_RUNNING')
    , ('ENC-SUSPENDED',2,3,0,1,N'CERTIFICATE',1,0,1,'TDE_SCAN_SUSPENDED')
    , ('ENC-CERT-WINDOW',0,3,0,1,N'CERTIFICATE',1,1,1,'TDE_CERTIFICATE_EXPIRY_WINDOW')
    , ('ENC-EXPORT-EVIDENCE',0,3,0,1,N'CERTIFICATE',1,0,0,'LOCAL_CERTIFICATE_EXPORT_EVIDENCE_MISSING');

IF EXISTS
(
    SELECT 1 FROM @States
    WHERE [ExpectedCode]<>CASE
          WHEN [EncryptionScanState]=3 THEN 'TDE_SCAN_ABORTED'
          WHEN [EncryptionScanState]=2 THEN 'TDE_SCAN_SUSPENDED'
          WHEN [EncryptionState] IN(2,4,5,6) AND [TransitionOld]=1 THEN 'TDE_TRANSITION_LONG_RUNNING'
          WHEN [IsEncrypted]=1 AND [EncryptorType]=N'CERTIFICATE' AND [ProtectorVisible]=0 THEN 'TDE_PROTECTOR_NOT_VISIBLE'
          WHEN [IsEncrypted]=1 AND [CertificateInWindow]=1 THEN 'TDE_CERTIFICATE_EXPIRY_WINDOW'
          WHEN [IsEncrypted]=1 AND [EncryptorType]=N'CERTIFICATE' AND [ExportVisible]=0 THEN 'LOCAL_CERTIFICATE_EXPORT_EVIDENCE_MISSING'
          WHEN [IsEncrypted]=1 THEN 'TDE_METADATA_CONSISTENT'
          ELSE 'DATABASE_NOT_TDE_ENCRYPTED' END
)
    THROW 55901,N'P2-TDE-Zustandspriorität ist inkonsistent.',1;

IF CHARINDEX(N'''TDE_TRANSITION_LONG_RUNNING''',@Definition)=0
   OR CHARINDEX(N'''TDE_SCAN_SUSPENDED''',@Definition)=0
   OR CHARINDEX(N'''TDE_SCAN_ABORTED''',@Definition)=0
   OR CHARINDEX(N'''TDE_CERTIFICATE_EXPIRY_WINDOW''',@Definition)=0
   OR CHARINDEX(N'''LOCAL_CERTIFICATE_EXPORT_EVIDENCE_MISSING''',@Definition)=0
    THROW 55902,N'TDE-, Zertifikat- oder Exportvertrag fehlt in der Procedure.',1;
INSERT @ExecutedCases SELECT [CaseId] FROM @States;

/* ENC-BACKUP-EXPLICIT: realer Read-only-Pfad auf der synthetischen Installationsdatenbank. */
EXEC [monitor].[USP_EncryptionAnalysis]
     @DatabaseNames=N'[DeineDatenbank]',@ExpliziteBackupverschluesselungErwartet=1,
     @BackupLookbackDays=1,@MaxZeilen=0,@ResultSetArt='NONE',
     @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;
IF ISJSON(@Json)<>1
   OR NOT EXISTS
      (
          SELECT 1 FROM OPENJSON(@Json,N'$.databases')
          WITH ([FindingCode] varchar(100) N'$.FindingCode')
          WHERE [FindingCode] IN('FULL_BACKUP_EVIDENCE_MISSING','EXPLICIT_BACKUP_ENCRYPTION_MISSING')
      )
    THROW 55903,N'P2-Vertrag ENC-BACKUP-EXPLICIT fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('ENC-BACKUP-EXPLICIT');

/* ENC-AE-AGGREGATE */
IF CHARINDEX(N'[ColumnMasterKeyCount]',@Definition)=0
   OR CHARINDEX(N'[ColumnEncryptionKeyCount]',@Definition)=0
   OR CHARINDEX(N'[EncryptedColumnCount]',@Definition)=0
   OR CHARINDEX(N'[sys].[column_master_keys]',@Definition)=0
   OR CHARINDEX(N'[sys].[column_encryption_keys]',@Definition)=0
   OR CHARINDEX(N'[encryption_type]',@Definition)=0
    THROW 55904,N'P2-Vertrag ENC-AE-AGGREGATE fehlt.',1;
INSERT @ExecutedCases VALUES('ENC-AE-AGGREGATE');

/* ENC-DENIED */
IF USER_ID(N'ExampleEncryptionRestrictedUser') IS NOT NULL
    DROP USER [ExampleEncryptionRestrictedUser];
CREATE USER [ExampleEncryptionRestrictedUser] WITHOUT LOGIN;
GRANT EXECUTE ON OBJECT::[monitor].[USP_EncryptionAnalysis] TO [ExampleEncryptionRestrictedUser];

SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXECUTE AS USER=N'ExampleEncryptionRestrictedUser';
SET @Impersonating=1;
EXEC [monitor].[USP_EncryptionAnalysis]
     @DatabaseNames=N'[DeineDatenbank]',@MaxZeilen=10,
     @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;
REVERT;
SET @Impersonating=0;

IF ISJSON(@Json)<>1 OR @Partial<>1 OR @Status NOT IN('AVAILABLE_LIMITED','DENIED_PERMISSION','ERROR_HANDLED')
   OR NOT EXISTS
      (
          SELECT 1 FROM OPENJSON(@Json,N'$.sources')
          WITH ([StatusCode] varchar(40) N'$.StatusCode',[IsPartial] bit N'$.IsPartial')
          WHERE [IsPartial]=1 AND [StatusCode] IN('DENIED_PERMISSION','ERROR_HANDLED')
      )
    THROW 55905,N'P2-Vertrag ENC-DENIED fehlgeschlagen.',1;
DROP USER [ExampleEncryptionRestrictedUser];
INSERT @ExecutedCases VALUES('ENC-DENIED');

IF CHARINDEX(N'[protectorthumbprint]',LOWER(@Definition))>0
   OR CHARINDEX(N'[private_key]',LOWER(@Definition))>0
   OR CHARINDEX(N'[physical_device_name]',LOWER(@Definition))>0
   OR CHARINDEX(N'[user_name]',LOWER(@Definition))>0
    THROW 55906,N'Encryption-Privacy-Vertrag verletzt.',1;

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>7
    THROW 55907,N'Der P2-Encryption-Vertrag hat nicht alle sieben offenen Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'Sieben offene P2-Encryption-Fälle wurden ohne Schlüssel- oder Medienzugriff geprüft.' AS [Detail]
FROM @ExecutedCases;
GO
