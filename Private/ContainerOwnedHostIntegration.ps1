<#
.SYNOPSIS Geschlossener lokaler StateRoot-Vertrag fuer CI auf gemeinsamem Windows-Host.
.DESCRIPTION Die Policy begrenzt Effekte. Identitaeten erteilen keine Ressourcenrechte.
#>

function Assert-LabOwnedHostPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'OWNED_HOST_PATH_INVALID' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Length -gt [IO.Path]::GetPathRoot($full).Length) { $full = $full.TrimEnd([IO.Path]::DirectorySeparatorChar) }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'OWNED_HOST_REPARSE_PATH' }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $full
}

function Assert-LabOwnedHostRootCustody {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][string]$OwnerSid)
    if (-not $IsWindows) { throw 'OWNED_HOST_PLATFORM_UNSUPPORTED' }
    $root = Assert-LabOwnedHostPath -Path $StateRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'OWNED_HOST_ROOT_MISSING' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $acl = Get-Acl -LiteralPath $root -ErrorAction Stop
    $rules = @($acl.Access)
    if ($OwnerSid -cne $sid -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid -or
        -not $acl.AreAccessRulesProtected -or $rules.Count -ne 1 -or
        $rules[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -cne $sid -or
        $rules[0].AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        (($rules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl)) {
        throw 'OWNED_HOST_ROOT_CUSTODY_INVALID'
    }
    return $root
}

function Assert-LabOwnedHostProperties {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string[]]$Names)
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count -or @($actual | Where-Object { $_ -cnotin $Names }).Count) {
        throw 'OWNED_HOST_RECORD_SHAPE_INVALID'
    }
}

function Initialize-LabOwnedHostPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][object[]]$RuntimePins, [AllowEmptyString()][string]$ParentOperationId = '')
    if (-not $IsWindows) { throw 'OWNED_HOST_PLATFORM_UNSUPPORTED' }
    $root = Assert-LabOwnedHostPath -Path $StateRoot
    if (Test-Path -LiteralPath $root) { throw 'OWNED_HOST_ROOT_ALREADY_EXISTS' }
    if ($ParentOperationId.Length -gt 128 -or ($ParentOperationId -and $ParentOperationId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$')) {
        throw 'OWNED_HOST_OPERATION_INVALID'
    }
    if (@($RuntimePins).Count -notin @(1,2)) { throw 'OWNED_HOST_PROVIDER_INVALID' }
    # Keine frei injizierbaren Commands, Prefixe oder Child-Environment-Einstellungen.
    $pins = @($RuntimePins | ForEach-Object {
        Assert-LabOwnedHostProperties -Value $_ -Names @('Provider','Invocation','Endpoint','IdentityPath','IdentitySha256')
        [pscustomobject][ordered]@{
            Provider = [string]$_.Provider; Invocation = [string]$_.Invocation; Endpoint = [string]$_.Endpoint
            IdentityPath = [string]$_.IdentityPath; IdentitySha256 = [string]$_.IdentitySha256
        }
    })
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $policy = [pscustomobject][ordered]@{
        ContractVersion = 'SqlServerLab.OwnedHostPolicy/1.0'; Mode = 'OwnedRunWindows'
        PolicyId = New-LabGuid; RootScopeId = New-LabGuid; StateRoot = $root
        OwnerSid = $sid.Value; ParentOperationId = $ParentOperationId; RuntimePins = $pins
    }
    $null = New-Item -Path $root -ItemType Directory -ErrorAction Stop
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($sid); $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    Set-Acl -LiteralPath $root -AclObject $acl -ErrorAction Stop
    [IO.File]::WriteAllText((Join-Path $root 'owned-host-required'), 'OwnedRunWindows/1.0', [Text.UTF8Encoding]::new($false))
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($policy | ConvertTo-Json -Depth 10))
    $stream = [IO.File]::Open((Join-Path $root 'owned-host-policy.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    # Elevated Windows creation can otherwise choose Administrators as owner.
    $fileAcl=[Security.AccessControl.FileSecurity]::new()
    $fileAcl.SetOwner($sid);$fileAcl.SetAccessRuleProtection($true,$false)
    $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','Allow'))
    Set-Acl -LiteralPath (Join-Path $root 'owned-host-policy.json') -AclObject $fileAcl -ErrorAction Stop
    # Bei Teilfehler bleibt der eigene Root zur Recovery erhalten, kein Standardfallback.
    return Get-LabOwnedHostPolicy -StateRoot $root -Required
}

function Assert-LabOwnedHostGuid {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
        $Value -ceq '00000000-0000-0000-0000-000000000000') { throw 'OWNED_HOST_ID_INVALID' }
}

function Read-LabOwnedHostRecord {
    param([Parameter(Mandatory)][string]$Path)
    $safe = Assert-LabOwnedHostPath -Path $Path
    $file = Get-Item -LiteralPath $safe -Force -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -gt 65536 -or $file.Length -eq 0) { throw 'OWNED_HOST_RECORD_SIZE_INVALID' }
    $text = [IO.File]::ReadAllText($safe, [Text.UTF8Encoding]::new($false, $true))
    $document = [Text.Json.JsonDocument]::Parse($text)
    try {
        # ConvertFrom-Json allein wuerde doppelte Properties still uebernehmen.
        $pending = [Collections.Generic.Stack[Text.Json.JsonElement]]::new()
        $pending.Push($document.RootElement)
        while ($pending.Count) {
            $element = $pending.Pop()
            if ($element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($property in $element.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) { throw 'OWNED_HOST_RECORD_DUPLICATE_PROPERTY' }
                    $pending.Push($property.Value)
                }
            }
            elseif ($element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                foreach ($child in $element.EnumerateArray()) { $pending.Push($child) }
            }
        }
    }
    finally { $document.Dispose() }
    return ($text | ConvertFrom-Json -Depth 16 -ErrorAction Stop)
}

function Get-LabOwnedHostPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [switch]$Required)
    $root = Assert-LabOwnedHostPath -Path $StateRoot
    $path = Join-Path $root 'owned-host-policy.json'
    if (-not (Test-Path -LiteralPath $path)) {
        if ($Required -or (((Test-Path -LiteralPath (Join-Path $root 'owned-host-required')) -or (Test-Path -LiteralPath (Join-Path $root 'owned-host-policy.json'))))) { throw 'OWNED_HOST_POLICY_MISSING' }
        return $null
    }
    $policy = Read-LabOwnedHostRecord -Path $path
    Assert-LabOwnedHostProperties -Value $policy -Names @('ContractVersion','Mode','PolicyId','RootScopeId','StateRoot','OwnerSid','ParentOperationId','RuntimePins')
    if ($policy.ContractVersion -cne 'SqlServerLab.OwnedHostPolicy/1.0' -or $policy.Mode -cne 'OwnedRunWindows' -or
        [string]$policy.StateRoot -cne $root -or $policy.RuntimePins -isnot [array] -or
        @($policy.RuntimePins).Count -notin @(1,2)) { throw 'OWNED_HOST_POLICY_INVALID' }
    Assert-LabOwnedHostGuid -Value $policy.PolicyId
    Assert-LabOwnedHostGuid -Value $policy.RootScopeId
    $null = Assert-LabOwnedHostRootCustody -StateRoot $root -OwnerSid $policy.OwnerSid
    $fileAcl = Get-Acl -LiteralPath $path -ErrorAction Stop
    if (-not $fileAcl.AreAccessRulesProtected -or $fileAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $policy.OwnerSid -or
        @($fileAcl.Access | Where-Object {
            $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -cne $policy.OwnerSid -or
            $_.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $_.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl
        }).Count -or @($fileAcl.Access).Count -ne 1) { throw 'OWNED_HOST_POLICY_CUSTODY_INVALID' }
    if ($policy.ParentOperationId -isnot [string] -or $policy.ParentOperationId.Length -gt 128) {
        throw 'OWNED_HOST_OPERATION_INVALID'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($pin in $policy.RuntimePins) {
        Assert-LabOwnedHostProperties -Value $pin -Names @('Provider','Invocation','Endpoint','IdentityPath','IdentitySha256')
        if ($pin.Provider -cnotin @('docker','podman') -or -not $seen.Add($pin.Provider)) { throw 'OWNED_HOST_PROVIDER_INVALID' }
        $invocation = Assert-LabOwnedHostPath -Path $pin.Invocation
        if (-not (Test-Path -LiteralPath $invocation -PathType Leaf) -or [IO.Path]::GetFileName($invocation) -ine ($pin.Provider + '.exe')) {
            throw 'OWNED_HOST_INVOCATION_INVALID'
        }
        if ($pin.Provider -ceq 'docker') {
            if ([string]$pin.Endpoint -cnotmatch '^npipe:////\./pipe/[A-Za-z0-9_.-]+$' -or $pin.IdentityPath -or $pin.IdentitySha256) {
                throw 'OWNED_HOST_DOCKER_PIN_INVALID'
            }
        }
        else {
            if ([string]$pin.Endpoint -cnotmatch '^ssh://[A-Za-z0-9_-]+@127\.0\.0\.1:[1-9][0-9]{0,4}/[A-Za-z0-9_./-]+$' -or
                [string]$pin.IdentitySha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'OWNED_HOST_PODMAN_PIN_INVALID' }
            $endpointUri = $null
            if (-not [Uri]::TryCreate([string]$pin.Endpoint, [UriKind]::Absolute, [ref]$endpointUri) -or
                $endpointUri.Port -lt 1 -or $endpointUri.Port -gt 65535) { throw 'OWNED_HOST_PODMAN_PIN_INVALID' }
            $identity = Assert-LabOwnedHostPath -Path $pin.IdentityPath
            if (-not (Test-Path -LiteralPath $identity -PathType Leaf) -or
                (Get-FileHash -LiteralPath $identity -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.IdentitySha256) {
                throw 'OWNED_HOST_IDENTITY_DRIFT'
            }
        }
    }
    return $policy
}

function New-LabOwnedHostRunReference {
    param([Parameter(Mandatory)]$Policy, [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId, [Parameter(Mandatory)][hashtable]$Metadata)
    Assert-LabOwnedHostGuid -Value $RunId
    Assert-LabOwnedHostGuid -Value $ScopeId
    $origin = 'WORKFLOW_CONTEXT'
    if (-not $Metadata.workflowOperationId) {
        $Metadata.workflowOperationId = New-LabGuid
        $origin = 'OWN_RUN_ALLOCATED'
    }
    if ($Metadata.workflowOperationId -isnot [string] -or
        $Metadata.workflowOperationId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') { throw 'OWNED_HOST_OPERATION_INVALID' }
    # ParentOperationId ist Herkunft, nicht die Operation legitimer Geschwisterruns.
    return [pscustomobject][ordered]@{
        ContractVersion = 'SqlServerLab.OwnedHostRunReference/1.0'
        PolicyId = $Policy.PolicyId; RootScopeId = $Policy.RootScopeId
        PolicySha256 = (Get-FileHash -LiteralPath (Join-Path $Policy.StateRoot 'owned-host-policy.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        RunId = $RunId; ScopeId = $ScopeId
        WorkflowOperationId = [string]$Metadata.workflowOperationId; OperationOrigin = $origin
    }
}

function Get-LabOwnedHostRunPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$StateRoot)
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if (-not $run) { throw 'OWNED_HOST_RUN_MISSING' }
    $reference = $run.metadata.ownedHostIntegration
    $hasPolicy = ((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json')) -or (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-required')) -or (Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json')))))
    if (-not $reference -and -not $hasPolicy) { return $null }
    if (-not $reference) { throw 'OWNED_HOST_RUN_REFERENCE_MISSING' }
    Assert-LabOwnedHostProperties -Value $reference -Names @('ContractVersion','PolicyId','RootScopeId','PolicySha256','RunId','ScopeId','WorkflowOperationId','OperationOrigin')
    $policy = Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required
    $hash = (Get-FileHash -LiteralPath (Join-Path $policy.StateRoot 'owned-host-policy.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($reference.ContractVersion -cne 'SqlServerLab.OwnedHostRunReference/1.0' -or
        $reference.PolicyId -cne $policy.PolicyId -or $reference.RootScopeId -cne $policy.RootScopeId -or
        $reference.PolicySha256 -cne $hash -or $reference.RunId -cne $RunId -or $run.runId -cne $RunId -or
        $reference.ScopeId -cne $run.scopeId -or $reference.WorkflowOperationId -cne $run.metadata.workflowOperationId -or
        $reference.OperationOrigin -cnotin @('WORKFLOW_CONTEXT','OWN_RUN_ALLOCATED')) { throw 'OWNED_HOST_RUN_REFERENCE_DRIFT' }
    Assert-LabOwnedHostGuid -Value $reference.RunId
    Assert-LabOwnedHostGuid -Value $reference.ScopeId
    return $policy
}

function Invoke-LabOwnedHostNativeProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo,
        [ValidateRange(1,86400)][int]$TimeoutSeconds = 60,
        [ValidateRange(4096,1048576)][int]$MaximumBytes = 1048576)
    # Beide Pipes werden gemeinsam begrenzt; keine ReadToEnd-Puffer oder Rohdateien.
    $process = $null
    $streams = @([IO.MemoryStream]::new(), [IO.MemoryStream]::new())
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $completed = $false
    try {
        $process = [Diagnostics.Process]::Start($StartInfo)
        $pipes = @($process.StandardOutput.BaseStream, $process.StandardError.BaseStream)
        $buffers = @([byte[]]::new(4096), [byte[]]::new(4096))
        $done = @($false, $false)
        $tasks = @($pipes[0].ReadAsync($buffers[0], 0, 4096), $pipes[1].ReadAsync($buffers[1], 0, 4096))
        $total = 0
        while ($true) {
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'OWNED_HOST_COMMAND_TIMEOUT' }
            for ($index = 0; $index -lt 2; $index++) {
                if (-not $done[$index] -and $tasks[$index].IsCompleted) {
                    $count = $tasks[$index].GetAwaiter().GetResult()
                    if ($count -eq 0) { $done[$index] = $true; continue }
                    $total += $count
                    if ($total -gt $MaximumBytes) { throw 'OWNED_HOST_COMMAND_OUTPUT_LIMIT' }
                    $streams[$index].Write($buffers[$index], 0, $count)
                    $tasks[$index] = $pipes[$index].ReadAsync($buffers[$index], 0, 4096)
                }
            }
            if ($process.HasExited -and $done[0] -and $done[1]) { $completed = $true; break }
            Start-Sleep -Milliseconds 10
        }
        $encoding = [Text.UTF8Encoding]::new($false, $true)
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $encoding.GetString($streams[0].ToArray())
            Stderr = $encoding.GetString($streams[1].ToArray())
        }
    }
    finally {
        try {
            if ($process) {
                if (-not $completed) {
                    if (-not $process.HasExited) { $process.Kill($true) }
                    $terminated = $process.WaitForExit(5000)
                    $drainClock = [Diagnostics.Stopwatch]::StartNew()
                    while ($terminated -and $done -and (-not $done[0] -or -not $done[1]) -and $drainClock.Elapsed.TotalSeconds -lt 5) {
                        for ($index = 0; $index -lt 2; $index++) {
                            if (-not $done[$index] -and $tasks[$index].IsCompleted) {
                                $count = $tasks[$index].GetAwaiter().GetResult()
                                if ($count -eq 0) { $done[$index] = $true }
                                else { $tasks[$index] = $pipes[$index].ReadAsync($buffers[$index], 0, 4096) }
                            }
                        }
                        if (-not $done[0] -or -not $done[1]) { Start-Sleep -Milliseconds 10 }
                    }
                    if (-not $terminated -or ($done -and (-not $done[0] -or -not $done[1]))) {
                        throw 'OWNED_HOST_COMMAND_TERMINATION_UNCONFIRMED'
                    }
                }
            }
        }
        finally {
            if ($process) { $process.Dispose() }
            foreach ($stream in $streams) { $stream.Dispose() }
            $StartInfo.ArgumentList.Clear()
        }
    }
}

function Invoke-LabOwnedHostPinnedCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Arguments,
        [ValidateRange(1,86400)][int]$TimeoutSeconds = 60)
    $policy = Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required
    $pins = @($policy.RuntimePins | Where-Object { $_.Provider -ceq $Provider })
    if ($pins.Count -ne 1) { throw 'OWNED_HOST_PROVIDER_NOT_SELECTED' }
    $pin = $pins[0]
    # Callerargumente duerfen die gespeicherte Route nicht uebersteuern.
    if (@($Arguments | Where-Object { $_ -cmatch '^(--host|--context|--connection|--url|--identity|--remote)(=|$)' }).Count -or
        ($Provider -ceq 'docker' -and $Arguments[0] -cne 'exec' -and @($Arguments | Where-Object { $_ -cmatch '^-H' }).Count) -or
        ($Provider -ceq 'podman' -and $Arguments[0] -cnotin @('exec','create') -and @($Arguments | Where-Object { $_ -cmatch '^-c($|=)' }).Count) -or
        @($Arguments).Count -eq 0 -or $Arguments[0].StartsWith('-')) {
        throw 'OWNED_HOST_ROUTE_OVERRIDE_FORBIDDEN'
    }
    Assert-LabOwnedHostCommandScope -StateRoot $StateRoot -Provider $Provider -Arguments $Arguments
    $start = [Diagnostics.ProcessStartInfo]::new([string]$pin.Invocation)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $routingEnvironment = @('DOCKER_HOST','DOCKER_CONTEXT','DOCKER_TLS','DOCKER_TLS_VERIFY','DOCKER_CERT_PATH',
        'CONTAINER_HOST','CONTAINER_CONNECTION','CONTAINER_SSHKEY','PODMAN_SSHKEY','PODMAN_CONNECTIONS_CONF','SSH_AUTH_SOCK','SSH_AGENT_PID')
    foreach ($name in $routingEnvironment) { $null = $start.Environment.Remove($name) }
    $prefix = if ($Provider -ceq 'docker') { @('--host', [string]$pin.Endpoint) }
        else { @('--remote', '--url', [string]$pin.Endpoint, '--identity', [string]$pin.IdentityPath) }
    foreach ($argument in @($prefix) + @($Arguments)) { $start.ArgumentList.Add($argument) }
    return Invoke-LabOwnedHostNativeProcess -StartInfo $start -TimeoutSeconds $TimeoutSeconds
}

function Invoke-LabContainerRuntimeCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$ArgumentList,
        [string]$StateRoot, [string]$RunId, [string]$Invocation,
        [ValidateRange(1,86400)][int]$TimeoutSeconds = 60, [switch]$NativeResult,
        [ValidateSet('ImageBuild','Transfer','Restore','Import','Cleanup','GuestWait','Extract','SqlReadiness','SqlQuery')][string]$Phase = 'Cleanup',
        [object]$Progress)
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $policy = if ($RunId) { Get-LabOwnedHostRunPolicy -RunId $RunId -StateRoot $StateRoot }
        elseif (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json')) -or (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-required')) -or (Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json')))))) { Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required }
        else { $null }
    if (-not $policy) {
        if (-not $Invocation) { $Invocation = Get-LabHostToolInvocation -Name $Provider }
        if ($NativeResult) {
            return Invoke-LabProgressNativeCommand -FilePath $Invocation -ArgumentList $ArgumentList `
                -Phase $Phase -TimeoutSeconds $TimeoutSeconds -Progress $Progress
        }
        & $Invocation @ArgumentList
        Set-Variable -Name LASTEXITCODE -Value $LASTEXITCODE -Scope 1
        return
    }
    # Public workflows can supply a name; only the bridge resolves it, with
    # persisted custody and a fresh pinned observation, before effect dispatch.
    $boundArguments=@($ArgumentList)
    if ($boundArguments[0] -cin @('start','stop','rm','exec','wait')) {
        $index=1
        while ($index -lt $boundArguments.Count -and $boundArguments[$index].StartsWith('-')) {
            $option=$boundArguments[$index]
            if ($option -cin @('--user','-u','--env','-e','--workdir','-w','--time','--timeout','-t') -and
                -not ($boundArguments[0] -ceq 'exec' -and $option -ceq '-t')) { $index+=2 }
            elseif ($option -cin @('--force','-f','--attach','-a','--interactive','-i','--tty','-t','--detach','-d') -or
                $option -cmatch '^--(user|env|workdir|time|timeout)=') { $index++ }
            else { throw 'OWNED_HOST_EFFECT_ARGUMENT_UNSUPPORTED' }
        }
        if ($index -ge $boundArguments.Count) { throw 'OWNED_HOST_CONTAINER_CONTEXT_REQUIRED' }
        $boundArguments[$index]=Resolve-LabOwnedHostContainerEffect -StateRoot $StateRoot -Provider $Provider -RunId $RunId -ContainerIdOrName $boundArguments[$index]
    }
    elseif ($boundArguments[0] -ceq 'cp' -and $boundArguments.Count -eq 3) {
        foreach ($index in @(1,2)) {
            if ($boundArguments[$index] -cmatch '^([^:]+):(/.*)$') {
                $name=$Matches[1];$containerPath=$Matches[2]
                $cid=Resolve-LabOwnedHostContainerEffect -StateRoot $StateRoot -Provider $Provider -RunId $RunId -ContainerIdOrName $name
                $boundArguments[$index]=$cid+':'+$containerPath
            }
        }
    }
    $result = Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments $boundArguments -TimeoutSeconds $TimeoutSeconds
    $output = @()
    if ($result.Stdout.Length) { $output += @($result.Stdout.TrimEnd("`r", "`n") -split '\r?\n') }
    if ($NativeResult) {
        if ($result.Stderr.Length) { $output += @($result.Stderr.TrimEnd("`r", "`n") -split '\r?\n') }
        return [pscustomobject]@{ ExitCode=$result.ExitCode; Output=$output }
    }
    Set-Variable -Name LASTEXITCODE -Value $result.ExitCode -Scope 1
    $global:LASTEXITCODE = $result.ExitCode
    $output
    if ($result.Stderr.Length) { Write-Error -Message $result.Stderr -ErrorAction Continue }
}

function Write-LabOwnedHostRecordExclusive {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Record)
    $safe = Assert-LabOwnedHostPath -Path $Path
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Record | ConvertTo-Json -Depth 12))
    if ($bytes.Length -gt 65536) { throw 'OWNED_HOST_RECORD_SIZE_INVALID' }
    $stream = [IO.File]::Open($safe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
}

function New-LabOwnedHostContainerIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId,[Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string]$ContainerName)
    $policy = Get-LabOwnedHostRunPolicy -RunId $RunId -StateRoot $StateRoot
    if (-not $policy) { return $null }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ($run.scopeId -cne $ScopeId -or $InstanceId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -or
        $ContainerName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$') { throw 'OWNED_HOST_CONTAINER_INTENT_INVALID' }
    $directory = Join-Path (Join-Path (Join-Path $policy.StateRoot 'runs') $RunId) 'owned-host-containers'
    $null = Assert-LabOwnedHostPath $directory
    if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -Path $directory -ItemType Directory -ErrorAction Stop }
    $intent = [pscustomobject][ordered]@{
        ContractVersion='SqlServerLab.OwnedHostContainerIntent/1.0'; IntentId=New-LabGuid
        PolicyId=$policy.PolicyId; RootScopeId=$policy.RootScopeId
        RunId=$RunId; ScopeId=$ScopeId; WorkflowOperationId=[string]$run.metadata.workflowOperationId
        InstanceId=$InstanceId; Provider=$Provider; ContainerName=$ContainerName
    }
    Write-LabOwnedHostRecordExclusive -Path (Join-Path $directory ($intent.IntentId+'.intent.json')) -Record $intent
    $existing = Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider `
        -Arguments @('ps','-a','--no-trunc','--filter',('name=^'+[regex]::Escape($ContainerName)+'$'),'--format','{{.ID}}')
    if ($existing.ExitCode -ne 0) { throw 'OWNED_HOST_CONTAINER_ABSENCE_UNVERIFIABLE' }
    if ($existing.Stdout.Trim()) { throw 'OWNED_HOST_CONTAINER_NAME_COLLISION' }
    return $intent
}

function Get-LabOwnedHostContainerLabels {
    param([Parameter(Mandatory)]$Intent)
    return @('--label',('sql-server-lab.owned-host-policy-id='+$Intent.PolicyId),
        '--label',('sql-server-lab.owned-host-root-scope-id='+$Intent.RootScopeId),
        '--label',('sql-server-lab.owned-host-intent-id='+$Intent.IntentId))
}

function Get-LabOwnedHostContainerObservation {
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)]$Intent,[Parameter(Mandatory)][string]$ContainerIdOrName)
    $null = Get-LabOwnedHostRunPolicy -RunId $Intent.RunId -StateRoot $StateRoot
    $result = Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Intent.Provider -Arguments @('inspect',$ContainerIdOrName)
    if ($result.ExitCode -ne 0) { throw 'OWNED_HOST_CONTAINER_INSPECT_FAILED' }
    $containers = @($result.Stdout | ConvertFrom-Json -Depth 32 -ErrorAction Stop)
    if ($containers.Count -ne 1) { throw 'OWNED_HOST_CONTAINER_AMBIGUOUS' }
    $container = $containers[0]; $labels = $container.Config.Labels
    if ([string]$container.Id -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$labels.'sql-server-lab.run-id' -cne $Intent.RunId -or [string]$labels.'sql-server-lab.scope-id' -cne $Intent.ScopeId -or
        [string]$labels.'sql-server-lab.instance-id' -cne $Intent.InstanceId -or
        [string]$labels.'sql-server-lab.owned-host-policy-id' -cne $Intent.PolicyId -or
        [string]$labels.'sql-server-lab.owned-host-root-scope-id' -cne $Intent.RootScopeId -or
        [string]$labels.'sql-server-lab.owned-host-intent-id' -cne $Intent.IntentId -or
        ([string]$container.Name).TrimStart('/') -cne $Intent.ContainerName) { throw 'OWNED_HOST_CONTAINER_BINDING_DRIFT' }
    if ($ContainerIdOrName -cmatch '^[a-f0-9]{64}$' -and [string]$container.Id -cne $ContainerIdOrName) { throw 'OWNED_HOST_CONTAINER_BINDING_DRIFT' }
    return $container
}

function Register-LabOwnedHostContainer {
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)]$Intent,[Parameter(Mandatory)][string]$ContainerIdOrName)
    $container = Get-LabOwnedHostContainerObservation -StateRoot $StateRoot -Intent $Intent -ContainerIdOrName $ContainerIdOrName
    $directory = Join-Path (Join-Path (Join-Path $StateRoot 'runs') $Intent.RunId) 'owned-host-containers'
    $intentPath = Join-Path $directory ($Intent.IntentId+'.intent.json')
    $stored = Read-LabOwnedHostRecord -Path $intentPath
    if (($stored|ConvertTo-Json -Depth 12 -Compress) -cne ($Intent|ConvertTo-Json -Depth 12 -Compress)) { throw 'OWNED_HOST_CONTAINER_INTENT_DRIFT' }
    $receipt = [pscustomobject][ordered]@{
        ContractVersion='SqlServerLab.OwnedHostContainerReceipt/1.0'; IntentId=$Intent.IntentId
        PolicyId=$Intent.PolicyId; RootScopeId=$Intent.RootScopeId; RunId=$Intent.RunId; ScopeId=$Intent.ScopeId
        InstanceId=$Intent.InstanceId; Provider=$Intent.Provider; ContainerId=[string]$container.Id
        IntentSha256=(Get-FileHash -LiteralPath $intentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $receiptPath = Join-Path $directory ($Intent.IntentId+'.created.json')
    if (Test-Path -LiteralPath $receiptPath) {
        $prior = Read-LabOwnedHostRecord $receiptPath
        if (($prior|ConvertTo-Json -Depth 12 -Compress) -cne ($receipt|ConvertTo-Json -Depth 12 -Compress)) {
            throw 'OWNED_HOST_CONTAINER_RECEIPT_DRIFT'
        }
    }
    else { Write-LabOwnedHostRecordExclusive -Path $receiptPath -Record $receipt }
    return $receipt
}

function Remove-LabOwnedHostFailedContainer {
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)]$Intent)
    # A failed create may have produced a container even when the client returned
    # no ID. Reconcile only our immutable intention and never remove by name.
    $found = Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Intent.Provider `
        -Arguments @('ps','-a','--no-trunc','--filter',('name=^'+[regex]::Escape($Intent.ContainerName)+'$'),'--format','{{.ID}}')
    if ($found.ExitCode -ne 0) { throw 'OWNED_HOST_FAILED_CREATE_UNVERIFIABLE' }
    if (-not $found.Stdout.Trim()) { return }
    $receipt = Register-LabOwnedHostContainer -StateRoot $StateRoot -Intent $Intent -ContainerIdOrName $Intent.ContainerName
    Assert-LabOwnedHostContainerEffect -StateRoot $StateRoot -RunId $Intent.RunId -Provider $Intent.Provider -ContainerId $receipt.ContainerId
    $removed = Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Intent.Provider -Arguments @('rm','-f',$receipt.ContainerId)
    if ($removed.ExitCode -ne 0) { throw 'OWNED_HOST_FAILED_CREATE_RECOVERY_REQUIRED' }
}

function Resolve-LabOwnedHostContainerEffect {
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string]$ContainerIdOrName,[string]$RunId)
    $result = Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments @('inspect',$ContainerIdOrName)
    if ($result.ExitCode -ne 0) { throw 'OWNED_HOST_CONTAINER_INSPECT_FAILED' }
    $items = @($result.Stdout|ConvertFrom-Json -Depth 32 -ErrorAction Stop)
    if ($items.Count -ne 1) { throw 'OWNED_HOST_CONTAINER_AMBIGUOUS' }
    $actualRunId = [string]$items[0].Config.Labels.'sql-server-lab.run-id'
    if ($RunId -and $RunId -cne $actualRunId) { throw 'OWNED_HOST_CONTAINER_RUN_DRIFT' }
    Assert-LabOwnedHostContainerEffect -StateRoot $StateRoot -RunId $actualRunId -Provider $Provider -ContainerId ([string]$items[0].Id)
    return [string]$items[0].Id
}

function Get-LabOwnedHostExistingNetwork {
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [string]$Name,[string]$Subnet)
    $null = Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required
    $network = Get-LabRuntimeNetwork -Provider $Provider
    if ($Name) { $network.Name=$Name }
    if ($Subnet) { $network.Subnet=(ConvertTo-LabIpv4Subnet $Subnet).Cidr }
    $result = Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments @('network','inspect',$network.Name)
    if ($result.ExitCode -ne 0) { throw 'OWNED_HOST_EXISTING_NETWORK_REQUIRED' }
    $items = @($result.Stdout|ConvertFrom-Json -Depth 30 -ErrorAction Stop)
    if ($items.Count -ne 1) { throw 'OWNED_HOST_NETWORK_AMBIGUOUS' }
    $contract = if ($Provider -eq 'docker') {
        [pscustomobject]@{Subnet=[string]@($items[0].IPAM.Config)[0].Subnet;Internal=[bool]$items[0].Internal}
    } else { Get-LabPodmanNetworkContractFromInspect $items[0] }
    if ($contract.Subnet -cne $network.Subnet -or $contract.Internal) { throw 'OWNED_HOST_NETWORK_CONTRACT_MISMATCH' }
    $list = Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments @('network','ls','-q','--no-trunc')
    if ($list.ExitCode -ne 0) { throw 'OWNED_HOST_NETWORK_INVENTORY_UNVERIFIABLE' }
    $ids = @($list.Stdout -split '\r?\n'|Where-Object {$_})
    if ($ids.Count -gt 256 -or -not $ids.Count) { throw 'OWNED_HOST_NETWORK_INVENTORY_INVALID' }
    $all = Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments (@('network','inspect')+$ids)
    if ($all.ExitCode -ne 0) { throw 'OWNED_HOST_NETWORK_INVENTORY_UNVERIFIABLE' }
    $known = @(Get-LabKnownIpv4Subnets)
    foreach ($item in @($all.Stdout|ConvertFrom-Json -Depth 30 -ErrorAction Stop)) {
        if ([string]$item.Id -ceq [string]$items[0].Id -or [string]$item.name -ceq $network.Name -or [string]$item.Name -ceq $network.Name) { continue }
        if ($Provider -eq 'docker') { $known+=@($item.IPAM.Config|ForEach-Object {[string]$_.Subnet}|Where-Object {$_}) }
        else { $known+=@($item.subnets|ForEach-Object {[string]$_.subnet}|Where-Object {$_}) }
    }
    Assert-LabRuntimeNetworkAvailable -Network $network -KnownSubnets $known
    # Reuse is observation only. No shared network creation or CNI repair.
    return $network
}

function Invoke-LabOwnedHostEphemeralContainer {
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId,[Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string[]]$ContainerArguments)
    $instanceId='probe-'+(New-LabGuid).Replace('-','')
    $name='sql-lab-owned-'+$instanceId
    $intent=New-LabOwnedHostContainerIntent -StateRoot $StateRoot -RunId $RunId -ScopeId $ScopeId -InstanceId $instanceId -Provider $Provider -ContainerName $name
    if (-not $intent) { throw 'OWNED_HOST_EPHEMERAL_CONTEXT_REQUIRED' }
    $labels=@('--label',('sql-server-lab.run-id='+$RunId),'--label',('sql-server-lab.scope-id='+$ScopeId),
        '--label',('sql-server-lab.instance-id='+$instanceId)) + @(Get-LabOwnedHostContainerLabels $intent)
    try {
        $created=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments (@('create','--name',$name)+$labels+$ContainerArguments)
        if ($created.ExitCode -ne 0) { throw 'OWNED_HOST_EPHEMERAL_CREATE_FAILED' }
        $receipt=Register-LabOwnedHostContainer -StateRoot $StateRoot -Intent $intent -ContainerIdOrName $name
        Assert-LabOwnedHostContainerEffect -StateRoot $StateRoot -RunId $RunId -Provider $Provider -ContainerId $receipt.ContainerId
        $started=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments @('start','--attach',$receipt.ContainerId)
        if ($started.ExitCode -ne 0) { throw 'OWNED_HOST_EPHEMERAL_START_FAILED' }
        $observation=Get-LabOwnedHostContainerObservation -StateRoot $StateRoot -Intent $intent -ContainerIdOrName $receipt.ContainerId
        if ($observation.State.Running -or [int]$observation.State.ExitCode -ne 0) { throw 'OWNED_HOST_EPHEMERAL_EXIT_FAILED' }
        return $started.Stdout
    }
    finally { Remove-LabOwnedHostFailedContainer -StateRoot $StateRoot -Intent $intent }
}

function Get-LabOwnedHostVolumeReceipt {
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string]$VolumeName)
    $policy=Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required
    if ($VolumeName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$') { throw 'OWNED_HOST_VOLUME_NAME_INVALID' }
    $directory=Join-Path $policy.StateRoot 'owned-host-volumes'
    $receiptPath=Join-Path $directory ($Provider+'-'+$VolumeName+'.created.json')
    $receipt=Read-LabOwnedHostRecord $receiptPath
    Assert-LabOwnedHostProperties $receipt @('ContractVersion','PolicyId','RootScopeId','Provider','VolumeName','IntentId','RunId','ScopeId','IntentSha256')
    $intentPath=Join-Path $directory ($Provider+'-'+$VolumeName+'.intent.json')
    $intent=Read-LabOwnedHostRecord $intentPath
    Assert-LabOwnedHostProperties $intent @('ContractVersion','PolicyId','RootScopeId','Provider','VolumeName','IntentId','RunId','ScopeId','InstanceId','VersionId','PersistentStorageId','PersistentStorageRole')
    $null=Get-LabOwnedHostRunPolicy -RunId $receipt.RunId -StateRoot $StateRoot
    if ($receipt.ContractVersion -cne 'SqlServerLab.OwnedHostVolumeReceipt/1.0' -or
        $intent.ContractVersion -cne 'SqlServerLab.OwnedHostVolumeIntent/1.0' -or
        $receipt.PolicyId -cne $policy.PolicyId -or $intent.PolicyId -cne $policy.PolicyId -or
        $receipt.RootScopeId -cne $policy.RootScopeId -or $intent.RootScopeId -cne $policy.RootScopeId -or
        $receipt.Provider -cne $Provider -or $intent.Provider -cne $Provider -or
        $receipt.VolumeName -cne $VolumeName -or $intent.VolumeName -cne $VolumeName -or
        $receipt.IntentId -cne $intent.IntentId -or $receipt.RunId -cne $intent.RunId -or $receipt.ScopeId -cne $intent.ScopeId -or
        $receipt.IntentSha256 -cne (Get-FileHash $intentPath).Hash.ToLowerInvariant()) { throw 'OWNED_HOST_VOLUME_RECEIPT_DRIFT' }
    $observed=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments @('volume','inspect',$VolumeName)
    if ($observed.ExitCode -ne 0) { throw 'OWNED_HOST_VOLUME_INSPECT_FAILED' }
    $items=@($observed.Stdout|ConvertFrom-Json -Depth 30 -ErrorAction Stop)
    if ($items.Count -ne 1 -or [string]$items[0].Name -cne $VolumeName) { throw 'OWNED_HOST_VOLUME_AMBIGUOUS' }
    $labels=$items[0].Labels
    if ([string]$labels.'sql-server-lab.run-id' -cne $intent.RunId -or [string]$labels.'sql-server-lab.scope-id' -cne $intent.ScopeId -or
        [string]$labels.'sql-server-lab.owned-host-policy-id' -cne $policy.PolicyId -or
        [string]$labels.'sql-server-lab.owned-host-root-scope-id' -cne $policy.RootScopeId -or
        [string]$labels.'sql-server-lab.owned-host-intent-id' -cne $intent.IntentId) { throw 'OWNED_HOST_VOLUME_BINDING_DRIFT' }
    return [pscustomobject]@{Receipt=$receipt;Intent=$intent;Observation=$items[0]}
}

function Initialize-LabOwnedHostSqlVolume {
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,[Parameter(Mandatory)][string]$VolumeName,
        [Parameter(Mandatory)][string]$Image,[Parameter(Mandatory)][string]$InstanceId,[Parameter(Mandatory)][string]$VersionId,
        [Parameter(Mandatory)][string]$ContainerPath,[string]$PersistentStorageId,[string]$PersistentStorageRole,
        [string]$Persistence,[switch]$SyncImageContent,$RuntimeBinding)
    $policy=Get-LabOwnedHostRunPolicy -RunId $RunId -StateRoot $StateRoot
    $run=Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if (-not $policy -or $run.scopeId -cne $ScopeId) { throw 'OWNED_HOST_VOLUME_CONTEXT_REQUIRED' }
    $directory=Join-Path $policy.StateRoot 'owned-host-volumes'
    $null=Assert-LabOwnedHostPath $directory
    if (-not (Test-Path $directory)) { $null=New-Item -Path $directory -ItemType Directory -ErrorAction Stop }
    $receiptPath=Join-Path $directory ($Provider+'-'+$VolumeName+'.created.json')
    if (Test-Path -LiteralPath $receiptPath) {
        $owned=Get-LabOwnedHostVolumeReceipt -StateRoot $StateRoot -Provider $Provider -VolumeName $VolumeName
        if ($owned.Intent.VersionId -cne $VersionId -or $owned.Intent.PersistentStorageId -cne $PersistentStorageId -or
            $owned.Intent.PersistentStorageRole -cne $PersistentStorageRole) { throw 'OWNED_HOST_VOLUME_LOGICAL_BINDING_DRIFT' }
        return $false
    }
    if ($RuntimeBinding) { throw 'OWNED_HOST_PREEXISTING_STORE_FORBIDDEN' }
    $intent=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.OwnedHostVolumeIntent/1.0';PolicyId=$policy.PolicyId;RootScopeId=$policy.RootScopeId
        Provider=$Provider;VolumeName=$VolumeName;IntentId=New-LabGuid;RunId=$RunId;ScopeId=$ScopeId
        InstanceId=$InstanceId;VersionId=$VersionId;PersistentStorageId=$PersistentStorageId;PersistentStorageRole=$PersistentStorageRole}
    $intentPath=Join-Path $directory ($Provider+'-'+$VolumeName+'.intent.json')
    Write-LabOwnedHostRecordExclusive -Path $intentPath -Record $intent
    $list=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments @('volume','ls','--filter',('name=^'+[regex]::Escape($VolumeName)+'$'),'--format','{{.Name}}')
    if ($list.ExitCode -ne 0 -or $list.Stdout.Trim()) { throw 'OWNED_HOST_VOLUME_ABSENCE_UNVERIFIABLE' }
    $labels=@('--label',('sql-server-lab.run-id='+$RunId),'--label',('sql-server-lab.scope-id='+$ScopeId),
        '--label',('sql-server-lab.instance-id='+$InstanceId),'--label',('sql-server-lab.sql-major-version='+$VersionId.Substring(0,4)))+@(Get-LabOwnedHostContainerLabels $intent)
    if ($Persistence) {$labels+=@('--label',('sql-server-lab.persistence='+$Persistence))}
    if ($PersistentStorageId) {$labels+=@('--label',('sql-server-lab.persistent-storage-id='+$PersistentStorageId))}
    if ($PersistentStorageRole) {$labels+=@('--label',('sql-server-lab.storage-role='+$PersistentStorageRole))}
    $created=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments (@('volume','create')+$labels+@($VolumeName))
    # A client failure leaves the immutable intention for explicit recovery; no
    # unverified volume is adopted or automatically removed.
    if ($created.ExitCode -ne 0) { throw 'OWNED_HOST_VOLUME_CREATE_RECOVERY_REQUIRED' }
    $receipt=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.OwnedHostVolumeReceipt/1.0';PolicyId=$policy.PolicyId;RootScopeId=$policy.RootScopeId
        Provider=$Provider;VolumeName=$VolumeName;IntentId=$intent.IntentId;RunId=$RunId;ScopeId=$ScopeId;IntentSha256=(Get-FileHash $intentPath).Hash.ToLowerInvariant()}
    Write-LabOwnedHostRecordExclusive -Path $receiptPath -Record $receipt
    $null=Get-LabOwnedHostVolumeReceipt -StateRoot $StateRoot -Provider $Provider -VolumeName $VolumeName
    $command=if ($SyncImageContent) {
        "if [ ! -d '$ContainerPath' ]; then exit 1; fi; cp -a '$ContainerPath'/. /sql-lab-volume-init/; chown --reference='$ContainerPath' /sql-lab-volume-init && chmod --reference='$ContainerPath' /sql-lab-volume-init"
    } else {'chown -R 10001:0 /sql-lab-volume-init && chmod 0770 /sql-lab-volume-init'}
    $null=Invoke-LabOwnedHostEphemeralContainer -StateRoot $StateRoot -RunId $RunId -ScopeId $ScopeId -Provider $Provider `
        -ContainerArguments @('--network','none','--user','0:0','--entrypoint','/bin/sh','-v',($VolumeName+':/sql-lab-volume-init'),$Image,'-c',$command)
    return $true
}

function Resolve-LabOwnedHostTaskUserSid {
    param([string]$UserId)
    try {
        if ([string]::IsNullOrWhiteSpace($UserId) -or $UserId -cne $UserId.Trim()) { throw 'INVALID_TASK_USER' }
        if ($UserId -cmatch '^S-1-') {
            return [Security.Principal.SecurityIdentifier]::new($UserId).Value
        }
        return [Security.Principal.NTAccount]::new($UserId).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    catch { throw 'OWNED_HOST_TASK_BINDING_DRIFT' }
}

function Assert-LabOwnedHostTaskBinding {
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)]$Intent,[Parameter(Mandatory)]$Task)
    $policy=Get-LabOwnedHostRunPolicy -RunId $Intent.RunId -StateRoot $StateRoot
    Assert-LabOwnedHostProperties $Intent @('ContractVersion','PolicyId','RunId','OwnerSid','Provider','TaskName','ScriptPath','ScriptSha256','Invocation','Arguments')
    if ($Intent.Provider -cnotin @('docker','podman')) { throw 'OWNED_HOST_TASK_BINDING_DRIFT' }
    $expectedName='SQL_Server_Lab_Owned_'+$policy.PolicyId.Replace('-','')+'_'+$Intent.RunId.Replace('-','')+'_'+$Intent.Provider
    $expectedPath=Join-Path (Join-Path (Join-Path (Join-Path $policy.StateRoot 'runs') $Intent.RunId) 'owned-host-tasks') ($Intent.Provider+'.coordinator.ps1')
    $null=Assert-LabOwnedHostPath $Intent.ScriptPath
    if ($Intent.PolicyId -cne $policy.PolicyId -or $Intent.OwnerSid -cne $policy.OwnerSid -or
        $Intent.ContractVersion -cne 'SqlServerLab.OwnedHostTaskIntent/1.0' -or
        $Intent.TaskName -cne $expectedName -or $Intent.ScriptPath -cne $expectedPath -or
        $Intent.Arguments -cne ('-NoProfile -NonInteractive -File "'+$expectedPath+'"') -or
        $Task.TaskName -cne $Intent.TaskName -or $Task.TaskPath -cne '\' -or
        @($Task.Actions).Count -ne 1 -or @($Task.Triggers).Count -ne 1 -or
        (Resolve-LabOwnedHostTaskUserSid -UserId ([string]$Task.Principal.UserId)) -cne $Intent.OwnerSid -or
        [string]$Task.Principal.LogonType -cne 'Interactive' -or [string]$Task.Principal.RunLevel -cne 'Limited' -or
        [string]$Task.Actions[0].Execute -cne $Intent.Invocation -or
        [string]$Task.Actions[0].Arguments -cne $Intent.Arguments -or
        [string]$Task.Actions[0].WorkingDirectory -cne '' -or
        (Resolve-LabOwnedHostTaskUserSid -UserId ([string]$Task.Triggers[0].UserId)) -cne $Intent.OwnerSid -or
        [string]$Task.Triggers[0].CimClass.CimClassName -cne 'MSFT_TaskLogonTrigger' -or
        $Intent.ScriptSha256 -cne (Get-FileHash -LiteralPath $Intent.ScriptPath).Hash.ToLowerInvariant()) {
        throw 'OWNED_HOST_TASK_BINDING_DRIFT'
    }
}

function Assert-LabOwnedHostTaskReceipt {
    param([string]$StateRoot,$Intent,[switch]$Required)
    $directory=Join-Path (Join-Path (Join-Path $StateRoot 'runs') $Intent.RunId) 'owned-host-tasks'
    $path=Join-Path $directory ($Intent.Provider+'.created.json')
    if (-not (Test-Path $path)) {
        if ($Required) { throw 'OWNED_HOST_TASK_RECOVERY_REQUIRED' }
        return # Exact intention/task binding still permits partial-create compensation.
    }
    $receipt=Read-LabOwnedHostRecord $path
    Assert-LabOwnedHostProperties $receipt @('ContractVersion','PolicyId','RunId','TaskName','IntentSha256')
    if ($receipt.ContractVersion -cne 'SqlServerLab.OwnedHostTaskReceipt/1.0' -or $receipt.PolicyId -cne $Intent.PolicyId -or
        $receipt.RunId -cne $Intent.RunId -or $receipt.TaskName -cne $Intent.TaskName -or
        $receipt.IntentSha256 -cne (Get-FileHash (Join-Path $directory ($Intent.Provider+'.intent.json'))).Hash.ToLowerInvariant()) {
        throw 'OWNED_HOST_TASK_RECEIPT_DRIFT'
    }
}

function Enable-LabOwnedHostAutoStart {
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)
    $policy=Get-LabOwnedHostRunPolicy -RunId $RunId -StateRoot $StateRoot
    if (-not $policy) { throw 'OWNED_HOST_TASK_CONTEXT_REQUIRED' }
    $run=Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    $directory=Join-Path (Join-Path (Join-Path $policy.StateRoot 'runs') $RunId) 'owned-host-tasks'
    $null=Assert-LabOwnedHostPath $directory
    if (-not (Test-Path $directory)) { $null=New-Item -Path $directory -ItemType Directory -ErrorAction Stop }
    $intentPath=Join-Path $directory ($Provider+'.intent.json')
    if (Test-Path -LiteralPath $intentPath) {
        $intent=Read-LabOwnedHostRecord $intentPath
        $task=Get-ScheduledTask -TaskPath '\' -TaskName $intent.TaskName -ErrorAction Stop
        Assert-LabOwnedHostTaskBinding -StateRoot $StateRoot -Intent $intent -Task $task
        Assert-LabOwnedHostTaskReceipt -StateRoot $StateRoot -Intent $intent -Required
        return [pscustomobject]@{Enabled=$true;Mechanism='OwnedRunLogonCoordinator';TaskName=$intent.TaskName;LogonDispatchProven=$false}
    }
    $taskName='SQL_Server_Lab_Owned_'+$policy.PolicyId.Replace('-','')+'_'+$RunId.Replace('-','')+'_'+$Provider
    if (Get-ScheduledTask -TaskPath '\' -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'OWNED_HOST_TASK_NAME_COLLISION' }
    $scriptPath=Join-Path $directory ($Provider+'.coordinator.ps1')
    $sourceRoot=Split-Path $PSScriptRoot -Parent
    $sources=@('Private/Common.ps1','Private/StateMachine.ps1','Private/ContainerOwnedHostIntegration.ps1')|ForEach-Object {
        $path=Join-Path $sourceRoot $_
        [pscustomobject]@{Path=$path;Sha256=(Get-FileHash $path).Hash.ToLowerInvariant()}
    }
    $literal={param($value) "'"+([string]$value).Replace("'","''")+"'"}
    $sourceJson=ConvertTo-Json -InputObject @($sources) -Depth 5 -Compress
    $scriptText=@'
# Own-run coordinator: registration does not prove a logon dispatch.
$ErrorActionPreference='Stop'
$sources=SOURCE_JSON | ConvertFrom-Json
$module=New-Module -ArgumentList $sources -ScriptBlock {
    param($sources)
    foreach($source in $sources) {
        if ((Get-FileHash -LiteralPath $source.Path).Hash.ToLowerInvariant() -cne $source.Sha256) { throw 'OWNED_HOST_COORDINATOR_SOURCE_DRIFT' }
        . $source.Path
    }
}
& $module {
    param($StateRoot,$RunId,$Provider)
    $null=Get-LabOwnedHostRunPolicy -RunId $RunId -StateRoot $StateRoot
    $directory=Join-Path (Join-Path (Join-Path $StateRoot 'runs') $RunId) 'owned-host-containers'
    $receipts=@(Get-ChildItem -LiteralPath $directory -Filter '*.created.json' -File -ErrorAction Stop)
    if ($receipts.Count -gt 128) { throw 'OWNED_HOST_CONTAINER_RECEIPT_LIMIT' }
    foreach($file in $receipts) {
        $receipt=Read-LabOwnedHostRecord $file.FullName
        if ($receipt.Provider -cne $Provider) { continue }
        $result=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments @('inspect',$receipt.ContainerId)
        if($result.ExitCode -ne 0) { continue }
        $items=@($result.Stdout|ConvertFrom-Json -Depth 32)
        if($items.Count -ne 1) { throw 'OWNED_HOST_CONTAINER_AMBIGUOUS' }
        if($items[0].Config.Labels.'sql-server-lab.autostart' -cne 'on') { continue }
        Assert-LabOwnedHostContainerEffect -StateRoot $StateRoot -RunId $RunId -Provider $Provider -ContainerId $receipt.ContainerId
        $started=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments @('start',$receipt.ContainerId)
        if($started.ExitCode -ne 0) { throw 'OWNED_HOST_COORDINATOR_START_FAILED' }
    }
} ROOT_LITERAL RUN_LITERAL PROVIDER_LITERAL
'@
    $scriptText=$scriptText.Replace('SOURCE_JSON',(& $literal $sourceJson)).Replace('ROOT_LITERAL',(& $literal $StateRoot)).Replace('RUN_LITERAL',(& $literal $RunId)).Replace('PROVIDER_LITERAL',(& $literal $Provider))
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($scriptText)
    $stream=[IO.File]::Open($scriptPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)} finally {$stream.Dispose()}
    $invocation=(Get-Process -Id $PID).Path
    $arguments='-NoProfile -NonInteractive -File "'+$scriptPath+'"'
    $intent=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.OwnedHostTaskIntent/1.0';PolicyId=$policy.PolicyId;RunId=$RunId
        OwnerSid=$policy.OwnerSid;Provider=$Provider;TaskName=$taskName;ScriptPath=$scriptPath;ScriptSha256=(Get-FileHash $scriptPath).Hash.ToLowerInvariant();Invocation=$invocation;Arguments=$arguments}
    Write-LabOwnedHostRecordExclusive -Path $intentPath -Record $intent
    $action=New-ScheduledTaskAction -Execute $invocation -Argument $arguments
    $trigger=New-ScheduledTaskTrigger -AtLogOn -User $policy.OwnerSid
    $principal=New-ScheduledTaskPrincipal -UserId $policy.OwnerSid -LogonType Interactive -RunLevel Limited
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::FromMinutes(5)) -MultipleInstances IgnoreNew
    # No Force, Desktop/HKCU mutation, task dispatch or machine start.
    $null=Register-ScheduledTask -TaskPath '\' -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description ('SQL_Server_Lab owned run '+$RunId) -ErrorAction Stop
    $task=Get-ScheduledTask -TaskPath '\' -TaskName $taskName -ErrorAction Stop
    Assert-LabOwnedHostTaskBinding -StateRoot $StateRoot -Intent $intent -Task $task
    Write-LabOwnedHostRecordExclusive -Path (Join-Path $directory ($Provider+'.created.json')) -Record ([pscustomobject]@{
        ContractVersion='SqlServerLab.OwnedHostTaskReceipt/1.0';PolicyId=$policy.PolicyId;RunId=$RunId;TaskName=$taskName;IntentSha256=(Get-FileHash $intentPath).Hash.ToLowerInvariant()})
    return [pscustomobject]@{Enabled=$true;Mechanism='OwnedRunLogonCoordinator';TaskName=$taskName;LogonDispatchProven=$false}
}

function Remove-LabOwnedHostAutoStartIfUnused {
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)
    $null=Get-LabOwnedHostRunPolicy -RunId $RunId -StateRoot $StateRoot
    $directory=Join-Path (Join-Path (Join-Path $StateRoot 'runs') $RunId) 'owned-host-tasks'
    $intentPath=Join-Path $directory ($Provider+'.intent.json')
    if (-not (Test-Path -LiteralPath $intentPath)) { return }
    $intent=Read-LabOwnedHostRecord $intentPath
    $list=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments @('ps','-a','--no-trunc','--filter',('label=sql-server-lab.run-id='+$RunId),'--format','{{.ID}}')
    if ($list.ExitCode -ne 0) { throw 'OWNED_HOST_TASK_UNUSED_UNVERIFIABLE' }
    if ($list.Stdout.Trim()) { return }
    $task=Get-ScheduledTask -TaskPath '\' -TaskName $intent.TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return }
    Assert-LabOwnedHostTaskBinding -StateRoot $StateRoot -Intent $intent -Task $task
    Assert-LabOwnedHostTaskReceipt -StateRoot $StateRoot -Intent $intent
    Unregister-ScheduledTask -TaskPath '\' -TaskName $intent.TaskName -Confirm:$false -ErrorAction Stop
    if (Get-ScheduledTask -TaskPath '\' -TaskName $intent.TaskName -ErrorAction SilentlyContinue) { throw 'OWNED_HOST_TASK_DELETE_UNCONFIRMED' }
    # Keep the exclusive intention, script and receipts as local recovery evidence.
}

function Get-LabOwnedHostImageObservation {
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string]$Image)
    $result=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments @('image','inspect',$Image)
    if ($result.ExitCode -ne 0) { return $null }
    $items=@($result.Stdout|ConvertFrom-Json -Depth 32 -ErrorAction Stop)
    if ($items.Count -eq 1 -and $Provider -ceq 'podman' -and [string]$items[0].Id -cmatch '^[a-f0-9]{64}$') {
        $items[0].Id='sha256:'+ [string]$items[0].Id
    }
    if ($items.Count -ne 1 -or [string]$items[0].Id -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'OWNED_HOST_IMAGE_INSPECT_INVALID' }
    return $items[0]
}

function Get-LabOwnedHostToolImageReceipt {
    param([string]$StateRoot,[string]$Provider,[string]$ImageKey)
    $policy=Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required
    if ($Provider -cnotin @('docker','podman') -or $ImageKey -cnotmatch '^[a-f0-9]{64}$') { throw 'OWNED_HOST_TOOL_IMAGE_CONTEXT_INVALID' }
    $directory=Join-Path $StateRoot 'owned-host-tool-images';$key=$Provider+'-'+$ImageKey
    $receiptPath=Join-Path $directory ($key+'.created.json');$intentPath=Join-Path $directory ($key+'.intent.json')
    $receipt=Read-LabOwnedHostRecord $receiptPath;$intent=Read-LabOwnedHostRecord $intentPath
    Assert-LabOwnedHostProperties $receipt @('ContractVersion','PolicyId','RootScopeId','IntentId','Provider','RunId','ImageKey','Image','ImageId','OwnsTag','IntentSha256')
    Assert-LabOwnedHostProperties $intent @('ContractVersion','PolicyId','RootScopeId','IntentId','Provider','RunId','ScopeId','ImageKey','Tag')
    $null=Get-LabOwnedHostRunPolicy -StateRoot $StateRoot -RunId $receipt.RunId
    $run=Get-LabRunState -StateRoot $StateRoot -RunId $receipt.RunId
    $tag='sql-server-lab/owned-tool:'+$policy.PolicyId.Replace('-','')+'-'+$ImageKey.Substring(0,24)+'-'+$Provider
    if ($receipt.ContractVersion -cne 'SqlServerLab.OwnedHostToolImageReceipt/1.0' -or $intent.ContractVersion -cne 'SqlServerLab.OwnedHostToolImageIntent/1.0' -or
        $receipt.PolicyId -cne $policy.PolicyId -or $intent.PolicyId -cne $policy.PolicyId -or $receipt.RootScopeId -cne $policy.RootScopeId -or $intent.RootScopeId -cne $policy.RootScopeId -or
        $receipt.Provider -cne $Provider -or $intent.Provider -cne $Provider -or $receipt.ImageKey -cne $ImageKey -or $intent.ImageKey -cne $ImageKey -or
        $receipt.IntentId -cne $intent.IntentId -or $receipt.RunId -cne $intent.RunId -or $intent.ScopeId -cne $run.scopeId -or $intent.Tag -cne $tag -or
        $receipt.OwnsTag -isnot [bool] -or $receipt.ImageId -cnotmatch '^sha256:[a-f0-9]{64}$' -or
        ($receipt.OwnsTag -and $receipt.Image -cne $tag) -or (-not $receipt.OwnsTag -and $receipt.Image -cne $receipt.ImageId) -or
        $receipt.IntentSha256 -cne (Get-FileHash $intentPath).Hash.ToLowerInvariant()) { throw 'OWNED_HOST_TOOL_IMAGE_RECEIPT_DRIFT' }
    $observed=Get-LabOwnedHostImageObservation -StateRoot $StateRoot -Provider $Provider -Image $receipt.Image
    if (-not $observed -or $observed.Id -cne $receipt.ImageId -or
        $observed.Config.Labels.'sql-server-lab.container-tool.image-key' -cne $ImageKey -or $observed.Config.Labels.'sql-server-lab.container-tool.ids' -cne 'sqlpackage' -or
        ($receipt.OwnsTag -and ($observed.Config.Labels.'sql-server-lab.owned-host-policy-id' -cne $policy.PolicyId -or
            $observed.Config.Labels.'sql-server-lab.owned-host-root-scope-id' -cne $policy.RootScopeId -or $observed.Config.Labels.'sql-server-lab.owned-host-intent-id' -cne $intent.IntentId))) {
        throw 'OWNED_HOST_TOOL_IMAGE_RECEIPT_DRIFT'
    }
    return $receipt
}

function Remove-LabOwnedHostToolImage {
    param([string]$StateRoot,[string]$Provider,[string]$ImageKey)
    $receipt=Get-LabOwnedHostToolImageReceipt -StateRoot $StateRoot -Provider $Provider -ImageKey $ImageKey
    if (-not $receipt.OwnsTag) { return [pscustomobject]@{Status='PRESERVED_IMMUTABLE_REFERENCE';Removed=$false} }
    $result=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments @('image','rm','--no-prune',$receipt.Image)
    if ($result.ExitCode -ne 0 -or (Get-LabOwnedHostImageObservation -StateRoot $StateRoot -Provider $Provider -Image $receipt.Image)) { throw 'OWNED_HOST_TOOL_IMAGE_CLEANUP_UNCONFIRMED' }
    return [pscustomobject]@{Status='REMOVED_OWN_TAG';Removed=$true}
}

function Invoke-LabOwnedHostToolImageBuild {
    param([Parameter(Mandatory)]$ImagePlan,[Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$RunId)
    $policy=Get-LabOwnedHostRunPolicy -RunId $RunId -StateRoot $StateRoot
    $run=Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    $provider=[string]$ImagePlan.Provider
    if (-not $policy -or $provider -cnotin @('docker','podman') -or $ImagePlan.ImageKey -cnotmatch '^[a-f0-9]{64}$') { throw 'OWNED_HOST_TOOL_IMAGE_CONTEXT_INVALID' }
    return Invoke-LabArtifactStoreLock -StateRoot $StateRoot -ScriptBlock {
        $directory=Join-Path $policy.StateRoot 'owned-host-tool-images'
        $null=Assert-LabOwnedHostPath $directory
        if (-not (Test-Path $directory)) { $null=New-Item -Path $directory -ItemType Directory -ErrorAction Stop }
        $key=$provider+'-'+$ImagePlan.ImageKey
        $receiptPath=Join-Path $directory ($key+'.created.json')
        if (Test-Path -LiteralPath $receiptPath) {
            $receipt=Get-LabOwnedHostToolImageReceipt -StateRoot $StateRoot -Provider $provider -ImageKey $ImagePlan.ImageKey
            $readyPath=Join-Path $directory ($key+'.ready.json')
            if (-not (Test-Path $readyPath)) { throw 'OWNED_HOST_TOOL_IMAGE_RECOVERY_REQUIRED' }
            $ready=Read-LabOwnedHostRecord $readyPath
            Assert-LabOwnedHostProperties $ready @('ContractVersion','PolicyId','ImageKey','Provider','ReceiptSha256')
            if ($ready.ContractVersion -cne 'SqlServerLab.OwnedHostToolImageReady/1.0' -or $ready.PolicyId -cne $policy.PolicyId -or
                $ready.ImageKey -cne $ImagePlan.ImageKey -or $ready.Provider -cne $provider -or $ready.ReceiptSha256 -cne (Get-FileHash $receiptPath).Hash.ToLowerInvariant()) {
                throw 'OWNED_HOST_TOOL_IMAGE_READY_DRIFT'
            }
            $observed=Get-LabOwnedHostImageObservation -StateRoot $StateRoot -Provider $provider -Image $receipt.Image
            if (-not $observed -or $receipt.PolicyId -cne $policy.PolicyId -or $receipt.ImageKey -cne $ImagePlan.ImageKey -or
                $observed.Id -cne $receipt.ImageId -or $observed.Config.Labels.'sql-server-lab.container-tool.image-key' -cne $ImagePlan.ImageKey) {
                throw 'OWNED_HOST_TOOL_IMAGE_RECEIPT_DRIFT'
            }
            $reused=$true
        } else {
            $existing=Get-LabOwnedHostImageObservation -StateRoot $StateRoot -Provider $provider -Image $ImagePlan.Image
            $intentId=New-LabGuid
            $ownedTag='sql-server-lab/owned-tool:'+ $policy.PolicyId.Replace('-','')+'-'+$ImagePlan.ImageKey.Substring(0,24)+'-'+$provider
            $intent=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.OwnedHostToolImageIntent/1.0';PolicyId=$policy.PolicyId;RootScopeId=$policy.RootScopeId
                IntentId=$intentId;Provider=$provider;RunId=$RunId;ScopeId=$run.scopeId;ImageKey=$ImagePlan.ImageKey;Tag=$ownedTag}
            $intentPath=Join-Path $directory ($key+'.intent.json')
            Write-LabOwnedHostRecordExclusive -Path $intentPath -Record $intent
            $reused=$existing -and $existing.Config.Labels.'sql-server-lab.container-tool.image-key' -ceq $ImagePlan.ImageKey -and
                $existing.Config.Labels.'sql-server-lab.container-tool.ids' -ceq 'sqlpackage'
            if ($reused) {
                # Reference the immutable ID; never depend on a shared mutable tag.
                $observed=$existing;$image=[string]$existing.Id;$ownsTag=$false
            } else {
                foreach ($prerequisite in @($ImagePlan.BaseImage,$ImagePlan.ExtractorImage)) {
                    if ([string]$prerequisite -cnotmatch '@sha256:[a-f0-9]{64}$' -or
                        -not (Get-LabOwnedHostImageObservation -StateRoot $StateRoot -Provider $provider -Image $prerequisite)) {
                        throw 'OWNED_HOST_IMMUTABLE_BUILD_PREREQUISITE_REQUIRED'
                    }
                }
                $tags=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $provider -Arguments @('image','ls','--format','{{.Repository}}:{{.Tag}}')
                $normalizedTags = @($tags.Stdout -split '\r?\n' | ForEach-Object { $_ -creplace '^localhost/', '' })
                if ($tags.ExitCode -ne 0 -or $ownedTag -cin $normalizedTags) { throw 'OWNED_HOST_TOOL_IMAGE_TAG_ABSENCE_UNVERIFIABLE' }
                $buildArguments=@('build','--pull=false','--file',[string]$ImagePlan.Containerfile,'--tag',$ownedTag,
                    '--label',('sql-server-lab.owned-host-policy-id='+$policy.PolicyId),'--label',('sql-server-lab.owned-host-root-scope-id='+$policy.RootScopeId),
                    '--label',('sql-server-lab.owned-host-intent-id='+$intentId),
                    '--build-arg',('BASE_IMAGE='+$ImagePlan.BaseImage),'--build-arg',('EXTRACTOR_IMAGE='+$ImagePlan.ExtractorImage),
                    '--build-arg',('SQLPACKAGE_ARCHIVE_URL='+$ImagePlan.SqlPackageArchiveUrl),'--build-arg',('SQLPACKAGE_ARCHIVE_SHA256='+$ImagePlan.SqlPackageArchiveSha256),
                    '--build-arg',('SQLPACKAGE_VERSION='+$ImagePlan.RuntimeVersion),'--build-arg',('LIBUNWIND_DEB_URL='+$ImagePlan.LibunwindDebUrl),
                    '--build-arg',('LIBUNWIND_DEB_SHA256='+$ImagePlan.LibunwindDebSha256),'--build-arg',('LIBUNWIND_DEB_VERSION='+$ImagePlan.LibunwindDebVersion),
                    '--build-arg',('CONTENT_ID='+$ImagePlan.ImageKey),[string]$ImagePlan.RecipeRoot)
                $buildError=$null;$built=$null
                try { $built=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $provider -Arguments $buildArguments -TimeoutSeconds 1800 }
                catch { $buildError=$_ }
                $observed=Get-LabOwnedHostImageObservation -StateRoot $StateRoot -Provider $provider -Image $ownedTag
                if (-not $observed) { throw 'OWNED_HOST_TOOL_IMAGE_BUILD_RECOVERY_REQUIRED' }
                if ($observed.Config.Labels.'sql-server-lab.owned-host-policy-id' -cne $policy.PolicyId -or
                    $observed.Config.Labels.'sql-server-lab.owned-host-root-scope-id' -cne $policy.RootScopeId -or
                    $observed.Config.Labels.'sql-server-lab.owned-host-intent-id' -cne $intentId -or
                    $observed.Config.Labels.'sql-server-lab.container-tool.image-key' -cne $ImagePlan.ImageKey -or
                    $observed.Config.Labels.'sql-server-lab.container-tool.ids' -cne 'sqlpackage') { throw 'OWNED_HOST_TOOL_IMAGE_BUILD_BINDING_DRIFT' }
                $image=$ownedTag;$ownsTag=$true
                # Creation custody is durable before the version probe. A
                # failure can remove only this tag after complete CID cleanup.
                $receipt=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.OwnedHostToolImageReceipt/1.0';PolicyId=$policy.PolicyId;RootScopeId=$policy.RootScopeId
                    IntentId=$intentId;Provider=$provider;RunId=$RunId;ImageKey=$ImagePlan.ImageKey;Image=$image;ImageId=[string]$observed.Id
                    OwnsTag=$true;IntentSha256=(Get-FileHash $intentPath).Hash.ToLowerInvariant()}
                Write-LabOwnedHostRecordExclusive -Path $receiptPath -Record $receipt
                try {
                    if ($buildError) { throw $buildError }
                    if (-not $built -or $built.ExitCode -ne 0) { throw 'OWNED_HOST_TOOL_IMAGE_BUILD_RECOVERY_REQUIRED' }
                    $probe=Invoke-LabOwnedHostEphemeralContainer -StateRoot $StateRoot -RunId $RunId -ScopeId $run.scopeId -Provider $provider `
                        -ContainerArguments @('--network','none','--entrypoint','/opt/sql-server-lab/tools/sqlpackage/sqlpackage',[string]$observed.Id,'/Version')
                    if ([string]$probe -notmatch [regex]::Escape([string]$ImagePlan.RuntimeVersion)) { throw 'OWNED_HOST_TOOL_IMAGE_PROBE_FAILED' }
                } catch {
                    $failure=$_
                    try { $null=Remove-LabOwnedHostToolImage -StateRoot $StateRoot -Provider $provider -ImageKey $ImagePlan.ImageKey }
                    catch { throw 'OWNED_HOST_TOOL_IMAGE_COMPENSATION_RECOVERY_REQUIRED' }
                    throw $failure
                }
            }
            $receipt=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.OwnedHostToolImageReceipt/1.0';PolicyId=$policy.PolicyId;RootScopeId=$policy.RootScopeId
                IntentId=$intentId;Provider=$provider;RunId=$RunId;ImageKey=$ImagePlan.ImageKey;Image=$image;ImageId=[string]$observed.Id
                OwnsTag=$ownsTag;IntentSha256=(Get-FileHash $intentPath).Hash.ToLowerInvariant()}
            if (-not (Test-Path $receiptPath)) { Write-LabOwnedHostRecordExclusive -Path $receiptPath -Record $receipt }
            Write-LabOwnedHostRecordExclusive -Path (Join-Path $directory ($key+'.ready.json')) -Record ([pscustomobject]@{
                ContractVersion='SqlServerLab.OwnedHostToolImageReady/1.0';PolicyId=$policy.PolicyId;ImageKey=$ImagePlan.ImageKey;Provider=$provider;ReceiptSha256=(Get-FileHash $receiptPath).Hash.ToLowerInvariant()})
        }
        $refPath=Join-Path $directory ($key+'-'+$RunId+'.reference.json')
        if (-not (Test-Path $refPath)) { Write-LabOwnedHostRecordExclusive -Path $refPath -Record ([pscustomobject]@{
            ContractVersion='SqlServerLab.OwnedHostToolImageReference/1.0';PolicyId=$policy.PolicyId;RunId=$RunId;ImageKey=$ImagePlan.ImageKey;Provider=$provider;ReceiptSha256=(Get-FileHash $receiptPath).Hash.ToLowerInvariant()}) }
        $reference = Read-LabOwnedHostRecord $refPath
        Assert-LabOwnedHostProperties $reference @('ContractVersion','PolicyId','RunId','ImageKey','Provider','ReceiptSha256')
        if ($reference.ContractVersion -cne 'SqlServerLab.OwnedHostToolImageReference/1.0' -or
            $reference.PolicyId -cne $policy.PolicyId -or $reference.RunId -cne $RunId -or
            $reference.ImageKey -cne $ImagePlan.ImageKey -or $reference.Provider -cne $provider -or
            $reference.ReceiptSha256 -cne (Get-FileHash $receiptPath).Hash.ToLowerInvariant()) { throw 'OWNED_HOST_TOOL_IMAGE_REFERENCE_DRIFT' }
        $publicReceipt=[pscustomobject]@{contract=[pscustomobject]@{name='SqlServerLab.ContainerToolImageReceipt';version='1.0'}
            imageKey=$ImagePlan.ImageKey;provider=$provider;image=$receipt.Image;localImageId=$receipt.ImageId;baseImageDigest=$ImagePlan.BaseImageDigest
            recipeVersion=$ImagePlan.RecipeVersion;softwarePlanKeys=@($ImagePlan.SoftwarePlanKeys);toolIds=@($ImagePlan.ToolIds);runtimeVersion=$ImagePlan.RuntimeVersion
            contextEvidence=@($ImagePlan.ContextEvidence);status='IMAGE_READY';retention='owned-root-explicit-terminal-removal';builtAt=Get-LabTimestamp}
        Write-LabArtifactJsonAtomic -Path (Get-LabContainerToolImageReceiptPath -ImageKey $ImagePlan.ImageKey -Provider $provider -StateRoot $StateRoot) -InputObject $publicReceipt
        return [pscustomobject]@{Contract=[pscustomobject]@{Name='SqlServerLab.ContainerToolImageArtifact';Version='1.0'};Provider=$provider
            Image=$receipt.Image;ImageKey=$ImagePlan.ImageKey;SoftwarePlanKeys=@($ImagePlan.SoftwarePlanKeys);LocalImageId=$receipt.ImageId;Reused=[bool]$reused;Receipt=$publicReceipt}
    }
}

function Assert-LabOwnedHostContainerCreateInputs {
    param([string]$StateRoot,[string]$Provider,[string[]]$Arguments)
    $index=1
    while ($index -lt $Arguments.Count -and $Arguments[$index].StartsWith('-')) {
        $option=$Arguments[$index++]
        if ($option -cin @('-d','--detach','--read-only','--init','-i','--interactive','-t','--tty')) { continue }
        if ($option -cnotin @('--name','--hostname','--label','--network','--ip','--publish','-p','--env','-e',
                '--cpus','--memory','--memory-swap','--shm-size','--user','-u','--entrypoint','--restart','--volume','-v',
                '--health-cmd','--health-interval','--health-timeout','--health-retries','--health-start-period','--ulimit')) {
            throw 'OWNED_HOST_CREATE_OPTION_UNSUPPORTED'
        }
        if ($index -ge $Arguments.Count) { throw 'OWNED_HOST_CREATE_OPTION_INCOMPLETE' }
        $value=$Arguments[$index++]
        if ($option -ceq '--network' -and $value -cin @('host','container','bridge')) { throw 'OWNED_HOST_SHARED_NETWORK_MODE_FORBIDDEN' }
        if ($option -cin @('--volume','-v')) {
            # Named volumes need their own original create receipt, including
            # retained-store use. Host writes remain inside this fresh root.
            if ($value -cmatch '^(?<source>[A-Za-z0-9][A-Za-z0-9_.-]{0,254}):/(?<target>[^:]+)(?::(?<mode>ro|rw|U(?:,(?:ro|rw))?))?$') {
                # Podman's ownership adjustment is restricted to receipt-bound named volumes.
                if ($Matches['mode'] -cin @('U','U,ro','U,rw') -and $Provider -cne 'podman') { throw 'OWNED_HOST_MOUNT_SCOPE_UNSUPPORTED' }
                $null=Get-LabOwnedHostVolumeReceipt -StateRoot $StateRoot -Provider $Provider -VolumeName $Matches['source']
            } elseif ($value -cmatch '^(?<source>[A-Za-z]:[\\/][^:]+):/(?<target>[^:]+)(?::(?<mode>ro|rw))?$') {
                $path=Assert-LabOwnedHostPath $Matches['source'];$mode=$Matches['mode']
                $relative=[IO.Path]::GetRelativePath($StateRoot,$path)
                if ($mode -cne 'ro' -and ([IO.Path]::IsPathRooted($relative) -or $relative -ceq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar))) {
                    throw 'OWNED_HOST_BIND_WRITE_OUTSIDE_ROOT'
                }
            } else { throw 'OWNED_HOST_MOUNT_SCOPE_UNSUPPORTED' }
        }
    }
    if ($index -ge $Arguments.Count -or $Arguments[$index] -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'OWNED_HOST_IMMUTABLE_CONTAINER_IMAGE_REQUIRED' }
    $observed=Get-LabOwnedHostImageObservation -StateRoot $StateRoot -Provider $Provider -Image $Arguments[$index]
    if (-not $observed -or $observed.Id -cne $Arguments[$index]) { throw 'OWNED_HOST_CONTAINER_IMAGE_UNVERIFIABLE' }
}

function Assert-LabOwnedHostCommandScope {
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string[]]$Arguments)
    $command=$Arguments[0]
    if ($command -cin @('inspect','ps','info','version','logs','port','images')) { return }
    if ($command -ceq 'machine' -and $Arguments[1] -ceq 'list') { return }
    if ($command -ceq 'network' -and $Arguments[1] -cin @('inspect','ls')) { return }
    if ($command -ceq 'image' -and $Arguments[1] -cin @('inspect','ls')) { return }
    if ($command -ceq 'volume' -and $Arguments[1] -cin @('inspect','ls')) { return }
    if ($command -ceq 'cp' -and $Arguments.Count -eq 3) {
        $remote=@($Arguments[1..2]|Where-Object {$_ -cmatch '^[a-f0-9]{64}:'})
        $local=@($Arguments[1..2]|Where-Object {$_ -cnotmatch '^[a-f0-9]{64}:'})
        if ($remote.Count -ne 1 -or $local.Count -ne 1) {throw 'OWNED_HOST_COPY_SCOPE_INVALID'}
        $path=Assert-LabOwnedHostPath $local[0]
        $relative=[IO.Path]::GetRelativePath($StateRoot,$path)
        if ([IO.Path]::IsPathRooted($relative) -or $relative -ceq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar)) {throw 'OWNED_HOST_COPY_PATH_OUTSIDE_ROOT'}
        $null=Resolve-LabOwnedHostContainerEffect -StateRoot $StateRoot -Provider $Provider -ContainerIdOrName $remote[0].Substring(0,64)
        return
    }
    if ($command -cin @('start','stop','rm','exec','wait')) {
        $index=1
        while ($index -lt $Arguments.Count -and $Arguments[$index].StartsWith('-')) {
            $option=$Arguments[$index++]
            if ($option -cin @('-t','--time','-u','--user','-e','--env','-w','--workdir')) {$index++;continue}
            if ($option -cin @('-i','--interactive','-t','--tty','--attach','-a','-f','--force')) {continue}
            throw 'OWNED_HOST_CONTAINER_OPTION_UNSUPPORTED'
        }
        # -t is a boolean only for exec; stop's -t consumes the timeout.
        if ($command -ceq 'exec') {
            $index=1
            while ($index -lt $Arguments.Count -and $Arguments[$index].StartsWith('-')) {
                $option=$Arguments[$index++]
                if ($option -cin @('-u','--user','-e','--env','-w','--workdir')) {$index++;continue}
                if ($option -cin @('-i','--interactive','-t','--tty')) {continue}
                throw 'OWNED_HOST_CONTAINER_OPTION_UNSUPPORTED'
            }
        }
        if ($index -ge $Arguments.Count -or $Arguments[$index] -cnotmatch '^[a-f0-9]{64}$' -or
            ($command -cne 'exec' -and $index -ne $Arguments.Count-1)) { throw 'OWNED_HOST_FULL_CID_REQUIRED' }
        $cid=$Arguments[$index]
        $inspected=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments @('inspect',$cid)
        if ($inspected.ExitCode -ne 0) { throw 'OWNED_HOST_CONTAINER_INSPECT_FAILED' }
        $items=@($inspected.Stdout|ConvertFrom-Json -Depth 32 -ErrorAction Stop)
        if ($items.Count -ne 1) { throw 'OWNED_HOST_CONTAINER_AMBIGUOUS' }
        Assert-LabOwnedHostContainerEffect -StateRoot $StateRoot -RunId ([string]$items[0].Config.Labels.'sql-server-lab.run-id') -Provider $Provider -ContainerId $cid
        return
    }
    if ($command -cin @('create','run') -or ($command -ceq 'volume' -and $Arguments[1] -ceq 'create') -or $command -ceq 'build') {
        $labels=@{};$name=$null;$tag=$null
        for ($index=1;$index -lt $Arguments.Count;$index++) {
            if ($Arguments[$index] -ceq '--label') {
                if (++$index -ge $Arguments.Count) {throw 'OWNED_HOST_CREATE_LABEL_INVALID'}
                $pair=$Arguments[$index] -split '=',2
                if ($pair.Count -ne 2 -or $labels.ContainsKey($pair[0])) {throw 'OWNED_HOST_CREATE_LABEL_INVALID'}
                $labels[$pair[0]]=$pair[1]
            } elseif ($Arguments[$index] -ceq '--name') {$name=$Arguments[++$index]}
            elseif ($Arguments[$index] -ceq '--tag') {$tag=$Arguments[++$index]}
        }
        $policy=Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required
        $intentId=[string]$labels.'sql-server-lab.owned-host-intent-id'
        Assert-LabOwnedHostGuid $intentId
        if ($labels.'sql-server-lab.owned-host-policy-id' -cne $policy.PolicyId -or
            $labels.'sql-server-lab.owned-host-root-scope-id' -cne $policy.RootScopeId) { throw 'OWNED_HOST_CREATE_POLICY_DRIFT' }
        if ($command -ceq 'build') {
            $intents=@(Get-ChildItem -LiteralPath (Join-Path $policy.StateRoot 'owned-host-tool-images') -Filter ($Provider+'-*.intent.json') -File)
            if ($intents.Count -gt 128) {throw 'OWNED_HOST_IMAGE_INTENT_LIMIT'}
            $matches=@($intents|ForEach-Object {Read-LabOwnedHostRecord $_.FullName}|Where-Object {$_.IntentId -ceq $intentId})
            if ($matches.Count -ne 1 -or $matches[0].PolicyId -cne $policy.PolicyId -or $matches[0].Tag -cne $tag -or
                $matches[0].Provider -cne $Provider) {throw 'OWNED_HOST_IMAGE_BUILD_INTENT_REQUIRED'}
            $intent = $matches[0]
            Assert-LabOwnedHostProperties $intent @('ContractVersion','PolicyId','RootScopeId','IntentId','Provider','RunId','ScopeId','ImageKey','Tag')
            $null=Get-LabOwnedHostRunPolicy -StateRoot $StateRoot -RunId $intent.RunId
            $run=Get-LabRunState -StateRoot $StateRoot -RunId $intent.RunId
            if ($intent.ContractVersion -cne 'SqlServerLab.OwnedHostToolImageIntent/1.0' -or
                $intent.RootScopeId -cne $policy.RootScopeId -or $intent.ScopeId -cne $run.scopeId -or
                $intent.ImageKey -cnotmatch '^[a-f0-9]{64}$' -or
                ('CONTENT_ID='+$intent.ImageKey) -cnotin $Arguments -or
                $tag -cne ('sql-server-lab/owned-tool:'+$policy.PolicyId.Replace('-','')+'-'+$intent.ImageKey.Substring(0,24)+'-'+$Provider)) {
                throw 'OWNED_HOST_IMAGE_BUILD_INTENT_REQUIRED'
            }
            return
        }
        $runId=[string]$labels.'sql-server-lab.run-id'
        $null=Get-LabOwnedHostRunPolicy -StateRoot $StateRoot -RunId $runId
        if ($command -ceq 'volume') {
            $name=$Arguments[-1]
            $path=Join-Path (Join-Path $policy.StateRoot 'owned-host-volumes') ($Provider+'-'+$name+'.intent.json')
            $intent=Read-LabOwnedHostRecord $path
            if ($intent.VolumeName -cne $name) {throw 'OWNED_HOST_VOLUME_INTENT_DRIFT'}
        } else {
            $path=Join-Path (Join-Path (Join-Path (Join-Path $policy.StateRoot 'runs') $runId) 'owned-host-containers') ($intentId+'.intent.json')
            $intent=Read-LabOwnedHostRecord $path
            if ($intent.ContainerName -cne $name -or $intent.InstanceId -cne $labels.'sql-server-lab.instance-id') {throw 'OWNED_HOST_CONTAINER_INTENT_DRIFT'}
        }
        if ($intent.IntentId -cne $intentId -or $intent.PolicyId -cne $policy.PolicyId -or $intent.RootScopeId -cne $policy.RootScopeId -or $intent.Provider -cne $Provider -or
            $intent.RunId -cne $runId -or $intent.ScopeId -cne $labels.'sql-server-lab.scope-id') {throw 'OWNED_HOST_CREATE_INTENT_DRIFT'}
        if ($command -cin @('create','run')) { Assert-LabOwnedHostContainerCreateInputs -StateRoot $StateRoot -Provider $Provider -Arguments $Arguments }
        return
    }
    if ($command -ceq 'volume' -and $Arguments[1] -ceq 'rm' -and $Arguments.Count -eq 3) {
        $null=Get-LabOwnedHostVolumeReceipt -StateRoot $StateRoot -Provider $Provider -VolumeName $Arguments[2]
        return
    }
    if ($command -ceq 'image' -and $Arguments[1] -ceq 'rm' -and $Arguments.Count -eq 4 -and $Arguments[2] -ceq '--no-prune') {
        $policy=Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required
        $records=@(Get-ChildItem -LiteralPath (Join-Path $StateRoot 'owned-host-tool-images') -Filter ($Provider+'-*.created.json') -File)
        if ($records.Count -gt 128) {throw 'OWNED_HOST_IMAGE_RECEIPT_LIMIT'}
        $tag=$Arguments[3]
        $matches=@($records|ForEach-Object {Read-LabOwnedHostRecord $_.FullName}|Where-Object {$_.Image -ceq $tag -and $_.OwnsTag -eq $true})
        if ($matches.Count -ne 1 -or $matches[0].PolicyId -cne $policy.PolicyId) {throw 'OWNED_HOST_IMAGE_REMOVAL_RECEIPT_REQUIRED'}
        $receipt=Get-LabOwnedHostToolImageReceipt -StateRoot $StateRoot -Provider $Provider -ImageKey $matches[0].ImageKey
        $observed=Get-LabOwnedHostImageObservation -StateRoot $StateRoot -Provider $Provider -Image $tag
        if (-not $observed -or $observed.Id -cne $matches[0].ImageId -or
            $observed.Config.Labels.'sql-server-lab.owned-host-policy-id' -cne $policy.PolicyId -or
            $observed.Config.Labels.'sql-server-lab.owned-host-intent-id' -cne $matches[0].IntentId) {throw 'OWNED_HOST_IMAGE_REMOVAL_BINDING_DRIFT'}
        $refs=@(Get-ChildItem -LiteralPath (Join-Path $StateRoot 'owned-host-tool-images') -Filter ($Provider+'-'+$matches[0].ImageKey+'-*.reference.json') -File)
        foreach ($file in $refs) {
            $ref=Read-LabOwnedHostRecord $file.FullName
            Assert-LabOwnedHostProperties $ref @('ContractVersion','PolicyId','RunId','ImageKey','Provider','ReceiptSha256')
            $receiptPath=Join-Path (Join-Path $StateRoot 'owned-host-tool-images') ($Provider+'-'+$receipt.ImageKey+'.created.json')
            if ($ref.ContractVersion -cne 'SqlServerLab.OwnedHostToolImageReference/1.0' -or $ref.PolicyId -cne $policy.PolicyId -or
                $ref.Provider -cne $Provider -or $ref.ImageKey -cne $receipt.ImageKey -or $ref.ReceiptSha256 -cne (Get-FileHash $receiptPath).Hash.ToLowerInvariant()) {
                throw 'OWNED_HOST_TOOL_IMAGE_REFERENCE_DRIFT'
            }
            $null=Get-LabOwnedHostRunPolicy -StateRoot $StateRoot -RunId $ref.RunId
            $run=Get-LabRunState -RunId $ref.RunId -StateRoot $StateRoot
            if ($run.state -cnotin @('REMOVED','CLEANED_UP')) {throw 'OWNED_HOST_IMAGE_ACTIVE_RUN_REFERENCE'}
        }
        $attachments=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments @('ps','-a','--no-trunc','--filter',('ancestor='+$receipt.ImageId),'--format','{{.ID}}')
        if ($attachments.ExitCode -ne 0 -or $attachments.Stdout.Trim()) { throw 'OWNED_HOST_IMAGE_ATTACHED_OR_UNVERIFIABLE' }
        return
    }
    throw 'OWNED_HOST_EFFECT_UNSUPPORTED'
}

function Get-LabOwnedHostRuntimeScope {
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)
    $policy=Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required
    $pin=@($policy.RuntimePins|Where-Object {$_.Provider -ceq $Provider})[0]
    if (-not $pin) {throw 'OWNED_HOST_PROVIDER_NOT_SELECTED'}
    $format=if($Provider -ceq 'docker') {'{{json .}}'}else{'json'}
    $read=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments @('info','--format',$format)
    if ($read.ExitCode -ne 0) {throw 'OWNED_HOST_RUNTIME_INFO_UNVERIFIABLE'}
    $info=$read.Stdout|ConvertFrom-Json -Depth 32 -ErrorAction Stop
    $machineName=$null;$machineState='NOT_APPLICABLE';$machineCount=0;$rootless=$null
    if ($Provider -ceq 'docker') {
        $backend=if([string]$info.OperatingSystem -match '(?i)Docker Desktop'){'DOCKER_DESKTOP'}else{'DOCKER_ENGINE'}
        $endpointKind=Get-LabContainerRuntimeEndpointKind -Endpoint $pin.Endpoint
        $hostMode=Get-LabContainerRuntimeHostMode -HostPlatform windows -EndpointKind $endpointKind
        $engineVersion=[string]$info.ServerVersion;$driver=[string]$info.Driver;$runtimeRoot=[string]$info.DockerRootDir
    } else {
        $listed=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider $Provider -Arguments @('machine','list','--format','json')
        if ($listed.ExitCode -ne 0) {throw 'OWNED_HOST_LOCAL_MACHINE_UNVERIFIABLE'}
        $machines=@($listed.Stdout|ConvertFrom-Json -Depth 16 -ErrorAction Stop)
        if ($machines.Count -gt 64) {throw 'OWNED_HOST_LOCAL_MACHINE_INVENTORY_LIMIT'}
        $port=([uri]$pin.Endpoint).Port
        $matching=@($machines|Where-Object {$_.Running -eq $true -and [int]$_.Port -eq $port})
        if ($matching.Count -ne 1 -or [string]$matching[0].VMType -cnotin @('wsl','hyperv')) {throw 'OWNED_HOST_LOCAL_MACHINE_BINDING_UNVERIFIABLE'}
        $machineName=[string]$matching[0].Name;$machineState='RUNNING';$machineCount=$machines.Count
        $backend='PODMAN_MACHINE';$endpointKind=Get-LabContainerRuntimeEndpointKind -Endpoint $pin.Endpoint
        $hostMode=Get-LabContainerRuntimeHostMode -HostPlatform windows -EndpointKind $endpointKind -MachineType ([string]$matching[0].VMType)
        $engineVersion=[string]$info.Version.Version;$driver=[string]$info.Store.GraphDriverName;$runtimeRoot=[string]$info.Store.GraphRoot
        if($null -ne $info.Host.Security.Rootless){$rootless=[bool]$info.Host.Security.Rootless}
    }
    if (-not $engineVersion -or -not $driver -or $hostMode -cin @('UNKNOWN','REMOTE')) {throw 'OWNED_HOST_RUNTIME_INFO_INCOMPLETE'}
    # DisplayName is an explicit per-policy projection, never a discovered
    # default context/connection name or a physical engine-generation identity.
    $displayName='owned-policy-'+$policy.PolicyId
    $runtimeId=Get-LabContainerRuntimeScopeId -Provider $Provider -IdentityKey ($displayName+'|'+$pin.Endpoint+'|'+$backend)
    return [pscustomobject][ordered]@{
        ContractVersion='SqlServerLab.ContainerRuntimeScope/1.0';Provider=$Provider;Status='AVAILABLE';RuntimeId=$runtimeId
        Binding=[pscustomobject][ordered]@{DisplayName=$displayName;EndpointKind=$endpointKind;BackendKind=$backend;HostMode=$hostMode
            EngineVersion=$engineVersion;StorageDriver=$driver;Rootless=$rootless;SelectedBy='EXPLICIT_POLICY_PIN';MachineName=$machineName
            MachineState=$machineState;MachineCount=$machineCount;ConnectionCount=0}
        Ownership=[pscustomobject][ordered]@{Status='SHARED_EXTERNAL';MutationPolicy='REPORT_ONLY';CleanupPolicy='PRESERVE_RUNTIME'}
        PhysicalBacking=[pscustomobject][ordered]@{RuntimeNamespaceStatus=if($runtimeRoot){'DECLARED'}else{'UNAVAILABLE'};HostBackingStatus='UNVERIFIABLE';LabDataRelation='UNKNOWN';BackingStoreCount=0}
        AllowedActions=@('INSPECT','USE_LABELED_RESOURCES');BlockedActions=@('RELOCATE_RUNTIME_STORAGE','REMOVE_RUNTIME','CHANGE_DEFAULT_CONNECTION','CHANGE_RUNTIME_MODE','ADOPT_FOREIGN_RESOURCES')
        Issues=@('RUNTIME_OWNERSHIP_NOT_PROVEN','RUNTIME_HOST_BACKING_UNVERIFIABLE')
        Summary=[pscustomobject][ordered]@{CanUseLabeledResources=$true;CanManageRuntime=$false;RequiresDedicatedOwnershipContract=$true}
    }
}

function Assert-LabOwnedHostContainerEffect {
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,[Parameter(Mandatory)][string]$ContainerId)
    $policy = Get-LabOwnedHostRunPolicy -RunId $RunId -StateRoot $StateRoot
    if (-not $policy) { return }
    if ($ContainerId -cnotmatch '^[a-f0-9]{64}$') { throw 'OWNED_HOST_FULL_CID_REQUIRED' }
    $directory = Join-Path (Join-Path (Join-Path $StateRoot 'runs') $RunId) 'owned-host-containers'
    $null = Assert-LabOwnedHostPath $directory
    $files = @(Get-ChildItem -LiteralPath $directory -Filter '*.created.json' -File -ErrorAction Stop)
    if ($files.Count -gt 128) { throw 'OWNED_HOST_CONTAINER_RECEIPT_LIMIT' }
    $matches = @()
    foreach ($file in $files) {
        $receipt = Read-LabOwnedHostRecord $file.FullName
        Assert-LabOwnedHostProperties $receipt @('ContractVersion','IntentId','PolicyId','RootScopeId','RunId','ScopeId','InstanceId','Provider','ContainerId','IntentSha256')
        if ($receipt.ContainerId -ceq $ContainerId -and $receipt.Provider -ceq $Provider) { $matches += $receipt }
    }
    if ($matches.Count -ne 1) { throw 'OWNED_HOST_CONTAINER_RECEIPT_MISSING' }
    $receipt = $matches[0]
    Assert-LabOwnedHostGuid $receipt.IntentId
    $intentPath = Join-Path $directory ($receipt.IntentId+'.intent.json')
    $intent = Read-LabOwnedHostRecord $intentPath
    Assert-LabOwnedHostProperties $intent @('ContractVersion','IntentId','PolicyId','RootScopeId','RunId','ScopeId','WorkflowOperationId','InstanceId','Provider','ContainerName')
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ($receipt.ContractVersion -cne 'SqlServerLab.OwnedHostContainerReceipt/1.0' -or
        $intent.ContractVersion -cne 'SqlServerLab.OwnedHostContainerIntent/1.0' -or
        $receipt.PolicyId -cne $policy.PolicyId -or $receipt.RootScopeId -cne $policy.RootScopeId -or
        $intent.PolicyId -cne $policy.PolicyId -or $intent.RootScopeId -cne $policy.RootScopeId -or
        $receipt.RunId -cne $RunId -or $intent.RunId -cne $RunId -or $receipt.ScopeId -cne $run.scopeId -or
        $intent.ScopeId -cne $run.scopeId -or $intent.WorkflowOperationId -cne $run.metadata.workflowOperationId -or
        $intent.InstanceId -cne $receipt.InstanceId -or $intent.Provider -cne $Provider -or
        $receipt.IntentSha256 -cne (Get-FileHash -LiteralPath $intentPath -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'OWNED_HOST_CONTAINER_RECEIPT_DRIFT'
    }
    $null = Get-LabOwnedHostContainerObservation -StateRoot $StateRoot -Intent $intent -ContainerIdOrName $ContainerId
}
