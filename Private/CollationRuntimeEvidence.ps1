function New-LabCollationRuntimeSqlConnection {
    <#
    .SYNOPSIS
        Erstellt eine kurzlebige, kennwortfreie SQL-Verbindung fuer den Collation-Nachweis.
    .DESCRIPTION
        Das Kennwort bleibt ausschliesslich in SqlCredential. Weder die
        Verbindungszeichenfolge noch Rueckgabewerte enthalten ein Kennwort.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$HostName,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword
    )

    if (-not $SaPassword.IsReadOnly()) { $SaPassword.MakeReadOnly() }
    $credential = [System.Data.SqlClient.SqlCredential]::new('sa', $SaPassword)
    $connection = [System.Data.SqlClient.SqlConnection]::new()
    $connection.ConnectionString = "Data Source=$HostName,$Port;Initial Catalog=master;Encrypt=True;TrustServerCertificate=True;Connect Timeout=15;Application Name=SqlServerLab.CollationRuntimeEvidence;Pooling=False;Persist Security Info=False"
    $connection.Credential = $credential
    return $connection
}

function Test-LabContainerSqlCollationRuntimeEvidence {
    <#
    .SYNOPSIS
        Prueft eine kataloggebundene Container-Instanzcollation nach SQL-Readiness.
    .DESCRIPTION
        Die Funktion ist providerneutral fuer Docker und Podman. Sie loest die
        erwartete Collation erneut aus dem bestehenden Katalog auf, fragt mit
        genau einer parametrisierten read-only SQL-Abfrage deren SQL-seitige
        Verfuegbarkeit sowie SERVERPROPERTY('Collation') ab und gibt nur
        sanitisierte Evidence zurueck. Jeder Fehler bleibt fail-closed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SqlVersion,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Collation,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$HostName,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword
    )

    try {
        $expectedCollation = Resolve-LabSqlServerCollation -Name $Collation -SqlVersion $SqlVersion
    }
    catch {
        throw 'SQL_COLLATION_RUNTIME_CATALOG_REJECTED'
    }

    $connection = $null
    $command = $null
    $reader = $null
    try {
        $connection = New-LabCollationRuntimeSqlConnection -HostName $HostName -Port $Port -SaPassword $SaPassword
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandTimeout = 15
        $command.CommandText = @'
SELECT
    CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.fn_helpcollations() WHERE name = @collation) THEN 1 ELSE 0 END AS bit) AS CatalogAvailable,
    CONVERT(nvarchar(128), SERVERPROPERTY(N'Collation')) AS ServerCollation;
'@
        $null = $command.Parameters.Add('@collation', [System.Data.SqlDbType]::NVarChar, 128)
        $command.Parameters['@collation'].Value = $expectedCollation
        $reader = $command.ExecuteReader()
        if (-not $reader.Read()) { throw 'SQL_COLLATION_RUNTIME_QUERY_EMPTY' }
        $catalogAvailable = $reader.GetBoolean(0)
        $actualCollation = if ($reader.IsDBNull(1)) { '' } else { [string]$reader.GetString(1) }
        if (-not $catalogAvailable) { throw 'SQL_COLLATION_RUNTIME_CATALOG_UNAVAILABLE' }
        if (-not [string]::Equals($actualCollation, $expectedCollation, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'SQL_COLLATION_RUNTIME_POSTCONDITION_FAILED'
        }
        return [PSCustomObject]@{
            Provider = $Provider
            SqlVersion = (Get-SqlServerVersion -VersionId $SqlVersion).id
            ExpectedCollation = $expectedCollation
            ActualCollation = $actualCollation
            CatalogAvailable = $catalogAvailable
            Status = 'VERIFIED'
        }
    }
    catch {
        $code = [string]$_.Exception.Message
        if ($code -match '^SQL_COLLATION_RUNTIME_(QUERY_EMPTY|CATALOG_UNAVAILABLE|POSTCONDITION_FAILED)$') { throw $code }
        throw 'SQL_COLLATION_RUNTIME_QUERY_FAILED'
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($command) { $command.Dispose() }
        if ($connection) { $connection.Dispose() }
    }
}
