function Invoke-LabTlsLinuxConsumerBridge {
    param([byte[]]$ExportBytes,[string]$StateRoot,[string]$RunId,[string]$InstanceId,[string]$ToolbeltRoot)
    $bound=Get-LabTlsOwnBinding $StateRoot $RunId $InstanceId
    if($bound.Record.ContractVersion-cne'SqlServerLab.AuthenticatedTlsLab/0.4'){throw 'TLS_LINUX_EXPLICIT_SELECTION_REQUIRED'}
    $budget=New-LabTlsRuntimeBudget -Provider $bound.Record.Provider -StateRoot $StateRoot -Record $bound.Record
    $initial=Read-LabTlsQualifiedExportSnapshot -ExportBytes $ExportBytes -FromBytes -StateRoot $StateRoot -RunId $RunId -InstanceId $InstanceId -Budget $budget -AllowLinuxController
    if($null-eq$initial-or$initial-is[bool]){throw 'TLS_LINUX_EXPORT_REJECTED'}
    $client=Get-LabTlsLinuxClientBinding $bound $budget
    $sourceSet=Get-LabTlsLinuxConsumerSourceSet $ToolbeltRoot
    $lease=$null;$session=$null;$process=$null;$start=$null;$started=$false;$confirmed=$false;$success=$false;$retained=$false
    $directory='/opt/tls-client/session-'+[guid]::NewGuid().ToString('N')
    $marker=Join-Path $StateRoot 'linux-client-execution.json'
    $tasks=@();$outputs=@([IO.MemoryStream]::new(),[IO.MemoryStream]::new());$copy=[byte[]]$ExportBytes.Clone();$cleanupError=$null
    try{
        $lease=Enter-LabTlsLinuxOperation $StateRoot
        Assert-LabTlsLinuxGuestIdle $client.Record.Client.ContainerId $budget
        Initialize-LabTlsLinuxConsumerFiles $bound $budget $client $sourceSet $directory
        # Start the short session after staging, from a fresh public snapshot.
        $reader=$ExecutionContext.SessionState.Module.ExportedCommands['Read-SqlServerLabQualifiedTestEnvironment']
        $initial=Read-LabTlsQualifiedExportSnapshot -ExportBytes $copy -FromBytes -StateRoot $StateRoot -RunId $RunId -InstanceId $InstanceId -Budget $budget -AllowLinuxController
        $expiry=[DateTimeOffset]::ParseExact($initial.Qualification.ExpiresAt,'o',[Globalization.CultureInfo]::InvariantCulture)
        $sessionEnd=[DateTimeOffset]::UtcNow.AddMinutes(2)
        if($sessionEnd-gt$expiry.AddSeconds(-35)){$sessionEnd=$expiry.AddSeconds(-35)}
        $live=@{Root=$lease.Root;ProcessId=$PID;State='OPEN';InVerifier=$false;GuestPid=0;RunId=$RunId;InstanceId=$InstanceId;CurrentStack=$null;Session=$null}
        $verify={
            param($Bytes,$Stack,$ClientRef,$ContextDigest)
            $null=$ClientRef;$null=$ContextDigest
            $live.CurrentStack=$Stack
            try{& $reader -ExportBytes $Bytes -StateRoot $StateRoot -RunId $RunId -InstanceId $InstanceId -LinuxSessionRef $live.Session.SessionRef -LinuxClientStack $Stack}
            finally{$live.CurrentStack=$null}
        }.GetNewClosure()
        $session=New-LabTlsLinuxConsumerSession $copy $client.Record.ClientRef $client.Sha256 $sessionEnd $verify {[DateTimeOffset]::UtcNow} -QualificationExpiresAt $expiry
        $live.Session=$session
        $script:SqlServerLabTlsLinuxLiveBridge=$live
        $execution=@{ContractVersion='SqlServerLab.LinuxExecution/0.1';Status='EXECUTION_PENDING';ClientContainerId=$client.Record.Client.ContainerId;RunId=$RunId;OperationId=$session.SessionRef}
        Write-LabTlsCaPrivateFile $marker $lease.Sid (ConvertTo-LabTlsRegistryWriterBytes $execution)
        $arguments=Get-LabTlsLinuxExecArguments $client.Record.Client.ContainerId @('/opt/tls-client/pwsh/pwsh','-NoProfile','-NonInteractive','-File',($directory+'/entry.ps1')) -InputStream
        Assert-LabTlsRuntimeBudget $budget 1
        $start=New-LabTlsRuntimeProcessInfo $arguments $budget
        $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$started=$process.Start()
        $pipes=@($process.StandardOutput.BaseStream,$process.StandardError.BaseStream);$buffers=@([byte[]]::new(4096),[byte[]]::new(4096));$done=@($false,$false)
        $tasks=@($pipes[0].ReadAsync($buffers[0],0,4096),$pipes[1].ReadAsync($buffers[1],0,4096))
        $boot=@{SessionRef=$session.SessionRef;ExportBase64=[Convert]::ToBase64String($copy);ExportSha256=$session.ExportSha256
            ClientRef=$session.ClientRef;ContextDigest=$session.ContextDigest;StateRoot=$StateRoot;RunId=$RunId;InstanceId=$InstanceId
            ExpiresAt=$session.ExpiresAt.ToString('o');MaximumMilliseconds=[long]$session.MaximumElapsed.TotalMilliseconds}
        $line=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($boot|ConvertTo-Json -Compress)))+[char]10
        $write=$process.StandardInput.WriteAsync($line)
        if(-not$write.Wait(5000)){throw 'TLS_LINUX_BRIDGE_INPUT_TIMEOUT'};$null=$write.GetAwaiter().GetResult();$line=$null;$boot=$null
        $clock=[Diagnostics.Stopwatch]::StartNew();$total=0;$pending='';$hello=$false;$result=$null
        while($true){
            if($clock.Elapsed.TotalSeconds-ge120-or[DateTimeOffset]::UtcNow-ge$session.ExpiresAt){throw 'TLS_LINUX_BRIDGE_TIMEOUT'}
            for($i=0;$i-lt2;$i++){
                if($done[$i]-or-not$tasks[$i].IsCompleted){continue}
                $count=$tasks[$i].GetAwaiter().GetResult()
                if($count-eq0){$done[$i]=$true;continue}
                $total+=$count;if($total-gt1048576){throw 'TLS_LINUX_BRIDGE_OUTPUT_LIMIT'}
                if($i-eq1){$outputs[1].Write($buffers[$i],0,$count)}
                else{
                    for($n=0;$n-lt$count;$n++){if($buffers[0][$n]-gt127){throw 'TLS_LINUX_BRIDGE_PROTOCOL'}}
                    $pending+=[Text.Encoding]::ASCII.GetString($buffers[0],0,$count)
                    if($pending.Length-gt8192){throw 'TLS_LINUX_BRIDGE_PROTOCOL'}
                    while(($offset=$pending.IndexOf([char]10))-ge0){
                        $row=$pending.Substring(0,$offset).TrimEnd([char]13);$pending=$pending.Substring($offset+1)
                        if($row.StartsWith('HELLO ',[StringComparison]::Ordinal)-and-not$hello-and$null-eq$result){
                            $h=Read-LabTlsBoundJson ([Convert]::FromBase64String($row.Substring(6))) @('ContractVersion','SessionRef','ProcessId')
                            if($h.ContractVersion-isnot[string]-or$h.ContractVersion-cne'SqlServerLab.LinuxPeerHello/0.1'-or
                                $h.SessionRef-isnot[string]-or$h.SessionRef-cne$session.SessionRef-or
                                ($h.ProcessId-isnot[int]-and$h.ProcessId-isnot[long])-or$h.ProcessId-lt2-or$h.ProcessId-gt[int]::MaxValue){throw 'TLS_LINUX_BRIDGE_PROTOCOL'}
                            $live.GuestPid=[int]$h.ProcessId;$hello=$true
                        }elseif($row.StartsWith('VERIFY ',[StringComparison]::Ordinal)-and$hello-and$null-eq$result){
                            $live.InVerifier=$true
                            try{$reply=Invoke-LabTlsLinuxSessionVerification $session ([Convert]::FromBase64String($row.Substring(7)))}
                            finally{$live.InVerifier=$false}
                            $answer='REPLY '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($reply|ConvertTo-Json -Compress)))+[char]10
                            $write=$process.StandardInput.WriteAsync($answer)
                            if(-not$write.Wait(5000)){throw 'TLS_LINUX_BRIDGE_INPUT_TIMEOUT'};$null=$write.GetAwaiter().GetResult()
                        }elseif($row.StartsWith('RESULT ',[StringComparison]::Ordinal)-and$hello-and$null-eq$result-and$session.Requests-eq2){
                            $result=Read-LabTlsBoundJson ([Convert]::FromBase64String($row.Substring(7))) @('ContractVersion','Status','ClientChecks','SqlBuild','SqlClient','Odbc','Encrypt','TrustServerCertificate')
                            $expected=[pscustomobject]@{ContractVersion='Toolbelt.LinuxLabPreflight/0.1';Status='PASS';ClientChecks=2;SqlBuild=$initial.Qualification.SqlBuild;SqlClient='PASS';Odbc='PASS';Encrypt=$true;TrustServerCertificate=$false}
                            Assert-LabTlsLinuxObservedFields $expected $result
                        }else{throw 'TLS_LINUX_BRIDGE_PROTOCOL'}
                    }
                }
                $tasks[$i]=$pipes[$i].ReadAsync($buffers[$i],0,4096)
            }
            if($process.HasExited-and$done[0]-and$done[1]){
                $confirmed=$true
                if($process.ExitCode-ne0-or$null-eq$result-or$pending.Length-or$outputs[1].Length){throw 'TLS_LINUX_CONSUMER_FAILED'}
                break
            }
            Start-Sleep -Milliseconds 10
        }
        # CLI success alone is insufficient: confirm no guest/SQL client remains.
        $live.State='CLOSED'
        Assert-LabTlsLinuxGuestIdle $client.Record.Client.ContainerId $budget
        foreach($entry in $sourceSet){
            $entry.Stream.Position=0
            if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($entry.Stream)).ToLowerInvariant()-cne$entry.Sha256){throw 'TLS_LINUX_SOURCE_CHANGED'}
        }
        Remove-Item -LiteralPath $marker -Force -ErrorAction Stop
        $success=$true
        return [pscustomobject]@{ContractVersion='SqlServerLab.LinuxConsumerResult/0.1';Status='PASS';ClientChecks=2;Provider=$bound.Record.Provider;SqlVersion=$initial.Qualification.SqlVersion;Patch=$initial.Qualification.Patch;SqlBuild=$initial.Qualification.SqlBuild;Consumer='TOOLBELT_READONLY_PREFLIGHT';WireCertificateFingerprint='NOT_OBSERVED'}
    }finally{
        if($script:SqlServerLabTlsLinuxLiveBridge){$script:SqlServerLabTlsLinuxLiveBridge.State='CLOSED'}
        if($started-and-not$confirmed){
            try{if(-not$process.HasExited){$process.Kill($true)};$confirmed=$process.WaitForExit(5000)}catch{$confirmed=$false}
        }
        if($confirmed){
            $settle=[Diagnostics.Stopwatch]::StartNew()
            foreach($task in @($write)+@($tasks)){
                if($null-eq$task){continue}
                while(-not$task.IsCompleted-and$settle.ElapsedMilliseconds-lt5000){Start-Sleep -Milliseconds 10}
                if(-not$task.IsCompleted){$confirmed=$false;break}
                try{$null=$task.GetAwaiter().GetResult()}catch{}
            }
        }
        if(-not$success-and(-not$started-or$confirmed)){
            # One canonical reconciliation terminates all descendants in this
            # exact private PID namespace, even after an interrupted exec.
            try{Remove-LabTlsLinuxClientIfPresent -StateRoot $StateRoot -RunId $RunId}catch{$cleanupError=$_}
        }
        if($started-and-not$confirmed){
            $script:SqlServerLabTlsLinuxBridgeCustody=@{Process=$process;SourceSet=$sourceSet;Pipes=$pipes;Tasks=$tasks;Outputs=$outputs;Lease=$lease;Session=$session;ExportBytes=$copy}
            $retained=$true
        }
        if(-not$retained){
            if($session){Close-LabTlsLinuxConsumerSession $session}
            foreach($entry in $sourceSet){$entry.Stream.Dispose()}
            foreach($output in $outputs){$output.Dispose()}
            if($process){$process.Dispose()}
            if($start){$start.ArgumentList.Clear()}
            if($lease){Exit-LabTlsLinuxOperation $lease}
            $script:SqlServerLabTlsLinuxLiveBridge=$null
            [Array]::Clear($copy,0,$copy.Length)
        }
        if($retained){throw 'TLS_LINUX_BRIDGE_TERMINATION_UNCONFIRMED'}
        if($cleanupError){throw 'TLS_LINUX_CLIENT_CLEANUP_RECOVERY_REQUIRED'}
    }
}
