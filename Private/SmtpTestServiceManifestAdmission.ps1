# Manifest-only admission. No receiver, resource or secret operation is admitted here.
function Read-LabSmtpManifestConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Json)
    $document = $null
    try {
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 100
        $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Skip
        $options.AllowTrailingCommas = $true
        try { $document = [System.Text.Json.JsonDocument]::Parse($Json, $options) }
        catch {
            # Legacy lexical forms (for example single quotes) cannot preserve raw
            # SMTP properties here. Classify only; never admit their normalized config.
            $legacy = $null
            try { $legacy = $Json | ConvertFrom-Json -AsHashtable -Depth 100 }
            catch { return $null } # Existing adapters still own malformed/non-SMTP JSON.
            if ($legacy -is [System.Collections.IDictionary]) {
                foreach ($key in $legacy.Keys) {
                    if ([string]::Equals($key, 'smtpTestService', [StringComparison]::OrdinalIgnoreCase)) {
                        throw 'SMTP_TEST_CONFIG_INVALID'
                    }
                }
            }
            return $null
        }
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $null }
        $matches = @($document.RootElement.EnumerateObject() | Where-Object {
            [string]::Equals($_.Name, 'smtpTestService', [StringComparison]::OrdinalIgnoreCase)
        })
        if ($matches.Count -eq 0) { return $null }
        if ($matches.Count -ne 1 -or $matches[0].Name -cne 'smtpTestService') { throw 'SMTP_TEST_CONFIG_INVALID' }
        if ($matches[0].Value.ValueKind -eq [System.Text.Json.JsonValueKind]::Null) { return $null }
        # Shared raw config reader rejects recursive duplicates before ConvertFrom-Json.
        return ConvertFrom-LabSmtpTestServiceJson -Json $matches[0].Value.GetRawText()
    }
    finally { if ($null -ne $document) { $document.Dispose() }; $matches = $null; $legacy = $null }
}

function Assert-LabSmtpManifestAdmission {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Json)
    $config = Read-LabSmtpManifestConfig -Json $Json
    if ($null -eq $config) { return }
    try {
        try { $manifest = $Json | ConvertFrom-Json -AsHashtable -Depth 100 }
        catch { throw 'SMTP_TEST_SCOPE_UNSUPPORTED' }
        if ($manifest.instances -isnot [array] -or $manifest.instances.Count -lt 1 -or $manifest.instances.Count -gt 64) {
            throw 'SMTP_TEST_SCOPE_UNSUPPORTED'
        }
        $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $provider = $null
        foreach ($instance in $manifest.instances) {
            if ($instance -isnot [System.Collections.IDictionary] -or $instance.id -isnot [string] -or
                [string]::IsNullOrWhiteSpace($instance.id) -or -not $ids.Add($instance.id) -or
                $instance.version -isnot [string]) { throw 'SMTP_TEST_SCOPE_UNSUPPORTED' }
            $effectiveOs = if ($instance.Contains('os')) { $instance.os } else { 'linux' }
            $effectiveProvider = if ($instance.Contains('provider')) { $instance.provider } else {
                Resolve-ProviderAutoSelect -Instance $instance
            }
            if ($effectiveOs -isnot [string] -or $effectiveOs -cne 'linux' -or
                $effectiveProvider -isnot [string] -or $effectiveProvider -cnotin @('docker', 'podman')) {
                throw 'SMTP_TEST_SCOPE_UNSUPPORTED'
            }
            if ($null -ne $provider -and $provider -cne $effectiveProvider) { throw 'SMTP_TEST_SCOPE_UNSUPPORTED' }
            $provider = $effectiveProvider
            try {
                $version = Get-SqlServerVersion -VersionId $instance.version
                $image = Get-SqlServerDockerImage -VersionId $instance.version
                if ($null -eq $version -or $version.id -cne '2025' -or [string]::IsNullOrWhiteSpace($image)) { throw 'SMTP_TEST_SCOPE_UNSUPPORTED' }
            }
            catch { throw 'SMTP_TEST_SCOPE_UNSUPPORTED' }
        }
        foreach ($sender in $config.senderInstanceIds) {
            if (-not $ids.Contains($sender)) { throw 'SMTP_TEST_SCOPE_UNSUPPORTED' }
        }
        # Valid intent is still not executable: native backend acceptance remains open.
        throw 'SMTP_TEST_BACKEND_UNADMITTED'
    }
    finally { $config = $null; $manifest = $null; $image = $null }
}
