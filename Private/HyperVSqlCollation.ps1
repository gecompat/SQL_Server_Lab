function Resolve-LabHyperVSqlCollationSelection {
    <# .SYNOPSIS Bindet eine ausdrueckliche oder run-lokal gespeicherte Auswahl an das Prepared-Artifact. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lab, [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters)

    $stored = $Lab.Instance.PSObject.Properties['sqlCollationIntent']
    $selected = $Parameters.Keys -contains 'Collation'
    if (-not $stored -and -not $selected) { return $null }
    $artifact = Get-HyperVImageArtifact -ArtifactId ([string]$Lab.Instance.imageArtifactId) -StateRoot $Lab.StateRoot
    if (-not $artifact -or [string]$artifact.artifactState -cne 'SQL_PREPARED_SEALED' -or
        [string]$Lab.Instance.workload -ceq 'windows') { throw 'HYPERV_SQL_COLLATION_PREPARED_REQUIRED' }
    $savedName = $null
    if ($stored) {
        if ($stored.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($stored.Value)) { throw 'HYPERV_SQL_COLLATION_INTENT_INVALID' }
        $savedName = Resolve-LabSqlServerCollation -Name $stored.Value -SqlVersion ([string]$artifact.sql.version)
    }
    if ($selected) {
        if ($Parameters['Collation'] -isnot [string] -or [string]::IsNullOrWhiteSpace($Parameters['Collation'])) { throw 'HYPERV_SQL_COLLATION_INTENT_INVALID' }
        $name = Resolve-LabSqlServerCollation -Name $Parameters['Collation'] -SqlVersion ([string]$artifact.sql.version)
        if ($savedName -and $name -cne $savedName) { throw 'HYPERV_SQL_COLLATION_INTENT_CONFLICT' }
        return $name
    }
    return $savedName
}

function Test-LabHyperVSqlCollationRuntimeEvidence {
    <#
    .SYNOPSIS Prueft die ausgewaehlte Collation im gebundenen Windows-Gast.
    .DESCRIPTION Eine parametrisierte read-only Abfrage mit Windows-Anmeldung
    verifiziert Katalog, SQL-Identitaet, Server, master und tempdb. Keine
    Reparatur, kein Kennwortexport und kein erfolgreicher Ersatz fuer fehlende Evidence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Lab,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][string]$Collation,
        [Parameter(Mandatory)][string]$SqlVersion,
        [ValidateRange(1,65535)][int]$SqlPort = 1433,
        [string]$FallbackAddress,
        [guid]$ExpectedVmId
    )
    $expected = Resolve-LabSqlServerCollation -Name $Collation -SqlVersion $SqlVersion
    $major = Get-HyperVSqlMajorVersionFromVersion -SqlVersion $SqlVersion
    $binding = @{}
    if ($PSBoundParameters.ContainsKey('ExpectedVmId')) {
        $binding.ExpectedVmId = $ExpectedVmId
        $null = Assert-HyperVLabSqlVmBinding -Lab $Lab @binding
    }
    try {
        $rows = @(Invoke-HyperVPowerShellDirect -VMName ([string]$Lab.Instance.vmName) `
            -ExpectedRunId ([string]$Lab.Run.runId) -ExpectedScopeId ([string]$Lab.Run.scopeId) -Credential $Credential -NoRetry -FallbackAddress $FallbackAddress @binding `
            -ArgumentList @([string]$Lab.Run.runId, [string]$Lab.Run.scopeId, $expected, $SqlPort) -ScriptBlock {
                param($RunId, $ScopeId, $ExpectedCollation, $Port)
                $connection = $null; $command = $null; $reader = $null
                try {
                    $connection = New-Object System.Data.SqlClient.SqlConnection -ArgumentList (,"Server=localhost,$Port;Initial Catalog=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connect Timeout=15;Pooling=False;Application Name=SqlServerLab.HyperVCollationEvidence")
                    $connection.Open()
                    $command = $connection.CreateCommand()
                    $command.CommandTimeout = 15
                    $command.CommandText = @'
SET NOCOUNT ON;
SELECT
    CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.fn_helpcollations() WHERE name = @collation) THEN 1 ELSE 0 END AS bit) AS CatalogAvailable,
    CONVERT(nvarchar(128), SERVERPROPERTY(N'Collation')) AS ServerCollation,
    CONVERT(nvarchar(128), DATABASEPROPERTYEX(N'master', N'Collation')) AS MasterCollation,
    CONVERT(nvarchar(128), DATABASEPROPERTYEX(N'tempdb', N'Collation')) AS TempdbCollation,
    CONVERT(int, PARSENAME(CONVERT(varchar(128), SERVERPROPERTY(N'ProductVersion')), 4)) AS MajorVersion,
    COALESCE(CONVERT(nvarchar(128), SERVERPROPERTY(N'InstanceName')), N'MSSQLSERVER') AS InstanceName;
'@
                    $null = $command.Parameters.Add('@collation', [System.Data.SqlDbType]::NVarChar, 128)
                    $command.Parameters['@collation'].Value = $ExpectedCollation
                    $reader = $command.ExecuteReader()
                    if (-not $reader.Read()) { throw 'EMPTY' }
                    [PSCustomObject]@{
                        RunId=$RunId; ScopeId=$ScopeId; CatalogAvailable=$reader['CatalogAvailable']
                        ServerCollation=$reader['ServerCollation']; MasterCollation=$reader['MasterCollation']; TempdbCollation=$reader['TempdbCollation']
                        MajorVersion=$reader['MajorVersion']; InstanceName=$reader['InstanceName']; ObservedAt=[datetime]::UtcNow.ToString('o')
                    }
                }
                finally {
                    if ($reader) { $reader.Dispose() }
                    if ($command) { $command.Dispose() }
                    if ($connection) { $connection.Dispose() }
                }
            })
    }
    catch { throw 'HYPERV_SQL_COLLATION_QUERY_FAILED' }
    if ($binding.Count) { $null = Assert-HyperVLabSqlVmBinding -Lab $Lab @binding }
    if ($rows.Count -ne 1) { throw 'HYPERV_SQL_COLLATION_RECEIPT_INVALID' }
    $receipt = $rows[0]
    if ([string]$receipt.RunId -cne [string]$Lab.Run.runId -or [string]$receipt.ScopeId -cne [string]$Lab.Run.scopeId -or
        [string]$receipt.InstanceName -cne 'MSSQLSERVER' -or [string]$receipt.MajorVersion -cne [string]$major -or
        $receipt.CatalogAvailable -isnot [bool] -or [string]::IsNullOrWhiteSpace([string]$receipt.ObservedAt)) {
        throw 'HYPERV_SQL_COLLATION_RECEIPT_INVALID'
    }
    if (-not $receipt.CatalogAvailable) { throw 'HYPERV_SQL_COLLATION_CATALOG_UNAVAILABLE' }
    foreach ($field in @('ServerCollation','MasterCollation','TempdbCollation')) {
        $property = $receipt.PSObject.Properties[$field]
        if (-not $property -or $property.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace($property.Value) -or $property.Value -notmatch '^[A-Za-z0-9_]{1,128}$') {
            throw 'HYPERV_SQL_COLLATION_RECEIPT_INVALID'
        }
    }
    foreach ($field in @('ServerCollation','MasterCollation','TempdbCollation')) {
        if (-not [string]::Equals([string]$receipt.$field, $expected, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'HYPERV_SQL_COLLATION_POSTCONDITION_FAILED'
        }
    }
    return [PSCustomObject]@{
        Status='VERIFIED'; Provider='hyperv'; SqlVersion=(Get-SqlServerVersion -VersionId $SqlVersion).id
        RunId=[string]$Lab.Run.runId; ScopeId=[string]$Lab.Run.scopeId; InstanceId=[string]$Lab.Instance.id
        ExpectedCollation=$expected; ActualCollation=[string]$receipt.ServerCollation
        MasterCollation=[string]$receipt.MasterCollation; TempdbCollation=[string]$receipt.TempdbCollation
        CatalogAvailable=$true; ObservedAt=[string]$receipt.ObservedAt
    }
}
