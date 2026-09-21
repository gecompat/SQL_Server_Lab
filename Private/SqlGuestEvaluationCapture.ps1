# Erfasst ausschließlich die beobachtbare SQL-Edition; keine Fristheuristik.
function Assert-LabSqlGuestCapturePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Path)
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if (-not (Test-LabPathWithinRoot -Root $rootFull -Path $Path).Valid) { throw 'SQL_GUEST_CAPTURE_PATH_INVALID' }
    # Der gemeinsame Containment-Guard prüft nur unterhalb des Roots.
    $cursor=$rootFull
    while ($cursor) {
        $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'SQL_GUEST_CAPTURE_PATH_INVALID' }
        $parent=[IO.Directory]::GetParent($cursor)
        $cursor=if($parent){$parent.FullName}else{$null}
    }
}

function Get-LabSqlGuestCaptureContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][guid]$RunId,[Parameter(Mandatory)][string]$StateRoot)
    $root=[IO.Path]::GetFullPath($StateRoot).TrimEnd('\','/')
    $directory=Join-Path (Join-Path $root 'runs') $RunId.ToString()
    $statePath=Join-Path $directory 'run-state.json';$connectionPath=Join-Path $directory 'connection-info.json'
    $receiptPath=Join-Path $directory 'sql-guest-evaluation-evidence.json';$lockPath=Join-Path $directory 'sql-guest-evaluation-capture.lock'
    foreach($path in @($statePath,$connectionPath,$receiptPath,$lockPath,
        (Join-Path $directory 'secrets/guest-administrator-password.secret'),
        (Join-Path $directory 'secrets/generated-sql-sa-password.secret'),(Join-Path $directory 'secrets/sa-password.secret'))){
        Assert-LabSqlGuestCapturePath -Root $root -Path $path
    }
    $stateText=[IO.File]::ReadAllText($statePath);$connectionText=[IO.File]::ReadAllText($connectionPath)
    $run=$stateText|ConvertFrom-Json -Depth 30;$connection=$connectionText|ConvertFrom-Json -Depth 30
    $instances=@($connection.instances)
    if([string]$run.runId -ne $RunId.ToString() -or [string]$run.state -ne 'RUNNING' -or
       [string]$run.metadata.workflowKind -ne 'hyperv-lab' -or -not [string]$run.scopeId -or $instances.Count -ne 1){throw 'SQL_GUEST_CAPTURE_BINDING_INVALID'}
    $instance=$instances[0];$ready=$instance.sqlReadiness
    if([string]$instance.provider -ne 'hyperv' -or [string]$instance.workload -ne 'sql' -or
       [string]$instance.sqlVersion -ne '2025' -or -not [string]$instance.id -or -not [string]$instance.vmName -or
       -not [string]$instance.vmId -or -not [string]$run.metadata.imageArtifactId -or
       [string]$instance.imageArtifactId -ne [string]$run.metadata.imageArtifactId -or
       [string]$ready.status -ne 'SQL_READY_RUN' -or [int]$ready.majorVersion -ne 17 -or
       [string]$ready.instanceName -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$' -or -not [string]$ready.edition -or
       -not (Test-LabSqlGuestEditionBinding -SetupEdition ([string]$instance.sqlEdition) -ObservedEdition ([string]$ready.edition) -SqlMajorVersion ([int]$ready.majorVersion)) -or [int]$instance.port -lt 1 -or [int]$instance.port -gt 65535){throw 'SQL_GUEST_CAPTURE_BINDING_INVALID'}
    $managed=Get-HyperVManagedVM -VMName ([string]$instance.vmName) -ExpectedRunId $RunId.ToString() -ExpectedScopeId ([string]$run.scopeId)
    if(-not $managed -or [string]$managed.VM.State -ne 'Running' -or [string]$managed.VM.Id -ne [string]$instance.vmId -or
       [string]$managed.Identity.instanceId -ne [string]$instance.id){throw 'SQL_GUEST_CAPTURE_BINDING_INVALID'}
    $artifacts=@(Get-HyperVImageArtifact -StateRoot $root -SkipIntegrityCheck | Where-Object { [string]$_.artifactId -eq [string]$instance.imageArtifactId })
    if($artifacts.Count -ne 1 -or [string]$artifacts[0].artifactState -ne 'SQL_PREPARED_SEALED' -or [string]$artifacts[0].sql.version -ne '2025'){throw 'SQL_GUEST_CAPTURE_IMAGE_INVALID'}
    $artifact=$artifacts[0]
    $disks=@(Get-VMHardDiskDrive -VM $managed.VM -ErrorAction Stop | Where-Object {[string]$_.Path -eq [string]$managed.Identity.childVhdxPath})
    if($disks.Count -ne 1){throw 'SQL_GUEST_CAPTURE_IMAGE_INVALID'}
    $disk=Get-VHD -Path ([string]$disks[0].Path) -ErrorAction Stop
    if(-not [string]$disk.ParentPath -or [IO.Path]::GetFullPath([string]$disk.ParentPath) -ine [IO.Path]::GetFullPath([string]$artifact.Path)){throw 'SQL_GUEST_CAPTURE_IMAGE_INVALID'}
    $identity=[ordered]@{State=$stateText;Connection=$connectionText;VmId=[string]$managed.VM.Id;Notes=$managed.Identity;Image=$artifact;DiskId=[string]$disk.DiskIdentifier;Parent=[string]$disk.ParentPath}
    $fingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($identity|ConvertTo-Json -Depth 40 -Compress))))
    [pscustomobject]@{Run=$run;Instance=$instance;StateRoot=$root;RunDirectory=$directory;ReceiptPath=$receiptPath;LockPath=$lockPath;Fingerprint=$fingerprint}
}

function Get-LabSqlGuestCaptureClassification {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Observation)
    # Microsoft SERVERPROPERTY: SQL 2025 Enterprise Evaluation und die beiden Developer-Editionen.
    $edition=[string]$Observation.Edition
    switch([long]$Observation.EditionId){
        610778273 {if($edition -notmatch '^(Enterprise )?Evaluation Edition(?: \(64-bit\))?$'){throw 'SQL_GUEST_CAPTURE_EDITION_UNSUPPORTED'};return 'EVALUATION'}
        -2117995310 {if($edition -notmatch '^(Developer|Enterprise Developer|Developer Enterprise) Edition(?: \(64-bit\))?$'){throw 'SQL_GUEST_CAPTURE_EDITION_UNSUPPORTED'};return 'NOT_EVALUATION'}
        -1785266663 {if($edition -notmatch '^(Standard Developer|Developer Standard) Edition(?: \(64-bit\))?$'){throw 'SQL_GUEST_CAPTURE_EDITION_UNSUPPORTED'};return 'NOT_EVALUATION'}
        default {throw 'SQL_GUEST_CAPTURE_EDITION_UNSUPPORTED'}
    }
}

function Invoke-LabSqlGuestCaptureProbe {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][int]$TimeoutSeconds)
    $guest=$null;$sa=$null;$loadedGuest=$null;$loadedSa=$null
    try {
        $fresh=Get-LabSqlGuestCaptureContext -RunId ([guid]$Context.Run.runId) -StateRoot $Context.StateRoot
        if($fresh.Fingerprint -cne $Context.Fingerprint){throw 'SQL_GUEST_CAPTURE_BINDING_CHANGED'}
        $loadedGuest=Get-LabSecret -Path $Context.RunDirectory -Name 'guest-administrator-password'
        $loadedSa=Get-LabSecret -Path $Context.RunDirectory -Name 'generated-sql-sa-password'
        if(-not $loadedSa){$loadedSa=Get-LabSecret -Path $Context.RunDirectory -Name 'sa-password'}
        if(-not $loadedGuest -or -not $loadedSa){throw 'SQL_GUEST_CAPTURE_CREDENTIAL_REQUIRED'}
        $guest=$loadedGuest.Copy();$sa=$loadedSa.Copy()
        $guest.MakeReadOnly();$sa.MakeReadOnly()
        $result=@(Invoke-HyperVPowerShellDirect -VMName ([string]$Context.Instance.vmName) -ExpectedRunId ([string]$Context.Run.runId) `
            -ExpectedScopeId ([string]$Context.Run.scopeId) -ExpectedVmId ([guid]$Context.Instance.vmId) `
            -Credential ([pscredential]::new('Administrator',$guest)) -TimeoutSeconds $TimeoutSeconds `
            -ArgumentList @($sa,[int]$Context.Instance.port,[math]::Min(30,$TimeoutSeconds)) -ScriptBlock {
                param([securestring]$Password,[int]$Port,[int]$SqlTimeout)
                $ErrorActionPreference='Stop';$connection=$null;$command=$null;$reader=$null;$secret=$null
                try {
                    Add-Type -AssemblyName System.Data
                    $secret=$Password.Copy();$secret.MakeReadOnly()
                    $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new()
                    $builder['Data Source']="tcp:127.0.0.1,$Port";$builder['Initial Catalog']='master'
                    $builder['Encrypt']=$true;$builder['TrustServerCertificate']=$true;$builder['Pooling']=$false
                    $builder['Persist Security Info']=$false;$builder['Connect Timeout']=[math]::Min(15,$SqlTimeout)
                    $connection=[Data.SqlClient.SqlConnection]::new($builder.ConnectionString,[Data.SqlClient.SqlCredential]::new('sa',$secret))
                    $connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=$SqlTimeout
                    $command.CommandText="SELECT CONVERT(nvarchar(128),SERVERPROPERTY('Edition')),CONVERT(bigint,SERVERPROPERTY('EditionID')),CONVERT(int,SERVERPROPERTY('ProductMajorVersion')),CONVERT(nvarchar(128),SERVERPROPERTY('InstanceName'));"
                    $reader=$command.ExecuteReader([Data.CommandBehavior]::SequentialAccess)
                    if(-not $reader.Read()){throw 'SQL_GUEST_CAPTURE_PROBE_INVALID'}
                    $edition=if($reader.IsDBNull(0)){$null}else{[string]$reader.GetValue(0)}
                    $editionId=if($reader.IsDBNull(1)){$null}else{[long]$reader.GetValue(1)}
                    $major=if($reader.IsDBNull(2)){$null}else{[int]$reader.GetValue(2)}
                    $instance=if($reader.IsDBNull(3)){'MSSQLSERVER'}else{[string]$reader.GetValue(3)}
                    if(-not $edition -or $null -eq $editionId -or $major -ne 17 -or $reader.Read() -or $reader.NextResult()){throw 'SQL_GUEST_CAPTURE_PROBE_INVALID'}
                    [pscustomobject]@{Edition=$edition;EditionId=$editionId;MajorVersion=$major;InstanceName=$instance}
                }
                catch {throw 'SQL_GUEST_CAPTURE_PROBE_FAILED'}
                finally {if($reader){$reader.Dispose()};if($command){$command.Dispose()};if($connection){$connection.Dispose()};if($secret){$secret.Dispose()}}
            } -ErrorAction Stop)
        if($result.Count -ne 1){throw 'SQL_GUEST_CAPTURE_PROBE_INVALID'}
        return $result[0]
    }
    finally {if($guest){$guest.Dispose()};if($sa){$sa.Dispose()};if($loadedGuest){$loadedGuest.Dispose()};if($loadedSa){$loadedSa.Dispose()}}
}

function Invoke-LabSqlGuestEvaluationCapture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][guid]$RunId,[Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][int]$TimeoutSeconds)
    $context=Get-LabSqlGuestCaptureContext -RunId $RunId -StateRoot $StateRoot
    $lock=$null
    try {
        try{$lock=[IO.FileStream]::new($context.LockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
        catch{throw 'SQL_GUEST_CAPTURE_LOCKED'}
        $bound=Get-LabSqlGuestCaptureContext -RunId $RunId -StateRoot $StateRoot
        if($bound.Fingerprint -cne $context.Fingerprint){throw 'SQL_GUEST_CAPTURE_BINDING_CHANGED'}
        $prior=Get-LabSqlGuestEvaluationEvidence -RunId $RunId.ToString() -StateRoot $context.StateRoot
        if($prior.Status -notin @('VALID','EVIDENCE_MISSING')){throw 'SQL_GUEST_CAPTURE_PRIOR_INVALID'}
        $observation=Invoke-LabSqlGuestCaptureProbe -Context $bound -TimeoutSeconds $TimeoutSeconds
        $classification=Get-LabSqlGuestCaptureClassification -Observation $observation
        if([int]$observation.MajorVersion -ne 17 -or [string]$observation.InstanceName -cne [string]$bound.Instance.sqlReadiness.instanceName -or
            [string]$observation.Edition -cne [string]$bound.Instance.sqlReadiness.edition){throw 'SQL_GUEST_CAPTURE_SQL_IDENTITY_CHANGED'}
        $current=Get-LabSqlGuestCaptureContext -RunId $RunId -StateRoot $StateRoot
        if($current.Fingerprint -cne $bound.Fingerprint){throw 'SQL_GUEST_CAPTURE_BINDING_CHANGED'}
        $now=[datetime]::UtcNow
        $evidence=[pscustomobject][ordered]@{
            Contract=@{Name='SqlServerLab.SqlGuestEvaluationEvidence';Version='1.0'}
            EvidenceId=[guid]::NewGuid().ToString();ObservedAt=$now.ToString('o');RunId=$RunId.ToString();ScopeId=[string]$bound.Run.scopeId
            InstanceId=[string]$bound.Instance.id;Provider='hyperv';VmId=[string]$bound.Instance.vmId;ImageArtifactId=[string]$bound.Instance.imageArtifactId
            SqlInstanceName=[string]$observation.InstanceName;SqlMajorVersion=[int]$observation.MajorVersion;SqlEdition=[string]$observation.Edition
            LicenseClassification=$classification;EvaluationExpiresAt=$null;DeadlineSource='SQL_GUEST_NO_DEADLINE';ObservationStatus='NO_DEADLINE'
            EvidenceFreshUntil=$now.AddHours(24).ToString('o');PreviousEvidenceId=if($prior.Status -eq 'VALID'){[string]$prior.Evidence.EvidenceId}else{$null}
        }
        if(-not (($evidence|ConvertTo-Json -Depth 10)|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'sql-guest-evaluation-evidence.schema.json') -ErrorAction Stop) -or
            -not (Test-LabSqlGuestEvaluationEvidenceSemantics -Evidence $evidence -Run $current.Run -Instance $current.Instance)){throw 'SQL_GUEST_CAPTURE_RECEIPT_INVALID'}
        $result=[pscustomobject]@{Status='UPDATED';RunId=$RunId.ToString();InstanceId=$evidence.InstanceId;EvidenceId=$evidence.EvidenceId;PreviousEvidenceId=$evidence.PreviousEvidenceId;LicenseClassification=$classification;ObservationStatus='NO_DEADLINE';EvaluationExpiresAt=$null;EvidenceFreshUntil=$evidence.EvidenceFreshUntil}
        Assert-LabSqlGuestCapturePath -Root $context.StateRoot -Path $context.ReceiptPath
        Write-LabArtifactJsonAtomic -Path $context.ReceiptPath -InputObject $evidence
        return $result
    }
    finally {if($lock){$lock.Dispose()}}
}
