#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module = Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hyperv-collation-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
$passed = 0
function Check([bool]$Value, [string]$Name) {
    if (-not $Value) { throw "HYPERV_COLLATION_CHECK_FAILED: $Name" }
    $script:passed++; Write-Host "PASS: $Name"
}
if (-not ('LabHyperVCollationFakeConnection' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Data;
public sealed class LabHyperVCollationFakeParameter { public object Value {get;set;} }
public sealed class LabHyperVCollationFakeParameters {
  public Dictionary<string,LabHyperVCollationFakeParameter> Values = new Dictionary<string,LabHyperVCollationFakeParameter>();
  public LabHyperVCollationFakeParameter Add(string n, SqlDbType t, int s) { var p=new LabHyperVCollationFakeParameter();Values.Add(n,p);return p; }
  public LabHyperVCollationFakeParameter this[string n] { get {return Values[n];} }
}
public sealed class LabHyperVCollationFakeReader {
  public static Dictionary<string,object> Row;
  public static bool Empty, Disposed;
  public bool Read() {return !Empty;}
  public object this[string n] {get {return Row[n];}}
  public void Dispose() {Disposed=true;}
}
public sealed class LabHyperVCollationFakeCommand {
  public static string Text; public static string Parameter;
  public static bool Disposed;
  public int CommandTimeout {get;set;}
  public string CommandText {get {return Text;} set {Text=value;}}
  public LabHyperVCollationFakeParameters Parameters = new LabHyperVCollationFakeParameters();
  public LabHyperVCollationFakeReader ExecuteReader() {Parameter=(string)Parameters["@collation"].Value;return new LabHyperVCollationFakeReader();}
  public void Dispose() {Disposed=true;}
}
public sealed class LabHyperVCollationFakeConnection {
  public static int Opens; public static bool Fail, Disposed;
  public void Open() {Opens++;if(Fail)throw new Exception("PRIVATE_CONNECTION_CANARY");}
  public LabHyperVCollationFakeCommand CreateCommand() {return new LabHyperVCollationFakeCommand();}
  public void Dispose() {Disposed=true;}
}
'@
}
try {
    $normalization = & $module {
        $manifest = [pscustomobject]@{name='synthetic-collation';instances=@([pscustomobject]@{
            id='primary';version='2025';provider='hyperv';os='windows';databases=@([pscustomobject]@{name='SyntheticDb'})
        })}
        $absent = Resolve-ManifestDefaults -Manifest $manifest
        $manifest.instances[0] | Add-Member -NotePropertyName collation -NotePropertyValue 'sql_latin1_general_cp1_cs_as'
        $selected = Resolve-ManifestDefaults -Manifest $manifest
        $manifest.instances[0].databases[0] | Add-Member -NotePropertyName collation -NotePropertyValue 'Latin1_General_100_BIN2'
        $override = Resolve-ManifestDefaults -Manifest $manifest
        [pscustomobject]@{Absent=$absent.instances[0];Selected=$selected.instances[0];Override=$override.instances[0]}
    }
    Check (-not $normalization.Absent.collationExplicit -and $normalization.Absent.collation -ceq 'SQL_Latin1_General_CP1_CI_AS') 'Omitted manifest selection preserves the legacy default without creating an intent'
    Check ($normalization.Selected.collationExplicit -and $normalization.Selected.collation -ceq 'SQL_Latin1_General_CP1_CS_AS' -and $normalization.Selected.databases[0].collation -ceq 'SQL_Latin1_General_CP1_CS_AS') 'Explicit manifest selection is canonical and inherited by new databases'
    Check ($normalization.Override.databases[0].collation -ceq 'Latin1_General_100_BIN2') 'Explicit database override is unchanged'

    $defaults = & $module {
        param($Fixture)
        Copy-Item -LiteralPath (Join-Path $script:CatalogsPath 'sql-server-collations.json') -Destination $Fixture
        $original = $script:CatalogsPath
        try {
            $script:CatalogsPath=$Fixture
            [IO.File]::WriteAllText((Join-Path $Fixture 'sql-intent-defaults.json'),'{"schemaVersion":1,"collation":"latin1_general_100_bin2"}')
            $edited=Get-LabSqlIntentDefaultCollation -SqlVersion 2025
            [IO.File]::WriteAllText((Join-Path $Fixture 'sql-intent-defaults.json'),'{"schemaVersion":1,"collation":"Unknown_Name"}')
            $rejected=$false;try {Get-LabSqlIntentDefaultCollation -SqlVersion 2025} catch {$rejected=$_.Exception.Message -like 'SQL_COLLATION_NOT_CATALOGED*'}
            [IO.File]::WriteAllText((Join-Path $Fixture 'sql-intent-defaults.json'),'{"schemaVersion":1,"collation":"","extra":true}')
            $invalid=$false;try {Get-LabSqlIntentDefaultCollation -SqlVersion 2025} catch {$invalid=$_.Exception.Message -ceq 'SQL_INTENT_DEFAULTS_INVALID'}
            [pscustomobject]@{Edited=$edited;Rejected=$rejected;Invalid=$invalid}
        } finally {$script:CatalogsPath=$original}
    } $fixture
    Check ($defaults.Edited -ceq 'Latin1_General_100_BIN2' -and $defaults.Rejected -and $defaults.Invalid) 'Framework default is editable, version-bound and rejects malformed or unknown values'

    $checks = & $module {
        param($Repo,$Fixture)
        $checks=[ordered]@{}
        $script:auditStateRoot=Join-Path $Fixture 'state'
        $script:auditMediaRoot=Join-Path $Fixture 'media'
        $script:auditMediaIso=Join-Path $Fixture 'media.iso'
        $script:auditArtifactVersion='2025';$script:auditArtifactState='SQL_PREPARED_SEALED'
        $script:auditArtifactReads=0;$script:auditQueryCalls=0;$script:auditBinding=@();$script:auditConnectionString=''
        function Get-HyperVImageArtifact {
            param($ArtifactId,$StateRoot)
            $script:auditArtifactReads++
            [pscustomobject]@{artifactState=$script:auditArtifactState;sql=[pscustomobject]@{version=$script:auditArtifactVersion;edition='EnterpriseDeveloper'}}
        }
        $script:auditLab=[pscustomobject]@{
            StateRoot=$script:auditStateRoot;RunDirectory=(Join-Path $script:auditStateRoot 'runs/own')
            Run=[pscustomobject]@{runId='own-run';scopeId='own-scope';metadata=[pscustomobject]@{}}
            Instance=[pscustomobject]@{id='primary';vmName='synthetic-vm';imageArtifactId='synthetic-image';workload='sql'}
        }
        $none=Resolve-LabHyperVSqlCollationSelection -Lab $script:auditLab -Parameters @{}
        $checks['No selection performs no artifact lookup and returns no collation']=$null -eq $none -and $script:auditArtifactReads -eq 0
        foreach($name in @('SQL_Latin1_General_CP1_CS_AS','SQL_Latin1_General_CP1_CI_AS','Latin1_General_100_CS_AS','Latin1_General_100_CI_AS_SC_UTF8','Latin1_General_100_BIN2','Japanese_Bushu_Kakusu_140_BIN2')) {
            $canonical=Resolve-LabHyperVSqlCollationSelection -Lab $script:auditLab -Parameters @{Collation=$name.ToLowerInvariant()}
            $checks["Prepared selection supports $name"]=$canonical -ceq $name
        }
        foreach($bad in @('Unknown_Name','Latin1*','SQL_Latin1_General_CP1_CS_AS;DROP','',' ')) {
            $denied=$false;try {$null=Resolve-LabHyperVSqlCollationSelection -Lab $script:auditLab -Parameters @{Collation=$bad}} catch {$denied=$_.Exception.Message -match '^(SQL_COLLATION_|HYPERV_SQL_COLLATION_INTENT_INVALID)'}
            $checks["Invalid selection rejects before guest work: $bad"]=$denied -and $script:auditQueryCalls -eq 0
        }
        $script:auditArtifactVersion='2017';$denied=$false
        try {$null=Resolve-LabHyperVSqlCollationSelection -Lab $script:auditLab -Parameters @{Collation='SQL_Latin1_General_CP1_CS_AS'}} catch {$denied=$_.Exception.Message -ceq 'SQL_COLLATION_VERSION_NOT_CATALOGED'}
        $checks['Selected artifact version governs admission']=$denied;$script:auditArtifactVersion='2025'
        $script:auditArtifactState='OS_SEALED';$denied=$false
        try {$null=Resolve-LabHyperVSqlCollationSelection -Lab $script:auditLab -Parameters @{Collation='SQL_Latin1_General_CP1_CS_AS'}} catch {$denied=$_.Exception.Message -ceq 'HYPERV_SQL_COLLATION_PREPARED_REQUIRED'}
        $checks['OS-only artifacts do not silently consume SQL selection']=$denied;$script:auditArtifactState='SQL_PREPARED_SEALED'
        $script:auditLab.Instance | Add-Member -NotePropertyName sqlCollationIntent -NotePropertyValue 'SQL_Latin1_General_CP1_CS_AS'
        $checks['Stored selection survives omitted caller parameter']=(Resolve-LabHyperVSqlCollationSelection -Lab $script:auditLab -Parameters @{}) -ceq 'SQL_Latin1_General_CP1_CS_AS'
        $denied=$false;try {$null=Resolve-LabHyperVSqlCollationSelection -Lab $script:auditLab -Parameters @{Collation='Latin1_General_100_BIN2'}} catch {$denied=$_.Exception.Message -ceq 'HYPERV_SQL_COLLATION_INTENT_CONFLICT'}
        $checks['Conflicting run selection cannot overwrite stored intent']=$denied
        $script:auditLab.Instance.PSObject.Properties.Remove('sqlCollationIntent')
        # Execute the actual caller preflight and its actual provision command.
        # Native preparation is outside this bounded caller-binding check.
        function Invoke-HyperVLabUnattendedProvision {
            param($Collation)
            $script:auditCallerCalls++
            $script:auditCallerBound=$PSBoundParameters.ContainsKey('Collation')
            $script:auditCallerValue=$Collation
        }
        foreach($caller in @('public','console')) {
            $source=if($caller -eq 'public'){'Public/New-SqlServerLab.ps1'}else{'Public/Invoke-SqlServerLab.ps1'}
            $functionName=if($caller -eq 'public'){'New-SqlServerLab'}else{'New-LabHyperVEnvironmentInteractive'}
            $variable=if($caller -eq 'public'){'$hyperVCollationArguments'}else{'$sqlCollationArguments'}
            $parsed=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo $source),[ref]$null,[ref]$null)
            $fn=$parsed.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $functionName},$false)
            $assignment=$fn.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $variable},$true)
            $condition=$fn.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq $(if($caller -eq 'public'){'$instance.collationExplicit'}else{'$isSqlPrepared -and $Intent'})},$true)
            $call=$fn.Find({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Invoke-HyperVLabUnattendedProvision'},$true)
            if(-not $assignment -or -not $condition -or -not $call){throw 'CALLER_COLLATION_BOUNDARY_MISSING'}
            $producer=[scriptblock]::Create($assignment.Extent.Text+"`n"+$condition.Extent.Text)
            $dispatch=[scriptblock]::Create($call.Extent.Text)
            foreach($case in @('absent','selected','unknown')) {
                $script:auditCallerCalls=0;$script:auditCallerBound=$false;$script:auditCallerValue=$null
                $artifactState='SQL_PREPARED_SEALED';$isSqlPrepared=$true
                $artifact=[pscustomobject]@{sql=[pscustomobject]@{version='2025'}}
                $selectedName=if($case -eq 'unknown'){'Unknown_Name'}else{'sql_latin1_general_cp1_cs_as'}
                $instance=[pscustomobject]@{collationExplicit=($case -ne 'absent');collation=$selectedName}
                $Intent=if($case -ne 'absent'){[pscustomobject]@{Collation=$selectedName}}else{$null}
                $code='';try {. $producer;. $dispatch} catch {$code=$_.Exception.Message}
                $checks["Actual $caller caller conditionally binds selection: $case"]=switch($case){
                    absent {$code -eq '' -and $script:auditCallerCalls -eq 1 -and -not $script:auditCallerBound}
                    selected {$code -eq '' -and $script:auditCallerCalls -eq 1 -and $script:auditCallerBound -and $script:auditCallerValue -ceq 'SQL_Latin1_General_CP1_CS_AS'}
                    unknown {$code -like 'SQL_COLLATION_NOT_CATALOGED*' -and $script:auditCallerCalls -eq 0}
                }
            }
        }
        # The actual interactive reader freezes the displayed default at confirmation.
        $script:auditDefaultReader=${function:Get-LabSqlIntentDefaultCollation}
        function Get-LabSqlIntentDefaultCollation {
            param($SqlVersion)
            $script:auditDefaultReads++
            if($script:auditDefaultReads -gt 1){throw 'DEFAULT_REREAD_AFTER_CONFIRMATION'}
            & $script:auditDefaultReader -SqlVersion $SqlVersion
        }
        function Invoke-LabConsoleMenu {
            param($ScreenId,$Items,$SelectedId)
            [pscustomobject]@{Status='Selected';SelectedItem=[pscustomobject]@{Id=$(if($ScreenId -eq 'sql-intent-mode'){if($script:auditFormCase -eq 'quick'){'quick'}else{'custom'}}else{'2025'})}}
        }
        function Select-LabSqlPatchIntent {[pscustomobject]@{VersionId='2025'}}
        function Get-LabHostPhysicalMemoryMB {0}
        function Invoke-LabConsoleForm {
            param($Fields)
            $values=@{};foreach($field in $Fields){$values[$field.Id]=$field.Value}
            $script:auditDisplayedCollation=$values['collation']
            if($script:auditFormCase -eq 'override'){$values['collation']='Latin1_General_100_BIN2'}
            [pscustomobject]@{Status='Confirmed';Values=$values}
        }
        foreach($case in @('quick','custom','override')) {
            $script:auditFormCase=$case;$script:auditDefaultReads=0
            $intent=Read-LabSqlEnvironmentIntentInteractive
            $checks["Actual $case SQL intent uses displayed default or explicit override"]=$script:auditDefaultReads -eq 1 -and $script:auditDisplayedCollation -ceq 'SQL_Latin1_General_CP1_CS_AS' -and $intent.Collation -ceq $(if($case -eq 'override'){'Latin1_General_100_BIN2'}else{'SQL_Latin1_General_CP1_CS_AS'})
        }
        function Assert-HyperVLabSqlVmBinding {param($Lab,$ExpectedVmId)$script:auditBinding+=@($ExpectedVmId);[pscustomobject]@{}}
        function New-Object {
            param($TypeName,$ArgumentList)
            if($TypeName -cne 'System.Data.SqlClient.SqlConnection'){throw 'UNEXPECTED_OBJECT'}
            $script:auditConnectionString=[string]$ArgumentList[0]
            [LabHyperVCollationFakeConnection]::new()
        }
        function Invoke-HyperVPowerShellDirect {
            param($VMName,$StateRoot,$ExpectedRunId,$ExpectedScopeId,$Credential,[switch]$NoRetry,$ExpectedVmId,$ScriptBlock,$ArgumentList,$FallbackAddress)
            $script:auditFallbackAddress=$FallbackAddress
            if ($ScriptBlock.ToString().Contains('HYPERV_LAB_SQL_COMPLETE_TIMEOUT')) {
                $script:auditEvents.Add('setup')
                return & $ScriptBlock @ArgumentList
            }
            $script:auditQueryCalls++
            if ($script:auditEvents) { $script:auditEvents.Add('collation') }
            if($VMName -cne 'synthetic-vm' -or $StateRoot -cne $script:auditStateRoot -or $ExpectedRunId -cne 'own-run' -or $ExpectedScopeId -cne 'own-scope' -or -not $NoRetry){throw 'BINDING_CHANGED'}
            $value=& $ScriptBlock @ArgumentList
            if($script:auditBadScope){$value.ScopeId='foreign'}
            $value
        }
        $credential=[pscredential]::new('synthetic-user',[securestring]::new())
        $vmId=[guid]'9633427c-2101-4dba-ab46-4af532c290a7'
        function Reset-SqlRow([string]$Name) {
            [LabHyperVCollationFakeReader]::Row=[Collections.Generic.Dictionary[string,object]]::new()
            foreach($field in @('ServerCollation','MasterCollation','TempdbCollation')){[LabHyperVCollationFakeReader]::Row[$field]=$Name}
            [LabHyperVCollationFakeReader]::Row['CatalogAvailable']=$true
            [LabHyperVCollationFakeReader]::Row['MajorVersion']=17
            [LabHyperVCollationFakeReader]::Row['InstanceName']='MSSQLSERVER'
            [LabHyperVCollationFakeReader]::Empty=$false;[LabHyperVCollationFakeConnection]::Fail=$false
            [LabHyperVCollationFakeReader]::Disposed=$false;[LabHyperVCollationFakeCommand]::Disposed=$false;[LabHyperVCollationFakeConnection]::Disposed=$false
            $script:auditBadScope=$false
        }
        foreach($name in @('SQL_Latin1_General_CP1_CS_AS','Latin1_General_100_BIN2')) {
            Reset-SqlRow $name
            $value=Test-LabHyperVSqlCollationRuntimeEvidence -Lab $script:auditLab -Credential $credential -Collation $name -SqlVersion 2025 -SqlPort 15433 -ExpectedVmId $vmId
            $checks["Actual guest query and sanitized result for $name"]=$value.Status -ceq 'VERIFIED' -and $value.ActualCollation -ceq $name -and $value.MasterCollation -ceq $name -and $value.TempdbCollation -ceq $name -and $value.RunId -ceq 'own-run' -and ($value|ConvertTo-Json) -notmatch 'synthetic-vm|synthetic-user|password|connectionString'
        }
        $checks['Actual SQL uses one parameter and reads all required properties']=[LabHyperVCollationFakeCommand]::Parameter -ceq 'Latin1_General_100_BIN2' -and [LabHyperVCollationFakeCommand]::Text -match 'sys.fn_helpcollations\(\)' -and [LabHyperVCollationFakeCommand]::Text -match "DATABASEPROPERTYEX\(N'master'" -and [LabHyperVCollationFakeCommand]::Text -match "DATABASEPROPERTYEX\(N'tempdb'" -and [LabHyperVCollationFakeCommand]::Text -match "SERVERPROPERTY\(N'Collation'" -and [LabHyperVCollationFakeCommand]::Text -notmatch 'ALTER|CREATE|DROP'
        $checks['Connection stays inside guest with selected port and Windows authentication']=$script:auditConnectionString -match 'Server=localhost,15433;' -and $script:auditConnectionString -match 'Integrated Security=True' -and $script:auditConnectionString -notmatch '(?i)password|user id'
        $checks['Optional VM binding reaches both evidence guards']=$script:auditBinding.Count -eq 4 -and @($script:auditBinding|Where-Object{$_ -ne $vmId}).Count -eq 0
        $null=Test-LabHyperVSqlCollationRuntimeEvidence -Lab $script:auditLab -Credential $credential -Collation 'Latin1_General_100_BIN2' -SqlVersion 2025 -FallbackAddress '192.0.2.2'
        $checks['Existing lab transport choice receives its bound fallback address']=$script:auditFallbackAddress -ceq '192.0.2.2'
        foreach($case in @('ServerCollation','MasterCollation','TempdbCollation','null','catalog','empty','exception','identity','scope')) {
            Reset-SqlRow 'SQL_Latin1_General_CP1_CS_AS'
            $expectedCode='HYPERV_SQL_COLLATION_POSTCONDITION_FAILED'
            switch($case) {
                null {[LabHyperVCollationFakeReader]::Row['TempdbCollation']=[DBNull]::Value}
                catalog {[LabHyperVCollationFakeReader]::Row['CatalogAvailable']=$false;$expectedCode='HYPERV_SQL_COLLATION_CATALOG_UNAVAILABLE'}
                empty {[LabHyperVCollationFakeReader]::Empty=$true;$expectedCode='HYPERV_SQL_COLLATION_QUERY_FAILED'}
                exception {[LabHyperVCollationFakeConnection]::Fail=$true;$expectedCode='HYPERV_SQL_COLLATION_QUERY_FAILED'}
                identity {[LabHyperVCollationFakeReader]::Row['MajorVersion']=16;$expectedCode='HYPERV_SQL_COLLATION_RECEIPT_INVALID'}
                scope {$script:auditBadScope=$true;$expectedCode='HYPERV_SQL_COLLATION_RECEIPT_INVALID'}
                default {[LabHyperVCollationFakeReader]::Row[$case]='SQL_Latin1_General_CP1_CI_AS'}
            }
            $code='';try {$null=Test-LabHyperVSqlCollationRuntimeEvidence -Lab $script:auditLab -Credential $credential -Collation 'SQL_Latin1_General_CP1_CS_AS' -SqlVersion 2025} catch {$code=$_.Exception.Message}
            $checks["Missing or wrong evidence fails closed: $case"]=$code -ceq $expectedCode -and [LabHyperVCollationFakeConnection]::Disposed
            if($case -ne 'exception'){$checks["Reader and command disposed after $case"]=[LabHyperVCollationFakeReader]::Disposed -and [LabHyperVCollationFakeCommand]::Disposed}
        }

        # Execute the actual CompleteImage guest block with synthetic process leaves.
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'Private/HyperVLabEnvironment.ps1'),[ref]$null,[ref]$null)
        $complete=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Complete-HyperVLabSqlImage'},$false)
        $remote=$complete.Find({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Invoke-HyperVPowerShellDirect'},$true)
        $guest=$remote.Find({param($n)$n -is [Management.Automation.Language.ScriptBlockExpressionAst]},$true).ScriptBlock.GetScriptBlock()
        function Get-PSDrive {[pscustomobject]@{Root=$script:auditMediaRoot}}
        function Test-Path {$true}
        function Get-Item {[pscustomobject]@{FullName=(Join-Path $script:auditMediaRoot 'setup.exe')}}
        function Start-Process {param($FilePath,$ArgumentList,[switch]$PassThru,[switch]$NoNewWindow)
            $script:auditSetupArguments=@($ArgumentList)
            $process=[pscustomobject]@{ExitCode=0};$process|Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {param($Timeout)$true};$process
        }
        function Get-CimInstance {[pscustomobject]@{LastBootUpTime=[datetime]'2026-01-01T00:00:00Z'}}
        function Get-Service {[pscustomobject]@{Name='MSSQLSERVER';Status='Running'}}
        $password=[securestring]::new()
        foreach($character in 'Synthetic_42!'.ToCharArray()){$password.AppendChar($character)}
        $password.MakeReadOnly()
        foreach($name in @($null,'SQL_Latin1_General_CP1_CS_AS','SQL_Latin1_General_CP1_CI_AS','Latin1_General_100_CS_AS')) {
            $null=& $guest 'own-run' 'own-scope' $password $name
            $options=@($script:auditSetupArguments|Where-Object{$_ -like '/SQLCOLLATION=*'})
            $checks["Actual setup argument conditional selection: $name"]=if($name){$options.Count -eq 1 -and $options[0] -ceq "/SQLCOLLATION=$name"}else{$options.Count -eq 0}
        }
        # Actual orchestration, including failure state, without provider work.
        function Get-HyperVLabWorkflowRun {$script:auditLab}
        function Assert-LabWindowsPoolMutationAllowed {$script:auditPoolWrites++}
        function Write-LabInfo {}
        function Write-LabSuccess {}
        function Write-LabWarning {}
        function Get-HyperVSqlInstallationMediaCandidates {[pscustomobject]@{State='READY';SqlVersion='2025';MediaEdition='Enterprise';MediaId='synthetic-media'}}
        function Resolve-HyperVSqlInstallationMedia {[pscustomobject]@{HashStatus='SIDECAR_READY';IsoPath=$script:auditMediaIso}}
        function Get-HyperVManagedVM {[pscustomobject]@{VM=[pscustomobject]@{State='Running'}}}
        function Invoke-LabWindowsSlotActivationReconcile {}
        function Save-LabHyperVSqlSaPassword {}
        function Get-VMDvdDrive {[pscustomobject]@{Path=$script:auditMediaIso}}
        function Repair-HyperVLabSqlWmiProvider {[pscustomobject]@{}}
        function Get-HyperVLabSqlInstanceReceipt {[pscustomobject]@{}}
        function Save-HyperVLabSqlInstanceReceipt {[pscustomobject]@{IsDefault=$true;ServiceStatus='Running'}}
        function Set-LabHyperVSqlPortBinding {}
        function Write-LabArtifactJsonAtomic {param($Path,$InputObject)$script:auditPersisted=$InputObject|ConvertTo-Json -Depth 30|ConvertFrom-Json -Depth 30}
        function Wait-HyperVGuestSqlReady {
            $script:auditEvents.Add('ready')
            [pscustomobject]@{Ready=$true;Status='SQL_READY_RUN';OnlineSystemDatabases=4;Provider='hyperv';InstanceName='MSSQLSERVER';MajorVersion=17;ProductVersion='17.0.synthetic';Edition='synthetic';ObservedAt='synthetic-time'}
        }
        foreach($case in @('absent','selected','stored','mismatch','unknown')) {
            Reset-SqlRow 'SQL_Latin1_General_CP1_CS_AS'
            $script:auditLab.Instance=[pscustomobject]@{id='primary';vmName='synthetic-vm';imageArtifactId='synthetic-image';workload='sql'}
            $script:auditLab | Add-Member -NotePropertyName Connection -NotePropertyValue ([pscustomobject]@{instances=@($script:auditLab.Instance)}) -Force
            $script:auditEvents=[Collections.Generic.List[string]]::new();$script:auditPoolWrites=0;$script:auditQueryCalls=0
            $arguments=@{RunId='own-run';Credential=$credential;SqlSaPassword=$password;SqlPort=15433;MediaRoot=$script:auditMediaRoot;StateRoot=$script:auditStateRoot}
            if($case -in @('selected','mismatch')){$arguments.Collation='sql_latin1_general_cp1_cs_as'}
            if($case -eq 'stored'){$script:auditLab.Instance|Add-Member -NotePropertyName sqlCollationIntent -NotePropertyValue 'SQL_Latin1_General_CP1_CS_AS'}
            if($case -eq 'mismatch'){[LabHyperVCollationFakeReader]::Row['MasterCollation']='SQL_Latin1_General_CP1_CI_AS'}
            if($case -eq 'unknown'){$arguments.Collation='Unknown_Name'}
            $errorCode='';$result=$null
            try {$result=Complete-HyperVLabSqlImage @arguments} catch {$errorCode=$_.Exception.Message}
            switch($case) {
                absent {$checks['Actual completion without selection performs no collation query or intent write']=$errorCode -eq '' -and $result.state -ceq 'COMPLETE' -and $script:auditQueryCalls -eq 0 -and -not $script:auditLab.Instance.PSObject.Properties['sqlCollationIntent'] -and @($script:auditSetupArguments|Where-Object{$_ -like '/SQLCOLLATION=*'}).Count -eq 0}
                mismatch {$checks['Actual completion retains pending state without SQL-ready success on mismatch']=$errorCode -ceq 'HYPERV_SQL_COLLATION_POSTCONDITION_FAILED' -and $script:auditPersisted.instances[0].sqlCompletion.state -ceq 'COLLATION_PENDING' -and -not $script:auditPersisted.instances[0].PSObject.Properties['sqlReadiness'] -and -not $script:auditPersisted.instances[0].sqlCompletion.PSObject.Properties['collation']}
                unknown {$checks['Actual completion rejects unknown selection before mutation or dispatch']=$errorCode -like 'SQL_COLLATION_NOT_CATALOGED*' -and $script:auditPoolWrites -eq 0 -and $script:auditEvents.Count -eq 0}
                default {$checks["Actual completion verifies and persists $case selection after readiness"]=$errorCode -eq '' -and $result.state -ceq 'COMPLETE' -and $result.collation.Status -ceq 'VERIFIED' -and $script:auditPersisted.instances[0].sqlReadiness.status -ceq 'SQL_READY_RUN' -and ($script:auditEvents -join ',') -ceq 'setup,ready,collation'}
            }
            if($errorCode -and $case -notin @('mismatch','unknown')){throw "UNEXPECTED_COMPLETION_FAILURE: $case $errorCode"}
        }
        [pscustomobject]$checks
    } $repo $fixture
    foreach($check in $checks.PSObject.Properties){Check ([bool]$check.Value) $check.Name}
}
finally {
    Remove-Module $module.Name -Force -ErrorAction SilentlyContinue
    $path=[IO.Path]::GetFullPath($fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $path.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($path) -notmatch '^sql-lab-hyperv-collation-[a-f0-9]{32}$'){throw 'COLLATION_TEST_CLEANUP_SCOPE_INVALID'}
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}
}
Write-Host "$passed Checks bestanden; native NOT_EXECUTED."
