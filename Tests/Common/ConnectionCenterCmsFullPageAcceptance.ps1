# Test-only full-document bootstrap with fixed synthetic HTTP reads.
. (Join-Path $PSScriptRoot ConnectionCenterCmsInspectionBrowserAcceptance.ps1)

function Get-CmsFullPageProductParts {
    param([string]$RepositoryRoot)
    $index=Join-Path $RepositoryRoot Ui/index.html
    Assert-CmsBrowserPath $index
    $html=Get-Content -LiteralPath $index -Raw
    $scripts=@([regex]::Matches($html,'<script\s+src="([^"]+)"')|ForEach-Object {$_.Groups[1].Value})
    if($scripts.Count -lt 1 -or @($scripts|Where-Object {$_ -cnotmatch '^[a-z][a-z0-9-]{0,63}\.js$'}).Count -or @($scripts|Sort-Object -Unique).Count -ne $scripts.Count -or ([regex]::Matches($html,'href="app\.css"')).Count -ne 1){throw 'CMS_FULL_PAGE_ASSET_DECLARATION'}
    $paths=@('Ui/index.html','Ui/app.css')+@($scripts|ForEach-Object {'Ui/'+$_})+@('Tools/Start-SqlServerLabUi.ps1')
    $assets=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $sources=@(foreach($path in $paths){
        $file=Join-Path $RepositoryRoot $path;Assert-CmsBrowserPath $file
        if((Get-Item -LiteralPath $file).Length -gt 256KB){throw 'CMS_FULL_PAGE_ASSET_LIMIT'}
        $bytes=[IO.File]::ReadAllBytes($file)
        $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        if($path.StartsWith('Ui/',[StringComparison]::Ordinal)){
            $uri=if($path -ceq 'Ui/index.html'){'/'}else{'/'+$path.Substring(3)}
            $mime=if($path.EndsWith('.html')){'text/html; charset=utf-8'}elseif($path.EndsWith('.css')){'text/css; charset=utf-8'}else{'application/javascript; charset=utf-8'}
            $assets.Add($uri,[pscustomobject]@{Bytes=$bytes;ContentType=$mime})
        }
        [pscustomobject]@{Path=$path;Sha256=$sha}
    })
    $parts=Get-CmsBrowserProductParts $RepositoryRoot
    foreach($source in $sources){if((Get-FileHash -LiteralPath (Join-Path $RepositoryRoot $source.Path)).Hash -cne $source.Sha256){throw 'CMS_FULL_PAGE_SOURCE_DRIFT'}}
    # Bind discovery itself to the captured document, as well as the served bytes.
    if([Text.UTF8Encoding]::new($false,$true).GetString($assets['/'].Bytes).TrimStart([char]0xfeff) -cne $html.TrimStart([char]0xfeff)){throw 'CMS_FULL_PAGE_DOCUMENT_DRIFT'}
    [pscustomobject]@{Assets=$assets;Sources=$sources;Adapter=$parts.Adapter;Dispatch=$parts.Dispatch}
}

function Get-CmsFullPageBootstrapResponse {
    param([string]$Path)
    if($Path -cin @('/api/jobs','/api/commands')){return '[]'}
    if($Path -ceq '/api/config'){return '{"jobLogBurstLimit":20,"aiSharedGatewayServiceSecret":{"available":false,"reason":"SYNTHETIC_ONLY_NO_SECRET_ACCESS"}}'}
    if($Path -cne '/api/workflow'){throw 'CMS_FULL_PAGE_BOOTSTRAP_PATH'}
    $view=[ordered]@{
        Host=@{IsElevated=$false;HyperV=@{Supported=$true;Available=$false;Message='Synthetische Browserabnahme: keine Providerprobe ausgeführt.'}}
        Summary=@{WindowsBaselines=0;SqlPreparedImages=0;TemplatePoolUsed=0;TemplatePoolCapacity=20;PendingWindowsBuilds=0;PendingSqlBuilds=0;ActiveContainerLabs=0;RunningWorkers=0;WaitingUserGates=0;QueueLength=0}
        Defaults=@{};Queue=@{items=@();runningWorkers=0;maxWorkers=2}
    }
    foreach($name in @('WindowsBuilds','SqlBuilds','WindowsBaselines','SqlPreparedImages','AcceptanceEnvironments','ActiveLabs','HyperVLabs','HyperVSwitches','HyperVExistingVmSources','MediaSources','DatabasePackageLibrary','HyperVPersistentDataCandidates','RetainedStoreRemovalCandidates','SqlInstallationMedia','WindowsInstallationMedia')){$view[$name]=@()}
    $view|ConvertTo-Json -Depth 6 -Compress
}

function Assert-CmsFullPageCompletion {
    param($Operator,[object[]]$Records,[string[]]$AssetPaths)
    $flags=@('FullDocument','AllScriptsLoaded','BootstrapRendered','NavigationToCms','InitialReadOnly','ExplicitInspection','GenuineZero','NoScriptErrors','DialogClosed')
    if($Operator -isnot [pscustomobject] -or $Operator.Contract -cne 'SqlServerLab.CmsFullPageOperator/1.0' -or @($Operator.PSObject.Properties.Name).Count -ne 10 -or @($Operator.PSObject.Properties.Name|Where-Object {$_ -cnotin (@('Contract')+$flags)}).Count){throw 'CMS_FULL_PAGE_OPERATOR_INVALID'}
    foreach($name in $flags){if($Operator.$name -isnot [bool] -or -not $Operator.$name){throw 'CMS_FULL_PAGE_OPERATOR_INVALID'}}
    $allowed=@($AssetPaths)+@('/api/config','/api/commands','/api/workflow','/api/jobs','/api/cms-inspection','/favicon.ico')
    if(@($Records|Where-Object {$_.Path -cnotin $allowed -or $_.Status -ne $(if($_.Path -ceq '/favicon.ico'){204}else{200}) -or ($_.Method -cne 'GET' -and $_.Path -cne '/api/cms-inspection')}).Count -or $Records.Count -gt 512){throw 'CMS_FULL_PAGE_REQUEST_INVALID'}
    foreach($path in $AssetPaths){if(@($Records|Where-Object {$_.Path -ceq $path -and $_.Method -ceq 'GET' -and $_.Status -eq 200}).Count -ne 1){throw 'CMS_FULL_PAGE_ASSET_MISSING_OR_DUPLICATE'}}
    foreach($path in @('/api/config','/api/commands','/api/workflow','/api/jobs')){if(@($Records|Where-Object Path -CEQ $path).Count -lt $(if($path -ceq '/api/jobs'){2}else{1})){throw 'CMS_FULL_PAGE_BOOTSTRAP_MISSING'}}
    $cms=@($Records|Where-Object Path -CEQ '/api/cms-inspection')
    if($cms.Count -ne 2 -or ($cms.Action -join '|') -cne 'GetCmsInspectionState|InspectCms' -or ($cms.Method -join '|') -cne 'GET|POST'){throw 'CMS_FULL_PAGE_CMS_SEQUENCE'}
}
