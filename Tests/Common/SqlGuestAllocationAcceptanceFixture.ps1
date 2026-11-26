# Shared arrange for native SQL guest acceptance. This writes only inside the
# caller's operation-owned guest, which the caller removes during cleanup.
function New-SqlGuestAllocationAcceptanceFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Module,
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][securestring]$GuestPassword,
        [Parameter(Mandatory)][securestring]$SqlPassword,
        [Parameter(Mandatory)][ValidateSet('SqlLabGuestAllocatedPages','SqlLabAllocationComparisonFixture')][string]$DatabaseName
    )

    $received = @(& $Module {
        param($BoundContext,[securestring]$Guest,[securestring]$Sql,[string]$FixtureName)
        $transport = @{
            VMName=$BoundContext.Instance.vmName;ExpectedRunId=$BoundContext.Run.runId
            ExpectedScopeId=$BoundContext.Run.scopeId;ExpectedVmId=[guid]$BoundContext.Instance.vmId
            Credential=[pscredential]::new('Administrator',$Guest);NoRetry=$true;TimeoutSeconds=90
            ArgumentList=@($Sql,[int]$BoundContext.Instance.port,[string]$BoundContext.Instance.sqlReadiness.instanceName,$FixtureName)
        }
        Invoke-HyperVPowerShellDirect @transport -ScriptBlock {
                param([securestring]$Password,[int]$Port,[string]$ExpectedInstance,[string]$Name)

                if ($Name -cnotin @('SqlLabGuestAllocatedPages','SqlLabAllocationComparisonFixture')) {
                    throw 'SQL_GUEST_ALLOCATION_FIXTURE_NAME_INVALID'
                }
                $ErrorActionPreference = 'Stop'
                Add-Type -AssemblyName System.Data
                $secret = $Password.Copy()
                $secret.MakeReadOnly()
                $connection = $null
                $command = $null
                $reader = $null
                try {
                    $builder = [Data.SqlClient.SqlConnectionStringBuilder]::new()
                    $builder['Data Source'] = "tcp:127.0.0.1,$Port"
                    $builder['Initial Catalog'] = 'master'
                    $builder['Encrypt'] = $true
                    $builder['TrustServerCertificate'] = $true
                    $builder['Pooling'] = $false
                    $builder['Persist Security Info'] = $false
                    $builder['Connect Timeout'] = 15
                    $connection = [Data.SqlClient.SqlConnection]::new($builder.ConnectionString,[Data.SqlClient.SqlCredential]::new('sa',$secret))
                    $connection.Open()
                    $command = $connection.CreateCommand()
                    $command.CommandTimeout = 45
                    $command.CommandText = "SELECT CONVERT(int,SERVERPROPERTY('ProductMajorVersion')), COALESCE(CONVERT(nvarchar(128),SERVERPROPERTY('InstanceName')),N'MSSQLSERVER'), DB_ID(N'$Name');"
                    $reader = $command.ExecuteReader()
                    if (-not $reader.Read() -or $reader.GetInt32(0) -ne 17 -or $reader.GetString(1) -cne $ExpectedInstance -or -not $reader.IsDBNull(2)) {
                        throw 'SQL_GUEST_ALLOCATION_FIXTURE_PRECONDITION'
                    }
                    $reader.Dispose()
                    $reader = $null
                    $command.CommandText = "CREATE DATABASE [$Name];"
                    $null = $command.ExecuteNonQuery()
                    $command.CommandText = "SELECT SUM(CASE WHEN type=0 THEN CONVERT(bigint,size) END), SUM(CASE WHEN type=1 THEN CONVERT(bigint,size) END) FROM [$Name].sys.database_files WHERE type IN (0,1);"
                    $reader = $command.ExecuteReader()
                    if (-not $reader.Read()) { throw 'SQL_GUEST_ALLOCATION_FIXTURE_SIZE_UNAVAILABLE' }
                    [pscustomobject]@{DataPages=$reader.GetInt64(0);LogPages=$reader.GetInt64(1)}
                } finally {
                    if ($reader) { $reader.Dispose() }
                    if ($command) { $command.Dispose() }
                    if ($connection) { $connection.Dispose() }
                    $secret.Dispose()
                }
            } -ErrorAction Stop
    } $Context $GuestPassword $SqlPassword $DatabaseName)
    if ($received.Count -ne 1 -or $received[0].DataPages -isnot [long] -or $received[0].LogPages -isnot [long] -or
        $received[0].DataPages -le 0 -or $received[0].LogPages -le 0) {
        throw 'SQL_GUEST_ALLOCATION_FIXTURE_RECEIPT_INVALID'
    }
    [pscustomobject]@{DataPages=$received[0].DataPages;LogPages=$received[0].LogPages}
}
