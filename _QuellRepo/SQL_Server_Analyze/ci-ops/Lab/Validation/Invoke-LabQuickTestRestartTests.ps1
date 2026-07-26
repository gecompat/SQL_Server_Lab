[CmdletBinding()]
param(
    [Parameter()]
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$paths = @(
    'Lab/Install-Lab.ps1'
    'Lab/QuickTest/QuickTestLab.psm1'
    'Lab/QuickTest/Public/Restart-QuickTestLab.ps1'
    'Lab/QuickTest/Public/Stop-QuickTestLab.ps1'
    'Lab/QuickTest/Public/Start-QuickTestStoppedLab.ps1'
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

$modulePath = Join-Path $RepositoryRoot 'Lab/QuickTest/QuickTestLab.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'qt-restart-' + [guid]::NewGuid().ToString('N')
)
$fakeBin = Join-Path $testRoot 'bin'
$fakeRuntimeRoot = Join-Path $testRoot 'FakeRuntime'
$stateRoot = Join-Path $testRoot 'state'
$dataRoot = Join-Path $testRoot 'data'
$credentialRoot = Join-Path $testRoot 'credentials'
foreach ($directory in @($fakeBin, $fakeRuntimeRoot, $stateRoot, $dataRoot, $credentialRoot)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}

$scopeName = 'synthetic-restart'
$statePath = Join-Path $stateRoot "$scopeName/state.json"
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
    : > "$FAKE_RUNTIME_ROOT/container-running"
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
  if [[ "$joined" == *'{{.State.Status}}|{{.State.Health.Status}}'* ]]; then
    if [ -f "$FAKE_RUNTIME_ROOT/container-running" ]; then printf 'running|healthy\n'; else printf 'exited|\n'; fi
    exit 0
  fi
  if [[ "$joined" == *'{{.State.Health.Status}}'* ]]; then
    if [ -f "$FAKE_RUNTIME_ROOT/container-running" ]; then printf 'healthy\n'; else printf '\n'; fi
    exit 0
  fi
  if [[ "$joined" == *'{{.State.Status}}'* ]]; then
    if [ -f "$FAKE_RUNTIME_ROOT/container-running" ]; then printf 'running\n'; else printf 'exited\n'; fi
    exit 0
  fi
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
if [ "${1:-}" = 'container' ] && [ "${2:-}" = 'stop' ]; then
  grep -q '"LifecycleStatus": "STOPPING"' "$QTLAB_TEST_STATE_PATH"
  printf 'container stop %s\n' "${5:-}" >> "$FAKE_RUNTIME_ROOT/stops.log"
  rm -f "$FAKE_RUNTIME_ROOT/container-running"
  exit 0
fi
if [ "${1:-}" = 'container' ] && [ "${2:-}" = 'start' ]; then
  grep -q '"LifecycleStatus": "STARTING"' "$QTLAB_TEST_STATE_PATH"
  printf 'container start %s\n' "${3:-}" >> "$FAKE_RUNTIME_ROOT/starts.log"
  : > "$FAKE_RUNTIME_ROOT/container-running"
  exit 0
fi
if [ "${1:-}" = 'exec' ]; then
  if [[ "$joined" == *'ProductMajorVersion'* ]]; then printf '17\n'; exit 0; fi
  if [[ "$joined" == *' --interactive '* ]]; then cat >/dev/null || true; fi
  exit 0
fi
if [ "${1:-}" = 'container' ] && [ "${2:-}" = 'rm' ]; then
  rm -f "$FAKE_RUNTIME_ROOT/container-present" "$FAKE_RUNTIME_ROOT/container-running"
  exit 0
fi
if [ "${1:-}" = 'network' ] && [ "${2:-}" = 'rm' ]; then
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
$previousStatePath = $env:QTLAB_TEST_STATE_PATH
try {
    $env:FAKE_RUNTIME_ROOT = $fakeRuntimeRoot
    $env:QTLAB_TEST_STATE_PATH = $statePath
    $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $previousPath
    $credentialInput = New-QuickTestPassword -Length 24

    $install = Install-QuickTestLab `
        -Runtime DOCKER `
        -SqlVersions @(2025) `
        -Ports @{ 2025 = 15501 } `
        -AdminSecret $credentialInput `
        -AdminLogin ExampleSqlAdmin `
        -ResourceProfile SMALL `
        -PersistenceMode PERSISTENT `
        -ScopeName $scopeName `
        -AcceptEula `
        -StateRoot $stateRoot `
        -DataRoot $dataRoot `
        -CredentialRoot $credentialRoot `
        -Confirm:$false
    if ($install.Status -ne 'READY') {
        throw 'Synthetic Restart Install did not return READY.'
    }

    $stateBefore = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
    $runIdBefore = [string] $stateBefore.RunId
    $containerIdBefore = [string] $stateBefore.Containers[0].ContainerId
    $networkIdBefore = [string] $stateBefore.NetworkId

    $whatIf = Restart-QuickTestLab `
        -ScopeName $scopeName `
        -StateRoot $stateRoot `
        -WhatIf
    if ($whatIf.Status -ne 'WHATIF') {
        throw 'Restart WhatIf did not report WHATIF.'
    }
    if (
        (Test-Path -LiteralPath (Join-Path $fakeRuntimeRoot 'stops.log')) -or
        (Test-Path -LiteralPath (Join-Path $fakeRuntimeRoot 'starts.log'))
    ) {
        throw 'Restart WhatIf performed a Runtime mutation.'
    }

    $restart = Restart-QuickTestLab `
        -ScopeName $scopeName `
        -StateRoot $stateRoot `
        -Confirm:$false
    if (
        $restart.Status -ne 'READY' -or
        -not $restart.Restarted -or
        $restart.ContainersRestarted -ne 1 -or
        -not $restart.RuntimeIdentityPreserved -or
        -not $restart.NetworkPreserved -or
        -not $restart.DataPreserved -or
        $restart.Connections.Count -ne 1
    ) {
        throw 'Restart did not return the expected READY contract.'
    }

    $stateAfter = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
    if (
        $stateAfter.LifecycleStatus -ne 'READY' -or
        [string] $stateAfter.RunId -ne $runIdBefore -or
        [string] $stateAfter.Containers[0].ContainerId -ne $containerIdBefore -or
        [string] $stateAfter.NetworkId -ne $networkIdBefore
    ) {
        throw 'Restart changed the preserved Runtime identity.'
    }

    $status = Get-QuickTestLabStatus `
        -ScopeName $scopeName `
        -StateRoot $stateRoot
    if ($status.Status -ne 'READY' -or -not $status.Instances[0].Ready) {
        throw 'Status did not return READY after Restart.'
    }

    $stops = Get-Content `
        -LiteralPath (Join-Path $fakeRuntimeRoot 'stops.log') `
        -Raw `
        -Encoding utf8
    $starts = Get-Content `
        -LiteralPath (Join-Path $fakeRuntimeRoot 'starts.log') `
        -Raw `
        -Encoding utf8
    if (
        @([regex]::Matches($stops, 'container stop [a]{64}')).Count -ne 1 -or
        @([regex]::Matches($starts, 'container start [a]{64}')).Count -ne 1
    ) {
        throw 'Restart did not use the exact canonical container ID once per phase.'
    }

    $commands = Get-Content `
        -LiteralPath (Join-Path $fakeRuntimeRoot 'commands.log') `
        -Raw `
        -Encoding utf8
    if (@([regex]::Matches($commands, 'up --detach sql2025(?:\s|$)')).Count -ne 1) {
        throw 'Restart recreated the container through Compose.'
    }

    $down = Invoke-QuickTestLabDown `
        -ScopeName $scopeName `
        -StateRoot $stateRoot `
        -Confirm:$false
    if ($down.Status -ne 'DOWN') {
        throw 'Down failed after Restart.'
    }
    $destroy = Remove-QuickTestLab `
        -ScopeName $scopeName `
        -StateRoot $stateRoot `
        -Confirm:$false
    if ($destroy.Status -ne 'DESTROYED') {
        throw 'Destroy failed after Restart and Down.'
    }
}
finally {
    $env:PATH = $previousPath
    $env:FAKE_RUNTIME_ROOT = $previousFakeRoot
    $env:QTLAB_TEST_STATE_PATH = $previousStatePath
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output 'Docker/Podman quick-test Restart contracts passed.'
