$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$module=New-Module -Name SqlServerLab -ArgumentList $repo -ScriptBlock {
    param($repo)
    $script:CatalogsPath=Join-Path $repo Catalogs;$script:SchemasPath=Join-Path $repo Schemas
    foreach($file in @('Private/CollationCatalog.ps1','Public/Find-SqlServerLabCollation.ps1','Private/CollationCatalogHttp.ps1')){. (Join-Path $repo $file)}
    $script:PublicBody=(Get-Command Find-SqlServerLabCollation).ScriptBlock;$script:PublicCalls=0;$script:Effects=0
    function Find-SqlServerLabCollation {param($Query,$SqlVersion);$script:PublicCalls++;& $script:PublicBody @PSBoundParameters}
    foreach($name in @('Invoke-Sqlcmd','Start-Process','Get-VM','Get-LabStateRoot','Write-LabEvent','New-LabRunState','Initialize-LabHostToolPath','Invoke-LabDiagnosticBoundedProcess','Invoke-LabContainerCli','Invoke-SqlServerLabWorkflowAction')){Set-Item ("Function:script:$name") {$script:Effects++;throw 'FORBIDDEN_EFFECT'}}
}
$script:HeldModule=$module;$script:Responses=0;$script:Lookups=0;$checks=0
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw "FIXTURE_FAILED: $Name"};$script:checks++;Write-Host "PASS: $Name"}
function Get-Module {param($Name);if($Name -cne 'SqlServerLab'){throw 'WRONG_MODULE'};$script:Lookups++;$script:HeldModule}
function Write-UiResponse {param($Context,$Body,$ContentType,$StatusCode=200);$script:Responses++;$script:Response=[pscustomobject]@{Status=$StatusCode;Body=$Body}}
$tokens=$null;$parseErrors=$null;$server=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tokens,[ref]$parseErrors)
$routes=@($server.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq "`$path -eq '/api/collations/search'"},$true))
Check ($parseErrors.Count -eq 0 -and $routes.Count -eq 1) 'Actual dedicated route has one parseable AST'
$dispatch=[scriptblock]::Create('foreach($iteration in 1){'+$routes[0].Extent.Text+"`nthrow 'ROUTE_FALLTHROUGH'"+'}')
function Send([string]$Body,$Overrides=@{},[byte[]]$Bytes=$null){
    $Port=19499;$path='/api/collations/search';if($null -eq $Bytes){$Bytes=[Text.Encoding]::UTF8.GetBytes($Body)}
    $stream=[IO.MemoryStream]::new($Bytes,$false)
    $request=[pscustomobject]@{HttpMethod='POST';ContentType='application/json; charset=utf-8';Headers=@{Origin='http://127.0.0.1:19499'};Url=[uri]'http://127.0.0.1:19499/api/collations/search';LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,19499);InputStream=$stream}
    foreach($key in $Overrides.Keys){$request.$key=$Overrides[$key]};$context=[pscustomobject]@{Request=$request};$before=$script:Responses
    try{. $dispatch;if($script:Responses -ne $before+1){throw 'RESPONSE_COUNT_INVALID'};return $script:Response}finally{$stream.Dispose()}
}
function Reject([string]$Body,[string]$Name,$Overrides=@{},[byte[]]$Bytes=$null){
    $before=& $module {$script:PublicCalls};$response=Send $Body $Overrides $Bytes
    Check ($response.Status -eq 400 -and ($response.Body|ConvertFrom-Json).Code -ceq 'COLLATION_HTTP_INVALID' -and (& $module {$script:PublicCalls}) -eq $before -and $response.Body -notmatch 'CANARY|Exception') $Name
}
foreach($major in @('2019','2022','2025')){foreach($query in @('','---','日本語')){
    $response=Send (@{SqlVersion=$major;Query=$query}|ConvertTo-Json -Compress);$view=$response.Body|ConvertFrom-Json
    Check ($response.Status -eq 200 -and $view.Results.Count -eq 6 -and $view.ReturnedCount -eq 6 -and -not $view.Truncated -and $view.SqlValidation -ceq 'NOT_CHECKED' -and -not $view.MutationAllowed -and -not $view.ExecutionSupported -and $view.Actions.Count -eq 0) "Actual public/schema zero-token search $major $query"
}}
$response=Send '{"SqlVersion":"2025","Query":"Latin1 UTF8"}';$view=$response.Body|ConvertFrom-Json
Check ($response.Status -eq 200 -and $view.Results.Count -eq 1 -and $view.Results[0].Utf8) 'Actual ASCII AND tokens filter the catalogue'
$response=Send '{"SqlVersion":"2022","Query":"PRIVATE_CANARY"}';$view=$response.Body|ConvertFrom-Json
Check ($view.Status -ceq 'NO_MATCHES' -and $view.Results.Count -eq 0 -and $response.Body -notmatch 'PRIVATE_CANARY') 'No match does not echo query'
$response=Send '{"SqlVersion":"2019","Query":"SQL_Latin1"}';$view=$response.Body|ConvertFrom-Json
Check ($view.Results[0].Status -ceq 'DEPRECATED' -and @($view.PSObject.Properties).Count -eq 10 -and @($view.Results[0].PSObject.Properties).Count -eq 9) 'Deprecated default remains valid, closed metadata only'
$body='{"SqlVersion":"2025","Query":""}'
foreach($bad in @('{}','[]','null','{"SqlVersion":"2025"}','{"SqlVersion":2025,"Query":""}','{"SqlVersion":"2020","Query":""}','{"SqlVersion":"2025","Query":null}','{"SqlVersion":"2025","Query":false}','{"SqlVersion":"2025","Query":{}}','{"SqlVersion":"2025","Query":[]}','{"SqlVersion":"2025","Query":"","QUERY":"PRIVATE_CANARY"}','{"SqlVersion":"2025","Query":"","Extra":"PRIVATE_CANARY"}','{"sqlVersion":"2025","Query":""}','{"SqlVersion":"2025","Query":"\u0000"}',(@{SqlVersion='2025';Query='x'*257}|ConvertTo-Json -Compress),(' '*1025))){Reject $bad ('Strict body '+$checks)}
Reject '' 'Invalid UTF8 rejected' @{} ([byte[]]@(255))
Reject '' 'Byte limit rejected before public' @{} ([Text.Encoding]::UTF8.GetBytes('界'*683))
foreach($override in @(@{HttpMethod='GET'},@{ContentType='text/plain'},@{Headers=@{}},@{Headers=@{Origin='http://localhost:19499'}},@{Url=[uri]'http://127.0.0.1:19500/api/collations/search'},@{LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,19500)},@{LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::IPv6Loopback,19499)})){Reject $body ('Exact origin/listener boundary '+$checks) $override}
$fixture=Join-Path $repo ('.artifacts/collation-browser/retained-http-fixtures/'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $fixture
$originalCatalog=& $module {$script:CatalogsPath}
try{
    & $module {param($folder)$script:CatalogsPath=$folder} $fixture
    [IO.File]::WriteAllText((Join-Path $fixture 'sql-server-collations.json'),'{}')
    $response=Send $body;Check ($response.Status -eq 500 -and ($response.Body|ConvertFrom-Json).Code -ceq 'COLLATION_HTTP_RESULT_INVALID') 'Actual malformed catalogue schema fails closed'
    $catalog=Get-Content (Join-Path $originalCatalog 'sql-server-collations.json') -Raw|ConvertFrom-Json;$catalog.collations+=@($catalog.collations[0]);$catalog|ConvertTo-Json -Depth 8|Set-Content (Join-Path $fixture 'sql-server-collations.json')
    $response=Send $body;Check ($response.Status -eq 500) 'Actual duplicate catalogue fails closed'
}finally{& $module {param($folder)$script:CatalogsPath=$folder} $originalCatalog}
# Owned synthetic catalogue files are retained; no deletion/cleanup claim.
& $module {$script:SavedPublic=(Get-Command Find-SqlServerLabCollation).ScriptBlock;function script:Find-SqlServerLabCollation {param($Query,$SqlVersion);$script:PublicCalls++;$script:SyntheticRows}}
try{
    $row=[pscustomobject]@{Name='Latin1_General_100_CI_AS';Locale='Latin';CodePage=1252;Lcid=1033;CaseSensitivity='CI';AccentSensitivity='AS';Utf8=$false;Status='SUPPORTED';SqlVersion='2025'}
    & $module {param($rows)$script:SyntheticRows=$rows} (@(1..101|ForEach-Object {$row}))
    $response=Send $body;$view=$response.Body|ConvertFrom-Json;Check ($response.Status -eq 200 -and $view.Results.Count -eq 100 -and $view.Truncated) 'Actual output bound truncates only after validation'
    foreach($mutation in @('Extra','CodePage','Utf8','Locale','SqlVersion','Name')){
        $bad=$row|Select-Object *
        switch($mutation){Extra{$bad|Add-Member NoteProperty Extra 'PRIVATE_CANARY'} CodePage{$bad.CodePage='1252'} Utf8{$bad.Utf8='false'} Locale{$bad.Locale="PRIVATE_CANARY`n"} SqlVersion{$bad.SqlVersion='2022'} Name{$bad.Name='<img src=x>'}}
        & $module {param($rows)$script:SyntheticRows=$rows} @($bad)
        $response=Send $body;Check ($response.Status -eq 500 -and $response.Body -notmatch 'PRIVATE_CANARY|img') "Closed output rejects $mutation"
    }
    $wide=$row|Select-Object *;$wide.Locale='界'*256
    & $module {param($rows)$script:SyntheticRows=$rows} (@(1..100|ForEach-Object {$wide}))
    $response=Send $body;Check ($response.Status -eq 500) 'Serialized UTF8 response limit fails closed'
}finally{& $module {Set-Item Function:script:Find-SqlServerLabCollation $script:SavedPublic}}
Check ((& $module {$script:Effects}) -eq 0 -and $script:Lookups -eq $script:Responses) 'Measured forbidden effects zero and same held module for every actual route'
Write-Host "HTTP TOTAL: $checks PASS; 0 FAIL; measured forbidden effects 0; retained owned synthetic fixtures; no provider/SQL/runtime"
