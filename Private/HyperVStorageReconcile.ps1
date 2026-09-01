<#
.SYNOPSIS
    Plant und repariert manifestgebundene Hyper-V-Zusatz-VHDX grow-only.
.DESCRIPTION
    Der oeffentliche Plan bleibt frei von VM-Identitaeten und Hostpfaden. Der
    Executor revalidiert Run, Scope, VM, VHDX und SCSI-Slots, journalisiert vor
    jeder Mutation, erstellt fehlende verwaltete VHDX, vergroessert vorhandene
    VHDX und verifiziert bzw. erweitert das NTFS-Volume im Windows-Gast.
    Shrink, Removal, Rollen-/Pfadwechsel und uneindeutige Attachments bleiben
    absichtlich unsupported.
#>

function Get-LabHyperVStorageReconcileJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)
    Join-Path $RunDirectory 'hyperv-storage-reconcile.local.journal.json'
}

function Assert-LabHyperVStorageReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal)
    $schemaPath = Join-Path $script:SchemasPath 'hyperv-storage-reconcile-journal.schema.json'
    if (-not (($Journal | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'HYPERV_STORAGE_RECONCILE_JOURNAL_SCHEMA_INVALID'
    }
    return $true
}

function Write-LabHyperVStorageReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal, [Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt = Get-LabTimestamp
    $null = Assert-LabHyperVStorageReconcileJournal -Journal $Journal
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
    return $Journal
}

function Set-LabHyperVStorageReconcileJournalStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('PREPARED','HOST_APPLIED','GUEST_VERIFIED','STATE_RESTORED','COMPLETED','RECOVERY_REQUIRED')][string]$Status,
        [string]$ErrorCode
    )
    $Journal.Status = $Status
    if ($ErrorCode) {
        $Journal.Recovery.ErrorCode = $ErrorCode
        $Journal.Recovery.Errors = @($Journal.Recovery.Errors) + @($ErrorCode)
    }
    if ($Status -eq 'COMPLETED') { $Journal.Recovery.Status = 'NOT_REQUIRED' }
    elseif ($Status -eq 'RECOVERY_REQUIRED') { $Journal.Recovery.Status = 'RETRY_STORAGE_RECONCILE' }
    return Write-LabHyperVStorageReconcileJournal -Journal $Journal -Path $Path
}

function Get-LabHyperVStorageReconcileTargetHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Drives)
    $portable = @($Drives | Sort-Object Id | ForEach-Object {
        [ordered]@{
            Id=[string]$_.Id;Role=[string]$_.Role;SizeBytes=[long]$_.SizeBytes;VhdType=[string]$_.VhdType
            GuestPath=[string]$_.GuestPath;AllocationUnitKB=[int]$_.AllocationUnitKB;FileSystem=[string]$_.FileSystem
            VolumeLabel=[string]$_.VolumeLabel;MaximumIops=[long]$_.MaximumIops;ControllerLocation=[int]$_.ControllerLocation
            Path=[IO.Path]::GetFullPath([string]$_.Path)
        }
    })
    $json = ConvertTo-LabStorageCanonicalValue -InputObject $portable | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Assert-LabHyperVStorageReconcileDesiredPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Drive, [Parameter(Mandatory)][string]$RunDirectory)
    if (-not $Drive.HostRoot) {
        if (-not (Test-HyperVPathWithinRunDirectory -Path ([string]$Drive.Path) -RunDirectory $RunDirectory)) {
            throw "HYPERV_STORAGE_RECONCILE_PATH_SCOPE_VIOLATION: $($Drive.Id)"
        }
        return $true
    }
    $hostRoot = [IO.Path]::GetFullPath([string]$Drive.HostRoot).TrimEnd('\','/')
    $path = [IO.Path]::GetFullPath([string]$Drive.Path)
    $boundary = Test-LabPathWithinRoot -Root $hostRoot -Path $path
    $configuration = Get-LabStorageConfiguration -DataRoot $hostRoot
    $locations = @($configuration.LabDataLocations | Where-Object {
        [string]::Equals([string]$_.LocationId, [string]$Drive.LocationId, [StringComparison]::OrdinalIgnoreCase) -and
        [string]$Drive.Selector -in @($_.Selectors)
    })
    if (-not $boundary.Valid -or $locations.Count -ne 1 -or
        -not (Test-LabDataRootOwnership -DataRoot $hostRoot -ControllerId ([string]$configuration.ControllerId))) {
        throw "HYPERV_STORAGE_RECONCILE_PATH_NOT_OWNED: $($Drive.Id)"
    }
    return $true
}

function Get-LabHyperVStorageReconcileDesiredDrives {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DesiredInstance,
        [Parameter(Mandatory)]$Managed,
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId
    )
    $providerPlan = @()
    if ($DesiredInstance.Storage) {
        # Der persistierte Desired-State verwendet absichtlich PascalCase am
        # Envelope. Fuer den Hash muss der portablen Schema-Schreibweise des
        # urspruenglichen StorageIntent (lower camel case) entsprochen werden.
        $intent = [PSCustomObject]@{
            contractVersion=[string]$DesiredInstance.Storage.ContractVersion
            placementPolicy=[string]$DesiredInstance.Storage.PlacementPolicy
            physicalIsolation=[string]$DesiredInstance.Storage.PhysicalIsolation
            roles=$DesiredInstance.Storage.Roles;tempDb=$DesiredInstance.Storage.TempDb
            databaseFiles=@($DesiredInstance.Storage.DatabaseFiles);restoreRules=@($DesiredInstance.Storage.RestoreRules)
        }
        $boundPath = Join-Path $RunDirectory 'storage-bound-plan.json'
        if (-not (Test-Path -LiteralPath $boundPath -PathType Leaf)) { throw 'HYPERV_STORAGE_RECONCILE_BOUND_PLAN_MISSING' }
        $bound = Get-Content -LiteralPath $boundPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
        $null = Assert-LabStorageBoundPlan -Plan $bound
        if ([string]$bound.RunId -ne $RunId -or [string]$bound.InstanceId -ne $InstanceId -or
            [string]$bound.Provider -ne 'hyperv' -or [string]$bound.Status -ne 'READY' -or
            [string]$bound.IntentSha256 -ne (Get-LabStorageIntentSha256 -StorageIntent $intent)) {
            throw 'HYPERV_STORAGE_RECONCILE_BOUND_PLAN_IDENTITY_MISMATCH'
        }
        $providerPlan = @(ConvertTo-LabHyperVStorageDrivePlan -Plan $bound)
    }
    else {
        $providerPlan = @($DesiredInstance.Drives | ForEach-Object {
            if ([string]$_.CapabilityStatus -eq 'DECLARED_UNSUPPORTED') { throw "HYPERV_STORAGE_RECONCILE_DRIVE_UNSUPPORTED: $($_.Id)" }
            [PSCustomObject]@{
                id=[string]$_.Id;role=[string]$_.Role;sizeBytes=[long]([double]$_.SizeGB * 1GB)
                vhdType=$(if ([string]$DesiredInstance.Profile -eq 'performance') {'fixed'} else {'dynamic'})
                guestPath=[string]$_.GuestPath;allocationUnitKB=64;fileSystem='NTFS'
                volumeLabel=('SQLLAB_' + ([string]$_.Id -replace '[^A-Za-z0-9_-]','_')).ToUpperInvariant()
                maximumIops=0;hostRoot=$null;hostPath=$null;locationId=$null;selector=$null
            }
        })
    }
    if ($providerPlan.Count -gt 16) { throw 'HYPERV_STORAGE_RECONCILE_DRIVE_LIMIT_EXCEEDED' }
    $vmName = [string]$Managed.VM.Name
    $resourceRoot = Split-Path -Parent ([string]$Managed.Identity.childVhdxPath)
    $result = @()
    $index = 0
    foreach ($drive in $providerPlan) {
        $id=[string]$drive.id;$role=[string]$drive.role;$size=[long]$drive.sizeBytes
        if($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$' -or $role -notin @('sqlData','sqlLog','tempdb','backup','general') -or
            $size -lt 32MB -or $size -gt 64TB -or [string]$drive.guestPath -notmatch '^[D-Zd-z]:\\') {
            throw "HYPERV_STORAGE_RECONCILE_DRIVE_INTENT_INVALID: $id"
        }
        $hostRoot=if($drive.hostRoot){[IO.Path]::GetFullPath([string]$drive.hostRoot).TrimEnd('\','/')}else{$null}
        $directory=if($drive.hostPath){[IO.Path]::GetFullPath([string]$drive.hostPath)}else{$resourceRoot}
        $path=Join-Path $directory "$vmName-$($id -replace '_','-').vhdx"
        $item=[PSCustomObject]@{
            Id=$id;Role=$role;SizeBytes=$size;VhdType=[string]$drive.vhdType;Path=[IO.Path]::GetFullPath($path)
            ControllerNumber=0;ControllerLocation=($index+1);GuestPath=[string]$drive.guestPath;FileSystem='NTFS'
            AllocationUnitKB=[int]$drive.allocationUnitKB;VolumeLabel=[string]$drive.volumeLabel;MaximumIops=[long]$drive.maximumIops
            HostRoot=$hostRoot;LocationId=if($drive.locationId){[string]$drive.locationId}else{$null};Selector=if($drive.selector){[string]$drive.selector}else{$null}
        }
        $null=Assert-LabHyperVStorageReconcileDesiredPath -Drive $item -RunDirectory $RunDirectory
        $result += $item;$index++
    }
    if(@($result.Id|Group-Object|Where-Object Count -gt 1).Count){throw 'HYPERV_STORAGE_RECONCILE_DRIVE_ID_DUPLICATE'}
    return @($result)
}

function Get-LabHyperVStorageReconcileContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$InstanceId,[string]$StateRoot)
    if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $run=Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if([string]$run.metadata.workflowKind -ne 'hyperv-lab'){throw 'HYPERV_STORAGE_RECONCILE_HYPERV_RUN_REQUIRED'}
    $guard=Get-LabHyperVResourceMigrationLifecycleGuard -RunId $RunId -StateRoot $StateRoot
    if(-not $guard.Allowed){throw "HYPERV_STORAGE_RECONCILE_MIGRATION_BLOCKED: $([string]$guard.ReasonCode)"}
    $targetState=if([string]$run.state -eq 'STOPPED'){'STOPPED'}else{'RUNNING'}
    $desired=New-LabDesiredState -Run $run -TargetState $targetState -StateRoot $StateRoot
    if(-not $desired.IsValid){throw 'HYPERV_STORAGE_RECONCILE_DESIRED_STATE_INVALID'}
    $desiredInstances=@($desired.Instances|Where-Object{[string]$_.Id -eq $InstanceId -and [string]$_.Provider -eq 'hyperv'})
    if($desiredInstances.Count -ne 1){throw 'HYPERV_STORAGE_RECONCILE_INSTANCE_NOT_UNIQUE'}
    $runDirectory=Join-Path (Join-Path $StateRoot 'runs') $RunId
    $connectionPath=Join-Path $runDirectory 'connection-info.json'
    if(-not(Test-Path -LiteralPath $connectionPath -PathType Leaf)){throw 'HYPERV_STORAGE_RECONCILE_CONNECTION_MISSING'}
    $connection=Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 40
    $instances=@($connection.instances|Where-Object{[string]$_.id -eq $InstanceId -and [string]$_.provider -eq 'hyperv'})
    if($instances.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$instances[0].vmName)){throw 'HYPERV_STORAGE_RECONCILE_CONNECTION_INSTANCE_NOT_UNIQUE'}
    $managed=Get-HyperVManagedVM -VMName ([string]$instances[0].vmName) -ExpectedRunId $RunId -ExpectedScopeId ([string]$run.scopeId)
    if(-not $managed){throw 'HYPERV_STORAGE_RECONCILE_VM_NOT_FOUND'}
    if($instances[0].vmId -and [string]$instances[0].vmId -ne [string]$managed.VM.Id){throw 'HYPERV_STORAGE_RECONCILE_VM_IDENTITY_MISMATCH'}
    if([string]$managed.VM.State -notin @('Running','Off')){throw 'HYPERV_STORAGE_RECONCILE_VM_STATE_UNSUPPORTED'}
    $drives=Get-LabHyperVStorageReconcileDesiredDrives -DesiredInstance $desiredInstances[0] -Managed $managed -RunDirectory $runDirectory -RunId $RunId -InstanceId $InstanceId
    $attachments=@(Get-VMHardDiskDrive -VM $managed.VM -ErrorAction Stop)
    [PSCustomObject]@{
        RunId=$RunId;ScopeId=[string]$run.scopeId;InstanceId=$InstanceId;StateRoot=$StateRoot;Run=$run;RunDirectory=$runDirectory
        Connection=$connection;ConnectionInstance=$instances[0];Managed=$managed;VM=$managed.VM;DesiredDrives=@($drives);Attachments=$attachments
        TargetHash=Get-LabHyperVStorageReconcileTargetHash -Drives $drives
        GuestCredentialAvailable=(Test-Path -LiteralPath (Join-Path (Join-Path $runDirectory 'secrets') 'guest-administrator-password.secret') -PathType Leaf)
    }
}

function Get-LabHyperVStorageReconcileDiff {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $diff=[Collections.Generic.List[object]]::new();$desiredIds=@($Context.DesiredDrives.Id)
    foreach($extra in @($Context.Managed.Identity.additionalDrives|Where-Object{[string]$_.id -notin $desiredIds})){
        $diff.Add([PSCustomObject]@{Id=[string]$extra.id;Kind='remove';Supported=$false;DesiredBytes=$null;ActualBytes=[long]$extra.sizeBytes})
    }
    foreach($desired in $Context.DesiredDrives){
        $identity=@($Context.Managed.Identity.additionalDrives|Where-Object{[string]$_.id -eq [string]$desired.Id})
        if($identity.Count -eq 0){
            $diff.Add([PSCustomObject]@{Id=[string]$desired.Id;Kind='add';Supported=(-not(Test-Path -LiteralPath $desired.Path));DesiredBytes=[long]$desired.SizeBytes;ActualBytes=$null})
            continue
        }
        if($identity.Count -ne 1){$diff.Add([PSCustomObject]@{Id=[string]$desired.Id;Kind='identity';Supported=$false;DesiredBytes=[long]$desired.SizeBytes;ActualBytes=$null});continue}
        $actual=$identity[0]
        $pathMatches=[string]::Equals([IO.Path]::GetFullPath([string]$actual.path),[IO.Path]::GetFullPath([string]$desired.Path),[StringComparison]::OrdinalIgnoreCase)
        $attachment=@($Context.Attachments|Where-Object{[string]::Equals([IO.Path]::GetFullPath([string]$_.Path),[IO.Path]::GetFullPath([string]$desired.Path),[StringComparison]::OrdinalIgnoreCase)})
        if(-not $pathMatches -or [string]$actual.role -ne [string]$desired.Role -or [string]$actual.vhdType -ne [string]$desired.VhdType -or
            [int]$actual.controllerNumber -ne 0 -or [int]$actual.controllerLocation -ne [int]$desired.ControllerLocation -or
            $attachment.Count -ne 1 -or [int]$attachment[0].ControllerNumber -ne 0 -or [int]$attachment[0].ControllerLocation -ne [int]$desired.ControllerLocation){
            $diff.Add([PSCustomObject]@{Id=[string]$desired.Id;Kind='contract';Supported=$false;DesiredBytes=[long]$desired.SizeBytes;ActualBytes=[long]$actual.sizeBytes});continue
        }
        if(-not(Test-Path -LiteralPath $desired.Path -PathType Leaf)){$diff.Add([PSCustomObject]@{Id=[string]$desired.Id;Kind='missing-file';Supported=$false;DesiredBytes=[long]$desired.SizeBytes;ActualBytes=$null});continue}
        try{$vhd=Get-VHD -Path $desired.Path -ErrorAction Stop}catch{$diff.Add([PSCustomObject]@{Id=[string]$desired.Id;Kind='vhd-unavailable';Supported=$false;DesiredBytes=[long]$desired.SizeBytes;ActualBytes=$null});continue}
        if([string]$vhd.DiskIdentifier -ne [string]$actual.diskIdentifier -or [string]$vhd.VhdType -ne [string]$desired.VhdType){
            $diff.Add([PSCustomObject]@{Id=[string]$desired.Id;Kind='vhd-identity';Supported=$false;DesiredBytes=[long]$desired.SizeBytes;ActualBytes=[long]$vhd.Size});continue
        }
        if([long]$vhd.Size -gt [long]$desired.SizeBytes){$diff.Add([PSCustomObject]@{Id=[string]$desired.Id;Kind='shrink';Supported=$false;DesiredBytes=[long]$desired.SizeBytes;ActualBytes=[long]$vhd.Size});continue}
        if([long]$vhd.Size -lt [long]$desired.SizeBytes){$diff.Add([PSCustomObject]@{Id=[string]$desired.Id;Kind='grow';Supported=$true;DesiredBytes=[long]$desired.SizeBytes;ActualBytes=[long]$vhd.Size});continue}
        $receipt=@($Context.Managed.Identity.guestDriveInitialization|Where-Object{[string]$_.id -eq [string]$desired.Id})
        $guestSuffix=([string]$desired.GuestPath).Substring(1)
        $guestReady=$receipt.Count -eq 1 -and [string]$receipt[0].diskIdentifier -eq [string]$actual.diskIdentifier -and
            [string]$receipt[0].fileSystem -eq 'NTFS' -and [string]$receipt[0].status -in @('INITIALIZED','VERIFIED','EXTENDED') -and
            [string]$receipt[0].guestPath -match '^[D-Z]:\\' -and ([string]$receipt[0].guestPath).Substring(1) -eq $guestSuffix -and
            $receipt[0].PSObject.Properties['diskSizeBytes'] -and [long]$receipt[0].diskSizeBytes -eq [long]$desired.SizeBytes -and
            $receipt[0].PSObject.Properties['partitionSizeBytes'] -and [long]$receipt[0].partitionSizeBytes -gt 0
        if(-not $guestReady){$diff.Add([PSCustomObject]@{Id=[string]$desired.Id;Kind='guest-verify';Supported=$true;DesiredBytes=[long]$desired.SizeBytes;ActualBytes=[long]$vhd.Size})}
    }
    return @($diff)
}

function Read-LabHyperVStorageReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Context)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    $journal=Get-Content -LiteralPath $Path -Raw -Encoding utf8|ConvertFrom-Json -Depth 30
    $null=Assert-LabHyperVStorageReconcileJournal -Journal $journal
    if([string]$journal.RunId -ne [string]$Context.RunId -or [string]$journal.ScopeId -ne [string]$Context.ScopeId -or
        [string]$journal.InstanceId -ne [string]$Context.InstanceId -or [string]$journal.Runtime.VMId -ne [string]$Context.VM.Id){
        throw 'HYPERV_STORAGE_RECONCILE_JOURNAL_IDENTITY_MISMATCH'
    }
    if([string]$journal.TargetHash -ne [string]$Context.TargetHash){if([string]$journal.Status -eq 'COMPLETED'){return $null};throw 'HYPERV_STORAGE_RECONCILE_JOURNAL_TARGET_MISMATCH'}
    return $journal
}

function New-LabHyperVStorageReconcilePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$InstanceId,[string]$StateRoot)
    try{$context=Get-LabHyperVStorageReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $journalPath=Get-LabHyperVStorageReconcileJournalPath -RunDirectory $context.RunDirectory
        $journal=Read-LabHyperVStorageReconcileJournal -Path $journalPath -Context $context
    }catch{
        $code=if($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}'){[string]$Matches[0]}else{'HYPERV_STORAGE_RECONCILE_UNAVAILABLE'}
        return [PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.HyperVStorageReconcilePlan';Version='1.0'};RunId=$RunId;InstanceId=$InstanceId;Provider='hyperv';Desired=@();Actual=[PSCustomObject]@{Status='UNAVAILABLE';RuntimeState='UNAVAILABLE'};Diff=@();Actions=@();HighestChangeClass='unsupported';IsNoOp=$false;MutationAllowed=$false;Warnings=@('Der Hyper-V-Storagezustand ist nicht eindeutig steuerbar.');ReasonCodes=@($code)}
    }
    $privateDiff=@(Get-LabHyperVStorageReconcileDiff -Context $context)
    $pending=$journal -and [string]$journal.Status -ne 'COMPLETED'
    if($pending){foreach($item in $privateDiff|Where-Object Kind -eq 'add'){if(Test-Path -LiteralPath (@($context.DesiredDrives|Where-Object Id -eq $item.Id)[0].Path)){ $item.Supported=$true }}}
    $unsupported=@($privateDiff|Where-Object{-not $_.Supported})
    $changeClass=if($unsupported.Count){'unsupported'}elseif($privateDiff.Count -eq 0 -and -not $pending){'no-op'}elseif(-not $context.GuestCredentialAvailable){'unsupported'}elseif($pending){[string]$journal.ChangeClass}elseif([string]$context.VM.State -eq 'Running'){'live'}elseif([string]$context.VM.State -eq 'Off'){'restart'}else{'unsupported'}
    $repairKinds=@($privateDiff.Kind|Sort-Object -Unique)
    $actions=if($changeClass -in @('live','restart')){@([PSCustomObject]@{Operation=if($pending){'ResumeHyperVStorage'}else{'RepairHyperVStorage'};ChangeClass=$changeClass;RepairKinds=$repairKinds;DriveIds=@($privateDiff.Id|Sort-Object -Unique);RequiresGuestVerification=$true;RequiresTemporaryStart=($changeClass -eq 'restart');RecoveryPending=[bool]$pending})}else{@()}
    $publicDiff=@($privateDiff|ForEach-Object{[PSCustomObject]@{DriveId=if([string]$_.Kind -eq 'remove'){'extra-managed-drive'}else{[string]$_.Id};Kind=[string]$_.Kind;DesiredSizeGB=if($null-ne$_.DesiredBytes){[decimal]([long]$_.DesiredBytes/1GB)}else{$null};ActualSizeGB=if($null-ne$_.ActualBytes){[decimal]([long]$_.ActualBytes/1GB)}else{$null};ChangeClass=if($_.Supported){$changeClass}else{'unsupported'}}})
    [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.HyperVStorageReconcilePlan';Version='1.0'};RunId=$RunId;InstanceId=$InstanceId;Provider='hyperv'
        Desired=@($context.DesiredDrives|ForEach-Object{[PSCustomObject]@{DriveId=[string]$_.Id;Role=[string]$_.Role;SizeGB=[decimal]([long]$_.SizeBytes/1GB);VhdType=[string]$_.VhdType;GuestBinding='managed-ntfs'}})
        Actual=[PSCustomObject]@{Status='AVAILABLE';RuntimeState=[string]$context.VM.State;ManagedDriveCount=@($context.Managed.Identity.additionalDrives).Count}
        Diff=$publicDiff;Actions=$actions;HighestChangeClass=$changeClass;IsNoOp=($changeClass -eq 'no-op');MutationAllowed=$false
        Warnings=if($unsupported.Count){@('Shrink, Removal, Rollen-/Pfadwechsel und uneindeutige Attachments werden nicht automatisch mutiert.')}elseif(-not $context.GuestCredentialAvailable -and $privateDiff.Count){@('Das geschuetzte Gastcredential fehlt; keine Hostmutation wird begonnen.')}elseif($changeClass -eq 'restart'){@('Die ausgeschaltete VM wird nur fuer Gastverifikation temporaer gestartet und danach wieder ausgeschaltet.')}else{@()}
        ReasonCodes=@($(if($pending){'HYPERV_STORAGE_RECONCILE_RECOVERY_PENDING'});$(if(-not $context.GuestCredentialAvailable -and $privateDiff.Count){'HYPERV_STORAGE_RECONCILE_GUEST_CREDENTIAL_REQUIRED'});@($unsupported|ForEach-Object{"HYPERV_STORAGE_RECONCILE_$([string]$_.Kind -replace '-','_')_UNSUPPORTED".ToUpperInvariant()}))
    }
}

function Add-LabHyperVStorageReconcileCleanupStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Drive)
    $cleanupPath=Join-Path $Context.RunDirectory 'cleanup-plan.json'
    $cleanup=Get-Content -LiteralPath $cleanupPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 30
    if(@($cleanup.steps|Where-Object{[string]$_.resourceType -eq 'vhdx' -and [string]::Equals([IO.Path]::GetFullPath([string]$_.resourceId),[IO.Path]::GetFullPath([string]$Drive.Path),[StringComparison]::OrdinalIgnoreCase)}).Count -eq 0){
        $null=Add-CleanupStep -RunDir $Context.RunDirectory -ResourceType vhdx -ResourceId ([string]$Drive.Path) -Action remove -Provider hyperv -ProviderSubRunId provider-hyperv -SafetyRoot ([string]$Drive.HostRoot) -Compensation "Remove reconciled Hyper-V $($Drive.Role) VHDX $($Drive.Id)"
    }
}

function Set-LabHyperVStorageReconcileHostState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $identityDrives=[Collections.Generic.List[object]]::new()
    foreach($desired in $Context.DesiredDrives){
        $existing=@($Context.Managed.Identity.additionalDrives|Where-Object{[string]$_.id -eq [string]$desired.Id})|Select-Object -First 1
        if(-not(Test-Path -LiteralPath $desired.Path -PathType Leaf)){
            Add-LabHyperVStorageReconcileCleanupStep -Context $Context -Drive $desired
            $directory=Split-Path -Parent ([string]$desired.Path);if(-not(Test-Path -LiteralPath $directory -PathType Container)){$null=New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop}
            $arguments=@{Path=[string]$desired.Path;SizeBytes=[long]$desired.SizeBytes;ErrorAction='Stop'};$arguments[[string]$desired.VhdType]=$true
            $null=New-VHD @arguments
        }
        $vhd=Get-VHD -Path $desired.Path -ErrorAction Stop
        if([long]$vhd.Size -gt [long]$desired.SizeBytes){throw "HYPERV_STORAGE_RECONCILE_SHRINK_UNSUPPORTED: $($desired.Id)"}
        if([long]$vhd.Size -lt [long]$desired.SizeBytes){$null=Resize-VHD -Path $desired.Path -SizeBytes ([long]$desired.SizeBytes) -ErrorAction Stop;$vhd=Get-VHD -Path $desired.Path -ErrorAction Stop}
        if([long]$vhd.Size -ne [long]$desired.SizeBytes -or [string]$vhd.VhdType -ne [string]$desired.VhdType -or [string]$vhd.DiskIdentifier -notmatch '^[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$'){
            throw "HYPERV_STORAGE_RECONCILE_VHD_POSTCONDITION_FAILED: $($desired.Id)"
        }
        $attachments=@(Get-VMHardDiskDrive -VM $Context.VM -ErrorAction Stop)
        $pathAttachments=@($attachments|Where-Object{[string]::Equals([IO.Path]::GetFullPath([string]$_.Path),[IO.Path]::GetFullPath([string]$desired.Path),[StringComparison]::OrdinalIgnoreCase)})
        if($pathAttachments.Count -eq 0){
            if(@($attachments|Where-Object{[int]$_.ControllerNumber -eq 0 -and [int]$_.ControllerLocation -eq [int]$desired.ControllerLocation}).Count){throw "HYPERV_STORAGE_RECONCILE_SCSI_SLOT_OCCUPIED: $($desired.Id)"}
            $attached=Add-VMHardDiskDrive -VM $Context.VM -ControllerType SCSI -ControllerNumber 0 -ControllerLocation ([int]$desired.ControllerLocation) -Path ([string]$desired.Path) -ErrorAction Stop
            if([long]$desired.MaximumIops -gt 0){$null=Set-VMHardDiskDrive -VMHardDiskDrive $attached -MaximumIOPS ([long]$desired.MaximumIops) -ErrorAction Stop}
        }elseif($pathAttachments.Count -ne 1 -or [int]$pathAttachments[0].ControllerNumber -ne 0 -or [int]$pathAttachments[0].ControllerLocation -ne [int]$desired.ControllerLocation){throw "HYPERV_STORAGE_RECONCILE_ATTACHMENT_POSTCONDITION_FAILED: $($desired.Id)"}
        $identityDrives.Add([PSCustomObject]@{
            id=[string]$desired.Id;role=[string]$desired.Role;sizeBytes=[long]$desired.SizeBytes;vhdType=[string]$desired.VhdType;path=[IO.Path]::GetFullPath([string]$desired.Path)
            diskIdentifier=([string]$vhd.DiskIdentifier).ToUpperInvariant();controllerNumber=0;controllerLocation=[int]$desired.ControllerLocation
            guestPath=if($existing -and $existing.guestPath){[string]$existing.guestPath}else{[string]$desired.GuestPath};driveLetter=if($existing){[string]$existing.driveLetter}else{([string]$desired.GuestPath).Substring(0,1).ToUpperInvariant()}
            fileSystem='NTFS';allocationUnitKB=[int]$desired.AllocationUnitKB;volumeLabel=[string]$desired.VolumeLabel;maximumIops=[long]$desired.MaximumIops
            hostRoot=if($desired.HostRoot){[string]$desired.HostRoot}else{$null};locationId=if($desired.LocationId){[string]$desired.LocationId}else{$null};selector=if($desired.Selector){[string]$desired.Selector}else{$null}
        })
    }
    $null=Set-HyperVManagedVMIdentityProperty -ManagedVM $Context.Managed -PropertyName additionalDrives -Value @($identityDrives) -ContractVersion '0.5'
    $null=Set-HyperVManagedVMIdentityProperty -ManagedVM $Context.Managed -PropertyName additionalVhdxPaths -Value @($identityDrives.path) -ContractVersion '0.5'
}

function Set-LabHyperVStorageReconcileConnectionReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Managed)
    $receipts=@($Managed.Identity.guestDriveInitialization)
    $Context.ConnectionInstance|Add-Member -NotePropertyName additionalDrives -NotePropertyValue @($Managed.Identity.additionalDrives|ForEach-Object{
        $drive=$_;$receipt=@($receipts|Where-Object{[string]$_.id -eq [string]$drive.id})|Select-Object -First 1
        [PSCustomObject]@{id=[string]$drive.id;role=[string]$drive.role;sizeBytes=[long]$drive.sizeBytes;vhdType=[string]$drive.vhdType;diskIdentifier=[string]$drive.diskIdentifier;guestPath=[string]$receipt.guestPath;driveLetter=[string]$receipt.driveLetter;fileSystem=[string]$receipt.fileSystem;allocationUnitKB=[int]$drive.allocationUnitKB;volumeLabel=[string]$drive.volumeLabel;maximumIops=[long]$drive.maximumIops;locationId=if($drive.locationId){[string]$drive.locationId}else{$null};selector=if($drive.selector){[string]$drive.selector}else{$null};state='GUEST_VERIFIED'}
    }) -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $Context.RunDirectory 'connection-info.json') -InputObject $Context.Connection
}

function Invoke-LabHyperVStorageReconcileRepair {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$InstanceId,[string]$StateRoot)
    $mutex=[Threading.Mutex]::new($false,"Global\SQL_Server_Lab_HyperV_Storage_Reconcile_$($RunId.Replace('-',''))")
    $acquired=$false;$journal=$null;$journalPath=$null
    try{
        $acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(5));if(-not$acquired){throw 'HYPERV_STORAGE_RECONCILE_LOCK_TIMEOUT'}
        $context=Get-LabHyperVStorageReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $journalPath=Get-LabHyperVStorageReconcileJournalPath -RunDirectory $context.RunDirectory
        $journal=Read-LabHyperVStorageReconcileJournal -Path $journalPath -Context $context
        $plan=New-LabHyperVStorageReconcilePlan -RunId $RunId -InstanceId $InstanceId -StateRoot $context.StateRoot
        if($journal -and [string]$journal.Status -ne 'COMPLETED'){$journal.Recovery.Attempts=[int]$journal.Recovery.Attempts+1}
        elseif($journal -and [string]$journal.Status -eq 'COMPLETED' -and $plan.IsNoOp){return [PSCustomObject]@{Status='NO_OP';RunId=$RunId;InstanceId=$InstanceId;Changed=$false;RepairKinds=@()}}
        elseif($journal -and [string]$journal.Status -eq 'COMPLETED'){$journal=$null}
        if(-not$journal){
            if($plan.IsNoOp){return [PSCustomObject]@{Status='NO_OP';RunId=$RunId;InstanceId=$InstanceId;Changed=$false;RepairKinds=@()}}
            if([string]$plan.HighestChangeClass -notin @('live','restart') -or @($plan.Actions).Count -ne 1){throw 'HYPERV_STORAGE_RECONCILE_UNSUPPORTED'}
            $journal=[PSCustomObject]@{ContractVersion='SqlServerLab.HyperVStorageReconcileJournal/1.0';OperationId=[Guid]::NewGuid().ToString('D');RunId=$RunId;ScopeId=[string]$context.ScopeId;InstanceId=$InstanceId;Provider='hyperv';ChangeClass=[string]$plan.HighestChangeClass;Status='PREPARED';TargetHash=[string]$context.TargetHash;Runtime=[PSCustomObject]@{VMId=[string]$context.VM.Id;OriginalState=[string]$context.VM.State};Recovery=[PSCustomObject]@{Status='RETRY_STORAGE_RECONCILE';Attempts=0;ErrorCode=$null;Errors=@()};UpdatedAt=Get-LabTimestamp}
            $null=Write-LabHyperVStorageReconcileJournal -Journal $journal -Path $journalPath
        }
        $guestPassword=Get-LabSecret -Path $context.RunDirectory -Name 'guest-administrator-password'
        if(-not$guestPassword){throw 'HYPERV_STORAGE_RECONCILE_GUEST_CREDENTIAL_REQUIRED'}
        $credential=[PSCredential]::new('Administrator',$guestPassword)
        Set-LabHyperVStorageReconcileHostState -Context $context
        $null=Set-LabHyperVStorageReconcileJournalStatus -Journal $journal -Path $journalPath -Status HOST_APPLIED
        $context=Get-LabHyperVStorageReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $context.StateRoot
        if([string]$context.VM.State -eq 'Off'){$null=Start-VM -VM $context.VM -ErrorAction Stop;$null=Wait-LabHyperVResourceReconcileVMState -VMName ([string]$context.ConnectionInstance.vmName) -RunId $RunId -ScopeId ([string]$context.ScopeId) -ExpectedState Running}
        $receipt=Initialize-HyperVWindowsGuestDrives -VMName ([string]$context.ConnectionInstance.vmName) -ExpectedRunId $RunId -ExpectedScopeId ([string]$context.ScopeId) -Credential $credential
        if([string]$receipt.Status -ne 'GUEST_DRIVES_READY'){throw 'HYPERV_STORAGE_RECONCILE_GUEST_POSTCONDITION_FAILED'}
        $null=Set-LabHyperVStorageReconcileJournalStatus -Journal $journal -Path $journalPath -Status GUEST_VERIFIED
        $managed=Get-HyperVManagedVM -VMName ([string]$context.ConnectionInstance.vmName) -ExpectedRunId $RunId -ExpectedScopeId ([string]$context.ScopeId)
        Set-LabHyperVStorageReconcileConnectionReceipt -Context $context -Managed $managed
        if([string]$journal.Runtime.OriginalState -eq 'Off' -and [string]$managed.VM.State -eq 'Running'){$null=Stop-VM -VM $managed.VM -Confirm:$false -ErrorAction Stop;$null=Wait-LabHyperVResourceReconcileVMState -VMName ([string]$context.ConnectionInstance.vmName) -RunId $RunId -ScopeId ([string]$context.ScopeId) -ExpectedState Off}
        $null=Set-LabHyperVStorageReconcileJournalStatus -Journal $journal -Path $journalPath -Status STATE_RESTORED
        $final=Get-LabHyperVStorageReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $context.StateRoot
        $remaining=@(Get-LabHyperVStorageReconcileDiff -Context $final)
        if($remaining.Count){throw "HYPERV_STORAGE_RECONCILE_POSTCONDITION_FAILED: $(@($remaining.Kind)-join ',')"}
        if([string]$final.VM.State -ne [string]$journal.Runtime.OriginalState){throw 'HYPERV_STORAGE_RECONCILE_STATE_POSTCONDITION_FAILED'}
        $null=Set-LabHyperVStorageReconcileJournalStatus -Journal $journal -Path $journalPath -Status COMPLETED
        [PSCustomObject]@{Status='SUCCEEDED';RunId=$RunId;InstanceId=$InstanceId;Changed=$true;RepairKinds=if(@($plan.Actions).Count){@($plan.Actions[0].RepairKinds)}else{@()};JournalStatus='COMPLETED'}
    }catch{
        $code=if($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}'){[string]$Matches[0]}else{'HYPERV_STORAGE_RECONCILE_FAILED'}
        if($journal -and $journalPath){try{$null=Set-LabHyperVStorageReconcileJournalStatus -Journal $journal -Path $journalPath -Status RECOVERY_REQUIRED -ErrorCode $code}catch{};throw "HYPERV_STORAGE_RECONCILE_RECOVERY_REQUIRED: $code"}
        throw
    }finally{if($acquired){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
}
