# Own real ACL/file/replace fixtures; authority, runtime and SQL observations
# remain injected by the enclosing restart suite. No provider or native claim.
function New-RebindRecoveryFixture {
    param([switch]$BeforeReplace)
    Reset-RebindFixture
    $script:observedEpoch=$script:nextEpoch
    if($BeforeReplace){
        $script:probeFails=$true
        if(-not(Test-RebindReject {Update-SqlServerLabTlsBinding -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot -Confirm:$false})){throw 'TLS_FIXTURE_EXPECTED_CLIENT_FAILURE'}
        $script:probeFails=$false
        $directory=Join-Path (Join-Path $script:rebindRoot 'authenticated-tls-rebind') ([guid]::NewGuid().ToString('D'))
        Initialize-LabTlsCaPrivateDirectory $directory $script:rebindNative.UserSid -NewOnly
        $bytes=Read-LabTlsCaPrivateFile (Join-Path $script:rebindRoot 'authenticated-tls-lab.json') $script:rebindNative.UserSid 32768
        $candidate=Read-LabTlsLabRecord $bytes;$candidate.StartedAt=$script:nextEpoch
        $candidateBytes=ConvertTo-LabTlsRegistryWriterBytes $candidate
        Write-LabTlsCaPrivateFile (Join-Path $directory 'original.json') $script:rebindNative.UserSid $bytes
        Write-LabTlsCaPrivateFile (Join-Path $directory 'candidate.json') $script:rebindNative.UserSid $candidateBytes
        $intent=[ordered]@{ContractVersion='SqlServerLab.TlsRebindIntent/0.1';TransactionId=[IO.Path]::GetFileName($directory);Sequence=1;
            SourceSha256=(Get-LabTlsCaByteDigest $bytes);CandidateSha256=(Get-LabTlsCaByteDigest $candidateBytes)}
        Write-LabTlsCaPrivateFile (Join-Path $directory 'intent.json') $script:rebindNative.UserSid (ConvertTo-LabTlsRegistryWriterBytes $intent)
    }else{
        $script:postCommitFails=$true
        if(-not(Test-RebindReject {Update-SqlServerLabTlsBinding -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot -Confirm:$false})){throw 'TLS_FIXTURE_EXPECTED_POSTREPLACE_FAILURE'}
        $script:postCommitFails=$false
    }
    $result=Get-SqlServerLabTlsBindingRecovery -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot
    if($result.Status -cne 'PENDING'){throw 'TLS_FIXTURE_PENDING_REQUIRED'}
    return $result.TransactionId
}
function Invoke-RebindRecoveryFixture {
    param([string]$TransactionId,[string]$Action)
    Resolve-SqlServerLabTlsBindingRecovery -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot -TransactionId $TransactionId -Action $Action -Confirm:$false
}

Reset-RebindFixture
$reads=$script:boundReads;$clients=$script:sqlChecks
Resolve-SqlServerLabTlsBindingRecovery -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot -TransactionId '12345678-1234-4234-8234-123456789012' -Action Complete -WhatIf
Add-CheckResult 'Recovery WhatIf does no authority, file, runtime or client work' ($script:boundReads -eq $reads -and $script:sqlChecks -eq $clients)
$status=Get-SqlServerLabTlsBindingRecovery -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot
Add-CheckResult 'Read-only recovery lookup creates no history and claims no qualification' ($status.Status -ceq 'NO_PENDING_TRANSACTION' -and $status.QualificationStatus -ceq 'NOT_EXECUTED' -and
    -not(Test-Path -LiteralPath (Join-Path $script:rebindRoot 'authenticated-tls-rebind')))

foreach($beforeReplace in @($false,$true)){
    $id=New-RebindRecoveryFixture -BeforeReplace:$beforeReplace
    $root=$script:rebindRoot;$path=Join-Path $root 'authenticated-tls-lab.json';$sha=(Get-FileHash -LiteralPath $path).Hash
    $clients=$script:sqlChecks;$odbc=$script:odbcChecks
    $status=Get-SqlServerLabTlsBindingRecovery -RunId synthetic-rebind -InstanceId primary -StateRoot $root
    Add-CheckResult "Pending recovery is observed without a client or record mutation (before replace=$beforeReplace)" ($status.TransactionId -ceq $id -and $status.QualificationStatus -ceq 'NOT_EXECUTED' -and
        $script:sqlChecks -eq $clients -and $script:odbcChecks -eq $odbc -and (Get-FileHash -LiteralPath $path).Hash -ceq $sha)
    Add-CheckResult 'Recovery rejects another transaction before clients' ((Test-RebindReject {Invoke-RebindRecoveryFixture '12345678-1234-4234-8234-123456789012' Complete}) -and $script:sqlChecks -eq $clients)
    $script:probeFails=$true
    Add-CheckResult 'Failed fresh ODBC qualification leaves the original pending state and bytes intact' ((Test-RebindReject {Invoke-RebindRecoveryFixture $id Complete}) -and
        (Get-FileHash -LiteralPath $path).Hash -ceq $sha -and (Get-SqlServerLabTlsBindingRecovery -RunId synthetic-rebind -InstanceId primary -StateRoot $root).Status -ceq 'PENDING')
    $script:probeFails=$false;$clients=$script:sqlChecks;$odbc=$script:odbcChecks
    $result=Invoke-RebindRecoveryFixture $id Complete
    $bound=Get-LabTlsOwnBinding $root synthetic-rebind primary
    $binding=[pscustomobject]@{Directory=(Join-Path $root 'authenticated-tls-rebind');Native=$script:rebindNative}
    Add-CheckResult 'Explicit recovery commits only after both new clients and exact history readback' ($result.Status -ceq 'QUALIFIED_METADATA_COMMITTED' -and $result.QualificationStatus -ceq 'QUALIFIED' -and
        $script:sqlChecks -eq $clients+1 -and $script:odbcChecks -eq $odbc+1 -and $bound.Record.StartedAt -ceq $script:nextEpoch -and (Read-LabTlsRebindHistory $binding $bound.Record $bound.Bytes) -eq 1)
    $clients=$script:sqlChecks;$odbc=$script:odbcChecks
    $repeat=Invoke-RebindRecoveryFixture $id Complete
    Add-CheckResult 'A repeated explicit request observes the terminal commit without replay or a new client claim' ($repeat.Status -ceq 'ALREADY_COMMITTED' -and $repeat.QualificationStatus -ceq 'NOT_EXECUTED' -and $script:sqlChecks -eq $clients -and $script:odbcChecks -eq $odbc)
    Add-CheckResult 'A committed transaction cannot be turned into a rollback' (Test-RebindReject {Invoke-RebindRecoveryFixture $id Rollback})
    $normal=Test-LabAuthenticatedTlsEnvironment -RunId synthetic-rebind -InstanceId primary -StateRoot $root
    Add-CheckResult 'A recovered commit permits ordinary fresh qualification' ($normal.Status -ceq 'QUALIFIED')

    $id=New-RebindRecoveryFixture -BeforeReplace:$beforeReplace
    $root=$script:rebindRoot;$transaction=Join-Path (Join-Path $root 'authenticated-tls-rebind') $id
    $source=(Get-FileHash -LiteralPath (Join-Path $transaction 'original.json')).Hash
    $clients=$script:sqlChecks;$odbc=$script:odbcChecks
    $result=Invoke-RebindRecoveryFixture $id Rollback
    $bound=Get-LabTlsOwnBinding $root synthetic-rebind primary
    $binding=[pscustomobject]@{Directory=(Join-Path $root 'authenticated-tls-rebind');Native=$script:rebindNative}
    Add-CheckResult 'Rollback restores only exact predecessor bytes and never reports a TLS qualification' ($result.Status -ceq 'ROLLED_BACK_UNQUALIFIED' -and $result.QualificationStatus -ceq 'NOT_EXECUTED' -and
        (Get-FileHash -LiteralPath (Join-Path $root 'authenticated-tls-lab.json')).Hash -ceq $source -and $script:sqlChecks -eq $clients -and $script:odbcChecks -eq $odbc -and
        (Read-LabTlsRebindHistory $binding $bound.Record $bound.Bytes) -eq 1)
    Add-CheckResult 'Restored old epoch remains unqualified at the current runtime epoch' (Test-RebindReject {Test-LabAuthenticatedTlsEnvironment -RunId synthetic-rebind -InstanceId primary -StateRoot $root})
    $repeat=Invoke-RebindRecoveryFixture $id Rollback
    Add-CheckResult 'Terminal rollback is observed without replay or qualification' ($repeat.Status -ceq 'ALREADY_ROLLED_BACK' -and $repeat.QualificationStatus -ceq 'NOT_EXECUTED')
    Add-CheckResult 'A rolled-back transaction cannot switch to Complete' (Test-RebindReject {Invoke-RebindRecoveryFixture $id Complete})
    $result=Update-SqlServerLabTlsBinding -RunId synthetic-rebind -InstanceId primary -StateRoot $root -Confirm:$false
    $bound=Get-LabTlsOwnBinding $root synthetic-rebind primary
    Add-CheckResult 'A later explicit rebind extends the aborted predecessor chain and requalifies freshly' ($result.Status -ceq 'QUALIFIED_METADATA_COMMITTED' -and (Read-LabTlsRebindHistory $binding $bound.Record $bound.Bytes) -eq 2)
}

foreach($fault in @('rollback-intent.json','rollback-write.json','rollback-commit.json','commit.json')){
    $id=New-RebindRecoveryFixture
    $root=$script:rebindRoot;$directory=Join-Path (Join-Path $root 'authenticated-tls-rebind') $id
    $action=$(if($fault -ceq 'commit.json'){'Complete'}else{'Rollback'})
    $script:recoveryBaseWriter=${function:Write-LabTlsCaPrivateFile}
    $script:recoveryFailureFile=$fault
    function Write-LabTlsCaPrivateFile {
        param([string]$Path,[string]$UserSid,[byte[]]$Bytes)
        if([IO.Path]::GetFileName($Path) -ceq $script:recoveryFailureFile){throw 'TLS_FIXTURE_RECOVERY_WRITE_INTERRUPTED'}
        & $script:recoveryBaseWriter -Path $Path -UserSid $UserSid -Bytes $Bytes
    }
    try{
        Add-CheckResult "Injected $fault interruption remains a failure" (Test-RebindReject {Invoke-RebindRecoveryFixture $id $action})
    }finally{Set-Item -LiteralPath function:Write-LabTlsCaPrivateFile -Value $script:recoveryBaseWriter}
    $status=Get-SqlServerLabTlsBindingRecovery -RunId synthetic-rebind -InstanceId primary -StateRoot $root
    Add-CheckResult 'An interrupted recovery remains pending and never claims a fresh qualification' ($status.Status -cin @('PENDING','ROLLBACK_PENDING') -and $status.QualificationStatus -ceq 'NOT_EXECUTED')
    if($status.Status -ceq 'ROLLBACK_PENDING'){
        Add-CheckResult 'A durable rollback intent prevents switching to Complete' (Test-RebindReject {Invoke-RebindRecoveryFixture $id Complete})
    }
    $backup=Join-Path $directory 'rollback-source.json'
    $backupSha=$(if(Test-Path -LiteralPath $backup){(Get-FileHash -LiteralPath $backup).Hash}else{$null})
    $result=Invoke-RebindRecoveryFixture $id $action
    Add-CheckResult 'Explicit same-action reconciliation completes the interrupted transaction' ($result.Status -ceq $(if($action -ceq 'Complete'){'QUALIFIED_METADATA_COMMITTED'}else{'ROLLED_BACK_UNQUALIFIED'}))
    if($backupSha){Add-CheckResult 'Reconciliation preserves the actual replacement backup without a second replacement' ((Get-FileHash -LiteralPath $backup).Hash -ceq $backupSha)}
}

foreach($sample in @(
    @{File='intent.json';State='PENDING';Action='Complete'},
    @{File='commit.json';State='COMMITTED';Action='Complete'},
    @{File='rollback-intent.json';State='ROLLED_BACK';Action='Rollback'},
    @{File='rollback-commit.json';State='ROLLED_BACK';Action='Rollback'},
    @{File='owner.json';State='PENDING';Action='Complete'}
)){
    $id=New-RebindRecoveryFixture
    if($sample.State -ceq 'COMMITTED'){$null=Invoke-RebindRecoveryFixture $id Complete}
    if($sample.State -ceq 'ROLLED_BACK'){$null=Invoke-RebindRecoveryFixture $id Rollback}
    $root=$script:rebindRoot;$historyRoot=Join-Path $root 'authenticated-tls-rebind'
    $directory=Join-Path $historyRoot $id
    $file=Join-Path $(if($sample.File -ceq 'owner.json'){$historyRoot}else{$directory}) $sample.File
    $bytes=[IO.File]::ReadAllBytes($file)
    $document=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -Depth 12 -DateKind String
    $fields=@($document.PSObject.Properties|Where-Object {$_.Value -is [string]}|ForEach-Object Name)
    foreach($field in $fields){
        foreach($single in @($false,$true)){
            $mutated=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -Depth 12 -DateKind String
            $value=$mutated.$field
            $mutated.$field=$(if($single){,@($value)}else{,@()})
            if($mutated.$field -isnot [array] -or $mutated.$field.Count -ne $(if($single){1}else{0})){throw 'TLS_FIXTURE_ARRAY_SHAPE_REQUIRED'}
            [IO.File]::WriteAllBytes($file,(ConvertTo-LabTlsRegistryWriterBytes $mutated))
            $clients=$script:sqlChecks;$odbc=$script:odbcChecks
            $recordSha=(Get-FileHash -LiteralPath (Join-Path $root 'authenticated-tls-lab.json')).Hash
            $names=@(Get-ChildItem -LiteralPath $directory -File|ForEach-Object Name|Sort-Object)
            $rejected=(Test-RebindReject {Get-SqlServerLabTlsBindingRecovery -RunId synthetic-rebind -InstanceId primary -StateRoot $root}) -and
                (Test-RebindReject {Invoke-RebindRecoveryFixture $id $sample.Action})
            $afterNames=@(Get-ChildItem -LiteralPath $directory -File|ForEach-Object Name|Sort-Object)
            Add-CheckResult "Journal rejects array instead of scalar $($sample.File)/$field (single=$single) before clients or writes" ($rejected -and
                $script:sqlChecks -eq $clients -and $script:odbcChecks -eq $odbc -and (Get-FileHash -LiteralPath (Join-Path $root 'authenticated-tls-lab.json')).Hash -ceq $recordSha -and
                ($names-join'|') -ceq ($afterNames-join'|'))
            [IO.File]::WriteAllBytes($file,$bytes)
        }
    }
}

$id=New-RebindRecoveryFixture -BeforeReplace
$directory=Join-Path (Join-Path $script:rebindRoot 'authenticated-tls-rebind') $id
$intent=Read-LabTlsBoundJson ([IO.File]::ReadAllBytes((Join-Path $directory 'intent.json'))) @('ContractVersion','TransactionId','Sequence','SourceSha256','CandidateSha256')
$rollback=[ordered]@{ContractVersion='SqlServerLab.TlsRebindRollbackIntent/0.1';TransactionId=$id;SourceSha256=$intent.SourceSha256;CandidateSha256=$intent.CandidateSha256}
Write-LabTlsCaPrivateFile (Join-Path $directory 'rollback-intent.json') $script:rebindNative.UserSid (ConvertTo-LabTlsRegistryWriterBytes $rollback)
Write-LabTlsCaPrivateFile (Join-Path $directory 'rollback-write.json') $script:rebindNative.UserSid ([IO.File]::ReadAllBytes((Join-Path $directory 'original.json')))
Add-CheckResult 'A rollback write without the actual predecessor backup is rejected as contradictory' (Test-RebindReject {Invoke-RebindRecoveryFixture $id Rollback})

$id=New-RebindRecoveryFixture
$root=$script:rebindRoot;$path=Join-Path $root 'authenticated-tls-lab.json';$sha=(Get-FileHash -LiteralPath $path).Hash
$script:observedEpoch=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
foreach($action in @('Complete','Rollback')){
    $clients=$script:sqlChecks
    Add-CheckResult 'Changed native epoch blocks recovery without a write or client login' ((Test-RebindReject {Invoke-RebindRecoveryFixture $id $action}) -and
        (Get-FileHash -LiteralPath $path).Hash -ceq $sha -and $script:sqlChecks -eq $clients)
}
$script:observedEpoch=$script:nextEpoch
$binding=[pscustomobject]@{Directory=(Join-Path $root 'authenticated-tls-rebind');Native=$script:rebindNative}
$lock=Enter-LabTlsRegistryWriterLock $binding
try {
    Add-CheckResult 'A held actual writer lock blocks both lookup and Apply' ((Test-RebindReject {Get-SqlServerLabTlsBindingRecovery -RunId synthetic-rebind -InstanceId primary -StateRoot $root}) -and
        (Test-RebindReject {Invoke-RebindRecoveryFixture $id Complete}))
}finally{Exit-LabTlsRegistryWriterLock $lock}
$unknown=Join-Path (Join-Path $binding.Directory $id) 'unknown.json'
Write-LabTlsCaPrivateFile $unknown $script:rebindNative.UserSid ([Text.Encoding]::UTF8.GetBytes('{}'))
Add-CheckResult 'Unknown transaction files block lookup and Apply instead of being ignored' ((Test-RebindReject {Get-SqlServerLabTlsBindingRecovery -RunId synthetic-rebind -InstanceId primary -StateRoot $root}) -and
    (Test-RebindReject {Invoke-RebindRecoveryFixture $id Rollback}))
