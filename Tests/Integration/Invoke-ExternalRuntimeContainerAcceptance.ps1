#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt die native External-Runtime-Abnahme fuer Docker oder Podman aus.
.DESCRIPTION
    Prueft die als SUPPORTED katalogisierten Linux-Varianten ohne Katalog- oder
    Provider-Mutation. Der normale New-SqlServerLab-Pfad baut das
    digestgebundene Derived Image, startet SQL Server im sicheren
    launchpadd-Namespace-Modus und prueft zuerst Python. Der Reconcile-Pfad
    wechselt danach journalgebunden auf ein neues Python-/R-/Java-Image und
    prueft alle Sprachen ueber sp_execute_external_script. Nach einem Restart werden die fachlichen
    Postconditions erneut ausgefuehrt. Run-Ressourcen und das explizit
    test-eigene, wiederverwendbare Image werden getrennt bereinigt.
.PARAMETER Provider
    Der nativ zu pruefende Linux-Containerprovider.
.PARAMETER EvidencePath
    Ziel fuer die sanitisierte JSON-Evidence. Der Pfad muss ausserhalb des
    Repositorys liegen, wenn die Evidence nicht absichtlich separat behandelt
    wird.
.PARAMETER KeepOnFailure
    Behaelt Run und Derived Image bei einem Fehler fuer eine manuelle Diagnose.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
    [ValidateSet('2019', '2022', '2025')][string]$SqlVersion = '2022',
    [Parameter(Mandatory)][string]$EvidencePath,
    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
if (-not $IsLinux) {
    throw 'EXTERNAL_RUNTIME_CONTAINER_ACCEPTANCE_REQUIRES_LINUX'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-server-lab-external-runtime-$Provider-$([guid]::NewGuid().ToString('N'))"
$stateRoot = Join-Path $testRoot 'state'
$manifestPath = Join-Path $testRoot 'manifest.json'
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$previousPodmanNetwork = $env:SQL_SERVER_LAB_PODMAN_NETWORK
$previousPodmanSubnet = $env:SQL_SERVER_LAB_PODMAN_SUBNET
$lab = $null
$imageName = $null
$initialImageName = $null
$allRuntimeImageName = $null
$completed = $false
$acceptanceNetworkName = $null

function Assert-ExternalRuntimeAcceptance {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Description,
        [string]$Evidence
    )
    if (-not $Condition) {
        throw "EXTERNAL_RUNTIME_CONTAINER_ACCEPTANCE_FAILED: $Description$(if ($Evidence) { ": $Evidence" })"
    }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

try {
    if ($Provider -eq 'podman') {
        $acceptanceNetworkName = 'SQL_LAB_EXTLANG_PODMAN'
        $env:SQL_SERVER_LAB_PODMAN_NETWORK = $acceptanceNetworkName
        $env:SQL_SERVER_LAB_PODMAN_SUBNET = '10.254.27.0/24'
    }
    foreach ($command in @($Provider, 'sqlcmd')) {
        Assert-ExternalRuntimeAcceptance ([bool](Get-Command $command -ErrorAction SilentlyContinue)) "Befehl '$command' ist verfuegbar"
    }
    & $Provider info 1>$null 2>$null
    Assert-ExternalRuntimeAcceptance ($LASTEXITCODE -eq 0) "Runtime '$Provider' ist erreichbar"

    New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
    $env:SQL_SERVER_LAB_STATE = $stateRoot
    $token = [guid]::NewGuid().ToString('N').Substring(0, 16)
    $saPlain = "ExtLang_${token}!Aa7"
    $saPassword = ConvertTo-SecureString $saPlain -AsPlainText -Force
    $manifest = [ordered]@{
        name = "external-runtime-$Provider-native"
        automation = [ordered]@{ mode = 'unattended' }
        instances = @([ordered]@{
            id = 'external-runtime'
            version = $SqlVersion
            provider = $Provider
            profile = 'performance'
            software = @(if ($SqlVersion -eq '2019') {
                [ordered]@{ id='sql-java'; scope='sqlExternalRuntime' }
            } else {
                [ordered]@{ id='sql-python'; scope='sqlExternalRuntime' }
            })
            serverConfig = [ordered]@{
                externalScripts = [ordered]@{
                    enabled = $true
                    resourceGovernor = [ordered]@{ maxMemoryPercent=40; maxProcesses=32 }
                }
            }
        })
    }
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8

    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module = Import-Module $modulePath -Force -PassThru
    $catalogState = & $module {
        param($ProviderName,$TargetSqlVersion)
        $expectedIds = if ($TargetSqlVersion -eq '2019') {
            @('sql2022-java11-ubuntu2204-derived')
        } else {
            @(
                'sql2022-python310-ubuntu2204-derived',
                'sql2022-r42-ubuntu2204-derived',
                'sql2022-java11-ubuntu2204-derived'
            )
        }
        $catalog = Get-LabSoftwareCatalog
        $variants = @($catalog.software | ForEach-Object { @($_.variants) } |
            Where-Object { [string]$_.id -in $expectedIds })
        if ($variants.Count -ne $expectedIds.Count) { throw 'EXTERNAL_RUNTIME_CONTAINER_ACCEPTANCE_VARIANTS_MISSING' }
        foreach ($variant in $variants) {
            if ([string]$variant.status -ne 'SUPPORTED' -or @($variant.providers) -notcontains $ProviderName) {
                throw "EXTERNAL_RUNTIME_CONTAINER_ACCEPTANCE_VARIANT_STATE_UNEXPECTED: $($variant.id) / $($variant.status)"
            }
            $targetMajor = switch ($TargetSqlVersion) { '2019' { 15 } '2025' { 17 } default { 16 } }
            if (@($variant.sqlMajorVersions) -notcontains $targetMajor) {
                throw "EXTERNAL_RUNTIME_CONTAINER_ACCEPTANCE_SQL_VERSION_MISSING: $($variant.id) / $TargetSqlVersion"
            }
        }
        $providerDefinition = $script:RegisteredProviders[$ProviderName].Definition
        foreach ($capability in @('derived-image-build','sql-external-runtime')) {
            if (@($providerDefinition.capabilities) -notcontains $capability) {
                throw "EXTERNAL_RUNTIME_CONTAINER_ACCEPTANCE_CAPABILITY_MISSING: $ProviderName / $capability"
            }
        }
        return @($variants | Sort-Object id | ForEach-Object {
            [PSCustomObject]@{ variantId=[string]$_.id; status=[string]$_.status }
        })
    } $Provider $SqlVersion
    Assert-ExternalRuntimeAcceptance (@($catalogState | Where-Object status -ne 'SUPPORTED').Count -eq 0) `
        $(if ($SqlVersion -eq '2019') { 'SQL-2019-Java-Variante und Provider-Capabilities sind freigegeben' } else { 'Alle drei Linux-Varianten und Provider-Capabilities sind freigegeben' })

    $lab = New-SqlServerLab -Manifest $manifestPath -SaPassword $saPassword -StateRoot $stateRoot -SkipAssessment -NonInteractive
    Assert-ExternalRuntimeAcceptance ([string]$lab.State -eq 'Running') 'Lab wurde ueber den normalen Produktpfad provisioniert'
    $instance = @($lab.Instances)[0]
    Assert-ExternalRuntimeAcceptance ([string]$instance.ExternalRuntime.Status -eq 'EXTENSIONS_READY_RUN') 'External-Runtime-State ist EXTENSIONS_READY_RUN'
    Assert-ExternalRuntimeAcceptance (@($instance.ExternalRuntime.Receipts).Count -eq 1) `
        $(if ($SqlVersion -eq '2019') { 'Java besitzt ein Installation-Receipt' } else { 'Python besitzt vor dem Refresh ein Installation-Receipt' })

    if ($SqlVersion -eq '2019') {
        $javaImageKey = [string]$instance.ExternalRuntime.ImageKey
        $javaRuntime = & $module {
            param($ProviderName,$ImageKey,$StateRootPath,$LabInstance,$Password)
            $plan = Resolve-LabExternalRuntimePlan -SoftwareItem ([PSCustomObject]@{
                Id='sql-java'; Version=$null; Variant=$null; InstallMethod=$null; Packages=@(); RequestSource='native-acceptance'
            }) -SqlVersion '2019' -Provider $ProviderName -OperatingSystem linux
            $imagePlan = New-LabExternalRuntimeContainerImagePlan -Provider $ProviderName -SqlVersion '2019' -SoftwarePlans @($plan)
            if ([string]$imagePlan.ImageKey -ne $ImageKey) { throw 'EXTERNAL_RUNTIME_CONTAINER_ACCEPTANCE_IMAGE_KEY_DRIFT' }
            [PSCustomObject]@{
                Plan=$plan
                Host=Test-LabExternalRuntimeContainerHost -Provider $ProviderName -ImagePlan $imagePlan
                ImageReceipt=Get-LabExternalRuntimeContainerImageReceipt -ImageKey $ImageKey -Provider $ProviderName -StateRoot $StateRootPath
                Launchpad=Test-LabExternalRuntimeLaunchpadProcess -Provider $ProviderName -ContainerIdOrName ([string]$LabInstance.ContainerId)
                Probe=Invoke-LabJavaExternalRuntimeProbe -Plan $plan -HostName ([string]$LabInstance.Host) -Port ([int]$LabInstance.Port) -SaPassword $Password -Database master
            }
        } $Provider $javaImageKey $stateRoot $instance $saPassword
        Assert-ExternalRuntimeAcceptance ([string]$javaRuntime.Host.Status -eq 'READY' -and [string]$javaRuntime.Host.CgroupVersion -eq '1') 'Provider läuft nativ auf Linux mit cgroup v1'
        Assert-ExternalRuntimeAcceptance ([string]$javaRuntime.ImageReceipt.status -eq 'IMAGE_READY') 'Digest- und Context-gebundenes Java-Image ist nachgewiesen'
        Assert-ExternalRuntimeAcceptance ([string]$javaRuntime.Launchpad.Status -eq 'PASS' -and [string]$javaRuntime.Probe.Status -eq 'PASS') 'Java besteht SQL-Datenroundtrip und Workerprüfung'
        $imageName = [string]$javaRuntime.ImageReceipt.image

        $restart = Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 300 -Force
        Assert-ExternalRuntimeAcceptance ([string]$restart.Status -eq 'RUNNING' -and [int]$restart.Errors -eq 0) 'Providergebundener Restart erreicht SQL-Readiness'
        $postRestart = & $module {
            param($Plan,$LabInstance,$Password)
            [PSCustomObject]@{
                Launchpad=Test-LabExternalRuntimeLaunchpadProcess -Provider ([string]$LabInstance.Provider) -ContainerIdOrName ([string]$LabInstance.ContainerId)
                Probe=Invoke-LabJavaExternalRuntimeProbe -Plan $Plan -HostName ([string]$LabInstance.Host) -Port ([int]$LabInstance.Port) -SaPassword $Password -Database master
            }
        } $javaRuntime.Plan $instance $saPassword
        Assert-ExternalRuntimeAcceptance ([string]$postRestart.Launchpad.Status -eq 'PASS' -and [string]$postRestart.Probe.Status -eq 'PASS') 'Java und launchpadd sind nach Restart erneut bereit'

        $cleanup = Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false
        Assert-ExternalRuntimeAcceptance ([string]$cleanup.Status -eq 'REMOVED') 'Run-Ressourcen wurden über den registrierten Cleanup entfernt'
        $lab = $null
        $imageExistsAfterRunCleanup = @(& $Provider image inspect $imageName 2>$null).Count -gt 0 -and $LASTEXITCODE -eq 0
        Assert-ExternalRuntimeAcceptance $imageExistsAfterRunCleanup 'Wiederverwendbares Java-Image bleibt vom Run-Cleanup getrennt'
        & $Provider image rm --force $imageName 1>$null
        Assert-ExternalRuntimeAcceptance ($LASTEXITCODE -eq 0) "Test-eigenes Derived Image wurde explizit entfernt: $imageName"
        if ($acceptanceNetworkName) {
            & $Provider network rm $acceptanceNetworkName 1>$null
            Assert-ExternalRuntimeAcceptance ($LASTEXITCODE -eq 0) 'Test-eigenes konfliktfreies Podman-Netz wurde explizit entfernt'
        }
        $evidence = [ordered]@{
            contract=[ordered]@{ name='SqlServerLab.ExternalRuntimeContainerAcceptance'; version='1.3' }
            status='PASS'; provider=$Provider; platform='linux'; sqlVersion=$SqlVersion
            cgroupVersion=[string]$javaRuntime.Host.CgroupVersion; rootless=[bool]$javaRuntime.Host.Rootless
            catalogState=@($catalogState); characterization='catalog-supported-native-acceptance'
            image=[ordered]@{ imageKey=$javaImageKey; baseImageDigest=[string]$javaRuntime.ImageReceipt.baseImageDigest; launchMode=[string]$javaRuntime.ImageReceipt.launchMode; retainedAfterRunCleanup=$imageExistsAfterRunCleanup; explicitlyRemoved=$true }
            languages=@([ordered]@{ softwareId='sql-java'; variantId=[string]$javaRuntime.Plan.VariantId; runtimeVersion=[string]$javaRuntime.Probe.RuntimeVersion; workerIdentity=[string]$javaRuntime.Probe.WorkerIdentity; status=[string]$javaRuntime.Probe.Status })
            restart=[ordered]@{ status=[string]$restart.Status; launchpad=[string]$postRestart.Launchpad.Status; probe=[string]$postRestart.Probe.Status }
            cleanup=[ordered]@{ runStatus=[string]$cleanup.Status; reusableImageExplicitlyRemoved=$true; acceptanceNetworkExplicitlyRemoved=[bool]$acceptanceNetworkName }
            completedAt=[DateTimeOffset]::UtcNow.ToString('o')
        }
        $evidenceDirectory = Split-Path -Parent $EvidencePath
        if ($evidenceDirectory) { New-Item -Path $evidenceDirectory -ItemType Directory -Force | Out-Null }
        $evidence | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
        $completed = $true
        Write-Host "External-Runtime-Akzeptanz erfolgreich: $Provider / SQL Server 2019 / Java" -ForegroundColor Green
        return
    }

    $dataMarker = "persisted-$token"
    $null = & $module {
        param($LabInstance,$Password,$Marker)
        Invoke-SqlQuery -HostName ([string]$LabInstance.Host) -Port ([int]$LabInstance.Port) -SaPlain $Password -TimeoutSeconds 90 -Query @"
IF DB_ID(N'ExternalRuntimePersistence') IS NULL CREATE DATABASE [ExternalRuntimePersistence];
EXEC(N'USE [ExternalRuntimePersistence]; IF OBJECT_ID(N''dbo.RefreshMarker'', N''U'') IS NULL CREATE TABLE dbo.RefreshMarker(marker nvarchar(128) NOT NULL); DELETE FROM dbo.RefreshMarker; INSERT dbo.RefreshMarker(marker) VALUES (N''$Marker'');');
"@
    } $instance $saPlain $dataMarker
    Assert-ExternalRuntimeAcceptance $true 'Persistenter SQL-Datenmarker wurde vor dem Refresh geschrieben'

    $initialImageKey = [string]$instance.ExternalRuntime.ImageKey
    $initialImageReceipt = & $module {
        param($ImageKey,$ProviderName,$StateRootPath)
        Get-LabExternalRuntimeContainerImageReceipt -ImageKey $ImageKey -Provider $ProviderName -StateRoot $StateRootPath
    } $initialImageKey $Provider $stateRoot
    $initialImageName = [string]$initialImageReceipt.image
    $manifest.instances[0].software = @(
        [ordered]@{ id='sql-python'; scope='sqlExternalRuntime' },
        [ordered]@{ id='sql-r'; scope='sqlExternalRuntime' },
        [ordered]@{ id='sql-java'; scope='sqlExternalRuntime' }
    )
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    $refreshPlan = Get-SqlServerLabReconcilePlan -RunId $lab.RunId -ManifestPath $manifestPath `
        -InstanceId external-runtime -StateRoot $stateRoot
    Assert-ExternalRuntimeAcceptance ($refreshPlan.HighestChangeClass -eq 'recreate' -and @($refreshPlan.Actions).Count -eq 1) 'Reconcile plant einen einzelnen External-Runtime-Recreate'
    $refresh = Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -ManifestPath $manifestPath `
        -InstanceId external-runtime -ReadinessTimeoutSeconds 300 -StateRoot $stateRoot -Confirm:$false
    $refreshErrors = @($refresh.ExecutionSummary.Errors) -join ' | '
    Assert-ExternalRuntimeAcceptance ([string]$refresh.ExecutionSummary.Status -eq 'SUCCEEDED' -and $refresh.MutationAllowed) `
        "Journalgebundener External-Runtime-Refresh wurde ausgefuehrt (Status=$($refresh.ExecutionSummary.Status); Errors=$refreshErrors)"
    $connectionPath = Join-Path (Join-Path (Join-Path $stateRoot 'runs') $lab.RunId) 'connection-info.json'
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    $instance = @($connection.instances | Where-Object id -eq 'external-runtime')[0]
    Assert-ExternalRuntimeAcceptance (@($instance.ExternalRuntime.Receipts).Count -eq 3) 'Python, R und Java besitzen nach dem Refresh Installation-Receipts'
    $journalPath = Join-Path (Join-Path (Join-Path $stateRoot 'runs') $lab.RunId) 'external-runtime-refresh.json'
    $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    Assert-ExternalRuntimeAcceptance ([string]$journal.status -eq 'COMPLETED') 'Refresh-Journal ist nach State-Commit und Alt-Container-Cleanup abgeschlossen'
    Assert-ExternalRuntimeAcceptance ([string]$journal.containerName -eq [string]$instance.containerName) 'Ersatzcontainer behaelt den kanonischen Cleanup-Namen'
    $markerAfterRefresh = & $module {
        param($LabInstance,$Password)
        @(Invoke-SqlQuery -HostName ([string]$LabInstance.Host) -Port ([int]$LabInstance.Port) -SaPlain $Password `
            -Database ExternalRuntimePersistence -Query 'SET NOCOUNT ON; SELECT marker FROM dbo.RefreshMarker;' -TimeoutSeconds 90) -join "`n"
    } $instance $saPlain
    Assert-ExternalRuntimeAcceptance ($markerAfterRefresh -match [regex]::Escape($dataMarker)) 'SQL-Datenmarker blieb ueber den Container-Refresh erhalten'

    $receiptPath = Join-Path (Join-Path (Join-Path $stateRoot 'runs') $lab.RunId) 'software-installation-receipts.json'
    Assert-ExternalRuntimeAcceptance (Test-Path -LiteralPath $receiptPath -PathType Leaf) 'Sanitisierte Installation-Receipts wurden persistiert'
    $receiptDocument = Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
    $receipts = @($receiptDocument.instances | Where-Object instanceId -eq 'external-runtime' | ForEach-Object { @($_.receipts) })
    Assert-ExternalRuntimeAcceptance ($receipts.Count -eq 3 -and @($receipts | Where-Object status -ne 'EXTENSIONS_READY_RUN').Count -eq 0) 'Persistierte Receipts sind vollstaendig und bereit'

    $allRuntimeImageKey = [string]$instance.ExternalRuntime.ImageKey
    $allRuntimeImageReceipt = & $module {
        param($ImageKey,$ProviderName,$StateRootPath)
        Get-LabExternalRuntimeContainerImageReceipt -ImageKey $ImageKey -Provider $ProviderName -StateRoot $StateRootPath
    } $allRuntimeImageKey $Provider $stateRoot
    $allRuntimeImageName = [string]$allRuntimeImageReceipt.image

    $manifest.instances[0].software = @(
        [ordered]@{ id='sql-python'; scope='sqlExternalRuntime' },
        [ordered]@{ id='sql-r'; scope='sqlExternalRuntime' }
    )
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    $removalPlan = Get-SqlServerLabReconcilePlan -RunId $lab.RunId -ManifestPath $manifestPath `
        -InstanceId external-runtime -StateRoot $stateRoot
    Assert-ExternalRuntimeAcceptance (@($removalPlan.Diff | Where-Object {
        $_.SoftwareId -eq 'sql-java' -and $_.ChangeClassification.Intent -eq 'remove'
    }).Count -eq 1) 'Reconcile plant Java als explizite Runtime-Entfernung'
    $removalRefresh = Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -ManifestPath $manifestPath `
        -InstanceId external-runtime -ReadinessTimeoutSeconds 300 -StateRoot $stateRoot -Confirm:$false
    $removalErrors = @($removalRefresh.ExecutionSummary.Errors) -join ' | '
    Assert-ExternalRuntimeAcceptance ([string]$removalRefresh.ExecutionSummary.Status -eq 'SUCCEEDED') `
        "Java-Runtime wurde journalgebunden entfernt (Status=$($removalRefresh.ExecutionSummary.Status); Errors=$removalErrors)"
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    $instance = @($connection.instances | Where-Object id -eq 'external-runtime')[0]
    Assert-ExternalRuntimeAcceptance (@($instance.ExternalRuntime.Receipts).Count -eq 2 -and
        @($instance.ExternalRuntime.Receipts.SoftwareId | Sort-Object) -join ',' -eq 'sql-python,sql-r') `
        'Connection-State enthaelt nach Removal nur Python und R'
    $removalJournal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    Assert-ExternalRuntimeAcceptance ([string]$removalJournal.status -eq 'COMPLETED' -and
        @($removalJournal.javaCleanup.records).Count -gt 0) 'Java-DDL-Cleanup ist eigentumsgebunden journalisiert und abgeschlossen'
    $javaObjects = & $module {
        param($LabInstance,$Password)
        @(Invoke-SqlQuery -HostName ([string]$LabInstance.Host) -Port ([int]$LabInstance.Port) -SaPlain $Password -Database master -TimeoutSeconds 90 -Query @'
SET NOCOUNT ON;
SELECT CONCAT(N'SQLLAB_JAVA_OBJECTS|',
    (SELECT COUNT(*) FROM sys.external_languages WHERE language = N'Java'), N'|',
    (SELECT COUNT(*) FROM sys.external_libraries WHERE name IN (N'SqlServerLabJavaSdk', N'SqlServerLabJavaProbe')));
'@) -join "`n"
    } $instance $saPlain
    Assert-ExternalRuntimeAcceptance ($javaObjects -match 'SQLLAB_JAVA_OBJECTS\|0\|0') 'Vom Lab erzeugte Java-Sprache und Libraries wurden entfernt'
    $receiptDocument = Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
    $receipts = @($receiptDocument.instances | Where-Object instanceId -eq 'external-runtime' | ForEach-Object { @($_.receipts) })
    Assert-ExternalRuntimeAcceptance ($receipts.Count -eq 2 -and @($receipts | Where-Object status -ne 'EXTENSIONS_READY_RUN').Count -eq 0) 'Persistierte Receipts enthalten nach Removal nur bereite Zielruntimes'

    $hostAndImage = & $module {
        param($ProviderName,$ImageKey,$StateRootPath,$SoftwareIds,$TargetSqlVersion)
        $plans = @(@($SoftwareIds) | ForEach-Object {
            Resolve-LabExternalRuntimePlan -SoftwareItem ([PSCustomObject]@{
                Id=$_; Version=$null; Variant=$null; InstallMethod=$null; Packages=@(); RequestSource='native-acceptance'
            }) -SqlVersion $TargetSqlVersion -Provider $ProviderName -OperatingSystem linux
        })
        $imagePlan = New-LabExternalRuntimeContainerImagePlan -Provider $ProviderName -SqlVersion $TargetSqlVersion -SoftwarePlans $plans
        if ([string]$imagePlan.ImageKey -ne $ImageKey) { throw 'EXTERNAL_RUNTIME_CONTAINER_ACCEPTANCE_IMAGE_KEY_DRIFT' }
        $hostStatus = Test-LabExternalRuntimeContainerHost -Provider $ProviderName -ImagePlan $imagePlan
        $imageReceipt = Get-LabExternalRuntimeContainerImageReceipt -ImageKey $ImageKey -Provider $ProviderName -StateRoot $StateRootPath
        [PSCustomObject]@{ Host=$hostStatus; ImageReceipt=$imageReceipt; Plans=$plans }
    } $Provider ([string]$instance.ExternalRuntime.ImageKey) $stateRoot @($instance.ExternalRuntime.Receipts.SoftwareId) $SqlVersion
    Assert-ExternalRuntimeAcceptance ([string]$hostAndImage.Host.Status -eq 'READY' -and [string]$hostAndImage.Host.CgroupVersion -eq '1') 'Provider laeuft nativ auf Linux mit cgroup v1'
    Assert-ExternalRuntimeAcceptance ([string]$hostAndImage.ImageReceipt.status -eq 'IMAGE_READY') 'Digest- und Context-gebundenes Derived Image ist nachgewiesen'
    $imageName = [string]$hostAndImage.ImageReceipt.image

    $restart = Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 300 -Force
    Assert-ExternalRuntimeAcceptance ([string]$restart.Status -eq 'RUNNING' -and [int]$restart.Errors -eq 0) 'Providergebundener Restart erreicht SQL-Readiness'
    $postRestart = & $module {
        param($Plans,$LabInstance,$Password)
        $launchpad = Test-LabExternalRuntimeLaunchpadProcess -Provider ([string]$LabInstance.Provider) -ContainerIdOrName ([string]$LabInstance.ContainerId)
        $probes = foreach ($plan in @($Plans)) {
            switch ([string]$plan.Language) {
                'Python' { Invoke-LabPythonExternalRuntimeProbe -Plan $plan -HostName ([string]$LabInstance.Host) -Port ([int]$LabInstance.Port) -SaPassword $Password }
                'R' { Invoke-LabRExternalRuntimeProbe -Plan $plan -HostName ([string]$LabInstance.Host) -Port ([int]$LabInstance.Port) -SaPassword $Password }
                'Java' { Invoke-LabJavaExternalRuntimeProbe -Plan $plan -HostName ([string]$LabInstance.Host) -Port ([int]$LabInstance.Port) -SaPassword $Password -Database master }
            }
        }
        [PSCustomObject]@{ Launchpad=$launchpad; Probes=@($probes) }
    } @($hostAndImage.Plans) $instance $saPassword
    Assert-ExternalRuntimeAcceptance ([string]$postRestart.Launchpad.Status -eq 'PASS') 'launchpadd ist nach Restart bereit'
    Assert-ExternalRuntimeAcceptance (@($postRestart.Probes).Count -eq 2 -and @($postRestart.Probes | Where-Object Status -ne 'PASS').Count -eq 0) 'Python und R bestehen nach Java-Removal und Restart erneut'
    $markerAfterRestart = & $module {
        param($LabInstance,$Password)
        @(Invoke-SqlQuery -HostName ([string]$LabInstance.Host) -Port ([int]$LabInstance.Port) -SaPlain $Password `
            -Database ExternalRuntimePersistence -Query 'SET NOCOUNT ON; SELECT marker FROM dbo.RefreshMarker;' -TimeoutSeconds 90) -join "`n"
    } $instance $saPlain
    Assert-ExternalRuntimeAcceptance ($markerAfterRestart -match [regex]::Escape($dataMarker)) 'SQL-Datenmarker blieb auch ueber den Provider-Restart erhalten'

    $cleanup = Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false
    Assert-ExternalRuntimeAcceptance ([string]$cleanup.Status -eq 'REMOVED') 'Run-Ressourcen wurden ueber den registrierten Cleanup entfernt'
    $lab = $null

    $imageExistsAfterRunCleanup = @(& $Provider image inspect $imageName 2>$null).Count -gt 0 -and $LASTEXITCODE -eq 0
    $initialImageExistsAfterRunCleanup = @(& $Provider image inspect $initialImageName 2>$null).Count -gt 0 -and $LASTEXITCODE -eq 0
    $allRuntimeImageExistsAfterRunCleanup = @(& $Provider image inspect $allRuntimeImageName 2>$null).Count -gt 0 -and $LASTEXITCODE -eq 0
    Assert-ExternalRuntimeAcceptance ($imageExistsAfterRunCleanup -and $initialImageExistsAfterRunCleanup -and $allRuntimeImageExistsAfterRunCleanup) 'Alle drei wiederverwendbaren Images bleiben vom normalen Run-Cleanup getrennt'
    foreach ($testImage in @(@($imageName,$initialImageName,$allRuntimeImageName) | Sort-Object -Unique)) {
        & $Provider image rm --force $testImage 1>$null
        Assert-ExternalRuntimeAcceptance ($LASTEXITCODE -eq 0) "Test-eigenes Derived Image wurde explizit entfernt: $testImage"
    }
    if ($acceptanceNetworkName) {
        & $Provider network rm $acceptanceNetworkName 1>$null
        Assert-ExternalRuntimeAcceptance ($LASTEXITCODE -eq 0) 'Test-eigenes konfliktfreies Podman-Netz wurde explizit entfernt'
    }

    $evidence = [ordered]@{
        contract = [ordered]@{ name='SqlServerLab.ExternalRuntimeContainerAcceptance'; version='1.3' }
        status = 'PASS'
        provider = $Provider
        platform = 'linux'
        sqlVersion = $SqlVersion
        cgroupVersion = [string]$hostAndImage.Host.CgroupVersion
        rootless = [bool]$hostAndImage.Host.Rootless
        catalogState = @($catalogState)
        characterization = 'catalog-supported-native-acceptance'
        refresh = [ordered]@{
            status = [string]$refresh.ExecutionSummary.Status
            changeClass = [string]$refreshPlan.HighestChangeClass
            journalStatus = [string]$journal.status
            previousImageKey = $initialImageKey
            desiredImageKey = $allRuntimeImageKey
            previousImageRetainedAfterSwitch = $initialImageExistsAfterRunCleanup
        }
        removal = [ordered]@{
            status = [string]$removalRefresh.ExecutionSummary.Status
            softwareId = 'sql-java'
            journalStatus = [string]$removalJournal.status
            javaCleanupRecords = @($removalJournal.javaCleanup.records).Count
            intermediateImageKey = $allRuntimeImageKey
            desiredImageKey = [string]$instance.ExternalRuntime.ImageKey
            intermediateImageRetainedAfterSwitch = $allRuntimeImageExistsAfterRunCleanup
        }
        image = [ordered]@{
            imageKey = [string]$instance.ExternalRuntime.ImageKey
            baseImageDigest = [string]$hostAndImage.ImageReceipt.baseImageDigest
            variantIds = @($hostAndImage.ImageReceipt.variantIds)
            launchMode = [string]$hostAndImage.ImageReceipt.launchMode
            namespaceIsolation = [bool]$hostAndImage.ImageReceipt.namespaceIsolation
            outboundAccess = [bool]$hostAndImage.ImageReceipt.outboundAccess
            retainedAfterRunCleanup = $imageExistsAfterRunCleanup
            explicitlyRemoved = $true
        }
        languages = @($receipts | Sort-Object softwareId | ForEach-Object {
            $runtimeProbe = @($_.postconditions | Where-Object { [string]$_.Language -in @('Python','R','Java') -or [string]$_.Id -match '^(python|r|java)-' }) | Select-Object -Last 1
            [ordered]@{
                softwareId = [string]$_.softwareId
                variantId = [string]$_.variantId
                runtimeVersion = [string]$_.runtimeVersion
                workerIdentity = if ($runtimeProbe) { [string]$runtimeProbe.WorkerIdentity } else { $null }
                status = [string]$_.status
            }
        })
        restart = [ordered]@{
            status = [string]$restart.Status
            launchpad = [string]$postRestart.Launchpad.Status
            probes = @($postRestart.Probes | ForEach-Object {
                [ordered]@{ id=[string]$_.Id; language=[string]$_.Language; runtimeVersion=[string]$_.RuntimeVersion; workerIdentity=[string]$_.WorkerIdentity; status=[string]$_.Status }
            })
        }
        cleanup = [ordered]@{
            runStatus=[string]$cleanup.Status
            reusableImageExplicitlyRemoved=$true
            acceptanceNetworkExplicitlyRemoved=[bool]$acceptanceNetworkName
        }
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $evidenceDirectory = Split-Path -Parent $EvidencePath
    if ($evidenceDirectory) { New-Item -Path $evidenceDirectory -ItemType Directory -Force | Out-Null }
    $evidence | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
    $completed = $true
    Write-Host "External-Runtime-Akzeptanz erfolgreich: $Provider" -ForegroundColor Green
    Write-Host "Evidence: $EvidencePath" -ForegroundColor Cyan
}
finally {
    if ($lab -and -not $KeepOnFailure) {
        try { Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false | Out-Null }
        catch { Write-Warning "Fehler-Cleanup des Runs schlug fehl: $($_.Exception.Message)" }
    }
    if ($imageName -and -not $completed -and -not $KeepOnFailure) {
        try { & $Provider image rm --force $imageName 1>$null 2>$null } catch { }
    }
    if ($initialImageName -and -not $completed -and -not $KeepOnFailure) {
        try { & $Provider image rm --force $initialImageName 1>$null 2>$null } catch { }
    }
    if ($allRuntimeImageName -and -not $completed -and -not $KeepOnFailure) {
        try { & $Provider image rm --force $allRuntimeImageName 1>$null 2>$null } catch { }
    }
    if ($acceptanceNetworkName -and -not $completed -and -not $KeepOnFailure) {
        try { & $Provider network rm $acceptanceNetworkName 1>$null 2>$null } catch { }
    }
    if (($completed -or -not $KeepOnFailure) -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $env:SQL_SERVER_LAB_STATE = $previousStateRoot
    $env:SQL_SERVER_LAB_PODMAN_NETWORK = $previousPodmanNetwork
    $env:SQL_SERVER_LAB_PODMAN_SUBNET = $previousPodmanSubnet
}
