#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')

try {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop
    $poolCommand = Get-Command New-SqlServerLabWindowsSlotPool -Module SqlServerLab -ErrorAction Stop
    $accessCommand = Get-Command Get-SqlServerLabGeneratedWindowsAccess -Module SqlServerLab -ErrorAction Stop

    Add-CheckResult -Name 'Windows-Slot-Pool und Zugangsausgabe sind öffentlich exportiert' -Success (
        $poolCommand -and $accessCommand)
    Add-CheckResult -Name 'RAM-Standards sind 1024/2048/4096 MB' -Success (
        $poolCommand.Parameters.MemoryMinimumMB.Attributes.Where({ $_ -is [Management.Automation.ParameterAttribute] }).Count -ge 1 -and
        $poolCommand.Definition -match '\$MemoryMinimumMB\s*=\s*1024' -and
        $poolCommand.Definition -match '\$MemoryStartupMB\s*=\s*2048' -and
        $poolCommand.Definition -match '\$MemoryMaximumMB\s*=\s*4096')

    $behavior = & $module {
        $originalIsWindows = Get-Variable -Name IsWindows -Scope Script -ErrorAction SilentlyContinue
        Set-Variable -Name IsWindows -Scope Script -Value $true -Force
        try {
        $script:poolLabs = @{}
        $script:createCalls = [Collections.Generic.List[object]]::new()
        $script:provisionCalls = [Collections.Generic.List[object]]::new()
        $script:stopCalls = [Collections.Generic.List[string]]::new()
        $script:slotNumber = 0

        function Test-LabAdministrator { $true }
        function Test-HyperVAvailable { [PSCustomObject]@{ Available=$true; Message='ok' } }
        function Resolve-LabWindowsSlotPoolArtifact {
            [PSCustomObject]@{
                artifactId = "hyperv-os-sealed-$('a' * 64)"
                artifactState = 'OS_SEALED'; generalized = $true; registeredAt = '2026-09-01T00:00:00Z'
                operatingSystem = [PSCustomObject]@{ id='windows-server-2025'; version='2025'; language='en-US' }
            }
        }
        function Assert-LabWindowsSlotPoolLocale { param($Region,$SystemLocale,$UiLanguage,$InputLocale,$TimeZone,$Artifact) }
        function Get-LabActiveRuns { @() }
        function New-HyperVLabEnvironment {
            param($ArtifactId,$LabName,$InstanceId,$DynamicMemoryEnabled,$MemoryMinimumMB,$MemoryStartupMB,$MemoryMaximumMB,$ProcessorCount,$AutoStart,$NetworkIntent,$StateRoot)
            $script:slotNumber++
            $runId = "run-$($script:slotNumber)"
            $scopeId = "scope-$($script:slotNumber)"
            $vmName = "vm-$($script:slotNumber)"
            $lab = [PSCustomObject]@{
                RunDirectory = "X:\state\$runId"
                Run = [PSCustomObject]@{ runId=$runId; scopeId=$scopeId; metadata=[PSCustomObject]@{ name=$LabName; networkIntent='hostOnly' } }
                Instance = [PSCustomObject]@{
                    provider='hyperv'; workload='windows'; imageArtifactId=$ArtifactId; vmName=$vmName
                    resourceSettings=[PSCustomObject]@{
                        dynamicMemoryEnabled=$true; memoryMinimumMB=$MemoryMinimumMB
                        memoryStartupMB=$MemoryStartupMB; memoryMaximumMB=$MemoryMaximumMB
                        processorCount=$ProcessorCount
                    }
                    windowsProvisioning=[PSCustomObject]@{ state='PENDING' }
                    oobeAutomation=[PSCustomObject]@{ status='PENDING'; passwordSource=$null }
                }
            }
            $script:poolLabs[$runId] = $lab
            $script:createCalls.Add([PSCustomObject]@{
                Name=$LabName; Minimum=$MemoryMinimumMB; Startup=$MemoryStartupMB
                Maximum=$MemoryMaximumMB; ProcessorCount=$ProcessorCount
            })
            [PSCustomObject]@{ RunId=$runId; VMName=$vmName }
        }
        function Get-HyperVLabWorkflowRun { param($RunId,$StateRoot) $script:poolLabs[$RunId] }
        function Get-HyperVInstanceStatus { [PSCustomObject]@{ Exists=$true; State='Off' } }
        function Get-LabSecret { $null }
        function New-HyperVSqlUnattendedPassword {
            $secure = [Security.SecureString]::new()
            foreach ($character in 'Synthetic-Only!123'.ToCharArray()) { $secure.AppendChar($character) }
            $secure.MakeReadOnly()
            $secure
        }
        function Invoke-HyperVLabUnattendedProvision {
            param($RunId,$AdministratorPassword,$PasswordSource,$Region,$SystemLocale,$UiLanguage,$InputLocale,$TimeZone,$StateRoot)
            $script:provisionCalls.Add([PSCustomObject]@{
                RunId=$RunId; PasswordSource=$PasswordSource; Region=$Region; SystemLocale=$SystemLocale
                UiLanguage=$UiLanguage; InputLocale=$InputLocale; TimeZone=$TimeZone
            })
            $script:poolLabs[$RunId].Instance.windowsProvisioning.state = 'COMPLETE'
            $script:poolLabs[$RunId].Instance.oobeAutomation.status = 'COMPLETED'
            $script:poolLabs[$RunId].Instance.oobeAutomation.passwordSource = $PasswordSource
        }
        function Stop-HyperVLabEnvironment { param($RunId,$StateRoot) $script:stopCalls.Add($RunId) }

        $result = New-SqlServerLabWindowsSlotPool -Count 2 -GenerateAdministratorPasswords `
            -StateRoot 'X:\state' -Confirm:$false
        [PSCustomObject]@{
            Result=$result; Creates=@($script:createCalls); Provisions=@($script:provisionCalls); Stops=@($script:stopCalls)
        }
        }
        finally {
            if ($originalIsWindows) {
                Set-Variable -Name IsWindows -Scope Script -Value ([bool]$originalIsWindows.Value) -Force
            }
            else {
                Remove-Variable -Name IsWindows -Scope Script -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Add-CheckResult -Name 'Pool erstellt zwei Slots mit den gebundenen Standardressourcen' -Success (
        $behavior.Result.Status -eq 'COMPLETE' -and @($behavior.Result.Slots).Count -eq 2 -and
        @($behavior.Creates | Where-Object { $_.Minimum -eq 1024 -and $_.Startup -eq 2048 -and $_.Maximum -eq 4096 -and $_.ProcessorCount -eq 4 }).Count -eq 2)
    Add-CheckResult -Name 'OOBE verwendet pro Slot den generierten Passwortmodus und Locale-Vertrag' -Success (
        @($behavior.Provisions).Count -eq 2 -and
        @($behavior.Provisions | Where-Object {
            $_.PasswordSource -eq 'generated' -and $_.Region -eq 'AT' -and $_.SystemLocale -eq 'de-AT' -and
            $_.UiLanguage -eq 'en-US' -and $_.InputLocale -eq '0407:00000407'
        }).Count -eq 2 -and @($behavior.Stops).Count -eq 2)

    $poolSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\New-SqlServerLabWindowsSlotPool.ps1') -Raw -Encoding utf8
    $uiSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\Invoke-SqlServerLab.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Pool ist resumierbar und lehnt eine ungeeignete Baseline ab' -Success (
        $poolSource -match 'HYPERV_WINDOWS_SLOT_POOL_BASELINE_REQUIRED' -and
        $poolSource -match "Action='REUSED'" -and
        $poolSource -match 'MinimumEvaluationDaysRemaining')
    Add-CheckResult -Name 'CLI fragt RAM, Locale und generiertes oder gemeinsames Passwort ab' -Success (
        $uiSource -match 'Invoke-LabHyperVWindowsSlotPoolInteractive' -and
        $uiSource -match 'Minimaler RAM pro Slot' -and
        $uiSource -match 'Windows-Anzeigesprache' -and
        $uiSource -match 'Tastaturlayout / Input-Locale' -and
        $uiSource -match 'GenerateAdministratorPasswords' -and
        $uiSource -match 'AdministratorPassword')
}
catch {
    Add-CheckResult -Name 'Windows-Slot-Pool-Testausführung' -Success $false -Message "$($_.Exception.Message) [$($_.ScriptStackTrace)]"
}

if ($failures.Count -gt 0) {
    Write-Host "Windows Slot Pool Checks: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Windows Slot Pool Checks: $passed PASS" -ForegroundColor Green
exit 0
