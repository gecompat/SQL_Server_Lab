# Test-only rendered overview. Actual public catalogue decisions; no provider probe.
. (Join-Path $PSScriptRoot ConnectionCenterCmsFullPageAcceptance.ps1)

function Get-HostMatrixBrowserCases {
    param([switch]$IncludeLaunchDetails)
    $cases=@(
        [pscustomobject]@{Action='ReadVersions';SqlVersion=$null;Provider=$null}
        [pscustomobject]@{Action='ReadMatrix';SqlVersion='2022';Provider='all'}
        [pscustomobject]@{Action='ReadMatrix';SqlVersion='2022';Provider='hyperv'}
        [pscustomobject]@{Action='ReadMatrix';SqlVersion='2025';Provider='docker'}
        [pscustomobject]@{Action='ReadMatrix';SqlVersion='2016';Provider='podman'}
        [pscustomobject]@{Action='ReadVersions';SqlVersion=$null;Provider=$null}
    )
    if($IncludeLaunchDetails){$cases+=@([pscustomobject]@{Action='ReadMatrix';SqlVersion='2022';Provider='docker'})}
    $cases
}

function Get-HostMatrixBrowserProductParts {
    param([string]$RepositoryRoot,[switch]$IncludeLaunchDetails)
    $parts=Get-CmsFullPageProductParts $RepositoryRoot
    $paths=@('Private/VersionCatalog.ps1','Private/SoftwareCatalog.ps1','Private/ExternalRuntimeCapability.ps1',
        'Private/HostCapabilityMatrix.ps1','Private/HostCapabilityMatrixHttp.ps1','Public/Get-SqlServerLabHostCapabilityMatrix.ps1',
        'Catalogs/software.json','Catalogs/sql-server-versions.json','Providers/Docker/provider.json','Providers/Podman/provider.json','Providers/HyperV/provider.json',
        'Tests/Common/HostCapabilityMatrixBrowserAcceptance.ps1','Tests/Common/ConnectionCenterCmsFullPageAcceptance.ps1',
        'Tests/Common/ConnectionCenterCmsInspectionBrowserAcceptance.ps1','Tests/Integration/Invoke-HostCapabilityMatrixBrowserAcceptance.ps1',
        'Tests/Static/Fixtures/HostCapabilityMatrixBrowserAcceptanceChecks.ps1')
    $sources=@($parts.Sources)+@(foreach($path in $paths) {
        $file=Join-Path $RepositoryRoot $path;Assert-CmsBrowserPath $file
        if((Get-Item -LiteralPath $file).Length -gt 256KB) {throw 'HOST_MATRIX_BROWSER_SOURCE_LIMIT'}
        [pscustomobject]@{Path=$path;Sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}
    })
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepositoryRoot 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tokens,[ref]$errors)
    $route=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -ceq "`$path -eq '/api/host-capability-matrix'"},$true))
    if($errors.Count -or $route.Count -ne 1) {throw 'HOST_MATRIX_BROWSER_ROUTE_BINDING'}
    $legacyDispatch=$null
    if($IncludeLaunchDetails) {
        . (Join-Path $PSScriptRoot ExternalRuntimeCapabilityCatalogBrowserAcceptance.ps1)
        $legacy=Get-ExternalCatalogBrowserProductParts $RepositoryRoot;$legacyDispatch=$legacy.Dispatch
        $sources=@(@($sources)+@($legacy.Sources)|Sort-Object Path -Unique)
    }
    [pscustomobject]@{Assets=$parts.Assets;Sources=$sources;Dispatch=[scriptblock]::Create('foreach($iteration in 1){'+$route[0].Extent.Text+"`nthrow 'HOST_MATRIX_BROWSER_FALLTHROUGH'"+'}');LegacyDispatch=$legacyDispatch}
}

function Assert-HostMatrixBrowserSources {
    param([string]$RepositoryRoot,[object[]]$Sources)
    if($Sources.Count -lt 1 -or $Sources.Count -gt 96) {throw 'HOST_MATRIX_BROWSER_SOURCE_COUNT'}
    foreach($source in $Sources) {
        if($source.Path -isnot [string] -or $source.Path -cnotmatch '^[a-zA-Z0-9._/-]{1,256}$' -or
            $source.Path -match '(^|/)\.{1,2}(/|$)' -or [IO.Path]::IsPathRooted($source.Path) -or
            $source.Sha256 -isnot [string] -or $source.Sha256 -cnotmatch '^[A-F0-9]{64}$') {throw 'HOST_MATRIX_BROWSER_SOURCE_BINDING'}
        $file=Join-Path $RepositoryRoot $source.Path;Assert-CmsBrowserPath $file
        if((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -cne $source.Sha256) {throw 'HOST_MATRIX_BROWSER_SOURCE_DRIFT'}
    }
}

function New-HostMatrixBrowserModule {
    param([string]$RepositoryRoot,[switch]$IncludeLaunchDetails)
    New-Module -ArgumentList $RepositoryRoot,([bool]$IncludeLaunchDetails) -ScriptBlock {
        param($root,$includeLegacy)
        $script:ModuleRoot=$root;$script:CatalogsPath=Join-Path $root 'Catalogs'
        $script:VersionCatalog=Get-Content (Join-Path $root Catalogs/sql-server-versions.json) -Raw|ConvertFrom-Json
        $script:RegisteredProviders=@{}
        foreach($name in @('Docker','Podman','HyperV')) {
            $definition=Get-Content (Join-Path $root "Providers/$name/provider.json") -Raw|ConvertFrom-Json
            $script:RegisteredProviders[$definition.name]=@{Definition=$definition}
        }
        foreach($path in @('Private/VersionCatalog.ps1','Private/SoftwareCatalog.ps1','Private/ExternalRuntimeCapability.ps1',
            'Private/HostCapabilityMatrix.ps1','Public/Get-SqlServerLabHostCapabilityMatrix.ps1','Private/HostCapabilityMatrixHttp.ps1')) {. (Join-Path $root $path)}
        $script:BrowserCalls=[Collections.Generic.List[object]]::new();$script:BrowserEffects=0
        $script:BrowserLegacyCalls=[Collections.Generic.List[object]]::new()
        $script:BrowserOriginalPublic=(Get-Command Get-SqlServerLabHostCapabilityMatrix).ScriptBlock
        function Get-SqlServerLabHostCapabilityMatrix {
            param($SqlVersion,$Provider,[switch]$CheckProviderReadiness)
            if($CheckProviderReadiness) {$script:BrowserEffects++;throw 'HOST_MATRIX_BROWSER_PROBE_FORBIDDEN'}
            $script:BrowserCalls.Add([pscustomobject]@{SqlVersion=$SqlVersion;Provider=@($Provider);CheckProviderReadiness=[bool]$CheckProviderReadiness})
            & $script:BrowserOriginalPublic @PSBoundParameters
        }
        if($includeLegacy) {
            foreach($path in @('Private/ContainerImageArtifact.ps1','Public/Get-SqlServerLabExternalRuntimeCapability.ps1','Private/ExternalRuntimeCapabilityHttp.ps1')){. (Join-Path $root $path)}
            $script:BrowserOriginalLegacy=(Get-Command Get-SqlServerLabExternalRuntimeCapability).ScriptBlock
            function Get-SqlServerLabExternalRuntimeCapability {
                param($SqlVersion,$Provider,$OperatingSystem,$SoftwareId,$RuntimeVersion,$VariantId,[switch]$CheckProviderReadiness,[switch]$IncludeRecordedEvidence)
                if($CheckProviderReadiness -or $IncludeRecordedEvidence){$script:BrowserEffects++;throw 'HOST_MATRIX_BROWSER_LEGACY_OPTIN_FORBIDDEN'}
                $script:BrowserLegacyCalls.Add([pscustomobject]@{SqlVersion=$SqlVersion;Provider=$Provider;SoftwareId=$SoftwareId;RuntimeVersion=$RuntimeVersion;VariantId=$VariantId;HostProbe=[bool]$CheckProviderReadiness;History=[bool]$IncludeRecordedEvidence})
                & $script:BrowserOriginalLegacy @PSBoundParameters
            }
        }
        foreach($name in @('Get-LabDiagnosticReadiness','Invoke-LabDiagnosticReadinessProcess','Initialize-LabHostToolPath',
            'Invoke-LabDiagnosticBoundedProcess','Invoke-Sqlcmd','Start-Process','Get-VM','Get-VMHost','Get-LabStateRoot',
            'Get-LabDataRoot','Get-LabRunState','Write-LabEvent','Add-LabMessage','New-LabRunState','Get-LabSecret',
            'Get-LabPreferencesSnapshot','Invoke-LabContainerCli','Invoke-SqlServerLabWorkflowAction','Invoke-LabExternalRuntimeImageBuild','Read-LabExternalRuntimeHostFacts')) {
            Set-Item ("Function:script:$name") {$script:BrowserEffects++;throw 'HOST_MATRIX_BROWSER_EFFECT_FORBIDDEN'}
        }
    }
}

function Assert-HostMatrixLaunchBrowserRecord {
    param($Payload,$View,[int]$Index)
    $action=if($Index -eq 0){'ReadOptions'}elseif($Index -eq 1){'Evaluate'}else{throw 'HOST_MATRIX_BROWSER_EXTRA_LEGACY_ACTION'}
    $names=@('Action','SqlVersion','Provider','OperatingSystem')
    if($Index -eq 1){$names+=@('SoftwareId','RuntimeVersion','VariantId','CheckProviderReadiness')}
    Assert-LabHostMatrixHttpShape $Payload $names
    if($Payload.Action -cne $action -or $Payload.SqlVersion -cne '2022' -or $Payload.Provider -cne 'docker' -or $Payload.OperatingSystem -cne 'linux' -or
        $View.ContractVersion -cne 'SqlServerLab.ExternalRuntimeCapabilityBrowser/1.0'){throw 'HOST_MATRIX_BROWSER_LEGACY_SCOPE'}
    if($Index -eq 0) {
        if($View.Status -cne 'OPTIONS' -or @($View.Options|Where-Object {$_.VariantId -ceq 'sql2022-python310-ubuntu2204-derived' -and $_.Decision.CatalogDecision.Status -ceq 'DECLARED_SUPPORTED'}).Count -ne 1){throw 'HOST_MATRIX_BROWSER_LEGACY_OPTIONS'}
    } else {
        if($Payload.SoftwareId -cne 'sql-python' -or $Payload.RuntimeVersion -cne '3.10' -or $Payload.VariantId -cne 'sql2022-python310-ubuntu2204-derived' -or
            $Payload.CheckProviderReadiness -isnot [bool] -or $Payload.CheckProviderReadiness -or $View.Status -cne 'DECISION' -or
            $View.Decision.CurrentReadiness.Status -cne 'NOT_CHECKED' -or $View.Decision.SqlLanguageExecution -cne 'NOT_CHECKED' -or
            $View.Decision.MutationAllowed -or $View.Decision.ExecutionSupported -or $View.Decision.Actions.Count -ne 0){throw 'HOST_MATRIX_BROWSER_LEGACY_DECISION'}
    }
}

function Assert-HostMatrixBrowserPayload {
    param($Payload,$Case)
    if($Payload.Action -cne $Case.Action) {throw 'HOST_MATRIX_BROWSER_ACTION'}
    $names=if($Case.Action -ceq 'ReadVersions'){@('Action')}else{@('Action','SqlVersion','Provider','CheckProviderReadiness')}
    Assert-LabHostMatrixHttpShape $Payload $names
    if($Case.Action -ceq 'ReadMatrix' -and ($Payload.SqlVersion -cne $Case.SqlVersion -or $Payload.Provider -cne $Case.Provider -or
        $Payload.CheckProviderReadiness -isnot [bool] -or $Payload.CheckProviderReadiness)) {throw 'HOST_MATRIX_BROWSER_SCOPE'}
}

function Assert-HostMatrixBrowserResult {
    param($View,$Case)
    if($View.ContractVersion -cne 'SqlServerLab.HostCapabilityMatrixBrowser/1.0') {throw 'HOST_MATRIX_BROWSER_VIEW'}
    if($Case.Action -ceq 'ReadVersions') {
        if($View.Status -cne 'VERSIONS' -or '2022' -cnotin $View.Versions -or '2016' -cnotin $View.Versions) {throw 'HOST_MATRIX_BROWSER_VERSIONS'}
        return
    }
    $matrix=$View.Matrix
    if($View.Status -cne 'MATRIX' -or $matrix.SqlVersion -cne $Case.SqlVersion -or
        $matrix.ExecutionSupported -isnot [bool] -or $matrix.ExecutionSupported -or $matrix.MutationAllowed -isnot [bool] -or $matrix.MutationAllowed -or
        $matrix.Actions.Count -ne 0 -or @($matrix.Providers | Where-Object Readiness -CNE 'NOT_CHECKED').Count -or
        @($matrix.Capabilities | Where-Object Language -CEQ 'C#').Count -ne $matrix.Providers.Count) {throw 'HOST_MATRIX_BROWSER_DECISION'}
    if($Case.Provider -ceq 'all') {
        if($matrix.ProviderProfile -cne 'NOT_CHECKED' -or $matrix.Providers.Count -ne 3 -or $matrix.Capabilities.Count -ne 12) {throw 'HOST_MATRIX_BROWSER_ALL_PROVIDERS'}
    } elseif($matrix.ProviderProfile -cne 'PARTIAL_SELECTION' -or $matrix.Providers.Count -ne 1 -or $matrix.Providers[0].Provider -cne $Case.Provider) {throw 'HOST_MATRIX_BROWSER_SINGLE_PROVIDER'}
    if($Case.Provider -ceq 'hyperv' -and @($matrix.Capabilities | Where-Object TargetOperatingSystem -CNE 'windows').Count) {throw 'HOST_MATRIX_BROWSER_HYPERV'}
    if($Case.SqlVersion -ceq '2025' -and -not @($matrix.Capabilities | Where-Object ExplicitSelectionRequired -EQ $true).Count) {throw 'HOST_MATRIX_BROWSER_EXPLICIT_VARIANT'}
    if($Case.SqlVersion -ceq '2016' -and @($matrix.Capabilities | Where-Object Availability -CEQ 'CATALOG_BLOCKED').Count -ne 3) {throw 'HOST_MATRIX_BROWSER_BLOCKED'}
}

function Assert-HostMatrixBrowserCompletion {
    param($Operator,[object[]]$Records,[string[]]$AssetPaths,[object[]]$Calls,[int]$ForbiddenEffects,[switch]$IncludeLaunchDetails,[object[]]$LegacyCalls=@())
    $flags=@('FullDocument','AllScriptsLoaded','BootstrapRendered','AllProviderRowsRendered','HyperVRowsRendered','DeferredVisible',
        'BlockedRowsVisible','ExplicitVariantVisible','SingleProviderProbeEnabled','AllProviderProbeDisabled','SelectionClears','CloseReopenClears','NoScriptErrors')
    if($IncludeLaunchDetails){$flags+=@('LaunchBridgeOpened','LaunchDecisionRendered')}
    Assert-LabHostMatrixHttpShape $Operator (@('Contract')+$flags)
    $version=if($IncludeLaunchDetails){'1.1'}else{'1.0'}
    if($Operator.Contract -cne "SqlServerLab.HostMatrixBrowserOperator/$version") {throw 'HOST_MATRIX_BROWSER_OPERATOR'}
    foreach($name in $flags) {if($Operator.$name -isnot [bool] -or -not $Operator.$name) {throw 'HOST_MATRIX_BROWSER_OPERATOR_FLAG'}}
    if($ForbiddenEffects -ne 0) {throw 'HOST_MATRIX_BROWSER_EFFECTS'}
    foreach($asset in $AssetPaths) {
        if(@($Records | Where-Object {$_.Path -ceq $asset -and $_.Method -ceq 'GET' -and $_.Status -eq 200}).Count -lt 1) {throw 'HOST_MATRIX_BROWSER_MISSING_ASSET'}
    }
    foreach($path in @('/api/config','/api/commands','/api/jobs','/api/workflow','/api/tls-created-targets')) {
        if(@($Records | Where-Object {$_.Path -ceq $path -and $_.Method -ceq 'GET' -and $_.Status -eq 200}).Count -lt 1) {throw 'HOST_MATRIX_BROWSER_MISSING_BOOTSTRAP'}
    }
    $actions=@($Records | Where-Object Path -CEQ '/api/host-capability-matrix');$cases=@(Get-HostMatrixBrowserCases -IncludeLaunchDetails:$IncludeLaunchDetails)
    if($actions.Count -ne $cases.Count -or $Calls.Count -ne $(if($IncludeLaunchDetails){5}else{4})) {throw 'HOST_MATRIX_BROWSER_CALL_COUNT'}
    $callIndex=0
    for($index=0;$index -lt $cases.Count;$index++) {
        $record=$actions[$index];$case=$cases[$index]
        if($record.Method -cne 'POST' -or $record.Status -ne 200) {throw 'HOST_MATRIX_BROWSER_ACTION_STATUS'}
        Assert-HostMatrixBrowserPayload $record.Payload $case
        Assert-HostMatrixBrowserResult $record.View $case
        if($case.Action -ceq 'ReadMatrix') {
            $call=$Calls[$callIndex++];$expected=if($case.Provider -ceq 'all'){'docker,podman,hyperv'}else{$case.Provider}
            if($call.SqlVersion -cne $case.SqlVersion -or ($call.Provider -join ',') -cne $expected -or
                $call.CheckProviderReadiness -isnot [bool] -or $call.CheckProviderReadiness) {throw 'HOST_MATRIX_BROWSER_PUBLIC_SCOPE'}
        }
    }
    $legacy=@($Records|Where-Object Path -CEQ '/api/external-runtime-capability')
    if($legacy.Count -ne $(if($IncludeLaunchDetails){2}else{0}) -or $LegacyCalls.Count -ne $(if($IncludeLaunchDetails){1}else{0})){throw 'HOST_MATRIX_BROWSER_LEGACY_COUNT'}
    if($IncludeLaunchDetails) {
        for($index=0;$index -lt 2;$index++) {
            if($legacy[$index].Method -cne 'POST' -or $legacy[$index].Status -ne 200){throw 'HOST_MATRIX_BROWSER_LEGACY_STATUS'}
            Assert-HostMatrixLaunchBrowserRecord $legacy[$index].Payload $legacy[$index].View $index
        }
        $call=$LegacyCalls[0]
        if($call.SqlVersion -cne '2022' -or $call.Provider -cne 'docker' -or $call.SoftwareId -cne 'sql-python' -or
            $call.RuntimeVersion -cne '3.10' -or $call.VariantId -cne 'sql2022-python310-ubuntu2204-derived' -or
            $call.HostProbe -isnot [bool] -or $call.HostProbe -or $call.History -isnot [bool] -or $call.History){throw 'HOST_MATRIX_BROWSER_LEGACY_PUBLIC_BINDING'}
    }
}
