#Requires -Version 7.2
#Requires -RunAsAdministrator
# Internal child of Invoke-HyperVNetworkReconnectAcceptance.ps1. Parent owns
# the runtime lock, hard timeout and cleanup, including partial clone failures.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$CloneSourceRunId,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$OperationId,
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$MediaRoot,
    [ValidateSet('Enterprise','Standard','Eval')][string]$MediaEdition='Enterprise'
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$password=$null
try {
    $password=& $module {New-HyperVSqlUnattendedPassword}
    $password.MakeReadOnly()
    $run=& $module {
        param($Helper,$Source,$Manifest,$Op,$Root,$Media,$Edition,$Password)
        if(Get-LabOperationOwnedRun -OperationId $Op -StateRoot $Root){throw 'HYPERV_NETWORK_ACCEPTANCE_OPERATION_ALREADY_OWNED'}
        . $Helper
        New-HyperVResourceAcceptanceSlotClone -SourceRunId $Source -ManifestPath $Manifest -OperationId $Op -StateRoot $Root -MediaRoot $Media -MediaEdition $Edition -SqlPassword $Password -RequireExistingNetwork
    } (Join-Path $PSScriptRoot 'HyperVResourceAcceptanceSlotClone.ps1') $CloneSourceRunId $ManifestPath $OperationId $StateRoot $MediaRoot $MediaEdition $password
    if($run.State -ne 'RUNNING' -or [string]$run.RunId -eq $CloneSourceRunId.ToString()){throw 'HYPERV_NETWORK_ACCEPTANCE_CREATED_RUN_INVALID'}
    $context=& $module {param($Id,$Root)Get-HyperVLabWorkflowRun -RunId $Id -StateRoot $Root} $run.RunId $StateRoot
    # SqlCredential avoids putting the generated test secret in the connection
    # string. Use the provider-compatible keyword spelling directly: an older
    # host SqlClient resolved the builder as a generic key store and rejected
    # its DataSource property after SQL provisioning had already completed.
    $connectionString=('Server={0},{1};Database=master;Encrypt=True;TrustServerCertificate=True;Connect Timeout=15;' -f $context.Instance.host,[int]$context.Instance.port)
    $credential=[Data.SqlClient.SqlCredential]::new('sa',$password)
    $marker=[guid]::NewGuid()
    foreach($phase in @('before','after')){
        $deadline=[datetime]::UtcNow.AddMinutes(5)
        $connected=$false
        do {
            $connection=[Data.SqlClient.SqlConnection]::new($connectionString,$credential)
            try {$connection.Open();$connected=$true}
            catch {$connection.Dispose();if([datetime]::UtcNow -ge $deadline){throw 'HYPERV_NETWORK_ACCEPTANCE_SQL_CONNECT_TIMEOUT'};Start-Sleep -Seconds 3}
        } while(-not $connected)
        try {
            $command=$connection.CreateCommand();$command.CommandTimeout=30
            try {
                if($phase -eq 'before'){
                    $command.CommandText="IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) <> 17 THROW 51000, 'SQL_VERSION_MISMATCH', 1; CREATE TABLE tempdb.dbo.SqlLabNetworkAcceptance (Marker uniqueidentifier NOT NULL); INSERT tempdb.dbo.SqlLabNetworkAcceptance VALUES (@marker); SELECT COUNT(*) FROM tempdb.dbo.SqlLabNetworkAcceptance WHERE Marker=@marker;"
                } else {$command.CommandText='SELECT COUNT(*) FROM tempdb.dbo.SqlLabNetworkAcceptance WHERE Marker=@marker;'}
                $null=$command.Parameters.Add('@marker',[Data.SqlDbType]::UniqueIdentifier)
                $command.Parameters['@marker'].Value=$marker
                if([int]$command.ExecuteScalar() -ne 1){throw 'HYPERV_NETWORK_ACCEPTANCE_SQL_MARKER_FAILED'}
            } finally {$command.Dispose()}
        } finally {$connection.Dispose()}
        Write-Host "PASS: SQL $phase reconnect"
        if($phase -eq 'before'){
            $result=& $module {
                param($Helper,$Id,$Op,$Root)
                . $Helper
                Invoke-HyperVNetworkReconnectAcceptanceStep -RunId $Id -OperationId $Op -StateRoot $Root
            } (Join-Path $PSScriptRoot 'HyperVNetworkReconnectAcceptance.ps1') $run.RunId $OperationId $StateRoot
            if($result.Status -ne 'PASS'){throw 'HYPERV_NETWORK_ACCEPTANCE_RECONNECT_FAILED'}
        }
    }
} finally {if($password){$password.Dispose()};Remove-Module $module.Name -Force}
exit 0
