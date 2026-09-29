# Isolated worker: Windows uses a job object; Linux uses setpriv parent-death signalling.
param([Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference='Stop'
$operationRoot=Split-Path -Parent $RequestPath
$request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
$installerProbe=$request.Contract -ceq 'SqlServerLab.LlamaCppInstallerProbe/1.0'
$receiptPath=Join-Path $operationRoot 'receipt.json'
function Write-Receipt([string]$Status,[string]$Code) {
    $exitCode=$null
    if($child -and $childTerminationConfirmed){try{$exitCode=$child.ExitCode}catch{}}
    $record=[ordered]@{OperationId=$request.OperationId;Status=$Status;Code=$Code;LaunchAttempted=[bool]$launchAttempted;ProbeStarted=[bool]$child;ExitCode=$exitCode;ChildTerminationConfirmed=[bool]$childTerminationConfirmed;ProcessId=if($child){$child.Id}else{$null};StartedAtUtcTicks=if($child){$child.StartTime.ToUniversalTime().Ticks}else{$null}}
    $temporary=$receiptPath+'.tmp'
    [IO.File]::WriteAllText($temporary,($record|ConvertTo-Json -Compress))
    [IO.File]::Move($temporary,$receiptPath,$true)
}
$child=$null;$outStream=$null;$errStream=$null;$outTask=$null;$errTask=$null
$launchAttempted=$false;$childTerminationConfirmed=$false
$finalStatus='FAILED';$finalCode='LLAMA_WORKER_FAILED'
function Confirm-LabLlamaWorkerChildTermination {
    param([object]$Process,[bool]$LaunchAttempted)
    if(-not $Process){return -not $LaunchAttempted}
    try {
        if(-not $Process.HasExited){$Process.Kill($true)}
        return [bool]$Process.WaitForExit(15000)
    }catch{return $false}
}
try {
    if(-not $IsWindows -and -not $IsLinux){throw 'LLAMA_PLATFORM_UNSUPPORTED'}
    if($IsWindows){Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class SqlLabLlamaJob {
    static IntPtr job;
    static int probeBytes;
    [StructLayout(LayoutKind.Sequential)] struct Basic {
        public long processTime, jobTime; public uint flags;
        public UIntPtr minWorkingSet, maxWorkingSet; public uint activeProcesses;
        public UIntPtr affinity; public uint priority, scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct Io {public ulong a,b,c,d,e,f;}
    [StructLayout(LayoutKind.Sequential)] struct Limits {
        public Basic basic; public Io io;
        public UIntPtr processMemory, jobMemory, peakProcessMemory, peakJobMemory;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int info,ref Limits limits,uint length);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    public static async System.Threading.Tasks.Task<bool> CopyBounded(System.IO.Stream input, System.IO.Stream output) {
        var buffer=new byte[8192]; int total=0;
        while(true) {
            int count=await input.ReadAsync(buffer,0,buffer.Length).ConfigureAwait(false);
            if(count==0) return true;
            int allowed=Math.Min(count,4*1024*1024-total);
            if(allowed>0) await output.WriteAsync(buffer,0,allowed).ConfigureAwait(false);
            total+=allowed;
            if(allowed<count) return false;
        }
    }
    public static async System.Threading.Tasks.Task<bool> CopyProbeBounded(System.IO.Stream input, System.IO.Stream output) {
        var buffer=new byte[8192];
        while(true) {
            int count=await input.ReadAsync(buffer,0,buffer.Length).ConfigureAwait(false);
            if(count==0) return true;
            if(System.Threading.Interlocked.Add(ref probeBytes,count)>65536) return false;
            await output.WriteAsync(buffer,0,count).ConfigureAwait(false);
        }
    }
    public static void Protect() {
        job=CreateJobObject(IntPtr.Zero,null);
        if(job==IntPtr.Zero) throw new Win32Exception();
        var limits=new Limits(); limits.basic.flags=0x2000;
        if(!SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(typeof(Limits)))) throw new Win32Exception();
        if(!AssignProcessToJobObject(job,GetCurrentProcess())) throw new Win32Exception();
        // No inherited job handle: worker termination closes the final handle.
    }
}
"@
    [SqlLabLlamaJob]::Protect()}
    if($installerProbe) {
        if(-not $IsWindows){throw 'LLAMA_INSTALL_PLATFORM_UNSUPPORTED'}
        # A request never authorizes arbitrary commands: derive the sole executable
        # from the private operation layout and revalidate the repository pin.
        . (Join-Path $PSScriptRoot '../Private/LlamaCppInstaller.ps1')
        . (Join-Path $PSScriptRoot '../Private/LabPreferences.ps1')
        $script:CatalogsPath=Join-Path $PSScriptRoot '../Catalogs'
        $catalog=Get-LabLlamaInstallerCatalog
        $owner=Split-Path -Parent $operationRoot
        $expectedOwner=$catalog.Item.Tag+'-'+$catalog.Item.Sha256.Substring(0,12)+'.operation'
        if((Split-Path -Leaf $operationRoot) -cne 'probe' -or (Split-Path -Leaf $owner) -cne $expectedOwner){throw 'LLAMA_INSTALL_PROBE_SCOPE'}
        $package=Join-Path $owner ('stage/'+[IO.Path]::GetFileNameWithoutExtension($catalog.Item.AssetName))
        Test-LabLlamaInstallerFiles -Path $package -Catalog $catalog.Item
        $request.Invocation=Join-Path $package 'llama-server.exe'
        $request.Arguments=@('--version')
        $request.StartTimeoutSeconds=15;$request.LeaseSeconds=15
    }
    $stopBuffer=[byte[]]::new(1)
    $stopSignal=[Console]::OpenStandardInput().ReadAsync($stopBuffer,0,1)
    Write-Receipt 'PREPARED' $(if($IsWindows){'OWN_JOB_READY'}else{'PARENT_DEATH_SIGNAL_READY'})
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=if($IsLinux){[string]$request.SupervisorInvocation}else{[string]$request.Invocation};$start.WorkingDirectory=Split-Path -Parent $request.Invocation
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    if($installerProbe) {
        $start.Environment.Clear()
        $systemRoot=[Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
        $start.Environment['SystemRoot']=$systemRoot;$start.Environment['WINDIR']=$systemRoot
        $start.Environment['PATH']=Join-Path $systemRoot 'System32'
        $working=Join-Path $operationRoot 'empty'
        $null=Assert-LabLlamaInstallerPath -Path $working
        if(Test-Path -LiteralPath $working){throw 'LLAMA_INSTALL_PROBE_WORKDIR_EXISTS'}
        $null=[IO.Directory]::CreateDirectory($working)
        $start.WorkingDirectory=$working
        foreach($name in @('PROGRAMDATA','APPDATA','LOCALAPPDATA','USERPROFILE','HOME','TEMP','TMP')){$start.Environment[$name]=$working}
    }
    foreach($key in @($start.Environment.Keys)) {
        if($key -match '^(LLAMA|GGML|CUDA|HIP|OPENVINO|OV_|HF_|HUGGING_FACE|ROCR)'){$null=$start.Environment.Remove($key)}
    }
    if(-not $installerProbe){foreach($property in $request.Environment.PSObject.Properties){$start.Environment[$property.Name]=[string]$property.Value}}
    if($IsLinux){foreach($arg in @('--pdeathsig','KILL','--',[string]$request.Invocation)){$start.ArgumentList.Add($arg)}}
    foreach($arg in $request.Arguments){$start.ArgumentList.Add([string]$arg)}
    $outStream=[IO.FileStream]::new((Join-Path $operationRoot 'stdout.log'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,1,[IO.FileOptions]::Asynchronous)
    $errStream=[IO.FileStream]::new((Join-Path $operationRoot 'stderr.log'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,1,[IO.FileOptions]::Asynchronous)
    if($installerProbe -and $stopSignal.IsCompleted){throw 'LLAMA_INSTALL_OWNER_CLOSED'}
    $launchAttempted=$true
    $child=[Diagnostics.Process]::Start($start)
    if($installerProbe){
        $outTask=[SqlLabLlamaJob]::CopyProbeBounded($child.StandardOutput.BaseStream,$outStream)
        $errTask=[SqlLabLlamaJob]::CopyProbeBounded($child.StandardError.BaseStream,$errStream)
    }else{
        $outTask=[SqlLabLlamaJob]::CopyBounded($child.StandardOutput.BaseStream,$outStream)
        $errTask=[SqlLabLlamaJob]::CopyBounded($child.StandardError.BaseStream,$errStream)
    }
    Write-Receipt 'RUNNING' 'ENDPOINT_NOT_PROBED'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $reason='PROCESS_EXITED'
    while(-not $child.WaitForExit(100)) {
        if($stopSignal.IsCompleted){$reason='OWNER_CLOSED';break}
        if($request.StartTimeoutSeconds -and $watch.Elapsed.TotalSeconds -ge [int]$request.StartTimeoutSeconds -and -not (Test-Path -LiteralPath (Join-Path $operationRoot 'ready'))){$reason='START_TIMEOUT';break}
        if($watch.Elapsed.TotalSeconds -ge [int]$request.LeaseSeconds){$reason='LEASE_EXPIRED';break}
        if(($outTask.IsCompleted -and -not $outTask.GetAwaiter().GetResult()) -or ($errTask.IsCompleted -and -not $errTask.GetAwaiter().GetResult())){$reason='OUTPUT_LIMIT';break}
    }
    if(-not $child.HasExited){$child.Kill($true)}
    if(-not $child.WaitForExit(15000)){throw 'LLAMA_TERMINATION_UNCONFIRMED'}
    $childTerminationConfirmed=$true
    if($installerProbe){
        if(-not $outTask.Wait(2000) -or -not $errTask.Wait(2000) -or -not $outTask.GetAwaiter().GetResult() -or -not $errTask.GetAwaiter().GetResult()){throw 'LLAMA_INSTALL_PROBE_OUTPUT_LIMIT'}
        $outStream.Flush();$errStream.Flush()
        # ReadAllText opens with FileShare.Read: finish the bounded writers first.
        $outStream.Dispose();$outStream=$null
        $errStream.Dispose();$errStream=$null
        $text=[IO.File]::ReadAllText((Join-Path $operationRoot 'stdout.log'))+[IO.File]::ReadAllText((Join-Path $operationRoot 'stderr.log'))
        if($reason -ceq 'OWNER_CLOSED'){throw 'LLAMA_INSTALL_PROBE_OWNER_CLOSED'}
        if($reason -cin @('START_TIMEOUT','LEASE_EXPIRED')){throw 'LLAMA_INSTALL_PROBE_TIMEOUT'}
        if($reason -ceq 'OUTPUT_LIMIT'){throw 'LLAMA_INSTALL_PROBE_OUTPUT_LIMIT'}
        if($child.ExitCode -ne 0){throw 'LLAMA_INSTALL_PROBE_NONZERO_EXIT'}
        if($text -cnotmatch '(?m)^version: [^\r\n]+ \(build 11247, commit 0bc845d35\)\r?$'){throw 'LLAMA_INSTALL_PROBE_VERSION_MISMATCH'}
        Test-LabLlamaInstallerFiles -Path $package -Catalog $catalog.Item
        $finalStatus='BINARY_PROBE_PASSED';$finalCode='COMPUTE_SQL_NOT_CHECKED'
    }else{
        $finalStatus='STOPPED';$finalCode=$reason
    }
}
catch {
    $finalStatus='FAILED';$finalCode='LLAMA_WORKER_FAILED'
    if($installerProbe){
        $fixedCodes=@('LLAMA_INSTALL_PROBE_OUTPUT_LIMIT','LLAMA_INSTALL_PROBE_TIMEOUT','LLAMA_INSTALL_PROBE_OWNER_CLOSED','LLAMA_INSTALL_PROBE_NONZERO_EXIT','LLAMA_INSTALL_PROBE_VERSION_MISMATCH')
        $finalCode=if($_.Exception.Message -cin $fixedCodes){$_.Exception.Message}
            elseif($_.Exception.Message -cin @('LLAMA_INSTALL_FILES_MISSING','LLAMA_INSTALL_FILESET_MISMATCH','LLAMA_INSTALL_CATALOG_INVALID','LLAMA_INSTALL_PROBE_SCOPE')){'LLAMA_INSTALL_PROBE_PACKAGE_FAILED'}
            elseif($launchAttempted -and -not $child){'LLAMA_INSTALL_PROBE_START_FAILED'}
            elseif(-not $launchAttempted){'LLAMA_INSTALL_PROBE_SETUP_FAILED'}
            else{'LLAMA_INSTALL_PROBE_FAILED'}
    }
}
finally {
    $childTerminationConfirmed=Confirm-LabLlamaWorkerChildTermination -Process $child -LaunchAttempted $launchAttempted
    if(-not $childTerminationConfirmed){$finalStatus='RECOVERY_REQUIRED';$finalCode='LLAMA_TERMINATION_UNCONFIRMED'}
    Write-Receipt $finalStatus $finalCode
    foreach($task in @($outTask,$errTask)){if($task){try{$null=$task.Wait(2000)}catch{}}}
    if($outStream){$outStream.Dispose()};if($errStream){$errStream.Dispose()}
    if($child){$child.Dispose()}
    $keyPath=Join-Path $operationRoot 'api-key.txt'
    if(Test-Path -LiteralPath $keyPath){Remove-Item -LiteralPath $keyPath -Force}
}
