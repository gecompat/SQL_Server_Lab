#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
$script:CatalogsPath = Join-Path $repoRoot 'Catalogs'
$script:SchemasPath = Join-Path $repoRoot 'Schemas'
. (Join-Path $repoRoot 'Private/SecurityToolCatalog.ps1')
. (Join-Path $repoRoot 'Public/Get-SqlServerLabSecurityToolPlan.ps1')
$fixtureJson = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Fixtures/SecurityTools/catalog.json') -Raw
$request = [ordered]@{
    contract='SqlServerLab.SecurityToolRequest/1.0'; toolId='synthetic-tool'; variantId='synthetic-linux'; purposeId='sql-tls'
    target=[ordered]@{ sqlVersion='2025'; os='linux'; distribution='synthetic-linux'; osVersion='1.0'; architecture='x64'; provider='docker' }
}
$requestJson = $request | ConvertTo-Json -Depth 20 -Compress
$at = [datetimeoffset]'2026-06-01T00:00:00Z'

function Get-Fixture { return ConvertFrom-LabSecurityToolJson -Json $fixtureJson -Kind catalog }
function Get-Request { return ConvertFrom-LabSecurityToolJson -Json $requestJson -Kind request }
function Test-Rejected {
    param([scriptblock]$Action)
    try { $null = & $Action; return $false }
    catch { return $_.Exception.Message -cmatch '^SECURITY_TOOL_(CATALOG|REQUEST|PLAN)_(INVALID|AMBIGUOUS)$' }
}
function Test-ClosedObject {
    param([object]$Value, [string]$Kind, [object]$Root, [string]$Path = 'root')
    if ($Value -is [Collections.IDictionary]) {
        $Value['unexpectedField'] = 'synthetic'
        Add-CheckResult -Name "Geschlossene Felder: $Kind $Path" -Success (Test-Rejected {
            ConvertFrom-LabSecurityToolJson -Json (ConvertTo-Json -InputObject $Root -Depth 80) -Kind $Kind
        })
        $Value.Remove('unexpectedField')
        foreach ($key in @($Value.Keys)) { Test-ClosedObject -Value $Value[$key] -Kind $Kind -Root $Root -Path "$Path.$key" }
    }
    elseif ($Value -is [array]) {
        for ($i=0; $i -lt $Value.Count; $i++) { Test-ClosedObject -Value $Value[$i] -Kind $Kind -Root $Root -Path "$Path[$i]" }
    }
}

$production = ConvertFrom-LabSecurityToolJson -Json (Get-LabSecurityToolCatalogJson) -Kind catalog
Add-CheckResult -Name 'Produktive Allowlist ist schema-valide und leer' -Success ($production.tools.Count -eq 0 -and $production.policy.review.status -ceq 'BLOCKED')
$public = Get-SqlServerLabSecurityToolPlan -ToolId synthetic-tool -VariantId synthetic-linux -PurposeId sql-tls -Target $request.target
Add-CheckResult -Name 'Direktaufruf blockiert bei leerer produktiver Allowlist' -Success ($public.Status -ceq 'BLOCKED' -and $public.Blockers -contains 'UNKNOWN_TOOL' -and -not $public.Executable)

foreach ($provider in @('docker','podman','hyperv')) {
    $inputRequest = Get-Request
    if ($provider -eq 'hyperv') {
        $inputRequest.variantId = 'synthetic-windows'
        $inputRequest.target = (Get-Fixture).tools[0].variants[1].targets[0]
    }
    else { $inputRequest.target.provider = $provider }
    $plan = Resolve-LabSecurityToolPlan -RequestJson ($inputRequest | ConvertTo-Json -Depth 20) -CatalogJson $fixtureJson -At $at
    Add-CheckResult -Name "Synthetische exakte Zielbindung $provider ohne Ausfuehrungsautoritaet" -Success (
        $plan.Status -ceq 'PLANNED' -and $plan.ArtifactCount -eq 1 -and -not $plan.Executable -and -not $plan.AuthenticityVerified -and $plan.Blockers.Count -eq 0)
    $null = ConvertFrom-LabSecurityToolJson -Json ($plan | ConvertTo-Json -Depth 30) -Kind plan
}

foreach ($case in @(
    @{Field='toolId';Value='unknown-tool';Code='UNKNOWN_TOOL'},
    @{Field='variantId';Value='unknown-variant';Code='UNKNOWN_VARIANT'},
    @{Field='purposeId';Value='unknown-purpose';Code='UNKNOWN_PURPOSE'},
    @{Field='sqlVersion';Value='2022';Code='TARGET_NOT_CATALOGED'},
    @{Field='os';Value='windows';Code='TARGET_NOT_CATALOGED'},
    @{Field='distribution';Value='unknown-linux';Code='TARGET_NOT_CATALOGED'},
    @{Field='osVersion';Value='2.0';Code='TARGET_NOT_CATALOGED'},
    @{Field='architecture';Value='arm64';Code='TARGET_NOT_CATALOGED'},
    @{Field='provider';Value='hyperv';Code='TARGET_NOT_CATALOGED'}
)) {
    $inputRequest = Get-Request
    if ($inputRequest.Contains($case.Field)) { $inputRequest[$case.Field] = $case.Value }
    else { $inputRequest.target[$case.Field] = $case.Value }
    $plan = Resolve-LabSecurityToolPlan -RequestJson ($inputRequest | ConvertTo-Json -Depth 20) -CatalogJson $fixtureJson -At $at
    Add-CheckResult -Name "Unbekannte oder abweichende Bindung: $($case.Field)" -Success ($plan.Status -ceq 'BLOCKED' -and $plan.Blockers -contains $case.Code -and $plan.ArtifactCount -eq 0)
}
foreach ($invalid in @('*','latest','Synthetic-tool',' tool','tool/path',"tool`n")) {
    $inputRequest = Get-Request; $inputRequest.toolId = $invalid
    Add-CheckResult -Name 'Freie oder nicht exakte ID wird abgewiesen' -Success (Test-Rejected {
        Resolve-LabSecurityToolPlan -RequestJson ($inputRequest | ConvertTo-Json -Depth 20) -CatalogJson $fixtureJson -At $at
    })
}
foreach ($case in @(
    @{Name='Reviewstatus'; Edit={param($c) $c.tools[0].variants[0].review.status='BLOCKED'}; Code='REVIEW_BLOCKED'},
    @{Name='Retired'; Edit={param($c) $c.tools[0].variants[0].review.status='RETIRED'}; Code='REVIEW_BLOCKED'},
    @{Name='Widerrufen'; Edit={param($c) $c.policy.review.revoked=$true}; Code='REVIEW_BLOCKED'},
    @{Name='Abgelaufen'; Edit={param($c) $c.policy.review.validUntil='2026-06-01T00:00:00Z'}; Code='REVIEW_BLOCKED'},
    @{Name='Zukuenftig'; Edit={param($c) $c.policy.review.reviewedAt='2026-07-01T00:00:00Z'}; Code='REVIEW_BLOCKED'},
    @{Name='Ungueltiges Datum'; Edit={param($c) $c.policy.review.reviewedAt='2026-02-31T00:00:00Z'}; Code='REVIEW_BLOCKED'},
    @{Name='Lizenz'; Edit={param($c) $c.tools[0].variants[0].license.localUseAllowed=$false}; Code='LICENSE_BLOCKED'},
    @{Name='Lizenzversion'; Edit={param($c) $c.tools[0].variants[0].license.reviewedVersion='2.0.0'}; Code='LICENSE_BLOCKED'},
    @{Name='Policybindung'; Edit={param($c) $c.tools[0].variants[0].artifacts[0].trust.policyRevision='different'}; Code='TRUST_METADATA_BLOCKED'},
    @{Name='Laengenlimit'; Edit={param($c) $c.tools[0].variants[0].artifacts[0].maxBytes=1}; Code='TRUST_METADATA_BLOCKED'},
    @{Name='Signaturplattform'; Edit={param($c) $c.tools[0].variants[0].artifacts[0].trust.signatureMethod='authenticode'}; Code='TRUST_METADATA_BLOCKED'},
    @{Name='Schluesselwiderruf'; Edit={param($c) $c.tools[0].variants[0].artifacts[0].trust.revocation.revoked=$true}; Code='TRUST_METADATA_BLOCKED'},
    @{Name='Stale Evidence'; Edit={param($c) $c.tools[0].variants[0].artifacts[0].trust.revocation.validUntil='2026-05-01T00:00:00Z'}; Code='TRUST_METADATA_BLOCKED'}
)) {
    $catalog = Get-Fixture; & $case.Edit $catalog
    $plan = Resolve-LabSecurityToolPlan -RequestJson $requestJson -CatalogJson ($catalog | ConvertTo-Json -Depth 30) -At $at
    Add-CheckResult -Name "Fail-closed Trust-Metadaten: $($case.Name)" -Success ($plan.Status -ceq 'BLOCKED' -and $plan.Blockers -contains $case.Code)
}

foreach ($edit in @(
    {param($c) $c.tools[0].variants[0].artifacts[0].Remove('trust')},
    {param($c) $c.tools[0].variants[0].artifacts[0].trust.Remove('anchorSha256')},
    {param($c) $c.tools[0].variants[0].artifacts[0].sha256='unknown'},
    {param($c) $c.tools[0].variants[0].review.status='UNKNOWN'},
    {param($c) $c.tools[0].variants[0].artifacts[0].source.uri=('https://' + 'synthetic-user:synthetic-value' + '@' + 'releases.test/file')},
    {param($c) $c.tools[0].variants[0].artifacts[0].source.redirectUris=@('https://other.test/file')},
    {param($c) $c.tools[0].variants[0].version='latest'},
    {param($c) $c.policy.allowExecution=$true},
    {param($c) $c.tools += $c.tools[0]},
    {param($c) $c.tools[0].variants += $c.tools[0].variants[0]},
    {param($c) $c.tools[0].variants[0].purposes += @{purposeId='sql-tls';sqlLabPurpose='Conflicting purpose'}}
)) {
    $catalog=Get-Fixture; & $edit $catalog
    Add-CheckResult -Name 'Unvollstaendige, freie oder mehrdeutige Katalogdaten sperren' -Success (Test-Rejected {
        Resolve-LabSecurityToolPlan -RequestJson $requestJson -CatalogJson ($catalog | ConvertTo-Json -Depth 30) -At $at
    })
}
foreach ($kind in @('catalog','request','plan')) {
    $value = switch ($kind) {
        'catalog' { Get-Fixture }
        'request' { Get-Request }
        'plan' { ConvertFrom-LabSecurityToolJson -Json ($public | ConvertTo-Json -Depth 30) -Kind plan }
    }
    Test-ClosedObject -Value $value -Kind $kind -Root $value
}
foreach ($field in @('sqlVersion','os','distribution','osVersion','architecture','provider')) {
    $inputRequest=Get-Request; $inputRequest.target.Remove($field)
    Add-CheckResult -Name "Fehlendes Zielfeld wird nicht ergaenzt: $field" -Success (Test-Rejected {
        Resolve-LabSecurityToolPlan -RequestJson ($inputRequest | ConvertTo-Json -Depth 20) -CatalogJson $fixtureJson -At $at
    })
}
foreach ($case in @(@{os='linux';provider='hyperv'},@{os='windows';provider='docker'},@{os='windows';provider='podman'})) {
    $inputRequest=Get-Request; $catalog=Get-Fixture
    $inputRequest.target.os=$case.os; $inputRequest.target.provider=$case.provider
    $catalog.tools[0].variants[0].targets=@($inputRequest.target)
    $plan=Resolve-LabSecurityToolPlan -RequestJson ($inputRequest | ConvertTo-Json -Depth 20) -CatalogJson ($catalog | ConvertTo-Json -Depth 30) -At $at
    Add-CheckResult -Name 'Nicht unterstuetzte OS-/Providerkombination sperrt auch bei passendem Katalog' -Success (
        $plan.Status -ceq 'BLOCKED' -and $plan.Blockers -contains 'TARGET_UNSUPPORTED')
}
$catalog=Get-Fixture; $catalog.tools[0].variants[0].targets=@($catalog.tools[0].variants[0].targets[0])
$inputRequest=Get-Request; $inputRequest.target.provider='podman'
$plan=Resolve-LabSecurityToolPlan -RequestJson ($inputRequest | ConvertTo-Json -Depth 20) -CatalogJson ($catalog | ConvertTo-Json -Depth 30) -At $at
Add-CheckResult -Name 'Docker-Zielbindung erteilt keine Podman-Kompatibilitaet' -Success ($plan.Blockers -contains 'TARGET_NOT_CATALOGED')
$catalogFunction = ${function:Get-LabSecurityToolCatalogJson}
try {
    function Get-LabSecurityToolCatalogJson { return $fixtureJson }
    $direct = Get-SqlServerLabSecurityToolPlan -ToolId synthetic-tool -VariantId synthetic-linux -PurposeId sql-tls -Target $request.target
    $resolved = Resolve-LabSecurityToolPlan -RequestJson $requestJson -CatalogJson $fixtureJson
    Add-CheckResult -Name 'Direkter Eingang nutzt denselben Resolver und PlanHash' -Success ($direct.PlanHash -ceq $resolved.PlanHash)
}
finally { Set-Item Function:Get-LabSecurityToolCatalogJson -Value $catalogFunction }
$publicParameters = (Get-Command Get-SqlServerLabSecurityToolPlan).Parameters.Keys
Add-CheckResult -Name 'Keine oeffentlichen Katalog-, Quell-, Approval-, Manifest- oder Bypassparameter' -Success (
    @($publicParameters | Where-Object { $_ -in @('CatalogJson','CatalogPath','SchemaPath','At','Force','TrustUnknownArtifact','ApprovalId','RunId','Manifest','Uri','Command') }).Count -eq 0)
foreach ($duplicate in @('"toolId":"other","toolId"','"ToolId":"other","toolId"')) {
    Add-CheckResult -Name 'Doppelte JSON-Felder inklusive Gross-/Kleinschreibung blockieren' -Success (Test-Rejected {
        Resolve-LabSecurityToolPlan -RequestJson ($requestJson.Replace('"toolId"',$duplicate)) -CatalogJson $fixtureJson -At $at
    })
}
$first = Resolve-LabSecurityToolPlan -RequestJson $requestJson -CatalogJson $fixtureJson -At $at
$reordered = [ordered]@{target=$request.target;purposeId=$request.purposeId;variantId=$request.variantId;toolId=$request.toolId;contract=$request.contract}
$second = Resolve-LabSecurityToolPlan -RequestJson ($reordered | ConvertTo-Json -Depth 20) -CatalogJson ((Get-Fixture) | ConvertTo-Json -Depth 30 -Compress) -At $at.AddDays(1)
Add-CheckResult -Name 'PlanHash ist unabhaengig von Feldreihenfolge, Whitespace und Laufzeitstempel' -Success ($first.PlanHash -ceq $second.PlanHash)
foreach ($edit in @(
    {param($c) $c.revision='synthetic-v2'},
    {param($c) $c.tools[0].variants[0].artifacts[0].sha256=('c'*64)},
    {param($c) $c.tools[0].variants[0].artifacts[0].source.uri='https://releases.test/other'},
    {param($c) $c.tools[0].variants[0].artifacts[0].trust.anchorSha256=('d'*64)}
)) {
    $catalog = Get-Fixture; & $edit $catalog
    $changed = Resolve-LabSecurityToolPlan -RequestJson $requestJson -CatalogJson ($catalog | ConvertTo-Json -Depth 30) -At $at
    Add-CheckResult -Name 'PlanHash bindet Katalogrevision, Bytes, Quelle und Trust Anchor' -Success ($changed.PlanHash -cne $first.PlanHash)
}

# Die geschlossene AST-Allowlist umfasst beide produktiven Dateien transitiv.
# Damit werden auch unbekannte neue Transport-/Provider-/Prozesspfade sichtbar.
$allowedCommands = @('ConvertFrom-LabSecurityToolJsonElement','ConvertFrom-LabSecurityToolJson','Get-LabSecurityToolHash',
    'Get-LabSecurityToolCatalogJson','Test-LabSecurityToolTimeWindow','Resolve-LabSecurityToolPlan',
    'ConvertTo-Json','Get-Content','Join-Path','Test-Json','Where-Object')
$allowedMethods = @('ToString','new','EnumerateObject','Add','EnumerateArray','ToArray','GetString','GetInt64',
    'Parse','ToUpperInvariant','Dispose','GetBytes','ToHexString','HashData','ToLowerInvariant','TryParseExact','Contains')
foreach ($file in @('Private/SecurityToolCatalog.ps1','Public/Get-SqlServerLabSecurityToolPlan.ps1')) {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $file),[ref]$null,[ref]$null)
    $unexpected = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true) | Where-Object {
        $_.GetCommandName() -notin $allowedCommands -or $_.InvocationOperator.ToString() -ne 'Unknown'
    })
    $unexpectedMethods = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst]},$true) | Where-Object { $_.Member.Value -notin $allowedMethods })
    $redirects = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.RedirectionAst]},$true))
    Add-CheckResult -Name "Keine Transport-/Prozess-/Provider-/Schreibaufrufe: $file" -Success ($unexpected.Count -eq 0 -and $unexpectedMethods.Count -eq 0 -and $redirects.Count -eq 0)
}
$before = Get-ChildItem -LiteralPath $script:CatalogsPath,$script:SchemasPath -File | Get-FileHash | Select-Object Path,Hash | ConvertTo-Json -Compress
$environmentBefore = [Environment]::GetEnvironmentVariables() | ConvertTo-Json -Compress
$originalRequest = $request | ConvertTo-Json -Depth 20
$null = Get-SqlServerLabSecurityToolPlan -ToolId synthetic-tool -VariantId synthetic-linux -PurposeId sql-tls -Target $request.target
$null = Resolve-LabSecurityToolPlan -RequestJson $requestJson -CatalogJson $fixtureJson -At $at
$after = Get-ChildItem -LiteralPath $script:CatalogsPath,$script:SchemasPath -File | Get-FileHash | Select-Object Path,Hash | ConvertTo-Json -Compress
Add-CheckResult -Name 'Direktaufruf und Resolver erhalten Quelldateien, Request und Prozessumgebung bytegenau' -Success (
    $before -ceq $after -and $originalRequest -ceq ($request | ConvertTo-Json -Depth 20) -and
    $environmentBefore -ceq ([Environment]::GetEnvironmentVariables() | ConvertTo-Json -Compress))

if ($failures.Count -gt 0) { throw "SECURITY TOOL CHECKS: $($failures.Count) FAIL: $($failures -join '; ')" }
Write-Host "SECURITY TOOL CHECKS: $passed PASS; 0 FAIL"
