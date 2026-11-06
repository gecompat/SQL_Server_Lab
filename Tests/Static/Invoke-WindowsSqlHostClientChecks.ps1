#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Tests/Integration/Start-WindowsSqlHostClient.ps1') -DefinitionsOnly
$passed=0
function Check([string]$Name,[bool]$Value){if(-not $Value){throw ('FAIL '+$Name)};$script:passed++}
$command=Get-Command Invoke-BoundWindowsSqlHostClient
Check 'No credential or password arguments' (@($command.Parameters.Keys|Where-Object {$_-match 'Password|Credential'}).Count-eq 0)
Check 'ShouldProcess is an actual native control' ($command.Parameters.ContainsKey('WhatIf'))
Check 'Run, source and output are explicit' (@($command.Parameters.Keys|Where-Object {$_-in @('RunId','ScriptPath','ExpectedScriptSha256','OutputDirectory')}).Count-eq 4)
$source=[IO.File]::ReadAllText((Join-Path $repoRoot 'Tests/Integration/Start-WindowsSqlHostClient.ps1'))
foreach($floor in @('Get-LabSsisPrerequisiteContext','guest-administrator-password','ZeroFreeGlobalAllocUnicode','NoRetry','ExpectedVmId','BINDING_CHANGED','NO_REPLAY_OUTPUT_EXISTS','STARTED_AUTHENTICATION_UNCONFIRMED')){
 Check ('Protected floor '+$floor) $source.Contains($floor)
}
Check 'No generated-only password export or interactive prompt' (-not $source.Contains('Get-SqlServerLabGeneratedWindowsAccess') -and -not $source.Contains('Get-Credential') -and -not $source.Contains('/savecred'))
Check 'Buffer is freed in finally' ($source-match '(?s)finally\{.*ZeroFreeGlobalAllocUnicode\(\$pointer\)')
Check 'Exactly network-only logon, no privilege elevation' ($source.Contains('domain,password,2,executable,command') -and -not $source.Contains('runas.exe'))
Check 'Credential stays inside module scope' ($source.IndexOf('$result=& $module {')-lt $source.IndexOf('$credential=Get-LabSecret'))
Check 'Dispatch follows fresh binding' ($source.IndexOf("if(`$fresh.Fingerprint-cne `$context.Fingerprint)")-lt $source.IndexOf('::Start($response[0]'))
Check 'Native input is bounded' ($source.Contains('command.Length>=1024') -and $source.Contains('$ScriptArguments.Count-gt 32'))
Check 'No new Windows/SQL/VM configuration' (-not ($source-match 'New-VM|Set-VM|Set-ItemProperty|Set-ExecutionPolicy|sp_configure|ALTER SERVER|New-LocalUser'))
$stage=Join-Path $repoRoot ('.artifacts/test-runs/windows-host-client-checks-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($stage)
try{
 Assert-BoundClientWorker (Join-Path $repoRoot 'Tests/Integration/WindowsSqlHostClient.Worker.ps1')
 Check 'Exact worker source is bound before credentials' $true
 $crlf=Join-Path $stage 'crlf-worker.ps1'
 [IO.File]::WriteAllText($crlf,[IO.File]::ReadAllText((Join-Path $repoRoot 'Tests/Integration/WindowsSqlHostClient.Worker.ps1')).Replace("`r`n","`n").Replace("`n","`r`n"),[Text.UTF8Encoding]::new($false))
 Assert-BoundClientWorker $crlf
 Check 'CRLF checkout preserves exact canonical worker source binding' $true
 $modified=Join-Path $stage 'modified-worker.ps1';[IO.File]::WriteAllText($modified,'throw "MUST_NOT_START"')
 $denied=$false;try{Assert-BoundClientWorker $modified}catch{$denied=$true}
 Check 'Changed worker source is rejected before credentials' $denied
 $script=Join-Path $stage 'synthetic.ps1'
 [IO.File]::WriteAllText($script,'param([string]$Value,[string]$Destination);[IO.File]::WriteAllText($Destination,$Value)')
 if([Environment]::OSVersion.Platform-eq [PlatformID]::Win32NT){
  # Fehlerhafte Eingabe wird vor Signatur-, Modul- und Credentialzugriff gesperrt.
  foreach($test in @(@{hash=('0'*64);output=(Join-Path $stage 'absent')},@{hash=(Get-FileHash $script).Hash;output=$stage})){
   $denied=$false
   try{Invoke-BoundWindowsSqlHostClient -LabModuleFile (Join-Path $repoRoot 'SqlServerLab.psd1') -ExpectedLabCommit ('0'*40) -RunId ([guid]'11111111-1111-1111-1111-111111111111') -ScriptPath $script -ExpectedScriptSha256 $test.hash -OutputDirectory $test.output -WhatIf|Out-Null}catch{$denied=$true}
   Check 'Bad input/replay denied without credentials' $denied
  }
 }
 $payload=Join-Path $stage 'payload.json';$destination=Join-Path $stage 'native-arguments.txt'
 @{contract='SqlServerLab.WindowsSqlHostClient/1.0';script=$script;scriptSha256=(Get-FileHash $script).Hash;arguments=@('-Value','Synthetisch Grüße Ω ; $literal','-Destination',$destination);output=$stage}|ConvertTo-Json -Depth 5|Set-Content $payload -Encoding utf8
 & (Get-Command pwsh).Source -NoProfile -File (Join-Path $repoRoot 'Tests/Integration/WindowsSqlHostClient.Worker.ps1') -PayloadPath $payload
 Check 'Actual separate worker preserves named Unicode arguments without evaluation' ($LASTEXITCODE-eq 0 -and [IO.File]::ReadAllText($destination)-ceq 'Synthetisch Grüße Ω ; $literal')
 [IO.File]::WriteAllText($script,'throw "MUST_NOT_EXECUTE_CHANGED_SOURCE"')
 & (Get-Command pwsh).Source -NoProfile -File (Join-Path $repoRoot 'Tests/Integration/WindowsSqlHostClient.Worker.ps1') -PayloadPath $payload
 Check 'Changed source is denied before child execution' ($LASTEXITCODE-ne 0)
 $result=Get-Content (Join-Path $stage 'process.private.json') -Raw|ConvertFrom-Json
 Check 'Exit outcome never pretends qualification success' ($result.exitCode-ne 0 -and $result.qualificationPassNotImplied)
}finally{
 $resolved=[IO.Path]::GetFullPath($stage);$bound=[IO.Path]::GetFullPath((Join-Path $repoRoot '.artifacts/test-runs'))+[IO.Path]::DirectorySeparatorChar
 if(-not $resolved.StartsWith($bound,[StringComparison]::OrdinalIgnoreCase)){throw 'CLEANUP_PATH_BOUND'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output ('WINDOWS_SQL_HOST_CLIENT_STATIC_PASS '+$passed+' checks; no credential or VM access')
