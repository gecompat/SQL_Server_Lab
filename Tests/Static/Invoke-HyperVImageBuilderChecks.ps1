#Requires -Version 7.2
[CmdletBinding()] param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'

if ($showHelpRequested) {

    Get-Help -Full -Name $PSCommandPath | Out-Host

    return

}
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
    $operatorText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVImageOperator.ps1') -Raw
    $plan = & $module { param($Iso,$Sha,$Root) New-HyperVWindowsImageBuildPlan -IsoPath $Iso -ExpectedSha256 $Sha -OperatingSystemId synthetic-ci -Edition none -InstallationType synthetic -LicenseType test-only -OsDiskSizeBytes 64MB -StateRoot $Root } $isoPath $sha $temporaryRoot
    Add-CheckResult -Name 'Build startet in MEDIA_VERIFIED' -Success ($plan.state -eq 'MEDIA_VERIFIED')
    Add-CheckResult -Name 'Windows-Build persistiert den initialen Leertastenvertrag' -Success ($plan.media.bootInteraction.initialMediaKey -eq 'space')
    Add-CheckResult -Name 'Virtuelle Tastatur wird ohne sprachabhängigen CIM-Caption-Filter aufgelöst' -Success (
        $operatorText -match '-Filter "ElementName=''\$escapedVmName''"' -and
        $operatorText -notmatch "Caption='Virtual Machine'"
    )
    $noInputPlan = & $module { param($Iso,$Sha,$Root) New-HyperVWindowsImageBuildPlan -IsoPath $Iso -ExpectedSha256 $Sha -OperatingSystemId synthetic-ci -Edition none -InstallationType synthetic -LicenseType test-only -InitialMediaKey none -OsDiskSizeBytes 64MB -StateRoot $Root } $isoPath $sha (Join-Path $temporaryRoot 'no-input-plan')
    Add-CheckResult -Name 'Installationsmedium kann Tastatureingaben explizit deaktivieren' -Success ($noInputPlan.media.bootInteraction.initialMediaKey -eq 'none')
    $mediaCatalog = & $module { Get-LabMediaSourceCatalog }
    Add-CheckResult -Name 'Medienkatalog trennt Windows-Leertaste und Linux ohne Eingabe' -Success (
        @($mediaCatalog | Where-Object { $_.Category -like 'Windows*' -and $_.BootInteraction.InitialMediaKey -ne 'space' }).Count -eq 0 -and
        @($mediaCatalog | Where-Object { $_.Id -eq 'ubuntu-server' -and $_.BootInteraction.InitialMediaKey -eq 'none' }).Count -eq 1
    )
    Add-CheckResult -Name 'Medienkatalog verweist für Windows Server auf konkrete aktuelle Evaluation-Downloads' -Success (
        @($mediaCatalog | Where-Object {
            $_.Id -eq 'windows-server-evaluation' -and
            $_.Url -eq 'https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025' -and
            $_.TargetRelativePath -eq 'WindowsServer/2025/Eval/ISO'
        }).Count -eq 1 -and
        @($mediaCatalog | Where-Object {
            $_.Id -eq 'windows-server-2022-evaluation' -and
            $_.Url -eq 'https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022' -and
            $_.TargetRelativePath -eq 'WindowsServer/2022/Eval/ISO'
        }).Count -eq 1 -and
        @($mediaCatalog | Where-Object { $_.Url -match '/evalcenter/evaluate-windows-server$' }).Count -eq 0
    )
    $sqlMedia = @($mediaCatalog | Where-Object { $_.Id -like 'sql-server-*' -and $_.Id -ne 'sql-server-downloads' })
    Add-CheckResult -Name 'SQL-Medienkatalog bindet alle automatischen Downloads an Größe und SHA-256' -Success (
        $sqlMedia.Count -ge 25 -and
        @($sqlMedia | Where-Object { $_.Automatable -and (-not $_.ExpectedBytes -or -not $_.ExpectedSha256 -or -not $_.DownloadUrl) }).Count -eq 0
    )
    Add-CheckResult -Name 'SQL-2025-Express-Quelle ist der verifizierte Microsoft-2025-Link' -Success (
        @($sqlMedia | Where-Object {
            $_.Id -eq 'sql-server-2025-express-bootstrapper' -and
            $_.DownloadUrl -eq 'https://download.microsoft.com/download/7ab8f535-7eb8-4b16-82eb-eca0fa2d38f3/SQL2025-SSEI-Expr.exe' -and
            $_.ExpectedSha256 -eq '1c677a33b318481c3217128835f8405cf0026621dcd04b13eb6cb0982e823f27'
        }).Count -eq 1
    )
    Add-CheckResult -Name 'Historische Archivquellen und manuelle Lizenzlücken sind explizit getrennt' -Success (
        @($sqlMedia | Where-Object { $_.Version -in @('2008','2005','2000') -and $_.Acquisition -eq 'ARCHIVE_FALLBACK_VERIFIED' }).Count -eq 4 -and
        @($sqlMedia | Where-Object { $_.Version -in @('7.0','6.5') -and -not $_.Automatable -and $_.Acquisition -eq 'MANUAL_LICENSED_MEDIA' }).Count -eq 2
    )
    $archivedWindowsMedia = @($mediaCatalog | Where-Object { $_.Id -in @(
        'windows-server-2008r2-sp1-evaluation-iso',
        'windows-server-2012r2-evaluation-iso'
    ) })
    Add-CheckResult -Name 'Historische Windows-Evaluationen sind als maschinenlesbare Archive.org-Quellen gebunden' -Success (
        $archivedWindowsMedia.Count -eq 2 -and
        @($archivedWindowsMedia | Where-Object {
            $_.Category -ne 'Windows Server' -or
            $_.Acquisition -ne 'ARCHIVE_FALLBACK_VERIFIED' -or
            -not $_.ArchiveIdentifier -or
            $_.ArchiveMetadataUrl -notlike 'https://archive.org/metadata/*' -or
            -not $_.ExpectedBytes -or
            -not $_.ExpectedSha256 -or
            -not $_.ExpectedSha1 -or
            $_.BootInteraction.InitialMediaKey -ne 'space'
        }).Count -eq 0
    )
    $windowsServer2003Sp2ToolsMedia = @($mediaCatalog | Where-Object {
        $_.Id -eq 'windows-server-2003-sp2-x86-tools-iso'
    })
    Add-CheckResult -Name 'Windows-Server-2003-SP2-Deployment-Tools sind direkt und hashgebunden verfügbar' -Success (
        $windowsServer2003Sp2ToolsMedia.Count -eq 1 -and
        $windowsServer2003Sp2ToolsMedia[0].Category -eq 'Windows Server' -and
        $windowsServer2003Sp2ToolsMedia[0].Acquisition -eq 'DIRECT_MICROSOFT_DOWNLOAD' -and
        $windowsServer2003Sp2ToolsMedia[0].SourceStatus -eq 'ACTIVE' -and
        $windowsServer2003Sp2ToolsMedia[0].DownloadUrl -eq 'https://download.microsoft.com/download/7/3/7/737d5061-be37-4d02-a67c-70569e75584b/w2k3sp2_3959_usa_x86fre_spcd.iso' -and
        $windowsServer2003Sp2ToolsMedia[0].ExpectedBytes -eq 548630528 -and
        $windowsServer2003Sp2ToolsMedia[0].ExpectedSha256 -eq '30cbd649cfd879bc35a94c41366380d64b5c1745393bcf5604390d3ce566529c' -and
        $windowsServer2003Sp2ToolsMedia[0].ExpectedSha1 -eq 'aeae93def8b8f5885bcea9a24f4979e51637254b' -and
        -not $windowsServer2003Sp2ToolsMedia[0].RequiresExplicitTrust
    )
    $legacySysprepToolPath = Join-Path $repoRoot 'Tools/New-WindowsServer2003SysprepMedia.ps1'
    $legacyChildToolPath = Join-Path $repoRoot 'Tools/New-WindowsServer2003LegacyChild.ps1'
    $legacyIntegrationMediaToolPath = Join-Path $repoRoot 'Tools/Test-WindowsServer2003HyperVIntegrationMedia.ps1'
    $legacyTemplateRunbookPath = Join-Path $repoRoot 'Documentation/HowTo/WINDOWS_SERVER_2003_LEGACY_TEMPLATE.md'
    $legacySysprepToolText = Get-Content -LiteralPath $legacySysprepToolPath -Raw -Encoding utf8
    $legacyChildToolText = Get-Content -LiteralPath $legacyChildToolPath -Raw -Encoding utf8
    $legacyIntegrationMediaToolText = Get-Content -LiteralPath $legacyIntegrationMediaToolPath -Raw -Encoding utf8
    $legacyTemplateRunbookText = Get-Content -LiteralPath $legacyTemplateRunbookPath -Raw -Encoding utf8
    Add-CheckResult -Name 'Windows-Server-2003-Legacy-Reseal bleibt schlüsselfrei und Generation 1 getrennt' -Success (
        $legacySysprepToolText -match 'SysprepVersion\s*=\s*\$sysprepVersion' -and
        $legacySysprepToolText -match "sysprep -reseal -mini -quiet -forceshutdown" -and
        $legacySysprepToolText -match 'ContainsSecrets\s*=\s*\$false' -and
        $legacySysprepToolText -notmatch '(?i)ProductKey\s*=' -and
        $legacySysprepToolText -notmatch '(?i)AdminPassword\s*=' -and
        $legacyTemplateRunbookText -match '`LEGACY_TEMPLATE_SEALED`' -and
        $legacyTemplateRunbookText -match 'Generation[- ]1' -and
        $legacyTemplateRunbookText -match 'Differencing-VHDX' -and
        $legacyTemplateRunbookText -match 'Parent wird niemals direkt gebootet'
    )
    Add-CheckResult -Name 'Windows-Server-2003-Child übernimmt Evaluation-Key lokal ohne Offenlegung oder Aktivierung' -Success (
        $legacyChildToolText -match [regex]::Escape('I386\UNATTEND.TXT') -and
        $legacyChildToolText -match 'ExpectedEvaluationIsoSha256' -and
        $legacyChildToolText -match "LEGACY_TEMPLATE_SEALED" -and
        $legacyChildToolText -match 'New-VHD\s+-Path\s+\$childVhdPath\s+-ParentPath\s+\$resolvedParentVhd\s+-Differencing' -and
        $legacyChildToolText -match "-Generation 1" -and
        $legacyChildToolText -match '-IsLegacy\s+\$true' -and
        $legacyChildToolText -match '\[Microsoft\.HyperV\.PowerShell\.BootDevice\]::IDE' -and
        $legacyChildToolText -match 'WS2003_CHILD_ROOT_SCOPE_INVALID' -and
        $legacyChildToolText -match 'EvaluationProductKeyInjected\s*=\s*\$true' -and
        $legacyChildToolText -match 'EvaluationProductKeyDisclosed\s*=\s*\$false' -and
        $legacyChildToolText -match 'ActivationPerformed\s*=\s*\$false' -and
        $legacyChildToolText -match '\[LicenseFilePrintData\]' -and
        $legacyChildToolText -match 'AutoMode=PerServer' -and
        $legacyChildToolText -match 'IntegrationServicesIsoPath' -and
        $legacyChildToolText -match 'Test-WindowsServer2003HyperVIntegrationMedia\.ps1' -and
        $legacyChildToolText -match 'WS2003_CHILD_REQUIRES_ELEVATED_RUNNER' -and
        $legacyChildToolText -notmatch '(?i)(?<![A-Z0-9])[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}(?![A-Z0-9])' -and
        $legacyTemplateRunbookText -match 'SP2-Slipstream-ISO' -and
        $legacyTemplateRunbookText -match 'führt keine Aktivierung aus'
    )
    $windowsServer2003IntegrationMedia = @($mediaCatalog | Where-Object {
        $_.Id -eq 'windows-server-2003-hyper-v-integration-services-iso'
    })
    Add-CheckResult -Name 'Windows-Server-2003-Integrations-DVD ist hash- und signaturgebunden katalogisiert' -Success (
        $windowsServer2003IntegrationMedia.Count -eq 1 -and
        $windowsServer2003IntegrationMedia[0].Acquisition -eq 'ARCHIVE_FALLBACK_VERIFIED' -and
        $windowsServer2003IntegrationMedia[0].ExpectedBytes -eq 27590656 -and
        $windowsServer2003IntegrationMedia[0].ExpectedSha256 -eq 'd1037fd8e788ce8ed0df16ec21f057e74512d5b3d551cc9396c7ae95dccba10f' -and
        $windowsServer2003IntegrationMedia[0].ExpectedSha1 -eq '415d62038cf28c39af2ca63076a7df91a4524314' -and
        -not $windowsServer2003IntegrationMedia[0].RequiresExplicitTrust -and
        $legacyIntegrationMediaToolText -match 'd1037fd8e788ce8ed0df16ec21f057e74512d5b3d551cc9396c7ae95dccba10f' -and
        $legacyIntegrationMediaToolText -match "FileSystemLabel -ne 'VMGUEST'" -and
        $legacyIntegrationMediaToolText -match [regex]::Escape('Windows5.x-HyperVIntegrationServices-x86.msi') -and
        $legacyIntegrationMediaToolText -match 'Get-AuthenticodeSignature' -and
        $legacyIntegrationMediaToolText -match '6.3.9600.16384' -and
        $legacyTemplateRunbookText -match [regex]::Escape('support\x86\setup.exe') -and
        $legacyTemplateRunbookText -match 'normal ausgerichteter VMConnect-Mauszeiger'
    )
    $directWindowsMedia = @($mediaCatalog | Where-Object { $_.Id -in @(
        'windows-server-2016-evaluation-iso',
        'windows-server-2019-evaluation-iso',
        'windows-server-2022-evaluation-iso',
        'windows-server-2025-evaluation-iso'
    ) })
    Add-CheckResult -Name 'Aktuelle Windows-Evaluationen verwenden hashgebundene öffentliche Microsoft-Binärziele' -Success (
        $directWindowsMedia.Count -eq 4 -and
        @($directWindowsMedia | Where-Object {
            $_.Category -ne 'Windows Server' -or
            $_.Acquisition -ne 'DIRECT_MICROSOFT_DOWNLOAD' -or
            $_.SourceStatus -ne 'ACTIVE' -or
            $_.DownloadUrl -notlike 'https://software-static.download.prss.microsoft.com/*' -or
            $_.ReferenceUrl -notlike 'https://www.microsoft.com/en-us/evalcenter/*' -or
            -not $_.ExpectedBytes -or
            -not $_.ExpectedSha256 -or
            $_.RequiresExplicitTrust
        }).Count -eq 0
    )
    $plannedDirectWindowsMedia = Save-SqlServerLabMediaSource -Id 'windows-server-2022-evaluation-iso' -MediaRoot $temporaryRoot -WhatIf
    Add-CheckResult -Name 'Microsoft-Evaluation besitzt ohne Formularmutation einen reproduzierbaren WhatIf-Plan' -Success (
        $plannedDirectWindowsMedia.Status -eq 'PLANNED' -and
        $plannedDirectWindowsMedia.Bytes -eq 5044094976 -and
        $plannedDirectWindowsMedia.Sha256 -eq '3e4fa6d8507b554856fc9ca6079cc402df11a8b79344871669f0251535255325'
    )
    $plannedWindowsServer2003Sp2Tools = Save-SqlServerLabMediaSource -Id 'windows-server-2003-sp2-x86-tools-iso' -MediaRoot $temporaryRoot -WhatIf
    Add-CheckResult -Name 'Windows-Server-2003-SP2-Deployment-Medium besitzt einen reproduzierbaren WhatIf-Plan' -Success (
        $plannedWindowsServer2003Sp2Tools.Status -eq 'PLANNED' -and
        $plannedWindowsServer2003Sp2Tools.TargetPath -like "$(Join-Path $temporaryRoot 'WindowsServer\2003\Eval\Updates')*" -and
        $plannedWindowsServer2003Sp2Tools.Bytes -eq 548630528 -and
        $plannedWindowsServer2003Sp2Tools.Sha256 -eq '30cbd649cfd879bc35a94c41366380d64b5c1745393bcf5604390d3ce566529c'
    )
    $plannedWindowsMedia = Save-SqlServerLabMediaSource -Id 'windows-server-2008r2-sp1-evaluation-iso' -MediaRoot $temporaryRoot -WhatIf
    Add-CheckResult -Name 'Archiviertes Windows-Basismedium besitzt einen mutationsfreien WhatIf-Plan' -Success (
        $plannedWindowsMedia.Status -eq 'PLANNED' -and
        $plannedWindowsMedia.Bytes -eq 3166840832 -and
        $plannedWindowsMedia.Sha1 -eq 'beed231a34e90e1dd9a04b3afabec31d62ce3889' -and
        $plannedWindowsMedia.Sha256 -eq '30832ad76ccfa4ce48ccb936edefe02079d42fb1da32201bf9e3a880c8ed6312'
    )
    $communityScanBlocked = try {
        $null = Save-SqlServerLabMediaSource -Id 'sql-server-2000-evaluation-community-scan' -MediaRoot $temporaryRoot -WhatIf -ErrorAction Stop
        $false
    }
    catch { $_.Exception.Message -match '^SQL_MEDIA_SOURCE_EXPLICIT_TRUST_REQUIRED:' }
    Add-CheckResult -Name 'Community-Scan bleibt ohne ausdrückliche Quarantänefreigabe gesperrt' -Success $communityScanBlocked
    $plannedCommunityScan = Save-SqlServerLabMediaSource -Id 'sql-server-2000-evaluation-community-scan' -MediaRoot $temporaryRoot -AllowCommunityScan -WhatIf
    Add-CheckResult -Name 'Freigegebener Community-Scan plant ausschließlich den Incoming-Quarantänepfad' -Success (
        $plannedCommunityScan.Status -eq 'PLANNED' -and
        $plannedCommunityScan.TargetPath -like "$(Join-Path $temporaryRoot 'Incoming\CommunityScan\SQL\2000\Evaluation')*" -and
        $plannedCommunityScan.Sha256 -eq '7c9ceb672a15cfcdc828c9bd8458b87f57b0c570c823847e0676c4fab2592feb'
    )
    $plannedSql2005CommunityScan = Save-SqlServerLabMediaSource -Id 'sql-server-2005-evaluation-community-scan' -MediaRoot $temporaryRoot -AllowCommunityScan -WhatIf
    Add-CheckResult -Name 'SQL-2005-Evaluation bindet Quellcontainer und abgeleitetes geprüftes ISO getrennt' -Success (
        $plannedSql2005CommunityScan.Status -eq 'PLANNED' -and
        $plannedSql2005CommunityScan.TargetPath -like "$(Join-Path $temporaryRoot 'Incoming\CommunityScan\SQL\2005\Evaluation')*" -and
        @($mediaCatalog | Where-Object {
            $_.Id -eq 'sql-server-2005-evaluation-community-scan' -and
            $_.DerivedTargetRelativePath -eq 'SQL/2005/Evaluation/ISO/SQL2005_Evaluation.iso' -and
            $_.DerivedExpectedSha256 -eq 'fccbd167a95c7399227a8fb7ae3a0c8c932411663d9248fa650623ef53c2268c'
        }).Count -eq 1
    )
    $plannedSqlMedia = Save-SqlServerLabMediaSource -Id 'sql-server-2016-developer-sp3-iso' -MediaRoot $temporaryRoot -WhatIf
    Add-CheckResult -Name 'SQL-Basismedien-Download besitzt einen mutationsfreien WhatIf-Plan' -Success (
        $plannedSqlMedia.Status -eq 'PLANNED' -and
        $plannedSqlMedia.Sha256 -eq 'c293d7e267d34cf4af4e8f03cf472f489772acad6e205da4ceab080cb32b71ad'
    )
    $plannedSql2016Evaluation = Save-SqlServerLabMediaSource -Id 'sql-server-2016-evaluation-sp2-iso' -MediaRoot $temporaryRoot -WhatIf
    Add-CheckResult -Name 'SQL-2016-SP2-Evaluation ist als hashgebundenes Microsoft-Vollmedium registriert' -Success (
        $plannedSql2016Evaluation.Status -eq 'PLANNED' -and
        $plannedSql2016Evaluation.Bytes -eq 2970245120 -and
        $plannedSql2016Evaluation.Sha1 -eq '6309d729a0f063d11c0bb7f840f1069483406755' -and
        $plannedSql2016Evaluation.Sha256 -eq '863c14f9cc03dad80f6a9ebd7ed462cd21da73f1e8f461f41ea1a4bd8a2e61bb'
    )
    $plannedSql2008R2Evaluation = Save-SqlServerLabMediaSource -Id 'sql-server-2008r2-evaluation-x64-sfx-archive' -MediaRoot $temporaryRoot -WhatIf
    Add-CheckResult -Name 'SQL-2008-R2-x64-Evaluation bindet die exakte frühere Microsoft-SFX-Datei' -Success (
        $plannedSql2008R2Evaluation.Status -eq 'PLANNED' -and
        $plannedSql2008R2Evaluation.Bytes -eq 1581398808 -and
        $plannedSql2008R2Evaluation.Sha1 -eq 'e9f0de0981895bf801e3edc63c9e28575d0aef7f' -and
        $plannedSql2008R2Evaluation.Sha256 -eq '098f017b5c2aa3d755fe0372537a02c9d8230a08c3bfea1f0fd856f4ee55f63e'
    )
    $plannedSql2008Evaluation = Save-SqlServerLabMediaSource -Id 'sql-server-2008-evaluation-iso-archive' -MediaRoot $temporaryRoot -WhatIf
    Add-CheckResult -Name 'SQL-2008-RTM-Evaluation bindet die geprüfte Microsoft-Wayback-Aufnahme' -Success (
        $plannedSql2008Evaluation.Status -eq 'PLANNED' -and
        $plannedSql2008Evaluation.Bytes -eq 3256913920 -and
        $plannedSql2008Evaluation.Sha1 -eq '883493544d7c90c9d7377005a1d8ffcdaae8b6ca' -and
        $plannedSql2008Evaluation.Sha256 -eq '5c77401099beb3a7e9543e718ca55283102611444a9eca323d097e861a75ea39'
    )
    $manualMediaBlocked = try {
        $null = Save-SqlServerLabMediaSource -Id 'sql-server-7.0-licensed-media' -MediaRoot $temporaryRoot -ErrorAction Stop
        $false
    }
    catch { $_.Exception.Message -match '^SQL_MEDIA_SOURCE_MANUAL_REQUIRED:' }
    Add-CheckResult -Name 'SQL-7.0-Lizenzmedium bleibt fail-closed manuell' -Success $manualMediaBlocked
    $retryableDiscovery = & $module {
        Test-HyperVWindowsMediaDiscoveryRetry -Cached @([PSCustomObject]@{ State = 'RETRY_ELEVATED' })
    }
    $stableDiscovery = & $module {
        Test-HyperVWindowsMediaDiscoveryRetry -Cached @([PSCustomObject]@{ State = 'UNRECOGNIZED' })
    }
    $legacyElevationDiscovery = & $module {
        Test-HyperVWindowsMediaDiscoveryRetry -Cached @([PSCustomObject]@{ State = 'UNRECOGNIZED'; Message = 'Der angeforderte Vorgang erfordert erhöhte Rechte.' })
    }
    $elevationMessageDetected = 'Der angeforderte Vorgang erfordert erhöhte Rechte.' -match '(?i)(erh.\s*hte Rechte|elevated (privilege|rights)|access (is )?denied|zugriff verweigert)'
    Add-CheckResult -Name 'Berechtigungsbedingte ISO-Erkennung wird erneut versucht und nicht persistent gecached' -Success (
        $retryableDiscovery -and -not $stableDiscovery -and $legacyElevationDiscovery -and $elevationMessageDetected -and
        $operatorText -match 'State = if \(\$requiresElevation\) \{ ''RETRY_ELEVATED'' \}' -and
        $operatorText -match 'Test-HyperVWindowsMediaDiscoveryRetry -Cached \$entry'
    )
    Add-CheckResult -Name 'Cleanup-Plan existiert vor Provider-Mutation' -Success (Test-Path (Join-Path $plan.BuildDirectory 'cleanup-plan.json'))
    $rawState = Get-Content (Join-Path $plan.BuildDirectory 'build-state.json') -Raw
    Add-CheckResult -Name 'Portabler Build-State enthaelt keinen ISO-Hostpfad' -Success ($rawState -notmatch [regex]::Escape($isoPath))
    $builderText = Get-Content $builderPath -Raw
    Add-CheckResult -Name 'Cleanup-Schritte stehen vor New-VHD' -Success ($builderText -match 'Add-CleanupStep[\s\S]+Add-CleanupStep[\s\S]+New-VHD')
    $notesIndex = $builderText.IndexOf('ConvertTo-HyperVLabNotes')
    $dvdIndex = $builderText.IndexOf('Add-VMDvdDrive')
    Add-CheckResult -Name 'Builder-Identitaet wird vor weiterer VM-Konfiguration gesetzt' -Success ($notesIndex -ge 0 -and $dvdIndex -gt $notesIndex)
    Add-CheckResult -Name 'VM-Konfiguration verwendet den gebundenen kurzen Build-Ressourcenroot' -Success (
        $builderText -match 'Initialize-LabHyperVResourceBinding[\s\S]+-ResourceClass\s+Build' -and
        $builderText -match 'New-VM[\s\S]+?-Path\s+\$resourceRoot' -and
        $builderText -match 'Assert-HyperVVMResourceBinding'
    )
    Add-CheckResult -Name 'Builder ist Generation 2 mit Secure Boot' -Success ($builderText -match 'Generation\s+2[\s\S]+EnableSecureBoot\s+On')
    Add-CheckResult -Name 'Builder deaktiviert automatische Hyper-V-Checkpoints' -Success ($builderText -match 'Set-VM[^\r\n]+AutomaticCheckpointsEnabled\s+\$false')
    Add-CheckResult -Name 'Windows-Builder erhält einen begrenzten dynamischen Speicherbereich' -Success ($builderText -match 'Math\]::Max\(\[double\]512MB,\s*\[double\]\$MemoryStartupBytes\s*/\s*2\)[\s\S]+Math\]::Min\(\[double\]1TB,\s*\[double\]\$MemoryStartupBytes\s*\*\s*2\)[\s\S]+Set-VMMemory[\s\S]+MaximumBytes\s+\$memoryMaximumBytes')
    Add-CheckResult -Name 'Builder bindet ISO als DVD ein' -Success ($builderText -match 'Add-VMDvdDrive[\s\S]+FirstBootDevice')
    $operatorText = Get-Content (Join-Path $repoRoot 'Private/HyperVImageOperator.ps1') -Raw
    Add-CheckResult -Name 'Initialer Medienboot nutzt Hyper-V-WMI und persistiert ein einmaliges Receipt' -Success (
        $operatorText -match 'Msvm_Keyboard' -and
        $operatorText -match 'TypeKey' -and
        $operatorText -match 'initialMediaBootReceipt'
    )
    Add-CheckResult -Name 'Initialer Medienboot deckt das reale UEFI-DVD-Zeitfenster ab' -Success (
        $operatorText -match '\[int\]\$Attempts\s*=\s*30' -and
        $operatorText -match '\[int\]\$IntervalMilliseconds\s*=\s*750'
    )
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
    $importIndex = $builderText.IndexOf('$artifact = Import-HyperVImageArtifact')
    $removeIndex = $builderText.LastIndexOf('$null = Remove-HyperVInstance')
    $sealedIndex = $builderText.IndexOf('$build = Set-HyperVImageBuildState -BuildId $BuildId -State $finalState')
    Add-CheckResult -Name 'Registry-Import wird vor Builder-Loeschung abgeschlossen' -Success ($importIndex -ge 0 -and $removeIndex -gt $importIndex)
    Add-CheckResult -Name 'Leeres Artifact kann Build nicht als versiegelt markieren' -Success (
        $builderText -match 'HYPERV_IMAGE_ARTIFACT_PUBLICATION_FAILED' -and
        $sealedIndex -gt $removeIndex
    )
    Add-CheckResult -Name 'Sysprep verwendet Generalize, OOBE, VM-Mode und Quit' -Success ($builderText -match "'/generalize',[^\r\n]+'/oobe',[^\r\n]+'/mode:vm',[^\r\n]+'/quit',[^\r\n]+'/quiet'")
    Add-CheckResult -Name 'Sysprep wartet begrenzt auf Microsoft ImageState vor Shutdown' -Success (
        $builderText -match 'imageStateDeadline\s*=\s*\[datetime\]::UtcNow\.AddSeconds\(180\)' -and
        $builderText -match "IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'\) \{ break \}" -and
        $builderText -match 'Start-Sleep -Seconds 2' -and
        $builderText -match [regex]::Escape("Join-Path `$env:WINDIR 'System32\Sysprep\Panther'") -and
        $builderText -match [regex]::Escape("Where-Object { `$_ -match 'error|fail' }") -and
        $builderText -match 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE[\s\S]+shutdown\.exe'
    )
    Add-CheckResult -Name 'Automatische Generalisierung persistiert REBOOT_REQUIRED' -Success ($builderText -match 'Set-HyperVImageBuildState[^\r\n]+-State REBOOT_REQUIRED')
    Add-CheckResult -Name 'Automatisches Sysprep ist fuer Testmedien gesperrt' -Success ($builderText -match 'HYPERV_SYSPREP_NOT_ALLOWED_FOR_TEST_MEDIA')

    $autoRoot = Join-Path $temporaryRoot 'auto-state'
    $autoPlan = & $module {
        param($Iso,$Sha,$Root)
        $plan = New-HyperVWindowsImageBuildPlan -IsoPath $Iso -ExpectedSha256 $Sha `
            -OperatingSystemId windows-server-2025 -Edition evaluation -InstallationType core `
            -LicenseType evaluation -OsDiskSizeBytes 64MB -StateRoot $Root
        $plan = Set-HyperVImageBuildState -BuildId $plan.buildId -State BUILDER_READY -Reason test -StateRoot $Root
        $plan.builder = [PSCustomObject]@{ vmName = 'mock-sysprep-vm'; osDiskRelativePath = 'resources/hyperv/mock.vhdx'; generation = 2; secureBoot = $true }
        Write-HyperVImageBuildState -BuildDirectory $plan.BuildDirectory -State $plan
        $manual = Set-HyperVImageBuildManualAction -BuildId $plan.buildId -StateRoot $Root
        $manual | Add-Member -NotePropertyName installationEvidence -NotePropertyValue ([PSCustomObject]@{
            contractVersion = '1'; verified = $true; installationType = 'core'
            editionId = 'ServerStandardEval'; currentBuild = '26100'
        }) -Force
        Write-HyperVImageBuildState -BuildDirectory $manual.BuildDirectory -State $manual
        Get-HyperVImageBuildPlan -BuildId $manual.buildId -StateRoot $Root
    } $isoPath $sha $autoRoot
    $testUser = 'sql-lab-sysprep-test'
    $testCredential = [PSCredential]::new($testUser, (ConvertTo-SecureString 'NotPersisted_1!' -AsPlainText -Force))
    $autoResult = & $module {
        param($BuildId,$Root,$Credential)
        function Test-HyperVAvailable { [PSCustomObject]@{ Available = $true; Message = '' } }
        function Invoke-HyperVPowerShellDirect {
            param($VMName,$ExpectedRunId,$ExpectedScopeId,$Credential,$ScriptBlock,$ArgumentList)
            [PSCustomObject]@{
                contractVersion = '1'; buildId = $ArgumentList[0]; scopeId = $ArgumentList[1]
                challenge = $ArgumentList[2]; imageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'
                sysprepExitCode = 0; guestComputerName = 'MOCK-GUEST'
                guestObservedAt = [datetime]::UtcNow.ToString('o'); shutdownDelaySeconds = 30
            }
        }
        function Get-HyperVManagedVM {
            param($VMName,$ExpectedRunId,$ExpectedScopeId)
            [PSCustomObject]@{ VM = [PSCustomObject]@{ State = 'Off' }; Identity = [PSCustomObject]@{} }
        }
        Invoke-HyperVWindowsImageGeneralization -BuildId $BuildId -Credential $Credential -StateRoot $Root
    } $autoPlan.buildId $autoRoot $testCredential
    Add-CheckResult -Name 'PowerShell-Direct-Receipt fuehrt automatisch zu RESUME_PENDING' -Success ($autoResult.state -eq 'RESUME_PENDING' -and $autoResult.generalizationEvidence.source -eq 'powershell-direct')
    $jsonDate = ('{"value":"2026-08-03T18:33:14Z"}' | ConvertFrom-Json).value
    $normalizedDate = & $module {
        param($Value)
        (ConvertTo-HyperVImageDateTimeOffset -Value $Value).ToUniversalTime().ToString('o')
    } $jsonDate
    Add-CheckResult -Name 'JSON-DateTime bleibt kulturinvariant am 3. August' -Success ($normalizedDate -eq '2026-08-03T18:33:14.0000000+00:00')
    $repairResult = & $module {
        param($BuildId,$Root)
        Repair-HyperVWindowsImageGeneralizationEvidence -BuildId $BuildId -StateRoot $Root
    } $autoResult.buildId $autoRoot
    Add-CheckResult -Name 'PowerShell-Direct-Evidenz kann ohne erneutes Sysprep repariert werden' -Success (
        $repairResult.state -eq 'RESUME_PENDING' -and
        $repairResult.generalizationEvidence.source -eq 'powershell-direct'
    )
    $autoRawState = Get-Content -LiteralPath (Join-Path $autoResult.BuildDirectory 'build-state.json') -Raw
    Add-CheckResult -Name 'Gast-Credentials werden nicht im Build-State persistiert' -Success ($autoRawState -notmatch [regex]::Escape($testUser) -and $autoRawState -notmatch 'NotPersisted_1!')
    Add-CheckResult -Name 'Realer Sysprep-Pfad verlangt verifizierte Installationsmetadaten' -Success ($builderText -match 'HYPERV_IMAGE_INSTALLATION_NOT_VERIFIED')

    $bootRoot = Join-Path $temporaryRoot 'boot-interaction'
    $bootResult = & $module {
        param($Iso,$Sha,$Root)
        $plan = New-HyperVWindowsImageBuildPlan -IsoPath $Iso -ExpectedSha256 $Sha `
            -OperatingSystemId windows-server-2025 -Edition evaluation -InstallationType core `
            -LicenseType evaluation -OsDiskSizeBytes 64MB -StateRoot $Root
        $plan = Set-HyperVImageBuildState -BuildId $plan.buildId -State BUILDER_READY -Reason test -StateRoot $Root
        $plan.builder = [PSCustomObject]@{ vmName = 'mock-boot-vm'; generation = 2; secureBoot = $true }
        Write-HyperVImageBuildState -BuildDirectory $plan.BuildDirectory -State $plan
        $script:typedKeys = 0
        function Start-HyperVInstance { [PSCustomObject]@{ VMName = 'mock-boot-vm'; State = 'Running' } }
        function Get-CimInstance { param($Namespace,$ClassName,$Filter,$ErrorAction) [PSCustomObject]@{ Name = 'mock-vm-cim' } }
        function Get-CimAssociatedInstance { param($InputObject,$Association,$ResultClassName,$ErrorAction) [PSCustomObject]@{ Name = 'mock-keyboard' } }
        function Invoke-CimMethod { param($InputObject,$MethodName,$Arguments,$ErrorAction) $script:typedKeys++; [PSCustomObject]@{ ReturnValue = 0 } }
        function Start-Sleep { param($Milliseconds) }
        $first = Start-HyperVWindowsImageBuildVM -BuildId $plan.buildId -StateRoot $Root
        $second = Start-HyperVWindowsImageBuildVM -BuildId $plan.buildId -StateRoot $Root
        $stored = Get-HyperVImageBuildPlan -BuildId $plan.buildId -StateRoot $Root
        [PSCustomObject]@{ First = $first; Second = $second; TypedKeys = $script:typedKeys; Stored = $stored }
    } $isoPath $sha $bootRoot
    Add-CheckResult -Name 'Leertaste wird nur beim ersten Builder-Start gesendet und als sanitisiertes Receipt gespeichert' -Success (
        $bootResult.TypedKeys -eq 30 -and
        $bootResult.First.InitialMediaBoot.status -eq 'SENT' -and
        $bootResult.Second.InitialMediaBoot.status -eq 'SENT' -and
        $bootResult.Stored.initialMediaBootReceipt.successfulSends -eq 30
    )

    $noInputBootRoot = Join-Path $temporaryRoot 'boot-interaction-none'
    $noInputBoot = & $module {
        param($Iso,$Sha,$Root)
        $plan = New-HyperVWindowsImageBuildPlan -IsoPath $Iso -ExpectedSha256 $Sha `
            -OperatingSystemId synthetic-ci -Edition none -InstallationType synthetic `
            -LicenseType test-only -InitialMediaKey none -OsDiskSizeBytes 64MB -StateRoot $Root
        $plan = Set-HyperVImageBuildState -BuildId $plan.buildId -State BUILDER_READY -Reason test -StateRoot $Root
        $plan.builder = [PSCustomObject]@{ vmName = 'mock-linux-vm'; generation = 2; secureBoot = $true }
        Write-HyperVImageBuildState -BuildDirectory $plan.BuildDirectory -State $plan
        function Start-HyperVInstance { [PSCustomObject]@{ VMName = 'mock-linux-vm'; State = 'Running' } }
        function Get-CimInstance { throw 'LINUX_BOOT_MUST_NOT_USE_KEYBOARD' }
        Start-HyperVWindowsImageBuildVM -BuildId $plan.buildId -StateRoot $Root
    } $isoPath $sha $noInputBootRoot
    Add-CheckResult -Name 'InitialMediaKey none überspringt die virtuelle Tastatur vollständig' -Success (
        $noInputBoot.InitialMediaBoot.status -eq 'SKIPPED' -and
        $noInputBoot.InitialMediaBoot.successfulSends -eq 0
    )
} catch { Add-CheckResult -Name 'Image-Builder-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally { Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue; if(Test-Path $temporaryRoot){Remove-Item $temporaryRoot -Recurse -Force} }
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if($failures.Count){exit 1}; exit 0



