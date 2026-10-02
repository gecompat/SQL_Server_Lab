#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Fixtures/LlamaCppStartPlanHttpChecks.ps1')
$node=Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if(-not$node){throw 'JAVASCRIPT_CHECK_NOT_EXECUTED'}
$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$node.Source;$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$start.ArgumentList.Add((Join-Path $PSScriptRoot 'Fixtures/LlamaCppStartPlanUiChecks.cjs'))
$child=[Diagnostics.Process]::new();$child.StartInfo=$start
try{
    if(-not$child.Start()){throw 'JAVASCRIPT_CHECK_START_FAILED'}
    $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
    if(-not$child.WaitForExit(30000)){ $child.Kill($true);$child.WaitForExit(5000)|Out-Null;throw 'JAVASCRIPT_CHECK_TIMEOUT' }
    Write-Host $stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult();if($child.ExitCode-ne0){throw ('JAVASCRIPT_CHECK_FAILED: '+$errorText)}
}finally{$child.Dispose()}
