function Get-LabSmtpTestServiceJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory,[Parameter(Mandatory)]$Plan)
    if ($Plan.Contract.Name -cne 'SqlServerLab.SmtpTestServicePlan' -or $Plan.Contract.Version -cne '1.0' -or
        $Plan.RunId -cnotmatch '^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$' -or $Plan.ScopeId -cnotmatch '^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$' -or
        $Plan.ServiceId -cnotmatch '^[a-z][a-z0-9-]{0,31}$') { throw 'SMTP_TEST_SERVICE_JOURNAL_INVALID' }
    return Join-Path (Join-Path $RunDirectory 'smtp-test-service') ($Plan.ScopeId+'-'+$Plan.ServiceId+'.json')
}

function New-LabSmtpTestServiceJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][string]$RunDirectory)
    $path=Get-LabSmtpTestServiceJournalPath -RunDirectory $RunDirectory -Plan $Plan
    $parent=Split-Path -Parent $path
    if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop|Out-Null}
    if(Test-Path -LiteralPath $path){throw 'SMTP_TEST_SERVICE_JOURNAL_COLLISION'}
    $journal=[pscustomobject][ordered]@{
        ContractVersion='SqlServerLab.SmtpTestServiceJournal/1.0';OperationId=[guid]::NewGuid().ToString('D');RunId=[string]$Plan.RunId;ScopeId=[string]$Plan.ScopeId;Provider=[string]$Plan.Provider;ServiceId=[string]$Plan.ServiceId;Status='PREPARED'
        Resources=[pscustomobject]@{NetworkName=[string]$Plan.NetworkName;GatewayContainerName=[string]$Plan.GatewayContainerName;ReceiverContainerName=[string]$Plan.ReceiverContainerName;NetworkId=$null;GatewayContainerId=$null;ReceiverContainerId=$null}
        Recovery=[pscustomobject]@{Status='REMOVE_CREATED_RESOURCES';Attempts=0;ErrorCode=$null};UpdatedAt=Get-LabTimestamp
    }
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($journal|ConvertTo-Json -Depth 12));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    return [pscustomobject]@{Journal=$journal;Path=$path}
}

function Get-LabSmtpTestServiceCleanupPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal)
    if($Journal.ContractVersion -cne 'SqlServerLab.SmtpTestServiceJournal/1.0' -or
        $Journal.Provider -cnotin @('docker','podman') -or $Journal.Status -cnotin @('PREPARED','PROVISIONING','FAILED','RECOVERY_REQUIRED') -or
        $Journal.Resources.NetworkName -isnot [string] -or $Journal.Resources.GatewayContainerName -isnot [string] -or $Journal.Resources.ReceiverContainerName -isnot [string]) {
        throw 'SMTP_TEST_SERVICE_JOURNAL_INVALID'
    }
    return [pscustomobject][ordered]@{
        Contract=[pscustomobject]@{Name='SqlServerLab.SmtpTestServiceCleanupPlan';Version='1.0'}
        RunId=[string]$Journal.RunId;ScopeId=[string]$Journal.ScopeId;Provider=[string]$Journal.Provider;OperationId=[string]$Journal.OperationId
        Steps=@(
            [pscustomobject]@{Id='remove-gateway';Kind='container';Identity=[string]$Journal.Resources.GatewayContainerName},
            [pscustomobject]@{Id='remove-receiver';Kind='container';Identity=[string]$Journal.Resources.ReceiverContainerName},
            [pscustomobject]@{Id='remove-network';Kind='network';Identity=[string]$Journal.Resources.NetworkName}
        )
    }
}
