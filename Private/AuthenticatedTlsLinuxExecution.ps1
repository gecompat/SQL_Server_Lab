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
