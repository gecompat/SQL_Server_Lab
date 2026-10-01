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

function Invoke-LabSsisOwnedTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Arrange,[Parameter(Mandatory)][scriptblock]$Verify,
        [Parameter(Mandatory)][scriptblock]$Cleanup)
    $primary=$null;$cleanupFailure=$null;$result=$null
    try {$result=& $Arrange;& $Verify $result | Out-Null} catch {$primary=$_}
    finally {try {& $Cleanup | Out-Null}catch {$cleanupFailure=$_}}
    if ($primary -or $cleanupFailure) {
        $failure=[InvalidOperationException]::new('SSIS_INSTALL_ACCEPTANCE_FAILED')
        # Raw exceptions remain local for the caller; never emit them into CI summaries.
        $failure.Data['PrimaryFailure']=$primary
        $failure.Data['CleanupFailure']=$cleanupFailure
        $failure.Data['RecoveryRequired']=[bool]$cleanupFailure
        throw $failure
    }
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
        $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(60))
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
        [Parameter(Mandatory)][string]$StateRoot)
    if(-not $IsWindows){throw 'SSIS_INSTALL_WINDOWS_REQUIRED'}
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'SSIS_INSTALL_ELEVATION_REQUIRED'}
    $mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke');$acquired=$false;$media=$null;$guest=$null;$sa=$null
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
        Invoke-LabSsisOwnedTransaction -Arrange {
            $created=Invoke-WithLabWorkflowOperationContext -OperationId $context.OperationId -ScriptBlock {
                New-HyperVLabEnvironment -ArtifactId $ArtifactId -LabName 'ssis-install-acceptance' -InstanceId 'ssis' -MemoryStartupMB 8192 `
                    -DynamicMemoryEnabled $false -ProcessorCount 4 -AutoStart off -NetworkIntent hostOnly `
                    -WindowsActivation @{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='VerifyOnly';EgressPolicy='Deny'} `
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
        } -Cleanup {Remove-LabSsisOperationRun -OperationId $context.OperationId -StateRoot $StateRoot -ExpectedRunId $context.RunId -ExpectedVmId $context.VmId}
    } catch { $_.Exception.Data['OperationId']=$context.OperationId;throw }
    finally {if($media){$media.Handle.Dispose()};if($guest){$guest.Dispose()};if($sa){$sa.Dispose()};if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
