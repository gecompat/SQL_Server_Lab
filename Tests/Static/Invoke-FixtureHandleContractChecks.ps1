#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
$sourcePath = Join-Path $repoRoot 'Private/FixtureHandleContract.ps1'
$functionNames = @('Test-FixtureHandleId', 'ConvertFrom-FixtureHandleBytes', 'ConvertTo-FixtureHandleBytes')
Add-CheckResult 'I01-A09: keine bestehende Codec-Namenskollision' (@(Get-Command $functionNames -ErrorAction SilentlyContinue).Count -eq 0)
. $sourcePath
$id = 'a40873d6-5d24-4ad9-972e-8b253b4d19b6'
$json = '{"ContractVersion":"1.0","HandleId":"a40873d6-5d24-4ad9-972e-8b253b4d19b6"}'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$bytes = $utf8.GetBytes($json)

function Test-HandleRejection {
    param([string]$Name, [object]$InputValue, [switch]$Encode)
    $errorCount = $Error.Count
    $output = @(if ($Encode) { ConvertTo-FixtureHandleBytes -Handle $InputValue -Verbose -Debug *>&1 }
        else { ConvertFrom-FixtureHandleBytes -Bytes $InputValue -Verbose -Debug *>&1 })
    $result = if ($output.Count -eq 1) { $output[0] } else { $null }
    Add-CheckResult $Name ($null -ne $result -and $result -is [pscustomobject] -and
        (@($result.PSObject.Properties.Name) -join ',') -ceq 'Success,Value,ErrorCode' -and
        $result.Success -ceq $false -and $null -eq $result.Value -and
        $result.ErrorCode -ceq 'FIXTURE_HANDLE_INVALID' -and $Error.Count -eq $errorCount)
}

$read = ConvertFrom-FixtureHandleBytes -Bytes $bytes
Add-CheckResult 'I01-A01: zwei exakte Stringfelder, stabiler Wert und kein Outcome' (
    $read.Success -and $null -eq $read.ErrorCode -and
    (@($read.Value.PSObject.Properties.Name) -join ',') -ceq 'ContractVersion,HandleId' -and
    $read.Value.ContractVersion -is [string] -and $read.Value.ContractVersion -ceq '1.0' -and
    $read.Value.HandleId -is [string] -and $read.Value.HandleId -ceq $id)
$written = ConvertTo-FixtureHandleBytes -Handle ([pscustomobject]@{ HandleId = $id; ContractVersion = '1.0' })
Add-CheckResult 'I01-A01/A02: unabhaengige kompakte Sollbytes, Reihenfolge, UTF8 ohne BOM' (
    $written.Success -and $written.Value -is [byte[]] -and $written.Value.Length -eq $bytes.Length -and
    [Convert]::ToBase64String($written.Value) -ceq [Convert]::ToBase64String($bytes))
foreach ($text in @(
    ' { "HandleId" : "a40873d6-5d24-4ad9-972e-8b253b4d19b6", "ContractVersion" : "1.0" } ',
    ("`t`r`n" + $json + "`r`n`t"),
    '{"\u0043ontractVersion":"\u0031.0","Handle\u0049d":"\u006140873d6-5d24-4ad9-972e-8b253b4d19b6"}'
)) {
    $parsed = ConvertFrom-FixtureHandleBytes -Bytes $utf8.GetBytes($text)
    $encoded = ConvertTo-FixtureHandleBytes -Handle $parsed.Value
    Add-CheckResult 'I01-A02: JSONwhitespace, Reihenfolge/Escapes und deterministische Normalform' (
        $parsed.Success -and $encoded.Success -and [Convert]::ToBase64String($encoded.Value) -ceq [Convert]::ToBase64String($bytes))
}
foreach ($size in @(255, 256)) {
    $bounded = $utf8.GetBytes($json + (' ' * ($size - $bytes.Length)))
    $result = ConvertFrom-FixtureHandleBytes -Bytes $bounded
    Add-CheckResult "I01-A03: $size Bytes akzeptiert" ($bounded.Length -eq $size -and $result.Success)
}
Test-HandleRejection 'I01-A03: 257 Bytes vor Decodierung abgewiesen' ($utf8.GetBytes($json + (' ' * (257 - $bytes.Length))))
Test-HandleRejection 'I01-A03: grosse Bytesequenz nicht gekuerzt' ([byte[]]::new(1048576))
$invalidBytes = @(
    ([byte[]]@(0xef,0xbb,0xbf) + $bytes),
    ([byte[]]@(0xff) + $bytes),
    [byte[]]@(0xe2,0x82),
    [byte[]]@(0xc0,0xaf),
    [byte[]]@(0x80),
    $utf8.GetBytes($json.Replace('HandleId', 'Handle' + [char]0xe4 + 'Id')),
    $utf8.GetBytes($json + [char]0xa0)
)
foreach ($inputBytes in $invalidBytes) { Test-HandleRejection 'I01-A03: UTF8-/Mehrbyte-/BOMgrenze' ([byte[]]$inputBytes) }
foreach ($inputValue in @($null, '', $json, [object[]]@(123,125), [int[]]@(123,125), [byte[]]@())) {
    Test-HandleRejection 'I01-A03/A05: kein impliziter Byte-Downcast oder Null-/Leereingang' $inputValue
}
$invalidJson = @(
    '{}', '{"ContractVersion":"1.0"}', ('{"HandleId":"' + $id + '"}'),
    $json.Replace('HandleId', 'handleId'), $json.Replace('ContractVersion', 'contractVersion'),
    $json.Replace('HandleId', 'Unknown'), $json.Replace('"HandleId":', '"ContractVersion":'),
    $json.Replace('"HandleId":', '"\u0043ontractVersion":'),
    $json.Replace('}', ',"Extra":"synthetic-extra"}'),
    $json.Replace('"1.0"', 'null'), $json.Replace('"1.0"', '1.0'),
    $json.Replace('"1.0"', 'true'), $json.Replace('"1.0"', '[]'),
    $json.Replace('"1.0"', '{}'), $json.Replace('"1.0"', '"2.0"'),
    $json.Replace('"1.0"', '"1.0 "'), $json.Replace('}', ',}'),
    ('/* comment */' + $json), ('[' + $json + ']'), ($json + $json),
    $json.Substring(0, $json.Length - 1), '', 'null', 'true', '1',
    ('prefix' + $json), ($json + [char]0), $json.Replace('1.0', '1\q0'),
    $json.Replace('1.0', '\u00zz'), $json.Replace('1.0', '\uD800'),
    $json.Replace('1.0', '1\u0000.0'), $json.Replace('1.0', '1\b.0'),
    $json.Replace('HandleId', 'Handle\u0000Id'),
    $json.Replace('HandleId', 'Handle\uD800Id'),
    $json.Replace('HandleId', 'Handle' + [char]10 + 'Id'),
    $json.Replace('HandleId', 'Handle\nId'),
    $json.Replace('HandleId', 'Handle\tId'),
    $json.Replace('HandleId', 'Handle\rId'),
    $json.Replace('HandleId', 'Handle\bId'),
    $json.Replace('HandleId', 'Handle\fId'),
    $json.Replace('HandleId', 'Handle\/Id'),
    $json.Replace('HandleId', 'Handle\\Id'),
    $json.Replace('HandleId', 'Handle\"Id')
)
$vectorIndex = 0
foreach ($text in $invalidJson) {
    Test-HandleRejection "I01-A04/A05/A06: geschlossene JSONform/Version/Escapes $vectorIndex" ($utf8.GetBytes($text))
    $vectorIndex++
}
foreach ($invalidId in @('', [guid]::Empty.ToString('D'), $id.ToUpperInvariant(), ('{' + $id + '}'),
    $id.Replace('-', ''), (' ' + $id), ($id + ' '), $id.Replace('a', 'g'))) {
    Test-HandleRejection 'I01-A06: ungeeignete oder nicht kanonische UUID' ($utf8.GetBytes($json.Replace($id, $invalidId)))
    Test-HandleRejection 'I01-A06: Encoder migriert keine UUID' ([pscustomobject]@{ ContractVersion = '1.0'; HandleId = $invalidId }) -Encode
}
# Keine zusaetzliche UUID-Versionsvorgabe: eine feste Nicht-v4-ID bleibt gueltig.
$otherId = '00000000-0000-0000-0000-000000000001'
Add-CheckResult 'I01-A06: kanonische Nicht-Nil-ID ohne zusaetzlichen Versionszwang' (
    (ConvertFrom-FixtureHandleBytes -Bytes $utf8.GetBytes($json.Replace($id, $otherId))).Success -and
    (ConvertTo-FixtureHandleBytes -Handle ([pscustomobject]@{ ContractVersion = '1.0'; HandleId = $otherId })).Success)
foreach ($handle in @(
    $null, $json, @{ ContractVersion = '1.0'; HandleId = $id },
    [pscustomobject]@{ ContractVersion = '1.0'; HandleId = $id; Extra = 'synthetic-extra' },
    [pscustomobject]@{ contractVersion = '1.0'; HandleId = $id },
    [pscustomobject]@{ ContractVersion = '2.0'; HandleId = $id },
    [pscustomobject]@{ ContractVersion = 1; HandleId = $id },
    [pscustomobject]@{ ContractVersion = $null; HandleId = $id },
    [pscustomobject]@{ ContractVersion = '1.0'; HandleId = [guid]$id },
    [pscustomobject]@{ ContractVersion = '1.0'; HandleId = @($id) }
)) { Test-HandleRejection 'I01-A04/A05/A06: Encoder prueft rohe Form vor Konvertierung' $handle -Encode }
foreach ($control in @([char]0, [char]8)) {
    Test-HandleRejection 'I01-A04: ordinaler Encoder-Propertyname mit Steuerzeichen' (
        [pscustomobject]@{ ('Contract' + $control + 'Version') = '1.0'; HandleId = $id }) -Encode
    Test-HandleRejection 'I01-A06: ordinale Encoderversion mit Steuerzeichen' (
        [pscustomobject]@{ ContractVersion = ('1' + $control + '.0'); HandleId = $id }) -Encode
}
$script:getterCalls = 0
$scripted = [pscustomobject]@{ HandleId = $id }
$scripted | Add-Member ScriptProperty ContractVersion { $script:getterCalls++; throw 'SYNTHETIC_GETTER_MARKER' }
Test-HandleRejection 'I01-A08: ScriptProperty wird nicht ausgefuehrt' $scripted -Encode
$native = [version]::new(1,0)
$native | Add-Member ScriptMethod GetType { $script:getterCalls++; throw 'SYNTHETIC_CONVERSION_MARKER' } -Force
Test-HandleRejection 'I01-A08: natives Objekt ohne aufrufbaren GetType-Downcast' $native -Encode
Add-CheckResult 'I01-A08: keine Getter oder Methoden roher Eingaben ausgefuehrt' ($script:getterCalls -eq 0)

$inputCopy = [Convert]::ToBase64String($bytes)
$handle = [pscustomobject]@{ HandleId = $id; ContractVersion = '1.0' }
$handleBefore = $handle | ConvertTo-Json -Compress
$null = ConvertFrom-FixtureHandleBytes -Bytes $bytes
$null = ConvertTo-FixtureHandleBytes -Handle $handle
Add-CheckResult 'I01-A08: Eingangsbytes und Objekt unveraendert' (
    [Convert]::ToBase64String($bytes) -ceq $inputCopy -and ($handle | ConvertTo-Json -Compress) -ceq $handleBefore)

$transcriptPath = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-handle-' + [guid]::NewGuid().ToString('N') + '.log')
$transcriptOwned = $false
try {
    Start-Transcript -LiteralPath $transcriptPath -NoClobber | Out-Null
    $transcriptOwned = $true
    foreach ($marker in @('SYNTHETIC_PASSWORD_MARKER', 'SYNTHETIC_ENDPOINT_MARKER', 'SYNTHETIC_PATH_MARKER')) {
        Test-HandleRejection 'I01-A07: keine Eingabe/Exception/ErrorRecord in allen Streams' ($utf8.GetBytes($json.Replace('HandleId', $marker)))
        Test-HandleRejection 'I01-A07: fehlerhafte JSONgrenze bleibt ohne Raw-Parserfehler' ($utf8.GetBytes('{"' + $marker))
        Test-HandleRejection 'I01-A07: Encoder gibt keine Rohfelder aus' ([pscustomobject]@{ ContractVersion = $marker; HandleId = $id }) -Encode
    }
    Stop-Transcript | Out-Null
    $transcriptOwned = $false
    $transcript = Get-Content -LiteralPath $transcriptPath -Raw
    Add-CheckResult 'I01-A07: ausgegebene Transcriptdaten enthalten keinen synthetischen Eingabemarker' (
        $transcript -notmatch 'SYNTHETIC_(PASSWORD|ENDPOINT|PATH)_MARKER')
}
finally {
    if ($transcriptOwned) { Stop-Transcript | Out-Null }
    if (Test-Path -LiteralPath $transcriptPath) { Remove-Item -LiteralPath $transcriptPath -Force }
}
Add-CheckResult 'I01-A07: eigener Transcript entfernt' (-not (Test-Path -LiteralPath $transcriptPath))

$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
$statements = @($ast.EndBlock.Statements)
$commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
$types = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.TypeExpressionAst] }, $true) | ForEach-Object { $_.TypeName.FullName })
Add-CheckResult 'I01-A08/A09/A12: Syntax und ausschliesslich nebenwirkungsfreie Definitionen' (
    $parseErrors.Count -eq 0 -and $statements.Count -eq 3 -and
    @($statements | Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] }).Count -eq 0 -and
    @($commands | Where-Object { $_.GetCommandName() -cne 'Test-FixtureHandleId' }).Count -eq 0 -and
    @($types | Where-Object { $_ -notin @('object','string','StringComparison','guid','byte[]','Text.Encoding','regex','Text.StringBuilder','char','Convert','pscustomobject','ordered','Management.Automation.PSCustomObject','Management.Automation.PSNoteProperty') }).Count -eq 0)
$members = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
    ForEach-Object { $_.Member.Value })
Add-CheckResult 'I01-A08: keine IO/Provider/SQL/Prozesse/Zufalls-ID/Keys oder Uhrabfragen' (
    @($members | Where-Object { $_ -notin @('TryParseExact','GetString','Match','new','Substring','ToInt32','Append','ToString','GetMethod','Invoke','GetType','GetBytes','Equals') }).Count -eq 0)

$module = $null
try {
    $manifestPath = Join-Path $repoRoot 'SqlServerLab.psd1'
    $manifest = Import-PowerShellDataFile $manifestPath
    $module = Import-Module $manifestPath -Force -PassThru -WarningAction Stop
    $loadErrors = & $module { @($script:ModuleLoadErrors).Count }
    $moduleRead = & $module { param($inputBytes) ConvertFrom-FixtureHandleBytes -Bytes $inputBytes } $bytes
    Add-CheckResult 'I01-A09/A12: bestehender Loader, keine LoadErrors, Codec intern erreichbar' (
        $loadErrors -eq 0 -and $moduleRead.Success -and $manifest.PowerShellVersion -eq '7.2')
    Add-CheckResult 'I01-A09: unveraenderte manifestgebundene Exporte, Codec bleibt privat' (
        @((Compare-Object @($manifest.FunctionsToExport | Sort-Object) @($module.ExportedFunctions.Keys | Sort-Object))).Count -eq 0 -and
        @($functionNames | Where-Object { $_ -in $module.ExportedFunctions.Keys }).Count -eq 0)
}
finally { if ($null -ne $module) { Remove-Module $module -Force } }
Write-Host "`nErgebnis: $passed PASS, $($failures.Count) FAIL"
if ($failures.Count -gt 0) { exit 1 }
exit 0
