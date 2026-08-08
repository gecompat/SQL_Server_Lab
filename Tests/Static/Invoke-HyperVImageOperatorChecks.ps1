#Requires -Version 7.2
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'

if ($showHelpRequested) {

    Get-Help -Full -Name $PSCommandPath | Out-Host

    return

}

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
    $cleanupPlan = & $module {
        param($Iso, $Sha, $Root)
        New-HyperVWindowsImageBuildPlan -IsoPath $Iso -ExpectedSha256 $Sha -OperatingSystemId windows-server-2025 -Edition standard-evaluation -InstallationType desktop-experience -LicenseType evaluation -OsDiskSizeBytes 64MB -StateRoot $Root
    } $isoPath $hashed.ExpectedSha256 $stateRoot
    $cleanedUp = & $module {
        param($BuildId, $Root)
        function Invoke-CleanupPlan {
            param($RunDir, $ScopeId)
            [PSCustomObject]@{ Status = 'CLEANUP_SUCCEEDED' }
        }
        Remove-HyperVWindowsImageBuild -BuildId $BuildId -StateRoot $Root
    } $cleanupPlan.buildId $stateRoot
    $visiblePlans = @(& $module { param($Root) Get-HyperVImageBuildPlans -StateRoot $Root } $stateRoot)
    $allPlans = @(& $module { param($Root) Get-HyperVImageBuildPlans -StateRoot $Root -IncludeCleanedUp } $stateRoot)
    Add-CheckResult -Name 'Windows-Builder-Cleanup markiert terminal und blendet ihn aus der Standardauswahl aus' -Success (
        $cleanedUp.Build.state -eq 'CLEANED_UP' -and
        @($visiblePlans | Where-Object buildId -eq $cleanupPlan.buildId).Count -eq 0 -and
        @($allPlans | Where-Object { $_.buildId -eq $cleanupPlan.buildId -and $_.state -eq 'CLEANED_UP' }).Count -eq 1
    )
    $manualHash = & $module {
        param($Root, $Sha)
        Set-HyperVWindowsMediaHashSidecar -MediaRoot $Root -OperatingSystemId windows-server-2025 -ExpectedSha256 $Sha
    } $mediaRoot $hashed.ExpectedSha256
    Add-CheckResult -Name 'Offiziell eingegebener Windows-Hash wird vor dem Sidecar-Schreiben lokal geprüft' -Success (
        $manualHash.HashStatus -eq 'SIDECAR_READY' -and $manualHash.ExpectedSha256 -eq $hashed.ExpectedSha256
    )

    $discoveryDirectory = Join-Path $mediaRoot 'OperatingSystems/Client/11/ISO'
    $discoveryIsoPath = Join-Path $discoveryDirectory 'windows-11-auto.iso'
    $legacyServerIsoPath = Join-Path $discoveryDirectory 'Windows_Server_2016_Datacenter_cyg-winsrv2016dc1709en.iso'
    New-Item -Path $discoveryDirectory -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllBytes($discoveryIsoPath, $bytes)
    [System.IO.File]::WriteAllBytes($legacyServerIsoPath, $bytes)
    $discovered = & $module {
        param($Root, $DiscoveryIso)
        function Get-HyperVWindowsInstallationMediaInfo {
            param($IsoPath)
            if ($IsoPath -eq $DiscoveryIso) {
                return [PSCustomObject]@{ OperatingSystemId = 'windows-11'; WindowsEdition = 'enterprise-evaluation'; InstallationType = 'desktop-experience'; ImageName = 'Windows 11 Enterprise Evaluation'; ImageIndex = 2 }
            }
            throw 'test medium ignored'
        }
        @(Get-HyperVWindowsInstallationMediaCandidates -MediaRoot $Root)
    } $mediaRoot $discoveryIsoPath
    Add-CheckResult -Name 'Windows-ISOs werden unabhängig von der Ordnerstruktur dynamisch angeboten' -Success (
        @($discovered | Where-Object { $_.MediaId -eq 'OperatingSystems/Client/11/ISO/windows-11-auto.iso' -and $_.OperatingSystemId -eq 'windows-11' -and $_.WindowsEdition -eq 'enterprise-evaluation' -and $_.InstallationType -eq 'desktop-experience' -and $_.State -eq 'READY' }).Count -eq 1
    )
    $persistentDiscoveryCache = & $module {
        param($Root)
        $cache = @{
            (Join-Path $Root 'OperatingSystems/Client/11/ISO/windows-11-auto.iso') = @([PSCustomObject]@{
                Fingerprint = '1:2'; MediaId = 'OperatingSystems/Client/11/ISO/windows-11-auto.iso'; State = 'READY'
            })
        }
        Save-HyperVMediaDiscoveryCache -MediaRoot $Root -Kind windows -Cache $cache
        $loaded = Get-HyperVMediaDiscoveryCache -MediaRoot $Root -Kind windows
        [PSCustomObject]@{ Exists = (Test-Path -LiteralPath (Join-Path $Root 'Evidence/windows-media-discovery-cache.json')); Count = $loaded.Count; State = [string]$loaded.Values[0][0].State }
    } $mediaRoot
    Add-CheckResult -Name 'Unveränderte Windows-ISOs werden pro Media Root prozessübergreifend aus dem Metadatencache gelesen' -Success (
        $persistentDiscoveryCache.Exists -and $persistentDiscoveryCache.Count -eq 1 -and $persistentDiscoveryCache.State -eq 'READY'
    )
    $sqlPreparedCompatibility = & $module {
        [PSCustomObject]@{
            Server2025 = (Test-HyperVSqlPreparedWindowsMediaCompatibility -OperatingSystemId 'windows-server-2025').Compatible
            Windows11 = (Test-HyperVSqlPreparedWindowsMediaCompatibility -OperatingSystemId 'windows-11').Compatible
        }
    }
    Add-CheckResult -Name 'SQL-Prepared-Workflow überlässt erkannte Windows-Server- und Client-Kombinationen dem Benutzer' -Success (
        $sqlPreparedCompatibility.Server2025 -and $sqlPreparedCompatibility.Windows11
    )

    if ($IsWindows) {
        $parsedMedia = & $module {
            param($Iso)
            function Get-DiskImage { [PSCustomObject]@{ Attached = $false } }
            function Mount-DiskImage { [PSCustomObject]@{ Attached = $true } }
            function Get-Volume { [PSCustomObject]@{ DriveLetter = 'X' } }
            function Test-Path {
                param($LiteralPath, $PathType)
                $LiteralPath -like '*install.wim'
            }
            function Get-Item { [PSCustomObject]@{ FullName = 'X:\sources\install.wim' } }
            function Get-WindowsImage {
                @(
                    [PSCustomObject]@{ ImageName = 'Windows Server 2025 Standard Evaluation (Desktop Experience)'; ImageIndex = 2 },
                    [PSCustomObject]@{ ImageName = 'Windows Server 2025 Datacenter Evaluation'; ImageIndex = 3 },
                    [PSCustomObject]@{ ImageName = 'Windows 11 Enterprise Evaluation'; ImageIndex = 4 },
                    [PSCustomObject]@{ ImageName = 'Windows Server 2016 SERVERSTANDARD'; ImageIndex = 5 },
                    [PSCustomObject]@{ ImageName = 'Windows 11 Enterprise LTSC Evaluation'; ImageIndex = 6 },
                    [PSCustomObject]@{ ImageName = 'Windows Server, version 1709'; ImageDescription = 'Windows Server Datacenter'; EditionId = 'ServerDatacenter'; ImageIndex = 7 }
                )
            }
            function Dismount-DiskImage { }
            @(Get-HyperVWindowsInstallationMediaInfo -IsoPath $Iso)
        } $legacyServerIsoPath
        Add-CheckResult -Name 'Windows-Server-Version bleibt trotz Editions- und Typ-Erkennung erhalten' -Success (
            @($parsedMedia | Where-Object { $_.OperatingSystemId -eq 'windows-server-2025' -and $_.WindowsEdition -eq 'standard-evaluation' -and $_.InstallationType -eq 'desktop-experience' }).Count -eq 1 -and
            @($parsedMedia | Where-Object { $_.OperatingSystemId -eq 'windows-server-2025' -and $_.WindowsEdition -eq 'datacenter-evaluation' -and $_.InstallationType -eq 'core' }).Count -eq 1 -and
            @($parsedMedia | Where-Object { $_.OperatingSystemId -eq 'windows-11' -and $_.WindowsEdition -eq 'enterprise-evaluation' -and $_.InstallationType -eq 'desktop-experience' }).Count -eq 1 -and
            @($parsedMedia | Where-Object { $_.OperatingSystemId -eq 'windows-server-2016' -and $_.WindowsEdition -eq 'standard' -and $_.InstallationType -eq 'desktop-experience' }).Count -eq 1 -and
            @($parsedMedia | Where-Object { $_.OperatingSystemId -eq 'windows-server-2016' -and $_.WindowsEdition -eq 'datacenter' -and $_.InstallationType -eq 'desktop-experience' }).Count -eq 1 -and
            @($parsedMedia | Where-Object { $_.OperatingSystemId -eq 'windows-11' -and $_.WindowsEdition -eq 'enterprise-ltsc-evaluation' }).Count -eq 1
        )
    }
    else {
        Add-CheckResult -Name 'Windows-Server-Medienanalyse wird auf Nicht-Windows korrekt übersprungen' -Success $true
    }

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
    $prerequisiteText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVPrerequisites.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Image-Einstieg bietet sichere Hyper-V-Installation inklusive Tools und Reboot-Hinweis' -Success (
        $menuText -match 'Install-LabHyperVPrerequisites' -and
        $menuText -match 'RestartRequired' -and
        $prerequisiteText -match 'Install-WindowsFeature -Name Hyper-V -IncludeManagementTools' -and
        $prerequisiteText -match 'Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All' -and
        $prerequisiteText -match '-NoRestart'
    )
    Add-CheckResult -Name 'VMConnect wird vor dem ersten VM-Start geoeffnet' -Success (
        $menuText -match 'Open-LabHyperVImageBuildConsole[\s\S]{0,180}Start-Sleep[\s\S]{0,180}Start-HyperVWindowsImageBuildVM'
    )
    Add-CheckResult -Name 'Image-Untermenue bleibt nach Aktionen geoeffnet und verlaesst sich nur mit 0' -Success (
        $menuText -match '\$exitImageMenu = \$false' -and
        $menuText -match 'while \(-not \$exitImageMenu\)' -and
        $menuText -match '''0''\s*\{\s*\$exitImageMenu\s*=\s*\$true\s*\}'
    )
    Add-CheckResult -Name 'Kompaktes Hyper-V-Hauptmenü bietet reine Windows- und SQL-Labs aus Vorlagen an' -Success (
        $menuText -match '\[3\] Neue Hyper-V-Umgebung aus Windows- oder SQL-Vorlage erstellen' -and
        $menuText -match 'New-LabHyperVEnvironmentInteractive' -and
        $menuText -match 'Manage-LabHyperVEnvironmentInteractive' -and
        $menuText -match 'New-HyperVLabEnvironment' -and
        $menuText -match 'Open-HyperVLabEnvironmentConsole'
    )
    Add-CheckResult -Name 'Reguläre Hyper-V-Labs verwenden standardmäßig den verwalteten Switch und erlauben bewusste Isolation' -Success (
        $menuText -match 'function Select-LabHyperVVirtualSwitch' -and
        $menuText -match 'Get-VMSwitch -ErrorAction Stop' -and
        $menuText -match 'Verwalteter SQL_Server_Lab-Internal-Switch' -and
        $menuText -match '\[0\] Kein Switch = bewusst isoliert' -and
        @($menuText | Select-String -Pattern 'Select-LabHyperVVirtualSwitch' -AllMatches).Matches.Count -ge 3
    )
    Add-CheckResult -Name 'Erfolgreiche Hyper-V-Laberstellung meldet den nächsten Schritt ohne ungültigen Inline-if-Aufruf' -Success (
        $menuText -notmatch 'Write-LabInfo\s+\(if\s*\('
    )
    Add-CheckResult -Name 'Untermenü-Aktionen leeren die Konsole vor ihrer Ausgabe' -Success (
        $menuText -match 'function Show-LabHyperVMenuActionHeader' -and
        $menuText -match 'function Invoke-LabHyperVMenuAction' -and
        $menuText -match 'Show-LabHyperVMenuActionHeader[\s\S]{0,180}\[Enter\] für Menü' -and
        $menuText -match "'1' \{ Invoke-LabHyperVMenuAction -Title 'Neues SQL-Prepared-Image'" -and
        @($menuText | Select-String -Pattern 'while \(-not \$exitMenu\) \{\s*Clear-Host' -AllMatches).Matches.Count -ge 5
    )
    Add-CheckResult -Name 'Windows-Builder-Cleanup bietet ALL mit eigener Gesamtbestaetigung' -Success (
        $menuText -match '\[ALL\] Alle \$\(\$builds\.Count\) angezeigten unfertigen Windows-Builder aufraeumen' -and
        $menuText -match 'WIRKLICH ALLE Windows-Builder aufraeumen' -and
        $menuText -match 'Remove-HyperVWindowsImageBuild -BuildId \$candidate\.buildId'
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



