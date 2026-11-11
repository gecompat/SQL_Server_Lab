function Enter-LabTlsLinuxOperation {
    param([string]$StateRoot,[switch]$Cleanup)
    $sid=(Get-LabTlsWindowsProcessFacts).UserSid
    $root=[IO.Path]::GetFullPath($StateRoot)
    $null=Get-LabOwnedHostPolicy -StateRoot $root -Required
    $name='Global\SqlServerLabTlsLinux_'+(Get-LabTlsCaByteDigest ([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant())))
    $mutex=[Threading.Mutex]::new($false,$name);$held=$false
    try{
        try{$held=$mutex.WaitOne(3000)}catch [Threading.AbandonedMutexException]{
            $held=$true
            $marker=Join-Path $root 'linux-client-execution.json'
            if(-not(Test-Path -LiteralPath $marker)){
                Write-LabTlsCaPrivateFile $marker $sid (ConvertTo-LabTlsRegistryWriterBytes @{Status='ABANDONED_CUSTODY';AtUtc=[DateTimeOffset]::UtcNow.ToString('o')})
            }
            if(-not$Cleanup){throw 'TLS_LINUX_RECOVERY_REQUIRED'}
        }
        if(-not$held){throw 'TLS_LINUX_OPERATION_BUSY'}
        $nested=$false
        if(-not$Cleanup-and(Test-Path -LiteralPath (Join-Path $root 'linux-client-execution.json'))){
            $live=Get-Variable -Name SqlServerLabTlsLinuxLiveBridge -Scope Script -ValueOnly -ErrorAction SilentlyContinue
            $nested=$null-ne$live-and$live.State-ceq'OPEN'-and$live.InVerifier-eq$true-and$live.Root-ceq$root-and$live.ProcessId-eq$PID
            if(-not$nested){throw 'TLS_LINUX_RECOVERY_REQUIRED'}
        }
        return @{Mutex=$mutex;Root=$root;Sid=$sid;Held=$true;Nested=$nested}
    }catch{if($held){$mutex.ReleaseMutex()};$mutex.Dispose();throw}
}

function Exit-LabTlsLinuxOperation {
    param([object]$Lease)
    if($Lease.Held){$Lease.Mutex.ReleaseMutex();$Lease.Held=$false}
    $Lease.Mutex.Dispose()
}

function Assert-LabTlsLinuxControllerSession {
    param([string]$StateRoot,[string]$RunId,[string]$InstanceId,[byte[]]$ExportBytes,[string]$SessionRef,[string]$Stack)
    $live=Get-Variable -Name SqlServerLabTlsLinuxLiveBridge -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if($null-eq$live-or$live.State-cne'OPEN'-or$live.InVerifier-isnot[bool]-or-not$live.InVerifier-or
        $live.ProcessId-ne$PID-or$live.Root-cne[IO.Path]::GetFullPath($StateRoot)-or$live.RunId-cne$RunId-or$live.InstanceId-cne$InstanceId-or
        $null-eq$live.Session-or$live.Session.State-cne'OPEN'-or$live.Session.InFlight-isnot[bool]-or-not$live.Session.InFlight-or
        $live.Session.SessionRef-cne$SessionRef-or$live.CurrentStack-cne$Stack-or
        $live.Session.Lifetime.Elapsed-ge$live.Session.MaximumElapsed-or$null-eq$ExportBytes-or
        (Get-LabTlsCaByteDigest $ExportBytes)-cne$live.Session.ExportSha256){throw 'TLS_LINUX_CONTROLLER_SESSION_REQUIRED'}
}

function Assert-LabTlsLinuxGuestIdle {
    param([string]$ContainerId,[object]$Budget,[int]$AllowedPeerPid=0)
    # Own private PID namespace: only PID1 and this exact shell may remain.
    # Builtins do not create a ps/cat process that could hide another child.
    if($AllowedPeerPid-lt0){throw 'TLS_LINUX_GUEST_TERMINATION_UNCONFIRMED'}
    $program='set -eu; for p in /proc/[0-9]*; do n=${p##*/}; if [ "$n" != 1 ] && [ "$n" != "$$" ] && [ "$n" != PEER_PID ]; then exit 42; fi; done; printf IDLE'
    $program=$program.Replace('PEER_PID',[string]$AllowedPeerPid)
    if((Invoke-LabTlsContainer @('exec','--user','10001:0',$ContainerId,'/bin/sh','-c',$program) -Budget $Budget)-cne'IDLE'){throw 'TLS_LINUX_GUEST_TERMINATION_UNCONFIRMED'}
}

function Get-LabTlsLinuxObservedOperationStage {
    param([string]$Program)
    if($Program -ceq (Get-LabTlsLinuxObservationProgram)){return 'linux-client-observation'}
    if($Program -ceq (Get-LabTlsLinuxQualificationProgram)){return 'linux-client-qualification'}
    return 'unspecified'
}

function Get-LabTlsSafePublicLinuxFailureCode {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    $exception=$ErrorRecord.Exception
    # These exact codes can originate at the Windows CA/export binding,
    # Linux-client bootstrap, observer, or SQL qualification boundaries. They
    # are fixed producer tokens; never expose arbitrary host/guest exception
    # text through the public preflight wrapper.
    $safePublicTokens=@(
        'TLS_CA_STORAGE_INVALID','TLS_CA_ACL_INVALID','TLS_CA_FILE_INVALID',
        'TLS_CA_METADATA_INVALID','TLS_CA_CERTIFICATE_INVALID','TLS_CA_KEY_INVALID',
        'TLS_CA_BINDING_DRIFT','TLS_CA_CANDIDATE_BINDING_INVALID',
        'TLS_QUALIFICATION_SQLCLIENT_RESULT_INVALID','TLS_QUALIFICATION_SQLCLIENT_FAILED',
        'TLS_QUALIFICATION_SQLCMD_CHANGED','TLS_QUALIFICATION_SQLCMD_TIMEOUT',
        'TLS_QUALIFICATION_SQLCMD_FAILED','TLS_QUALIFICATION_BINARY_CHANGED',
        'TLS_QUALIFICATION_BINDING_CHANGED','TLS_QUALIFICATION_SECRET_UNAVAILABLE',
        'TLS_EXPORT_EXPLICIT_SELECTION_REQUIRED','TLS_EXPORT_BYTES_INVALID',
        'TLS_EXPORT_READBACK_INVALID','TLS_EXPORT_BINDING_CHANGED',
        'TLS_LINUX_EXPLICIT_SELECTION_REQUIRED','TLS_LINUX_EXPORT_REJECTED',
        'TLS_LINUX_CLIENT_INTENT_CHANGED','TLS_LINUX_CLIENT_ISOLATION_CHANGED',
        'TLS_LINUX_NAMESPACE_OR_TRUST_CHANGED','TLS_LINUX_CLIENT_ALREADY_ALLOCATED',
        'TLS_LINUX_STOCK_CLIENT_IMAGE_REQUIRED','TLS_LINUX_PARENT_CHANGED',
        'TLS_LINUX_CLIENT_CHANGED','TLS_LINUX_CONTEXT_CHANGED',
        'TLS_LINUX_MISSING_INTENT_RECOVERY_REQUIRED','TLS_LINUX_CLEANUP_BINDING_INVALID',
        'TLS_LINUX_CLEANUP_RECOVERY_REQUIRED','TLS_LINUX_RECOVERY_REQUIRED',
        'TLS_LINUX_OPERATION_BUSY','TLS_LINUX_CONTROLLER_SESSION_REQUIRED',
        'TLS_LINUX_SOURCE_SCOPE_INVALID','TLS_LINUX_SOURCE_LIMIT',
        'TLS_LINUX_SOURCE_COPY_CHANGED','TLS_LINUX_BOOTSTRAP_LIMIT',
        'TLS_LINUX_SESSION_INVALID','TLS_LINUX_SESSION_REJECTED',
        'TLS_LINUX_CLIENT_BINDING_INVALID','TLS_LINUX_CONTEXT_RECORD_INVALID',
        'TLS_LINUX_EXPORT_BINDING_INVALID','TLS_LINUX_PEER_REJECTED',
        'TLS_LINUX_PINNED_PACKAGE_INVALID','TLS_LINUX_PINNED_PACKAGE_REQUIRED',
        'TLS_LINUX_PROCESS_RECOVERY_REQUIRED','TLS_LINUX_QUALIFICATION_BINDING_CHANGED',
        'TLS_LINUX_TERMINATION_UNCONFIRMED','TLS_LINUX_TRANSFER_COMMAND_FAILED',
        'TLS_LINUX_TRANSFER_INPUT_INVALID','TLS_LINUX_TRANSFER_OUTPUT_LIMIT',
        'TLS_LINUX_TRANSFER_SOURCE_CHANGED','TLS_LINUX_TRANSFER_TIMEOUT',
        'TLS_LINUX_CA_PEM_STAT_FAILED','TLS_LINUX_CA_PEM_ACCESS_DENIED',
        'TLS_LINUX_CA_PEM_READ_FAILED','TLS_LINUX_CA_PEM_PARSE_FAILED',
        'TLS_LINUX_BRIDGE_INPUT_TIMEOUT','TLS_LINUX_BRIDGE_TIMEOUT','TLS_LINUX_BRIDGE_OUTPUT_LIMIT',
        'TLS_LINUX_BRIDGE_PROTOCOL','TLS_LINUX_BRIDGE_TERMINATION_UNCONFIRMED',
        'TLS_LINUX_CONSUMER_FAILED','TLS_LINUX_CHILD_EXIT_NONZERO','TLS_LINUX_BRIDGE_PROTOCOL_BYTES_PENDING',
        'TLS_LINUX_RESULT_MISSING','TLS_LINUX_CHILD_STDERR_NONEMPTY',
        'TLS_LINUX_SOURCE_CHANGED','TLS_LINUX_CLIENT_CLEANUP_RECOVERY_REQUIRED',
        'TLS_LINUX_GUEST_TERMINATION_UNCONFIRMED'
    )
    $safeRuntimeClasses=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($class in @(
        'STDERR_UNCLASSIFIED','STDERR_EMPTY','CONTAINER_NOT_FOUND','CONTAINER_NOT_RUNNING',
        'PORT_CONFLICT','DAEMON_UNREACHABLE','REGISTRY_AUTHORIZATION','IMAGE_NOT_FOUND',
        'TLS_SQLCLIENT_RESULT_INVALID','TLS_SQLCMD_TIMEOUT','TLS_ODBC_AMBIGUOUS',
        'TLS_SQLCMD_RESULT_INVALID','TLS_CA_PEM_STAT_FAILED','TLS_CA_PEM_ACCESS_DENIED',
        'TLS_CA_PEM_READ_FAILED','TLS_CA_PEM_PARSE_FAILED','PERMISSION_DENIED',
        'TLS_CERTIFICATE','NETWORK_NOT_FOUND','RUNTIME_TIMEOUT','DAEMON_REJECTED_REQUEST'
    )){$null=$safeRuntimeClasses.Add($class)}
    foreach($stage in @('CONSTRUCT','OPEN','QUERY','CLEANUP')){foreach($category in @('PLATFORM_UNSUPPORTED','ASSEMBLY_UNAVAILABLE','AUTHENTICATION','TIMEOUT','NETWORK','SQL','UNCLASSIFIED')){
        $null=$safeRuntimeClasses.Add('TLS_SQLCLIENT_'+$stage+'_'+$category)
    }}
    while($null-ne$exception){
        $message=[string]$exception.Message
        if($message -cin $safePublicTokens-or$message -cmatch '\ATLS_SQLCLIENT_(?:CONSTRUCT|OPEN|QUERY|CLEANUP)_(?:PLATFORM_UNSUPPORTED|ASSEMBLY_UNAVAILABLE|AUTHENTICATION|TIMEOUT|NETWORK|SQL|UNCLASSIFIED)\z'){
            return $message
        }
        if($message -cmatch '\ATLS_LAB_RUNTIME_COMMAND_FAILED\|exitCode=(-?\d{1,10})\|stderrClass=([A-Z0-9_]{1,64})\|stderrBytes=(\d{1,10})\|stdoutChars=(\d{1,10})\|operationStage=(unspecified|linux-client-create|linux-client-start|linux-client-layout|linux-client-trust-write|linux-client-observation|linux-client-namespace-check|linux-client-qualification)\z'){
            $exitCode=[long]$Matches[1];$stderrBytes=[long]$Matches[3];$stdoutChars=[long]$Matches[4]
            if($safeRuntimeClasses.Contains($Matches[2])-and$exitCode-ge[int]::MinValue-and$exitCode-le[int]::MaxValue-and
                $stderrBytes-ge0-and$stderrBytes-le1048576-and$stdoutChars-ge0-and$stdoutChars-le1048576){return $message}
        }
        $exception=$exception.InnerException
    }
    return 'TLS_LINUX_CONSUMER_REJECTED_OR_RECOVERY_REQUIRED'
}

function Invoke-LabTlsLinuxObservedProgram {
    param([object]$Bound,[object]$Budget,[string]$ContainerId,[string]$Program,[string]$InputText)
    $root=$Bound.StateRoot;$lease=Enter-LabTlsLinuxOperation $root
    $marker=Join-Path $root 'linux-client-execution.json'
    $operationStage=Get-LabTlsLinuxObservedOperationStage $Program
    try{
        $record=@{ContractVersion='SqlServerLab.LinuxExecution/0.1';Status='EXECUTION_PENDING';ClientContainerId=$ContainerId;RunId=$Bound.Record.RunId;OperationId=[guid]::NewGuid().ToString('D')}
        if(-not$lease.Nested){Write-LabTlsCaPrivateFile $marker $lease.Sid (ConvertTo-LabTlsRegistryWriterBytes $record)}
        $command=@('/opt/tls-client/pwsh/pwsh','-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Program)))
        $arguments=Get-LabTlsLinuxExecArguments $ContainerId $command -InputStream:([bool]$InputText)
        $output=Invoke-LabTlsContainer $arguments $InputText -Budget $Budget -OperationStage $operationStage
        $peer=if($lease.Nested){$script:SqlServerLabTlsLinuxLiveBridge.GuestPid}else{0}
        Assert-LabTlsLinuxGuestIdle $ContainerId $Budget -AllowedPeerPid $peer
        if(-not$lease.Nested){Remove-Item -LiteralPath $marker -Force -ErrorAction Stop}
        return $output
    }finally{Exit-LabTlsLinuxOperation $lease}
}
