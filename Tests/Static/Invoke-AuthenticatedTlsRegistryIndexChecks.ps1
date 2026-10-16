#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsRequest.ps1')
$source=Join-Path $repo 'Private/AuthenticatedTlsRegistryIndex.ps1';. $source
$passed=0;$failures=[Collections.Generic.List[string]]::new()
function Get-TlsIndexFixtureRef {param([int]$Number) return ('00000000-0000-4000-8000-{0:d12}' -f $Number)}
function Get-TlsIndexFixtureRecord {
    param([string]$Kind='CLIENT_CONTEXT',[int]$Number=1)
    $record=[ordered]@{Kind=$Kind;Ref=(Get-TlsIndexFixtureRef $Number);Generation=1;Status='ACTIVE';IdentityDigest=('a'*64);RevisionDigest=('b'*64)}
    if($Kind -ceq 'AUTHORITY'){$record.SignerContextRef=Get-TlsIndexFixtureRef 2;$record.SignerGeneration=1}
    return [pscustomobject]$record
}
function Get-TlsIndexFixture {
    return [pscustomobject][ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryIndex/0.1';ControllerId='11111111-1111-4111-8111-111111111111';
        LocationId='22222222-2222-4222-8222-222222222222';Revision=1;Records=@((Get-TlsIndexFixtureRecord),(Get-TlsIndexFixtureRecord SIGNER_CONTEXT 2),(Get-TlsIndexFixtureRecord AUTHORITY 3))}
}
function Get-TlsIndexFixtureBytes {
    param([object]$Value)
    return ,[Text.UTF8Encoding]::new($false,$true).GetBytes(($Value|ConvertTo-Json -Depth 12 -Compress))
}
function Assert-TlsIndexRejected {
    param([object]$Bytes)
    $all=@(Read-LabAuthenticatedTlsRegistryIndex $Bytes *>&1)
    Add-CheckResult 'TLS-I01 geschlossene Ablehnung ohne Diagnose' ($all.Count -eq 1 -and -not $all[0].Success -and $null -eq $all[0].Value -and
        $all[0].ErrorCode -ceq 'TLS_REGISTRY_INDEX_INVALID' -and ($all|ConvertTo-Json -Compress) -notmatch 'TLS_INDEX_PRIVATE_CANARY')
}
function Assert-TlsTransition {
    param([object]$Before,[object]$After,[bool]$Expected)
    $all=@(Test-LabAuthenticatedTlsRegistryTransition (Get-TlsIndexFixtureBytes $Before) (Get-TlsIndexFixtureBytes $After) *>&1)
    $closed=$all.Count -eq 1 -and @($all[0].PSObject.Properties).Count -eq 3 -and $all[0].Success -eq $Expected
    if($Expected){$closed=$closed -and $null -eq $all[0].ErrorCode -and $all[0].Value.Status -ceq 'OFFLINE_TRANSITION_ONLY' -and
        -not $all[0].Value.Ready -and -not $all[0].Value.MutationAllowed -and $all[0].Value.RegistrationStatus -ceq 'NOT_EXECUTED' -and $all[0].Value.QualificationStatus -ceq 'NOT_EXECUTED'}
    else{$closed=$closed -and $null -eq $all[0].Value -and $all[0].ErrorCode -ceq 'TLS_REGISTRY_TRANSITION_INVALID'}
    Add-CheckResult "TLS-I04 Uebergang erwartet $Expected" $closed
}
& {
    Set-StrictMode -Version Latest
    $fixture=Get-TlsIndexFixture;$bytes=Get-TlsIndexFixtureBytes $fixture
    $parsed=Read-LabAuthenticatedTlsRegistryIndex $bytes
    Add-CheckResult 'TLS-I01 geschlossene frische Indexprojektion' ($parsed.Success -and $null -eq $parsed.ErrorCode -and @($parsed.Value.PSObject.Properties).Count -eq 5 -and
        $parsed.Value.Records.Count -eq 3 -and @($parsed.Value.Records[0].PSObject.Properties).Count -eq 6 -and @($parsed.Value.Records[2].PSObject.Properties).Count -eq 8)
    [array]::Clear($bytes,0,$bytes.Length)
    Add-CheckResult 'TLS-I01 keine Callerbytes oder JsonElement im Ergebnis' ($parsed.Value.Records[0].Ref -ceq (Get-TlsIndexFixtureRef 1) -and
        $parsed.Value.Records[0] -is [pscustomobject] -and $parsed.Value.Records[0].Generation -is [int])
    $empty=Get-TlsIndexFixture;$empty.Revision=0;$empty.Records=@()
    Add-CheckResult 'TLS-I01 leerer Ausgangsindex Revision0' (Read-LabAuthenticatedTlsRegistryIndex (Get-TlsIndexFixtureBytes $empty)).Success
    foreach($field in @('ContractVersion','ControllerId','LocationId','Revision','Records')){
        $bad=Get-TlsIndexFixture;$bad.PSObject.Properties.Remove($field);Assert-TlsIndexRejected (Get-TlsIndexFixtureBytes $bad)
        $bad=Get-TlsIndexFixture;$bad.$field=$null;Assert-TlsIndexRejected (Get-TlsIndexFixtureBytes $bad)
    }
    foreach($kind in @('CLIENT_CONTEXT','SIGNER_CONTEXT','AUTHORITY')){
        $template=Get-TlsIndexFixtureRecord $kind 3
        foreach($field in @($template.PSObject.Properties.Name)){
            $bad=Get-TlsIndexFixture;$bad.Records[2]=Get-TlsIndexFixtureRecord $kind 3;$bad.Records[2].PSObject.Properties.Remove($field)
            Assert-TlsIndexRejected (Get-TlsIndexFixtureBytes $bad)
        }
        $bad=Get-TlsIndexFixture;$bad.Records[2]=Get-TlsIndexFixtureRecord $kind 3;$bad.Records[2]|Add-Member NoteProperty Approved $true
        Assert-TlsIndexRejected (Get-TlsIndexFixtureBytes $bad)
    }
    foreach($field in @('Ref','IdentityDigest','RevisionDigest','Status','Kind')){
        foreach($value in @('TLS_INDEX_PRIVATE_CANARY',1,$true,'')){
            $bad=Get-TlsIndexFixture;$bad.Records[0].$field=$value;Assert-TlsIndexRejected (Get-TlsIndexFixtureBytes $bad)
        }
    }
    foreach($field in @('IdentityDigest','RevisionDigest')){
        $bad=Get-TlsIndexFixture;$bad.Records[0].$field='A'*64;Assert-TlsIndexRejected (Get-TlsIndexFixtureBytes $bad)
    }
    foreach($number in @(-1,0,'1',1.5,2147483648,$true)){
        $bad=Get-TlsIndexFixture;$bad.Records[0].Generation=$number;Assert-TlsIndexRejected (Get-TlsIndexFixtureBytes $bad)
        $bad=Get-TlsIndexFixture;$bad.Records[2].SignerGeneration=$number;Assert-TlsIndexRejected (Get-TlsIndexFixtureBytes $bad)
    }
    foreach($number in @(-1,'1',1.5,2147483648,$true)){
        $bad=Get-TlsIndexFixture;$bad.Revision=$number;Assert-TlsIndexRejected (Get-TlsIndexFixtureBytes $bad)
    }
    $raw=(Get-TlsIndexFixture|ConvertTo-Json -Depth 12 -Compress)
    foreach($json in @($raw.Replace('"Generation":1','"Generation":1.0'),$raw.Replace('"Revision":1','"Revision":1e0'),
        $raw.Replace('"Revision":1','"Revision":1,"Revision":2'),$raw.Replace('"Revision":1','"Revision":1,"revision":2'),
        $raw.Replace('"Generation":1','"Generation":1,"Generation":2'),$raw.Replace('"Ref":','"Ref":"TLS_INDEX_PRIVATE_CANARY","Ref":'),
        $raw.Replace('"Revision":1','"Revision":1,"Revi\u0073ion":2'),$raw.Replace('"Revision":1','"Revision":1,/*comment*/'),
        $raw.TrimEnd('}')+',}',('['*7+'0'+']'*7),'[]','null','"TLS_INDEX_PRIVATE_CANARY"')){
        Assert-TlsIndexRejected ([Text.Encoding]::UTF8.GetBytes($json))
    }
    Assert-TlsIndexRejected ([byte[]]@(0xc3,0x28))
    Assert-TlsIndexRejected ([byte[]](@(0xef,0xbb,0xbf)+[Text.Encoding]::UTF8.GetBytes($raw)))
    foreach($bad in @($null,'TLS_INDEX_PRIVATE_CANARY',1,$true,@(1,2,3),[byte[]]@(),[byte[]]::new(131073))){Assert-TlsIndexRejected $bad}
    $script:foreignCalls=0
    $alien=[pscustomobject]@{};$alien|Add-Member ScriptMethod ToString {$script:foreignCalls++;throw 'TLS_INDEX_PRIVATE_CANARY getter'} -Force
    Assert-TlsIndexRejected $alien
    $decorated=Get-TlsIndexFixtureBytes (Get-TlsIndexFixture)
    $decorated|Add-Member ScriptProperty Length {$script:foreignCalls++;throw 'TLS_INDEX_PRIVATE_CANARY length'} -Force
    Add-CheckResult 'TLS-I02 ETS-Length wird nicht ausgefuehrt' (Read-LabAuthenticatedTlsRegistryIndex $decorated).Success
    Add-CheckResult 'TLS-I02 keine fremden Getter/Casts' ($script:foreignCalls -eq 0)
    $padding=' '*(131072-[Text.Encoding]::UTF8.GetByteCount($raw))
    Add-CheckResult 'TLS-I02 exakte Byteobergrenze' (Read-LabAuthenticatedTlsRegistryIndex ([Text.Encoding]::UTF8.GetBytes($raw+$padding))).Success
    Assert-TlsIndexRejected ([Text.Encoding]::UTF8.GetBytes($raw+$padding+' '))
    $limit=Get-TlsIndexFixture;$limit.Records=@(1..256|ForEach-Object {Get-TlsIndexFixtureRecord CLIENT_CONTEXT $_})
    Add-CheckResult 'TLS-I02 256 geschlossene Records' (Read-LabAuthenticatedTlsRegistryIndex (Get-TlsIndexFixtureBytes $limit)).Success
    $limit.Records+=Get-TlsIndexFixtureRecord CLIENT_CONTEXT 257;Assert-TlsIndexRejected (Get-TlsIndexFixtureBytes $limit)
    $bad=Get-TlsIndexFixture;$bad.Records[1].Ref=$bad.Records[0].Ref;Assert-TlsIndexRejected (Get-TlsIndexFixtureBytes $bad)
    $bad=Get-TlsIndexFixture;$bad.Revision=0;Assert-TlsIndexRejected (Get-TlsIndexFixtureBytes $bad)
    $bad=Get-TlsIndexFixture;$bad.Records=@();Assert-TlsIndexRejected (Get-TlsIndexFixtureBytes $bad)
    foreach($change in @('missing','client','future','retired','stale')){
        $bad=Get-TlsIndexFixture
        switch($change){
            missing {$bad.Records[2].SignerContextRef=Get-TlsIndexFixtureRef 8}
            client {$bad.Records[2].SignerContextRef=Get-TlsIndexFixtureRef 1}
            future {$bad.Records[2].SignerGeneration=2}
            retired {$bad.Records[1].Status='RETIRED'}
            stale {$bad.Records[1].Generation=2}
        }
        Assert-TlsIndexRejected (Get-TlsIndexFixtureBytes $bad)
    }
    $history=Get-TlsIndexFixture;$history.Records[1].Generation=2;$history.Records[1].Status='RETIRED';$history.Records[2].Status='RETIRED'
    Add-CheckResult 'TLS-I03 historischer CA-Tombstone behaelt Signiergeneration' (Read-LabAuthenticatedTlsRegistryIndex (Get-TlsIndexFixtureBytes $history)).Success
    $saved=[Threading.Thread]::CurrentThread.CurrentCulture
    try{
        foreach($culture in @('en-US','de-DE','tr-TR')){
            [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($culture)
            foreach($char in @([char]0x200b,[char]0x00ad)){
                foreach($field in @('Kind','Status')){$bad=Get-TlsIndexFixture;$bad.Records[0].$field+=$char;Assert-TlsIndexRejected (Get-TlsIndexFixtureBytes $bad)}
                $bad=Get-TlsIndexFixture;$bad.ContractVersion+=$char;Assert-TlsIndexRejected (Get-TlsIndexFixtureBytes $bad)
            }
        }
    }finally{[Threading.Thread]::CurrentThread.CurrentCulture=$saved}

    $base=Get-TlsIndexFixture;$base.Revision=0;$base.Records=@()
    Assert-TlsTransition $base (Get-TlsIndexFixture) $true
    $base=Get-TlsIndexFixture
    Assert-TlsTransition $base $base $false
    $next=Get-TlsIndexFixture;$next.Revision=2;Assert-TlsTransition $base $next $false
    foreach($change in @('add','update','retire','rotateSigner','retireBoth')){
        $next=Get-TlsIndexFixture;$next.Revision=2
        switch($change){
            add {$next.Records+=Get-TlsIndexFixtureRecord CLIENT_CONTEXT 4}
            update {$next.Records[0].Generation=2;$next.Records[0].RevisionDigest='c'*64}
            retire {$next.Records[0].Status='RETIRED'}
            rotateSigner {$next.Records[1].Generation=2;$next.Records[1].RevisionDigest='c'*64;$next.Records[2].Generation=2;$next.Records[2].RevisionDigest='d'*64;$next.Records[2].SignerGeneration=2}
            retireBoth {$next.Records[1].Status='RETIRED';$next.Records[2].Status='RETIRED'}
        }
        Assert-TlsTransition $base $next $true
    }
    foreach($change in @('controller','location','skipRevision','delete','reuseRole','identity','digestOnly','generationOnly','skipGeneration','retireWithChange','newRetired','newGeneration','moveSigner','edgeWithoutGeneration')){
        $next=Get-TlsIndexFixture;$next.Revision=2
        switch($change){
            controller {$next.ControllerId=Get-TlsIndexFixtureRef 20}
            location {$next.LocationId=Get-TlsIndexFixtureRef 20}
            skipRevision {$next.Revision=3}
            delete {$next.Records=$next.Records[1..2]}
            reuseRole {$next.Records[0].Kind='SIGNER_CONTEXT'}
            identity {$next.Records[0].IdentityDigest='c'*64}
            digestOnly {$next.Records[0].RevisionDigest='c'*64}
            generationOnly {$next.Records[0].Generation=2}
            skipGeneration {$next.Records[0].Generation=3;$next.Records[0].RevisionDigest='c'*64}
            retireWithChange {$next.Records[0].Status='RETIRED';$next.Records[0].RevisionDigest='c'*64}
            newRetired {$r=Get-TlsIndexFixtureRecord CLIENT_CONTEXT 4;$r.Status='RETIRED';$next.Records+=$r}
            newGeneration {$r=Get-TlsIndexFixtureRecord CLIENT_CONTEXT 4;$r.Generation=2;$next.Records+=$r}
            moveSigner {$next.Records+=Get-TlsIndexFixtureRecord SIGNER_CONTEXT 4;$next.Records[2].SignerContextRef=Get-TlsIndexFixtureRef 4;$next.Records[2].Generation=2;$next.Records[2].RevisionDigest='c'*64}
            edgeWithoutGeneration {$next.Records[1].Generation=2;$next.Records[1].RevisionDigest='c'*64;$next.Records[2].SignerGeneration=2}
        }
        Assert-TlsTransition $base $next $false
    }
    $tombstone=Get-TlsIndexFixture;$tombstone.Records[0].Status='RETIRED'
    foreach($change in @('revive','digest','generation','drop')){
        $next=Get-TlsIndexFixture;$next.Revision=2;$next.Records[0].Status='RETIRED';$next.Records+=Get-TlsIndexFixtureRecord CLIENT_CONTEXT 4
        switch($change){revive {$next.Records[0].Status='ACTIVE'} digest {$next.Records[0].RevisionDigest='c'*64} generation {$next.Records[0].Generation=2} drop {$next.Records=$next.Records[1..3]}}
        Assert-TlsTransition $tombstone $next $false
    }
    $ceiling=Get-TlsIndexFixture;$ceiling.Revision=[int]::MaxValue
    $next=Get-TlsIndexFixture;$next.Revision=0;Assert-TlsTransition $ceiling $next $false
    $ceiling=Get-TlsIndexFixture;$ceiling.Records[0].Generation=[int]::MaxValue
    $next=Get-TlsIndexFixture;$next.Revision=2;$next.Records[0].Generation=1;$next.Records[0].RevisionDigest='c'*64;Assert-TlsTransition $ceiling $next $false
    $next=Get-TlsIndexFixture;$next.Revision=2;$next.Records+=Get-TlsIndexFixtureRecord CLIENT_CONTEXT 9;$next.Records+=Get-TlsIndexFixtureRecord CLIENT_CONTEXT 4
    $next.Records=[object[]]@($next.Records[4],$next.Records[2],$next.Records[0],$next.Records[3],$next.Records[1])
    $result=Test-LabAuthenticatedTlsRegistryTransition (Get-TlsIndexFixtureBytes $base) (Get-TlsIndexFixtureBytes $next)
    Add-CheckResult 'TLS-I05 ordinal sortierte Deltas ohne Reihenfolgenbindung' ($result.Success -and ($result.Value.AddedRefs -join ',') -ceq ((Get-TlsIndexFixtureRef 4)+','+(Get-TlsIndexFixtureRef 9)) -and
        $result.Value.UpdatedRefs.Count -eq 0 -and $result.Value.RetiredRefs.Count -eq 0 -and @($result.Value.PSObject.Properties).Count -eq 13)
    $result=Test-LabAuthenticatedTlsRegistryTransition 'TLS_INDEX_PRIVATE_CANARY' (Get-TlsIndexFixtureBytes $next)
    Add-CheckResult 'TLS-I05 ungueltige Ausgangsbytes sperren Uebergang' (-not $result.Success -and $null -eq $result.Value -and $result.ErrorCode -ceq 'TLS_REGISTRY_TRANSITION_INVALID')
    $result=Test-LabAuthenticatedTlsRegistryTransition (Get-TlsIndexFixtureBytes $base) 'TLS_INDEX_PRIVATE_CANARY'
    Add-CheckResult 'TLS-I05 ungueltige Kandidatenbytes sperren Uebergang' (-not $result.Success -and $null -eq $result.Value -and $result.ErrorCode -ceq 'TLS_REGISTRY_TRANSITION_INVALID')
    $first=Get-TlsIndexFixture;$first.Revision=2;$first.Records+=Get-TlsIndexFixtureRecord CLIENT_CONTEXT 4
    $second=Get-TlsIndexFixture;$second.Revision=2;$second.Records+=Get-TlsIndexFixtureRecord CLIENT_CONTEXT 5
    Assert-TlsTransition $base $first $true
    Assert-TlsTransition $base $second $true
    Assert-TlsTransition $first $second $false
    $next=Get-TlsIndexFixture;$next.Revision=2;$next.Records[1].Generation=2;$next.Records[1].RevisionDigest='c'*64;$next.Records[2].Status='RETIRED'
    Assert-TlsTransition $base $next $true
}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
Add-CheckResult 'TLS-I06 beim Laden nur Definitionen' ($errors.Count -eq 0 -and @($ast.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count -eq 0)
$commands=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object GetCommandName)
Add-CheckResult 'TLS-I06 reiner In-Memory-Commandgraph' (@($commands|Where-Object {$_ -cnotin @('Get-LabTlsIndexFields','Get-LabTlsIndexString','Get-LabTlsIndexInteger','Test-LabTlsRequestEnum','Test-LabTlsRequestReference','Read-LabAuthenticatedTlsRegistryIndex')}).Count -eq 0)
$types=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.TypeExpressionAst]},$true)|ForEach-Object {$_.TypeName.FullName})
Add-CheckResult 'TLS-I06 keine I/O-/Prozess-/SQL-/PKI-Typen' (@($types|Where-Object {$_ -match '(?i)\A(IO\.|Microsoft\.Win32|Diagnostics\.|Security\.|Net\.|.*SqlConnection)'}).Count -eq 0)
Write-Host "Authenticated TLS Registry Index: $passed PASS, $($failures.Count) FAIL"
if($failures.Count){throw 'AUTHENTICATED_TLS_REGISTRY_INDEX_CHECKS_FAILED'}
