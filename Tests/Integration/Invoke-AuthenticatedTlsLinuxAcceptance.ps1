#Requires -Version 7.5
<#
.SYNOPSIS Prueft beide echten Linux-Clients an genau einem neuen eigenen SQL-Lab.
.DESCRIPTION Kein Host-Trustimport und keine Registry-/Exportqualifikation.
    Vier eigene Leafschluessel bleiben im neuen SQL-Container. Client-Trust
    gilt nur fuer Kindprozesse in kurzlebigen, receiptgebundenen Namespaces.
#>
[CmdletBinding(DefaultParameterSetName='Parent')]
param([Parameter(Mandatory,ParameterSetName='Parent')][string]$EvidenceDirectory,
    [Parameter(Mandatory,ParameterSetName='Parent')][string]$PowerShellPackage,
    [string[]]$PreserveFile=@(),
    [ValidateSet('docker','podman')][string]$Provider='docker',
    [ValidateSet('2019-CU32','2022-CU27','2025-CU9')][string]$Version='2019-CU32',[switch]$Execute,
    [Parameter(Mandatory,ParameterSetName='Worker',DontShow=$true)][string]$WorkerTicket,
    [Parameter(Mandatory,ParameterSetName='Worker',DontShow=$true)][string]$WorkerNonce)
$ErrorActionPreference='Stop'
if(-not $Execute){throw 'TLS_LINUX_EXECUTE_REQUIRED_ONE_OWN_SQL_LAB_AND_FIVE_SEQUENTIAL_CLIENTS'}
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repo 'Tests/Common/OwnedHostTestScope.ps1')
. (Join-Path $repo 'Tests/Common/AuthenticatedTlsLinuxClient.ps1')
. (Join-Path $repo 'Tests/Common/AuthenticatedTlsAcceptanceSelection.ps1')
Assert-TlsLinuxNoRecoveryCustody
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -PassThru -Force
if($PSCmdlet.ParameterSetName -ceq 'Parent'){
    # This parent retains the actual runtime lease until the worker is terminal.
    # The protected, held ticket binds the one child to this live parent/source;
    # it is not a reusable resource or execution-authorization token.
    $target=& $module {param($P) Assert-LabOwnedHostPath ([IO.Path]::GetFullPath($P))} $EvidenceDirectory
    $control=$target+'.control'
    if((Test-Path -LiteralPath $target) -or (Test-Path -LiteralPath $control)){throw 'TLS_LINUX_NEW_SUPERVISED_SCOPE_REQUIRED'}
    $lease=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke');$leaseHeld=$false;$ticketLock=$null;$workerJob=$null;$ticket=$null
    try{
        try{$leaseHeld=$lease.WaitOne(0)}catch [Threading.AbandonedMutexException]{$leaseHeld=$true;throw 'TLS_LINUX_RUNTIME_MUTEX_ABANDONED'}
        if(-not $leaseHeld){throw 'TLS_LINUX_RUNTIME_MUTEX_BUSY_NO_ARRANGE'}
        & $module {param($P) Initialize-LabTlsCaPrivateDirectory $P (Get-LabTlsWindowsProcessFacts).UserSid -NewOnly} $control
        $now=[DateTimeOffset]::UtcNow;$parentProcess=[Diagnostics.Process]::GetCurrentProcess()
        $nonce=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        $ticket=@{ParentId=$PID;ParentStartTicks=$parentProcess.StartTime.ToUniversalTime().Ticks;ParentInvocation=$parentProcess.MainModule.FileName;Nonce=$nonce;SourceSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;EvidenceDirectory=$target;PowerShellPackage=[IO.Path]::GetFullPath($PowerShellPackage);Provider=$Provider;Version=$Version;PreserveFile=$PreserveFile;StopAt=$now.AddMinutes(25).ToString('o');Deadline=$now.AddMinutes(30).ToString('o');StopFile=(Join-Path $control 'stop-requested');ReadyFile=(Join-Path $control 'custody-assigned');ClaimFile=(Join-Path $control 'worker-claimed');ClosedFile=(Join-Path $control 'custody-closed')}
        $ticketPath=Join-Path $control 'worker-ticket.private.json'
        & $module {param($P,$Data) Write-LabTlsCaPrivateFile $P (Get-LabTlsWindowsProcessFacts).UserSid (ConvertTo-LabTlsRegistryWriterBytes $Data)} $ticketPath $ticket
        $ticketLock=[IO.File]::Open($ticketPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'));$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($arg in @('-NoLogo','-NoProfile','-File',$PSCommandPath,'-Execute','-WorkerTicket',$ticketPath,'-WorkerNonce',$nonce)){$start.ArgumentList.Add($arg)}
        $workerJob=New-TlsLinuxWorkerJob
        $supervisor=Invoke-TlsLinuxSupervisedProcess -StartInfo $start -StopAt ([DateTimeOffset]::Parse($ticket.StopAt)) -Deadline ([DateTimeOffset]::Parse($ticket.Deadline)) -StopFile $ticket.StopFile -WorkerJob $workerJob -ReadyFile $ticket.ReadyFile
        $proof=@{ExitCode=$supervisor.ExitCode;ExitConfirmed=$supervisor.ExitConfirmed;JobEmptyConfirmed=$supervisor.JobEmptyConfirmed;StopRequested=$supervisor.StopRequested;HardStopped=$supervisor.HardStopped;ElapsedSeconds=$supervisor.ElapsedSeconds;WorkerSourceSha256=$ticket.SourceSha256;ParentHeldRuntimeLease=$true;StdoutSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($supervisor.Stdout)));StderrSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($supervisor.Stderr)));Provider=$Provider;Version=$Version;AtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
        $proof.WorkerFailureCode=if($supervisor.ExitCode -ne 0){Get-TlsLinuxWorkerFailureCode $supervisor.Stderr}else{$null}
        & $module {param($P,$Data) Write-LabTlsCaPrivateFile $P (Get-LabTlsWindowsProcessFacts).UserSid (ConvertTo-LabTlsRegistryWriterBytes $Data)} (Join-Path $control 'supervisor-terminal.private.json') $proof
        if($supervisor.HardStopped -or -not $supervisor.ExitConfirmed -or -not $supervisor.JobEmptyConfirmed){throw 'TLS_LINUX_SUPERVISOR_HARD_STOP_RECOVERY_REQUIRED'}
        if($supervisor.ExitCode -ne 0 -or $supervisor.StopRequested){throw 'TLS_LINUX_SUPERVISED_WORKER_FAILED_SEE_PRIVATE_TERMINALS'}
        $terminal=Get-Content -LiteralPath (Join-Path $target 'terminal.private.json') -Raw|ConvertFrom-Json -Depth 24 -DateKind String
        if($terminal.Status -cne 'PASS' -or -not $terminal.Removed -or -not $terminal.Preserved){throw 'TLS_LINUX_SUPERVISED_RESULT_NOT_COMPLETE'}
        return $terminal|Select-Object Status,Provider,Version,ExpectedBuild,Removed,Preserved,Commands
    }finally{
        # Retain the actual job, ticket and lease on an unconfirmed termination.
        # Recovery must reconcile that custody before another native admission.
        $safeToRelease=$false
        try{
            if($workerJob -and -not $workerJob.TerminateAndConfirm(5000)){throw 'TLS_LINUX_JOB_TERMINATION_UNCONFIRMED'}
            if($ticket){
                & $module {param($P,$Data) Write-LabTlsCaPrivateFile $P (Get-LabTlsWindowsProcessFacts).UserSid (ConvertTo-LabTlsRegistryWriterBytes $Data)} $ticket.ClosedFile @{Closed=$true;AtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
            }
            if($workerJob){$workerJob.Dispose()}
            $safeToRelease=$true
        }finally{
            if($safeToRelease){if($ticketLock){$ticketLock.Dispose()};if($leaseHeld){$lease.ReleaseMutex()};$lease.Dispose()}
            else{
                if(-not $global:SqlServerLabTlsLinuxRecoveryCustody){$global:SqlServerLabTlsLinuxRecoveryCustody=[Collections.Generic.List[object]]::new()}
                $global:SqlServerLabTlsLinuxRecoveryCustody.Add(@{Job=$workerJob;TicketLock=$ticketLock;Lease=$lease;LeaseHeld=$leaseHeld;Control=$control})
                throw 'TLS_LINUX_CUSTODY_RECOVERY_REQUIRED_LEASE_RETAINED'
            }
        }
    }
}
$ticketPath=& $module {param($P) Assert-LabOwnedHostPath ([IO.Path]::GetFullPath($P))} $WorkerTicket
& $module {param($P) Assert-LabTlsCaPrivateAcl $P (Get-LabTlsWindowsProcessFacts).UserSid} $ticketPath
$ticket=Get-Content -LiteralPath $ticketPath -Raw|ConvertFrom-Json -DateKind String
$parentProcess=Get-Process -Id $ticket.ParentId -ErrorAction Stop
if($ticket.ParentId -eq $PID -or $parentProcess.StartTime.ToUniversalTime().Ticks -ne $ticket.ParentStartTicks -or
    $parentProcess.MainModule.FileName -cne $ticket.ParentInvocation -or $WorkerNonce -cne $ticket.Nonce -or
    (Get-FileHash -LiteralPath $PSCommandPath).Hash -cne $ticket.SourceSha256 -or [DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($ticket.StopAt)){
    throw 'TLS_LINUX_SUPERVISOR_TICKET_INVALID'
}
$EvidenceDirectory=$ticket.EvidenceDirectory;$PowerShellPackage=$ticket.PowerShellPackage;$Provider=$ticket.Provider;$Version=$ticket.Version;$PreserveFile=@($ticket.PreserveFile)
$custodyClock=[Diagnostics.Stopwatch]::StartNew()
while(-not(Test-Path -LiteralPath $ticket.ReadyFile)){
    if($parentProcess.HasExited -or $custodyClock.Elapsed.TotalSeconds -ge 15){throw 'TLS_LINUX_PARENT_CUSTODY_NOT_ASSIGNED'}
    Start-Sleep -Milliseconds 20
}
Enter-TlsLinuxWorkerCustody -TicketPath $ticketPath -Ticket $ticket -WorkerId $PID -WorkerStartTicks ([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks)
$tool=& (Join-Path $repo 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider
if(-not $tool.Available){throw 'TLS_LINUX_PROVIDER_UNAVAILABLE'}
$ready=& (Join-Path $repo 'Tools/Test-SqlServerLabClientReadiness.ps1') -Provider $Provider -Operation Inspect
if($ready.Status -cne 'READY'){throw 'TLS_LINUX_READINESS_BLOCKED'}
$package=& $module {param($Path) Assert-LabOwnedHostPath $Path} ([IO.Path]::GetFullPath($PowerShellPackage))
Assert-TlsLinuxPowerShellPackage $package
$evidence=& $module {param($Path) Assert-LabOwnedHostPath $Path} ([IO.Path]::GetFullPath($EvidenceDirectory))
if(Test-Path -LiteralPath $evidence){throw 'TLS_LINUX_NEW_EVIDENCE_REQUIRED'}
& $module {param($Path) Initialize-LabTlsCaPrivateDirectory $Path (Get-LabTlsWindowsProcessFacts).UserSid -NewOnly} $evidence
$audit=[guid]::NewGuid().ToString('D');$state=Join-Path $evidence 'state'
$context=@{Module=$module;Provider=$Provider;Version=$Version;Evidence=$evidence;Audit=$audit;StateRoot=$state;Run=$null;SqlId=$null;SqlExecutionUser=$null;ClientIntent=$null;ClientId=$null;Commands=0;Deadline=[DateTimeOffset]::Parse($ticket.StopAt);CleanupDeadline=[DateTimeOffset]::Parse($ticket.Deadline);StopFile=$ticket.StopFile;Budget=$null;RuntimePin=$null;Removed=$false}
$expected=Get-OwnedTlsAcceptanceProfile $Version
$results=[Collections.Generic.List[object]]::new();$issuer=$null;$issuerKey=$null;$held=$false;$failure=$null;$cleanupFailure=$null;$removed=$false;$preserved=$false
$fileBaseline=@();$inventoryBefore=$null
function Get-TlsLinuxInventory {
    param($Context,[switch]$Cleanup)
    $inventory=@{}
    foreach($kind in @('containers','volumes','networks')){
        $vector=switch($kind){'containers'{@('ps','-a','--no-trunc','--format','{{.ID}}')};'volumes'{@('volume','ls','--format','{{.Name}}')};'networks'{@('network','ls','--no-trunc','--format','{{.ID}}')}}
        $output=Invoke-TlsLinuxNative $Context $vector -Cleanup:$Cleanup
        $inventory[$kind]=@($output -split '\r?\n'|Where-Object{$_}|Sort-Object -CaseSensitive)
    }
    return $inventory
}
$mutex=$null
try{
    $root=Initialize-OwnedHostTestRoot -Module $module -StateRoot $state -Providers @($Provider) -ParentOperationId $audit
    New-TlsLinuxPolicyBudget $context
    $savedPin=@{}
    foreach($name in @('Provider','Invocation','Endpoint','IdentityPath','IdentitySha256','RuntimeScopeId','RoutingKey','IncarnationKey','MachineName')){$savedPin[$name]=$context.RuntimePin.$name}
    Write-TlsLinuxProof $context 'original-runtime-pin.private.json' @{Pin=$savedPin;PolicyId=$root.PolicyId;StateRoot=$state;RecordedBeforeProviderArrange=$true;AtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
    $budget=$context.Budget
    $context.ClientImage=& $module {param($B) ConvertTo-LabTlsImageId (Invoke-LabTlsContainer @('image','inspect','mcr.microsoft.com/mssql/server:2025-CU9-ubuntu-24.04','--format','{{.Id}}') -Budget $B)} $budget
    foreach($path in $PreserveFile){
        $full=& $module {param($Path) Assert-LabOwnedHostPath $Path} ([IO.Path]::GetFullPath($path))
        if(-not(Test-Path -LiteralPath $full -PathType Leaf)){throw 'TLS_LINUX_PRESERVED_FILE_MISSING'}
        $fileBaseline+=@{Path=$full;Bytes=(Get-Item -LiteralPath $full).Length;Sha256=(Get-FileHash -LiteralPath $full).Hash}
    }
    $inventoryBefore=Get-TlsLinuxInventory $context
    Write-TlsLinuxProof $context 'preservation-before.private.json' @{Files=$fileBaseline;Resources=$inventoryBefore}
    Write-TlsLinuxProof $context 'intent.private.json' @{AuditId=$audit;Provider=$Provider;Version=$Version;RootPolicy=$root;MaximumNewSqlLabs=1;MaximumSequentialClients=5;MaximumNewOwnLeaves=4;CommandsLimit=450;TotalMinutes=30;CleanupReserveMinutes=5;NoReplay=$true;Recovery='Reconcile exact run and immutable client intentions; preserve original failures; no foreign resources or host trust mutation'}
    Enter-TlsLinuxCommandBudget $context
    $lab=New-SqlServerLab -Provider $Provider -Version $Version -Profile compact -Cpu 2 -MemoryMB 3072 -StateRoot $state -InstanceId primary -LabName ('tls-linux-'+$audit.Replace('-','').Substring(0,12)) -AutoStart off -GenerateSaPassword -NonInteractive
    $context.Run=$lab
    if(-not $lab.RunId -or $lab.State -cne 'Running' -or @($lab.Instances).Count -ne 1){throw 'TLS_LINUX_OWN_SQL_CREATE_INCOMPLETE'}
    $own=& $module {param($Run,$Root,$B) Get-LabTlsOwnedRuntimeContext -RunId $Run.RunId -StateRoot $Root -Budget $B} $lab $state $budget
    $context.SqlId=$own.ContainerId
    Write-TlsLinuxProof $context 'created-run.private.json' @{RunId=$lab.RunId;ScopeId=$lab.ScopeId;StateRoot=$state;ContainerId=$context.SqlId;Provider=$Provider;Version=$Version;ClientImage=$context.ClientImage}
    if($Version -cin @('2022-CU27','2025-CU9') -and $own.Inspect.Config.User -cne 'mssql'){throw 'TLS_LINUX_SQL_IMAGE_USER_UNSUPPORTED'}
    Initialize-TlsLinuxSqlExecutionIdentity $context
    $issuerKey=[Security.Cryptography.RSA]::Create(3072)
    $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=SQL_Server_Lab Linux fixture CA',$issuerKey,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]'KeyCertSign, CrlSign',$true))
    $issuer=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1),[DateTimeOffset]::UtcNow.AddDays(2))
    $caPem=[Security.Cryptography.PemEncoding]::WriteString('CERTIFICATE',$issuer.RawData)
    $caPemHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($caPem)))
    $leaves=@{}
    foreach($kind in @('valid','wrong-san','renewed')){$leaves[$kind]=New-TlsLinuxLeafFixture $context $issuer $kind}
    if($leaves.valid.SpkiSha256 -ceq $leaves.renewed.SpkiSha256){throw 'TLS_LINUX_RENEWAL_DID_NOT_CHANGE_KEY'}
    $phases=@(
        @{Name='valid';Leaf='valid';Cases=@(@{Name='STRICT_TRUSTED';Positive=$true;Trusted=$true;Bypass=$false},@{Name='DEFAULT_TRUE';Positive=$true;Trusted=$false;Bypass=$true},@{Name='UNTRUSTED';Positive=$false;Trusted=$false;Bypass=$false},@{Name='TRUST_RESTORED';Positive=$true;Trusted=$true;Bypass=$false})},
        @{Name='wrong-san';Leaf='wrong-san';Cases=@(@{Name='WRONG_SAN';Positive=$false;Trusted=$true;Bypass=$false})},
        @{Name='valid-restored';Leaf='valid';Cases=@(@{Name='NAME_CONTROL_RESTORED';Positive=$true;Trusted=$true;Bypass=$false})},
        @{Name='expired';Leaf='expired';Cases=@(@{Name='PRE_EXPIRY_CONTROL';Positive=$true;Trusted=$true;Bypass=$false},@{Name='EXPIRED';Positive=$false;Trusted=$true;Bypass=$false})},
        @{Name='renewed';Leaf='renewed';Cases=@(@{Name='NEW_KEY_RENEWAL';Positive=$true;Trusted=$true;Bypass=$false})})
    $password=& $module {param($Root,$RunId) Get-LabSecret -Path (Join-Path $Root ('runs/'+$RunId)) -Name 'sa-password'} $state $lab.RunId
    if(-not $password){throw 'TLS_LINUX_SECRET_UNAVAILABLE'}
    foreach($phase in $phases){
        New-TlsLinuxPolicyBudget $context
        if($phase.Name -ceq 'expired'){$leaves.expired=New-TlsLinuxLeafFixture $context $issuer expired}
        Set-TlsLinuxLeafFixture $context $leaves[$phase.Leaf]
        New-TlsLinuxClientFixture $context $phase.Name $package (Join-Path $PSScriptRoot 'Fixtures/TlsLinuxClientProbe.ps1') $caPem
        try{
            if($phase.Name -ceq 'expired'){$expiryEpoch=Get-TlsLinuxSqlProcessEpoch $context}
            foreach($case in $phase.Cases){
                if($case.Name -ceq 'EXPIRED'){
                    $end=[DateTimeOffset]::Parse($leaves.expired.NotAfterUtc).AddSeconds(2)
                    $clock=[Diagnostics.Stopwatch]::StartNew()
                    while([DateTimeOffset]::UtcNow -lt $end){
                        if($clock.Elapsed.TotalSeconds -gt 310 -or [DateTimeOffset]::UtcNow -ge $context.Deadline -or
                            (Test-Path -LiteralPath $context.StopFile)){throw 'TLS_LINUX_EXPIRY_WAIT_BOUNDED_OR_STOPPED'}
                        Start-Sleep -Seconds 2
                    }
                    if((Get-TlsLinuxSqlProcessEpoch $context) -cne $expiryEpoch){throw 'TLS_LINUX_SQL_RESTARTED_DURING_EXPIRY_WAIT'}
                    Write-TlsLinuxProof $context 'actual-expiry-wait.private.json' @{NotAfterUtc=$leaves.expired.NotAfterUtc;ObservedUtc=[DateTimeOffset]::UtcNow.ToString('o');MonotonicSeconds=$clock.Elapsed.TotalSeconds;ClockOverride=$false;SqlProcessEpoch=$expiryEpoch}
                }
                $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
                try{
                    $inputRecord=@{Password=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer);ExpectedBuild=$expected.SqlBuild;Positive=$case.Positive;Trusted=$case.Trusted;TrustServerCertificate=$case.Bypass;CaPemSha256=$caPemHash}
                    $inputText=$inputRecord|ConvertTo-Json -Compress
                }finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
                try{$json=Invoke-TlsLinuxNative $context @('exec','-i','--env','HOME=/tmp','--env','POWERSHELL_TELEMETRY_OPTOUT=1','--env','DOTNET_CLI_TELEMETRY_OPTOUT=1',$context.ClientId,'/opt/tls-client/pwsh/pwsh','-NoLogo','-NoProfile','-File','/opt/tls-client/probe.ps1','-Mode','Pair','-Execute') -InputText $inputText}
                finally{$inputRecord.Password=$null;$inputText=$null}
                $result=Read-TlsLinuxPairResult $json
                if($case.Name -ceq 'EXPIRED' -and [DateTimeOffset]::Parse($result.UtcNow,[Globalization.CultureInfo]::InvariantCulture) -le [DateTimeOffset]::Parse($leaves.expired.NotAfterUtc,[Globalization.CultureInfo]::InvariantCulture)){throw 'TLS_LINUX_EXPIRY_NOT_ACTUAL'}
                if($case.Name -ceq 'EXPIRED' -and (Get-TlsLinuxSqlProcessEpoch $context) -cne $expiryEpoch){throw 'TLS_LINUX_SQL_RESTARTED_DURING_EXPIRED_PROBES'}
                $results.Add(@{Case=$case.Name;Status='PASS';Leaf=$phase.Leaf;Clients=$result})
                Write-TlsLinuxProof $context ('case-'+$case.Name+'.private.json') $result
            }
        }finally{Remove-TlsLinuxClientFixture $context}
    }
}catch{$failure=$_.Exception.Message}
finally{
    try{
        if($context.Budget){New-TlsLinuxPolicyBudget $context -Cleanup}
        Remove-TlsLinuxOwnedFixture $context
        $removed=$context.Removed
        if($null -ne $inventoryBefore){
            $inventoryAfter=Get-TlsLinuxInventory $context -Cleanup
            Write-TlsLinuxProof $context 'preservation-after-observed.private.json' @{Resources=$inventoryAfter;AtUtc=[DateTimeOffset]::UtcNow.ToString('o');Comparison='NOT_YET_EVALUATED'}
            foreach($kind in @('containers','volumes','networks')){
                if(($inventoryBefore[$kind] -join "`n") -cne ($inventoryAfter[$kind] -join "`n")){throw 'TLS_LINUX_PREEXISTING_RESOURCE_INVENTORY_CHANGED'}
            }
            foreach($entry in $fileBaseline){
                if((Get-Item -LiteralPath $entry.Path).Length -ne $entry.Bytes -or (Get-FileHash -LiteralPath $entry.Path).Hash -cne $entry.Sha256){throw 'TLS_LINUX_PREEXISTING_FILE_CHANGED'}
            }
            Assert-TlsLinuxPowerShellPackage $package
            $preserved=$true
            Write-TlsLinuxProof $context 'preservation-after.private.json' @{Status='PASS';Files=$fileBaseline.Count;Resources=$inventoryAfter;PackageUnchanged=$true}
        }
    }catch{$cleanupFailure=$_.Exception.Message}
    if($password){$password.Dispose()};if($issuer){$issuer.Dispose()};if($issuerKey){$issuerKey.Dispose()}
    if($held){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
    $terminal=@{Status=$(if(-not $failure -and -not $cleanupFailure -and $removed -and $preserved -and $results.Count -eq 9){'PASS'}else{'FAIL'});Failure=$failure;CleanupFailure=$cleanupFailure;Removed=$removed;Preserved=$preserved;Results=$results.ToArray();Provider=$Provider;Version=$Version;ExpectedBuild=$expected.SqlBuild;Commands=$context.Commands;RunId=$context.Run.RunId;StateRoot=$state;AtUtc=[DateTimeOffset]::UtcNow.ToString('o');PublicLinuxQualification='NOT_CLAIMED';WireFingerprint='NOT_OBSERVED'}
    Write-TlsLinuxProof $context 'terminal.private.json' $terminal
}
if($terminal.Status -cne 'PASS'){throw 'TLS_LINUX_ACCEPTANCE_FAILED_SEE_PRIVATE_TERMINAL'}
$terminal|Select-Object Status,Provider,Version,ExpectedBuild,Removed,Commands
