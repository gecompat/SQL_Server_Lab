<#
.SYNOPSIS
    Fuehrt ein T-SQL-Skript gegen eine Lab-Instanz aus.
.DESCRIPTION
    Public Wrapper um Invoke-LabSqlScript. Unterstuetzt Pfad oder RunId-basierte
    Instanz-Aufloesung. GO-Batches werden korrekt getrennt.
.EXAMPLE
    Invoke-LabScript -ScriptPath './setup.sql' -Port 14330 -SaPassword $pw
.EXAMPLE
    Invoke-LabScript -ScriptPath './setup.sql' -RunId $lab.RunId -InstanceId 'primary'
#>
function Invoke-LabScript {
    [CmdletBinding(DefaultParameterSetName = 'Direct')]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        # --- Direkte Verbindung ---
        [Parameter(ParameterSetName = 'Direct')]
        [string]$HostName = '127.0.0.1',

        [Parameter(ParameterSetName = 'Direct', Mandatory)]
        [int]$Port,

        [Parameter(Mandatory)]
        [SecureString]$SaPassword,

        [string]$Database = 'master',

        # --- RunId-basiert ---
        [Parameter(ParameterSetName = 'RunBased', Mandatory)]
        [string]$RunId,

        [Parameter(ParameterSetName = 'RunBased')]
        [string]$InstanceId = 'primary',

        [Parameter(ParameterSetName = 'RunBased')]
        [string]$StateRoot
    )

    $ErrorActionPreference = 'Stop'

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

    Write-LabInfo "Skript ausfuehren: $(Split-Path $ScriptPath -Leaf) -> $HostName`:$Port/$Database"

    $result = Invoke-LabSqlScript `
        -ScriptPath $ScriptPath `
        -HostName $HostName `
        -Port $Port `
        -SaPassword $SaPassword `
        -Database $Database

    if ($result.Success) {
        Write-LabSuccess "$($result.Message) ($($result.Batches) Batches, $($result.Duration.TotalSeconds.ToString('F1'))s)"
    }
    else {
        Write-LabError $result.Message
    }

    return $result
}
