function Get-LabWorkflowUtcNow {
    [CmdletBinding()]
    param()

    return [DateTime]::UtcNow.ToString('o')
}

function Get-LabWorkflowValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]::Equals([string]$key, $Name, [StringComparison]::OrdinalIgnoreCase)) {
                return $InputObject[$key]
            }
        }
        return $Default
    }

    $property = $InputObject.PSObject.Properties | Where-Object {
        [string]::Equals($_.Name, $Name, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
    if ($null -ne $property) {
        return $property.Value
    }

    return $Default
}

function ConvertTo-LabWorkflowHashtable {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [string] -or $InputObject -is [ValueType] -or $InputObject -is [SecureString]) {
        return $InputObject
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $result[[string]$key] = ConvertTo-LabWorkflowHashtable -InputObject $InputObject[$key]
        }
        return $result
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        return @($InputObject | ForEach-Object { ConvertTo-LabWorkflowHashtable -InputObject $_ })
    }

    $result = [ordered]@{}
    foreach ($property in $InputObject.PSObject.Properties) {
        $result[$property.Name] = ConvertTo-LabWorkflowHashtable -InputObject $property.Value
    }
    return $result
}

function Merge-LabWorkflowConfiguration {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$InputObject
    )

    $merged = [ordered]@{}
    foreach ($source in @($InputObject)) {
        if ($null -eq $source) {
            continue
        }
        $table = ConvertTo-LabWorkflowHashtable -InputObject $source
        if ($table -isnot [System.Collections.IDictionary]) {
            continue
        }
        foreach ($key in $table.Keys) {
            $merged[[string]$key] = $table[$key]
        }
    }
    return $merged
}

function Get-LabWorkflowHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [ValidateRange(8, 64)]
        [int]$Length = 16
    )

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $hash = [BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        return $hash.Substring(0, [Math]::Min($Length, $hash.Length))
    }
    finally {
        $algorithm.Dispose()
    }
}

function ConvertTo-LabWorkflowSlug {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Text,

        [string]$Fallback = 'item'
    )

    $slug = ([string]$Text).Trim().ToLowerInvariant() -replace '[^a-z0-9_-]+', '-'
    $slug = $slug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return $Fallback
    }
    return $slug
}

function Initialize-LabWorkflowStore {
    [CmdletBinding()]
    param(
        [string]$StateRoot
    )

    $root = Initialize-LabStateRoot -StateRoot $StateRoot
    foreach ($directory in @('batches', 'operations', 'scheduler', 'scheduler\leases', 'scheduler\logs')) {
        $path = Join-Path $root $directory
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
    return $root
}

function Get-LabBatchStatePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BatchId,

        [string]$StateRoot
    )

    $root = Initialize-LabWorkflowStore -StateRoot $StateRoot
    return Join-Path (Join-Path $root 'batches') ((ConvertTo-LabWorkflowSlug -Text $BatchId -Fallback 'batch') + '.json')
}

function Get-LabOperationStatePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OperationId,

        [string]$StateRoot
    )

    $root = Initialize-LabWorkflowStore -StateRoot $StateRoot
    return Join-Path (Join-Path $root 'operations') ((ConvertTo-LabWorkflowSlug -Text $OperationId -Fallback 'operation') + '.json')
}

function Read-LabWorkflowJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
}

function Write-LabBatchState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Batch,

        [string]$StateRoot
    )

    $Batch.updatedAt = Get-LabWorkflowUtcNow
    Write-LabArtifactJsonAtomic -Path (Get-LabBatchStatePath -BatchId $Batch.batchId -StateRoot $StateRoot) -InputObject $Batch
    return $Batch
}

function Write-LabOperationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Operation,

        [string]$StateRoot
    )

    $Operation.updatedAt = Get-LabWorkflowUtcNow
    Write-LabArtifactJsonAtomic -Path (Get-LabOperationStatePath -OperationId $Operation.operationId -StateRoot $StateRoot) -InputObject $Operation
    return $Operation
}

function Add-LabOperationEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Operation,

        [Parameter(Mandatory)]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Message,

        [AllowNull()]
        [object]$Data,

        [string]$StateRoot
    )

    $sequence = [int](Get-LabWorkflowValue -InputObject $Operation -Name 'eventSequence' -Default 0) + 1
    $event = [pscustomobject][ordered]@{
        sequence = $sequence
        timestamp = Get-LabWorkflowUtcNow
        type = $Type
        message = $Message
        data = $Data
    }
    $Operation.eventSequence = $sequence
    $Operation.events = @(@(Get-LabWorkflowValue -InputObject $Operation -Name 'events' -Default @()) + $event)
    if ($Operation.events.Count -gt 200) {
        $Operation.events = @($Operation.events | Select-Object -Last 200)
    }

    $root = Initialize-LabWorkflowStore -StateRoot $StateRoot
    $eventPath = Join-Path (Join-Path $root 'scheduler\logs') 'events.jsonl'
    $line = ([pscustomobject][ordered]@{
        contract = 'SqlServerLab.Event/1.0'
        batchId = $Operation.batchId
        operationId = $Operation.operationId
        sequence = $sequence
        timestamp = $event.timestamp
        type = $Type
        message = $Message
        data = $Data
    } | ConvertTo-Json -Depth 30 -Compress)
    Add-Content -LiteralPath $eventPath -Value $line -Encoding utf8
    return $event
}

function Invoke-WithLabWorkflowLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [string]$StateRoot,

        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 30
    )

    $root = Initialize-LabWorkflowStore -StateRoot $StateRoot
    $name = 'SqlServerLab.Workflow.' + (Get-LabWorkflowHash -Text ([IO.Path]::GetFullPath($root).ToLowerInvariant()) -Length 24)
    $created = $false
    $mutex = [Threading.Mutex]::new($false, $name, [ref]$created)
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        if (-not $acquired) {
            throw "Workflow-Sperre '$name' konnte nicht innerhalb von $TimeoutSeconds Sekunden erworben werden."
        }
        return & $ScriptBlock
    }
    finally {
        if ($acquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Get-LabProviderAvailabilityMap {
    [CmdletBinding()]
    param()

    $result = [ordered]@{}
    foreach ($provider in @('docker', 'podman', 'hyperv')) {
        try {
            $probe = Test-ProviderAvailability -Provider $provider
            if ($probe -is [bool]) {
                $result[$provider] = [bool]$probe
            }
            else {
                $available = Get-LabWorkflowValue -InputObject $probe -Name 'Available' -Default $null
                if ($null -eq $available) {
                    $available = Get-LabWorkflowValue -InputObject $probe -Name 'IsAvailable' -Default $null
                }
                if ($null -eq $available) {
                    $status = [string](Get-LabWorkflowValue -InputObject $probe -Name 'Status' -Default '')
                    $available = $status -eq 'RESOURCE_OK'
                }
                $result[$provider] = [bool]$available
            }
        }
        catch {
            $result[$provider] = $false
        }
        if ($provider -eq 'hyperv' -and -not [bool]$result[$provider] -and $IsWindows) {
            try { $result[$provider] = [bool](Test-HyperVAvailable).Available } catch { }
        }
    }
    return $result
}

function Resolve-LabBatchProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Kind,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Effective,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Availability
    )

    if ($Kind -match '^(Test|NoOp|Action|Dependency)$') {
        return [pscustomobject]@{ provider = 'Internal'; reason = 'Interner Workflow-Vorgang.'; blockingError = $null }
    }

    $preference = [string](Get-LabWorkflowValue -InputObject $Effective -Name 'ProviderPreference' -Default 'Auto')
    if ([string]::IsNullOrWhiteSpace($preference)) {
        $preference = 'Auto'
    }
    $os = [string](Get-LabWorkflowValue -InputObject $Effective -Name 'OperatingSystem' -Default (Get-LabWorkflowValue -InputObject $Effective -Name 'TargetOperatingSystem' -Default (Get-LabWorkflowValue -InputObject $Effective -Name 'OsFamily' -Default (Get-LabWorkflowValue -InputObject $Effective -Name 'Platform' -Default ''))))
    $needsWindows = $Kind -match '(Windows|Slot)' -or $os -match 'Windows'
    $needsHyperV = $needsWindows -or [bool](Get-LabWorkflowValue -InputObject $Effective -Name 'RequiresVhdx' -Default $false) -or -not [string]::IsNullOrWhiteSpace([string](Get-LabWorkflowValue -InputObject $Effective -Name 'PhysicalStoragePath' -Default ''))

    if (-not [string]::Equals($preference, 'Auto', [StringComparison]::OrdinalIgnoreCase)) {
        $selected = $preference.ToLowerInvariant()
        if ($selected -notin @('docker', 'podman', 'hyperv')) {
            return [pscustomobject]@{ provider = $selected; reason = 'Explizite Providerwahl.'; blockingError = "Unbekannter Provider '$preference'." }
        }
        if ($needsHyperV -and $selected -ne 'hyperv') {
            return [pscustomobject]@{ provider = $selected; reason = 'Explizite Providerwahl.'; blockingError = "Die Anforderungen erzwingen Hyper-V; '$preference' ist unvereinbar." }
        }
        if (-not [bool]$Availability[$selected]) {
            return [pscustomobject]@{ provider = $selected; reason = 'Explizite Providerwahl.'; blockingError = "Der explizit gewählte Provider '$preference' ist nicht verfügbar." }
        }
        return [pscustomobject]@{ provider = $selected; reason = "Explizit unter Erweitert gewählt: $preference."; blockingError = $null }
    }

    if ($needsHyperV) {
        if (-not [bool]$Availability['hyperv']) {
            return [pscustomobject]@{ provider = 'hyperv'; reason = 'Windows-, VHDX- oder Storage-Anforderung erzwingt Hyper-V.'; blockingError = 'Hyper-V wird benötigt, ist auf diesem Host aber nicht verfügbar.' }
        }
        return [pscustomobject]@{ provider = 'hyperv'; reason = 'Windows-, VHDX- oder Storage-Anforderung erzwingt Hyper-V.'; blockingError = $null }
    }

    if ([bool]$Availability['docker']) {
        return [pscustomobject]@{ provider = 'docker'; reason = 'Auto: SQL unter Linux wird bevorzugt mit Docker bereitgestellt.'; blockingError = $null }
    }
    if ([bool]$Availability['podman']) {
        return [pscustomobject]@{ provider = 'podman'; reason = 'Auto: Docker ist nicht verfügbar; Podman erfüllt die Linux-Anforderung.'; blockingError = $null }
    }
    return [pscustomobject]@{ provider = 'docker'; reason = 'Auto: Container-Runtime erforderlich.'; blockingError = 'Weder Docker noch Podman ist für diese Linux-Anforderung verfügbar.' }
}

function Get-LabArtifactRequirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Effective
    )

    $requirement = [ordered]@{
        operatingSystem = [string](Get-LabWorkflowValue -InputObject $Effective -Name 'OperatingSystem' -Default (Get-LabWorkflowValue -InputObject $Effective -Name 'OsFamily' -Default 'Windows'))
        variant = [string](Get-LabWorkflowValue -InputObject $Effective -Name 'Variant' -Default (Get-LabWorkflowValue -InputObject $Effective -Name 'InstallationType' -Default ''))
        sqlVersion = [string](Get-LabWorkflowValue -InputObject $Effective -Name 'SqlVersion' -Default (Get-LabWorkflowValue -InputObject $Effective -Name 'Version' -Default ''))
        edition = [string](Get-LabWorkflowValue -InputObject $Effective -Name 'Edition' -Default '')
        language = [string](Get-LabWorkflowValue -InputObject $Effective -Name 'Language' -Default '')
    }
    return $requirement
}

function Find-LabMatchingHyperVArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Requirement,

        [string]$StateRoot
    )

    try {
        $artifacts = @(Get-HyperVImageArtifact -StateRoot $StateRoot -SkipIntegrityCheck -ErrorAction Stop)
    }
    catch {
        return $null
    }

    $normalize = {
        param([string]$Value)
        $normalized = $Value.ToLowerInvariant() -replace '[^a-z0-9]+', ''
        $normalized = $normalized -replace 'desktopexperience', 'desktop'
        return $normalized
    }
    foreach ($artifact in $artifacts) {
        $metadata = Get-LabWorkflowValue -InputObject $artifact -Name 'metadata' -Default $artifact
        $matches = $true
        $compared = 0
        foreach ($field in @('operatingSystem', 'variant', 'sqlVersion', 'edition', 'language')) {
            $expected = [string](Get-LabWorkflowValue -InputObject $Requirement -Name $field -Default '')
            if ([string]::IsNullOrWhiteSpace($expected)) {
                continue
            }
            $actual = [string](Get-LabWorkflowValue -InputObject $metadata -Name $field -Default (Get-LabWorkflowValue -InputObject $artifact -Name $field -Default ''))
            if ($field -eq 'operatingSystem') {
                $osObject = Get-LabWorkflowValue -InputObject $artifact -Name 'operatingSystem' -Default $null
                $actual = [string](Get-LabWorkflowValue -InputObject $osObject -Name 'id' -Default (Get-LabWorkflowValue -InputObject $osObject -Name 'version' -Default $actual))
            }
            elseif ($field -eq 'variant') {
                $osObject = Get-LabWorkflowValue -InputObject $artifact -Name 'operatingSystem' -Default $null
                $actual = [string](Get-LabWorkflowValue -InputObject $osObject -Name 'installationType' -Default $actual)
            }
            elseif ($field -eq 'edition') {
                $sqlObject = Get-LabWorkflowValue -InputObject $artifact -Name 'sql' -Default $null
                $osObject = Get-LabWorkflowValue -InputObject $artifact -Name 'operatingSystem' -Default $null
                $actual = [string](Get-LabWorkflowValue -InputObject $sqlObject -Name 'edition' -Default (Get-LabWorkflowValue -InputObject $osObject -Name 'edition' -Default $actual))
            }
            elseif ($field -eq 'sqlVersion') {
                $sqlObject = Get-LabWorkflowValue -InputObject $artifact -Name 'sql' -Default $null
                $actual = [string](Get-LabWorkflowValue -InputObject $sqlObject -Name 'version' -Default $actual)
            }
            if ([string]::IsNullOrWhiteSpace($actual)) {
                $matches = $false
                break
            }
            $compared++
            if (-not [string]::Equals((& $normalize $actual), (& $normalize $expected), [StringComparison]::OrdinalIgnoreCase)) {
                $matches = $false
                break
            }
        }
        if ($matches -and $compared -gt 0) {
            return $artifact
        }
    }
    return $null
}

function New-LabWorkflowStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$Title
    )

    return [pscustomobject][ordered]@{
        id = $Id
        action = $Action
        title = $Title
        status = 'Pending'
        startedAt = $null
        completedAt = $null
        receipt = $null
        error = $null
    }
}

function New-LabOperationStateObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OperationId,

        [Parameter(Mandatory)]
        [string]$BatchId,

        [Parameter(Mandatory)]
        [string]$ItemId,

        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Kind,

        [Parameter(Mandatory)]
        [ValidateSet('High', 'Normal', 'Low')]
        [string]$Priority,

        [Parameter(Mandatory)]
        [int]$QueuePosition,

        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$ProviderReason,

        [Parameter(Mandatory)]
        [string]$ResourceClass,

        [string[]]$Locks = @(),

        [string[]]$Dependencies = @(),

        [Parameter(Mandatory)]
        [object]$Executor,

        [Parameter(Mandatory)]
        [object[]]$Steps,

        [object]$CleanupPlan
    )

    $now = Get-LabWorkflowUtcNow
    $initialStatus = if (@($Dependencies).Count -gt 0) { 'WaitingForDependency' } else { 'Queued' }
    return [pscustomobject][ordered]@{
        contract = 'SqlServerLab.Operation/1.0'
        operationId = $OperationId
        batchId = $BatchId
        itemId = $ItemId
        title = $Title
        kind = $Kind
        status = $initialStatus
        progress = 0
        priority = $Priority
        priorityOverridden = $false
        queuePosition = $QueuePosition
        provider = $Provider
        providerReason = $ProviderReason
        resourceClass = $ResourceClass
        locks = @($Locks)
        dependencies = @($Dependencies)
        dependents = @()
        executor = $Executor
        steps = @($Steps)
        currentStep = 0
        receipts = @()
        runId = $null
        userGate = $null
        probe = [pscustomobject][ordered]@{
            status = 'Inactive'
            nextProbeAt = $null
            intervalSeconds = 30
            failures = 0
            lastSignature = $null
            lastCheckedAt = $null
        }
        muted = $false
        nextSoundAt = $null
        soundIndex = 0
        worker = $null
        cancelRequested = $false
        cleanupRequested = $false
        cleanupPlan = $CleanupPlan
        cleanupResult = $null
        result = $null
        error = $null
        createdAt = $now
        updatedAt = $now
        startedAt = $null
        completedAt = $null
        eventSequence = 0
        events = @()
    }
}

function Get-LabOperationStepsForPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Kind,

        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Effective
    )

    if ($Kind -eq 'Dependency') {
        return @(New-LabWorkflowStep -Id 'resolve-artifact' -Action 'ResolveHyperVArtifact' -Title 'Passende Hyper-V-Vorlage auflösen')
    }
    if ($Kind -match '^(Test|NoOp|Action)$') {
        $gate = [bool](Get-LabWorkflowValue -InputObject $Effective -Name 'RequireUserAction' -Default $false)
        $steps = @(New-LabWorkflowStep -Id 'execute' -Action 'InvokeInternalAction' -Title 'Interne Aktion ausführen')
        if ($gate) {
            $steps += New-LabWorkflowStep -Id 'user-action' -Action 'WaitForGenericUserAction' -Title 'Benutzeraktion bestätigen'
        }
        return $steps
    }
    if ($Provider -eq 'hyperv') {
        $steps = @(
            New-LabWorkflowStep -Id 'create-hyperv' -Action 'CreateHyperVEnvironment' -Title 'Hyper-V-Umgebung erzeugen'
            New-LabWorkflowStep -Id 'start-hyperv' -Action 'StartHyperVEnvironment' -Title 'Hyper-V-Umgebung starten'
        )
        $requiresUserSetup = [bool](Get-LabWorkflowValue -InputObject $Effective -Name 'RequiresUserSetup' -Default ($Kind -match '(Windows|Slot)'))
        if ($requiresUserSetup) {
            $steps += New-LabWorkflowStep -Id 'windows-user-action' -Action 'WaitForWindowsUserAction' -Title 'Windows-Anmeldung und Einrichtung abschließen'
        }
        $steps += New-LabWorkflowStep -Id 'complete' -Action 'CompleteEnvironment' -Title 'Umgebung abschließen'
        return $steps
    }
    return @(
        New-LabWorkflowStep -Id 'create-runtime' -Action 'CreateContainerEnvironment' -Title 'Container-Umgebung erzeugen'
        New-LabWorkflowStep -Id 'complete' -Action 'CompleteEnvironment' -Title 'Umgebung abschließen'
    )
}

function Get-LabWorkflowResourceEstimate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Effective
    )

    return [pscustomobject][ordered]@{
        cpu = [int](Get-LabWorkflowValue -InputObject $Effective -Name 'Cpu' -Default (Get-LabWorkflowValue -InputObject $Effective -Name 'ProcessorCount' -Default 2))
        memoryMB = [int](Get-LabWorkflowValue -InputObject $Effective -Name 'MemoryMB' -Default (Get-LabWorkflowValue -InputObject $Effective -Name 'MemoryStartupMB' -Default 4096))
        storageGB = [int](Get-LabWorkflowValue -InputObject $Effective -Name 'StorageGB' -Default 0)
    }
}

function Update-LabBatchSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BatchId,

        [string]$StateRoot
    )

    $batchPath = Get-LabBatchStatePath -BatchId $BatchId -StateRoot $StateRoot
    $batch = Read-LabWorkflowJson -Path $batchPath
    if ($null -eq $batch) {
        return $null
    }
    $operations = @()
    foreach ($operationId in @($batch.operationIds)) {
        $operation = Read-LabWorkflowJson -Path (Get-LabOperationStatePath -OperationId $operationId -StateRoot $StateRoot)
        if ($null -ne $operation) {
            $operations += $operation
        }
    }
    $counts = [ordered]@{}
    foreach ($status in @('Draft', 'Queued', 'Running', 'WaitingForDependency', 'WaitingForUser', 'CandidateSatisfied', 'Paused', 'CleanupQueued', 'Completed', 'Failed', 'Cancelled')) {
        $counts[$status] = @($operations | Where-Object status -eq $status).Count
    }
    $total = $operations.Count
    $terminal = $counts.Completed + $counts.Failed + $counts.Cancelled
    $progress = if ($total -eq 0) { 0 } else { [Math]::Round(((@($operations | Measure-Object -Property progress -Average).Average)), 1) }

    if ($batch.status -eq 'Draft' -or $batch.status -eq 'Validated') {
        $status = $batch.status
    }
    elseif ($counts.CleanupQueued -gt 0) {
        $status = 'CleanupQueued'
    }
    elseif ($terminal -eq $total -and $total -gt 0) {
        $status = if (($counts.Failed + $counts.Cancelled) -gt 0) { 'CompletedWithErrors' } else { 'Completed' }
    }
    elseif (($counts.WaitingForUser + $counts.CandidateSatisfied) -gt 0 -and $counts.Running -eq 0) {
        $status = 'Waiting'
    }
    elseif ($counts.Running -gt 0 -or $terminal -gt 0) {
        $status = 'Running'
    }
    else {
        $status = 'Queued'
    }
    $batch.status = $status
    $batch.progress = [pscustomobject][ordered]@{
        percent = $progress
        total = $total
        counts = [pscustomobject]$counts
    }
    $batch.errorStatus = [pscustomobject][ordered]@{
        failed = $counts.Failed
        cancelled = $counts.Cancelled
        hasErrors = ($counts.Failed + $counts.Cancelled) -gt 0
    }
    Write-LabBatchState -Batch $batch -StateRoot $StateRoot | Out-Null
    return $batch
}

function Get-LabPriorityRank {
    [CmdletBinding()]
    param([string]$Priority)

    switch ($Priority) {
        'High' { return 0 }
        'Low' { return 2 }
        default { return 1 }
    }
}

function Test-LabOperationTerminal {
    [CmdletBinding()]
    param([string]$Status)

    return $Status -in @('Completed', 'Failed', 'Cancelled')
}

function Repair-LabAbandonedOperations {
    [CmdletBinding()]
    param([string]$StateRoot)

    $root = Initialize-LabWorkflowStore -StateRoot $StateRoot
    $operations = @(Get-ChildItem -LiteralPath (Join-Path $root 'operations') -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { Read-LabWorkflowJson -Path $_.FullName } | Where-Object status -eq 'Running')
    foreach ($operation in $operations) {
        $worker = $operation.worker
        $abandoned = $false
        if ($null -eq $worker) {
            $abandoned = $true
        }
        elseif ([string]$worker.host -eq [Environment]::MachineName) {
            try { $null = Get-Process -Id ([int]$worker.processId) -ErrorAction Stop } catch { $abandoned = $true }
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$worker.heartbeatAt)) {
            $abandoned = (([DateTime]::UtcNow - ([DateTime]$worker.heartbeatAt).ToUniversalTime()).TotalMinutes -gt 15)
        }
        if (-not $abandoned) { continue }
        $operation.status = if ([bool]$operation.cleanupRequested) { 'CleanupQueued' } elseif (@($operation.dependencies).Count -gt 0) { 'WaitingForDependency' } else { 'Queued' }
        $operation.worker = $null
        Add-LabOperationEvent -Operation $operation -Type 'WorkerRecovered' -Message 'Ein verlassener Worker wurde erkannt; der Vorgang wird am letzten persistenten Schritt fortgesetzt.' -StateRoot $StateRoot | Out-Null
        Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
    }
}

function Update-LabDependencyStates {
    [CmdletBinding()]
    param([string]$StateRoot)

    $root = Initialize-LabWorkflowStore -StateRoot $StateRoot
    $operations = @(Get-ChildItem -LiteralPath (Join-Path $root 'operations') -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { Read-LabWorkflowJson -Path $_.FullName })
    $byId = @{}
    foreach ($operation in $operations) {
        $byId[$operation.operationId] = $operation
    }
    foreach ($operation in $operations | Where-Object status -eq 'WaitingForDependency') {
        $dependencies = @($operation.dependencies | ForEach-Object { $byId[[string]$_] } | Where-Object { $null -ne $_ })
        $failed = @($dependencies | Where-Object status -in @('Failed', 'Cancelled'))
        if ($failed.Count -gt 0) {
            $operation.status = 'Failed'
            $operation.error = [pscustomobject]@{
                code = 'DEPENDENCY_FAILED'
                message = 'Eine gemeinsame Abhängigkeit ist fehlgeschlagen oder wurde abgebrochen.'
                dependencyIds = @($failed.operationId)
            }
            $operation.completedAt = Get-LabWorkflowUtcNow
            Add-LabOperationEvent -Operation $operation -Type 'DependencyFailed' -Message $operation.error.message -Data $operation.error -StateRoot $StateRoot | Out-Null
            Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
            continue
        }
        if ($dependencies.Count -eq @($operation.dependencies).Count -and @($dependencies | Where-Object status -ne 'Completed').Count -eq 0) {
            $operation.status = 'Queued'
            Add-LabOperationEvent -Operation $operation -Type 'DependenciesSatisfied' -Message 'Alle Abhängigkeiten sind erfüllt; der Vorgang wurde wieder eingereiht.' -StateRoot $StateRoot | Out-Null
            Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
        }
    }
}

function Get-LabStartableOperations {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 16)]
        [int]$MaxWorkers = 2,

        [string]$StateRoot
    )

    Repair-LabAbandonedOperations -StateRoot $StateRoot
    Update-LabDependencyStates -StateRoot $StateRoot
    $root = Initialize-LabWorkflowStore -StateRoot $StateRoot
    $all = @(Get-ChildItem -LiteralPath (Join-Path $root 'operations') -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { Read-LabWorkflowJson -Path $_.FullName })
    $running = @($all | Where-Object status -eq 'Running')
    $availableSlots = [Math]::Max(0, $MaxWorkers - $running.Count)
    if ($availableSlots -eq 0) {
        return @()
    }

    $activeLocks = @($running | ForEach-Object { @($_.locks) })
    $heavyActive = @($running | Where-Object resourceClass -eq 'HyperVHeavy').Count -gt 0
    $exclusiveActive = @($running | Where-Object resourceClass -eq 'ExclusiveStorage').Count -gt 0
    $selected = @()
    $candidates = @($all | Where-Object status -in @('Queued', 'CleanupQueued') | Sort-Object @{ Expression = { Get-LabPriorityRank -Priority $_.priority } }, @{ Expression = { [int]$_.queuePosition } }, createdAt)
    foreach ($candidate in $candidates) {
        if ($selected.Count -ge $availableSlots) {
            break
        }
        $batch = Read-LabWorkflowJson -Path (Get-LabBatchStatePath -BatchId $candidate.batchId -StateRoot $StateRoot)
        if ($null -eq $batch -or $batch.status -in @('Draft', 'Validated', 'Cancelled')) {
            continue
        }
        if ($exclusiveActive -or (@($selected | Where-Object resourceClass -eq 'ExclusiveStorage').Count -gt 0)) {
            continue
        }
        if ($candidate.resourceClass -eq 'ExclusiveStorage' -and ($running.Count + $selected.Count) -gt 0) {
            continue
        }
        if ($candidate.resourceClass -eq 'HyperVHeavy' -and ($heavyActive -or @($selected | Where-Object resourceClass -eq 'HyperVHeavy').Count -gt 0)) {
            continue
        }
        $candidateLocks = @($candidate.locks)
        $selectedLocks = @($selected | ForEach-Object { @($_.locks) })
        if (@($candidateLocks | Where-Object { $_ -in $activeLocks -or $_ -in $selectedLocks }).Count -gt 0) {
            continue
        }
        $selected += $candidate
    }
    return @($selected)
}

function Get-LabRunVmName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Run
    )

    foreach ($candidate in @(
        (Get-LabWorkflowValue -InputObject $Run -Name 'VMName' -Default $null),
        (Get-LabWorkflowValue -InputObject (Get-LabWorkflowValue -InputObject $Run -Name 'runtime' -Default $null) -Name 'VMName' -Default $null),
        (Get-LabWorkflowValue -InputObject (Get-LabWorkflowValue -InputObject $Run -Name 'hyperv' -Default $null) -Name 'VMName' -Default $null)
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            return [string]$candidate
        }
    }
    foreach ($resource in @(Get-LabWorkflowValue -InputObject $Run -Name 'resources' -Default @())) {
        $type = [string](Get-LabWorkflowValue -InputObject $resource -Name 'type' -Default '')
        if ($type -match 'VM') {
            $name = [string](Get-LabWorkflowValue -InputObject $resource -Name 'name' -Default (Get-LabWorkflowValue -InputObject $resource -Name 'id' -Default ''))
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                return $name
            }
        }
    }
    return $null
}

function Resolve-LabOperationArtifactId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Operation,

        [string]$StateRoot
    )

    $effective = Get-LabWorkflowValue -InputObject $Operation.executor -Name 'effective' -Default @{}
    $artifactId = [string](Get-LabWorkflowValue -InputObject $effective -Name 'ArtifactId' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($artifactId)) {
        return $artifactId
    }
    foreach ($dependencyId in @($Operation.dependencies)) {
        $dependency = Read-LabWorkflowJson -Path (Get-LabOperationStatePath -OperationId $dependencyId -StateRoot $StateRoot)
        $candidate = [string](Get-LabWorkflowValue -InputObject (Get-LabWorkflowValue -InputObject $dependency -Name 'result' -Default $null) -Name 'artifactId' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }
    return $null
}

function New-LabUserGateObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$GateId,

        [Parameter(Mandatory)]
        [string]$Resource,

        [Parameter(Mandatory)]
        [string]$Reason,

        [Parameter(Mandatory)]
        [string[]]$Instructions,

        [Parameter(Mandatory)]
        [string]$ExpectedResult,

        [Parameter(Mandatory)]
        [string]$VerificationType,

        [AllowNull()]
        [object]$VerificationData
    )

    $now = Get-LabWorkflowUtcNow
    return [pscustomobject][ordered]@{
        contract = 'SqlServerLab.UserGate/1.0'
        gateId = $GateId
        status = 'WaitingForUser'
        resource = $Resource
        reason = $Reason
        instructions = @($Instructions)
        expectedResult = $ExpectedResult
        verification = [pscustomobject][ordered]@{
            type = $VerificationType
            data = $VerificationData
            lastResult = $null
        }
        createdAt = $now
        lastShownAt = $null
        candidateSatisfiedAt = $null
        confirmedAt = $null
    }
}

function Invoke-LabOperationStepAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Operation,

        [Parameter(Mandatory)]
        [object]$Step,

        [string]$StateRoot
    )

    $effective = ConvertTo-LabWorkflowHashtable -InputObject (Get-LabWorkflowValue -InputObject $Operation.executor -Name 'effective' -Default @{})
    switch ($Step.action) {
        'InvokeInternalAction' {
            $workflowAction = [string](Get-LabWorkflowValue -InputObject $effective -Name 'WorkflowAction' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($workflowAction)) {
                $workflowParameters = ConvertTo-LabWorkflowHashtable -InputObject (Get-LabWorkflowValue -InputObject $effective -Name 'WorkflowParameters' -Default @{})
                $workflowResult = Invoke-SqlServerLabWorkflowAction -Action $workflowAction @workflowParameters
                return [pscustomobject]@{ state = 'Completed'; result = $workflowResult; receipt = [pscustomobject]@{ action = $workflowAction; changed = $true; at = Get-LabWorkflowUtcNow } }
            }
            $delay = [int](Get-LabWorkflowValue -InputObject $effective -Name 'DelayMilliseconds' -Default 0)
            if ($delay -gt 0) {
                Start-Sleep -Milliseconds $delay
            }
            if ([bool](Get-LabWorkflowValue -InputObject $effective -Name 'Fail' -Default $false)) {
                throw [string](Get-LabWorkflowValue -InputObject $effective -Name 'FailureMessage' -Default 'Die angeforderte Testaktion ist fehlgeschlagen.')
            }
            return [pscustomobject]@{ state = 'Completed'; receipt = [pscustomobject]@{ action = 'Internal'; changed = $true; at = Get-LabWorkflowUtcNow } }
        }
        'CreateContainerEnvironment' {
            if (-not [string]::IsNullOrWhiteSpace([string]$Operation.runId)) {
                try {
                    $existing = Get-LabRunState -RunId $Operation.runId -StateRoot $StateRoot
                    if ($null -ne $existing) {
                        return [pscustomobject]@{ state = 'Completed'; receipt = [pscustomobject]@{ action = 'ReuseRun'; runId = $Operation.runId; changed = $false } }
                    }
                }
                catch {
                }
            }
            $parameters = @{
                Provider = [string]$Operation.provider
                Version = [string](Get-LabWorkflowValue -InputObject $effective -Name 'Version' -Default (Get-LabWorkflowValue -InputObject $effective -Name 'SqlVersion' -Default '2022'))
                Profile = [string](Get-LabWorkflowValue -InputObject $effective -Name 'Profile' -Default 'compact')
                StateRoot = $StateRoot
                NonInteractive = $true
            }
            $saPasswordEnvironmentVariable = [string](Get-LabWorkflowValue -InputObject $effective -Name 'SaPasswordEnvironmentVariable' -Default '')
            if ([string]::IsNullOrWhiteSpace($saPasswordEnvironmentVariable)) {
                throw 'BATCH_SA_PASSWORD_ENVIRONMENT_VARIABLE_REQUIRED: Container-Batchpositionen benötigen eine Referenz auf eine SQL_SERVER_LAB_SECRET_*-Prozessvariable.'
            }
            $parameters['SaPassword'] = Get-LabManifestEnvironmentSecret -Name $saPasswordEnvironmentVariable
            foreach ($mapping in @(
                @('LabName', 'LabName'), @('InstanceId', 'InstanceId'), @('Port', 'Port'), @('Cpu', 'Cpu'),
                @('MemoryMB', 'MemoryMB'), @('Collation', 'Collation'),
                @('DataRoot', 'DataRoot'), @('PersistentData', 'PersistentData'), @('NetworkName', 'NetworkName')
            )) {
                $value = Get-LabWorkflowValue -InputObject $effective -Name $mapping[0] -Default $null
                if ($null -ne $value -and -not ([string]::IsNullOrWhiteSpace([string]$value))) {
                    $parameters[$mapping[1]] = $value
                }
            }
            $autoStartValue = Get-LabWorkflowValue -InputObject $effective -Name 'AutoStart' -Default $null
            if ($autoStartValue -is [bool]) {
                $autoStartValue = if ($autoStartValue) { 'on' } else { 'off' }
            }
            if ($null -ne $autoStartValue -and -not [string]::IsNullOrWhiteSpace([string]$autoStartValue)) {
                $parameters['AutoStart'] = [string]$autoStartValue
            }
            $created = New-SqlServerLab @parameters
            $result = @($created) | Select-Object -Last 1
            $runId = [string](Get-LabWorkflowValue -InputObject $result -Name 'RunId' -Default (Get-LabWorkflowValue -InputObject $result -Name 'runId' -Default ''))
            if ([string]::IsNullOrWhiteSpace($runId)) {
                throw 'Die Container-Erstellung lieferte keine RunId.'
            }
            return [pscustomobject]@{ state = 'Completed'; runId = $runId; receipt = [pscustomobject]@{ action = 'CreateContainer'; runId = $runId; changed = $true } }
        }
        'CreateHyperVEnvironment' {
            if (-not [string]::IsNullOrWhiteSpace([string]$Operation.runId)) {
                try {
                    $existing = Get-LabRunState -RunId $Operation.runId -StateRoot $StateRoot
                    if ($null -ne $existing) {
                        return [pscustomobject]@{ state = 'Completed'; receipt = [pscustomobject]@{ action = 'ReuseRun'; runId = $Operation.runId; changed = $false } }
                    }
                }
                catch {
                }
            }
            $artifactId = Resolve-LabOperationArtifactId -Operation $Operation -StateRoot $StateRoot
            if ([string]::IsNullOrWhiteSpace($artifactId)) {
                throw 'Für die Hyper-V-Erstellung wurde keine passende ArtifactId aufgelöst.'
            }
            $autoStartValue = Get-LabWorkflowValue -InputObject $effective -Name 'AutoStart' -Default 'off'
            if ($autoStartValue -is [bool]) { $autoStartValue = if ($autoStartValue) { 'on' } else { 'off' } }
            if ([string]$autoStartValue -notin @('on', 'off')) { $autoStartValue = 'off' }
            $parameters = @{
                ArtifactId = $artifactId
                LabName = [string](Get-LabWorkflowValue -InputObject $effective -Name 'LabName' -Default $Operation.itemId)
                InstanceId = [string](Get-LabWorkflowValue -InputObject $effective -Name 'InstanceId' -Default 'default')
                MemoryStartupMB = [int](Get-LabWorkflowValue -InputObject $effective -Name 'MemoryStartupMB' -Default (Get-LabWorkflowValue -InputObject $effective -Name 'MemoryMB' -Default 4096))
                ProcessorCount = [int](Get-LabWorkflowValue -InputObject $effective -Name 'ProcessorCount' -Default (Get-LabWorkflowValue -InputObject $effective -Name 'Cpu' -Default 2))
                AutoStart = [string]$autoStartValue
                StateRoot = $StateRoot
            }
            foreach ($name in @('SwitchName', 'Isolated', 'AdditionalDrives', 'DesiredState')) {
                $value = Get-LabWorkflowValue -InputObject $effective -Name $name -Default $null
                if ($null -ne $value) {
                    $parameters[$name] = $value
                }
            }
            $created = New-HyperVLabEnvironment @parameters
            $runId = [string](Get-LabWorkflowValue -InputObject $created -Name 'RunId' -Default (Get-LabWorkflowValue -InputObject $created -Name 'runId' -Default ''))
            if ([string]::IsNullOrWhiteSpace($runId)) {
                throw 'Die Hyper-V-Erstellung lieferte keine RunId.'
            }
            return [pscustomobject]@{ state = 'Completed'; runId = $runId; receipt = [pscustomobject]@{ action = 'CreateHyperV'; runId = $runId; artifactId = $artifactId; changed = $true } }
        }
        'StartHyperVEnvironment' {
            if ([string]::IsNullOrWhiteSpace([string]$Operation.runId)) {
                throw 'Die Hyper-V-Umgebung kann ohne RunId nicht gestartet werden.'
            }
            $result = Start-HyperVLabEnvironment -RunId $Operation.runId -StateRoot $StateRoot
            return [pscustomobject]@{ state = 'Completed'; receipt = [pscustomobject]@{ action = 'StartHyperV'; runId = $Operation.runId; result = $result } }
        }
        'WaitForWindowsUserAction' {
            $run = Get-LabRunState -RunId $Operation.runId -StateRoot $StateRoot
            $vmName = Get-LabRunVmName -Run $run
            if ([string]::IsNullOrWhiteSpace($vmName)) {
                $vmName = [string]$Operation.runId
            }
            $gate = New-LabUserGateObject -GateId ('gate-' + $Operation.operationId + '-windows') -Resource $vmName -Reason 'Windows benötigt eine interaktive Anmeldung beziehungsweise OOBE-Konfiguration.' -Instructions @(
                "VM '$vmName' in der Konsole öffnen.",
                'Windows-OOBE und die lokale Anmeldung vollständig abschließen.',
                'Warten, bis der Desktop beziehungsweise die erwartete Eingabeaufforderung stabil verfügbar ist.',
                'Hier Erledigt - prüfen und fortsetzen wählen; Zugangsdaten werden erst bei der Prüfung abgefragt.'
            ) -ExpectedResult 'Windows ist eingerichtet, die VM läuft und PowerShell Direct ist mit dem bestätigten Konto erreichbar.' -VerificationType 'HyperVWindowsSetup' -VerificationData ([pscustomobject]@{ runId = $Operation.runId; vmName = $vmName })
            return [pscustomobject]@{ state = 'WaitingForUser'; gate = $gate }
        }
        'WaitForGenericUserAction' {
            $instructions = @(Get-LabWorkflowValue -InputObject $effective -Name 'UserInstructions' -Default @('Die beschriebene externe Tätigkeit vollständig ausführen.'))
            $receiptPath = [string](Get-LabWorkflowValue -InputObject $effective -Name 'ReceiptPath' -Default '')
            $verificationType = if ([string]::IsNullOrWhiteSpace($receiptPath)) { 'Always' } else { 'ReceiptFile' }
            $gate = New-LabUserGateObject -GateId ('gate-' + $Operation.operationId + '-generic') -Resource ([string](Get-LabWorkflowValue -InputObject $effective -Name 'Resource' -Default $Operation.title)) -Reason ([string](Get-LabWorkflowValue -InputObject $effective -Name 'UserReason' -Default 'Eine Benutzeraktion ist erforderlich.')) -Instructions $instructions -ExpectedResult ([string](Get-LabWorkflowValue -InputObject $effective -Name 'ExpectedResult' -Default 'Die angeforderten Schritte sind abgeschlossen.')) -VerificationType $verificationType -VerificationData ([pscustomobject]@{ receiptPath = $receiptPath })
            return [pscustomobject]@{ state = 'WaitingForUser'; gate = $gate }
        }
        'ResolveHyperVArtifact' {
            $requirement = Get-LabWorkflowValue -InputObject $Operation.executor -Name 'requirement' -Default @{}
            $artifact = Find-LabMatchingHyperVArtifact -Requirement $requirement -StateRoot $StateRoot
            if ($null -ne $artifact) {
                $artifactId = [string](Get-LabWorkflowValue -InputObject $artifact -Name 'ArtifactId' -Default (Get-LabWorkflowValue -InputObject $artifact -Name 'artifactId' -Default ''))
                return [pscustomobject]@{ state = 'Completed'; result = [pscustomobject]@{ artifactId = $artifactId; reused = $true }; receipt = [pscustomobject]@{ action = 'ResolveArtifact'; artifactId = $artifactId; reused = $true } }
            }
            $description = ($requirement | ConvertTo-Json -Depth 10 -Compress)
            $gate = New-LabUserGateObject -GateId ('gate-' + $Operation.operationId + '-artifact') -Resource 'Hyper-V-Vorlagenbibliothek' -Reason 'Eine gemeinsam benötigte, vollständig passende Vorlage fehlt.' -Instructions @(
                'Im Menü Hyper-V-Infrastruktur die benötigte OS- oder SQL-Prepared-Vorlage planen.',
                "Anforderung der abhängigen Positionen: $description",
                'ISO gegebenenfalls erkennen oder herunterladen und den Build vollständig veröffentlichen.',
                'Danach hier Erledigt - prüfen und fortsetzen wählen.'
            ) -ExpectedResult 'Eine veröffentlichte Hyper-V-Vorlage erfüllt alle aufgelisteten Eigenschaften.' -VerificationType 'HyperVArtifactAvailable' -VerificationData ([pscustomobject]@{ requirement = $requirement })
            return [pscustomobject]@{ state = 'WaitingForUser'; gate = $gate }
        }
        'CompleteEnvironment' {
            return [pscustomobject]@{ state = 'Completed'; receipt = [pscustomobject]@{ action = 'Complete'; runId = $Operation.runId; changed = $false } }
        }
        default {
            throw "Unbekannte Operation-Step-Aktion '$($Step.action)'."
        }
    }
}

function Invoke-LabOperationCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Operation,

        [string]$StateRoot
    )

    $remaining = @()
    $removed = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$Operation.runId)) {
        try {
            Remove-SqlServerLab -RunId $Operation.runId -StateRoot $StateRoot -Force -Confirm:$false | Out-Null
            $removed += [pscustomobject]@{ type = 'Run'; id = $Operation.runId }
        }
        catch {
            $remaining += [pscustomobject]@{ type = 'Run'; id = $Operation.runId; error = $_.Exception.Message }
        }
    }
    $success = $remaining.Count -eq 0
    return [pscustomobject][ordered]@{
        success = $success
        completedAt = Get-LabWorkflowUtcNow
        removed = $removed
        remaining = $remaining
        protectedResourcesPreserved = @('PublishedArtifacts', 'MediaLibrary', 'ProtectedPersistentData')
    }
}

function Invoke-LabOperationExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OperationId,

        [string]$StateRoot
    )

    $operation = Read-LabWorkflowJson -Path (Get-LabOperationStatePath -OperationId $OperationId -StateRoot $StateRoot)
    if ($null -eq $operation) {
        throw "Vorgang '$OperationId' wurde nicht gefunden."
    }
    try {
        if ($operation.cleanupRequested -or $operation.status -eq 'CleanupQueued') {
            $operation.status = 'Running'
            Add-LabOperationEvent -Operation $operation -Type 'CleanupStarted' -Message 'Scopegebundene Bereinigung wurde gestartet.' -StateRoot $StateRoot | Out-Null
            Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
            $operation.cleanupResult = Invoke-LabOperationCleanup -Operation $operation -StateRoot $StateRoot
            $operation.status = 'Cancelled'
            $operation.progress = 100
            $operation.completedAt = Get-LabWorkflowUtcNow
            Add-LabOperationEvent -Operation $operation -Type 'CleanupCompleted' -Message 'Scopegebundene Bereinigung wurde beendet.' -Data $operation.cleanupResult -StateRoot $StateRoot | Out-Null
            Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
            Update-LabBatchSummary -BatchId $operation.batchId -StateRoot $StateRoot | Out-Null
            return $operation
        }

        $operation.status = 'Running'
        if ($null -eq $operation.startedAt) {
            $operation.startedAt = Get-LabWorkflowUtcNow
        }
        $operation.worker = [pscustomobject]@{ host = [Environment]::MachineName; processId = $PID; startedAt = Get-LabWorkflowUtcNow; heartbeatAt = Get-LabWorkflowUtcNow }
        Add-LabOperationEvent -Operation $operation -Type 'Started' -Message 'Vorgang wurde von einem Scheduler-Worker übernommen.' -StateRoot $StateRoot | Out-Null
        Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null

        while ([int]$operation.currentStep -lt @($operation.steps).Count) {
            if ([bool]$operation.cancelRequested) {
                $operation.cleanupRequested = $true
                $operation.status = 'CleanupQueued'
                Add-LabOperationEvent -Operation $operation -Type 'CancellationBoundaryReached' -Message 'Der laufende atomare Schritt ist beendet; Cleanup wurde eingereiht.' -StateRoot $StateRoot | Out-Null
                Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
                Update-LabBatchSummary -BatchId $operation.batchId -StateRoot $StateRoot | Out-Null
                return $operation
            }
            $index = [int]$operation.currentStep
            $step = $operation.steps[$index]
            if ($step.status -eq 'Completed') {
                $operation.currentStep = $index + 1
                continue
            }
            $step.status = 'Running'
            $step.startedAt = Get-LabWorkflowUtcNow
            $operation.worker.heartbeatAt = Get-LabWorkflowUtcNow
            Add-LabOperationEvent -Operation $operation -Type 'StepStarted' -Message $step.title -Data ([pscustomobject]@{ stepId = $step.id; action = $step.action }) -StateRoot $StateRoot | Out-Null
            Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
            $outcome = Invoke-LabOperationStepAction -Operation $operation -Step $step -StateRoot $StateRoot
            if (-not [string]::IsNullOrWhiteSpace([string](Get-LabWorkflowValue -InputObject $outcome -Name 'runId' -Default ''))) {
                $operation.runId = [string]$outcome.runId
            }
            $outcomeResult = Get-LabWorkflowValue -InputObject $outcome -Name 'result' -Default $null
            if ($null -ne $outcomeResult) {
                $operation.result = $outcomeResult
            }
            if ($outcome.state -eq 'WaitingForUser') {
                $step.status = 'WaitingForUser'
                $operation.status = 'WaitingForUser'
                $operation.userGate = $outcome.gate
                $operation.probe.status = 'Scheduled'
                $operation.probe.intervalSeconds = 30
                $operation.probe.nextProbeAt = [DateTime]::UtcNow.AddSeconds(30).ToString('o')
                $operation.worker = $null
                Add-LabOperationEvent -Operation $operation -Type 'UserActionRequired' -Message $outcome.gate.reason -Data $outcome.gate -StateRoot $StateRoot | Out-Null
                Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
                Update-LabBatchSummary -BatchId $operation.batchId -StateRoot $StateRoot | Out-Null
                return $operation
            }
            $step.status = 'Completed'
            $step.completedAt = Get-LabWorkflowUtcNow
            $step.receipt = Get-LabWorkflowValue -InputObject $outcome -Name 'receipt' -Default $null
            if ($null -ne $step.receipt) {
                $operation.receipts = @(@($operation.receipts) + $step.receipt)
            }
            $operation.currentStep = $index + 1
            $operation.progress = [Math]::Round((100 * [int]$operation.currentStep / [Math]::Max(1, @($operation.steps).Count)), 1)
            Add-LabOperationEvent -Operation $operation -Type 'StepCompleted' -Message $step.title -Data $step.receipt -StateRoot $StateRoot | Out-Null
            Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
        }
        $operation.status = 'Completed'
        $operation.progress = 100
        $operation.completedAt = Get-LabWorkflowUtcNow
        $operation.worker = $null
        if ($null -eq $operation.result) {
            $operation.result = [pscustomobject]@{ runId = $operation.runId; changed = $true }
        }
        Add-LabOperationEvent -Operation $operation -Type 'Completed' -Message 'Vorgang wurde erfolgreich abgeschlossen.' -Data $operation.result -StateRoot $StateRoot | Out-Null
        Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
        Update-LabBatchSummary -BatchId $operation.batchId -StateRoot $StateRoot | Out-Null
        return $operation
    }
    catch {
        $operation.status = 'Failed'
        $operation.completedAt = Get-LabWorkflowUtcNow
        $operation.worker = $null
        $operation.error = [pscustomobject][ordered]@{
            code = 'OPERATION_FAILED'
            message = $_.Exception.Message
            type = $_.Exception.GetType().FullName
            stepId = if ([int]$operation.currentStep -lt @($operation.steps).Count) { $operation.steps[[int]$operation.currentStep].id } else { $null }
        }
        if ([int]$operation.currentStep -lt @($operation.steps).Count) {
            $operation.steps[[int]$operation.currentStep].status = 'Failed'
            $operation.steps[[int]$operation.currentStep].error = $operation.error
        }
        Add-LabOperationEvent -Operation $operation -Type 'Failed' -Message $operation.error.message -Data $operation.error -StateRoot $StateRoot | Out-Null
        Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
        Update-LabBatchSummary -BatchId $operation.batchId -StateRoot $StateRoot | Out-Null
        return $operation
    }
}

function Test-LabOperationUserGateVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Operation,

        [PSCredential]$Credential,

        [string]$StateRoot,

        [switch]$ProbeOnly
    )

    $gate = $Operation.userGate
    $verification = $gate.verification
    switch ([string]$verification.type) {
        'Always' {
            return [pscustomobject]@{ success = $true; candidate = $true; message = 'Die Benutzerbestätigung ist die technische Verifikation.'; result = $null }
        }
        'ReceiptFile' {
            $path = [string](Get-LabWorkflowValue -InputObject $verification.data -Name 'receiptPath' -Default '')
            $exists = -not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)
            return [pscustomobject]@{ success = $exists; candidate = $exists; message = if ($exists) { 'Das erwartete Receipt ist vorhanden.' } else { "Das erwartete Receipt '$path' fehlt." }; result = [pscustomobject]@{ path = $path } }
        }
        'HyperVArtifactAvailable' {
            $requirement = Get-LabWorkflowValue -InputObject $verification.data -Name 'requirement' -Default @{}
            $artifact = Find-LabMatchingHyperVArtifact -Requirement $requirement -StateRoot $StateRoot
            $artifactId = if ($null -eq $artifact) { $null } else { [string](Get-LabWorkflowValue -InputObject $artifact -Name 'ArtifactId' -Default (Get-LabWorkflowValue -InputObject $artifact -Name 'artifactId' -Default '')) }
            return [pscustomobject]@{ success = $null -ne $artifact; candidate = $null -ne $artifact; message = if ($null -ne $artifact) { "Passende Vorlage '$artifactId' gefunden." } else { 'Noch keine vollständig passende veröffentlichte Vorlage gefunden.' }; result = [pscustomobject]@{ artifactId = $artifactId; reused = $false } }
        }
        'HyperVWindowsSetup' {
            $runId = [string](Get-LabWorkflowValue -InputObject $verification.data -Name 'runId' -Default $Operation.runId)
            if ($ProbeOnly) {
                try {
                    $run = Get-LabRunState -RunId $runId -StateRoot $StateRoot
                    $vmName = Get-LabRunVmName -Run $run
                    $status = Get-HyperVInstanceStatus -VMName $vmName -ExpectedRunId $runId
                    $state = [string](Get-LabWorkflowValue -InputObject $status -Name 'State' -Default (Get-LabWorkflowValue -InputObject $status -Name 'VMState' -Default ''))
                    $candidate = $state -match 'Running|Off|Stopped'
                    return [pscustomobject]@{ success = $false; candidate = $candidate; message = if ($candidate) { 'Die VM reagiert in einem plausiblen Zustand; Benutzerbestätigung und Credential-Prüfung bleiben erforderlich.' } else { 'Die VM ist noch nicht in einem plausiblen Zustand.' }; result = $status }
                }
                catch {
                    return [pscustomobject]@{ success = $false; candidate = $false; message = $_.Exception.Message; result = $null }
                }
            }
            if ($null -eq $Credential) {
                return [pscustomobject]@{ success = $false; candidate = $false; message = 'Für die PowerShell-Direct-Prüfung ist das eingerichtete Windows-Credential erforderlich.'; result = $null }
            }
            try {
                $result = Complete-HyperVLabManualWindowsSlot -RunId $runId -Credential $Credential -StateRoot $StateRoot
                return [pscustomobject]@{ success = $true; candidate = $true; message = 'Windows-Einrichtung und PowerShell Direct wurden bestätigt.'; result = $result }
            }
            catch {
                return [pscustomobject]@{ success = $false; candidate = $false; message = $_.Exception.Message; result = $null }
            }
        }
        default {
            return [pscustomobject]@{ success = $false; candidate = $false; message = "Unbekannte Verifikation '$($verification.type)'."; result = $null }
        }
    }
}

function Get-LabSchedulerSettings {
    [CmdletBinding()]
    param([string]$StateRoot)

    $root = Initialize-LabWorkflowStore -StateRoot $StateRoot
    $path = Join-Path $root 'scheduler\settings.json'
    $settings = Read-LabWorkflowJson -Path $path
    if ($null -eq $settings) {
        $settings = [pscustomobject][ordered]@{
            contract = 'SqlServerLab.SchedulerSettings/1.0'
            maxWorkers = 2
            maxHyperVHeavy = 1
            quietUntil = $null
            quietIndefinitely = $false
            soundEnabled = $true
            probeEnabled = $true
        }
        Write-LabArtifactJsonAtomic -Path $path -InputObject $settings
    }
    return $settings
}

function Write-LabSchedulerSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Settings,

        [string]$StateRoot
    )

    $root = Initialize-LabWorkflowStore -StateRoot $StateRoot
    Write-LabArtifactJsonAtomic -Path (Join-Path $root 'scheduler\settings.json') -InputObject $Settings
    return $Settings
}

function Test-LabQuietModeActive {
    [CmdletBinding()]
    param([object]$Settings)

    if ([bool]$Settings.quietIndefinitely) {
        return $true
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Settings.quietUntil)) {
        return ([DateTime]$Settings.quietUntil).ToUniversalTime() -gt [DateTime]::UtcNow
    }
    return $false
}

function Invoke-LabCandidateSound {
    [CmdletBinding()]
    param(
        [string]$StateRoot
    )

    $settings = Get-LabSchedulerSettings -StateRoot $StateRoot
    if (-not [bool]$settings.soundEnabled -or (Test-LabQuietModeActive -Settings $settings)) {
        return
    }
    $root = Initialize-LabWorkflowStore -StateRoot $StateRoot
    $operations = @(Get-ChildItem -LiteralPath (Join-Path $root 'operations') -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { Read-LabWorkflowJson -Path $_.FullName })
    $due = $operations | Where-Object {
        $_.status -eq 'CandidateSatisfied' -and -not [bool]$_.muted -and -not [string]::IsNullOrWhiteSpace([string]$_.nextSoundAt) -and ([DateTime]$_.nextSoundAt).ToUniversalTime() -le [DateTime]::UtcNow
    } | Sort-Object nextSoundAt | Select-Object -First 1
    if ($null -eq $due) {
        return
    }
    try {
        [Console]::Beep(880, 180)
    }
    catch {
        try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    }
    $intervals = @(5, 15, 30, 60, 120, 300, 600)
    $index = [Math]::Min([int]$due.soundIndex + 1, $intervals.Count - 1)
    $due.soundIndex = $index
    $due.nextSoundAt = [DateTime]::UtcNow.AddSeconds($intervals[$index]).ToString('o')
    Write-LabOperationState -Operation $due -StateRoot $StateRoot | Out-Null
}

function Invoke-LabDueOperationProbe {
    [CmdletBinding()]
    param([string]$StateRoot)

    $settings = Get-LabSchedulerSettings -StateRoot $StateRoot
    if (-not [bool]$settings.probeEnabled) {
        return $null
    }
    $root = Initialize-LabWorkflowStore -StateRoot $StateRoot
    $operation = @(Get-ChildItem -LiteralPath (Join-Path $root 'operations') -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { Read-LabWorkflowJson -Path $_.FullName } | Where-Object {
        $_.status -in @('WaitingForUser', 'CandidateSatisfied') -and -not [string]::IsNullOrWhiteSpace([string]$_.probe.nextProbeAt) -and ([DateTime]$_.probe.nextProbeAt).ToUniversalTime() -le [DateTime]::UtcNow
    } | Sort-Object { [DateTime]$_.probe.nextProbeAt } | Select-Object -First 1)
    if ($operation.Count -eq 0) {
        return $null
    }
    $operation = $operation[0]
    $verification = Test-LabOperationUserGateVerification -Operation $operation -StateRoot $StateRoot -ProbeOnly
    $signature = Get-LabWorkflowHash -Text (($verification.result | ConvertTo-Json -Depth 20 -Compress) + '|' + $verification.message) -Length 16
    $changed = -not [string]::Equals([string]$operation.probe.lastSignature, $signature, [StringComparison]::Ordinal)
    $operation.probe.lastCheckedAt = Get-LabWorkflowUtcNow
    $operation.probe.lastSignature = $signature
    if ($verification.candidate) {
        if ($operation.status -ne 'CandidateSatisfied') {
            $operation.status = 'CandidateSatisfied'
            $operation.userGate.status = 'CandidateSatisfied'
            $operation.userGate.candidateSatisfiedAt = Get-LabWorkflowUtcNow
            $operation.soundIndex = 0
            $operation.nextSoundAt = [DateTime]::UtcNow.AddSeconds(5).ToString('o')
            Add-LabOperationEvent -Operation $operation -Type 'CandidateSatisfied' -Message 'Die Read-only-Prüfung hält das Ziel vermutlich für erreicht; ausdrückliche Bestätigung bleibt erforderlich.' -Data $verification -StateRoot $StateRoot | Out-Null
        }
        $operation.probe.intervalSeconds = if ($changed) { 30 } else { [Math]::Min(300, [Math]::Max(120, [int]$operation.probe.intervalSeconds * 2)) }
    }
    else {
        if ($operation.status -eq 'CandidateSatisfied') {
            $operation.status = 'WaitingForUser'
            $operation.userGate.status = 'WaitingForUser'
            $operation.nextSoundAt = $null
        }
        $operation.probe.intervalSeconds = if ($changed) { 30 } else { [Math]::Min(300, [Math]::Max(30, [int]$operation.probe.intervalSeconds * 2)) }
    }
    $operation.probe.nextProbeAt = [DateTime]::UtcNow.AddSeconds([int]$operation.probe.intervalSeconds).ToString('o')
    $operation.userGate.verification.lastResult = $verification
    Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
    Update-LabBatchSummary -BatchId $operation.batchId -StateRoot $StateRoot | Out-Null
    return $operation
}
