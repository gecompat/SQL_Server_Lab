# Read only fixed, size-bounded metadata beneath one registered local DataRoot.
# No compatibility adoption, runtime observation, connection data or journal scan.
function Assert-LabDiagnosticPath {
    param([string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or $Path.StartsWith('\\') -or $Path.StartsWith('//') -or
        $Path.IndexOf([char]0) -ge 0 -or
        @($Path -split '[\\/]' | Where-Object { $_ -cin @('.','..') }).Count -or
        ($IsWindows -and $Path.Substring(2).Contains(':'))) {
        throw 'DIAGNOSTIC_ROOT_INVALID'
    }
    $full=[IO.Path]::GetFullPath($Path)
    if ($full.TrimEnd('\','/') -ceq [IO.Path]::GetPathRoot($full).TrimEnd('\','/')) { throw 'DIAGNOSTIC_ROOT_INVALID' }
    $current=$full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'DIAGNOSTIC_LINK_BLOCKED' }
        }
        $parent=[IO.Path]::GetDirectoryName($current)
        if ($parent -ceq $current) { break }
        $current=$parent
    }
    return $full.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
}

function Read-LabDiagnosticJson {
    param([string]$Path,[int]$MaximumBytes=1048576,[int]$MaximumDepth=32,[switch]$Optional)
    $null=Assert-LabDiagnosticPath -Path $Path
    if (-not [IO.File]::Exists($Path)) {
        if ($Optional) { return $null }
        throw 'DIAGNOSTIC_EVIDENCE_MISSING'
    }
    $stream=$null
    try {
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if ($stream.Length -gt $MaximumBytes) { throw 'DIAGNOSTIC_SIZE_LIMIT' }
        $bytes=[byte[]]::new($MaximumBytes+1)
        $length=0
        while ($length -lt $bytes.Length) {
            $read=$stream.Read($bytes,$length,$bytes.Length-$length)
            if ($read -eq 0) { break }
            $length+=$read
        }
        if ($length -gt $MaximumBytes) { throw 'DIAGNOSTIC_SIZE_LIMIT' }
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes,0,$length).TrimStart([char]0xfeff)
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=$MaximumDepth
        $document=[Text.Json.JsonDocument]::Parse($text,$options)
        try {
            if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'DIAGNOSTIC_METADATA_INVALID' }
            # Duplicate keys (including case aliases) must never change identity interpretation.
            $pending=[Collections.Generic.Stack[Text.Json.JsonElement]]::new();$pending.Push($document.RootElement)
            $nodes=0
            while ($pending.Count) {
                if (++$nodes -gt 16384) { throw 'DIAGNOSTIC_COUNT_LIMIT' }
                $element=$pending.Pop()
                if ($element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                    $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    foreach ($property in $element.EnumerateObject()) {
                        if (-not $keys.Add($property.Name)) { throw 'DIAGNOSTIC_METADATA_INVALID' }
                        $pending.Push($property.Value)
                    }
                }
                elseif ($element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                    foreach ($child in $element.EnumerateArray()) { $pending.Push($child) }
                }
            }
        }
        finally { $document.Dispose() }
        return $text | ConvertFrom-Json -Depth $MaximumDepth -ErrorAction Stop
    }
    finally { if ($stream) { $stream.Dispose() } }
}

function Test-LabDiagnosticGuid {
    param($Value)
    $parsed=[guid]::Empty
    return $Value -is [string] -and [guid]::TryParseExact($Value,'D',[ref]$parsed) -and $Value -ceq $parsed.ToString('D') -and $parsed -ne [guid]::Empty
}

function Get-LabDiagnosticBinding {
    param([string]$RunId,[string]$InstanceId,[string]$DataRoot,[string]$Provider)
    if (-not (Test-LabDiagnosticGuid $RunId) -or $InstanceId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$') {
        throw 'DIAGNOSTIC_TARGET_INVALID'
    }
    $root=Assert-LabDiagnosticPath -Path $DataRoot
    $marker=Read-LabDiagnosticJson -Path (Join-Path $root '.sql-server-lab-root.json') -MaximumBytes 16384 -MaximumDepth 8
    $catalog=Read-LabDiagnosticJson -Path (Join-Path $root 'Catalog/storage-locations.json') -MaximumBytes 65536 -MaximumDepth 12
    if ($marker.ContractVersion -cne 'SqlServerLab.DataRoot/2.0' -or $marker.ManagedBy -cne 'SQL_Server_Lab' -or
        -not (Test-LabDiagnosticGuid $marker.ControllerId) -or $catalog.ContractVersion -cne 'SqlServerLab.Storage/2.0' -or
        $catalog.ControllerId -cne $marker.ControllerId) { throw 'DIAGNOSTIC_CONTROLLER_MISMATCH' }
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$marker.DataRoot).TrimEnd('\','/'),$root,$comparison)) {
        throw 'DIAGNOSTIC_ROOT_MISMATCH'
    }
    $locations=@($catalog.LabDataLocations)
    if ($locations.Count -gt 32) { throw 'DIAGNOSTIC_COUNT_LIMIT' }
    $registered=@($locations | Where-Object { [string]::Equals([string]$_.LabDataRoot,$root,$comparison) })
    if ($registered.Count -ne 1 -or -not (Test-LabDiagnosticGuid $registered[0].LocationId) -or
        $registered[0].ControllerId -cne $marker.ControllerId -or
        -not $marker.VolumeId -or $registered[0].VolumeId -cne $marker.VolumeId) { throw 'DIAGNOSTIC_ROOT_UNREGISTERED' }
    $stateRoot=Join-Path $root 'State'
    $directory=Join-Path (Join-Path $stateRoot 'runs') $RunId
    $run=Read-LabDiagnosticJson -Path (Join-Path $directory 'run-state.json')
    if ($run.contractVersion -cne 'SqlServerLab.RunState/1.0') { throw 'DIAGNOSTIC_RUN_CONTRACT_UNSUPPORTED' }
    if ($run.runId -cne $RunId -or -not (Test-LabDiagnosticGuid $run.scopeId)) { throw 'DIAGNOSTIC_RUN_SCOPE_MISMATCH' }
    $scope=Read-LabDiagnosticJson -Path (Join-Path (Join-Path $stateRoot 'scope-markers') ($run.scopeId+'.json')) -MaximumBytes 16384 -MaximumDepth 8
    if ($scope.runId -cne $RunId -or $scope.scopeId -cne $run.scopeId) { throw 'DIAGNOSTIC_RUN_SCOPE_MISMATCH' }
    $desired=$run.metadata.desiredState
    if ($desired.Contract.Name -cne 'SqlServerLab.RunDesiredState' -or $desired.Contract.Version -cne '1.0' -or
        $desired.PersistentData -isnot [bool] -or $run.metadata.persistentData -isnot [bool] -or
        $desired.PersistentData -ne $run.metadata.persistentData -or $desired.ProvisioningMode -isnot [string] -or
        $desired.ProvisioningMode -cnotin @('adhoc','manifest')) {
        throw 'DIAGNOSTIC_DESIRED_BINDING_INVALID'
    }
    if ($desired.PersistentData -and -not [string]::Equals([string]$run.metadata.dataRoot,$root,$comparison)) {
        throw 'DIAGNOSTIC_PERSISTENT_ROOT_MISMATCH'
    }
    foreach ($collection in @('instances','providerSubRuns','errors','stateHistory')) {
        if ($run.$collection -isnot [array]) { throw 'DIAGNOSTIC_METADATA_INVALID' }
    }
    if ($desired.Instances -isnot [array]) { throw 'DIAGNOSTIC_METADATA_INVALID' }
    $instances=@($desired.Instances);$subRuns=@($run.providerSubRuns)
    if ($instances.Count -lt 1 -or $instances.Count -gt 64 -or $subRuns.Count -lt 1 -or $subRuns.Count -gt 3 -or
        @($run.instances).Count -gt 64 -or @($run.errors).Count -gt 256 -or @($run.stateHistory).Count -gt 256) {
        throw 'DIAGNOSTIC_COUNT_LIMIT'
    }
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $providers=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($instance in $instances) {
        if ($instance.Id -isnot [string] -or $instance.Id -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$' -or
            -not $ids.Add($instance.Id) -or $instance.Provider -isnot [string] -or
            $instance.Provider -cnotin @('docker','podman','hyperv') -or $instance.Version -isnot [string] -or
            $instance.Version -cnotmatch '^[0-9]{4}(R2)?$') { throw 'DIAGNOSTIC_INSTANCE_BINDING_INVALID' }
        $null=$providers.Add($instance.Provider)
    }
    if ($subRuns.Count -ne $providers.Count) { throw 'DIAGNOSTIC_PROVIDER_BINDING_INVALID' }
    foreach ($name in $providers) {
        $sub=@($subRuns | Where-Object provider -CEQ $name)
        $expected=@($instances | Where-Object Provider -CEQ $name | ForEach-Object Id | Sort-Object)
        if ($sub.Count -ne 1 -or @($sub[0].instanceIds).Count -ne $expected.Count -or
            (@($sub[0].instanceIds | Sort-Object) -join '|') -cne ($expected -join '|')) { throw 'DIAGNOSTIC_PROVIDER_BINDING_INVALID' }
    }
    $actualIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($actual in @($run.instances)) {
        $intent=@($instances | Where-Object Id -CEQ $actual.id)
        if ($intent.Count -ne 1 -or -not $actualIds.Add([string]$actual.id) -or
            $actual.provider -cne $intent[0].Provider -or
            ($actual.version -and $actual.version -cne $intent[0].Version)) { throw 'DIAGNOSTIC_INSTANCE_BINDING_INVALID' }
    }
    $selected=@($instances | Where-Object Id -CEQ $InstanceId)
    if ($selected.Count -ne 1) { throw 'DIAGNOSTIC_INSTANCE_UNAVAILABLE' }
    $instance=$selected[0]
    if ($Provider -and $Provider -cne $instance.Provider) { throw 'DIAGNOSTIC_PROVIDER_MISMATCH' }
    $version=Get-SqlServerVersion -VersionId ([string]$instance.Version)
    if (-not $version -or [string]$version.id -cne [string]$instance.Version -or
        ($instance.Provider -cin @('docker','podman') -and -not $version.docker)) { throw 'DIAGNOSTIC_SQL_VERSION_UNSUPPORTED' }
    # REMOVED is terminal and intentionally has no outgoing transition-map entry.
    $states=@('INITIALIZING','PROVISIONING','SQL_READY','DATABASES_CREATED','POST_PROVISIONED','RUNNING',
        'STOPPED','PROVISION_FAILED','CLEANUP_PENDING','CLEANUP_RUNNING','CLEANED_UP','RECOVERY_REQUIRED','REMOVED')
    if ($run.state -isnot [string] -or $run.state -cnotin $states -or
        @($subRuns | Where-Object { $_.state -isnot [string] -or $_.state -cnotin $states }).Count) { throw 'DIAGNOSTIC_STATE_INVALID' }
    # No complete desired-state/intent object escapes this internal binding boundary.
    [pscustomobject]@{Root=$root;StateRoot=$stateRoot;Directory=$directory;Run=$run;Instance=$instance;Provider=$instance.Provider}
}

function Get-LabDiagnosticCleanup {
    param($Binding)
    $result=[pscustomobject]@{EvidenceStatus='UNAVAILABLE';Reason='DIAGNOSTIC_CLEANUP_NOT_RECORDED';Status='UNKNOWN';PendingSteps=0;CompletedSteps=0;FailedSteps=0;LiveResidueStatus='NOT_EXECUTED'}
    try {
        $plan=Read-LabDiagnosticJson -Path (Join-Path $Binding.Directory 'cleanup-plan.json') -Optional
        if (-not $plan) { return $result }
        if ($plan.runId -cne $Binding.Run.runId -or $plan.scopeId -cne $Binding.Run.scopeId) { throw 'DIAGNOSTIC_CLEANUP_BINDING_INVALID' }
        if ($plan.steps -isnot [array]) { throw 'DIAGNOSTIC_CLEANUP_STATE_INVALID' }
        $steps=@($plan.steps)
        if ($steps.Count -gt 256) { throw 'DIAGNOSTIC_COUNT_LIMIT' }
        if ($plan.status -isnot [string] -or $plan.status -cnotin @('PENDING','EXECUTING','COMPLETED','PARTIAL') -or
            @($steps | Where-Object { $_.state -isnot [string] -or $_.state -cnotin @('PENDING','COMPLETED','FAILED') }).Count) { throw 'DIAGNOSTIC_CLEANUP_STATE_INVALID' }
        $result.EvidenceStatus='OBSERVED';$result.Reason='NONE';$result.Status=$plan.status
        $result.PendingSteps=@($steps | Where-Object state -CEQ 'PENDING').Count
        $result.CompletedSteps=@($steps | Where-Object state -CEQ 'COMPLETED').Count
        $result.FailedSteps=@($steps | Where-Object state -CEQ 'FAILED').Count
    }
    catch { $result.EvidenceStatus='BLOCKED';$result.Reason='DIAGNOSTIC_CLEANUP_UNVERIFIABLE' }
    return $result
}

function Get-LabDiagnosticOperation {
    param($Binding)
    $result=[pscustomobject]@{EvidenceStatus='UNAVAILABLE';Reason='DIAGNOSTIC_OPERATION_NOT_RECORDED';Status='UNKNOWN';StepCount=0;CleanupRequested=$false}
    $id=$Binding.Run.metadata.workflowOperationId
    if (-not $id) { return $result }
    try {
        if ($id -isnot [string] -or $id -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,191}$') { throw 'DIAGNOSTIC_OPERATION_INVALID' }
        $operation=Read-LabDiagnosticJson -Path (Join-Path (Join-Path $Binding.StateRoot 'operations') ($id+'.json')) -Optional
        if (-not $operation) { return $result }
        if ($operation.contract -cne 'SqlServerLab.Operation/1.0' -or $operation.operationId -cne $id -or
            $operation.runId -cne $Binding.Run.runId -or $operation.provider -cne $Binding.Provider -or
            $operation.status -isnot [string] -or $operation.status -cnotin @('Draft','Queued','Running','WaitingForDependency','WaitingForUser','CandidateSatisfied','Paused','CleanupQueued','Completed','Failed','Cancelled') -or
            $operation.cleanupRequested -isnot [bool] -or $operation.steps -isnot [array] -or
            @($operation.steps).Count -gt 64) { throw 'DIAGNOSTIC_OPERATION_INVALID' }
        $result.EvidenceStatus='OBSERVED';$result.Reason='NONE';$result.Status=$operation.status
        $result.StepCount=@($operation.steps).Count;$result.CleanupRequested=$operation.cleanupRequested
    }
    catch { $result.EvidenceStatus='BLOCKED';$result.Reason='DIAGNOSTIC_OPERATION_UNVERIFIABLE' }
    return $result
}

function Get-LabDiagnosticTargetEvidence {
    param([string]$RunId,[string]$InstanceId,[string]$DataRoot,[string]$Provider)
    $binding=Get-LabDiagnosticBinding -RunId $RunId -InstanceId $InstanceId -DataRoot $DataRoot -Provider $Provider
    [pscustomobject]@{
        Binding=[pscustomobject]@{
            EvidenceStatus='OBSERVED';Reason='NONE';Provider=$binding.Provider;SqlVersion=[string]$binding.Instance.Version
            OperatingSystem=if($binding.Provider -ceq 'hyperv'){'windows'}else{'linux'}
            Persistence=if($binding.Run.metadata.persistentData){'PERSISTENT'}else{'RUN_SCOPED'}
            ProvisioningMode=$binding.Run.metadata.desiredState.ProvisioningMode
        }
        History=[pscustomobject]@{
            EvidenceStatus='OBSERVED';RunState=$binding.Run.state
            RecoveryStatus=if($binding.Run.state -ceq 'RECOVERY_REQUIRED'){'REQUIRED'}else{'NOT_RECORDED'}
            ErrorCount=@($binding.Run.errors).Count;RuntimeStatus='NOT_EXECUTED'
        }
        Cleanup=Get-LabDiagnosticCleanup -Binding $binding
        Operation=Get-LabDiagnosticOperation -Binding $binding
    }
}
