#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Private/SsisOwnedInstall.ps1')
$passed=0;$failed=0
function Check {param($Name,$Success)if($Success){$script:passed++;Write-Host "PASS $Name"}else{$script:failed++;Write-Host "FAIL $Name"}}
foreach($case in @('same','child','outside')){
    $path=switch($case){same{$repoRoot};child{Join-Path $repoRoot 'synthetic-state'};outside{Join-Path ([IO.Path]::GetTempPath()) 'synthetic-state'}}
    $blocked=$false;try{Assert-LabSsisEvidenceLocation -StateRoot $path -RepositoryRoot $repoRoot}catch{$blocked=$true}
    Check "Lokale Evidence $case" ($blocked -eq ($case -ne 'outside'))
}
$localFailure=& {
    function Add-Content {throw 'SYNTHETIC_PRIVATE_STORAGE_FAILURE'}
    $errorObject=[InvalidOperationException]::new('SYNTHETIC_PRIVATE_PRIMARY')
    $errorObject.Data['PrimaryFailure']='SYNTHETIC_PRIVATE_PRIMARY';$errorObject.Data['CleanupFailure']='SYNTHETIC_PRIVATE_CLEANUP';$errorObject.Data['RecoveryRequired']=$true
    $record=[Management.Automation.ErrorRecord]::new($errorObject,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null)
    @(New-LabSsisLocalFailure -Failure $record -LogPath 'synthetic.log' *>&1)
}
Check 'Diagnose-Schreibfehler verdrängt Primär-/Cleanupfehler nicht und exportiert keine Rohdaten' ($localFailure.Count -eq 1 -and $localFailure[0].Data['PrimaryFailure'] -eq 'SSIS_INSTALL_OPERATION_FAILED' -and $localFailure[0].Data['CleanupFailure'] -eq 'SSIS_INSTALL_CLEANUP_FAILED' -and $localFailure[0].Data['RecoveryRequired'] -and $localFailure[0].Data['EvidenceFailure'] -eq 'SSIS_INSTALL_DIAGNOSTIC_WRITE_FAILED' -and ($localFailure|Out-String) -notmatch 'SYNTHETIC_PRIVATE')
$operation='ssis-install-'+('a'*32);$vm=[guid]'11111111-1111-1111-1111-111111111111'
function New-SyntheticBinding {
    @{Lab=[pscustomobject]@{Run=@{metadata=@{workflowOperationId=$operation;workflowKind='hyperv-lab'}};
        Instance=@{provider='hyperv';vmId=$vm.ToString();workload='windows';windowsProvisioning=@{state='COMPLETE'}}};
      Managed=@{VM=@{Id=$vm;State='Off'}};OperationId=$operation;Sha256='a'*64;VmId=$vm;SqlVersion='2025';MediaEdition='Enterprise';Features=@('SQLENGINE','IS')}
}
foreach($case in @('valid','operation','hash','vm','provider','workload','running','version','edition','extra-feature','missing-feature')){
    $binding=New-SyntheticBinding
    switch($case){operation{$binding.Lab.Run.metadata.workflowOperationId='other'};hash{$binding.Sha256='x'};vm{$binding.Managed.VM.Id=[guid]::NewGuid()};
        provider{$binding.Lab.Instance.provider='docker'};workload{$binding.Lab.Instance.workload='sql'};running{$binding.Managed.VM.State='Running'};
        version{$binding.SqlVersion='2022'};edition{$binding.MediaEdition='Standard'};'extra-feature'{$binding.Features+= 'SDK'};'missing-feature'{$binding.Features=@('SQLENGINE')}}
    $blocked=$false;try{Assert-LabSsisInstallBinding @binding}catch{$blocked=$true}
    Check "Produktbindung $case" ($blocked -eq ($case -ne 'valid'))
}
$installerSource=Get-Content -LiteralPath (Join-Path $repoRoot 'Private/SsisOwnedInstall.ps1') -Raw
$editionGuard=([scriptblock]::Create($installerSource)).Ast.Find({param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match 'SSIS_COMPONENT_ENTERPRISE_DEVELOPER_REQUIRED'
},$true)
foreach($edition in @('EnterpriseDeveloper','Developer','StandardDeveloper','Enterprise','UNKNOWN')){
    $blocked=$false;$preflight=[pscustomobject]@{Edition=$edition}
    try {& ([scriptblock]::Create($editionGuard.Extent.Text))}catch{$blocked=$_.Exception.Message -eq 'SSIS_COMPONENT_ENTERPRISE_DEVELOPER_REQUIRED'}
    Check "Tatsächliche Editionsadmission vor Medien/Setup: $edition" ($blocked -eq ($edition -notin @('EnterpriseDeveloper','Developer')))
}
$preparedFixtureSource=[regex]::Match($installerSource,'(?s)function Invoke-LabSsisPreparedFixtureRun \{.*?(?=function Invoke-LabSsisOwnedTransaction)').Value
Check 'IS-Installationslauf fordert keine Windows-Aktivierung und keinen Egress an' ($preparedFixtureSource -match "windowsActivation=\[ordered\]@\{ContractVersion='SqlServerLab\.WindowsActivationIntent/1\.0';Strategy='NotRequested';EgressPolicy='Denied'\}")
Check 'Langer SSIS-Gasttransport besitzt einen eigenstaendigen Fortschrittsreporter' ($installerSource -match '\$blockingProgress=Start-LabBlockingActionProgress -Phase GuestWait' -and $installerSource -match 'finally \{if\(\$blockingProgress\)\{Stop-LabBlockingActionProgress -Handle \$blockingProgress\}')
$arguments=@(Get-LabSsisSetupArguments)
Check 'Setup benötigt keine Dienstsecrets und deaktiviert Updates sowie den für SSISDB unnötigen Legacydienst' ($arguments.Count -eq 4 -and $arguments -contains '/UpdateEnabled=False' -and $arguments -contains '/USEMICROSOFTUPDATE=False' -and $arguments -contains '/ISSVCACCOUNT="NT AUTHORITY\NETWORK SERVICE"' -and $arguments -contains '/ISSVCStartupType=Disabled' -and $installerSource -notmatch '/ISSVCStartupType=Automatic')
Check 'SSISDB-Fixture erstellt den Katalog über Microsofts installierte, versionsgebundene Management-API' ($installerSource -match 'Microsoft.SqlServer.Management.IntegrationServices, Version=17.0.0.0' -and $installerSource -match '\$catalog.Create\(\)' -and $installerSource -notmatch 'RESTORE DATABASE \[SSISDB\]' -and $installerSource -notmatch '(?i)(Invoke-WebRequest|Start-BitsTransfer|winget|choco|Install-Module)')
$catalogProbe=Get-LabSsisCatalogFixtureGuestProbe
$executionGuard=$catalogProbe.Ast.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text -match 'SSIS_FIXTURE_EXECUTION_STATUS_INVALID'},$true)
foreach($executionCase in @('accepted','pending','unexpected-end')){
    $success=[int64]1;$failure=[int64]2;$incomplete=[int64]3
    $states=@{'1'=7;'2'=4;'3'=1}
    if($executionCase -eq 'pending'){$states['1']=5}
    if($executionCase -eq 'unexpected-end'){$states['1']=6}
    $observedError=$null
    try {& ([scriptblock]::Create($executionGuard.Extent.Text))}catch{$observedError=$_.Exception.Message}
    $expectedError='SSIS_FIXTURE_EXECUTION_STATUS_INVALID:Success={0};Failure=4;Incomplete=1' -f $states['1']
    Check "Ausführungsfehler behält sichere numerische Statusdiagnose: $executionCase" $(if($executionCase -eq 'accepted'){-not $observedError}else{$observedError -ceq $expectedError})
}
Check 'Lokale Fixture übernimmt keinen globalen Scale-Out-Default' ($installerSource -match '@use32bitruntime=0,@runinscaleout=0,@execution_id=@id OUTPUT')
$passwordAst=$catalogProbe.Ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$catalogPassword' -and $n.Right.Extent.Text -match 'NewGuid'},$true)
$generatedPassword=& { . ([scriptblock]::Create($passwordAst.Extent.Text)); $catalogPassword }
Check 'Generiertes Katalogkennwort erfüllt alle vier Komplexitätsklassen ohne festen Secretwert' ($generatedPassword.Length -ge 32 -and $generatedPassword -cmatch '[a-z]' -and $generatedPassword -cmatch '[A-Z]' -and $generatedPassword -match '[0-9]' -and $generatedPassword -match '[^a-zA-Z0-9]' -and $installerSource -match 'finally \{[^\r\n]*\$catalogPassword=\$null\}')
$writerAst=$catalogProbe.Ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-SsisFixtureProject'},$true)
. ([scriptblock]::Create($writerAst.Extent.Text))
$formatDirectory=Join-Path ([IO.Path]::GetTempPath()) ('ssis-opc-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $formatDirectory
try {
    $archivePath=Write-SsisFixtureProject -Directory $formatDirectory -ProjectName 'LabStaticFormat'
    $archive=[IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $entries=@($archive.Entries.FullName)
        Check 'Tatsächliche ISPAC enthält OPC-Typen, Projektmanifest, Parameter und genau drei Packages' ($entries.Count -eq 6 -and @('@Project.manifest','[Content_Types].xml','Project.params','Success.dtsx','Failure.dtsx','Incomplete.dtsx'|Where-Object {$_ -cnotin $entries}).Count -eq 0)
        $reader=[IO.StreamReader]::new($archive.GetEntry('@Project.manifest').Open())
        try {[xml]$manifestXml=$reader.ReadToEnd()}finally{$reader.Dispose()}
        $ns=[Xml.XmlNamespaceManager]::new($manifestXml.NameTable);$ns.AddNamespace('s','www.microsoft.com/SqlServer/SSIS')
        $meta=@($manifestXml.SelectNodes('//s:PackageMetaData',$ns))
        Check 'Projektmanifest bindet alle Pakete und die von Microsofts Reader benötigten Eigenschaften' ($meta.Count -eq 3 -and @($manifestXml.SelectNodes('//s:Packages/s:Package[@s:EntryPoint="1"]',$ns)).Count -eq 3 -and @($meta|Where-Object { -not $_.SelectSingleNode('s:Properties/s:Property[@s:Name="VersionComments"]',$ns) -or -not $_.SelectSingleNode('s:Properties/s:Property[@s:Name="Description"]',$ns)}).Count -eq 0)
    } finally {$archive.Dispose()}
} finally {Remove-Item -LiteralPath $formatDirectory -Recurse -Force}
$collisionOperation='ssis-install-'+[guid]::NewGuid().ToString('N')
$collisionDirectory=Join-Path ([IO.Path]::GetTempPath()) ('SqlServerLab-Ssis-'+$collisionOperation.Substring($collisionOperation.Length-12))
$null=New-Item -ItemType Directory -Path $collisionDirectory -ErrorAction Stop
$collisionSentinel=Join-Path $collisionDirectory 'synthetic-sentinel'
[IO.File]::WriteAllText($collisionSentinel,'SYNTHETIC')
try {
    $blocked=$false
    try {& $catalogProbe $collisionOperation $false}catch{$blocked=$true}
    Check 'Tatsächliche Gastprobe bewahrt ein schon vorhandenes Tempverzeichnis und erreicht keine SQL-Aktion' ($blocked -and [IO.File]::Exists($collisionSentinel))
} finally {
    # Only the file created here and its now-empty exact directory; no recursion.
    [IO.File]::Delete($collisionSentinel)
    if([IO.Directory]::Exists($collisionDirectory)){[IO.Directory]::Delete($collisionDirectory)}
}
Check 'SSISDB verlangt gemäß Microsoft keinen gestarteten Legacy-Paketdienst' ($installerSource -match 'MsDtsServer170' -and $installerSource -match 'LegacyServiceStatus' -and $installerSource -notmatch '\$service\.Start\(\)|\$service\.WaitForStatus\(|SSIS_INSTALL_SERVICE_START_FAILED')
Check 'SQL-Postcondition wartet nach Neustart lokal und begrenzt auf den Diensttransport' ($installerSource -match '\$sqlDeadline=\[datetime\]::UtcNow\.AddSeconds\(180\)' -and $installerSource -match 'Pooling=False' -and $installerSource -match 'SSIS_INSTALL_SQL_LOCAL_READY_TIMEOUT' -and $installerSource -match 'Start-Sleep -Seconds 5')
Check 'Der Gasttransport umfasst den begrenzten SQL-Readiness-Retry' ($installerSource -match 'Get-LabSsisInstallGuestProbe\) -ArgumentList @\(\$true,\$true\) -NoRetry -TimeoutSeconds 300')
Check 'SSISDB-Fixture bildet Erfolg, Fehler und ungestarteten Fall über Katalogausführungen ab' ($installerSource -match 'Success\.dtsx' -and $installerSource -match 'Failure\.dtsx' -and $installerSource -match 'Incomplete\.dtsx' -and $installerSource -match '\[catalog\]\.\[create_execution\]' -and $installerSource -match '\[catalog\]\.\[start_execution\]')
Check 'SSISDB-Fixture bindet Katalognamen und Execution-IDs mit ihren echten SQL-Typen' ($installerSource -match 'SqlDbType\]::NVarChar,128' -and $installerSource -match 'SqlDbType\]::BigInt' -and $installerSource -notmatch 'Invoke-FixtureCommand[\s\S]*SqlDbType\]::Variant')
Check 'SSISDB-Fixture löscht ausschließlich den eigenen Katalogordner' ($installerSource -match '\[catalog\]\.\[delete_folder\].*@folder_name=@folder' -and $installerSource -notmatch '(?i)(drop database\s+ssisdb|catalog\]\.\[delete_catalog)')
$cleanupSql=Get-LabSsisFixtureCleanupSql
Check 'Cleanup beendet nur quittierte aktive Ausführungen vor der Löschung und wartet begrenzt ohne gehaltene Katalogtransaktion' ($cleanupSql.IndexOf('COMMIT TRANSACTION;') -lt $cleanupSql.IndexOf('EXEC [catalog].[stop_operation]') -and $cleanupSql.IndexOf('EXEC [catalog].[stop_operation]') -lt $cleanupSql.IndexOf('EXEC [catalog].[delete_project]') -and $cleanupSql -match 'project_lsn=@currentVersion AND status IN\(2,5\)' -and $cleanupSql -match 'DATEADD\(second,30,SYSUTCDATETIME\(\)\)' -and $cleanupSql -match 'SSIS_FIXTURE_EXECUTION_STOP_NOT_CONFIRMED' -and $cleanupSql -match 'SSIS_FIXTURE_FOREIGN_EXECUTION_RETAINED')
Check 'Cleanup prüft Ownership nach dem Stoppen erneut, bevor Objekte gelöscht werden' ([regex]::Matches($cleanupSql,'SSIS_FIXTURE_PROJECT_BINDING_CHANGED').Count -eq 4 -and $cleanupSql.LastIndexOf('SSIS_FIXTURE_PROJECT_BINDING_CHANGED') -gt $cleanupSql.IndexOf('stop_operation'))
Check 'Cleanup verwirft einen konkurrierenden Start auch nach dem Settlement vor der Löschung' ($cleanupSql.LastIndexOf('SSIS_FIXTURE_EXECUTION_STOP_NOT_CONFIRMED') -gt $cleanupSql.LastIndexOf('SSIS_FIXTURE_PROJECT_BINDING_CHANGED') -and $cleanupSql.LastIndexOf('SSIS_FIXTURE_EXECUTION_STOP_NOT_CONFIRMED') -lt $cleanupSql.IndexOf('EXEC [catalog].[delete_project]'))
$journalDirectory=Join-Path ([IO.Path]::GetTempPath()) ('ssis-journal-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $journalDirectory
try {
    $journalCases=& {
        $id=[guid]::NewGuid()
        function Read-LabDiagnosticJson {param($Path) Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}
        # Execute the real file guard without the unrelated Windows/provider
        # admission. This regression must run identically on both CI platforms.
        $creation=(Get-Command Invoke-LabSsisExistingCatalogFixture).ScriptBlock
        $journalGuard=$creation.Ast.Find({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match 'SSIS_FIXTURE_RECOVERY_REQUIRED'},$true)
        if(-not $journalGuard){throw 'SSIS_JOURNAL_GUARD_MISSING'}
        $guard=[scriptblock]::Create($journalGuard.Extent.Text)
        $values=@{}
        $path=Join-Path $journalDirectory 'ssis-fixture-operation.json'
        foreach($mode in @('STARTED','FAILED_FINAL_STATE_REQUIRES_INSPECTION','FIXTURE_RECEIPT_RECORDED','REMOVED','FOREIGN')){
            @{RunId=$(if($mode -eq 'FOREIGN'){[guid]::NewGuid().ToString()}else{$id.ToString()});Status=$(if($mode -eq 'FOREIGN'){'REMOVED'}else{$mode});OperationId='SYNTHETIC_PRESERVE'}|ConvertTo-Json|Set-Content -LiteralPath $path
            $before=(Get-FileHash -LiteralPath $path).Hash
            $observed=''
            $RunId=$id;$operationPath=$path
            try {& $guard;throw 'SYNTHETIC_SECRET_REACHED'}catch{$observed=$_.Exception.Message}
            $values[$mode]=[pscustomobject]@{Error=$observed;Preserved=((Get-FileHash -LiteralPath $path).Hash -ceq $before)}
        }
        $values
    }
    foreach($mode in $journalCases.Keys){
        $case=$journalCases[$mode]
        Check "Echtes Recoveryjournal $mode wird vor Secret-/Gastzugriff geprüft und erhalten" ($case.Preserved -and $(if($mode -eq 'REMOVED'){$case.Error -ceq 'SYNTHETIC_SECRET_REACHED'}else{$case.Error -like 'SSIS_FIXTURE_RECOVERY_REQUIRED:*'}))
    }
} finally {
    foreach($name in @('ssis-fixture-operation.json','ssis-fixture-operation.lock')){$path=Join-Path $journalDirectory $name;if(Test-Path -LiteralPath $path){[IO.File]::Delete($path)}}
    [IO.Directory]::Delete($journalDirectory)
}
Check 'Recoveryguard liegt im produktiven Erstellungsablauf vor dem Secret-/Gastzugriff' ($installerSource.IndexOf("throw 'SSIS_FIXTURE_RECOVERY_REQUIRED:") -lt $installerSource.IndexOf("`$guest=Get-LabSecret",$installerSource.IndexOf('function Invoke-LabSsisExistingCatalogFixture')))
Check 'Projekt wird vor dem leeren Ordner über die offiziellen APIs gelöscht' ($cleanupSql.IndexOf('EXEC [catalog].[delete_project]') -lt $cleanupSql.IndexOf('EXEC [catalog].[delete_folder]') -and $cleanupSql -match 'SSIS_FIXTURE_FOREIGN_RESOURCES_RETAINED' -and $cleanupSql -match 'object_version_lsn' -and $cleanupSql -match 'project_lsn=@currentVersion')
Check 'Fixture setzt nur das Logging ihrer eigenen Ausführungen explizit auf Basic' ($installerSource -match 'set_execution_parameter_value' -and $installerSource -match "@object_type=50,@parameter_name=N'LOGGING_LEVEL'" -and $installerSource -notmatch '\[catalog\]\.\[configure_catalog\]')
$cleanupGuards=& {
    $values=@{};$run=[guid]'11111111-1111-1111-1111-111111111111'
    function Get-LabSsisPrerequisiteContext { [pscustomobject]@{Directory='synthetic'} }
    function Read-LabDiagnosticJson {$receipt}
    function Get-LabSecret {$calls++;throw 'SECRET_MUST_NOT_BE_READ'}
    foreach($mode in @('folder-token','folder-id','operation','project-token','negative-project','incomplete-project-binding')){
        $receipt=[pscustomobject]@{RunId=$run.ToString();InstanceId='primary';SourceBinding='OWNED_EXISTING_HYPERV_RUN';OperationId=('ssis-install-'+('a'*32));FolderName=('LabFixture_'+('a'*12));FolderId=1;ProjectName=('LabProject_'+('a'*12));ProjectId=1;ProjectVersionLsn=1}
        switch($mode){'folder-token'{$receipt.FolderName='LabFixture_'+('b'*12)};'folder-id'{$receipt.FolderId=0};operation{$receipt.OperationId='invalid'};'project-token'{$receipt.ProjectName='LabProject_'+('b'*12)};'negative-project'{$receipt.ProjectId=-1};'incomplete-project-binding'{$receipt.ProjectVersionLsn=0}}
        $calls=0;$blocked=$false
        try {Remove-LabSsisExistingCatalogFixture -RunId $run -InstanceId primary -StateRoot synthetic}
        catch {$blocked=$_.Exception.Message -eq 'SSIS_FIXTURE_CLEANUP_BINDING_INVALID'}
        $values[$mode]=$blocked -and $calls -eq 0
    }
    $values
}
foreach($mode in $cleanupGuards.Keys){Check "Gezielter Cleanup verwirft veränderte Receipt vor Secret/Gast: $mode" $cleanupGuards[$mode]}
$creator=([scriptblock]::Create($installerSource)).Ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-LabSsisExistingCatalogFixture'},$true)
$creatorTry=@($creator.Body.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[0]
$leaseGuard=[scriptblock]::Create(($creatorTry.Body.Statements[0..3].Extent.Text -join "`n"))
$leaseFinally=[scriptblock]::Create(($creatorTry.Finally.Statements.Extent.Text -join "`n"))
$leaseDirectory=Join-Path ([IO.Path]::GetTempPath()) ('ssis-lease-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $leaseDirectory
try {
    $leaseCases=& {
        $context=[pscustomobject]@{Directory=$leaseDirectory};$guest=$null;$lease=$null
        $receiptFile=Join-Path $leaseDirectory 'ssis-fixture-receipt.json'
        [IO.File]::WriteAllText($receiptFile,'SYNTHETIC_RECEIPT')
        $duplicate=$false
        try {. $leaseGuard}catch{$duplicate=$_.Exception.Message -match '^SSIS_FIXTURE_ALREADY_EXISTS'}finally{. $leaseFinally}
        [IO.File]::Delete($receiptFile)
        $held=[IO.FileStream]::new((Join-Path $leaseDirectory 'ssis-fixture-operation.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $busy=$false;$lease=$null
        try {try {. $leaseGuard}catch{$busy=$_.Exception.Message -eq 'SSIS_FIXTURE_OPERATION_IN_PROGRESS_OR_STATE_LOCK_UNAVAILABLE'}}finally{$held.Dispose();. $leaseFinally}
        $released=$false
        try {. $leaseGuard;$released=$true}finally{. $leaseFinally}
        [pscustomobject]@{Duplicate=$duplicate;Busy=$busy;Released=$released}
    }
    Check 'Tatsächliche Erstellungs-Lease verhindert Receiptüberschreiben und Parallelität, gibt die Sperre wieder frei' ($leaseCases.Duplicate -and $leaseCases.Busy -and $leaseCases.Released)
} finally {
    foreach($name in @('ssis-fixture-receipt.json','ssis-fixture-operation.lock')){$file=Join-Path $leaseDirectory $name;if([IO.File]::Exists($file)){[IO.File]::Delete($file)}}
    [IO.Directory]::Delete($leaseDirectory)
}
$probeTry=@($catalogProbe.Ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[0]
$probeFinally=[scriptblock]::Create(($probeTry.Finally.Statements.Extent.Text -join "`n"))
$cleanupFailureCase=& {
    $events=[Collections.Generic.List[string]]::new()
    $connection=[pscustomobject]@{Events=$events};$connection|Add-Member -MemberType ScriptMethod -Name Dispose -Value {$this.Events.Add('connection-disposed')}
    $catalogConnection=[pscustomobject]@{Events=$events}
    $catalogConnection|Add-Member -MemberType ScriptMethod -Name CreateCommand -Value {throw 'SYNTHETIC_CLEANUP_FAILURE'}
    $catalogConnection|Add-Member -MemberType ScriptMethod -Name Dispose -Value {$this.Events.Add('catalog-disposed')}
    $folderCreated=$true;$RetainFolder=$false;$accepted=$false;$temporaryCreated=$false
    $primaryFailure=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('SYNTHETIC_PRIMARY'),'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null)
    & $probeFinally
    [pscustomobject]@{Primary=$primaryFailure;Events=($events -join ',')}
}
Check 'Tatsächliches Gast-finally entsorgt Verbindungen trotz Cleanupfehler und bewahrt Primär-/Recoverybefund' ($cleanupFailureCase.Primary.Exception.Message -eq 'SYNTHETIC_PRIMARY' -and $cleanupFailureCase.Primary.Exception.Data['CleanupFailure'] -eq 'SSIS_FIXTURE_CLEANUP_FAILED' -and $cleanupFailureCase.Primary.Exception.Data['RecoveryRequired'] -and $cleanupFailureCase.Events -eq 'catalog-disposed,connection-disposed')

$temporary=Join-Path ([IO.Path]::GetTempPath()) ('ssis-offline-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temporary
$file=Join-Path $temporary 'synthetic.iso';[IO.File]::WriteAllText($file,'SYNTHETIC_ISO_BYTES')
$hash=(Get-FileHash -LiteralPath $file).Hash
try {
    $mediaCases=& {
        function Assert-LabDiagnosticPath {param($Path) $Path}
        function Resolve-HyperVSqlInstallationMedia { [pscustomobject]@{IsoPath=$file;HashStatus=$(if($mode -eq 'sidecar-missing'){'MISSING'}else{'SIDECAR_READY'});ExpectedSha256=$(if($mode -eq 'sidecar-drift'){'f'*64}else{$hash})} }
        $values=@{}
        foreach($mode in @('valid','sidecar-missing','sidecar-drift','content-drift')){
            $held=$null;$blocked=$false
            if($mode -eq 'content-drift'){[IO.File]::WriteAllText($file,'CHANGED_SYNTHETIC_BYTES')}
            try{$held=Open-LabSsisApprovedMedia -MediaRoot $temporary -SqlMediaPath 'SQL/synthetic.iso' -ExpectedSha256 $hash}catch{$blocked=$true}
            finally{if($held){$held.Handle.Dispose()}}
            $values[$mode]=$blocked
        }
        $values
    }
    foreach($name in $mediaCases.Keys){Check "Echter Samehandle-Hash $name" ($mediaCases[$name] -eq ($name -ne 'valid'))}
}finally{[IO.File]::Delete($file);[IO.Directory]::Delete($temporary)}

foreach($mode in @('success','partial-arrange','verify-fault','cleanup-fault','both')){
    $events=[Collections.Generic.List[string]]::new();$caught=$null;$result=$null
    try{
        $result=Invoke-LabSsisOwnedTransaction -Arrange {$events.Add('arrange');if($mode -in @('partial-arrange','both')){throw 'SYNTHETIC_PRIMARY'};'own-run'} `
            -Verify {param($Run)$events.Add('verify');if($Run -ne 'own-run'){throw 'binding'};if($mode -eq 'verify-fault'){throw 'SYNTHETIC_PRIMARY'}} `
            -Cleanup {$events.Add('cleanup');if($mode -in @('cleanup-fault','both')){throw 'SYNTHETIC_CLEANUP'}}
    }catch{$caught=$_}
    Check "Cleanup läuft nach jedem begonnenen Arrange: $mode" ($events[-1] -eq 'cleanup' -and @($events|Where-Object {$_ -eq 'cleanup'}).Count -eq 1)
    if($mode -eq 'success'){Check 'PASS setzt erfolgreiche Verify und Cleanup voraus, ETL bleibt offen' ($result.Status -eq 'IS_INSTALL_AND_RESTART_PASSED' -and $result.Etl -eq 'NOT_EXECUTED' -and $result.SsisDb -eq 'NOT_PROVISIONED')}
    else{Check "Primär- und Cleanupfehler getrennt: $mode" ($caught.Exception.Data['RecoveryRequired'] -eq ($mode -in @('cleanup-fault','both')) -and [bool]$caught.Exception.Data['PrimaryFailure'] -eq ($mode -ne 'cleanup-fault'))}
}

# Execute the actual plan function, proving rejection precedes any VM mutation.
$tokens=$null;$errors=$null
$source=Join-Path $repoRoot 'Private/HyperVLabEnvironment.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
Check 'Geänderter produktiver Installer ist parsebar' ($errors.Count -eq 0)
$planAst=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-HyperVLabSqlDeploymentPlan'},$true)
. ([scriptblock]::Create($planAst.Extent.Text))
$planCases=& {
    function Assert-LabWindowsPoolMutationAllowed {param($RunId,$StateRoot,[switch]$InvalidateEvidence) if($RunId -cne 'synthetic'){throw 'SYNTHETIC_POOL_GUARD_SCOPE_MISMATCH'}}
    function Get-HyperVLabWorkflowRun { $lab }
    function Get-HyperVManagedVM { $managed }
    function Set-VMProcessor { $events.Add('processor') }
    function Set-VMMemory { $events.Add('memory') }
    function Write-LabArtifactJsonAtomic { $events.Add('persist') }
    function Get-LabTimestamp {'synthetic'}
    $values=@{}
    foreach($case in @('normal','ssis','unbound-is','old-version','existing-plan')){
        $binding=New-SyntheticBinding;$lab=$binding.Lab;$managed=$binding.Managed
        $lab|Add-Member NoteProperty RunDirectory $repoRoot;$lab|Add-Member NoteProperty Connection @{}
        $lab.Run.runId='synthetic';$lab.Run.scopeId='synthetic';$lab.Instance.vmName='synthetic'
        $events=[Collections.Generic.List[string]]::new();$blocked=$false
        $parameters=@{RunId='synthetic';SqlVersion='2025';DeploymentMode='adhoc-install';MediaEdition='Enterprise';SqlMediaPath='SQL/synthetic.iso'}
        if($case -ne 'normal'){$parameters.SqlFeatures=@('SQLENGINE','IS')}
        if($case -in @('ssis','old-version','existing-plan')){$parameters.SsisOperationId=$operation;$parameters.ExpectedSqlMediaSha256='a'*64;$parameters.ExpectedVmId=$vm}
        if($case -eq 'old-version'){$parameters.SqlVersion='2022'}
        if($case -eq 'existing-plan'){$lab.Instance.sqlDeploymentPlan=@{state='PLANNED'}}
        try{$null=Set-HyperVLabSqlDeploymentPlan @parameters}catch{$blocked=$true}
        $values[$case]=@{Blocked=$blocked;Events=@($events);Plan=$lab.Instance.sqlDeploymentPlan}
    }
    $values
}
foreach($case in @('unbound-is','old-version','existing-plan')){Check "Plan $case vor Hardwaremutation blockiert" ($planCases[$case].Blocked -and $planCases[$case].Events.Count -eq 0)}
Check 'Normaler Nicht-IS-Plan behält Defaults ohne Bindung' (-not $planCases.normal.Blocked -and -not $planCases.normal.Plan.ssisBinding -and @($planCases.normal.Plan.features).Count -eq 3)
Check 'IS-Plan persistiert explizite Freigabe und VM-Bindung' (-not $planCases.ssis.Blocked -and $planCases.ssis.Plan.ssisBinding.VmId -eq $vm.ToString() -and $planCases.ssis.Plan.ssisBinding.OperationId -ceq $operation)
$installAst=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-HyperVLabSqlSlotInstall'},$true)
$assignment=$installAst.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$arguments' -and $n.Right.Extent.Text -match '/ACTION=Install'},$true)
$append=$installAst.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Extent.Text -eq '$arguments += @($SsisArguments)'},$true)
$setupArguments=& {
    $features=@('SQLENGINE','IS');$SsisArguments=@(Get-LabSsisSetupArguments)
    . ([scriptblock]::Create($assignment.Extent.Text))
    . ([scriptblock]::Create($append.Extent.Text))
    $arguments
}
Check 'Tatsächliche Gast-Setupargumente enthalten IS und Updatesperre ohne SDK/ScaleOut' ($setupArguments -contains '/FEATURES=SQLENGINE,IS' -and $setupArguments -contains '/UpdateEnabled=False' -and $setupArguments -contains '/USEMICROSOFTUPDATE=False' -and ($setupArguments -join ' ') -notmatch '(?:SDK|IS_Master|IS_Worker)')
$cleanupCases=& {
    function Get-LabOperationOwnedRun {if($mode -ne 'no-run'){$owned}}
    function Get-CleanupPlan {$plan}
    function Test-HyperVPathWithinRunDirectory {$mode -ne 'foreign-path'}
    function Get-HyperVManagedVM {[pscustomobject]@{VM=@{Id=$(if($mode -eq 'vm-drift'){[guid]::NewGuid()}else{$vm})}}}
    function Remove-SqlServerLab {$events.Add('remove');[pscustomobject]@{RunId=$owned.runId;Status='REMOVED';Cleanup=$(if($mode -eq 'remove-fault'){'FAILED'}else{'CLEANUP_SUCCEEDED'})}}
    function Get-VM {if($mode -eq 'vm-remains'){@{Id=$vm}}}
    function Test-Path {$mode -eq 'disk-remains'}
    $values=@{}
    foreach($mode in @('no-run','partial-before-vm','valid','foreign-operation','foreign-plan','foreign-path','vm-drift','remove-fault','vm-remains','disk-remains')){
        $events=[Collections.Generic.List[string]]::new()
        $owned=[pscustomobject]@{runId='22222222-2222-2222-2222-222222222222';scopeId='33333333-3333-3333-3333-333333333333';metadata=@{workflowKind='hyperv-lab';workflowOperationId=$operation}}
        $plan=[pscustomobject]@{runId=$owned.runId;scopeId=$owned.scopeId;steps=@(@{provider='hyperv';resourceType='vhdx';resourceId='synthetic.vhdx'})}
        if($mode -ne 'partial-before-vm'){$plan.steps+=@{provider='hyperv';resourceType='vm';resourceId='synthetic-vm'}}
        if($mode -eq 'foreign-operation'){$owned.metadata.workflowOperationId='other'}
        if($mode -eq 'foreign-plan'){$plan.steps[0].provider='docker'}
        $blocked=$false;try{Remove-LabSsisOperationRun -OperationId $operation -StateRoot $repoRoot -ExpectedVmId $vm.ToString()}catch{$blocked=$true}
        $values[$mode]=@{Blocked=$blocked;Removed=($events.Count -eq 1)}
    }
    $values
}
foreach($case in @('foreign-operation','foreign-plan','foreign-path','vm-drift')){Check "Echter Cleanup $case vor Remove blockiert" ($cleanupCases[$case].Blocked -and -not $cleanupCases[$case].Removed)}
foreach($case in @('remove-fault','vm-remains','disk-remains')){Check "Echter Cleanup $case meldet Recovery" ($cleanupCases[$case].Blocked -and $cleanupCases[$case].Removed)}
Check 'Partial Arrange vor VM wird nur operationseigen bereinigt' ($cleanupCases['partial-before-vm'].Removed -and -not $cleanupCases['partial-before-vm'].Blocked)
Check 'Kein Run führt zu keiner Löschung' (-not $cleanupCases['no-run'].Removed -and -not $cleanupCases['no-run'].Blocked)
Check 'Eigener vollständiger Cleanup bestätigt Postconditions' ($cleanupCases.valid.Removed -and -not $cleanupCases.valid.Blocked)
$guest=Get-LabSsisInstallGuestProbe
$readerAst=$guest.Ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-SsisInstalledSql'},$true)
. ([scriptblock]::Create($readerAst.Extent.Text))
foreach($case in @('valid','legacy-developer-label','wrong-major','standard-developer','enterprise-paid','not-sysadmin','existing-catalog','existing-catalog-allowed','duplicate','query-fault')){
    $table=[Data.DataTable]::new()
    foreach($column in @('Major','Edition','Sysadmin','Catalogs')){$null=$table.Columns.Add($column,$(if($column -eq 'Edition'){[string]}else{[int]}))}
    $edition=switch($case){'legacy-developer-label'{'Developer Edition (64-bit)'};'standard-developer'{'Standard Developer Edition (64-bit)'};'enterprise-paid'{'Enterprise Edition (64-bit)'};default{'Enterprise Developer Edition (64-bit)'}}
    $null=$table.Rows.Add(@($(if($case -eq 'wrong-major'){16}else{17}),$edition,$(if($case -like 'not-sysadmin*'){0}else{1}),$(if($case -like 'existing-catalog*'){1}else{0})))
    if($case -eq 'duplicate'){$null=$table.Rows.Add($table.Rows[0].ItemArray)}
    $command=[pscustomobject]@{CommandText='';CommandTimeout=0;Table=$table;Case=$case;Disposed=$false}
    $command|Add-Member ScriptMethod ExecuteReader {if($this.Case -eq 'query-fault'){throw 'SYNTHETIC_QUERY_FAILURE'};return ,$this.Table.CreateDataReader()}
    $command|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    $connection=[pscustomobject]@{Command=$command};$connection|Add-Member ScriptMethod CreateCommand {return $this.Command}
    $blocked=$false;try{Read-SsisInstalledSql -Connection $connection -AllowExistingCatalog ($case -ceq 'existing-catalog-allowed')}catch{$blocked=$true}
    Check "Tatsächlicher SQL-Gastleser $case, begrenzt und entsorgt" ($blocked -eq ($case -notin @('valid','legacy-developer-label','existing-catalog-allowed')) -and $command.Disposed -and $command.CommandTimeout -eq 30)
    $table.Dispose()
}
$registration=Get-LabSsisFeatureRegistrationProbe
$registrationValues=$registration.Ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-SsisRegistrationValues'},$true)
. ([scriptblock]::Create($registrationValues.Extent.Text))
foreach($case in @('Enterprise Developer Edition','Developer Edition','Standard Edition','Enterprise Evaluation Edition','','unknown')){
    Check "Registrierungswerte statt Dateipräsenz: $case" ((Test-SsisRegistrationValues -Edition $case -EditionType $case) -eq ($case -notin @('','unknown')))
}
Check 'Ein fehlender Editionswert reicht nicht zur Installationserkennung' (-not (Test-SsisRegistrationValues -Edition 'Enterprise Developer Edition' -EditionType ''))
$componentAst=([scriptblock]::Create($installerSource)).Ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-LabSsisExistingComponent'},$true)
Check 'Komponentenpfad verwendet keinen harten VM-Reset und verlangt eine neue Bootzeit' ($componentAst.Extent.Text -notmatch 'Restart-VM' -and $componentAst.Extent.Text -match '\[datetimeoffset\]::Parse\(\[string\]\$boot\[0\]\.BootTime\) -gt \$bootBefore')
$mutatingDispatches=@($componentAst.Body.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-HyperVPowerShellDirect' -and $node.Extent.Text -match '-ScriptBlock \(Get-LabSsisComponentGuest(?:Install|Restart)\)'},$true))
Check 'Eine verlorene Setup-/Neustartantwort wiederholt keine Mutation' ($mutatingDispatches.Count -eq 2 -and @($mutatingDispatches|Where-Object {@($_.CommandElements|Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -ceq 'NoRetry'}).Count -ne 1}).Count -eq 0)
$restart=Get-LabSsisComponentGuestRestart
Check 'Gastneustart verlangt beendetes Setup und einen exklusiven Rebootmarker' ($restart.ToString() -match 'ConsumerEnded' -and $restart.ToString() -match 'FileMode\]::CreateNew' -and $restart.ToString() -match 'shutdown.exe' -and $restart.ToString() -notmatch 'Restart-VM')
$guestInstall=Get-LabSsisComponentGuestInstall
Check 'IS-Task besitzt SYSTEM, keinen Trigger und geschützte ProgramFiles-Pfade' ($guestInstall.ToString() -match "-UserId 'S-1-5-18' -LogonType ServiceAccount" -and $guestInstall.ToString() -notmatch 'New-ScheduledTaskTrigger' -and $guestInstall.ToString() -match '\$env:ProgramFiles' -and $guestInstall.ToString() -match 'OPERATION_EXISTS_NO_REPLAY')

$cleanupTask=Remove-LabSsisComponentGuestOperation
$taskCases=& {
    $originalProgramFiles=$env:ProgramFiles
    try {
        $env:ProgramFiles=Join-Path ([IO.Path]::GetTempPath()) 'synthetic-program-files'
        $id='ssis-component-'+('b'*32);$root=Join-Path $env:ProgramFiles 'SqlServerLab\SsisOperations'
        $workerPath=Join-Path $root ($id+'.ps1');$configPath=Join-Path $root ($id+'.json')
        $expected='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$workerPath+'" -ConfigPath "'+$configPath+'"'
        $values=@{}
        function Get-ScheduledTask {param($TaskPath) if($case -eq 'scheduler-fault'){throw 'SYNTHETIC_SCHEDULER_FAILED'};if($case -notlike 'missing-task*'){$task}}
        function Get-Content {param($LiteralPath,[switch]$Raw) $record|ConvertTo-Json}
        function Test-Path {param($LiteralPath) $LiteralPath -cne 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress'}
        function Get-Process {}
        function Remove-Item {param($LiteralPath,[switch]$Force) $events.Add('file')}
        function Unregister-ScheduledTask {param($TaskName,$TaskPath) $events.Add('task')}
        foreach($case in @('valid','running','consumer-unknown','changed-operation','changed-action','changed-principal','delete-fault','missing-task-terminal','missing-task-unknown','scheduler-fault','nonterminal-state')){
            $events=[Collections.Generic.List[string]]::new()
            $task=[pscustomobject]@{TaskName=$id;State='Ready';TaskPath='\';Description=$id;Principal=@{UserId='S-1-5-18'};Actions=@(@{Execute=(Join-Path $PSHOME 'powershell.exe');Arguments=$expected})}
            $record=@{OperationId=$id;State='SUCCEEDED';ConsumerEnded=$true}
            switch($case){running{$task.State='Running'};'consumer-unknown'{$record.ConsumerEnded=$false};'missing-task-unknown'{$record.ConsumerEnded=$false};'nonterminal-state'{$record.State='RUNNING'};'changed-operation'{$record.OperationId='different'};'changed-action'{$task.Actions[0].Arguments='different'};'changed-principal'{$task.Principal.UserId='S-1-5-19'}}
            function Remove-Item {param($LiteralPath,[switch]$Force) if($case -eq 'delete-fault'){throw 'SYNTHETIC_DELETE_FAILED'};$events.Add('file')}
            $blocked=$false;try{& $cleanupTask $id|Out-Null}catch{$blocked=$true}
            $values[$case]=[pscustomobject]@{Blocked=$blocked;Events=@($events)}
        }
        $values
    }finally{$env:ProgramFiles=$originalProgramFiles}
}
Check 'Tatsächlicher Taskcleanup entfernt nur gebundene beendete Aufgabe und fünf eigene Dateien' (-not $taskCases.valid.Blocked -and $taskCases.valid.Events.Count -eq 6 -and $taskCases.valid.Events[0] -eq 'task')
foreach($case in @('running','consumer-unknown','changed-operation','changed-action','changed-principal','missing-task-unknown','scheduler-fault','nonterminal-state')){
    Check "Tatsächlicher Taskcleanup schützt unklaren oder veränderten Zustand: $case" ($taskCases[$case].Blocked -and $taskCases[$case].Events.Count -eq 0)
}
Check 'Dateilöschfehler wird als fehlgeschlagener Cleanup sichtbar' $taskCases['delete-fault'].Blocked
Check 'Fehlender Task erlaubt Dateicleanup nur bei unabhängig gebundenem Consumerende' (-not $taskCases['missing-task-terminal'].Blocked -and $taskCases['missing-task-terminal'].Events.Count -eq 5 -and $taskCases['missing-task-terminal'].Events -notcontains 'task')
$componentTry=@($componentAst.Body.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[0]
$componentFinally=[scriptblock]::Create(($componentTry.Finally.Statements.Extent.Text -join "`n"))
$finallyCases=& {
    $values=@{}
    function Invoke-HyperVPowerShellDirect {if($case -in @('cleanup-fault','primary-fault')){throw 'SYNTHETIC_TASK_CLEANUP_FAILED'}}
    function Get-HyperVManagedVM {[pscustomobject]@{VM=@{Id=$context.Instance.vmId}}}
    function Get-VMDvdDrive { [pscustomobject]@{ControllerNumber=0;ControllerLocation=1;Path='synthetic.iso'} }
    function Remove-VMDvdDrive {$events.Add('dvd');if($case -in @('cleanup-fault','primary-fault')){throw 'SYNTHETIC_DVD_CLEANUP_FAILED'}}
    function Stop-LabBlockingActionProgress {$events.Add('progress')}
    foreach($case in @('valid','cleanup-fault','primary-fault','unknown-consumer')){
        $events=[Collections.Generic.List[string]]::new()
        $operationId='ssis-component-'+('c'*32);$RunId=[guid]'11111111-1111-1111-1111-111111111111'
        $context=[pscustomobject]@{Instance=@{vmName='synthetic';vmId=$RunId.ToString()};Run=@{scopeId=$RunId.ToString()}}
        $guest=[Security.SecureString]::new();$guest.AppendChar('x');$guestOperationStarted=$true
        $setupConsumerEnded=$case -ne 'unknown-consumer';$addedDvd=@{ControllerNumber=0;ControllerLocation=1}
        $progress=@{};$progress['owned']=$true
        $handle=[pscustomobject]@{Events=$events};$handle|Add-Member ScriptMethod Dispose {$this.Events.Add('media-handle')}
        $media=@{Handle=$handle;Media=@{IsoPath='synthetic.iso'}}
        $primaryFailure=if($case -in @('primary-fault','unknown-consumer')){[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('SYNTHETIC_PRIMARY'),'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null)}else{$null}
        $caught=$null;try{. $componentFinally}catch{$caught=$_}
        $disposed=$false;try{$copy=$guest.Copy();$copy.Dispose()}catch{$disposed=$true}
        $values[$case]=[pscustomobject]@{Caught=$caught;Primary=$primaryFailure;Events=@($events);SecretDisposed=$disposed}
    }
    $values
}
foreach($case in $finallyCases.Keys){Check "Task-/DVD-Cleanupfehler überspringt weder Fortschritts- noch Secret-/Medienfreigabe: $case" ($finallyCases[$case].SecretDisposed -and $finallyCases[$case].Events -contains 'progress' -and $finallyCases[$case].Events -contains 'media-handle')}
Check 'Getrennter Cleanupfehler nennt Recovery und bewahrt beide Ursachen' ($finallyCases['cleanup-fault'].Caught.Exception.Data['RecoveryRequired'] -and $finallyCases['cleanup-fault'].Caught.Exception.Data['CleanupFailure'] -eq 'SSIS_COMPONENT_OPERATION_CLEANUP_FAILED;SSIS_COMPONENT_MEDIA_DETACH_FAILED')
Check 'Primärfehler bleibt bei mehreren Cleanupfehlern erhalten' (-not $finallyCases['primary-fault'].Caught -and $finallyCases['primary-fault'].Primary.Exception.Message -eq 'SYNTHETIC_PRIMARY' -and $finallyCases['primary-fault'].Primary.Exception.Data['RecoveryRequired'])
Check 'Unbekanntes Installerende behält DVD und kennzeichnet Recovery' ($finallyCases['unknown-consumer'].Events -notcontains 'dvd' -and $finallyCases['unknown-consumer'].Primary.Exception.Data['RecoveryRequired'])
$sqlStartGuard=$guest.Ast.Find({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq '$StartSqlIfStopped'},$true)
$sqlStartCases=& {
    $values=@{}
    function Get-Service {param($Name) if($Name -cne 'MSSQLSERVER'){throw 'UNEXPECTED_SERVICE'};$controller}
    function Start-Service {param($Name) if($Name -cne 'MSSQLSERVER'){throw 'UNEXPECTED_SERVICE'};$events.Add('start');if($case -ceq 'start-fault'){throw 'SYNTHETIC_START_FAILED'}}
    foreach($case in @('disabled-option','stopped','running','start-pending','start-fault')){
        $events=[Collections.Generic.List[string]]::new();$StartSqlIfStopped=$case -cne 'disabled-option'
        $controller=[pscustomobject]@{Status=$(switch($case){running{'Running'};'start-pending'{'StartPending'};default{'Stopped'}});Events=$events}
        $controller|Add-Member ScriptMethod Dispose {$this.Events.Add('dispose')}
        $caught=$false;try{& ([scriptblock]::Create($sqlStartGuard.Extent.Text))}catch{$caught=$true}
        $values[$case]=[pscustomobject]@{Events=@($events);Failed=$caught}
    }
    $values
}
Check 'SQL-Startoption ist standardmäßig wirkungslos' ($sqlStartCases['disabled-option'].Events.Count -eq 0)
Check 'Gestoppter SQL-Dienst wird genau einmal gestartet und Controller freigegeben' (($sqlStartCases.stopped.Events -join ',') -ceq 'start,dispose')
foreach($case in @('running','start-pending')){Check "Laufender/bereits startender SQL-Dienst wird nicht erneut gestartet: $case" (($sqlStartCases[$case].Events -join ',') -ceq 'dispose')}
Check 'SQL-Startfehler wird nicht wiederholt und gibt Controller frei' ($sqlStartCases['start-fault'].Failed -and ($sqlStartCases['start-fault'].Events -join ',') -ceq 'start,dispose')
Write-Host "SSIS OWNED INSTALL CHECKS: $passed PASS, $failed FAIL; native NOT_EXECUTED"
if($failed){exit 1}
