[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'generated'),
    [string]$FrameworkOutputPath,
    [string]$TargetOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if ([string]::IsNullOrWhiteSpace($FrameworkOutputPath)) {
    $FrameworkOutputPath = Join-Path $OutputDirectory 'Install_SnapshotBaseline_Framework.generated.sql'
}
if ([string]::IsNullOrWhiteSpace($TargetOutputPath)) {
    $TargetOutputPath = Join-Path $OutputDirectory 'Install_SnapshotBaseline_Target.generated.sql'
}

$repositoryPrefix = $RepositoryRoot.TrimEnd([char[]]@(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)) + [IO.Path]::DirectorySeparatorChar
$includePattern = '(?m)^\s*:r\s+(.+?)\s*$'
$sqlCmdPattern = '(?im)^\s*:(?:ON\s+ERROR|r\s+).*$'
$leadingFrameworkContextPattern = '^\uFEFF?USE \[DeineDatenbank\];\r?\nGO\r?\n\r?\n'

function Get-InstallerDefinition {
    param(
        [Parameter(Mandatory)][string]$InstallerName,
        [Parameter(Mandatory)][string]$ArtifactLabel
    )

    $installerPath = Join-Path $PSScriptRoot $InstallerName
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        throw "Snapshot installer master is missing: $InstallerName"
    }

    $masterText = [IO.File]::ReadAllText($installerPath, [Text.Encoding]::UTF8)
    $includeMatches = [Text.RegularExpressions.Regex]::Matches($masterText, $includePattern)
    if ($includeMatches.Count -eq 0) {
        throw "Snapshot installer has no SQLCMD includes: $InstallerName"
    }

    $files = foreach ($includeMatch in $includeMatches) {
        $includePath = $includeMatch.Groups[1].Value.Trim().Trim('"')
        $candidate = Join-Path $PSScriptRoot $includePath
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Snapshot installer include is missing: $includePath"
        }

        $item = Get-Item -LiteralPath $candidate
        if ($item.Extension -ne '.sql') {
            throw "Snapshot installer include is not a SQL file: $includePath"
        }
        if (-not $item.FullName.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Snapshot installer include is outside the repository: $includePath"
        }
        $item
    }

    $duplicates = @($files | Group-Object FullName | Where-Object Count -gt 1)
    if ($duplicates.Count -gt 0) {
        throw "Snapshot installer contains duplicate SQLCMD includes: $InstallerName"
    }

    $builder = [Text.StringBuilder]::new()
    [void]$builder.AppendLine("/* Generated from canonical $ArtifactLabel source files. Do not edit directly. */")

    $masterPreamble = [Text.RegularExpressions.Regex]::Replace($masterText, $sqlCmdPattern, '').Trim()
    if (-not [string]::IsNullOrWhiteSpace($masterPreamble)) {
        [void]$builder.AppendLine()
        [void]$builder.AppendLine($masterPreamble)
    }

    foreach ($file in $files) {
        $relativePath = [IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName).Replace('\', '/')
        $content = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
        $content = [Text.RegularExpressions.Regex]::Replace(
            $content,
            $leadingFrameworkContextPattern,
            ''
        )

        [void]$builder.AppendLine()
        [void]$builder.AppendLine("-- BEGIN SOURCE: $relativePath")
        [void]$builder.AppendLine($content.TrimEnd())
        [void]$builder.AppendLine("-- END SOURCE: $relativePath")
    }

    $generatedText = $builder.ToString()
    if ([Text.RegularExpressions.Regex]::IsMatch($generatedText, '(?im)^\s*:(?:r|ON\s+ERROR)\b')) {
        throw "Generated snapshot installer still contains SQLCMD directives: $InstallerName"
    }

    [pscustomobject]@{
        InstallerName = $InstallerName
        Files = @($files)
        Text = $generatedText
    }
}

function Write-GeneratedInstaller {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory ('.' + [IO.Path]::GetFileName($fullPath) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')

    try {
        [IO.File]::WriteAllText($temporaryPath, $Content, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $fullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

$framework = Get-InstallerDefinition `
    -InstallerName 'Install_SnapshotBaseline_Framework.sql' `
    -ArtifactLabel 'Snapshot Baseline framework'
$target = Get-InstallerDefinition `
    -InstallerName 'Install_SnapshotBaseline_Target.sql' `
    -ArtifactLabel 'Snapshot Baseline target'

$overlap = @($framework.Files.FullName | Where-Object { $target.Files.FullName -contains $_ })
if ($overlap.Count -gt 0) {
    throw 'Snapshot framework and target installer closures overlap.'
}
if ([IO.Path]::GetFullPath($FrameworkOutputPath) -eq [IO.Path]::GetFullPath($TargetOutputPath)) {
    throw 'Framework and target output paths must be different.'
}

Write-GeneratedInstaller -Path $FrameworkOutputPath -Content $framework.Text
Write-GeneratedInstaller -Path $TargetOutputPath -Content $target.Text

Write-Host (
    "Generated $FrameworkOutputPath from $($framework.Files.Count) canonical SQL files and " +
    "$TargetOutputPath from $($target.Files.Count) canonical SQL files."
)
