# Referenzhandbuch der öffentlichen Procedures

Stand: 2026-07-23

`@ResultSetArt` verwendet frameworkweit `CONSOLE` als Default. Technische Verbraucher setzen `RAW` oder die benannte Mehrfachzuordnung `TABLE` mit `@ResultTablesJson`; JSON-only verwendet `NONE` mit `@JsonErzeugen = 1`. Die Signaturen werden aus dem kanonischen Codebestand abgeleitet.

## `[monitor].[USP_AgentJobs]`

Quelle: `Code/07_Infrastructure/020_USP_AgentJobs.sql`

```sql
@JobNames          nvarchar(max)  = NULL
    , @JobNamePattern    nvarchar(4000) = NULL
    , @NurProblematisch  bit            = 0
    , @LongRunningMinutes int           = 60
    , @MaxZeilen         int            = 2000
    , @ResultSetArt      varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen      bit            = 0
    , @Json              nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen    bit            = 1
    , @Hilfe             bit            = 0
```

## `[monitor].[USP_AgentMonitoringAnalysis]`

Quelle: `Code/07_Infrastructure/120_USP_AgentMonitoringAnalysis.sql`

```sql
@HistoryHours       int             = 24
    , @MitJobStatus       bit             = 1
    , @MitDatabaseMail    bit             = 1
    , @MaxZeilen          int             = 1000
    , @ResultSetArt       varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen       bit             = 0
    , @Json               nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen     bit             = 1
    , @Hilfe              bit             = 0
    , @StatusCodeOut      varchar(40)     = NULL OUTPUT
    , @IsPartialOut       bit             = NULL OUTPUT
    , @ErrorNumberOut     int             = NULL OUTPUT
    , @ErrorMessageOut    nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_AgentStatus]`

Quelle: `Code/07_Infrastructure/010_USP_AgentStatus.sql`

```sql
@ResultSetArt   varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen   bit            = 0
    , @Json           nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen bit            = 1
    , @Hilfe          bit            = 0
```

## `[monitor].[USP_AnalysisNavigator]`

Quelle: `Code/01_Common/100_USP_AnalysisNavigator.sql`

```sql
@Suchbegriff       nvarchar(4000) = NULL
    , @Bereich           varchar(40)    = NULL
    , @Scope             varchar(40)    = NULL
    , @Navigationsrolle  varchar(24)    = NULL
    , @NurInstallierte   bit            = 0
    , @MaxZeilen         int            = 12
    , @ResultSetArt      varchar(16)    = 'CONSOLE'
    , @ResultTablesJson  nvarchar(max)  = NULL
    , @JsonErzeugen      bit            = 0
    , @Json              nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen    bit            = 1
    , @Hilfe             bit            = 0
```

## `[monitor].[USP_AvailabilityDeepAnalysis]`

Quelle: `Code/07_Infrastructure/110_USP_AvailabilityDeepAnalysis.sql`

```sql
@QueueWarnMb              bigint          = 1024
    , @SecondaryLagWarnSeconds  int             = 60
    , @MitClusterNetzwerken     bit             = 0
    , @MaxZeilen                int             = 1000
    , @ResultSetArt             varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen             bit             = 0
    , @Json                     nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen           bit             = 1
    , @Hilfe                    bit             = 0
    , @StatusCodeOut            varchar(40)     = NULL OUTPUT
    , @IsPartialOut             bit             = NULL OUTPUT
    , @ErrorNumberOut           int             = NULL OUTPUT
    , @ErrorMessageOut          nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_AvailabilityGroups]`

Quelle: `Code/07_Infrastructure/040_USP_AvailabilityGroups.sql`

```sql
@MitRouting bit=1
    , @MaxZeilen int=5000
    , @ResultSetArt varchar(16)='CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen bit=0
    , @Json nvarchar(max)=NULL OUTPUT
    , @PrintMeldungen bit=1
    , @Hilfe bit=0
```

## `[monitor].[USP_BackupChainAnalysis]`

Quelle: `Code/07_Infrastructure/100_USP_BackupChainAnalysis.sql`

```sql
@DatabaseNames                nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen bit            = 0
    , @DatabaseNamePattern          nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @HistoryDays                  int            = 35
    , @MitRestoreEvidence           bit            = 1
    , @MaxZeilen                    int            = 1000
    , @ResultSetArt                 varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                 bit            = 0
    , @Json                         nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen               bit            = 1
    , @Hilfe                        bit            = 0
    , @StatusCodeOut                varchar(40)    = NULL OUTPUT
    , @IsPartialOut                 bit            = NULL OUTPUT
    , @ErrorNumberOut               int            = NULL OUTPUT
    , @ErrorMessageOut              nvarchar(2048) = NULL OUTPUT
```

## `[monitor].[USP_BackupRecovery]`

Quelle: `Code/07_Infrastructure/050_USP_BackupRecovery.sql`

```sql
@DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @FullWarnHours                  int            = 48
    , @DiffWarnHours                  int            = 24
    , @LogWarnMinutes                 int            = 30
    , @MitRestoreHistory              bit            = 1
    , @MaxZeilen                      int            = 5000
    , @ResultSetArt                   varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                   bit            = 0
    , @Json                           nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                 bit            = 1
    , @Hilfe                          bit            = 0
```

## `[monitor].[USP_BufferPoolAnalysis]`

Quelle: `Code/08_ServerHealth/160_USP_BufferPoolAnalysis.sql`

```sql
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
```

## `[monitor].[USP_CheckAnalyseAccess]`

Quelle: `Code/01_Common/050_USP_CheckAnalyseAccess.sql`

```sql
@AnalyseKlasse   varchar(64)    = NULL
    , @NurGesperrte    bit            = 0
    , @ResultSetArt    varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen    bit             = 0
    , @Json             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen  bit             = 1
    , @Hilfe            bit             = 0
```

## `[monitor].[USP_CheckFrameworkCapabilities]`

Quelle: `Code/01_Common/070_USP_CheckFrameworkCapabilities.sql`

```sql
@DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @AnalyseKlasse                    varchar(64)     = NULL
    , @NurNichtVerfuegbar               bit            = 0
    , @MitGruppenpruefung               bit            = 1
    , @ResultSetArt                     varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit             = 0
    , @Json                              nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit             = 1
    , @Hilfe                             bit             = 0
```

## `[monitor].[USP_Columnstore]`

Quelle: `Code/03_ObjectIndex/060_USP_Columnstore.sql`

```sql
@DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                    nvarchar(max)  = NULL
    , @SchemaNamePattern              nvarchar(4000) = NULL
    , @ObjectNames                    nvarchar(max)  = NULL
    , @ObjectNamePattern              nvarchar(4000) = NULL
    , @FullObjectNames                nvarchar(max)  = NULL
    , @AnalyseModus                  varchar(16)   = 'GEZIELT'
    , @MitPhysicalStats               bit           = 0
    , @MitSegmenten                   bit           = 0
    , @MitDictionaries                bit           = 0
    , @MinDeletedPercent              decimal(9,2)  = 0
    , @NurProblematisch               bit           = 0
    , @MaxZeilen                      int           = 10000
    , @LockTimeoutMs                  int           = 0
    , @ResultSetArt                  varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                  bit            = 0
    , @Json                          nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                 bit           = 1
    , @Hilfe                          bit           = 0
```

## `[monitor].[USP_CriticalEngineEvents]`

Quelle: `Code/08_ServerHealth/140_USP_CriticalEngineEvents.sql`

```sql
@SourceExtendedEventSessionName nvarchar(258) = N'system_health'
    , @FilePath                        nvarchar(4000) = NULL
    , @VonUtc                          datetime2(7)   = NULL
    , @BisUtc                          datetime2(7)   = NULL
    , @MinErrorSeverity                tinyint         = 20
    , @MitSystemHealth                 bit             = 1
    , @MitServerDiagnostics            bit             = 0
    , @MitEventXml                     bit             = 0
    , @MaxZeilen                       int             = 500
    , @ResultSetArt                    varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                    bit             = 0
    , @Json                            nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                  bit             = 1
    , @Hilfe                           bit             = 0
    , @StatusCodeOut                   varchar(40)     = NULL OUTPUT
    , @IsPartialOut                    bit             = NULL OUTPUT
    , @ErrorNumberOut                  int             = NULL OUTPUT
    , @ErrorMessageOut                 nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_CurrentBlocking]`

Quelle: `Code/02_CurrentState/030_USP_CurrentBlocking.sql`

```sql
@SessionIds                 nvarchar(max)  = NULL
    , @MinWaitMs                  bigint         = 0
    , @SystemSessionsEinbeziehen  bit            = 0
    , @ToolHintergrundabfragenEinbeziehen bit     = 0
    , @MitSqlText                 bit            = 1
    , @MaxSqlTextZeichen          int            = 3000
    , @BlockingObjektTiefe        varchar(16)    = 'STANDARD'
    , @MaxObjektAufloesungen      int            = 100
    , @MitLockDetails             bit            = 0
    , @HighImpactConfirmed        bit            = 0
    , @MaxZeilen                  int            = 1000
    , @ResultSetArt               varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen               bit             = 0
    , @Json                       nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen             bit             = 1
    , @Hilfe                      bit             = 0
    , @ParentCurrentStateSnapshotId uniqueidentifier = NULL
```

## `[monitor].[USP_CurrentIO]`

Quelle: `Code/02_CurrentState/080_USP_CurrentIO.sql`

```sql
@DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MinLatencyMs                   decimal(19,3)  = 0
    , @SampleSeconds                  tinyint         = 0
    , @PendingIoEinbeziehen           bit             = 1
    , @NurWiederholtPending           bit             = 0
    , @MinPendingIoMs                 bigint          = 0
    , @PhysischePfadeEinbeziehen      bit             = 0
    , @MaxZeilen                      int             = 1000
    , @ResultSetArt                   varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max)   = NULL
    , @JsonErzeugen                   bit             = 0
    , @Json                           nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                 bit             = 1
    , @Hilfe                          bit             = 0
    , @ParentCurrentStateSnapshotId   uniqueidentifier = NULL
```

## `[monitor].[USP_CurrentLog]`

Quelle: `Code/02_CurrentState/090_USP_CurrentLog.sql`

```sql
@DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MinUsedPercent                   decimal(5,2)   = NULL
    , @MitVlfInformationen              bit            = 0
    , @MitPersistentVersionStore        bit            = 0
    , @MaxZeilen                        int            = 1000
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
```

## `[monitor].[USP_CurrentMemoryGrants]`

Quelle: `Code/02_CurrentState/060_USP_CurrentMemoryGrants.sql`

```sql
@SessionIds                   nvarchar(max)  = NULL
    , @AktuelleSessionEinbeziehen   bit            = 0
    , @NurWartende                  bit            = 0
    , @MinRequestedMb               decimal(19,2)  = NULL
    , @MinGrantedMb                 decimal(19,2)  = NULL
    , @MitSqlText                   bit            = 1
    , @MaxSqlTextZeichen            int            = 3000
    , @MaxZeilen                    int            = 1000
    , @ResultSetArt                 varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                 bit            = 0
    , @Json                         nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen               bit            = 1
    , @Hilfe                        bit            = 0
    , @ParentCurrentStateSnapshotId uniqueidentifier = NULL
```

## `[monitor].[USP_CurrentOverview]`

Quelle: `Code/02_CurrentState/100_USP_CurrentOverview.sql`

```sql
@SessionIds                    nvarchar(max)  = NULL
    , @DatabaseNames                 nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen  bit            = 0
    , @DatabaseNamePattern           nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @ToolHintergrundabfragenEinbeziehen bit          = 0
    , @Detailgrad                    varchar(16)     = 'SUMMARY'
    , @MitSessions                   bit             = 1
    , @MitRequests                   bit             = 1
    , @MitBlocking                   bit             = 1
    , @BlockingObjektTiefe           varchar(16)     = 'STANDARD'
    , @MaxObjektAufloesungen         int             = 100
    , @MitWaits                      bit             = 1
    , @MitTransactions               bit             = 1
    , @MitMemoryGrants               bit             = 1
    , @MitTempDB                     bit             = 1
    , @MitIO                         bit             = 1
    , @MitLog                        bit             = 1
    , @MitSqlText                    bit             = 1
    , @GesamtenSqlTextEinbeziehen    bit             = 0
    , @InputBufferEinbeziehen        bit             = 0
    , @ModulInfoEinbeziehen          bit             = 1
    , @MaxSqlTextZeichen             int             = 4000
    , @SampleSeconds                 tinyint         = 0
    , @MaxZeilen                     int             = 500
    , @ResultSetArt                  varchar(16)     = 'CONSOLE'
    , @ResultTablesJson              nvarchar(max)   = NULL
    , @JsonErzeugen                  bit             = 0
    , @Json                          nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                bit             = 1
    , @Hilfe                         bit             = 0
```

## `[monitor].[USP_CurrentRequests]`

Quelle: `Code/02_CurrentState/020_USP_CurrentRequests.sql`

```sql
@SessionIds                    nvarchar(max)  = NULL
    , @EigeneSessionsModus           varchar(16)    = 'ALLE'
    , @AktuelleSessionEinbeziehen    bit            = 0
    , @SystemSessionsEinbeziehen     bit            = 0
    , @ToolHintergrundabfragenEinbeziehen bit        = 0
    , @NurBlockierte                 bit            = 0
    , @NurMitWait                    bit            = 0
    , @MinLaufzeitSekunden           int            = NULL
    , @MinCpuMs                      bigint         = NULL
    , @MinLogicalReads               bigint         = NULL
    , @LoginNames                    nvarchar(max)  = NULL
    , @LoginNamePattern              nvarchar(4000) = NULL
    , @HostNames                     nvarchar(max)  = NULL
    , @HostNamePattern               nvarchar(4000) = NULL
    , @ProgramNames                  nvarchar(max)  = NULL
    , @ProgramNamePattern            nvarchar(4000) = NULL
    , @DatabaseNames                 nvarchar(max)  = NULL
    , @DatabaseNamePattern           nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @TextPattern                   nvarchar(4000) = NULL
    , @MitSqlText                    bit            = 1
    , @GesamtenSqlTextEinbeziehen    bit            = 0
    , @InputBufferEinbeziehen        bit            = 0
    , @ModulInfoEinbeziehen          bit            = 1
    , @MaxSqlTextZeichen             int            = 4000
    , @MaxZeilen                     int            = 500
    , @Sortierung                    varchar(32)    = 'RELEVANZ'
    , @ResultSetArt                  varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                  bit            = 0
    , @Json                          nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                bit            = 1
    , @Hilfe                         bit            = 0
    , @ParentCurrentStateSnapshotId uniqueidentifier = NULL
```

## `[monitor].[USP_CurrentSessions]`

Quelle: `Code/02_CurrentState/010_USP_CurrentSessions.sql`

```sql
@SessionIds                   nvarchar(max)  = NULL
    , @EigeneSessionsModus          varchar(16)    = 'ALLE'
    , @AktuelleSessionEinbeziehen   bit            = 0
    , @SystemSessionsEinbeziehen    bit            = 0
    , @ToolHintergrundabfragenEinbeziehen bit       = 0
    , @InaktiveSessionsEinbeziehen  bit            = 1
    , @LoginNames                   nvarchar(max)  = NULL
    , @LoginNamePattern             nvarchar(4000) = NULL
    , @HostNames                    nvarchar(max)  = NULL
    , @HostNamePattern              nvarchar(4000) = NULL
    , @ProgramNames                 nvarchar(max)  = NULL
    , @ProgramNamePattern           nvarchar(4000) = NULL
    , @DatabaseNames                nvarchar(max)  = NULL
    , @DatabaseNamePattern          nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MitSqlText                   bit            = 0
    , @MaxSqlTextZeichen            int            = 2000
    , @MaxZeilen                    int            = 500
    , @Sortierung                   varchar(32)    = 'CPU'
    , @ResultSetArt                 varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                 bit            = 0
    , @Json                         nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen               bit            = 1
    , @Hilfe                        bit            = 0
    , @ParentCurrentStateSnapshotId uniqueidentifier = NULL
```

## `[monitor].[USP_CurrentTempDB]`

Quelle: `Code/02_CurrentState/070_USP_CurrentTempDB.sql`

```sql
@SessionIds                 nvarchar(max) = NULL
    , @AktuelleSessionEinbeziehen bit           = 0
    , @MinNettoMb                 decimal(19,2)  = 0
    , @SystemSessionsEinbeziehen  bit           = 0
    , @MitDateien                 bit           = 1
    , @MaxZeilen                  int           = 1000
    , @ResultSetArt               varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen               bit            = 0
    , @Json                       nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen             bit            = 1
    , @Hilfe                      bit            = 0
    , @ParentCurrentStateSnapshotId uniqueidentifier = NULL
```

## `[monitor].[USP_CurrentTransactions]`

Quelle: `Code/02_CurrentState/050_USP_CurrentTransactions.sql`

```sql
@SessionIds                 nvarchar(max) = NULL
    , @MinAlterSekunden           int           = 0
    , @NurSleeping                bit           = 0
    , @SystemSessionsEinbeziehen  bit           = 0
    , @MitSqlText                 bit           = 1
    , @MaxSqlTextZeichen          int           = 3000
    , @MaxZeilen                  int           = 1000
    , @ResultSetArt               varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen               bit            = 0
    , @Json                       nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen             bit            = 1
    , @Hilfe                      bit            = 0
    , @ParentCurrentStateSnapshotId uniqueidentifier = NULL
```

## `[monitor].[USP_CurrentWaits]`

Quelle: `Code/02_CurrentState/040_USP_CurrentWaits.sql`

```sql
@SessionIds                    nvarchar(max)  = NULL
    , @MinWaitMs                    bigint         = 0
    , @WaitTypes                    nvarchar(max)  = NULL
    , @WaitTypePattern              nvarchar(4000) = NULL
    , @WaitGroups                   nvarchar(max)  = NULL
    , @WaitGroupPattern             nvarchar(4000) = NULL
    , @SystemSessionsEinbeziehen    bit            = 0
    , @ToolHintergrundabfragenEinbeziehen bit       = 0
    , @MitSqlText                   bit            = 1
    , @MaxSqlTextZeichen            int            = 2000
    , @SampleSeconds                tinyint        = 0
    , @UnkritischeWaitsEinbeziehen  bit            = 0
    , @TopWaitPercentage            decimal(5,2)   = 95.00
    , @MaxZeilen                    int            = 1000
    , @ResultSetArt                 varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                 bit            = 0
    , @Json                         nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen               bit            = 1
    , @Hilfe                        bit            = 0
    , @ParentCurrentStateSnapshotId uniqueidentifier = NULL
```

## `[monitor].[USP_DatabaseCapacityAnalysis]`

Quelle: `Code/08_ServerHealth/120_USP_DatabaseCapacityAnalysis.sql`

```sql
@DatabaseNames                nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen bit            = 0
    , @DatabaseNamePattern          nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MinVolumeFreePercent         decimal(9,2)   = 10.00
    , @NurProblematisch             bit            = 0
    , @MaxZeilen                    int            = 1000
    , @ResultSetArt                 varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                 bit            = 0
    , @Json                         nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen               bit            = 1
    , @Hilfe                        bit            = 0
    , @StatusCodeOut                varchar(40)    = NULL OUTPUT
    , @IsPartialOut                 bit            = NULL OUTPUT
    , @ErrorNumberOut               int            = NULL OUTPUT
    , @ErrorMessageOut              nvarchar(2048) = NULL OUTPUT
```

## `[monitor].[USP_DatabaseIntegrityAnalysis]`

Quelle: `Code/08_ServerHealth/110_USP_DatabaseIntegrityAnalysis.sql`

```sql
@DatabaseNames                nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen bit            = 0
    , @DatabaseNamePattern          nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @CheckdbWarnHours             int            = 168
    , @BackupHistoryDays            int            = 35
    , @MitPageDetails               bit            = 0
    , @MaxZeilen                    int            = 1000
    , @ResultSetArt                 varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                 bit            = 0
    , @Json                         nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen               bit            = 1
    , @Hilfe                        bit            = 0
    , @StatusCodeOut                varchar(40)    = NULL OUTPUT
    , @IsPartialOut                 bit            = NULL OUTPUT
    , @ErrorNumberOut               int            = NULL OUTPUT
    , @ErrorMessageOut              nvarchar(2048) = NULL OUTPUT
```

## `[monitor].[USP_DataCaptureStatus]`

Quelle: `Code/07_Infrastructure/080_USP_DataCaptureStatus.sql`

```sql
@DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MaxZeilen                        int            = 10000
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
```

## `[monitor].[USP_DataCaptureDeepAnalysis]`

Quelle: `Code/09_VersionAdaptive/070_USP_DataCaptureDeepAnalysis.sql`

```sql
@DatabaseNames                    nvarchar(max)   = NULL
    , @SystemdatenbankenEinbeziehen     bit             = 0
    , @DatabaseNamePattern              nvarchar(4000)  = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                      nvarchar(max)   = NULL
    , @SchemaNamePattern                nvarchar(4000)  = NULL
    , @ObjectNames                      nvarchar(max)   = NULL
    , @ObjectNamePattern                nvarchar(4000)  = NULL
    , @FullObjectNames                  nvarchar(max)   = NULL
    , @NurProblematisch                 bit             = 0
    , @ChangeTrackingClientVersion      bigint          = NULL
    , @CdcLatencyWarnSeconds            bigint          = 300
    , @CdcCleanupGraceMinutes           bigint          = 60
    , @ErrorLookbackHours               int             = 24
    , @ReplicationLatencyWarnSeconds    bigint          = 300
    , @ReplicationPendingCommandWarn    bigint          = 10000
    , @ReplicationAgentStaleWarnMinutes bigint          = 15
    , @MaxZeilen                        int             = 2000
    , @LockTimeoutMs                    int             = 0
    , @ResultSetArt                     varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit             = 0
    , @Json                             nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                   bit             = 1
    , @Hilfe                            bit             = 0
    , @StatusCodeOut                    varchar(40)     = NULL OUTPUT
    , @IsPartialOut                     bit             = NULL OUTPUT
    , @ErrorNumberOut                   int             = NULL OUTPUT
    , @ErrorMessageOut                  nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_DiagnosticFindings]`

Quelle: `Code/08_ServerHealth/170_USP_DiagnosticFindings.sql`

```sql
@DatabaseNames                nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen bit            = 0
    , @DatabaseNamePattern          nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MitIntegritaet               bit            = 1
    , @MitKapazitaet                bit            = 1
    , @MitSpeicher                  bit            = 1
    , @MitBackupketten              bit            = 1
    , @MitAvailability              bit            = 1
    , @MitAgentMonitoring           bit            = 1
    , @MitSchemaDesign              bit            = 0
    , @MitStatistikverteilung       bit            = 0
    , @MitIQP                       bit            = 0
    , @MitContention                bit            = 0
    , @ContentionSampleSeconds      tinyint         = 5
    , @ContentionMinWaitMs          bigint          = 1000
    , @ParentIntegrityJson          nvarchar(max)   = NULL
    , @ParentCapacityJson           nvarchar(max)   = NULL
    , @ParentBufferPoolJson         nvarchar(max)   = NULL
    , @NurAbPrioritaet              varchar(16)     = 'INFO'
    , @MaxZeilen                    int             = 1000
    , @ResultSetArt                 varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                 bit             = 0
    , @Json                         nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen               bit             = 1
    , @Hilfe                        bit             = 0
    , @StatusCodeOut                varchar(40)     = NULL OUTPUT
    , @IsPartialOut                 bit             = NULL OUTPUT
    , @ErrorNumberOut               int             = NULL OUTPUT
    , @ErrorMessageOut              nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_ExtendedEventsAnalysis]`

Quelle: `Code/06_ExtendedEvents/060_USP_ExtendedEventsAnalysis.sql`

```sql
@SourceExtendedEventSessionName nvarchar(258)  = N'system_health'
    , @ExtendedEventSessionNames       nvarchar(max)  = NULL
    , @ExtendedEventSessionNamePattern nvarchar(4000) = NULL
    , @EventNames                      nvarchar(max)  = NULL
    , @EventNamePattern                nvarchar(4000) = NULL
    , @TargetNames                     nvarchar(max)  = NULL
    , @TargetNamePattern               nvarchar(4000) = NULL
    , @Quelle                          varchar(20)    = 'AUTO'
    , @FilePath                        nvarchar(4000) = NULL
    , @VonUtc                          datetime2(7)   = NULL
    , @BisUtc                          datetime2(7)   = NULL
    , @MitSessionInventar              bit            = 1
    , @MitTargetRuntime                bit            = 0
    , @MitEvents                       bit            = 0
    , @MitDeadlocks                    bit            = 0
    , @MitBlockedProcesses             bit            = 0
    , @MaxZeilen                       int            = 100
    , @BestaetigeTargetFlush           bit            = 0
    , @HighImpactConfirmed             bit            = 0
    , @ResultSetArt                    varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                    bit            = 0
    , @Json                            nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                  bit            = 1
    , @Hilfe                           bit            = 0
```

## `[monitor].[USP_ExtendedEventsBlockedProcesses]`

Quelle: `Code/06_ExtendedEvents/040_USP_ExtendedEventsBlockedProcesses.sql`

```sql
@SourceExtendedEventSessionName nvarchar(258)         = NULL
    , @Quelle                  varchar(20)     = 'AUTO'
    , @FilePath                nvarchar(4000)  = NULL
    , @VonUtc                  datetime2(7)    = NULL
    , @BisUtc                  datetime2(7)    = NULL
    , @MaxZeilen              int             = 200
    , @MitReportXml            bit             = 1
    , @MitProcessXml           bit             = 0
    , @BestaetigeTargetFlush   bit             = 0
    , @HighImpactConfirmed     bit             = 0
    , @ResultSetArt                   varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                   bit            = 0
    , @Json                            nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen          bit             = 1
    , @Hilfe                   bit             = 0
```

## `[monitor].[USP_ExtendedEventsDeadlocks]`

Quelle: `Code/06_ExtendedEvents/030_USP_ExtendedEventsDeadlocks.sql`

```sql
@SourceExtendedEventSessionName nvarchar(258)         = N'system_health'
    , @Quelle                  varchar(20)     = 'AUTO'
    , @FilePath                nvarchar(4000)  = NULL
    , @VonUtc                  datetime2(7)    = NULL
    , @BisUtc                  datetime2(7)    = NULL
    , @MaxZeilen               int             = 100
    , @MitDeadlockXml          bit             = 1
    , @MitProcessDetails       bit             = 1
    , @MitResourceDetails      bit             = 1
    , @BestaetigeTargetFlush   bit             = 0
    , @HighImpactConfirmed     bit             = 0
    , @ResultSetArt                   varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                   bit            = 0
    , @Json                            nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen          bit             = 1
    , @Hilfe                   bit             = 0
```

## `[monitor].[USP_ExtendedEventsReadEvents]`

Quelle: `Code/06_ExtendedEvents/020_USP_ExtendedEventsReadEvents.sql`

```sql
@SourceExtendedEventSessionName nvarchar(258)         = N'system_health'
    , @Quelle                  varchar(20)     = 'EVENT_FILE'
    , @FilePath                nvarchar(4000)  = NULL
    , @EventNames              nvarchar(max)   = NULL
    , @EventNamePattern        nvarchar(4000)  = NULL
    , @VonUtc                  datetime2(7)    = NULL
    , @BisUtc                  datetime2(7)    = NULL
    , @MaxZeilen               int             = 1000
    , @MitEventXml             bit             = 1
    , @BestaetigeTargetFlush   bit             = 0
    , @HighImpactConfirmed     bit             = 0
    , @ResultSetArt                   varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                   bit            = 0
    , @Json                            nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen          bit             = 1
    , @Hilfe                   bit             = 0
```

## `[monitor].[USP_ExtendedEventsSessions]`

Quelle: `Code/06_ExtendedEvents/010_USP_ExtendedEventsSessions.sql`

```sql
@ExtendedEventSessionNames       nvarchar(max)  = NULL
    , @ExtendedEventSessionNamePattern nvarchar(4000) = NULL
    , @EventNames                      nvarchar(max)  = NULL
    , @EventNamePattern                nvarchar(4000) = NULL
    , @TargetNames                     nvarchar(max)  = NULL
    , @TargetNamePattern               nvarchar(4000) = NULL
    , @NurLaufend           bit           = 0
    , @MitLaufzeitstatus    bit           = 1
    , @MitEvents            bit           = 1
    , @MitActions           bit           = 1
    , @MitTargets           bit           = 1
    , @MitFeldern           bit           = 0
    , @MaxZeilen            int           = 5000
    , @ResultSetArt                   varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                   bit            = 0
    , @Json                            nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen       bit           = 1
    , @Hilfe                bit           = 0
```

## `[monitor].[USP_ExtendedEventsTargetRuntime]`

Quelle: `Code/06_ExtendedEvents/050_USP_ExtendedEventsTargetRuntime.sql`

```sql
@ExtendedEventSessionNames       nvarchar(max)  = NULL
    , @ExtendedEventSessionNamePattern nvarchar(4000) = NULL
    , @TargetNames                     nvarchar(max)  = NULL
    , @TargetNamePattern               nvarchar(4000) = NULL
    , @MitTargetData           bit           = 0
    , @MaxTargetDataZeichen    int           = 4000
    , @BestaetigeTargetFlush   bit           = 0
    , @HighImpactConfirmed     bit           = 0
    , @ResultSetArt                   varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                   bit            = 0
    , @Json                            nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen          bit           = 1
    , @Hilfe                   bit           = 0
```

## `[monitor].[USP_FullTextAnalysis]`

Quelle: `Code/09_VersionAdaptive/060_USP_FullTextAnalysis.sql`

```sql
@DatabaseNames                    nvarchar(max)   = NULL
    , @SystemdatenbankenEinbeziehen     bit             = 0
    , @DatabaseNamePattern              nvarchar(4000)  = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                      nvarchar(max)   = NULL
    , @SchemaNamePattern                nvarchar(4000)  = NULL
    , @ObjectNames                      nvarchar(max)   = NULL
    , @ObjectNamePattern                nvarchar(4000)  = NULL
    , @FullObjectNames                  nvarchar(max)   = NULL
    , @NurProblematisch                 bit             = 0
    , @PopulationAgeWarnMinutes         bigint          = 60
    , @QueryableFragmentWarn            bigint          = 30
    , @OutstandingBatchWarn             bigint          = 100
    , @FailedDocumentWarn               bigint          = 1
    , @CatalogSizeWarnMb                decimal(19,2)   = 10240
    , @MaxZeilen                        int             = 2000
    , @LockTimeoutMs                    int             = 0
    , @ResultSetArt                     varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit             = 0
    , @Json                             nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                   bit             = 1
    , @Hilfe                            bit             = 0
    , @StatusCodeOut                    varchar(40)     = NULL OUTPUT
    , @IsPartialOut                     bit             = NULL OUTPUT
    , @ErrorNumberOut                   int             = NULL OUTPUT
    , @ErrorMessageOut                  nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_IndexOperationalStats]`

Quelle: `Code/03_ObjectIndex/025_USP_IndexOperationalStats.sql`

```sql
@DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                    nvarchar(max)  = NULL
    , @SchemaNamePattern              nvarchar(4000) = NULL
    , @ObjectNames                    nvarchar(max)  = NULL
    , @ObjectNamePattern              nvarchar(4000) = NULL
    , @FullObjectNames                nvarchar(max)  = NULL
    , @IndexNames                     nvarchar(max)  = NULL
    , @IndexNamePattern               nvarchar(4000) = NULL
    , @AnalyseModus                varchar(16)   = 'GEZIELT'
    , @PartitionNumber             int           = NULL
    , @NurMitAktivitaet            bit           = 1
    , @MinLeafPageAllocations      bigint        = 0
    , @MinLockWaitMs               bigint        = 0
    , @MaxZeilen                   int           = 5000
    , @LockTimeoutMs               int           = 0
    , @ResultSetArt                  varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                  bit            = 0
    , @Json                          nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen              bit           = 1
    , @Hilfe                       bit           = 0
```

## `[monitor].[USP_IndexPhysicalStats]`

Quelle: `Code/03_ObjectIndex/070_USP_IndexPhysicalStats.sql`

```sql
@DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                    nvarchar(max)  = NULL
    , @SchemaNamePattern              nvarchar(4000) = NULL
    , @ObjectNames                    nvarchar(max)  = NULL
    , @ObjectNamePattern              nvarchar(4000) = NULL
    , @FullObjectNames                nvarchar(max)  = NULL
    , @IndexNames                     nvarchar(max)  = NULL
    , @IndexNamePattern               nvarchar(4000) = NULL
    , @AnalyseModus                   varchar(16)   = 'GEZIELT'
    , @ScanMode                       varchar(16)   = 'LIMITED'
    , @IndexId                        int           = NULL
    , @PartitionNumber                int           = NULL
    , @MinPageCount                   bigint        = 1000
    , @MinFragmentationPercent        decimal(9,2)  = 0
    , @MaxZeilen                      int           = 10000
    , @LockTimeoutMs                  int           = 0
    , @ResultSetArt                  varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                  bit            = 0
    , @Json                          nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                 bit           = 1
    , @Hilfe                          bit           = 0
```

## `[monitor].[USP_IndexUsage]`

Quelle: `Code/03_ObjectIndex/020_USP_IndexUsage.sql`

```sql
@DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                    nvarchar(max)  = NULL
    , @SchemaNamePattern              nvarchar(4000) = NULL
    , @ObjectNames                    nvarchar(max)  = NULL
    , @ObjectNamePattern              nvarchar(4000) = NULL
    , @FullObjectNames                nvarchar(max)  = NULL
    , @AnalyseModus                  varchar(16)   = 'GEZIELT'
    , @NurUngenutzt                   bit           = 0
    , @MinUserUpdates                 bigint        = 0
    , @PrimaryUndUniqueEinbeziehen    bit           = 1
    , @MitMemoryOptimized              bit           = 1
    , @MaxZeilen                      int           = 5000
    , @LockTimeoutMs                  int           = 0
    , @ResultSetArt                  varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                  bit            = 0
    , @Json                          nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                 bit           = 1
    , @Hilfe                          bit           = 0
```

## `[monitor].[USP_InfrastructureAnalysis]`

Quelle: `Code/07_Infrastructure/090_USP_InfrastructureAnalysis.sql`

```sql
@MitAgent                       bit            = 1
    , @MitAgentJobs                   bit            = 1
    , @MitResourceGovernor            bit            = 1
    , @MitAvailabilityGroups          bit            = 1
    , @MitBackupRecovery              bit            = 1
    , @MitLogShipping                 bit            = 1
    , @MitReplication                 bit            = 1
    , @MitDataCapture                 bit            = 1
    , @MitReplicationDetails          bit            = 0
    , @MitBackupChain                 bit            = 0
    , @MitAvailabilityDeep            bit            = 0
    , @MitAgentMonitoring             bit            = 0
    , @DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MaxZeilen                      int            = 2000
    , @ResultSetArt                   varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                   bit            = 0
    , @Json                           nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                 bit            = 1
    , @Hilfe                          bit            = 0
```

## `[monitor].[USP_InMemoryOltpAnalysis]`

Quelle: `Code/09_VersionAdaptive/030_USP_InMemoryOltpAnalysis.sql`

```sql
@DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                      nvarchar(max)  = NULL
    , @SchemaNamePattern                nvarchar(4000) = NULL
    , @ObjectNames                      nvarchar(max)  = NULL
    , @ObjectNamePattern                nvarchar(4000) = NULL
    , @FullObjectNames                  nvarchar(max)  = NULL
    , @MitHashIndexStats                bit            = 0
    , @NurProblematisch                 bit            = 0
    , @MinTableMemoryMb                 decimal(19,2)  = 1024
    , @HashAvgChainWarn                 decimal(19,4)  = 10
    , @HashMaxChainWarn                 bigint         = 100
    , @HashMinEmptyBucketPercent        decimal(9,4)   = 10
    , @WaitingCheckpointWarnMb          decimal(19,2)  = 1024
    , @ActiveTransactionWarnCount       int            = 100
    , @PoolUsedWarnPercent              decimal(9,4)   = 80
    , @MaxZeilen                        int            = 2000
    , @LockTimeoutMs                    int            = 0
    , @ResultSetArt                     varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
    , @StatusCodeOut                    varchar(40)     = NULL OUTPUT
    , @IsPartialOut                     bit            = NULL OUTPUT
    , @ErrorNumberOut                   int            = NULL OUTPUT
    , @ErrorMessageOut                  nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_IntelligentQueryProcessingAnalysis]`

Quelle: `Code/05_QueryStore/090_USP_IntelligentQueryProcessingAnalysis.sql`

```sql
@DatabaseNames                nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen bit            = 0
    , @DatabaseNamePattern          nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MaxZeilen                    int            = 1000
    , @ResultSetArt                 varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                 bit            = 0
    , @Json                         nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen               bit            = 1
    , @Hilfe                        bit            = 0
    , @StatusCodeOut                varchar(40)    = NULL OUTPUT
    , @IsPartialOut                 bit            = NULL OUTPUT
    , @ErrorNumberOut               int            = NULL OUTPUT
    , @ErrorMessageOut              nvarchar(2048) = NULL OUTPUT
```

## `[monitor].[USP_InternalContentionAnalysis]`

Quelle: `Code/08_ServerHealth/150_USP_InternalContentionAnalysis.sql`

```sql
@SampleSeconds     tinyint        = 5
    , @MitSpinlocks      bit            = 1
    , @MitHotPages       bit            = 1
    , @MitPageDetails    bit            = 0
    , @MaxZeilen         int            = 100
    , @ResultSetArt      varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen      bit            = 0
    , @Json              nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen    bit            = 1
    , @Hilfe             bit            = 0
    , @StatusCodeOut     varchar(40)    = NULL OUTPUT
    , @IsPartialOut      bit            = NULL OUTPUT
    , @ErrorNumberOut    int            = NULL OUTPUT
    , @ErrorMessageOut   nvarchar(2048) = NULL OUTPUT
```

## `[monitor].[USP_LogShippingStatus]`

Quelle: `Code/07_Infrastructure/060_USP_LogShippingStatus.sql`

```sql
@MaxZeilen int=5000,@ResultSetArt varchar(16)='CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen bit=0,@Json nvarchar(max)=NULL OUTPUT,@PrintMeldungen bit=1,@Hilfe bit=0
```

## `[monitor].[USP_MissingIndexes]`

Quelle: `Code/03_ObjectIndex/030_USP_MissingIndexes.sql`

```sql
@DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                    nvarchar(max)  = NULL
    , @SchemaNamePattern              nvarchar(4000) = NULL
    , @ObjectNames                    nvarchar(max)  = NULL
    , @ObjectNamePattern              nvarchar(4000) = NULL
    , @FullObjectNames                nvarchar(max)  = NULL
    , @MinUserReads                   bigint        = 1
    , @MinAvgUserImpact               decimal(9,2)  = 0
    , @MinImprovementMeasure          decimal(28,2) = 0
    , @MaxZeilen                      int           = 5000
    , @LockTimeoutMs                  int           = 0
    , @ResultSetArt                  varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                  bit            = 0
    , @Json                          nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                 bit           = 1
    , @Hilfe                          bit           = 0
```

## `[monitor].[USP_ObjectAnalysis]`

Quelle: `Code/03_ObjectIndex/080_USP_ObjectAnalysis.sql`

```sql
@DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                      nvarchar(max)  = NULL
    , @SchemaNamePattern                nvarchar(4000) = NULL
    , @ObjectNames                      nvarchar(max)  = NULL
    , @ObjectNamePattern                nvarchar(4000) = NULL
    , @FullObjectNames                  nvarchar(max)  = NULL
    , @IndexNames                       nvarchar(max)  = NULL
    , @IndexNamePattern                 nvarchar(4000) = NULL
    , @StatisticsNames                  nvarchar(max)  = NULL
    , @StatisticsNamePattern            nvarchar(4000) = NULL
    , @Vollanalyse                      bit            = 0
    , @MitObjectInventory               bit            = 1
    , @MitIndexUsage                    bit            = 1
    , @MitMissingIndexes                bit            = 1
    , @MitOperationalStats              bit            = 0
    , @MitStatistics                    bit            = 0
    , @MitStatisticsDistribution        bit            = 0
    , @MitPartitions                    bit            = 0
    , @MitColumnstore                   bit            = 0
    , @MitPhysicalStats                 bit            = 0
    , @MitVectorIndexes                 bit            = 0
    , @MitSchemaDesign                  bit            = 0
    , @MaxZeilen                        int            = 2000
    , @LockTimeoutMs                    int            = 0
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
```

## `[monitor].[USP_ObjectInventory]`

Quelle: `Code/03_ObjectIndex/010_USP_ObjectInventory.sql`

```sql
@DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                    nvarchar(max)  = NULL
    , @SchemaNamePattern              nvarchar(4000) = NULL
    , @ObjectNames                    nvarchar(max)  = NULL
    , @ObjectNamePattern              nvarchar(4000) = NULL
    , @FullObjectNames                nvarchar(max)  = NULL
    , @ObjectType                     varchar(16)   = 'TABLE'
    , @AnalyseModus                   varchar(16)   = 'GEZIELT'
    , @MitIndizes                     bit           = 1
    , @MitSpaltenlisten               bit           = 1
    , @MaxZeilen                      int           = 5000
    , @LockTimeoutMs                  int           = 0
    , @ResultSetArt                  varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                  bit            = 0
    , @Json                          nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                 bit           = 1
    , @Hilfe                          bit           = 0
```

## `[monitor].[USP_OSInformation]`

Quelle: `Code/08_ServerHealth/080_USP_OSInformation.sql`

```sql
@PrintMeldungen bit=1,@Hilfe bit=0,@ResultSetArt varchar(16)='CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen bit=0,@Json nvarchar(max)=NULL OUTPUT,
 @StatusCodeOut varchar(40)=NULL OUTPUT,@IsPartialOut bit=NULL OUTPUT,@ErrorNumberOut int=NULL OUTPUT,@ErrorMessageOut nvarchar(2048)=NULL OUTPUT
```

## `[monitor].[USP_Partitions]`

Quelle: `Code/03_ObjectIndex/050_USP_Partitions.sql`

```sql
@DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                    nvarchar(max)  = NULL
    , @SchemaNamePattern              nvarchar(4000) = NULL
    , @ObjectNames                    nvarchar(max)  = NULL
    , @ObjectNamePattern              nvarchar(4000) = NULL
    , @FullObjectNames                nvarchar(max)  = NULL
    , @AnalyseModus                   varchar(16)   = 'GEZIELT'
    , @NurPartitionierte              bit           = 0
    , @NurGemischteKompression        bit           = 0
    , @MaxZeilen                      int           = 10000
    , @LockTimeoutMs                  int           = 0
    , @ResultSetArt                  varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                  bit            = 0
    , @Json                          nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                 bit           = 1
    , @Hilfe                          bit           = 0
```

## `[monitor].[USP_PerformanceCounters]`

Quelle: `Code/08_ServerHealth/130_USP_PerformanceCounters.sql`

```sql
@ObjectNames       nvarchar(max)  = NULL
    , @CounterNames      nvarchar(max)  = NULL
    , @SampleSeconds     tinyint         = 0
    , @MaxZeilen         int             = 1000
    , @ResultSetArt      varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen      bit             = 0
    , @Json              nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen    bit             = 1
    , @Hilfe             bit             = 0
    , @StatusCodeOut     varchar(40)     = NULL OUTPUT
    , @IsPartialOut      bit             = NULL OUTPUT
    , @ErrorNumberOut    int             = NULL OUTPUT
    , @ErrorMessageOut   nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_PlanCacheAnalysis]`

Quelle: `Code/04_PlanCache/060_USP_PlanCacheAnalysis.sql`

```sql
@MitQueryStats                    bit            = 1
    , @MitQueryHashAnalysis             bit            = 0
    , @MitPlanCacheHealth               bit            = 0
    , @MitShowplanAnalysis              bit            = 0
    , @DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @QueryHash                        binary(8)      = NULL
    , @QueryPlanHash                    binary(8)      = NULL
    , @PlanHandle                       varbinary(64)  = NULL
    , @TextPattern                      nvarchar(4000) = NULL
    , @Sortierung                       varchar(32)    = 'CPU_TOTAL'
    , @AnalyseModus                     varchar(16)    = 'TOP'
    , @MaxZeilen                        int            = 100
    , @MaxAnalyseobjekte                int            = 20
    , @MaxDurationSeconds               int            = 30
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
```

## `[monitor].[USP_PlanCacheHealth]`

Quelle: `Code/04_PlanCache/030_USP_PlanCacheHealth.sql`

```sql
@AnalyseModus               varchar(16) = 'SUMMARY'
    , @MitDatenbankVerteilung     bit         = 0
    , @MitSingleUseDetails        bit         = 0
    , @MaxZeilen                  int         = 100
    , @HighImpactConfirmed        bit         = 0
    , @MaxSqlTextZeichen          int         = 4000
    , @ResultSetArt               varchar(16) = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen               bit         = 0
    , @Json                        nvarchar(max) = NULL OUTPUT
    , @PrintMeldungen             bit         = 1
    , @Hilfe                      bit         = 0
```

## `[monitor].[USP_PlanDetails]`

Quelle: `Code/04_PlanCache/040_USP_PlanDetails.sql`

```sql
@SessionIds            nvarchar(max)  = NULL
    , @PlanHandle            varbinary(64)  = NULL
    , @SqlHandle             varbinary(64)  = NULL
    , @QueryHash             binary(8)      = NULL
    , @MitPlanAttributes     bit            = 1
    , @MitCompilePlan        bit            = 1
    , @MitTextPlan           bit            = 0
    , @MitLastActualPlan     bit            = 0
    , @MitLivePlan           bit            = 0
    , @MaxAnalyseobjekte      int            = 20
    , @HighImpactConfirmed   bit            = 0
    , @MaxSqlTextZeichen     int            = 8000
    , @ResultSetArt          varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen          bit            = 0
    , @Json                   nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen        bit            = 1
    , @Hilfe                 bit            = 0
```

## `[monitor].[USP_PrepareDatabaseCandidates]`

Quelle: `Code/01_Common/083_USP_PrepareDatabaseCandidates.sql`

```sql
@DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @AnalysisClass                    varchar(64)    = NULL
    , @HighImpactConfirmed              bit            = 0
    , @StatusCode                       varchar(40)    OUTPUT
    , @ErrorMessage                     nvarchar(2048) OUTPUT
    , @CrossDatabaseRequested           bit            OUTPUT
    , @CandidateTable                   sysname        = N'#PrepareDatabaseCandidates_Result'
    , @WarningTable                     sysname        = NULL
```

## `[monitor].[USP_PrepareNameFilters]`

Quelle: `Code/01_Common/084_USP_PrepareNameFilters.sql`

```sql
@SchemaNames       nvarchar(max)  = NULL
    , @ObjectNames       nvarchar(max)  = NULL
    , @FullObjectNames   nvarchar(max)  = NULL
    , @IndexNames        nvarchar(max)  = NULL
    , @StatisticsNames   nvarchar(max)  = NULL
    , @ColumnNames       nvarchar(max)  = NULL
    , @StatusCode        varchar(40)    OUTPUT
    , @ErrorMessage      nvarchar(2048) OUTPUT
    , @FilterTable       sysname        = N'#PrepareNameFilters_Result'
```

## `[monitor].[USP_QueryHashAnalysis]`

Quelle: `Code/04_PlanCache/020_USP_QueryHashAnalysis.sql`

```sql
@QueryHash           binary(8)   = NULL
    , @Sortierung              varchar(32) = 'CPU_TOTAL'
    , @AnalyseModus        varchar(16) = 'TOP'
    , @MinExecutionCount   bigint      = 1
    , @MinPlanVarianten    int         = 1
    , @MaxZeilen           int         = 100
    , @MaxSqlTextZeichen   int         = 4000
    , @ParentQueryStatsSnapshot bit    = 0
    , @HighImpactConfirmed bit         = 0
    , @ResultSetArt        varchar(16) = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen        bit         = 0
    , @Json                 nvarchar(max) = NULL OUTPUT
    , @PrintMeldungen      bit         = 1
    , @Hilfe               bit         = 0
```

## `[monitor].[USP_QueryStats]`

Quelle: `Code/04_PlanCache/010_USP_QueryStats.sql`

```sql
@DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @QueryHash                      binary(8)      = NULL
    , @QueryPlanHash                  binary(8)      = NULL
    , @SqlHandle                      varbinary(64)  = NULL
    , @PlanHandle                     varbinary(64)  = NULL
    , @TextPattern                    nvarchar(4000) = NULL
    , @Sortierung                     varchar(32)    = 'CPU_TOTAL'
    , @AnalyseModus                   varchar(16)    = 'TOP'
    , @MinExecutionCount              bigint         = 1
    , @VonUtc                         datetime2(7)    = NULL
    , @MaxZeilen                      int            = 100
    , @MaxSqlTextZeichen              int            = 4000
    , @ParentQueryStatsSnapshot       bit            = 0
    , @ResultSetArt                   varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                   bit            = 0
    , @Json                           nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                 bit            = 1
    , @Hilfe                          bit            = 0
```

## `[monitor].[USP_QueryStoreAnalysis]`

Quelle: `Code/05_QueryStore/080_USP_QueryStoreAnalysis.sql`

```sql
@QueryStoreDatabaseNames          nvarchar(max)  = NULL
    , @QueryStoreDatabaseNamePattern    nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @ReferencedDatabaseNames          nvarchar(max)  = NULL
    , @ReferencedDatabaseNamePattern    nvarchar(4000) = NULL
    , @VonUtc                           datetime2(7)   = NULL
    , @BisUtc                           datetime2(7)   = NULL
    , @MitStatus                        bit            = 1
    , @MitRuntimeStats                  bit            = 1
    , @MitWaitStats                     bit            = 0
    , @MitPlanChanges                   bit            = 0
    , @MitRegressionen                  bit            = 0
    , @MitForcedPlans                   bit            = 0
    , @MitHints                         bit            = 0
    , @MitIQP                           bit            = 0
    , @MaxZeilen                        int            = 100
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
```

## `[monitor].[USP_QueryStoreForcedPlans]`

Quelle: `Code/05_QueryStore/060_USP_QueryStoreForcedPlans.sql`

```sql
@QueryStoreDatabaseNames          nvarchar(max)  = NULL
    , @QueryStoreDatabaseNamePattern    nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @ReferencedDatabaseNames          nvarchar(max)  = NULL
    , @ReferencedDatabaseNamePattern    nvarchar(4000) = NULL
    , @QueryId                          bigint         = NULL
    , @NurMitFehler                     bit            = 0
    , @MitPlanXml                       bit            = 0
    , @MaxZeilen                        int            = 100
    , @MaxSqlTextZeichen                int            = 4000
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
```

## `[monitor].[USP_QueryStoreHints]`

Quelle: `Code/05_QueryStore/070_USP_QueryStoreHints.sql`

```sql
@QueryStoreDatabaseNames          nvarchar(max)  = NULL
    , @QueryStoreDatabaseNamePattern    nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @QueryId                          bigint         = NULL
    , @NurMitFehler                     bit            = 0
    , @MaxZeilen                        int            = 100
    , @MaxSqlTextZeichen                int            = 4000
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
```

## `[monitor].[USP_QueryStorePlanChanges]`

Quelle: `Code/05_QueryStore/040_USP_QueryStorePlanChanges.sql`

```sql
@QueryStoreDatabaseNames          nvarchar(max)  = NULL
    , @QueryStoreDatabaseNamePattern    nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @ReferencedDatabaseNames          nvarchar(max)  = NULL
    , @ReferencedDatabaseNamePattern    nvarchar(4000) = NULL
    , @QueryId                          bigint         = NULL
    , @QueryHash                        binary(8)      = NULL
    , @VonUtc                           datetime2(7)   = NULL
    , @NurMehrerePlaene                 bit            = 1
    , @MitPlanXml                       bit            = 0
    , @AnalyseModus                     varchar(16)    = 'TOP'
    , @MaxZeilen                        int            = 100
    , @MaxSqlTextZeichen                int            = 4000
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
```

## `[monitor].[USP_QueryStoreRegressions]`

Quelle: `Code/05_QueryStore/050_USP_QueryStoreRegressions.sql`

```sql
@QueryStoreDatabaseNames          nvarchar(max)  = NULL
    , @QueryStoreDatabaseNamePattern    nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @ReferencedDatabaseNames          nvarchar(max)  = NULL
    , @ReferencedDatabaseNamePattern    nvarchar(4000) = NULL
    , @QueryId                          bigint         = NULL
    , @QueryHash                        binary(8)      = NULL
    , @BaselineVonUtc                   datetime2(7)   = NULL
    , @BaselineBisUtc                   datetime2(7)   = NULL
    , @VergleichVonUtc                  datetime2(7)   = NULL
    , @VergleichBisUtc                  datetime2(7)   = NULL
    , @Metrik                           varchar(32)    = 'DURATION_AVG'
    , @MinAusfuehrungenJeFenster        bigint         = 1
    , @MinRegressionProzent             decimal(9,2)   = 20.0
    , @AnalyseModus                     varchar(16)    = 'TOP'
    , @MaxZeilen                        int            = 100
    , @MaxSqlTextZeichen                int            = 4000
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
```

## `[monitor].[USP_QueryStoreRuntimeStats]`

Quelle: `Code/05_QueryStore/020_USP_QueryStoreRuntimeStats.sql`

```sql
@QueryStoreDatabaseNames          nvarchar(max)  = NULL
    , @QueryStoreDatabaseNamePattern    nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @ReferencedDatabaseNames          nvarchar(max)  = NULL
    , @ReferencedDatabaseNamePattern    nvarchar(4000) = NULL
    , @QueryId                          bigint         = NULL
    , @QueryHash                        binary(8)      = NULL
    , @TextPattern                      nvarchar(4000) = NULL
    , @VonUtc                           datetime2(7)   = NULL
    , @BisUtc                           datetime2(7)   = NULL
    , @Sortierung                       varchar(32)    = 'CPU_TOTAL'
    , @AnalyseModus                     varchar(16)    = 'TOP'
    , @MaxZeilen                        int            = 100
    , @MitPlanXml                       bit            = 0
    , @MaxSqlTextZeichen                int            = 4000
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
```

## `[monitor].[USP_QueryStoreStatus]`

Quelle: `Code/05_QueryStore/010_USP_QueryStoreStatus.sql`

```sql
@QueryStoreDatabaseNames         nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen    bit            = 0
    , @QueryStoreDatabaseNamePattern   nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @ResultSetArt                    varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                    bit            = 0
    , @Json                            nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                  bit            = 1
    , @Hilfe                           bit            = 0
```

## `[monitor].[USP_QueryStoreWaitStats]`

Quelle: `Code/05_QueryStore/030_USP_QueryStoreWaitStats.sql`

```sql
@QueryStoreDatabaseNames          nvarchar(max)  = NULL
    , @QueryStoreDatabaseNamePattern    nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @ReferencedDatabaseNames          nvarchar(max)  = NULL
    , @ReferencedDatabaseNamePattern    nvarchar(4000) = NULL
    , @QueryId                          bigint         = NULL
    , @QueryHash                        binary(8)      = NULL
    , @WaitCategory                     nvarchar(128)  = NULL
    , @VonUtc                           datetime2(7)   = NULL
    , @BisUtc                           datetime2(7)   = NULL
    , @AnalyseModus                     varchar(16)    = 'TOP'
    , @MaxZeilen                        int            = 100
    , @MaxSqlTextZeichen                int            = 4000
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
```

## `[monitor].[USP_ReplicationStatus]`

Quelle: `Code/07_Infrastructure/070_USP_ReplicationStatus.sql`

```sql
@MitDistributionDetails bit=0,@MaxZeilen int=5000,@HighImpactConfirmed bit=0,@ResultSetArt varchar(16)='CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen bit=0,@Json nvarchar(max)=NULL OUTPUT,@PrintMeldungen bit=1,@Hilfe bit=0
```

## `[monitor].[USP_ResourceGovernorAnalysis]`

Quelle: `Code/07_Infrastructure/030_USP_ResourceGovernorAnalysis.sql`

```sql
@MitSessions       bit            = 1
    , @MaxZeilen         int            = 5000
    , @ResultSetArt      varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen      bit            = 0
    , @Json              nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen    bit            = 1
    , @Hilfe             bit            = 0
```

## `[monitor].[USP_SchemaDesignAnalysis]`

Quelle: `Code/03_ObjectIndex/090_USP_SchemaDesignAnalysis.sql`

```sql
@DatabaseNames                nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen bit            = 0
    , @DatabaseNamePattern          nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @IdentityWarnPercent          decimal(5,2)   = 80.00
    , @MaxZeilen                    int            = 1000
    , @ResultSetArt                 varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                 bit            = 0
    , @Json                         nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen               bit            = 1
    , @Hilfe                        bit            = 0
    , @StatusCodeOut                varchar(40)    = NULL OUTPUT
    , @IsPartialOut                 bit            = NULL OUTPUT
    , @ErrorNumberOut               int            = NULL OUTPUT
    , @ErrorMessageOut              nvarchar(2048) = NULL OUTPUT
```

## `[monitor].[USP_ServerConfiguration]`

Quelle: `Code/08_ServerHealth/050_USP_ServerConfiguration.sql`

```sql
@NurKernparameter bit=1,@PrintMeldungen bit=1,@Hilfe bit=0,@ResultSetArt varchar(16)='CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen bit=0,@Json nvarchar(max)=NULL OUTPUT,
 @StatusCodeOut varchar(40)=NULL OUTPUT,@IsPartialOut bit=NULL OUTPUT,@ErrorNumberOut int=NULL OUTPUT,@ErrorMessageOut nvarchar(2048)=NULL OUTPUT
```

## `[monitor].[USP_ServerCpuTopology]`

Quelle: `Code/08_ServerHealth/010_USP_ServerCpuTopology.sql`

```sql
@PrintMeldungen bit=1,@Hilfe bit=0,@ResultSetArt varchar(16)='CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen bit=0,@Json nvarchar(max)=NULL OUTPUT,
 @StatusCodeOut varchar(40)=NULL OUTPUT,@IsPartialOut bit=NULL OUTPUT,@ErrorNumberOut int=NULL OUTPUT,@ErrorMessageOut nvarchar(2048)=NULL OUTPUT
```

## `[monitor].[USP_ServerFeatureCapabilities]`

Quelle: `Code/09_VersionAdaptive/010_USP_ServerFeatureCapabilities.sql`

```sql
@DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MitSpezialindizes                bit            = 1
    , @MitQueryStoreReplicas            bit            = 1
    , @MitPlattformdetails              bit            = 1
    , @MaxZeilen                        int            = 5000
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
```

## `[monitor].[USP_ServerVersionInformation]`

Quelle: `Code/09_VersionAdaptive/015_USP_ServerVersionInformation.sql`

```sql
@MitDatenbankKompatibilitaet bit            = 0
    , @DatabaseNames                nvarchar(max)  = NULL
    , @DatabaseNamePattern          nvarchar(4000) = NULL
    , @SystemdatenbankenEinbeziehen bit            = 0
    , @MaxZeilen                    int            = 2000
    , @ResultSetArt                 varchar(16)    = 'CONSOLE'
    , @ResultTablesJson             nvarchar(max)  = NULL
    , @JsonErzeugen                 bit            = 0
    , @Json                         nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen               bit            = 1
    , @Hilfe                        bit            = 0
    , @StatusCodeOut                varchar(40)    = NULL OUTPUT
    , @IsPartialOut                 bit            = NULL OUTPUT
    , @ErrorNumberOut               int            = NULL OUTPUT
    , @ErrorMessageOut              nvarchar(2048) = NULL OUTPUT
```

## `[monitor].[USP_ServerHealthAnalysis]`

Quelle: `Code/08_ServerHealth/100_USP_ServerHealthAnalysis.sql`

```sql
@MitCpu           bit           = 1
    , @MitNuma          bit           = 1
    , @MitMemory        bit           = 1
    , @MitTempDB        bit           = 1
    , @MitConfiguration bit           = 1
    , @MitTraceFlags    bit           = 1
    , @MitStartup       bit           = 1
    , @MitOS            bit           = 1
    , @MitSecurity      bit           = 1
    , @MitIntegritaet   bit           = 0
    , @MitKapazitaet    bit           = 0
    , @MitPerformanceCounters bit      = 0
    , @MitCriticalEvents bit           = 0
    , @MitContention    bit           = 0
    , @MitBufferPool    bit           = 0
    , @MitFindings      bit           = 0
    , @DatabaseNames    nvarchar(max) = NULL
    , @SystemdatenbankenEinbeziehen bit = 0
    , @DatabaseNamePattern nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MaxZeilen        int           = 100
    , @ResultSetArt     varchar(16)   = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen     bit           = 0
    , @Json             nvarchar(max) = NULL OUTPUT
    , @PrintMeldungen   bit           = 1
    , @Hilfe            bit           = 0
```

## `[monitor].[USP_ServerMemory]`

Quelle: `Code/08_ServerHealth/030_USP_ServerMemory.sql`

```sql
@MaxZeilen int=100,@PrintMeldungen bit=1,@Hilfe bit=0,@ResultSetArt varchar(16)='CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen bit=0,@Json nvarchar(max)=NULL OUTPUT,
 @StatusCodeOut varchar(40)=NULL OUTPUT,@IsPartialOut bit=NULL OUTPUT,@ErrorNumberOut int=NULL OUTPUT,@ErrorMessageOut nvarchar(2048)=NULL OUTPUT
```

## `[monitor].[USP_ServerNuma]`

Quelle: `Code/08_ServerHealth/020_USP_ServerNuma.sql`

```sql
@PrintMeldungen bit=1,@Hilfe bit=0,@ResultSetArt varchar(16)='CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen bit=0,@Json nvarchar(max)=NULL OUTPUT,
 @StatusCodeOut varchar(40)=NULL OUTPUT,@IsPartialOut bit=NULL OUTPUT,@ErrorNumberOut int=NULL OUTPUT,@ErrorMessageOut nvarchar(2048)=NULL OUTPUT
```

## `[monitor].[USP_ServerSecurityConfiguration]`

Quelle: `Code/08_ServerHealth/090_USP_ServerSecurityConfiguration.sql`

```sql
@PrintMeldungen  bit = 1,
    @Hilfe           bit = 0,
    @ResultSetArt    varchar(16) = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen    bit = 0,
    @Json             nvarchar(max) = NULL OUTPUT,
    @StatusCodeOut   varchar(40) = NULL OUTPUT,
    @IsPartialOut    bit = NULL OUTPUT,
    @ErrorNumberOut  int = NULL OUTPUT,
    @ErrorMessageOut nvarchar(2048) = NULL OUTPUT
```

## `[monitor].[USP_CreateExecutionEvidenceJson]`

Quelle: `Code/04_PlanCache/052_USP_CreateExecutionEvidenceJson.sql`

```sql
@PlanXml                       xml             = NULL
    , @StatisticsIoText              nvarchar(max)   = NULL
    , @StatisticsTimeText            nvarchar(max)   = NULL
    , @StatisticsLanguage            varchar(16)     = 'AUTO'
    , @StatisticsEvidenceJson        nvarchar(max)   = NULL
    , @ObjectMetadataJson            nvarchar(max)   = NULL
    , @StatistikEvidenzModus         varchar(16)     = 'PLAN_ONLY'
    , @HistogrammModus               varchar(16)     = 'NONE'
    , @MetadatenQuellenmodus         varchar(16)     = 'EVIDENCE_ONLY'
    , @QuellumgebungBestaetigt       bit             = 0
    , @EvidenzDatenschutzModus       varchar(24)     = 'DERIVED_ONLY'
    , @IdentifierDatenschutzModus    varchar(16)     = 'RAW'
    , @SensitiveDataConfirmed        bit             = 0
    , @MitPredicateHistogramMap      bit             = 1
    , @StatementId                   int             = NULL
    , @StatementOrdinal              int             = NULL
    , @SameExecutionAsPlanConfirmed  bit             = NULL
    , @CapturedAtUtc                 datetime2(3)    = NULL
    , @SourceProductVersion          nvarchar(128)   = NULL
    , @SourceCompatibilityLevel      smallint        = NULL
    , @SourceEngineEdition           int             = NULL
    , @MaxStatistiken                int             = 100
    , @MaxHistogrammSchritte         int             = 20000
    , @LockTimeoutMs                 int             = 0
    , @HighImpactConfirmed           bit             = 0
    , @AdditionalEvidenceJson        nvarchar(max)   = NULL
    , @ExistingEvidenceJson          nvarchar(max)   = NULL
    , @RawTextHandling               varchar(16)     = 'HASH_ONLY'
    , @StrictValidation              bit             = 1
    , @ResultSetArt                  varchar(16)     = 'CONSOLE'
    , @ResultTablesJson              nvarchar(max)   = NULL
    , @JsonErzeugen                  bit             = 1
    , @Json                          nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                bit             = 1
    , @Hilfe                         bit             = 0
    , @StatusCodeOut                 varchar(40)     = NULL OUTPUT
    , @IsPartialOut                  bit             = NULL OUTPUT
    , @ErrorNumberOut                int             = NULL OUTPUT
    , @ErrorMessageOut               nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_ExecutionPlanAnalysis]`

Quelle: `Code/04_PlanCache/053_USP_ExecutionPlanAnalysis.sql`

```sql
@PlanXml                        xml             = NULL
    , @PlanHandle                     varbinary(64)   = NULL
    , @SessionIds                     nvarchar(max)   = NULL
    , @RequestId                      int             = NULL
    , @QueryStoreDatabaseName         sysname         = NULL
    , @QueryStorePlanId               bigint          = NULL
    , @PlanQuelle                     varchar(24)      = 'AUTO'
    , @StatementId                    int             = NULL
    , @StatementQueryHash             binary(8)       = NULL
    , @StatementQueryPlanHash         binary(8)       = NULL
    , @EvidenzJson                    nvarchar(max)   = NULL
    , @StatisticsIoText               nvarchar(max)   = NULL
    , @StatisticsTimeText             nvarchar(max)   = NULL
    , @StatisticsLanguage             varchar(16)     = 'AUTO'
    , @StatistikEvidenzModus          varchar(16)     = 'PLAN_ONLY'
    , @HistogrammModus                varchar(16)     = 'NONE'
    , @MetadatenQuellenmodus          varchar(16)     = 'EVIDENCE_ONLY'
    , @QuellumgebungBestaetigt        bit             = 0
    , @MitPredicateHistogramMap       bit             = 1
    , @AnalyseTiefe                   varchar(16)      = 'STANDARD'
    , @WorkloadProfil                 varchar(32)      = 'AUTO'
    , @Regelsatz                      varchar(32)      = 'DEFAULT'
    , @MinSchweregrad                 varchar(16)      = 'INFO'
    , @MitThreadRuntime               bit             = 0
    , @MitSqlText                     bit             = 0
    , @EvidenzDatenschutzModus        varchar(24)      = 'DERIVED_ONLY'
    , @IdentifierDatenschutzModus     varchar(16)      = 'RAW'
    , @SensitiveDataConfirmed         bit             = 0
    , @MaxOperatoren                  int             = 50000
    , @MaxFindings                    int             = 5000
    , @MaxStatistiken                 int             = 100
    , @MaxHistogrammSchritte          int             = 20000
    , @MaxDurationSeconds             int             = 30
    , @LockTimeoutMs                  int             = 0
    , @HighImpactConfirmed            bit             = 0
    , @ResultSetArt                   varchar(16)      = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max)   = NULL
    , @JsonErzeugen                   bit             = 0
    , @Json                           nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                 bit             = 1
    , @Hilfe                          bit             = 0
    , @StatusCodeOut                  varchar(40)     = NULL OUTPUT
    , @IsPartialOut                   bit             = NULL OUTPUT
    , @ErrorNumberOut                 int             = NULL OUTPUT
    , @ErrorMessageOut                nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_ShowplanAnalysis]`

Quelle: `Code/04_PlanCache/050_USP_ShowplanAnalysis.sql`

```sql
@PlanHandle                    varbinary(64)   = NULL
    , @QueryHash                     binary(8)       = NULL
    , @QueryPlanHash                 binary(8)       = NULL
    , @DatabaseNames                 nvarchar(max)   = NULL
    , @SystemdatenbankenEinbeziehen  bit             = 0
    , @DatabaseNamePattern           nvarchar(4000)  = NULL
    , @HighImpactConfirmed           bit             = 0
    , @TextPattern                   nvarchar(4000)  = NULL
    , @AnalyseModus                  varchar(16)      = 'GEZIELT'
    , @PlanQuelle                    varchar(16)      = 'AUTO'
    , @Sortierung                    varchar(32)      = 'CPU_TOTAL'
    , @MinExecutionCount             bigint          = 1
    , @MaxAnalyseobjekte             int             = 20
    , @MaxDurationSeconds            int             = 30
    , @MaxZeilen                     int             = 50000
    , @ParentQueryStatsSnapshot      bit             = 0
    , @WorkloadProfil                varchar(32)      = 'AUTO'
    , @MinSchweregrad                varchar(16)      = 'INFO'
    , @MitThreadRuntime              bit             = 0
    , @MitSqlText                    bit             = 0
    , @StatistikEvidenzModus         varchar(16)      = 'PLAN_ONLY'
    , @HistogrammModus               varchar(16)      = 'NONE'
    , @MetadatenQuellenmodus         varchar(16)      = 'EVIDENCE_ONLY'
    , @QuellumgebungBestaetigt       bit             = 0
    , @EvidenzDatenschutzModus       varchar(24)      = 'DERIVED_ONLY'
    , @IdentifierDatenschutzModus    varchar(16)      = 'RAW'
    , @SensitiveDataConfirmed        bit             = 0
    , @MaxStatistiken                int             = 100
    , @MaxHistogrammSchritte         int             = 20000
    , @ResultSetArt                  varchar(16)      = 'CONSOLE'
    , @ResultTablesJson              nvarchar(max)   = NULL
    , @JsonErzeugen                  bit             = 0
    , @Json                          nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                bit             = 1
    , @Hilfe                         bit             = 0
```

## `[monitor].[USP_ServiceBrokerAnalysis]`

Quelle: `Code/09_VersionAdaptive/050_USP_ServiceBrokerAnalysis.sql`

```sql
@DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                      nvarchar(max)  = NULL
    , @SchemaNamePattern                nvarchar(4000) = NULL
    , @ObjectNames                      nvarchar(max)  = NULL
    , @ObjectNamePattern                nvarchar(4000) = NULL
    , @FullObjectNames                  nvarchar(max)  = NULL
    , @NurProblematisch                 bit            = 0
    , @TransmissionAgeWarnMinutes       bigint         = 60
    , @TransmissionRowsWarn             bigint         = 1000
    , @QueueRowsWarn                    bigint         = 10000
    , @ActivationSilenceWarnMinutes     bigint         = 60
    , @ConversationRowsWarn             bigint         = 100000
    , @MaxZeilen                        int            = 2000
    , @LockTimeoutMs                    int            = 0
    , @ResultSetArt                     varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
    , @StatusCodeOut                    varchar(40)     = NULL OUTPUT
    , @IsPartialOut                     bit            = NULL OUTPUT
    , @ErrorNumberOut                   int            = NULL OUTPUT
    , @ErrorMessageOut                  nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_SpecialFeatureInventory]`

Quelle: `Code/09_VersionAdaptive/020_USP_SpecialFeatureInventory.sql`

```sql
@DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @NurErkannteFeatures              bit            = 0
    , @MaxZeilen                        int            = 2000
    , @LockTimeoutMs                    int            = 0
    , @ResultSetArt                     varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
    , @StatusCodeOut                    varchar(40)     = NULL OUTPUT
    , @IsPartialOut                     bit            = NULL OUTPUT
    , @ErrorNumberOut                   int            = NULL OUTPUT
    , @ErrorMessageOut                  nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_StartupParameters]`

Quelle: `Code/08_ServerHealth/070_USP_StartupParameters.sql`

```sql
@PrintMeldungen bit=1,@Hilfe bit=0,@ResultSetArt varchar(16)='CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen bit=0,@Json nvarchar(max)=NULL OUTPUT,
 @StatusCodeOut varchar(40)=NULL OUTPUT,@IsPartialOut bit=NULL OUTPUT,@ErrorNumberOut int=NULL OUTPUT,@ErrorMessageOut nvarchar(2048)=NULL OUTPUT
```

## `[monitor].[USP_Statistics]`

Quelle: `Code/03_ObjectIndex/040_USP_Statistics.sql`

```sql
@DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                    nvarchar(max)  = NULL
    , @SchemaNamePattern              nvarchar(4000) = NULL
    , @ObjectNames                    nvarchar(max)  = NULL
    , @ObjectNamePattern              nvarchar(4000) = NULL
    , @FullObjectNames                nvarchar(max)  = NULL
    , @StatisticsNames                nvarchar(max)  = NULL
    , @StatisticsNamePattern          nvarchar(4000) = NULL
    , @AnalyseModus                   varchar(16)   = 'GEZIELT'
    , @MinModificationPercent         decimal(9,2)  = 0
    , @MinAlterTage                   int           = 0
    , @MitIncrementellenDetails       bit           = 0
    , @MaxZeilen                      int           = 10000
    , @LockTimeoutMs                  int           = 0
    , @ResultSetArt                  varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                  bit            = 0
    , @Json                          nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                 bit           = 1
    , @Hilfe                          bit           = 0
```

## `[monitor].[USP_StatisticsDistributionAnalysis]`

Quelle: `Code/03_ObjectIndex/045_USP_StatisticsDistributionAnalysis.sql`

```sql
@DatabaseNames                       nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen        bit            = 0
    , @DatabaseNamePattern                 nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                         nvarchar(max)  = NULL
    , @SchemaNamePattern                   nvarchar(4000) = NULL
    , @ObjectNames                         nvarchar(max)  = NULL
    , @ObjectNamePattern                   nvarchar(4000) = NULL
    , @FullObjectNames                     nvarchar(max)  = NULL
    , @StatisticsNames                     nvarchar(max)  = NULL
    , @StatisticsNamePattern               nvarchar(4000) = NULL
    , @AnalyseModus                        varchar(16)     = 'GEZIELT'
    , @MaxVerteilungsStatistiken           int             = 50
    , @MinVerteilungsZeilen                bigint          = 1000
    , @SkewWarnFaktor                      decimal(19,4)   = 10
    , @DominanterSchrittWarnPercent        decimal(9,4)    = 50
    , @ModificationWarnPercent             decimal(9,4)    = 20
    , @PartitionSpreadWarnPercent          decimal(9,4)    = 20
    , @MaxZeilen                           int             = 1000
    , @LockTimeoutMs                       int             = 0
    , @ResultSetArt                        varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                        bit             = 0
    , @Json                                nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                      bit             = 1
    , @Hilfe                               bit             = 0
    , @StatusCodeOut                       varchar(40)     = NULL OUTPUT
    , @IsPartialOut                        bit             = NULL OUTPUT
    , @ErrorNumberOut                      int             = NULL OUTPUT
    , @ErrorMessageOut                     nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_TempDBConfiguration]`

Quelle: `Code/08_ServerHealth/040_USP_TempDBConfiguration.sql`

```sql
@PrintMeldungen bit=1,@Hilfe bit=0,@ResultSetArt varchar(16)='CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen bit=0,@Json nvarchar(max)=NULL OUTPUT,
 @StatusCodeOut varchar(40)=NULL OUTPUT,@IsPartialOut bit=NULL OUTPUT,@ErrorNumberOut int=NULL OUTPUT,@ErrorMessageOut nvarchar(2048)=NULL OUTPUT
```

## `[monitor].[USP_TemporalAnalysis]`

Quelle: `Code/09_VersionAdaptive/040_USP_TemporalAnalysis.sql`

```sql
@DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                      nvarchar(max)  = NULL
    , @SchemaNamePattern                nvarchar(4000) = NULL
    , @ObjectNames                      nvarchar(max)  = NULL
    , @ObjectNamePattern                nvarchar(4000) = NULL
    , @FullObjectNames                  nvarchar(max)  = NULL
    , @NurProblematisch                 bit            = 0
    , @HistorySizeWarnMb                decimal(19,2)  = 10240
    , @HistoryRowsWarn                  bigint         = 10000000
    , @HistoryToCurrentRatioWarn        decimal(19,4)  = 10
    , @MinHistoryMbForRatioWarn         decimal(19,2)  = 100
    , @MaxZeilen                        int            = 2000
    , @LockTimeoutMs                    int            = 0
    , @ResultSetArt                     varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
    , @StatusCodeOut                    varchar(40)     = NULL OUTPUT
    , @IsPartialOut                     bit            = NULL OUTPUT
    , @ErrorNumberOut                   int            = NULL OUTPUT
    , @ErrorMessageOut                  nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_TraceFlags]`

Quelle: `Code/08_ServerHealth/060_USP_TraceFlags.sql`

```sql
@PrintMeldungen bit=1,@Hilfe bit=0,@ResultSetArt varchar(16)='CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen bit=0,@Json nvarchar(max)=NULL OUTPUT,
 @StatusCodeOut varchar(40)=NULL OUTPUT,@IsPartialOut bit=NULL OUTPUT,@ErrorNumberOut int=NULL OUTPUT,@ErrorMessageOut nvarchar(2048)=NULL OUTPUT
```

## `[monitor].[USP_EncryptionAnalysis]`

Quelle: `Code/09_VersionAdaptive/080_USP_EncryptionAnalysis.sql`

```sql
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
```

## `[monitor].[USP_ExternalRuntimeAnalysis]`

Quelle: `Code/09_VersionAdaptive/090_USP_ExternalRuntimeAnalysis.sql`

```sql
@DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @LanguageNames                    nvarchar(max)  = NULL
    , @LanguageNamePattern              nvarchar(4000) = NULL
    , @SampleSeconds                    tinyint         = 0
    , @MitDateimetadaten                bit             = 0
    , @MitBerechtigungsanalyse          bit             = 0
    , @MitSitzungskontext               bit             = 0
    , @NurProblematisch                 bit             = 0
    , @MaxZeilen                        int             = 100
    , @LockTimeoutMs                    int             = 0
    , @ResultSetArt                     varchar(16)     = 'CONSOLE'
    , @ResultTablesJson                 nvarchar(max)   = NULL
    , @JsonErzeugen                     bit             = 0
    , @Json                             nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                   bit             = 1
    , @Hilfe                            bit             = 0
    , @StatusCodeOut                    varchar(40)     = NULL OUTPUT
    , @IsPartialOut                     bit             = NULL OUTPUT
    , @ErrorNumberOut                   int             = NULL OUTPUT
    , @ErrorMessageOut                  nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_ClrAnalysis]`

Quelle: `Code/09_VersionAdaptive/100_USP_ClrAnalysis.sql`

```sql
@DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @AssemblyNames                    nvarchar(max)  = NULL
    , @AssemblyNamePattern              nvarchar(4000) = NULL
    , @SampleSeconds                    tinyint         = 0
    , @MitModulzuordnung                bit             = 1
    , @MitBerechtigungsanalyse          bit             = 0
    , @MitSitzungskontext               bit             = 0
    , @NurProblematisch                 bit             = 0
    , @MaxZeilen                        int             = 100
    , @LockTimeoutMs                    int             = 0
    , @ResultSetArt                     varchar(16)     = 'CONSOLE'
    , @ResultTablesJson                 nvarchar(max)   = NULL
    , @JsonErzeugen                     bit             = 0
    , @Json                             nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                   bit             = 1
    , @Hilfe                            bit             = 0
    , @StatusCodeOut                    varchar(40)     = NULL OUTPUT
    , @IsPartialOut                     bit             = NULL OUTPUT
    , @ErrorNumberOut                   int             = NULL OUTPUT
    , @ErrorMessageOut                  nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_MaintenanceOperations]`

Quelle: `Code/07_Infrastructure/130_USP_MaintenanceOperations.sql`

```sql
@DatabaseNames                       nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen        bit            = 0
    , @DatabaseNamePattern                 nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @JobNames                            nvarchar(max)  = NULL
    , @JobNamePattern                      nvarchar(4000) = NULL
    , @NurProblematisch                    bit            = 0
    , @ResumablePausedWarnMinutes          int            = 60
    , @BlockedWarnMs                       bigint         = 5000
    , @PvsWarnMb                           decimal(19,2)  = 1024
    , @AbortedTransactionsWarnCount        bigint         = 1
    , @MaxZeilen                           int            = 1000
    , @LockTimeoutMs                       int            = 0
    , @ResultSetArt                        varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                        bit            = 0
    , @Json                                nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                      bit            = 1
    , @Hilfe                               bit            = 0
    , @StatusCodeOut                       varchar(40)    = NULL OUTPUT
    , @IsPartialOut                        bit            = NULL OUTPUT
    , @ErrorNumberOut                      int            = NULL OUTPUT
    , @ErrorMessageOut                     nvarchar(2048) = NULL OUTPUT
```

## `[monitor].[USP_ErrorLogAnalysis]`

Quelle: `Code/07_Infrastructure/140_USP_ErrorLogAnalysis.sql`

```sql
@AgentEinbeziehen          bit             = 0
    , @MaxArchivNummer           tinyint         = 0
    , @SeitServerlokalzeit       datetime2(3)    = NULL
    , @Suchtext1                 nvarchar(4000)  = NULL
    , @Suchtext2                 nvarchar(4000)  = NULL
    , @MeldungstextEinbeziehen   bit             = 0
    , @MaxMeldungszeichen        int             = 4000
    , @MaxQuellzeilen            int             = 10000
    , @MaxZeilen                 int             = 1000
    , @ResultSetArt              varchar(16)     = 'CONSOLE'
    , @ResultTablesJson          nvarchar(max)   = NULL
    , @JsonErzeugen              bit             = 0
    , @Json                       nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen            bit             = 1
    , @Hilfe                     bit             = 0
    , @StatusCodeOut             varchar(40)     = NULL OUTPUT
    , @IsPartialOut              bit             = NULL OUTPUT
    , @ErrorNumberOut            int             = NULL OUTPUT
    , @ErrorMessageOut           nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_VectorIndexAnalysis]`

Quelle: `Code/03_ObjectIndex/075_USP_VectorIndexAnalysis.sql`

```sql
@DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed            bit            = 0
    , @SchemaNames                    nvarchar(max)  = NULL
    , @SchemaNamePattern              nvarchar(4000) = NULL
    , @ObjectNames                    nvarchar(max)  = NULL
    , @ObjectNamePattern              nvarchar(4000) = NULL
    , @FullObjectNames                nvarchar(max)  = NULL
    , @IndexNames                     nvarchar(max)  = NULL
    , @IndexNamePattern               nvarchar(4000) = NULL
    , @StalenessReviewPercent         decimal(5,2)  = 15.00
    , @MaxZeilen                      int            = 2000
    , @LockTimeoutMs                  int            = 0
    , @ResultSetArt                   varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max)  = NULL
    , @JsonErzeugen                   bit            = 0
    , @Json                           nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                 bit            = 1
    , @Hilfe                          bit            = 0
    , @StatusCodeOut                  varchar(40)    = NULL OUTPUT
    , @IsPartialOut                   bit            = NULL OUTPUT
    , @ErrorNumberOut                 int            = NULL OUTPUT
    , @ErrorMessageOut                nvarchar(2048) = NULL OUTPUT
```

## `[monitor].[USP_WorkerPressureAnalysis]`

Quelle: `Code/08_ServerHealth/180_USP_WorkerPressureAnalysis.sql`

```sql
@SampleSeconds       tinyint         = 1
    , @MinRequestElapsedMs int             = 5000
    , @MaxZeilen           int             = 1000
    , @ResultSetArt        varchar(16)     = 'CONSOLE'
    , @ResultTablesJson    nvarchar(max)   = NULL
    , @JsonErzeugen        bit             = 0
    , @Json                nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen      bit             = 1
    , @Hilfe               bit             = 0
    , @StatusCodeOut       varchar(40)     = NULL OUTPUT
    , @IsPartialOut        bit             = NULL OUTPUT
    , @ErrorNumberOut      int             = NULL OUTPUT
    , @ErrorMessageOut     nvarchar(2048)  = NULL OUTPUT
```

## `[monitor].[USP_DatabaseConfigurationAnalysis]`

Quelle: `Code/08_ServerHealth/190_USP_DatabaseConfigurationAnalysis.sql`

```sql
@DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @ProfileJson                    nvarchar(max)  = NULL
    , @MaxZeilen                      int            = 2000
    , @ResultSetArt                   varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max)  = NULL
    , @JsonErzeugen                   bit            = 0
    , @Json                           nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                 bit            = 1
    , @Hilfe                          bit            = 0
    , @StatusCodeOut                  varchar(40)    = NULL OUTPUT
    , @IsPartialOut                   bit            = NULL OUTPUT
    , @ErrorNumberOut                 int            = NULL OUTPUT
    , @ErrorMessageOut                nvarchar(2048) = NULL OUTPUT
```

## `[monitor].[USP_ConfigureSnapshotTarget]`

Quelle: `Code/10_SnapshotBaseline/080_USP_ConfigureSnapshotTarget.sql`

```sql
@TargetDatabaseName       sysname
    , @IsEnabled                bit           = 1
    , @SchedulerType            varchar(16)   = 'EXTERNAL'
    , @CollectionIntervalSeconds smallint      = 30
    , @MaxRows                  int            = 1000
    , @PayloadEnabled           bit            = 0
    , @RawRetentionDays         smallint       = 14
    , @PayloadRetentionDays     smallint       = 7
    , @RollupRetentionDays      smallint       = 180
    , @SoftBudgetMB             int            = 10240
    , @PurgeIntervalMinutes     smallint       = 60
    , @PurgeBatchRows           int            = 10000
    , @BudgetAction             varchar(32)    = 'PURGE_EXPIRED_THEN_STOP'
    , @PrintMeldungen           bit            = 1
    , @Hilfe                    bit            = 0
    , @StatusCodeOut            varchar(40)    = NULL OUTPUT
    , @IsPartialOut             bit            = NULL OUTPUT
    , @ErrorNumberOut           int            = NULL OUTPUT
    , @ErrorMessageOut          nvarchar(2048) = NULL OUTPUT
```

## `[monitor].[USP_RunSnapshotCollectionCycle]`

Quelle: `Code/10_SnapshotBaseline/090_USP_RunSnapshotCollectionCycle.sql`

```sql
@SchedulerType     varchar(16)    = 'EXTERNAL'
    , @RunEvenIfNotDue   bit            = 0
    , @ResultSetArt      varchar(16)    = 'CONSOLE'
    , @ResultTablesJson  nvarchar(max)  = NULL
    , @JsonErzeugen      bit            = 0
    , @Json              nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen    bit            = 1
    , @Hilfe             bit            = 0
    , @CaptureRunIdOut   bigint         = NULL OUTPUT
    , @StatusCodeOut     varchar(40)    = NULL OUTPUT
    , @IsPartialOut      bit            = NULL OUTPUT
    , @ErrorNumberOut    int            = NULL OUTPUT
    , @ErrorMessageOut   nvarchar(2048) = NULL OUTPUT
```

## `[monitor].[USP_PurgeSnapshotData]`

Quelle: `Code/10_SnapshotBaseline/100_USP_PurgeSnapshotData.sql`

```sql
@MaxBatches       int            = 10
    , @Force            bit            = 0
    , @ResultSetArt     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson nvarchar(max)  = NULL
    , @JsonErzeugen     bit            = 0
    , @Json             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen   bit            = 1
    , @Hilfe            bit            = 0
    , @PurgeRunIdOut    bigint         = NULL OUTPUT
    , @StatusCodeOut    varchar(40)    = NULL OUTPUT
    , @IsPartialOut     bit            = NULL OUTPUT
    , @ErrorNumberOut   int            = NULL OUTPUT
    , @ErrorMessageOut  nvarchar(2048) = NULL OUTPUT
```

## `[monitor].[USP_FrameworkUsageFromQueryStore]`

Quelle: `Code/09_VersionAdaptive/500_USP_FrameworkUsageFromQueryStore.sql`

```sql
@MaxZeilen        int            = 100
    , @MinAusfuehrungen bigint         = 1
    , @ZeitraumTage     int            = NULL
    , @ResultSetArt     varchar(16)    = 'CONSOLE'
    , @Json             nvarchar(max)  = NULL OUTPUT
```
