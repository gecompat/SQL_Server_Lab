# Private explicit content channel only; no public/backend activation.
# Ten seconds covers operation polling; bounded cleanup is independent.
# No hard RSS/CPU limit or managed/native-string erasure is attested.
# Preserve the existing local owner on re-dot-source. This state is scoped to
# this script/module instance; it is not a global process/runspace guarantee.
if($null -eq (Get-Variable -Name LabSmtpMimeProcessState -Scope Script -ErrorAction SilentlyContinue)){
    $script:LabSmtpMimeProcessState=[pscustomobject]@{Gate=[object]::new();Active=$false;PendingOwner=$null}
}
function Read-LabSmtpMimeDecodedBytes {
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][AllowEmptyCollection()][object]$Bytes)
    $doc=$null;$text=$null
    try {
        if($Bytes -isnot [byte[]] -or $Bytes.Length -gt 524288){throw 'SMTP_MIME_RESPONSE_INVALID'}
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=8
        $doc=[Text.Json.JsonDocument]::Parse($text,$options)
        $root=$doc.RootElement
        $keys=@('SchemaVersion','Subject','From','To','MissingHeaders','BodyKind','BodyStatus','Body','SelectionRule','PartCount','IgnoredPartCount')
        if($root.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'SMTP_MIME_RESPONSE_INVALID'}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($p in $root.EnumerateObject()){if($p.Name -cnotin $keys -or -not $seen.Add($p.Name)){throw 'SMTP_MIME_RESPONSE_INVALID'}}
        if($seen.Count -ne 11){throw 'SMTP_MIME_RESPONSE_INVALID'}
        $result=[ordered]@{}
        foreach($n in @('SchemaVersion','PartCount','IgnoredPartCount')){
            $p=$root.GetProperty($n);$i=0L
            if($p.ValueKind -ne [Text.Json.JsonValueKind]::Number -or -not $p.TryGetInt64([ref]$i)){throw 'SMTP_MIME_RESPONSE_INVALID'}
            $result[$n]=$i
        }
        if($result.SchemaVersion -ne 1 -or $result.PartCount -lt 1 -or $result.PartCount -gt 64 -or $result.IgnoredPartCount -lt 0 -or $result.IgnoredPartCount -gt $result.PartCount){throw 'SMTP_MIME_RESPONSE_INVALID'}
        foreach($n in @('Subject','From','To','BodyKind','Body')){
            $p=$root.GetProperty($n)
            if($p.ValueKind -eq [Text.Json.JsonValueKind]::Null){$result[$n]=$null}
            elseif($p.ValueKind -eq [Text.Json.JsonValueKind]::String){$result[$n]=$p.GetString()}
            else{throw 'SMTP_MIME_RESPONSE_INVALID'}
        }
        foreach($n in @('Subject','From','To')){if($null -ne $result[$n] -and ([Text.Encoding]::UTF8.GetByteCount($result[$n]) -gt 4096 -or $result[$n].Contains([char]0))){throw 'SMTP_MIME_RESPONSE_INVALID'}}
        foreach($n in @('BodyStatus','SelectionRule')){
            $p=$root.GetProperty($n);if($p.ValueKind -ne [Text.Json.JsonValueKind]::String){throw 'SMTP_MIME_RESPONSE_INVALID'};$result[$n]=$p.GetString()
        }
        $missing=$root.GetProperty('MissingHeaders');$list=[Collections.Generic.List[string]]::new();$seenMissing=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        if($missing.ValueKind -ne [Text.Json.JsonValueKind]::Array -or $missing.GetArrayLength() -gt 3){throw 'SMTP_MIME_RESPONSE_INVALID'}
        foreach($p in $missing.EnumerateArray()){
            if($p.ValueKind -ne [Text.Json.JsonValueKind]::String){throw 'SMTP_MIME_RESPONSE_INVALID'};$n=$p.GetString()
            if($n -cnotin @('Subject','From','To') -or -not $seenMissing.Add($n) -or $null -ne $result[$n]){throw 'SMTP_MIME_RESPONSE_INVALID'};$list.Add($n)
        }
        foreach($n in @('Subject','From','To')){if(($null -eq $result[$n]) -ne $seenMissing.Contains($n)){throw 'SMTP_MIME_RESPONSE_INVALID'}}
        $result.MissingHeaders=$list.ToArray()
        if($result.SelectionRule -cnotin @('NONE','LEAF','RELATED_ROOT','ALTERNATIVE_LAST_PLAIN','ALTERNATIVE_LAST_HTML','MIXED_FIRST_BODY')){throw 'SMTP_MIME_RESPONSE_INVALID'}
        if($null -eq $result.BodyKind){
            if($null -ne $result.Body -or $result.BodyStatus -cnotin @('NO_READABLE_BODY','UNSUPPORTED_MULTIPART') -or $result.SelectionRule -cnotin @('NONE','RELATED_ROOT') -or $result.IgnoredPartCount -ne $result.PartCount){throw 'SMTP_MIME_RESPONSE_INVALID'}
        }else{
            if($result.BodyKind -cnotin @('PLAIN_TEXT','HTML_SOURCE') -or $null -eq $result.Body -or $result.Body.Contains([char]0) -or [Text.Encoding]::UTF8.GetByteCount($result.Body) -gt 262144 -or $result.SelectionRule -ceq 'NONE' -or $result.IgnoredPartCount -ne ($result.PartCount-1)){throw 'SMTP_MIME_RESPONSE_INVALID'}
            $valid=if($result.BodyKind -ceq 'PLAIN_TEXT'){@('TEXT','EMPTY_TEXT')}else{@('HTML_SOURCE','EMPTY_HTML_SOURCE')}
            if($result.BodyStatus -cnotin $valid -or (($result.Body.Length -eq 0) -ne ($result.BodyStatus -cin @('EMPTY_TEXT','EMPTY_HTML_SOURCE')))){throw 'SMTP_MIME_RESPONSE_INVALID'}
            if(($result.SelectionRule -ceq 'ALTERNATIVE_LAST_PLAIN' -and $result.BodyKind -cne 'PLAIN_TEXT') -or ($result.SelectionRule -ceq 'ALTERNATIVE_LAST_HTML' -and $result.BodyKind -cne 'HTML_SOURCE')){throw 'SMTP_MIME_RESPONSE_INVALID'}
        }
        return [pscustomobject]$result
    }catch{throw 'SMTP_MIME_RESPONSE_INVALID'}
    finally{if($doc){$doc.Dispose()};$text=$null}
}

function Complete-LabSmtpMimeProcessCustody {
    param($Process,$InputStream,$InputTask,$ReadPipes,$ReadTasks,$Done,$Scratch,$Streams,$StartInfo)
    $state=[ordered]@{TerminationStatus='NOT_STARTED';InputStatus='NOT_STARTED';PipeDrainStatus='NOT_STARTED';DisposeStatus='NOT_STARTED';OutputPipeDisposeStatus='NOT_STARTED';InputBufferClearAllowed=$true;ScratchBufferClearAllowed=@($true,$true);PendingIO=$false;BufferCustody='QUIESCENT';KillFailed=$false;WaitFailed=$false;InputFailed=$false;DrainFailed=$false;DisposeFailed=$false;PipeDisposeFailed=$false;BufferCleanupFailed=$false;RecoveryRequired=$false;CleanupFailureCode=$null;WaitMaximumMs=5000;DrainMaximumMs=5000}
    if($null -ne $Process){
        $exited=$false;$wait=$false
        # Closing stdin is independent of process kill/wait and output drain.
        if($null -ne $InputStream){try{$InputStream.Dispose()}catch{$state.InputFailed=$true}}
        try{$exited=[bool]$Process.HasExited}catch{$state.WaitFailed=$true}
        if(-not $exited){try{$Process.Kill($true)}catch{$state.KillFailed=$true}}
        try{$wait=[bool]$Process.WaitForExit(5000)}catch{$state.WaitFailed=$true}
        try{$exited=[bool]$Process.HasExited}catch{$state.WaitFailed=$true}
        $state.TerminationStatus=if($wait -and $exited){'CONFIRMED_EXIT'}else{'UNKNOWN'}
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $shape=($ReadPipes.Count -eq 2 -and $ReadTasks.Count -eq 2 -and $Done.Count -eq 2 -and $Scratch.Count -eq 2)
        while($shape -and $state.TerminationStatus -ceq 'CONFIRMED_EXIT' -and $clock.ElapsedMilliseconds -lt 5000){
            for($i=0;$i -lt 2;$i++){
                if($Done[$i]){continue}
                try{if($ReadTasks[$i].IsCompleted){$n=$ReadTasks[$i].GetAwaiter().GetResult();if($n -eq 0){$Done[$i]=$true}else{$ReadTasks[$i]=$ReadPipes[$i].ReadAsync($Scratch[$i],0,4096)}}}catch{$state.DrainFailed=$true;$Done[$i]=$false}
            }
            $inputDone=($null -eq $InputTask -or $InputTask.IsCompleted)
            if(($Done[0] -and $Done[1] -and $inputDone) -or $state.DrainFailed){break}
            Start-Sleep -Milliseconds 10
        }
        # Each actual pipe is closed independently, even if process disposal fails.
        foreach($pipe in @($ReadPipes)){if($null -ne $pipe){try{$pipe.Dispose()}catch{$state.PipeDisposeFailed=$true}}}
        $state.OutputPipeDisposeStatus=if($state.PipeDisposeFailed){'UNKNOWN'}else{'CONFIRMED'}
        # Disposal may finish pending IO. Observe completion only within the same
        # drain budget; completion is not EOF and is not successful input delivery.
        while($clock.ElapsedMilliseconds -lt 5000){
            $pending=($null -ne $InputTask -and -not $InputTask.IsCompleted)
            foreach($task in @($ReadTasks)){if($null -ne $task -and -not $task.IsCompleted){$pending=$true}}
            if(-not $pending){break};Start-Sleep -Milliseconds 10
        }
        $state.InputStatus=if($null -eq $InputTask -or $InputTask.IsCompleted){'CONFIRMED_COMPLETE'}else{'UNKNOWN'}
        $state.PipeDrainStatus=if($shape -and $Done[0] -and $Done[1] -and -not $state.DrainFailed){'CONFIRMED_EOF'}else{'UNKNOWN'}
        try{$Process.Dispose();$state.DisposeStatus='CONFIRMED'}catch{$state.DisposeFailed=$true;$state.DisposeStatus='UNKNOWN'}
    }
    $state.InputBufferClearAllowed=($null -eq $InputTask -or $InputTask.IsCompleted)
    for($i=0;$i -lt 2;$i++){
        $safe=($ReadTasks.Count -le $i -or $null -eq $ReadTasks[$i] -or $ReadTasks[$i].IsCompleted)
        $state.ScratchBufferClearAllowed[$i]=$safe
        if($safe -and $Scratch.Count -gt $i -and $null -ne $Scratch[$i]){try{[Array]::Clear($Scratch[$i],0,$Scratch[$i].Length)}catch{$state.BufferCleanupFailed=$true}}
    }
    $state.PendingIO=(-not $state.InputBufferClearAllowed -or -not $state.ScratchBufferClearAllowed[0] -or -not $state.ScratchBufferClearAllowed[1])
    if($state.PendingIO){$state.BufferCustody='UNKNOWN'}
    foreach($stream in @($Streams)){
        if($null -eq $stream){continue}
        try{[ArraySegment[byte]]$segment=[Activator]::CreateInstance([ArraySegment[byte]]);if($stream.TryGetBuffer([ref]$segment)){[Array]::Clear($segment.Array,0,$segment.Array.Length)}}catch{$state.BufferCleanupFailed=$true}
        try{$stream.Dispose()}catch{$state.BufferCleanupFailed=$true}
    }
    if($null -ne $StartInfo){try{$StartInfo.ArgumentList.Clear();$StartInfo.Environment.Clear()}catch{$state.BufferCleanupFailed=$true}}
    if($null -ne $Process -and ($state.TerminationStatus -cne 'CONFIRMED_EXIT' -or $state.InputStatus -cne 'CONFIRMED_COMPLETE' -or $state.PipeDrainStatus -cne 'CONFIRMED_EOF')){$state.CleanupFailureCode='SMTP_MIME_PROCESS_TERMINATION_UNKNOWN'}
    elseif($state.KillFailed -or $state.WaitFailed -or $state.InputFailed -or $state.DisposeFailed -or $state.PipeDisposeFailed -or $state.BufferCleanupFailed){$state.CleanupFailureCode='SMTP_MIME_PROCESS_CLEANUP_FAILED'}
    $state.RecoveryRequired=($null -ne $state.CleanupFailureCode)
    return [pscustomobject]$state
}

function Invoke-LabSmtpMimeByteProcess {
    # Internal transport. Only the fixed production entry below is a content reader.
    # Focal fixtures may call this private primitive with their own fixed child.
    param([Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo,[Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$OwnedInput,
        [Parameter(Mandatory)][ValidateRange(1,8388608)][int]$OutputLimit)
    $process=$null;$inputStream=$null;$write=$null;$pipes=@();$tasks=@();$done=@($false,$false);$scratch=@();$streams=@();$copies=@();$failure=$null;$answer=$null;$custody=$null;$entered=$false;$claimed=$false
    $clock=[Diagnostics.Stopwatch]::StartNew()
    try{
        $entered=[Threading.Monitor]::TryEnter($script:LabSmtpMimeProcessState.Gate,0)
        if(-not $entered -or $script:LabSmtpMimeProcessState.Active){throw 'SMTP_MIME_PROCESS_BUSY'}
        $script:LabSmtpMimeProcessState.Active=$true;$claimed=$true
        if($null -ne $script:LabSmtpMimeProcessState.PendingOwner){throw 'SMTP_MIME_PROCESS_RECOVERY_REQUIRED'}
        if($StartInfo.UseShellExecute -or -not $StartInfo.RedirectStandardInput -or -not $StartInfo.RedirectStandardOutput -or -not $StartInfo.RedirectStandardError){throw 'SMTP_MIME_PROCESS_INVALID'}
        $streams=@([IO.MemoryStream]::new(),[IO.MemoryStream]::new());$scratch=@([byte[]]::new(4096),[byte[]]::new(4096))
        $process=[Diagnostics.Process]::Start($StartInfo)
        $pipes=@($process.StandardOutput.BaseStream,$process.StandardError.BaseStream)
        # Retain each returned Task immediately if the second allocation fails.
        $tasks=@($null,$null)
        for($i=0;$i -lt 2;$i++){$tasks[$i]=$pipes[$i].ReadAsync($scratch[$i],0,4096)}
        $inputStream=$process.StandardInput.BaseStream;$write=$inputStream.WriteAsync($OwnedInput,0,$OwnedInput.Length);$inputClosed=$false
        while($true){
            if($clock.ElapsedMilliseconds -ge 10000){throw 'SMTP_MIME_PROCESS_TIMEOUT'}
            if(-not $inputClosed -and $write.IsCompleted){$null=$write.GetAwaiter().GetResult();$inputStream.Dispose();$inputClosed=$true}
            for($i=0;$i -lt 2;$i++){
                if(-not $done[$i] -and $tasks[$i].IsCompleted){
                    $n=$tasks[$i].GetAwaiter().GetResult();if($n -eq 0){$done[$i]=$true;continue}
                    $limit=if($i -eq 0){$OutputLimit}else{256}
                    if($streams[$i].Length+$n -gt $limit){throw 'SMTP_MIME_PROCESS_OUTPUT_LIMIT'}
                    $streams[$i].Write($scratch[$i],0,$n);$tasks[$i]=$pipes[$i].ReadAsync($scratch[$i],0,4096)
                }
            }
            if($process.HasExited -and $done[0] -and $done[1] -and $inputClosed){break}
            Start-Sleep -Milliseconds 10
        }
        $copies=@($streams[0].ToArray(),$streams[1].ToArray())
        if($process.ExitCode -ne 0){
            if($copies[0].Length -ne 0){throw 'SMTP_MIME_PROCESS_FAILED'}
            $err=[Text.UTF8Encoding]::new($false,$true).GetString($copies[1]);$allowed=@('SMTP_MIME_INPUT_INVALID','SMTP_MIME_LIMIT_EXCEEDED','SMTP_MIME_INVALID','SMTP_MIME_INVALID_ENCODING','SMTP_MIME_UNSUPPORTED_CHARSET','SMTP_MIME_UNSUPPORTED_ENCODING','SMTP_MIME_UNSUPPORTED_ADDRESS','SMTP_MIME_PARSE_FAILED','SMTP_MIME_TIMEOUT')
            $matched=$null;foreach($code in $allowed){if([string]::Equals($err,($code+"`n"),[StringComparison]::Ordinal) -or [string]::Equals($err,($code+"`r`n"),[StringComparison]::Ordinal)){$matched=$code;break}};$err=$null
            if($null -eq $matched){throw 'SMTP_MIME_PROCESS_FAILED'};throw $matched
        }
        if($copies[1].Length -ne 0){throw 'SMTP_MIME_PROCESS_FAILED'}
        # This owned copy is released only after the genuine finally confirms custody.
        $answer=$copies[0];$copies[0]=$null
    }catch{
        $allowed=@('SMTP_MIME_PROCESS_BUSY','SMTP_MIME_PROCESS_RECOVERY_REQUIRED','SMTP_MIME_PROCESS_INVALID','SMTP_MIME_PROCESS_TIMEOUT','SMTP_MIME_PROCESS_OUTPUT_LIMIT','SMTP_MIME_PROCESS_FAILED','SMTP_MIME_INPUT_INVALID','SMTP_MIME_LIMIT_EXCEEDED','SMTP_MIME_INVALID','SMTP_MIME_INVALID_ENCODING','SMTP_MIME_UNSUPPORTED_CHARSET','SMTP_MIME_UNSUPPORTED_ENCODING','SMTP_MIME_UNSUPPORTED_ADDRESS','SMTP_MIME_PARSE_FAILED','SMTP_MIME_TIMEOUT')
        $failure=if($_.Exception.Message -cin $allowed){$_.Exception.Message}else{'SMTP_MIME_PROCESS_FAILED'}
    }finally{
        try{
        try{$custody=Complete-LabSmtpMimeProcessCustody $process $inputStream $write $pipes $tasks $done $scratch $streams $StartInfo}catch{$custody=[pscustomobject]@{TerminationStatus='UNKNOWN';InputStatus='UNKNOWN';PipeDrainStatus='UNKNOWN';DisposeStatus='UNKNOWN';InputBufferClearAllowed=$false;PendingIO=$true;BufferCustody='UNKNOWN';RecoveryRequired=$true;CleanupFailureCode='SMTP_MIME_PROCESS_CLEANUP_FAILED'}}
        foreach($copy in $copies){if($null -ne $copy){[Array]::Clear($copy,0,$copy.Length)}}
        try{Protect-LabSmtpMimePendingBuffers $custody $OwnedInput $scratch $tasks $write $pipes $inputStream $process $streams}catch{$custody.RecoveryRequired=$true;$custody.CleanupFailureCode='SMTP_MIME_PROCESS_CLEANUP_FAILED'}
        if($null -ne $failure -or $null -eq $custody -or $custody.RecoveryRequired){if($null -ne $answer){[Array]::Clear($answer,0,$answer.Length);$answer=$null}}
        }finally{if($claimed){$script:LabSmtpMimeProcessState.Active=$false};if($entered){[Threading.Monitor]::Exit($script:LabSmtpMimeProcessState.Gate)}}
    }
    if($null -ne $failure -or $custody.RecoveryRequired){
        $code=if($null -ne $failure){$failure}else{$custody.CleanupFailureCode};$exception=[InvalidOperationException]::new($code)
        $exception.Data['SqlServerLab.SmtpMimeCustody']=$custody;throw $exception
    }
    return ,$answer
}

function Protect-LabSmtpMimePendingBuffers {
    param($Custody,[AllowEmptyCollection()][byte[]]$OwnedInput,$Scratch,$Tasks,$InputTask,$Pipes,$InputStream,$Process,$Streams)
    if($Custody.InputBufferClearAllowed){[Array]::Clear($OwnedInput,0,$OwnedInput.Length)}
    if($Custody.PendingIO){
        if(-not [Threading.Monitor]::IsEntered($script:LabSmtpMimeProcessState.Gate) -or $null -ne $script:LabSmtpMimeProcessState.PendingOwner){throw 'SMTP_MIME_PROCESS_CLEANUP_FAILED'}
        # At most one RAM-only owning recovery capsule under the admission lock.
        # No references enter Data/output; no automatic reaper/retry is installed.
        $script:LabSmtpMimeProcessState.PendingOwner=[pscustomobject]@{Input=$OwnedInput;Scratch=$Scratch;Tasks=$Tasks;InputTask=$InputTask;Pipes=$Pipes;InputStream=$InputStream;Process=$Process;Streams=$Streams}
    }
}

function Invoke-LabSmtpTestServiceMimeProjection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][AllowEmptyCollection()][object]$Format,[Parameter(Mandatory)][AllowNull()][AllowEmptyString()][AllowEmptyCollection()][object]$InputBytes)
    # Actual types precede resolution/start, preventing PowerShell coercion.
    if($Format -isnot [string] -or $Format -cnotin @('Decoded','Mime')){throw 'SMTP_MIME_INPUT_INVALID'}
    $limit=if($Format -ceq 'Decoded'){1048576}else{8388608}
    if($InputBytes -isnot [byte[]]){throw 'SMTP_MIME_INPUT_INVALID'}
    if($InputBytes.Length -gt $limit){throw 'SMTP_MIME_LIMIT_EXCEEDED'}
    if($null -ne $script:LabSmtpMimeProcessState.PendingOwner){throw 'SMTP_MIME_PROCESS_RECOVERY_REQUIRED'}
    $owned=[byte[]]$InputBytes.Clone();$output=$null;$result=$null
    try{
        $repo=Split-Path -Parent $PSScriptRoot
        $resolution=@(& (Join-Path $repo 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name python)
        if($resolution.Count -ne 1 -or $resolution[0].Available -isnot [bool] -or -not $resolution[0].Available -or $resolution[0].Invocation -isnot [string] -or -not [IO.Path]::IsPathRooted($resolution[0].Invocation)){throw 'SMTP_MIME_RUNTIME_UNAVAILABLE'}
        $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$resolution[0].Invocation;$start.WorkingDirectory=$repo;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.Environment.Clear()
        foreach($n in @('SystemRoot','WINDIR','ComSpec')){$value=[Environment]::GetEnvironmentVariable($n);if($null -ne $value){$start.Environment[$n]=$value}}
        foreach($arg in @('-I','-B',(Join-Path $repo 'Tools/SmtpTestServiceMime.py'),$Format)){$start.ArgumentList.Add($arg)}
        $outputLimit=if($Format -ceq 'Decoded'){524288}else{8388608}
        $output=Invoke-LabSmtpMimeByteProcess $start $owned $outputLimit
        if($Format -ceq 'Decoded'){$result=Read-LabSmtpMimeDecodedBytes $output}else{$result=$output;$output=$null}
    }catch{
        $allowed=@('SMTP_MIME_PROCESS_BUSY','SMTP_MIME_PROCESS_RECOVERY_REQUIRED','SMTP_MIME_RUNTIME_UNAVAILABLE','SMTP_MIME_RESPONSE_INVALID','SMTP_MIME_PROCESS_INVALID','SMTP_MIME_PROCESS_TIMEOUT','SMTP_MIME_PROCESS_OUTPUT_LIMIT','SMTP_MIME_PROCESS_FAILED','SMTP_MIME_PROCESS_TERMINATION_UNKNOWN','SMTP_MIME_PROCESS_CLEANUP_FAILED','SMTP_MIME_INPUT_INVALID','SMTP_MIME_LIMIT_EXCEEDED','SMTP_MIME_INVALID','SMTP_MIME_INVALID_ENCODING','SMTP_MIME_UNSUPPORTED_CHARSET','SMTP_MIME_UNSUPPORTED_ENCODING','SMTP_MIME_UNSUPPORTED_ADDRESS','SMTP_MIME_PARSE_FAILED','SMTP_MIME_TIMEOUT')
        $code=if($_.Exception.Message -cin $allowed){$_.Exception.Message}else{'SMTP_MIME_RUNTIME_UNAVAILABLE'}
        $fixed=[InvalidOperationException]::new($code)
        if($_.Exception.Data.Contains('SqlServerLab.SmtpMimeCustody')){$fixed.Data['SqlServerLab.SmtpMimeCustody']=$_.Exception.Data['SqlServerLab.SmtpMimeCustody']}
        throw $fixed
    }finally{
        $held=$script:LabSmtpMimeProcessState.PendingOwner
        if($null -eq $held -or -not [object]::ReferenceEquals($held.Input,$owned)){[Array]::Clear($owned,0,$owned.Length)}
        if($null -ne $output){[Array]::Clear($output,0,$output.Length)}
    }
    if($Format -ceq 'Mime'){return ,$result}
    return $result
}
