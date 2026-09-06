<#
.SYNOPSIS
    Baut Windows-Server-2008-R2/2012-R2-Evaluationen über Legacy-WMI.
#>

function New-HyperVLegacyWindowsOobeUnattendXml {
    [CmdletBinding()]
    param([Parameter(Mandatory)][SecureString]$AdministratorPassword)

    $pointer=[IntPtr]::Zero; $plain=$null
    try {
        $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdministratorPassword)
        $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        $escaped=[Security.SecurityElement]::Escape($plain)
        return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>netsh.exe advfirewall firewall set rule group="Windows Management Instrumentation (WMI)" new enable=yes</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>netsh.exe advfirewall firewall set rule group="Remote Service Management" new enable=yes</Path></RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>0407:00000407</InputLocale><SystemLocale>de-DE</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>de-DE</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <UserAccounts><AdministratorPassword><Value>$escaped</Value><PlainText>true</PlainText></AdministratorPassword></UserAccounts>
      <AutoLogon><Password><Value>$escaped</Value><PlainText>true</PlainText></Password><Enabled>true</Enabled><LogonCount>1</LogonCount><Username>Administrator</Username></AutoLogon>
      <RegisteredOwner>SQL_Server_Lab</RegisteredOwner><TimeZone>W. Europe Standard Time</TimeZone>
      <OOBE><HideEULAPage>true</HideEULAPage><NetworkLocation>Work</NetworkLocation><ProtectYourPC>3</ProtectYourPC></OOBE>
    </component>
  </settings>
</unattend>
"@
    }
    finally {
        $plain=$null
        if($pointer -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
    }
}

function Connect-HyperVLegacyWindowsWmiScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][PSCredential]$Credential
    )
    Add-Type -AssemblyName System.Management -ErrorAction Stop
    $pointer=[IntPtr]::Zero; $plain=$null
    try {
        $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
        $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        $options=[Management.ConnectionOptions]::new()
        $options.Username=[string]$Credential.UserName; $options.Password=$plain
        $options.Impersonation=[Management.ImpersonationLevel]::Impersonate
        $options.Authentication=[Management.AuthenticationLevel]::PacketPrivacy
        $options.EnablePrivileges=$true; $options.Timeout=[timespan]::FromSeconds(15)
        $scope=[Management.ManagementScope]::new("\\$Address\$Namespace",$options)
        $scope.Connect()
        return $scope
    }
    finally {
        $plain=$null
        if($pointer -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
    }
}

function Get-HyperVLegacyWindowsGuestIPv4 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$AdapterName
    )
    $adapter=Get-VMNetworkAdapter -VMName $VMName -Name $AdapterName -ErrorAction SilentlyContinue
    $addresses=@($adapter.IPAddresses | Where-Object {
        $_ -match '^\d{1,3}(?:\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' -and $_ -notlike '127.*'
    })
    if($addresses.Count -gt 0){return @($addresses|Sort-Object -Unique)}

    $vm=Get-VM -Name $VMName -ErrorAction Stop
    $component=Get-CimInstance -Namespace 'root/virtualization/v2' -ClassName Msvm_KvpExchangeComponent `
        -Filter "SystemName='$([string]$vm.Id)'" -ErrorAction SilentlyContinue
    foreach($item in @($component.GuestIntrinsicExchangeItems)){
        try {
            [xml]$document=$item
            $properties=@{}
            foreach($property in @($document.INSTANCE.PROPERTY)){
                $properties[[string]$property.NAME]=[string]$property.VALUE
            }
            if([string]$properties.Name -eq 'NetworkAddressIPv4'){
                $addresses+=@([string]$properties.Data -split ';' | Where-Object {
                    $_ -match '^\d{1,3}(?:\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' -and $_ -notlike '127.*'
                })
            }
        } catch { }
    }
    return @($addresses|Sort-Object -Unique)
}

function Wait-HyperVLegacyWindowsWmi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$AdapterName,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [ValidateRange(60,3600)][int]$TimeoutSeconds=1800
    )
    $deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds); $lastError=$null
    do {
        $addresses=@(Get-HyperVLegacyWindowsGuestIPv4 -VMName $VMName -AdapterName $AdapterName)
        foreach($address in $addresses){
            try {
                $scope=Connect-HyperVLegacyWindowsWmiScope -Address $address -Namespace 'root\cimv2' -Credential $Credential
                return [pscustomobject]@{Ready=$true;Address=$address;Scope=$scope}
            } catch { $lastError=[string]$_ }
        }
        Start-Sleep -Seconds 3
    } while([datetime]::UtcNow -lt $deadline)
    return [pscustomobject]@{Ready=$false;Address=$null;Scope=$null;LastError=$lastError}
}

function Get-HyperVLegacyWindowsRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Management.ManagementScope]$Scope,
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('String','DWORD')][string]$Type='String'
    )
    $registry=[Management.ManagementClass]::new($Scope,[Management.ManagementPath]::new('StdRegProv'),$null)
    $method=if($Type -eq 'DWORD'){'GetDWORDValue'}else{'GetStringValue'}
    $input=$registry.GetMethodParameters($method); $input['hDefKey']=[uint32]2147483650
    $input['sSubKeyName']=$SubKey; $input['sValueName']=$Name
    $output=$registry.InvokeMethod($method,$input,$null)
    if([uint32]$output['ReturnValue'] -ne 0){return $null}
    return $(if($Type -eq 'DWORD'){[uint32]$output['uValue']}else{[string]$output['sValue']})
}

function Set-HyperVLegacyWindowsRegistryDWORD {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Management.ManagementScope]$Scope,
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][uint32]$Value
    )
    $registry=[Management.ManagementClass]::new($Scope,[Management.ManagementPath]::new('StdRegProv'),$null)
    $create=$registry.GetMethodParameters('CreateKey');$create['hDefKey']=[uint32]2147483650;$create['sSubKeyName']=$SubKey
    if([uint32]$registry.InvokeMethod('CreateKey',$create,$null)['ReturnValue'] -ne 0){throw 'HYPERV_LEGACY_REGISTRY_CREATE_FAILED'}
    $input=$registry.GetMethodParameters('SetDWORDValue');$input['hDefKey']=[uint32]2147483650
    $input['sSubKeyName']=$SubKey;$input['sValueName']=$Name;$input['uValue']=$Value
    if([uint32]$registry.InvokeMethod('SetDWORDValue',$input,$null)['ReturnValue'] -ne 0){throw 'HYPERV_LEGACY_REGISTRY_SET_FAILED'}
}

function Invoke-HyperVLegacyWindowsProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Management.ManagementScope]$Scope,
        [Parameter(Mandatory)][string]$CommandLine
    )
    $process=[Management.ManagementClass]::new($Scope,[Management.ManagementPath]::new('Win32_Process'),$null)
    $input=$process.GetMethodParameters('Create');$input['CommandLine']=$CommandLine
    $output=$process.InvokeMethod('Create',$input,$null)
    if([uint32]$output['ReturnValue'] -ne 0){throw "HYPERV_LEGACY_PROCESS_CREATE_FAILED: $($output['ReturnValue'])"}
    return [uint32]$output['ProcessId']
}

function Get-HyperVLegacyWindowsGuestReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Management.ManagementScope]$Scope)
    $current='SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $state='SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'
    $sql='SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    $registry=[Management.ManagementClass]::new($Scope,[Management.ManagementPath]::new('StdRegProv'),$null)
    $enum=$registry.GetMethodParameters('EnumValues');$enum['hDefKey']=[uint32]2147483650;$enum['sSubKeyName']=$sql
    $sqlResult=$registry.InvokeMethod('EnumValues',$enum,$null)
    return [pscustomobject]@{
        productName=Get-HyperVLegacyWindowsRegistryValue -Scope $Scope -SubKey $current -Name ProductName
        editionId=Get-HyperVLegacyWindowsRegistryValue -Scope $Scope -SubKey $current -Name EditionID
        currentBuild=Get-HyperVLegacyWindowsRegistryValue -Scope $Scope -SubKey $current -Name CurrentBuildNumber
        imageState=Get-HyperVLegacyWindowsRegistryValue -Scope $Scope -SubKey $state -Name ImageState
        sqlInstalled=([uint32]$sqlResult['ReturnValue'] -eq 0 -and @($sqlResult['sNames']).Count -gt 0)
    }
}

function Wait-HyperVLegacyWindowsGuestComplete {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Management.ManagementScope]$Scope,
        [ValidateRange(30,600)][int]$TimeoutSeconds=300
    )
    $deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds);$receipt=$null
    do {
        $receipt=Get-HyperVLegacyWindowsGuestReceipt -Scope $Scope
        if($receipt.imageState -eq 'IMAGE_STATE_COMPLETE'){return $receipt}
        Start-Sleep -Seconds 3
    } while([datetime]::UtcNow -lt $deadline)
    return $receipt
}

function Get-HyperVLegacyWindowsEvaluationLicenseReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Management.ManagementScope]$Scope)
    $query=[Management.ObjectQuery]::new("SELECT * FROM SoftwareLicensingProduct WHERE ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'")
    $items=@([Management.ManagementObjectSearcher]::new($Scope,$query).Get() | Where-Object {
        $_['PartialProductKey'] -and -not [bool]$_['LicenseIsAddon']
    } | Sort-Object @{Expression={[int]$_['LicenseStatus']};Descending=$true},@{Expression={[int]$_['GracePeriodRemaining']};Descending=$true})
    $product=@($items|Select-Object -First 1)[0]
    if(-not $product){throw 'HYPERV_LEGACY_ACTIVATION_PRODUCT_NOT_FOUND'}
    $observed=[datetime]::UtcNow
    return [pscustomobject]@{
        licenseStatus=[int]$product['LicenseStatus'];graceMinutes=[int]$product['GracePeriodRemaining']
        evaluationExpiresAt=if([int]$product['GracePeriodRemaining'] -gt 0){
            $observed.AddMinutes([int]$product['GracePeriodRemaining']).ToString('o')
        }else{$null}
        observedAt=$observed.ToString('o')
    }
}

function Invoke-HyperVLegacyWindowsEvaluationActivation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Management.ManagementScope]$Scope,
        [switch]$AllowActivationGrace
    )
    $deadline=[datetime]::UtcNow.AddMinutes(5);$receipt=$null;$activationAttempted=$false
    do {
        try {
            $receipt=Get-HyperVLegacyWindowsEvaluationLicenseReceipt -Scope $Scope
            if([int]$receipt.licenseStatus -eq 1){break}
            if($AllowActivationGrace -and $activationAttempted -and [int]$receipt.licenseStatus -eq 2){break}
            $null=Invoke-HyperVLegacyWindowsProcess -Scope $Scope -CommandLine `
                'cmd.exe /c cscript.exe //B "%WINDIR%\System32\slmgr.vbs" /ato'
            $activationAttempted=$true
            Start-Sleep -Seconds 15
        }
        catch {
            $text=@([string]$_,[string]$_.Exception.Message,[string]$_.FullyQualifiedErrorId)-join ' '
            if($text -notmatch '(?i)another activation attempt is in progress|another activation request is being processed'){throw}
            Start-Sleep -Seconds 15
        }
    } while([datetime]::UtcNow -lt $deadline)
    $receipt=Get-HyperVLegacyWindowsEvaluationLicenseReceipt -Scope $Scope
    $activated=[int]$receipt.licenseStatus -eq 1 -and [int]$receipt.graceMinutes -ge 43200
    $activationGrace=$AllowActivationGrace -and [int]$receipt.licenseStatus -eq 2 -and [int]$receipt.graceMinutes -ge 1440
    if(-not $activated -and -not $activationGrace){
        throw "HYPERV_LEGACY_EVALUATION_NOT_ACTIVE: LicenseStatus=$([int]$receipt.licenseStatus); GraceMinutes=$([int]$receipt.graceMinutes)"
    }
    $receipt|Add-Member -NotePropertyName activated -NotePropertyValue $activated -Force
    $receipt|Add-Member -NotePropertyName state -NotePropertyValue $(if($activated){'ACTIVATED'}else{'OOB_GRACE'}) -Force
    return $receipt
}

function Remove-HyperVLegacyWindowsGuestSecretTraces {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Management.ManagementScope]$Scope)
    $command='cmd.exe /c del /f /q "%WINDIR%\Panther\Unattend.xml" 2>nul & del /f /q "%WINDIR%\Panther\Unattend\Unattend.xml" 2>nul & reg.exe delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /f 2>nul & reg.exe add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f'
    $null=Invoke-HyperVLegacyWindowsProcess -Scope $Scope -CommandLine $command
    Start-Sleep -Seconds 3
}

function Invoke-HyperVLegacyWindowsSysprep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Management.ManagementScope]$Scope,
        [Parameter(Mandatory)][string]$VMName,
        [ValidateRange(120,1800)][int]$TimeoutSeconds=900
    )
    $processId=Invoke-HyperVLegacyWindowsProcess -Scope $Scope -CommandLine `
        'C:\Windows\System32\Sysprep\Sysprep.exe /generalize /oobe /quit /quiet'
    $deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds);$imageState=$null
    do {
        try {
            $imageState=Get-HyperVLegacyWindowsRegistryValue -Scope $Scope `
                -SubKey 'SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState
        } catch { }
        if($imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'){break}
        Start-Sleep -Seconds 2
    } while([datetime]::UtcNow -lt $deadline)
    if($imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'){
        throw "HYPERV_LEGACY_SYSPREP_FAILED: ProcessId=$processId; ImageState=$imageState"
    }
    $shutdownCommand='cmd.exe /c netsh.exe advfirewall firewall set rule group="Windows Management Instrumentation (WMI)" new enable=no & netsh.exe advfirewall firewall set rule group="Remote Service Management" new enable=no & reg.exe delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v LocalAccountTokenFilterPolicy /f & shutdown.exe /s /t 5 /f'
    $null=Invoke-HyperVLegacyWindowsProcess -Scope $Scope -CommandLine $shutdownCommand
    do {
        Start-Sleep -Seconds 2
        $vm=Get-VM -Name $VMName -ErrorAction Stop
    } while([string]$vm.State -ne 'Off' -and [datetime]::UtcNow -lt $deadline)
    if([string]$vm.State -ne 'Off'){
        throw "HYPERV_LEGACY_SYSPREP_SHUTDOWN_FAILED: $($vm.State)"
    }
    return [pscustomobject]@{ProcessId=$processId;ImageState=$imageState;ShutdownObserved=$true}
}

function Submit-HyperVLegacyWindowsGeneralizationEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Build,[string]$StateRoot)
    $evidencePath=Join-Path $Build.BuildDirectory 'legacy-wmi-generalization-submission.json'
    Write-LabArtifactJsonAtomic -Path $evidencePath -InputObject ([pscustomobject]@{
        contractVersion='1';buildId=[string]$Build.buildId;scopeId=[string]$Build.scopeId
        challenge=[string]$Build.manualAction.challenge;kind='windows-sysprep-generalize';source='legacy-wmi'
        completedAt=[datetime]::UtcNow.ToString('o');checks=[pscustomobject]@{
            sysprepGeneralizeSucceeded=$true;oobeReady=$true;shutdownObserved=$true
        }
    })
    $sha=(Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash
    return Submit-HyperVImageGeneralizationEvidence -BuildId $Build.buildId -EvidencePath $evidencePath -ExpectedSha256 $sha -StateRoot $StateRoot
}

function Invoke-HyperVLegacyWindowsEvaluationTemplateBuild {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][ValidateSet('2008R2','2012R2')][string]$Version,
        [string]$MediaRoot,[string]$StateRoot,[Parameter(Mandatory)][string]$ExternalSwitchName,
        [ValidateRange(300,3600)][int]$TimeoutSeconds=2400,
        [ValidateRange(40,256)][int]$OsDiskSizeGB=80,
        [ValidateRange(2048,32768)][int]$MemoryStartupMB=4096,
        [ValidateRange(1,16)][int]$ProcessorCount=2,[switch]$KeepOnFailure
    )
    if(-not $MediaRoot){$MediaRoot=Get-LabMediaRootDefault};if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $osId=if($Version -eq '2008R2'){'windows-server-2008-r2'}else{'windows-server-2012-r2'}
    $switch=Get-VMSwitch -Name $ExternalSwitchName -ErrorAction Stop
    if([string]$switch.SwitchType -eq 'Private'){throw 'HYPERV_LEGACY_TEMPLATE_EXTERNAL_SWITCH_REQUIRED'}
    $media=Resolve-HyperVWindowsEvaluationCatalogMedia -MediaRoot $MediaRoot -Version $Version
    $variant=@(Get-HyperVWindowsEvaluationVariantEvidence -MediaRoot $MediaRoot -Version $Version -OperatingSystemId $osId -ExpectedSha256 $media.ExpectedSha256)
    if($variant.Count -ne 1){throw 'HYPERV_LEGACY_TEMPLATE_VARIANT_NOT_UNIQUE'}
    if(-not $PSCmdlet.ShouldProcess("Windows Server $Version",'über Legacy-WMI installieren, aktivieren, generalisieren und Child-validieren')){
        return [pscustomobject]@{Status='PLANNED';Version=$Version;IsoPath=$media.IsoPath;ImageIndex=$variant[0].ImageIndex}
    }
    $adapterName='SQL_SERVER_LAB_LEGACY_TEMP';$build=$null;$published=$null;$validationLab=$null
    $answerDirectory=$null;$answerIsoPath=$null;$childAnswerDirectory=$null;$childAnswerIsoPath=$null
    $adminPassword=$null;$credential=$null
    try {
        $build=New-HyperVWindowsImageBuildPlan -IsoPath $media.IsoPath -ExpectedSha256 $media.ExpectedSha256 `
            -OperatingSystemId $osId -Edition standard-evaluation -InstallationType desktop-experience `
            -Language en-US -LicenseType evaluation -InitialMediaKey space -OsDiskSizeBytes ([long]$OsDiskSizeGB*1GB) -StateRoot $StateRoot
        $null=New-HyperVWindowsImageBuilder -BuildId $build.buildId -MemoryStartupBytes ([long]$MemoryStartupMB*1MB) -ProcessorCount $ProcessorCount -StateRoot $StateRoot
        $build=Set-HyperVImageBuildManualAction -BuildId $build.buildId -StateRoot $StateRoot
        $vmName=[string]$build.builder.vmName;$vm=Get-VM -Name $vmName -ErrorAction Stop
        $adminPassword=New-HyperVSqlUnattendedPassword;$credential=[PSCredential]::new('Administrator',$adminPassword)
        $answerDirectory=Join-Path $build.BuildDirectory 'legacy-unattended-answer';$answerIsoPath=Join-Path $build.BuildDirectory 'legacy-unattended-answer.iso'
        New-Item -Path $answerDirectory -ItemType Directory -ErrorAction Stop|Out-Null
        $xml=$null
        try{$xml=New-HyperVLegacyWindowsOobeUnattendXml -AdministratorPassword $adminPassword;$xml=Add-HyperVWindowsSetupPassToUnattend -OobeUnattend $xml -ImageIndex ([int]$variant[0].ImageIndex) -VmGeneration ([int]$build.platform.vmGeneration);[void][xml]$xml;[IO.File]::WriteAllText((Join-Path $answerDirectory 'Autounattend.xml'),$xml,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $answerDirectory 'Unattend.xml'),$xml,[Text.UTF8Encoding]::new($false));New-HyperVWindowsSetupAnswerIso -SourceDirectory $answerDirectory -DestinationPath $answerIsoPath}finally{$xml=$null}
        Remove-Item -LiteralPath $answerDirectory -Recurse -Force;$answerDirectory=$null
        Add-VMDvdDrive -VM $vm -Path $answerIsoPath -ErrorAction Stop|Out-Null
        Add-VMNetworkAdapter -VMName $vmName -Name $adapterName -SwitchName $ExternalSwitchName `
            -IsLegacy:($Version -eq '2008R2') -ErrorAction Stop|Out-Null
        $null=Start-HyperVWindowsImageBuildVM -BuildId $build.buildId -StateRoot $StateRoot
        $ready=Wait-HyperVLegacyWindowsWmi -VMName $vmName -AdapterName $adapterName -Credential $credential -TimeoutSeconds $TimeoutSeconds
        if(-not $ready.Ready){throw "HYPERV_LEGACY_TEMPLATE_WMI_NOT_READY: $($ready.LastError)"}
        @($vm|Get-VMDvdDrive|Where-Object Path -eq $answerIsoPath)|Set-VMDvdDrive -Path $null -ErrorAction Stop
        Remove-Item -LiteralPath $answerIsoPath -Force;$answerIsoPath=$null
        Remove-HyperVLegacyWindowsGuestSecretTraces -Scope $ready.Scope
        $guest=Wait-HyperVLegacyWindowsGuestComplete -Scope $ready.Scope -TimeoutSeconds 300
        if($guest.imageState -ne 'IMAGE_STATE_COMPLETE' -or $guest.productName -notmatch [regex]::Escape($Version.Substring(0,4)) -or $guest.sqlInstalled){throw "HYPERV_LEGACY_TEMPLATE_INSTALL_POSTCONDITION_FAILED: $($guest|ConvertTo-Json -Compress)"}
        $activation=Invoke-HyperVLegacyWindowsEvaluationActivation -Scope $ready.Scope `
            -AllowActivationGrace:($Version -eq '2008R2')
        $build | Add-Member -NotePropertyName installationEvidence -NotePropertyValue ([pscustomobject]@{contractVersion='1';verified=$true;productName=$guest.productName;editionId=$guest.editionId;installationType='desktop-experience';requestedInstallationType='desktop-experience';metadataAdjusted=$false;currentBuild=$guest.currentBuild;displayVersion='';computerName='legacy-wmi';observedAt=[datetime]::UtcNow.ToString('o');acceptedAt=Get-LabTimestamp}) -Force
        Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
        $null=Invoke-HyperVLegacyWindowsSysprep -Scope $ready.Scope -VMName $vmName -TimeoutSeconds ([Math]::Min(1800,$TimeoutSeconds))
        Get-VMNetworkAdapter -VMName $vmName -Name $adapterName -ErrorAction SilentlyContinue|Remove-VMNetworkAdapter -ErrorAction Stop
        $build=Get-HyperVImageBuildPlan -BuildId $build.buildId -StateRoot $StateRoot
        $build=Set-HyperVImageBuildState -BuildId $build.buildId -State REBOOT_REQUIRED -Reason 'Legacy-WMI-Sysprep erfolgreich; Gast-Shutdown technisch beobachtet' -StateRoot $StateRoot
        $build=Submit-HyperVLegacyWindowsGeneralizationEvidence -Build $build -StateRoot $StateRoot
        $published=Publish-HyperVWindowsImageBuild -BuildId $build.buildId -EvaluationExpiresAt ([datetime]$activation.evaluationExpiresAt) -RequireChildBootValidation -StateRoot $StateRoot

        $childPassword=New-HyperVSqlUnattendedPassword;$childCredential=[PSCredential]::new('Administrator',$childPassword)
        try {
            $validationLab=New-HyperVLabEnvironment -ArtifactId $published.Artifact.artifactId -LabName "template-validation-$Version" -InstanceId "windows-$Version-validation" -MemoryStartupMB $MemoryStartupMB -ProcessorCount $ProcessorCount -Isolated -TemplateValidationRun -StateRoot $StateRoot
            $child=Get-HyperVLabWorkflowRun -RunId $validationLab.RunId -StateRoot $StateRoot;$childVm=Get-VM -Name $child.Instance.vmName -ErrorAction Stop
            $childAnswerDirectory=Join-Path $child.RunDirectory 'legacy-validation-answer';$childAnswerIsoPath=Join-Path $child.RunDirectory 'legacy-validation-answer.iso'
            New-Item -Path $childAnswerDirectory -ItemType Directory -ErrorAction Stop|Out-Null
            $childXml=$null
            try{$childXml=New-HyperVLegacyWindowsOobeUnattendXml -AdministratorPassword $childPassword;[void][xml]$childXml;[IO.File]::WriteAllText((Join-Path $childAnswerDirectory 'Autounattend.xml'),$childXml,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $childAnswerDirectory 'Unattend.xml'),$childXml,[Text.UTF8Encoding]::new($false));New-HyperVWindowsSetupAnswerIso -SourceDirectory $childAnswerDirectory -DestinationPath $childAnswerIsoPath}finally{$childXml=$null}
            Remove-Item -LiteralPath $childAnswerDirectory -Recurse -Force;$childAnswerDirectory=$null
            Add-VMDvdDrive -VM $childVm -Path $childAnswerIsoPath -ErrorAction Stop|Out-Null
            Add-VMNetworkAdapter -VMName $child.Instance.vmName -Name $adapterName -SwitchName $ExternalSwitchName `
                -IsLegacy:($Version -eq '2008R2') -ErrorAction Stop|Out-Null
            $null=Start-HyperVInstance -VMName $child.Instance.vmName -ExpectedRunId $child.Run.runId -ExpectedScopeId $child.Run.scopeId
            $childReady=Wait-HyperVLegacyWindowsWmi -VMName $child.Instance.vmName -AdapterName $adapterName -Credential $childCredential -TimeoutSeconds $TimeoutSeconds
            if(-not $childReady.Ready){throw 'HYPERV_LEGACY_TEMPLATE_CHILD_OOBE_FAILED'}
            @($childVm|Get-VMDvdDrive|Where-Object Path -eq $childAnswerIsoPath)|Set-VMDvdDrive -Path $null -ErrorAction Stop
            Remove-Item -LiteralPath $childAnswerIsoPath -Force;$childAnswerIsoPath=$null
            Remove-HyperVLegacyWindowsGuestSecretTraces -Scope $childReady.Scope
            $initialChildReceipt=Wait-HyperVLegacyWindowsGuestComplete -Scope $childReady.Scope -TimeoutSeconds 300
            if($initialChildReceipt.imageState -ne 'IMAGE_STATE_COMPLETE'){
                throw "HYPERV_LEGACY_TEMPLATE_CHILD_OOBE_INCOMPLETE: $($initialChildReceipt.imageState)"
            }
            $null=Invoke-HyperVLegacyWindowsProcess -Scope $childReady.Scope -CommandLine 'shutdown.exe /s /t 0 /f'
            $deadline=[datetime]::UtcNow.AddSeconds(300);do{Start-Sleep 2;$childVm=Get-VM -Name $child.Instance.vmName}while([string]$childVm.State -ne 'Off' -and [datetime]::UtcNow -lt $deadline)
            if([string]$childVm.State -ne 'Off'){throw 'HYPERV_LEGACY_TEMPLATE_CHILD_SHUTDOWN_FAILED'}
            $null=Start-HyperVInstance -VMName $child.Instance.vmName -ExpectedRunId $child.Run.runId -ExpectedScopeId $child.Run.scopeId
            $coldReady=Wait-HyperVLegacyWindowsWmi -VMName $child.Instance.vmName -AdapterName $adapterName -Credential $childCredential -TimeoutSeconds $TimeoutSeconds
            if(-not $coldReady.Ready){throw 'HYPERV_LEGACY_TEMPLATE_CHILD_COLD_START_FAILED'}
            $childReceipt=Wait-HyperVLegacyWindowsGuestComplete -Scope $coldReady.Scope -TimeoutSeconds 300
            if($childReceipt.imageState -ne 'IMAGE_STATE_COMPLETE' -or $childReceipt.productName -notmatch [regex]::Escape($Version.Substring(0,4)) -or $childReceipt.sqlInstalled){throw "HYPERV_LEGACY_TEMPLATE_CHILD_POSTCONDITION_FAILED: $($childReceipt|ConvertTo-Json -Compress)"}
            $childLicense=Get-HyperVLegacyWindowsEvaluationLicenseReceipt -Scope $coldReady.Scope
            $childLicenseUsable=if($Version -eq '2008R2'){
                [int]$childLicense.licenseStatus -in @(1,2) -and [int]$childLicense.graceMinutes -ge 1440
            }else{
                [int]$childLicense.licenseStatus -eq 1 -and [int]$childLicense.graceMinutes -ge 43200
            }
            if(-not $childLicenseUsable){
                throw "HYPERV_LEGACY_TEMPLATE_CHILD_LICENSE_FAILED: LicenseStatus=$([int]$childLicense.licenseStatus); GraceMinutes=$([int]$childLicense.graceMinutes)"
            }
        }
        catch{
            $childFailure=$_;try{$null=Set-HyperVImageArtifactChildValidation -ArtifactId $published.Artifact.artifactId -State FAILED -StateRoot $StateRoot}catch{};throw $childFailure
        }
        finally{
            $childCredential=$null;$childPassword=$null
            if($validationLab){$cleanup=Remove-SqlServerLab -RunId $validationLab.RunId -StateRoot $StateRoot -Force -Confirm:$false;if($cleanup.Status -ne 'REMOVED'){throw "HYPERV_LEGACY_TEMPLATE_CHILD_CLEANUP_FAILED: $($cleanup.Status)"};$validationLab=$null}
            if($childAnswerIsoPath){Remove-Item -LiteralPath $childAnswerIsoPath -Force -ErrorAction SilentlyContinue};if($childAnswerDirectory){Remove-Item -LiteralPath $childAnswerDirectory -Recurse -Force -ErrorAction SilentlyContinue}
        }
        $evidenceRoot=Join-Path $StateRoot 'evidence/hyperv-windows-templates';New-Item $evidenceRoot -ItemType Directory -Force|Out-Null
        $evidencePath=Join-Path $evidenceRoot "$($published.Artifact.artifactId).json"
        Write-LabArtifactJsonAtomic -Path $evidencePath -InputObject ([pscustomobject]@{contractVersion='SqlServerLab.HyperVWindowsTemplateValidation/1.0';status='CHILD_BOOT_VERIFIED';artifactId=$published.Artifact.artifactId;operatingSystemId=$osId;imageIndex=[int]$variant[0].ImageIndex;vmGeneration=[int]$published.Artifact.platform.vmGeneration;secureBoot=[bool]$published.Artifact.platform.secureBoot;evaluationExpiresAt=$published.Artifact.license.evaluationExpiresAt;guestControl='legacy-wmi';licenseState=[string]$activation.state;checks=[pscustomobject]@{mediaHash=$true;installImage=$true;installation=$true;activation=[bool]$activation.activated;activationGrace=([string]$activation.state -eq 'OOB_GRACE');generalization=$true;childOobe=$true;childColdStart=$true;childLicenseUsable=$true;noSqlInstance=$true;cleanup=$true};observedAt=[datetime]::UtcNow.ToString('o')})
        $evidenceSha=(Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash
        $published.Artifact=Set-HyperVImageArtifactChildValidation -ArtifactId $published.Artifact.artifactId -State CHILD_BOOT_VERIFIED -EvidenceSha256 $evidenceSha -StateRoot $StateRoot
        return [pscustomobject]@{Status='CHILD_BOOT_VERIFIED';Version=$Version;ArtifactId=$published.Artifact.artifactId;EvaluationExpiresAt=$published.Artifact.license.evaluationExpiresAt;ActivationStatus=[string]$activation.state;GuestControl='legacy-wmi';CredentialDisclosed=$false;ChildValidationCleanup='REMOVED';ValidationEvidencePath=$evidencePath}
    }
    catch{
        $failure=$_
        if($published -and $published.Artifact -and [string]$published.Artifact.validation.state -ne 'CHILD_BOOT_VERIFIED'){try{$null=Set-HyperVImageArtifactChildValidation -ArtifactId $published.Artifact.artifactId -State FAILED -StateRoot $StateRoot}catch{}}
        if($build -and -not $KeepOnFailure){try{$null=Remove-HyperVWindowsImageBuild -BuildId $build.buildId -StateRoot $StateRoot}catch{}}
        if($published -and $published.Artifact -and -not $KeepOnFailure -and [string]$published.Artifact.validation.state -ne 'CHILD_BOOT_VERIFIED'){try{$null=Remove-HyperVImageArtifact -ArtifactId $published.Artifact.artifactId -StateRoot $StateRoot -Confirm:$false;$published=$null}catch{}}
        throw $failure
    }
    finally{
        $credential=$null;$adminPassword=$null
        foreach($path in @($answerIsoPath,$childAnswerIsoPath)){if($path){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}}
        foreach($path in @($answerDirectory,$childAnswerDirectory)){if($path){Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue}}
    }
}
