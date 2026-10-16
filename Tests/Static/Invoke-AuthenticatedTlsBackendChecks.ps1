#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$passed=0; $failures=[Collections.Generic.List[string]]::new()
$source=Join-Path $repo 'Private/AuthenticatedTlsBackend.ps1'
. $source

# Metadatenabfragen duerfen weder Konstruktor noch Methoden ausfuehren.
class TlsBackendApiCanary {
    static [int]$Calls=0
    TlsBackendApiCanary([object]$Value) { [TlsBackendApiCanary]::Calls++; throw 'TLS_BACKEND_PRIVATE_CANARY constructor' }
    [string] Probe([object]$Value) { [TlsBackendApiCanary]::Calls++; throw 'TLS_BACKEND_PRIVATE_CANARY method' }
    static [bool] StaticProbe() { [TlsBackendApiCanary]::Calls++; throw 'TLS_BACKEND_PRIVATE_CANARY static' }
}
class TlsBackendApiChild : TlsBackendApiCanary {
    TlsBackendApiChild() : base($null) {}
}
& {
    Set-StrictMode -Version Latest
    Add-CheckResult 'TLS-B01 Konstruktor nur entdecken' (Test-LabTlsBackendApi -Owner ([TlsBackendApiCanary]) -Constructor -Parameters @([object]))
    Add-CheckResult 'TLS-B01 Instanzmethode nur entdecken' (Test-LabTlsBackendApi -Owner ([TlsBackendApiCanary]) -Name Probe -Parameters @([object]) -ReturnType ([string]) -Static $false)
    Add-CheckResult 'TLS-B01 statische Methode nur entdecken' (Test-LabTlsBackendApi -Owner ([TlsBackendApiCanary]) -Name StaticProbe -Parameters @() -ReturnType ([bool]) -Static $true)
    Add-CheckResult 'TLS-B01 keine Konstruktor-/Methodenaufrufe' ([TlsBackendApiCanary]::Calls -eq 0)
    Add-CheckResult 'TLS-B02 kein Binder-Basistypersatz im Konstruktor' (-not (Test-LabTlsBackendApi -Owner ([TlsBackendApiCanary]) -Constructor -Parameters @([string])))
    Add-CheckResult 'TLS-B02 kein Binder-Basistypersatz in Methode' (-not (Test-LabTlsBackendApi -Owner ([TlsBackendApiCanary]) -Name Probe -Parameters @([string]) -ReturnType ([string]) -Static $false))
    Add-CheckResult 'TLS-B02 falscher Rueckgabetyp' (-not (Test-LabTlsBackendApi -Owner ([TlsBackendApiCanary]) -Name Probe -Parameters @([object]) -ReturnType ([bool]) -Static $false))
    Add-CheckResult 'TLS-B02 keine Instanz-/Static-Verwechslung' (-not (Test-LabTlsBackendApi -Owner ([TlsBackendApiCanary]) -Name StaticProbe -Parameters @() -ReturnType ([bool]) -Static $false))
    Add-CheckResult 'TLS-B02 kein geerbter Ersatz' (-not (Test-LabTlsBackendApi -Owner ([TlsBackendApiChild]) -Name Probe -Parameters @([object]) -ReturnType ([string]) -Static $false))
    Add-CheckResult 'TLS-B02 keine offene generische Methode' (-not (Test-LabTlsBackendApi -Owner ([Linq.Enumerable]) -Name Empty -Parameters @() -ReturnType ([object]) -Static $true))
    Add-CheckResult 'TLS-B02 unbekannter Typ fail-closed' (-not (Test-LabTlsBackendApi -Owner $null -Constructor -Parameters @()))
    $result=Get-LabAuthenticatedTlsBackendMetadata -Context CURRENT_PROCESS
    $value=$result.Value
    Add-CheckResult 'TLS-B03 eine geschlossene Ergebnisform' ($result.Success -and $null -eq $result.ErrorCode -and @($result.PSObject.Properties).Count -eq 3 -and @($value.PSObject.Properties).Count -eq 14)
    Add-CheckResult 'TLS-B03 feste Metadatenaussage ohne Autoritaet' ($value.ContractVersion -ceq 'SqlServerLab.AuthenticatedTlsBackendMetadata/0.1' -and
        $value.Context -ceq 'CURRENT_PROCESS' -and $value.Backend -ceq 'DOTNET_X509' -and $value.Status -ceq 'METADATA_ONLY' -and
        $value.RegistrationStatus -ceq 'NOT_EVALUATED' -and $value.KeyProtectionStatus -ceq 'NOT_EXECUTED' -and
        $value.SigningStatus -ceq 'NOT_EXECUTED' -and $value.ClientStatus -ceq 'NOT_EVALUATED' -and
        $value.Ready -is [bool] -and -not $value.Ready -and $value.MutationAllowed -is [bool] -and -not $value.MutationAllowed)
    $expectedPlatform=if($IsWindows){'windows'}elseif($IsLinux){'linux'}else{'other'}
    Add-CheckResult 'TLS-B03 wirkliche Prozessplattform und CLR-Version' ($value.Platform -ceq $expectedPlatform -and $value.RuntimeVersion -ceq [Environment]::Version.ToString())
    $ids=@('REQUEST_RSA_CONSTRUCTOR','CSR_CREATE_DER','CSR_LOAD_DER','CERTIFICATE_CREATE','SAN_IP','SAN_DNS')
    Add-CheckResult 'TLS-B03 feste API-Liste' ($value.Apis.Count -eq 6 -and ($value.Apis.Id -join '|') -ceq ($ids -join '|'))
    foreach($api in $value.Apis) { Add-CheckResult "TLS-B03 native API-Flags $($api.Id)" ($api.Present -is [bool] -and @($api.PSObject.Properties).Count -eq 2) }
    # .NET 6 besitzt die aelteren PKI-APIs; der PKCS#10-Reader ist ab .NET 7 dokumentiert.
    $expectedLoad=[Environment]::Version.Major -ge 7
    foreach($api in $value.Apis) {
        $expected=if($api.Id -ceq 'CSR_LOAD_DER'){$expectedLoad}else{$true}
        Add-CheckResult "TLS-B04 unabhaengiges CLR-Soll $($api.Id)" ($api.Present -eq $expected)
    }
    Add-CheckResult 'TLS-B04 API-Vollstaendigkeit hebt Sperre nie auf' ($value.ApiStatus -ceq $(if($expectedLoad){'COMPLETE'}else{'INCOMPLETE'}) -and -not $value.Ready -and -not $value.MutationAllowed)
    $text=$result|ConvertTo-Json -Depth 8 -Compress
    Add-CheckResult 'TLS-B05 keine IDs, Locatoren, User-/Key-/Storewerte' ($text -notmatch 'ClientRef|AuthorityRef|SignerContextRef|UserName|IdentitySid|DataRoot|Thumbprint|PrivateKey|TLS_BACKEND_PRIVATE_CANARY')
    $result.Value.Apis[0].Present=$false
    Add-CheckResult 'TLS-B05 neue Projektion je Aufruf' (Get-LabAuthenticatedTlsBackendMetadata -Context CURRENT_PROCESS).Value.Apis[0].Present
    $streams=@(Get-LabAuthenticatedTlsBackendMetadata -Context CURRENT_PROCESS *>&1)
    Add-CheckResult 'TLS-B05 genau ein Ergebnis ohne Nebenstreams' ($streams.Count -eq 1 -and $streams[0].Success)
}
function Assert-BackendRejected { param($Context)
    $all=@(Get-LabAuthenticatedTlsBackendMetadata -Context $Context *>&1)
    Add-CheckResult 'TLS-B06 ungueltiger Kontext geschlossen' ($all.Count -eq 1 -and $all[0].Success -eq $false -and $null -eq $all[0].Value -and $all[0].ErrorCode -ceq 'TLS_BACKEND_CONTEXT_INVALID')
}
$script:foreignCalls=0
$alien=[pscustomobject]@{}; $alien|Add-Member ScriptProperty Context {$script:foreignCalls++;throw 'TLS_BACKEND_PRIVATE_CANARY getter'}
$alien|Add-Member ScriptMethod ToString {$script:foreignCalls++;throw 'TLS_BACKEND_PRIVATE_CANARY string'} -Force
foreach($bad in @($null,'','current_process','CURRENT_PROCESS ',"CURRENT_PROCESS`n",'CURRENT_USER','LOCAL_MACHINE',1,$true,@('CURRENT_PROCESS'),$alien)) { Assert-BackendRejected $bad }
$savedCulture=[Threading.Thread]::CurrentThread.CurrentCulture
try {
    foreach($culture in @('en-US','de-DE','tr-TR')) {
        [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($culture)
        foreach($c in @([char]0x200b,[char]0x00ad)) { Assert-BackendRejected ('CURRENT_PROCESS'+$c) }
    }
} finally { [Threading.Thread]::CurrentThread.CurrentCulture=$savedCulture }
Add-CheckResult 'TLS-B06 kein fremder Getter/Cast aufgerufen' ($script:foreignCalls -eq 0)
$original=${function:Test-LabTlsBackendApi};$script:metadataCalls=0
try {
    function Test-LabTlsBackendApi { $script:metadataCalls++; throw 'TLS_BACKEND_PRIVATE_CANARY metadata error' }
    Assert-BackendRejected 'CURRENT_USER'
    Add-CheckResult 'TLS-B07 keine API-Abfrage vor Kontextwahl' ($script:metadataCalls -eq 0)
    $all=@(Get-LabAuthenticatedTlsBackendMetadata -Context CURRENT_PROCESS *>&1)
    Add-CheckResult 'TLS-B07 Metadatenfehler ohne Rohdiagnose' ($all.Count -eq 1 -and -not $all[0].Success -and $null -eq $all[0].Value -and
        $all[0].ErrorCode -ceq 'TLS_BACKEND_METADATA_UNAVAILABLE' -and ($all|ConvertTo-Json -Compress) -notmatch 'TLS_BACKEND_PRIVATE_CANARY')
    function Test-LabTlsBackendApi { return $false }
    $incomplete=Get-LabAuthenticatedTlsBackendMetadata -Context CURRENT_PROCESS
    Add-CheckResult 'TLS-B07 unvollstaendige API bleibt Metadaten, keine Freigabe' ($incomplete.Success -and $incomplete.Value.ApiStatus -ceq 'INCOMPLETE' -and
        @($incomplete.Value.Apis|Where-Object Present).Count -eq 0 -and -not $incomplete.Value.Ready -and -not $incomplete.Value.MutationAllowed)
} finally { Set-Item function:Test-LabTlsBackendApi $original }
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
Add-CheckResult 'TLS-B08 beim Laden ausschliesslich Funktionsdefinitionen' ($errors.Count -eq 0 -and @($ast.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count -eq 0)
$calls=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object GetCommandName)
Add-CheckResult 'TLS-B08 kein nativer Prozess-/Datei-/SQL-/Storecommand' (@($calls|Where-Object {$_ -cnotin @('Test-LabTlsBackendApi','Where-Object')}).Count -eq 0)
$methods=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst]},$true)|ForEach-Object {$_.Member.Value})
Add-CheckResult 'TLS-B08 keine Konstruktor-/Krypto-/Key-/Storeausfuehrung' (@($methods|Where-Object {$_ -cnotin @('GetConstructor','GetMethod','GetParameters','Equals','GetType','IsOSPlatform','Format')}).Count -eq 0)
Write-Host "Authenticated TLS Backend: $passed PASS, $($failures.Count) FAIL"
if($failures.Count){throw 'AUTHENTICATED_TLS_BACKEND_CHECKS_FAILED'}
