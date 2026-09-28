#Requires -Version 7.2
<#
.SYNOPSIS
    Führt einen begrenzten, ausschließlich manuell von Main gestarteten CSharp-Nativtest aus.
.DESCRIPTION
    Erzeugt genau einen eigenen Windows-/SQL-2025-Gast. Bestehende Runs und
    Clone-Quellen werden nicht akzeptiert. Alle Rohlogs bleiben lokal.
    Timeout und Fehler führen zu operationseigenem Cleanup; unbestätigte
    Kindprozessbeendigung erfordert Recovery und sperrt paralleles Cleanup.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Profile)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Tests/Common/CSharpNativeAcceptance.ps1')
$event=Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw|ConvertFrom-Json
$dispatch=[pscustomobject]@{EventName=$env:GITHUB_EVENT_NAME;Ref=$env:GITHUB_REF;Repository=$env:GITHUB_REPOSITORY;EventRepository=$event.repository.full_name;ExpectedCommit=$env:GITHUB_SHA;CheckoutCommit=(git -C $repoRoot rev-parse HEAD);Dirty=[bool](git -C $repoRoot status --porcelain --untracked-files=no);ArtifactId=$null}
Assert-CSharpNativeCheckout $dispatch
if(-not $IsWindows){throw 'CSHARP_NATIVE_WINDOWS_REQUIRED'}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'CSHARP_NATIVE_ELEVATED_RUNNER_REQUIRED'}
$configuration=Get-CSharpNativeProfile -Name $Profile
$ArtifactId=$configuration.ArtifactId
$dispatch.ArtifactId=$ArtifactId
Assert-CSharpNativeDispatch $dispatch
$Package=Join-Path $configuration.PayloadRoot 'extension.zip'
$Probe=Join-Path $configuration.PayloadRoot 'SqlServerLab.CSharpProbe.dll'
$RuntimeArchive=Join-Path $configuration.PayloadRoot 'runtime.zip'
$PackageSha256=$configuration.PackageSha256;$ProbeSha256=$configuration.ProbeSha256
$SqlMediaPath=$configuration.SqlMediaPath;$MediaEdition=$configuration.MediaEdition
$StateRoot=$configuration.StateRoot;$MediaRoot=$configuration.MediaRoot
$runtimeHash='9c55c58694676ee64b0eed2cd6d8cbf58b9aa8288420acc66841e15ca0099c75d4af0182d23a641c2342e5a151a325df4a12fa0bde2e47c0fb7e9a33e7b09896'
Assert-CSharpNativeFile -Path $Package -ExpectedHash $PackageSha256
Assert-CSharpNativeFile -Path $Probe -ExpectedHash $ProbeSha256 -MaximumBytes 1048576
Assert-CSharpNativeFile -Path $RuntimeArchive -ExpectedHash $runtimeHash -Algorithm SHA512
$null=& (Join-Path $repoRoot 'Tools/CSharpBuild/Test-ExternalRuntimeWindowsCSharpPackage.ps1') -Package $Package -ExpectedSha256 $PackageSha256
$operation='csharp-native-'+[guid]::NewGuid().ToString('N')
$root=Join-Path $repoRoot ('.artifacts/test-runs/'+$operation)
Assert-CSharpNativeLocalPath $root
$null=New-Item -ItemType Directory -Path $root
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
if(-not $StateRoot){$StateRoot=& $module {Get-LabStateRoot}}
if(-not $MediaRoot){$MediaRoot=& $module {Get-LabMediaRootDefault}}
Assert-CSharpNativeLocalPath $StateRoot
Assert-CSharpNativeLocalPath $MediaRoot
$readiness=& (Join-Path $repoRoot 'Tools/Test-SqlServerLabClientReadiness.ps1') -Provider hyperv -Operation Create
try{Assert-CSharpNativeClientReadiness $readiness}catch{
    # Bounded failure detail stays local; the workflow still exports only fixed codes.
    try{
        $detail=$readiness|ConvertTo-Json -Depth 5 -Compress -WarningAction SilentlyContinue
        if([Text.Encoding]::UTF8.GetByteCount($detail) -gt 32768){$detail='{"Status":"READINESS_DETAIL_TOO_LARGE"}'}
        $detail|Set-Content -LiteralPath (Join-Path $root 'client-readiness.json') -ErrorAction Stop
    }catch{Write-Verbose 'CSHARP_NATIVE_READINESS_DETAIL_UNAVAILABLE'}
    throw 'CSHARP_NATIVE_CLIENT_NOT_READY'
}
$payload=Join-Path $root 'payload';$null=New-Item -ItemType Directory -Path $payload
Copy-Item -LiteralPath $Package -Destination (Join-Path $payload 'extension.zip')
Copy-Item -LiteralPath $Probe -Destination (Join-Path $payload 'SqlServerLab.CSharpProbe.dll')
Copy-Item -LiteralPath $RuntimeArchive -Destination (Join-Path $payload 'runtime.zip')
Copy-Item -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Fixtures/CSharp/probe.sql') -Destination (Join-Path $payload 'probe.sql')
Assert-CSharpNativeFile -Path (Join-Path $payload 'extension.zip') -ExpectedHash $PackageSha256
Assert-CSharpNativeFile -Path (Join-Path $payload 'SqlServerLab.CSharpProbe.dll') -ExpectedHash $ProbeSha256 -MaximumBytes 1048576
Assert-CSharpNativeFile -Path (Join-Path $payload 'runtime.zip') -ExpectedHash $runtimeHash -Algorithm SHA512
$sqlHash=(Get-FileHash -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Fixtures/CSharp/probe.sql')).Hash.ToLowerInvariant()
Assert-CSharpNativeFile -Path (Join-Path $payload 'probe.sql') -ExpectedHash $sqlHash
$planPath=Join-Path $root 'plan.json'
@{OperationId=$operation;ArtifactId=$ArtifactId;StateRoot=$StateRoot;MediaRoot=$MediaRoot;MediaEdition=$MediaEdition;SqlMediaPath=$SqlMediaPath;
    PayloadRoot=$payload;PackageSha256=$PackageSha256;ProbeSha256=$ProbeSha256;SqlSha256=$sqlHash}|ConvertTo-Json|Set-Content -LiteralPath $planPath
$terminated=$true;$failure=$null;$cleanupFailure=$null;$mutex=$null;$acquired=$false
try{
    $env:SQL_SERVER_LAB_RESOURCE_LIFECYCLE='test'
    $env:SQL_SERVER_LAB_TEST_OPERATION_ID=$operation
    $child=Invoke-CSharpNativeChild -Worker (Join-Path $PSScriptRoot 'Invoke-CSharpHyperVAcceptanceWorker.ps1') -PlanPath $planPath -OutputRoot $root
    if($child.ExitCode -ne 0){throw 'CSHARP_NATIVE_CHILD_FAILED'}
    $result=Get-Content -LiteralPath (Join-Path $root 'worker-result.json') -Raw|ConvertFrom-Json
    if($result.Status -cne 'SQL_PROBE_AND_RESTART_PASSED' -or $result.OperationId -cne $operation -or $result.Commit -cne $env:GITHUB_SHA){throw 'CSHARP_NATIVE_CHILD_RESULT_INVALID'}
}catch{
    $failure=Get-CSharpNativeFailureCode $_
    if($_.Exception.Data.Contains('CSharpChildTerminated')){$terminated=[bool]$_.Exception.Data['CSharpChildTerminated']}
}
finally{
    if($terminated){
        try{
            $mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke')
            try{$acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10))}catch [Threading.AbandonedMutexException]{$acquired=$true}
            if(-not $acquired){throw 'CSHARP_NATIVE_CLEANUP_LOCK_TIMEOUT'}
            $cleanup=Invoke-CSharpNativeCleanup -Module $module -OperationId $operation -StateRoot $StateRoot
            if(-not $failure -and -not $cleanup){throw 'CSHARP_NATIVE_SUCCESS_OWNED_RUN_MISSING'}
        }catch{$cleanupFailure=Get-CSharpNativeFailureCode $_}
    }else{$cleanupFailure='CSHARP_NATIVE_CHILD_TERMINATION_UNCONFIRMED'}
    if($acquired){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
}
$nativeStatus='NOT_EXECUTED'
try{$nativeStatus=Get-CSharpNativeSqlStatus -AttemptPath (Join-Path $root 'native-attempt.json') -OperationId $operation -Commit $env:GITHUB_SHA -Passed (-not $failure -and -not $cleanupFailure)}catch{$failure=Get-CSharpNativeFailureCode $_}
if(-not $failure -and -not $cleanupFailure -and $nativeStatus -ne 'PASSED'){$failure='CSHARP_NATIVE_ATTEMPT_MISSING'}
$receipt=[pscustomobject]@{Contract='SqlServerLab.CSharpNativeAcceptance/1.0';Status=$(if($failure -or $cleanupFailure){'FAILED'}else{'PASSED'});
    Commit=$env:GITHUB_SHA;PrimaryFailure=$failure;CleanupFailure=$cleanupFailure;NativeAcceptanceStatus=$nativeStatus}
$receipt|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root 'receipt.json')
if($cleanupFailure){Write-Host "RECOVERY_REQUIRED: $cleanupFailure"}
if($failure -or $cleanupFailure){throw (New-CSharpNativeFailureException -PrimaryFailure $failure -CleanupFailure $cleanupFailure)}
$receipt
