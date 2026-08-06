#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft fehlgeschlagenen Cleanup und einen erfolgreichen Recovery-Versuch.
.DESCRIPTION
    Erzeugt ausschliesslich synthetischen State in einem temporaeren Verzeichnis.
    Provideraufrufe werden im Modulkontext simuliert; Container oder andere
    Hostressourcen werden nicht veraendert.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-recovery-check-$([guid]::NewGuid().ToString('N'))"
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Cleanup and Recovery Checks' -ForegroundColor Cyan

try {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -ErrorAction Stop
    $module = Get-Module SqlServerLab

    $result = & $module {
        param($StateRoot)

        # Die Funktionen bleiben auf den Modulkontext dieses Testprozesses
        # begrenzt und ersetzen ausschliesslich externe Provideroperationen.
        $script:syntheticCleanupFailure = $true
        function docker {
            $global:LASTEXITCODE = 0
        }
        function Get-DockerLabContainers {
            param([string]$RunId)
            return @()
        }
        function Remove-DockerInstance {
            param(
                [string]$ContainerIdOrName,
                [string]$ExpectedScopeId
            )

            if ($script:syntheticCleanupFailure) {
                throw 'SYNTHETIC_PROVIDER_REMOVE_FAILURE'
            }

            return [pscustomobject]@{
                ContainerIdOrName = $ContainerIdOrName
                ScopeId           = $ExpectedScopeId
                Status            = 'REMOVED'
            }
        }

        $scopeId = New-LabGuid
        $run = New-LabRunState `
            -StateRoot $StateRoot `
            -ScopeId $scopeId `
            -Metadata @{ name = 'synthetic-recovery-check' } `
            -ProviderSubRuns @(
                [pscustomobject]@{
                    id          = 'provider-docker'
                    provider    = 'docker'
                    instanceIds = @('primary')
                }
            )

        foreach ($state in @('PROVISIONING', 'SQL_READY', 'DATABASES_CREATED', 'RUNNING')) {
            Set-LabRunState -RunId $run.RunId -NewState $state -StateRoot $StateRoot
            Set-LabProviderSubRunState `
                -RunId $run.RunId `
                -Provider docker `
                -NewState $state `
                -StateRoot $StateRoot
        }

        $connectionInfo = [pscustomobject]@{
            runId     = $run.RunId
            scopeId   = $scopeId
            instances = @(
                [pscustomobject]@{
                    id            = 'primary'
                    provider      = 'docker'
                    containerId   = 'synthetic-container-id'
                    containerName = 'sql-lab-synthetic-recovery'
                    host          = '127.0.0.1'
                    port          = 14330
                    version       = '2022'
                }
            )
        }
        $connectionInfo |
            ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath (Join-Path $run.RunDir 'connection-info.json') -Encoding utf8

        $null = New-CleanupPlan `
            -RunDir $run.RunDir `
            -RunId $run.RunId `
            -ScopeId $scopeId `
            -ProviderSubRuns @([pscustomobject]@{ id = 'provider-docker'; provider = 'docker' })
        $null = Add-CleanupStep `
            -RunDir $run.RunDir `
            -ResourceType container `
            -ResourceId 'sql-lab-synthetic-recovery' `
            -Action remove `
            -Provider docker `
            -ProviderSubRunId 'provider-docker'

        # Simuliert einen vor dem providerbezogenen Cleanup-Statusformat
        # gespeicherten Plan. Der Recovery-Pfad muss ihn ohne Hostmutation
        # aktualisieren und den eigentlichen Providerfehler erreichen.
        $legacyPlan = [pscustomobject]@{
            runId = $run.RunId; scopeId = $scopeId; createdAt = Get-LabTimestamp; status = 'PENDING'
            providerSubRuns = @([pscustomobject]@{ id = 'provider-docker'; provider = 'docker' })
            steps = @([pscustomobject]@{
                order = 1; resourceType = 'container'; resourceId = 'sql-lab-synthetic-recovery'
                action = 'remove'; provider = 'docker'; compensation = ''; dependsOn = @()
            })
        }
        $legacyPlan |
            ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath (Join-Path $run.RunDir 'cleanup-plan.json') -Encoding utf8

        $secretDirectory = Join-Path $run.RunDir 'secrets'
        New-Item -Path $secretDirectory -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $secretDirectory 'synthetic.secret') -Value 'synthetic-only' -Encoding utf8

        $firstAttempt = Remove-SqlServerLab `
            -RunId $run.RunId `
            -StateRoot $StateRoot `
            -Force `
            -Confirm:$false
        $stateAfterFailure = Get-LabRunState -RunId $run.RunId -StateRoot $StateRoot
        $planAfterFailure = Get-CleanupPlan -RunDir $run.RunDir

        $script:syntheticCleanupFailure = $false
        $secondAttempt = Remove-SqlServerLab `
            -RunId $run.RunId `
            -StateRoot $StateRoot `
            -Force `
            -Confirm:$false
        $stateAfterRetry = Get-LabRunState -RunId $run.RunId -StateRoot $StateRoot
        $planAfterRetry = Get-CleanupPlan -RunDir $run.RunDir

        [pscustomobject]@{
            FirstAttemptRecoveryRequired = $firstAttempt.Status -eq 'RECOVERY_REQUIRED'
            FirstAttemptBlocked          = $firstAttempt.Cleanup -eq 'CLEANUP_BLOCKED'
            FailureStatePreserved        = $stateAfterFailure.state -eq 'RECOVERY_REQUIRED'
            FailedStepPreserved          = @($planAfterFailure.steps).Count -eq 1 -and
                                           $planAfterFailure.steps[0].state -eq 'FAILED' -and
                                           $planAfterFailure.steps[0].error -match 'SYNTHETIC_PROVIDER_REMOVE_FAILURE'
            LegacyPlanUpgraded           = $planAfterFailure.providerSubRuns[0].state -eq 'PARTIAL' -and
                                           $planAfterFailure.providerSubRuns[0].errors -eq 1
            ErrorHistoryPreserved        = @($stateAfterFailure.errors | Where-Object {
                                               $_.component -eq 'Remove-SqlServerLab'
                                           }).Count -eq 1
            RetryRemoved                 = $secondAttempt.Status -eq 'REMOVED' -and
                                           $secondAttempt.Errors -eq 0
            RetryStateFinal              = $stateAfterRetry.state -eq 'REMOVED'
            RetryStepCompleted           = $planAfterRetry.steps[0].state -eq 'COMPLETED' -and
                                           -not $planAfterRetry.steps[0].error
            RecoveryHistoryPreserved     = @($stateAfterRetry.stateHistory | Where-Object {
                                               $_.state -eq 'RECOVERY_REQUIRED'
                                           }).Count -eq 1
            SecretsRemovedAfterSuccess   = -not (Test-Path -LiteralPath $secretDirectory)
        }
    } $temporaryRoot

    Add-CheckResult -Name 'Providerfehler ergibt RECOVERY_REQUIRED' -Success $result.FirstAttemptRecoveryRequired
    Add-CheckResult -Name 'Vollstaendig blockierter Cleanup bleibt sichtbar' -Success $result.FirstAttemptBlocked
    Add-CheckResult -Name 'Run-State bleibt nach Fehler fuer Recovery erhalten' -Success $result.FailureStatePreserved
    Add-CheckResult -Name 'Fehlgeschlagener Cleanup-Schritt behaelt Ursache' -Success $result.FailedStepPreserved
    Add-CheckResult -Name 'Aelterer Cleanup-Plan wird vor Recovery kompatibel aktualisiert' -Success $result.LegacyPlanUpgraded
    Add-CheckResult -Name 'Run-Fehlerhistorie dokumentiert Cleanupfehler' -Success $result.ErrorHistoryPreserved
    Add-CheckResult -Name 'Wiederholungsversuch entfernt die Umgebung' -Success $result.RetryRemoved
    Add-CheckResult -Name 'Erfolgreicher Retry endet in REMOVED' -Success $result.RetryStateFinal
    Add-CheckResult -Name 'Retry setzt FAILED zurueck und schliesst Schritt ab' -Success $result.RetryStepCompleted
    Add-CheckResult -Name 'Recovery-Historie bleibt nach Erfolg erhalten' -Success $result.RecoveryHistoryPreserved
    Add-CheckResult -Name 'Secrets werden erst nach erfolgreichem Cleanup entfernt' -Success $result.SecretsRemovedAfterSuccess
}
catch {
    Add-CheckResult -Name 'Cleanup-/Recovery-Testausfuehrung' -Success $false -Message $_.Exception.Message
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

exit 0
