function Get-SqlServerLabGeneratedWindowsAccess {
    <#
    .SYNOPSIS
        Liefert den generierten Windows-Administratorzugang eines Hyper-V-Labs.
    .DESCRIPTION
        Entschlüsselt ausschließlich ein automatisch erzeugtes, run-lokal
        DPAPI-geschütztes Windows-Administratorpasswort. Benutzerdefinierte
        Passwörter werden von diesem Befehl nicht ausgegeben. Normale Status-,
        Katalog- und Poolausgaben enthalten das Passwort nicht.
    .PARAMETER RunId
        Run-ID des Windows- oder SQL-Hyper-V-Labs.
    .PARAMETER StateRoot
        Optionaler abweichender State Root.
    .OUTPUTS
        PSCustomObject mit RunId, VMName, UserName und Password.
    .EXAMPLE
        Get-SqlServerLabGeneratedWindowsAccess -RunId 01234567-89ab-cdef-0123-456789abcdef
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot
    )

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    if ([string]$lab.Instance.oobeAutomation.passwordSource -ne 'generated') {
        throw 'HYPERV_LAB_GENERATED_WINDOWS_ACCESS_NOT_APPLICABLE'
    }
    $password = Get-LabSecret -Path $lab.RunDirectory -Name 'generated-windows-administrator-password'
    if (-not $password) {
        $password = Get-LabSecret -Path $lab.RunDirectory -Name 'guest-administrator-password'
    }
    if (-not $password) {
        throw 'HYPERV_LAB_GENERATED_WINDOWS_ACCESS_NOT_FOUND'
    }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
    try {
        return [PSCustomObject]@{
            RunId = [string]$lab.Run.runId
            VMName = [string]$lab.Instance.vmName
            UserName = 'Administrator'
            Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            Generated = $true
            Persisted = $true
        }
    }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
