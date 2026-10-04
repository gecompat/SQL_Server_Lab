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

    $explicitCoreArtifact = & $module {
        function Get-HyperVImageArtifact {
            param([string]$ArtifactId, [string]$StateRoot, [switch]$SkipIntegrityCheck)
            [PSCustomObject]@{
                artifactId = $ArtifactId; artifactState = 'OS_SEALED'; generalized = $true
                registeredAt = '2026-09-01T00:00:00Z'
                operatingSystem = [PSCustomObject]@{ id = 'windows-server-2025'; version = '2025'; installationType = 'core' }
            }
        }
        function Test-HyperVImageArtifactEvaluationEligibility {
            param($Artifact, $MinimumEvaluationDaysRemaining)
            [PSCustomObject]@{ Eligible = $true; Reason = $null }
        }
        Resolve-LabWindowsSlotPoolArtifact -ArtifactId ('hyperv-os-sealed-' + ('c' * 64))
    }
    Add-CheckResult -Name 'Explizite Server-Core-Baseline wird trotz implizitem Desktop-Default akzeptiert' -Success (
        $explicitCoreArtifact.artifactId -eq ('hyperv-os-sealed-' + ('c' * 64)) -and
        $explicitCoreArtifact.operatingSystem.installationType -eq 'core')

    $fixtureControlBefore = & $module {
        $flag = Get-Variable -Name IsWindows -Scope Script -ErrorAction SilentlyContinue
        [pscustomobject]@{HasFlag=($null -ne $flag);FlagValue=$(if($flag){$flag.Value}else{$null})
            RootSupport=${function:Assert-LabWindowsPoolRootSupport}.ToString()}
    }
    $fixture=Join-Path (Join-Path $repoRoot '.artifacts/windows-slot-pool-checks') ([guid]::NewGuid().ToString('N'))
    $behavior = & $module {
        param($StateRoot)
        $originalIsWindows = Get-Variable -Name IsWindows -Scope Script -ErrorAction SilentlyContinue
        $originalIsWindowsValue = if ($originalIsWindows) { [bool]$originalIsWindows.Value } else { $null }
        $actualIsWindows = [OperatingSystem]::IsWindows()
        $originalPoolRootSupport = ${function:Assert-LabWindowsPoolRootSupport}
        Set-Variable -Name IsWindows -Scope Script -Value $true -Force
        try {
        if (-not $actualIsWindows) {
            # Windows product behavior is synthetic here; retain the actual host's
            # real lexical root checks without invoking Win32 APIs on Unix.
            function Assert-LabWindowsPoolRootSupport {
                [CmdletBinding()]
                param([string]$StateRoot)
                $syntheticIsWindowsValue = [bool]$script:IsWindows
                try {
                    Set-Variable -Name IsWindows -Scope Script -Value $actualIsWindows -Force
                    & $originalPoolRootSupport -StateRoot $StateRoot
                }
                finally {
                    Set-Variable -Name IsWindows -Scope Script -Value $syntheticIsWindowsValue -Force
                }
            }
        }
        $script:poolLabs = @{}
        $script:createCalls = [Collections.Generic.List[object]]::new()
        $script:provisionCalls = [Collections.Generic.List[object]]::new()
        $script:stopCalls = [Collections.Generic.List[string]]::new()
        $script:activationChecks = [Collections.Generic.List[string]]::new()
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
        function Assert-LabWindowsSlotPoolLocale {
            param($Region,$SystemLocale,$UiLanguage,$InputLocale,$TimeZone,$Artifact)
            $overrides=@{Region=$Region;SystemLocale=$SystemLocale;UiLanguage=$UiLanguage;TimeZone=$TimeZone}
            if(-not [string]::IsNullOrWhiteSpace([string]$InputLocale)){$overrides.InputLocale=$InputLocale}
            Resolve-LabWindowsLocaleIntent -Overrides $overrides
        }
        function Get-LabActiveRuns { @() }
        function Get-VM {param($Name) @()}
        function New-HyperVLabEnvironment {
            param($ArtifactId,$LabName,$InstanceId,$DynamicMemoryEnabled,$MemoryMinimumMB,$MemoryStartupMB,$MemoryMaximumMB,$ProcessorCount,$AutoStart,$NetworkIntent,$StateRoot,$WindowsLocale,$WindowsActivation)
            $script:slotNumber++
            $created=New-LabRunState -StateRoot $StateRoot -Metadata @{name=$LabName;workflowKind='hyperv-lab';workload='windows';imageArtifactId=$ArtifactId;networkIntent='hostOnly';windowsLocale=$WindowsLocale}
            $runId = $created.RunId
            $scopeId = $created.ScopeId
            $vmName = "vm-$($script:slotNumber)"
            $lab = [PSCustomObject]@{
                RunDirectory = $created.RunDir
                Run = Get-LabRunState -RunId $runId -StateRoot $StateRoot
                Instance = [PSCustomObject]@{
                    id='primary';provider='hyperv'; workload='windows'; imageArtifactId=$ArtifactId; vmName=$vmName;vmId=[guid]::NewGuid().ToString()
                    windowsActivationIntent=$WindowsActivation
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
            if(-not $lab.Run.metadata.windowsPoolMember -or -not (Test-Path -LiteralPath (Join-Path (Join-Path $StateRoot operations) ($lab.Run.metadata.windowsPoolMember.creationOperationId+'.json')))){throw 'PROSPECTIVE_POOL_AUTHORITY_MISSING'}
            foreach($next in @('PROVISIONING','SQL_READY','DATABASES_CREATED','RUNNING','STOPPED')){Set-LabRunState -RunId $runId -StateRoot $StateRoot -NewState $next}
            $script:createCalls.Add([PSCustomObject]@{
                Name=$LabName; Minimum=$MemoryMinimumMB; Startup=$MemoryStartupMB
                Maximum=$MemoryMaximumMB; ProcessorCount=$ProcessorCount
                WindowsLocale=$WindowsLocale
                WindowsActivation=$WindowsActivation
            })
            [PSCustomObject]@{ RunId=$runId; VMName=$vmName }
        }
        function Get-HyperVLabWorkflowRun { param($RunId,$StateRoot) $script:poolLabs[$RunId] }
        function Get-LabWindowsPoolBoundMember {
            param($RunId,$StateRoot,[switch]$RequireOff)
            $lab=$script:poolLabs[$RunId];$run=Get-LabRunState -RunId $RunId -StateRoot $StateRoot
            [pscustomobject]@{Run=$run;Member=$run.metadata.windowsPoolMember;Instance=$lab.Instance
                Managed=[pscustomobject]@{VM=[pscustomobject]@{Id=$lab.Instance.vmId;Name=$lab.Instance.vmName;State=$(if($run.state -eq 'RUNNING'){'Running'}else{'Off'})}}
                ParentFingerprint=('c'*64);StateRoot=$StateRoot;RunDirectory=$lab.RunDirectory}
        }
        function Get-LabWindowsPoolGuestReceipt {
            param($Bound)
            if(-not (Test-LabWindowsPoolOperationContext -Member $Bound.Member -StateRoot $Bound.StateRoot)){throw 'POOL_CAPTURE_WITHOUT_CLAIM'}
            [pscustomobject]@{observedAt=[datetime]::UtcNow.ToString('o');evaluationExpiresAt=[datetime]::UtcNow.AddDays(90).ToString('o');licenseStatus=1;provisioningComplete=$true}
        }
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
        function Stop-HyperVLabEnvironment { param($RunId,$StateRoot) $script:stopCalls.Add($RunId);Set-LabRunState -RunId $RunId -StateRoot $StateRoot -NewState STOPPED }
        function Start-HyperVLabEnvironment {param($RunId,$StateRoot,[switch]$SkipWindowsActivationReconcile) $script:activationChecks.Add($RunId);Set-LabRunState -RunId $RunId -StateRoot $StateRoot -NewState RUNNING}
        function Invoke-HyperVWindowsSlotActivation {
            param($RunId,$WindowsActivation,$StateRoot)
            $script:activationChecks.Add("activation:${RunId}:$($WindowsActivation.EgressPolicy)")
        }

        $result = New-SqlServerLabWindowsSlotPool -Count 2 -GenerateAdministratorPasswords -ArtifactId '' `
            -StateRoot $StateRoot -Confirm:$false
        function Get-LabActiveRuns {@($script:poolLabs.Values | ForEach-Object {$_.Run})}
        $reuse = New-SqlServerLabWindowsSlotPool -Count 2 -PoolId $result.PoolId -GenerateAdministratorPasswords -StateRoot $StateRoot -Confirm:$false
        $legacyIntent = Resolve-LabWindowsActivationIntent -Intent @{
            ContractVersion = 'SqlServerLab.WindowsActivationIntent/1.0'
            Strategy = 'EvaluationOnline'
            EgressPolicy = 'ExistingOnly'
        }
        foreach ($lab in @($script:poolLabs.Values)) { $lab.Instance.windowsActivationIntent = $legacyIntent }
        $legacyRejected=$false
        try {New-SqlServerLabWindowsSlotPool -Count 2 -GenerateAdministratorPasswords -StateRoot $StateRoot -Confirm:$false}catch{$legacyRejected=$_.Exception.Message -eq 'WINDOWS_POOL_EXISTING_NAME_CONFLICT'}
        $invalidExplicitArtifactRejected = $false
        try { New-SqlServerLabWindowsSlotPool -Count 1 -GenerateAdministratorPasswords -ArtifactId 'invalid-artifact' | Out-Null }
        catch { $invalidExplicitArtifactRejected = $true }
        [PSCustomObject]@{
            Result=$result; Reuse=$reuse; LegacyRejected=$legacyRejected; ActivationChecks=@($script:activationChecks); Creates=@($script:createCalls); Provisions=@($script:provisionCalls); Stops=@($script:stopCalls)
            InvalidExplicitArtifactRejected=$invalidExplicitArtifactRejected
        }
        }
        finally {
            Set-Item -Path Function:Assert-LabWindowsPoolRootSupport -Value $originalPoolRootSupport
            if ($originalIsWindows) {
                Set-Variable -Name IsWindows -Scope Script -Value $originalIsWindowsValue -Force
            }
            else {
                Remove-Variable -Name IsWindows -Scope Script -Force -ErrorAction SilentlyContinue
            }
        }
    } $fixture

    $fixtureControlAfter = & $module {
        $flag = Get-Variable -Name IsWindows -Scope Script -ErrorAction SilentlyContinue
        [pscustomobject]@{HasFlag=($null -ne $flag);FlagValue=$(if($flag){$flag.Value}else{$null})
            RootSupport=${function:Assert-LabWindowsPoolRootSupport}.ToString()}
    }
    Add-CheckResult -Name 'Synthetische Windows-Fixture stellt Hostflag und echte Rootpruefung vollstaendig wieder her' -Success (
        ($fixtureControlBefore | ConvertTo-Json -Compress) -ceq ($fixtureControlAfter | ConvertTo-Json -Compress))
    Add-CheckResult -Name 'Leere optionale ArtifactId loest die automatische Baseline-Auswahl aus; eine explizit ungueltige ID bleibt abgewiesen' -Success (
        $behavior.Result.ArtifactId -eq ("hyperv-os-sealed-" + ('a' * 64)) -and $behavior.InvalidExplicitArtifactRejected)
    Add-CheckResult -Name 'Resume bindet dieselbe Pool-ID, überspringt frische gestoppte Mitglieder und adoptiert keine Namen' -Success ($behavior.ActivationChecks.Count -eq 4 -and @($behavior.ActivationChecks | Where-Object { $_ -match ':AllowTemporary$' }).Count -eq 2 -and @($behavior.Reuse.Slots).Count -eq 2 -and $behavior.LegacyRejected -and $behavior.Creates.Count -eq 2 -and $behavior.Provisions.Count -eq 2)
    Add-CheckResult -Name 'Pool bindet vor der ersten VM einen kontrollierten temporaeren Aktivierungsintent' -Success (@($behavior.Creates | Where-Object {$_.WindowsActivation.ContractVersion -eq 'SqlServerLab.WindowsActivationIntent/1.0' -and $_.WindowsActivation.EgressPolicy -eq 'AllowTemporary'}).Count -eq 2)
    Add-CheckResult -Name 'Pool erstellt zwei Slots mit den gebundenen Standardressourcen' -Success (
        $behavior.Result.Status -eq 'COMPLETE' -and @($behavior.Result.Slots).Count -eq 2 -and
        @($behavior.Creates | Where-Object { $_.Minimum -eq 1024 -and $_.Startup -eq 2048 -and $_.Maximum -eq 4096 -and $_.ProcessorCount -eq 4 }).Count -eq 2)
    Add-CheckResult -Name 'Pool bindet den normalisierten Locale-Intent bereits vor der Slot-Mutation' -Success (
        @($behavior.Creates | Where-Object { $_.WindowsLocale.ContractVersion -eq 'SqlServerLab.WindowsLocaleIntent/1.0' -and $_.WindowsLocale.Region -eq 'AT' }).Count -eq 2)
    Add-CheckResult -Name 'OOBE verwendet pro Slot den generierten Passwortmodus und Locale-Vertrag' -Success (
        @($behavior.Provisions).Count -eq 2 -and
        @($behavior.Provisions | Where-Object {
            $_.PasswordSource -eq 'generated' -and $_.Region -eq 'AT' -and $_.SystemLocale -eq 'de-AT' -and
            $_.UiLanguage -eq 'en-US' -and $_.InputLocale -eq $behavior.Result.Locale.InputLocale
        }).Count -eq 2 -and @($behavior.Stops).Count -eq 4)

    $poolSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\New-SqlServerLabWindowsSlotPool.ps1') -Raw -Encoding utf8
    $uiSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\Invoke-SqlServerLab.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Pool ist resumierbar und lehnt eine ungeeignete Baseline ab' -Success (
        $poolSource -match 'HYPERV_WINDOWS_SLOT_POOL_BASELINE_REQUIRED' -and
        $poolSource -match 'PoolId' -and
        $poolSource -match 'MinimumEvaluationDaysRemaining' -and
        $poolSource -match "InstallationType = 'desktop-experience'" -and
        $poolSource -match 'operatingSystem.installationType -eq \$InstallationType')
    Add-CheckResult -Name 'CLI fragt RAM, Locale und generiertes oder gemeinsames Passwort ab' -Success (
        $uiSource -match 'Invoke-LabHyperVWindowsSlotPoolInteractive' -and
        $uiSource -match 'Minimaler RAM pro Slot' -and
        $uiSource -match 'Windows-Anzeigesprache' -and
        $uiSource -match 'Tastaturlayout / Input-Locale' -and
        $uiSource -match 'GenerateAdministratorPasswords' -and
        $uiSource -match 'AdministratorPassword' -and
        $uiSource -match 'windows-slot-pool-installation-type' -and
        $uiSource.Contains('-InstallationType $installationType'))
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
