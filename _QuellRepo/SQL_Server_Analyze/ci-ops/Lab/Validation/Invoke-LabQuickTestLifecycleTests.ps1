[CmdletBinding()]
param(
    [Parameter()]
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$paths = @(
    'Lab/Install-Lab.ps1'
    'Lab/Uninstall-Lab.ps1'
    'Lab/QuickTest/QuickTestLab.psm1'
    'Lab/QuickTest/Private/Common.ps1'
    'Lab/QuickTest/Private/LifecycleState.ps1'
    'Lab/QuickTest/Private/LifecycleRuntime.ps1'
    'Lab/QuickTest/Public/Invoke-QuickTestPreflight.ps1'
    'Lab/QuickTest/Public/Install-QuickTestLab.ps1'
    'Lab/QuickTest/Public/Get-QuickTestLabStatus.ps1'
    'Lab/QuickTest/Public/Invoke-QuickTestLabDown.ps1'
    'Lab/QuickTest/Public/Start-QuickTestLab.ps1'
    'Lab/QuickTest/Public/Remove-QuickTestLab.ps1'
    'Lab/Orchestration/Modules/DiagnosticLab/Public/Install-LabContainerFramework.ps1'
)
foreach ($relativePath in $paths) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $RepositoryRoot $relativePath),
        [ref] $tokens,
        [ref] $errors
    ) | Out-Null
    if (@($errors).Count -gt 0) {
        $summary = @($errors | ForEach-Object { $_.Message }) -join '; '
        throw "PowerShell parser reported an error for ${relativePath}: $summary"
    }
}

$startSource = [IO.File]::ReadAllText(
    (Join-Path $RepositoryRoot 'Lab/QuickTest/Public/Start-QuickTestLab.ps1'),
    [Text.Encoding]::UTF8
)
foreach ($fragment in @(
        "LifecycleStatus = 'STARTING'"
        "LifecycleStatus = 'START_RECOVERY_CLEANUP'"
        "LifecycleStatus = 'DOWN'"
    )) {
    if (-not $startSource.Contains($fragment, [StringComparison]::Ordinal)) {
        throw "Start source lacks recovery state fragment $fragment."
    }
}

$modulePath = Join-Path $RepositoryRoot 'Lab/QuickTest/QuickTestLab.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'qt-lifecycle-' + [guid]::NewGuid().ToString('N')
)
$fakeBin = Join-Path $testRoot 'bin'
$fakeRuntimeRoot = Join-Path $testRoot 'FakeRuntime'
$stateRoot = Join-Path $testRoot 'state'
$dataRoot = Join-Path $testRoot 'data'
$credentialRoot = Join-Path $testRoot 'credentials'
foreach ($directory in @($fakeBin, $fakeRuntimeRoot, $stateRoot, $dataRoot, $credentialRoot)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}

$fakeRuntime = Join-Path $fakeBin 'docker'
$fakeScript = @'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_RUNTIME_ROOT/commands.log"
container_short='aaaaaaaaaaaa'
network_short='bbbbbbbbbbbb'
container_full="$(printf 'a%.0s' {1..64})"
network_full="$(printf 'b%.0s' {1..64})"
joined=" $* "

if [ "${1:-}" = 'version' ]; then exit 0; fi
if [ "${1:-}" = 'compose' ] && [ "${2:-}" = 'version' ]; then exit 0; fi
if [ "${1:-}" = 'compose' ]; then
  if [[ "$joined" == *' up --detach sql2025 '* ]]; then
    printf '%s' "$QTLAB_RUN_ID" > "$FAKE_RUNTIME_ROOT/run-id"
    : > "$FAKE_RUNTIME_ROOT/container-present"
    : > "$FAKE_RUNTIME_ROOT/network-present"
  fi
  if [[ "$joined" == *' ps --all --quiet sql2025 '* ]] && [ -f "$FAKE_RUNTIME_ROOT/container-present" ]; then
    printf '%s\n' "$container_short"
  fi
  exit 0
fi
if [ "${1:-}" = 'manifest' ] && [ "${2:-}" = 'inspect' ]; then exit 0; fi
if [ "${1:-}" = 'container' ] && [ "${2:-}" = 'ls' ]; then
  if [[ "$joined" == *'label=qt-lab.scope='* ]]; then exit 0; fi
  if [[ "$joined" == *'label=qt-lab.run-id='* ]] && [ -f "$FAKE_RUNTIME_ROOT/container-present" ]; then
    printf '%s\n' "$container_short"
  fi
  exit 0
fi
if [ "${1:-}" = 'network' ] && [ "${2:-}" = 'ls' ]; then
  if [[ "$joined" == *'label=qt-lab.scope='* ]]; then exit 0; fi
  if [[ "$joined" == *'label=qt-lab.run-id='* ]] && [ -f "$FAKE_RUNTIME_ROOT/network-present" ]; then
    printf '%s\n' "$network_short"
  fi
  exit 0
fi
if [ "${1:-}" = 'container' ] && [ "${2:-}" = 'inspect' ]; then
  if [[ "$joined" == *'{{.Id}}'* ]]; then printf '%s\n' "$container_full"; exit 0; fi
  if [[ "$joined" == *'{{.State.Status}}|{{.State.Health.Status}}'* ]]; then printf 'running|healthy\n'; exit 0; fi
  if [[ "$joined" == *'{{.State.Health.Status}}'* ]]; then printf 'healthy\n'; exit 0; fi
  if [[ "$joined" == *'qt-lab.owner'* ]]; then printf 'SQL_SERVER_ANALYZE\n'; exit 0; fi
  if [[ "$joined" == *'qt-lab.run-id'* ]]; then cat "$FAKE_RUNTIME_ROOT/run-id"; printf '\n'; exit 0; fi
  exit 0
fi
if [ "${1:-}" = 'network' ] && [ "${2:-}" = 'inspect' ]; then
  if [[ "$joined" == *'{{.Id}}'* ]]; then printf '%s\n' "$network_full"; exit 0; fi
  if [[ "$joined" == *'qt-lab.owner'* ]]; then printf 'SQL_SERVER_ANALYZE\n'; exit 0; fi
  if [[ "$joined" == *'qt-lab.run-id'* ]]; then cat "$FAKE_RUNTIME_ROOT/run-id"; printf '\n'; exit 0; fi
  exit 0
fi
if [ "${1:-}" = 'exec' ]; then
  if [[ "$joined" == *'ProductMajorVersion'* ]]; then printf '17\n'; exit 0; fi
  if [[ "$joined" == *'FRAMEWORK_READY'* ]]; then printf 'FRAMEWORK_READY\n'; exit 0; fi
  if [[ "$joined" == *' --interactive '* ]]; then cat >/dev/null || true; fi
  exit 0
fi
if [ "${1:-}" = 'container' ] && [ "${2:-}" = 'rm' ]; then
  printf 'container rm --force %s\n' "${4:-}" >> "$FAKE_RUNTIME_ROOT/removals.log"
  rm -f "$FAKE_RUNTIME_ROOT/container-present"
  exit 0
fi
if [ "${1:-}" = 'network' ] && [ "${2:-}" = 'rm' ]; then
  printf 'network rm %s\n' "${3:-}" >> "$FAKE_RUNTIME_ROOT/removals.log"
  rm -f "$FAKE_RUNTIME_ROOT/network-present"
  exit 0
fi
exit 3
'@
[IO.File]::WriteAllText(
    $fakeRuntime,
    $fakeScript,
    [Text.UTF8Encoding]::new($false)
)
if ($IsLinux) {
    [IO.File]::SetUnixFileMode(
        $fakeRuntime,
        (
            [IO.UnixFileMode]::UserRead -bor
            [IO.UnixFileMode]::UserWrite -bor
            [IO.UnixFileMode]::UserExecute
        )
    )
}

$previousPath = $env:PATH
$previousFakeRoot = $env:FAKE_RUNTIME_ROOT
try {
    $env:FAKE_RUNTIME_ROOT = $fakeRuntimeRoot
    $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $previousPath
    $credentialInput = New-QuickTestPassword -Length 24

    $conflictScope = 'synthetic-conflict'
    [IO.Directory]::CreateDirectory(
        (Join-Path $dataRoot $conflictScope)
    ) | Out-Null
    $conflict = Install-QuickTestLab `
        -Runtime DOCKER `
        -SqlVersions @(2025) `
        -Ports @{ 2025 = 15480 } `
        -AdminSecret $credentialInput `
        -AdminLogin ExampleSqlAdmin `
        -ResourceProfile SMALL `
        -PersistenceMode TEMPORARY `
        -ScopeName $conflictScope `
        -AcceptEula `
        -StateRoot $stateRoot `
        -DataRoot $dataRoot `
        -CredentialRoot $credentialRoot `
        -Confirm:$false
    if (
        $conflict.Status -ne 'PREFLIGHT_FAILED' -or
        'LOCAL_SCOPE_CONFLICT' -notin @($conflict.BlockerReasonCodes)
    ) {
        throw 'Install did not refuse a pre-existing unowned local scope.'
    }

    $preflight = Invoke-QuickTestPreflight `
        -Runtime DOCKER `
        -SqlVersions @(2025) `
        -Ports @{ 2025 = 15481 } `
        -AdminLogin ExampleSqlAdmin `
        -AdminSecret $credentialInput `
        -ResourceProfile SMALL `
        -DataRoot (Join-Path $dataRoot 'synthetic-lifecycle') `
        -ScopeName synthetic-lifecycle `
        -AcceptEula
    if (
        $preflight.Status -ne 'READY' -or
        $preflight.MutationBoundary -ne 'READ_ONLY_PREFLIGHT'
    ) {
        throw "Synthetic lifecycle Preflight failed: $($preflight.BlockerReasonCodes -join ',')"
    }

    $install = Install-QuickTestLab `
        -Runtime DOCKER `
        -SqlVersions @(2025) `
        -Ports @{ 2025 = 15481 } `
        -AdminSecret $credentialInput `
        -AdminLogin ExampleSqlAdmin `
        -ResourceProfile SMALL `
        -PersistenceMode PERSISTENT `
        -ScopeName synthetic-lifecycle `
        -PersistGeneratedCredential `
        -AcceptEula `
        -StateRoot $stateRoot `
        -DataRoot $dataRoot `
        -CredentialRoot $credentialRoot `
        -Confirm:$false
    if ($install.Status -ne 'READY') {
        throw 'Synthetic Install did not return READY.'
    }
    if ($install.Connections.Count -ne 1 -or $install.Connections[0].SqlVersion -ne 2025) {
        throw 'Synthetic Install did not return the expected connection contract.'
    }

    $statePath = Join-Path $stateRoot 'synthetic-lifecycle/state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'Install did not write the marker-bound recovery state.'
    }
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
    if (
        $state.LifecycleStatus -ne 'READY' -or
        [string] $state.Containers[0].ContainerId -notmatch '^[a]{64}$' -or
        [string] $state.NetworkId -notmatch '^[b]{64}$'
    ) {
        throw 'Install did not persist canonical full runtime object IDs.'
    }
    if ($state.PSObject.Properties.Name -contains 'AdminSecret') {
        throw 'Runtime state contains a credential value property.'
    }
    $adminSqlFiles = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $stateRoot 'synthetic-lifecycle/runtime') `
            -Filter 'admin-login-*.sql' `
            -File `
            -ErrorAction SilentlyContinue
    )
    if ($adminSqlFiles.Count -gt 0) {
        throw 'Administrative login creation wrote a credential-bearing SQL file.'
    }

    $status = Get-QuickTestLabStatus `
        -ScopeName synthetic-lifecycle `
        -StateRoot $stateRoot
    if (
        $status.Status -ne 'READY' -or
        $status.Instances.Count -ne 1 -or
        -not $status.Instances[0].OwnershipValid -or
        -not $status.Instances[0].Ready
    ) {
        throw 'Synthetic Status did not validate runtime health and ownership.'
    }

    $down = Invoke-QuickTestLabDown `
        -ScopeName synthetic-lifecycle `
        -StateRoot $stateRoot `
        -Confirm:$false
    if (
        $down.Status -ne 'DOWN' -or
        $down.AlreadyDown -or
        -not $down.DataPreserved -or
        -not $down.StatePreserved -or
        -not $down.CredentialPreserved -or
        $down.ContainersRemoved -ne 1 -or
        $down.NetworksRemoved -ne 1
    ) {
        throw 'Synthetic Down did not preserve local state while removing runtime objects.'
    }

    $downState = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
    if (
        $downState.LifecycleStatus -ne 'DOWN' -or
        -not [string]::IsNullOrWhiteSpace([string] $downState.Containers[0].ContainerId) -or
        [string] $downState.Containers[0].PreviousContainerId -notmatch '^[a]{64}$' -or
        -not [string]::IsNullOrWhiteSpace([string] $downState.NetworkId) -or
        [string] $downState.PreviousNetworkId -notmatch '^[b]{64}$' -or
        @($downState.RecoveryContainerIds).Count -ne 0 -or
        @($downState.RecoveryNetworkIds).Count -ne 0
    ) {
        throw 'Down did not persist the expected reusable state contract.'
    }
    if (
        -not (Test-Path -LiteralPath (Join-Path $dataRoot 'synthetic-lifecycle')) -or
        -not (Test-Path -LiteralPath (Join-Path $credentialRoot 'synthetic-lifecycle')) -or
        -not (Test-Path -LiteralPath (Join-Path $stateRoot 'synthetic-lifecycle'))
    ) {
        throw 'Down removed a preserved local lifecycle directory.'
    }

    $downStatus = Get-QuickTestLabStatus `
        -ScopeName synthetic-lifecycle `
        -StateRoot $stateRoot
    if (
        $downStatus.Status -ne 'DOWN' -or
        -not $downStatus.DataPreserved -or
        -not $downStatus.StatePreserved -or
        $downStatus.Instances.Count -ne 1 -or
        $downStatus.Instances[0].RuntimeStatus -ne 'removed' -or
        $downStatus.Instances[0].Ready
    ) {
        throw 'Status did not report the preserved Down state.'
    }

    $downAgain = Invoke-QuickTestLabDown `
        -ScopeName synthetic-lifecycle `
        -StateRoot $stateRoot `
        -Confirm:$false
    if (
        $downAgain.Status -ne 'DOWN' -or
        -not $downAgain.AlreadyDown -or
        $downAgain.ContainersRemoved -ne 0 -or
        $downAgain.NetworksRemoved -ne 0
    ) {
        throw 'Down is not idempotent.'
    }

    $start = Start-QuickTestLab `
        -ScopeName synthetic-lifecycle `
        -StateRoot $stateRoot `
        -Confirm:$false
    if (
        $start.Status -ne 'READY' -or
        $start.AlreadyRunning -or
        -not $start.LoadedStoredCredential -or
        $start.Connections.Count -ne 1 -or
        $start.Connections[0].SqlVersion -ne 2025
    ) {
        throw 'Start did not recreate the preserved quick-test scope.'
    }

    $startState = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
    if (
        $startState.LifecycleStatus -ne 'READY' -or
        [string] $startState.Containers[0].ContainerId -notmatch '^[a]{64}$' -or
        [string] $startState.NetworkId -notmatch '^[b]{64}$' -or
        [string] $startState.Containers[0].PreviousContainerId -notmatch '^[a]{64}$' -or
        @($startState.RecoveryContainerIds).Count -ne 0 -or
        @($startState.RecoveryNetworkIds).Count -ne 0
    ) {
        throw 'Start did not persist the expected READY state contract.'
    }

    $startedStatus = Get-QuickTestLabStatus `
        -ScopeName synthetic-lifecycle `
        -StateRoot $stateRoot
    if (
        $startedStatus.Status -ne 'READY' -or
        $startedStatus.Instances.Count -ne 1 -or
        -not $startedStatus.Instances[0].OwnershipValid -or
        -not $startedStatus.Instances[0].Ready
    ) {
        throw 'Status did not report READY after Start.'
    }

    $startAgain = Start-QuickTestLab `
        -ScopeName synthetic-lifecycle `
        -StateRoot $stateRoot `
        -Confirm:$false
    if (
        $startAgain.Status -ne 'READY' -or
        -not $startAgain.AlreadyRunning
    ) {
        throw 'Start is not idempotent for a ready scope.'
    }

    $downAfterStart = Invoke-QuickTestLabDown `
        -ScopeName synthetic-lifecycle `
        -StateRoot $stateRoot `
        -Confirm:$false
    if (
        $downAfterStart.Status -ne 'DOWN' -or
        $downAfterStart.AlreadyDown -or
        $downAfterStart.ContainersRemoved -ne 1 -or
        $downAfterStart.NetworksRemoved -ne 1
    ) {
        throw 'Down did not remove the scope after Start.'
    }

    $destroy = Remove-QuickTestLab `
        -ScopeName synthetic-lifecycle `
        -StateRoot $stateRoot `
        -Confirm:$false
    if ($destroy.Status -ne 'DESTROYED' -or -not $destroy.DataRemoved) {
        throw 'Synthetic Destroy did not remove the complete owned scope after Start and Down.'
    }
    if (
        (Test-Path -LiteralPath (Join-Path $stateRoot 'synthetic-lifecycle')) -or
        (Test-Path -LiteralPath (Join-Path $dataRoot 'synthetic-lifecycle')) -or
        (Test-Path -LiteralPath (Join-Path $credentialRoot 'synthetic-lifecycle'))
    ) {
        throw 'Synthetic Destroy left an owned local lifecycle directory.'
    }

    $removalLog = Get-Content `
        -LiteralPath (Join-Path $fakeRuntimeRoot 'removals.log') `
        -Raw `
        -Encoding utf8
    $containerRemovals = @(
        [regex]::Matches($removalLog, 'container rm --force [a]{64}')
    ).Count
    $networkRemovals = @(
        [regex]::Matches($removalLog, 'network rm [b]{64}')
    ).Count
    if ($containerRemovals -ne 2 -or $networkRemovals -ne 2) {
        throw 'Down and Start lifecycle did not use exact canonical runtime object IDs.'
    }
}
finally {
    $env:PATH = $previousPath
    $env:FAKE_RUNTIME_ROOT = $previousFakeRoot
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output 'Docker/Podman quick-test lifecycle contracts passed.'
