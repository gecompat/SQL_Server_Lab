#Requires -Version 7.2
<#
.SYNOPSIS
    Einmaliger echter HTTPS-Stub fuer den KI-Endpoint-Acceptance-Test.
.DESCRIPTION
    Bindet ausschließlich IPv4-Loopback, erzeugt ein flüchtiges selbstsigniertes
    localhost-Zertifikat und persistiert nur dessen öffentlichen Anteil sowie
    sanitisierte Request-Metadaten im vom Aufrufer bereitgestellten Testverzeichnis.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$ReceiptPath,
    [Parameter(Mandatory)][ValidateSet('embedding-retry','generation-success')][string]$Mode
)

$ErrorActionPreference = 'Stop'
$listener = $null
$certificate = $null
$rsa = $null
$requests = [Collections.Generic.List[object]]::new()

function Read-StubHttpRequest {
    param([Parameter(Mandatory)][IO.Stream]$Stream)

    $headerBytes = [Collections.Generic.List[byte]]::new()
    $tail = [Collections.Generic.Queue[byte]]::new()
    while ($true) {
        $value = $Stream.ReadByte()
        if ($value -lt 0) { throw 'AI_HTTPS_STUB_REQUEST_TRUNCATED' }
        $byte = [byte]$value
        $headerBytes.Add($byte)
        $tail.Enqueue($byte)
        if ($tail.Count -gt 4) { $null = $tail.Dequeue() }
        if ($tail.Count -eq 4 -and (@($tail) -join ',') -eq '13,10,13,10') { break }
        if ($headerBytes.Count -gt 32768) { throw 'AI_HTTPS_STUB_HEADER_TOO_LARGE' }
    }

    $headerText = [Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
    $headerLines = @($headerText -split "`r`n")
    $requestLine = @($headerLines[0] -split ' ')
    if ($requestLine.Count -lt 2 -or $requestLine[0] -cne 'POST') { throw 'AI_HTTPS_STUB_REQUEST_INVALID' }
    $contentLengthLine = @($headerLines | Where-Object { $_ -match '^(?i)Content-Length:\s*\d+\s*$' })
    if ($contentLengthLine.Count -ne 1) { throw 'AI_HTTPS_STUB_CONTENT_LENGTH_INVALID' }
    $contentLength = [int](($contentLengthLine[0] -split ':', 2)[1].Trim())
    if ($contentLength -lt 2 -or $contentLength -gt 1048576) { throw 'AI_HTTPS_STUB_BODY_SIZE_INVALID' }
    $bodyBytes = [byte[]]::new($contentLength)
    $offset = 0
    while ($offset -lt $contentLength) {
        $read = $Stream.Read($bodyBytes, $offset, $contentLength - $offset)
        if ($read -le 0) { throw 'AI_HTTPS_STUB_BODY_TRUNCATED' }
        $offset += $read
    }
    $body = [Text.Encoding]::UTF8.GetString($bodyBytes) | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    return [PSCustomObject]@{Path=[string]$requestLine[1];Model=[string]$body.model;HasInput=$null -ne $body.input;HasPrompt=$null -ne $body.prompt}
}

function Write-StubHttpResponse {
    param(
        [Parameter(Mandatory)][IO.Stream]$Stream,
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][string]$Body
    )

    $reason = if ($StatusCode -eq 200) { 'OK' } elseif ($StatusCode -eq 429) { 'Too Many Requests' } else { 'Error' }
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $header = "HTTP/1.1 $StatusCode $reason`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $Stream.Flush()
}

try {
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=localhost', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
    $usage = [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor
        [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment -bor
        [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new($usage, $true))
    $oids = [Security.Cryptography.OidCollection]::new()
    $null = $oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids, $true))
    $san = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $san.AddDnsName('localhost')
    $request.CertificateExtensions.Add($san.Build())
    $generatedCertificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddHours(1))
    try {
        # Windows SslStream cannot use the ephemeral key returned directly by
        # CertificateRequest. Re-import the short-lived PFX into a temporary
        # user key container; disposing this certificate releases that scope.
        $pfxBytes = $generatedCertificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, [string]::Empty)
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $pfxBytes, [string]::Empty,
            [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet -bor
            [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
    }
    finally {
        $generatedCertificate.Dispose()
        $pfxBytes = $null
    }

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $ready = [ordered]@{
        Port = $port
        CertificateSha256 = $certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()
        CertificateBase64 = [Convert]::ToBase64String($certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    }
    [IO.File]::WriteAllText($ReadyPath, ($ready | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))

    $requestCount = if ($Mode -eq 'embedding-retry') { 2 } else { 1 }
    for ($attempt = 1; $attempt -le $requestCount; $attempt++) {
        $client = $listener.AcceptTcpClient()
        try {
            $ssl = [Net.Security.SslStream]::new($client.GetStream(), $false)
            try {
                $ssl.AuthenticateAsServer($certificate, $false, [Security.Authentication.SslProtocols]::Tls12, $false)
                $observed = Read-StubHttpRequest -Stream $ssl
                $requests.Add($observed)
                if ($Mode -eq 'embedding-retry' -and $attempt -eq 1) {
                    Write-StubHttpResponse -Stream $ssl -StatusCode 429 -Body '{}'
                }
                elseif ($Mode -eq 'embedding-retry') {
                    $vector = @(1..768 | ForEach-Object { if ($_ -eq 1) { 1.0 } else { 0.0 } })
                    Write-StubHttpResponse -Stream $ssl -StatusCode 200 -Body ([ordered]@{embeddings=@(,$vector)} | ConvertTo-Json -Depth 5 -Compress)
                }
                else {
                    Write-StubHttpResponse -Stream $ssl -StatusCode 200 -Body '{"response":"SYNTHETIC_OK"}'
                }
            }
            finally { $ssl.Dispose() }
        }
        finally { $client.Dispose() }
    }

    $receipt = [ordered]@{Mode=$Mode;AttemptCount=$requests.Count;Requests=@($requests)}
    [IO.File]::WriteAllText($ReceiptPath, ($receipt | ConvertTo-Json -Depth 10 -Compress), [Text.UTF8Encoding]::new($false))
}
finally {
    if ($listener) { $listener.Stop() }
    if ($certificate) { $certificate.Dispose() }
    if ($rsa) { $rsa.Dispose() }
}
