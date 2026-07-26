function Get-SelectedVersions {
    while ($true) {
        $inputValue = (Read-Host 'SQL-Server-Versionen (2019,2022,2025) [Standard: 2019,2022,2025]').Trim()
        if ([string]::IsNullOrWhiteSpace($inputValue)) {
            return @('2019', '2022', '2025')
        }
        $versions = @($inputValue -split '[,; ]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        if ($versions.Count -gt 0 -and @($versions | Where-Object { $_ -notin @('2019', '2022', '2025') }).Count -eq 0) {
            return @($versions | Sort-Object)
        }
        Write-Warning 'Erlaubt sind ausschließlich 2019, 2022 und 2025.'
    }
}

function Get-ResourceSettings {
    param([Parameter(Mandatory)][int] $VersionCount)

    $profiles = @{
        '1' = 'Compact: 2 CPU, 3 GiB Container, 2 GiB SQL Server je Instanz'
        '2' = 'Standard: 4 CPU, 8 GiB Container, 6 GiB SQL Server je Instanz'
        '3' = 'Performance: 8 CPU, 16 GiB Container, 12 GiB SQL Server je Instanz'
    }
    $choice = Read-MenuChoice -Prompt 'Ressourcenprofil' -Choices $profiles -DefaultKey '2'
    $settings = switch ($choice) {
        '1' { [pscustomobject]@{ Name = 'COMPACT'; Cpus = '2.0'; ContainerMemory = '3g'; ContainerMemoryGiB = 3; SqlMemoryMb = 2048 } }
        '2' { [pscustomobject]@{ Name = 'STANDARD'; Cpus = '4.0'; ContainerMemory = '8g'; ContainerMemoryGiB = 8; SqlMemoryMb = 6144 } }
        '3' { [pscustomobject]@{ Name = 'PERFORMANCE'; Cpus = '8.0'; ContainerMemory = '16g'; ContainerMemoryGiB = 16; SqlMemoryMb = 12288 } }
    }

    $totalMemoryGiB = if ($script:IsWindowsHost) {
        [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    }
    elseif (Test-Path -LiteralPath '/proc/meminfo') {
        $line = Get-Content -LiteralPath '/proc/meminfo' | Where-Object { $_ -match '^MemTotal:' } | Select-Object -First 1
        [math]::Floor(([double] (($line -replace '\D', ''))) / 1MB)
    }
    else {
        0
    }

    $requestedGiB = $settings.ContainerMemoryGiB * $VersionCount
    if ($totalMemoryGiB -gt 0 -and $requestedGiB -gt [math]::Floor($totalMemoryGiB * 0.70)) {
        Write-Warning "Das Profil reserviert bis zu $requestedGiB GiB für Container; der Host hat ungefähr $totalMemoryGiB GiB RAM."
        if (-not (Read-YesNo -Prompt 'Dieses Profil trotzdem verwenden?' -Default $false)) {
            return Get-ResourceSettings -VersionCount $VersionCount
        }
    }
    return $settings
}

function Test-PortAvailable {
    param([Parameter(Mandatory)][ValidateRange(1024, 65535)][int] $Port)
    $listeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    return -not ($listeners.Port -contains $Port)
}

function Read-AvailablePort {
    param(
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][int] $DefaultPort,
        [Parameter(Mandatory)][int[]] $AlreadySelected
    )

    while ($true) {
        $raw = (Read-Host "Host-Port für SQL Server $Version [Standard: $DefaultPort]").Trim()
        $port = if ([string]::IsNullOrWhiteSpace($raw)) { $DefaultPort } else { 0 }
        if (-not [string]::IsNullOrWhiteSpace($raw) -and -not [int]::TryParse($raw, [ref] $port)) {
            Write-Warning 'Bitte eine gültige Portnummer eingeben.'
            continue
        }
        if ($port -lt 1024 -or $port -gt 65535) {
            Write-Warning 'Der Port muss zwischen 1024 und 65535 liegen.'
            continue
        }
        if ($port -in $AlreadySelected) {
            Write-Warning 'Dieser Port wurde bereits für eine andere SQL-Version gewählt.'
            continue
        }
        if (-not (Test-PortAvailable -Port $port)) {
            Write-Warning "Port $port ist bereits belegt."
            continue
        }
        return $port
    }
}

function Read-SaPassword {
    while ($true) {
        $secure = Read-Host 'SA-Passwort für die synthetischen SQL-Testinstanzen' -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }

        if ($plain.Length -lt 16 -or $plain.Length -gt 128) {
            Write-Warning 'Das Passwort muss 16 bis 128 Zeichen lang sein.'
            continue
        }
        if ($plain -notmatch '[A-Z]' -or $plain -notmatch '[a-z]' -or $plain -notmatch '\d' -or $plain -notmatch '[^A-Za-z0-9]') {
            Write-Warning 'Das Passwort muss Großbuchstaben, Kleinbuchstaben, Ziffern und Sonderzeichen enthalten.'
            continue
        }
        if ($plain -match "['\r\n]" -or $plain -match '\s') {
            Write-Warning "Leerraum, Zeilenumbrüche und das einfache Anführungszeichen sind für die lokale .env-Datei nicht zulässig."
            continue
        }
        return $plain
    }
}
