#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$passed = 0
$failures = [Collections.Generic.List[string]]::new()
$sourcePath = Join-Path $repoRoot 'Private/AuthenticatedTlsRequest.ps1'
. $sourcePath

function New-TlsRequestFixture {
    param([string]$Kind = 'CA_PROFILE')
    $record = [ordered]@{
        ContractVersion = 'SqlServerLab.AuthenticatedTlsRequest/0.1'
        RequestId = '11111111-1111-1111-1111-111111111111'
        AuthorityRef = '22222222-2222-2222-2222-222222222222'
        Kind = $Kind
    }
    $profile = [pscustomobject][ordered]@{ Algorithm = 'RSA'; RsaBits = 3072; Signature = 'SHA256'; ValidityDays = 30; RenewBeforeDays = 7 }
    switch ($Kind) {
        'CA_PROFILE' { $record.Profile = $profile }
        'LEAF_PROFILE' {
            $record.TargetRef = '33333333-3333-3333-3333-333333333333'; $record.Provider = 'docker'; $record.SqlVersion = '2025'; $record.Port = 1433
            $record.Identity = [pscustomobject][ordered]@{ Kind = 'IP'; Value = '127.0.0.1' }; $record.Profile = $profile
        }
        'CLIENT_TRUST' {
            $record.ClientRef = '44444444-4444-4444-4444-444444444444'; $record.Platform = 'windows'; $record.Store = 'CURRENT_USER_ROOT'
            $record.CertificateSha256 = 'a' * 64; $record.ClientStacks = @('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD')
        }
    }
    return [pscustomobject]$record
}

function Assert-TlsRequestRejected {
    param([string]$Name, [object]$Request)
    $before = $Error.Count
    $output = @(Test-LabAuthenticatedTlsRequest -Request $Request -Verbose -Debug *>&1)
    $validRejection = $output.Count -eq 1 -and $output[0] -is [pscustomobject] -and
        (@($output[0].PSObject.Properties.Name) -join ',') -ceq 'Success,Value,ErrorCode' -and
        $output[0].Success -ceq $false -and $null -eq $output[0].Value -and
        $output[0].ErrorCode -ceq 'TLS_REQUEST_INVALID' -and $Error.Count -eq $before
    Add-CheckResult $Name $validRejection
}

# Unabhaengige Sollprojektionen: keine Uebernahme der Produktvalidator-Ausgabe.
$expected = @{
    CA_PROFILE = '{"ContractVersion":"SqlServerLab.AuthenticatedTlsRequest/0.1","RequestId":"11111111-1111-1111-1111-111111111111","AuthorityRef":"22222222-2222-2222-2222-222222222222","Kind":"CA_PROFILE","Profile":{"Algorithm":"RSA","RsaBits":3072,"Signature":"SHA256","ValidityDays":30,"RenewBeforeDays":7}}'
    LEAF_PROFILE = '{"ContractVersion":"SqlServerLab.AuthenticatedTlsRequest/0.1","RequestId":"11111111-1111-1111-1111-111111111111","AuthorityRef":"22222222-2222-2222-2222-222222222222","Kind":"LEAF_PROFILE","TargetRef":"33333333-3333-3333-3333-333333333333","Provider":"docker","SqlVersion":"2025","Port":1433,"Identity":{"Kind":"IP","Value":"127.0.0.1"},"Profile":{"Algorithm":"RSA","RsaBits":3072,"Signature":"SHA256","ValidityDays":30,"RenewBeforeDays":7}}'
    CLIENT_TRUST = '{"ContractVersion":"SqlServerLab.AuthenticatedTlsRequest/0.1","RequestId":"11111111-1111-1111-1111-111111111111","AuthorityRef":"22222222-2222-2222-2222-222222222222","Kind":"CLIENT_TRUST","ClientRef":"44444444-4444-4444-4444-444444444444","Platform":"windows","Store":"CURRENT_USER_ROOT","CertificateSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","ClientStacks":["SYSTEM_DATA_SQLCLIENT","ODBC_SQLCMD"]}'
}
foreach ($kind in @('CA_PROFILE','LEAF_PROFILE','CLIENT_TRUST')) {
    $fixture = New-TlsRequestFixture $kind
    $before = $fixture | ConvertTo-Json -Depth 8 -Compress
    $errorCount = $Error.Count
    $output = @(Test-LabAuthenticatedTlsRequest $fixture -Verbose -Debug *>&1)
    Add-CheckResult "TLS-R01: genaue unabhaengige Projektion $kind" ($output.Count -eq 1 -and $output[0].Success -eq $true -and
        $null -eq $output[0].ErrorCode -and ($output[0].Value | ConvertTo-Json -Depth 8 -Compress) -ceq $expected[$kind] -and
        $Error.Count -eq $errorCount -and ($fixture | ConvertTo-Json -Depth 8 -Compress) -ceq $before)
    foreach ($name in @($fixture.PSObject.Properties.Name)) {
        $missing = New-TlsRequestFixture $kind; $missing.PSObject.Properties.Remove($name)
        Assert-TlsRequestRejected "TLS-R02: Pflichtfeld $kind/$name" $missing
        $nullField = New-TlsRequestFixture $kind; $nullField.$name = $null
        Assert-TlsRequestRejected "TLS-R02: Nullwert $kind/$name" $nullField
    }
    foreach ($name in @('Approved','Path','PrivateKey','Extra')) {
        $extra = New-TlsRequestFixture $kind; $extra | Add-Member -NotePropertyName $name -NotePropertyValue 'synthetic'
        Assert-TlsRequestRejected "TLS-R02: unbekanntes Feld $kind/$name" $extra
    }
    $wrongCase = New-TlsRequestFixture $kind; $wrongCase.PSObject.Properties.Remove('ContractVersion')
    $wrongCase | Add-Member -NotePropertyName contractVersion -NotePropertyValue 'SqlServerLab.AuthenticatedTlsRequest/0.1'
    Assert-TlsRequestRejected "TLS-R02: Feldname ordinal $kind" $wrongCase
}
foreach ($foreign in @($null, 'synthetic', 1, $true, @{}, [ordered]@{}, [datetime]::MinValue, { throw 'not invoked' })) {
    Assert-TlsRequestRejected 'TLS-R02: keine Coercion fremder Roottypen' $foreign
}
foreach ($reference in @('', '00000000-0000-0000-0000-000000000000','AAAAAAAA-1111-1111-1111-111111111111',
        '11111111111111111111111111111111', '11111111-1111-1111-1111-111111111111 ', [guid]::NewGuid(), 1)) {
    foreach ($name in @('RequestId','AuthorityRef')) {
        $fixture = New-TlsRequestFixture; $fixture.$name = $reference
        Assert-TlsRequestRejected "TLS-R03: kanonische Referenz $name" $fixture
    }
}
foreach ($version in @('1.0','SqlServerLab.AuthenticatedTlsRequest/0.2',1,$true)) {
    $fixture = New-TlsRequestFixture; $fixture.ContractVersion = $version
    Assert-TlsRequestRejected 'TLS-R03: keine Versionsmigration' $fixture
}
foreach ($kind in @('ca_profile','IMPORT','REMOVE','LEAF_PROFILE ')) {
    $fixture = New-TlsRequestFixture; $fixture.Kind = $kind
    Assert-TlsRequestRejected 'TLS-R03: kein Operations-/Casefallback' $fixture
}
foreach ($kind in @('CA_PROFILE','LEAF_PROFILE')) {
    foreach ($days in @(2, $(if ($kind -eq 'CA_PROFILE') {365} else {30}))) {
        $fixture = New-TlsRequestFixture $kind; $fixture.Profile.ValidityDays = $days; $fixture.Profile.RenewBeforeDays = 1
        Add-CheckResult "TLS-R04: Fristgrenze $kind/$days" (Test-LabAuthenticatedTlsRequest $fixture).Success
    }
    foreach ($days in @(0,1,366, [long]30,[double]30,[decimal]30,'30',$true)) {
        $fixture = New-TlsRequestFixture $kind; $fixture.Profile.ValidityDays = $days
        Assert-TlsRequestRejected "TLS-R04: Fristtyp/-bereich $kind" $fixture
    }
    foreach ($renew in @(0,30,31,[long]7,'7',$false)) {
        $fixture = New-TlsRequestFixture $kind; $fixture.Profile.RenewBeforeDays = $renew
        Assert-TlsRequestRejected "TLS-R04: Erneuerungsfrist $kind" $fixture
    }
    foreach ($pair in @(@('Algorithm','rsa'),@('Algorithm','ECDSA'),@('RsaBits',2048),@('RsaBits',[long]3072),@('RsaBits',4096),@('Signature','SHA1'))) {
        $fixture = New-TlsRequestFixture $kind; $fixture.Profile.($pair[0]) = $pair[1]
        Assert-TlsRequestRejected "TLS-R04: geschlossenes Profil $kind/$($pair[0])" $fixture
    }
    foreach ($name in @('Algorithm','RsaBits','Signature','ValidityDays','RenewBeforeDays')) {
        $fixture = New-TlsRequestFixture $kind; $fixture.Profile.PSObject.Properties.Remove($name)
        Assert-TlsRequestRejected "TLS-R04: fehlendes Profilfeld $kind/$name" $fixture
    }
}
$fixture = New-TlsRequestFixture LEAF_PROFILE; $fixture.Profile.ValidityDays = 31
Assert-TlsRequestRejected 'TLS-R04: Leaf hat engere Frist als CA' $fixture
foreach ($provider in @('docker','podman','hyperv')) {
    foreach ($version in @('2019','2022','2025')) {
        $fixture = New-TlsRequestFixture LEAF_PROFILE; $fixture.Provider = $provider; $fixture.SqlVersion = $version
        Add-CheckResult "TLS-R05: deklaratives Zieltupel $provider/$version" (Test-LabAuthenticatedTlsRequest $fixture).Success
    }
}
foreach ($pair in @(@('Provider','Docker'),@('Provider','unknown'),@('SqlVersion',2025),@('SqlVersion','2024'),
        @('Port',0),@('Port',65536),@('Port',[long]1433),@('Port','1433'),@('Port',$true),@('TargetRef','unknown'))) {
    $fixture = New-TlsRequestFixture LEAF_PROFILE; $fixture.($pair[0]) = $pair[1]
    Assert-TlsRequestRejected "TLS-R05: kein Ziel-/Typfallback $($pair[0])" $fixture
}
foreach ($port in @(1,65535)) {
    $fixture = New-TlsRequestFixture LEAF_PROFILE; $fixture.Port = $port
    Add-CheckResult "TLS-R05: Portgrenze $port" (Test-LabAuthenticatedTlsRequest $fixture).Success
}
foreach ($ip in @('127.0.0.1','10.23.0.10','::1')) {
    $fixture = New-TlsRequestFixture LEAF_PROFILE; $fixture.Identity.Value = $ip
    Add-CheckResult "TLS-R06: kanonischer IP-SAN $ip" (Test-LabAuthenticatedTlsRequest $fixture).Success
}
foreach ($ip in @('', '0.0.0.0','::','127.1','0x7f000001','127.000.000.001','127.0.0.1 ', '[::1]','::1%0','0:0:0:0:0:0:0:1','sql.fixture.test',1433)) {
    $fixture = New-TlsRequestFixture LEAF_PROFILE; $fixture.Identity.Value = $ip
    Assert-TlsRequestRejected 'TLS-R06: keine IP-Normalisierung oder SAN-Verwechslung' $fixture
}
$longDns = ('a' * 63) + '.' + ('b' * 63) + '.' + ('c' * 63) + '.' + ('d' * 61)
foreach ($dns in @('sql.fixture.test','a',$longDns)) {
    $fixture = New-TlsRequestFixture LEAF_PROFILE; $fixture.Identity.Kind = 'DNS'; $fixture.Identity.Value = $dns
    Add-CheckResult 'TLS-R06: expliziter DNS-SAN einschliesslich 253 Zeichen' (Test-LabAuthenticatedTlsRequest $fixture).Success
}
foreach ($dns in @('127.0.0.1','127.1','*.fixture.test','SQL.fixture.test','sql.fixture.test.','-sql.fixture.test','sql_.fixture.test',
        ('a' * 64),($longDns + 'e'),("sql`nfixture.test"),("sql`0fixture.test"),'söl.fixture.test')) {
    $fixture = New-TlsRequestFixture LEAF_PROFILE; $fixture.Identity.Kind = 'DNS'; $fixture.Identity.Value = $dns
    Assert-TlsRequestRejected 'TLS-R06: DNS-Label-/Laengen-/ASCII-/Typgrenze' $fixture
}
foreach ($platform in @('windows','linux')) {
    $fixture = New-TlsRequestFixture CLIENT_TRUST; $fixture.Platform = $platform
    $fixture.Store = if ($platform -eq 'windows') {'CURRENT_USER_ROOT'} else {'ISOLATED_CLIENT_CA_STORE'}
    $fixture.ClientStacks = [string[]]@('ODBC_SQLCMD','SYSTEM_DATA_SQLCLIENT')
    $result = Test-LabAuthenticatedTlsRequest $fixture
    Add-CheckResult "TLS-R07: beide Stacks im expliziten Kontext $platform" ($result.Success -and
        ($result.Value.ClientStacks -join ',') -ceq 'SYSTEM_DATA_SQLCLIENT,ODBC_SQLCMD')
}
foreach ($pair in @(@('Platform','Windows'),@('Platform','unknown'),@('Store','LOCAL_MACHINE_ROOT'),@('Store','ISOLATED_CLIENT_CA_STORE'),
        @('ClientRef','unknown'),@('CertificateSha256',('A' * 64)),@('CertificateSha256',('a' * 63)),@('CertificateSha256',1))) {
    $fixture = New-TlsRequestFixture CLIENT_TRUST; $fixture.($pair[0]) = $pair[1]
    Assert-TlsRequestRejected "TLS-R07: keine Trust-/Kontextcoercion $($pair[0])" $fixture
}
foreach ($stacks in @(@('ODBC_SQLCMD'),@('ODBC_SQLCMD','ODBC_SQLCMD'),@('ODBC_SQLCMD','UNKNOWN'),@('ODBC_SQLCMD','system_data_sqlclient'),
        @('ODBC_SQLCMD','SYSTEM_DATA_SQLCLIENT','UNKNOWN'),@(), 'ODBC_SQLCMD', [int[]]@(1,2), [object[,]]::new(1,2))) {
    $fixture = New-TlsRequestFixture CLIENT_TRUST; $fixture.ClientStacks = $stacks
    Assert-TlsRequestRejected 'TLS-R07: genau zwei verschiedene bekannte Clientstacks' $fixture
}

# Fremde ETS-Getter/-Methoden duerfen auch an einem ansonsten gueltigen Objekt
# oder Array nicht durch Laengen-, Typ- oder Feldpruefung ausgefuehrt werden.
$script:tlsGetterCalls = 0
foreach ($location in @('root','profile','identity')) {
    $fixture = New-TlsRequestFixture LEAF_PROFILE
    $target = switch ($location) { root {$fixture} profile {$fixture.Profile} identity {$fixture.Identity} }
    $name = switch ($location) { root {'Kind'} profile {'Algorithm'} identity {'Value'} }
    $target.PSObject.Properties.Remove($name)
    $target | Add-Member -MemberType ScriptProperty -Name $name -Value { $script:tlsGetterCalls++; throw 'getter must not execute' }
    Assert-TlsRequestRejected "TLS-R08: ScriptProperty wird nicht gelesen $location" $fixture
}
$fixture = New-TlsRequestFixture
$fixture | Add-Member -MemberType ScriptMethod -Name GetType -Force -Value { $script:tlsGetterCalls++; throw 'method must not execute' }
Add-CheckResult 'TLS-R08: native Typpruefung ignoriert GetType-ScriptMethod' (Test-LabAuthenticatedTlsRequest $fixture).Success
$fixture = New-TlsRequestFixture CLIENT_TRUST
Add-Member -InputObject $fixture.ClientStacks -MemberType ScriptProperty -Name Count -Force -Value { $script:tlsGetterCalls++; throw 'count must not execute' }
Add-CheckResult 'TLS-R08: native Arraylaenge ignoriert Count-ScriptProperty' (Test-LabAuthenticatedTlsRequest $fixture).Success
Add-CheckResult 'TLS-R08: keine fremden Getter oder Methoden ausgefuehrt' ($script:tlsGetterCalls -eq 0)

$script:tlsMetadataCalls = 0
foreach ($location in @('root','profile','identity')) {
    foreach ($member in @('BaseObject','Properties')) {
        $fixture = New-TlsRequestFixture LEAF_PROFILE
        $target = switch ($location) { root {$fixture} profile {$fixture.Profile} identity {$fixture.Identity} }
        Add-Member -InputObject $target.PSObject -MemberType ScriptProperty -Name $member -Force -Value { $script:tlsMetadataCalls++; $null }
        $nativeResult = Test-LabAuthenticatedTlsRequest $fixture
        Add-CheckResult "TLS-R08a: native PSObject-Inspektion $location/$member" ($nativeResult.Success -and
            ($nativeResult.Value | ConvertTo-Json -Depth 8 -Compress) -ceq $expected.LEAF_PROFILE)
        Add-CheckResult "TLS-R08a: PSObject-Getter nicht ausgefuehrt $location/$member" ($script:tlsMetadataCalls -eq 0)
    }
}
foreach ($member in @('Name','Value')) {
    $fixture = New-TlsRequestFixture
    $getter = if ($member -eq 'Name') { { $script:tlsMetadataCalls++; 'Kind' } } else { { $script:tlsMetadataCalls++; 'CA_PROFILE' } }
    Add-Member -InputObject $fixture.PSObject.Properties['Kind'] -MemberType ScriptProperty -Name $member -Force -Value $getter
    Add-CheckResult "TLS-R08a: native PSNoteProperty-Metadaten ignorieren ETS-$member" (
        (Test-LabAuthenticatedTlsRequest $fixture).Success -and $script:tlsMetadataCalls -eq 0)
}
$savedCulture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    foreach ($culture in @('en-US','tr-TR','cy-GB')) {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
        foreach ($ignored in @([char]0x200b,[char]0x00ad)) {
            foreach ($case in @('version','kind','algorithm','signature','provider','sqlversion','identitykind','platform','store','stack')) {
                $fixture = New-TlsRequestFixture LEAF_PROFILE
                switch ($case) {
                    version { $fixture.ContractVersion = 'SqlServerLab.' + $ignored + 'AuthenticatedTlsRequest/0.1' }
                    kind { $fixture.Kind = 'LEAF_' + $ignored + 'PROFILE' }
                    algorithm { $fixture.Profile.Algorithm = 'R' + $ignored + 'SA' }
                    signature { $fixture.Profile.Signature = 'SHA' + $ignored + '256' }
                    provider { $fixture.Provider = 'doc' + $ignored + 'ker' }
                    sqlversion { $fixture.SqlVersion = '20' + $ignored + '25' }
                    identitykind { $fixture.Identity.Kind = 'I' + $ignored + 'P' }
                    platform { $fixture = New-TlsRequestFixture CLIENT_TRUST; $fixture.Platform = 'win' + $ignored + 'dows' }
                    store { $fixture = New-TlsRequestFixture CLIENT_TRUST; $fixture.Store = 'CURRENT_' + $ignored + 'USER_ROOT' }
                    stack { $fixture = New-TlsRequestFixture CLIENT_TRUST; $fixture.ClientStacks[0] = 'SYSTEM_' + $ignored + 'DATA_SQLCLIENT' }
                }
                Assert-TlsRequestRejected "TLS-R08b: ordinaler Wert $case/$culture/$([int]$ignored)" $fixture
            }
            $fixture = New-TlsRequestFixture; $fixture.PSObject.Properties.Remove('Kind')
            $fixture | Add-Member -NotePropertyName ('Ki' + $ignored + 'nd') -NotePropertyValue 'CA_PROFILE'
            Assert-TlsRequestRejected "TLS-R08b: ordinaler Feldname $culture/$([int]$ignored)" $fixture
        }
    }
} finally { [Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture }

& {
    Set-StrictMode -Version Latest
    Assert-TlsRequestRejected 'TLS-R08c: leeres Objekt unter StrictMode' ([pscustomobject]@{})
    foreach ($kind in @('CA_PROFILE','LEAF_PROFILE','CLIENT_TRUST')) {
        Add-CheckResult "TLS-R08c: gueltige Anfrage unter StrictMode $kind" (Test-LabAuthenticatedTlsRequest (New-TlsRequestFixture $kind)).Success
        $fixture = New-TlsRequestFixture $kind
        foreach ($name in @($fixture.PSObject.Properties.Name)) {
            $missing = New-TlsRequestFixture $kind; $missing.PSObject.Properties.Remove($name)
            Assert-TlsRequestRejected "TLS-R08c: fehlendes Feld unter StrictMode $kind/$name" $missing
        }
    }
}

$fixture = New-TlsRequestFixture LEAF_PROFILE; $result = Test-LabAuthenticatedTlsRequest $fixture
$result.Value.Profile.ValidityDays = 3; $result.Value.Identity.Value = '10.23.0.11'
Add-CheckResult 'TLS-R09: tiefe getrennte Profil-/Identitaetsprojektion' ($fixture.Profile.ValidityDays -eq 30 -and $fixture.Identity.Value -ceq '127.0.0.1')
$fixture = New-TlsRequestFixture CLIENT_TRUST; $result = Test-LabAuthenticatedTlsRequest $fixture
$result.Value.ClientStacks[0] = 'changed'
Add-CheckResult 'TLS-R09: Clientarray nicht mit Caller geteilt' ($fixture.ClientStacks[0] -ceq 'SYSTEM_DATA_SQLCLIENT')
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$parseErrors)
Add-CheckResult 'TLS-R10: beim Dot-Sourcing ausschliesslich Funktionsdefinitionen' ($parseErrors.Count -eq 0 -and
    @($ast.EndBlock.Statements | Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] }).Count -eq 0)
$calls = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true) | ForEach-Object GetCommandName)
Add-CheckResult 'TLS-R10: geschlossener privater Commandgraph ohne Host-/PKI-/SQL-Aufruf' (
    @($calls | Where-Object { $_ -cnotin @('Get-LabTlsRequestFields','Test-LabTlsRequestReference','Test-LabTlsRequestEnum','Get-LabTlsRequestProfile','Get-LabTlsRequestIdentity') }).Count -eq 0)

Write-Host "Authenticated TLS Request: $passed PASS, $($failures.Count) FAIL"
if ($failures.Count) { throw 'AUTHENTICATED_TLS_REQUEST_CHECKS_FAILED' }
