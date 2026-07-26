[CmdletBinding()]
param(
    [Parameter()]
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($relativePath in @(
        'Lab/Install-Lab.ps1'
        'Lab/QuickTest/QuickTestLab.psm1'
        'Lab/QuickTest/Public/Reset-QuickTestLab.ps1'
        'Lab/QuickTest/Public/Install-QuickTestLab.ps1'
        'Lab/QuickTest/Public/Remove-QuickTestLab.ps1'
    )) {
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

$modulePath = Join-Path $RepositoryRoot 'Lab/QuickTest/QuickTestLab.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'qt-reset-' + [guid]::NewGuid().ToString('N')
)
$fakeBin = Join-Path $testRoot 'bin'
$fakeRuntimeRoot = Join-Path $testRoot 'FakeRuntime'
$stateRoot = Join-Path $testRoot 'state'
$dataRoot = Join-Path $testRoot 'data'
$credentialRoot = Join-Path $testRoot 'credentials'
foreach ($directory in @(
        $fakeBin
        $fakeRuntimeRoot
        $stateRoot
        $dataRoot
        $credentialRoot
    )) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}

$fakeRuntime = Join-Path $fakeBin 'docker'
$fakeScript = @'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_RUNTIME_ROOT/commands.log"
joined=" $* "
get_generation() {
  if [ -f "$FAKE_RUNTIME_ROOT/generation" ]; then cat "$FAKE_RUNTIME_ROOT/generation"; else printf '0'; fi
}
get_chars() {
  local generation
  generation="$(get_generation)"
  if [ "$generation" = '1' ]; then printf 'a b'; else printf 'c d'; fi
}

if [ "${1:-}" = 'version' ]; then exit 0; fi
if [ "${1:-}" = 'compose' ] && [ "${2:-}" = 'version' ]; then exit 0; fi
if [ "${1:-}" = 'manifest' ] && [ "${2:-}" = 'inspect' ]; then exit 0; fi
if [ "${1:-}" = 'compose' ]; then
  if [[ "$joined" == *' up --detach sql2025'* ]]; then
    generation=$(( $(get_generation) + 1 ))
    printf '%s' "$generation" > "$FAKE_RUNTIME_ROOT/generation"
    printf '%s' "$QTLAB_RUN_ID" > "$FAKE_RUNTIME_ROOT/run-id"
    : > "$FAKE_RUNTIME_ROOT/container-present"
    : > "$FAKE_RUNTIME_ROOT/network-present"
  fi
  if [[ "$joined" == *' ps --all --quiet sql2025'* ]] && [ -f "$FAKE_RUNTIME_ROOT/container-present" ]; then
    read -r container_char network_char <<< "$(get_chars)"
    printf '%s\n' "$(printf "$container_char%.0s" {1..12})"
  fi
  exit 0
fi
if [ "${1:-}" = 'container' ] && [ "${2:-}" = 'ls' ]; then
  if [[ "$joined" == *'label=qt-lab.scope='* ]]; then exit 0; fi
  if [[ "$joined" == *'label=qt-lab.run-id='* ]] && [ -f "$FAKE_RUNTIME_ROOT/container-present" ]; then
    read -r container_char network_char <<< "$(get_chars)"
    printf '%s\n' "$(printf "$container_char%.0s" {1..12})"
  fi
  exit 0
fi
if [ "${1:-}" = 'network' ] && [ "${2:-}" = 'ls' ]; then
  if [[ "$joined" == *'label=qt-lab.scope='* ]]; then exit 0; fi
  if [[ "$joined" == *'label=qt-lab.run-id='* ]] && [ -f "$FAKE_RUNTIME_ROOT/network-present" ]; then
    read -r container_char network_char <<< "$(get_chars)"
    printf '%s\n' "$(printf "$network_char%.0s" {1..12})"
  fi
  exit 0
fi
if [ "${1:-}" = 'container' ] && [ "${2:-}" = 'inspect' ]; then
  read -r container_char network_char <<< "$(get_chars)"
  if [[ "$joined" == *'{{.Id}}'* ]]; then printf '%s\n' "$(printf "$container_char%.0s" {1..64})"; exit 0; fi
  if [[ "$joined" == *'{{.State.Status}}|{{.State.Health.Status}}'* ]]; then printf 'running|healthy\n'; exit 0; fi
  if [[ "$joined" == *'{{.State.Health.Status}}'* ]]; then printf 'healthy\n'; exit 0; fi
  if [[ "$joined" == *'qt-lab.owner'* ]]; then printf 'SQL_SERVER_ANALYZE\n'; exit 0; fi
  if [[ "$joined" == *'qt-lab.run-id'* ]]; then cat "$FAKE_RUNTIME_ROOT/run-id"; printf '\n'; exit 0; fi
  exit 0
fi
if [ "${1:-}" = 'network' ] && [ "${2:-}" = 'inspect' ]; then
  read -r container_char network_char <<< "$(get_chars)"
  if [[ "$joined" == *'{{.Id}}'* ]]; then printf '%s\n' "$(printf "$network_char%.0s" {1..64})"; exit 0; fi
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
    $credential = New-QuickTestPassword -Length 24

    $persistent = Install-QuickTestLab `
        -Runtime DOCKER `
        -SqlVersions @(2025) `
        -Ports @{ 2025 = 15501 } `
        -AdminSecret $credential `
        -AdminLogin ExampleSqlAdmin `
        -ResourceProfile SMALL `
        -PersistenceMode PERSISTENT `
        -ScopeName synthetic-persistent `
        -AcceptEula `
        -StateRoot $stateRoot `
        -DataRoot $dataRoot `
        -CredentialRoot $credentialRoot `
        -SkipImageAvailabilityCheck `
        -Confirm:$false
    if ($persistent.Status -ne 'READY') {
        throw 'Persistent Reset fixture did not install.'
    }
    $persistentStatePath = Join-Path $stateRoot 'synthetic-persistent/state.json'
    $persistentState = Get-Content -LiteralPath $persistentStatePath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
    $persistentReset = Reset-QuickTestLab `
        -ScopeName synthetic-persistent `
        -StateRoot $stateRoot `
        -AdminSecret $credential `
        -Confirm:$false
    if (
        $persistentReset.Status -ne 'RESET_PERSISTENT_SCOPE_BLOCKED' -or
        $persistentReset.MutationBoundary -ne 'READ_ONLY_RESET_PREFLIGHT'
    ) {
        throw 'Reset did not block a persistent scope before mutation.'
    }
    $persistentAfter = Get-Content -LiteralPath $persistentStatePath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
    if ([string] $persistentAfter.RunId -ne [string] $persistentState.RunId) {
        throw 'Blocked persistent Reset changed the scope state.'
    }
    Remove-QuickTestLab `
        -ScopeName synthetic-persistent `
        -StateRoot $stateRoot `
        -Confirm:$false |
        Out-Null

    Remove-Item -LiteralPath (Join-Path $fakeRuntimeRoot 'generation') -Force

    $temporary = Install-QuickTestLab `
        -Runtime DOCKER `
        -SqlVersions @(2025) `
        -Ports @{ 2025 = 15502 } `
        -AdminSecret $credential `
        -AdminLogin ExampleSqlAdmin `
        -ResourceProfile SMALL `
        -PersistenceMode TEMPORARY `
        -ScopeName synthetic-reset `
        -PersistGeneratedCredential `
        -AcceptEula `
        -StateRoot $stateRoot `
        -DataRoot $dataRoot `
        -CredentialRoot $credentialRoot `
        -SkipImageAvailabilityCheck `
        -Confirm:$false
    if ($temporary.Status -ne 'READY') {
        throw 'Temporary Reset fixture did not install.'
    }

    $statePath = Join-Path $stateRoot 'synthetic-reset/state.json'
    $before = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
    $oldRunId = [string] $before.RunId
    $oldContainerId = [string] $before.Containers[0].ContainerId
    $oldNetworkId = [string] $before.NetworkId
    $sentinelPath = Join-Path $dataRoot 'synthetic-reset/2025/data/reset-sentinel.txt'
    [IO.File]::WriteAllText(
        $sentinelPath,
        'synthetic reset sentinel',
        [Text.UTF8Encoding]::new($false)
    )

    $whatIf = Reset-QuickTestLab `
        -ScopeName synthetic-reset `
        -StateRoot $stateRoot `
        -WhatIf
    if ($whatIf.Status -ne 'RESET_CONFIRMATION_REQUIRED') {
        throw 'Reset WhatIf did not preserve the read-only mutation boundary.'
    }
    if (-not (Test-Path -LiteralPath $sentinelPath -PathType Leaf)) {
        throw 'Reset WhatIf removed synthetic data.'
    }

    $reset = Reset-QuickTestLab `
        -ScopeName synthetic-reset `
        -StateRoot $stateRoot `
        -SkipImageAvailabilityCheck `
        -Confirm:$false
    if (
        $reset.Status -ne 'READY' -or
        -not $reset.ResetPerformed -or
        -not $reset.DataRecreated -or
        -not $reset.LoadedStoredCredential -or
        [string] $reset.PreviousRunId -ne $oldRunId -or
        [string] $reset.RunId -eq $oldRunId
    ) {
        throw 'Reset did not return the expected fresh READY contract.'
    }

    $after = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
    if (
        $after.LifecycleStatus -ne 'READY' -or
        $after.PersistenceMode -ne 'TEMPORARY' -or
        -not $after.GeneratedCredentialStored -or
        [string] $after.RunId -eq $oldRunId -or
        [string] $after.Containers[0].ContainerId -eq $oldContainerId -or
        [string] $after.NetworkId -eq $oldNetworkId -or
        [string] $after.Containers[0].ContainerId -notmatch '^[c]{64}$' -or
        [string] $after.NetworkId -notmatch '^[d]{64}$'
    ) {
        throw 'Reset did not persist a fresh canonical runtime identity.'
    }
    if (Test-Path -LiteralPath $sentinelPath) {
        throw 'Reset did not delete the previous temporary data scope.'
    }
    if (
        -not (Test-Path -LiteralPath (Join-Path $dataRoot 'synthetic-reset/2025/data') -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $credentialRoot 'synthetic-reset/sql-admin.credential') -PathType Leaf)
    ) {
        throw 'Reset did not recreate the temporary data and credential scope.'
    }

    $status = Get-QuickTestLabStatus `
        -ScopeName synthetic-reset `
        -StateRoot $stateRoot
    if ($status.Status -ne 'READY' -or -not $status.Instances[0].Ready) {
        throw 'Status did not report READY after Reset.'
    }

    $commands = Get-Content `
        -LiteralPath (Join-Path $fakeRuntimeRoot 'commands.log') `
        -Raw `
        -Encoding utf8
    if (@([regex]::Matches($commands, ' up --detach sql2025(?:\s|$)')).Count -ne 3) {
        throw 'Reset fixture did not perform the persistent install, temporary install, and one fresh reinstall.'
    }
    $removals = Get-Content `
        -LiteralPath (Join-Path $fakeRuntimeRoot 'removals.log') `
        -Raw `
        -Encoding utf8
    if (
        $removals -notmatch 'container rm --force [a]{64}' -or
        $removals -notmatch 'network rm [b]{64}'
    ) {
        throw 'Reset did not destroy the previous runtime by exact canonical IDs.'
    }

    Remove-QuickTestLab `
        -ScopeName synthetic-reset `
        -StateRoot $stateRoot `
        -Confirm:$false |
        Out-Null
}
finally {
    $env:PATH = $previousPath
    $env:FAKE_RUNTIME_ROOT = $previousFakeRoot
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output 'Docker/Podman quick-test Reset contracts passed.'
