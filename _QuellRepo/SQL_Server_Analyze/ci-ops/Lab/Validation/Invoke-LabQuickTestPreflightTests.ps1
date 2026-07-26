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
    'Lab/QuickTest/Private/Common.ps1'
    'Lab/QuickTest/Public/Invoke-QuickTestPreflight.ps1'
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

$credentialInput = New-QuickTestPassword -Length 24
if (-not (Test-QuickTestPassword -SecureValue $credentialInput)) {
    throw 'Generated quick-test credential does not satisfy the complexity contract.'
}

$ports = Get-QuickTestDefaultPorts
if (
    $ports[2019] -ne 14331 -or
    $ports[2022] -ne 14332 -or
    $ports[2025] -ne 14335
) {
    throw 'Quick-test default ports are not stable.'
}

$resolved = Resolve-QuickTestPorts `
    -SqlVersions @(2019, 2025) `
    -Ports @{ 2019 = 15431; 2025 = 15435 }
if ($resolved[2019] -ne 15431 -or $resolved[2025] -ne 15435) {
    throw 'Explicit quick-test ports were not preserved.'
}

$duplicateRejected = $false
try {
    Resolve-QuickTestPorts `
        -SqlVersions @(2019, 2022) `
        -Ports @{ 2019 = 15441; 2022 = 15441 } |
        Out-Null
}
catch {
    $duplicateRejected = $true
}
if (-not $duplicateRejected) {
    throw 'Duplicate quick-test ports were accepted.'
}

$small = Get-QuickTestResourceProfile -Name SMALL
$medium = Get-QuickTestResourceProfile -Name MEDIUM
$large = Get-QuickTestResourceProfile -Name LARGE
if (
    $small.ContainerMemoryMiB -ge $medium.ContainerMemoryMiB -or
    $medium.ContainerMemoryMiB -ge $large.ContainerMemoryMiB -or
    $small.SqlMemoryMiB -ge $small.ContainerMemoryMiB
) {
    throw 'Quick-test resource profiles are not ordered or bounded.'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'qt-preflight-' + [guid]::NewGuid().ToString('N')
)
$fakeBin = Join-Path $testRoot 'bin'
$dataRoot = Join-Path $testRoot 'data'
[IO.Directory]::CreateDirectory($fakeBin) | Out-Null
[IO.Directory]::CreateDirectory($dataRoot) | Out-Null
$fakeRuntime = Join-Path $fakeBin 'docker'
$fakeScript = @'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "version" ]; then exit 0; fi
if [ "$1" = "compose" ] && [ "$2" = "version" ]; then exit 0; fi
if [ "$1" = "container" ] && [ "$2" = "ls" ]; then exit 0; fi
if [ "$1" = "network" ] && [ "$2" = "ls" ]; then exit 0; fi
if [ "$1" = "manifest" ] && [ "$2" = "inspect" ]; then exit 0; fi
exit 2
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
try {
    $separator = [IO.Path]::PathSeparator
    $env:PATH = $fakeBin + $separator + $previousPath
    $ready = Invoke-QuickTestPreflight `
        -Runtime DOCKER `
        -SqlVersions @(2025) `
        -Ports @{ 2025 = 15451 } `
        -AdminLogin ExampleSqlAdmin `
        -AdminSecret $credentialInput `
        -ResourceProfile SMALL `
        -DataRoot $dataRoot `
        -ScopeName sql-analyze-quicktest `
        -AcceptEula

    if ($ready.Status -ne 'READY') {
        throw "Synthetic ready Preflight failed: $($ready.BlockerReasonCodes -join ',')"
    }
    if ($ready.MutationBoundary -ne 'READ_ONLY_PREFLIGHT') {
        throw 'Preflight does not expose the read-only mutation boundary.'
    }

    $env:PATH = $fakeBin
    $blocked = Invoke-QuickTestPreflight `
        -Runtime PODMAN `
        -SqlVersions @(2019, 2022) `
        -Ports @{ 2019 = 15461; 2022 = 15462 } `
        -AdminLogin ExampleSqlAdmin `
        -AdminSecret $credentialInput `
        -ResourceProfile SMALL `
        -DataRoot $dataRoot `
        -ScopeName sql-analyze-quicktest `
        -AcceptEula `
        -SkipImageAvailabilityCheck
    if (
        $blocked.Status -ne 'PREFLIGHT_FAILED' -or
        'RUNTIME_UNAVAILABLE' -notin @($blocked.BlockerReasonCodes)
    ) {
        throw 'Missing Podman runtime did not produce the structured blocker.'
    }
}
finally {
    $env:PATH = $previousPath
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output 'Docker/Podman quick-test Preflight contracts passed.'
