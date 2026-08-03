#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den externen Media-Root-Initializer ohne reale Medien.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$initializer = Join-Path $repoRoot 'Tools/Initialize-SqlServerLabMediaRoot.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-media-root-check-$([guid]::NewGuid().ToString('N'))"
$pass = 0
$fail = 0

function Assert-Check {
    param([string]$Name, [bool]$Condition)
    if ($Condition) {
        $script:pass++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    }
    else {
        $script:fail++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
    }
}

try {
    $initial = & $initializer -RootPath $testRoot
    foreach ($relativePath in @(
        'Incoming',
        'Linux/ISO',
        'Linux/VHDX',
        'SQL/Installers/2025',
        'SQL/2022/Eval/ISO',
        'WindowsServer/2025/Eval/ISO',
        'WindowsServer/2025/Eval/VHDX',
        'Hashes',
        'Evidence',
        'Exports'
    )) {
        Assert-Check "Layout enthaelt $relativePath" (Test-Path -LiteralPath (Join-Path $testRoot $relativePath) -PathType Container)
    }

    foreach ($relativePath in @(
        'README.md',
        'Incoming/README.md',
        'Linux/ISO/README.md',
        'Linux/VHDX/README.md',
        'SQL/Installers/2019/README.md',
        'SQL/2022/Eval/ISO/README.md',
        'SQL/2025/Enterprise/ISO/README.md',
        'WindowsServer/2022/Eval/ISO/README.md',
        'WindowsServer/2025/Eval/VHDX/README.md',
        'Hashes/README.md',
        'Evidence/README.md',
        'Exports/README.md'
    )) {
        Assert-Check "Download-Hilfe enthaelt $relativePath" (Test-Path -LiteralPath (Join-Path $testRoot $relativePath) -PathType Leaf)
    }
    Assert-Check 'Receipt meldet automatisch erzeugte READMEs' (@($initial.CreatedReadmeFiles).Count -ge 18)

    $rootReadme = Get-Content -LiteralPath (Join-Path $testRoot 'README.md') -Raw -Encoding utf8
    Assert-Check 'Root-README nennt den konfigurierten Media Root' ($rootReadme -match [regex]::Escape($testRoot))
    $linuxReadme = Get-Content -LiteralPath (Join-Path $testRoot 'Linux/ISO/README.md') -Raw -Encoding utf8
    Assert-Check 'Linux-README verweist auf die offizielle Ubuntu-Seite' ($linuxReadme -match 'https://ubuntu\.com/download/server')
    $windowsReadme = Get-Content -LiteralPath (Join-Path $testRoot 'WindowsServer/2025/Eval/ISO/README.md') -Raw -Encoding utf8
    Assert-Check 'Windows-README verweist auf das Microsoft Evaluation Center' ($windowsReadme -match 'https://www\.microsoft\.com/en-us/evalcenter/download-windows-server-2025')

    Set-Content -LiteralPath (Join-Path $testRoot 'SQL2025-SSEI-StdDev.exe') -Value 'sql-installer' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $testRoot 'Linux/ubuntu-test.iso') -Value 'linux-iso' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $testRoot 'SQL/2022/Eval/sql-test.iso') -Value 'sql-iso' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $testRoot 'WindowsServer/2025/Eval/windows-test.iso') -Value 'windows-iso' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $testRoot 'WindowsServer/2025/Eval/windows-test.vhdx') -Value 'windows-vhdx' -Encoding ascii

    $result = & $initializer -RootPath $testRoot -OrganizeExisting -GenerateSha256
    Assert-Check 'SQL-Installer wird nach Version einsortiert' (Test-Path -LiteralPath (Join-Path $testRoot 'SQL/Installers/2025/SQL2025-SSEI-StdDev.exe'))
    Assert-Check 'Linux-ISO wird einsortiert' (Test-Path -LiteralPath (Join-Path $testRoot 'Linux/ISO/ubuntu-test.iso'))
    Assert-Check 'SQL-ISO wird einsortiert' (Test-Path -LiteralPath (Join-Path $testRoot 'SQL/2022/Eval/ISO/sql-test.iso'))
    Assert-Check 'Windows-ISO wird einsortiert' (Test-Path -LiteralPath (Join-Path $testRoot 'WindowsServer/2025/Eval/ISO/windows-test.iso'))
    Assert-Check 'Windows-VHDX wird einsortiert' (Test-Path -LiteralPath (Join-Path $testRoot 'WindowsServer/2025/Eval/VHDX/windows-test.vhdx'))
    Assert-Check 'Receipt meldet verschobene Dateien' (@($result.MovedFiles).Count -eq 5)
    Assert-Check 'SHA-256-Sidecars werden erzeugt' (@($result.HashFiles).Count -eq 5)
    Assert-Check 'Hash folgt der relativen Medienstruktur' (Test-Path -LiteralPath (Join-Path $testRoot 'Hashes/Linux/ISO/ubuntu-test.iso.sha256'))

    $second = & $initializer -RootPath $testRoot -OrganizeExisting -GenerateSha256
    Assert-Check 'Wiederholter Lauf ist idempotent' (
        @($second.MovedFiles).Count -eq 0 -and
        @($second.HashFiles).Count -eq 0 -and
        @($second.CreatedReadmeFiles).Count -eq 0 -and
        @($second.SkippedReadmeFiles).Count -eq 0
    )

    $customReadmePath = Join-Path $testRoot 'Incoming/README.md'
    Set-Content -LiteralPath $customReadmePath -Value '# Operator-Hinweis' -Encoding utf8NoBOM
    $protected = & $initializer -RootPath $testRoot 3>$null
    Assert-Check 'Abweichende Anwender-README wird nicht ueberschrieben' (
        (Get-Content -LiteralPath $customReadmePath -Raw -Encoding utf8).Trim() -eq '# Operator-Hinweis'
    )
    Assert-Check 'Receipt meldet geschuetzte abweichende README' (@($protected.SkippedReadmeFiles) -contains $customReadmePath)

    $repositoryRejected = $false
    try {
        $null = & $initializer -RootPath $repoRoot
    }
    catch {
        $repositoryRejected = $_.Exception.Message -match 'MEDIA_ROOT_INSIDE_REPOSITORY'
    }
    Assert-Check 'Repository kann nicht als Media Root verwendet werden' $repositoryRejected
}
finally {
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    if ($resolvedTestRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

Write-Host "`nErgebnis: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 }
