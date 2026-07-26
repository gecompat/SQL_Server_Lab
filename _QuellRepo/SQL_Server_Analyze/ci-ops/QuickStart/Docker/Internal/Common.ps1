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

function Invoke-ExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter()][string[]] $Arguments = @(),
        [Parameter()][int[]] $AllowedExitCodes = @(0),
        [switch] $Quiet
    )

    $output = @(& $FilePath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -notin $AllowedExitCodes) {
        $text = ($output | ForEach-Object { [string] $_ }) -join [Environment]::NewLine
        throw "Command '$FilePath' failed with exit code $exitCode.`n$text"
    }
    if (-not $Quiet) {
        $output | ForEach-Object { Write-Host ([string] $_) }
    }
    return @($output | ForEach-Object { [string] $_ })
}

function Get-FirstOutputLine {
    param([Parameter()][AllowEmptyCollection()][object[]] $InputObject = @())

    $first = @($InputObject | Select-Object -First 1)
    if ($first.Count -eq 0 -or $null -eq $first[0]) {
        return ''
    }
    return ([string] $first[0]).Trim()
}

function Assert-DockerReady {
    if (-not (Get-Command -Name docker -ErrorAction SilentlyContinue)) {
        throw 'Docker CLI wurde nicht gefunden. Docker Desktop oder Docker Engine muss zuerst installiert werden.'
    }

    Invoke-ExternalCommand -FilePath 'docker' -Arguments @('version', '--format', '{{.Server.Version}}') -Quiet | Out-Null
    Invoke-ExternalCommand -FilePath 'docker' -Arguments @('compose', 'version', '--short') -Quiet | Out-Null

    $osType = Get-FirstOutputLine -InputObject @(
        Invoke-ExternalCommand -FilePath 'docker' -Arguments @('info', '--format', '{{.OSType}}') -Quiet
    )
    if ($osType -ne 'linux') {
        throw "Die Docker Engine meldet OSType '$osType'. SQL-Server-Linux-Container benötigen eine Linux-Container-Engine."
    }
}
