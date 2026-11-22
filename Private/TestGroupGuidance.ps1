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

function Assert-LabTestGroupExportPaths {
    param([string]$Directory)

    foreach ($name in @('TestUmgebung.registry.json','TestUmgebung.schema.json','TestUmgebung.prompt.md','TestUmgebung.json','TestUmgebung.env','TestUmgebung.md')) {
        $path = Join-Path $Directory $name
        if (-not (Test-LabPathWithinRoot -Root $Directory -Path $path).Valid -or (Test-Path -LiteralPath $path -PathType Container)) {
            throw 'TEST_GROUP_EXPORT_PATH_UNSAFE'
        }
    }
}

function Get-LabTestGroupWindowsArtifact {
    param([string]$StateRoot, [string]$ArtifactId, [switch]$VerifyIntegrity)

    if (-not (Test-HyperVAvailable).Available) { return }
    foreach ($artifact in @(Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot -SkipIntegrityCheck:(-not $VerifyIntegrity))) {
        if (-not $artifact -or $artifact.artifactState -cne 'SQL_PREPARED_SEALED' -or
            [string]$artifact.artifactId -cnotmatch '^hyperv-[a-z0-9-]{1,96}-[a-f0-9]{64}$' -or
            [string]$artifact.sql.version -cnotin @('2019','2022','2025') -or
            -not (Test-HyperVImageArtifactChildValidationEligibility -Artifact $artifact).Eligible -or
            -not (Test-HyperVImageArtifactEvaluationEligibility -Artifact $artifact -MinimumEvaluationDaysRemaining 0).Eligible) { continue }
        $match = [regex]::Match([string]$artifact.sql.build, '^(?<version>[0-9]{1,4}(?:\.[0-9]{1,6}){3})(?: \(\([A-Za-z0-9_. -]+\)\.[0-9]{6}-[0-9]{4}\))?$')
        if (-not $match.Success) { continue }
        $version = [version]$match.Groups['version'].Value
        $major = Get-HyperVSqlMajorVersionFromVersion -SqlVersion ([string]$artifact.sql.version)
        # SQL Setup FileVersion can use year + major*10 instead of product major + minor.
        if ($version.Major -eq [int]$artifact.sql.version -and $version.Minor -eq ($major * 10)) {
            $version = [version]::new($major, 0, $version.Build, $version.Revision)
        }
        if ($version.Major -ne $major) { continue }
        [pscustomobject]@{ ArtifactId=[string]$artifact.artifactId; SqlVersion=[string]$artifact.sql.version; Build=$version.ToString() }
    }
}

function Get-LabTestGroupManagementPlan {
    param([ValidateSet('CreateWindows','Repair','Remove')][string]$Operation, [string]$ArtifactId)

    $root = Get-LabStateRoot
    if ($Operation -eq 'CreateWindows' -and -not $ArtifactId) {
        return [pscustomobject]@{ Operation=$Operation; Artifacts=@(Get-LabTestGroupWindowsArtifact -StateRoot $root) }
    }
    if (($Operation -eq 'CreateWindows' -and $ArtifactId -cnotmatch '^hyperv-[a-z0-9-]{1,96}-[a-f0-9]{64}$') -or
        ($Operation -ne 'CreateWindows' -and $ArtifactId)) { throw 'TEST_GROUP_MANAGEMENT_TARGET_INVALID' }
    $directory = Get-LabTestEnvironmentExportDirectory
    $lock = Enter-LabTestGroupLock -OutputDirectory $directory
    try {
        Assert-LabTestGroupExportPaths -Directory $directory
        if ($Operation -eq 'CreateWindows') {
            $image = @(Get-LabTestGroupWindowsArtifact -StateRoot $root -ArtifactId $ArtifactId)
            if ($image.Count -ne 1 -or $image[0].ArtifactId -cne $ArtifactId) { throw 'TEST_GROUP_WINDOWS_IMAGE_UNAVAILABLE' }
            $image = $image[0]
            $build = @(Get-SqlServerBuilds -VersionId $image.SqlVersion | Where-Object build -EQ $image.Build | Select-Object -First 1)
            $patch = if ($build.Count -and $build[0].cu -match '^CU[1-9][0-9]*$') { ([string]$build[0].cu).ToLowerInvariant() } else { "build-$($image.Build)" }
            $key = ConvertTo-LabTestEnvironmentKey -Platform windows -SqlVersion $image.SqlVersion -Patch $patch
            $registry = Get-LabTestEnvironmentRegistry -OutputDirectory $directory
            if ($key -in @($registry.environments | ForEach-Object { $_.key })) { throw 'TEST_GROUP_WINDOWS_TARGET_ALREADY_REGISTERED' }
            $registryPath = Get-LabTestEnvironmentRegistryPath -OutputDirectory $directory
            $registryHash = if (Test-Path -LiteralPath $registryPath -PathType Leaf) { (Get-FileHash -LiteralPath $registryPath).Hash } else { 'absent' }
            $binding = @($Operation,$root,$directory,$registryHash,$ArtifactId,$image.SqlVersion,$image.Build,$key) | ConvertTo-Json -Compress
            return [pscustomobject]@{
                Operation=$Operation; CanApply=$true; ArtifactId=$ArtifactId; SqlVersion=$image.SqlVersion; Build=$image.Build
                Patch=$patch; Key=$key; PlanKey=(Get-LabWorkflowHash -Text $binding -Length 64)
            }
        }
        $view = Get-LabTestGroupPowerPlan -PowerAction Stop -StateRoot $root -OutputDirectory $directory
        $environmentGroups = Get-LabEnvironmentGroupsRegistry -StateRoot $root
        $cleanupHashes = [Collections.Generic.List[string]]::new()
        $members = @(foreach ($member in $view.Members) {
            $safe = $member.Change -ne 'BLOCKED'
            if ($safe) {
                try {
                    # Repair can stop or replace a member as well. Protect all group references.
                    Assert-LabEnvironmentGroupRunMutation -RunId $member.RunId -Action Remove -Registry $environmentGroups
                    Assert-LabWindowsPoolMutationAllowed -RunId $member.RunId -StateRoot $root
                    if ($Operation -eq 'Remove') {
                        $runDirectory = Join-Path $root "runs/$($member.RunId)"
                        $path = Join-Path $runDirectory 'cleanup-plan.json'
                        if (-not (Test-LabPathWithinRoot -Root $root -Path $path).Valid) { throw 'TEST_GROUP_CLEANUP_PATH_UNSAFE' }
                        $bytes = [IO.File]::ReadAllBytes($path)
                        $cleanup = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -Depth 20 -ErrorAction Stop
                        if ($cleanup.runId -cne $member.RunId -or $cleanup.scopeId -cne $member.ScopeId -or -not $cleanup.steps.Count) { throw 'TEST_GROUP_CLEANUP_BINDING' }
                        if (-not (Test-LabHyperVCleanupPlanProtection -Plan $cleanup -RunDir $runDirectory -ScopeId $member.ScopeId).Valid) { throw 'TEST_GROUP_CLEANUP_BINDING' }
                        $cleanupHashes.Add([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)))
                    }
                } catch { $safe = $false }
            }
            [pscustomobject]@{ Key=$member.Key; Target=$member.RegistrationLabel; Power=$member.Power; Verified=[bool]$safe }
        })
        $allowed = $view.CanApply -and @($members | Where-Object { -not $_.Verified }).Count -eq 0
        [pscustomobject]@{
            Operation=$Operation; CanApply=[bool]$allowed; Members=$members
            PlanKey=if ($allowed) { Get-LabWorkflowHash -Text ((@($Operation,$view.PlanKey) + $cleanupHashes.ToArray()) -join '|') -Length 64 }
        }
    } finally { Exit-LabTestGroupLock -Mutex $lock }
}

function Invoke-LabTestGroupManagementPlan {
    param([ValidateSet('CreateWindows','Repair','Remove')][string]$Operation, [string]$ArtifactId, [string]$ExpectedPlanKey)

    if ($ExpectedPlanKey -cnotmatch '^[a-f0-9]{64}$') { throw 'TEST_GROUP_MANAGEMENT_PREVIEW_REQUIRED' }
    if ($Operation -eq 'CreateWindows' -and -not $ArtifactId) { throw 'TEST_GROUP_MANAGEMENT_TARGET_INVALID' }
    $root = Get-LabStateRoot
    $directory = Get-LabTestEnvironmentExportDirectory
    $lock = Enter-LabTestGroupLock -OutputDirectory $directory
    $groupsLock = $null
    $runLocks = [Collections.Generic.List[object]]::new()
    try {
        if ($Operation -ne 'CreateWindows') {
            $groupsLock = Enter-LabEnvironmentGroupsLock -StateRoot $root
            $registry = Get-LabTestEnvironmentRegistry -OutputDirectory $directory
            foreach ($id in @($registry.environments | ForEach-Object { [string]$_.runId } | Sort-Object -Unique)) {
                $guid = [guid]::Empty
                if (-not [guid]::TryParseExact($id,'D',[ref]$guid) -or $guid.ToString('D') -cne $id) { throw 'TEST_GROUP_MANAGEMENT_MEMBER_UNVERIFIED' }
                $runLocks.Add((Enter-LabEnvironmentGroupRunResourceLock -RunId $id -StateRoot $root))
            }
        }
        $plan = Get-LabTestGroupManagementPlan -Operation $Operation -ArtifactId $ArtifactId
        if (-not $plan.CanApply -or $plan.PlanKey -cne $ExpectedPlanKey) { throw 'TEST_GROUP_MANAGEMENT_PREVIEW_CHANGED' }
        if ($Operation -eq 'CreateWindows') {
            $password = New-HyperVSqlUnattendedPassword
            $stage = 'IMAGE'
            try {
                $images = @(Get-LabTestGroupWindowsArtifact -ArtifactId $ArtifactId -StateRoot $root -VerifyIntegrity 3>$null 4>$null 5>$null 6>$null)
                if ($images.Count -ne 1 -or $images[0].ArtifactId -cne $ArtifactId -or
                    $images[0].SqlVersion -cne $plan.SqlVersion -or $images[0].Build -cne $plan.Build) {
                    throw 'TEST_GROUP_WINDOWS_IMAGE_CHANGED'
                }
                $stage = 'INTENT'
                $null = Register-LabTestEnvironmentIntent -Platform windows -SqlVersion $plan.SqlVersion -Patch $plan.Patch -InstanceId primary -Name $plan.Key -OutputDirectory $directory
                $stage = 'PENDING_EXPORT'
                $null = Export-SqlServerLabTestEnvironment -OutputDirectory $directory -StateRoot $root 3>$null 4>$null 5>$null 6>$null
                $stage = 'CLONE'
                $lab = New-HyperVLabEnvironment -ArtifactId $ArtifactId -LabName (Get-LabAutomatedTestEnvironmentDisplayName -Key $plan.Key) `
                    -InstanceId primary -MemoryStartupMB 4096 -ProcessorCount 4 -AutoStart on -StateRoot $root 3>$null 4>$null 5>$null 6>$null
                $stage = 'REGISTRATION'
                $null = Register-LabTestEnvironmentRun -RunId $lab.RunId -Platform windows -SqlVersion $plan.SqlVersion -Patch $plan.Patch -InstanceId primary -Name $plan.Key -OutputDirectory $directory
                $stage = 'PROVISION'
                Set-LabWindowsTestEnvironmentActivationIntent -RunId $lab.RunId -StateRoot $root
                $null = Invoke-HyperVLabUnattendedProvision -RunId $lab.RunId -AdministratorPassword $password -PasswordSource generated -StateRoot $root 3>$null 4>$null 5>$null 6>$null
                $stage = 'EXPORT'
                $export = Export-SqlServerLabTestEnvironment -OutputDirectory $directory -StateRoot $root 3>$null 4>$null 5>$null 6>$null
                $null = Sync-LabAutomatedTestEnvironmentConnectionCenter -StateRoot $root 3>$null 4>$null 5>$null 6>$null
                return [pscustomobject]@{ Status='REGISTERED'; Key=$plan.Key; GroupReady=($export.GroupStatus -ceq 'READY') }
            } catch { throw "TEST_GROUP_WINDOWS_CREATE_UNCONFIRMED: $stage" }
            finally { $password.Dispose() }
        }
        try {
            $arguments = @{Force=$true; Confirm=$false; StateRoot=$root; OutputDirectory=$directory; ErrorAction='Stop'}
            $result = if ($Operation -eq 'Remove') {
                Clear-SqlServerLabAutomatedTestEnvironment @arguments 3>$null 4>$null 5>$null 6>$null
            } else {
                Repair-SqlServerLabAutomatedTestEnvironment @arguments 3>$null 4>$null 5>$null 6>$null
            }
        } catch { throw 'TEST_GROUP_MANAGEMENT_UNCONFIRMED' }
        if ($Operation -eq 'Remove' -and $result.Status -ceq 'REMOVED') {
            return [pscustomobject]@{ Status='REMOVED'; Count=[int]$result.Removed }
        }
        if ($Operation -eq 'Repair' -and $result.Status -ceq 'READY') {
            return [pscustomobject]@{ Status='READY'; Count=$plan.Members.Count }
        }
        throw 'TEST_GROUP_MANAGEMENT_UNCONFIRMED'
    } finally {
        for ($i = $runLocks.Count - 1; $i -ge 0; $i--) { Exit-LabEnvironmentGroupRunResourceLock -Mutex $runLocks[$i] }
        if ($groupsLock) { Exit-LabEnvironmentGroupsLock -Mutex $groupsLock }
        Exit-LabTestGroupLock -Mutex $lock
    }
}

function Get-LabTestGroupLinuxCreatePlan {
    param([string]$Provider, [string]$SqlVersion, [string]$OutputDirectory, [string]$StateRoot, [string]$Patch = 'latest')

    $versions = @(Get-SqlServerVersions -Status SUPPORTED | Where-Object { $_.docker.image } |
        ForEach-Object { [string]$_.id } | Where-Object { $_ -cmatch '^20\d{2}$' } | Sort-Object -Unique)
    if (-not $Provider -and -not $SqlVersion) {
        $patches = [ordered]@{}
        foreach ($version in $versions) {
            $patches[$version] = @(Get-SqlServerBuilds -VersionId $version | Where-Object { $_.tag -and $_.cu -match '^CU[1-9][0-9]{0,5}$' } |
                ForEach-Object { ([string]$_.cu).ToLowerInvariant() } | Select-Object -Unique)
        }
        return [pscustomobject]@{ Versions=$versions; Patches=$patches }
    }
    if ($Provider -cnotin @('docker','podman') -or $SqlVersion -cnotin $versions) {
        throw 'TEST_GROUP_LINUX_CREATE_TARGET_INVALID'
    }
    if (-not $Patch) { $Patch = 'latest' }
    if ($Patch -cnotmatch '^(?:latest|cu[1-9][0-9]{0,5})$') { throw 'TEST_GROUP_LINUX_CREATE_PATCH_INVALID' }
    $versionId = if ($Patch -ceq 'latest') { $SqlVersion } else { "$SqlVersion-$($Patch.ToUpperInvariant())" }
    try { $image = Get-SqlServerDockerImage -VersionId $versionId -ErrorAction Stop }
    catch { throw 'TEST_GROUP_LINUX_CREATE_PATCH_UNAVAILABLE' }
    if ($image -cnotmatch '^mcr\.microsoft\.com/mssql/server:[A-Za-z0-9_.-]+$') { throw 'TEST_GROUP_LINUX_CREATE_PATCH_UNAVAILABLE' }
    $directory = Get-LabTestEnvironmentExportDirectory -OutputDirectory $OutputDirectory
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $lock = Enter-LabTestGroupLock -OutputDirectory $directory
    try {
        Assert-LabTestGroupExportPaths -Directory $directory
        $scope = Get-LabContainerRuntimeScope -Provider $Provider -StateRoot $StateRoot
        if ($scope.Status -cne 'AVAILABLE' -or -not $scope.RuntimeId) { throw 'TEST_GROUP_LINUX_CREATE_RUNTIME_UNAVAILABLE' }
        $registry = Get-LabTestEnvironmentRegistry -OutputDirectory $directory
        $registryPath = Get-LabTestEnvironmentRegistryPath -OutputDirectory $directory
        $registryHash = if (Test-Path -LiteralPath $registryPath -PathType Leaf) {
            (Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash
        } else { 'absent' }
        $name = if ($Patch -ceq 'latest') { "linux-$Provider-$SqlVersion" } else { "linux-$Provider-$SqlVersion-$Patch" }
        $initialKey = ConvertTo-LabTestEnvironmentKey -Platform linux -SqlVersion $SqlVersion -Patch $Patch -Name $name
        if (@($registry.environments | Where-Object {
            ($_.key -eq $initialKey -or $_.key -like "${initialKey}_*") -and -not $_.runId
        }).Count) { throw 'TEST_GROUP_LINUX_CREATE_PENDING' }
        $registeredKeys = @($registry.environments | ForEach-Object { [string]$_.key })
        $key = $initialKey
        $suffix = 2
        while ($key -in $registeredKeys) {
            $key = "${initialKey}_$suffix"
            $suffix++
        }
        $binding = [ordered]@{
            Directory=(Get-LabCanonicalResourceRoot -StateRoot $directory)
            StateRoot=(Get-LabCanonicalResourceRoot -StateRoot $StateRoot)
            RegistryHash=$registryHash; RuntimeId=$scope.RuntimeId; Provider=$Provider
            SqlVersion=$SqlVersion; Patch=$Patch; Image=$image; Key=$key
        }
        [pscustomobject]@{
            Provider=$Provider; SqlVersion=$SqlVersion; Patch=$Patch; Key=$key
            PlanKey=(Get-LabWorkflowHash -Text ($binding | ConvertTo-Json -Compress) -Length 64)
        }
    } finally { Exit-LabTestGroupLock -Mutex $lock }
}

function Invoke-LabTestGroupLinuxCreatePlan {
    param([string]$Provider, [string]$SqlVersion, [string]$ExpectedPlanKey, [string]$Patch = 'latest')

    if (-not $ExpectedPlanKey) { throw 'TEST_GROUP_LINUX_CREATE_PREVIEW_REQUIRED' }
    $directory = Get-LabTestEnvironmentExportDirectory
    $root = Get-LabStateRoot
    $lock = Enter-LabTestGroupLock -OutputDirectory $directory
    try {
        $plan = Get-LabTestGroupLinuxCreatePlan -Provider $Provider -SqlVersion $SqlVersion -Patch $Patch -OutputDirectory $directory -StateRoot $root
        if ($plan.PlanKey -cne $ExpectedPlanKey) { throw 'TEST_GROUP_LINUX_CREATE_PREVIEW_CHANGED' }
        $specification = [pscustomobject]@{ Platform='linux'; SqlVersion=$SqlVersion; Patch=$plan.Patch; Key=$plan.Key; InstanceId='primary' }
        try {
            $created = New-SqlServerLabAutomatedTestEnvironment -Specification @($specification) -Provider $Provider `
                -OutputDirectory $directory -StateRoot $root -ErrorAction Stop 3>$null 4>$null 5>$null 6>$null
        } catch { throw 'TEST_GROUP_LINUX_CREATE_UNCONFIRMED' }
        if (@($created.Errors).Count -or @($created.Environments).Count -ne 1) { throw 'TEST_GROUP_LINUX_CREATE_UNCONFIRMED' }
        $registry = Get-LabTestEnvironmentRegistry -OutputDirectory $directory
        $record = @($registry.environments | Where-Object key -CEQ $plan.Key)
        if ($record.Count -ne 1 -or -not $record[0].runId -or $record[0].runId -cne [string]$created.Environments[0].RunId -or
            $record[0].registrationState -cne 'REGISTERED') { throw 'TEST_GROUP_LINUX_CREATE_UNCONFIRMED' }
        [pscustomobject]@{ Status='REGISTERED'; Key=$plan.Key; SqlVersion=$SqlVersion; Provider=$Provider; GroupReady=($created.Status -ceq 'READY') }
    } finally { Exit-LabTestGroupLock -Mutex $lock }
}

function Invoke-LabTestGroupLinuxCreatePlanRequest {
    param([Collections.Specialized.NameValueCollection]$Query)

    if ($Query.Count -gt 0 -and ($Query.Count -notin @(2,3) -or
        @($Query.AllKeys | Where-Object { $_ -cnotin @('provider','sqlVersion','patch') }).Count -or
        @($Query.GetValues('provider')).Count -ne 1 -or @($Query.GetValues('sqlVersion')).Count -ne 1 -or
        ($Query.Count -eq 3 -and (@($Query.GetValues('patch')).Count -ne 1 -or [string]$Query['patch'] -cnotmatch '^(?:latest|cu[1-9][0-9]{0,5})$')) -or
        [string]$Query['provider'] -cnotin @('docker','podman') -or [string]$Query['sqlVersion'] -cnotmatch '^20\d{2}$')) {
        throw 'TEST_GROUP_LINUX_CREATE_TARGET_INVALID'
    }
    Get-LabTestGroupLinuxCreatePlan -Provider $Query['provider'] -SqlVersion $Query['sqlVersion'] -Patch $Query['patch']
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

function Get-LabTestGroupRegistrationLabel {
    param([Parameter(Mandatory)]$Entry)

    $platform = switch -CaseSensitive ([string]$Entry.platform) {
        'linux' { 'Linux' }
        'windows' { 'Windows' }
        default { 'Plattform unbekannt' }
    }
    $version = [string]$Entry.sqlVersion
    $patch = if ($Entry.PSObject.Properties['patch']) { [string]$Entry.patch } else { '' }
    $registrationState = if ($Entry.PSObject.Properties['registrationState']) { [string]$Entry.registrationState } else { '' }
    $versionLabel = if ($version -cmatch '^20[0-9]{2}$') { "SQL Server $version" } else { 'SQL-Version unbekannt' }
    $patchLabel = if ($patch -match '^(?:rtm|cu[1-9][0-9]{0,5})$') { $patch.ToUpperInvariant() }
        elseif ($patch -ceq 'latest') { 'Aktueller Patch laut Katalog' }
        elseif ($patch -cmatch '^build-\d+\.\d+\.\d+\.\d+$') { "Build $($patch.Substring(6))" }
        else { 'Patch unbekannt' }
    $registered = [guid]::Empty
    $status = if ($registrationState -ceq 'PROVISIONING_PENDING' -and -not $Entry.runId) { 'Vorgemerkt' }
        elseif ([guid]::TryParseExact([string]$Entry.runId, 'D', [ref]$registered) -and $registered -ne [guid]::Empty -and
            (-not $registrationState -or $registrationState -ceq 'REGISTERED')) { 'Registriert' }
        else { 'Registrierung unklar' }
    return "$platform · $versionLabel · $patchLabel · $status"
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
            $member = [pscustomobject]@{ Key=[string]$entry.key; RegistrationLabel=(Get-LabTestGroupRegistrationLabel -Entry $entry); RunId=[string]$entry.runId; ScopeId=''; InstanceId=[string]$entry.instanceId; Provider=''; RuntimeId=''; VMName=''; Power='UNKNOWN'; Desired=$target; SqlReadiness='NOT_CHECKED'; Change='BLOCKED'; Reason='' }
            try {
                if (-not $member.Key -or $seenKeys.ContainsKey($member.Key) -or $seenRuns.ContainsKey($member.RunId) -or
                    $member.RunId -notmatch '^[a-fA-F0-9-]{36}$' -or -not $member.InstanceId) { throw 'TEST_GROUP_MEMBER_AMBIGUOUS' }
                $seenKeys[$member.Key] = $true; $seenRuns[$member.RunId] = $true
                $runDirectory = Join-Path (Join-Path $root 'runs') $member.RunId
                $runPath = Join-Path $runDirectory 'run-state.json'; $connectionPath = Join-Path $runDirectory 'connection-info.json'
                if (-not (Test-LabPathWithinRoot -Root $root -Path $runPath).Valid -or
                    -not (Test-LabPathWithinRoot -Root $root -Path $connectionPath).Valid) { throw 'TEST_GROUP_MEMBER_PATH_UNSAFE' }
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
                        $arguments = @{ VMName=$member.VMName; ExpectedRunId=$member.RunId; ExpectedScopeId=$member.ScopeId; ExpectedVMId=$member.RuntimeId; ExpectedInstanceId=$member.InstanceId; StateRoot=$StateRoot }
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
                foreach ($member in $view.Members) { New-LabConsoleItem -Id ('member-' + $member.Key) -Label ("{0} · {1} · Power {2} · {3}" -f $member.Key,$member.Provider,$member.Power,$member.RegistrationLabel) -Disabled -DisabledReason $(if ($member.Reason) { $member.Reason } else { 'Mitglied der gruppenweiten Aktion' }) }
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
