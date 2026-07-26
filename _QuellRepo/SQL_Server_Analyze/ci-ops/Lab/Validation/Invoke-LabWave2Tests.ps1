[CmdletBinding()]
param(
    [Parameter()]
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path (
    $RepositoryRoot
) 'Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psd1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

try {
    foreach ($functionName in @(
            'Invoke-LabUp',
            'Invoke-LabScenario',
            'Test-LabScenario'
        )) {
        if ($null -eq (Get-Command $functionName -ErrorAction SilentlyContinue)) {
            throw "Required Welle 2 function is missing: $functionName"
        }
    }

    $exampleLock = Get-Content `
        -LiteralPath (Join-Path (
            $RepositoryRoot
        ) 'Lab/Config/image-lock.example.json') `
        -Raw `
        -Encoding utf8 |
        ConvertFrom-Json -Depth 20
    $image = @($exampleLock.Images) |
        Where-Object {
            $_.LogicalImageId -eq 'SQL_SERVER_2025_DEVELOPER_LINUX'
        } |
        Select-Object -First 1
    if (
        $null -eq $image -or
        $image.ReadableReference -notmatch
        '^mcr\.microsoft\.com/mssql/server:2025-[A-Za-z0-9._-]+$' -or
        $image.Status -ne 'UNRESOLVED_EXAMPLE'
    ) {
        throw 'The public image-lock example boundary is invalid.'
    }

    $waveTwoValidator = Join-Path (
        $RepositoryRoot
    ) 'Code/Tests/Static/990_Validate_LAB001_Wave2_ContainerBaseline.py'
    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        $python = Get-Command python -ErrorAction Stop
    }
    & $python.Source $waveTwoValidator --repository-root $RepositoryRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Welle 2 static validation failed with exit code $LASTEXITCODE."
    }
}
finally {
    Remove-Module -Name DiagnosticLab -Force -ErrorAction SilentlyContinue
}

Write-Output 'LAB-001 Welle 2 PowerShell contract tests passed.'
