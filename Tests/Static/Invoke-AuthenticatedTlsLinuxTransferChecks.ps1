#Requires -Version 7.5
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
. (Join-Path $PSScriptRoot '../Common/TestTemporaryDirectory.ps1')
$passed=0;$failures=[Collections.Generic.List[string]]::new()
function Check([string]$Name,[scriptblock]$Body){try{& $Body;Add-CheckResult $Name $true}catch{Add-CheckResult $Name $false $_.Exception.Message}}
if(-not $IsWindows){Write-Host 'NOT_APPLICABLE: Windows controller transfer';exit 0}
$owned=New-TestTemporaryDirectory -ParentPath (Join-Path $repo '.artifacts/test-runs/linux-transfer');$temp=$owned.Path
$inputPath=Join-Path $temp 'input.bin';$data=[byte[]]::new(24576);[Security.Cryptography.RandomNumberGenerator]::Fill($data);[IO.File]::WriteAllBytes($inputPath,$data)
$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($data)).ToLowerInvariant()
$pwsh=(Get-Process -Id $PID).Path
$module=New-Module -ArgumentList $repo,$pwsh,$temp,$inputPath -ScriptBlock {
    param($Repo,$Pwsh,$Temp,$Source)
    . (Join-Path $Repo 'Private/AuthenticatedTlsLinuxTransfer.ps1')
    $script:Executable=$Pwsh;$script:InputFile=$Source;$script:Root=$Temp;$script:Starts=0
    function Get-LabOwnedHostPolicy {param($StateRoot,[switch]$Required);@{}}
    function Assert-LabTlsRuntimeBudget {param($Budget,$Count)}
    function Write-LabTlsCaPrivateFile {throw 'UNCONFIRMED_LOCAL_TEST_PROCESS'}
    function Get-LabTlsWindowsProcessFacts {@{UserSid='synthetic'}}
    function ConvertTo-LabTlsRegistryWriterBytes {param($Value);[Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json))}
    function New-LabTlsRuntimeProcessInfo {
        param($Arguments,$Budget)
        $script:Starts++
        $body=switch($Arguments[0]){
            normal {
                @'
$memory=[IO.MemoryStream]::new();[Console]::OpenStandardInput().CopyTo($memory)
$locked=$false;try{[IO.File]::WriteAllText($env:TEST_TRANSFER_INPUT,'changed')}catch{$locked=$true}
[Console]::Write('INPUT='+$memory.Length+';LOCKED='+$locked);$memory.Dispose()
'@
            }
            stderr {"[Console]::OpenStandardInput().CopyTo([IO.Stream]::Null);[Console]::Error.Write('SYNTHETIC_PRIVATE_ERROR');exit 7"}
            output {"[Console]::OpenStandardInput().CopyTo([IO.Stream]::Null);[Console]::Write(('x'*1049000))"}
            timeout {'[Console]::OpenStandardInput().CopyTo([IO.Stream]::Null);Start-Sleep -Seconds 10'}
            default {throw 'TEST_MODE_INVALID'}
        }
        $info=[Diagnostics.ProcessStartInfo]::new($script:Executable)
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.Environment['TEST_TRANSFER_INPUT']=$script:InputFile
        foreach($arg in @('-NoProfile','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body)))){$info.ArgumentList.Add($arg)}
        $info
    }
    Export-ModuleMember -Function @()
}
function Transfer([string]$Mode,[string]$Hash=$hash,[long]$Bytes=$data.Length,[int]$Milliseconds=15000){
    & $module {param($Mode,$Path,$Hash,$Bytes,$Milliseconds)
        $budget=@{StateRoot=$script:Root;DeadlineUtc=[DateTimeOffset]::UtcNow.AddMilliseconds($Milliseconds)}
        Invoke-LabTlsLinuxFileTransfer -Budget $budget -Arguments @($Mode) -InputPath $Path -ExpectedSha256 $Hash -ExpectedBytes $Bytes
    } $Mode $inputPath $Hash $Bytes $Milliseconds
}
function Reject([scriptblock]$Body,[string]$Expected){$message='';try{& $Body|Out-Null}catch{$message=$_.Exception.Message};if($message-cne$Expected){throw ('Expected '+$Expected+'; actual '+$message)}}
try{
    Check 'Actual local process receives exact bytes while source stays write-locked' {if((Transfer normal)-cne'INPUT=24576;LOCKED=True'){throw 'TRANSFER_RESULT_MISMATCH'}}
    Check 'Hash mismatch rejects before process creation' {$before=& $module {$script:Starts};Reject {Transfer normal ('0'*64)} 'TLS_LINUX_TRANSFER_SOURCE_CHANGED';if((& $module {$script:Starts})-ne$before){throw 'UNEXPECTED_PROCESS'}}
    Check 'Length mismatch rejects before process creation' {Reject {Transfer normal $hash 24575} 'TLS_LINUX_TRANSFER_SOURCE_CHANGED'}
    Check 'Input bound rejects before process creation' {Reject {Transfer normal $hash 83886081} 'TLS_LINUX_TRANSFER_INPUT_INVALID'}
    Check 'Process failure never exposes raw stderr' {Reject {Transfer stderr} 'TLS_LINUX_TRANSFER_COMMAND_FAILED'}
    Check 'Output remains bounded' {Reject {Transfer output} 'TLS_LINUX_TRANSFER_OUTPUT_LIMIT'}
    Check 'Deadline kills and confirms actual local process' {Reject {Transfer timeout $hash $data.Length 1000} 'TLS_LINUX_TRANSFER_TIMEOUT'}
    Check 'Source bytes and recovery state remain unchanged' {if((Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()-cne$hash-or(Test-Path -LiteralPath (Join-Path $temp 'tls-linux-process-recovery.json'))){throw 'CUSTODY_OR_SOURCE_CHANGED'}}
}finally{Remove-Module $module;Remove-TestTemporaryDirectory -OwnedDirectory $owned}
Write-Host ('Checks: '+$passed+' passed, '+$failures.Count+' failed')
if($failures.Count){exit 1}
