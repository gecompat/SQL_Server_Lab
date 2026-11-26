#Requires -Version 7.2
<#
.SYNOPSIS
    Runs the bounded native HV-603A SQL-storage reconcile acceptance.
.DESCRIPTION
    Uses one operation-owned clone of an explicitly selected stopped Windows
    2025 slot.  It first establishes the HV-603 SCSI/storage receipt and only
    then verifies receipt-bound SQL default and TempDB path reconciliation.
    Fault/resume injection remains in the synthetic contract; this runner does
    not add a production fault-injection seam.
.PARAMETER VerifyLibraryRestore
    Uses the same owned clone to verify a guided library backup and the guided
    restore into a new synthetic database. The library is test-local.
.PARAMETER PreparedArtifactId
    Optional sealed SQL 2025 Developer artifact for one prepared acceptance scope.
    Uses one owned prepared run on an existing Host-Only network with activation
    egress denied. This option does not use a pre-existing Windows slot or media.
#>
[CmdletBinding(DefaultParameterSetName='Clone')]
param(
    [Parameter(Mandatory,ParameterSetName='Clone')][string]$CloneSourceRunId,
    [Parameter(Mandatory,ParameterSetName='Clone')][string]$MediaRoot,
    [Parameter(ParameterSetName='Clone')][ValidateSet('Enterprise','Standard','Eval')][string]$MediaEdition='Enterprise',
    [Parameter(Mandatory,ParameterSetName='Prepared')][ValidatePattern('^hyperv-sql-prepared-sealed-[a-f0-9]{64}$')][string]$PreparedArtifactId,
    [string]$StateRoot,
    [string]$OperationId=('local-hv-sql-storage-'+[guid]::NewGuid().ToString('N')),
    [switch]$KeepOnFailure,
    [switch]$VerifyLibraryRestore,
    [Parameter(ParameterSetName='Prepared')][switch]$VerifyGuidedDatabaseScript
)
$ErrorActionPreference='Stop'
if ($PreparedArtifactId -and ($VerifyLibraryRestore.IsPresent -eq $VerifyGuidedDatabaseScript.IsPresent)) {
    throw 'HYPERV_LIBRARY_RESTORE_ACCEPTANCE_PREPARED_SCOPE_REQUIRED'
}
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath=Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-sql-storage-'+[guid]::NewGuid().ToString('N'))
$previousStateRoot=$env:SQL_SERVER_LAB_STATE
$module=$null;$lab=$null;$ownedPaths=@();$completed=$false;$script:saPassword=$null
$ownsOperation=$false
$mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_HyperV_SQL_Storage_Reconcile_Acceptance');$mutexAcquired=$false

function Assert-HyperVSqlStorageAcceptance { param([bool]$Condition,[string]$Description) if(-not $Condition){throw "HYPERV_SQL_STORAGE_ACCEPTANCE_FAILED: $Description"};Write-Host "PASS: $Description" -ForegroundColor Green }
function Invoke-Private { param([scriptblock]$ScriptBlock,[object[]]$Arguments=@()) & $module $ScriptBlock @Arguments }
function Get-Context { param([string]$RunId) Invoke-Private {param($Id,$Root)Get-HyperVLabWorkflowRun -RunId $Id -StateRoot $Root} @($RunId,$StateRoot) }
function Get-OwnedManagedVm { param($Context) Invoke-Private {param($Name,$Id,$Scope)Get-HyperVManagedVM -VMName $Name -ExpectedRunId $Id -ExpectedScopeId $Scope} @([string]$Context.Instance.vmName,[string]$Context.Run.runId,[string]$Context.Run.scopeId) }
function New-SqlConnection { param($Context) if(-not $script:saPassword.IsReadOnly()){$script:saPassword.MakeReadOnly()};$c=[Data.SqlClient.SqlConnection]::new();$c.ConnectionString="Server=$([string]$Context.Instance.host),$([int]$Context.Instance.port);Database=master;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;";$c.Credential=[Data.SqlClient.SqlCredential]::new('sa',$script:saPassword);$c }
function Invoke-SqlRows {
    param($Context,[string]$Query)
    $c=New-SqlConnection $Context;try{$c.Open();$cmd=$c.CreateCommand();$cmd.CommandTimeout=120;$cmd.CommandText=$Query;$table=[Data.DataTable]::new();$reader=$cmd.ExecuteReader();$table.Load($reader);$reader.Dispose();@($table.Rows|ForEach-Object{$row=$_;$value=[ordered]@{};foreach($column in $table.Columns){$value[$column.ColumnName]=[string]$row[$column.ColumnName]};[pscustomobject]$value})}finally{$c.Dispose()}
}
function Wait-StorageSqlReady { param($Context) $deadline=[datetime]::UtcNow.AddMinutes(5);do{try{$c=New-SqlConnection $Context;$c.Open();$cmd=$c.CreateCommand();$cmd.CommandText='SELECT 1;';if([int]$cmd.ExecuteScalar() -eq 1){return $true}}catch{}finally{if($c){$c.Dispose()}};Start-Sleep -Seconds 5}while([datetime]::UtcNow -lt $deadline);throw 'HYPERV_SQL_STORAGE_ACCEPTANCE_SQL_READINESS_TIMEOUT' }
function Get-SqlStorageObservation {
    param($Context)
    $defaults=Invoke-SqlRows $Context "DECLARE @b nvarchar(4000); EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',N'Software\Microsoft\MSSQLServer\MSSQLServer',N'BackupDirectory',@b OUTPUT; SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(4000)) AS DefaultData,CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(4000)) AS DefaultLog,@b AS BackupDirectory,CONVERT(varchar(33),sqlserver_start_time,126) AS SqlStartTime FROM sys.dm_os_sys_info;"
    $tempdb=Invoke-SqlRows $Context "SELECT name AS LogicalName,physical_name AS SqlPhysicalPath,CONVERT(varchar(20),size/128) AS SizeMB,CASE WHEN is_percent_growth=1 THEN CONVERT(varchar(20),growth)+'%' ELSE CONVERT(varchar(20),growth/128)+'MB' END AS Growth,CONVERT(varchar(20),type) AS FileType FROM sys.master_files WHERE database_id=2 ORDER BY file_id;"
    [pscustomobject]@{Defaults=$defaults[0];TempDb=@($tempdb)}
}
function Get-GuestBootTime { param($Context,$Credential) [string](Invoke-Private {param($Name,$Id,$Scope,$Cred)$value=Invoke-HyperVPowerShellDirect -VMName $Name -ExpectedRunId $Id -ExpectedScopeId $Scope -Credential $Cred -ScriptBlock {(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')};[string]@($value)[-1]} @([string]$Context.Instance.vmName,[string]$Context.Run.runId,[string]$Context.Run.scopeId,$Credential)) }
function Test-ScopedTemporaryRoot { param([string]$Path) $resolved=[IO.Path]::GetFullPath($Path).TrimEnd('\');$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\');[IO.Directory]::GetParent($resolved).FullName.TrimEnd('\').Equals($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^sql-lab-hv-sql-storage-[a-f0-9]{32}$' }
function New-StorageManifest {
    param([string]$Path,[string]$Name)
    $value=[ordered]@{'$schema'=(Join-Path $repoRoot 'Schemas/lab-manifest.schema.json');name=$Name;automation=[ordered]@{mode='unattended'};instances=@([ordered]@{id='primary';version='2025';provider='hyperv';os='windows';profile='standard';autostart='off';network=[ordered]@{intent='hostOnly';exposure='host'};windowsActivation=[ordered]@{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='VerifyOnly';EgressPolicy='Denied'};hyperv=[ordered]@{memoryStartupMB=6144;processorCount=4;sqlPort=1433;guestPasswordMode='prompt'};storageIntent=[ordered]@{contractVersion='SqlServerLab.StorageIntent/1.0';placementPolicy='logical-only';physicalIsolation='not-required';roles=[ordered]@{defaultData=[ordered]@{selector='default'};defaultLog=[ordered]@{selector='default'};backup=[ordered]@{selector='default'}};tempDb=[ordered]@{distribution='single-location';dataFileCount=4;dataLocationSelectors=@('default');logPlacement=[ordered]@{selector='default';logicalName='templog';fileName='templog.ldf';sizeMB=64;growth='32MB'}};databaseFiles=@();restoreRules=@()}})}
    $value|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $Path -Encoding utf8
}
function New-OwnedRun {
    param([string]$ManifestPath,[securestring]$SqlPassword)
    $helper=Join-Path $repoRoot 'Tests/Common/HyperVResourceAcceptanceSlotClone.ps1'
    Invoke-Private {
        param($Helper,$Source,$Path,$Op,$Media,$Edition,$Sql,$Root,[bool]$ExistingNetwork)
        . $Helper
        New-HyperVResourceAcceptanceSlotClone -SourceRunId $Source -ManifestPath $Path -OperationId $Op `
            -MediaRoot $Media -MediaEdition $Edition -SqlPassword $Sql -StateRoot $Root -RequireExistingNetwork:$ExistingNetwork
    } @($helper,$CloneSourceRunId,$ManifestPath,$OperationId,$MediaRoot,$MediaEdition,$SqlPassword,$StateRoot,$VerifyLibraryRestore.IsPresent)
}

function New-PreparedSqlStorageAcceptanceRun {
    param([string]$ManifestPath,[securestring]$SqlPassword)

    $artifact = Invoke-Private {
        param($Id,$Root) Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root
    } @($PreparedArtifactId,$StateRoot)
    if (@($artifact).Count -ne 1 -or $artifact.artifactState -cne 'SQL_PREPARED_SEALED' -or
        $artifact.operatingSystem.version -cne '2025' -or $artifact.sql.version -cne '2025' -or
        $artifact.sql.edition -notmatch 'Developer' -or $artifact.integrityVerification.status -cnotin @('VERIFIED_HASH','VERIFIED_CACHE')) {
        throw 'HYPERV_LIBRARY_RESTORE_ACCEPTANCE_PREPARED_ARTIFACT_UNVERIFIED'
    }
    $network = Invoke-Private { Resolve-LabHyperVNetworkBoundPlan -Intent hostOnly }
    if ($network.Status -cne 'READY' -or $network.Intent -cne 'hostOnly' -or @($network.Actions).Count -ne 0 -or -not $network.Name) {
        throw 'HYPERV_LIBRARY_RESTORE_ACCEPTANCE_EXISTING_NETWORK_REQUIRED'
    }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 30
    $instance = $manifest.instances[0]
    $instance.hyperv.preparedImageId = $PreparedArtifactId
    $instance.hyperv.switchName = [string]$network.Name
    $instance.windowsActivation.Strategy = 'NotRequested'
    $preparedPath = Join-Path $testRoot 'library-restore-prepared.json'
    $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $preparedPath -Encoding utf8
    Assert-HyperVSqlStorageAcceptance (Test-SqlServerLabManifest -Path $preparedPath).IsValid 'Manifest bindet die Prepared-Vorlage und das bestehende Host-Only-Netz'
    $guestPassword = Invoke-Private { New-HyperVSqlUnattendedPassword }
    try {
        Invoke-Private {
            param($Path,$Guest,$Sql,$Root,$Op)
            Invoke-WithLabWorkflowOperationContext -OperationId $Op -ScriptBlock {
                param($Path,$Guest,$Sql,$Root)
                New-SqlServerLab -Manifest $Path -GuestPassword $Guest -SqlSaPassword $Sql -StateRoot $Root -NonInteractive -RequireExistingHyperVNetwork
            } -ArgumentList @($Path,$Guest,$Sql,$Root)
        } @($preparedPath,$guestPassword,$SqlPassword,$StateRoot,$OperationId)
    } finally {
        $guestPassword.Dispose()
    }
}

function Invoke-GuidedDatabaseScriptAcceptance {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][PSCredential]$GuestCredential)

    $runId = [string]$Context.Run.runId
    $scope = [string]$Context.Run.scopeId
    $owned = Invoke-Private { param($Op,$Root) Get-LabOperationOwnedRun -OperationId $Op -StateRoot $Root } @($OperationId,$StateRoot)
    if (-not $owned -or $owned.runId -cne $runId -or $owned.scopeId -cne $scope -or
        -not (Test-ScopedTemporaryRoot $testRoot)) { throw 'HYPERV_GUIDED_DATABASE_SCRIPT_ACCEPTANCE_SCOPE_CHANGED' }

    $phase = 'CREATE'
    try {
        $created = Invoke-Private {
            param($Id,$Credential,$Sa)
            Invoke-LabGuidedHyperVDatabaseCreate -RunId $Id -InstanceId primary -DatabaseName LabGuidedSqlFixture -GuestUserName $Credential.UserName -GuestPassword $Credential.Password -SaPassword $Sa
        } @($runId,$GuestCredential,$script:saPassword)
        Assert-HyperVSqlStorageAcceptance ($created.Status -ceq 'CREATED' -and $created.RunId -ceq $runId -and
            $created.InstanceId -ceq 'primary' -and $created.DatabaseName -ceq 'LabGuidedSqlFixture') 'Guided database creation confirms the exact owned SQL target'

        $phase = 'SCRIPT'
        $sqlPath = Join-Path $testRoot 'guided-fixture.sql'
        [IO.File]::WriteAllText($sqlPath,'CREATE TABLE dbo.GuidedFixture (Value int NOT NULL); INSERT INTO dbo.GuidedFixture VALUES (57);')
        $scriptArguments = @{RunId=$runId;InstanceId='primary';StateRoot=$StateRoot;WindowsAuthentication=$true;ScriptPath=$sqlPath;Database='LabGuidedSqlFixture';Confirm=$false}
        $result = Invoke-SqlServerLabScript @scriptArguments 3>$null 4>$null 5>$null 6>$null
        $operation = [guid]::Empty
        Assert-HyperVSqlStorageAcceptance ($result.Success -and $result.Outcome -ceq 'SUCCEEDED' -and $result.Authentication -ceq 'Windows' -and
            $result.RunId -ceq $runId -and $result.InstanceId -ceq 'primary' -and $result.Batches -eq 1 -and
            [guid]::TryParseExact([string]$result.OperationId,'D',[ref]$operation) -and $operation -ne [guid]::Empty) 'Windows SQL script returns a bound one-batch receipt'
        $journal = Get-Content -LiteralPath (Join-Path $Context.RunDirectory "windows-sql-$operation.json") -Raw -Encoding utf8 | ConvertFrom-Json
        Assert-HyperVSqlStorageAcceptance ($journal.ContractVersion -ceq 'SqlServerLab.WindowsSqlOperation/1.0' -and $journal.OperationId -ceq $operation.ToString() -and
            $journal.Status -ceq 'SUCCEEDED' -and $journal.RunId -ceq $runId -and
            $journal.ScopeId -ceq $scope -and $journal.InstanceId -ceq 'primary' -and [guid]$journal.VmId -eq [guid]$Context.Instance.vmId -and
            $journal.ScriptSha256 -ceq (Get-FileHash -LiteralPath $sqlPath -Algorithm SHA256).Hash) 'Script journal binds the owned VM and exact executed bytes'

        $phase = 'CONTENT'
        $rows = @(Invoke-SqlRows $Context 'SELECT Value FROM LabGuidedSqlFixture.dbo.GuidedFixture;')
        Assert-HyperVSqlStorageAcceptance ($rows.Count -eq 1 -and $rows[0].Value -ceq '57') 'Synthetic script data is visible in the selected SQL database'
    } catch {
        $code = ($_.Exception.Message -split ':',2)[0]
        if ($code -cnotmatch '^(?:HYPERV_DATABASE_CREATE_(?:TARGET_(?:INVALID|NOT_READY|CHECK_FAILED|EXISTS)|UNCONFIRMED)|WINDOWS_SQL_(?:INPUT_INVALID|TARGET_UNAVAILABLE|OPERATION_UNCONFIRMED|NOT_DISPATCHED))$') { $code = 'UNCLASSIFIED' }
        throw "HYPERV_GUIDED_DATABASE_SCRIPT_ACCEPTANCE_UNCONFIRMED · $phase · $code"
    }
}

function Invoke-StorageLibraryRestoreAcceptance {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][PSCredential]$GuestCredential,
        [Parameter(Mandatory)][guid]$ExpectedVmId,
        [Parameter(Mandatory)][guid]$ExpectedStoragePlanId
    )

    $runId = [string]$Context.Run.runId
    $owned = Invoke-Private { param($Op,$Root) Get-LabOperationOwnedRun -OperationId $Op -StateRoot $Root } @($OperationId,$StateRoot)
    if (-not $owned -or $owned.runId -cne $runId -or $owned.scopeId -cne $Context.Run.scopeId -or
        -not (Test-ScopedTemporaryRoot $testRoot)) { throw 'HYPERV_LIBRARY_RESTORE_ACCEPTANCE_SCOPE_CHANGED' }
    $libraryRoot = Join-Path $testRoot 'Backups'
    if (Test-Path -LiteralPath $libraryRoot) { throw 'HYPERV_LIBRARY_RESTORE_ACCEPTANCE_LIBRARY_ALREADY_EXISTS' }

    $phase = 'FIXTURE'
    try {
        $null = Invoke-SqlRows $Context ("IF DB_ID(N'LabRestoreSeedFixture') IS NOT NULL OR DB_ID(N'LabRestoredFixture') IS NOT NULL " +
            "THROW 51011, 'SYNTHETIC_DATABASE_COLLISION', 1; EXEC(N'CREATE DATABASE [LabRestoreSeedFixture];'); SELECT CAST(1 AS int) AS Ready;")
        $null = Invoke-SqlRows $Context ('CREATE TABLE [LabRestoreSeedFixture].dbo.Fixture (Id int NOT NULL PRIMARY KEY, Value nvarchar(20) NOT NULL); ' +
            'INSERT INTO [LabRestoreSeedFixture].dbo.Fixture VALUES (1,N''alpha''),(2,N''beta''); SELECT CAST(1 AS int) AS Ready;')
        $phase = 'BACKUP_RESTORE'
        $execution = Invoke-Private {
            param($Id,$Credential,$Sa,$TestRoot,$LibraryRoot,$RunDirectory,$ScopeId,$VmId,$PlanId)
            $registeredDataRoot = Resolve-LabDataRootForUse -DataRoot (Get-LabDataRootDefault)
            if (-not (Test-LabPathWithinRoot -Root $TestRoot -Path $LibraryRoot).Valid -or
                (Test-Path -LiteralPath $LibraryRoot)) { throw 'HYPERV_LIBRARY_RESTORE_ACCEPTANCE_LIBRARY_SCOPE_INVALID' }

            # Redirect only the fixture library files inside this module call.
            # The real registered data-root and runtime storage guards still run.
            function Get-LabBackupLibraryPaths {
                param([Parameter(Mandatory)][string]$DataRoot)

                $root = Resolve-LabDataRootForUse -DataRoot $DataRoot
                if ($root -ine $registeredDataRoot) { throw 'HYPERV_LIBRARY_RESTORE_ACCEPTANCE_LIBRARY_SCOPE_INVALID' }
                [pscustomobject]@{
                    DataRoot = $root
                    LibraryRoot = $LibraryRoot
                    ObjectsRoot = Join-Path $LibraryRoot 'Objects'
                    RegistryPath = Join-Path $LibraryRoot 'backup-library.json'
                }
            }

            $priorIntents = @(Get-ChildItem -LiteralPath $RunDirectory -File -Filter 'backup-library-*.local.journal.json')
            if ($priorIntents.Count) { throw 'HYPERV_LIBRARY_BACKUP_ACCEPTANCE_UNEXPECTED_INTENT' }
            $backup = Invoke-LabGuidedHyperVLibraryBackup -RunId $Id -InstanceId primary -DatabaseName LabRestoreSeedFixture `
                -GuestUserName $Credential.UserName -GuestPassword $Credential.Password -SaPassword $Sa
            if ($backup.Status -cne 'BACKUP_REUSABLE' -or $backup.RunId -cne $Id -or $backup.InstanceId -cne 'primary' -or
                $backup.DatabaseName -cne 'LabRestoreSeedFixture' -or -not $backup.BackupSetId -or $backup.Bytes -le 0) {
                throw 'HYPERV_LIBRARY_BACKUP_ACCEPTANCE_RECEIPT_INVALID'
            }
            $intents = @(Get-ChildItem -LiteralPath $RunDirectory -File -Filter 'backup-library-*.local.journal.json')
            if ($intents.Count -ne 1) { throw 'HYPERV_LIBRARY_BACKUP_ACCEPTANCE_INTENT_NOT_UNIQUE' }
            $intent = Get-Content -LiteralPath $intents[0].FullName -Raw -Encoding utf8 | ConvertFrom-Json
            if ($intent.Contract -cne 'SqlServerLab.HyperVLibraryBackupIntent/1.0' -or $intent.Status -cne 'GUEST_FILE_REMOVED' -or
                $intent.RunId -cne $Id -or $intent.ScopeId -cne $ScopeId -or $intent.InstanceId -cne 'primary' -or
                $intent.FileName -cnotmatch '^backup-[0-9a-f]{32}\.bak$' -or [guid]$intent.VMId -ne $VmId -or
                [guid]$intent.StoragePlanId -ne $PlanId) { throw 'HYPERV_LIBRARY_BACKUP_ACCEPTANCE_INTENT_INVALID' }
            Write-Host 'PASS: Geführtes Backup liefert einen gebundenen Sicherungssatz mit bestätigter Gastdateibereinigung' -ForegroundColor Green

            $restored = Invoke-LabGuidedHyperVLibraryRestore -RunId $Id -InstanceId primary -BackupSetId $backup.BackupSetId `
                -DatabaseName LabRestoredFixture -GuestUserName $Credential.UserName -GuestPassword $Credential.Password -SaPassword $Sa
            [pscustomobject]@{BackupSetId = [string]$backup.BackupSetId; Restored = $restored}
        } @($runId,$GuestCredential,$script:saPassword,$testRoot,$libraryRoot,$Context.RunDirectory,
            [string]$Context.Run.scopeId,$ExpectedVmId,$ExpectedStoragePlanId)
        $restored = $execution.Restored
        Assert-HyperVSqlStorageAcceptance ($restored.Status -ceq 'RESTORED' -and $restored.CleanupStatus -ceq 'CONFIRMED' -and
            $restored.RunId -ceq $runId -and $restored.InstanceId -ceq 'primary' -and $restored.BackupSetId -ceq $execution.BackupSetId -and
            $restored.DatabaseName -ceq 'LabRestoredFixture') 'Geführter Restore bindet das verifizierte Backup und bestätigt die Bereinigung der Gastkopie'
        $phase = 'CONTENT'
        $sourceRows = @(Invoke-SqlRows $Context 'SELECT Id,Value FROM [LabRestoreSeedFixture].dbo.Fixture ORDER BY Id;')
        $targetRows = @(Invoke-SqlRows $Context 'SELECT Id,Value FROM [LabRestoredFixture].dbo.Fixture ORDER BY Id;')
        Assert-HyperVSqlStorageAcceptance ($sourceRows.Count -eq 2 -and $targetRows.Count -eq 2 -and
            ($sourceRows | ConvertTo-Json -Compress) -ceq ($targetRows | ConvertTo-Json -Compress)) 'Neue Zieldatenbank enthält die exakten synthetischen Daten'
    } catch {
        $code = $_.Exception.Message
        if ($code -cnotmatch '^HYPERV_LIBRARY_RESTORE_(?:TARGET_(?:INVALID|NOT_READY|CHECK_FAILED|EXISTS)|BACKUP_NOT_SELECTABLE|UNCONFIRMED|CLEANUP_REQUIRED|ACCEPTANCE_LIBRARY_SCOPE_INVALID)$' -and
            $code -cnotmatch '^HYPERV_LIBRARY_BACKUP_(?:SOURCE_(?:INVALID|NOT_READY)|UNCONFIRMED|CLEANUP_REQUIRED|ACCEPTANCE_(?:RECEIPT_INVALID|UNEXPECTED_INTENT|INTENT_NOT_UNIQUE|INTENT_INVALID))$') {
            $code = 'UNCLASSIFIED'
        }
        throw ('HYPERV_LIBRARY_RESTORE_ACCEPTANCE_UNCONFIRMED · '+$phase+' · '+$code)
    }
}

try {
    $mutexAcquired=$mutex.WaitOne([TimeSpan]::FromMinutes(15));if(-not $mutexAcquired){throw 'HYPERV_SQL_STORAGE_ACCEPTANCE_HOST_LOCK_TIMEOUT'}
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent());Assert-HyperVSqlStorageAcceptance $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) 'Runner arbeitet erhoeht'
    Get-Command Get-VM,Get-VHD,Get-VMHardDiskDrive -ErrorAction Stop|Out-Null
    $null=New-Item -ItemType Directory -Path $testRoot -Force;$module=Import-Module $modulePath -Force -PassThru
    if(-not $StateRoot){$StateRoot=Invoke-Private {Get-LabStateRoot}};$env:SQL_SERVER_LAB_STATE=$StateRoot
    if(Invoke-Private {param($Op,$Root)Get-LabOperationOwnedRun -OperationId $Op -StateRoot $Root} @($OperationId,$StateRoot)){throw 'HYPERV_SQL_STORAGE_ACCEPTANCE_OPERATION_ALREADY_OWNED'}
    $ownsOperation=$true
    $manifestPath=Join-Path $testRoot 'sql-storage.json';New-StorageManifest $manifestPath ('hv-sql-storage-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    Assert-HyperVSqlStorageAcceptance (Test-SqlServerLabManifest -Path $manifestPath).IsValid 'VerifyOnly-Manifest mit gebundenem Storage-Intent ist gueltig'
    $script:saPassword = Invoke-Private { New-HyperVSqlUnattendedPassword }
    $lab = if ($PreparedArtifactId) { New-PreparedSqlStorageAcceptanceRun $manifestPath $script:saPassword }
        else { New-OwnedRun $manifestPath $script:saPassword }
    Assert-HyperVSqlStorageAcceptance ([string]$lab.State -eq 'RUNNING') 'Operationseigener SQL-2025-Run ist bereit'
    $context=Get-Context $lab.RunId;$managed=Get-OwnedManagedVm $context
    if ($PreparedArtifactId) {
        # Prepared provision already applies the declared storage intent and verifies the SQL receipt.
        $ownedPaths = @([string]$managed.Identity.childVhdxPath) +
            @($managed.Identity.additionalDrives | ForEach-Object { [string]$_.path })
        $storage = Invoke-Private {
            param($Id,$Root)
            Get-LabVerifiedStorageRuntimeContext -RunId $Id -InstanceId primary -StateRoot $Root
        } @([string]$lab.RunId,$StateRoot)
        Assert-HyperVSqlStorageAcceptance ($ownedPaths.Count -gt 1 -and $storage.Receipt.Provider -ceq 'hyperv' -and
            $storage.Receipt.Status -ceq 'VERIFIED') 'Prepared-Provisionierung hat den gebundenen SQL-Speicher verifiziert'
        Assert-HyperVSqlStorageAcceptance (Wait-StorageSqlReady $context) 'SQL ist nach Prepared-Provisionierung bereit'
        $guestPassword = Invoke-Private {
            param($RunDirectory)
            Get-LabSecret -Path $RunDirectory -Name 'guest-administrator-password'
        } @($context.RunDirectory)
        try {
            $guestCredential = [PSCredential]::new('Administrator',$guestPassword)
            if ($VerifyGuidedDatabaseScript) {
                Invoke-GuidedDatabaseScriptAcceptance -Context $context -GuestCredential $guestCredential
            } else {
                Invoke-StorageLibraryRestoreAcceptance -Context $context -GuestCredential $guestCredential -ExpectedVmId $managed.VM.Id -ExpectedStoragePlanId $storage.Receipt.PlanId
            }
        } finally {
            if ($guestPassword) { $guestPassword.Dispose() }
        }
    } else {
        Assert-HyperVSqlStorageAcceptance (@($managed.Identity.additionalDrives).Count -eq 0) 'Clone beginnt ohne run-eigene Storage-Lanes'
        $intent=(Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 30).instances[0].storageIntent
        $bound=Invoke-Private {param($Intent,$RunId,$Name)New-LabStorageBoundPlan -StorageIntent $Intent -RunId $RunId -LabName $Name -InstanceId primary -Provider hyperv} @($intent,[string]$lab.RunId,[string]$lab.RunId)
        Assert-HyperVSqlStorageAcceptance ([string]$bound.Status -eq 'READY') 'Storage-Intent ist für den operationseigenen Run gebunden'
        Invoke-Private {param($Path,$Plan)Write-LabArtifactJsonAtomic -Path $Path -InputObject $Plan} @((Join-Path $context.RunDirectory 'storage-bound-plan.json'),$bound)
        $hostJournal=Join-Path $context.RunDirectory 'hyperv-storage-reconcile.local.journal.json'
        $hostPlan=Get-SqlServerLabReconcilePlan -RunId $lab.RunId -HyperVStorage -InstanceId primary -StateRoot $StateRoot
        $hostReasonCodes=@($hostPlan.ReasonCodes|Where-Object{$_}) -join ','
        Assert-HyperVSqlStorageAcceptance ([string]$hostPlan.HighestChangeClass -in @('live','restart') -and @($hostPlan.Actions).Count -eq 1 -and [string]$hostPlan.Actions[0].Operation -eq 'RepairHyperVStorage' -and @($hostPlan.Diff).Count -ge 1) "HV-603 plant die gebundene Storage-Lane eigentumsgeprueft: $hostReasonCodes"
        $hostWhatIf=Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -RepairHyperVStorage -InstanceId primary -StateRoot $StateRoot -WhatIf
        Assert-HyperVSqlStorageAcceptance ([string]$hostWhatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE' -and -not(Test-Path -LiteralPath $hostJournal)) 'HV-603-WhatIf schreibt weder VHDX noch Journal'
        $hostResult=Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -RepairHyperVStorage -InstanceId primary -StateRoot $StateRoot -Confirm:$false
        Assert-HyperVSqlStorageAcceptance ([string]$hostResult.ExecutionSummary.Status -eq 'SUCCEEDED') 'HV-603 erstellt die operationseigenen Storage-Lanes'
        $context=Get-Context $lab.RunId;$managed=Get-OwnedManagedVm $context;$ownedPaths=@([string]$managed.Identity.childVhdxPath)+@($managed.Identity.additionalDrives|ForEach-Object{[string]$_.path})
        $hostNoOp=Get-SqlServerLabReconcilePlan -RunId $lab.RunId -HyperVStorage -InstanceId primary -StateRoot $StateRoot
        Assert-HyperVSqlStorageAcceptance ($hostNoOp.IsNoOp -and @($hostNoOp.Actions).Count -eq 0 -and @($managed.Identity.guestDriveInitialization).Count -eq 1) 'HV-603 ist vor SQL-Mutation No-op und besitzt den gebundenen Gast-Receipt'
        if([string]$managed.VM.State -eq 'Off'){
            Invoke-Private {param($VM)Start-VM -VM $VM -ErrorAction Stop} @($managed.VM)
            $context=Get-Context $lab.RunId
        }
        Assert-HyperVSqlStorageAcceptance (Wait-StorageSqlReady $context) 'SQL ist nach Host-Storage-Reconcile bereit'
        $receiptPath=Join-Path $context.RunDirectory 'storage-runtime-receipt.json'
        Assert-HyperVSqlStorageAcceptance (-not(Test-Path -LiteralPath $receiptPath -PathType Leaf)) 'HV-603 persistiert noch keinen SQL-Runtime-Receipt'
        $before=Get-SqlStorageObservation $context;$sqlPlan=Get-SqlServerLabReconcilePlan -RunId $lab.RunId -HyperVSqlStorage -InstanceId primary -StateRoot $StateRoot
        Assert-HyperVSqlStorageAcceptance ([string]$sqlPlan.HighestChangeClass -eq 'restart' -and @($sqlPlan.Actions).Count -eq 1 -and $sqlPlan.Actions[0].RequiresSqlServiceRestart -and -not $sqlPlan.MutationAllowed) 'HV-603A plant receiptgebundene SQL-Pfad-Reparatur als SQL-Dienstrestart'
        Assert-HyperVSqlStorageAcceptance (($sqlPlan|ConvertTo-Json -Depth 30) -notmatch 'SQLData|SQLLog|private-|\.vhdx') 'Oeffentlicher SQL-Storage-Plan bleibt hostwertfrei'
        $sqlWhatIf=Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -RepairHyperVSqlStorage -InstanceId primary -StateRoot $StateRoot -WhatIf;$afterWhatIf=Get-SqlStorageObservation $context
        Assert-HyperVSqlStorageAcceptance ([string]$sqlWhatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE' -and -not(Test-Path -LiteralPath $receiptPath -PathType Leaf) -and $afterWhatIf.Defaults.SqlStartTime -eq $before.Defaults.SqlStartTime) 'HV-603A-WhatIf veraendert weder SQL noch Runtime-Receipt'
        $guestCredential=[PSCredential]::new('Administrator',(Invoke-Private {param($RunDirectory)(Get-LabSecret -Path $RunDirectory -Name 'guest-administrator-password')} @($context.RunDirectory)))
        $bootBefore=Get-GuestBootTime $context $guestCredential;$sqlStartBefore=$before.Defaults.SqlStartTime
        $result=Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -RepairHyperVSqlStorage -InstanceId primary -StateRoot $StateRoot -Confirm:$false
        $after=Get-SqlStorageObservation $context;$bootAfter=Get-GuestBootTime $context $guestCredential;$receiptAfter=Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 40
        $expected=@($receiptAfter.FileBindings);$normalizePath={param([string]$Path) ([string]$Path).Trim().TrimEnd('\','/')}
        $defaultSource=@(
            [pscustomobject]@{Role='default-data';Expected=[string](@($expected|Where-Object Role -eq 'default-data')[0].SqlPhysicalPath);Actual=[string]$after.Defaults.DefaultData}
            [pscustomobject]@{Role='default-log';Expected=[string](@($expected|Where-Object Role -eq 'default-log')[0].SqlPhysicalPath);Actual=[string]$after.Defaults.DefaultLog}
            [pscustomobject]@{Role='backup';Expected=[string](@($expected|Where-Object Role -eq 'backup')[0].SqlPhysicalPath);Actual=[string]$after.Defaults.BackupDirectory}
        )
        $defaultEvidence=@($defaultSource|ForEach-Object{[pscustomobject]@{Role=$_.Role;Exact=([string]$_.Expected).Equals([string]$_.Actual,[StringComparison]::OrdinalIgnoreCase);Normalized=((&$normalizePath $_.Expected).Equals((&$normalizePath $_.Actual),[StringComparison]::OrdinalIgnoreCase));ExpectedLength=$_.Expected.Length;ActualLength=$_.Actual.Length}})
        $tempEvidence=@($expected|Where-Object Role -in @('tempdb-data','tempdb-log')|ForEach-Object{$expectedFile=$_;$actual=@($after.TempDb|Where-Object { [string]$_.LogicalName -eq [string]$expectedFile.LogicalName });$actualPath=if($actual.Count -eq 1){[string]$actual[0].SqlPhysicalPath}else{''};[pscustomobject]@{LogicalName=[string]$expectedFile.LogicalName;Count=$actual.Count;Exact=($actual.Count -eq 1 -and $actualPath.Equals([string]$expectedFile.SqlPhysicalPath,[StringComparison]::OrdinalIgnoreCase));Normalized=($actual.Count -eq 1 -and (&$normalizePath $actualPath).Equals((&$normalizePath ([string]$expectedFile.SqlPhysicalPath)),[StringComparison]::OrdinalIgnoreCase));ExpectedLength=([string]$expectedFile.SqlPhysicalPath).Length;ActualLength=$actualPath.Length}})
        # SQL directory properties can include a trailing separator; file paths stay exact.
        $defaultsOk=@($defaultEvidence|Where-Object { $_.Normalized -and $_.ExpectedLength -gt 0 -and $_.ActualLength -gt 0 }).Count -eq $defaultEvidence.Count;$tempOk=@($tempEvidence|Where-Object Exact).Count -eq $tempEvidence.Count
        $resultOk=[string]$result.ExecutionSummary.Status -eq 'SUCCEEDED';$receiptResultOk=[string]$result.ExecutionPlan[0].Result.ReceiptStatus -eq 'VERIFIED';$receiptOk=[string]$receiptAfter.Status -eq 'VERIFIED';$sqlRestarted=$after.Defaults.SqlStartTime -ne $sqlStartBefore;$guestBootUnchanged=$bootAfter -eq $bootBefore;$vmRunning=[string]((Get-OwnedManagedVm $context).VM.State) -eq 'Running'
        $convergenceEvidence="result=$resultOk receiptResult=$receiptResultOk receipt=$receiptOk defaults=$defaultsOk tempdb=$tempOk sqlRestarted=$sqlRestarted guestBootUnchanged=$guestBootUnchanged vmRunning=$vmRunning expectedFiles=$(@($expected).Count) observedTempDb=$(@($after.TempDb).Count) defaultsDetail=$((@($defaultEvidence|ForEach-Object{"$($_.Role):exact=$($_.Exact),normalized=$($_.Normalized),length=$($_.ExpectedLength)/$($_.ActualLength)"}) -join ';')) tempdbDetail=$((@($tempEvidence|ForEach-Object{"$($_.LogicalName):count=$($_.Count),exact=$($_.Exact),normalized=$($_.Normalized),length=$($_.ExpectedLength)/$($_.ActualLength)"}) -join ';'))"
        Assert-HyperVSqlStorageAcceptance ($resultOk -and $receiptResultOk -and $receiptOk -and $defaultsOk -and $tempOk -and $sqlRestarted -and $guestBootUnchanged -and $vmRunning) "Receipt, SQL-Defaults und TempDB konvergieren nach SQL-Dienstrestart ohne VM-Neustart: $convergenceEvidence"
        $noOp=Get-SqlServerLabReconcilePlan -RunId $lab.RunId -HyperVSqlStorage -InstanceId primary -StateRoot $StateRoot
        Assert-HyperVSqlStorageAcceptance ($noOp.IsNoOp -and @($noOp.Actions).Count -eq 0) 'Wiederholter HV-603A-Plan ist No-op'
        if ($VerifyLibraryRestore) { Invoke-StorageLibraryRestoreAcceptance -Context $context -GuestCredential $guestCredential -ExpectedVmId $managed.VM.Id -ExpectedStoragePlanId $receiptAfter.PlanId }
    }
    $cleanup=Remove-SqlServerLab -RunId $lab.RunId -StateRoot $StateRoot -Force -Confirm:$false;Assert-HyperVSqlStorageAcceptance ([string]$cleanup.Status -in @('REMOVED','COMPLETED')) 'Operationseigener Run wurde scopegebunden entfernt';$lab=$null;foreach($path in $ownedPaths){Assert-HyperVSqlStorageAcceptance (-not(Test-Path -LiteralPath $path)) 'Run-eigene VHDX wurde entfernt'};$completed=$true
}
catch {
    if(-not $lab -and $ownsOperation){
        $recovered=Invoke-Private {param($Op,$Root)Get-LabOperationOwnedRun -OperationId $Op -StateRoot $Root} @($OperationId,$StateRoot)
        if($recovered){$lab=[pscustomobject]@{RunId=[string]$recovered.runId}}
    }
    if($lab -and $KeepOnFailure){Write-Host "RECOVERY_RUN_ID=$([string]$lab.RunId)";Write-Host "RECOVERY_MANIFEST_ROOT=$testRoot"}
    throw
}
finally { $script:saPassword=$null;if($lab -and -not $KeepOnFailure){try{Remove-SqlServerLab -RunId ([string]$lab.RunId) -StateRoot $StateRoot -Force -Confirm:$false|Out-Null}catch{Write-Warning 'HYPERV_SQL_STORAGE_ACCEPTANCE_OWNED_CLEANUP_FAILED'}};if(($completed -or -not $KeepOnFailure) -and (Test-Path $testRoot)){if(-not(Test-ScopedTemporaryRoot $testRoot)){throw 'HYPERV_SQL_STORAGE_ACCEPTANCE_TEMP_SCOPE_INVALID'};Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue};if($previousStateRoot){$env:SQL_SERVER_LAB_STATE=$previousStateRoot}else{Remove-Item Env:SQL_SERVER_LAB_STATE -ErrorAction SilentlyContinue};if($mutexAcquired){$mutex.ReleaseMutex()};$mutex.Dispose() }
Write-Host 'Native Hyper-V-SQL-Storage-Reconcile-Akzeptanz erfolgreich.' -ForegroundColor Green
