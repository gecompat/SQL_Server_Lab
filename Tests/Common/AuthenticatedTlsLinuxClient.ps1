# Test-only transport and certificate fixtures. Every provider command retains
# the ordinary owned-host policy and the original runtime pin.
function Assert-TlsLinuxPowerShellPackage {
    param([string]$Path)
    # Fixed v7.6.6 linux-x64 asset, verified against official release metadata.
    if((Get-Item -LiteralPath $Path).Length -ne 75876271 -or
        (Get-FileHash -LiteralPath $Path).Hash -cne 'DDBC4A2D113BBD46D283CFEDCBCD117A70CAEFD7673F41F2B4E0000BADF103BC'){
        throw 'TLS_LINUX_PINNED_POWERSHELL_PACKAGE_INVALID'
    }
}

function Get-TlsLinuxWorkerFailureCode {
    param([string]$Stderr)
    $allowed=@('TLS_LINUX_PROVIDER_UNAVAILABLE','TLS_LINUX_READINESS_BLOCKED','TLS_LINUX_PINNED_POWERSHELL_PACKAGE_INVALID',
        'TLS_LINUX_NEW_EVIDENCE_REQUIRED','TLS_LINUX_PARENT_CUSTODY_NOT_ASSIGNED','TLS_LINUX_TICKET_NOT_HELD',
        'TLS_LINUX_ASSIGNED_WORKER_MISMATCH','TLS_LINUX_CUSTODY_CLOSED','TLS_LINUX_SUPERVISOR_TICKET_INVALID',
        'TLS_LINUX_ACCEPTANCE_FAILED_SEE_PRIVATE_TERMINAL')
    $codes=@([regex]::Matches($Stderr,'\bTLS_LINUX_[A-Z0-9_]{1,96}\b')|ForEach-Object{$_.Value}|Where-Object{$_ -cin $allowed}|Sort-Object -Unique)
    if($codes.Count -eq 1){return $codes[0]}
    return 'UNCLASSIFIED_PRIVATE_HASH_ONLY'
}

function New-TlsLinuxWorkerJob {
    if(-not $IsWindows){throw 'TLS_LINUX_CONTROLLER_WINDOWS_REQUIRED'}
    if(-not ('SqlServerLab.TlsLinuxWorkerJob' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace SqlServerLab {
 public sealed class TlsLinuxWorkerJob : IDisposable {
  IntPtr job; bool terminationAttempted, terminationConfirmed;
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
  [StructLayout(LayoutKind.Sequential)] struct Accounting {
   public long processTime, jobTime, periodProcessTime, periodJobTime;
   public uint faults, totalProcesses, activeProcesses, terminatedProcesses;
  }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes,string name);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int info,ref Limits limits,uint length);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint exitCode);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int info,out Accounting accounting,uint length,IntPtr returned);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  public TlsLinuxWorkerJob() {
   job=CreateJobObject(IntPtr.Zero,null);
   if(job==IntPtr.Zero) throw new Win32Exception();
   var limits=new Limits(); limits.basic.flags=0x2000;
   if(!SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(typeof(Limits)))) {
    int error=Marshal.GetLastWin32Error();Dispose();throw new Win32Exception(error);
   }
  }
  public void Assign(IntPtr process) {
   if(terminationAttempted) throw new InvalidOperationException("TLS_LINUX_JOB_CLOSED");
   if(!AssignProcessToJobObject(job,process)) throw new Win32Exception();
  }
  public bool TerminateAndConfirm(int milliseconds) {
   if(job==IntPtr.Zero) throw new ObjectDisposedException("TlsLinuxWorkerJob");
   if(terminationAttempted) return terminationConfirmed;
   terminationAttempted=true;
   if(!TerminateJobObject(job,1)) throw new Win32Exception();
   var clock=System.Diagnostics.Stopwatch.StartNew();
   do {
    Accounting accounting;
    if(!QueryInformationJobObject(job,1,out accounting,(uint)Marshal.SizeOf(typeof(Accounting)),IntPtr.Zero)) throw new Win32Exception();
    if(accounting.activeProcesses==0) {terminationConfirmed=true;return true;}
    System.Threading.Thread.Sleep(10);
   } while(clock.ElapsedMilliseconds<milliseconds);
   return false;
  }
  public void Dispose() {
   if(job!=IntPtr.Zero){
    if(!TerminateAndConfirm(5000)) throw new InvalidOperationException("TLS_LINUX_JOB_TERMINATION_UNCONFIRMED");
    if(!CloseHandle(job)) throw new Win32Exception();
    job=IntPtr.Zero;
   }
  }
 }
}
'@
    }
    return [SqlServerLab.TlsLinuxWorkerJob]::new()
}

function Assert-TlsLinuxNoRecoveryCustody {
    $custody=Get-Variable -Name SqlServerLabTlsLinuxRecoveryCustody -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if($null -ne $custody -and $custody.Count -gt 0){throw 'TLS_LINUX_EXISTING_CUSTODY_RECOVERY_REQUIRED'}
}

function Publish-TlsLinuxWorkerReady {
    param([string]$ReadyFile,[int]$WorkerId,[long]$WorkerStartTicks)
    $pending=$ReadyFile+'.pending'
    $ready=[IO.File]::Open($pending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{
        $bytes=[Text.Encoding]::UTF8.GetBytes((@{WorkerId=$WorkerId;WorkerStartTicks=$WorkerStartTicks}|ConvertTo-Json -Compress))
        $ready.Write($bytes,0,$bytes.Length);$ready.Flush($true)
    }finally{$ready.Dispose()}
    # The worker never observes the pending name. Publish complete closed bytes
    # in this same directory and refuse replacement of an existing Ready.
    [IO.File]::Move($pending,$ReadyFile,$false)
}

function Assert-TlsLinuxTicketHeld {
    param([string]$TicketPath)
    $opened=$null
    try{$opened=[IO.File]::Open($TicketPath,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)}
    catch{
        $failure=$_.Exception.GetBaseException()
        if($failure -is [IO.IOException] -and ($failure.HResult -band 0xffff) -eq 32){return}
        throw 'TLS_LINUX_TICKET_CUSTODY_UNCONFIRMED'
    }finally{if($opened){$opened.Dispose()}}
    throw 'TLS_LINUX_TICKET_NOT_HELD'
}

function Enter-TlsLinuxWorkerCustody {
    param([string]$TicketPath,$Ticket,[int]$WorkerId,[long]$WorkerStartTicks)
    $control=[IO.Path]::GetDirectoryName($TicketPath)
    foreach($entry in @{ReadyFile='custody-assigned';ClaimFile='worker-claimed';ClosedFile='custody-closed'}.GetEnumerator()){
        if($Ticket.($entry.Key) -cne (Join-Path $control $entry.Value)){throw 'TLS_LINUX_CUSTODY_PATH_INVALID'}
    }
    if(Test-Path -LiteralPath $Ticket.ClosedFile){throw 'TLS_LINUX_CUSTODY_CLOSED'}
    Assert-TlsLinuxTicketHeld $TicketPath
    $ready=Get-Content -LiteralPath $Ticket.ReadyFile -Raw|ConvertFrom-Json -DateKind String
    if($ready.WorkerId -ne $WorkerId -or $ready.WorkerStartTicks -ne $WorkerStartTicks){throw 'TLS_LINUX_ASSIGNED_WORKER_MISMATCH'}
    $claim=[IO.File]::Open($Ticket.ClaimFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{
        $bytes=[Text.Encoding]::UTF8.GetBytes((@{WorkerId=$WorkerId;WorkerStartTicks=$WorkerStartTicks}|ConvertTo-Json -Compress))
        $claim.Write($bytes,0,$bytes.Length);$claim.Flush($true)
    }finally{$claim.Dispose()}
    Assert-TlsLinuxTicketHeld $TicketPath
    if(Test-Path -LiteralPath $Ticket.ClosedFile){throw 'TLS_LINUX_CUSTODY_CLOSED'}
}

function Invoke-TlsLinuxSupervisedProcess {
    param([Diagnostics.ProcessStartInfo]$StartInfo,[DateTimeOffset]$StopAt,[DateTimeOffset]$Deadline,[string]$StopFile,$WorkerJob,[string]$ReadyFile)
    $process=[Diagnostics.Process]::new();$process.StartInfo=$StartInfo;$started=$false;$confirmed=$false
    $outputs=@([IO.MemoryStream]::new(),[IO.MemoryStream]::new());$stopRequested=$false;$hardStopped=$false;$jobEmpty=$false
    $clock=[Diagnostics.Stopwatch]::StartNew();$now=[DateTimeOffset]::UtcNow
    $stopSeconds=($StopAt-$now).TotalSeconds;$hardSeconds=($Deadline-$now).TotalSeconds
    if($stopSeconds -le 0 -or $hardSeconds -le $stopSeconds){throw 'TLS_LINUX_SUPERVISOR_DEADLINES_INVALID'}
    try{
        $started=$process.Start()
        if($WorkerJob){
            $WorkerJob.Assign($process.Handle)
            Publish-TlsLinuxWorkerReady -ReadyFile $ReadyFile -WorkerId $process.Id -WorkerStartTicks $process.StartTime.ToUniversalTime().Ticks
        }
        $pipes=@($process.StandardOutput.BaseStream,$process.StandardError.BaseStream)
        $buffers=@([byte[]]::new(4096),[byte[]]::new(4096));$done=@($false,$false)
        $tasks=@($pipes[0].ReadAsync($buffers[0],0,4096),$pipes[1].ReadAsync($buffers[1],0,4096));$total=0
        while($true){
            if(-not $stopRequested -and ($clock.Elapsed.TotalSeconds -ge $stopSeconds -or [DateTimeOffset]::UtcNow -ge $StopAt -or (Test-Path -LiteralPath $StopFile))){
                if(-not(Test-Path -LiteralPath $StopFile)){
                    $signal=[IO.File]::Open($StopFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
                    try{$bytes=[Text.Encoding]::UTF8.GetBytes('STOP_REQUESTED');$signal.Write($bytes,0,$bytes.Length);$signal.Flush($true)}finally{$signal.Dispose()}
                }
                $stopRequested=$true
            }
            if($clock.Elapsed.TotalSeconds -ge $hardSeconds -or [DateTimeOffset]::UtcNow -ge $Deadline){
                $hardStopped=$true
                if($WorkerJob){$jobEmpty=$WorkerJob.TerminateAndConfirm(5000);if(-not $jobEmpty){throw 'TLS_LINUX_JOB_TERMINATION_UNCONFIRMED'}}
                elseif(-not $process.HasExited){$process.Kill($true)}
                if(-not $process.WaitForExit(5000)){throw 'TLS_LINUX_SUPERVISOR_TERMINATION_UNCONFIRMED'}
                $confirmed=$true
                break
            }
            for($i=0;$i -lt 2;$i++){
                if(-not $done[$i] -and $tasks[$i].IsCompleted){
                    $count=$tasks[$i].GetAwaiter().GetResult();if($count -eq 0){$done[$i]=$true;continue}
                    $total+=$count;if($total -gt 1048576){throw 'TLS_LINUX_SUPERVISOR_OUTPUT_LIMIT'}
                    $outputs[$i].Write($buffers[$i],0,$count);$tasks[$i]=$pipes[$i].ReadAsync($buffers[$i],0,4096)
                }
            }
            if($process.HasExited){
                if($WorkerJob -and -not $jobEmpty){$jobEmpty=$WorkerJob.TerminateAndConfirm(5000);if(-not $jobEmpty){throw 'TLS_LINUX_JOB_TERMINATION_UNCONFIRMED'}}
                if($done[0] -and $done[1]){$confirmed=$true;break}
            }
            Start-Sleep -Milliseconds 10
        }
        return @{ExitCode=$process.ExitCode;ExitConfirmed=$confirmed;JobEmptyConfirmed=$jobEmpty;StopRequested=$stopRequested;HardStopped=$hardStopped;ElapsedSeconds=$clock.Elapsed.TotalSeconds;Stdout=[Text.Encoding]::UTF8.GetString($outputs[0].ToArray());Stderr=[Text.Encoding]::UTF8.GetString($outputs[1].ToArray())}
    }finally{
        if($WorkerJob -and -not $jobEmpty){$jobEmpty=$WorkerJob.TerminateAndConfirm(5000);if(-not $jobEmpty){throw 'TLS_LINUX_JOB_TERMINATION_UNCONFIRMED'}}
        if($started -and -not $confirmed){if(-not $process.HasExited){$process.Kill($true)};if(-not $process.WaitForExit(5000)){throw 'TLS_LINUX_SUPERVISOR_TERMINATION_UNCONFIRMED'}}
        $process.Dispose();foreach($output in $outputs){$output.Dispose()};$StartInfo.ArgumentList.Clear()
    }
}

function New-TlsLinuxPolicyBudget {
    param($Context,[switch]$Cleanup)
    $bound=& $Context.Module {
        param($Provider,$Root,$OriginalPin)
        $policy=Get-LabOwnedHostPolicy -StateRoot $Root -Required
        if($null -eq $OriginalPin){
            # Discover the original readonly physical context before attaching
            # the effect policy. Its Podman MachineName is never synthesized
            # from the policy's display/scope projection.
            $budget=New-LabTlsRuntimeBudget -Provider $Provider
            $pin=Get-LabTlsRuntimePin $budget
        }else{
            $pin=$OriginalPin
            $budget=New-LabTlsRuntimeBudget -Provider $Provider
            Assert-LabTlsRuntimeBudget $budget 1
            if((Get-LabRunArtifactRuntimeIncarnation -Context $pin -Invocation $pin.Invocation) -cne $pin.IncarnationKey){throw 'TLS_LINUX_ORIGINAL_RUNTIME_CHANGED'}
            $budget.RuntimeContext=$pin
        }
        Assert-LabTlsPolicyPin $policy $pin
        # All effectful commands still pass the unchanged owned-host gateway.
        $budget.StateRoot=$Root
        return @{Budget=$budget;Pin=$pin}
    } $Context.Provider $Context.StateRoot $Context.RuntimePin
    $Context.RuntimePin=$bound.Pin
    $Context.Budget=$bound.Budget
    $Context.Budget.DeadlineUtc=$(if($Cleanup){$Context.CleanupDeadline.UtcDateTime}else{$Context.Deadline.UtcDateTime})
}

function Enter-TlsLinuxCommandBudget {
    param($Context,[switch]$Cleanup)
    $limit=if($Cleanup){450}else{400}
    $deadline=if($Cleanup){$Context.CleanupDeadline}else{$Context.Deadline}
    if(-not $Cleanup -and (Test-Path -LiteralPath $Context.StopFile)){throw 'TLS_LINUX_STOP_REQUESTED'}
    if($Context.Commands -ge $limit -or [DateTimeOffset]::UtcNow -ge $deadline){throw 'TLS_LINUX_OPERATION_BUDGET_EXCEEDED'}
    $Context.Commands++
}

function Get-TlsLinuxNativeFailureDiagnostic {
    param([string]$Stdout,[string]$Stderr)
    $null=$Stderr # Formatting is deliberately not a diagnostic protocol.
    $allowed=@('TLS_LINUX_CLR_PROBE_FAILED','TLS_LINUX_CLR_CHILD_FAILED','TLS_LINUX_CLR_RESULT_INVALID',
        'TLS_LINUX_ODBC_POSITIVE_FAILED','TLS_LINUX_ODBC_CERTIFICATE_REJECTION_MISSING','TLS_LINUX_DRIVER_CHANGED',
        'TLS_LINUX_SQLCMD_CHANGED','TLS_LINUX_PROBE_INPUT_INVALID','TLS_LINUX_TRUST_BYTES_CHANGED','TLS_LINUX_TRUST_PATH_INVALID',
        'TLS_LINUX_PARENT_CONTEXT_INVALID','TLS_LINUX_NON_LOOPBACK_RESOLUTION','TLS_LINUX_CHILD_BOUND_EXCEEDED',
        'TLS_LINUX_CHILD_OUTPUT_TOO_LARGE','TLS_LINUX_ODBC_AMBIGUOUS','TLS_LINUX_PROBE_UNCLASSIFIED')
    foreach($suffix in @('EXIT_CERTIFICATE','EXIT_LOGIN','EXIT_LOGIN_TIMEOUT','EXIT_QUERY_TIMEOUT','EXIT_TIMEOUT','EXIT_NETWORK','EXIT_UNCLASSIFIED','STDERR','SQL_RESULT','DRIVER_NOT_OBSERVED','DRIVER_MAPS_UNREADABLE','DRIVER_PATTERN_MISSING')){$allowed+=('TLS_LINUX_ODBC_POSITIVE_'+$suffix)}
    foreach($code in @('PLATFORM_UNSUPPORTED','ASSEMBLY_UNAVAILABLE','CERTIFICATE','LOGIN','TIMEOUT','NETWORK','SQL_RESULT','UNCLASSIFIED')){
        foreach($stage in @('CONSTRUCT','OPEN','QUERY')){$allowed+=('TLS_LINUX_CLR_CLIENT_'+$code+'_'+$stage)}
    }
    if($Stdout.Length -le 4096){
        $document=$null
        try{
            $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=4
            $document=[Text.Json.JsonDocument]::Parse($Stdout,$options)
            if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'INVALID_DIAGNOSTIC'}
            $properties=@($document.RootElement.EnumerateObject())
            if($properties.Count -notin @(3,4)){throw 'INVALID_DIAGNOSTIC'}
            $record=@{}
            foreach($property in $properties){
                if($property.Name -cnotin @('Schema','Status','Code','Facts') -or $record.ContainsKey($property.Name)){throw 'INVALID_DIAGNOSTIC'}
                if($property.Name -ceq 'Facts'){$record.Facts=$property.Value}
                else{
                    if($property.Value.ValueKind -ne [Text.Json.JsonValueKind]::String){throw 'INVALID_DIAGNOSTIC'}
                    $record[$property.Name]=$property.Value.GetString()
                }
            }
            if($record.Status -cne 'FAIL' -or $record.Code -cnotin $allowed){throw 'INVALID_DIAGNOSTIC'}
            if($record.Schema -ceq 'SqlServerLab.TlsLinuxProbeFailure/1.0' -and $properties.Count -eq 3 -and -not $record.ContainsKey('Facts')){
                return @{Code=$record.Code;Source='STRUCTURED_PROBE_FAILURE'}
            }
            if($record.Schema -cnotin @('SqlServerLab.TlsLinuxProbeFailure/2.0','SqlServerLab.TlsLinuxProbeFailure/2.1') -or $properties.Count -ne 4 -or
                -not $record.ContainsKey('Facts') -or $record.Facts.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
                -not $record.Code.StartsWith('TLS_LINUX_ODBC_POSITIVE_',[StringComparison]::Ordinal)){throw 'INVALID_DIAGNOSTIC'}
            $extended=$record.Schema -ceq 'SqlServerLab.TlsLinuxProbeFailure/2.1'
            $facts=@{};$factProperties=@($record.Facts.EnumerateObject())
            $factNames=@('OdbcExitCode','ChildElapsedMilliseconds','DriverMaps','DriverObserved','ActualOdbcAddressFamily','LoopbackIpv4','LoopbackIpv6')
            if($extended){$factNames+=@('SqlcmdSha256','DriverSha256','DiagnosticKinds','TcpProviderErrorCode','PasswordEnvironmentPresentAtStart')}
            if($factProperties.Count -ne $factNames.Count){throw 'INVALID_DIAGNOSTIC'}
            foreach($fact in $factProperties){
                if($fact.Name -cnotin $factNames -or $facts.ContainsKey($fact.Name)){throw 'INVALID_DIAGNOSTIC'}
                if($fact.Name -cin @('OdbcExitCode','ChildElapsedMilliseconds')){
                    $number=0L
                    if($fact.Value.ValueKind -ne [Text.Json.JsonValueKind]::Number -or -not $fact.Value.TryGetInt64([ref]$number) -or
                        $number -lt 0 -or $number -gt $(if($fact.Name -ceq 'OdbcExitCode'){255}else{90000})){throw 'INVALID_DIAGNOSTIC'}
                    $facts[$fact.Name]=$number
                }elseif($fact.Name -ceq 'DiagnosticKinds'){
                    if($fact.Value.ValueKind -ne [Text.Json.JsonValueKind]::Array){throw 'INVALID_DIAGNOSTIC'}
                    $items=@($fact.Value.EnumerateArray());$kinds=[Collections.Generic.List[string]]::new()
                    if($items.Count -gt 13){throw 'INVALID_DIAGNOSTIC'}
                    foreach($item in $items){
                        if($item.ValueKind -ne [Text.Json.JsonValueKind]::String){throw 'INVALID_DIAGNOSTIC'}
                        $kind=$item.GetString()
                        if($kind -cnotin @('LOGIN_TIMEOUT','QUERY_TIMEOUT','CERTIFICATE','SSL_PROVIDER','SSL_PROTOCOL','SSL_CIPHER','SSL_EOF','PRELOGIN','TCP_PROVIDER','NETWORK_INSTANCE','NAME_RESOLUTION','PASSWORD_PROMPT','LOGIN_FAILED') -or $kinds.Contains($kind)){throw 'INVALID_DIAGNOSTIC'}
                        $kinds.Add($kind)
                    }
                    $facts[$fact.Name]=$kinds.ToArray()
                }elseif($fact.Name -cin @('DriverObserved','PasswordEnvironmentPresentAtStart')){
                    if($fact.Value.ValueKind -notin @([Text.Json.JsonValueKind]::True,[Text.Json.JsonValueKind]::False)){throw 'INVALID_DIAGNOSTIC'}
                    $facts[$fact.Name]=$fact.Value.GetBoolean()
                }else{
                    if($fact.Value.ValueKind -ne [Text.Json.JsonValueKind]::String){throw 'INVALID_DIAGNOSTIC'}
                    $value=$fact.Value.GetString()
                    if($fact.Name -cin @('SqlcmdSha256','DriverSha256')){
                        if($value -cnotmatch '\A[A-F0-9]{64}\z' -and -not($fact.Name -ceq 'DriverSha256' -and $value -ceq 'NOT_OBSERVED')){throw 'INVALID_DIAGNOSTIC'}
                        $facts[$fact.Name]=$value;continue
                    }
                    if($fact.Name -ceq 'TcpProviderErrorCode'){
                        if($value -cnotmatch '\A(?:NOT_OBSERVED|AMBIGUOUS|0x[A-F0-9]{8})\z'){throw 'INVALID_DIAGNOSTIC'}
                        $facts[$fact.Name]=$value;continue
                    }
                    $values=switch -CaseSensitive ($fact.Name){
                        DriverMaps{@('NOT_OBSERVED','UNREADABLE','READABLE')}
                        ActualOdbcAddressFamily{@('NOT_OBSERVED')}
                        default{@('NOT_RESOLVED','CONNECTED','REFUSED','TIMEOUT','ERROR')}
                    }
                    if($value -cnotin $values){throw 'INVALID_DIAGNOSTIC'}
                    $facts[$fact.Name]=$value
                }
            }
            if($facts.DriverObserved -and $facts.DriverMaps -cne 'READABLE'){throw 'INVALID_DIAGNOSTIC'}
            if($extended -and (($facts.DriverObserved -and $facts.DriverSha256 -ceq 'NOT_OBSERVED') -or
                (-not $facts.DriverObserved -and $facts.DriverSha256 -cne 'NOT_OBSERVED'))){throw 'INVALID_DIAGNOSTIC'}
            return @{Code=$record.Code;Source='STRUCTURED_PROBE_FAILURE';Facts=$facts}
        }catch{
            # A malformed diagnostic never changes the failed command outcome.
        }finally{if($document){$document.Dispose()}}
    }
    return @{Code='UNCLASSIFIED_NATIVE_EXIT';Source='UNCLASSIFIED'}
}

function Get-TlsLinuxNativeFailureArguments {
    param([string[]]$Arguments,[string]$Operation)
    if([string]::IsNullOrEmpty($Operation)){return ,$Arguments}
    if($Operation -cne 'CLIENT_NSS'){throw 'TLS_LINUX_DIAGNOSTIC_OPERATION_INVALID'}
    return ,@('OPERATION','CLIENT_NSS')
}

function Get-TlsLinuxNssFailureDiagnostic {
    param([string]$Stdout,[string]$Stderr)
    $null=$Stdout
    # Only the fixed command's known shell diagnostic formats qualify. A host,
    # container or arbitrary configuration error is not a missing NSS tool.
    $syntax=$Stderr -match '(?im)^tls-linux-nss: [0-9]{1,3}: Syntax error: [^\r\n]*\r?$'
    $tool=$Stderr -match '(?im)^tls-linux-nss: [0-9]{1,3}: /usr/bin/(?:awk|getent|timeout): (?:not found|No such file or directory)[ \t]*\r?$'
    if($syntax -and -not $tool){return @{Code='TLS_LINUX_NSS_SHELL_SYNTAX';Source='CLASSIFIED_NSS_FAILURE'}}
    if($tool -and -not $syntax){return @{Code='TLS_LINUX_NSS_TOOL_UNAVAILABLE';Source='CLASSIFIED_NSS_FAILURE'}}
    return @{Code='UNCLASSIFIED_NATIVE_EXIT';Source='UNCLASSIFIED'}
}

function Invoke-TlsLinuxNative {
    param($Context,[string[]]$Arguments,[string]$InputText,[string]$InputFile,[switch]$Cleanup,[ValidateSet('CLIENT_NSS')][string]$DiagnosticOperation)
    $failureArguments=Get-TlsLinuxNativeFailureArguments $Arguments $DiagnosticOperation
    $classifier=if($DiagnosticOperation -ceq 'CLIENT_NSS'){'Get-TlsLinuxNssFailureDiagnostic'}else{'Get-TlsLinuxNativeFailureDiagnostic'}
    Enter-TlsLinuxCommandBudget $Context -Cleanup:$Cleanup
    $deadline=if($Cleanup){$Context.CleanupDeadline}else{$Context.Deadline}
    return & $Context.Module {
        param($ArgsVector,$Text,$File,$Budget,$Deadline,$FailurePath,$ClassifyFailure,$FailureArguments)
        Assert-LabTlsRuntimeBudget $Budget 1
        $start=New-LabTlsRuntimeProcessInfo -Arguments $ArgsVector -Budget $Budget
        $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$started=$false;$source=$null;$inputBytes=$null
        $outputs=@([IO.MemoryStream]::new(),[IO.MemoryStream]::new());$completed=$false
        try{
            if($File){$source=[IO.File]::OpenRead($File)}else{$inputBytes=[Text.Encoding]::UTF8.GetBytes($Text);$source=[IO.MemoryStream]::new($inputBytes,$false)}
            $started=$process.Start();$write=$source.CopyToAsync($process.StandardInput.BaseStream);$inputClosed=$false
            $pipes=@($process.StandardOutput.BaseStream,$process.StandardError.BaseStream)
            $buffers=@([byte[]]::new(4096),[byte[]]::new(4096));$done=@($false,$false)
            $tasks=@($pipes[0].ReadAsync($buffers[0],0,4096),$pipes[1].ReadAsync($buffers[1],0,4096))
            $timer=[Diagnostics.Stopwatch]::StartNew();$total=0
            while($true){
                if($timer.Elapsed.TotalSeconds -ge 90 -or [DateTimeOffset]::UtcNow -ge $Deadline){throw 'TLS_LINUX_COMMAND_TIMEOUT'}
                if(-not $inputClosed -and $write.IsCompleted){$null=$write.GetAwaiter().GetResult();$process.StandardInput.Close();$inputClosed=$true}
                for($i=0;$i -lt 2;$i++){
                    if(-not $done[$i] -and $tasks[$i].IsCompleted){
                        $count=$tasks[$i].GetAwaiter().GetResult()
                        if($count -eq 0){$done[$i]=$true;continue}
                        $total+=$count;if($total -gt 1048576){throw 'TLS_LINUX_COMMAND_OUTPUT_LIMIT'}
                        $outputs[$i].Write($buffers[$i],0,$count);$tasks[$i]=$pipes[$i].ReadAsync($buffers[$i],0,4096)
                    }
                }
                if($process.HasExited -and $done[0] -and $done[1]){
                    $completed=$true
                    if($process.ExitCode -ne 0){
                        $diagnostic=& $ClassifyFailure -Stdout ([Text.Encoding]::UTF8.GetString($outputs[0].ToArray())) -Stderr ([Text.Encoding]::UTF8.GetString($outputs[1].ToArray()))
                        $proof=@{ExitCode=$process.ExitCode;DiagnosticCode=$diagnostic.Code;DiagnosticSource=$diagnostic.Source;Arguments=$FailureArguments;Input='NOT_LOGGED';StdoutSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($outputs[0].ToArray()));StderrSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($outputs[1].ToArray()));AtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
                        if($diagnostic.ContainsKey('Facts')){$proof.DiagnosticFacts=$diagnostic.Facts}
                        Write-LabTlsCaPrivateFile $FailurePath (Get-LabTlsWindowsProcessFacts).UserSid (ConvertTo-LabTlsRegistryWriterBytes $proof)
                        throw ('TLS_LINUX_NATIVE_COMMAND_FAILED:'+ $diagnostic.Code)
                    }
                    return [Text.UTF8Encoding]::new($false,$true).GetString($outputs[0].ToArray()).TrimEnd("`r","`n")
                }
                Start-Sleep -Milliseconds 10
            }
        }finally{
            if($started -and -not $completed){if(-not $process.HasExited){$process.Kill($true)};if(-not $process.WaitForExit(5000)){throw 'TLS_LINUX_TERMINATION_UNCONFIRMED'}}
            if($source){$source.Dispose()};if($inputBytes){[Array]::Clear($inputBytes,0,$inputBytes.Length)}
            foreach($output in $outputs){$output.Dispose()};$process.Dispose();$start.ArgumentList.Clear()
        }
    } $Arguments $InputText $InputFile $Context.Budget $deadline (Join-Path $Context.Evidence ('native-command-failure-'+$Context.Commands+'.private.json')) (Get-Command $classifier -CommandType Function).ScriptBlock $failureArguments
}

function Read-TlsLinuxPairResult {
    param([string]$Json)
    try {
        # Preserve the native RFC3339 text. Automatic DateTime conversion makes
        # a later string binding culture dependent on the Windows controller.
        $result=$Json|ConvertFrom-Json -Depth 16 -DateKind String
        if($result.Status -isnot [string] -or $result.Status -cne 'PASS' -or
            @($result.Results).Count -ne 2 -or $result.UtcNow -isnot [string] -or
            $result.UtcNow -cnotmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,7})?(?:Z|[+-][0-9]{2}:[0-9]{2})\z'){
            throw 'INVALID_PAIR'
        }
        $null=[DateTimeOffset]::Parse($result.UtcNow,[Globalization.CultureInfo]::InvariantCulture)
        return $result
    }catch{throw 'TLS_LINUX_PAIR_RESULT_INVALID'}
}

function Write-TlsLinuxProof {
    param($Context,[string]$Name,$Value)
    & $Context.Module {param($Path,$Data) Write-LabTlsCaPrivateFile $Path (Get-LabTlsWindowsProcessFacts).UserSid (ConvertTo-LabTlsRegistryWriterBytes $Data)} (Join-Path $Context.Evidence $Name) $Value
}

function Read-TlsLinuxSqlIdentity {
    param([string]$Text)
    if($Text -cnotmatch '\A10001:([0-9]{1,5}):10001:([0-9]{1,5}):([01])\z'){
        throw 'TLS_LINUX_SQL_IDENTITY_INVALID'
    }
    $gid=[int]$Matches[1];$accountGid=[int]$Matches[2];$writable=$Matches[3] -ceq '1'
    if($gid -gt 65535 -or $accountGid -gt 65535){throw 'TLS_LINUX_SQL_IDENTITY_INVALID'}
    return @{Uid=10001;Gid=$gid;AccountUid=10001;AccountGid=$accountGid;Writable=$writable}
}

function Initialize-TlsLinuxSqlExecutionIdentity {
    param($Context)
    if($Context.Version -isnot [string] -or $Context.Version -cnotin @('2019-CU32','2022-CU27','2025-CU9')){throw 'TLS_LINUX_SQL_PROFILE_INVALID'}
    $Context.SqlExecutionUser=$null
    if($Context.Version -ceq '2019-CU32'){
        # Preserve the already exercised SQL-2019 path.
        $Context.SqlExecutionUser='10001:0'
        return
    }
    if($Context.SqlId -isnot [string] -or $Context.SqlId -cnotmatch '\A[0-9a-f]{64}\z'){throw 'TLS_LINUX_SQL_IDENTITY_INVALID'}
    # Read-only differential before any leaf/key/configuration mutation. Keep
    # UID 10001 and let the SQL image resolve its account's primary group.
    $command='set -eu; u=$(id -u); g=$(id -g); a=$(id -u mssql); b=$(id -g mssql); w=0; if test -d /var/opt/mssql && test -w /var/opt/mssql; then w=1; fi; printf ''%s:%s:%s:%s:%s'' "$u" "$g" "$a" "$b" "$w"'
    $observations=@{}
    foreach($user in @('10001:0','10001')){
        $text=Invoke-TlsLinuxNative $Context @('exec','--user',$user,$Context.SqlId,'/bin/sh','-c',$command)
        $observations[$user]=Read-TlsLinuxSqlIdentity $text
    }
    $selected=$observations['10001']
    $qualified=$selected.Writable -and $selected.Gid -eq $selected.AccountGid
    Write-TlsLinuxProof $Context 'sql-execution-identity.private.json' @{Version=$Context.Version;ContainerId=$Context.SqlId;SelectedUser='10001';Observations=$observations;Qualified=$qualified;ReadOnly=$true}
    if(-not $qualified){throw 'TLS_LINUX_SQL_IDENTITY_UNQUALIFIED'}
    $Context.SqlExecutionUser='10001'
}

function Get-TlsLinuxSqlExecutionUser {
    param($Context)
    if($Context.Version -isnot [string] -or $Context.Version -cnotin @('2019-CU32','2022-CU27','2025-CU9')){throw 'TLS_LINUX_SQL_PROFILE_INVALID'}
    $expected=if($Context.Version -ceq '2019-CU32'){'10001:0'}else{'10001'}
    if($Context.SqlExecutionUser -isnot [string] -or $Context.SqlExecutionUser -cne $expected){throw 'TLS_LINUX_SQL_IDENTITY_UNQUALIFIED'}
    return $expected
}

function Get-TlsLinuxSqlProcessEpoch {
    param($Context)
    $user=Get-TlsLinuxSqlExecutionUser $Context
    $epoch=Invoke-TlsLinuxNative $Context @('exec','--user',$user,$Context.SqlId,'/bin/sh','-c',
        'set -eu; awk ''$2 == "(sqlservr)" {print $1 ":" $22}'' /proc/[0-9]*/stat 2>/dev/null | sort')
    $rows=@($epoch -split '\r?\n')
    if($rows.Count -lt 1 -or $rows.Count -gt 4 -or @($rows|Where-Object{$_ -cnotmatch '\A[1-9][0-9]*:[0-9]+\z'}).Count){throw 'TLS_LINUX_SQL_PROCESS_EPOCH_UNVERIFIABLE'}
    return $epoch
}

function New-TlsLinuxLeafFixture {
    param($Context,$Issuer,[ValidateSet('valid','wrong-san','expired','renewed')][string]$Kind)
    $directory='/var/opt/mssql/tls-linux-'+$Context.Audit.Replace('-','')+'/'+$Kind
    $dns=if($Kind -ceq 'wrong-san'){'mismatch.invalid'}else{'localhost'}
    $cid=$Context.SqlId
    $user=Get-TlsLinuxSqlExecutionUser $Context
    $null=Invoke-TlsLinuxNative $Context @('exec','--user',$user,$cid,'/bin/sh','-c',
        "set -eu; umask 077; mkdir -p '$directory'; test ! -e '$directory/server.key'; openssl req -new -newkey rsa:3072 -nodes -sha256 -subj '/CN=SQL_Server_Lab Server Leaf' -keyout '$directory/server.key' -out '$directory/server.csr' -outform DER -addext 'subjectAltName=DNS:$dns' 2>/dev/null")
    $encoded=Invoke-TlsLinuxNative $Context @('exec','--user',$user,$cid,'/usr/bin/base64','-w','0',($directory+'/server.csr'))
    $csr=[Convert]::FromBase64String($encoded)
    $leaf=& $Context.Module {
        param($Csr,$Dns,$Ca,$Kind)
        $identity=[pscustomobject]@{Kind='DNS';Value=$Dns};$public=Read-LabTlsServerLeafCsr $Csr $identity
        $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new([Security.Cryptography.X509Certificates.X500DistinguishedName]::new('CN=SQL_Server_Lab Server Leaf'),$public.PublicKey,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]'DigitalSignature, KeyEncipherment',$true))
        $oids=[Security.Cryptography.OidCollection]::new();$null=$oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids,$false))
        $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new();$san.AddDnsName($Dns);$request.CertificateExtensions.Add($san.Build())
        $now=[DateTimeOffset]::UtcNow;$begin=$now.AddMinutes(-2)
        # Load the short-lived certificate while valid, then observe real expiry
        # at unchanged clocks and with no intervening SQL restart.
        $end=if($Kind -ceq 'expired'){$now.AddSeconds(300)}else{$now.AddDays(1)}
        $certificate=$request.Create($Ca,$begin,$end,[Security.Cryptography.RandomNumberGenerator]::GetBytes(16))
        try{return @{Der=$certificate.RawData;SpkiSha256=(Get-LabTlsCaByteDigest $public.Spki);NotBeforeUtc=$certificate.NotBefore.ToUniversalTime().ToString('o');NotAfterUtc=$certificate.NotAfter.ToUniversalTime().ToString('o');Dns=$Dns;Kind=$Kind}}
        finally{$certificate.Dispose()}
    } $csr $dns $Issuer $Kind
    $pem=[Security.Cryptography.PemEncoding]::WriteString('CERTIFICATE',$leaf.Der)
    $null=Invoke-TlsLinuxNative $Context @('exec','-i','--user',$user,$cid,'/bin/sh','-c',"set -eu; umask 077; test ! -e '$directory/server.pem'; cat > '$directory/server.pem'") -InputText $pem
    $leaf.Directory=$directory
    Write-TlsLinuxProof $Context ('leaf-'+$Kind+'.private.json') $leaf
    return $leaf
}

function Set-TlsLinuxLeafFixture {
    param($Context,$Leaf)
    $user=Get-TlsLinuxSqlExecutionUser $Context
    if($Context.ClientIntent){throw 'TLS_LINUX_CLIENT_MUST_BE_REMOVED_BEFORE_SQL_RESTART'}
    foreach($setting in @(@('network.tlscert',($Leaf.Directory+'/server.pem')),@('network.tlskey',($Leaf.Directory+'/server.key')),@('network.forceencryption','1'))){
        $null=Invoke-TlsLinuxNative $Context @('exec','--user','0',$Context.SqlId,'/opt/mssql/bin/mssql-conf','set',$setting[0],$setting[1])
    }
    Enter-TlsLinuxCommandBudget $Context
    $stopped=Stop-SqlServerLab -RunId $Context.Run.RunId -StateRoot $Context.StateRoot -Force -SkipHostMemoryRelease -Confirm:$false
    if($stopped.Status -cne 'STOPPED' -or $stopped.Errors){throw 'TLS_LINUX_OWN_STOP_FAILED'}
    Enter-TlsLinuxCommandBudget $Context
    $started=Start-SqlServerLab -RunId $Context.Run.RunId -StateRoot $Context.StateRoot
    if($started.Status -cne 'RUNNING' -or $started.Errors){throw 'TLS_LINUX_OWN_START_FAILED'}
    $loaded="The certificate [Certificate File:'"+$Leaf.Directory+"/server.pem', Private Key File:'"+$Leaf.Directory+"/server.key'] was successfully loaded for encryption."
    $log=Invoke-TlsLinuxNative $Context @('exec','--user',$user,$Context.SqlId,'/usr/bin/tail','-n','120','/var/opt/mssql/log/errorlog')
    if(-not $log.Contains($loaded)){throw 'TLS_LINUX_SELECTED_CERTIFICATE_NOT_LOADED'}
    $null=Invoke-TlsLinuxNative $Context @('exec','--user',$user,$Context.SqlId,'/usr/bin/openssl','x509','-in',($Leaf.Directory+'/server.pem'),'-outform','DER','-out','/tmp/tls-linux-observed.der')
    $encoded=Invoke-TlsLinuxNative $Context @('exec','--user',$user,$Context.SqlId,'/usr/bin/base64','-w','0','/tmp/tls-linux-observed.der')
    if([Convert]::ToBase64String([Convert]::FromBase64String($encoded)) -cne [Convert]::ToBase64String($Leaf.Der)){throw 'TLS_LINUX_CERTIFICATE_BYTES_CHANGED'}
}

function Get-TlsLinuxBoundClientHostname {
    param([string]$Hostname,[string]$ObservedHostname,[string]$ClientId,[string]$IntentName)
    if($ClientId -cnotmatch '\A[a-f0-9]{64}\z' -or $IntentName -cnotmatch '\Atls-client-[a-f0-9]{32}\z' -or
        $Hostname -cne $ObservedHostname -or $Hostname -cnotin @($ClientId.Substring(0,12),$IntentName)){
        throw 'TLS_LINUX_CLIENT_HOSTNAME_BINDING_INVALID'
    }
    return $Hostname
}

function Read-TlsLinuxNssFacts {
    param([string]$Text)
    $facts=@{}
    foreach($line in ($Text -replace "`r`n","`n").TrimEnd("`n").Split("`n")){
        if($line -cnotmatch '\A(HOSTS_READABLE|HOSTS_ACTUAL|HOSTS_INTENT|LOCALHOST_EXIT|HOSTNAME_EXIT)=(0|[1-9][0-9]{0,2})\z' -or $facts.ContainsKey($Matches[1])){
            throw 'TLS_LINUX_NSS_DIAGNOSTIC_INVALID'
        }
        $name=$Matches[1];$value=[int]::Parse($Matches[2],[Globalization.CultureInfo]::InvariantCulture)
        if($value -gt $(if($name.StartsWith('HOSTS_',[StringComparison]::Ordinal)){1}else{255})){throw 'TLS_LINUX_NSS_DIAGNOSTIC_INVALID'}
        $facts[$name]=$value
    }
    if($facts.Count -ne 5){throw 'TLS_LINUX_NSS_DIAGNOSTIC_INVALID'}
    return $facts
}

function Assert-TlsLinuxClientNameResolution {
    param($Context,$Observation,[string]$Phase)
    $hostnameText=Invoke-TlsLinuxNative $Context @('exec',$Context.ClientId,'/usr/bin/cat','/proc/sys/kernel/hostname')
    $hostname=Get-TlsLinuxBoundClientHostname $hostnameText.TrimEnd("`r","`n") $Observation.Config.Hostname $Context.ClientId $Context.ClientIntent.ContainerName
    # Exact fixed script. The only arguments are already bound DNS-label names;
    # no files, names, addresses or getent output are returned to the controller.
    $script=@'
if [ -r /etc/hosts ]; then
  printf 'HOSTS_READABLE=1\n'
  /usr/bin/awk -v actual="$1" -v intent="$2" '{sub(/#.*/, ""); for (i=2; i<=NF; i++) {if ($i==actual) a=1; if ($i==intent) n=1}} END {printf "HOSTS_ACTUAL=%d\nHOSTS_INTENT=%d\n",a,n}' /etc/hosts
else
  printf 'HOSTS_READABLE=0\nHOSTS_ACTUAL=0\nHOSTS_INTENT=0\n'
fi
LC_ALL=C /usr/bin/timeout --signal=KILL 3s /usr/bin/getent ahostsv4 localhost >/dev/null 2>&1
printf 'LOCALHOST_EXIT=%s\n' "$?"
LC_ALL=C /usr/bin/timeout --signal=KILL 3s /usr/bin/getent ahostsv4 "$1" >/dev/null 2>&1
printf 'HOSTNAME_EXIT=%s\n' "$?"
'@
    # This literal is a Linux command string even in a CRLF checkout. Do not
    # normalize arbitrary argv, hostnames, payloads or credentials.
    $script=$script.Replace("`r`n","`n")
    if($script.Contains("`r")){throw 'TLS_LINUX_NSS_SHELL_TEXT_INVALID'}
    $text=Invoke-TlsLinuxNative $Context @('exec',$Context.ClientId,'/bin/sh','-c',$script,'tls-linux-nss',$hostname,$Context.ClientIntent.ContainerName) -DiagnosticOperation CLIENT_NSS
    $facts=Read-TlsLinuxNssFacts $text
    Write-TlsLinuxProof $Context ('client-'+$Phase+'-nss.private.json') @{Status='OBSERVED';Source='GETENT_AHOSTSV4_AI_ADDRCONFIG';
        ActualHostnameEqualsIntent=($hostname -ceq $Context.ClientIntent.ContainerName);HostsReadable=[bool]$facts.HOSTS_READABLE;
        HostsContainActualHostname=[bool]$facts.HOSTS_ACTUAL;HostsContainIntentName=[bool]$facts.HOSTS_INTENT;
        LocalhostExit=$facts.LOCALHOST_EXIT;ActualHostnameExit=$facts.HOSTNAME_EXIT;LookupMaximumSeconds=3;
        Addresses='NOT_RETAINED';OdbcResolverParameters='NOT_OBSERVED';TlsQualification='NOT_CLAIMED'}
    if($hostname -cne $Context.ClientIntent.ContainerName){throw 'TLS_LINUX_CLIENT_HOSTNAME_NOT_APPLIED'}
    if($facts.LOCALHOST_EXIT -ne 0){throw 'TLS_LINUX_CLIENT_LOCALHOST_NSS_UNRESOLVED'}
    if($facts.HOSTNAME_EXIT -ne 0){throw 'TLS_LINUX_CLIENT_HOSTNAME_NSS_UNRESOLVED'}
}

function New-TlsLinuxClientFixture {
    param($Context,[string]$Phase,[string]$Package,[string]$Probe,[string]$CaPem)
    if($Context.ClientIntent){throw 'TLS_LINUX_CLIENT_ALREADY_ACTIVE'}
    $intent=& $Context.Module {
        param($Root,$Run,$Provider,$Name)
        New-LabOwnedHostContainerIntent -StateRoot $Root -RunId $Run.RunId -ScopeId $Run.ScopeId -InstanceId 'tls-linux-client' -Provider $Provider -ContainerName $Name
    } $Context.StateRoot $Context.Run $Context.Provider ('tls-client-'+[guid]::NewGuid().ToString('N'))
    $Context.ClientIntent=$intent
    Write-TlsLinuxProof $Context ('client-'+$Phase+'-intent.private.json') $intent
    $arguments=& $Context.Module {param($Intent,$SqlId,$Image) Get-LabOwnedHostTlsLinuxClientArguments $Intent $SqlId $Image} $intent $Context.SqlId $Context.ClientImage
    $id=Invoke-TlsLinuxNative $Context $arguments
    $receipt=& $Context.Module {param($Root,$Intent,$Id) Register-LabOwnedHostContainer $Root $Intent $Id} $Context.StateRoot $intent $id.Trim()
    $Context.ClientId=$receipt.ContainerId
    Write-TlsLinuxProof $Context ('client-'+$Phase+'-created.private.json') $receipt
    $null=Invoke-TlsLinuxNative $Context @('start',$Context.ClientId)
    $observed=& $Context.Module {param($Root,$Intent,$Id) Get-LabOwnedHostContainerObservation $Root $Intent $Id} $Context.StateRoot $intent $Context.ClientId
    Assert-TlsLinuxClientIsolation $Context $observed
    $fs=Invoke-TlsLinuxNative $Context @('exec',$Context.ClientId,'/usr/bin/stat','-f','-c','%T','/opt/tls-client','/tmp')
    if(($fs -replace "`r",'') -cne "tmpfs`ntmpfs"){throw 'TLS_LINUX_CLIENT_TMPFS_NOT_OBSERVED'}
    if($Context.Provider -ceq 'podman'){
        $kernel=Invoke-TlsLinuxNative $Context @('exec',$Context.ClientId,'/usr/bin/awk','/^(Cap(Inh|Prm|Eff|Bnd|Amb)|NoNewPrivs):/ {print $1 $2}','/proc/1/status')
        Assert-TlsLinuxKernelCapabilities $kernel
        Write-TlsLinuxProof $Context ('client-'+$Phase+'-kernel-isolation.private.json') @{AllFiveCapabilityMasksZero=$true;NoNewPrivileges=$true;Source='OWN_PID1_PROC_STATUS';Observed=$true}
        $owner=Invoke-TlsLinuxNative $Context @('exec',$Context.ClientId,'/usr/bin/stat','-c','%u:%g:%a','/opt/tls-client')
        if($owner -cne '10001:0:700'){throw 'TLS_LINUX_CLIENT_TMPFS_OWNERSHIP_INVALID'}
        Write-TlsLinuxProof $Context ('client-'+$Phase+'-tmpfs-ownership.private.json') @{Uid=10001;Gid=0;Mode='0700';Filesystem='tmpfs';Observed=$true}
        Assert-TlsLinuxClientNameResolution $Context $observed $Phase
    }
    $null=Invoke-TlsLinuxNative $Context @('exec',$Context.ClientId,'/bin/sh','-c','set -eu; umask 077; mkdir /opt/tls-client/pwsh /opt/tls-client/empty')
    $null=Invoke-TlsLinuxNative $Context @('exec','-i',$Context.ClientId,'/bin/tar','-xz','--no-same-owner','-C','/opt/tls-client/pwsh') -InputFile $Package
    $null=Invoke-TlsLinuxNative $Context @('exec','-i',$Context.ClientId,'/bin/sh','-c','set -eu; umask 077; test ! -e /opt/tls-client/probe.ps1; cat > /opt/tls-client/probe.ps1') -InputText ([IO.File]::ReadAllText($Probe))
    $null=Invoke-TlsLinuxNative $Context @('exec','-i',$Context.ClientId,'/bin/sh','-c','set -eu; umask 077; test ! -e /opt/tls-client/ca.pem; cat > /opt/tls-client/ca.pem') -InputText $CaPem
}

function Test-TlsLinuxEmptyCapabilityField {
    param($Observed,[string]$Name)
    $property=$Observed.PSObject.Properties[$Name]
    return $null -ne $property -and ($null -eq $property.Value -or ($property.Value -is [Array] -and $property.Value.Count -eq 0))
}

function Assert-TlsLinuxKernelCapabilities {
    param([string]$Text)
    $expected='CapInh:'+('0'*16)+"`nCapPrm:"+('0'*16)+"`nCapEff:"+('0'*16)+"`nCapBnd:"+('0'*16)+"`nCapAmb:"+('0'*16)+"`nNoNewPrivs:1"
    if(($Text -replace "`r",'') -cne $expected){throw 'TLS_LINUX_KERNEL_ISOLATION_INVALID'}
}

function Assert-TlsLinuxClientIsolation {
    param($Context,$Observed)
    $binds=$Observed.HostConfig.Binds;$ports=$Observed.HostConfig.PortBindings
    $literalAll=@($Observed.HostConfig.CapDrop) -ccontains 'ALL'
    $capabilities=if($Context.Provider -ceq 'podman'){
        (Test-TlsLinuxEmptyCapabilityField $Observed 'EffectiveCaps') -and (Test-TlsLinuxEmptyCapabilityField $Observed 'BoundingCaps')
    }else{$literalAll}
    # Podman derives CapDrop as a difference from its defaults, rather than
    # preserving Docker's literal ALL. Empty OCI sets plus the following actual
    # PID1 kernel check establish the protection; no flag-display fallback.
    $facts=[ordered]@{
        ProviderKnown=($Context.Provider -is [string] -and $Context.Provider -cin @('docker','podman'))
        Running=($Observed.State.Running -is [bool] -and $Observed.State.Running)
        ReadOnlyRoot=($Observed.HostConfig.ReadonlyRootfs -is [bool] -and $Observed.HostConfig.ReadonlyRootfs)
        FixedUser=($Observed.Config.User -ceq '10001:0')
        OwnSqlNamespace=($Observed.HostConfig.NetworkMode -ceq ('container:'+$Context.SqlId))
        NoHostBinds=($null -eq $binds -or @($binds).Count -eq 0)
        NoPorts=($null -eq $ports -or @($ports.PSObject.Properties).Count -eq 0)
        NoCapabilities=[bool]$capabilities
        NoNewPrivileges=(@($Observed.HostConfig.SecurityOpt) -ccontains 'no-new-privileges')
        NotPrivileged=($Observed.HostConfig.Privileged -is [bool] -and -not $Observed.HostConfig.Privileged)
    }
    Write-TlsLinuxProof $Context ('client-isolation-'+$Context.Commands+'.private.json') @{Checks=$facts;LiteralAllCapDrop=$literalAll;Kernel='NOT_YET_OBSERVED'}
    if(@($facts.Values|Where-Object{$_ -ne $true}).Count){throw 'TLS_LINUX_CLIENT_ISOLATION_INVALID'}
}

function Remove-TlsLinuxClientFixture {
    param($Context)
    if(-not $Context.ClientIntent){return}
    Enter-TlsLinuxCommandBudget $Context -Cleanup
    & $Context.Module {param($Root,$Intent) Remove-LabOwnedHostFailedContainer -StateRoot $Root -Intent $Intent} $Context.StateRoot $Context.ClientIntent
    $left=Invoke-TlsLinuxNative $Context @('ps','-aq','--filter',('label=sql-server-lab.owned-host-intent-id='+$Context.ClientIntent.IntentId)) -Cleanup
    if($left){throw 'TLS_LINUX_OWN_CLIENT_REMAINS'}
    $Context.ClientIntent=$null;$Context.ClientId=$null
}

function Remove-TlsLinuxOwnedFixture {
    param($Context)
    Remove-TlsLinuxClientFixture $Context
    if($Context.Run){
        Enter-TlsLinuxCommandBudget $Context -Cleanup
        $cleanup=Remove-SqlServerLab -RunId $Context.Run.RunId -StateRoot $Context.StateRoot -Force -Confirm:$false
        if($cleanup.Status -cne 'REMOVED' -or $cleanup.Errors){throw 'TLS_LINUX_PUBLIC_REMOVE_INCOMPLETE'}
        foreach($vector in @(@('ps','-aq'),@('volume','ls','-q'),@('network','ls','-q'))){
            $left=Invoke-TlsLinuxNative $Context ($vector+@('--filter',('label=sql-server-lab.run-id='+$Context.Run.RunId),'--filter',('label=sql-server-lab.scope-id='+$Context.Run.ScopeId))) -Cleanup
            if($left){throw 'TLS_LINUX_OWN_RESOURCES_REMAIN'}
        }
        $Context.Removed=$true
    }
}
