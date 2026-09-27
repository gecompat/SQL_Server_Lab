# Dot-sourced by the Windows external runtime suite; no compiler or provider needed.
. (Join-Path $PSScriptRoot 'CSharpAcceptancePackageChecks.ps1')
. (Join-Path $repoRoot 'Tools/Common/ExternalRuntimeWindowsCSharpBuild.ps1')
$recipeRoot = Join-Path $repoRoot 'Tools/CSharpBuild'
$archiveLock = @(Get-Content (Join-Path $recipeRoot 'archives.lock.json') -Raw | ConvertFrom-Json)
$packageLock = Get-Content (Join-Path $recipeRoot 'packages.lock.json') -Raw | ConvertFrom-Json
$lockedPackages = @($packageLock.dependencies.'net8.0'.PSObject.Properties)
Add-CheckResult -Name 'CSharp: vollständiger Paket- und Referenzpack-Lock' -Success (
    $archiveLock.Count -eq 43 -and $lockedPackages.Count -eq 40 -and
    @($archiveLock | Group-Object Id | Where-Object Count -ne 1).Count -eq 0 -and
    @($lockedPackages | Where-Object {
        $id = $_.Name; $version = $_.Value.resolved
        @($archiveLock | Where-Object { $_.Id -ieq $id -and $_.Version -ceq $version }).Count -ne 1
    }).Count -eq 0
)
Add-CheckResult -Name 'CSharp: öffentliche NuGet-Quellen und SHA512 vollständig' -Success (
    @($archiveLock | Where-Object {
        $_.Sha512 -notmatch '^[A-Za-z0-9+/]{86}==$' -or
        $_.ArchiveUrl -cne "https://api.nuget.org/v3-flatcontainer/$($_.Id)/$($_.Version)/$($_.Id).$($_.Version).nupkg" -or
        $_.CatalogUrl -notlike 'https://api.nuget.org/v3/catalog0/data/*'
    }).Count -eq 0
)
$inputRoot = Join-Path $temporaryRoot 'csharp-inputs'
$outputRoot = Join-Path $temporaryRoot 'csharp-output'
$null = New-Item -ItemType Directory -Path $inputRoot
[IO.File]::WriteAllText((Join-Path $inputRoot 'source.zip'), 'synthetic corrupt source')
$caught = ''
try {
    Invoke-LabCSharpPackageBuild -Inputs $inputRoot -OutputRoot $outputRoot -Dotnet $PSHOME -VcVars $PSHOME -RecipeRoot $recipeRoot -ValidateInputsOnly
} catch { $caught = $_.Exception.Message }
Add-CheckResult -Name 'CSharp: falscher Quellhash vor Mutation abgewiesen' -Success (
    $caught -eq 'Input hash mismatch: source.zip' -and -not (Test-Path -LiteralPath $outputRoot)
)
$null = New-Item -ItemType Directory -Path $outputRoot
$sentinel = Join-Path $outputRoot 'sentinel.txt'
[IO.File]::WriteAllText($sentinel, 'synthetic existing output')
$caught = ''
try {
    Invoke-LabCSharpPackageBuild -Inputs $inputRoot -OutputRoot $outputRoot -Dotnet $PSHOME -VcVars $PSHOME -RecipeRoot $recipeRoot -ValidateInputsOnly
} catch { $caught = $_.Exception.Message }
Add-CheckResult -Name 'CSharp: vorhandener Output bleibt unverändert' -Success (
    $caught -eq 'Output root must not exist.' -and [IO.File]::ReadAllText($sentinel) -ceq 'synthetic existing output'
)
$caught = ''
try {
    Invoke-LabCSharpPackageBuild -Inputs $inputRoot -OutputRoot ($outputRoot + '&unsafe') -Dotnet $PSHOME -VcVars $PSHOME -RecipeRoot $recipeRoot -ValidateInputsOnly
} catch { $caught = $_.Exception.Message }
Add-CheckResult -Name 'CSharp: Shell-Metazeichen vor Mutation abgewiesen' -Success ($caught -eq 'Unsupported command-shell path character.')
$sourceText = Get-Content (Join-Path $repoRoot 'Tools/Common/ExternalRuntimeWindowsCSharpBuild.ps1') -Raw
Add-CheckResult -Name 'CSharp: Offline-, Versions- und Reproduzierbarkeitsgrenzen gebunden' -Success (
    $sourceText -match '--locked-mode' -and $sourceText -match 'ImportDirectoryBuildProps=false' -and
    $sourceText -match 'experimental:deterministic' -and $sourceText -match 'PathMap=' -and
    $sourceText -match '10\.0\.401' -and $sourceText -match '14\.51\.36231' -and
    $sourceText -match '10\.0\.26100\.0' -and $sourceText -match 'LatestPatch' -and
    $sourceText -match 'BUILT_NOT_SQL_VALIDATED' -and $sourceText -notmatch 'Invoke-WebRequest|Invoke-RestMethod|Start-Service|New-VM'
)
