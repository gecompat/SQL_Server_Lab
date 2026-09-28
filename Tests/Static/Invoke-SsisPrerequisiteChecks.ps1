#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Private/SsisPrerequisite.ps1')
$passed=0;$failed=0
function Check { param($Name,$Success) if($Success){$script:passed++;Write-Host "PASS $Name"}else{$script:failed++;Write-Host "FAIL $Name"} }
$positive=[pscustomobject]@{SqlStatus='OBSERVED';Major=17;Edition='Enterprise Developer Edition (64-bit)';Components='OBSERVED';Catalog='ONLINE_CATALOG_OBSERVED'}
$result=ConvertTo-LabSsisPrerequisiteResult $positive
Check 'Positive Beobachtung ist keine Installations- oder ETL-Freigabe' ($result.Sql -eq 'SQL_2025_OBSERVED' -and $result.Edition -eq 'EnterpriseDeveloper' -and $result.ExecutionStatus -eq 'NOT_EXECUTED' -and -not $result.InstallationVerified)
foreach($state in @('MISSING','NOT_ONLINE','ONLINE_UNVERIFIED','ONLINE_CATALOG_OBSERVED','UNKNOWN')) {
    $copy=$positive.PSObject.Copy();$copy.Catalog=$state
    Check "SSISDB $state bleibt getrennt" ((ConvertTo-LabSsisPrerequisiteResult $copy).SsisDb -eq $state)
}
$copy=$positive.PSObject.Copy();$copy.Major=16
Check 'Falscher tatsächlicher SQL-Major bleibt sichtbar' ((ConvertTo-LabSsisPrerequisiteResult $copy).Sql -eq 'VERSION_MISMATCH')
$private='SYNTHETIC_PRIVATE_DIAGNOSTIC'
$copy=$positive.PSObject.Copy();$copy.Edition=$private;$copy.Components=$private;$copy.Catalog=$private
Check 'Unbekannte Gastwerte und Fehler gelangen nicht in Projektion' (((ConvertTo-LabSsisPrerequisiteResult $copy -FailureCode $private)|ConvertTo-Json) -notmatch $private)
$probe=Get-LabSsisGuestProbe
foreach($name in @('Read-SsisComponentObservation','Read-SsisSqlObservation')) {
    $ast=$probe.Ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($ast.Extent.Text))
}
$componentCases=& {
    function Join-Path { param($Path,$ChildPath) "synthetic/$ChildPath" }
    function Get-Item {
        if($mode -eq 'missing'){throw [Management.Automation.ItemNotFoundException]::new('synthetic missing')}
        if($mode -eq 'denied'){throw [UnauthorizedAccessException]::new('synthetic private denial')}
        [pscustomobject]@{PSIsContainer=$false;Attributes=$(if($mode -eq 'link'){[IO.FileAttributes]::ReparsePoint}else{[IO.FileAttributes]::Normal});VersionInfo=@{FileMajorPart=$(if($mode -eq 'old'){16}else{17})}}
    }
    $values=@{}
    foreach($mode in @('present','missing','denied','link','old')){$values[$mode]=Read-SsisComponentObservation}
    $values
}
Check 'Echter Komponentenleser trennt fehlend, verweigert, Link und falsche Version' ($componentCases.present -eq 'OBSERVED' -and $componentCases.missing -eq 'NOT_OBSERVED' -and $componentCases.denied -eq 'UNKNOWN' -and $componentCases.link -eq 'UNKNOWN' -and $componentCases.old -eq 'UNKNOWN')
foreach($mode in @('online','missing','offline','denied','ordinary-db','query-fault','duplicate')) {
    $table=[Data.DataTable]::new()
    foreach($name in @('Major','Edition','Instance','Sysadmin','State')){$null=$table.Columns.Add($name,[object])}
    $null=$table.Rows.Add(@(17,'Developer Edition (64-bit)','MSSQLSERVER',$(if($mode -eq 'denied'){0}else{1}),$(if($mode -eq 'missing') {[DBNull]::Value}elseif($mode -eq 'offline'){'OFFLINE'}else{'ONLINE'})))
    if($mode -eq 'duplicate'){$null=$table.Rows.Add(@(17,'Developer Edition (64-bit)','MSSQLSERVER',1,'ONLINE'))}
    $command=[pscustomobject]@{CommandText='';CommandTimeout=0;Disposed=$false;Table=$table;Mode=$mode;ScalarCalls=0}
    $command|Add-Member ScriptMethod ExecuteReader {param($Behavior) if($this.Mode -eq 'query-fault'){throw 'synthetic sql fault'};return ,$this.Table.CreateDataReader()}
    $command|Add-Member ScriptMethod ExecuteScalar {$this.ScalarCalls++;if($this.Mode -eq 'ordinary-db'){return 0};return 1}
    $command|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    $connection=[pscustomobject]@{Command=$command};$connection|Add-Member ScriptMethod CreateCommand {return $this.Command}
    $observed=$null;$threw=$false
    try {$observed=Read-SsisSqlObservation -Connection $connection -Timeout 7}catch{$threw=$true}
    $expected=switch($mode){online{'ONLINE_CATALOG_OBSERVED'};missing{'MISSING'};offline{'NOT_ONLINE'};denied{'UNKNOWN'};'ordinary-db'{'ONLINE_UNVERIFIED'};default{''}}
    Check "Echter SQL-Leser $mode und Dispose" ($command.Disposed -and $(if($expected){$observed.Catalog -eq $expected -and -not $threw}else{$threw}))
    if($mode -eq 'denied'){Check 'Ohne volle Sichtrechte keine Abwesenheit und keine Katalogabfrage' ($command.ScalarCalls -eq 0)}
    $table.Dispose()
}
$contextCases=& {
    $id=[guid]'11111111-1111-1111-1111-111111111111';$vmId='22222222-2222-2222-2222-222222222222'
    function Assert-LabDiagnosticPath {param($Path) return $Path}
    function Read-LabDiagnosticJson {
        param($Path)
        if($Path.EndsWith('run-state.json')){return [pscustomobject]@{runId=$id.ToString();scopeId='synthetic';state=$(if($mode -eq 'stopped'){'STOPPED'}else{'RUNNING'});metadata=@{workflowKind='hyperv-lab'}}}
        $instance=[pscustomobject]@{id='primary';provider=$(if($mode -eq 'provider'){'docker'}else{'hyperv'});workload='sql';sqlVersion=$(if($mode -eq 'version'){'2022'}else{'2025'});vmName='synthetic';vmId=$vmId;port=1433;sqlReadiness=@{instanceName='MSSQLSERVER'}}
        [pscustomobject]@{instances=$(if($mode -eq 'duplicate'){@($instance,$instance)}else{@($instance)})}
    }
    function Get-HyperVManagedVM { [pscustomobject]@{VM=@{Id=$(if($mode -eq 'vm'){'33333333-3333-3333-3333-333333333333'}else{$vmId});State='Running'};Identity=@{instanceId=$(if($mode -eq 'instance'){'foreign'}else{'primary'})}} }
    $values=@{}
    foreach($mode in @('valid','stopped','provider','version','duplicate','vm','instance')) {
        try{$context=Get-LabSsisPrerequisiteContext -RunId $id -InstanceId primary -StateRoot ([IO.Path]::GetTempPath());$values[$mode]=[bool]$context.Fingerprint}catch{$values[$mode]=$false}
    }
    $values
}
Check 'Echter Kontext benötigt kein Prepared-Image' $contextCases.valid
foreach($mode in @('stopped','provider','version','duplicate','vm','instance')){Check "Echter Kontext verweigert $mode" (-not $contextCases[$mode])}
$wrapperCases=& {
    $runId=[guid]'11111111-1111-1111-1111-111111111111';$vmId='22222222-2222-2222-2222-222222222222'
    function Get-LabSsisPrerequisiteContext {
        $tracker.Context++
        if($mode -eq 'target'){throw 'SYNTHETIC_PRIVATE_CONTEXT'}
        [pscustomobject]@{Directory='synthetic';Run=@{scopeId='synthetic-scope'};Instance=@{vmName='synthetic';vmId=$vmId;port=1433;sqlReadiness=@{instanceName='MSSQLSERVER'}};Fingerprint=$(if(($mode -eq 'drift' -and $tracker.Context -gt 1) -or ($mode -eq 'post-drift' -and $tracker.Context -gt 2)){'changed'}else{'stable'})}
    }
    function Get-LabSecret { $secret=[securestring]::new();foreach($character in 'synthetic password'.ToCharArray()){$secret.AppendChar($character)};$tracker.Secrets.Add($secret);return $secret }
    function Invoke-HyperVPowerShellDirect {
        param($ExpectedRunId,$ExpectedScopeId,$ExpectedVmId,$TimeoutSeconds,$ArgumentList)
        $tracker.Calls++;$tracker.Bound=($ExpectedRunId -eq $runId.ToString() -and $ExpectedVmId.ToString() -eq $vmId -and $ExpectedScopeId -eq 'synthetic-scope' -and $TimeoutSeconds -eq 12 -and $ArgumentList[0] -is [securestring])
        if($mode -eq 'timeout'){throw 'GUEST_JOB_OPERATION_TIMEOUT SYNTHETIC_PRIVATE_TRANSPORT'}
        if($mode -eq 'extra'){return @($positive,$positive)}
        return $positive
    }
    $values=@{}
    foreach($mode in @('success','target','timeout','drift','post-drift','extra')) {
        $tracker=@{Context=0;Calls=0;Bound=$false;Secrets=[Collections.Generic.List[securestring]]::new()}
        $value=Invoke-LabSsisPrerequisite -RunId $runId -InstanceId primary -StateRoot synthetic -TimeoutSeconds 12
        $disposed=$true;foreach($secret in $tracker.Secrets){try{$copy=$secret.Copy();$copy.Dispose();$disposed=$false}catch [ObjectDisposedException]{}}
        $values[$mode]=@{Value=$value;Calls=$tracker.Calls;Bound=$tracker.Bound;Disposed=$disposed}
    }
    $values
}
Check 'Wrapper bindet tatsächlichen VM-ID-Transport und entsorgt Secrets' ($wrapperCases.success.Bound -and $wrapperCases.success.Disposed -and $wrapperCases.success.Value.Sql -eq 'SQL_2025_OBSERVED')
Check 'Targetfehler und Drift öffnen keinen Gast' ($wrapperCases.target.Calls -eq 0 -and $wrapperCases.drift.Calls -eq 0)
Check 'Timeout bleibt sanitisiert, Secrets entsorgt' ($wrapperCases.timeout.Value.ReasonCode -eq 'SSIS_PROBE_UNAVAILABLE' -and $wrapperCases.timeout.Disposed -and ($wrapperCases.timeout.Value|ConvertTo-Json) -notmatch 'PRIVATE')
Check 'Mehrere Gastresultate werden abgewiesen' ($wrapperCases.extra.Value.ReasonCode -eq 'SSIS_PROBE_UNAVAILABLE')
Check 'Nachträgliche Bindungsänderung verwirft Gastbeobachtung' ($wrapperCases['post-drift'].Value.ReasonCode -eq 'SSIS_BINDING_CHANGED' -and $wrapperCases['post-drift'].Value.Sql -eq 'UNKNOWN')
Check 'Gastskript enthält keine Installation oder SQL-Mutation' ($probe.ToString() -notmatch '(?i)Start-Process|Start-Service|CREATE DATABASE|ALTER DATABASE|Invoke-Expression')
Write-Host "Ergebnis: $passed PASS, $failed FAIL"
if($failed){exit 1}
