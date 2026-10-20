#Requires -Version 7.5
<#
.SYNOPSIS
    Führt die feste native TLS-Abnahme an einem ausdrücklich gebundenen eigenen Hyper-V-SQL-2025-RTM-Run aus.
.DESCRIPTION
    ConfigurationPath enthält ausschließlich lokale Bindungen und öffentliche Metadaten.
    Vor Ausführung sind stabile Quellen, unabhängiger Review und lokale Gates erforderlich.
    Ein dauerhafter VM-/Operationsintent verhindert Replay. Unbekanntes Verbraucherende
    erhält VM, Disks und Schlüssel; es löst weder Stop noch Removal aus.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [Parameter(Mandatory)][ValidatePattern('\A[a-fA-F0-9]{64}\z')][string]$ExpectedConfigurationSha256,
    [ValidateSet('Supervisor','Worker')][string]$Mode='Supervisor',
    [datetimeoffset]$DeadlineUtc=[datetimeoffset]::UtcNow.AddMinutes(180)
)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$pins=[Collections.Generic.List[IDisposable]]::new();$module=$null;$runtime=$null;$held=$false;$password=$null
$result=[ordered]@{Status='FAIL_PRE_EFFECT';Cleanup='NO_NATIVE_EFFECT';Phase='BINDING';ErrorCode=$null;NativeEndKnown=$true;SqlBuild=$null;Cases=@()}
try{
    if(-not $IsWindows -or $DeadlineUtc -le [datetimeoffset]::UtcNow -or $DeadlineUtc -gt [datetimeoffset]::UtcNow.AddMinutes(181)){throw 'TLS_HV_EXECUTION_NOT_SUPPORTED'}
    $configPin=[IO.File]::Open($ConfigurationPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$pins.Add($configPin)
    if($configPin.Length -gt 4194304 -or (Get-FileHash -LiteralPath $ConfigurationPath).Hash -ine $ExpectedConfigurationSha256){throw 'TLS_HV_CONFIGURATION_CHANGED'}
    $config=Get-Content -LiteralPath $ConfigurationPath -Raw|ConvertFrom-Json -Depth 20 -DateKind String
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if($identity.User.Value -cne $config.ActorSid -or $repo -cne $config.RepositoryRoot -or $config.Scope -cne 'TLS001_HYPERV_NATIVE_OWN_RETAINED_VM' -or
        [datetimeoffset]::Parse($config.ExpiresUtc) -le [datetimeoffset]::UtcNow -or $config.ExpectedBuild -cne '17.0.1000.7'){throw 'TLS_HV_CONFIGURATION_BINDING_INVALID'}
    if([IO.Path]::GetFullPath($config.EvidenceRoot) -cne [IO.Path]::GetFullPath((Split-Path $ConfigurationPath -Parent)) -or
        [IO.Path]::GetFullPath($config.StateRoot) -cne [IO.Path]::GetFullPath((Join-Path $config.DataRoot 'State')) -or
        ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -ne $config.Elevated){throw 'TLS_HV_CONFIGURATION_ROOT_OR_TOKEN_CHANGED'}
    foreach($row in $config.Sources){
        $path=[IO.Path]::GetFullPath((Join-Path $repo $row.RelativePath))
        if(-not $path.StartsWith($repo+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal) -or $row.RelativePath -match '\.\.') {throw 'TLS_HV_SOURCE_PATH_INVALID'}
        $pin=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$pins.Add($pin)
        if((Get-FileHash -LiteralPath $path).Hash -ine $row.Sha256){throw 'TLS_HV_SOURCE_CHANGED'}
    }
    . (Join-Path $repo 'Tests/Common/AuthenticatedTlsHyperVAcceptance.ps1')
    $inventory=@(Get-TlsHyperVSourceInventory $repo)
    if(($inventory -join "`n") -cne (@($config.Sources|ForEach-Object RelativePath) -join "`n")){throw 'TLS_HV_SOURCE_INVENTORY_CHANGED'}
    Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -ErrorAction Stop
    $module=Get-Module SqlServerLab
    $digest=& $module {param($rows)$atoms=@('SqlServerLab.TlsHyperVSource/0.1');foreach($row in $rows){$atoms+=@($row.RelativePath,$row.Sha256.ToLowerInvariant())};Get-LabTlsPayloadDigest $atoms} $config.Sources
    if($digest -cne $config.SourceDigest){throw 'TLS_HV_SOURCE_DIGEST_INVALID'}
    $result.ContractVersion='SqlServerLab.TlsHyperVResult/0.1';$result.OperationId=$config.OperationId;$result.SourceDigest=$digest;$result.WorkerPid=$PID
    & $module {param($p,$sid)Assert-LabTlsCaPrivateAcl $p $sid;Assert-LabTlsCaPrivateAcl (Split-Path $p -Parent) $sid -Directory} $ConfigurationPath $config.ActorSid
    function Write-TlsEvidence([string]$Name,$Value){
        if($Name -cnotmatch '\A[a-z0-9-]+\.private\.json\z'){throw 'TLS_HV_EVIDENCE_NAME_INVALID'}
        & $module {param($p,$sid,$v)Write-LabTlsCaPrivateFile $p $sid (ConvertTo-LabTlsRegistryWriterBytes $v)} (Join-Path $config.EvidenceRoot $Name) $config.ActorSid $Value
    }
    function Assert-TlsBudget {
        if([datetimeoffset]::UtcNow -ge $DeadlineUtc -or (Test-Path -LiteralPath (Join-Path $config.EvidenceRoot 'cancel.private.json'))){throw 'TLS_HV_EXECUTION_BUDGET_EXHAUSTED'}
    }
    if($Mode -ceq 'Supervisor'){
        Write-TlsEvidence 'supervisor-intent.private.json' @{OperationId=$config.OperationId;Pid=$PID;StartTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks;DeadlineUtc=$DeadlineUtc.ToString('o');SourceDigest=$digest}
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'));$start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($arg in @('-NoLogo','-NoProfile','-File',$PSCommandPath,'-ConfigurationPath',$ConfigurationPath,'-ExpectedConfigurationSha256',$ExpectedConfigurationSha256,'-Mode','Worker','-DeadlineUtc',$DeadlineUtc.ToString('o'))){$start.ArgumentList.Add($arg)}
        $child=[Diagnostics.Process]::new();$child.StartInfo=$start
        # After starting a child, even an evidence-write failure is recovery-required.
        $result.Cleanup='RECOVERY_RETAIN_VM_DISKS_KEY';$result.NativeEndKnown=$false
        Invoke-TlsHyperVSupervisedProcess $child $DeadlineUtc $config.OperationId $digest {param($n,$v)Write-TlsEvidence $n $v} {
            $path=Join-Path $config.EvidenceRoot 'result.private.json'
            if((Get-Item -LiteralPath $path).Length -gt 1048576){throw 'TLS_HV_WORKER_RESULT_INVALID'}
            & $module {param($p,$sid)Assert-LabTlsCaPrivateAcl $p $sid} $path $config.ActorSid
            Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -Depth 20
        }
        $result.Status='PASS';$result.Cleanup='WORKER_COMPLETED';$result.NativeEndKnown=$true;return
    }
    Write-TlsEvidence 'worker-intent.private.json' @{OperationId=$config.OperationId;Pid=$PID;StartTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks;SourceDigest=$digest;DeadlineUtc=$DeadlineUtc.ToString('o')}
    $runtime=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke')
    try{$held=$runtime.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true;throw 'TLS_HV_RUNTIME_MUTEX_ABANDONED'}
    if(-not $held){throw 'TLS_HV_RUNTIME_BUSY'}
    $protectedLeases=[Collections.Generic.List[object]]::new()
    foreach($row in $config.ProtectedFiles){
        $pin=[IO.File]::Open($row.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$pins.Add($pin)
        if((Get-FileHash -LiteralPath $row.Path).Hash -ine $row.Sha256){throw 'TLS_HV_PROTECTED_FILE_CHANGED'}
        $item=Get-Item -LiteralPath $row.Path -Force
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'TLS_HV_PROTECTED_REPARSE'}
        $protectedLeases.Add(@{Row=$row;Pin=$pin;Length=$item.Length;LastWriteUtc=$item.LastWriteTimeUtc;CreationUtc=$item.CreationTimeUtc;Attributes=$item.Attributes})
    }
    function Assert-TlsProtection([switch]$Final) {
        foreach($lease in $protectedLeases){
            $item=Get-Item -LiteralPath $lease.Row.Path -Force
            if(-not $lease.Pin.CanRead -or $lease.Pin.SafeFileHandle.IsClosed -or $lease.Pin.Length -ne $lease.Length -or $item.Length -ne $lease.Length -or
                $item.LastWriteTimeUtc -ne $lease.LastWriteUtc -or $item.CreationTimeUtc -ne $lease.CreationUtc -or $item.Attributes -ne $lease.Attributes){throw 'TLS_HV_PROTECTED_LEASE_CHANGED'}
            # A held FileShare.Read lease denies new writers/deletion. Small authority
            # records are rehashed each time; large immutable media also at completion.
            if(($Final -or $lease.Length -lt 67108864) -and (Get-FileHash -LiteralPath $lease.Row.Path).Hash -ine $lease.Row.Sha256){throw 'TLS_HV_PROTECTED_FILE_CHANGED'}
        }
        $trust=@(Get-ChildItem Cert:/CurrentUser/Root|ForEach-Object {[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($_.RawData))}|Sort-Object)
        if(($trust -join ',') -cne ($config.HostRootDigests -join ',')){throw 'TLS_HV_HOST_TRUST_CHANGED'}
    }
    function Get-TlsOwnVm([string]$State){
        Assert-TlsBudget;Assert-TlsProtection
        $lab=& $module {param($c)Get-HyperVLabWorkflowRun -RunId $c.RunId -StateRoot $c.StateRoot -ExpectedVmId ([guid]$c.VmId)} $config
        if($lab.Run.scopeId -cne $config.ScopeId -or $lab.Run.metadata.workflowOperationId -cne $config.CreateOperationId -or
            $lab.Instance.windowsActivationIntent.Strategy -cne 'VerifyOnly' -or $lab.Instance.windowsActivationIntent.EgressPolicy -cne 'Denied' -or
            $lab.Instance.labNetwork.address -cne $config.Address){throw 'TLS_HV_OWN_BINDING_CHANGED'}
        $vm=Get-VM -Id ([guid]$config.VmId) -ErrorAction Stop
        if([string]$vm.State -cne $State -or [string]$vm.AutomaticStartAction -cne 'Nothing'){throw 'TLS_HV_VM_STATE_CHANGED'}
        $adapters=@(Get-VMNetworkAdapter -VM $vm|ForEach-Object {[ordered]@{Id=[string]$_.Id;SwitchId=[string]$_.SwitchId;MacAddress=[string]$_.MacAddress}}|Sort-Object Id)
        if(($adapters|ConvertTo-Json -Compress) -cne ($config.Adapters|ConvertTo-Json -Compress)){throw 'TLS_HV_ADAPTER_SET_CHANGED'}
        $disks=@(Get-VMHardDiskDrive -VM $vm)
        if($disks.Count -ne 1 -or $disks[0].Path -cne $config.Disk.Path){throw 'TLS_HV_DISK_CHANGED'}
        $disk=Get-VHD -Path $disks[0].Path -ErrorAction Stop
        if([string]$disk.DiskIdentifier -cne $config.Disk.DiskIdentifier -or $disk.ParentPath -cne $config.Disk.ParentPath){throw 'TLS_HV_DISK_ID_CHANGED'}
        return $lab
    }
    function Get-TlsAuthority {
        & $module {param($c)Get-LabTlsOperationalAuthority $c.DataRoot $c.ControllerId $c.LocationId $c.AuthorityRef $c.ClientRef} $config
    }
    $lab=Get-TlsOwnVm Off
    if($lab.Run.state -cne 'STOPPED' -or $lab.Instance.sqlCompletion){throw 'TLS_HV_PREPARED_STOPPED_RUN_REQUIRED'}
    $authority=Get-TlsAuthority
    if((Get-FileHash -LiteralPath $config.LocalGate.Path).Hash -ine $config.LocalGate.Sha256){throw 'TLS_HV_GATE_RECORD_CHANGED'}
    $gate=Get-Content -LiteralPath $config.LocalGate.Path -Raw|ConvertFrom-Json -Depth 8
    $selection=& (Join-Path $repo 'Tools/Get-CiTestSelection.ps1') -ChangedPath $config.ChangedPaths
    if($gate.Status -cne 'EXECUTED_PASS' -or $gate.ExitCode -ne 0 -or -not $gate.SourceStable -or $gate.SourceDigest -cne $digest -or -not $gate.NoReuse -or
        (($gate.Checks|Sort-Object) -join ',') -cne (($selection.StaticChecks|Sort-Object) -join ',') -or
        (Get-FileHash -LiteralPath $gate.LogPath).Hash -ine $gate.LogSha256){throw 'TLS_HV_LOCAL_GATE_NOT_PASSED'}
    $password=& $module {param($p)Get-LabSecret -Path $p -Name 'guest-administrator-password'} $lab.RunDirectory
    if($password -isnot [securestring]){throw 'TLS_HV_GUEST_CREDENTIAL_MISSING'}
    $credential=[pscredential]::new('Administrator',$password)
    $session=& $module {param($c)New-LabTlsSqlConsumerSession -DataRoot $c.DataRoot -ControllerId $c.ControllerId -LocationId $c.LocationId -OperationId $c.OperationId -RunId $c.RunId -ScopeId $c.ScopeId -VmId $c.VmId -SourceDigest $c.SourceDigest -WorkerDigest $c.WorkerDigest} $config
    $null=Get-TlsOwnVm Off
    $result.Cleanup='RECOVERY_RETAIN_VM_DISKS_KEY';$result.NativeEndKnown=$false;$result.Phase='START'
    $null=Start-SqlServerLab -RunId $config.RunId -StateRoot $config.StateRoot
    $lab=Get-TlsOwnVm Running
    $ready=& $module {param($c,$name,$cred)Wait-HyperVPowerShellDirect -VMName $name -ExpectedRunId $c.RunId -ExpectedScopeId $c.ScopeId -ExpectedVmId ([guid]$c.VmId) -Credential $cred -TimeoutSeconds 300} $config $lab.Instance.vmName $credential
    if(-not $ready -or -not $ready.Ready){throw 'TLS_HV_GUEST_NOT_READY'}
    $null=Get-TlsOwnVm Running
    $null=& $module {param($c,$cred)Invoke-LabWindowsSlotActivationReconcile -RunId $c.RunId -StateRoot $c.StateRoot -ExpectedVmId ([guid]$c.VmId) -Credential $cred} $config $credential
    $original=@(& $module {param($c,$name,$cred)Invoke-HyperVPowerShellDirect -VMName $name -ExpectedRunId $c.RunId -ExpectedScopeId $c.ScopeId -ExpectedVmId ([guid]$c.VmId) -Credential $cred -NoRetry -TimeoutSeconds 30 -ScriptBlock (Get-LabTlsHyperVOriginalKeyGuestScript) -ArgumentList @($c.OriginalContainer,$c.OriginalModulus,$c.MachineName,$c.CertreqSha256)} $config $lab.Instance.vmName $credential)
    if($original.Count -ne 1 -or -not $original[0].Success -or -not $original[0].ConsumerEnded -or -not $original[0].OriginalKeyBound -or $original[0].Modulus -cne $config.OriginalModulus){throw 'TLS_HV_ORIGINAL_KEY_PREFLIGHT_FAILED'}
    Write-TlsEvidence 'original-key-preflight.private.json' $original[0]
    $result.Phase='SQL_COMPLETE'
    Write-TlsEvidence 'before-sql.private.json' @{SourceDigest=$digest;OperationId=$config.OperationId;RunId=$config.RunId;ScopeId=$config.ScopeId;VmId=$config.VmId}
    $completion=& $module {param($s,$cred,$pwd,$media,$deadline,$cancel)Invoke-LabTlsHyperVSqlCompletion -Session $s -Credential $cred -SqlSaPassword $pwd -MediaRoot $media -DeadlineUtc $deadline -CancellationPath $cancel} $session $credential $password $config.MediaRoot $DeadlineUtc (Join-Path $config.EvidenceRoot 'cancel.private.json')
    $result.NativeEndKnown=$true;$result.SqlBuild=$completion.sqlReadiness.ProductVersion
    Write-TlsEvidence 'sql-completion.private.json' $completion
    $lab=Get-TlsOwnVm Running
    $direct=@{VMName=$lab.Instance.vmName;ExpectedRunId=$config.RunId;ExpectedScopeId=$config.ScopeId;ExpectedVmId=[guid]$config.VmId;Credential=$credential;NoRetry=$true;TimeoutSeconds=180}
    $script:tlsGuestCallNumber=0
    function Invoke-TlsGuest($Block,[object[]]$Arguments){
        $null=Get-TlsOwnVm Running;$result.NativeEndKnown=$false
        $observed=@(& $module {param($d,$b,$a)Invoke-HyperVPowerShellDirect @d -ScriptBlock $b -ArgumentList $a} $direct $Block $Arguments)
        $script:tlsGuestCallNumber++
        Write-TlsEvidence ('guest-call-'+$script:tlsGuestCallNumber+'.private.json') @{Phase=$result.Phase;Reply=$observed}
        if($observed.Count -ne 1 -or $observed[0].ConsumerEnded -isnot [bool]){throw 'TLS_HV_GUEST_REPLY_UNKNOWN'}
        $result.NativeEndKnown=$observed[0].ConsumerEnded
        if(-not $result.NativeEndKnown -or $observed[0].Success -isnot [bool] -or -not $observed[0].Success){throw 'TLS_HV_GUEST_OPERATION_FAILED'}
        if($observed[0].SqlServiceRestarted -is [bool] -and $observed[0].SqlServiceRestarted){
            $result.NativeEndKnown=$false;$readinessDirect=$direct.Clone();$readinessDirect.TimeoutSeconds=90
            $readiness=@(& $module {param($d)Invoke-HyperVPowerShellDirect @d -ScriptBlock (Get-LabTlsSqlReadinessGuestScript)} $readinessDirect)
            if($readiness.Count -ne 1 -or $readiness[0].ConsumerEnded -isnot [bool]){throw 'TLS_HV_SQL_READINESS_REPLY_UNKNOWN'}
            $result.NativeEndKnown=$readiness[0].ConsumerEnded
            if(-not $result.NativeEndKnown -or -not $readiness[0].Success -or $readiness[0].Build -cne '17.0.1000.7' -or $readiness[0].OnlineSystemDatabases -ne 4){throw 'TLS_HV_SQL_NOT_READY'}
            $observed[0]|Add-Member -NotePropertyName SqlReadiness -NotePropertyValue $readiness[0]
        }
        return $observed[0]
    }
    $cases=[Collections.Generic.List[object]]::new();$certificates=[Collections.Generic.List[object]]::new();$ownedRequests=[Collections.Generic.List[object]]::new();$originalCsr=$null;$last=$null
    foreach($case in @('valid','untrusted','wrong-san','short','renewed')){
        $result.Phase='TLS_'+$case.ToUpperInvariant();$null=Get-TlsOwnVm Running;$authority=Get-TlsAuthority
        $container=if($case -ceq 'renewed'){'SQLServerLab-TLS-Renew-'+$config.OperationId}else{$config.OriginalContainer}
        $address=if($case -ceq 'wrong-san'){$config.WrongSanAddress}else{$config.Address}
        if($case -ceq 'untrusted'){$csr=$originalCsr}else{
            $block=& $module {Get-LabTlsHyperVCsrGuestScript}
            $csr=Invoke-TlsGuest $block @($config.OperationId,$case,$container,$address,$config.MachineName,($case -ceq 'renewed'),$config.OriginalModulus,$config.CertreqSha256,$(if($case -ceq 'valid'){$config.CsrRetryInfSha256}else{$null}))
            if($case -cne 'renewed' -and $csr.Modulus -cne $config.OriginalModulus){throw 'TLS_HV_ORIGINAL_KEY_CHANGED'}
            if($case -ceq 'renewed' -and $csr.Modulus -ceq $config.OriginalModulus){throw 'TLS_HV_RENEWAL_REUSED_KEY'}
            foreach($request in $csr.OwnedRequests){if(-not @($ownedRequests|Where-Object Thumbprint -CEQ $request.Thumbprint).Count){$ownedRequests.Add($request)}}
        }
        if($case -ceq 'valid'){$originalCsr=$csr}
        $null=Get-TlsOwnVm Running
        $der=[Convert]::FromBase64String($csr.Csr)
        if($case -ceq 'untrusted'){$leafDer=New-TlsHyperVUntrustedLeaf $der $address $config.MachineName $module;$notAfter=$null}
        else{
            $leaf=& $module {param($c,$bytes,$ip,$short)New-LabAuthenticatedTlsServerLeaf -DataRoot $c.DataRoot -ControllerId $c.ControllerId -LocationId $c.LocationId -Context CURRENT_WINDOWS_PROCESS -CandidateId $c.CandidateId -CsrDer $bytes -Identity ([pscustomobject]@{Kind='IP';Value=$ip}) -ValidityDays $(if($short){$null}else{[int]1}) -ValiditySeconds $(if($short){[int]180}else{$null}) -WindowsMachineName $c.MachineName} $config $der $address ($case -ceq 'short')
            if(-not $leaf.Success){throw 'TLS_HV_LEAF_SIGNING_FAILED'}
            $leafDer=$leaf.Value.CertificateDer;$notAfter=$leaf.Value.NotAfterUtc
        }
        $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($leafDer)).ToLowerInvariant()
        $block=& $module {Get-LabTlsHyperVLeafInstallGuestScript}
        $last=Invoke-TlsGuest $block @($config.OperationId,$case,[Convert]::ToBase64String($leafDer),$sha,$container,$csr.Modulus)
        $certificates.Add([pscustomobject]@{Thumbprint=$last.Thumbprint;Sha256=$sha})
        $expected=switch($case){'untrusted'{'UNTRUSTED'};'wrong-san'{'WRONG_SAN'};default{'PASS'}}
        if($case -ceq 'untrusted'){$cases.Add([pscustomobject]@{Case='UNTRUSTED_OVERRIDE_CONTROL';Results=@(Invoke-TlsHyperVClientPair $config.Address $password $true PASS $authority.Client $module)})}
        $cases.Add([pscustomobject]@{Case=$case;Results=@(Invoke-TlsHyperVClientPair $config.Address $password $false $expected $authority.Client $module)})
        if($case -ceq 'short'){
            Write-TlsEvidence 'short-before-expiry.private.json' @{Case=$case;CertificateSha256=$sha;GuestReceipt=$last;NotAfterUtc=$notAfter;Cases=$cases.ToArray()}
            $expiry=[datetimeoffset]::Parse($notAfter).AddSeconds(2)
            while([datetimeoffset]::UtcNow -le $expiry){Assert-TlsBudget;Start-Sleep -Seconds 1}
            $cases.Add([pscustomobject]@{Case='EXPIRED';Results=@(Invoke-TlsHyperVClientPair $config.Address $password $false EXPIRED $authority.Client $module)})
        }
        Write-TlsEvidence ($case+'-case.private.json') @{Case=$case;CertificateSha256=$sha;GuestReceipt=$last;Cases=$cases.ToArray()}
        $null=Get-TlsAuthority;Assert-TlsProtection
    }
    $result.Phase='RENEWAL_NATIVE_REBOOT'
    $null=Get-TlsOwnVm Running
    $setupReply=Get-Content -LiteralPath (Join-Path $session.Directory 'setup-reply.json') -Raw|ConvertFrom-Json
    $bootBefore=@(& $module {param($d,$hash)Invoke-HyperVPowerShellDirect @d -ScriptBlock (Get-LabTlsSqlPostBootGuestScript) -ArgumentList @($hash)} $direct $setupReply.summarySha256)
    if($bootBefore.Count -ne 1 -or -not $bootBefore[0].InstallerIdle){throw 'TLS_HV_RENEWAL_BOOT_UNBOUND'}
    $previousBoot=[datetimeoffset]::Parse($bootBefore[0].Boot)
    Write-TlsEvidence 'renewal-reboot-intent.private.json' @{OperationId=$config.OperationId;VmId=$config.VmId;PreviousBoot=$previousBoot.ToString('o');CertificateSha256=$last.Sha256;Attempts=1;Method='Win32Shutdown(2)'}
    $result.NativeEndKnown=$false
    $rebootDirect=$direct.Clone();$rebootDirect.TimeoutSeconds=30
    $readDirect=$direct.Clone();$readDirect.TimeoutSeconds=30
    try{$null=& $module {param($d)Invoke-HyperVPowerShellDirect @d -ScriptBlock {
        $ErrorActionPreference='Stop';$reply=Invoke-CimMethod -InputObject (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop) -MethodName Win32Shutdown -Arguments @{Flags=2}
        if($reply.ReturnValue -ne 0){throw 'TLS_HV_RENEWAL_REBOOT_REJECTED'}
    }} $rebootDirect}catch{Write-Verbose 'No reboot replay; observing the new epoch only.'}
    $newBoot=$null;$bootDeadline=[datetimeoffset]::UtcNow.AddMinutes(5)
    do{
        Assert-TlsBudget;$null=Get-TlsOwnVm Running
        try{
            $idle=@(& $module {param($d,$hash)Invoke-HyperVPowerShellDirect @d -ScriptBlock (Get-LabTlsSqlPostBootGuestScript) -ArgumentList @($hash)} $readDirect $setupReply.summarySha256)
            if($idle.Count -ne 1 -or -not $idle[0].InstallerIdle -or [datetimeoffset]::Parse($idle[0].Boot) -le $previousBoot){throw 'TLS_HV_RENEWAL_BOOT_INSTALLER_NOT_PROVEN'}
            $fresh=@(& $module {param($d,$thumb,$sha,$modulus,$container,$unique)Invoke-HyperVPowerShellDirect @d -ScriptBlock {
                param($Thumbprint,$Sha256,$Modulus,$Container,$UniqueContainer)
                $ErrorActionPreference='Stop';$boot=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime()
                if(([datetime]::UtcNow-$boot).TotalSeconds -lt 60){throw 'TLS_HV_RENEWAL_BOOT_SETTLING'}
                $map=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop
                $key='HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\'+$map.MSSQLSERVER+'\MSSQLServer\SuperSocketNetLib'
                $settings=Get-ItemProperty -LiteralPath $key -ErrorAction Stop
                if($settings.Certificate -cne $Thumbprint.ToLowerInvariant() -or [int]$settings.ForceEncryption -ne 1){throw 'TLS_HV_RENEWAL_BINDING_DRIFT'}
                $errorLog=Get-ItemPropertyValue -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\'+$map.MSSQLSERVER+'\MSSQLServer\Parameters') -Name SQLArg1 -ErrorAction Stop
                if($errorLog -notlike '-e*'){throw 'TLS_HV_RENEWAL_ERRORLOG_PATH_INVALID'}
                $logPath=$errorLog.Substring(2).Trim('"');$log=Get-Item -LiteralPath $logPath -ErrorAction Stop
                if($log.LastWriteTimeUtc -lt $boot -or (Get-Content -LiteralPath $logPath -Raw -ErrorAction Stop) -notmatch ('(?i)Cert Hash\(sha1\)\s+"?'+[regex]::Escape($Thumbprint)+'"?.*successfully loaded')){throw 'TLS_HV_RENEWAL_CERTIFICATE_NOT_LOADED'}
                $store=[Security.Cryptography.X509Certificates.X509Store]::new('My','LocalMachine');$private=$null
                try{
                    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly);$cert=@($store.Certificates|Where-Object Thumbprint -CEQ $Thumbprint)
                    if($cert.Count -ne 1 -or -not $cert[0].HasPrivateKey){throw 'TLS_HV_RENEWAL_CERTIFICATE_MISSING'}
                    $hasher=[Security.Cryptography.SHA256]::Create();try{$actual=([BitConverter]::ToString($hasher.ComputeHash($cert[0].RawData))).Replace('-','').ToLowerInvariant()}finally{$hasher.Dispose()}
                    $private=$cert[0].PrivateKey
                    if($actual -cne $Sha256 -or $private -isnot [Security.Cryptography.RSACryptoServiceProvider] -or $private.CspKeyContainerInfo.UniqueKeyContainerName -cne $UniqueContainer -or
                        $private.CspKeyContainerInfo.Exportable -or [int]$private.CspKeyContainerInfo.KeyNumber -ne 1 -or [Convert]::ToBase64String($private.ExportParameters($false).Modulus) -cne $Modulus){throw 'TLS_HV_RENEWAL_KEY_DRIFT'}
                }finally{if($private){$private.Dispose()};$store.Dispose()}
                [pscustomobject]@{Boot=$boot.ToString('o');Bound=$true}
            } -ArgumentList @($thumb,$sha,$modulus,$container,$unique)} $readDirect $last.Thumbprint $last.Sha256 $csr.Modulus $container $csr.UniqueContainer)
            if($fresh.Count -eq 1 -and $fresh[0].Bound -and $fresh[0].Boot -ceq $idle[0].Boot -and [datetimeoffset]::Parse($fresh[0].Boot) -gt $previousBoot){$newBoot=$fresh[0];break}
        }catch{Write-Verbose 'Waiting for renewed TLS binding on the same new boot.'}
        if([datetimeoffset]::UtcNow -ge $bootDeadline){throw 'TLS_HV_RENEWAL_BOOT_NOT_PROVEN'}
        Start-Sleep -Seconds 2
    }while($true)
    $result.NativeEndKnown=$true;$authority=Get-TlsAuthority
    $cases.Add([pscustomobject]@{Case='RENEWAL_AFTER_NATIVE_REBOOT';Results=@(Invoke-TlsHyperVClientPair $config.Address $password $false PASS $authority.Client $module)})
    Write-TlsEvidence 'renewal-boot-proof.private.json' @{PreviousBoot=$previousBoot.ToString('o');NewBoot=$newBoot.Boot;CertificateSha256=$last.Sha256;StrictClients='BOTH_PASS'}
    $result.Phase='TLS_CLEANUP'
    $cleanup=Invoke-TlsGuest (Get-TlsHyperVCleanupGuestScript) @($config.OperationId,$certificates.ToArray(),$config.OriginalContainer,$config.OriginalModulus,('SQLServerLab-TLS-Renew-'+$config.OperationId),$last.Thumbprint,$ownedRequests.ToArray())
    Write-TlsEvidence 'guest-cleanup.private.json' $cleanup
    $cases.Add([pscustomobject]@{Case='RESTORED_DEFAULT_CONTROL';Results=@(Invoke-TlsHyperVClientPair $config.Address $password $true PASS $authority.Client $module)})
    $result.Cases=$cases.ToArray()
    $cleanupRule=Invoke-TlsGuest {
        param($OperationId,$Address,$HostAddress)
        $ErrorActionPreference='Stop';$name='SqlServerLab-Tls-HyperV-'+$OperationId
        $rule=@(Get-NetFirewallRule -ErrorAction Stop|Where-Object Name -CEQ $name)
        if($rule.Count -ne 1){throw 'TLS_HV_FIREWALL_SCOPE_CHANGED'}
        $ports=$rule[0]|Get-NetFirewallPortFilter -ErrorAction Stop;$addresses=$rule[0]|Get-NetFirewallAddressFilter -ErrorAction Stop
        if([string]$ports.LocalPort -cne '1433' -or [string]$addresses.LocalAddress -cne $Address -or [string]$addresses.RemoteAddress -cne $HostAddress){throw 'TLS_HV_FIREWALL_BINDING_CHANGED'}
        $rule[0]|Remove-NetFirewallRule -ErrorAction Stop
        if(@(Get-NetFirewallRule -ErrorAction Stop|Where-Object Name -CEQ $name).Count){throw 'TLS_HV_FIREWALL_REMAINS'}
        [pscustomobject]@{Success=$true;ConsumerEnded=$true;OwnFirewallRuleRemoved=$true}
    } @($config.OperationId,$config.Address,$config.HostAddress)
    Write-TlsEvidence 'firewall-cleanup.private.json' $cleanupRule
    $lab=Get-TlsOwnVm Running;$vm=Get-VM -Id ([guid]$config.VmId);$dvd=@(Get-VMDvdDrive -VM $vm -ErrorAction Stop)
    if($dvd.Count -ne 1 -or $dvd[0].Path -cne $config.MediaIsoPath){throw 'TLS_HV_DVD_CLEANUP_BINDING_CHANGED'}
    $dvd[0]|Remove-VMDvdDrive -ErrorAction Stop
    $null=Stop-SqlServerLab -RunId $config.RunId -StateRoot $config.StateRoot -SkipHostMemoryRelease -Force -Confirm:$false
    $lab=Get-TlsOwnVm Off
    if($lab.Run.state -cne 'STOPPED' -or @(Get-VMDvdDrive -VM (Get-VM -Id ([guid]$config.VmId))).Count){throw 'TLS_HV_FINAL_STOP_NOT_CONFIRMED'}
    Assert-TlsProtection -Final
    $result.Status='PASS';$result.Phase='COMPLETED';$result.Cleanup='OWN_TLS_ARTIFACTS_REMOVED_ACL_AND_BINDING_RESTORED_EXISTING_VM_DISKS_ORIGINAL_KEY_RETAINED_STOPPED'
}catch{
    $result.ErrorCode=if($_.Exception.Message -match '\A(TLS_[A-Z0-9_]+)'){$Matches[1]}else{'TLS_HV_ACCEPTANCE_FAILED'}
    if($Mode -ceq 'Worker' -and $module -and $config){
        try{Write-TlsEvidence 'failure.private.json' @{ErrorCode=$result.ErrorCode;ExceptionType=$_.Exception.GetType().FullName;HResult=$_.Exception.HResult;Position=$_.InvocationInfo.PositionMessage;Stack=$_.ScriptStackTrace}}catch{Write-Verbose 'Private failure detail could not be persisted.'}
    }
    if($result.Cleanup -cne 'NO_NATIVE_EFFECT'){$result.Status='RECOVERY_REQUIRED'}
}finally{
    if($Mode -ceq 'Worker' -and $module -and $config){try{Write-TlsEvidence 'result.private.json' $result}catch{$result.Status='RECOVERY_REQUIRED';$result.ErrorCode='TLS_HV_RESULT_WRITE_FAILED';Write-Error 'TLS_HV_RESULT_WRITE_FAILED' -ErrorAction Continue}}
    if($password){$password.Dispose()};if($held){$runtime.ReleaseMutex()};if($runtime){$runtime.Dispose()}
    for($i=$pins.Count-1;$i -ge 0;$i--){$pins[$i].Dispose()}
}
$result|Select-Object Status,Phase,Cleanup,ErrorCode
if($result.Status -cne 'PASS'){exit 1}
