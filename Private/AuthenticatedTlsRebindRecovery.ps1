#Requires -Version 7.2
# Explicit recovery of an incomplete own metadata-only restart transaction.
function Assert-LabTlsRebindStringFields {
    param([object]$Value,[string[]]$Fields)
    foreach($field in $Fields){
        if($Value.$field -isnot [string]){throw 'TLS_REBIND_RECOVERY_REQUIRED'}
    }
}

function Read-LabTlsRebindTransaction {
    param([IO.DirectoryInfo]$Directory,[string]$Sid,[string]$IdentitySha256)
    if($Directory.Name -cnotmatch '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'){throw 'TLS_REBIND_STORAGE_UNKNOWN'}
    Assert-LabTlsCaPrivateAcl $Directory.FullName $Sid -Directory
    $allowed=@('original.json','candidate.json','intent.json','candidate-write.json','source.json','commit.json',
        'rollback-intent.json','rollback-write.json','rollback-source.json','rollback-commit.json')
    $files=[Collections.Generic.Dictionary[string,byte[]]]::new([StringComparer]::Ordinal)
    foreach($file in @(Get-ChildItem -LiteralPath $Directory.FullName -Force)){
        if($file.PSIsContainer -or $file.Name -cnotin $allowed){throw 'TLS_REBIND_STORAGE_UNKNOWN'}
        $files.Add($file.Name,(Read-LabTlsCaPrivateFile $file.FullName $Sid 32768))
    }
    foreach($name in @('original.json','candidate.json','intent.json')){if(-not $files.ContainsKey($name)){throw 'TLS_REBIND_RECOVERY_REQUIRED'}}
    $intent=Read-LabTlsBoundJson $files['intent.json'] @('ContractVersion','TransactionId','Sequence','SourceSha256','CandidateSha256')
    Assert-LabTlsRebindStringFields $intent @('ContractVersion','TransactionId','SourceSha256','CandidateSha256')
    if($intent.ContractVersion -cne 'SqlServerLab.TlsRebindIntent/0.1' -or $intent.TransactionId -cne $Directory.Name -or
        $intent.Sequence -isnot [long] -or $intent.Sequence -lt 1 -or $intent.Sequence -gt 64 -or
        $intent.SourceSha256 -isnot [string] -or $intent.SourceSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
        $intent.CandidateSha256 -isnot [string] -or $intent.CandidateSha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'TLS_REBIND_RECOVERY_REQUIRED'}
    foreach($name in @('original.json','source.json','rollback-write.json')){
        if($files.ContainsKey($name) -and (Get-LabTlsCaByteDigest $files[$name]) -cne $intent.SourceSha256){throw 'TLS_REBIND_RECOVERY_REQUIRED'}
    }
    foreach($name in @('candidate.json','candidate-write.json','rollback-source.json')){
        if($files.ContainsKey($name) -and (Get-LabTlsCaByteDigest $files[$name]) -cne $intent.CandidateSha256){throw 'TLS_REBIND_RECOVERY_REQUIRED'}
    }
    $original=Read-LabTlsLabRecord $files['original.json'];$candidate=Read-LabTlsLabRecord $files['candidate.json']
    Assert-LabTlsRestartCandidate $original $candidate
    if((Get-LabTlsRebindIdentityDigest $candidate) -cne $IdentitySha256){throw 'TLS_REBIND_STORAGE_OWNER_CHANGED'}
    $hasSource=$files.ContainsKey('source.json');$hasRollback=$files.ContainsKey('rollback-intent.json')
    if(($hasSource -and $files.ContainsKey('candidate-write.json')) -or
        (-not $hasSource -and $files.ContainsKey('rollback-write.json')) -or
        ($files.ContainsKey('rollback-source.json') -and (-not $hasSource -or $files.ContainsKey('rollback-write.json'))) -or
        (-not $hasRollback -and @($files.Keys|Where-Object {$_.StartsWith('rollback-',[StringComparison]::Ordinal)}).Count)){
        throw 'TLS_REBIND_RECOVERY_REQUIRED'
    }
    $status='PENDING';$head=$intent.CandidateSha256;$current=$(if($hasSource){$intent.CandidateSha256}else{$intent.SourceSha256})
    if($files.ContainsKey('commit.json')){
        if($hasRollback -or -not $hasSource -or $files.Count -ne 5){throw 'TLS_REBIND_RECOVERY_REQUIRED'}
        $commit=Read-LabTlsBoundJson $files['commit.json'] @('ContractVersion','TransactionId','SourceSha256','CandidateSha256','Status','QualifiedAt','ExpiresAt')
        Assert-LabTlsRebindStringFields $commit @('ContractVersion','TransactionId','SourceSha256','CandidateSha256','Status','QualifiedAt','ExpiresAt')
        $start=[DateTimeOffset]::MinValue;$end=[DateTimeOffset]::MinValue
        if($commit.ContractVersion -cne 'SqlServerLab.TlsRebindCommit/0.1' -or $commit.TransactionId -cne $intent.TransactionId -or
            $commit.SourceSha256 -cne $intent.SourceSha256 -or $commit.CandidateSha256 -cne $intent.CandidateSha256 -or
            $commit.Status -cne 'QUALIFIED_METADATA_COMMITTED' -or
            -not [DateTimeOffset]::TryParseExact($commit.QualifiedAt,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$start) -or
            -not [DateTimeOffset]::TryParseExact($commit.ExpiresAt,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$end) -or
            $end -le $start -or ($end-$start).TotalMinutes -gt 15){throw 'TLS_REBIND_RECOVERY_REQUIRED'}
        $status='COMMITTED'
    }elseif($hasRollback){
        $rollback=Read-LabTlsBoundJson $files['rollback-intent.json'] @('ContractVersion','TransactionId','SourceSha256','CandidateSha256')
        Assert-LabTlsRebindStringFields $rollback @('ContractVersion','TransactionId','SourceSha256','CandidateSha256')
        if($rollback.ContractVersion -cne 'SqlServerLab.TlsRebindRollbackIntent/0.1' -or $rollback.TransactionId -cne $intent.TransactionId -or
            $rollback.SourceSha256 -cne $intent.SourceSha256 -or $rollback.CandidateSha256 -cne $intent.CandidateSha256){throw 'TLS_REBIND_RECOVERY_REQUIRED'}
        $status='ROLLBACK_PENDING';$head=$intent.SourceSha256
        if($files.ContainsKey('rollback-source.json')){$current=$intent.SourceSha256}
        if($files.ContainsKey('rollback-commit.json')){
            $done=Read-LabTlsBoundJson $files['rollback-commit.json'] @('ContractVersion','TransactionId','SourceSha256','CandidateSha256','Status','RestoredFromCandidate','CompletedAt')
            Assert-LabTlsRebindStringFields $done @('ContractVersion','TransactionId','SourceSha256','CandidateSha256','Status','CompletedAt')
            $at=[DateTimeOffset]::MinValue
            if($done.ContractVersion -cne 'SqlServerLab.TlsRebindRollbackCommit/0.1' -or $done.TransactionId -cne $intent.TransactionId -or
                $done.SourceSha256 -cne $intent.SourceSha256 -or $done.CandidateSha256 -cne $intent.CandidateSha256 -or
                $done.Status -cne 'ROLLED_BACK_UNQUALIFIED' -or $done.RestoredFromCandidate -isnot [bool] -or
                $done.RestoredFromCandidate -ne $hasSource -or $files.ContainsKey('rollback-write.json') -or
                ($hasSource -and -not $files.ContainsKey('rollback-source.json')) -or
                -not [DateTimeOffset]::TryParseExact($done.CompletedAt,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$at)){
                throw 'TLS_REBIND_RECOVERY_REQUIRED'
            }
            $status='ROLLED_BACK';$current=$intent.SourceSha256
        }
    }
    [pscustomobject]@{Id=$intent.TransactionId;Sequence=$intent.Sequence;Status=$status;SourceSha256=$intent.SourceSha256;
        CandidateSha256=$intent.CandidateSha256;HeadSha256=$head;CurrentSha256=$current;Original=$original;Candidate=$candidate;
        OriginalBytes=$files['original.json'];CandidateBytes=$files['candidate.json'];Files=$files;Directory=$Directory.FullName}
}

function Get-LabTlsRebindHistoryState {
    param([object]$Binding,[object]$Record,[byte[]]$CurrentBytes,[switch]$AllowIncomplete)
    $directory=$Binding.Directory;$sid=$Binding.Native.UserSid
    Assert-LabTlsCaPrivateAcl $directory $sid -Directory
    $owner=Read-LabTlsBoundJson (Read-LabTlsCaPrivateFile (Join-Path $directory 'owner.json') $sid 4096) @('ContractVersion','RunId','InstanceId','ScopeId','AuditId','IdentitySha256')
    Assert-LabTlsRebindStringFields $Record @('RunId','InstanceId','ScopeId','AuditId')
    Assert-LabTlsRebindStringFields $owner @('ContractVersion','RunId','InstanceId','ScopeId','AuditId','IdentitySha256')
    if($owner.ContractVersion -cne 'SqlServerLab.TlsRebindStorage/0.1' -or $owner.RunId -cne $Record.RunId -or
        $owner.InstanceId -cne $Record.InstanceId -or $owner.ScopeId -cne $Record.ScopeId -or $owner.AuditId -cne $Record.AuditId -or
        $owner.IdentitySha256 -cne (Get-LabTlsRebindIdentityDigest $Record)){throw 'TLS_REBIND_STORAGE_OWNER_CHANGED'}
    $entries=@(Get-ChildItem -LiteralPath $directory -Force);$directories=@($entries|Where-Object PSIsContainer)
    if($directories.Count -gt 64 -or @($entries|Where-Object {-not $_.PSIsContainer -and $_.Name -cnotin @('owner.json','writer.lock')}).Count){throw 'TLS_REBIND_STORAGE_UNKNOWN'}
    $history=@(foreach($item in $directories){Read-LabTlsRebindTransaction $item $sid $owner.IdentitySha256})|Sort-Object Sequence
    $history=@($history);$head=$null;$sequence=0;$pending=$null
    foreach($transaction in $history){
        if($transaction.Sequence -ne ++$sequence -or ($head -and $transaction.SourceSha256 -cne $head)){throw 'TLS_REBIND_HISTORY_CHAIN_INVALID'}
        if($transaction.Status -cin @('PENDING','ROLLBACK_PENDING')){
            if(-not $AllowIncomplete -or $sequence -ne $history.Count){throw 'TLS_REBIND_RECOVERY_REQUIRED'}
            $pending=$transaction
        }
        $head=$transaction.HeadSha256
    }
    $expected=$(if($pending){$pending.CurrentSha256}else{$head})
    if($expected -and $expected -cne (Get-LabTlsCaByteDigest $CurrentBytes)){throw 'TLS_REBIND_COMMITTED_BINDING_CHANGED'}
    [pscustomobject]@{Sequence=$sequence;Transactions=$history;Pending=$pending}
}

function New-LabTlsRebindRecoveryResult {
    param([object]$Record,[object]$Transaction,[string]$Status,[object]$Qualification)
    [pscustomobject][ordered]@{ContractVersion='SqlServerLab.TlsBindingRecovery/0.1';RunId=$Record.RunId;InstanceId=$Record.InstanceId;
        TransactionId=$(if($Transaction){$Transaction.Id}else{$null});Status=$Status;
        QualificationStatus=$(if($Qualification){'QUALIFIED'}else{'NOT_EXECUTED'});
        QualifiedAt=$(if($Qualification){$Qualification.QualifiedAt}else{$null});ExpiresAt=$(if($Qualification){$Qualification.ExpiresAt}else{$null});
        WireCertificateFingerprint='NOT_OBSERVED'}
}

function Get-LabTlsRebindRecovery {
    param([string]$RunId,[string]$InstanceId,[string]$StateRoot)
    $bound=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
    $binding=[pscustomobject]@{Directory=(Join-Path $bound.StateRoot 'authenticated-tls-rebind');Native=$bound.Authority.Native}
    if(-not(Test-Path -LiteralPath $binding.Directory)){return New-LabTlsRebindRecoveryResult $bound.Record $null 'NO_PENDING_TRANSACTION' $null}
    $lock=$null
    try{
        $lock=Enter-LabTlsRegistryWriterLock $binding
        $fresh=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
        if((Get-LabTlsCaByteDigest $fresh.Bytes) -cne (Get-LabTlsCaByteDigest $bound.Bytes)){throw 'TLS_REBIND_SOURCE_CHANGED'}
        $state=Get-LabTlsRebindHistoryState $binding $fresh.Record $fresh.Bytes -AllowIncomplete
        New-LabTlsRebindRecoveryResult $fresh.Record $state.Pending $(if($state.Pending){$state.Pending.Status}else{'NO_PENDING_TRANSACTION'}) $null
    }finally{Exit-LabTlsRegistryWriterLock $lock}
}

function Resolve-LabTlsRebindRecovery {
    param([string]$RunId,[string]$InstanceId,[string]$StateRoot,[string]$TransactionId,[string]$Action)
    if($TransactionId -cnotmatch '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z' -or $Action -cnotin @('Complete','Rollback')){throw 'TLS_REBIND_RECOVERY_REQUEST_INVALID'}
    $bound=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
    $binding=[pscustomobject]@{Directory=(Join-Path $bound.StateRoot 'authenticated-tls-rebind');Native=$bound.Authority.Native}
    if(-not(Test-Path -LiteralPath $binding.Directory)){throw 'TLS_REBIND_RECOVERY_TRANSACTION_REQUIRED'}
    $lock=$null
    try{
        $lock=Enter-LabTlsRegistryWriterLock $binding
        $fresh=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
        if((Get-LabTlsCaByteDigest $fresh.Bytes) -cne (Get-LabTlsCaByteDigest $bound.Bytes)){throw 'TLS_REBIND_SOURCE_CHANGED'}
        $state=Get-LabTlsRebindHistoryState $binding $fresh.Record $fresh.Bytes -AllowIncomplete
        if(-not $state.Sequence -or $state.Transactions[-1].Id -cne $TransactionId){throw 'TLS_REBIND_RECOVERY_LAST_TRANSACTION_REQUIRED'}
        $transaction=$state.Transactions[-1];$sid=$binding.Native.UserSid
        if($transaction.Status -cin @('COMMITTED','ROLLED_BACK')){
            if(($Action -ceq 'Complete' -and $transaction.Status -cne 'COMMITTED') -or ($Action -ceq 'Rollback' -and $transaction.Status -cne 'ROLLED_BACK')){throw 'TLS_REBIND_RECOVERY_ACTION_CHANGED'}
            return New-LabTlsRebindRecoveryResult $fresh.Record $transaction ('ALREADY_'+$transaction.Status) $null
        }
        if($Action -ceq 'Complete' -and $transaction.Status -ceq 'ROLLBACK_PENDING'){throw 'TLS_REBIND_RECOVERY_ACTION_CHANGED'}
        $provider=Get-LabTlsBindingProvider $fresh.Record
        $budget=New-LabTlsRuntimeBudget -Provider $provider -StateRoot $StateRoot -Record $fresh.Record
        $null=Assert-LabTlsSqlCertificateBinding $transaction.Candidate $StateRoot $budget
        $qualified=$null
        if($Action -ceq 'Complete'){
            $sourceSha=Get-LabTlsCaByteDigest $fresh.Bytes
            $qualified=Test-LabAuthenticatedTlsEnvironment -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot -Budget $budget `
                -RestartCandidate $transaction.Candidate -ExpectedSourceSha256 $sourceSha -RebindLock $lock -RecoveryTransactionId $TransactionId
        }
        # Re-read both local authority and the original native incarnation immediately
        # before applying an exact predecessor/candidate transition. No inferred retry.
        $again=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
        if((Get-LabTlsCaByteDigest $again.Bytes) -cne (Get-LabTlsCaByteDigest $fresh.Bytes)){throw 'TLS_REBIND_SOURCE_CHANGED'}
        $null=Assert-LabTlsSqlCertificateBinding $transaction.Candidate $StateRoot $budget
        $livePath=Join-Path $bound.StateRoot 'authenticated-tls-lab.json'
        if($Action -ceq 'Complete'){
            if([DateTimeOffset]::Parse($qualified.ExpiresAt,[Globalization.CultureInfo]::InvariantCulture) -le [DateTimeOffset]::UtcNow){throw 'TLS_REBIND_QUALIFICATION_EXPIRED'}
            if(-not $transaction.Files.ContainsKey('source.json')){
                $temporary=Join-Path $transaction.Directory 'candidate-write.json'
                if(-not $transaction.Files.ContainsKey('candidate-write.json')){Write-LabTlsCaPrivateFile $temporary $sid $transaction.CandidateBytes}
                [IO.File]::Replace($temporary,$livePath,(Join-Path $transaction.Directory 'source.json'),$false)
            }
            $installed=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
            if((Get-LabTlsCaByteDigest $installed.Bytes) -cne $transaction.CandidateSha256){throw 'TLS_REBIND_RECOVERY_REQUIRED'}
            $null=Assert-LabTlsSqlCertificateBinding $installed.Record $StateRoot $budget
            if([DateTimeOffset]::Parse($qualified.ExpiresAt,[Globalization.CultureInfo]::InvariantCulture) -le [DateTimeOffset]::UtcNow){throw 'TLS_REBIND_QUALIFICATION_EXPIRED'}
            $commit=[ordered]@{ContractVersion='SqlServerLab.TlsRebindCommit/0.1';TransactionId=$TransactionId;SourceSha256=$transaction.SourceSha256;
                CandidateSha256=$transaction.CandidateSha256;Status='QUALIFIED_METADATA_COMMITTED';QualifiedAt=$qualified.QualifiedAt;ExpiresAt=$qualified.ExpiresAt}
            Write-LabTlsCaPrivateFile (Join-Path $transaction.Directory 'commit.json') $sid (ConvertTo-LabTlsRegistryWriterBytes $commit)
        }else{
            if(-not $transaction.Files.ContainsKey('rollback-intent.json')){
                $intent=[ordered]@{ContractVersion='SqlServerLab.TlsRebindRollbackIntent/0.1';TransactionId=$TransactionId;
                    SourceSha256=$transaction.SourceSha256;CandidateSha256=$transaction.CandidateSha256}
                Write-LabTlsCaPrivateFile (Join-Path $transaction.Directory 'rollback-intent.json') $sid (ConvertTo-LabTlsRegistryWriterBytes $intent)
            }
            if($transaction.Files.ContainsKey('source.json') -and -not $transaction.Files.ContainsKey('rollback-source.json')){
                $temporary=Join-Path $transaction.Directory 'rollback-write.json'
                if(-not $transaction.Files.ContainsKey('rollback-write.json')){Write-LabTlsCaPrivateFile $temporary $sid $transaction.OriginalBytes}
                [IO.File]::Replace($temporary,$livePath,(Join-Path $transaction.Directory 'rollback-source.json'),$false)
            }
            $installed=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
            if((Get-LabTlsCaByteDigest $installed.Bytes) -cne $transaction.SourceSha256){throw 'TLS_REBIND_RECOVERY_REQUIRED'}
            $null=Assert-LabTlsSqlCertificateBinding $transaction.Candidate $StateRoot $budget
            $commit=[ordered]@{ContractVersion='SqlServerLab.TlsRebindRollbackCommit/0.1';TransactionId=$TransactionId;
                SourceSha256=$transaction.SourceSha256;CandidateSha256=$transaction.CandidateSha256;Status='ROLLED_BACK_UNQUALIFIED';
                RestoredFromCandidate=$transaction.Files.ContainsKey('source.json');CompletedAt=[DateTimeOffset]::UtcNow.ToString('o')}
            Write-LabTlsCaPrivateFile (Join-Path $transaction.Directory 'rollback-commit.json') $sid (ConvertTo-LabTlsRegistryWriterBytes $commit)
        }
        $installed=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
        $null=Read-LabTlsRebindHistory $binding $installed.Record $installed.Bytes
        New-LabTlsRebindRecoveryResult $installed.Record $transaction $(if($Action -ceq 'Complete'){'QUALIFIED_METADATA_COMMITTED'}else{'ROLLED_BACK_UNQUALIFIED'}) $qualified
    }finally{Exit-LabTlsRegistryWriterLock $lock}
}
