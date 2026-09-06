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

.PARAMETER KeyboardLayoutOnly
Setzt nur das deutsche Login-Layout; die Aktivierung wird nicht aufgerufen.

.PARAMETER TimeoutSeconds
Maximale Gesamtdauer für Boot, WMI-Verbindung und Online-Aktivierung.

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

    [ValidateSet('0407:00000407')]
    [string] $InputLocale = '0407:00000407',

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

$action = if ($KeyboardLayoutOnly) {
    "deutsches Login-Layout über temporären Switch '$ActivationSwitchName' setzen"
}
else {
    "Evaluation über temporären Switch '$ActivationSwitchName' online aktivieren und deutsches Login-Layout setzen"
}
if (-not $PSCmdlet.ShouldProcess($VmName, $action)) {
    return [pscustomobject]@{
        Status = 'PLANNED'
        VmName = $VmName
        ChildVhdPath = $resolvedChildVhd
        ActivationSwitchName = $ActivationSwitchName
        TemporaryAdapterName = $temporaryAdapterName
        ActivationMethod = if ($KeyboardLayoutOnly) { 'NONE' } else {
            'Win32_WindowsProductActivation.ActivateOnline'
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
        $options.Authentication = [System.Management.AuthenticationLevel]::Packet
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

$adapterCreated = $false
$guestStarted = $false
$primaryError = $null
$activationState = $null
try {
    Add-VMNetworkAdapter -VMName $VmName -Name $temporaryAdapterName `
        -SwitchName $ActivationSwitchName -IsLegacy $true -ErrorAction Stop | Out-Null
    $adapterCreated = $true
    Start-VM -Name $VmName -ErrorAction Stop | Out-Null
    $guestStarted = $true

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $scope = $null
    do {
        Start-Sleep -Seconds 3
        $adapter = Get-VMNetworkAdapter -VMName $VmName -Name $temporaryAdapterName `
            -ErrorAction SilentlyContinue
        $guestAddress = @($adapter.IPAddresses | Where-Object {
            $_ -match '^\d{1,3}(?:\.\d{1,3}){3}$' -and $_ -notlike '169.254.*'
        } | Select-Object -First 1)
        if ($guestAddress) {
            try {
                $scope = Connect-WindowsServer2003WmiScope -Address $guestAddress[0] `
                    -Namespace 'root\cimv2' -Credential $AdministratorCredential
            }
            catch { $scope = $null }
        }
    } while (-not $scope -and [datetime]::UtcNow -lt $deadline)
    if (-not $scope) {
        throw 'WS2003_ACTIVATION_WMI_CONNECTION_TIMEOUT'
    }

    $registryScope = Connect-WindowsServer2003WmiScope -Address $guestAddress[0] `
        -Namespace 'root\default' -Credential $AdministratorCredential
    $hkeyUsers = [uint32] 2147483651
    Invoke-WindowsServer2003RegistryString -Scope $registryScope -RootKey $hkeyUsers `
        -SubKey '.DEFAULT\Keyboard Layout\Preload' -Name '1' -Value '00000407'
    Invoke-WindowsServer2003RegistryString -Scope $registryScope -RootKey $hkeyUsers `
        -SubKey '.DEFAULT\Control Panel\International' -Name 'Locale' -Value '00000407'

    $activationState = Get-WindowsServer2003ActivationState -Scope $scope
    if (-not $KeyboardLayoutOnly -and $activationState.ActivationRequired -eq 1) {
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
    if (-not $KeyboardLayoutOnly -and $activationState.ActivationRequired -ne 0) {
        throw "WS2003_ACTIVATION_NOT_COMPLETED: ActivationRequired=$($activationState.ActivationRequired)"
    }
    if (-not $KeyboardLayoutOnly -and $activationState.EvaluationDaysRemaining -le 0) {
        throw "WS2003_ACTIVATION_EVALUATION_EXPIRED: EvaluationDaysRemaining=$($activationState.EvaluationDaysRemaining)"
    }

    $null = Invoke-WindowsServer2003ProcessThroughWmi -Scope $scope -CommandLine `
        'C:\Windows\System32\shutdown.exe -s -t 0 -f'
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
    Status = if ($KeyboardLayoutOnly) { 'KEYBOARD_LAYOUT_CONFIGURED' } else { 'EVALUATION_ACTIVE' }
    VmName = $VmName
    ChildVhdPath = $resolvedChildVhd
    ActivationMethod = if ($KeyboardLayoutOnly) { 'NONE' } else {
        'Win32_WindowsProductActivation.ActivateOnline'
    }
    ActivationRequired = if ($activationState) { [int] $activationState.ActivationRequired } else { $null }
    EvaluationDaysRemaining = if ($activationState) { [int] $activationState.EvaluationDaysRemaining } else { $null }
    GraceDaysRemaining = if ($activationState) { [int] $activationState.GraceDaysRemaining } else { $null }
    InputLocale = $InputLocale
    LogonKeyboardLayout = '00000407'
    TemporaryAdapterRemoved = -not [bool](Get-VMNetworkAdapter -VMName $VmName `
        -Name $temporaryAdapterName -ErrorAction SilentlyContinue)
    VmStopped = [string](Get-VM -Name $VmName -ErrorAction Stop).State -eq 'Off'
    ProductKeyDisclosed = $false
    CredentialDisclosed = $false
}
