function Invoke-LabCleanup {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter()]
        [switch] $Recovery,

        [Parameter()]
        [string] $StateRoot = (Get-LabDefaultStateRoot)
    )

    $runDirectory = Get-LabRunDirectory -LabRunId $LabRunId -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $runDirectory -PathType Container)) {
        throw 'Cleanup requires an existing LAB-001 run state.'
    }
    $paths = [pscustomobject] @{
        RunDirectory = $runDirectory
        StatePath = (Join-Path $runDirectory 'run-state.json')
        RegistryPath = (Join-Path $runDirectory 'resource-registry.json')
        LogPath = (Join-Path $runDirectory 'events.jsonl')
        LockPath = (Join-Path $runDirectory 'run.lock')
    }
    if (
        -not (Test-Path -LiteralPath $paths.StatePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $paths.RegistryPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $paths.LockPath -PathType Leaf)
    ) {
        throw 'Cleanup requires complete existing LAB-001 state files.'
    }
    $stateLock = Enter-LabStateLock -LockPath $paths.LockPath
    try {
        $registry = Read-LabJsonFile -Path $paths.RegistryPath
        if ($registry.LabRunId -ne $LabRunId) {
            throw 'Cleanup registry owner does not match LabRunId.'
        }

        $resources = @($registry.Resources)
        foreach ($resource in $resources) {
            if ($resource.OwnerRunId -ne $LabRunId) {
                throw 'Cleanup registry contains a foreign owner.'
            }
            if (
                [string] $resource.ResourceId -notmatch
                '^[A-Z0-9][A-Z0-9_-]{2,127}$'
            ) {
                throw 'Cleanup registry contains an invalid ResourceId.'
            }
            if (
                [Management.Automation.WildcardPattern]::ContainsWildcardCharacters(
                    [string] $resource.ExactLocator
                )
            ) {
                throw 'Cleanup registry contains a wildcard locator.'
            }

            $isLocalFile = (
                $resource.Provider -eq 'LOCAL_FILESYSTEM' -and
                $resource.ResourceType -in @('FILE', 'DIRECTORY')
            )
            $isDockerObject = (
                $resource.Provider -eq 'DOCKER' -and
                $resource.ResourceType -in @('CONTAINER', 'NETWORK', 'VOLUME')
            )
            if (-not $isLocalFile -and -not $isDockerObject) {
                throw 'Cleanup registry contains an unsupported resource handler.'
            }
            if (
                $isLocalFile -and
                -not (Test-LabPathWithinRoot `
                        -Path $resource.ExactLocator `
                        -Root $resource.BoundaryLocator)
            ) {
                throw 'Cleanup registry contains a locator outside the run boundary.'
            }
            if ($resource.ResourceType -eq 'DIRECTORY') {
                $markerPath = Join-Path $resource.ExactLocator '.lab-owner'
                if (
                    -not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
                    (Get-Content -LiteralPath $markerPath -Raw -Encoding utf8).Trim() -ne
                    $LabRunId
                ) {
                    throw 'Cleanup directory ownership marker is invalid.'
                }
            }
            if (
                $isDockerObject -and
                $resource.ResourceType -in @('CONTAINER', 'NETWORK') -and
                [string] $resource.ExactLocator -notmatch '^[a-f0-9]{64}$'
            ) {
                throw 'Cleanup registry contains an invalid Docker object ID.'
            }
            if (
                $isDockerObject -and
                $resource.ResourceType -eq 'VOLUME' -and
                [string] $resource.ExactLocator -notmatch
                '^[a-z0-9][a-z0-9_.-]{2,127}$'
            ) {
                throw 'Cleanup registry contains an invalid Docker volume identity.'
            }
        }

        $actionName = if ($Recovery) {
            'RecoveryCleanup'
        }
        else {
            'Down'
        }
        if (-not $PSCmdlet.ShouldProcess(
                "exactly $($resources.Count) registered resources owned by $LabRunId",
                $actionName
            )) {
            return [pscustomobject] @{
                LabRunId = $LabRunId
                CleanupStatus = 'WHATIF'
                RemovedResourceCount = 0
                RemainingResourceCount = $resources.Count
            }
        }

        $remainingResources = [Collections.Generic.List[object]]::new()
        $removedResourceCount = 0
        $orderedResources = @(
            $resources |
                Sort-Object {
                    if ($_.ResourceType -eq 'CONTAINER') { 10 }
                    elseif ($_.ResourceType -eq 'NETWORK') { 20 }
                    elseif ($_.ResourceType -eq 'VOLUME') { 30 }
                    elseif ($_.ResourceType -eq 'FILE') { 40 }
                    else { 50 }
                }
        )
        foreach ($resource in $orderedResources) {
            try {
                if ($resource.Provider -eq 'LOCAL_FILESYSTEM') {
                    if ($resource.ResourceType -eq 'DIRECTORY') {
                        if (
                            Test-Path `
                                -LiteralPath $resource.ExactLocator `
                                -PathType Container
                        ) {
                            [IO.Directory]::Delete($resource.ExactLocator, $true)
                        }
                    }
                    elseif (
                        Test-Path -LiteralPath $resource.ExactLocator -PathType Leaf
                    ) {
                        Remove-Item -LiteralPath $resource.ExactLocator -Force
                    }
                }
                else {
                    Remove-LabDockerResource `
                        -LabRunId $LabRunId `
                        -ResourceType $resource.ResourceType `
                        -ExactLocator $resource.ExactLocator
                }
                $removedResourceCount++
            }
            catch {
                $remainingResources.Add($resource)
            }
        }

        Write-LabJsonFile -Path $paths.RegistryPath -InputObject ([ordered] @{
                SchemaVersion = '1.0'
                DataClassification = 'LOCAL_RUNTIME_STATE'
                LabRunId = $LabRunId
                Resources = @($remainingResources)
            })
        $cleanupStatus = if ($remainingResources.Count -eq 0) {
            'CLEANUP_COMPLETED'
        }
        else {
            'CLEANUP_INCOMPLETE'
        }
        Set-LabRunState -StatePath $paths.StatePath -Changes @{
            LifecycleStatus = $cleanupStatus
            CleanupMode = $actionName
        }
        $logLevel = if ($remainingResources.Count -eq 0) {
            'INFO'
        }
        else {
            'ERROR'
        }
        Write-LabEvent `
            -LogPath $paths.LogPath `
            -Level $logLevel `
            -EventCode $cleanupStatus `
            -Properties @{
                LabRunId = $LabRunId
                RemovedResourceCount = $removedResourceCount
                RemainingResourceCount = $remainingResources.Count
            }

        return [pscustomobject] @{
            LabRunId = $LabRunId
            CleanupStatus = $cleanupStatus
            RemovedResourceCount = $removedResourceCount
            RemainingResourceCount = $remainingResources.Count
        }
    }
    finally {
        $stateLock.Dispose()
    }
}
