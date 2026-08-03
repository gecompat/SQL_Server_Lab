#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$menuPath = Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1'
$entryPath = Join-Path $repoRoot 'Invoke-SqlServerLab.ps1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-image-operator-$([guid]::NewGuid().ToString('N'))"
$mediaRoot = Join-Path $temporaryRoot 'media'
$stateRoot = Join-Path $temporaryRoot 'state'
$isoDirectory = Join-Path $mediaRoot 'WindowsServer/2025/Eval/ISO'
$isoPath = Join-Path $isoDirectory 'windows-server-2025-test.iso'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Hyper-V Image Operator Checks' -ForegroundColor Cyan

try {
    New-Item -Path $isoDirectory -ItemType Directory -Force | Out-Null
    $bytes = [byte[]]::new(65536)
    [System.Text.Encoding]::ASCII.GetBytes('CD001').CopyTo($bytes, 32769)
    [System.IO.File]::WriteAllBytes($isoPath, $bytes)
    $module = Import-Module $modulePath -Force -PassThru

    $missing = & $module {
        param($Root)
        Resolve-HyperVWindowsInstallationMedia -MediaRoot $Root -OperatingSystemId windows-server-2025
    } $mediaRoot
    Add-CheckResult -Name 'Kanonische Windows-ISO wird eindeutig aufgeloest' -Success ($missing.IsoPath -eq $isoPath)
    Add-CheckResult -Name 'Fehlendes SHA-256-Sidecar wird sichtbar' -Success ($missing.HashStatus -eq 'MISSING' -and -not $missing.ExpectedSha256)

    $hashed = & $module {
        param($Root)
        New-HyperVWindowsMediaHashSidecar -MediaRoot $Root -OperatingSystemId windows-server-2025
    } $mediaRoot
    Add-CheckResult -Name 'Einzelnes ISO-Sidecar wird erzeugt' -Success (Test-Path -LiteralPath $hashed.HashPath -PathType Leaf)
    Add-CheckResult -Name 'Sidecar bindet SHA-256 und relativen Pfad' -Success (
        $hashed.HashStatus -eq 'SIDECAR_READY' -and
        $hashed.ExpectedSha256 -match '^[a-f0-9]{64}$' -and
        (Get-Content -LiteralPath $hashed.HashPath -Raw) -match 'WindowsServer/2025/Eval/ISO/windows-server-2025-test\.iso'
    )

    $plan = & $module {
        param($Iso, $Sha, $Root)
        New-HyperVWindowsImageBuildPlan -IsoPath $Iso -ExpectedSha256 $Sha `
            -OperatingSystemId windows-server-2025 -Edition standard-evaluation `
            -InstallationType desktop-experience -LicenseType evaluation `
            -OsDiskSizeBytes 64MB -StateRoot $Root
    } $isoPath $hashed.ExpectedSha256 $stateRoot
    $plans = @(& $module { param($Root) Get-HyperVImageBuildPlans -StateRoot $Root } $stateRoot)
    Add-CheckResult -Name 'Persistente Build-Plaene werden aufgelistet' -Success ($plans.Count -eq 1 -and $plans[0].buildId -eq $plan.buildId)

    $manual = & $module {
        param($BuildId, $Root)
        $build = Set-HyperVImageBuildState -BuildId $BuildId -State BUILDER_READY -Reason test -StateRoot $Root
        $build.builder = [PSCustomObject]@{
            vmName = 'mock-core-builder'
            osDiskRelativePath = 'resources/hyperv/mock-core.vhdx'
            generation = 2
            secureBoot = $true
        }
        Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
        Set-HyperVImageBuildManualAction -BuildId $BuildId -StateRoot $Root
    } $plan.buildId $stateRoot
    $credentialUser = 'operator-test-user'
    $credentialPassword = 'NeverPersist_42!'
    $credential = [PSCredential]::new(
        $credentialUser,
        (ConvertTo-SecureString $credentialPassword -AsPlainText -Force)
    )
    $typeMismatchRejected = & $module {
        param($BuildId, $Root, $Credential)
        function Invoke-HyperVPowerShellDirect {
            param($VMName,$ExpectedRunId,$ExpectedScopeId,$Credential,$ScriptBlock,$ArgumentList)
            [PSCustomObject]@{
                contractVersion = '1'; buildId = $ArgumentList[0]; scopeId = $ArgumentList[1]
                productName = 'Windows Server 2025 Standard Evaluation'
                editionId = 'ServerStandardEvalCor'; installationType = 'Server Core'
                currentBuild = '26100'; displayVersion = '24H2'; computerName = 'MOCK-CORE'
                observedAt = [datetime]::UtcNow.ToString('o')
            }
        }
        try {
            Confirm-HyperVWindowsImageInstallation -BuildId $BuildId -Credential $Credential -StateRoot $Root | Out-Null
            $false
        }
        catch { $_.Exception.Message -match 'HYPERV_IMAGE_INSTALLATION_TYPE_MISMATCH' }
    } $manual.buildId $stateRoot $credential
    Add-CheckResult -Name 'Core-/Desktop-Abweichung wird nicht still akzeptiert' -Success $typeMismatchRejected

    $accepted = & $module {
        param($BuildId, $Root, $Credential)
        function Invoke-HyperVPowerShellDirect {
            param($VMName,$ExpectedRunId,$ExpectedScopeId,$Credential,$ScriptBlock,$ArgumentList)
            [PSCustomObject]@{
                contractVersion = '1'; buildId = $ArgumentList[0]; scopeId = $ArgumentList[1]
                productName = 'Windows Server 2025 Standard Evaluation'
                editionId = 'ServerStandardEvalCor'; installationType = 'Server Core'
                currentBuild = '26100'; displayVersion = '24H2'; computerName = 'MOCK-CORE'
                observedAt = [datetime]::UtcNow.ToString('o')
            }
        }
        Confirm-HyperVWindowsImageInstallation -BuildId $BuildId -Credential $Credential `
            -AcceptDetectedInstallationType -StateRoot $Root
    } $manual.buildId $stateRoot $credential
    Add-CheckResult -Name 'Explizit akzeptierter Gastnachweis korrigiert Metadaten auf Core' -Success (
        $accepted.operatingSystem.installationType -eq 'core' -and
        $accepted.installationEvidence.verified -eq $true -and
        $accepted.installationEvidence.metadataAdjusted -eq $true
    )
    $acceptedRawState = Get-Content -LiteralPath (Join-Path $accepted.BuildDirectory 'build-state.json') -Raw
    Add-CheckResult -Name 'Gast-Credentials werden beim Installationsnachweis nicht persistiert' -Success (
        $acceptedRawState -notmatch [regex]::Escape($credentialUser) -and
        $acceptedRawState -notmatch [regex]::Escape($credentialPassword)
    )

    Set-Content -LiteralPath $hashed.HashPath `
        -Value "$($hashed.ExpectedSha256)  WindowsServer/2022/Eval/ISO/fremd.iso" `
        -Encoding utf8NoBOM
    $pathMismatchRejected = $false
    try {
        & $module {
            param($Root)
            Resolve-HyperVWindowsInstallationMedia -MediaRoot $Root -OperatingSystemId windows-server-2025
        } $mediaRoot | Out-Null
    }
    catch { $pathMismatchRejected = $_.Exception.Message -match 'HYPERV_WINDOWS_MEDIA_HASH_PATH_MISMATCH' }
    Add-CheckResult -Name 'Sidecar fuer fremden Pfad wird abgelehnt' -Success $pathMismatchRejected

    Remove-Item -LiteralPath $hashed.HashPath -Force
    Copy-Item -LiteralPath $isoPath -Destination (Join-Path $isoDirectory 'zweite.iso')
    $ambiguousRejected = $false
    try {
        & $module {
            param($Root)
            Resolve-HyperVWindowsInstallationMedia -MediaRoot $Root -OperatingSystemId windows-server-2025
        } $mediaRoot | Out-Null
    }
    catch { $ambiguousRejected = $_.Exception.Message -match 'HYPERV_WINDOWS_MEDIA_AMBIGUOUS' }
    Add-CheckResult -Name 'Mehrere ISOs werden nicht geraten' -Success $ambiguousRejected

    $menuText = Get-Content -LiteralPath $menuPath -Raw -Encoding utf8
    $entryText = Get-Content -LiteralPath $entryPath -Raw -Encoding utf8
    Add-CheckResult -Name 'Hauptmenue bietet Hyper-V-Image-Verwaltung an' -Success ($menuText -match "'i'\s*\{\s*Invoke-LabAction\s+-ActionName\s+'Image'")
    Add-CheckResult -Name 'Direkt-Aktion Image ist am Einstieg erlaubt' -Success ($entryText -match "ValidateSet\([^\)]*'Image'")
    Add-CheckResult -Name 'Menue dokumentiert den manuellen Installationsschritt' -Success ($menuText -match 'Show-LabHyperVManualInstallInstructions')
    Add-CheckResult -Name 'Menue besitzt Generalisierung und Publikation' -Success (
        $menuText -match 'Invoke-HyperVWindowsImageGeneralization' -and
        $menuText -match 'Publish-HyperVWindowsImageBuild'
    )
    Add-CheckResult -Name 'VMConnect wird vor dem ersten VM-Start geoeffnet' -Success (
        $menuText -match 'Open-LabHyperVImageBuildConsole[\s\S]{0,180}Start-Sleep[\s\S]{0,180}Start-HyperVWindowsImageBuildVM'
    )
}
catch {
    Add-CheckResult -Name 'Image-Operator-Testausfuehrung' -Success $false -Message $_.Exception.Message
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
    if ($resolvedTemporaryRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTemporaryRoot)) {
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }
exit 0
