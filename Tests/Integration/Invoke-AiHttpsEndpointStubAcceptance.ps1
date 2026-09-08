#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den echten, zertifikatsgebundenen HTTPS-Pfad des KI-Endpointvertrags.
.DESCRIPTION
    Startet ausschließlich einen flüchtigen IPv4-Loopback-Stub. Geprüft werden
    Custom-Root-Trust ohne globale Zertifikatmutation, exakter Zertifikat-Pin,
    ein realer HTTP-429-Retry sowie Embed- und Generate-Payloads.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$module = $null
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("sql-lab-ai-https-{0}" -f ([Guid]::NewGuid().ToString('N')))
$processes = [Collections.Generic.List[Diagnostics.Process]]::new()
$certificates = [Collections.Generic.List[Security.Cryptography.X509Certificates.X509Certificate2]]::new()
$results = [Collections.Generic.List[object]]::new()

function Add-Result {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Success)
    $results.Add([PSCustomObject]@{Name=$Name;Success=$Success})
    Write-Host "[$(if($Success){'PASS'}else{'FAIL'})] $Name" -ForegroundColor $(if($Success){'Green'}else{'Red'})
}

function Start-HttpsStub {
    param([Parameter(Mandatory)][ValidateSet('embedding-retry','generation-success')][string]$Mode)

    $token = [Guid]::NewGuid().ToString('N')
    $readyPath = Join-Path $temporaryRoot "$token.ready.json"
    $receiptPath = Join-Path $temporaryRoot "$token.receipt.json"
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    foreach ($argument in @(
        '-NoLogo','-NoProfile','-NonInteractive','-File',
        (Join-Path $repoRoot 'Tests/Integration/Support/Invoke-AiHttpsStubServer.ps1'),
        '-ReadyPath',$readyPath,'-ReceiptPath',$receiptPath,'-Mode',$Mode)) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($startInfo)
    $processes.Add($process)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
        if ($process.HasExited) { throw "AI_HTTPS_STUB_START_FAILED: exit $($process.ExitCode)" }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'AI_HTTPS_STUB_START_TIMEOUT' }
        Start-Sleep -Milliseconds 50
    }
    $ready = Get-Content -LiteralPath $readyPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        [Convert]::FromBase64String([string]$ready.CertificateBase64))
    $certificates.Add($certificate)
    return [PSCustomObject]@{Process=$process;Ready=$ready;ReceiptPath=$receiptPath;Certificate=$certificate}
}

function Wait-HttpsStub {
    param([Parameter(Mandatory)]$Stub)
    if (-not $Stub.Process.WaitForExit(15000)) { throw 'AI_HTTPS_STUB_COMPLETION_TIMEOUT' }
    if ($Stub.Process.ExitCode -ne 0) { throw "AI_HTTPS_STUB_FAILED: exit $($Stub.Process.ExitCode)" }
    if (-not (Test-Path -LiteralPath $Stub.ReceiptPath -PathType Leaf)) { throw 'AI_HTTPS_STUB_RECEIPT_MISSING' }
    return Get-Content -LiteralPath $Stub.ReceiptPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
}

try {
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
    if (-not $resolvedTemporaryRoot.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'AI_HTTPS_STUB_TEMP_SCOPE_INVALID' }
    $null = New-Item -Path $temporaryRoot -ItemType Directory
    $module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop

    $embeddingStub = Start-HttpsStub -Mode embedding-retry
    $embeddingRun = & $module {
        param($Port,$Pin,$Certificate)
        $plan = New-LabAiEndpointPlan -ModelKey ollama-embeddinggemma-300m-q4 -EndpointRef deterministic-https-stub `
            -Lane stub -StubBaseUri "https://localhost:$Port" -StubServerCertificateSha256 $Pin -RetryCount 1 -TimeoutSeconds 10
        $result = Invoke-LabAiEndpointRequest -Plan $plan -InputText 'synthetic acceptance input' -TrustedServerCertificate $Certificate
        [PSCustomObject]@{Plan=$plan;Result=$result}
    } ([int]$embeddingStub.Ready.Port) ([string]$embeddingStub.Ready.CertificateSha256) $embeddingStub.Certificate
    $embeddingReceipt = Wait-HttpsStub -Stub $embeddingStub
    Add-Result 'Echter HTTPS-Embedding-Aufruf verwendet exakten Zertifikat-Pin und begrenzten 429-Retry' (
        $embeddingRun.Plan.Status -eq 'NOT_PROBED' -and $embeddingRun.Plan.TargetHost -eq 'localhost' -and
        $embeddingRun.Plan.ServerCertificateSha256 -eq [string]$embeddingStub.Ready.CertificateSha256 -and
        $embeddingRun.Result.Status -eq 'SUCCEEDED' -and $embeddingRun.Result.Attempts -eq 2 -and
        @($embeddingRun.Result.Vector).Count -eq 768 -and $embeddingReceipt.AttemptCount -eq 2)
    Add-Result 'HTTPS-Stub beobachtet ausschließlich den katalogisierten Embed-Pfad und Modellnamen' (
        @($embeddingReceipt.Requests | Where-Object { $_.Path -ne '/api/embed' -or -not $_.HasInput -or $_.HasPrompt }).Count -eq 0 -and
        @($embeddingReceipt.Requests | Select-Object -ExpandProperty Model -Unique).Count -eq 1)

    $generationStub = Start-HttpsStub -Mode generation-success
    $generationRun = & $module {
        param($Port,$Pin,$Certificate)
        $plan = New-LabAiEndpointPlan -ModelKey ollama-gemma3-1b-local -EndpointRef deterministic-https-stub `
            -Lane stub -StubBaseUri "https://localhost:$Port" -StubServerCertificateSha256 $Pin -RetryCount 0 -TimeoutSeconds 10
        $result = Invoke-LabAiEndpointRequest -Plan $plan -InputText 'synthetic acceptance prompt' -TrustedServerCertificate $Certificate
        [PSCustomObject]@{Plan=$plan;Result=$result}
    } ([int]$generationStub.Ready.Port) ([string]$generationStub.Ready.CertificateSha256) $generationStub.Certificate
    $generationReceipt = Wait-HttpsStub -Stub $generationStub
    Add-Result 'Echter HTTPS-Generation-Aufruf erfüllt den gemeinsamen Antwortvertrag' (
        $generationRun.Result.Status -eq 'SUCCEEDED' -and $generationRun.Result.Text -eq 'SYNTHETIC_OK' -and
        $generationReceipt.AttemptCount -eq 1 -and $generationReceipt.Requests[0].Path -eq '/api/generate' -and
        $generationReceipt.Requests[0].HasPrompt -and -not $generationReceipt.Requests[0].HasInput)

    $pinMismatchRejected = $false
    try {
        & $module {
            param($Port,$Certificate)
            $plan = New-LabAiEndpointPlan -ModelKey ollama-gemma3-1b-local -EndpointRef deterministic-https-stub `
                -Lane stub -StubBaseUri "https://localhost:$Port" `
                -StubServerCertificateSha256 '0000000000000000000000000000000000000000000000000000000000000000' -RetryCount 0
            Invoke-LabAiEndpointRequest -Plan $plan -InputText 'must not be sent' -TrustedServerCertificate $Certificate
        } ([int]$generationStub.Ready.Port) $generationStub.Certificate
    }
    catch { $pinMismatchRejected = $_.Exception.Message -eq 'AI_ENDPOINT_TLS_CERTIFICATE_MISMATCH' }
    Add-Result 'Abweichender Zertifikat-Pin scheitert vor einem Netzwerkrequest fail-closed' $pinMismatchRejected

    if (@($results | Where-Object { -not $_.Success }).Count -gt 0) { throw 'AI_HTTPS_ENDPOINT_STUB_ACCEPTANCE_FAILED' }
    Write-Host "AI HTTPS endpoint stub acceptance: $($results.Count) PASS" -ForegroundColor Green
}
finally {
    foreach ($process in $processes) {
        if ($process -and -not $process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(5000) }
        if ($process) { $process.Dispose() }
    }
    foreach ($certificate in $certificates) { if ($certificate) { $certificate.Dispose() } }
    if ($module) { Remove-Module $module -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $temporaryRoot) {
        $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
        if ($resolvedTemporaryRoot.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
        }
    }
}
