param([switch]$Standalone)

$smtpRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$smtpTemp = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-smtp-manifest-' + [guid]::NewGuid().ToString('N'))
$smtpModule = $null
$smtpRows = [System.Collections.Generic.List[object]]::new()
function Add-SmtpAdmissionCheck {
    param([string]$Id, [bool]$Success)
    $smtpRows.Add([pscustomobject]@{Id=$Id;Success=$Success})
}
try {
    $null = New-Item -ItemType Directory -Path $smtpTemp
    $smtpModule = New-Module -ArgumentList $smtpRoot -ScriptBlock {
        param($root)
        $script:SchemasPath = Join-Path $root 'Schemas'
        $script:VersionCatalog = Get-Content (Join-Path $root 'Catalogs/sql-server-versions.json') -Raw | ConvertFrom-Json -Depth 100
        foreach ($file in @('Private/SmtpTestServiceConfig.ps1','Private/SmtpTestServiceManifestAdmission.ps1',
            'Private/VersionCatalog.ps1','Private/ManifestParser.ps1','Private/ManifestBuilder.ps1',
            'Private/DesiredState.ps1','Public/New-SqlServerLabManifest.ps1','Public/New-SqlServerLab.ps1')) {
            . (Join-Path $root $file)
        }
        # Synthetic leaves only. Actual schema, catalog, admission and public adapters stay intact.
        $script:Effects = 0; $script:Defaults = 0
        function Resolve-LabSqlServerCollation { $script:Defaults++; 'SQL_Latin1_General_CP1_CI_AS' }
        function Resolve-LabNetworkIntentPlan { [pscustomobject]@{Status='RESOLVED';Intent='isolated'} }
        function ConvertTo-LabExternalRuntimeRequests { @() }
        function Resolve-LabAiManifestIntent { $null }
        function Get-LabManifestRuntimeContractErrors { @() }
        function Get-LabExternalRuntimePlanPreview { @() }
        function Get-LabAiManifestValidationResult { [pscustomobject]@{Errors=@();Warnings=@()} }
        function Write-LabHeader {}
        function Write-LabInfo {}
        function Write-LabWarning {}
        function Write-LabError {}
        function Write-LabSuccess {}
        function Write-LabManifestSummary {}
        function Write-LabManifestPlanPreview {}
        function Test-LabManifestNavigationResult { $false }
        function Get-LabProviderCapabilityContract { @() }
        function New-LabInstanceIntentSnapshot { [pscustomobject]@{Synthetic=$true} }
        function Get-LabManifestEnvironmentSecret { $script:Effects++; throw 'SYNTHETIC_EFFECT_VETO' }
        function New-LabRunState { $script:Effects++; throw 'SYNTHETIC_EFFECT_VETO' }
        function Invoke-LabResourceAssessmentPreflight { $script:Effects++; throw 'SYNTHETIC_EFFECT_VETO' }
        function Invoke-LabProviderOperation { $script:Effects++; throw 'SYNTHETIC_EFFECT_VETO' }
        function Test-SmtpFixedError {
            param([string]$Json,[string]$Expected,[string]$Route,[string]$Path)
            $script:Effects=0; $script:Defaults=0; $code=$null
            try {
                switch ($Route) {
                    'Admission' { Assert-LabSmtpManifestAdmission -Json $Json }
                    'Defaults' { Resolve-ManifestDefaults -Manifest ($Json | ConvertFrom-Json -Depth 100) | Out-Null }
                    'Read' { Read-LabManifest -Path $Path | Out-Null }
                    'New' { New-SqlServerLab -Manifest $Path -NonInteractive | Out-Null }
                    'TestPath' {
                        $result=Test-SqlServerLabManifest -Path $Path
                        if (-not $result.IsValid -and $result.Errors.Count -eq 1) { $code=$result.Errors[0] }
                    }
                    'TestObject' {
                        $result=Test-SqlServerLabManifest -InputObject ($Json | ConvertFrom-Json -Depth 100)
                        if (-not $result.IsValid -and $result.Errors.Count -eq 1) { $code=$result.Errors[0] }
                    }
                    'Builder' {
                        $result=Get-LabManifestValidationResult -Manifest ($Json|ConvertFrom-Json -Depth 100) -Json $Json
                        if (-not $result.IsValid -and $result.Errors.Count -eq 1 -and
                            $result.Plan.Contract.Version -ceq '1.3' -and $result.Plan.Instances.Count -eq 0) { $code=$result.Errors[0] }
                    }
                    default { throw 'SYNTHETIC_ROUTE_INVALID' }
                }
            }
            catch { $code=$_.Exception.Message }
            return [string]::Equals($code,$Expected,[StringComparison]::Ordinal) -and $script:Effects -eq 0 -and $script:Defaults -eq 0
        }
    }
    $base = '{"name":"synthetic-smtp","instances":[{"id":"primary","version":"2025"}]'
    $vectors = @(
        @('ENABLED_DEFAULTS','{}','SMTP_TEST_BACKEND_UNADMITTED'),
        @('ENABLED_EXPLICIT','{"enabled":true}','SMTP_TEST_BACKEND_UNADMITTED'),
        @('ROOT_FALSE','false','SMTP_TEST_CONFIG_INVALID'),
        @('ENABLED_STRING','{"enabled":"false"}','SMTP_TEST_CONFIG_INVALID'),
        @('OFF_EXTRA_KEY','{"enabled":false,"id":"smtp"}','SMTP_TEST_CONFIG_INVALID'),
        @('UNKNOWN_KEY','{"unknown":1}','SMTP_TEST_CONFIG_INVALID'),
        @('DERIVED_REENTRY','{"maxMessageBytes":1048576}','SMTP_TEST_CONFIG_INVALID'),
        @('DUP_TRUE_FALSE','{"enabled":true,"enabled":false}','SMTP_TEST_CONFIG_INVALID'),
        @('DUP_FALSE_TRUE','{"enabled":false,"enabled":true}','SMTP_TEST_CONFIG_INVALID'),
        @('DUP_CASE','{"enabled":true,"Enabled":false}','SMTP_TEST_CONFIG_INVALID'),
        @('RECURSIVE_DUP','{"unknown":{"a":1,"A":2}}','SMTP_TEST_CONFIG_INVALID'),
        @('RESOURCE_STRING','{"CPUs":"0.5"}','SMTP_TEST_CONFIG_INVALID'),
        @('RATE_ZERO','{"acceptedMessagesPerUtc60Seconds":0}','SMTP_TEST_CONFIG_INVALID'),
        @('MISSING_SENDER','{"senderInstanceIds":["other"]}','SMTP_TEST_SCOPE_UNSUPPORTED'),
        @('SENDER_CASE_DUP','{"senderInstanceIds":["primary","PRIMARY"]}','SMTP_TEST_CONFIG_INVALID')
    )
    foreach ($v in $vectors) {
        $json=$base+',"smtpTestService":'+$v[1]+'}'
        Add-SmtpAdmissionCheck $v[0] (& $smtpModule {param($j,$e) Test-SmtpFixedError $j $e Admission} $json $v[2])
    }
    foreach ($json in @(
        ($base+',"smtpTestService":null,"SMTPTESTSERVICE":{"enabled":false}}'),
        ($base+',"SMTPTESTSERVICE":{"enabled":false}}'))) {
        Add-SmtpAdmissionCheck ('ROOT_OCCURRENCE_'+$smtpRows.Count) (& $smtpModule {param($j) Test-SmtpFixedError $j SMTP_TEST_CONFIG_INVALID Admission} $json)
    }
    $scopeVectors=@(
        @('PODMAN','{"id":"primary","version":"2025","provider":"podman"}','SMTP_TEST_BACKEND_UNADMITTED'),
        @('CU_CATALOG','{"id":"primary","version":"2025-CU9"}','SMTP_TEST_BACKEND_UNADMITTED'),
        @('UNKNOWN_CU','{"id":"primary","version":"2025-CU999"}','SMTP_TEST_SCOPE_UNSUPPORTED'),
        @('PREFIX_FALSE','{"id":"primary","version":"2025-made-up"}','SMTP_TEST_SCOPE_UNSUPPORTED'),
        @('SQL2022','{"id":"primary","version":"2022"}','SMTP_TEST_SCOPE_UNSUPPORTED'),
        @('WINDOWS_DEFAULT','{"id":"primary","version":"2025","os":"windows"}','SMTP_TEST_SCOPE_UNSUPPORTED'),
        @('GUI_DEFAULT','{"id":"primary","version":"2025","software":[{"id":"ssms"}]}','SMTP_TEST_SCOPE_UNSUPPORTED'),
        @('HYPERV','{"id":"primary","version":"2025","provider":"hyperv"}','SMTP_TEST_SCOPE_UNSUPPORTED'),
        @('MIXED','{"id":"primary","version":"2025","provider":"docker"},{"id":"second","version":"2025","provider":"podman"}','SMTP_TEST_SCOPE_UNSUPPORTED')
    )
    foreach($v in $scopeVectors) {
        $json='{"name":"synthetic-smtp","instances":['+$v[1]+'],"smtpTestService":{}}'
        Add-SmtpAdmissionCheck $v[0] (& $smtpModule {param($j,$e) Test-SmtpFixedError $j $e Admission} $json $v[2])
    }
    $active=$base+',"smtpTestService":{},"automation":{"secrets":{"saPassword":"SYNTHETIC_SA_REF"}}}'
    $path=Join-Path $smtpTemp 'active.json';[IO.File]::WriteAllText($path,$active)
    foreach($route in @('Defaults','Read','New','TestPath','TestObject','Builder')) {
        Add-SmtpAdmissionCheck ('ADAPTER_'+$route) (& $smtpModule {param($j,$r,$p) Test-SmtpFixedError $j SMTP_TEST_BACKEND_UNADMITTED $r $p} $active $route $path)
    }
    $duplicate=$base+',"smtpTestService":{"enabled":true,"enabled":false}}'
    [IO.File]::WriteAllText($path,$duplicate)
    foreach($route in @('Read','New','TestPath','Builder')) {
        Add-SmtpAdmissionCheck ('RAW_DUP_ADAPTER_'+$route) (& $smtpModule {param($j,$r,$p) Test-SmtpFixedError $j SMTP_TEST_CONFIG_INVALID $r $p} $duplicate $route $path)
    }
    $snapshots=@()
    foreach($suffix in @('}',',"smtpTestService":null}',',"smtpTestService":{"enabled":false}}')) {
        $json=$base+$suffix;[IO.File]::WriteAllText($path,$json)
        $legacy=&$smtpModule {param($p)
            $validation=Test-SqlServerLabManifest -Path $p
            $resolved=Read-LabManifest -Path $p
            $snapshot=New-LabDesiredStateSnapshot -ResolvedLab $resolved -ProvisioningMode manifest -PersistentData $false
            [pscustomobject]@{Valid=$validation.IsValid;Resolved=$resolved;Snapshot=$snapshot}
        } $path
        Add-SmtpAdmissionCheck ('LEGACY_'+$snapshots.Count) ($legacy.Valid -and !$legacy.Resolved.PSObject.Properties['smtpTestService'] -and
            $legacy.Snapshot.Contract.Version -ceq '1.0' -and !$legacy.Snapshot.PSObject.Properties['smtpTestService'])
        $snapshots+=($legacy.Snapshot|ConvertTo-Json -Depth 100 -Compress)
    }
    Add-SmtpAdmissionCheck 'LEGACY_DESIREDSTATE_EXACT_PARITY' ($snapshots[0] -ceq $snapshots[1] -and $snapshots[0] -ceq $snapshots[2])
    $schemaChecks=&$smtpModule {
        $schema=Get-LabManifestSchema
        $support=Test-LabManifestSchemaInputSupport -RootSchema $schema
        $nullValue=Read-LabManifestSchemaValue -Node ([pscustomobject]@{type='null'}) -RootSchema $schema -Path manifest.smtpTestService
        [pscustomobject]@{Supported=$support.IsSupported;Null=($null -eq $nullValue)}
    }
    Add-SmtpAdmissionCheck 'WIZARD_SCHEMA_ALL_SUPPORTED' $schemaChecks.Supported
    Add-SmtpAdmissionCheck 'WIZARD_NULL_VALUE' $schemaChecks.Null
    $save=Join-Path $smtpTemp 'rejected.json'
    $rejected=&$smtpModule {param($j,$p);try{New-SqlServerLabManifest -Path $p -InputObject ($j|ConvertFrom-Json) -ErrorAction Stop|Out-Null;$false}catch{$true}} $active $save
    Add-SmtpAdmissionCheck 'WIZARD_NO_ACTIVE_FILE' ($rejected -and !(Test-Path -LiteralPath $save))
}
finally {
    if($null -ne $smtpModule){Remove-Module $smtpModule -Force}
    if(Test-Path -LiteralPath $smtpTemp){Remove-Item -LiteralPath $smtpTemp -Recurse -Force}
}
if($Standalone) {
    [pscustomobject]@{Schema='SmtpManifestAdmissionChecks/v1';Passed=@($smtpRows|Where-Object Success).Count;
        Failed=@($smtpRows|Where-Object {!$_.Success}).Count;Rows=@($smtpRows);OwnCleanup=$true;NativeOperations=0}
}
else {
    foreach($row in $smtpRows){Add-CheckResult -Name ('SMTP Manifest: '+$row.Id) -Success $row.Success}
}
