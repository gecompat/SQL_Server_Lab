# Dot-sourced by Invoke-TestEnvironmentChecks: only synthetic contracts and runs.
$cuContract = $json | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
$cuContract.environments[0].patch = 'CU32'
$selectCu = {
    param($Contract, $Patch, $Version = '2022', $Platform = 'linux', $Provider = 'docker')
    Resolve-LabTestEnvironmentTarget -Contract $Contract -Platform $Platform -SqlVersion $Version -Patch $Patch -Provider $Provider
}
foreach ($spelling in @('CU32', 'Cu32', 'cu32', 'cU0032')) {
    $target = @(& $module $selectCu $cuContract $spelling)
    Add-CheckResult -Name "CU target resolves equivalent spelling $spelling" -Success ($target.Count -eq 1)
}
Add-CheckResult -Name 'Legacy CU contract validates before normalization and remains unchanged' -Success (
    ($cuContract | ConvertTo-Json -Depth 30 | Test-Json -SchemaFile $export.SchemaPath) -and
    $cuContract.environments[0].patch -ceq 'CU32'
)
foreach ($constraint in @(
    @{ Patch='cu31'; Version='2022'; Platform='linux'; Provider='docker' },
    @{ Patch='cu32'; Version='2019'; Platform='linux'; Provider='docker' },
    @{ Patch='cu32'; Version='2022'; Platform='windows'; Provider='docker' },
    @{ Patch='cu32'; Version='2022'; Platform='linux'; Provider='podman' },
    @{ Patch='base'; Version='2022'; Platform='linux'; Provider='docker' },
    @{ Patch='latest'; Version='2022'; Platform='linux'; Provider='docker' }
)) {
    $targets = @(& $module $selectCu $cuContract $constraint.Patch $constraint.Version $constraint.Platform $constraint.Provider)
    Add-CheckResult -Name "CU selection excludes $($constraint.Values -join '/')" -Success ($targets.Count -eq 0)
}
foreach ($label in @('base', 'latest')) {
    $cuContract.environments[0].patch = $label
    Add-CheckResult -Name "$label remains a distinct exact patch requirement" -Success (
        @(& $module $selectCu $cuContract $label).Count -eq 1 -and
        @(& $module $selectCu $cuContract 'cu32').Count -eq 0
    )
}
$cuContract.environments[0].patch = 'Cu00032'
Add-CheckResult -Name 'Legacy zero-padded CU contract remains readable' -Success (@(& $module $selectCu $cuContract 'CU32').Count -eq 1)
$cuContract.environments[0].patch = 'CU123456789012345678901234567890'
Add-CheckResult -Name 'CU normalization preserves large decimal numbers without overflow' -Success (
    @(& $module $selectCu $cuContract 'cu123456789012345678901234567890').Count -eq 1 -and
    @(& $module $selectCu $cuContract 'cu123456789012345678901234567891').Count -eq 0
)
$cuContract.environments[0].patch = 'Cu00032'
foreach ($invalid in @('', 'CU', 'CU0', 'cu000', 'CU-1', 'CU+1', 'CU3.2', 'CU1e2', 'CUfoo', 'CU32 ', ' CU32')) {
    $message = try { & $module $selectCu $cuContract $invalid | Out-Null; '' } catch { $_.Exception.Message }
    Add-CheckResult -Name "Invalid CU input rejected [$invalid]" -Success ($message -match '^TEST_ENVIRONMENT_(CU|PATCH)_INVALID:')
}
$cuContract.environments[0].patch = 'CU0'
$message = try { & $module $selectCu $cuContract 'CU32' | Out-Null; '' } catch { $_.Exception.Message }
Add-CheckResult -Name 'Invalid CU in schema-valid legacy contract fails without fallback' -Success ($message -match '^TEST_ENVIRONMENT_CU_INVALID:')
$cuContract.contractVersion = 'invalid'
$message = try { & $module $selectCu $cuContract 'CU0' | Out-Null; '' } catch { $_.Exception.Message }
Add-CheckResult -Name 'Original schema validation precedes semantic normalization' -Success ($message -match '^TEST_ENVIRONMENT_SCHEMA_INVALID:')
$cuContract.contractVersion = 'SqlServerLab.TestEnvironment/1.0'
$cuContract.environments[0].patch = 'cu32'
$cuContract.groupStatus = 'INCOMPLETE'
$cuContract.environments[0].status = 'GROUP_INCOMPLETE'
Add-CheckResult -Name 'CU normalization cannot bypass group readiness' -Success (@(& $module $selectCu $cuContract 'CU32').Count -eq 0)
$cuContract.environments[0].runtimeStatus = 'STOPPED'
Add-CheckResult -Name 'CU normalization cannot bypass runtime readiness' -Success (@(& $module $selectCu $cuContract 'CU32').Count -eq 0)

# Exercise the real registry -> resolved entries -> JSON/dotenv/Markdown export path.
# Existing Docker status is synthetic; restore registry bytes without rewriting legacy keys.
$cuRegistryPath = Join-Path $outputRoot 'TestUmgebung.registry.json'
$cuRegistryBytes = [IO.File]::ReadAllBytes($cuRegistryPath)
try {
    $cuRegistry = Get-Content -LiteralPath $cuRegistryPath -Raw | ConvertFrom-Json -Depth 30
    $cuRegistry.environments[0].patch = 'CU00032'
    $cuRegistry | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $cuRegistryPath -Encoding utf8
    $legacyBytes = [IO.File]::ReadAllBytes($cuRegistryPath)
    $cuExport = Export-SqlServerLabTestEnvironment -OutputDirectory $outputRoot -StateRoot $stateRoot
    $cuExportJson = Get-Content -LiteralPath $cuExport.JsonPath -Raw | ConvertFrom-Json -Depth 30
    Add-CheckResult -Name 'New exports canonicalize legacy CU across JSON dotenv and Markdown' -Success (
        $cuExportJson.environments[0].patch -ceq 'cu32' -and
        (Get-Content -LiteralPath $cuExport.EnvPath -Raw) -match '_PATCH="cu32"' -and
        (Get-Content -LiteralPath $cuExport.MarkdownPath -Raw) -match 'cu32' -and
        ((Get-Content -LiteralPath $cuExport.JsonPath -Raw) | Test-Json -SchemaFile $cuExport.SchemaPath)
    )
    Add-CheckResult -Name 'Export does not rewrite the legacy registry or its key' -Success (
        [Convert]::ToBase64String($legacyBytes) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($cuRegistryPath)) -and
        $cuExportJson.environments[0].key -ceq $cuRegistry.environments[0].key
    )
    $newIntent = & $module { param($OutputRoot) Register-LabTestEnvironmentIntent -Platform windows -SqlVersion 2019 -Patch CU00032 -InstanceId primary -OutputDirectory $OutputRoot } $outputRoot
    Add-CheckResult -Name 'New registry input and generated key use canonical CU number' -Success ($newIntent.patch -ceq 'cu32' -and $newIntent.key -ceq 'WINDOWS_2019_CU32')
} finally {
    [IO.File]::WriteAllBytes($cuRegistryPath, $cuRegistryBytes)
}
foreach ($spelling in @('CU32', 'Cu32', 'cu32')) {
    $patchOption = & $module { param($Cu) Get-SqlServerPatchOption -VersionId 2019 -Cu $Cu } $spelling
    Add-CheckResult -Name "Existing catalog resolver accepts $spelling" -Success ($patchOption.Cu -ieq 'CU32')
}
