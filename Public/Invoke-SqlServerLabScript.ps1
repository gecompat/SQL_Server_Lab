<#
.SYNOPSIS
    Fuehrt ein T-SQL-Skript gegen eine Lab-Instanz aus.
.DESCRIPTION
    Public Wrapper um Invoke-LabSqlScript. Unterstuetzt Pfad oder RunId-basierte
    Instanz-Aufloesung. GO-Batches werden korrekt getrennt.
    -WindowsAuthentication verwendet fuer einen gebundenen laufenden Hyper-V-
    Windows-SQL-Run den vorhandenen PowerShell-Direct-Transport und die intern
    geschuetzte Gastanmeldung. Es werden keine Kennwoerter zurueckgegeben.
.PARAMETER ScriptPath
    Pfad zu einer vorhandenen lokalen T-SQL-Datei.
.PARAMETER HostName
    Hostname oder IP-Adresse im direkten Verbindungsmodus. Standard ist
    127.0.0.1.
.PARAMETER Port
    Host-Port der SQL-Server-Instanz im direkten Verbindungsmodus.
.PARAMETER SaPassword
    SA-Passwort als SecureString.
.PARAMETER Database
    Zieldatenbank fuer die Skriptausfuehrung. Standard ist master.
.PARAMETER RunId
    RunId einer gespeicherten Labumgebung. Host und Port werden aus deren
    connection-info.json gelesen.
.PARAMETER InstanceId
    Instanz-ID innerhalb des Runs. Standard ist primary.
.PARAMETER StateRoot
    Optionales State-Stammverzeichnis fuer die RunId-basierte Aufloesung.
.PARAMETER KeepConnection
    Fuehrt alle GO-Batches ueber dieselbe sqlcmd-Verbindung aus. Der Alias
    SingleConnection ist ebenfalls zulaessig.
.PARAMETER WindowsAuthentication
    SQL im Gast mit Windows-Authentifizierung ausfuehren. Kein Host-Login,
    kein SQL-Auth-Fallback und keine automatische Wiederholung nach Versand.
.PARAMETER Parameters
    Windows-Modus: benannte SQL-Parameter als Hashtable; string, int, long,
    bool, byte[] oder null. Insgesamt hoechstens 16 MiB, maximal 32 Parameter.
.PARAMETER TimeoutSeconds
    Windows-Modus: gesamter Gastaufruf, 5 bis 600 Sekunden. Standard 300.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Liefert Success, Message,
    Batches und Duration der Skriptausfuehrung.
    Im Windows-Modus zusaetzlich OperationId, Authentication, AuthScheme,
    Outcome, ErrorCode, SqlErrorNumber und begrenzte ResultSets mit Columns/Rows.
.EXAMPLE
    Invoke-SqlServerLabScript -ScriptPath './setup.sql' -Port 14330 -SaPassword $pw
.EXAMPLE
    Invoke-SqlServerLabScript -ScriptPath './setup.sql' -RunId $lab.RunId -SaPassword $pw
.EXAMPLE
    $result = Invoke-SqlServerLabScript -RunId $runId -InstanceId primary `
      -WindowsAuthentication -Database SSISDB -ScriptPath './own-deploy.sql' `
      -Parameters @{ project_stream = [IO.File]::ReadAllBytes($ispacPath) } -KeepConnection
#>
function Invoke-SqlServerLabScript {
    [CmdletBinding(DefaultParameterSetName = 'Direct', SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        # --- Direkte Verbindung ---
        [Parameter(ParameterSetName = 'Direct')]
        [string]$HostName = '127.0.0.1',

        [Parameter(ParameterSetName = 'Direct', Mandatory)]
        [int]$Port,

        [Parameter(ParameterSetName = 'Direct', Mandatory)]
        [Parameter(ParameterSetName = 'RunBased', Mandatory)]
        [SecureString]$SaPassword,

        [string]$Database = 'master',

        # --- RunId-basiert ---
        [Parameter(ParameterSetName = 'RunBased', Mandatory)]
        [Parameter(ParameterSetName = 'RunWindows', Mandatory)]
        [string]$RunId,

        [Parameter(ParameterSetName = 'RunBased')]
        [Parameter(ParameterSetName = 'RunWindows')]
        [string]$InstanceId = 'primary',

        [Parameter(ParameterSetName = 'RunBased')]
        [Parameter(ParameterSetName = 'RunWindows')]
        [string]$StateRoot,

        [Parameter(ParameterSetName = 'RunWindows', Mandatory)]
        [switch]$WindowsAuthentication,

        [Parameter(ParameterSetName = 'RunWindows')]
        [hashtable]$Parameters = @{},

        [Parameter(ParameterSetName = 'RunWindows')]
        [ValidateRange(5,600)][int]$TimeoutSeconds = 300,

        [Parameter()]
        [Alias('SingleConnection')]
        [switch]$KeepConnection
    )

    $ErrorActionPreference = 'Stop'

    if ($PSCmdlet.ParameterSetName -eq 'RunWindows') {
        if (-not $WindowsAuthentication) { throw 'WINDOWS_SQL_AUTHENTICATION_REQUIRED' }
        if (-not $PSCmdlet.ShouldProcess("$RunId/$InstanceId", 'SQL-Skript im gebundenen Gast mit Windows-Authentifizierung ausfuehren')) { return }
        if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
        return Invoke-LabWindowsSqlScript -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot `
            -ScriptPath $ScriptPath -Database $Database -Parameters $Parameters `
            -KeepConnection:$KeepConnection -TimeoutSeconds $TimeoutSeconds
    }

    # Instanz-Aufloesung bei RunId-Modus
    if ($PSCmdlet.ParameterSetName -eq 'RunBased') {
        if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
        $runDir = Join-Path $StateRoot 'runs' $RunId
        $connFile = Join-Path $runDir 'connection-info.json'

        if (-not (Test-Path $connFile)) {
            throw "Connection-Info nicht gefunden fuer Run: $RunId"
        }

        $connInfo = Get-Content $connFile -Raw | ConvertFrom-Json -Depth 10
        $instance = $connInfo.instances | Where-Object { $_.id -eq $InstanceId }

        if (-not $instance) {
            throw "Instanz '$InstanceId' nicht in Run '$RunId' gefunden."
        }

        $HostName = $instance.host
        $Port = $instance.port
    }

    # Skript ausfuehren
    if (-not (Test-Path $ScriptPath)) {
        throw "SQL-Skript nicht gefunden: $ScriptPath"
    }

    if (-not $PSCmdlet.ShouldProcess("$HostName`:$Port/$Database", 'SQL-Skript ausfuehren')) { return }
    Write-LabInfo "Skript ausfuehren: $(Split-Path $ScriptPath -Leaf) -> $HostName`:$Port/$Database"

    $scriptParams = @{
        ScriptPath = $ScriptPath
        HostName   = $HostName
        Port       = $Port
        SaPassword = $SaPassword
        Database   = $Database
    }
    if ($KeepConnection) { $scriptParams['KeepConnection'] = $true }

    $result = Invoke-LabSqlScript @scriptParams

    if ($result.Success) {
        Write-LabSuccess "$($result.Message) ($($result.Batches) Batches, $($result.Duration.TotalSeconds.ToString('F1'))s)"
    }
    else {
        Write-LabError $result.Message
    }

    return $result
}
