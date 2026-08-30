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
    $dataRoot = Split-Path -Parent $outputRoot
    & $module { param($DataRoot) $null = Initialize-LabManagedDataRoot -DataRoot $DataRoot } $dataRoot
    $env:SQL_SERVER_LAB_DATA_ROOT = $dataRoot
    Add-CheckResult -Name 'Öffentliche Cmdlets sind über das Modul verfügbar' -Success (
        $module.ExportedCommands.ContainsKey('New-SqlServerLabAutomatedTestEnvironment') -and
        $module.ExportedCommands.ContainsKey('Export-SqlServerLabTestEnvironment') -and
        $module.ExportedCommands.ContainsKey('Repair-SqlServerLabAutomatedTestEnvironment') -and
        $module.ExportedCommands.ContainsKey('Start-SqlServerLabAutomatedTestEnvironment') -and
        $module.ExportedCommands.ContainsKey('Stop-SqlServerLabAutomatedTestEnvironment') -and
        $module.ExportedCommands.ContainsKey('Clear-SqlServerLabAutomatedTestEnvironment')
    )
    & $module {
        param($RunDirectory)
        $secret = [Security.SecureString]::new()
        foreach ($character in 'Random-Test-Password_42!'.ToCharArray()) { $secret.AppendChar($character) }
        $secret.MakeReadOnly()
        Save-LabSecret -Path $RunDirectory -Name 'sa-password' -Secret $secret
    } $runDirectory
    $secretRoundTrip = & $module {
        param($RunDirectory)
        $secret = Get-LabSecret -Path $RunDirectory -Name 'sa-password'
        ConvertFrom-LabSecureString -SecureString $secret
    } $runDirectory
    Add-CheckResult -Name 'Secret-Store bewahrt Kennwörter plattformunabhängig und zeichengetreu' -Success (
        $secretRoundTrip -eq 'Random-Test-Password_42!'
    )
    & $module {
        param($RunId,$OutputRoot)
        Register-LabTestEnvironmentRun -RunId $RunId -Platform linux -SqlVersion 2022 -Patch latest -InstanceId primary -OutputDirectory $OutputRoot
    } $runId $outputRoot | Out-Null
    $reusedIntent = & $module {
        param($OutputRoot)
        Register-LabTestEnvironmentIntent -Platform linux -SqlVersion 2022 -Patch latest -InstanceId primary `
            -Name LINUX_2022_LATEST -OutputDirectory $OutputRoot -ReuseExisting
    } $outputRoot
    Add-CheckResult -Name 'Explizite Wiederaufnahme behält Schlüssel und registrierten Run idempotent bei' -Success (
        [string]$reusedIntent.key -eq 'LINUX_2022_LATEST' -and [string]$reusedIntent.runId -eq $runId
    )
    $canonicalRuntimeDisplayName = & $module {
        Get-LabAutomatedTestEnvironmentDisplayName -Key 'WINDOWS_2022_BASE'
    }
    Add-CheckResult -Name 'Registry-Schlüssel ergeben deterministische sprechende Runtime-Namen' -Success (
        $canonicalRuntimeDisplayName -eq 'test-windows-2022-base'
    )
    $statusSnapshot = & $module {
        param($OutputRoot,$StateRoot)
        Get-LabAutomatedTestEnvironmentStatus -OutputDirectory $OutputRoot -StateRoot $StateRoot
    } $outputRoot $stateRoot
    Add-CheckResult -Name 'Menüstatus projiziert bestehende Testumgebungen laufzeitnah ohne Zugangsdaten' -Success (
        $statusSnapshot.GroupStatus -eq 'INCOMPLETE' -and $statusSnapshot.Ready -eq 0 -and
        $statusSnapshot.Total -eq 1 -and $statusSnapshot.Entries[0].StatusCode -eq 'UNAVAILABLE' -and
        -not $statusSnapshot.Entries[0].PSObject.Properties['Password'] -and
        -not $statusSnapshot.Entries[0].PSObject.Properties['ConnectionString']
    )
    $unavailableExport = Export-SqlServerLabTestEnvironment -OutputDirectory $outputRoot -StateRoot $stateRoot
    $unavailableJson = Get-Content -LiteralPath $unavailableExport.JsonPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    Add-CheckResult -Name 'Gespeichertes RUNNING ohne erreichbaren Live-Provider wird nicht als READY exportiert' -Success (
        $unavailableJson.groupStatus -eq 'INCOMPLETE' -and
        $unavailableJson.environments[0].status -eq 'GROUP_INCOMPLETE' -and
        $unavailableJson.environments[0].runtimeStatus -eq 'UNAVAILABLE'
    )
    $originalDockerStatus = & $module { (Get-Command Get-DockerInstanceStatus).ScriptBlock }
    & $module {
        Set-Item Function:Get-DockerInstanceStatus -Value {
            param([string]$ContainerIdOrName)
            [PSCustomObject]@{ Exists=$true; Running=$true; Healthy=$false; AutoStart=$true; Inspect=$null; Raw='running' }
        }
    }
    $unhealthyExport = Export-SqlServerLabTestEnvironment -OutputDirectory $outputRoot -StateRoot $stateRoot
    $unhealthyJson = Get-Content -LiteralPath $unhealthyExport.JsonPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    Add-CheckResult -Name 'Gespeichertes RUNNING mit ungesundem Live-Container wird fail-closed exportiert' -Success (
        $unhealthyJson.groupStatus -eq 'INCOMPLETE' -and
        $unhealthyJson.environments[0].status -eq 'GROUP_INCOMPLETE' -and
        $unhealthyJson.environments[0].runtimeStatus -eq 'UNHEALTHY'
    )
    & $module {
        Set-Item Function:Get-DockerInstanceStatus -Value {
            param([string]$ContainerIdOrName)
            [PSCustomObject]@{ Exists=$true; Running=$true; Healthy=$true; AutoStart=$true; Inspect=$null; Raw='running' }
        }
    }
    $export = Export-SqlServerLabTestEnvironment -OutputDirectory $outputRoot -StateRoot $stateRoot
    $jsonText = Get-Content -LiteralPath $export.JsonPath -Raw -Encoding utf8
    $json = $jsonText | ConvertFrom-Json -Depth 20
    $envText = Get-Content -LiteralPath $export.EnvPath -Raw -Encoding utf8
    $markdown = Get-Content -LiteralPath $export.MarkdownPath -Raw -Encoding utf8

    Add-CheckResult -Name 'Export liegt ausschließlich im expliziten Lab_Data-Ziel' -Success (
        $export.Directory -eq [IO.Path]::GetFullPath($outputRoot) -and
        -not $export.EnvPath.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)
    )
    Add-CheckResult -Name 'JSON-Export verweist auf das mitexportierte und gültige Schema' -Success (
        $json.'$schema' -eq './TestUmgebung.schema.json' -and
        $export.SchemaPath -eq (Join-Path $outputRoot 'TestUmgebung.schema.json') -and
        (Test-Path -LiteralPath $export.SchemaPath -PathType Leaf) -and
        ($jsonText | Test-Json -SchemaFile $export.SchemaPath)
    )
    Add-CheckResult -Name 'Export veröffentlicht portable Discovery und den wiederverwendbaren Prompt' -Success (
        $export.PromptPath -eq (Join-Path $outputRoot 'TestUmgebung.prompt.md') -and
        (Test-Path -LiteralPath $export.PromptPath -PathType Leaf) -and
        $env:SQL_SERVER_LAB_TEST_ENV_FILE -eq $export.JsonPath -and
        $env:SQL_SERVER_LAB_TEST_ENV_SCHEMA_FILE -eq $export.SchemaPath -and
        $env:SQL_SERVER_LAB_TEST_ENV_PROMPT_FILE -eq $export.PromptPath -and
        (Get-Content -LiteralPath $export.PromptPath -Raw -Encoding utf8) -match 'Keine Laufwerks-, Home- oder Repositorysuche'
    )
    Add-CheckResult -Name 'Vollständige Gruppe ist eindeutig als READY selektierbar' -Success (
        $json.contractVersion -eq 'SqlServerLab.TestEnvironment/1.0' -and $json.groupStatus -eq 'READY' -and
        @($json.environments | Where-Object {
            $_.platform -eq 'linux' -and $_.sqlVersion -eq '2022' -and $_.patch -eq 'latest' -and $_.status -eq 'READY'
        }).Count -eq 1
    )
    $readyCenter = Get-SqlServerLabConnectionCenter -StateRoot $stateRoot
    Add-CheckResult -Name 'Vollständige Testgruppe erscheint mit stabilem Namen in der Verbindungszentrale' -Success (
        @($readyCenter.Entries | Where-Object { $_.RunId -eq $runId -and $_.DisplayName -eq 'TEST · LINUX_2022_LATEST (primary)' }).Count -eq 1
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
    $incompleteJsonText = Get-Content -LiteralPath $incompleteExport.JsonPath -Raw -Encoding utf8
    $incompleteJson = $incompleteJsonText | ConvertFrom-Json -Depth 20
    $incompleteEnv = Get-Content -LiteralPath $incompleteExport.EnvPath -Raw -Encoding utf8
    $incompleteCenter = Get-SqlServerLabConnectionCenter -StateRoot $stateRoot
    $defaultExport = Export-SqlServerLabTestEnvironment -StateRoot $stateRoot
    Add-CheckResult -Name 'Standardexport wird aus dem konfigurierten Lab_Data abgeleitet' -Success (
        $defaultExport.Directory -eq [IO.Path]::GetFullPath($outputRoot)
    )
    Add-CheckResult -Name 'Unvollständige Gruppe gibt keinen einzelnen READY-Endpunkt frei' -Success (
        $incompleteJson.groupStatus -eq 'INCOMPLETE' -and
        @($incompleteJson.environments | Where-Object status -eq 'READY').Count -eq 0 -and
        $incompleteEnv -match 'SQL_SERVER_LAB_TEST_ENV_GROUP_STATUS="INCOMPLETE"' -and
        $incompleteEnv -notmatch 'SQL_SERVER_LAB_DEFAULT_KEY=' -and
        ($incompleteJsonText | Test-Json -SchemaFile $incompleteExport.SchemaPath)
    )
    Add-CheckResult -Name 'Unvollständige Testgruppe wird auch im CMS-Katalog vollständig zurückgehalten' -Success (
        @($incompleteCenter.Entries | Where-Object RunId -eq $runId).Count -eq 0
    )
    Add-CheckResult -Name 'Mehrere identische Ziele behalten getrennte Schlüssel' -Success (
        @($incompleteJson.environments | Where-Object key -eq 'LINUX_2022_LATEST').Count -eq 1 -and
        @($incompleteJson.environments | Where-Object key -eq 'LINUX_2022_LATEST_2').Count -eq 1
    )
    & $module { param($Original) Set-Item Function:Get-DockerInstanceStatus -Value $Original } $originalDockerStatus
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
        -not (Test-Path -LiteralPath (Join-Path $clearOutput 'TestUmgebung.env')) -and
        -not (Test-Path -LiteralPath (Join-Path $clearOutput 'TestUmgebung.schema.json')) -and
        -not (Test-Path -LiteralPath (Join-Path $clearOutput 'TestUmgebung.prompt.md'))
    )
    $menuText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1') -Raw -Encoding utf8
    $batchConsoleText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/BatchConsole.ps1') -Raw -Encoding utf8
    $testEnvironmentText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/TestEnvironment.ps1') -Raw -Encoding utf8
    $hyperVLabText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVLabEnvironment.ps1') -Raw -Encoding utf8
    $clearText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Clear-SqlServerLab.ps1') -Raw -Encoding utf8
    $connectionCenterText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Sync-SqlServerLabConnectionCenter.ps1') -Raw -Encoding utf8
    $runtimeReadinessText = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-TestEnvironmentRuntimeReadiness.ps1') -Raw -Encoding utf8
    $acceptanceText = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-TestEnvironmentAcceptance.ps1') -Raw -Encoding utf8
    $groupLifecycleText = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-TestEnvironmentGroupLifecycle.ps1') -Raw -Encoding utf8
    $groupLifecycleCommandText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/TestEnvironmentLifecycle.ps1') -Raw -Encoding utf8
    $lifecycleText = @(
        'Start-SqlServerLab.ps1','Stop-SqlServerLab.ps1','Restart-SqlServerLab.ps1','Remove-SqlServerLab.ps1','Update-SqlServerLabContainer.ps1'
    ) | ForEach-Object { Get-Content -LiteralPath (Join-Path $repoRoot "Public/$_") -Raw -Encoding utf8 }
    Add-CheckResult -Name 'Providerneutraler Hauptpfad bietet Batch-Erfassung für Linux und Windows an' -Success (
        $menuText -match "-Id 'plan' -Label 'Umgebungen planen und erstellen'" -and
        $batchConsoleText -match "-Id 'add-sql' -Label 'SQL-Umgebung hinzufuegen'" -and
        $batchConsoleText -match "-Id 'add-windows'" -and
        $batchConsoleText -match "'Reine Windows-Umgebung hinzufuegen'" -and
        $batchConsoleText -match "-Id 'matrix' -Label 'Testmatrix erzeugen'" -and
        $batchConsoleText -match "ProviderPreference'\] = 'Auto'" -and
        $batchConsoleText -match "-Id 'review' -Label 'Gesamtplan pruefen und zur Queue uebergeben'" -and
        $menuText -match "-Id 'ClearAutomatedTestEnvironment' -Label 'Alle automatisierten Testumgebungen loeschen'" -and
        $menuText -match '-Id ''AutomatedTestEnvironmentLifecycle'' -Label \$testEnvironmentLifecycle\.Label' -and
        $menuText -match "'Automatisierte Testumgebung starten'" -and
        $menuText -match "'Automatisierte Testumgebung stoppen'" -and
        $testEnvironmentText -match 'function Get-LabAutomatedTestEnvironmentStatus' -and
        $testEnvironmentText -match '-AutoStart on' -and
        $menuText -match 'DisableAutomatedTestEnvironments'
    )
    Add-CheckResult -Name 'Cleanup zeigt Docker, Podman und Hyper-V mit explizitem Runtime-Status' -Success (
        $clearText -match "Id='docker'; Label='docker'" -and
        $clearText -match "Id='podman'; Label='podman'" -and
        $clearText -match "Id='hyperv'; Label='Hyper-V'" -and
        $clearText -match '\$auditBefore\.Audit\.HyperV\.Status'
    )
    $windowsPatchContract = & $module {
        $base = New-LabWindowsBaseSqlPatchIntent -BaseVersion '2022'
        $intent = [PSCustomObject]@{
            BaseVersion='2022'; VersionId='2022'; Patch=$base; RequiresWindows=$true
            Edition='Developer'; Purpose='adhoc'; NetworkMode='host-access'; Drives=@(); Cpu=[decimal]4
        }
        [PSCustomObject]@{
            Base=$base
            Decision=Resolve-LabSqlIntentProvider -Intent $intent -AvailableProviders @('hyperv')
        }
    }
    Add-CheckResult -Name 'Windows base benötigt kein CU-Paket und bleibt für Hyper-V zulässig' -Success (
        $windowsPatchContract.Base.PatchMode -eq 'base' -and
        -not $windowsPatchContract.Base.Cu -and
        -not $windowsPatchContract.Base.WindowsPath -and
        -not $windowsPatchContract.Base.Floating -and
        $windowsPatchContract.Decision.Supported -and
        $windowsPatchContract.Decision.Provider -eq 'hyperv' -and
        $menuText -match 'Select-LabSqlPatchIntent -BaseVersion \$sqlVersion -Platform \$platform' -and
        $menuText -notmatch 'latestWindowsPatch'
    )
    Add-CheckResult -Name 'Automatisierte Windows-Ziele entnehmen freie Slots aus dem Pool' -Success (
        $menuText -match 'PreferExistingWindowsSlot=\$true' -and
        $menuText -match 'Select-LabReusableHyperVWindowsSlotInteractive -Intent \$Intent -Automatic:\$automaticSlotSelection' -and
        $menuText -match 'ReusedWindowsSlotRunId' -and
        $menuText -match 'Rename-LabAutomatedTestEnvironmentRuntime -RunId \(\[string\]\$reusableSlot.RunId\)' -and
        $menuText -match 'Register-LabTestEnvironmentRun -RunId \(\[string\]\$reusableSlot.RunId\)' -and
        $menuText -match 'Freier Windows-Slot wird automatisch aus dem Pool entnommen' -and
        $menuText -match 'Get-LabAutomatedTestEnvironmentRunIds' -and
        $menuText -match '\$intendedTestRunId' -and
        $menuText -match "'PLANNED', 'INSTALL_RETRY_PENDING', 'CONFIGURATION_PENDING'" -and
        $menuText -match 'SQL-Testumgebung ist bereits vollständig bereit' -and
        $testEnvironmentText -match '\[switch\]\$ReuseExisting' -and
        $menuText -match '-ReuseExisting:' -and
        $menuText -match 'Set-HyperVLabAutoStart -RunId \(\[string\]\$Slot.RunId\)' -and
        $hyperVLabText -match 'function Set-HyperVLabAutoStart' -and
        $hyperVLabText -match 'AutomaticStartAction \$automaticStartAction' -and
        $menuText -match 'WindowsActivationRequired=\$true' -and
        $menuText -match 'Invoke-HyperVWindowsSlotActivation -RunId' -and
        $menuText -notmatch 'WindowsActivationSwitchName=\$windowsActivation.ExternalSwitchName' -and
        $menuText -notmatch 'WindowsProductKey=\$windowsActivation.ProductKey' -and
        $menuText -notmatch 'RequiresFreshSqlInstall=\$true; ForceNewWindowsSlot=\$true'
    )
    Add-CheckResult -Name 'Windows-Testslots aktivieren die Child-VM sicher über eine temporäre External-NIC' -Success (
        $hyperVLabText -match 'function Get-HyperVWindowsSlotLicenseStatus' -and
        $hyperVLabText -match 'function Resolve-HyperVWindowsActivationExternalSwitch' -and
        $hyperVLabText -match 'function Invoke-HyperVWindowsSlotActivation' -and
        $hyperVLabText -match "if \(\[string\]\`$current.State -in @\('EVALUATION_ACTIVE','LICENSED'\)\) \{ return \`$current \}" -and
        $hyperVLabText -notmatch "\[Parameter\(Mandatory\)\]\[SecureString\]\`$ProductKey" -and
        $hyperVLabText -match 'Get-VMSwitch -SwitchType External' -and
        $hyperVLabText -match 'SQL_SERVER_LAB_ACTIVATION_TEMP' -and
        $hyperVLabText -match "MethodName Activate" -and
        $hyperVLabText -match 'evaluationMinutesRemaining' -and
        $hyperVLabText -match "State EVALUATION_ACTIVE" -and
        $hyperVLabText -match 'finally\s*\{[\s\S]+Remove-VMNetworkAdapter' -and
        $hyperVLabText -notmatch "Save-LabSecret[^\r\n]+ProductKey|Write-LabArtifactJsonAtomic[^\r\n]+ProductKey"
    )
    Add-CheckResult -Name 'Batch-Linux-Erfolg hängt nicht vom noch unvollständigen Gruppenstatus ab' -Success (
        $menuText -match 'TEST_ENVIRONMENT_CREATION_FAILED' -and
        $menuText -notmatch 'TEST_ENVIRONMENT_GROUP_INCOMPLETE'
    )
    Add-CheckResult -Name 'Automatisierte Linux-Ziele verwenden belastbare Runtime- und SQL-Memory-Grenzen' -Success (
        $testEnvironmentText -match '\$name = Get-LabAutomatedTestEnvironmentDisplayName -Key \$request.Key' -and
        $testEnvironmentText -match '-Profile standard' -and
        $testEnvironmentText -match '-Cpu 4 -MemoryMB 4096' -and
        $testEnvironmentText -match 'maxMB = 3072' -and
        $testEnvironmentText -notmatch 'New-SqlServerLab[^\r\n]+-Profile compact'
    )
    Add-CheckResult -Name 'Gruppenreparatur konvergiert Ressourcen, Autostart und sprechende Runtime-Namen' -Success (
        $testEnvironmentText -match 'function Repair-SqlServerLabAutomatedTestEnvironment' -and
        $testEnvironmentText -match 'function Rename-LabAutomatedTestEnvironmentRuntime' -and
        $testEnvironmentText -match 'Get-LabAutomatedTestEnvironmentDisplayName' -and
        $testEnvironmentText -match 'Update-SqlServerLabContainer[^\r\n]+-Cpu 4 -MemoryMB 4096' -and
        $testEnvironmentText -match '-AutoStart on' -and
        $testEnvironmentText -match '-RepairSqlRuntimeContract' -and
        $testEnvironmentText -match 'Set-LabServerConfig' -and
        $testEnvironmentText -match 'Stop-HyperVInstance' -and
        $testEnvironmentText -match 'Start-HyperVInstance' -and
        $testEnvironmentText -match 'Start-SqlServerLabAutomatedTestEnvironment -TimeoutSeconds \$ReadinessTimeoutSeconds' -and
        $testEnvironmentText -notmatch '\[SecureString\]\$WindowsProductKey' -and
        $testEnvironmentText -match '\[string\]\$WindowsActivationSwitchName' -and
        $testEnvironmentText -match 'Invoke-HyperVWindowsSlotActivation -RunId \$runId' -and
        $testEnvironmentText -match 'Rename-ContainerLabEnvironment' -and
        $testEnvironmentText -match 'Rename-HyperVLabEnvironment' -and
        $testEnvironmentText -match 'maxMB = 3072' -and
        $testEnvironmentText -match 'Export-SqlServerLabTestEnvironment' -and
        $testEnvironmentText -match 'LabAutomatedTestEnvironmentGroupOperation = \$true'
    )
    Add-CheckResult -Name 'Testgruppe synchronisiert Verbindungszentrale und CMS explizit und atomar sichtbar' -Success (
        $testEnvironmentText -match 'function Sync-LabAutomatedTestEnvironmentConnectionCenter' -and
        $testEnvironmentText -match 'Sync-SqlServerLabCms -StateRoot \$StateRoot -Quiet' -and
        $connectionCenterText -match 'if \(\$isAutomatedTestEnvironment -and -not \$testGroupReady\) \{ continue \}' -and
        $connectionCenterText -match 'TEST · \$\(\[string\]\$testEnvironment.key\)'
    )
    Add-CheckResult -Name 'CMS-Menü nennt Zielserver und korrekten SSMS-Anzeigeort' -Success (
        $connectionCenterText -match 'SSMS-CMS-Server:' -and
        $connectionCenterText -match 'Ansicht -> Registrierte Server -> Datenbankmodul -> Zentrale Verwaltungsserver' -and
        $connectionCenterText -match "SQL Server Lab -> Running" -and
        $connectionCenterText -match '\$center\.Entries = @\(\$center\.Entries \| Where-Object \{ \[string\]\$_\.RunId -ne \[string\]\$cmsConfiguration\.RunId \}\)'
    )
    Add-CheckResult -Name 'Normale Lifecycle- und Cleanup-Pfade schützen die Testgruppe' -Success (
        @($lifecycleText | Where-Object { $_ -match 'TEST_ENVIRONMENT_GROUP_PROTECTED' }).Count -eq 5 -and
        $clearText -match 'Get-LabAutomatedTestEnvironmentRunIds' -and
        $clearText -match 'geschützte automatisierte Test-Runs'
    )
    Add-CheckResult -Name 'Oeffentlicher Gruppen-Lifecycle bleibt scopegebunden, bestaetigt und nicht-destruktiv' -Success (
        $groupLifecycleCommandText -match 'function Start-SqlServerLabAutomatedTestEnvironment' -and
        $groupLifecycleCommandText -match 'function Stop-SqlServerLabAutomatedTestEnvironment' -and
        @($groupLifecycleCommandText -split '\r?\n' | Where-Object { $_ -match 'CmdletBinding\(SupportsShouldProcess' }).Count -eq 2 -and
        $groupLifecycleCommandText -match "platform -eq 'windows'" -and
        $groupLifecycleCommandText -match 'ExpectedRunId' -and
        $groupLifecycleCommandText -match 'ExpectedScopeId' -and
        $groupLifecycleCommandText -match 'Invoke-HyperVPowerShellDirect' -and
        $groupLifecycleCommandText -match 'Get-HyperVWindowsSlotLicenseStatus' -and
        $groupLifecycleCommandText -match 'TEST_ENVIRONMENT_WINDOWS_ACTIVATION_REQUIRED' -and
        $groupLifecycleCommandText -match 'Wait-SqlReady' -and
        $groupLifecycleCommandText -match 'Start-HyperVLabEnvironment' -and
        $groupLifecycleCommandText -match 'Stop-HyperVLabEnvironment' -and
        @($groupLifecycleCommandText -split '\r?\n' | Where-Object { $_ -match 'Export-SqlServerLabTestEnvironment' }).Count -eq 2 -and
        $groupLifecycleCommandText -notmatch 'Remove-SqlServerLab|Clear-SqlServerLabAutomatedTestEnvironment|Remove-VM'
    )
    Add-CheckResult -Name 'Gruppen-Lifecycle umfasst Docker, Podman und Hyper-V bei erhaltenem Einzelschutz' -Success (
        $groupLifecycleCommandText -match 'Get-LabAutomatedTestEnvironmentRegisteredEntries' -and
        $groupLifecycleCommandText -match "provider -in @\('docker','podman'\)" -and
        $groupLifecycleCommandText -match 'Start-SqlServerLab -RunId \$runId -SkipReadyCheck' -and
        $groupLifecycleCommandText -match 'Stop-SqlServerLab -RunId \$runId' -and
        $groupLifecycleCommandText -match 'Get-LabAutomatedTestEnvironmentExpectedMajorVersion' -and
        $groupLifecycleCommandText -match 'LabAutomatedTestEnvironmentGroupOperation = \$true' -and
        $lifecycleText -match '-not \[bool\]\$script:LabAutomatedTestEnvironmentGroupOperation'
    )
    Add-CheckResult -Name 'Recovery und Runtime-Nachweis verwenden nur den oeffentlichen Gruppen-Lifecycle' -Success (
        $runtimeReadinessText -match 'Start-SqlServerLabAutomatedTestEnvironment' -and
        $runtimeReadinessText -notmatch 'Get-LabSecret|Start-HyperVLabEnvironment|Invoke-HyperVPowerShellDirect' -and
        $groupLifecycleText -match 'Start-SqlServerLabAutomatedTestEnvironment' -and
        $groupLifecycleText -match 'finally' -and
        $groupLifecycleText -match 'Stop-SqlServerLabAutomatedTestEnvironment' -and
        $groupLifecycleText -match 'BindingsPreserved' -and
        $groupLifecycleText -match 'ProvidersPreserved' -and
        $groupLifecycleText -match "GroupStatus -ne 'INCOMPLETE'" -and
        $groupLifecycleText -match 'MembersRestored' -and
        $groupLifecycleText -match "GroupStatus -ne 'READY'" -and
        @($groupLifecycleText -split '\r?\n' | Where-Object { $_ -match 'Start-SqlServerLabAutomatedTestEnvironment' }).Count -ge 2 -and
        $groupLifecycleText -notmatch 'Remove-SqlServerLab|Clear-SqlServerLabAutomatedTestEnvironment'
    )
    Add-CheckResult -Name 'Gemeinsame Runtime-Abnahme bindet jede SQL-Jahresversion an ihre echte Major-Version' -Success (
        $acceptanceText -match "'2019' \{ 15 \}" -and
        $acceptanceText -match "'2022' \{ 16 \}" -and
        $acceptanceText -match "'2025' \{ 17 \}" -and
        $acceptanceText -match "SERVERPROPERTY\('ProductMajorVersion'\)" -and
        $acceptanceText -match 'TEST_ENVIRONMENT_VERSION_MISMATCH'
    )
}
finally {
    $env:SQL_SERVER_LAB_DATA_ROOT = $previousDataRoot
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Host "`nErgebnis: $passed PASS, $($failures.Count) FAIL"
if ($failures.Count -gt 0) { exit 1 }
