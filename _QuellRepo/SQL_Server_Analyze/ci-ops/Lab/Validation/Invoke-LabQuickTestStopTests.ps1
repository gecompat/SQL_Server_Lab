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
    'Lab/QuickTest/Public/Stop-QuickTestLab.ps1'
    'Lab/QuickTest/Public/Start-QuickTestStoppedLab.ps1'
    'Lab/QuickTest/Public/Get-QuickTestLabStatus.ps1'
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
    'qt-stop-' + [guid]::NewGuid().ToString('N')
)
$fakeBin = Join-Path $testRoot 'bin'
$fakeRuntimeRoot = Join-Path $testRoot 'FakeRuntime'
$stateRoot = Join-Path $testRoot 'state'
$dataRoot = Join-Path $testRoot 'data'
$credentialRoot = Join-Path $testRoot 'credentials'
foreach ($directory in @($fakeBin, $fakeRuntimeRoot, $stateRoot, $dataRoot, $credentialRoot)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}

$scopeName = 'synthetic-stop'
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
        -Ports @{ 2025 = 15491 } `
        -AdminSecret $credentialInput `
        -AdminLogin ExampleSqlAdmin `
        -ResourceProfile SMALL `
        -PersistenceMode PERSISTENT `
        -ScopeName $scopeName `
        -PersistGeneratedCredential `
        -AcceptEula `
        -StateRoot $stateRoot `
        -DataRoot $dataRoot `
        -CredentialRoot $credentialRoot `
        -Confirm:$false
    if ($install.Status -ne 'READY') {
        throw 'Synthetic Stop Install did not return READY.'
    }

    $beforeState = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
    $containerId = [string] $beforeState.Containers[0].ContainerId
    $networkId = [string] $beforeState.NetworkId

    $whatIf = Stop-QuickTestLab `
        -ScopeName $scopeName `
        -StateRoot $stateRoot `
        -WhatIf
    if ($whatIf.Status -ne 'WHATIF') {
        throw 'Stop WhatIf did not report WHATIF.'
    }

    $stop = Stop-QuickTestLab `
        -ScopeName $scopeName `
        -StateRoot $stateRoot `
        -Confirm:$false
    if (
        $stop.Status -ne 'STOPPED' -or
        $stop.AlreadyStopped -or
        $stop.ContainersStopped -ne 1 -or
        -not $stop.NetworkPreserved -or
        -not $stop.DataPreserved
    ) {
        throw 'Stop did not preserve the exact installed scope.'
    }

    $stoppedState = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
    if (
        $stoppedState.LifecycleStatus -ne 'STOPPED' -or
        [string] $stoppedState.Containers[0].ContainerId -ne $containerId -or
        [string] $stoppedState.NetworkId -ne $networkId
    ) {
        throw 'Stop changed registered runtime object IDs.'
    }
    foreach ($path in @(
            (Join-Path $stateRoot $scopeName)
            (Join-Path $dataRoot $scopeName)
            (Join-Path $credentialRoot $scopeName)
        )) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            throw 'Stop removed a preserved local scope directory.'
        }
    }

    $status = Get-QuickTestLabStatus `
        -ScopeName $scopeName `
        -StateRoot $stateRoot
    if (
        $status.Status -ne 'STOPPED' -or
        $status.Instances.Count -ne 1 -or
        -not $status.Instances[0].Stopped -or
        $status.Instances[0].Ready -or
        -not $status.NetworkPreserved
    ) {
        throw 'Status did not report the STOPPED lifecycle state.'
    }

    $stopAgain = Stop-QuickTestLab `
        -ScopeName $scopeName `
        -StateRoot $stateRoot `
        -Confirm:$false
    if (
        $stopAgain.Status -ne 'STOPPED' -or
        -not $stopAgain.AlreadyStopped -or
        $stopAgain.ContainersStopped -ne 0
    ) {
        throw 'Stop is not idempotent.'
    }

    $start = Start-QuickTestStoppedLab `
        -ScopeName $scopeName `
        -StateRoot $stateRoot `
        -Confirm:$false
    if (
        $start.Status -ne 'READY' -or
        $start.AlreadyRunning -or
        $start.RecreatedContainers -or
        $start.LoadedStoredCredential -or
        $start.Connections.Count -ne 1
    ) {
        throw 'Stopped Start did not resume the existing container.'
    }

    $startedState = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
    if (
        $startedState.LifecycleStatus -ne 'READY' -or
        [string] $startedState.Containers[0].ContainerId -ne $containerId -or
        [string] $startedState.NetworkId -ne $networkId -or
        @($startedState.RecoveryContainerIds).Count -ne 0
    ) {
        throw 'Stopped Start changed the preserved runtime identity.'
    }

    $readyStatus = Get-QuickTestLabStatus `
        -ScopeName $scopeName `
        -StateRoot $stateRoot
    if ($readyStatus.Status -ne 'READY' -or -not $readyStatus.Instances[0].Ready) {
        throw 'Status did not return READY after stopped Start.'
    }

    $stopAfterStart = Stop-QuickTestLab `
        -ScopeName $scopeName `
        -StateRoot $stateRoot `
        -Confirm:$false
    if ($stopAfterStart.Status -ne 'STOPPED') {
        throw 'Stop failed after stopped Start.'
    }

    $down = Invoke-QuickTestLabDown `
        -ScopeName $scopeName `
        -StateRoot $stateRoot `
        -Confirm:$false
    if ($down.Status -ne 'DOWN') {
        throw 'Down failed after Stop.'
    }
    $destroy = Remove-QuickTestLab `
        -ScopeName $scopeName `
        -StateRoot $stateRoot `
        -Confirm:$false
    if ($destroy.Status -ne 'DESTROYED') {
        throw 'Destroy failed after Stop and Down.'
    }

    $stopLog = Get-Content `
        -LiteralPath (Join-Path $fakeRuntimeRoot 'stops.log') `
        -Raw `
        -Encoding utf8
    $startLog = Get-Content `
        -LiteralPath (Join-Path $fakeRuntimeRoot 'starts.log') `
        -Raw `
        -Encoding utf8
    if (
        @([regex]::Matches($stopLog, 'container stop [a]{64}')).Count -ne 2 -or
        @([regex]::Matches($startLog, 'container start [a]{64}')).Count -ne 1
    ) {
        throw 'Stop and stopped Start did not use the exact canonical container ID.'
    }
    $commands = Get-Content `
        -LiteralPath (Join-Path $fakeRuntimeRoot 'commands.log') `
        -Raw `
        -Encoding utf8
    if (@([regex]::Matches($commands, 'up --detach sql2025(?:\s|$)')).Count -ne 1) {
        throw 'Stopped Start recreated the container through Compose.'
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

Write-Output 'Docker/Podman quick-test Stop contracts passed.'
