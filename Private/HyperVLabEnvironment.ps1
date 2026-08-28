<#
.SYNOPSIS
    Erstellt und verwaltet reguläre Hyper-V-Lab-VMs aus Windows- oder SQL-Images.
.DESCRIPTION
    Ein regulärer Run verwendet ein registriertes, unveränderliches OS_SEALED-
    oder SQL_PREPARED_SEALED-Image als Parent. Reine Windows-Labs sind ein
    eigenständiger Workload: Sie erhalten weder SQL CompleteImage noch WMI-/
    TCP-Konfiguration. SQL-Labs führen diese Schritte erst im Run-Child aus.
#>

function Get-HyperVLabWorkflowRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ([string]$run.metadata.workflowKind -ne 'hyperv-lab') {
        throw 'HYPERV_LAB_WORKFLOW_RUN_NOT_FOUND'
    }
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) {
        throw 'HYPERV_LAB_CONNECTION_INFO_NOT_FOUND'
    }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    $instance = @($connection.instances | Where-Object { $_.provider -eq 'hyperv' }) | Select-Object -First 1
    if (-not $instance -or -not $instance.vmName) { throw 'HYPERV_LAB_CONNECTION_INFO_INVALID' }

    # Ältere oder manuell umbenannte VMs können einen inzwischen veralteten
    # connection-info-Namen besitzen. Die signierte Lab-Identity in den VM-
    # Notes ist dafür die maßgebliche Zuordnung, nicht der Anzeigename.
    $matchingVm = @(
        Get-HyperVLabVMs -RunId ([string]$run.runId) -ScopeId ([string]$run.scopeId)
    )
    if ($matchingVm.Count -eq 1 -and [string]$matchingVm[0].VMName -ne [string]$instance.vmName) {
        $instance | Add-Member -NotePropertyName vmName -NotePropertyValue ([string]$matchingVm[0].VMName) -Force
        $instance | Add-Member -NotePropertyName vmId -NotePropertyValue ([string]$matchingVm[0].VMId) -Force
        Write-LabArtifactJsonAtomic -Path $connectionPath -InputObject $connection
    }
    return [PSCustomObject]@{ Run = $run; RunDirectory = $runDirectory; Connection = $connection; Instance = $instance; StateRoot = $StateRoot }
}

function Get-HyperVLabRuntimeName {
    <# Liefert den menschenlesbaren und zugleich eindeutigen Hyper-V-Namen. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$')][string]$LabName,
        [Parameter(Mandatory)][string]$RunId
    )

    $runPrefix = $RunId.Replace('-', '').Substring(0, 8).ToLowerInvariant()
    return "$(($LabName.Trim()))-$runPrefix"
}

function Set-HyperVLabAutoStart {
    <# Setzt den nativen VM-Autostart und den persistierten Labvertrag gemeinsam. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('on','off')][string]$AutoStart,
        [string]$StateRoot
    )

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if (-not $managed) { throw 'HYPERV_LAB_VM_NOT_FOUND' }
    $automaticStartAction = if ($AutoStart -eq 'on') { 'Start' } else { 'Nothing' }
    $null = Set-VM -VM $managed.VM -AutomaticStartAction $automaticStartAction -ErrorAction Stop

    $lab.Instance | Add-Member -NotePropertyName autostart -NotePropertyValue $AutoStart -Force
    $lab.Run.metadata | Add-Member -NotePropertyName autostart -NotePropertyValue $AutoStart -Force
    $lab.Run.updatedAt = Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'run-state.json') -InputObject $lab.Run
    return [PSCustomObject]@{ RunId=$RunId; VMName=[string]$lab.Instance.vmName; AutoStart=$AutoStart; AutomaticStartAction=$automaticStartAction }
}

function Get-HyperVExistingVmLabSource {
    <#
    .SYNOPSIS
        Liefert sichere Ausgangs-VMs fuer einen differenzierenden Schnellstart.
    .DESCRIPTION
        Es werden ausschliesslich ausgeschaltete, nicht von SQL_Server_Lab
        verwaltete Generation-2-VMs mit genau einer System-VHDX angeboten.
        Die Quelle wird niemals veraendert; beim Erstellen wird sie in eine
        run-lokale, schreibgeschuetzte Arbeitskopie konvertiert.
    #>
    [CmdletBinding()]
    param()

    $availability = Test-HyperVAvailable
    if (-not $availability.Available) { return @() }

    $candidates = @()
    foreach ($vm in @(Get-VM -ErrorAction Stop | Sort-Object Name)) {
        if ([string]$vm.State -ne 'Off' -or [int]$vm.Generation -ne 2) { continue }
        if (ConvertFrom-HyperVLabNotes -Notes ([string]$vm.Notes)) { continue }

        $disks = @(Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction Stop |
            Where-Object { $_.Path -and ([IO.Path]::GetExtension([string]$_.Path) -ieq '.vhdx') })
        # Mehrere Disks lassen nicht verlaesslich erkennen, welche Startdisk ist.
        if ($disks.Count -ne 1) { continue }
        $sourcePath = [IO.Path]::GetFullPath([string]$disks[0].Path)
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { continue }
        $vhd = Get-VHD -Path $sourcePath -ErrorAction Stop
        $looksLikeDeveloperVm = [string]$vm.Name -match '(?i)(windows\s*11|developer|dev\s*environment|quick\s*create)'
        $candidates += [PSCustomObject]@{
            VMName = [string]$vm.Name
            SourceVhdxPath = $sourcePath
            Generation = [int]$vm.Generation
            MemoryStartupMB = [int]($vm.MemoryStartup / 1MB)
            ProcessorCount = [int]$vm.ProcessorCount
            SourceDiskType = [string]$vhd.VhdType
            IsDeveloperEnvironment = $looksLikeDeveloperVm
            LicenseNotice = if ($looksLikeDeveloperVm) {
                'Entwicklungs-/Evaluierungsumgebung erkannt: Ablauf und Lizenzstatus vor dem Start in Windows pruefen.'
            } else {
                'Lizenz- und Ablaufstatus der Quell-VM vor dem Start in Windows pruefen.'
            }
        }
    }
    return @($candidates)
}

function New-HyperVLabEnvironmentFromExistingVm {
    <#
    .SYNOPSIS
        Erstellt eine neue Lab-VM aus einer vorhandenen Hyper-V-Quell-VM.
    .DESCRIPTION
        Die Quell-VM und ihre VHDX bleiben unveraendert. Stattdessen wird die
        ausgeschaltete Quell-VHDX zu einer run-lokalen Arbeitskopie konvertiert,
        schreibgeschuetzt und nur diese Kopie als Parent der Child-VHDX verwendet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SourceVMName,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$')][string]$LabName,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')][string]$InstanceId,
        [ValidateRange(512, 1048576)][int]$MemoryStartupMB = 4096,
        [ValidateRange(1, 64)][int]$ProcessorCount = 4,
        [ValidateSet('on', 'off')][string]$AutoStart = 'off',
        [string]$SwitchName,
        [switch]$Isolated,
        [switch]$ConfirmSourceLicense,
        [string]$StateRoot
    )

    if (-not $ConfirmSourceLicense) { throw 'HYPERV_EXISTING_VM_LICENSE_CONFIRMATION_REQUIRED' }
    Write-LabInfo 'Schritt 1/6: Sichere, ausgeschaltete Quell-VM wird geprueft.'
    $availability = Test-HyperVAvailable
    if (-not $availability.Available) { throw "HYPERV_WORKFLOW_UNAVAILABLE: $($availability.Message)" }
    $source = @(Get-HyperVExistingVmLabSource | Where-Object { $_.VMName -eq $SourceVMName }) | Select-Object -First 1
    if (-not $source) { throw 'HYPERV_EXISTING_VM_SOURCE_NOT_ELIGIBLE' }
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $labNetwork = Resolve-LabHyperVNetwork -SwitchName $SwitchName -Isolated:$Isolated

    Write-LabInfo 'Schritt 2/6: Workflow-Run und Cleanup-Plan werden angelegt.'
    $run = New-LabRunState -StateRoot $StateRoot -Metadata @{
        name = $LabName; workflowKind = 'hyperv-lab'; baseKind = 'existing-vm'; workload = 'windows'; autostart = $AutoStart
        sourceVMName = $source.VMName; sourceVhdxPath = $source.SourceVhdxPath
        sourceLicenseNotice = $source.LicenseNotice
        network = if ($labNetwork) { $labNetwork.Name } else { $null }
    } -ProviderSubRuns @([PSCustomObject]@{ id = 'provider-hyperv'; provider = 'hyperv'; instanceIds = @($InstanceId) })
    try {
        $null = New-CleanupPlan -RunDir $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId -ProviderSubRuns @([PSCustomObject]@{ id = 'provider-hyperv'; provider = 'hyperv'; instanceIds = @($InstanceId) })
        $null = Set-LabRunState -RunId $run.RunId -NewState PROVISIONING -Reason 'Hyper-V-Lab wird aus einer vorhandenen VM abgeleitet.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState PROVISIONING -Reason 'Quell-VM wird unveraendert als Basis kopiert.' -StateRoot $run.StateRoot

        $resourceRoot = Join-Path (Join-Path $run.RunDir 'resources') 'hyperv'
        $parentCopyPath = Join-Path $resourceRoot "$InstanceId-source-parent.vhdx"
        if (-not (Test-HyperVPathWithinRunDirectory -Path $parentCopyPath -RunDirectory $run.RunDir)) { throw 'HYPERV_RESOURCE_SCOPE_VIOLATION' }
        $null = Add-CleanupStep -RunDir $run.RunDir -ResourceType 'vhdx' -ResourceId $parentCopyPath -Action 'remove' -Provider 'hyperv' -ProviderSubRunId 'provider-hyperv' -Compensation "Remove protected source-parent copy for $InstanceId"
        $null = New-Item -ItemType Directory -Path $resourceRoot -Force
        Write-LabInfo 'Schritt 3/6: Quell-VHDX wird als eigene Arbeitskopie konvertiert; die Original-VM bleibt unveraendert.'
        Convert-VHD -Path $source.SourceVhdxPath -DestinationPath $parentCopyPath -VHDType Dynamic -ErrorAction Stop
        $parentItem = Get-Item -LiteralPath $parentCopyPath -Force
        $parentItem.IsReadOnly = $true
        $parentHash = (Get-FileHash -LiteralPath $parentCopyPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()

        Write-LabInfo 'Schritt 4/6: Differenzierende Lab-VM wird aus der geschuetzten Arbeitskopie erstellt.'
        $vm = New-HyperVInstance -ParentVhdxPath $parentCopyPath -ParentSha256 $parentHash -RunDirectory $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId -InstanceId $InstanceId -LabName $LabName -MemoryStartupBytes ($MemoryStartupMB * 1MB) -ProcessorCount $ProcessorCount -AutoStart $AutoStart -SwitchName $(if ($labNetwork) { $labNetwork.Name } else { $null })
        $connection = [PSCustomObject]@{
            schemaVersion = 1; instances = @([PSCustomObject]@{
                id = $InstanceId; provider = 'hyperv'; vmName = $vm.VMName; vmId = $vm.VMId; autostart = $AutoStart
                sqlVersion = $null; sqlEdition = $null; imageArtifactId = $null; host = $null; port = $null
                labNetwork = if ($labNetwork) { [PSCustomObject]@{ name = $labNetwork.Name; subnet = $labNetwork.Subnet; prefixLength = $labNetwork.PrefixLength; hostAddress = $labNetwork.HostAddress } } else { $null }
                baseKind = 'existing-vm'; workload = 'windows'; sourceVMName = $source.VMName; sourceVhdxPath = $source.SourceVhdxPath
                sourceParentCopyPath = $parentCopyPath; sourceParentSha256 = $parentHash
            })
        }
        Write-LabInfo 'Schritt 5/6: Verbindungsdaten und sichere Ressourcenbindung werden gespeichert.'
        Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'connection-info.json') -InputObject $connection
        # Der technische State SQL_READY ist im gemeinsamen Lifecycle der
        # nächste zulässige Zustand; workload=windows verhindert, dass die UI
        # daraus eine SQL-Aktion ableitet.
        $null = Set-LabRunState -RunId $run.RunId -NewState SQL_READY -Reason 'Windows-Quell-VM als unveraenderte Basis gebunden.' -StateRoot $run.StateRoot
        $null = Set-LabRunState -RunId $run.RunId -NewState DATABASES_CREATED -Reason 'Keine run-lokalen Datenbanken angefordert.' -StateRoot $run.StateRoot
        $null = Set-LabRunState -RunId $run.RunId -NewState RUNNING -Reason 'Hyper-V-VM erstellt, noch ausgeschaltet.' -StateRoot $run.StateRoot
        $null = Set-LabRunState -RunId $run.RunId -NewState STOPPED -Reason 'Warte auf sichtbaren VM-Start.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState SQL_READY -Reason 'Windows-Quell-VM als unveraenderte Basis gebunden.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState DATABASES_CREATED -Reason 'Keine run-lokalen Datenbanken angefordert.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState RUNNING -Reason 'Hyper-V-VM erstellt, noch ausgeschaltet.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState STOPPED -Reason 'Warte auf sichtbaren VM-Start.' -StateRoot $run.StateRoot
        Write-LabSuccess "Schritt 6/6: VM $($vm.VMName) ist erstellt; die Quell-VM '$($source.VMName)' blieb unveraendert."
        return [PSCustomObject]@{ RunId = $run.RunId; ScopeId = $run.ScopeId; VMName = $vm.VMName; State = 'STOPPED'; AutoStart = $AutoStart; SourceVMName = $source.VMName }
    }
    catch {
        try {
            $current = Get-LabRunState -RunId $run.RunId -StateRoot $run.StateRoot
            if ([string]$current.state -notin @('CLEANUP_PENDING', 'CLEANUP_RUNNING', 'CLEANED_UP', 'REMOVED')) {
                $null = Set-LabRunState -RunId $run.RunId -NewState CLEANUP_PENDING -Reason 'Hyper-V-Lab-Erstellung aus vorhandener VM fehlgeschlagen.' -StateRoot $run.StateRoot
            }
        }
        catch { }
        throw
    }
}

function New-HyperVLabEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArtifactId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$')][string]$LabName,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')][string]$InstanceId,
        [ValidateRange(512, 1048576)][int]$MemoryStartupMB = 4096,
        [ValidateRange(1, 64)][int]$ProcessorCount = 4,
        [ValidateSet('on', 'off')][string]$AutoStart = 'off',
        [string]$SwitchName,
        [switch]$Isolated,
        [object[]]$AdditionalDrives = @(),
        $StorageIntent,
        $DesiredState,
        [string]$StateRoot
    )

    Write-LabInfo 'Schritt 1/5: Hyper-V-Verfügbarkeit und veröffentlichte Windows-/SQL-Vorlage werden geprüft.'
    $availability = Test-HyperVAvailable
    if (-not $availability.Available) { throw "HYPERV_WORKFLOW_UNAVAILABLE: $($availability.Message)" }
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $artifact = Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot
    if (-not $artifact) { throw 'HYPERV_LAB_ARTIFACT_NOT_FOUND' }
    $artifactState = [string]$artifact.artifactState
    if ($artifactState -notin @('SQL_PREPARED_SEALED', 'OS_SEALED')) {
        throw 'HYPERV_LAB_WINDOWS_OR_SQL_PREPARED_IMAGE_REQUIRED'
    }
    $workload = if ($artifactState -eq 'SQL_PREPARED_SEALED') { 'sql' } else { 'windows' }
    $baseKind = if ($workload -eq 'sql') { 'sql-prepared' } else { 'windows-baseline' }
    if ($StorageIntent) {
        if ($workload -ne 'sql') { throw 'HYPERV_STORAGE_INTENT_SQL_PREPARED_IMAGE_REQUIRED' }
        if (@($AdditionalDrives).Count -gt 0) { throw 'HYPERV_STORAGE_INTENT_ADDITIONAL_DRIVE_CONFLICT' }
        $storagePreflight = New-LabStorageBoundPlan -StorageIntent $StorageIntent -RunId ([Guid]::NewGuid().ToString('D')) `
            -LabName $LabName -InstanceId $InstanceId -Provider hyperv
        if ([string]$storagePreflight.Status -ne 'READY') {
            throw "HYPERV_STORAGE_INTENT_BINDING_BLOCKED: $(@($storagePreflight.Blockers) -join ', ')"
        }
    }
    $labNetwork = Resolve-LabHyperVNetwork -SwitchName $SwitchName -Isolated:$Isolated

    Write-LabInfo 'Schritt 2/5: Workflow-Run und rückgängig ausführbarer Cleanup-Plan werden angelegt.'
    $runMetadata = @{
        name = $LabName; workflowKind = 'hyperv-lab'; imageArtifactId = $ArtifactId; workload = $workload; baseKind = $baseKind; autostart = $AutoStart
        network = if ($labNetwork) { $labNetwork.Name } else { $null }
        desiredState = $DesiredState
    }
    $workflowOperationId = Get-LabWorkflowOperationContext
    if (-not [string]::IsNullOrWhiteSpace($workflowOperationId)) {
        $runMetadata['workflowOperationId'] = $workflowOperationId
    }
    $run = New-LabRunState -StateRoot $StateRoot -Metadata $runMetadata `
        -ProviderSubRuns @([PSCustomObject]@{ id = 'provider-hyperv'; provider = 'hyperv'; instanceIds = @($InstanceId) })
    try {
        $null = New-CleanupPlan -RunDir $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId -ProviderSubRuns @([PSCustomObject]@{ id = 'provider-hyperv'; provider = 'hyperv'; instanceIds = @($InstanceId) })
        $storageBoundPlan = $null
        if ($StorageIntent) {
            $storageBoundPlan = New-LabStorageBoundPlan -StorageIntent $StorageIntent -RunId $run.RunId `
                -LabName $LabName -InstanceId $InstanceId -Provider hyperv
            if ([string]$storageBoundPlan.Status -ne 'READY') {
                throw "HYPERV_STORAGE_INTENT_BINDING_BLOCKED: $(@($storageBoundPlan.Blockers) -join ', ')"
            }
            $AdditionalDrives = @(ConvertTo-LabHyperVStorageDrivePlan -Plan $storageBoundPlan)
            $null = Assert-LabStorageBoundPlan -Plan $storageBoundPlan
            Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'storage-bound-plan.json') -InputObject $storageBoundPlan
        }
        $sourceDescription = if ($workload -eq 'sql') { 'SQL-Prepared-Image' } else { 'Windows-OS-Baseline' }
        $null = Set-LabRunState -RunId $run.RunId -NewState PROVISIONING -Reason "Hyper-V-Lab wird aus $sourceDescription erstellt." -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState PROVISIONING -Reason "Hyper-V-Lab wird aus $sourceDescription erstellt." -StateRoot $run.StateRoot
        Write-LabInfo "Schritt 3/5: Differenzierende VM wird aus Image $ArtifactId erstellt."
        $vm = New-HyperVInstance -ImageArtifactId $ArtifactId -RunDirectory $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId -InstanceId $InstanceId -LabName $LabName -MemoryStartupBytes ($MemoryStartupMB * 1MB) -ProcessorCount $ProcessorCount -AutoStart $AutoStart -SwitchName $(if ($labNetwork) { $labNetwork.Name } else { $null }) -AdditionalDrives $AdditionalDrives -StateRoot $run.StateRoot
        $connection = [PSCustomObject]@{
            schemaVersion = 1; instances = @([PSCustomObject]@{
                id = $InstanceId; provider = 'hyperv'; vmName = $vm.VMName; vmId = $vm.VMId; autostart = $AutoStart
                sqlVersion = if ($workload -eq 'sql') { [string]$artifact.sql.version } else { $null }
                sqlEdition = if ($workload -eq 'sql') { [string]$artifact.sql.edition } else { $null }
                workload = $workload; baseKind = $baseKind; imageArtifactId = $ArtifactId; host = $null; port = $null
                labNetwork = if ($labNetwork) { [PSCustomObject]@{ name = $labNetwork.Name; subnet = $labNetwork.Subnet; prefixLength = $labNetwork.PrefixLength; hostAddress = $labNetwork.HostAddress } } else { $null }
                storageBoundPlan = if ($storageBoundPlan) { [PSCustomObject]@{ planId=[string]$storageBoundPlan.PlanId; status='READY_TO_APPLY'; artifact='storage-bound-plan.json' } } else { $null }
                additionalDrives = @($vm.AdditionalDrives | ForEach-Object {
                    [PSCustomObject]@{
                        id = [string]$_.Id; role = [string]$_.Role; sizeBytes = [long]$_.SizeBytes
                        vhdType = [string]$_.VhdType; diskIdentifier = [string]$_.DiskIdentifier
                        guestPath = [string]$_.GuestPath; allocationUnitKB = [int]$_.AllocationUnitKB
                        volumeLabel = [string]$_.VolumeLabel; maximumIops = [long]$_.MaximumIops
                        locationId = [string]$_.LocationId; selector = [string]$_.Selector
                        state = 'ATTACHED_PENDING_INITIALIZATION'
                    }
                })
            })
        }
        Write-LabInfo 'Schritt 4/5: Verbindungsdaten und Ressourcenbindung werden gespeichert.'
        Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'connection-info.json') -InputObject $connection
        # Der gemeinsame State-Machine-Vertrag enthält noch keinen WINDOWS_READY-
        # Zustand. workload=windows ist daher maßgeblich für die Darstellung,
        # während SQL_READY nur die zulässige technische Transition markiert.
        $readyReason = if ($workload -eq 'sql') { 'SQL-Prepared-Image gebunden.' } else { 'Windows-OS-Baseline gebunden.' }
        $null = Set-LabRunState -RunId $run.RunId -NewState SQL_READY -Reason $readyReason -StateRoot $run.StateRoot
        $null = Set-LabRunState -RunId $run.RunId -NewState DATABASES_CREATED -Reason 'Keine run-lokalen Datenbanken angefordert.' -StateRoot $run.StateRoot
        $null = Set-LabRunState -RunId $run.RunId -NewState RUNNING -Reason 'Hyper-V-VM erstellt, noch ausgeschaltet.' -StateRoot $run.StateRoot
        $null = Set-LabRunState -RunId $run.RunId -NewState STOPPED -Reason 'Warte auf sichtbaren VM-Start.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState SQL_READY -Reason $readyReason -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState DATABASES_CREATED -Reason 'Keine run-lokalen Datenbanken angefordert.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState RUNNING -Reason 'Hyper-V-VM erstellt, noch ausgeschaltet.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState STOPPED -Reason 'Warte auf sichtbaren VM-Start.' -StateRoot $run.StateRoot
        Write-LabSuccess "Schritt 5/5: $workload-VM $($vm.VMName) ist erstellt und bewusst ausgeschaltet."
        return [PSCustomObject]@{ RunId = $run.RunId; ScopeId = $run.ScopeId; VMName = $vm.VMName; State = 'STOPPED'; AutoStart = $AutoStart; ArtifactId = $ArtifactId; Workload = $workload }
    }
    catch {
        try {
            $current = Get-LabRunState -RunId $run.RunId -StateRoot $run.StateRoot
            if ([string]$current.state -notin @('CLEANUP_PENDING', 'CLEANUP_RUNNING', 'CLEANED_UP', 'REMOVED')) {
                $null = Set-LabRunState -RunId $run.RunId -NewState CLEANUP_PENDING -Reason 'Hyper-V-Lab-Erstellung fehlgeschlagen.' -StateRoot $run.StateRoot
            }
        }
        catch { }
        throw
    }
}

function Resolve-HyperVLocaleGeoId {
    [CmdletBinding()]
    param(
        [string]$Region
    )

    if ([string]::IsNullOrWhiteSpace($Region)) { throw 'HYPERV_LAB_REGION_REQUIRED' }

    $normalized = $Region.Trim().Replace('_', '-').ToUpperInvariant()
    $territory = if ($normalized -match '^[A-Z]{2}-([A-Z]{2})$') {
        $Matches[1]
    }
    elseif ($normalized -match '^[A-Z]{2}$') {
        $normalized
    }
    else {
        throw "HYPERV_LAB_REGION_INVALID: $Region"
    }

    try {
        $regionInfo = [System.Globalization.RegionInfo]::new($territory)
        if ($regionInfo.GeoId -le 0) { throw 'GeoId unavailable' }
        return [int]$regionInfo.GeoId
    }
    catch {
        throw "HYPERV_LAB_REGION_UNSUPPORTED: $Region"
    }
}

function Get-HyperVUnattendedLocaleSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][string]$SystemLocale,
        [Parameter(Mandatory)][string]$UiLanguage,
        [Parameter(Mandatory)][string]$InputLocale,
        [Parameter(Mandatory)][string]$TimeZone
    )

    return [PSCustomObject]@{
        Region = $Region
        GeoId = Resolve-HyperVLocaleGeoId -Region $Region
        SystemLocale = $SystemLocale
        UiLanguage = $UiLanguage
        InputLocale = $InputLocale
        TimeZone = $TimeZone
    }
}

function Get-HyperVUnattendedPostLoginScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$GeoId,
        [Parameter(Mandatory)][string]$SystemLocale,
        [Parameter(Mandatory)][string]$UiLanguage,
        [Parameter(Mandatory)][string]$InputLocale,
        [Parameter(Mandatory)][string]$TimeZone
    )

    return {
        param(
            $ExpectedRunId,
            [int]$GeoId,
            $SystemLocale,
            $UiLanguage,
            $InputLocale,
            $TimeZone
        )
        $ErrorActionPreference = 'Stop'
        Set-WinHomeLocation -GeoId $GeoId
        Set-WinSystemLocale -SystemLocale $SystemLocale
        Set-Culture -CultureInfo $SystemLocale
        Set-WinUILanguageOverride -Language $UiLanguage
        Set-WinDefaultInputMethodOverride -InputTip $InputLocale
        Set-TimeZone -Id $TimeZone
        Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend.xml" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend\Unattend.xml" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$env:WINDIR\Setup\Scripts\SetupComplete.cmd" -Force -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            runId = $ExpectedRunId
            computerName = [Environment]::MachineName
            imageState = [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState)
            geoId = [int](Get-WinHomeLocation).GeoId
            systemLocale = [string](Get-WinSystemLocale)
            uiLanguage = [string](Get-WinUILanguageOverride)
            inputLocale = [string](Get-WinDefaultInputMethodOverride).InputMethodTip
            timeZone = [string](Get-TimeZone).Id
            observedAt = [datetime]::UtcNow.ToString('o')
        }
    }.GetNewClosure()
}

function New-HyperVTransientGeneratedSqlAccess {
    [CmdletBinding()]
    param(
        $HostSqlAccess,
        [Parameter(Mandatory)][SecureString]$SqlSaPassword,
        [switch]$Generated,
        [switch]$Persisted
    )

    if (-not $Generated) { return $null }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlSaPassword)
    try {
        $plainTextPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $connectionString = if ($HostSqlAccess -and $HostSqlAccess.ConnectionString) {
            $escapedPassword = $plainTextPassword.Replace('"', '""')
            $template = [string]$HostSqlAccess.ConnectionString
            $placeholder = [regex]::Match($template, 'Password=<[^;]+>;')
            if ($placeholder.Success) {
                $template.Remove($placeholder.Index, $placeholder.Length).Insert(
                    $placeholder.Index,
                    "Password=`"$escapedPassword`";"
                )
            }
            else { $null }
        } else { $null }
        return [PSCustomObject]@{
            transient = -not $Persisted
            generated = $true
            userName = 'sa'
            password = $plainTextPassword
            connectionString = $connectionString
            notice = if ($Persisted) {
                'DPAPI-geschützt im Run-Secret-Store gespeichert; explizit über Get-SqlServerLabGeneratedSqlAccess abrufbar.'
            }
            else {
                'Nur im unmittelbaren Aufrufergebnis vorhanden; nicht im Run-State oder connection-info.json gespeichert.'
            }
        }
    }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Invoke-HyperVLabUnattendedProvision {
    <#
    .SYNOPSIS
        Startet einen Prepared-Image-Klon ohne interaktive Windows-OOBE.
    .DESCRIPTION
        Die Antwortdatei wird ausschließlich in die differenzierende Child-VHDX
        des konkreten Runs injiziert. Das immutable Prepared-Image erhält weder
        Kennwort noch Gastkonfiguration. Das Kennwort liegt nur DPAPI-geschützt
        im Run und die Antwortdatei wird nach der erfolgreichen OOBE entfernt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][SecureString]$AdministratorPassword,
        [SecureString]$SqlSaPassword,
        [ValidateSet('user', 'generated')][string]$PasswordSource = 'user',
        [ValidateRange(60, 3600)][int]$TimeoutSeconds = 900,
        [ValidatePattern('^[A-Za-z]{2}(-[A-Za-z]{2})?$')][string]$Region = 'DE',
        [ValidatePattern('^[A-Za-z]{2}-[A-Za-z]{2}$')][string]$SystemLocale = 'de-DE',
        [ValidatePattern('^[A-Za-z]{2}-[A-Za-z]{2}$')][string]$UiLanguage = 'en-US',
        [ValidatePattern('^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{8}$')][string]$InputLocale = '0407:00000407',
        [string]$TimeZone = 'W. Europe Standard Time',
        [string]$MediaRoot,
        [string]$StateRoot
    )

    Write-LabInfo 'Schritt 1/6: Klon-Vorlage und isolierte Child-VHDX werden geprüft.'
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    if (-not $lab.Instance.imageArtifactId) { throw 'HYPERV_LAB_UNATTENDED_REQUIRES_IMAGE_ARTIFACT' }
    $windowsOnly = [string]$lab.Instance.workload -eq 'windows'
    if ($lab.Instance.oobeAutomation -and [string]$lab.Instance.oobeAutomation.status -eq 'COMPLETED') {
        throw 'HYPERV_LAB_UNATTENDED_ALREADY_COMPLETED'
    }
    $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if (-not $managed -or [string]$managed.VM.State -ne 'Off') { throw 'HYPERV_LAB_UNATTENDED_VM_MUST_BE_OFF' }
    $vhdxPath = [string]$managed.Identity.childVhdxPath
    if (-not $vhdxPath -or -not (Test-Path -LiteralPath $vhdxPath -PathType Leaf)) { throw 'HYPERV_LAB_UNATTENDED_CHILD_VHDX_NOT_FOUND' }

    Write-LabInfo 'Schritt 2/6: Gastpasswort wird nur für diesen Run DPAPI-geschützt abgelegt.'
    Save-LabSecret -Path $lab.RunDirectory -Name 'guest-administrator-password' -Secret $AdministratorPassword
    $credential = [PSCredential]::new('Administrator', $AdministratorPassword)
    $unattend = $null; $bootstrap = $null; $fallbackAddress = $null
    $localeSettings = Get-HyperVUnattendedLocaleSettings -Region $Region -SystemLocale $SystemLocale -UiLanguage $UiLanguage -InputLocale $InputLocale -TimeZone $TimeZone
    $postLoginScript = Get-HyperVUnattendedPostLoginScript -GeoId $localeSettings.GeoId -SystemLocale $localeSettings.SystemLocale -UiLanguage $localeSettings.UiLanguage -InputLocale $localeSettings.InputLocale -TimeZone $localeSettings.TimeZone
    try {
        if ($lab.Instance.labNetwork) {
            $fallbackAddress = Get-LabNetworkGuestAddress -Network $lab.Instance.labNetwork -Identity $lab.Run.runId
            $bootstrap = New-HyperVSqlGuestNetworkBootstrapScript -Network $lab.Instance.labNetwork -Address $fallbackAddress
        }
        $unattend = New-HyperVSqlOobeUnattendXml -AdministratorPassword $AdministratorPassword `
            -Network $lab.Instance.labNetwork -Identity $lab.Run.runId `
            -SystemLocale $localeSettings.SystemLocale -UiLanguage $localeSettings.UiLanguage `
            -InputLocale $localeSettings.InputLocale `
            -TimeZone $localeSettings.TimeZone
        Write-LabInfo 'Schritt 3/6: Unattend.xml und – bei Labnetz – der WinRM-Netzwerk-Bootstrap werden ausschließlich in die Child-VHDX injiziert.'
        Set-HyperVSqlOfflineUnattend -VhdxPath $vhdxPath -MountRoot (Join-Path $lab.RunDirectory 'offline-oobe-mount') -UnattendXml $unattend -BootstrapScript $bootstrap
    }
    finally { $unattend = $null }

    $lab.Instance | Add-Member -NotePropertyName oobeAutomation -NotePropertyValue ([PSCustomObject]@{
        status = 'RUNNING'; passwordSource = $PasswordSource; passwordStorage = 'host-dpapi'
        region = $Region; systemLocale = $SystemLocale; uiLanguage = $UiLanguage; inputLocale = $InputLocale; timeZone = $TimeZone
        answerMedia = 'run-child-vhdx'; networkBootstrap = if ($fallbackAddress) { 'lab-winrm-v1' } else { 'none' }
        labAddress = $fallbackAddress; startedAt = Get-LabTimestamp
    }) -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection

    $readinessChannel = if ($fallbackAddress) { "PowerShell Direct oder Lab-WinRM ($fallbackAddress)" } else { 'PowerShell Direct (VM bleibt bewusst isoliert)' }
    Write-LabInfo "Schritt 4/6: VM wird gestartet; OOBE, Sprache, Region und Tastatur laufen unbeaufsichtigt. Readiness: $readinessChannel."
    $null = Start-HyperVLabEnvironment -RunId $RunId -StateRoot $lab.StateRoot
    try {
        $ready = Wait-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId `
            -ExpectedScopeId $lab.Run.scopeId -Credential $credential -FallbackAddress $fallbackAddress `
            -GuestInitializationScript $bootstrap -TimeoutSeconds $TimeoutSeconds
    }
    finally { $bootstrap = $null }
    if (-not $ready.Ready) { throw "HYPERV_LAB_UNATTENDED_OOBE_TIMEOUT: $($ready.Message)" }

    Write-LabInfo 'Schritt 5/6: OOBE-Artefakte werden im Gast entfernt und die regionale Konfiguration wird geprüft.'
    $receipt = Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId `
        -ExpectedScopeId $lab.Run.scopeId -Credential $credential -FallbackAddress $fallbackAddress `
        -ArgumentList @([string]$lab.Run.runId, $localeSettings.GeoId, $localeSettings.SystemLocale, $localeSettings.UiLanguage, $localeSettings.InputLocale, $localeSettings.TimeZone) `
        -ScriptBlock $postLoginScript
    $receipt = @($receipt)[-1]
    $receiptMismatches = [Collections.Generic.List[string]]::new()
    if (-not $receipt) {
        $receiptMismatches.Add('receipt=<null>')
    }
    else {
        foreach ($field in @(
            @{ Name='runId'; Expected=[string]$lab.Run.runId; Actual=[string]$receipt.runId },
            @{ Name='imageState'; Expected='IMAGE_STATE_COMPLETE'; Actual=[string]$receipt.imageState },
            @{ Name='geoId'; Expected=[string]$localeSettings.GeoId; Actual=[string][int]$receipt.geoId },
            @{ Name='systemLocale'; Expected=[string]$localeSettings.SystemLocale; Actual=[string]$receipt.systemLocale },
            @{ Name='uiLanguage'; Expected=[string]$localeSettings.UiLanguage; Actual=[string]$receipt.uiLanguage },
            @{ Name='inputLocale'; Expected=[string]$localeSettings.InputLocale; Actual=[string]$receipt.inputLocale },
            @{ Name='timeZone'; Expected=[string]$localeSettings.TimeZone; Actual=[string]$receipt.timeZone }
        )) {
            if ($field.Actual -ne $field.Expected) {
                $receiptMismatches.Add("$($field.Name): expected='$($field.Expected)', actual='$($field.Actual)'")
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$receipt.computerName)) {
            $receiptMismatches.Add('computerName=<empty>')
        }
    }
    if ($receiptMismatches.Count -gt 0) {
        throw "HYPERV_LAB_UNATTENDED_OOBE_RECEIPT_INVALID: $($receiptMismatches -join '; ')"
    }
    $managedAfterOobe = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    $null = Set-HyperVManagedVMIdentityProperty -ManagedVM $managedAfterOobe `
        -PropertyName windowsSpecialization -ContractVersion '0.5' `
        -Value ([PSCustomObject]@{
            status = 'WINDOWS_SPECIALIZED'
            computerName = [string]$receipt.computerName
            imageState = [string]$receipt.imageState
            rebooted = $false
            source = 'unattended-oobe'
            observedAt = [string]$receipt.observedAt
        })
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $lab.StateRoot
    $lab.Instance | Add-Member -NotePropertyName oobeAutomation -NotePropertyValue ([PSCustomObject]@{
        status = 'COMPLETED'; passwordSource = $PasswordSource; passwordStorage = 'host-dpapi'
        region = $Region; systemLocale = $SystemLocale; uiLanguage = $UiLanguage; inputLocale = $InputLocale; timeZone = $TimeZone
        answerMedia = 'guest-scrubbed'; networkBootstrap = if ($fallbackAddress) { 'lab-winrm-v1' } else { 'none' }
        labAddress = $fallbackAddress; completedAt = [string]$receipt.observedAt
    }) -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection

    $driveReceipt = $null
    if ($lab.Instance.persistentStorage -and [string]$lab.Instance.persistentStorage.state -eq 'ATTACHED_PENDING_INITIALIZATION') {
        Write-LabInfo 'Schritt 6/6a: Eigene Data-Root-VHDX wird im Gast initialisiert.'
        $driveReceipt = Initialize-HyperVLabPersistentData -RunId $RunId -Credential $credential -StateRoot $lab.StateRoot
    }
    else {
        $managedAfterOobe = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
        if (@($managedAfterOobe.Identity.additionalDrives | Where-Object guestPath).Count -gt 0) {
            Write-LabInfo 'Schritt 6/6a: Manifestgebundene Zusatz-VHDX werden im Gast initialisiert.'
            $driveReceipt = Initialize-HyperVWindowsGuestDrives -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $credential
        }
    }
    if ($driveReceipt) {
        $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $lab.StateRoot
        $lab.Instance | Add-Member -NotePropertyName additionalDrives -NotePropertyValue @($driveReceipt.Drives | ForEach-Object {
            [PSCustomObject]@{
                id = [string]$_.id; diskIdentifier = [string]$_.diskIdentifier
                guestPath = [string]$_.guestPath; driveLetter = [string]$_.driveLetter
                fileSystem = [string]$_.fileSystem; allocationUnitKB = [int]$_.allocationUnitKB
                volumeLabel = [string]$_.volumeLabel; status = [string]$_.status
            }
        }) -Force
        Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
    }
    if ($windowsOnly) {
        $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $lab.StateRoot
        $lab.Instance | Add-Member -NotePropertyName windowsProvisioning -NotePropertyValue ([PSCustomObject]@{
            state = 'COMPLETE'; completedAt = Get-LabTimestamp; workload = 'windows-only'
        }) -Force
        Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
        Write-LabSuccess 'Unbeaufsichtigte OOBE für die reine Windows-VM ist abgeschlossen. SQL, WMI und TCP/IP werden nicht konfiguriert.'
        return [PSCustomObject]@{ RunId = $RunId; OobeState = 'COMPLETED'; WindowsOnly = $true; PasswordSource = $PasswordSource }
    }
    # Ein separates SA-Passwort ist bewusst möglich. Ohne Angabe bleibt der
    # frühere, sichere Standard erhalten: SA entspricht dem Gastkonto.
    $sqlSaPasswordWasProvided = $null -ne $SqlSaPassword
    if (-not $SqlSaPassword) { $SqlSaPassword = $AdministratorPassword }
    $generatedSqlPassword = $PasswordSource -eq 'generated' -and -not $sqlSaPasswordWasProvided
    if ($generatedSqlPassword) {
        Save-LabSecret -Path $lab.RunDirectory -Name 'generated-sql-sa-password' -Secret $SqlSaPassword
    }
    Write-LabInfo 'Schritt 6/6b: SQL CompleteImage, WMI-Prüfung sowie TCP/IP-Hostzugriff werden in der laufenden Klon-VM automatisch ausgeführt.'
    $sqlCompletion = Complete-HyperVLabSqlImage -RunId $RunId -Credential $credential -SqlSaPassword $SqlSaPassword -MediaRoot $MediaRoot -StateRoot $lab.StateRoot
    $storageRuntime = $null
    $storagePlanPath = Join-Path $lab.RunDirectory 'storage-bound-plan.json'
    if (Test-Path -LiteralPath $storagePlanPath -PathType Leaf) {
        Write-LabInfo 'SQL-Defaultpfade und TempDB-Dateiplan werden auf die initialisierten Storage-Lanes angewendet und nach Dienstrestart geprüft.'
        $storagePlan = Get-Content -LiteralPath $storagePlanPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
        $storageRuntime = Invoke-HyperVLabStoragePlan -RunId $RunId -Plan $storagePlan -Credential $credential `
            -SqlSaPassword $SqlSaPassword -StateRoot $lab.StateRoot
        $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $lab.StateRoot
        $lab.Instance.storageBoundPlan.status = 'VERIFIED'
        $lab.Instance | Add-Member -NotePropertyName storageRuntime -NotePropertyValue ([PSCustomObject]@{
            status=[string]$storageRuntime.Status; planId=[string]$storageRuntime.PlanId; artifact='storage-runtime-receipt.json'
        }) -Force
        Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
    }
    $hostAccess = if ($sqlCompletion.PSObject.Properties['hostSqlAccess']) { $sqlCompletion.hostSqlAccess } else { $null }
    $generatedSqlAccess = New-HyperVTransientGeneratedSqlAccess -HostSqlAccess $hostAccess -SqlSaPassword $SqlSaPassword `
        -Generated:$generatedSqlPassword -Persisted:$generatedSqlPassword
    if ($generatedSqlAccess) {
        Write-Host ''
        Write-Host '  Generierte SQL-Verbindung (DPAPI-geschützt später erneut abrufbar):' -ForegroundColor Yellow
        if ($generatedSqlAccess.connectionString) { Write-Host "  $($generatedSqlAccess.connectionString)" -ForegroundColor White }
        Write-Host "  SA-Passwort: $($generatedSqlAccess.password)" -ForegroundColor White
        Write-Host "  Abruf: Get-SqlServerLabGeneratedSqlAccess -RunId $RunId" -ForegroundColor DarkGray
    }
    Write-LabSuccess 'Unbeaufsichtigte OOBE, SQL CompleteImage, WMI und der TCP/IP-Hostzugriff sind abgeschlossen.'
    return [PSCustomObject]@{
        RunId = $RunId; OobeState = 'COMPLETED'; SqlCompletion = $sqlCompletion; StorageRuntime = $storageRuntime
        HostSqlAccess = $hostAccess; GeneratedSqlAccess = $generatedSqlAccess; PasswordSource = $PasswordSource
    }
}

function Complete-HyperVLabManualWindowsSlot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [ValidateRange(60, 3600)][int]$TimeoutSeconds = 900,
        [string]$StateRoot
    )

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    if ([string]$lab.Instance.workload -ne 'windows' -or [string]$lab.Instance.baseKind -ne 'windows-baseline') {
        throw 'HYPERV_MANUAL_WINDOWS_SLOT_REQUIRED'
    }
    if ($lab.Instance.windowsProvisioning -and [string]$lab.Instance.windowsProvisioning.state -eq 'COMPLETE') {
        throw 'HYPERV_MANUAL_WINDOWS_SLOT_ALREADY_COMPLETED'
    }
    $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') {
        throw 'HYPERV_MANUAL_WINDOWS_SLOT_VM_MUST_BE_RUNNING'
    }

    Write-LabInfo 'Windows-Slot: prüfe abgeschlossene manuelle Windows-Einrichtung per PowerShell Direct.'
    $ready = Wait-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId `
        -Credential $Credential -TimeoutSeconds $TimeoutSeconds
    if (-not $ready.Ready) { throw "HYPERV_MANUAL_WINDOWS_SLOT_TIMEOUT: $($ready.Message)" }

    Save-LabSecret -Path $lab.RunDirectory -Name 'guest-administrator-password' -Secret $Credential.Password
    $networkReceipt = $null
    if ($lab.Instance.labNetwork) {
        Write-LabInfo "Windows-Slot: konfiguriere feste Gastadresse im Netz $($lab.Instance.labNetwork.name)."
        $networkReceipt = Initialize-HyperVGuestLabNetwork -VMName ([string]$lab.Instance.vmName) `
            -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId `
            -Credential $Credential -Network $lab.Instance.labNetwork -Identity $lab.Run.runId
    }

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $lab.StateRoot
    $lab.Instance | Add-Member -NotePropertyName windowsProvisioning -NotePropertyValue ([PSCustomObject]@{
        state = 'COMPLETE'; mode = 'manual-handoff'; computerName = [string]$ready.ComputerName
        imageState = [string]$ready.ImageState; network = $networkReceipt; completedAt = Get-LabTimestamp
    }) -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
    return [PSCustomObject]@{
        RunId = $lab.Run.runId; VMName = $lab.Instance.vmName; State = 'WINDOWS_SLOT_READY'
        ComputerName = [string]$ready.ComputerName; Network = $networkReceipt
    }
}

function Set-HyperVLabSqlDeploymentPlan {
    <# .SYNOPSIS Speichert den verbindlichen SQL-Ausbauplan eines übernommenen Windows-Slots. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('2016', '2017', '2019', '2022', '2025')][string]$SqlVersion,
        [Parameter(Mandatory)][ValidateSet('sql-pool-slot', 'adhoc-install')][string]$DeploymentMode,
        [ValidateSet('Eval', 'Enterprise', 'Standard')][string]$MediaEdition = 'Enterprise',
        [Parameter(Mandatory)][string]$SqlMediaPath,
        [ValidateSet('SQLENGINE', 'FULLTEXT', 'REPLICATION', 'ADVANCEDANALYTICS')]
        [string[]]$SqlFeatures = @('SQLENGINE', 'FULLTEXT', 'REPLICATION'),
        [ValidateRange(1, 64)][int]$ProcessorCount = 4,
        [ValidateRange(0, 1000000)][long]$MaximumDataIops = 0,
        [ValidateRange(0, 1048576)][int]$MemoryStartupMB = 0,
        [ValidatePattern('^[A-Za-z0-9_]{1,128}$')][string]$Collation = 'SQL_Latin1_General_CP1_CI_AS',
        [ValidateRange(1,65535)][int]$SqlPort = 1433,
        [ValidateSet('host-access','isolated')][string]$NetworkMode = 'host-access',
        $ServerConfig,
        $StorageConfiguration,
        [string]$SqlPatch,
        [string]$SqlUpdatePath,
        [string]$ExpectedSqlBuild,
        [string]$StateRoot
    )

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    if ([string]$lab.Instance.workload -ne 'windows') { throw 'HYPERV_LAB_SQL_PLAN_REQUIRES_WINDOWS_SLOT' }
    if (-not $lab.Instance.windowsProvisioning -or [string]$lab.Instance.windowsProvisioning.state -ne 'COMPLETE') {
        throw 'HYPERV_LAB_SQL_PLAN_REQUIRES_COMPLETED_WINDOWS_SLOT'
    }
    $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if (-not $managed) { throw 'HYPERV_LAB_VM_NOT_FOUND' }
    if ([string]$managed.VM.State -ne 'Off') { throw 'HYPERV_LAB_SQL_PLAN_VM_MUST_BE_OFF' }

    $null = Set-VMProcessor -VM $managed.VM -Count $ProcessorCount -ErrorAction Stop
    if ($MemoryStartupMB -gt 0) {
        $startupBytes = [long]$MemoryStartupMB * 1MB
        $minimumBytes = [long][Math]::Max([double]512MB, [double]$startupBytes / 2)
        $maximumBytes = [long][Math]::Min([double]1TB, [double]$startupBytes * 2)
        $null = Set-VMMemory -VM $managed.VM -DynamicMemoryEnabled $true -MinimumBytes $minimumBytes `
            -StartupBytes $startupBytes -MaximumBytes $maximumBytes -ErrorAction Stop
    }
    $normalizedFeatures = @($SqlFeatures | ForEach-Object { ([string]$_).ToUpperInvariant() } | Sort-Object -Unique)
    if ($normalizedFeatures.Count -eq 0 -or $normalizedFeatures -notcontains 'SQLENGINE') {
        throw 'HYPERV_LAB_SQL_FEATURES_REQUIRE_SQLENGINE'
    }
    $lab.Instance | Add-Member -NotePropertyName sqlDeploymentPlan -NotePropertyValue ([PSCustomObject]@{
        state = 'PLANNED'; sqlVersion = $SqlVersion; mediaEdition = $MediaEdition; sqlMediaPath = $SqlMediaPath
        deploymentMode = $DeploymentMode; features = $normalizedFeatures
        processorCount = $ProcessorCount; memoryStartupMB = $MemoryStartupMB; maximumDataIops = $MaximumDataIops
        collation = $Collation; sqlPort = $SqlPort; networkMode = $NetworkMode
        serverConfig = $ServerConfig; storage = $StorageConfiguration
        sqlPatch = $SqlPatch; sqlUpdatePath = $SqlUpdatePath; expectedSqlBuild = $ExpectedSqlBuild
        plannedAt = Get-LabTimestamp
    }) -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
    return $lab.Instance.sqlDeploymentPlan
}

function Invoke-HyperVLabSqlSlotInstall {
    <# .SYNOPSIS Installiert SQL vollständig in einen eindeutigen Windows-Slot; führt niemals Sysprep aus. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$MediaRoot,
        [SecureString]$SqlSaPassword,
        [ValidateRange(60, 10800)][int]$SetupTimeoutSeconds = 7200,
        [ValidateRange(60, 3600)][int]$ReadinessTimeoutSeconds = 900,
        [string]$StateRoot
    )

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $plan = $lab.Instance.sqlDeploymentPlan
    if (-not $plan -or [string]$plan.deploymentMode -notin @('sql-pool-slot', 'adhoc-install') -or
        [string]$plan.state -notin @('PLANNED', 'INSTALL_RETRY_PENDING', 'CONFIGURATION_PENDING')) {
        throw 'HYPERV_LAB_SQL_INSTALL_PLAN_REQUIRED'
    }
    $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if (-not $managed) { throw 'HYPERV_LAB_VM_NOT_FOUND' }
    if ([string]$plan.state -eq 'PLANNED' -and [string]$managed.VM.State -ne 'Off') {
        throw 'HYPERV_LAB_SQL_INSTALL_VM_MUST_BE_OFF'
    }

    $guestPassword = Get-LabSecret -Path $lab.RunDirectory -Name 'guest-administrator-password'
    if (-not $guestPassword) { throw 'HYPERV_LAB_GUEST_PASSWORD_NOT_STORED' }
    $credential = [PSCredential]::new('Administrator', $guestPassword)
    $generatedSaPassword = $false
    if (-not $SqlSaPassword) { $SqlSaPassword = Get-LabSecret -Path $lab.RunDirectory -Name 'sa-password' }
    if ($SqlSaPassword -and [string]$plan.passwordSource -eq 'generated') { $generatedSaPassword = $true }
    if (-not $SqlSaPassword) {
        $SqlSaPassword = New-HyperVSqlUnattendedPassword
        $generatedSaPassword = $true
        Save-LabSecret -Path $lab.RunDirectory -Name 'sa-password' -Secret $SqlSaPassword
        Save-LabSecret -Path $lab.RunDirectory -Name 'generated-sql-sa-password' -Secret $SqlSaPassword
        $plan | Add-Member -NotePropertyName passwordSource -NotePropertyValue 'generated' -Force
    }

    if ([string]$plan.state -in @('PLANNED', 'INSTALL_RETRY_PENDING')) {
        $media = Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion ([string]$plan.sqlVersion) `
            -MediaEdition ([string]$plan.mediaEdition) -SqlMediaPath ([string]$plan.sqlMediaPath)
        if ([string]$media.HashStatus -ne 'SIDECAR_READY') {
            Write-LabInfo "SQL-Medium wird einmalig per SHA-256 katalogisiert: $($media.RelativePath)"
            $media = New-HyperVSqlMediaHashSidecar -MediaRoot $MediaRoot -SqlVersion ([string]$plan.sqlVersion) `
                -MediaEdition ([string]$plan.mediaEdition) -SqlMediaPath ([string]$plan.sqlMediaPath) -Confirm:$false
        }
        if ([string]$media.HashStatus -ne 'SIDECAR_READY') { throw "HYPERV_SQL_MEDIA_HASH_REQUIRED: $($media.HashPath)" }
        $null = Confirm-HyperVSqlInstallationMediaVersion -IsoPath $media.IsoPath -SqlVersion ([string]$plan.sqlVersion)
        $setupVersionPattern = Get-HyperVSqlSetupVersionPattern -SqlVersion ([string]$plan.sqlVersion)
        $existingDvd = @(Get-VMDvdDrive -VM $managed.VM -ErrorAction Stop | Where-Object { [string]$_.Path -eq [string]$media.IsoPath }) | Select-Object -First 1
        if (-not $existingDvd) { $null = Add-VMDvdDrive -VM $managed.VM -Path $media.IsoPath -ErrorAction Stop }
        $plan.state = 'INSTALLING'
        $plan | Add-Member -NotePropertyName mediaRelativePath -NotePropertyValue ([string]$media.RelativePath) -Force
        $plan | Add-Member -NotePropertyName startedAt -NotePropertyValue (Get-LabTimestamp) -Force
        Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection

        $null = Start-HyperVInstance -VMName ([string]$lab.Instance.vmName) `
            -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
        $ready = Wait-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) `
            -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $credential -TimeoutSeconds $ReadinessTimeoutSeconds
        if (-not $ready.Ready) { throw "HYPERV_LAB_SQL_INSTALL_GUEST_TIMEOUT: $($ready.Message)" }

        $pendingAdditionalDrives = @($lab.Instance.additionalDrives | Where-Object { [string]$_.state -eq 'ATTACHED_PENDING_INITIALIZATION' })
        if ($pendingAdditionalDrives.Count -gt 0) {
            Write-LabInfo "$($pendingAdditionalDrives.Count) zusätzliche SQL-VHDX werden im Gast initialisiert."
            $driveReceipt = Initialize-HyperVWindowsGuestDrives -VMName ([string]$lab.Instance.vmName) `
                -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $credential
            foreach ($drive in $pendingAdditionalDrives) {
                $initialized = @($driveReceipt.Drives | Where-Object { [string]$_.id -eq [string]$drive.id }) | Select-Object -First 1
                if (-not $initialized -or -not $initialized.guestPath) { throw "HYPERV_LAB_ADDITIONAL_DRIVE_INITIALIZATION_MISSING: $($drive.id)" }
                $drive.guestPath = [string]$initialized.guestPath
                $drive.state = 'READY'
            }
            Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
        }

        $dataRoot = $null
        if ($lab.Instance.persistentStorage) {
            if ([string]$lab.Instance.persistentStorage.state -eq 'ATTACHED_PENDING_INITIALIZATION') {
                Write-LabInfo 'SQL-Datenplatte wird vor SQL Setup initialisiert.'
                $null = Initialize-HyperVLabPersistentData -RunId $RunId -Credential $credential -StateRoot $lab.StateRoot
                $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $lab.StateRoot
                $plan = $lab.Instance.sqlDeploymentPlan
            }
            if ([string]$lab.Instance.persistentStorage.state -eq 'READY') { $dataRoot = [string]$lab.Instance.persistentStorage.guestPath }
        }

        Write-LabInfo "SQL $($plan.sqlVersion) wird vollständig im eindeutigen Windows-Slot installiert; kein Sysprep."
        try {
            $receipt = Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) `
                -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $credential `
                -ArgumentList @([string]$plan.sqlVersion, $setupVersionPattern, (@($plan.features) -join ','), $SqlSaPassword, $dataRoot, $plan.storage, [string]$plan.collation, $SetupTimeoutSeconds) `
                -ScriptBlock {
                param($ExpectedSqlVersion, $ExpectedSetupVersionPattern, $FeaturesCsv, $SaPassword, $SqlDataRoot, $StorageConfiguration, $Collation, $TimeoutSeconds)
                $ErrorActionPreference = 'Stop'
                $features = @([string]$FeaturesCsv -split ',' | Where-Object { $_ })
                $setups = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object {
                    $candidate = Join-Path ([string]$_.DeviceID + '\') 'setup.exe'
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate }
                } | Where-Object { [string]$_.VersionInfo.FileVersion -match $ExpectedSetupVersionPattern })
                if ($setups.Count -ne 1) { throw "SQL_SETUP_MEDIA_NOT_UNIQUE: $($setups.Count)" }
                    $arguments = @(
                    '/Q', '/ACTION=Install', "/FEATURES=$($features -join ',')",
                    '/INSTANCENAME=MSSQLSERVER', '/INSTANCEID=MSSQLSERVER',
                    '/SQLSVCACCOUNT="NT Service\MSSQLSERVER"', '/AGTSVCACCOUNT="NT Service\SQLSERVERAGENT"',
                    '/AGTSVCSTARTUPTYPE=Automatic', '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"',
                    '/SECURITYMODE=SQL', '/TCPENABLED=1', '/SQLSVCINSTANTFILEINIT=True',
                        '/ENU=True', '/IACCEPTSQLSERVERLICENSETERMS', '/INDICATEPROGRESS'
                    )
                    if ($Collation) { $arguments += "/SQLCOLLATION=$Collation" }
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
                $plainPassword = $null
                try {
                    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                    if ($plainPassword -match '[\s"]') { throw 'SQL_SA_PASSWORD_COMMAND_LINE_UNSAFE' }
                    $arguments += "/SAPWD=$plainPassword"
                    $paths = if ($StorageConfiguration) {
                        [PSCustomObject]@{
                            Data=[string]$StorageConfiguration.dataPath; Log=[string]$StorageConfiguration.logPath
                            Temp=[string]@($StorageConfiguration.tempDbPaths)[0]; Backup=[string]$StorageConfiguration.backupPath
                        }
                    } elseif ($SqlDataRoot) {
                        [PSCustomObject]@{
                            Data=Join-Path $SqlDataRoot 'Data'; Log=Join-Path $SqlDataRoot 'Log'
                            Temp=Join-Path $SqlDataRoot 'TempDB'; Backup=Join-Path $SqlDataRoot 'Backup'
                        }
                    } else { $null }
                    if ($paths) {
                        @($paths.Data,$paths.Log,$paths.Temp,$paths.Backup) | ForEach-Object { $null = New-Item -Path $_ -ItemType Directory -Force }
                        $arguments += "/SQLUSERDBDIR=$($paths.Data)"
                        $arguments += "/SQLUSERDBLOGDIR=$($paths.Log)"
                        $arguments += "/SQLTEMPDBDIR=$($paths.Temp)"
                        $arguments += "/SQLTEMPDBLOGDIR=$($paths.Temp)"
                        $arguments += "/SQLBACKUPDIR=$($paths.Backup)"
                    }
                    $process = Start-Process -FilePath $setups[0].FullName -ArgumentList $arguments -PassThru -NoNewWindow
                    if (-not $process.WaitForExit([int]$TimeoutSeconds * 1000)) {
                        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                        throw "SQL_SETUP_INSTALL_TIMEOUT: $TimeoutSeconds"
                    }
                    if ([int]$process.ExitCode -notin @(0,3010)) { throw "SQL_SETUP_INSTALL_FAILED: $($process.ExitCode)" }
                    $summary = Get-ChildItem -LiteralPath 'C:\Program Files\Microsoft SQL Server' -Filter Summary.txt -Recurse -File -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
                    $summaryText = if ($summary) { Get-Content -LiteralPath $summary.FullName -Raw -ErrorAction SilentlyContinue } else { $null }
                    if ($summaryText -match '(?im)^Final result:\s+Failed\s*$') {
                        $summaryTail = @(Get-Content -LiteralPath $summary.FullName -Tail 12 -ErrorAction SilentlyContinue) -join ' | '
                        throw "SQL_SETUP_INSTALL_FAILED: ExitCode=$([int]$process.ExitCode); Summary=$summaryTail"
                    }
                    $instanceRegistryPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
                    $registrationDeadline = [datetime]::UtcNow.AddMinutes(5)
                    $instanceRegistered = $false
                    do {
                        $instanceRegistered = (Test-Path -LiteralPath $instanceRegistryPath) -and
                            ($null -ne (Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue))
                        if (-not $instanceRegistered) { Start-Sleep -Seconds 5 }
                    } while (-not $instanceRegistered -and [datetime]::UtcNow -lt $registrationDeadline)
                    if (-not $instanceRegistered) {
                        $summaryTail = if ($summary) { (@(Get-Content -LiteralPath $summary.FullName -Tail 12 -ErrorAction SilentlyContinue) -join ' | ') } else { 'nicht gefunden' }
                        throw "SQL_SETUP_INSTALLATION_NOT_REGISTERED: ExitCode=$([int]$process.ExitCode); Summary=$summaryTail"
                    }
                    [PSCustomObject]@{
                        action='Install'; sqlVersion=$ExpectedSqlVersion; setupVersion=[string]$setups[0].VersionInfo.FileVersion
                        features=$features; exitCode=[int]$process.ExitCode; completedAt=[datetime]::UtcNow.ToString('o')
                    }
                }
                finally {
                    $plainPassword = $null
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
                }
        }
        catch {
            if ($_.Exception.Message -match 'SQL_SETUP_(?:INSTALL_FAILED|INSTALL_TIMEOUT|INSTALLATION_NOT_REGISTERED)') {
                $plan.state = 'INSTALL_RETRY_PENDING'
                $failureCode = if ($_.Exception.Message -match 'SQL_SETUP_[A-Z_]+') { $Matches[0] } else { 'SQL_SETUP_FAILED' }
                $plan | Add-Member -NotePropertyName lastSetupFailure -NotePropertyValue $failureCode -Force
                $plan | Add-Member -NotePropertyName lastSetupFailureAt -NotePropertyValue (Get-LabTimestamp) -Force
                Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
            }
            throw
        }
        $receipt = @($receipt)[-1]
        if (-not $receipt -or [string]$receipt.action -ne 'Install' -or [int]$receipt.exitCode -notin @(0,3010)) {
            throw 'HYPERV_LAB_SQL_INSTALL_RECEIPT_INVALID'
        }
        if ([int]$receipt.exitCode -eq 3010) {
            Write-LabInfo 'SQL Setup fordert einen Neustart; Gast wird neu gestartet und automatisch wieder übernommen.'
            $null = Restart-VM -Name ([string]$lab.Instance.vmName) -Force -ErrorAction Stop
            $ready = Wait-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) `
                -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $credential -TimeoutSeconds $ReadinessTimeoutSeconds
            if (-not $ready.Ready) { throw "HYPERV_LAB_SQL_INSTALL_RESTART_TIMEOUT: $($ready.Message)" }
        }
        if ($plan.sqlUpdatePath -and -not $plan.patchAppliedAt) {
            if (-not (Test-Path -LiteralPath $plan.sqlUpdatePath -PathType Leaf)) { throw "HYPERV_SQL_CU_PACKAGE_MISSING: $($plan.sqlUpdatePath)" }
            Write-LabInfo "SQL $($plan.sqlPatch) wird im Gast installiert."
            $guestFolder='C:\SqlServerLab\Updates'
            $guestUpdatePath=Join-Path $guestFolder (Split-Path -Leaf ([string]$plan.sqlUpdatePath))
            $null=Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $credential -ArgumentList @($guestFolder) -ScriptBlock {param($Path);$null=New-Item -ItemType Directory -Path $Path -Force}
            $guestService=Get-VMIntegrationService -VMName ([string]$lab.Instance.vmName) -ErrorAction Stop |
                Where-Object { ([string]$_.Id).EndsWith('6C09BB55-D683-4DA0-8931-C9BF705F6480', [StringComparison]::OrdinalIgnoreCase) } |
                Select-Object -First 1
            if(-not $guestService){throw 'HYPERV_GUEST_FILE_COPY_SERVICE_NOT_FOUND'}
            if(-not $guestService.Enabled){$null=Enable-VMIntegrationService -VMIntegrationService $guestService -ErrorAction Stop}
            Copy-VMFile -VMName ([string]$lab.Instance.vmName) -SourcePath ([string]$plan.sqlUpdatePath) -DestinationPath $guestUpdatePath -FileSource Host -CreateFullPath -Force -ErrorAction Stop
            $patchReceipt=Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $credential -ArgumentList @($guestUpdatePath,$SetupTimeoutSeconds) -ScriptBlock {
                param($PackagePath,$TimeoutSeconds)
                $process=Start-Process -FilePath $PackagePath -ArgumentList @('/quiet','/IAcceptSQLServerLicenseTerms','/Action=Patch','/AllInstances') -PassThru
                if(-not $process.WaitForExit([int]$TimeoutSeconds*1000)){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue;throw "SQL_CU_INSTALL_TIMEOUT: $TimeoutSeconds"}
                if([int]$process.ExitCode -notin @(0,3010)){throw "SQL_CU_INSTALL_FAILED: $($process.ExitCode)"}
                [PSCustomObject]@{exitCode=[int]$process.ExitCode;completedAt=[datetime]::UtcNow.ToString('o')}
            }
            $patchReceipt=@($patchReceipt)[-1]
            if([int]$patchReceipt.exitCode -eq 3010){$null=Restart-VM -Name ([string]$lab.Instance.vmName) -Force -ErrorAction Stop;$ready=Wait-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $credential -TimeoutSeconds $ReadinessTimeoutSeconds;if(-not $ready.Ready){throw 'HYPERV_SQL_CU_RESTART_TIMEOUT'}}
            $actualBuild=Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $credential -ScriptBlock {$instance=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop).MSSQLSERVER;(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instance\MSSQLServer\CurrentVersion" -ErrorAction Stop).CurrentVersion}
            $actualBuild=[string]@($actualBuild)[-1]
            if($plan.expectedSqlBuild -and $actualBuild -ne [string]$plan.expectedSqlBuild){throw "HYPERV_SQL_CU_BUILD_MISMATCH: expected=$($plan.expectedSqlBuild); actual=$actualBuild"}
            $plan | Add-Member -NotePropertyName patchAppliedAt -NotePropertyValue ([string]$patchReceipt.completedAt) -Force
            $plan | Add-Member -NotePropertyName installedSqlBuild -NotePropertyValue $actualBuild -Force
        }
        $plan.state = 'CONFIGURATION_PENDING'
        $plan | Add-Member -NotePropertyName setupVersion -NotePropertyValue ([string]$receipt.setupVersion) -Force
        $plan | Add-Member -NotePropertyName installedAt -NotePropertyValue ([string]$receipt.completedAt) -Force
        $lab.Instance | Add-Member -NotePropertyName workload -NotePropertyValue 'sql' -Force
        $lab.Instance | Add-Member -NotePropertyName sqlVersion -NotePropertyValue ([string]$plan.sqlVersion) -Force
        $lab.Instance | Add-Member -NotePropertyName sqlEdition -NotePropertyValue ([string]$plan.mediaEdition) -Force
        Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
    }

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $lab.StateRoot
    $plan = $lab.Instance.sqlDeploymentPlan
    Write-LabInfo 'SQL-Instanz wird für Hostzugriff, TCP/IP, Firewall und Labnetz fertig konfiguriert.'
    $hostAccess = Enable-HyperVLabHostSqlAccess -RunId $RunId -Credential $credential -SqlSaPassword $SqlSaPassword `
        -SqlPort $(if ($plan.sqlPort) { [int]$plan.sqlPort } else { 1433 }) -StateRoot $lab.StateRoot
    if ($plan.serverConfig) {
        Write-LabInfo 'Deklarierte SQL-Memory-, MAXDOP-, Cost-Threshold- und TempDB-Konfiguration wird angewendet.'
        $null = Set-LabServerConfig -Config $plan.serverConfig -HostName ([string]$hostAccess.Network.Address) `
            -Port $(if ($plan.sqlPort) { [int]$plan.sqlPort } else { 1433 }) -SaPassword $SqlSaPassword
    }
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $lab.StateRoot
    $plan = $lab.Instance.sqlDeploymentPlan
    $plan.state = 'SQL_SLOT_READY'
    $plan | Add-Member -NotePropertyName completedAt -NotePropertyValue (Get-LabTimestamp) -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection

    if ([string]$plan.deploymentMode -eq 'sql-pool-slot') {
        $null = Stop-HyperVInstance -VMName ([string]$lab.Instance.vmName) `
            -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    }
    else {
        if ([string]$lab.Run.state -eq 'STOPPED') {
            $null = Set-LabRunState -RunId $RunId -NewState RUNNING -Reason 'SQL-Ad-hoc-Umgebung vollständig installiert.' -StateRoot $lab.StateRoot
        }
        Set-LabProviderSubRunState -RunId $RunId -Provider hyperv -NewState RUNNING -Reason 'SQL-Ad-hoc-Umgebung vollständig installiert.' -StateRoot $lab.StateRoot
    }
    if ([string]$plan.networkMode -eq 'isolated') {
        Write-LabInfo 'Angeforderte Isolation: Netzwerkadapter wird nach Abschluss der SQL-Konfiguration entfernt.'
        @(Get-VMNetworkAdapter -VMName ([string]$lab.Instance.vmName) -ErrorAction Stop) | Remove-VMNetworkAdapter -ErrorAction Stop
        $lab.Instance.host = $null; $lab.Instance.port = $null; $lab.Instance.connectionString = $null; $lab.Instance.labNetwork = $null
        Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
        $hostAccess = $null
    }
    $generatedAccess = if ($hostAccess) {
        New-HyperVTransientGeneratedSqlAccess -HostSqlAccess $hostAccess -SqlSaPassword $SqlSaPassword `
            -Generated:$generatedSaPassword -Persisted:$generatedSaPassword
    } else { $null }
    return [PSCustomObject]@{
        RunId=$RunId; VMName=$lab.Instance.vmName; State='SQL_SLOT_READY'; SqlVersion=$plan.sqlVersion
        DeploymentMode=$plan.deploymentMode; HostSqlAccess=$hostAccess; GeneratedSqlAccess=$generatedAccess
    }
}

function Invoke-HyperVLabSqlPreparedSlot {
    <# .SYNOPSIS Baut einen übernommenen Windows-Slot bis zur veröffentlichungsbereiten SQL-Prepared-VHDX aus. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$MediaRoot,
        [ValidateRange(60, 10800)][int]$SetupTimeoutSeconds = 7200,
        [ValidateRange(30, 1800)][int]$ShutdownTimeoutSeconds = 600,
        [string]$StateRoot
    )

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $plan = $lab.Instance.sqlDeploymentPlan
    if (-not $plan -or [string]$plan.state -notin @('PLANNED', 'PREPARE_RUNNING') -or [string]$plan.deploymentMode -ne 'prepared-template') {
        throw 'HYPERV_LAB_SQL_PREPARED_PLAN_REQUIRED'
    }
    $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if (-not $managed) { throw 'HYPERV_LAB_VM_NOT_FOUND' }
    if ([string]$plan.state -eq 'PLANNED' -and [string]$managed.VM.State -ne 'Off') { throw 'HYPERV_LAB_SQL_PREPARE_VM_MUST_BE_OFF' }
    if ([string]$plan.state -eq 'PREPARE_RUNNING') {
        Write-LabInfo 'SQL PrepareImage und Sysprep sind bereits abgeschlossen; VM wird hostseitig ausgeschaltet und die Child-VHDX offline geprüft.'
        if ([string]$managed.VM.State -ne 'Off') {
            $null = Stop-HyperVInstance -VMName ([string]$lab.Instance.vmName) `
                -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
        }
        $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) `
            -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
        if ([string]$managed.VM.State -ne 'Off') { throw 'HYPERV_LAB_SQL_GENERALIZE_RECOVERY_SHUTDOWN_FAILED' }
        $vhdxPath = [string]$managed.Identity.childVhdxPath
        if (-not $vhdxPath -or -not (Test-Path -LiteralPath $vhdxPath -PathType Leaf)) {
            throw 'HYPERV_LAB_SQL_GENERALIZE_RECOVERY_VHDX_MISSING'
        }
        $inspection = Get-HyperVSqlOfflineImageState -VhdxPath $vhdxPath `
            -MountRoot (Join-Path $lab.RunDirectory 'offline-generalization-inspection')
        $imageState = [string]$inspection.ImageState
        if ($imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
            $reason = Get-HyperVSqlSysprepFailureReason -ImageState $imageState -SysprepDetail ([string]$inspection.SysprepDetail)
            $plan | Add-Member -NotePropertyName lastError -NotePropertyValue $reason -Force
            $plan | Add-Member -NotePropertyName sysprepFailureDetail -NotePropertyValue ([string]$inspection.SysprepDetail) -Force
            Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
            throw $reason
        }
        $setupVersion = 'unknown'
        if ($plan.mediaRelativePath) {
            $sqlIsoPath = Join-Path $MediaRoot ([string]$plan.mediaRelativePath).Replace('/', '\')
            if (Test-Path -LiteralPath $sqlIsoPath -PathType Leaf) {
                $setupVersion = [string](Get-HyperVSqlInstallationMediaInfo -IsoPath $sqlIsoPath).SetupVersion
            }
        }
        $plan.state = 'GENERALIZED_READY_TO_PUBLISH'
        $plan | Add-Member -NotePropertyName setupVersion -NotePropertyValue $setupVersion -Force
        $plan | Add-Member -NotePropertyName completedAt -NotePropertyValue (Get-LabTimestamp) -Force
        $plan | Add-Member -NotePropertyName generalizationEvidence -NotePropertyValue ([PSCustomObject]@{
            source='offline-inspection'; imageState=$imageState; shutdownObserved=$true; acceptedAt=Get-LabTimestamp
        }) -Force
        Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
        return [PSCustomObject]@{ RunId=$RunId; VMName=$lab.Instance.vmName; State=$plan.state; SqlVersion=$plan.sqlVersion; SetupVersion=$plan.setupVersion }
    }

    $media = Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion ([string]$plan.sqlVersion) `
        -MediaEdition ([string]$plan.mediaEdition)
    if ([string]$media.HashStatus -ne 'SIDECAR_READY') {
        Write-LabInfo "SQL-Medium wird einmalig per SHA-256 katalogisiert: $($media.RelativePath)"
        $media = New-HyperVSqlMediaHashSidecar -MediaRoot $MediaRoot -SqlVersion ([string]$plan.sqlVersion) `
            -MediaEdition ([string]$plan.mediaEdition) -Confirm:$false
        if ([string]$media.HashStatus -ne 'SIDECAR_READY') { throw "HYPERV_SQL_MEDIA_HASH_REQUIRED: $($media.HashPath)" }
    }
    $null = Confirm-HyperVSqlInstallationMediaVersion -IsoPath $media.IsoPath -SqlVersion ([string]$plan.sqlVersion)
    $setupVersionPattern = Get-HyperVSqlSetupVersionPattern -SqlVersion ([string]$plan.sqlVersion)
    $existingDvd = @(Get-VMDvdDrive -VM $managed.VM -ErrorAction Stop | Where-Object { [string]$_.Path -eq [string]$media.IsoPath }) | Select-Object -First 1
    if (-not $existingDvd) { $null = Add-VMDvdDrive -VM $managed.VM -Path $media.IsoPath -ErrorAction Stop }

    $password = Get-LabSecret -Path $lab.RunDirectory -Name 'guest-administrator-password'
    if (-not $password) { throw 'HYPERV_LAB_GUEST_PASSWORD_NOT_STORED' }
    $credential = [PSCredential]::new('Administrator', $password)
    $plan.state = 'PREPARE_RUNNING'
    $plan | Add-Member -NotePropertyName mediaRelativePath -NotePropertyValue ([string]$media.RelativePath) -Force
    $plan | Add-Member -NotePropertyName startedAt -NotePropertyValue (Get-LabTimestamp) -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection

    $null = Start-HyperVInstance -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    $ready = Wait-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $credential -TimeoutSeconds 900
    if (-not $ready.Ready) { throw "HYPERV_LAB_SQL_PREPARE_GUEST_TIMEOUT: $($ready.Message)" }

    $receipt = Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $credential `
        -ArgumentList @([string]$plan.sqlVersion, $setupVersionPattern, (@($plan.features) -join ','), $SetupTimeoutSeconds) `
        -ScriptBlock {
            param($ExpectedSqlVersion, $ExpectedSetupVersionPattern, $FeaturesCsv, $TimeoutSeconds)
            $ErrorActionPreference = 'Stop'
            $features = @([string]$FeaturesCsv -split ',' | Where-Object { $_ })
            $setups = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object {
                $candidate = Join-Path ([string]$_.DeviceID + '\') 'setup.exe'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate }
            } | Where-Object { [string]$_.VersionInfo.FileVersion -match $ExpectedSetupVersionPattern })
            if ($setups.Count -ne 1) { throw "SQL_SETUP_MEDIA_NOT_UNIQUE: $($setups.Count)" }
            $arguments = @(
                '/Q', '/ACTION=PrepareImage', "/FEATURES=$($features -join ',')",
                '/INSTANCEID=MSSQLSERVER', '/ENU=True', '/IACCEPTSQLSERVERLICENSETERMS', '/INDICATEPROGRESS'
            )
            $process = Start-Process -FilePath $setups[0].FullName -ArgumentList $arguments -PassThru -NoNewWindow
            if (-not $process.WaitForExit([int]$TimeoutSeconds * 1000)) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                throw "SQL_SETUP_PREPARE_IMAGE_TIMEOUT: $TimeoutSeconds"
            }
            if ([int]$process.ExitCode -notin @(0, 3010)) { throw "SQL_SETUP_PREPARE_IMAGE_FAILED: $($process.ExitCode)" }
            if ([int]$process.ExitCode -eq 3010) {
                $null = & shutdown.exe /r /t 0 /f
                return [PSCustomObject]@{ action='PrepareImage'; sqlVersion=$ExpectedSqlVersion; setupVersion=[string]$setups[0].VersionInfo.FileVersion; exitCode=3010 }
            }

            Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object {
                Set-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction SilentlyContinue
                Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object PrefixOrigin -EQ Manual | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
            }
            $sysprep = Start-Process -FilePath "$env:SystemRoot\System32\Sysprep\Sysprep.exe" `
                -ArgumentList @('/generalize','/oobe','/mode:vm','/quit','/quiet') -Wait -PassThru
            if ([int]$sysprep.ExitCode -ne 0) { throw "WINDOWS_SYSPREP_FAILED: $($sysprep.ExitCode)" }
            $deadline = [datetime]::UtcNow.AddMinutes(10)
            do {
                $imageState = [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState)
                if ($imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { break }
                Start-Sleep -Seconds 2
            } while ([datetime]::UtcNow -lt $deadline)
            if ($imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { throw "WINDOWS_SYSPREP_STATE_INVALID: $imageState" }
            $null = & shutdown.exe /s /t 15 /f /d p:4:1
            [PSCustomObject]@{
                action='PrepareImage'; sqlVersion=$ExpectedSqlVersion; setupVersion=[string]$setups[0].VersionInfo.FileVersion
                features=$features; exitCode=0; imageState=$imageState; completedAt=[datetime]::UtcNow.ToString('o')
            }
        }
    $receipt = @($receipt)[-1]
    if (-not $receipt -or [string]$receipt.action -ne 'PrepareImage' -or [int]$receipt.exitCode -ne 0 -or
        [string]$receipt.imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
        if ($receipt -and [int]$receipt.exitCode -eq 3010) {
            $plan.state = 'REBOOT_REQUIRED'
            Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
            throw 'HYPERV_LAB_SQL_PREPARE_REBOOT_REQUIRED'
        }
        throw 'HYPERV_LAB_SQL_PREPARE_RECEIPT_INVALID'
    }
    $deadline = [datetime]::UtcNow.AddSeconds($ShutdownTimeoutSeconds)
    do {
        $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) `
            -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
        if ([string]$managed.VM.State -eq 'Off') { break }
        Start-Sleep -Seconds 2
    } while ([datetime]::UtcNow -lt $deadline)
    if ([string]$managed.VM.State -ne 'Off') { throw 'HYPERV_LAB_SQL_PREPARE_SHUTDOWN_TIMEOUT' }

    $plan.state = 'GENERALIZED_READY_TO_PUBLISH'
    $plan | Add-Member -NotePropertyName setupVersion -NotePropertyValue ([string]$receipt.setupVersion) -Force
    $plan | Add-Member -NotePropertyName completedAt -NotePropertyValue ([string]$receipt.completedAt) -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
    return [PSCustomObject]@{ RunId=$RunId; VMName=$lab.Instance.vmName; State=$plan.state; SqlVersion=$plan.sqlVersion; SetupVersion=$plan.setupVersion }
}

function Rename-HyperVLabEnvironment {
    <#
    .SYNOPSIS
        Benennt einen Hyper-V-Lab-Run und seine ausgeschaltete VM gemeinsam um.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$')][string]$DisplayName,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $DisplayName = $DisplayName.Trim()
    $newVmName = Get-HyperVLabRuntimeName -LabName $DisplayName -RunId $RunId
    $previousVmName = [string]$lab.Instance.vmName
    $vmRenamed = $false

    if ($previousVmName -ne $newVmName) {
        $managed = Get-HyperVManagedVM -VMName $previousVmName -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
        if ([string]$managed.VM.State -ne 'Off') { throw 'HYPERV_LAB_VM_MUST_BE_STOPPED_FOR_RENAME' }
        if (Get-VM -Name $newVmName -ErrorAction SilentlyContinue) { throw "HYPERV_LAB_VM_NAME_ALREADY_EXISTS: $newVmName" }
        Rename-VM -VM $managed.VM -NewName $newVmName -ErrorAction Stop
        $lab.Instance | Add-Member -NotePropertyName vmName -NotePropertyValue $newVmName -Force
        Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
        $planPath = Join-Path $lab.RunDirectory 'cleanup-plan.json'
        if (Test-Path -LiteralPath $planPath -PathType Leaf) {
            $plan = Get-Content -LiteralPath $planPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
            foreach ($step in @($plan.steps | Where-Object { $_.resourceType -eq 'vm' -and $_.resourceId -eq $previousVmName })) {
                $step.resourceId = $newVmName
                $step.compensation = "Remove Hyper-V VM $newVmName"
            }
            Write-LabArtifactJsonAtomic -Path $planPath -InputObject $plan
        }
        $vmRenamed = $true
    }

    try {
        $renamed = Rename-LabRunDisplayName -RunId $RunId -DisplayName $DisplayName -StateRoot $StateRoot
    }
    catch {
        if ($vmRenamed) { try { Rename-VM -Name $newVmName -NewName $previousVmName -ErrorAction Stop } catch { } }
        throw
    }
    return [PSCustomObject]@{
        RunId = $renamed.RunId; PreviousName = $renamed.PreviousName; Name = $renamed.Name; Changed = $renamed.Changed
        PreviousVMName = $previousVmName; VMName = $newVmName; VMRenamed = $vmRenamed
    }
}

function Start-HyperVLabEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [string]$StateRoot)
    Write-LabInfo 'Schritt 1/2: Besitz und aktueller Status der Hyper-V-VM werden geprüft.'
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    Write-LabInfo "Schritt 2/2: VM $($lab.Instance.vmName) wird gestartet."
    $status = Start-HyperVInstance -VMName $lab.Instance.vmName -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if ([string]$lab.Run.state -eq 'STOPPED') { $null = Set-LabRunState -RunId $RunId -NewState RUNNING -Reason 'Hyper-V-VM gestartet.' -StateRoot $lab.StateRoot }
    Set-LabProviderSubRunState -RunId $RunId -Provider hyperv -NewState RUNNING -Reason 'Hyper-V-VM gestartet.' -StateRoot $lab.StateRoot
    return $status
}

function Enable-HyperVLabPersistentData {
    <# .SYNOPSIS Hängt eine langlebige Daten-VHDX aus dem Data Root an eine ausgeschaltete Lab-VM an. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$DataRoot,
        [ValidateRange(32, 4096)][int]$SizeGB = 128,
        [ValidateRange(0, 1000000)][long]$MaximumIops = 0,
        [string]$StateRoot
    )

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if (-not $managed -or [string]$managed.VM.State -ne 'Off') { throw 'HYPERV_LAB_PERSISTENT_DATA_VM_MUST_BE_OFF' }
    if ($lab.Instance.persistentStorage) { throw 'HYPERV_LAB_PERSISTENT_DATA_ALREADY_ENABLED' }
    $sqlVersion = if ($lab.Instance.sqlVersion) { [string]$lab.Instance.sqlVersion } else { 'windows' }
    $storage = Get-LabPersistentInstanceStorage -DataRoot $DataRoot -LabName ([string]$lab.Run.metadata.name) -Provider hyperv -InstanceId ([string]$lab.Instance.id) -SqlVersion $sqlVersion -Create
    if (Test-Path -LiteralPath $storage.HyperVVhdxPath -PathType Leaf) { throw 'HYPERV_LAB_PERSISTENT_DATA_VHDX_ALREADY_EXISTS' }
    $null = New-VHD -Path $storage.HyperVVhdxPath -Dynamic -SizeBytes ([long]$SizeGB * 1GB) -ErrorAction Stop
    $vhd = Get-VHD -Path $storage.HyperVVhdxPath -ErrorAction Stop
    $drive = [PSCustomObject]@{
        Id = 'persistent-sql-data'; Role = 'sqlData'; SizeBytes = [long]$SizeGB * 1GB; VhdType = 'dynamic'
        Path = [string]$storage.HyperVVhdxPath; DiskIdentifier = ([string]$vhd.DiskIdentifier).ToUpperInvariant()
        # S: ist bewusst gewählt: D: ist in vielen Gastinstallationen das
        # DVD-Laufwerk. Der Gast wählt bei einem Konflikt selbst einen freien
        # Datenbuchstaben und speichert ihn anschließend in den VM-Notes.
        GuestPath = 'S:\SQLData'; DriveLetter = 'S'; FileSystem = 'NTFS'; AllocationUnitKB = 64; VolumeLabel = 'SQLLAB_DATA'
    }
    $allDrives = @($managed.Identity.additionalDrives) + @($drive)
    $notes = ConvertTo-HyperVLabNotes -RunId $lab.Run.runId -ScopeId $lab.Run.scopeId -InstanceId ([string]$lab.Instance.id) -ChildVhdxPath ([string]$managed.Identity.childVhdxPath) -AdditionalDrives $allDrives
    $attachedDrive = Add-VMHardDiskDrive -VMName $lab.Instance.vmName -ControllerType SCSI -ControllerNumber 0 -Path $storage.HyperVVhdxPath -Passthru -ErrorAction Stop
    if ($MaximumIops -gt 0) {
        $null = Set-VMHardDiskDrive -VMHardDiskDrive $attachedDrive -MaximumIOPS $MaximumIops -ErrorAction Stop
    }
    $null = Set-VM -VMName $lab.Instance.vmName -Notes $notes -AutomaticCheckpointsEnabled $false -ErrorAction Stop
    $lab.Instance | Add-Member -NotePropertyName persistentStorage -NotePropertyValue ([PSCustomObject]@{
        mode = 'data-root-vhdx'; root = [string]$storage.SqlRoot; hostPath = [string]$storage.HyperVVhdxPath
        guestPath = 'S:\SQLData'; backupGuestPath = 'S:\SQLData\Backups'; backupMode = 'guest-data-vhdx'
        maximumIops = $MaximumIops; state = 'ATTACHED_PENDING_INITIALIZATION'
    }) -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
    Write-LabSuccess "Persistente Daten-VHDX angehängt: $($storage.HyperVVhdxPath). Nach dem VM-Start einmal initialisieren."
    return $lab.Instance.persistentStorage
}

function Initialize-HyperVLabPersistentData {
    <# .SYNOPSIS Formatiert den zuvor angehängten persistenten Lab-Datenträger im laufenden Gast. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][PSCredential]$Credential, [string]$StateRoot)

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    if (-not $lab.Instance.persistentStorage -or [string]$lab.Instance.persistentStorage.state -ne 'ATTACHED_PENDING_INITIALIZATION') { throw 'HYPERV_LAB_PERSISTENT_DATA_INITIALIZATION_NOT_PENDING' }
    $receipt = Initialize-HyperVWindowsGuestDrives -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $Credential
    $dataDrive = @($receipt.Drives | Where-Object id -EQ 'persistent-sql-data') | Select-Object -First 1
    if (-not $dataDrive -or -not $dataDrive.guestPath) { throw 'HYPERV_LAB_PERSISTENT_DATA_RECEIPT_MISSING' }
    $lab.Instance.persistentStorage.guestPath = [string]$dataDrive.guestPath
    $backupGuestPath = Join-Path ([string]$dataDrive.guestPath) 'Backups'
    $null = Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $Credential -ArgumentList @($backupGuestPath) -ScriptBlock {
        param($BackupPath)
        New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
        [PSCustomObject]@{ backupPath = $BackupPath; ready = (Test-Path -LiteralPath $BackupPath -PathType Container) }
    }
    $lab.Instance.persistentStorage.backupGuestPath = $backupGuestPath
    $lab.Instance.persistentStorage.backupMode = 'guest-data-vhdx'
    $lab.Instance.persistentStorage.state = 'READY'
    $lab.Instance.persistentStorage.initializedAt = Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
    Write-LabSuccess "Persistenter Hyper-V-Datenträger ist im Gast als $($lab.Instance.persistentStorage.guestPath) bereit; Backup-Pfad: $backupGuestPath"
    return $receipt
}

function Get-HyperVLabSqlInstanceReceipt {
    <#
    .SYNOPSIS Liest alle lokal registrierten SQL-Server-Instanzen im verwalteten Gast aus.
    .DESCRIPTION Die Prüfung ist ausschließlich lesend. Sie verwendet PowerShell
    Direct und erfasst Instanzname, Dienstzustand sowie – sofern festgelegt –
    den TCP-Port. Kennwörter und sonstige Geheimnisse werden nicht gelesen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Lab,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [string]$FallbackAddress
    )

    $managed = Get-HyperVManagedVM -VMName ([string]$Lab.Instance.vmName) -ExpectedRunId $Lab.Run.runId -ExpectedScopeId $Lab.Run.scopeId
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') { throw 'HYPERV_LAB_SQL_INSPECTION_VM_MUST_BE_RUNNING' }
    $receipt = Invoke-HyperVPowerShellDirect -VMName $Lab.Instance.vmName -ExpectedRunId $Lab.Run.runId -ExpectedScopeId $Lab.Run.scopeId -Credential $Credential -FallbackAddress $FallbackAddress -ArgumentList @([string]$Lab.Run.runId, [string]$Lab.Run.scopeId) -ScriptBlock {
        param($ExpectedRunId, $ExpectedScopeId)
        $root = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
        $instances = @()
        if (Test-Path -LiteralPath $root) {
            $properties = Get-ItemProperty -LiteralPath $root -ErrorAction Stop
            foreach ($property in @($properties.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
                $name = [string]$property.Name
                $instanceId = [string]$property.Value
                $serviceName = if ($name -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { 'MSSQL$' + $name }
                $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                $tcpPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"
                $port = $null
                if (Test-Path -LiteralPath $tcpPath) {
                    $tcp = Get-ItemProperty -LiteralPath $tcpPath -ErrorAction Stop
                    $candidate = [string]$tcp.TcpPort
                    if (-not $candidate) { $candidate = [string]$tcp.TcpDynamicPorts }
                    if ($candidate -match '^\d{1,5}$') { $port = [int]$candidate }
                }
                $instances += [PSCustomObject]@{
                    name = $name; instanceId = $instanceId; isDefault = ($name -eq 'MSSQLSERVER')
                    serviceName = $serviceName; serviceStatus = if ($service) { [string]$service.Status } else { 'NOT_FOUND' }
                    tcpPort = $port
                }
            }
        }
        [PSCustomObject]@{ runId = $ExpectedRunId; scopeId = $ExpectedScopeId; instances = @($instances); inspectedAt = [datetime]::UtcNow.ToString('o') }
    }
    $receipt = @($receipt)[-1]
    if (-not $receipt -or [string]$receipt.runId -ne [string]$Lab.Run.runId -or [string]$receipt.scopeId -ne [string]$Lab.Run.scopeId) {
        throw 'HYPERV_LAB_SQL_INSPECTION_RECEIPT_INVALID'
    }
    return $receipt
}

function Save-HyperVLabSqlInstanceReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lab, [Parameter(Mandatory)]$Receipt)

    $instances = @($Receipt.instances | ForEach-Object {
        $inVmServer = if ($_.isDefault) {
            if ($_.tcpPort) { "localhost,$($_.tcpPort)" } else { 'localhost' }
        }
        elseif ($_.tcpPort) { "localhost,$($_.tcpPort)" }
        else { "localhost\$($_.name)" }
        $hostServer = if ($Lab.Instance.host -and $_.tcpPort) { "$($Lab.Instance.host),$($_.tcpPort)" } else { $null }
        $hostConnection = if ($hostServer) {
            "Server=$hostServer;Database=master;User ID=sa;Password=<SQL-SA-Passwort>;Encrypt=True;TrustServerCertificate=True;"
        }
        else { $null }
        [PSCustomObject]@{
            Name = [string]$_.name; InstanceId = [string]$_.instanceId; IsDefault = [bool]$_.isDefault
            ServiceName = [string]$_.serviceName; ServiceStatus = [string]$_.serviceStatus; TcpPort = $_.tcpPort
            InVmConnectionString = "Server=$inVmServer;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;"
            HostConnectionString = $hostConnection
            ConnectionString = if ($hostConnection) { $hostConnection } else { "Server=$inVmServer;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;" }
        }
    })
    $Lab.Instance | Add-Member -NotePropertyName sqlInstances -NotePropertyValue $instances -Force
    $Lab.Instance | Add-Member -NotePropertyName sqlInstancesInspectedAt -NotePropertyValue ([string]$Receipt.inspectedAt) -Force
    $running = @($instances | Where-Object { $_.ServiceStatus -eq 'Running' })
    $primaryConnectionString = if ($running.Count -eq 1) { [string]$running[0].ConnectionString } else { $null }
    $Lab.Instance | Add-Member -NotePropertyName connectionString -NotePropertyValue $primaryConnectionString -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $Lab.RunDirectory 'connection-info.json') -InputObject $Lab.Connection
    return $instances
}

function Enable-HyperVLabHostSqlAccess {
    <#
    .SYNOPSIS Richtet Host-SSMS-Zugriff für einen regulären Hyper-V-Lab-Klon ein.
    .DESCRIPTION Bindet die VM an den verbindlichen internen Lab-Switch, setzt
    eine run-stabile Gast-IP, aktiviert SQL-TCP auf 1433, beschränkt die
    Gastfirewall auf den Hyper-V-Host und setzt SQL-Authentifizierung. Das
    SA-Passwort kann unabhängig vom Gast-Administratorpasswort übergeben
    werden; ohne Angabe bleibt der sichere Gleichheits-Standard erhalten.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [SecureString]$SqlSaPassword,
        [ValidateRange(1,65535)][int]$SqlPort = 1433,
        [string]$SwitchName,
        [string]$StateRoot
    )

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') { throw 'HYPERV_LAB_HOST_SQL_VM_MUST_BE_RUNNING' }
    $usesSeparateSaPassword = $null -ne $SqlSaPassword
    if (-not $SqlSaPassword) { $SqlSaPassword = $Credential.Password }

    $preferredSwitch = if ($SwitchName) { $SwitchName } elseif ($lab.Instance.labNetwork -and $lab.Instance.labNetwork.name) { [string]$lab.Instance.labNetwork.name } else {
        $attached = @(Get-VMNetworkAdapter -VMName $lab.Instance.vmName -ErrorAction Stop | Where-Object { $_.SwitchName })
        if ($attached.Count -eq 1) { [string]$attached[0].SwitchName } else { $null }
    }
    $network = Resolve-LabHyperVNetwork -SwitchName $preferredSwitch
    $attached = @(Get-VMNetworkAdapter -VMName $lab.Instance.vmName -ErrorAction Stop | Where-Object { [string]$_.SwitchName -eq [string]$network.Name })
    if ($attached.Count -eq 0) {
        Write-LabInfo "Hostzugriff: binde $($lab.Instance.vmName) an $($network.Name)."
        Add-VMNetworkAdapter -VMName $lab.Instance.vmName -SwitchName $network.Name -Name 'SQL_LAB_HYPERV' -ErrorAction Stop | Out-Null
    }

    Write-LabInfo "Hostzugriff: konfiguriere feste Gast-IP im Netz $($network.Name)."
    $networkReceipt = Initialize-HyperVGuestLabNetwork -VMName $lab.Instance.vmName -ExpectedRunId $lab.Run.runId `
        -ExpectedScopeId $lab.Run.scopeId -Credential $Credential -Network $network -Identity $lab.Run.runId

    Write-LabInfo 'Hostzugriff: SQL-WMI-Provider wird geprüft und bei Bedarf automatisch repariert.'
    $null = Repair-HyperVLabSqlWmiProvider -RunId $RunId -Credential $Credential `
        -FallbackAddress $networkReceipt.Address -StateRoot $lab.StateRoot
    Write-LabInfo 'Hostzugriff: aktiviere SQL-TCP, SQL-Authentifizierung und die Host-beschränkte Firewallregel.'
    $receipt = Invoke-HyperVPowerShellDirect -VMName $lab.Instance.vmName -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId `
        -Credential $Credential -FallbackAddress $networkReceipt.Address -ArgumentList @([string]$lab.Run.runId, [string]$lab.Run.scopeId, $SqlSaPassword, [string]$network.HostAddress, $SqlPort) -ScriptBlock {
            param($ExpectedRunId, $ExpectedScopeId, $SaPassword, $HostAddress, $RequestedSqlPort)
            $ErrorActionPreference = 'Stop'
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
            $plain = $null
            try {
                $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                if ($plain -match '[\s"]') { throw 'HYPERV_LAB_SQL_SA_PASSWORD_COMMAND_LINE_UNSAFE' }
                $instanceRegistryPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
                if (-not (Test-Path -LiteralPath $instanceRegistryPath)) {
                    throw 'HYPERV_LAB_SQL_INSTANCE_REGISTRY_NOT_FOUND: SQL Setup ist noch nicht vollständig registriert; den SQL-Workflow erneut fortsetzen.'
                }
                $instanceMap = Get-ItemProperty -LiteralPath $instanceRegistryPath -ErrorAction Stop
                $instances = @($instanceMap.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })
                if ($instances.Count -eq 0) { throw 'HYPERV_LAB_SQL_INSTANCE_NOT_FOUND' }
                $configured = @()
                for ($index = 0; $index -lt $instances.Count; $index++) {
                    $name = [string]$instances[$index].Name
                    $instanceId = [string]$instances[$index].Value
                    $serviceName = if ($name -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { 'MSSQL$' + $name }
                    $port = [int]$RequestedSqlPort + $index
                    $tcpRoot = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer\SuperSocketNetLib\Tcp"
                    if (Test-Path -LiteralPath $tcpRoot) {
                        Set-ItemProperty -LiteralPath $tcpRoot -Name Enabled -Value 1 -Type DWord -ErrorAction Stop
                        $ipAll = Join-Path $tcpRoot 'IPAll'
                        Set-ItemProperty -LiteralPath $ipAll -Name TcpDynamicPorts -Value '' -ErrorAction Stop
                        Set-ItemProperty -LiteralPath $ipAll -Name TcpPort -Value ([string]$port) -ErrorAction Stop
                    }
                    $serverRoot = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer"
                    Set-ItemProperty -LiteralPath $serverRoot -Name LoginMode -Value 2 -Type DWord -ErrorAction Stop
                    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                    if (-not $service) {
                        throw "HYPERV_LAB_SQL_COMPLETEIMAGE_REQUIRED: SQL-Dienst '$serviceName' fehlt. Zuerst 'SQL CompleteImage ausführen' für diese VM ausführen."
                    }
                    if ($service.Status -eq 'Running') { Restart-Service -Name $serviceName -Force -ErrorAction Stop } else { Start-Service -Name $serviceName -ErrorAction Stop }
                    $configured += [PSCustomObject]@{ name = $name; serviceName = $serviceName; port = $port }
                }
                Start-Sleep -Seconds 3
                $default = @($configured | Where-Object { $_.name -eq 'MSSQLSERVER' } | Select-Object -First 1)[0]
                if (-not $default) { throw 'HYPERV_LAB_SQL_DEFAULT_INSTANCE_REQUIRED' }
                $connection = [System.Data.SqlClient.SqlConnection]::new("Server=localhost,$($default.port);Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;")
                try {
                    $connection.Open()
                    $command = $connection.CreateCommand()
                    $command.CommandText = @'
DECLARE @statement nvarchar(max) =
    N'ALTER LOGIN [sa] ENABLE; ALTER LOGIN [sa] WITH PASSWORD = ' +
    QUOTENAME(@password, '''') +
    N', CHECK_POLICY = ON;';
EXEC sys.sp_executesql @statement;
'@
                    $null = $command.Parameters.Add('@password', [System.Data.SqlDbType]::NVarChar, 128)
                    $command.Parameters['@password'].Value = $plain
                    $null = $command.ExecuteNonQuery()
                }
                finally { if ($connection) { $connection.Dispose() } }
                $ruleName = 'SQL_Server_Lab SQL TCP Host'
                $ports = ($configured.port -join ',')
                $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
                if ($rule) { $rule | Remove-NetFirewallRule -ErrorAction SilentlyContinue }
                New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $ports -RemoteAddress $HostAddress | Out-Null
                [PSCustomObject]@{ runId = $ExpectedRunId; scopeId = $ExpectedScopeId; instances = @($configured); observedAt = [datetime]::UtcNow.ToString('o') }
            }
            finally {
                $plain = $null
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
    $receipt = @($receipt)[-1]
    if (-not $receipt -or [string]$receipt.runId -ne [string]$lab.Run.runId -or [string]$receipt.scopeId -ne [string]$lab.Run.scopeId) {
        throw 'HYPERV_LAB_HOST_SQL_RECEIPT_INVALID'
    }
    $lab.Instance | Add-Member -NotePropertyName labNetwork -NotePropertyValue ([PSCustomObject]@{ name = $networkReceipt.Network; address = $networkReceipt.Address; prefixLength = $networkReceipt.PrefixLength; hostAddress = $network.HostAddress }) -Force
    $lab.Instance | Add-Member -NotePropertyName host -NotePropertyValue ([string]$networkReceipt.Address) -Force
    $lab.Instance | Add-Member -NotePropertyName port -NotePropertyValue $SqlPort -Force
    $passwordHint = if ($usesSeparateSaPassword) { 'Separat festgelegtes SQL-SA-Passwort' } else { 'Gast-Administratorpasswort' }
    $lab.Instance | Add-Member -NotePropertyName hostSqlAccess -NotePropertyValue ([PSCustomObject]@{ state = 'READY'; authentication = 'sql-authentication'; login = 'sa'; passwordHint = $passwordHint; configuredAt = [string]$receipt.observedAt }) -Force
    $instanceReceipt = Get-HyperVLabSqlInstanceReceipt -Lab $lab -Credential $Credential -FallbackAddress $networkReceipt.Address
    $null = Save-HyperVLabSqlInstanceReceipt -Lab $lab -Receipt $instanceReceipt
    Write-LabSuccess "Hostzugriff bereit: $($lab.Instance.host),$SqlPort (SQL-Login sa; Passwort: $passwordHint)."
    return [PSCustomObject]@{ Network = $networkReceipt; Sql = $receipt; ConnectionString = [string]$lab.Instance.connectionString }
}

function Inspect-HyperVLabSqlInstances {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][PSCredential]$Credential, [string]$StateRoot)

    Write-LabInfo 'Schritt 1/2: SQL-Instanzen werden ausschließlich lesend im laufenden Gast geprüft.'
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $fallbackAddress = if ($lab.Instance.labNetwork) {
        if ($lab.Instance.labNetwork.address) { [string]$lab.Instance.labNetwork.address }
        else { Get-LabNetworkGuestAddress -Network $lab.Instance.labNetwork -Identity ([string]$lab.Run.runId) }
    }
    $receipt = Get-HyperVLabSqlInstanceReceipt -Lab $lab -Credential $Credential -FallbackAddress $fallbackAddress
    $instances = Save-HyperVLabSqlInstanceReceipt -Lab $lab -Receipt $receipt
    Write-LabSuccess "Schritt 2/2: $($instances.Count) SQL-Instanz(en) geprüft und Verbindungsdaten aktualisiert."
    return $instances
}

function Repair-HyperVLabSqlWmiProvider {
    <#
    .SYNOPSIS Prüft und repariert den SQL-WMI-Provider im verwalteten Gast.
    .DESCRIPTION Der SQL Server Configuration Manager benötigt die WMI-Klasse
    SqlService. Nach PrepareImage/CompleteImage kann die MOF-Registrierung
    fehlen; in diesem Fall wird ausschließlich die passende lokale SQL-MOF
    kompiliert und der WMI-Dienst im Gast neu gestartet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [string]$FallbackAddress,
        [string]$StateRoot
    )

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') { throw 'HYPERV_LAB_SQL_WMI_VM_MUST_BE_RUNNING' }

    $receipt = Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $Credential `
        -FallbackAddress $FallbackAddress -ArgumentList @([string]$lab.Run.runId, [string]$lab.Run.scopeId) -ScriptBlock {
            param($ExpectedRunId, $ExpectedScopeId)
            $ErrorActionPreference = 'Stop'
            $instanceMap = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop
            $instanceId = [string]$instanceMap.MSSQLSERVER
            if ($instanceId -notmatch '^MSSQL(\d+)\.') { throw 'HYPERV_LAB_SQL_WMI_INSTANCE_VERSION_NOT_FOUND' }
            $major = [int]$Matches[1]
            $namespace = "root\Microsoft\SqlServer\ComputerManagement$major"
            $wasReady = $true
            try { $null = Get-CimClass -Namespace $namespace -ClassName 'SqlService' -ErrorAction Stop }
            catch { $wasReady = $false }
            $mofPath = $null
            if (-not $wasReady) {
                $root = Join-Path ${env:ProgramFiles(x86)} 'Microsoft SQL Server'
                $versionDirectory = Join-Path $root ("{0}0" -f $major)
                $candidates = @(
                    (Join-Path $versionDirectory 'Shared\sqlmgmprovider.mof'),
                    (Join-Path $versionDirectory 'Shared\sqlmgmproviderxpsp2up.mof')
                )
                $mofPath = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)[0]
                if (-not $mofPath) { throw "HYPERV_LAB_SQL_WMI_MOF_NOT_FOUND: $versionDirectory" }
                & "$env:WINDIR\System32\wbem\mofcomp.exe" $mofPath | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "HYPERV_LAB_SQL_WMI_MOFCOMP_FAILED: ExitCode=$LASTEXITCODE" }
                Restart-Service -Name winmgmt -Force -ErrorAction Stop
                Start-Sleep -Seconds 2
                $null = Get-CimClass -Namespace $namespace -ClassName 'SqlService' -ErrorAction Stop
            }
            [PSCustomObject]@{ runId = $ExpectedRunId; scopeId = $ExpectedScopeId; namespace = $namespace; repaired = (-not $wasReady); mofPath = $mofPath; observedAt = [datetime]::UtcNow.ToString('o') }
        }
    $receipt = @($receipt)[-1]
    if (-not $receipt -or [string]$receipt.runId -ne [string]$lab.Run.runId -or [string]$receipt.scopeId -ne [string]$lab.Run.scopeId) {
        throw 'HYPERV_LAB_SQL_WMI_RECEIPT_INVALID'
    }
    $lab.Instance | Add-Member -NotePropertyName sqlWmiProvider -NotePropertyValue $receipt -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
    Write-LabSuccess $(if ($receipt.repaired) { 'SQL-WMI-Provider wurde repariert.' } else { 'SQL-WMI-Provider ist bereits verfügbar.' })
    return $receipt
}

function Wait-HyperVLabSqlCompletionRestart {
    <#
    .SYNOPSIS Wartet nach SQL CompleteImage auf den tatsächlich neuen Gast-Boot.
    .DESCRIPTION Ein SQL-Setup-Rückgabecode 3010 bedeutet nicht, dass TCP,
    Dienste oder WMI bereits nutzbar sind. Die Bootzeit verhindert, dass die
    alte PowerShell-Direct-Sitzung versehentlich als erfolgreicher Neustart
    gezählt wird.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Lab,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][string]$PreviousBootTime,
        [string]$FallbackAddress,
        [ValidateRange(30, 1800)][int]$TimeoutSeconds = 600
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastStatus = 'Neustart noch nicht beobachtet.'
    $lastProgressSeconds = -30
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (($stopwatch.Elapsed.TotalSeconds - $lastProgressSeconds) -ge 30) {
            $lastProgressSeconds = $stopwatch.Elapsed.TotalSeconds
            Write-LabInfo "SQL CompleteImage: warte auf Gast-Neustart ($([int]$stopwatch.Elapsed.TotalSeconds)s/$TimeoutSeconds, $lastStatus)"
        }
        try {
            $probe = Invoke-HyperVPowerShellDirect -VMName ([string]$Lab.Instance.vmName) `
                -ExpectedRunId ([string]$Lab.Run.runId) -ExpectedScopeId ([string]$Lab.Run.scopeId) `
                -Credential $Credential -FallbackAddress $FallbackAddress -ScriptBlock {
                    [PSCustomObject]@{
                        bootTime = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')
                        imageState = [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState -ErrorAction Stop)
                    }
                }
            $probe = @($probe)[-1]
            if ($probe -and [string]$probe.bootTime -ne $PreviousBootTime -and [string]$probe.imageState -eq 'IMAGE_STATE_COMPLETE') {
                $stopwatch.Stop()
                return [PSCustomObject]@{ Ready = $true; BootTime = [string]$probe.bootTime; Duration = $stopwatch.Elapsed; Message = 'SQL CompleteImage-Neustart abgeschlossen.' }
            }
            $lastStatus = if ($probe) { "Bootzeit noch unverändert ($($probe.bootTime))." } else { 'Kein PowerShell-Direct-Resultat.' }
        }
        catch {
            $lastStatus = $_.Exception.Message
        }
        Start-Sleep -Seconds 2
    }
    $stopwatch.Stop()
    return [PSCustomObject]@{ Ready = $false; BootTime = $null; Duration = $stopwatch.Elapsed; Message = "SQL CompleteImage-Neustart Timeout: $lastStatus" }
}

function Complete-HyperVLabSqlImage {
    <#
    .SYNOPSIS Vervollständigt SQL Server in einer geklonten Prepared-Image-VM.
    .DESCRIPTION PrepareImage installiert absichtlich noch keine verwendbare
    Instanz. CompleteImage läuft ausschließlich in der run-eigenen, laufenden
    VM und setzt den MSSQLSERVER-Dienst vor der Nutzung in Betrieb.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [SecureString]$SqlSaPassword,
        [string]$MediaRoot,
        [string]$StateRoot
    )

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    if (-not $lab.Instance.imageArtifactId -or $lab.Instance.sqlCompletion) { throw 'HYPERV_LAB_SQL_COMPLETE_NOT_REQUIRED' }
    $artifact = Get-HyperVImageArtifact -ArtifactId ([string]$lab.Instance.imageArtifactId) -StateRoot $lab.StateRoot
    if (-not $artifact -or [string]$artifact.artifactState -ne 'SQL_PREPARED_SEALED') { throw 'HYPERV_LAB_SQL_PREPARED_IMAGE_REQUIRED' }
    if (-not $MediaRoot) { $MediaRoot = Get-LabMediaRootDefault }
    if (-not $MediaRoot) { throw 'HYPERV_WORKFLOW_MEDIA_ROOT_REQUIRED' }
    # Das Artifact speichert die SQL-Setup-Produktedition (etwa
    # EnterpriseDeveloper); für die ISO-Suche wird daraus der stabile
    # Medien-Schlüssel Enterprise/Eval/Standard abgeleitet.
    $mediaEdition = ConvertTo-HyperVSqlMediaEdition -SqlEdition ([string]$artifact.sql.edition)
    # Nicht nur den historischen kanonischen Pfad verwenden: Die UI erkennt
    # Medien dynamisch in frei organisierten Unterordnern, daher muss
    # CompleteImage dieselbe Auswahlregel nutzen.
    $mediaCandidates = @(Get-HyperVSqlInstallationMediaCandidates -MediaRoot $MediaRoot | Where-Object {
        $_.State -eq 'READY' -and
        [string]$_.SqlVersion -eq [string]$artifact.sql.version -and
        [string]$_.MediaEdition -eq $mediaEdition
    })
    if ($mediaCandidates.Count -eq 0) { throw "HYPERV_LAB_SQL_COMPLETE_MEDIA_NOT_FOUND: SQL $($artifact.sql.version) / $mediaEdition" }
    if ($mediaCandidates.Count -gt 1) { throw "HYPERV_LAB_SQL_COMPLETE_MEDIA_AMBIGUOUS: $($mediaCandidates.MediaId -join ', ')" }
    $media = Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion ([string]$artifact.sql.version) -MediaEdition $mediaEdition -SqlMediaPath ([string]$mediaCandidates[0].MediaId)
    if ($media.HashStatus -ne 'SIDECAR_READY') { throw "HYPERV_LAB_SQL_MEDIA_HASH_REQUIRED: $($media.HashPath)" }
    $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') { throw 'HYPERV_LAB_SQL_COMPLETE_VM_MUST_BE_RUNNING' }
    if (-not $SqlSaPassword) { $SqlSaPassword = $Credential.Password }
    $fallbackAddress = if ($lab.Instance.labNetwork) {
        if ($lab.Instance.labNetwork.address) { [string]$lab.Instance.labNetwork.address }
        else { Get-LabNetworkGuestAddress -Network $lab.Instance.labNetwork -Identity ([string]$lab.Run.runId) }
    }

    if (-not @(Get-VMDvdDrive -VMName $lab.Instance.vmName -ErrorAction Stop | Where-Object { $_.Path -eq $media.IsoPath })) {
        $null = Add-VMDvdDrive -VMName $lab.Instance.vmName -Path $media.IsoPath -ErrorAction Stop
    }
    Write-LabInfo 'Schritt 1/3: SQL-Setup-Medium wird in der run-eigenen VM geprüft.'
    $receipt = Invoke-HyperVPowerShellDirect -VMName $lab.Instance.vmName -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $Credential -FallbackAddress $fallbackAddress -ArgumentList @([string]$lab.Run.runId, [string]$lab.Run.scopeId, $SqlSaPassword) -ScriptBlock {
        param($ExpectedRunId, $ExpectedScopeId, $SaPassword)
        $setup = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object {
            $candidate = Join-Path $_.Root 'setup.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate }
        })
        if ($setup.Count -ne 1) { throw "HYPERV_LAB_SQL_SETUP_MEDIA_NOT_UNIQUE: $($setup.FullName -join ', ')" }
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
        $plainPassword = $null
        try {
            $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            if ($plainPassword -match '[\s"]') { throw 'HYPERV_LAB_SQL_SA_PASSWORD_COMMAND_LINE_UNSAFE' }
            $arguments = @('/Q', '/ACTION=CompleteImage', '/INSTANCEID=MSSQLSERVER', '/INSTANCENAME=MSSQLSERVER', '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"', '/SECURITYMODE=SQL', "/SAPWD=$plainPassword", '/TCPENABLED=1', '/IACCEPTSQLSERVERLICENSETERMS', '/INDICATEPROGRESS')
            $process = Start-Process -FilePath $setup[0].FullName -ArgumentList $arguments -PassThru -NoNewWindow
            if (-not $process.WaitForExit(5400000)) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue; throw 'HYPERV_LAB_SQL_COMPLETE_TIMEOUT' }
            # Setup liefert den Code in älteren Gast-PowerShell-Versionen nicht
            # immer als typisierten Integer. Vor jeder Auswertung normalisieren.
            $exitCode = [int]$process.ExitCode
            if ($exitCode -ne 0 -and $exitCode -ne 3010) { throw "HYPERV_LAB_SQL_COMPLETE_FAILED: ExitCode=$exitCode" }
            $bootTimeBeforeRestart = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')
            if ($exitCode -eq 3010) { & shutdown.exe /r /t 10 /f | Out-Null }
            $service = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
            if ($service -and $exitCode -eq 0 -and $service.Status -ne 'Running') {
                Start-Service -Name MSSQLSERVER -ErrorAction Stop
                $service = Get-Service -Name MSSQLSERVER -ErrorAction Stop
            }
            [PSCustomObject]@{ runId = $ExpectedRunId; scopeId = $ExpectedScopeId; exitCode = $exitCode; bootTimeBeforeRestart = $bootTimeBeforeRestart; serviceName = if ($service) { $service.Name } else { $null }; serviceStatus = if ($service) { [string]$service.Status } else { $null }; completedAt = [datetime]::UtcNow.ToString('o') }
        }
        finally {
            $plainPassword = $null
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
    $receipt = @($receipt)[-1]
    if (-not $receipt -or [string]$receipt.runId -ne [string]$lab.Run.runId -or [int]$receipt.exitCode -notin @(0, 3010) -or (([int]$receipt.exitCode -eq 0) -and $receipt.serviceName -ne 'MSSQLSERVER')) { throw 'HYPERV_LAB_SQL_COMPLETE_RECEIPT_INVALID' }
    if ([int]$receipt.exitCode -eq 3010) {
        Write-LabInfo 'Schritt 2/5: SQL Setup hat einen Neustart angefordert; der automatische Ablauf wartet auf den neuen Gast-Boot.'
        $restarted = Wait-HyperVLabSqlCompletionRestart -Lab $lab -Credential $Credential `
            -PreviousBootTime ([string]$receipt.bootTimeBeforeRestart) -FallbackAddress $fallbackAddress
        if (-not $restarted.Ready) { throw "HYPERV_LAB_SQL_COMPLETE_REBOOT_TIMEOUT: $($restarted.Message)" }
    }
    Write-LabInfo 'Schritt 3/5: SQL-WMI-Provider wird automatisch geprüft und bei Bedarf repariert.'
    $wmiReceipt = Repair-HyperVLabSqlWmiProvider -RunId $RunId -Credential $Credential `
        -FallbackAddress $fallbackAddress -StateRoot $lab.StateRoot
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $lab.StateRoot
    $instanceReceipt = Get-HyperVLabSqlInstanceReceipt -Lab $lab -Credential $Credential -FallbackAddress $fallbackAddress
    $instances = Save-HyperVLabSqlInstanceReceipt -Lab $lab -Receipt $instanceReceipt
    $defaultInstance = @($instances | Where-Object { $_.IsDefault }) | Select-Object -First 1
    if (-not $defaultInstance -or [string]$defaultInstance.ServiceStatus -ne 'Running') {
        throw 'HYPERV_LAB_SQL_COMPLETE_DEFAULT_INSTANCE_NOT_RUNNING'
    }

    $completion = [PSCustomObject]@{
        state = 'COMPLETE'; serviceStatus = [string]$defaultInstance.ServiceStatus
        completedAt = [string]$receipt.completedAt; wmiProvider = $wmiReceipt
    }
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $lab.StateRoot
    $lab.Instance | Add-Member -NotePropertyName sqlCompletion -NotePropertyValue $completion -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection

    $hostAccess = $null
    if ($lab.Instance.labNetwork) {
        Write-LabInfo 'Schritt 4/5: Feste Lab-IP, SQL-TCP und die auf den Host beschränkte Firewallregel werden automatisch eingerichtet.'
        $hostAccess = Enable-HyperVLabHostSqlAccess -RunId $RunId -Credential $Credential `
            -SqlSaPassword $SqlSaPassword -StateRoot $lab.StateRoot
        $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $lab.StateRoot
        $lab.Instance.sqlCompletion | Add-Member -NotePropertyName hostSqlAccess -NotePropertyValue $hostAccess -Force
        Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
    }
    else {
        Write-LabWarning 'Schritt 4/5 übersprungen: Die VM wurde ausdrücklich isoliert erstellt; ein Zugriff des Hosts oder anderer Anwendungen ist damit nicht möglich.'
    }
    Write-LabInfo 'Schritt 5/5: SQL-Dienst, Hauptversion und alle vier Systemdatenbanken werden im echten Gast geprüft.'
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $lab.StateRoot
    $readiness = Wait-HyperVGuestSqlReady -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId) `
        -Credential $Credential -SaPassword $SqlSaPassword -FallbackAddress $fallbackAddress `
        -ExpectedMajorVersion (Get-HyperVSqlMajorVersionFromVersion -SqlVersion ([string]$artifact.sql.version))
    if (-not $readiness.Ready -or [string]$readiness.Status -ne 'SQL_READY_RUN' -or
        [int]$readiness.OnlineSystemDatabases -ne 4) {
        throw 'HYPERV_LAB_SQL_READY_RUN_RECEIPT_INVALID'
    }
    $readinessEvidence = [PSCustomObject]@{
        status = [string]$readiness.Status
        provider = [string]$readiness.Provider
        instanceName = [string]$readiness.InstanceName
        majorVersion = [int]$readiness.MajorVersion
        productVersion = [string]$readiness.ProductVersion
        edition = [string]$readiness.Edition
        onlineSystemDatabases = [int]$readiness.OnlineSystemDatabases
        observedAt = [string]$readiness.ObservedAt
    }
    $lab.Instance.sqlCompletion | Add-Member -NotePropertyName sqlReadiness -NotePropertyValue $readinessEvidence -Force
    $lab.Instance | Add-Member -NotePropertyName sqlReadiness -NotePropertyValue $readinessEvidence -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
    Write-LabSuccess 'SQL Server, WMI, SQL_READY_RUN und – im Labnetz – TCP/IP für Host-Anwendungen sind bereit.'
    return $lab.Instance.sqlCompletion
}

function Stop-HyperVLabEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [string]$StateRoot)
    Write-LabInfo 'Schritt 1/2: Besitz und aktueller Status der Hyper-V-VM werden geprüft.'
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    Write-LabInfo "Schritt 2/2: VM $($lab.Instance.vmName) wird sauber gestoppt."
    $status = Stop-HyperVInstance -VMName $lab.Instance.vmName -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if ([string]$lab.Run.state -eq 'RUNNING') { $null = Set-LabRunState -RunId $RunId -NewState STOPPED -Reason 'Hyper-V-VM gestoppt.' -StateRoot $lab.StateRoot }
    Set-LabProviderSubRunState -RunId $RunId -Provider hyperv -NewState STOPPED -Reason 'Hyper-V-VM gestoppt.' -StateRoot $lab.StateRoot
    return $status
}

function Open-HyperVLabEnvironmentConsole {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [string]$StateRoot)
    Write-LabInfo 'Schritt 1/2: Hyper-V-VM wird für VMConnect geprüft.'
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $status = Get-HyperVInstanceStatus -VMName $lab.Instance.vmName -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if (-not $status.Exists) { throw 'HYPERV_LAB_VM_NOT_FOUND' }
    Write-LabInfo "Schritt 2/2: VMConnect für $($lab.Instance.vmName) wird geöffnet und in den Vordergrund geholt."
    Start-LabVmConnect -VMName $lab.Instance.vmName
    return $status
}
