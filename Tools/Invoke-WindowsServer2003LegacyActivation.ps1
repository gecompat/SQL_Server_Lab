#Requires -Version 7.2
<#
.SYNOPSIS
Aktiviert einen Windows-Server-2003-Evaluation-Child und setzt Deutsch am Login.

.DESCRIPTION
Der Befehl übernimmt den aktuellen Windows-Slot-Aktivierungsvertrag für den
Legacy-Gast ohne PowerShell Direct. Er akzeptiert nur eine ausgeschaltete,
eindeutige Generation-1-VM ohne Checkpoints und mit exakt gebundener Child-VHDX.
Für den Lauf wird eine eindeutig benannte temporäre Legacy-NIC hinzugefügt.

Nach dem Start wartet der Host auf eine vom Hyper-V-Datenaustausch gemeldete
Adresse und verbindet sich mit dem lokalen Administrator-Credential über WMI.
Im Gast wird Deutsch (`0407:00000407`) für die Anmeldemaske gesetzt.
Anschließend ruft WMI bei Bedarf
`Win32_WindowsProductActivation.ActivateOnline()` auf und prüft Status und
Restlaufzeit. Der Gast wird heruntergefahren und die Internet-NIC entfernt.

Das Credential bleibt im Arbeitsspeicher und wird weder in VHDX, Befehlszeile,
Ausgabe noch Repository geschrieben. Der Befehl umgeht keine Aktivierung.

.PARAMETER VmName
Exakter Name der vorhandenen Windows-Server-2003-Generation-1-VM.

.PARAMETER ChildVhdPath
Exakter Pfad ihrer beschreibbaren Child-VHDX.

.PARAMETER AdministratorCredential
Lokales Administrator-Credential des Childs.

.PARAMETER PromptForAdministratorCredential
Fragt das Credential interaktiv und geschützt ab.

.PARAMETER ActivationSwitchName
Vorhandener Switch mit DHCP und Internet-Egress, standardmäßig `Default Switch`.

.PARAMETER StaticAddress
Optionale feste IPv4-Adresse für die bereits vorhandene primäre Legacy-NIC.
Sie wird über die temporäre DHCP-NIC gesetzt, bevor diese wieder entfernt wird.

.PARAMETER StaticSubnetMask
Subnetzmaske zur festen IPv4-Adresse, standardmäßig `255.255.255.0`.

.PARAMETER ActivationMode
`Online` versucht die direkte Aktivierung, `PrepareOffline` liest die für das
Microsoft-Portal erforderliche Installations-ID, `CompleteOffline` übernimmt
eine dort erzeugte Bestätigungs-ID, und `KeyboardOnly` setzt nur das deutsche
Login-Layout.

.PARAMETER OfflineConfirmationId
Vom Microsoft Product Activation Portal gelieferte Bestätigungs-ID als
SecureString. Nur zusammen mit `ActivationMode CompleteOffline` zulässig.

.PARAMETER PromptForOfflineConfirmationId
Fragt die Bestätigungs-ID geschützt ab, ohne sie in Befehlszeile oder History
zu übernehmen.

.PARAMETER KeyboardLayoutOnly
Kompatibler Alias für `ActivationMode KeyboardOnly`.

.PARAMETER TimeoutSeconds
Maximale Gesamtdauer für Boot, WMI-Verbindung und Online-Aktivierung.

Während des Mini-Setups bestätigt der Host den bei Evaluation-Medien
reproduzierbar eingeblendeten Hinweis begrenzt per virtueller Enter-Taste.

.PARAMETER ShowHelp
Zeigt diese Hilfe ohne Mutation.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Alias('h', 'help', '?')]
    [switch] $ShowHelp,

    [ValidateNotNullOrEmpty()]
    [string] $VmName,

    [ValidateNotNullOrEmpty()]
    [string] $ChildVhdPath,

    [PSCredential] $AdministratorCredential,

    [switch] $PromptForAdministratorCredential,

    [ValidateNotNullOrEmpty()]
    [string] $ActivationSwitchName = 'Default Switch',

    [string] $StaticAddress,

    [string] $StaticSubnetMask = '255.255.255.0',

    [ValidateSet('0407:00000407')]
    [string] $InputLocale = '0407:00000407',

    [ValidateSet('Online', 'PrepareOffline', 'CompleteOffline', 'KeyboardOnly')]
    [string] $ActivationMode = 'Online',

    [SecureString] $OfflineConfirmationId,

    [switch] $PromptForOfflineConfirmationId,

    [switch] $KeyboardLayoutOnly,

    [ValidateRange(120, 3600)]
    [int] $TimeoutSeconds = 900,

    [Parameter(ValueFromRemainingArguments)]
    [string[]] $RemainingArgs
)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or
    @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or
    @($RemainingArgs) -contains '--help'
if ($showHelpRequested) {
    Get-Help -Full -Name $PSCommandPath | Out-Host
    return
}

$requiredArguments = [ordered]@{
    VmName = $VmName
    ChildVhdPath = $ChildVhdPath
    ActivationSwitchName = $ActivationSwitchName
}
if (-not $PromptForAdministratorCredential) {
    $requiredArguments.AdministratorCredential = $AdministratorCredential
}
$missingArguments = @($requiredArguments.GetEnumerator() | Where-Object {
    $null -eq $_.Value -or [string]::IsNullOrWhiteSpace([string] $_.Value)
} | ForEach-Object Key)
if ($missingArguments.Count -gt 0) {
    throw "WS2003_ACTIVATION_ARGUMENT_REQUIRED: $($missingArguments -join ', ')"
}
if ($KeyboardLayoutOnly) {
    if ($PSBoundParameters.ContainsKey('ActivationMode') -and $ActivationMode -ne 'KeyboardOnly') {
        throw 'WS2003_ACTIVATION_MODE_CONFLICT'
    }
    $ActivationMode = 'KeyboardOnly'
}
if ($ActivationMode -eq 'CompleteOffline' -and
    -not $OfflineConfirmationId -and -not $PromptForOfflineConfirmationId) {
    throw 'WS2003_OFFLINE_CONFIRMATION_ID_REQUIRED'
}
if ($ActivationMode -ne 'CompleteOffline' -and
    ($OfflineConfirmationId -or $PromptForOfflineConfirmationId)) {
    throw 'WS2003_OFFLINE_CONFIRMATION_ID_NOT_APPLICABLE'
}
$parsedAddress = [Net.IPAddress]::None
$parsedMask = [Net.IPAddress]::None
if ($StaticAddress -and
    (-not [Net.IPAddress]::TryParse($StaticAddress, [ref] $parsedAddress) -or
     $parsedAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork)) {
    throw 'WS2003_STATIC_ADDRESS_INVALID'
}
if ($StaticAddress -and
    (-not [Net.IPAddress]::TryParse($StaticSubnetMask, [ref] $parsedMask) -or
     $parsedMask.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork)) {
    throw 'WS2003_STATIC_SUBNET_MASK_INVALID'
}

$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop
Add-Type -AssemblyName System.Management -ErrorAction Stop

$temporaryAdapterName = 'SQL_SERVER_LAB_ACTIVATION_TEMP'
$resolvedChildVhd = (Resolve-Path -LiteralPath $ChildVhdPath).Path
$vm = Get-VM -Name $VmName -ErrorAction Stop
$activationSwitch = Get-VMSwitch -Name $ActivationSwitchName -ErrorAction Stop

if ([int] $vm.Generation -ne 1) {
    throw 'WS2003_ACTIVATION_GENERATION_INVALID: Erwartet wird eine Generation-1-VM.'
}
if ([string] $vm.State -ne 'Off') {
    throw "WS2003_ACTIVATION_VM_MUST_BE_OFF: $($vm.State)"
}
if ([string] $activationSwitch.SwitchType -eq 'Private') {
    throw 'WS2003_ACTIVATION_SWITCH_PRIVATE: Der Aktivierungs-Switch benötigt DHCP und Internet-Egress.'
}
if ((Get-Item -LiteralPath $resolvedChildVhd).IsReadOnly) {
    throw 'WS2003_ACTIVATION_CHILD_READ_ONLY: Die Child-VHDX muss beschreibbar sein.'
}
if (@(Get-VMSnapshot -VM $vm -ErrorAction Stop).Count -gt 0) {
    throw 'WS2003_ACTIVATION_CHECKPOINT_PRESENT: Vorhandene Checkpoints werden nicht unterstützt.'
}
$matchingDisks = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop | Where-Object {
    $_.Path -and [IO.Path]::GetFullPath([string] $_.Path).Equals(
        $resolvedChildVhd, [StringComparison]::OrdinalIgnoreCase)
})
if ($matchingDisks.Count -ne 1) {
    throw 'WS2003_ACTIVATION_CHILD_BINDING_INVALID: Die VHDX ist nicht eindeutig an die VM gebunden.'
}
if (Get-VMNetworkAdapter -VM $vm -Name $temporaryAdapterName -ErrorAction SilentlyContinue) {
    throw 'WS2003_ACTIVATION_TEMP_ADAPTER_EXISTS: Vorhandene gleichnamige NIC wird nicht übernommen.'
}

$action = switch ($ActivationMode) {
    'KeyboardOnly' {
        "deutsches Login-Layout über temporären Switch '$ActivationSwitchName' setzen"
    }
    'PrepareOffline' {
        "Installations-ID für die Offline-Aktivierung über temporären Switch '$ActivationSwitchName' lesen"
    }
    'CompleteOffline' {
        "Evaluation mit einer geschützten Bestätigungs-ID offline aktivieren"
    }
    default {
        "Evaluation über temporären Switch '$ActivationSwitchName' online aktivieren und deutsches Login-Layout setzen"
    }
}
if (-not $PSCmdlet.ShouldProcess($VmName, $action)) {
    return [pscustomobject]@{
        Status = 'PLANNED'
        VmName = $VmName
        ChildVhdPath = $resolvedChildVhd
        ActivationSwitchName = $ActivationSwitchName
        TemporaryAdapterName = $temporaryAdapterName
        ActivationMode = $ActivationMode
        ActivationMethod = switch ($ActivationMode) {
            'KeyboardOnly' { 'NONE' }
            'PrepareOffline' { 'Win32_WindowsProductActivation.GetInstallationID' }
            'CompleteOffline' { 'Win32_WindowsProductActivation.ActivateOffline' }
            default { 'Win32_WindowsProductActivation.ActivateOnline' }
        }
        InputLocale = $InputLocale
        LogonKeyboardLayout = '00000407'
        ProductKeyDisclosed = $false
        CredentialDisclosed = $false
    }
}

$windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$windowsPrincipal = [Security.Principal.WindowsPrincipal]::new($windowsIdentity)
if (-not $windowsPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'WS2003_ACTIVATION_REQUIRES_ELEVATED_RUNNER'
}
if ($PromptForAdministratorCredential) {
    $AdministratorCredential = Get-Credential -UserName Administrator `
        -Message 'Lokales Kennwort des Windows-Server-2003-Childs'
    if (-not $AdministratorCredential) {
        throw 'WS2003_ACTIVATION_CREDENTIAL_PROMPT_CANCELLED'
    }
}
if ([string] $AdministratorCredential.GetNetworkCredential().UserName -ne 'Administrator') {
    throw 'WS2003_ACTIVATION_ADMINISTRATOR_REQUIRED: Erwartet wird das lokale Administrator-Credential.'
}
if ($PromptForOfflineConfirmationId) {
    $OfflineConfirmationId = Read-Host `
        -Prompt 'Bestätigungs-ID des Microsoft Product Activation Portals' `
        -AsSecureString
    if (-not $OfflineConfirmationId) {
        throw 'WS2003_OFFLINE_CONFIRMATION_ID_PROMPT_CANCELLED'
    }
}

function Connect-WindowsServer2003WmiScope {
    param(
        [Parameter(Mandatory)][string] $Address,
        [Parameter(Mandatory)][string] $Namespace,
        [Parameter(Mandatory)][PSCredential] $Credential
    )

    $passwordPointer = [IntPtr]::Zero
    $plainPassword = $null
    try {
        $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
        $options = [System.Management.ConnectionOptions]::new()
        $options.Username = [string] $Credential.GetNetworkCredential().UserName
        $options.Password = $plainPassword
        $options.Impersonation = [System.Management.ImpersonationLevel]::Impersonate
        # NT5 accepts read-only queries at Packet level, but remote provider
        # method calls (StdRegProv, Win32_Process and EnableStatic) require the
        # stronger DCOM authentication level on this evaluation image.
        $options.Authentication = [System.Management.AuthenticationLevel]::PacketPrivacy
        $options.EnablePrivileges = $true
        $options.Timeout = [timespan]::FromSeconds(20)
        $scope = [System.Management.ManagementScope]::new("\\$Address\$Namespace", $options)
        $scope.Connect()
        return $scope
    }
    finally {
        $plainPassword = $null
        if ($passwordPointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
        }
    }
}

function Invoke-WindowsServer2003RegistryString {
    param(
        [Parameter(Mandatory)][System.Management.ManagementScope] $Scope,
        [Parameter(Mandatory)][UInt32] $RootKey,
        [Parameter(Mandatory)][string] $SubKey,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Value
    )

    $registry = [System.Management.ManagementClass]::new(
        $Scope, [System.Management.ManagementPath]::new('StdRegProv'), $null)
    $createInput = $registry.GetMethodParameters('CreateKey')
    $createInput['hDefKey'] = $RootKey
    $createInput['sSubKeyName'] = $SubKey
    $createOutput = $registry.InvokeMethod('CreateKey', $createInput, $null)
    if ([uint32] $createOutput['ReturnValue'] -ne 0) {
        throw 'WS2003_KEYBOARD_REGISTRY_CREATE_FAILED'
    }
    $setInput = $registry.GetMethodParameters('SetStringValue')
    $setInput['hDefKey'] = $RootKey
    $setInput['sSubKeyName'] = $SubKey
    $setInput['sValueName'] = $Name
    $setInput['sValue'] = $Value
    $setOutput = $registry.InvokeMethod('SetStringValue', $setInput, $null)
    if ([uint32] $setOutput['ReturnValue'] -ne 0) {
        throw 'WS2003_KEYBOARD_REGISTRY_SET_FAILED'
    }
}

function Get-WindowsServer2003ActivationState {
    param([Parameter(Mandatory)][System.Management.ManagementScope] $Scope)

    $query = [System.Management.ObjectQuery]::new(
        'SELECT ActivationRequired, RemainingEvaluationPeriod, RemainingGracePeriod FROM Win32_WindowsProductActivation')
    $searcher = [System.Management.ManagementObjectSearcher]::new($Scope, $query)
    $products = @($searcher.Get())
    if ($products.Count -ne 1) {
        throw "WS2003_ACTIVATION_PRODUCT_COUNT_INVALID: $($products.Count)"
    }
    return [pscustomobject]@{
        ActivationRequired = [int] $products[0]['ActivationRequired']
        EvaluationDaysRemaining = [int] $products[0]['RemainingEvaluationPeriod']
        GraceDaysRemaining = [int] $products[0]['RemainingGracePeriod']
    }
}

function Invoke-WindowsServer2003ActivationMethod {
    param(
        [Parameter(Mandatory)][System.Management.ManagementScope] $Scope,
        [Parameter(Mandatory)]
        [ValidateSet('GetInstallationID', 'ActivateOffline')]
        [string] $Method,
        [string] $ConfirmationId
    )

    $query = [System.Management.ObjectQuery]::new(
        'SELECT * FROM Win32_WindowsProductActivation')
    $searcher = [System.Management.ManagementObjectSearcher]::new($Scope, $query)
    $products = @($searcher.Get())
    if ($products.Count -ne 1) {
        throw "WS2003_ACTIVATION_PRODUCT_COUNT_INVALID: $($products.Count)"
    }
    $methodInput = $products[0].GetMethodParameters($Method)
    if ($Method -eq 'ActivateOffline') {
        $methodInput['ConfirmationID'] = $ConfirmationId
    }
    $methodOutput = $products[0].InvokeMethod($Method, $methodInput, $null)
    if ([uint32] $methodOutput['ReturnValue'] -ne 0) {
        throw "WS2003_ACTIVATION_METHOD_FAILED: Method=$Method; ReturnValue=$($methodOutput['ReturnValue'])"
    }
    return $methodOutput
}

function Invoke-WindowsServer2003ProcessThroughWmi {
    param(
        [Parameter(Mandatory)][System.Management.ManagementScope] $Scope,
        [Parameter(Mandatory)][string] $CommandLine
    )

    $processClass = [System.Management.ManagementClass]::new(
        $Scope, [System.Management.ManagementPath]::new('Win32_Process'), $null)
    $createInput = $processClass.GetMethodParameters('Create')
    $createInput['CommandLine'] = $CommandLine
    $output = $processClass.InvokeMethod('Create', $createInput, $null)
    if ([uint32] $output['ReturnValue'] -ne 0) {
        throw "WS2003_PROCESS_CREATE_FAILED: ReturnValue=$($output['ReturnValue'])"
    }
    return [uint32] $output['ProcessId']
}

function Set-WindowsServer2003StaticAddress {
    param(
        [Parameter(Mandatory)][System.Management.ManagementScope] $Scope,
        [Parameter(Mandatory)][string] $MacAddress,
        [Parameter(Mandatory)][string] $Address,
        [Parameter(Mandatory)][string] $SubnetMask
    )

    $hex = ($MacAddress -replace '[^A-Fa-f0-9]', '').ToUpperInvariant()
    if ($hex.Length -ne 12) { throw 'WS2003_STATIC_ADAPTER_MAC_INVALID' }
    $normalizedMac = @(
        for ($index = 0; $index -lt 12; $index += 2) { $hex.Substring($index, 2) }
    ) -join ':'
    $query = [System.Management.ObjectQuery]::new(
        "SELECT * FROM Win32_NetworkAdapterConfiguration WHERE MACAddress='$normalizedMac'")
    $configurations = @([System.Management.ManagementObjectSearcher]::new($Scope, $query).Get())
    if ($configurations.Count -ne 1) {
        throw "WS2003_STATIC_ADAPTER_COUNT_INVALID: $($configurations.Count)"
    }
    $input = $configurations[0].GetMethodParameters('EnableStatic')
    $input['IPAddress'] = [string[]] @($Address)
    $input['SubnetMask'] = [string[]] @($SubnetMask)
    $output = $configurations[0].InvokeMethod('EnableStatic', $input, $null)
    if ([uint32] $output['ReturnValue'] -notin @(0, 1)) {
        throw "WS2003_STATIC_ADDRESS_FAILED: ReturnValue=$($output['ReturnValue'])"
    }
}

function Send-WindowsServer2003EvaluationNoticeEnter {
    param([Parameter(Mandatory)][string] $TargetVmName)

    $escapedVmName = $TargetVmName.Replace("'", "''")
    $computerSystem = @(Get-CimInstance -Namespace 'root/virtualization/v2' `
        -ClassName Msvm_ComputerSystem -Filter "ElementName='$escapedVmName'" `
        -ErrorAction Stop)[0]
    if (-not $computerSystem) { throw 'WS2003_MINISETUP_VM_CIM_NOT_FOUND' }
    $keyboard = @(Get-CimAssociatedInstance -InputObject $computerSystem `
        -Association Msvm_SystemDevice -ResultClassName Msvm_Keyboard `
        -ErrorAction Stop)[0]
    if (-not $keyboard) { throw 'WS2003_MINISETUP_KEYBOARD_NOT_FOUND' }
    $result = Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey `
        -Arguments @{ keyCode = [uint32] 0x0D } -ErrorAction Stop
    if ([uint32] $result.ReturnValue -ne 0) {
        throw "WS2003_MINISETUP_ENTER_FAILED: $($result.ReturnValue)"
    }
}

function Mount-WindowsServer2003ChildVolume {
    param([Parameter(Mandatory)][string] $Path)
    $mounted = Mount-VHD -Path $Path -NoDriveLetter -Passthru -ErrorAction Stop
    $mountRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('SqlServerLab-VhdMount-' + [guid]::NewGuid().ToString('N'))
    $accessPath = $null
    try {
        $disk = $mounted | Get-Disk -ErrorAction Stop
        $partition = Get-Partition -DiskNumber $disk.Number -ErrorAction Stop |
            Where-Object { $_.Size -ge 1GB -and $_.Type -ne 'Reserved' } |
            Sort-Object Size -Descending | Select-Object -First 1
        if (-not $partition) { throw 'WS2003_BOOTSTRAP_SYSTEM_PARTITION_NOT_FOUND' }
        New-Item -Path $mountRoot -ItemType Directory -Force | Out-Null
        $accessPath = $mountRoot.TrimEnd('\') + '\'
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber `
            -AccessPath $accessPath -ErrorAction Stop | Out-Null
        return [pscustomobject]@{
            Path = $Path; DiskNumber = $disk.Number; PartitionNumber = $partition.PartitionNumber
            RootPath = $accessPath; AccessPath = $accessPath
        }
    }
    catch {
        if ($accessPath) {
            Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber `
                -AccessPath $accessPath -ErrorAction SilentlyContinue
        }
        Dismount-VHD -Path $Path -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $mountRoot -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Dismount-WindowsServer2003ChildVolume {
    param([Parameter(Mandatory)] $Mount)
    try {
        if ($Mount.AccessPath) {
            Remove-PartitionAccessPath -DiskNumber $Mount.DiskNumber `
                -PartitionNumber $Mount.PartitionNumber -AccessPath $Mount.AccessPath `
                -ErrorAction Stop
        }
    }
    finally {
        Dismount-VHD -Path $Mount.Path -ErrorAction Stop
        if ($Mount.AccessPath) {
            Remove-Item -LiteralPath ([string] $Mount.AccessPath).TrimEnd('\') `
                -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-WindowsServer2003OfflineBootstrap {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $PrimaryAdapterMac,
        [string] $StaticAddress,
        [string] $StaticSubnetMask
    )
    $mount = $null
    try {
        $mount = Mount-WindowsServer2003ChildVolume -Path $Path
        $root = $mount.RootPath
        $bootstrapRoot = Join-Path $root 'SQLServerLab'
        [IO.Directory]::CreateDirectory($bootstrapRoot) | Out-Null
        $normalizedMac = (@(for ($index = 0; $index -lt 12; $index += 2) {
            $PrimaryAdapterMac.Substring($index, 2)
        }) -join ':')
        $staticCommands = if ($StaticAddress) {
@"
set PRIMARY_INTERFACE=
for /f "tokens=2 delims==" %%I in ('wmic nic where "MACAddress='$normalizedMac'" get NetConnectionID /value ^| find "="') do set PRIMARY_INTERFACE=%%I
if not defined PRIMARY_INTERFACE goto STATIC_FAILED
netsh interface ip set address name="%PRIMARY_INTERFACE%" static $StaticAddress $StaticSubnetMask none
if errorlevel 1 goto STATIC_FAILED
set STATIC_CONFIGURED=True
"@
        } else { 'set STATIC_CONFIGURED=False' }
        $command = @"
@echo off
setlocal EnableExtensions
:CONFIGURE
netsh.exe firewall set opmode disable >nul 2>&1
if exist D:\support\x86\WindowsServer2003-KB943295-x86-ENU.exe D:\support\x86\WindowsServer2003-KB943295-x86-ENU.exe /quiet /norestart
if exist D:\support\x86\Windows5.x-HyperVIntegrationServices-x86.msi msiexec.exe /i D:\support\x86\Windows5.x-HyperVIntegrationServices-x86.msi /qn /norestart
reg.exe add "HKU\.DEFAULT\Keyboard Layout\Preload" /v 1 /t REG_SZ /d 00000407 /f >nul
if errorlevel 1 goto KEYBOARD_FAILED
reg.exe add "HKU\.DEFAULT\Control Panel\International" /v Locale /t REG_SZ /d 00000407 /f >nul
if errorlevel 1 goto KEYBOARD_FAILED
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\lanmanserver\parameters" /v AutoShareServer /t REG_DWORD /d 1 /f >nul
net.exe start lanmanserver >nul 2>&1
netsh.exe firewall set service type=FILEANDPRINT mode=ENABLE >nul 2>&1
$staticCommands
for /f "tokens=2 delims==" %%I in ('wmic path Win32_WindowsProductActivation get ActivationRequired /value ^| find "="') do set ACTIVATION_REQUIRED=%%I
for /f "tokens=2 delims==" %%I in ('wmic path Win32_WindowsProductActivation get RemainingEvaluationPeriod /value ^| find "="') do set EVALUATION_DAYS=%%I
for /f "tokens=2 delims==" %%I in ('wmic path Win32_WindowsProductActivation get RemainingGracePeriod /value ^| find "="') do set GRACE_DAYS=%%I
if not defined ACTIVATION_REQUIRED goto LICENSE_FAILED
>C:\SQLServerLab\activation-bootstrap.tmp echo status=COMPLETED
>>C:\SQLServerLab\activation-bootstrap.tmp echo activationRequired=%ACTIVATION_REQUIRED%
>>C:\SQLServerLab\activation-bootstrap.tmp echo evaluationDaysRemaining=%EVALUATION_DAYS%
>>C:\SQLServerLab\activation-bootstrap.tmp echo graceDaysRemaining=%GRACE_DAYS%
>>C:\SQLServerLab\activation-bootstrap.tmp echo staticAddressConfigured=%STATIC_CONFIGURED%
move /y C:\SQLServerLab\activation-bootstrap.tmp C:\SQLServerLab\activation-bootstrap.ini >nul
goto FINISH
:KEYBOARD_FAILED
set BOOTSTRAP_ERROR=KEYBOARD_CONFIGURATION_FAILED
goto WRITE_FAILURE
:STATIC_FAILED
set BOOTSTRAP_ERROR=STATIC_ADDRESS_CONFIGURATION_FAILED
goto WRITE_FAILURE
:LICENSE_FAILED
set BOOTSTRAP_ERROR=LICENSE_QUERY_FAILED
:WRITE_FAILURE
>C:\SQLServerLab\activation-bootstrap.tmp echo status=FAILED
>>C:\SQLServerLab\activation-bootstrap.tmp echo errorCode=%BOOTSTRAP_ERROR%
move /y C:\SQLServerLab\activation-bootstrap.tmp C:\SQLServerLab\activation-bootstrap.ini >nul
:FINISH
del /f /q C:\Windows\System32\GroupPolicy\Machine\Scripts\scripts.ini >nul 2>&1
shutdown.exe -s -t 5 -f
exit /b 0
"@
        Set-Content -LiteralPath (Join-Path $bootstrapRoot 'ActivationBootstrap.cmd') `
            -Value $command -Encoding ascii -NoNewline
        Remove-Item -LiteralPath (Join-Path $bootstrapRoot 'activation-bootstrap.ini') `
            -Force -ErrorAction SilentlyContinue
        $scriptPolicyRoot = Join-Path $root 'Windows\System32\GroupPolicy\Machine\Scripts'
        [IO.Directory]::CreateDirectory((Join-Path $scriptPolicyRoot 'Startup')) | Out-Null
        $scriptsIni = @"
[Startup]
0CmdLine=C:\SQLServerLab\ActivationBootstrap.cmd
0Parameters=
"@
        Set-Content -LiteralPath (Join-Path $scriptPolicyRoot 'scripts.ini') `
            -Value $scriptsIni -Encoding unicode -NoNewline
        $groupPolicyRoot = Split-Path -Parent (Split-Path -Parent $scriptPolicyRoot)
        $gptIni = @"
[General]
gPCMachineExtensionNames=[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]
Version=1
"@
        Set-Content -LiteralPath (Join-Path $groupPolicyRoot 'gpt.ini') `
            -Value $gptIni -Encoding ascii -NoNewline
    }
    finally {
        if ($mount) { Dismount-WindowsServer2003ChildVolume -Mount $mount }
    }
}

function Get-WindowsServer2003OfflineBootstrapReceipt {
    param([Parameter(Mandatory)][string] $Path)
    $mount = $null
    try {
        $mount = Mount-WindowsServer2003ChildVolume -Path $Path
        $receiptPath = Join-Path $mount.RootPath 'SQLServerLab\activation-bootstrap.ini'
        if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
            throw 'WS2003_BOOTSTRAP_RECEIPT_MISSING'
        }
        return ConvertFrom-StringData -StringData (Get-Content -LiteralPath $receiptPath -Raw -Encoding ascii)
    }
    finally { if ($mount) { Dismount-WindowsServer2003ChildVolume -Mount $mount } }
}

$adapterCreated = $false
$guestStarted = $false
$primaryError = $null
$activationState = $null
$installationId = $null
$confirmationIdPointer = [IntPtr]::Zero
$confirmationIdPlain = $null
try {
    $primaryAdapters = @(Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop)
    if ($primaryAdapters.Count -ne 1) {
        throw "WS2003_PRIMARY_ADAPTER_COUNT_INVALID: $($primaryAdapters.Count)"
    }
    $primaryAdapterMac = [string] $primaryAdapters[0].MacAddress
    if ($ActivationMode -eq 'KeyboardOnly') {
        Set-WindowsServer2003OfflineBootstrap -Path $resolvedChildVhd `
            -PrimaryAdapterMac $primaryAdapterMac -StaticAddress $StaticAddress `
            -StaticSubnetMask $StaticSubnetMask
    }
    Add-VMNetworkAdapter -VMName $VmName -Name $temporaryAdapterName `
        -SwitchName $ActivationSwitchName -IsLegacy $true -ErrorAction Stop | Out-Null
    $adapterCreated = $true
    Start-VM -Name $VmName -ErrorAction Stop | Out-Null
    $guestStarted = $true

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $nextEvaluationNoticeEnter = [datetime]::UtcNow.AddSeconds(180)
    $evaluationNoticeEnterCount = 0
    $scope = $null
    $bootstrapComplete = $false
    do {
        Start-Sleep -Seconds 3
        if ($ActivationMode -eq 'KeyboardOnly') {
            $bootstrapComplete = [string](Get-VM -Name $VmName -ErrorAction Stop).State -eq 'Off'
        }
        else {
            $adapter = Get-VMNetworkAdapter -VMName $VmName -Name $temporaryAdapterName `
                -ErrorAction SilentlyContinue
            $guestAddress = @($adapter.IPAddresses | Where-Object {
                $_ -match '^\d{1,3}(?:\.\d{1,3}){3}$' -and $_ -notlike '169.254.*'
            } | Select-Object -First 1)
            if (-not $guestAddress -and $adapter.MacAddress) {
                $normalizedMac = ($adapter.MacAddress -replace '(.{2})(?!$)', '$1-').ToUpperInvariant()
                $guestAddress = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.LinkLayerAddress.ToUpperInvariant() -eq $normalizedMac -and
                        $_.IPAddress -notlike '169.254.*' } |
                    Select-Object -ExpandProperty IPAddress -First 1)
            }
            if ($guestAddress) {
                try {
                    $scope = Connect-WindowsServer2003WmiScope -Address $guestAddress[0] `
                        -Namespace 'root\cimv2' -Credential $AdministratorCredential
                }
                catch { $scope = $null }
            }
        }
        $waiting = if ($ActivationMode -eq 'KeyboardOnly') { -not $bootstrapComplete } else { -not $scope }
        if ($waiting -and [datetime]::UtcNow -ge $nextEvaluationNoticeEnter -and
            $evaluationNoticeEnterCount -lt 5) {
            Send-WindowsServer2003EvaluationNoticeEnter -TargetVmName $VmName
            $evaluationNoticeEnterCount++
            $nextEvaluationNoticeEnter = [datetime]::UtcNow.AddSeconds(60)
        }
    } while ($waiting -and [datetime]::UtcNow -lt $deadline)
    if ($ActivationMode -ne 'KeyboardOnly' -and -not $scope) {
        throw 'WS2003_ACTIVATION_WMI_CONNECTION_TIMEOUT'
    }

    if ($ActivationMode -eq 'KeyboardOnly') {
        if (-not $bootstrapComplete) { throw 'WS2003_BOOTSTRAP_TIMEOUT' }
        $bridgeReceipt = Get-WindowsServer2003OfflineBootstrapReceipt -Path $resolvedChildVhd
        if ([string] $bridgeReceipt.status -ne 'COMPLETED') {
            throw "WS2003_BOOTSTRAP_FAILED: $($bridgeReceipt.errorCode)"
        }
        $activationState = [pscustomobject]@{
            ActivationRequired = [int] $bridgeReceipt.activationRequired
            EvaluationDaysRemaining = [int] $bridgeReceipt.evaluationDaysRemaining
            GraceDaysRemaining = [int] $bridgeReceipt.graceDaysRemaining
        }
    }
    else {
    try {
        $registryScope = Connect-WindowsServer2003WmiScope -Address $guestAddress[0] `
            -Namespace 'root\default' -Credential $AdministratorCredential
        $hkeyUsers = [uint32] 2147483651
        Invoke-WindowsServer2003RegistryString -Scope $registryScope -RootKey $hkeyUsers `
            -SubKey '.DEFAULT\Keyboard Layout\Preload' -Name '1' -Value '00000407'
        Invoke-WindowsServer2003RegistryString -Scope $registryScope -RootKey $hkeyUsers `
            -SubKey '.DEFAULT\Control Panel\International' -Name 'Locale' -Value '00000407'
    }
    catch {
        # StdRegProv on the Windows Server 2003 evaluation image can return the
        # provider-level WBEM_E_CRITICAL_ERROR even though remote process creation
        # is healthy.  reg.exe is the supported NT5 fallback and writes the same
        # logon-desktop values without loading an offline hive on the host.
        try {
            $null = Invoke-WindowsServer2003ProcessThroughWmi -Scope $scope -CommandLine `
                'reg.exe add "HKU\.DEFAULT\Keyboard Layout\Preload" /v 1 /t REG_SZ /d 00000407 /f'
            $null = Invoke-WindowsServer2003ProcessThroughWmi -Scope $scope -CommandLine `
                'reg.exe add "HKU\.DEFAULT\Control Panel\International" /v Locale /t REG_SZ /d 00000407 /f'
        }
        catch {
            throw "WS2003_KEYBOARD_CONFIGURATION_FAILED: $($_.Exception.Message)"
        }
    }

    if ($StaticAddress) {
        try {
            Set-WindowsServer2003StaticAddress -Scope $scope -MacAddress $primaryAdapterMac `
                -Address $StaticAddress -SubnetMask $StaticSubnetMask
        }
        catch {
            throw "WS2003_STATIC_ADDRESS_CONFIGURATION_FAILED: $($_.Exception.Message)"
        }
    }

    try { $activationState = Get-WindowsServer2003ActivationState -Scope $scope }
    catch { throw "WS2003_LICENSE_QUERY_FAILED: $($_.Exception.Message)" }
    if ($ActivationMode -eq 'PrepareOffline' -and $activationState.ActivationRequired -eq 1) {
        $installationResult = Invoke-WindowsServer2003ActivationMethod `
            -Scope $scope -Method GetInstallationID
        $installationId = [string] $installationResult['InstallationID']
        if ($installationId -notmatch '^\d{50}$') {
            throw 'WS2003_OFFLINE_INSTALLATION_ID_INVALID'
        }
    }
    if ($ActivationMode -eq 'CompleteOffline' -and $activationState.ActivationRequired -eq 1) {
        $confirmationIdPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
            $OfflineConfirmationId)
        $confirmationIdPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            $confirmationIdPointer)
        $confirmationIdPlain = $confirmationIdPlain -replace '[\s-]', ''
        if ($confirmationIdPlain -notmatch '^\d{6,100}$') {
            throw 'WS2003_OFFLINE_CONFIRMATION_ID_INVALID'
        }
        $null = Invoke-WindowsServer2003ActivationMethod -Scope $scope `
            -Method ActivateOffline -ConfirmationId $confirmationIdPlain
        $confirmationIdPlain = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($confirmationIdPointer)
        $confirmationIdPointer = [IntPtr]::Zero
        $activationState = Get-WindowsServer2003ActivationState -Scope $scope
    }
    if ($ActivationMode -eq 'Online' -and $activationState.ActivationRequired -eq 1) {
        $null = Invoke-WindowsServer2003ProcessThroughWmi -Scope $scope -CommandLine `
            'C:\Windows\System32\wbem\wmic.exe path Win32_WindowsProductActivation call ActivateOnline'
        $activationDeadline = [datetime]::UtcNow.AddSeconds(180)
        if ($activationDeadline -gt $deadline) { $activationDeadline = $deadline }
        do {
            Start-Sleep -Seconds 5
            $activationState = Get-WindowsServer2003ActivationState -Scope $scope
        } while ($activationState.ActivationRequired -eq 1 -and
            [datetime]::UtcNow -lt $activationDeadline)
    }
    if ($ActivationMode -in @('Online', 'CompleteOffline') -and
        $activationState.ActivationRequired -ne 0) {
        throw "WS2003_ACTIVATION_NOT_COMPLETED: ActivationRequired=$($activationState.ActivationRequired)"
    }
    if ($ActivationMode -in @('Online', 'CompleteOffline') -and
        $activationState.EvaluationDaysRemaining -le 0) {
        throw "WS2003_ACTIVATION_EVALUATION_EXPIRED: EvaluationDaysRemaining=$($activationState.EvaluationDaysRemaining)"
    }

    $null = Invoke-WindowsServer2003ProcessThroughWmi -Scope $scope -CommandLine `
        'C:\Windows\System32\shutdown.exe -s -t 0 -f'
    }
    do {
        Start-Sleep -Seconds 2
        $vm = Get-VM -Name $VmName -ErrorAction Stop
    } while ([string] $vm.State -ne 'Off' -and [datetime]::UtcNow -lt $deadline)
    if ([string] $vm.State -ne 'Off') {
        throw 'WS2003_ACTIVATION_SHUTDOWN_TIMEOUT'
    }
}
catch {
    $primaryError = $_
}
finally {
    $confirmationIdPlain = $null
    if ($confirmationIdPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($confirmationIdPointer)
    }
    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($vm -and [string] $vm.State -ne 'Off' -and $guestStarted) {
        Stop-VM -VM $vm -TurnOff -Force -ErrorAction SilentlyContinue
    }
    if ($adapterCreated) {
        Get-VMNetworkAdapter -VMName $VmName -Name $temporaryAdapterName `
            -ErrorAction SilentlyContinue | Remove-VMNetworkAdapter -ErrorAction SilentlyContinue
    }
}

if ($primaryError) { throw $primaryError }

[pscustomobject]@{
    Status = switch ($ActivationMode) {
        'KeyboardOnly' { 'KEYBOARD_LAYOUT_CONFIGURED' }
        'PrepareOffline' {
            if ($activationState.ActivationRequired -eq 0) { 'EVALUATION_ACTIVE' }
            else { 'OFFLINE_ACTIVATION_PREPARED' }
        }
        default { 'EVALUATION_ACTIVE' }
    }
    VmName = $VmName
    ChildVhdPath = $resolvedChildVhd
    ActivationMode = $ActivationMode
    ActivationMethod = switch ($ActivationMode) {
        'KeyboardOnly' { 'NONE' }
        'PrepareOffline' { 'Win32_WindowsProductActivation.GetInstallationID' }
        'CompleteOffline' { 'Win32_WindowsProductActivation.ActivateOffline' }
        default { 'Win32_WindowsProductActivation.ActivateOnline' }
    }
    InstallationId = $installationId
    InstallationIdDisclosed = $ActivationMode -eq 'PrepareOffline' -and $null -ne $installationId
    ActivationRequired = if ($activationState) { [int] $activationState.ActivationRequired } else { $null }
    EvaluationDaysRemaining = if ($activationState) { [int] $activationState.EvaluationDaysRemaining } else { $null }
    GraceDaysRemaining = if ($activationState) { [int] $activationState.GraceDaysRemaining } else { $null }
    InputLocale = $InputLocale
    LogonKeyboardLayout = '00000407'
    StaticAddress = $StaticAddress
    StaticSubnetMask = if ($StaticAddress) { $StaticSubnetMask } else { $null }
    StaticAddressConfigured = [bool] $StaticAddress
    MiniSetupEvaluationNoticeEnterCount = $evaluationNoticeEnterCount
    TemporaryAdapterRemoved = -not [bool](Get-VMNetworkAdapter -VMName $VmName `
        -Name $temporaryAdapterName -ErrorAction SilentlyContinue)
    VmStopped = [string](Get-VM -Name $VmName -ErrorAction Stop).State -eq 'Off'
    ProductKeyDisclosed = $false
    ConfirmationIdDisclosed = $false
    CredentialDisclosed = $false
}
