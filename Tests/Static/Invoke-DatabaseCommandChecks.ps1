#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$password = [Security.SecureString]::new()
foreach ($character in 'Synthetic_Contract1!'.ToCharArray()) { $password.AppendChar($character) }
$password.MakeReadOnly()

function Assert-DatabaseContract {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Description)
    if (-not $Condition) { throw "DATABASE_COMMAND_CHECK_FAILED: $Description" }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

try {
    & $module {
        $script:DatabaseCommandQueries = @()
        $script:DatabaseCommandOriginalQuery = (Get-Command Invoke-SqlQuery -ErrorAction Stop).ScriptBlock
        Set-Item Function:Invoke-SqlQuery -Value {
            param($HostName,$Port,$SaPlain,$Query,$TimeoutSeconds)
            $script:DatabaseCommandQueries += [string]$Query
        }
    }

    New-SqlServerLabDatabase -HostName 127.0.0.1 -Port 1433 -SaPassword $password -DatabaseName WindowsPathContract `
        -DataFiles @([PSCustomObject]@{ name='WindowsPath_Data'; path='E:\SQLData\WindowsPath_Data.mdf'; sizeMB=8; filegrowthMB=8 }) `
        -LogFiles @([PSCustomObject]@{ name='WindowsPath_Log'; path='L:\SQLLog\WindowsPath_Log.ldf'; sizeMB=8; filegrowthMB=8 }) | Out-Null
    $windowsQuery = & $module { $script:DatabaseCommandQueries -join "`n" }
    Assert-DatabaseContract ($windowsQuery -match [regex]::Escape("E:\SQLData\WindowsPath_Data.mdf")) 'Absoluter Windows-Datenpfad wird in CREATE DATABASE uebernommen'
    Assert-DatabaseContract ($windowsQuery -match [regex]::Escape("L:\SQLLog\WindowsPath_Log.ldf")) 'Absoluter Windows-Logpfad wird in CREATE DATABASE uebernommen'

    $rejected = $false
    try {
        New-SqlServerLabDatabase -Port 1433 -SaPassword $password -DatabaseName RelativePathContract `
            -DataFiles @([PSCustomObject]@{ name='Relative_Data'; path='relative\data.mdf'; sizeMB=8; filegrowthMB=8 }) | Out-Null
    }
    catch { $rejected = $_.Exception.Message -match 'absoluter Linux- oder Windows-SQL-Pfad' }
    Assert-DatabaseContract $rejected 'Relative SQL-Dateipfade bleiben fail-closed'
}
finally {
    & $module {
        if ($script:DatabaseCommandOriginalQuery) {
            Set-Item Function:Invoke-SqlQuery -Value $script:DatabaseCommandOriginalQuery
        }
        Remove-Variable DatabaseCommandQueries,DatabaseCommandOriginalQuery -Scope Script -ErrorAction SilentlyContinue
    }
}

Write-Host 'DATABASE COMMAND CHECKS: PASS' -ForegroundColor Green
