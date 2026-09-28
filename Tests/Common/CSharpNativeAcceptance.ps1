# Internal acceptance contracts; no runtime action when dot-sourced.
function Assert-CSharpNativeCheckout {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    if($Context.EventName -cne 'workflow_dispatch' -or $Context.Ref -cne 'refs/heads/main'){
        throw 'CSHARP_NATIVE_MANUAL_MAIN_REQUIRED'
    }
    if($Context.Repository -cne 'gecompat/SQL_Server_Lab' -or $Context.EventRepository -cne $Context.Repository){
        throw 'CSHARP_NATIVE_REPOSITORY_MISMATCH'
    }
    if($Context.ExpectedCommit -cnotmatch '^[a-f0-9]{40}$' -or $Context.CheckoutCommit -cne $Context.ExpectedCommit -or $Context.Dirty){
        throw 'CSHARP_NATIVE_CHECKOUT_MISMATCH'
    }
}

function Assert-CSharpNativeDispatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    Assert-CSharpNativeCheckout $Context
    if($Context.ArtifactId -cnotmatch '^hyperv-os-sealed-[a-f0-9]{64}$'){
        throw 'CSHARP_NATIVE_OS_ARTIFACT_REQUIRED'
    }
}

function Assert-CSharpNativeFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedHash,
        [ValidateSet('SHA256','SHA512')][string]$Algorithm='SHA256',[long]$MaximumBytes=134217728)
    if($ExpectedHash -cnotmatch $(if($Algorithm -eq 'SHA512'){'^[a-f0-9]{128}$'}else{'^[a-f0-9]{64}$'})){
        throw 'CSHARP_NATIVE_HASH_INVALID'
    }
    $full=[IO.Path]::GetFullPath($Path)
    if($IsWindows -and ((New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($full))).DriveType -ne [IO.DriveType]::Fixed)){
        throw 'CSHARP_NATIVE_LOCAL_FILE_REQUIRED'
    }
    $ancestor=$full
    while($ancestor){
        if((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
            throw 'CSHARP_NATIVE_REPARSE_POINT'
        }
        $ancestor=[IO.Path]::GetDirectoryName($ancestor)
    }
    $file=Get-Item -LiteralPath $full -ErrorAction Stop
    if($file.PSIsContainer -or $file.Length -le 0 -or $file.Length -gt $MaximumBytes){throw 'CSHARP_NATIVE_FILE_SIZE'}
    if((Get-FileHash -LiteralPath $full -Algorithm $Algorithm).Hash.ToLowerInvariant() -cne $ExpectedHash){throw 'CSHARP_NATIVE_FILE_HASH'}
}

function Get-CSharpNativeFailureCode {
    param($ErrorRecord)
    $message=[string]$ErrorRecord.Exception.Message
    if($message.Length -le 128 -and $message -cmatch '^CSHARP_NATIVE_[A-Z_]+$'){return $message}
    return 'CSHARP_NATIVE_UNCLASSIFIED_FAILURE'
}
function Get-CSharpNativeOwnedRun {
    param([Parameter(Mandatory)]$Module, [Parameter(Mandatory)][string]$OperationId, [Parameter(Mandatory)][string]$StateRoot)
    & $Module {
        param($ExpectedOperationId, $Root)
        $owned = Get-LabOperationOwnedRun -OperationId $ExpectedOperationId -StateRoot $Root
        if (-not $owned) { return $null }
        if ([string]$owned.runId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
            [string]$owned.scopeId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
            [string]$owned.metadata.workflowOperationId -cne $ExpectedOperationId -or
            (-not [string]::IsNullOrWhiteSpace([string]$owned.metadata.workflowKind) -and [string]$owned.metadata.workflowKind -cne 'hyperv-lab')) {
            throw 'CSHARP_NATIVE_OWNED_RUN_STATE_INVALID'
        }
        $providerSubRuns = @(Get-LabProviderSubRuns -RunId ([string]$owned.runId) -StateRoot $Root)
        if ($providerSubRuns.Count -ne 1 -or [string]$providerSubRuns[0].provider -cne 'hyperv') {
            throw 'CSHARP_NATIVE_OWNED_RUN_PROVIDER_INVALID'
        }
        $runDirectory = Join-Path (Join-Path $Root 'runs') ([string]$owned.runId)
        $plan = Get-CleanupPlan -RunDir $runDirectory
        $vmSteps = @($plan.steps | Where-Object { [string]$_.resourceType -eq 'vm' })
        if ([string]$plan.runId -cne [string]$owned.runId -or [string]$plan.scopeId -cne [string]$owned.scopeId -or
            @($plan.steps | Where-Object { [string]$_.provider -ne 'hyperv' -or [string]$_.resourceType -notin @('vm', 'vhdx', 'ipam-lease') }).Count -gt 0 -or
            $vmSteps.Count -gt 1 -or ($vmSteps.Count -eq 1 -and [string]::IsNullOrWhiteSpace([string]$vmSteps[0].resourceId))) {
            throw 'CSHARP_NATIVE_OWNED_RUN_CLEANUP_PLAN_INVALID'
        }
        $plannedVmName = if($vmSteps.Count -eq 1){[string]$vmSteps[0].resourceId}else{''}
        $vmId=$null
        $connectionPath = Join-Path $runDirectory 'connection-info.json'
        if (Test-Path -LiteralPath $connectionPath -PathType Leaf) {
            $context = Get-HyperVLabWorkflowRun -RunId ([string]$owned.runId) -StateRoot $Root
            if ([string]$context.Run.scopeId -cne [string]$owned.scopeId -or
                [string]$context.Instance.provider -cne 'hyperv' -or
                [string]::IsNullOrWhiteSpace([string]$context.Instance.vmName) -or
                [string]::IsNullOrWhiteSpace([string]$context.Instance.vmId)) {
                throw 'CSHARP_NATIVE_OWNED_RUN_CONNECTION_INVALID'
            }
            $contextVmId = [guid]::Empty
            if ([string]$context.Instance.vmName -cne $plannedVmName -or -not [guid]::TryParse([string]$context.Instance.vmId, [ref]$contextVmId)) {
                throw 'CSHARP_NATIVE_OWNED_VM_OWNERSHIP_INVALID'
            }
            $managed = Get-HyperVManagedVM -VMName $plannedVmName -ExpectedRunId ([string]$owned.runId) -ExpectedScopeId ([string]$owned.scopeId)
            if (-not $managed -or [string]$managed.VM.Id -cne $contextVmId.ToString()) {
                throw 'CSHARP_NATIVE_OWNED_VM_OWNERSHIP_INVALID'
            }
            $vmId = $contextVmId.ToString()
        }
        elseif($plannedVmName) {
            $existingVm = @(Get-VM -Name $plannedVmName -ErrorAction SilentlyContinue)
            if ($existingVm.Count -ne 0) {
                $managed = Get-HyperVManagedVM -VMName $plannedVmName -ExpectedRunId ([string]$owned.runId) -ExpectedScopeId ([string]$owned.scopeId)
                if (-not $managed) { throw 'CSHARP_NATIVE_OWNED_VM_OWNERSHIP_INVALID' }
                $vmId = [string]$managed.VM.Id
            }
        }
        return [PSCustomObject]@{
            RunId=[string]$owned.runId; ScopeId=[string]$owned.scopeId; VMName=$plannedVmName; VMId=$vmId
            VhdxPaths=@($plan.steps | Where-Object { [string]$_.resourceType -eq 'vhdx' } | ForEach-Object { [string]$_.resourceId } | Where-Object { $_ })
            IpamLeases=@($plan.steps | Where-Object { [string]$_.resourceType -eq 'ipam-lease' } | ForEach-Object { [string]$_.resourceId } | Where-Object { $_ })
        }
    } $OperationId $StateRoot
}
function Test-CSharpNativeCleanupPostconditions {
    param([Parameter(Mandatory)]$Module, [Parameter(Mandatory)]$Owned, [Parameter(Mandatory)][string]$StateRoot)
    & $Module {
        param($CleanupOwned, $Root)
        $remainingVm = @(if($CleanupOwned.VMName){Get-VM -Name ([string]$CleanupOwned.VMName) -ErrorAction SilentlyContinue})
        if ($remainingVm.Count -ne 0) { throw 'CSHARP_NATIVE_CLEANUP_VM_POSTCONDITION_FAILED' }
        foreach ($path in @($CleanupOwned.VhdxPaths | Sort-Object -Unique)) {
            if (Test-Path -LiteralPath $path) { throw 'CSHARP_NATIVE_CLEANUP_VHDX_POSTCONDITION_FAILED' }
        }
        $ipamPath = Join-Path (Join-Path $Root 'network') 'hyperv-ipam.json'
        if (Test-Path -LiteralPath $ipamPath -PathType Leaf) {
            $registry = Get-Content -LiteralPath $ipamPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
            foreach ($address in @($CleanupOwned.IpamLeases | Sort-Object -Unique)) {
                $matches = @($registry.leases | Where-Object {
                    [string]$_.address -ceq $address -and [string]$_.runId -ceq [string]$CleanupOwned.RunId -and
                    [string]$_.scopeId -ceq [string]$CleanupOwned.ScopeId -and [string]$_.state -ceq 'ACTIVE'
                })
                if ($matches.Count -ne 0) { throw 'CSHARP_NATIVE_CLEANUP_IPAM_POSTCONDITION_FAILED' }
            }
        }
        return $true
    } $Owned $StateRoot
}
function Invoke-CSharpNativeCleanup {
    param([Parameter(Mandatory)]$Module, [Parameter(Mandatory)][string]$OperationId, [Parameter(Mandatory)][string]$StateRoot)
    $owned = Get-CSharpNativeOwnedRun -Module $Module -OperationId $OperationId -StateRoot $StateRoot
    if (-not $owned) { return $null }
    $result = & $Module { param($RunId, $Root) Remove-SqlServerLab -RunId $RunId -StateRoot $Root -Force -Confirm:$false } $owned.RunId $StateRoot
    if ([string]$result.RunId -cne [string]$owned.RunId -or [string]$result.Status -notin @('REMOVED','COMPLETED','ALREADY_REMOVED') -or [string]$result.Cleanup -notin @('CLEANUP_SUCCEEDED','ALREADY_REMOVED')) {
        throw 'CSHARP_NATIVE_OWNED_RUN_CLEANUP_FAILED'
    }
    $null = Test-CSharpNativeCleanupPostconditions -Module $Module -Owned $owned -StateRoot $StateRoot
    return $result
}

function Invoke-CSharpNativeChild {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Worker,[Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$OutputRoot,[ValidateRange(1,7200)][int]$TimeoutSeconds=7200)
    $process=$null;$started=$false;$terminated=$true;$stdout=$null;$stderr=$null
    try{
        $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Command pwsh -ErrorAction Stop).Source
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($argument in @('-NoLogo','-NoProfile','-File',$Worker,'-PlanPath',$PlanPath)){$start.ArgumentList.Add($argument)}
        $process=[Diagnostics.Process]::new();$process.StartInfo=$start
        if(-not $process.Start()){throw 'CSHARP_NATIVE_CHILD_START_FAILED'}
        $started=$true;$terminated=$false
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($TimeoutSeconds*1000)){
            $process.Kill($true);$terminated=$process.WaitForExit(15000)
            if(-not $terminated){throw 'CSHARP_NATIVE_CHILD_TERMINATION_UNCONFIRMED'}
            throw 'CSHARP_NATIVE_CHILD_TIMEOUT'
        }
        $terminated=$true
        if(-not $stdout.Wait(10000) -or -not $stderr.Wait(10000)){throw 'CSHARP_NATIVE_CHILD_OUTPUT_TIMEOUT'}
        [IO.File]::WriteAllText((Join-Path $OutputRoot 'worker.stdout.log'),$stdout.GetAwaiter().GetResult())
        [IO.File]::WriteAllText((Join-Path $OutputRoot 'worker.stderr.log'),$stderr.GetAwaiter().GetResult())
        return [pscustomobject]@{ExitCode=$process.ExitCode;Terminated=$true}
    }catch{
        if($started -and -not $terminated){try{$process.Kill($true);$terminated=$process.WaitForExit(15000)}catch{$terminated=$false}}
        $_.Exception.Data['CSharpChildTerminated']=$terminated
        throw
    }finally{
        if($terminated -and $stdout -and $stdout.IsCompletedSuccessfully){[IO.File]::WriteAllText((Join-Path $OutputRoot 'worker.stdout.log'),$stdout.GetAwaiter().GetResult())}
        if($terminated -and $stderr -and $stderr.IsCompletedSuccessfully){[IO.File]::WriteAllText((Join-Path $OutputRoot 'worker.stderr.log'),$stderr.GetAwaiter().GetResult())}
        if($process){$process.Dispose()}
    }
}

function Enable-CSharpNativeGuestCopy {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$VM)
    $services=@(Get-VMIntegrationService -VM $VM -ErrorAction Stop | Where-Object {([string]$_.Id).EndsWith('6C09BB55-D683-4DA0-8931-C9BF705F6480',[StringComparison]::OrdinalIgnoreCase)})
    if($services.Count -ne 1){throw 'CSHARP_NATIVE_GUEST_COPY_SERVICE_MISSING'}
    if(-not $services[0].Enabled){$null=Enable-VMIntegrationService -VMIntegrationService $services[0] -ErrorAction Stop}
}

function Assert-CSharpNativeLocalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    if($IsWindows -and ((New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($full))).DriveType -ne [IO.DriveType]::Fixed)){throw 'CSHARP_NATIVE_LOCAL_FILE_REQUIRED'}
    $ancestor=$full
    while($ancestor){
        if((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'CSHARP_NATIVE_REPARSE_POINT'}
        $ancestor=[IO.Path]::GetDirectoryName($ancestor)
    }
}

function New-CSharpNativeFailureException {
    param([string]$PrimaryFailure,[string]$CleanupFailure)
    $exception=[InvalidOperationException]::new($(if($CleanupFailure){'CSHARP_NATIVE_RECOVERY_REQUIRED'}else{'CSHARP_NATIVE_ACCEPTANCE_FAILED'}))
    $exception.Data['PrimaryFailure']=$PrimaryFailure
    $exception.Data['CleanupFailure']=$CleanupFailure
    return $exception
}

function Get-CSharpNativeFailureDiagnostic {
    param([Parameter(Mandatory)]$ErrorRecord)
    $primary=Get-CSharpNativeFailureCode $ErrorRecord
    $cleanup=$null
    foreach($key in @('PrimaryFailure','CleanupFailure')){
        $value=[string]$ErrorRecord.Exception.Data[$key]
        if($value){
            if($value.Length -gt 128 -or $value -cnotmatch '^CSHARP_NATIVE_[A-Z_]+$'){$value='CSHARP_NATIVE_UNCLASSIFIED_FAILURE'}
            if($key -eq 'PrimaryFailure'){$primary=$value}else{$cleanup=$value}
        }
    }
    [pscustomobject]@{PrimaryFailure=$primary;CleanupFailure=$cleanup;RecoveryRequired=[bool]$cleanup;
        ReasonCode=$(if($cleanup){'CSHARP_NATIVE_RECOVERY_REQUIRED'}else{$primary})}
}

function Get-CSharpNativeSqlStatus {
    param([Parameter(Mandatory)][string]$AttemptPath,[Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$Commit,[bool]$Passed)
    if(-not(Test-Path -LiteralPath $AttemptPath)){return 'NOT_EXECUTED'}
    if((Get-Item -LiteralPath $AttemptPath).Length -gt 4096){throw 'CSHARP_NATIVE_ATTEMPT_INVALID'}
    $attempt=Get-Content -LiteralPath $AttemptPath -Raw|ConvertFrom-Json
    if($attempt.Status -cne 'SQL_PROBE_STARTED' -or $attempt.OperationId -cne $OperationId -or $attempt.Commit -cne $Commit){throw 'CSHARP_NATIVE_ATTEMPT_INVALID'}
    if($Passed){return 'PASSED'}
    return 'FAILED'
}

function Assert-CSharpNativeProfileAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Descriptor,[switch]$Ancestor)
    # Conservative allow-list; unknown writers are rejected even if another ACE denies them.
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    if(-not $Descriptor.DaclPresent -or $Descriptor.Owner -cnotin $trusted){throw 'CSHARP_NATIVE_PROFILE_ACL'}
    $mask=[long]([Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership -bor [Security.AccessControl.FileSystemRights]::WriteAttributes -bor [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes)
    # GetAccessRules preserves generic access bits; GenericWrite/All also mutate ancestors.
    $mask=$mask -bor 0x40000000L -bor 0x10000000L
    if(-not $Ancestor){$mask=$mask -bor [long][Security.AccessControl.FileSystemRights]::WriteData -bor [long][Security.AccessControl.FileSystemRights]::AppendData}
    foreach($rule in $Descriptor.Rules){
        if($rule.Allow -and -not $rule.InheritOnly -and $rule.Sid -cnotin $trusted -and ([long]$rule.Rights -band $mask)){
            throw 'CSHARP_NATIVE_PROFILE_ACL'
        }
    }
}

function Assert-CSharpNativeProfilePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if(-not $IsWindows){throw 'CSHARP_NATIVE_WINDOWS_REQUIRED'}
    if($Path -cnotmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':')){throw 'CSHARP_NATIVE_PROFILE_PATH'}
    Assert-CSharpNativeLocalPath $Path
    $full=[IO.Path]::GetFullPath($Path)
    if($full -ine $Path){throw 'CSHARP_NATIVE_PROFILE_PATH'}
    $profileRoot=[IO.Path]::GetDirectoryName($full)
    $cursor=$full
    while($cursor){
        $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if($cursor -ine $full -and -not $item.PSIsContainer){throw 'CSHARP_NATIVE_PROFILE_PATH'}
        $acl=Get-Acl -LiteralPath $cursor -ErrorAction Stop
        $raw=[Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(),0)
        $descriptor=[pscustomobject]@{
            Owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
            DaclPresent=($null -ne $raw.DiscretionaryAcl)
            Rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|ForEach-Object {
                [pscustomobject]@{Sid=$_.IdentityReference.Value;Rights=[long]$_.FileSystemRights;Allow=($_.AccessControlType -eq 'Allow');InheritOnly=[bool]($_.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)}
            })
        }
        Assert-CSharpNativeProfileAcl -Descriptor $descriptor -Ancestor:($cursor -ine $full -and $cursor -ine $profileRoot)
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
}

function ConvertFrom-CSharpNativeProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Json)
    $document=$null
    try{
        if([Text.Encoding]::UTF8.GetByteCount($Json) -gt 16384){throw 'CSHARP_NATIVE_PROFILE_SIZE'}
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=3
        $document=[Text.Json.JsonDocument]::Parse($Json,$options)
        if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'CSHARP_NATIVE_PROFILE_SCHEMA'}
        $expected=@('SchemaVersion','ArtifactId','PayloadRoot','PackageSha256','ProbeSha256','SqlMediaPath','MediaEdition','StateRoot','MediaRoot')
        $values=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach($property in $document.RootElement.EnumerateObject()){
            if($property.Name -cnotin $expected -or $values.ContainsKey($property.Name) -or $property.Value.ValueKind -ne [Text.Json.JsonValueKind]::String){throw 'CSHARP_NATIVE_PROFILE_SCHEMA'}
            $value=$property.Value.GetString()
            if([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 1024 -or $value -match '[\x00-\x1f]') {throw 'CSHARP_NATIVE_PROFILE_SCHEMA'}
            $values.Add($property.Name,$value)
        }
        if($values.Count -ne $expected.Count -or $values['SchemaVersion'] -cne '1' -or
            $values['ArtifactId'] -cnotmatch '^hyperv-os-sealed-[a-f0-9]{64}$' -or
            $values['PackageSha256'] -cnotmatch '^[a-f0-9]{64}$' -or $values['ProbeSha256'] -cnotmatch '^[a-f0-9]{64}$' -or
            $values['MediaEdition'] -cnotin @('Enterprise','Standard','Eval')){throw 'CSHARP_NATIVE_PROFILE_SCHEMA'}
        foreach($key in @('PayloadRoot','StateRoot','MediaRoot')){
            $path=$values[$key]
            if($path -cnotmatch '^[A-Za-z]:\\' -or $path.Substring(2).Contains(':') -or $path -match '(?:^|[\\/])\.{1,2}(?:[\\/]|$)' -or $path.Contains('/')){throw 'CSHARP_NATIVE_PROFILE_PATH'}
        }
        if($values['SqlMediaPath'] -match '[:/]' -or $values['SqlMediaPath'].StartsWith('\') -or
            $values['SqlMediaPath'] -match '(?:^|\\)\.{1,2}(?:\\|$)' -or $values['SqlMediaPath'] -notmatch '(?i)\.iso$'){throw 'CSHARP_NATIVE_PROFILE_PATH'}
        return [pscustomobject]@{ArtifactId=$values['ArtifactId'];PayloadRoot=$values['PayloadRoot'];PackageSha256=$values['PackageSha256'];ProbeSha256=$values['ProbeSha256'];SqlMediaPath=$values['SqlMediaPath'];MediaEdition=$values['MediaEdition'];StateRoot=$values['StateRoot'];MediaRoot=$values['MediaRoot']}
    }catch{
        $code=Get-CSharpNativeFailureCode $_
        if($code -eq 'CSHARP_NATIVE_UNCLASSIFIED_FAILURE'){$code='CSHARP_NATIVE_PROFILE_SCHEMA'}
        throw $code
    }finally{if($document){$document.Dispose()}}
}

function Get-CSharpNativeProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $stream=$null;$reader=$null
    try{
        if($Name -cne 'csharp-sql2025'){throw 'CSHARP_NATIVE_PROFILE_NAME'}
        $root=$env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT
        if([string]::IsNullOrWhiteSpace($root)){throw 'CSHARP_NATIVE_PROFILE_ROOT_REQUIRED'}
        $path=Join-Path $root ($Name+'.json')
        Assert-CSharpNativeProfilePath $path
        # Same-handle bounded read; do not permit a concurrent writer or deletion.
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if($stream.Length -le 0 -or $stream.Length -gt 16384){throw 'CSHARP_NATIVE_PROFILE_SIZE'}
        $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$false)
        return ConvertFrom-CSharpNativeProfile ($reader.ReadToEnd())
    }catch{
        $code=Get-CSharpNativeFailureCode $_
        if($code -eq 'CSHARP_NATIVE_UNCLASSIFIED_FAILURE'){$code='CSHARP_NATIVE_PROFILE_READ_FAILED'}
        throw $code
    }finally{if($reader){$reader.Dispose()};if($stream){$stream.Dispose()}}
}

function Assert-CSharpNativeClientReadiness {
    [CmdletBinding()]
    param([AllowNull()]$Readiness)
    # Create/1.0 deliberately leaves target authorization to the operation entrypoint.
    # This adapter accepts only that exact warning, never a general warning status.
    $failure='CSHARP_NATIVE_CLIENT_NOT_READY'
    if($null -eq $Readiness -or $Readiness.ContractVersion -cne 'SqlServerLab.ClientReadiness/1.0' -or
        $Readiness.Provider -cne 'hyperv' -or $Readiness.Operation -cne 'Create' -or
        $Readiness.Status -cne 'READY_WITH_WARNINGS' -or $Readiness.MutationAllowed -isnot [bool] -or $Readiness.MutationAllowed -or
        -not $Readiness.PSObject.Properties['MissingPrerequisites'] -or @($Readiness.MissingPrerequisites).Count -ne 0 -or
        @($Readiness.Warnings).Count -ne 1 -or $Readiness.Warnings[0] -cne 'TARGET_AUTHORIZATION_REQUIRED'){
        throw $failure
    }
    $expected=[ordered]@{OperatingSystem='OS_SUPPORTED';PowerShell='POWERSHELL_SUPPORTED';Repository='REPOSITORY_PRESENT';Manifest='MANIFEST_VALID';ModuleImport='MODULE_IMPORTED';Exports='MODULE_EXPORTS_PRESENT';Reachability='PROVIDER_REACHABLE';Storage='STORAGE_CONFIGURED'}
    $checks=@($Readiness.Checks)
    if($checks.Count -ne 9){throw $failure}
    foreach($category in $expected.Keys){
        $matches=@($checks|Where-Object {$_.Category -ceq $category})
        if($matches.Count -ne 1 -or $matches[0].Code -cne $expected[$category] -or $matches[0].Status -cne 'PASS' -or
            $matches[0].MissingPrerequisite -or $matches[0].Warning){throw $failure}
    }
    $rights=@($checks|Where-Object {$_.Category -ceq 'OperationRights'})
    if($rights.Count -ne 1 -or $rights[0].Code -cne 'TARGET_AUTHORIZATION_REQUIRED' -or $rights[0].Status -cne 'WARNING' -or
        $rights[0].Warning -cne 'TARGET_AUTHORIZATION_REQUIRED' -or $rights[0].MissingPrerequisite){throw $failure}
}
