# Actual HTTP -> unchanged Public ShouldProcess -> isolated runtime leaf; no module autoload.
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path)
$ErrorActionPreference='Stop';$passed=0;$failed=0
function Check([string]$Name,[bool]$Condition){if($Condition){$script:passed++;Write-Host "PASS $Name"}else{$script:failed++;Write-Host "FAIL $Name"}}
$module=New-Module -Name SqlServerLab {
    param($root)
    . (Join-Path $root 'Private/LlamaCppStartHttp.ps1')
    . (Join-Path $root 'Private/LlamaCppStartConsole.ps1')
    . (Join-Path $root 'Public/Start-SqlServerLabLlamaCppRuntime.ps1')
    # Observe the real handler-owned key at its result leaf without modifying Public.
    $originalResult=(Get-Command New-LabLlamaStartHttpResult).ScriptBlock.ToString()
    Set-Item Function:script:New-FixtureActualHttpResult ([scriptblock]::Create($originalResult))
    function New-LabLlamaStartHttpResult {
        param($Status,$OperationId,$PossibleOwnSession)
        $script:Key=(Get-Variable ownedKey -Scope 1).Value
        New-FixtureActualHttpResult @PSBoundParameters
    }
    $script:ConfirmPreference=[Management.Automation.ConfirmImpact]::High
    function Start-LabLlamaCppOwnedRuntime {
        param($RuntimeDirectory,$Backend,$Accelerator,$ModelPath,$ModelName,$Dimension,$Pooling,$Port,$CertificatePath,$PrivateKeyPath,$ApiKey,$TrustedRootPath,$StartTimeoutSeconds,$LeaseSeconds,$ContextSize)
        $script:Starts++;$script:Key=$ApiKey;$script:Received=@{}+$PSBoundParameters
        if($script:Mode -ceq 'RAWERROR'){throw 'PRIVATE_SECRET_CANARY'}
        if($script:Mode -ceq 'RECOVERY'){throw 'LLAMA_RECOVERY_REQUIRED; OperationId=PRIVATE_SECRET_CANARY; OriginalFailure=PRIVATE_SECRET_CANARY'}
        if($script:Mode -ceq 'NULL'){return}
        $id='11111111-2222-4333-8444-555555555555'
        $script:LlamaCppOwnedSessions=@{$id=@{Port=[int]$Port}}
        $selector=if($Backend -ceq 'LlamaCppOpenVino'){'OPENVINO0'}elseif($Accelerator -ceq 'CPU'){'none'}else{'CUDA0'}
        $result=[pscustomobject]@{Contract='SqlServerLab.LlamaCppOwnedRuntime/1.0';OperationId=$id;Status='ENDPOINT_VERIFIED';Backend=$Backend;Accelerator=$Accelerator;ModelName=$ModelName;Dimension=[int]$Dimension;Location="https://127.0.0.1:$Port/v1/embeddings";ServerCertificateSha256=('a'*64);LeaseSeconds=[int]$LeaseSeconds;ArtifactEvidence=$null;CandidateId=$null;SelectionMode='EXPLICIT_LEGACY';RuntimeSelectors=@($selector)}
        switch($script:Mode){
            'EXTRA'{$result|Add-Member NoteProperty PrivatePath 'PRIVATE_SECRET_CANARY'}
            'FOREIGN'{$result.OperationId='22222222-2222-4333-8444-555555555555'}
            'PORT'{$script:LlamaCppOwnedSessions[$id].Port++}
            'SELECTOR'{$result.RuntimeSelectors=@('none','CUDA0')}
            'MULTI'{$result}
        }
        $result
    }
    foreach($name in @('Stop-SqlServerLabLlamaCppRuntime','Stop-LabLlamaCppOwnedRuntime','Start-Process','Find-LabLlamaCppRuntime','Get-SqlServerLabLlamaCppStartPlan','Invoke-LabAiExternalModelHttpTransport','Test-Path','Get-Content','Get-Item')){
        Set-Item ('Function:script:'+$name) ([scriptblock]::Create("`$script:Forbidden++;throw 'FIXTURE_FORBIDDEN_BOUNDARY'"))
    }
    function Run-Case {
        param([string]$Body,[string]$Mode='VALID',[string]$Preference='High',[bool]$AmbientWhatIf=$false,[string]$Origin='http://127.0.0.1:19499',[string]$HostName='127.0.0.1',[int]$Port=19499,[string]$LocalAddress='127.0.0.1',[string]$Method='POST',[string]$ContentType='application/json',[byte[]]$RawBytes)
        $script:Starts=0;$script:Forbidden=0;$script:Key=$null;$script:Mode=$Mode;$script:LlamaCppOwnedSessions=@{};$script:Received=$null
        $script:ConfirmPreference=if($Preference -eq 'Unknown'){'PRIVATE_SECRET_CANARY'}else{[Management.Automation.ConfirmImpact]::$Preference}
        $script:WhatIfPreference=$AmbientWhatIf
        if($null -eq $RawBytes){$RawBytes=[Text.Encoding]::UTF8.GetBytes($Body)}
        $stream=[IO.MemoryStream]::new($RawBytes,$false)
        $request=[pscustomobject]@{HttpMethod=$Method;ContentType=$ContentType;Headers=@{Origin=$Origin};Url=[uri]"http://${HostName}:$Port/api/llama-start";LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Parse($LocalAddress),19499);InputStream=$stream}
        $view=$null;$code=$null
        try{$view=Invoke-LabLlamaCppStartHttpRequest -Request $request -ListenerPort 19499}catch{$code=$_.Exception.Message}finally{$stream.Dispose()}
        if($script:Forbidden){throw 'FIXTURE_FORBIDDEN_BOUNDARY_REACHED'}
        $disposed=$false;if($script:Key){try{$script:Key.AppendChar([char]122)}catch [ObjectDisposedException]{$disposed=$true}}
        [pscustomobject]@{Starts=$script:Starts;Code=$code;View=$view;Disposed=$disposed;Received=$script:Received;Sessions=$script:LlamaCppOwnedSessions.Count;Request=$request}
    }
} -ArgumentList $RepoRoot
$parameters=@{RuntimeDirectory='PRIVATE_PATH_CANARY';Backend='LlamaCppCuda';Accelerator='CPU';ModelPath='PRIVATE_PATH_CANARY';ModelName='PRIVATE_ALIAS_CANARY';Dimension=768;Pooling='mean';Port=19435;CertificatePath='PRIVATE_PATH_CANARY';PrivateKeyPath='PRIVATE_PATH_CANARY';ApiKey=('x'*32);TrustedRootPath='';StartTimeoutSeconds=120;LeaseSeconds=900;ContextSize=512}
function Body([hashtable]$Params=$parameters,[string]$Action='Start',[bool]$Confirmed=$true){@{Action=$Action;Confirmed=$Confirmed;Parameters=$Params}|ConvertTo-Json -Compress -Depth 6}
function Run([hashtable]$Options=@{}){if(-not$Options.ContainsKey('Body')){$Options.Body=Body}; & $module {param($opts)Run-Case @opts} $Options}
$valid=Run
Check 'Actual public default ConfirmImpact is Medium' ((& $module {[Management.Automation.CommandMetadata]::new((Get-Command Start-SqlServerLabLlamaCppRuntime)).ConfirmImpact}) -eq [Management.Automation.ConfirmImpact]::Medium)
Check 'Same-module public starts once and validates held ownership' ($valid.Starts -eq 1 -and $valid.Sessions -eq 1 -and $valid.View.Status -ceq 'ENDPOINT_VERIFIED')
Check 'Handler owned SecureString disposed after actual public dispatch' $valid.Disposed
Check 'Closed result drops paths alias key pin and caller canaries' (($valid.View|ConvertTo-Json -Compress) -notmatch 'PRIVATE_|xxx|https|Certificate')
Check 'Exactly fifteen explicit arguments optional empty CA omitted' ($valid.Received.Count -eq 14 -and -not$valid.Received.ContainsKey('TrustedRootPath'))
foreach($preference in @('Low','Medium','Unknown')){$r=Run @{Preference=$preference};Check "Preference $preference rejects before public/runtime" ($r.Starts -eq 0 -and $r.Code -ceq 'LLAMA_START_HTTP_CONFIRM_POLICY_BLOCKED')}
$none=Run @{Preference='None'};Check 'None preference preserved natural ShouldProcess' ($none.Starts -eq 1 -and $none.View.Status -ceq 'ENDPOINT_VERIFIED')
$whatif=Run @{Body=(Body -Action WhatIf -Confirmed $false)};Check 'Deliberate WhatIf public no-effect disposes owned key with no private runtime' ($whatif.Starts -eq 0 -and $whatif.Disposed -and $whatif.View.Status -ceq 'WHATIF_ONLY' -and -not$whatif.View.PossibleOwnSession)
$ambient=Run @{AmbientWhatIf=$true};Check 'Ambient WhatIf never reports endpoint success' ($ambient.Starts -eq 0 -and $ambient.View.Status -ceq 'WHATIF_ONLY')
foreach($body in @((Body -Confirmed $false),(Body -Action WhatIf -Confirmed $true),(Body -Action Stop))){$r=Run @{Body=$body};Check 'Nonconsensual/unknown action zero dispatch' ($r.Starts -eq 0 -and $r.Code -ceq 'LLAMA_START_HTTP_CONFIRMATION_REQUIRED')}
foreach($option in @(@{Origin=''},@{Origin='http://localhost:19499'},@{HostName='localhost'},@{Port=19500},@{LocalAddress='::1'},@{Method='GET'},@{ContentType='text/plain'})){$r=Run $option;Check 'Exact method origin listener authority veto' ($r.Starts -eq 0 -and $r.Code -ceq 'LLAMA_START_HTTP_INVALID')}
foreach($mutation in @('ApiKey','CertificatePath','Dimension','Backend','LeaseSeconds','Accelerator','Extra','Null','Missing')){
    $changed=@{}+$parameters
    switch($mutation){'ApiKey'{$changed.ApiKey='short'}'CertificatePath'{$changed.CertificatePath='x'*4097}'Dimension'{$changed.Dimension='768'}'Backend'{$changed.Backend='llamacppcuda'}'LeaseSeconds'{$changed.LeaseSeconds=120}'Accelerator'{$changed.Accelerator='NPU'}'Extra'{$changed.Private='PRIVATE_SECRET_CANARY'}'Null'{$changed.ApiKey=$null}'Missing'{$changed.Remove('ModelPath')}}
    $r=Run @{Body=(Body $changed)};Check "Strict field $mutation zero dispatch" ($r.Starts -eq 0 -and $r.Code -ceq 'LLAMA_START_HTTP_INVALID')
}
foreach($bad in @((Body).Replace('"Confirmed":true','"Confirmed":"true"'),(Body).Replace('"Action":"Start"','"Action":"Start","action":"Start"'),(Body).Replace('"Dimension":768','"Dimension":768.0'),'[]')){$r=Run @{Body=$bad};Check 'JSON shape duplicate case coercion rejected' ($r.Starts -eq 0 -and $r.Code -ceq 'LLAMA_START_HTTP_INVALID')}
$r=Run @{RawBytes=[byte[]]@(255,254)};Check 'Malformed UTF8 bytes zero dispatch' ($r.Starts -eq 0 -and $r.Code -ceq 'LLAMA_START_HTTP_INVALID')
$r=Run @{Body=(' '*32769)};Check 'Decoded aggregate char maximum rejected' ($r.Starts -eq 0 -and $r.Code -ceq 'LLAMA_START_HTTP_INVALID')
$multi=@{}+$parameters;foreach($field in @('RuntimeDirectory','ModelPath','CertificatePath','PrivateKeyPath','TrustedRootPath')){$multi[$field]=[string]::new([char]0x4e00,4096)}
$r=Run @{Body=(Body $multi)};Check 'Multibyte combination within actual aggregate limits reaches public' ($r.Starts -eq 1 -and $r.View.Status -ceq 'ENDPOINT_VERIFIED')
$escaped=(Body $multi).Replace([string][char]0x4e00,'\u4e00')
$r=Run @{Body=$escaped};Check 'Escaped multibyte combination over byte maximum zero dispatch' ($r.Starts -eq 0 -and $r.Code -ceq 'LLAMA_START_HTTP_INVALID')
foreach($mode in @('EXTRA','FOREIGN','PORT','SELECTOR','MULTI','NULL','RAWERROR','RECOVERY')){$r=Run @{Mode=$mode};Check "Postdispatch $mode fixed outcome no adoption stop or leak" ($r.Starts -eq 1 -and $r.Disposed -and $r.View.Status -cin @('NOT_CONFIRMED','RECOVERY_REQUIRED') -and $r.View.PossibleOwnSession -and $null -eq $r.View.OperationId -and ($r.View|ConvertTo-Json -Compress) -notmatch 'PRIVATE_|xxx')}
# Extract the actual new route extent; only listener response/module lookup leaves are isolated.
$tok=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tok,[ref]$errors)
$route=$ast.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq "$"+'path -eq '+"'/api/llama-start'"},$true)
if(-not$route){throw 'FIXTURE_ROUTE_MISSING'}
$script:RouteModule=$module;$script:RouteResponse=$null
function Get-Module {param($Name)$script:RouteModule}
function Write-UiResponse {param($Context,$Body,$ContentType,$StatusCode=200)$script:RouteResponse=[pscustomobject]@{Body=$Body;StatusCode=$StatusCode}}
$routeBody=Body;$routeStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($routeBody),$false)
try{
    & $module {$script:ConfirmPreference=[Management.Automation.ConfirmImpact]::High;$script:WhatIfPreference=$false;$script:Mode='VALID';$script:Starts=0}
    $Port=19499;$path='/api/llama-start';$context=[pscustomobject]@{Request=[pscustomobject]@{HttpMethod='POST';ContentType='application/json';Headers=@{Origin='http://127.0.0.1:19499'};Url=[uri]'http://127.0.0.1:19499/api/llama-start';LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,19499);InputStream=$routeStream}}
    & ([scriptblock]::Create('do {'+$route.Extent.Text+'} while($false)'))
    Check 'Actual extracted route dispatches exact held module/public without job' ($script:RouteResponse.StatusCode -eq 200 -and ($script:RouteResponse.Body|ConvertFrom-Json).Status -ceq 'ENDPOINT_VERIFIED' -and (& $module {$script:Starts}) -eq 1)
}finally{$routeStream.Dispose()}
Write-Host "LLAMA_START_HTTP_CHECKS: $passed PASS; $failed FAIL; runtime/process/file/network leaves 0"
if($failed){throw 'LLAMA_START_HTTP_CHECKS_FAILED'}
