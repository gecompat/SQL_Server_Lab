#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures=[Collections.Generic.List[string]]::new();$passed=0
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Maintenance Checks' -ForegroundColor Cyan
try {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -ErrorAction Stop
    Add-CheckResult -Name 'Maintenance-Cmdlets sind exportiert' -Success (
        (Get-Command Get-SqlServerLabMaintenancePlan -ErrorAction SilentlyContinue) -and
        (Get-Command Invoke-SqlServerLabMaintenance -ErrorAction SilentlyContinue))

    $module=Get-Module SqlServerLab
    $plan=& $module {
        $now=[DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')
        function Get-LabStateRoot { 'synthetic-state' }
        function Get-LabActiveRuns {
            @(
                [pscustomobject]@{runId='11111111-1111-1111-1111-111111111111';scopeId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';state='RUNNING';updatedAt=$now},
                [pscustomobject]@{runId='22222222-2222-2222-2222-222222222222';scopeId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';state='STOPPED';updatedAt=$now},
                [pscustomobject]@{runId='33333333-3333-3333-3333-333333333333';scopeId='cccccccc-cccc-cccc-cccc-cccccccccccc';state='PROVISIONING';updatedAt=$now}
            )
        }
        function Get-LabRunRuntimeStatus { param($Run) switch([string]$Run.runId){
            '11111111-1111-1111-1111-111111111111'{[pscustomobject]@{State='STOPPED'}}
            '22222222-2222-2222-2222-222222222222'{[pscustomobject]@{State='MISSING'}}
            default{[pscustomobject]@{State='UNKNOWN'}}
        }}
        function Get-LabMaintenanceContainerInventory { param($Provider)
            if($Provider -eq 'docker'){
                [pscustomobject]@{Provider='docker';Status='AVAILABLE';Resources=@(
                    [pscustomobject]@{Provider='docker';ResourceId='orphan';Name='lab-orphan';State='exited';Running=$false;RunId='44444444-4444-4444-4444-444444444444';ScopeId='dddddddd-dddd-dddd-dddd-dddddddddddd';Lifecycle='';ExpiresAt='';Classification='LAB_BOUND';Fingerprint=('a'*64)},
                    [pscustomobject]@{Provider='docker';ResourceId='legacy';Name='sql-lab-legacy';State='exited';Running=$false;RunId='';ScopeId='';Classification='LEGACY_TEST_CANDIDATE';Fingerprint=('b'*64);BindMountCount=0},
                    [pscustomobject]@{Provider='docker';ResourceId='foreign';Name='open-webui';State='exited';Running=$false;RunId='';ScopeId='';Classification='FOREIGN';Fingerprint=('c'*64)}
                )}
            } else {[pscustomobject]@{Provider='podman';Status='AVAILABLE';Resources=@()}}
        }
        function Get-LabMaintenanceHyperVInventory {[pscustomobject]@{Provider='hyperv';Status='AVAILABLE';Resources=@()}}
        function Get-LabMaintenanceTempInventory {[pscustomobject]@{Status='AVAILABLE';Root='C:\synthetic-temp';CutoffUtc=$now;Resources=@(
            [pscustomobject]@{ResourceId='temp';Name='sql-lab-synthetic';FullPath='C:\synthetic-temp\sql-lab-synthetic';Kind='Directory';LastWriteTimeUtc=$now;FileCount=0;Bytes=0;Fingerprint=('d'*64)}
        )}}
        Get-LabMaintenancePlanCore -StaleAfterMinutes 30
    }
    Add-CheckResult -Name 'State-Drift wird automatisch synchronisierbar geplant' -Success (
        @($plan.Actions|Where-Object ActionType -eq 'SYNC_RUNTIME_STATE').Count -eq 1)
    Add-CheckResult -Name 'Fehlende Runtime trennt Markierung und scopegebundenen Cleanup' -Success (
        @($plan.Actions|Where-Object RunId -eq '22222222-2222-2222-2222-222222222222').Count -eq 2)
    Add-CheckResult -Name 'Veralteter unvollständiger Run erhält einen Cleanup-Pfad' -Success (
        @($plan.Actions|Where-Object ReasonCode -eq 'STALE_INCOMPLETE_RUN').Count -eq 1)
    Add-CheckResult -Name 'Gebundener Runtime-Orphan ist scopegebunden' -Success (
        @($plan.Actions|Where-Object { $_.ResourceId -eq 'orphan' -and $_.Disposition -eq 'SCOPED_CLEANUP' }).Count -eq 1)
    Add-CheckResult -Name 'Legacy-Testartefakt benötigt ausdrückliche Freigabe' -Success (
        @($plan.Actions|Where-Object { $_.ResourceId -eq 'legacy' -and $_.Disposition -eq 'EXPLICIT_LEGACY_APPROVAL' }).Count -eq 1)
    Add-CheckResult -Name 'Fremder Container wird nicht als Aktion geplant' -Success (
        @($plan.Actions|Where-Object ResourceId -eq 'foreign').Count -eq 0 -and $plan.Summary.ForeignResources -eq 1)
    Add-CheckResult -Name 'Veraltete Test-Tempobjekte werden gebündelt scopegebunden geplant' -Success (
        @($plan.Actions|Where-Object ActionType -eq 'REMOVE_STALE_TEST_TEMP_ARTIFACTS').Count -eq 1)

    $schema=Get-Content (Join-Path $repoRoot 'Schemas\lab-maintenance-plan.schema.json') -Raw -Encoding utf8
    Add-CheckResult -Name 'Maintenance-Plan erfüllt sein JSON-Schema' -Success (
        Test-Json -Json ($plan|ConvertTo-Json -Depth 30) -Schema $schema)

    $previewRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-maintenance-preview-' + [guid]::NewGuid().ToString('N'))
    $runId = 'c36cc4de-a090-4992-abf5-a54dae913095'
    $scopeId = '9efeb4b3-b5df-4974-84d5-49e9220ed99e'
    $vmId = 'f2f7cc26-de26-43ac-94e3-567fb0d790e7'
    $runPath = Join-Path $previewRoot "runs/$runId"
    $statePath = Join-Path $runPath 'run-state.json'
    $connectionPath = Join-Path $runPath 'connection-info.json'
    $null = New-Item -ItemType Directory -Path $runPath
    try {
        [IO.File]::WriteAllText($statePath, (@{
            runId=$runId; scopeId=$scopeId; state='RUNNING'; metadata=@{workflowKind='hyperv-lab'}
        } | ConvertTo-Json -Depth 4 -Compress))
        [IO.File]::WriteAllText($connectionPath, (@{
            instances=@(@{id='primary'; provider='hyperv'; vmName='synthetic-old'; vmId=$vmId})
        } | ConvertTo-Json -Depth 4 -Compress))
        $before = @(Get-FileHash -LiteralPath $statePath,$connectionPath | Select-Object -ExpandProperty Hash)
        $preview = & $module {
            param($PreviewFixtureRoot, $PreviewFixtureRunId, $PreviewFixtureScopeId, $PreviewFixtureVmId)
            function Get-HyperVLabVMs {
                param($RunId, $ScopeId)
                if ($RunId -ceq $PreviewFixtureRunId -and $ScopeId -ceq $PreviewFixtureScopeId) {
                    [pscustomobject]@{ VMName='synthetic-renamed'; VMId=$PreviewFixtureVmId }
                }
            }
            function Get-HyperVInstanceStatus {
                param($VMName, $ExpectedRunId, $ExpectedScopeId)
                if ($VMName -ceq 'synthetic-renamed' -and $ExpectedRunId -ceq $PreviewFixtureRunId -and $ExpectedScopeId -ceq $PreviewFixtureScopeId) {
                    [pscustomobject]@{ Exists=$true; State='Off' }
                }
            }
            function Get-LabMaintenanceContainerInventory { param($Provider) [pscustomobject]@{Provider=$Provider;Status='AVAILABLE';Resources=@()} }
            function Get-LabMaintenanceHyperVInventory { [pscustomobject]@{Provider='hyperv';Status='AVAILABLE';Resources=@()} }
            function Get-LabMaintenanceTempInventory { [pscustomobject]@{Resources=@()} }
            Get-SqlServerLabMaintenancePlan -StateRoot $PreviewFixtureRoot
        } $previewRoot $runId $scopeId $vmId
        $after = @(Get-FileHash -LiteralPath $statePath,$connectionPath | Select-Object -ExpandProperty Hash)
        $action = @($preview.Actions | Where-Object ActionType -eq 'SYNC_RUNTIME_STATE')
        Add-CheckResult -Name 'Maintenance-Preview liest eine umbenannte Hyper-V-VM und bewahrt beide Belege bytegenau' -Success (
            $action.Count -eq 1 -and $action[0].RunId -ceq $runId -and
            $action[0].TargetState -ceq 'STOPPED' -and ($before -join '|') -ceq ($after -join '|')
        )
    }
    finally {
        [IO.File]::Delete($connectionPath)
        [IO.File]::Delete($statePath)
        [IO.Directory]::Delete($runPath)
        [IO.Directory]::Delete((Join-Path $previewRoot 'runs'))
        [IO.Directory]::Delete($previewRoot)
    }

    $clearSource=Get-Content (Join-Path $repoRoot 'Public\Clear-SqlServerLab.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'StateOnly schützt vorhandene Hyper-V-Ressourcen' -Success (
        $clearSource -match 'Audit\.HyperV\.Resources' -and $clearSource -match 'runtimeResourcesForRun')
    $auditSource=Get-Content (Join-Path $repoRoot 'Public\Get-SqlServerLabCleanupAudit.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Cleanup-Audit projiziert unregistrierte Testartefakte' -Success (
        $auditSource -match 'UnregisteredTestArtifacts' -and $auditSource -match 'LEGACY_TEST_CANDIDATE')
    $hyperVSmoke=Get-Content (Join-Path $repoRoot 'Tests\Integration\Invoke-HyperVSmokeTest.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Hyper-V-Smoke markiert Testressourcen und eskaliert Cleanup-Reste' -Success (
        $hyperVSmoke -match '-Lifecycle test' -and $hyperVSmoke -match 'hinterliess Runtime-Ressourcen')
    $maintenanceSource=Get-Content (Join-Path $repoRoot 'Public\Maintenance.ps1') -Raw -Encoding utf8
    $maintenancePrivateSource=Get-Content (Join-Path $repoRoot 'Private\Maintenance.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Ressourcen-Revalidierung vergleicht die vollständige stabile ID' -Success (
        $maintenanceSource -notmatch 'Where-Object ResourceId -eq \[string\]' -and
        $maintenancePrivateSource -notmatch 'Where-Object ResourceId -eq \[string\]' -and
        $maintenanceSource -match '\[string\]\$_\.ResourceId -eq \[string\]\$action\.ResourceId' -and
        $maintenancePrivateSource -match '\[string\]\$_\.ResourceId -eq \[string\]\$Action\.ResourceId')
    $maintenanceToolSource=Get-Content (Join-Path $repoRoot 'Tools\Invoke-SqlServerLabMaintenance.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Maintenance-Wrapper bindet WhatIf und lehnt unbekannte Argumente ab' -Success (
        $maintenanceToolSource -match 'SupportsShouldProcess' -and
        $maintenanceToolSource -match 'WhatIf=\[bool\]\$WhatIfPreference' -and
        $maintenanceToolSource -match 'UNKNOWN_ARGUMENTS')
}
catch { Add-CheckResult -Name 'Maintenance-Testausführung' -Success $false -Message $_.Exception.Message }

Write-Host ''
if($failures.Count -gt 0){Write-Host "Maintenance Checks: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red;$failures|ForEach-Object{Write-Host "  - $_" -ForegroundColor Red};exit 1}
Write-Host "Maintenance Checks: $passed PASS" -ForegroundColor Green
exit 0
