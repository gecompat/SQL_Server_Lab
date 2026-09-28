<# Advisory policy only. No pool claims, provider discovery or provisioning authority. #>
function ConvertTo-LabSlotReservePolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Policy)
    $fields = @('WindowsReserve', 'SqlReserve', 'MinimumDaysRemaining', 'WarningDaysRemaining')
    $names = if ($Policy -is [Collections.IDictionary]) { @($Policy.Keys) } else { @($Policy.PSObject.Properties.Name) }
    if ($names.Count -ne $fields.Count -or @($names | Where-Object { $_ -notin $fields }).Count) { throw 'SLOT_RESERVE_POLICY_INVALID' }
    $result = [ordered]@{}
    foreach ($name in $fields) {
        $value = $Policy.$name
        $maximum = if ($name -like '*Reserve') { 100 } else { 3650 }
        if ($value -isnot [int] -and $value -isnot [long]) { throw 'SLOT_RESERVE_POLICY_INVALID' }
        if ($value -lt 0 -or $value -gt $maximum) { throw 'SLOT_RESERVE_POLICY_INVALID' }
        $result[$name] = [int]$value
    }
    [pscustomobject]$result
}

function Get-LabSlotReserveState {
    [CmdletBinding()]
    param()
    $snapshot = Get-LabPreferencesSnapshot
    $policy = $null
    $status = 'MISSING'
    if ($snapshot.Document.Contains('slotReservePolicy')) {
        try { $policy = ConvertTo-LabSlotReservePolicy -Policy $snapshot.Document['slotReservePolicy']; $status='CONFIGURED' }
        catch { $status='INVALID' }
    }
    [pscustomobject]@{ Status=$status; Policy=$policy; Mode='ADVISORY'; AutomaticRefill=$false }
}

function New-LabSlotReservePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Policy)
    $normalized = ConvertTo-LabSlotReservePolicy -Policy $Policy
    $snapshot = Get-LabPreferencesSnapshot
    $current = Get-LabSlotReserveState
    if ($current.Status -eq 'INVALID') { throw 'SLOT_RESERVE_POLICY_INVALID' }
    $json = $normalized | ConvertTo-Json -Compress
    [pscustomobject]@{ ContractVersion='SqlServerLab.SlotReservePlan/1.0'; Policy=$normalized
        PreviousKey=$snapshot.Key; PlanKey=(Get-LabPreferencesDigest -Text ($snapshot.Key + ':' + $json))
        IsNoOp=($current.Status -eq 'CONFIGURED' -and ($current.Policy | ConvertTo-Json -Compress) -ceq $json)
        Mode='ADVISORY'; Notice='Nur Policy speichern; keine Auffüllung, Reservierung oder Provideraktion.' }
}

function Invoke-LabSlotReservePlan {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object]$Plan)
    if ($Plan.ContractVersion -cne 'SqlServerLab.SlotReservePlan/1.0') { throw 'SLOT_RESERVE_PLAN_INVALID' }
    $applySnapshot = Get-LabPreferencesSnapshot
    $applyCmdlet = $PSCmdlet
    Invoke-WithLabPreferencesLock -Path $applySnapshot.Path -Body {
        if ((Get-LabPreferencesSnapshot).Path -cne $applySnapshot.Path) { throw 'PREFERENCES_PREVIEW_STALE' }
        $fresh = New-LabSlotReservePlan -Policy $Plan.Policy
        if ($fresh.PreviousKey -cne $Plan.PreviousKey -or $fresh.PlanKey -cne $Plan.PlanKey) { throw 'PREFERENCES_PREVIEW_STALE' }
        if (-not $fresh.IsNoOp -and $applyCmdlet.ShouldProcess('Zentrale Slotreservepolicy', 'Geprüfte Advisory-Policy speichern')) {
            Set-LabPreferencesEntry -Name slotReservePolicy -Value $fresh.Policy -ExpectedKey $fresh.PreviousKey
        }
        Get-LabSlotReserveState
    }
}

function Get-LabSlotReserveInventory {
    [CmdletBinding()]
    param()
    $state = Get-LabSlotReserveState
    $root = Get-LabStateRoot
    $now = [datetime]::UtcNow
    $rows = [Collections.Generic.List[object]]::new()
    $runsRoot = Join-Path $root 'runs'
    if (Test-Path -LiteralPath $runsRoot -PathType Container) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $runsRoot -Directory)) {
            if (-not (Test-LabPathWithinRoot -Root $root -Path (Join-Path $directory.FullName 'run-state.json')).Valid) { throw 'SLOT_RESERVE_INVENTORY_INVALID' }
        }
    }
    $operations = @(
        $operationRoot = Join-Path $root 'operations'
        if (Test-Path -LiteralPath $operationRoot -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $operationRoot -File -Filter '*.json')) {
                if (-not (Test-LabPathWithinRoot -Root $root -Path $file.FullName).Valid) { throw 'SLOT_RESERVE_INVENTORY_INVALID' }
                Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 30
            }
        }
    )
    foreach ($run in @(Get-LabActiveRuns -StateRoot $root 3>$null | Where-Object { $_.metadata.workflowKind -eq 'hyperv-lab' })) {
        # Read persisted metadata directly: workflow/status helpers may repair state or probe VMs.
        $runId = [string]$run.runId
        $guid = [guid]::Empty
        if (-not [guid]::TryParse($runId, [ref]$guid)) { continue }
        $path = Join-Path (Join-Path (Join-Path $root 'runs') $runId) 'connection-info.json'
        $instance = $null
        try {
            if (-not (Test-LabPathWithinRoot -Root $root -Path $path).Valid) { throw 'INVALID_PATH' }
            $connection = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 30
            $instance = @($connection.instances | Where-Object provider -eq 'hyperv' | Select-Object -First 1)[0]
        } catch { }
        $kind = if ($instance.workload -eq 'sql') { 'SQL' } elseif ($instance.workload -eq 'windows') { 'Windows' } else { 'UNKNOWN' }
        $allocation = if (@($operations | Where-Object { $_.runId -eq $runId -and $_.status -notin @('Completed','Cancelled','Failed') }).Count) { 'OPERATION_BOUND' }
            elseif ($instance.sqlDeploymentPlan) { 'IN_USE' } else { 'UNKNOWN' }
        $expiry = [datetime]::MinValue
        $days = $null; $lifetime = 'UNKNOWN'; $warning = 'UNKNOWN'
        if ([datetime]::TryParse([string]$instance.windowsActivation.evaluationExpiresAt, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$expiry)) {
            $remaining = ($expiry.ToUniversalTime() - $now).TotalDays
            $days = [math]::Max(0, [int][math]::Floor($remaining))
            $lifetime = if ($remaining -le 0) { 'EXPIRED' } elseif ($state.Policy -and $remaining -lt $state.Policy.MinimumDaysRemaining) { 'BELOW_MINIMUM' } else { 'HISTORICAL_ONLY' }
            $warning = if ($state.Policy -and $remaining -le $state.Policy.WarningDaysRemaining) { 'WARNING' } else { 'NOT_EVALUATED' }
        }
        $sqlLifetime='UNKNOWN'; $sqlSource='UNKNOWN'; $sqlMinimum='UNKNOWN'
        if ($kind -eq 'SQL' -and [string]$run.state -in @('RUNNING','STOPPED')) {
            $evidence = Get-LabSqlGuestEvaluationEvidence -RunId $runId -StateRoot $root
            $sql = ConvertTo-LabSqlGuestEvaluationWatchItem -ReaderResult $evidence -RegistrationState ([string]$run.state) -Now $now `
                -WarningDaysRemaining $(if ($state.Policy) { $state.Policy.WarningDaysRemaining } else { 0 }) -CriticalDaysRemaining 0
            $sqlLifetime=[string]$sql.Status; $sqlSource=[string]$sql.EvidenceStatus
            if ($state.Policy -and $sql.EvidenceStatus -eq 'CURRENT' -and $sql.EvaluationExpiresAt) {
                $sqlRemaining=([datetime]$sql.EvaluationExpiresAt - $now).TotalDays
                $sqlMinimum=if ($sqlRemaining -lt $state.Policy.MinimumDaysRemaining) { 'BELOW_MINIMUM' } else { 'MEETS_MINIMUM' }
            }
        }
        $registeredState = if ([string]$run.state -in @('RUNNING','STOPPED','CREATED','PROVISIONING','FAILED','CLEANUP_PENDING','RECOVERY_REQUIRED')) { [string]$run.state } else { 'OTHER_REGISTERED_STATE' }
        $rows.Add([pscustomobject]@{ Reference=$runId; Kind=$kind; RegisteredState=$registeredState
            Allocation=$allocation; WindowsLifetime=$lifetime; WindowsDays=$days; Warning=$warning
            Evidence='PERSISTED_WINDOWS_ACTIVATION_NOT_LIVE'; SqlLifetime=$sqlLifetime; SqlEvidence=$sqlSource; SqlMinimum=$sqlMinimum; VerifiedAvailable=$false })
    }
    [pscustomobject]@{ Configuration=$state; CandidateCount=$rows.Count; Rows=@($rows); VerifiedAvailable=$null; Deficit=$null
        Recommendation=$(if ($state.Policy -and $state.Policy.WindowsReserve -eq 0 -and $state.Policy.SqlReserve -eq 0) { 'NO_RESERVE_REQUESTED' } else { 'VERIFY_MEMBERSHIP_AND_CLAIMS' })
        Notice='Registrierte Kandidaten, kein vollständiger Hostbestand. Poolzugehörigkeit und freie Reservierbarkeit unbelegt; verfügbare Reserve und Auffüllzahl unbekannt. Keine automatische Auffüllung.' }
}

function Show-LabSlotReserveInteractive {
    [CmdletBinding()]
    param()
    while ($true) {
        try { $view = (Invoke-SqlServerLabWorkflowAction -Action GetSlotReserveState).Result }
        catch { Write-LabWarning 'Slotreserve konnte nicht gelesen werden. Preferences und State separat prüfen.'; Wait-LabConsoleAcknowledgement; return }
        $choice = Invoke-LabConsoleMenu -ScreenId 'slot-reserve' -Title 'Slotreserve: Policy und registrierte Kandidaten' -Subtitle "$($view.Configuration.Status) · Kandidaten=$($view.CandidateCount) · Verfügbarkeit/Bedarf unbekannt" -Items @(
            New-LabConsoleItem -Id configure -Label 'Advisory-Policy bearbeiten und Vorschau prüfen' -Shortcut 1 -Disabled:($view.Configuration.Status -eq 'INVALID') -DisabledReason 'Ungültige Policy separat prüfen; keine automatische Reparatur.'
            New-LabConsoleItem -Id inventory -Label 'Bestand und Grenzen anzeigen' -Shortcut 2
            New-LabConsoleItem -Id back -Label 'Zurück' -Shortcut 0
        )
        if ($choice.Status -eq 'Refresh') { continue }
        if ($choice.Status -ne 'Selected' -or $choice.SelectedItem.Id -eq 'back') { return }
        if ($choice.SelectedItem.Id -eq 'inventory') {
            Write-Host $view.Notice
            Write-Host ($view | ConvertTo-Json -Depth 8)
            Wait-LabConsoleAcknowledgement
            continue
        }
        $policy = @{}; $cancelled=$false
        foreach ($field in @(@('WindowsReserve','Windows-Zielreserve (0–100)'), @('SqlReserve','SQL-Zielreserve (0–100)'), @('MinimumDaysRemaining','Mindestrestlaufzeit in Tagen (0–3650)'), @('WarningDaysRemaining','Separate Warnfrist in Tagen (0–3650)'))) {
            $inputResult = Read-LabConsoleTextInput -Prompt $field[1]
            $number = 0
            if ($inputResult.Status -ne 'Confirmed' -or -not [int]::TryParse([string]$inputResult.Value, [ref]$number)) { $cancelled=$true; break }
            $policy[$field[0]]=$number
        }
        if ($cancelled) { continue }
        try {
            $plan = (Invoke-SqlServerLabWorkflowAction -Action PlanSlotReserve -SlotReservePolicy $policy).Result
            Write-Host ($plan.Policy | ConvertTo-Json); Write-Host $plan.Notice
            if (Read-LabConfirm -Prompt 'Nur diese angezeigte Policy speichern?' -Default $false) {
                $null = Invoke-SqlServerLabWorkflowAction -Action ApplySlotReserve -SlotReservePlan $plan -ConfirmSlotReserve
                Write-LabInfo 'Policy gespeichert. Kein Slot wurde erstellt oder reserviert.'
            }
        } catch { Write-LabWarning 'Policy nicht gespeichert. Eingaben und aktuellen Zustand erneut prüfen.' }
        Wait-LabConsoleAcknowledgement
    }
}
