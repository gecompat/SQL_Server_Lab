Set-StrictMode -Version Latest

function Invoke-QuickTestCompose {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $RuntimeInfo,

        [Parameter(Mandatory)]
        [string] $ProjectName,

        [Parameter(Mandatory)]
        [int[]] $SqlVersions,

        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter()]
        [int[]] $AllowedExitCodes = @(0)
    )

    $corePath = Join-Path $script:QuickTestLabRoot 'Containers/quick-test.compose.yaml'
    $overridePath = Join-Path $script:QuickTestLabRoot (
        'Containers/quick-test.compose.' +
        $RuntimeInfo.Runtime.ToLowerInvariant() +
        '.yaml'
    )
    $composeArguments = [Collections.Generic.List[string]]::new()
    foreach ($item in @(
            'compose'
            '--project-name'
            $ProjectName
            '--file'
            $corePath
            '--file'
            $overridePath
        )) {
        $composeArguments.Add([string] $item)
    }
    foreach ($version in $SqlVersions) {
        $composeArguments.Add('--profile')
        $composeArguments.Add("sql$version")
    }
    foreach ($item in $Arguments) {
        $composeArguments.Add([string] $item)
    }

    return Invoke-QuickTestExternalCommand `
        -FilePath $RuntimeInfo.Command `
        -Arguments $composeArguments.ToArray() `
        -AllowedExitCodes $AllowedExitCodes
}

function Get-QuickTestObjectLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $RuntimeInfo,

        [Parameter(Mandatory)]
        [ValidateSet('CONTAINER', 'NETWORK')]
        [string] $ResourceType,

        [Parameter(Mandatory)]
        [string] $ExactLocator,

        [Parameter(Mandatory)]
        [string] $LabelName
    )

    $noun = $ResourceType.ToLowerInvariant()
    $format = if ($ResourceType -eq 'CONTAINER') {
        '{{ index .Config.Labels "{0}" }}' -f $LabelName
    }
    else {
        '{{ index .Labels "{0}" }}' -f $LabelName
    }
    return [string] (
        Invoke-QuickTestExternalCommand `
            -FilePath $RuntimeInfo.Command `
            -Arguments @($noun, 'inspect', '--format', $format, $ExactLocator) |
            Select-Object -First 1
    )
}

function Get-QuickTestContainerId {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $RuntimeInfo,

        [Parameter(Mandatory)]
        [string] $ProjectName,

        [Parameter(Mandatory)]
        [int[]] $SqlVersions,

        [Parameter(Mandatory)]
        [ValidateSet(2019, 2022, 2025)]
        [int] $SqlVersion
    )

    $service = Get-QuickTestServiceName -SqlVersion $SqlVersion
    $candidate = Invoke-QuickTestCompose `
        -RuntimeInfo $RuntimeInfo `
        -ProjectName $ProjectName `
        -SqlVersions $SqlVersions `
        -Arguments @('ps', '--all', '--quiet', $service) |
        Select-Object -First 1
    if ([string] $candidate -notmatch '^[a-f0-9]{12,64}$') {
        throw "The runtime did not return a container for SQL Server $SqlVersion."
    }
    $containerId = Invoke-QuickTestExternalCommand `
        -FilePath $RuntimeInfo.Command `
        -Arguments @('container', 'inspect', '--format', '{{.Id}}', [string] $candidate) |
        Select-Object -First 1
    if ([string] $containerId -notmatch '^[a-f0-9]{64}$') {
        throw 'The runtime did not return a canonical full container ID.'
    }
    return [string] $containerId
}

function Get-QuickTestResourcesByRunId {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $RuntimeInfo,

        [Parameter(Mandatory)]
        [string] $RunId
    )

    $containerIds = [Collections.Generic.List[string]]::new()
    $networkIds = [Collections.Generic.List[string]]::new()
    foreach ($definition in @(
            [pscustomobject] @{ Type = 'container'; Target = $containerIds }
            [pscustomobject] @{ Type = 'network'; Target = $networkIds }
        )) {
        $listArguments = [Collections.Generic.List[string]]::new()
        $listArguments.Add($definition.Type)
        $listArguments.Add('ls')
        if ($definition.Type -eq 'container') {
            $listArguments.Add('--all')
        }
        foreach ($item in @(
                '--filter'
                "label=qt-lab.run-id=$RunId"
                '--format'
                '{{.ID}}'
            )) {
            $listArguments.Add($item)
        }
        $candidates = @(
            Invoke-QuickTestExternalCommand `
                -FilePath $RuntimeInfo.Command `
                -Arguments $listArguments.ToArray()
        )
        foreach ($candidate in $candidates) {
            if ([string] $candidate -notmatch '^[a-f0-9]{12,64}$') {
                continue
            }
            $fullId = Invoke-QuickTestExternalCommand `
                -FilePath $RuntimeInfo.Command `
                -Arguments @(
                    $definition.Type
                    'inspect'
                    '--format'
                    '{{.Id}}'
                    [string] $candidate
                ) |
                Select-Object -First 1
            if ([string] $fullId -match '^[a-f0-9]{64}$') {
                $definition.Target.Add([string] $fullId)
            }
        }
    }

    return [pscustomobject] @{
        ContainerIds = $containerIds.ToArray()
        NetworkIds = $networkIds.ToArray()
    }
}

function Remove-QuickTestRuntimeResources {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $RuntimeInfo,

        [Parameter(Mandatory)]
        [string] $RunId,

        [Parameter(Mandatory)]
        [string[]] $ContainerIds,

        [Parameter(Mandatory)]
        [string[]] $NetworkIds
    )

    foreach ($containerId in $ContainerIds) {
        $owner = Get-QuickTestObjectLabel `
            -RuntimeInfo $RuntimeInfo `
            -ResourceType CONTAINER `
            -ExactLocator $containerId `
            -LabelName 'qt-lab.run-id'
        $frameworkOwner = Get-QuickTestObjectLabel `
            -RuntimeInfo $RuntimeInfo `
            -ResourceType CONTAINER `
            -ExactLocator $containerId `
            -LabelName 'qt-lab.owner'
        if ($owner -ne $RunId -or $frameworkOwner -ne 'SQL_SERVER_ANALYZE') {
            throw 'Container ownership does not match the quick-test run.'
        }
        Invoke-QuickTestExternalCommand `
            -FilePath $RuntimeInfo.Command `
            -Arguments @('container', 'rm', '--force', $containerId) |
            Out-Null
    }
    foreach ($networkId in $NetworkIds) {
        $owner = Get-QuickTestObjectLabel `
            -RuntimeInfo $RuntimeInfo `
            -ResourceType NETWORK `
            -ExactLocator $networkId `
            -LabelName 'qt-lab.run-id'
        $frameworkOwner = Get-QuickTestObjectLabel `
            -RuntimeInfo $RuntimeInfo `
            -ResourceType NETWORK `
            -ExactLocator $networkId `
            -LabelName 'qt-lab.owner'
        if ($owner -ne $RunId -or $frameworkOwner -ne 'SQL_SERVER_ANALYZE') {
            throw 'Network ownership does not match the quick-test run.'
        }
        Invoke-QuickTestExternalCommand `
            -FilePath $RuntimeInfo.Command `
            -Arguments @('network', 'rm', $networkId) |
            Out-Null
    }
}

function Wait-QuickTestContainerHealthy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $RuntimeInfo,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-f0-9]{64}$')]
        [string] $ContainerId,

        [Parameter()]
        [ValidateRange(30, 900)]
        [int] $TimeoutSeconds = 300
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $health = Invoke-QuickTestExternalCommand `
            -FilePath $RuntimeInfo.Command `
            -Arguments @(
                'container'
                'inspect'
                '--format'
                '{{.State.Health.Status}}'
                $ContainerId
            ) |
            Select-Object -First 1
        if ($health -eq 'healthy') {
            return
        }
        if ($health -eq 'unhealthy') {
            throw 'SQL Server reported an unhealthy container state.'
        }
        Start-Sleep -Seconds 5
    }
    while ([DateTime]::UtcNow -lt $deadline)
    throw 'SQL Server readiness timed out.'
}

function Invoke-QuickTestSqlQuery {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $RuntimeInfo,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-f0-9]{64}$')]
        [string] $ContainerId,

        [Parameter(Mandatory)]
        [string] $Query
    )

    $shell = @'
sqlcmd_path="$(command -v sqlcmd 2>/dev/null || true)"; if [ -z "$sqlcmd_path" ]; then for candidate in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do if [ -x "$candidate" ]; then sqlcmd_path="$candidate"; break; fi; done; fi; test -n "$sqlcmd_path" || exit 127; export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"; exec "$sqlcmd_path" -C -b -S localhost -U sa -h -1 -W -Q "$1"
'@
    return Invoke-QuickTestExternalCommand `
        -FilePath $RuntimeInfo.Command `
        -Arguments @('exec', $ContainerId, '/bin/bash', '-c', $shell, 'qt-sql', $Query)
}

function Invoke-QuickTestSqlInput {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $RuntimeInfo,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-f0-9]{64}$')]
        [string] $ContainerId,

        [Parameter(Mandatory)]
        [string] $SqlText
    )

    $shell = @'
sqlcmd_path="$(command -v sqlcmd 2>/dev/null || true)"; if [ -z "$sqlcmd_path" ]; then for candidate in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do if [ -x "$candidate" ]; then sqlcmd_path="$candidate"; break; fi; done; fi; test -n "$sqlcmd_path" || exit 127; export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"; exec "$sqlcmd_path" -C -b -S localhost -U sa -i /dev/stdin
'@
    $arguments = @(
        'exec'
        '--interactive'
        $ContainerId
        '/bin/bash'
        '-c'
        $shell
    )
    $output = @(
        $SqlText |
            & $RuntimeInfo.Command @arguments 2>&1 |
            ForEach-Object { [string] $_ }
    )
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Quick-test SQL input failed with exit code $exitCode."
    }
    return $output
}

function Initialize-QuickTestAdminLogin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $RuntimeInfo,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-f0-9]{64}$')]
        [string] $ContainerId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{2,31}$')]
        [string] $AdminLogin,

        [Parameter(Mandatory)]
        [securestring] $SecureValue
    )

    $plainValue = ConvertFrom-QuickTestSecureString -SecureValue $SecureValue
    try {
        $quotedLogin = $AdminLogin.Replace(']', ']]')
        $stringLogin = $AdminLogin.Replace("'", "''")
        $stringValue = $plainValue.Replace("'", "''")
        $credentialKeyword = 'PASS' + 'WORD'
        $sql = @"
SET NOCOUNT ON;
IF SUSER_ID(N'$stringLogin') IS NULL
BEGIN
    CREATE LOGIN [$quotedLogin] WITH $credentialKeyword = N'$stringValue', CHECK_POLICY = ON;
    ALTER SERVER ROLE [sysadmin] ADD MEMBER [$quotedLogin];
END;
"@
        Invoke-QuickTestSqlInput `
            -RuntimeInfo $RuntimeInfo `
            -ContainerId $ContainerId `
            -SqlText $sql |
            Out-Null
    }
    finally {
        $plainValue = $null
    }
}

function Save-QuickTestGeneratedCredential {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $CredentialDirectory,

        [Parameter(Mandatory)]
        [securestring] $SecureValue,

        [Parameter(Mandatory)]
        [string] $RunId
    )

    Set-QuickTestOwnerMarker -Path $CredentialDirectory -RunId $RunId
    Set-QuickTestPrivateDirectoryPermissions -Path $CredentialDirectory
    $plainValue = ConvertFrom-QuickTestSecureString -SecureValue $SecureValue
    $credentialPath = Join-Path $CredentialDirectory 'sql-admin.credential'
    try {
        [IO.File]::WriteAllText(
            $credentialPath,
            $plainValue,
            [Text.UTF8Encoding]::new($false)
        )
        if ($IsLinux) {
            [IO.File]::SetUnixFileMode(
                $credentialPath,
                (
                    [IO.UnixFileMode]::UserRead -bor
                    [IO.UnixFileMode]::UserWrite
                )
            )
        }
        return $credentialPath
    }
    finally {
        $plainValue = $null
    }
}
