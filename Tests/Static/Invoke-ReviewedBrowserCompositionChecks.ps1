#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft die gemeinsame Browserroute-, HTML-, Export- und Menükomposition ohne Runtime.
#>
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixture=Join-Path $repo ('.artifacts/reviewed-browser-composition-fixtures/'+[guid]::NewGuid().ToString('N'))
$checks=0
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw "COMPOSITION_CHECK_FAILED: $Name"};$script:checks++;Write-Host "PASS $Name"}
function Parse-Source([string]$Path){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'COMPOSITION_PARSE_FAILED'};$ast}
try {
    $server=Parse-Source (Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1')
    $paths=@('/api/evaluation-refresh-plan','/api/llama-start','/api/llama-start-plan','/api/external-runtime-capability','/api/collations/search')
    $routes=@(foreach($routePath in $paths){
        $matches=@($server.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq ("`$path -eq '$routePath'")},$true))
        Check ($matches.Count -eq 1) "Dedicated route unique $routePath"
        $matches[0]
    })
    $ordered=@($routes|Sort-Object {$_.Extent.StartOffset})
    foreach($route in $ordered){
        $other=@($ordered|Where-Object {$_.Extent.StartOffset -gt $route.Extent.StartOffset -and $_.Extent.EndOffset -lt $route.Extent.EndOffset})
        $tries=@($route.Clauses[0].Item2.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
        Check ($other.Count -eq 0 -and $tries.Count -eq 1 -and $tries[0].CatchClauses.Count -eq 1 -and $route.Clauses[0].Item2.Statements[-1] -is [Management.Automation.Language.ContinueStatementAst]) 'Independent full catch and continue, no nested route'
    }
    $html=[IO.File]::ReadAllText((Join-Path $repo 'Ui/index.html'))
    $ids=@([regex]::Matches($html,'\bid="([^"]+)"')|ForEach-Object {$_.Groups[1].Value})
    Check (@($ids|Group-Object|Where-Object Count -gt 1).Count -eq 0) 'All combined HTML IDs unique'
    foreach($family in @('evaluation-refresh','llama-start','llama-start-plan','external-runtime','collation')){
        Check (@($ids|Where-Object {$_ -ceq "$family-dialog"}).Count -eq 1 -and @($ids|Where-Object {$_ -ceq "$family-open"}).Count -eq 1) "Dialog and opener retained $family"
    }
    foreach($scriptName in @('app.js','evaluation-refresh-plan.js','llama-start.js','llama-start-plan.js','external-runtime-capability.js','collation-catalog.js','component-relations.js')){
        Check ([regex]::Matches($html,'src="'+[regex]::Escape($scriptName)+'"').Count -eq 1) "Script included once $scriptName"
    }
    Check ($html.Contains('Worker teilen ein gemeinsames Konto und besitzen Netzwerkzugriff') -and $html.Contains('Abbruch verwirft nur die Anzeige')) 'Complete shared-worker warning and truthful cancellation retained'
    $exports=@((Import-PowerShellDataFile (Join-Path $repo 'SqlServerLab.psd1')).FunctionsToExport)
    Check ($exports.Count -eq 135 -and @($exports|Sort-Object -Unique).Count -eq 135) '135 unique combined public exports'
    foreach($name in @('Get-SqlServerLabEvaluationRefreshPlan','Get-SqlServerLabLlamaCppStartPlan','Get-SqlServerLabExternalRuntimeCapability')){Check ($name -cin $exports) "Public union retains $name"}
    Check ([IO.File]::ReadAllText((Join-Path $repo 'Documentation/README.md')).Contains('135 exportierte Funktionen')) 'Documentation export count follows actual combined manifest'

    $module=New-Module -Name SqlServerLab -ArgumentList $repo,$fixture -ScriptBlock {
        param($repoRoot,$fixtureRoot)
        $script:repo=$repoRoot;$script:root=$fixtureRoot;$script:ModuleRoot=$repoRoot
        # Reuse only the existing metadata arrange, not its assertions or native imports.
        $tokens=$null;$errors=$null
        $arrangeAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Tests/Static/Invoke-EvaluationRefreshPlanChecks.ps1'),[ref]$tokens,[ref]$errors)
        if($errors.Count){throw 'COMPOSITION_ARRANGE_PARSE_FAILED'}
        foreach($statement in $arrangeAst.EndBlock.Statements){if($statement -is [Management.Automation.Language.FunctionDefinitionAst]){. ([scriptblock]::Create(($statement.Extent.Text -replace '^function ','function script:')))}}
        $try=@($arrangeAst.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
        $arrange=@();foreach($statement in $try[0].Body.Statements){if($statement.Extent.Text -match '^\$before='){break};$arrange+=$statement.Extent.Text}
        if($try.Count -ne 1 -or $arrange.Count -ne 19){throw 'COMPOSITION_ARRANGE_SHAPE_CHANGED'}
        . ([scriptblock]::Create($arrange -join "`n"))
        foreach($source in @('Private/EvaluationRefreshPlanConsole.ps1','Private/EvaluationRefreshPlanHttp.ps1','Private/SoftwareCatalog.ps1','Private/ContainerImageArtifact.ps1','Private/ExternalRuntimeCapability.ps1','Public/Get-SqlServerLabExternalRuntimeCapability.ps1','Private/ExternalRuntimeCapabilityHttp.ps1','Private/LlamaCppStartPlan.ps1','Public/Get-SqlServerLabLlamaCppStartPlan.ps1','Private/LlamaCppStartPlanConsole.ps1','Private/LlamaCppStartPlanHttp.ps1','Private/LlamaCppStartConsole.ps1','Private/LlamaCppStartHttp.ps1','Public/Start-SqlServerLabLlamaCppRuntime.ps1')){Import-RefreshFunctions $source}
        foreach($source in @('Private/CollationCatalog.ps1','Public/Find-SqlServerLabCollation.ps1','Private/CollationCatalogHttp.ps1')){Import-RefreshFunctions $source}
        $script:CatalogsPath=Join-Path $repo Catalogs;$script:SchemasPath=Join-Path $repo Schemas;$script:RegisteredProviders=@{}
        foreach($provider in @('Docker','Podman')){$definition=Get-Content (Join-Path $repo "Providers/$provider/provider.json") -Raw|ConvertFrom-Json;$script:RegisteredProviders[$definition.name]=@{Definition=$definition}}
        $candidateAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Private/AiExternalModelAcceleration.ps1'),[ref]$tokens,[ref]$errors)
        foreach($name in @('Get-LabLlamaCppRuntimeCandidate','Find-LabLlamaCppRuntime')){$function=$candidateAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true);. ([scriptblock]::Create($function.Extent.Text))}
        $script:ConfirmPreference=[Management.Automation.ConfirmImpact]::High
        $script:Forbidden=0;$script:Transports=0;$script:HttpCalls=@{};$script:HttpBodies=@{}
        foreach($name in @('Invoke-LabEvaluationRefreshHttpRequest','Invoke-LabLlamaCppStartHttpRequest','Invoke-LabLlamaCppStartPlanHttpRequest','Invoke-LabExternalRuntimeCapabilityHttpRequest','Invoke-LabCollationCatalogHttpRequest')){
            $script:HttpBodies[$name]=(Get-Command $name).ScriptBlock;$script:HttpCalls[$name]=0
            $parameters=if($name -cin @('Invoke-LabLlamaCppStartHttpRequest','Invoke-LabExternalRuntimeCapabilityHttpRequest','Invoke-LabCollationCatalogHttpRequest')){'param($Request,$ListenerPort)'}else{'param($Request)'}
            Set-Item ("Function:script:$name") ([scriptblock]::Create($parameters+"`n`$script:HttpCalls['$name']++; & `$script:HttpBodies['$name'] @PSBoundParameters"))
        }
        function Initialize-LabHostToolPath {param($Name)[pscustomobject]@{Available=$true;Invocation=Join-Path $root "synthetic-$Name.exe"}}
        function Invoke-LabDiagnosticBoundedProcess {
            param($StartInfo,$TimeoutSeconds,$MaximumBytes)
            if($TimeoutSeconds -ne 20 -or $MaximumBytes -ne 65536 -or $StartInfo.ArgumentList.Count -ne 3 -or $StartInfo.ArgumentList[0] -cne 'info' -or $StartInfo.ArgumentList[1] -cne '--format'){throw 'COMPOSITION_TRANSPORT_CONTRACT_CHANGED'}
            $script:Transports++;[pscustomobject]@{Success=$true;Value=[pscustomobject]@{OperatingSystem='linux';CgroupVersion='1';SecurityOptions=@()}}
        }
        foreach($name in @('Start-LabLlamaCppOwnedRuntime','Stop-LabLlamaCppOwnedRuntime','Start-UiBackgroundAction','Invoke-SqlServerLabWorkflowAction','Start-ThreadJob','Start-Job','Start-Process','Invoke-Sqlcmd','Get-VM','Get-LabSecret','Get-LabStorageConfiguration','Get-LabStateRoot','Invoke-LabAiExternalModelHttpTransport','Write-LabEvent')){
            Set-Item ("Function:script:$name") {$script:Forbidden++;throw 'COMPOSITION_FORBIDDEN_NATIVE_LEAF'}
        }
        $script:LlamaCppOwnedSessions=@{};$script:Before=Get-RefreshHashes
        [pscustomobject]@{DataRoot=$root;RunId=$runId;ScopeId=$scope}
    }
    # New-Module emits the module object; obtain metadata in that same held session.
    $module=@($module|Where-Object {$_ -is [Management.Automation.PSModuleInfo]})[0]
    $script:HeldModule=$module;$script:Response=$null;$script:Responses=0;$script:Lookups=0
    function Get-Module {param($Name);if($Name -cne 'SqlServerLab'){throw 'COMPOSITION_MODULE_CHANGED'};$script:Lookups++;$script:HeldModule}
    function Write-UiResponse {param($Context,$Body,$ContentType,$StatusCode=200);$script:Responses++;$script:Response=[pscustomobject]@{Body=$Body;Status=$StatusCode}}
    $dispatch=[scriptblock]::Create('foreach($iteration in 1){'+(($ordered|ForEach-Object {$_.Extent.Text}) -join "`n")+"`nthrow 'COMPOSITION_UNHANDLED_ROUTE'"+'}')
    function Send([string]$Path,$Payload){
        $Port=19499;$path=$Path;$json=$Payload|ConvertTo-Json -Depth 10 -Compress;$stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($json),$false)
        $context=[pscustomobject]@{Request=[pscustomobject]@{HttpMethod='POST';ContentType='application/json';Headers=@{Origin='http://127.0.0.1:19499'};Url=[uri]("http://127.0.0.1:19499"+$Path);LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,19499);ContentEncoding=[Text.Encoding]::UTF8;InputStream=$stream}}
        $before=$script:Responses
        $counts=& $module { @{}+$script:HttpCalls }
        try{
            . $dispatch
            Check ($script:Responses -eq $before+1) 'Exactly one response, no fallthrough'
            $expected=switch -CaseSensitive ($Path){
                '/api/evaluation-refresh-plan' {'Invoke-LabEvaluationRefreshHttpRequest'}
                '/api/llama-start' {'Invoke-LabLlamaCppStartHttpRequest'}
                '/api/llama-start-plan' {'Invoke-LabLlamaCppStartPlanHttpRequest'}
                '/api/external-runtime-capability' {'Invoke-LabExternalRuntimeCapabilityHttpRequest'}
                '/api/collations/search' {'Invoke-LabCollationCatalogHttpRequest'}
            }
            $current=& $module { @{}+$script:HttpCalls }
            Check (@($current.Keys|Where-Object {$current[$_] -ne ($counts[$_]+[int]($_ -ceq $expected))}).Count -eq 0) 'Exactly the matching actual helper, no cross-route dispatch'
            $script:Response
        }finally{$stream.Dispose()}
    }
    foreach($path in $paths){$response=Send $path @{};Check ($response.Status -eq 400 -and $response.Body -notmatch 'CANARY|Exception|Path') "Combined route safe failure $path"}
    $response=Send '/api/collations/search' @{SqlVersion='2025';Query='Latin1 UTF8'};$collations=$response.Body|ConvertFrom-Json
    Check ($response.Status -eq 200 -and $collations.ReturnedCount -eq 1 -and $collations.SqlValidation -ceq 'NOT_CHECKED' -and $collations.Actions.Count -eq 0) 'Fifth route reaches actual Public/catalogue/schema without SQL'
    $dataRoot=& $module {$script:root}
    $response=Send '/api/evaluation-refresh-plan' @{Action='Read';DataRoot=$dataRoot};$metadata=$response.Body|ConvertFrom-Json
    Check ($response.Status -eq 200 -and $metadata.Status -ceq 'METADATA_ONLY' -and $metadata.Runs.Count -eq 1) 'Combined D route reaches actual registered reader'
    $response=Send '/api/evaluation-refresh-plan' @{Action='Preview';DataRoot=$dataRoot;Selection=$metadata.Runs[0];Mode='STATEFUL_MIGRATION'};$plan=$response.Body|ConvertFrom-Json
    Check ($response.Status -eq 200 -and $plan.Status -ceq 'BLOCKED' -and $plan.Actions.Count -eq 0) 'Combined D route reaches actual Public/Core without transfer'
    Check ((& $module {Get-RefreshHashes}) -ceq (& $module {$script:Before})) 'Combined D routes preserve all registered source bytes'
    $response=Send '/api/external-runtime-capability' @{Action='ReadOptions';Provider='docker';OperatingSystem='linux';SqlVersion='2022'};$options=$response.Body|ConvertFrom-Json
    Check ($response.Status -eq 200 -and $options.Status -ceq 'OPTIONS' -and $options.Options.Count -eq 9 -and (& $module {$script:Transports}) -eq 0) 'Combined catalog route reaches real reducer, no host probe'
    $selected=@($options.Options|Where-Object {$_.Decision.CatalogDecision.Status -ceq 'DECLARED_SUPPORTED'})[0]
    $evaluate=@{Action='Evaluate';Provider='docker';OperatingSystem='linux';SqlVersion='2022';SoftwareId=$selected.SoftwareId;RuntimeVersion=$selected.RuntimeVersion;VariantId=$selected.VariantId;CheckProviderReadiness=$true}
    $response=Send '/api/external-runtime-capability' $evaluate;$decision=$response.Body|ConvertFrom-Json
    Check ($response.Status -eq 200 -and $decision.Decision.CurrentReadiness.Status -ceq 'READY' -and (& $module {$script:Transports}) -eq 1 -and -not $decision.Decision.ExecutionSupported) ("Combined conscious host route: status="+$decision.Decision.CurrentReadiness.Status+" reason="+$decision.Decision.CurrentReadiness.ReasonCode+" transports="+(& $module {$script:Transports}))
    $runtime=Join-Path $fixture runtime;$null=New-Item -ItemType Directory $runtime
    [IO.File]::WriteAllText((Join-Path $runtime 'llama-server.exe'),'synthetic-not-executable');[IO.File]::WriteAllText((Join-Path $runtime 'ggml-cuda.dll'),'synthetic')
    $model=Join-Path $fixture model.gguf;[IO.File]::WriteAllBytes($model,[Text.Encoding]::ASCII.GetBytes('GGUFsynthetic'))
    $inputs=@{RuntimeDirectory=$runtime;ModelPath=$model;Backend='LlamaCppCuda';Accelerator='CPU';Dimension=768;Pooling='mean';Port=19435;StartTimeoutSeconds=120;LeaseSeconds=900;ContextSize=512}
    $response=Send '/api/llama-start-plan' @{Action='Preview';Parameters=$inputs};$plan=$response.Body|ConvertFrom-Json
    Check ($response.Status -eq 200 -and $plan.Mode -ceq 'PLAN_ONLY' -and $plan.Status -ceq 'BLOCKED') 'Combined files-only route reaches actual Public and candidate reader'
    $inputs.ModelName='synthetic-model';$inputs.CertificatePath='SYNTHETIC_FILE';$inputs.PrivateKeyPath='SYNTHETIC_FILE';$inputs.ApiKey='x'*32;$inputs.TrustedRootPath=''
    $response=Send '/api/llama-start' @{Action='WhatIf';Confirmed=$false;Parameters=$inputs};$result=$response.Body|ConvertFrom-Json
    Check ($response.Status -eq 200 -and $result.Status -ceq 'WHATIF_ONLY' -and -not $result.PossibleOwnSession) 'Combined actual Start/Public WhatIf preserves zero private runtime dispatch'
    Check ((& $module {$script:Forbidden}) -eq 0 -and $script:Lookups -eq $script:Responses) 'All combined routes use one held module lookup per response, forbidden leaves zero'

    $console=Parse-Source (Join-Path $repo 'Private/PublicCommandConsole.ps1')
    $handler=$console.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Manage-LabPublicCommandsInteractive'},$true)
    $menu=New-Module -ArgumentList $handler.Extent.Text -ScriptBlock {
        param($body)
        . ([scriptblock]::Create($body));$script:Seen=@();$script:Choice=$null;$script:Selections=0
        function Get-LabPublicCommandConsoleCatalog {[pscustomobject]@{Name='SyntheticCommand';ParameterSets=@([pscustomobject]@{Name='Default'})}}
        function New-LabConsoleItem {param($Id,$Label,$Value,$Shortcut,$Data)[pscustomobject]@{Id=$Id;Data=$Data}}
        function Invoke-LabConsoleMenu {param($ScreenId,$Title,$Subtitle,$Items);if(++$script:Selections -gt 1 -or $null -eq $script:Choice){return [pscustomobject]@{Status='Cancelled'}};$item=@($Items|Where-Object Id -CEQ $script:Choice)[0];[pscustomobject]@{Status='Selected';SelectedItem=$item}}
        function Invoke-LabEvaluationRefreshPlanInteractive {$script:Seen+='D'}
        function Invoke-LabLlamaCppStartInteractive {$script:Seen+='START'}
        function Invoke-LabLlamaCppStartPlanInteractive {$script:Seen+='PLAN'}
        function Invoke-LabComponentRelationPlanInteractive {$script:Seen+='COMPONENT'}
        function Invoke-LabPublicCommandInteractive {param($CatalogItem)$script:Seen+='GENERIC'}
    }
    foreach($case in @(@('evaluation-refresh-preview','D'),@('llama-guided-start','START'),@('llama-start-plan-preview','PLAN'),@('component-relations-preview','COMPONENT'),@('SyntheticCommand','GENERIC'))){
        $seen=& $menu {param($choice)$script:Choice=$choice;$script:Selections=0;$script:Seen=@();Manage-LabPublicCommandsInteractive;$script:Seen} $case[0]
        Check (@($seen).Count -eq 1 -and $seen -ceq $case[1]) "Combined actual menu dispatch $($case[1])"
    }
    $seen=& $menu {$script:Choice=$null;$script:Selections=0;$script:Seen=@();Manage-LabPublicCommandsInteractive;$script:Seen}
    Check (@($seen).Count -eq 0) 'Combined actual menu cancel zero dispatch'
    Write-Host "REVIEWED_BROWSER_COMPOSITION: $checks PASS; 0 FAIL; synthetic transport only; no native/provider/process/network execution"
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture);$parent=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/reviewed-browser-composition-fixtures'))
    if(-not $resolved.StartsWith($parent+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^[a-f0-9]{32}$'){throw 'COMPOSITION_FIXTURE_CLEANUP_SCOPE_INVALID'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
