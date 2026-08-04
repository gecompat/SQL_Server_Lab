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
    $sql2025SetupVersionAccepted = & $module {
        $pattern = Get-HyperVSqlSetupVersionPattern -SqlVersion 2025
        '2025.0170.1000.07 (sql2025_rtm).251021-1808' -match $pattern -and
        '16.0.1000.6' -notmatch $pattern
    }
    Add-CheckResult -Name 'SQL-2025-RTM-Jahresversion wird als SQL-2025-Medium erkannt' -Success (
        $sql2025SetupVersionAccepted -and
        $builderText -match 'ExpectedSetupVersionPattern' -and
        $builderText -notmatch "'2025' \{ '17\.' \}"
    )
    Add-CheckResult -Name 'SQL-Prepared-Publikation flacht Differencing-Kette ab' -Success ($builderText -match 'Convert-VHD[\s\S]+-VHDType Dynamic')
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
        $menuText -match 'Initialize-HyperVSqlPreparedImageBuild' -and $menuText -match 'Invoke-HyperVSqlPrepareAndGeneralize' -and
        $menuText -match 'Publish-HyperVSqlPreparedImageBuild'
    )
}
catch { Add-CheckResult -Name 'Hyper-V-SQL-Image-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
