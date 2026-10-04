#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$root=Join-Path ([IO.Path]::GetTempPath()) ('SqlServerLab-PortConsole-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repo SqlServerLab.psd1) -Force -PassThru
try {
    & $module {
        param($Root)
        $script:checks=0
        function Assert-ConsolePort($condition,$name){if(-not $condition){throw ('PORT_CONSOLE_CHECK_FAILED: '+$name)};$script:checks++;Write-Host ('PASS: '+$name)}
        function Write-PortConsoleJson($path,$value){$null=New-Item -ItemType Directory (Split-Path $path) -Force;$value|ConvertTo-Json -Depth 60|Set-Content -LiteralPath $path -Encoding utf8}
        $dataRoot=Join-Path $Root data;$state=Join-Path $dataRoot State
        $controller=[guid]::NewGuid().ToString('D');$location=[guid]::NewGuid().ToString('D')
        Write-PortConsoleJson (Join-Path $dataRoot '.sql-server-lab-root.json') @{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId='PRIVATE_VOLUME_CANARY';DataRoot=$dataRoot}
        $catalog=Join-Path $dataRoot 'Catalog/storage-locations.json'
        Write-PortConsoleJson $catalog @{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@(@{LocationId=$location;ControllerId=$controller;LabDataRoot=$dataRoot;VolumeId='PRIVATE_VOLUME_CANARY'})}
        $tool=Join-Path $Root inspect-spy.ps1
        Set-Content $tool '$global:consoleInspectCalls++;$global:consoleInspect|ConvertTo-Json -Depth 60' -Encoding utf8
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
            if($script:cancel -ceq 'port' -and $script:prompts.Count -eq 2){return [pscustomobject]@{Status='Cancelled';Value=''}}
            [pscustomobject]@{Status='Confirmed';Value=$(if($script:prompts.Count -eq 1){$dataRoot}else{$script:requestedPort})}
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
        $actualPlan=${function:Get-SqlServerLabReconcilePlan}
        function Get-SqlServerLabReconcilePlan {
            param($RunId,$InstanceId,$StateRoot,[switch]$ContainerPortPreview,[int]$Port)
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
                'category'{$plan.Desired.PortChange='PRIVATE_CATEGORY_CANARY'}
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
            }
            $plan
        }
        function Reset-PortConsole {
            $script:planCalls=0;$global:consoleInspectCalls=0;$script:forbidden=0;$script:ack=0
            $script:cancel='';$script:forged='';$script:dtoCase='';$script:protected=$false;$script:cms=$false;$script:requestedPort='15433'
            $script:messages=[Collections.Generic.List[string]]::new();$script:menus=[Collections.Generic.List[string]]::new();$script:prompts=[Collections.Generic.List[string]]::new()
        }
        function Get-PortConsoleFiles {@(Get-ChildItem $Root -Recurse -File|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash $_.FullName).Hash}) -join '|'}
        foreach($provider in @('docker','podman')) {
            $instance=[pscustomobject]@{id='primary';provider=$provider;version='2025';profile='standard';autostart='manual';drives=@();databases=@();software=@()}
            $desired=New-LabDesiredStateSnapshot -ResolvedLab ([pscustomobject]@{name='Synthetic SQL port console';instances=@($instance)}) -ProvisioningMode adhoc -PersistentData $false
            $run=New-LabRunState -StateRoot $state -Metadata @{desiredState=$desired;persistentData=$false} -ProviderSubRuns @([pscustomobject]@{provider=$provider;instanceIds=@('primary')})
            $script:runId=$run.RunId;$path=Join-Path $run.RunDir run-state.json
            $stored=Get-Content $path -Raw|ConvertFrom-Json -Depth 60;$stored.state='RUNNING';$stored.providerSubRuns[0].state='RUNNING';Write-PortConsoleJson $path $stored
            Write-PortConsoleJson (Join-Path $run.RunDir connection-info.json) @{instances=@(@{id='primary';provider=$provider;containerId=('a'*64);containerName='PRIVATE_CONTAINER_CANARY';port=1})}
            $global:consoleInspect=[pscustomobject]@{Id=('a'*64);Image=('sha256:'+('b'*64));State=[pscustomobject]@{Running=$true};Config=[pscustomobject]@{Labels=[pscustomobject]@{'sql-server-lab.run-id'=$run.RunId;'sql-server-lab.scope-id'=$run.ScopeId;'sql-server-lab.instance-id'='primary'};Env=@('MSSQL_SA_PASSWORD=PRIVATE_SECRET_CANARY')};HostConfig=[pscustomobject]@{NanoCpus=2000000000L;Memory=2048MB;NetworkMode='PRIVATE_NETWORK_CANARY';RestartPolicy=[pscustomobject]@{Name='no'};PortBindings=[pscustomobject]@{'1433/tcp'=@([pscustomobject]@{HostIp='127.0.0.1';HostPort='14333'})}};NetworkSettings=[pscustomobject]@{Ports=[pscustomobject]@{'1433/tcp'=@([pscustomobject]@{HostIp='127.0.0.1';HostPort='14333'})};Networks=[pscustomobject]@{PRIVATE_NETWORK_CANARY=[pscustomobject]@{Aliases=@();IPAMConfig=$null}}};Mounts=@()}
            Reset-PortConsole
            $before=Get-PortConsoleFiles
            $menu=@(Show-LabWorkspaceMenu);$entry=@($menu|Where-Object Id -CEQ ContainerPortPreview)
            Assert-ConsolePort ($entry.Count -eq 1 -and $entry[0].Value -match 'PLAN_ONLY') 'Real fachmenu exposes separate port preview'
            Invoke-LabMenuAction -ActionName $entry[0].Id
            Assert-ConsolePort ($script:planCalls -eq 1 -and $global:consoleInspectCalls -eq 1 -and $script:arguments.RunId -ceq $run.RunId -and $script:arguments.InstanceId -ceq 'primary' -and $script:arguments.StateRoot -ceq $state -and $script:arguments.ContainerPortPreview -and $script:arguments.Port -eq 15433) 'Actual menu/router/dialog/public/core binds selected identity and one inspect'
            Assert-ConsolePort (($script:messages -join '|') -match 'DIFFERENT_PORT.*recreate.*REQUIRED' -and ($script:messages -join '|') -match 'CanApply=false' -and ($script:messages -join '|') -match 'Mounts: 0' -and ($script:messages -join '|') -notmatch 'PRIVATE_|14333|127.0.0.1') 'Fixed categories, zero mounts, unknown endpoint and no actual port or raw identities'
            Assert-ConsolePort ($before -ceq (Get-PortConsoleFiles) -and $script:forbidden -eq 0) 'No state write or forbidden effect'
            Reset-PortConsole;$script:requestedPort='14333';Invoke-LabMenuAction ContainerPortPreview
            Assert-ConsolePort (($script:messages -join '|') -match 'SAME_PORT.*no-op.*NONE' -and $script:planCalls -eq 1 -and $script:forbidden -eq 0) 'No-op remains one read and no Apply'
            foreach($cancel in @('root','container-port-run','container-port-instance','port')){Reset-PortConsole;$script:cancel=$cancel;Invoke-LabMenuAction ContainerPortPreview;Assert-ConsolePort ($script:planCalls -eq 0 -and $global:consoleInspectCalls -eq 0 -and $script:forbidden -eq 0) ('Cancel before plan '+$cancel)}
            foreach($value in @('q','','1023','65536','-1234','1e4','999999999999','PRIVATE_INPUT_CANARY')){Reset-PortConsole;$script:requestedPort=$value;Invoke-LabMenuAction ContainerPortPreview;Assert-ConsolePort ($script:planCalls -eq 0 -and $global:consoleInspectCalls -eq 0 -and ($script:messages -join '|') -notmatch 'PRIVATE_') ('Invalid/cancel input '+$value)}
            foreach($value in @('1024','65535')){Reset-PortConsole;$script:requestedPort=$value;Invoke-LabMenuAction ContainerPortPreview;Assert-ConsolePort ($script:planCalls -eq 1 -and $script:arguments.Port -eq [int]$value) 'Port boundary preserved'}
            foreach($screen in @('container-port-run','container-port-instance')){Reset-PortConsole;$script:forged=$screen;Invoke-LabMenuAction ContainerPortPreview;Assert-ConsolePort ($script:planCalls -eq 0) ('Forged selection blocked '+$screen)}
            foreach($case in @('contract','mode','apply','mutation','actions','reason','key','category','endpoint','mount','consistency','throw','provider','sql','backup','data-impact','mount-null','mount-owner','actions-scalar','bool-string')){Reset-PortConsole;$script:dtoCase=$case;$bytesBefore=Get-PortConsoleFiles;Invoke-LabMenuAction ContainerPortPreview;Assert-ConsolePort (($script:messages -join '|') -match 'PORT_CONSOLE_UNAVAILABLE' -and ($script:messages -join '|') -notmatch 'PRIVATE_|Gewünschter Port|DIFFERENT_PORT' -and $script:forbidden -eq 0 -and $bytesBefore -ceq (Get-PortConsoleFiles)) ('Malformed DTO/raw error failclosed '+$case)}
            foreach($protection in @('protected','cms')){Reset-PortConsole;Set-Variable -Name $protection -Scope Script -Value $true;Invoke-LabMenuAction ContainerPortPreview;Assert-ConsolePort ($script:planCalls -eq 0 -and $global:consoleInspectCalls -eq 0) ('Protected target omitted '+$protection)}
            Reset-PortConsole;$stored.state='STOPPED';Write-PortConsoleJson $path $stored;Invoke-LabMenuAction ContainerPortPreview;Assert-ConsolePort ($script:planCalls -eq 0 -and $global:consoleInspectCalls -eq 0) 'Stopped target has no implied authorization'
            Reset-PortConsole;$stored.state='RUNNING';Write-PortConsoleJson $path $stored;$global:consoleInspect.HostConfig.PortBindings=[pscustomobject]@{};Invoke-LabMenuAction ContainerPortPreview
            Assert-ConsolePort ($script:planCalls -eq 1 -and ($script:messages -join '|') -match 'blockiert' -and ($script:messages -join '|') -notmatch 'Gewünschter Port|PRIVATE_') 'Actual unsupported topology is shown with fixed unknown text'
            Reset-PortConsole;$catalogBefore=Get-Content $catalog -Raw;Write-PortConsoleJson $catalog @{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@()};Invoke-LabMenuAction ContainerPortPreview
            Assert-ConsolePort ($script:planCalls -eq 0 -and $global:consoleInspectCalls -eq 0) 'Unregistered root cannot supply a target'
            Set-Content $catalog $catalogBefore -NoNewline -Encoding utf8
            Reset-PortConsole;$stored.metadata.desiredState.Instances[0].Provider='hyperv';$stored.providerSubRuns[0].provider='hyperv';Write-PortConsoleJson $path $stored;Invoke-LabMenuAction ContainerPortPreview
            Assert-ConsolePort ($script:planCalls -eq 0 -and $global:consoleInspectCalls -eq 0) 'Hyper-V is unavailable in this separate container dialog'
            $stored.state='REMOVED';Write-PortConsoleJson $path $stored
        }
        Write-Host ('Port console: '+$script:checks+' PASS, 0 FAIL; ProviderMutations=0')
    } $root
} finally {
    Remove-Module $module -Force
    if((Test-Path $root) -and [IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $root -Leaf) -like 'SqlServerLab-PortConsole-*'){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop}
    Remove-Variable consoleInspect,consoleInspectCalls -Scope Global -ErrorAction SilentlyContinue
}
