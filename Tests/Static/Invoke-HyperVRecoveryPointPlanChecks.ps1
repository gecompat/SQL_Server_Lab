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