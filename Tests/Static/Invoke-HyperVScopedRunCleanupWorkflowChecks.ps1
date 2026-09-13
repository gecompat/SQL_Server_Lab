#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')
$workflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\hyperv-scoped-run-cleanup.yml') -Raw -Encoding utf8

Add-CheckResult -Name 'Scoped cleanup is manual-only with one required RunId' -Success ($workflow -match '(?m)^on:\s*\r?$' -and $workflow -match '(?m)^\s{2}workflow_dispatch:\s*\r?$' -and $workflow -notmatch 'workflow_call|pull_request|\bschedule\b|\bpush\b' -and $workflow -match '(?s)run_id:.*?required:\s*true.*?type:\s*string')
Add-CheckResult -Name 'Scoped cleanup checks out main without persisted credentials' -Success ($workflow -match 'uses:\s*actions/checkout@v7' -and $workflow -match 'ref:\s*main' -and $workflow -match 'persist-credentials:\s*false')
Add-CheckResult -Name 'Scoped cleanup is bounded, serialized and confined to the Hyper-V runner' -Success ($workflow -match 'cancel-in-progress:\s*false' -and $workflow -match 'timeout-minutes:\s*45' -and $workflow -match 'runs-on:\s*\[self-hosted, SQL_Lab, Hyper-V\]')
Add-CheckResult -Name 'RunId crosses through env and must be GUID D' -Success ($workflow -match 'INPUT_RUN_ID:\s*\$\{\{ inputs\.run_id \}\}' -and $workflow -match '\[Guid\]::TryParseExact\(\$env:INPUT_RUN_ID, ''D''' -and $workflow -notmatch '\$\{\{ inputs\.run_id \}\}.*\.(ps1|exe|cmd)')
Add-CheckResult -Name 'StateRoot is fixed runner-local configuration without input or fallback' -Success ($workflow -match "GetFolderPath\(\[Environment\+SpecialFolder\]::LocalApplicationData\).*'SqlServerLab'" -and $workflow -notmatch 'Get-LabStateRoot|inputs\.state_root|StateRoot.*inputs')
Add-CheckResult -Name 'Required state, scope and Hyper-V-only plan fail closed before removal' -Success ($workflow -match "'run-state.json'" -and $workflow -match "'cleanup-plan.json'" -and $workflow -match "'connection-info.json'" -and $workflow -match 'HYPERV_SCOPED_CLEANUP_REQUIRED_STATE_MISSING' -and $workflow -match 'HYPERV_SCOPED_CLEANUP_STATE_SCOPE_INVALID' -and $workflow -match 'HYPERV_SCOPED_CLEANUP_PLAN_NOT_HYPERV_ONLY' -and $workflow -match "workflowKind -cne 'hyperv-lab'" -and $workflow -match "resourceType -notin @\('vm', 'vhdx', 'ipam-lease'\)")
Add-CheckResult -Name 'Live VM identity is exact, Hyper-V and lifecycle=test' -Success ($workflow -match 'Get-HyperVManagedVM -VMName \$VmName -ExpectedRunId \$ExpectedRunId -ExpectedScopeId \$ExpectedScopeId' -and $workflow -match "Identity\.lifecycle -cne 'test'" -and $workflow -match 'HYPERV_SCOPED_CLEANUP_LIVE_OWNERSHIP_INVALID' -and $workflow -notmatch 'Get-HyperVLabWorkflowRun')
Add-CheckResult -Name 'Only public removal executes and VM absence is fail-closed and sanitized' -Success ($workflow -match 'Remove-SqlServerLab -RunId \$runId -StateRoot \$stateRoot -Force -Confirm:\$false' -and $workflow -match 'HYPERV_SCOPED_CLEANUP_POSTCONDITION_FAILED' -and $workflow -match 'HYPERV_SCOPED_CLEANUP_STATUS=' -and $workflow -notmatch 'Remove-VM|Remove-Item|Remove-VHD')
