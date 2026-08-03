#Requires -Version 7.2
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$builderPath = Join-Path $repoRoot 'Private/HyperVImageBuilder.ps1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-image-builder-$([guid]::NewGuid().ToString('N'))"
$isoPath = Join-Path $temporaryRoot 'synthetic.iso'
$evidencePath = Join-Path $temporaryRoot 'generalization-evidence.json'
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
    $ready = & $module { param($Id,$Root) Set-HyperVImageBuildState -BuildId $Id -State BUILDER_READY -Reason test -StateRoot $Root } $plan.buildId $temporaryRoot
    $manual = & $module { param($Id,$Root) Set-HyperVImageBuildManualAction -BuildId $Id -StateRoot $Root } $plan.buildId $temporaryRoot
    Add-CheckResult -Name 'Manual Action besitzt buildgebundene Challenge' -Success ($manual.manualAction.challenge -match '^[a-f0-9-]{36}$')

    $evidence = [PSCustomObject]@{
        contractVersion = '1'; buildId = $manual.buildId; scopeId = $manual.scopeId
        challenge = '00000000-0000-0000-0000-000000000000'; kind = 'synthetic-ci-generalize'
        source = 'synthetic-test'; completedAt = [datetime]::UtcNow.ToString('o')
        checks = [PSCustomObject]@{ sysprepGeneralizeSucceeded = $true; oobeReady = $true; shutdownObserved = $true }
    }
    $evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $evidencePath -Encoding utf8
    $evidenceSha = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash
    $wrongChallengeRejected = $false
    try {
        & $module { param($Id,$Path,$Sha,$Root) Submit-HyperVImageGeneralizationEvidence -BuildId $Id -EvidencePath $Path -ExpectedSha256 $Sha -StateRoot $Root } $plan.buildId $evidencePath $evidenceSha $temporaryRoot | Out-Null
    } catch { $wrongChallengeRejected = $_.Exception.Message -match 'HYPERV_GENERALIZATION_EVIDENCE_POSTCONDITION_FAILED' }
    Add-CheckResult -Name 'Fremde Generalisierungsevidenz wird abgelehnt' -Success $wrongChallengeRejected

    $evidence.challenge = [string]$manual.manualAction.challenge
    $evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $evidencePath -Encoding utf8
    $evidenceSha = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash
    $resumed = & $module { param($Id,$Path,$Sha,$Root) Submit-HyperVImageGeneralizationEvidence -BuildId $Id -EvidencePath $Path -ExpectedSha256 $Sha -StateRoot $Root } $plan.buildId $evidencePath $evidenceSha $temporaryRoot
    Add-CheckResult -Name 'Gueltige Evidenz fuehrt zu RESUME_PENDING' -Success ($resumed.state -eq 'RESUME_PENDING')
    $portableState = Get-Content -LiteralPath (Join-Path $plan.BuildDirectory 'build-state.json') -Raw
    Add-CheckResult -Name 'Evidenz-State enthaelt keinen Quell-Hostpfad' -Success ($portableState -notmatch [regex]::Escape($evidencePath))
    Add-CheckResult -Name 'Reale Publikation bleibt OS_SEALED, CI bleibt test-only' -Success ($builderText -match 'if \(\$synthetic\) \{ ''LIFECYCLE_TEST_ONLY'' \} else \{ ''OS_SEALED'' \}')
    Add-CheckResult -Name 'Sealing darf laufende VM nicht hart ausschalten' -Success ($builderText -match 'Remove-HyperVInstance[^\r\n]+[\s\S]{0,180}-PreserveVhdx\s+-RequireOff')
} catch { Add-CheckResult -Name 'Image-Builder-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally { Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue; if(Test-Path $temporaryRoot){Remove-Item $temporaryRoot -Recurse -Force} }
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if($failures.Count){exit 1}; exit 0
