function Get-LabRunStateUpgradePlanView {
    param([Parameter(Mandatory)][string]$RunId)
    $identity = [guid]::Empty
    if (-not [guid]::TryParseExact($RunId, 'D', [ref]$identity) -or $identity -eq [guid]::Empty) {
        throw 'RUN_STATE_UPGRADE_GUIDANCE_TARGET_INVALID'
    }
    $stateRoot = Get-LabStateRoot
    $boundId = $identity.ToString('D')
    $path = Join-Path $stateRoot "runs/$boundId/run-state.json"
    $null = Assert-LabDiagnosticPath -Path $path
    $item = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -gt 1048576) { throw 'RUN_STATE_UPGRADE_GUIDANCE_TARGET_INVALID' }
    $plan = Get-SqlServerLabRunStateUpgradePlan -RunId $boundId -StateRoot $stateRoot -ErrorAction Stop
    $source = if ($plan.SourceContractVersion -cin @('SqlServerLab.RunState/1.0','UNVERSIONED_LEGACY')) {
        $plan.SourceContractVersion
    } else { 'UNSUPPORTED' }
    $blockers = @(foreach ($blocker in $plan.Blockers) {
        if ([string]$blocker -cmatch '\A(RUN_STATE_[A-Z_]{1,64})(?=:|\z)') { $Matches[1] }
        else { 'RUN_STATE_UPGRADE_GUIDANCE_UNAVAILABLE' }
    })
    [pscustomobject]@{
        RunId=$boundId; Status=$plan.Status; Source=$source; Target=$plan.TargetContractVersion
        SyntheticFixture=$plan.SyntheticFixture
        Changes=@($plan.Changes | ForEach-Object Kind)
        Blockers=@($blockers | Sort-Object -Unique)
    }
}

function Show-LabRunStateUpgradePlanInteractive {
    $runs = @(Get-LabActiveRuns -NoWrite)
    if (-not $runs.Count) {
        Write-Host 'Kein lokaler Run für die State-Formatprüfung gefunden.'
        $null = Wait-LabConsoleAcknowledgement
        return
    }
    $runId = Select-LabRun -Runs $runs -Prompt 'Run für die State-Formatprüfung' -DisableAutomatedTestEnvironments -DisableSystemServices
    if (-not $runId) { return }
    try {
        $view = Get-LabRunStateUpgradePlanView -RunId $runId
        Write-Host ('Status: {0} · Format: {1} → {2}' -f $view.Status, $view.Source, $view.Target)
        if ($view.Changes.Count) { Write-Host ('Geplante Felder: ' + ($view.Changes -join ', ')) }
        if ($view.Blockers.Count) { Write-Host ('Blocker: ' + ($view.Blockers -join ', ')) }
    }
    catch { Write-Host 'Das State-Format konnte nicht geprüft werden.' -ForegroundColor Yellow }
    $null = Wait-LabConsoleAcknowledgement
}
