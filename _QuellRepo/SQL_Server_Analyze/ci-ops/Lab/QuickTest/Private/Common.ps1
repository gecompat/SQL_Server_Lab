Set-StrictMode -Version Latest

function ConvertFrom-QuickTestSecureString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [securestring] $SecureValue
    )

    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
            $SecureValue
        )
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
}

function ConvertTo-QuickTestSecureString {
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value
    )

    $secureValue = [securestring]::new()
    foreach ($character in $Value.ToCharArray()) {
        $secureValue.AppendChar($character)
    }
    $secureValue.MakeReadOnly()
    return $secureValue
}

function Test-QuickTestPassword {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [securestring] $SecureValue
    )

    $plainValue = ConvertFrom-QuickTestSecureString -SecureValue $SecureValue
    try {
        return (
            $plainValue.Length -ge 12 -and
            $plainValue -cmatch '[A-Z]' -and
            $plainValue -cmatch '[a-z]' -and
            $plainValue -match '[0-9]' -and
            $plainValue -match '[^A-Za-z0-9]'
        )
    }
    finally {
        $plainValue = $null
    }
}

function New-QuickTestPassword {
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter()]
        [ValidateRange(16, 128)]
        [int] $Length = 24
    )

    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ'
        'abcdefghijkmnopqrstuvwxyz'
        '23456789'
        '!#$%&*+-=?@_'
    )
    $characters = [Collections.Generic.List[char]]::new()
    foreach ($set in $sets) {
        $index = [Security.Cryptography.RandomNumberGenerator]::GetInt32(
            $set.Length
        )
        $characters.Add($set[$index])
    }
    $combined = $sets -join ''
    while ($characters.Count -lt $Length) {
        $index = [Security.Cryptography.RandomNumberGenerator]::GetInt32(
            $combined.Length
        )
        $characters.Add($combined[$index])
    }
    for ($index = $characters.Count - 1; $index -gt 0; $index--) {
        $swapIndex = [Security.Cryptography.RandomNumberGenerator]::GetInt32(
            $index + 1
        )
        $temporary = $characters[$index]
        $characters[$index] = $characters[$swapIndex]
        $characters[$swapIndex] = $temporary
    }

    $generatedValue = -join $characters
    try {
        return ConvertTo-QuickTestSecureString -Value $generatedValue
    }
    finally {
        $generatedValue = $null
    }
}

function Get-QuickTestDefaultPorts {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        2019 = 14331
        2022 = 14332
        2025 = 14335
    }
}

function Get-QuickTestResourceProfile {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('SMALL', 'MEDIUM', 'LARGE')]
        [string] $Name
    )

    switch ($Name) {
        'SMALL' {
            return [pscustomobject] @{
                Name = 'SMALL'
                CpuLimit = 2.0
                ContainerMemoryMiB = 3072
                SqlMemoryMiB = 2048
                HostReserveMiB = 1024
            }
        }
        'MEDIUM' {
            return [pscustomobject] @{
                Name = 'MEDIUM'
                CpuLimit = 3.0
                ContainerMemoryMiB = 5120
                SqlMemoryMiB = 4096
                HostReserveMiB = 1536
            }
        }
        'LARGE' {
            return [pscustomobject] @{
                Name = 'LARGE'
                CpuLimit = 4.0
                ContainerMemoryMiB = 8192
                SqlMemoryMiB = 6144
                HostReserveMiB = 2048
            }
        }
    }
}

function Resolve-QuickTestPorts {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [int[]] $SqlVersions,

        [Parameter()]
        [hashtable] $Ports = @{}
    )

    $versions = @($SqlVersions | Sort-Object -Unique)
    if (
        $versions.Count -eq 0 -or
        @($versions | Where-Object { $_ -notin @(2019, 2022, 2025) }).Count -gt 0
    ) {
        throw 'Choose one or more supported SQL Server versions.'
    }

    $defaults = Get-QuickTestDefaultPorts
    $resolved = @{}
    foreach ($version in $versions) {
        $value = $null
        if ($Ports.ContainsKey($version)) {
            $value = $Ports[$version]
        }
        elseif ($Ports.ContainsKey([string] $version)) {
            $value = $Ports[[string] $version]
        }
        else {
            $value = $defaults[$version]
        }
        $port = [int] $value
        if ($port -lt 1024 -or $port -gt 65535) {
            throw "The host port for SQL Server $version is outside the allowed range."
        }
        $resolved[$version] = $port
    }
    if (@($resolved.Values | Sort-Object -Unique).Count -ne $resolved.Count) {
        throw 'Selected SQL Server versions must use different host ports.'
    }
    return $resolved
}

function Get-QuickTestImageReference {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet(2019, 2022, 2025)]
        [int] $SqlVersion
    )

    return "mcr.microsoft.com/mssql/server:$SqlVersion-latest"
}

function Invoke-QuickTestExternalCommand {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter()]
        [int[]] $AllowedExitCodes = @(0)
    )

    $output = @(& $FilePath @Arguments 2>&1 | ForEach-Object { [string] $_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -notin $AllowedExitCodes) {
        throw "Quick-test command failed with exit code $exitCode."
    }
    return $output
}

function Resolve-QuickTestRuntime {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DOCKER', 'PODMAN')]
        [string] $Runtime
    )

    $commandName = $Runtime.ToLowerInvariant()
    $command = Get-Command -Name $commandName -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return [pscustomobject] @{
            IsAvailable = $false
            Runtime = $Runtime
            Command = ''
            ReasonCode = 'RUNTIME_UNAVAILABLE'
        }
    }

    try {
        Invoke-QuickTestExternalCommand `
            -FilePath $command.Source `
            -Arguments @('version') |
            Out-Null
        Invoke-QuickTestExternalCommand `
            -FilePath $command.Source `
            -Arguments @('compose', 'version') |
            Out-Null
    }
    catch {
        return [pscustomobject] @{
            IsAvailable = $false
            Runtime = $Runtime
            Command = $command.Source
            ReasonCode = 'COMPOSE_UNAVAILABLE'
        }
    }

    return [pscustomobject] @{
        IsAvailable = $true
        Runtime = $Runtime
        Command = $command.Source
        ReasonCode = ''
    }
}

function Get-QuickTestAvailableMemoryMiB {
    [CmdletBinding()]
    [OutputType([int64])]
    param()

    if (-not $IsLinux -or -not (Test-Path -LiteralPath '/proc/meminfo')) {
        return 0
    }
    $line = Get-Content -LiteralPath '/proc/meminfo' -Encoding utf8 |
        Where-Object { $_ -match '^MemAvailable:\s+([0-9]+)\s+kB$' } |
        Select-Object -First 1
    if ($line -match '^MemAvailable:\s+([0-9]+)\s+kB$') {
        return [int64] [Math]::Floor(([int64] $Matches[1]) / 1024)
    }
    return 0
}

function Test-QuickTestPortAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1024, 65535)]
        [int] $Port
    )

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $Port)
    try {
        $listener.Start()
        return $true
    }
    catch {
        return $false
    }
    finally {
        $listener.Stop()
    }
}

function Test-QuickTestWritablePath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $candidate = [IO.Path]::GetFullPath($Path)
    while (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        $parent = Split-Path -Parent $candidate
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidate) {
            return $false
        }
        $candidate = $parent
    }
    $bash = Get-Command -Name bash -ErrorAction SilentlyContinue
    if ($null -eq $bash) {
        return $false
    }
    & $bash.Source -c 'test -w "$1"' -- $candidate
    return $LASTEXITCODE -eq 0
}

function Test-QuickTestScopeConflict {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $RuntimeInfo,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z][a-z0-9-]{2,31}$')]
        [string] $ScopeName
    )

    foreach ($resourceType in @('container', 'network')) {
        $items = @(
            Invoke-QuickTestExternalCommand `
                -FilePath $RuntimeInfo.Command `
                -Arguments @(
                    $resourceType
                    'ls'
                    '--filter'
                    "label=qt-lab.scope=$ScopeName"
                    '--format'
                    '{{.ID}}'
                )
        )
        if (@($items | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            return $true
        }
    }
    return $false
}
