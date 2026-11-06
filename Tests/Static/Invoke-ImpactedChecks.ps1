#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt nur die von geaenderten Pfaden betroffenen statischen Suites aus.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$ChangedPath,
    [switch]$Development,
    [switch]$NoReuse
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$selector = Join-Path $repoRoot 'Tools/Get-CiTestSelection.ps1'
$selection = & $selector -ChangedPath $ChangedPath
$pwsh = Get-Command pwsh -ErrorAction Stop
$failures = [System.Collections.Generic.List[string]]::new()
. (Join-Path $repoRoot 'Tests/Common/LocalStaticEvidence.ps1')
$cacheEnabled = $env:GITHUB_ACTIONS -ne 'true'
$reuse = $cacheEnabled -and $Development -and -not $NoReuse
$evidenceRoot = Join-Path $repoRoot '.artifacts/test-runs/local-static-evidence'
$logRootSafe=$true
foreach ($part in @('.artifacts','.artifacts/test-runs','.artifacts/test-runs/local-static-evidence')) {
    $directory=Join-Path $repoRoot $part
    if ((Test-Path -LiteralPath $directory) -and ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $cacheEnabled=$false; $reuse=$false; $logRootSafe=$false }
}
if (-not $logRootSafe) { throw 'STATIC_CHECK_LOG_ROOT_UNSAFE' }
$null=New-Item -ItemType Directory -Path $evidenceRoot -Force

function Invoke-StaticCheckChild {
    param([string]$Invocation,[string[]]$ArgumentList,[Parameter(Mandatory)][string]$LogPath)
    $info=[Diagnostics.ProcessStartInfo]::new($Invocation)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($argument in $ArgumentList){$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$started=$false;$ended=$false
    $log=$null;$stdout=$null;$stderr=$null;$outTask=$null;$errTask=$null;$primaryFailure=$null
    try{
        # Publish durable sidecar locations before the child can emit any bytes.
        # Unbuffered write-through streams retain partial output if this host ends.
        $log=[IO.FileStream]::new($LogPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read,1,[IO.FileOptions]::WriteThrough)
        $header=[Text.Encoding]::UTF8.GetBytes("PARTIAL_LOGS: "+$LogPath+".stdout | "+$LogPath+".stderr"+[Environment]::NewLine)
        $log.Write($header,0,$header.Length);$log.Flush($true)
        $options=[IO.FileOptions]::Asynchronous -bor [IO.FileOptions]::WriteThrough
        $stdout=[IO.FileStream]::new($LogPath+'.stdout',[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read,1,$options)
        $stderr=[IO.FileStream]::new($LogPath+'.stderr',[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read,1,$options)
        $started=$process.Start()
        if(-not$started){throw 'STATIC_CHECK_CHILD_NOT_STARTED'}
        $outTask=$process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errTask=$process.StandardError.BaseStream.CopyToAsync($stderr)
        while(-not$process.WaitForExit(100)){
            foreach($task in @($outTask,$errTask)){
                if($task.IsFaulted-or$task.IsCanceled){$null=$task.GetAwaiter().GetResult()}
            }
        }
        $ended=$true
        if(-not[Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outTask,$errTask),5000)){throw 'STATIC_CHECK_CHILD_IO_INCOMPLETE'}
        $null=$outTask.GetAwaiter().GetResult();$null=$errTask.GetAwaiter().GetResult()
        $stdout.Flush($true);$stderr.Flush($true)
        $log.Position=0;$log.SetLength(0)
        $stdout.Position=0;$stdout.CopyTo($log)
        $stderr.Position=0;$stderr.CopyTo($log)
        $log.Flush($true)
        return $process.ExitCode
    }catch{$primaryFailure=$_.Exception;throw}finally{
        $cleanupErrors=[Collections.Generic.List[Exception]]::new()
        try{
            if($started-and-not$ended){
                if(-not$process.HasExited){$process.Kill($true)}
                if(-not$process.WaitForExit(5000)){throw 'STATIC_CHECK_CHILD_TERMINATION_UNCONFIRMED'}
                if($outTask-and$errTask){
                    if(-not[Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outTask,$errTask),5000)){throw 'STATIC_CHECK_CHILD_IO_INCOMPLETE'}
                }
            }
        }catch{$cleanupErrors.Add($_.Exception)}
        foreach($stream in @($stdout,$stderr,$log)){
            if($stream){
                try{$stream.Flush($true)}catch{$cleanupErrors.Add($_.Exception)}
                try{$stream.Dispose()}catch{$cleanupErrors.Add($_.Exception)}
            }
        }
        try{$process.Dispose()}catch{$cleanupErrors.Add($_.Exception)}
        if($cleanupErrors.Count){
            if($primaryFailure){$cleanupErrors.Insert(0,$primaryFailure)}
            throw [AggregateException]::new('STATIC_CHECK_CHILD_CLEANUP_FAILED',$cleanupErrors.ToArray())
        }
    }
}

Write-Host "Betroffene statische Suites: $($selection.StaticChecks -join ', ')" -ForegroundColor Cyan
foreach ($check in $selection.StaticChecks) {
    Write-Host "`n=== $check ===" -ForegroundColor Cyan
    $binding=if ($cacheEnabled) { Get-LocalStaticEvidenceBinding -RepoRoot $repoRoot -Check $check -ChangedPath $ChangedPath -RunnerInvocation $pwsh.Source }
    $recordPath=Join-Path $evidenceRoot ($check+'.json')
    $lock=$null
    try {
        if ($binding) {
            # Exclusive local custody; another writer means NOT_EXECUTED.
            if (@($recordPath,$recordPath+'.lock') | Where-Object { (Test-Path -LiteralPath $_) -and ((Get-Item -LiteralPath $_ -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }) { $binding=$null }
            else { try { $lock=[IO.File]::Open($recordPath+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) } catch { $failures.Add("$check (LOCAL_EVIDENCE_BUSY_NOT_EXECUTED)"); continue } }
        }
        if ($reuse -and $binding -and (Test-LocalStaticEvidence -Path $recordPath -Binding $binding)) {
            Write-Host "REUSED: $check (original execution retained; not a fresh PASS)"
            continue
        }
        if ($binding) { @{Schema='LOCAL_STATIC_EVIDENCE/v1';Status='RUNNING';Binding=$binding} | ConvertTo-Json | Set-Content -LiteralPath $recordPath }
        $arguments=@('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot $check))
        if ($Development -and $check -in @('Invoke-PesterChecks.ps1','Invoke-PSScriptAnalyzerChecks.ps1')) {
            # -File does not portably marshal array parameters to a new process.
            $encodedPaths=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($ChangedPath) -Compress)))
            $entry=(Join-Path $PSScriptRoot $check).Replace("'","''")
            $command="& '$entry' -ChangedPath @(([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedPaths')) | ConvertFrom-Json))"
            $arguments=@('-NoLogo','-NoProfile','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
        }
        $log=Join-Path $evidenceRoot ([guid]::NewGuid().ToString('N')+'.private.log')
        $code=Invoke-StaticCheckChild -Invocation $pwsh.Source -ArgumentList $arguments -LogPath $log
        if ($binding) {
            $end=Get-LocalStaticEvidenceBinding -RepoRoot $repoRoot -Check $check -ChangedPath $ChangedPath -RunnerInvocation $pwsh.Source
            $stable=$end -ceq $binding
            $record=@{Schema='LOCAL_STATIC_EVIDENCE/v1';Status=if($code -eq 0 -and $stable){'EXECUTED_PASS'}else{'FAIL_OR_UNKNOWN'};
                Binding=$binding;ExitCode=$code;SourceStable=$stable;CompletedUtc=[datetime]::UtcNow.ToString('o');Log=$log;LogSHA256=(Get-FileHash -LiteralPath $log).Hash}
            $record | ConvertTo-Json | Set-Content -LiteralPath $recordPath
            Write-Host "$($record.Status): $check; private log: $log"
            if ($code -ne 0) { Get-Content -LiteralPath $log -Tail 20 | Out-Host }
            if (-not $stable) { $failures.Add("$check (source binding changed)") }
        } else {
            $status=if($code -eq 0){'EXECUTED_PASS'}else{'FAIL_OR_UNKNOWN'}
            Write-Host "$status`: $check; private log: $log"
            if ($code -ne 0) { Get-Content -LiteralPath $log -Tail 20 | Out-Host }
        }
        if ($code -ne 0) { $failures.Add("$check (Exitcode $code)") }
    } finally { if ($lock) { $lock.Dispose() } }
}

if ($failures.Count -gt 0) {
    throw "Betroffene statische Vertragspruefungen fehlgeschlagen: $($failures -join '; ')"
}

Write-Host "`nBETROFFENE STATISCHE VERTRAGSPRUEFUNGEN: PASS" -ForegroundColor Green
