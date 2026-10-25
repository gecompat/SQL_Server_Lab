$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$module=New-Module -ArgumentList $root -ScriptBlock {
    param($root)
    $script:ModuleRoot=$root;$script:CatalogsPath=Join-Path $root 'Catalogs'
    $script:VersionCatalog=Get-Content (Join-Path $root 'Catalogs/sql-server-versions.json') -Raw|ConvertFrom-Json
    $script:RegisteredProviders=@{}
    foreach($name in @('Docker','Podman','HyperV')) {
        $definition=Get-Content (Join-Path $root "Providers/$name/provider.json") -Raw|ConvertFrom-Json
        $script:RegisteredProviders[$definition.name]=@{Definition=$definition}
    }
    foreach($path in @('Private/VersionCatalog.ps1','Private/SoftwareCatalog.ps1','Private/ExternalRuntimeCapability.ps1',
        'Private/DiagnosticBundleReadiness.ps1','Private/HostCapabilityMatrix.ps1','Public/Get-SqlServerLabHostCapabilityMatrix.ps1',
        'Private/HostCapabilityMatrixHttp.ps1')) {. (Join-Path $root $path)}
    $script:passed=0;$script:probes=0;$script:calls=0;$script:mode='normal';$script:observed=@();$script:providerCode='PROVIDER_REACHABLE'
    function Invoke-LabDiagnosticReadinessProcess {
        param($Provider,$Operation)
        $script:probes++;$script:observed+=@($Provider)
        if($script:providerCode -ceq 'TRANSPORT_TIMEOUT') {return [pscustomobject]@{Success=$false;Reason='DIAGNOSTIC_READINESS_TIMEOUT';Value=$null}}
        $code=$script:providerCode
        $category=switch($code){
            {$_ -cin @('PROVIDER_ACCESS_DENIED','TOOL_EXECUTION_DENIED')}{'Permission'}
            {$_ -cin @('TOOL_NOT_INSTALLED','PROVIDER_INSTALLATION_INCOMPLETE','TOOL_RESOLUTION_FAILED')}{'Installation'}
            default{'Reachability'}
        }
        [pscustomobject]@{Success=$true;Reason='NONE';Value=[pscustomobject]@{
            ContractVersion='SqlServerLab.DiagnosticProviderReadiness/1.0';Provider=$Provider;Operation=$Operation;Status=$(if($code -ceq 'PROVIDER_REACHABLE'){'READY'}else{'NOT_READY'})
            Checks=@([pscustomobject]@{Category=$category;Code=$code;Status=$(if($code -ceq 'PROVIDER_REACHABLE'){'PASS'}else{'BLOCKED'})})
        }}
    }
    $script:actualPublic=(Get-Command Get-SqlServerLabHostCapabilityMatrix).ScriptBlock
    function Get-SqlServerLabHostCapabilityMatrix {
        param($SqlVersion,$Provider,[switch]$CheckProviderReadiness)
        $script:calls++
        $result=& $script:actualPublic @PSBoundParameters
        switch($script:mode) {
            'authority' {$result.MutationAllowed=$true}
            'authority-string' {$result.ExecutionSupported='false'}
            'action' {$result.Actions=@('PRIVATE_HOST_CANARY')}
            'scope' {$result.SqlVersion='2019'}
            'provider' {$result.Providers[0].Provider='podman'}
            'profile' {$result.ProviderProfile='ALL_PROVIDERS'}
            'timestamp' {$result.GeneratedAtUtc='PRIVATE_HOST_CANARY'}
            'host-array' {$result.HostOperatingSystem=@('windows')}
            'extra' {$result|Add-Member -NotePropertyName Raw -NotePropertyValue 'PRIVATE_HOST_CANARY'}
            'provider-extra' {$result.Providers[0]|Add-Member -NotePropertyName Raw -NotePropertyValue 'PRIVATE_HOST_CANARY'}
            'row-extra' {$result.Capabilities[0]|Add-Member -NotePropertyName Raw -NotePropertyValue 'PRIVATE_HOST_CANARY'}
            'raw-capability' {$result.Capabilities[0].RequiredCapabilities=@('/PRIVATE_HOST_CANARY')}
            'raw-reason' {$result.Capabilities[0].ReasonCode='PRIVATE_HOST_CANARY'}
            'raw-variant' {$result.Capabilities[0].VariantId='/PRIVATE_HOST_CANARY'}
            'deferred-identity' {$result.Capabilities[-1].SoftwareId='sql-csharp'}
            'unassessed' {$result.Unassessed=@('PRIVATE_HOST_CANARY')}
            'explanation' {$result.Capabilities[0].Explanation='PRIVATE_HOST_CANARY'}
            'provider-relation' {$result.Providers[0].Presence='MISSING'}
            'provider-reason-relation' {$result.Providers[0].ReasonCode='PROVIDER_UNREACHABLE'}
            'row-relation' {$result.Capabilities[0].Availability='NOT_CHECKED';$result.Capabilities[0].ReasonCode='PROVIDER_NOT_CHECKED';$result.Capabilities[0].NextStep='CHECK_PROVIDER_READINESS'}
            'next-relation' {$result.Capabilities[0].NextStep='REVIEW_PROVIDER_READINESS'}
            'catalog-relation' {$result.Capabilities[0].CatalogStatus='BLOCKED';$result.Capabilities[0].CatalogReasonCode='RUNTIME_COMBINATION_NOT_CATALOGUED'}
            'deferred-requirements' {$result.Capabilities[-1].RequiredCapabilities=@('synthetic')}
            'deferred-selection' {$result.Capabilities[-1].ExplicitSelectionRequired=$true}
        }
        return $result
    }
    function Assert-Case {param([bool]$Condition,[string]$Name)
        if(-not $Condition){throw "FIXTURE_FAILED: $Name"};$script:passed++;Write-Host "PASS: $Name"
    }
    function New-Request {param([string]$Body)
        [pscustomobject]@{HttpMethod='POST';ContentType='application/json; charset=utf-8';Headers=@{Origin='http://127.0.0.1:8484'};
            Url=[uri]'http://127.0.0.1:8484/api/host-capability-matrix';LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,8484);
            InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Body))}
    }
    function Send-Request {param($Payload) Invoke-LabHostCapabilityMatrixHttpRequest -Request (New-Request ($Payload|ConvertTo-Json -Compress)) -ListenerPort 8484}
    function Reject-Request {param($Request,[string]$Name)
        $before=$script:calls;$caught=$false
        try {Invoke-LabHostCapabilityMatrixHttpRequest -Request $Request -ListenerPort 8484|Out-Null}
        catch {$caught=$_.Exception.Message -ceq 'HOST_MATRIX_HTTP_INVALID'}
        Assert-Case ($caught -and $script:calls -eq $before) $Name
    }
    function Test-AdapterAuthority {
        param([string]$Source)
        $tokens=$null;$errors=$null
        $adapter=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
        if($errors.Count -or @($adapter.FindAll({param($n)$n -is [Management.Automation.Language.FileRedirectionAst]},$true)).Count) {return $false}
        $allowed=@('Assert-LabHostMatrixHttpShape','ConvertFrom-Json','ConvertTo-Json','ConvertTo-LabHostMatrixHttpProjection',
            'Get-LabHostMatrixProfile','Get-SqlServerLabHostCapabilityMatrix','Select-Object','Test-LabHostMatrixHttpTimestamp','Where-Object')
        $commands=@($adapter.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))
        if(@($commands | Where-Object {$_.GetCommandName() -cnotin $allowed}).Count) {return $false}
        $constructors=@('byte[]','Text.UTF8Encoding','Text.Json.JsonDocumentOptions','Collections.Generic.HashSet[string]')
        $static=@('DateTimeOffset|TryParse','Text.Json.JsonDocument|Parse')
        $instances=@('[Text.Encoding]::UTF8|GetByteCount','[Text.UTF8Encoding]::new($false,$true)|GetString',
            '$document.RootElement|EnumerateObject','$document|Dispose','$keys|Add','$Matrix.PSObject|Copy',
            '$Request.InputStream|Read','$Request.LocalEndPoint.Address|ToString','$Request.Url|GetLeftPart')
        foreach($invocation in @($adapter.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst]},$true))) {
            if($invocation.Member -isnot [Management.Automation.Language.StringConstantExpressionAst]) {return $false}
            $member=$invocation.Member.Value
            if($invocation.Static) {
                if($invocation.Expression -isnot [Management.Automation.Language.TypeExpressionAst]) {return $false}
                $type=$invocation.Expression.TypeName.FullName
                if($member -ceq 'new') {if($type -cnotin $constructors){return $false}}
                elseif("$type|$member" -cnotin $static) {return $false}
            } else {
                $receiver=[regex]::Replace($invocation.Expression.Extent.Text,'\s+','')
                if("$receiver|$member" -cnotin $instances) {return $false}
            }
        }
        return $true
    }
    Assert-Case (Test-AdapterAuthority (Get-Content (Join-Path $root 'Private/HostCapabilityMatrixHttp.ps1') -Raw)) 'Actual adapter is bounded to read-only commands, concrete member receivers and constructors without file redirection'
    foreach($source in @('[IO.File]::Copy("source","target")','ConvertTo-Json -InputObject @{} > private-file.json','$unrelated.Copy()')) {
        Assert-Case (-not (Test-AdapterAuthority $source)) 'Authority oracle rejects static file copy, file redirection and unrelated instance calls without executing them'
    }
    $versions=Send-Request @{Action='ReadVersions'}
    Assert-Case ($versions.Status -ceq 'VERSIONS' -and ($versions.Versions -join ',') -ceq ($script:VersionCatalog.versions.id -join ',') -and $script:calls -eq 0 -and $script:probes -eq 0) 'Version choices use current loaded catalog without public/provider work'
    $request=[ordered]@{Action='ReadMatrix';SqlVersion='2022';Provider='all';CheckProviderReadiness=$false}
    $view=Send-Request $request
    Assert-Case ($view.Matrix.ProviderProfile -ceq 'NOT_CHECKED' -and $view.Matrix.Providers.Count -eq 3 -and $view.Matrix.Capabilities.Count -eq 12 -and $script:calls -eq 1 -and $script:probes -eq 0) 'All-provider browser default delegates exactly once to actual public API without host probe'
    Assert-Case (@($view.Matrix.Capabilities | Where-Object Language -CEQ 'C#').Count -eq 3 -and -not $view.Matrix.MutationAllowed -and $view.Matrix.Actions.Count -eq 0) 'Deferred C# and closed authority survive HTTP projection'
    $defaultPublic=& $script:actualPublic -SqlVersion 2022
    $expected=@($defaultPublic.Capabilities | Select-Object Provider,TargetOperatingSystem,Language,SoftwareId,VariantId,RuntimeVersion,CatalogStatus,CatalogReasonCode,Availability,ReasonCode,NextStep,RequiredCapabilities,ExplicitSelectionRequired)
    Assert-Case (($view.Matrix.Capabilities | ConvertTo-Json -Depth 12 -Compress) -ceq ($expected | ConvertTo-Json -Depth 12 -Compress)) 'Actual public/browser capability decisions are identical after documented projection'
    foreach($provider in @('docker','podman','hyperv')) {
        $request.Provider=$provider;$request.CheckProviderReadiness=$true;$before=$script:probes
        $view=Send-Request $request
        Assert-Case ($view.Matrix.ProviderProfile -ceq 'PARTIAL_SELECTION' -and $view.Matrix.Providers.Count -eq 1 -and
            $view.Matrix.Providers[0].Provider -ceq $provider -and $script:probes -eq $before+1 -and $script:observed[-1] -ceq $provider) "Explicit browser probe has exactly one provider scope: $provider"
        Assert-Case (@($view.Matrix.Capabilities | Where-Object {$_.Availability -ceq 'READY'}).Count -eq 0) "Bootstrap never becomes language execution: $provider"
    }
    $request.Provider='all';$request.CheckProviderReadiness=$true
    Reject-Request (New-Request ($request|ConvertTo-Json -Compress)) 'Browser multi-provider native request is rejected before public call'
    $request.Provider='docker';$request.CheckProviderReadiness=$false
    foreach($body in @('null','[]','{}','{"Action":true}','{"Action":false}','{"Action":"ReadVersions","action":"ReadVersions"}',
        '{"Action":"ReadVersions","Raw":"PRIVATE_HOST_CANARY"}',
        '{"Action":"ReadMatrix","SqlVersion":"2022","Provider":"docker","CheckProviderReadiness":"false"}',
        '{"Action":"ReadMatrix","SqlVersion":"2022","Provider":["docker"],"CheckProviderReadiness":false}',
        '{"Action":"ReadMatrix","SqlVersion":"2022-CU999","Provider":"docker","CheckProviderReadiness":false}',
        '{"Action":"ReadMatrix","SqlVersion":"2022","Provider":"Docker","CheckProviderReadiness":false}',
        (' '*2049))) {Reject-Request (New-Request $body) 'Malformed/unknown/oversize payload is rejected before any public/provider call'}
    foreach($change in @('method','origin','content','authority','local-address','local-port','path','query')) {
        $mock=New-Request ($request|ConvertTo-Json -Compress)
        switch($change){
            'method'{$mock.HttpMethod='GET'}
            'origin'{$mock.Headers.Origin='http://localhost:8484'}
            'content'{$mock.ContentType='text/plain'}
            'authority'{$mock.Url=[uri]'http://localhost:8484/api/host-capability-matrix'}
            'local-address'{$mock.LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Any,8484)}
            'local-port'{$mock.LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,8485)}
            'path'{$mock.Url=[uri]'http://127.0.0.1:8484/api/other'}
            'query'{$mock.Url=[uri]'http://127.0.0.1:8484/api/host-capability-matrix?secret=PRIVATE_HOST_CANARY'}
        }
        Reject-Request $mock "Loopback/origin/request binding: $change"
    }
    foreach($mode in @('authority','authority-string','action','scope','provider','profile','timestamp','host-array','extra','provider-extra','row-extra','raw-capability','raw-reason','raw-variant','deferred-identity','unassessed','deferred-requirements','deferred-selection','catalog-relation')) {
        $script:mode=$mode;$caught=$false;$before=$script:probes
        try {Send-Request $request|Out-Null}catch{$caught=$_.Exception.Message -ceq 'HOST_MATRIX_HTTP_INVALID'}
        Assert-Case ($caught -and $script:probes -eq $before) "Malformed public result is closed, scoped and raw-free: $mode"
    }
    $script:mode='explanation';$view=Send-Request $request
    Assert-Case (($view|ConvertTo-Json -Depth 20 -Compress) -cnotmatch 'PRIVATE_HOST_CANARY|Explanation') 'Free explanation text does not cross the browser DTO'
    $request.CheckProviderReadiness=$true
    foreach($mode in @('provider-relation','provider-reason-relation','row-relation','next-relation')) {
        $script:mode=$mode;$caught=$false;$before=$script:probes
        try {Send-Request $request|Out-Null}catch{$caught=$_.Exception.Message -ceq 'HOST_MATRIX_HTTP_INVALID'}
        Assert-Case ($caught -and $script:probes -eq $before+1) "Typed but contradictory observed result is rejected after one explicit probe: $mode"
    }
    $script:mode='normal'
    foreach($code in @('TOOL_NOT_INSTALLED','PROVIDER_ACCESS_DENIED','PROVIDER_UNREACHABLE','PROVIDER_INSTALLATION_INCOMPLETE','TOOL_RESOLUTION_FAILED','PROVIDER_RESPONSE_INVALID','TRANSPORT_TIMEOUT')) {
        $script:providerCode=$code;$view=Send-Request $request
        $expected=if($code -ceq 'TRANSPORT_TIMEOUT'){'DIAGNOSTIC_READINESS_TIMEOUT'}else{$code}
        Assert-Case ($view.Matrix.Providers[0].ReasonCode -ceq $expected -and -not $view.Matrix.ExecutionSupported) "Actual public incomplete/unknown result remains representable: $code"
    }
    Write-Host "Host matrix HTTP: $script:passed PASS; synthetic process boundary only."
}
try {& $module { }} finally {Remove-Module $module -Force -ErrorAction SilentlyContinue}
