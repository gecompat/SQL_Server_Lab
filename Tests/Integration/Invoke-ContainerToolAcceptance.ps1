#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft kataloggebundene SqlPackage-Operationen im nativen Container-Lab.
.DESCRIPTION
    Provisioniert einen isolierten SQL-2022-Manifest-Run mit SqlPackage,
    prueft Versionsprobe und Restart, synthetisches BACPAC-Extract/Import,
    DACPAC-Extract/Publish, No-op- und kontrollierte Drift-DeployReports,
    wiederholtes Publish mit Driftkorrektur sowie Container-Attach.
    Run, temporäre Pakete und ein test-eigenes Derived Image werden entfernt.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText','',Justification='Nur zufaellig erzeugte synthetische Credentials fuer den eigenen isolierten Test-Run.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
    [string]$EvidencePath,
    [switch]$RuntimeMutexAlreadyHeld,
    [switch]$KeepOnFailure,
    [string]$StateRoot
)
$requestedStateRoot=$StateRoot
. (Join-Path $PSScriptRoot '../Common/OwnedHostTestScope.ps1')
if ($requestedStateRoot) { Assert-OwnedHostTestRoot -StateRoot $requestedStateRoot }


$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot=if ($requestedStateRoot) { Get-OwnedHostTestArtifactRoot -StateRoot $requestedStateRoot -Name 'sql-server-lab-container-tool' } else { Join-Path ([IO.Path]::GetTempPath()) "sql-server-lab-container-tool-$Provider-$([guid]::NewGuid().ToString('N'))" }
$stateRoot=if ($requestedStateRoot) { $requestedStateRoot } else { Join-Path $testRoot 'state' }
$manifestPath = Join-Path $testRoot 'manifest.json'
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$lab = $null
$runtimeInvocation = $null
$imageName = $null
$removeImageAfterTest = $false
$bacpacSourcePath = $null
$bacpacContainerPath = $null
$dacpacContainerPath = $null
$dacpacDeployReportContainerPath = $null
$dacpacDeployReportHostPath = $null
$attachPayloadRoot = $null
$completed = $false
$cleanupFailed = $false
$mutex = [Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}))
$mutexAcquired = $false

function Assert-ContainerToolAcceptance {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Description,
        [string]$Evidence
    )
    if (-not $Condition) {
        throw "CONTAINER_TOOL_ACCEPTANCE_FAILED: $Description$(if ($Evidence) { ": $Evidence" })"
    }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

function Get-ContainerToolDacpacDeployReport {
    param(
        [Parameter(Mandatory)][string]$SourceDacpacPath,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$ContainerReportPath,
        [Parameter(Mandatory)][string]$HostReportPath
    )

    $script:dacpacDeployReportContainerPath = $ContainerReportPath
    $script:dacpacDeployReportHostPath = $HostReportPath
    $command = 'exec /opt/sql-server-lab/tools/sqlpackage/sqlpackage /Action:DeployReport "/SourceFile:$1" "/TargetServerName:localhost" "/TargetDatabaseName:$2" /TargetUser:sa /TargetTrustServerCertificate:True "/TargetPassword:$SQLSERVERLAB_SA_PASSWORD" "/OutputPath:$3" /p:BlockOnPossibleDataLoss=True /p:DropObjectsNotInSource=False'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($saPassword)
    try {
        $saPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $output = @($(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('exec','--env',"SQLSERVERLAB_SA_PASSWORD=$saPlain",'--user','mssql',$instance.ContainerName,'sh','-ceu',$command,'--',$SourceDacpacPath,$DatabaseName,$ContainerReportPath) } else { & $runtimeInvocation exec --env "SQLSERVERLAB_SA_PASSWORD=$saPlain" --user mssql $instance.ContainerName sh -ceu $command -- $SourceDacpacPath $DatabaseName $ContainerReportPath }) 2>&1)
        Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0) 'SqlPackage erzeugt den DACPAC-DeployReport'
    }
    finally {
        $saPlain = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    try {
        $(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('cp',"$($instance.ContainerName):$ContainerReportPath",$HostReportPath) } else { & $runtimeInvocation cp "$($instance.ContainerName):$ContainerReportPath" $HostReportPath }) 1>$null
        Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $HostReportPath -PathType Leaf)) 'DeployReport wird als eigenes temporäres Testartefakt gelesen'
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $settings.MaxCharactersInDocument = 1048576
        $reader = $null
        try {
            $reader = [Xml.XmlReader]::Create($HostReportPath,$settings)
            $report = [Xml.XmlDocument]::new()
            $report.XmlResolver = $null
            $report.Load($reader)
        }
        finally {
            if ($reader) { $reader.Dispose() }
        }
        $operationSections = @($report.SelectNodes("//*[local-name()='Operations']"))
        $operations = @($report.SelectNodes("//*[local-name()='Operation']"))
        Assert-ContainerToolAcceptance ($report.DocumentElement.LocalName -eq 'DeploymentReport' -and $operationSections.Count -le 1) 'DeployReport ist valides XML mit erwarteter Reportstruktur'
        [PSCustomObject]@{ OperationCount = $operations.Count }
    }
    finally {
        if (Test-Path -LiteralPath $HostReportPath) {
            Remove-Item -LiteralPath $HostReportPath -Force
        }
        Assert-ContainerToolAcceptance (-not (Test-Path -LiteralPath $HostReportPath)) 'Hostkopie des DeployReports wird entfernt'
        if ($runtimeInvocation -and $instance -and $ContainerReportPath) {
            $(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('exec','--user','mssql',$instance.ContainerName,'rm','-f','--',$ContainerReportPath) } else { & $runtimeInvocation exec --user mssql $instance.ContainerName rm -f -- $ContainerReportPath }) 1>$null
            Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0) 'Temporärer DeployReport wird aus dem eigenen Run entfernt'
        }
        $script:dacpacDeployReportContainerPath = $null
        $script:dacpacDeployReportHostPath = $null
    }
}

try {
    if(-not $RuntimeMutexAlreadyHeld){
        $mutexAcquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10))
        if(-not $mutexAcquired){throw 'CONTAINER_TOOL_ACCEPTANCE_LOCK_TIMEOUT'}
    }
    $runtimeResolution = @(& (Join-Path $repoRoot 'Tools\Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    Assert-ContainerToolAcceptance ([bool]$runtimeResolution.Available) "Runtime-CLI '$Provider' ist zentral aufloesbar"
    $runtimeInvocation = [string]$runtimeResolution.Invocation
    if ($Provider -eq 'podman') { $(if ($requestedStateRoot) { & (Join-Path $PSScriptRoot 'Initialize-PodmanRuntime.ps1') -StateRoot $requestedStateRoot -RequireReachable } else { & (Join-Path $PSScriptRoot 'Initialize-PodmanRuntime.ps1') })  | Out-Host }
    $(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('info') } else { & $runtimeInvocation info }) 1>$null 2>$null
    Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0) "Runtime '$Provider' ist erreichbar"


    New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
    $env:SQL_SERVER_LAB_STATE = $stateRoot
    $token = [guid]::NewGuid().ToString('N').Substring(0, 16)
    $saPassword = ConvertTo-SecureString "ContainerTool_${token}!Aa7" -AsPlainText -Force
    $manifest = [ordered]@{
        name = "container-tool-$Provider-native"
        automation = [ordered]@{ mode = 'unattended' }
        instances = @([ordered]@{
            id = 'container-tool'
            version = '2022'
            provider = $Provider
            profile = 'compact'
            software = @([ordered]@{ id = 'sqlpackage'; scope = 'instance' })
        })
    }
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8

    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module = Import-Module $modulePath -Force -PassThru
    $plannedToolImage=& $module {
        param($Instance)
        $plans=@(Resolve-LabSoftwarePlansForInstance -Instance $Instance)
        (New-LabContainerToolImagePlan -Provider ([string]$Instance.provider) -SqlVersion ([string]$Instance.version) -SoftwarePlans $plans).Image
    } ([pscustomobject]$manifest.instances[0])
    # Podman kann lokale Images als `localhost/<repository>:<tag>` ausgeben,
    # waehrend der portable Plan das kanonische Repository ohne Registry-Praefix
    # verwendet. Die Ownership-Entscheidung darf diesen Darstellungsunterschied
    # nicht als neues test-eigenes Image interpretieren.
    $plannedToolImageCanonical = ([string]$plannedToolImage -replace '^(?i)localhost/', '')
    $existingToolImages=@($(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('images','--no-trunc','--format','{{.Repository}}:{{.Tag}}={{.ID}}','--filter','reference=sql-server-lab/container-tool:*') } else { & $runtimeInvocation images --no-trunc --format '{{.Repository}}:{{.Tag}}={{.ID}}' --filter 'reference=sql-server-lab/container-tool:*' }) )
    $existingPlannedToolImage=@($existingToolImages | Where-Object {
        $candidate = (([string]$_ -split '=', 2)[0] -replace '^(?i)localhost/', '')
        $candidate -ieq $plannedToolImageCanonical
    })
    Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0 -and $existingPlannedToolImage.Count -le 1) 'Isolierter Image-Test erkennt hoechstens ein bestehendes Zielimage'
    $removeImageAfterTest = $existingPlannedToolImage.Count -eq 0
    $assessment=Test-SqlServerLabPrerequisite -Provider $Provider -StateRoot $stateRoot
    Assert-ContainerToolAcceptance ($assessment.Status -eq 'RESOURCE_OK') 'Ressourcenpruefung erlaubt den isolierten Test-Run'
    $lab = New-SqlServerLab -Manifest $manifestPath -SaPassword $saPassword -StateRoot $stateRoot -SkipAssessment -NonInteractive
    Assert-ContainerToolAcceptance ([string]$lab.State -eq 'Running') 'Lab wurde ueber den normalen Manifestpfad provisioniert'
    $instance = @($lab.Instances)[0]
    Assert-ContainerToolAcceptance (
        [string]$instance.ContainerTools.Status -eq 'IMAGE_READY' -and
        (@($instance.ContainerTools.ToolIds) -join ',') -eq 'sqlpackage' -and
        [string]$instance.ContainerTools.RuntimeVersion -match '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    ) 'Run-State bindet ausschliesslich die katalogisierte SqlPackage-Tool-Identitaet'

    $receiptPath = & $module {
        param($ImageKey, $ProviderName, $Root)
        Get-LabContainerToolImageReceiptPath -ImageKey $ImageKey -Provider $ProviderName -StateRoot $Root
    } ([string]$instance.ContainerTools.ImageKey) $Provider $stateRoot
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $imageName = [string]$receipt.image
    if ($requestedStateRoot) {
        $ownToolImage=& $module {
            param($Root,$Selected,$Key)
            Get-LabOwnedHostToolImageReceipt -StateRoot $Root -Provider $Selected -ImageKey $Key
        } $stateRoot $Provider ([string]$receipt.imageKey)
        $removeImageAfterTest=[bool]$ownToolImage.OwnsTag
        Assert-ContainerToolAcceptance ($imageName -ceq $ownToolImage.Image -and $receipt.localImageId -ceq $ownToolImage.ImageId) 'OwnRoot-Receipt bindet exakt eigene Tag-Custody oder unveraenderliche vorhandene Image-ID'
    }
    $currentToolImages=@($(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('images','--no-trunc','--format','{{.Repository}}:{{.Tag}}={{.ID}}','--filter','reference=sql-server-lab/container-tool:*') } else { & $runtimeInvocation images --no-trunc --format '{{.Repository}}:{{.Tag}}={{.ID}}' --filter 'reference=sql-server-lab/container-tool:*' }) )
    $currentPlannedToolImage=@($currentToolImages | Where-Object {
        $candidate = (([string]$_ -split '=', 2)[0] -replace '^(?i)localhost/', '')
        $candidate -ieq $plannedToolImageCanonical
    })
    Assert-ContainerToolAcceptance (
        [string]$receipt.status -eq 'IMAGE_READY' -and
        [string]$receipt.retention -eq $(if ($requestedStateRoot) { 'owned-root-explicit-terminal-removal' } else { 'reusable-explicit-removal' }) -and
        [string]$receipt.runtimeVersion -eq [string]$instance.ContainerTools.RuntimeVersion -and
        (@($receipt.toolIds) -join ',') -eq 'sqlpackage' -and
        ($existingPlannedToolImage.Count -eq 0 -or ($currentPlannedToolImage -join ',') -eq ($existingPlannedToolImage -join ','))
    ) 'Derived Image besitzt einen scope-lokalen, kataloggebundenen Receipt'

    $probe = Test-SqlServerLabContainerTool -RunId $lab.RunId -InstanceId 'container-tool' -StateRoot $stateRoot
    Assert-ContainerToolAcceptance (
        [string]$probe.Status -eq 'PASS' -and [string]$probe.ToolId -eq 'sqlpackage' -and
        [string]$probe.Provider -eq $Provider -and [string]$probe.RuntimeVersion -eq [string]$instance.ContainerTools.RuntimeVersion
    ) 'Oeffentliche Run-/Scope-gebundene SqlPackage-Versionsprobe besteht'

    $status = Get-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot
    $statusJson = $status | ConvertTo-Json -Depth 30
    Assert-ContainerToolAcceptance (
        [string]$status.Instances[0].ContainerTools.RuntimeVersion -eq [string]$probe.RuntimeVersion -and
        $statusJson -notmatch '(?i)(localImageId|containerTools\.receipt|containerTools\.source)'
    ) 'Oeffentliche Statussicht bleibt auf sanitisierte Tool-Metadaten begrenzt'

    $restart = Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 300 -Force -StateRoot $stateRoot
    Assert-ContainerToolAcceptance ([string]$restart.Status -eq 'RUNNING' -and [int]$restart.Errors -eq 0) 'Run-Restart erreicht erneut SQL-Readiness'
    $postRestartProbe = Test-SqlServerLabContainerTool -RunId $lab.RunId -InstanceId 'container-tool' -StateRoot $stateRoot
    Assert-ContainerToolAcceptance (
        [string]$postRestartProbe.Status -eq 'PASS' -and [string]$postRestartProbe.RuntimeVersion -eq [string]$probe.RuntimeVersion
    ) 'Oeffentliche Versionsprobe bleibt nach Restart read-only erfolgreich'

    $sourceDatabase = 'BacpacSource'
    $targetDatabase = 'BacpacImported'
    $sourceCreation = & $module {
        param($HostName, $PortNumber, $Password, $SourceDatabase)
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            Invoke-SqlQuery -HostName $HostName -Port $PortNumber -SaPlain $plain -Query "CREATE DATABASE [$SourceDatabase];" -TimeoutSeconds 90 | Out-Null
            Invoke-SqlQuery -HostName $HostName -Port $PortNumber -SaPlain $plain -Database $SourceDatabase -Query "CREATE TABLE dbo.BacpacProbe (Id int NOT NULL PRIMARY KEY, Marker nvarchar(40) NOT NULL); INSERT INTO dbo.BacpacProbe (Id, Marker) VALUES (1, N'container-tool-bacpac');" -TimeoutSeconds 90 | Out-Null
        }
        finally {
            $plain = $null
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } $instance.Host ([int]$instance.Port) $saPassword $sourceDatabase
    Assert-ContainerToolAcceptance ($null -eq $sourceCreation) 'Synthetische BACPAC-Quelldatenbank wurde nur im Test-Run angelegt'

    $bacpacContainerPath = "/tmp/sql-server-lab-bacpac-export-$([guid]::NewGuid().ToString('N')).bacpac"
    $exportCommand = 'exec /opt/sql-server-lab/tools/sqlpackage/sqlpackage /Action:Export /SourceServerName:localhost "/SourceDatabaseName:$1" /SourceUser:sa /SourceTrustServerCertificate:True "/SourcePassword:$SQLSERVERLAB_SA_PASSWORD" "/TargetFile:$2"'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($saPassword)
    try {
        $saPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $exportOutput = @($(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('exec','--env',"SQLSERVERLAB_SA_PASSWORD=$saPlain",'--user','mssql',$instance.ContainerName,'sh','-ceu',$exportCommand,'--',$sourceDatabase,$bacpacContainerPath) } else { & $runtimeInvocation exec --env "SQLSERVERLAB_SA_PASSWORD=$saPlain" --user mssql $instance.ContainerName sh -ceu $exportCommand -- $sourceDatabase $bacpacContainerPath }) 2>&1)
        Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0) 'Kataloggebundenes SqlPackage exportiert ein synthetisches BACPAC ohne Host-Tool'
    }
    finally {
        $saPlain = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $bacpacSourcePath = Join-Path $testRoot 'synthetic-source.bacpac'
    $(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('cp',"$($instance.ContainerName):$bacpacContainerPath",$bacpacSourcePath) } else { & $runtimeInvocation cp "$($instance.ContainerName):$bacpacContainerPath" $bacpacSourcePath }) 1>$null
    Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $bacpacSourcePath -PathType Leaf)) 'Exportiertes BACPAC wird als kontrolliertes Testartefakt aus dem Run gelesen'
    $(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('exec','--user','root',$instance.ContainerName,'rm','-f','--',$bacpacContainerPath) } else { & $runtimeInvocation exec --user root $instance.ContainerName rm -f -- $bacpacContainerPath }) 1>$null
    Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0) 'Temporäres Export-BACPAC wird vor dem Import aus dem Container entfernt'
    $bacpacContainerPath = $null

    $bacpacImport = & $module {
        param($ArtifactPath, $LabInstance, $Password, $ProviderName, $RunIdentifier, $Root, $TargetDatabase)
        Invoke-LabContainerBacpacImport -Provider $ProviderName -ContainerName $LabInstance.ContainerName `
            -RunId $RunIdentifier -InstanceId $LabInstance.Id -ArtifactPath $ArtifactPath -DatabaseName $TargetDatabase `
            -SaPassword $Password -ExpectedRuntimeVersion ([string]$LabInstance.ContainerTools.RuntimeVersion) -StateRoot $Root
    } $bacpacSourcePath $instance $saPassword $Provider $lab.RunId $stateRoot $targetDatabase
    Assert-ContainerToolAcceptance ([string]$bacpacImport.Status -eq 'BACPAC_IMPORTED') 'BACPAC-Handler importiert in die scopegebundene Zieldatenbank'
    $bacpacMarker = & $module {
        param($HostName, $PortNumber, $Password, $DatabaseName)
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            @(Invoke-SqlQuery -HostName $HostName -Port $PortNumber -SaPlain $plain -Database $DatabaseName -Query 'SET NOCOUNT ON; SELECT Marker FROM dbo.BacpacProbe WHERE Id = 1;')
        }
        finally {
            $plain = $null
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } $instance.Host ([int]$instance.Port) $saPassword $targetDatabase
    Assert-ContainerToolAcceptance ((@($bacpacMarker | ForEach-Object { ([string]$_).Trim() }) -contains 'container-tool-bacpac')) 'Importierte BACPAC-Daten bestehen den SQL-Roundtrip'
    $residualBacpac = @($(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('exec','--user','root',$instance.ContainerName,'sh','-ceu','test -z "$(find /tmp -maxdepth 1 -name ''sql-server-lab-bacpac-*.bacpac'' -print -quit)"') } else { & $runtimeInvocation exec --user root $instance.ContainerName sh -ceu 'test -z "$(find /tmp -maxdepth 1 -name ''sql-server-lab-bacpac-*.bacpac'' -print -quit)"' }) 2>&1)
    Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0) 'BACPAC-Import hinterlässt kein temporäres Containerartefakt'

    # Erstes Schema-Deployment-Slice: Das gebundene SqlPackage extrahiert ein
    # synthetisches Modell aus dem eigenen Run und publiziert es ausschließlich
    # in eine explizit zuvor angelegte zweite Testdatenbank. Die Wiederholung
    # darf bestehende Zieldaten nicht löschen.
    $dacpacTargetDatabase = 'DacpacPublished'
    & $module {
        param($HostName, $PortNumber, $Password, $DatabaseName)
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            Invoke-SqlQuery -HostName $HostName -Port $PortNumber -SaPlain $plain -Query "CREATE DATABASE [$DatabaseName];" -TimeoutSeconds 90 | Out-Null
        }
        finally {
            $plain = $null
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } $instance.Host ([int]$instance.Port) $saPassword $dacpacTargetDatabase
    Assert-ContainerToolAcceptance $true 'DACPAC-Zieldatenbank wurde ausschließlich im eigenen Test-Run angelegt'

    $dacpacContainerPath = "/tmp/sql-server-lab-dacpac-$([guid]::NewGuid().ToString('N')).dacpac"
    $extractCommand = 'exec /opt/sql-server-lab/tools/sqlpackage/sqlpackage /Action:Extract "/SourceServerName:localhost" "/SourceDatabaseName:$1" /SourceUser:sa /SourceTrustServerCertificate:True "/SourcePassword:$SQLSERVERLAB_SA_PASSWORD" "/TargetFile:$2"'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($saPassword)
    try {
        $saPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $extractOutput = @($(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('exec','--env',"SQLSERVERLAB_SA_PASSWORD=$saPlain",'--user','mssql',$instance.ContainerName,'sh','-ceu',$extractCommand,'--',$sourceDatabase,$dacpacContainerPath) } else { & $runtimeInvocation exec --env "SQLSERVERLAB_SA_PASSWORD=$saPlain" --user mssql $instance.ContainerName sh -ceu $extractCommand -- $sourceDatabase $dacpacContainerPath }) 2>&1)
        Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0) 'Kataloggebundenes SqlPackage extrahiert das synthetische Schema als DACPAC'
    }
    finally {
        $saPlain = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    $publishCommand = 'exec /opt/sql-server-lab/tools/sqlpackage/sqlpackage /Action:Publish "/SourceFile:$1" "/TargetServerName:localhost" "/TargetDatabaseName:$2" /TargetUser:sa /TargetTrustServerCertificate:True "/TargetPassword:$SQLSERVERLAB_SA_PASSWORD" /p:BlockOnPossibleDataLoss=True /p:DropObjectsNotInSource=False'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($saPassword)
    try {
        $saPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $publishOutput = @($(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('exec','--env',"SQLSERVERLAB_SA_PASSWORD=$saPlain",'--user','mssql',$instance.ContainerName,'sh','-ceu',$publishCommand,'--',$dacpacContainerPath,$dacpacTargetDatabase) } else { & $runtimeInvocation exec --env "SQLSERVERLAB_SA_PASSWORD=$saPlain" --user mssql $instance.ContainerName sh -ceu $publishCommand -- $dacpacContainerPath $dacpacTargetDatabase }) 2>&1)
        Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0) 'SqlPackage publiziert das synthetische DACPAC in die gebundene Testdatenbank'
    }
    finally {
        $saPlain = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $dacpacSchema = & $module {
        param($HostName, $PortNumber, $Password, $DatabaseName)
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            @(Invoke-SqlQuery -HostName $HostName -Port $PortNumber -SaPlain $plain -Database $DatabaseName -Query "SET NOCOUNT ON; SELECT CASE WHEN OBJECT_ID(N'dbo.BacpacProbe', N'U') IS NOT NULL THEN 'DACPAC_SCHEMA_PRESENT' ELSE 'DACPAC_SCHEMA_MISSING' END;")
        }
        finally {
            $plain = $null
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } $instance.Host ([int]$instance.Port) $saPassword $dacpacTargetDatabase
    Assert-ContainerToolAcceptance (@($dacpacSchema | ForEach-Object { ([string]$_).Trim() }) -contains 'DACPAC_SCHEMA_PRESENT') 'DACPAC-Publish erzeugt das erwartete synthetische Tabellenschema'

    & $module {
        param($HostName, $PortNumber, $Password, $DatabaseName)
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            Invoke-SqlQuery -HostName $HostName -Port $PortNumber -SaPlain $plain -Database $DatabaseName -Query "INSERT INTO dbo.BacpacProbe (Id, Marker) VALUES (99, N'dacpac-preserved');" -TimeoutSeconds 90 | Out-Null
        }
        finally {
            $plain = $null
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } $instance.Host ([int]$instance.Port) $saPassword $dacpacTargetDatabase
    $noOpReport = Get-ContainerToolDacpacDeployReport -SourceDacpacPath $dacpacContainerPath -DatabaseName $dacpacTargetDatabase -ContainerReportPath "/tmp/sql-server-lab-dacpac-$([guid]::NewGuid().ToString('N')).noop.xml" -HostReportPath (Join-Path $testRoot 'dacpac-deploy-report-noop.xml')
    Assert-ContainerToolAcceptance ($noOpReport.OperationCount -eq 0) 'DeployReport meldet nach Publish und Datenänderung keine Schemaoperationen'
    $markerValuesFit = & $module {
        param($HostName, $PortNumber, $Password, $DatabaseName)
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            @(Invoke-SqlQuery -HostName $HostName -Port $PortNumber -SaPlain $plain -Database $DatabaseName -Query "SET NOCOUNT ON; SELECT CASE WHEN (SELECT MAX(LEN(Marker)) FROM dbo.BacpacProbe) <= 24 THEN 'DACPAC_MARKERS_FIT_NARROW_COLUMN' ELSE 'DACPAC_MARKERS_EXCEED_NARROW_COLUMN' END;")
        }
        finally {
            $plain = $null
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } $instance.Host ([int]$instance.Port) $saPassword $dacpacTargetDatabase
    Assert-ContainerToolAcceptance (@($markerValuesFit | ForEach-Object { ([string]$_).Trim() }) -contains 'DACPAC_MARKERS_FIT_NARROW_COLUMN') 'Synthetische Zielwerte passen vor der Driftmutation in nvarchar(24)'
    $schemaDrifted = & $module {
        param($HostName, $PortNumber, $Password, $DatabaseName)
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            Invoke-SqlQuery -HostName $HostName -Port $PortNumber -SaPlain $plain -Database $DatabaseName -Query 'ALTER TABLE dbo.BacpacProbe ALTER COLUMN Marker nvarchar(24) NOT NULL;' -TimeoutSeconds 90 | Out-Null
            @(Invoke-SqlQuery -HostName $HostName -Port $PortNumber -SaPlain $plain -Database $DatabaseName -Query "SET NOCOUNT ON; SELECT CASE WHEN COL_LENGTH(N'dbo.BacpacProbe', N'Marker') = 48 AND (SELECT MAX(LEN(Marker)) FROM dbo.BacpacProbe) <= 24 THEN 'DACPAC_SCHEMA_DRIFTED' ELSE 'DACPAC_SCHEMA_NOT_DRIFTED' END;")
        }
        finally {
            $plain = $null
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } $instance.Host ([int]$instance.Port) $saPassword $dacpacTargetDatabase
    Assert-ContainerToolAcceptance (@($schemaDrifted | ForEach-Object { ([string]$_).Trim() }) -contains 'DACPAC_SCHEMA_DRIFTED') 'Kontrollierte Spaltenbreiten-Drift wird nur in der eigenen Zieldatenbank erzeugt'
    $driftReport = Get-ContainerToolDacpacDeployReport -SourceDacpacPath $dacpacContainerPath -DatabaseName $dacpacTargetDatabase -ContainerReportPath "/tmp/sql-server-lab-dacpac-$([guid]::NewGuid().ToString('N')).drift.xml" -HostReportPath (Join-Path $testRoot 'dacpac-deploy-report-drift.xml')
    Assert-ContainerToolAcceptance ($driftReport.OperationCount -gt 0) 'DeployReport erkennt die kontrollierte Spaltenbreiten-Drift'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($saPassword)
    try {
        $saPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $republishOutput = @($(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('exec','--env',"SQLSERVERLAB_SA_PASSWORD=$saPlain",'--user','mssql',$instance.ContainerName,'sh','-ceu',$publishCommand,'--',$dacpacContainerPath,$dacpacTargetDatabase) } else { & $runtimeInvocation exec --env "SQLSERVERLAB_SA_PASSWORD=$saPlain" --user mssql $instance.ContainerName sh -ceu $publishCommand -- $dacpacContainerPath $dacpacTargetDatabase }) 2>&1)
        Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0) 'Erneute DACPAC-Publikation bleibt erfolgreich'
    }
    finally {
        $saPlain = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $dacpacSchemaRestored = & $module {
        param($HostName, $PortNumber, $Password, $DatabaseName)
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            @(Invoke-SqlQuery -HostName $HostName -Port $PortNumber -SaPlain $plain -Database $DatabaseName -Query "SET NOCOUNT ON; SELECT CASE WHEN COL_LENGTH(N'dbo.BacpacProbe', N'Marker') = 80 THEN 'DACPAC_SCHEMA_RESTORED' ELSE 'DACPAC_SCHEMA_NOT_RESTORED' END;")
        }
        finally {
            $plain = $null
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } $instance.Host ([int]$instance.Port) $saPassword $dacpacTargetDatabase
    Assert-ContainerToolAcceptance (@($dacpacSchemaRestored | ForEach-Object { ([string]$_).Trim() }) -contains 'DACPAC_SCHEMA_RESTORED') 'Publish stellt nach erkannter Drift die DACPAC-Spaltenbreite wieder her'
    $dacpacPreserved = & $module {
        param($HostName, $PortNumber, $Password, $DatabaseName)
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            @(Invoke-SqlQuery -HostName $HostName -Port $PortNumber -SaPlain $plain -Database $DatabaseName -Query "SET NOCOUNT ON; SELECT Marker FROM dbo.BacpacProbe WHERE Id = 99;")
        }
        finally {
            $plain = $null
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } $instance.Host ([int]$instance.Port) $saPassword $dacpacTargetDatabase
    Assert-ContainerToolAcceptance (@($dacpacPreserved | ForEach-Object { ([string]$_).Trim() }) -contains 'dacpac-preserved') 'Erneute DACPAC-Publikation erhält vorhandene Zieldaten'
    $(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('exec','--user','mssql',$instance.ContainerName,'rm','-f','--',$dacpacContainerPath) } else { & $runtimeInvocation exec --user mssql $instance.ContainerName rm -f -- $dacpacContainerPath }) 1>$null
    Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0) 'Temporäres DACPAC wird nach der Publish-Prüfung entfernt'
    $dacpacContainerPath = $null

    $attachSourceDatabase = 'AttachNativeSource'
    $attachTargetDatabase = 'AttachNativeTarget'
    & $module {
        param($HostName, $PortNumber, $Password, $SourceDatabase)
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            Invoke-SqlQuery -HostName $HostName -Port $PortNumber -SaPlain $plain -Query "CREATE DATABASE [$SourceDatabase];" -TimeoutSeconds 90 | Out-Null
            Invoke-SqlQuery -HostName $HostName -Port $PortNumber -SaPlain $plain -Database $SourceDatabase -Query "CREATE TABLE dbo.AttachProbe (Id int NOT NULL PRIMARY KEY, Marker nvarchar(40) NOT NULL); INSERT INTO dbo.AttachProbe (Id, Marker) VALUES (1, N'container-native-attach');" -TimeoutSeconds 90 | Out-Null
            Invoke-SqlQuery -HostName $HostName -Port $PortNumber -SaPlain $plain -Query "ALTER DATABASE [$SourceDatabase] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; EXEC sp_detach_db N'$SourceDatabase';" -TimeoutSeconds 90 | Out-Null
        }
        finally {
            $plain = $null
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } $instance.Host ([int]$instance.Port) $saPassword $attachSourceDatabase
    Assert-ContainerToolAcceptance $true 'Synthetische Attach-Quelldatenbank wurde im isolierten Test-Run detachiert'

    $attachPayloadRoot = Join-Path $testRoot 'attach-payload'
    New-Item -Path $attachPayloadRoot -ItemType Directory -Force | Out-Null
    $attachPrimaryPath = Join-Path $attachPayloadRoot "$attachSourceDatabase.mdf"
    $attachLogPath = Join-Path $attachPayloadRoot "${attachSourceDatabase}_log.ldf"
    $(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('cp',"$($instance.ContainerName):/var/opt/mssql/data/$attachSourceDatabase.mdf",$attachPrimaryPath) } else { & $runtimeInvocation cp "$($instance.ContainerName):/var/opt/mssql/data/$attachSourceDatabase.mdf" $attachPrimaryPath }) 1>$null
    Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $attachPrimaryPath -PathType Leaf)) 'Detach-MDF wird als kontrollierte Testpayload aus dem Container gelesen'
    $(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('cp',"$($instance.ContainerName):/var/opt/mssql/data/${attachSourceDatabase}_log.ldf",$attachLogPath) } else { & $runtimeInvocation cp "$($instance.ContainerName):/var/opt/mssql/data/${attachSourceDatabase}_log.ldf" $attachLogPath }) 1>$null
    Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $attachLogPath -PathType Leaf)) 'Detach-LDF wird als kontrollierte Testpayload aus dem Container gelesen'

    $attachResult = & $module {
        param($ProviderName, $LabInstance, $RunIdentifier, $PayloadRoot, $Password, $Root, $TargetDatabase)
        Invoke-LabContainerAttach -Provider $ProviderName -ContainerName $LabInstance.ContainerName `
            -RunId $RunIdentifier -InstanceId $LabInstance.Id -Payloads @(
                [PSCustomObject]@{ Path = (Join-Path $PayloadRoot 'AttachNativeSource.mdf'); Role = 'primary' },
                [PSCustomObject]@{ Path = (Join-Path $PayloadRoot 'AttachNativeSource_log.ldf'); Role = 'log' }
            ) -DatabaseName $TargetDatabase -HostName $LabInstance.Host -Port ([int]$LabInstance.Port) -SaPassword $Password -StateRoot $Root
    } $Provider $instance $lab.RunId $attachPayloadRoot $saPassword $stateRoot $attachTargetDatabase
    Assert-ContainerToolAcceptance ([string]$attachResult.Status -eq 'ATTACHED') 'Container-Attach kopiert die kontrollierte Payload und erreicht ONLINE'
    $attachJournalPath = Get-ChildItem -LiteralPath (Join-Path $stateRoot "operations/attach/$($lab.RunId)") -Filter '*.json' | Select-Object -First 1 -ExpandProperty FullName
    $attachJournal = Get-Content -LiteralPath $attachJournalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    Assert-ContainerToolAcceptance (
        [string]$attachJournal.Status -eq 'COMPLETED' -and $attachJournal.CopyVerified -and
        $attachJournal.AttachInvoked -and $attachJournal.PostconditionVerified -and
        [string]$attachJournal.Recovery -eq 'NOT_REQUIRED'
    ) 'Container-Attach-Journal belegt Kopie, SQL-Mutation und ONLINE-Postcondition'
    $attachMarker = & $module {
        param($HostName, $PortNumber, $Password, $DatabaseName)
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            @(Invoke-SqlQuery -HostName $HostName -Port $PortNumber -SaPlain $plain -Database $DatabaseName -Query 'SET NOCOUNT ON; SELECT Marker FROM dbo.AttachProbe WHERE Id = 1;')
        }
        finally {
            $plain = $null
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } $instance.Host ([int]$instance.Port) $saPassword $attachTargetDatabase
    Assert-ContainerToolAcceptance ((@($attachMarker | ForEach-Object { ([string]$_).Trim() }) -contains 'container-native-attach')) 'Attached Datenbank besteht den SQL-Inhaltsroundtrip'
    $attachFailureRejected = $false
    try {
        $null = & $module {
            param($ProviderName, $LabInstance, $RunIdentifier, $PayloadRoot, $Password, $Root, $TargetDatabase)
            Invoke-LabContainerAttach -Provider $ProviderName -ContainerName $LabInstance.ContainerName `
                -RunId $RunIdentifier -InstanceId $LabInstance.Id -Payloads @(
                    [PSCustomObject]@{ Path = (Join-Path $PayloadRoot 'AttachNativeSource.mdf'); Role = 'primary' },
                    [PSCustomObject]@{ Path = (Join-Path $PayloadRoot 'AttachNativeSource_log.ldf'); Role = 'log' }
                ) -DatabaseName $TargetDatabase -HostName $LabInstance.Host -Port ([int]$LabInstance.Port) -SaPassword $Password -StateRoot $Root
        } $Provider $instance $lab.RunId $attachPayloadRoot $saPassword $stateRoot $attachTargetDatabase
    }
    catch { $attachFailureRejected = $_.Exception.Message -match 'ATTACH_RECOVERY_REQUIRED' }
    $attachFailureJournalPath = Get-ChildItem -LiteralPath (Join-Path $stateRoot "operations/attach/$($lab.RunId)") -Filter '*.json' |
        Where-Object { $_.FullName -ne $attachJournalPath } | Select-Object -First 1 -ExpandProperty FullName
    $attachFailureJournal = Get-Content -LiteralPath $attachFailureJournalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    Assert-ContainerToolAcceptance (
        $attachFailureRejected -and [string]$attachFailureJournal.Status -eq 'RECOVERY_REQUIRED' -and
        $attachFailureJournal.CopyVerified -and $attachFailureJournal.AttachInvoked -and -not $attachFailureJournal.PostconditionVerified -and
        [string]$attachFailureJournal.Recovery -eq 'DETACH_TARGET_COPY_AND_PRESERVE_TARGET'
    ) 'Container-Attach persistiert nach realem SQL-Fehler die passende Recovery-Aktion'

    $cleanup = Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false
    Assert-ContainerToolAcceptance ([string]$cleanup.Status -eq 'REMOVED') 'Registrierter Run-Cleanup entfernt ausschliesslich Run-Ressourcen'
    $lab = $null
    $(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('image','inspect',$imageName) } else { & $runtimeInvocation image inspect $imageName }) 1>$null 2>$null
    Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0) 'Wiederverwendbares Derived Image bleibt vom Run-Cleanup getrennt'
    if ($removeImageAfterTest) {
        if ($requestedStateRoot) {
            $ownRemoval=& $module {param($Root,$Selected,$Key) Remove-LabOwnedHostToolImage -StateRoot $Root -Provider $Selected -ImageKey $Key} $stateRoot $Provider ([string]$receipt.imageKey)
            Assert-ContainerToolAcceptance ($ownRemoval.Status -ceq 'REMOVED_OWN_TAG' -and $ownRemoval.Removed) 'Eigener Derived-Image-Tag wurde nach terminalem Run exakt entfernt'
        } else {
            & $runtimeInvocation image rm $imageName 1>$null
            Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0) 'Test-eigenes Derived Image wurde explizit entfernt'
        }
    }
    else {
        Assert-ContainerToolAcceptance (($currentPlannedToolImage -join ',') -eq ($existingPlannedToolImage -join ',')) 'Bereits vorhandenes Derived Image blieb unveraendert'
    }
    $imageName = $null
    $preservedToolImages=@($(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('images','--no-trunc','--format','{{.Repository}}:{{.Tag}}={{.ID}}','--filter','reference=sql-server-lab/container-tool:*') } else { & $runtimeInvocation images --no-trunc --format '{{.Repository}}:{{.Tag}}={{.ID}}' --filter 'reference=sql-server-lab/container-tool:*' }) )
    Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0 -and @($existingToolImages | Where-Object {$_ -notin $preservedToolImages}).Count -eq 0) 'Vorhandene Tool-Images bleiben mit derselben Tag- und Image-ID-Bindung erhalten'

    if ($EvidencePath) {
        $evidenceDirectory = Split-Path -Parent $EvidencePath
        if ($evidenceDirectory) { New-Item -Path $evidenceDirectory -ItemType Directory -Force | Out-Null }
        [ordered]@{
            contract = [ordered]@{ name = 'SqlServerLab.ContainerToolAcceptance'; version = '1.0' }
            status = 'PASS'; provider = $Provider; sqlVersion = '2022'
            tool = [ordered]@{ id = [string]$probe.ToolId; runtimeVersion = [string]$probe.RuntimeVersion; imageKey = [string]$instance.ContainerTools.ImageKey }
            bacpac = [ordered]@{ status = [string]$bacpacImport.Status; source = 'synthetic'; targetDatabase = $targetDatabase; dataRoundtrip = $true }
            dacpac = [ordered]@{
                status = 'PUBLISHED'; source = 'synthetic-schema-extract'; targetDatabase = $dacpacTargetDatabase
                deployReport = 'NO_SCHEMA_OPERATIONS'
                driftReport = 'OPERATIONS_PLANNED'; driftRecoveryPublish = 'PASS'
                repeatPublish = 'PASS'; targetDataPreserved = $true
                blockOnPossibleDataLoss = $true; dropObjectsNotInSource = $false
            }
            attach = [ordered]@{ status = [string]$attachResult.Status; source = 'synthetic-detached-mdf-ldf'; targetDatabase = $attachTargetDatabase; dataRoundtrip = $true; journalStatus = [string]$attachJournal.Status }
            attachRecovery = [ordered]@{ status = [string]$attachFailureJournal.Status; controlledSqlFailure = $attachFailureRejected; recovery = [string]$attachFailureJournal.Recovery }
            restart = [ordered]@{ status = [string]$restart.Status; probeStatus = [string]$postRestartProbe.Status }
            cleanup = [ordered]@{ runStatus = [string]$cleanup.Status; reusableImageExplicitlyRemoved = $true }
            completedAt = [DateTimeOffset]::UtcNow.ToString('o')
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
    }
    $completed = $true
    Write-Host "Container-Tool-Akzeptanz erfolgreich: $Provider" -ForegroundColor Green
}
finally {
    if ($lab -and -not $KeepOnFailure) {
        try {$cleanup=Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false;if($cleanup.Status -ne 'REMOVED'){throw 'CONTAINER_TOOL_TEST_CLEANUP_FAILED'}}
        catch {$cleanupFailed=$true;Write-Warning 'Run-Cleanup fehlgeschlagen; Test-State bleibt fuer Recovery erhalten.'}
    }
    if ($imageName -and -not $KeepOnFailure -and $runtimeInvocation) {
        try {
            if ($requestedStateRoot) {
                $null=& $module {param($Root,$Selected,$Key) Remove-LabOwnedHostToolImage -StateRoot $Root -Provider $Selected -ImageKey $Key} $stateRoot $Provider ([string]$receipt.imageKey)
            } else {
                & $runtimeInvocation image rm $imageName 1>$null 2>$null
                if($LASTEXITCODE -ne 0){throw 'CONTAINER_TOOL_TEST_IMAGE_CLEANUP_FAILED'}
            }
        } catch {$cleanupFailed=$true}
    }
    if ($bacpacContainerPath -and -not $KeepOnFailure -and $runtimeInvocation -and $lab) {
        try { $(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('exec','--user','root',$lab.Instances[0].ContainerName,'rm','-f','--',$bacpacContainerPath) } else { & $runtimeInvocation exec --user root $lab.Instances[0].ContainerName rm -f -- $bacpacContainerPath }) 1>$null 2>$null } catch { }
    }
    if ($dacpacContainerPath -and -not $KeepOnFailure -and $runtimeInvocation -and $lab) {
        try { $(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('exec','--user','root',$lab.Instances[0].ContainerName,'rm','-f','--',$dacpacContainerPath) } else { & $runtimeInvocation exec --user root $lab.Instances[0].ContainerName rm -f -- $dacpacContainerPath }) 1>$null 2>$null } catch { }
    }
    if ($dacpacDeployReportContainerPath -and -not $KeepOnFailure -and $runtimeInvocation -and $lab) {
        try { $(if ($requestedStateRoot) { Invoke-OwnedHostTestCommand -StateRoot $requestedStateRoot -Provider $Provider -Invocation $runtimeInvocation -Arguments @('exec','--user','root',$lab.Instances[0].ContainerName,'rm','-f','--',$dacpacDeployReportContainerPath) } else { & $runtimeInvocation exec --user root $lab.Instances[0].ContainerName rm -f -- $dacpacDeployReportContainerPath }) 1>$null 2>$null } catch { }
    }
    if (-not $cleanupFailed -and ($completed -or -not $KeepOnFailure) -and (Test-Path -LiteralPath $testRoot)) {
        $resolved=[IO.Path]::GetFullPath($testRoot)
        $boundary=[IO.Path]::GetFullPath($(if ($requestedStateRoot) { Join-Path $requestedStateRoot 'test-artifacts' } else { [IO.Path]::GetTempPath() })).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-server-lab-container-tool-*'){throw 'CONTAINER_TOOL_TEST_CLEANUP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    $env:SQL_SERVER_LAB_STATE = $previousStateRoot
    if($mutexAcquired){$mutex.ReleaseMutex()};$mutex.Dispose()
}
if($cleanupFailed){throw 'CONTAINER_TOOL_TEST_CLEANUP_FAILED'}
