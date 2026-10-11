#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$passed = 0
$failures = [Collections.Generic.List[string]]::new()
$sourcePath = Join-Path $repoRoot 'Private/FixtureIdentityRequest.ps1'
$functionNames = @('Skip-FixtureIdentityJsonSpace','Read-FixtureIdentityJsonValue','Test-FixtureIdentityFields',
    'Test-FixtureIdentityString','Test-FixtureIdentityAlias','Get-FixtureIdentityUsageMask',
    'Get-FixtureIdentityRetention','ConvertFrom-FixtureIdentityRequestBytes')
Add-CheckResult 'I02-A09: keine bestehende Namenskollision' (@(Get-Command $functionNames -ErrorAction SilentlyContinue).Count -eq 0)
. (Join-Path $repoRoot 'Private/FixtureHandleContract.ps1')
. $sourcePath
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$dbRef = '00000000-0000-0000-0000-000000000003'

function New-IdentityRetentionFixture {
    param([string]$Mode = 'OPERATION', [int]$Duration = -1)
    $retention = [ordered]@{ Mode = $Mode }
    if ($Duration -ge 0) { $retention.DurationSeconds = $Duration }
    return $retention
}
function New-OsIdentityFixture {
    param([string]$Alias = 'same', [string]$Kind = 'LINUX_LOCAL_ACCOUNT', [string]$Usage = 'AUTOMATED', [string]$Mode = 'OPERATION', [int]$Duration = -1)
    return [ordered]@{ Alias = $Alias; Kind = $Kind; Usage = $Usage; Retention = (New-IdentityRetentionFixture $Mode $Duration) }
}
function New-LoginIdentityFixture {
    param([string]$Alias = 'same', [string]$Usage = 'AUTOMATED', [string]$Mode = 'OPERATION', [int]$Duration = -1)
    return [ordered]@{ Alias = $Alias; Usage = $Usage; Retention = (New-IdentityRetentionFixture $Mode $Duration) }
}
function New-DbIdentityFixture {
    param([string]$Alias = 'reader', [string]$LoginAlias = 'same', [string]$DatabaseRef = $dbRef,
        [string]$Usage = 'AUTOMATED', [string]$Mode = 'OPERATION', [int]$Duration = -1)
    return [ordered]@{ Alias = $Alias; LoginAlias = $LoginAlias; DatabaseRef = $DatabaseRef; ProfileAlias = 'ReadProfile'; Usage = $Usage; Retention = (New-IdentityRetentionFixture $Mode $Duration) }
}
function New-IdentityRequestFixture {
    param([object[]]$Os = @(), [object[]]$Logins = @(), [object[]]$Users = @())
    return [ordered]@{
        ContractVersion = '1.0'; RequestRef = '00000000-0000-0000-0000-000000000001'; TargetRef = '00000000-0000-0000-0000-000000000002'
        ScenarioAlias = 'Training'; OsIdentities = $Os; SqlIdentities = [ordered]@{ Logins = $Logins; DatabaseUsers = $Users }
    }
}
function ConvertTo-IdentityFixtureBytes {
    param([object]$Fixture)
    return ,$utf8.GetBytes(($Fixture | ConvertTo-Json -Depth 20 -Compress))
}
function Test-IdentityRequestRejection {
    param([string]$Name, [object]$InputBytes)
    $before = $Error.Count
    $output = @(ConvertFrom-FixtureIdentityRequestBytes -Bytes $InputBytes -Verbose -Debug *>&1)
    $result = if ($output.Count -eq 1) { $output[0] } else { $null }
    Add-CheckResult $Name ($null -ne $result -and $result -is [pscustomobject] -and
        (@($result.PSObject.Properties.Name) -join ',') -ceq 'Success,Value,ErrorCode' -and
        $result.Success -eq $false -and $null -eq $result.Value -and $result.ErrorCode -ceq 'FIXTURE_REQUEST_INVALID' -and $Error.Count -eq $before)
}

$osRequest = New-IdentityRequestFixture -Os @((New-OsIdentityFixture -Usage MANUAL -Mode SCENARIO))
$osBytes = ConvertTo-IdentityFixtureBytes $osRequest
$read = ConvertFrom-FixtureIdentityRequestBytes $osBytes
$expected = New-IdentityRequestFixture -Os @((New-OsIdentityFixture -Usage MANUAL -Mode SCENARIO -Duration 14400))
Add-CheckResult 'I02-A01/A06: unabhaengige genaue OS-Projektion und Vier-Stunden-Default' (
    $read.Success -and $null -eq $read.ErrorCode -and
    ($read.Value | ConvertTo-Json -Depth 20 -Compress) -ceq ($expected | ConvertTo-Json -Depth 20 -Compress))
foreach ($kind in @('WINDOWS_LOCAL_ACCOUNT','LINUX_LOCAL_ACCOUNT','LINUX_NUMERIC_CONTEXT')) {
    foreach ($usage in @('MANUAL','AUTOMATED','MANUAL_AND_AUTOMATED')) {
        $fixture = New-IdentityRequestFixture -Os @((New-OsIdentityFixture -Kind $kind -Usage $usage -Mode SCENARIO))
        $result = ConvertFrom-FixtureIdentityRequestBytes (ConvertTo-IdentityFixtureBytes $fixture)
        Add-CheckResult "I02-A01/A07: getrennte Art und beabsichtigte Nutzung $kind/$usage" (
            $result.Success -and $result.Value.OsIdentities[0].Kind -ceq $kind -and $result.Value.OsIdentities[0].Usage -ceq $usage -and
            (@($result.Value.OsIdentities[0].PSObject.Properties.Name) -join ',') -ceq 'Alias,Kind,Usage,Retention')
    }
}
$combined = New-IdentityRequestFixture -Os @((New-OsIdentityFixture)) -Logins @((New-LoginIdentityFixture)) -Users @((New-DbIdentityFixture))
$result = ConvertFrom-FixtureIdentityRequestBytes (ConvertTo-IdentityFixtureBytes $combined)
Add-CheckResult 'I02-A01/A02: gleicher OS-/Login-Alias ohne Kopplung, nur ausdruecklicher DB-Login' (
    $result.Success -and $result.Value.OsIdentities.Count -eq 1 -and $result.Value.SqlIdentities.Logins.Count -eq 1 -and
    $result.Value.SqlIdentities.DatabaseUsers.Count -eq 1 -and $result.Value.SqlIdentities.DatabaseUsers[0].LoginAlias -ceq 'same')
$multiple = New-IdentityRequestFixture -Logins @((New-LoginIdentityFixture -Alias zeta), (New-LoginIdentityFixture -Alias alpha)) -Users @(
    (New-DbIdentityFixture -LoginAlias zeta), (New-DbIdentityFixture -LoginAlias alpha -DatabaseRef '00000000-0000-0000-0000-000000000004'))
$result = ConvertFrom-FixtureIdentityRequestBytes (ConvertTo-IdentityFixtureBytes $multiple)
Add-CheckResult 'I02-A01/A05: reine SQL-Anfrage, mehrere Datenbanken, Alias- und Arrayreihenfolge erhalten' (
    $result.Success -and $result.Value.OsIdentities -is [array] -and $result.Value.OsIdentities.Count -eq 0 -and
    ($result.Value.SqlIdentities.Logins.Alias -join ',') -ceq 'zeta,alpha' -and $result.Value.SqlIdentities.DatabaseUsers.Count -eq 2)

$json = $utf8.GetString($osBytes)
$escaped = $json.Replace('ContractVersion','\u0043ontractVersion').Replace('Training','\u0054raining').Replace('MANUAL','\u004dANUAL')
$whitespace = "`t`r`n " + $escaped + " `n"
$reverse = [ordered]@{}
foreach ($key in @($osRequest.Keys)[($osRequest.Count-1)..0]) { $reverse[$key] = $osRequest[$key] }
foreach ($validBytes in @($utf8.GetBytes($whitespace), (ConvertTo-IdentityFixtureBytes $reverse))) {
    $result = ConvertFrom-FixtureIdentityRequestBytes ([byte[]]$validBytes)
    Add-CheckResult 'I02-A03: Feldreihenfolge/JSONwhitespace/ASCII-Unicode-Escapes ohne Wertmigration' (
        $result.Success -and ($result.Value | ConvertTo-Json -Depth 20 -Compress) -ceq ($expected | ConvertTo-Json -Depth 20 -Compress))
}
foreach ($size in @(16383,16384)) {
    $bounded = $utf8.GetBytes($json + (' ' * ($size - $osBytes.Length)))
    Add-CheckResult "I02-A04: $size tatsaechliche UTF8-Bytes erlaubt" (
        $bounded.Length -eq $size -and (ConvertFrom-FixtureIdentityRequestBytes $bounded).Success)
}
Test-IdentityRequestRejection 'I02-A04: 16385 Bytes vor Verarbeitung abgewiesen' ($utf8.GetBytes($json + (' ' * (16385 - $osBytes.Length))))
Test-IdentityRequestRejection 'I02-A04: 1 MiB nicht gekuerzt' ([byte[]]::new(1048576))
foreach ($bytes in @(([byte[]]@(0xef,0xbb,0xbf) + $osBytes), [byte[]]@(0xe2,0x82), [byte[]]@(0xc0,0xaf), [byte[]]@(0x80),
        $utf8.GetBytes($json + [char]0xa0), $utf8.GetBytes($json.Replace('Training','Tr' + [char]0xe4 + 'ining')))) {
    Test-IdentityRequestRejection 'I02-A03: BOM/defektes UTF8/Nicht-ASCII ohne gueltige geschlossene Form' ([byte[]]$bytes)
}
foreach ($raw in @($null, '', $json, [object[]]@(123,125), [int[]]@(123,125), [byte[]]@(), [pscustomobject]@{ Bytes = $osBytes })) {
    Test-IdentityRequestRejection 'I02-A03/A08: rohe Nicht-Byteeingaben ohne Konvertierung' $raw
}
$script:getterCalls = 0
$scripted = [pscustomobject]@{}
$scripted | Add-Member ScriptProperty Bytes { $script:getterCalls++; throw 'SYNTHETIC_GETTER_MARKER' }
Test-IdentityRequestRejection 'I02-A08: roher Objektgetter nicht ausgefuehrt' $scripted
Add-CheckResult 'I02-A08: keine Getterausfuehrung' ($script:getterCalls -eq 0)
$extendedBytes = $utf8.GetBytes($json)
Add-Member -InputObject $extendedBytes -MemberType ScriptProperty -Name Length -Value { $script:getterCalls++; throw 'SYNTHETIC_ARRAY_GETTER_MARKER' } -Force
Add-CheckResult 'I02-A08: byte[] ohne ueberschriebenen Arraygetter verarbeitet' (
    $extendedBytes.PSObject.Properties['Length'] -is [Management.Automation.PSScriptProperty] -and
    (ConvertFrom-FixtureIdentityRequestBytes $extendedBytes).Success -and $script:getterCalls -eq 0)

$badJson = @('{}','null','true','[]',('[' + $json + ']'),('/* comment */' + $json),($json + $json),($json + [char]0),
    $json.Replace('"1.0"','1'),$json.Replace('"1.0"','null'),$json.Replace('"1.0"','false'),$json.Replace('"1.0"','[]'),$json.Replace('"1.0"','{}'),
    $json.Replace('1.0','2.0'),$json.Replace('ContractVersion','contractVersion'),$json.Replace('ContractVersion','Contract\u0000Version'),
    $json.Replace('ContractVersion','Contract\bVersion'),$json.Replace('1.0','1\u0000.0'),$json.Replace('1.0','1\b.0'),
    $json.Replace('Training','Train\ning'),$json.Replace('Training','Train\ting'),$json.Replace('Training','Train\ring'),
    $json.Replace('Training','Train\fing'),$json.Replace('Training','Train\/ing'),$json.Replace('Training','Train\\ing'),
    $json.Replace('Training','Train\"ing'),$json.Replace('Training','\uD800'),$json.Replace('Training','\u00zz'),$json.Replace('Training','Train\qing'),
    $json.Replace('MANUAL','MANUAL\u0000'),$json.Replace('SCENARIO','SCE\bNARIO'),
    $json.Replace('"ContractVersion":"1.0"','"ContractVersion":"1.0","\u0043ontractVersion":"1.0"'),
    $json.Replace('"Logins":[]','"Logins":[],"Log\u0069ns":[]'),
    $json.Replace('"Alias":"same"','"Alias":"same","\u0041lias":"same"'),
    $json.Replace('"Mode":"SCENARIO"','"Mode":"SCENARIO","Mode":"SCENARIO"'),
    $json.Replace('"OsIdentities":[','"OsIdentities":{'),$json.Replace('"SqlIdentities":{','"SqlIdentities":['),
    $json.Replace('"Mode":"SCENARIO"','"Mode":"SCENARIO",'),$json.Replace('"Logins":[]','"Logins":[{},]'),
    $json.Replace('"Alias":"same",',''),$json.Replace('"OsIdentities":','"osIdentities":'))
$index = 0
foreach ($text in $badJson) { Test-IdentityRequestRejection "I02-A03/A07: geschlossene JSONform $index" ($utf8.GetBytes($text)); $index++ }
for ($length = 0; $length -lt $osBytes.Length; $length++) {
    $prefix = [byte[]]::new($length)
    [Array]::Copy($osBytes, $prefix, $length)
    Test-IdentityRequestRejection "I02-A03/A08: abgeschnittener Byteprefix $length" $prefix
}
foreach ($name in @('RequestRef','TargetRef')) {
    foreach ($bad in @('', '00000000-0000-0000-0000-000000000000','{00000000-0000-0000-0000-000000000001}',
            'ABCDEF12-0000-0000-0000-000000000001','00000000000000000000000000000001','not_a_reference')) {
        $fixture = New-IdentityRequestFixture -Os @((New-OsIdentityFixture))
        $fixture[$name] = $bad
        Test-IdentityRequestRejection 'I02-A03: unvermutete/nicht kanonische Referenz' (ConvertTo-IdentityFixtureBytes $fixture)
    }
}
foreach ($name in @('Alias','ScenarioAlias','ProfileAlias')) {
    foreach ($alias in @('', ('a' * 33), 'two words', 'native/path', ('a' + [char]0), ('a' + [char]8))) {
        $fixture = New-IdentityRequestFixture -Logins @((New-LoginIdentityFixture)) -Users @((New-DbIdentityFixture))
        if ($name -eq 'ScenarioAlias') { $fixture.ScenarioAlias = $alias }
        else { $fixture.SqlIdentities.DatabaseUsers[0][$name] = $alias }
        Test-IdentityRequestRejection 'I02-A04/A07: begrenzter logischer Alias' (ConvertTo-IdentityFixtureBytes $fixture)
    }
}
$fixture = New-IdentityRequestFixture -Os @((New-OsIdentityFixture -Alias ('a' * 32)))
Add-CheckResult 'I02-A04: genau 32 ASCII-Aliaszeichen' ((ConvertFrom-FixtureIdentityRequestBytes (ConvertTo-IdentityFixtureBytes $fixture)).Success)
Test-IdentityRequestRejection 'I02-A04: kein leerer Ressourcensatz' (ConvertTo-IdentityFixtureBytes (New-IdentityRequestFixture))
foreach ($count in @(16,17)) {
    $nodes = @(for ($i = 0; $i -lt $count; $i++) { New-OsIdentityFixture -Alias "os$i" })
    $bytes = ConvertTo-IdentityFixtureBytes (New-IdentityRequestFixture -Os $nodes)
    if ($count -eq 16) { Add-CheckResult 'I02-A04: 16 OS-Deskriptoren erlaubt' ((ConvertFrom-FixtureIdentityRequestBytes $bytes).Success) }
    else { Test-IdentityRequestRejection 'I02-A04: 17 OS-Deskriptoren abgewiesen' $bytes }
    $nodes = @(for ($i = 0; $i -lt $count; $i++) { New-LoginIdentityFixture -Alias "sql$i" })
    $bytes = ConvertTo-IdentityFixtureBytes (New-IdentityRequestFixture -Logins $nodes)
    if ($count -eq 16) { Add-CheckResult 'I02-A04: 16 Logindeskriptoren erlaubt' ((ConvertFrom-FixtureIdentityRequestBytes $bytes).Success) }
    else { Test-IdentityRequestRejection 'I02-A04: 17 Logindeskriptoren abgewiesen' $bytes }
}
# Unabhaengige Feldrechnung: Root/SQL 8, Login 4, Benutzer je 7.
$sixteenUsers = @(for ($i = 0; $i -lt 16; $i++) { New-DbIdentityFixture -Alias "u$i" })
$boundary = New-IdentityRequestFixture -Logins @((New-LoginIdentityFixture),(New-LoginIdentityFixture -Alias second)) -Users $sixteenUsers
Add-CheckResult 'I02-A04: 128 Felder = 8 + 2*4 + 16*7 erlaubt' ((ConvertFrom-FixtureIdentityRequestBytes (ConvertTo-IdentityFixtureBytes $boundary)).Success)
$boundary.SqlIdentities.Logins[0].Retention = New-IdentityRetentionFixture SCENARIO 14400
Test-IdentityRequestRejection 'I02-A04: 129 Felder durch ein weiteres Durationfeld abgewiesen' (ConvertTo-IdentityFixtureBytes $boundary)
$boundary = New-IdentityRequestFixture -Logins @((New-LoginIdentityFixture -Mode SCENARIO)) -Users $sixteenUsers
foreach ($i in 0..2) { $boundary.SqlIdentities.DatabaseUsers[$i].Retention = New-IdentityRetentionFixture SCENARIO 1 }
Add-CheckResult 'I02-A04: 127 Felder = 8 + 4 + 16*7 + 3 erlaubt' ((ConvertFrom-FixtureIdentityRequestBytes (ConvertTo-IdentityFixtureBytes $boundary)).Success)
foreach ($count in @(32,33,64,65)) {
    $nodes = @(for ($i = 0; $i -lt $count; $i++) { New-DbIdentityFixture -Alias "db$i" })
    Test-IdentityRequestRejection 'I02-A04: unerreichbare grosse DB-/Gesamtzaehler am strengeren Feldbudget blockiert' (ConvertTo-IdentityFixtureBytes (New-IdentityRequestFixture -Logins @((New-LoginIdentityFixture)) -Users $nodes))
}
foreach ($depth in @(8,9,20)) { Test-IdentityRequestRejection 'I02-A04: fremde Shape/Tiefenueberschreitung' ($utf8.GetBytes(('[' * $depth) + '0' + (']' * $depth))) }

foreach ($duration in @(1,86400)) {
    $fixture = New-IdentityRequestFixture -Os @((New-OsIdentityFixture -Usage MANUAL -Mode SCENARIO -Duration $duration))
    $result = ConvertFrom-FixtureIdentityRequestBytes (ConvertTo-IdentityFixtureBytes $fixture)
    Add-CheckResult "I02-A06: Durationrand $duration erlaubt" ($result.Success -and $result.Value.OsIdentities[0].Retention.DurationSeconds -eq $duration)
}
foreach ($number in @('0','86401','-1','-0','01','1.0','1e0','14400.5','2147483648','999999999999999999999','"1"','null','true','[]','{}')) {
    Test-IdentityRequestRejection 'I02-A04/A06: Dauer ist kein erlaubter JSONinteger' ($utf8.GetBytes($json.Replace('"Mode":"SCENARIO"', ('"Mode":"SCENARIO","DurationSeconds":' + $number))))
}
foreach ($usage in @('MANUAL','MANUAL_AND_AUTOMATED')) {
    Test-IdentityRequestRejection 'I02-A06: manuelle Nutzung ohne Szenarioretention' (ConvertTo-IdentityFixtureBytes (New-IdentityRequestFixture -Os @((New-OsIdentityFixture -Usage $usage))))
}
Test-IdentityRequestRejection 'I02-A06: OPERATION mit Dauer ungueltig' (ConvertTo-IdentityFixtureBytes (New-IdentityRequestFixture -Os @((New-OsIdentityFixture -Duration 1))))
foreach ($case in @('missing','case','os','osduplicate','loginduplicate','dbduplicate','operationparent','shortparent','usage')) {
    $fixture = New-IdentityRequestFixture -Logins @((New-LoginIdentityFixture)) -Users @((New-DbIdentityFixture))
    switch ($case) {
        missing { $fixture.SqlIdentities.DatabaseUsers[0].LoginAlias = 'absent' }
        case { $fixture.SqlIdentities.DatabaseUsers[0].LoginAlias = 'Same' }
        os { $fixture.OsIdentities = @((New-OsIdentityFixture)); $fixture.SqlIdentities.Logins = @() }
        osduplicate { $fixture.OsIdentities = @((New-OsIdentityFixture), (New-OsIdentityFixture -Alias SAME)) }
        loginduplicate { $fixture.SqlIdentities.Logins += New-LoginIdentityFixture -Alias SAME }
        dbduplicate { $fixture.SqlIdentities.DatabaseUsers += New-DbIdentityFixture -Alias READER }
        operationparent { $fixture.SqlIdentities.DatabaseUsers[0].Retention = New-IdentityRetentionFixture SCENARIO 1 }
        shortparent { $fixture.SqlIdentities.Logins[0].Retention = New-IdentityRetentionFixture SCENARIO 1; $fixture.SqlIdentities.DatabaseUsers[0].Retention = New-IdentityRetentionFixture SCENARIO 2 }
        usage { $fixture.SqlIdentities.DatabaseUsers[0].Usage = 'MANUAL'; $fixture.SqlIdentities.Logins[0].Retention = New-IdentityRetentionFixture SCENARIO; $fixture.SqlIdentities.DatabaseUsers[0].Retention = New-IdentityRetentionFixture SCENARIO }
    }
    Test-IdentityRequestRejection "I02-A05/A06: ausdrueckliche Beziehung/Retention $case" (ConvertTo-IdentityFixtureBytes $fixture)
}
foreach ($parentUsage in @('MANUAL','AUTOMATED','MANUAL_AND_AUTOMATED')) {
    foreach ($childUsage in @('MANUAL','AUTOMATED','MANUAL_AND_AUTOMATED')) {
        $fixture = New-IdentityRequestFixture -Logins @((New-LoginIdentityFixture -Usage $parentUsage -Mode SCENARIO)) -Users @((New-DbIdentityFixture -Usage $childUsage -Mode SCENARIO))
        $result = ConvertFrom-FixtureIdentityRequestBytes (ConvertTo-IdentityFixtureBytes $fixture)
        $allowed = $parentUsage -ceq $childUsage -or $parentUsage -ceq 'MANUAL_AND_AUTOMATED'
        Add-CheckResult "I02-A06: unabhaengige Nutzungs-Untermenge $parentUsage/$childUsage" ($result.Success -eq $allowed)
    }
}
$fixture = New-IdentityRequestFixture -Logins @((New-LoginIdentityFixture -Mode SCENARIO)) -Users @((New-DbIdentityFixture))
Add-CheckResult 'I02-A06: OPERATION-Benutzer darf aufbewahrten Login nutzen' ((ConvertFrom-FixtureIdentityRequestBytes (ConvertTo-IdentityFixtureBytes $fixture)).Success)
foreach ($name in @('StateRoot','Credentials','Owner','Grant','READY','Generation','Command','Sql','Shell','FILESYSTEM')) {
    $fixture = New-IdentityRequestFixture -Os @((New-OsIdentityFixture))
    $fixture[$name] = 'SYNTHETIC_INPUT_MARKER'
    Test-IdentityRequestRejection 'I02-A07: keine Selbstauskunft/Pfade/Credentials/Commands' (ConvertTo-IdentityFixtureBytes $fixture)
}
foreach ($kind in @('SQL_AUTH_LOGIN','SQL_DB_USER_MAPPED','FILESYSTEM','CONTAINED_USER','WITHOUT_LOGIN','WINDOWS_AUTH_LOGIN','linux_local_account')) {
    Test-IdentityRequestRejection 'I02-A07: keine fremde oder ausgeschlossene OS-Art' (ConvertTo-IdentityFixtureBytes (New-IdentityRequestFixture -Os @((New-OsIdentityFixture -Kind $kind))))
}
foreach ($group in @('OS','LOGIN','USER')) {
    $fixture = New-IdentityRequestFixture -Os @((New-OsIdentityFixture)) -Logins @((New-LoginIdentityFixture)) -Users @((New-DbIdentityFixture))
    $entry = if ($group -eq 'OS') { $fixture.OsIdentities[0] } elseif ($group -eq 'LOGIN') { $fixture.SqlIdentities.Logins[0] } else { $fixture.SqlIdentities.DatabaseUsers[0] }
    $entry['NativeId'] = 'SYNTHETIC_NATIVE_MARKER'
    Test-IdentityRequestRejection 'I02-A07: native Zusatzfelder in jeder Art abgewiesen' (ConvertTo-IdentityFixtureBytes $fixture)
}

$copy = [Convert]::ToBase64String($osBytes)
$first = ConvertFrom-FixtureIdentityRequestBytes $osBytes
$first.Value.OsIdentities[0].Alias = 'changed'
$first.Value.OsIdentities[0].Retention.DurationSeconds = 1
$second = ConvertFrom-FixtureIdentityRequestBytes $osBytes
Add-CheckResult 'I02-A08: Eingang unveraendert und Ergebnisse voneinander unabhaengig' (
    [Convert]::ToBase64String($osBytes) -ceq $copy -and $second.Value.OsIdentities[0].Alias -ceq 'same' -and
    $second.Value.OsIdentities[0].Retention.DurationSeconds -eq 14400)
$transcriptPath = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-identity-' + [guid]::NewGuid().ToString('N') + '.log')
$owned = $false
try {
    Start-Transcript -LiteralPath $transcriptPath -NoClobber | Out-Null; $owned = $true
    foreach ($marker in @('SYNTHETIC_PASSWORD_MARKER','SYNTHETIC_ENDPOINT_MARKER','SYNTHETIC_PATH_MARKER')) {
        Test-IdentityRequestRejection 'I02-A08: kein Rohfeld/Parserfehler in Streams und Fehlerverlauf' ($utf8.GetBytes($json.Replace('ContractVersion',$marker)))
        Test-IdentityRequestRejection 'I02-A08: abgeschnittene Markereingabe bleibt privat' ($utf8.GetBytes('{"' + $marker + '\u'))
    }
    $before = $Error.Count
    $output = @(ConvertFrom-FixtureIdentityRequestBytes $osBytes -Verbose -Debug *>&1)
    Add-CheckResult 'I02-A08: Erfolg nur ein privates Ergebnis, keine Streams oder ErrorRecords' ($output.Count -eq 1 -and $output[0].Success -and $Error.Count -eq $before)
    Stop-Transcript | Out-Null; $owned = $false
    $transcript = Get-Content -LiteralPath $transcriptPath -Raw
    Add-CheckResult 'I02-A08: keine synthetischen Eingabemarker im Transcript' ($transcript -notmatch 'SYNTHETIC_(PASSWORD|ENDPOINT|PATH)_MARKER')
}
finally { if ($owned) { Stop-Transcript | Out-Null }; if (Test-Path -LiteralPath $transcriptPath) { Remove-Item -LiteralPath $transcriptPath -Force } }
Add-CheckResult 'I02-A08: eigener Transcript entfernt' (-not (Test-Path -LiteralPath $transcriptPath))

$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
$statements = @($ast.EndBlock.Statements)
Add-CheckResult 'I02-A09: ausschliesslich acht reine Definitionen, keine Initialisierung' (
    $parseErrors.Count -eq 0 -and $statements.Count -eq 8 -and
    @($statements | Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] }).Count -eq 0)
$commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object GetCommandName)
Add-CheckResult 'I02-A09: Commanddispatch nur an reine eigene Helper und I01-UUIDpruefung' (
    @($commands | Where-Object { $_ -notin @($functionNames + 'Test-FixtureHandleId') }).Count -eq 0)
$types = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.TypeExpressionAst] }, $true) | ForEach-Object { $_.TypeName.FullName })
Add-CheckResult 'I02-A09: Frameworkmittel ohne IO/Clock/Keys/Prozess/Provider/SQL' (
    @($types | Where-Object { $_ -notin @('Text.StringBuilder','Convert','Collections.Generic.Dictionary[string,object]',
        'StringComparer','Collections.Generic.List[object]','int','string','StringComparison','Text.Encoding','Collections.Generic.HashSet[string]','byte[]') }).Count -eq 0)
$members = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true) | ForEach-Object { $_.Member.Value })
Add-CheckResult 'I02-A09: begrenzte Formoperationen ohne externe Seiteneffekte' (
    @($members | Where-Object { $_ -notin @('new','ToString','Substring','ToInt32','Append','ContainsKey','Add','TryParse','Equals','GetString','ToArray') }).Count -eq 0)
$module = $null
try {
    $manifestPath = Join-Path $repoRoot 'SqlServerLab.psd1'
    $manifest = Import-PowerShellDataFile $manifestPath
    $module = Import-Module $manifestPath -Force -PassThru -WarningAction Stop
    $moduleResult = & $module { param($inputBytes) ConvertFrom-FixtureIdentityRequestBytes $inputBytes } $osBytes
    $loadErrors = & $module { @($script:ModuleLoadErrors).Count }
    Add-CheckResult 'I02-A09/A11: echter Modulimport ohne LoadErrors und interner Validator' ($loadErrors -eq 0 -and $moduleResult.Success -and $manifest.PowerShellVersion -eq '7.2')
    Add-CheckResult 'I02-A09: unveraenderte manifestgebundene Exporte' (
        @((Compare-Object @($manifest.FunctionsToExport | Sort-Object) @($module.ExportedFunctions.Keys | Sort-Object))).Count -eq 0 -and
        @($functionNames | Where-Object { $_ -in $module.ExportedFunctions.Keys }).Count -eq 0)
}
finally { if ($null -ne $module) { Remove-Module $module -Force } }
Write-Host "`nErgebnis: $passed PASS, $($failures.Count) FAIL"
if ($failures.Count -gt 0) { exit 1 }
exit 0
