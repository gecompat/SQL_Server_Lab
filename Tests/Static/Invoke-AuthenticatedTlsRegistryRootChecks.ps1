#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
foreach($name in @('DiagnosticBundleReader','AuthenticatedTlsRequest','AuthenticatedTlsRegistryIndex','AuthenticatedTlsRegistryPayload','AuthenticatedTlsRegistryDocument','AuthenticatedTlsRegistryRoot')){. (Join-Path $repo "Private/$name.ps1")}
$passed=0;$failures=[Collections.Generic.List[string]]::new()
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-tls-root-'+[guid]::NewGuid().ToString('N'))
$controller='11111111-1111-4111-8111-111111111111';$location='22222222-2222-4222-8222-222222222222'
function Write-TlsRootFixtureJson {param([string]$Path,[object]$Value) $Value|ConvertTo-Json -Depth 16 -Compress|Set-Content -LiteralPath $Path -Encoding utf8}
function Reset-TlsRootFixture {
    $script:dataRoot=Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path (Join-Path $script:dataRoot 'Catalog'),(Join-Path $script:dataRoot 'State/authenticated-tls') -Force
    $script:markerPath=Join-Path $script:dataRoot '.sql-server-lab-root.json';$script:catalogPath=Join-Path $script:dataRoot 'Catalog/storage-locations.json';$script:registryPath=Join-Path $script:dataRoot 'State/authenticated-tls/registry.json'
    $script:marker=[pscustomobject]@{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId='synthetic-volume';DataRoot=$script:dataRoot}
    $script:catalog=[pscustomobject]@{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@([pscustomobject]@{LocationId=$location;ControllerId=$controller;VolumeId='synthetic-volume';LabDataRoot=$script:dataRoot})}
    $script:registry=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsContextRegistry/0.1';Index=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryIndex/0.1';ControllerId=$controller;LocationId=$location;Revision=0;Records=@()};Payloads=@()}
    Save-TlsRootFixture
}
function Save-TlsRootFixture {
    Write-TlsRootFixtureJson $script:markerPath $script:marker;Write-TlsRootFixtureJson $script:catalogPath $script:catalog;Write-TlsRootFixtureJson $script:registryPath $script:registry
}
function Get-TlsRootFixtureResult {Get-LabAuthenticatedTlsRegistryRoot $script:dataRoot $controller $location}
function Get-TlsRootFixtureSnapshot {
    return (@(Get-ChildItem -LiteralPath $fixtureRoot -File -Recurse|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join '|')
}
function Assert-TlsRootRejected {param([object[]]$Result)
    Add-CheckResult 'TLS-R02 geschlossene Ablehnung ohne Teilbefund/Rohdiagnose' ($Result.Count -eq 1 -and @($Result[0].PSObject.Properties).Count -eq 3 -and -not $Result[0].Success -and $null -eq $Result[0].Value -and $Result[0].ErrorCode -ceq 'TLS_REGISTRY_ROOT_INVALID')
}
$script:nativeCalls=0
function Get-LabAuthenticatedTlsContextPreview { $script:nativeCalls++;throw 'TLS_ROOT_PRIVATE_CANARY' }
try {
    & {
        Set-StrictMode -Version Latest
        $actualWindows=[Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)
        $realJson=${function:Read-LabDiagnosticJson};$script:jsonCalls=0
        function Read-LabDiagnosticJson {param($Path,$MaximumBytes,$MaximumDepth) $script:jsonCalls++;throw 'TLS_ROOT_PRIVATE_CANARY'}
        try {
            foreach($bad in @($null,'',@('C:\lab'),[pscustomobject]@{},12,'relative','C:','C:\','\\host\share\lab','C:\lab\..\other','C:\lab\registry.json:stream','C:\lab.','C:\lab ','C:\lab\*')){
                Assert-TlsRootRejected @(Get-LabAuthenticatedTlsRegistryRoot $bad $controller $location *>&1)
            }
            foreach($bad in @($null,'',@($controller),[pscustomobject]@{},$controller.ToUpperInvariant(),($controller+[char]0x200b))){
                if($bad -ceq $controller){continue}
                Assert-TlsRootRejected @(Get-LabAuthenticatedTlsRegistryRoot 'C:\lab' $bad $location *>&1)
                Assert-TlsRootRejected @(Get-LabAuthenticatedTlsRegistryRoot 'C:\lab' $controller $bad *>&1)
            }
            $script:foreignCalls=0;$alien=[pscustomobject]@{};$alien|Add-Member ScriptMethod ToString {$script:foreignCalls++;throw 'TLS_ROOT_PRIVATE_CANARY'} -Force
            Assert-TlsRootRejected @(Get-LabAuthenticatedTlsRegistryRoot $alien $controller $location *>&1)
            Add-CheckResult 'TLS-R01 keine fremden Casts und kein Read vor Eingabepruefung' ($script:foreignCalls -eq 0 -and $script:jsonCalls -eq 0)
        } finally {Set-Item function:Read-LabDiagnosticJson $realJson}
        if(-not $actualWindows){
            Assert-TlsRootRejected @(Get-LabAuthenticatedTlsRegistryRoot 'C:\lab' $controller $location *>&1)
            Write-Host 'TLS-R Windows-Dateifalle: NOT_EXECUTED auf Nicht-Windows; keine Plattformqualifikation'
            return
        }
        Reset-TlsRootFixture;$snapshot=Get-TlsRootFixtureSnapshot;$r=Get-TlsRootFixtureResult
        Add-CheckResult 'TLS-R03 bestehender Root und vollstaendige leere Registry beobachtet' ($r.Success -and @($r.Value.PSObject.Properties).Count -eq 16 -and $r.Value.Status -ceq 'REGISTERED_ROOT_METADATA_MATCH' -and
            $r.Value.DataRoot -ceq $script:dataRoot -and $r.Value.ControllerId -ceq $controller -and $r.Value.LocationId -ceq $location -and
            $r.Value.RegistryPath -ceq $script:registryPath -and $r.Value.RootBindingStatus -ceq 'REGISTERED_METADATA_MATCH' -and $r.Value.NativeBindingStatus -ceq 'NOT_EXECUTED' -and
            $r.Value.RegistrationStatus -ceq 'NOT_EXECUTED' -and $r.Value.QualificationStatus -ceq 'NOT_EXECUTED' -and $r.Value.SnapshotStatus -ceq 'NON_ATOMIC_READ' -and -not $r.Value.Ready -and -not $r.Value.MutationAllowed)
        Add-CheckResult 'TLS-R03 keine Dateimutation' ($snapshot -ceq (Get-TlsRootFixtureSnapshot))
        Add-CheckResult 'TLS-R03 Originalbytehash und getrennte Metadatendigests' ($r.Value.RegistryByteSha256 -ceq (Get-FileHash -LiteralPath $script:registryPath).Hash.ToLowerInvariant() -and $r.Value.ContentDigest -cmatch '\A[0-9a-f]{64}\z' -and $r.Value.RootMetadataDigest -cmatch '\A[0-9a-f]{64}\z')
        Add-CheckResult 'TLS-R03 ausdruecklicher Root darf abschliessenden Separator haben' (Get-LabAuthenticatedTlsRegistryRoot ($script:dataRoot+'\') $controller $location).Success
        $decorated=[string]::Concat($script:dataRoot);$decorated|Add-Member ScriptMethod Substring {$script:foreignCalls++;throw 'TLS_ROOT_PRIVATE_CANARY'} -Force
        $decorated|Add-Member ScriptProperty Length {$script:foreignCalls++;throw 'TLS_ROOT_PRIVATE_CANARY'} -Force
        Add-CheckResult 'TLS-R03 keine Caller-ETS-Laenge oder Substring' ((Get-LabAuthenticatedTlsRegistryRoot $decorated $controller $location).Success -and $script:foreignCalls -eq 0)
        $payload=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryPayload/0.1';ControllerId=$controller;LocationId=$location;Kind='SIGNER_CONTEXT';Ref='33333333-3333-4333-8333-333333333333';Generation=1;Status='ACTIVE';Context='CURRENT_WINDOWS_PROCESS';
            Actor=[pscustomobject]@{UserSid='S-1-5-21-100-200-300-1001';HostMarker='77777777-7777-4777-8777-777777777777';ProfilePath='C:\lab\profile'};
            Details=[pscustomobject]@{Backend='DOTNET_X509';RuntimeVersion='10.0.12';ApiStatus='COMPLETE';Apis=@('REQUEST_RSA_CONSTRUCTOR','CSR_CREATE_DER','CSR_LOAD_DER','CERTIFICATE_CREATE','SAN_IP','SAN_DNS'|ForEach-Object {[pscustomobject]@{Id=$_;Present=$true}});KeyProtectionStatus='NOT_EVALUATED'}}
        $parsed=Read-LabAuthenticatedTlsRegistryPayload ([Text.Encoding]::UTF8.GetBytes(($payload|ConvertTo-Json -Depth 10 -Compress)))
        $script:registry.Index.Revision=1;$script:registry.Index.Records=@($parsed.Value.IndexRecord);$script:registry.Payloads=@($payload);Save-TlsRootFixture
        $nonempty=Get-TlsRootFixtureResult
        Add-CheckResult 'TLS-R03 vollstaendige nichtleere Payloadkomposition' ($nonempty.Success -and $nonempty.Value.RegistryDocument.Payloads.Count -eq 1 -and $nonempty.Value.RegistryDocument.Index.Records.Count -eq 1 -and -not $nonempty.Value.Ready)
        foreach($change in @('markerContract','owner','controller','markerRoot','volume','catalogContract','catalogController','empty','tooMany','duplicateRoot','duplicateId','location','selectedController','selectedVolume','rootType','locationsType','registryController','registryLocation','partialRegistry')){
            Reset-TlsRootFixture
            switch($change){
                markerContract {$script:marker.ContractVersion='legacy'} owner {$script:marker.ManagedBy='foreign'} controller {$script:marker.ControllerId=$location} markerRoot {$script:marker.DataRoot+='-other'} volume {$script:marker.VolumeId=$null}
                catalogContract {$script:catalog.ContractVersion='legacy'} catalogController {$script:catalog.ControllerId=$location} empty {$script:catalog.LabDataLocations=@()}
                tooMany {$script:catalog.LabDataLocations=@(1..33|ForEach-Object {$script:catalog.LabDataLocations[0]})}
                duplicateRoot {$script:catalog.LabDataLocations+= $script:catalog.LabDataLocations[0]}
                duplicateId {$script:catalog.LabDataLocations+=[pscustomobject]@{LocationId=$location;LabDataRoot='C:\other'}}
                location {$script:catalog.LabDataLocations[0].LocationId=$controller} selectedController {$script:catalog.LabDataLocations[0].ControllerId=$location} selectedVolume {$script:catalog.LabDataLocations[0].VolumeId='foreign'}
                rootType {$script:catalog.LabDataLocations[0].LabDataRoot=@($script:dataRoot)} locationsType {$script:catalog.LabDataLocations=$script:catalog.LabDataLocations[0]}
                registryController {$script:registry.Index.ControllerId=$location} registryLocation {$script:registry.Index.LocationId=$controller} partialRegistry {$script:registry.Payloads=@([pscustomobject]@{})}
            }
            Save-TlsRootFixture;Assert-TlsRootRejected @(Get-TlsRootFixtureResult *>&1)
        }
        foreach($file in @('markerPath','catalogPath','registryPath')){
            Reset-TlsRootFixture;$path=(Get-Variable -Name $file -Scope Script).Value;Remove-Item -LiteralPath $path
            $snapshot=Get-TlsRootFixtureSnapshot;Assert-TlsRootRejected @(Get-TlsRootFixtureResult *>&1)
            Add-CheckResult 'TLS-R04 keine Anlage oder Adoption bei fehlender Datei' ($snapshot -ceq (Get-TlsRootFixtureSnapshot))
            Reset-TlsRootFixture;$path=(Get-Variable -Name $file -Scope Script).Value;[IO.File]::WriteAllText($path,'{"ControllerId":"TLS_ROOT_PRIVATE_CANARY","controllerId":"alias"}')
            Assert-TlsRootRejected @(Get-TlsRootFixtureResult *>&1)
        }
        Reset-TlsRootFixture;$raw=[IO.File]::ReadAllText($script:registryPath)
        [IO.File]::WriteAllBytes($script:registryPath,[Text.Encoding]::UTF8.GetBytes($raw+(' '*(4194304-[Text.Encoding]::UTF8.GetByteCount($raw)))))
        Add-CheckResult 'TLS-R05 exakte Dateibytegrenze' (Get-TlsRootFixtureResult).Success
        $stream=[IO.File]::OpenWrite($script:registryPath);try{$stream.SetLength(4194305)}finally{$stream.Dispose()};Assert-TlsRootRejected @(Get-TlsRootFixtureResult *>&1)
        foreach($bytes in @([byte[]]@(),[byte[]]@(0xc3,0x28),[byte[]]@(0xef,0xbb,0xbf,0x7b,0x7d))){Reset-TlsRootFixture;[IO.File]::WriteAllBytes($script:registryPath,$bytes);Assert-TlsRootRejected @(Get-TlsRootFixtureResult *>&1)}
        Reset-TlsRootFixture;$stream=[IO.File]::Open($script:registryPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{Assert-TlsRootRejected @(Get-TlsRootFixtureResult *>&1)}finally{$stream.Dispose()}
        $realBytes=${function:Read-LabTlsRegistryFileBytes}
        foreach($drift in @('registry','marker','catalog')){
            Reset-TlsRootFixture;$script:byteCalls=0;$script:jsonCalls=0;$script:driftKind=$drift
            function Read-LabTlsRegistryFileBytes {param($Path) $script:byteCalls++;$bytes=& $realBytes $Path;if($script:driftKind -ceq 'registry' -and $script:byteCalls -eq 2){$bytes[0]=0};return ,$bytes}
            function Read-LabDiagnosticJson {param($Path,$MaximumBytes,$MaximumDepth) $script:jsonCalls++;$v=& $realJson -Path $Path -MaximumBytes $MaximumBytes -MaximumDepth $MaximumDepth;if(($script:driftKind -ceq 'marker' -and $script:jsonCalls -eq 3) -or ($script:driftKind -ceq 'catalog' -and $script:jsonCalls -eq 4)){$v.ControllerId=$location};return $v}
            try{Assert-TlsRootRejected @(Get-TlsRootFixtureResult *>&1)}finally{Set-Item function:Read-LabTlsRegistryFileBytes $realBytes;Set-Item function:Read-LabDiagnosticJson $realJson}
        }
        Reset-TlsRootFixture;$link=Join-Path $fixtureRoot 'own-link';$null=New-Item -ItemType Junction -Path $link -Target $script:dataRoot
        try{Assert-TlsRootRejected @(Get-LabAuthenticatedTlsRegistryRoot $link $controller $location *>&1)}finally{Remove-Item -LiteralPath $link -Force}
    }
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Private/AuthenticatedTlsRegistryRoot.ps1'),[ref]$tokens,[ref]$errors)
    Add-CheckResult 'TLS-R06 Laden definiert nur Funktionen' ($errors.Count -eq 0 -and @($ast.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count -eq 0)
    $calls=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object GetCommandName)
    Add-CheckResult 'TLS-R06 nur lesender fester Commandgraph' (@($calls|Where-Object {$_ -cnotin @('Assert-LabDiagnosticPath','Get-Item','Test-LabTlsRequestReference','Test-Path','Join-Path','Read-LabDiagnosticJson','Test-LabTlsRequestEnum','ConvertTo-Json','Read-LabTlsRegistryFileBytes','Read-LabAuthenticatedTlsRegistryDocument','Get-LabTlsPayloadDigest','Get-LabAuthenticatedTlsRootMetadata')}).Count -eq 0)
    Add-CheckResult 'TLS-R06 keine native Kontext-/PKI-/SQL-Probe' ($script:nativeCalls -eq 0)
    Write-Host "Authenticated TLS Registry Root: $passed PASS, $($failures.Count) FAIL"
    if($failures.Count){throw 'AUTHENTICATED_TLS_REGISTRY_ROOT_CHECKS_FAILED'}
} finally {
    $full=[IO.Path]::GetFullPath($fixtureRoot);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '\Asql-lab-tls-root-[a-f0-9]{32}\z'){throw 'TLS_ROOT_FIXTURE_CLEANUP_BOUNDARY'}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
