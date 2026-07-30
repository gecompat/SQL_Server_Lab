<#
.SYNOPSIS
    Cleanup-Engine fuer SQL_Server_Lab.
.DESCRIPTION
    Erstellt maschinenlesbare Cleanup-Plaene vor Mutationen und fuehrt
    ausstehende Schritte in umgekehrter Reihenfolge providergebunden aus.
#>

function New-CleanupPlan {
    <#
    .SYNOPSIS
        Erstellt einen leeren Cleanup-Plan fuer einen Run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId,
        [array]$ProviderSubRuns = @()
    )

    $cleanupSubRuns = @(
        foreach ($providerSubRun in @($ProviderSubRuns)) {
            $provider = ([string]$providerSubRun.provider).ToLowerInvariant()
            if (-not $provider) {
                throw 'Cleanup-ProviderSubRun besitzt keinen Provider.'
            }

            [PSCustomObject]@{
                id          = if ($providerSubRun.id) { [string]$providerSubRun.id } else { "provider-$provider" }
                provider    = $provider
                stepOrders  = @()
                state       = 'PENDING'
                updatedAt   = Get-LabTimestamp
                errors      = 0
            }
        }
    )

    $plan = [PSCustomObject]@{
        runId     = $RunId
        scopeId   = $ScopeId
        createdAt = Get-LabTimestamp
        providerSubRuns = $cleanupSubRuns
        steps     = @()
        status    = 'PENDING'
    }

    $planPath = Join-Path $RunDir 'cleanup-plan.json'
    $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planPath -Encoding utf8
    return $plan
}

function Add-CleanupStep {
    <#
    .SYNOPSIS
        Fuegt einen providergebundenen Schritt zum Cleanup-Plan hinzu.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][string]$ResourceType,
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$Action,
        [ValidateSet('docker', 'podman', 'hyperv')]
        [string]$Provider,
        [string]$ProviderSubRunId,
        [string]$Compensation = '',
        [string[]]$DependsOn = @()
    )

    $planPath = Join-Path $RunDir 'cleanup-plan.json'
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        throw "Cleanup-Plan nicht gefunden: $planPath"
    }

    $plan = Get-Content -LiteralPath $planPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    $order = @($plan.steps).Count + 1

    $step = [PSCustomObject]@{
        order        = $order
        resourceType = $ResourceType
        resourceId   = $ResourceId
        action       = $Action
        provider     = $Provider
        compensation = $Compensation
        dependsOn    = @($DependsOn)
        state        = 'PENDING'
        executedAt   = $null
        error        = $null
    }

    $plan.steps += $step

    if ($ProviderSubRunId -and $plan.PSObject.Properties['providerSubRuns']) {
        $providerSubRun = @(
            $plan.providerSubRuns | Where-Object { $_.id -eq $ProviderSubRunId }
        ) | Select-Object -First 1
        if (-not $providerSubRun) {
            throw "Cleanup-ProviderSubRun '$ProviderSubRunId' nicht gefunden."
        }
        $providerSubRun.stepOrders += $order
        $providerSubRun.updatedAt = Get-LabTimestamp
    }

    $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planPath -Encoding utf8
    return $step
}

function Get-CleanupStepProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Step,
        [string[]]$RunProviders = @()
    )

    if ($Step.provider -in @('docker', 'podman')) {
        return [string]$Step.provider
    }

    $compensationText = [string]$Step.compensation
    if ($compensationText -match '^\s*(docker|podman)\b') {
        return $Matches[1].ToLowerInvariant()
    }

    $uniqueProviders = @($RunProviders | Where-Object { $_ } | Sort-Object -Unique)
    if ($uniqueProviders.Count -eq 1 -and $uniqueProviders[0] -in @('docker', 'podman')) {
        return [string]$uniqueProviders[0]
    }

    return $null
}

function Remove-LabContainerForCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$ContainerIdOrName,
        [Parameter(Mandatory)][string]$ExpectedScopeId
    )

    switch ($Provider) {
        'docker' {
            $null = Remove-DockerInstance `
                -ContainerIdOrName $ContainerIdOrName `
                -ExpectedScopeId $ExpectedScopeId
        }
        'podman' {
            $null = Remove-PodmanInstance `
                -ContainerIdOrName $ContainerIdOrName `
                -ExpectedScopeId $ExpectedScopeId
        }
        default {
            throw "Cleanup-Provider '$Provider' wird fuer Container nicht unterstuetzt."
        }
    }
}

function Remove-LabRuntimeResourceForCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)][ValidateSet('volume', 'network')][string]$ResourceType,
        [Parameter(Mandatory)][string]$ResourceId
    )

    & $Provider $ResourceType inspect $ResourceId 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-LabInfo "  Bereits entfernt oder nicht vorhanden: $ResourceType $ResourceId"
        return
    }

    & $Provider $ResourceType rm $ResourceId 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "$Provider konnte $ResourceType '$ResourceId' nicht entfernen."
    }
}

function Invoke-CleanupPlan {
    <#
    .SYNOPSIS
        Fuehrt ausstehende Cleanup-Schritte in umgekehrter Reihenfolge aus.
    .OUTPUTS
        PSCustomObject mit Status, Steps, Errors und Total.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][string]$ScopeId
    )

    $planPath = Join-Path $RunDir 'cleanup-plan.json'
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        Write-LabWarning 'Kein Cleanup-Plan gefunden.'
        return [PSCustomObject]@{
            Status = 'CLEANUP_SUCCEEDED'
            Steps  = 0
            Errors = 0
            Total  = 0
        }
    }

    $plan = Get-Content -LiteralPath $planPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    $plan.status = 'EXECUTING'
    $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planPath -Encoding utf8

    $connectionInfoPath = Join-Path $RunDir 'connection-info.json'
    $runProviders = @()
    if (Test-Path -LiteralPath $connectionInfoPath -PathType Leaf) {
        try {
            $connectionInfo = Get-Content -LiteralPath $connectionInfoPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
            $runProviders = @($connectionInfo.instances | ForEach-Object { $_.provider })
        }
        catch {
            Write-LabWarning "Connection-Info konnte fuer Cleanup nicht gelesen werden: $($_.Exception.Message)"
        }
    }

    $pendingSteps = @(
        $plan.steps |
            Where-Object { $_.state -eq 'PENDING' } |
            Sort-Object order -Descending
    )

    $errors = 0
    $executed = 0
    $providerResults = @{}

    foreach ($providerSubRun in @($plan.providerSubRuns)) {
        if ($providerSubRun.state -eq 'PENDING') {
            $providerSubRun.state = 'RUNNING'
            $providerSubRun.updatedAt = Get-LabTimestamp
        }
    }
    $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planPath -Encoding utf8

    foreach ($step in $pendingSteps) {
        Write-LabInfo "Cleanup [$($step.order)]: $($step.action) $($step.resourceType):$($step.resourceId)"

        $provider = $null
        try {
            $provider = Get-CleanupStepProvider -Step $step -RunProviders $runProviders
            if ($provider -and -not $providerResults.ContainsKey($provider)) {
                $providerResults[$provider] = [PSCustomObject]@{
                    Provider = $provider
                    Steps    = 0
                    Errors   = 0
                    Total    = 0
                    Status   = 'PENDING'
                }
            }
            if ($provider) {
                $providerResults[$provider].Total++
            }

            switch ($step.resourceType) {
                'container' {
                    if (-not $provider) {
                        throw "Provider fuer Container '$($step.resourceId)' ist nicht bestimmbar."
                    }
                    Remove-LabContainerForCleanup `
                        -Provider $provider `
                        -ContainerIdOrName $step.resourceId `
                        -ExpectedScopeId $ScopeId
                }
                'volume' {
                    if (-not $provider) {
                        throw "Provider fuer Volume '$($step.resourceId)' ist nicht bestimmbar."
                    }
                    Remove-LabRuntimeResourceForCleanup `
                        -Provider $provider `
                        -ResourceType 'volume' `
                        -ResourceId $step.resourceId
                }
                'network' {
                    if (-not $provider) {
                        throw "Provider fuer Netzwerk '$($step.resourceId)' ist nicht bestimmbar."
                    }
                    Remove-LabRuntimeResourceForCleanup `
                        -Provider $provider `
                        -ResourceType 'network' `
                        -ResourceId $step.resourceId
                }
                default {
                    throw "Unbekannter Cleanup-Ressourcentyp: $($step.resourceType)"
                }
            }

            $step.state = 'COMPLETED'
            $step.executedAt = Get-LabTimestamp
            $step.error = $null
            $executed++
            if ($provider) {
                $providerResults[$provider].Steps++
            }
            Write-LabSuccess "  Entfernt: $($step.resourceId)"
        }
        catch {
            $step.state = 'FAILED'
            $step.error = $_.Exception.Message
            $step.executedAt = Get-LabTimestamp
            $errors++
            if ($provider) {
                $providerResults[$provider].Errors++
            }
            Write-LabError "  Fehlgeschlagen: $($step.resourceId) - $($_.Exception.Message)"
        }

        $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planPath -Encoding utf8
    }

    $plan.status = if ($errors -eq 0) { 'COMPLETED' } else { 'PARTIAL' }
    foreach ($providerResult in @($providerResults.Values)) {
        $providerResult.Status = if ($providerResult.Errors -eq 0) { 'CLEANUP_SUCCEEDED' } else { 'CLEANUP_PARTIAL' }
    }

    foreach ($providerSubRun in @($plan.providerSubRuns)) {
        $providerResult = $providerResults[[string]$providerSubRun.provider]
        if ($providerResult) {
            $providerSubRun.errors = $providerResult.Errors
            $providerSubRun.state = if ($providerResult.Errors -eq 0) { 'COMPLETED' } else { 'PARTIAL' }
        }
        elseif (@($providerSubRun.stepOrders).Count -eq 0) {
            $providerSubRun.state = 'COMPLETED'
        }
        else {
            $providerSubRun.state = 'BLOCKED'
            $providerSubRun.errors = 1
        }
        $providerSubRun.updatedAt = Get-LabTimestamp
    }
    $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planPath -Encoding utf8

    $overallStatus = if ($errors -eq 0) {
        'CLEANUP_SUCCEEDED'
    }
    elseif ($executed -gt 0) {
        'CLEANUP_PARTIAL'
    }
    else {
        'CLEANUP_BLOCKED'
    }

    return [PSCustomObject]@{
        Status = $overallStatus
        Steps  = $executed
        Errors = $errors
        Total  = $pendingSteps.Count
        ProviderSubRuns = @($providerResults.Values | Sort-Object Provider)
    }
}

function Get-CleanupPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDir
    )

    $planPath = Join-Path $RunDir 'cleanup-plan.json'
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $planPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
}
