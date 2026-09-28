# Actual Windows file handles and restricted CRT writes; no SQL, VM or UAC.
& {
    if(-not $IsWindows){Write-Host '  NOT_EXECUTED  CSharp trace file: Windows ACL and CRT required';return}
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tests/Integration/Fixtures/CSharp/guest.ps1'),[ref]$null,[ref]$null)
    foreach($name in @('Initialize-CSharpGuestTraceInterop','Get-CSharpGuestTraceSddl','Assert-CSharpGuestTraceAcl','New-CSharpGuestTraceFile','Open-CSharpGuestTraceFile','Read-CSharpGuestTraceTail','Get-CSharpGuestLaunchpadSid')){
        $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true)
        . ([scriptblock]::Create($node.Extent.Text))
    }
    Initialize-CSharpGuestTraceInterop
    $root=Join-Path $nativeRoot 'trace-file';$null=[IO.Directory]::CreateDirectory($root)
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $restricted='S-1-5-21-100-200-300-4567'
    $sddl='O:'+ $user +'D:P(A;;FA;;;'+$user+')(A;;0x120116;;;'+$restricted+')'
    $file=Join-Path $root 'trace';$neighbor=Join-Path $root 'neighbor';$absent=Join-Path $root 'absent'
    $stream=[SqlServerLab.CSharpTraceFile]::Open($file,$true,$sddl)
    try{Assert-CSharpGuestTraceAcl $stream $sddl;$identity=[SqlServerLab.CSharpTraceFile]::Identity($stream.SafeFileHandle)}finally{$stream.Dispose()}
    Add-CheckResult -Name 'CSharp trace file: actual initial protected ACL and single-link file identity' -Success ($identity -cmatch '^[a-f0-9]{24}$')
    $caught='';try{$unexpected=[SqlServerLab.CSharpTraceFile]::Open($file,$true,$sddl);$unexpected.Dispose()}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name 'CSharp trace file: actual CreateNew collision preserves file' -Success ($caught -match 'CSHARP_TRACE_OPEN' -and ([IO.File]::ReadAllText($file)).Length -eq 0)
    $stream=[SqlServerLab.CSharpTraceFile]::Open($file,$false,$null)
    try{$caught='';try{Assert-CSharpGuestTraceAcl $stream ($sddl.Replace('0x120116','FA'))}catch{$caught=$_.Exception.Message}}finally{$stream.Dispose()}
    Add-CheckResult -Name 'CSharp trace file: actual ACL rejects a mismatched rights contract' -Success ($caught -ceq 'CSHARP_TRACE_ACL')
    $stream=[SqlServerLab.CSharpTraceFile]::Open($file,$false,$null)
    try{$caught='';try{Assert-CSharpGuestTraceAcl $stream ($sddl.Replace('O:'+$user,'O:BA'))}catch{$caught=$_.Exception.Message}}finally{$stream.Dispose()}
    Add-CheckResult -Name 'CSharp trace file: actual owner must match the expected owner' -Success ($caught -ceq 'CSHARP_TRACE_ACL')
    [IO.File]::WriteAllText($neighbor,'untouched')
    $source=@'
using System;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class CSharpTraceRestrictedCrt {
 [StructLayout(LayoutKind.Sequential)] struct SidAndAttributes { public IntPtr Sid; public uint Attributes; }
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool CreateRestrictedToken(IntPtr existing,uint flags,uint disabled,IntPtr disable,uint deleted,IntPtr delete,uint count,ref SidAndAttributes restrict,out IntPtr token);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool ImpersonateLoggedOnUser(IntPtr token);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool RevertToSelf();
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool CreateHardLink(string link,string existing,IntPtr reserved);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool CreateSymbolicLink(string link,string existing,uint flags);
 [DllImport("ucrtbase.dll",CharSet=CharSet.Unicode,CallingConvention=CallingConvention.Cdecl)] static extern IntPtr _wfopen(string path,string mode);
 [DllImport("ucrtbase.dll",CallingConvention=CallingConvention.Cdecl)] static extern int fputs([MarshalAs(UnmanagedType.LPStr)]string text,IntPtr stream);
 [DllImport("ucrtbase.dll",CallingConvention=CallingConvention.Cdecl)] static extern int fclose(IntPtr stream);
 public static bool[] Run(string sid,string file,string neighbor,string absent) {
  IntPtr original=IntPtr.Zero,restricted=IntPtr.Zero,pointer=IntPtr.Zero; bool impersonated=false;
  try {
   var identity=new SecurityIdentifier(sid); byte[] bytes=new byte[identity.BinaryLength]; identity.GetBinaryForm(bytes,0); pointer=Marshal.AllocHGlobal(bytes.Length);Marshal.Copy(bytes,0,pointer,bytes.Length);
   if(!OpenProcessToken(GetCurrentProcess(),0x0002|0x0008|0x0001,out original))throw new Exception("OPEN_TOKEN_"+Marshal.GetLastWin32Error());
   var item=new SidAndAttributes{Sid=pointer,Attributes=0};
   if(!CreateRestrictedToken(original,9,0,IntPtr.Zero,0,IntPtr.Zero,1,ref item,out restricted))throw new Exception("RESTRICT_TOKEN_"+Marshal.GetLastWin32Error());
   if(!ImpersonateLoggedOnUser(restricted))throw new Exception("IMPERSONATE_"+Marshal.GetLastWin32Error()); impersonated=true;
   bool[] results=new bool[3]; string[] paths={file,neighbor,absent};
   for(int i=0;i<3;i++){IntPtr stream=_wfopen(paths[i],"a"); if(stream!=IntPtr.Zero){results[i]=fputs("synthetic trace\n",stream)>=0;results[i]&=fclose(stream)==0;}}
   return results;
  } finally {if(impersonated&&!RevertToSelf())Environment.FailFast("REVERT_FAILED");if(restricted!=IntPtr.Zero)CloseHandle(restricted);if(original!=IntPtr.Zero)CloseHandle(original);if(pointer!=IntPtr.Zero)Marshal.FreeHGlobal(pointer);}
 }
}
'@
    Add-Type -TypeDefinition $source
    $result=[CSharpTraceRestrictedCrt]::Run($restricted,$file,$neighbor,$absent)
    Add-CheckResult -Name 'CSharp trace file: actual CRT append with write-restricted token and FILE_GENERIC_WRITE' -Success ($result[0] -and [IO.File]::ReadAllText($file).Contains('synthetic trace'))
    Add-CheckResult -Name 'CSharp trace file: restricted token cannot write neighbor or create file' -Success (-not $result[1] -and -not $result[2] -and [IO.File]::ReadAllText($neighbor) -ceq 'untouched' -and -not(Test-Path $absent))
    $link=Join-Path $root 'hardlink'
    if(-not [CSharpTraceRestrictedCrt]::CreateHardLink($link,$file,[IntPtr]::Zero)){throw 'SYNTHETIC_HARDLINK_CREATE'}
    $caught='';try{$unexpected=[SqlServerLab.CSharpTraceFile]::Open($file,$false,$null);$unexpected.Dispose()}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name 'CSharp trace file: actual multiple-hardlink file is rejected by handle' -Success ($caught -match 'CSHARP_TRACE_FILE_IDENTITY')
    & {
        function Get-CimInstance {param($ClassName,$Filter)return [pscustomobject]@{StartName='synthetic-foreign-service'}}
        $caught='';try{Get-CSharpGuestLaunchpadSid}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name 'CSharp trace file: actual service identity gate rejects changed Launchpad account' -Success ($caught -ceq 'CSHARP_TRACE_LAUNCHPAD_IDENTITY')
    }
    $launchpad='S-1-5-80-1-2-3-4-5'
    $descriptor=[Security.AccessControl.RawSecurityDescriptor]::new((Get-CSharpGuestTraceSddl $launchpad))
    $writers=@($descriptor.DiscretionaryAcl|Where-Object {$_.SecurityIdentifier.Value -in @($launchpad,'S-1-15-2-1')})
    Add-CheckResult -Name 'CSharp trace file: two exact file-only writer grants exclude delete owner and ACL changes' -Success ($writers.Count -eq 2 -and @($writers|Where-Object {$_.AccessMask -ne 0x120116 -or $_.AceFlags -ne 0}).Count -eq 0)
    & {
        function Get-CSharpGuestLaunchpadSid {return 'synthetic'}
        function Open-CSharpGuestTraceFile {param($GuestRoot,$LaunchpadSid)return [IO.File]::OpenRead((Join-Path $GuestRoot 'tail'))}
        $tailPath=Join-Path $root 'tail';[IO.File]::WriteAllBytes($tailPath,[byte[]](0..255)*200)
        $tail=Read-CSharpGuestTraceTail $root
        Add-CheckResult -Name 'CSharp trace file: bounded tail reports exact length offset and truncation' -Success ($tail.Length -eq 51200 -and $tail.Offset -eq 18432 -and $tail.Bytes -eq 32768 -and $tail.Truncated -and [Convert]::FromBase64String($tail.TailBase64)[32767] -eq 255)
        [IO.File]::WriteAllText($tailPath,'');$empty=Read-CSharpGuestTraceTail $root
        Add-CheckResult -Name 'CSharp trace file: empty file differs from unavailable diagnostics' -Success ($empty.Status -ceq 'EMPTY' -and $empty.Length -eq 0 -and -not $empty.Truncated)
    }
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        $reparse=Join-Path $root 'reparse'
        if(-not [CSharpTraceRestrictedCrt]::CreateSymbolicLink($reparse,$neighbor,0)){throw 'SYNTHETIC_REPARSE_CREATE'}
        $caught='';try{$unexpected=[SqlServerLab.CSharpTraceFile]::Open($reparse,$false,$null);$unexpected.Dispose()}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name 'CSharp trace file: actual reparse file rejected without following target' -Success ($caught -match 'CSHARP_TRACE_FILE_IDENTITY' -and [IO.File]::ReadAllText($neighbor) -ceq 'untouched')
        $owned=Join-Path $root 'owned';$null=[IO.Directory]::CreateDirectory($owned)
        New-CSharpGuestTraceFile $owned $launchpad
        $bound=Open-CSharpGuestTraceFile $owned $launchpad;try{$valid=$bound.Length -eq 0}finally{$bound.Dispose()}
        Add-CheckResult -Name 'CSharp trace file: elevated actual creation and protected identity binding' -Success $valid
        $marker=Join-Path $owned 'hostfxr-trace.identity'
        [IO.File]::WriteAllText($marker,('0'*24))
        $caught='';try{$unexpected=Open-CSharpGuestTraceFile $owned $launchpad;$unexpected.Dispose()}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name 'CSharp trace file: actual identity substitution rejected' -Success ($caught -ceq 'CSHARP_TRACE_BINDING')
    }else{Write-Host '  NOT_EXECUTED  CSharp trace file: real admin-owned guest fixture requires elevated Windows CI'}
}
