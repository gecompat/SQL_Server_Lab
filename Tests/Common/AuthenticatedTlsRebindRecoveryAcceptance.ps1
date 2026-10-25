# Test-only injection at the existing post-replace certificate check. It is
# scoped to this exact new own lab and removed before any recovery invocation.
function Invoke-OwnedTlsInterruptedRebind {
    param([object]$Module,[object]$Lab)
    & $Module {
        param($lab)
        $script:acceptanceRecoveryCheck=${function:Assert-LabTlsSqlCertificateBinding}
        $script:acceptanceRecoveryRun=$lab.RunId
        $script:acceptanceRecoveryRoot=$lab.StateRoot
        function script:Assert-LabTlsSqlCertificateBinding {
            param([object]$Record,[string]$StateRoot,[object]$Budget)
            if($Record.RunId -cne $script:acceptanceRecoveryRun -or $StateRoot -cne $script:acceptanceRecoveryRoot){throw 'TLS_ACCEPTANCE_RECOVERY_SCOPE_CHANGED'}
            $bytes=Read-LabTlsCaPrivateFile (Join-Path $StateRoot 'authenticated-tls-lab.json') (Get-LabTlsWindowsProcessFacts).UserSid 32768
            $live=Read-LabTlsLabRecord $bytes
            if($live.StartedAt -ceq $Record.StartedAt){throw 'TLS_ACCEPTANCE_INJECTED_POST_REPLACE'}
            & $script:acceptanceRecoveryCheck -Record $Record -StateRoot $StateRoot -Budget $Budget
        }
    } $Lab
    $message=''
    try{
        $null=Update-SqlServerLabTlsBinding -RunId $Lab.RunId -InstanceId primary -StateRoot $Lab.StateRoot -Confirm:$false
    }catch{$message=$_.Exception.Message}
    finally{
        & $Module {
            Set-Item -LiteralPath function:script:Assert-LabTlsSqlCertificateBinding -Value $script:acceptanceRecoveryCheck
            Remove-Variable -Name acceptanceRecoveryCheck,acceptanceRecoveryRun,acceptanceRecoveryRoot -Scope Script
        }
    }
    if($message -cne 'TLS_REBIND_RECOVERY_REQUIRED'){throw 'TLS_ACCEPTANCE_POST_REPLACE_CUT_NOT_REACHED'}
    $pending=Get-SqlServerLabTlsBindingRecovery -RunId $Lab.RunId -InstanceId primary -StateRoot $Lab.StateRoot
    if($pending.Status -cne 'PENDING' -or $pending.QualificationStatus -cne 'NOT_EXECUTED'){throw 'TLS_ACCEPTANCE_PENDING_RECOVERY_REQUIRED'}
    return $pending
}

function Invoke-OwnedTlsRebindRecoveryScenario {
    param([object]$Module,[object]$Lab,[object]$Expected,[object]$Export,[string]$EvidenceDirectory,[object]$Results)
    $path=Join-Path $Lab.StateRoot 'authenticated-tls-lab.json'
    $firstSource=(Get-FileHash -LiteralPath $path).Hash
    $pending=Invoke-OwnedTlsInterruptedRebind $Module $Lab
    $candidate=(Get-FileHash -LiteralPath $path).Hash
    if($candidate -ceq $firstSource){throw 'TLS_ACCEPTANCE_CANDIDATE_NOT_INSTALLED'}
    $Results.Add(@{Case='REAL_REBIND_POST_REPLACE_CUT_REMAINS_PENDING';Status='PASS'})
    $blocked=$false
    try{$null=Test-SqlServerLabTlsQualification -RunId $Lab.RunId -InstanceId primary -StateRoot $Lab.StateRoot}catch{$blocked=$_.Exception.Message -ceq 'TLS_LIVE_QUALIFICATION_REJECTED'}
    if(-not $blocked){throw 'TLS_ACCEPTANCE_PENDING_QUALIFICATION_NOT_BLOCKED'}
    $Results.Add(@{Case='PENDING_TRANSACTION_BLOCKS_ORDINARY_QUALIFICATION';Status='PASS'})
    $null=Resolve-SqlServerLabTlsBindingRecovery -RunId $Lab.RunId -InstanceId primary -StateRoot $Lab.StateRoot -TransactionId $pending.TransactionId -Action Complete -WhatIf
    if((Get-FileHash -LiteralPath $path).Hash -cne $candidate){throw 'TLS_ACCEPTANCE_RECOVERY_WHATIF_MUTATED'}
    $completed=Resolve-SqlServerLabTlsBindingRecovery -RunId $Lab.RunId -InstanceId primary -StateRoot $Lab.StateRoot -TransactionId $pending.TransactionId -Action Complete -Confirm:$false
    if($completed.Status -cne 'QUALIFIED_METADATA_COMMITTED' -or $completed.QualificationStatus -cne 'QUALIFIED' -or
        (Get-FileHash -LiteralPath $path).Hash -cne $candidate){throw 'TLS_ACCEPTANCE_RECOVERY_COMPLETE_FAILED'}
    $Results.Add(@{Case='EXPLICIT_COMPLETE_WITH_TWO_FRESH_STRICT_CLIENTS';Status='PASS'})
    & $Module {param($lab,$export) if(Test-LabTlsQualifiedExport $export.JsonPath $lab.StateRoot $lab.RunId primary){throw 'TLS_ACCEPTANCE_RECOVERY_REVIVED_OLD_EXPORT'}} $Lab $Export
    $Results.Add(@{Case='OLD_EXPORT_REMAINS_INVALID_AFTER_RECOVERY';Status='PASS'})

    # A second actual restart supplies a separate, later transaction to roll back.
    $secondSource=(Get-FileHash -LiteralPath $path).Hash
    $stopped=Stop-SqlServerLab -RunId $Lab.RunId -StateRoot $Lab.StateRoot -Force -SkipHostMemoryRelease -Confirm:$false
    $started=Start-SqlServerLab -RunId $Lab.RunId -StateRoot $Lab.StateRoot
    if($stopped.Status -cne 'STOPPED' -or $stopped.Errors -gt 0 -or $started.Status -cne 'RUNNING' -or $started.Errors -gt 0){throw 'TLS_ACCEPTANCE_RECOVERY_RESTART_FAILED'}
    $rollbackPending=Invoke-OwnedTlsInterruptedRebind $Module $Lab
    $rolledBack=Resolve-SqlServerLabTlsBindingRecovery -RunId $Lab.RunId -InstanceId primary -StateRoot $Lab.StateRoot -TransactionId $rollbackPending.TransactionId -Action Rollback -Confirm:$false
    if($rolledBack.Status -cne 'ROLLED_BACK_UNQUALIFIED' -or $rolledBack.QualificationStatus -cne 'NOT_EXECUTED' -or
        (Get-FileHash -LiteralPath $path).Hash -cne $secondSource){throw 'TLS_ACCEPTANCE_RECOVERY_ROLLBACK_FAILED'}
    $Results.Add(@{Case='EXPLICIT_ROLLBACK_RESTORES_ONLY_OWN_PREDECESSOR';Status='PASS'})
    $blocked=$false
    try{$null=Test-SqlServerLabTlsQualification -RunId $Lab.RunId -InstanceId primary -StateRoot $Lab.StateRoot}catch{$blocked=$_.Exception.Message -ceq 'TLS_LIVE_QUALIFICATION_REJECTED'}
    if(-not $blocked){throw 'TLS_ACCEPTANCE_ROLLBACK_CLAIMED_QUALIFICATION'}
    $Results.Add(@{Case='ROLLED_BACK_EPOCH_IS_NOT_A_TLS_PASS';Status='PASS'})
    $rebound=Update-SqlServerLabTlsBinding -RunId $Lab.RunId -InstanceId primary -StateRoot $Lab.StateRoot -Confirm:$false
    if($rebound.Status -cne 'QUALIFIED_METADATA_COMMITTED' -or $rebound.QualificationStatus -cne 'QUALIFIED' -or $rebound.SqlBuild -cne $Expected.SqlBuild){throw 'TLS_ACCEPTANCE_REBIND_AFTER_ROLLBACK_FAILED'}
    $Results.Add(@{Case='LATER_EXPLICIT_REBIND_AFTER_ROLLBACK_TWO_STRICT_CLIENTS';Status='PASS'})
    $newExport=Export-SqlServerLabTestEnvironment -TrustServerCertificate:$false -RunId $Lab.RunId -InstanceId primary -StateRoot $Lab.StateRoot -OutputDirectory (Join-Path $Lab.StateRoot 'rebound-qualified-export')
    & $Module {param($lab,$output) if(-not(Test-LabTlsQualifiedExport $output.JsonPath $lab.StateRoot $lab.RunId primary)){throw 'TLS_ACCEPTANCE_RECOVERY_EXPORT_INVALID'}} $Lab $newExport
    $Results.Add(@{Case='NEW_QUALIFIED_EXPORT_AFTER_RECOVERY_TWO_STRICT_CLIENTS';Status='PASS'})
    & $Module {
        param($lab,$directory,$completed,$rolledBack,$rebound,$newExport)
        $sid=(Get-LabTlsWindowsProcessFacts).UserSid
        $receipt=[ordered]@{Completed=$completed;RolledBack=$rolledBack;Rebound=$rebound;Export=$newExport}
        Write-LabTlsCaPrivateFile (Join-Path $directory 'rebind-recovery.private.json') $sid (ConvertTo-LabTlsRegistryWriterBytes $receipt)
    } $Lab $EvidenceDirectory $completed $rolledBack $rebound $newExport
}
