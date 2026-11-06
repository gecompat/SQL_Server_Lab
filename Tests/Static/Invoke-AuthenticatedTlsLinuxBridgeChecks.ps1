#Requires -Version 7.5
[CmdletBinding()]
param([switch]$Worker,[string]$FixtureRoot)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $PSScriptRoot '../Common/TestTemporaryDirectory.ps1')
if(-not$IsWindows){Write-Host 'NOT_APPLICABLE: Windows controller bridge';exit 0}
if(-not$Worker){
    $owned=New-TestTemporaryDirectory -ParentPath (Join-Path $repo '.artifacts/test-runs/linux-bridge')
    $process=[Diagnostics.Process]::new();$info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($arg in @('-NoProfile','-File',$PSCommandPath,'-Worker','-FixtureRoot',$owned.Path)){$info.ArgumentList.Add($arg)}
    $process.StartInfo=$info;$ended=$false
    try{
        $null=$process.Start();$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
        if(-not$process.WaitForExit(30000)){$process.Kill($true);$ended=$process.WaitForExit(5000);throw 'LOCAL_BRIDGE_FIXTURE_TIMEOUT'}
        $ended=$true;$text=$out.GetAwaiter().GetResult();$errorText=$err.GetAwaiter().GetResult()
        if($process.ExitCode-ne0){Write-Host $text;Write-Host $errorText;throw 'LOCAL_BRIDGE_FIXTURE_FAILED'}
        Write-Host $text.Trim()
    }finally{$process.Dispose();if($ended){Remove-TestTemporaryDirectory -OwnedDirectory $owned}}
    exit 0
}
if(-not[IO.Path]::IsPathFullyQualified($FixtureRoot)-or-not(Test-Path -LiteralPath (Join-Path $FixtureRoot '.test-owner'))){throw 'FIXTURE_OWNER_REQUIRED'}
$module=New-Module -ArgumentList $repo,$FixtureRoot,(Get-Process -Id $PID).Path -ScriptBlock {
    param($Repo,$Root,$Pwsh)
    foreach($name in @('AuthenticatedTlsRequest.ps1','AuthenticatedTlsRegistryIndex.ps1','AuthenticatedTlsLab.ps1','AuthenticatedTlsLinuxSession.ps1','AuthenticatedTlsLinuxBridge.ps1','AuthenticatedTlsLinuxClient.ps1')){
        . (Join-Path $Repo ('Private/'+$name))
    }
    $script:Root=$Root;$script:Pwsh=$Pwsh;$script:Mode='normal';$script:Removed=0;$script:Idles=0;$script:LeaseExits=0
    $script:Bytes=[Text.Encoding]::UTF8.GetBytes('synthetic-private-snapshot')
    $script:Hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($script:Bytes)).ToLowerInvariant()
    function Get-LabTlsOwnBinding {param($StateRoot,$RunId,$InstanceId);[pscustomobject]@{StateRoot=$StateRoot;Record=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.4';Provider='docker'}}}
    function New-LabTlsRuntimeBudget {param($Provider,$StateRoot,$Record);@{StateRoot=$StateRoot;Provider=$Provider;DeadlineUtc=[DateTime]::UtcNow.AddMinutes(2)}}
    function Read-SqlServerLabQualifiedTestEnvironment {
        param($ExportBytes,$StateRoot,$RunId,$InstanceId)
        [pscustomobject]@{ContractVersion='SqlServerLab.QualifiedTestEnvironmentSnapshot/0.1';ExportBytes=[byte[]]$ExportBytes.Clone();ExportSha256=$script:Hash;VerifiedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
            Qualification=[pscustomobject]@{Status='QUALIFIED';ClientPlatform='linux';ClientRef='22222222-2222-2222-2222-222222222222';ClientContextDigest=('c'*64);ExpiresAt=$script:Expiry.ToString('o');SqlVersion='2025';Patch='cu9';SqlBuild='17.0.5005.3'}}
    }
    function Read-LabTlsQualifiedExportSnapshot {param($ExportBytes,[switch]$FromBytes,$StateRoot,$RunId,$InstanceId,$Budget);Read-SqlServerLabQualifiedTestEnvironment $ExportBytes $StateRoot $RunId $InstanceId}
    function Get-LabTlsLinuxClientBinding {param($Bound,$Budget);[pscustomobject]@{Sha256=('c'*64);Record=[pscustomobject]@{ClientRef='22222222-2222-2222-2222-222222222222';Client=[pscustomobject]@{ContainerId=('d'*64)}}}}
    function Get-LabTlsLinuxConsumerSourceSet {param($ToolbeltRoot);return ,([Collections.Generic.List[object]]::new())}
    function Enter-LabTlsLinuxOperation {param($StateRoot);@{Root=$StateRoot;Sid='synthetic';Held=$true}}
    function Exit-LabTlsLinuxOperation {param($Lease);$script:LeaseExits++}
    function Assert-LabTlsLinuxGuestIdle {param($ContainerId,$Budget);$script:Idles++}
    function Initialize-LabTlsLinuxConsumerFiles {param($Bound,$Budget,$Client,$SourceSet,$Directory)}
    function Get-LabTlsCaByteDigest {param([byte[]]$Bytes);[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
    function ConvertTo-LabTlsRegistryWriterBytes {param($Value);[Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 10 -Compress))}
    function Write-LabTlsCaPrivateFile {param($Path,$Sid,$Bytes);[IO.File]::WriteAllBytes($Path,$Bytes)}
    function Get-LabTlsLinuxExecArguments {param($ContainerId,$Command,[switch]$InputStream);@('synthetic')}
    function Assert-LabTlsRuntimeBudget {param($Budget,$Commands)}
    function Remove-LabTlsLinuxClientIfPresent {param($StateRoot,$RunId);$script:Removed++;$p=Join-Path $StateRoot 'linux-client-execution.json';if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Force}}
    function New-LabTlsRuntimeProcessInfo {
        param($Arguments,$Budget)
        $program=@'
$ErrorActionPreference='Stop'
$boot=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([Console]::In.ReadLine()))|ConvertFrom-Json
function Send($Prefix,$Value){[Console]::Out.WriteLine($Prefix+' '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Compress))));[Console]::Out.Flush()}
if($env:BRIDGE_FIXTURE_MODE-ceq'malformed'){[Console]::Out.WriteLine('UNKNOWN');exit 7}
if($env:BRIDGE_FIXTURE_MODE-ceq'oversize'){[Console]::Out.Write(('x'*9000));[Console]::Out.Flush();exit 7}
$guestPid=switch($env:BRIDGE_FIXTURE_MODE){pid-string{[string]$PID};pid-bool{$true};pid-float{3.5};pid-zero{0};pid-overflow{2147483648};pid-array{,@($PID)};default{$PID}}
Send HELLO @{ContractVersion='SqlServerLab.LinuxPeerHello/0.1';SessionRef=$boot.SessionRef;ProcessId=$guestPid}
foreach($stack in @('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD')){
    $ref=$boot.SessionRef;if($env:BRIDGE_FIXTURE_MODE-ceq'wrong-ref'){$ref='f'*64}
    Send VERIFY @{ContractVersion='SqlServerLab.LinuxClientVerificationRequest/0.1';SessionRef=$ref;RequestId=[guid]::NewGuid().ToString('D');Stack=$stack;ExportSha256=$boot.ExportSha256;ClientRef=$boot.ClientRef;ContextDigest=$boot.ContextDigest}
    $line=[Console]::In.ReadLine()
    if(-not$line.StartsWith('REPLY ')){exit 7}
    $reply=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line.Substring(6)))|ConvertFrom-Json
    if($reply.Status-cne'VERIFIED'){exit 7}
}
if($env:BRIDGE_FIXTURE_MODE-ceq'stderr'){[Console]::Error.Write('SYNTHETIC_PRIVATE_STDERR')}
Send RESULT @{ContractVersion='Toolbelt.LinuxLabPreflight/0.1';Status='PASS';ClientChecks=2;SqlBuild='17.0.5005.3';SqlClient='PASS';Odbc='PASS';Encrypt=$true;TrustServerCertificate=$false}
'@
        $i=[Diagnostics.ProcessStartInfo]::new($script:Pwsh);$i.UseShellExecute=$false;$i.CreateNoWindow=$true
        $i.RedirectStandardInput=$true;$i.RedirectStandardOutput=$true;$i.RedirectStandardError=$true
        $i.Environment['BRIDGE_FIXTURE_MODE']=$script:Mode
        foreach($arg in @('-NoProfile','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program)))){$i.ArgumentList.Add($arg)}
        $i
    }
    Export-ModuleMember -Function Read-SqlServerLabQualifiedTestEnvironment
}
$count=0
foreach($mode in @('normal','malformed','oversize','wrong-ref','stderr','pid-string','pid-bool','pid-float','pid-zero','pid-overflow','pid-array')){
    & $module {
        param($Mode)
        $script:Mode=$Mode;$script:Expiry=[DateTimeOffset]::UtcNow.AddMinutes(14);$script:Removed=0;$script:Idles=0;$script:LeaseExits=0
        $root=Join-Path $script:Root $Mode;$null=[IO.Directory]::CreateDirectory($root);$errorCode=$null;$result=$null
        try{$result=Invoke-LabTlsLinuxConsumerBridge $script:Bytes $root '11111111-1111-1111-1111-111111111111' primary 'synthetic-trusted-code'}catch{$errorCode=$_.Exception.Message;$trace=$_.ScriptStackTrace}
        if($Mode-ceq'normal'){
            if($errorCode-or$result.Status-cne'PASS'-or$script:Removed-ne0-or$script:Idles-ne2){throw ('NORMAL_FAILED '+$errorCode+'; '+$trace)}
        }elseif(-not$errorCode-or$script:Removed-ne1){throw ('REJECTION_OR_OWN_CLEANUP_FAILED '+$Mode+' '+$errorCode)}
        if($script:LeaseExits-ne1-or(Test-Path -LiteralPath (Join-Path $root 'linux-client-execution.json'))){throw 'LEASE_OR_MARKER_REMAINS'}
    } $mode
    $count++
}
Write-Host ('LOCAL_BRIDGE_PASS cases='+$count+'; actual local processes; provider/SQL=0; controller verification stub is not signature/native evidence')
Remove-Module $module
