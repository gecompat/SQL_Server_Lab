Set-StrictMode -Version Latest

function Invoke-QuickTestPreflight {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DOCKER', 'PODMAN')]
        [string] $Runtime,

        [Parameter(Mandatory)]
        [int[]] $SqlVersions,

        [Parameter()]
        [hashtable] $Ports = @{},

        [Parameter(Mandatory)]
        [ValidatePattern('^(sa|[A-Za-z][A-Za-z0-9_]{2,31})$')]
        [string] $AdminLogin,

        [Parameter(Mandatory)]
        [securestring] $AdminSecret,

        [Parameter()]
        [ValidateSet('SMALL', 'MEDIUM', 'LARGE')]
        [string] $ResourceProfile = 'SMALL',

        [Parameter()]
        [string] $DataRoot = (Join-Path $script:QuickTestLabRoot '.state/quick-test-data'),

        [Parameter()]
        [ValidatePattern('^[a-z][a-z0-9-]{2,31}$')]
        [string] $ScopeName = 'sql-analyze-quicktest',

        [Parameter()]
        [switch] $AcceptEula,

        [Parameter()]
        [switch] $SkipImageAvailabilityCheck
    )

    $checks = [Collections.Generic.List[object]]::new()
    $blockers = [Collections.Generic.List[string]]::new()
    $versions = @($SqlVersions | Sort-Object -Unique)
    $resolvedPorts = @{}

    $osReady = $IsLinux
    $checks.Add([pscustomobject] @{
            Check = 'OPERATING_SYSTEM'
            Status = if ($osReady) { 'PASS' } else { 'FAIL' }
            ReasonCode = if ($osReady) { '' } else { 'UNSUPPORTED_OPERATING_SYSTEM' }
        })
    if (-not $osReady) {
        $blockers.Add('UNSUPPORTED_OPERATING_SYSTEM')
    }

    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    $architectureReady = $architecture -eq [Runtime.InteropServices.Architecture]::X64
    $checks.Add([pscustomobject] @{
            Check = 'ARCHITECTURE'
            Status = if ($architectureReady) { 'PASS' } else { 'FAIL' }
            ReasonCode = if ($architectureReady) { '' } else { 'UNSUPPORTED_ARCHITECTURE' }
        })
    if (-not $architectureReady) {
        $blockers.Add('UNSUPPORTED_ARCHITECTURE')
    }

    $eulaReady = [bool] $AcceptEula
    $checks.Add([pscustomobject] @{
            Check = 'SQL_SERVER_EULA'
            Status = if ($eulaReady) { 'PASS' } else { 'FAIL' }
            ReasonCode = if ($eulaReady) { '' } else { 'EULA_ACCEPTANCE_REQUIRED' }
        })
    if (-not $eulaReady) {
        $blockers.Add('EULA_ACCEPTANCE_REQUIRED')
    }

    $secretReady = Test-QuickTestPassword -SecureValue $AdminSecret
    $checks.Add([pscustomobject] @{
            Check = 'SQL_SECRET_COMPLEXITY'
            Status = if ($secretReady) { 'PASS' } else { 'FAIL' }
            ReasonCode = if ($secretReady) { '' } else { 'SECRET_COMPLEXITY_FAILED' }
        })
    if (-not $secretReady) {
        $blockers.Add('SECRET_COMPLEXITY_FAILED')
    }

    $versionReady = (
        $versions.Count -gt 0 -and
        @($versions | Where-Object { $_ -notin @(2019, 2022, 2025) }).Count -eq 0
    )
    $checks.Add([pscustomobject] @{
            Check = 'SQL_VERSIONS'
            Status = if ($versionReady) { 'PASS' } else { 'FAIL' }
            ReasonCode = if ($versionReady) { '' } else { 'UNSUPPORTED_SQL_VERSION' }
        })
    if (-not $versionReady) {
        $blockers.Add('UNSUPPORTED_SQL_VERSION')
    }

    $portsReady = $false
    if ($versionReady) {
        try {
            $resolvedPorts = Resolve-QuickTestPorts `
                -SqlVersions $versions `
                -Ports $Ports
            $portsReady = $true
            foreach ($version in $versions) {
                $port = [int] $resolvedPorts[$version]
                if (-not (Test-QuickTestPortAvailable -Port $port)) {
                    $portsReady = $false
                    break
                }
            }
        }
        catch {
            $portsReady = $false
        }
    }
    $checks.Add([pscustomobject] @{
            Check = 'HOST_PORTS'
            Status = if ($portsReady) { 'PASS' } else { 'FAIL' }
            ReasonCode = if ($portsReady) { '' } else { 'PORT_CONFLICT' }
        })
    if (-not $portsReady) {
        $blockers.Add('PORT_CONFLICT')
    }

    $profile = Get-QuickTestResourceProfile -Name $ResourceProfile
    $availableMemoryMiB = Get-QuickTestAvailableMemoryMiB
    $requiredMemoryMiB = (
        $profile.ContainerMemoryMiB * [Math]::Max($versions.Count, 1)
    ) + $profile.HostReserveMiB
    $resourceReady = (
        $availableMemoryMiB -gt 0 -and
        $availableMemoryMiB -ge $requiredMemoryMiB
    )
    $checks.Add([pscustomobject] @{
            Check = 'MEMORY_BUDGET'
            Status = if ($resourceReady) { 'PASS' } else { 'FAIL' }
            ReasonCode = if ($resourceReady) { '' } else { 'RESOURCE_LIMIT_EXCEEDED' }
        })
    if (-not $resourceReady) {
        $blockers.Add('RESOURCE_LIMIT_EXCEEDED')
    }

    $fullDataRoot = [IO.Path]::GetFullPath($DataRoot)
    $rootPath = [IO.Path]::GetPathRoot($fullDataRoot)
    $pathReady = (
        $fullDataRoot -ne $rootPath -and
        (Test-QuickTestWritablePath -Path $fullDataRoot)
    )
    $checks.Add([pscustomobject] @{
            Check = 'DATA_ROOT'
            Status = if ($pathReady) { 'PASS' } else { 'FAIL' }
            ReasonCode = if ($pathReady) { '' } else { 'DATA_ROOT_UNAVAILABLE' }
        })
    if (-not $pathReady) {
        $blockers.Add('DATA_ROOT_UNAVAILABLE')
    }

    $runtimeInfo = Resolve-QuickTestRuntime -Runtime $Runtime
    $checks.Add([pscustomobject] @{
            Check = 'CONTAINER_RUNTIME'
            Status = if ($runtimeInfo.IsAvailable) { 'PASS' } else { 'FAIL' }
            ReasonCode = $runtimeInfo.ReasonCode
        })
    if (-not $runtimeInfo.IsAvailable) {
        $blockers.Add($runtimeInfo.ReasonCode)
    }

    if ($runtimeInfo.IsAvailable) {
        $scopeConflict = $false
        try {
            $scopeConflict = Test-QuickTestScopeConflict `
                -RuntimeInfo $runtimeInfo `
                -ScopeName $ScopeName
        }
        catch {
            $scopeConflict = $true
        }
        $checks.Add([pscustomobject] @{
                Check = 'LAB_SCOPE'
                Status = if ($scopeConflict) { 'FAIL' } else { 'PASS' }
                ReasonCode = if ($scopeConflict) { 'SCOPE_CONFLICT' } else { '' }
            })
        if ($scopeConflict) {
            $blockers.Add('SCOPE_CONFLICT')
        }

        if (-not $SkipImageAvailabilityCheck -and $versionReady) {
            foreach ($version in $versions) {
                $imageReady = $true
                try {
                    $image = Get-QuickTestImageReference -SqlVersion $version
                    Invoke-QuickTestExternalCommand `
                        -FilePath $runtimeInfo.Command `
                        -Arguments @('manifest', 'inspect', $image) |
                        Out-Null
                }
                catch {
                    $imageReady = $false
                }
                $checks.Add([pscustomobject] @{
                        Check = "IMAGE_$version"
                        Status = if ($imageReady) { 'PASS' } else { 'FAIL' }
                        ReasonCode = if ($imageReady) { '' } else { 'IMAGE_UNAVAILABLE' }
                    })
                if (-not $imageReady) {
                    $blockers.Add('IMAGE_UNAVAILABLE')
                }
            }
        }
    }

    $uniqueBlockers = @($blockers | Sort-Object -Unique)
    $overallStatus = if ($uniqueBlockers.Count -eq 0) {
        'READY'
    }
    else {
        'PREFLIGHT_FAILED'
    }

    return [pscustomobject] @{
        Status = $overallStatus
        Runtime = $Runtime
        RuntimeCommand = $runtimeInfo.Command
        SqlVersions = $versions
        Ports = $resolvedPorts
        AdminLogin = $AdminLogin
        ResourceProfile = $ResourceProfile
        DataRoot = $fullDataRoot
        ScopeName = $ScopeName
        RequiredMemoryMiB = $requiredMemoryMiB
        AvailableMemoryMiB = $availableMemoryMiB
        Checks = $checks.ToArray()
        BlockerReasonCodes = $uniqueBlockers
        MutationBoundary = 'READ_ONLY_PREFLIGHT'
    }
}
