# Actual public composition, one bounded synthetic transport, no provider execution.
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$m=New-Module -ArgumentList $root -ScriptBlock {
    param($root)
    # Match the existing minimal capability fixture: full module startup state
    # is intentionally absent here; reducer types are checked independently.
    Set-StrictMode -Off
    $script:ModuleRoot=$root;$script:CatalogsPath=Join-Path $root 'Catalogs'
    $script:VersionCatalog=Get-Content (Join-Path $script:CatalogsPath 'sql-server-versions.json') -Raw|ConvertFrom-Json
    $script:RegisteredProviders=@{}
    foreach($provider in @('Docker','Podman')){
        $d=Get-Content (Join-Path $root "Providers/$provider/provider.json") -Raw|ConvertFrom-Json
        $script:RegisteredProviders[$d.name]=@{Definition=$d}
    }
    foreach($file in @('VersionCatalog','SoftwareCatalog','ContainerImageArtifact','DiagnosticBundleReadiness','ExternalRuntimeCapability','ExternalRuntimeHostPrerequisites')){
        . (Join-Path $root "Private/$file.ps1")
    }
    . (Join-Path $root 'Public/Get-SqlServerLabExternalRuntimeCapability.ps1')
    $script:count=0;$script:initializers=0;$script:transports=0;$script:mode='ready'
    function Assert-Prereq {param([bool]$Condition,[string]$Name)
        if(-not $Condition){throw "PUBLIC_PREREQUISITE_FAILED: $Name"};$script:count++
    }
    function Initialize-LabHostToolPath {param($Name)
        $script:initializers++;[pscustomobject]@{Available=$true;Invocation=(Join-Path ([IO.Path]::GetTempPath()) "synthetic-$Name.exe")}
    }
    function Invoke-LabDiagnosticBoundedProcess {param($StartInfo,$TimeoutSeconds,$MaximumBytes)
        if($TimeoutSeconds -ne 20 -or $MaximumBytes -ne 65536 -or $StartInfo.ArgumentList.Count -ne 3 -or
            $StartInfo.ArgumentList[0] -cne 'info' -or $StartInfo.ArgumentList[1] -cne '--format' -or $StartInfo.UseShellExecute){throw 'PREREQUISITE_TRANSPORT_CHANGED'}
        $script:transports++
        $docker=$StartInfo.FileName -like '*docker*'
        $extended=$StartInfo.ArgumentList[2] -match 'MemoryLimit|Controllers'
        $value=if($docker){[pscustomobject]@{OperatingSystem='linux';CgroupVersion='1';SecurityOptions=@()}}
            else{[pscustomobject]@{OperatingSystem='linux';CgroupVersion='v1';Rootless=$false}}
        if($script:mode -ceq 'v2'){$value.CgroupVersion='2'}
        if($extended){
            $value|Add-Member MemTotal 8GB
            if($docker){$value|Add-Member MemoryLimit $true;$value|Add-Member PidsLimit $true;$value|Add-Member NCPU 8}
            else{$value|Add-Member CgroupsVersion $(if($script:mode -ceq 'v2'){'2'}else{'v1'});$value|Add-Member Controllers @('cpu','memory','pids');$value|Add-Member Cpus 8
                if($script:mode -ceq 'aliasOnly'){$value.PSObject.Properties.Remove('CgroupVersion')}
                if($script:mode -ceq 'aliasConflict'){$value.CgroupsVersion='v2'}}
            if($script:mode -ceq 'low'){$value.MemTotal=1GB}
            if($script:mode -ceq 'invalidCapacity'){$value.MemTotal='PRIVATE_HOST_CANARY'}
            if($script:mode -ceq 'missingController'){if($docker){$value.MemoryLimit=$false}else{$value.Controllers=@('cpu','pids')}}
            if($script:mode -ceq 'unknownController'){if($docker){$value.PSObject.Properties.Remove('MemoryLimit')}else{$value.PSObject.Properties.Remove('Controllers')}}
            if($script:mode -ceq 'extra'){$value|Add-Member Hostname 'PRIVATE_HOST_CANARY'}
        }
        [pscustomobject]@{Success=$true;Reason='NONE';Value=$value}
    }
    function Get-LabHostToolInvocation {throw 'UNBOUNDED_NATIVE_FORBIDDEN'}
    function Resolve-LabHostTool {throw 'UNBOUNDED_NATIVE_FORBIDDEN'}
}
try { & $m {
    $args=@{SqlVersion='2022';Provider='docker';OperatingSystem='linux';SoftwareId='sql-python';RuntimeVersion='3.10';VariantId='sql2022-python310-ubuntu2204-derived'}
    $legacy=Get-SqlServerLabExternalRuntimeCapability @args
    Assert-Prereq ($legacy.Contract.Version -ceq '1.0' -and -not $legacy.PSObject.Properties['HostPrerequisites'] -and $script:transports -eq 0) 'Default remains unchanged and starts no probe'
    $unmeasured=Get-SqlServerLabExternalRuntimeCapability @args -IncludeHostPrerequisites
    Assert-Prereq ($unmeasured.Contract.Version -ceq '1.2' -and $unmeasured.HostPrerequisites.Status -ceq 'NOT_CHECKED' -and
        $unmeasured.CurrentReadiness.Status -ceq 'NOT_CHECKED' -and $script:transports -eq 0 -and $script:initializers -eq 0) 'Opt-in metadata alone starts no tool or native process'
    foreach($provider in @('docker','podman')){
        $args.Provider=$provider
        foreach($mode in @('ready','low','invalidCapacity','missingController','unknownController','extra')){
            $script:mode=$mode;$before=$script:transports
            $d=Get-SqlServerLabExternalRuntimeCapability @args -IncludeHostPrerequisites -CheckProviderReadiness -ResourceProfile standard
            Assert-Prereq ($script:transports -eq $before+1 -and $d.Contract.Version -ceq '1.2') "$provider $mode exactly one existing bounded info transport"
            Assert-Prereq (-not $d.ExecutionSupported -and -not $d.MutationAllowed -and $d.Actions.Count -eq 0 -and
                -not $d.HostPrerequisites.ExecutionSupported -and $d.HostPrerequisites.FullLaunchReadiness -ceq 'INCOMPLETE' -and
                -not $d.HostPrerequisites.SharedKernel.IsolationProven -and $d.SqlLanguageExecution -ceq 'NOT_CHECKED') "$provider $mode no execution or WSL independence claim"
            Assert-Prereq (($d|ConvertTo-Json -Depth 25 -Compress) -notmatch 'PRIVATE_HOST_CANARY|synthetic-|MemTotal|NCPU|SecurityOptions|cgroupControllers') "$provider $mode no raw inventory"
            if($mode -ceq 'ready'){
                Assert-Prereq ($d.CurrentReadiness.Status -ceq 'READY' -and $d.HostPrerequisites.Status -ceq 'COMPATIBLE' -and
                    $d.HostPrerequisites.ResourceCapacity.FreeMemory -ceq 'NOT_CHECKED') "$provider narrow prerequisites remain separate from free RAM"
            }else{
                $expected=switch($mode){low{'RESOURCE_PROFILE_CAPACITY_INSUFFICIENT'}invalidCapacity{'RESOURCE_PROFILE_CAPACITY_UNKNOWN'}missingController{'RESOURCE_CONTROLLERS_UNAVAILABLE'}unknownController{'RESOURCE_CONTROLLERS_UNKNOWN'}extra{'PROVIDER_RESPONSE_INVALID'}}
                Assert-Prereq ($d.CurrentReadiness.Status -ceq 'BLOCKED' -and $d.CurrentReadiness.ReasonCode -ceq $expected) "$provider $mode actual reducer blocks with scoped reason"
            }
        }
    }
    $args.Provider='podman';$script:mode='aliasOnly'
    $aliasOnly=Get-SqlServerLabExternalRuntimeCapability @args -IncludeHostPrerequisites -CheckProviderReadiness -ResourceProfile standard
    Assert-Prereq ($aliasOnly.CurrentReadiness.Status -ceq 'READY') 'Podman historical cgroupsVersion alone follows canonical v1 decision'
    $script:mode='aliasConflict'
    $aliasConflict=Get-SqlServerLabExternalRuntimeCapability @args -IncludeHostPrerequisites -CheckProviderReadiness -ResourceProfile standard
    Assert-Prereq ($aliasConflict.CurrentReadiness.Status -ceq 'BLOCKED' -and $aliasConflict.CurrentReadiness.ReasonCode -ceq 'PROVIDER_RESPONSE_INVALID') 'Podman conflicting cgroup aliases remain invalid'
    $before=$script:transports
    try{Get-SqlServerLabExternalRuntimeCapability @args -IncludeHostPrerequisites -CheckProviderReadiness -ResourceProfile unknown;throw 'EXPECTED_PROFILE_REJECTION'}
    catch{if($_.Exception.Message -cne 'EXTERNAL_RUNTIME_RESOURCE_PROFILE_INVALID'){throw}}
    Assert-Prereq ($before -eq $script:transports) 'Unknown profile fails before native probe'
    $variant=@(((Get-LabSoftwareCatalog).software|Where-Object id -ceq 'sql-python').variants|Where-Object launchMode -ceq 'sql2025-shared-user-v2')[0]
    $args.SqlVersion='2025';$args.VariantId=$variant.id;$args.RuntimeVersion=$variant.runtimeVersion;$script:mode='v2'
    $d=Get-SqlServerLabExternalRuntimeCapability @args -IncludeHostPrerequisites -CheckProviderReadiness
    Assert-Prereq ($d.CurrentReadiness.Status -ceq 'READY' -and $d.CurrentReadiness.RequiredCgroupVersion -ceq '2' -and
        $d.Identity.SqlVersion -ceq '2025') 'Actual selected SQL2025 recipe binds v2 instead of native-tool default recipe'
    $before=$script:transports
    $args.VariantId='not-a-catalog-variant';$d=Get-SqlServerLabExternalRuntimeCapability @args -IncludeHostPrerequisites -CheckProviderReadiness
    Assert-Prereq ($d.HostPrerequisites.Status -ceq 'CATALOG_BLOCKED' -and $d.CurrentReadiness.Status -cne 'READY' -and $before -eq $script:transports) 'Blocked catalog starts no host probe'
    Write-Host "PUBLIC HOST PREREQUISITES: PASS ($script:count assertions; synthetic transport)"
} }finally{Remove-Module $m -ErrorAction SilentlyContinue}
