<#
.SYNOPSIS
    Baut Windows-Server-2016+-Evaluationen unbeaufsichtigt als OS_SEALED.
#>

function New-HyperVWindowsSetupAnswerIso {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (-not ('SqlServerLabWindowsSetupImapiStreamCopy' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class SqlServerLabWindowsSetupImapiStreamCopy
{
    public static void ToFile(object source, string path)
    {
        IStream stream = (IStream)source;
        byte[] buffer = new byte[65536];
        IntPtr bytesRead = Marshal.AllocCoTaskMem(sizeof(int));
        try {
            using (FileStream file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None)) {
                while (true) {
                    Marshal.WriteInt32(bytesRead, 0);
                    stream.Read(buffer, buffer.Length, bytesRead);
                    int count = Marshal.ReadInt32(bytesRead);
                    if (count <= 0) break;
                    file.Write(buffer, 0, count);
                }
            }
        }
        finally { Marshal.FreeCoTaskMem(bytesRead); }
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
        [SqlServerLabWindowsSetupImapiStreamCopy]::ToFile($result.ImageStream, $DestinationPath)
    }
    finally {
        foreach ($comObject in @($result, $image)) {
            if ($comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject)
            }
        }
    }
    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf) -or
        (Get-Item -LiteralPath $DestinationPath -Force).Length -lt 32768) {
        throw 'HYPERV_WINDOWS_SETUP_ANSWER_ISO_INVALID'
    }
}

function Add-HyperVWindowsSetupPassToUnattend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OobeUnattend,
        [Parameter(Mandatory)][ValidateRange(1, 99)][int]$ImageIndex,
        [Parameter(Mandatory)][ValidateSet(1, 2)][int]$VmGeneration
    )

    $rootElement = '<unattend xmlns="urn:schemas-microsoft-com:unattend">'
    if (-not $OobeUnattend.Contains($rootElement)) {
        throw 'HYPERV_WINDOWS_SETUP_OOBE_UNATTEND_ROOT_MISSING'
    }
    $partitionXml = if ($VmGeneration -eq 1) {
@'
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Size>350</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Active>true</Active><Format>NTFS</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
'@
    }
    else {
@'
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>100</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
'@
    }
    $windowsPartition = if ($VmGeneration -eq 1) { 2 } else { 3 }
    $windowsPe = @"
$rootElement
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>0407:00000407</InputLocale><SystemLocale>de-DE</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>de-DE</UserLocale>
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <DiskConfiguration><Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
$partitionXml
      </Disk><WillShowUI>OnError</WillShowUI></DiskConfiguration>
      <ImageInstall><OSImage><InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>$ImageIndex</Value></MetaData></InstallFrom><InstallTo><DiskID>0</DiskID><PartitionID>$windowsPartition</PartitionID></InstallTo><WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>
      <UserData><AcceptEula>true</AcceptEula></UserData>
    </component>
  </settings>
"@
    return $OobeUnattend.Replace($rootElement, $windowsPe)
}

function Get-HyperVWindowsEvaluationVariantEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$OperatingSystemId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256
    )

    $evidencePath = Join-Path ([IO.Path]::GetFullPath($MediaRoot)) 'Evidence\windows-server-evaluation-media-validation.json'
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
        throw 'HYPERV_WINDOWS_TEMPLATE_INSTALL_IMAGE_EVIDENCE_REQUIRED'
    }
    $document = Get-Content -LiteralPath $evidencePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    if ([string]$document.Kind -ne 'windows-server-evaluation-media-validation') {
        throw 'HYPERV_WINDOWS_TEMPLATE_INSTALL_IMAGE_EVIDENCE_INVALID'
    }
    $result = @($document.Results | Where-Object {
        [string]$_.Status -eq 'VERIFIED' -and [string]$_.WindowsVersion -eq $Version -and
        [string]$_.Sha256 -eq $ExpectedSha256.ToLowerInvariant()
    })
    if ($result.Count -ne 1) { throw 'HYPERV_WINDOWS_TEMPLATE_INSTALL_IMAGE_EVIDENCE_MISMATCH' }
    $expectedEditionId = if ($Version -eq '2008R2') { 'ServerStandard' } else { 'ServerStandardEval' }
    $standardDesktop = @($result[0].Images | Where-Object {
        [string]$_.EditionId -eq $expectedEditionId -and
        [string]$_.Name -notmatch '(?i)Core' -and
        ([string]$_.Name -match '(?i)(Desktop Experience|Server with a GUI)' -or
            [string]$_.InstallationType -eq 'Server')
    })
    if ($standardDesktop.Count -ne 1) {
        throw "HYPERV_WINDOWS_TEMPLATE_STANDARD_DESKTOP_EVIDENCE_NOT_UNIQUE: $($standardDesktop.Count)"
    }
    return [pscustomobject]@{
        OperatingSystemId=$OperatingSystemId; WindowsEdition='standard-evaluation'
        InstallationType='desktop-experience'; ImageName=[string]$standardDesktop[0].Name
        ImageIndex=[int]$standardDesktop[0].Index; EvidencePath=$evidencePath
    }
}

function Resolve-HyperVWindowsEvaluationCatalogMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$Version
    )

    $matches = @(Get-LabMediaSourceCatalog -MediaRoot $MediaRoot | Where-Object {
        $_.Category -eq 'Windows Server' -and $_.Version -eq $Version -and
        $_.Edition -eq 'Evaluation' -and $_.MediaKind -eq 'ISO' -and
        $_.Architecture -eq 'x64' -and $_.Language -eq 'en-US'
    })
    if ($matches.Count -ne 1) {
        throw "HYPERV_WINDOWS_TEMPLATE_CATALOG_MEDIA_NOT_UNIQUE: $Version ($($matches.Count))"
    }
    $source = $matches[0]
    if (-not $source.Available -or [string]$source.IntegrityStatus -ne 'CATALOG_HASH_SIDECAR_MATCH' -or
        -not [string]$source.ExpectedSha256 -or -not (Test-Path -LiteralPath $source.TargetPath -PathType Leaf)) {
        throw "HYPERV_WINDOWS_TEMPLATE_CATALOG_MEDIA_NOT_READY: $($source.Id) ($($source.IntegrityStatus))"
    }
    return [pscustomobject]@{
        IsoPath=[string]$source.TargetPath
        MediaId=([string]$source.TargetRelativePath).Replace('\', '/')
        ExpectedSha256=([string]$source.ExpectedSha256).ToLowerInvariant()
        HashStatus='SIDECAR_READY'
        CatalogId=[string]$source.Id
        Language=[string]$source.Language
    }
}

function Invoke-HyperVWindowsEvaluationBuilderActivation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedScopeId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [string]$ExternalSwitchName
    )

    $managed = Get-HyperVManagedVM -VMName $VMName -ExpectedRunId $ExpectedRunId -ExpectedScopeId $ExpectedScopeId
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') { throw 'HYPERV_WINDOWS_TEMPLATE_ACTIVATION_VM_MUST_BE_RUNNING' }
    $adapterName='SQL_SERVER_LAB_ACTIVATION_TEMP'
    try {
        @(Get-VMNetworkAdapter -VMName $VMName -Name $adapterName -ErrorAction SilentlyContinue) |
            Remove-VMNetworkAdapter -ErrorAction Stop
    } catch { throw 'HYPERV_WINDOWS_TEMPLATE_ACTIVATION_STALE_NETWORK_CLEANUP_FAILED' }
    $externalSwitch=Resolve-HyperVWindowsActivationExternalSwitch -ExternalSwitchName $ExternalSwitchName
    $operationFailure=$null; $cleanupFailed=$false; $receipt=$null
    try {
        $activationAdapter=Add-VMNetworkAdapter -VMName $VMName -SwitchName ([string]$externalSwitch.Name) `
            -Name $adapterName -Passthru -ErrorAction Stop
        if (-not $activationAdapter -or -not [string]$activationAdapter.MacAddress) {
            $activationAdapter=@(Get-VMNetworkAdapter -VMName $VMName -Name $adapterName -ErrorAction Stop | Select-Object -First 1)[0]
        }
        $macAddress=([string]$activationAdapter.MacAddress -replace '[^0-9A-Fa-f]','').ToUpperInvariant()
        if (-not $macAddress) { throw 'HYPERV_WINDOWS_TEMPLATE_ACTIVATION_ADAPTER_IDENTITY_MISSING' }
        $receipt=@(Invoke-HyperVPowerShellDirect -VMName $VMName -ExpectedRunId $ExpectedRunId `
            -ExpectedScopeId $ExpectedScopeId -Credential $Credential -ArgumentList @($macAddress) -ScriptBlock {
                param($MacAddress)
                $ErrorActionPreference='Stop'
                $adapterDeadline=[datetime]::UtcNow.AddSeconds(30)
                do {
                    $adapter=@(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
                        ([string]$_.MacAddress -replace '[^0-9A-Fa-f]','').ToUpperInvariant() -eq $MacAddress
                    } | Select-Object -First 1)[0]
                    if (-not $adapter) { Start-Sleep -Seconds 1 }
                } while (-not $adapter -and [datetime]::UtcNow -lt $adapterDeadline)
                if (-not $adapter) { throw 'WINDOWS_ACTIVATION_GUEST_ADAPTER_NOT_FOUND' }
                Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction Stop
                $null=& ipconfig.exe /renew $adapter.Name
                $networkDeadline=[datetime]::UtcNow.AddSeconds(60)
                do {
                    $address=@(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*' })
                    $route=@(Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
                    if ($address.Count -and $route.Count) { break }
                    Start-Sleep -Seconds 2
                } while ([datetime]::UtcNow -lt $networkDeadline)
                if (-not $address.Count -or -not $route.Count) { throw 'WINDOWS_ACTIVATION_NETWORK_NOT_READY' }
                $product=$null; $activationCompleted=$false; $activationDeadline=[datetime]::UtcNow.AddMinutes(5)
                do {
                    try {
                        $product=@(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" -ErrorAction Stop |
                            Where-Object { $_.PartialProductKey -and -not [bool]$_.LicenseIsAddon } |
                            Sort-Object LicenseStatus,GracePeriodRemaining -Descending | Select-Object -First 1)[0]
                        if (-not $product) { throw 'WINDOWS_ACTIVATION_PRODUCT_NOT_FOUND' }
                        if ([int]$product.LicenseStatus -eq 1) { $activationCompleted=$true; break }
                        $activation=Invoke-CimMethod -InputObject $product -MethodName Activate -ErrorAction Stop
                        if ([int]$activation.ReturnValue -ne 0) { throw "WINDOWS_ACTIVATION_FAILED: $([int]$activation.ReturnValue)" }
                        $service=Get-CimInstance SoftwareLicensingService -ErrorAction Stop
                        $null=Invoke-CimMethod -InputObject $service -MethodName RefreshLicenseStatus -ErrorAction Stop
                        Start-Sleep -Seconds 3
                        $product=Get-CimInstance SoftwareLicensingProduct -Filter "ID='$($product.ID)'" -ErrorAction Stop
                        if ([int]$product.LicenseStatus -eq 1) { $activationCompleted=$true }
                    }
                    catch {
                        $activationErrorText=@(
                            [string]$_
                            [string]$_.Exception.Message
                            [string]$_.FullyQualifiedErrorId
                        ) -join ' '
                        if ($activationErrorText -notmatch '(?i)another activation attempt is in progress|another activation request is being processed') { throw }
                        Start-Sleep -Seconds 15
                    }
                } while (-not $activationCompleted -and [datetime]::UtcNow -lt $activationDeadline)
                if (-not $activationCompleted) { throw 'WINDOWS_ACTIVATION_CONCURRENT_ATTEMPT_TIMEOUT' }
                $observed=[datetime]::UtcNow
                [pscustomobject]@{
                    licenseStatus=[int]$product.LicenseStatus; graceMinutes=[int]$product.GracePeriodRemaining
                    evaluationExpiresAt=if([int]$product.GracePeriodRemaining -gt 0){$observed.AddMinutes([int]$product.GracePeriodRemaining).ToString('o')}else{$null}
                }
            })[-1]
    }
    catch { $operationFailure=$_ }
    finally {
        try {
            @(Get-VMNetworkAdapter -VMName $VMName -Name $adapterName -ErrorAction SilentlyContinue) |
                Remove-VMNetworkAdapter -ErrorAction Stop
        } catch { $cleanupFailed=$true }
    }
    if ($cleanupFailed) { throw 'HYPERV_WINDOWS_TEMPLATE_ACTIVATION_NETWORK_CLEANUP_FAILED' }
    if ($operationFailure) { throw $operationFailure }
    if (-not $receipt -or [int]$receipt.licenseStatus -ne 1 -or [int]$receipt.graceMinutes -lt 43200 -or -not $receipt.evaluationExpiresAt) {
        throw 'HYPERV_WINDOWS_TEMPLATE_ACTIVATION_VERIFICATION_FAILED'
    }
    return $receipt
}

function Invoke-HyperVWindowsEvaluationTemplateBuild {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('2016', '2019', '2022', '2025')]
        [string]$Version,
        [string]$MediaRoot,
        [string]$StateRoot,
        [ValidateRange(300, 3600)][int]$TimeoutSeconds = 1800,
        [ValidateRange(40, 256)][int]$OsDiskSizeGB = 80,
        [ValidateRange(2048, 32768)][int]$MemoryStartupMB = 4096,
        [ValidateRange(1, 16)][int]$ProcessorCount = 2,
        [string]$ExternalSwitchName,
        [switch]$KeepOnFailure
    )

    if (-not $IsWindows) { throw 'HYPERV_WINDOWS_TEMPLATE_WINDOWS_ONLY' }
    if (-not $MediaRoot) { $MediaRoot = Get-LabMediaRootDefault }
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $osId = "windows-server-$Version"
    $media = Resolve-HyperVWindowsEvaluationCatalogMedia -MediaRoot $MediaRoot -Version $Version
    if ([string]$media.HashStatus -ne 'SIDECAR_READY' -or -not $media.ExpectedSha256) {
        throw 'HYPERV_WINDOWS_TEMPLATE_MEDIA_HASH_SIDECAR_REQUIRED'
    }
    $variant = @()
    try {
        $variant = @(Get-HyperVWindowsInstallationMediaInfo -IsoPath $media.IsoPath | Where-Object {
            $_.OperatingSystemId -eq $osId -and $_.WindowsEdition -eq 'standard-evaluation' -and
            $_.InstallationType -eq 'desktop-experience'
        })
    }
    catch {
        if ($_.Exception.Message -notmatch '(?i)(erh.\s*hte Rechte|required privilege|access (is )?denied|zugriff verweigert)') { throw }
    }
    if ($variant.Count -ne 1) {
        $variant = @(Get-HyperVWindowsEvaluationVariantEvidence -MediaRoot $MediaRoot -Version $Version `
            -OperatingSystemId $osId -ExpectedSha256 $media.ExpectedSha256)
    }
    if ($variant.Count -ne 1) { throw "HYPERV_WINDOWS_TEMPLATE_VARIANT_NOT_UNIQUE: $($variant.Count)" }
    if (-not $PSCmdlet.ShouldProcess("Windows Server $Version", 'unbeaufsichtigt installieren, generalisieren und als OS_SEALED veröffentlichen')) {
        return [pscustomobject]@{ Status='PLANNED'; Version=$Version; IsoPath=$media.IsoPath; ImageIndex=$variant[0].ImageIndex }
    }

    $build = $null; $builderVmName = $null; $answerDirectory = $null; $answerIsoPath = $null
    $adminPassword = $null; $credential = $null; $published = $null; $validationLab = $null
    try {
        $build = New-HyperVWindowsImageBuildPlan -IsoPath $media.IsoPath `
            -ExpectedSha256 $media.ExpectedSha256 -OperatingSystemId $osId `
            -Edition standard-evaluation -InstallationType desktop-experience `
            -Language en-US -LicenseType evaluation -InitialMediaKey space `
            -OsDiskSizeBytes ([long]$OsDiskSizeGB * 1GB) -StateRoot $StateRoot
        $null = New-HyperVWindowsImageBuilder -BuildId $build.buildId `
            -MemoryStartupBytes ([long]$MemoryStartupMB * 1MB) `
            -ProcessorCount $ProcessorCount -StateRoot $StateRoot
        $build = Set-HyperVImageBuildManualAction -BuildId $build.buildId -StateRoot $StateRoot
        $builderVmName = [string]$build.builder.vmName
        $vm = Get-VM -Name $builderVmName -ErrorAction Stop

        $adminPassword = New-HyperVSqlUnattendedPassword
        $credential = [PSCredential]::new('Administrator', $adminPassword)
        $answerDirectory = Join-Path $build.BuildDirectory 'unattended-answer'
        $answerIsoPath = Join-Path $build.BuildDirectory 'unattended-answer.iso'
        New-Item -Path $answerDirectory -ItemType Directory -ErrorAction Stop | Out-Null
        $unattend = $null
        try {
            $unattend = New-HyperVSqlOobeUnattendXml -AdministratorPassword $adminPassword -Identity $build.buildId
            $unattend = Add-HyperVWindowsSetupPassToUnattend -OobeUnattend $unattend `
                -ImageIndex ([int]$variant[0].ImageIndex) -VmGeneration ([int]$build.platform.vmGeneration)
            [void][xml]$unattend
            foreach ($name in @('Autounattend.xml', 'Unattend.xml')) {
                [IO.File]::WriteAllText((Join-Path $answerDirectory $name), $unattend, [Text.UTF8Encoding]::new($false))
            }
            New-HyperVWindowsSetupAnswerIso -SourceDirectory $answerDirectory -DestinationPath $answerIsoPath
        }
        finally { $unattend = $null }
        Remove-Item -LiteralPath $answerDirectory -Recurse -Force -ErrorAction Stop
        $answerDirectory = $null
        Add-VMDvdDrive -VM $vm -Path $answerIsoPath -ErrorAction Stop | Out-Null

        $null = Start-HyperVWindowsImageBuildVM -BuildId $build.buildId -StateRoot $StateRoot
        $ready = Wait-HyperVPowerShellDirect -VMName $builderVmName -ExpectedRunId $build.buildId `
            -ExpectedScopeId $build.scopeId -Credential $credential -TimeoutSeconds $TimeoutSeconds
        if (-not $ready.Ready) { throw 'HYPERV_WINDOWS_TEMPLATE_GUEST_NOT_READY' }

        @($vm | Get-VMDvdDrive -ErrorAction Stop) | Remove-VMDvdDrive -ErrorAction Stop
        Remove-Item -LiteralPath $answerIsoPath -Force -ErrorAction Stop
        $answerIsoPath = $null
        $guest = @(Invoke-HyperVPowerShellDirect -VMName $builderVmName `
            -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId -Credential $credential -ScriptBlock {
                $ErrorActionPreference='Stop'
                Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend.xml" -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend\Unattend.xml" -Force -ErrorAction SilentlyContinue
                $winlogon='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
                Remove-ItemProperty -LiteralPath $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
                Set-ItemProperty -LiteralPath $winlogon -Name AutoAdminLogon -Value '0' -ErrorAction SilentlyContinue
                [pscustomobject]@{
                    imageState=[string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState)
                    editionId=[string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID)
                }
            })[-1]
        if ($guest.imageState -ne 'IMAGE_STATE_COMPLETE') { throw "HYPERV_WINDOWS_TEMPLATE_IMAGE_STATE_INVALID: $($guest.imageState)" }
        if ([string]$guest.editionId -notmatch '^ServerStandardEval') {
            throw "HYPERV_WINDOWS_TEMPLATE_EDITION_INVALID: $($guest.editionId)"
        }
        $activation = Invoke-HyperVWindowsEvaluationBuilderActivation -VMName $builderVmName `
            -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId -Credential $credential `
            -ExternalSwitchName $ExternalSwitchName
        $guest | Add-Member -NotePropertyName licenseStatus -NotePropertyValue ([int]$activation.licenseStatus)
        $guest | Add-Member -NotePropertyName graceMinutes -NotePropertyValue ([int]$activation.graceMinutes)
        $guest | Add-Member -NotePropertyName evaluationExpiresAt -NotePropertyValue ([string]$activation.evaluationExpiresAt)
        if ($guest.licenseStatus -ne 1 -or $guest.graceMinutes -lt 43200 -or -not $guest.evaluationExpiresAt) {
            throw "HYPERV_WINDOWS_TEMPLATE_EVALUATION_NOT_ACTIVE: LicenseStatus=$($guest.licenseStatus); GraceMinutes=$($guest.graceMinutes)"
        }

        $null = Confirm-HyperVWindowsImageInstallation -BuildId $build.buildId -Credential $credential -StateRoot $StateRoot
        $null = Invoke-HyperVWindowsImageGeneralization -BuildId $build.buildId -Credential $credential `
            -ShutdownTimeoutSeconds ([Math]::Min(1800, $TimeoutSeconds)) -StateRoot $StateRoot
        $published = Publish-HyperVWindowsImageBuild -BuildId $build.buildId `
            -EvaluationExpiresAt ([datetime]$guest.evaluationExpiresAt) `
            -RequireChildBootValidation -StateRoot $StateRoot
        $childPassword = New-HyperVSqlUnattendedPassword
        $childCredential = [PSCredential]::new('Administrator', $childPassword)
        $childAnswerDirectory=$null; $childAnswerIsoPath=$null
        try {
            $validationLab = New-HyperVLabEnvironment -ArtifactId $published.Artifact.artifactId `
                -LabName "template-validation-$Version" -InstanceId "windows-$Version-validation" `
                -MemoryStartupMB $MemoryStartupMB -ProcessorCount $ProcessorCount -Isolated `
                -TemplateValidationRun -StateRoot $StateRoot
            $child = Get-HyperVLabWorkflowRun -RunId $validationLab.RunId -StateRoot $StateRoot
            $childAnswerDirectory=Join-Path $child.RunDirectory 'template-validation-answer'
            $childAnswerIsoPath=Join-Path $child.RunDirectory 'template-validation-answer.iso'
            New-Item -Path $childAnswerDirectory -ItemType Directory -ErrorAction Stop | Out-Null
            $childUnattend=$null
            try {
                $childUnattend=New-HyperVSqlOobeUnattendXml -AdministratorPassword $childPassword `
                    -Identity $child.Run.runId
                foreach($name in @('Autounattend.xml','Unattend.xml')) {
                    [IO.File]::WriteAllText((Join-Path $childAnswerDirectory $name),$childUnattend,[Text.UTF8Encoding]::new($false))
                }
                New-HyperVWindowsSetupAnswerIso -SourceDirectory $childAnswerDirectory -DestinationPath $childAnswerIsoPath
            } finally { $childUnattend=$null }
            Remove-Item -LiteralPath $childAnswerDirectory -Recurse -Force -ErrorAction Stop
            $childAnswerDirectory=$null
            $childVm=Get-VM -Name $child.Instance.vmName -ErrorAction Stop
            Add-VMDvdDrive -VM $childVm -Path $childAnswerIsoPath -ErrorAction Stop | Out-Null
            $null=Start-HyperVInstance -VMName $child.Instance.vmName `
                -ExpectedRunId $child.Run.runId -ExpectedScopeId $child.Run.scopeId
            $initialChildReady=Wait-HyperVPowerShellDirect -VMName $child.Instance.vmName `
                -ExpectedRunId $child.Run.runId -ExpectedScopeId $child.Run.scopeId `
                -Credential $childCredential -TimeoutSeconds $TimeoutSeconds
            if (-not $initialChildReady.Ready) { throw 'HYPERV_WINDOWS_TEMPLATE_CHILD_OOBE_FAILED' }
            @($childVm | Get-VMDvdDrive -ErrorAction Stop | Where-Object Path -eq $childAnswerIsoPath) |
                Remove-VMDvdDrive -ErrorAction Stop
            Remove-Item -LiteralPath $childAnswerIsoPath -Force -ErrorAction Stop
            $childAnswerIsoPath=$null
            $null=Invoke-HyperVPowerShellDirect -VMName $child.Instance.vmName `
                -ExpectedRunId $child.Run.runId -ExpectedScopeId $child.Run.scopeId `
                -Credential $childCredential -ScriptBlock {
                    Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend.xml" -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend\Unattend.xml" -Force -ErrorAction SilentlyContinue
                    $winlogon='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
                    Remove-ItemProperty -LiteralPath $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
                    Set-ItemProperty -LiteralPath $winlogon -Name AutoAdminLogon -Value '0' -ErrorAction SilentlyContinue
                }
            $null = Stop-HyperVInstance -VMName $child.Instance.vmName `
                -ExpectedRunId $child.Run.runId -ExpectedScopeId $child.Run.scopeId
            $null = Start-HyperVInstance -VMName $child.Instance.vmName `
                -ExpectedRunId $child.Run.runId -ExpectedScopeId $child.Run.scopeId
            $readyAfterColdStart = Wait-HyperVPowerShellDirect -VMName $child.Instance.vmName `
                -ExpectedRunId $child.Run.runId -ExpectedScopeId $child.Run.scopeId `
                -Credential $childCredential -TimeoutSeconds $TimeoutSeconds
            if (-not $readyAfterColdStart.Ready) { throw 'HYPERV_WINDOWS_TEMPLATE_CHILD_COLD_START_FAILED' }
            $childReceipt = @(Invoke-HyperVPowerShellDirect -VMName $child.Instance.vmName `
                -ExpectedRunId $child.Run.runId -ExpectedScopeId $child.Run.scopeId `
                -Credential $childCredential -ScriptBlock {
                    $version=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
                    [pscustomobject]@{
                        productName=[string]$version.ProductName
                        editionId=[string]$version.EditionID
                        imageState=[string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState)
                        sqlInstalled=Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
                    }
                })[-1]
            if ($childReceipt.imageState -ne 'IMAGE_STATE_COMPLETE' -or
                $childReceipt.productName -notmatch [regex]::Escape($Version) -or
                $childReceipt.editionId -notmatch '^ServerStandardEval' -or
                $childReceipt.sqlInstalled) {
                throw "HYPERV_WINDOWS_TEMPLATE_CHILD_POSTCONDITION_FAILED: $($childReceipt | ConvertTo-Json -Compress)"
            }
        }
        catch {
            $childFailure = $_
            try {
                $null = Set-HyperVImageArtifactChildValidation -ArtifactId $published.Artifact.artifactId `
                    -State FAILED -StateRoot $StateRoot
            } catch { }
            try {
                if ($validationLab) {
                    $null = Remove-SqlServerLab -RunId $validationLab.RunId -StateRoot $StateRoot -Force -Confirm:$false
                    $validationLab = $null
                }
                $null = Remove-HyperVImageArtifact -ArtifactId $published.Artifact.artifactId `
                    -StateRoot $StateRoot -Confirm:$false
                $published = $null
            } catch { }
            throw $childFailure
        }
        finally {
            $childCredential = $null; $childPassword = $null
            if($childAnswerIsoPath) {
                try {
                    $childVm=Get-VM -Name $child.Instance.vmName -ErrorAction SilentlyContinue
                    if($childVm) {
                        @($childVm | Get-VMDvdDrive -ErrorAction SilentlyContinue | Where-Object Path -eq $childAnswerIsoPath) |
                            Remove-VMDvdDrive -ErrorAction SilentlyContinue
                    }
                } catch { }
                Remove-Item -LiteralPath $childAnswerIsoPath -Force -ErrorAction SilentlyContinue
            }
            if($childAnswerDirectory) { Remove-Item -LiteralPath $childAnswerDirectory -Recurse -Force -ErrorAction SilentlyContinue }
            if ($validationLab) {
                $cleanup = Remove-SqlServerLab -RunId $validationLab.RunId -StateRoot $StateRoot -Force -Confirm:$false
                if ($cleanup.Status -ne 'REMOVED') { throw "HYPERV_WINDOWS_TEMPLATE_CHILD_CLEANUP_FAILED: $($cleanup.Status)" }
                $validationLab = $null
            }
        }
        $validationEvidenceRoot = Join-Path $StateRoot 'evidence/hyperv-windows-templates'
        New-Item -Path $validationEvidenceRoot -ItemType Directory -Force | Out-Null
        $validationEvidencePath = Join-Path $validationEvidenceRoot ("$($published.Artifact.artifactId).json")
        Write-LabArtifactJsonAtomic -Path $validationEvidencePath -InputObject ([pscustomobject]@{
            contractVersion='SqlServerLab.HyperVWindowsTemplateValidation/1.0'
            status='CHILD_BOOT_VERIFIED'; artifactId=[string]$published.Artifact.artifactId
            operatingSystemId=$osId; imageIndex=[int]$variant[0].ImageIndex
            vmGeneration=[int]$published.Artifact.platform.vmGeneration
            secureBoot=[bool]$published.Artifact.platform.secureBoot
            evaluationExpiresAt=[string]$published.Artifact.license.evaluationExpiresAt
            checks=[pscustomobject]@{
                mediaHash=$true; installImage=$true; installation=$true; generalization=$true
                childOobe=$true; childColdStart=$true; noSqlInstance=$true; cleanup=$true
            }
            observedAt=[datetime]::UtcNow.ToString('o')
        })
        $evidenceSha256 = (Get-FileHash -LiteralPath $validationEvidencePath -Algorithm SHA256).Hash
        $published.Artifact = Set-HyperVImageArtifactChildValidation `
            -ArtifactId $published.Artifact.artifactId -State CHILD_BOOT_VERIFIED `
            -EvidenceSha256 $evidenceSha256 -StateRoot $StateRoot
        return [pscustomobject]@{
            Status='CHILD_BOOT_VERIFIED'; Version=$Version; ImageIndex=[int]$variant[0].ImageIndex
            ArtifactId=[string]$published.Artifact.artifactId
            VmGeneration=[int]$published.Artifact.platform.vmGeneration
            SecureBoot=[bool]$published.Artifact.platform.secureBoot
            EvaluationExpiresAt=[string]$published.Artifact.license.evaluationExpiresAt
            CredentialDisclosed=$false; TemporaryAnswerMediaRemoved=$true
            ChildValidationCleanup='REMOVED'
            ValidationEvidencePath=$validationEvidencePath
        }
    }
    catch {
        $templateFailure = $_
        if ($published -and $published.Artifact -and
            [string]$published.Artifact.validation.state -ne 'CHILD_BOOT_VERIFIED') {
            try {
                $null = Set-HyperVImageArtifactChildValidation -ArtifactId $published.Artifact.artifactId `
                    -State FAILED -StateRoot $StateRoot
            } catch { }
        }
        if ($build -and -not $KeepOnFailure) {
            try { $null = Remove-HyperVWindowsImageBuild -BuildId $build.buildId -StateRoot $StateRoot } catch { }
        }
        if ($published -and $published.Artifact -and -not $KeepOnFailure -and
            [string]$published.Artifact.validation.state -ne 'CHILD_BOOT_VERIFIED') {
            try {
                $null = Remove-HyperVImageArtifact -ArtifactId $published.Artifact.artifactId `
                    -StateRoot $StateRoot -Confirm:$false
                $published = $null
            } catch { }
        }
        throw $templateFailure
    }
    finally {
        $credential = $null; $adminPassword = $null
        if ($builderVmName -and $answerIsoPath) {
            try {
                $vm = Get-VM -Name $builderVmName -ErrorAction SilentlyContinue
                if ($vm) {
                    @($vm | Get-VMDvdDrive -ErrorAction SilentlyContinue | Where-Object Path -eq $answerIsoPath) |
                        Remove-VMDvdDrive -ErrorAction SilentlyContinue
                }
            } catch { }
            Remove-Item -LiteralPath $answerIsoPath -Force -ErrorAction SilentlyContinue
        }
        if ($answerDirectory) { Remove-Item -LiteralPath $answerDirectory -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
