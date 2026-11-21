#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][System.Management.Automation.PSModuleInfo]$Module)

$ErrorActionPreference = 'Stop'

& $Module {
    $runId = [guid]::NewGuid().ToString('D')
    $scopeId = [guid]::NewGuid().ToString('D')
    $desiredInstance = [pscustomobject]@{ Id = 'primary'; Provider = 'hyperv'; AutoStart = 'off' }
    $run = [pscustomobject]@{
        runId = $runId; scopeId = $scopeId; state = 'STOPPED'; updatedAt = $null
        metadata = [pscustomobject]@{
            autostart = 'off'; workflowKind = 'hyperv-lab'
            desiredState = [pscustomobject]@{ Instances = @($desiredInstance) }
        }
    }
    $connection = [pscustomobject]@{
        instances = @([pscustomobject]@{ id = 'primary'; provider = 'hyperv'; vmName = 'synthetic-hyperv'; vmId = 'vm-guid'; autostart = 'off' })
    }
    $script:autostartVm = [pscustomobject]@{ Id = 'vm-guid'; State = 'Off'; AutomaticStartAction = 'Nothing' }
    $script:autostartSetCalls = 0
    $script:autostartWrites = @()
    $script:autostartJournal = $null
    $syntheticRunDirectory = Join-Path ([IO.Path]::GetTempPath()) ("sql-lab-hyperv-autostart-synthetic-$([guid]::NewGuid().ToString('N'))")
    $null = New-Item -ItemType Directory -Path $syntheticRunDirectory -Force

    function Assert-LabWindowsPoolMutationAllowed {
        param($RunId,$StateRoot,[switch]$InvalidateEvidence)
        if ($script:autostartBlockPool) { throw 'WINDOWS_POOL_MEMBER_RESERVED' }
    }
    function Assert-LabResourceChangeAllowed { param($RunId,$StateRoot) }
    function Assert-LabHyperVResourceMigrationLifecycleAllowed {
        param($RunId,$Operation,$StateRoot)
        if ($script:autostartBlockMigration) { throw 'HYPERV_AUTOSTART_MIGRATION_BLOCKED' }
    }
    function Get-HyperVLabWorkflowRun {
        param($RunId,$StateRoot)
        [pscustomobject]@{
            Run = $run; RunDirectory = $syntheticRunDirectory; Connection = $connection
            Instance = $connection.instances[0]; StateRoot = ([IO.Path]::GetTempPath())
        }
    }
    function Get-HyperVManagedVM {
        param($VMName,$ExpectedRunId,$ExpectedScopeId)
        [pscustomobject]@{ VM = $script:autostartVm }
    }
    function Set-VM {
        param($VM,$AutomaticStartAction)
        $script:autostartSetCalls++
        $VM.AutomaticStartAction = $AutomaticStartAction
    }
    function Get-LabTimestamp { '2026-10-10T00:00:00.0000000Z' }
    function Write-LabArtifactJsonAtomic {
        param($Path,$InputObject)
        $script:autostartWrites += [string]$Path
        if ($Path -like '*hyperv-autostart-journal.json') {
            $script:autostartJournal = $InputObject | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
            $InputObject | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
        }
        elseif ($script:failConnectionWrite -and $Path -like '*connection-info.json') {
            $script:failConnectionWrite = $false
            throw 'SYNTHETIC_STATE_COMMIT_FAILURE'
        }
    }

    $plan = Get-SqlServerLabHyperVAutoStartPlan -RunId $runId -AutoStart on -StateRoot ([IO.Path]::GetTempPath())
    if ($plan.Contract.Name -ne 'SqlServerLab.HyperVAutoStartPlan' -or $plan.NoChange -or $plan.ChangeClass -ne 'live' -or
        $plan.Actual.AutoStart -ne 'OFF' -or $plan.Desired.AutoStart -ne 'ON' -or $plan.PlanKey -notmatch '^[a-f0-9]{64}$' -or
        ($plan | ConvertTo-Json -Depth 10) -match 'vm-guid') { throw 'HYPERV_AUTOSTART_PLAN_BINDING' }
    foreach ($blocker in @('WINDOWS_POOL_MEMBER_RESERVED', 'HYPERV_AUTOSTART_MIGRATION_BLOCKED')) {
        $script:autostartBlockPool = ($blocker -ceq 'WINDOWS_POOL_MEMBER_RESERVED')
        $script:autostartBlockMigration = ($blocker -ceq 'HYPERV_AUTOSTART_MIGRATION_BLOCKED')
        $blocked = $false
        try { $null = Set-SqlServerLabHyperVAutoStart -RunId $runId -AutoStart on -ExpectedAutoStartPlanKey $plan.PlanKey -StateRoot ([IO.Path]::GetTempPath()) -Confirm:$false }
        catch { $blocked = $_.Exception.Message -ceq $blocker }
        if (-not $blocked -or $script:autostartSetCalls -ne 0 -or $script:autostartWrites.Count -ne 0) {
            throw 'HYPERV_AUTOSTART_PROTECTED_STATE_MUTATED'
        }
    }
    $script:autostartBlockPool = $false
    $script:autostartBlockMigration = $false
    $result = Set-SqlServerLabHyperVAutoStart -RunId $runId -AutoStart on -ExpectedAutoStartPlanKey $plan.PlanKey -StateRoot ([IO.Path]::GetTempPath()) -Confirm:$false
    $success = $result.Status -eq 'SUCCEEDED' -and $result.AutoStart -eq 'on' -and
        $script:autostartSetCalls -eq 1 -and $script:autostartVm.Id -eq 'vm-guid' -and
        $script:autostartVm.State -eq 'Off' -and $script:autostartVm.AutomaticStartAction -eq 'Start' -and
        $connection.instances[0].autostart -eq 'on' -and $run.metadata.autostart -eq 'on' -and
        $desiredInstance.AutoStart -eq 'on' -and $script:autostartWrites.Count -eq 6 -and
        $script:autostartJournal.Status -eq 'COMPLETED' -and $script:autostartJournal.Runtime.VMId -eq 'vm-guid'
    $script:autostartVm.AutomaticStartAction = 'Nothing'
    $connection.instances[0].autostart = 'off'; $run.metadata.autostart = 'off'; $desiredInstance.AutoStart = 'off'
    $script:failConnectionWrite = $true
    $recoveryPlan = Get-SqlServerLabHyperVAutoStartPlan -RunId $runId -AutoStart on -StateRoot ([IO.Path]::GetTempPath())
    $recoveryFailed = $false
    try { $null = Set-SqlServerLabHyperVAutoStart -RunId $runId -AutoStart on -ExpectedAutoStartPlanKey $recoveryPlan.PlanKey -StateRoot ([IO.Path]::GetTempPath()) -Confirm:$false }
    catch { $recoveryFailed = $_.Exception.Message -match 'SYNTHETIC_STATE_COMMIT_FAILURE' }
    $setCallsBeforeResume = $script:autostartSetCalls
    $blockedPlan = $false
    try { $null = Get-SqlServerLabHyperVAutoStartPlan -RunId $runId -AutoStart off -StateRoot ([IO.Path]::GetTempPath()) }
    catch { $blockedPlan = $_.Exception.Message -ceq 'HYPERV_AUTOSTART_RECOVERY_REQUIRED' }
    if (-not $blockedPlan) { throw 'HYPERV_AUTOSTART_RECOVERY_PLAN_NOT_BLOCKED' }
    $reopened = Get-LabHyperVAutoStartApplyPlan -RunId $runId -AutoStart off -StateRoot ([IO.Path]::GetTempPath())
    $journalPath = Get-LabHyperVAutoStartJournalPath -RunDirectory $syntheticRunDirectory
    $oldHash = (Get-FileHash -LiteralPath $journalPath).Hash
    $blocked = $false
    try { $null = Set-SqlServerLabHyperVAutoStart -RunId $runId -AutoStart off -ExpectedAutoStartPlanKey $reopened.PlanKey -StateRoot ([IO.Path]::GetTempPath()) -Confirm:$false }
    catch { $blocked = $_.Exception.Message -ceq 'HYPERV_AUTOSTART_RECOVERY_REQUIRED' }
    if (-not $blocked -or (Get-FileHash -LiteralPath $journalPath).Hash -cne $oldHash -or
        $script:autostartSetCalls -ne $setCallsBeforeResume) { throw 'HYPERV_AUTOSTART_INCOMPLETE_JOURNAL_OVERWRITE' }
    $staleRecovery = $false
    try { $null = Resume-SqlServerLabHyperVAutoStart -RunId $runId -StateRoot ([IO.Path]::GetTempPath()) -ExpectedRecoveryOperationId ([guid]::NewGuid()) -Confirm:$false }
    catch { $staleRecovery = $_.Exception.Message -ceq 'HYPERV_AUTOSTART_RECOVERY_SELECTION_CHANGED' }
    if (-not $staleRecovery -or (Get-FileHash -LiteralPath $journalPath).Hash -cne $oldHash) {
        throw 'HYPERV_AUTOSTART_STALE_RECOVERY_CHANGED_STATE'
    }
    $recovered = Resume-SqlServerLabHyperVAutoStart -RunId $runId -StateRoot ([IO.Path]::GetTempPath()) -Confirm:$false
    $recoverySuccess = $recoveryFailed -and $script:autostartJournal.Status -eq 'COMPLETED' -and
        $recovered.Status -eq 'RECOVERY_SUCCEEDED' -and $script:autostartSetCalls -eq $setCallsBeforeResume -and
        $connection.instances[0].autostart -eq 'on' -and $desiredInstance.AutoStart -eq 'on'
    $terminal = $script:autostartJournal
    foreach ($pendingStatus in @('PREPARED', 'STATE_COMMITTED')) {
        $pending = $terminal | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12
        $pending.Status = $pendingStatus
        $null = Write-LabHyperVAutoStartJournal -Journal $pending -Path $journalPath
        $resume = Resume-SqlServerLabHyperVAutoStart -RunId $runId -StateRoot ([IO.Path]::GetTempPath()) -Confirm:$false
        if ($resume.Status -cne 'RECOVERY_SUCCEEDED' -or $script:autostartSetCalls -ne $setCallsBeforeResume) {
            throw 'HYPERV_AUTOSTART_INTERRUPTED_COMMIT_REPLAY'
        }
    }
    $pending.Status = 'STATE_COMMITTED'
    $null = Write-LabHyperVAutoStartJournal -Journal $pending -Path $journalPath
    $pendingHash = (Get-FileHash -LiteralPath $journalPath).Hash
    function Get-LabActiveRuns {
        $run
        [pscustomobject]@{ runId='another-provider'; state='RUNNING'; metadata=[pscustomobject]@{ workflowKind='docker' } }
    }
    function Select-LabRun {
        param($Runs,$Prompt,[switch]$DisableAutomatedTestEnvironments,[switch]$DisableSystemServices)
        if ($Runs.Count -ne 1 -or -not $DisableAutomatedTestEnvironments -or -not $DisableSystemServices) {
            throw 'HYPERV_AUTOSTART_CONSOLE_SCOPE'
        }
        $Runs[0].runId
    }
    function Read-LabConfirm { param($Prompt,$Default) if ($Default) { throw 'CONFIRMATION_MUST_DEFAULT_TO_NO' }; $script:confirmAutostartRecovery }
    function Write-LabInfo {}
    function Write-LabSuccess {}
    function Write-LabError { throw 'HYPERV_AUTOSTART_CONSOLE_RECOVERY_FAILED' }
    function Wait-LabConsoleAcknowledgement {}
    $script:confirmAutostartRecovery = $false
    Invoke-LabHyperVAutoStartRecoveryInteractive
    if ((Get-FileHash -LiteralPath $journalPath).Hash -cne $pendingHash) { throw 'HYPERV_AUTOSTART_CONSOLE_DECLINE_MUTATED' }
    $script:confirmAutostartRecovery = $true
    Invoke-LabHyperVAutoStartRecoveryInteractive
    if ($script:autostartJournal.Status -cne 'COMPLETED' -or $script:autostartSetCalls -ne $setCallsBeforeResume) {
        throw 'HYPERV_AUTOSTART_CONSOLE_RECOVERY_REPLAY'
    }
    $browserStore = @{}
    $planJson = @{ Action='Plan'; RunId=$runId; AutoStart='off' } | ConvertTo-Json -Compress
    $browserPlan = Invoke-LabHyperVAutoStartBrowser -Store $browserStore -Json $planJson
    $applyJson = @{ Action='Apply'; Selection=$browserPlan.Selection; Confirmed=$true } | ConvertTo-Json -Compress
    $invalid = $false
    try { $null = Invoke-LabHyperVAutoStartBrowser -Store $browserStore -Json ($applyJson.Replace('true', 'false')) }
    catch { $invalid = $true }
    if (-not $invalid -or $script:autostartSetCalls -ne $setCallsBeforeResume -or
        ($browserPlan | ConvertTo-Json) -match 'PlanKey|vm-guid') { throw 'HYPERV_AUTOSTART_BROWSER_PREVIEW_EFFECT' }
    $browserStore.Plan.Expires = [DateTime]::UtcNow.AddSeconds(-1)
    $expired = $false
    try { $null = Invoke-LabHyperVAutoStartBrowser -Store $browserStore -Json $applyJson }
    catch { $expired = $_.Exception.Message -ceq 'HYPERV_AUTOSTART_BROWSER_APPROVAL_INVALID' }
    if (-not $expired -or $script:autostartSetCalls -ne $setCallsBeforeResume) { throw 'HYPERV_AUTOSTART_BROWSER_EXPIRED_EFFECT' }
    $browserPlan = Invoke-LabHyperVAutoStartBrowser -Store $browserStore -Json $planJson
    $applyJson = @{ Action='Apply'; Selection=$browserPlan.Selection; Confirmed=$true } | ConvertTo-Json -Compress
    $applied = Invoke-LabHyperVAutoStartBrowser -Store $browserStore -Json $applyJson
    $replay = $false
    try { $null = Invoke-LabHyperVAutoStartBrowser -Store $browserStore -Json $applyJson }
    catch { $replay = $_.Exception.Message -ceq 'HYPERV_AUTOSTART_BROWSER_APPROVAL_INVALID' }
    if ($applied.Status -cne 'SUCCEEDED' -or -not $replay -or $script:autostartSetCalls -ne ($setCallsBeforeResume+1)) {
        throw 'HYPERV_AUTOSTART_BROWSER_ONE_TIME_CONSUMPTION'
    }
    $pending = $script:autostartJournal
    $pending.Status = 'STATE_COMMITTED'
    $null = Write-LabHyperVAutoStartJournal -Journal $pending -Path $journalPath
    $recoveryJson = @{ Action='PlanRecovery'; RunId=$runId } | ConvertTo-Json -Compress
    $script:autostartVm.AutomaticStartAction = 'Start'
    $mismatch = $false
    try { $null = Invoke-LabHyperVAutoStartBrowser -Store $browserStore -Json $recoveryJson }
    catch { $mismatch = $_.Exception.Message -ceq 'HYPERV_AUTOSTART_RECOVERY_READBACK_CHANGED' }
    if (-not $mismatch -or $browserStore.Plan) { throw 'HYPERV_AUTOSTART_BROWSER_UNVERIFIED_RECOVERY' }
    $script:autostartVm.AutomaticStartAction = 'Nothing'
    $browserPlan = Invoke-LabHyperVAutoStartBrowser -Store $browserStore -Json $recoveryJson
    $applyJson = @{ Action='Apply'; Selection=$browserPlan.Selection; Confirmed=$true } | ConvertTo-Json -Compress
    $resumed = Invoke-LabHyperVAutoStartBrowser -Store $browserStore -Json $applyJson
    if ($resumed.Status -cne 'RECOVERY_SUCCEEDED' -or $script:autostartSetCalls -ne ($setCallsBeforeResume+1)) {
        throw 'HYPERV_AUTOSTART_BROWSER_RECOVERY_REPLAYED_NATIVE_MUTATION'
    }
    Remove-Item -LiteralPath $syntheticRunDirectory -Recurse -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{ Success = ($success -and $recoverySuccess) }
}
