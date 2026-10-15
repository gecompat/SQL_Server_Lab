# Interner IS-only-Vertrag; keine SSISDB- oder Packagefreigabe.
function Assert-LabSsisEvidenceLocation {
    [CmdletBinding()]
    param([string]$StateRoot,[string]$RepositoryRoot)
    $root=[IO.Path]::GetFullPath($StateRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $repository=[IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if($root.Equals($repository,$comparison) -or $root.StartsWith($repository+[IO.Path]::DirectorySeparatorChar,$comparison)){throw 'SSIS_INSTALL_EVIDENCE_OUTSIDE_CHECKOUT_REQUIRED'}
}

function New-LabSsisLocalFailure {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Failure,[Parameter(Mandatory)][string]$LogPath)
    $diagnosticFailed=$false
    try {
        $Failure | Out-String | Add-Content -LiteralPath $LogPath -ErrorAction Stop
        foreach($name in @('OperationId','PrimaryFailure','CleanupFailure')){
            $Failure.Exception.Data[$name] | Out-String | Add-Content -LiteralPath $LogPath -ErrorAction Stop
        }
    }catch{$diagnosticFailed=$true}
    $exception=[InvalidOperationException]::new('SSIS_INSTALL_ACCEPTANCE_FAILED')
    $exception.Data['PrimaryFailure']=if($Failure.Exception.Data['PrimaryFailure'] -or -not $Failure.Exception.Data['CleanupFailure']){'SSIS_INSTALL_OPERATION_FAILED'}else{$null}
    $exception.Data['CleanupFailure']=if($Failure.Exception.Data['CleanupFailure']){'SSIS_INSTALL_CLEANUP_FAILED'}else{$null}
    $exception.Data['RecoveryRequired']=[bool]$Failure.Exception.Data['RecoveryRequired']
    $exception.Data['EvidenceFailure']=if($diagnosticFailed){'SSIS_INSTALL_DIAGNOSTIC_WRITE_FAILED'}else{$null}
    return $exception
}

function Assert-LabSsisInstallBinding {
    [CmdletBinding()]
    param($Lab,$Managed,[string]$OperationId,[string]$Sha256,[guid]$VmId,[string]$SqlVersion,[string]$MediaEdition,[string[]]$Features)
    if ($OperationId -cnotmatch '^ssis-install-[a-f0-9]{32}$' -or $Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $VmId -eq [guid]::Empty -or
        $SqlVersion -cne '2025' -or $MediaEdition -cne 'Enterprise' -or
        (@($Features | Sort-Object -Unique) -join ',') -cne 'IS,SQLENGINE' -or $Features.Count -ne 2) { throw 'SSIS_INSTALL_CONTRACT_INVALID' }
    if (-not $Lab -or -not $Managed -or [string]$Lab.Run.metadata.workflowOperationId -cne $OperationId -or
        [string]$Lab.Run.metadata.workflowKind -cne 'hyperv-lab' -or [string]$Lab.Instance.provider -cne 'hyperv' -or
        [string]$Lab.Instance.vmId -ne $VmId.ToString() -or [string]$Managed.VM.Id -ne $VmId.ToString() -or
        [string]$Lab.Instance.workload -cne 'windows' -or [string]$Lab.Instance.windowsProvisioning.state -cne 'COMPLETE' -or
        [string]$Managed.VM.State -cne 'Off') { throw 'SSIS_INSTALL_TARGET_INVALID' }
}

function Open-LabSsisApprovedMedia {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MediaRoot,[Parameter(Mandatory)][string]$SqlMediaPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSha256)
    $media=Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion 2025 -MediaEdition Enterprise -SqlMediaPath $SqlMediaPath
    if ($media.HashStatus -cne 'SIDECAR_READY' -or $media.ExpectedSha256 -ine $ExpectedSha256) { throw 'SSIS_INSTALL_MEDIA_APPROVAL_MISMATCH' }
    $null=Assert-LabDiagnosticPath -Path $media.IsoPath
    $stream=$null
    try {
        # Keep this handle through setup: Windows denies replacement/writes while mounted.
        $stream=[IO.FileStream]::new($media.IsoPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $algorithm=[Security.Cryptography.SHA256]::Create()
        try {$hash=[Convert]::ToHexString($algorithm.ComputeHash($stream))}finally{$algorithm.Dispose()}
        if ($hash -ine $ExpectedSha256) { throw 'SSIS_INSTALL_MEDIA_HASH_MISMATCH' }
        return [pscustomobject]@{Media=$media;Handle=$stream;Sha256=$hash.ToLowerInvariant()}
    } catch {if($stream){$stream.Dispose()};throw}
}

function Get-LabSsisSetupArguments {
    [CmdletBinding()]
    param()
    @('/UpdateEnabled=False','/USEMICROSOFTUPDATE=False','/ISSVCACCOUNT="NT AUTHORITY\NETWORK SERVICE"','/ISSVCStartupType=Automatic')
}

# Installs only the Integration Services server feature into an already bound
# SQL-2025 Hyper-V run.  It deliberately does not reuse the fresh SQL-engine
# plan: the normal path must keep its prepared SQL slot and must not reinstall
# the engine merely to add SSIS.
function Get-LabSsisComponentGuestInstall {
    [CmdletBinding()]
    param()
    return {
        param([string]$ExpectedSetupVersionPattern,[int]$TimeoutSeconds,[string]$OperationId)
        $ErrorActionPreference='Stop'
        if($OperationId -cnotmatch '^ssis-component-[a-f0-9]{32}$'){throw 'SSIS_COMPONENT_OPERATION_INVALID'}
        $stage='MEDIA_DISCOVERY'
        try {
            $setups=@()
            $mediaDeadline=[datetime]::UtcNow.AddSeconds([math]::Min(120,[math]::Max(15,$TimeoutSeconds)))
            do {
                $setups=@(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object {
                    $candidate=Join-Path ([string]$_.DeviceID+'\\') 'setup.exe'
                    if(Test-Path -LiteralPath $candidate -PathType Leaf){Get-Item -LiteralPath $candidate}
                } | Where-Object {[string]$_.VersionInfo.FileVersion -match $ExpectedSetupVersionPattern})
                if($setups.Count -eq 1){break}
                Start-Sleep -Seconds 2
            } while([datetime]::UtcNow -lt $mediaDeadline)
            if($setups.Count -ne 1){throw "SSIS_COMPONENT_MEDIA_NOT_UNIQUE: $($setups.Count)"}
            # PowerShell Direct jobs on persistent hosts may have a short operation
            # limit.  It therefore starts a bounded, owned guest worker and returns;
            # the host polls its small status record with separate short calls.
            $stage='SETUP_START'
            $arguments=@('/Q','/ACTION=Install','/FEATURES=IS','/INSTANCENAME=MSSQLSERVER',
                '/IACCEPTSQLSERVERLICENSETERMS','/INDICATEPROGRESS','/UpdateEnabled=False',
                '/USEMICROSOFTUPDATE=False','/ISSVCACCOUNT="NT AUTHORITY\NETWORK SERVICE"',
                '/ISSVCStartupType=Automatic')
            $root=Join-Path $env:ProgramData 'SqlServerLab\SsisOperations'
            $null=New-Item -ItemType Directory -Force -Path $root
            $configPath=Join-Path $root ($OperationId+'.json');$workerPath=Join-Path $root ($OperationId+'.ps1')
            $statusPath=Join-Path $root ($OperationId+'.status.json')
            foreach($path in @($configPath,$workerPath,$statusPath)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force -ErrorAction Stop}}
            $config=[ordered]@{OperationId=$OperationId;SetupPath=$setups[0].FullName;Arguments=$arguments;StatusPath=$statusPath}
            [IO.File]::WriteAllText($configPath,($config|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
            $worker=@'
param([Parameter(Mandatory)][string]$ConfigPath)
$ErrorActionPreference='Stop'
$config=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
$result=[ordered]@{OperationId=[string]$config.OperationId;State='FAILED';ErrorCode='SSIS_COMPONENT_WORKER_FAILED';RebootRequired=$false}
try {
    $process=Start-Process -FilePath ([string]$config.SetupPath) -ArgumentList @($config.Arguments) -PassThru -ErrorAction Stop
    $process.WaitForExit()
    if($process.ExitCode -in @(0,3010)){$result.State='SUCCEEDED';$result.ErrorCode='NONE';$result.RebootRequired=($process.ExitCode -eq 3010)}else{$result.ErrorCode='SSIS_COMPONENT_SETUP_FAILED'}
} catch {$result.ErrorCode='SSIS_COMPONENT_WORKER_FAILED'}
finally {
    $temporary=([string]$config.StatusPath)+'.tmp'
    [IO.File]::WriteAllText($temporary,($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination ([string]$config.StatusPath) -Force
}
'@
            [IO.File]::WriteAllText($workerPath,$worker,[Text.UTF8Encoding]::new($false))
            $launcher=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$workerPath,'-ConfigPath',$configPath) -PassThru -WindowStyle Hidden -ErrorAction Stop
            if(-not $launcher){throw 'SSIS_COMPONENT_SETUP_START_FAILED'}
            [pscustomobject]@{Status='SSIS_COMPONENT_INSTALL_LAUNCHED';OperationId=$OperationId}
        }
        catch {
            $message=[string]$_.Exception.Message
            if($message -match '^SSIS_COMPONENT_'){throw $message}
            throw ('SSIS_COMPONENT_GUEST_FAILURE:{0}' -f $stage)
        }
    }
}

function Get-LabSsisComponentGuestInstallStatus {
    [CmdletBinding()]
    param()
    return {
        param([string]$OperationId)
        $ErrorActionPreference='Stop'
        if($OperationId -cnotmatch '^ssis-component-[a-f0-9]{32}$'){throw 'SSIS_COMPONENT_OPERATION_INVALID'}
        $path=Join-Path (Join-Path $env:ProgramData 'SqlServerLab\SsisOperations') ($OperationId+'.status.json')
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return [pscustomobject]@{OperationId=$OperationId;State='RUNNING';ErrorCode='NONE';RebootRequired=$false}}
        $status=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
        if([string]$status.OperationId -cne $OperationId -or [string]$status.State -notin @('SUCCEEDED','FAILED')){throw 'SSIS_COMPONENT_STATUS_INVALID'}
        [pscustomobject]@{OperationId=$OperationId;State=[string]$status.State;ErrorCode=[string]$status.ErrorCode;RebootRequired=[bool]$status.RebootRequired}
    }
}

function Remove-LabSsisComponentGuestOperation {
    [CmdletBinding()]
    param()
    return {
        param([string]$OperationId)
        $ErrorActionPreference='Stop'
        if($OperationId -cnotmatch '^ssis-component-[a-f0-9]{32}$'){throw 'SSIS_COMPONENT_OPERATION_INVALID'}
        $root=Join-Path $env:ProgramData 'SqlServerLab\SsisOperations'
        foreach($suffix in @('.json','.ps1','.status.json')){Remove-Item -LiteralPath (Join-Path $root ($OperationId+$suffix)) -Force -ErrorAction SilentlyContinue}
        [pscustomobject]@{OperationId=$OperationId;Status='REMOVED'}
    }
}

function Install-LabSsisExistingComponent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$SqlMediaPath,
        [Parameter(Mandatory)][string]$ExpectedSqlMediaSha256,
        [Parameter(Mandatory)][string]$StateRoot,
        [ValidateRange(300,3600)][int]$SetupTimeoutSeconds=1800
    )
    if(-not $IsWindows){throw 'SSIS_COMPONENT_WINDOWS_REQUIRED'}
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'SSIS_COMPONENT_ELEVATION_REQUIRED'}
    $context=Get-LabSsisPrerequisiteContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    $preflight=Invoke-LabSsisPrerequisite -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot -TimeoutSeconds 60
    if([string]$preflight.Sql -ne 'SQL_2025_OBSERVED'){throw 'SSIS_COMPONENT_SQL_2025_REQUIRED'}
    if([string]$preflight.DefaultPathComponents -eq 'OBSERVED'){
        return [pscustomobject]@{RunId=$RunId.ToString();InstanceId=$InstanceId;Status='ALREADY_INSTALLED';EngineMajor=17;SsisMajor=17;Cleanup='REMOVE_RUN_TO_CLEANUP'}
    }
    if([string]$preflight.DefaultPathComponents -ne 'NOT_OBSERVED'){throw ('SSIS_COMPONENT_PREREQUISITE_INCONCLUSIVE:{0}:{1}' -f [string]$preflight.DefaultPathComponents,[string]$preflight.ReasonCode)}
    $media=$null;$guest=$null;$addedDvd=$null;$progress=$null;$primaryFailure=$null;$guestOperationStarted=$false
    $operationId='ssis-component-'+[guid]::NewGuid().ToString('N')
    try {
        $media=Open-LabSsisApprovedMedia -MediaRoot $MediaRoot -SqlMediaPath $SqlMediaPath -ExpectedSha256 $ExpectedSqlMediaSha256
        $null=Confirm-HyperVSqlInstallationMediaVersion -IsoPath $media.Media.IsoPath -SqlVersion 2025
        # The target has already passed ownership binding above. Reconcile its
        # lifecycle through the owned-run path, then tolerate Hyper-V's short
        # Start-VM state transition before attaching installation media.
        $null=Start-HyperVLabEnvironment -RunId $RunId.ToString() -SkipWindowsActivationReconcile -StateRoot $StateRoot
        $managed=$null
        $vmStartDeadline=[datetime]::UtcNow.AddSeconds(60)
        do {
            $managed=Get-HyperVManagedVM -VMName ([string]$context.Instance.vmName) -ExpectedRunId $RunId.ToString() -ExpectedScopeId ([string]$context.Run.scopeId)
            if($managed -and [string]$managed.VM.Id -ne [string]$context.Instance.vmId){throw 'SSIS_COMPONENT_VM_BINDING_INVALID'}
            if($managed -and [string]$managed.VM.State -eq 'Running'){break}
            Start-Sleep -Seconds 2
        } while([datetime]::UtcNow -lt $vmStartDeadline)
        if(-not $managed){throw 'SSIS_COMPONENT_VM_BINDING_UNAVAILABLE'}
        if([string]$managed.VM.Id -ne [string]$context.Instance.vmId){throw 'SSIS_COMPONENT_VM_BINDING_INVALID'}
        if([string]$managed.VM.State -ne 'Running'){throw ('SSIS_COMPONENT_VM_START_TIMEOUT:{0}' -f [string]$managed.VM.State)}
        $existing=@(Get-VMDvdDrive -VM $managed.VM -ErrorAction Stop | Where-Object {[string]$_.Path -eq [string]$media.Media.IsoPath}) | Select-Object -First 1
        if(-not $existing){$addedDvd=Add-VMDvdDrive -VM $managed.VM -Path $media.Media.IsoPath -ErrorAction Stop}
        $guest=Get-LabSecret -Path $context.Directory -Name 'guest-administrator-password'
        if(-not $guest){throw 'SSIS_COMPONENT_GUEST_CREDENTIAL_REQUIRED'}
        $credential=[PSCredential]::new('Administrator',$guest)
        $progress=Start-LabBlockingActionProgress -Phase GuestWait
        $launched=@(Invoke-HyperVPowerShellDirect -VMName ([string]$context.Instance.vmName) -ExpectedRunId $RunId.ToString() `
            -ExpectedScopeId ([string]$context.Run.scopeId) -ExpectedVmId ([guid]$context.Instance.vmId) -Credential $credential `
            -ScriptBlock (Get-LabSsisComponentGuestInstall) -ArgumentList @((Get-HyperVSqlSetupVersionPattern -SqlVersion '2025'),$SetupTimeoutSeconds,$operationId) `
            -Progress $progress.Progress -TimeoutSeconds 180 -ErrorAction Stop)
        if($launched.Count -ne 1 -or [string]$launched[0].Status -ne 'SSIS_COMPONENT_INSTALL_LAUNCHED' -or [string]$launched[0].OperationId -ne $operationId){throw 'SSIS_COMPONENT_LAUNCH_INVALID'}
        $guestOperationStarted=$true
        $deadline=[datetime]::UtcNow.AddSeconds($SetupTimeoutSeconds);$result=$null
        do {
            Start-Sleep -Seconds 10
            $status=@(Invoke-HyperVPowerShellDirect -VMName ([string]$context.Instance.vmName) -ExpectedRunId $RunId.ToString() `
                -ExpectedScopeId ([string]$context.Run.scopeId) -ExpectedVmId ([guid]$context.Instance.vmId) -Credential $credential `
                -ScriptBlock (Get-LabSsisComponentGuestInstallStatus) -ArgumentList @($operationId) -Progress $progress.Progress -TimeoutSeconds 60 -ErrorAction Stop)
            if($status.Count -ne 1 -or [string]$status[0].OperationId -ne $operationId){throw 'SSIS_COMPONENT_STATUS_INVALID'}
            if([string]$status[0].State -eq 'SUCCEEDED'){$result=$status[0];break}
            if([string]$status[0].State -eq 'FAILED'){throw ('SSIS_COMPONENT_SETUP_FAILED:{0}' -f [string]$status[0].ErrorCode)}
        } while([datetime]::UtcNow -lt $deadline)
        if(-not $result){throw 'SSIS_COMPONENT_SETUP_TIMEOUT'}
        $managed=Get-HyperVManagedVM -VMName ([string]$context.Instance.vmName) -ExpectedRunId $RunId.ToString() -ExpectedScopeId ([string]$context.Run.scopeId)
        if(-not $managed -or [string]$managed.VM.Id -ne [string]$context.Instance.vmId){throw 'SSIS_COMPONENT_RESTART_BINDING_INVALID'}
        $null=Restart-VM -VM $managed.VM -Force -ErrorAction Stop
        $ready=Wait-HyperVPowerShellDirect -VMName ([string]$context.Instance.vmName) -ExpectedRunId $RunId.ToString() `
            -ExpectedScopeId ([string]$context.Run.scopeId) -Credential $credential -TimeoutSeconds 600
        if(-not $ready.Ready){throw 'SSIS_COMPONENT_RESTART_NOT_READY'}
        $verified=@(Invoke-HyperVPowerShellDirect -VMName ([string]$context.Instance.vmName) -ExpectedRunId $RunId.ToString() `
            -ExpectedScopeId ([string]$context.Run.scopeId) -ExpectedVmId ([guid]$context.Instance.vmId) -Credential $credential `
            -ScriptBlock (Get-LabSsisInstallGuestProbe) -TimeoutSeconds 120 -ErrorAction Stop)
        if($verified.Count -ne 1 -or [string]$verified[0].Status -ne 'IS_COMPONENTS_AND_SQL_VERIFIED'){throw 'SSIS_COMPONENT_POSTCONDITION_FAILED'}
        $receipt=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.SsisComponent/1.0';RunId=$RunId.ToString();InstanceId=$InstanceId;OperationId=$operationId;Status='INSTALLED_AND_RESTART_VERIFIED';EngineMajor=17;SsisMajor=17;MediaSha256=$media.Sha256;Cleanup='REMOVE_RUN_TO_CLEANUP'}
        Write-LabArtifactJsonAtomic -Path (Join-Path $context.Directory 'ssis-component-receipt.json') -InputObject $receipt
        return $receipt
    }
    catch {
        $primaryFailure=$_
        throw
    }
    finally {
        if($guestOperationStarted -and $guest){
            try {
                $credential=[PSCredential]::new('Administrator',$guest)
                $null=Invoke-HyperVPowerShellDirect -VMName ([string]$context.Instance.vmName) -ExpectedRunId $RunId.ToString() `
                    -ExpectedScopeId ([string]$context.Run.scopeId) -ExpectedVmId ([guid]$context.Instance.vmId) -Credential $credential `
                    -ScriptBlock (Remove-LabSsisComponentGuestOperation) -ArgumentList @($operationId) -TimeoutSeconds 60 -ErrorAction Stop
            } catch {if(-not $primaryFailure){throw 'SSIS_COMPONENT_OPERATION_CLEANUP_FAILED'}}
        }
        if($addedDvd){
            try { Remove-VMDvdDrive -VMDvdDrive $addedDvd -ErrorAction Stop }
            catch {
                if($primaryFailure){ $primaryFailure.Exception.Data['CleanupFailure']='SSIS_COMPONENT_MEDIA_DETACH_FAILED' }
                else { throw 'SSIS_COMPONENT_MEDIA_DETACH_FAILED' }
            }
        }
        if($progress){Stop-LabBlockingActionProgress -Handle $progress}
        if($guest){$guest.Dispose()}
        if($media){$media.Handle.Dispose()}
    }
}

# The normal "new SSIS fixture" path clones a sealed prepared SQL image and
# then invokes the same additive component installer as an existing run.  The
# older OS_SEALED/full-engine routine below remains an installation-chain
# acceptance helper only; it is not a provisioning shortcut.
function Invoke-LabSsisPreparedFixtureRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^hyperv-sql-prepared-sealed-[a-f0-9]{64}$')][string]$ArtifactId,
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$SqlMediaPath,
        [Parameter(Mandatory)][string]$ExpectedSqlMediaSha256,
        [Parameter(Mandatory)][string]$StateRoot,
        [ValidateRange(600,1800)][int]$FixtureTimeoutSeconds=900
    )
    if(-not $IsWindows){throw 'SSIS_FIXTURE_WINDOWS_REQUIRED'}
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'SSIS_COMPONENT_ELEVATION_REQUIRED'}
    $artifact=Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot
    if(-not $artifact -or [string]$artifact.artifactState -ne 'SQL_PREPARED_SEALED' -or
        [string]$artifact.operatingSystem.id -ne 'windows-server-2025' -or [string]$artifact.sql.version -ne '2025' -or
        @($artifact.sql.features | ForEach-Object {[string]$_}) -notcontains 'SQLENGINE' -or
        -not (Test-HyperVImageArtifactEvaluationEligibility -Artifact $artifact).Eligible -or
        -not (Test-HyperVImageArtifactChildValidationEligibility -Artifact $artifact).Eligible){throw 'SSIS_FIXTURE_PREPARED_ARTIFACT_INVALID'}
    $approved=Open-LabSsisApprovedMedia -MediaRoot $MediaRoot -SqlMediaPath $SqlMediaPath -ExpectedSha256 $ExpectedSqlMediaSha256
    $guest=$null;$sa=$null;$manifestPath=$null;$runId=$null
    try {
        $guest=New-HyperVSqlUnattendedPassword
        $sa=New-HyperVSqlUnattendedPassword
        $manifestPath=Join-Path ([IO.Path]::GetTempPath()) ('sql-server-lab-ssis-'+[guid]::NewGuid().ToString('N')+'.json')
        $manifest=[ordered]@{name='ssis-prepared-fixture';instances=@([ordered]@{
            id='primary';version='2025';provider='hyperv';os='windows';profile='standard'
            windowsActivation=[ordered]@{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='NotRequested';EgressPolicy='Denied'}
            hyperv=[ordered]@{preparedImageId=$ArtifactId;memoryStartupMB=4096;processorCount=2;autostart='off';guestPasswordMode='prompt'}
        })}
        [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
        $created=New-SqlServerLab -Manifest $manifestPath -GuestPassword $guest -SqlSaPassword $sa -NonInteractive -StateRoot $StateRoot
        $runId=[guid]$created.RunId
        # Prepared runs honour autostart=off after readiness; the additive guest installer needs an owned running VM.
        # New-SqlServerLab already performed the one permitted activation reconciliation.
        # A second reconciliation can resume-and-stop an autostart=off run, so the installer only starts the bound VM.
        $null=Start-HyperVLabEnvironment -RunId $runId.ToString() -SkipWindowsActivationReconcile -StateRoot $StateRoot
        # Start-VM returns while Hyper-V can still report the owned VM as Starting.
        # Wait only for that immutable, bound state before attaching approved media;
        # guest readiness remains the installer's separate PowerShell-Direct gate.
        $startedLab=Get-HyperVLabWorkflowRun -RunId $runId.ToString() -StateRoot $StateRoot
        $vmStartDeadline=[datetime]::UtcNow.AddSeconds(60)
        do {
            $started=Get-HyperVManagedVM -VMName ([string]$startedLab.Instance.vmName) `
                -ExpectedRunId $runId.ToString() -ExpectedScopeId ([string]$startedLab.Run.scopeId)
            if($started -and [string]$started.VM.State -eq 'Running'){break}
            Start-Sleep -Seconds 2
        } while([datetime]::UtcNow -lt $vmStartDeadline)
        if(-not $started -or [string]$started.VM.State -ne 'Running'){throw 'SSIS_FIXTURE_VM_START_TIMEOUT'}
        Write-LabInfo 'SSIS-Fixture: beginne additive IS-Komponenteninstallation im gebundenen Prepared-Run (Budget: 1800 Sekunden).'
        $component=Install-LabSsisExistingComponent -RunId $runId -InstanceId 'primary' -MediaRoot $MediaRoot -SqlMediaPath $SqlMediaPath `
            -ExpectedSqlMediaSha256 $ExpectedSqlMediaSha256 -StateRoot $StateRoot -SetupTimeoutSeconds 1800
        if([string]$component.Status -notin @('INSTALLED_AND_RESTART_VERIFIED','ALREADY_INSTALLED')){throw 'SSIS_FIXTURE_COMPONENT_RESULT_INVALID'}
        Write-LabInfo 'SSIS-Fixture: IS-Komponente verifiziert; erstelle nun den eigenen SSISDB-Katalog und die drei Ausführungen (Budget: 900 Sekunden).'
        $fixture=Invoke-LabSsisExistingCatalogFixture -RunId $runId -InstanceId 'primary' -StateRoot $StateRoot -FixtureTimeoutSeconds 900
        $fixture | Add-Member -NotePropertyName SourceBinding -NotePropertyValue 'OWNED_PREPARED_HYPERV_RUN' -Force
        return $fixture
    }
    catch {
        $primaryFailure=$_
        if($runId){
            try { $null=Remove-SqlServerLab -RunId $runId -StateRoot $StateRoot -Force -Confirm:$false }
            catch { $primaryFailure.Exception.Data['CleanupFailure']='SSIS_FIXTURE_RUN_CLEANUP_FAILED' }
        }
        throw $primaryFailure
    }
    finally {
        if($approved){$approved.Handle.Dispose()}
        if($guest){$guest.Dispose()};if($sa){$sa.Dispose()}
        if($manifestPath -and (Test-Path -LiteralPath $manifestPath)){Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue}
    }
}

function Invoke-LabSsisOwnedTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Arrange,[Parameter(Mandatory)][scriptblock]$Verify,
        [Parameter(Mandatory)][scriptblock]$Cleanup,[switch]$RetainOnSuccess)
    $primary=$null;$cleanupFailure=$null;$result=$null;$verification=$null
    try {$result=& $Arrange;$verification=& $Verify $result} catch {$primary=$_}
    finally {if($primary -or -not $RetainOnSuccess){try {& $Cleanup | Out-Null}catch {$cleanupFailure=$_}}}
    if ($primary -or $cleanupFailure) {
        $failure=[InvalidOperationException]::new('SSIS_INSTALL_ACCEPTANCE_FAILED')
        # Raw exceptions remain local for the caller; never emit them into CI summaries.
        $failure.Data['PrimaryFailure']=$primary
        $failure.Data['CleanupFailure']=$cleanupFailure
        $failure.Data['RecoveryRequired']=[bool]$cleanupFailure
        throw $failure
    }
    if($null -ne $verification){return $verification}
    return [pscustomobject]@{Status='IS_INSTALL_AND_RESTART_PASSED';Cleanup='CLEANUP_SUCCEEDED';SsisDb='NOT_PROVISIONED';Etl='NOT_EXECUTED'}
}

function Get-LabSsisInstallGuestProbe {
    [CmdletBinding()]
    param()
    return {
        $ErrorActionPreference='Stop'
        function Read-SsisInstalledSql {
            param($Connection)
            $command=$null;$reader=$null
            try {
                $command=$Connection.CreateCommand();$command.CommandTimeout=30
                $command.CommandText="SELECT CONVERT(int,SERVERPROPERTY('ProductMajorVersion')),CONVERT(nvarchar(128),SERVERPROPERTY('Edition')),IS_SRVROLEMEMBER(N'sysadmin'),(SELECT COUNT(*) FROM sys.databases WHERE name=N'SSISDB');"
                $reader=$command.ExecuteReader()
                if (-not $reader.Read() -or $reader.GetInt32(0) -ne 17 -or
                    $reader.GetString(1) -cnotmatch '^(Enterprise )?Developer Edition \(64-bit\)$' -or $reader.GetInt32(2) -ne 1 -or $reader.GetInt32(3) -ne 0) { throw 'SSIS_INSTALL_SQL_POSTCONDITION' }
                if ($reader.Read() -or $reader.NextResult()) { throw 'SSIS_INSTALL_SQL_POSTCONDITION' }
            } finally {if($reader){$reader.Dispose()};if($command){$command.Dispose()}}
        }
        $service=Get-Service -Name MsDtsServer170 -ErrorAction Stop
        # Setup can complete before the freshly installed service has finished
        # auto-starting after the required reboot. Start it through the local
        # service controller and wait within the bounded guest probe instead of
        # treating that transient state as a failed installation.
        if($service.Status -ne 'Running'){
            try {
                $service.Start()
                $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromMinutes(5))
            } catch { throw 'SSIS_INSTALL_SERVICE_START_FAILED' }
        }
        $path=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Microsoft SQL Server/170/DTS/Binn/MsDtsSrvr.exe'
        $file=Get-Item -LiteralPath $path -ErrorAction Stop
        if ($service.Status -ne 'Running' -or $file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            [int]$file.VersionInfo.FileMajorPart -ne 17) { throw 'SSIS_INSTALL_COMPONENT_POSTCONDITION' }
        $connection=[Data.SqlClient.SqlConnection]::new('Data Source=localhost;Initial Catalog=master;Integrated Security=SSPI;Connect Timeout=15;Encrypt=False;Pooling=False')
        try {
            $connection.Open();Read-SsisInstalledSql -Connection $connection
            [pscustomobject]@{Status='IS_COMPONENTS_AND_SQL_VERIFIED';BootTime=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')}
        } finally {$connection.Dispose()}
    }
}

# Runs only inside the fresh, operation-owned guest after SQLENGINE and IS are installed.
# It restores the SSISDB template shipped by that same IS installation; no SDK, download,
# build tool, or external data source participates in the fixture.
function Get-LabSsisCatalogFixtureGuestProbe {
    [CmdletBinding()]
    param()
    return {
        param([string]$OperationId,[bool]$RetainFolder=$false)
        $ErrorActionPreference='Stop'
        if ($OperationId -cnotmatch '^ssis-install-[a-f0-9]{32}$') { throw 'SSIS_FIXTURE_OPERATION_INVALID' }
        $token=$OperationId.Substring($OperationId.Length-12)
        $folder="LabFixture_$token";$project="LabProject_$token"
        $temporary=Join-Path ([IO.Path]::GetTempPath()) "SqlServerLab-Ssis-$token"
        $connection=$null;$catalogConnection=$null;$folderCreated=$false;$accepted=$false
        try {
            $null=New-Item -ItemType Directory -Path $temporary -ErrorAction Stop
            $connection=[Data.SqlClient.SqlConnection]::new('Data Source=localhost;Initial Catalog=master;Integrated Security=SSPI;Connect Timeout=30;Encrypt=False;Pooling=False')
            $connection.Open()
            $command=$connection.CreateCommand();$command.CommandTimeout=180
            try {
                $command.CommandText="SELECT CONVERT(int,SERVERPROPERTY('ProductMajorVersion')), (SELECT COUNT(*) FROM sys.databases WHERE name=N'SSISDB');"
                $reader=$command.ExecuteReader();try {
                    if(-not $reader.Read() -or $reader.GetInt32(0) -ne 17){throw 'SSIS_FIXTURE_ENGINE_INVALID'}
                    $catalogExists=$reader.GetInt32(1) -eq 1
                }finally{$reader.Dispose()}
            }finally{$command.Dispose()}
            if(-not $catalogExists){
                $ssisBinn=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Microsoft SQL Server/170/DTS/Binn'
                $catalogBackup=Join-Path $ssisBinn 'SSISDBBackup.bak'
                $serverAssembly=Join-Path $ssisBinn 'Microsoft.SqlServer.IntegrationServices.Server.dll'
                foreach($path in @($catalogBackup,$serverAssembly)){
                    $file=Get-Item -LiteralPath $path -ErrorAction Stop
                    if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'SSIS_FIXTURE_INSTALLED_CATALOG_MEDIA_INVALID'}
                }
                function Escape-SsisSqlLiteral {param([string]$Value) $Value.Replace("'","''")}
                function Invoke-SsisMasterNonQuery {param([string]$Text,[int]$Timeout=300)
                    $cmd=$connection.CreateCommand();$cmd.CommandTimeout=$Timeout;$cmd.CommandText=$Text
                    try{$null=$cmd.ExecuteNonQuery()}finally{$cmd.Dispose()}
                }
                $backupLiteral=Escape-SsisSqlLiteral $catalogBackup
                $files=@();$cmd=$connection.CreateCommand();$cmd.CommandTimeout=120;$cmd.CommandText="RESTORE FILELISTONLY FROM DISK=N'$backupLiteral';"
                try {
                    $reader=$cmd.ExecuteReader();try{while($reader.Read()){$files+=,[pscustomobject]@{LogicalName=[string]$reader['LogicalName'];Type=[string]$reader['Type']}}}finally{$reader.Dispose()}
                }finally{$cmd.Dispose()}
                $dataLogical=@($files|Where-Object {$_.Type -ceq 'D'});$logLogical=@($files|Where-Object {$_.Type -ceq 'L'})
                if($dataLogical.Count -ne 1 -or $logLogical.Count -ne 1){throw 'SSIS_FIXTURE_INSTALLED_CATALOG_LAYOUT_INVALID'}
                $cmd=$connection.CreateCommand();$cmd.CommandTimeout=30;$cmd.CommandText='SELECT physical_name,type FROM master.sys.master_files WHERE database_id=1 AND type IN (0,1);'
                $paths=@();try{$reader=$cmd.ExecuteReader();try{while($reader.Read()){$paths+=,[pscustomobject]@{Path=[string]$reader.GetString(0);Type=[Convert]::ToInt32($reader.GetValue(1),[Globalization.CultureInfo]::InvariantCulture)}}}finally{$reader.Dispose()}}finally{$cmd.Dispose()}
                $dataDirectory=Split-Path -Parent ([string](@($paths|Where-Object {$_.Type -eq 0})[0].Path))
                $logDirectory=Split-Path -Parent ([string](@($paths|Where-Object {$_.Type -eq 1})[0].Path))
                if([string]::IsNullOrWhiteSpace($dataDirectory) -or [string]::IsNullOrWhiteSpace($logDirectory)){throw 'SSIS_FIXTURE_DEFAULT_PATHS_INVALID'}
                $dataFileLiteral=Escape-SsisSqlLiteral (Join-Path $dataDirectory 'SSISDB.mdf')
                $logFileLiteral=Escape-SsisSqlLiteral (Join-Path $logDirectory 'SSISDB_log.ldf')
                $dataLogicalLiteral=Escape-SsisSqlLiteral $dataLogical[0].LogicalName
                $logLogicalLiteral=Escape-SsisSqlLiteral $logLogical[0].LogicalName
                # SQL Server requires the CLR trust principal before an SSISDB backup is restored.
                # Keeping this before RESTORE also follows the documented first-catalog restore order.
                $assemblyLiteral=Escape-SsisSqlLiteral $serverAssembly
                Invoke-SsisMasterNonQuery -Text ("EXEC sp_configure 'clr enabled',1; RECONFIGURE; IF NOT EXISTS(SELECT 1 FROM sys.asymmetric_keys WHERE name=N'MS_SQLEnableSystemAssemblyLoadingKey') CREATE ASYMMETRIC KEY [MS_SQLEnableSystemAssemblyLoadingKey] FROM EXECUTABLE FILE=N'$assemblyLiteral'; IF NOT EXISTS(SELECT 1 FROM sys.server_principals WHERE name=N'##MS_SQLEnableSystemAssemblyLoadingUser##') CREATE LOGIN [##MS_SQLEnableSystemAssemblyLoadingUser##] FROM ASYMMETRIC KEY [MS_SQLEnableSystemAssemblyLoadingKey]; GRANT UNSAFE ASSEMBLY TO [##MS_SQLEnableSystemAssemblyLoadingUser##];")
                Invoke-SsisMasterNonQuery -Text ("RESTORE DATABASE [SSISDB] FROM DISK=N'$backupLiteral' WITH MOVE N'$dataLogicalLiteral' TO N'$dataFileLiteral', MOVE N'$logLogicalLiteral' TO N'$logFileLiteral', RECOVERY;") -Timeout 600
                # The template's database master key is encrypted with the documented
                # bootstrap password. Bind it to this instance before compatibility check.
                Invoke-SsisMasterNonQuery -Text "USE [SSISDB]; OPEN MASTER KEY DECRYPTION BY PASSWORD=N'LS1Setup!'; ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY; CLOSE MASTER KEY;"
                Invoke-SsisMasterNonQuery -Text "USE [SSISDB]; EXEC [catalog].[check_schema_version] @use32bitruntime=0;"
            }
            $catalogConnection=[Data.SqlClient.SqlConnection]::new('Data Source=localhost;Initial Catalog=SSISDB;Integrated Security=SSPI;Connect Timeout=30;Encrypt=False;Pooling=False')
            $catalogConnection.Open()
            # The generated packages are intentionally local-only: a blank package succeeds;
            # ForceExecutionResult produces the error case; the third execution remains created.
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $runtimePath=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Microsoft SQL Server/170/DTS/Binn/Microsoft.SqlServer.Dts.Runtime.dll'
            if(-not(Test-Path -LiteralPath $runtimePath)){throw 'SSIS_FIXTURE_RUNTIME_ASSEMBLY_MISSING'}
            Add-Type -Path $runtimePath
            $application=[Microsoft.SqlServer.Dts.Runtime.Application]::new()
            foreach($spec in @(@{Name='Success.dtsx';Failure=$false},@{Name='Failure.dtsx';Failure=$true},@{Name='Incomplete.dtsx';Failure=$false})){
                $package=[Microsoft.SqlServer.Dts.Runtime.Package]::new()
                if($spec.Failure){$package.ForceExecutionResult=[Microsoft.SqlServer.Dts.Runtime.DTSExecResult]::Failure}
                $application.SaveToXml((Join-Path $temporary $spec.Name),$package,$null)
            }
            $projectParameters=Join-Path $temporary 'Project.params'
            [IO.File]::WriteAllText($projectParameters,'<?xml version="1.0" encoding="utf-8"?><SSIS:Parameters xmlns:SSIS="www.microsoft.com/SqlServer/SSIS"></SSIS:Parameters>',[Text.UTF8Encoding]::new($false))
            $ispac=Join-Path $temporary "$project.ispac"
            $archive=[IO.Compression.ZipFile]::Open($ispac,[IO.Compression.ZipArchiveMode]::Create)
            try { foreach($path in @($projectParameters,(Join-Path $temporary 'Success.dtsx'),(Join-Path $temporary 'Failure.dtsx'),(Join-Path $temporary 'Incomplete.dtsx'))){[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$path,[IO.Path]::GetFileName($path))|Out-Null} } finally {$archive.Dispose()}
            function Invoke-FixtureCommand { param([string]$Text,[hashtable]$Parameters=@{})
                $cmd=$catalogConnection.CreateCommand();$cmd.CommandTimeout=180;$cmd.CommandText=$Text
                try {foreach($key in $Parameters.Keys){$value=$Parameters[$key];$parameter=$cmd.Parameters.Add($key,[Data.SqlDbType]::Variant);$parameter.Value=if($null -eq $value){[DBNull]::Value}else{$value}};return $cmd.ExecuteScalar()}finally{$cmd.Dispose()}
            }
            $folderId=Invoke-FixtureCommand -Text 'DECLARE @id bigint; EXEC [catalog].[create_folder] @folder_name=@folder, @folder_id=@id OUTPUT; SELECT @id;' -Parameters @{ '@folder'=$folder }
            if([int64]$folderId -lt 1){throw 'SSIS_FIXTURE_FOLDER_CREATE_FAILED'};$folderCreated=$true
            $bytes=[IO.File]::ReadAllBytes($ispac)
            $deploy=$catalogConnection.CreateCommand();$deploy.CommandTimeout=180
            try {
                $deploy.CommandText='DECLARE @id bigint; EXEC [catalog].[deploy_project] @folder_name=@folder,@project_name=@project,@project_stream=@stream,@operation_id=@id OUTPUT; SELECT @id;'
                $null=$deploy.Parameters.Add('@folder',[Data.SqlDbType]::NVarChar,128);$deploy.Parameters['@folder'].Value=$folder
                $null=$deploy.Parameters.Add('@project',[Data.SqlDbType]::NVarChar,128);$deploy.Parameters['@project'].Value=$project
                $stream=$deploy.Parameters.Add('@stream',[Data.SqlDbType]::VarBinary,-1);$stream.Value=$bytes
                if([int64]$deploy.ExecuteScalar() -lt 1){throw 'SSIS_FIXTURE_PROJECT_DEPLOY_FAILED'}
            } finally {$deploy.Dispose()}
            function New-FixtureExecution {param([string]$Package,[switch]$Start)
                $cmd=$catalogConnection.CreateCommand();$cmd.CommandTimeout=180;$cmd.CommandText='DECLARE @id bigint; EXEC [catalog].[create_execution] @folder_name=@folder,@project_name=@project,@package_name=@package,@reference_id=NULL,@use32bitruntime=0,@execution_id=@id OUTPUT; SELECT @id;'
                try {$null=$cmd.Parameters.Add('@folder',[Data.SqlDbType]::NVarChar,128);$cmd.Parameters['@folder'].Value=$folder;$null=$cmd.Parameters.Add('@project',[Data.SqlDbType]::NVarChar,128);$cmd.Parameters['@project'].Value=$project;$null=$cmd.Parameters.Add('@package',[Data.SqlDbType]::NVarChar,260);$cmd.Parameters['@package'].Value=$Package;$id=[int64]$cmd.ExecuteScalar()}finally{$cmd.Dispose()}
                if($Start){$null=Invoke-FixtureCommand -Text 'EXEC [catalog].[start_execution] @execution_id=@id;' -Parameters @{ '@id'=$id }};return $id
            }
            $success=New-FixtureExecution -Package 'Success.dtsx' -Start
            $failure=New-FixtureExecution -Package 'Failure.dtsx' -Start
            $incomplete=New-FixtureExecution -Package 'Incomplete.dtsx'
            $deadline=[datetime]::UtcNow.AddMinutes(3);$states=@{}
            do {$cmd=$catalogConnection.CreateCommand();$cmd.CommandTimeout=30;$cmd.CommandText='SELECT execution_id,status FROM [catalog].[executions] WHERE execution_id IN (@success,@failure,@incomplete);';try {foreach($name in @('success','failure','incomplete')){$null=$cmd.Parameters.Add('@'+$name,[Data.SqlDbType]::BigInt);$cmd.Parameters['@'+$name].Value=(Get-Variable $name -ValueOnly)};$reader=$cmd.ExecuteReader();try{while($reader.Read()){$states[[string]$reader.GetInt64(0)]=[int]$reader.GetInt32(1)}}finally{$reader.Dispose()}}finally{$cmd.Dispose()};if($states[[string]$success] -in 3,4,6,7,9 -and $states[[string]$failure] -in 3,4,6,7,9){break};Start-Sleep -Milliseconds 500}while([datetime]::UtcNow -lt $deadline)
            if($states[[string]$success] -notin 7,9 -or $states[[string]$failure] -notin 4,6,9 -or $states[[string]$incomplete] -ne 1){throw 'SSIS_FIXTURE_EXECUTION_STATUS_INVALID'}
            $accepted=$true
            [pscustomobject]@{Status='SSISDB_FIXTURE_ACCEPTED';OperationId=$OperationId;EngineMajor=17;SsisMajor=17;ExecutionIds=@{Success=$success;Failure=$failure;Incomplete=$incomplete};ExecutionStatus=@{Success=$states[[string]$success];Failure=$states[[string]$failure];Incomplete=$states[[string]$incomplete]};CatalogViews=@('catalog.executions','catalog.event_messages');Rights='SYSADMIN_OBSERVED';FolderName=$folder;ProjectName=$project;Cleanup=$(if($RetainFolder){'RETAINED_FOR_OWNED_RUN'}else{'CATALOG_FOLDER_CLEANUP_PENDING'})}
        }
        finally {
            if($folderCreated -and (-not $RetainFolder -or -not $accepted) -and $catalogConnection){$cmd=$catalogConnection.CreateCommand();try{$cmd.CommandTimeout=120;$cmd.CommandText='EXEC [catalog].[delete_folder] @folder_name=@folder;';$null=$cmd.Parameters.Add('@folder',[Data.SqlDbType]::NVarChar,128);$cmd.Parameters['@folder'].Value=$folder;$null=$cmd.ExecuteNonQuery()}finally{$cmd.Dispose()}}
            if($catalogConnection){$catalogConnection.Dispose()};if($connection){$connection.Dispose()};if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction Stop}
        }
    }
}

# Erzeugt eine Fixture ausschließlich in einem bereits laufenden, eigenen SQL-2025-Run.
# Die Funktion installiert nichts und akzeptiert keine freien VM-/Endpoint-Angaben.
function Invoke-LabSsisExistingCatalogFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$StateRoot,
        [ValidateRange(600,1800)][int]$FixtureTimeoutSeconds=900
    )
    if(-not $IsWindows){throw 'SSIS_FIXTURE_WINDOWS_REQUIRED'}
    $context=Get-LabSsisPrerequisiteContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    $preflight=Invoke-LabSsisPrerequisite -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot -TimeoutSeconds 60
    if([string]$preflight.Sql -ne 'SQL_2025_OBSERVED'){throw 'SSIS_FIXTURE_SQL_2025_REQUIRED'}
    if([string]$preflight.DefaultPathComponents -ne 'OBSERVED'){throw 'SSIS_FIXTURE_COMPONENTS_NOT_READY'}
    if([string]$preflight.SsisDb -notin @('MISSING','ONLINE_CATALOG_OBSERVED')){throw 'SSIS_FIXTURE_CATALOG_NOT_READY'}
    $guest=$null
    try {
        $guest=Get-LabSecret -Path $context.Directory -Name 'guest-administrator-password'
        if(-not $guest){throw 'SSIS_FIXTURE_GUEST_CREDENTIAL_REQUIRED'}
        $operationId='ssis-install-'+[guid]::NewGuid().ToString('N')
        $result=@(Invoke-HyperVPowerShellDirect -VMName ([string]$context.Instance.vmName) -ExpectedRunId $RunId.ToString() `
            -ExpectedScopeId ([string]$context.Run.scopeId) -ExpectedVmId ([guid]$context.Instance.vmId) `
            -Credential ([PSCredential]::new('Administrator',$guest)) -ScriptBlock (Get-LabSsisCatalogFixtureGuestProbe) `
            -ArgumentList @($operationId,$true) -TimeoutSeconds $FixtureTimeoutSeconds -ErrorAction Stop)
        if($result.Count -ne 1 -or [string]$result[0].Status -ne 'SSISDB_FIXTURE_ACCEPTED' -or
            [string]$result[0].OperationId -ne $operationId){throw 'SSIS_FIXTURE_RESULT_INVALID'}
        $fixture=$result[0]
        $fixture | Add-Member -NotePropertyName RunId -NotePropertyValue $RunId.ToString() -Force
        $fixture | Add-Member -NotePropertyName InstanceId -NotePropertyValue $InstanceId -Force
        $fixture | Add-Member -NotePropertyName SourceBinding -NotePropertyValue 'OWNED_EXISTING_HYPERV_RUN' -Force
        Write-LabArtifactJsonAtomic -Path (Join-Path $context.Directory 'ssis-fixture-receipt.json') -InputObject $fixture
        return $fixture
    }
    finally {if($guest){$guest.Dispose()}}
}

function Remove-LabSsisExistingCatalogFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$StateRoot
    )
    $context=Get-LabSsisPrerequisiteContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    $receiptPath=Join-Path $context.Directory 'ssis-fixture-receipt.json'
    $receipt=Read-LabDiagnosticJson -Path $receiptPath
    $folder=[string]$receipt.FolderName
    if([string]$receipt.RunId -ne $RunId.ToString() -or [string]$receipt.InstanceId -cne $InstanceId -or
        [string]$receipt.SourceBinding -cne 'OWNED_EXISTING_HYPERV_RUN' -or
        [string]$receipt.OperationId -cnotmatch '^ssis-install-[a-f0-9]{32}$' -or
        $folder -cnotmatch '^LabFixture_[a-f0-9]{12}$'){throw 'SSIS_FIXTURE_CLEANUP_BINDING_INVALID'}
    $guest=$null
    try {
        $guest=Get-LabSecret -Path $context.Directory -Name 'guest-administrator-password'
        if(-not $guest){throw 'SSIS_FIXTURE_GUEST_CREDENTIAL_REQUIRED'}
        $result=@(Invoke-HyperVPowerShellDirect -VMName ([string]$context.Instance.vmName) -ExpectedRunId $RunId.ToString() `
            -ExpectedScopeId ([string]$context.Run.scopeId) -ExpectedVmId ([guid]$context.Instance.vmId) `
            -Credential ([PSCredential]::new('Administrator',$guest)) -ArgumentList @($folder) -TimeoutSeconds 120 -ErrorAction Stop -ScriptBlock {
                param($FolderName)
                $connection=[Data.SqlClient.SqlConnection]::new('Data Source=localhost;Initial Catalog=SSISDB;Integrated Security=SSPI;Connect Timeout=30;Encrypt=False;Pooling=False')
                try {$connection.Open();$command=$connection.CreateCommand();try {$command.CommandTimeout=120;$command.CommandText='EXEC [catalog].[delete_folder] @folder_name=@folder;';$null=$command.Parameters.Add('@folder',[Data.SqlDbType]::NVarChar,128);$command.Parameters['@folder'].Value=$FolderName;$null=$command.ExecuteNonQuery();[pscustomobject]@{Status='REMOVED'}}finally{$command.Dispose()}}finally{$connection.Dispose()}
            })
        if($result.Count -ne 1 -or [string]$result[0].Status -ne 'REMOVED'){throw 'SSIS_FIXTURE_CLEANUP_FAILED'}
        Remove-Item -LiteralPath $receiptPath -Force -ErrorAction Stop
        return [pscustomobject]@{RunId=$RunId.ToString();InstanceId=$InstanceId;Status='REMOVED';Cleanup='CATALOG_FOLDER_CLEANUP_SUCCEEDED'}
    }
    finally {if($guest){$guest.Dispose()}}
}

function Remove-LabSsisOperationRun {
    [CmdletBinding()]
    param([string]$OperationId,[string]$StateRoot,[string]$ExpectedRunId,[string]$ExpectedVmId)
    if ($OperationId -cnotmatch '^ssis-install-[a-f0-9]{32}$') {throw 'SSIS_INSTALL_OPERATION_INVALID'}
    $owned=Get-LabOperationOwnedRun -OperationId $OperationId -StateRoot $StateRoot
    if (-not $owned) {return}
    if ([string]$owned.metadata.workflowKind -cne 'hyperv-lab' -or [string]$owned.metadata.workflowOperationId -cne $OperationId -or
        ($ExpectedRunId -and [string]$owned.runId -cne $ExpectedRunId)) {throw 'SSIS_INSTALL_CLEANUP_BINDING'}
    $id=[guid]::Parse([string]$owned.runId);$scope=[guid]::Parse([string]$owned.scopeId)
    if($id -eq [guid]::Empty -or $scope -eq [guid]::Empty){throw 'SSIS_INSTALL_CLEANUP_BINDING'}
    $directory=Join-Path (Join-Path $StateRoot 'runs') $id.ToString()
    $plan=Get-CleanupPlan -RunDir $directory
    if ([string]$plan.runId -cne [string]$owned.runId -or [string]$plan.scopeId -cne [string]$owned.scopeId -or
        @($plan.steps|Where-Object {$_.provider -ne 'hyperv' -or $_.resourceType -notin @('vm','vhdx','ipam-lease')}).Count -gt 0) {throw 'SSIS_INSTALL_CLEANUP_PLAN'}
    $vms=@($plan.steps|Where-Object resourceType -EQ vm)
    if($vms.Count -gt 1){throw 'SSIS_INSTALL_CLEANUP_PLAN'}
    foreach($step in @($plan.steps|Where-Object resourceType -EQ vhdx)){
        if(-not(Test-HyperVPathWithinRunDirectory -Path $step.resourceId -RunDirectory $directory)){throw 'SSIS_INSTALL_CLEANUP_PATH'}
    }
    $ids=@()
    foreach($step in $vms){
        $vm=Get-HyperVManagedVM -VMName ([string]$step.resourceId) -ExpectedRunId $owned.runId -ExpectedScopeId $owned.scopeId
        if($vm){
            if($ExpectedVmId -and [string]$vm.VM.Id -cne $ExpectedVmId){throw 'SSIS_INSTALL_CLEANUP_VM_ID'}
            $ids+=([guid]$vm.VM.Id)
        }
    }
    $result=Remove-SqlServerLab -RunId $owned.runId -StateRoot $StateRoot -Force -Confirm:$false
    if ($result.RunId -ne $owned.runId -or $result.Status -notin @('REMOVED','ALREADY_REMOVED') -or
        $result.Cleanup -notin @('CLEANUP_SUCCEEDED','ALREADY_REMOVED')) {throw 'SSIS_INSTALL_CLEANUP_FAILED'}
    foreach($id in $ids){if(Get-VM -Id $id -ErrorAction SilentlyContinue){throw 'SSIS_INSTALL_CLEANUP_VM_REMAINS'}}
    foreach($step in @($plan.steps|Where-Object resourceType -EQ vhdx)){if(Test-Path -LiteralPath $step.resourceId){throw 'SSIS_INSTALL_CLEANUP_DISK_REMAINS'}}
}

function Invoke-LabSsisOwnedInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^hyperv-os-sealed-[a-f0-9]{64}$')][string]$ArtifactId,
        [Parameter(Mandatory)][string]$MediaRoot,[Parameter(Mandatory)][string]$SqlMediaPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSqlMediaSha256,
        [Parameter(Mandatory)][string]$StateRoot,[switch]$RetainFixture)
    if(-not $IsWindows){throw 'SSIS_INSTALL_WINDOWS_REQUIRED'}
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'SSIS_INSTALL_ELEVATION_REQUIRED'}
    $mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke');$acquired=$false;$media=$null;$guest=$null;$sa=$null;$blockingProgress=$null
    $context=@{OperationId='ssis-install-'+[guid]::NewGuid().ToString('N');RunId=$null;VmId=$null}
    try {
        try{$acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10))}catch [Threading.AbandonedMutexException]{$acquired=$true}
        if(-not $acquired){throw 'SSIS_INSTALL_HOST_LOCK_TIMEOUT'}
        $media=Open-LabSsisApprovedMedia -MediaRoot $MediaRoot -SqlMediaPath $SqlMediaPath -ExpectedSha256 $ExpectedSqlMediaSha256
        $artifact=Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot
        if (-not $artifact -or $artifact.artifactState -cne 'OS_SEALED' -or $artifact.operatingSystem.id -cne 'windows-server-2025' -or
            $artifact.integrityVerification.status -notin @('VERIFIED_HASH','VERIFIED_CACHE') -or
            -not(Test-HyperVImageArtifactEvaluationEligibility -Artifact $artifact).Eligible -or
            -not(Test-HyperVImageArtifactChildValidationEligibility -Artifact $artifact).Eligible){throw 'SSIS_INSTALL_ARTIFACT_INVALID'}
        $assessment=Invoke-LabResourceAssessmentPreflight -Instances @([pscustomobject]@{provider='hyperv';profile='standard';hyperv=@{memoryStartupMB=8192;processorCount=4}}) -Provider hyperv
        $guest=New-HyperVSqlUnattendedPassword;$sa=New-HyperVSqlUnattendedPassword
        # Ein eigener Reporter bleibt auch sichtbar, wenn der synchrone Gasttransport laenger laeuft.
        $blockingProgress=Start-LabBlockingActionProgress -Phase GuestWait
        Invoke-LabSsisOwnedTransaction -RetainOnSuccess:$RetainFixture -Arrange {
            $created=Invoke-WithLabWorkflowOperationContext -OperationId $context.OperationId -ScriptBlock {
                New-HyperVLabEnvironment -ArtifactId $ArtifactId -LabName 'ssis-install-acceptance' -InstanceId 'ssis' -MemoryStartupMB 8192 `
                    -DynamicMemoryEnabled $false -ProcessorCount 4 -AutoStart off -NetworkIntent hostOnly `
                    -WindowsActivation @{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='EvaluationOnline';EgressPolicy='AllowTemporary'} `
                    -ResourceAssessmentRecord $assessment -StateRoot $StateRoot
            }
            $context.RunId=[string]$created.RunId
            $lab=Get-HyperVLabWorkflowRun -RunId $context.RunId -StateRoot $StateRoot
            if($lab.Run.metadata.workflowOperationId -cne $context.OperationId){throw 'SSIS_INSTALL_CREATED_BINDING'}
            $context.VmId=[string]$lab.Instance.vmId
            Save-LabSecret -Path $lab.RunDirectory -Name 'guest-administrator-password' -Secret $guest
            $null=Invoke-HyperVLabUnattendedProvision -RunId $context.RunId -AdministratorPassword $guest -PasswordSource generated -StateRoot $StateRoot
            $null=Stop-HyperVLabEnvironment -RunId $context.RunId -StateRoot $StateRoot
            $null=Set-HyperVLabSqlDeploymentPlan -RunId $context.RunId -SqlVersion 2025 -DeploymentMode adhoc-install -MediaEdition Enterprise `
                -SqlMediaPath $SqlMediaPath -SqlFeatures SQLENGINE,IS -SsisOperationId $context.OperationId -ExpectedSqlMediaSha256 $ExpectedSqlMediaSha256 `
                -ExpectedVmId ([guid]$context.VmId) -StateRoot $StateRoot
            $installed=Invoke-HyperVLabSqlSlotInstall -RunId $context.RunId -MediaRoot $MediaRoot -SqlSaPassword $sa -SetupTimeoutSeconds 5400 -ReadinessTimeoutSeconds 600 -StateRoot $StateRoot
            if($installed.State -cne 'SQL_SLOT_READY'){throw 'SSIS_INSTALL_SETUP_INCOMPLETE'}
            return $context.RunId
        } -Verify {
            $lab=Get-HyperVLabWorkflowRun -RunId $context.RunId -StateRoot $StateRoot
            $credential=[PSCredential]::new('Administrator',$guest)
            $probe=Get-LabSsisInstallGuestProbe
            $arguments=@{VMName=[string]$lab.Instance.vmName;ExpectedRunId=$context.RunId;ExpectedScopeId=[string]$lab.Run.scopeId;
                ExpectedVmId=[guid]$context.VmId;Credential=$credential;ScriptBlock=$probe;TimeoutSeconds=90}
            $before=Invoke-HyperVPowerShellDirect @arguments
            $managed=Get-HyperVManagedVM -VMName $lab.Instance.vmName -ExpectedRunId $context.RunId -ExpectedScopeId $lab.Run.scopeId
            if([string]$managed.VM.Id -cne $context.VmId){throw 'SSIS_INSTALL_RESTART_BINDING'}
            $null=Restart-VM -VM $managed.VM -Force -ErrorAction Stop
            $ready=Wait-HyperVGuestSqlReady -VMName $lab.Instance.vmName -ExpectedRunId $context.RunId -ExpectedScopeId $lab.Run.scopeId `
                -Credential $credential -SaPassword $sa -ExpectedMajorVersion 17 -TimeoutSeconds 600 -StateRoot $StateRoot
            if(-not $ready.Ready){throw 'SSIS_INSTALL_RESTART_NOT_READY'}
            $after=Invoke-HyperVPowerShellDirect @arguments
            if($before.Status -cne 'IS_COMPONENTS_AND_SQL_VERIFIED' -or $after.Status -cne 'IS_COMPONENTS_AND_SQL_VERIFIED' -or
                [datetimeoffset]$after.BootTime -le [datetimeoffset]$before.BootTime){throw 'SSIS_INSTALL_RESTART_POSTCONDITION'}
            $fixtureArguments=@{VMName=[string]$lab.Instance.vmName;ExpectedRunId=$context.RunId;ExpectedScopeId=[string]$lab.Run.scopeId;
                ExpectedVmId=[guid]$context.VmId;Credential=$credential;ScriptBlock=(Get-LabSsisCatalogFixtureGuestProbe);ArgumentList=@($context.OperationId,[bool]$RetainFixture);TimeoutSeconds=600}
            $fixture=Invoke-HyperVPowerShellDirect @fixtureArguments
            if(@($fixture).Count -ne 1 -or $fixture.Status -cne 'SSISDB_FIXTURE_ACCEPTED'){throw 'SSIS_FIXTURE_RESULT_INVALID'}
            $fixture | Add-Member -NotePropertyName RunId -NotePropertyValue $context.RunId -Force
            $fixture | Add-Member -NotePropertyName InstanceId -NotePropertyValue 'ssis' -Force
            $fixture | Add-Member -NotePropertyName SourceBinding -NotePropertyValue 'OWNED_HYPERV_WINDOWS_RUN' -Force
            if($RetainFixture){Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'ssis-fixture-receipt.json') -InputObject $fixture}
            else{$fixture.Cleanup='CATALOG_FOLDER_CLEANUP_SUCCEEDED'}
            $fixture
        } -Cleanup {Remove-LabSsisOperationRun -OperationId $context.OperationId -StateRoot $StateRoot -ExpectedRunId $context.RunId -ExpectedVmId $context.VmId}
    } catch { $_.Exception.Data['OperationId']=$context.OperationId;throw }
    finally {if($blockingProgress){Stop-LabBlockingActionProgress -Handle $blockingProgress};if($media){$media.Handle.Dispose()};if($guest){$guest.Dispose()};if($sa){$sa.Dispose()};if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
