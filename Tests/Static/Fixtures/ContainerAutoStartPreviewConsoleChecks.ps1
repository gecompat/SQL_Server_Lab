#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$root=Join-Path ([IO.Path]::GetTempPath()) ('SqlServerLab-AutoStartConsole-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repo SqlServerLab.psd1) -Force -PassThru
try {
    & $module {
        param($Root)
        $script:checks=0
        function Assert-ConsoleAutoStart($condition,$name){if(-not $condition){throw ('AUTOSTART_CONSOLE_CHECK_FAILED: '+$name)};$script:checks++;Write-Host ('PASS: '+$name)}
        function Write-AutoStartConsoleJson($path,$value){$null=New-Item -ItemType Directory (Split-Path $path) -Force;$value|ConvertTo-Json -Depth 60|Set-Content -LiteralPath $path -Encoding utf8}
        $dataRoot=Join-Path $Root data;$state=Join-Path $dataRoot State
        $controller=[guid]::NewGuid().ToString('D');$location=[guid]::NewGuid().ToString('D')
        Write-AutoStartConsoleJson (Join-Path $dataRoot '.sql-server-lab-root.json') @{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId='PRIVATE_VOLUME_CANARY';DataRoot=$dataRoot}
        $catalog=Join-Path $dataRoot 'Catalog/storage-locations.json'
        Write-AutoStartConsoleJson $catalog @{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@(@{LocationId=$location;ControllerId=$controller;LabDataRoot=$dataRoot;VolumeId='PRIVATE_VOLUME_CANARY'})}
        $tool=Join-Path $Root inspect-spy.ps1
        Set-Content $tool '$global:autoStartConsoleInspectCalls++;$global:autoStartConsoleInspect|ConvertTo-Json -Depth 60' -Encoding utf8
        function Get-LabHostToolInvocation { $tool }
        function Test-LabAutomatedTestEnvironmentRun { $script:protected }
        function Get-LabConnectionCenterCmsConfiguration {if($script:cms){[pscustomobject]@{RunId=$script:runId}}}
        function Get-LabSecret {$script:forbidden++;throw 'FORBIDDEN_SECRET'}
        function Invoke-SqlQuery {$script:forbidden++;throw 'FORBIDDEN_SQL'}
        function Test-LabEndpointBinding {$script:forbidden++;throw 'FORBIDDEN_LISTENER'}
        function Repair-LabContainerReconcileJournal {$script:forbidden++;throw 'FORBIDDEN_REPAIR'}
        function Update-SqlServerLabContainer {$script:forbidden++;throw 'FORBIDDEN_APPLY'}
        function Invoke-LabActionWithResult {$script:forbidden++;throw 'FORBIDDEN_MUTATING_WRAPPER'}
        function Read-LabConfirm {$script:forbidden++;throw 'FORBIDDEN_CONFIRM'}
        function Write-LabInfo {param($Message);$script:messages.Add([string]$Message)}
        function Write-LabWarning {param($Message);$script:messages.Add([string]$Message)}
        function Write-LabError {param($Message);$script:messages.Add([string]$Message)}
        function Wait-LabConsoleAcknowledgement {$script:ack++}
        function Read-LabConsoleTextInput {
            param($Prompt)
            $script:prompts.Add($Prompt)
            if($script:cancel -ceq 'root' -and $script:prompts.Count -eq 1){return [pscustomobject]@{Status='Cancelled';Value=''}}
            if($script:cancel -ceq 'policy' -and $script:prompts.Count -eq 2){return [pscustomobject]@{Status='Cancelled';Value=''}}
            $result=[pscustomobject]@{Status='Confirmed';Value=$null}
            if($script:prompts.Count -eq 1){$result.Value=$dataRoot}else{$result.Value=$script:requestedAutoStart}
            return $result
        }
        function Invoke-LabConsoleMenu {
            param($ScreenId,$Title,$Items)
            $script:menus.Add($ScreenId)
            if($script:cancel -ceq $ScreenId){return [pscustomobject]@{Status='Cancelled'}}
            $item=$Items[0]
            if($script:forged -ceq $ScreenId){return [pscustomobject]@{Status='Selected';SelectedItem=[pscustomobject]@{Id='foreign';Data=$item.Data}}}
            # Forged Data never replaces the locally bound item, even for a valid Id.
            [pscustomobject]@{Status='Selected';SelectedItem=[pscustomobject]@{Id=$item.Id;Data=[pscustomobject]@{RunId='foreign';InstanceId='foreign';StateRoot='PRIVATE_FOREIGN_PATH'}}}
        }
        function Show-LabSubMenu {param($ScreenId,$Title,$Subtitle,$Items);$Items}
        # Capture actual exported metadata before the public-call observation wrapper.
        $actualConsoleCatalog=@(Get-LabPublicCommandConsoleCatalog)
        $actualWebCatalog=@(Get-LabPublicCommandWebCatalog)
        $actualPlan=${function:Get-SqlServerLabReconcilePlan}
        function Get-SqlServerLabReconcilePlan {
            param($RunId,$InstanceId,$StateRoot,[switch]$ContainerAutoStartPreview,[string]$AutoStart)
            $script:planCalls++;$script:arguments=@{}+$PSBoundParameters
            if($script:dtoCase -ceq 'throw'){throw 'PRIVATE_EXCEPTION_CANARY'}
            $plan=& $actualPlan @PSBoundParameters
            switch($script:dtoCase){
                'contract'{$plan.Contract.Version='999'}
                'mode'{$plan.Mode='EXECUTE'}
                'apply'{$plan.CanApply=$true}
                'mutation'{$plan.MutationAllowed=$true}
                'actions'{$plan.Actions=@('PRIVATE_ACTION_CANARY')}
                'reason'{$plan.Reason='PRIVATE_REASON_CANARY'}
                'key'{$plan.ObservationKey='PRIVATE_KEY_CANARY'}
                'category'{$plan.Desired.AutoStartChange='PRIVATE_CATEGORY_CANARY'}
                'endpoint'{$plan.Preview.Endpoint='CHECKED'}
                'mount'{$plan.Preview.Mounts.TotalMountCount=1025}
                'consistency'{$plan.NoChange=-not $plan.NoChange}
                'provider'{$plan.Provider='hyperv'}
                'sql'{$plan.Preview.Sql='CHECKED'}
                'backup'{$plan.Preview.Backup='CHECKED'}
                'data-impact'{$plan.Preview.DataImpact='PRESERVED'}
                'mount-null'{$plan.Preview.Mounts=$null}
                'mount-owner'{$plan.Preview.Mounts.VolumeOwnership='OWNED'}
                'actions-scalar'{$plan.Actions=''}
                'bool-string'{$plan.CanApply='false'}
                'mode-array'{$plan.Mode=@($plan.Mode)}
                'reason-array'{$plan.Reason=@($plan.Reason)}
                'evidence-array'{$plan.Actual.Evidence=@($plan.Actual.Evidence)}
                'actual-array'{$plan.Actual.AutoStart=@($plan.Actual.AutoStart)}
                'desired-array'{$plan.Desired.AutoStartChange=@($plan.Desired.AutoStartChange)}
                'hostlogin'{$plan.Preview.HostLogin='CHECKED'}
            }
            $plan
        }
        function Reset-AutoStartConsole {
            $script:planCalls=0;$global:autoStartConsoleInspectCalls=0;$script:forbidden=0;$script:ack=0
            $script:cancel='';$script:forged='';$script:dtoCase='';$script:protected=$false;$script:cms=$false;$script:requestedAutoStart='on'
            $script:messages=[Collections.Generic.List[string]]::new();$script:menus=[Collections.Generic.List[string]]::new();$script:prompts=[Collections.Generic.List[string]]::new()
        }
        function Get-AutoStartConsoleFiles {@(Get-ChildItem $Root -Recurse -File|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash $_.FullName).Hash}) -join '|'}
        foreach($provider in @('docker','podman')) {
            $instance=[pscustomobject]@{id='primary';provider=$provider;version='2025';profile='standard';autostart='manual';drives=@();databases=@();software=@()}
            $desired=New-LabDesiredStateSnapshot -ResolvedLab ([pscustomobject]@{name='Synthetic SQL autostart console';instances=@($instance)}) -ProvisioningMode adhoc -PersistentData $false
            $run=New-LabRunState -StateRoot $state -Metadata @{desiredState=$desired;persistentData=$false} -ProviderSubRuns @([pscustomobject]@{provider=$provider;instanceIds=@('primary')})
            $script:runId=$run.RunId;$path=Join-Path $run.RunDir run-state.json
            $stored=Get-Content $path -Raw|ConvertFrom-Json -Depth 60;$stored.state='RUNNING';$stored.providerSubRuns[0].state='RUNNING';Write-AutoStartConsoleJson $path $stored
            Write-AutoStartConsoleJson (Join-Path $run.RunDir connection-info.json) @{instances=@(@{id='primary';provider=$provider;containerId=('a'*64);containerName='PRIVATE_CONTAINER_CANARY';port=1})}
            $global:autoStartConsoleInspect=[pscustomobject]@{Id=('a'*64);Image=('sha256:'+('b'*64));State=[pscustomobject]@{Running=$true};Config=[pscustomobject]@{Labels=[pscustomobject]@{'sql-server-lab.run-id'=$run.RunId;'sql-server-lab.scope-id'=$run.ScopeId;'sql-server-lab.instance-id'='primary';'sql-server-lab.autostart'='off'};Env=@('MSSQL_SA_PASSWORD=PRIVATE_SECRET_CANARY')};HostConfig=[pscustomobject]@{NanoCpus=2000000000L;Memory=2048MB;NetworkMode='PRIVATE_NETWORK_CANARY';RestartPolicy=[pscustomobject]@{Name='no'};PortBindings=[pscustomobject]@{'1433/tcp'=@([pscustomobject]@{HostIp='127.0.0.1';HostPort='14333'})}};NetworkSettings=[pscustomobject]@{Ports=[pscustomobject]@{'1433/tcp'=@([pscustomobject]@{HostIp='127.0.0.1';HostPort='14333'})};Networks=[pscustomobject]@{PRIVATE_NETWORK_CANARY=[pscustomobject]@{Aliases=@();IPAMConfig=$null}}};Mounts=@()}
            Reset-AutoStartConsole
            $before=Get-AutoStartConsoleFiles
            $menu=@(Show-LabWorkspaceMenu);$entry=@($menu|Where-Object Id -CEQ ContainerAutoStartPreview)
            Assert-ConsoleAutoStart ($entry.Count -eq 1 -and $entry[0].Value -match 'PLAN_ONLY') 'Real fachmenu exposes separate autostart preview'
            Invoke-LabMenuAction -ActionName $entry[0].Id
            Assert-ConsoleAutoStart ($script:planCalls -eq 1 -and $global:autoStartConsoleInspectCalls -eq 1 -and $script:arguments.RunId -ceq $run.RunId -and $script:arguments.InstanceId -ceq 'primary' -and $script:arguments.StateRoot -ceq $state -and $script:arguments.ContainerAutoStartPreview -and $script:arguments.AutoStart -ceq 'on') 'Actual menu/router/dialog/public/core binds selected identity and one inspect'
            Assert-ConsoleAutoStart (($script:messages -join '|') -match 'DIFFERENT_POLICY.*recreate.*REQUIRED' -and ($script:messages -join '|') -match 'CanApply=false' -and ($script:messages -join '|') -match 'Mounts: 0' -and ($script:messages -join '|') -notmatch 'PRIVATE_|14333|127.0.0.1') 'Fixed categories, zero mounts, unknown endpoint and no actual port or raw identities'
            Assert-ConsoleAutoStart ($before -ceq (Get-AutoStartConsoleFiles) -and $script:forbidden -eq 0) 'No state write or forbidden effect'
            Reset-AutoStartConsole;Invoke-LabAction -ActionName ContainerAutoStartPreview
            Assert-ConsoleAutoStart ($script:planCalls -eq 1 -and $script:forbidden -eq 0) 'Actual legacy switch route invokes the dedicated read-only dialog'
            $help=Get-LabConsoleHelpCatalog
            Assert-ConsoleAutoStart ($help.ContainsKey('container-autostart-run') -and $help.ContainsKey('container-autostart-instance') -and $help['container-autostart-instance'].Effects -match 'CanApply=false') 'Actual help entries describe PLAN_ONLY and cancellation'
            $command=@($actualConsoleCatalog|Where-Object Name -ceq 'Get-SqlServerLabReconcilePlan')[0]
            $set=@($command.ParameterSets|Where-Object Name -ceq 'ContainerAutoStartPreview')
            $descriptors=@(Get-LabPublicCommandParameterDescriptor -Command $command.Command -ParameterSet $set[0].Metadata)
            $web=@($actualWebCatalog|Where-Object Name -ceq $command.Name)[0]
            Assert-ConsoleAutoStart ($set.Count -eq 1 -and (@($set[0].MandatoryNames|Sort-Object) -join '|') -ceq 'AutoStart|ContainerAutoStartPreview|InstanceId|RunId' -and (($descriptors|Where-Object Name -ceq 'AutoStart').AllowedValues -ceq 'Werte: on, off') -and $web.RequiresConfirmation -eq $false) 'Actual generic catalogs preserve mandatory on/off read-only contract'
            Reset-AutoStartConsole;$script:requestedAutoStart='off';Invoke-LabMenuAction ContainerAutoStartPreview
            Assert-ConsoleAutoStart (($script:messages -join '|') -match 'SAME_POLICY.*no-op.*NONE' -and $script:planCalls -eq 1 -and $script:forbidden -eq 0) 'No-op remains one read and no Apply'
            foreach($cancel in @('root','container-autostart-run','container-autostart-instance','policy')){Reset-AutoStartConsole;$script:cancel=$cancel;Invoke-LabMenuAction ContainerAutoStartPreview;Assert-ConsoleAutoStart ($script:planCalls -eq 0 -and $global:autoStartConsoleInspectCalls -eq 0 -and $script:forbidden -eq 0) ('Cancel before plan '+$cancel)}
            foreach($value in @('q','Q','','yes',' on','off ','1','PRIVATE_INPUT_CANARY')){Reset-AutoStartConsole;$script:requestedAutoStart=$value;Invoke-LabMenuAction ContainerAutoStartPreview;Assert-ConsoleAutoStart ($script:planCalls -eq 0 -and $global:autoStartConsoleInspectCalls -eq 0 -and ($script:messages -join '|') -notmatch 'PRIVATE_') ('Invalid/cancel input '+$value)}
            Reset-AutoStartConsole;$script:requestedAutoStart=@('on');Invoke-LabMenuAction ContainerAutoStartPreview
            Assert-ConsoleAutoStart ($script:planCalls -eq 0 -and $global:autoStartConsoleInspectCalls -eq 0) 'Array input is not a scalar desired policy'
            foreach($value in @('on','off','ON','OFF')){Reset-AutoStartConsole;$script:requestedAutoStart=$value;Invoke-LabMenuAction ContainerAutoStartPreview;Assert-ConsoleAutoStart ($script:planCalls -eq 1 -and $script:arguments.AutoStart -ceq $value.ToLowerInvariant()) 'Case-normalized desired policy'}
            foreach($screen in @('container-autostart-run','container-autostart-instance')){Reset-AutoStartConsole;$script:forged=$screen;Invoke-LabMenuAction ContainerAutoStartPreview;Assert-ConsoleAutoStart ($script:planCalls -eq 0) ('Forged selection blocked '+$screen)}
            foreach($case in @('contract','mode','apply','mutation','actions','reason','key','category','endpoint','mount','consistency','throw','provider','sql','backup','data-impact','mount-null','mount-owner','actions-scalar','bool-string','mode-array','reason-array','evidence-array','actual-array','desired-array','hostlogin')){Reset-AutoStartConsole;$script:dtoCase=$case;$bytesBefore=Get-AutoStartConsoleFiles;Invoke-LabMenuAction ContainerAutoStartPreview;Assert-ConsoleAutoStart (($script:messages -join '|') -match 'AUTOSTART_CONSOLE_UNAVAILABLE' -and ($script:messages -join '|') -notmatch 'PRIVATE_|Istpolicy: OFF|DIFFERENT_POLICY' -and $script:forbidden -eq 0 -and $bytesBefore -ceq (Get-AutoStartConsoleFiles)) ('Malformed DTO/raw error failclosed '+$case)}
            Reset-AutoStartConsole;$global:autoStartConsoleInspect.Config.Labels.'sql-server-lab.autostart'='on';Invoke-LabMenuAction ContainerAutoStartPreview
            Assert-ConsoleAutoStart ($script:planCalls -eq 1 -and ($script:messages -join '|') -match 'blockiert.*DRIFTED' -and $script:forbidden -eq 0) 'Actual drift is blocked and shown as DRIFTED, never measured ON'
            $global:autoStartConsoleInspect.Config.Labels.'sql-server-lab.autostart'='off'
            foreach($protection in @('protected','cms')){Reset-AutoStartConsole;Set-Variable -Name $protection -Scope Script -Value $true;Invoke-LabMenuAction ContainerAutoStartPreview;Assert-ConsoleAutoStart ($script:planCalls -eq 0 -and $global:autoStartConsoleInspectCalls -eq 0) ('Protected target omitted '+$protection)}
            foreach($badBinding in @('legacy','foreign-run','foreign-scope')){
                Reset-AutoStartConsole;$validRunJson=Get-Content -LiteralPath $path -Raw
                $invalidRun=$validRunJson|ConvertFrom-Json -Depth 60
                switch($badBinding){'legacy'{$invalidRun.contractVersion='legacy'};'foreign-run'{$invalidRun.runId=[guid]::NewGuid().ToString('D')};'foreign-scope'{$invalidRun.scopeId=[guid]::NewGuid().ToString('D')}}
                Write-AutoStartConsoleJson $path $invalidRun;Invoke-LabMenuAction ContainerAutoStartPreview
                Assert-ConsoleAutoStart ($script:planCalls -eq 0 -and $global:autoStartConsoleInspectCalls -eq 0 -and $script:forbidden -eq 0) ('Actual metadata binding rejects '+$badBinding)
                Set-Content -LiteralPath $path -Value $validRunJson -NoNewline -Encoding utf8
            }
            Reset-AutoStartConsole;$stored.state='STOPPED';Write-AutoStartConsoleJson $path $stored;Invoke-LabMenuAction ContainerAutoStartPreview;Assert-ConsoleAutoStart ($script:planCalls -eq 0 -and $global:autoStartConsoleInspectCalls -eq 0) 'Stopped target has no implied authorization'
            Reset-AutoStartConsole;$stored.state='RUNNING';Write-AutoStartConsoleJson $path $stored;$global:autoStartConsoleInspect.HostConfig.PortBindings=[pscustomobject]@{};Invoke-LabMenuAction ContainerAutoStartPreview
            Assert-ConsoleAutoStart ($script:planCalls -eq 1 -and ($script:messages -join '|') -match 'blockiert' -and ($script:messages -join '|') -notmatch 'Wunsch:|PRIVATE_') 'Actual unsupported topology is shown with fixed unknown text'
            Reset-AutoStartConsole;$catalogBefore=Get-Content $catalog -Raw;Write-AutoStartConsoleJson $catalog @{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@()};Invoke-LabMenuAction ContainerAutoStartPreview
            Assert-ConsoleAutoStart ($script:planCalls -eq 0 -and $global:autoStartConsoleInspectCalls -eq 0) 'Unregistered root cannot supply a target'
            Set-Content $catalog $catalogBefore -NoNewline -Encoding utf8
            Reset-AutoStartConsole;$stored.metadata.desiredState.Instances[0].Provider='hyperv';$stored.providerSubRuns[0].provider='hyperv';Write-AutoStartConsoleJson $path $stored;Invoke-LabMenuAction ContainerAutoStartPreview
            Assert-ConsoleAutoStart ($script:planCalls -eq 0 -and $global:autoStartConsoleInspectCalls -eq 0) 'Hyper-V is unavailable in this separate container dialog'
            $stored.state='REMOVED';Write-AutoStartConsoleJson $path $stored
        }
        Write-Host ('AutoStart console: '+$script:checks+' PASS, 0 FAIL; ProviderMutations=0')
    } $root
} finally {
    Remove-Module $module -Force
    if(Test-Path -LiteralPath $root -ErrorAction Stop){
        $base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        $full=[IO.Path]::GetFullPath($root)
        if((Split-Path $full -Parent) -cne $base -or (Split-Path $full -Leaf) -cnotmatch '^SqlServerLab-AutoStartConsole-[a-f0-9]{32}$'){throw 'AUTOSTART_FIXTURE_CLEANUP_SCOPE'}
        $items=@(Get-Item -LiteralPath $full -Force -ErrorAction Stop)+@(Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction Stop)
        foreach($item in $items){if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'AUTOSTART_FIXTURE_CLEANUP_REPARSE'}}
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    }
    Remove-Variable autoStartConsoleInspect,autoStartConsoleInspectCalls -Scope Global -ErrorAction SilentlyContinue
}
