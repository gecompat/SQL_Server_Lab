<#
.SYNOPSIS
    Erstellt eine Datenbank auf einer Lab-Instanz.
.DESCRIPTION
    Generiert CREATE DATABASE T-SQL mit konfigurierbaren Data/Log Files,
    Filegroups, Collation und Optionen (Query Store, Compatibility Level).
.EXAMPLE
    New-LabDatabase -Port 14330 -SaPassword $pw -DatabaseName 'TestDB' -DataFiles @(@{name='D1';sizeMB=200})
#>
function New-LabDatabase {
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][string]$DatabaseName,
        [string]$Collation = 'SQL_Latin1_General_CP1_CS_AS',
        [array]$DataFiles = @(),
        [array]$LogFiles = @(),
        $Options = $null
    )

    # Defaults
    if ($DataFiles.Count -eq 0) {
        $DataFiles = @(@{ name = "${DatabaseName}_Data"; sizeMB = 64; filegrowthMB = 64 })
    }
    if ($LogFiles.Count -eq 0) {
        $LogFiles = @(@{ name = "${DatabaseName}_Log"; sizeMB = 32; filegrowthMB = 32 })
    }

    # CREATE DATABASE SQL generieren
    $sql = "CREATE DATABASE [$DatabaseName]`n"
    $sql += "  COLLATE $Collation`n"
    $sql += "ON PRIMARY`n"

    # Data Files
    for ($i = 0; $i -lt $DataFiles.Count; $i++) {
        $df = $DataFiles[$i]
        $name = $df.name ?? $df['name']
        $size = $df.sizeMB ?? $df['sizeMB'] ?? 64
        $growth = $df.filegrowthMB ?? $df['filegrowthMB'] ?? 64
        $comma = if ($i -lt $DataFiles.Count - 1) { ',' } else { '' }

        $sql += "  ( NAME = N'$name',`n"
        $sql += "    FILENAME = N'/var/opt/mssql/data/${name}.mdf',`n"
        $sql += "    SIZE = ${size}MB,`n"
        $sql += "    FILEGROWTH = ${growth}MB )$comma`n"
    }

    # Log Files
    $sql += "LOG ON`n"
    for ($i = 0; $i -lt $LogFiles.Count; $i++) {
        $lf = $LogFiles[$i]
        $name = $lf.name ?? $lf['name']
        $size = $lf.sizeMB ?? $lf['sizeMB'] ?? 32
        $growth = $lf.filegrowthMB ?? $lf['filegrowthMB'] ?? 32
        $comma = if ($i -lt $LogFiles.Count - 1) { ',' } else { '' }

        $sql += "  ( NAME = N'$name',`n"
        $sql += "    FILENAME = N'/var/opt/mssql/data/${name}.ldf',`n"
        $sql += "    SIZE = ${size}MB,`n"
        $sql += "    FILEGROWTH = ${growth}MB )$comma`n"
    }
    $sql += ";`n"

    # Optionen (ALTER DATABASE)
    $alterStatements = @()

    if ($Options) {
        $queryStore = $Options.queryStore ?? $Options['queryStore']
        if ($queryStore -eq $true) {
            $alterStatements += "ALTER DATABASE [$DatabaseName] SET QUERY_STORE = ON;"
        }

        $compat = $Options.compatibility ?? $Options['compatibility']
        if ($compat) {
            $alterStatements += "ALTER DATABASE [$DatabaseName] SET COMPATIBILITY_LEVEL = $compat;"
        }
    }

    # Zusammenbauen
    $fullSql = $sql
    if ($alterStatements.Count -gt 0) {
        $fullSql += "`nGO`n`n"
        $fullSql += $alterStatements -join "`n"
    }

    # Ausfuehren
    $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword))

    try {
        # CREATE DATABASE (darf kein GO enthalten)
        Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $saPlain -Query $sql -TimeoutSeconds 60

        # ALTER-Statements einzeln
        foreach ($alter in $alterStatements) {
            Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $saPlain -Query $alter -TimeoutSeconds 30
        }

        $saPlain = $null
        Write-LabSuccess "Datenbank erstellt: $DatabaseName ($($DataFiles.Count) Data, $($LogFiles.Count) Log Files)"

        return [PSCustomObject]@{
            Success      = $true
            DatabaseName = $DatabaseName
            DataFiles    = $DataFiles.Count
            LogFiles     = $LogFiles.Count
            Collation    = $Collation
        }
    }
    catch {
        $saPlain = $null
        Write-LabError "Datenbank-Erstellung fehlgeschlagen: $_"
        throw
    }
}
