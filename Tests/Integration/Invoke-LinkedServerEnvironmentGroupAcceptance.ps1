#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft gruppierte Linked-Server-Runs, Collation-Konflikt und explizite Auflösung.
.DESCRIPTION
    Erstellt genau zwei eigene Docker- oder Podman-Runs auf demselben frisch
    benannten Container-Netz, bindet sie an eine sowie den Ziel-Run zusätzlich
    an eine zweite Umgebungsgruppe und prüft eine read-only SQL-Abfrage über
    MSOLEDBSQL, erzwingt eine inkompatible Collation-Gegenprobe und prüft die
    read-only Abfrage erneut mit explizit vereinheitlichter Collation.
    Anschließend wird die geteilte Gruppen-Laufzeitnachfrage geprüft.
    Fehlerbelege enthalten nur die Operationsphase und strukturierte SQL-Fehlercodes.
    Falls das konfigurierte Provider-Subnetz mit einem bekannten Netz kollidiert,
    waehlt der Test einen freien /24-Bereich ausschliesslich im aktuellen Prozess
    und stellt den vorherigen Prozesswert danach wieder her.
    Der Test belegt keine TLS-Identitätsprüfung, Kerberos-Delegierung oder MSDTC.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [ValidateSet('docker','podman')][string]$Provider = 'docker',
    [ValidateSet('2025-CU9')][string]$Version = '2025-CU9'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$evidenceRoot = [IO.Path]::GetFullPath($EvidenceDirectory)
if (Test-Path -LiteralPath $evidenceRoot) { throw 'LINKED_SERVER_EVIDENCE_DIRECTORY_MUST_BE_NEW' }
if ($evidenceRoot.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'LINKED_SERVER_EVIDENCE_MUST_REMAIN_OUTSIDE_REPOSITORY' }

$resolution = @(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
if (-not $resolution.Available) { throw 'LINKED_SERVER_PROVIDER_UNAVAILABLE' }
$runtime = [string]$resolution.Invocation
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop
$labMessageSequenceAtStart = [int](& $module { (Get-LabMessage).Count })
$operationId = [guid]::NewGuid().ToString('N')
$stateRoot = Join-Path $evidenceRoot 'state'
$evidenceRootOwnerMarker = Join-Path $evidenceRoot '.linked-server-acceptance-evidence-owner'
$stateRootOwnerMarker = Join-Path $stateRoot '.linked-server-acceptance-owner'
$evidenceRootCreatedByThisInvocation = $false
$evidenceRootOwnershipVerified = $false
$stateRootCreatedByThisInvocation = $false
$stateRootOwnershipVerified = $false
$networkName = "sql-lab-ls-$($operationId.Substring(0,16))"
$sourceName = "ls-src-$($operationId.Substring(0,8))"
$targetName = "ls-tgt-$($operationId.Substring(0,8))"
$sourceContainer = $null
$targetContainer = $null
$sourceRun = $null
$targetRun = $null
$sourcePassword = $null
$targetPassword = $null
$remotePassword = $null
$remotePasswordText = $null
$firstGroup = $null
$secondGroup = $null
$networkId = $null
$networkCreationAttempted = $false
$networkSubnet = $null
$networkSubnetVariable = if ($Provider -eq 'docker') { 'SQL_SERVER_LAB_DOCKER_SUBNET' } else { 'SQL_SERVER_LAB_PODMAN_SUBNET' }
$previousProcessNetworkSubnet = [Environment]::GetEnvironmentVariable($networkSubnetVariable, 'Process')
$networkSubnetOverridden = $false
$failureStage = 'PREFLIGHT'
$linkedServerName = "LS_$($operationId.Substring(0,12))"
$databaseName = "LSDB_$($operationId.Substring(0,8))"
$loginName = "ls_reader_$($operationId.Substring(0,8))"
$tableName = 'Probe'
$marker = "linked-$operationId"
$failure = $null
$failureCode = $null
$failureArgumentParameter = $null
$knownArgumentParameters = @('connectionString','name','parameterName','password','size','sqlDbType','userId','value')
$knownFailureCodes = @(
    'UNIQUE_NETWORK_ABSENT_BEFORE_ARRANGE','SOURCE_RUN_CREATED','TARGET_RUN_CREATED','DISTINCT_SQL_CONTAINER_ENDPOINTS',
    'FIRST_GROUP_HAS_BOTH_RUNS','SECOND_GROUP_REUSES_TARGET_RUN','BOTH_GROUP_MEMBERS_RUNNING',
    'OPENQUERY_RETURNED_SYNTHETIC_TARGET_MARKER','OPENQUERY_COLLATION_CONFLICT_REJECTED','OPENQUERY_EXPLICIT_COLLATION_RECONCILED',
    'SHARED_TARGET_RETAINED_WHILE_SECOND_GROUP_ACTIVE','TARGET_STOPS_AFTER_LAST_GROUP_RELEASES',
    'LINKED_SERVER_CREATE','LINKED_SERVER_EVIDENCE_DIRECTORY_MUST_BE_NEW','LINKED_SERVER_EVIDENCE_MUST_REMAIN_OUTSIDE_REPOSITORY',
    'LINKED_SERVER_FIRST_GROUP_START_FAILED','LINKED_SERVER_FIRST_GROUP_STOP_FAILED','LINKED_SERVER_GROUP_REMAINS_IN_RECOVERY',
    'LINKED_SERVER_GROUP_REMOVE_UNCONFIRMED','LINKED_SERVER_LOGIN_MAPPING','LINKED_SERVER_NETWORK_ABSENCE_UNCONFIRMED',
    'LINKED_SERVER_NETWORK_CLEANUP_BINDING_INVALID','LINKED_SERVER_NETWORK_ID_INVALID','LINKED_SERVER_NETWORK_INSPECT_FAILED',
    'LINKED_SERVER_NETWORK_LIST_FAILED','LINKED_SERVER_NETWORK_OWNERSHIP_INVALID','LINKED_SERVER_NETWORK_REMOVE_FAILED',
    'LINKED_SERVER_NO_AVAILABLE_TEST_NETWORK_SUBNET','LINKED_SERVER_PREPARE_MEMBER_STOP_FAILED','LINKED_SERVER_PROVIDER_UNAVAILABLE',
    'LINKED_SERVER_RUN_BINDING_INVALID','LINKED_SERVER_RUN_CONTAINER_BINDING_INVALID','LINKED_SERVER_RUN_CONTAINER_OWNERSHIP_INVALID',
    'LINKED_SERVER_RUN_PROVIDER_OR_VERSION_INVALID','LINKED_SERVER_RUN_REMOVE_UNCONFIRMED','LINKED_SERVER_RUN_SECRET_MISSING',
    'LINKED_SERVER_RUN_SHARED_NETWORK_BINDING_INVALID','LINKED_SERVER_RUN_STILL_GROUP_REFERENCED','LINKED_SERVER_RUNTIME_MUTEX_ABANDONED',
    'LINKED_SERVER_RUNTIME_MUTEX_BUSY','LINKED_SERVER_RUNTIME_NOT_REACHABLE','LINKED_SERVER_SECOND_GROUP_START_FAILED',
    'LINKED_SERVER_SECOND_GROUP_STOP_FAILED','LINKED_SERVER_SQL_FIXTURE_CLEANUP_FAILED','LINKED_SERVER_TEST_NETWORK_SUBNET_INVALID',
    'LINKED_SERVER_UNBOUND_NETWORK_CLEANUP_NOT_SAFE','LINKED_SERVER_STATE_ROOT_MUST_BE_NEW',
    'LINKED_SERVER_EVIDENCE_ROOT_BINDING_UNCONFIRMED','OWN_STATE_ROOT_BINDING_UNCONFIRMED',
    'OWN_NETWORK_RECOVERY_UNCONFIRMED','OWN_NETWORK_ID_NOT_CAPTURED',
    'OWN_RUN_INVENTORY_UNCLASSIFIED','OWN_RUN_CLEANUP_UNCONFIRMED','OWN_NETWORK_CLEANUP_BLOCKED_BY_RUN',
    'SOURCE_LINKED_SERVER_DROP_FAILED','TARGET_SQL_FIXTURE_DROP_FAILED',
    'SQL_CLIENT_ERROR','UNCLASSIFIED_EXCEPTION'
)
$runCleanupConfirmed = $true
$groupCleanupConfirmed = $true
$networkCleanupConfirmed = $true
$sqlCleanupPerformed = $false
$failureExceptionType = $null
$failureOrigin = $null
$failureSqlNumber = $null
$failureSqlState = $null
$failureSqlClass = $null
$failureSqlCategory = $null
$failureSqlErrorNumbers = @()
$failureHResult = $null
$cleanupFailures = [Collections.Generic.List[string]]::new()
$sqlCleanupFailures = [Collections.Generic.List[string]]::new()
$steps = [Collections.Generic.List[string]]::new()
$runIdsToRemove = [Collections.Generic.List[string]]::new()
$lease = [Threading.Mutex]::new($false, 'Global\SQL_Server_Lab_Runtime_Smoke')
$leaseHeld = $false

function Assert-LinkedServerAcceptance {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw $Code }
    $null = $steps.Add($Code)
}

function Find-LinkedServerSqlException {
    param([Parameter(Mandatory)][Exception]$Exception)
    $depth = 0
    for ($current = $Exception; $current; $current = $current.InnerException) {
        if ($depth++ -ge 20) { break }
        if ($current -is [Data.SqlClient.SqlException]) { return $current }
    }
    return $null
}

function Get-LinkedServerSqlFailureCategory {
    param([Parameter(Mandatory)][Data.SqlClient.SqlException]$Exception)
    $messages = @($Exception.Errors | Select-Object -First 20 | ForEach-Object { [string]$_.Message })
    $combined = $messages -join "`n"
    if ($combined -match '(?i)(cannot create an instance of OLE DB provider|provider .+ not registered|class not registered|provider could not be loaded)') { return 'OLEDB_PROVIDER_UNAVAILABLE' }
    if ($combined -match '(?i)(network-related|server was not found|not accessible|timed out|timeout expired|actively refused|connection refused|could not open a connection|error locating server|TCP Provider)') { return 'REMOTE_CONNECTIVITY' }
    if ($combined -match '(?i)(login failed|not associated with a trusted SQL Server connection)') { return 'REMOTE_LOGIN_REJECTED' }
    if ($combined -match '(?i)(certificate|SSL Provider|TLS|encrypt|encryption)') { return 'REMOTE_ENCRYPTION_NEGOTIATION' }
    if ($combined -match '(?i)(permission was denied|does not have permission|not authorized)') { return 'REMOTE_PERMISSION_DENIED' }
    if ($combined -match '(?i)(invalid object|invalid column|incorrect syntax|cannot open database|does not exist)') { return 'REMOTE_SQL_OBJECT_OR_SYNTAX' }
    return 'UNCLASSIFIED_SQL_ERROR'
}

function Get-LinkedServerFailureOrigin {
    param([Parameter(Mandatory)][Exception]$Exception)
    $originMap = @{
        'System.Data.SqlClient.SqlCredential::.ctor'='SQL_CREDENTIAL_CONSTRUCTOR'
        'System.Data.SqlClient.SqlConnection::set_Credential'='SQL_CREDENTIAL_ASSIGNMENT'
        'System.Data.SqlClient.SqlConnection::set_ConnectionString'='SQL_CONNECTION_STRING_ASSIGNMENT'
        'System.Data.SqlClient.SqlConnection::Open'='SQL_CONNECTION_OPEN'
        'System.Data.SqlClient.SqlConnectionStringBuilder::set_DataSource'='SQL_DATA_SOURCE_ASSIGNMENT'
        'System.Data.SqlClient.SqlParameterCollection::Add'='SQL_PARAMETER_ADD'
        'System.Data.SqlClient.SqlParameter::set_Value'='SQL_PARAMETER_VALUE'
        'System.Data.SqlClient.SqlCommand::ExecuteNonQuery'='SQL_COMMAND_EXECUTION'
        'System.Data.SqlClient.SqlCommand::ExecuteScalar'='SQL_SCALAR_EXECUTION'
    }
    foreach ($frame in [Diagnostics.StackTrace]::new($Exception,$true).GetFrames()) {
        $method = $frame.GetMethod()
        if (-not $method -or -not $method.DeclaringType) { continue }
        $key = "$($method.DeclaringType.FullName)::$($method.Name)"
        if ($originMap.ContainsKey($key)) { return [string]$originMap[$key] }
    }
    return 'UNCLASSIFIED'
}

function ConvertFrom-LinkedServerSecureString {
    param([Parameter(Mandatory)][SecureString]$Value)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function New-LinkedServerSqlConnection {
    param([Parameter(Mandatory)]$Instance, [Parameter(Mandatory)][SecureString]$Password)
    if (-not $script:failure -and $script:sqlCleanupFailures.Count -eq 0) { $script:failureStage = 'SQL_CONNECTION_STRING_BUILDER_CREATE' }
    $builder = [Data.SqlClient.SqlConnectionStringBuilder]::new()
    if (-not $script:failure -and $script:sqlCleanupFailures.Count -eq 0) { $script:failureStage = 'SQL_DATA_SOURCE_ASSIGNMENT' }
    $builder['Data Source'] = "$([string]$Instance.host),$([int]$Instance.port)"
    if (-not $script:failure -and $script:sqlCleanupFailures.Count -eq 0) { $script:failureStage = 'SQL_CONNECTION_STRING_OPTIONS' }
    $builder['Initial Catalog'] = 'master'
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = $true
    $builder['Connect Timeout'] = 15
    $builder['Pooling'] = $false
    if (-not $script:failure -and $script:sqlCleanupFailures.Count -eq 0) { $script:failureStage = 'SQL_CREDENTIAL_CREATE' }
    if (-not $Password.IsReadOnly()) { $Password.MakeReadOnly() }
    $credential = [Data.SqlClient.SqlCredential]::new('sa', $Password)
    if (-not $script:failure -and $script:sqlCleanupFailures.Count -eq 0) { $script:failureStage = 'SQL_CONNECTION_OBJECT_CREATE' }
    $connection = [Data.SqlClient.SqlConnection]::new($builder.ConnectionString,$credential)
    return $connection
}

function Invoke-LinkedServerSql {
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)][SecureString]$Password,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][ValidateSet('TARGET_SQL_FIXTURE_CREATE','LINKED_SERVER_CREATE','LINKED_SERVER_LOGIN_MAPPING','OPENQUERY_EXECUTION','OPENQUERY_COLLATION_CONFLICT_CONTROL','OPENQUERY_EXPLICIT_COLLATION_RECONCILIATION','SOURCE_SQL_CLEANUP','TARGET_SQL_CLEANUP')][string]$OperationStage,
        [System.Collections.IDictionary]$Parameters = @{},
        [switch]$Scalar
    )
    if (-not $script:failure -and $script:sqlCleanupFailures.Count -eq 0) { $script:failureStage = "${OperationStage}_CONNECTION_CREATE" }
    $connection = New-LinkedServerSqlConnection -Instance $Instance -Password $Password
    try {
        if (-not $script:failure -and $script:sqlCleanupFailures.Count -eq 0) { $script:failureStage = "${OperationStage}_CONNECTION_OPEN" }
        $connection.Open()
        $command = $connection.CreateCommand()
        try {
            $command.CommandTimeout = 30
            $command.CommandText = $Query
            if (-not $script:failure -and $script:sqlCleanupFailures.Count -eq 0) { $script:failureStage = "${OperationStage}_PARAMETER_BIND" }
            foreach ($entry in $Parameters.GetEnumerator()) {
                $parameter = $command.Parameters.Add("@$($entry.Key)", [Data.SqlDbType]::NVarChar, 4000)
                $parameter.Value = [string]$entry.Value
            }
            if (-not $script:failure -and $script:sqlCleanupFailures.Count -eq 0) { $script:failureStage = "${OperationStage}_EXECUTE" }
            if ($Scalar) { return $command.ExecuteScalar() }
            $null = $command.ExecuteNonQuery()
        }
        finally { $command.Dispose() }
    }
    finally { $connection.Dispose() }
}

function Get-LinkedServerRunContext {
    param([Parameter(Mandatory)]$Run)
    $runDirectory = Join-Path (Join-Path $stateRoot 'runs') $Run.RunId
    $connectionInfo = Get-Content -LiteralPath (Join-Path $runDirectory 'connection-info.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    if ([string]$connectionInfo.runId -cne [string]$Run.RunId -or @($connectionInfo.instances).Count -ne 1) {
        throw 'LINKED_SERVER_RUN_BINDING_INVALID'
    }
    $instance = $connectionInfo.instances[0]
    if ([string]$instance.provider -cne $Provider -or [string]$instance.version -cne $Version) {
        throw 'LINKED_SERVER_RUN_PROVIDER_OR_VERSION_INVALID'
    }
    $secret = & $module { param($Path) Get-LabSecret -Path $Path -Name 'sa-password' } $runDirectory
    if ($secret -isnot [SecureString]) { throw 'LINKED_SERVER_RUN_SECRET_MISSING' }
    $container = @(& $runtime ps -a -q --no-trunc --filter "label=sql-server-lab.run-id=$($Run.RunId)" |
        ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^[0-9a-f]{12,64}$' })
    if ($container.Count -ne 1) { throw 'LINKED_SERVER_RUN_CONTAINER_BINDING_INVALID' }
    $inspect = @(& $runtime inspect $container[0] | ConvertFrom-Json -Depth 40 -ErrorAction Stop)[0]
    if ([string]$inspect.Id -cne [string]$container[0] -or
        [string]$inspect.Config.Labels.'sql-server-lab.run-id' -cne [string]$Run.RunId -or
        [string]$inspect.Config.Labels.'sql-server-lab.scope-id' -cne [string]$Run.ScopeId) {
        throw 'LINKED_SERVER_RUN_CONTAINER_OWNERSHIP_INVALID'
    }
    $net = $inspect.NetworkSettings.Networks.PSObject.Properties[$networkName]
    if (-not $net -or [string]$net.Value.IPAddress -notmatch '^\d{1,3}(?:\.\d{1,3}){3}$') {
        throw 'LINKED_SERVER_RUN_SHARED_NETWORK_BINDING_INVALID'
    }
    [PSCustomObject]@{
        RunId=[string]$Run.RunId; ScopeId=[string]$Run.ScopeId; Instance=$instance
        ContainerId=[string]$container[0]; ContainerName=([string]$inspect.Name).TrimStart('/')
        NetworkAddress=[string]$net.Value.IPAddress; Password=$secret
    }
}

function Remove-LinkedServerSqlObjects {
    if ($sourceContext -and $sourcePassword) {
        try {
            $null = Invoke-LinkedServerSql -Instance $sourceContext.Instance -Password $sourcePassword -OperationStage SOURCE_SQL_CLEANUP -Query @'
IF EXISTS (SELECT 1 FROM sys.servers WHERE name = @server)
    EXEC master.dbo.sp_dropserver @server=@server, @droplogins=N'droplogins';
'@ -Parameters @{server=$linkedServerName}
        }
        catch { $sqlCleanupFailures.Add('SOURCE_LINKED_SERVER_DROP_FAILED') }
    }
    if ($targetContext -and $targetPassword) {
        try {
            $null = Invoke-LinkedServerSql -Instance $targetContext.Instance -Password $targetPassword -OperationStage TARGET_SQL_CLEANUP -Query @'
IF DB_ID(@database) IS NOT NULL
BEGIN
    DECLARE @drop nvarchar(max) = N'ALTER DATABASE ' + QUOTENAME(@database) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@database) + N';';
    EXEC(@drop);
END;
IF SUSER_ID(@login) IS NOT NULL
BEGIN
    DECLARE @dropLogin nvarchar(max) = N'DROP LOGIN ' + QUOTENAME(@login) + N';';
    EXEC(@dropLogin);
END;
'@ -Parameters @{database=$databaseName;login=$loginName}
        }
        catch { $sqlCleanupFailures.Add('TARGET_SQL_FIXTURE_DROP_FAILED') }
    }
}

function Get-GroupState {
    param($Group)
    if (-not $Group) { return $null }
    return @((Get-SqlServerLabEnvironmentGroup -GroupId $Group.GroupId -StateRoot $stateRoot))[0]
}

try {
    try { $leaseHeld = $lease.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $leaseHeld = $true; throw 'LINKED_SERVER_RUNTIME_MUTEX_ABANDONED' }
    if (-not $leaseHeld) { throw 'LINKED_SERVER_RUNTIME_MUTEX_BUSY' }
    $null = & $runtime info 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'LINKED_SERVER_RUNTIME_NOT_REACHABLE' }

    $networkSelection = & $module {
        param($SelectedProvider)
        $network = Get-LabRuntimeNetwork -Provider $SelectedProvider
        $knownSubnets = @(Get-LabKnownIpv4Subnets -Provider $SelectedProvider)
        try {
            Assert-LabRuntimeNetworkAvailable -Network $network -KnownSubnets $knownSubnets
            return [PSCustomObject]@{Subnet=[string]$network.Subnet;Override=$false}
        }
        catch {
            if ($_.Exception.Message -notmatch '^LAB_NETWORK_SUBNET_CONFLICT:') { throw }
        }
        $providerOffset = if ($SelectedProvider -eq 'docker') { 0 } else { 256 }
        foreach ($index in 0..255) {
            $candidateSubnet = "198.$([int](18 + [math]::Floor(($providerOffset + $index) / 256))).$([int](($providerOffset + $index) % 256)).0/24"
            $candidate = [PSCustomObject]@{Name=[string]$network.Name;Subnet=$candidateSubnet}
            try {
                Assert-LabRuntimeNetworkAvailable -Network $candidate -KnownSubnets $knownSubnets
                return [PSCustomObject]@{Subnet=$candidateSubnet;Override=$true}
            }
            catch {
                if ($_.Exception.Message -notmatch '^LAB_NETWORK_SUBNET_CONFLICT:') { throw }
            }
        }
        throw 'LINKED_SERVER_NO_AVAILABLE_TEST_NETWORK_SUBNET'
    } $Provider
    $networkSubnet = [string]$networkSelection.Subnet
    if (-not $networkSubnet -or $networkSubnet -notmatch '^\d{1,3}(?:\.\d{1,3}){3}/24$') { throw 'LINKED_SERVER_TEST_NETWORK_SUBNET_INVALID' }
    if ($networkSelection.Override) {
        [Environment]::SetEnvironmentVariable($networkSubnetVariable, $networkSubnet, 'Process')
        $networkSubnetOverridden = $true
    }

    $null = New-Item -ItemType Directory -Path $evidenceRoot -ErrorAction Stop
    $evidenceRootCreatedByThisInvocation = $true
    $markerBytes = [Text.Encoding]::UTF8.GetBytes($operationId)
    $evidenceMarkerStream = [IO.File]::Open($evidenceRootOwnerMarker,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $evidenceMarkerStream.Write($markerBytes,0,$markerBytes.Length); $evidenceMarkerStream.Flush($true) }
    finally { $evidenceMarkerStream.Dispose() }
    $evidenceRootOwnershipVerified = $true
    if (Test-Path -LiteralPath $stateRoot) { throw 'LINKED_SERVER_STATE_ROOT_MUST_BE_NEW' }
    $null = New-Item -ItemType Directory -Path $stateRoot -ErrorAction Stop
    $stateRootCreatedByThisInvocation = $true
    $markerStream = [IO.File]::Open($stateRootOwnerMarker,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $markerStream.Write($markerBytes,0,$markerBytes.Length); $markerStream.Flush($true) }
    finally { $markerStream.Dispose() }
    $networkBefore = @(& $runtime network inspect $networkName 2>$null | ConvertFrom-Json -Depth 20)[0]
    Assert-LinkedServerAcceptance ($null -eq $networkBefore) 'UNIQUE_NETWORK_ABSENT_BEFORE_ARRANGE'

    $failureStage = 'SOURCE_RUN_CREATE'
    $networkCreationAttempted = $true
    $sourceRun = New-SqlServerLab -Provider $Provider -Version $Version -Profile compact -Cpu 2 -MemoryMB 3072 `
        -StateRoot $stateRoot -NetworkName $networkName -LabName $sourceName -InstanceId source -GenerateSaPassword -NonInteractive -SkipAssessment
    $sourceContext = Get-LinkedServerRunContext -Run $sourceRun
    $sourcePassword = $sourceContext.Password
    Assert-LinkedServerAcceptance ([string]$sourceRun.State -eq 'Running') 'SOURCE_RUN_CREATED'
    $failureStage = 'SOURCE_RUN_NETWORK_BINDING'
    $networkInspect = @(& $runtime network inspect $networkName | ConvertFrom-Json -Depth 30 -ErrorAction Stop)[0]
    if ([string]$networkInspect.Labels.'sql-server-lab.network' -cne 'managed') { throw 'LINKED_SERVER_NETWORK_OWNERSHIP_INVALID' }
    $networkId = [string]$(if ($networkInspect.Id) { $networkInspect.Id } else { $networkInspect.id })
    if ($networkId -notmatch '^[0-9a-f]{12,64}$') { throw 'LINKED_SERVER_NETWORK_ID_INVALID' }

    $failureStage = 'TARGET_RUN_CREATE'
    $targetRun = New-SqlServerLab -Provider $Provider -Version $Version -Profile compact -Cpu 2 -MemoryMB 3072 `
        -StateRoot $stateRoot -NetworkName $networkName -LabName $targetName -InstanceId target -GenerateSaPassword -NonInteractive -SkipAssessment
    $targetContext = Get-LinkedServerRunContext -Run $targetRun
    $targetPassword = $targetContext.Password
    Assert-LinkedServerAcceptance ([string]$targetRun.State -eq 'Running') 'TARGET_RUN_CREATED'
    $failureStage = 'TARGET_RUN_NETWORK_BINDING'
    $sourceContext = Get-LinkedServerRunContext -Run $sourceRun
    $targetContext = Get-LinkedServerRunContext -Run $targetRun
    $sourcePassword = $sourceContext.Password
    $targetPassword = $targetContext.Password
    $sourceContainer = $sourceContext.ContainerId
    $targetContainer = $targetContext.ContainerId
    Assert-LinkedServerAcceptance ($sourceContext.NetworkAddress -ne $targetContext.NetworkAddress) 'DISTINCT_SQL_CONTAINER_ENDPOINTS'

    $failureStage = 'GROUP_BINDING_AND_LIFECYCLE'
    $firstGroup = (New-SqlServerLabEnvironmentGroup -Name "Linked Server $($operationId.Substring(0,8))" -StateRoot $stateRoot).Group
    Add-SqlServerLabEnvironmentGroupMember -GroupId $firstGroup.GroupId -RunId $sourceRun.RunId -StateRoot $stateRoot | Out-Null
    Add-SqlServerLabEnvironmentGroupMember -GroupId $firstGroup.GroupId -RunId $targetRun.RunId -StateRoot $stateRoot | Out-Null
    $secondGroup = (New-SqlServerLabEnvironmentGroup -Name "Shared Target $($operationId.Substring(0,8))" -StateRoot $stateRoot).Group
    Add-SqlServerLabEnvironmentGroupMember -GroupId $secondGroup.GroupId -RunId $targetRun.RunId -StateRoot $stateRoot | Out-Null
    Assert-LinkedServerAcceptance (@((Get-SqlServerLabEnvironmentGroup -GroupId $firstGroup.GroupId -StateRoot $stateRoot).Members).Count -eq 2) 'FIRST_GROUP_HAS_BOTH_RUNS'
    Assert-LinkedServerAcceptance (@((Get-SqlServerLabEnvironmentGroup -GroupId $secondGroup.GroupId -StateRoot $stateRoot).Members).Count -eq 1) 'SECOND_GROUP_REUSES_TARGET_RUN'

    foreach ($runId in @($sourceRun.RunId,$targetRun.RunId)) {
        $stopped = Stop-SqlServerLab -RunId $runId -StateRoot $stateRoot -Force -Confirm:$false
        if ([string]$stopped.Status -notin @('STOPPED','ALREADY_STOPPED')) { throw 'LINKED_SERVER_PREPARE_MEMBER_STOP_FAILED' }
    }
    $startedFirst = Start-SqlServerLabEnvironmentGroup -GroupId $firstGroup.GroupId -StateRoot $stateRoot -TimeoutSeconds 240 -Confirm:$false
    if ([string]$startedFirst.Status -notin @('COMPLETED','STARTED','READY') -or [int]$startedFirst.Errors -gt 0) { throw 'LINKED_SERVER_FIRST_GROUP_START_FAILED' }
    $startedSecond = Start-SqlServerLabEnvironmentGroup -GroupId $secondGroup.GroupId -StateRoot $stateRoot -TimeoutSeconds 240 -Confirm:$false
    if ([string]$startedSecond.Status -notin @('COMPLETED','STARTED','READY','ALREADY_ACTIVE') -or [int]$startedSecond.Errors -gt 0) { throw 'LINKED_SERVER_SECOND_GROUP_START_FAILED' }
    Assert-LinkedServerAcceptance ((Get-SqlServerLab -RunId $sourceRun.RunId -StateRoot $stateRoot).State -eq 'RUNNING' -and
        (Get-SqlServerLab -RunId $targetRun.RunId -StateRoot $stateRoot).State -eq 'RUNNING') 'BOTH_GROUP_MEMBERS_RUNNING'
    # A provider may assign a new container IP after stop/start. Bind SQL
    # traffic to the current endpoint observed only after both groups are active.
    $failureStage = 'ACTIVE_GROUP_SQL_ENDPOINT_REFRESH'
    $sourceContext = Get-LinkedServerRunContext -Run $sourceRun
    $targetContext = Get-LinkedServerRunContext -Run $targetRun
    Assert-LinkedServerAcceptance ($sourceContext.NetworkAddress -ne $targetContext.NetworkAddress) 'ACTIVE_GROUP_SQL_ENDPOINTS_DISTINCT'

    $remotePassword = ConvertTo-SecureString "LS_${operationId}!Aa9" -AsPlainText -Force
    $remotePasswordText = ConvertFrom-LinkedServerSecureString -Value $remotePassword
    $loginLiteral = $loginName.Replace("'", "''")
    $databaseLiteral = $databaseName.Replace("'", "''")
    $failureStage = 'TARGET_SQL_FIXTURE_CREATE'
    $null = Invoke-LinkedServerSql -Instance $targetContext.Instance -Password $targetPassword -OperationStage TARGET_SQL_FIXTURE_CREATE -Query @'
DECLARE @createLogin nvarchar(max) = N'CREATE LOGIN ' + QUOTENAME(@login) + N' WITH PASSWORD = ' + QUOTENAME(@password, '''') + N';';
EXEC(@createLogin);
DECLARE @createDatabase nvarchar(max) = N'CREATE DATABASE ' + QUOTENAME(@database) + N';';
EXEC(@createDatabase);
DECLARE @createFixture nvarchar(max) = N'USE ' + QUOTENAME(@database) + N'; CREATE USER ' + QUOTENAME(@login) + N' FOR LOGIN ' + QUOTENAME(@login) + N'; CREATE TABLE dbo.Probe(marker nvarchar(96) NOT NULL); INSERT dbo.Probe(marker) VALUES (' + QUOTENAME(@marker, '''') + N'); GRANT SELECT ON dbo.Probe TO ' + QUOTENAME(@login) + N';';
EXEC(@createFixture);
'@ -Parameters @{login=$loginLiteral;password=$remotePasswordText;database=$databaseLiteral;marker=$marker}
    $linkedServerParameters = @{
        server=$linkedServerName;provider='MSOLEDBSQL';dataSource="$($targetContext.NetworkAddress),1433"
        providerString='Encrypt=Optional;TrustServerCertificate=yes;'
    }
    $failureStage = 'LINKED_SERVER_CREATE'
    $null = Invoke-LinkedServerSql -Instance $sourceContext.Instance -Password $sourcePassword -OperationStage LINKED_SERVER_CREATE -Query @'
EXEC master.dbo.sp_addlinkedserver @server=@server, @srvproduct=N'', @provider=@provider,
    @datasrc=@dataSource, @provstr=@providerString;
'@ -Parameters $linkedServerParameters
    $failureStage = 'LINKED_SERVER_LOGIN_MAPPING'
    $null = Invoke-LinkedServerSql -Instance $sourceContext.Instance -Password $sourcePassword -OperationStage LINKED_SERVER_LOGIN_MAPPING -Query @'
EXEC master.dbo.sp_addlinkedsrvlogin @rmtsrvname=@server, @useself=N'False', @locallogin=NULL,
    @rmtuser=@login, @rmtpassword=@password;
'@ -Parameters @{server=$linkedServerName;login=$loginName;password=$remotePasswordText}
    $remotePasswordText = $null
    $failureStage = 'OPENQUERY_EXECUTION'
    $linkedQuery = @'
SELECT marker FROM OPENQUERY([LINKED_SERVER_NAME], 'SELECT marker FROM LINKED_DATABASE.dbo.Probe');
'@
    $linkedQuery = $linkedQuery.Replace('LINKED_SERVER_NAME', $linkedServerName).Replace('LINKED_DATABASE', $databaseName)
    $actual = [string](Invoke-LinkedServerSql -Instance $sourceContext.Instance -Password $sourcePassword -OperationStage OPENQUERY_EXECUTION -Scalar -Query $linkedQuery)
    Assert-LinkedServerAcceptance ($actual -ceq $marker) 'OPENQUERY_RETURNED_SYNTHETIC_TARGET_MARKER'

    $failureStage = 'OPENQUERY_COLLATION_CONFLICT_CONTROL'
    $conflictingCollationQuery = @'
SELECT CASE WHEN @marker COLLATE Latin1_General_100_BIN2 = remote.marker COLLATE SQL_Latin1_General_CP1_CI_AS THEN 1 ELSE 0 END
FROM OPENQUERY([LINKED_SERVER_NAME], 'SELECT marker FROM LINKED_DATABASE.dbo.Probe') AS remote;
'@
    $conflictingCollationQuery = $conflictingCollationQuery.Replace('LINKED_SERVER_NAME', $linkedServerName).Replace('LINKED_DATABASE', $databaseName)
    $collationConflictDetected = $false
    try {
        $null = Invoke-LinkedServerSql -Instance $sourceContext.Instance -Password $sourcePassword -OperationStage OPENQUERY_COLLATION_CONFLICT_CONTROL -Scalar -Query $conflictingCollationQuery -Parameters @{marker=$marker}
    }
    catch {
        $collationSqlFailure = Find-LinkedServerSqlException -Exception $_.Exception
        $collationSqlNumbers = if ($collationSqlFailure) { @($collationSqlFailure.Errors | ForEach-Object { [int]$_.Number }) } else { @() }
        if (-not ($collationSqlNumbers -contains 468)) { throw }
        $collationConflictDetected = $true
    }
    Assert-LinkedServerAcceptance $collationConflictDetected 'OPENQUERY_COLLATION_CONFLICT_REJECTED'

    $failureStage = 'OPENQUERY_EXPLICIT_COLLATION_RECONCILIATION'
    $reconciledCollationQuery = @'
SELECT remote.marker
FROM OPENQUERY([LINKED_SERVER_NAME], 'SELECT marker FROM LINKED_DATABASE.dbo.Probe') AS remote
WHERE remote.marker COLLATE SQL_Latin1_General_CP1_CI_AS = @marker COLLATE SQL_Latin1_General_CP1_CI_AS;
'@
    $reconciledCollationQuery = $reconciledCollationQuery.Replace('LINKED_SERVER_NAME', $linkedServerName).Replace('LINKED_DATABASE', $databaseName)
    $reconciledMarker = [string](Invoke-LinkedServerSql -Instance $sourceContext.Instance -Password $sourcePassword -OperationStage OPENQUERY_EXPLICIT_COLLATION_RECONCILIATION -Scalar -Query $reconciledCollationQuery -Parameters @{marker=$marker})
    Assert-LinkedServerAcceptance ($reconciledMarker -ceq $marker) 'OPENQUERY_EXPLICIT_COLLATION_RECONCILED'

    Remove-LinkedServerSqlObjects
    $sqlCleanupPerformed = $true
    if ($sqlCleanupFailures.Count) { throw 'LINKED_SERVER_SQL_FIXTURE_CLEANUP_FAILED' }
$failureStage = 'SHARED_MEMBER_STOP_VERIFICATION'
    $stoppedFirst = Stop-SqlServerLabEnvironmentGroup -GroupId $firstGroup.GroupId -StateRoot $stateRoot -Confirm:$false
    if ([string]$stoppedFirst.Status -notin @('COMPLETED','STOPPED') -or [int]$stoppedFirst.Errors -gt 0) { throw 'LINKED_SERVER_FIRST_GROUP_STOP_FAILED' }
    $sourceAfterStop = Get-SqlServerLab -RunId $sourceRun.RunId -StateRoot $stateRoot
    $targetAfterStop = Get-SqlServerLab -RunId $targetRun.RunId -StateRoot $stateRoot
    Assert-LinkedServerAcceptance ([string]$sourceAfterStop.State -eq 'STOPPED' -and [string]$targetAfterStop.State -eq 'RUNNING') 'SHARED_TARGET_RETAINED_WHILE_SECOND_GROUP_ACTIVE'
    $stoppedSecond = Stop-SqlServerLabEnvironmentGroup -GroupId $secondGroup.GroupId -StateRoot $stateRoot -Confirm:$false
    if ([string]$stoppedSecond.Status -notin @('COMPLETED','STOPPED') -or [int]$stoppedSecond.Errors -gt 0) { throw 'LINKED_SERVER_SECOND_GROUP_STOP_FAILED' }
    Assert-LinkedServerAcceptance ([string](Get-SqlServerLab -RunId $targetRun.RunId -StateRoot $stateRoot).State -eq 'STOPPED') 'TARGET_STOPS_AFTER_LAST_GROUP_RELEASES'
}
catch {
    $failure = $_
    if ($failureStage -eq 'PREFLIGHT') { $failureStage = 'RUNTIME_ARRANGE' }
    $failureText=[string]$failure.Exception.Message
    $baseFailure=$failure.Exception.GetBaseException()
    $failureExceptionType=[string]$baseFailure.GetType().FullName
    $failureOrigin=Get-LinkedServerFailureOrigin -Exception $baseFailure
    $failureHResult=[int]$baseFailure.HResult
    if ($baseFailure -is [ArgumentException]) {
        $failureArgumentParameter='UNCLASSIFIED'
        if ($baseFailure.ParamName -and $knownArgumentParameters -ccontains [string]$baseFailure.ParamName) {
            $failureArgumentParameter=([string]$baseFailure.ParamName).ToUpperInvariant()
        }
    }
    $sqlFailure=Find-LinkedServerSqlException -Exception $failure.Exception
    if ($sqlFailure) {
        $failureSqlNumber=[int]$sqlFailure.Number
        $failureSqlState=[byte]$sqlFailure.State
        $failureSqlClass=[byte]$sqlFailure.Class
        $failureSqlCategory=Get-LinkedServerSqlFailureCategory -Exception $sqlFailure
        $failureSqlErrorNumbers=@($sqlFailure.Errors | Select-Object -First 20 | ForEach-Object { [int]$_.Number })
    }
    if ($knownFailureCodes -ccontains $failureText) { $failureCode=$failureText }
    elseif ($sqlFailure) { $failureCode='SQL_CLIENT_ERROR' }
    elseif ($baseFailure -is [ArgumentException]) { $failureCode='ARGUMENT_ERROR' }
    else {
        $recordedCodes=@(& $module {
            param($AfterSequence)
            @(Get-LabMessage -Severity Error | Where-Object { [int]$_.sequence -gt $AfterSequence } |
                ForEach-Object { [string]$_.code } | Where-Object { $_ -in @('LAB_NETWORK_SUBNET_CONFLICT','LAB_PROVIDER_NOT_AVAILABLE') })
        } $labMessageSequenceAtStart)
        if ($recordedCodes.Count) { $failureCode=[string]$recordedCodes[-1] }
        else { $failureCode='UNCLASSIFIED_EXCEPTION' }
    }
}
finally {
    if ($leaseHeld -and $stateRootCreatedByThisInvocation) {
        try { $stateRootOwnershipVerified = [IO.File]::ReadAllText($stateRootOwnerMarker,[Text.Encoding]::UTF8) -ceq $operationId }
        catch { $stateRootOwnershipVerified = $false }
    }
    if ($stateRootOwnershipVerified) {
    if (-not $sqlCleanupPerformed -and ($sourceContext -or $targetContext)) {
        Remove-LinkedServerSqlObjects
        $sqlCleanupPerformed = $true
    }
    foreach ($group in @($firstGroup,$secondGroup)) {
        if (-not $group) { continue }
        try {
            $state = Get-GroupState $group
            if ($state.lifecycleState -in @('ACTIVE','STARTING','STOPPING','RECOVERY_REQUIRED')) {
                $null = Stop-SqlServerLabEnvironmentGroup -GroupId $group.GroupId -StateRoot $stateRoot -Force -Confirm:$false
                $state = Get-GroupState $group
            }
            if ($state.lifecycleState -eq 'STOPPED') {
                $removedGroup = Remove-SqlServerLabEnvironmentGroup -GroupId $group.GroupId -StateRoot $stateRoot -Confirm:$false
                $remainingGroup = @((Get-SqlServerLabEnvironmentGroup -StateRoot $stateRoot) | Where-Object { [string]$_.groupId -ceq [string]$group.GroupId })
                if ([string]$removedGroup.Status -ne 'REMOVED' -or $remainingGroup.Count) { throw 'LINKED_SERVER_GROUP_REMOVE_UNCONFIRMED' }
            }
            elseif ($state) { throw 'LINKED_SERVER_GROUP_REMAINS_IN_RECOVERY' }
        }
        catch { $groupCleanupConfirmed = $false; $cleanupFailures.Add('GROUP_CLEANUP_UNCONFIRMED') }
    }
    foreach ($run in @($sourceRun,$targetRun)) {
        if ($run -and $run.RunId -and $runIdsToRemove -notcontains [string]$run.RunId) { $runIdsToRemove.Add([string]$run.RunId) }
    }
    $runDirectoryRoot = Join-Path $stateRoot 'runs'
    if (Test-Path -LiteralPath $runDirectoryRoot -PathType Container) {
        foreach ($runDirectory in @(Get-ChildItem -LiteralPath $runDirectoryRoot -Directory -Force)) {
            $parsedRunId = [guid]::Empty
            if (-not [guid]::TryParse($runDirectory.Name,[ref]$parsedRunId)) {
                $runCleanupConfirmed = $false
                $cleanupFailures.Add('OWN_RUN_INVENTORY_UNCLASSIFIED')
                continue
            }
            $normalizedRunId = $parsedRunId.ToString('D')
            if ($runIdsToRemove -notcontains $normalizedRunId) { $runIdsToRemove.Add($normalizedRunId) }
        }
    }
    foreach ($runId in $runIdsToRemove) {
        try {
            $runState = & $module { param($RunId,$Root) Get-LabRunState -RunId $RunId -StateRoot $Root } $runId $stateRoot
            if ([string]$runState.state -ne 'REMOVED') {
                $groupReferences = @((Get-SqlServerLabEnvironmentGroup -StateRoot $stateRoot) | ForEach-Object { @($_.members | Where-Object { [string]$_.runId -ceq $runId }) })
                if ($groupReferences.Count) { throw 'LINKED_SERVER_RUN_STILL_GROUP_REFERENCED' }
                $removed = Remove-SqlServerLab -RunId $runId -StateRoot $stateRoot -Force -Confirm:$false
                if ([string]$removed.Status -ne 'REMOVED') { throw 'LINKED_SERVER_RUN_REMOVE_UNCONFIRMED' }
                $runState = & $module { param($RunId,$Root) Get-LabRunState -RunId $RunId -StateRoot $Root } $runId $stateRoot
                if ([string]$runState.state -ne 'REMOVED') { throw 'LINKED_SERVER_RUN_REMOVE_UNCONFIRMED' }
            }
            $remainingContainers = @(& $runtime ps -a -q --no-trunc --filter "label=sql-server-lab.run-id=$runId" | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
            if ($LASTEXITCODE -ne 0 -or $remainingContainers.Count) { throw 'LINKED_SERVER_RUN_REMOVE_UNCONFIRMED' }
        }
        catch { $runCleanupConfirmed = $false; $cleanupFailures.Add('OWN_RUN_CLEANUP_UNCONFIRMED') }
    }
    if (-not $runCleanupConfirmed -and -not $cleanupFailures.Contains('OWN_RUN_CLEANUP_UNCONFIRMED')) { $cleanupFailures.Add('OWN_RUN_CLEANUP_UNCONFIRMED') }
    if ($networkCreationAttempted -and -not $networkId -and ($steps -contains 'UNIQUE_NETWORK_ABSENT_BEFORE_ARRANGE')) {
        try {
            $networkNames = @(& $runtime network ls --format '{{.Name}}' | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
            if ($LASTEXITCODE -ne 0) { throw 'LINKED_SERVER_NETWORK_LIST_FAILED' }
            if ($networkNames -ccontains $networkName) {
                $observed = @(& $runtime network inspect $networkName | ConvertFrom-Json -Depth 30 -ErrorAction Stop)[0]
                if ($LASTEXITCODE -ne 0 -or -not $observed -or [string]$observed.Labels.'sql-server-lab.network' -cne 'managed' -or @($observed.Containers.PSObject.Properties).Count -ne 0) {
                    throw 'LINKED_SERVER_UNBOUND_NETWORK_CLEANUP_NOT_SAFE'
                }
                $networkId = [string]$(if ($observed.Id) { $observed.Id } else { $observed.id })
                if ($networkId -notmatch '^[0-9a-f]{12,64}$') { throw 'LINKED_SERVER_NETWORK_ID_INVALID' }
            }
        }
        catch { $networkCleanupConfirmed = $false; $cleanupFailures.Add('OWN_NETWORK_RECOVERY_UNCONFIRMED') }
    }
    elseif ($networkCreationAttempted -and -not $networkId) {
        $networkCleanupConfirmed = $false
        $cleanupFailures.Add('OWN_NETWORK_ID_NOT_CAPTURED')
    }
    if ($networkId -and -not $runCleanupConfirmed) {
        $networkCleanupConfirmed = $false
        $cleanupFailures.Add('OWN_NETWORK_CLEANUP_BLOCKED_BY_RUN')
    }
    if ($networkId -and $runCleanupConfirmed -and $networkCleanupConfirmed) {
        try {
            $networkNames = @(& $runtime network ls --format '{{.Name}}' | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
            if ($LASTEXITCODE -ne 0) { throw 'LINKED_SERVER_NETWORK_LIST_FAILED' }
            if ($networkNames -ccontains $networkName) {
                $observed = @(& $runtime network inspect $networkName | ConvertFrom-Json -Depth 30 -ErrorAction Stop)[0]
                if ($LASTEXITCODE -ne 0 -or -not $observed) { throw 'LINKED_SERVER_NETWORK_INSPECT_FAILED' }
                $observedId = [string]$(if ($observed.Id) { $observed.Id } else { $observed.id })
                $containers = @($observed.Containers.PSObject.Properties)
                if ($observedId -cne $networkId -or [string]$observed.Labels.'sql-server-lab.network' -cne 'managed' -or $containers.Count -ne 0) {
                    throw 'LINKED_SERVER_NETWORK_CLEANUP_BINDING_INVALID'
                }
                $null = & $runtime network rm $networkId
                if ($LASTEXITCODE -ne 0) { throw 'LINKED_SERVER_NETWORK_REMOVE_FAILED' }
                $remainingNetworks = @(& $runtime network ls --format '{{.Name}}' | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
                if ($LASTEXITCODE -ne 0 -or $remainingNetworks -ccontains $networkName) { throw 'LINKED_SERVER_NETWORK_ABSENCE_UNCONFIRMED' }
            }
        }
        catch { $networkCleanupConfirmed = $false; $cleanupFailures.Add('OWN_NETWORK_CLEANUP_UNCONFIRMED') }
    }
    }
    elseif ($stateRootCreatedByThisInvocation -or $networkCreationAttempted -or $sourceRun -or $targetRun -or $firstGroup -or $secondGroup) {
        $groupCleanupConfirmed = $false
        $runCleanupConfirmed = $false
        $networkCleanupConfirmed = $false
        $cleanupFailures.Add('OWN_STATE_ROOT_BINDING_UNCONFIRMED')
    }
            if ($remotePassword) { $remotePassword.Dispose() }
    $remotePasswordText = $null
    if ($sourcePassword) { $sourcePassword.Dispose() }
    if ($targetPassword) { $targetPassword.Dispose() }
    if ($networkSubnetOverridden) { [Environment]::SetEnvironmentVariable($networkSubnetVariable, $previousProcessNetworkSubnet, 'Process') }
    if ($leaseHeld) { $lease.ReleaseMutex() }
    $lease.Dispose()
}

$proof = [ordered]@{
    ContractVersion='SqlServerLab.LinkedServerEnvironmentGroupAcceptance/1.1'
    Status=if ($failure -or $cleanupFailures.Count -or $sqlCleanupFailures.Count) { 'FAIL' } else { 'PASS' }
    Provider=$Provider; Version=$Version; OwnRuns=@($runIdsToRemove)
    FirstGroupId=[string]$(if ($firstGroup) { $firstGroup.GroupId } else { '' })
    SecondGroupId=[string]$(if ($secondGroup) { $secondGroup.GroupId } else { '' })
    NetworkSubnet=$networkSubnet; SameNamedNetwork=($steps -contains 'DISTINCT_SQL_CONTAINER_ENDPOINTS'); LinkedServerQuery=if ($steps -contains 'OPENQUERY_RETURNED_SYNTHETIC_TARGET_MARKER') { 'PASS' } else { 'NOT_CONFIRMED' }
    CollationConflict=if ($steps -contains 'OPENQUERY_COLLATION_CONFLICT_REJECTED') { 'REJECTED_ERROR_468' } else { 'NOT_CONFIRMED' }
    ExplicitCollationResolution=if ($steps -contains 'OPENQUERY_EXPLICIT_COLLATION_RECONCILED') { 'PASS' } else { 'NOT_CONFIRMED' }
    SharedMemberStop=if ($steps -contains 'SHARED_TARGET_RETAINED_WHILE_SECOND_GROUP_ACTIVE') { 'PASS' } else { 'NOT_CONFIRMED' }
    Cleanup=if ($cleanupFailures.Count) { 'RECOVERY_REQUIRED' } else { 'CONFIRMED' }
    SqlFixtureCleanup=if (-not $sqlCleanupFailures.Count) { 'CONFIRMED' } elseif ($runCleanupConfirmed) { 'CONTAINED_BY_OWN_RUN_REMOVAL' } else { 'RECOVERY_REQUIRED' }
    OwnGroupsRemoved=$groupCleanupConfirmed; OwnRunsRemoved=$runCleanupConfirmed
    OwnNetworkRemoved=$networkCleanupConfirmed
    EvidenceRootOwnership=if ($evidenceRootOwnershipVerified) { 'CONFIRMED' } elseif ($evidenceRootCreatedByThisInvocation) { 'UNCONFIRMED' } else { 'NOT_CREATED' }
    StateRootOwnership=if ($stateRootOwnershipVerified) { 'CONFIRMED' } elseif ($stateRootCreatedByThisInvocation) { 'UNCONFIRMED' } else { 'NOT_CREATED' }
    Steps=@($steps); CleanupFailures=@($cleanupFailures); SqlFixtureCleanupFailures=@($sqlCleanupFailures)
    FailureStage=if ($failure) { $failureStage } else { $null }
    FailureCode=$failureCode
    FailureArgumentParameter=$failureArgumentParameter; FailureHResult=$failureHResult
    FailureExceptionType=$failureExceptionType; FailureOrigin=$failureOrigin; FailureSqlCategory=$failureSqlCategory
    FailureSqlErrorNumbers=@($failureSqlErrorNumbers); FailureSqlNumber=$failureSqlNumber
    FailureSqlState=$failureSqlState; FailureSqlClass=$failureSqlClass
    CompletedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
}
$evidenceRootOwnershipVerified = $false
if ($leaseHeld -and $evidenceRootCreatedByThisInvocation) {
    try { $evidenceRootOwnershipVerified = [IO.File]::ReadAllText($evidenceRootOwnerMarker,[Text.Encoding]::UTF8) -ceq $operationId }
    catch { $evidenceRootOwnershipVerified = $false }
}
if (-not $evidenceRootOwnershipVerified) { throw 'LINKED_SERVER_EVIDENCE_ROOT_BINDING_UNCONFIRMED' }
$proof.EvidenceRootOwnership='CONFIRMED'
$proofBytes=[Text.UTF8Encoding]::new($false).GetBytes(($proof | ConvertTo-Json -Depth 12))
try {
    $proofStream=[IO.File]::Open((Join-Path $evidenceRoot 'acceptance.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $proofStream.Write($proofBytes,0,$proofBytes.Length); $proofStream.Flush($true) }
    finally { $proofStream.Dispose() }
}
catch { throw 'LINKED_SERVER_EVIDENCE_PROOF_CREATE_FAILED' }
if ($failure -or $cleanupFailures.Count) { throw 'LINKED_SERVER_ENVIRONMENT_GROUP_ACCEPTANCE_FAILED: see sanitized acceptance.json and own StateRoot' }
$proof
