#Requires -Version 7.2
# Actual build/provider authority composition; only native boundaries are synthetic.
[CmdletBinding()] param([switch]$AsResults,[switch]$SqlPublicationOnly)
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-build-authority-'+[guid]::NewGuid().ToString('N'))
$oldDataRoot=$env:SQL_SERVER_LAB_DATA_ROOT
try {
    $module=Import-Module (Join-Path $repository 'SqlServerLab.psd1') -Force -PassThru -WarningAction SilentlyContinue
    $results=& $module {
        param($FixtureRoot,$Repository,$SqlPublicationOnly)
        $stateRoot=Join-Path $FixtureRoot 'state'; $dataRoot=Join-Path $FixtureRoot 'data'
        $null=Initialize-LabManagedDataRoot -DataRoot $dataRoot -Confirm:$false
        $env:SQL_SERVER_LAB_DATA_ROOT=$dataRoot
        $id=[guid]::NewGuid().ToString();$scope=[guid]::NewGuid().ToString();$vmId=[guid]::NewGuid().ToString()
        $directory=Join-Path $stateRoot "image-builds/hyperv/$id"
        $null=New-Item -ItemType Directory -Path $directory -Force
        $state=[pscustomobject]@{buildId=$id;scopeId=$scope;updatedAt='';builder=$null;state='MEDIA_VERIFIED'}
        Write-HyperVImageBuildState -BuildDirectory $directory -State $state
        $binding=Initialize-LabHyperVResourceBinding -ResourceId $id -ResourceClass Build -StateDirectory $directory -DataRoot $dataRoot
        $disk=Join-Path $binding.HyperVResourceRoot 'synthetic-builder.vhdx'
        $null=New-Item -ItemType Directory -Path $binding.HyperVResourceRoot -Force
        $null=New-Item -ItemType File -Path $disk
        $null=New-CleanupPlan -RunDir $directory -RunId $id -ScopeId $scope
        $null=Add-CleanupStep -RunDir $directory -ResourceType vhdx -ResourceId $disk -Action remove -Provider hyperv
        $null=Add-CleanupStep -RunDir $directory -ResourceType vm -ResourceId synthetic-builder -Action remove -Provider hyperv
        $native=[pscustomobject]@{Id=$vmId;Name='synthetic-builder';State='Off';Notes=(ConvertTo-HyperVLabNotes -RunId $id -ScopeId $scope -InstanceId image-builder -ChildVhdxPath $disk)}
        $cases=[Collections.Generic.List[object]]::new()
        function Record([string]$Name,[scriptblock]$Body) {
            if($SqlPublicationOnly -and $Name -notmatch '^Actual SQL fresh creation|^Actual SQL clone provider creation|^Actual provider post-Action log|^Entire SQL'){return}
            try { $ok=& $Body; $cases.Add([pscustomobject]@{Name=$Name;Success=($ok -eq $true);Code=''}) }
            catch { $cases.Add([pscustomobject]@{Name=$Name;Success=$false;Code=$_.Exception.GetType().Name}); Write-Warning "$Name : $($_.Exception.Message)" }
        }
        function Rejected([scriptblock]$Body) { try { & $Body | Out-Null; return $false } catch { return $true } }
        function RejectedCode([scriptblock]$Body,[string]$Code) { try { & $Body | Out-Null; return $false } catch { return $_.Exception.Message -ceq $Code } }
        $nativeSet=@($native);$readError=$false
        $actualProviderOperation=(Get-Item Function:Invoke-LabProviderOperation).ScriptBlock
        function Get-VM { [CmdletBinding()]param() if($readError){throw 'SYNTHETIC_ACCESS_DENIED'}; $nativeSet | Where-Object { $_.State -ne 'Removed' } }
        function Get-VMHardDiskDrive { [CmdletBinding()]param([Parameter(ValueFromPipeline)]$VM) process { if($attached -or $VM.Id -ceq $vmId){[pscustomobject]@{Path=if($wrongNativeDisk){Join-Path $FixtureRoot 'foreign.vhdx'}else{$disk}}} } }
        function Get-VMSnapshot { [CmdletBinding()]param($VM) @() }
        function Remove-VM { [CmdletBinding()]param($VM,[switch]$Force) $VM.State='Removed' }
        function Invoke-LabProviderOperation { param($Provider,$Phase,$RunId,$StateRoot,$Command,$Action) & $Action }
        function Start-LabBlockingActionProgress { param($Phase) $null }
        function Stop-LabBlockingActionProgress { param($Handle) }
        Record 'Historical build remains readable but cannot mutate' {
            (Get-HyperVImageBuildPlan -BuildId $id -StateRoot $stateRoot).buildId -eq $id -and
            (Rejected { Get-HyperVBuildMutationContext -BuildDirectory $directory -StateRoot $stateRoot })
        }
        $persisted=Set-HyperVBuildNativeBinding -BuildDirectory $directory -StateRoot $stateRoot -VM $native -InstanceId image-builder -ChildVhdxPath $disk
        Record 'Actual returned VM ID is persisted before later builder fields' { $persisted.vmId -ceq $vmId -and (Get-HyperVImageBuildPlan -BuildId $id -StateRoot $stateRoot).builder.vmId -ceq $vmId }
        $context=Get-HyperVBuildMutationContext -BuildDirectory $directory -StateRoot $stateRoot -ExpectedScopeId $scope
        $callerBuild=Get-HyperVImageBuildPlan -BuildId $id -StateRoot $stateRoot
        $guestCalls=0
        $actualGuestTransport=(Get-Item Function:Invoke-HyperVPowerShellDirect).ScriptBlock
        function Invoke-HyperVPowerShellDirect { param($VMName,$ExpectedRunId,$ExpectedScopeId,$ExpectedVmId,$Credential,$ScriptBlock,$ArgumentList,$FallbackAddress,$Progress,$TimeoutSeconds,$Build,$BuildStateRoot) $script:guestCalls++; [string]$ExpectedVmId }
        function Get-VHD { [CmdletBinding()]param($Path) [pscustomobject]@{Attached=$false} }
        $secure=[securestring]::new();$secure.AppendChar('x');$credential=[pscredential]::new('synthetic',$secure)
        Record 'Actual Build guest composition forwards recorded native ID' {
            $guestCalls=0
            $result=Invoke-HyperVBuildPowerShellDirect -Build $callerBuild -StateRoot $stateRoot -VMName $native.Name -ExpectedRunId $id -ExpectedScopeId $scope -Credential $credential -ScriptBlock {}
            $result -ceq $vmId -and $script:guestCalls -eq 1
        }
        $savedCallerId=$callerBuild.builder.vmId;$callerBuild.builder.vmId=[guid]::NewGuid().ToString()
        Record 'Guest caller changed ID prevents actual transport' { $script:guestCalls=0;(Rejected { Invoke-HyperVBuildPowerShellDirect -Build $callerBuild -StateRoot $stateRoot -VMName $native.Name -ExpectedRunId $id -ExpectedScopeId $scope -Credential $credential -ScriptBlock {} }) -and $script:guestCalls -eq 0 }
        $callerBuild.builder.vmId=$savedCallerId
        Record 'Guest foreign root prevents actual transport' { $script:guestCalls=0;(Rejected { Invoke-HyperVBuildPowerShellDirect -Build $callerBuild -StateRoot (Join-Path $FixtureRoot foreign) -VMName $native.Name -ExpectedRunId $id -ExpectedScopeId $scope -Credential $credential -ScriptBlock {} }) -and $script:guestCalls -eq 0 }
        Record 'Guest foreign scope prevents actual transport' { $script:guestCalls=0;(Rejected { Invoke-HyperVBuildPowerShellDirect -Build $callerBuild -StateRoot $stateRoot -VMName $native.Name -ExpectedRunId $id -ExpectedScopeId ([guid]::NewGuid().ToString()) -Credential $credential -ScriptBlock {} }) -and $script:guestCalls -eq 0 }
        Record 'Stopped owned VM permits exact unattached offline disk' { Assert-HyperVBuildOfflineDiskAuthority -Build $callerBuild -StateRoot $stateRoot -VhdxPath $disk; $true }
        $readError=$true
        Record 'Offline query error never becomes absent authority' { Rejected { Assert-HyperVBuildOfflineDiskAuthority -Build $callerBuild -StateRoot $stateRoot -VhdxPath $disk } }
        $readError=$false;$nativeSet=@()
        Record 'Confirmed VM absence preserves typed offline disk authority' { Assert-HyperVBuildOfflineDiskAuthority -Build $callerBuild -StateRoot $stateRoot -VhdxPath $disk; $true }
        $nativeSet=@($native)
        # Compose the real Build wrapper, fresh binding helper and generic transport.
        $mockGuestTransport=(Get-Item Function:Invoke-HyperVPowerShellDirect).ScriptBlock
        Set-Item Function:Invoke-HyperVPowerShellDirect $actualGuestTransport
        $native.State='Running';$switchId=[guid]::NewGuid().ToString();$script:fallbackIp='192.0.2.11'
        $callerBuild | Add-Member labNetwork ([pscustomobject]@{Name='synthetic-network';Subnet='192.0.2.0/24'}) -Force
        Write-HyperVImageBuildState -BuildDirectory $directory -State $callerBuild
        function Get-LabNetworkGuestAddress {param($Network,$Identity) '192.0.2.11'}
        function Get-VMSwitch {[CmdletBinding()]param($Name) [pscustomobject]@{Id=$switchId;Name=$Name}}
        function Get-VMNetworkAdapter {[CmdletBinding()]param($VM) if($script:nicError){throw 'SYNTHETIC_NIC_READ_ERROR'};[pscustomobject]@{SwitchId=if($script:foreignNicSwitch){[guid]::NewGuid().ToString()}else{$switchId};SwitchName='synthetic-network';IPAddresses=@($script:fallbackIp)}}
        function Get-HyperVManagedVM {param($VMName,$ExpectedRunId,$ExpectedScopeId) [pscustomobject]@{VM=[pscustomobject]@{Id=if($script:transportReplacement){[guid]::NewGuid().ToString()}else{$native.Id};Name=$native.Name;State=$native.State};Identity=[pscustomobject]@{guestTransport=$script:transportKind}}}
        function Invoke-Command {
            [CmdletBinding()]param($VMId,$VMName,$Credential,$ScriptBlock,$ArgumentList,[switch]$AsJob)
            $script:directCalls++;$script:selectedId=[string]$VMId
            if($script:openError){$PSCmdlet.ThrowTerminatingError([Management.Automation.ErrorRecord]::new([Exception]::new('SYNTHETIC_OPEN_ERROR'),'SyntheticOpen',[Management.Automation.ErrorCategory]::OpenError,$null))}
            [pscustomobject]@{Synthetic=$true}
        }
        function Receive-LabProgressJob {param($Job,$Progress,$TimeoutSeconds) if($script:initDrift){$native.Id=[guid]::NewGuid().ToString()};[pscustomobject]@{computerName='synthetic';imageState='IMAGE_STATE_COMPLETE'}}
        function Invoke-HyperVWinRmFallback {param($Address,$Credential,$ScriptBlock,$ArgumentList,$Progress,$TimeoutSeconds) $script:fallbackCalls++;'synthetic-fallback'}
        function Wait-LabProgressDelay {param($Progress,$Milliseconds) if($script:retryDrift){$native.Id=[guid]::NewGuid().ToString()}}
        $transportArgs=@{Build=$callerBuild;StateRoot=$stateRoot;VMName=$native.Name;ExpectedRunId=$id;ExpectedScopeId=$scope;Credential=$credential;ScriptBlock={};FallbackAddress='192.0.2.11';Progress=[pscustomobject]@{};TimeoutSeconds=10}
        Record 'Real Build plus generic direct with fallback selects exact native ID' {$script:directCalls=0;$null=Invoke-HyperVBuildPowerShellDirect @transportArgs;$script:directCalls -eq 1 -and $script:selectedId -ceq $vmId}
        $script:transportReplacement=$true
        Record 'Real fallback composition same name replacement ID has zero dispatch' {$script:directCalls=0;$script:fallbackCalls=0;(Rejected {Invoke-HyperVBuildPowerShellDirect @transportArgs}) -and $script:directCalls -eq 0 -and $script:fallbackCalls -eq 0}
        $script:transportReplacement=$false;$script:transportKind='lab-winrm'
        Record 'Real WinRM dispatch requires fresh owned native NIC and exact address' {$script:fallbackCalls=0;$null=Invoke-HyperVBuildPowerShellDirect @transportArgs;$script:fallbackCalls -eq 1}
        $script:fallbackIp='192.0.2.12'
        Record 'Wrong native NIC address prevents fallback credential forwarding' {$script:fallbackCalls=0;(Rejected {Invoke-HyperVBuildPowerShellDirect @transportArgs}) -and $script:fallbackCalls -eq 0}
        $script:fallbackIp='192.0.2.11';$script:foreignNicSwitch=$true
        Record 'Foreign native switch prevents fallback credential forwarding' {$script:fallbackCalls=0;(Rejected {Invoke-HyperVBuildPowerShellDirect @transportArgs}) -and $script:fallbackCalls -eq 0}
        $script:foreignNicSwitch=$false;$script:nicError=$true
        Record 'Native NIC query error prevents fallback credential forwarding' {$script:fallbackCalls=0;(Rejected {Invoke-HyperVBuildPowerShellDirect @transportArgs}) -and $script:fallbackCalls -eq 0}
        $script:nicError=$false;$script:transportKind='powershell-direct';$script:openError=$true;$script:retryDrift=$true
        Record 'Native ID drift after OpenError prevents second direct or fallback attempt' {$script:directCalls=0;$script:fallbackCalls=0;(Rejected {Invoke-HyperVBuildPowerShellDirect @transportArgs}) -and $script:directCalls -eq 1 -and $script:fallbackCalls -eq 0}
        $native.Id=$vmId;$script:openError=$false;$script:retryDrift=$false
        Record 'Ordinary run strict ID plus fallback remains prohibited' {$script:directCalls=0;(Rejected {Invoke-HyperVPowerShellDirect -VMName $native.Name -ExpectedRunId $id -ExpectedScopeId $scope -ExpectedVmId ([guid]$vmId) -Credential $credential -ScriptBlock {} -FallbackAddress '192.0.2.11'}) -and $script:directCalls -eq 0}
        $script:initDrift=$true
        Record 'Actual readiness initialization revalidates Build before second guest dispatch' {$script:directCalls=0;(Rejected {Wait-HyperVPowerShellDirect -Build $callerBuild -BuildStateRoot $stateRoot -VMName $native.Name -ExpectedRunId $id -ExpectedScopeId $scope -Credential $credential -GuestInitializationScript 'synthetic' -TimeoutSeconds 1}) -and $script:directCalls -eq 1}
        $native.Id=$vmId;$native.State='Off';$script:initDrift=$false
        Set-Item Function:Invoke-HyperVPowerShellDirect $mockGuestTransport
        $legacyState=Get-HyperVImageBuildPlan -BuildId $id -StateRoot $stateRoot
        $legacyState.state='MANUAL_ACTION_REQUIRED';$legacyState.builder.vmId=$null
        Write-HyperVImageBuildState -BuildDirectory $directory -State $legacyState
        Record 'Actual Windows confirmation rejects missing native ID before guest transport' { $script:guestCalls=0;(Rejected { Confirm-HyperVWindowsImageInstallation -BuildId $id -StateRoot $stateRoot -Credential $credential }) -and $script:guestCalls -eq 0 }
        $legacyState.builder.vmId=$vmId;Write-HyperVImageBuildState -BuildDirectory $directory -State $legacyState
        $legacyState | Add-Member -NotePropertyName media -NotePropertyValue ([pscustomobject]@{bootInteraction=[pscustomobject]@{initialMediaKey='space'}}) -Force
        Write-HyperVImageBuildState -BuildDirectory $directory -State $legacyState
        $script:keyEffects=0;$script:cimId=[guid]::NewGuid().ToString()
        function Start-Sleep {param($Milliseconds,$Seconds)}
        function Get-CimInstance {[CmdletBinding()]param($Namespace,$ClassName,$Filter) [pscustomobject]@{Name=$script:cimId}}
        function Get-CimAssociatedInstance {[CmdletBinding()]param($InputObject,$Association,$ResultClassName) [pscustomobject]@{Name='synthetic-keyboard'}}
        function Invoke-CimMethod {[CmdletBinding()]param($InputObject,$MethodName,$Arguments) $script:keyEffects++;[pscustomobject]@{ReturnValue=0}}
        Record 'Actual keyboard same name foreign CIM native ID has zero effects' { (Rejected { Invoke-HyperVInitialMediaBootInteraction -BuildId $id -VMName $native.Name -StateRoot $stateRoot -Attempts 1 }) -and $script:keyEffects -eq 0 }
        $script:cimId=$vmId
        Record 'Actual keyboard exact native ID performs one intended effect' { (Invoke-HyperVInitialMediaBootInteraction -BuildId $id -VMName $native.Name -StateRoot $stateRoot -Attempts 1).successfulSends -eq 1 -and $script:keyEffects -eq 1 }
        Record 'Fresh ID Notes typed Build disk and cleanup plan agree' { (Get-HyperVBuildBoundManagedVM -Context $context).VM.Id -ceq $vmId }
        Record 'Actual provider guard accepts independently selected Build root' { Assert-LabWindowsPoolProviderMutation -Managed ([pscustomobject]@{VM=$native;Identity=(ConvertFrom-HyperVLabNotes $native.Notes)}) -StateRoot $stateRoot; $true }
        $wrongNativeDisk=$true
        Record 'Native physical child drift is rejected before VM effects' { Rejected { Get-HyperVBuildBoundManagedVM -Context $context } }
        $wrongNativeDisk=$false
        Record 'Wrong root is rejected' { Rejected { Get-HyperVBuildMutationContext -BuildDirectory $directory -StateRoot (Join-Path $FixtureRoot 'foreign') } }
        $link=Join-Path $directory 'linked'
        $null=New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path $link -Target $FixtureRoot
        Record 'Linked authority path is rejected' { -not (Test-LabPathWithinRoot -Root $stateRoot -Path (Join-Path $link 'state.json')).Valid }
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $link -Force
        Record 'Wrong scope is rejected' { Rejected { Get-HyperVBuildMutationContext -BuildDirectory $directory -StateRoot $stateRoot -ExpectedScopeId ([guid]::NewGuid().ToString()) } }
        $originalNotes=$native.Notes
        $native.Notes=ConvertTo-HyperVLabNotes -RunId $id -ScopeId ([guid]::NewGuid().ToString()) -InstanceId image-builder -ChildVhdxPath $disk
        Record 'Foreign Notes scope is rejected' { Rejected { Get-HyperVBuildBoundManagedVM -Context $context } }
        $native.Notes=$originalNotes
        # Entire publication function; native responses and registry import are
        # the only synthetic boundaries. Old seal evidence cannot authorize a disk.
        $savedPublishState=Get-HyperVImageBuildPlan -BuildId $id -StateRoot $stateRoot
        $savedPublishPlan=Read-LabWorkflowJson -Path (Join-Path $directory 'cleanup-plan.json')
        $publishState=[pscustomobject]@{buildId=$id;scopeId=$scope;updatedAt='';builder=$savedPublishState.builder;state='RESUME_PENDING';stateHistory=@();
            operatingSystem=[pscustomobject]@{id='synthetic-ci';edition='synthetic';installationType='synthetic';language='en-US'};
            license=[pscustomobject]@{type='test-only'};media=[pscustomobject]@{bootInteraction=[pscustomobject]@{initialMediaKey='space'}};
            generalizationEvidence=[pscustomobject]@{relativePath='evidence/generalization.json';storedSha256=''};
            sealPostconditions=[pscustomobject]@{identityValidated=$true;vmOff=$true;checkpointsAbsent=$true}}
        $publishState.builder | Add-Member -NotePropertyName osDiskRelativePath -NotePropertyValue 'resources/hyperv/synthetic-builder.vhdx' -Force
        $null=New-Item -ItemType Directory (Join-Path $directory 'evidence') -Force
        Set-Content -LiteralPath (Join-Path $directory 'evidence/generalization.json') -Value '{}'
        $publishState.generalizationEvidence.storedSha256=(Get-FileHash (Join-Path $directory 'evidence/generalization.json')).Hash.ToLowerInvariant()
        function Test-HyperVAvailable {[pscustomobject]@{Available=$true}}
        function Test-HyperVVhdxSignature {param($Path) $true}
        function Test-HyperVVhdxCleanupDependencyChain {param($Path) [pscustomobject]@{Valid=(-not $script:publishDependencyInvalid);Code='SYNTHETIC_AVHDX_PRESENT'}}
        function Import-HyperVImageArtifact {
            param($VhdxPath,$ExpectedSha256,$ArtifactState,$OperatingSystemId,$OperatingSystemVersion,$Edition,$InstallationType,$Language,$LicenseType,$VmGeneration,$SecureBoot,$GuestControl,$IntegrityOrigin,$InitialMediaKey,$EvaluationExpiresAt,$StateRoot,[switch]$Generalized,[switch]$RequireChildBootValidation)
            $script:publishImports++
            [pscustomobject]@{artifactId='synthetic-published';sha256=$ExpectedSha256.ToLowerInvariant();artifactState=$ArtifactState}
        }
        $nativeSet=@([pscustomobject]@{Id=[guid]::NewGuid().ToString();Name='foreign';State='Running';Notes=''});$attached=$true
        Write-HyperVImageBuildState -BuildDirectory $directory -State $publishState
        Record 'Entire Windows publish absent VM foreign disk attachment has zero seal/import' { $script:publishImports=0;(Rejected { Publish-HyperVWindowsImageBuild -BuildId $id -StateRoot $stateRoot }) -and $script:publishImports -eq 0 -and -not (Get-Item $disk).IsReadOnly }
        $nativeSet=@();$attached=$false;$script:publishDependencyInvalid=$true
        Record 'Entire Windows publish absent VM AVHDX dependency has zero seal/import' { $script:publishImports=0;(Rejected { Publish-HyperVWindowsImageBuild -BuildId $id -StateRoot $stateRoot }) -and $script:publishImports -eq 0 -and -not (Get-Item $disk).IsReadOnly }
        $script:publishDependencyInvalid=$false;$readError=$true
        Record 'Entire Windows publish native query failure has zero seal/import' { $script:publishImports=0;(Rejected { Publish-HyperVWindowsImageBuild -BuildId $id -StateRoot $stateRoot }) -and $script:publishImports -eq 0 -and -not (Get-Item $disk).IsReadOnly }
        $readError=$false
        Record 'Entire Windows publish confirmed absence seals imports and completes own cleanup' { $script:publishImports=0;$result=Publish-HyperVWindowsImageBuild -BuildId $id -StateRoot $stateRoot;$result.Status -ceq 'TEST_ARTIFACT_PUBLISHED' -and $script:publishImports -eq 1 -and -not (Test-Path $disk) }
        if(-not(Test-Path $disk)){$null=New-Item -ItemType File $disk}
        Write-HyperVImageBuildState -BuildDirectory $directory -State $publishState
        Write-LabArtifactJsonAtomic -Path (Join-Path $directory 'cleanup-plan.json') -InputObject $savedPublishPlan
        $nativeSet=@($native);$native.State='Off'
        Record 'Entire Windows publish exact own VM Off seals imports and completes own cleanup' { $script:publishImports=0;$result=Publish-HyperVWindowsImageBuild -BuildId $id -StateRoot $stateRoot;$result.Status -ceq 'TEST_ARTIFACT_PUBLISHED' -and $script:publishImports -eq 1 -and $native.State -ceq 'Removed' -and -not (Test-Path $disk) }
        if(Test-Path $disk){(Get-Item $disk).IsReadOnly=$false}else{$null=New-Item -ItemType File $disk}
        Write-HyperVImageBuildState -BuildDirectory $directory -State $savedPublishState
        Write-LabArtifactJsonAtomic -Path (Join-Path $directory 'cleanup-plan.json') -InputObject $savedPublishPlan
        $native.State='Off';$nativeSet=@($native)
        Record 'Actual VM removal carries Build authority into provider operation' {
            (Remove-HyperVInstance -VMName $native.Name -ExpectedScopeId $scope -ExpectedRunDirectory $directory -StateRoot $stateRoot -PreserveVhdx -RequireOff).Removed -eq $true -and $native.State -eq 'Removed' -and (Test-Path $disk)
        }
        $native.State='Off'
        $native.Id=[guid]::NewGuid().ToString()
        Record 'Actual guest transport rejects same name changed native ID' { $script:guestCalls=0;(Rejected { Invoke-HyperVBuildPowerShellDirect -Build $callerBuild -StateRoot $stateRoot -VMName $native.Name -ExpectedRunId $id -ExpectedScopeId $scope -Credential $credential -ScriptBlock {} }) -and $script:guestCalls -eq 0 }
        Record 'Same name with different native ID has zero removal effects' { (Rejected { Remove-HyperVInstance -VMName $native.Name -ExpectedScopeId $scope -ExpectedRunDirectory $directory -StateRoot $stateRoot -PreserveVhdx }) -and $native.State -ceq 'Off' -and (Test-Path $disk) }
        $native.Id=$vmId
        $readError=$true
        Record 'Native query error is never AlreadyAbsent' { Rejected { Remove-HyperVInstance -VMName $native.Name -ExpectedScopeId $scope -ExpectedRunDirectory $directory -StateRoot $stateRoot -PreserveVhdx } }
        $readError=$false;$nativeSet=@()
        Record 'Confirmed exact native absence permits AlreadyAbsent' { (Remove-HyperVInstance -VMName $native.Name -ExpectedScopeId $scope -ExpectedRunDirectory $directory -StateRoot $stateRoot -PreserveVhdx).AlreadyAbsent -eq $true }
        $nativeSet=@($native)
        $runDirectory=Join-Path $stateRoot "runs/$id";$null=New-Item -ItemType Directory -Path $runDirectory -Force
        $null=New-Item -ItemType File -Path (Join-Path $runDirectory 'run-state.json')
        Record 'Stripped pool/run membership takes precedence over forged Build' { Rejected { Get-HyperVBuildMutationContext -BuildDirectory $directory -StateRoot $stateRoot } }
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $runDirectory -Recurse -Force
        $otherPoolId=[guid]::NewGuid().ToString();$poolDirectory=Join-Path $stateRoot "runs/$otherPoolId"
        $null=New-Item -ItemType Directory -Path $poolDirectory -Force
        $poolScope=[guid]::NewGuid().ToString();$artifactId='hyperv-os-sealed-'+('a'*64)
        $poolRun=[pscustomobject]@{runId=$otherPoolId;scopeId=$poolScope;metadata=[pscustomobject]@{workflowKind='hyperv-lab';imageArtifactId=$artifactId;
            windowsPoolMember=[pscustomobject]@{contractVersion='SqlServerLab.WindowsPoolMember/1.0';poolId=[guid]::NewGuid().ToString();
                creationOperationId=[guid]::NewGuid().ToString();runId=$otherPoolId;scopeId=$poolScope;evidenceEpoch=[guid]::NewGuid().ToString();
                provider='hyperv';instanceId='primary';vmId=$vmId;imageArtifactId=$artifactId;revision=1;index=1;state='FREE';claim=$null}}}
        $null=Assert-LabWindowsPoolMember -Run $poolRun
        # Seed a fully validated, pre-existing synthetic member; do not request
        # registration or acquire a real pool claim in this fixture.
        Write-LabArtifactJsonAtomicRaw -Path (Join-Path $poolDirectory 'run-state.json') -InputObject $poolRun
        Record 'Native-ID pool membership defeats stripped hint and forged Build run ID' {
            Rejected { Assert-LabWindowsPoolProviderMutation -Managed ([pscustomobject]@{VM=$native;Identity=(ConvertFrom-HyperVLabNotes $native.Notes)}) -StateRoot $stateRoot }
        }
        Record 'Actual guest transport cannot override recorded pool native ID' { $script:guestCalls=0;(Rejected { Invoke-HyperVBuildPowerShellDirect -Build $callerBuild -StateRoot $stateRoot -VMName $native.Name -ExpectedRunId $id -ExpectedScopeId $scope -Credential $credential -ScriptBlock {} }) -and $script:guestCalls -eq 0 }
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $poolDirectory -Recurse -Force
        $runId=[guid]::NewGuid().ToString();$otherRunDirectory=Join-Path $stateRoot "runs/$runId"
        $null=New-Item -ItemType Directory -Path $otherRunDirectory -Force
        Write-LabArtifactJsonAtomic -Path (Join-Path $otherRunDirectory 'run-state.json') -InputObject ([pscustomobject]@{runId=$runId;scopeId=$scope;metadata=@{}})
        Write-LabArtifactJsonAtomic -Path (Join-Path $otherRunDirectory 'connection-info.json') -InputObject ([pscustomobject]@{instances=@([pscustomobject]@{provider='hyperv';vmId=$vmId})})
        Record 'Native-ID Run connection defeats forged Build identity' { Rejected { Get-HyperVBuildMutationContext -BuildDirectory $directory -StateRoot $stateRoot } }
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $otherRunDirectory -Recurse -Force
        $rawBinding=Read-LabWorkflowJson -Path (Join-Path $directory 'hyperv-resource-binding.local.json')
        $rawBinding.ResourceClass='Run';Write-LabArtifactJsonAtomic -Path (Join-Path $directory 'hyperv-resource-binding.local.json') -InputObject $rawBinding
        Record 'Wrong typed resource class is rejected' { Rejected { Get-HyperVBuildMutationContext -BuildDirectory $directory -StateRoot $stateRoot } }
        Write-LabArtifactJsonAtomic -Path (Join-Path $directory 'hyperv-resource-binding.local.json') -InputObject $binding
        $plan=Read-LabWorkflowJson -Path (Join-Path $directory 'cleanup-plan.json');$oldPlanId=$plan.runId;$plan.runId=[guid]::NewGuid().ToString()
        Write-LabArtifactJsonAtomic -Path (Join-Path $directory 'cleanup-plan.json') -InputObject $plan
        Record 'Wrong cleanup plan Build ID is rejected' { Rejected { Get-HyperVBuildMutationContext -BuildDirectory $directory -StateRoot $stateRoot } }
        $plan.runId=$oldPlanId;Write-LabArtifactJsonAtomic -Path (Join-Path $directory 'cleanup-plan.json') -InputObject $plan
        $nativeSet=@();$attached=$false
        function Test-HyperVVhdxCleanupDependencyChain { param($Path) [pscustomobject]@{Valid=$true} }
        Record 'Absent VM plus foreign physical disk is rejected' { Rejected { Remove-HyperVVhdxForCleanup -Path (Join-Path $FixtureRoot 'foreign.vhdx') -ExpectedRunDirectory $directory -StateRoot $stateRoot -ExpectedScopeId $scope } }
        $nativeSet=@([pscustomobject]@{Id=[guid]::NewGuid().ToString();Name='foreign';Notes='';State='Running'});$attached=$true
        Record 'Foreign attachment blocks bound disk cleanup' { Rejected { Remove-HyperVVhdxForCleanup -Path $disk -ExpectedRunDirectory $directory -StateRoot $stateRoot -ExpectedScopeId $scope } }
        $nativeSet=@();$attached=$false
        Record 'Confirmed own VM absence permits exact bound disk cleanup' { (Remove-HyperVVhdxForCleanup -Path $disk -ExpectedRunDirectory $directory -StateRoot $stateRoot -ExpectedScopeId $scope).Removed -eq $true -and -not (Test-Path $disk) }
        if(-not(Test-Path $disk)){$null=New-Item -ItemType File -Path $disk}
        $nativeSet=@($native);$native.State='Off'
        Record 'Actual complete cleanup plan dispatch removes VM then exact disk' {
            $cleanup=Invoke-CleanupPlan -RunDir $directory -ScopeId $scope
            $cleanup.Status -ceq 'CLEANUP_SUCCEEDED' -and $native.State -ceq 'Removed' -and -not (Test-Path $disk)
        }
        # Exercise the real creator only through the first post-New-VM failure.
        $creationId=[guid]::NewGuid().ToString();$creationDirectory=Join-Path $stateRoot "image-builds/hyperv/$creationId"
        $null=New-Item -ItemType Directory -Path $creationDirectory -Force
        $creationState=[pscustomobject]@{buildId=$creationId;scopeId=$scope;updatedAt='';builder=$null;state='MEDIA_VERIFIED';resources=[pscustomobject]@{osDiskSizeBytes=64MB};platform=[pscustomobject]@{vmGeneration=2;secureBoot=$true}}
        Write-HyperVImageBuildState -BuildDirectory $creationDirectory -State $creationState
        Write-LabArtifactJsonAtomic -Path (Join-Path $creationDirectory 'build-local.json') -InputObject ([pscustomobject]@{isoPath='synthetic.iso'})
        $null=New-CleanupPlan -RunDir $creationDirectory -RunId $creationId -ScopeId $scope -ProviderSubRuns @([pscustomobject]@{provider='hyperv';id='provider-hyperv-builder'})
        function Test-HyperVAvailable { [pscustomobject]@{Available=$true} }
        function New-VHD { [CmdletBinding()]param($Path,$SizeBytes,[switch]$Dynamic) $null=New-Item -ItemType File -Path $Path }
        function New-VM { [CmdletBinding()]param($Name,$Generation,$MemoryStartupBytes,$VHDPath,$Path) [pscustomobject]@{Name=$Name;Id=$vmId} }
        function Set-VM { [CmdletBinding()]param($VM,$SmartPagingFilePath,$SnapshotFileLocation) throw 'SYNTHETIC_AFTER_CREATE_FAILURE' }
        Record 'Actual creator persists returned ID before first Set-VM failure' {
            $failureCode=''
            try { $null=New-HyperVWindowsImageBuilder -BuildId $creationId -StateRoot $stateRoot }
            catch { $failureCode=$_.Exception.Message; Write-Verbose $failureCode }
            $saved=Get-HyperVImageBuildPlan -BuildId $creationId -StateRoot $stateRoot
            $failureCode -ceq 'SYNTHETIC_AFTER_CREATE_FAILURE' -and $saved.builder.vmId -ceq $vmId -and $saved.builder.nativeBindingContract -ceq 'SqlServerLab.HyperVBuildNative/1.0'
        }
        $creationSaved=Get-HyperVImageBuildPlan -BuildId $creationId -StateRoot $stateRoot
        $savedWriter=(Get-Item Function:Write-HyperVImageBuildState).ScriptBlock
        function Write-HyperVImageBuildState { param($BuildDirectory,$State) throw 'SYNTHETIC_STATE_PERSIST_FAILURE' }
        Record 'Persistence failure explicitly requires Recovery instead of name adoption' {
            try { Set-HyperVBuildNativeBinding -BuildDirectory $creationDirectory -StateRoot $stateRoot -VM ([pscustomobject]@{Name=$creationSaved.builder.vmName;Id=$vmId}) -InstanceId image-builder -ChildVhdxPath (Join-Path (Read-LabHyperVResourceBinding -StateDirectory $creationDirectory -DataRoot $dataRoot).HyperVResourceRoot $creationSaved.builder.resourceRelativePath); $false }
            catch { $_.Exception.Message -ceq 'HYPERV_BUILD_NATIVE_BINDING_PERSIST_FAILED_RECOVERY_REQUIRED' }
        }
        Set-Item Function:Write-HyperVImageBuildState $savedWriter
        $sqlId=[guid]::NewGuid().ToString();$sqlDirectory=Join-Path $stateRoot "image-builds/hyperv-sql/$sqlId"
        $null=New-Item -ItemType Directory -Path $sqlDirectory -Force
        $plan=[pscustomobject]@{buildId=$sqlId;scopeId=$scope;updatedAt='';builder=$null;state='MEDIA_VERIFIED';sql=[pscustomobject]@{version='2025'};BuildDirectory=$sqlDirectory}
        Write-HyperVImageBuildState -BuildDirectory $sqlDirectory -State $plan
        $sqlBinding=Initialize-LabHyperVResourceBinding -ResourceId $sqlId -ResourceClass Build -StateDirectory $sqlDirectory -DataRoot $dataRoot
        $resourceRoot=$sqlBinding.HyperVResourceRoot;$vmName='synthetic-sql-builder';$diskPath=Join-Path $resourceRoot "$vmName.vhdx"
        $null=New-CleanupPlan -RunDir $sqlDirectory -RunId $sqlId -ScopeId $scope -ProviderSubRuns @([pscustomobject]@{id='provider-hyperv';provider='hyperv'})
        $null=Add-CleanupStep -RunDir $sqlDirectory -ResourceType vhdx -ResourceId $diskPath -Action remove -Provider hyperv
        $null=Add-CleanupStep -RunDir $sqlDirectory -ResourceType vm -ResourceId $vmName -Action remove -Provider hyperv
        $SqlVersion='2025';$MemoryStartupBytes=512MB;$labNetwork=[pscustomobject]@{Name='synthetic-network'}
        function New-VM { [CmdletBinding()]param($Name,$Generation,$MemoryStartupBytes,$VHDPath,$Path,$SwitchName) [pscustomobject]@{Name=$Name;Id=$vmId} }
        function ProductionCreationSlice([string]$Path,[string]$FunctionName,[string]$StartAssignment,[string]$EndCommand) {
            $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
            $function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $FunctionName},$true)
            $start=@($function.Body.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq $StartAssignment},$true))
            if($start.Count -ne 1){throw 'FIXTURE_CREATION_AST_NOT_UNIQUE'}
            $finish=@($function.Body.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq $EndCommand -and $node.Extent.StartOffset -gt $start[0].Extent.EndOffset},$true))[0]
            if(-not $finish){throw 'FIXTURE_CREATION_AST_END_MISSING'}
            $text=Get-Content -LiteralPath $Path -Raw
            [scriptblock]::Create($text.Substring($start[0].Extent.StartOffset,$finish.Extent.EndOffset-$start[0].Extent.StartOffset))
        }
        $sqlSlice=ProductionCreationSlice (Join-Path $Repository 'Private/HyperVSqlImageBuilder.ps1') Initialize-HyperVSqlFreshPreparedImageBuild '$vm' Set-VM
        Record 'Actual SQL fresh creation slice persists ID before Set-VM failure' {
            $failureCode='';try{. $sqlSlice}catch{$failureCode=$_.Exception.Message}
            $saved=Get-HyperVSqlImageBuildPlan -BuildId $sqlId -StateRoot $stateRoot
            $failureCode -ceq 'SYNTHETIC_AFTER_CREATE_FAILURE' -and $saved.builder.vmId -ceq $vmId -and $saved.builder.instanceId -ceq 'sql-image-2025'
        }
        $genericSlice=ProductionCreationSlice (Join-Path $Repository 'Providers/HyperV/HyperVProvider.ps1') New-HyperVInstance '$vmCreate' Set-VM
        function Invoke-LabProviderOperation { param($Provider,$Phase,$RunId,$StateRoot,$Command,$Action) [pscustomobject]@{Output=@(& $Action)} }
        $plan.builder=$null;Write-HyperVImageBuildState -BuildDirectory $sqlDirectory -State $plan
        $RunDirectory=$sqlDirectory;$RunId=$sqlId;$ResourceClass='Build';$InstanceId='sql-image-2025';$childVhdxPath=$diskPath
        $newVmParameters=@{Name=$vmName;Generation=2;MemoryStartupBytes=512MB;VHDPath=$diskPath;Path=$resourceRoot}
        Record 'Actual SQL clone provider creation slice preserves immediate native ID' {
            $failureCode='';try{. $genericSlice}catch{$failureCode=$_.Exception.Message}
            $saved=Get-HyperVSqlImageBuildPlan -BuildId $sqlId -StateRoot $stateRoot
            $failureCode -ceq 'SYNTHETIC_AFTER_CREATE_FAILURE' -and $saved.builder.vmId -ceq $vmId
        }
        $plan.builder=$null;Write-HyperVImageBuildState -BuildDirectory $sqlDirectory -State $plan
        Set-Item Function:Invoke-LabProviderOperation $actualProviderOperation
        function Write-LabProviderLog { param($Provider,$Phase,$Command,$Output,$ExitCode,$RunId,$StateRoot) throw 'SYNTHETIC_POST_CREATE_LOG_FAILURE' }
        Record 'Actual provider post-Action log failure preserves returned native ID' {
            $failureCode='';try{. $genericSlice}catch{$failureCode=$_.Exception.Message}
            $saved=Get-HyperVSqlImageBuildPlan -BuildId $sqlId -StateRoot $stateRoot
            $failureCode -ceq 'SYNTHETIC_POST_CREATE_LOG_FAILURE' -and $saved.builder.vmId -ceq $vmId -and
                (Get-HyperVBuildMutationContext -BuildDirectory $sqlDirectory -StateRoot $stateRoot -ExpectedScopeId $scope).Binding.ResourceClass -ceq 'Build'
        }
        $legacySql=Get-HyperVSqlImageBuildPlan -BuildId $sqlId -StateRoot $stateRoot
        $legacySql.state='MANUAL_ACTION_REQUIRED';$legacySql.builder.vmId=$null
        Write-HyperVImageBuildState -BuildDirectory $sqlDirectory -State $legacySql
        $script:secretCalls=0
        function Get-LabSecret {param($Path,$Name) $script:secretCalls++;throw 'SYNTHETIC_SECRET_BOUNDARY'}
        function Get-LabLicenseProfileSecret {param($Id,$StateRoot) $script:secretCalls++;throw 'SYNTHETIC_SECRET_BOUNDARY'}
        Record 'Actual SQL PrepareImage missing native ID blocks guest and secrets' { $script:guestCalls=0;(Rejected { Invoke-HyperVSqlPrepareAndGeneralize -BuildId $sqlId -StateRoot $stateRoot -Credential $credential }) -and $script:guestCalls -eq 0 -and $script:secretCalls -eq 0 }
        Record 'Actual SQL OOBE missing native ID blocks network and secrets' { (Rejected { Invoke-HyperVSqlUnattendedOobe -BuildId $sqlId -StateRoot $stateRoot }) -and $script:secretCalls -eq 0 }
        Record 'Actual SQL install missing native ID blocks guest and secrets' { $script:guestCalls=0;(Rejected { Invoke-HyperVSqlTestEnvironmentInstall -BuildId $sqlId -StateRoot $stateRoot -Credential $credential }) -and $script:guestCalls -eq 0 -and $script:secretCalls -eq 0 }
        $script:legacyConnections=0
        function Connect-HyperVLegacyWindowsWmiScope {param($Address,$Namespace,$Credential) $script:legacyConnections++;throw 'SYNTHETIC_LEGACY_CONNECTION'}
        Record 'Actual legacy task composition missing native ID blocks connection' { (Rejected { Invoke-HyperVLegacyGuestSystemScript -Build $legacySql -StateRoot $stateRoot -BuildId $sqlId -Address '192.0.2.1' -Credential $credential -Action SqlSetup -ScriptContent 'synthetic' }) -and $script:legacyConnections -eq 0 }
        $legacySql.state='SQL_READY_RUN';Write-HyperVImageBuildState -BuildDirectory $sqlDirectory -State $legacySql
        Record 'Actual SQL acceptance missing native ID blocks guest and secrets' { $script:guestCalls=0;(Rejected { Test-HyperVSqlAcceptanceEnvironment -BuildId $sqlId -StateRoot $stateRoot -Credential $credential }) -and $script:guestCalls -eq 0 -and $script:secretCalls -eq 0 }
        # Entire actual SQL publish with existing flattened output and real authorities.
        $disk=$diskPath;$flat=Join-Path $resourceRoot "sql-prepared-$sqlId.vhdx"
        $null=New-Item -ItemType Directory $resourceRoot -Force
        Set-Content -LiteralPath $disk 'synthetic';Set-Content -LiteralPath $flat 'synthetic'
        $native.Name=$vmName;$native.Id=$vmId;$native.State='Off';$native.Notes=ConvertTo-HyperVLabNotes -RunId $sqlId -ScopeId $scope -InstanceId sql-image-2025 -ChildVhdxPath $disk
        $nativeSet=@($native);$attached=$false;$readError=$false
        $legacySql.builder.vmId=$vmId
        $sqlPublishState=[pscustomobject]@{buildId=$sqlId;scopeId=$scope;updatedAt='';builder=$legacySql.builder;state='RESUME_PENDING';stateHistory=@();artifact=$null;sealPostconditions=$null;cleanupStatus=$null;
            setupEvidence=[pscustomobject]@{};generalizationEvidence=[pscustomobject]@{shutdownObserved=$true;challenge='synthetic'};manualAction=[pscustomobject]@{challenge='synthetic'};
            parentArtifact=[pscustomobject]@{platform=[pscustomobject]@{vmGeneration=2;secureBoot=$true;guestControl='powershell-direct'};operatingSystem=[pscustomobject]@{id='synthetic';version='1';edition='synthetic';installationType='synthetic';language='en-US'};license=[pscustomobject]@{type='test-only'}};
            sql=[pscustomobject]@{version='2025';edition='Developer';setupBuild='17.0.1000.0';features=@('SQL');license=[pscustomobject]@{type='developer'}}}
        $sqlPublishState.builder | Add-Member osDiskRelativePath ("resources/hyperv/$vmName.vhdx") -Force
        Write-HyperVSqlImageBuildState -BuildDirectory $sqlDirectory -State $sqlPublishState
        $sqlPlan=Read-LabWorkflowJson (Join-Path $sqlDirectory 'cleanup-plan.json')
        Write-LabArtifactJsonAtomic -Path (Join-Path $sqlDirectory 'cleanup-plan.json') -InputObject $sqlPlan
        Record 'Entire SQL existing flat without exact cleanup step prevents seal and import' {$script:publishImports=0;(RejectedCode {Publish-HyperVSqlPreparedImageBuild -BuildId $sqlId -StateRoot $stateRoot} 'HYPERV_BUILD_OUTPUT_DISK_NOT_PLANNED') -and $script:publishImports -eq 0 -and -not (Get-Item $flat).IsReadOnly}
        $null=Add-CleanupStep -RunDir $sqlDirectory -ResourceType vhdx -ResourceId $flat -Action remove -Provider hyperv
        $sqlPlan=Read-LabWorkflowJson (Join-Path $sqlDirectory 'cleanup-plan.json')
        $script:foreignFlat=$true
        function Get-VMHardDiskDrive {[CmdletBinding()]param([Parameter(ValueFromPipeline)]$VM) process {[pscustomobject]@{Path=if($VM.Id -ceq $vmId){$disk}else{$flat}}}}
        $nativeSet=@($native,[pscustomobject]@{Name='foreign';Id=[guid]::NewGuid().ToString();State='Running';Notes=''})
        Record 'Entire SQL existing flat foreign attachment prevents seal and import' {$script:publishImports=0;(RejectedCode {Publish-HyperVSqlPreparedImageBuild -BuildId $sqlId -StateRoot $stateRoot} 'HYPERV_BUILD_OFFLINE_DISK_FOREIGN_ATTACHMENT') -and $script:publishImports -eq 0 -and -not (Get-Item $flat).IsReadOnly}
        $nativeSet=@($native)
        function Test-HyperVVhdxCleanupDependencyChain {param($Path) [pscustomobject]@{Valid=(-not $script:publishDependencyInvalid);Code='SYNTHETIC_AVHDX_PRESENT'}}
        $script:publishDependencyInvalid=$true
        Record 'Entire SQL existing flat AVHDX dependency prevents seal and import' {$script:publishImports=0;(RejectedCode {Publish-HyperVSqlPreparedImageBuild -BuildId $sqlId -StateRoot $stateRoot} 'SYNTHETIC_AVHDX_PRESENT') -and $script:publishImports -eq 0 -and -not (Get-Item $flat).IsReadOnly}
        $script:publishDependencyInvalid=$false;$readError=$true
        Record 'Entire SQL existing flat native query failure prevents seal and import' {$script:publishImports=0;(RejectedCode {Publish-HyperVSqlPreparedImageBuild -BuildId $sqlId -StateRoot $stateRoot} 'SYNTHETIC_ACCESS_DENIED') -and $script:publishImports -eq 0 -and -not (Get-Item $flat).IsReadOnly}
        $readError=$false;$script:conversion=0
        function Convert-VHD {[CmdletBinding()]param($Path,$DestinationPath,$VHDType) $script:conversion++;Set-Content -LiteralPath $DestinationPath 'synthetic-converted'}
        function Invoke-LabProviderOperation {param($Provider,$Phase,$RunId,$StateRoot,$Command,$Action) & $Action}
        Record 'Entire SQL existing flat verifies output then imports without conversion' {$script:publishImports=0;$result=Publish-HyperVSqlPreparedImageBuild -BuildId $sqlId -StateRoot $stateRoot;$result.Status -ceq 'SQL_PREPARED_SEALED' -and $script:publishImports -eq 1 -and $script:conversion -eq 0 -and -not (Test-Path $flat) -and -not (Test-Path $disk)}
        $native.State='Off';Set-Content -LiteralPath $disk 'synthetic'
        Write-HyperVSqlImageBuildState -BuildDirectory $sqlDirectory -State $sqlPublishState
        $sqlPlan.steps=@($sqlPlan.steps|Where-Object {$_.resourceId -cne $flat})
        Write-LabArtifactJsonAtomic -Path (Join-Path $sqlDirectory 'cleanup-plan.json') -InputObject $sqlPlan
        Record 'Entire SQL new flat conversion registers exact output and completes cleanup' {$script:publishImports=0;$result=Publish-HyperVSqlPreparedImageBuild -BuildId $sqlId -StateRoot $stateRoot;$result.Status -ceq 'SQL_PREPARED_SEALED' -and $script:publishImports -eq 1 -and $script:conversion -eq 1 -and -not (Test-Path $flat) -and -not (Test-Path $disk)}
        return $cases.ToArray()
    } $fixtureRoot $repository $SqlPublicationOnly
    if($AsResults){return $results}
    $failed=@($results | Where-Object {-not $_.Success})
    if($failed.Count){Write-Host ($failed|Select-Object Name,Code|ConvertTo-Json -Compress)}
    Write-Host "Build authority: $($results.Count-$failed.Count) PASS, $($failed.Count) FAIL"
    if($failed.Count){exit 1}
}
finally {
    $env:SQL_SERVER_LAB_DATA_ROOT=$oldDataRoot
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $fixtureRoot){Remove-Item -LiteralPath $fixtureRoot -Recurse -Force}
}
