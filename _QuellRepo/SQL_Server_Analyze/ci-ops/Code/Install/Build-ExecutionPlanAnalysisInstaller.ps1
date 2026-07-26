param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")),
    [string]$OutputPath = (Join-Path $PSScriptRoot "generated/Install_ExecutionPlanAnalysis.generated.sql")
)

$ErrorActionPreference = "Stop"
$sqlCmdInstaller = Join-Path $PSScriptRoot "Install_ExecutionPlanAnalysis.sql"
$includePattern = '(?m)^\s*:r\s+(.+?)\s*$'
$includeMatches = [Text.RegularExpressions.Regex]::Matches(
    [IO.File]::ReadAllText($sqlCmdInstaller, [Text.Encoding]::UTF8),
    $includePattern
)

if ($includeMatches.Count -eq 0) {
    throw "Install_ExecutionPlanAnalysis.sql enthält keine SQLCMD-Includes."
}

$files = foreach ($includeMatch in $includeMatches) {
    $includePath = $includeMatch.Groups[1].Value.Trim().Trim('"')
    Get-Item -LiteralPath (Join-Path $PSScriptRoot $includePath)
}

$duplicateFiles = $files | Group-Object FullName | Where-Object Count -gt 1
if ($duplicateFiles) {
    throw "Install_ExecutionPlanAnalysis.sql enthält doppelte SQLCMD-Includes."
}

$builder = [System.Text.StringBuilder]::new()
[void]$builder.AppendLine("USE [DeineDatenbank];")
[void]$builder.AppendLine("GO")
[void]$builder.AppendLine()
[void]$builder.AppendLine("/* Generated from canonical Execution Plan Analysis source files. Do not edit directly. */")

foreach ($file in $files) {
    $relative = [IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName).Replace('\','/')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine("-- BEGIN SOURCE: $relative")
    $content = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
    $content = [Text.RegularExpressions.Regex]::Replace($content, '^\uFEFF?USE \[DeineDatenbank\];\r?\nGO\r?\n\r?\n', '')
    [void]$builder.AppendLine($content.TrimEnd())
    [void]$builder.AppendLine("-- END SOURCE: $relative")
}

$outputDirectory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath))
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}

[IO.File]::WriteAllText($OutputPath, $builder.ToString(), [Text.UTF8Encoding]::new($false))
Write-Host "Generated $OutputPath from $($files.Count) canonical SQL files."
