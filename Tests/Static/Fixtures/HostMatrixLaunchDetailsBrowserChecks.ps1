$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo Tests/Common/HostCapabilityMatrixBrowserAcceptance.ps1)
. (Join-Path $repo Private/HostCapabilityMatrixHttp.ps1)
$parts=Get-HostMatrixBrowserProductParts $repo -IncludeLaunchDetails
$module=New-HostMatrixBrowserModule $repo -IncludeLaunchDetails
$script:checks=0;$script:response=$null
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw "HOST_LAUNCH_BROWSER_FIXTURE: $Name"};$script:checks++}
function Reject([scriptblock]$Body,[string]$Name){$caught=$false;try{& $Body}catch{$caught=$true};Check $caught $Name}
function Copy-Record($Value){$Value|ConvertTo-Json -Depth 25|ConvertFrom-Json -Depth 25}
function Get-Module {param($Name) if($Name -cne 'SqlServerLab'){throw 'UNEXPECTED_MODULE'};$module}
function Write-UiResponse {param($Context,$Body,$ContentType,[int]$StatusCode=200) $Context.Response.StatusCode=$StatusCode;$script:response=$Body}
function Invoke-Dispatch($Payload,[bool]$Legacy) {
    $path=if($Legacy){'/api/external-runtime-capability'}else{'/api/host-capability-matrix'}
    $request=[pscustomobject]@{HttpMethod='POST';ContentType='application/json';Headers=@{Origin='http://127.0.0.1:8484'};Url=[uri]("http://127.0.0.1:8484"+$path);
        LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,8484);InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(($Payload|ConvertTo-Json -Compress)))}
    $context=[pscustomobject]@{Request=$request;Response=[pscustomobject]@{StatusCode=0}};$Port=8484
    try {if($Legacy){& $parts.LegacyDispatch}else{& $parts.Dispatch}}finally{$request.InputStream.Dispose()}
    Check ($context.Response.StatusCode -eq 200) 'actual selected product dispatch returns a closed successful view'
    [pscustomobject]@{Path=$path;Method='POST';Status=$context.Response.StatusCode;Payload=$Payload;View=($script:response|ConvertFrom-Json -Depth 20)}
}
try {
    Assert-HostMatrixBrowserSources $repo $parts.Sources
    Check ($null -ne $parts.LegacyDispatch -and $parts.Sources.Count -gt 34 -and $parts.Assets.Count -eq 17) 'composed actual route, catalogue, recipe and all-asset bindings'
    $records=@(foreach($path in @($parts.Assets.Keys)+@('/api/config','/api/commands','/api/jobs','/api/workflow','/api/tls-created-targets')){[pscustomobject]@{Path=$path;Method='GET';Status=200;Payload=$null;View=$null}})
    foreach($case in @(Get-HostMatrixBrowserCases -IncludeLaunchDetails)) {
        $payload=if($case.Action -ceq 'ReadVersions'){[pscustomobject]@{Action='ReadVersions'}}else{[pscustomobject]@{Action='ReadMatrix';SqlVersion=$case.SqlVersion;Provider=$case.Provider;CheckProviderReadiness=$false}}
        $records+=@(Invoke-Dispatch $payload $false)
    }
    $read=[pscustomobject]@{Action='ReadOptions';SqlVersion='2022';Provider='docker';OperatingSystem='linux'}
    $evaluate=[pscustomobject]@{Action='Evaluate';SqlVersion='2022';Provider='docker';OperatingSystem='linux';SoftwareId='sql-python';RuntimeVersion='3.10';VariantId='sql2022-python310-ubuntu2204-derived';CheckProviderReadiness=$false}
    $records+=@(Invoke-Dispatch $read $true);$records+=@(Invoke-Dispatch $evaluate $true)
    $operator=[ordered]@{Contract='SqlServerLab.HostMatrixBrowserOperator/1.1'}
    foreach($flag in @('FullDocument','AllScriptsLoaded','BootstrapRendered','AllProviderRowsRendered','HyperVRowsRendered','DeferredVisible','BlockedRowsVisible','ExplicitVariantVisible','SingleProviderProbeEnabled','AllProviderProbeDisabled','SelectionClears','CloseReopenClears','NoScriptErrors','LaunchBridgeOpened','LaunchDecisionRendered')){$operator[$flag]=$true}
    $operator=[pscustomobject]$operator;$calls=@(& $module {@($script:BrowserCalls)});$legacy=@(& $module {@($script:BrowserLegacyCalls)})
    Assert-HostMatrixBrowserCompletion $operator $records @($parts.Assets.Keys) $calls 0 -IncludeLaunchDetails -LegacyCalls $legacy
    Check ($calls.Count -eq 5 -and $legacy.Count -eq 1 -and (& $module {$script:BrowserEffects}) -eq 0) 'actual public readers compose with no host/history/state/SQL work'
    $copy=Copy-Record $operator;$copy.LaunchBridgeOpened=$false
    Reject {Assert-HostMatrixBrowserCompletion $copy $records @($parts.Assets.Keys) $calls 0 -IncludeLaunchDetails -LegacyCalls $legacy} 'missing visible bridge proof vetoes completion'
    Reject {Assert-HostMatrixBrowserCompletion $operator $records @($parts.Assets.Keys) $calls 0 -IncludeLaunchDetails -LegacyCalls @()} 'missing actual detailed public call vetoes completion'
    $copy=Copy-Record $legacy;$copy[0].VariantId='other'
    Reject {Assert-HostMatrixBrowserCompletion $operator $records @($parts.Assets.Keys) $calls 0 -IncludeLaunchDetails -LegacyCalls $copy} 'detailed public tuple mismatch vetoes completion'
    $copy=Copy-Record $records;@($copy|Where-Object Path -CEQ '/api/external-runtime-capability')[1].Payload.CheckProviderReadiness=$true
    Reject {Assert-HostMatrixBrowserCompletion $operator $copy @($parts.Assets.Keys) $calls 0 -IncludeLaunchDetails -LegacyCalls $legacy} 'hidden native opt-in vetoes rendered metadata-only proof'
    [pscustomobject]@{Passed=$script:checks;Assets=$parts.Assets.Count;Sources=$parts.Sources.Count;MatrixPublicCalls=$calls.Count;DetailedPublicCalls=$legacy.Count;ForbiddenEffects=0;RenderedBrowser='NOT_EXECUTED'}|ConvertTo-Json -Compress
} finally {Remove-Module $module -Force -ErrorAction SilentlyContinue}
