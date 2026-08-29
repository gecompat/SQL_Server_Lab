#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft Derived-Image-Key, sichere Launchgrenzen und Receipt-Vertrag.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - External Runtime Container Image Checks' -ForegroundColor Cyan

Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -ErrorAction Stop
$module = Get-Module SqlServerLab
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("sql-lab-external-runtime-checks-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
try {
    $result = & $module {
        param($Root)
        $request = [PSCustomObject]@{
            Id='sql-python'; Version=$null; Variant=$null; Scope='sqlExternalRuntime'; InstallMethod='catalog'
            Optional=$false; Packages=@(); RequestSource='software'
        }
        $dockerSoftwarePlan = Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion 2022 -Provider docker -OperatingSystem linux
        $podmanSoftwarePlan = Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion 2022 -Provider podman -OperatingSystem linux
        $docker2025SoftwarePlan = Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion 2025 -Provider docker -OperatingSystem linux
        $rRequest = $request | Select-Object *
        $rRequest.Id = 'sql-r'
        $dockerRSoftwarePlan = Resolve-LabExternalRuntimePlan -SoftwareItem $rRequest -SqlVersion 2022 -Provider docker -OperatingSystem linux
        $podmanRSoftwarePlan = Resolve-LabExternalRuntimePlan -SoftwareItem $rRequest -SqlVersion 2022 -Provider podman -OperatingSystem linux
        $javaRequest = $request | Select-Object *
        $javaRequest.Id = 'sql-java'
        $dockerJavaSoftwarePlan = Resolve-LabExternalRuntimePlan -SoftwareItem $javaRequest -SqlVersion 2022 -Provider docker -OperatingSystem linux
        $podmanJavaSoftwarePlan = Resolve-LabExternalRuntimePlan -SoftwareItem $javaRequest -SqlVersion 2022 -Provider podman -OperatingSystem linux
        $docker2019JavaSoftwarePlan = Resolve-LabExternalRuntimePlan -SoftwareItem $javaRequest -SqlVersion 2019 -Provider docker -OperatingSystem linux
        $dockerImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider docker -SqlVersion 2022 -SoftwarePlans @($dockerSoftwarePlan)
        $podmanImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider podman -SqlVersion 2022 -SoftwarePlans @($podmanSoftwarePlan)
        $docker2025ImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider docker -SqlVersion 2025 -SoftwarePlans @($docker2025SoftwarePlan)
        $dockerRImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider docker -SqlVersion 2022 -SoftwarePlans @($dockerRSoftwarePlan)
        $podmanRImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider podman -SqlVersion 2022 -SoftwarePlans @($podmanRSoftwarePlan)
        $combinedImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider docker -SqlVersion 2022 `
            -SoftwarePlans @($dockerSoftwarePlan, $dockerRSoftwarePlan)
        $dockerJavaImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider docker -SqlVersion 2022 `
            -SoftwarePlans @($dockerJavaSoftwarePlan)
        $podmanJavaImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider podman -SqlVersion 2022 `
            -SoftwarePlans @($podmanJavaSoftwarePlan)
        $docker2019JavaImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider docker -SqlVersion 2019 `
            -SoftwarePlans @($docker2019JavaSoftwarePlan)
        $pythonJavaImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider docker -SqlVersion 2022 `
            -SoftwarePlans @($dockerSoftwarePlan, $dockerJavaSoftwarePlan)
        $rJavaImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider docker -SqlVersion 2022 `
            -SoftwarePlans @($dockerRSoftwarePlan, $dockerJavaSoftwarePlan)
        $allImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider docker -SqlVersion 2022 `
            -SoftwarePlans @($dockerSoftwarePlan, $dockerRSoftwarePlan, $dockerJavaSoftwarePlan)

        $compensationRoot = Join-Path $Root 'java-compensation-run'
        New-Item -Path $compensationRoot -ItemType Directory -Force | Out-Null
        $originalConfigurationQuery = (Get-Command Invoke-LabConfigurationQuery).ScriptBlock
        $originalRestart = (Get-Command Restart-LabExternalRuntimeContainer).ScriptBlock
        $originalWait = (Get-Command Wait-SqlReady).ScriptBlock
        $originalLaunchpad = (Get-Command Test-LabExternalRuntimeLaunchpadProcess).ScriptBlock
        $originalJavaProbe = (Get-Command Invoke-LabJavaExternalRuntimeProbe).ScriptBlock
        $originalJavaUndo = (Get-Command Undo-LabJavaExternalRuntimeDatabaseObjects).ScriptBlock
        try {
            $script:javaProbeCall = 0
            $script:javaCompensatedDatabases = @()
            Set-Item Function:Invoke-LabConfigurationQuery -Value {
                param($HostName, $Port, $SaPassword, $Query)
            }
            Set-Item Function:Restart-LabExternalRuntimeContainer -Value {
                param($Provider, $ContainerIdOrName)
            }
            Set-Item Function:Wait-SqlReady -Value {
                param($HostName, $Port, $SaPassword, $TimeoutSeconds, $ExpectedMajorVersion, $Provider, $ContainerIdOrName)
                [PSCustomObject]@{ Ready=$true; Message='ready' }
            }
            Set-Item Function:Test-LabExternalRuntimeLaunchpadProcess -Value {
                param($Provider, $ContainerIdOrName)
                [PSCustomObject]@{ Id='launchpadd-process'; Status='PASS' }
            }
            Set-Item Function:Invoke-LabJavaExternalRuntimeProbe -Value {
                param($Plan, $HostName, $Port, $SaPassword, $Database, $RegistrationTracker)
                $script:javaProbeCall++
                if ($script:javaProbeCall -eq 2) { throw 'SYNTHETIC_SECOND_DATABASE_FAILURE' }
                $registration = [PSCustomObject]@{
                    Database=$Database; CreatedLanguage=$true; CreatedSdk=$true; CreatedProbe=$true
                }
                $RegistrationTracker.Registration = $registration
                [PSCustomObject]@{
                    Id='java-data-roundtrip'; Status='PASS'; Language='Java'; Database=$Database
                    RuntimeVersion='11.0.32'; ProbeVersion='1.0.0'; InputValue=42; OutputValue=42
                    WorkerIdentity='mssql_satellite'; Registration='CREATED'
                    RegistrationDetails=$registration
                }
            }
            Set-Item Function:Undo-LabJavaExternalRuntimeDatabaseObjects -Value {
                param($HostName, $Port, $SaPassword, $Database, $Registration)
                $script:javaCompensatedDatabases += [string]$Database
            }
            $resolvedJava = $dockerJavaSoftwarePlan | Select-Object *
            $resolvedJava.Status = 'RESOLVED'
            $resolvedJava.ReasonCode = $null
            $resolvedJava.Reason = $null
            $compensationFailure = $null
            try {
                $null = Initialize-LabExternalRuntimes -SoftwarePlans @($resolvedJava) -LabInstance ([PSCustomObject]@{
                    Id='sql'; Provider='docker'; ContainerId='container'; Host='127.0.0.1'; Port=1433
                    Version='2022'; Databases=@('DbOne', 'DbTwo')
                }) -ImageArtifact ([PSCustomObject]@{
                    ImageKey=('a' * 64); Provider='docker'; LocalImageId='sha256:test'
                }) -SaPassword ([Security.SecureString]::new()) -RunDirectory $compensationRoot
            }
            catch { $compensationFailure = $_.Exception.Message }
            $multiDatabaseCompensation = $compensationFailure -match 'SYNTHETIC_SECOND_DATABASE_FAILURE' -and
                @($script:javaCompensatedDatabases).Count -eq 1 -and
                $script:javaCompensatedDatabases[0] -eq 'DbOne'
        }
        finally {
            Set-Item Function:Invoke-LabConfigurationQuery -Value $originalConfigurationQuery
            Set-Item Function:Restart-LabExternalRuntimeContainer -Value $originalRestart
            Set-Item Function:Wait-SqlReady -Value $originalWait
            Set-Item Function:Test-LabExternalRuntimeLaunchpadProcess -Value $originalLaunchpad
            Set-Item Function:Invoke-LabJavaExternalRuntimeProbe -Value $originalJavaProbe
            Set-Item Function:Undo-LabJavaExternalRuntimeDatabaseObjects -Value $originalJavaUndo
        }

        $arbitraryRejected = $false
        try {
            $invalid = $dockerSoftwarePlan | Select-Object *
            $invalid.Status = 'RESOLVED_BY_USER'
            $null = New-LabExternalRuntimeContainerImagePlan -Provider docker -SqlVersion 2022 -SoftwarePlans @($invalid) -AllowPreview
        }
        catch { $arbitraryRejected = $_.Exception.Message -match 'SOFTWARE_PLAN_REJECTED' }

        $resolved = $dockerSoftwarePlan | Select-Object *
        $resolved.Status = 'RESOLVED'
        $resolved.ReasonCode = $null
        $resolved.Reason = $null
        $receipt = New-LabSoftwareInstallationReceipt -Plan $resolved -Postconditions @(
            [PSCustomObject]@{ Id='python-data-roundtrip'; Status='PASS'; RuntimeVersion='3.10.12'; WorkerIdentity='mssql_satellite' }
        )
        $runDirectory = Join-Path $Root 'run'
        New-Item -Path $runDirectory -ItemType Directory -Force | Out-Null
        $null = Save-LabExternalRuntimeInstallationReceipts -RunDirectory $runDirectory -InstanceId sql -Receipts @($receipt)
        $receiptText = Get-Content -LiteralPath (Join-Path $runDirectory 'software-installation-receipts.json') -Raw -Encoding utf8

        $cleanupDirectory = Join-Path $Root 'cleanup-binding'
        New-Item -Path $cleanupDirectory -ItemType Directory -Force | Out-Null
        $cleanupRunState = [PSCustomObject]@{
            RunId='external-runtime-plan-key'; ScopeId='scope-external-runtime-plan-key'; RunDir=$cleanupDirectory
            metadata=[PSCustomObject]@{ name='external-runtime-plan-key' }
        }
        $null = New-CleanupPlan -RunDir $cleanupDirectory -RunId $cleanupRunState.RunId `
            -ScopeId $cleanupRunState.ScopeId -ProviderSubRuns @(
                [PSCustomObject]@{ id='provider-docker'; provider='docker' }
            )
        $null = Add-LabInstanceCleanupPlan -Instance ([PSCustomObject]@{
            id='sql'; provider='docker'; drives=@()
        }) -RunState $cleanupRunState -SoftwarePlans @($dockerSoftwarePlan)
        $cleanupPlan = Get-Content -LiteralPath (Join-Path $cleanupDirectory 'cleanup-plan.json') `
            -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30

        [PSCustomObject]@{
            Recipe = Get-LabExternalRuntimeContainerRecipe
            DockerPlan = $dockerImagePlan
            PodmanPlan = $podmanImagePlan
            Docker2025Plan = $docker2025ImagePlan
            Recipe2025 = Get-LabExternalRuntimeContainerRecipe -SqlVersion 2025
            DockerRPlan = $dockerRImagePlan
            PodmanRPlan = $podmanRImagePlan
            CombinedPlan = $combinedImagePlan
            DockerJavaPlan = $dockerJavaImagePlan
            PodmanJavaPlan = $podmanJavaImagePlan
            Docker2019JavaPlan = $docker2019JavaImagePlan
            Recipe2019 = Get-LabExternalRuntimeContainerRecipe -SqlVersion 2019
            PythonJavaPlan = $pythonJavaImagePlan
            RJavaPlan = $rJavaImagePlan
            AllPlan = $allImagePlan
            SoftwarePlans = @($dockerSoftwarePlan,$podmanSoftwarePlan,$dockerRSoftwarePlan,$podmanRSoftwarePlan,$dockerJavaSoftwarePlan,$podmanJavaSoftwarePlan)
            MultiDatabaseCompensation = $multiDatabaseCompensation
            ArbitraryRejected = $arbitraryRejected
            ReceiptSanitized = $receiptText -notmatch '(?i)https?://|[A-Z]:\\|/usr/|RecipeRoot|Containerfile'
            ReceiptContract = ($receiptText | ConvertFrom-Json -Depth 30).contract.name
            CleanupPlan = $cleanupPlan
        }
    } $testRoot

    Add-CheckResult -Name 'Rezept ist versioniert und bindet SQL-Basisimage per MCR-Digest' -Success (
        $result.Recipe.contract.name -eq 'SqlServerLab.ExternalRuntimeContainerRecipe' -and
        $result.Recipe.baseImage.reference -match '@sha256:[a-f0-9]{64}$' -and
        $result.Recipe.baseImage.reference -notmatch ':latest'
    )
    Add-CheckResult -Name 'Python-Lock und Rezept besitzen dieselben acht versionierten SHA-256-Artefakte' -Success (
        @($result.Recipe.runtimes.Python.artifacts).Count -eq 8 -and
        @($result.Recipe.runtimes.Python.artifacts | Where-Object { [string]$_.sha256 -match '^[a-f0-9]{64}$' }).Count -eq 8
    )
    Add-CheckResult -Name 'R-Rezept bindet R 4.2.3, OCI-Stage und sechs Paketarchive per SHA-256' -Success (
        $result.Recipe.runtimes.R.runtimeVersion -eq '4.2.3' -and
        $result.Recipe.runtimes.R.runtimeImage.reference -match '@sha256:[a-f0-9]{64}$' -and
        @($result.Recipe.runtimes.R.artifacts).Count -eq 6 -and
        @($result.Recipe.runtimes.R.artifacts | Where-Object { [string]$_.sha256 -match '^[a-f0-9]{64}$' }).Count -eq 6
    )
    Add-CheckResult -Name 'Java-Rezept bindet JDK 11.0.32, Extension 1.1.1, drei SDK-Quellen und beide erzeugten JARs per SHA-256' -Success (
        $result.Recipe.runtimes.Java.runtimeVersion -eq '11' -and
        @($result.Recipe.runtimes.Java.artifacts).Count -eq 5 -and
        @($result.Recipe.runtimes.Java.generatedArtifacts).Count -eq 2 -and
        @($result.Recipe.runtimes.Java.artifacts + $result.Recipe.runtimes.Java.generatedArtifacts | Where-Object {
            [string]$_.sha256 -match '^[a-f0-9]{64}$'
        }).Count -eq 7
    )
    Add-CheckResult -Name 'SQL-Satellite-OpenSSL-Vertrag bindet nur die digestgebundenen Runtimebibliotheken' -Success (
        $result.Recipe.recipeVersion -eq '6' -and
        $result.Recipe.sqlSatelliteCompatibility.id -eq 'sql-server-2022-ubuntu-openssl-runtime-links' -and
        @($result.Recipe.sqlSatelliteCompatibility.links).Count -eq 2 -and
        $result.Recipe.sqlSatelliteCompatibility.links[0].path -eq '/usr/lib/x86_64-linux-gnu/libssl.so' -and
        $result.Recipe.sqlSatelliteCompatibility.links[0].target -eq 'libssl.so.3' -and
        $result.Recipe.sqlSatelliteCompatibility.links[1].path -eq '/usr/lib/x86_64-linux-gnu/libcrypto.so' -and
        $result.Recipe.sqlSatelliteCompatibility.links[1].target -eq 'libcrypto.so.3'
    )
    Add-CheckResult -Name 'Freigegebene Linux-Varianten loesen ohne Preview-Bypass fuer beide Provider auf' -Success (
        @($result.SoftwarePlans).Count -eq 6 -and
        @($result.SoftwarePlans | Where-Object Status -ne 'RESOLVED').Count -eq 0 -and
        @($result.SoftwarePlans | Where-Object RecipeVersion -ne '6').Count -eq 0 -and
        $result.DockerPlan.EvidenceStatus -eq 'SUPPORTED' -and
        $result.PodmanPlan.EvidenceStatus -eq 'SUPPORTED' -and
        $result.Docker2025Plan.EvidenceStatus -eq 'SUPPORTED' -and
        $result.Docker2025Plan.BaseImageDigest -eq '86cc6144ef39bb0fbed2329e1ad79b13ee82e7b2e4739213a0db0800e668a74a' -and
        $result.Docker2025Plan.ExtensibilityDebVersion -eq '17.0.4065.4-1' -and
        $result.Docker2025Plan.LaunchMode -eq 'sql2025-namespace-v1' -and
        $result.Recipe2025.operatingSystem -eq 'ubuntu-24.04' -and
        $result.Docker2019JavaPlan.BaseImageDigest -eq '46f719fd3457d4e7e8e5845fe00c35c20e7bae7ff1e8b9fe595f2a81029f5ba8' -and
        $result.Docker2019JavaPlan.ExtensibilityDebVersion -eq '15.0.4480.2-1' -and
        $result.Docker2019JavaPlan.LaunchMode -eq 'sql2019-namespace-v1' -and
        $result.Recipe2019.operatingSystem -eq 'ubuntu-20.04'
    )
    Add-CheckResult -Name 'Docker und Podman konsumieren denselben providerneutralen OCI-Image-Key' -Success (
        $result.DockerPlan.ImageKey -eq $result.PodmanPlan.ImageKey -and
        $result.DockerPlan.Image -eq $result.PodmanPlan.Image -and
        $result.DockerPlan.ImageKey -match '^[a-f0-9]{64}$'
    )
    Add-CheckResult -Name 'Derived-Image-Plaene binden die exakten Resolver-PlanKeys' -Success (
        @($result.DockerPlan.SoftwarePlanKeys).Count -eq 1 -and
        $result.DockerPlan.SoftwarePlanKeys[0] -eq $result.SoftwarePlans[0].PlanKey -and
        @($result.CombinedPlan.SoftwarePlanKeys).Count -eq 2 -and
        @($result.CombinedPlan.SoftwarePlanKeys | Where-Object { $_ -notin @(
            $result.SoftwarePlans[0].PlanKey, $result.SoftwarePlans[2].PlanKey
        ) }).Count -eq 0
    )
    Add-CheckResult -Name 'Image-Key bindet alle sieben Python-Kontextdateien mit SHA-256' -Success (
        @($result.DockerPlan.ContextEvidence).Count -eq 7 -and
        @($result.DockerPlan.ContextEvidence | Where-Object { $_.sha256 -match '^[a-f0-9]{64}$' }).Count -eq 7
    )
    Add-CheckResult -Name 'R-Image-Key ist providerneutral und bindet genau den runtime-r-Stage' -Success (
        $result.DockerRPlan.ImageKey -eq $result.PodmanRPlan.ImageKey -and
        $result.DockerRPlan.BuildStage -eq 'runtime-r' -and
        $result.DockerRPlan.BuildTokens -join ',' -eq 'r' -and
        @($result.DockerRPlan.ContextEvidence).Count -eq 6
    )
    Add-CheckResult -Name 'Kombinierter R-Python-Plan verwendet kanonische Reihenfolge und vollständigen Kontext' -Success (
        $result.CombinedPlan.BuildStage -eq 'runtime-r-python' -and
        $result.CombinedPlan.BuildTokens -join ',' -eq 'r,python' -and
        @($result.CombinedPlan.ContextEvidence).Count -eq 9 -and
        $result.CombinedPlan.ImageKey -notin @($result.DockerPlan.ImageKey, $result.DockerRPlan.ImageKey)
    )
Add-CheckResult -Name 'Java-Image-Key ist providerneutral und bindet acht vollständige Kontextdateien' -Success (
        $result.DockerJavaPlan.ImageKey -eq $result.PodmanJavaPlan.ImageKey -and
        $result.DockerJavaPlan.BuildStage -eq 'runtime-java' -and
        $result.DockerJavaPlan.BuildTokens -join ',' -eq 'java' -and
        @($result.DockerJavaPlan.ContextEvidence).Count -eq 8
)
Add-CheckResult -Name 'Java-only verwendet einen frühen finalen Build-Target ohne Python-/R-Vorstages' -Success (
    [string]$result.DockerJavaPlan.BuildTarget -eq 'selected-runtime-java' -and
    [string]$result.PodmanJavaPlan.BuildTarget -eq 'selected-runtime-java' -and
    (Get-Content -LiteralPath (Join-Path $repoRoot 'Images/ExternalLanguages/Linux/Containerfile') -Raw -Encoding utf8) -match 'FROM runtime-java AS selected-runtime-java' -and
    (Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ContainerImageArtifact.ps1') -Raw -Encoding utf8) -match "'--target', \[string\]\`$ImagePlan\.BuildTarget"
)
    Add-CheckResult -Name 'Alle Java-Kombinationen verwenden kanonische und vorhandene OCI-Stages' -Success (
        $result.PythonJavaPlan.BuildStage -eq 'runtime-python-java' -and
        $result.RJavaPlan.BuildStage -eq 'runtime-r-java' -and
        $result.AllPlan.BuildStage -eq 'runtime-r-python-java' -and
        $result.AllPlan.BuildTokens -join ',' -eq 'r,python,java' -and
        @($result.AllPlan.ContextEvidence).Count -eq 13
    )
    Add-CheckResult -Name 'Fehler in einer spaeteren Java-Zieldatenbank kompensiert fruehere Neuanlagen rueckwaerts' -Success $result.MultiDatabaseCompensation
    Add-CheckResult -Name 'Beliebig behauptete Softwareplan-Status werden abgelehnt' -Success $result.ArbitraryRejected
    Add-CheckResult -Name 'Run-Receipt bleibt geheimnis- und hostpfadfrei' -Success (
        $result.ReceiptSanitized -and $result.ReceiptContract -eq 'SqlServerLab.RunSoftwareInstallationReceipts'
    )
    Add-CheckResult -Name 'Cleanup bindet Resolver-PlanKey und behaelt wiederverwendbare Image-Artefakte' -Success (
        @($result.CleanupPlan.steps).Count -eq 1 -and
        $result.CleanupPlan.steps[0].softwareContract.contract.name -eq 'SqlServerLab.SoftwareCleanupBinding' -and
        $result.CleanupPlan.steps[0].softwareContract.planKeys[0] -eq $result.SoftwarePlans[0].PlanKey -and
        $result.CleanupPlan.steps[0].softwareContract.softwareIds[0] -eq 'sql-python' -and
        $result.CleanupPlan.steps[0].softwareContract.artifactRetention -eq 'reusable-artifacts-retained'
    )

    $containerfile = Get-Content -LiteralPath (Join-Path $repoRoot 'Images/ExternalLanguages/Linux/Containerfile') -Raw -Encoding utf8
    $launcher = Get-Content -LiteralPath (Join-Path $repoRoot 'Images/ExternalLanguages/Linux/launch-external-runtime.sh') -Raw -Encoding utf8
    $pythonWheelInstaller = Get-Content -LiteralPath (Join-Path $repoRoot 'Images/ExternalLanguages/Linux/install-python-wheels.py') -Raw -Encoding utf8
    $rInstaller = Get-Content -LiteralPath (Join-Path $repoRoot 'Images/ExternalLanguages/Linux/install-r-runtime.sh') -Raw -Encoding utf8
    $javaInstaller = Get-Content -LiteralPath (Join-Path $repoRoot 'Images/ExternalLanguages/Linux/install-java-runtime.sh') -Raw -Encoding utf8
    Add-CheckResult -Name 'Containerfile bindet Microsoft-Paket, EULA und sichere Launch-Metadaten' -Success (
        $containerfile -match 'mssql-server-extensibility_16\.0\.4265\.3-1_amd64\.deb' -and
        $containerfile -match '50df89ac3d1176f6227a9db46d1d8128cb3a326718515082f5ca161028610226' -and
        $containerfile -match 'accepteulaml Y' -and
        $containerfile -match 'required-cgroup-version="1"' -and
        $containerfile -match 'namespace-isolation="true"' -and
        $containerfile -match 'outbound-access="false"'
    )
    Add-CheckResult -Name 'Containerfile behebt SQL-Satellite-OpenSSL-Aufloesung ohne ungesperrte Pakete' -Success (
        $containerfile -match 'OPENSSL_SONAME=3' -and
        $containerfile -match 'libssl\.so\.\$\{OPENSSL_SONAME\}' -and
        $containerfile -match 'libcrypto\.so\.\$\{OPENSSL_SONAME\}' -and
        $result.Recipe2019.opensslSoname -eq '1.1' -and $result.Recipe2025.opensslSoname -eq '3' -and
        $containerfile -notmatch '(?i)apt-get\s+install[^\r\n]*libssl-dev'
    )
    Add-CheckResult -Name 'Python- und R-Zielstages binden die native libgomp-Laufzeit hashverifiziert' -Success (
        @($result.Recipe.runtimeLibraries).Count -eq 1 -and
        $result.Recipe.runtimeLibraries[0].artifact.id -eq 'ubuntu-jammy-libgomp1' -and
        $result.Recipe.runtimeLibraries[0].artifact.sha256 -eq '870c27299185a5dd4accad3b15bf82a7409fd7073cccaa8025875307da4d0ce2' -and
        @($result.Recipe.runtimeLibraries[0].languages | Sort-Object) -join ',' -eq 'Python,R' -and
        $containerfile -match 'mkdir -p /opt/sql-server-lab/runtime-libraries/libgomp1' -and
        $containerfile -match 'dpkg-deb -x /tmp/libgomp1\.deb' -and
        $containerfile -match 'sha256sum --check --strict' -and
        @([regex]::Matches($containerfile, 'COPY --from=runtime-openmp .*libgomp\.so\.1\*')).Count -eq 2
    )
    Add-CheckResult -Name 'Launcher deaktiviert weder Namespace-Isolation noch Outbound-Schutz' -Success (
        $launcher -match 'runuser -u mssql_launchpadd -- /opt/mssql/bin/launchpadd &' -and
        $launcher -match 'runuser -u mssql -- "\$@" &' -and
        $launcher -notmatch '(?i)-usens=false|enableOutboundAccess=true'
    )
    Add-CheckResult -Name 'Jedes Image synchronisiert EULA und Extensibility-Konfiguration rollback-sicher beim Start' -Success (
        $containerfile -match 'external-runtime-mssql\.conf' -and
        $launcher -match 'test "\$\{desired_ml_eula\}" = ''Y''' -and
        $launcher -match 'mssql-conf set EULA accepteulaml "\$\{desired_ml_eula\}"' -and
        $launcher -match 'for setting in pythonbinpath rbinpath datadirectories' -and
        $launcher -match 'mssql-conf set "extensibility\.\$\{setting\}"' -and
        $launcher -match 'mssql-conf unset "extensibility\.\$\{setting\}"' -and
        $launcher -match '/var/opt/mssql-extensibility/data /var/opt/mssql-extensibility/sandboxes' -and
        $launcher -notmatch '/var/opt/mssql-extensibility/externallibrar'
    )
    Add-CheckResult -Name 'Wheel-Installation erhaelt nur sichere ausfuehrbare Modusbits' -Success (
        $pythonWheelInstaller -match 'member\.external_attr >> 16' -and
        $pythonWheelInstaller -match '0o755 if archive_mode & 0o111 else 0o644'
    )
    Add-CheckResult -Name 'R-Build bleibt hashgebunden, compilerfrei im Ziel und ABI-minimal' -Success (
        $containerfile -match 'rocker/r-ver@sha256:22202dfb31f3a1b515936bac559a9f56b67585adce2c14d063f97478940d374a' -and
        $containerfile -match 'FROM runtime-base AS runtime-r' -and
        $containerfile -match 'FROM runtime-r AS runtime-r-python' -and
        $containerfile -match 'libgfortran\.so\.5' -and $containerfile -match 'liblapack\.so\.3' -and
        $containerfile -notmatch '(?m)^FROM runtime-r.*\b(gcc|g\+\+|build-essential)\b' -and
        $rInstaller -match 'sha256sum --check --strict' -and
        $rInstaller -notmatch 'install\.packages\s*\('
    )
    Add-CheckResult -Name 'Java-Build ist hashgebunden, erzeugt SDK und Probe reproduzierbar und liefert nur eine jlink-JRE aus' -Success (
        $containerfile -match 'FROM runtime-base AS java-build' -and
        $containerfile -match 'FROM runtime-base AS runtime-java' -and
        $containerfile -match 'FROM runtime-r-python AS runtime-r-python-java' -and
        $containerfile -match '087ef4e0d1b9bee661c7fed19cbb01a17c7c2a2a341a4bc178c1205bae4d0f00' -and
        $containerfile -match 'e9604092b910fbc52d084d3c66ec55e3d2920cc703b382f8d4c865677b5910a0' -and
        $javaInstaller -match 'sha256sum --check --strict' -and
        $javaInstaller -match 'jlink' -and
        $javaInstaller -match 'test ! -e .*jre/bin/javac' -and
        $javaInstaller -match 'test -x .*jre/lib/jspawnhelper' -and
        $javaInstaller -notmatch '(?i)apt-get|curl\s'
    )
    Add-CheckResult -Name 'Jede Java-Stage bindet die compilerfreie JRE in den Launchpad-Sandboxvertrag ein' -Success (
        ([regex]::Matches($containerfile, 'mssql-conf set extensibility datadirectories[^\r\n]*/opt/sql-server-lab/java')).Count -eq 4 -and
        $containerfile -match 'runtime-java[\s\S]*?datadirectories /opt/sql-server-lab/java' -and
        $containerfile -match 'runtime-r-java[\s\S]*?datadirectories /usr/local/lib/R:/opt/sql-server-lab/java' -and
        $containerfile -match 'runtime-python-java[\s\S]*?datadirectories /usr/lib:/usr/lib/python3\.10/dist-packages:/opt/sql-server-lab/java' -and
        $containerfile -match 'runtime-r-python-java[\s\S]*?datadirectories /usr/local/lib/R:/usr/lib:/usr/lib/python3\.10/dist-packages:/opt/sql-server-lab/java'
    )

    $artifactSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ContainerImageArtifact.ps1') -Raw -Encoding utf8
    $dockerSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Docker/DockerProvider.ps1') -Raw -Encoding utf8
    $podmanSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Podman/PodmanProvider.ps1') -Raw -Encoding utf8
    $newLabSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/New-SqlServerLab.ps1') -Raw -Encoding utf8
    $lifecycleSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ExternalRuntimeLifecycle.ps1') -Raw -Encoding utf8
    $acceptanceSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-ExternalRuntimeContainerAcceptance.ps1') -Raw -Encoding utf8
    $hostAcceptanceSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-ExternalRuntimeContainerHyperVHost.ps1') -Raw -Encoding utf8
    $dockerDefinition = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Docker/provider.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    $podmanDefinition = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Podman/provider.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    $requiredLaunchCapabilities = @('CHOWN','DAC_OVERRIDE','KILL','SETGID','SETUID','SYS_ADMIN','MKNOD','SETPCAP','NET_ADMIN','NET_RAW','SYS_PTRACE')
    Add-CheckResult -Name 'Build akzeptiert nur bekannte Provider und arraygebundene Argumente' -Success (
        $artifactSource -match "ValidateSet\('docker', 'podman'\)" -and
        $artifactSource -match '& \$provider @buildArguments' -and
        $artifactSource -notmatch '(?i)Invoke-Expression|ScriptBlock\.Create'
    )
    Add-CheckResult -Name 'Paketlocks binden sichere Dateinamen an den exakten URL-Pfad' -Success (
        $artifactSource -match 'EXTERNAL_RUNTIME_PACKAGE_LOCK_FILENAME_MISMATCH' -and
        $artifactSource -match 'GetFileName\(\$sourceUri\.AbsolutePath\)'
    )
    Add-CheckResult -Name 'Image-Reuse und Build sind je Artifact Store serialisiert' -Success (
        $artifactSource -match '(?s)function Invoke-LabExternalRuntimeContainerImageBuild\s*\{.*?Invoke-LabArtifactStoreLock.*?Invoke-LabExternalRuntimeContainerImageBuildCore'
    )
    Add-CheckResult -Name 'Podman-Neustart behandelt nur die bekannte Portfreigabe-Race zeitlich begrenzt' -Success (
        $lifecycleSource -match 'if \(\$Provider -eq ''podman''\)' -and
        $lifecycleSource -match 'Restart-PodmanInstance' -and
        $podmanSource -match '(?s)function Restart-PodmanInstance\s*\{.*?Stop-PodmanInstance.*?Start-PodmanInstance' -and
        $podmanSource -match 'cannot listen on the TCP port\.\*address already in use' -and
        $podmanSource -match 'Stopwatch' -and
        $podmanSource -match 'PODMAN_CONTAINER_START_PORT_RELEASE_TIMEOUT' -and
        $podmanSource -notmatch '(?m)^\s*podman restart '
    )
    Add-CheckResult -Name 'Native Acceptance prueft den unveraenderten freigegebenen Katalog providergetrennt' -Success (
        @('derived-image-build','sql-external-runtime' | Where-Object { @($dockerDefinition.capabilities) -notcontains $_ }).Count -eq 0 -and
        @('derived-image-build','sql-external-runtime' | Where-Object { @($podmanDefinition.capabilities) -notcontains $_ }).Count -eq 0 -and
        $acceptanceSource -match "ValidateSet\('docker', 'podman'\)" -and
        $acceptanceSource -match "variant\.status -ne 'SUPPORTED'" -and
        $acceptanceSource -match 'catalog-supported-native-acceptance' -and
        $acceptanceSource -notmatch '(?m)\$variant\.status\s*=' -and
        $acceptanceSource -notmatch '(?m)\$providerDefinition\.capabilities\s*=' -and
        $hostAcceptanceSource -match 'foreach \(\$provider in @\(''docker'',''podman''\)\)' -and
        $hostAcceptanceSource -match 'sudo pwsh[^\r\n]+Invoke-ExternalRuntimeContainerAcceptance\.ps1' -and
        $hostAcceptanceSource -match "if \(\`$KeepOnFailure\) \{ ' -KeepOnFailure' \}"
    )
    Add-CheckResult -Name 'Root/cgroup und minimale Capabilities werden nur durch den exakten Launchmodus gebunden' -Success (
        ($result.Recipe.launchContract.requiredLinuxCapabilities -join ',') -eq ($requiredLaunchCapabilities -join ',') -and
        $containerfile -match 'required-capabilities="CHOWN,DAC_OVERRIDE,KILL,SETGID,SETUID,SYS_ADMIN,MKNOD,SETPCAP,NET_ADMIN,NET_RAW,SYS_PTRACE"' -and
        $artifactSource -match 'CHOWN,DAC_OVERRIDE,KILL,SETGID,SETUID,SYS_ADMIN,MKNOD,SETPCAP,NET_ADMIN,NET_RAW,SYS_PTRACE' -and
        $newLabSource -match 'CHOWN,DAC_OVERRIDE,KILL,SETGID,SETUID,SYS_ADMIN,MKNOD,SETPCAP,NET_ADMIN,NET_RAW,SYS_PTRACE' -and
        $dockerSource -match "ExternalRuntimeLaunchMode -in @\('sql2019-namespace-v1','sql2022-namespace-v1','sql2025-namespace-v1'\)" -and
        $dockerSource -match "'--user', '0:0'" -and
        @($requiredLaunchCapabilities | Where-Object { $dockerSource -notmatch "'--cap-add', '$_'" }).Count -eq 0 -and
        $dockerSource -match "'--cap-add', 'SYS_ADMIN'" -and
        $dockerSource -match "'--cap-add', 'NET_ADMIN'" -and
        $dockerSource -match "'--cap-add', 'SYS_PTRACE'" -and
        $dockerSource -match "'--security-opt', 'apparmor=unconfined'" -and
        $dockerSource -match "'--security-opt', 'seccomp=unconfined'" -and
        $dockerSource -match "'/sys/fs/cgroup:/sys/fs/cgroup:rw'" -and
        $dockerSource -notmatch "'--privileged'" -and
        $podmanSource -match "ExternalRuntimeLaunchMode -in @\('sql2019-namespace-v1','sql2022-namespace-v1','sql2025-namespace-v1'\)" -and
        $podmanSource -match "'--user', '0:0'" -and
        @($requiredLaunchCapabilities | Where-Object { $podmanSource -notmatch "'--cap-add', '$_'" }).Count -eq 0 -and
        $podmanSource -match "'--cap-add', 'SYS_ADMIN'" -and
        $podmanSource -match "'--cap-add', 'NET_ADMIN'" -and
        $podmanSource -match "'--cap-add', 'SYS_PTRACE'" -and
        $podmanSource -match "'--security-opt', 'apparmor=unconfined'" -and
        $podmanSource -match "'--security-opt', 'seccomp=unconfined'" -and
        $podmanSource -match "'/sys/fs/cgroup:/sys/fs/cgroup:rw'" -and
        $podmanSource -match "cp -a '\`$ContainerPath'/\. /sql-lab-volume-init/" -and
        $podmanSource -match 'ExternalRuntimeLaunchMode -eq ''none''\) \{ \$volumeOptions \+= ''U'' \}' -and
        $podmanSource -notmatch "'--privileged'" -and
        $artifactSource -match 'if \(\$rootless\)'
    )
    Add-CheckResult -Name 'Software- und Host-Gates laufen vor Run-State und jeder Provider-Mutation' -Success (
        $newLabSource.IndexOf('Resolve-LabExternalRuntimePlansForInstance') -ge 0 -and
        $newLabSource.IndexOf('Resolve-LabExternalRuntimePlansForInstance') -lt $newLabSource.IndexOf('New-LabRunState') -and
        $newLabSource.IndexOf('Test-LabExternalRuntimeContainerHost') -lt $newLabSource.IndexOf('New-LabRunState')
    )
    Add-CheckResult -Name 'Image-Build erfolgt erst nach Cleanup-Plan und bleibt außerhalb normaler Run-Cleanup-Schritte' -Success (
        $newLabSource.IndexOf('New-CleanupPlan') -lt $newLabSource.IndexOf('Invoke-LabExternalRuntimeContainerImageBuild') -and
        $newLabSource -notmatch "ResourceType 'image'"
    )
    Add-CheckResult -Name 'Run-State persistiert Image-Key und verifizierte Software-Receipt-Zusammenfassung' -Success (
        $newLabSource -match "Status = 'IMAGE_READY'" -and
        $newLabSource -match "ExternalRuntime\.Status = 'EXTENSIONS_READY_RUN'" -and
        $newLabSource -match 'SoftwarePlanKeys\s*=\s*@\(\$imagePlan\.SoftwarePlanKeys\)' -and
        $newLabSource -match 'PlanKey\s*=\s*\[string\]\$_.PlanKey' -and
        $newLabSource -match 'externalRuntime\s+= \$_\.ExternalRuntime'
    )
    Add-CheckResult -Name 'Java-Postcondition registriert datenbankgebunden, prueft Drift und kompensiert nur neu erzeugte Objekte' -Success (
        $lifecycleSource -match 'Register-LabJavaExternalRuntimeDatabaseObjects' -and
        $lifecycleSource -match "@language = N'Java'" -and
        @([regex]::Matches($lifecycleSource, 'FROM \(CONTENT = N''\$\(\$platformContract\.[A-Za-z]+Path\)'', PLATFORM = \$\(\$platformContract\.Platform\)\)\s+WITH \(LANGUAGE = ''Java''\)')).Count -eq 2 -and
        $lifecycleSource -match 'sqlserverlab\.SqlServerLabExternalRuntimeProbe' -and
        $lifecycleSource -match 'EXTERNAL_RUNTIME_JAVA_LANGUAGE_DRIFT' -and
        $lifecycleSource -match 'Undo-LabJavaExternalRuntimeDatabaseObjects' -and
        $lifecycleSource -match 'javaCompensations' -and
        $lifecycleSource -match '(?s)function Invoke-LabJavaExternalRuntimeProbe\s*\{.*?param\(.*?\$RegistrationTracker' -and
        $lifecycleSource -match 'RegistrationTracker\.Registration' -and
        $lifecycleSource -match '\[bool\]\$registration\.CreatedLanguage -or \[bool\]\$prior\.CreatedLanguage' -and
        $lifecycleSource -match "Language -eq 'Java'\) \{ 1 \}" -and
        $lifecycleSource -match 'mssql_satellite'
    )
    Add-CheckResult -Name 'Fehlgeschlagene Java-Kompensation bindet sanitisierte Containerdiagnose' -Success (
        $lifecycleSource -match '(?s)catch \{\s*\$initialFailure = \$_.*?Get-LabContainerReadinessDiagnostic.*?-IncludeLogs.*?EXTERNAL_RUNTIME_INITIALIZATION_AND_COMPENSATION_FAILED' -and
        $lifecycleSource -match 'EXTERNAL_RUNTIME_INITIALIZATION_FAILED:.*?\$containerDiagnostic\.Message'
    )
    Add-CheckResult -Name 'Datenbankgebundene Java-Registrierung laeuft erst nach Create und Restore' -Success (
        $newLabSource.IndexOf('New-SqlServerLabDatabase') -lt $newLabSource.IndexOf('Initialize-LabExternalRuntimes') -and
        $newLabSource.IndexOf('Install-LabSampleDatabase') -lt $newLabSource.IndexOf('Initialize-LabExternalRuntimes')
    )
    Add-CheckResult -Name 'R-Postcondition prueft SQL-Datenroundtrip, Paketversionen und Workeridentitaet' -Success (
        $lifecycleSource -match "@language = N'R'" -and
        $lifecycleSource -match "EXTERNAL_RUNTIME_R_EVIDENCE_INVALID" -and
        $lifecycleSource -match 'packageVersion\("RevoScaleR"\)' -and
        $lifecycleSource -match 'packageVersion\("jsonlite"\)' -and
        $lifecycleSource -match "mssql_satellite"
    )
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "FAIL: $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "External Runtime Container Image Checks: $passed PASS" -ForegroundColor Green
