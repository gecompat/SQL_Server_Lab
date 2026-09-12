#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$results = [Collections.Generic.List[object]]::new()
function Add-CheckResult { param([string]$Name,[bool]$Success) $results.Add([PSCustomObject]@{Name=$Name;Success=$Success}); Write-Host "$(if($Success){'PASS'}else{'FAIL'}): $Name" -ForegroundColor $(if($Success){'Green'}else{'Red'}) }
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    $result = & $module {
        function script:Get-LabTimestamp { '2026-09-12T00:00:00.0000000Z' }
        $before = Get-LabAutomationApiPlan -Action Reconcile | ConvertTo-Json -Depth 20 -Compress
        $again = Get-LabAutomationApiPlan -Action Reconcile
        $invalid = Get-SqlServerLabAutomationPlan -Action 'C:\private\token=not-for-output'
        $missing = Get-SqlServerLabAutomationPlan
        [PSCustomObject]@{ Before=$before; Again=$again; Invalid=$invalid; Missing=$missing }
    }
    $schemaPath = Join-Path $repoRoot 'Schemas/automation-api-plan.schema.json'
    Add-CheckResult 'Automation-Plan bindet bestehende öffentliche Plan-/Action-Verträge ohne Executor' (
        $result.Again.ContractVersion -eq 'SqlServerLab.AutomationApiPlan/1.0' -and
        $result.Again.Plan.Command -eq 'Get-SqlServerLabReconcilePlan' -and
        $result.Again.Result.ActionCommand -eq 'Invoke-SqlServerLabReconcileAction' -and
        -not $result.Again.ExecutionImplemented -and -not $result.Again.Result.ExecutionImplemented)
    Add-CheckResult 'Automation-Planidentität ist für denselben Action-Wert deterministisch' (
        $result.Again.PlanId -eq ((Get-SqlServerLabAutomationPlan -Action Reconcile).PlanId) -and
        $result.Again.PlanKey -match '^[a-f0-9]{64}$')
    Add-CheckResult 'Automation-Plan erfüllt den versionierten Schema-Vertrag' ((($result.Again | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue))
    Add-CheckResult 'Ungültige Eingaben werden ohne Wertreflexion fail-closed sanitisiert' (
        $result.Invalid.Status -eq 'BLOCKED' -and 'AUTOMATION_ACTION_UNSUPPORTED' -in $result.Invalid.Blockers -and
        (($result.Invalid | ConvertTo-Json -Depth 20) -notmatch 'private|token=not-for-output|[A-Za-z]:\\'))
    Add-CheckResult 'Fehlende Eingaben liefern einen strukturierten Blocker' ($result.Missing.Status -eq 'BLOCKED' -and 'AUTOMATION_ACTION_REQUIRED' -in $result.Missing.Blockers)
    $endpointSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/AutomationApiPlan.ps1') -Raw -Encoding utf8
    Add-CheckResult 'Der Endpoint erzeugt keine State-, Runtime- oder Netzwerk-Seiteneffekte' (
        $result.Before -eq (($result.Again | ConvertTo-Json -Depth 20 -Compress)) -and
        $endpointSource -notmatch 'Get-LabStateRoot|Get-LabRunState|Set-Content|Add-Content|New-Item|Remove-Item|Invoke-WebRequest|Invoke-RestMethod|Get-VMSnapshot|docker|podman')
}
finally { Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue }
$failed = @($results | Where-Object { -not $_.Success })
if ($failed.Count -gt 0) { throw "AUTOMATION API PLAN CHECKS FAILED: $($failed.Name -join '; ')" }
Write-Host "AUTOMATION API PLAN CHECKS: PASS ($($results.Count))" -ForegroundColor Green
