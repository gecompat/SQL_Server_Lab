# Explicit readonly inspection of one existing managed CMS. No sync or export.
function New-LabCmsInspectionResult {
    param([string]$Status='UNKNOWN',[string]$Code='CMS_INSPECTION_UNKNOWN',$Selection=$null,$Observation=$null)
    [pscustomobject][ordered]@{ContractVersion='SqlServerLab.CmsInspection/1.0';Status=$Status;Code=$Code
        RunId=$(if($Selection){$Selection.RunId}else{$null});InstanceId=$(if($Selection){$Selection.InstanceId}else{$null});Provider=$(if($Selection){$Selection.Provider}else{$null})
        SelectionKey=$(if($Selection){$Selection.Key}else{$null});ObservedAt=$(if($Status -ne 'NOT_CHECKED' -and $Status -ne 'NOT_CONFIGURED'){[datetime]::UtcNow.ToString('o')}else{$null})
        SqlMajor=$(if($Observation){$Observation.SqlMajor}else{$null});ManagedGroupCount=$(if($Observation){$Observation.ManagedGroupCount}else{$null});ManagedServerCount=$(if($Observation){$Observation.ManagedServerCount}else{$null})
        Notice='Nur lesende Prüfung des registrierten CMS und seiner markierten Metadaten. Keine Synchronisation, Änderung oder Verbindung zu Mitgliedsservern; keine SSMS- oder vollständige CMS-Abnahme.'}
}

function Get-LabCmsInspectionSelection {
    param([string]$StateRoot)
    if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $configPath=Join-Path $StateRoot 'catalog/sql-connection-center-cms.json'
    if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){return $null}
    Assert-LabCmsInspectionReadPath -Root $StateRoot -Path $configPath
    $configBefore=(Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    $config=Get-LabConnectionCenterCmsConfiguration -StateRoot $StateRoot
    if($config.ContractVersion -cnotin @('SqlServerLab.ConnectionCenterCms/1.0','SqlServerLab.ConnectionCenterCms/1.1') -or
        $config.Provider -isnot [string] -or $config.RunId -isnot [string] -or $config.RunId -cnotmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' -or $config.Provider -cnotin @('docker','podman','hyperv')){throw 'CMS_INSPECTION_CONFIGURATION_INVALID'}
    $runPath=Join-Path $StateRoot ('runs/'+$config.RunId+'/run-state.json')
    $connectionPath=Join-Path $StateRoot ('runs/'+$config.RunId+'/connection-info.json')
    Assert-LabCmsInspectionReadPath -Root $StateRoot -Path $runPath
    Assert-LabCmsInspectionReadPath -Root $StateRoot -Path $connectionPath
    $runBefore=(Get-FileHash -LiteralPath $runPath -Algorithm SHA256).Hash
    $connectionBefore=(Get-FileHash -LiteralPath $connectionPath -Algorithm SHA256).Hash
    $layoutPath=Join-Path $StateRoot 'catalog/sql-connection-center-groups.json'
    $layoutBefore=if(Test-Path -LiteralPath $layoutPath -PathType Leaf){Assert-LabCmsInspectionReadPath -Root $StateRoot -Path $layoutPath;(Get-FileHash -LiteralPath $layoutPath -Algorithm SHA256).Hash}else{'ABSENT'}
    if(Test-Path -LiteralPath $layoutPath -PathType Leaf){
        $rawLayout=Get-Content -LiteralPath $layoutPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 10 -ErrorAction Stop
        if($rawLayout.ContractVersion -cnotin @('SqlServerLab.ConnectionCenterGroups/1.0','SqlServerLab.ConnectionCenterGroups/1.1','SqlServerLab.ConnectionCenterGroups/1.2') -or
            ($null -ne $rawLayout.CmsUseRootGroup -and $rawLayout.CmsUseRootGroup -isnot [bool])){throw 'CMS_INSPECTION_CONFIGURATION_INVALID'}
    }
    $layout=Get-LabConnectionCenterConfiguration -StateRoot $StateRoot
    $run=Get-LabRunState -RunId $config.RunId -StateRoot $StateRoot
    $connection=Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 20
    $instances=@($connection.instances|Where-Object {[string]$_.id -ceq 'primary'})
    if($instances.Count -ne 1 -or [string]$run.runId -cne $config.RunId -or [string]$connection.runId -cne $config.RunId -or
        [string]::IsNullOrWhiteSpace([string]$run.scopeId) -or [string]$connection.scopeId -cne [string]$run.scopeId -or [string]$instances[0].provider -cne [string]$config.Provider){throw 'CMS_INSPECTION_BINDING_UNVERIFIED'}
    $layoutPath=Join-Path $StateRoot 'catalog/sql-connection-center-groups.json'
    $files=@($configPath,$runPath,$connectionPath)
    $hashes=@($files|ForEach-Object {(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()})
    $hashes+=if(Test-Path -LiteralPath $layoutPath -PathType Leaf){(Get-FileHash -LiteralPath $layoutPath -Algorithm SHA256).Hash.ToLowerInvariant()}else{'ABSENT'}
    if($hashes[0] -ine $configBefore -or $hashes[1] -ine $runBefore -or $hashes[2] -ine $connectionBefore -or $hashes[3] -ine $layoutBefore){throw 'CMS_INSPECTION_SELECTION_CHANGED'}
    $canonicalRoot=[IO.Path]::GetFullPath($StateRoot).TrimEnd('\','/')
    if($IsWindows){$canonicalRoot=$canonicalRoot.ToUpperInvariant()}
    $key=Get-LabSetupWriteProbeDigest ([ordered]@{Contract='SqlServerLab.CmsInspection/1.0';StateRoot=$canonicalRoot;FileHashes=$hashes}|ConvertTo-Json -Compress)
    [pscustomobject]@{RunId=$config.RunId;InstanceId='primary';Provider=$config.Provider;Key=$key;StateRoot=$StateRoot;Run=$run;Instance=$instances[0];Layout=$layout}
}

function Get-LabCmsInspectionState {
    try {$selection=Get-LabCmsInspectionSelection;if(-not $selection){return New-LabCmsInspectionResult -Status NOT_CONFIGURED -Code CMS_INSPECTION_NOT_CONFIGURED}
        New-LabCmsInspectionResult -Status NOT_CHECKED -Code CMS_INSPECTION_NOT_CHECKED -Selection $selection
    }catch{New-LabCmsInspectionResult -Code CMS_INSPECTION_BINDING_UNVERIFIED}
}

function Get-LabCmsInspectionRuntimeBinding {
    param([Parameter(Mandatory)]$Selection)
    if($Selection.Provider -cnotin @('docker','podman')){throw 'CMS_INSPECTION_PROVIDER_UNSUPPORTED'}
    $instance=$Selection.Instance
    if([string]$Selection.Run.state -cne 'RUNNING'){throw 'CMS_INSPECTION_NOT_RUNNING'}
    if([string]$instance.containerId -cnotmatch '^[a-f0-9]{64}$' -or [string]$instance.host -cnotin @('127.0.0.1','::1','localhost') -or
        [int]$instance.port -lt 1 -or [int]$instance.port -gt 65535 -or [string]$instance.version -cnotin @('2019','2022','2025')){throw 'CMS_INSPECTION_BINDING_UNVERIFIED'}
    # Resolve the namespace only; do not inspect physical runtime backing/WSL.
    $evidence=Get-LabContainerRuntimeScopeEvidence -Provider $Selection.Provider
    $scope=ConvertTo-LabContainerRuntimeScope -Evidence $evidence
    if($scope.Status -cne 'AVAILABLE' -or [string]::IsNullOrWhiteSpace([string]$scope.RuntimeId) -or $scope.Binding.EndpointKind -cnotin @('LOCAL_NPIPE','LOCAL_UNIX','LOCAL_MACHINE_SSH')){throw 'CMS_INSPECTION_RUNTIME_UNVERIFIED'}
    $nativeIdentity=if($Selection.Provider -ceq 'docker'){
        if([string]::IsNullOrWhiteSpace([string]$evidence.Info.ID)){throw 'CMS_INSPECTION_RUNTIME_UNVERIFIED'}
        [ordered]@{EngineId=[string]$evidence.Info.ID}
    }else{
        if([string]::IsNullOrWhiteSpace([string]$evidence.Info.Host.Hostname) -or [string]::IsNullOrWhiteSpace([string]$evidence.Info.Version.Version) -or [string]::IsNullOrWhiteSpace([string]$evidence.Info.Store.GraphRoot)){throw 'CMS_INSPECTION_RUNTIME_UNVERIFIED'}
        [ordered]@{Host=[string]$evidence.Info.Host.Hostname;Version=[string]$evidence.Info.Version.Version;GraphRoot=[string]$evidence.Info.Store.GraphRoot}
    }
    $tool=Get-LabHostToolInvocation -Name $Selection.Provider
    $json=@(& $tool inspect ([string]$instance.containerId) 2>$null)
    if($LASTEXITCODE -ne 0){throw 'CMS_INSPECTION_RUNTIME_UNVERIFIED'}
    $containers=@(($json -join "`n")|ConvertFrom-Json -Depth 30)
    if($containers.Count -ne 1){throw 'CMS_INSPECTION_RUNTIME_UNVERIFIED'}
    $container=$containers[0];$labels=$container.Config.Labels
    if([string]$container.Id -cne [string]$instance.containerId -or $container.State.Running -ne $true -or
        [string]$labels.'sql-server-lab.run-id' -cne $Selection.RunId -or [string]$labels.'sql-server-lab.scope-id' -cne [string]$Selection.Run.scopeId -or
        [string]$labels.'sql-server-lab.instance-id' -cne $Selection.InstanceId){throw 'CMS_INSPECTION_RUNTIME_UNVERIFIED'}
    $ports=@($container.NetworkSettings.Ports.'1433/tcp')
    if($ports.Count -ne 1 -or [int]$ports[0].HostPort -ne [int]$instance.port -or [string]$ports[0].HostIp -cnotin @('127.0.0.1','::1')){throw 'CMS_INSPECTION_ENDPOINT_UNVERIFIED'}
    $address=[string]$ports[0].HostIp
    if([string]$instance.host -cne 'localhost' -and [string]$instance.host -cne $address){throw 'CMS_INSPECTION_ENDPOINT_UNVERIFIED'}
    $binding=[ordered]@{SelectionKey=$Selection.Key;RuntimeScopeId=$scope.RuntimeId;NativeIdentity=$nativeIdentity;ContainerId=$container.Id;ScopeId=$Selection.Run.scopeId;Address=$address;Port=[int]$instance.port;Version=$instance.version}
    [pscustomobject]@{Key=(Get-LabSetupWriteProbeDigest ($binding|ConvertTo-Json -Compress));HostName=$address;Port=[int]$instance.port;ExpectedMajor=(@{'2019'=15;'2022'=16;'2025'=17}[[string]$instance.version]);UseRootGroup=[bool]$Selection.Layout.CmsUseRootGroup}
}

function Invoke-LabCmsInspectionSql {
    param([Parameter(Mandatory)]$Binding,[Parameter(Mandatory)][SecureString]$Secret)
    if(-not $Secret.IsReadOnly()){$Secret.MakeReadOnly()}
    $connection=[Data.SqlClient.SqlConnection]::new();$command=$null;$reader=$null
    try {
        $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new()
        $builder['Data Source']=$Binding.HostName+','+$Binding.Port;$builder['Initial Catalog']='msdb';$builder['Encrypt']=$true;$builder['TrustServerCertificate']=$true
        $builder['Connect Timeout']=3;$builder['Pooling']=$false;$builder['Persist Security Info']=$false;$builder['Application Name']='SqlServerLab.CmsReadonlyInspection'
        $connection.ConnectionString=$builder.ConnectionString;$connection.Credential=[Data.SqlClient.SqlCredential]::new('sa',$Secret)
        $command=$connection.CreateCommand();$command.CommandTimeout=5
        # Counts only: optional generated password aliases may be CMS node names.
        $command.CommandText=@"
SELECT CONVERT(int,SERVERPROPERTY('ProductMajorVersion')) AS SqlMajor,
 (SELECT COUNT_BIG(*) FROM msdb.dbo.sysmanagement_shared_server_groups WHERE description LIKE N'ManagedBy=SQL[_]Server[_]Lab;Contract=%;Role=Root%') AS ManagedRootCount,
 (SELECT COUNT_BIG(*) FROM msdb.dbo.sysmanagement_shared_server_groups WHERE description LIKE N'ManagedBy=SQL[_]Server[_]Lab;Contract=%') AS ManagedGroupCount,
 (SELECT COUNT_BIG(*) FROM msdb.dbo.sysmanagement_shared_registered_servers WHERE description LIKE N'ManagedBy=SQL[_]Server[_]Lab;Contract=%;Identity=%') AS ManagedServerCount;
"@
        $connection.Open();$reader=$command.ExecuteReader()
        if(-not $reader.Read()){throw 'CMS_INSPECTION_SQL_RESULT_INVALID'}
        $observation=[pscustomobject]@{SqlMajor=$reader.GetInt32(0);ManagedRootCount=$reader.GetInt64(1);ManagedGroupCount=$reader.GetInt64(2);ManagedServerCount=$reader.GetInt64(3)}
        if($reader.Read() -or $reader.NextResult()){throw 'CMS_INSPECTION_SQL_RESULT_INVALID'}
        $observation
    } finally {if($reader){$reader.Dispose()};if($command){$command.Dispose()};$connection.Dispose()}
}

function Invoke-LabCmsInspectionWorkerCore {
    param([Parameter(Mandatory)][string]$ExpectedPlanKey)
    $secret=$null;$selection=$null
    try {
        $selection=Get-LabCmsInspectionSelection
        if(-not $selection -or $selection.Key -cne $ExpectedPlanKey){throw 'CMS_INSPECTION_SELECTION_CHANGED'}
        $binding=Get-LabCmsInspectionRuntimeBinding -Selection $selection
        Assert-LabCmsInspectionReadPath -Root $selection.StateRoot -Path (Join-Path $selection.StateRoot ('runs/'+$selection.RunId+'/secrets/sa-password.secret'))
        $secret=Get-LabSecret -Path (Join-Path $selection.StateRoot ('runs/'+$selection.RunId)) -Name 'sa-password'
        if($secret -isnot [Security.SecureString]){throw 'CMS_INSPECTION_SECRET_UNAVAILABLE'}
        $observation=Invoke-LabCmsInspectionSql -Binding $binding -Secret $secret
        $after=Get-LabCmsInspectionSelection
        if(-not $after -or $after.Key -cne $selection.Key -or (Get-LabCmsInspectionRuntimeBinding -Selection $after).Key -cne $binding.Key){throw 'CMS_INSPECTION_BINDING_CHANGED'}
        if($observation.SqlMajor -ne $binding.ExpectedMajor -or $observation.ManagedRootCount -lt 0 -or $observation.ManagedRootCount -gt 1 -or
            ($binding.UseRootGroup -and $observation.ManagedRootCount -ne 1) -or $observation.ManagedGroupCount -isnot [long] -or $observation.ManagedServerCount -isnot [long] -or
            $observation.ManagedGroupCount -lt 0 -or $observation.ManagedServerCount -lt 0 -or $observation.ManagedGroupCount -gt 9007199254740991 -or $observation.ManagedServerCount -gt 9007199254740991){throw 'CMS_INSPECTION_SQL_RESULT_INVALID'}
        New-LabCmsInspectionResult -Status OBSERVED -Code CMS_INSPECTION_OBSERVED -Selection $selection -Observation $observation
    } catch {
        $code=if($_.Exception.Message -cin (Get-LabCmsInspectionResultCodes)){$_.Exception.Message}else{'CMS_INSPECTION_READ_FAILED'}
        New-LabCmsInspectionResult -Code $code -Selection $selection
    } finally {if($secret){$secret.Dispose()}}
}

function Invoke-LabCmsInspection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedPlanKey,[ValidateRange(1000,20000)][int]$TimeoutMilliseconds=20000)
    $process=$null;$started=$false;$result=$null
    try {
        $selection=Get-LabCmsInspectionSelection
        if(-not $selection -or $selection.Key -cne $ExpectedPlanKey){throw 'CMS_INSPECTION_SELECTION_CHANGED'}
        $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Command pwsh -ErrorAction Stop).Source;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $script:ModuleRoot 'Tools/Read-CmsInspection.ps1'),'-ExpectedPlanKey',$ExpectedPlanKey)){$start.ArgumentList.Add($argument)}
        $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$started=$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($TimeoutMilliseconds)){throw 'CMS_INSPECTION_TIMEOUT'}
        if(-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),2000)){throw 'CMS_INSPECTION_STREAM_UNCONFIRMED'}
        $json=$stdout.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0 -or $json.Length -gt 8192){throw 'CMS_INSPECTION_RESULT_INVALID'}
        $document=[Text.Json.JsonDocument]::Parse([string]$json)
        try {
            $properties=@($document.RootElement.EnumerateObject())
            if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object -or $properties.Count -ne 12 -or @($properties.Name|Sort-Object -Unique).Count -ne 12){throw 'CMS_INSPECTION_RESULT_INVALID'}
            $timestampText=$document.RootElement.GetProperty('ObservedAt').GetString()
            $dto=$json|ConvertFrom-Json -Depth 5 -ErrorAction Stop;$dto.ObservedAt=$timestampText
        } finally {$document.Dispose()}
        $time=[datetimeoffset]::MinValue
        if($dto.ContractVersion -cne 'SqlServerLab.CmsInspection/1.0' -or $dto.RunId -cne $selection.RunId -or $dto.InstanceId -cne $selection.InstanceId -or $dto.Provider -cne $selection.Provider -or $dto.SelectionKey -cne $ExpectedPlanKey -or
            $dto.Status -cnotin @('OBSERVED','UNKNOWN') -or $dto.Code -cnotin (Get-LabCmsInspectionResultCodes) -or
            -not [datetimeoffset]::TryParse($timestampText,[ref]$time) -or $time.Offset -ne [timespan]::Zero -or $time.UtcDateTime -gt [datetime]::UtcNow.AddSeconds(5) -or $time.UtcDateTime -lt [datetime]::UtcNow.AddMinutes(-1) -or
            @($dto.PSObject.Properties.Name|Where-Object {$_ -cnotin @('ContractVersion','Status','Code','RunId','InstanceId','Provider','SelectionKey','ObservedAt','SqlMajor','ManagedGroupCount','ManagedServerCount','Notice')}).Count){throw 'CMS_INSPECTION_RESULT_INVALID'}
        $observation=$null
        if($dto.Status -ceq 'OBSERVED') {
            if($dto.Code -cne 'CMS_INSPECTION_OBSERVED' -or $dto.SqlMajor -notin @(15,16,17) -or $dto.ManagedGroupCount -isnot [long] -or $dto.ManagedServerCount -isnot [long] -or $dto.ManagedGroupCount -lt 0 -or $dto.ManagedServerCount -lt 0 -or
                $dto.ManagedGroupCount -gt 9007199254740991 -or $dto.ManagedServerCount -gt 9007199254740991){throw 'CMS_INSPECTION_RESULT_INVALID'}
            $observation=$dto
        } elseif($dto.Code -ceq 'CMS_INSPECTION_OBSERVED' -or $null -ne $dto.SqlMajor -or $null -ne $dto.ManagedGroupCount -or $null -ne $dto.ManagedServerCount){throw 'CMS_INSPECTION_RESULT_INVALID'}
        $after=Get-LabCmsInspectionSelection
        if(-not $after -or $after.Key -cne $selection.Key){throw 'CMS_INSPECTION_SELECTION_CHANGED'}
        $result=New-LabCmsInspectionResult -Status $dto.Status -Code $dto.Code -Selection $selection -Observation $observation
        $result.ObservedAt=$timestampText
    } catch {
        $code=if($_.Exception.Message -cin (Get-LabCmsInspectionResultCodes)){[string]$_.Exception.Message}else{'CMS_INSPECTION_READ_FAILED'}
        $result=New-LabCmsInspectionResult -Code $code -Selection $selection
    } finally {
        if($process){
            try {if($started -and -not $process.HasExited){$process.Kill($true);if(-not $process.WaitForExit(2000)){throw 'OWN_WORKER_NOT_TERMINATED'}}}
            catch {$result=New-LabCmsInspectionResult -Code CMS_INSPECTION_WORKER_TERMINATION_UNCONFIRMED -Selection $selection}
            finally {try{$process.Dispose()}catch{$result=New-LabCmsInspectionResult -Code CMS_INSPECTION_WORKER_TERMINATION_UNCONFIRMED -Selection $selection}}
        }
    }
    $result
}

function Get-LabCmsInspectionResultCodes {
    @('CMS_INSPECTION_OBSERVED','CMS_INSPECTION_UNKNOWN','CMS_INSPECTION_CONFIGURATION_INVALID','CMS_INSPECTION_BINDING_UNVERIFIED','CMS_INSPECTION_PROVIDER_UNSUPPORTED','CMS_INSPECTION_NOT_RUNNING','CMS_INSPECTION_RUNTIME_UNVERIFIED','CMS_INSPECTION_ENDPOINT_UNVERIFIED','CMS_INSPECTION_SECRET_UNAVAILABLE','CMS_INSPECTION_SELECTION_CHANGED','CMS_INSPECTION_BINDING_CHANGED','CMS_INSPECTION_SQL_RESULT_INVALID','CMS_INSPECTION_READ_FAILED','CMS_INSPECTION_TIMEOUT','CMS_INSPECTION_RESULT_INVALID','CMS_INSPECTION_STREAM_UNCONFIRMED','CMS_INSPECTION_WORKER_TERMINATION_UNCONFIRMED')
}
function Format-LabCmsInspection {
    param($Result)
    if($Result.Status -ceq 'OBSERVED') { return ('CMS gelesen · SQL-Major {0} · markierte Gruppen: {1} · markierte Server: {2} · {3}' -f $Result.SqlMajor,$Result.ManagedGroupCount,$Result.ManagedServerCount,$Result.ObservedAt) }
    if($Result.Status -ceq 'NOT_CONFIGURED'){return 'Kein verwalteter CMS registriert. Diese Prüfung richtet keinen CMS ein.'}
    if($Result.Status -ceq 'NOT_CHECKED'){return 'CMS registriert; noch nicht geprüft. Die Prüfung liest nur diesen CMS.'}
    if($Result.Code -ceq 'CMS_INSPECTION_PROVIDER_UNSUPPORTED'){return 'Diese lesende Prüfung unterstützt derzeit nur einen lokal gebundenen Docker-/Podman-CMS; Hyper-V bleibt ungeprüft.'}
    return 'CMS-Befund unbekannt. Registrierung, laufenden CMS und Zugriff prüfen; anschließend erneut auswählen. Es wurde nichts synchronisiert.'
}

function Invoke-LabCmsInspectionInteractive {
    $view=(Invoke-SqlServerLabWorkflowAction -Action GetCmsInspectionState).Result
    $select=Invoke-LabConsoleMenu -ScreenId 'cms-readonly-inspection' -Title 'Registrierten CMS lesend prüfen' -Subtitle (Format-LabCmsInspection $view) -Items @(
        New-LabConsoleItem -Id inspect -Label 'Registrierten CMS jetzt lesend prüfen' -Value $(if($view.RunId){$view.Provider+' · Run '+$view.RunId}else{'kein gültiges Ziel'}) -Shortcut 1 -Disabled:($view.Status -cne 'NOT_CHECKED' -or $view.Provider -cnotin @('docker','podman')) -DisabledReason 'Eine eindeutige lokale Docker-/Podman-CMS-Registrierung ist erforderlich.'
        New-LabConsoleItem -Id back -Label 'Zurück' -Shortcut 0
    ) -Footer 'Enter: Auswahl · Escape/0: Abbruch ohne SQL-Abfrage'
    if($select.Status -ne 'Selected' -or $select.SelectedItem.Id -cne 'inspect'){return}
    $result=(Invoke-SqlServerLabWorkflowAction -Action InspectCms -ExpectedPlanKey $view.SelectionKey).Result
    Write-LabInfo (Format-LabCmsInspection $result);Write-LabInfo $result.Notice
    $null=Wait-LabConsoleAcknowledgement -Prompt 'Enter oder Escape: Zurück'
}
function Assert-LabCmsInspectionReadPath {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Path)
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $pathFull=[IO.Path]::GetFullPath($Path)
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not $pathFull.StartsWith($rootFull+[IO.Path]::DirectorySeparatorChar,$comparison)){throw 'CMS_INSPECTION_BINDING_UNVERIFIED'}
    $cursor=$pathFull
    while($cursor){
        $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'CMS_INSPECTION_BINDING_UNVERIFIED'}
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
    if((Get-Item -LiteralPath $pathFull -Force).PSIsContainer){throw 'CMS_INSPECTION_BINDING_UNVERIFIED'}
}
