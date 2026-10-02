#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Fixtures/EvaluationRefreshPlanHttpChecks.ps1')
$node=Get-Command node -CommandType Application -ErrorAction Stop|Select-Object -First 1
$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$node.Source;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$start.ArgumentList.Add((Join-Path $PSScriptRoot 'Fixtures/EvaluationRefreshPlanUiChecks.cjs'))
$process=[Diagnostics.Process]::new();$process.StartInfo=$start
try{
    $null=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    if(-not$process.WaitForExit(30000)){$process.Kill($true);$process.WaitForExit();throw 'EVALUATION_REFRESH_BROWSER_JS_TIMEOUT'}
    Write-Host $stdout.GetAwaiter().GetResult()
    if($process.ExitCode-ne0){Write-Host $stderr.GetAwaiter().GetResult();throw 'EVALUATION_REFRESH_BROWSER_JS_FAILED'}
}finally{$process.Dispose()}
