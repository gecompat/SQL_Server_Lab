function Update-SqlServerLabContainer {
    <#
    .SYNOPSIS Gleicht CPU, RAM und Hostport einer Docker-/Podman-Umgebung mit dem gewünschten Zustand ab.
    .DESCRIPTION CPU, RAM und SQL max memory werden live aktualisiert. Eine
    Portänderung erzeugt den Container kontrolliert neu, übernimmt Environment,
    Labels und sämtliche Bind-/Volume-Mounts und verwendet ein versioniertes
    Journal für Resume, Rollback und sichtbaren Recovery-Bedarf.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$InstanceId,
        [ValidateRange(1, 64)][decimal]$Cpu,
        [ValidateRange(512, 1048576)][int]$MemoryMB,
        [ValidateRange(1024, 65535)][int]$Port,
        [ValidateRange(128, 2147483647)][int]$SqlMaxMemoryMB,
        [ValidateRange(10, 600)][int]$ReadinessTimeoutSeconds = 180,
        [switch]$RepairSqlRuntimeContract,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    if ((Test-LabAutomatedTestEnvironmentRun -RunId $RunId) -and -not $script:LabAutomatedTestEnvironmentGroupOperation) {
        throw 'TEST_ENVIRONMENT_GROUP_PROTECTED: Containeränderung ist für einzelne Testumgebungen gesperrt.'
    }
    $context = Get-LabContainerReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    $null = Repair-LabContainerReconcileJournal -Context $context
    $context = Get-LabContainerReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    $planArguments = @{ RunId=$RunId; InstanceId=[string]$context.InstanceId; StateRoot=$StateRoot; RepairSqlRuntimeContract=$RepairSqlRuntimeContract }
    if ($PSBoundParameters.ContainsKey('Cpu')) { $planArguments.Cpu=[decimal]$Cpu }
    if ($PSBoundParameters.ContainsKey('MemoryMB')) { $planArguments.MemoryMB=[int]$MemoryMB }
    if ($PSBoundParameters.ContainsKey('Port')) { $planArguments.Port=[int]$Port }
    if ($PSBoundParameters.ContainsKey('SqlMaxMemoryMB')) { $planArguments.SqlMaxMemoryMB=[int]$SqlMaxMemoryMB }
    $plan = New-LabContainerReconcilePlan @planArguments
    if ($plan.IsNoOp) {
        return [PSCustomObject]@{
            RunId=$RunId; InstanceId=[string]$context.InstanceId; Provider=[string]$context.Provider
            Container=[string]$context.ContainerName; Changed=$false; Recreated=$false; ChangeClass='no-op'
            Port=[int]$context.CurrentPort; Cpu=[decimal]$context.CurrentCpu; MemoryMB=[int]$context.CurrentMemoryMB
            OperationId=$null; Status='NO_OP'
        }
    }
    if (-not $PSCmdlet.ShouldProcess($context.ContainerName, "Container-Reconcile '$($plan.HighestChangeClass)' ausführen")) { return }
    if ([string]$plan.HighestChangeClass -eq 'recreate' -and [int]$plan.Desired.Port -ne [int]$context.CurrentPort) {
        $binding = Test-LabEndpointBinding -Port ([int]$plan.Desired.Port)
        if (-not $binding.Available) { throw "CONTAINER_RECONCILE_PORT_IN_USE: $($plan.Desired.Port)" }
    }

    $journalInfo = New-LabContainerReconcileJournal -Context $context -Plan $plan
    $journal = $journalInfo.Journal
    $journalPath = $journalInfo.Path
    $runtime = [string]$context.Provider
    $name = [string]$context.ContainerName
    $cpuArgument = ([decimal]$plan.Desired.Cpu).ToString('0.##',[Globalization.CultureInfo]::InvariantCulture)
    $sqlMemoryLimitMB = [int]$plan.Desired.SqlMemoryLimitMB
    try {
        if ([string]$plan.HighestChangeClass -eq 'live') {
            $null = Invoke-LabContainerReconcileCommand -Provider $runtime -Arguments @('update','--cpus',$cpuArgument,'--memory',"$([int]$plan.Desired.MemoryMB)m",$name) -ErrorCode 'CONTAINER_RECONCILE_UPDATE_FAILED'
            $journal = Set-LabContainerReconcileJournalStatus -Journal $journal -Path $journalPath -Status LIVE_MUTATED
            if ($null -ne $plan.Desired.SqlMaxMemoryMB) {
                $null = Set-LabContainerSqlMaxMemoryMB -Context $context -SqlMaxMemoryMB ([int]$plan.Desired.SqlMaxMemoryMB)
            }
            $post = Assert-LabContainerReconcileRuntimeIdentity -Provider $runtime -Identity $name -RunId $RunId -ScopeId ([string]$context.Run.scopeId)
            if ([long]$post.HostConfig.Memory -ne ([long][int]$plan.Desired.MemoryMB * 1MB) -or
                [decimal]([long]$post.HostConfig.NanoCpus / 1000000000) -ne [decimal]$plan.Desired.Cpu) {
                throw 'CONTAINER_RECONCILE_LIVE_POSTCONDITION_FAILED'
            }
            $context.Instance | Add-Member -NotePropertyName cpu -NotePropertyValue ([decimal]$plan.Desired.Cpu) -Force
            $context.Instance | Add-Member -NotePropertyName memoryMB -NotePropertyValue ([int]$plan.Desired.MemoryMB) -Force
            if ($null -ne $plan.Desired.SqlMaxMemoryMB) {
                $context.Instance | Add-Member -NotePropertyName sqlMaxMemoryMB -NotePropertyValue ([int]$plan.Desired.SqlMaxMemoryMB) -Force
            }
            Write-LabArtifactJsonAtomic -Path $context.ConnectionPath -InputObject $context.Connection
            $journal = Set-LabContainerReconcileJournalStatus -Journal $journal -Path $journalPath -Status COMPLETED
            return [PSCustomObject]@{
                RunId=$RunId; InstanceId=[string]$context.InstanceId; Provider=$runtime; Container=$name
                Changed=$true; Recreated=$false; ChangeClass='live'; Port=[int]$plan.Desired.Port
                Cpu=[decimal]$plan.Desired.Cpu; MemoryMB=[int]$plan.Desired.MemoryMB
                SqlMaxMemoryMB=$plan.Desired.SqlMaxMemoryMB; OperationId=[string]$journal.OperationId; Status='SUCCEEDED'
            }
        }

        $backupName = "$name-reconcile-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $journal.Runtime.BackupName = $backupName
        $journal = Write-LabContainerReconcileJournal -Journal $journal -Path $journalPath
        $inspect = $context.Inspect
        $arguments = @('run','-d','--name',$name,'-p',"$([int]$plan.Desired.Port):1433",'--cpus',$cpuArgument,'--memory',"$([int]$plan.Desired.MemoryMB)m")
        if ($inspect.Config.Hostname) { $arguments += @('--hostname',[string]$inspect.Config.Hostname) }
        $networkNames = @($inspect.NetworkSettings.Networks.PSObject.Properties.Name)
        if ($networkNames.Count -gt 0) { $arguments += @('--network',[string]$networkNames[0]) }
        foreach ($entry in @($inspect.Config.Env)) {
            if ([string]$entry -match '^MSSQL_MEMORY_LIMIT_MB=') { continue }
            $arguments += @('-e',[string]$entry)
        }
        $arguments += @('-e',"MSSQL_MEMORY_LIMIT_MB=$sqlMemoryLimitMB")
        foreach ($property in @($inspect.Config.Labels.PSObject.Properties)) { $arguments += @('--label',"$($property.Name)=$($property.Value)") }
        foreach ($mount in @($inspect.Mounts)) {
            if ([string]$mount.Type -eq 'bind') {
                $suffix = if (-not [bool]$mount.RW) { ':ro' } else { '' }
                $arguments += @('-v',"$($mount.Source):$($mount.Destination)$suffix")
            }
            elseif ([string]$mount.Type -eq 'volume' -and $mount.Name) {
                $volumeOptions = @()
                if ($runtime -eq 'podman') { $volumeOptions += 'U' }
                if (-not [bool]$mount.RW) { $volumeOptions += 'ro' }
                $suffix = if ($volumeOptions.Count -gt 0) { ":$($volumeOptions -join ',')" } else { '' }
                $arguments += @('-v',"$($mount.Name):$($mount.Destination)$suffix")
            }
        }
        if ($inspect.HostConfig.RestartPolicy.Name -and [string]$inspect.HostConfig.RestartPolicy.Name -ne 'no') {
            $arguments += @('--restart',[string]$inspect.HostConfig.RestartPolicy.Name)
        }
        $arguments += @('--health-cmd','/opt/mssql-tools*/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "SELECT 1" -b','--health-interval','5s','--health-timeout','3s','--health-retries','30',[string]$inspect.Config.Image)
        if ($context.WasRunning) { $null = Invoke-LabContainerReconcileCommand -Provider $runtime -Arguments @('stop',$name) -ErrorCode 'CONTAINER_RECONCILE_STOP_FAILED' }
        $null = Invoke-LabContainerReconcileCommand -Provider $runtime -Arguments @('rename',$name,$backupName) -ErrorCode 'CONTAINER_RECONCILE_RENAME_FAILED'
        $journal = Set-LabContainerReconcileJournalStatus -Journal $journal -Path $journalPath -Status ORIGINAL_RENAMED
        $null = Invoke-LabContainerReconcileCommand -Provider $runtime -Arguments $arguments -ErrorCode 'CONTAINER_RECONCILE_CREATE_FAILED'
        $replacement = Assert-LabContainerReconcileRuntimeIdentity -Provider $runtime -Identity $name -RunId $RunId -ScopeId ([string]$context.Run.scopeId)
        $journal.Runtime.ReplacementId = [string]$replacement.Id
        $journal = Set-LabContainerReconcileJournalStatus -Journal $journal -Path $journalPath -Status REPLACEMENT_CREATED
        if (-not $context.WasRunning) {
            $null = Invoke-LabContainerReconcileCommand -Provider $runtime -Arguments @('stop',$name) -ErrorCode 'CONTAINER_RECONCILE_REPLACEMENT_STOP_FAILED'
        }
        else {
            $password = Get-LabSecret -Path $context.RunDirectory -Name 'sa-password'
            if (-not $password) { throw 'CONTAINER_RECONCILE_SA_SECRET_MISSING' }
            $hostName = if ($context.Instance.host) { [string]$context.Instance.host } else { '127.0.0.1' }
            $readiness = Wait-SqlReady -HostName $hostName -Port ([int]$plan.Desired.Port) -SaPassword $password `
                -TimeoutSeconds $ReadinessTimeoutSeconds -Provider $runtime -ContainerIdOrName $name
            if (-not $readiness.Ready) { throw "CONTAINER_RECONCILE_READINESS_TIMEOUT: $($readiness.Message)" }
        }
        $replacement = Assert-LabContainerReconcileRuntimeIdentity -Provider $runtime -Identity $name -RunId $RunId -ScopeId ([string]$context.Run.scopeId)
        if ((Get-LabContainerMountFingerprint -Mounts @($replacement.Mounts)) -ne [string]$journal.Target.MountFingerprint) {
            throw 'CONTAINER_RECONCILE_MOUNT_POSTCONDITION_FAILED'
        }
        $replacementPort = @($replacement.NetworkSettings.Ports.'1433/tcp' | Select-Object -First 1)
        if ($replacementPort.Count -ne 1 -or [int]$replacementPort[0].HostPort -ne [int]$plan.Desired.Port) { throw 'CONTAINER_RECONCILE_PORT_POSTCONDITION_FAILED' }
        if ($null -ne $plan.Desired.SqlMaxMemoryMB) {
            $replacementSqlContext = $context | Select-Object *
            $replacementSqlContext.CurrentPort = [int]$plan.Desired.Port
            $null = Set-LabContainerSqlMaxMemoryMB -Context $replacementSqlContext -SqlMaxMemoryMB ([int]$plan.Desired.SqlMaxMemoryMB)
        }
        $journal = Set-LabContainerReconcileJournalStatus -Journal $journal -Path $journalPath -Status VERIFIED
        $context.Instance | Add-Member -NotePropertyName containerId -NotePropertyValue ([string]$replacement.Id) -Force
        $context.Instance | Add-Member -NotePropertyName runtimeId -NotePropertyValue ([string]$replacement.Id) -Force
        $context.Instance | Add-Member -NotePropertyName containerName -NotePropertyValue $name -Force
        $context.Instance | Add-Member -NotePropertyName port -NotePropertyValue ([int]$plan.Desired.Port) -Force
        $context.Instance | Add-Member -NotePropertyName cpu -NotePropertyValue ([decimal]$plan.Desired.Cpu) -Force
        $context.Instance | Add-Member -NotePropertyName memoryMB -NotePropertyValue ([int]$plan.Desired.MemoryMB) -Force
        if ($null -ne $plan.Desired.SqlMaxMemoryMB) {
            $context.Instance | Add-Member -NotePropertyName sqlMaxMemoryMB -NotePropertyValue ([int]$plan.Desired.SqlMaxMemoryMB) -Force
        }
        $hostName = if ($context.Instance.host) { [string]$context.Instance.host } else { '127.0.0.1' }
        $context.Instance | Add-Member -NotePropertyName connectionString -NotePropertyValue (New-SqlConnectionString -HostName $hostName -Port ([int]$plan.Desired.Port)) -Force
        Write-LabArtifactJsonAtomic -Path $context.ConnectionPath -InputObject $context.Connection
        $journal = Set-LabContainerReconcileJournalStatus -Journal $journal -Path $journalPath -Status STATE_COMMITTED
        $null = Invoke-LabContainerReconcileCommand -Provider $runtime -Arguments @('rm','-f',$backupName) -ErrorCode 'CONTAINER_RECONCILE_BACKUP_REMOVE_FAILED'
        $journal = Set-LabContainerReconcileJournalStatus -Journal $journal -Path $journalPath -Status COMPLETED
        return [PSCustomObject]@{
            RunId=$RunId; InstanceId=[string]$context.InstanceId; Provider=$runtime; Container=$name
            Changed=$true; Recreated=$true; ChangeClass='recreate'; Port=[int]$plan.Desired.Port
            Cpu=[decimal]$plan.Desired.Cpu; MemoryMB=[int]$plan.Desired.MemoryMB
            SqlMemoryLimitMB=[int]$plan.Desired.SqlMemoryLimitMB; SqlMaxMemoryMB=$plan.Desired.SqlMaxMemoryMB
            OperationId=[string]$journal.OperationId; Status='SUCCEEDED'
        }
    }
    catch {
        $failure = $_
        $statusBeforeRepair = [string]$journal.Status
        try { $repaired = Repair-LabContainerReconcileJournal -Context $context }
        catch { throw "CONTAINER_RECONCILE_AND_RECOVERY_FAILED: $($failure.Exception.Message) / $($_.Exception.Message)" }
        if ($statusBeforeRepair -eq 'STATE_COMMITTED' -and [string]$repaired.Status -eq 'COMPLETED') {
            return [PSCustomObject]@{
                RunId=$RunId; InstanceId=[string]$context.InstanceId; Provider=$runtime; Container=$name
                Changed=$true; Recreated=$true; ChangeClass='recreate'; Port=[int]$plan.Desired.Port
                Cpu=[decimal]$plan.Desired.Cpu; MemoryMB=[int]$plan.Desired.MemoryMB
                OperationId=[string]$journal.OperationId; Status='SUCCEEDED_AFTER_RESUME'
            }
        }
        throw $failure
    }
}

function Update-LabContainerEnvironmentInteractive {
    [CmdletBinding()]
    param()
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $floatStyles = [System.Globalization.NumberStyles]::Number
    $readNumericValue = {
        param(
            [string]$Label,
            [decimal]$Current,
            [decimal]$Minimum,
            [decimal]$Maximum,
            [bool]$RequireInteger = $false
        )

        while ($true) {
            $suffix = if ($RequireInteger) { 'ganze Zahl' } else { 'Zahl' }
            $format = if ($RequireInteger) { '{0}' -f [int]$Current } else { '{0}' -f ($Current.ToString('0.##', $culture)) }
            $text = Read-Host ("  {0} [{1}] ({2} bis {3}, {4})" -f $Label, $format, $Minimum, $Maximum, $suffix)
            if (-not $text) { return $Current }

            $candidate = [int]0
            $ok = if ($RequireInteger) {
                [int]::TryParse($text, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::CurrentCulture, [ref]$candidate) -or
                [int]::TryParse($text, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$candidate)
            } else {
                $parsed = [decimal]0
                [decimal]::TryParse($text, $floatStyles, [System.Globalization.CultureInfo]::CurrentCulture, [ref]$parsed) -or
                [decimal]::TryParse($text, $floatStyles, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)
            }
            if (-not $ok) {
                Write-LabWarning "Ungültige Eingabe. Bitte eine gültige $suffix eingeben (oder Enter für den aktuellen Wert)."
                continue
            }

            if ($RequireInteger) {
                if ($candidate -lt $Minimum -or $candidate -gt $Maximum) {
                    Write-LabWarning "Ungültiger Bereich: $candidate ist nicht zwischen $Minimum und $Maximum."
                    continue
                }
                return [decimal]$candidate
            }

            if ([math]::Round($parsed, 2) -lt $Minimum -or [math]::Round($parsed, 2) -gt $Maximum) {
                Write-LabWarning "Ungültiger Bereich: $parsed ist nicht zwischen $Minimum und $Maximum."
                continue
            }
            return [decimal]$parsed
        }
    }

    $isHostPortAvailable = {
        param([int]$Port, [int]$CurrentPort)
        if ($Port -eq $CurrentPort) { return $true }
        try {
            return -not [bool](& Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
        } catch {
            return $true
        }
    }

    $stateRoot = Get-LabStateRoot
    $choices = @()
    foreach ($run in @(Get-LabActiveRuns)) {
        $path = Join-Path (Join-Path (Join-Path $stateRoot 'runs') ([string]$run.runId)) 'connection-info.json'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $connection = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
        if (@($connection.instances | Where-Object { [string]$_.provider -in @('docker','podman') }).Count -eq 1) {
            $choices += [PSCustomObject]@{ Run=$run; Connection=$connection }
        }
    }
    if ($choices.Count -eq 0) { Write-LabInfo 'Keine änderbare Docker-/Podman-Umgebung vorhanden.'; return }
    $protectedRunIds = @(Get-LabAutomatedTestEnvironmentRunIds)
    $environmentItems = for ($i=0; $i -lt $choices.Count; $i++) {
        $instance = @($choices[$i].Connection.instances)[0]
        $protected = [string]$choices[$i].Run.runId -in $protectedRunIds
        $value = if ($protected) { "{0} - Port {1} · geschützte Testgruppe" -f $instance.provider, $instance.port } else { "{0} - Port {1}" -f $instance.provider, $instance.port }
        New-LabConsoleItem -Id ([string]$choices[$i].Run.runId) -Label ([string]$choices[$i].Run.metadata.name) -Value $value -Shortcut ([string]($i + 1)) -Data $choices[$i] -Disabled:$protected
    }
    $environmentResult = Invoke-LabConsoleMenu -ScreenId 'container-update-environment' -Title 'Docker-/Podman-Umgebung auswaehlen' -Items $environmentItems -FallbackPrompt '  Umgebung auswaehlen'
    if ($environmentResult.Status -ne 'Selected') {
        if ($environmentResult.Status -eq 'Invalid') { Write-LabWarning 'Ungueltige Auswahl.' }
        return
    }
    $selected = $environmentResult.SelectedItem.Data
    $provider = $null
    $containerIdentity = $null
    foreach ($providerCandidate in @('docker', 'podman')) {
        $candidate = $selected.Connection.instances | Where-Object { [string]$_.provider -eq $providerCandidate } | Select-Object -First 1
        if (-not $candidate) { continue }
        $provider = $providerCandidate
        $containerIdentity = @(
            [string]$candidate.containerId,
            [string]$candidate.runtimeId,
            [string]$candidate.name,
            [string]$candidate.id
        ) | Where-Object { $_ }
        break
    }
    $currentCpu = if ($selected.Connection.instances[0].cpu) { [decimal]$selected.Connection.instances[0].cpu } else { 2 }
    $currentMemoryMB = if ($selected.Connection.instances[0].memoryMB) { [int]$selected.Connection.instances[0].memoryMB } else { 2048 }
    $currentPort = if ($selected.Connection.instances[0].port) { [int]$selected.Connection.instances[0].port } else { 1433 }

    if ($provider -and $containerIdentity) {
        try {
            $inspect = @(& $provider inspect $containerIdentity[0] 2>$null | ConvertFrom-Json -Depth 50)[0]
            if ($inspect -and $inspect.HostConfig) {
                if ($inspect.HostConfig.NanoCpus -gt 0) {
                    $currentCpu = [decimal]([long]$inspect.HostConfig.NanoCpus / 1000000000)
                }
                if ($inspect.HostConfig.Memory -gt 0) {
                    $currentMemoryMB = [int]([long]$inspect.HostConfig.Memory / 1MB)
                }
                $portCandidate = @($inspect.NetworkSettings.Ports.'1433/tcp' | Select-Object -First 1).HostPort
                if ($portCandidate) { $currentPort = [int]$portCandidate }
            }
        } catch {}
    }

    # Runtimezustand und Werte sind ein Snapshot. Navigation und Review mutieren den Provider nicht.
    $environmentName = [string]$selected.Run.metadata.name
    $fields = @(
        New-LabConsoleField -Id 'cpu' -Label 'vCPU (1..64)' -Value $currentCpu -Shortcut '1' -Editor { param($current, $values) & $readNumericValue -Label '  vCPU' -Current $current -Minimum 1 -Maximum 64 -RequireInteger $false } -Formatter { param($value) ([decimal]$value).ToString('0.##', $culture) }
        New-LabConsoleField -Id 'memory' -Label 'RAM MB (512..1048576)' -Value $currentMemoryMB -Shortcut '2' -Editor { param($current, $values) [int](& $readNumericValue -Label '  RAM MB' -Current $current -Minimum 512 -Maximum 1048576 -RequireInteger $true) }
        New-LabConsoleField -Id 'port' -Label 'Hostport (1024..65535)' -Value $currentPort -Shortcut '3' -Editor { param($current, $values) [int](& $readNumericValue -Label '  Hostport' -Current $current -Minimum 1024 -Maximum 65535 -RequireInteger $true) } -Validator { param($value, $values) if (-not (& $isHostPortAvailable -Port ([int]$value) -CurrentPort $currentPort)) { "Hostport $value wird bereits von einem anderen Dienst verwendet." } }
    )
    $formResult = Invoke-LabConsoleForm -ScreenId 'container-update-form' -Title 'Docker-/Podman-Umgebung aendern' -Subtitle ("Umgebung: {0} - {1}" -f $environmentName, $provider) -Fields $fields
    if ($formResult.Status -ne 'Confirmed') { Write-LabInfo 'Abbruch durch Nutzer.'; return }
    $cpu = [decimal]$formResult.Values['cpu']
    $memoryMB = [int]$formResult.Values['memory']
    $port = [int]$formResult.Values['port']

    $arguments = @{
        RunId=[string]$selected.Run.runId
        Container=$true
        Cpu=[decimal]$cpu
        MemoryMB=[int]$memoryMB
        Port=[int]$port
    }

    try {
        $action = Invoke-SqlServerLabReconcileAction @arguments -Confirm:$false
        if ([string]$action.ExecutionSummary.Status -eq 'FAILED') {
            throw ([string]@($action.ExecutionSummary.Errors)[0])
        }
        $result = if ([string]$action.ExecutionSummary.Status -eq 'NO_OP') {
            [PSCustomObject]@{
                Changed=$false; Provider=[string]$action.Plan.Provider; Container=[string]$action.Plan.InstanceId
                Cpu=[decimal]$action.Plan.Desired.Cpu; MemoryMB=[int]$action.Plan.Desired.MemoryMB; Port=[int]$action.Plan.Desired.Port
            }
        } else { $action.ExecutionPlan[0].Result }
    } catch {
        $message = $_.Exception.Message
        if ($message -like 'CONTAINER_RECONCILE_PORT_IN_USE:*') {
            Write-LabError 'Hostport wird bereits verwendet. Bitte andere Portnummer wählen.'
            return
        }
        throw
    }

    if ($result.Changed) { Write-LabSuccess "Container abgeglichen: $($result.Provider) · $($result.Container) · CPU $($result.Cpu) · RAM $($result.MemoryMB) MB · Port $($result.Port)" }
    else { Write-LabInfo 'Die Umgebung entspricht bereits dem gewünschten Zustand.' }
}
