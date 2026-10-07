#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$root = Join-Path $repo ('.artifacts/test-runs/run-artifact-console-' + [guid]::NewGuid().ToString('N'))
$module = Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
try {
    & $module {
        param($Root)
        $script:consoleChecks = 0
        $script:consoleRoot = $Root
        $script:consoleState = Join-Path $Root 'State'
        $script:consoleRunId = '11111111-2222-4333-8444-555555555555'
        $script:consoleKey = 'a' * 64
        $runDirectory = Join-Path $script:consoleState ('runs/' + $script:consoleRunId)
        $null = New-Item -ItemType Directory -Path $runDirectory -Force
        $statePath = Join-Path $runDirectory 'run-state.json'
        [IO.File]::WriteAllText($statePath, (@{runId=$script:consoleRunId;state='REMOVED';metadata=@{name='Synthetic removed lab'}} | ConvertTo-Json))
        $before = (Get-FileHash -LiteralPath $statePath).Hash
        function Check-Console { param([bool]$Condition, [string]$Name)
            if (-not $Condition) { throw "RUN_ARTIFACT_CONSOLE_CHECK_FAILED: $Name" }
            $script:consoleChecks++; Write-Host "PASS: $Name"
        }
        function Get-LabDataRootDefault { $script:consoleRoot }
        function Get-LabStateRoot { $script:consoleState }
        function Get-LabStorageConfiguration { param($DataRoot)
            [pscustomobject]@{LabDataLocations=@([pscustomobject]@{LabDataRoot=if ($script:mode -ceq 'UNREGISTERED') {'synthetic-other-root'} else {$script:consoleRoot}})}
        }
        function Get-LabWorkflowLifecycleFingerprint { 'unchanged' }
        function Sync-LabConnectionCenterAfterLifecycle { throw 'FORBIDDEN_SYNC' }
        function Wait-LabConsoleAcknowledgement { $script:waits++ }
        function Write-LabInfo { param($Message) $script:output.Add([string]$Message) }
        function Write-LabWarning { param($Message) $script:output.Add([string]$Message) }
        function Write-LabStatus { param($Label,$Value) $script:output.Add("$Label $Value") }
        function Show-LabSubMenu { param($ScreenId,$Title,$Subtitle,$Items)
            Check-Console ('RunArtifactRemoval' -cin @($Items.Id)) 'actual maintenance menu contains dedicated action'
            'RunArtifactRemoval'
        }
        function Invoke-LabConsoleMenu { param($ScreenId,$Title,$Subtitle,$Items)
            $script:output.Add([string]$Subtitle)
            if ($ScreenId -ceq 'run-artifact-removal') {
                $script:candidateMenus++
                if ($script:mode -ceq 'F5_SELECTION' -and $script:candidateMenus -eq 1) { return [pscustomobject]@{Status='Refresh';SelectedItem=$null} }
                $script:candidateIds = @($Items.Id)
                if ($script:mode -ceq 'CANCEL_SELECTION') { return [pscustomobject]@{Status='Cancelled';SelectedItem=$null} }
                $id = if ($script:mode -ceq 'FOREIGN_SELECTION') {'99999999-2222-4333-8444-555555555555'} else {$script:consoleRunId}
            }
            else {
                if ($script:mode -ceq 'F5_REVIEW' -and $script:plans -eq 1) { return [pscustomobject]@{Status='Refresh';SelectedItem=$null} }
                $script:applyDisabled = @($Items | Where-Object Id -CEQ apply)[0].Disabled
                if ($script:mode -ceq 'CANCEL_REVIEW') { return [pscustomobject]@{Status='Cancelled';SelectedItem=$null} }
                $id = if ($script:mode -ceq 'REFRESH' -and $script:plans -eq 1) {'refresh'} else {'apply'}
            }
            [pscustomobject]@{Status='Selected';SelectedItem=[pscustomobject]@{Id=$id}}
        }
        function Read-LabConfirm { param($Prompt,$Default)
            $script:confirms++; $script:defaultFalse = $Default -ceq $false
            $script:mode -cne 'DECLINE'
        }
        function Get-LabRunArtifactRemovalContext { param($RunId,$StateRoot,$DataRoot)
            $script:plans++
            Check-Console ($RunId -ceq $script:consoleRunId -and $StateRoot -ceq $script:consoleState -and $DataRoot -ceq $script:consoleRoot) 'public plan uses selected RunId and server roots'
            if ($script:mode -ceq 'PLAN_RAW_ERROR') { throw 'PRIVATE_RAW_ERROR_CANARY' }
            $plan = [pscustomobject]@{Status='READY';CanApply=$true;PlanKey=$script:consoleKey;FileCount=3}
            if ($script:mode -ceq 'BLOCKED') { throw 'RUN_ARTIFACT_HYPERV_ABSENCE_UNVERIFIABLE' }
            if ($script:mode -ceq 'STRING_BOOL') { $plan.CanApply='true' }
            if ($script:mode -ceq 'BAD_KEY') { $plan.PlanKey='PRIVATE_PLAN_KEY_CANARY' }
            if ($script:mode -ceq 'RECOVERY') { $plan.Status='RECOVERY_REQUIRED' }
            if ($script:mode -ceq 'REMOVED') { $plan.Status='REMOVED';$plan.CanApply=$false;$plan.FileCount=0 }
            $plan
        }
        function Invoke-LabRunArtifactRemoval { param($RunId,$StateRoot,$DataRoot,$ExpectedPlanKey)
            $script:applies++
            Check-Console ($RunId -ceq $script:consoleRunId -and $StateRoot -ceq $script:consoleState -and $DataRoot -ceq $script:consoleRoot -and $ExpectedPlanKey -ceq $script:consoleKey) 'public apply retains preview binding'
            if ($script:mode -ceq 'STALE') { throw 'RUN_ARTIFACT_PREVIEW_STALE' }
            if ($script:mode -ceq 'APPLY_RAW_ERROR') { throw 'PRIVATE_RAW_ERROR_CANARY' }
            [pscustomobject]@{RunId=if ($script:mode -ceq 'FOREIGN_RESULT') {'PRIVATE_RESULT_CANARY'} else {$RunId};Status='REMOVED';Changed=$true}
        }
        function Run-ConsoleCase { param([string]$Mode='READY',[switch]$Direct)
            $script:mode=$Mode; $script:plans=0; $script:applies=0; $script:confirms=0; $script:waits=0
            $script:candidateMenus=0
            $script:output=[Collections.Generic.List[string]]::new();$script:applyDisabled=$false;$script:defaultFalse=$false
            if ($Direct) { Invoke-SqlServerLab -Action RunArtifactRemoval }
            else { $action=Show-LabMaintenanceMenu; Invoke-LabMenuAction -ActionName $action }
            [pscustomobject]@{Plans=$script:plans;Applies=$script:applies;Confirms=$script:confirms;Disabled=$script:applyDisabled;
                Output=($script:output -join "`n");DefaultFalse=$script:defaultFalse;Waits=$script:waits;CandidateMenus=$script:candidateMenus}
        }
        $candidates = @(Get-LabRunArtifactRemovalConsoleCandidates -StateRoot $script:consoleState)
        Check-Console ($candidates.Count -eq 1 -and $candidates[0].Label -ceq 'Synthetic removed lab') 'metadata discovery includes named REMOVED run'
        $r=Run-ConsoleCase
        Check-Console ($r.Plans -eq 1 -and $r.Applies -eq 1 -and $r.Confirms -eq 1 -and $r.DefaultFalse -and $r.Waits -eq 1) 'actual menu -> router -> public preview -> confirmed public apply'
        Check-Console ($r.Output -match 'Artefaktentfernung REMOVED') 'bound result is displayed'
        $r=Run-ConsoleCase -Direct
        Check-Console ($r.Plans -eq 1 -and $r.Applies -eq 1) 'public direct Action uses same handler'
        foreach ($mode in @('CANCEL_SELECTION','FOREIGN_SELECTION','UNREGISTERED')) {
            $r=Run-ConsoleCase $mode
            Check-Console ($r.Plans -eq 0 -and $r.Applies -eq 0 -and $r.Confirms -eq 0) "$mode has no preview or apply"
        }
        foreach ($mode in @('CANCEL_REVIEW','DECLINE','BLOCKED','STRING_BOOL','BAD_KEY','PLAN_RAW_ERROR','REMOVED')) {
            $r=Run-ConsoleCase $mode
            Check-Console ($r.Plans -eq 1 -and $r.Applies -eq 0) "$mode has no apply"
            Check-Console ($r.Output -notmatch 'PRIVATE_') "$mode does not expose raw evidence"
        }
        $r=Run-ConsoleCase BLOCKED
        Check-Console ($r.Disabled -and $r.Confirms -eq 0 -and $r.Output -match 'VHDX') 'blocked plan remains explained and cannot be forced by selection'
        $r=Run-ConsoleCase REFRESH
        Check-Console ($r.Plans -eq 2 -and $r.Applies -eq 1) 'explicit refresh reads once per requested preview'
        $r=Run-ConsoleCase F5_SELECTION
        Check-Console ($r.CandidateMenus -eq 2 -and $r.Plans -eq 1 -and $r.Applies -eq 1) 'F5 refreshes metadata selection without an early public preview'
        $r=Run-ConsoleCase F5_REVIEW
        Check-Console ($r.Plans -eq 2 -and $r.Applies -eq 1) 'F5 refreshes the public preview instead of leaving the dialog'
        $r=Run-ConsoleCase RECOVERY
        Check-Console ($r.Applies -eq 1 -and $r.Output -match 'vorwärts') 'recovery uses same public plan and bound apply'
        foreach ($mode in @('STALE','APPLY_RAW_ERROR','FOREIGN_RESULT')) {
            $r=Run-ConsoleCase $mode
            Check-Console ($r.Applies -eq 1 -and $r.Output -notmatch 'Artefaktentfernung REMOVED|PRIVATE_' -and $r.Output -match 'nicht bestätigt') "$mode neither retries nor claims success"
        }
        Check-Console ((Get-FileHash -LiteralPath $statePath).Hash -ceq $before) 'handler control tests leave metadata bytes unchanged'
        $journalDirectory=Join-Path $script:consoleState ('run-artifact-removals/' + $script:consoleRunId)
        $null=New-Item -ItemType Directory -Path $journalDirectory -Force
        [IO.File]::WriteAllText((Join-Path $journalDirectory 'journal.json'),'{}')
        $candidates=@(Get-LabRunArtifactRemovalConsoleCandidates -StateRoot $script:consoleState)
        Check-Console ($candidates.Count -eq 1 -and $candidates[0].Label -match 'Artefaktvorgang') 'same run and journal deduplicate'
        [IO.File]::Delete($statePath)
        $candidates=@(Get-LabRunArtifactRemovalConsoleCandidates -StateRoot $script:consoleState)
        Check-Console ($candidates.Count -eq 1 -and $candidates[0].RunId -ceq $script:consoleRunId) 'staged recovery remains discoverable without run-state'
        [IO.File]::Delete((Join-Path $journalDirectory 'journal.json'))
        $r=Run-ConsoleCase
        Check-Console ($r.Plans -eq 0 -and $r.Applies -eq 0 -and $r.Output -match 'Keine entfernten') 'empty discovery does not read a provider'
        Write-Host "RUN ARTIFACT CONSOLE CHECKS: $script:consoleChecks PASS"
    } $root
}
finally {
    $boundary=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/test-runs')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if ([IO.Path]::GetFullPath($root).StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $root)) { Remove-Item -LiteralPath $root -Recurse -Force }
    Remove-Module $module.Name -Force
}
