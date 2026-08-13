#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-test-environment-$([guid]::NewGuid().ToString('N'))"
$stateRoot = Join-Path $temporaryRoot 'state'
$outputRoot = Join-Path $temporaryRoot 'Lab_Data/Exports'
$runId = [guid]::NewGuid().ToString()
$runDirectory = Join-Path (Join-Path $stateRoot 'runs') $runId
$previousDataRoot = $env:SQL_SERVER_LAB_DATA_ROOT
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Automated Test Environment Checks' -ForegroundColor Cyan

try {
    $null = New-Item -ItemType Directory -Path $runDirectory -Force
    [PSCustomObject]@{
        runId=$runId; scopeId=[guid]::NewGuid().ToString(); state='RUNNING'; createdAt=[datetime]::UtcNow.ToString('o')
        metadata=[PSCustomObject]@{name='test-linux-2022-latest'}; instances=@(); providerSubRuns=@(); errors=@()
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runDirectory 'run-state.json') -Encoding utf8
    [PSCustomObject]@{
        runId=$runId; instances=@([PSCustomObject]@{
            id='primary'; host='127.0.0.1'; port=15433; version='2022'; provider='docker'
            connectionString='Server=127.0.0.1,15433;Database=master;User ID=sa;Password=<set at creation>;Encrypt=True;TrustServerCertificate=True;'
        })
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runDirectory 'connection-info.json') -Encoding utf8

    $module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    Add-CheckResult -Name 'Öffentliche Cmdlets sind über das Modul verfügbar' -Success (
        $module.ExportedCommands.ContainsKey('New-SqlServerLabAutomatedTestEnvironment') -and
        $module.ExportedCommands.ContainsKey('Export-SqlServerLabTestEnvironment') -and
        $module.ExportedCommands.ContainsKey('Clear-SqlServerLabAutomatedTestEnvironment')
    )
    & $module {
        param($RunDirectory)
        $secret = [Security.SecureString]::new()
        foreach ($character in 'Random-Test-Password_42!'.ToCharArray()) { $secret.AppendChar($character) }
        $secret.MakeReadOnly()
        Save-LabSecret -Path $RunDirectory -Name 'sa-password' -Secret $secret
    } $runDirectory
    & $module {
        param($RunId,$OutputRoot)
        Register-LabTestEnvironmentRun -RunId $RunId -Platform linux -SqlVersion 2022 -Patch latest -InstanceId primary -OutputDirectory $OutputRoot
    } $runId $outputRoot | Out-Null
    $export = Export-SqlServerLabTestEnvironment -OutputDirectory $outputRoot -StateRoot $stateRoot
    $json = Get-Content -LiteralPath $export.JsonPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    $envText = Get-Content -LiteralPath $export.EnvPath -Raw -Encoding utf8
    $markdown = Get-Content -LiteralPath $export.MarkdownPath -Raw -Encoding utf8

    Add-CheckResult -Name 'Export liegt ausschließlich im expliziten Lab_Data-Ziel' -Success (
        $export.Directory -eq [IO.Path]::GetFullPath($outputRoot) -and
        -not $export.EnvPath.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)
    )
    Add-CheckResult -Name 'Vollständige Gruppe ist eindeutig als READY selektierbar' -Success (
        $json.contractVersion -eq 'SqlServerLab.TestEnvironment/1.0' -and $json.groupStatus -eq 'READY' -and
        @($json.environments | Where-Object {
            $_.platform -eq 'linux' -and $_.sqlVersion -eq '2022' -and $_.patch -eq 'latest' -and $_.status -eq 'READY'
        }).Count -eq 1
    )
    Add-CheckResult -Name 'ENV enthält stabile Präfixe, AutoStart und das zufällige Kennwort' -Success (
        $envText -match 'SQL_SERVER_LAB_TEST_ENV_GROUP_STATUS="READY"' -and
        $envText -match 'SQL_SERVER_LAB_LINUX_2022_LATEST_HOST="127\.0\.0\.1"' -and
        $envText -match 'SQL_SERVER_LAB_LINUX_2022_LATEST_PORT="15433"' -and
        $envText -match 'SQL_SERVER_LAB_LINUX_2022_LATEST_PASSWORD="Random-Test-Password_42!"' -and
        $envText -match 'SQL_SERVER_LAB_LINUX_2022_LATEST_AUTO_START="on"' -and
        $envText -match 'SQL_SERVER_LAB_DEFAULT_KEY="LINUX_2022_LATEST"'
    )
    $secondRunId = [guid]::NewGuid().ToString()
    $missingRunId = [guid]::NewGuid().ToString()
    & $module {
        param($SecondRunId,$MissingRunId,$OutputRoot)
        Register-LabTestEnvironmentRun -RunId $SecondRunId -Platform linux -SqlVersion 2022 -Patch latest -InstanceId primary -OutputDirectory $OutputRoot
        Register-LabTestEnvironmentRun -RunId $MissingRunId -Platform windows -SqlVersion 2019 -Patch cu32 -InstanceId primary -Name AAA_MISSING -OutputDirectory $OutputRoot
    } $secondRunId $missingRunId $outputRoot | Out-Null
    $incompleteExport = Export-SqlServerLabTestEnvironment -OutputDirectory $outputRoot -StateRoot $stateRoot
    $incompleteJson = Get-Content -LiteralPath $incompleteExport.JsonPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    $incompleteEnv = Get-Content -LiteralPath $incompleteExport.EnvPath -Raw -Encoding utf8
    $dataRoot = Split-Path -Parent $outputRoot
    & $module { param($DataRoot) $null = Initialize-LabManagedDataRoot -DataRoot $DataRoot } $dataRoot
    $env:SQL_SERVER_LAB_DATA_ROOT = $dataRoot
    $defaultExport = Export-SqlServerLabTestEnvironment -StateRoot $stateRoot
    Add-CheckResult -Name 'Standardexport wird aus dem konfigurierten Lab_Data abgeleitet' -Success (
        $defaultExport.Directory -eq [IO.Path]::GetFullPath($outputRoot)
    )
    Add-CheckResult -Name 'Unvollständige Gruppe gibt keinen einzelnen READY-Endpunkt frei' -Success (
        $incompleteJson.groupStatus -eq 'INCOMPLETE' -and
        @($incompleteJson.environments | Where-Object status -eq 'READY').Count -eq 0 -and
        $incompleteEnv -match 'SQL_SERVER_LAB_TEST_ENV_GROUP_STATUS="INCOMPLETE"' -and
        $incompleteEnv -notmatch 'SQL_SERVER_LAB_DEFAULT_KEY='
    )
    Add-CheckResult -Name 'Mehrere identische Ziele behalten getrennte Schlüssel' -Success (
        @($incompleteJson.environments | Where-Object key -eq 'LINUX_2022_LATEST').Count -eq 1 -and
        @($incompleteJson.environments | Where-Object key -eq 'LINUX_2022_LATEST_2').Count -eq 1
    )
    $passwords = & $module {
        $values = foreach ($unused in 1..2) {
            $secret = New-HyperVSqlUnattendedPassword
            $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
            try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        }
        return @($values)
    }
    Add-CheckResult -Name 'Jede Umgebung erhält ein eigenes kryptografisch erzeugtes Kennwort' -Success (
        @($passwords).Count -eq 2 -and $passwords[0].Length -eq 32 -and $passwords[1].Length -eq 32 -and $passwords[0] -ne $passwords[1]
    )
    Add-CheckResult -Name 'Markdown beschreibt KI-Auswahl und Klartextsecret-Risiko' -Success (
        $markdown -match 'groupStatus = READY' -and $markdown -match 'status = READY' -and $markdown -match 'Klartextkennwörter'
    )
    $lifecycleBlocked = $false
    try { Start-SqlServerLab -RunId $runId -StateRoot $stateRoot -ErrorAction Stop | Out-Null }
    catch { $lifecycleBlocked = $_.Exception.Message -match 'TEST_ENVIRONMENT_GROUP_PROTECTED' }
    Add-CheckResult -Name 'Öffentlicher Einzel-Lifecycle ist für Test-Runs gesperrt' -Success $lifecycleBlocked

    $clearOutput = Join-Path $temporaryRoot 'clear-test/Exports'
    & $module {
        param($ClearOutput)
        $null = Register-LabTestEnvironmentIntent -Platform linux -SqlVersion 2022 -Patch latest -InstanceId primary -OutputDirectory $ClearOutput
    } $clearOutput
    $null = Export-SqlServerLabTestEnvironment -OutputDirectory $clearOutput -StateRoot $stateRoot
    $clearResult = Clear-SqlServerLabAutomatedTestEnvironment -OutputDirectory $clearOutput -StateRoot $stateRoot -Force -Confirm:$false
    Add-CheckResult -Name 'Eigener Löschpunkt entfernt die vollständige Gruppe samt Exportdateien' -Success (
        $clearResult.Status -eq 'REMOVED' -and -not (Test-Path -LiteralPath (Join-Path $clearOutput 'TestUmgebung.registry.json')) -and
        -not (Test-Path -LiteralPath (Join-Path $clearOutput 'TestUmgebung.env'))
    )
    $menuText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1') -Raw -Encoding utf8
    $testEnvironmentText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/TestEnvironment.ps1') -Raw -Encoding utf8
    $clearText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Clear-SqlServerLab.ps1') -Raw -Encoding utf8
    $lifecycleText = @(
        'Start-SqlServerLab.ps1','Stop-SqlServerLab.ps1','Restart-SqlServerLab.ps1','Remove-SqlServerLab.ps1','Update-SqlServerLabContainer.ps1'
    ) | ForEach-Object { Get-Content -LiteralPath (Join-Path $repoRoot "Public/$_") -Raw -Encoding utf8 }
    Add-CheckResult -Name 'Hauptmenü bietet Batch-Erfassung für Linux und Windows an' -Success (
        $menuText -match "-Id 'automated-test' -Label 'Umgebung für automatisierte Tests anlegen'" -and
        $menuText -match "-Id 'clear-automated-test' -Label 'Alle automatisierten Testumgebungen löschen'" -and
        $menuText -match "\[l\] Linux hinzufügen  \[w\] Windows hinzufügen" -and
        $menuText -match "\[a\] Alle erstellen" -and
        $menuText -match "AutoStart='on'" -and
        $testEnvironmentText -match '-AutoStart on' -and
        $menuText -match 'DisableAutomatedTestEnvironments'
    )
    Add-CheckResult -Name 'Normale Lifecycle- und Cleanup-Pfade schützen die Testgruppe' -Success (
        @($lifecycleText | Where-Object { $_ -match 'TEST_ENVIRONMENT_GROUP_PROTECTED' }).Count -eq 5 -and
        $clearText -match 'Get-LabAutomatedTestEnvironmentRunIds' -and
        $clearText -match 'geschützte automatisierte Test-Runs'
    )
}
finally {
    $env:SQL_SERVER_LAB_DATA_ROOT = $previousDataRoot
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Host "`nErgebnis: $passed PASS, $($failures.Count) FAIL"
if ($failures.Count -gt 0) { exit 1 }
