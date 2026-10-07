$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo Tests/Common/ExternalRuntimeCapabilityCatalogBrowserAcceptance.ps1)
$parts=Get-ExternalCatalogBrowserProductParts $repo
$module=New-ExternalCatalogBrowserModule $repo
$checks=0
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw "EXTERNAL_CATALOG_BROWSER_FIXTURE: $Name"};$script:checks++}
function Reject([scriptblock]$Body,[string]$Name){$failed=$false;try{& $Body}catch{$failed=$true};Check $failed $Name}
function Copy-Observation($Value){$Value | ConvertTo-Json -Depth 16 | ConvertFrom-Json -Depth 16}
Check ($parts.Assets.Count -eq 12 -and $parts.Sources.Count -gt 23) 'actual page/catalogue/recipe bindings'
$hidden=@($parts.Sources|Where-Object Path -CEQ 'Images/ExternalLanguages/Linux/.dockerignore')
Check ($hidden.Count -eq 1) 'hidden recipe context input included'
Check ($hidden[0].Sha256 -ceq [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes((Join-Path $repo 'Images/ExternalLanguages/Linux/.dockerignore'))))) 'hidden input exact byte binding'
foreach($path in @('Tests/Common/ExternalRuntimeCapabilityCatalogBrowserAcceptance.ps1','Tests/Integration/Invoke-ExternalRuntimeCapabilityCatalogBrowserAcceptance.ps1','Tests/Static/Fixtures/ExternalRuntimeCapabilityCatalogBrowserAcceptanceChecks.ps1')){
    foreach($candidate in @($path,$path.Replace('/','\'))){
        $selection=& (Join-Path $repo Tools/Get-CiTestSelection.ps1) -ChangedPath $candidate
        Check ($selection.StaticChecks -contains 'Invoke-ExternalRuntimeCapabilityBrowserChecks.ps1' -and -not ($selection.Docker -or $selection.Podman -or $selection.Mixed -or $selection.HyperV -or $selection.Adapter)) ('single-path suite selection '+$candidate)
    }
}
$records=@(foreach($path in $parts.Assets.Keys){[pscustomobject]@{Path=$path;Method='GET';Status=200;Transport='SENT';PublicCalls=0;Payload=$null;Result=$null}})
$records+=@(foreach($path in @('/api/config','/api/commands','/api/workflow','/api/jobs','/api/jobs')){[pscustomobject]@{Path=$path;Method='GET';Status=200;Transport='SENT';PublicCalls=0;Payload=$null;Result=$null}})
$cases=@(Get-ExternalCatalogBrowserCases)
foreach($case in $cases){
    $payload=[ordered]@{Action=$case.Action;SqlVersion=$case.SqlVersion;Provider=$case.Provider;OperatingSystem='linux'}
    if($case.Action -ceq 'Evaluate'){foreach($name in @('SoftwareId','RuntimeVersion','VariantId')){$payload[$name]=$case.$name};$payload.CheckProviderReadiness=$false}
    $body=$payload | ConvertTo-Json -Compress
    $transportedPayload=$body | ConvertFrom-Json
    Assert-ExternalCatalogBrowserPayload $transportedPayload $case
    $stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($body),$false)
    $request=[pscustomobject]@{HttpMethod='POST';ContentType='application/json; charset=utf-8';Headers=@{Origin='http://127.0.0.1:19547'};Url=[uri]'http://127.0.0.1:19547/api/external-runtime-capability';LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,19547);InputStream=$stream}
    $before=& $module {$script:BrowserCalls.Count}
    try{$result=& $module {param($request) Invoke-LabExternalRuntimeCapabilityHttpRequest -Request $request -ListenerPort 19547} $request}finally{$stream.Dispose()}
    $transported=Copy-Observation $result
    Assert-ExternalCatalogBrowserResult $module $transported $case
    $count=(& $module {$script:BrowserCalls.Count})-$before
    Check ($count -eq $(if($case.Action -ceq 'Evaluate'){1}else{0})) ('actual '+$case.Action+' '+$case.Provider+' '+$case.SqlVersion)
    $records+=[pscustomobject]@{Path='/api/external-runtime-capability';Method='POST';Status=200;Transport='SENT';PublicCalls=$count;Payload=$transportedPayload;Result=$transported}
}
$calls=@(& $module {@($script:BrowserCalls)})
$flags=@('FullDocument','AllScriptsLoaded','BootstrapRendered','NavigationToCreate','OpenEditNoAction','OptionsRendered','BlockedOptionsDisabled','DecisionsRendered','Explicit2025Variant','HostNotExecuted','ReopenClearsOutput','NoScriptErrors','DialogClosed')
$operator=[pscustomobject]@{Contract='SqlServerLab.ExternalCatalogBrowserOperator/1.0'}
foreach($name in $flags){$operator | Add-Member NoteProperty $name $true}
Assert-ExternalCatalogBrowserCompletion $module $operator $records @($parts.Assets.Keys) $calls 0
Check ((& $module {$script:BrowserEffects}) -eq 0 -and $calls.Count -eq 4) 'actual public calls and zero forbidden effects'
foreach($flag in $flags){$bad=Copy-Observation $operator;$bad.$flag=$false;Reject {Assert-ExternalCatalogBrowserCompletion $module $bad $records @($parts.Assets.Keys) $calls 0} ('operator '+$flag)}
$bad=Copy-Observation $operator;$bad.HostNotExecuted='true';Reject {Assert-ExternalCatalogBrowserCompletion $module $bad $records @($parts.Assets.Keys) $calls 0} 'strict operator boolean'
$bad=Copy-Observation $operator;$bad | Add-Member NoteProperty Extra $true;Reject {Assert-ExternalCatalogBrowserCompletion $module $bad $records @($parts.Assets.Keys) $calls 0} 'closed operator'
Reject {Assert-ExternalCatalogBrowserCompletion $module $operator @($records | Where-Object Path -CNE '/') @($parts.Assets.Keys) $calls 0} 'missing document'
Reject {Assert-ExternalCatalogBrowserCompletion $module $operator ($records+@($records[0])) @($parts.Assets.Keys) $calls 0} 'duplicate asset'
Reject {Assert-ExternalCatalogBrowserCompletion $module $operator @($records | Where-Object Path -CNE '/api/config') @($parts.Assets.Keys) $calls 0} 'missing bootstrap'
Reject {Assert-ExternalCatalogBrowserCompletion $module $operator $records @($parts.Assets.Keys) $calls 1} 'forbidden effect'
Reject {Assert-ExternalCatalogBrowserCompletion $module $operator ($records+@($records[-1])) @($parts.Assets.Keys) $calls 0} 'extra action'
foreach($field in @('Method','Transport','PublicCalls')){$bad=Copy-Observation $records;$bad[-1].$field=$(switch($field){Method{'GET'} Transport{'CLIENT_DISCONNECTED'} PublicCalls{2}});Reject {Assert-ExternalCatalogBrowserCompletion $module $operator $bad @($parts.Assets.Keys) $calls 0} ('invalid '+$field)}
$bad=Copy-Observation $records;$bad[-1].Payload.CheckProviderReadiness=$true;Reject {Assert-ExternalCatalogBrowserCompletion $module $operator $bad @($parts.Assets.Keys) $calls 0} 'host optin veto'
$bad=Copy-Observation $records;$bad[-1].Payload.CheckProviderReadiness='false';Reject {Assert-ExternalCatalogBrowserCompletion $module $operator $bad @($parts.Assets.Keys) $calls 0} 'strict host boolean'
$bad=Copy-Observation $records;$bad[-1].Payload.VariantId='sql2022-java11-ubuntu2204-derived';Reject {Assert-ExternalCatalogBrowserCompletion $module $operator $bad @($parts.Assets.Keys) $calls 0} 'explicit variant binding'
$bad=Copy-Observation $calls;$bad[0].SqlVersion='2025';Reject {Assert-ExternalCatalogBrowserCompletion $module $operator $records @($parts.Assets.Keys) $bad 0} 'public identity binding'
$bad=Copy-Observation $calls;$bad[0].IncludeRecordedEvidence=$true;Reject {Assert-ExternalCatalogBrowserCompletion $module $operator $records @($parts.Assets.Keys) $bad 0} 'historical optin veto'
$bad=Copy-Observation $records[-1].Result;$bad.Decision.MutationAllowed=$true;Reject {Assert-ExternalCatalogBrowserResult $module $bad $cases[-1]} 'execution authority veto'
$bad=Copy-Observation $records[-2].Result;$bad.Options=@($bad.Options | Select-Object -First 8);Reject {Assert-ExternalCatalogBrowserResult $module $bad $cases[-2]} 'catalogue completeness'
Write-Host "EXTERNAL CATALOG BROWSER ACCEPTANCE FIXTURE: $checks PASS; $($parts.Sources.Count) actual source hashes; no listener/provider/State/secret/SQL"
