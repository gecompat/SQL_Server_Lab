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
    $behavior = & $module {
        $script:syncRun = [PSCustomObject]@{ runId='runtime-sync-run'; state='RUNNING' }
        $script:syncSubRun = [PSCustomObject]@{ provider='docker'; state='RUNNING' }
        $script:syncRuntimeState = 'MISSING'
        $script:syncErrors = 0
        function Get-LabRunState { $script:syncRun }
        $script:previewWrites = 0
        $script:syncCalls = 0
        function Get-LabActiveRuns {
            param($StateRoot,[switch]$NoWrite)
            if (-not $NoWrite) { $script:previewWrites++ }
            @($script:syncRun)
        }
        function Get-LabRunRuntimeStatus {
            param($Run,$StateRoot,[switch]$NoWrite)
            if (-not $NoWrite) { $script:previewWrites++ }
            $provider = if ($script:syncRuntimeState -eq 'STOPPED') { 'hyperv' } else { 'docker' }
            [PSCustomObject]@{
                State=$script:syncRuntimeState
                Instances=@([PSCustomObject]@{ Provider=$provider; State=$script:syncRuntimeState; InstanceId='primary' })
            }
        }
        function Get-LabProviderSubRuns { @($script:syncSubRun) }
        function Set-LabProviderSubRunState { param($RunId,$Provider,$NewState,$Reason,$StateRoot) $script:syncSubRun.state=$NewState }
        function Set-LabRunState { param($RunId,$NewState,$Reason,$StateRoot) $script:syncRun.state=$NewState; $script:syncRun }
        function Add-LabRunError { $script:syncErrors++ }
        function Sync-LabRunRuntimeState {
            param($Run,$StateRoot)
            $script:syncCalls++
            $script:syncRun.state = $script:syncRuntimeState
            [pscustomobject]@{ Run=$script:syncRun; Synchronized=$true }
        }

        $missing = Sync-SqlServerLabRuntimeState -RunId runtime-sync-run -StateRoot 'X:\state' -Confirm:$false
        $missingState = [string]$script:syncRun.state
        $missingSubState = [string]$script:syncSubRun.state
        $missingErrors = $script:syncErrors

        $script:syncRun.state = 'RUNNING'; $script:syncSubRun.state='RUNNING'; $script:syncErrors=0
        $whatIf = Sync-SqlServerLabRuntimeState -RunId runtime-sync-run -StateRoot 'X:\state' -WhatIf
        $whatIfState = [string]$script:syncRun.state

        $script:syncRuntimeState = 'UNAVAILABLE'
        $unavailable = Sync-SqlServerLabRuntimeState -RunId runtime-sync-run -StateRoot 'X:\state' -Confirm:$false
        $unavailableState = [string]$script:syncRun.state
        $script:syncRuntimeState = 'STOPPED'
        $script:previewWrites = 0
        $preview = Sync-SqlServerLabRuntimeState -StateRoot 'X:\state' -WhatIf
        $stayedRunning = $script:syncRun.state -eq 'RUNNING'
        $previewWrites = $script:previewWrites
        $previewSyncCalls = $script:syncCalls
        $applied = Sync-SqlServerLabRuntimeState -RunId runtime-sync-run -StateRoot 'X:\state' -Confirm:$false
        [PSCustomObject]@{
            Missing=$missing; MissingState=$missingState; MissingSubState=$missingSubState; MissingErrors=$missingErrors
            WhatIf=$whatIf; WhatIfState=$whatIfState; Unavailable=$unavailable; UnavailableState=$unavailableState
            Preview=$preview; StayedRunning=$stayedRunning; PreviewWrites=$previewWrites; PreviewSyncCalls=$previewSyncCalls
            Applied=$applied; SyncCalls=$script:syncCalls
        }
    }

    Add-CheckResult -Name 'Fehlende gebundene Runtime setzt Run und ProviderSubRun auf RECOVERY_REQUIRED' -Success (
        $behavior.Missing.RuntimeState -eq 'MISSING' -and $behavior.Missing.Action -eq 'RECOVERY_REQUIRED' -and
        $behavior.Missing.Changed -and $behavior.MissingState -eq 'RECOVERY_REQUIRED' -and
        $behavior.MissingSubState -eq 'RECOVERY_REQUIRED' -and $behavior.MissingErrors -eq 1)
    Add-CheckResult -Name 'WhatIf verändert einen fehlenden Runtime-Run nicht' -Success (
        -not $behavior.WhatIf.Changed -and $behavior.WhatIfState -eq 'RUNNING' -and
        $behavior.WhatIf.Action -eq 'RECOVERY_REQUIRED_PLANNED')
    Add-CheckResult -Name 'Nicht erreichbare Runtime bleibt Diagnose und wird nicht als Löschung verbucht' -Success (
        $behavior.Unavailable.Action -eq 'DIAGNOSTIC_ONLY' -and -not $behavior.Unavailable.Changed -and
        $behavior.UnavailableState -eq 'RUNNING')

    Add-CheckResult -Name 'WhatIf liest auch bei abweichender Hyper-V-Laufzeit ohne Metadatenreparatur oder Logging' -Success (
        $behavior.StayedRunning -and $behavior.PreviewWrites -eq 0 -and $behavior.PreviewSyncCalls -eq 0 -and
        $behavior.Preview.Action -eq 'STATE_SYNCHRONIZE_PLANNED' -and -not $behavior.Preview.Changed)
    Add-CheckResult -Name 'Bestätigter Statusabgleich erreicht den Schreibpfad genau einmal' -Success (
        $behavior.Applied.Action -eq 'STATE_SYNCHRONIZED' -and $behavior.Applied.Changed -and
        $behavior.Applied.State -eq 'STOPPED' -and $behavior.SyncCalls -eq 1)

    $getSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\Get-SqlServerLab.ps1') -Raw -Encoding utf8
    $dockerSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers\Docker\DockerProvider.ps1') -Raw -Encoding utf8
    $podmanSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers\Podman\PodmanProvider.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Statusoberfläche weist MISSING ausdrücklich aus' -Success (
        $getSource -match 'runtimeState\s*=\s*if \(\[string\]\$boundRuntime\.State -eq ''MISSING''\) \{ ''Missing'' \}' -and
        $getSource -match '\[MISSING\]')
    Add-CheckResult -Name 'Containerprovider unterscheiden fehlendes Objekt von nicht erreichbarer Runtime' -Success (
        $dockerSource -match 'Available\s*=\s*\$runtimeAvailable' -and $dockerSource -match "info" -and
        $podmanSource -match 'Available\s*=\s*\$runtimeAvailable' -and $podmanSource -match "info")
}
catch {
    Add-CheckResult -Name 'Runtime-State-Sync-Testausführung' -Success $false -Message "$($_.Exception.Message) [$($_.ScriptStackTrace)]"
}

if ($failures.Count -gt 0) {
    Write-Host "Runtime State Sync Checks: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Runtime State Sync Checks: $passed PASS" -ForegroundColor Green
exit 0
