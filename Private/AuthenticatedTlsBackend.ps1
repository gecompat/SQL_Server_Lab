#Requires -Version 7.2
# Reine API-Metadaten; kein Konstruktor-/Kryptoaufruf und keine Autorisierung.

function Test-LabTlsBackendApi {
    param([type]$Owner, [string]$Name, [type[]]$Parameters, [type]$ReturnType, [bool]$Static, [switch]$Constructor)
    if ($null -eq $Owner -or $null -eq $Parameters) { return $false }
    $flags = [Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::DeclaredOnly
    $flags = $flags -bor $(if ($Static -and -not $Constructor) { [Reflection.BindingFlags]::Static } else { [Reflection.BindingFlags]::Instance })
    $member = if ($Constructor) { $Owner.GetConstructor($flags, $null, $Parameters, $null) }
        else { $Owner.GetMethod($Name, $flags, $null, $Parameters, $null) }
    if ($null -eq $member -or $member.ContainsGenericParameters) { return $false }
    # Der Reflection-Binder darf keine passenden Basistypen/Zahlenkonversionen ersetzen.
    $actual = $member.GetParameters()
    if ($actual.Length -ne $Parameters.Length) { return $false }
    for ($index=0; $index -lt $Parameters.Length; $index++) {
        if ($actual[$index].ParameterType -ne $Parameters[$index]) { return $false }
    }
    return $Constructor -or $member.ReturnType -eq $ReturnType
}

function Get-LabAuthenticatedTlsBackendMetadata {
    [CmdletBinding()]
    param([object]$Context)

    $rejected = [pscustomobject][ordered]@{ Success = $false; Value = $null; ErrorCode = 'TLS_BACKEND_CONTEXT_INVALID' }
    if ($Context -isnot [string] -or -not [string]::Equals($Context, 'CURRENT_PROCESS', [StringComparison]::Ordinal)) { return $rejected }
    try {
        $requestType = [Security.Cryptography.X509Certificates.CertificateRequest]
        $sanType = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]
        # Der Typ fehlt auf aelteren CLRs. Keine statische Referenz, kein Download/Fallback.
        $loadOptions = $requestType.Assembly.GetType('System.Security.Cryptography.X509Certificates.CertificateRequestLoadOptions', $false, $false)
        $hasLoad = $false
        if ($null -ne $loadOptions) {
            $hasLoad = Test-LabTlsBackendApi -Owner $requestType -Name LoadSigningRequest -Static $true -ReturnType $requestType -Parameters @(
                [byte[]], [Security.Cryptography.HashAlgorithmName], $loadOptions, [Security.Cryptography.RSASignaturePadding])
        }
        $apis = @(
            [pscustomobject][ordered]@{ Id='REQUEST_RSA_CONSTRUCTOR'; Present=(Test-LabTlsBackendApi -Owner $requestType -Constructor -Parameters @(
                [string], [Security.Cryptography.RSA], [Security.Cryptography.HashAlgorithmName], [Security.Cryptography.RSASignaturePadding])) }
            [pscustomobject][ordered]@{ Id='CSR_CREATE_DER'; Present=(Test-LabTlsBackendApi -Owner $requestType -Name CreateSigningRequest -Parameters @() -ReturnType ([byte[]]) -Static $false) }
            [pscustomobject][ordered]@{ Id='CSR_LOAD_DER'; Present=$hasLoad }
            [pscustomobject][ordered]@{ Id='CERTIFICATE_CREATE'; Present=(Test-LabTlsBackendApi -Owner $requestType -Name Create -Parameters @(
                [Security.Cryptography.X509Certificates.X509Certificate2], [DateTimeOffset], [DateTimeOffset], [byte[]]) -ReturnType ([Security.Cryptography.X509Certificates.X509Certificate2]) -Static $false) }
            [pscustomobject][ordered]@{ Id='SAN_IP'; Present=(Test-LabTlsBackendApi -Owner $sanType -Name AddIpAddress -Parameters @([Net.IPAddress]) -ReturnType ([void]) -Static $false) }
            [pscustomobject][ordered]@{ Id='SAN_DNS'; Present=(Test-LabTlsBackendApi -Owner $sanType -Name AddDnsName -Parameters @([string]) -ReturnType ([void]) -Static $false) }
        )
        $platform = if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { 'windows' }
            elseif ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)) { 'linux' } else { 'other' }
        $complete = @($apis | Where-Object { -not $_.Present }).Count -eq 0
        $value = [pscustomobject][ordered]@{
            ContractVersion='SqlServerLab.AuthenticatedTlsBackendMetadata/0.1'; Context='CURRENT_PROCESS'; Backend='DOTNET_X509'
            Status='METADATA_ONLY'; Platform=$platform; RuntimeVersion=([string]::Format('{0}', [Environment]::Version))
            ApiStatus=$(if ($complete) { 'COMPLETE' } else { 'INCOMPLETE' }); Apis=$apis
            RegistrationStatus='NOT_EVALUATED'; KeyProtectionStatus='NOT_EXECUTED'; SigningStatus='NOT_EXECUTED'
            ClientStatus='NOT_EVALUATED'; Ready=$false; MutationAllowed=$false
        }
        return [pscustomobject][ordered]@{ Success=$true; Value=$value; ErrorCode=$null }
    }
    catch {
        $rejected.ErrorCode='TLS_BACKEND_METADATA_UNAVAILABLE'; return $rejected
    }
}
