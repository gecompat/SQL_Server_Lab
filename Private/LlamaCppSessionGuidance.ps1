# Guided stop is deliberately limited to worker objects already held by this module.
function Get-LabLlamaCppSessionConsumerContext {
    param([int]$Port)
    $dataRoot = Get-LabDataRootDefault
    $stateRoot = Get-LabStateRoot
    $registry=$null
    $exportRoot=$null
    if ($dataRoot) {
        $exportRoot=Get-LabTestEnvironmentExportDirectory -OutputDirectory (Join-Path $dataRoot 'Exports')
        $registryPath=Get-LabTestEnvironmentRegistryPath -OutputDirectory $exportRoot
        $null=Assert-LabAiSharedGatewayStoragePath $registryPath
        if ((Test-Path -LiteralPath $registryPath) -and -not (Test-Path -LiteralPath $registryPath -PathType Leaf)) { throw 'LLAMA_SESSION_PROTECTION_INVALID' }
        $registry=Get-LabTestEnvironmentRegistry -OutputDirectory $exportRoot
    }
    if ($registry -and ($registry.environments -isnot [array] -or
        @($registry.environments | Where-Object { $_ -isnot [pscustomobject] -or ($_.runId -and [string]$_.runId -cnotmatch '^[a-f0-9-]{36}$') }).Count)) { throw 'LLAMA_SESSION_PROTECTION_INVALID' }
    $consumers = @()
    $plans = @()
    if ($stateRoot) {
        $directory = Join-Path $stateRoot 'shared-ai-gateways'
        if (Test-Path -LiteralPath $directory) {
            $null = Assert-LabAiSharedGatewayStoragePath $directory
            foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Directory -ErrorAction Stop)) {
                $path = Join-Path $entry.FullName 'plan.json'
                $null = Assert-LabAiSharedGatewayStoragePath $path
                $plan = Resolve-LabAiSharedGatewayPlan (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 30)
                if (([uri]$plan.UpstreamLocation).Port -eq $Port) {
                    $plans += $plan.PlanKey
                    $consumers += @($plan.Consumers)
                }
            }
        }
    }
    $protected = @($registry.environments | ForEach-Object { [string]$_.runId })
    $blocked = @($consumers | Where-Object { [string]$_.RunId -in $protected }).Count -gt 0
    [pscustomobject]@{ Key=(Get-LabAiPlanKey ([ordered]@{DataRoot=$dataRoot;StateRoot=$stateRoot;ExportRoot=$exportRoot;RegistryVersion=$registry.contractVersion;Protected=@($protected | Sort-Object);Plans=@($plans | Sort-Object)}))
        KnownConsumerCount=$consumers.Count; Protected=$blocked; DataRoot=$dataRoot; StateRoot=$stateRoot; ExportRoot=$exportRoot; Coverage='UNKNOWN' }
}

function Get-LabLlamaCppSessionView {
    $rows = @()
    if ($script:LlamaCppOwnedSessions) {
        $rows = @(foreach ($id in @($script:LlamaCppOwnedSessions.Keys | Sort-Object)) {
            $session = $script:LlamaCppOwnedSessions[$id]
            [pscustomobject]@{ OperationId=$id; Port=$session.Port
                Status=$(if ($session.Worker.HasExited) { 'CLEANUP_PENDING' } else { 'OWNED_SESSION' }) }
        })
    }
    [pscustomobject]@{ Items=$rows; Notice='Nur llama.cpp-Sitzungen dieses Modulhosts. Andere Prozesse und Modulsitzungen werden nicht übernommen. Verbraucher-Coverage UNKNOWN: auch unbekannte SQL-Verbraucher können ausfallen. Leere Sicht: im selben Modulhost starten; Import -Force beendet die bisherige Ownership.' }
}

function New-LabLlamaCppSessionStopPlan {
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$OperationId)
    if (-not $script:LlamaCppOwnedSessions -or -not $script:LlamaCppOwnedSessions.ContainsKey($OperationId)) { throw 'LLAMA_OWNERSHIP_NOT_FOUND' }
    $session = $script:LlamaCppOwnedSessions[$OperationId]
    $publicationLock=$null;$registryLock=$null
    $stateRoot=Get-LabStateRoot
    $exportRoot=if (Get-LabDataRootDefault) { Get-LabTestEnvironmentExportDirectory } else { $null }
    try {
        $publicationLock=Enter-LabAiSharedGatewayLifecycleLock -StateRoot $stateRoot
        if ($exportRoot) { $registryLock=Enter-LabTestGroupLock -OutputDirectory $exportRoot }
        $context = Get-LabLlamaCppSessionConsumerContext -Port $session.Port
        if ((Get-LabCanonicalResourceRoot $context.StateRoot) -cne (Get-LabCanonicalResourceRoot $stateRoot) -or
            [string]$context.ExportRoot -cne [string]$exportRoot) { throw 'LLAMA_SESSION_PREVIEW_STALE' }
    } finally { if ($registryLock) { Exit-LabTestGroupLock $registryLock };Exit-LabAiSharedGatewayLifecycleLock $publicationLock }
    if ($context.Protected) { throw 'LLAMA_SESSION_PROTECTED_CONSUMER' }
    if (-not $script:LlamaCppStopPlans) { $script:LlamaCppStopPlans=@{} }
    foreach ($key in @($script:LlamaCppStopPlans.Keys)) {
        if ($script:LlamaCppStopPlans[$key].Expires -le [datetime]::UtcNow) { $script:LlamaCppStopPlans.Remove($key) }
    }
    if ($script:LlamaCppStopPlans.Count -ge 32) { throw 'LLAMA_SESSION_PREVIEW_LIMIT' }
    $token=[guid]::NewGuid().ToString('D')
    $script:LlamaCppStopPlans[$token]=@{OperationId=$OperationId;Session=$session;Worker=$session.Worker;Port=$session.Port;StateRoot=$context.StateRoot;ExportRoot=$context.ExportRoot;ContextKey=$context.Key;Expires=[datetime]::UtcNow.AddMinutes(5)}
    [pscustomobject]@{ PlanId=$token;OperationId=$OperationId;Port=$session.Port;KnownConsumerCount=$context.KnownConsumerCount
        ConsumerCoverage='UNKNOWN';Rights='OWNED_WORKER_CONTROL';Notice='Ausgewählte eigene Sitzung stoppen und temporären API-Key entfernen. Callerdateien bleiben erhalten. Bekannte und unbekannte SQL-Verbraucher können ausfallen. Kein automatischer Neustart; für Wiederaufnahme ist ein ausdrücklicher neuer Start erforderlich.' }
}

function Invoke-LabLlamaCppSessionStopPlan {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$PlanId,[switch]$Confirmed)
    if (-not $Confirmed) { return [pscustomobject]@{Status='CANCELLED'} }
    if (-not $script:LlamaCppStopPlans -or -not $script:LlamaCppStopPlans.ContainsKey($PlanId)) { throw 'LLAMA_SESSION_PREVIEW_NOT_FOUND' }
    $plan=$script:LlamaCppStopPlans[$PlanId]
    if ($plan.Expires -le [datetime]::UtcNow) { $script:LlamaCppStopPlans.Remove($PlanId);throw 'LLAMA_SESSION_PREVIEW_EXPIRED' }
    $lock=$null;$publicationLock=$null
    try {
        # Fixed order: StateRoot publication/lifecycle, then test-group registry.
        $publicationLock=Enter-LabAiSharedGatewayLifecycleLock -StateRoot $plan.StateRoot
        if ($plan.ExportRoot) { $lock=Enter-LabTestGroupLock -OutputDirectory $plan.ExportRoot }
        if (-not $script:LlamaCppOwnedSessions -or -not $script:LlamaCppOwnedSessions.ContainsKey($plan.OperationId) -or
            -not [object]::ReferenceEquals($script:LlamaCppOwnedSessions[$plan.OperationId],$plan.Session) -or
            -not [object]::ReferenceEquals($plan.Session.Worker,$plan.Worker) -or $plan.Session.Port -ne $plan.Port) { throw 'LLAMA_SESSION_PREVIEW_STALE' }
        $context=Get-LabLlamaCppSessionConsumerContext -Port $plan.Session.Port
        if ($context.Protected) { throw 'LLAMA_SESSION_PROTECTED_CONSUMER' }
        if ($context.Key -cne $plan.ContextKey) { throw 'LLAMA_SESSION_PREVIEW_STALE' }
        if ($PSCmdlet.ShouldProcess($plan.OperationId,'Eigene llama.cpp-Sitzung stoppen; unbekannte Verbraucher können ausfallen')) {
            $finalContext=Get-LabLlamaCppSessionConsumerContext -Port $plan.Session.Port
            if ($finalContext.Protected) { throw 'LLAMA_SESSION_PROTECTED_CONSUMER' }
            if ($finalContext.Key -cne $plan.ContextKey) { throw 'LLAMA_SESSION_PREVIEW_STALE' }
            $script:LlamaCppStopPlans.Remove($PlanId)
            Stop-LabLlamaCppOwnedRuntime -OperationId $plan.OperationId
        }
    } finally { if ($lock) { Exit-LabTestGroupLock $lock };Exit-LabAiSharedGatewayLifecycleLock $publicationLock }
}

function Show-LabLlamaCppSessionStopInteractive {
    while ($true) {
        $view=Get-LabLlamaCppSessionView
        $items=@($view.Items | ForEach-Object { New-LabConsoleItem -Id $_.OperationId -Label ('Port '+$_.Port+' · '+$_.OperationId) -Value $_.Status })
        $items+=New-LabConsoleItem -Id back -Label 'Zurück' -Shortcut 0
        $choice=Invoke-LabConsoleMenu -ScreenId 'llama-session-stop' -Title 'Eigene llama.cpp-Sitzung stoppen' -Subtitle $view.Notice -Items $items
        if ($choice.Status -eq 'Refresh') { continue }
        if ($choice.Status -ne 'Selected' -or $choice.SelectedItem.Id -eq 'back') { return }
        try {
            $plan=New-LabLlamaCppSessionStopPlan -OperationId $choice.SelectedItem.Id
            Write-Host ($plan | ConvertTo-Json -Depth 3)
            if (Read-LabConfirm -Prompt 'Angezeigte Sitzung stoppen; auch unbekannte SQL-Verbraucher können ausfallen?' -Default $false) {
                $result=Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId -Confirmed -Confirm:$false
                Write-LabInfo $result.Status
            }
        } catch { Write-LabWarning ('Stop nicht bestätigt: '+$_.Exception.Message+'. Neu lesen und vorprüfen; bei Recovery eigene Sitzung gezielt bereinigen.') }
        Wait-LabConsoleAcknowledgement
    }
}
