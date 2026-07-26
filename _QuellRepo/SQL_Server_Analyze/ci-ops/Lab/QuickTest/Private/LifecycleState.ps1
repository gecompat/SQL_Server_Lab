Set-StrictMode -Version Latest

function Get-QuickTestServiceName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet(2019, 2022, 2025)]
        [int] $SqlVersion
    )

    return "sql$SqlVersion"
}

function New-QuickTestRunId {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $suffix = [Convert]::ToHexString(
        [Security.Cryptography.RandomNumberGenerator]::GetBytes(4)
    )
    return 'QTLAB-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + $suffix
}

function Test-QuickTestPathWithinRoot {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Root
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    return (
        $fullPath -eq $fullRoot -or
        $fullPath.StartsWith(
            $fullRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::Ordinal
        )
    )
}

function Write-QuickTestJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [object] $InputObject
    )

    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    [IO.File]::WriteAllText(
        $Path,
        ($InputObject | ConvertTo-Json -Depth 100),
        [Text.UTF8Encoding]::new($false)
    )
}

function Read-QuickTestJson {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    return Get-Content -LiteralPath $Path -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
}

function Set-QuickTestDirectoryPermissions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not $IsLinux) {
        return
    }
    [IO.File]::SetUnixFileMode(
        $Path,
        (
            [IO.UnixFileMode]::UserRead -bor
            [IO.UnixFileMode]::UserWrite -bor
            [IO.UnixFileMode]::UserExecute -bor
            [IO.UnixFileMode]::GroupRead -bor
            [IO.UnixFileMode]::GroupWrite -bor
            [IO.UnixFileMode]::GroupExecute -bor
            [IO.UnixFileMode]::OtherRead -bor
            [IO.UnixFileMode]::OtherWrite -bor
            [IO.UnixFileMode]::OtherExecute
        )
    )
}

function Set-QuickTestPrivateDirectoryPermissions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not $IsLinux) {
        return
    }
    [IO.File]::SetUnixFileMode(
        $Path,
        (
            [IO.UnixFileMode]::UserRead -bor
            [IO.UnixFileMode]::UserWrite -bor
            [IO.UnixFileMode]::UserExecute
        )
    )
}

function Set-QuickTestOwnerMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $RunId
    )

    $marker = Join-Path $Path '.quicktest-owner'
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw 'The quick-test path exists but is not a directory.'
        }
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
            throw 'The quick-test path already exists without an ownership marker.'
        }
        $existingRunId = (
            Get-Content -LiteralPath $marker -Raw -Encoding utf8
        ).Trim()
        if ($existingRunId -ne $RunId) {
            throw 'The quick-test path is owned by a different run.'
        }
    }
    else {
        [IO.Directory]::CreateDirectory($Path) | Out-Null
    }

    [IO.File]::WriteAllText(
        $marker,
        $RunId + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
}

function Test-QuickTestOwnedDirectory {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $RunId
    )

    $marker = Join-Path $Path '.quicktest-owner'
    return (
        (Test-QuickTestPathWithinRoot -Path $Path -Root $Root) -and
        (Test-Path -LiteralPath $marker -PathType Leaf) -and
        ((Get-Content -LiteralPath $marker -Raw -Encoding utf8).Trim() -eq $RunId)
    )
}
