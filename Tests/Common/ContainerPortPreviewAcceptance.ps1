# Test-only helpers; no product exports and no standard/shared-host fallback.
function New-PortPreviewAcceptanceEvidenceDirectory {
    param($Module,[string]$RepositoryRoot)
    $path=Join-Path $RepositoryRoot ('.artifacts/test-runs/port-preview-'+[guid]::NewGuid().ToString('N'))
    & $Module {param($Path)$null=Assert-LabOwnedHostPath $Path} $path
    if(Test-Path -LiteralPath $path -ErrorAction Stop){throw 'PORT_ACCEPTANCE_EVIDENCE_EXISTS'}
    $null=New-Item -ItemType Directory -Path $path -ErrorAction Stop
    return $path
}

function Assert-PortPreviewAcceptanceLayout {
    param([string]$DataRoot,[string]$RepositoryRoot)
    if(-not [IO.Path]::IsPathFullyQualified($DataRoot)){throw 'PORT_ACCEPTANCE_ROOT_INVALID'}
    $root=[IO.Path]::GetFullPath($DataRoot).TrimEnd('\','/')
    $repo=[IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\','/')
    if([IO.Path]::GetFileName($root) -cnotmatch '^sql-lab-port-preview-[a-f0-9]{32}$' -or
        $root.StartsWith($repo+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
        $root -eq $repo -or (Test-Path -LiteralPath $root -ErrorAction Stop)){throw 'PORT_ACCEPTANCE_ROOT_INVALID'}
    return $root
}

function New-PortPreviewAcceptanceScope {
    param($Module,[string]$DataRoot,[string]$Provider,[string]$ParentOperationId)
    # Two fresh exact policies preserve both registration-parent custody and the
    # real runtime State child. No existing run or policy is moved or adopted.
    $null=Initialize-OwnedHostTestRoot -Module $Module -StateRoot $DataRoot -Providers @($Provider) -ParentOperationId $ParentOperationId
    $state=Join-Path $DataRoot State
    $null=Initialize-OwnedHostTestRoot -Module $Module -StateRoot $state -Providers @($Provider) -ParentOperationId $ParentOperationId
    return & $Module {
        param($Root,$State,$Operation)
        $parent=Get-LabOwnedHostPolicy -StateRoot $Root -Required
        $child=Get-LabOwnedHostPolicy -StateRoot $State -Required
        if($parent.ParentOperationId -cne $Operation -or $child.ParentOperationId -cne $Operation -or
            ($parent.RuntimePins|ConvertTo-Json -Depth 8 -Compress) -cne ($child.RuntimePins|ConvertTo-Json -Depth 8 -Compress)){throw 'PORT_ACCEPTANCE_POLICY_BINDING'}
        $null=Initialize-LabManagedDataRoot -DataRoot $Root -ControllerId ([guid]::NewGuid().ToString('D')) -Confirm:$false
        $config=Get-LabStorageConfiguration -DataRoot $Root
        if(@($config.LabDataLocations).Count -ne 1 -or $config.LabDataLocations[0].LabDataRoot -cne $Root){throw 'PORT_ACCEPTANCE_REGISTRATION_SCOPE'}
        $null=Write-LabStorageConfiguration -Configuration $config
        [pscustomobject]@{DataRoot=$Root;StateRoot=$State;ParentOperationId=$Operation
            ParentPolicyHash=(Get-FileHash (Join-Path $Root owned-host-policy.json)).Hash
            StatePolicyHash=(Get-FileHash (Join-Path $State owned-host-policy.json)).Hash
            MarkerHash=(Get-FileHash (Join-Path $Root .sql-server-lab-root.json)).Hash
            CatalogHash=(Get-FileHash (Join-Path $Root Catalog/storage-locations.json)).Hash}
    } $DataRoot $state $ParentOperationId
}

function Get-PortPreviewAcceptanceFileBinding {
    param([string]$DataRoot)
    $files=@(Get-ChildItem -LiteralPath $DataRoot -Recurse -Force -ErrorAction Stop)
    if($files.Count -gt 8192 -or @($files|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'PORT_ACCEPTANCE_FILE_SCOPE'}
    return @($files|Where-Object{-not $_.PSIsContainer}|Sort-Object FullName|ForEach-Object{
        [pscustomobject]@{Path=[IO.Path]::GetRelativePath($DataRoot,$_.FullName);Bytes=$_.Length;Sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
    })
}

function Invoke-PortPreviewAcceptanceObservations {
    param($Module,$Scope,[string]$RunId,[string]$Provider,[string]$RepositoryRoot)
    # Only interaction/output and transparent counters are substituted. Runtime
    # discovery, immutable pins, origin/label checks and Inspect remain real.
    return & $Module {
        param($Scope,$RunId,$Provider,$Repo)
        $binding=Get-LabDiagnosticBinding -RunId $RunId -InstanceId primary -DataRoot $Scope.DataRoot
        $origin=Get-LabOwnedHostRunPolicy -RunId $RunId -StateRoot $Scope.StateRoot
        if($binding.StateRoot -cne $Scope.StateRoot -or $binding.Run.metadata.persistentData -ne $false -or
            $binding.Run.state -cne 'RUNNING' -or $origin.StateRoot -cne $Scope.StateRoot){throw 'PORT_ACCEPTANCE_RUN_BINDING'}
        $before=Get-LabContainerReconcileContext -RunId $RunId -InstanceId primary -StateRoot $Scope.StateRoot
        $current=[int]$before.CurrentPort;$requested=if($current -eq 65535){65534}else{$current+1}
        if($current -lt 1024 -or $current -gt 65535){throw 'PORT_ACCEPTANCE_CURRENT_PORT'}
        $script:portAcceptancePublicBody=${function:Get-SqlServerLabReconcilePlan}
        $script:portAcceptanceNativeBody=${function:Invoke-LabOwnedHostNativeProcess}
        $saved=@{}
        foreach($name in @('Get-SqlServerLabReconcilePlan','Invoke-LabOwnedHostNativeProcess','Write-LabInfo','Write-LabWarning','Write-LabError','Wait-LabConsoleAcknowledgement','Show-LabSubMenu','Read-LabConsoleTextInput','Invoke-LabConsoleMenu',
                'Get-LabSecret','Invoke-SqlQuery','Test-LabEndpointBinding','Repair-LabContainerReconcileJournal','New-LabContainerReconcileJournal','Invoke-LabContainerReconcileCommand','Update-SqlServerLabContainer','Invoke-SqlServerLabWorkflowAction','Invoke-LabActionWithResult')){
            $saved[$name]=(Get-Item ('Function:'+ $name) -ErrorAction SilentlyContinue).ScriptBlock
        }
        try {
        foreach($name in @('Get-LabSecret','Invoke-SqlQuery','Test-LabEndpointBinding','Repair-LabContainerReconcileJournal','New-LabContainerReconcileJournal','Invoke-LabContainerReconcileCommand','Update-SqlServerLabContainer','Invoke-SqlServerLabWorkflowAction','Invoke-LabActionWithResult')){
            Set-Item ('Function:script:'+$name) {throw 'PORT_ACCEPTANCE_FORBIDDEN_PREVIEW_EFFECT'}
        }
        $script:portAcceptanceCalls=0;$script:portAcceptanceReads=0
        $script:portAcceptancePlans=[Collections.Generic.List[object]]::new()
        $script:portAcceptanceText=[Collections.Generic.List[string]]::new()
        $script:portAcceptanceRoot=$Scope.DataRoot;$script:portAcceptanceRun=$RunId;$script:portAcceptanceState=$Scope.StateRoot
        function script:Get-SqlServerLabReconcilePlan {
            param($RunId,$InstanceId,$StateRoot,[switch]$ContainerPortPreview,[int]$Port)
            if($RunId -cne $script:portAcceptanceRun -or $InstanceId -cne 'primary' -or $StateRoot -cne $script:portAcceptanceState -or -not $ContainerPortPreview){throw 'PORT_ACCEPTANCE_PUBLIC_SCOPE'}
            $script:portAcceptanceCalls++
            $plan=& $script:portAcceptancePublicBody @PSBoundParameters
            $script:portAcceptancePlans.Add($plan);return $plan
        }
        function script:Invoke-LabOwnedHostNativeProcess {
            param($StartInfo,[int]$TimeoutSeconds,[int]$MaximumBytes)
            $script:portAcceptanceReads++
            & $script:portAcceptanceNativeBody @PSBoundParameters
        }
        function script:Write-LabInfo {param($Message);$script:portAcceptanceText.Add([string]$Message)}
        function script:Write-LabWarning {param($Message);$script:portAcceptanceText.Add([string]$Message)}
        function script:Write-LabError {param($Message);$script:portAcceptanceText.Add([string]$Message)}
        function script:Wait-LabConsoleAcknowledgement {}
        function script:Show-LabSubMenu {param($ScreenId,$Title,$Subtitle,$Items);$Items}
        function script:Read-LabConsoleTextInput {
            param($Prompt)
            $script:portAcceptanceInput++
            if($script:portAcceptanceCase -ceq 'cancel'){return [pscustomobject]@{Status='Cancelled';Value=''}}
            [pscustomobject]@{Status='Confirmed';Value=$(if($script:portAcceptanceInput -eq 1){$script:portAcceptanceRoot}else{$script:portAcceptancePort})}
        }
        function script:Invoke-LabConsoleMenu {
            param($ScreenId,$Title,$Items)
            $id=if($ScreenId -ceq 'container-port-run'){$script:portAcceptanceRun}else{'primary'}
            $item=@($Items|Where-Object Id -CEQ $id)
            if($item.Count -ne 1){throw 'PORT_ACCEPTANCE_MENU_SCOPE'}
            [pscustomobject]@{Status='Selected';SelectedItem=[pscustomobject]@{Id=$id}}
        }
        $plans=@(foreach($port in @($requested,$current,$requested)){
            Get-SqlServerLabReconcilePlan -RunId $RunId -InstanceId primary -StateRoot $Scope.StateRoot -ContainerPortPreview -Port $port
        })
        foreach($plan in $plans){$null=ConvertTo-LabContainerPortBrowserPlan -Plan $plan -Provider $Provider;if($plan.Status -cne 'PLAN_ONLY'){throw 'PORT_ACCEPTANCE_NATIVE_FORM_BLOCKED'}}
        if($plans[0].NoChange -or -not $plans[1].NoChange -or $plans[0].ObservationKey -cne $plans[2].ObservationKey -or
            $plans[0].ObservationKey -ceq $plans[1].ObservationKey -or
            ($plans[0].Preview.Mounts|ConvertTo-Json -Compress) -cne ($plans[1].Preview.Mounts|ConvertTo-Json -Compress)){throw 'PORT_ACCEPTANCE_CONTENT_BINDING'}
        $menu=@(Show-LabWorkspaceMenu|Where-Object Id -CEQ ContainerPortPreview)
        if($menu.Count -ne 1){throw 'PORT_ACCEPTANCE_MENU_MISSING'}
        foreach($case in @('valid','cancel','invalid')){
            $script:portAcceptanceCase=$case;$script:portAcceptanceInput=0;$script:portAcceptancePort=if($case -ceq 'invalid'){'1023'}else{[string]$requested}
            $calls=$script:portAcceptanceCalls;$reads=$script:portAcceptanceReads
            Invoke-LabMenuAction -ActionName ContainerPortPreview
            $expected=if($case -ceq 'valid'){1}else{0}
            if($script:portAcceptanceCalls-$calls -ne $expected -or ($expected -eq 0 -and $script:portAcceptanceReads -ne $reads)){throw 'PORT_ACCEPTANCE_CLI_EFFECT'}
        }
        # Execute the exact server dispatch AST with deterministic in-process
        # request/response objects. No listener or rendered browser is claimed.
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo Tools/Start-SqlServerLabUi.ps1),[ref]$tokens,[ref]$errors)
        $routes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq "`$path -eq '/api/container-port-preview'"},$true))
        if($errors.Count -or $routes.Count -ne 1){throw 'PORT_ACCEPTANCE_HTTP_ROUTE'}
        $dispatch=[scriptblock]::Create('foreach($iteration in 1){'+$routes[0].Extent.Text+"`nthrow 'FALLTHROUGH'"+'}')
        $held=$ExecutionContext.SessionState.Module
        function Get-Module {param($Name);if($Name -cne 'SqlServerLab'){throw 'PORT_ACCEPTANCE_HTTP_MODULE'};$held}
        function Write-UiResponse {param($Context,$Body,$ContentType,$StatusCode=200);$script:portAcceptanceResponse=[pscustomobject]@{Status=$StatusCode;Body=$Body}}
        foreach($case in @('Read','Preview','Invalid','ArrayAction')){
            $body=if($case -ceq 'Read'){'{"Action":"Read"}'}elseif($case -ceq 'ArrayAction'){'{"Action":["Read"]}'}else{@{Action='Preview';RunId=$RunId;InstanceId='primary';Port=$(if($case -ceq 'Invalid'){1023}else{$requested})}|ConvertTo-Json -Compress}
            $stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($body));$Port=19499;$path='/api/container-port-preview'
            $request=[pscustomobject]@{HttpMethod='POST';ContentType='application/json';Headers=@{Origin='http://127.0.0.1:19499'};Url=[uri]'http://127.0.0.1:19499/api/container-port-preview';LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,19499);RemoteEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,1);InputStream=$stream}
            $context=[pscustomobject]@{Request=$request};$calls=$script:portAcceptanceCalls;$reads=$script:portAcceptanceReads
            try{& $dispatch}finally{$stream.Dispose()}
            $expected=if($case -ceq 'Preview'){1}else{0};$status=if($case -cin @('Invalid','ArrayAction')){400}else{200}
            if($script:portAcceptanceResponse.Status -ne $status -or $script:portAcceptanceCalls-$calls -ne $expected -or
                ($expected -eq 0 -and $script:portAcceptanceReads -ne $reads)){throw 'PORT_ACCEPTANCE_HTTP_EFFECT'}
            if($case -ceq 'Preview'){
                # The route validates before serialization. Compare its exact JSON
                # projection; PS JSON integer roundtripping may change Int32 to Int64.
                $expectedBody=ConvertTo-LabContainerPortBrowserPlan -Plan $script:portAcceptancePlans[$script:portAcceptancePlans.Count-1] -Provider $Provider
                if($script:portAcceptanceResponse.Body -cne ($expectedBody|ConvertTo-Json -Depth 8 -Compress)){throw 'PORT_ACCEPTANCE_HTTP_PROJECTION'}
            }
        }
        $after=Get-LabContainerReconcileContext -RunId $RunId -InstanceId primary -StateRoot $Scope.StateRoot
        $sourceBefore=@($before.ContainerId,$before.Inspect.Image,$before.Inspect.Config,$before.Inspect.HostConfig,$before.Inspect.Mounts)|ConvertTo-Json -Depth 50 -Compress
        $sourceAfter=@($after.ContainerId,$after.Inspect.Image,$after.Inspect.Config,$after.Inspect.HostConfig,$after.Inspect.Mounts)|ConvertTo-Json -Depth 50 -Compress
        if($sourceBefore -cne $sourceAfter){throw 'PORT_ACCEPTANCE_NATIVE_SOURCE_DRIFT'}
        [pscustomobject]@{Core='CHANGED_NOOP_REPEAT_PASSED';Cli='ACTUAL_MENU_ROUTE_PASSED';Http='ACTUAL_INPROCESS_SERVER_ROUTE_PASSED';PublicPreviewCalls=$script:portAcceptanceCalls;PinnedReadCalls=$script:portAcceptanceReads;NativeSourceUnchanged=$true;RenderedBrowser='NOT_EXECUTED';HttpNetworkTransport='NOT_EXECUTED';Endpoint='NOT_CHECKED';SqlPreview='NOT_CHECKED';Apply='NOT_IMPLEMENTED'}
        } finally {
            foreach($name in $saved.Keys){
                if($saved[$name]){Set-Item ('Function:script:'+$name) $saved[$name]}
                else{Remove-Item ('Function:script:'+$name) -ErrorAction SilentlyContinue}
            }
        }
    } $Scope $RunId $Provider $RepositoryRoot
}

function Get-PortPreviewAcceptanceCustody {
    param($Module,$Scope,[string]$RunId,[string]$Provider)
    & $Module {
        param($Scope,$Run,$Provider)
        $policy=Get-LabOwnedHostRunPolicy -StateRoot $Scope.StateRoot -RunId $Run
        if(-not $policy -or $policy.ParentOperationId -cne $Scope.ParentOperationId){throw 'PORT_ACCEPTANCE_CUSTODY'}
        $context=Get-LabContainerReconcileContext -RunId $Run -InstanceId primary -StateRoot $Scope.StateRoot
        if($context.Provider -cne $Provider -or $context.ContainerId -cnotmatch '^[a-f0-9]{64}$'){throw 'PORT_ACCEPTANCE_CUSTODY'}
        $null=Assert-LabOwnedHostContainerEffect -StateRoot $Scope.StateRoot -RunId $Run -Provider $Provider -ContainerId $context.ContainerId
        $directory=Join-Path $Scope.StateRoot "runs/$Run/owned-host-containers"
        $created=@(Get-ChildItem -LiteralPath $directory -Filter '*.created.json' -File -ErrorAction Stop)
        if($created.Count -ne 1){throw 'PORT_ACCEPTANCE_CUSTODY'}
        $receipt=Read-LabOwnedHostRecord $created[0].FullName
        $intentPath=Join-Path $directory ($receipt.IntentId+'.intent.json')
        $intent=Read-LabOwnedHostRecord $intentPath
        if($intent.ContainerName -cne $context.ContainerName -or $intent.RunId -cne $Run){throw 'PORT_ACCEPTANCE_CUSTODY'}
        $volumes=@(foreach($mount in @($context.Inspect.Mounts|Where-Object Type -CEQ volume)){
            $volume=Get-LabOwnedHostVolumeReceipt -StateRoot $Scope.StateRoot -Provider $Provider -VolumeName $mount.Name
            if($volume.RunId -cne $Run){throw 'PORT_ACCEPTANCE_VOLUME_CUSTODY'}
            [pscustomobject]@{Name=$volume.VolumeName;ReceiptHash=(Get-FileHash -LiteralPath (Join-Path $Scope.StateRoot "owned-host-volumes/$Provider-$($volume.VolumeName).created.json")).Hash;IntentHash=(Get-FileHash -LiteralPath (Join-Path $Scope.StateRoot "owned-host-volumes/$Provider-$($volume.VolumeName).intent.json")).Hash}
        })
        [pscustomobject]@{RunId=$Run;ScopeId=$context.Run.scopeId;IntentId=$receipt.IntentId;ContainerId=$context.ContainerId;ContainerName=$context.ContainerName;Volumes=$volumes;
            ContainerReceiptHash=(Get-FileHash -LiteralPath $created[0].FullName).Hash;IntentHash=(Get-FileHash -LiteralPath $intentPath).Hash}
    } $Scope $RunId $Provider
}

function Remove-PortPreviewAcceptanceScope {
    param($Module,$Scope,$Custody,[string]$Provider,[bool]$UnreturnedCreation,[bool]$Completed,[string]$EvidenceRoot)
    # Failure retains parent registration, child policy and journals together.
    if($UnreturnedCreation -or -not $Scope -or -not $Custody){return [pscustomobject]@{Status='RECOVERY_REQUIRED';RootRemoved=$false}}
    foreach($id in @($Custody.RunId,$Custody.IntentId)){
        $parsed=[guid]::Empty
        if(-not [guid]::TryParseExact([string]$id,'D',[ref]$parsed) -or $parsed -eq [guid]::Empty){throw 'PORT_ACCEPTANCE_CUSTODY_ID_INVALID'}
    }
    if($Custody.ContainerId -cnotmatch '^[a-f0-9]{64}$' -or $Custody.ContainerName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$' -or
        $Scope.StateRoot -cne (Join-Path $Scope.DataRoot State) -or [IO.Path]::GetFileName($Scope.DataRoot) -cnotmatch '^sql-lab-port-preview-[a-f0-9]{32}$' -or
        @($Custody.Volumes).Count -gt 128){throw 'PORT_ACCEPTANCE_CUSTODY_ID_INVALID'}
    foreach($volume in @($Custody.Volumes)){if($volume.Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$'){throw 'PORT_ACCEPTANCE_CUSTODY_ID_INVALID'}}
    if(-not $EvidenceRoot){throw 'PORT_ACCEPTANCE_EVIDENCE_MISSING'}
    $evidenceFull=[IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\','/')
    $runtimeFull=[IO.Path]::GetFullPath($Scope.DataRoot).TrimEnd('\','/')
    if($evidenceFull -ceq $runtimeFull -or $evidenceFull.StartsWith($runtimeFull+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'PORT_ACCEPTANCE_EVIDENCE_INSIDE_RUNTIME_ROOT'}
    & $Module {param($Path)$null=Assert-LabOwnedHostPath $Path} $EvidenceRoot
    & $Module {
        param($Scope,$Custody,$Provider)
        $parent=Get-LabOwnedHostPolicy -StateRoot $Scope.DataRoot -Required
        $child=Get-LabOwnedHostRunPolicy -StateRoot $Scope.StateRoot -RunId $Custody.RunId
        if(-not $child -or $parent.ParentOperationId -cne $Scope.ParentOperationId -or $child.ParentOperationId -cne $Scope.ParentOperationId){throw 'PORT_ACCEPTANCE_POLICY_DRIFT'}
        $directory=Join-Path $Scope.StateRoot "runs/$($Custody.RunId)/owned-host-containers"
        foreach($entry in @(@{Path=(Join-Path $Scope.DataRoot 'owned-host-policy.json');Hash=$Scope.ParentPolicyHash},
                @{Path=(Join-Path $Scope.StateRoot 'owned-host-policy.json');Hash=$Scope.StatePolicyHash},
                @{Path=(Join-Path $Scope.DataRoot '.sql-server-lab-root.json');Hash=$Scope.MarkerHash},
                @{Path=(Join-Path $Scope.DataRoot 'Catalog/storage-locations.json');Hash=$Scope.CatalogHash},
                @{Path=(Join-Path $directory ($Custody.IntentId+'.created.json'));Hash=$Custody.ContainerReceiptHash},
                @{Path=(Join-Path $directory ($Custody.IntentId+'.intent.json'));Hash=$Custody.IntentHash})){
            $null=Assert-LabOwnedHostPath $entry.Path
            if((Get-FileHash -LiteralPath $entry.Path -ErrorAction Stop).Hash -cne $entry.Hash){throw 'PORT_ACCEPTANCE_CLAIM_DRIFT'}
        }
        $receipt=Read-LabOwnedHostRecord (Join-Path $directory ($Custody.IntentId+'.created.json'))
        $intent=Read-LabOwnedHostRecord (Join-Path $directory ($Custody.IntentId+'.intent.json'))
        if($receipt.ContainerId -cne $Custody.ContainerId -or $receipt.RunId -cne $Custody.RunId -or
            $receipt.Provider -cne $Provider -or $intent.ContainerName -cne $Custody.ContainerName){throw 'PORT_ACCEPTANCE_CONTAINER_CUSTODY_DRIFT'}
        $null=Assert-LabOwnedHostContainerEffect -StateRoot $Scope.StateRoot -RunId $Custody.RunId -Provider $Provider -ContainerId $Custody.ContainerId
        foreach($volume in @($Custody.Volumes)){
            foreach($entry in @(@{Suffix='created';Hash=$volume.ReceiptHash},@{Suffix='intent';Hash=$volume.IntentHash})){
                $path=Join-Path $Scope.StateRoot "owned-host-volumes/$Provider-$($volume.Name).$($entry.Suffix).json"
                $null=Assert-LabOwnedHostPath $path
                if((Get-FileHash -LiteralPath $path -ErrorAction Stop).Hash -cne $entry.Hash){throw 'PORT_ACCEPTANCE_VOLUME_CUSTODY_DRIFT'}
            }
            $receipt=Get-LabOwnedHostVolumeReceipt -StateRoot $Scope.StateRoot -Provider $Provider -VolumeName $volume.Name
            if($receipt.RunId -cne $Custody.RunId -or $receipt.Provider -cne $Provider -or $receipt.VolumeName -cne $volume.Name){throw 'PORT_ACCEPTANCE_VOLUME_CUSTODY_DRIFT'}
        }
    } $Scope $Custody $Provider
    $removed=Remove-SqlServerLab -RunId $Custody.RunId -StateRoot $Scope.StateRoot -Force -Confirm:$false
    if($removed.Status -cne 'REMOVED'){throw 'PORT_ACCEPTANCE_CLEANUP_UNCONFIRMED'}
    & $Module {
        param($Scope,$Custody,$Provider,$Completed,$EvidenceRoot)
        $parent=Get-LabOwnedHostPolicy -StateRoot $Scope.DataRoot -Required
        $child=Get-LabOwnedHostPolicy -StateRoot $Scope.StateRoot -Required
        if($parent.ParentOperationId -cne $Scope.ParentOperationId -or $child.ParentOperationId -cne $Scope.ParentOperationId){throw 'PORT_ACCEPTANCE_POLICY_DRIFT'}
        $run=Get-LabRunState -RunId $Custody.RunId -StateRoot $Scope.StateRoot
        $runDirectory=Join-Path $Scope.StateRoot ('runs/'+$Custody.RunId)
        $planPath=Assert-LabOwnedHostPath (Join-Path $runDirectory cleanup-plan.json)
        $plan=Get-Content -LiteralPath $planPath -Raw -ErrorAction Stop|ConvertFrom-Json -Depth 30
        if($run.state -cne 'REMOVED' -or $run.scopeId -cne $Custody.ScopeId -or $plan.runId -cne $Custody.RunId -or
            $plan.scopeId -cne $Custody.ScopeId -or $plan.status -cne 'COMPLETED' -or @($plan.steps|Where-Object state -CNE COMPLETED).Count){throw 'PORT_ACCEPTANCE_CLEANUP_UNCONFIRMED'}
        $terminal=[pscustomobject]@{RunStateSha256=(Get-FileHash -LiteralPath (Join-Path $runDirectory run-state.json)).Hash;CleanupPlanSha256=(Get-FileHash -LiteralPath $planPath).Hash}
        foreach($path in @(@{Path=(Join-Path $Scope.DataRoot 'owned-host-policy.json');Hash=$Scope.ParentPolicyHash},
                @{Path=(Join-Path $Scope.StateRoot 'owned-host-policy.json');Hash=$Scope.StatePolicyHash},
                @{Path=(Join-Path $Scope.DataRoot '.sql-server-lab-root.json');Hash=$Scope.MarkerHash},
                @{Path=(Join-Path $Scope.DataRoot 'Catalog/storage-locations.json');Hash=$Scope.CatalogHash})){
            $null=Assert-LabOwnedHostPath $path.Path
            if((Get-FileHash -LiteralPath $path.Path -ErrorAction Stop).Hash -cne $path.Hash){throw 'PORT_ACCEPTANCE_CLAIM_DRIFT'}
        }
        $read=Invoke-LabOwnedHostPinnedCommand -StateRoot $Scope.StateRoot -Provider $Provider -Arguments @('ps','-a','--no-trunc','--filter',('name=^'+[regex]::Escape($Custody.ContainerName)+'$'),'--format','{{.ID}}')
        if($read.ExitCode -ne 0 -or $read.Stdout.Trim()){throw 'PORT_ACCEPTANCE_CONTAINER_ABSENCE_UNCONFIRMED'}
        foreach($volume in @($Custody.Volumes)){
            $read=Invoke-LabOwnedHostPinnedCommand -StateRoot $Scope.StateRoot -Provider $Provider -Arguments @('volume','ls','--filter',('name=^'+[regex]::Escape($volume.Name)+'$'),'--format','{{.Name}}')
            if($read.ExitCode -ne 0 -or $read.Stdout.Trim()){throw 'PORT_ACCEPTANCE_VOLUME_ABSENCE_UNCONFIRMED'}
        }
        $runs=@(Get-ChildItem -LiteralPath (Join-Path $Scope.StateRoot runs) -Directory -ErrorAction Stop)
        if($runs.Count -ne 1 -or $runs[0].Name -cne $Custody.RunId){throw 'PORT_ACCEPTANCE_EXTRA_RUN'}
        if(-not $Completed){return [pscustomobject]@{Status='OWN_RESOURCES_REMOVED_ROOT_RETAINED';RootRemoved=$false}}
        $root=Assert-LabOwnedHostPath $Scope.DataRoot
        if([IO.Path]::GetFileName($root) -cnotmatch '^sql-lab-port-preview-[a-f0-9]{32}$' -or
            $Scope.StateRoot -cne (Join-Path $root State) -or
            @((Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop)|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'PORT_ACCEPTANCE_DELETE_SCOPE'}
        $preserved=[Collections.Generic.List[object]]::new()
        foreach($entry in @(@{Source=(Join-Path $runDirectory run-state.json);Hash=$terminal.RunStateSha256;Name='terminal-run-state.private.json'},
                @{Source=$planPath;Hash=$terminal.CleanupPlanSha256;Name='terminal-cleanup-plan.private.json'})){
            $source=Assert-LabOwnedHostPath $entry.Source
            $destination=Assert-LabOwnedHostPath (Join-Path $EvidenceRoot $entry.Name)
            $sourceStream=$null;$output=$null
            try {
                $sourceStream=[IO.FileStream]::new($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                if($sourceStream.Length -gt 1MB){throw 'PORT_ACCEPTANCE_TERMINAL_EVIDENCE_LIMIT'}
                $bytes=[byte[]]::new([int]$sourceStream.Length);$offset=0
                while($offset -lt $bytes.Length){$read=$sourceStream.Read($bytes,$offset,$bytes.Length-$offset);if($read -eq 0){throw 'PORT_ACCEPTANCE_TERMINAL_EVIDENCE_SHORT_READ'};$offset+=$read}
                if($sourceStream.ReadByte() -ne -1 -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $entry.Hash){throw 'PORT_ACCEPTANCE_TERMINAL_EVIDENCE_DRIFT'}
                $output=[IO.FileStream]::new($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $output.Write($bytes,0,$bytes.Length)
            } finally {if($output){$output.Dispose()};if($sourceStream){$sourceStream.Dispose()}}
            $null=Assert-LabOwnedHostPath $destination
            if((Get-FileHash -LiteralPath $destination).Hash -cne $entry.Hash -or (Get-Item -LiteralPath $destination).Length -ne $bytes.Length){throw 'PORT_ACCEPTANCE_TERMINAL_EVIDENCE_COPY_FAILED'}
            $preserved.Add([pscustomobject]@{RelativeEvidencePath=$entry.Name;Sha256=$entry.Hash;Bytes=$bytes.Length})
        }
        # Same-user FS checks are not an atomic filesystem transaction.
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
        if(Test-Path -LiteralPath $root -ErrorAction Stop){throw 'PORT_ACCEPTANCE_ROOT_REMAINS'}
        [pscustomobject]@{Status='CLEANED';RootRemoved=$true;ResourcesAbsent=$true;TerminalEvidence=@($preserved)}
    } $Scope $Custody $Provider $Completed $EvidenceRoot
}
