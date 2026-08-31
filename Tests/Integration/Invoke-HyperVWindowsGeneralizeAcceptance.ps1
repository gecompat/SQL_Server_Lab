#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt den realen positiven Windows-Generalize-/Publish-Pfad aus.
.DESCRIPTION
    Erstellt in einem isolierten temporaeren StateRoot einen Windows-Image-
    Builder und installiert Windows aus einem hashverifizierten Eval-Medium
    unbeaufsichtigt auf dessen leerer Disk. OOBE wird mit einem nur fuer diesen
    Lauf erzeugten Credential abgeschlossen. Danach werden Installationsevidenz,
    Sysprep /generalize, Shutdown, Generalization-Evidence und testlokale
    OS_SEALED-Publikation ueber die produktiven Funktionen ausgefuehrt.

    Die produktive Referenz-Baseline, die produktive Artifact Registry und das
    ISO werden nicht veraendert. VM, Builder-Disk, testlokales Artifact, Credential und
    temporaerer State werden auch bei Fehlern soweit sicher moeglich entfernt.
.PARAMETER ArtifactId
    ID einer veroeffentlichten Windows-Server-OS_SEALED-Baseline.
.PARAMETER ArtifactStateRoot
    Optionaler StateRoot der produktiven Baseline. Standard ist der konfigurierte
    SQL_Server_Lab-StateRoot.
.PARAMETER TimeoutSeconds
    Maximale Wartezeit fuer OOBE/PowerShell Direct und den Sysprep-Shutdown.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^hyperv-os-sealed-[a-f0-9]{64}$')]
    [string]$ArtifactId,

    [string]$ArtifactStateRoot,

    [ValidateRange(300, 3600)]
    [int]$TimeoutSeconds = 1200
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$stateRoot = $null
$buildId = $null
$builderVmName = $null
$builderDiskPath = $null
$answerDirectory = $null
$answerIsoPath = $null
$adminPassword = $null
$credential = $null
$testFailed = $false
$cleanupFailed = $false
$published = $null

function Assert-GeneralizeAcceptance {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Description
    )

    if (-not $Condition) { throw $Description }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

function New-GeneralizeAcceptanceAnswerIso {
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (-not ('SqlServerLabGeneralizeAcceptanceImapiStreamCopy' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class SqlServerLabGeneralizeAcceptanceImapiStreamCopy
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
    $image.VolumeName = 'SQLLAB_OOBE'
    $image.Root.AddTree($SourceDirectory, $false)
    $result = $image.CreateResultImage()
    try {
        [SqlServerLabGeneralizeAcceptanceImapiStreamCopy]::ToFile($result.ImageStream, $DestinationPath)
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
        throw 'GENERALIZE_ACCEPTANCE_ANSWER_ISO_INVALID'
    }
}

function Add-GeneralizeAcceptanceWindowsSetupPass {
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
        throw 'GENERALIZE_ACCEPTANCE_OOBE_UNATTEND_ROOT_MISSING'
    }
    return $OobeUnattend.Replace($rootElement, $windowsSetupPass)
}

try {
    Write-Host 'Reale Hyper-V-Windows-Generalize-Abnahme' -ForegroundColor Cyan
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force
    $module = Get-Module SqlServerLab

    if ([string]::IsNullOrWhiteSpace($ArtifactStateRoot)) {
        $ArtifactStateRoot = & $module { Get-LabStateRoot }
    }
    $ArtifactStateRoot = (Resolve-Path -LiteralPath $ArtifactStateRoot -ErrorAction Stop).Path
    $sourceArtifact = & $module {
        param($Id, $Root)
        Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root
    } $ArtifactId $ArtifactStateRoot
    Assert-GeneralizeAcceptance -Condition (
        $sourceArtifact -and
        [string]$sourceArtifact.artifactState -eq 'OS_SEALED' -and
        [bool]$sourceArtifact.generalized -and
        [string]$sourceArtifact.operatingSystem.id -match '^windows-server-'
    ) -Description 'Produktive Referenz liefert hashverifizierte Windows-Server-Medienmetadaten'
    Assert-GeneralizeAcceptance -Condition ((Get-Item -LiteralPath $sourceArtifact.Path -Force).IsReadOnly) `
        -Description 'Produktive Parent-VHDX ist vor dem Test schreibgeschuetzt'

    $evaluationExpiresAt = if ([string]$sourceArtifact.license.type -eq 'evaluation') {
        [datetime]$sourceArtifact.license.evaluationExpiresAt
    }
    else { $null }
    Assert-GeneralizeAcceptance -Condition (
        [string]$sourceArtifact.license.type -ne 'evaluation' -or
        ($evaluationExpiresAt -and $evaluationExpiresAt.ToUniversalTime() -gt [datetime]::UtcNow.AddDays(30))
    ) -Description 'Windows-Lizenzmetadaten erlauben den isolierten Generalize-Lauf'

    $mediaRoot = & $module { Get-LabMediaRootDefault }
    $media = & $module {
        param($Root, $OsId, $Edition, $InstallationType)
        Resolve-HyperVWindowsInstallationMedia -MediaRoot $Root -OperatingSystemId $OsId `
            -WindowsEdition $Edition -InstallationType $InstallationType
    } $mediaRoot ([string]$sourceArtifact.operatingSystem.id) `
        ([string]$sourceArtifact.operatingSystem.edition) `
        ([string]$sourceArtifact.operatingSystem.installationType)
    Assert-GeneralizeAcceptance -Condition ($media.HashStatus -eq 'SIDECAR_READY' -and $media.ExpectedSha256) `
        -Description 'Passendes Windows-Installationsmedium ist per SHA-256-Sidecar freigegeben'

    $stateRoot = Join-Path $ArtifactStateRoot ('acceptance-generalize-' + [guid]::NewGuid().ToString('N'))
    New-Item -Path $stateRoot -ItemType Directory -ErrorAction Stop | Out-Null
    $env:SQL_SERVER_LAB_STATE = $stateRoot

    $adminPassword = [Security.SecureString]::new()
    $passwordToken = "Generalize_$([guid]::NewGuid().ToString('N'))!Aa7"
    foreach ($character in $passwordToken.ToCharArray()) { $adminPassword.AppendChar($character) }
    $passwordToken = $null
    $adminPassword.MakeReadOnly()
    $credential = [PSCredential]::new('Administrator', $adminPassword)

    $sourceVhd = Get-VHD -Path ([string]$sourceArtifact.Path) -ErrorAction Stop
    $build = & $module {
        param($IsoPath, $ExpectedSha256, $OsId, $Edition, $InstallationType, $Language, $LicenseType, $DiskSize, $Root)
        New-HyperVWindowsImageBuildPlan -IsoPath $IsoPath -ExpectedSha256 $ExpectedSha256 `
            -OperatingSystemId $OsId -Edition $Edition -InstallationType $InstallationType `
            -Language $Language -LicenseType $LicenseType -InitialMediaKey space `
            -OsDiskSizeBytes $DiskSize -StateRoot $Root
    } ([string]$media.IsoPath) ([string]$media.ExpectedSha256) `
        ([string]$sourceArtifact.operatingSystem.id) ([string]$sourceArtifact.operatingSystem.edition) `
        ([string]$sourceArtifact.operatingSystem.installationType) ([string]$sourceArtifact.operatingSystem.language) `
        ([string]$sourceArtifact.license.type) ([long]$sourceVhd.Size) $stateRoot
    $buildId = [string]$build.buildId
    $build = & $module {
        param($Id, $Root)
        $null = New-HyperVWindowsImageBuilder -BuildId $Id -MemoryStartupBytes 4GB -ProcessorCount 2 -StateRoot $Root
        Set-HyperVImageBuildManualAction -BuildId $Id -StateRoot $Root
    } $buildId $stateRoot
    $builderVmName = [string]$build.builder.vmName
    $builderDiskPath = & $module {
        param($Build)
        Resolve-LabHyperVBuilderDiskPath -Build $Build
    } $build
    Assert-GeneralizeAcceptance -Condition ($build.state -eq 'MANUAL_ACTION_REQUIRED') `
        -Description 'Testlokaler Windows-Builder wartet am produktiven Generalize-Gate'

    $vm = Get-VM -Name $builderVmName -ErrorAction Stop
    $testVhd = Get-VHD -Path $builderDiskPath -ErrorAction Stop
    Assert-GeneralizeAcceptance -Condition ([string]::IsNullOrWhiteSpace([string]$testVhd.ParentPath)) `
        -Description 'Builder verwendet eine neue eigenstaendige VHDX ohne Parent-Abhaengigkeit'

    $answerDirectory = Join-Path $build.BuildDirectory 'generalize-oobe-answer'
    $answerIsoPath = Join-Path $build.BuildDirectory 'generalize-oobe-answer.iso'
    $null = New-Item -Path $answerDirectory -ItemType Directory -ErrorAction Stop
    $unattend = $null
    try {
        $unattend = & $module {
            param($Password, $Identity)
            New-HyperVSqlOobeUnattendXml -AdministratorPassword $Password -Identity $Identity
        } $adminPassword $buildId
        if ([string]$sourceArtifact.operatingSystem.edition -ne 'standard-evaluation' -or
            [string]$sourceArtifact.operatingSystem.installationType -ne 'desktop-experience') {
            throw 'GENERALIZE_ACCEPTANCE_REQUIRES_STANDARD_EVALUATION_DESKTOP_EXPERIENCE'
        }
        $unattend = Add-GeneralizeAcceptanceWindowsSetupPass -OobeUnattend $unattend -ImageIndex 2
        [void][xml]$unattend
        [IO.File]::WriteAllText((Join-Path $answerDirectory 'Autounattend.xml'), $unattend, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $answerDirectory 'Unattend.xml'), $unattend, [Text.UTF8Encoding]::new($false))
        New-GeneralizeAcceptanceAnswerIso -SourceDirectory $answerDirectory -DestinationPath $answerIsoPath
    }
    finally { $unattend = $null }
    Remove-Item -LiteralPath $answerDirectory -Recurse -Force -ErrorAction Stop
    $answerDirectory = $null
    $null = Add-VMDvdDrive -VM $vm -Path $answerIsoPath -ErrorAction Stop
    Assert-GeneralizeAcceptance -Condition $true `
        -Description 'Windows-Setup und OOBE-Credential wurden ausschliesslich ueber ein testlokales Antwort-ISO bereitgestellt'

    $started = & $module {
        param($Id, $Root)
        Start-HyperVWindowsImageBuildVM -BuildId $Id -StateRoot $Root
    } $buildId $stateRoot
    Assert-GeneralizeAcceptance -Condition (
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
    Assert-GeneralizeAcceptance -Condition ([bool]$ready.Ready) `
        -Description 'Realer Windows-Gast ist nach OOBE ueber PowerShell Direct erreichbar'

    @($vm | Get-VMDvdDrive -ErrorAction SilentlyContinue) | Remove-VMDvdDrive -ErrorAction Stop
    Remove-Item -LiteralPath $answerIsoPath -Force -ErrorAction Stop
    $answerIsoPath = $null
    Assert-GeneralizeAcceptance -Condition (-not @($vm | Get-VMDvdDrive -ErrorAction SilentlyContinue)) `
        -Description 'Testlokales Antwort-ISO mit Credential wurde vor Sysprep entfernt'

    $guestPreparation = @(& $module {
        param($VmName, $Id, $ScopeId, $Credential)
        Invoke-HyperVPowerShellDirect -VMName $VmName -ExpectedRunId $Id -ExpectedScopeId $ScopeId `
            -Credential $Credential -ScriptBlock {
                $ErrorActionPreference = 'Stop'
                Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend.xml" -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend\Unattend.xml" -Force -ErrorAction SilentlyContinue
                $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
                Remove-ItemProperty -LiteralPath $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
                Set-ItemProperty -LiteralPath $winlogon -Name AutoAdminLogon -Value '0' -ErrorAction SilentlyContinue
                [pscustomobject]@{
                    imageState = [string](Get-ItemPropertyValue `
                        -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState)
                    computerName = [string]$env:COMPUTERNAME
                }
            }
    } $builderVmName $buildId ([string]$build.scopeId) $credential)[-1]
    Assert-GeneralizeAcceptance -Condition (
        [string]$guestPreparation.imageState -eq 'IMAGE_STATE_COMPLETE' -and
        -not [string]::IsNullOrWhiteSpace([string]$guestPreparation.computerName)
    ) -Description 'Gast ist vor Sysprep vollstaendig installiert und sensible OOBE-Artefakte sind entfernt'

    $confirmed = & $module {
        param($Id, $Credential, $Root)
        Confirm-HyperVWindowsImageInstallation -BuildId $Id -Credential $Credential -StateRoot $Root
    } $buildId $credential $stateRoot
    Assert-GeneralizeAcceptance -Condition (
        [bool]$confirmed.installationEvidence.verified -and
        [string]$confirmed.installationEvidence.installationType -eq [string]$sourceArtifact.operatingSystem.installationType
    ) -Description 'Produktiver Installations-Receipt bindet Edition und Installationstyp an den echten Gast'

    $generalized = & $module {
        param($Id, $Credential, $Timeout, $Root)
        Invoke-HyperVWindowsImageGeneralization -BuildId $Id -Credential $Credential `
            -ShutdownTimeoutSeconds $Timeout -StateRoot $Root
    } $buildId $credential $TimeoutSeconds $stateRoot
    Assert-GeneralizeAcceptance -Condition (
        [string]$generalized.state -eq 'RESUME_PENDING' -and
        [string]$generalized.generalizationRequest.imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' -and
        [int]$generalized.generalizationRequest.sysprepExitCode -eq 0 -and
        [string]$generalized.generalizationEvidence.source -eq 'powershell-direct'
    ) -Description 'Sysprep-Generalize erreichte den vorgesehenen PowerShell-Direct-Receipt-Pfad'
    $generalizationEvidencePath = Join-Path $generalized.BuildDirectory `
        ([string]$generalized.generalizationEvidence.relativePath)
    Assert-GeneralizeAcceptance -Condition (
        (Test-Path -LiteralPath $generalizationEvidencePath -PathType Leaf) -and
        (Get-FileHash -LiteralPath $generalizationEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant() -eq `
            [string]$generalized.generalizationEvidence.storedSha256 -and
        (Get-VM -Name $builderVmName -ErrorAction Stop).State -eq 'Off'
    ) -Description 'Generalization-Evidence ist hashgebunden und der echte Gast ist ausgeschaltet'

    $published = & $module {
        param($Id, $Expiry, $Root)
        Publish-HyperVWindowsImageBuild -BuildId $Id -EvaluationExpiresAt $Expiry -StateRoot $Root
    } $buildId $evaluationExpiresAt $stateRoot
    Assert-GeneralizeAcceptance -Condition (
        [string]$published.Status -eq 'OS_SEALED' -and
        [string]$published.Artifact.artifactState -eq 'OS_SEALED' -and
        [bool]$published.Artifact.generalized -and
        (Get-Item -LiteralPath $published.Artifact.Path -Force).IsReadOnly
    ) -Description 'Produktiver Publish-Pfad erzeugte ein testlokales immutable OS_SEALED-Artifact'
    Assert-GeneralizeAcceptance -Condition (
        [string]$published.Cleanup.Status -eq 'CLEANUP_SUCCEEDED' -and
        -not (Get-VM -Name $builderVmName -ErrorAction SilentlyContinue) -and
        -not (Test-Path -LiteralPath $builderDiskPath -PathType Leaf)
    ) -Description 'Publish entfernte Builder-VM und buildlokale VHDX scopegebunden'
    Assert-GeneralizeAcceptance -Condition ((Get-Item -LiteralPath $sourceArtifact.Path -Force).IsReadOnly) `
        -Description 'Produktive Parent-VHDX blieb nach Generalize und Publish unveraendert schreibgeschuetzt'
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

    if ($buildId -and $stateRoot -and (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        try {
            $module = Get-Module SqlServerLab
            $currentBuild = & $module {
                param($Id, $Root)
                Get-HyperVImageBuildPlan -BuildId $Id -StateRoot $Root
            } $buildId $stateRoot
            $vmExists = $builderVmName -and (Get-VM -Name $builderVmName -ErrorAction SilentlyContinue)
            $diskExists = $builderDiskPath -and (Test-Path -LiteralPath $builderDiskPath -PathType Leaf)
            if ($currentBuild -and ($vmExists -or $diskExists)) {
                $cleanup = & $module {
                    param($Id, $Root)
                    Remove-HyperVWindowsImageBuild -BuildId $Id -StateRoot $Root
                } $buildId $stateRoot
                if ([string]$cleanup.Status -ne 'CLEANUP_SUCCEEDED') {
                    throw "GENERALIZE_ACCEPTANCE_CLEANUP_INCOMPLETE: $($cleanup.Status)"
                }
            }
        }
        catch {
            $cleanupFailed = $true
            $testFailed = $true
            Write-Host "Generalize-Cleanup-Fehler: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    $credential = $null
    if ($adminPassword) { $adminPassword.Dispose() }
    $env:SQL_SERVER_LAB_STATE = $previousStateRoot

    foreach ($sensitivePath in @($answerIsoPath,$answerDirectory)) {
        if ($sensitivePath -and (Test-Path -LiteralPath $sensitivePath)) {
            Remove-Item -LiteralPath $sensitivePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($stateRoot -and -not $cleanupFailed -and (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        $resolvedStateRoot = [IO.Path]::GetFullPath($stateRoot).TrimEnd('\')
        $resolvedParent = [IO.Path]::GetFullPath($ArtifactStateRoot).TrimEnd('\')
        $actualParent = [IO.Directory]::GetParent($resolvedStateRoot).FullName.TrimEnd('\')
        $leaf = [IO.Path]::GetFileName($resolvedStateRoot)
        if (-not $actualParent.Equals($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -or
            $leaf -notmatch '^acceptance-generalize-[a-f0-9]{32}$') {
            $testFailed = $true
            Write-Host 'Generalize-Cleanup-Fehler: temporaerer StateRoot liegt ausserhalb des erwarteten Scopes.' -ForegroundColor Red
        }
        else {
            Remove-Item -LiteralPath $resolvedStateRoot -Recurse -Force
        }
    }
}

if ($testFailed) { exit 1 }
Write-Host 'Reale Hyper-V-Windows-Generalize-Abnahme erfolgreich.' -ForegroundColor Green
exit 0
