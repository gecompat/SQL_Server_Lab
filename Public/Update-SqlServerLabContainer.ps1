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
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'CONTAINER_RECONCILE_CONNECTION_INFO_MISSING' }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $instances = @($connection.instances | Where-Object { [string]$_.provider -in @('docker','podman') })
    if ($instances.Count -ne 1) { throw "CONTAINER_RECONCILE_INSTANCE_NOT_UNIQUE: $($instances.Count)" }
    $instance = $instances[0]
    $runtime = [string]$instance.provider
    if (-not (Get-Command $runtime -ErrorAction SilentlyContinue)) { throw "CONTAINER_RECONCILE_RUNTIME_NOT_AVAILABLE: $runtime" }
    $identity = @([string]$instance.containerId, [string]$instance.runtimeId, [string]$instance.name, [string]$instance.id | Where-Object { $_ })[0]
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

    if ($Port -eq $currentPort) {
        $output = & $runtime update --cpus ([string]$Cpu) --memory "${MemoryMB}m" $name 2>&1
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
    $arguments = @('run','-d','--name',$name,'-p',"${Port}:1433",'--cpus',([string]$Cpu),'--memory',"${MemoryMB}m")
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
    try {
        if ($wasRunning) { $null = & $runtime stop $name 2>&1 }
        $renameOutput = & $runtime rename $name $backupName 2>&1
        if ($LASTEXITCODE -ne 0) { throw "CONTAINER_RECONCILE_RENAME_FAILED: $($renameOutput -join ' ')" }
        $newId = @(& $runtime @arguments 2>&1)[-1]
        if ($LASTEXITCODE -ne 0) { throw "CONTAINER_RECONCILE_CREATE_FAILED: $newId" }
        if (-not $wasRunning) { $null = & $runtime stop $name 2>&1 }
        else {
            $deadline = [datetime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
            do {
                $ready = Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue
                if ($ready) { break }
                Start-Sleep -Seconds 2
            } while ([datetime]::UtcNow -lt $deadline)
            if (-not $ready) { throw "CONTAINER_RECONCILE_READINESS_TIMEOUT: 127.0.0.1:$Port" }
        }
        $null = & $runtime rm -f $backupName 2>&1
        $instance | Add-Member -NotePropertyName containerId -NotePropertyValue ([string]$newId).Trim() -Force
        $instance | Add-Member -NotePropertyName runtimeId -NotePropertyValue ([string]$newId).Trim() -Force
        $instance | Add-Member -NotePropertyName port -NotePropertyValue $Port -Force
        $instance | Add-Member -NotePropertyName cpu -NotePropertyValue $Cpu -Force
        $instance | Add-Member -NotePropertyName memoryMB -NotePropertyValue $MemoryMB -Force
        $instance | Add-Member -NotePropertyName connectionString -NotePropertyValue (New-SqlConnectionString -HostName '127.0.0.1' -Port $Port) -Force
        Write-LabArtifactJsonAtomic -Path $connectionPath -InputObject $connection
        return [PSCustomObject]@{ RunId=$RunId; Provider=$runtime; Container=$name; Changed=$true; Recreated=$true; Port=$Port; Cpu=$Cpu; MemoryMB=$MemoryMB }
    }
    catch {
        $null = & $runtime rm -f $name 2>&1
        $null = & $runtime rename $backupName $name 2>&1
        if ($wasRunning) { $null = & $runtime start $name 2>&1 }
        throw
    }
}

function Update-LabContainerEnvironmentInteractive {
    [CmdletBinding()]
    param()
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
    for ($i=0; $i -lt $choices.Count; $i++) {
        $instance = @($choices[$i].Connection.instances)[0]
        Write-Host ("    [{0}] {1} · {2} · Port {3}" -f ($i+1), $choices[$i].Run.metadata.name, $instance.provider, $instance.port) -ForegroundColor White
    }
    $selection = Read-Host '  Umgebung auswählen'
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $choices.Count) { Write-LabWarning 'Ungültige Auswahl.'; return }
    $selected = $choices[[int]$selection-1]
    $cpuText = Read-Host '  vCPU [unverändert]'
    $memoryText = Read-Host '  RAM MB [unverändert]'
    $portText = Read-Host '  Hostport [unverändert]'
    $arguments = @{ RunId=[string]$selected.Run.runId }
    if ($cpuText) { $arguments.Cpu = [decimal]$cpuText }
    if ($memoryText) { $arguments.MemoryMB = [int]$memoryText }
    if ($portText) { $arguments.Port = [int]$portText }
    if (-not (Read-LabConfirm -Prompt '  Sollzustand jetzt automatisch anwenden?' -Default $false)) { return }
    $result = Update-SqlServerLabContainer @arguments
    if ($result.Changed) { Write-LabSuccess "Container abgeglichen: $($result.Provider) · $($result.Container) · CPU $($result.Cpu) · RAM $($result.MemoryMB) MB · Port $($result.Port)" }
    else { Write-LabInfo 'Die Umgebung entspricht bereits dem gewünschten Zustand.' }
}
