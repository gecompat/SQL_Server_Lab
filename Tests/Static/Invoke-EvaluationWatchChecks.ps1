#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "evaluation-watch-$([guid]::NewGuid().ToString('N'))"
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Evaluation Watch Checks' -ForegroundColor Cyan

try {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module = Import-Module $modulePath -Force -PassThru
    $result = & $module {
        param($StateRoot)
        $normalExpiry = [datetime]::UtcNow.AddDays(90).ToString('o')
        $criticalExpiry = [datetime]::UtcNow.AddDays(2).ToString('o')
        $instanceExpiry = [datetime]::UtcNow.AddDays(3).ToString('o')
        $runId = '11111111-1111-1111-1111-111111111111'
        $connectionDirectory = Join-Path (Join-Path $StateRoot 'runs') $runId
        New-Item -ItemType Directory -Path $connectionDirectory -Force | Out-Null
        [PSCustomObject]@{
            schemaVersion = 1
            instances = @(
                [PSCustomObject]@{
                    id = 'windows-primary'; provider = 'hyperv'; vmName = 'secret-vm-name'
                    windowsActivation = [PSCustomObject]@{
                        state = 'EVALUATION_ACTIVE'; edition = 'ServerStandardEval'
                        evaluationExpiresAt = $instanceExpiry
                    }
                }
            )
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $connectionDirectory 'connection-info.json') -Encoding utf8
        function Get-SqlServerLabHyperVImageArtifact {
            @(
                [PSCustomObject]@{
                    ArtifactId = 'hyperv-os-sealed-' + ('a' * 64); ArtifactState = 'OS_SEALED'
                    Evaluation = [PSCustomObject]@{ LicenseType = 'evaluation'; ExpiresAt = $normalExpiry }
                    Sql = [PSCustomObject]@{ Evaluation = [PSCustomObject]@{ LicenseType = ''; ExpiresAt = $null } }
                },
                [PSCustomObject]@{
                    ArtifactId = 'hyperv-sql-prepared-sealed-' + ('b' * 64); ArtifactState = 'SQL_PREPARED_SEALED'
                    Evaluation = [PSCustomObject]@{ LicenseType = 'evaluation'; ExpiresAt = $criticalExpiry }
                    Sql = [PSCustomObject]@{ Evaluation = [PSCustomObject]@{ LicenseType = 'evaluation'; ExpiresAt = $null } }
                }
            )
        }
        function Get-LabActiveRuns {
            @(
                [PSCustomObject]@{
                    runId = $runId; state = 'RUNNING'
                    metadata = [PSCustomObject]@{
                        workflowKind = 'hyperv-lab'; imageArtifactId = 'hyperv-os-sealed-' + ('a' * 64)
                    }
                },
                [PSCustomObject]@{
                    runId = '22222222-2222-2222-2222-222222222222'; state = 'STOPPED'
                    metadata = [PSCustomObject]@{
                        workflowKind = 'hyperv-lab'; imageArtifactId = 'hyperv-os-sealed-' + ('a' * 64)
                    }
                }
            )
        }
        $readOnly = Get-SqlServerLabEvaluationWatch -StateRoot $StateRoot -WarningDaysRemaining 30 -CriticalDaysRemaining 7
        $eventStateExistsAfterReadOnly = Test-Path -LiteralPath (Join-Path $StateRoot 'evaluation-watch-events.json')
        $firstRecorded = Get-SqlServerLabEvaluationWatch -StateRoot $StateRoot -WarningDaysRemaining 30 -CriticalDaysRemaining 7 -RecordEvents
        $secondRecorded = Get-SqlServerLabEvaluationWatch -StateRoot $StateRoot -WarningDaysRemaining 30 -CriticalDaysRemaining 7 -RecordEvents
        function Test-LabPathWithinRoot { [PSCustomObject]@{ Valid = $false; Reason = 'synthetic reparse point' } }
        $unsafeConnection = Get-SqlServerLabEvaluationWatch -StateRoot $StateRoot -WarningDaysRemaining 30 -CriticalDaysRemaining 7
        [PSCustomObject]@{ ReadOnly = $readOnly; EventStateExistsAfterReadOnly = $eventStateExistsAfterReadOnly; FirstRecorded = $firstRecorded; SecondRecorded = $secondRecorded; UnsafeConnection = $unsafeConnection }
    } $temporaryRoot

    $items = @($result.ReadOnly.Items)
    Add-CheckResult -Name 'Evaluation-Watch projiziert Windows- und SQL-Evaluationen über stabile Artifact-IDs' -Success (
        $result.ReadOnly.ContractVersion -eq 'SqlServerLab.EvaluationWatch/1.1' -and
        $items.Count -eq 3 -and (@($items.Component | Sort-Object -Unique) -join '|') -eq 'SqlServer|Windows'
    )
    Add-CheckResult -Name 'Evaluation-Watch klassifiziert normale, kritische und unbekannte Fristen ohne Auto-Refresh' -Success (
        @($items.Status) -contains 'OK' -and @($items.Status) -contains 'CRITICAL' -and @($items.Status) -contains 'UNKNOWN' -and
        @($items | Where-Object Status -ne 'OK' | Where-Object RefreshStatus -ne 'REFRESH_BLOCKED').Count -eq 0
    )
    Add-CheckResult -Name 'Evaluation-Watch bleibt ohne RecordEvents vollständig read-only' -Success (
        $result.ReadOnly.NewEventCount -eq 0 -and -not $result.EventStateExistsAfterReadOnly
    )
    $instanceItems = @($result.ReadOnly.InstanceItems)
    Add-CheckResult -Name 'Evaluation-Watch projiziert nur registrierte laufende Hyper-V-Instanzen mit eigener persistierter Windows-Frist' -Success (
        $instanceItems.Count -eq 1 -and
        $instanceItems[0].RunId -eq '11111111-1111-1111-1111-111111111111' -and
        $instanceItems[0].InstanceId -eq 'windows-primary' -and
        $instanceItems[0].ArtifactId -eq ('hyperv-os-sealed-' + ('a' * 64)) -and
        $instanceItems[0].RegistrationState -eq 'RUNNING' -and
        $instanceItems[0].DeadlineSource -eq 'PERSISTED_WINDOWS_ACTIVATION' -and
        $instanceItems[0].Status -eq 'CRITICAL'
    )
    Add-CheckResult -Name 'Evaluation-Watch folgt keiner unsicheren Connection-Info-Pfadbindung' -Success (
        @($result.UnsafeConnection.InstanceItems).Count -eq 0
    )
    Add-CheckResult -Name 'Evaluation-Watch erfasst neue Fälligkeitsereignisse einmalig und dedupliziert Wiederholungen' -Success (
        $result.FirstRecorded.NewEventCount -eq 3 -and $result.SecondRecorded.NewEventCount -eq 0 -and
        @($result.FirstRecorded.NewEvents.EventId | Select-Object -Unique).Count -eq 3 -and
        @($result.FirstRecorded.NewEvents | Where-Object { $_.RunId -eq '11111111-1111-1111-1111-111111111111' -and $_.InstanceId -eq 'windows-primary' }).Count -eq 1
    )
    Add-CheckResult -Name 'Evaluation-Watch gibt weder lokale Pfade noch Event-State-Pfade aus' -Success (
        ($result | ConvertTo-Json -Depth 20) -notmatch [regex]::Escape($temporaryRoot) -and
        ($result | ConvertTo-Json -Depth 20) -notmatch 'secret-vm-name'
    )
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Error "$($failures.Count) Checks fehlgeschlagen."
    exit 1
}
Write-Host "$passed Checks bestanden." -ForegroundColor Green
