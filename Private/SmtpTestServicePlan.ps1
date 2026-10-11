# A pure run/scoped binding.  It deliberately creates no receiver resource.
function New-LabSmtpTestServicePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider
    )

    $guid = [guid]::Empty
    if (-not [guid]::TryParseExact($RunId,'D',[ref]$guid) -or $RunId -cne $guid.ToString('D') -or $guid -eq [guid]::Empty -or
        -not [guid]::TryParseExact($ScopeId,'D',[ref]$guid) -or $ScopeId -cne $guid.ToString('D') -or $guid -eq [guid]::Empty) {
        throw 'SMTP_TEST_SERVICE_BINDING_INVALID'
    }
    $allowed=@('enabled','id','senderInstanceIds','maxStoredMessages','maxStoredBytes','maxMessageMiB','acceptedMessagesPerUtc60Seconds','MemoryMiB','CPUs')
    $input=[ordered]@{}
    foreach($name in $allowed){if($Config -is [Collections.IDictionary]){if($Config.Contains($name)){$input[$name]=$Config[$name]}}elseif($Config.PSObject.Properties[$name]){$input[$name]=$Config.PSObject.Properties[$name].Value}}
    $normalized=ConvertTo-LabSmtpTestServiceConfig -InputObject $input
    if ($null -eq $normalized) { throw 'SMTP_TEST_SERVICE_BINDING_INVALID' }
    $base="sql-lab-smtp-$RunId-$ScopeId-$($normalized.id)"
    if ($base.Length -gt 220) { throw 'SMTP_TEST_SERVICE_BINDING_INVALID' }
    return [pscustomobject][ordered]@{
        Contract=[pscustomobject]@{Name='SqlServerLab.SmtpTestServicePlan';Version='1.0'}
        RunId=$RunId;ScopeId=$ScopeId;Provider=$Provider;ServiceId=[string]$normalized.id
        SenderInstanceIds=[string[]]@($normalized.senderInstanceIds)
        NetworkName=$base;GatewayContainerName="$base-gateway";ReceiverContainerName="$base-receiver"
        Gateway=[pscustomobject][ordered]@{ImageBuildFile='Tools/SmtpTestServiceGateway.Dockerfile';MaxStoredMessages=[long]$normalized.maxStoredMessages;MaxStoredBytes=[long]$normalized.maxStoredBytes;MaxMessageBytes=[long]$normalized.maxMessageBytes;AcceptedMessagesPerUtc60Seconds=[long]$normalized.acceptedMessagesPerUtc60Seconds;MemoryMiB=[long]$normalized.MemoryMiB;CPUs=[double]$normalized.CPUs}
        Receiver=[pscustomobject][ordered]@{Image='ghcr.io/axllent/mailpit:v1.31.3@sha256:ed9b00c609e77e99c79b93f1178255ebc271868920f2c69a8d166bd5634ed10d';HttpPort=8025;SmtpPort=1025}
    }
}
