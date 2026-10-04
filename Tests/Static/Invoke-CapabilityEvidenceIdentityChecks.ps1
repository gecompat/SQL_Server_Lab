#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'Private/CapabilityEvidence.ps1')
$script:passed=0
function Assert-EvidenceIdentity {param([bool]$Condition,[string]$Name)
    if(-not $Condition){throw "FIXTURE_FAILED: $Name"};$script:passed++;Write-Host "PASS: $Name"
}
# Persist isolated synthetic inputs locally; no runtime, SQL, process or cleanup path.
$fixture=Join-Path $root ('.artifacts/evidence-identity-fixtures/'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path (Join-Path $fixture 'Schemas'),(Join-Path $fixture 'Documentation/Quality') -Force
Copy-Item (Join-Path $root 'Schemas/capability-evidence-index.schema.json') (Join-Path $fixture 'Schemas/capability-evidence-index.schema.json')
# An untrusted data root deliberately offers an accept-all schema. It is never authority.
[IO.File]::WriteAllText((Join-Path $fixture 'Schemas/capability-evidence-index.schema.json'),'{}')
$index=Join-Path $fixture 'Documentation/Quality/capability-evidence-index.json'
function Write-Document {param($Value)
    [IO.File]::WriteAllText($index,($Value|ConvertTo-Json -Depth 30 -Compress),[Text.UTF8Encoding]::new($false))
}
$legacy=Get-Content (Join-Path $root 'Documentation/Quality/capability-evidence-index.json') -Raw|ConvertFrom-Json -Depth 30
Write-Document $legacy
$read=Read-LabCapabilityEvidenceIndex $fixture -IncludeIdentity
Assert-EvidenceIdentity ($read.Status -ceq 'RECORDED' -and $read.Records.Count -eq 11) 'Legacy schema and all original records remain readable'
$legacyCells=New-LabCapabilityEvidenceIdentityCells $read.Records $read.ContractVersion
Assert-EvidenceIdentity (@($legacyCells|Where-Object MappingStatus -CNE 'NOT_DEFINED').Count -eq 0) 'Legacy identity is unknown, never wildcard'
Assert-EvidenceIdentity ((Get-LabCapabilityEvidenceTupleKey @($null)) -cne (Get-LabCapabilityEvidenceTupleKey @('null'))) 'Typed null differs from literal string'
Assert-EvidenceIdentity ((Get-LabCapabilityEvidenceTupleKey @($false)) -cne (Get-LabCapabilityEvidenceTupleKey @('false'))) 'Boolean differs from string'
$identity=[pscustomobject]@{Kind='EXTERNAL_RUNTIME_CONTAINER/1.0';TargetOperatingSystem='linux';TargetDistribution='ubuntu-22.04';Architecture='x86_64';SoftwareId='sql-python';RuntimeVersion='3.10';VariantId='sql2022-python310-ubuntu2204-derived';SoftwarePlanKey=('a'*64);BaseImageSha256=('b'*64);LaunchMode='sql2022-namespace-v1';RequiredCgroupVersion='1'}
$record=[pscustomobject]@{Capability='external-runtime-capability';Provider='docker';SqlVersion='2022';Platform='windows';Scope='NATIVE_LIFECYCLE';SourceRevision=('c'*40);Test='Tests/Integration/Invoke-SmokeTest.ps1';Result='PASS';Cleanup='PASS';Date='2026-10-03';Reference='https://github.com/gecompat/SQL_Server_Lab/actions/runs/1';Identity=$identity;ObservedHostProfile=[pscustomobject]@{OperatingSystem='linux';CgroupVersion='1';Rootless=$false}}
$document=[pscustomobject]@{ContractVersion='SqlServerLab.CapabilityEvidenceIndex/1.1';EvidenceBoundary='RECORDED_HISTORY_ONLY';Records=@($record)}
foreach($failure in @('RawReference','ExtraField','ProfileType')) {
    $bad=$record|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20
    switch($failure) {
        'RawReference' {$bad.Reference='SYNTHETIC_PRIVATE_REFERENCE_CANARY'}
        'ExtraField' {$bad|Add-Member UnexpectedField 'SYNTHETIC_PRIVATE_FIELD_CANARY'}
        'ProfileType' {$bad.ObservedHostProfile='false'}
    }
    $document.Records=@($bad);Write-Document $document
    Assert-EvidenceIdentity ((Read-LabCapabilityEvidenceIndex $fixture -IncludeIdentity).Status -ceq 'INVALID') "Definition-owned schema vetoes $failure despite foreign accept-all schema"
}
$document.Records=@($record)
Write-Document $document
$read=Read-LabCapabilityEvidenceIndex $fixture -IncludeIdentity
Assert-EvidenceIdentity ($read.Status -ceq 'RECORDED') 'Extended exact identity accepts valid original-proof shape'
Assert-EvidenceIdentity ((Read-LabCapabilityEvidenceIndex $fixture).Status -ceq 'SCHEMA_UNSUPPORTED') 'Old consumers do not flatten extended identities'
$plan=[pscustomobject]@{Status='RESOLVED';Provider='docker';SqlVersion='2022';SoftwareId='sql-python';RuntimeVersion='3.10';VariantId=$identity.VariantId;PlanKey=$identity.SoftwarePlanKey}
$recipe=[pscustomobject]@{operatingSystem='ubuntu-22.04';architecture='x86_64';baseImage=[pscustomobject]@{sha256=$identity.BaseImageSha256};launchContract=[pscustomobject]@{mode=$identity.LaunchMode;requiredCgroupVersion='1'}}
$matched=Get-LabExternalRuntimeRecordedEvidence $plan $recipe $fixture
Assert-EvidenceIdentity ($matched.Status -ceq 'RECORDED_HISTORY_ONLY' -and $matched.RecordCount -eq 1 -and $matched.Cells[0].RecordedPlatform -ceq 'windows') 'Exact matcher separates recorded platform from Linux target'
Assert-EvidenceIdentity ($matched.Cells[0].NativeAcceptanceStatus -ceq 'UNKNOWN' -and $matched.Cells[0].CurrentReadinessStatus -ceq 'NOT_CHECKED') 'Recorded PASS never grants current acceptance/readiness'
$plan.Provider='podman'
Assert-EvidenceIdentity ((Get-LabExternalRuntimeRecordedEvidence $plan $recipe $fixture).ReasonCode -ceq 'INDEX_NO_MATCH') 'Provider is an exact matching dimension'
$plan.Provider='docker';$plan.SqlVersion=$null
Assert-EvidenceIdentity ((Get-LabExternalRuntimeRecordedEvidence $plan $recipe $fixture).ReasonCode -ceq 'CATALOG_IDENTITY_UNRESOLVED') 'Missing SQL is never a join wildcard'
$plan.SqlVersion='2022'
$copy=$record|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20
$copy.Result='FAIL';$copy.Cleanup='RECOVERY_REQUIRED';$document.Records=@($record,$copy)
Write-Document $document;$read=Read-LabCapabilityEvidenceIndex $fixture -IncludeIdentity
$cells=New-LabCapabilityEvidenceIdentityCells $read.Records $read.ContractVersion
Assert-EvidenceIdentity ($read.Status -ceq 'RECORDED' -and $cells.Count -eq 1 -and $cells[0].HistoryConflict -and $cells[0].RecordCount -eq 2) 'Same observation incompatible outcomes preserve both records and conflict'
$copy.Date='2026-10-02';Write-Document $document;$read=Read-LabCapabilityEvidenceIndex $fixture -IncludeIdentity
Assert-EvidenceIdentity (-not (New-LabCapabilityEvidenceIdentityCells $read.Records $read.ContractVersion)[0].HistoryConflict) 'Different dates preserve history without false conflict'
foreach($field in @('Capability','Provider','SqlVersion')) {
    $bad=$record|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20
    $bad.$field=switch($field){Capability{'other-capability'}Provider{'hyperv'}SqlVersion{$null}}
    $document.Records=@($bad);Write-Document $document
    Assert-EvidenceIdentity ((Read-LabCapabilityEvidenceIndex $fixture -IncludeIdentity).Status -ceq 'INVALID') "Extended family rejects wrong $field"
}
foreach($value in @($null,'false',$true)) {
    $bad=$record|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20;$bad.ObservedHostProfile.Rootless=$value
    $document.Records=@($bad);Write-Document $document
    Assert-EvidenceIdentity ((Read-LabCapabilityEvidenceIndex $fixture -IncludeIdentity).Status -ceq 'INVALID') 'Native PASS requires verified typed rootful profile'
}
$document.Records=@($record);Write-Document $document;$text=Get-Content $index -Raw
foreach($badText in @($text.Replace('"Capability":','"capability":'),$text.Replace('"Capability":','"Capability":"other", "Capability":'),$text.Replace('"Capability":','"CAPABILITY":"other", "Capability":'))) {
    [IO.File]::WriteAllText($index,$badText)
    Assert-EvidenceIdentity ((Read-LabCapabilityEvidenceIndex $fixture -IncludeIdentity).Status -ceq 'INVALID') 'New JSON rejects wrong case and duplicate/case-folded keys'
}
$document.ContractVersion='SqlServerLab.CapabilityEvidenceIndex/9.0';Write-Document $document
Assert-EvidenceIdentity ((Read-LabCapabilityEvidenceIndex $fixture -IncludeIdentity).Status -ceq 'SCHEMA_UNSUPPORTED') 'Unknown schema is explicit unsupported'
$module=New-Module -ArgumentList $root -ScriptBlock {
    param($root)
    $script:ModuleRoot=$root;$script:CatalogsPath=Join-Path $root 'Catalogs'
    $script:VersionCatalog=Get-Content (Join-Path $root 'Catalogs/sql-server-versions.json') -Raw|ConvertFrom-Json
    $script:RegisteredProviders=@{}
    foreach($provider in @('Docker','Podman')) {
        $definition=Get-Content (Join-Path $root "Providers/$provider/provider.json") -Raw|ConvertFrom-Json
        $script:RegisteredProviders[$definition.name]=@{Definition=$definition}
    }
    foreach($path in @('Private/VersionCatalog.ps1','Private/SoftwareCatalog.ps1','Private/ContainerImageArtifact.ps1','Private/CapabilityEvidence.ps1','Private/ExternalRuntimeCapability.ps1','Public/Get-SqlServerLabExternalRuntimeCapability.ps1')){. (Join-Path $root $path)}
    $script:observations=0
    function Read-LabExternalRuntimeHostFacts {param($Provider) $script:observations++;throw 'FORBIDDEN_HOST_PROBE'}
    function Get-LabProvider {param($Name) [pscustomobject]@{Name=$Name}}
}
& $module {
    $params=@{SqlVersion='2022';Provider='docker';OperatingSystem='linux';SoftwareId='sql-python';RuntimeVersion='3.10';VariantId='sql2022-python310-ubuntu2204-derived'}
    $default=Get-SqlServerLabExternalRuntimeCapability @params
    $extended=Get-SqlServerLabExternalRuntimeCapability @params -IncludeRecordedEvidence
    if($default.Contract.Version -cne '1.0' -or @($default.HistoricalEvidence.PSObject.Properties).Count -ne 2){throw 'PUBLIC_DEFAULT_CHANGED'}
    if($extended.Contract.Version -cne '1.1' -or $extended.CatalogDecision.Status -cne 'DECLARED_SUPPORTED' -or $extended.HistoricalEvidence.ReasonCode -cne 'INDEX_LEGACY_IDENTITY_UNKNOWN'){throw 'PUBLIC_OPTIN_COMPOSITION_FAILED'}
    if($script:observations -ne 0){throw 'UNEXPECTED_OBSERVATION'}
}
Assert-EvidenceIdentity $true 'Actual Public/resolver/recipe/reader opt-in keeps default and performs zero observed host probes'
$tool=Join-Path $root 'Tools/Get-SqlServerLabCapabilityInventory.ps1'
try {& $tool -IncludeRecordedIdentityMatrix|Out-Null;throw 'SWITCH_DEPENDENCY_NOT_REJECTED'}catch{
    Assert-EvidenceIdentity ($_.Exception.Message -ceq 'RECORDED_IDENTITY_MATRIX_REQUIRES_ACCEPTANCE_MATRIX') 'New tool switch requires old opt-in before source work'
}
$document.Records=@($record);$document.ContractVersion='SqlServerLab.CapabilityEvidenceIndex/1.1';Write-Document $document
$null=New-Item -ItemType Directory -Path (Join-Path $fixture 'Private') -Force
[IO.File]::WriteAllText((Join-Path $fixture 'Private/CapabilityEvidence.ps1'),'throw "FOREIGN_DATA_ROOT_CODE"')
[IO.File]::WriteAllText((Join-Path $fixture 'SqlServerLab.psm1'),'throw "FORBIDDEN_IMPORT"')
$matrix=& $tool -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix -IncludeRecordedIdentityMatrix
Assert-EvidenceIdentity ($matrix.ContractVersion -ceq 'SqlServerLab.RepositoryCapabilityInventory/1.2' -and $matrix.SourceScope -ceq 'RECORDED_IDENTITY_MATRIX_ONLY' -and @($matrix.PSObject.Properties).Count -eq 11) 'Actual tool outputs only closed eleven-field matrix'
Assert-EvidenceIdentity ($matrix.RecordCount -eq 1 -and $matrix.Cells.Count -eq 1 -and $matrix.Status -ceq 'RECORDED_HISTORY_ONLY') 'Actual tool uses own helper, never foreign code/module'
Assert-EvidenceIdentity ($null -eq $matrix.PSObject.Properties['Sources'] -and -not $matrix.MutationAllowed -and $matrix.CurrentExecutionStatus -ceq 'NOT_EXECUTED') 'No fake empty inventory or current execution claim'
$legacyMatrix=& $tool -RepositoryRoot $root -IncludeRecordedAcceptanceMatrix -IncludeRecordedIdentityMatrix
Assert-EvidenceIdentity ($legacyMatrix.RecordCount -eq 11 -and @($legacyMatrix.Cells|Where-Object MappingStatus -CNE 'NOT_DEFINED').Count -eq 0) 'New view retains all actual legacy history with unknown mapping'
$overflow=@(foreach($n in 1..128){
    $r=$record|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20
    $r.Identity.SoftwarePlanKey=$n.ToString('x64');$r.Reference='https://github.com/gecompat/SQL_Server_Lab/actions/runs/'+('1'*900)+$n
    $r
})
$document.Records=$overflow;Write-Document $document
Assert-EvidenceIdentity ((Read-LabCapabilityEvidenceIndex $fixture -IncludeIdentity).Records.Count -eq 128) 'All 128 bounded records validate without truncation'
$matrix=& $tool -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix -IncludeRecordedIdentityMatrix
Assert-EvidenceIdentity ($matrix.Status -ceq 'UNAVAILABLE' -and $matrix.ReasonCode -ceq 'EVIDENCE_OUTPUT_LIMIT' -and $matrix.RecordCount -eq 0 -and $matrix.Cells.Count -eq 0) 'Complete matrix response overflow fails closed without truncation'
Assert-EvidenceIdentity ([Text.Encoding]::UTF8.GetByteCount(($matrix|ConvertTo-Json -Depth 30 -Compress)) -le 262144) 'Overflow response itself meets full UTF8 bound'
$document.Records=@($overflow)+@($record);Write-Document $document
Assert-EvidenceIdentity ((Read-LabCapabilityEvidenceIndex $fixture -IncludeIdentity).Status -ceq 'INVALID') '129 records fail closed'
$copySource=Join-Path $fixture 'source-boundary'
$null=New-Item -ItemType Directory -Path (Join-Path $copySource 'Tools'),(Join-Path $copySource 'Private') -Force
Copy-Item $tool (Join-Path $copySource 'Tools/Get-SqlServerLabCapabilityInventory.ps1')
Copy-Item (Join-Path $root 'Private/CapabilityEvidence.ps1') (Join-Path $copySource 'Private/CapabilityEvidence.ps1')
$boundTool=Join-Path $copySource 'Tools/Get-SqlServerLabCapabilityInventory.ps1'
Write-Document $legacy
$control=& $boundTool -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix -IncludeRecordedIdentityMatrix
Assert-EvidenceIdentity ($control.Status -ceq 'UNAVAILABLE' -and $control.RecordCount -eq 0) 'Missing definition-owned schema cannot borrow a data-root schema'
$null=New-Item -ItemType Directory -Path (Join-Path $copySource 'Schemas')
Copy-Item (Join-Path $root 'Schemas/capability-evidence-index.schema.json') (Join-Path $copySource 'Schemas/capability-evidence-index.schema.json')
$control=& $boundTool -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix -IncludeRecordedIdentityMatrix
Assert-EvidenceIdentity ($control.RecordCount -eq 11) 'Copied own tool helper has expected source ABI'
$schemaLinkedSource=Join-Path $fixture 'schema-linked-source-boundary'
$null=New-Item -ItemType Directory -Path (Join-Path $schemaLinkedSource 'Tools'),(Join-Path $schemaLinkedSource 'Private')
Copy-Item $tool (Join-Path $schemaLinkedSource 'Tools/Get-SqlServerLabCapabilityInventory.ps1')
Copy-Item (Join-Path $root 'Private/CapabilityEvidence.ps1') (Join-Path $schemaLinkedSource 'Private/CapabilityEvidence.ps1')
$null=New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path (Join-Path $schemaLinkedSource 'Schemas') -Target (Join-Path $copySource 'Schemas')
$schemaBlocked=& (Join-Path $schemaLinkedSource 'Tools/Get-SqlServerLabCapabilityInventory.ps1') -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix -IncludeRecordedIdentityMatrix
Assert-EvidenceIdentity ($schemaBlocked.Status -ceq 'UNAVAILABLE' -and $schemaBlocked.RecordCount -eq 0) 'Definition-owned schema ancestor reparse cannot supply authority'
$linkedSource=Join-Path $fixture 'linked-source-boundary'
$null=New-Item -ItemType Directory -Path (Join-Path $linkedSource 'Tools') -Force
Copy-Item $tool (Join-Path $linkedSource 'Tools/Get-SqlServerLabCapabilityInventory.ps1')
$null=New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path (Join-Path $linkedSource 'Private') -Target (Join-Path $copySource 'Private')
try {& (Join-Path $linkedSource 'Tools/Get-SqlServerLabCapabilityInventory.ps1') -RepositoryRoot $fixture -IncludeRecordedAcceptanceMatrix -IncludeRecordedIdentityMatrix|Out-Null;throw 'REPARSE_VETO_MISSING'}catch{
    Assert-EvidenceIdentity ($_.Exception.Message -ceq 'EVIDENCE_HELPER_REPARSE_POINT_NOT_READ') 'Tool source helper ancestor reparse is vetoed before dot-source'
}
$badData=Join-Path $fixture 'bad-data-root'
$null=New-Item -ItemType Directory -Path (Join-Path $badData 'Documentation') -Force
$null=New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path (Join-Path $badData 'Documentation/Quality') -Target (Join-Path $fixture 'Documentation/Quality')
$blocked=& $tool -RepositoryRoot $badData -IncludeRecordedAcceptanceMatrix -IncludeRecordedIdentityMatrix
Assert-EvidenceIdentity ($blocked.Status -ceq 'UNAVAILABLE' -and $blocked.ReasonCode -ceq 'INDEX_INVALID' -and $blocked.RecordCount -eq 0) 'Data-root reparse fails closed with no raw path in result'
$resolved=& $module {
    $request=[pscustomobject]@{Id='sql-python';Version='3.10';Variant='sql2022-python310-ubuntu2204-derived';InstallMethod='catalog';Packages=@();RequestSource='capability-decision'}
    [pscustomobject]@{Plan=(Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion 2022 -Provider docker -OperatingSystem linux);Recipe=(Get-LabExternalRuntimeContainerRecipe -SqlVersion 2022)}
}
$publicRows=[Collections.Generic.List[object]]::new()
foreach($platform in @('windows','linux')){foreach($scope in @('STATIC_CONTRACT','PACKAGE','NATIVE_SQL','NATIVE_LIFECYCLE')){
    foreach($os in @($null,'linux','windows')){foreach($cgroup in @($null,'1','2')){foreach($rootless in @($null,$false,$true)){
        if($publicRows.Count -ge 128){continue}
        $r=$record|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20
        $r.Identity.SoftwarePlanKey=$resolved.Plan.PlanKey;$r.Identity.BaseImageSha256=$resolved.Recipe.baseImage.sha256
        $r.Platform=$platform;$r.Scope=$scope;$r.Result='FAIL';$r.Cleanup='NOT_EXECUTED'
        $r.Test=if($scope -cin @('NATIVE_SQL','NATIVE_LIFECYCLE')){'Tests/Integration/Invoke-SmokeTest.ps1'}else{'Tests/Static/Invoke-CapabilityInventoryChecks.ps1'}
        $r.ObservedHostProfile=[pscustomobject]@{OperatingSystem=$os;CgroupVersion=$cgroup;Rootless=$rootless}
        $r.Reference='https://github.com/gecompat/SQL_Server_Lab/actions/runs/'+('1'*900)+$publicRows.Count
        $publicRows.Add($r)
    }}}
}}
$document.Records=@($publicRows);Write-Document $document
Assert-EvidenceIdentity ((Read-LabCapabilityEvidenceIndex $fixture -IncludeIdentity).Records.Count -eq 128) 'Large exact public-match input remains schema-valid and bounded'
& $module {
    param($fixture)
    $script:fixtureDataRoot=$fixture
    $script:actualReader=(Get-Command Read-LabCapabilityEvidenceIndex).ScriptBlock
    function Read-LabCapabilityEvidenceIndex {
        param($RepositoryRoot,[switch]$IncludeIdentity)
        & $script:actualReader -RepositoryRoot $script:fixtureDataRoot -IncludeIdentity:$IncludeIdentity
    }
    $result=Get-SqlServerLabExternalRuntimeCapability -SqlVersion 2022 -Provider docker -OperatingSystem linux -SoftwareId sql-python -RuntimeVersion 3.10 -VariantId sql2022-python310-ubuntu2204-derived -IncludeRecordedEvidence
    if($result.HistoricalEvidence.ReasonCode -cne 'EVIDENCE_OUTPUT_LIMIT' -or $result.HistoricalEvidence.Cells.Count -ne 0 -or $result.HistoricalEvidence.RecordCount -ne 0){throw 'PUBLIC_FULL_OUTPUT_LIMIT_NOT_ENFORCED'}
    if([Text.Encoding]::UTF8.GetByteCount(($result|ConvertTo-Json -Depth 30 -Compress)) -gt 262144 -or $script:observations -ne 0){throw 'PUBLIC_OVERFLOW_RESPONSE_INVALID'}
} $fixture
Assert-EvidenceIdentity $true 'Actual Public/Core/matcher complete response overflow is bounded, empty and zero-probe'
Write-Host "EVIDENCE IDENTITY: $script:passed PASS; isolated files retained; no runtime execution"
