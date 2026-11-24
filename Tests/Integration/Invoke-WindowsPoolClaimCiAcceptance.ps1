#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if ($env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or $env:GITHUB_REF -cne 'refs/heads/main' -or
    $env:GITHUB_REPOSITORY -cne 'gecompat/SQL_Server_Lab' -or
    $env:SQL_SERVER_LAB_CI_EVENT_REPOSITORY -cne $env:GITHUB_REPOSITORY -or
    $env:SQL_SERVER_LAB_CI_POOL_CONFIRM -cne 'true') {
    throw 'WINDOWS_POOL_CI_SCOPE_INVALID'
}
$checkout = & git -C $repoRoot rev-parse HEAD
if ($LASTEXITCODE -or $checkout -cne $env:GITHUB_SHA) { throw 'WINDOWS_POOL_CI_CHECKOUT_INVALID' }
if ($env:SQL_SERVER_LAB_RESOURCE_LIFECYCLE -cne 'run') { throw 'WINDOWS_POOL_CI_RUN_LIFECYCLE_REQUIRED' }
if ($env:SQL_SERVER_LAB_CI_POOL_INSTALL_SQL -and $env:SQL_SERVER_LAB_CI_POOL_INSTALL_SQL -cnotin @('true','false')) {
    throw 'WINDOWS_POOL_CI_SQL_SLOT_CONFIRMATION_INVALID'
}
$installSqlSlot = $env:SQL_SERVER_LAB_CI_POOL_INSTALL_SQL -ceq 'true'

$relativeMedia = $env:SQL_SERVER_LAB_CI_POOL_SQL_MEDIA
$mediaEdition = $env:SQL_SERVER_LAB_CI_POOL_MEDIA_EDITION
if ($relativeMedia -notmatch '^SQL[\\/]2025[\\/][^:\r\n]+\.iso$' -or
    $relativeMedia -match '(^|[\\/])\.\.([\\/]|$)' -or $mediaEdition -cnotin @('Enterprise','Standard','Eval')) {
    throw 'WINDOWS_POOL_CI_MEDIA_SELECTION_REQUIRED'
}
$artifactId = $env:SQL_SERVER_LAB_CI_POOL_IMAGE_ID
if ($artifactId -and $artifactId -cnotmatch '^hyperv-os-sealed-[a-f0-9]{64}$') { throw 'WINDOWS_POOL_CI_IMAGE_SELECTION_INVALID' }
if (-not $IsWindows -or [Environment]::MachineName -ine 'Key18') { throw 'WINDOWS_POOL_CI_RUNNER_INVALID' }

. (Join-Path $repoRoot 'Tests/Common/HyperVPreparedLocaleSupervisor.ps1')
$mutex = [Threading.Mutex]::new($false, 'Global\SQL_Server_Lab_Runtime_Smoke')
$acquired = $false
$previousState = $env:SQL_SERVER_LAB_STATE
try {
    try { $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(5)) }
    catch [Threading.AbandonedMutexException] {
        $acquired = $true
        throw 'WINDOWS_POOL_CI_RUNTIME_LEASE_ABANDONED'
    }
    if (-not $acquired) { throw 'WINDOWS_POOL_CI_RUNTIME_LEASE_BUSY' }

    $module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru 3>$null
    $mediaRoot = & $module {
        if (-not (Test-LabAdministrator) -or -not (Test-HyperVAvailable).Available) { throw 'WINDOWS_POOL_CI_ELEVATION_REQUIRED' }
        $network = Resolve-LabHyperVNetworkBoundPlan -Intent hostOnly
        if ($network.Status -cne 'READY' -or @($network.Actions).Count -ne 0) { throw 'WINDOWS_POOL_CI_EXISTING_HOST_NETWORK_REQUIRED' }
        Get-LabMediaRootDefault
    }
    if (-not $mediaRoot) { throw 'WINDOWS_POOL_CI_MEDIA_ROOT_NOT_CONFIGURED' }

    $root = New-HyperVPreparedLocaleSupervisorRoot
    $stateRoot = Join-Path $root 'state'
    $env:SQL_SERVER_LAB_STATE = $stateRoot
    $candidates = @(Get-SqlServerLabHyperVImageArtifact -StateRoot $stateRoot | Where-Object {
        $_.ArtifactState -ceq 'OS_SEALED' -and $_.OperatingSystem.Version -match '2025' -and
        $_.OperatingSystem.InstallationType -ceq 'desktop-experience' -and $_.Evaluation.Status -ceq 'EVALUATION_VALID' -and
        $_.TemplateValidation.Status -ceq 'CHILD_BOOT_VERIFIED' -and (-not $artifactId -or $_.ArtifactId -ceq $artifactId)
    })
    if ($candidates.Count -ne 1) { throw 'WINDOWS_POOL_CI_UNIQUE_BASELINE_REQUIRED' }

    $log = Join-Path $root 'windows-pool-claim.private.log'
    try {
        & (Join-Path $repoRoot 'Tests/Integration/Invoke-WindowsPoolClaimAcceptance.ps1') -StateRoot $stateRoot `
            -ArtifactId $candidates[0].ArtifactId -MediaRoot $mediaRoot -SqlMediaPath $relativeMedia -MediaEdition $mediaEdition `
            -ConfirmNativeExecution -ConfirmOwnCleanup -ConfirmSqlSlotInstallation:$installSqlSlot -RetainEvidenceInStateRoot *> $log
    }
    catch {
        $code = 'WINDOWS_POOL_CI_ACCEPTANCE_FAILED'
        if ($_.Exception.Message -cmatch '^(WINDOWS_POOL_NATIVE_[A-Z0-9_]+)(?:[: ]|$)') { $code = $Matches[1] }
        throw "$code. Private evidence is retained on Key18."
    }
    Write-Host 'WINDOWS_POOL_CI_ACCEPTANCE_PASS'
}
finally {
    $env:SQL_SERVER_LAB_STATE = $previousState
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
