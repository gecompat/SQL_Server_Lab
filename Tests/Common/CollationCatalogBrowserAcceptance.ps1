# Test-only rendered search: actual public catalogue, synthetic page bootstrap.
. (Join-Path $PSScriptRoot ConnectionCenterCmsFullPageAcceptance.ps1)

function Get-CollationBrowserCases {
    @(
        [pscustomobject]@{SqlVersion='2025';Query='Latin1 UTF8';Count=1;Name='Latin1_General_100_CI_AS_SC_UTF8';Status='SUPPORTED'}
        [pscustomobject]@{SqlVersion='2019';Query='SQL_Latin1';Count=1;Name='SQL_Latin1_General_CP1_CI_AS';Status='DEPRECATED'}
        [pscustomobject]@{SqlVersion='2022';Query='NO_SUCH_COLLATION_FIXTURE';Count=0;Name=$null;Status=$null}
        [pscustomobject]@{SqlVersion='2019';Query='日本語';Count=6;Name=$null;Status=$null}
        [pscustomobject]@{SqlVersion='2022';Query='';Count=6;Name=$null;Status=$null}
        [pscustomobject]@{SqlVersion='2025';Query='Latin1 UTF8';Count=1;Name='Latin1_General_100_CI_AS_SC_UTF8';Status='SUPPORTED'}
    )
}

function Get-CollationBrowserProductParts {
    param([string]$RepositoryRoot)
    $parts=Get-CmsFullPageProductParts $RepositoryRoot
    $paths=@('Private/CollationCatalog.ps1','Private/CollationCatalogHttp.ps1','Public/Find-SqlServerLabCollation.ps1','Catalogs/sql-server-collations.json','Schemas/sql-server-collation-catalog.schema.json')
    $sources=@($parts.Sources)+@(foreach($path in $paths){$file=Join-Path $RepositoryRoot $path;Assert-CmsBrowserPath $file;[pscustomobject]@{Path=$path;Sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}})
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepositoryRoot Tools/Start-SqlServerLabUi.ps1),[ref]$tokens,[ref]$errors)
    $route=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq "`$path -eq '/api/collations/search'"},$true))
    if($errors.Count -or $route.Count -ne 1){throw 'COLLATION_BROWSER_PRODUCT_ROUTE'}
    [pscustomobject]@{Assets=$parts.Assets;Sources=$sources;Dispatch=[scriptblock]::Create('foreach($iteration in 1){'+$route[0].Extent.Text+"`nthrow 'COLLATION_BROWSER_FALLTHROUGH'"+'}')}
}

function New-CollationBrowserModule {
    param([string]$RepositoryRoot)
    New-Module -Name SqlServerLab -ArgumentList $RepositoryRoot -ScriptBlock {
        param($repo)
        $script:CatalogsPath=Join-Path $repo Catalogs;$script:SchemasPath=Join-Path $repo Schemas
        foreach($path in @('Private/CollationCatalog.ps1','Private/CollationCatalogHttp.ps1','Public/Find-SqlServerLabCollation.ps1')){. (Join-Path $repo $path)}
        $script:BrowserOriginalPublic=(Get-Command Find-SqlServerLabCollation).ScriptBlock
        $script:BrowserCalls=[Collections.Generic.List[object]]::new();$script:BrowserEffects=0
        function Find-SqlServerLabCollation {
            param($Query,$SqlVersion)
            $script:BrowserCalls.Add([pscustomobject]@{SqlVersion=$SqlVersion;Query=$Query})
            & $script:BrowserOriginalPublic @PSBoundParameters
        }
        foreach($name in @('Invoke-Sqlcmd','Start-Process','Get-VM','Get-LabStateRoot','Get-LabDataRoot','Get-LabRunState','Write-LabEvent','New-LabRunState','Get-LabSecret','Get-LabPreferencesSnapshot','Initialize-LabHostToolPath','Invoke-LabDiagnosticBoundedProcess','Invoke-LabContainerCli','Invoke-SqlServerLabWorkflowAction')){
            Set-Item ("Function:script:$name") {$script:BrowserEffects++;throw 'COLLATION_BROWSER_FORBIDDEN_EFFECT'}
        }
    }
}

function Assert-CollationBrowserResult {
    param($Result,$Case)
    Assert-LabCollationHttpShape $Result @('Contract','SqlVersion','Status','Results','ReturnedCount','Truncated','SqlValidation','ExecutionSupported','MutationAllowed','Actions')
    Assert-LabCollationHttpShape $Result.Contract @('Name','Version')
    if($Result.Contract.Name -cne 'SqlServerLab.CollationCatalogueSearch' -or $Result.Contract.Version -cne '1.0' -or
        $Result.SqlVersion -cne $Case.SqlVersion -or $Result.Status -cne $(if($Case.Count){'MATCHES'}else{'NO_MATCHES'}) -or
        ($Result.ReturnedCount -isnot [int] -and $Result.ReturnedCount -isnot [long]) -or $Result.ReturnedCount -ne $Case.Count -or $Result.Results -isnot [array] -or $Result.Results.Count -ne $Case.Count -or
        $Result.Truncated -isnot [bool] -or $Result.Truncated -or $Result.SqlValidation -cne 'NOT_CHECKED' -or
        $Result.ExecutionSupported -isnot [bool] -or $Result.ExecutionSupported -or $Result.MutationAllowed -isnot [bool] -or $Result.MutationAllowed -or
        $Result.Actions -isnot [array] -or $Result.Actions.Count){throw 'COLLATION_BROWSER_RESULT'}
    foreach($row in @($Result.Results)){
        # JSON numbers may be Int64 after transport; accept integers within the
        # product Int32 bounds without accepting strings, booleans or fractions.
        foreach($field in @('CodePage','Lcid')){if(($row.$field -isnot [int] -and $row.$field -isnot [long]) -or $row.$field -lt 0 -or $row.$field -gt [int]::MaxValue){throw 'COLLATION_BROWSER_ROW_INTEGER'}}
        $normalized=$row | Select-Object *;$normalized.CodePage=[int]$row.CodePage;$normalized.Lcid=[int]$row.Lcid
        Assert-LabCollationHttpRow $normalized $Case.SqlVersion
    }
    if($Case.Name -and ($Result.Results[0].Name -cne $Case.Name -or $Result.Results[0].Status -cne $Case.Status)){throw 'COLLATION_BROWSER_EXPECTED_ROW'}
}

function Assert-CollationBrowserCompletion {
    param($Operator,[object[]]$Records,[string[]]$AssetPaths,[object[]]$Calls,[int]$ForbiddenEffects)
    $flags=@('FullDocument','AllScriptsLoaded','BootstrapRendered','NavigationToCreate','OpenEditNoSearch','MatchesRendered','DeprecatedRendered','NoMatchesRendered','ZeroTokensRendered','ReopenClears','NoScriptErrors','DialogClosed')
    if($Operator -isnot [pscustomobject] -or $Operator.Contract -cne 'SqlServerLab.CollationBrowserOperator/1.0' -or @($Operator.PSObject.Properties.Name).Count -ne $flags.Count+1 -or @($Operator.PSObject.Properties.Name | Where-Object {$_ -cnotin (@('Contract')+$flags)}).Count){throw 'COLLATION_BROWSER_OPERATOR'}
    foreach($name in $flags){if($Operator.$name -isnot [bool] -or -not $Operator.$name){throw 'COLLATION_BROWSER_OPERATOR'}}
    if($AssetPaths.Count -ne 12 -or @($AssetPaths | Sort-Object -Unique).Count -ne 12 -or $Records.Count -gt 512 -or $ForbiddenEffects -ne 0){throw 'COLLATION_BROWSER_BOUNDARY'}
    $bootstrap=@('/api/config','/api/commands','/api/workflow','/api/jobs')
    $allowed=@($AssetPaths)+$bootstrap+@('/api/collations/search','/favicon.ico')
    foreach($row in $Records){
        if($row.Path -cnotin $allowed -or $row.Status -ne $(if($row.Path -ceq '/favicon.ico'){204}else{200}) -or $row.Method -cne $(if($row.Path -ceq '/api/collations/search'){'POST'}else{'GET'}) -or $row.Transport -cne 'SENT'){throw 'COLLATION_BROWSER_REQUEST'}
    }
    foreach($path in $AssetPaths){if(@($Records | Where-Object Path -CEQ $path).Count -ne 1){throw 'COLLATION_BROWSER_ASSET'}}
    foreach($path in $bootstrap){if(@($Records | Where-Object Path -CEQ $path).Count -lt $(if($path -ceq '/api/jobs'){2}else{1})){throw 'COLLATION_BROWSER_BOOTSTRAP'}}
    $searches=@($Records | Where-Object Path -CEQ '/api/collations/search');$cases=@(Get-CollationBrowserCases)
    if($searches.Count -ne $cases.Count -or $Calls.Count -ne $cases.Count){throw 'COLLATION_BROWSER_SEARCH_COUNT'}
    for($i=0;$i -lt $cases.Count;$i++){
        if($Calls[$i].SqlVersion -cne $cases[$i].SqlVersion -or $Calls[$i].Query -cne $cases[$i].Query -or $searches[$i].PublicCalls -ne 1){throw 'COLLATION_BROWSER_SEARCH_SEQUENCE'}
        Assert-CollationBrowserResult $searches[$i].Result $cases[$i]
    }
}
