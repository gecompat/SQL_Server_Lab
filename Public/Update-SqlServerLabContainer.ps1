function Update-SqlServerLabContainer {
    <#
    .SYNOPSIS Gleicht CPU, RAM und Hostport einer Docker-/Podman-Umgebung mit dem gewünschten Zustand ab.
    .DESCRIPTION Ressourcen werden in-place aktualisiert. Eine Portänderung erzeugt den Container kontrolliert
    neu, übernimmt Environment, Labels und sämtliche Bind-/Volume-Mounts und rollt bei fehlender Readiness zurück.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [ValidateRange(1, 64)][decimal]$Cpu,
        [ValidateRange(512, 1048576)][int]$MemoryMB,
        [ValidateRange(1024, 65535)][int]$Port,
        [ValidateRange(10, 600)][int]$ReadinessTimeoutSeconds = 180,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    if (Test-LabAutomatedTestEnvironmentRun -RunId $RunId) {
        throw 'TEST_ENVIRONMENT_GROUP_PROTECTED: Containeränderung ist für einzelne Testumgebungen gesperrt.'
    }
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'CONTAINER_RECONCILE_CONNECTION_INFO_MISSING' }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $instances = @($connection.instances | Where-Object { [string]$_.provider -in @('docker','podman') })
    if ($instances.Count -ne 1) { throw "CONTAINER_RECONCILE_INSTANCE_NOT_UNIQUE: $($instances.Count)" }
    $instance = $instances[0]
    $runtime = [string]$instance.provider
    if (-not (Get-Command $runtime -ErrorAction SilentlyContinue)) { throw "CONTAINER_RECONCILE_RUNTIME_NOT_AVAILABLE: $runtime" }
    $identity = @(
        [string]$instance.containerId
        [string]$instance.runtimeId
        [string]$instance.name
        [string]$instance.id
    ) | Where-Object { $_ } | Select-Object -First 1
    if (-not $identity) { throw 'CONTAINER_RECONCILE_IDENTITY_MISSING' }
    $inspect = @(& $runtime inspect $identity 2>$null | ConvertFrom-Json -Depth 50)[0]
    if (-not $inspect) { throw "CONTAINER_RECONCILE_CONTAINER_NOT_FOUND: $identity" }
    $name = ([string]$inspect.Name).TrimStart('/')
    $wasRunning = [bool]$inspect.State.Running
    $currentPort = [int]@($inspect.NetworkSettings.Ports.'1433/tcp' | Select-Object -First 1).HostPort
    $currentMemoryMB = if ([long]$inspect.HostConfig.Memory -gt 0) { [int]([long]$inspect.HostConfig.Memory / 1MB) } else { 2048 }
    $currentCpu = if ([long]$inspect.HostConfig.NanoCpus -gt 0) { [decimal]([long]$inspect.HostConfig.NanoCpus / 1000000000) } else { 2 }
    if (-not $PSBoundParameters.ContainsKey('Cpu')) { $Cpu = $currentCpu }
    if (-not $PSBoundParameters.ContainsKey('MemoryMB')) { $MemoryMB = $currentMemoryMB }
    if (-not $PSBoundParameters.ContainsKey('Port')) { $Port = $currentPort }
    if ($Cpu -eq $currentCpu -and $MemoryMB -eq $currentMemoryMB -and $Port -eq $currentPort) {
        return [PSCustomObject]@{ RunId=$RunId; Provider=$runtime; Container=$name; Changed=$false; Port=$currentPort; Cpu=$currentCpu; MemoryMB=$currentMemoryMB }
    }
    if (-not $PSCmdlet.ShouldProcess($name, "Containerzustand auf CPU=$Cpu, RAM=${MemoryMB}MB, Port=$Port abgleichen")) { return }

    $cpuArgument = $Cpu.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)
    if ($Port -eq $currentPort) {
        $output = & $runtime update --cpus $cpuArgument --memory "${MemoryMB}m" $name 2>&1
        if ($LASTEXITCODE -ne 0) { throw "CONTAINER_RECONCILE_UPDATE_FAILED: $($output -join ' ')" }
        $instance | Add-Member -NotePropertyName cpu -NotePropertyValue $Cpu -Force
        $instance | Add-Member -NotePropertyName memoryMB -NotePropertyValue $MemoryMB -Force
        Write-LabArtifactJsonAtomic -Path $connectionPath -InputObject $connection
        return [PSCustomObject]@{ RunId=$RunId; Provider=$runtime; Container=$name; Changed=$true; Recreated=$false; Port=$Port; Cpu=$Cpu; MemoryMB=$MemoryMB }
    }

    $occupied = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    if ($occupied) { throw "CONTAINER_RECONCILE_PORT_IN_USE: $Port" }
    $backupName = "$name-reconcile-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $image = [string]$inspect.Config.Image
    $containerHost = if ($instance.host) { [string]$instance.host } else { '127.0.0.1' }
    $saPassword = if ($wasRunning) { Get-LabSecret -Path $runDirectory -Name 'sa-password' } else { $null }
    if ($wasRunning -and -not $saPassword) { throw 'CONTAINER_RECONCILE_SA_SECRET_MISSING' }
    $arguments = @('run','-d','--name',$name,'-p',"${Port}:1433",'--cpus',$cpuArgument,'--memory',"${MemoryMB}m")
    foreach ($entry in @($inspect.Config.Env)) { $arguments += @('-e',[string]$entry) }
    foreach ($property in @($inspect.Config.Labels.PSObject.Properties)) { $arguments += @('--label',"$($property.Name)=$($property.Value)") }
    foreach ($mount in @($inspect.Mounts)) {
        if ([string]$mount.Type -eq 'bind') {
            $suffix = if (-not [bool]$mount.RW) { ':ro' } else { '' }
            $arguments += @('-v',"$($mount.Source):$($mount.Destination)$suffix")
        }
        elseif ([string]$mount.Type -eq 'volume' -and $mount.Name) {
            $suffix = if (-not [bool]$mount.RW) { ':ro' } else { '' }
            $arguments += @('-v',"$($mount.Name):$($mount.Destination)$suffix")
        }
    }
    if ($inspect.HostConfig.RestartPolicy.Name -and [string]$inspect.HostConfig.RestartPolicy.Name -ne 'no') {
        $arguments += @('--restart',[string]$inspect.HostConfig.RestartPolicy.Name)
    }
    $arguments += $image
    $originalRenamed = $false
    $replacementCreated = $false
    try {
        if ($wasRunning) { $null = & $runtime stop $name 2>&1 }
        $renameOutput = & $runtime rename $name $backupName 2>&1
        if ($LASTEXITCODE -ne 0) { throw "CONTAINER_RECONCILE_RENAME_FAILED: $($renameOutput -join ' ')" }
        $originalRenamed = $true
        $newId = @(& $runtime @arguments 2>&1)[-1]
        if ($LASTEXITCODE -ne 0) { throw "CONTAINER_RECONCILE_CREATE_FAILED: $newId" }
        $replacementCreated = $true
        if (-not $wasRunning) { $null = & $runtime stop $name 2>&1 }
        else {
            $readiness = Wait-SqlReady `
                -HostName $containerHost `
                -Port $Port `
                -SaPassword $saPassword `
                -TimeoutSeconds $ReadinessTimeoutSeconds `
                -Provider $runtime `
                -ContainerIdOrName $name
            if (-not $readiness.Ready) { throw "CONTAINER_RECONCILE_READINESS_TIMEOUT: $($readiness.Message)" }
        }
        $removeOutput = & $runtime rm -f $backupName 2>&1
        if ($LASTEXITCODE -ne 0) { throw "CONTAINER_RECONCILE_BACKUP_REMOVE_FAILED: $($removeOutput -join ' ')" }
        $originalRenamed = $false
        $instance | Add-Member -NotePropertyName containerId -NotePropertyValue ([string]$newId).Trim() -Force
        $instance | Add-Member -NotePropertyName runtimeId -NotePropertyValue ([string]$newId).Trim() -Force
        $instance | Add-Member -NotePropertyName port -NotePropertyValue $Port -Force
        $instance | Add-Member -NotePropertyName cpu -NotePropertyValue $Cpu -Force
        $instance | Add-Member -NotePropertyName memoryMB -NotePropertyValue $MemoryMB -Force
        $instance | Add-Member -NotePropertyName connectionString -NotePropertyValue (New-SqlConnectionString -HostName $containerHost -Port $Port) -Force
        Write-LabArtifactJsonAtomic -Path $connectionPath -InputObject $connection
        return [PSCustomObject]@{ RunId=$RunId; Provider=$runtime; Container=$name; Changed=$true; Recreated=$true; Port=$Port; Cpu=$Cpu; MemoryMB=$MemoryMB }
    }
    catch {
        if ($replacementCreated) { $null = & $runtime rm -f $name 2>&1 }
        if ($originalRenamed) {
            $null = & $runtime rename $backupName $name 2>&1
            if ($wasRunning) { $null = & $runtime start $name 2>&1 }
        }
        throw
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
        Cpu=[decimal]$cpu
        MemoryMB=[int]$memoryMB
        Port=[int]$port
    }

    try {
        $result = Update-SqlServerLabContainer @arguments
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
