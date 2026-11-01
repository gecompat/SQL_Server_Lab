#Requires -Version 7.2
<#
.SYNOPSIS
    Startet einen eigenen nativen Windows-SQL-Qualifikationsclient am Host.
.DESCRIPTION
    Testwerkzeug für einen gebundenen laufenden Windows-SQL-Hyper-V-Run.
    Die vorhandene geschützte Gastanmeldung bleibt im Labmodul. Ein lokaler
    PowerShell-Client erhält nur eine flüchtige Netzwerkanmeldesitzung. Keine
    Kennwortausgabe, kein savecred, keine Änderung von Host-/VM-/SQL-Einstellungen.
    Ein gestarteter Prozess belegt noch keine erfolgreiche SQL-Anmeldung.
    Das aufrufende Qualifikationsverfahren besitzt Ergebnis, Timeout und Cleanup.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
 [string]$LabModuleFile,
 [string]$ExpectedLabCommit,
 [guid]$RunId,
 [string]$InstanceId='primary',
 [string]$StateRoot,
 [string]$ScriptPath,
 [string]$ExpectedScriptSha256,
 [string[]]$ScriptArguments=@(),
 [string]$OutputDirectory,
 [switch]$DefinitionsOnly
)
function Get-BoundClientNativeCode {
@'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class LabBoundWindowsSqlClient {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
 public struct Startup {
  public int cb; public string reserved,desktop,title;
  public int x,y,width,height,columns,rows,fill,flags;
  public short show,reservedSize; public IntPtr reservedPointer,input,output,error;
 }
 [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo {public IntPtr process,thread;public int pid,tid;}
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 static extern bool CreateProcessWithLogonW(string user,string domain,IntPtr password,int logonFlags,
  string application,StringBuilder command,int creationFlags,IntPtr environment,string directory,ref Startup startup,out ProcessInfo process);
 [DllImport("kernel32.dll",SetLastError=true)]static extern bool CloseHandle(IntPtr handle);
 public static int Start(string domain,IntPtr password,string executable,string worker,string payload,string directory){
  foreach(string path in new[]{executable,worker,payload,directory})
   if(String.IsNullOrEmpty(path)||path.IndexOf('"')>=0||path.IndexOf('\r')>=0||path.IndexOf('\n')>=0)
    throw new ArgumentException("WINDOWS_SQL_HOST_CLIENT_PATH_INVALID");
  var command=new StringBuilder("\""+executable+"\" -NoLogo -NoProfile -File \""+worker+"\" -PayloadPath \""+payload+"\"");
  if(command.Length>=1024)throw new ArgumentException("WINDOWS_SQL_HOST_CLIENT_COMMAND_BOUND");
  var startup=new Startup();startup.cb=Marshal.SizeOf(startup);startup.flags=1;startup.show=0;
  ProcessInfo process;
  if(!CreateProcessWithLogonW("Administrator",domain,password,2,executable,command,0x08000400,IntPtr.Zero,directory,ref startup,out process))
   throw new Win32Exception(Marshal.GetLastWin32Error(),"WINDOWS_SQL_HOST_CLIENT_START_FAILED");
  try{return process.pid;}finally{CloseHandle(process.thread);CloseHandle(process.process);}
 }
}
'@
}
function Resolve-BoundClientPowerShell {
 $exe=(Get-Command pwsh.exe -ErrorAction Stop).Source
 if(-not [IO.Path]::IsPathRooted($exe) -or (Split-Path -Leaf $exe)-ine 'pwsh.exe'){throw 'WINDOWS_SQL_HOST_CLIENT_POWERSHELL_REQUIRED'}
 $signature=Get-AuthenticodeSignature -FilePath $exe
 if($signature.Status-ne 'Valid' -or $signature.SignerCertificate.Subject-notmatch '(^|,\s*)O=Microsoft Corporation(,|$)'){throw 'WINDOWS_SQL_HOST_CLIENT_POWERSHELL_SIGNATURE'}
 return $exe
}
function Assert-BoundClientWorker([string]$Path){
 # Git-Checkouts können CRLF verwenden. Ausschließlich CRLF -> LF und die
 # UTF8-Textdarstellung normalisieren; keine übrigen Sourceänderungen zulassen.
 $text=[IO.File]::ReadAllText($Path).Replace("`r`n","`n")
 $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($text)))
 if($hash-cne 'C5148A8DB2C05265F52C937E27B26C492409FF3B918642BBBD33471A43FB1823'){
  throw 'WINDOWS_SQL_HOST_CLIENT_WORKER_CHANGED'
 }
}
function Invoke-BoundWindowsSqlHostClient {
 [CmdletBinding(SupportsShouldProcess)]
 param([Parameter(Mandatory)][string]$LabModuleFile,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedLabCommit,[Parameter(Mandatory)][guid]$RunId,
  [string]$InstanceId='primary',[string]$StateRoot,
  [Parameter(Mandatory)][string]$ScriptPath,[Parameter(Mandatory)][ValidatePattern('^[0-9A-F]{64}$')][string]$ExpectedScriptSha256,
  [string[]]$ScriptArguments=@(),[Parameter(Mandatory)][string]$OutputDirectory)
 $ErrorActionPreference='Stop'
 if([Environment]::OSVersion.Platform-ne [PlatformID]::Win32NT){throw 'WINDOWS_SQL_HOST_CLIENT_WINDOWS_REQUIRED'}
 $scriptFile=[IO.Path]::GetFullPath($ScriptPath);$moduleFile=[IO.Path]::GetFullPath($LabModuleFile);$output=[IO.Path]::GetFullPath($OutputDirectory)
 if((Split-Path -Leaf $moduleFile)-cne 'SqlServerLab.psd1' -or -not (Test-Path -LiteralPath $moduleFile) -or
    [IO.Path]::GetExtension($scriptFile)-ine '.ps1' -or (Get-FileHash -LiteralPath $scriptFile).Hash-cne $ExpectedScriptSha256){throw 'WINDOWS_SQL_HOST_CLIENT_INPUT_CHANGED'}
 if($ScriptArguments.Count-gt 32 -or @($ScriptArguments|Where-Object {$null-eq $_ -or $_.Length-gt 2048 -or $_.Contains([char]0)}).Count){throw 'WINDOWS_SQL_HOST_CLIENT_ARGUMENT_BOUND'}
 if(Test-Path -LiteralPath $output){throw 'WINDOWS_SQL_HOST_CLIENT_NO_REPLAY_OUTPUT_EXISTS'}
 $moduleRoot=Split-Path -Parent $moduleFile
 if((git -C $moduleRoot rev-parse HEAD)-cne $ExpectedLabCommit -or (git -C $moduleRoot status --porcelain --untracked-files=all)){throw 'WINDOWS_SQL_HOST_CLIENT_MODULE_BINDING'}
 $exe=Resolve-BoundClientPowerShell
 $worker=Join-Path $PSScriptRoot 'WindowsSqlHostClient.Worker.ps1'
 Assert-BoundClientWorker $worker
 if(-not $PSCmdlet.ShouldProcess($RunId.ToString()+'/'+$InstanceId,'Start bound native Windows SQL qualification client')){return}
 [void][IO.Directory]::CreateDirectory($output)
 $payloadPath=Join-Path $output 'payload.private.json'
 $payload=[ordered]@{contract='SqlServerLab.WindowsSqlHostClient/1.0';script=$scriptFile;scriptSha256=$ExpectedScriptSha256;arguments=@($ScriptArguments);output=$output}
 [IO.File]::WriteAllText($payloadPath,($payload|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
 if(-not ('LabBoundWindowsSqlClient'-as [type])){Add-Type -TypeDefinition (Get-BoundClientNativeCode)}
 $module=Import-Module $moduleFile -Force -PassThru -DisableNameChecking
 $result=& $module {
  param($run,$instance,$state,$exe,$worker,$payload,$output)
  $ErrorActionPreference='Stop'
  if(-not $state){$state=Get-LabStateRoot}
  $context=Get-LabSsisPrerequisiteContext -RunId $run -InstanceId $instance -StateRoot $state
  $credential=$null;$pointer=[IntPtr]::Zero
  try{
   $credential=Get-LabSecret -Path $context.Directory -Name 'guest-administrator-password'
   if(-not $credential){throw 'WINDOWS_SQL_HOST_CLIENT_CREDENTIAL_REQUIRED'}
   $response=@(Invoke-HyperVPowerShellDirect -VMName ([string]$context.Instance.vmName) -ExpectedRunId $run.ToString() -ExpectedScopeId ([string]$context.Run.scopeId) -ExpectedVmId ([guid]$context.Instance.vmId) -Credential ([pscredential]::new('Administrator',$credential)) -NoRetry -TimeoutSeconds 30 -ScriptBlock {$env:COMPUTERNAME} -ArgumentList @() -ErrorAction Stop 3>$null 4>$null 5>$null 6>$null)
   if($response.Count-ne 1 -or $response[0]-isnot [string] -or $response[0]-cnotmatch '^[A-Za-z0-9-]{1,63}$'){throw 'WINDOWS_SQL_HOST_CLIENT_COMPUTER_BINDING'}
   $fresh=Get-LabSsisPrerequisiteContext -RunId $run -InstanceId $instance -StateRoot $state
   if($fresh.Fingerprint-cne $context.Fingerprint){throw 'WINDOWS_SQL_HOST_CLIENT_BINDING_CHANGED'}
   $pointer=[Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($credential)
   $clientId=[LabBoundWindowsSqlClient]::Start($response[0],$pointer,$exe,$worker,$payload,$output)
   [pscustomobject]@{ContractVersion='SqlServerLab.WindowsSqlHostClient/1.0';RunId=$run.ToString();InstanceId=$instance;ProcessId=$clientId;Outcome='STARTED_AUTHENTICATION_UNCONFIRMED';AutomaticRetry=$false;CredentialReturned=$false}
  }finally{
   if($pointer-ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer)}
   if($credential){$credential.Dispose()}
  }
 } $RunId $InstanceId $StateRoot $exe $worker $payloadPath $output
 [IO.File]::WriteAllText((Join-Path $output 'launch.private.json'),($result|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
 return $result
}
if(-not $DefinitionsOnly){
 $invoke=@{};foreach($key in $PSBoundParameters.Keys){if($key-ne 'DefinitionsOnly'){$invoke[$key]=$PSBoundParameters[$key]}}
 Invoke-BoundWindowsSqlHostClient @invoke
}
