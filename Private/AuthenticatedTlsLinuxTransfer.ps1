# Bounded stdin transfer to an already owned container. The caller selects a
# fixed operation and verifies the asset/catalogue; no code/path comes from V2.
function Invoke-LabTlsLinuxFileTransfer {
    param(
        [object]$Budget,[string[]]$Arguments,[string]$InputPath,
        [string]$ExpectedSha256,[long]$ExpectedBytes
    )
    if(-not $IsWindows -or $null -eq $Budget -or -not $Budget.StateRoot -or
        $ExpectedSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $ExpectedBytes -lt 1 -or
        $ExpectedBytes -gt 83886080){throw 'TLS_LINUX_TRANSFER_INPUT_INVALID'}
    $recovery=Join-Path $Budget.StateRoot 'tls-linux-process-recovery.json'
    $custody=Get-Variable -Name SqlServerLabTlsLinuxProcessCustody -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if(($null -ne $custody -and $custody.Count) -or (Test-Path -LiteralPath $recovery)){throw 'TLS_LINUX_PROCESS_RECOVERY_REQUIRED'}
    $path=[IO.Path]::GetFullPath($InputPath)
    if($path -cnotmatch '\A[A-Za-z]:[\\/]' -or $path.IndexOf(':',2)-ge0){throw 'TLS_LINUX_TRANSFER_INPUT_INVALID'}
    if([IO.DriveInfo]::new([IO.Path]::GetPathRoot($path)).DriveType-ne[IO.DriveType]::Fixed){throw 'TLS_LINUX_TRANSFER_INPUT_INVALID'}
    $walk=$path
    while($walk){
        if((Test-Path -LiteralPath $walk)-and([IO.File]::GetAttributes($walk)-band[IO.FileAttributes]::ReparsePoint)){throw 'TLS_LINUX_TRANSFER_INPUT_INVALID'}
        $walk=[IO.Path]::GetDirectoryName($walk)
    }
    $null=Get-LabOwnedHostPolicy -StateRoot $Budget.StateRoot -Required
    $source=$null;$process=$null;$start=$null;$started=$false;$completed=$false;$retained=$false
    $write=$null;$tasks=@()
    $outputs=@([IO.MemoryStream]::new(),[IO.MemoryStream]::new())
    try{
        # Deny source write/replacement for the complete hash/copy/readback.
        $source=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if($source.Length-ne$ExpectedBytes){throw 'TLS_LINUX_TRANSFER_SOURCE_CHANGED'}
        $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($source)).ToLowerInvariant()
        if($digest-cne$ExpectedSha256){throw 'TLS_LINUX_TRANSFER_SOURCE_CHANGED'}
        $source.Position=0
        Assert-LabTlsRuntimeBudget $Budget 1
        $start=New-LabTlsRuntimeProcessInfo -Arguments $Arguments -Budget $Budget
        $process=[Diagnostics.Process]::new();$process.StartInfo=$start
        $started=$process.Start()
        $write=$source.CopyToAsync($process.StandardInput.BaseStream)
        $inputClosed=$false
        $pipes=@($process.StandardOutput.BaseStream,$process.StandardError.BaseStream)
        $buffers=@([byte[]]::new(4096),[byte[]]::new(4096));$done=@($false,$false)
        $tasks=@($pipes[0].ReadAsync($buffers[0],0,4096),$pipes[1].ReadAsync($buffers[1],0,4096))
        $timer=[Diagnostics.Stopwatch]::StartNew();$total=0
        while($true){
            if($timer.Elapsed.TotalSeconds-ge90 -or [DateTimeOffset]::UtcNow-ge$Budget.DeadlineUtc){throw 'TLS_LINUX_TRANSFER_TIMEOUT'}
            if(-not$inputClosed-and$write.IsCompleted){
                try{$null=$write.GetAwaiter().GetResult()}catch{throw 'TLS_LINUX_TRANSFER_COMMAND_FAILED'}
                if($source.Position-ne$ExpectedBytes-or$source.Length-ne$ExpectedBytes){throw 'TLS_LINUX_TRANSFER_SOURCE_CHANGED'}
                $process.StandardInput.Close();$inputClosed=$true
            }
            for($i=0;$i-lt2;$i++){
                if(-not$done[$i]-and$tasks[$i].IsCompleted){
                    $count=$tasks[$i].GetAwaiter().GetResult()
                    if($count-eq0){$done[$i]=$true;continue}
                    $total+=$count
                    if($total-gt1048576){throw 'TLS_LINUX_TRANSFER_OUTPUT_LIMIT'}
                    $outputs[$i].Write($buffers[$i],0,$count)
                    $tasks[$i]=$pipes[$i].ReadAsync($buffers[$i],0,4096)
                }
            }
            if($process.HasExited-and$done[0]-and$done[1]-and$inputClosed){
                $completed=$true
                if($process.ExitCode-ne0){throw 'TLS_LINUX_TRANSFER_COMMAND_FAILED'}
                $source.Position=0
                if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($source)).ToLowerInvariant()-cne$ExpectedSha256){throw 'TLS_LINUX_TRANSFER_SOURCE_CHANGED'}
                return [Text.UTF8Encoding]::new($false,$true).GetString($outputs[0].ToArray()).TrimEnd([char[]]@(13,10))
            }
            Start-Sleep -Milliseconds 10
        }
    }finally{
        if($started-and-not$completed){
            try{
                if(-not$process.HasExited){$process.Kill($true)}
                if(-not$process.WaitForExit(5000)){throw 'NOT_TERMINAL'}
                $settle=[Diagnostics.Stopwatch]::StartNew()
                foreach($task in @($write)+@($tasks)){
                    if($null-eq$task){continue}
                    while(-not$task.IsCompleted-and$settle.ElapsedMilliseconds-lt5000){Start-Sleep -Milliseconds 10}
                    if(-not$task.IsCompleted){throw 'IO_NOT_TERMINAL'}
                    # Observe faults caused by closing/killing an interrupted
                    # transfer; they cannot become an unobserved background task.
                    try{$null=$task.GetAwaiter().GetResult()}catch{}
                }
            }catch{
                # Keep live process/stream custody. Never silently dispose an
                # unconfirmed worker and admit another operation on this root.
                $entry=@{Process=$process;Source=$source;Outputs=$outputs;StartInfo=$start;WriteTask=$write;ReadTasks=$tasks;StateRoot=$Budget.StateRoot}
                if($null-eq$custody){$script:SqlServerLabTlsLinuxProcessCustody=[Collections.Generic.List[object]]::new()}
                $script:SqlServerLabTlsLinuxProcessCustody.Add($entry);$retained=$true
                $marker=[pscustomobject]@{ContractVersion='SqlServerLab.LinuxProcessRecovery/0.1';Status='WORKER_TERMINATION_UNCONFIRMED';ProcessId=$process.Id;ProcessStartTicks=$process.StartTime.ToUniversalTime().Ticks;AtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
                Write-LabTlsCaPrivateFile $recovery (Get-LabTlsWindowsProcessFacts).UserSid (ConvertTo-LabTlsRegistryWriterBytes $marker)
                throw 'TLS_LINUX_TERMINATION_UNCONFIRMED'
            }
        }
        if(-not$retained){
            if($source){$source.Dispose()}
            foreach($output in $outputs){$output.Dispose()}
            if($process){$process.Dispose()}
            if($start){$start.ArgumentList.Clear()}
        }
    }
}
