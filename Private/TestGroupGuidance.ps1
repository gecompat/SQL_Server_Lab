function Enter-LabTestGroupLock {
    param([string]$OutputDirectory)
    $root = Get-LabCanonicalResourceRoot -StateRoot (Get-LabTestEnvironmentExportDirectory -OutputDirectory $OutputDirectory)
    $cursor = Get-LabTestEnvironmentRegistryPath -OutputDirectory $root
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'TEST_GROUP_REPARSE_POINT' }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    $name = 'SqlServerLab.TestGroup.' + (Get-LabWorkflowHash -Text $root -Length 32)
    if ($IsWindows) { $name = 'Global\' + $name }
    $mutex = [Threading.Mutex]::new($false, $name)
    try {
        try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'TEST_GROUP_BUSY' }
        return $mutex
    }
    catch { $mutex.Dispose(); throw }
}

function Exit-LabTestGroupLock {
    param($Mutex)
    if ($Mutex) { $Mutex.ReleaseMutex(); $Mutex.Dispose() }
}

function Get-LabTestGroupRuntimeSnapshot {
    # Only native reads; no workflow discovery, repair, export or SQL probe.
    param([Parameter(Mandatory)]$Member)
    if ($Member.Provider -eq 'hyperv') {
        $managed = Get-HyperVManagedVM -VMName $Member.VMName -ExpectedRunId $Member.RunId -ExpectedScopeId $Member.ScopeId
        if (-not $managed -or [string]$managed.VM.Id -ne $Member.RuntimeId -or
            [string]$managed.Identity.instanceId -ne $Member.InstanceId) { throw 'TEST_GROUP_RUNTIME_BINDING' }
        $siblings = @(Get-VM -ErrorAction Stop | Where-Object {
            $identity = ConvertFrom-HyperVLabNotes -Notes ([string]$_.Notes)
            $identity -and [string]$identity.runId -eq $Member.RunId
        })
        if ($siblings.Count -ne 1 -or [string]$siblings[0].Id -ne $Member.RuntimeId) { throw 'TEST_GROUP_EXTRA_RUNTIME' }
        $power = switch ([string]$managed.VM.State) { 'Running' { 'RUNNING' } 'Off' { 'STOPPED' } default { 'UNKNOWN' } }
    }
    else {
        $invocation = Get-LabHostToolInvocation -Name $Member.Provider
        $ids = @(& $invocation ps -a -q --no-trunc --filter "label=sql-server-lab.run-id=$($Member.RunId)" 2>$null)
        if ($LASTEXITCODE -ne 0 -or $ids.Count -ne 1 -or ([string]$ids[0]).Trim() -ne $Member.RuntimeId) { throw 'TEST_GROUP_EXTRA_RUNTIME' }
        $status = if ($Member.Provider -eq 'docker') { Get-DockerInstanceStatus -ContainerIdOrName $Member.RuntimeId } else { Get-PodmanInstanceStatus -ContainerIdOrName $Member.RuntimeId }
        $inspect = $status.Inspect
        if (-not $status.Available -or -not $status.Exists -or [string]$inspect.Id -ne $Member.RuntimeId -or
            [string]$inspect.Config.Labels.'sql-server-lab.run-id' -ne $Member.RunId -or
            [string]$inspect.Config.Labels.'sql-server-lab.scope-id' -ne $Member.ScopeId -or
            [string]$inspect.Config.Labels.'sql-server-lab.instance-id' -ne $Member.InstanceId) { throw 'TEST_GROUP_RUNTIME_BINDING' }
        $power = switch ([string]$inspect.State.Status) { 'running' { 'RUNNING' } 'exited' { 'STOPPED' } default { 'UNKNOWN' } }
    }
    if ($power -eq 'UNKNOWN') { throw 'TEST_GROUP_POWER_UNKNOWN' }
    return $power
}

function Get-LabTestGroupPowerPlan {
    [CmdletBinding()]
    param([ValidateSet('Start','Stop')][string]$PowerAction = 'Start', [string]$StateRoot, [string]$OutputDirectory)
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $root = Get-LabCanonicalResourceRoot -StateRoot $StateRoot
    $directory = Get-LabTestEnvironmentExportDirectory -OutputDirectory $OutputDirectory
    $lock = Enter-LabTestGroupLock -OutputDirectory $directory
    try {
        $registry = Get-LabTestEnvironmentRegistry -OutputDirectory $directory
        $registryPath = Get-LabTestEnvironmentRegistryPath -OutputDirectory $directory
        $registryHash = if (Test-Path -LiteralPath $registryPath) { (Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash } else { 'absent' }
        $target = if ($PowerAction -eq 'Start') { 'RUNNING' } else { 'STOPPED' }
        $members = @(); $bindings = @(); $seenKeys = @{}; $seenRuns = @{}
        foreach ($entry in @($registry.environments | Sort-Object key)) {
            $member = [pscustomobject]@{ Key=[string]$entry.key; RunId=[string]$entry.runId; ScopeId=''; InstanceId=[string]$entry.instanceId; Provider=''; RuntimeId=''; VMName=''; Power='UNKNOWN'; Desired=$target; SqlReadiness='NOT_CHECKED'; Change='BLOCKED'; Reason='' }
            try {
                if (-not $member.Key -or $seenKeys.ContainsKey($member.Key) -or $seenRuns.ContainsKey($member.RunId) -or
                    $member.RunId -notmatch '^[a-fA-F0-9-]{36}$' -or -not $member.InstanceId) { throw 'TEST_GROUP_MEMBER_AMBIGUOUS' }
                $seenKeys[$member.Key] = $true; $seenRuns[$member.RunId] = $true
                $runDirectory = Join-Path (Join-Path $root 'runs') $member.RunId
                $runPath = Join-Path $runDirectory 'run-state.json'; $connectionPath = Join-Path $runDirectory 'connection-info.json'
                $run = Get-Content -LiteralPath $runPath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 50 -ErrorAction Stop
                $connection = Get-Content -LiteralPath $connectionPath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 50 -ErrorAction Stop
                if ([string]$run.runId -ne $member.RunId -or -not $run.scopeId -or [string]$run.state -notin @('RUNNING','STOPPED')) { throw 'TEST_GROUP_LIFECYCLE_BLOCKED' }
                $instances = @($connection.instances)
                if ($instances.Count -ne 1 -or @($run.instances).Count -gt 1 -or @($run.providerSubRuns).Count -gt 1 -or [string]$instances[0].id -ne $member.InstanceId) { throw 'TEST_GROUP_SINGLE_INSTANCE_REQUIRED' }
                $instance = $instances[0]; $member.ScopeId = [string]$run.scopeId; $member.Provider = [string]$instance.provider
                if ($member.Provider -notin @('docker','podman','hyperv') -or
                    ($member.Provider -eq 'hyperv') -ne ([string]$entry.platform -eq 'windows')) { throw 'TEST_GROUP_PROVIDER_MISMATCH' }
                if ([string]$run.metadata.systemService) { throw 'TEST_GROUP_SYSTEM_SERVICE_BLOCKED' }
                $cms = Get-LabConnectionCenterCmsConfiguration -StateRoot $root
                if ($cms -and [string]$cms.RunId -eq $member.RunId) { throw 'TEST_GROUP_SYSTEM_SERVICE_BLOCKED' }
                $journalKey = 'absent'
                if ($member.Provider -eq 'hyperv') {
                    # Legacy Hyper-V runs may omit subruns; present subruns must be stable and bound.
                    $subRuns = @($run.providerSubRuns | Where-Object { $null -ne $_ })
                    if ($subRuns.Count -and ($subRuns.Count -ne 1 -or [string]$subRuns[0].provider -ne 'hyperv' -or [string]$subRuns[0].state -notin @('RUNNING','STOPPED'))) { throw 'TEST_GROUP_LIFECYCLE_BLOCKED' }
                    $member.RuntimeId = [string]$instance.vmId; $member.VMName = [string]$instance.vmName
                    $null = Assert-LabHyperVResourceMigrationLifecycleAllowed -RunId $member.RunId -Operation $PowerAction -StateRoot $root
                    # Do not interpret or resume unrelated Hyper-V recovery contracts.
                    if (@(Get-ChildItem -LiteralPath $runDirectory -Filter '*journal*.json' -File).Count) { throw 'TEST_GROUP_RECOVERY_REVIEW_REQUIRED' }
                }
                else {
                    $member.RuntimeId = [string]$instance.containerId
                    $subRuns = @($run.providerSubRuns)
                    if ($subRuns.Count -ne 1 -or [string]$subRuns[0].provider -ne $member.Provider -or [string]$subRuns[0].state -notin @('RUNNING','STOPPED')) { throw 'TEST_GROUP_LIFECYCLE_BLOCKED' }
                    $journalPath = Get-LabContainerReconcileJournalPath -RunDirectory $runDirectory
                    if (@(Get-ChildItem -LiteralPath $runDirectory -Filter '*journal*.json' -File | Where-Object FullName -ne $journalPath).Count) { throw 'TEST_GROUP_RECOVERY_REVIEW_REQUIRED' }
                    if (Test-Path -LiteralPath $journalPath) {
                        $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json -Depth 50
                        $null = Assert-LabContainerReconcileJournal -Journal $journal
                        if ($journal.Status -notin @('COMPLETED','ROLLED_BACK') -or $journal.RunId -ne $member.RunId -or $journal.ScopeId -ne $member.ScopeId -or $journal.InstanceId -ne $member.InstanceId -or $journal.Provider -ne $member.Provider) { throw 'TEST_GROUP_RECOVERY_BLOCKED' }
                        $journalKey = (Get-FileHash -LiteralPath $journalPath).Hash
                    }
                }
                if (-not $member.RuntimeId) { throw 'TEST_GROUP_RUNTIME_BINDING' }
                $member.Power = Get-LabTestGroupRuntimeSnapshot -Member $member
                $member.Change = if ($member.Power -eq $target) { 'NO_OP' } else { $PowerAction.ToUpperInvariant() }
                $bindings += [ordered]@{ Key=$member.Key; Run=$member.RunId; Scope=$member.ScopeId; Instance=$member.InstanceId; Provider=$member.Provider; Runtime=$member.RuntimeId; VMName=$member.VMName; RunHash=(Get-FileHash -LiteralPath $runPath).Hash; ConnectionHash=(Get-FileHash -LiteralPath $connectionPath).Hash; Journal=$journalKey }
            }
            catch { $member.Change = 'BLOCKED'; $member.Reason = if ($_.Exception.Message -match '^(TEST_GROUP_[A-Z_]+)$') { $Matches[1] } else { 'TEST_GROUP_READ_UNAVAILABLE' } }
            $members += $member
        }
        $binding = [ordered]@{ StateRoot=$root; ExportRoot=(Get-LabCanonicalResourceRoot -StateRoot $directory); Registry=$registryHash; Members=$bindings }
        $bindingKey = Get-LabWorkflowHash -Text ($binding | ConvertTo-Json -Depth 15 -Compress) -Length 64
        $planKey = Get-LabWorkflowHash -Text (($bindingKey, $PowerAction, @($members.Power)) | ConvertTo-Json -Compress) -Length 64
        $allowed = $members.Count -gt 0 -and @($members | Where-Object Change -eq 'BLOCKED').Count -eq 0
        [pscustomobject]@{
            Group='Registrierte Testgruppe'; PowerAction=$PowerAction; PlanKey=$planKey; BindingKey=$bindingKey
            Members=$members; Total=$members.Count; CanApply=$allowed; NoChange=($allowed -and @($members | Where-Object Change -ne 'NO_OP').Count -eq 0)
            PowerStatus=$(if (-not $members.Count) {'EMPTY'} elseif (@($members.Power | Select-Object -Unique).Count -eq 1) {$members[0].Power} else {'MIXED'})
            SqlReadiness='NOT_CHECKED'; Notice='Nur Container-/VM-Power. SQL-Bereitschaft nicht geprüft; Dienste können durch vorhandenen Autostart anlaufen. Keine Export-, CMS-, Lizenz- oder Hostspeicheraktion. Nach Teilfehler neue Vorschau lesen; kein automatisches Resume/Rollback.'
        }
    }
    finally { Exit-LabTestGroupLock -Mutex $lock }
}

function Invoke-LabTestGroupPowerPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Start','Stop')][string]$PowerAction, [Parameter(Mandatory)][string]$ExpectedPlanKey, [switch]$Confirmed, [string]$StateRoot, [string]$OutputDirectory)
    if (-not $Confirmed) { return [pscustomobject]@{ Status='CANCELLED'; Details=@(); SqlReadiness='NOT_CHECKED' } }
    $directory = Get-LabTestEnvironmentExportDirectory -OutputDirectory $OutputDirectory
    $lock = Enter-LabTestGroupLock -OutputDirectory $directory
    try {
        $plan = Get-LabTestGroupPowerPlan -PowerAction $PowerAction -StateRoot $StateRoot -OutputDirectory $directory
        if (-not $plan.CanApply -or $plan.PlanKey -cne $ExpectedPlanKey) { throw 'TEST_GROUP_PREVIEW_STALE_OR_BLOCKED' }
        if ($plan.NoChange) { return [pscustomobject]@{ Status='NO_OP'; Details=@($plan.Members | ForEach-Object { [pscustomobject]@{Key=$_.Key;Provider=$_.Provider;Status=$_.Power;Action='NO_OP';Attempted=$false;SqlReadiness='NOT_CHECKED'} }); SqlReadiness='NOT_CHECKED' } }
        $details = @()
        foreach ($member in $plan.Members) {
            $attempted = $false
            try {
                $fresh = Get-LabTestGroupPowerPlan -PowerAction $PowerAction -StateRoot $StateRoot -OutputDirectory $directory
                $current = @($fresh.Members | Where-Object Key -eq $member.Key)[0]
                if (-not $fresh.CanApply -or $fresh.BindingKey -cne $plan.BindingKey -or $current.Power -ne $member.Power) { throw 'TEST_GROUP_MEMBER_DRIFT' }
                if ($member.Change -ne 'NO_OP') {
                    $attempted = $true
                    if ($member.Provider -eq 'hyperv') {
                        $arguments = @{ VMName=$member.VMName; ExpectedRunId=$member.RunId; ExpectedScopeId=$member.ScopeId; ExpectedVMId=$member.RuntimeId; ExpectedInstanceId=$member.InstanceId }
                        if ($PowerAction -eq 'Start') { $null = Start-HyperVInstance @arguments } else { $null = Stop-HyperVInstance @arguments }
                    }
                    elseif ($member.Provider -eq 'docker') {
                        if ($PowerAction -eq 'Start') { $null = Start-DockerInstance -ContainerIdOrName $member.RuntimeId -RunId $member.RunId } else { $null = Stop-DockerInstance -ContainerIdOrName $member.RuntimeId -RunId $member.RunId }
                    }
                    else {
                        if ($PowerAction -eq 'Start') { $null = Start-PodmanInstance -ContainerIdOrName $member.RuntimeId -RunId $member.RunId } else { $null = Stop-PodmanInstance -ContainerIdOrName $member.RuntimeId -RunId $member.RunId }
                    }
                }
                $observed = Get-LabTestGroupRuntimeSnapshot -Member $member
                if ($observed -ne $member.Desired) { throw 'TEST_GROUP_POSTCONDITION_UNCONFIRMED' }
                $details += [pscustomobject]@{ Key=$member.Key; Provider=$member.Provider; Status=$observed; Action=$member.Change; Attempted=$attempted; SqlReadiness='NOT_CHECKED' }
            }
            catch { $details += [pscustomobject]@{ Key=$member.Key; Provider=$member.Provider; Status='UNCONFIRMED'; Action=$member.Change; Attempted=$attempted; SqlReadiness='NOT_CHECKED'; Reason='Zustand erneut lesen; bereits ausgeführte Änderungen werden nicht zurückgerollt.' } }
        }
        [pscustomobject]@{ Status=$(if (@($details | Where-Object Status -eq 'UNCONFIRMED').Count) {'PARTIAL'} else {'COMPLETED'}); Details=$details; SqlReadiness='NOT_CHECKED'; NextStep='Aktuellen Gruppenstatus lesen. Wiederholung nur mit neuer Vorschau und Bestätigung.' }
    }
    finally { Exit-LabTestGroupLock -Mutex $lock }
}

function Invoke-LabTestGroupPowerInteractive {
    [CmdletBinding()]
    param()
    $summary = 'NoChange'
    try {
        $view = Get-LabTestGroupPowerPlan
        if (-not $view.Total) { Write-LabInfo 'Keine registrierte Testgruppe vorhanden.'; $null = Wait-LabConsoleAcknowledgement; return New-LabActionResult -Action AutomatedTestEnvironmentLifecycle -Status NoChange }
        $selected = Select-LabConsoleDataItem -ScreenId 'test-group-select' -Title 'Geschützte Testgruppe auswählen' -Items @(
            [pscustomobject]@{ Id='registered'; Label=$view.Group; Value="$($view.Total) Mitglieder · Power $($view.PowerStatus)"; Data=$true }
        )
        if (-not $selected) { return New-LabActionResult -Action AutomatedTestEnvironmentLifecycle -Status Cancelled }
        while ($true) {
            $view = Get-LabTestGroupPowerPlan
            $menu = Invoke-LabConsoleMenu -ScreenId 'test-group-power' -Title 'Gruppenweite Poweraktion' -Subtitle ("Power: {0} · SQL-Bereitschaft nicht geprüft. {1}" -f $view.PowerStatus,$view.Notice) -Items @(
                foreach ($member in $view.Members) { New-LabConsoleItem -Id ('member-' + $member.Key) -Label ("{0} · {1} · Power {2} · {3}" -f $member.Key,$member.Provider,$member.Power,$member.Reason) -Disabled -DisabledReason 'Mitglied der gruppenweiten Aktion' }
                New-LabConsoleItem -Id Start -Label 'Gesamte Gruppe: Power starten' -Shortcut 1
                New-LabConsoleItem -Id Stop -Label 'Gesamte Gruppe: Power stoppen' -Shortcut 2
                New-LabConsoleItem -Id refresh -Label 'Status erneut lesen' -Shortcut 3
                New-LabConsoleItem -Id back -Label 'Zurück / Abbrechen' -Shortcut 0
            )
            if ($menu.Status -in @('Refresh','Invalid')) { continue }
            $choice = if ($menu.Status -eq 'Selected') { [string]$menu.SelectedItem.Id } else { $null }
            if (-not $choice -or $choice -in @('back','0','q')) { return New-LabActionResult -Action AutomatedTestEnvironmentLifecycle -Status $summary }
            if ($choice -eq 'refresh') { continue }
            if ($choice -notin @('Start','Stop')) { continue }
            $plan = Get-LabTestGroupPowerPlan -PowerAction $choice
            foreach ($member in $plan.Members) { Write-LabInfo ("Vorschau {0}: {1} → {2} · {3} {4}" -f $member.Key,$member.Power,$member.Desired,$member.Change,$member.Reason) }
            Write-LabInfo $plan.Notice
            if (-not $plan.CanApply -or $plan.NoChange) { Write-LabInfo 'Keine ausführbare Änderung. Blocker prüfen oder zurück.'; $null = Wait-LabConsoleAcknowledgement; continue }
            if (-not (Read-LabConfirm -Prompt 'Diese Poweraktion für die gesamte ausgewählte Gruppe ausführen?' -Default $false)) { if ($summary -eq 'NoChange') { $summary='Cancelled' }; continue }
            $result = Invoke-LabTestGroupPowerPlan -PowerAction $choice -ExpectedPlanKey $plan.PlanKey -Confirmed
            if ($result.Status -eq 'PARTIAL') { $summary='Failed' }
            elseif ($summary -ne 'Failed' -and @($result.Details | Where-Object Attempted).Count) { $summary='Changed' }
            Write-LabInfo ("Gruppenergebnis: {0}. SQL-Bereitschaft nicht geprüft." -f $result.Status)
            foreach ($member in $result.Details) { Write-LabInfo ("{0}: {1} · {2}" -f $member.Key,$member.Status,$member.Action) }
            Write-LabInfo $result.NextStep
            $null = Wait-LabConsoleAcknowledgement
        }
    }
    catch { Write-LabError 'TEST_GROUP_UNAVAILABLE: Ergebnis kann unbestätigt sein. Gruppe erneut lesen; keine automatische Wiederholung.'; $null = Wait-LabConsoleAcknowledgement; return New-LabActionResult -Action AutomatedTestEnvironmentLifecycle -Status Failed -ErrorCode TEST_GROUP_UNCONFIRMED }
}
