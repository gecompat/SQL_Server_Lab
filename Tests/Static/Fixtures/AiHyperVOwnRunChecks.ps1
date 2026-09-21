param($Module,$RepoRoot,$TemporaryRoot)
& $Module {
    param($RepoRoot,$TemporaryRoot)
    . (Join-Path $RepoRoot 'Tests/Common/AiHyperVOwnRunAcceptance.ps1')
    $checks=[Collections.Generic.List[object]]::new()
    function Check {param($Name,$Value)$checks.Add([pscustomobject]@{Name=$Name;Success=[bool]$Value})}
    function Reject {param([scriptblock]$Action,[string]$Code)try{& $Action|Out-Null;$false}catch{$_.Exception.Message -match $Code}}
    $containerCommand=Get-Command (Join-Path $RepoRoot 'Tests/Integration/Invoke-AiRagExistingOllamaAcceptance.ps1')
    $cloudParameters=@($containerCommand.ParameterSets|Where-Object Name -eq Cloud)[0]
    $localParameters=@($containerCommand.ParameterSets|Where-Object Name -eq Local)[0]
    Check 'Container-Clouddefault behält Pflichtsecret und schließt lokale Diagnose aus' ($cloudParameters.IsDefault -and @($cloudParameters.Parameters|Where-Object {$_.Name -eq 'SecretFilePath' -and $_.IsMandatory}).Count -eq 1 -and 'IncludeDiagnostic' -notin $cloudParameters.Parameters.Name)
    Check 'Lokaler Container-Diagnosemodus verlangt Auswahl und erlaubt keine Cloudsecrets' (@($localParameters.Parameters|Where-Object {$_.Name -eq 'LocalGeneration' -and $_.IsMandatory}).Count -eq 1 -and 'IncludeDiagnostic' -in $localParameters.Parameters.Name -and 'SecretFilePath' -notin $localParameters.Parameters.Name)
    $ownRunAcceptance=Get-Content -LiteralPath (Join-Path $RepoRoot 'Tests/Integration/Invoke-AiHyperVOwnRunAcceptance.ps1') -Raw -Encoding utf8
    Check 'Own-Run-Restart bindet echten Hyper-V-Status und begrenzte Gast-SQL-Readiness' (
        $ownRunAcceptance -match '\$restart\.Exists' -and
        $ownRunAcceptance -match '\$restart\.State -eq ''Running''' -and
        $ownRunAcceptance -match '\$restart\.VMId' -and
        $ownRunAcceptance -match 'Wait-HyperVGuestSqlReady' -and
        $ownRunAcceptance -match '-ExpectedMajorVersion 17 -TimeoutSeconds 300' -and
        $ownRunAcceptance -match '\$sqlReady\.Status -eq ''SQL_READY_RUN''' -and
        $ownRunAcceptance -notmatch '\$restart\.Action'
    )
    $originals=@{}
    $names=@('Get-HyperVImageArtifact','Resolve-LabHyperVResourceBinding','Get-LabAiHostModelBinding','Test-LabAutomatedTestEnvironmentRun','Get-LabRunState','Get-HyperVManagedVM','Read-LabHyperVResourceBinding','Test-LabHyperVBoundPath','Get-VMHardDiskDrive','Get-VHD','Get-VM','Get-HyperVLabVMs')
    foreach($name in $names){$command=Get-Command $name -ErrorAction SilentlyContinue;$originals[$name]=if($command){$command.ScriptBlock}else{$null}}
    $directory=Join-Path $TemporaryRoot 'hyperv-own';$null=New-Item -Path $directory -ItemType Directory -Force
    $parentPath=Join-Path $directory 'parent.vhdx';[IO.File]::WriteAllText($parentPath,'synthetic-parent')
    $hash=(Get-FileHash -LiteralPath $parentPath).Hash.ToLowerInvariant();$parentItem=Get-Item $parentPath;$parentItem.IsReadOnly=$true
    $artifactId='hyperv-sql-prepared-sealed-'+$hash
    $runId='33333333-3333-4333-8333-333333333333';$vmId='44444444-4444-4444-8444-444444444444';$scope='55555555-5555-4555-8555-555555555555';$op='66666666-6666-4666-8666-666666666666'
    $script:hvArtifact=[pscustomobject]@{artifactId=$artifactId;artifactState='SQL_PREPARED_SEALED';sql=@{version='2025';license=@{type='developer'}};license=@{type='evaluation';evaluationExpiresAt=[datetimeoffset]::UtcNow.AddDays(5).ToString('o')};Path=$parentPath;sha256=$hash}
    $script:hvRun=[pscustomobject]@{runId=$runId;scopeId=$scope;state='RUNNING';metadata=@{workflowOperationId=$op;imageArtifactId=$artifactId;workflowKind='hyperv-lab'}}
    $child=Join-Path $directory 'child.vhdx'
    $script:hvManaged=[pscustomobject]@{VM=@{Id=$vmId;State='Running'};Identity=@{instanceId='primary';childVhdxPath=$child;additionalDrives=@()}}
    $script:hvProtected=$false;$script:hvForeignParent=$false;$script:hvForeignAttachment=$false;$script:hvVmResidue=$false
    $script:hvResource=@{ResourceId=$runId;HyperVResourceRoot=$directory}
    $runDirectory=Join-Path $directory "runs/$runId";$null=New-Item -Path $runDirectory -ItemType Directory -Force
    @{instances=@(@{id='primary';provider='hyperv';imageArtifactId=$artifactId;vmName='synthetic-own';vmId=$vmId;sqlVersion='2025';host='192.0.2.5';port=1433})}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $runDirectory 'connection-info.json')
    $module=Get-Module SqlServerLab
    try{
        Set-Item Function:script:Get-HyperVImageArtifact -Value {param($ArtifactId,$StateRoot,[switch]$SkipIntegrityCheck)if(-not $SkipIntegrityCheck){throw 'unexpected cache write'};$script:hvArtifact}
        Set-Item Function:script:Resolve-LabHyperVResourceBinding -Value {param($ResourceId,$ResourceClass)@{LocationId='synthetic-location'}}
        Set-Item Function:script:Get-LabAiHostModelBinding -Value {param($Plan)@{ModelKey=$Plan.ModelKey;Digest=('a'*64)}}
        Set-Item Function:script:Test-LabAutomatedTestEnvironmentRun -Value {param($RunId)$script:hvProtected}
        Set-Item Function:script:Get-LabRunState -Value {param($RunId,$StateRoot)$script:hvRun}
        Set-Item Function:script:Get-HyperVManagedVM -Value {param($VMName,$ExpectedRunId,$ExpectedScopeId)$script:hvManaged}
        Set-Item Function:script:Read-LabHyperVResourceBinding -Value {param($StateDirectory)$script:hvResource}
        Set-Item Function:script:Test-LabHyperVBoundPath -Value {param($Binding,$Path)@{Valid=$true}}
        Set-Item Function:script:Get-VMHardDiskDrive -Value {[CmdletBinding()]param([Parameter(Mandatory)]$VM)if([string]$VM.Id -cne [string]$script:hvManaged.VM.Id){throw 'unexpected VM binding'};@{Path=if($script:hvForeignAttachment){'unrelated.vhdx'}else{$script:hvManaged.Identity.childVhdxPath}}}
        Set-Item Function:script:Get-VHD -Value {param($Path)@{VhdType='Differencing';ParentPath=if($script:hvForeignParent){'unrelated-parent.vhdx'}else{$script:hvArtifact.Path}}}
        Set-Item Function:script:Get-VM -Value {if($script:hvVmResidue){$script:hvManaged.VM}}
        Set-Item Function:script:Get-HyperVLabVMs -Value {param($RunId,$ScopeId)@()}
        $before=@(Get-ChildItem -LiteralPath $directory -Recurse -File|ForEach-Object{$_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join "`n"
        $preflight=Get-OwnHyperVAiPreflight -Module $module -ArtifactId $artifactId -StateRoot $directory -LocalPort 11434
        $after=@(Get-ChildItem -LiteralPath $directory -Recurse -File|ForEach-Object{$_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join "`n"
        Check 'Hyper-V-Preflight prüft Parenthash ohne State- oder Cachewrite' ($preflight.ParentHash -ceq $hash -and $before -ceq $after)
        $script:hvArtifact.sha256='a'*64
        Check 'Falscher Parenthash blockiert vor Create' (Reject {Get-OwnHyperVAiPreflight -Module $module -ArtifactId $artifactId -StateRoot $directory -LocalPort 11434} 'AI_HYPERV_PARENT_INTEGRITY_INVALID')
        $script:hvArtifact.sha256=$hash;$script:hvArtifact.sql.license.type='evaluation'
        Check 'Nicht-Developer-SQL-Artifact bleibt außerhalb dieser Abnahme' (Reject {Get-OwnHyperVAiPreflight -Module $module -ArtifactId $artifactId -StateRoot $directory -LocalPort 11434} 'AI_HYPERV_PREPARED_ARTIFACT_INVALID')
        $script:hvArtifact.sql.license.type='developer'
        $arguments=@{Module=$module;RunId=$runId;StateRoot=$directory;OperationId=$op;ArtifactId=$artifactId;ExpectedVmId=$vmId;RequireReady=$true}
        $binding=Get-OwnHyperVAiBinding @arguments
        Check 'Own-Run-Bindung prüft exakte VM und tatsächlichen VHD-Parent' ($binding.VmId -ceq $vmId)
        $script:hvProtected=$true
        Check 'Reservierte Testgruppe blockiert vor jeder eigenen Aktion' (Reject {Get-OwnHyperVAiBinding @arguments} 'AI_HYPERV_SHARED_GROUP_FORBIDDEN')
        $script:hvProtected=$false;$script:hvRun.metadata.workflowOperationId='foreign'
        Check 'Fremde Operation darf nicht übernommen werden' (Reject {Get-OwnHyperVAiBinding @arguments} 'AI_HYPERV_RUN_OWNERSHIP_INVALID')
        $script:hvRun.metadata.workflowOperationId=$op;$script:hvManaged.VM.Id='77777777-7777-4777-8777-777777777777'
        Check 'VMId-ABA wird unabhängig vom Namen erkannt' (Reject {Get-OwnHyperVAiBinding @arguments} 'AI_HYPERV_VM_ID_DRIFT')
        $script:hvManaged.VM.Id=$vmId;$script:hvManaged.Identity.instanceId='other'
        Check 'Andere VM-Instanzidentität wird abgewiesen' (Reject {Get-OwnHyperVAiBinding @arguments} 'AI_HYPERV_VM_INSTANCE_DRIFT')
        $script:hvManaged.Identity.instanceId='primary';$script:hvForeignParent=$true
        Check 'Falscher tatsächlicher Parent wird vor RAG oder Restart abgewiesen' (Reject {Get-OwnHyperVAiBinding @arguments} 'AI_HYPERV_ACTUAL_PARENT_DRIFT')
        $script:hvForeignParent=$false;$script:hvForeignAttachment=$true
        Check 'Fremdes tatsächlich angehängtes Laufwerk blockiert' (Reject {Get-OwnHyperVAiBinding @arguments} 'AI_HYPERV_DISK_ATTACHMENT_DRIFT')
        $script:hvForeignAttachment=$false;$script:hvRun.state='REMOVED'
        $network=Join-Path $directory 'network';$null=New-Item -Path $network -ItemType Directory
        $lease=@{runId='foreign-run';scopeId='foreign-scope';state='ACTIVE'}
        @{leases=@($lease)}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $network 'hyperv-ipam.json')
        Assert-OwnHyperVAiNoResidue -Module $module -Binding $binding -StateRoot $directory
        Check 'Fremde aktive IPAM-Leases bleiben außerhalb des Own-Cleanups' $true
        $lease.runId=$runId;$lease.scopeId=$scope
        @{leases=@($lease)}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $network 'hyperv-ipam.json')
        Check 'Eigene aktive IPAM-Lease verhindert Erfolg' (Reject {Assert-OwnHyperVAiNoResidue -Module $module -Binding $binding -StateRoot $directory} 'AI_HYPERV_IPAM_RESIDUE')
        $script:hvVmResidue=$true
        Check 'Verbliebene exakte VM verhindert Erfolg' (Reject {Assert-OwnHyperVAiNoResidue -Module $module -Binding $binding -StateRoot $directory} 'AI_HYPERV_VM_RESIDUE')
    }finally{
        (Get-Item -LiteralPath $parentPath).IsReadOnly=$false
        foreach($name in $names){if($originals[$name]){Set-Item "Function:script:$name" -Value $originals[$name]}else{Remove-Item "Function:script:$name" -ErrorAction SilentlyContinue}}
    }
    $checks.ToArray()
} $RepoRoot $TemporaryRoot
