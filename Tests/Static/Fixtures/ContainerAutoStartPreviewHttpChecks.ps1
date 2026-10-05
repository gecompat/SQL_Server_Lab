#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$module=Import-Module (Join-Path $repo SqlServerLab.psd1) -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('SqlServerLab-AutoStartHttp-'+[guid]::NewGuid().ToString('N'))
$script:checks=0
function Check($value,$name){if(-not $value){throw ('AUTOSTART_HTTP_CHECK_FAILED: '+$name)};$script:checks++;Write-Host ('PASS: '+$name)}
try {
    & $module {
        param($Root)
        function script:Write-AutoStartJson($path,$value){$null=New-Item -ItemType Directory (Split-Path $path) -Force;$value|ConvertTo-Json -Depth 60|Set-Content -LiteralPath $path -Encoding utf8}
        $script:dataRoot=Join-Path $Root data;$state=Join-Path $script:dataRoot State
        $controller=[guid]::NewGuid().ToString('D');$location=[guid]::NewGuid().ToString('D')
        Write-AutoStartJson (Join-Path $script:dataRoot '.sql-server-lab-root.json') @{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId='SYNTHETIC_VOLUME';DataRoot=$script:dataRoot}
        Write-AutoStartJson (Join-Path $script:dataRoot 'Catalog/storage-locations.json') @{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@(@{LocationId=$location;ControllerId=$controller;LabDataRoot=$script:dataRoot;VolumeId='SYNTHETIC_VOLUME'})}
        function script:Get-LabDataRootDefault {$script:metadataReads++;$script:dataRoot}
        $script:targetsBody=${function:Get-LabContainerPortConsoleTargets}
        function script:Get-LabContainerPortConsoleTargets {
            param($DataRoot)
            $rows=@(& $script:targetsBody -DataRoot $DataRoot)
            switch($script:targetCase){
                'duplicate' {if($rows.Count){$rows+=@($rows[0])}}
                'scalar' {if($rows.Count){$rows[0].Provider=@($rows[0].Provider)}}
            }
            $rows
        }
        function script:Test-LabAutomatedTestEnvironmentRun {$script:protected}
        function script:Get-LabConnectionCenterCmsConfiguration {if($script:cms){[pscustomobject]@{RunId=$script:runId}}}
        $script:tool=Join-Path $Root inspect.ps1
        Set-Content $script:tool '$global:httpInspectCalls++;$global:httpInspect|ConvertTo-Json -Depth 60' -Encoding utf8
        function script:Get-LabHostToolInvocation {$script:tool}
        $script:publicBody=${function:Get-SqlServerLabReconcilePlan}
        function script:Get-SqlServerLabReconcilePlan {
            param($RunId,$InstanceId,$StateRoot,[switch]$ContainerAutoStartPreview,[string]$AutoStart)
            $script:publicCalls++;$plan=& $script:publicBody @PSBoundParameters
            switch($script:dtoCase){'apply'{$plan.CanApply=$true};'mutation'{$plan.MutationAllowed=$true};'extra'{$plan|Add-Member Raw 'PRIVATE_CANARY'};'nestedextra'{$plan.Actual|Add-Member Raw 'PRIVATE_CANARY'};'actions'{$plan.Actions=@('START')};'mount'{$plan.Preview.Mounts.TotalMountCount=1025};'reason'{$plan.Reason='PRIVATE_CANARY'}}
            if($script:dtoCase -like 'scalar:*') {
                $parts=$script:dtoCase.Substring(7).Split('.');$owner=$plan
                for($index=0;$index -lt ($parts.Count-1);$index++){$owner=$owner.($parts[$index])}
                $name=$parts[-1];$owner.$name=@($owner.$name)
            }
            $plan
        }
        foreach($name in @('Get-LabSecret','Invoke-SqlQuery','Test-LabEndpointBinding','Repair-LabContainerReconcileJournal','Update-SqlServerLabContainer','Invoke-SqlServerLabWorkflowAction','Invoke-LabActionWithResult','Start-Process')) {
            Set-Item ("Function:script:$name") {$script:effects++;throw 'FORBIDDEN_EFFECT'}
        }
        $script:effects=0;$script:publicCalls=0;$script:metadataReads=0;$global:httpInspectCalls=0
        foreach($provider in @('docker','podman')) {
            $instance=[pscustomobject]@{id=$provider;provider=$provider;version='2025';profile='standard';autostart='off';drives=@();databases=@();software=@()}
            $desired=New-LabDesiredStateSnapshot -ResolvedLab ([pscustomobject]@{name='Synthetic SQL autostart HTTP';instances=@($instance)}) -ProvisioningMode adhoc -PersistentData $false
            $run=New-LabRunState -StateRoot $state -Metadata @{desiredState=$desired;persistentData=$false} -ProviderSubRuns @([pscustomobject]@{provider=$provider;instanceIds=@($provider)})
            $stored=Get-Content (Join-Path $run.RunDir run-state.json) -Raw|ConvertFrom-Json -Depth 60;$stored.state='RUNNING';$stored.providerSubRuns[0].state='RUNNING';Write-AutoStartJson (Join-Path $run.RunDir run-state.json) $stored
            Write-AutoStartJson (Join-Path $run.RunDir connection-info.json) @{instances=@(@{id=$provider;provider=$provider;containerId=('a'*64);containerName='PRIVATE_CANARY';port=1})}
        }
        function script:Set-HttpInspect($target) {
            $binding=Get-LabDiagnosticBinding -RunId $target.RunId -InstanceId $target.InstanceId -DataRoot $script:dataRoot
            $global:httpInspect=[pscustomobject]@{Id=('a'*64);Image=('sha256:'+('b'*64));State=[pscustomobject]@{Running=$true};Config=[pscustomobject]@{Labels=[pscustomobject]@{'sql-server-lab.run-id'=$binding.Run.runId;'sql-server-lab.scope-id'=$binding.Run.scopeId;'sql-server-lab.instance-id'=$target.InstanceId;'sql-server-lab.autostart'='off'};Env=@('MSSQL_SA_PASSWORD=PRIVATE_CANARY')};HostConfig=[pscustomobject]@{NanoCpus=2000000000L;Memory=2048MB;NetworkMode='PRIVATE_NETWORK';RestartPolicy=[pscustomobject]@{Name='no'};PortBindings=[pscustomobject]@{'1433/tcp'=@([pscustomobject]@{HostIp='127.0.0.1';HostPort='14333'})}};NetworkSettings=[pscustomobject]@{Ports=[pscustomobject]@{'1433/tcp'=@([pscustomobject]@{HostIp='127.0.0.1';HostPort='14333'})};Networks=[pscustomobject]@{PRIVATE_NETWORK=[pscustomobject]@{Aliases=@();IPAMConfig=$null}}};Mounts=@()}
        }
    } $root
    $script:held=$module
    function Get-Module {param($Name);if($Name -cne 'SqlServerLab'){throw 'WRONG_MODULE'};$script:held}
    function Write-UiResponse {param($Context,$Body,$ContentType,$StatusCode=200);$script:response=[pscustomobject]@{Status=$StatusCode;Body=$Body}}
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tokens,[ref]$errors)
    $route=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq "`$path -eq '/api/container-autostart-preview'"},$true))
    Check ($errors.Count -eq 0 -and $route.Count -eq 1) 'Actual dedicated server route parses once'
    $dispatch=[scriptblock]::Create('foreach($iteration in 1){'+$route[0].Extent.Text+"`nthrow 'FALLTHROUGH'"+'}')
    function Send($body,$override=@{},[byte[]]$bytes=$null) {
        if($null -eq $bytes){$bytes=[Text.Encoding]::UTF8.GetBytes($body)}
        $stream=[IO.MemoryStream]::new($bytes,$false)
        $Port=19499;$path='/api/container-autostart-preview'
        $request=[pscustomobject]@{HttpMethod='POST';ContentType='application/json; charset=utf-8';Headers=@{Origin='http://127.0.0.1:19499'};Url=[uri]'http://127.0.0.1:19499/api/container-autostart-preview';LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,19499);RemoteEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,19000);InputStream=$stream}
        foreach($key in $override.Keys){$request.$key=$override[$key]}
        try {$context=[pscustomobject]@{Request=$request};& $dispatch;$script:response}finally{$stream.Dispose()}
    }
    function Reject($body,$name,$override=@{},[byte[]]$bytes=$null) {
        $before=& $module {$script:publicCalls};$inspect=$global:httpInspectCalls
        $response=Send $body $override $bytes
        Check ($response.Status -eq 400 -and $response.Body -ceq '{"Code":"AUTOSTART_HTTP_INVALID"}' -and (& $module {$script:publicCalls}) -eq $before -and $global:httpInspectCalls -eq $inspect) $name
    }
    foreach($body in @('{"Action":["Read"]}','{"Action":["Read","Read"]}','{"Action":["Preview"],"RunId":"11111111-1111-1111-1111-111111111111","InstanceId":"docker","AutoStart":"on"}')) {
        $metadata=& $module {$script:metadataReads}
        Reject $body 'Array Action veto before metadata'
        Check ((& $module {$script:metadataReads}) -eq $metadata) 'Array Action metadata reads zero'
    }
    $before=@(Get-ChildItem $root -Recurse -File|ForEach-Object {$_.FullName+':'+(Get-FileHash $_.FullName).Hash}) -join '|'
    $response=Send '{"Action":"Read"}';$view=$response.Body|ConvertFrom-Json
    Check ($response.Status -eq 200 -and $view.Targets.Count -eq 2 -and $global:httpInspectCalls -eq 0 -and (& $module {$script:publicCalls}) -eq 0 -and $response.Body -notmatch 'PRIVATE_|StateRoot|ScopeId|ContainerId') 'Metadata read has no inspect/public call or private authority'
    foreach($case in @('duplicate','scalar')) {
        & $module {param($c)$script:targetCase=$c} $case
        try {Reject '{"Action":"Read"}' ('Malformed internal metadata '+$case)} finally {& $module {$script:targetCase=''}}
    }
    foreach($target in $view.Targets) {
        & $module {param($t)Set-HttpInspect $t} $target
        $body=@{Action='Preview';RunId=$target.RunId;InstanceId=$target.InstanceId;AutoStart='on'}|ConvertTo-Json -Compress
        $beforeCalls=& $module {$script:publicCalls};$beforeInspect=$global:httpInspectCalls
        $response=Send $body;$plan=$response.Body|ConvertFrom-Json
        Check ($response.Status -eq 200 -and $plan.Status -ceq 'PLAN_ONLY' -and (& $module {$script:publicCalls}) -eq ($beforeCalls+1) -and $global:httpInspectCalls -eq ($beforeInspect+1) -and $response.Body -notmatch 'PRIVATE_|14333|127.0.0.1|StateRoot|ContainerId') ('Actual route/public/core one inspect '+$target.Provider)
        foreach($case in @('apply','mutation','extra','nestedextra','actions','mount','reason')) {
            & $module {param($c)$script:dtoCase=$c} $case
            $response=Send $body;Check ($response.Status -eq 400 -and $response.Body -notmatch 'PRIVATE_') ('Malformed response veto '+$case)
        }
        foreach($field in @('Contract.Name','Contract.Version','Mode','Status','Reason','Provider','Actual.Evidence','Actual.SqlBinding','Actual.Lifecycle','Actual.AutoStart','Desired.AutoStartChange','ChangeClass','Preview.Downtime','Preview.Endpoint','Preview.Sql','Preview.Backup','Preview.HostLogin','Preview.DataImpact','Preview.Mounts.Status','Preview.Mounts.VolumeOwnership')) {
            & $module {param($f)$script:dtoCase='scalar:'+$f} $field
            $response=Send $body
            Check ($response.Status -eq 400 -and $response.Body -ceq '{"Code":"AUTOSTART_HTTP_INVALID"}') ('Scalar array response veto '+$field+' '+$target.Provider)
        }
        & $module {$script:dtoCase=''}
        $repeat=Send $body;$again=$repeat.Body|ConvertFrom-Json
        $first=Send $body;$same=$first.Body|ConvertFrom-Json
        Check ($repeat.Status -eq 200 -and $same.ObservationKey -ceq $again.ObservationKey) ('Repeated request content binding '+$target.Provider)
        foreach($policyCase in @('UNKNOWN','DRIFTED')) {
            & $module {param($c)if($c -ceq 'UNKNOWN'){$global:httpInspect.Config.Labels.'sql-server-lab.autostart'=$null}else{$global:httpInspect.Config.Labels.'sql-server-lab.autostart'='on'}} $policyCase
            $response=Send $body;$v=$response.Body|ConvertFrom-Json
            Check ($response.Status -eq 200 -and $v.Status -ceq 'BLOCKED' -and $v.Actual.AutoStart -ceq $policyCase -and -not $v.CanApply -and $null -eq $v.ObservationKey) ('Actual public policy '+$policyCase+' '+$target.Provider)
        }
        & $module {param($t)Set-HttpInspect $t} $target
        & $module {$global:httpInspect.HostConfig.RestartPolicy.Name='on-failure'}
        $response=Send $body;$unsupported=$response.Body|ConvertFrom-Json
        Check ($response.Status -eq 200 -and $unsupported.Status -ceq 'UNSUPPORTED' -and $unsupported.Actual.AutoStart -ceq 'UNKNOWN' -and $unsupported.Reason -ceq 'AUTOSTART_PREVIEW_POLICY_UNSUPPORTED') ('Unsupported policy remains unknown '+$target.Provider)
        & $module {param($t)Set-HttpInspect $t} $target
        $noopBody=@{Action='Preview';RunId=$target.RunId;InstanceId=$target.InstanceId;AutoStart='off'}|ConvertTo-Json -Compress
        $response=Send $noopBody;$noop=$response.Body|ConvertFrom-Json
        Check ($response.Status -eq 200 -and $noop.NoChange -and -not $noop.CanApply -and $noop.Actions.Count -eq 0) ('No-op still nonexecutable '+$target.Provider)
        foreach($protect in @('protected','cms')) {& $module {param($p,$id)Set-Variable -Scope Script -Name $p -Value $true;$script:runId=$id} $protect $target.RunId;Reject $body ('Protected target zero core '+$protect);& $module {param($p)Set-Variable -Scope Script -Name $p -Value $false} $protect}
        & $module {
            param($t)
            $binding=Get-LabDiagnosticBinding -RunId $t.RunId -InstanceId $t.InstanceId -DataRoot $script:dataRoot
            $script:runPath=Join-Path $binding.Directory run-state.json
            $script:runBytes=[IO.File]::ReadAllBytes($script:runPath)
        } $target
        foreach($badState in @('STOPPED','LEGACY')) {
            & $module {param($s)$run=Get-Content $script:runPath -Raw|ConvertFrom-Json -Depth 60;if($s -ceq 'STOPPED'){$run.state='STOPPED'}else{$run.metadata.desiredState=$null};Write-AutoStartJson $script:runPath $run} $badState
            try {Reject $body ('Stopped or legacy target zero core '+$badState)} finally {& $module {[IO.File]::WriteAllBytes($script:runPath,$script:runBytes)}}
        }
        $markerPath=& $module {Join-Path $script:dataRoot '.sql-server-lab-root.json'}
        $markerBytes=[IO.File]::ReadAllBytes($markerPath)
        try {
            $foreign=Get-Content -LiteralPath $markerPath -Raw|ConvertFrom-Json
            $foreign.ControllerId=[guid]::NewGuid().ToString('D')
            $foreign|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $markerPath -Encoding utf8
            Reject $body ('Fresh server root rebinding rejects foreign controller '+$target.Provider)
        } finally {[IO.File]::WriteAllBytes($markerPath,$markerBytes)}
    }
    foreach($body in @('{}','null','[]','{"Action":"Read","action":"Read"}','{"Action":"Read","StateRoot":"PRIVATE_CANARY"}','{"Action":"Read","NativeId":"PRIVATE_CANARY"}','{"Action":"Read","CanApply":true}','{"Action":"Preview","RunId":"foreign","InstanceId":"x","AutoStart":"on"}',('{"Action":"Preview","RunId":"'+$target.RunId+'","InstanceId":"foreign","AutoStart":"on"}'),('{"Action":"Preview","RunId":"'+$target.RunId+'","InstanceId":"'+$target.InstanceId+'","AutoStart":"invalid"}'),('{"Action":"Preview","RunId":"'+$target.RunId+'","InstanceId":"'+$target.InstanceId+'","AutoStart":["on"]}'))) {Reject $body ('Body rejects before core '+$script:checks)}
    foreach($override in @(@{HttpMethod='GET'},@{ContentType='text/plain'},@{Headers=@{}},@{Headers=@{Origin='http://localhost:19499'}},@{Url=[uri]'http://127.0.0.1:19499/api/container-autostart-preview?StateRoot=x'},@{RemoteEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Parse('192.0.2.1'),19000)},@{LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::IPv6Loopback,19499)})) {Reject '{"Action":"Read"}' ('Transport veto '+$script:checks) $override}
    Reject '' 'Byte bound' @{} ([Text.Encoding]::UTF8.GetBytes('x'*2049));Reject '' 'Strict UTF8' @{} ([byte[]]@(255))
    $after=@(Get-ChildItem $root -Recurse -File|ForEach-Object {$_.FullName+':'+(Get-FileHash $_.FullName).Hash}) -join '|'
    Check ($before -ceq $after -and (& $module {$script:effects}) -eq 0) 'State bytes unchanged and forbidden effects zero'
    Write-Host "HTTP TOTAL: $script:checks PASS; 0 FAIL; ProviderMutations0; synthetic actual module/route/public/core"
} finally {
    Microsoft.PowerShell.Core\Remove-Module $module -Force
    # Recursive deletion is allowed only for this exact direct own temp child.
    $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if ([IO.Path]::GetDirectoryName($resolved) -cne $temp -or [IO.Path]::GetFileName($resolved) -cnotmatch '^SqlServerLab-AutoStartHttp-[a-f0-9]{32}$') {throw 'AUTOSTART_HTTP_CLEANUP_SCOPE'}
    if (Test-Path -LiteralPath $resolved -ErrorAction Stop) {
        $current=Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
        while ($current) {if($current.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'AUTOSTART_HTTP_CLEANUP_REPARSE'};$current=$current.Parent}
        foreach($entry in @(Get-Item -LiteralPath $resolved -Force)+@(Get-ChildItem -LiteralPath $resolved -Recurse -Force -ErrorAction Stop)) {
            if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'AUTOSTART_HTTP_CLEANUP_REPARSE'}
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
    }
}
