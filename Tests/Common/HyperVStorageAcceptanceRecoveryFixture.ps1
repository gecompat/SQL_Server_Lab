#Requires -Version 7.2
# Execute the actual outer catch without importing a provider or touching a run.
function Test-HyperVStorageAcceptanceRecovery {
    param([Parameter(Mandatory)][string]$RunnerPath)
    $parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($RunnerPath,[ref]$null,[ref]$parseErrors)
    if($parseErrors.Count){throw 'Recovery fixture requires a valid runner'}
    $outerTry=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[-1]
    $handler=[scriptblock]::Create('try { throw "SYNTHETIC_CLONE_FAILURE" } '+$outerTry.CatchClauses[0].Extent.Text)
    foreach($case in @('Owned','NotOwned','NoRun','Existing','Keep','Ambiguous')){
        & {
            $OperationId='synthetic-operation';$StateRoot='synthetic-state';$testRoot='synthetic-temp'
            $ownsOperation=$case -ne 'NotOwned';$KeepOnFailure=$case -eq 'Keep'
            $lab=if($case -eq 'Existing'){[pscustomobject]@{RunId='existing-owned-run'}}else{$null}
            $probe=@{Calls=0}
            function Invoke-Private {
                param([scriptblock]$Block,[object[]]$Arguments)
                if($Arguments.Count -ne 2 -or $Arguments[0] -ne $OperationId -or $Arguments[1] -ne $StateRoot){throw 'RECOVERY_SCOPE_MISMATCH'}
                $probe.Calls++
                if($case -eq 'Ambiguous'){throw 'SYNTHETIC_AMBIGUOUS_OWNERSHIP'}
                if($case -ne 'NoRun'){[pscustomobject]@{runId='synthetic-owned-run'}}
            }
            $failure=$null
            try { . $handler } catch { $failure=$_.Exception.Message }
            $expectedError=if($case -eq 'Ambiguous'){'SYNTHETIC_AMBIGUOUS_OWNERSHIP'}else{'SYNTHETIC_CLONE_FAILURE'}
            if($failure -ne $expectedError){throw "Recovery error contract failed: $case"}
            $expectedCalls=if($case -in @('NotOwned','Existing')){0}else{1}
            if($probe.Calls -ne $expectedCalls){throw "Recovery lookup contract failed: $case"}
            $expectedRun=if($case -eq 'Existing'){'existing-owned-run'}elseif($case -in @('Owned','Keep')){'synthetic-owned-run'}else{''}
            if([string]$lab.RunId -ne $expectedRun){throw "Recovery ownership contract failed: $case"}
        }
    }
    return $true
}
