function Write-Section {
    param([Parameter(Mandatory)][string] $Text)
    Write-Host ''
    Write-Host "=== $Text ==="
}

function Read-YesNo {
    param(
        [Parameter(Mandatory)][string] $Prompt,
        [bool] $Default = $false
    )

    $suffix = if ($Default) { '[J/n]' } else { '[j/N]' }
    while ($true) {
        $answer = (Read-Host "$Prompt $suffix").Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Default
        }
        if ($answer -match '^(j|ja|y|yes)$') {
            return $true
        }
        if ($answer -match '^(n|nein|no)$') {
            return $false
        }
        Write-Warning 'Bitte J oder N eingeben.'
    }
}

function Read-MenuChoice {
    param(
        [Parameter(Mandatory)][string] $Prompt,
        [Parameter(Mandatory)][hashtable] $Choices,
        [Parameter(Mandatory)][string] $DefaultKey
    )

    foreach ($key in @($Choices.Keys | Sort-Object)) {
        Write-Host "[$key] $($Choices[$key])"
    }

    while ($true) {
        $value = (Read-Host "$Prompt [Standard: $DefaultKey]").Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $DefaultKey
        }
        if ($Choices.ContainsKey($value)) {
            return $value
        }
        Write-Warning 'Ungültige Auswahl.'
    }
}

function Read-SecurePassword {
    param(
        [Parameter(Mandatory)][string] $Prompt,
        [int] $MinLength = 8
    )

    while ($true) {
        $secure = Read-Host -Prompt $Prompt -AsSecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        )
        if ($plain.Length -lt $MinLength) {
            Write-Warning "Mindestens $MinLength Zeichen erforderlich."
            continue
        }
        if ($plain -notmatch '[A-Z]' -or $plain -notmatch '[a-z]' -or $plain -notmatch '[0-9]') {
            Write-Warning 'Großbuchstabe, Kleinbuchstabe und Ziffer erforderlich.'
            continue
        }
        return $plain
    }
}

function Read-EnvFile {
    param([Parameter(Mandatory)][string] $Path)

    $config = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $config
    }
    foreach ($line in @(Get-Content -LiteralPath $Path -Encoding utf8)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }
        $eqIndex = $trimmed.IndexOf('=')
        if ($eqIndex -gt 0) {
            $key = $trimmed.Substring(0, $eqIndex).Trim()
            $value = $trimmed.Substring($eqIndex + 1).Trim()
            $config[$key] = $value
        }
    }
    return $config
}

function Write-EnvFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][hashtable] $Config
    )

    $lines = @('# SQL_Server_Analyze Hyper-V QuickStart Konfiguration', "# Erzeugt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", '')
    foreach ($key in @($Config.Keys | Sort-Object)) {
        $lines += "$key=$($Config[$key])"
    }
    [IO.File]::WriteAllLines($Path, $lines, [Text.Encoding]::UTF8)
}

function Invoke-SqlCmd {
    param(
        [Parameter(Mandatory)][string] $ServerInstance,
        [Parameter(Mandatory)][string] $Query,
        [Parameter(Mandatory)][string] $Password,
        [int] $TimeoutSeconds = 30
    )

    $connectionString = "Server=$ServerInstance;User Id=sa;Password=$Password;TrustServerCertificate=True;Connect Timeout=$TimeoutSeconds;"
    $connection = [System.Data.SqlClient.SqlConnection]::new($connectionString)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = $TimeoutSeconds
        $adapter = [System.Data.SqlClient.SqlDataAdapter]::new($command)
        $dataSet = [System.Data.DataSet]::new()
        [void]$adapter.Fill($dataSet)
        return $dataSet.Tables[0]
    }
    finally {
        $connection.Dispose()
    }
}

function Test-SqlConnection {
    param(
        [Parameter(Mandatory)][string] $ServerInstance,
        [Parameter(Mandatory)][string] $Password,
        [int] $TimeoutSeconds = 5
    )

    try {
        $result = Invoke-SqlCmd -ServerInstance $ServerInstance `
            -Query 'SELECT 1 AS [Connected]' `
            -Password $Password `
            -TimeoutSeconds $TimeoutSeconds
        return ($null -ne $result -and $result.Rows.Count -gt 0)
    }
    catch {
        return $false
    }
}
