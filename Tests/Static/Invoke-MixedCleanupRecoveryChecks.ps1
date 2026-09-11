#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft die providerweise Recovery eines gemischten Cleanup-Teilfehlers.
.DESCRIPTION
    Erzeugt nur synthetischen Run-State. Docker-Cleanup gelingt, Podman scheitert
    kontrolliert. Der erfolgreiche Docker-Subrun muss terminal bleiben; der
    Retry verarbeitet ausschließlich den fehlgeschlagenen Podman-Schritt.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-mixed-cleanup-' + [guid]::NewGuid().ToString('N'))
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

try {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -ErrorAction Stop
    $module = Get-Module SqlServerLab

    $result = & $module {
        param($StateRoot)

        $script:podmanFails = $true
        $script:dockerCalls = 0
        $script:podmanCalls = 0
        function Resolve-LabHostTool { param([string]$Name) [pscustomobject]@{ Available = $true; Invocation = $Name } }
        function Get-DockerLabContainers { param([string]$RunId) @() }
        function Get-PodmanLabContainers { param([string]$RunId) @() }
        function Remove-DockerInstance {
            param([string]$ContainerIdOrName, [string]$ExpectedScopeId)
            $null = $ContainerIdOrName, $ExpectedScopeId
            $script:dockerCalls++
        }
        function Remove-PodmanInstance {
            param([string]$ContainerIdOrName, [string]$ExpectedScopeId)
            $null = $ContainerIdOrName, $ExpectedScopeId
            $script:podmanCalls++
            if ($script:podmanFails) { throw 'SYNTHETIC_PODMAN_CLEANUP_FAILURE' }
        }

        $scopeId = New-LabGuid
        $run = New-LabRunState -StateRoot $StateRoot -ScopeId $scopeId -Metadata @{ name = 'synthetic-mixed-cleanup' } -ProviderSubRuns @(
            [pscustomobject]@{ id = 'provider-docker'; provider = 'docker'; instanceIds = @('docker-primary') },
            [pscustomobject]@{ id = 'provider-podman'; provider = 'podman'; instanceIds = @('podman-primary') }
        )
        foreach ($state in @('PROVISIONING', 'SQL_READY', 'DATABASES_CREATED', 'RUNNING')) {
            Set-LabRunState -RunId $run.RunId -NewState $state -StateRoot $StateRoot
            foreach ($provider in @('docker', 'podman')) {
                Set-LabProviderSubRunState -RunId $run.RunId -Provider $provider -NewState $state -StateRoot $StateRoot
            }
        }

        [pscustomobject]@{
            runId = $run.RunId; scopeId = $scopeId
            instances = @(
                [pscustomobject]@{ id = 'docker-primary'; provider = 'docker'; containerId = 'synthetic-docker'; containerName = 'synthetic-docker' },
                [pscustomobject]@{ id = 'podman-primary'; provider = 'podman'; containerId = 'synthetic-podman'; containerName = 'synthetic-podman' }
            )
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $run.RunDir 'connection-info.json') -Encoding utf8

        $null = New-CleanupPlan -RunDir $run.RunDir -RunId $run.RunId -ScopeId $scopeId -ProviderSubRuns @(
            [pscustomobject]@{ id = 'provider-docker'; provider = 'docker' },
            [pscustomobject]@{ id = 'provider-podman'; provider = 'podman' }
        )
        $null = Add-CleanupStep -RunDir $run.RunDir -ResourceType container -ResourceId 'synthetic-docker' -Action remove -Provider docker -ProviderSubRunId 'provider-docker'
        $null = Add-CleanupStep -RunDir $run.RunDir -ResourceType container -ResourceId 'synthetic-podman' -Action remove -Provider podman -ProviderSubRunId 'provider-podman'

        $first = Remove-SqlServerLab -RunId $run.RunId -StateRoot $StateRoot -Force -Confirm:$false
        $firstSubRuns = @(Get-LabProviderSubRuns -RunId $run.RunId -StateRoot $StateRoot)
        $firstPlan = Get-CleanupPlan -RunDir $run.RunDir

        $script:podmanFails = $false
        $retry = Remove-SqlServerLab -RunId $run.RunId -StateRoot $StateRoot -Force -Confirm:$false
        $finalState = Get-LabRunState -RunId $run.RunId -StateRoot $StateRoot
        $finalPlan = Get-CleanupPlan -RunDir $run.RunDir

        [pscustomobject]@{
            FirstStatus = $first.Status
            DockerStateAfterFailure = [string](@($firstSubRuns | Where-Object provider -eq 'docker')[0].state)
            PodmanStateAfterFailure = [string](@($firstSubRuns | Where-Object provider -eq 'podman')[0].state)
            DockerStepCompleted = [string](@($firstPlan.steps | Where-Object provider -eq 'docker')[0].state) -eq 'COMPLETED'
            PodmanStepFailed = [string](@($firstPlan.steps | Where-Object provider -eq 'podman')[0].state) -eq 'FAILED'
            RetryStatus = $retry.Status
            FinalState = [string]$finalState.state
            DockerCalls = $script:dockerCalls
            PodmanCalls = $script:podmanCalls
            PodmanStepCompleted = [string](@($finalPlan.steps | Where-Object provider -eq 'podman')[0].state) -eq 'COMPLETED'
        }
    } $temporaryRoot

    Add-CheckResult -Name 'Gemischter Cleanup-Teilfehler bleibt als RECOVERY_REQUIRED sichtbar' -Success ($result.FirstStatus -eq 'RECOVERY_REQUIRED')
    Add-CheckResult -Name 'Erfolgreicher Docker-Subrun bleibt bei Podman-Fehler terminal bereinigt' -Success ($result.DockerStateAfterFailure -eq 'CLEANED_UP' -and $result.DockerStepCompleted)
    Add-CheckResult -Name 'Nur der fehlgeschlagene Podman-Subrun bleibt für Recovery markiert' -Success ($result.PodmanStateAfterFailure -eq 'RECOVERY_REQUIRED' -and $result.PodmanStepFailed)
    Add-CheckResult -Name 'Retry führt nur Podman erneut aus und finalisiert den gemischten Run' -Success ($result.RetryStatus -eq 'REMOVED' -and $result.FinalState -eq 'REMOVED' -and $result.DockerCalls -eq 1 -and $result.PodmanCalls -eq 2 -and $result.PodmanStepCompleted)
}
catch {
    Add-CheckResult -Name 'Gemischte-Cleanup-Recovery-Testausführung' -Success $false -Message $_.Exception.Message
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) { exit 1 }
