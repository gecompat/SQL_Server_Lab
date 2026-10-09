# Actual manifest validator/resolver/public entry, with isolated catalog and effect vetoes.
$outputModule = New-Module -Name ManifestSampleOutputChecks -ArgumentList $repoRoot -ScriptBlock {
    param($root)
    $script:SchemasPath = Join-Path $root 'Schemas'
    . (Join-Path $root 'Private/SmtpTestServiceConfig.ps1')
    . (Join-Path $root 'Private/SmtpTestServiceManifestAdmission.ps1')
    . (Join-Path $root 'Private/ManifestParser.ps1')
    . (Join-Path $root 'Private/ManifestBuilder.ps1')
    . (Join-Path $root 'Public/New-SqlServerLab.ps1')
    $script:Catalog = @{}
    $script:CatalogReads = 0
    $script:Drift = $false
    $script:Effects = 0
    function Get-LabSampleDatabase {
        param($Id)
        $script:CatalogReads++
        $item = $script:Catalog[$Id] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        if ($script:Drift -and $script:CatalogReads -gt 1) { $item.versions.full.expectedOutputs[1].name = 'Shared' }
        return $item
    }
    function Resolve-LabSqlServerCollation { 'SQL_Latin1_General_CP1_CI_AS' }
    function Get-LabManifestRuntimeContractErrors { @() }
    function Resolve-LabNetworkIntentPlan { [PSCustomObject]@{Status='RESOLVED';Intent='isolated'} }
    function Test-SqlServerVersionSupported { [PSCustomObject]@{Supported=$true;Status='SUPPORTED';Message=$null} }
    function Get-SqlServerVersion { [PSCustomObject]@{id='2025';compatibilityLevel=170} }
    function Get-SqlServerDockerImage { 'synthetic-image' }
    function ConvertTo-LabExternalRuntimeRequests { @() }
    function Get-LabExternalRuntimePlanPreview { @() }
    function Get-LabAiManifestValidationResult { [PSCustomObject]@{Errors=@();Warnings=@()} }
    function Resolve-DatabaseFiles { $null }
    function Resolve-LabServerConfig { $null }
    function Resolve-LabAiManifestIntent { $null }
    function Write-LabHeader {}
    function Write-LabInfo {}
    function Write-LabWarning {}
    function New-LabRunState { $script:Effects++; throw 'FIXTURE_EFFECT_VETO' }
    function Invoke-LabResourceAssessmentPreflight { $script:Effects++; throw 'FIXTURE_EFFECT_VETO' }
    function Get-LabManifestEnvironmentSecret { $script:Effects++; throw 'FIXTURE_EFFECT_VETO' }
    function New-OutputSample {
        param($Id, $Names, $Kind='script-bundle', [switch]$Override)
        [PSCustomObject]@{ id=$Id; versions=[PSCustomObject]@{full=[PSCustomObject]@{
            url='https://example.invalid/synthetic';artifactType=$Kind;handlerContractVersion='1';
            runtimeStatus='executable';trustPolicy='interactive-once';
            expectedOutputs=@($Names | ForEach-Object {[PSCustomObject]@{kind='database';name=$_}});
            installation=[PSCustomObject]@{kind=$Kind;allowTargetDatabaseOverride=$Override.IsPresent;idempotencyMode='fail-if-exists'}
        }}}
    }
    function New-OutputManifest {
        param($Databases)
        [PSCustomObject]@{name='synthetic-outputs';instances=@([PSCustomObject]@{
            id='sql';version='2025';provider='docker';os='linux';databases=@($Databases)
        })}
    }
    function Test-OutputCase {
        param($Manifest, [string]$ExpectedCode)
        $script:CatalogReads=0
        $validation=Get-LabManifestValidationResult -Manifest $Manifest -Json ($Manifest|ConvertTo-Json -Depth 20)
        $code=$null
        try { $null=Resolve-ManifestDefaults -Manifest $Manifest -ManifestPath (Join-Path $root 'synthetic.json') }
        catch { $code=$_.Exception.Message }
        if ($ExpectedCode) { return (-not $validation.IsValid -and ($validation.Errors -join ';') -match $ExpectedCode -and $code -match $ExpectedCode) }
        return ($validation.IsValid -and $null -eq $code)
    }
}
try {
    $cases = & $outputModule {
        $script:Catalog.a=New-OutputSample a @('Alpha','Shared')
        $script:Catalog.b=New-OutputSample b @('Beta','shared')
        $sampleA=[PSCustomObject]@{name='Alpha';sample=[PSCustomObject]@{id='a';variant='full'}}
        $sampleB=[PSCustomObject]@{name='Beta';sample=[PSCustomObject]@{id='b';variant='full'}}
        $results=[ordered]@{}
        $results.SecondOutputExplicit=Test-OutputCase (New-OutputManifest @($sampleA,[PSCustomObject]@{name='Shared'})) SAMPLE_OUTPUT_CONFLICT
        $results.SecondOutputCase=Test-OutputCase (New-OutputManifest @($sampleA,[PSCustomObject]@{name='sHaReD'})) SAMPLE_OUTPUT_CONFLICT
        $results.BundleUnion=Test-OutputCase (New-OutputManifest @($sampleA,$sampleB)) SAMPLE_OUTPUT_CONFLICT
        $results.Disjoint=Test-OutputCase (New-OutputManifest @($sampleA,[PSCustomObject]@{name='Other'})) ''
        $separate=New-OutputManifest @($sampleA)
        $second=$separate.instances[0]|ConvertTo-Json -Depth 20|ConvertFrom-Json
        $second.id='other';$separate.instances+=@($second)
        $results.SeparateInstances=Test-OutputCase $separate ''
        $script:Catalog.single=New-OutputSample single @('Source') backup -Override
        $override=[PSCustomObject]@{name='Target';sample=[PSCustomObject]@{id='single';variant='full'}}
        $results.ResolvedOverride=Test-OutputCase (New-OutputManifest @($override,[PSCustomObject]@{name='Source'})) ''
        $results.SingleOutput=Test-OutputCase (New-OutputManifest @($override)) ''
        $overrideCollision=[PSCustomObject]@{name='SHARED';sample=[PSCustomObject]@{id='single';variant='full'}}
        $results.OverrideBundleCollision=Test-OutputCase (New-OutputManifest @($sampleA,$overrideCollision)) SAMPLE_OUTPUT_CONFLICT
        foreach($invalid in 'Empty','Blank','Numeric','Kind','Duplicate','NamePattern') {
            $entry=New-OutputSample a @('Alpha','Other')
            switch($invalid) {
                Empty {$entry.versions.full.expectedOutputs=@()}
                Blank {$entry.versions.full.expectedOutputs[1].name=' '}
                Numeric {$entry.versions.full.expectedOutputs[1].name=42}
                Kind {$entry.versions.full.expectedOutputs[1].kind='file'}
                Duplicate {$entry.versions.full.expectedOutputs[1].name='ALPHA'}
                NamePattern {$entry.versions.full.expectedOutputs[1].name='not/a/database'}
            }
            $script:Catalog.a=$entry
            $expected=if($invalid -eq 'Duplicate'){'SAMPLE_OUTPUT_CONFLICT'}else{'SAMPLE_OUTPUTS_INVALID'}
            $results["Malformed$invalid"]=Test-OutputCase (New-OutputManifest @($sampleA)) $expected
        }
        $script:Catalog.a=New-OutputSample a @('Alpha','Other')
        $script:Drift=$true;$script:CatalogReads=0
        $manifest=New-OutputManifest @($sampleA,[PSCustomObject]@{name='Shared'})
        $path=Join-Path ([System.IO.Path]::GetTempPath()) ('sql-lab-output-'+[guid]::NewGuid().ToString('N')+'.json')
        try {
            [System.IO.File]::WriteAllText($path,($manifest|ConvertTo-Json -Depth 20))
            $code=$null
            try {$null=New-SqlServerLab -Manifest $path -NonInteractive} catch {$code=$_.Exception.Message}
            $results.PublicReresolutionDrift=($code -eq 'SAMPLE_OUTPUT_CONFLICT' -and $script:Effects -eq 0 -and $script:CatalogReads -eq 2)
            $script:Drift=$false;$script:CatalogReads=0
            $script:Catalog.a=New-OutputSample a @('Alpha','Shared')
            $code=$null
            try {$null=New-SqlServerLab -Manifest $path -NonInteractive} catch {$code=$_.Exception.Message}
            $results.PublicValidationCollision=($code -match 'SAMPLE_OUTPUT_CONFLICT' -and $script:Effects -eq 0 -and $script:CatalogReads -eq 1)
        } finally {Remove-Item -LiteralPath $path -Force}
        $results
    }
    foreach($entry in $cases.GetEnumerator()) {
        Add-CheckResult -Name "Manifest sample output preflight: $($entry.Key)" -Success $entry.Value -Message 'Actual validator/resolver; isolated catalog; no resource acquisition.'
    }
} finally { Remove-Module $outputModule -ErrorAction SilentlyContinue }
