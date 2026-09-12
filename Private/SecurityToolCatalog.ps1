function ConvertFrom-LabSecurityToolJsonElement {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Text.Json.JsonElement]$Element)

    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $properties = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $names.Add($property.Name)) { throw 'SECURITY_TOOL_DUPLICATE_FIELD' }
                $properties.Add($property.Name, (ConvertFrom-LabSecurityToolJsonElement -Element $property.Value))
            }
            $result = [ordered]@{}
            foreach ($name in $properties.Keys) { $result[$name] = $properties[$name] }
            return $result
        }
        'Array' {
            $items = [Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) { $items.Add((ConvertFrom-LabSecurityToolJsonElement -Element $item)) }
            return ,$items.ToArray()
        }
        'String' { return $Element.GetString() }
        'Number' { return $Element.GetInt64() }
        'True' { return $true }
        'False' { return $false }
        default { throw 'SECURITY_TOOL_JSON_VALUE_INVALID' }
    }
}

function ConvertFrom-LabSecurityToolJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][ValidateSet('catalog','request','plan')][string]$Kind
    )

    $document = $null
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Json)
        $value = ConvertFrom-LabSecurityToolJsonElement -Element $document.RootElement
        $schemaPath = Join-Path $script:SchemasPath "security-tool-$Kind.schema.json"
        if (-not (Test-Json -Json $Json -SchemaFile $schemaPath -ErrorAction Stop)) { throw 'INVALID' }
        return $value
    }
    catch { throw "SECURITY_TOOL_$($Kind.ToUpperInvariant())_INVALID" }
    finally { if ($document) { $document.Dispose() } }
}

function Get-LabSecurityToolHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)

    # Versionierter Vertrag: ordinale Feldsortierung, UTF-8, kompakte JSON-Werte.
    # Arrays behalten ihre Reihenfolge; Zeit und Eingangspfad werden nicht hinzugefuegt.
    $json = ConvertTo-Json -InputObject $Value -Depth 80 -Compress
    $document = [System.Text.Json.JsonDocument]::Parse($json)
    try { $canonical = ConvertFrom-LabSecurityToolJsonElement -Element $document.RootElement }
    finally { $document.Dispose() }
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $canonical -Depth 80 -Compress))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-LabSecurityToolCatalogJson {
    [CmdletBinding()]
    param()
    try {
        return Get-Content -LiteralPath (Join-Path $script:CatalogsPath 'security-tools.json') -Raw -Encoding utf8 -ErrorAction Stop
    }
    catch { throw 'SECURITY_TOOL_CATALOG_UNAVAILABLE' }
}

function Test-LabSecurityToolTimeWindow {
    [CmdletBinding()]
    param([string]$Start, [string]$End, [datetimeoffset]$At)
    $startTime = [datetimeoffset]::MinValue
    $endTime = [datetimeoffset]::MinValue
    $style = [Globalization.DateTimeStyles]::AssumeUniversal
    $culture = [Globalization.CultureInfo]::InvariantCulture
    return [datetimeoffset]::TryParseExact($Start, "yyyy-MM-dd'T'HH:mm:ss'Z'", $culture, $style, [ref]$startTime) -and
        [datetimeoffset]::TryParseExact($End, "yyyy-MM-dd'T'HH:mm:ss'Z'", $culture, $style, [ref]$endTime) -and
        $startTime -le $At -and $At -lt $endTime
}

function Resolve-LabSecurityToolPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RequestJson,
        [Parameter(Mandatory)][string]$CatalogJson,
        [datetimeoffset]$At = [datetimeoffset]::UtcNow
    )

    $request = ConvertFrom-LabSecurityToolJson -Json $RequestJson -Kind request
    $catalog = ConvertFrom-LabSecurityToolJson -Json $CatalogJson -Kind catalog
    # Doppelte Identitaeten sperren den gesamten Katalog, auch ausserhalb des Requests.
    $toolIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($tool in $catalog.tools) {
        if (-not $toolIds.Add($tool.toolId)) { throw 'SECURITY_TOOL_CATALOG_AMBIGUOUS' }
        $variantIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($variant in $tool.variants) {
            if (-not $variantIds.Add($variant.variantId)) { throw 'SECURITY_TOOL_CATALOG_AMBIGUOUS' }
            foreach ($field in @('purposes','artifacts')) {
                $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                $idField = if ($field -eq 'purposes') { 'purposeId' } else { 'artifactId' }
                foreach ($entry in $variant[$field]) {
                    if (-not $ids.Add($entry[$idField])) { throw 'SECURITY_TOOL_CATALOG_AMBIGUOUS' }
                }
            }
        }
    }

    $blockers = [Collections.Generic.List[string]]::new()
    $selectedTool = @($catalog.tools | Where-Object { $_.toolId -ceq $request.toolId })
    $selectedVariant = @()
    if ($selectedTool.Count -ne 1) { $blockers.Add('UNKNOWN_TOOL') }
    else {
        $selectedVariant = @($selectedTool[0].variants | Where-Object { $_.variantId -ceq $request.variantId })
        if ($selectedVariant.Count -ne 1) { $blockers.Add('UNKNOWN_VARIANT') }
    }
    $artifactCount = 0
    if ($selectedVariant.Count -eq 1) {
        $variant = $selectedVariant[0]
        if (@($variant.purposes | Where-Object { $_.purposeId -ceq $request.purposeId }).Count -ne 1) {
            $blockers.Add('UNKNOWN_PURPOSE')
        }
        $targetHash = Get-LabSecurityToolHash -Value $request.target
        if (@($variant.targets | Where-Object { (Get-LabSecurityToolHash -Value $_) -ceq $targetHash }).Count -ne 1) {
            $blockers.Add('TARGET_NOT_CATALOGED')
        }
        $target = $request.target
        if (-not (($target.os -ceq 'windows' -and $target.provider -ceq 'hyperv' -and $target.distribution -ceq 'windows-server') -or
            ($target.os -ceq 'linux' -and $target.provider -cin @('docker','podman') -and $target.distribution -cne 'windows-server'))) {
            $blockers.Add('TARGET_UNSUPPORTED')
        }
        foreach ($review in @($catalog.policy.review, $variant.review)) {
            if ($review.status -cne 'APPROVED' -or $review.revoked -or
                -not (Test-LabSecurityToolTimeWindow -Start $review.reviewedAt -End $review.validUntil -At $At)) {
                if (-not $blockers.Contains('REVIEW_BLOCKED')) { $blockers.Add('REVIEW_BLOCKED') }
            }
        }
        if (-not $variant.license.localUseAllowed -or $variant.license.reviewedVersion -cne $variant.version -or
            -not (Test-LabSecurityToolTimeWindow -Start $variant.license.reviewedAt -End $variant.review.validUntil -At $At)) {
            $blockers.Add('LICENSE_BLOCKED')
        }
        foreach ($artifact in $variant.artifacts) {
            $trust = $artifact.trust
            $methodAllowed = $trust.signatureMethod -ceq 'signed-release-inventory' -or
                ($target.os -ceq 'windows' -and $trust.signatureMethod -ceq 'authenticode') -or
                ($target.os -ceq 'linux' -and $trust.signatureMethod -ceq 'signed-package-metadata')
            if ($artifact.expectedBytes -gt $artifact.maxBytes -or $trust.policyRevision -cne $catalog.policy.revision -or
                -not $methodAllowed -or $trust.revocation.revoked -or
                -not (Test-LabSecurityToolTimeWindow -Start $trust.revocation.checkedAt -End $trust.revocation.validUntil -At $At)) {
                if (-not $blockers.Contains('TRUST_METADATA_BLOCKED')) { $blockers.Add('TRUST_METADATA_BLOCKED') }
            }
        }
        if ($blockers.Count -eq 0) { $artifactCount = $variant.artifacts.Count }
    }
    $plan = [ordered]@{
        Contract = 'SqlServerLab.SecurityToolPlan/1.0'
        Status = if ($blockers.Count -eq 0) { 'PLANNED' } else { 'BLOCKED' }
        Blockers = $blockers.ToArray()
        Executable = $false
        AuthenticityVerified = $false
        Request = $request
        CatalogRevision = $catalog.revision
        CatalogSha256 = Get-LabSecurityToolHash -Value $catalog
        PolicyRevision = $catalog.policy.revision
        ArtifactCount = $artifactCount
    }
    $plan.PlanHash = Get-LabSecurityToolHash -Value $plan
    return [pscustomobject]$plan
}
