function New-LabContainerAutoStartPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][ValidateSet('on','off')][string]$AutoStart,
        [string]$StateRoot
    )
    # ValidateSet accepts case variants; requested values share one content key.
    $AutoStart=$AutoStart.ToLowerInvariant()
    # This DTO deliberately projects categories instead of local host ports.
    # Its content hash is observation evidence, never an executable plan key.
    $result = [pscustomobject]@{
        Contract=[pscustomobject]@{Name='SqlServerLab.ContainerAutoStartPreview';Version='1.0'}
        Mode='CONTAINER_AUTOSTART_PREVIEW_PLAN_ONLY'; Status='BLOCKED'; Reason='AUTOSTART_PREVIEW_BINDING_UNAVAILABLE'
        Provider=$null; CanApply=$false; MutationAllowed=$false; Actions=@(); ObservationKey=$null
        Actual=[pscustomobject]@{Evidence='UNKNOWN';SqlBinding='UNKNOWN';Lifecycle='UNKNOWN';AutoStart='UNKNOWN'}
        Desired=[pscustomobject]@{AutoStartChange='UNKNOWN'}; NoChange=$null; ChangeClass='unsupported'
        Preview=[pscustomobject]@{Downtime='UNKNOWN';Endpoint='NOT_CHECKED';Sql='NOT_CHECKED';Backup='NOT_CHECKED';HostLogin='NOT_CHECKED';Mounts=$null;DataImpact='NOT_VERIFIED'}
    }
    try {
        if (-not $StateRoot) { $StateRoot=Get-LabStateRoot }
        $root=Assert-LabDiagnosticPath -Path $StateRoot
        if ([IO.Path]::GetFileName($root) -cne 'State') { return $result }
        $binding=Get-LabDiagnosticBinding -RunId $RunId -InstanceId $InstanceId -DataRoot ([IO.Path]::GetDirectoryName($root))
        if ($binding.Provider -cnotin @('docker','podman')) {
            $result.Status='UNSUPPORTED'; $result.Reason='AUTOSTART_PREVIEW_PROVIDER_UNSUPPORTED'; return $result
        }
        try { Assert-LabResourceChangeAllowed -RunId $RunId -StateRoot $root }
        catch { $result.Reason='AUTOSTART_PREVIEW_PROTECTED_TARGET'; return $result }
        $sub=@($binding.Run.providerSubRuns | Where-Object provider -CEQ $binding.Provider)
        if ($binding.Run.state -cne 'RUNNING' -or $sub.Count -ne 1 -or $sub[0].state -cne 'RUNNING') {
            $result.Reason='AUTOSTART_PREVIEW_RUNNING_REQUIRED'; return $result
        }
        $connection=Read-LabDiagnosticJson -Path (Join-Path $binding.Directory 'connection-info.json')
        $rows=@($connection.instances | Where-Object { $_.id -ceq $InstanceId -and $_.provider -ceq $binding.Provider })
        if ($connection.instances -isnot [array] -or $rows.Count -ne 1 -or
            $rows[0].containerId -isnot [string] -or $rows[0].containerId -cnotmatch '^[a-f0-9]{64}$') { return $result }
        $journalPath=Get-LabContainerReconcileJournalPath -RunDirectory $binding.Directory
        $journal=Read-LabDiagnosticJson -Path $journalPath -Optional
        $journalDigest='absent'
        if ($journal) {
            $null=Assert-LabContainerReconcileJournal -Journal $journal
            if ($journal.RunId -cne $RunId -or $journal.ScopeId -cne $binding.Run.scopeId -or
                $journal.InstanceId -cne $InstanceId -or $journal.Provider -cne $binding.Provider -or
                $journal.Status -cnotin @('COMPLETED','ROLLED_BACK')) {
                $result.Reason='AUTOSTART_PREVIEW_JOURNAL_BLOCKED'; return $result
            }
            $journalDigest=Get-LabWorkflowHash -Text ($journal | ConvertTo-Json -Depth 50 -Compress) -Length 64
        }
        # One context read; owned-origin validation may perform additional reads.
        # Never use its legacy fallback limits or first-port projection here.
        $context=Get-LabContainerReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $root
        $inspect=$context.Inspect
        if ($inspect.Id -isnot [string] -or $inspect.Config.Labels.'sql-server-lab.run-id' -isnot [string] -or
            $inspect.Config.Labels.'sql-server-lab.scope-id' -isnot [string] -or $inspect.Config.Labels.'sql-server-lab.instance-id' -isnot [string] -or
            $context.Provider -cne $binding.Provider -or $context.ContainerId -cne $rows[0].containerId -or
            $context.Run.scopeId -cne $binding.Run.scopeId -or $context.Run.state -cne 'RUNNING' -or
            $inspect.Id -cne $rows[0].containerId -or $inspect.State.Running -isnot [bool] -or -not $inspect.State.Running -or
            $inspect.Config.Labels.'sql-server-lab.run-id' -cne $RunId -or
            $inspect.Config.Labels.'sql-server-lab.scope-id' -cne $binding.Run.scopeId -or
            $inspect.Config.Labels.'sql-server-lab.instance-id' -cne $InstanceId) { return $result }
        # Require raw scalar evidence, with no missing-label OFF fallback.
        $label=$inspect.Config.Labels.'sql-server-lab.autostart'
        $policy=$inspect.HostConfig.RestartPolicy.Name
        if ($label -isnot [string] -or $label -cnotin @('on','off') -or $policy -isnot [string]) {
            $result.Reason='AUTOSTART_PREVIEW_POLICY_UNKNOWN'; return $result
        }
        if ($policy -cnotin @('','no','always','unless-stopped')) {
            $result.Status='UNSUPPORTED';$result.Reason='AUTOSTART_PREVIEW_POLICY_UNSUPPORTED'; return $result
        }
        $current=if($policy -cin @('always','unless-stopped')){'on'}else{'off'}
        if ($label -cne $current) {
            $result.Actual.AutoStart='DRIFTED';$result.Reason='AUTOSTART_PREVIEW_POLICY_DRIFTED'; return $result
        }
        $ports=$inspect.NetworkSettings.Ports
        $configuredPorts=$inspect.HostConfig.PortBindings
        $networks=$inspect.NetworkSettings.Networks
        $sqlPorts=@($ports.'1433/tcp')
        $configuredSql=@($configuredPorts.'1433/tcp')
        if ($ports -isnot [pscustomobject] -or $configuredPorts -isnot [pscustomobject] -or $networks -isnot [pscustomobject] -or
            $ports.'1433/tcp' -isnot [array] -or $configuredPorts.'1433/tcp' -isnot [array] -or
            @($ports.PSObject.Properties).Count -ne 1 -or @($configuredPorts.PSObject.Properties).Count -ne 1 -or
            @($networks.PSObject.Properties).Count -ne 1 -or $sqlPorts.Count -ne 1 -or $configuredSql.Count -ne 1 -or
            $sqlPorts[0].HostIp -isnot [string] -or $configuredSql[0].HostIp -isnot [string] -or
            $sqlPorts[0].HostIp -cne '127.0.0.1' -or $configuredSql[0].HostIp -cne '127.0.0.1' -or
            $sqlPorts[0].HostPort -isnot [string] -or $sqlPorts[0].HostPort -cnotmatch '^[1-9][0-9]{0,4}$' -or
            $configuredSql[0].HostPort -isnot [string] -or $configuredSql[0].HostPort -cne $sqlPorts[0].HostPort -or [int]$sqlPorts[0].HostPort -gt 65535) {
            $result.Status='UNSUPPORTED'; $result.Reason='AUTOSTART_PREVIEW_TOPOLOGY_UNSUPPORTED'; return $result
        }
        $network=@($networks.PSObject.Properties)[0].Value
        if ($network -isnot [pscustomobject] -or
            ($null -ne $network.Aliases -and $network.Aliases -isnot [array]) -or
            ($null -ne $network.IPAMConfig -and $network.IPAMConfig -isnot [pscustomobject]) -or
            ($null -ne $inspect.Config.ExposedPorts -and $inspect.Config.ExposedPorts -isnot [pscustomobject]) -or
            ($null -ne $inspect.HostConfig.PublishAllPorts -and $inspect.HostConfig.PublishAllPorts -isnot [bool])) {
            $result.Status='UNSUPPORTED';$result.Reason='AUTOSTART_PREVIEW_TOPOLOGY_UNSUPPORTED';return $result
        }
        foreach($field in @('Dns','ExtraHosts','Links')) {
            $value=$inspect.HostConfig.$field
            if ($null -ne $value -and ($value -isnot [array] -or @($value | Where-Object { $null -ne $_ }).Count)) {
                $result.Status='UNSUPPORTED';$result.Reason='AUTOSTART_PREVIEW_TOPOLOGY_UNSUPPORTED';return $result
            }
        }
        foreach($alias in @($network.Aliases)) {
            if ($null -ne $alias -and $alias -isnot [string]) {
                $result.Status='UNSUPPORTED';$result.Reason='AUTOSTART_PREVIEW_TOPOLOGY_UNSUPPORTED';return $result
            }
        }
        # Additional aliases, fixed IP requests or host/container networking are
        # not equivalent to the current single-network recreate path.
        if ($inspect.HostConfig.NetworkMode -isnot [string] -or [string]::IsNullOrWhiteSpace($inspect.HostConfig.NetworkMode) -or
            $inspect.HostConfig.NetworkMode -cin @('host','none') -or
            [string]$inspect.HostConfig.NetworkMode -like 'container:*' -or
            @($inspect.HostConfig.Dns | Where-Object { $_ }).Count -or
            @($inspect.HostConfig.ExtraHosts | Where-Object { $_ }).Count -or
            @($inspect.HostConfig.Links | Where-Object { $_ }).Count -or $inspect.HostConfig.PublishAllPorts -eq $true -or
            @($inspect.Config.ExposedPorts.PSObject.Properties | Where-Object { $_ -and $_.Name -cne '1433/tcp' }).Count -or
            @($network.Aliases | Where-Object { $null -ne $_ -and $_ -cnotin @($context.ContainerName,$context.ContainerId,$context.ContainerId.Substring(0,12)) }).Count -or
            ($network.IPAMConfig -and ($network.IPAMConfig | ConvertTo-Json -Compress) -cne '{}')) {
            $result.Status='UNSUPPORTED'; $result.Reason='AUTOSTART_PREVIEW_TOPOLOGY_UNSUPPORTED'; return $result
        }
        $cpu=Get-LabContainerMeasuredCpu -Inspect $inspect
        if ($null -eq $cpu -or $cpu -lt 1 -or $cpu -gt 64 -or [long]$inspect.HostConfig.Memory -lt 512MB -or
            [long]$inspect.HostConfig.Memory % 1MB -ne 0 -or [long]$inspect.HostConfig.Memory -gt 1048576MB) {
            $result.Reason='AUTOSTART_PREVIEW_LIMITS_UNKNOWN'; return $result
        }
        try { $null=@(Get-LabContainerRecreateMountArguments -Inspect $inspect -Provider $binding.Provider) }
        catch { $result.Status='UNSUPPORTED'; $result.Reason='AUTOSTART_PREVIEW_MOUNTS_UNSUPPORTED'; return $result }
        $same=$AutoStart -ceq $current
        $observed=[ordered]@{
            Root=$root; Run=$RunId; Scope=$binding.Run.scopeId; Instance=$InstanceId; Provider=$binding.Provider
            RuntimeId=$context.ContainerId; RunState=$binding.Run.state; ProviderState=$sub[0].state
            Config=$inspect.Config; HostConfig=$inspect.HostConfig; Image=$inspect.Image
            Ports=$ports; Networks=$networks
            Mounts=(Get-LabContainerMountFingerprint -Mounts @($inspect.Mounts)); Journal=$journalDigest; DesiredAutoStart=$AutoStart
        }
        $result.ObservationKey=Get-LabWorkflowHash -Text ($observed | ConvertTo-Json -Depth 50 -Compress) -Length 64
        $result.Provider=$binding.Provider; $result.Status='PLAN_ONLY'; $result.Reason='AUTOSTART_PREVIEW_APPLY_NOT_IMPLEMENTED'
        $result.Actual=[pscustomobject]@{Evidence='MEASURED';SqlBinding='SINGLE_LOOPBACK_1433_TCP';Lifecycle='RUNNING';AutoStart=if($current -ceq 'on'){'ON'}else{'OFF'}}
        $result.Desired.AutoStartChange=if($same){'SAME_POLICY'}else{'DIFFERENT_POLICY'}
        $result.NoChange=$same; $result.ChangeClass=if($same){'no-op'}else{'recreate'}
        $result.Preview.Downtime=if($same){'NONE'}else{'REQUIRED'}
        $result.Preview.Mounts=Get-LabContainerMountPreview -Inspect $inspect
        return $result
    }
    catch {
        # Raw diagnostic/runtime exceptions can contain host paths or identities.
        # Return the fixed unavailable DTO rather than forwarding that text.
        return $result
    }
}
