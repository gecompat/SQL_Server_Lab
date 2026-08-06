#Requires -Version 7.2
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$builderPath = Join-Path $repoRoot 'Private/HyperVSqlImageBuilder.ps1'
$menuPath = Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-sql-image-$([guid]::NewGuid().ToString('N'))"
$mediaRoot = Join-Path $temporaryRoot 'media'
$stateRoot = Join-Path $temporaryRoot 'state'
$isoDirectory = Join-Path $mediaRoot 'SQL/2019/Eval/ISO'
$isoPath = Join-Path $isoDirectory 'SQLServer2019-test.iso'
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Hyper-V SQL Image Builder Checks' -ForegroundColor Cyan

try {
    New-Item -Path $isoDirectory -ItemType Directory -Force | Out-Null
    $bytes = [byte[]]::new(65536); [System.Text.Encoding]::ASCII.GetBytes('CD001').CopyTo($bytes, 32769)
    [System.IO.File]::WriteAllBytes($isoPath, $bytes)
    $module = Import-Module $modulePath -Force -PassThru

    $missing = & $module { param($Root) Resolve-HyperVSqlInstallationMedia -MediaRoot $Root -SqlVersion 2019 -MediaEdition Eval } $mediaRoot
    Add-CheckResult -Name 'SQL-ISO wird aus kanonischem Versions-/Editionspfad aufgeloest' -Success ($missing.IsoPath -eq $isoPath)
    Add-CheckResult -Name 'Fehlendes SQL-Sidecar ist explizit' -Success ($missing.HashStatus -eq 'MISSING')
    $hashed = & $module { param($Root) New-HyperVSqlMediaHashSidecar -MediaRoot $Root -SqlVersion 2019 -MediaEdition Eval } $mediaRoot
    Add-CheckResult -Name 'SQL-Sidecar bindet Hash und relativen Pfad' -Success (
        $hashed.HashStatus -eq 'SIDECAR_READY' -and $hashed.ExpectedSha256 -match '^[a-f0-9]{64}$' -and
        (Get-Content -LiteralPath $hashed.HashPath -Raw) -match 'SQL/2019/Eval/ISO/SQLServer2019-test\.iso'
    )
    $manualHash = & $module {
        param($Root, $Sha)
        Set-HyperVSqlMediaHashSidecar -MediaRoot $Root -SqlVersion 2019 -MediaEdition Eval -ExpectedSha256 $Sha
    } $mediaRoot $hashed.ExpectedSha256
    Add-CheckResult -Name 'Offiziell eingegebener SQL-Hash wird vor dem Sidecar-Schreiben lokal geprüft' -Success (
        $manualHash.HashStatus -eq 'SIDECAR_READY' -and $manualHash.ExpectedSha256 -eq $hashed.ExpectedSha256
    )

    $artifactId = 'hyperv-os-sealed-' + ('a' * 64)
    $plan = & $module {
        param($ArtifactId,$Iso,$Sha,$Root)
        function Get-HyperVImageArtifact {
            [PSCustomObject]@{
                artifactId = $ArtifactId; artifactState = 'OS_SEALED'; sha256 = ('a' * 64)
                operatingSystem = [PSCustomObject]@{
                    id = 'windows-server-2025'; version = '2025'; edition = 'datacenter-evaluation'
                    installationType = 'core'; language = 'en-US'; architecture = 'x64'
                }
                license = [PSCustomObject]@{ type = 'evaluation'; evaluationExpiresAt = [datetime]::UtcNow.AddDays(120).ToString('o') }
            }
        }
        New-HyperVSqlImageBuildPlan -ImageArtifactId $ArtifactId -IsoPath $Iso -ExpectedSha256 $Sha `
            -SqlVersion 2019 -SqlEdition Eval -StateRoot $Root
    } $artifactId $isoPath $hashed.ExpectedSha256 $stateRoot
    Add-CheckResult -Name 'SQL-Build startet mit verifiziertem OS-Artifact und Medium' -Success ($plan.state -eq 'MEDIA_VERIFIED')
    Add-CheckResult -Name 'Cleanup-Plan existiert vor Hyper-V-Mutation' -Success (Test-Path (Join-Path $plan.BuildDirectory 'cleanup-plan.json'))
    $rawState = Get-Content -LiteralPath (Join-Path $plan.BuildDirectory 'build-state.json') -Raw
    Add-CheckResult -Name 'Portabler SQL-Build-State enthaelt keinen ISO-Hostpfad' -Success ($rawState -notmatch [regex]::Escape($isoPath))
    Add-CheckResult -Name 'Evaluation-Ablaufmetadaten werden vom OS-Parent uebernommen' -Success (
        -not [string]::IsNullOrWhiteSpace([string]$plan.parentArtifact.license.evaluationExpiresAt)
    )
    $freshPlan = & $module {
        param($Iso,$Sha,$Root)
        New-HyperVSqlFreshImageBuildPlan -WindowsIsoPath $Iso -ExpectedWindowsSha256 $Sha `
            -OperatingSystemId windows-server-2025 -WindowsEdition standard-evaluation `
            -InstallationType desktop-experience -SqlIsoPath $Iso -ExpectedSqlSha256 $Sha `
            -SqlVersion 2019 -SqlEdition Eval -ImageName 'Testbild SQL 2019' -StateRoot $Root
    } $isoPath $hashed.ExpectedSha256 $stateRoot
    Add-CheckResult -Name 'Fresh-Prepared-Plan startet ohne OS_SEALED-Parent und mit genau einem finalen Sysprep' -Success (
        $freshPlan.provisioningMode -eq 'fresh-windows-media' -and
        $freshPlan.parentArtifact.source -eq 'fresh-windows-media' -and
        $freshPlan.operatingSystem.installationType -eq 'desktop-experience' -and
        $freshPlan.displayName -eq 'Testbild SQL 2019'
    )
    $cleanedUp = & $module {
        param($BuildId,$Root)
        function Invoke-CleanupPlan {
            param($RunDir,$ScopeId)
            [PSCustomObject]@{ Status = 'CLEANUP_SUCCEEDED' }
        }
        function Remove-LabSecrets { param($Path) }
        Remove-HyperVSqlImageBuild -BuildId $BuildId -StateRoot $Root
    } $freshPlan.buildId $stateRoot
    $visiblePlans = & $module { param($Root) @(Get-HyperVSqlImageBuildPlans -StateRoot $Root) } $stateRoot
    $allPlans = & $module { param($Root) @(Get-HyperVSqlImageBuildPlans -StateRoot $Root -IncludeCleanedUp) } $stateRoot
    Add-CheckResult -Name 'Cleanup markiert SQL-Builder terminal und blendet ihn aus der Standardauswahl aus' -Success (
        $cleanedUp.Build.state -eq 'CLEANED_UP' -and
        @($visiblePlans | Where-Object buildId -eq $freshPlan.buildId).Count -eq 0 -and
        @($allPlans | Where-Object { $_.buildId -eq $freshPlan.buildId -and $_.state -eq 'CLEANED_UP' }).Count -eq 1
    )

    $credentialUser = 'sql-image-test-user'; $credentialPassword = 'NeverPersist_SQL_42!'
    $credential = [PSCredential]::new($credentialUser, (ConvertTo-SecureString $credentialPassword -AsPlainText -Force))
    $resumed = & $module {
        param($BuildId,$Root,$Credential)
        $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $Root
        $build.builder = [PSCustomObject]@{ vmName = 'mock-sql-image'; osDiskRelativePath = 'resources/hyperv/mock.vhdx' }
        $build.manualAction = [PSCustomObject]@{ challenge = '11111111-1111-1111-1111-111111111111'; requestedAt = Get-LabTimestamp }
        Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
        $null = Set-HyperVSqlImageBuildState -BuildId $BuildId -State MANUAL_ACTION_REQUIRED -Reason test -StateRoot $Root
        $script:sqlImageMockCall = 0
        function Get-HyperVManagedVM {
            [PSCustomObject]@{ VM = [PSCustomObject]@{ State = if ($script:sqlImageMockCall -ge 2) { 'Off' } else { 'Running' } }; Identity = [PSCustomObject]@{} }
        }
        function Invoke-HyperVPowerShellDirect {
            param($VMName,$ExpectedRunId,$ExpectedScopeId,$Credential,$ScriptBlock,$ArgumentList)
            $script:sqlImageMockCall++
            if ($script:sqlImageMockCall -eq 1) {
                return [PSCustomObject]@{
                    contractVersion = '1'; buildId = $ArgumentList[0]; scopeId = $ArgumentList[1]; challenge = $ArgumentList[2]
                    action = 'PrepareImage'; sqlVersion = '2019'; setupFileVersion = '15.0.2000.5'
                    features = @([string]$ArgumentList[5] -split ','); exitCode = 0; rebootScheduled = $false
                    completedAt = [datetime]::UtcNow.ToString('o')
                }
            }
            return [PSCustomObject]@{
                contractVersion = '1'; buildId = $ArgumentList[0]; scopeId = $ArgumentList[1]; challenge = $ArgumentList[2]
                sysprepExitCode = 0; imageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'; completedAt = [datetime]::UtcNow.ToString('o')
            }
        }
        Invoke-HyperVSqlPrepareAndGeneralize -BuildId $BuildId -Credential $Credential -StateRoot $Root
    } $plan.buildId $stateRoot $credential
    Add-CheckResult -Name 'PrepareImage- und Sysprep-Receipts fuehren zu RESUME_PENDING' -Success (
        $resumed.state -eq 'RESUME_PENDING' -and $resumed.setupEvidence.action -eq 'PrepareImage' -and
        $resumed.generalizationEvidence.shutdownObserved -eq $true
    )
    $resumedRawState = Get-Content -LiteralPath (Join-Path $resumed.BuildDirectory 'build-state.json') -Raw
    Add-CheckResult -Name 'Gast-Credentials werden im SQL-Builder nicht persistiert' -Success (
        $resumedRawState -notmatch [regex]::Escape($credentialUser) -and $resumedRawState -notmatch [regex]::Escape($credentialPassword)
    )

    $builderText = Get-Content -LiteralPath $builderPath -Raw -Encoding utf8
    $menuText = Get-Content -LiteralPath $menuPath -Raw -Encoding utf8
    Add-CheckResult -Name 'SQL Setup verwendet PrepareImage quiet und akzeptiert Lizenzbedingungen' -Success (
        $builderText -match '/ACTION=PrepareImage' -and $builderText -match '/IACCEPTSQLSERVERLICENSETERMS'
    )
    Add-CheckResult -Name 'SQL Setup besitzt ein hartes Timeout' -Success (
        $builderText -match 'WaitForExit\(\$TimeoutSeconds \* 1000\)' -and $builderText -match 'SQL_SETUP_PREPARE_IMAGE_TIMEOUT'
    )
    Add-CheckResult -Name 'Wiederholung nach Sysprep-Fehler startet PrepareImage nicht erneut' -Success (
        $builderText -match 'MANUAL_ACTION_REQUIRED'' -and -not \$build\.setupEvidence'
    )
    Add-CheckResult -Name 'Sysprep-Recovery prueft ausgeschaltete Builder-VHDX offline ohne Gastpasswort' -Success (
        $builderText -match 'function Get-HyperVSqlOfflineImageState' -and
        $builderText -match 'function Get-HyperVSqlSysprepFailureReason' -and
        $builderText -match 'function Resume-HyperVSqlPreparedImageGeneralization' -and
        $builderText -match 'HYPERV_SQL_IMAGE_GENERALIZATION_RECOVERY_INVALID_STATE' -and
        $builderText -match 'WINDOWS_SYSPREP_REARM_LIMIT_REACHED' -and
        $builderText -match 'SysprepDetail' -and
        $menuText -match "'17' \{ Resume-LabHyperVSqlPreparedImageGeneralizationInteractive \}"
    )
    Add-CheckResult -Name 'Sysprep wartet nach /quit auf den finalen Generalize-ImageState' -Success (
        $builderText -match 'stateDeadline = \[datetime\]::UtcNow\.AddSeconds\(120\)' -and
        $builderText -match "IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'\) \{ break \}" -and
        $builderText -match 'Start-Sleep -Seconds 2'
    )
    Add-CheckResult -Name 'PrepareImage-Fehler nennt Exitcode und aktuelle SQL-Setup-Summary' -Success (
        $builderText -match 'SQL_SETUP_PREPARE_IMAGE_FAILED: ExitCode=' -and
        $builderText -match "-Filter 'Summary\.txt'" -and $builderText -match 'Summary=\$\(\$summary\.FullName\)'
    )
    Add-CheckResult -Name 'Editionsmismatch nennt die im Windows-Setup auszuwählende Zielvariante' -Success (
        $builderText -match 'Windows Server 2025 Datacenter Evaluation' -and
        $builderText -match 'Server Core Installation' -and
        $builderText -match 'neu installieren und'
    )
    $sqlSetupVersionsAccepted = & $module {
        $sql2022Pattern = Get-HyperVSqlSetupVersionPattern -SqlVersion 2022
        $sql2025Pattern = Get-HyperVSqlSetupVersionPattern -SqlVersion 2025
        '2022.0160.1000.06 (SQL22_RTM).221008-0913' -match $sql2022Pattern -and
        '16.0.1000.6' -match $sql2022Pattern -and
        '2025.0170.1000.07 (sql2025_rtm).251021-1808' -match $sql2025Pattern -and
        '2022.0160.1000.06' -notmatch $sql2025Pattern
    }
    Add-CheckResult -Name 'SQL-2022- und SQL-2025-Jahresversionen werden als passende Medien erkannt' -Success (
        $sqlSetupVersionsAccepted -and
        $builderText -match 'ExpectedSetupVersionPattern' -and
        $builderText -match 'function Get-HyperVSqlVersionFromMajor' -and
        $builderText -match 'function Get-HyperVSqlInstallationMediaCandidates'
    )
    $dynamicVersionMapping = & $module {
        (Get-HyperVSqlVersionFromMajor -MajorVersion 14) -eq '2017' -and
        (Get-HyperVSqlMajorVersionFromVersion -SqlVersion 2016) -eq 13 -and
        ('13.0.1601.5' -match (Get-HyperVSqlSetupVersionPattern -SqlVersion 2016))
    }
    Add-CheckResult -Name 'Weitere SQL-Versionen werden ueber die aus ISO gelesene Hauptversion dynamisch zugeordnet' -Success $dynamicVersionMapping
    $dynamicEditionMapping = & $module {
        (Get-HyperVSqlMediaEditionFromPath -Path 'SQL/2025/Standard_Developer/ISO/sql.iso') -eq 'Standard' -and
        (Get-HyperVSqlMediaEditionFromPath -Path 'SQL/2022/Developer/ISO/sql.iso') -eq 'Enterprise'
    }
    Add-CheckResult -Name 'Automatische Medienedition bevorzugt Standard vor dem Developer-Zusatz' -Success $dynamicEditionMapping
    $artifactEditionMapping = & $module {
        (ConvertTo-HyperVSqlMediaEdition -SqlEdition EnterpriseDeveloper) -eq 'Enterprise' -and
        (ConvertTo-HyperVSqlMediaEdition -SqlEdition StandardDeveloper) -eq 'Standard' -and
        (ConvertTo-HyperVSqlMediaEdition -SqlEdition Evaluation) -eq 'Eval'
    }
    Add-CheckResult -Name 'Artifact-Produkteditionen werden für die ISO-Suche rückwärtskompatibel abgebildet' -Success $artifactEditionMapping
    Add-CheckResult -Name 'SQL-ISO wird vor der VM-Erstellung gegen die gewaehlte SQL-Version geprueft' -Success (
        $builderText -match 'function Confirm-HyperVSqlInstallationMediaVersion' -and
        $builderText -match 'HYPERV_SQL_MEDIA_VERSION_MISMATCH' -and
        $builderText -match 'Confirm-HyperVSqlInstallationMediaVersion -IsoPath \$sqlMedia\.IsoPath -SqlVersion \$SqlVersion' -and
        $builderText.IndexOf('Confirm-HyperVSqlInstallationMediaVersion -IsoPath $sqlMedia.IsoPath') -lt $builderText.IndexOf('New-VHD -Path $diskPath')
    )
    Add-CheckResult -Name 'SQL-Prepared-Publikation flacht Differencing-Kette ab' -Success ($builderText -match 'Convert-VHD[\s\S]+-VHDType Dynamic')
    Add-CheckResult -Name 'Sonderpfad für frische ISOs erstellt Windows-VHDX und bindet beide ISOs ein' -Success (
        $builderText -match 'function Initialize-HyperVSqlFreshPreparedImageBuild' -and
        $builderText -match 'New-HyperVSqlFreshImageBuildPlan' -and
        $builderText -match 'New-VHD -Path \$diskPath -Dynamic' -and
        $builderText -match 'Add-VMDvdDrive -VM \$vm -Path \$windowsMedia\.IsoPath' -and
        $builderText -match 'Add-VMDvdDrive -VM \$vm -Path \$sqlMedia\.IsoPath' -and
        $menuText -match "'f' \{ New-LabHyperVSqlImageBuildInteractive \}" -and
        $menuText -match 'ein finaler Sysprep'
    )
    Add-CheckResult -Name 'Empfohlener Prepared-Image-Pfad verwendet eine veröffentlichte OS-Baseline als unveränderten Parent' -Success (
        $builderText -match "provisioningMode = 'sealed-os-baseline'" -and
        $builderText -match 'function Initialize-HyperVSqlPreparedImageBuild' -and
        $builderText -match 'New-HyperVInstance -ImageArtifactId \$ImageArtifactId' -and
        $builderText -match '\[ValidateLength\(1, 80\)\]\[string\]\$ImageName' -and
        $menuText -match "'7' \{ New-LabHyperVSqlAcceptanceBuildInteractive \}" -and
        $menuText -match 'OS-Baseline wird wiederverwendet'
    )
    $convertIndex = $builderText.IndexOf('Convert-VHD -Path $childPath')
    $importIndex = $builderText.IndexOf('$artifact = Import-HyperVImageArtifact')
    $removeIndex = $builderText.IndexOf('$null = Remove-HyperVInstance', $importIndex)
    Add-CheckResult -Name 'Flatten, Registry-Import und VM-Cleanup sind transaktional geordnet' -Success (
        $convertIndex -ge 0 -and $importIndex -gt $convertIndex -and $removeIndex -gt $importIndex
    )
    Add-CheckResult -Name 'SQL-Prepared-Artifact traegt SQL-Version, Edition, Build und Features' -Success (
        $builderText -match '-SqlVersion \$build\.sql\.version' -and $builderText -match '-SqlEdition \$build\.sql\.edition' -and
        $builderText -match '-SqlBuild \$build\.sql\.setupBuild' -and $builderText -match '-SqlFeatures @\(\$build\.sql\.features\)'
    )
    Add-CheckResult -Name 'Invoke-SqlServerLab-Image-Menue bietet den SQL-Image-Lifecycle' -Success (
        $menuText -match 'Initialize-HyperVSqlFreshPreparedImageBuild' -and $menuText -match 'Invoke-HyperVSqlPrepareAndGeneralize' -and
        $menuText -match 'Publish-HyperVSqlPreparedImageBuild'
    )
    $imageDeleteFunctionIndex = $menuText.IndexOf('function Remove-LabHyperVImageArtifactInteractive')
    $nextImageMenuFunctionIndex = $menuText.IndexOf('function Select-LabHyperVOsArtifact', $imageDeleteFunctionIndex)
    $imageDeleteFunctionText = if ($imageDeleteFunctionIndex -ge 0 -and $nextImageMenuFunctionIndex -gt $imageDeleteFunctionIndex) {
        $menuText.Substring($imageDeleteFunctionIndex, $nextImageMenuFunctionIndex - $imageDeleteFunctionIndex)
    } else { '' }
    Add-CheckResult -Name 'Image-Loeschauswahl liest die Registry ohne VHDX-Hashing' -Success (
        $imageDeleteFunctionText -match 'Get-HyperVImageArtifact -SkipIntegrityCheck' -and
        $imageDeleteFunctionText -match 'Remove-HyperVImageArtifact'
    )
    Add-CheckResult -Name 'SQL-Builder-Cleanup bietet ALL mit eigener Gesamtbestaetigung' -Success (
        $menuText -match '\[ALL\] Alle \$\(\$builds\.Count\) angezeigten unfertigen SQL-Builder aufraeumen' -and
        $menuText -match 'WIRKLICH ALLE SQL-Builder aufraeumen' -and
        $menuText -match 'Cleanup \$\(\$succeeded \+ \$failed \+ 1\)/\$\(\$builds\.Count\)'
    )
    $nextActionGuidance = & $module {
        @(
            Get-LabHyperVSqlImageNextStep -Build ([PSCustomObject]@{ state = 'RESUME_PENDING'; provisioningMode = 'fresh-windows-media' })
            Get-LabHyperVSqlImageNextStep -Build ([PSCustomObject]@{ state = 'REBOOT_REQUIRED'; provisioningMode = 'fresh-windows-media' })
        )
    }
    Add-CheckResult -Name 'SQL-Image-Status nennt den konkreten naechsten Menuepunkt ohne interne State-Kenntnis' -Success (
        $nextActionGuidance[0] -eq '[11] SQL-Prepared-Image jetzt veroeffentlichen.' -and
        $nextActionGuidance[1] -eq '[9] VM starten, vollstaendig booten lassen; danach [10] erneut ausfuehren.' -and
        $menuText -match '''8''\s*\{\s*\$null\s*=\s*Show-LabHyperVSqlImageBuilds\s*\}' -and
        $menuText -match 'Show-LabHyperVSqlNextActions'
    )
    $prepareFunctionIndex = $menuText.IndexOf('function Invoke-LabHyperVSqlPrepareInteractive')
    $targetBuilderIndex = $menuText.IndexOf('Ziel-Builder: SQL {0} {1} | VM: {2}', $prepareFunctionIndex)
    $credentialPromptIndex = $menuText.IndexOf('Read-Host ''  Lokaler Gast-Administrator [Administrator]''', $prepareFunctionIndex)
    Add-CheckResult -Name 'PrepareImage zeigt vor dem Passwort den fest verdrahteten SQL-Zielbuilder' -Success (
        $prepareFunctionIndex -ge 0 -and $targetBuilderIndex -gt $prepareFunctionIndex -and
        $credentialPromptIndex -gt $targetBuilderIndex -and $menuText -match 'Build-ID: \{0\}'
    )
}
catch { Add-CheckResult -Name 'Hyper-V-SQL-Image-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
