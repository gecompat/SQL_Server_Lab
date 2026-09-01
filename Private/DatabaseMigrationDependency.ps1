<#
.SYNOPSIS
    Inventarisiert SQL-seitig beobachtbare Migrationsabhaengigkeiten read-only.
.DESCRIPTION
    Der Vertrag trennt Datenbankartefakte von Instanzzustand, Serverobjekten,
    TDE-Keymaterial und externen Services. Persistiert werden nur Kategorien
    und Counts; Objekt-/Hostnamen, Credential-Werte und Schluesselmaterial
    bleiben ausserhalb des Receipts.
#>

function Get-LabDatabaseMigrationDependencySqlObservation {
    [CmdletBinding()]
    param(
        [string]$HostName='127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$SaPlain,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$DatabaseName
    )

    $literal=$DatabaseName.Replace("'","''")
    $identifier=$DatabaseName.Replace(']',']]')
    $query=@"
SET NOCOUNT ON;
IF DB_ID(N'$literal') IS NULL THROW 51000, 'MIGRATION_DEPENDENCY_DATABASE_NOT_FOUND', 1;
SELECT CONCAT(
    N'PSR010_META|', CONVERT(nvarchar(10),SERVERPROPERTY('ProductMajorVersion')), N'|',
    d.containment_desc COLLATE DATABASE_DEFAULT, N'|', CONVERT(nvarchar(1),d.is_encrypted), N'|',
    CONVERT(nvarchar(10),COALESCE(dek.encryption_state,0)), N'|',
    COALESCE(REPLACE(dek.encryptor_type COLLATE DATABASE_DEFAULT,N' ',N'_'),N'NONE'))
FROM sys.databases d
OUTER APPLY (
    SELECT TOP (1) encryption_state, encryptor_type
    FROM sys.dm_database_encryption_keys
    WHERE database_id=d.database_id
    ORDER BY database_id
) dek
WHERE d.database_id=DB_ID(N'$literal');

USE [$identifier];
SELECT CONCAT(N'PSR010_COUNT|SERVER_LOGIN_MAPPING|',CONVERT(nvarchar(20),COUNT_BIG(*)))
FROM sys.database_principals dp
JOIN master.sys.server_principals sp ON sp.sid=dp.sid
WHERE dp.principal_id > 4 AND dp.authentication_type IN (1,3) AND dp.type IN ('S','U','G');

SELECT CONCAT(N'PSR010_COUNT|SQL_AGENT_JOB|',CONVERT(nvarchar(20),COUNT_BIG(DISTINCT js.job_id)))
FROM msdb.dbo.sysjobsteps js
WHERE js.database_name=N'$literal';

SELECT CONCAT(N'PSR010_COUNT|CREDENTIAL_OR_PROXY|',CONVERT(nvarchar(20),COUNT_BIG(DISTINCT js.proxy_id)))
FROM msdb.dbo.sysjobsteps js
WHERE js.database_name=N'$literal' AND js.proxy_id > 0;

SELECT CONCAT(N'PSR010_COUNT|LINKED_SERVER|',CONVERT(nvarchar(20),COUNT_BIG(*)))
FROM master.sys.servers
WHERE is_linked=1;
"@
    $output=@(Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $SaPlain -Database master -Query $query)
    $lines=@($output|ForEach-Object{([string]$_).Trim()}|Where-Object{$_ -match '^PSR010_(META|COUNT)\|'})
    $meta=@($lines|Where-Object{$_ -match '^PSR010_META\|'})
    if($meta.Count -ne 1){throw 'MIGRATION_DEPENDENCY_METADATA_RESULT_INVALID'}
    $parts=$meta[0].Split('|')
    if($parts.Count -ne 6 -or $parts[1] -notmatch '^\d+$' -or $parts[3] -notmatch '^[01]$' -or $parts[4] -notmatch '^\d+$'){
        throw 'MIGRATION_DEPENDENCY_METADATA_RESULT_INVALID'
    }
    $counts=@{}
    foreach($line in @($lines|Where-Object{$_ -match '^PSR010_COUNT\|'})){
        $countParts=$line.Split('|')
        if($countParts.Count -ne 3 -or $countParts[2] -notmatch '^\d+$' -or $counts.ContainsKey($countParts[1])){
            throw 'MIGRATION_DEPENDENCY_COUNT_RESULT_INVALID'
        }
        $counts[$countParts[1]]=[long]$countParts[2]
    }
    foreach($category in @('SERVER_LOGIN_MAPPING','SQL_AGENT_JOB','CREDENTIAL_OR_PROXY','LINKED_SERVER')){
        if(-not $counts.ContainsKey($category)){throw "MIGRATION_DEPENDENCY_COUNT_MISSING: $category"}
    }
    [PSCustomObject][ordered]@{
        SqlMajorVersion=[string]$parts[1]
        Containment=[string]$parts[2]
        IsEncrypted=[int]$parts[3] -eq 1
        EncryptionState=[int]$parts[4]
        EncryptorType=[string]$parts[5]
        ServerLoginMappingCount=[long]$counts.SERVER_LOGIN_MAPPING
        SqlAgentJobCount=[long]$counts.SQL_AGENT_JOB
        CredentialOrProxyCount=[long]$counts.CREDENTIAL_OR_PROXY
        LinkedServerCount=[long]$counts.LINKED_SERVER
    }
}

function New-LabDatabaseMigrationDependencyEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][ValidateSet('DETECTED','NOT_DETECTED','NOT_OBSERVABLE')][string]$Status,
        [AllowNull()][Nullable[long]]$Count,
        [Parameter(Mandatory)][ValidateSet('DATABASE_BOUND','INSTANCE_WIDE','EXTERNAL')][string]$Scope,
        [Parameter(Mandatory)][string]$RequiredAction
    )
    [PSCustomObject][ordered]@{
        Category=$Category;Status=$Status;Count=if($null -eq $Count){$null}else{[long]$Count}
        Scope=$Scope;RequiredAction=$RequiredAction;IncludedInDatabaseArtifact=$false
    }
}

function Test-LabDatabaseMigrationDependencyInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inventory)
    try{$valid=$Inventory|ConvertTo-Json -Depth 40|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'database-migration-dependency-inventory.schema.json') -ErrorAction Stop}catch{throw "MIGRATION_DEPENDENCY_INVENTORY_SCHEMA_INVALID: $($_.Exception.Message)"}
    if(-not $valid){throw 'MIGRATION_DEPENDENCY_INVENTORY_SCHEMA_INVALID'}
    $expected=@('SERVER_LOGIN_MAPPING','SQL_AGENT_JOB','CREDENTIAL_OR_PROXY','LINKED_SERVER','SERVER_CONFIGURATION','TDE_PROTECTOR','SSISDB','SSAS')
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($dependency in @($Inventory.Dependencies)){
        $category=[string]$dependency.Category
        if(-not $seen.Add($category)){throw "MIGRATION_DEPENDENCY_CATEGORY_DUPLICATE: $category"}
        switch([string]$dependency.Status){
            'DETECTED' {if($null -eq $dependency.Count -or [long]$dependency.Count -lt 1){throw "MIGRATION_DEPENDENCY_COUNT_STATUS_MISMATCH: $category"}}
            'NOT_DETECTED' {if($null -eq $dependency.Count -or [long]$dependency.Count -ne 0){throw "MIGRATION_DEPENDENCY_COUNT_STATUS_MISMATCH: $category"}}
            'NOT_OBSERVABLE' {if($null -ne $dependency.Count){throw "MIGRATION_DEPENDENCY_COUNT_STATUS_MISMATCH: $category"}}
        }
    }
    foreach($category in $expected){if(-not $seen.Contains($category)){throw "MIGRATION_DEPENDENCY_CATEGORY_MISSING: $category"}}
    return $true
}

function New-LabDatabaseMigrationDependencyInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$DatabaseName,
        [Parameter(Mandatory)][ValidateSet('docker','podman','hyperv','external')][string]$Provider,
        [string]$RunId,[string]$InstanceId,
        [Parameter(Mandatory)]$Observation,
        [bool]$TdeRecoveryEvidenceVerified=$false
    )

    foreach($property in @('SqlMajorVersion','Containment','IsEncrypted','EncryptionState','EncryptorType','ServerLoginMappingCount','SqlAgentJobCount','CredentialOrProxyCount','LinkedServerCount')){
        if(-not $Observation.PSObject.Properties[$property]){throw "MIGRATION_DEPENDENCY_OBSERVATION_INCOMPLETE: $property"}
    }
    foreach($property in @('ServerLoginMappingCount','SqlAgentJobCount','CredentialOrProxyCount','LinkedServerCount')){
        if([long]$Observation.$property -lt 0){throw "MIGRATION_DEPENDENCY_COUNT_INVALID: $property"}
    }
    $containment=([string]$Observation.Containment).ToUpperInvariant()
    if($containment -notin @('NONE','PARTIAL','CONTAINED','UNKNOWN')){$containment='UNKNOWN'}
    $encryptor=([string]$Observation.EncryptorType).ToUpperInvariant().Replace(' ','_')
    if($encryptor -notin @('NONE','CERTIFICATE','ASYMMETRIC_KEY','UNKNOWN')){$encryptor='UNKNOWN'}
    $encryptionState=switch([int]$Observation.EncryptionState){
        0{'NOT_ENCRYPTED'};1{'UNENCRYPTED'};2{'ENCRYPTION_IN_PROGRESS'};3{'ENCRYPTED'}
        4{'KEY_CHANGE_IN_PROGRESS'};5{'DECRYPTION_IN_PROGRESS'};6{'PROTECTION_CHANGE_IN_PROGRESS'};default{'UNKNOWN'}
    }
    if(-not [bool]$Observation.IsEncrypted){$encryptionState='NOT_ENCRYPTED';$encryptor='NONE'}
    $dependencies=[Collections.Generic.List[object]]::new()
    $definitions=@(
        @{Category='SERVER_LOGIN_MAPPING';Count=[long]$Observation.ServerLoginMappingCount;Scope='DATABASE_BOUND';Action='SCRIPT_AND_REMAP'},
        @{Category='SQL_AGENT_JOB';Count=[long]$Observation.SqlAgentJobCount;Scope='DATABASE_BOUND';Action='SCRIPT_OR_RECREATE'},
        @{Category='CREDENTIAL_OR_PROXY';Count=[long]$Observation.CredentialOrProxyCount;Scope='INSTANCE_WIDE';Action='VERIFY_AND_RECREATE'},
        @{Category='LINKED_SERVER';Count=[long]$Observation.LinkedServerCount;Scope='INSTANCE_WIDE';Action='VERIFY_AND_RECREATE'}
    )
    foreach($definition in $definitions){
        $status=if([long]$definition.Count -gt 0){'DETECTED'}else{'NOT_DETECTED'}
        $dependencies.Add((New-LabDatabaseMigrationDependencyEntry -Category $definition.Category -Status $status -Count ([long]$definition.Count) -Scope $definition.Scope -RequiredAction $definition.Action))
    }
    $tdeCount=if([bool]$Observation.IsEncrypted -and $encryptor -in @('CERTIFICATE','ASYMMETRIC_KEY')){1}else{0}
    $dependencies.Add((New-LabDatabaseMigrationDependencyEntry -Category 'TDE_PROTECTOR' -Status $(if($tdeCount -eq 1){'DETECTED'}else{'NOT_DETECTED'}) -Count $tdeCount -Scope 'INSTANCE_WIDE' -RequiredAction 'PROVIDE_TDE_RECOVERY_EVIDENCE'))
    foreach($external in @(
        @{Category='SERVER_CONFIGURATION';Scope='INSTANCE_WIDE';Action='MANUAL_REVIEW'},
        @{Category='SSISDB';Scope='EXTERNAL';Action='EXPORT_SEPARATELY'},
        @{Category='SSAS';Scope='EXTERNAL';Action='EXPORT_SEPARATELY'}
    )){
        $dependencies.Add((New-LabDatabaseMigrationDependencyEntry -Category $external.Category -Status 'NOT_OBSERVABLE' -Count $null -Scope $external.Scope -RequiredAction $external.Action))
    }
    $blockers=[Collections.Generic.List[string]]::new()
    if([bool]$Observation.IsEncrypted -and $tdeCount -eq 0){$blockers.Add('TDE_PROTECTOR_NOT_RESOLVED')}
    if([bool]$Observation.IsEncrypted -and -not $TdeRecoveryEvidenceVerified){$blockers.Add('TDE_RECOVERY_EVIDENCE_REQUIRED')}
    $warnings=[Collections.Generic.List[string]]::new()
    foreach($warning in @('DATABASE_ARTIFACT_EXCLUDES_INSTANCE_STATE','SERVER_CONFIGURATION_REVIEW_REQUIRED','EXTERNAL_SERVICE_REVIEW_REQUIRED','SECRET_VALUES_NOT_CAPTURED')){$warnings.Add($warning)}
    foreach($dependency in @($dependencies|Where-Object Status -eq 'DETECTED')){$warnings.Add("$($dependency.Category)_REQUIRES_SEPARATE_HANDLING")}
    $inventory=[PSCustomObject][ordered]@{
        ContractVersion='SqlServerLab.DatabaseMigrationDependencyInventory/1.0'
        DatabaseName=$DatabaseName
        Source=[PSCustomObject][ordered]@{Provider=$Provider;RunId=if($RunId){$RunId}else{$null};InstanceId=if($InstanceId){$InstanceId}else{$null};SqlMajorVersion=[string]$Observation.SqlMajorVersion}
        ObservationStatus='SQL_ENGINE_COMPLETE_EXTERNAL_REVIEW_REQUIRED'
        Database=[PSCustomObject][ordered]@{Containment=$containment;IsEncrypted=[bool]$Observation.IsEncrypted;EncryptionState=$encryptionState;EncryptorType=$encryptor;TdeRecoveryEvidenceVerified=$TdeRecoveryEvidenceVerified}
        Dependencies=@($dependencies)
        MigrationBoundary=[PSCustomObject][ordered]@{
            ArtifactScope='DATABASE_ONLY';FullInstanceMigration=$false;ServerObjectsIncluded=$false
            TdeKeyMaterialIncluded=$false;SecretValuesIncluded=$false;ExternalServicesIncluded=$false
            PortableRestoreStatus=if($blockers.Count -gt 0){'BLOCKED'}else{'MANUAL_REVIEW'}
            Blockers=@($blockers|Sort-Object -Unique);Warnings=@($warnings|Sort-Object -Unique)
        }
        ObservedAt=Get-LabTimestamp
    }
    $null=Test-LabDatabaseMigrationDependencyInventory -Inventory $inventory
    return $inventory
}

function Get-LabDatabaseMigrationDependencyInventory {
    [CmdletBinding()]
    param(
        [string]$HostName='127.0.0.1',[Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$DatabaseName,
        [Parameter(Mandatory)][ValidateSet('docker','podman','hyperv','external')][string]$Provider,
        [string]$RunId,[string]$InstanceId,[bool]$TdeRecoveryEvidenceVerified=$false
    )
    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
    try{$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
    try{
        $observation=Get-LabDatabaseMigrationDependencySqlObservation -HostName $HostName -Port $Port -SaPlain $plain -DatabaseName $DatabaseName
        New-LabDatabaseMigrationDependencyInventory -DatabaseName $DatabaseName -Provider $Provider -RunId $RunId -InstanceId $InstanceId -Observation $observation -TdeRecoveryEvidenceVerified:$TdeRecoveryEvidenceVerified
    } finally {$plain=$null}
}

function Get-LabDatabaseArtifactMigrationBoundary {
    [CmdletBinding()]
    param([AllowNull()]$DependencyInventory,[string[]]$ExternalDependencies=@())
    $categories=[Collections.Generic.List[string]]::new()
    $warnings=[Collections.Generic.List[string]]::new()
    foreach($warning in @('SERVER_OBJECTS_NOT_INCLUDED','TDE_KEY_MATERIAL_NOT_INCLUDED','SECRET_VALUES_NOT_INCLUDED','EXTERNAL_SERVICE_CONFIGURATION_NOT_INCLUDED')){$warnings.Add($warning)}
    $status='NOT_EXECUTED'
    if($DependencyInventory){
        if([string]$DependencyInventory.ContractVersion -ne 'SqlServerLab.DatabaseMigrationDependencyInventory/1.0'){throw 'MIGRATION_DEPENDENCY_INVENTORY_CONTRACT_INVALID'}
        $null=Test-LabDatabaseMigrationDependencyInventory -Inventory $DependencyInventory
        $status=[string]$DependencyInventory.ObservationStatus
        foreach($dependency in @($DependencyInventory.Dependencies|Where-Object Status -in @('DETECTED','NOT_OBSERVABLE'))){$categories.Add([string]$dependency.Category)}
        foreach($warning in @($DependencyInventory.MigrationBoundary.Warnings)){$warnings.Add([string]$warning)}
    } else {$warnings.Add('DEPENDENCY_INVENTORY_NOT_EXECUTED')}
    foreach($dependency in @($ExternalDependencies|Where-Object{$_})){
        $category=([string]$dependency).ToUpperInvariant()
        if($category -notmatch '^[A-Z0-9_]+$'){throw "MIGRATION_DEPENDENCY_CATEGORY_INVALID: $dependency"}
        $categories.Add($category)
    }
    [PSCustomObject][ordered]@{
        DependencyInventoryStatus=$status;ArtifactScope='DATABASE_FILES_ONLY';FullInstanceMigration=$false
        ServerObjectsIncluded=$false;TdeKeyMaterialIncluded=$false;SecretValuesIncluded=$false;ExternalServicesIncluded=$false
        DependencyCategories=@($categories|Sort-Object -Unique);Warnings=@($warnings|Sort-Object -Unique)
    }
}
