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
        'Lab/QuickTest/Public/Update-QuickTestFramework.ps1'
        'Lab/Orchestration/Modules/DiagnosticLab/Public/Install-LabContainerFramework.ps1'
        'Lab/Orchestration/Modules/DiagnosticLab/Private/Installer.ps1'
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
    'qt-update-framework-' + [guid]::NewGuid().ToString('N')
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
if [ "${1:-}" = 'manifest' ] && [ "${2:-}" = 'inspect' ]; then exit 0; fi
if [ "${1:-}" = 'compose' ]; then
  if [[ "$joined" == *' up --detach sql2025'* ]]; then
    printf '%s' "$QTLAB_RUN_ID" > "$FAKE_RUNTIME_ROOT/run-id"
    : > "$FAKE_RUNTIME_ROOT/container-present"
    : > "$FAKE_RUNTIME_ROOT/network-present"
  fi
  if [[ "$joined" == *' ps --all --quiet sql2025'* ]] && [ -f "$FAKE_RUNTIME_ROOT/container-present" ]; then
    printf '%s\n' "$container_short"
  fi
  exit 0
fi
if [ "${1:-}" = 'container' ] && [ "${2:-}" = 'ls' ]; then
  if [[ "$joined" == *'label=qt-lab.scope='* ]]; then exit 0; fi
  if [[ "$joined" == *'label=qt-lab.run-id='* ]] && [ -f "$FAKE_RUNTIME_ROOT/container-present" ]; then printf '%s\n' "$container_short"; fi
  exit 0
fi
if [ "${1:-}" = 'network' ] && [ "${2:-}" = 'ls' ]; then
  if [[ "$joined" == *'label=qt-lab.scope='* ]]; then exit 0; fi
  if [[ "$joined" == *'label=qt-lab.run-id='* ]] && [ -f "$FAKE_RUNTIME_ROOT/network-present" ]; then printf '%s\n' "$network_short"; fi
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
  if [[ "$joined" == *'Classify_Framework.sql'* ]]; then
    if [ -f "$FAKE_RUNTIME_ROOT/framework-present" ]; then printf 'FRAMEWORK_EXISTING\n'; else printf 'FRAMEWORK_MISSING\n'; fi
    exit 0
  fi
  if [[ "$joined" == *'Install_All.generated.sql'* ]]; then : > "$FAKE_RUNTIME_ROOT/framework-present"; exit 0; fi
  if [[ "$joined" == *'Prepare_Framework_Database.sql'* ]]; then exit 0; fi
  if [[ "$joined" == *'Verify_Framework.sql'* ]]; then
    test -f "$FAKE_RUNTIME_ROOT/framework-present"
    printf 'FRAMEWORK_READY\n'
    exit 0
  fi
  if [[ "$joined" == *' --interactive '* ]]; then cat >/dev/null || true; fi
  exit 0
fi
if [ "${1:-}" = 'container' ] && [ "${2:-}" = 'rm' ]; then rm -f "$FAKE_RUNTIME_ROOT/container-present"; exit 0; fi
if [ "${1:-}" = 'network' ] && [ "${2:-}" = 'rm' ]; then rm -f "$FAKE_RUNTIME_ROOT/network-present"; exit 0; fi
exit 3
'@
[IO.File]::WriteAllText($fakeRuntime, $fakeScript, [Text.UTF8Encoding]::new($false))
if ($IsLinux) {
    [IO.File]::SetUnixFileMode(
        $fakeRuntime,
        [IO.UnixFileMode]::UserRead -bor
        [IO.UnixFileMode]::UserWrite -bor
        [IO.UnixFileMode]::UserExecute
    )
}

$previousPath = $env:PATH
$previousFakeRoot = $env:FAKE_RUNTIME_ROOT
try {
    $env:FAKE_RUNTIME_ROOT = $fakeRuntimeRoot
    $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $previousPath
    $credential = New-QuickTestPassword -Length 24
    $install = Install-QuickTestLab `
        -Runtime DOCKER `
        -SqlVersions @(2025) `
        -Ports @{ 2025 = 15511 } `
        -AdminSecret $credential `
        -AdminLogin sa `
        -ResourceProfile SMALL `
        -PersistenceMode TEMPORARY `
        -ScopeName synthetic-framework `
        -AcceptEula `
        -StateRoot $stateRoot `
        -DataRoot $dataRoot `
        -CredentialRoot $credentialRoot `
        -SkipImageAvailabilityCheck `
        -Confirm:$false
    if ($install.Status -ne 'READY') { throw 'UpdateFramework fixture did not install.' }

    $statePath = Join-Path $stateRoot 'synthetic-framework/state.json'
    $before = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
    $whatIf = Update-QuickTestFramework `
        -ScopeName synthetic-framework `
        -StateRoot $stateRoot `
        -WhatIf
    if ($whatIf.Status -ne 'WHATIF') { throw 'UpdateFramework WhatIf did not stop before mutation.' }
    if (Test-Path -LiteralPath (Join-Path $fakeRuntimeRoot 'framework-present')) { throw 'UpdateFramework WhatIf changed the framework.' }

    $first = Update-QuickTestFramework `
        -ScopeName synthetic-framework `
        -StateRoot $stateRoot `
        -Confirm:$false
    if (
        $first.Status -ne 'READY' -or
        $first.FrameworkAction -ne 'INSTALLED' -or
        $first.SuccessfulCount -ne 1 -or
        $first.FailedCount -ne 0 -or
        $first.Instances[0].VerificationStatus -ne 'FRAMEWORK_READY'
    ) { throw 'First UpdateFramework call did not report INSTALLED and verified.' }

    $second = Update-QuickTestFramework `
        -ScopeName synthetic-framework `
        -StateRoot $stateRoot `
        -Confirm:$false
    if (
        $second.Status -ne 'READY' -or
        $second.FrameworkAction -ne 'UPDATED' -or
        $second.Instances[0].Status -ne 'UPDATED'
    ) { throw 'Second UpdateFramework call did not report UPDATED.' }

    $after = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
    if (
        [string] $after.RunId -ne [string] $before.RunId -or
        [string] $after.NetworkId -ne [string] $before.NetworkId -or
        [string] $after.Containers[0].ContainerId -ne [string] $before.Containers[0].ContainerId -or
        -not $after.InstallFramework -or
        $after.FrameworkDatabase -ne 'LabAnalyze' -or
        $after.FrameworkUpdateStatus -ne 'READY' -or
        $after.FrameworkInstances[0].Status -ne 'UPDATED'
    ) { throw 'UpdateFramework changed runtime identity or did not persist framework state.' }

    $commands = Get-Content -LiteralPath (Join-Path $fakeRuntimeRoot 'commands.log') -Raw -Encoding utf8
    if (@([regex]::Matches($commands, ' up --detach sql2025(?:\s|$)')).Count -ne 1) { throw 'UpdateFramework recreated the container through Compose.' }
    if (@([regex]::Matches($commands, 'Classify_Framework.sql')).Count -ne 2) { throw 'UpdateFramework did not classify both framework actions.' }
    if (@([regex]::Matches($commands, 'Verify_Framework.sql')).Count -ne 2) { throw 'UpdateFramework did not verify both framework actions.' }

    Remove-QuickTestLab -ScopeName synthetic-framework -StateRoot $stateRoot -Confirm:$false | Out-Null
}
finally {
    $env:PATH = $previousPath
    $env:FAKE_RUNTIME_ROOT = $previousFakeRoot
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output 'Docker/Podman quick-test UpdateFramework contracts passed.'
