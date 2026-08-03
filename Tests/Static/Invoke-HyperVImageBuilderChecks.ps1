#Requires -Version 7.2
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$builderPath = Join-Path $repoRoot 'Private/HyperVImageBuilder.ps1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-image-builder-$([guid]::NewGuid().ToString('N'))"
$isoPath = Join-Path $temporaryRoot 'synthetic.iso'
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Hyper-V Image Builder Checks' -ForegroundColor Cyan
try {
    New-Item -Path $temporaryRoot -ItemType Directory -Force | Out-Null
    $bytes = [byte[]]::new(65536); [System.Text.Encoding]::ASCII.GetBytes('CD001').CopyTo($bytes, 32769)
    [System.IO.File]::WriteAllBytes($isoPath, $bytes)
    $sha = (Get-FileHash $isoPath -Algorithm SHA256).Hash
    $module = Import-Module $modulePath -Force -PassThru
    $plan = & $module { param($Iso,$Sha,$Root) New-HyperVWindowsImageBuildPlan -IsoPath $Iso -ExpectedSha256 $Sha -OperatingSystemId synthetic-ci -Edition none -InstallationType synthetic -LicenseType test-only -OsDiskSizeBytes 64MB -StateRoot $Root } $isoPath $sha $temporaryRoot
    Add-CheckResult -Name 'Build startet in MEDIA_VERIFIED' -Success ($plan.state -eq 'MEDIA_VERIFIED')
    Add-CheckResult -Name 'Cleanup-Plan existiert vor Provider-Mutation' -Success (Test-Path (Join-Path $plan.BuildDirectory 'cleanup-plan.json'))
    $rawState = Get-Content (Join-Path $plan.BuildDirectory 'build-state.json') -Raw
    Add-CheckResult -Name 'Portabler Build-State enthaelt keinen ISO-Hostpfad' -Success ($rawState -notmatch [regex]::Escape($isoPath))
    $builderText = Get-Content $builderPath -Raw
    Add-CheckResult -Name 'Cleanup-Schritte stehen vor New-VHD' -Success ($builderText -match 'Add-CleanupStep[\s\S]+Add-CleanupStep[\s\S]+New-VHD')
    $notesIndex = $builderText.IndexOf('ConvertTo-HyperVLabNotes')
    $dvdIndex = $builderText.IndexOf('Add-VMDvdDrive')
    Add-CheckResult -Name 'Builder-Identitaet wird vor weiterer VM-Konfiguration gesetzt' -Success ($notesIndex -ge 0 -and $dvdIndex -gt $notesIndex)
    Add-CheckResult -Name 'VM-Konfiguration verwendet keinen tiefen Build-State-Pfad' -Success ($builderText -notmatch 'New-VM[^\r\n]+-Path\s+\$resourceRoot')
    Add-CheckResult -Name 'Builder ist Generation 2 mit Secure Boot' -Success ($builderText -match 'Generation\s+2[\s\S]+EnableSecureBoot\s+On')
    Add-CheckResult -Name 'Builder bindet ISO als DVD ein' -Success ($builderText -match 'Add-VMDvdDrive[\s\S]+FirstBootDevice')
    Add-CheckResult -Name 'Manual Action wird persistent modelliert' -Success ($builderText -match 'MANUAL_ACTION_REQUIRED')
} catch { Add-CheckResult -Name 'Image-Builder-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally { Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue; if(Test-Path $temporaryRoot){Remove-Item $temporaryRoot -Recurse -Force} }
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if($failures.Count){exit 1}; exit 0
