function Read-LabGuidedExternalModelFile {
    param([string]$Path)

    $stream = $null
    $bytes = $null
    try {
        $verifiedPath = Resolve-LabAiSharedGatewayGuidedInputPath -Path $Path
        $stream = [IO.File]::Open($verifiedPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $size = $stream.Length
        if ($size -lt 1 -or $size -gt 32768) { throw 'Input size outside the supported range' }
        $bytes = [byte[]]::new([int]$size)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes,$offset,$bytes.Length-$offset)
            if (-not $read) { throw 'Input changed while reading' }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1) { throw 'Input changed while reading' }
        return [Text.UTF8Encoding]::new($false,$true).GetString($bytes).TrimStart([char]0xfeff)
    } catch { throw 'AI_EXTERNAL_MODEL_GUIDED_FILE_INVALID' }
    finally {
        if ($stream) { $stream.Dispose() }
        if ($null -ne $bytes) { [Array]::Clear($bytes,0,$bytes.Length) }
    }
}

function New-LabGuidedExternalModelRootCertificate {
    param([string]$Pem)
    if (-not $Pem) { return }
    if ($Pem.Length -gt 32768 -or $Pem.Trim() -cnotmatch
        '\A-----BEGIN CERTIFICATE-----\r?\n(?:[A-Za-z0-9+/=]+\r?\n)+-----END CERTIFICATE-----\z') {
        throw 'AI_EXTERNAL_MODEL_GUIDED_CA_INVALID'
    }
    $certificate = $null
    try {
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($Pem)
        $ca = @($certificate.Extensions | Where-Object {$_.Oid.Value -ceq '2.5.29.19'})
        if ($ca.Count -ne 1 -or $ca[0] -isnot [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] -or
            -not $ca[0].CertificateAuthority) { throw 'Expected one CA certificate' }
        return $certificate
    } catch {
        if ($certificate) { $certificate.Dispose() }
        throw 'AI_EXTERNAL_MODEL_GUIDED_CA_INVALID'
    }
}

function Invoke-LabGuidedExternalModelEndpoint {
    param([Parameter(Mandatory)]$Plan,[Security.Cryptography.X509Certificates.X509Certificate2]$TrustedRootCertificate,
        [Security.SecureString]$ApiKey)

    $canonical = Resolve-LabAiExternalModelPlan -Plan $Plan
    $parameters = @{Plan=$canonical}
    if ($TrustedRootCertificate) { $parameters.TrustedRootCertificate=$TrustedRootCertificate }
    if ($ApiKey -and $ApiKey.Length) {
        if ($ApiKey.Length -gt 4096) { throw 'AI_EXTERNAL_MODEL_GUIDED_KEY_INVALID' }
        $parameters.ApiKey=$ApiKey
    }
    $results = @(Test-SqlServerLabAiExternalModelEndpoint @parameters)
    if ($results.Count -ne 1) { throw 'AI_EXTERNAL_MODEL_GUIDED_RESULT_UNCONFIRMED' }
    $receipt = $results[0]
    $null = Resolve-LabAiExternalModelEndpointReceipt -Plan $canonical -EndpointReceipt $receipt
    [pscustomobject][ordered]@{
        Contract=[pscustomobject]@{Name='SqlServerLab.AiExternalModelEndpointReceipt';Version='1.0'}
        Status='ENDPOINT_VERIFIED';EvidenceStatus='LIVE_ENDPOINT';PlanKey=$canonical.PlanKey;Backend=$canonical.Backend
        Dimension=$canonical.Dimension;HttpStatus=[int]$receipt.HttpStatus;ServerCertificateSha256=$canonical.ServerCertificateSha256
        DurationMilliseconds=[long]$receipt.DurationMilliseconds;VerifiedAtUtc=[string]$receipt.VerifiedAtUtc
        ReceiptKey=[string]$receipt.ReceiptKey;VerifiedEvidence=@($receipt.VerifiedEvidence);PendingEvidence=@($receipt.PendingEvidence)
    }
}

function Invoke-LabGuidedExternalModelEndpointInteractive {
    param($PreparedPlan)

    $key = $null
    $certificate = $null
    try {
        if (-not $PreparedPlan) {
            $planPath = Read-LabConsoleTextInput -Prompt 'Absoluter lokaler Pfad zum External-Model-Plan (JSON)' -MaskInput
            if ($planPath.Status -cne 'Confirmed') { return }
            $PreparedPlan = (Read-LabGuidedExternalModelFile -Path $planPath.Value) | ConvertFrom-Json -Depth 8 -ErrorAction Stop
        }
        $plan = Resolve-LabAiExternalModelPlan -Plan $PreparedPlan
        Write-LabInfo ("{0} · Modell {1} · Dimension {2} · {3}" -f $plan.Backend,$plan.RuntimeModel,$plan.Dimension,$plan.Location)
        if (-not (Read-LabConfirm -Prompt 'Genau eine synthetische Embedding-Anfrage an diesen lokalen HTTPS-Endpunkt senden?' -Default $false)) { return }
        $rootPath = Read-LabConsoleTextInput -Prompt 'Optionaler absoluter Pfad zum öffentlichen CA-PEM (leer für Systemvertrauen)' -MaskInput
        if ($rootPath.Status -cne 'Confirmed') { return }
        if ($rootPath.Value) {
            $certificate = New-LabGuidedExternalModelRootCertificate -Pem (Read-LabGuidedExternalModelFile -Path $rootPath.Value)
        }
        $entered = Read-LabConsoleTextInput -Prompt 'Optionaler API-Schlüssel (maskiert, leer für keinen Schlüssel)' -AsSecureString
        if ($entered.Status -cne 'Confirmed') { return }
        if ($entered.Value -isnot [Security.SecureString]) { throw 'AI_EXTERNAL_MODEL_GUIDED_KEY_INVALID' }
        $key = $entered.Value
        $receipt = Invoke-LabGuidedExternalModelEndpoint -Plan $plan -TrustedRootCertificate $certificate -ApiKey $key
        Write-LabInfo ($receipt | ConvertTo-Json -Depth 8)
    } catch [Management.Automation.PipelineStoppedException] { throw }
    catch {
        Write-LabWarning 'Endpunktprüfung nicht bestätigt. Prüfe den Plan, den lokalen Dienst, Zertifikat und optionalen Schlüssel.'
    } finally {
        if ($certificate) { $certificate.Dispose() }
        if ($key) { $key.Dispose() }
    }
    $null = Wait-LabConsoleAcknowledgement
}

function Invoke-LabGuidedExternalModelEndpointHttp {
    param([string]$Body)

    if (-not $Body -or [Text.Encoding]::UTF8.GetByteCount($Body) -gt 65536) { throw 'AI_EXTERNAL_MODEL_GUIDED_REQUEST_INVALID' }
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 8
    $document = [Text.Json.JsonDocument]::Parse($Body,$options)
    $key = $null
    $certificate = $null
    try {
        $shape = @{Plan=[Text.Json.JsonValueKind]::Object; Confirmed=[Text.Json.JsonValueKind]::True
            TrustedRootPem=[Text.Json.JsonValueKind]::String; ApiKeyReference=[Text.Json.JsonValueKind]::String}
        $values = ConvertFrom-LabAiSharedGatewayFormObject -Object $document.RootElement -Fields $shape
        $plan = Resolve-LabAiExternalModelPlan -Plan ($values.Plan.GetRawText() | ConvertFrom-Json -Depth 8 -ErrorAction Stop)
        $certificate = New-LabGuidedExternalModelRootCertificate -Pem $values.TrustedRootPem.GetString()
        $reference = $values.ApiKeyReference.GetString()
        if ($reference) {
            if ($reference -cnotmatch '^SQL_SERVER_LAB_SECRET_[A-Z0-9_]{1,96}$') { throw 'AI_EXTERNAL_MODEL_GUIDED_REQUEST_INVALID' }
            $vault = Get-Command -Name Get-Secret -ErrorAction SilentlyContinue
            if (-not $vault) { throw 'AI_EXTERNAL_MODEL_GUIDED_VAULT_UNAVAILABLE' }
            try { $valuesFromVault = @(& $vault -Name $reference -ErrorAction Stop 3>$null 4>$null 5>$null 6>$null) }
            catch { throw 'AI_EXTERNAL_MODEL_GUIDED_VAULT_UNAVAILABLE' }
            if ($valuesFromVault.Count -ne 1 -or $valuesFromVault[0] -isnot [Security.SecureString] -or
                $valuesFromVault[0].Length -lt 1 -or $valuesFromVault[0].Length -gt 4096) { throw 'AI_EXTERNAL_MODEL_GUIDED_KEY_INVALID' }
            $key = $valuesFromVault[0].Copy()
        }
        Invoke-LabGuidedExternalModelEndpoint -Plan $plan -TrustedRootCertificate $certificate -ApiKey $key
    } finally {
        $document.Dispose()
        if ($certificate) { $certificate.Dispose() }
        if ($key) { $key.Dispose() }
    }
}
