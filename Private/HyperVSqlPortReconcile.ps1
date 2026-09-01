<#
.SYNOPSIS
    Plant und repariert den statischen TCP-Port der SQL-Standardinstanz eines Hyper-V-Runs.
.DESCRIPTION
    Der read-only Plan vergleicht den persistierten SqlEndpoint-Sollzustand mit
    der Registry- und Firewallkonfiguration im laufenden Gast. Der Executor
    bindet die Mutation an Run, Scope, Instanz, VM und SQL-Instanz, schreibt vor
    der ersten Mutation ein lokales Journal, startet ausschliesslich den
    SQL-Dienst neu und setzt unvollstaendige Operationen idempotent fort.
#>

function Get-LabHyperVSqlPortReconcileJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)
    Join-Path $RunDirectory 'hyperv-sql-port-reconcile.local.journal.json'
}

function Assert-LabHyperVSqlPortReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal)
    $schemaPath = Join-Path $script:SchemasPath 'hyperv-sql-port-reconcile-journal.schema.json'
    if (-not (($Journal | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'HYPERV_SQL_PORT_RECONCILE_JOURNAL_SCHEMA_INVALID'
    }
    return $true
}

function Write-LabHyperVSqlPortReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal, [Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt = Get-LabTimestamp
    $null = Assert-LabHyperVSqlPortReconcileJournal -Journal $Journal
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
    return $Journal
}

function Set-LabHyperVSqlPortReconcileJournalStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('PREPARED','TCP_APPLIED','SERVICE_RESTARTED','VERIFIED','CONNECTION_STATE_UPDATED','COMPLETED','RECOVERY_REQUIRED')][string]$Status,
        [string]$ErrorCode
    )
    $Journal.Status = $Status
    if ($ErrorCode) {
        $Journal.Recovery.ErrorCode = $ErrorCode
        $Journal.Recovery.Errors = @($Journal.Recovery.Errors) + @($ErrorCode)
    }
    if ($Status -eq 'COMPLETED') { $Journal.Recovery.Status = 'NOT_REQUIRED' }
    elseif ($Status -eq 'RECOVERY_REQUIRED') { $Journal.Recovery.Status = 'RETRY_SQL_PORT_RECONCILE' }
    return Write-LabHyperVSqlPortReconcileJournal -Journal $Journal -Path $Path
}

function Get-LabHyperVSqlPortReconcileCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)
    $guestPassword = Get-LabSecret -Path $RunDirectory -Name 'guest-administrator-password'
    if (-not $guestPassword) { throw 'HYPERV_SQL_PORT_RECONCILE_CREDENTIAL_REQUIRED' }
    return [PSCredential]::new('Administrator', $guestPassword)
}

function Get-LabHyperVSqlPortReconcileContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ([string]$run.metadata.workflowKind -ne 'hyperv-lab') { throw 'HYPERV_SQL_PORT_RECONCILE_HYPERV_RUN_REQUIRED' }
    $guard = Get-LabHyperVResourceMigrationLifecycleGuard -RunId $RunId -StateRoot $StateRoot
    if (-not $guard.Allowed) { throw "HYPERV_SQL_PORT_RECONCILE_MIGRATION_BLOCKED: $([string]$guard.ReasonCode)" }
    $targetState = if ([string]$run.state -eq 'STOPPED') { 'STOPPED' } else { 'RUNNING' }
    $desiredState = New-LabDesiredState -Run $run -TargetState $targetState -StateRoot $StateRoot
    if (-not $desiredState.IsValid) { throw 'HYPERV_SQL_PORT_RECONCILE_DESIRED_STATE_INVALID' }
    $desiredInstances = @($desiredState.Instances | Where-Object { [string]$_.Id -eq $InstanceId -and [string]$_.Provider -eq 'hyperv' })
    if ($desiredInstances.Count -ne 1) { throw 'HYPERV_SQL_PORT_RECONCILE_INSTANCE_NOT_UNIQUE' }
    $desired = $desiredInstances[0].SqlEndpoint
    if (-not $desired -or -not $desired.Contract -or
        [string]$desired.Contract.Name -ne 'SqlServerLab.SqlEndpointIntent' -or
        [string]$desired.Contract.Version -ne '1.0' -or [string]$desired.Protocol -ne 'tcp') {
        throw 'HYPERV_SQL_PORT_RECONCILE_INTENT_MISSING'
    }
    if ([string]$desired.CapabilityStatus -ne 'DECLARED_SUPPORTED') { throw 'HYPERV_SQL_PORT_RECONCILE_INTENT_UNSUPPORTED' }
    $desiredPort = [int]$desired.Port
    if ($desiredPort -lt 1 -or $desiredPort -gt 65535) { throw 'HYPERV_SQL_PORT_RECONCILE_PORT_INVALID' }

    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'HYPERV_SQL_PORT_RECONCILE_CONNECTION_MISSING' }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
    $instances = @($connection.instances | Where-Object { [string]$_.id -eq $InstanceId -and [string]$_.provider -eq 'hyperv' })
    if ($instances.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$instances[0].vmName)) {
        throw 'HYPERV_SQL_PORT_RECONCILE_CONNECTION_INSTANCE_NOT_UNIQUE'
    }
    $managed = Get-HyperVManagedVM -VMName ([string]$instances[0].vmName) `
        -ExpectedRunId $RunId -ExpectedScopeId ([string]$run.scopeId)
    if (-not $managed) { throw 'HYPERV_SQL_PORT_RECONCILE_VM_NOT_FOUND' }
    if ($instances[0].vmId -and [string]$instances[0].vmId -ne [string]$managed.VM.Id) {
        throw 'HYPERV_SQL_PORT_RECONCILE_VM_IDENTITY_MISMATCH'
    }
    if ([string]$managed.VM.State -ne 'Running') { throw 'HYPERV_SQL_PORT_RECONCILE_VM_RUNNING_REQUIRED' }

    $firewallRequired = $instances[0].hostSqlAccess -and [string]$instances[0].hostSqlAccess.state -eq 'READY'
    $firewallRemoteAddress = $null
    if ($firewallRequired) {
        if ($instances[0].labNetwork -and [string]$instances[0].labNetwork.intent -eq 'lan') {
            $firewallRemoteAddress = 'LocalSubnet'
        }
        elseif ($instances[0].labNetwork -and $instances[0].labNetwork.hostAddress) {
            $firewallRemoteAddress = [string]$instances[0].labNetwork.hostAddress
        }
        if (-not $firewallRemoteAddress) { throw 'HYPERV_SQL_PORT_RECONCILE_FIREWALL_REMOTE_ADDRESS_MISSING' }
    }
    $secretPath = Join-Path (Join-Path $runDirectory 'secrets') 'guest-administrator-password.secret'
    return [PSCustomObject]@{
        RunId=$RunId; ScopeId=[string]$run.scopeId; InstanceId=$InstanceId; StateRoot=$StateRoot
        RunDirectory=$runDirectory; ConnectionPath=$connectionPath; Connection=$connection
        ConnectionInstance=$instances[0]; Managed=$managed; VM=$managed.VM; Desired=$desired
        FirewallRequired=[bool]$firewallRequired; FirewallRemoteAddress=$firewallRemoteAddress
        CredentialAvailable=(Test-Path -LiteralPath $secretPath -PathType Leaf)
    }
}

function Get-LabHyperVSqlPortActualState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][PSCredential]$Credential)

    $result = Invoke-HyperVPowerShellDirect -VMName ([string]$Context.ConnectionInstance.vmName) `
        -ExpectedRunId ([string]$Context.RunId) -ExpectedScopeId ([string]$Context.ScopeId) `
        -Credential $Credential -ArgumentList @('SQL_Server_Lab SQL TCP Host') -ScriptBlock {
        param($FirewallRuleName)
        $ErrorActionPreference = 'Stop'
        $instanceRoot = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
        if (-not (Test-Path -LiteralPath $instanceRoot)) { throw 'HYPERV_SQL_PORT_RECONCILE_INSTANCE_REGISTRY_NOT_FOUND' }
        $map = Get-ItemProperty -LiteralPath $instanceRoot -ErrorAction Stop
        $instances = @($map.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })
        $defaults = @($instances | Where-Object { [string]$_.Name -eq 'MSSQLSERVER' })
        if ($instances.Count -ne 1 -or $defaults.Count -ne 1) { throw 'HYPERV_SQL_PORT_RECONCILE_DEFAULT_INSTANCE_NOT_UNIQUE' }
        $sqlInstanceId = [string]$defaults[0].Value
        $tcpRoot = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$sqlInstanceId\MSSQLServer\SuperSocketNetLib\Tcp"
        $ipAll = Join-Path $tcpRoot 'IPAll'
        if (-not (Test-Path -LiteralPath $tcpRoot) -or -not (Test-Path -LiteralPath $ipAll)) {
            throw 'HYPERV_SQL_PORT_RECONCILE_TCP_REGISTRY_NOT_FOUND'
        }
        $tcp = Get-ItemProperty -LiteralPath $tcpRoot -ErrorAction Stop
        $binding = Get-ItemProperty -LiteralPath $ipAll -ErrorAction Stop
        $port = if ([string]$binding.TcpPort -match '^\d{1,5}$') { [int]$binding.TcpPort } else { $null }
        $service = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
        $sqlReachable = $false
        if ($service -and [string]$service.Status -eq 'Running' -and $port) {
            Add-Type -AssemblyName System.Data
            $connection = [Data.SqlClient.SqlConnection]::new("Server=localhost,$port;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connect Timeout=5;")
            try {
                $connection.Open();$command=$connection.CreateCommand();$command.CommandText='SELECT DB_NAME();'
                $sqlReachable = [string]$command.ExecuteScalar() -eq 'master'
            }
            catch { $sqlReachable = $false }
            finally { $connection.Dispose() }
        }
        $rules = @(Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue)
        $firewallPorts = @()
        $firewallProtocols = @()
        $firewallRemoteAddresses = @()
        $firewallEnabled = $false
        $firewallInbound = $false
        $firewallAllow = $false
        if ($rules.Count -eq 1) {
            $firewallPorts = @($rules[0] | Get-NetFirewallPortFilter -ErrorAction Stop | ForEach-Object { [string]$_.LocalPort })
            $firewallProtocols = @($rules[0] | Get-NetFirewallPortFilter -ErrorAction Stop | ForEach-Object { [string]$_.Protocol })
            $firewallRemoteAddresses = @($rules[0] | Get-NetFirewallAddressFilter -ErrorAction Stop | ForEach-Object { [string]$_.RemoteAddress })
            $firewallEnabled = [string]$rules[0].Enabled -eq 'True'
            $firewallInbound = [string]$rules[0].Direction -eq 'Inbound'
            $firewallAllow = [string]$rules[0].Action -eq 'Allow'
        }
        [PSCustomObject]@{
            Status='AVAILABLE';SqlInstanceId=$sqlInstanceId;ServiceName=if($service){[string]$service.Name}else{$null}
            ServiceStatus=if($service){[string]$service.Status}else{'NOT_FOUND'};TcpEnabled=([int]$tcp.Enabled -eq 1)
            StaticPort=([string]::IsNullOrEmpty([string]$binding.TcpDynamicPorts));Port=$port;SqlReachable=$sqlReachable
            FirewallRuleCount=$rules.Count;FirewallPorts=$firewallPorts;FirewallProtocols=$firewallProtocols
            FirewallRemoteAddresses=$firewallRemoteAddresses;FirewallEnabled=$firewallEnabled
            FirewallInbound=$firewallInbound;FirewallAllow=$firewallAllow;ObservedAt=[datetime]::UtcNow.ToString('o')
        }
    }
    $actual = @($result)[-1]
    if (-not $actual -or [string]$actual.Status -ne 'AVAILABLE') { throw 'HYPERV_SQL_PORT_RECONCILE_ACTUAL_UNAVAILABLE' }
    return $actual
}

function Get-LabHyperVSqlPortReconcileDiff {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Actual)

    $diff = [Collections.Generic.List[object]]::new()
    if ([string]$Actual.ServiceName -ne 'MSSQLSERVER') {
        $diff.Add([PSCustomObject]@{Kind='service-missing';Supported=$false})
    }
    elseif ([string]$Actual.ServiceStatus -ne 'Running') {
        $diff.Add([PSCustomObject]@{Kind='service-not-running';Supported=$false})
    }
    if (-not $Actual.TcpEnabled -or -not $Actual.StaticPort -or $null -eq $Actual.Port -or [int]$Actual.Port -ne [int]$Context.Desired.Port) {
        $diff.Add([PSCustomObject]@{Kind='tcp-binding';Supported=$true})
    }
    elseif (-not $Actual.SqlReachable) {
        $diff.Add([PSCustomObject]@{Kind='sql-readiness';Supported=$true})
    }
    if ($Context.FirewallRequired) {
        if ([int]$Actual.FirewallRuleCount -gt 1) {
            $diff.Add([PSCustomObject]@{Kind='firewall-rule-ambiguous';Supported=$false})
        }
        elseif ([int]$Actual.FirewallRuleCount -eq 0 -or @($Actual.FirewallPorts) -notcontains ([string][int]$Context.Desired.Port) -or
            @($Actual.FirewallProtocols) -notcontains 'TCP' -or @($Actual.FirewallRemoteAddresses) -notcontains ([string]$Context.FirewallRemoteAddress) -or
            -not $Actual.FirewallEnabled -or -not $Actual.FirewallInbound -or -not $Actual.FirewallAllow) {
            $diff.Add([PSCustomObject]@{Kind='firewall-binding';Supported=$true})
        }
    }
    return @($diff)
}

function Read-LabHyperVSqlPortReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Context, $Actual)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $journal = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $null = Assert-LabHyperVSqlPortReconcileJournal -Journal $journal
    if ([string]$journal.RunId -ne [string]$Context.RunId -or [string]$journal.ScopeId -ne [string]$Context.ScopeId -or
        [string]$journal.InstanceId -ne [string]$Context.InstanceId -or [string]$journal.Runtime.VMId -ne [string]$Context.VM.Id) {
        throw 'HYPERV_SQL_PORT_RECONCILE_JOURNAL_IDENTITY_MISMATCH'
    }
    $expectedTarget = [PSCustomObject]@{
        Protocol='tcp';Port=[int]$Context.Desired.Port;TcpEnabled=$true;StaticPort=$true;FirewallRequired=[bool]$Context.FirewallRequired
    }
    if (($journal.Target | ConvertTo-Json -Depth 10 -Compress) -cne ($expectedTarget | ConvertTo-Json -Depth 10 -Compress)) {
        if ([string]$journal.Status -eq 'COMPLETED') { return $null }
        throw 'HYPERV_SQL_PORT_RECONCILE_JOURNAL_TARGET_MISMATCH'
    }
    if ($Actual -and ([string]$journal.Runtime.SqlInstanceId -ne [string]$Actual.SqlInstanceId -or
        [string]$journal.Runtime.ServiceName -ne [string]$Actual.ServiceName)) {
        throw 'HYPERV_SQL_PORT_RECONCILE_JOURNAL_SQL_IDENTITY_MISMATCH'
    }
    return $journal
}

function New-LabHyperVSqlPortReconcilePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$InstanceId, [string]$StateRoot)
    try {
        $context = Get-LabHyperVSqlPortReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if (-not $context.CredentialAvailable) { throw 'HYPERV_SQL_PORT_RECONCILE_CREDENTIAL_REQUIRED' }
        $credential = Get-LabHyperVSqlPortReconcileCredential -RunDirectory $context.RunDirectory
        $actual = Get-LabHyperVSqlPortActualState -Context $context -Credential $credential
        $journalPath = Get-LabHyperVSqlPortReconcileJournalPath -RunDirectory $context.RunDirectory
        $journal = Read-LabHyperVSqlPortReconcileJournal -Path $journalPath -Context $context -Actual $actual
    }
    catch {
        $code = if ($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}') { [string]$Matches[0] } else { 'HYPERV_SQL_PORT_RECONCILE_UNAVAILABLE' }
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{Name='SqlServerLab.HyperVSqlPortReconcilePlan';Version='1.0'}
            RunId=$RunId;InstanceId=$InstanceId;Provider='hyperv';Desired=[PSCustomObject]@{Protocol='tcp';Status='DECLARED'}
            Actual=[PSCustomObject]@{Status='UNAVAILABLE';TcpBindingStatus='UNKNOWN';FirewallBindingStatus='UNKNOWN';SqlReadinessStatus='UNKNOWN'}
            Diff=@();Actions=@();HighestChangeClass='unsupported';IsNoOp=$false;MutationAllowed=$false
            Warnings=@('Der SQL-Portzustand ist nicht eindeutig steuerbar.');ReasonCodes=@($code)
        }
    }
    $diff = @(Get-LabHyperVSqlPortReconcileDiff -Context $context -Actual $actual)
    $unsupported = @($diff | Where-Object { -not $_.Supported })
    $recoveryPending = $journal -and [string]$journal.Status -ne 'COMPLETED'
    $changeClass = if ($unsupported.Count) { 'unsupported' } elseif ($diff.Count -or $recoveryPending) { 'restart' } else { 'no-op' }
    $repairKinds = @($diff | Where-Object Supported | ForEach-Object { [string]$_.Kind } | Sort-Object -Unique)
    if ($recoveryPending -and $diff.Count -eq 0) { $repairKinds = @('recovery-finalize') }
    $actions = if ($changeClass -eq 'restart') {
        @([PSCustomObject]@{
            Operation=if($recoveryPending){'ResumeHyperVSqlPort'}else{'RepairHyperVSqlPort'};ChangeClass='restart'
            RepairKinds=$repairKinds;RequiresServiceRestart=$true;RequiresVmRestart=$false;RecoveryPending=[bool]$recoveryPending
        })
    } else { @() }
    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.HyperVSqlPortReconcilePlan';Version='1.0'}
        RunId=$RunId;InstanceId=$InstanceId;Provider='hyperv';Desired=[PSCustomObject]@{Protocol='tcp';Status='DECLARED'}
        Actual=[PSCustomObject]@{
            Status='AVAILABLE';TcpBindingStatus=if(@($diff.Kind) -contains 'tcp-binding'){'DRIFT'}else{'MATCHED'}
            FirewallBindingStatus=if(-not $context.FirewallRequired){'NOT_REQUIRED'}elseif(@($diff.Kind) -contains 'firewall-binding'){'DRIFT'}elseif(@($diff.Kind) -contains 'firewall-rule-ambiguous'){'AMBIGUOUS'}else{'MATCHED'}
            SqlReadinessStatus=if(@($diff.Kind) -contains 'sql-readiness'){'NOT_READY'}else{'READY'}
        }
        Diff=@($diff | ForEach-Object {[PSCustomObject]@{Kind=[string]$_.Kind;ChangeClass=if($_.Supported){'restart'}else{'unsupported'}}})
        Actions=$actions;HighestChangeClass=$changeClass;IsNoOp=($changeClass -eq 'no-op');MutationAllowed=$false
        Warnings=if($unsupported.Count){@('Mehrdeutige SQL-Instanz-, Dienst- oder Firewallidentitaet wird nicht mutiert.')}elseif($changeClass -eq 'restart'){@('Die Reparatur startet ausschliesslich den SQL-Dienst neu; die Hyper-V-VM bleibt gestartet.')}else{@()}
        ReasonCodes=@($(if($recoveryPending){'HYPERV_SQL_PORT_RECONCILE_RECOVERY_PENDING'});$(if($unsupported.Count){'HYPERV_SQL_PORT_RECONCILE_UNSUPPORTED'}))
    }
}

function Set-LabHyperVSqlPortBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][PSCredential]$Credential)

    $receipt = Invoke-HyperVPowerShellDirect -VMName ([string]$Context.ConnectionInstance.vmName) `
        -ExpectedRunId ([string]$Context.RunId) -ExpectedScopeId ([string]$Context.ScopeId) -Credential $Credential `
        -ArgumentList @([int]$Context.Desired.Port,[bool]$Context.FirewallRequired,[string]$Context.FirewallRemoteAddress,'SQL_Server_Lab SQL TCP Host') -ScriptBlock {
        param($RequestedPort,$FirewallRequired,$FirewallRemoteAddress,$FirewallRuleName)
        $ErrorActionPreference = 'Stop'
        if ([int]$RequestedPort -lt 1 -or [int]$RequestedPort -gt 65535) { throw 'HYPERV_SQL_PORT_RECONCILE_PORT_INVALID' }
        if ($FirewallRequired -and [string]::IsNullOrWhiteSpace([string]$FirewallRemoteAddress)) {
            throw 'HYPERV_SQL_PORT_RECONCILE_FIREWALL_REMOTE_ADDRESS_MISSING'
        }
        $instanceRoot = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
        $map = Get-ItemProperty -LiteralPath $instanceRoot -ErrorAction Stop
        $instances = @($map.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })
        $defaults = @($instances | Where-Object { [string]$_.Name -eq 'MSSQLSERVER' })
        if ($instances.Count -ne 1 -or $defaults.Count -ne 1) { throw 'HYPERV_SQL_PORT_RECONCILE_DEFAULT_INSTANCE_NOT_UNIQUE' }
        $sqlInstanceId = [string]$defaults[0].Value
        $service = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
        if (-not $service -or [string]$service.Status -ne 'Running') { throw 'HYPERV_SQL_PORT_RECONCILE_SERVICE_RUNNING_REQUIRED' }
        $rules = @(Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue)
        if ($rules.Count -gt 1) { throw 'HYPERV_SQL_PORT_RECONCILE_FIREWALL_RULE_AMBIGUOUS' }
        $tcpRoot = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$sqlInstanceId\MSSQLServer\SuperSocketNetLib\Tcp"
        $ipAll = Join-Path $tcpRoot 'IPAll'
        if (-not (Test-Path -LiteralPath $tcpRoot) -or -not (Test-Path -LiteralPath $ipAll)) {
            throw 'HYPERV_SQL_PORT_RECONCILE_TCP_REGISTRY_NOT_FOUND'
        }
        Set-ItemProperty -LiteralPath $tcpRoot -Name Enabled -Value 1 -Type DWord -ErrorAction Stop
        Set-ItemProperty -LiteralPath $ipAll -Name TcpDynamicPorts -Value '' -ErrorAction Stop
        Set-ItemProperty -LiteralPath $ipAll -Name TcpPort -Value ([string][int]$RequestedPort) -ErrorAction Stop
        if ($FirewallRequired) {
            if ($rules.Count -eq 0) {
                New-NetFirewallRule -DisplayName $FirewallRuleName -Group 'SQL_Server_Lab' -Description 'Managed by SQL_Server_Lab' `
                    -Direction Inbound -Action Allow -Protocol TCP -LocalPort ([int]$RequestedPort) -RemoteAddress $FirewallRemoteAddress -ErrorAction Stop | Out-Null
            }
            else {
                $rules[0] | Set-NetFirewallRule -Enabled True -Direction Inbound -Action Allow -ErrorAction Stop | Out-Null
                $filters = @($rules[0] | Get-NetFirewallPortFilter -ErrorAction Stop)
                if ($filters.Count -ne 1) { throw 'HYPERV_SQL_PORT_RECONCILE_FIREWALL_FILTER_NOT_UNIQUE' }
                $filters[0] | Set-NetFirewallPortFilter -Protocol TCP -LocalPort ([int]$RequestedPort) -ErrorAction Stop | Out-Null
                $addressFilters = @($rules[0] | Get-NetFirewallAddressFilter -ErrorAction Stop)
                if ($addressFilters.Count -ne 1) { throw 'HYPERV_SQL_PORT_RECONCILE_FIREWALL_ADDRESS_FILTER_NOT_UNIQUE' }
                $addressFilters[0] | Set-NetFirewallAddressFilter -RemoteAddress $FirewallRemoteAddress -ErrorAction Stop | Out-Null
            }
        }
        Restart-Service -Name 'MSSQLSERVER' -ErrorAction Stop
        $service = Get-Service -Name 'MSSQLSERVER' -ErrorAction Stop
        $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(120))
        Add-Type -AssemblyName System.Data
        $connection = [Data.SqlClient.SqlConnection]::new("Server=localhost,$([int]$RequestedPort);Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;")
        try {
            $connection.Open();$command=$connection.CreateCommand();$command.CommandText='SELECT DB_NAME();'
            if ([string]$command.ExecuteScalar() -ne 'master') { throw 'HYPERV_SQL_PORT_RECONCILE_SQL_POSTCONDITION_FAILED' }
        }
        finally { $connection.Dispose() }
        [PSCustomObject]@{
            Status='APPLIED';SqlInstanceId=$sqlInstanceId;ServiceName='MSSQLSERVER';ServiceStatus='Running'
            Port=[int]$RequestedPort;FirewallRequired=[bool]$FirewallRequired;ObservedAt=[datetime]::UtcNow.ToString('o')
        }
    }
    $receipt = @($receipt)[-1]
    if (-not $receipt -or [string]$receipt.Status -ne 'APPLIED' -or [int]$receipt.Port -ne [int]$Context.Desired.Port -or
        [string]$receipt.ServiceName -ne 'MSSQLSERVER' -or [string]$receipt.ServiceStatus -ne 'Running') {
        throw 'HYPERV_SQL_PORT_RECONCILE_APPLY_RECEIPT_INVALID'
    }
    return $receipt
}

function Sync-LabHyperVSqlPortConnectionState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][PSCredential]$Credential)

    $lab = Get-HyperVLabWorkflowRun -RunId ([string]$Context.RunId) -StateRoot ([string]$Context.StateRoot)
    $fallbackAddress = if ($lab.Instance.labNetwork -and $lab.Instance.labNetwork.address) { [string]$lab.Instance.labNetwork.address } else { $null }
    $receipt = Get-HyperVLabSqlInstanceReceipt -Lab $lab -Credential $Credential -FallbackAddress $fallbackAddress
    $defaults = @($receipt.instances | Where-Object { $_.isDefault })
    if (@($receipt.instances).Count -ne 1 -or $defaults.Count -ne 1 -or [int]$defaults[0].tcpPort -ne [int]$Context.Desired.Port -or
        [string]$defaults[0].serviceStatus -ne 'Running') {
        throw 'HYPERV_SQL_PORT_RECONCILE_CONNECTION_STATE_POSTCONDITION_FAILED'
    }
    $lab.Instance | Add-Member -NotePropertyName port -NotePropertyValue ([int]$Context.Desired.Port) -Force
    if ($lab.Instance.hostSqlAccess -and [string]$lab.Instance.hostSqlAccess.state -eq 'READY') {
        $lab.Instance.hostSqlAccess | Add-Member -NotePropertyName portReconciledAt -NotePropertyValue (Get-LabTimestamp) -Force
    }
    $null = Save-HyperVLabSqlInstanceReceipt -Lab $lab -Receipt $receipt
}

function Invoke-LabHyperVSqlPortReconcileRepair {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$InstanceId,[string]$StateRoot)

    $mutex = [Threading.Mutex]::new($false,"Global\SQL_Server_Lab_HyperV_SQL_Port_Reconcile_$($RunId.Replace('-',''))")
    $acquired=$false;$journal=$null;$journalPath=$null
    try {
        $acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(5));if(-not $acquired){throw 'HYPERV_SQL_PORT_RECONCILE_LOCK_TIMEOUT'}
        $context=Get-LabHyperVSqlPortReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $credential=Get-LabHyperVSqlPortReconcileCredential -RunDirectory $context.RunDirectory
        $actual=Get-LabHyperVSqlPortActualState -Context $context -Credential $credential
        $journalPath=Get-LabHyperVSqlPortReconcileJournalPath -RunDirectory $context.RunDirectory
        $journal=Read-LabHyperVSqlPortReconcileJournal -Path $journalPath -Context $context -Actual $actual
        $plan=New-LabHyperVSqlPortReconcilePlan -RunId $RunId -InstanceId $InstanceId -StateRoot $context.StateRoot
        if($journal -and [string]$journal.Status -ne 'COMPLETED'){$journal.Recovery.Attempts=[int]$journal.Recovery.Attempts+1}
        elseif($journal -and [string]$journal.Status -eq 'COMPLETED' -and $plan.IsNoOp){return [PSCustomObject]@{Status='NO_OP';RunId=$RunId;InstanceId=$InstanceId;Changed=$false;RepairKinds=@()}}
        elseif($journal -and [string]$journal.Status -eq 'COMPLETED'){$journal=$null}
        if(-not $journal){
            if($plan.IsNoOp){return [PSCustomObject]@{Status='NO_OP';RunId=$RunId;InstanceId=$InstanceId;Changed=$false;RepairKinds=@()}}
            if([string]$plan.HighestChangeClass -ne 'restart' -or @($plan.Actions).Count -ne 1){throw 'HYPERV_SQL_PORT_RECONCILE_UNSUPPORTED'}
            $journal=[PSCustomObject]@{
                ContractVersion='SqlServerLab.HyperVSqlPortReconcileJournal/1.0';OperationId=[Guid]::NewGuid().ToString('D')
                RunId=$RunId;ScopeId=[string]$context.ScopeId;InstanceId=$InstanceId;Provider='hyperv';ChangeClass='restart';Status='PREPARED'
                Target=[PSCustomObject]@{Protocol='tcp';Port=[int]$context.Desired.Port;TcpEnabled=$true;StaticPort=$true;FirewallRequired=[bool]$context.FirewallRequired}
                Runtime=[PSCustomObject]@{VMId=[string]$context.VM.Id;SqlInstanceId=[string]$actual.SqlInstanceId;ServiceName='MSSQLSERVER';FirewallRuleName='SQL_Server_Lab SQL TCP Host'}
                Recovery=[PSCustomObject]@{Status='RETRY_SQL_PORT_RECONCILE';Attempts=0;ErrorCode=$null;Errors=@()};UpdatedAt=Get-LabTimestamp
            }
            $null=Write-LabHyperVSqlPortReconcileJournal -Journal $journal -Path $journalPath
        }
        $before=@(Get-LabHyperVSqlPortReconcileDiff -Context $context -Actual $actual)
        if(@($before | Where-Object {-not $_.Supported}).Count){throw 'HYPERV_SQL_PORT_RECONCILE_UNSUPPORTED'}
        if($before.Count){
            $applyReceipt=Set-LabHyperVSqlPortBinding -Context $context -Credential $credential
            $null=Set-LabHyperVSqlPortReconcileJournalStatus -Journal $journal -Path $journalPath -Status TCP_APPLIED
            if([string]$applyReceipt.ServiceStatus -ne 'Running'){throw 'HYPERV_SQL_PORT_RECONCILE_SERVICE_RESTART_FAILED'}
            $null=Set-LabHyperVSqlPortReconcileJournalStatus -Journal $journal -Path $journalPath -Status SERVICE_RESTARTED
        }
        $actual=Get-LabHyperVSqlPortActualState -Context $context -Credential $credential
        $remaining=@(Get-LabHyperVSqlPortReconcileDiff -Context $context -Actual $actual)
        if($remaining.Count){throw "HYPERV_SQL_PORT_RECONCILE_POSTCONDITION_FAILED: $(@($remaining.Kind)-join ',')"}
        $null=Set-LabHyperVSqlPortReconcileJournalStatus -Journal $journal -Path $journalPath -Status VERIFIED
        Sync-LabHyperVSqlPortConnectionState -Context $context -Credential $credential
        $null=Set-LabHyperVSqlPortReconcileJournalStatus -Journal $journal -Path $journalPath -Status CONNECTION_STATE_UPDATED
        $null=Set-LabHyperVSqlPortReconcileJournalStatus -Journal $journal -Path $journalPath -Status COMPLETED
        return [PSCustomObject]@{Status='SUCCEEDED';RunId=$RunId;InstanceId=$InstanceId;Changed=($before.Count -gt 0);RepairKinds=@($before.Kind|Sort-Object -Unique);JournalStatus='COMPLETED'}
    }
    catch {
        $code=if($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}'){[string]$Matches[0]}else{'HYPERV_SQL_PORT_RECONCILE_FAILED'}
        if($journal -and $journalPath){try{$null=Set-LabHyperVSqlPortReconcileJournalStatus -Journal $journal -Path $journalPath -Status RECOVERY_REQUIRED -ErrorCode $code}catch{}}
        if($journal -and $journalPath){throw "HYPERV_SQL_PORT_RECONCILE_RECOVERY_REQUIRED: $code"}
        throw
    }
    finally {if($acquired){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
}
