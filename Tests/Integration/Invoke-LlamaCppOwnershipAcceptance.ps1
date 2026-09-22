#Requires -Version 7.2
[CmdletBinding()]param([ValidateSet('OwnerClosed','LeaseExpired','WorkerKilled','OutputLimit','CleanupRetry')][string[]]$Case=@('OwnerClosed','LeaseExpired','WorkerKilled','OutputLimit','CleanupRetry'))
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw 'LLAMA_WINDOWS_REQUIRED'}
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-llama-ownership-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$workers=[Collections.Generic.List[Diagnostics.Process]]::new()
try {
    foreach($mode in $Case) {
        $scope=Join-Path $root $mode;$null=New-Item -ItemType Directory -Path $scope
        if($mode -eq 'CleanupRetry') {
            $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
            $psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
            foreach($arg in @('-NoProfile','-NonInteractive','-Command','exit 0')){$psi.ArgumentList.Add($arg)}
            $finished=[Diagnostics.Process]::Start($psi);$null=$finished.WaitForExit(5000)
            $id=[guid]::NewGuid().ToString('D');$keyPath=Join-Path $scope 'api-key.txt';[IO.File]::WriteAllText($keyPath,'synthetic-fixture-only')
            & $module {param($Id,$Process,$Root)$script:LlamaCppOwnedSessions=@{};$script:LlamaCppOwnedSessions[$Id]=@{Worker=$Process;OperationRoot=$Root;ReceiptPath=(Join-Path $Root 'absent.json');Port=19435}} $id $finished $scope
            $lock=[IO.File]::Open($keyPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $failed=$false
            try {try {Stop-SqlServerLabLlamaCppRuntime $id|Out-Null}catch{$failed=$true}}finally{$lock.Dispose()}
            if(-not $failed){throw 'CLEANUP_FAILURE_NOT_OBSERVED'}
            $cleanup=Stop-SqlServerLabLlamaCppRuntime $id
            if($cleanup.Status -ne 'CLEANUP_SUCCEEDED' -or (Test-Path $keyPath)){throw 'CLEANUP_RETRY_FAILED'}
            Remove-Module $module -Force
            Write-Host 'PASS: cleanup can retry after temporary key-file lock'
            continue
        }
        $requestPath=Join-Path $scope 'request.json';$receiptPath=Join-Path $scope 'receipt.json'
        $request=@{OperationId=[guid]::NewGuid().ToString('D');Invocation=(Get-Process -Id $PID).Path;Arguments=@('-NoProfile','-NonInteractive','-Command',$(if($mode -eq 'OutputLimit'){'[Console]::Out.Write([string]::new([char]120,5MB));Start-Sleep -Seconds 60'}else{'Start-Sleep -Seconds 60'}));Environment=@{};LeaseSeconds=if($mode -eq 'LeaseExpired'){2}else{30};StartTimeoutSeconds=0}
        [IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json -Depth 5))
        [IO.File]::WriteAllText((Join-Path $scope 'api-key.txt'),'synthetic-fixture-only')
        $psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardInput=$true
        $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        foreach($arg in @('-NoProfile','-NonInteractive','-File',(Join-Path $repoRoot 'Tools/Invoke-LlamaCppOwnedWorker.ps1'),'-RequestPath',$requestPath)){$psi.ArgumentList.Add($arg)}
        $worker=[Diagnostics.Process]::Start($psi);$workers.Add($worker)
        $out=$worker.StandardOutput.ReadToEndAsync();$err=$worker.StandardError.ReadToEndAsync()
        $watch=[Diagnostics.Stopwatch]::StartNew();$receipt=$null
        do {
            if(Test-Path $receiptPath){$receipt=Get-Content $receiptPath -Raw|ConvertFrom-Json}
            if($receipt.Status -eq 'RUNNING'){break}
            if($worker.HasExited -or $watch.Elapsed.TotalSeconds -gt 15){throw 'WORKER_NOT_RUNNING'}
            Start-Sleep -Milliseconds 50
        }while($true)
        $child=Get-Process -Id $receipt.ProcessId -ErrorAction Stop
        if($mode -eq 'WorkerKilled'){$worker.Kill()}
        elseif($mode -eq 'OwnerClosed'){$worker.StandardInput.Close()}
        if(-not $worker.WaitForExit(15000)){throw 'WORKER_DID_NOT_EXIT'}
        if(-not $child.WaitForExit(5000)){throw 'OWN_CHILD_SURVIVED'}
        $child.Dispose()
        if($mode -ne 'WorkerKilled' -and (Test-Path (Join-Path $scope 'api-key.txt'))){throw 'SECRET_NOT_REMOVED'}
        if($mode -eq 'OutputLimit' -and (Get-Item -LiteralPath (Join-Path $scope 'stdout.log')).Length -ne 4MB){throw 'OUTPUT_CAP_FAILED'}
        Write-Host "PASS: $mode terminates its child; scoped cleanup confirmed"
    }
}
finally {
    foreach($worker in $workers){if(-not $worker.HasExited){$worker.Kill();$null=$worker.WaitForExit(5000)};$worker.Dispose()}
    $resolved=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-llama-ownership-*'){throw 'CLEANUP_SCOPE_INVALID'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'LLAMA OWNERSHIP ACCEPTANCE: PASS; CLEANUP_SUCCEEDED'
