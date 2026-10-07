# Test-only helpers; no product exports and no standard/shared-host fallback.
# Custody/finalization deliberately follows the existing port acceptance contract.
function New-CmsInspectionAcceptanceEvidenceDirectory {
    param($Module,[string]$RepositoryRoot)
    $path=Join-Path $RepositoryRoot ('.artifacts/test-runs/cms-inspection-'+[guid]::NewGuid().ToString('N'))
    & $Module {param($Path)$null=Assert-LabOwnedHostPath $Path} $path
    if(Test-Path -LiteralPath $path -ErrorAction Stop){throw 'CMS_ACCEPTANCE_EVIDENCE_EXISTS'}
    $null=New-Item -ItemType Directory -Path $path -ErrorAction Stop
    return $path
}

function Assert-CmsInspectionAcceptanceLayout {
    param([string]$DataRoot,[string]$RepositoryRoot)
    if(-not [IO.Path]::IsPathFullyQualified($DataRoot)){throw 'CMS_ACCEPTANCE_ROOT_INVALID'}
    $root=[IO.Path]::GetFullPath($DataRoot).TrimEnd('\','/')
    $repo=[IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\','/')
    if([IO.Path]::GetFileName($root) -cnotmatch '^sql-lab-cms-inspection-[a-f0-9]{32}$' -or
        $root.StartsWith($repo+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
        $root -eq $repo -or (Test-Path -LiteralPath $root -ErrorAction Stop)){throw 'CMS_ACCEPTANCE_ROOT_INVALID'}
    return $root
}

function New-CmsInspectionAcceptanceScope {
    param($Module,[string]$DataRoot,[string]$Provider,[string]$ParentOperationId)
    # Two fresh exact policies preserve both registration-parent custody and the
    # real runtime State child. No existing run or policy is moved or adopted.
    $null=Initialize-OwnedHostTestRoot -Module $Module -StateRoot $DataRoot -Providers @($Provider) -ParentOperationId $ParentOperationId
    $state=Join-Path $DataRoot State
    $null=Initialize-OwnedHostTestRoot -Module $Module -StateRoot $state -Providers @($Provider) -ParentOperationId $ParentOperationId
    return & $Module {
        param($Root,$State,$Operation)
        $parent=Get-LabOwnedHostPolicy -StateRoot $Root -Required
        $child=Get-LabOwnedHostPolicy -StateRoot $State -Required
        if($parent.ParentOperationId -cne $Operation -or $child.ParentOperationId -cne $Operation -or
            ($parent.RuntimePins|ConvertTo-Json -Depth 8 -Compress) -cne ($child.RuntimePins|ConvertTo-Json -Depth 8 -Compress)){throw 'CMS_ACCEPTANCE_POLICY_BINDING'}
        $null=Initialize-LabManagedDataRoot -DataRoot $Root -ControllerId ([guid]::NewGuid().ToString('D')) -Confirm:$false
        $config=Get-LabStorageConfiguration -DataRoot $Root
        if(@($config.LabDataLocations).Count -ne 1 -or $config.LabDataLocations[0].LabDataRoot -cne $Root){throw 'CMS_ACCEPTANCE_REGISTRATION_SCOPE'}
        $null=Write-LabStorageConfiguration -Configuration $config
        [pscustomobject]@{DataRoot=$Root;StateRoot=$State;ParentOperationId=$Operation
            ParentPolicyHash=(Get-FileHash (Join-Path $Root owned-host-policy.json)).Hash
            StatePolicyHash=(Get-FileHash (Join-Path $State owned-host-policy.json)).Hash
            MarkerHash=(Get-FileHash (Join-Path $Root .sql-server-lab-root.json)).Hash
            CatalogHash=(Get-FileHash (Join-Path $Root Catalog/storage-locations.json)).Hash}
    } $DataRoot $state $ParentOperationId
}

function Get-CmsInspectionAcceptanceFileBinding {
    param([string]$DataRoot)
    if(-not [IO.Path]::IsPathFullyQualified($DataRoot)){throw 'CMS_ACCEPTANCE_FILE_SCOPE'}
    $cursor=[IO.Path]::GetFullPath($DataRoot)
    while($cursor){
        if((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'CMS_ACCEPTANCE_FILE_SCOPE'}
        $parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent
    }
    $files=@(Get-ChildItem -LiteralPath $DataRoot -Recurse -Force -ErrorAction Stop)
    if($files.Count -gt 8192 -or @($files|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'CMS_ACCEPTANCE_FILE_SCOPE'}
    return @($files|Where-Object{-not $_.PSIsContainer}|Sort-Object FullName|ForEach-Object{
        [pscustomobject]@{Path=[IO.Path]::GetRelativePath($DataRoot,$_.FullName);Bytes=$_.Length;Sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
    })
}

function Assert-CmsInspectionAcceptanceRoute {
    param($Module,$Scope,[string]$Provider)
    & $Module {
        param($Scope,$Provider)
        $policy=Get-LabOwnedHostPolicy -StateRoot $Scope.StateRoot -Required
        $pins=@($policy.RuntimePins|Where-Object Provider -CEQ $Provider)
        if($pins.Count -ne 1){throw 'CMS_ACCEPTANCE_ROUTE'}
        $pin=$pins[0]
        if((Get-LabHostToolInvocation -Name $Provider) -cne $pin.Invocation){throw 'CMS_ACCEPTANCE_ROUTE'}
        # The product worker also makes a direct native inspect. Check its active
        # route against custody without rewriting any client/default settings.
        foreach($name in @('DOCKER_HOST','DOCKER_CONTEXT','CONTAINER_HOST','CONTAINER_CONNECTION','CONTAINER_SSHKEY','PODMAN_CONNECTIONS_CONF','PODMAN_SSHKEY')){
            if([Environment]::GetEnvironmentVariable($name)){throw 'CMS_ACCEPTANCE_ROUTE_OVERRIDE'}
        }
        function Read-CmsAcceptanceNative([string[]]$Arguments){
            $start=[Diagnostics.ProcessStartInfo]::new($pin.Invocation)
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}
            $read=Invoke-LabOwnedHostNativeProcess -StartInfo $start -TimeoutSeconds 10 -MaximumBytes 1048576
            if($read.ExitCode -ne 0){throw 'CMS_ACCEPTANCE_ROUTE_UNAVAILABLE'}
            $read.Stdout
        }
        if($Provider -ceq 'docker'){
            $contexts=@((Read-CmsAcceptanceNative @('context','inspect'))|ConvertFrom-Json -Depth 16)
            if($contexts.Count -ne 1 -or $contexts[0].Endpoints.docker.Host -cne $pin.Endpoint){throw 'CMS_ACCEPTANCE_ROUTE'}
            $arguments=@('info','--format','{{json .}}')
        }else{
            $connections=@((Read-CmsAcceptanceNative @('system','connection','list','--format','json'))|ConvertFrom-Json -Depth 16)
            $selected=@($connections|Where-Object Default -EQ $true)
            if($selected.Count -ne 1 -or $selected[0].URI -cne $pin.Endpoint -or
                [IO.Path]::GetFullPath([string]$selected[0].Identity) -cne $pin.IdentityPath -or
                (Get-FileHash -LiteralPath $pin.IdentityPath).Hash.ToLowerInvariant() -cne $pin.IdentitySha256){throw 'CMS_ACCEPTANCE_ROUTE'}
            $arguments=@('info','--format','json')
        }
        $native=(Read-CmsAcceptanceNative $arguments)|ConvertFrom-Json -Depth 30
        $read=Invoke-LabOwnedHostPinnedCommand -StateRoot $Scope.StateRoot -Provider $Provider -Arguments $arguments -TimeoutSeconds 10
        if($read.ExitCode -ne 0){throw 'CMS_ACCEPTANCE_ROUTE_UNAVAILABLE'}
        $pinned=$read.Stdout|ConvertFrom-Json -Depth 30
        if($Provider -ceq 'docker'){
            if(-not $native.ID -or $native.ID -cne $pinned.ID){throw 'CMS_ACCEPTANCE_ROUTE'}
        }elseif(-not $native.Host.Hostname -or -not $native.Store.GraphRoot -or -not $native.Version.Version -or
            $native.Host.Hostname -cne $pinned.Host.Hostname -or $native.Store.GraphRoot -cne $pinned.Store.GraphRoot -or
            $native.Version.Version -cne $pinned.Version.Version){throw 'CMS_ACCEPTANCE_ROUTE'}
    } $Scope $Provider
}

function Invoke-CmsInspectionAcceptanceSql {
    param($Module,$Scope,$Custody,[switch]$Arrange)
    Assert-CmsInspectionAcceptanceRoute $Module $Scope $Custody.Provider
    & $Module {
        param($Scope,$Custody,$Arrange)
        $selection=Get-LabCmsInspectionSelection -StateRoot $Scope.StateRoot
        if(-not $selection -or $selection.RunId -cne $Custody.RunId -or
            $selection.Run.scopeId -cne $Custody.ScopeId -or $selection.Provider -cne $Custody.Provider -or
            $selection.Instance.containerId -cne $Custody.ContainerId -or $selection.Instance.id -cne 'primary' -or
            $selection.StateRoot -cne $Scope.StateRoot -or $selection.Run.state -cne 'RUNNING'){throw 'CMS_ACCEPTANCE_SQL_SCOPE'}
        $null=Assert-LabOwnedHostContainerEffect -StateRoot $Scope.StateRoot -RunId $Custody.RunId -Provider $selection.Provider -ContainerId $Custody.ContainerId
        # The real product binding runs only inside its bounded worker. Arrange/
        # independent table reads use a bounded pinned inspect of exact custody.
        $read=Invoke-LabOwnedHostPinnedCommand -StateRoot $Scope.StateRoot -Provider $Custody.Provider -Arguments @('inspect',$Custody.ContainerId) -TimeoutSeconds 10
        if($read.ExitCode -ne 0){throw 'CMS_ACCEPTANCE_SQL_BINDING'}
        $containers=@($read.Stdout|ConvertFrom-Json -Depth 30)
        if($containers.Count -ne 1){throw 'CMS_ACCEPTANCE_SQL_BINDING'}
        $container=$containers[0];$labels=$container.Config.Labels;$ports=@($container.NetworkSettings.Ports.'1433/tcp')
        if($container.Id -cne $Custody.ContainerId -or $container.State.Running -isnot [bool] -or -not $container.State.Running -or
            $labels.'sql-server-lab.run-id' -cne $Custody.RunId -or $labels.'sql-server-lab.scope-id' -cne $Custody.ScopeId -or
            $labels.'sql-server-lab.instance-id' -cne 'primary' -or $ports.Count -ne 1 -or
            $ports[0].HostIp -cnotin @('127.0.0.1','::1') -or [int]$ports[0].HostPort -lt 1 -or [int]$ports[0].HostPort -gt 65535 -or
            [int]$ports[0].HostPort -ne [int]$selection.Instance.port -or $selection.Instance.version -cne '2025' -or
            $selection.Instance.host -cnotin @('localhost',[string]$ports[0].HostIp)){throw 'CMS_ACCEPTANCE_SQL_BINDING'}
        $binding=[pscustomobject]@{HostName=[string]$ports[0].HostIp;Port=[int]$ports[0].HostPort}
        Assert-LabCmsInspectionReadPath -Root $Scope.StateRoot -Path (Join-Path $Scope.StateRoot ('runs/'+$Custody.RunId+'/secrets/sa-password.secret'))
        $secret=$null;$connection=$null;$command=$null;$reader=$null
        try {
            $secret=Get-LabSecret -Path (Join-Path $Scope.StateRoot ('runs/'+$Custody.RunId)) -Name sa-password
            if($secret -isnot [Security.SecureString]){throw 'CMS_ACCEPTANCE_SQL_SECRET'}
            if(-not $secret.IsReadOnly()){$secret.MakeReadOnly()}
            $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new()
            $builder['Data Source']=$binding.HostName+','+$binding.Port;$builder['Initial Catalog']='msdb'
            $builder['Encrypt']=$true;$builder['TrustServerCertificate']=$true;$builder['Connect Timeout']=3
            $builder['Pooling']=$false;$builder['Persist Security Info']=$false
            $builder['Application Name']='SqlServerLab.CmsNativeAcceptance'
            $connection=[Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
            $connection.Credential=[Data.SqlClient.SqlCredential]::new('sa',$secret)
            $command=$connection.CreateCommand();$command.CommandTimeout=10;$connection.Open()
            if($Arrange){
                # Synthetic membership is SQL arrangement only, never a connection
                # test. These writes finish before the read-only acceptance freeze.
                $command.CommandText=@'
SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF EXISTS (SELECT 1 FROM dbo.sysmanagement_shared_server_groups WHERE is_system_object = 0)
 OR EXISTS (SELECT 1 FROM dbo.sysmanagement_shared_registered_servers)
 THROW 51000, 'CMS fixture requires empty fresh CMS metadata.', 1;
DECLARE @Engine int = (SELECT TOP (1) server_group_id FROM dbo.sysmanagement_shared_server_groups WHERE server_type = 0 AND is_system_object = 1 ORDER BY server_group_id);
IF @Engine IS NULL THROW 51000, 'CMS engine root missing.', 1;
DECLARE @Root int, @Managed int, @Unmanaged int, @Server int;
EXEC dbo.sp_sysmanagement_add_shared_server_group @name=N'Native CMS fixture', @description=N'ManagedBy=SQL_Server_Lab;Contract=1.1;Role=Root', @server_type=0, @parent_id=@Engine, @server_group_id=@Root OUTPUT;
EXEC dbo.sp_sysmanagement_add_shared_server_group @name=N'Managed fixture', @description=N'ManagedBy=SQL_Server_Lab;Contract=1.1;Role=Provider', @server_type=0, @parent_id=@Root, @server_group_id=@Managed OUTPUT;
EXEC dbo.sp_sysmanagement_add_shared_registered_server @name=N'Managed synthetic server', @server_group_id=@Managed, @server_name=N'native-fixture.invalid,1433', @description=N'ManagedBy=SQL_Server_Lab;Contract=1.1;Identity=native-fixture', @server_type=0, @server_id=@Server OUTPUT;
EXEC dbo.sp_sysmanagement_add_shared_server_group @name=N'Unmanaged fixture', @description=N'Synthetic unmanaged fixture', @server_type=0, @parent_id=@Engine, @server_group_id=@Unmanaged OUTPUT;
EXEC dbo.sp_sysmanagement_add_shared_registered_server @name=N'Unmanaged synthetic server', @server_group_id=@Unmanaged, @server_name=N'unmanaged-fixture.invalid,1433', @description=N'Synthetic unmanaged fixture', @server_type=0, @server_id=@Server OUTPUT;
COMMIT;
'@
                $null=$command.ExecuteNonQuery()
            }
            # All columns/rows from both CMS tables, including unmanaged controls.
            # Retain only digests; names, endpoints and raw SQL rows never leave here.
            $command.CommandText=@'
SELECT (SELECT * FROM dbo.sysmanagement_shared_server_groups ORDER BY server_group_id FOR JSON PATH, INCLUDE_NULL_VALUES),
       (SELECT * FROM dbo.sysmanagement_shared_registered_servers ORDER BY server_id FOR JSON PATH, INCLUDE_NULL_VALUES);
'@
            $reader=$command.ExecuteReader()
            if(-not $reader.Read()){throw 'CMS_ACCEPTANCE_SQL_SNAPSHOT'}
            $hashes=@(foreach($i in 0,1){
                $json=$reader.GetString($i)
                if([Text.Encoding]::UTF8.GetByteCount($json) -gt 1MB){throw 'CMS_ACCEPTANCE_SQL_SNAPSHOT_LIMIT'}
                [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json)))
            })
            if($reader.Read() -or $reader.NextResult()){throw 'CMS_ACCEPTANCE_SQL_SNAPSHOT'}
            [pscustomobject]@{GroupsSha256=$hashes[0];ServersSha256=$hashes[1]}
        }finally{if($reader){$reader.Dispose()};if($command){$command.Dispose()};if($connection){$connection.Dispose()};if($secret){$secret.Dispose()}}
    } $Scope $Custody ([bool]$Arrange)
}

function Assert-CmsInspectionAcceptanceResult {
    param($Result,$Custody,[string]$Provider,[string]$SelectionKey,[string]$Status,[string]$Code)
    $fields=@('ContractVersion','Status','Code','RunId','InstanceId','Provider','SelectionKey','ObservedAt','SqlMajor','ManagedGroupCount','ManagedServerCount','Notice')
    if($Result -isnot [pscustomobject] -or @($Result.PSObject.Properties).Count -ne 12 -or
        @($Result.PSObject.Properties.Name|Where-Object{$_ -cnotin $fields}).Count -or
        $Result.ContractVersion -cne 'SqlServerLab.CmsInspection/1.0' -or $Result.Status -cne $Status -or $Result.Code -cne $Code -or
        $Result.RunId -cne $Custody.RunId -or $Result.InstanceId -cne 'primary' -or $Result.Provider -cne $Provider -or
        $Result.SelectionKey -cne $SelectionKey){throw 'CMS_ACCEPTANCE_DTO'}
    if($Status -ceq 'OBSERVED'){
        if(($Result.SqlMajor -isnot [int] -and $Result.SqlMajor -isnot [long]) -or $Result.SqlMajor -ne 17 -or
            $Result.ManagedGroupCount -isnot [long] -or $Result.ManagedServerCount -isnot [long] -or
            $Result.ManagedGroupCount -ne 2 -or $Result.ManagedServerCount -ne 1){throw 'CMS_ACCEPTANCE_COUNTS'}
    }elseif($null -ne $Result.SqlMajor -or $null -ne $Result.ManagedGroupCount -or $null -ne $Result.ManagedServerCount){throw 'CMS_ACCEPTANCE_UNKNOWN_COUNTS'}
}

function Get-CmsInspectionAcceptanceCustody {
    param($Module,$Scope,[string]$RunId,[string]$Provider)
    & $Module {
        param($Scope,$Run,$Provider)
        $policy=Get-LabOwnedHostRunPolicy -StateRoot $Scope.StateRoot -RunId $Run
        if(-not $policy -or $policy.ParentOperationId -cne $Scope.ParentOperationId){throw 'CMS_ACCEPTANCE_CUSTODY'}
        $context=Get-LabContainerReconcileContext -RunId $Run -InstanceId primary -StateRoot $Scope.StateRoot
        if($context.Provider -cne $Provider -or $context.ContainerId -cnotmatch '^[a-f0-9]{64}$'){throw 'CMS_ACCEPTANCE_CUSTODY'}
        $null=Assert-LabOwnedHostContainerEffect -StateRoot $Scope.StateRoot -RunId $Run -Provider $Provider -ContainerId $context.ContainerId
        $directory=Join-Path $Scope.StateRoot "runs/$Run/owned-host-containers"
        $null=Assert-LabOwnedHostPath $directory
        $created=@(Get-ChildItem -LiteralPath $directory -Filter '*.created.json' -File -ErrorAction Stop)
        if($created.Count -gt 128){throw 'CMS_ACCEPTANCE_CUSTODY_RECEIPT_LIMIT'}
        # New can retain receipt-backed ephemeral probes as well as the primary.
        # Select exact current native identity, never the number/order of files.
        $matches=@(foreach($file in $created){
            $null=Assert-LabOwnedHostPath $file.FullName
            $record=Read-LabOwnedHostRecord $file.FullName
            Assert-LabOwnedHostProperties $record @('ContractVersion','IntentId','PolicyId','RootScopeId','RunId','ScopeId','InstanceId','Provider','ContainerId','IntentSha256')
            foreach($property in $record.PSObject.Properties){if($property.Value -isnot [string]){throw 'CMS_ACCEPTANCE_CUSTODY_RECORD_INVALID'}}
            Assert-LabOwnedHostGuid $record.IntentId
            $intentPath=Assert-LabOwnedHostPath (Join-Path $directory ($record.IntentId+'.intent.json'))
            $intent=Read-LabOwnedHostRecord $intentPath
            Assert-LabOwnedHostProperties $intent @('ContractVersion','IntentId','PolicyId','RootScopeId','RunId','ScopeId','WorkflowOperationId','InstanceId','Provider','ContainerName')
            foreach($property in $intent.PSObject.Properties){if($property.Value -isnot [string]){throw 'CMS_ACCEPTANCE_CUSTODY_RECORD_INVALID'}}
            if($record.ContractVersion -cne 'SqlServerLab.OwnedHostContainerReceipt/1.0' -or $intent.ContractVersion -cne 'SqlServerLab.OwnedHostContainerIntent/1.0' -or
                $record.PolicyId -cne $policy.PolicyId -or $intent.PolicyId -cne $policy.PolicyId -or
                $record.RootScopeId -cne $policy.RootScopeId -or $intent.RootScopeId -cne $policy.RootScopeId -or
                $record.RunId -cne $Run -or $intent.RunId -cne $Run -or $record.ScopeId -cne $context.Run.scopeId -or $intent.ScopeId -cne $context.Run.scopeId -or
                $intent.IntentId -cne $record.IntentId -or $file.Name -cne ($record.IntentId+'.created.json') -or
                $record.InstanceId -cne $intent.InstanceId -or $record.Provider -cne $Provider -or $intent.Provider -cne $Provider -or
                $intent.WorkflowOperationId -cne $context.Run.metadata.workflowOperationId -or
                $record.ContainerId -cnotmatch '^[a-f0-9]{64}$' -or $intent.ContainerName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$' -or
                $record.IntentSha256 -cne (Get-FileHash -LiteralPath $intentPath).Hash.ToLowerInvariant()){throw 'CMS_ACCEPTANCE_CUSTODY_RECORD_DRIFT'}
            if($record.ContainerId -ceq $context.ContainerId){
                if($record.InstanceId -cne 'primary' -or $intent.ContainerName -cne $context.ContainerName){throw 'CMS_ACCEPTANCE_CUSTODY'}
                [pscustomobject]@{Receipt=$record;Path=$file.FullName;IntentPath=$intentPath}
            }
        })
        if($matches.Count -ne 1){throw 'CMS_ACCEPTANCE_CUSTODY'}
        $receipt=$matches[0].Receipt;$receiptPath=$matches[0].Path;$intentPath=$matches[0].IntentPath
        $volumes=@(foreach($mount in @($context.Inspect.Mounts|Where-Object Type -CEQ volume)){
            $volume=(Get-LabOwnedHostVolumeReceipt -StateRoot $Scope.StateRoot -Provider $Provider -VolumeName $mount.Name).Receipt
            if($volume.RunId -cne $Run -or $volume.ScopeId -cne $context.Run.scopeId -or $volume.Provider -cne $Provider -or $volume.VolumeName -cne $mount.Name){throw 'CMS_ACCEPTANCE_VOLUME_CUSTODY'}
            [pscustomobject]@{Name=$volume.VolumeName;ReceiptHash=(Get-FileHash -LiteralPath (Join-Path $Scope.StateRoot "owned-host-volumes/$Provider-$($volume.VolumeName).created.json")).Hash;IntentHash=(Get-FileHash -LiteralPath (Join-Path $Scope.StateRoot "owned-host-volumes/$Provider-$($volume.VolumeName).intent.json")).Hash}
        })
        [pscustomobject]@{RunId=$Run;ScopeId=$context.Run.scopeId;Provider=$Provider;IntentId=$receipt.IntentId;ContainerId=$context.ContainerId;ContainerName=$context.ContainerName;Volumes=$volumes;
            ContainerReceiptHash=(Get-FileHash -LiteralPath $receiptPath).Hash;IntentHash=(Get-FileHash -LiteralPath $intentPath).Hash}
    } $Scope $RunId $Provider
}

function Remove-CmsInspectionAcceptanceScope {
    param($Module,$Scope,$Custody,[string]$Provider,[bool]$UnreturnedCreation,[bool]$Completed,[string]$EvidenceRoot)
    # Failure retains parent registration, child policy and journals together.
    if($UnreturnedCreation -or -not $Scope -or -not $Custody){return [pscustomobject]@{Status='RECOVERY_REQUIRED';RootRemoved=$false}}
    foreach($id in @($Custody.RunId,$Custody.IntentId)){
        $parsed=[guid]::Empty
        if(-not [guid]::TryParseExact([string]$id,'D',[ref]$parsed) -or $parsed -eq [guid]::Empty){throw 'CMS_ACCEPTANCE_CUSTODY_ID_INVALID'}
    }
    if($Custody.ContainerId -cnotmatch '^[a-f0-9]{64}$' -or $Custody.ContainerName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$' -or
        $Scope.StateRoot -cne (Join-Path $Scope.DataRoot State) -or [IO.Path]::GetFileName($Scope.DataRoot) -cnotmatch '^sql-lab-cms-inspection-[a-f0-9]{32}$' -or
        @($Custody.Volumes).Count -gt 128){throw 'CMS_ACCEPTANCE_CUSTODY_ID_INVALID'}
    foreach($volume in @($Custody.Volumes)){if($volume.Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$'){throw 'CMS_ACCEPTANCE_CUSTODY_ID_INVALID'}}
    if(-not $EvidenceRoot){throw 'CMS_ACCEPTANCE_EVIDENCE_MISSING'}
    $evidenceFull=[IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\','/')
    $runtimeFull=[IO.Path]::GetFullPath($Scope.DataRoot).TrimEnd('\','/')
    if($evidenceFull -ceq $runtimeFull -or $evidenceFull.StartsWith($runtimeFull+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'CMS_ACCEPTANCE_EVIDENCE_INSIDE_RUNTIME_ROOT'}
    & $Module {param($Path)$null=Assert-LabOwnedHostPath $Path} $EvidenceRoot
    & $Module {
        param($Scope,$Custody,$Provider)
        $parent=Get-LabOwnedHostPolicy -StateRoot $Scope.DataRoot -Required
        $child=Get-LabOwnedHostRunPolicy -StateRoot $Scope.StateRoot -RunId $Custody.RunId
        if(-not $child -or $parent.ParentOperationId -cne $Scope.ParentOperationId -or $child.ParentOperationId -cne $Scope.ParentOperationId){throw 'CMS_ACCEPTANCE_POLICY_DRIFT'}
        $directory=Join-Path $Scope.StateRoot "runs/$($Custody.RunId)/owned-host-containers"
        foreach($entry in @(@{Path=(Join-Path $Scope.DataRoot 'owned-host-policy.json');Hash=$Scope.ParentPolicyHash},
                @{Path=(Join-Path $Scope.StateRoot 'owned-host-policy.json');Hash=$Scope.StatePolicyHash},
                @{Path=(Join-Path $Scope.DataRoot '.sql-server-lab-root.json');Hash=$Scope.MarkerHash},
                @{Path=(Join-Path $Scope.DataRoot 'Catalog/storage-locations.json');Hash=$Scope.CatalogHash},
                @{Path=(Join-Path $directory ($Custody.IntentId+'.created.json'));Hash=$Custody.ContainerReceiptHash},
                @{Path=(Join-Path $directory ($Custody.IntentId+'.intent.json'));Hash=$Custody.IntentHash})){
            $null=Assert-LabOwnedHostPath $entry.Path
            if((Get-FileHash -LiteralPath $entry.Path -ErrorAction Stop).Hash -cne $entry.Hash){throw 'CMS_ACCEPTANCE_CLAIM_DRIFT'}
        }
        $receipt=Read-LabOwnedHostRecord (Join-Path $directory ($Custody.IntentId+'.created.json'))
        $intent=Read-LabOwnedHostRecord (Join-Path $directory ($Custody.IntentId+'.intent.json'))
        if($receipt.ContainerId -cne $Custody.ContainerId -or $receipt.RunId -cne $Custody.RunId -or
            $receipt.Provider -cne $Provider -or $intent.ContainerName -cne $Custody.ContainerName){throw 'CMS_ACCEPTANCE_CONTAINER_CUSTODY_DRIFT'}
        $null=Assert-LabOwnedHostContainerEffect -StateRoot $Scope.StateRoot -RunId $Custody.RunId -Provider $Provider -ContainerId $Custody.ContainerId
        foreach($volume in @($Custody.Volumes)){
            foreach($entry in @(@{Suffix='created';Hash=$volume.ReceiptHash},@{Suffix='intent';Hash=$volume.IntentHash})){
                $path=Join-Path $Scope.StateRoot "owned-host-volumes/$Provider-$($volume.Name).$($entry.Suffix).json"
                $null=Assert-LabOwnedHostPath $path
                if((Get-FileHash -LiteralPath $path -ErrorAction Stop).Hash -cne $entry.Hash){throw 'CMS_ACCEPTANCE_VOLUME_CUSTODY_DRIFT'}
            }
            $receipt=(Get-LabOwnedHostVolumeReceipt -StateRoot $Scope.StateRoot -Provider $Provider -VolumeName $volume.Name).Receipt
            if($receipt.RunId -cne $Custody.RunId -or $receipt.ScopeId -cne $Custody.ScopeId -or $receipt.Provider -cne $Provider -or $receipt.VolumeName -cne $volume.Name){throw 'CMS_ACCEPTANCE_VOLUME_CUSTODY_DRIFT'}
        }
    } $Scope $Custody $Provider
    $removed=Remove-SqlServerLab -RunId $Custody.RunId -StateRoot $Scope.StateRoot -Force -Confirm:$false
    if($removed.Status -cne 'REMOVED'){throw 'CMS_ACCEPTANCE_CLEANUP_UNCONFIRMED'}
    & $Module {
        param($Scope,$Custody,$Provider,$Completed,$EvidenceRoot)
        $parent=Get-LabOwnedHostPolicy -StateRoot $Scope.DataRoot -Required
        $child=Get-LabOwnedHostPolicy -StateRoot $Scope.StateRoot -Required
        if($parent.ParentOperationId -cne $Scope.ParentOperationId -or $child.ParentOperationId -cne $Scope.ParentOperationId){throw 'CMS_ACCEPTANCE_POLICY_DRIFT'}
        $run=Get-LabRunState -RunId $Custody.RunId -StateRoot $Scope.StateRoot
        $runDirectory=Join-Path $Scope.StateRoot ('runs/'+$Custody.RunId)
        $planPath=Assert-LabOwnedHostPath (Join-Path $runDirectory cleanup-plan.json)
        $plan=Get-Content -LiteralPath $planPath -Raw -ErrorAction Stop|ConvertFrom-Json -Depth 30
        if($run.state -cne 'REMOVED' -or $run.scopeId -cne $Custody.ScopeId -or $plan.runId -cne $Custody.RunId -or
            $plan.scopeId -cne $Custody.ScopeId -or $plan.status -cne 'COMPLETED' -or @($plan.steps|Where-Object state -CNE COMPLETED).Count){throw 'CMS_ACCEPTANCE_CLEANUP_UNCONFIRMED'}
        $terminal=[pscustomobject]@{RunStateSha256=(Get-FileHash -LiteralPath (Join-Path $runDirectory run-state.json)).Hash;CleanupPlanSha256=(Get-FileHash -LiteralPath $planPath).Hash}
        foreach($path in @(@{Path=(Join-Path $Scope.DataRoot 'owned-host-policy.json');Hash=$Scope.ParentPolicyHash},
                @{Path=(Join-Path $Scope.StateRoot 'owned-host-policy.json');Hash=$Scope.StatePolicyHash},
                @{Path=(Join-Path $Scope.DataRoot '.sql-server-lab-root.json');Hash=$Scope.MarkerHash},
                @{Path=(Join-Path $Scope.DataRoot 'Catalog/storage-locations.json');Hash=$Scope.CatalogHash})){
            $null=Assert-LabOwnedHostPath $path.Path
            if((Get-FileHash -LiteralPath $path.Path -ErrorAction Stop).Hash -cne $path.Hash){throw 'CMS_ACCEPTANCE_CLAIM_DRIFT'}
        }
        $read=Invoke-LabOwnedHostPinnedCommand -StateRoot $Scope.StateRoot -Provider $Provider -Arguments @('ps','-a','--no-trunc','--filter',('id='+$Custody.ContainerId),'--format','{{.ID}}')
        if($read.ExitCode -ne 0 -or $read.Stdout.Trim()){throw 'CMS_ACCEPTANCE_CONTAINER_ABSENCE_UNCONFIRMED'}
        foreach($volume in @($Custody.Volumes)){
            $read=Invoke-LabOwnedHostPinnedCommand -StateRoot $Scope.StateRoot -Provider $Provider -Arguments @('volume','ls','--filter',('name=^'+[regex]::Escape($volume.Name)+'$'),'--format','{{.Name}}')
            if($read.ExitCode -ne 0 -or $read.Stdout.Trim()){throw 'CMS_ACCEPTANCE_VOLUME_ABSENCE_UNCONFIRMED'}
        }
        $runs=@(Get-ChildItem -LiteralPath (Join-Path $Scope.StateRoot runs) -Directory -ErrorAction Stop)
        if($runs.Count -ne 1 -or $runs[0].Name -cne $Custody.RunId){throw 'CMS_ACCEPTANCE_EXTRA_RUN'}
        if(-not $Completed){return [pscustomobject]@{Status='OWN_RESOURCES_REMOVED_ROOT_RETAINED';RootRemoved=$false}}
        $root=Assert-LabOwnedHostPath $Scope.DataRoot
        if([IO.Path]::GetFileName($root) -cnotmatch '^sql-lab-cms-inspection-[a-f0-9]{32}$' -or
            $Scope.StateRoot -cne (Join-Path $root State) -or
            @((Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop)|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'CMS_ACCEPTANCE_DELETE_SCOPE'}
        $preserved=[Collections.Generic.List[object]]::new()
        foreach($entry in @(@{Source=(Join-Path $runDirectory run-state.json);Hash=$terminal.RunStateSha256;Name='terminal-run-state.private.json'},
                @{Source=$planPath;Hash=$terminal.CleanupPlanSha256;Name='terminal-cleanup-plan.private.json'})){
            $source=Assert-LabOwnedHostPath $entry.Source
            $destination=Assert-LabOwnedHostPath (Join-Path $EvidenceRoot $entry.Name)
            $sourceStream=$null;$output=$null
            try {
                $sourceStream=[IO.FileStream]::new($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                if($sourceStream.Length -gt 1MB){throw 'CMS_ACCEPTANCE_TERMINAL_EVIDENCE_LIMIT'}
                $bytes=[byte[]]::new([int]$sourceStream.Length);$offset=0
                while($offset -lt $bytes.Length){$read=$sourceStream.Read($bytes,$offset,$bytes.Length-$offset);if($read -eq 0){throw 'CMS_ACCEPTANCE_TERMINAL_EVIDENCE_SHORT_READ'};$offset+=$read}
                if($sourceStream.ReadByte() -ne -1 -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $entry.Hash){throw 'CMS_ACCEPTANCE_TERMINAL_EVIDENCE_DRIFT'}
                $output=[IO.FileStream]::new($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $output.Write($bytes,0,$bytes.Length)
            } finally {if($output){$output.Dispose()};if($sourceStream){$sourceStream.Dispose()}}
            $null=Assert-LabOwnedHostPath $destination
            if((Get-FileHash -LiteralPath $destination).Hash -cne $entry.Hash -or (Get-Item -LiteralPath $destination).Length -ne $bytes.Length){throw 'CMS_ACCEPTANCE_TERMINAL_EVIDENCE_COPY_FAILED'}
            $preserved.Add([pscustomobject]@{RelativeEvidencePath=$entry.Name;Sha256=$entry.Hash;Bytes=$bytes.Length})
        }
        # Same-user FS checks are not an atomic filesystem transaction.
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
        if(Test-Path -LiteralPath $root -ErrorAction Stop){throw 'CMS_ACCEPTANCE_ROOT_REMAINS'}
        [pscustomobject]@{Status='CLEANED';RootRemoved=$true;ResourcesAbsent=$true;TerminalEvidence=@($preserved)}
    } $Scope $Custody $Provider $Completed $EvidenceRoot
}
