#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt den realen SQL-Prepared-Image-Build und Manifest-Klon aus.
.DESCRIPTION
    Installiert Windows Server 2025 aus einem hashverifizierten Eval-Medium
    unbeaufsichtigt auf einer neuen VHDX, fuehrt SQL Server 2025 PrepareImage
    aus, generalisiert Windows genau einmal und veroeffentlicht das Ergebnis
    testlokal als immutable SQL_PREPARED_SEALED-Artifact. Dieses Artifact wird
    anschliessend ueber den normalen Manifestpfad differenzierend geklont,
    per CompleteImage vervollstaendigt und bis SQL_READY_RUN verifiziert.

    Produktive Artifact Registry und Medien bleiben unveraendert. VM,
    Builder-Disk, Antwort-ISO, Credential und temporaerer State werden auch
    bei Fehlern soweit sicher moeglich entfernt.
.PARAMETER TimeoutSeconds
    Maximale Wartezeit fuer OOBE, einen Setup-Neustart und den Sysprep-Shutdown.
.PARAMETER SetupTimeoutSeconds
    Maximale Laufzeit fuer SQL Server PrepareImage.
.PARAMETER RetainPreparedArtifact
    Behaelt das isolierte testlokale State-Root ausschliesslich nach einem
    vollstaendig erfolgreichen Lauf fuer einen unmittelbar nachgelagerten
    Acceptance-Test. Der Standard bleibt vollstaendiger Cleanup. Bei Nutzung
    werden State-Root und Artifact-ID maschinenlesbar ausgegeben; der Aufrufer
    ist fuer den anschliessenden scopegebundenen Cleanup verantwortlich.
#>
[CmdletBinding()]
param(
    [ValidateRange(300, 3600)]
    [int]$TimeoutSeconds = 1200,

    [ValidateRange(600, 10800)]
    [int]$SetupTimeoutSeconds = 7200,

    [switch]$RetainPreparedArtifact
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$productionStateRoot = $null
$stateRoot = $null
$buildId = $null
$builderVmName = $null
$builderDiskPath = $null
$answerDirectory = $null
$answerIsoPath = $null
$adminPassword = $null
$saPassword = $null
$credential = $null
$manifestPath = $null
$manifestRunId = $null
$manifestVmName = $null
$manifestChildVhdxPath = $null
$testFailed = $false
$cleanupFailed = $false

function Assert-SqlPreparedAcceptance {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Description
    )

    if (-not $Condition) { throw $Description }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

function New-SqlPreparedAcceptanceAnswerIso {
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (-not ('SqlServerLabSqlPreparedAcceptanceImapiStreamCopy' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class SqlServerLabSqlPreparedAcceptanceImapiStreamCopy
{
    public static void ToFile(object source, string path)
    {
        IStream stream = (IStream)source;
        byte[] buffer = new byte[65536];
        IntPtr bytesReadPointer = Marshal.AllocCoTaskMem(sizeof(int));
        try
        {
            using (FileStream file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                while (true)
                {
                    Marshal.WriteInt32(bytesReadPointer, 0);
                    stream.Read(buffer, buffer.Length, bytesReadPointer);
                    int bytesRead = Marshal.ReadInt32(bytesReadPointer);
                    if (bytesRead <= 0) break;
                    file.Write(buffer, 0, bytesRead);
                }
            }
        }
        finally
        {
            Marshal.FreeCoTaskMem(bytesReadPointer);
        }
    }
}
'@
    }

    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $image.FileSystemsToCreate = 3
    $image.VolumeName = 'SQLLAB_PREPARED'
    $image.Root.AddTree($SourceDirectory, $false)
    $result = $image.CreateResultImage()
    try {
        [SqlServerLabSqlPreparedAcceptanceImapiStreamCopy]::ToFile($result.ImageStream, $DestinationPath)
    }
    finally {
        foreach ($comObject in @($result,$image)) {
            if ($comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject)
            }
        }
    }
    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf) -or
        (Get-Item -LiteralPath $DestinationPath).Length -lt 32768) {
        throw 'SQL_PREPARED_ACCEPTANCE_ANSWER_ISO_INVALID'
    }
}

function Add-SqlPreparedAcceptanceWindowsSetupPass {
    param(
        [Parameter(Mandatory)][string]$OobeUnattend,
        [Parameter(Mandatory)][ValidateRange(1, 99)][int]$ImageIndex
    )

    $rootElement = '<unattend xmlns="urn:schemas-microsoft-com:unattend">'
    $windowsSetupPass = @"
$rootElement
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>0407:00000407</InputLocale>
      <SystemLocale>de-DE</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>de-DE</UserLocale>
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>100</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
        <WillShowUI>OnError</WillShowUI>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>$ImageIndex</Value></MetaData></InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData><AcceptEula>true</AcceptEula></UserData>
    </component>
  </settings>
"@
    if (-not $OobeUnattend.Contains($rootElement)) {
        throw 'SQL_PREPARED_ACCEPTANCE_OOBE_UNATTEND_ROOT_MISSING'
    }
    return $OobeUnattend.Replace($rootElement, $windowsSetupPass)
}

try {
    Write-Host 'Reale Hyper-V-SQL-Prepared-Image-Abnahme' -ForegroundColor Cyan
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'SQL_PREPARED_ACCEPTANCE_REQUIRES_ELEVATED_RUNNER'
    }
    Assert-SqlPreparedAcceptance -Condition $true -Description 'Runner arbeitet erhoeht'
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force
    $module = Get-Module SqlServerLab

    $productionStateRoot = & $module { Get-LabStateRoot }
    $mediaRoot = & $module { Get-LabMediaRootDefault }
    $windowsMedia = & $module {
        param($Root)
        Resolve-HyperVWindowsInstallationMedia -MediaRoot $Root -OperatingSystemId windows-server-2025 `
            -WindowsEdition standard-evaluation -InstallationType desktop-experience
    } $mediaRoot
    $sqlMedia = & $module {
        param($Root)
        Resolve-HyperVSqlInstallationMedia -MediaRoot $Root -SqlVersion 2025 -MediaEdition Enterprise
    } $mediaRoot
    $detectedMedia = & $module {
        param($Root, $WindowsPath, $SqlPath)
        [pscustomobject]@{
            Windows = @(Get-HyperVWindowsInstallationMediaCandidates -MediaRoot $Root | Where-Object {
                [string]$_.OperatingSystemId -eq 'windows-server-2025' -and
                [string]$_.WindowsEdition -eq 'standard-evaluation' -and
                [string]$_.InstallationType -eq 'desktop-experience' -and
                [IO.Path]::GetFullPath((Join-Path $Root ([string]$_.MediaId).Replace('/', '\'))).Equals(
                    [IO.Path]::GetFullPath($WindowsPath), [StringComparison]::OrdinalIgnoreCase)
            })
            Sql = @(Get-HyperVSqlInstallationMediaCandidates -MediaRoot $Root | Where-Object {
                [string]$_.SqlVersion -eq '2025' -and [string]$_.MediaEdition -eq 'Enterprise' -and
                [IO.Path]::GetFullPath((Join-Path $Root ([string]$_.MediaId).Replace('/', '\'))).Equals(
                    [IO.Path]::GetFullPath($SqlPath), [StringComparison]::OrdinalIgnoreCase)
            })
        }
    } $mediaRoot ([string]$windowsMedia.IsoPath) ([string]$sqlMedia.IsoPath)
    Assert-SqlPreparedAcceptance -Condition (
        $windowsMedia.HashStatus -eq 'SIDECAR_READY' -and $windowsMedia.ExpectedSha256 -and
        @($detectedMedia.Windows).Count -eq 1 -and [int]$detectedMedia.Windows[0].ImageIndex -eq 2
    ) -Description 'Windows Server 2025 Standard Evaluation Desktop ist per SHA-256 freigegeben'
    Assert-SqlPreparedAcceptance -Condition (
        $sqlMedia.HashStatus -eq 'SIDECAR_READY' -and $sqlMedia.ExpectedSha256 -and
        @($detectedMedia.Sql).Count -eq 1 -and [string]$detectedMedia.Sql[0].SetupVersion -match '^17\.'
    ) -Description 'SQL Server 2025 Enterprise Developer ist per SHA-256 und Setup-Build freigegeben'
    $sqlSetupVersionPattern = & $module { Get-HyperVSqlSetupVersionPattern -SqlVersion 2025 }

    # Hyper-V erweitert -Path intern noch um VM-Name und Smart-Paging-Datei.
    # Der isolierte Scope bleibt deshalb bewusst kurz und dennoch kollisionsfest.
    $stateRoot = Join-Path $productionStateRoot ('n4sql-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -Path $stateRoot -ItemType Directory -ErrorAction Stop | Out-Null
    $env:SQL_SERVER_LAB_STATE = $stateRoot

    $adminPassword = [Security.SecureString]::new()
    $passwordToken = "SqlPrepared_$([guid]::NewGuid().ToString('N'))!Aa7"
    foreach ($character in $passwordToken.ToCharArray()) { $adminPassword.AppendChar($character) }
    $passwordToken = $null
    $adminPassword.MakeReadOnly()
    $credential = [PSCredential]::new('Administrator', $adminPassword)

    $build = & $module {
        param($Root, $MediaRoot)
        Initialize-HyperVSqlFreshPreparedImageBuild -MediaRoot $MediaRoot `
            -OperatingSystemId windows-server-2025 -WindowsEdition standard-evaluation `
            -InstallationType desktop-experience -SqlVersion 2025 -MediaEdition Enterprise `
            -SqlFeatures SQLENGINE,FULLTEXT,REPLICATION -ImageName 'N4 SQL 2025 Prepared Acceptance' `
            -MemoryStartupBytes 4GB -ProcessorCount 2 -StateRoot $Root
    } $stateRoot $mediaRoot
    $buildId = [string]$build.buildId
    $builderVmName = [string]$build.builder.vmName
    $builderDiskPath = & $module {
        param($Build)
        Resolve-LabHyperVBuilderDiskPath -Build $Build
    } $build
    Assert-SqlPreparedAcceptance -Condition (
        $build.state -eq 'MANUAL_ACTION_REQUIRED' -and
        $build.provisioningMode -eq 'fresh-windows-media'
    ) -Description 'Produktiver Builder erstellte eine frische testlokale Windows-/SQL-VM'

    $vm = Get-VM -Name $builderVmName -ErrorAction Stop
    $testVhd = Get-VHD -Path $builderDiskPath -ErrorAction Stop
    Assert-SqlPreparedAcceptance -Condition ([string]::IsNullOrWhiteSpace([string]$testVhd.ParentPath)) `
        -Description 'Builder-Disk ist eine neue eigenstaendige VHDX'

    $answerDirectory = Join-Path $build.BuildDirectory 'sql-prepared-oobe-answer'
    $answerIsoPath = Join-Path $build.BuildDirectory 'sql-prepared-oobe-answer.iso'
    $null = New-Item -Path $answerDirectory -ItemType Directory -ErrorAction Stop
    $unattend = $null
    try {
        $unattend = & $module {
            param($Password, $Identity)
            New-HyperVSqlOobeUnattendXml -AdministratorPassword $Password -Identity $Identity
        } $adminPassword $buildId
        $unattend = Add-SqlPreparedAcceptanceWindowsSetupPass -OobeUnattend $unattend `
            -ImageIndex ([int]$detectedMedia.Windows[0].ImageIndex)
        [void][xml]$unattend
        [IO.File]::WriteAllText((Join-Path $answerDirectory 'Autounattend.xml'), $unattend, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $answerDirectory 'Unattend.xml'), $unattend, [Text.UTF8Encoding]::new($false))
        New-SqlPreparedAcceptanceAnswerIso -SourceDirectory $answerDirectory -DestinationPath $answerIsoPath
    }
    finally { $unattend = $null }
    Remove-Item -LiteralPath $answerDirectory -Recurse -Force -ErrorAction Stop
    $answerDirectory = $null
    $null = Add-VMDvdDrive -VM $vm -Path $answerIsoPath -ErrorAction Stop

    $started = & $module {
        param($Id, $Root)
        Start-HyperVSqlImageBuildVM -BuildId $Id -StateRoot $Root
    } $buildId $stateRoot
    Assert-SqlPreparedAcceptance -Condition (
        [string]$started.State -eq 'Running' -and
        [string]$started.InitialMediaBoot.status -eq 'SENT' -and
        [int]$started.InitialMediaBoot.attempts -eq 30 -and
        [int]$started.InitialMediaBoot.successfulSends -gt 0
    ) -Description 'Produktiver UEFI-DVD-Bootvertrag deckte das reale Setup-Zeitfenster ab'
    $ready = & $module {
        param($VmName, $Id, $ScopeId, $Credential, $Timeout)
        Wait-HyperVPowerShellDirect -VMName $VmName -ExpectedRunId $Id -ExpectedScopeId $ScopeId `
            -Credential $Credential -TimeoutSeconds $Timeout
    } $builderVmName $buildId ([string]$build.scopeId) $credential $TimeoutSeconds
    Assert-SqlPreparedAcceptance -Condition ([bool]$ready.Ready) `
        -Description 'Frisch installierter Windows-Gast ist nach OOBE ueber PowerShell Direct erreichbar'

    $answerFullPath = [IO.Path]::GetFullPath($answerIsoPath)
    $answerDrives = @($vm | Get-VMDvdDrive -ErrorAction Stop | Where-Object {
        $_.Path -and [IO.Path]::GetFullPath([string]$_.Path).Equals(
            $answerFullPath, [StringComparison]::OrdinalIgnoreCase)
    })
    Assert-SqlPreparedAcceptance -Condition ($answerDrives.Count -eq 1) `
        -Description 'Testlokales Credential-ISO ist eindeutig an die Builder-VM gebunden'
    $answerDrives | Remove-VMDvdDrive -ErrorAction Stop
    Remove-Item -LiteralPath $answerIsoPath -Force -ErrorAction Stop
    $answerIsoPath = $null

    $guestPreparation = @(& $module {
        param($VmName, $Id, $ScopeId, $Credential, $SetupVersionPattern)
        Invoke-HyperVPowerShellDirect -VMName $VmName -ExpectedRunId $Id -ExpectedScopeId $ScopeId `
            -Credential $Credential -ArgumentList @($SetupVersionPattern) -ScriptBlock {
                param($ExpectedSetupVersionPattern)
                $ErrorActionPreference = 'Stop'
                Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend.xml" -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend\Unattend.xml" -Force -ErrorAction SilentlyContinue
                $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
                Remove-ItemProperty -LiteralPath $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
                Set-ItemProperty -LiteralPath $winlogon -Name AutoAdminLogon -Value '0' -ErrorAction SilentlyContinue
                $allSetups = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object {
                    $candidate = Join-Path ([string]$_.DeviceID + '\') 'setup.exe'
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate }
                })
                $sqlSetups = @($allSetups | Where-Object {
                    [string]$_.VersionInfo.FileVersion -match $ExpectedSetupVersionPattern
                })
                [pscustomobject]@{
                    imageState = [string](Get-ItemPropertyValue `
                        -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState)
                    sqlSetupCount = $sqlSetups.Count
                    sqlSetupVersion = if ($sqlSetups.Count -eq 1) { [string]$sqlSetups[0].VersionInfo.FileVersion } else { $null }
                    observedSetupVersions = @($allSetups | ForEach-Object { [string]$_.VersionInfo.FileVersion })
                }
            }
    } $builderVmName $buildId ([string]$build.scopeId) $credential $sqlSetupVersionPattern)[-1]
    if ([string]$guestPreparation.imageState -ne 'IMAGE_STATE_COMPLETE' -or
        [int]$guestPreparation.sqlSetupCount -ne 1 -or
        [string]$guestPreparation.sqlSetupVersion -notmatch $sqlSetupVersionPattern) {
        throw "SQL_PREPARED_ACCEPTANCE_GUEST_MEDIA_INVALID: ImageState=$($guestPreparation.imageState); SQLSetups=$($guestPreparation.sqlSetupCount); beobachtet=$(@($guestPreparation.observedSetupVersions) -join ',')"
    }
    Assert-SqlPreparedAcceptance -Condition $true `
        -Description 'Gast ist vollstaendig installiert, bereinigt und sieht genau ein SQL-2025-Setup'

    $published = & $module {
        param($Id, $Credential, $SetupTimeout, $ShutdownTimeout, $Root)
        Complete-HyperVSqlPreparedImageBuild -BuildId $Id -Credential $Credential `
            -SetupTimeoutSeconds $SetupTimeout -ShutdownTimeoutSeconds $ShutdownTimeout -StateRoot $Root
    } $buildId $credential $SetupTimeoutSeconds $TimeoutSeconds $stateRoot
    Assert-SqlPreparedAcceptance -Condition (
        [string]$published.Status -eq 'SQL_PREPARED_SEALED' -and
        [string]$published.Artifact.artifactState -eq 'SQL_PREPARED_SEALED' -and
        [bool]$published.Artifact.generalized -and [bool]$published.Artifact.sqlPrepared -and
        [string]$published.Artifact.sql.version -eq '2025' -and
        [string]$published.Artifact.sql.build -match $sqlSetupVersionPattern -and
        (Get-Item -LiteralPath $published.Artifact.Path -Force).IsReadOnly
    ) -Description 'PrepareImage und Sysprep erzeugten ein immutable SQL_PREPARED_SEALED-Artifact'
    Assert-SqlPreparedAcceptance -Condition (
        [string]$published.Build.generalizationEvidence.source -eq 'powershell-direct' -and
        [string]$published.Build.generalizationEvidence.imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' -and
        [int]$published.Build.generalizationEvidence.sysprepExitCode -eq 0
    ) -Description 'Finales Windows-Generalize ist durch den echten Gast-Receipt gebunden'
    Assert-SqlPreparedAcceptance -Condition (
        [string]$published.Cleanup.Status -eq 'CLEANUP_SUCCEEDED' -and
        -not (Get-VM -Name $builderVmName -ErrorAction SilentlyContinue) -and
        -not (Test-Path -LiteralPath $builderDiskPath -PathType Leaf)
    ) -Description 'Publish entfernte Builder-VM und buildlokale VHDX scopegebunden'

    $preparedArtifactPath = [string]$published.Artifact.Path
    $preparedArtifactHash = (Get-FileHash -LiteralPath $preparedArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $saPassword = [Security.SecureString]::new()
    $saPasswordToken = "SqlReady_$([guid]::NewGuid().ToString('N'))!Bb8"
    foreach ($character in $saPasswordToken.ToCharArray()) { $saPassword.AppendChar($character) }
    $saPasswordToken = $null
    $saPassword.MakeReadOnly()

    $manifestPath = Join-Path $stateRoot 'n4-sql-ready-manifest.json'
    $manifest = [ordered]@{
        name = 'n4-sql-ready-manifest'
        instances = @(
            [ordered]@{
                id = 'primary'; version = '2025'; provider = 'hyperv'; os = 'windows'
                profile = 'standard'
                hyperv = [ordered]@{
                    preparedImageId = [string]$published.Artifact.artifactId
                    memoryStartupMB = 4096; processorCount = 2
                    autostart = 'off'; guestPasswordMode = 'prompt'
                }
            }
        )
    }
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $manifest = $null
    $manifestResult = New-SqlServerLab -Manifest $manifestPath -GuestPassword $adminPassword `
        -SqlSaPassword $saPassword -NonInteractive -StateRoot $stateRoot
    $manifestRunId = [string]$manifestResult.RunId
    $manifestVmName = [string]$manifestResult.Instances[0].vmName
    $manifestContext = & $module {
        param($Id, $Root)
        Get-HyperVLabWorkflowRun -RunId $Id -StateRoot $Root
    } $manifestRunId $stateRoot
    $managedManifestVm = & $module {
        param($VmName, $RunId, $ScopeId)
        Get-HyperVManagedVM -VMName $VmName -ExpectedRunId $RunId -ExpectedScopeId $ScopeId
    } $manifestVmName $manifestRunId ([string]$manifestContext.Run.scopeId)
    $manifestChildVhdxPath = [string]$managedManifestVm.Identity.childVhdxPath
    $readiness = $manifestContext.Instance.sqlReadiness
    Assert-SqlPreparedAcceptance -Condition (
        [string]$manifestResult.State -eq 'RUNNING' -and
        [string]$manifestResult.Provisioning.SqlCompletion.sqlReadiness.status -eq 'SQL_READY_RUN' -and
        [string]$readiness.status -eq 'SQL_READY_RUN' -and
        [string]$readiness.provider -eq 'hyperv' -and
        [int]$readiness.majorVersion -eq 17 -and
        [int]$readiness.onlineSystemDatabases -eq 4
    ) -Description 'Normaler Manifestpfad erreichte im echten Gast SQL_READY_RUN mit SQL-Major 17 und vier Online-Systemdatenbanken'
    Assert-SqlPreparedAcceptance -Condition (
        [string]$manifestContext.Instance.sqlCompletion.state -eq 'COMPLETE' -and
        [string]$manifestContext.Instance.sqlCompletion.serviceStatus -eq 'Running' -and
        [string]$manifestContext.Instance.hostSqlAccess.state -eq 'READY' -and
        -not [string]::IsNullOrWhiteSpace([string]$manifestContext.Instance.host) -and
        [int]$manifestContext.Instance.port -eq 1433
    ) -Description 'CompleteImage, Windows-Specialization, WMI und Hyper-V-Hostzugriff sind real gebunden'
    Assert-SqlPreparedAcceptance -Condition (
        (Test-Path -LiteralPath $manifestChildVhdxPath -PathType Leaf) -and
        (Get-VHD -Path $manifestChildVhdxPath -ErrorAction Stop).ParentPath -and
        (Get-Item -LiteralPath $preparedArtifactPath -Force).IsReadOnly -and
        (Get-FileHash -LiteralPath $preparedArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $preparedArtifactHash
    ) -Description 'Manifestklon verwendet eine Child-VHDX und ließ Hash sowie Schreibschutz des Prepared-Parents unverändert'

    $manifestCleanup = Remove-SqlServerLab -RunId $manifestRunId -StateRoot $stateRoot -Force -Confirm:$false
    Assert-SqlPreparedAcceptance -Condition (
        [string]$manifestCleanup.Status -eq 'REMOVED' -and
        [string]$manifestCleanup.Cleanup -eq 'CLEANUP_SUCCEEDED' -and
        -not (Get-VM -Name $manifestVmName -ErrorAction SilentlyContinue) -and
        -not (Test-Path -LiteralPath $manifestChildVhdxPath -PathType Leaf)
    ) -Description 'Normaler Manifest-Cleanup entfernte VM, Child-VHDX und Secrets scopegebunden'
}
catch {
    $testFailed = $true
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($answerIsoPath -and $builderVmName) {
        try {
            $answerFullPath = [IO.Path]::GetFullPath($answerIsoPath)
            $answerDrives = @(Get-VM -Name $builderVmName -ErrorAction SilentlyContinue |
                Get-VMDvdDrive -ErrorAction SilentlyContinue | Where-Object {
                    $_.Path -and [IO.Path]::GetFullPath([string]$_.Path).Equals(
                        $answerFullPath, [StringComparison]::OrdinalIgnoreCase)
                })
            if ($answerDrives) { $answerDrives | Remove-VMDvdDrive -ErrorAction SilentlyContinue }
        }
        catch { }
    }

    if ($stateRoot -and (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        try {
            $module = Get-Module SqlServerLab
            $activeManifestRuns = @(& $module {
                param($Root)
                Get-LabActiveRuns -StateRoot $Root | Where-Object {
                    [string]$_.metadata.workflowKind -eq 'hyperv-lab'
                }
            } $stateRoot)
            foreach ($activeManifestRun in $activeManifestRuns) {
                $manifestCleanup = Remove-SqlServerLab -RunId ([string]$activeManifestRun.runId) `
                    -StateRoot $stateRoot -Force -Confirm:$false
                if ([string]$manifestCleanup.Status -ne 'REMOVED') {
                    throw "SQL_PREPARED_MANIFEST_CLEANUP_INCOMPLETE: $($manifestCleanup.Status)"
                }
            }
        }
        catch {
            $cleanupFailed = $true
            $testFailed = $true
            Write-Host "SQL-Prepared-Manifest-Cleanup-Fehler: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    if ($buildId -and $stateRoot -and (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        try {
            $module = Get-Module SqlServerLab
            $currentBuild = & $module {
                param($Id, $Root)
                Get-HyperVSqlImageBuildPlan -BuildId $Id -StateRoot $Root
            } $buildId $stateRoot
            $vmExists = $builderVmName -and (Get-VM -Name $builderVmName -ErrorAction SilentlyContinue)
            $diskExists = $builderDiskPath -and (Test-Path -LiteralPath $builderDiskPath -PathType Leaf)
            if ($currentBuild -and ($vmExists -or $diskExists)) {
                $cleanup = & $module {
                    param($Id, $Root)
                    Remove-HyperVSqlImageBuild -BuildId $Id -StateRoot $Root
                } $buildId $stateRoot
                if ([string]$cleanup.Status -ne 'CLEANUP_SUCCEEDED') {
                    throw "SQL_PREPARED_ACCEPTANCE_CLEANUP_INCOMPLETE: $($cleanup.Status)"
                }
            }
        }
        catch {
            $cleanupFailed = $true
            $testFailed = $true
            Write-Host "SQL-Prepared-Cleanup-Fehler: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    $credential = $null
    if ($adminPassword) { $adminPassword.Dispose() }
    if ($saPassword) { $saPassword.Dispose() }
    $env:SQL_SERVER_LAB_STATE = $previousStateRoot

    foreach ($sensitivePath in @($answerIsoPath,$answerDirectory)) {
        if ($sensitivePath -and (Test-Path -LiteralPath $sensitivePath)) {
            Remove-Item -LiteralPath $sensitivePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $retainSuccessfulState = $RetainPreparedArtifact -and -not $testFailed -and -not $cleanupFailed
    if ($stateRoot -and -not $cleanupFailed -and -not $retainSuccessfulState -and
        (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        $resolvedStateRoot = [IO.Path]::GetFullPath($stateRoot).TrimEnd('\')
        $resolvedParent = [IO.Path]::GetFullPath($productionStateRoot).TrimEnd('\')
        $actualParent = [IO.Directory]::GetParent($resolvedStateRoot).FullName.TrimEnd('\')
        $leaf = [IO.Path]::GetFileName($resolvedStateRoot)
        if (-not $actualParent.Equals($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -or
            $leaf -notmatch '^n4sql-[a-f0-9]{8}$') {
            $testFailed = $true
            Write-Host 'SQL-Prepared-Cleanup-Fehler: temporaerer StateRoot liegt ausserhalb des erwarteten Scopes.' -ForegroundColor Red
        }
        else {
            Remove-Item -LiteralPath $resolvedStateRoot -Recurse -Force
        }
    }
}

if ($testFailed) { exit 1 }
if ($RetainPreparedArtifact) {
    Write-Host "RETAINED_STATE_ROOT=$stateRoot"
    Write-Host "RETAINED_ARTIFACT_ID=$([string]$published.Artifact.artifactId)"
}
Write-Host 'Reale Hyper-V-SQL-Prepared-Image-Abnahme erfolgreich.' -ForegroundColor Green
exit 0
