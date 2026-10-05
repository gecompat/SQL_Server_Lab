# Test-only public-core acceptance. No provider commands or product overrides.
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
