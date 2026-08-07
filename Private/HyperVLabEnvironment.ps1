<#
.SYNOPSIS
    Erstellt und verwaltet reguläre Hyper-V-Lab-VMs aus Prepared-Images.
.DESCRIPTION
    Ein regulärer Run verwendet ausschließlich ein registriertes, unveränderliches
    SQL_PREPARED_SEALED-Image als Parent. Die VM bleibt nach dem Erstellen aus;
    Start und VMConnect sind separate, sichtbare Benutzeraktionen.
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
        name = $LabName; workflowKind = 'hyperv-lab'; baseKind = 'existing-vm'
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
        $vm = New-HyperVInstance -ParentVhdxPath $parentCopyPath -ParentSha256 $parentHash -RunDirectory $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId -InstanceId $InstanceId -LabName $LabName -MemoryStartupBytes ($MemoryStartupMB * 1MB) -ProcessorCount $ProcessorCount -SwitchName $(if ($labNetwork) { $labNetwork.Name } else { $null })
        $connection = [PSCustomObject]@{
            schemaVersion = 1; instances = @([PSCustomObject]@{
                id = $InstanceId; provider = 'hyperv'; vmName = $vm.VMName; vmId = $vm.VMId
                sqlVersion = $null; sqlEdition = $null; imageArtifactId = $null; host = $null; port = $null
                labNetwork = if ($labNetwork) { [PSCustomObject]@{ name = $labNetwork.Name; subnet = $labNetwork.Subnet; prefixLength = $labNetwork.PrefixLength; hostAddress = $labNetwork.HostAddress } } else { $null }
                baseKind = 'existing-vm'; sourceVMName = $source.VMName; sourceVhdxPath = $source.SourceVhdxPath
                sourceParentCopyPath = $parentCopyPath; sourceParentSha256 = $parentHash
            })
        }
        Write-LabInfo 'Schritt 5/6: Verbindungsdaten und sichere Ressourcenbindung werden gespeichert.'
        Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'connection-info.json') -InputObject $connection
        $null = Set-LabRunState -RunId $run.RunId -NewState SQL_READY -Reason 'Windows-Quell-VM als unveraenderte Basis gebunden.' -StateRoot $run.StateRoot
        $null = Set-LabRunState -RunId $run.RunId -NewState DATABASES_CREATED -Reason 'Keine run-lokalen Datenbanken angefordert.' -StateRoot $run.StateRoot
        $null = Set-LabRunState -RunId $run.RunId -NewState RUNNING -Reason 'Hyper-V-VM erstellt, noch ausgeschaltet.' -StateRoot $run.StateRoot
        $null = Set-LabRunState -RunId $run.RunId -NewState STOPPED -Reason 'Warte auf sichtbaren VM-Start.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState SQL_READY -Reason 'Windows-Quell-VM als unveraenderte Basis gebunden.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState DATABASES_CREATED -Reason 'Keine run-lokalen Datenbanken angefordert.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState RUNNING -Reason 'Hyper-V-VM erstellt, noch ausgeschaltet.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState STOPPED -Reason 'Warte auf sichtbaren VM-Start.' -StateRoot $run.StateRoot
        Write-LabSuccess "Schritt 6/6: VM $($vm.VMName) ist erstellt; die Quell-VM '$($source.VMName)' blieb unveraendert."
        return [PSCustomObject]@{ RunId = $run.RunId; ScopeId = $run.ScopeId; VMName = $vm.VMName; State = 'STOPPED'; SourceVMName = $source.VMName }
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
        [string]$SwitchName,
        [switch]$Isolated,
        [string]$StateRoot
    )

    Write-LabInfo 'Schritt 1/5: Hyper-V-Verfügbarkeit und SQL-Prepared-Image werden geprüft.'
    $availability = Test-HyperVAvailable
    if (-not $availability.Available) { throw "HYPERV_WORKFLOW_UNAVAILABLE: $($availability.Message)" }
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $artifact = Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot
    if (-not $artifact) { throw 'HYPERV_LAB_ARTIFACT_NOT_FOUND' }
    if ([string]$artifact.artifactState -ne 'SQL_PREPARED_SEALED') {
        throw 'HYPERV_LAB_SQL_PREPARED_IMAGE_REQUIRED'
    }
    $labNetwork = Resolve-LabHyperVNetwork -SwitchName $SwitchName -Isolated:$Isolated

    Write-LabInfo 'Schritt 2/5: Workflow-Run und rückgängig ausführbarer Cleanup-Plan werden angelegt.'
    $run = New-LabRunState -StateRoot $StateRoot -Metadata @{
        name = $LabName; workflowKind = 'hyperv-lab'; imageArtifactId = $ArtifactId
        network = if ($labNetwork) { $labNetwork.Name } else { $null }
    } -ProviderSubRuns @([PSCustomObject]@{ id = 'provider-hyperv'; provider = 'hyperv'; instanceIds = @($InstanceId) })
    try {
        $null = New-CleanupPlan -RunDir $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId -ProviderSubRuns @([PSCustomObject]@{ id = 'provider-hyperv'; provider = 'hyperv'; instanceIds = @($InstanceId) })
        $null = Set-LabRunState -RunId $run.RunId -NewState PROVISIONING -Reason 'Hyper-V-Lab wird aus Prepared-Image erstellt.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState PROVISIONING -Reason 'Hyper-V-Lab wird aus Prepared-Image erstellt.' -StateRoot $run.StateRoot
        Write-LabInfo "Schritt 3/5: Differenzierende VM wird aus Image $ArtifactId erstellt."
        $vm = New-HyperVInstance -ImageArtifactId $ArtifactId -RunDirectory $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId -InstanceId $InstanceId -LabName $LabName -MemoryStartupBytes ($MemoryStartupMB * 1MB) -ProcessorCount $ProcessorCount -SwitchName $(if ($labNetwork) { $labNetwork.Name } else { $null }) -StateRoot $run.StateRoot
        $connection = [PSCustomObject]@{
            schemaVersion = 1; instances = @([PSCustomObject]@{
                id = $InstanceId; provider = 'hyperv'; vmName = $vm.VMName; vmId = $vm.VMId
                sqlVersion = [string]$artifact.sql.version; sqlEdition = [string]$artifact.sql.edition
                imageArtifactId = $ArtifactId; host = $null; port = $null
                labNetwork = if ($labNetwork) { [PSCustomObject]@{ name = $labNetwork.Name; subnet = $labNetwork.Subnet; prefixLength = $labNetwork.PrefixLength; hostAddress = $labNetwork.HostAddress } } else { $null }
            })
        }
        Write-LabInfo 'Schritt 4/5: Verbindungsdaten und Ressourcenbindung werden gespeichert.'
        Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'connection-info.json') -InputObject $connection
        # Das Prepared-Image enthält SQL bereits. Der Run wird bewusst ausgeschaltet
        # hinterlegt, bis der Benutzer den sichtbaren Start anstößt.
        $null = Set-LabRunState -RunId $run.RunId -NewState SQL_READY -Reason 'Prepared-Image gebunden.' -StateRoot $run.StateRoot
        $null = Set-LabRunState -RunId $run.RunId -NewState DATABASES_CREATED -Reason 'Keine run-lokalen Datenbanken angefordert.' -StateRoot $run.StateRoot
        $null = Set-LabRunState -RunId $run.RunId -NewState RUNNING -Reason 'Hyper-V-VM erstellt, noch ausgeschaltet.' -StateRoot $run.StateRoot
        $null = Set-LabRunState -RunId $run.RunId -NewState STOPPED -Reason 'Warte auf sichtbaren VM-Start.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState SQL_READY -Reason 'Prepared-Image gebunden.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState DATABASES_CREATED -Reason 'Keine run-lokalen Datenbanken angefordert.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState RUNNING -Reason 'Hyper-V-VM erstellt, noch ausgeschaltet.' -StateRoot $run.StateRoot
        Set-LabProviderSubRunState -RunId $run.RunId -Provider hyperv -NewState STOPPED -Reason 'Warte auf sichtbaren VM-Start.' -StateRoot $run.StateRoot
        Write-LabSuccess "Schritt 5/5: VM $($vm.VMName) ist erstellt und bewusst ausgeschaltet."
        return [PSCustomObject]@{ RunId = $run.RunId; ScopeId = $run.ScopeId; VMName = $vm.VMName; State = 'STOPPED'; ArtifactId = $ArtifactId }
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
        [ValidateSet('user', 'generated')][string]$PasswordSource = 'user',
        [ValidateRange(60, 3600)][int]$TimeoutSeconds = 900,
        [string]$MediaRoot,
        [string]$StateRoot
    )

    Write-LabInfo 'Schritt 1/6: Prepared-Image-Klon und isolierte Child-VHDX werden geprüft.'
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    if (-not $lab.Instance.imageArtifactId) { throw 'HYPERV_LAB_UNATTENDED_REQUIRES_PREPARED_IMAGE' }
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
    $unattend = $null
    try {
        $unattend = New-HyperVSqlOobeUnattendXml -AdministratorPassword $AdministratorPassword
        Write-LabInfo 'Schritt 3/6: Unattend.xml wird ausschließlich in die Child-VHDX injiziert.'
        Set-HyperVSqlOfflineUnattend -VhdxPath $vhdxPath -MountRoot (Join-Path $lab.RunDirectory 'offline-oobe-mount') -UnattendXml $unattend
    }
    finally { $unattend = $null }

    $lab.Instance | Add-Member -NotePropertyName oobeAutomation -NotePropertyValue ([PSCustomObject]@{
        status = 'RUNNING'; passwordSource = $PasswordSource; passwordStorage = 'host-dpapi'
        answerMedia = 'run-child-vhdx'; startedAt = Get-LabTimestamp
    }) -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection

    Write-LabInfo 'Schritt 4/6: VM wird gestartet; OOBE, Sprache, Region und Tastatur laufen unbeaufsichtigt.'
    $null = Start-HyperVLabEnvironment -RunId $RunId -StateRoot $lab.StateRoot
    $ready = Wait-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId `
        -ExpectedScopeId $lab.Run.scopeId -Credential $credential -TimeoutSeconds $TimeoutSeconds
    if (-not $ready.Ready) { throw "HYPERV_LAB_UNATTENDED_OOBE_TIMEOUT: $($ready.Message)" }

    Write-LabInfo 'Schritt 5/6: OOBE-Artefakte werden im Gast entfernt und die regionale Konfiguration wird geprüft.'
    $receipt = Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId `
        -ExpectedScopeId $lab.Run.scopeId -Credential $credential -ArgumentList @([string]$lab.Run.runId) -ScriptBlock {
            param($ExpectedRunId)
            $ErrorActionPreference = 'Stop'
            Set-WinHomeLocation -GeoId 94
            Set-WinSystemLocale -SystemLocale 'de-DE'
            Set-Culture -CultureInfo 'de-DE'
            Set-WinUILanguageOverride -Language 'en-US'
            Set-WinDefaultInputMethodOverride -InputTip '0407:00000407'
            Set-TimeZone -Id 'W. Europe Standard Time'
            Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend.xml" -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend\Unattend.xml" -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$env:WINDIR\Setup\Scripts\SetupComplete.cmd" -Force -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                runId = $ExpectedRunId
                imageState = [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState)
                observedAt = [datetime]::UtcNow.ToString('o')
            }
        }
    $receipt = @($receipt)[-1]
    if (-not $receipt -or [string]$receipt.runId -ne [string]$lab.Run.runId -or [string]$receipt.imageState -ne 'IMAGE_STATE_COMPLETE') {
        throw 'HYPERV_LAB_UNATTENDED_OOBE_RECEIPT_INVALID'
    }
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $lab.StateRoot
    $lab.Instance | Add-Member -NotePropertyName oobeAutomation -NotePropertyValue ([PSCustomObject]@{
        status = 'COMPLETED'; passwordSource = $PasswordSource; passwordStorage = 'host-dpapi'
        answerMedia = 'guest-scrubbed'; completedAt = [string]$receipt.observedAt
    }) -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection

    if ($lab.Instance.persistentStorage -and [string]$lab.Instance.persistentStorage.state -eq 'ATTACHED_PENDING_INITIALIZATION') {
        Write-LabInfo 'Schritt 6/6a: Eigene Data-Root-VHDX wird im Gast initialisiert.'
        $null = Initialize-HyperVLabPersistentData -RunId $RunId -Credential $credential -StateRoot $lab.StateRoot
    }
    Write-LabInfo 'Schritt 6/6b: SQL CompleteImage wird in der laufenden Klon-VM ausgeführt.'
    $sqlCompletion = Complete-HyperVLabSqlImage -RunId $RunId -Credential $credential -SqlSaPassword $AdministratorPassword -MediaRoot $MediaRoot -StateRoot $lab.StateRoot
    $hostAccess = if ($lab.Instance.labNetwork) { Enable-HyperVLabHostSqlAccess -RunId $RunId -Credential $credential -SqlSaPassword $AdministratorPassword -StateRoot $lab.StateRoot } else { $null }
    Write-LabSuccess 'Unbeaufsichtigte OOBE, SQL CompleteImage und der Host-SSMS-Zugriff sind abgeschlossen.'
    return [PSCustomObject]@{ RunId = $RunId; OobeState = 'COMPLETED'; SqlCompletion = $sqlCompletion; HostSqlAccess = $hostAccess; PasswordSource = $PasswordSource }
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
        GuestPath = 'D:\SQLData'; DriveLetter = 'D'; FileSystem = 'NTFS'; AllocationUnitKB = 64; VolumeLabel = 'SQLLAB_DATA'
    }
    $allDrives = @($managed.Identity.additionalDrives) + @($drive)
    $notes = ConvertTo-HyperVLabNotes -RunId $lab.Run.runId -ScopeId $lab.Run.scopeId -InstanceId ([string]$lab.Instance.id) -ChildVhdxPath ([string]$managed.Identity.childVhdxPath) -AdditionalDrives $allDrives
    $null = Add-VMHardDiskDrive -VMName $lab.Instance.vmName -ControllerType SCSI -ControllerNumber 0 -Path $storage.HyperVVhdxPath -ErrorAction Stop
    $null = Set-VM -VMName $lab.Instance.vmName -Notes $notes -AutomaticCheckpointsEnabled $false -ErrorAction Stop
    $lab.Instance | Add-Member -NotePropertyName persistentStorage -NotePropertyValue ([PSCustomObject]@{ mode = 'data-root-vhdx'; root = [string]$storage.SqlRoot; hostPath = [string]$storage.HyperVVhdxPath; guestPath = 'D:\SQLData'; state = 'ATTACHED_PENDING_INITIALIZATION' }) -Force
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
    $lab.Instance.persistentStorage.state = 'READY'
    $lab.Instance.persistentStorage.initializedAt = Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
    Write-LabSuccess 'Persistenter Hyper-V-Datenträger ist im Gast als D:\SQLData bereit.'
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
    param([Parameter(Mandatory)]$Lab, [Parameter(Mandatory)][PSCredential]$Credential)

    $managed = Get-HyperVManagedVM -VMName ([string]$Lab.Instance.vmName) -ExpectedRunId $Lab.Run.runId -ExpectedScopeId $Lab.Run.scopeId
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') { throw 'HYPERV_LAB_SQL_INSPECTION_VM_MUST_BE_RUNNING' }
    $receipt = Invoke-HyperVPowerShellDirect -VMName $Lab.Instance.vmName -ExpectedRunId $Lab.Run.runId -ExpectedScopeId $Lab.Run.scopeId -Credential $Credential -ArgumentList @([string]$Lab.Run.runId, [string]$Lab.Run.scopeId) -ScriptBlock {
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
            "Server=$hostServer;Database=master;User ID=sa;Password=<Gast-Administratorpasswort>;Encrypt=True;TrustServerCertificate=True;"
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
    Gastfirewall auf den Hyper-V-Host und setzt SQL-Authentifizierung mit dem
    bereits bekannten Gast-Administratorpasswort als SA-Passwort.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [SecureString]$SqlSaPassword,
        [string]$SwitchName,
        [string]$StateRoot
    )

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') { throw 'HYPERV_LAB_HOST_SQL_VM_MUST_BE_RUNNING' }
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

    Write-LabInfo 'Hostzugriff: aktiviere SQL-TCP, SQL-Authentifizierung und die Host-beschränkte Firewallregel.'
    $receipt = Invoke-HyperVPowerShellDirect -VMName $lab.Instance.vmName -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId `
        -Credential $Credential -FallbackAddress $networkReceipt.Address -ArgumentList @([string]$lab.Run.runId, [string]$lab.Run.scopeId, $SqlSaPassword, [string]$network.HostAddress) -ScriptBlock {
            param($ExpectedRunId, $ExpectedScopeId, $SaPassword, $HostAddress)
            $ErrorActionPreference = 'Stop'
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
            $plain = $null
            try {
                $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                if ($plain -match '[\s"]') { throw 'HYPERV_LAB_SQL_SA_PASSWORD_COMMAND_LINE_UNSAFE' }
                $instanceMap = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop
                $instances = @($instanceMap.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })
                if ($instances.Count -eq 0) { throw 'HYPERV_LAB_SQL_INSTANCE_NOT_FOUND' }
                $configured = @()
                for ($index = 0; $index -lt $instances.Count; $index++) {
                    $name = [string]$instances[$index].Name
                    $instanceId = [string]$instances[$index].Value
                    $serviceName = if ($name -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { 'MSSQL$' + $name }
                    $port = 1433 + $index
                    $tcpRoot = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer\SuperSocketNetLib\Tcp"
                    if (Test-Path -LiteralPath $tcpRoot) {
                        Set-ItemProperty -LiteralPath $tcpRoot -Name Enabled -Value 1 -Type DWord -ErrorAction Stop
                        $ipAll = Join-Path $tcpRoot 'IPAll'
                        Set-ItemProperty -LiteralPath $ipAll -Name TcpDynamicPorts -Value '' -ErrorAction Stop
                        Set-ItemProperty -LiteralPath $ipAll -Name TcpPort -Value ([string]$port) -ErrorAction Stop
                    }
                    $serverRoot = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer"
                    Set-ItemProperty -LiteralPath $serverRoot -Name LoginMode -Value 2 -Type DWord -ErrorAction Stop
                    $service = Get-Service -Name $serviceName -ErrorAction Stop
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
                    $command.CommandText = 'ALTER LOGIN [sa] ENABLE; ALTER LOGIN [sa] WITH PASSWORD = @password, CHECK_POLICY = ON;'
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
    $lab.Instance | Add-Member -NotePropertyName port -NotePropertyValue 1433 -Force
    $lab.Instance | Add-Member -NotePropertyName hostSqlAccess -NotePropertyValue ([PSCustomObject]@{ state = 'READY'; authentication = 'sql-authentication'; login = 'sa'; passwordHint = 'Gast-Administratorpasswort'; configuredAt = [string]$receipt.observedAt }) -Force
    $instanceReceipt = Get-HyperVLabSqlInstanceReceipt -Lab $lab -Credential $Credential
    $null = Save-HyperVLabSqlInstanceReceipt -Lab $lab -Receipt $instanceReceipt
    Write-LabSuccess "Hostzugriff bereit: $($lab.Instance.host),1433 (SQL-Login sa; Passwort = Gast-Administratorpasswort)."
    return [PSCustomObject]@{ Network = $networkReceipt; Sql = $receipt; ConnectionString = [string]$lab.Instance.connectionString }
}

function Inspect-HyperVLabSqlInstances {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][PSCredential]$Credential, [string]$StateRoot)

    Write-LabInfo 'Schritt 1/2: SQL-Instanzen werden ausschließlich lesend im laufenden Gast geprüft.'
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $receipt = Get-HyperVLabSqlInstanceReceipt -Lab $lab -Credential $Credential
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
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][PSCredential]$Credential, [string]$StateRoot)

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') { throw 'HYPERV_LAB_SQL_WMI_VM_MUST_BE_RUNNING' }

    $receipt = Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $Credential `
        -ArgumentList @([string]$lab.Run.runId, [string]$lab.Run.scopeId) -ScriptBlock {
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

    if (-not @(Get-VMDvdDrive -VMName $lab.Instance.vmName -ErrorAction Stop | Where-Object { $_.Path -eq $media.IsoPath })) {
        $null = Add-VMDvdDrive -VMName $lab.Instance.vmName -Path $media.IsoPath -ErrorAction Stop
    }
    Write-LabInfo 'Schritt 1/3: SQL-Setup-Medium wird in der run-eigenen VM geprüft.'
    $receipt = Invoke-HyperVPowerShellDirect -VMName $lab.Instance.vmName -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $Credential -ArgumentList @([string]$lab.Run.runId, [string]$lab.Run.scopeId, $SqlSaPassword) -ScriptBlock {
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
            if ($process.ExitCode -notin @(0, 3010)) { throw "HYPERV_LAB_SQL_COMPLETE_FAILED: ExitCode=$($process.ExitCode)" }
            if ($process.ExitCode -eq 3010) { & shutdown.exe /r /t 10 /f | Out-Null }
            $service = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
            if ($service -and $process.ExitCode -eq 0 -and $service.Status -ne 'Running') {
                Start-Service -Name MSSQLSERVER -ErrorAction Stop
                $service = Get-Service -Name MSSQLSERVER -ErrorAction Stop
            }
            [PSCustomObject]@{ runId = $ExpectedRunId; scopeId = $ExpectedScopeId; exitCode = $process.ExitCode; serviceName = if ($service) { $service.Name } else { $null }; serviceStatus = if ($service) { [string]$service.Status } else { $null }; completedAt = [datetime]::UtcNow.ToString('o') }
        }
        finally {
            $plainPassword = $null
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
    $receipt = @($receipt)[-1]
    if (-not $receipt -or [string]$receipt.runId -ne [string]$lab.Run.runId -or [int]$receipt.exitCode -notin @(0, 3010) -or (([int]$receipt.exitCode -eq 0) -and $receipt.serviceName -ne 'MSSQLSERVER')) { throw 'HYPERV_LAB_SQL_COMPLETE_RECEIPT_INVALID' }
    Write-LabInfo 'Schritt 2/3: SQL CompleteImage wurde bestätigt; Verbindungsdaten werden aktualisiert.'
    $lab.Instance | Add-Member -NotePropertyName sqlCompletion -NotePropertyValue ([PSCustomObject]@{ state = if ([int]$receipt.exitCode -eq 3010) { 'REBOOT_REQUIRED' } else { 'COMPLETE' }; serviceStatus = [string]$receipt.serviceStatus; completedAt = [string]$receipt.completedAt }) -Force
    if ([int]$receipt.exitCode -eq 0) {
        $null = Repair-HyperVLabSqlWmiProvider -RunId $RunId -Credential $Credential -StateRoot $lab.StateRoot
        $instanceReceipt = Get-HyperVLabSqlInstanceReceipt -Lab $lab -Credential $Credential
        $null = Save-HyperVLabSqlInstanceReceipt -Lab $lab -Receipt $instanceReceipt
    }
    else {
        Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
    }
    Write-LabSuccess 'Schritt 3/3: SQL Server CompleteImage ist ausgeführt; MSSQLSERVER ist in dieser Lab-VM eingerichtet.'
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
