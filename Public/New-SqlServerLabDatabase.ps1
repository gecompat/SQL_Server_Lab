<#
.SYNOPSIS
    Erstellt eine Datenbank auf einer Lab-Instanz.
.DESCRIPTION
    Erzeugt CREATE DATABASE T-SQL mit konfigurierbaren Data- und Log-Dateien,
    sicheren einfachen Bezeichnern, Collation und optionalen Basiseinstellungen.
    Das Feld path akzeptiert einen absoluten Linux-Containerpfad oder einen
    absoluten Windows-Laufwerkspfad. Dadurch kann derselbe CLI-Vertrag fuer
    Docker, Podman und direkt erreichbare Hyper-V-SQL-Instanzen verwendet werden.
.PARAMETER HostName
    Hostname oder IP-Adresse des SQL Servers. Standard ist 127.0.0.1.
.PARAMETER Port
    Host-Port der SQL-Server-Instanz.
.PARAMETER SaPassword
    SA-Passwort als SecureString.
.PARAMETER DatabaseName
    Name der neuen Datenbank. Erlaubt sind Buchstaben, Ziffern und Unterstriche;
    das erste Zeichen muss ein Buchstabe sein.
.PARAMETER Collation
    Collation der neuen Datenbank. Standard ist
    SQL_Latin1_General_CP1_CI_AS.
.PARAMETER DataFiles
    Array von Data-File-Definitionen mit name sowie optional path, sizeMB und
    filegrowthMB. Ohne Angabe wird eine Data-Datei erzeugt.
.PARAMETER LogFiles
    Array von Log-File-Definitionen mit name sowie optional path, sizeMB und
    filegrowthMB. Ohne Angabe wird eine Log-Datei erzeugt.
.PARAMETER Options
    Optionales Objekt mit Datenbankoptionen, die nach CREATE DATABASE
    angewendet werden.
.PARAMETER RunId
    Optionaler Run mit verifiziertem Storage-Bound-Plan. Data- und Logdateien
    werden dann vollständig und exakt aus dessen Runtime-Receipt aufgelöst.
.PARAMETER InstanceId
    Instanz-ID des Storage-Plans. Standard ist primary.
.PARAMETER StateRoot
    Optionaler State-Root für Bound Plan und Runtime-Receipt.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Liefert das Ergebnis der
    ausgefuehrten SQL-Batches.
.EXAMPLE
    New-SqlServerLabDatabase -Port 14330 -SaPassword $pw -DatabaseName 'TestDB'
#>
function New-SqlServerLabDatabase {
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][string]$DatabaseName,
        [string]$Collation = 'SQL_Latin1_General_CP1_CI_AS',
        [array]$DataFiles = @(),
        [array]$LogFiles = @(),
        $Options = $null,
        [string]$RunId,
        [string]$InstanceId = 'primary',
        [string]$StateRoot
    )

    if ($DatabaseName -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$') {
        throw "DatabaseName '$DatabaseName' ist fuer den aktuellen Labvertrag ungueltig. Erlaubt sind Buchstaben, Ziffern und Unterstrich; das erste Zeichen muss ein Buchstabe sein."
    }
    if ($Collation -notmatch '^[A-Za-z0-9_]+$') {
        throw "Collation '$Collation' enthaelt unzulaessige Zeichen."
    }
    if ($Port -lt 1 -or $Port -gt 65535) {
        throw "Port '$Port' liegt ausserhalb des gueltigen TCP-Portbereichs."
    }

    $isAbsoluteSqlPath = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        return $Path.StartsWith('/') -or $Path -match '^[A-Za-z]:\\[^<>:"|?*\r\n]+$'
    }

    if ($DataFiles.Count -eq 0) {
        $DataFiles = @(
            [PSCustomObject]@{
                name         = "${DatabaseName}_Data"
                path         = $null
                sizeMB       = 64
                filegrowthMB = 64
            }
        )
    }

    if ($LogFiles.Count -eq 0) {
        $LogFiles = @(
            [PSCustomObject]@{
                name         = "${DatabaseName}_Log"
                path         = $null
                sizeMB       = 32
                filegrowthMB = 32
            }
        )
    }

    $storageContext = $null
    $storageOperationId = $null
    if ($RunId) {
        $storageContext = Get-LabVerifiedStorageRuntimeContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $storageFiles = Resolve-LabStorageDatabaseFilePlan -Context $storageContext -DatabaseName $DatabaseName `
            -DataFiles @($DataFiles) -LogFiles @($LogFiles)
        $DataFiles = @($storageFiles.DataFiles)
        $LogFiles = @($storageFiles.LogFiles)
        $storageOperationId = "create:$DatabaseName"
    }

    $sql = "CREATE DATABASE [$DatabaseName]`nON PRIMARY`n"

    for ($index = 0; $index -lt $DataFiles.Count; $index++) {
        $file = $DataFiles[$index]
        $name = [string]$file.name
        $size = if ($null -ne $file.sizeMB) { [int]$file.sizeMB } else { 64 }
        $growth = if ($null -ne $file.filegrowthMB) { [int]$file.filegrowthMB } else { 64 }
        $configuredPath = [string]$file.path

        if ($name -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$') {
            throw "Data-File-Name '$name' ist ungueltig."
        }
        if ($size -le 0 -or $growth -le 0) {
            throw "Data-File '$name' benoetigt positive Werte fuer sizeMB und filegrowthMB."
        }
        if ($configuredPath -and -not (& $isAbsoluteSqlPath $configuredPath)) {
            throw "Data-File-Pfad '$configuredPath' muss ein absoluter Linux- oder Windows-SQL-Pfad sein."
        }

        $extension = if ($index -eq 0) { 'mdf' } else { 'ndf' }
        $path = if ($configuredPath) { $configuredPath } else { "/var/opt/mssql/data/${name}.${extension}" }
        $comma = if ($index -lt $DataFiles.Count - 1) { ',' } else { '' }
        $escapedPath = $path.Replace("'", "''")

        $sql += "  ( NAME = N'$name',`n"
        $sql += "    FILENAME = N'$escapedPath',`n"
        $sql += "    SIZE = ${size}MB,`n"
        $sql += "    FILEGROWTH = ${growth}MB )$comma`n"
    }

    $sql += "LOG ON`n"

    for ($index = 0; $index -lt $LogFiles.Count; $index++) {
        $file = $LogFiles[$index]
        $name = [string]$file.name
        $size = if ($null -ne $file.sizeMB) { [int]$file.sizeMB } else { 32 }
        $growth = if ($null -ne $file.filegrowthMB) { [int]$file.filegrowthMB } else { 32 }
        $configuredPath = [string]$file.path

        if ($name -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$') {
            throw "Log-File-Name '$name' ist ungueltig."
        }
        if ($size -le 0 -or $growth -le 0) {
            throw "Log-File '$name' benoetigt positive Werte fuer sizeMB und filegrowthMB."
        }
        if ($configuredPath -and -not (& $isAbsoluteSqlPath $configuredPath)) {
            throw "Log-File-Pfad '$configuredPath' muss ein absoluter Linux- oder Windows-SQL-Pfad sein."
        }

        $path = if ($configuredPath) { $configuredPath } else { "/var/opt/mssql/data/${name}.ldf" }
        $comma = if ($index -lt $LogFiles.Count - 1) { ',' } else { '' }
        $escapedPath = $path.Replace("'", "''")

        $sql += "  ( NAME = N'$name',`n"
        $sql += "    FILENAME = N'$escapedPath',`n"
        $sql += "    SIZE = ${size}MB,`n"
        $sql += "    FILEGROWTH = ${growth}MB )$comma`n"
    }

    $sql += "COLLATE $Collation;`n"

    $alterStatements = @()
    if ($Options) {
        if ($Options.queryStore -eq $true) {
            $alterStatements += "ALTER DATABASE [$DatabaseName] SET QUERY_STORE = ON;"
        }
        if ($Options.compatibility) {
            $compatibilityLevel = [int]$Options.compatibility
            if ($compatibilityLevel -notin @(150, 160, 170)) {
                throw "Compatibility Level '$compatibilityLevel' wird vom aktuellen Labvertrag nicht unterstuetzt."
            }
            $alterStatements += "ALTER DATABASE [$DatabaseName] SET COMPATIBILITY_LEVEL = $compatibilityLevel;"
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
        if ($storageContext) {
            $storageContext = Start-LabStorageSqlOperation -Context $storageContext -OperationId $storageOperationId `
                -Kind create -DatabaseName $DatabaseName
        }
        $null = Invoke-SqlQuery `
            -HostName $HostName `
            -Port $Port `
            -SaPlain $saPlain `
            -Query $sql `
            -TimeoutSeconds 60

        foreach ($alterStatement in $alterStatements) {
            $null = Invoke-SqlQuery `
                -HostName $HostName `
                -Port $Port `
                -SaPlain $saPlain `
                -Query $alterStatement `
                -TimeoutSeconds 30
        }

        if ($storageContext) {
            $verificationQuery = New-LabStorageMasterFilesVerificationQuery -DatabaseName $DatabaseName `
                -FilePlan @($DataFiles + $LogFiles)
            $null = Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $saPlain `
                -Query $verificationQuery -TimeoutSeconds 60
            $null = Complete-LabStorageSqlOperation -Context $storageContext -OperationId $storageOperationId `
                -Kind create -DatabaseName $DatabaseName -Files @($DataFiles + $LogFiles)
        }

        Write-LabSuccess "Datenbank erstellt: $DatabaseName ($($DataFiles.Count) Data, $($LogFiles.Count) Log Files)"

        return [PSCustomObject]@{
            Success      = $true
            DatabaseName = $DatabaseName
            DataFiles    = $DataFiles.Count
            LogFiles     = $LogFiles.Count
            Collation    = $Collation
            StoragePlanId = if ($storageContext) { [string]$storageContext.Plan.PlanId } else { $null }
        }
    }
    catch {
        if ($storageContext -and $storageOperationId) {
            $null = Fail-LabStorageSqlOperation -Context $storageContext -OperationId $storageOperationId -ErrorMessage $_.Exception.Message
        }
        Write-LabError "Datenbank-Erstellung fehlgeschlagen: $($_.Exception.Message)"
        throw
    }
    finally {
        $saPlain = $null
    }
}
