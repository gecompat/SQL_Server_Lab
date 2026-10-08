#Requires -Version 7.2
# Actual shared classifier/converter with synthetic facts; no product initialization.
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$factsModule=$null
try {
    $factsModule=New-Module -ArgumentList $root -ScriptBlock {
        param($root)
        Set-StrictMode -Version Latest
        $script:ModuleRoot=$root;$script:CatalogsPath=Join-Path $root 'Catalogs'
        $script:VersionCatalog=Get-Content (Join-Path $root 'Catalogs/sql-server-versions.json') -Raw|ConvertFrom-Json
        $script:RegisteredProviders=@{}
        foreach($provider in @('Docker','Podman')) {
            $definition=Get-Content (Join-Path $root "Providers/$provider/provider.json") -Raw|ConvertFrom-Json
            $script:RegisteredProviders[$definition.name]=@{Definition=$definition}
        }
        foreach($file in @('Private/VersionCatalog.ps1','Private/SoftwareCatalog.ps1','Private/ContainerImageArtifact.ps1',
            'Private/ExternalRuntimeCapability.ps1','Public/Get-SqlServerLabExternalRuntimeCapability.ps1',
            'Private/ExternalRuntimeCapabilityHttp.ps1')) { . (Join-Path $root $file) }
        $script:passed=0;$script:nativeAttempts=0;$script:effects=0
        function Assert-Fact {param([bool]$Condition,[string]$Name)
            if(-not $Condition){throw "HOST_FACTS_CHECK_FAILED: $Name"};$script:passed++;Write-Host "PASS: $Name"
        }
        function Resolve-LabHostTool { $script:nativeAttempts++;throw 'HOST_FACTS_NATIVE_FORBIDDEN' }
        function Get-LabHostToolInvocation { $script:nativeAttempts++;throw 'HOST_FACTS_NATIVE_FORBIDDEN' }
        function Initialize-LabHostToolPath { $script:nativeAttempts++;throw 'HOST_FACTS_NATIVE_FORBIDDEN' }
        function Invoke-LabExternalRuntimeInfoProcess { $script:nativeAttempts++;throw 'HOST_FACTS_NATIVE_FORBIDDEN' }
        function Invoke-LabProgressNativeCommand { $script:nativeAttempts++;throw 'HOST_FACTS_NATIVE_FORBIDDEN' }
        function Start-Process { $script:nativeAttempts++;throw 'HOST_FACTS_NATIVE_FORBIDDEN' }
        function New-DockerInfo {param($OS='linux',$Cgroup='1',$Security=@())
            [pscustomobject]@{OSType=$OS;CgroupVersion=$Cgroup;SecurityOptions=$Security}
        }
        function New-PodmanInfo {param($OS='linux',$Cgroup='v1',$Rootless=$false)
            [pscustomobject]@{host=[pscustomobject]@{os=$OS;cgroupVersion=$Cgroup;security=[pscustomobject]@{rootless=$Rootless}}}
        }
    }
    & $factsModule {
        $root=$script:ModuleRoot
        $unknown=@(
            @{Id='missing security';Provider='docker';Info=[pscustomobject]@{OSType='linux';CgroupVersion='1'}},
            @{Id='null security';Provider='docker';Info=(New-DockerInfo -Security $null)},
            @{Id='scalar security';Provider='docker';Info=(New-DockerInfo -Security 'name=seccomp')},
            @{Id='wrong security element';Provider='docker';Info=(New-DockerInfo -Security @(1))},
            @{Id='unknown rootless token';Provider='docker';Info=(New-DockerInfo -Security @('name=ROOTLESS'))},
            @{Id='security quota';Provider='docker';Info=(New-DockerInfo -Security (@('name=seccomp')*17))},
            @{Id='string false';Provider='podman';Info=(New-PodmanInfo -Rootless 'false')},
            @{Id='numeric rootless';Provider='podman';Info=(New-PodmanInfo -Rootless 0)},
            @{Id='null rootless';Provider='podman';Info=(New-PodmanInfo -Rootless $null)},
            @{Id='missing security object';Provider='podman';Info=[pscustomobject]@{host=[pscustomobject]@{os='linux';cgroupVersion='v1'}}},
            @{Id='wrong host object';Provider='podman';Info=[pscustomobject]@{host=@{os='linux';cgroupVersion='v1';security=@{rootless=$false}}}},
            @{Id='conflicting alias';Provider='podman';Info=[pscustomobject]@{host=[pscustomobject]@{os='linux';cgroupVersion='1';cgroupsVersion='2';security=[pscustomobject]@{rootless=$false}}}},
            @{Id='null primary with valid alias';Provider='podman';Info=[pscustomobject]@{host=[pscustomobject]@{os='linux';cgroupVersion=$null;cgroupsVersion='1';security=[pscustomobject]@{rootless=$false}}}},
            @{Id='invalid primary with valid alias';Provider='podman';Info=[pscustomobject]@{host=[pscustomobject]@{os='linux';cgroupVersion='bad-v1';cgroupsVersion='1';security=[pscustomobject]@{rootless=$false}}}},
            @{Id='boolean primary with valid alias';Provider='podman';Info=[pscustomobject]@{host=[pscustomobject]@{os='linux';cgroupVersion=$true;cgroupsVersion='1';security=[pscustomobject]@{rootless=$false}}}},
            @{Id='valid primary with boolean alias';Provider='podman';Info=[pscustomobject]@{host=[pscustomobject]@{os='linux';cgroupVersion='1';cgroupsVersion=$true;security=[pscustomobject]@{rootless=$false}}}},
            @{Id='malformed cgroup';Provider='docker';Info=(New-DockerInfo -Cgroup 'prefix-v1-tail')},
            @{Id='numeric cgroup';Provider='docker';Info=(New-DockerInfo -Cgroup 1)},
            @{Id='null cgroup';Provider='podman';Info=(New-PodmanInfo -Cgroup $null)},
            @{Id='unknown OS';Provider='docker';Info=(New-DockerInfo -OS 'SYNTHETIC_HOST_CANARY')},
            @{Id='null OS';Provider='podman';Info=(New-PodmanInfo -OS $null)},
            @{Id='wrong OS type';Provider='docker';Info=(New-DockerInfo -OS @('linux'))},
            @{Id='wrong info object';Provider='docker';Info=@{OSType='linux';CgroupVersion='1';SecurityOptions=@()}}
        )
        foreach($case in $unknown) {
            $raw=Get-LabExternalRuntimeHostCapability -Provider $case.Provider -SqlVersion 2022 -RuntimeInfo $case.Info -ToolAvailable $true -RuntimeReachable $true
            Assert-Fact ($raw.Status -ceq 'UNKNOWN' -and -not $raw.Supported -and $raw.ReasonCode -ceq 'PROVIDER_RESPONSE_INVALID') "$($case.Id): unknown never gains support"
            Assert-Fact ([string]::IsNullOrEmpty($raw.CgroupVersion) -and $null -eq $raw.Rootless -and $raw.Guidance -and $raw.DisplayReason -match 'Abhilfe:' -and
                ($raw|ConvertTo-Json -Depth 5 -Compress) -notmatch 'SYNTHETIC_HOST_CANARY|prefix-v1-tail') "$($case.Id): fixed reason and unknown facts"
        }
        foreach($provider in @('docker','podman')) {
            foreach($cgroup in @('1','v1','2','v2')) {
                $info=if($provider -ceq 'docker'){New-DockerInfo -Cgroup $cgroup}else{New-PodmanInfo -Cgroup $cgroup}
                $required=$cgroup.TrimStart('v')
                $ready=Get-LabExternalRuntimeHostCapability -Provider $provider -SqlVersion 2025 -RequiredCgroupVersion $required -RuntimeInfo $info -ToolAvailable $true -RuntimeReachable $true
                Assert-Fact ($ready.Status -ceq 'READY' -and $ready.CgroupVersion -ceq $required -and $ready.Rootless -eq $false) "$provider exact $cgroup rootful remains ready"
            }
            $windows=if($provider -ceq 'docker'){New-DockerInfo -OS windows}else{New-PodmanInfo -OS windows}
            $rootless=if($provider -ceq 'docker'){New-DockerInfo -Security @('name=rootless')}else{New-PodmanInfo -Rootless $true}
            foreach($known in @(@{Info=$windows;Code='LINUX_RUNTIME_REQUIRED'},@{Info=$rootless;Code='ROOTFUL_PROVIDER_REQUIRED'})) {
                $result=Get-LabExternalRuntimeHostCapability -Provider $provider -SqlVersion 2022 -RuntimeInfo $known.Info -ToolAvailable $true -RuntimeReachable $true
                Assert-Fact ($result.Status -ceq 'DECLARED_UNSUPPORTED' -and -not $result.Supported -and $result.ReasonCode -ceq $known.Code) "$provider known $($known.Code) remains incompatible"
            }
        }
        foreach($aliasInfo in @(
            [pscustomobject]@{host=[pscustomobject]@{os='linux';cgroupsVersion='v1';security=[pscustomobject]@{rootless=$false}}},
            [pscustomobject]@{host=[pscustomobject]@{os='linux';cgroupVersion='v1';cgroupsVersion='v1';security=[pscustomobject]@{rootless=$false}}}
        )) {
            $result=Get-LabExternalRuntimeHostCapability -Provider podman -SqlVersion 2022 -RuntimeInfo $aliasInfo -ToolAvailable $true -RuntimeReachable $true
            Assert-Fact ($result.Status -ceq 'READY') 'Typed unambiguous historical alias remains supported'
        }
        foreach($pair in @(
            @{Primary='1';Alias='v1';Required='1'},@{Primary='v1';Alias='1';Required='1'},
            @{Primary='2';Alias='v2';Required='2'},@{Primary='v2';Alias='2';Required='2'}
        )) {
            $info=[pscustomobject]@{host=[pscustomobject]@{os='linux';cgroupVersion=$pair.Primary;cgroupsVersion=$pair.Alias;security=[pscustomobject]@{rootless=$false}}}
            $result=Get-LabExternalRuntimeHostCapability -Provider podman -SqlVersion 2025 -RequiredCgroupVersion $pair.Required -RuntimeInfo $info -ToolAvailable $true -RuntimeReachable $true
            Assert-Fact ($result.Status -ceq 'READY' -and $result.Supported -and $result.ReasonCode -ceq 'NONE' -and
                $result.CgroupVersion -ceq $pair.Required -and $result.Rootless -eq $false -and $script:nativeAttempts -eq 0 -and $script:effects -eq 0) "Equivalent typed Podman aliases $($pair.Primary)/$($pair.Alias) preserve canonical readiness without effects"
        }
        $result=Get-LabExternalRuntimeHostCapability -Provider Docker -SqlVersion 2022 -RuntimeInfo (New-DockerInfo) -ToolAvailable $true -RuntimeReachable $true
        Assert-Fact ($result.Status -ceq 'READY') 'Existing ValidateSet provider casing remains supported'
        # The existing catalog resolver uses optional properties under the
        # product module's default mode; keep its actual caller environment.
        Set-StrictMode -Off
        $parameters=@{SqlVersion='2022';Provider='docker';OperatingSystem='linux';SoftwareId='sql-python';RuntimeVersion='3.10';VariantId='sql2022-python310-ubuntu2204-derived'}
        foreach($projection in @(
            [pscustomobject]@{OperatingSystem='linux';CgroupVersion='1';SecurityOptions=$null},
            [pscustomobject]@{OperatingSystem='linux';CgroupVersion='bad-v1';SecurityOptions=@()},
            [pscustomobject]@{OperatingSystem='linux';CgroupVersion='1';SecurityOptions=@(1)},
            [pscustomobject]@{OperatingSystem='SYNTHETIC_HOST_CANARY';CgroupVersion='1';SecurityOptions=@()}
        )) {
            $caught=$false;try{$null=ConvertTo-LabExternalRuntimeHostFacts -Provider docker -Value $projection}catch{$caught=$_.Exception.Message -ceq 'PROVIDER_RESPONSE_INVALID'}
            Assert-Fact $caught 'Shared public projection rejects malformed facts without type coercion'
        }
        $decision=New-LabExternalRuntimeCapabilityDecision @parameters -HostObservation ([pscustomobject]@{Status='UNAVAILABLE';ReasonCode='PROVIDER_RESPONSE_INVALID';Facts=$null})
        Assert-LabExternalRuntimeHttpDecision $decision
        Assert-Fact ($decision.CurrentReadiness.Status -ceq 'BLOCKED' -and $decision.CurrentReadiness.ReasonCode -ceq 'PROVIDER_RESPONSE_INVALID' -and
            -not $decision.ExecutionSupported -and -not $decision.MutationAllowed -and $decision.Actions.Count -eq 0) 'Unknown host is accepted by closed public/browser DTO as BLOCKED without authority'
        $script:actualClassifier=(Get-Command Get-LabExternalRuntimeHostCapability).ScriptBlock
        function Get-LabExternalRuntimeHostCapability {
            param($Provider,$SqlVersion,$RequiredCgroupVersion='1')
            & $script:actualClassifier -Provider $Provider -SqlVersion $SqlVersion -RequiredCgroupVersion $RequiredCgroupVersion `
                -RuntimeInfo (New-DockerInfo -Security $null) -ToolAvailable $true -RuntimeReachable $true
        }
        # Bind the actual menu function and both existing pre-mutation veto statements.
        foreach($source in @('Public/Invoke-SqlServerLab.ps1','Public/New-SqlServerLab.ps1','Private/ContainerImageArtifact.ps1')) {
            $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $source),[ref]$tokens,[ref]$errors)
            Assert-Fact ($errors.Count -eq 0) "Actual consumer parses $source"
            if($source -ceq 'Public/Invoke-SqlServerLab.ps1') {
                $functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-LabExternalRuntimeMenuCapability'},$true))
                Assert-Fact ($functions.Count -eq 1) 'Actual console/fallback classifier is unique'
                . ([scriptblock]::Create($functions[0].Extent.Text))
                $menu=Get-LabExternalRuntimeMenuCapability -Instance ([pscustomobject]@{provider='docker';version='2022'})
                Assert-Fact ($menu.Status -ceq 'UNKNOWN' -and -not $menu.Supported -and $menu.ReasonCode -ceq 'PROVIDER_RESPONSE_INVALID' -and $menu.DisplayReason -match 'Abhilfe:') 'Actual console/fallback preserves unknown reason'
            } else {
                $guards=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq '[string]$hostStatus.Status -ne ''READY'''},$true))
                Assert-Fact ($guards.Count -eq 1) "Actual pre-mutation guard is unique $source"
                $request=[pscustomobject]@{Id='sql-python';Version=$null;Variant=$null;InstallMethod='catalog';Packages=@();RequestSource='test'}
                $plan=Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion 2022 -Provider docker -OperatingSystem linux
                $imagePlan=New-LabExternalRuntimeContainerImagePlan -Provider docker -SqlVersion 2022 -SoftwarePlans @($plan)
                $hostStatus=Test-LabExternalRuntimeContainerHost -Provider docker -ImagePlan $imagePlan
                $instance=[pscustomobject]@{id='synthetic-instance'};$caught=$false
                try { & ([scriptblock]::Create($guards[0].Extent.Text));$script:effects++ }
                catch { $caught=$_.Exception.Message -match '^EXTERNAL_RUNTIME_CONTAINER_HOST_REJECTED \[PROVIDER_RESPONSE_INVALID\]:' }
                Assert-Fact ($hostStatus.Status -ceq 'UNKNOWN' -and $caught -and $script:effects -eq 0) "Genuine valid image plan and actual $source guard veto before synthetic effect"
            }
        }
        Assert-Fact ($script:nativeAttempts -eq 0 -and $script:effects -eq 0) 'No native/tool/provider/state/SQL effects'
        Write-Host "HOST FACTS CHECKS: PASS ($script:passed assertions; synthetic facts only)"
    }
} finally {
    if($factsModule){Remove-Module $factsModule -ErrorAction Stop}
    $factsModule=$null
}
