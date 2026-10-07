$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo Tests/Common/CollationCatalogBrowserAcceptance.ps1)
. (Join-Path $repo Private/CollationCatalogHttp.ps1)
$parts=Get-CollationBrowserProductParts $repo
$module=New-CollationBrowserModule $repo
$checks=0
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw "COLLATION_BROWSER_FIXTURE: $Name"};$script:checks++}
function Reject([scriptblock]$Body,[string]$Name){$failed=$false;try{& $Body}catch{$failed=$true};Check $failed $Name}
function Copy-Observation($Value){$Value | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10}
Check ($parts.Assets.Count -eq 12 -and $parts.Sources.Count -eq 18) 'full source and asset bindings'
$records=@(foreach($path in $parts.Assets.Keys){[pscustomobject]@{Path=$path;Method='GET';Status=200;Transport='SENT';PublicCalls=0;Result=$null}})
$records+=@(foreach($path in @('/api/config','/api/commands','/api/workflow','/api/jobs','/api/jobs')){[pscustomobject]@{Path=$path;Method='GET';Status=200;Transport='SENT';PublicCalls=0;Result=$null}})
$cases=@(Get-CollationBrowserCases)
foreach($case in $cases){
    $body=@{SqlVersion=$case.SqlVersion;Query=$case.Query} | ConvertTo-Json -Compress
    $stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($body),$false)
    $request=[pscustomobject]@{HttpMethod='POST';ContentType='application/json; charset=utf-8';Headers=@{Origin='http://127.0.0.1:19546'};Url=[uri]'http://127.0.0.1:19546/api/collations/search';LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,19546);InputStream=$stream}
    try{$result=& $module {param($request) Invoke-LabCollationCatalogHttpRequest -Request $request -ListenerPort 19546} $request}finally{$stream.Dispose()}
    $transported=Copy-Observation $result
    Assert-CollationBrowserResult $transported $case
    Check ($transported.ReturnedCount -eq $case.Count) ('actual public catalogue '+$case.SqlVersion+' '+$case.Query)
    $records+=[pscustomobject]@{Path='/api/collations/search';Method='POST';Status=200;Transport='SENT';PublicCalls=1;Result=$transported}
}
$calls=@(& $module {@($script:BrowserCalls)})
$flags=@('FullDocument','AllScriptsLoaded','BootstrapRendered','NavigationToCreate','OpenEditNoSearch','MatchesRendered','DeprecatedRendered','NoMatchesRendered','ZeroTokensRendered','ReopenClears','NoScriptErrors','DialogClosed')
$operator=[pscustomobject]@{Contract='SqlServerLab.CollationBrowserOperator/1.0'}
foreach($name in $flags){$operator | Add-Member NoteProperty $name $true}
Assert-CollationBrowserCompletion $operator $records @($parts.Assets.Keys) $calls 0
Check ((& $module {$script:BrowserEffects}) -eq 0 -and $calls.Count -eq 6) 'bounded actual public workflow and zero forbidden effects'
foreach($flag in $flags){$bad=Copy-Observation $operator;$bad.$flag=$false;Reject {Assert-CollationBrowserCompletion $bad $records @($parts.Assets.Keys) $calls 0} ('operator '+$flag)}
$bad=Copy-Observation $operator;$bad.FullDocument='true';Reject {Assert-CollationBrowserCompletion $bad $records @($parts.Assets.Keys) $calls 0} 'boolean remains strict'
Reject {Assert-CollationBrowserCompletion $operator @($records | Where-Object Path -CNE '/') @($parts.Assets.Keys) $calls 0} 'missing document'
Reject {Assert-CollationBrowserCompletion $operator ($records+@($records[0])) @($parts.Assets.Keys) $calls 0} 'duplicate asset'
Reject {Assert-CollationBrowserCompletion $operator @($records | Where-Object Path -CNE '/api/config') @($parts.Assets.Keys) $calls 0} 'missing bootstrap'
Reject {Assert-CollationBrowserCompletion $operator $records @($parts.Assets.Keys) $calls 1} 'forbidden effect veto'
Reject {Assert-CollationBrowserCompletion $operator ($records+@($records[-1])) @($parts.Assets.Keys) ($calls+@($calls[-1])) 0} 'extra search'
$badRecords=Copy-Observation $records;$badRecords[-1].Method='GET';Reject {Assert-CollationBrowserCompletion $operator $badRecords @($parts.Assets.Keys) $calls 0} 'wrong search method'
$badRecords=Copy-Observation $records;$badRecords[-1].PublicCalls=2;Reject {Assert-CollationBrowserCompletion $operator $badRecords @($parts.Assets.Keys) $calls 0} 'dispatch duplication'
$badRecords=Copy-Observation $records;$badRecords[0].Transport='CLIENT_DISCONNECTED';Reject {Assert-CollationBrowserCompletion $operator $badRecords @($parts.Assets.Keys) $calls 0} 'asset delivery required'
$badCalls=Copy-Observation $calls;$badCalls[0].SqlVersion='2022';Reject {Assert-CollationBrowserCompletion $operator $records @($parts.Assets.Keys) $badCalls 0} 'version sequence drift'
foreach($value in @('65001',$true,65001.5,2147483648L)){$bad=Copy-Observation $records[-1].Result;$bad.Results[0].CodePage=$value;Reject {Assert-CollationBrowserResult $bad $cases[-1]} 'invalid transported integer'}
$bad=Copy-Observation $records[-1].Result;$bad.MutationAllowed=$true;Reject {Assert-CollationBrowserResult $bad $cases[-1]} 'mutation authority veto'
$bad=Copy-Observation $records[-1].Result;$bad.Results[0].Name='unexpected';Reject {Assert-CollationBrowserResult $bad $cases[-1]} 'unexpected catalogue row'
Write-Host "COLLATION BROWSER ACCEPTANCE FIXTURE: $checks PASS; no listener/provider/State/secret/SQL"
