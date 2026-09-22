# Isolated Windows worker: the job owns this worker and every child it creates.
param([Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference='Stop'
$operationRoot=Split-Path -Parent $RequestPath
$request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
$receiptPath=Join-Path $operationRoot 'receipt.json'
function Write-Receipt([string]$Status,[string]$Code) {
    $record=[ordered]@{OperationId=$request.OperationId;Status=$Status;Code=$Code;ProcessId=if($child){$child.Id}else{$null};StartedAtUtcTicks=if($child){$child.StartTime.ToUniversalTime().Ticks}else{$null}}
    $temporary=$receiptPath+'.tmp'
    [IO.File]::WriteAllText($temporary,($record|ConvertTo-Json -Compress))
    [IO.File]::Move($temporary,$receiptPath,$true)
}
$child=$null;$outStream=$null;$errStream=$null;$outTask=$null;$errTask=$null
try {
    if(-not $IsWindows){throw 'LLAMA_WINDOWS_REQUIRED'}
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class SqlLabLlamaJob {
    static IntPtr job;
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
    [SqlLabLlamaJob]::Protect()
    $stopBuffer=[byte[]]::new(1)
    $stopSignal=[Console]::OpenStandardInput().ReadAsync($stopBuffer,0,1)
    Write-Receipt 'PREPARED' 'OWN_JOB_READY'
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$request.Invocation;$start.WorkingDirectory=Split-Path -Parent $request.Invocation
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($key in @($start.Environment.Keys)) {
        if($key -match '^(LLAMA|GGML|CUDA|HIP|OPENVINO|OV_|HF_|HUGGING_FACE|ROCR)'){$null=$start.Environment.Remove($key)}
    }
    foreach($property in $request.Environment.PSObject.Properties){$start.Environment[$property.Name]=[string]$property.Value}
    foreach($arg in $request.Arguments){$start.ArgumentList.Add([string]$arg)}
    $outStream=[IO.FileStream]::new((Join-Path $operationRoot 'stdout.log'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,1,[IO.FileOptions]::Asynchronous)
    $errStream=[IO.FileStream]::new((Join-Path $operationRoot 'stderr.log'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,1,[IO.FileOptions]::Asynchronous)
    $child=[Diagnostics.Process]::Start($start)
    $outTask=[SqlLabLlamaJob]::CopyBounded($child.StandardOutput.BaseStream,$outStream)
    $errTask=[SqlLabLlamaJob]::CopyBounded($child.StandardError.BaseStream,$errStream)
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
    Write-Receipt 'STOPPED' $reason
}
catch {
    Write-Receipt 'FAILED' 'LLAMA_WORKER_FAILED'
}
finally {
    if($child -and -not $child.HasExited){try{$child.Kill($true);$null=$child.WaitForExit(15000)}catch{Write-Receipt 'RECOVERY_REQUIRED' 'LLAMA_TERMINATION_UNCONFIRMED'}}
    foreach($task in @($outTask,$errTask)){if($task){try{$null=$task.Wait(2000)}catch{}}}
    if($outStream){$outStream.Dispose()};if($errStream){$errStream.Dispose()}
    if($child){$child.Dispose()}
    $keyPath=Join-Path $operationRoot 'api-key.txt'
    if(Test-Path -LiteralPath $keyPath){Remove-Item -LiteralPath $keyPath -Force}
}
