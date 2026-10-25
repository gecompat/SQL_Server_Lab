#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Common/TestTemporaryDirectory.ps1')
. (Join-Path $PSScriptRoot '../Common/WorkflowUiTestTemporaryDirectory.ps1')
$testScope=New-TestTemporaryDirectory -ParentPath ([IO.Path]::GetTempPath())
$parent=$testScope.Path
$allChecksCompleted=$false
$result=$null
$primaryError=$null
$passed=0
try{
    $trailing=New-TestTemporaryDirectory -ParentPath ($parent+[IO.Path]::DirectorySeparatorChar)
    $trailing.Parent += [IO.Path]::DirectorySeparatorChar
    Remove-TestTemporaryDirectory $trailing
    if(Test-Path -LiteralPath $trailing.Path){throw 'Trailing parent separator changed owned scope identity'};$passed++
    $owned=New-TestTemporaryDirectory -ParentPath $parent
    $null=New-Item -ItemType Directory -Path (Join-Path $owned.Path 'nested')
    Set-Content -LiteralPath (Join-Path $owned.Path 'nested/file.txt') -Value 'synthetic'
    Remove-TestTemporaryDirectory $owned
    Remove-TestTemporaryDirectory $owned
    if(Test-Path -LiteralPath $owned.Path){throw 'Ordinary cleanup failed'};$passed++
    $owned=New-TestTemporaryDirectory -ParentPath $parent
    Set-Content -LiteralPath (Join-Path $owned.Path '.test-owner') -Value 'foreign' -NoNewline
    $blocked=$false;try{Remove-TestTemporaryDirectory $owned}catch{$blocked=$true}
    if(-not $blocked -or -not(Test-Path -LiteralPath $owned.Path)){throw 'Owner drift was not preserved'};$passed++
    [IO.File]::WriteAllText((Join-Path $owned.Path '.test-owner'),$owned.Token)
    $foreign=Join-Path $parent 'foreign';$null=New-Item -ItemType Directory -Path $foreign
    Set-Content -LiteralPath (Join-Path $foreign 'sentinel.txt') -Value 'preserve'
    $kind=if($IsWindows){'Junction'}else{'SymbolicLink'}
    $null=New-Item -ItemType $kind -Path (Join-Path $owned.Path 'linked') -Target $foreign
    Remove-TestTemporaryDirectory $owned
    if(Test-Path -LiteralPath $owned.Path){throw 'Linked fixture remains'}
    if((Get-Content -LiteralPath (Join-Path $foreign 'sentinel.txt') -Raw).Trim() -cne 'preserve'){throw 'Foreign link target changed'};$passed++
    $linkedParent=Join-Path $parent 'linked-parent'
    $null=New-Item -ItemType $kind -Path $linkedParent -Target $foreign
    try{
        $blocked=$false;try{$unexpected=New-TestTemporaryDirectory -ParentPath (Join-Path $linkedParent 'new-parent')}catch{$blocked=$true}
        if(-not $blocked -or (Test-Path -LiteralPath (Join-Path $foreign 'new-parent'))){throw 'Allocation followed linked ancestor'};$passed++
    }finally{Remove-Item -LiteralPath $linkedParent -Force}
    $supervisor=New-TestTemporaryDirectory -ParentPath $parent
    $driver=Join-Path $supervisor.Path 'fixture.ps1'
    $environmentBefore=@($env:TEMP,$env:TMP,$env:TMPDIR)
    Set-Content -LiteralPath $driver -Value '[Console]::WriteLine(($env:TEMP,$env:TMP,$env:TMPDIR -join "|")); exit 0'
    $result=Invoke-WorkflowUiTemporaryFixture -FixturePath $driver -TimeoutMilliseconds 5000 -ParentPath $supervisor.Path
    if(-not $result.Completed -or $result.ExitCode -ne 0 -or $result.Cleanup -cne 'CLEAN' -or
        $result.Output.Trim() -cne (@($result.OwnedDirectory.Path)*3 -join '|') -or
        (Test-Path -LiteralPath $result.OwnedDirectory.Path) -or -not $result.Process.Started -or
        $result.Process.Id -eq $PID -or $result.Process.Id -le 0 -or -not $result.Process.StartTimeUtc -or
        -not $result.Process.TerminationConfirmed -or -not $result.Process.OutputClosed -or
        (@($env:TEMP,$env:TMP,$env:TMPDIR) -join '|') -cne ($environmentBefore -join '|')){throw 'Supervisor did not isolate child temporary environment'};$passed++
    Set-Content -LiteralPath $driver -Value 'Set-Content -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) "arranged.txt") -Value synthetic; exit 23'
    $result=Invoke-WorkflowUiTemporaryFixture -FixturePath $driver -TimeoutMilliseconds 5000 -ParentPath $supervisor.Path
    if(-not $result.Completed -or $result.ExitCode -ne 23 -or $result.PrimaryFailure -cne 'NONZERO_EXIT' -or
        $result.Cleanup -cne 'CLEAN' -or (Test-Path -LiteralPath $result.OwnedDirectory.Path)){throw 'Nonzero fixture result or cleanup was lost'};$passed++
    Set-Content -LiteralPath $driver -Value 'throw "SYNTHETIC_FIXTURE_FAILURE"'
    $result=Invoke-WorkflowUiTemporaryFixture -FixturePath $driver -TimeoutMilliseconds 5000 -ParentPath $supervisor.Path
    if(-not $result.Completed -or $result.ExitCode -eq 0 -or $result.Error -notmatch 'SYNTHETIC_FIXTURE_FAILURE' -or
        $result.Cleanup -cne 'CLEAN' -or (Test-Path -LiteralPath $result.OwnedDirectory.Path)){throw 'Throwing fixture did not preserve error and cleanup'};$passed++
    Set-Content -LiteralPath $driver -Value 'Set-Content -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) "arranged.txt") -Value synthetic; Write-Output ARRANGED; Start-Sleep -Seconds 30'
    $result=Invoke-WorkflowUiTemporaryFixture -FixturePath $driver -TimeoutMilliseconds 5000 -ParentPath $supervisor.Path
    if($result.Completed -or $result.PrimaryFailure -cne 'TIMEOUT' -or $result.Output -notmatch 'ARRANGED' -or
        $result.Cleanup -cne 'CLEAN' -or (Test-Path -LiteralPath $result.OwnedDirectory.Path)){throw 'Timed-out fixture did not remain failed with confirmed cleanup'};$passed++
    Set-Content -LiteralPath $driver -Value '[IO.File]::WriteAllText((Join-Path ([IO.Path]::GetTempPath()) ".test-owner"),"foreign"); exit 0'
    $result=Invoke-WorkflowUiTemporaryFixture -FixturePath $driver -TimeoutMilliseconds 5000 -ParentPath $supervisor.Path
    if(-not $result.Completed -or $result.ExitCode -ne 0 -or $result.Cleanup -cne 'RECOVERY_REQUIRED' -or
        -not (Test-Path -LiteralPath $result.OwnedDirectory.Path)){throw 'Owner drift must retain a failed cleanup receipt'};$passed++
    [IO.File]::WriteAllText((Join-Path $result.OwnedDirectory.Path '.test-owner'),$result.OwnedDirectory.Token)
    Remove-TestTemporaryDirectory $result.OwnedDirectory
    Set-Content -LiteralPath $driver -Value '[IO.File]::WriteAllText((Join-Path ([IO.Path]::GetTempPath()) ".test-owner"),"foreign"); Write-Output ARRANGED; Start-Sleep -Seconds 30'
    $result=Invoke-WorkflowUiTemporaryFixture -FixturePath $driver -TimeoutMilliseconds 5000 -ParentPath $supervisor.Path
    if($result.Completed -or $result.PrimaryFailure -cne 'TIMEOUT' -or $result.Output -notmatch 'ARRANGED' -or
        $result.Cleanup -cne 'RECOVERY_REQUIRED' -or -not (Test-Path -LiteralPath $result.OwnedDirectory.Path)){throw 'Primary timeout and cleanup veto must both survive'};$passed++
    [IO.File]::WriteAllText((Join-Path $result.OwnedDirectory.Path '.test-owner'),$result.OwnedDirectory.Token)
    Remove-TestTemporaryDirectory $result.OwnedDirectory
    $target=$foreign.Replace("'","''")
    Set-Content -LiteralPath $driver -Value ("`$null=New-Item -ItemType $kind -Path (Join-Path ([IO.Path]::GetTempPath()) 'foreign-link') -Target '$target'; exit 0")
    $result=Invoke-WorkflowUiTemporaryFixture -FixturePath $driver -TimeoutMilliseconds 5000 -ParentPath $supervisor.Path
    if(-not $result.Completed -or $result.ExitCode -ne 0 -or $result.Cleanup -cne 'CLEAN' -or
        (Test-Path -LiteralPath $result.OwnedDirectory.Path) -or
        (Get-Content -LiteralPath (Join-Path $foreign 'sentinel.txt') -Raw).Trim() -cne 'preserve'){throw 'Supervisor followed foreign link target'};$passed++
    $receipt=Write-WorkflowUiFixtureRecoveryReceipt -Directory (Join-Path $supervisor.Path 'receipts') -Record ([pscustomobject]@{Status='synthetic'})
    if($receipt.Status -cne 'WRITTEN' -or (Get-Content -LiteralPath $receipt.Path -Raw|ConvertFrom-Json).Status -cne 'synthetic'){throw 'Recovery receipt was not written'};$passed++
    $observed=$null;$failedReceipt=$null
    try{try{throw 'SYNTHETIC_PRIMARY_FAILURE'}finally{$failedReceipt=Write-WorkflowUiFixtureRecoveryReceipt -Directory $driver -Record ([pscustomobject]@{Status='synthetic'})}}catch{$observed=$_}
    if(-not $observed -or $observed.Exception.Message -cne 'SYNTHETIC_PRIMARY_FAILURE' -or
        $failedReceipt.Status -cne 'WRITE_FAILED' -or $failedReceipt.Path -or $failedReceipt.FailureType -ceq 'NONE'){throw 'Receipt failure replaced primary error or claimed success'};$passed++
    Remove-TestTemporaryDirectory $supervisor
    $allChecksCompleted=$true
}catch{$primaryError=$_;throw}finally{
    $outerCleanupFailed=$false
    if($allChecksCompleted){try{Remove-TestTemporaryDirectory $testScope}catch{$outerCleanupFailed=$true}}
    if(-not $allChecksCompleted -or $outerCleanupFailed){
        $recoveryRoot=Join-Path $PSScriptRoot '../../.artifacts/test-runs/temporary-directory-recovery'
        $record=[pscustomobject]@{TestScope=$testScope;AllChecksCompleted=$allChecksCompleted;OuterCleanupFailed=$outerCleanupFailed;
            LastFixture=if($result){$result|Select-Object PrimaryFailure,Cleanup,CleanupReason,OwnedDirectory,Process}else{$null}}
        $receipt=Write-WorkflowUiFixtureRecoveryReceipt -Directory $recoveryRoot -Record $record
        if($primaryError){$primaryError.Exception.Data['SqlServerLab.TestRecoveryReceiptStatus']=$receipt.Status;$primaryError.Exception.Data['SqlServerLab.TestRecoveryReceiptFailureType']=$receipt.FailureType}
        Write-Host ('RECOVERY_REQUIRED: eigener Testbereich bleibt erhalten; Belegstatus '+$receipt.Status+'.')
        if($outerCleanupFailed){throw 'TEST_DIRECTORY_CLEANUP_REQUIRED'}
    }
}
Write-Host "TEST TEMPORARY DIRECTORY: PASS ($passed scenarios; foreign link target preserved)"
