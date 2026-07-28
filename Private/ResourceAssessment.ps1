function Test-SqlServerLabPrerequisite {
    <#
    .SYNOPSIS
        Fuehrt ein vollstaendiges Resource-Assessment durch.
    .DESCRIPTION
        Prueft Provider-Verfuegbarkeit, RAM, Storage, Ports und optional die
        Sicherheit eines Zielpfads, ohne Labressourcen zu erstellen oder zu
        veraendern.
    .PARAMETER Instances
        Array von Instanzdefinitionen, typischerweise aus einem aufgeloesten
        Manifest. Ohne Angabe werden hostweite Basispruefungen ausgefuehrt.
    .PARAMETER Provider
        Zu pruefender Provider. Standard ist docker.
    .PARAMETER TargetPath
        Optionaler Zielpfad fuer Storage- und Pfadsicherheitspruefungen.
    .PARAMETER RepositoryRoot
        Optionales Repository-Stammverzeichnis. Wird zur Bewertung verwendet,
        ob TargetPath gefaehrlich innerhalb des Quellrepositorys liegt.
    .OUTPUTS
        System.Management.Automation.PSCustomObject. Liefert Status, Timestamp
        und Details pro Pruefkategorie.
    .EXAMPLE
        Test-SqlServerLabPrerequisite -Provider docker

        Prueft Docker sowie die verfuegbaren Hostressourcen ohne Mutation.
    #>
    [CmdletBinding()]
    param(
        [array]$Instances = @(),
        [string]$Provider = 'docker',
        [string]$TargetPath,
        [string]$RepositoryRoot
    )

    $results = @()
    $overallStatus = 'RESOURCE_OK'

    # --- Provider-Verfuegbarkeit ---
    $providerCheck = Test-ProviderAvailability -Provider $Provider
    $results += $providerCheck
    if ($providerCheck.Status -eq 'RESOURCE_HARD_BLOCK') { $overallStatus = 'RESOURCE_HARD_BLOCK' }

    # --- RAM ---
    $ramCheck = Test-RamAvailability -Instances $Instances
    $results += $ramCheck
    if ($ramCheck.Status -eq 'RESOURCE_HARD_BLOCK' -and $overallStatus -ne 'RESOURCE_HARD_BLOCK') {
        $overallStatus = 'RESOURCE_HARD_BLOCK'
    }
    elseif ($ramCheck.Status -eq 'RESOURCE_WARNING' -and $overallStatus -eq 'RESOURCE_OK') {
        $overallStatus = 'RESOURCE_WARNING'
    }

    # --- Storage ---
    $storageCheck = Test-StorageAvailability -Instances $Instances -TargetPath $TargetPath
    $results += $storageCheck
    if ($storageCheck.Status -eq 'RESOURCE_WARNING' -and $overallStatus -eq 'RESOURCE_OK') {
        $overallStatus = 'RESOURCE_WARNING'
    }

    # --- Ports ---
    $portCheck = Test-PortAvailability -Instances $Instances
    $results += $portCheck

    # --- Pfadsicherheit ---
    if ($TargetPath) {
        $pathCheck = Test-PathAvailability -TargetPath $TargetPath -RepositoryRoot $RepositoryRoot
        $results += $pathCheck
        if ($pathCheck.Status -eq 'RESOURCE_HARD_BLOCK') { $overallStatus = 'RESOURCE_HARD_BLOCK' }
    }

    return [PSCustomObject]@{
        Status    = $overallStatus
        Timestamp = Get-LabTimestamp
        Details   = $results
    }
}

# =============================================================================
# Einzelpruefungen
# =============================================================================

function Test-ProviderAvailability {
    [CmdletBinding()]
    param([string]$Provider = 'docker')

    switch ($Provider) {
        'docker' {
            $check = Test-DockerAvailable
            if ($check.Available) {
                return [PSCustomObject]@{
                    Category = 'Provider'
                    Status   = 'RESOURCE_OK'
                    Message  = "Docker verfuegbar (Version: $($check.Version))"
                    Value    = $check.Version
                }
            }
            return [PSCustomObject]@{
                Category = 'Provider'
                Status   = 'RESOURCE_HARD_BLOCK'
                Message  = "Docker nicht verfuegbar: $($check.Message)"
                Value    = $null
            }
        }
        'podman' {
            $check = Test-PodmanAvailable
            if ($check.Available) {
                return [PSCustomObject]@{
                    Category = 'Provider'
                    Status   = 'RESOURCE_OK'
                    Message  = "Podman verfuegbar (Version: $($check.Version))"
                    Value    = $check.Version
                }
            }
            return [PSCustomObject]@{
                Category = 'Provider'
                Status   = 'RESOURCE_HARD_BLOCK'
                Message  = "Podman nicht verfuegbar: $($check.Message)"
                Value    = $null
            }
        }
        default {
            return [PSCustomObject]@{
                Category = 'Provider'
                Status   = 'RESOURCE_HARD_BLOCK'
                Message  = "Provider '$Provider' nicht implementiert."
                Value    = $null
            }
        }
    }
}

function Test-RamAvailability {
    [CmdletBinding()]
    param([array]$Instances = @())

    $requiredMB = 0
    foreach ($inst in $Instances) {
        $resourceProfileName = if ($inst.profile) { $inst.profile } else { 'standard' }
        try {
            $profileDef = Get-LabResourceProfile -Name $resourceProfileName
            $requiredMB += $profileDef.maxMemoryMB
        } catch {
            $requiredMB += 4096  # Default
        }
    }
    if ($requiredMB -eq 0) { $requiredMB = 4096 }

    # Freien RAM ermitteln
    $freeMB = 0
    try {
        if ($IsWindows) {
            $os = Get-CimInstance Win32_OperatingSystem
            $freeMB = [math]::Round($os.FreePhysicalMemory / 1024)
        } else {
            $memInfo = Get-Content '/proc/meminfo' -ErrorAction SilentlyContinue
            $available = $memInfo | Where-Object { $_ -match '^MemAvailable:\s+(\d+)' }
            if ($available -and $Matches[1]) { $freeMB = [math]::Round([int]$Matches[1] / 1024) }
        }
    } catch { $freeMB = 0 }

    if ($freeMB -eq 0) {
        return [PSCustomObject]@{ Category = 'RAM'; Status = 'RESOURCE_WARNING'; Message = "RAM konnte nicht ermittelt werden."; Value = '?' }
    }

    $ratio = $freeMB / $requiredMB
    $status = if ($ratio -lt 1.0) { 'RESOURCE_INSUFFICIENT_OVERRIDABLE' }
              elseif ($ratio -lt 1.2) { 'RESOURCE_WARNING' }
              else { 'RESOURCE_OK' }

    return [PSCustomObject]@{
        Category = 'RAM'
        Status   = $status
        Message  = "Frei: ${freeMB}MB, Benoetigt: ${requiredMB}MB (Ratio: $([math]::Round($ratio, 2)))"
        Value    = @{ FreeMB = $freeMB; RequiredMB = $requiredMB; Ratio = [math]::Round($ratio, 2) }
    }
}

function Test-StorageAvailability {
    [CmdletBinding()]
    param(
        [array]$Instances = @(),
        [string]$TargetPath
    )

    # Geschaetzter Bedarf: 2GB pro Instanz (Image + Data)
    $requiredGB = [math]::Max($Instances.Count * 2, 2)

    $freeGB = 0
    try {
        if ($IsWindows) {
            $drive = if ($TargetPath) { (Split-Path $TargetPath -Qualifier) } else { $env:SystemDrive }
            $disk = Get-PSDrive ($drive.TrimEnd(':')) -ErrorAction SilentlyContinue
            if ($disk) { $freeGB = [math]::Round($disk.Free / 1GB, 1) }
        } else {
            $dfOutput = df -BG / 2>$null | Select-Object -Last 1
            if ($dfOutput -match '(\d+)G\s+(\d+)G\s+(\d+)G') { $freeGB = [int]$Matches[3] }
        }
    } catch { }

    if ($freeGB -eq 0) {
        return [PSCustomObject]@{ Category = 'Storage'; Status = 'RESOURCE_WARNING'; Message = 'Storage konnte nicht ermittelt werden.'; Value = '?' }
    }

    $status = if ($freeGB -lt $requiredGB) { 'RESOURCE_WARNING' } else { 'RESOURCE_OK' }

    return [PSCustomObject]@{
        Category = 'Storage'
        Status   = $status
        Message  = "Frei: ${freeGB}GB, Geschaetzt benoetigt: ${requiredGB}GB"
        Value    = @{ FreeGB = $freeGB; RequiredGB = $requiredGB }
    }
}

function Test-PortAvailability {
    [CmdletBinding()]
    param([array]$Instances = @())

    $portsNeeded = $Instances.Count
    if ($portsNeeded -eq 0) { $portsNeeded = 1 }

    # Verfuegbare Ports im Lab-Bereich zaehlen
    $available = 0
    for ($port = 14330; $port -le 14399; $port++) {
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
            $listener.Start()
            $listener.Stop()
            $available++
            if ($available -ge $portsNeeded) { break }
        } catch { }
    }

    $status = if ($available -ge $portsNeeded) { 'RESOURCE_OK' } else { 'RESOURCE_HARD_BLOCK' }

    return [PSCustomObject]@{
        Category = 'Ports'
        Status   = $status
        Message  = "Verfuegbar: $available, Benoetigt: $portsNeeded (Bereich 14330-14399)"
        Value    = @{ Available = $available; Required = $portsNeeded }
    }
}

function Test-PathAvailability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$RepositoryRoot
    )

    $check = Test-PathSafe -Path $TargetPath -RepositoryRoot $RepositoryRoot

    if ($check.Valid) {
        return [PSCustomObject]@{ Category = 'Pfad'; Status = 'RESOURCE_OK'; Message = "Pfad sicher: $TargetPath"; Value = $TargetPath }
    }

    return [PSCustomObject]@{ Category = 'Pfad'; Status = 'RESOURCE_HARD_BLOCK'; Message = $check.Reason; Value = $TargetPath }
}
