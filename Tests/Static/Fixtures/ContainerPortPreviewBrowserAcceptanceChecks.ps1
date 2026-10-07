#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo Tests/Common/ContainerPortPreviewBrowserAcceptance.ps1)
$module=Import-Module (Join-Path $repo SqlServerLab.psd1) -Force -PassThru
$checks=0
function Check($Value,$Name){if(-not $Value){throw ('PORT_BROWSER_CHECK_FAILED: '+$Name)};$script:checks++;Write-Host ('PASS: '+$Name)}
function New-FixturePortPlan([string]$Provider,[bool]$NoChange){
    [pscustomobject]@{Contract=[pscustomobject]@{Name='SqlServerLab.ContainerPortPreview';Version='1.0'};
        Mode='CONTAINER_PORT_PREVIEW_PLAN_ONLY';Status='PLAN_ONLY';Reason='PORT_PREVIEW_APPLY_NOT_IMPLEMENTED';Provider=$Provider;
        ObservationKey=$(if($NoChange){'b'*64}else{'a'*64});Actual=[pscustomobject]@{Evidence='MEASURED';SqlBinding='SINGLE_LOOPBACK_1433_TCP';Lifecycle='RUNNING'};
        Desired=[pscustomobject]@{PortChange=$(if($NoChange){'SAME_PORT'}else{'DIFFERENT_PORT'})};NoChange=$NoChange;ChangeClass=$(if($NoChange){'no-op'}else{'recreate'});
        CanApply=$false;MutationAllowed=$false;Actions=@();Preview=[pscustomobject]@{Downtime=$(if($NoChange){'NONE'}else{'REQUIRED'});
            Endpoint='NOT_CHECKED';Sql='NOT_CHECKED';Backup='NOT_CHECKED';DataImpact='NOT_VERIFIED';Mounts=[pscustomobject]@{Status='MEASURED';TotalMountCount=0;
                VolumeMountCount=0;HostBindCount=0;WritableHostBindCount=0;OtherMountCount=0;VolumeOwnership='NOT_CHECKED'}}}
}
try {
    # Real loopback transport, no browser or provider. A declared body that never
    # arrives must release control before product dispatch/cleanup can be blocked.
    $portProbe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $portProbe.Start();$port=$portProbe.LocalEndpoint.Port;$portProbe.Stop()
    $listener=[Net.HttpListener]::new();$listener.Prefixes.Add("http://127.0.0.1:$port/")
    $client=[Net.Sockets.TcpClient]::new();$context=$null
    try {
        $listener.Start();$accepted=$listener.GetContextAsync();$client.Connect('127.0.0.1',$port)
        $headers=[Text.Encoding]::ASCII.GetBytes("POST /api/container-port-preview HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nContent-Length: 100`r`nContent-Type: application/json`r`n`r`n{")
        $client.GetStream().Write($headers);$client.GetStream().Flush()
        if(-not $accepted.Wait(5000)){throw 'PORT_BROWSER_FIXTURE_ACCEPT_TIMEOUT'}
        $context=$accepted.GetAwaiter().GetResult();$timer=[Diagnostics.Stopwatch]::StartNew();$veto=$false
        try{Read-PortPreviewBrowserRequestBody $context.Request 200|Out-Null}catch{$veto=$_.Exception.Message -ceq 'PORT_BROWSER_BODY_TIMEOUT'}
        $timer.Stop()
        Check ($veto -and $timer.Elapsed.TotalSeconds -lt 3) 'Incomplete native HTTP body releases control within bounded read deadline'
    } finally {if($context){$context.Response.Abort()};$client.Dispose();$listener.Close()}
    foreach($provider in @('docker','podman')){
        $plans=@((New-FixturePortPlan $provider $false),(New-FixturePortPlan $provider $true),(New-FixturePortPlan $provider $false))
        $records=@(foreach($calls in @(0,1,1,1,0)){[pscustomobject]@{Status=200;PublicCalls=$calls;PinnedReads=$(if($calls){3}else{0});StateEqual=$true}})
        $operator=[pscustomobject]@{Contract='SqlServerLab.PortBrowserOperatorObservation/1.0';RenderedDialog=$true;InvalidPortVeto=$true;EditingClearedResult=$true;CloseClearedDialog=$true}
        Assert-PortPreviewBrowserObservation $module $records $plans $provider $operator
        Check $true "$provider measured HTTP and separate operator observations accepted"
        foreach($case in @('operator-false','operator-array','operator-extra','missing-http','extra-http','failed-http','wrong-order','metadata-native','preview-no-native','changed-state',
                'dto-apply','dto-extra','wrong-provider','wrong-repeat','wrong-noop','dto-blocked')){
            $r=@($records|ForEach-Object{[pscustomobject]@{Status=$_.Status;PublicCalls=$_.PublicCalls;PinnedReads=$_.PinnedReads;StateEqual=$_.StateEqual}})
            $p=@((New-FixturePortPlan $provider $false),(New-FixturePortPlan $provider $true),(New-FixturePortPlan $provider $false))
            $o=$operator|ConvertTo-Json|ConvertFrom-Json
            switch($case){
                operator-false {$o.RenderedDialog=$false}
                operator-array {$o.InvalidPortVeto=@($true)}
                operator-extra {$o|Add-Member Authority 'SYNTHETIC_CANARY'}
                missing-http {$r=$r[0..3]}
                extra-http {$r+= $r[0]}
                failed-http {$r[0].Status=400}
                wrong-order {$r[0].PublicCalls=1;$r[1].PublicCalls=0}
                metadata-native {$r[0].PinnedReads=1}
                preview-no-native {$r[1].PinnedReads=0}
                changed-state {$r[2].StateEqual=$false}
                dto-apply {$p[0].CanApply=$true}
                dto-extra {$p[0]|Add-Member RawSecret 'SYNTHETIC_CANARY'}
                wrong-provider {$p[0].Provider=$(if($provider -ceq 'docker'){'podman'}else{'docker'})}
                wrong-repeat {$p[2].ObservationKey='c'*64}
                wrong-noop {$p[1]=New-FixturePortPlan $provider $false}
                dto-blocked {$p[0].Status='BLOCKED'}
            }
            $veto=$false;try{Assert-PortPreviewBrowserObservation $module $r $p $provider $o}catch{$veto=$true}
            Check $veto "$provider refuses incomplete or false evidence: $case"
        }
    }
    $veto=$false;try{Invoke-PortPreviewBrowserAcceptance -ListenerPort 14336}catch{$veto=$true}
    Check $veto 'Product listener port rejected before module/runtime access'
    $veto=$false
    try{& (Join-Path $repo Tests/Integration/Invoke-ContainerPortPreviewAcceptance.ps1) -Provider docker -DataRoot relative -ParentOperationId ('f'*32) -BrowserAcceptance -ListenerPort 14336}
    catch{$veto=$_.Exception.Message -ceq 'PORT_BROWSER_PRODUCT_PORT'}
    Check $veto 'Actual integration entry rejects product port before scope/module/creation'
    foreach($file in @('Tests/Common/ContainerPortPreviewBrowserAcceptance.ps1','Tests/Integration/Invoke-ContainerPortPreviewAcceptance.ps1')){
        $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $file),[ref]$tokens,[ref]$errors)
        Check ($errors.Count -eq 0) "$file parses"
    }
    [pscustomobject]@{Passed=$checks;RuntimeCalls=0;RenderedBrowser='NOT_EXECUTED'}|ConvertTo-Json -Compress
} finally {Remove-Module $module -Force}
