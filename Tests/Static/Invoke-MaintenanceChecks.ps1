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
            param([switch]$NoWrite)
            if (-not $NoWrite) { throw 'MAINTENANCE_RUN_INVENTORY_MUST_BE_READ_ONLY' }
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

    $guidedPlan = & $module {
        param($SyntheticPlan)
        function Get-SqlServerLabMaintenancePlan {
            [CmdletBinding()] param($Mode)
            if ($Mode -cne 'Runtime') { throw 'MAINTENANCE_GUIDANCE_MODE_INVALID' }
            $SyntheticPlan
        }
        Get-LabRuntimeMaintenancePreview
    } $plan
    Add-CheckResult -Name 'Geführter Wartungsplan projiziert Providerstatus und Zähler ohne Aktions- oder Pfaddaten' -Success (
        $guidedPlan.ContractVersion -ceq 'SqlServerLab.RuntimeMaintenancePreview/1.0' -and
        $guidedPlan.Status -ceq $plan.Status -and @($guidedPlan.Providers).Count -eq 3 -and
        $guidedPlan.Summary.Actions -eq $plan.Actions.Count -and $guidedPlan.Summary.LegacyApproval -eq 1 -and
        ($guidedPlan | ConvertTo-Json -Depth 6 -Compress) -notmatch 'synthetic-temp|lab-orphan|ResourceId|RunId|ForeignResources'
    )
    $guidedConsole = & $module {
        param($SyntheticView)
        function Show-LabSubMenu { param($ScreenId,$Title,$Subtitle,$Items) $Items }
        $unavailableFixture = $false
        function Get-LabRuntimeMaintenancePreview {
            if ($unavailableFixture) { throw 'SYNTHETIC_PREVIEW_UNAVAILABLE' }
            $SyntheticView
        }
        function Write-LabInfo { throw 'MAINTENANCE_PREVIEW_SESSION_WRITE' }
        function Write-LabWarning { throw 'MAINTENANCE_PREVIEW_SESSION_WRITE' }
        function Wait-LabConsoleAcknowledgement { param($Prompt) Write-Output 'ACKNOWLEDGED' }
        $items = @(Show-LabMaintenanceMenu)
        $entry = @($items | Where-Object Id -ceq 'RuntimeMaintenancePreview')
        if ($entry.Count -ne 1 -or @($items | Where-Object Shortcut -ceq $entry[0].Shortcut).Count -ne 1) { return $false }
        $output = (Invoke-LabMenuAction -ActionName $entry[0].Id 6>&1) -join [Environment]::NewLine
        $unavailableFixture = $true
        $failure = (Invoke-LabMenuAction -ActionName $entry[0].Id 6>&1) -join [Environment]::NewLine
        return $output -match 'Vorgeschlagene Aktionen: \d+' -and $output -match 'ACKNOWLEDGED' -and
            $failure -match 'konnte nicht gelesen werden' -and $failure -match 'ACKNOWLEDGED' -and
            $failure -notmatch 'SYNTHETIC_PREVIEW_UNAVAILABLE'
    } $guidedPlan
    Add-CheckResult -Name 'Geführte Wartungsvorschau meldet Ergebnis oder Fehler ohne Sitzungsjournal und wartet auf Bestätigung' -Success $guidedConsole
    $fullPreview = & $module {
        param($SyntheticPlan)
        function Get-SqlServerLabMaintenancePlan {
            [CmdletBinding()] param($Mode)
            if ($Mode -cne 'Full') { throw 'FULL_MODE_REQUIRED' }
            $SyntheticPlan.FullAudit = [pscustomobject]@{
                Summary = [pscustomobject]@{
                    ResidualCount = 3; UnverifiableProviders = 1; ManagedImages = 2; RuntimeBackingStores = 1
                    HyperVProtectionIssues = 2; HyperVUntrackedFiles = 1; RawPath = 'synthetic-private-audit-path'
                }
                Items = @('synthetic-private-audit-row')
            }
            $SyntheticPlan
        }
        function Show-LabSubMenu { param($ScreenId,$Title,$Subtitle,$Items) $Items }
        function Wait-LabConsoleAcknowledgement { param($Prompt) Write-Output 'ACKNOWLEDGED' }
        $action = Invoke-SqlServerLabWorkflowAction -Action ReadFullMaintenancePreview -ErrorAction Stop
        $entry = @(Show-LabMaintenanceMenu | Where-Object Id -ceq 'FullMaintenancePreview')
        if ($entry.Count -ne 1) { return $false }
        $console = (Invoke-LabMenuAction -ActionName $entry[0].Id 6>&1) -join [Environment]::NewLine
        $rejected = $false
        try { $null = Invoke-SqlServerLabWorkflowAction -Action ReadFullMaintenancePreview -Provider docker }
        catch { $rejected = $_.Exception.Message -ceq 'FULL_MAINTENANCE_PREVIEW_ARGUMENTS_INVALID' }
        return $rejected -and $action.Result.FullAudit.ResidualCount -eq 3 -and
            $console -match 'Befunde im Speicher- und Cleanup-Audit: 3' -and $console -match 'ACKNOWLEDGED' -and
            ($action | ConvertTo-Json -Depth 7 -Compress) -notmatch 'synthetic-private-audit|ResourceId|RunId'
    } $plan
    Add-CheckResult -Name 'Vollständiger Wartungsplan wird in CLI und Workflow lesend und ohne rohe Auditdaten geführt' -Success $fullPreview
    $routeAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot 'Tools/Start-SqlServerLabUi.ps1'), [ref]$null, [ref]$null)
    $route = $routeAst.Find({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -ceq '$path -ceq ''/api/runtime-maintenance-preview'''
    }, $true)
    $handler = [scriptblock]::Create('foreach ($once in @(1)) ' + $route.Clauses[0].Item2.Extent.Text)
    $guidedHttp = & {
        $responses = [Collections.Generic.List[object]]::new()
        $reads = [Collections.Generic.List[string]]::new()
        function Write-UiResponse {
            param($Context,$Body,$ContentType,$StatusCode=200)
            $responses.Add([pscustomobject]@{ Status=$StatusCode; Body=$Body | ConvertFrom-Json })
        }
        function Get-Module {
            param($Name)
            $reads.Add($Name)
            {
                param($Action)
                if ($Action.ToString().Trim() -cne 'Get-LabRuntimeMaintenancePreview -ErrorAction Stop') {
                    throw 'MAINTENANCE_PREVIEW_UNEXPECTED_DISPATCH'
                }
                $guidedPlan
            }
        }
        $request = [pscustomobject]@{ HttpMethod='GET'; HasEntityBody=$false; Url=[uri]'http://localhost/api/runtime-maintenance-preview' }
        $context = [pscustomobject]@{ Request=$request }
        & $handler
        $request.Url = [uri]'http://localhost/api/runtime-maintenance-preview?mode=Full'
        & $handler
        $request.Url = [uri]'http://localhost/api/runtime-maintenance-preview'
        $request.HttpMethod = 'POST'
        & $handler
        $reads.Count -eq 1 -and $reads[0] -ceq 'SqlServerLab' -and $responses.Count -eq 3 -and
            $responses[0].Status -eq 200 -and $responses[0].Body.ContractVersion -ceq $guidedPlan.ContractVersion -and
            @($responses[1..2] | Where-Object {
                $_.Status -ne 400 -or $_.Body.Code -cne 'RUNTIME_MAINTENANCE_PREVIEW_REQUEST_INVALID'
            }).Count -eq 0
    }
    Add-CheckResult -Name 'Wartungsvorschau-Route akzeptiert GET ohne Scope- oder Modusparameter' -Success $guidedHttp
    $actionRoute = $routeAst.Find({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -ceq '$path -eq ''/api/actions'' -and $context.Request.HttpMethod -eq ''POST'''
    }, $true)
    $actionHandler = [scriptblock]::Create('foreach ($once in @(1)) ' + $actionRoute.Clauses[0].Item2.Extent.Text)
    $fullHttp = & {
        $jobs = @{}
        $requestJson = '{"action":"ReadFullMaintenancePreview","parameters":{}}'
        function Read-UiJsonRequestBody { param($Request) @{ Allowed=$true; Body=$requestJson } }
        function New-SqlServerLabBatch { throw 'PERSISTENT_JOB_FOR_READ_FORBIDDEN' }
        function Start-UiWorkflowJob {
            param($Action,$Parameters)
            if ($Action -cne 'ReadFullMaintenancePreview' -or $Parameters.Count) { throw 'UNEXPECTED_JOB' }
            [pscustomobject]@{ Id='full-preview'; Action=$Action; Job=[pscustomobject]@{ State='Running' } }
        }
        function Write-UiResponse { param($Context,$Body,$ContentType,$StatusCode) [pscustomobject]@{ StatusCode=$StatusCode; Body=$Body | ConvertFrom-Json } }
        $accepted = & $actionHandler
        $busy = $invalid = $false
        try { $null = & $actionHandler }
        catch { $busy = $_.Exception.Message -ceq 'FULL_MAINTENANCE_PREVIEW_IN_PROGRESS' }
        $requestJson = '{"action":"ReadFullMaintenancePreview","parameters":{"Provider":"docker"}}'
        try { $null = & $actionHandler }
        catch { $invalid = $_.Exception.Message -ceq 'FULL_MAINTENANCE_PREVIEW_ARGUMENTS_INVALID' }
        $accepted.StatusCode -eq 202 -and $accepted.Body.id -ceq 'full-preview' -and $jobs.Count -eq 1 -and $busy -and $invalid
    }
    Add-CheckResult -Name 'Vollständige Browser-Inventur bleibt ein einzelner flüchtiger Job ohne Zielparameter' -Success $fullHttp

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
