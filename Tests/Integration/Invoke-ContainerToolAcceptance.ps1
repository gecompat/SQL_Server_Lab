#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den kataloggebundenen SqlPackage-Container-Tool-Pfad nativ.
.DESCRIPTION
    Provisioniert einen isolierten SQL-2022-Manifest-Run mit SqlPackage,
    prueft ausschliesslich den oeffentlichen read-only Versionsprobe-Command
    vor und nach einem Restart und entfernt danach Run sowie test-eigenes
    Derived Image wieder vollstaendig.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
    [string]$EvidencePath,
    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-server-lab-container-tool-$Provider-$([guid]::NewGuid().ToString('N'))"
$stateRoot = Join-Path $testRoot 'state'
$manifestPath = Join-Path $testRoot 'manifest.json'
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$lab = $null
$runtimeInvocation = $null
$imageName = $null
$bacpacSourcePath = $null
$bacpacContainerPath = $null
$completed = $false

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

try {
    $runtimeResolution = @(& (Join-Path $repoRoot 'Tools\Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    Assert-ContainerToolAcceptance ([bool]$runtimeResolution.Available) "Runtime-CLI '$Provider' ist zentral aufloesbar"
    $runtimeInvocation = [string]$runtimeResolution.Invocation
    if ($Provider -eq 'podman') { & (Join-Path $PSScriptRoot 'Initialize-PodmanRuntime.ps1') | Out-Host }
    & $runtimeInvocation info 1>$null 2>$null
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
    Assert-ContainerToolAcceptance (
        [string]$receipt.status -eq 'IMAGE_READY' -and
        [string]$receipt.retention -eq 'reusable-explicit-removal' -and
        [string]$receipt.runtimeVersion -eq [string]$instance.ContainerTools.RuntimeVersion -and
        (@($receipt.toolIds) -join ',') -eq 'sqlpackage'
    ) 'Derived Image besitzt einen scope-lokalen, kataloggebundenen Receipt'

    $probe = Test-SqlServerLabContainerTool -RunId $lab.RunId -InstanceId 'container-tool' -StateRoot $stateRoot
    Assert-ContainerToolAcceptance (
        [string]$probe.Status -eq 'PASS' -and [string]$probe.ToolId -eq 'sqlpackage' -and
        [string]$probe.Provider -eq $Provider -and [string]$probe.RuntimeVersion -eq [string]$instance.ContainerTools.RuntimeVersion
    ) 'Oeffentliche Run-/Scope-gebundene SqlPackage-Versionsprobe besteht'

    $status = Get-SqlServerLab -RunId $lab.RunId
    $statusJson = $status | ConvertTo-Json -Depth 30
    Assert-ContainerToolAcceptance (
        [string]$status.Instances[0].ContainerTools.RuntimeVersion -eq [string]$probe.RuntimeVersion -and
        $statusJson -notmatch '(?i)(localImageId|containerTools\.receipt|containerTools\.source)'
    ) 'Oeffentliche Statussicht bleibt auf sanitisierte Tool-Metadaten begrenzt'

    $restart = Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 300 -Force
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
        $exportOutput = @(& $runtimeInvocation exec --env "SQLSERVERLAB_SA_PASSWORD=$saPlain" --user mssql $instance.ContainerName sh -ceu $exportCommand -- $sourceDatabase $bacpacContainerPath 2>&1)
        Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0) 'Kataloggebundenes SqlPackage exportiert ein synthetisches BACPAC ohne Host-Tool'
    }
    finally {
        $saPlain = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $bacpacSourcePath = Join-Path $testRoot 'synthetic-source.bacpac'
    & $runtimeInvocation cp "$($instance.ContainerName):$bacpacContainerPath" $bacpacSourcePath 1>$null
    Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $bacpacSourcePath -PathType Leaf)) 'Exportiertes BACPAC wird als kontrolliertes Testartefakt aus dem Run gelesen'
    & $runtimeInvocation exec --user root $instance.ContainerName rm -f -- $bacpacContainerPath 1>$null
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
    $residualBacpac = @(& $runtimeInvocation exec --user root $instance.ContainerName sh -ceu 'test -z "$(find /tmp -maxdepth 1 -name ''sql-server-lab-bacpac-*.bacpac'' -print -quit)"' 2>&1)
    Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0) 'BACPAC-Import hinterlässt kein temporäres Containerartefakt'

    $cleanup = Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false
    Assert-ContainerToolAcceptance ([string]$cleanup.Status -eq 'REMOVED') 'Registrierter Run-Cleanup entfernt ausschliesslich Run-Ressourcen'
    $lab = $null
    & $runtimeInvocation image inspect $imageName 1>$null 2>$null
    Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0) 'Wiederverwendbares Derived Image bleibt vom Run-Cleanup getrennt'
    & $runtimeInvocation image rm --force $imageName 1>$null
    Assert-ContainerToolAcceptance ($LASTEXITCODE -eq 0) 'Test-eigenes Derived Image wurde explizit entfernt'
    $imageName = $null

    if ($EvidencePath) {
        $evidenceDirectory = Split-Path -Parent $EvidencePath
        if ($evidenceDirectory) { New-Item -Path $evidenceDirectory -ItemType Directory -Force | Out-Null }
        [ordered]@{
            contract = [ordered]@{ name = 'SqlServerLab.ContainerToolAcceptance'; version = '1.0' }
            status = 'PASS'; provider = $Provider; sqlVersion = '2022'
            tool = [ordered]@{ id = [string]$probe.ToolId; runtimeVersion = [string]$probe.RuntimeVersion; imageKey = [string]$instance.ContainerTools.ImageKey }
            bacpac = [ordered]@{ status = [string]$bacpacImport.Status; source = 'synthetic'; targetDatabase = $targetDatabase; dataRoundtrip = $true }
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
        try { Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false | Out-Null }
        catch { Write-Warning "Fehler-Cleanup des Runs schlug fehl: $($_.Exception.Message)" }
    }
    if ($imageName -and -not $KeepOnFailure -and $runtimeInvocation) {
        try { & $runtimeInvocation image rm --force $imageName 1>$null 2>$null } catch { }
    }
    if ($bacpacContainerPath -and -not $KeepOnFailure -and $runtimeInvocation -and $lab) {
        try { & $runtimeInvocation exec --user root $lab.Instances[0].ContainerName rm -f -- $bacpacContainerPath 1>$null 2>$null } catch { }
    }
    if (($completed -or -not $KeepOnFailure) -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $env:SQL_SERVER_LAB_STATE = $previousStateRoot
}
