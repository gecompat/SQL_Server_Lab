<#
.SYNOPSIS
    Plant und persistiert einen providerneutralen Batch.
.DESCRIPTION
    Expandiert Mengen in stabile Positionen, validiert Provider und gemeinsame
    Abhaengigkeiten und reiht erst danach alle Kindvorgaenge atomar ein.
.PARAMETER Name
    Sichtbarer Name des Batch.
.PARAMETER Priority
    Gemeinsame Startprioritaet High, Normal oder Low.
.PARAMETER Defaults
    Gemeinsame Standardwerte fuer alle Positionen.
.PARAMETER Items
    Eine oder mehrere Positionen mit id, kind, count, intent und overrides.
.PARAMETER Manifest
    Pfad zu einem SqlServerLab.BatchManifest/1.0; ein eindeutiger offener Lauf wird fortgesetzt.
.PARAMETER Queue
    Legt fest, ob der validierte Batch sofort eingereiht wird.
.PARAMETER StateRoot
    Optionaler Root fuer den persistenten Workflow-State.
.OUTPUTS
    PSCustomObject mit dem persistenten SqlServerLab.Batch/1.0-Zustand.
#>
function New-SqlServerLabBatch {
    [CmdletBinding(DefaultParameterSetName = 'Items')]
    param(
        [Parameter(ParameterSetName = 'Items')]
        [string]$Name,

        [Parameter(ParameterSetName = 'Items')]
        [ValidateSet('High', 'Normal', 'Low')]
        [string]$Priority = 'Normal',

        [Parameter(ParameterSetName = 'Items')]
        [AllowNull()]
        [object]$Defaults,

        [Parameter(Mandatory, ParameterSetName = 'Items')]
        [object[]]$Items,

        [Parameter(Mandatory, ParameterSetName = 'Manifest')]
        [ValidateNotNullOrEmpty()]
        [string]$Manifest,

        [bool]$Queue = $true,

        [string]$StateRoot
    )

    $root = Initialize-LabWorkflowStore -StateRoot $StateRoot
    $manifestSource = $null
    if ($PSCmdlet.ParameterSetName -eq 'Manifest') {
        $manifestPath = (Resolve-Path -LiteralPath $Manifest -ErrorAction Stop).Path
        $manifestSource = Read-LabWorkflowJson -Path $manifestPath
        if ($null -eq $manifestSource) {
            throw "Batch-Manifest '$manifestPath' ist leer oder ungültig."
        }
        $Name = [string](Get-LabWorkflowValue -InputObject $manifestSource -Name 'name' -Default ([IO.Path]::GetFileNameWithoutExtension($manifestPath)))
        $Priority = [string](Get-LabWorkflowValue -InputObject $manifestSource -Name 'priority' -Default 'Normal')
        $Defaults = Get-LabWorkflowValue -InputObject $manifestSource -Name 'defaults' -Default @{}
        $Items = @(Get-LabWorkflowValue -InputObject $manifestSource -Name 'items' -Default @())
    }
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = 'Batch ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
    }
    if ($Priority -notin @('High', 'Normal', 'Low')) {
        throw "Ungültige Batch-Priorität '$Priority'."
    }
    if (@($Items).Count -eq 0) {
        throw 'Ein Batch benötigt mindestens eine Position.'
    }

    $sourceObject = [ordered]@{ name = $Name; priority = $Priority; defaults = $Defaults; items = $Items }
    $fingerprint = Get-LabWorkflowHash -Text ($sourceObject | ConvertTo-Json -Depth 50 -Compress) -Length 32
    if ($PSCmdlet.ParameterSetName -eq 'Manifest') {
        $existing = @(Get-SqlServerLabBatch -StateRoot $root | Where-Object {
            $_.sourceFingerprint -eq $fingerprint -and $_.status -notin @('Completed', 'CompletedWithErrors', 'Cancelled')
        } | Sort-Object createdAt -Descending | Select-Object -First 1)
        if ($existing.Count -eq 1) {
            return $existing[0]
        }
    }

    $availability = Get-LabProviderAvailabilityMap
    $batchId = 'batch-' + (Get-Date -Format 'yyyyMMddHHmmss') + '-' + ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    $expanded = @()
    $blocking = @()
    $warnings = @()
    $seenIds = @{}
    $seenNames = @{}
    $position = 0
    foreach ($sourceItem in @($Items)) {
        $position++
        $kind = [string](Get-LabWorkflowValue -InputObject $sourceItem -Name 'kind' -Default 'SqlEnvironment')
        $sourceId = ConvertTo-LabWorkflowSlug -Text ([string](Get-LabWorkflowValue -InputObject $sourceItem -Name 'id' -Default ("$kind-$position"))) -Fallback ("item-$position")
        $count = [int](Get-LabWorkflowValue -InputObject $sourceItem -Name 'count' -Default 1)
        if ($count -lt 1) {
            $blocking += "Position '$sourceId' hat eine ungültige Anzahl $count."
            continue
        }
        $intent = Get-LabWorkflowValue -InputObject $sourceItem -Name 'intent' -Default @{}
        $itemManifest = Get-LabWorkflowValue -InputObject $sourceItem -Name 'manifest' -Default @{}
        $overrides = Get-LabWorkflowValue -InputObject $sourceItem -Name 'overrides' -Default @{}
        $itemValues = ConvertTo-LabWorkflowHashtable -InputObject $sourceItem
        foreach ($ordinal in 1..$count) {
            $itemId = if ($count -gt 1) { '{0}-{1:d3}' -f $sourceId, $ordinal } else { $sourceId }
            if ($seenIds.ContainsKey($itemId)) {
                $blocking += "Doppelte expandierte ItemId '$itemId'."
                continue
            }
            $seenIds[$itemId] = $true
            $effective = Merge-LabWorkflowConfiguration -InputObject @($Defaults, $itemManifest, $intent, $overrides, $itemValues)
            $effective['ItemId'] = $itemId
            $baseName = [string](Get-LabWorkflowValue -InputObject $effective -Name 'LabName' -Default (Get-LabWorkflowValue -InputObject $effective -Name 'Name' -Default $sourceId))
            $resolvedName = if ($count -gt 1) { '{0}-{1:d3}' -f $baseName, $ordinal } else { $baseName }
            $effective['LabName'] = $resolvedName
            if ($seenNames.ContainsKey($resolvedName)) {
                $blocking += "Doppelter Umgebungsname '$resolvedName'."
            }
            $seenNames[$resolvedName] = $true
            $decision = Resolve-LabBatchProvider -Kind $kind -Effective $effective -Availability $availability
            if (-not [string]::IsNullOrWhiteSpace([string]$decision.blockingError)) {
                $blocking += "[$itemId] $($decision.blockingError)"
            }
            $expanded += [pscustomobject][ordered]@{
                itemId = $itemId
                sourceItemId = $sourceId
                ordinal = $ordinal
                kind = $kind
                name = $resolvedName
                effective = [pscustomobject]$effective
                provider = $decision.provider
                providerReason = $decision.reason
                resourceEstimate = Get-LabWorkflowResourceEstimate -Effective $effective
                overrides = [pscustomobject](ConvertTo-LabWorkflowHashtable -InputObject $overrides)
            }
        }
    }
    if ($blocking.Count -gt 0) {
        $message = "Batch-Preflight ist blockiert:`n - " + ($blocking -join "`n - ")
        throw $message
    }

    $dependencyPlans = [ordered]@{}
    foreach ($item in $expanded | Where-Object provider -eq 'hyperv') {
        $artifactId = [string](Get-LabWorkflowValue -InputObject $item.effective -Name 'ArtifactId' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($artifactId)) {
            $item | Add-Member -NotePropertyName artifactId -NotePropertyValue $artifactId -Force
            continue
        }
        $requirement = Get-LabArtifactRequirement -Effective (ConvertTo-LabWorkflowHashtable -InputObject $item.effective)
        $artifact = Find-LabMatchingHyperVArtifact -Requirement $requirement -StateRoot $root
        if ($null -ne $artifact) {
            $resolvedArtifactId = [string](Get-LabWorkflowValue -InputObject $artifact -Name 'ArtifactId' -Default (Get-LabWorkflowValue -InputObject $artifact -Name 'artifactId' -Default ''))
            $item | Add-Member -NotePropertyName artifactId -NotePropertyValue $resolvedArtifactId -Force
            $item.effective | Add-Member -NotePropertyName ArtifactId -NotePropertyValue $resolvedArtifactId -Force
            continue
        }
        $key = Get-LabWorkflowHash -Text ($requirement | ConvertTo-Json -Depth 20 -Compress) -Length 20
        if (-not $dependencyPlans.Contains($key)) {
            $dependencyPlans[$key] = [ordered]@{ requirement = $requirement; itemIds = @() }
        }
        $dependencyPlans[$key].itemIds = @($dependencyPlans[$key].itemIds) + $item.itemId
        $item | Add-Member -NotePropertyName dependencyKey -NotePropertyValue $key -Force
    }

    $operationStates = @()
    $operationIds = @()
    $dependencyIds = @()
    $queuePosition = 0
    foreach ($key in $dependencyPlans.Keys) {
        $queuePosition++
        $operationId = 'op-' + $batchId + '-dependency-' + $key.Substring(0, 8)
        $dependencyIds += $operationId
        $operationIds += $operationId
        $plan = $dependencyPlans[$key]
        $operation = New-LabOperationStateObject -OperationId $operationId -BatchId $batchId -ItemId ('dependency-' + $key.Substring(0, 8)) -Title 'Gemeinsame Hyper-V-Vorlage bereitstellen' -Kind 'Dependency' -Priority $Priority -QueuePosition $queuePosition -Provider 'hyperv' -ProviderReason 'Gemeinsame Voraussetzung für mehrere Positionen.' -ResourceClass 'HyperVHeavy' -Locks @('catalog:hyperv-artifacts') -Executor ([pscustomobject]@{ type = 'ResolveHyperVArtifact'; requirement = $plan.requirement; affectedItemIds = @($plan.itemIds) }) -Steps (Get-LabOperationStepsForPlan -Kind 'Dependency' -Provider 'hyperv' -Effective @{}) -CleanupPlan ([pscustomobject]@{ scope = 'Dependency'; removeOnlyIfUnpublished = $true })
        $operationStates += $operation
    }
    foreach ($item in $expanded) {
        $queuePosition++
        $operationId = 'op-' + $batchId + '-' + (ConvertTo-LabWorkflowSlug -Text $item.itemId)
        $operationIds += $operationId
        $dependencies = @()
        if (-not [string]::IsNullOrWhiteSpace([string](Get-LabWorkflowValue -InputObject $item -Name 'dependencyKey' -Default ''))) {
            $dependencies = @('op-' + $batchId + '-dependency-' + $item.dependencyKey.Substring(0, 8))
        }
        $resourceClass = if ($item.provider -eq 'hyperv') { 'HyperVHeavy' } elseif ($item.kind -match 'Lifecycle') { 'LifecycleLight' } else { [string](Get-LabWorkflowValue -InputObject $item.effective -Name 'ResourceClass' -Default 'RuntimeNormal') }
        $effective = ConvertTo-LabWorkflowHashtable -InputObject $item.effective
        if (-not [string]::IsNullOrWhiteSpace([string](Get-LabWorkflowValue -InputObject $item -Name 'artifactId' -Default ''))) {
            $effective['ArtifactId'] = $item.artifactId
        }
        $operationLocks = @(Get-LabWorkflowValue -InputObject $effective -Name 'Locks' -Default @('environment:' + $item.name.ToLowerInvariant()))
        $operation = New-LabOperationStateObject -OperationId $operationId -BatchId $batchId -ItemId $item.itemId -Title $item.name -Kind $item.kind -Priority $Priority -QueuePosition $queuePosition -Provider $item.provider -ProviderReason $item.providerReason -ResourceClass $resourceClass -Locks $operationLocks -Dependencies $dependencies -Executor ([pscustomobject]@{ type = 'CreateEnvironment'; effective = [pscustomobject]$effective }) -Steps (Get-LabOperationStepsForPlan -Kind $item.kind -Provider $item.provider -Effective $effective) -CleanupPlan ([pscustomobject]@{ scope = 'Operation'; ownedRunOnly = $true; preservePersistentData = [bool](Get-LabWorkflowValue -InputObject $effective -Name 'PersistentData' -Default $false) })
        $operationStates += $operation
    }
    foreach ($dependency in $operationStates | Where-Object kind -eq 'Dependency') {
        $dependency.dependents = @($operationStates | Where-Object { $dependency.operationId -in @($_.dependencies) } | ForEach-Object operationId)
    }

    $cpu = (@($expanded.resourceEstimate | Measure-Object -Property cpu -Sum).Sum)
    $memory = (@($expanded.resourceEstimate | Measure-Object -Property memoryMB -Sum).Sum)
    $storage = (@($expanded.resourceEstimate | Measure-Object -Property storageGB -Sum).Sum)
    $now = Get-LabWorkflowUtcNow
    $batch = [pscustomobject][ordered]@{
        contract = 'SqlServerLab.Batch/1.0'
        batchId = $batchId
        name = $Name
        priority = $Priority
        createdAt = $now
        updatedAt = $now
        status = 'Draft'
        sourceFingerprint = $fingerprint
        defaults = [pscustomobject](ConvertTo-LabWorkflowHashtable -InputObject $Defaults)
        items = @($expanded)
        operationIds = @($operationIds)
        dependencyOperationIds = @($dependencyIds)
        sharedDependencies = @($dependencyPlans.Keys | ForEach-Object { [pscustomobject]@{ key = $_; requirement = [pscustomobject]$dependencyPlans[$_].requirement; itemIds = @($dependencyPlans[$_].itemIds) } })
        preflight = [pscustomobject][ordered]@{
            validatedAt = $now
            blockingConflicts = @()
            warnings = @($warnings)
            providerAvailability = [pscustomobject]$availability
            estimatedResources = [pscustomobject]@{ cpu = $cpu; memoryMB = $memory; storageGB = $storage }
            maxWorkers = 2
            maxHyperVHeavy = 1
        }
        progress = [pscustomobject]@{ percent = 0; total = $operationIds.Count; counts = [pscustomobject]@{} }
        errorStatus = [pscustomobject]@{ failed = 0; cancelled = 0; hasErrors = $false }
        cleanupPlan = [pscustomobject][ordered]@{
            scope = 'Batch'
            operationIds = @($operationIds)
            completedResourcesRequireExplicitRollback = $true
            preservePublishedArtifacts = $true
            preserveMediaLibraries = $true
            preserveProtectedPersistentData = $true
        }
        manifestSource = if ($null -eq $manifestSource) { $null } else { [pscustomobject](ConvertTo-LabWorkflowHashtable -InputObject $manifestSource) }
    }

    Write-LabBatchState -Batch $batch -StateRoot $root | Out-Null
    foreach ($operation in $operationStates) {
        Add-LabOperationEvent -Operation $operation -Type 'Planned' -Message 'Vorgang wurde vollständig geplant und persistent angelegt.' -StateRoot $root | Out-Null
        Write-LabOperationState -Operation $operation -StateRoot $root | Out-Null
    }
    $batch.status = if ($Queue) { 'Queued' } else { 'Validated' }
    Write-LabBatchState -Batch $batch -StateRoot $root | Out-Null
    return $batch
}

<#
.SYNOPSIS
    Liest persistente Batchzustaende.
.DESCRIPTION
    Gibt einen bestimmten Batch oder alle Batches mit Plan, Fortschritt,
    Abhaengigkeiten, Fehlerstatus und Cleanup-Scope zurueck.
.PARAMETER BatchId
    Optionale stabile ID des gesuchten Batch.
.PARAMETER StateRoot
    Optionaler Root des persistenten Workflow-State.
.OUTPUTS
    PSCustomObject oder Objektliste mit SqlServerLab.Batch/1.0-Zustaenden.
#>
function Get-SqlServerLabBatch {
    [CmdletBinding()]
    param(
        [string]$BatchId,
        [string]$StateRoot
    )

    $root = Initialize-LabWorkflowStore -StateRoot $StateRoot
    if (-not [string]::IsNullOrWhiteSpace($BatchId)) {
        $batch = Read-LabWorkflowJson -Path (Get-LabBatchStatePath -BatchId $BatchId -StateRoot $root)
        if ($null -eq $batch) {
            throw "Batch '$BatchId' wurde nicht gefunden."
        }
        return $batch
    }
    return @(Get-ChildItem -LiteralPath (Join-Path $root 'batches') -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { Read-LabWorkflowJson -Path $_.FullName } | Sort-Object createdAt -Descending)
}

<#
.SYNOPSIS
    Liest persistente Kindvorgaenge.
.DESCRIPTION
    Gibt Operationen mit Schritten, Receipts, Events, Locks, User-Gate und Ergebnis zurueck.
.PARAMETER OperationId
    Optionale stabile ID eines einzelnen Vorgangs.
.PARAMETER BatchId
    Optionaler Filter auf einen Batch.
.PARAMETER StateRoot
    Optionaler Root des persistenten Workflow-State.
.OUTPUTS
    PSCustomObject oder Objektliste mit SqlServerLab.Operation/1.0-Zustaenden.
#>
function Get-SqlServerLabOperation {
    [CmdletBinding()]
    param(
        [string]$OperationId,
        [string]$BatchId,
        [string]$StateRoot
    )

    $root = Initialize-LabWorkflowStore -StateRoot $StateRoot
    if (-not [string]::IsNullOrWhiteSpace($OperationId)) {
        $operation = Read-LabWorkflowJson -Path (Get-LabOperationStatePath -OperationId $OperationId -StateRoot $root)
        if ($null -eq $operation) {
            throw "Vorgang '$OperationId' wurde nicht gefunden."
        }
        return $operation
    }
    $operations = @(Get-ChildItem -LiteralPath (Join-Path $root 'operations') -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { Read-LabWorkflowJson -Path $_.FullName })
    if (-not [string]::IsNullOrWhiteSpace($BatchId)) {
        $operations = @($operations | Where-Object batchId -eq $BatchId)
    }
    return @($operations | Sort-Object @{ Expression = { Get-LabPriorityRank -Priority $_.priority } }, queuePosition, createdAt)
}

<#
.SYNOPSIS
    Zeigt Queue, Worker und Blockierungen.
.DESCRIPTION
    Liefert laufende Worker, belegte Ressourcenklassen und Locks, die naechste
    startbare Position sowie wartende User-Gates ohne Runtime-Mutation.
.PARAMETER StateRoot
    Optionaler Root des persistenten Workflow-State.
.OUTPUTS
    PSCustomObject mit dem SqlServerLab.Queue/1.0-Snapshot.
#>
function Get-SqlServerLabQueue {
    [CmdletBinding()]
    param([string]$StateRoot)

    $settings = Get-LabSchedulerSettings -StateRoot $StateRoot
    $operations = @(Get-SqlServerLabOperation -StateRoot $StateRoot)
    $running = @($operations | Where-Object status -eq 'Running')
    $startable = @(Get-LabStartableOperations -MaxWorkers ([int]$settings.maxWorkers) -StateRoot $StateRoot)
    $rows = foreach ($operation in $operations | Where-Object { -not (Test-LabOperationTerminal -Status $_.status) }) {
        $blockedReason = $null
        if ($operation.status -eq 'WaitingForDependency') { $blockedReason = 'Wartet auf gemeinsame Abhängigkeit.' }
        elseif ($operation.status -in @('WaitingForUser', 'CandidateSatisfied')) { $blockedReason = 'Wartet auf ausdrückliche Benutzerbestätigung.' }
        elseif ($operation.status -eq 'Paused') { $blockedReason = 'Vom Benutzer pausiert.' }
        elseif ($operation.resourceClass -eq 'HyperVHeavy' -and @($running | Where-Object resourceClass -eq 'HyperVHeavy').Count -gt 0) { $blockedReason = 'HyperVHeavy-Slot ist belegt.' }
        elseif (@($operation.locks | Where-Object { $_ -in @($running | ForEach-Object { @($_.locks) }) }).Count -gt 0) { $blockedReason = 'Exklusiver Ressourcen-Lock ist belegt.' }
        [pscustomobject][ordered]@{
            operationId = $operation.operationId
            batchId = $operation.batchId
            itemId = $operation.itemId
            title = $operation.title
            status = $operation.status
            progress = $operation.progress
            priority = $operation.priority
            queuePosition = $operation.queuePosition
            resourceClass = $operation.resourceClass
            locks = @($operation.locks)
            provider = $operation.provider
            blockedReason = $blockedReason
            startable = $operation.operationId -in @($startable.operationId)
            candidateSatisfied = $operation.status -eq 'CandidateSatisfied'
            userGate = $operation.userGate
        }
    }
    return [pscustomobject][ordered]@{
        contract = 'SqlServerLab.Queue/1.0'
        generatedAt = Get-LabWorkflowUtcNow
        maxWorkers = [int]$settings.maxWorkers
        maxHyperVHeavy = [int]$settings.maxHyperVHeavy
        runningWorkers = $running.Count
        running = @($rows | Where-Object status -eq 'Running')
        nextStartable = @($rows | Where-Object startable | Select-Object -First 1)
        waitingUserGates = @($rows | Where-Object status -in @('WaitingForUser', 'CandidateSatisfied')).Count
        length = @($rows | Where-Object status -in @('Queued', 'WaitingForDependency', 'CleanupQueued')).Count
        items = @($rows)
    }
}

<#
.SYNOPSIS
    Setzt die Prioritaet eines Kindvorgangs.
.DESCRIPTION
    Markiert die Prioritaet als individuelle Ueberschreibung; ein bereits
    laufender atomarer Schritt wird nicht unterbrochen.
.PARAMETER OperationId
    Eine oder mehrere stabile Vorgangs-IDs.
.PARAMETER Priority
    Neue Prioritaet High, Normal oder Low.
.PARAMETER StateRoot
    Optionaler Root des persistenten Workflow-State.
.OUTPUTS
    PSCustomObject oder Objektliste mit den aktualisierten Operationen.
#>
function Set-SqlServerLabOperationPriority {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$OperationId,
        [Parameter(Mandatory)]
        [ValidateSet('High', 'Normal', 'Low')]
        [string]$Priority,
        [string]$StateRoot
    )

    $result = @()
    foreach ($id in $OperationId) {
        $operation = Get-SqlServerLabOperation -OperationId $id -StateRoot $StateRoot
        if ($operation.status -eq 'Running') {
            $operation.priority = $Priority
            $operation.priorityOverridden = $true
        }
        elseif (-not (Test-LabOperationTerminal -Status $operation.status)) {
            $operation.priority = $Priority
            $operation.priorityOverridden = $true
        }
        Add-LabOperationEvent -Operation $operation -Type 'PriorityChanged' -Message "Priorität wurde auf '$Priority' gesetzt; laufende atomare Schritte bleiben unberührt." -StateRoot $StateRoot | Out-Null
        Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
        $result += $operation
    }
    return $result
}

<#
.SYNOPSIS
    Reiht einen wartenden Vorgang um.
.DESCRIPTION
    Verschiebt einen nicht laufenden Vorgang innerhalb seiner sichtbaren Prioritaetsgruppe.
.PARAMETER OperationId
    Stabile ID des umzureihenden Vorgangs.
.PARAMETER Direction
    Verschieberichtung Up oder Down.
.PARAMETER Position
    Alternativ eine absolute sichtbare Position innerhalb der Prioritaetsgruppe.
.PARAMETER StateRoot
    Optionaler Root des persistenten Workflow-State.
.OUTPUTS
    PSCustomObject mit der aktualisierten Operation.
#>
function Move-SqlServerLabOperation {
    [CmdletBinding(DefaultParameterSetName = 'Direction')]
    param(
        [Parameter(Mandatory)]
        [string]$OperationId,
        [Parameter(Mandatory, ParameterSetName = 'Direction')]
        [ValidateSet('Up', 'Down')]
        [string]$Direction,
        [Parameter(Mandatory, ParameterSetName = 'Position')]
        [ValidateRange(1, 1000000)]
        [int]$Position,
        [string]$StateRoot
    )

    $operation = Get-SqlServerLabOperation -OperationId $OperationId -StateRoot $StateRoot
    if ($operation.status -eq 'Running' -or (Test-LabOperationTerminal -Status $operation.status)) {
        throw 'Nur wartende, pausierte oder eingereihte Vorgänge können umgereiht werden.'
    }
    $peers = @(Get-SqlServerLabOperation -StateRoot $StateRoot | Where-Object { $_.priority -eq $operation.priority -and $_.status -ne 'Running' -and -not (Test-LabOperationTerminal -Status $_.status) } | Sort-Object queuePosition)
    $current = [Array]::IndexOf([string[]]@($peers.operationId), $OperationId)
    $target = if ($PSCmdlet.ParameterSetName -eq 'Position') { [Math]::Min($peers.Count - 1, $Position - 1) } elseif ($Direction -eq 'Up') { [Math]::Max(0, $current - 1) } else { [Math]::Min($peers.Count - 1, $current + 1) }
    if ($target -ne $current) {
        $list = [Collections.Generic.List[object]]::new()
        foreach ($peer in $peers) { $list.Add($peer) }
        $moving = $list[$current]
        $list.RemoveAt($current)
        $list.Insert($target, $moving)
        for ($index = 0; $index -lt $list.Count; $index++) {
            $list[$index].queuePosition = $index + 1
            Write-LabOperationState -Operation $list[$index] -StateRoot $StateRoot | Out-Null
        }
        $operation = $moving
        Add-LabOperationEvent -Operation $operation -Type 'Moved' -Message "Vorgang wurde auf sichtbare Position $($target + 1) gereiht." -StateRoot $StateRoot | Out-Null
        Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
    }
    return $operation
}

<#
.SYNOPSIS
    Pausiert wartende Kindvorgaenge.
.DESCRIPTION
    Entfernt eingereihte oder abhaengigkeitswartende Vorgaenge aus der startbaren Queue.
.PARAMETER OperationId
    Eine oder mehrere stabile Vorgangs-IDs.
.PARAMETER StateRoot
    Optionaler Root des persistenten Workflow-State.
.OUTPUTS
    PSCustomObject oder Objektliste mit den pausierten Operationen.
#>
function Suspend-SqlServerLabOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$OperationId,
        [string]$StateRoot
    )

    foreach ($id in $OperationId) {
        $operation = Get-SqlServerLabOperation -OperationId $id -StateRoot $StateRoot
        if ($operation.status -eq 'Running') {
            throw "Vorgang '$id' führt gerade einen atomaren Schritt aus und kann erst danach pausiert werden."
        }
        if ($operation.status -in @('Queued', 'WaitingForDependency')) {
            $operation.status = 'Paused'
            Add-LabOperationEvent -Operation $operation -Type 'Paused' -Message 'Vorgang wurde pausiert.' -StateRoot $StateRoot | Out-Null
            Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
        }
        $operation
    }
}

<#
.SYNOPSIS
    Gibt pausierte Kindvorgaenge wieder frei.
.DESCRIPTION
    Reiht einen pausierten Vorgang ein oder setzt ihn bei offenen Voraussetzungen auf WaitingForDependency.
.PARAMETER OperationId
    Eine oder mehrere stabile Vorgangs-IDs.
.PARAMETER StateRoot
    Optionaler Root des persistenten Workflow-State.
.OUTPUTS
    PSCustomObject oder Objektliste mit den freigegebenen Operationen.
#>
function Resume-SqlServerLabOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$OperationId,
        [string]$StateRoot
    )

    foreach ($id in $OperationId) {
        $operation = Get-SqlServerLabOperation -OperationId $id -StateRoot $StateRoot
        if ($operation.status -eq 'Paused') {
            $dependencies = @(Get-LabWorkflowValue -InputObject $operation -Name 'dependencies' -Default @())
            $unresolved = @($dependencies | Where-Object { (Get-SqlServerLabOperation -OperationId $_ -StateRoot $StateRoot).status -ne 'Completed' })
            $operation.status = if ($unresolved.Count -gt 0) { 'WaitingForDependency' } else { 'Queued' }
            Add-LabOperationEvent -Operation $operation -Type 'Resumed' -Message 'Vorgang wurde wieder freigegeben.' -StateRoot $StateRoot | Out-Null
            Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
        }
        $operation
    }
}

<#
.SYNOPSIS
    Stoppt einen Kindvorgang endgueltig.
.DESCRIPTION
    Beginnt keinen neuen Mutationsschritt, wartet eine sichere Schrittgrenze ab
    und fuehrt mit Cleanup ausschliesslich den persistierten Vorgangsscope aus.
.PARAMETER OperationId
    Eine oder mehrere stabile Vorgangs-IDs.
.PARAMETER Cleanup
    Reiht den scopegebundenen Cleanup-Plan ein.
.PARAMETER StateRoot
    Optionaler Root des persistenten Workflow-State.
.OUTPUTS
    PSCustomObject oder Objektliste mit Stopp- und Cleanup-Status.
#>
function Stop-SqlServerLabOperation {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string[]]$OperationId,
        [switch]$Cleanup,
        [string]$StateRoot
    )

    foreach ($id in $OperationId) {
        if (-not $PSCmdlet.ShouldProcess($id, 'Vorgang endgültig stoppen' + $(if ($Cleanup) { ' und scopegebunden aufräumen' } else { '' }))) {
            continue
        }
        $operation = Get-SqlServerLabOperation -OperationId $id -StateRoot $StateRoot
        if (Test-LabOperationTerminal -Status $operation.status) {
            if (-not $Cleanup -or $operation.status -eq 'Cancelled') {
                $operation
                continue
            }
        }
        if ($operation.status -eq 'Running') {
            $operation.cancelRequested = $true
            $operation.cleanupRequested = [bool]$Cleanup
            Add-LabOperationEvent -Operation $operation -Type 'CancellationRequested' -Message 'Stopp wurde angefordert; der aktuelle atomare Schritt läuft bis zur sicheren Grenze.' -StateRoot $StateRoot | Out-Null
        }
        elseif ($Cleanup) {
            $operation.cancelRequested = $true
            $operation.cleanupRequested = $true
            $operation.status = 'CleanupQueued'
            Add-LabOperationEvent -Operation $operation -Type 'CleanupQueued' -Message 'Vorgang wurde gestoppt und zur scopegebundenen Bereinigung eingereiht.' -StateRoot $StateRoot | Out-Null
        }
        else {
            $operation.cancelRequested = $true
            $operation.status = 'Cancelled'
            $operation.completedAt = Get-LabWorkflowUtcNow
            Add-LabOperationEvent -Operation $operation -Type 'Cancelled' -Message 'Vorgang wurde endgültig gestoppt; Ressourcen wurden nicht automatisch entfernt.' -StateRoot $StateRoot | Out-Null
        }
        Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
        Update-LabBatchSummary -BatchId $operation.batchId -StateRoot $StateRoot | Out-Null
        $operation
    }
}

<#
.SYNOPSIS
    Stoppt einen Batch kontrolliert.
.DESCRIPTION
    Stoppt standardmaessig nur unfertige Positionen. IncludeCompleted erlaubt
    nach ausdruecklicher Review den Rueckbau auch bereits fertiger Batch-Ressourcen.
.PARAMETER BatchId
    Stabile ID des Batch.
.PARAMETER Cleanup
    Reiht scopegebundene Cleanup-Plaene ein.
.PARAMETER IncludeCompleted
    Bezieht bereits erfolgreich fertiggestellte Positionen in den Rueckbau ein.
.PARAMETER StateRoot
    Optionaler Root des persistenten Workflow-State.
.OUTPUTS
    PSCustomObject mit dem aktualisierten Batchzustand.
#>
function Stop-SqlServerLabBatch {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$BatchId,
        [switch]$Cleanup,
        [switch]$IncludeCompleted,
        [string]$StateRoot
    )

    $batch = Get-SqlServerLabBatch -BatchId $BatchId -StateRoot $StateRoot
    $action = if ($IncludeCompleted) { 'Gesamten Batch einschließlich fertiger Ressourcen zurückbauen' } else { 'Unfertige Batch-Positionen stoppen' }
    if (-not $PSCmdlet.ShouldProcess($batch.name, $action)) {
        return $batch
    }
    $operations = @(Get-SqlServerLabOperation -BatchId $BatchId -StateRoot $StateRoot)
    $targets = if ($IncludeCompleted) { $operations } else { @($operations | Where-Object status -notin @('Completed', 'Failed', 'Cancelled')) }
    if ($targets.Count -gt 0) {
        Stop-SqlServerLabOperation -OperationId @($targets.operationId) -Cleanup:$Cleanup -StateRoot $StateRoot -Confirm:$false | Out-Null
    }
    $batch = Update-LabBatchSummary -BatchId $BatchId -StateRoot $StateRoot
    return $batch
}

<#
.SYNOPSIS
    Bestaetigt und prueft persistente Benutzeraktionen.
.DESCRIPTION
    Verifiziert jede ausgewaehlte Position einzeln. Nur erfolgreich gepruefte
    Positionen werden fortgesetzt; alle anderen bleiben mit konkretem Fehler im Gate.
.PARAMETER OperationId
    Eine oder mehrere stabile IDs wartender Vorgaenge.
.PARAMETER Credential
    Optionales, nur fuer diese technische Pruefung verwendetes Gast-Credential.
.PARAMETER StateRoot
    Optionaler Root des persistenten Workflow-State.
.OUTPUTS
    PSCustomObject oder Objektliste mit dem individuellen Verifikationsergebnis.
#>
function Confirm-SqlServerLabOperationUserAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$OperationId,
        [PSCredential]$Credential,
        [string]$StateRoot
    )

    $results = @()
    foreach ($id in $OperationId) {
        $operation = Get-SqlServerLabOperation -OperationId $id -StateRoot $StateRoot
        if ($operation.status -notin @('WaitingForUser', 'CandidateSatisfied')) {
            $results += [pscustomobject]@{ operationId = $id; success = $false; status = $operation.status; message = 'Der Vorgang wartet aktuell auf keine Benutzeraktion.' }
            continue
        }
        $verification = Test-LabOperationUserGateVerification -Operation $operation -Credential $Credential -StateRoot $StateRoot
        $operation.userGate.verification.lastResult = $verification
        if (-not $verification.success) {
            $operation.status = 'WaitingForUser'
            $operation.userGate.status = 'WaitingForUser'
            $operation.nextSoundAt = $null
            Add-LabOperationEvent -Operation $operation -Type 'UserActionVerificationFailed' -Message $verification.message -Data $verification -StateRoot $StateRoot | Out-Null
            Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
            $results += [pscustomobject]@{ operationId = $id; success = $false; status = $operation.status; message = $verification.message }
            continue
        }
        $index = [int]$operation.currentStep
        $step = $operation.steps[$index]
        $step.status = 'Completed'
        $step.completedAt = Get-LabWorkflowUtcNow
        $step.receipt = [pscustomobject]@{ action = 'UserGateConfirmed'; verification = $verification.result; confirmedAt = Get-LabWorkflowUtcNow }
        $operation.receipts = @(@($operation.receipts) + $step.receipt)
        $operation.userGate.status = 'Confirmed'
        $operation.userGate.confirmedAt = Get-LabWorkflowUtcNow
        $operation.currentStep = $index + 1
        $operation.progress = [Math]::Round((100 * [int]$operation.currentStep / [Math]::Max(1, @($operation.steps).Count)), 1)
        $operation.probe.status = 'Inactive'
        $operation.probe.nextProbeAt = $null
        $operation.nextSoundAt = $null
        if ($operation.kind -eq 'Dependency' -and $null -ne $verification.result) {
            $operation.result = $verification.result
        }
        if ([int]$operation.currentStep -ge @($operation.steps).Count) {
            $operation.status = 'Completed'
            $operation.progress = 100
            $operation.completedAt = Get-LabWorkflowUtcNow
        }
        else {
            $operation.status = 'Queued'
        }
        Add-LabOperationEvent -Operation $operation -Type 'UserActionConfirmed' -Message 'Benutzeraktion wurde technisch verifiziert; der Vorgang darf fortgesetzt werden.' -Data $verification -StateRoot $StateRoot | Out-Null
        Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
        Update-LabDependencyStates -StateRoot $StateRoot
        Update-LabBatchSummary -BatchId $operation.batchId -StateRoot $StateRoot | Out-Null
        $results += [pscustomobject]@{ operationId = $id; success = $true; status = $operation.status; message = $verification.message }
    }
    return $results
}

function Invoke-SqlServerLabOperationProbe {
    [CmdletBinding()]
    param(
        [string[]]$OperationId,
        [switch]$DueOnly,
        [string]$StateRoot
    )

    if ($DueOnly -or @($OperationId).Count -eq 0) {
        return Invoke-LabDueOperationProbe -StateRoot $StateRoot
    }
    $result = @()
    foreach ($id in $OperationId) {
        $operation = Get-SqlServerLabOperation -OperationId $id -StateRoot $StateRoot
        if ($operation.status -notin @('WaitingForUser', 'CandidateSatisfied')) {
            continue
        }
        $operation.probe.nextProbeAt = [DateTime]::UtcNow.AddSeconds(-1).ToString('o')
        Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
        $result += Invoke-LabDueOperationProbe -StateRoot $StateRoot
    }
    return $result
}

function Set-SqlServerLabAttention {
    [CmdletBinding(DefaultParameterSetName = 'Global')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Operation')]
        [string]$OperationId,
        [Parameter(Mandatory, ParameterSetName = 'Operation')]
        [bool]$Muted,
        [Parameter(ParameterSetName = 'Global')]
        [ValidateSet('Off', 'OneHour', 'EightHours', 'Indefinite')]
        [string]$QuietMode = 'Off',
        [string]$StateRoot
    )

    if ($PSCmdlet.ParameterSetName -eq 'Operation') {
        $operation = Get-SqlServerLabOperation -OperationId $OperationId -StateRoot $StateRoot
        $operation.muted = $Muted
        Add-LabOperationEvent -Operation $operation -Type 'AttentionChanged' -Message $(if ($Muted) { 'Akustischer Hinweis für diesen Vorgang wurde deaktiviert.' } else { 'Akustischer Hinweis für diesen Vorgang wurde aktiviert.' }) -StateRoot $StateRoot | Out-Null
        Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
        return $operation
    }
    $settings = Get-LabSchedulerSettings -StateRoot $StateRoot
    $settings.quietIndefinitely = $QuietMode -eq 'Indefinite'
    switch ($QuietMode) {
        'OneHour' { $settings.quietUntil = [DateTime]::UtcNow.AddHours(1).ToString('o') }
        'EightHours' { $settings.quietUntil = [DateTime]::UtcNow.AddHours(8).ToString('o') }
        default { $settings.quietUntil = $null }
    }
    return Write-LabSchedulerSettings -Settings $settings -StateRoot $StateRoot
}

function Invoke-SqlServerLabScheduler {
    [CmdletBinding()]
    param(
        [switch]$UntilIdle,
        [ValidateRange(1, 16)]
        [int]$MaxWorkers = 2,
        [string]$StateRoot
    )

    $root = Initialize-LabWorkflowStore -StateRoot $StateRoot
    $settings = Get-LabSchedulerSettings -StateRoot $root
    $settings.maxWorkers = $MaxWorkers
    Write-LabSchedulerSettings -Settings $settings -StateRoot $root | Out-Null
    $allResults = @()
    do {
        $selected = @(Invoke-WithLabWorkflowLock -StateRoot $root -ScriptBlock {
            $candidates = @(Get-LabStartableOperations -MaxWorkers $MaxWorkers -StateRoot $root)
            foreach ($candidate in $candidates) {
                $candidate.status = 'Running'
                $candidate.worker = [pscustomobject]@{ host = [Environment]::MachineName; processId = $PID; claimedAt = Get-LabWorkflowUtcNow; heartbeatAt = Get-LabWorkflowUtcNow }
                Add-LabOperationEvent -Operation $candidate -Type 'Claimed' -Message 'Scheduler hat den Vorgang atomar für einen Worker reserviert.' -StateRoot $root | Out-Null
                Write-LabOperationState -Operation $candidate -StateRoot $root | Out-Null
            }
            return $candidates
        })
        if ($selected.Count -eq 0) {
            break
        }
        $jobs = @()
        foreach ($operation in $selected) {
            $modulePath = $ExecutionContext.SessionState.Module.Path
            $operationId = $operation.operationId
            if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
                $jobs += Start-ThreadJob -ArgumentList $modulePath, $root, $operationId -ScriptBlock {
                    param($ModulePath, $StateRoot, $OperationId)
                    Import-Module $ModulePath -Force
                    $module = Get-Module SqlServerLab
                    & $module { param($Id, $Root) Invoke-LabOperationExecution -OperationId $Id -StateRoot $Root } $OperationId $StateRoot
                }
            }
            else {
                $jobs += Start-Job -ArgumentList $modulePath, $root, $operationId -ScriptBlock {
                    param($ModulePath, $StateRoot, $OperationId)
                    Import-Module $ModulePath -Force
                    $module = Get-Module SqlServerLab
                    & $module { param($Id, $Root) Invoke-LabOperationExecution -OperationId $Id -StateRoot $Root } $OperationId $StateRoot
                }
            }
        }
        if ($jobs.Count -gt 0) {
            $jobs | Wait-Job | Out-Null
            foreach ($job in $jobs) {
                $allResults += @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
            foreach ($claimed in $selected) {
                $current = Read-LabWorkflowJson -Path (Get-LabOperationStatePath -OperationId $claimed.operationId -StateRoot $root)
                if ($null -ne $current -and $current.status -eq 'Running') {
                    $current.status = if ([bool]$current.cleanupRequested) { 'CleanupQueued' } elseif (@($current.dependencies).Count -gt 0) { 'WaitingForDependency' } else { 'Queued' }
                    $current.worker = $null
                    Add-LabOperationEvent -Operation $current -Type 'WorkerExitedUnexpectedly' -Message 'Der Worker endete ohne Abschlussstatus; der letzte persistente Schritt wurde wieder freigegeben.' -StateRoot $root | Out-Null
                    Write-LabOperationState -Operation $current -StateRoot $root | Out-Null
                }
            }
        }
        Invoke-LabDueOperationProbe -StateRoot $root | Out-Null
        Invoke-LabCandidateSound -StateRoot $root
    } while ($UntilIdle)
    return $allResults
}

function Start-SqlServerLabOperationHost {
    [CmdletBinding()]
    param(
        [string]$StateRoot,
        [switch]$PassThru
    )

    $root = Initialize-LabWorkflowStore -StateRoot $StateRoot
    $leasePath = Join-Path $root 'scheduler\leases\host.json'
    $existingLease = Read-LabWorkflowJson -Path $leasePath
    if ($null -ne $existingLease -and -not [string]::IsNullOrWhiteSpace([string]$existingLease.updatedAt)) {
        $fresh = (([DateTime]::UtcNow - ([DateTime]$existingLease.updatedAt).ToUniversalTime()).TotalSeconds -lt 20)
        $alive = $fresh
        if ([string]$existingLease.host -eq [Environment]::MachineName) {
            try { $null = Get-Process -Id ([int]$existingLease.processId) -ErrorAction Stop; $alive = $true } catch { $alive = $false }
        }
        if ($alive) {
            if ($PassThru) { return [pscustomobject]@{ AlreadyRunning = $true; ProcessId = [int]$existingLease.processId; StateRoot = $root } }
            return
        }
    }
    $modulePath = $ExecutionContext.SessionState.Module.Path
    $hostScript = Join-Path (Split-Path -Parent $modulePath) 'Tools\Start-SqlServerLabOperationHost.ps1'
    $arguments = @('-NoLogo', '-NoProfile', '-File', $hostScript, '-ModulePath', $modulePath, '-StateRoot', $root)
    $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if ($PassThru) {
        return $process
    }
}
