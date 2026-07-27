<#
.SYNOPSIS
    Erstellt eine Datenbank auf einer Lab-Instanz.
.DESCRIPTION
    Generiert CREATE DATABASE T-SQL mit konfigurierbaren Data- und Log-Dateien,
    Collation sowie optionalen Query-Store- und Compatibility-Einstellungen.
    Ein pro Datei angegebenes Feld path wird als Containerpfad verwendet.
.EXAMPLE
    New-LabDatabase -Port 14330 -SaPassword $pw -DatabaseName 'TestDB' -DataFiles @(@{ name = 'D1'; path = '/sqldata/D1.mdf'; sizeMB = 200 })
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

    if ($DataFiles.Count -eq 0) {
        $DataFiles = @(
            @{
                name         = "${DatabaseName}_Data"
                sizeMB       = 64
                filegrowthMB = 64
            }
        )
    }

    if ($LogFiles.Count -eq 0) {
        $LogFiles = @(
            @{
                name         = "${DatabaseName}_Log"
                sizeMB       = 32
                filegrowthMB = 32
            }
        )
    }

    $escapedDatabaseName = $DatabaseName.Replace(']', ']]')
    $sql = "CREATE DATABASE [$escapedDatabaseName]`nON PRIMARY`n"

    for ($index = 0; $index -lt $DataFiles.Count; $index++) {
        $file = $DataFiles[$index]
        $name = $file.name ?? $file['name']
        $size = $file.sizeMB ?? $file['sizeMB'] ?? 64
        $growth = $file.filegrowthMB ?? $file['filegrowthMB'] ?? 64
        $configuredPath = $file.path ?? $file['path']
        $extension = if ($index -eq 0) { 'mdf' } else { 'ndf' }
        $path = if ($configuredPath) { $configuredPath } else { "/var/opt/mssql/data/${name}.${extension}" }
        $comma = if ($index -lt $DataFiles.Count - 1) { ',' } else { '' }

        $escapedName = ([string]$name).Replace("'", "''")
        $escapedPath = ([string]$path).Replace("'", "''")

        $sql += "  ( NAME = N'$escapedName',`n"
        $sql += "    FILENAME = N'$escapedPath',`n"
        $sql += "    SIZE = ${size}MB,`n"
        $sql += "    FILEGROWTH = ${growth}MB )$comma`n"
    }

    $sql += "LOG ON`n"

    for ($index = 0; $index -lt $LogFiles.Count; $index++) {
        $file = $LogFiles[$index]
        $name = $file.name ?? $file['name']
        $size = $file.sizeMB ?? $file['sizeMB'] ?? 32
        $growth = $file.filegrowthMB ?? $file['filegrowthMB'] ?? 32
        $configuredPath = $file.path ?? $file['path']
        $path = if ($configuredPath) { $configuredPath } else { "/var/opt/mssql/data/${name}.ldf" }
        $comma = if ($index -lt $LogFiles.Count - 1) { ',' } else { '' }

        $escapedName = ([string]$name).Replace("'", "''")
        $escapedPath = ([string]$path).Replace("'", "''")

        $sql += "  ( NAME = N'$escapedName',`n"
        $sql += "    FILENAME = N'$escapedPath',`n"
        $sql += "    SIZE = ${size}MB,`n"
        $sql += "    FILEGROWTH = ${growth}MB )$comma`n"
    }

    $sql += "COLLATE $Collation;`n"

    $alterStatements = @()
    if ($Options) {
        $queryStore = $Options.queryStore ?? $Options['queryStore']
        if ($queryStore -eq $true) {
            $alterStatements += "ALTER DATABASE [$escapedDatabaseName] SET QUERY_STORE = ON;"
        }

        $compatibilityLevel = $Options.compatibility ?? $Options['compatibility']
        if ($compatibilityLevel) {
            $alterStatements += "ALTER DATABASE [$escapedDatabaseName] SET COMPATIBILITY_LEVEL = $compatibilityLevel;"
        }
    }

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
    try {
        $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    try {
        Invoke-SqlQuery `
            -HostName $HostName `
            -Port $Port `
            -SaPlain $saPlain `
            -Query $sql `
            -TimeoutSeconds 60

        foreach ($alterStatement in $alterStatements) {
            Invoke-SqlQuery `
                -HostName $HostName `
                -Port $Port `
                -SaPlain $saPlain `
                -Query $alterStatement `
                -TimeoutSeconds 30
        }

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
        Write-LabError "Datenbank-Erstellung fehlgeschlagen: $_"
        throw
    }
    finally {
        $saPlain = $null
    }
}
