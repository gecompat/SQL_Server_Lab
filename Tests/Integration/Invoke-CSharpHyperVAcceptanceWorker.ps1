#Requires -Version 7.2
<# .SYNOPSIS Interner Kindprozess des begrenzten CSharp-Own-Guest-Runners. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PlanPath)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Tests/Common/CSharpNativeAcceptance.ps1')
$plan=Get-Content -LiteralPath $PlanPath -Raw|ConvertFrom-Json
$event=Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw|ConvertFrom-Json
Assert-CSharpNativeDispatch ([pscustomobject]@{EventName=$env:GITHUB_EVENT_NAME;Ref=$env:GITHUB_REF;Repository=$env:GITHUB_REPOSITORY;EventRepository=$event.repository.full_name;ExpectedCommit=$env:GITHUB_SHA;CheckoutCommit=(git -C $repoRoot rev-parse HEAD);Dirty=[bool](git -C $repoRoot status --porcelain --untracked-files=no);ArtifactId=$plan.ArtifactId})
if($plan.OperationId -cnotmatch '^csharp-native-[a-f0-9]{32}$'){throw 'CSHARP_NATIVE_OPERATION_INVALID'}
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$env:SQL_SERVER_LAB_STATE=$plan.StateRoot
$guest=$null;$sa=$null;$mutex=$null;$acquired=$false
try{
    $mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke')
    try{$acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10))}catch [Threading.AbandonedMutexException]{$acquired=$true}
    if(-not $acquired){throw 'CSHARP_NATIVE_HOST_LOCK_TIMEOUT'}
    if(& $module {param($Op,$Root)Get-LabOperationOwnedRun -OperationId $Op -StateRoot $Root} $plan.OperationId $plan.StateRoot){throw 'CSHARP_NATIVE_OPERATION_ALREADY_USED'}
    & $module {
        param($Plan)
        $artifact=Get-HyperVImageArtifact -ArtifactId $Plan.ArtifactId -StateRoot $Plan.StateRoot
        if(-not $artifact -or $artifact.artifactState -ne 'OS_SEALED' -or $artifact.operatingSystem.id -ne 'windows-server-2025' -or
            $artifact.integrityVerification.status -notin @('VERIFIED_HASH','VERIFIED_CACHE') -or
            -not(Test-HyperVImageArtifactEvaluationEligibility -Artifact $artifact).Eligible -or
            -not(Test-HyperVImageArtifactChildValidationEligibility -Artifact $artifact).Eligible){throw 'CSHARP_NATIVE_ARTIFACT_INELIGIBLE'}
        $media=Resolve-HyperVSqlInstallationMedia -MediaRoot $Plan.MediaRoot -SqlVersion 2025 -MediaEdition $Plan.MediaEdition -SqlMediaPath $Plan.SqlMediaPath
        if($media.HashStatus -ne 'SIDECAR_READY'){throw 'CSHARP_NATIVE_SQL_MEDIA_HASH_REQUIRED'}
        $null=Confirm-HyperVSqlInstallationMediaVersion -IsoPath $media.IsoPath -SqlVersion 2025
    } $plan
    $assessment=& $module {Invoke-LabResourceAssessmentPreflight -Instances @([pscustomobject]@{provider='hyperv';profile='standard';hyperv=@{memoryStartupMB=16384;processorCount=4}}) -Provider hyperv}
    $guest=& $module {New-HyperVSqlUnattendedPassword};$sa=& $module {New-HyperVSqlUnattendedPassword}
    $created=& $module {
        param($Plan,$Assessment,$Guest)
        Invoke-WithLabWorkflowOperationContext -OperationId $Plan.OperationId -ScriptBlock {
            $created=New-HyperVLabEnvironment -ArtifactId $Plan.ArtifactId -LabName 'csharp-native-acceptance' -InstanceId 'csharp' `
                -MemoryStartupMB 16384 -DynamicMemoryEnabled $false -ProcessorCount 4 -AutoStart off -NetworkIntent hostOnly `
                -WindowsActivation @{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='EvaluationOnline';EgressPolicy='AllowTemporary'} `
                -ResourceAssessmentRecord $Assessment -StateRoot $Plan.StateRoot
            $lab=Get-HyperVLabWorkflowRun -RunId $created.RunId -StateRoot $Plan.StateRoot
            Save-LabSecret -Path $lab.RunDirectory -Name 'guest-administrator-password' -Secret $Guest
            return $created
        }
    } $plan $assessment $guest
    $owned=Get-CSharpNativeOwnedRun -Module $module -OperationId $plan.OperationId -StateRoot $plan.StateRoot
    if(-not $owned -or $owned.RunId -cne [string]$created.RunId){throw 'CSHARP_NATIVE_CREATED_BINDING'}
    & $module {
        param($Plan,$RunId,$Guest,$Sa)
        $null=Invoke-HyperVLabUnattendedProvision -RunId $RunId -AdministratorPassword $Guest -PasswordSource generated -StateRoot $Plan.StateRoot
        $null=Stop-HyperVLabEnvironment -RunId $RunId -StateRoot $Plan.StateRoot
        $null=Set-HyperVLabSqlDeploymentPlan -RunId $RunId -SqlVersion 2025 -DeploymentMode adhoc-install -MediaEdition $Plan.MediaEdition `
            -SqlMediaPath $Plan.SqlMediaPath -SqlFeatures SQLENGINE,FULLTEXT,REPLICATION,ADVANCEDANALYTICS -StateRoot $Plan.StateRoot
        $result=Invoke-HyperVLabSqlSlotInstall -RunId $RunId -MediaRoot $Plan.MediaRoot -SqlSaPassword $Sa -SetupTimeoutSeconds 5400 -ReadinessTimeoutSeconds 600 -StateRoot $Plan.StateRoot
        if($result.State -ne 'SQL_SLOT_READY'){throw 'CSHARP_NATIVE_SQL_SETUP_INCOMPLETE'}
    } $plan $owned.RunId $guest $sa
    $owned=Get-CSharpNativeOwnedRun -Module $module -OperationId $plan.OperationId -StateRoot $plan.StateRoot
    $credential=[PSCredential]::new('Administrator',$guest)
    $guestRoot='C:\SqlServerLab\CSharpAcceptance\'+$plan.OperationId.Substring('csharp-native-'.Length)
    $managed=& $module {param($Owned)Get-HyperVManagedVM -VMName $Owned.VMName -ExpectedRunId $Owned.RunId -ExpectedScopeId $Owned.ScopeId} $owned
    if([string]$managed.VM.Id -cne $owned.VMId){throw 'CSHARP_NATIVE_TRANSFER_VM_BINDING'}
    Enable-CSharpNativeGuestCopy -VM $managed.VM
    foreach($name in @('extension.zip','runtime.zip','SqlServerLab.CSharpProbe.dll','probe.sql')){
        $null=& $module {param($Owned)Get-HyperVManagedVM -VMName $Owned.VMName -ExpectedRunId $Owned.RunId -ExpectedScopeId $Owned.ScopeId} $owned
        $job=Copy-VMFile -VM (Get-VM -Id ([guid]$owned.VMId)) -SourcePath (Join-Path $plan.PayloadRoot $name) -DestinationPath (Join-Path $guestRoot $name) -FileSource Host -CreateFullPath -AsJob
        try{
            if(-not(Wait-Job -Job $job -Timeout 180)){throw 'CSHARP_NATIVE_TRANSFER_TIMEOUT'}
            $null=Receive-Job -Job $job -ErrorAction Stop
            if($job.State -ne 'Completed'){throw 'CSHARP_NATIVE_TRANSFER_FAILED'}
        }finally{Stop-Job -Job $job -ErrorAction SilentlyContinue;Remove-Job -Job $job -Force}
    }
    $guestScript=[scriptblock]::Create([IO.File]::ReadAllText((Join-Path $repoRoot 'Tests/Integration/Fixtures/CSharp/guest.ps1')))
    function Invoke-OwnGuest([string]$Stage){
        & $module {
            param($Owned,$Credential,$Code,$Arguments)
            Invoke-HyperVPowerShellDirect -VMName $Owned.VMName -ExpectedRunId $Owned.RunId -ExpectedScopeId $Owned.ScopeId -ExpectedVmId ([guid]$Owned.VMId) `
                -Credential $Credential -ScriptBlock $Code -ArgumentList $Arguments -TimeoutSeconds 600
        } $owned $credential $guestScript @($Stage,$guestRoot,$plan.PackageSha256,$plan.ProbeSha256,$plan.SqlSha256,$sa)
    }
    function Restart-OwnGuest {
        $restart=Restart-SqlServerLab -RunId $owned.RunId -TimeoutSeconds 600 -Force -Confirm:$false
        if($restart.State -ne 'Running' -or [string]$restart.VMId -cne $owned.VMId){throw 'CSHARP_NATIVE_RESTART_BINDING'}
        $ready=& $module {param($Owned,$Credential,$Sa)Wait-HyperVGuestSqlReady -VMName $Owned.VMName -ExpectedRunId $Owned.RunId -ExpectedScopeId $Owned.ScopeId -Credential $Credential -SaPassword $Sa -ExpectedMajorVersion 17 -TimeoutSeconds 600} $owned $credential $sa
        if(-not $ready.Ready -or $ready.MajorVersion -ne 17){throw 'CSHARP_NATIVE_SQL_NOT_READY'}
    }
    if((Invoke-OwnGuest Configure) -cne 'CSHARP_NATIVE_CONFIGURED_RESTART_REQUIRED'){throw 'CSHARP_NATIVE_CONFIGURE_RESULT'}
    Restart-OwnGuest
    if((Invoke-OwnGuest Register) -cne 'CSHARP_NATIVE_REGISTERED'){throw 'CSHARP_NATIVE_REGISTER_RESULT'}
    [pscustomobject]@{Status='SQL_PROBE_STARTED';OperationId=$plan.OperationId;Commit=$env:GITHUB_SHA}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path (Split-Path $PlanPath) 'native-attempt.json')
    $before=Invoke-OwnGuest Probe
    Restart-OwnGuest
    $after=Invoke-OwnGuest Probe
    if($before.Status -cne 'CSHARP_SQL_ROUNDTRIP_OK' -or $after.Status -cne 'CSHARP_SQL_ROUNDTRIP_OK' -or [datetimeoffset]$after.BootTime -le [datetimeoffset]$before.BootTime){throw 'CSHARP_NATIVE_RESTART_PROOF'}
    [pscustomobject]@{Status='SQL_PROBE_AND_RESTART_PASSED';OperationId=$plan.OperationId;Commit=$env:GITHUB_SHA} |
        ConvertTo-Json|Set-Content -LiteralPath (Join-Path (Split-Path $PlanPath) 'worker-result.json')
}finally{
    # Parent is responsible for independent cleanup even after hard child termination.
    if($guest){$guest.Dispose()};if($sa){$sa.Dispose()}
    if($acquired){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
}
