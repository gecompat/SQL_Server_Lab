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
        $sqlRunId = '33333333-3333-3333-3333-333333333333'
        $stoppedSqlRunId = '44444444-4444-4444-4444-444444444444'
        $sqlArtifactId = 'hyperv-sql-prepared-sealed-' + ('c' * 64)
        $sqlVmId = '55555555-5555-5555-5555-555555555555'
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
        foreach ($sqlFixture in @(
            [PSCustomObject]@{ RunId = $sqlRunId; State = 'RUNNING' },
            [PSCustomObject]@{ RunId = $stoppedSqlRunId; State = 'STOPPED' }
        )) {
            $directory = Join-Path (Join-Path $StateRoot 'runs') $sqlFixture.RunId
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            [PSCustomObject]@{
                runId = $sqlFixture.RunId; scopeId = '66666666-6666-6666-6666-666666666666'; state = $sqlFixture.State
                metadata = [PSCustomObject]@{ workflowKind = 'hyperv-lab'; workload = 'sql'; imageArtifactId = $sqlArtifactId }
            } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'run-state.json') -Encoding utf8
            [PSCustomObject]@{
                schemaVersion = 1
                instances = @([PSCustomObject]@{
                    id = 'sql-primary'; provider = 'hyperv'; workload = 'sql'; vmName = 'secret-sql-vm'; vmId = $sqlVmId
                    imageArtifactId = $sqlArtifactId; sqlEdition = 'Enterprise Developer'
                    sqlReadiness = [PSCustomObject]@{
                        status = 'SQL_READY_RUN'; instanceName = 'MSSQLSERVER'; majorVersion = 17; edition = 'Enterprise Developer'
                    }
                })
            } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $directory 'connection-info.json') -Encoding utf8
        }
        $validEvidence = [ordered]@{
            Contract = [ordered]@{ Name = 'SqlServerLab.SqlGuestEvaluationEvidence'; Version = '1.0' }
            EvidenceId = '77777777-7777-7777-7777-777777777777'
            ObservedAt = [datetime]::UtcNow.AddMinutes(-5).ToString('o')
            RunId = $sqlRunId; ScopeId = '66666666-6666-6666-6666-666666666666'; InstanceId = 'sql-primary'; Provider = 'hyperv'
            VmId = $sqlVmId; ImageArtifactId = $sqlArtifactId; SqlInstanceName = 'MSSQLSERVER'; SqlMajorVersion = 17; SqlEdition = 'Enterprise Developer'
            LicenseClassification = 'EVALUATION'; EvaluationExpiresAt = [datetime]::UtcNow.AddDays(3).ToString('o')
            DeadlineSource = 'SQL_GUEST_OBSERVED'; ObservationStatus = 'CAPTURED'; EvidenceFreshUntil = [datetime]::UtcNow.AddHours(12).ToString('o')
            PreviousEvidenceId = $null
        }
        $validEvidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path (Join-Path (Join-Path $StateRoot 'runs') $sqlRunId) 'sql-guest-evaluation-evidence.json') -Encoding utf8
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
                },
                [PSCustomObject]@{
                    runId = $sqlRunId; state = 'RUNNING'
                    metadata = [PSCustomObject]@{ workflowKind = 'hyperv-lab'; workload = 'sql'; imageArtifactId = $sqlArtifactId }
                },
                [PSCustomObject]@{
                    runId = $stoppedSqlRunId; state = 'STOPPED'
                    metadata = [PSCustomObject]@{ workflowKind = 'hyperv-lab'; workload = 'sql'; imageArtifactId = $sqlArtifactId }
                }
            )
        }
        $readOnly = Get-SqlServerLabEvaluationWatch -StateRoot $StateRoot -WarningDaysRemaining 30 -CriticalDaysRemaining 7
        $eventStateExistsAfterReadOnly = Test-Path -LiteralPath (Join-Path $StateRoot 'evaluation-watch-events.json')
        $firstRecorded = Get-SqlServerLabEvaluationWatch -StateRoot $StateRoot -WarningDaysRemaining 30 -CriticalDaysRemaining 7 -RecordEvents
        $secondRecorded = Get-SqlServerLabEvaluationWatch -StateRoot $StateRoot -WarningDaysRemaining 30 -CriticalDaysRemaining 7 -RecordEvents
        $staleEvidence = $validEvidence | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        $staleEvidence.ObservedAt = [datetime]::UtcNow.AddDays(-7).ToString('o')
        $staleEvidence.EvidenceFreshUntil = [datetime]::UtcNow.AddMinutes(-1).ToString('o')
        $staleEvidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path (Join-Path (Join-Path $StateRoot 'runs') $sqlRunId) 'sql-guest-evaluation-evidence.json') -Encoding utf8
        $stale = Get-SqlServerLabEvaluationWatch -StateRoot $StateRoot -WarningDaysRemaining 30 -CriticalDaysRemaining 7
        $wrongBinding = $validEvidence | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20; $wrongBinding.VmId = '88888888-8888-8888-8888-888888888888'
        $wrongBinding | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path (Join-Path (Join-Path $StateRoot 'runs') $sqlRunId) 'sql-guest-evaluation-evidence.json') -Encoding utf8
        $wrongBindingResult = Get-LabSqlGuestEvaluationEvidence -RunId $sqlRunId -StateRoot $StateRoot
        $invalidDeadline = $validEvidence | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20; $invalidDeadline.DeadlineSource = 'SQL_GUEST_NO_DEADLINE'
        $invalidDeadline | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path (Join-Path (Join-Path $StateRoot 'runs') $sqlRunId) 'sql-guest-evaluation-evidence.json') -Encoding utf8
        $invalidDeadlineResult = Get-LabSqlGuestEvaluationEvidence -RunId $sqlRunId -StateRoot $StateRoot
        $duplicateEvidence = $validEvidence | ConvertTo-Json -Depth 20
        $duplicateEvidence = $duplicateEvidence -replace '"EvidenceId": "([^"]+)"', '"EvidenceId": "$1", "EvidenceId": "$1"'
        Set-Content -LiteralPath (Join-Path (Join-Path (Join-Path $StateRoot 'runs') $sqlRunId) 'sql-guest-evaluation-evidence.json') -Value $duplicateEvidence -Encoding utf8
        $duplicateEvidenceResult = Get-LabSqlGuestEvaluationEvidence -RunId $sqlRunId -StateRoot $StateRoot
        $triggerStateRoot = Join-Path $StateRoot 'trigger'
        New-Item -ItemType Directory -Path $triggerStateRoot -Force | Out-Null
        $trigger = Invoke-SqlServerLabEvaluationWatchTrigger -StateRoot $triggerStateRoot -WarningDaysRemaining 30 -CriticalDaysRemaining 7 -IntervalSeconds 1 -MaximumChecks 2 -RecordEvents
        $invalidTriggerThresholdRejected = $false
        try {
            Invoke-SqlServerLabEvaluationWatchTrigger -StateRoot $triggerStateRoot -WarningDaysRemaining 7 -CriticalDaysRemaining 30 -IntervalSeconds 1 -MaximumChecks 1 | Out-Null
        }
        catch { $invalidTriggerThresholdRejected = $_.Exception.Message -eq 'EVALUATION_WATCH_TRIGGER_CRITICAL_THRESHOLD_INVALID' }
        function Test-LabPathWithinRoot { [PSCustomObject]@{ Valid = $false; Reason = 'synthetic reparse point' } }
        $unsafeConnection = Get-SqlServerLabEvaluationWatch -StateRoot $StateRoot -WarningDaysRemaining 30 -CriticalDaysRemaining 7
        [PSCustomObject]@{ ReadOnly = $readOnly; EventStateExistsAfterReadOnly = $eventStateExistsAfterReadOnly; FirstRecorded = $firstRecorded; SecondRecorded = $secondRecorded; Stale = $stale; WrongBindingResult = $wrongBindingResult; InvalidDeadlineResult = $invalidDeadlineResult; DuplicateEvidenceResult = $duplicateEvidenceResult; Trigger = $trigger; InvalidTriggerThresholdRejected = $invalidTriggerThresholdRejected; UnsafeConnection = $unsafeConnection }
    } $temporaryRoot

    $items = @($result.ReadOnly.Items)
    Add-CheckResult -Name 'Evaluation-Watch projiziert Windows- und SQL-Evaluationen über stabile Artifact-IDs' -Success (
        $result.ReadOnly.ContractVersion -eq 'SqlServerLab.EvaluationWatch/1.2' -and
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
    $windowsInstance = @($instanceItems | Where-Object Component -eq 'Windows')
    Add-CheckResult -Name 'Evaluation-Watch projiziert nur registrierte laufende Hyper-V-Instanzen mit eigener persistierter Windows-Frist' -Success (
        $windowsInstance.Count -eq 1 -and
        $windowsInstance[0].RunId -eq '11111111-1111-1111-1111-111111111111' -and
        $windowsInstance[0].InstanceId -eq 'windows-primary' -and
        $windowsInstance[0].ArtifactId -eq ('hyperv-os-sealed-' + ('a' * 64)) -and
        $windowsInstance[0].RegistrationState -eq 'RUNNING' -and
        $windowsInstance[0].DeadlineSource -eq 'PERSISTED_WINDOWS_ACTIVATION' -and
        $windowsInstance[0].Status -eq 'CRITICAL'
    )
    $sqlInstanceItems = @($instanceItems | Where-Object Component -eq 'SqlServer')
    Add-CheckResult -Name 'SQL-Gast-Evidence wird nur für registrierte SQL-Hyper-V-Runs unabhängig von Image- und Windowsfristen projiziert' -Success (
        $sqlInstanceItems.Count -eq 2 -and
        @($sqlInstanceItems | Where-Object { $_.RunId -eq '33333333-3333-3333-3333-333333333333' -and $_.EvidenceStatus -eq 'CURRENT' -and $_.Status -eq 'CRITICAL' -and $_.DeadlineSource -eq 'SQL_GUEST_OBSERVED' }).Count -eq 1 -and
        @($sqlInstanceItems | Where-Object { $_.RunId -eq '44444444-4444-4444-4444-444444444444' -and $_.RegistrationState -eq 'STOPPED' -and $_.EvidenceStatus -eq 'EVIDENCE_MISSING' -and $_.Status -eq 'UNKNOWN' -and $_.RefreshStatus -eq 'REFRESH_BLOCKED' }).Count -eq 1
    )
    Add-CheckResult -Name 'SQL-Gast-Evidence wird bei falscher Bindung, unzulässiger Fristsemantik und doppelter EvidenceId fail-closed abgewiesen' -Success (
        $result.WrongBindingResult.Status -eq 'EVIDENCE_INVALID' -and
        $result.InvalidDeadlineResult.Status -eq 'EVIDENCE_INVALID' -and
        $result.DuplicateEvidenceResult.Status -eq 'EVIDENCE_INVALID'
    )
    Add-CheckResult -Name 'Veraltete SQL-Gast-Evidence erzeugt keine aktuelle Frist und blockiert den Refresh' -Success (
        @($result.Stale.InstanceItems | Where-Object { $_.Component -eq 'SqlServer' -and $_.RunId -eq '33333333-3333-3333-3333-333333333333' -and $_.EvidenceStatus -eq 'EVIDENCE_STALE' -and $_.Status -eq 'UNKNOWN' -and $_.EvaluationExpiresAt -eq $null -and $_.RefreshStatus -eq 'REFRESH_BLOCKED' }).Count -eq 1
    )
    Add-CheckResult -Name 'Evaluation-Watch folgt keiner unsicheren Connection-Info-Pfadbindung' -Success (
        @($result.UnsafeConnection.InstanceItems | Where-Object Component -eq 'Windows').Count -eq 0
    )
    Add-CheckResult -Name 'Evaluation-Watch erfasst neue Fälligkeitsereignisse einmalig und dedupliziert Wiederholungen' -Success (
        $result.FirstRecorded.NewEventCount -eq 5 -and $result.SecondRecorded.NewEventCount -eq 0 -and
        @($result.FirstRecorded.NewEvents.EventId | Select-Object -Unique).Count -eq 5 -and
        @($result.FirstRecorded.NewEvents | Where-Object { $_.RunId -eq '11111111-1111-1111-1111-111111111111' -and $_.InstanceId -eq 'windows-primary' }).Count -eq 1
    )
    $triggerSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLabEvaluationWatchTrigger.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Begrenzter Evaluation-Watch-Zeittrigger führt nur die explizite Anzahl lokaler Prüfungen aus und dedupliziert Ereignisse' -Success (
        $result.Trigger.ContractVersion -eq 'SqlServerLab.EvaluationWatchTrigger/1.0' -and
        $result.Trigger.CheckCount -eq 2 -and $result.Trigger.WaitCount -eq 1 -and
        $result.Trigger.TotalDueEventCount -eq 8 -and $result.Trigger.TotalNewEventCount -eq 4 -and
        (@($result.Trigger.Checks | ForEach-Object NewEventCount) -join '|') -eq '4|0' -and
        $result.InvalidTriggerThresholdRejected
    )
    Add-CheckResult -Name 'Evaluation-Watch-Zeittrigger registriert keine Windows-Aufgabe und greift nicht auf Runtime oder Netzwerk zu' -Success (
        $triggerSource -notmatch 'Register-ScheduledTask|New-ScheduledTask|schtasks(?:\.exe)?|Invoke-WebRequest|Invoke-RestMethod|Start-Process|Get-VM|docker|podman'
    )
    Add-CheckResult -Name 'Evaluation-Watch gibt weder lokale Pfade noch Event-State-Pfade aus' -Success (
        ($result | ConvertTo-Json -Depth 20) -notmatch [regex]::Escape($temporaryRoot) -and
        ($result | ConvertTo-Json -Depth 20) -notmatch 'secret-vm-name|secret-sql-vm'
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
