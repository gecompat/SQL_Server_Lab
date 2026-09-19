#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$helper = Join-Path $repoRoot 'Tests/Common/HyperVNetworkReconnectAcceptance.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-network-fixture-' + [guid]::NewGuid().ToString('N'))
$passed = 0
$failures = [Collections.Generic.List[string]]::new()
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
try {
    $null = New-Item -ItemType Directory -Path $testRoot
    Add-CheckResult -Name 'Existing-only Produktgrenze ohne Hostmutation' -Success ([bool](& (Join-Path $repoRoot 'Tests/Common/HyperVExistingNetworkFixture.ps1') -ProductPath (Join-Path $repoRoot 'Private/HyperVLabEnvironment.ps1')))
    Add-CheckResult -Name 'Supervisor und source-sicherer Cleanup' -Success ([bool](& (Join-Path $repoRoot 'Tests/Common/HyperVNetworkReconnectSupervisorFixture.ps1') -HelperPath (Join-Path $repoRoot 'Tests/Common/HyperVNetworkReconnectSupervisor.ps1')))
    foreach($relative in @('Tests/Common/HyperVNetworkReconnectWorker.ps1','Tests/Integration/Invoke-HyperVNetworkReconnectAcceptance.ps1')){
        $parseTokens=$null;$parseErrors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $relative),[ref]$parseTokens,[ref]$parseErrors)
        Add-CheckResult -Name "Runner-Syntax: $relative" -Success ($parseErrors.Count -eq 0)
    }
    $workerText=Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Common/HyperVNetworkReconnectWorker.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Worker verwendet SqlCredential ohne inkompatiblen Builder' -Success ($workerText -match 'Server=\{0\},\{1\};Database=master' -and $workerText -match 'SqlCredential' -and $workerText -notmatch 'SqlConnectionStringBuilder')
    $cloneText=Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Common/HyperVResourceAcceptanceSlotClone.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Clone persistiert die Operationsbindung vor der VM-Erstellung' -Success ($cloneText -match 'workflowOperationId=\$OperationId')
    $runnerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVNetworkReconnectAcceptance.ps1'),[ref]$parseTokens,[ref]$parseErrors)
    Add-CheckResult -Name 'Parent protokolliert Kindprozessausgabe lokal' -Success ($runnerAst.Extent.Text -match 'RedirectStandardOutput=\$true' -and $runnerAst.Extent.Text -match 'RedirectStandardError=\$true' -and $runnerAst.Extent.Text -match 'hyperv-network-worker-')
    $manifestPipelines=@($runnerAst.FindAll({param($node) $node -is [Management.Automation.Language.PipelineAst] -and $node.Extent.Text -match '^\[ordered\]@\{' -and $node.Extent.Text -match 'Set-Content -LiteralPath \$manifest'},$true))
    if($manifestPipelines.Count -ne 1){throw 'NETWORK_ACCEPTANCE_MANIFEST_LITERAL_MISSING'}
    $manifestValue=& ([scriptblock]::Create($manifestPipelines[0].PipelineElements[0].Extent.Text))
    $fixtureManifest=Join-Path $testRoot 'runner-manifest.json'
    $manifestValue | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fixtureManifest -Encoding utf8
    $productModule=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    try{Add-CheckResult -Name 'Exaktes natives Runner-Manifest ist gueltig' -Success (Test-SqlServerLabManifest -Path $fixtureManifest).IsValid}
    finally{Remove-Module -ModuleInfo $productModule -Force}
    foreach ($scenario in @('success','ownership','multiple','infrastructure','existingJournal','badPlan','whatIfMutation','whatIfAdapterDrift','whatIfVmDrift','whatIfSwitchDrift','applyFailure','disconnectFailure','foreignBinding','identityDrift','recoveryFailure','recoveryNoEffect')) {
        $caseRoot = Join-Path $testRoot $scenario
        $null = New-Item -ItemType Directory -Path $caseRoot
        $probe = & {
            param($Scenario, $Root, $Helper)
            . $Helper
            $state = @{ Disconnects=0; Connects=0; Applied=$false; ApplyCalls=0 }
            $adapter = [pscustomobject]@{ Id='synthetic-adapter'; SwitchName='synthetic-switch' }
            $context = [pscustomobject]@{
                VM=[pscustomobject]@{ Id='synthetic-vm' }; Adapters=@($adapter); RunDirectory=$Root
                ExpectedSwitchName='synthetic-switch'; BoundPlan=[pscustomobject]@{ Status='READY'; Actions=@() }
                Actual=[pscustomobject]@{ Status='MATCHED' }; DesiredInstance=[pscustomobject]@{ Network=[pscustomobject]@{ Intent='hostOnly' } }
            }
            $journalPath = Join-Path $Root 'journal.json'
            if ($Scenario -eq 'multiple') { $context.Adapters=@($adapter,$adapter) }
            if ($Scenario -eq 'infrastructure') { $context.BoundPlan.Actions=@('create-switch') }
            if ($Scenario -eq 'existingJournal') { '{}' | Set-Content -LiteralPath $journalPath }
            function Get-LabOperationOwnedRun { if ($Scenario -eq 'ownership') { return $null }; [pscustomobject]@{ runId='synthetic-run' } }
            function Get-LabHyperVNetworkReconcileContext { $context }
            function Get-LabHyperVNetworkReconcileJournalPath { $journalPath }
            function Disconnect-VMNetworkAdapter {
                $state.Disconnects++; $adapter.SwitchName=$null
                if ($Scenario -eq 'disconnectFailure') { throw 'SYNTHETIC_DISCONNECT_FAILURE' }
            }
            function Connect-VMNetworkAdapter {
                param($VMNetworkAdapter,$SwitchName)
                $state.Connects++
                if ($Scenario -eq 'recoveryFailure') { throw 'SYNTHETIC_RECOVERY_FAILURE' }
                if ($Scenario -ne 'recoveryNoEffect') { $VMNetworkAdapter.SwitchName=$SwitchName }
            }
            function Get-SqlServerLabReconcilePlan {
                if ($state.Applied) { return [pscustomobject]@{ IsNoOp=$true; Actions=@() } }
                [pscustomobject]@{ HighestChangeClass='live'; Actions=@([pscustomobject]@{ RepairKinds=@($(if($Scenario -eq 'badPlan'){'infrastructure'}else{'adapter-reconnect'})) }) }
            }
            function Invoke-SqlServerLabReconcileAction {
                param([switch]$WhatIf, $Confirm)
                if ($WhatIf) {
                    if ($Scenario -eq 'whatIfAdapterDrift') { $adapter.Id='foreign-adapter' }
                    if ($Scenario -eq 'whatIfVmDrift') { $context.VM.Id='foreign-vm' }
                    if ($Scenario -eq 'whatIfSwitchDrift') { $context.ExpectedSwitchName='foreign-switch' }
                    if ($Scenario -eq 'whatIfMutation') { '{}' | Set-Content -LiteralPath $journalPath }
                    return [pscustomobject]@{ ExecutionSummary=[pscustomobject]@{ Status='WOULD_EXECUTE' } }
                }
                $state.ApplyCalls++
                if ($Scenario -eq 'foreignBinding') { $adapter.SwitchName='foreign-switch' }
                if ($Scenario -eq 'identityDrift') { $adapter.Id='foreign-adapter' }
                if ($Scenario -in @('applyFailure','foreignBinding','identityDrift','recoveryFailure','recoveryNoEffect')) { throw 'SYNTHETIC_APPLY_FAILURE' }
                $state.Applied=$true; $adapter.SwitchName='synthetic-switch'
                '{"Status":"COMPLETED"}' | Set-Content -LiteralPath $journalPath
                [pscustomobject]@{ ExecutionSummary=[pscustomobject]@{ Status='SUCCEEDED' } }
            }
            $result=$null; $failure=$null
            try { $result=Invoke-HyperVNetworkReconnectAcceptanceStep -RunId synthetic-run -OperationId synthetic-operation -StateRoot $Root }
            catch { $failure=$_.Exception }
            [pscustomobject]@{ Result=$result; Failure=$failure; Disconnects=$state.Disconnects; Connects=$state.Connects; Switch=$adapter.SwitchName; ApplyCalls=$state.ApplyCalls }
        } $scenario $caseRoot $helper
        $ok = switch ($scenario) {
            'success' { $probe.Result.Status -eq 'PASS' -and $probe.Result.SqlEvidence -eq 'NOT_EXECUTED' -and $probe.Disconnects -eq 1 -and $probe.Connects -eq 0 }
            { $_ -in @('ownership','multiple','infrastructure','existingJournal') } { $null -ne $probe.Failure -and $probe.Disconnects -eq 0 -and $probe.Connects -eq 0 }
            'foreignBinding' { $probe.Failure.Message -match 'RECOVERY_FOREIGN_BINDING' -and $probe.Connects -eq 0 -and $probe.Switch -eq 'foreign-switch' }
            'identityDrift' { $probe.Failure.Message -match 'RECOVERY_IDENTITY_CHANGED' -and $probe.Connects -eq 0 }
            { $_ -in @('whatIfAdapterDrift','whatIfVmDrift','whatIfSwitchDrift') } {
                $probe.Failure -is [AggregateException] -and $probe.Failure.InnerExceptions.Count -eq 2 -and
                $probe.Failure.InnerExceptions[0].Message -eq 'HYPERV_NETWORK_ACCEPTANCE_PRE_APPLY_IDENTITY_CHANGED' -and
                $probe.Failure.InnerExceptions[1].Message -eq 'HYPERV_NETWORK_ACCEPTANCE_RECOVERY_IDENTITY_CHANGED' -and
                $probe.ApplyCalls -eq 0 -and $probe.Connects -eq 0 -and $probe.Disconnects -eq 1
            }
            'recoveryFailure' { $probe.Failure -is [AggregateException] -and $probe.Failure.InnerExceptions.Count -eq 2 -and $probe.Failure.InnerExceptions[0].Message -eq 'SYNTHETIC_APPLY_FAILURE' -and $probe.Failure.InnerExceptions[1].Message -eq 'SYNTHETIC_RECOVERY_FAILURE' }
            'recoveryNoEffect' { $probe.Failure.Message -match 'RECOVERY_POSTCONDITION_FAILED' -and $probe.Connects -eq 1 }
            default { $null -ne $probe.Failure -and $probe.Disconnects -eq 1 -and $probe.Connects -eq 1 -and $probe.Switch -eq 'synthetic-switch' }
        }
        Add-CheckResult -Name "Isolierter Netzwerk-Abnahmefall: $scenario" -Success ([bool]$ok)
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        if ($resolved -ne [IO.Path]::GetFullPath($testRoot)) { throw 'SYNTHETIC_NETWORK_CLEANUP_PATH_MISMATCH' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL"
if ($failures.Count) { exit 1 }
