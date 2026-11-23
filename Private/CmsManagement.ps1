function Invoke-WithLabCmsManagementLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$StateRoot,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $root = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\','/')
    if ($IsWindows) { $root = $root.ToUpperInvariant() }
    $rootBytes = [Text.Encoding]::UTF8.GetBytes($root)
    $prefix = if ($IsWindows) { 'Global\SqlServerLab.CmsManagement.' } else { 'SqlServerLab.CmsManagement.' }
    try { $name = $prefix + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rootBytes)).ToLowerInvariant() }
    finally { [Array]::Clear($rootBytes, 0, $rootBytes.Length) }

    $mutex = [Threading.Mutex]::new($false, $name)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] { $acquired = $true; throw 'CMS_MANAGEMENT_STATE_CHANGED' }
        if (-not $acquired) { throw 'CMS_MANAGEMENT_BUSY' }
        return & $ScriptBlock
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-LabCmsManagementState {
    [CmdletBinding()]
    param([string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $canonicalRoot = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\','/')
    $configuration = $null
    $configurationError = $false
    try {
        $configPath = Join-Path $StateRoot 'catalog/sql-connection-center-cms.json'
        if (Test-Path -LiteralPath $configPath) { Assert-LabCmsInspectionReadPath -Root $StateRoot -Path $configPath }
        $configuration = Get-LabConnectionCenterCmsConfiguration -StateRoot $StateRoot
        if ($configuration -and ($configuration.RunId -cnotmatch '^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$' -or
            $configuration.Provider -cnotin @('docker','podman','hyperv') -or
            $configuration.ContractVersion -cnotin @('SqlServerLab.ConnectionCenterCms/1.0','SqlServerLab.ConnectionCenterCms/1.1'))) {
            throw 'CMS_MANAGEMENT_CONFIGURATION_INVALID'
        }
    }
    catch { $configurationError = $true; $configuration = $null }

    $providers = @()
    try { $providers = @(Get-AvailableLabProviders | Where-Object { $_ -in @('docker','podman') } | Sort-Object -Unique) }
    catch { }
    $dataRootConfigured = $false
    $dataRootBinding = 'UNKNOWN'
    try {
        $dataRoot = [string](Get-LabDataRootDefault)
        $dataRootConfigured = -not [string]::IsNullOrWhiteSpace($dataRoot)
        if ($dataRootConfigured) { $dataRootBinding = [IO.Path]::GetFullPath($dataRoot) }
        else { $dataRootBinding = 'ABSENT' }
    } catch { $dataRootBinding = 'UNKNOWN' }

    $cms = $null
    $cmsRunState = 'NOT_CONFIGURED'
    if ($configuration) {
        try {
            $run = Get-LabRunState -RunId ([string]$configuration.RunId) -StateRoot $StateRoot
            $cmsRunState = [string]$run.state
            if ([string]::IsNullOrWhiteSpace($cmsRunState)) { $cmsRunState = 'UNKNOWN' }
        } catch { $cmsRunState = 'UNKNOWN' }
        $cms = [pscustomobject][ordered]@{
            RunId = [string]$configuration.RunId
            Provider = [string]$configuration.Provider
            State = $cmsRunState
        }
    }

    $candidates = @()
    if (-not $configurationError -and -not $configuration) {
        try {
            $candidates = @(Get-LabCmsManagementCandidates -StateRoot $StateRoot -Providers $providers)
        } catch { $candidates = @() }
    }
    $fileNames = @('catalog/sql-connection-center-cms.json')
    if ($configuration) {
        $fileNames += @(
            ('runs/{0}/run-state.json' -f [string]$configuration.RunId),
            ('runs/{0}/connection-info.json' -f [string]$configuration.RunId)
        )
    }
    $fileBindings = foreach ($relative in $fileNames) {
        $path = Join-Path $StateRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Assert-LabCmsInspectionReadPath -Root $StateRoot -Path $path
            '{0}:{1}' -f $relative, (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        } else { '{0}:ABSENT' -f $relative }
    }
    $keyInput = [ordered]@{
        ContractVersion = 'SqlServerLab.CmsManagement/1.0'
        StateRoot = $canonicalRoot
        Files = @($fileBindings)
        Providers = $providers
        DataRoot = $dataRootBinding
        CmsState = $cmsRunState
        CandidateBindings = @($candidates | ForEach-Object { $_.Binding })
    }
    $keyBytes = [Text.Encoding]::UTF8.GetBytes(($keyInput | ConvertTo-Json -Depth 8 -Compress))
    $planKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($keyBytes)).ToLowerInvariant()
    [Array]::Clear($keyBytes, 0, $keyBytes.Length)

    $removedCms = $configuration -and $cmsRunState -eq 'REMOVED'
    [pscustomobject][ordered]@{
        ContractVersion = 'SqlServerLab.CmsManagement/1.0'
        Status = if ($configurationError) { 'UNKNOWN' } elseif ($configuration) { 'CONFIGURED' } else { 'NOT_CONFIGURED' }
        PlanKey = $planKey
        Cms = $cms
        Providers = $providers
        DataRootConfigured = $dataRootConfigured
        CanCreate = (-not $configurationError -and (-not $configuration -or $removedCms) -and $providers.Count -gt 0 -and $dataRootConfigured)
        CanAdopt = (-not $configurationError -and -not $configuration -and $candidates.Count -gt 0)
        Candidates = @($candidates | Select-Object RunId,Name,Provider)
    }
}

function Get-LabCmsManagementCandidates {
    param([string]$StateRoot, [string[]]$Providers)
    if (-not $Providers.Count) { return }
    $protected = @((Get-LabTestEnvironmentRegistry).environments | ForEach-Object { [string]$_.runId })
    foreach ($candidate in Get-LabConnectionCenterCmsEnvironmentCandidates -StateRoot $StateRoot) {
        $id = [string]$candidate.RunId
        if ($id -cnotmatch '^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$' -or $id -in $protected -or
            $candidate.Provider -cnotin $Providers -or $candidate.Run.state -cne 'RUNNING') { continue }
        try {
            $folder = Join-Path $StateRoot ('runs/' + $id)
            $paths = @('run-state.json','connection-info.json','secrets/sa-password.secret' | ForEach-Object { Join-Path $folder $_ })
            foreach ($path in $paths) { Assert-LabCmsInspectionReadPath -Root $StateRoot -Path $path }
            $before = @($paths[0..1] | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
            $run = Get-Content -LiteralPath $paths[0] -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 -ErrorAction Stop
            $connection = Get-Content -LiteralPath $paths[1] -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 -ErrorAction Stop
            $instances = @($connection.instances)
            if ($run.runId -cne $id -or $run.state -cne 'RUNNING' -or -not $run.scopeId -or
                $connection.runId -cne $id -or $connection.scopeId -cne $run.scopeId -or $instances.Count -ne 1 -or
                $instances[0].id -cne 'primary' -or $instances[0].provider -cne $candidate.Provider -or
                $instances[0].containerId -cnotmatch '^[a-f0-9]{64}$' -or $instances[0].host -cnotin @('127.0.0.1','::1','localhost') -or
                $instances[0].version -cnotin @('2019','2022','2025') -or
                [int]$instances[0].port -lt 1 -or [int]$instances[0].port -gt 65535) { continue }
            $after = @($paths[0..1] | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
            if (($before -join ':') -cne ($after -join ':')) { continue }
            [pscustomobject]@{ RunId=$id; Name=[string]$candidate.Name; Provider=[string]$candidate.Provider; Binding="$id/$($after -join ':')"
                Run=$run; Instance=$instances[0] }
        } catch { continue }
    }
}

function Invoke-LabCmsManagementAdoption {
    param([string]$RunId, [string]$ExpectedPlanKey, [string]$StateRoot)
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $mutex = [Threading.Mutex]::new($false, (Get-LabContainerResourceLockName -StateRoot $StateRoot -RunId $RunId))
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true; throw 'CMS_MANAGEMENT_STATE_CHANGED' }
        if (-not $acquired) { throw 'CMS_MANAGEMENT_BUSY' }
        $state = Assert-LabCmsManagementPlanKey -ExpectedPlanKey $ExpectedPlanKey -StateRoot $StateRoot
        $matches = @(Get-LabCmsManagementCandidates -StateRoot $StateRoot -Providers $state.Providers | Where-Object RunId -ceq $RunId)
        if (-not $state.CanAdopt -or $matches.Count -ne 1) { throw 'CMS_MANAGEMENT_ADOPTION_UNAVAILABLE' }
        $candidate = $matches[0]
        $selection = @{
            Provider=$candidate.Provider; RunId=$candidate.RunId; InstanceId='primary'
            Run=$candidate.Run; Instance=$candidate.Instance; Key=$state.PlanKey
            Layout=Get-LabConnectionCenterConfiguration -StateRoot $StateRoot
        }
        $null = Get-LabCmsInspectionRuntimeBinding -Selection $selection
        $null = Assert-LabCmsManagementPlanKey -ExpectedPlanKey $ExpectedPlanKey -StateRoot $StateRoot
        Register-SqlServerLabCmsEnvironment -RunId $RunId -StateRoot $StateRoot -ErrorAction Stop
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Assert-LabCmsManagementPlanKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExpectedPlanKey, [string]$StateRoot)

    if ($ExpectedPlanKey -cnotmatch '^[a-f0-9]{64}$') { throw 'CMS_MANAGEMENT_PLAN_INVALID' }
    $state = Get-LabCmsManagementState -StateRoot $StateRoot
    if ($state.Status -eq 'UNKNOWN' -or $state.PlanKey -cne $ExpectedPlanKey) { throw 'CMS_MANAGEMENT_STATE_CHANGED' }
    return $state
}

function Assert-LabCmsManagementWorkflowJsonShape {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][string]$Action)

    try { $payload = $Json | ConvertFrom-Json -Depth 8 -ErrorAction Stop } catch { throw 'CMS_MANAGEMENT_REQUEST_INVALID' }
    if ($payload -isnot [pscustomobject] -or $payload.action -cne $Action -or $payload.parameters -isnot [pscustomobject] -or
        @($payload.PSObject.Properties.Name | Where-Object { $_ -cnotin @('action','parameters') }).Count) { throw 'CMS_MANAGEMENT_REQUEST_INVALID' }
    $parameters = @($payload.parameters.PSObject.Properties)
    $names = @($parameters | ForEach-Object Name)
    if ($names.Count -ne @($names | Sort-Object -Unique).Count) { throw 'CMS_MANAGEMENT_REQUEST_INVALID' }
    $expectedKey = $payload.parameters.ExpectedPlanKey
    $confirmed = $payload.parameters.ConfirmCmsOperation
    if ($expectedKey -isnot [string] -or $expectedKey -cnotmatch '^[a-f0-9]{64}$' -or $confirmed -isnot [bool] -or -not $confirmed) { throw 'CMS_MANAGEMENT_CONFIRMATION_REQUIRED' }

    switch ($Action) {
        'InitializeCms' {
            if (@($names | Where-Object { $_ -cnotin @('ExpectedPlanKey','ConfirmCmsOperation','Provider','LabName','ReplaceRemovedCms') }).Count -or
                $payload.parameters.Provider -notin @('docker','podman') -or
                ($null -ne $payload.parameters.LabName -and ($payload.parameters.LabName -isnot [string] -or $payload.parameters.LabName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$')) -or
                ($null -ne $payload.parameters.ReplaceRemovedCms -and $payload.parameters.ReplaceRemovedCms -isnot [bool])) { throw 'CMS_MANAGEMENT_REQUEST_INVALID' }
        }
        'AdoptCms' {
            if (@($names | Where-Object { $_ -cnotin @('ExpectedPlanKey','ConfirmCmsOperation','RunId') }).Count -or
                $payload.parameters.RunId -isnot [string] -or $payload.parameters.RunId -cnotmatch '^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$') { throw 'CMS_MANAGEMENT_REQUEST_INVALID' }
        }
        default { throw 'CMS_MANAGEMENT_ACTION_INVALID' }
    }
    return $true
}
