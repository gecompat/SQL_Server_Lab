#Requires -Version 7.2
<#
.SYNOPSIS
    Erzeugt einen isolierten Legacy-SQL-Kandidaten und schliesst die reale HVR-008-Abnahme.
.DESCRIPTION
    Verwendet genau einen bereiten Windows-SQL-2022-Slot der geschuetzten
    automatisierten Testgruppe ausschliesslich als ausgeschaltete Kopierquelle.
    Aus dessen OS-Disk entsteht ausserhalb registrierter Lab_Data-Roots ein
    eigenstaendiger, eindeutig gebundener Legacy-Run. Der Klon erhaelt vor dem
    Wiederanlauf der Testgruppe eine eigene deterministische Lab-IP.

    Danach fuehrt der vorhandene HVR-008-Runner die journalisierte Migration in
    den registrierten Default-Data-Root mit zwei Gast-/SQL-Neustartnachweisen
    aus. Nur bei vollstaendig erfolgreicher Abnahme werden Kandidat und
    temporaerer State entfernt. Bei Fehlern bleibt der Kandidat fuer Recovery
    erhalten; die geschuetzte Testgruppe wird in jedem Fall wieder gestartet.
.PARAMETER TimeoutSeconds
    Timeout fuer Gruppen-, Gast- und SQL-Bereitschaft.
#>
[CmdletBinding()]
param(
    [ValidateRange(60, 3600)][int]$TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$acceptancePath = Join-Path $PSScriptRoot 'Invoke-HyperVResourceMigrationAcceptance.ps1'
$module = $null
$inventory = $null
$legacyStateRoot = $null
$candidateRunId = $null
$candidateVMName = $null
$candidateAddress = $null
$groupStopped = $false
$candidateNetworkIsolated = $false
$phase = 'preflight'
$failure = $null
$groupRestoreFailure = $null
$groupTimeoutSeconds = [Math]::Min(600, $TimeoutSeconds)

function Test-LegacySqlBootstrapAdministrator {
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-LegacySqlBootstrapStateRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedVolumeRoot
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $resolvedVolumeRoot = [IO.Path]::GetFullPath($ExpectedVolumeRoot).TrimEnd('\', '/')
    $parent = [IO.Directory]::GetParent($resolvedPath).FullName.TrimEnd('\', '/')
    $leaf = [IO.Path]::GetFileName($resolvedPath)
    if (-not $parent.Equals($resolvedVolumeRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notmatch '^SqlServerLab-Legacy-Sql-Acceptance-[a-f0-9]{8}$') {
        throw 'HVR008_SQL_BOOTSTRAP_STATE_SCOPE_INVALID'
    }
    $resolvedPath
}

function Import-LegacySqlBootstrapModule {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -PassThru -ErrorAction Stop
}

try {
    if (-not (Test-LegacySqlBootstrapAdministrator)) {
        throw 'HVR008_SQL_BOOTSTRAP_ELEVATION_REQUIRED'
    }
    $module = Import-LegacySqlBootstrapModule
    $inventory = & $module {
        $stateRoot = Get-LabStateRoot
        $dataRoot = Get-LabDataRootDefault
        if (-not $dataRoot) { throw 'HVR008_SQL_BOOTSTRAP_DATA_ROOT_REQUIRED' }
        $configuration = Get-LabStorageConfiguration -DataRoot $dataRoot
        if (-not (Test-LabDataRootOwnership -DataRoot $dataRoot -ControllerId ([string]$configuration.ControllerId))) {
            throw 'HVR008_SQL_BOOTSTRAP_DATA_ROOT_OWNERSHIP_INVALID'
        }
        $registry = Get-LabTestEnvironmentRegistry
        $status = Get-LabAutomatedTestEnvironmentStatus -StateRoot $stateRoot
        if ([string]$status.GroupStatus -ne 'READY') {
            throw 'HVR008_SQL_BOOTSTRAP_TEST_GROUP_NOT_READY'
        }
        $readyKeys = @($status.Entries | Where-Object StatusCode -eq 'READY' | ForEach-Object Key)
        $sources = @($registry.environments | Where-Object {
            [string]$_.platform -eq 'windows' -and [string]$_.sqlVersion -eq '2022' -and
            [string]$_.runId -and [string]$_.key -in $readyKeys
        })
        if ($sources.Count -ne 1) { throw 'HVR008_SQL_BOOTSTRAP_EXACT_SOURCE_REQUIRED' }
        $source = $sources[0]
        $lab = Get-HyperVLabWorkflowRun -RunId ([string]$source.runId) -StateRoot $stateRoot
        $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) `
            -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId)
        if (-not $managed -or [string]$managed.VM.State -ne 'Running') {
            throw 'HVR008_SQL_BOOTSTRAP_SOURCE_VM_NOT_RUNNING'
        }
        if (@(Get-VMSnapshot -VM $managed.VM -ErrorAction Stop).Count -ne 0) {
            throw 'HVR008_SQL_BOOTSTRAP_SOURCE_HAS_CHECKPOINTS'
        }
        $disks = @(Get-VMHardDiskDrive -VM $managed.VM -ErrorAction Stop)
        $sourceDisk = @($disks | Where-Object {
            [string]::Equals([IO.Path]::GetFullPath([string]$_.Path),
                [IO.Path]::GetFullPath([string]$managed.Identity.childVhdxPath),
                [StringComparison]::OrdinalIgnoreCase)
        })
        if ($sourceDisk.Count -ne 1) { throw 'HVR008_SQL_BOOTSTRAP_SOURCE_OS_DISK_INVALID' }
        $switches = @(Get-VMNetworkAdapter -VM $managed.VM -ErrorAction Stop | ForEach-Object SwitchName |
            Where-Object { $_ } | Sort-Object -Unique)
        if ($switches.Count -ne 1) { throw 'HVR008_SQL_BOOTSTRAP_SOURCE_SWITCH_INVALID' }
        $guestSecret = Get-LabSecret -Path $lab.RunDirectory -Name 'guest-administrator-password'
        $saSecret = Get-LabSecret -Path $lab.RunDirectory -Name 'generated-sql-sa-password'
        if (-not $saSecret) { $saSecret = Get-LabSecret -Path $lab.RunDirectory -Name 'sa-password' }
        if (-not $guestSecret -or -not $saSecret) { throw 'HVR008_SQL_BOOTSTRAP_SOURCE_SECRETS_REQUIRED' }
        [PSCustomObject]@{
            ProductionStateRoot=$stateRoot; DataRoot=[IO.Path]::GetFullPath($dataRoot).TrimEnd('\', '/')
            SourceRunId=[string]$lab.Run.runId; SourceScopeId=[string]$lab.Run.scopeId
            SourceVMName=[string]$managed.VM.Name; SourceDiskPath=[IO.Path]::GetFullPath([string]$sourceDisk[0].Path)
            SourceDiskBytes=[long](Get-Item -LiteralPath ([string]$sourceDisk[0].Path) -Force).Length
            SwitchName=[string]$switches[0]; GuestSecret=$guestSecret; SaSecret=$saSecret
            SourceComputerName=[string]$lab.Instance.windowsProvisioning.computerName
        }
    }

    $token = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $volumeRoot = [IO.Path]::GetPathRoot([string]$inventory.DataRoot)
    $legacyStateRoot = Assert-LegacySqlBootstrapStateRoot `
        -Path (Join-Path $volumeRoot "SqlServerLab-Legacy-Sql-Acceptance-$token") `
        -ExpectedVolumeRoot $volumeRoot
    if (Test-Path -LiteralPath $legacyStateRoot) { throw 'HVR008_SQL_BOOTSTRAP_STATE_COLLISION' }
    $driveName = [IO.Path]::GetPathRoot($legacyStateRoot).TrimEnd(':\')
    $drive = Get-PSDrive -Name $driveName -ErrorAction Stop
    $requiredBytes = [long]([Math]::Max(8GB, [double]$inventory.SourceDiskBytes * 2.2))
    if ([long]$drive.Free -lt $requiredBytes) { throw 'HVR008_SQL_BOOTSTRAP_CAPACITY_INSUFFICIENT' }

    $phase = 'create-state'
    $fixture = & $module {
        param($Root, $Token, $GuestSecret, $SaSecret)
        $providerSubRuns = @([PSCustomObject]@{ id='provider-hyperv'; provider='hyperv'; instanceIds=@('primary') })
        $run = New-LabRunState -StateRoot $Root -Metadata @{
            name="HVR008 Legacy SQL Acceptance $Token"; workflowKind='hyperv-lab'; workload='sql';
            sqlVersion='2022'; source='isolated-acceptance-bootstrap'; autostart='off'
        } -ProviderSubRuns $providerSubRuns
        $null = New-CleanupPlan -RunDir $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId `
            -ProviderSubRuns $providerSubRuns
        Save-LabSecret -Path $run.RunDir -Name 'guest-administrator-password' -Secret $GuestSecret
        Save-LabSecret -Path $run.RunDir -Name 'generated-sql-sa-password' -Secret $SaSecret
        $run
    } $legacyStateRoot $token $inventory.GuestSecret $inventory.SaSecret
    $candidateRunId = [string]$fixture.RunId
    $candidateVMName = "SqlLab-HVR008-$($candidateRunId.Replace('-', '').Substring(0, 8))"
    $candidateRunDirectory = [string]$fixture.RunDir
    $resourceRoot = Join-Path $candidateRunDirectory 'resources\hyperv'
    $candidateDisk = Join-Path $resourceRoot "$candidateVMName.vhdx"
    $candidateVMPath = Join-Path $resourceRoot 'vm'

    $phase = 'stop-protected-group'
    $stopResult = Stop-SqlServerLabAutomatedTestEnvironment `
        -StateRoot ([string]$inventory.ProductionStateRoot) -Force -Confirm:$false
    if ([string]$stopResult.Status -ne 'STOPPED' -or [int]$stopResult.Errors -ne 0) {
        throw 'HVR008_SQL_BOOTSTRAP_GROUP_STOP_FAILED'
    }
    $groupStopped = $true
    $sourceVM = Get-VM -Name ([string]$inventory.SourceVMName) -ErrorAction Stop
    if ([string]$sourceVM.State -ne 'Off') { throw 'HVR008_SQL_BOOTSTRAP_SOURCE_NOT_OFF' }

    $phase = 'clone-source'
    & $module {
        param($RunDirectory, $DiskPath, $VMName)
        $null = Add-CleanupStep -RunDir $RunDirectory -ResourceType vhdx -ResourceId $DiskPath `
            -Action remove -Provider hyperv -ProviderSubRunId provider-hyperv `
            -Compensation "Remove isolated HVR-008 SQL disk for $VMName"
        $null = Add-CleanupStep -RunDir $RunDirectory -ResourceType vm -ResourceId $VMName `
            -Action remove -Provider hyperv -ProviderSubRunId provider-hyperv `
            -Compensation "Remove isolated HVR-008 SQL VM $VMName"
    } $candidateRunDirectory $candidateDisk $candidateVMName
    New-Item -Path $resourceRoot -ItemType Directory -Force | Out-Null
    Convert-VHD -Path ([string]$inventory.SourceDiskPath) -DestinationPath $candidateDisk `
        -VHDType Dynamic -ErrorAction Stop
    $candidateDiskInfo = Get-VHD -Path $candidateDisk -ErrorAction Stop
    if ($candidateDiskInfo.ParentPath) { throw 'HVR008_SQL_BOOTSTRAP_CLONE_NOT_STANDALONE' }
    $candidateVM = New-VM -Name $candidateVMName -Generation 2 -MemoryStartupBytes 4GB `
        -VHDPath $candidateDisk -Path $candidateVMPath -SwitchName ([string]$inventory.SwitchName) -ErrorAction Stop
    Set-VM -VM $candidateVM -ProcessorCount 2 -AutomaticCheckpointsEnabled $false `
        -CheckpointType Disabled -AutomaticStartAction Nothing -SmartPagingFilePath $resourceRoot `
        -SnapshotFileLocation $resourceRoot -ErrorAction Stop
    Set-VMMemory -VM $candidateVM -DynamicMemoryEnabled $true -MinimumBytes 2GB `
        -StartupBytes 4GB -MaximumBytes 8GB -ErrorAction Stop
    Set-VMFirmware -VM $candidateVM -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -ErrorAction Stop
    $notes = & $module {
        param($RunId, $ScopeId, $DiskPath)
        ConvertTo-HyperVLabNotes -RunId $RunId -ScopeId $ScopeId -InstanceId primary -ChildVhdxPath $DiskPath
    } $candidateRunId ([string]$fixture.ScopeId) $candidateDisk
    Set-VM -VM $candidateVM -Notes $notes -ErrorAction Stop

    $phase = 'isolate-candidate-network'
    Start-VM -VM $candidateVM -ErrorAction Stop | Out-Null
    $credential = [PSCredential]::new('Administrator', $inventory.GuestSecret)
    $networkReceipt = & $module {
        param($VMName, $RunId, $ScopeId, [PSCredential]$Credential, $Timeout)
        $ready = Wait-HyperVPowerShellDirect -VMName $VMName -ExpectedRunId $RunId `
            -ExpectedScopeId $ScopeId -Credential $Credential -TimeoutSeconds $Timeout
        if (-not $ready.Ready) { throw 'HVR008_SQL_BOOTSTRAP_GUEST_NOT_READY' }
        $network = Resolve-LabHyperVNetwork
        Initialize-HyperVGuestLabNetwork -VMName $VMName -ExpectedRunId $RunId `
            -ExpectedScopeId $ScopeId -Credential $Credential -Network $network -Identity $RunId
    } $candidateVMName $candidateRunId ([string]$fixture.ScopeId) $credential $TimeoutSeconds
    $candidateAddress = [string]$networkReceipt.Address
    $candidateNetworkIsolated = $true
    $sqlReceipt = & $module {
        param($Address, $SaSecret, $Timeout)
        Wait-SqlReady -HostName $Address -Port 1433 -SaPassword $SaSecret `
            -TimeoutSeconds $Timeout -ExpectedMajorVersion 16
    } $candidateAddress $inventory.SaSecret $TimeoutSeconds
    if (-not $sqlReceipt.Ready -or [int]$sqlReceipt.MajorVersion -ne 16) {
        throw 'HVR008_SQL_BOOTSTRAP_SQL_NOT_READY'
    }

    $phase = 'persist-legacy-contract'
    & $module {
        param($Root, $RunId, $ScopeId, $VMName, $VMId, $Address, $ComputerName)
        $runDirectory = Join-Path (Join-Path $Root 'runs') $RunId
        $connection = [PSCustomObject]@{
            contractVersion='0.1.0'; runId=$RunId; scopeId=$ScopeId; generatedAt=Get-LabTimestamp
            instances=@([PSCustomObject]@{
                id='primary'; provider='hyperv'; workload='sql'; sqlVersion='2022'; vmName=$VMName; vmId=$VMId
                host=$Address; port=1433; autostart='off'
                windowsProvisioning=[PSCustomObject]@{
                    state='COMPLETE'; computerName=$ComputerName; imageState='IMAGE_STATE_COMPLETE'
                }
                hostSqlAccess=[PSCustomObject]@{ state='READY'; host=$Address; port=1433; observedAt=Get-LabTimestamp }
            })
        }
        Write-LabArtifactJsonAtomic -Path (Join-Path $runDirectory 'connection-info.json') -InputObject $connection
        $state = Get-LabRunState -RunId $RunId -StateRoot $Root
        $state.instances = @([PSCustomObject]@{ id='primary'; provider='hyperv'; resourceId=$VMId; name=$VMName })
        Write-LabArtifactJsonAtomic -Path (Join-Path $runDirectory 'run-state.json') -InputObject $state
        foreach ($next in @('PROVISIONING','SQL_READY','DATABASES_CREATED','RUNNING')) {
            Set-LabRunState -RunId $RunId -NewState $next -Reason 'Isolierter HVR-008-Legacy-SQL-Kandidat' -StateRoot $Root
            Set-LabProviderSubRunState -RunId $RunId -Provider hyperv -NewState $next `
                -Reason 'Isolierter HVR-008-Legacy-SQL-Kandidat' -StateRoot $Root
        }
    } $legacyStateRoot $candidateRunId ([string]$fixture.ScopeId) $candidateVMName `
        ([string]$candidateVM.Id) $candidateAddress ([string]$inventory.SourceComputerName)

    $phase = 'restore-protected-group'
    $restoreResult = Start-SqlServerLabAutomatedTestEnvironment `
        -StateRoot ([string]$inventory.ProductionStateRoot) -TimeoutSeconds $groupTimeoutSeconds -Force -Confirm:$false
    if ([string]$restoreResult.Status -ne 'READY' -or [int]$restoreResult.Errors -ne 0 -or
        [string]$restoreResult.Export.GroupStatus -ne 'READY') {
        throw 'HVR008_SQL_BOOTSTRAP_GROUP_RESTORE_FAILED'
    }
    $groupStopped = $false

    $phase = 'migrate-and-restart'
    $acceptance = & $acceptancePath -RunId $candidateRunId -ExpectedVMName $candidateVMName `
        -LegacyStateRoot $legacyStateRoot -DataRoot ([string]$inventory.DataRoot) `
        -ReadinessTimeoutSeconds $TimeoutSeconds -ExpectedInitialVMState Running `
        -RequireSqlReadiness -ExpectedSqlMajorVersion 16 -AdoptLegacySqlIdentity -Confirm:$false
    if ([string]$acceptance.Status -ne 'PASS' -or [int]$acceptance.RestartEvidenceCount -ne 2 -or
        [int]$acceptance.SqlRestartEvidenceCount -ne 2 -or -not [bool]$acceptance.BindingCommitted) {
        throw 'HVR008_SQL_BOOTSTRAP_ACCEPTANCE_INVALID'
    }

    $phase = 'cleanup-candidate'
    $module = Import-LegacySqlBootstrapModule
    $cleanup = Remove-SqlServerLab -RunId $candidateRunId -StateRoot $legacyStateRoot -Force -Confirm:$false
    if ([string]$cleanup.Status -ne 'REMOVED' -or [int]$cleanup.Errors -ne 0) {
        throw 'HVR008_SQL_BOOTSTRAP_CANDIDATE_CLEANUP_FAILED'
    }
    if (Get-VM -Name $candidateVMName -ErrorAction SilentlyContinue) {
        throw 'HVR008_SQL_BOOTSTRAP_CANDIDATE_VM_REMAINS'
    }
    $validatedLegacyRoot = Assert-LegacySqlBootstrapStateRoot -Path $legacyStateRoot -ExpectedVolumeRoot $volumeRoot
    Remove-Item -LiteralPath $validatedLegacyRoot -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $validatedLegacyRoot) { throw 'HVR008_SQL_BOOTSTRAP_STATE_CLEANUP_INCOMPLETE' }

    $finalStatus = & $module {
        param($StateRoot)
        Get-LabAutomatedTestEnvironmentStatus -StateRoot $StateRoot
    } ([string]$inventory.ProductionStateRoot)
    if ([string]$finalStatus.GroupStatus -ne 'READY' -or [int]$finalStatus.Ready -ne [int]$finalStatus.Total) {
        throw 'HVR008_SQL_BOOTSTRAP_FINAL_GROUP_NOT_READY'
    }

    [PSCustomObject]@{
        ContractVersion='SqlServerLab.HVR008SqlBootstrap/1.0'; Status='PASS'
        SqlMajorVersion=16; RestartEvidenceCount=[int]$acceptance.RestartEvidenceCount
        SqlRestartEvidenceCount=[int]$acceptance.SqlRestartEvidenceCount
        BindingCommitted=[bool]$acceptance.BindingCommitted; CandidateRemoved=$true
        LegacyStateRemoved=$true; ProtectedGroupStatus=[string]$finalStatus.GroupStatus
    }
}
catch {
    $failure = $_
}
finally {
    if ($groupStopped) {
        try {
            if (-not $candidateNetworkIsolated -and $candidateVMName) {
                $candidate = Get-VM -Name $candidateVMName -ErrorAction SilentlyContinue
                if ($candidate -and [string]$candidate.State -ne 'Off') {
                    Stop-VM -VM $candidate -TurnOff -Force -ErrorAction Stop
                }
            }
            $module = Import-LegacySqlBootstrapModule
            $restored = Start-SqlServerLabAutomatedTestEnvironment `
                -StateRoot ([string]$inventory.ProductionStateRoot) -TimeoutSeconds $groupTimeoutSeconds -Force -Confirm:$false
            if ([string]$restored.Status -ne 'READY' -or [int]$restored.Errors -ne 0 -or
                [string]$restored.Export.GroupStatus -ne 'READY') {
                throw 'HVR008_SQL_BOOTSTRAP_FINALLY_GROUP_RESTORE_FAILED'
            }
        }
        catch { $groupRestoreFailure = $_ }
    }
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
}

if ($groupRestoreFailure) {
    if ($failure) {
        throw "HVR008_SQL_BOOTSTRAP_TEST_AND_GROUP_RESTORE_FAILED: test=$($failure.Exception.Message); restore=$($groupRestoreFailure.Exception.Message)"
    }
    throw $groupRestoreFailure
}
if ($failure) {
    $recovery = if ($candidateRunId) {
        "Recovery-Kandidat: RunId=$candidateRunId, VM=$candidateVMName, StateRoot=$legacyStateRoot"
    } else { 'Vor der Kandidatenerstellung fehlgeschlagen.' }
    throw "HVR008_SQL_BOOTSTRAP_RECOVERY_REQUIRED [$phase]: $($failure.Exception.Message). $recovery"
}
