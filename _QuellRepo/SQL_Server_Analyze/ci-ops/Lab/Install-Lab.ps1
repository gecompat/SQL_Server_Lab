[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [ValidateSet('Preflight', 'Install', 'Status', 'Stop', 'Restart', 'Reset', 'Down', 'Start', 'Destroy')]
    [string] $Action = 'Preflight',

    [Parameter()]
    [ValidateSet('DOCKER', 'PODMAN')]
    [string] $Runtime,

    [Parameter()]
    [int[]] $SqlVersions,

    [Parameter()]
    [hashtable] $Ports = @{},

    [Parameter()]
    [ValidatePattern('^(sa|[A-Za-z][A-Za-z0-9_]{2,31})$')]
    [string] $AdminLogin,

    [Parameter()]
    [securestring] $AdminSecret,

    [Parameter()]
    [string] $SecretEnvironmentVariable = 'QTLAB_SQL_SECRET',

    [Parameter()]
    [switch] $GenerateSecret,

    [Parameter()]
    [ValidateSet('SMALL', 'MEDIUM', 'LARGE')]
    [string] $ResourceProfile,

    [Parameter()]
    [ValidateSet('PERSISTENT', 'TEMPORARY')]
    [string] $PersistenceMode,

    [Parameter()]
    [string] $DataRoot = (Join-Path $PSScriptRoot '.artifacts/quick-test'),

    [Parameter()]
    [string] $StateRoot = (Join-Path $PSScriptRoot '.state/quick-test'),

    [Parameter()]
    [string] $CredentialRoot = (Join-Path $PSScriptRoot '.secrets/quick-test'),

    [Parameter()]
    [ValidatePattern('^[a-z][a-z0-9-]{2,31}$')]
    [string] $ScopeName = 'sql-analyze-quicktest',

    [Parameter()]
    [switch] $AcceptEula,

    [Parameter()]
    [switch] $InstallFramework,

    [Parameter()]
    [switch] $Force,

    [Parameter()]
    [switch] $NonInteractive,

    [Parameter()]
    [switch] $SkipImageAvailabilityCheck
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot 'QuickTest/QuickTestLab.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

function Read-QuickTestChoice {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Prompt,

        [Parameter(Mandatory)]
        [string[]] $AllowedValues,

        [Parameter(Mandatory)]
        [string] $DefaultValue
    )

    while ($true) {
        $value = Read-Host "$Prompt [$($AllowedValues -join '/')], default $DefaultValue"
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $DefaultValue
        }
        $normalized = $value.Trim().ToUpperInvariant()
        if ($normalized -in $AllowedValues) {
            return $normalized
        }
        Write-Warning 'The selected value is not supported.'
    }
}

function Read-QuickTestVersions {
    [CmdletBinding()]
    [OutputType([int[]])]
    param()

    while ($true) {
        $value = Read-Host 'SQL Server versions, comma separated [2019,2022,2025]'
        if ([string]::IsNullOrWhiteSpace($value)) {
            return @(2019, 2022, 2025)
        }
        try {
            $versions = @(
                $value.Split(',') |
                    ForEach-Object { [int] ($_.Trim()) } |
                    Sort-Object -Unique
            )
            $invalid = @(
                $versions | Where-Object { $_ -notin @(2019, 2022, 2025) }
            )
            if ($versions.Count -gt 0 -and $invalid.Count -eq 0) {
                return $versions
            }
        }
        catch {
            # A bounded warning follows below.
        }
        Write-Warning 'Choose one or more values from 2019, 2022, and 2025.'
    }
}

function Read-QuickTestPorts {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [int[]] $Versions
    )

    $defaults = Get-QuickTestDefaultPorts
    $result = @{}
    foreach ($version in $Versions) {
        while ($true) {
            $value = Read-Host "Host port for SQL Server $version [$($defaults[$version])]"
            if ([string]::IsNullOrWhiteSpace($value)) {
                $result[$version] = [int] $defaults[$version]
                break
            }
            $port = 0
            $parsed = [int]::TryParse($value, [ref] $port)
            if ($parsed -and $port -ge 1024 -and $port -le 65535) {
                $result[$version] = $port
                break
            }
            Write-Warning 'Use an unprivileged TCP port from 1024 through 65535.'
        }
    }
    return $result
}

if ($Force -and $Action -notin @('Down', 'Reset', 'Destroy')) {
    throw '-Force is supported only with -Action Down, Reset, or Destroy.'
}

if ($Action -eq 'Status') {
    Get-QuickTestLabStatus `
        -ScopeName $ScopeName `
        -StateRoot $StateRoot
    return
}

if ($Action -eq 'Stop') {
    $stopArguments = @{
        ScopeName = $ScopeName
        StateRoot = $StateRoot
        Confirm = $false
    }
    if ($WhatIfPreference) {
        $stopArguments.WhatIf = $true
    }
    Stop-QuickTestLab @stopArguments
    return
}

if ($Action -eq 'Restart') {
    $restartArguments = @{
        ScopeName = $ScopeName
        StateRoot = $StateRoot
        Confirm = $false
    }
    if ($WhatIfPreference) {
        $restartArguments.WhatIf = $true
    }
    Restart-QuickTestLab @restartArguments
    return
}

if ($Action -eq 'Reset') {
    if ($GenerateSecret) {
        throw 'Reset requires the existing SQL credential and cannot generate a new one.'
    }
    $resetSecret = $AdminSecret
    if ($null -eq $resetSecret) {
        $environmentCredential = ''
        if (-not [string]::IsNullOrWhiteSpace($SecretEnvironmentVariable)) {
            $environmentCredential = [Environment]::GetEnvironmentVariable(
                $SecretEnvironmentVariable
            )
        }
        if (-not [string]::IsNullOrWhiteSpace($environmentCredential)) {
            $resetSecret = ConvertTo-QuickTestSecureString `
                -Value $environmentCredential
            $environmentCredential = $null
        }
    }

    $resetArguments = @{
        ScopeName = $ScopeName
        StateRoot = $StateRoot
        SkipImageAvailabilityCheck = $SkipImageAvailabilityCheck
    }
    if ($null -ne $resetSecret) {
        $resetArguments.AdminSecret = $resetSecret
    }
    if ($Force) {
        $resetArguments.Confirm = $false
    }
    if ($WhatIfPreference) {
        $resetArguments.WhatIf = $true
    }
    $resetResult = Reset-QuickTestLab @resetArguments
    if (
        $resetResult.Status -eq 'RESET_CREDENTIAL_REQUIRED' -and
        -not $NonInteractive
    ) {
        $resetArguments.AdminSecret = Read-Host `
            'Existing administrative SQL credential' `
            -AsSecureString
        $resetResult = Reset-QuickTestLab @resetArguments
    }
    $resetResult
    return
}

if ($Action -eq 'Down') {
    if (-not $Force) {
        if (-not $PSCmdlet.ShouldProcess(
                "quick-test scope $ScopeName",
                'Remove registered containers and network while preserving local state and data'
            )) {
            [pscustomobject] @{
                Status = 'DOWN_CONFIRMATION_REQUIRED'
                ScopeName = $ScopeName
            }
            return
        }
    }
    Invoke-QuickTestLabDown `
        -ScopeName $ScopeName `
        -StateRoot $StateRoot `
        -Confirm:$false
    return
}

if ($Action -eq 'Start') {
    $currentStatus = Get-QuickTestLabStatus `
        -ScopeName $ScopeName `
        -StateRoot $StateRoot
    $currentLifecycleStatus = ''
    if ($currentStatus.PSObject.Properties.Name -contains 'LifecycleStatus') {
        $currentLifecycleStatus = [string] $currentStatus.LifecycleStatus
    }
    if (
        $currentStatus.Status -eq 'STOPPED' -or
        $currentLifecycleStatus -eq 'STOPPED'
    ) {
        $stoppedStartArguments = @{
            ScopeName = $ScopeName
            StateRoot = $StateRoot
            Confirm = $false
        }
        if ($WhatIfPreference) {
            $stoppedStartArguments.WhatIf = $true
        }
        Start-QuickTestStoppedLab @stoppedStartArguments
        return
    }

    if ($GenerateSecret) {
        throw 'Start requires the existing SQL credential and cannot generate a new one.'
    }
    $startSecret = $AdminSecret
    if ($null -eq $startSecret) {
        $environmentCredential = ''
        if (-not [string]::IsNullOrWhiteSpace($SecretEnvironmentVariable)) {
            $environmentCredential = [Environment]::GetEnvironmentVariable(
                $SecretEnvironmentVariable
            )
        }
        if (-not [string]::IsNullOrWhiteSpace($environmentCredential)) {
            $startSecret = ConvertTo-QuickTestSecureString `
                -Value $environmentCredential
            $environmentCredential = $null
        }
    }

    $startArguments = @{
        ScopeName = $ScopeName
        StateRoot = $StateRoot
        Confirm = $false
    }
    if ($null -ne $startSecret) {
        $startArguments.AdminSecret = $startSecret
    }
    if ($WhatIfPreference) {
        $startArguments.WhatIf = $true
    }
    $startResult = Start-QuickTestLab @startArguments
    if (
        $startResult.Status -eq 'START_CREDENTIAL_REQUIRED' -and
        -not $NonInteractive
    ) {
        $startArguments.AdminSecret = Read-Host `
            'Existing administrative SQL credential' `
            -AsSecureString
        $startResult = Start-QuickTestLab @startArguments
    }
    $startResult
    return
}

if ($Action -eq 'Destroy') {
    if (-not $Force) {
        if (-not $PSCmdlet.ShouldProcess(
                "quick-test scope $ScopeName",
                'Destroy all registered quick-test resources and local data'
            )) {
            [pscustomobject] @{
                Status = 'DESTROY_CONFIRMATION_REQUIRED'
                ScopeName = $ScopeName
            }
            return
        }
    }
    Remove-QuickTestLab `
        -ScopeName $ScopeName `
        -StateRoot $StateRoot `
        -Confirm:$false
    return
}

if (-not $PSBoundParameters.ContainsKey('Runtime')) {
    if ($NonInteractive) {
        throw "Non-interactive $Action requires -Runtime."
    }
    $Runtime = Read-QuickTestChoice `
        -Prompt 'Container runtime' `
        -AllowedValues @('DOCKER', 'PODMAN') `
        -DefaultValue 'DOCKER'
}

if (-not $PSBoundParameters.ContainsKey('SqlVersions')) {
    if ($NonInteractive) {
        throw "Non-interactive $Action requires -SqlVersions."
    }
    $SqlVersions = Read-QuickTestVersions
}

if (-not $PSBoundParameters.ContainsKey('Ports') -or $Ports.Count -eq 0) {
    if ($NonInteractive) {
        $defaults = Get-QuickTestDefaultPorts
        foreach ($version in $SqlVersions) {
            $Ports[$version] = $defaults[$version]
        }
    }
    else {
        $Ports = Read-QuickTestPorts -Versions $SqlVersions
    }
}

if (-not $PSBoundParameters.ContainsKey('AdminLogin')) {
    if ($NonInteractive) {
        $AdminLogin = 'ExampleSqlAdmin'
    }
    else {
        $value = Read-Host 'Administrative SQL login [ExampleSqlAdmin]'
        if ([string]::IsNullOrWhiteSpace($value)) {
            $AdminLogin = 'ExampleSqlAdmin'
        }
        else {
            $AdminLogin = $value.Trim()
        }
    }
}

if (-not $PSBoundParameters.ContainsKey('ResourceProfile')) {
    if ($NonInteractive) {
        $ResourceProfile = 'SMALL'
    }
    else {
        $ResourceProfile = Read-QuickTestChoice `
            -Prompt 'Resource profile' `
            -AllowedValues @('SMALL', 'MEDIUM', 'LARGE') `
            -DefaultValue 'SMALL'
    }
}

if (-not $PSBoundParameters.ContainsKey('PersistenceMode')) {
    if ($NonInteractive) {
        $PersistenceMode = 'TEMPORARY'
    }
    else {
        $PersistenceMode = Read-QuickTestChoice `
            -Prompt 'Persistence mode' `
            -AllowedValues @('PERSISTENT', 'TEMPORARY') `
            -DefaultValue 'TEMPORARY'
    }
}

if (-not $AcceptEula) {
    if ($NonInteractive) {
        throw "Non-interactive $Action requires -AcceptEula."
    }
    $confirmation = Read-Host 'Accept the SQL Server container EULA for this test use? [yes/no]'
    if ($confirmation.Trim().ToLowerInvariant() -ne 'yes') {
        throw 'SQL Server EULA acceptance was not provided.'
    }
    $AcceptEula = $true
}

$generatedCredential = $false
if ($GenerateSecret) {
    $AdminSecret = New-QuickTestPassword
    $generatedCredential = $true
}
elseif ($PSBoundParameters.ContainsKey('AdminSecret')) {
    # The caller supplied a SecureString object.
}
else {
    $environmentCredential = ''
    if (-not [string]::IsNullOrWhiteSpace($SecretEnvironmentVariable)) {
        $environmentCredential = [Environment]::GetEnvironmentVariable(
            $SecretEnvironmentVariable
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($environmentCredential)) {
        $AdminSecret = ConvertTo-QuickTestSecureString `
            -Value $environmentCredential
        $environmentCredential = $null
    }
    elseif (-not $NonInteractive) {
        $AdminSecret = Read-Host 'Administrative SQL secret' -AsSecureString
    }
    else {
        throw 'Provide -AdminSecret, -GenerateSecret, or a populated secret environment variable.'
    }
}

if ($Action -eq 'Preflight') {
    $result = Invoke-QuickTestPreflight `
        -Runtime $Runtime `
        -SqlVersions $SqlVersions `
        -Ports $Ports `
        -AdminLogin $AdminLogin `
        -AdminSecret $AdminSecret `
        -ResourceProfile $ResourceProfile `
        -DataRoot (Join-Path $DataRoot $ScopeName) `
        -ScopeName $ScopeName `
        -AcceptEula:$AcceptEula `
        -SkipImageAvailabilityCheck:$SkipImageAvailabilityCheck

    $result | Add-Member `
        -NotePropertyName PersistenceMode `
        -NotePropertyValue $PersistenceMode `
        -PassThru
    return
}

$installArguments = @{
    Runtime = $Runtime
    SqlVersions = $SqlVersions
    Ports = $Ports
    AdminSecret = $AdminSecret
    AdminLogin = $AdminLogin
    ResourceProfile = $ResourceProfile
    PersistenceMode = $PersistenceMode
    ScopeName = $ScopeName
    InstallFramework = $InstallFramework
    PersistGeneratedCredential = $generatedCredential
    AcceptEula = $AcceptEula
    StateRoot = $StateRoot
    DataRoot = $DataRoot
    CredentialRoot = $CredentialRoot
    SkipImageAvailabilityCheck = $SkipImageAvailabilityCheck
    Confirm = $false
}
if ($WhatIfPreference) {
    $installArguments.WhatIf = $true
}
Install-QuickTestLab @installArguments
