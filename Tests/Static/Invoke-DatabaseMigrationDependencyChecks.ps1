#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$results=[Collections.Generic.List[object]]::new()
function Add-CheckResult { param([string]$Name,[bool]$Success) $results.Add([PSCustomObject]@{Name=$Name;Success=$Success});Write-Host "$(if($Success){'PASS'}else{'FAIL'}): $Name" -ForegroundColor $(if($Success){'Green'}else{'Red'}) }

Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    $result=& $module {
        $script:capturedQuery=$null
        Set-Item Function:script:Invoke-SqlQuery -Value {
            param($Query)
            $script:capturedQuery=[string]$Query
            @(
                'PSR010_META|17|NONE|1|3|CERTIFICATE',
                'PSR010_COUNT|SERVER_LOGIN_MAPPING|2',
                'PSR010_COUNT|SQL_AGENT_JOB|1',
                'PSR010_COUNT|CREDENTIAL_OR_PROXY|1',
                'PSR010_COUNT|LINKED_SERVER|1'
            )
        }
        $observation=Get-LabDatabaseMigrationDependencySqlObservation -Port 14330 -SaPlain 'ephemeral-test-value' -DatabaseName Evidence
        $blocked=New-LabDatabaseMigrationDependencyInventory -DatabaseName Evidence -Provider hyperv -RunId 'sanitized-run' -InstanceId primary -Observation $observation
        $review=New-LabDatabaseMigrationDependencyInventory -DatabaseName Evidence -Provider hyperv -Observation $observation -TdeRecoveryEvidenceVerified $true
        $boundary=Get-LabDatabaseArtifactMigrationBoundary -DependencyInventory $review -ExternalDependencies @('CUSTOM_EXTERNAL_RUNTIME')
        $duplicate=$false
        $invalid=$review|ConvertTo-Json -Depth 40|ConvertFrom-Json -Depth 40
        $invalid.Dependencies[1].Category='SERVER_LOGIN_MAPPING'
        try{$null=Test-LabDatabaseMigrationDependencyInventory -Inventory $invalid}catch{$duplicate=$_.Exception.Message -match 'CATEGORY_DUPLICATE'}
        $missing=$false
        Set-Item Function:script:Invoke-SqlQuery -Value { @('PSR010_META|17|NONE|0|0|NONE','PSR010_COUNT|SERVER_LOGIN_MAPPING|0') }
        try{$null=Get-LabDatabaseMigrationDependencySqlObservation -Port 14330 -SaPlain 'ephemeral-test-value' -DatabaseName Evidence}catch{$missing=$_.Exception.Message -match 'COUNT_MISSING'}
        [PSCustomObject]@{Observation=$observation;Blocked=$blocked;Review=$review;Boundary=$boundary;Missing=$missing;Duplicate=$duplicate;Query=$script:capturedQuery}
    }
    Add-CheckResult 'Read-only SQL-Inventar erfasst Login-, Job-, Proxy-, Linked-Server- und TDE-Kategorien als Counts' (
        $result.Observation.ServerLoginMappingCount -eq 2 -and $result.Observation.SqlAgentJobCount -eq 1 -and
        $result.Observation.CredentialOrProxyCount -eq 1 -and $result.Observation.LinkedServerCount -eq 1)
    Add-CheckResult 'TDE ohne verifizierte Recovery-Evidence blockiert portable Migration fail-closed' (
        $result.Blocked.MigrationBoundary.PortableRestoreStatus -eq 'BLOCKED' -and
        'TDE_RECOVERY_EVIDENCE_REQUIRED' -in $result.Blocked.MigrationBoundary.Blockers)
    Add-CheckResult 'Verifizierte TDE-Evidence bleibt wegen separater Serverobjekte MANUAL_REVIEW' (
        $result.Review.MigrationBoundary.PortableRestoreStatus -eq 'MANUAL_REVIEW' -and
        -not $result.Review.MigrationBoundary.FullInstanceMigration -and -not $result.Review.MigrationBoundary.TdeKeyMaterialIncluded)
    Add-CheckResult 'Nicht SQL-seitig beweisbare Serverkonfiguration, SSISDB und SSAS bleiben sichtbar NOT_OBSERVABLE' (
        @($result.Review.Dependencies|Where-Object Status -eq 'NOT_OBSERVABLE').Count -eq 3)
    Add-CheckResult 'Artefaktgrenze weist DATABASE_FILES_ONLY und getrennte Abhängigkeiten aus' (
        $result.Boundary.ArtifactScope -eq 'DATABASE_FILES_ONLY' -and -not $result.Boundary.FullInstanceMigration -and
        'CUSTOM_EXTERNAL_RUNTIME' -in $result.Boundary.DependencyCategories -and 'SERVER_LOGIN_MAPPING' -in $result.Boundary.DependencyCategories)
    Add-CheckResult 'Unvollständige SQL-Count-Evidence wird abgelehnt' $result.Missing
    Add-CheckResult 'Doppelte oder fehlende Dependency-Kategorien werden semantisch abgelehnt' $result.Duplicate
    Add-CheckResult 'Inventar erfüllt das versionierte JSON-Schema' (
        ($result.Review|ConvertTo-Json -Depth 40)|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/database-migration-dependency-inventory.schema.json') -ErrorAction SilentlyContinue)
    $json=$result.Review|ConvertTo-Json -Depth 40
    Add-CheckResult 'Receipt enthält keine Zugangsdaten, Endpunkte, Objekt- oder Schlüsselnamen' (
        $json -notmatch 'ephemeral-test-value|14330|HostName|Password|CredentialValue|PrivateKey|CertificateName')
    Add-CheckResult 'SQL-Erhebung enthält ausschließlich read-only SELECT-Metadatenzugriffe' (
        $result.Query -match 'sys\.database_principals' -and $result.Query -match 'sys\.dm_database_encryption_keys' -and
        $result.Query -notmatch '(?im)^\s*(INSERT|UPDATE|DELETE|MERGE|BACKUP|RESTORE|CREATE|ALTER|DROP|EXEC(?:UTE)?)\b')
}
finally {Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue}

$failed=@($results|Where-Object{-not $_.Success})
if($failed.Count -gt 0){throw "DATABASE MIGRATION DEPENDENCY CHECKS FAILED: $($failed.Name -join '; ')"}
Write-Host "DATABASE MIGRATION DEPENDENCY CHECKS: PASS ($($results.Count))" -ForegroundColor Green
