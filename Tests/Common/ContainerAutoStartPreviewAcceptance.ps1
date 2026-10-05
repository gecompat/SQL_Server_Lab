# Test-only acceptance: default observes public core without overrides. ConsoleOnly temporarily instruments UI and transparent public/native-leaf observers; original bodies are restored and returned plans remain untouched.
function Write-AutoStartPreviewAcceptanceObservation {
    param($Plan,[string]$Provider,[int]$Ordinal,[string]$EvidenceRoot,[string]$RepositoryRoot,$Scope)
    function Scalar($value,[string[]]$allowed){if($value -isnot [string] -or $value -cnotin $allowed){throw 'AUTOSTART_ACCEPTANCE_DTO_INVALID'}}
    Scalar $Provider @('docker','podman')
    Scalar $Plan.Contract.Name @('SqlServerLab.ContainerAutoStartPreview')
    Scalar $Plan.Contract.Version @('1.0')
    Scalar $Plan.Mode @('CONTAINER_AUTOSTART_PREVIEW_PLAN_ONLY')
    Scalar $Plan.Status @('PLAN_ONLY','BLOCKED','UNSUPPORTED')
    Scalar $Plan.Reason @('AUTOSTART_PREVIEW_BINDING_UNAVAILABLE','AUTOSTART_PREVIEW_PROVIDER_UNSUPPORTED','AUTOSTART_PREVIEW_PROTECTED_TARGET',
        'AUTOSTART_PREVIEW_RUNNING_REQUIRED','AUTOSTART_PREVIEW_JOURNAL_BLOCKED','AUTOSTART_PREVIEW_TOPOLOGY_UNSUPPORTED',
        'AUTOSTART_PREVIEW_LIMITS_UNKNOWN','AUTOSTART_PREVIEW_MOUNTS_UNSUPPORTED','AUTOSTART_PREVIEW_POLICY_UNKNOWN',
        'AUTOSTART_PREVIEW_POLICY_DRIFTED','AUTOSTART_PREVIEW_POLICY_UNSUPPORTED','AUTOSTART_PREVIEW_APPLY_NOT_IMPLEMENTED')
    if($Ordinal -lt 1 -or $Ordinal -gt 5 -or $Plan.CanApply -isnot [bool] -or $Plan.CanApply -or
        $Plan.MutationAllowed -isnot [bool] -or $Plan.MutationAllowed -or $Plan.Actions -isnot [array] -or $Plan.Actions.Count){throw 'AUTOSTART_ACCEPTANCE_DTO_INVALID'}
    if($null -ne $Plan.Provider){Scalar $Plan.Provider @($Provider)}
    Scalar $Plan.Actual.Evidence @('MEASURED','UNKNOWN');Scalar $Plan.Actual.SqlBinding @('SINGLE_LOOPBACK_1433_TCP','UNKNOWN')
    Scalar $Plan.Actual.Lifecycle @('RUNNING','UNKNOWN');Scalar $Plan.Actual.AutoStart @('ON','OFF','UNKNOWN','DRIFTED')
    Scalar $Plan.Desired.AutoStartChange @('SAME_POLICY','DIFFERENT_POLICY','UNKNOWN');Scalar $Plan.ChangeClass @('no-op','recreate','unsupported')
    if($null -ne $Plan.NoChange -and $Plan.NoChange -isnot [bool]){throw 'AUTOSTART_ACCEPTANCE_DTO_INVALID'}
    Scalar $Plan.Preview.Downtime @('NONE','REQUIRED','UNKNOWN')
    foreach($field in @('Endpoint','Sql','Backup','HostLogin')){Scalar $Plan.Preview.$field @('NOT_CHECKED')}
    Scalar $Plan.Preview.DataImpact @('NOT_VERIFIED')
    if($null -ne $Plan.ObservationKey -and ($Plan.ObservationKey -isnot [string] -or $Plan.ObservationKey -cnotmatch '^[a-f0-9]{64}$')){throw 'AUTOSTART_ACCEPTANCE_DTO_INVALID'}
    $mounts=$null
    if($null -ne $Plan.Preview.Mounts){
        $m=$Plan.Preview.Mounts;Scalar $m.Status @('MEASURED','UNKNOWN');Scalar $m.VolumeOwnership @('NOT_CHECKED')
        $mounts=[ordered]@{Status=$m.Status;VolumeOwnership='NOT_CHECKED'}
        foreach($field in @('TotalMountCount','VolumeMountCount','HostBindCount','WritableHostBindCount','OtherMountCount')){
            $v=$m.$field
            if($m.Status -ceq 'UNKNOWN'){if($null -ne $v){throw 'AUTOSTART_ACCEPTANCE_DTO_INVALID'}}
            elseif($v -isnot [int] -and $v -isnot [long] -or $v -lt 0 -or $v -gt 1024){throw 'AUTOSTART_ACCEPTANCE_DTO_INVALID'}
            $mounts[$field]=$v
        }
        if($m.Status -ceq 'MEASURED' -and ($m.TotalMountCount -ne ($m.VolumeMountCount+$m.HostBindCount+$m.OtherMountCount) -or $m.WritableHostBindCount -gt $m.HostBindCount)){throw 'AUTOSTART_ACCEPTANCE_DTO_INVALID'}
    }
    if($Plan.Status -ceq 'PLAN_ONLY' -and ($Plan.Reason -cne 'AUTOSTART_PREVIEW_APPLY_NOT_IMPLEMENTED' -or $Plan.Provider -cne $Provider -or
        $Plan.Actual.Evidence -cne 'MEASURED' -or $Plan.Actual.SqlBinding -cne 'SINGLE_LOOPBACK_1433_TCP' -or $Plan.Actual.Lifecycle -cne 'RUNNING' -or
        $Plan.Actual.AutoStart -cnotin @('ON','OFF') -or $Plan.NoChange -isnot [bool] -or $null -eq $mounts -or $mounts.Status -cne 'MEASURED' -or
        $Plan.ObservationKey -isnot [string])){throw 'AUTOSTART_ACCEPTANCE_DTO_INVALID'}
    # Only fixed categories/counts are projected; arbitrary extra DTO fields,
    # content key, raw policy, IDs, ports, paths and inspect never enter payload.
    $payload=[ordered]@{Contract='SqlServerLab.AutoStartAcceptanceObservation/1.0';PublicCallOrdinal=$Ordinal;Provider=$Provider;
        Status=$Plan.Status;Reason=$Plan.Reason;CanApply=$false;MutationAllowed=$false;
        Actual=[ordered]@{Evidence=$Plan.Actual.Evidence;SqlBinding=$Plan.Actual.SqlBinding;Lifecycle=$Plan.Actual.Lifecycle;AutoStart=$Plan.Actual.AutoStart};
        Desired=[ordered]@{AutoStartChange=$Plan.Desired.AutoStartChange};NoChange=$Plan.NoChange;ChangeClass=$Plan.ChangeClass;
        Preview=[ordered]@{Downtime=$Plan.Preview.Downtime;Endpoint='NOT_CHECKED';Sql='NOT_CHECKED';Backup='NOT_CHECKED';HostLogin='NOT_CHECKED';DataImpact='NOT_VERIFIED';Mounts=$mounts}}
    if(-not [IO.Path]::IsPathFullyQualified($EvidenceRoot) -or -not [IO.Path]::IsPathFullyQualified($RepositoryRoot) -or -not [IO.Path]::IsPathFullyQualified([string]$Scope.DataRoot)){throw 'AUTOSTART_ACCEPTANCE_EVIDENCE_SCOPE'}
    $root=[IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\','/');$parent=[IO.Path]::GetFullPath((Join-Path $RepositoryRoot '.artifacts/test-runs')).TrimEnd('\','/')
    $runtime=[IO.Path]::GetFullPath($Scope.DataRoot).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($root) -ine $parent -or [IO.Path]::GetFileName($root) -cnotmatch '^port-preview-[a-f0-9]{32}$' -or
        $root -ieq $runtime -or $root.StartsWith($runtime+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'AUTOSTART_ACCEPTANCE_EVIDENCE_SCOPE'}
    $ancestor=$root
    while($ancestor){$item=Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
        if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'AUTOSTART_ACCEPTANCE_EVIDENCE_SCOPE'}
        $ancestor=[IO.Path]::GetDirectoryName($ancestor)}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($payload|ConvertTo-Json -Depth 7 -Compress))
    if($bytes.Length -gt 4096){throw 'AUTOSTART_ACCEPTANCE_EVIDENCE_SIZE'}
    $name='autostart-preview-{0:D2}.private.json' -f $Ordinal;$path=Join-Path $root $name
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    [pscustomobject]@{RelativeEvidencePath=$name;Sha256=(Get-FileHash -LiteralPath $path).Hash;Bytes=(Get-Item -LiteralPath $path).Length}
}

function Invoke-AutoStartPreviewAcceptanceObservations {
    param($Module,$Scope,[string]$RunId,[string]$Provider,[string]$RepositoryRoot,[string]$EvidenceRoot)
    $before=Get-PortPreviewAcceptanceFileBinding -DataRoot $Scope.DataRoot
    $plans=[Collections.Generic.List[object]]::new();$records=[Collections.Generic.List[object]]::new();$calls=0
    foreach($desired in @('off','on','on','ON','OFF')){
        $calls++
        $plan=& $Module {param($Run,$State,$Desired) Get-SqlServerLabReconcilePlan -RunId $Run -InstanceId primary -StateRoot $State -ContainerAutoStartPreview -AutoStart $Desired} $RunId $Scope.StateRoot $desired
        $records.Add((Write-AutoStartPreviewAcceptanceObservation -Plan $plan -Provider $Provider -Ordinal $calls -Scope $Scope -RepositoryRoot $RepositoryRoot -EvidenceRoot $EvidenceRoot))
        # Persist real fixed status/reason before veto; never alter a blocked plan.
        if($plan.Status -cne 'PLAN_ONLY' -or $plan.Provider -cne $Provider -or $plan.Actual.Evidence -cne 'MEASURED' -or $plan.Actual.AutoStart -cne 'OFF' -or
            $plan.Actual.Lifecycle -cne 'RUNNING' -or $plan.Actual.SqlBinding -cne 'SINGLE_LOOPBACK_1433_TCP' -or $plan.ObservationKey -isnot [string]){throw 'AUTOSTART_ACCEPTANCE_MEASURED_OFF_REQUIRED'}
        $plans.Add($plan)
    }
    foreach($i in @(0,4)){if($plans[$i].NoChange -ne $true -or $plans[$i].ChangeClass -cne 'no-op' -or $plans[$i].Desired.AutoStartChange -cne 'SAME_POLICY' -or $plans[$i].Preview.Downtime -cne 'NONE'){throw 'AUTOSTART_ACCEPTANCE_NOOP'}}
    foreach($i in @(1,2,3)){if($plans[$i].NoChange -ne $false -or $plans[$i].ChangeClass -cne 'recreate' -or $plans[$i].Desired.AutoStartChange -cne 'DIFFERENT_POLICY' -or $plans[$i].Preview.Downtime -cne 'REQUIRED'){throw 'AUTOSTART_ACCEPTANCE_CHANGE'}}
    if($plans[1].ObservationKey -cne $plans[2].ObservationKey -or $plans[1].ObservationKey -cne $plans[3].ObservationKey -or $plans[0].ObservationKey -cne $plans[4].ObservationKey -or $plans[0].ObservationKey -ceq $plans[1].ObservationKey){throw 'AUTOSTART_ACCEPTANCE_CONTENT_KEY'}
    $after=Get-PortPreviewAcceptanceFileBinding -DataRoot $Scope.DataRoot
    if(($before|ConvertTo-Json -Depth 5 -Compress) -cne ($after|ConvertTo-Json -Depth 5 -Compress)){throw 'AUTOSTART_ACCEPTANCE_PREVIEW_STATE_WRITE'}
    # Matching repeat keys bind the entire returned actual inspect contents,
    # including raw restart policy; no additional native/context read is added.
    [pscustomobject]@{Core='NOOP_CHANGED_REPEAT_CASE_NORMALIZATION_PASSED';PublicPreviewCalls=$calls;PublicObservationEvidence=@($records);
        StateBytesEqual=$true;RepeatObservedContentEqual=$true;DesiredOnlyDifference=$true;AdditionalDiagnosticReads=0;
        DedicatedCli='NOT_EXECUTED';RenderedBrowser='NOT_EXECUTED';HttpNetworkTransport='NOT_EXECUTED';HostLogin='NOT_CHECKED';Endpoint='NOT_CHECKED';SqlPreview='NOT_CHECKED';Apply='NOT_IMPLEMENTED'}
}

function Invoke-AutoStartConsoleAcceptanceObservations {
    param($Module,$Scope,[string]$RunId,[string]$Provider,[string]$RepositoryRoot,[string]$EvidenceRoot)
    $before=Get-PortPreviewAcceptanceFileBinding -DataRoot $Scope.DataRoot
    $result=& $Module {
        param($Scope,$RunId,$Provider,$RepositoryRoot,$EvidenceRoot,$Writer)
        $binding=Get-LabDiagnosticBinding -RunId $RunId -InstanceId primary -DataRoot $Scope.DataRoot
        if($binding.StateRoot -cne $Scope.StateRoot -or $binding.Run.state -cne 'RUNNING' -or $binding.Provider -cne $Provider -or $binding.Run.metadata.persistentData -ne $false){throw 'AUTOSTART_CONSOLE_ACCEPTANCE_BINDING'}
        $names=@('Get-SqlServerLabReconcilePlan','Invoke-LabOwnedHostNativeProcess','Read-LabConsoleTextInput','Invoke-LabConsoleMenu',
            'Write-LabInfo','Write-LabWarning','Write-LabError','Wait-LabConsoleAcknowledgement','Show-LabSubMenu',
            'Get-LabSecret','Invoke-SqlQuery','Test-LabEndpointBinding','Repair-LabContainerReconcileJournal','New-LabContainerReconcileJournal',
            'Invoke-LabContainerReconcileCommand','Update-SqlServerLabContainer','Invoke-SqlServerLabWorkflowAction','Invoke-LabActionWithResult','Read-LabConfirm')
        $saved=@{};foreach($name in $names){$saved[$name]=(Get-Item ('Function:'+ $name) -ErrorAction SilentlyContinue).ScriptBlock}
        $script:autoStartConsoleAcceptancePublic=$saved['Get-SqlServerLabReconcilePlan']
        $script:autoStartConsoleAcceptanceNative=$saved['Invoke-LabOwnedHostNativeProcess']
        $script:autoStartConsoleAcceptanceScope=$Scope;$script:autoStartConsoleAcceptanceRun=$RunId
        $script:autoStartConsoleAcceptanceProvider=$Provider;$script:autoStartConsoleAcceptanceRepo=$RepositoryRoot
        $script:autoStartConsoleAcceptanceEvidence=$EvidenceRoot;$script:autoStartConsoleAcceptanceWriter=$Writer
        $script:autoStartConsoleAcceptanceCalls=0;$script:autoStartConsoleAcceptanceReads=0;$script:autoStartConsoleAcceptanceForbidden=0
        $script:autoStartConsoleAcceptancePlans=[Collections.Generic.List[object]]::new()
        $script:autoStartConsoleAcceptanceRecords=[Collections.Generic.List[object]]::new()
        $script:autoStartConsoleAcceptanceObserverError=$null
        $primary=$null;$restoreErrors=[Collections.Generic.List[object]]::new();$completedResult=$null
        try {
            foreach($name in @('Get-LabSecret','Invoke-SqlQuery','Test-LabEndpointBinding','Repair-LabContainerReconcileJournal','New-LabContainerReconcileJournal',
                    'Invoke-LabContainerReconcileCommand','Update-SqlServerLabContainer','Invoke-SqlServerLabWorkflowAction','Invoke-LabActionWithResult','Read-LabConfirm')){
                Set-Item ('Function:script:'+$name) {$script:autoStartConsoleAcceptanceForbidden++;throw 'AUTOSTART_CONSOLE_ACCEPTANCE_FORBIDDEN'}
            }
            function script:Get-SqlServerLabReconcilePlan {
                param($RunId,$InstanceId,$StateRoot,[switch]$ContainerAutoStartPreview,[string]$AutoStart)
                if($RunId -cne $script:autoStartConsoleAcceptanceRun -or $InstanceId -cne 'primary' -or $StateRoot -cne $script:autoStartConsoleAcceptanceScope.StateRoot -or -not $ContainerAutoStartPreview){throw 'AUTOSTART_CONSOLE_ACCEPTANCE_PUBLIC_SCOPE'}
                $script:autoStartConsoleAcceptanceCalls++
                try{
                    $plan=& $script:autoStartConsoleAcceptancePublic @PSBoundParameters
                    $record=& $script:autoStartConsoleAcceptanceWriter -Plan $plan -Provider $script:autoStartConsoleAcceptanceProvider -Ordinal $script:autoStartConsoleAcceptanceCalls -Scope $script:autoStartConsoleAcceptanceScope -RepositoryRoot $script:autoStartConsoleAcceptanceRepo -EvidenceRoot $script:autoStartConsoleAcceptanceEvidence
                    $script:autoStartConsoleAcceptanceRecords.Add($record)
                }catch{$script:autoStartConsoleAcceptanceObserverError=$_;throw}
                $script:autoStartConsoleAcceptancePlans.Add($plan)
                return $plan
            }
            function script:Invoke-LabOwnedHostNativeProcess {
                param($StartInfo,[int]$TimeoutSeconds,[int]$MaximumBytes)
                $script:autoStartConsoleAcceptanceReads++
                & $script:autoStartConsoleAcceptanceNative @PSBoundParameters
            }
            function script:Read-LabConsoleTextInput {
                param($Prompt)
                $script:autoStartConsoleAcceptanceInputs++
                if($script:autoStartConsoleAcceptanceCase -ceq 'cancel-root' -or ($script:autoStartConsoleAcceptanceCase -ceq 'cancel-policy' -and $script:autoStartConsoleAcceptanceInputs -eq 2)){return [pscustomobject]@{Status='Cancelled';Value=''}}
                $value=if($script:autoStartConsoleAcceptanceInputs -eq 1){$script:autoStartConsoleAcceptanceScope.DataRoot}elseif($script:autoStartConsoleAcceptanceCase -ceq 'invalid'){'neither'}else{$script:autoStartConsoleAcceptanceDesired}
                [pscustomobject]@{Status='Confirmed';Value=$value}
            }
            function script:Invoke-LabConsoleMenu {
                param($ScreenId,$Title,$Items)
                $id=if($ScreenId -ceq 'container-autostart-run'){$script:autoStartConsoleAcceptanceRun}elseif($ScreenId -ceq 'container-autostart-instance'){'primary'}else{throw 'AUTOSTART_CONSOLE_ACCEPTANCE_SCREEN'}
                $item=@($Items|Where-Object Id -CEQ $id)
                if($item.Count -ne 1){throw 'AUTOSTART_CONSOLE_ACCEPTANCE_TARGET'}
                if($script:autoStartConsoleAcceptanceCase -ceq 'forged-id'){$id='foreign'}
                [pscustomobject]@{Status='Selected';SelectedItem=[pscustomobject]@{Id=$id;Data=[pscustomobject]@{RunId='foreign';StateRoot='foreign';InstanceId='foreign'}}}
            }
            function script:Show-LabSubMenu {param($ScreenId,$Title,$Subtitle,$Items);$Items}
            function script:Write-LabInfo {param($Message)}
            function script:Write-LabWarning {param($Message)}
            function script:Write-LabError {param($Message)}
            function script:Wait-LabConsoleAcknowledgement {}
            $menu=@(Show-LabWorkspaceMenu|Where-Object Id -CEQ ContainerAutoStartPreview)
            if($menu.Count -ne 1){throw 'AUTOSTART_CONSOLE_ACCEPTANCE_MENU'}
            foreach($case in @('cancel-root','cancel-policy','invalid','forged-id')){
                $script:autoStartConsoleAcceptanceCase=$case;$script:autoStartConsoleAcceptanceInputs=0
                $calls=$script:autoStartConsoleAcceptanceCalls;$reads=$script:autoStartConsoleAcceptanceReads
                Invoke-LabMenuAction -ActionName $menu[0].Id
                if($script:autoStartConsoleAcceptanceCalls -ne $calls -or $script:autoStartConsoleAcceptanceReads -ne $reads){throw 'AUTOSTART_CONSOLE_ACCEPTANCE_EARLY_EFFECT'}
            }
            $script:autoStartConsoleAcceptanceCase='valid'
            foreach($request in @(@{Desired='on';Legacy=$false},@{Desired='off';Legacy=$false},@{Desired='on';Legacy=$true})){
                $script:autoStartConsoleAcceptanceDesired=$request.Desired;$script:autoStartConsoleAcceptanceInputs=0
                $calls=$script:autoStartConsoleAcceptanceCalls
                if($request.Legacy){Invoke-LabAction -ActionName $menu[0].Id}else{Invoke-LabMenuAction -ActionName $menu[0].Id}
                if($script:autoStartConsoleAcceptanceObserverError){throw $script:autoStartConsoleAcceptanceObserverError}
                if($script:autoStartConsoleAcceptanceCalls-$calls -ne 1){throw 'AUTOSTART_CONSOLE_ACCEPTANCE_CALL_COUNT'}
                $plan=$script:autoStartConsoleAcceptancePlans[$calls]
                Assert-LabContainerAutoStartConsolePlan -Plan $plan -Provider $Provider
                if($plan.Status -cne 'PLAN_ONLY' -or $plan.Actual.AutoStart -cne 'OFF'){throw 'AUTOSTART_CONSOLE_ACCEPTANCE_NATIVE_FORM'}
                $noOp=$request.Desired -ceq 'off'
                if($plan.NoChange -ne $noOp -or $plan.Desired.AutoStartChange -cne $(if($noOp){'SAME_POLICY'}else{'DIFFERENT_POLICY'})){throw 'AUTOSTART_CONSOLE_ACCEPTANCE_CATEGORY'}
            }
            $plans=$script:autoStartConsoleAcceptancePlans
            if($plans.Count -ne 3 -or $plans[0].ObservationKey -cne $plans[2].ObservationKey -or $plans[0].ObservationKey -ceq $plans[1].ObservationKey -or $script:autoStartConsoleAcceptanceForbidden){throw 'AUTOSTART_CONSOLE_ACCEPTANCE_CONTENT_OR_EFFECT'}
            $completedResult=[pscustomobject]@{DedicatedCli='ACTUAL_MENU_DUAL_ROUTER_PASSED';PublicPreviewCalls=3;EarlyCancelInvalidPublicCalls=0;EarlyCancelInvalidNativeReads=0;
                PublicObservationEvidence=@($script:autoStartConsoleAcceptanceRecords);PinnedNativeReads=$script:autoStartConsoleAcceptanceReads;
                RepeatObservedContentEqual=$true;DesiredOnlyDifference=$true;CoreFiveCallRepeat='NOT_EXECUTED';HostLogin='NOT_CHECKED';Endpoint='NOT_CHECKED';SqlPreview='NOT_CHECKED';Apply='NOT_IMPLEMENTED';RenderedBrowser='NOT_EXECUTED';HttpNetworkTransport='NOT_EXECUTED'}
        }catch{$primary=$_}
        finally{
            foreach($name in $names){try{if($saved[$name]){Set-Item ('Function:script:'+$name) $saved[$name] -ErrorAction Stop}else{Remove-Item ('Function:script:'+$name) -ErrorAction Stop}}catch{$restoreErrors.Add($_)}}
            foreach($name in @(Get-Variable -Scope Script -Name 'autoStartConsoleAcceptance*' -ErrorAction SilentlyContinue|ForEach-Object Name)){Remove-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue}
        }
        if($primary){if($restoreErrors.Count){$primary.Exception.Data['AutoStartConsoleRestorationFailure']=$true};throw $primary}
        if($restoreErrors.Count){throw 'AUTOSTART_CONSOLE_ACCEPTANCE_RESTORATION'}
        return $completedResult
    } $Scope $RunId $Provider $RepositoryRoot $EvidenceRoot ${function:Write-AutoStartPreviewAcceptanceObservation}
    $after=Get-PortPreviewAcceptanceFileBinding -DataRoot $Scope.DataRoot
    if(($before|ConvertTo-Json -Depth 5 -Compress) -cne ($after|ConvertTo-Json -Depth 5 -Compress)){throw 'AUTOSTART_CONSOLE_ACCEPTANCE_STATE_WRITE'}
    $result|Add-Member -NotePropertyName StateBytesEqual -NotePropertyValue $true
    return $result
}
