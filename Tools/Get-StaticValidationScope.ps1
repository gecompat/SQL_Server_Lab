#Requires -Version 7.2
<#
.SYNOPSIS
    Resolves a conservative file scope for local Pester and analyzer checks.
.DESCRIPTION
    Missing dependency knowledge, shared module/configuration inputs, and no
    explicit development scope retain full validation. Global integration and
    qualification calls omit ChangedPath. Scopes never traverse runtime roots.
#>
[CmdletBinding()]
param([string[]]$ChangedPath)
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$paths=@($ChangedPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Replace('\','/') } | Sort-Object -Unique)
foreach ($path in $paths) {
    if ([IO.Path]::IsPathRooted($path) -or $path -match '(^|/)\.\.(/|$)' -or $path -match '^\.(artifacts|runtime|state|secrets|cache|local)/') { throw 'STATIC_SCOPE_PATH_INVALID' }
}
$global=$paths.Count -eq 0 -or @($paths | Where-Object {
    $_ -match '^(SqlServerLab\.|Tests/Static/PSScriptAnalyzerSettings|Tests/Common/|\.github/workflows/)' -or
    $_ -match '^(Schemas|Catalogs)/' -or
    ($_ -match '^(Tools|Tests)/' -and $_ -notmatch '^Tests/Pester/[^/]+\.Tests\.ps1$|^Tests/Static/(Invoke-PesterChecks|Invoke-PSScriptAnalyzerChecks)\.ps1$|^Tools/Get-StaticValidationScope\.ps1$') -or
    $_ -notmatch '^(Private|Public|Providers|Adapters|Tools|Tests|Documentation|Schemas|Catalogs|Ui|\.ai)/|^(AGENTS|README|CONTRIBUTING|SECURITY)\.md$'
}).Count -gt 0
$pester=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($path in $paths) {
    if ($path -match '^Tests/Pester/[^/]+\.Tests\.ps1$') { [void]$pester.Add($path) }
    # Module import/export is shared by every product PowerShell source.
    if ($path -match '^(Private|Public|Providers|Adapters)/.*\.(ps1|psm1|psd1)$|PSScriptAnalyzer|Invoke-PesterChecks|Get-StaticValidationScope') { [void]$pester.Add('Tests/Pester/SqlServerLab.Module.Tests.ps1') }
    if ($path -match 'TestEnvironment|TestGroup|ContainerAutoStart|RuntimeStateSync|HyperVLabEnvironment|CleanupEngine|StateMachine') { [void]$pester.Add('Tests/Pester/TestEnvironmentLifecycle.Tests.ps1') }
    if ($path -match 'PrivacyScanner|\.gitignore') { [void]$pester.Add('Tests/Pester/PrivacyScanner.Tests.ps1') }
}
if ($global) { $pester.Clear(); foreach($file in Get-ChildItem -LiteralPath (Join-Path $root 'Tests/Pester') -Filter '*.Tests.ps1' -File) { [void]$pester.Add([IO.Path]::GetRelativePath($root,$file.FullName).Replace('\','/')) } }
$analyzer=@($paths | Where-Object { $_ -match '\.(ps1|psm1)$' -and (Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf) })
[pscustomobject]@{ Global=$global; Pester=@($pester | Sort-Object); Analyzer=$analyzer }
