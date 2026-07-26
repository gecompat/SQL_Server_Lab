[CmdletBinding()]
param([string]$RepositoryRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
}
else {
    $RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
}

$installer = Join-Path $RepositoryRoot 'Code/Install/Install_All.sql'
$builder = Join-Path $RepositoryRoot 'Code/Install/Build-StandaloneInstaller.ps1'
foreach ($path in @($installer, $builder)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "STANDALONE_INSTALLER_FILE_MISSING: $([IO.Path]::GetFileName($path))"
    }
}

$builderText = Get-Content -LiteralPath $builder -Raw -Encoding UTF8
if ($builderText -notmatch 'generated/Install_All\.generated\.sql') {
    throw 'STANDALONE_DEFAULT_OUTPUT_DIRECTORY_INVALID'
}

$masterText = Get-Content -LiteralPath $installer -Raw -Encoding UTF8
$includes = @([Text.RegularExpressions.Regex]::Matches($masterText, '(?m)^\s*:r\s+(.+?)\s*$'))
if ($includes.Count -eq 0) {
    throw 'STANDALONE_MASTER_HAS_NO_INCLUDES'
}

$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('sql-server-analyze-standalone-' + [guid]::NewGuid().ToString('N'))
$outputPath = Join-Path $testDirectory 'nested/Install_All.generated.sql'
try {
    & $builder -RepositoryRoot $RepositoryRoot -OutputPath $outputPath
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw 'STANDALONE_GENERATED_FILE_MISSING'
    }

    $generatedText = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8
    if ($generatedText -match '(?im)^\s*:(?:r|ON\s+ERROR)\b') {
        throw 'STANDALONE_GENERATED_SQLCMD_DIRECTIVE_FOUND'
    }
    $sourceMarkers = @([Text.RegularExpressions.Regex]::Matches($generatedText, '(?m)^-- BEGIN SOURCE: (.+?)$'))
    if ($sourceMarkers.Count -ne $includes.Count) {
        throw 'STANDALONE_GENERATED_SOURCE_COUNT_INVALID'
    }
    if (@([Text.RegularExpressions.Regex]::Matches($generatedText, '(?im)^USE \[DeineDatenbank\];\r?$')).Count -ne 1) {
        throw 'STANDALONE_DATABASE_CONTEXT_COUNT_INVALID'
    }

    $firstHash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash
    & $builder -RepositoryRoot $RepositoryRoot -OutputPath $outputPath
    $secondHash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash
    if ($firstHash -ne $secondHash) {
        throw 'STANDALONE_GENERATION_NOT_DETERMINISTIC'
    }
}
finally {
    if (Test-Path -LiteralPath $testDirectory) {
        Remove-Item -LiteralPath $testDirectory -Recurse -Force
    }
}

Write-Host "Standalone installer contract passed: $($includes.Count) canonical includes."
