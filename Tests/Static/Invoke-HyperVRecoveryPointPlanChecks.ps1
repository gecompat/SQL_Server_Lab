#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$results = [Collections.Generic.List[object]]::new()
function Add-CheckResult { param([string]$Name,[bool]$Success) $results.Add([PSCustomObject]@{Name=$Name;Success=$Success});Write-Host "$(if($Success){'PASS'}else{'FAIL'}): $Name" -ForegroundColor $(if($Success){'Green'}else{'Red'}) }
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    $routeChecks = & $module {
        param($Repository)
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository 'Tools/Start-SqlServerLabUi.ps1'), [ref]$tokens, [ref]$parseErrors)
        $route = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -ceq '$path -ceq ''/api/hyperv-recovery-point-plan'''
        }, $true)
        if ($parseErrors.Count -or -not $route) { throw 'HYPERV_RECOVERY_POINT_ROUTE_MISSING' }
        $routeScript = [scriptblock]::Create('foreach ($once in @(1)) ' + $route.Clauses[0].Item2.Extent.Text)
        $query = [Collections.Specialized.NameValueCollection]::new()
        $context = [pscustomobject]@{ Request = [pscustomobject]@{ HttpMethod='GET'; HasEntityBody=$false; QueryString=$query } }
        $responses = [Collections.Generic.List[object]]::new()
        $calls = [Collections.Generic.List[object]]::new()
        function Write-UiResponse { param($Context,$Body,$ContentType,$StatusCode=200) $responses.Add(@{Status=$StatusCode;Body=$Body}) }
        function Get-SqlServerLabHyperVRecoveryPointPlan {
            [CmdletBinding()] param($RunId,$InstanceId,$StateRoot)
            $calls.Add(@($RunId,$InstanceId))
            [pscustomobject]@{ Status='NO_ACTION'; RunId=$RunId; InstanceId=$InstanceId }
        }
        $runId = '5defd56c-a51a-4d32-bc4f-8bf10662e7bd'
        $query.Add('runId', $runId)
        $query.Add('instanceId', 'primary')
        & $routeScript
        $query.Add('instanceId', 'duplicate')
        & $routeScript
        $query.Set('instanceId', 'primary')
        $query.Set('runId', '../foreign')
        & $routeScript
        $received = $responses[0].Body | ConvertFrom-Json
        $responses.Count -eq 3 -and $responses[0].Status -eq 200 -and $responses[1].Status -eq 400 -and
            $responses[2].Status -eq 400 -and $calls.Count -eq 1 -and $received.RunId -ceq $runId -and $received.InstanceId -ceq 'primary'
    } $repoRoot
    Add-CheckResult 'Browser bindet das Checkpoint-Inventar nur an eine eindeutige Run- und Instanz-ID' $routeChecks
    $consoleChecks = & $module {
        $expectedRun = '5defd56c-a51a-4d32-bc4f-8bf10662e7bd'
        $expectedRoot = Join-Path ([IO.Path]::GetTempPath()) 'synthetic-lab-state'
        function Get-LabStateRoot { $expectedRoot }
        function Get-LabActiveRuns {
            param($StateRoot,[switch]$NoWrite)
            if (-not $NoWrite -or $StateRoot -cne $expectedRoot) { throw 'HYPERV_RECOVERY_POINT_CONSOLE_WRITE' }
            [pscustomobject]@{ runId=$expectedRun; metadata=@{workflowKind='hyperv-lab'} }
        }
        function Select-LabRun { param($Runs,$Prompt,[switch]$DisableAutomatedTestEnvironments,[switch]$DisableSystemServices) $Runs[0].runId }
        function Get-Content {
            [CmdletBinding()] param($LiteralPath,[switch]$Raw,$Encoding)
            if ($LiteralPath -cne (Join-Path $expectedRoot "runs/$expectedRun/connection-info.json")) { throw 'HYPERV_RECOVERY_POINT_CONSOLE_FOREIGN_PATH' }
            '{"instances":[{"id":"primary","provider":"hyperv"}]}'
        }
        function Get-SqlServerLabHyperVRecoveryPointPlan {
            [CmdletBinding()] param($RunId,$InstanceId,$StateRoot)
            if ($RunId -cne $expectedRun -or $InstanceId -cne 'primary' -or $StateRoot -cne $expectedRoot) { throw 'HYPERV_RECOVERY_POINT_CONSOLE_BINDING' }
            [pscustomobject]@{ Status='NO_ACTION' }
        }
        function Write-LabError { param($Message) throw $Message }
        function Wait-LabConsoleAcknowledgement {}
        (Invoke-LabMenuAction -ActionName HyperVRecoveryPointPlan 6>&1 | Out-String) -match 'keine Checkpoints vorhanden'
    }
    Add-CheckResult 'Konsolenwahl bindet das lesende Inventar an die registrierte Hyper-V-Instanz' $consoleChecks
    $result = & $module {
        function script:Get-LabHyperVRecoveryPointContext { param($RunId,$InstanceId,$StateRoot) [PSCustomObject]@{RunId=$RunId;InstanceId=$InstanceId;Managed=[PSCustomObject]@{VM=[PSCustomObject]@{Name='private-host-vm'}}} }
        function script:Get-LabHyperVRecoveryPointCandidates { param($Context) @([PSCustomObject]@{RecoveryPointId='11111111-1111-1111-1111-111111111111';Kind='PRODUCTION';CreatedAt='2026-09-09T12:00:00.0000000Z'}) }
        $ready = Get-SqlServerLabHyperVRecoveryPointPlan -RunId 'run-001' -InstanceId 'primary'
        function script:Get-LabHyperVRecoveryPointContext { param($RunId,$InstanceId,$StateRoot) throw 'HYPERV_RECOVERY_POINT_VM_NOT_FOUND' }
        $blocked = Get-SqlServerLabHyperVRecoveryPointPlan -RunId 'run-002' -InstanceId 'primary'
        [PSCustomObject]@{Ready=$ready;Blocked=$blocked}
    }
    Add-CheckResult 'Gebundene Hyper-V-Checkpoints werden als read-only Recovery-Point-Plan inventarisiert' ($result.Ready.Status -eq 'READY' -and $result.Ready.Action -eq 'REVIEW_RECOVERY_POINTS' -and -not $result.Ready.ExecutionImplemented -and $result.Ready.RecoveryPoints[0].Kind -eq 'PRODUCTION')
    Add-CheckResult 'Unklare VM-Bindung blockiert den Recovery-Point-Plan fail-closed' ($result.Blocked.Status -eq 'BLOCKED' -and $result.Blocked.Action -eq 'MANUAL_REVIEW_REQUIRED' -and 'HYPERV_RECOVERY_POINT_VM_NOT_FOUND' -in $result.Blocked.Blockers)
    Add-CheckResult 'Recovery-Point-Plan enthält keine VM-Namen oder Hostpfade' ((($result | ConvertTo-Json -Depth 20) -notmatch 'private-host-vm') -and (($result | ConvertTo-Json -Depth 20) -notmatch '[A-Za-z]:\\'))
    Add-CheckResult 'Recovery-Point-Plan erfüllt den versionierten JSON-Schema-Vertrag' ((($result.Ready | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/hyperv-recovery-point-plan.schema.json') -ErrorAction SilentlyContinue) -and (($result.Blocked | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/hyperv-recovery-point-plan.schema.json') -ErrorAction SilentlyContinue))
}
finally { Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue }

$failed = @($results | Where-Object { -not $_.Success })
if ($failed.Count -gt 0) { throw "HYPERV RECOVERY POINT PLAN CHECKS FAILED: $($failed.Name -join '; ')" }
Write-Host "HYPERV RECOVERY POINT PLAN CHECKS: PASS ($($results.Count))" -ForegroundColor Green
