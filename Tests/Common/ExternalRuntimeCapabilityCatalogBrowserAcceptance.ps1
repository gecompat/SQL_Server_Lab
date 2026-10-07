# Test-only rendered catalogue decisions; actual reader, synthetic page bootstrap.
. (Join-Path $PSScriptRoot ConnectionCenterCmsFullPageAcceptance.ps1)

function Get-ExternalCatalogBrowserCases {
    foreach($choice in @(
        @{Provider='docker';SqlVersion='2019';SoftwareId='sql-java';RuntimeVersion='11';VariantId='sql2022-java11-ubuntu2204-derived';Supported=1;Cgroup='1';Mode='sql2019-namespace-v1'}
        @{Provider='docker';SqlVersion='2022';SoftwareId='sql-python';RuntimeVersion='3.10';VariantId='sql2022-python310-ubuntu2204-derived';Supported=3;Cgroup='1';Mode='sql2022-namespace-v1'}
        @{Provider='podman';SqlVersion='2022';SoftwareId='sql-r';RuntimeVersion='4.2.3';VariantId='sql2022-r42-ubuntu2204-derived';Supported=3;Cgroup='1';Mode='sql2022-namespace-v1'}
        @{Provider='podman';SqlVersion='2025';SoftwareId='sql-java';RuntimeVersion='11';VariantId='sql-java-2025-shared-user-v2';Supported=6;Cgroup='2';Mode='sql2025-shared-user-v2'}
    )){
        foreach($action in @('ReadOptions','Evaluate')){[pscustomobject]@{Action=$action;Provider=$choice.Provider;SqlVersion=$choice.SqlVersion;SoftwareId=$choice.SoftwareId;RuntimeVersion=$choice.RuntimeVersion;VariantId=$choice.VariantId;Supported=$choice.Supported;Cgroup=$choice.Cgroup;Mode=$choice.Mode}}
    }
}

function Get-ExternalCatalogBrowserProductParts {
    param([string]$RepositoryRoot)
    $parts=Get-CmsFullPageProductParts $RepositoryRoot
    $paths=@('Private/VersionCatalog.ps1','Private/SoftwareCatalog.ps1','Private/ContainerImageArtifact.ps1','Private/ExternalRuntimeCapability.ps1','Public/Get-SqlServerLabExternalRuntimeCapability.ps1','Private/ExternalRuntimeCapabilityHttp.ps1','Catalogs/software.json','Catalogs/sql-server-versions.json','Providers/Docker/provider.json','Providers/Podman/provider.json')
    $recipeRoot=Join-Path $RepositoryRoot Images/ExternalLanguages/Linux
    Assert-CmsBrowserPath $recipeRoot
    # Capture all recipe/context/lock inputs before the unchanged recipe reader.
    $directories=[Collections.Generic.Queue[string]]::new();$directories.Enqueue($recipeRoot)
    $recipeFiles=[Collections.Generic.List[object]]::new();$directoryCount=0
    while($directories.Count){
        $directory=$directories.Dequeue();Assert-CmsBrowserPath $directory
        if(++$directoryCount -gt 64){throw 'EXTERNAL_CATALOG_BROWSER_RECIPE_LIMIT'}
        foreach($item in Get-ChildItem -LiteralPath $directory -Force){Assert-CmsBrowserPath $item.FullName;if($item.PSIsContainer){$directories.Enqueue($item.FullName)}else{$recipeFiles.Add($item)}}
    }
    if($recipeFiles.Count -lt 1 -or $recipeFiles.Count -gt 64){throw 'EXTERNAL_CATALOG_BROWSER_RECIPE_LIMIT'}
    $paths+=@($recipeFiles | ForEach-Object {[IO.Path]::GetRelativePath($RepositoryRoot,$_.FullName).Replace('\','/')})
    $sources=@($parts.Sources)+@(foreach($path in $paths){$file=Join-Path $RepositoryRoot $path;Assert-CmsBrowserPath $file;if((Get-Item -LiteralPath $file -Force).Length -gt 256KB){throw 'EXTERNAL_CATALOG_BROWSER_SOURCE_LIMIT'};[pscustomobject]@{Path=$path;Sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}})
    if(@($sources.Path | Sort-Object -Unique).Count -ne $sources.Count){throw 'EXTERNAL_CATALOG_BROWSER_DUPLICATE_SOURCE'}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepositoryRoot Tools/Start-SqlServerLabUi.ps1),[ref]$tokens,[ref]$errors)
    $route=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq "`$path -eq '/api/external-runtime-capability'"},$true))
    if($errors.Count -or $route.Count -ne 1){throw 'EXTERNAL_CATALOG_BROWSER_PRODUCT_ROUTE'}
    [pscustomobject]@{Assets=$parts.Assets;Sources=$sources;Dispatch=[scriptblock]::Create('foreach($iteration in 1){'+$route[0].Extent.Text+"`nthrow 'EXTERNAL_CATALOG_BROWSER_FALLTHROUGH'"+'}')}
}

function New-ExternalCatalogBrowserModule {
    param([string]$RepositoryRoot)
    New-Module -Name SqlServerLab -ArgumentList $RepositoryRoot -ScriptBlock {
        param($repo)
        $script:ModuleRoot=$repo;$script:CatalogsPath=Join-Path $repo Catalogs
        $script:VersionCatalog=Get-Content -LiteralPath (Join-Path $repo Catalogs/sql-server-versions.json) -Raw | ConvertFrom-Json
        $script:RegisteredProviders=@{}
        foreach($provider in @('Docker','Podman')){$definition=Get-Content -LiteralPath (Join-Path $repo ("Providers/$provider/provider.json")) -Raw | ConvertFrom-Json;$script:RegisteredProviders[$definition.name]=@{Definition=$definition}}
        foreach($path in @('Private/VersionCatalog.ps1','Private/SoftwareCatalog.ps1','Private/ContainerImageArtifact.ps1','Private/ExternalRuntimeCapability.ps1','Public/Get-SqlServerLabExternalRuntimeCapability.ps1','Private/ExternalRuntimeCapabilityHttp.ps1')){. (Join-Path $repo $path)}
        $script:BrowserOriginalPublic=(Get-Command Get-SqlServerLabExternalRuntimeCapability).ScriptBlock
        $script:BrowserCalls=[Collections.Generic.List[object]]::new();$script:BrowserEffects=0
        function Get-SqlServerLabExternalRuntimeCapability {
            param($SqlVersion,$Provider,$OperatingSystem,$SoftwareId,$RuntimeVersion,$VariantId,[switch]$CheckProviderReadiness,[switch]$IncludeRecordedEvidence)
            if($CheckProviderReadiness -or $IncludeRecordedEvidence){$script:BrowserEffects++;throw 'EXTERNAL_CATALOG_BROWSER_OPTIN_FORBIDDEN'}
            $script:BrowserCalls.Add([pscustomobject]@{SqlVersion=$SqlVersion;Provider=$Provider;OperatingSystem=$OperatingSystem;SoftwareId=$SoftwareId;RuntimeVersion=$RuntimeVersion;VariantId=$VariantId;CheckProviderReadiness=[bool]$CheckProviderReadiness;IncludeRecordedEvidence=[bool]$IncludeRecordedEvidence})
            & $script:BrowserOriginalPublic @PSBoundParameters
        }
        foreach($name in @('Read-LabExternalRuntimeHostFacts','Invoke-LabExternalRuntimeInfoProcess','Initialize-LabHostToolPath','Invoke-LabDiagnosticBoundedProcess','Get-LabExternalRuntimeRecordedEvidence','Invoke-Sqlcmd','Start-Process','Get-VM','Get-LabStateRoot','Get-LabDataRoot','Get-LabRunState','Write-LabEvent','New-LabRunState','Get-LabSecret','Get-LabPreferencesSnapshot','Invoke-LabContainerCli','Invoke-SqlServerLabWorkflowAction','Invoke-LabExternalRuntimeImageBuild')){Set-Item ("Function:script:$name") {$script:BrowserEffects++;throw 'EXTERNAL_CATALOG_BROWSER_FORBIDDEN_EFFECT'}}
    }
}

function Assert-ExternalCatalogBrowserPayload {
    param($Payload,$Case)
    $names=@('Action','SqlVersion','Provider','OperatingSystem')
    if($Case.Action -ceq 'Evaluate'){$names+=@('SoftwareId','RuntimeVersion','VariantId','CheckProviderReadiness')}
    if($Payload -isnot [pscustomobject] -or @($Payload.PSObject.Properties.Name).Count -ne $names.Count -or @($Payload.PSObject.Properties.Name | Where-Object {$_ -cnotin $names}).Count){throw 'EXTERNAL_CATALOG_BROWSER_PAYLOAD'}
    foreach($name in @('Action','SqlVersion','Provider')){if($Payload.$name -isnot [string] -or $Payload.$name -cne $Case.$name){throw 'EXTERNAL_CATALOG_BROWSER_SEQUENCE'}}
    if($Payload.OperatingSystem -isnot [string] -or $Payload.OperatingSystem -cne 'linux'){throw 'EXTERNAL_CATALOG_BROWSER_SEQUENCE'}
    if($Case.Action -ceq 'Evaluate'){
        foreach($name in @('SoftwareId','RuntimeVersion','VariantId')){if($Payload.$name -isnot [string] -or $Payload.$name -cne $Case.$name){throw 'EXTERNAL_CATALOG_BROWSER_IDENTITY'}}
        if($Payload.CheckProviderReadiness -isnot [bool] -or $Payload.CheckProviderReadiness){throw 'EXTERNAL_CATALOG_BROWSER_HOST_FORBIDDEN'}
    }
}

function Assert-ExternalCatalogBrowserResult {
    param($Module,$Result,$Case)
    & $Module {
        param($result,$case)
        $names=if($case.Action -ceq 'ReadOptions'){@('ContractVersion','Status','Options')}else{@('ContractVersion','Status','Decision')}
        Assert-LabExternalRuntimeHttpShape $result $names
        if($result.ContractVersion -cne 'SqlServerLab.ExternalRuntimeCapabilityBrowser/1.0' -or $result.Status -cne $(if($case.Action -ceq 'ReadOptions'){'OPTIONS'}else{'DECISION'})){throw 'EXTERNAL_CATALOG_BROWSER_RESULT'}
        $decisions=if($case.Action -ceq 'ReadOptions'){
            if($result.Options -isnot [array] -or $result.Options.Count -ne 9 -or @($result.Options | Where-Object {$_.Decision.CatalogDecision.Status -ceq 'DECLARED_SUPPORTED'}).Count -ne $case.Supported){throw 'EXTERNAL_CATALOG_BROWSER_OPTIONS'}
            $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach($option in $result.Options){Assert-LabExternalRuntimeHttpShape $option @('SoftwareId','Language','VariantId','RuntimeVersion','Decision');Assert-LabExternalRuntimeHttpIdentity $option;if(-not $seen.Add($option.VariantId)){throw 'EXTERNAL_CATALOG_BROWSER_DUPLICATE_OPTION'};if($option.Decision.Identity -and ($option.Decision.Identity.SoftwareId -cne $option.SoftwareId -or $option.Decision.Identity.VariantId -cne $option.VariantId -or $option.Decision.Identity.RuntimeVersion -cne $option.RuntimeVersion)){throw 'EXTERNAL_CATALOG_BROWSER_OPTION_BINDING'};$option.Decision}
        }else{
            if($result.Decision.CatalogDecision.Status -cne 'DECLARED_SUPPORTED' -or $result.Decision.Identity.SoftwareId -cne $case.SoftwareId -or $result.Decision.Identity.VariantId -cne $case.VariantId -or $result.Decision.Identity.RuntimeVersion -cne $case.RuntimeVersion -or $result.Decision.CurrentReadiness.RequiredCgroupVersion -cne $case.Cgroup -or $result.Decision.CurrentReadiness.LaunchMode -cne $case.Mode){throw 'EXTERNAL_CATALOG_BROWSER_DECISION'}
            $result.Decision
        }
        foreach($decision in $decisions){Assert-LabExternalRuntimeHttpDecision $decision;if($decision.Provider -cne $case.Provider -or $decision.CurrentReadiness.Status -cne 'NOT_CHECKED' -or ($decision.Identity -and $decision.Identity.SqlVersion -cne $case.SqlVersion)){throw 'EXTERNAL_CATALOG_BROWSER_READINESS'}}
    } $Result $Case
}

function Assert-ExternalCatalogBrowserCompletion {
    param($Module,$Operator,[object[]]$Records,[string[]]$AssetPaths,[object[]]$Calls,[int]$ForbiddenEffects)
    $flags=@('FullDocument','AllScriptsLoaded','BootstrapRendered','NavigationToCreate','OpenEditNoAction','OptionsRendered','BlockedOptionsDisabled','DecisionsRendered','Explicit2025Variant','HostNotExecuted','ReopenClearsOutput','NoScriptErrors','DialogClosed')
    if($Operator -isnot [pscustomobject] -or $Operator.Contract -cne 'SqlServerLab.ExternalCatalogBrowserOperator/1.0' -or @($Operator.PSObject.Properties.Name).Count -ne $flags.Count+1 -or @($Operator.PSObject.Properties.Name | Where-Object {$_ -cnotin (@('Contract')+$flags)}).Count){throw 'EXTERNAL_CATALOG_BROWSER_OPERATOR'}
    foreach($name in $flags){if($Operator.$name -isnot [bool] -or -not $Operator.$name){throw 'EXTERNAL_CATALOG_BROWSER_OPERATOR'}}
    if($AssetPaths.Count -ne 12 -or @($AssetPaths | Sort-Object -Unique).Count -ne 12 -or $Records.Count -gt 512 -or $ForbiddenEffects -ne 0){throw 'EXTERNAL_CATALOG_BROWSER_BOUNDARY'}
    $bootstrap=@('/api/config','/api/commands','/api/workflow','/api/jobs');$allowed=@($AssetPaths)+$bootstrap+@('/api/external-runtime-capability','/favicon.ico')
    foreach($row in $Records){if($row.Path -cnotin $allowed -or $row.Status -ne $(if($row.Path -ceq '/favicon.ico'){204}else{200}) -or $row.Method -cne $(if($row.Path -ceq '/api/external-runtime-capability'){'POST'}else{'GET'}) -or $row.Transport -cne 'SENT'){throw 'EXTERNAL_CATALOG_BROWSER_REQUEST'}}
    foreach($path in $AssetPaths){if(@($Records | Where-Object Path -CEQ $path).Count -ne 1){throw 'EXTERNAL_CATALOG_BROWSER_ASSET'}}
    foreach($path in $bootstrap){if(@($Records | Where-Object Path -CEQ $path).Count -lt $(if($path -ceq '/api/jobs'){2}else{1})){throw 'EXTERNAL_CATALOG_BROWSER_BOOTSTRAP'}}
    $requests=@($Records | Where-Object Path -CEQ '/api/external-runtime-capability');$cases=@(Get-ExternalCatalogBrowserCases);$evaluations=@($cases | Where-Object Action -CEQ Evaluate)
    if($requests.Count -ne 8 -or $Calls.Count -ne 4){throw 'EXTERNAL_CATALOG_BROWSER_ACTION_COUNT'}
    for($i=0;$i -lt $cases.Count;$i++){Assert-ExternalCatalogBrowserPayload $requests[$i].Payload $cases[$i];Assert-ExternalCatalogBrowserResult $Module $requests[$i].Result $cases[$i];if($requests[$i].PublicCalls -ne $(if($cases[$i].Action -ceq 'Evaluate'){1}else{0})){throw 'EXTERNAL_CATALOG_BROWSER_PUBLIC_COUNT'}}
    for($i=0;$i -lt $evaluations.Count;$i++){foreach($name in @('SqlVersion','Provider','SoftwareId','RuntimeVersion','VariantId')){if($Calls[$i].$name -cne $evaluations[$i].$name){throw 'EXTERNAL_CATALOG_BROWSER_PUBLIC_BINDING'}};if($Calls[$i].OperatingSystem -cne 'linux' -or $Calls[$i].CheckProviderReadiness -isnot [bool] -or $Calls[$i].CheckProviderReadiness -or $Calls[$i].IncludeRecordedEvidence -isnot [bool] -or $Calls[$i].IncludeRecordedEvidence){throw 'EXTERNAL_CATALOG_BROWSER_PUBLIC_OPTIN'}}
}
