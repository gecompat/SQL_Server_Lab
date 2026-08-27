#Requires -Version 7.2
[CmdletBinding()] param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-external-runtime-windows-$([guid]::NewGuid().ToString('N'))"
$failures = [Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''; Write-Host 'SQL_Server_Lab - External Runtime Windows Checks' -ForegroundColor Cyan
try {
    New-Item -Path $temporaryRoot -ItemType Directory -Force | Out-Null
    $module = Import-Module $modulePath -Force -PassThru
    $catalog = Get-Content -LiteralPath (Join-Path $repoRoot 'Catalogs/software.json') -Raw | ConvertFrom-Json -Depth 100
    $recipe = & $module { Get-LabExternalRuntimeWindowsRecipe }
    $python = @($catalog.software | Where-Object id -eq 'sql-python')[0].variants |
        Where-Object id -eq 'sql2022-python-windows-hyperv'
    $r = @($catalog.software | Where-Object id -eq 'sql-r')[0].variants |
        Where-Object id -eq 'sql2022-r-windows-hyperv'
    $java = @($catalog.software | Where-Object id -eq 'sql-java')[0].variants |
        Where-Object id -eq 'sql2022-java17-windows-hyperv'
    Add-CheckResult -Name 'Windows-Rezept bindet SQL 2022, Python 3.10.11, R 4.2.3 und Java 17' -Success (
        $recipe.sqlMajorVersion -eq 16 -and $recipe.languages.Python.runtimeVersion -eq '3.10.11' -and
        $recipe.languages.R.runtimeVersion -eq '4.2.3' -and $recipe.languages.Java.runtimeVersion -eq '17.0.20.1'
    )
    Add-CheckResult -Name 'Python-Windows-Variante bindet Installer und zehn Offline-Wheels per SHA-256' -Success (
        @($python.artifacts).Count -eq 11 -and @($python.artifacts | Where-Object { $_.sha256 -notmatch '^[a-f0-9]{64}$' }).Count -eq 0 -and
        @($python.artifacts | Where-Object id -eq 'revoscalepy-win-10.0.1').Count -eq 1
    )
    Add-CheckResult -Name 'R-Windows-Variante bindet Installer und sechs Binärpakete per SHA-256' -Success (
        @($r.artifacts).Count -eq 7 -and @($r.artifacts | Where-Object { $_.sha256 -notmatch '^[a-f0-9]{64}$' }).Count -eq 0 -and
        @($r.artifacts | Where-Object id -eq 'revoscaler-win-10.0.1').Count -eq 1
    )
    Add-CheckResult -Name 'Java-Windows-Variante bindet JDK, Extension, SDK und erzeugtes Probe-JAR per SHA-256' -Success (
        @($java.artifacts).Count -eq 4 -and @($java.artifacts | Where-Object { $_.sha256 -notmatch '^[a-f0-9]{64}$' }).Count -eq 0 -and
        @($java.artifacts | Where-Object { $_.sourceType -eq 'generated' -and $_.id -in @('mssql-java-lang-extension-windows','sql-server-lab-java-probe') }).Count -eq 2 -and
        $java.extensionVersion -eq '1.1.0'
    )

    $samplePlans = @(
        [PSCustomObject]@{ SoftwareId='sql-python'; VariantId=$python.id; Language='Python' },
        [PSCustomObject]@{ SoftwareId='sql-r'; VariantId=$r.id; Language='R' },
        [PSCustomObject]@{
            SoftwareId='sql-java'; VariantId=$java.id; Language='Java'
            ArtifactRefs=@($java.artifacts | ForEach-Object { [PSCustomObject]@{ Id=$_.id; Sha256=$_.sha256 } })
        }
    )
    $sampleArtifacts = @(
        [PSCustomObject]@{ Id='one'; Version='1'; Sha256=('a' * 64); FileName='one.bin' },
        [PSCustomObject]@{ Id='two'; Version='2'; Sha256=('b' * 64); FileName='two.bin' }
    )
    $guestPlan = & $module {
        param($Plans,$Artifacts,$Root)
        New-LabExternalRuntimeWindowsGuestPlan -SoftwarePlans $Plans -Artifacts $Artifacts -RunDirectory $Root
    } $samplePlans $sampleArtifacts $temporaryRoot
    $rawGuestPlan = Get-Content -LiteralPath $guestPlan.Path -Raw
    Add-CheckResult -Name 'Guest-Plan ist deterministisch und enthält weder Quellen noch Hostpfade' -Success (
        (@($guestPlan.Plan.languages) -join ',') -eq 'Java,Python,R' -and $guestPlan.Plan.java -and
        $rawGuestPlan -notmatch 'https?://' -and $rawGuestPlan -notmatch [regex]::Escape($repoRoot)
    )

    $guestScriptPath = Join-Path $repoRoot 'Images/ExternalLanguages/Windows/Install-ExternalRuntimes.ps1'
    $tokens = $null; $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($guestScriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    $guestText = Get-Content -LiteralPath $guestScriptPath -Raw
    Add-CheckResult -Name 'Guest-Installer ist syntaktisch gültig und vollständig offline' -Success (
        $parseErrors.Count -eq 0 -and $guestText -notmatch 'Invoke-WebRequest|Start-BitsTransfer|curl(?:\.exe)?' -and
        $guestText -match '--no-index' -and $guestText -match '--no-deps'
    )
    Add-CheckResult -Name 'Guest-Installer prüft Hash, ACL, RegisterRext und Services' -Success (
        $guestText -match 'Get-FileHash' -and $guestText -match '\*S-1-15-2-1' -and
        $guestText -match 'RegisterRext\.exe' -and $guestText -match 'Restart-Service -Name \$sqlServiceName'
    )
    Add-CheckResult -Name 'Guest-Installer extrahiert das Java-SDK, baut das Probe-JAR offline und bindet JRE_HOME' -Success (
        $guestText -match 'Install-JavaExternalRuntime' -and $guestText -match 'sdkJarSha256' -and
        $guestText -match 'probeJarSha256' -and $guestText -match "SetEnvironmentVariable\('JRE_HOME'" -and
        $guestText -notmatch 'JAVA_INSTALLATION_NOT_IMPLEMENTED'
    )

    $javaRuntimePlan = [PSCustomObject]@{
        OperatingSystem='windows'; RuntimeVersion='17'; ArtifactRefs=@($java.artifacts | ForEach-Object {
            [PSCustomObject]@{ Id=$_.id; Sha256=$_.sha256 }
        })
    }
    $securePassword = [Security.SecureString]::new()
    foreach ($character in @('T','e','s','t','_','1','!')) { $securePassword.AppendChar($character) }
    $javaSqlContract = & $module {
        param($Plan,$Password)
        $script:windowsJavaQueries = [Collections.Generic.List[string]]::new()
        function Invoke-SqlQuery {
            param($HostName,$Port,$SaPlain,$Database,$Query,$TimeoutSeconds)
            $script:windowsJavaQueries.Add([string]$Query)
            if ($Query -match 'SQLLAB_JAVA_REGISTRATION') { return 'SQLLAB_JAVA_REGISTRATION|1|1|1' }
            return 'SQLLAB_EXTERNAL|Java|1.0.0|17.0.20.1|42|MSSQLLAUNCHPAD01'
        }
        $probe = Invoke-LabJavaExternalRuntimeProbe -Plan $Plan -Port 1433 -SaPassword $Password -Database master
        [PSCustomObject]@{ Probe=$probe; Query=($script:windowsJavaQueries -join "`n--NEXT--`n") }
    } $javaRuntimePlan $securePassword
    Add-CheckResult -Name 'Windows-Java-DDL bindet Plattform, DLL, JAVAHOME, SDK und echte Java-17-Probe' -Success (
        $javaSqlContract.Probe.Status -eq 'PASS' -and $javaSqlContract.Probe.RuntimeVersion -eq '17.0.20.1' -and
        $javaSqlContract.Query -match 'PLATFORM = WINDOWS' -and $javaSqlContract.Query -match "FILE_NAME = 'javaextension\.dll'" -and
        $javaSqlContract.Query -match 'JAVAHOME' -and $javaSqlContract.Query -match 'mssql-java-lang-extension-windows\.jar'
    )

    $hostText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ExternalRuntimeWindows.ps1') -Raw
    $newText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/New-SqlServerLab.ps1') -Raw
    $imageBuilderText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVSqlImageBuilder.ps1') -Raw
    $labEnvironmentText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVLabEnvironment.ps1') -Raw
    Add-CheckResult -Name 'Hostpfad verwendet content-addressed Media Root und atomare verifizierte Downloads' -Success (
        $hostText -match 'ExternalLanguages/Windows/\$\(\(\[string\]\$artifact\.sha256\)' -and
        $hostText -match '\.partial-' -and $hostText -match 'MEDIA_HASH_MISMATCH' -and
        $hostText -match '\[IO\.File\]::Move'
    )
    Add-CheckResult -Name 'PowerShell Direct kopiert nur geschlossenen Plan, Artefakte und Repositoryskript' -Success (
        $hostText -match 'Copy-VMFile' -and $hostText -match 'Install-ExternalRuntimes\.ps1' -and
        $hostText -match 'SqlServerLab\.ExternalRuntimeWindowsGuestPlan'
    )
    Add-CheckResult -Name 'Fehler bleibt sichtbar RECOVERY_REQUIRED; Erfolg erst nach SQL-Probe ready' -Success (
        $hostText -match 'RECOVERY_REQUIRED' -and $hostText -match 'EXTENSIONS_READY_RUN' -and
        $hostText.IndexOf('Invoke-LabPythonExternalRuntimeProbe') -lt $hostText.IndexOf('-Status EXTENSIONS_READY_RUN') -and
        $hostText.IndexOf('Invoke-LabJavaExternalRuntimeProbe') -lt $hostText.IndexOf('-Status EXTENSIONS_READY_RUN')
    )
    Add-CheckResult -Name 'Hyper-V-Manifest verlangt Prepared Image mit AdvancedAnalytics vor Mutation' -Success (
        $newText -match 'HYPERV_EXTERNAL_RUNTIME_SQL_PREPARED_IMAGE_REQUIRED' -and
        $newText -match 'HYPERV_EXTERNAL_RUNTIME_ADVANCED_ANALYTICS_REQUIRED' -and
        $newText.IndexOf('HYPERV_EXTERNAL_RUNTIME_ADVANCED_ANALYTICS_REQUIRED') -lt $newText.IndexOf('New-HyperVLabEnvironment')
    )
    Add-CheckResult -Name 'Prepared-Image- und SQL-Slot-Pläne erlauben AdvancedAnalytics explizit' -Success (
        $imageBuilderText -match "'ADVANCEDANALYTICS'" -and
        $labEnvironmentText -match "ValidateSet\('SQLENGINE', 'FULLTEXT', 'REPLICATION', 'ADVANCEDANALYTICS'\)"
    )
}
catch { Add-CheckResult -Name 'External-Runtime-Windows-Testausführung' -Success $false -Message $_.Exception.Message }
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
