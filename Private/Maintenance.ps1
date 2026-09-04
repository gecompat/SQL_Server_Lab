<#
.SYNOPSIS
    Erstellt und fuehrt den provideruebergreifenden Maintenance-Vertrag aus.
.DESCRIPTION
    Inventarisiert den schnellen Runtime-/State-Scope ohne rekursive Storage-
    Analyse. Mutationen werden ausschliesslich aus stabilen Run-/Scope-
    Bindungen oder einem eng begrenzten Legacy-Testartefaktvertrag abgeleitet.
#>

function Get-LabMaintenanceHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)

    $bytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Value))
    return [Convert]::ToHexString($bytes).ToLowerInvariant()
}

function Get-LabMaintenanceContainerInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)

    $resolution = Resolve-LabHostTool -Name $Provider
    if (-not $resolution.Available) {
        return [PSCustomObject]@{ Provider=$Provider; Status='NOT_INSTALLED'; Resources=@() }
    }
    $runtime = [string]$resolution.Invocation
    $infoArguments=@('info')
    & $runtime @infoArguments 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{ Provider=$Provider; Status='UNAVAILABLE'; Resources=@() }
    }

    $listArguments=@('ps','-a','-q')
    $ids = @(& $runtime @listArguments 2>$null | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{ Provider=$Provider; Status='UNAVAILABLE'; Resources=@() }
    }
    $resources = foreach ($id in $ids) {
        $inspectArguments=@('inspect',[string]$id)
        $inspect = @(& $runtime @inspectArguments 2>$null | ConvertFrom-Json -Depth 50)[0]
        if ($LASTEXITCODE -ne 0 -or -not $inspect) { continue }
        $labels = $inspect.Config.Labels
        $name = ([string]$inspect.Name).TrimStart('/')
        $runId = [string]$labels.'sql-server-lab.run-id'
        $scopeId = [string]$labels.'sql-server-lab.scope-id'
        $lifecycle = [string]$labels.'sql-server-lab.lifecycle'
        $expiresAt = [string]$labels.'sql-server-lab.expires-at'
        $vendor = [string]$labels.'org.opencontainers.image.vendor'
        $image = [string]$inspect.Config.Image
        $bindMounts = @($inspect.Mounts | Where-Object { [string]$_.Type -eq 'bind' })
        $classification = if ($runId -and $scopeId) {
            'LAB_BOUND'
        }
        elseif ($vendor -eq 'SQL_Server_Lab' -and $name -like 'sql-lab-*' -and $image -like 'sql-server-lab/*') {
            'LEGACY_TEST_CANDIDATE'
        }
        else {
            'FOREIGN'
        }
        $material = @($Provider,[string]$inspect.Id,$name,[string]$inspect.State.Status,$runId,$scopeId,$lifecycle,$expiresAt,$vendor,$image,$bindMounts.Count) -join '|'
        [PSCustomObject]@{
            Provider=$Provider; ResourceId=[string]$inspect.Id; Name=$name; State=[string]$inspect.State.Status
            Running=[bool]$inspect.State.Running; RunId=$runId; ScopeId=$scopeId; Lifecycle=$lifecycle
            ExpiresAt=$expiresAt; Vendor=$vendor; Image=$image; BindMountCount=$bindMounts.Count
            Classification=$classification; Fingerprint=(Get-LabMaintenanceHash -Value $material)
        }
    }
    return [PSCustomObject]@{ Provider=$Provider; Status='AVAILABLE'; Resources=@($resources) }
}

function Test-LabMaintenancePathWithinRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Root)

    try {
        $candidate = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
        $boundary = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
        return $candidate.Equals($boundary,[StringComparison]::OrdinalIgnoreCase) -or
            $candidate.StartsWith($boundary + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Get-LabMaintenanceTempArtifactRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)

    if($Item.Attributes -band [IO.FileAttributes]::ReparsePoint){return $null}
    try {
        $descendants=if($Item.PSIsContainer){@(Get-ChildItem -LiteralPath $Item.FullName -Force -Recurse -ErrorAction Stop)}else{@()}
        if(@($descendants|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count -gt 0){return $null}
        $files=if($Item.PSIsContainer){@($descendants|Where-Object {-not $_.PSIsContainer})}else{@($Item)}
        $latest=@($Item)+@($descendants)|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
        $bytes=[long](($files|Measure-Object Length -Sum).Sum)
        $kind=if($Item.PSIsContainer){'Directory'}else{'File'}
        $material=@($Item.FullName,$kind,$latest.LastWriteTimeUtc.ToString('o'),$files.Count,$bytes) -join '|'
        [PSCustomObject]@{
            ResourceId=(Get-LabMaintenanceHash -Value $Item.FullName);Name=$Item.Name;FullPath=$Item.FullName
            Kind=$kind;LastWriteTimeUtc=$latest.LastWriteTimeUtc.ToString('o');FileCount=$files.Count;Bytes=$bytes
            Fingerprint=(Get-LabMaintenanceHash -Value $material)
        }
    }
    catch { return $null }
}

function Get-LabMaintenanceTempInventory {
    [CmdletBinding()]
    param([ValidateRange(5,10080)][int]$StaleAfterMinutes=60)

    $root=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    $cutoff=[DateTime]::UtcNow.AddMinutes(-$StaleAfterMinutes)
    $pattern='^(?i)(sql-lab-|sqlserverlab-smoke-|sqlserverlabcatalogteststate$)'
    $resources=@(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue|Where-Object {$_.Name -match $pattern}|ForEach-Object {
        $record=Get-LabMaintenanceTempArtifactRecord -Item $_
        if($record -and [datetime]::Parse($record.LastWriteTimeUtc).ToUniversalTime() -le $cutoff){$record}
    })
    [PSCustomObject]@{Status='AVAILABLE';Root=$root;CutoffUtc=$cutoff.ToString('o');Resources=$resources}
}

function Get-LabMaintenanceHyperVInventory {
    [CmdletBinding()]
    param()

    if (-not $IsWindows -or -not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{ Provider='hyperv'; Status='NOT_INSTALLED'; Resources=@() }
    }
    try {
        $configuration = Get-LabStorageConfiguration
        $runRoots = @($configuration.LabDataLocations | ForEach-Object {
            if ($_.LabDataRoot) { Join-Path ([string]$_.LabDataRoot) 'HyperV\Runs' }
        } | Where-Object { $_ })
        $allVms = @(Get-VM -ErrorAction Stop)
        $resources = foreach ($vm in $allVms) {
            $identity = ConvertFrom-HyperVLabNotes -Notes ([string]$vm.Notes)
            $vmPath = [string]$vm.Path
            $insideLabRunRoot = @($runRoots | Where-Object { $vmPath -and (Test-LabMaintenancePathWithinRoot -Path $vmPath -Root $_) }).Count -gt 0
            $classification = if ($identity -and [string]$identity.provider -eq 'hyperv' -and $identity.runId -and $identity.scopeId) {
                'LAB_BOUND'
            }
            elseif (-not $identity -and [string]$vm.State -eq 'Off' -and $insideLabRunRoot -and [string]$vm.Name -like 'sql-lab-*') {
                'LEGACY_TEST_CANDIDATE'
            }
            else { 'FOREIGN' }
            $vhdxPaths = @(Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Path } | Where-Object { $_ })
            $resourceRoot = if ($vmPath) { Split-Path -Parent ([IO.Path]::GetFullPath($vmPath).TrimEnd('\','/')) } else { $null }
            $material = @('hyperv',[string]$vm.Id,[string]$vm.Name,[string]$vm.State,[string]$vm.Notes,$vmPath,$resourceRoot,($vhdxPaths -join ';')) -join '|'
            [PSCustomObject]@{
                Provider='hyperv'; ResourceId=[string]$vm.Id; Name=[string]$vm.Name; State=[string]$vm.State
                Running=([string]$vm.State -eq 'Running'); RunId=if($identity){[string]$identity.runId}else{''}
                ScopeId=if($identity){[string]$identity.scopeId}else{''}; Lifecycle=if($identity){[string]$identity.lifecycle}else{''}
                ExpiresAt=if($identity){[string]$identity.expiresAt}else{''}; Path=$vmPath; ResourceRoot=$resourceRoot
                VhdxPaths=$vhdxPaths; NotesPresent=([string]$vm.Notes -ne ''); InsideLabRunRoot=$insideLabRunRoot
                Classification=$classification; Fingerprint=(Get-LabMaintenanceHash -Value $material)
            }
        }
        return [PSCustomObject]@{ Provider='hyperv'; Status='AVAILABLE'; Resources=@($resources) }
    }
    catch {
        return [PSCustomObject]@{ Provider='hyperv'; Status='UNAVAILABLE'; Resources=@(); Message=$_.Exception.Message }
    }
}

function New-LabMaintenanceAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ActionType,
        [Parameter(Mandatory)][ValidateSet('SAFE_AUTOMATIC','SCOPED_CLEANUP','EXPLICIT_LEGACY_APPROVAL','REVIEW_ONLY')][string]$Disposition,
        [Parameter(Mandatory)][string]$Provider,
        [string]$RunId,[string]$ScopeId,[string]$ResourceId,[string]$Name,
        [string]$CurrentState,[string]$TargetState,[Parameter(Mandatory)][string]$ReasonCode,
        [Parameter(Mandatory)][string]$Fingerprint,[hashtable]$Evidence=@{}
    )
    $key = @($ActionType,$Provider,$RunId,$ScopeId,$ResourceId,$Name,$Fingerprint) -join '|'
    [PSCustomObject]@{
        ActionId="maintenance-action-$((Get-LabMaintenanceHash -Value $key).Substring(0,24))"
        ActionType=$ActionType; Disposition=$Disposition; Provider=$Provider; RunId=$RunId; ScopeId=$ScopeId
        ResourceId=$ResourceId; Name=$Name; CurrentState=$CurrentState; TargetState=$TargetState
        ReasonCode=$ReasonCode; Fingerprint=$Fingerprint; Evidence=[PSCustomObject]$Evidence
    }
}

function Get-LabMaintenancePlanCore {
    [CmdletBinding()]
    param(
        [ValidateSet('Runtime','Full')][string]$Mode='Runtime',
        [ValidateRange(5,10080)][int]$StaleAfterMinutes=60,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot=Get-LabStateRoot }
    $runs=@(Get-LabActiveRuns -StateRoot $StateRoot)
    $knownRunIds=@($runs | ForEach-Object { [string]$_.runId })
    $docker=Get-LabMaintenanceContainerInventory -Provider docker
    $podman=Get-LabMaintenanceContainerInventory -Provider podman
    $hyperv=Get-LabMaintenanceHyperVInventory
    $temp=Get-LabMaintenanceTempInventory -StaleAfterMinutes $StaleAfterMinutes
    $runtimeResources=@($docker.Resources)+@($podman.Resources)+@($hyperv.Resources)
    $actions=[Collections.Generic.List[object]]::new()

    foreach($run in $runs) {
        $runtime=Get-LabRunRuntimeStatus -Run $run -StateRoot $StateRoot
        $stored=[string]$run.state; $actual=[string]$runtime.State
        $runFingerprint=Get-LabMaintenanceHash -Value (@([string]$run.runId,[string]$run.scopeId,$stored,$actual,[string]$run.updatedAt) -join '|')
        if($actual -in @('RUNNING','STOPPED') -and $stored -in @('RUNNING','STOPPED') -and $actual -ne $stored) {
            $actions.Add((New-LabMaintenanceAction -ActionType SYNC_RUNTIME_STATE -Disposition SAFE_AUTOMATIC -Provider core `
                -RunId ([string]$run.runId) -ScopeId ([string]$run.scopeId) -CurrentState $stored -TargetState $actual `
                -ReasonCode RUNTIME_STATE_DRIFT -Fingerprint $runFingerprint))
        }
        elseif($actual -eq 'MISSING' -and $stored -notin @('REMOVED','CLEANED_UP','RECOVERY_REQUIRED')) {
            $actions.Add((New-LabMaintenanceAction -ActionType MARK_RECOVERY_REQUIRED -Disposition SAFE_AUTOMATIC -Provider core `
                -RunId ([string]$run.runId) -ScopeId ([string]$run.scopeId) -CurrentState $stored -TargetState RECOVERY_REQUIRED `
                -ReasonCode BOUND_RUNTIME_MISSING -Fingerprint $runFingerprint))
            $actions.Add((New-LabMaintenanceAction -ActionType RETRY_RUN_CLEANUP -Disposition SCOPED_CLEANUP -Provider core `
                -RunId ([string]$run.runId) -ScopeId ([string]$run.scopeId) -CurrentState $stored -TargetState REMOVED `
                -ReasonCode MISSING_RUNTIME_CLEANUP_AVAILABLE -Fingerprint $runFingerprint))
        }

        $updatedAt=[datetime]::MinValue
        $parsed=[datetime]::TryParse([string]$run.updatedAt,[ref]$updatedAt)
        $ageMinutes=if($parsed){((Get-Date).ToUniversalTime()-$updatedAt.ToUniversalTime()).TotalMinutes}else{0}
        $ownedResources=@($runtimeResources | Where-Object { $_.RunId -and [string]$_.RunId -eq [string]$run.runId })
        if($stored -in @('INITIALIZING','PROVISIONING','PROVISION_FAILED') -and $ageMinutes -ge $StaleAfterMinutes -and $ownedResources.Count -eq 0) {
            $actions.Add((New-LabMaintenanceAction -ActionType RETRY_RUN_CLEANUP -Disposition SCOPED_CLEANUP -Provider core `
                -RunId ([string]$run.runId) -ScopeId ([string]$run.scopeId) -CurrentState $stored -TargetState REMOVED `
                -ReasonCode STALE_INCOMPLETE_RUN -Fingerprint $runFingerprint -Evidence @{AgeMinutes=[int]$ageMinutes}))
        }
    }

    foreach($resource in $runtimeResources) {
        if($resource.Classification -eq 'LAB_BOUND' -and $resource.RunId -notin $knownRunIds) {
            $expired=$false; $expiry=[datetime]::MinValue
            if($resource.Lifecycle -eq 'test' -and [datetime]::TryParse([string]$resource.ExpiresAt,[ref]$expiry)) {
                $expired=$expiry.ToUniversalTime() -le (Get-Date).ToUniversalTime()
            }
            $disposition=if($expired){'SAFE_AUTOMATIC'}else{'SCOPED_CLEANUP'}
            $type=if($resource.Provider -eq 'hyperv'){'REMOVE_ORPHAN_HYPERV'}else{'REMOVE_ORPHAN_CONTAINER'}
            $actions.Add((New-LabMaintenanceAction -ActionType $type -Disposition $disposition -Provider $resource.Provider `
                -RunId $resource.RunId -ScopeId $resource.ScopeId -ResourceId $resource.ResourceId -Name $resource.Name `
                -CurrentState $resource.State -TargetState REMOVED -ReasonCode ORPHAN_RUNTIME_RESOURCE `
                -Fingerprint $resource.Fingerprint -Evidence @{Lifecycle=$resource.Lifecycle;ExpiresAt=$resource.ExpiresAt;ResourceRoot=$resource.ResourceRoot}))
        }
        elseif($resource.Classification -eq 'LEGACY_TEST_CANDIDATE') {
            $type=if($resource.Provider -eq 'hyperv'){'REMOVE_LEGACY_TEST_HYPERV'}else{'REMOVE_LEGACY_TEST_CONTAINER'}
            $actions.Add((New-LabMaintenanceAction -ActionType $type -Disposition EXPLICIT_LEGACY_APPROVAL -Provider $resource.Provider `
                -ResourceId $resource.ResourceId -Name $resource.Name -CurrentState $resource.State -TargetState REMOVED `
                -ReasonCode LEGACY_TEST_ARTIFACT_WITHOUT_COMPLETE_IDENTITY -Fingerprint $resource.Fingerprint `
                -Evidence @{ResourceRoot=$resource.ResourceRoot;BindMountCount=$resource.BindMountCount;InsideLabRunRoot=$resource.InsideLabRunRoot}))
        }
    }

    if(@($temp.Resources).Count -gt 0){
        $itemFingerprints=@($temp.Resources|Sort-Object FullPath|ForEach-Object {[string]$_.Fingerprint})
        $aggregateFingerprint=Get-LabMaintenanceHash -Value (@($temp.Root,$temp.CutoffUtc)+$itemFingerprints -join '|')
        $actions.Add((New-LabMaintenanceAction -ActionType REMOVE_STALE_TEST_TEMP_ARTIFACTS -Disposition SCOPED_CLEANUP -Provider core `
            -ResourceId (Get-LabMaintenanceHash -Value ([string]$temp.Root)) -Name "$(@($temp.Resources).Count) stale SQL_Server_Lab temp artifacts" `
            -CurrentState PRESENT -TargetState REMOVED -ReasonCode STALE_TEST_TEMP_ARTIFACTS -Fingerprint $aggregateFingerprint `
            -Evidence @{TempRoot=$temp.Root;CutoffUtc=$temp.CutoffUtc;Items=@($temp.Resources)}))
    }

    $providerStates=@($docker,$podman,$hyperv | ForEach-Object {[PSCustomObject]@{Provider=$_.Provider;Status=$_.Status}})
    $unverifiable=@($providerStates | Where-Object Status -eq 'UNAVAILABLE')
    $ordered=@($actions | Sort-Object Disposition,Provider,ActionType,RunId,Name)
    $status=if($unverifiable.Count -gt 0){'UNVERIFIABLE'}elseif($ordered.Count -eq 0){'CLEAN'}elseif(@($ordered|Where-Object Disposition -eq 'REVIEW_ONLY').Count -gt 0){'REVIEW_REQUIRED'}else{'CHANGES_AVAILABLE'}
    $fullAudit=$null
    if($Mode -eq 'Full') { $fullAudit=(Get-SqlServerLabCleanupAudit -NoWrite -StateRoot $StateRoot).Audit }
    [PSCustomObject]@{
        ContractVersion='SqlServerLab.MaintenancePlan/1.0'; PlanId=[guid]::NewGuid().ToString('D'); CreatedAt=Get-LabTimestamp
        Mode=$Mode; Status=$status; StaleAfterMinutes=$StaleAfterMinutes; Providers=$providerStates; Actions=$ordered
        Summary=[PSCustomObject]@{
            Actions=$ordered.Count; SafeAutomatic=@($ordered|Where-Object Disposition -eq 'SAFE_AUTOMATIC').Count
            ScopedCleanup=@($ordered|Where-Object Disposition -eq 'SCOPED_CLEANUP').Count
            LegacyApproval=@($ordered|Where-Object Disposition -eq 'EXPLICIT_LEGACY_APPROVAL').Count
            ReviewOnly=@($ordered|Where-Object Disposition -eq 'REVIEW_ONLY').Count
            ForeignResources=@($runtimeResources|Where-Object Classification -eq 'FOREIGN').Count
        }
        FullAudit=$fullAudit
    }
}

function Remove-LabStaleTestTempArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Action)

    $expectedRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetFullPath([string]$Action.Evidence.TempRoot).TrimEnd('\','/') -ne $expectedRoot){throw 'TEMP_ROOT_REVALIDATION_FAILED'}
    $removed=0;$absent=0
    foreach($planned in @($Action.Evidence.Items)){
        if([string]$planned.Name -notmatch '^(?i)(sql-lab-|sqlserverlab-smoke-|sqlserverlabcatalogteststate$)'){throw 'TEMP_ARTIFACT_NAME_REVALIDATION_FAILED'}
        $expectedPath=[IO.Path]::GetFullPath((Join-Path $expectedRoot ([string]$planned.Name)))
        if($expectedPath -ne [IO.Path]::GetFullPath([string]$planned.FullPath)){throw 'TEMP_ARTIFACT_PATH_REVALIDATION_FAILED'}
        if(-not(Test-Path -LiteralPath $expectedPath)){$absent++;continue}
        $item=Get-Item -LiteralPath $expectedPath -Force -ErrorAction Stop
        $current=Get-LabMaintenanceTempArtifactRecord -Item $item
        if(-not $current -or [string]$current.Fingerprint -ne [string]$planned.Fingerprint){throw "TEMP_ARTIFACT_FINGERPRINT_CHANGED: $($planned.Name)"}
        if([datetime]::Parse($current.LastWriteTimeUtc).ToUniversalTime() -gt [datetime]::Parse([string]$Action.Evidence.CutoffUtc).ToUniversalTime()){throw "TEMP_ARTIFACT_NO_LONGER_STALE: $($planned.Name)"}
        Remove-Item -LiteralPath $expectedPath -Recurse -Force -ErrorAction Stop
        if(Test-Path -LiteralPath $expectedPath){throw "TEMP_ARTIFACT_REMOVE_FAILED: $($planned.Name)"}
        $removed++
    }
    [PSCustomObject]@{Status=if($removed -gt 0){'REMOVED'}else{'ALREADY_ABSENT'};Removed=$removed;AlreadyAbsent=$absent}
}

function Remove-LabLegacyTestContainer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,[Parameter(Mandatory)]$Action)

    $inventory=Get-LabMaintenanceContainerInventory -Provider $Provider
    $current=@($inventory.Resources|Where-Object { [string]$_.ResourceId -eq [string]$Action.ResourceId }|Select-Object -First 1)[0]
    if(-not $current){return [PSCustomObject]@{Status='ALREADY_ABSENT';Name=$Action.Name}}
    if($current.Classification -ne 'LEGACY_TEST_CANDIDATE' -or $current.Running -or $current.BindMountCount -ne 0 -or $current.Fingerprint -ne $Action.Fingerprint) {
        throw 'LEGACY_TEST_CONTAINER_REVALIDATION_FAILED'
    }
    $runtime=Get-LabHostToolInvocation -Name $Provider
    $removeArguments=@('rm','-f',[string]$current.ResourceId)
    & $runtime @removeArguments | Out-Null
    if($LASTEXITCODE -ne 0){throw 'LEGACY_TEST_CONTAINER_REMOVE_FAILED'}
    [PSCustomObject]@{Status='REMOVED';Name=$current.Name}
}

function Remove-LabLegacyTestHyperV {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Action)

    $inventory=Get-LabMaintenanceHyperVInventory
    $current=@($inventory.Resources|Where-Object { [string]$_.ResourceId -eq [string]$Action.ResourceId }|Select-Object -First 1)[0]
    if(-not $current){return [PSCustomObject]@{Status='ALREADY_ABSENT';Name=$Action.Name}}
    if($current.Classification -ne 'LEGACY_TEST_CANDIDATE' -or $current.State -ne 'Off' -or -not $current.InsideLabRunRoot -or
        $current.Fingerprint -ne $Action.Fingerprint -or -not $current.ResourceRoot) {
        throw 'LEGACY_TEST_HYPERV_REVALIDATION_FAILED'
    }
    $root=[IO.Path]::GetFullPath([string]$current.ResourceRoot).TrimEnd('\','/')
    $otherVms=@(Get-VM -ErrorAction Stop|Where-Object {[string]$_.Id -ne [string]$current.ResourceId -and $_.Path -and (Test-LabMaintenancePathWithinRoot -Path ([string]$_.Path) -Root $root)})
    if($otherVms.Count -gt 0){throw 'LEGACY_TEST_HYPERV_RESOURCE_ROOT_SHARED'}
    if(Test-Path -LiteralPath $root){
        $reparse=@(Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint})
        if($reparse.Count -gt 0){throw 'LEGACY_TEST_HYPERV_REPARSE_POINT_BLOCKED'}
    }
    $vm=Get-VM -Id ([guid]$current.ResourceId) -ErrorAction Stop
    Remove-VM -VM $vm -Force -ErrorAction Stop
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop}
    [PSCustomObject]@{Status='REMOVED';Name=$current.Name}
}
