#Requires -Version 7.5
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
. (Join-Path $PSScriptRoot '../Common/TestTemporaryDirectory.ps1')
$passed=0;$failures=[Collections.Generic.List[string]]::new()
function Check([string]$Label,[scriptblock]$Body){try{& $Body;Add-CheckResult $Label $true}catch{Add-CheckResult $Label $false ($_.Exception.Message+' at '+$_.InvocationInfo.ScriptLineNumber)}}
function Assert([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function Reject([scriptblock]$Body){$rejected=$false;try{& $Body|Out-Null}catch{$rejected=$true};Assert $rejected 'Expected closed rejection'}
function RejectCode([scriptblock]$Body,[string]$Expected){$actual=$null;try{& $Body|Out-Null}catch{$actual=$_.Exception.Message};Assert ($actual-ceq$Expected) ('Expected '+$Expected+'; actual '+$actual)}
$owned=New-TestTemporaryDirectory -ParentPath (Join-Path $repo '.artifacts/test-runs/linux-public')
$module=New-Module -ArgumentList $repo,$owned.Path -ScriptBlock {
    param($Repo,$FixtureRoot)
    $script:ModuleRoot=$Repo
    $script:FixtureRoot=$FixtureRoot
    $script:ProviderCalls=0
    foreach($p in @('AuthenticatedTlsRequest.ps1','AuthenticatedTlsRegistryIndex.ps1','AuthenticatedTlsCaCandidate.ps1','DiagnosticBundleReader.ps1',
        'AuthenticatedTlsLab.ps1','AuthenticatedTlsQualification.ps1','AuthenticatedTlsLinuxClient.ps1','AuthenticatedTlsLinuxExecution.ps1','AuthenticatedTlsLinuxObserver.ps1','AuthenticatedTlsLinuxQualification.ps1','AuthenticatedTlsLinuxBootstrap.ps1')){
        . (Join-Path $Repo ('Private/'+$p))
    }
    function Get-LabTlsLinuxClientBinding {param($Bound,$Budget)$script:Client}
    function Get-LabTlsOwnBinding {param($StateRoot,$RunId,$InstanceId)$script:Bound}
    function Get-LabOwnedHostRunPolicy {$script:ProviderCalls++;throw 'UNEXPECTED_PROVIDER'}
    function Remove-LabOwnedHostFailedContainer {$script:ProviderCalls++;throw 'UNEXPECTED_PROVIDER'}
    function Invoke-LabOwnedHostPinnedCommand {$script:ProviderCalls++;throw 'UNEXPECTED_PROVIDER'}
    function Get-LabTlsWindowsProcessFacts {@{UserSid='synthetic'}}
    function Read-LabTlsCaPrivateFile {
        param($Path,$Sid,$MaximumBytes)
        if(-not[IO.Path]::GetFullPath($Path).StartsWith(($script:FixtureRoot+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)){throw 'FIXTURE_SCOPE'}
        [IO.File]::ReadAllBytes($Path)
    }
    Export-ModuleMember -Function @()
}
function Fixture {
    & $module {
        $id='11111111-1111-1111-1111-111111111111';$child='22222222-2222-2222-2222-222222222222'
        $r=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.4';SqlProfileId='2025-CU9';ClientPlatform='linux';LinuxClientRef=$child
            Provider='docker';RunId=$id;InstanceId='primary';ScopeId=$id;ContainerId=('a'*64);ImageId=('sha256:'+('b'*64));StartedAt='2026-10-26T03:00:00Z';CertificateSha256=('c'*64);NotAfterUtc='2026-10-27T03:00:00.0000000+00:00'}
        $a=[pscustomobject]@{Authority=[pscustomobject]@{Ref=$id;Generation=1;TrustScopeRef=$id;CertificateSha256=('d'*64)}
            Client=[pscustomobject]@{Ref=$id;Generation=1};ActorDigest=('e'*64);RootDigest=('f'*64);RegistrySha256=('1'*64)}
        $script:Bound=[pscustomobject]@{Record=$r;Authority=$a}
        $binary=[pscustomobject]@{Sha256=('2'*64);Bytes=64000}
        $script:Client=[pscustomobject]@{Sha256=('3'*64);Record=[pscustomobject]@{ClientRef=$child;Generation=1
            Client=[pscustomobject]@{ContainerId=('4'*64);ImageId=('sha256:'+('5'*64));StartedAt='2026-10-26T03:01:00Z';NetNamespace='net:[4026533333]'}
            Trust=[pscustomobject]@{FileSha256=('6'*64)};Binaries=[pscustomobject]@{SqlClient=$binary;Sqlcmd=$binary;OdbcDriver=$binary}}}
        $script:Q=New-LabTlsLinuxQualificationDocument $script:Bound $script:Client '2026-10-26T03:02:00.0000000+00:00' '2026-10-26T03:17:00.0000000+00:00'
        $script:Entry=[pscustomobject]@{key='LINUX_SQL2025_CU9_TLS';status='READY';runtimeStatus='READY';platform='linux';provider='docker';sqlVersion='2025';patch='cu9';resolvedVersion='17.0.5005.3'
            runId=$id;instanceId='primary';host='localhost';port=1433;database='master';username='sa';password='synthetic-fixture';encrypt=$true;trustServerCertificate=$false;autoStart='off';connectionString='synthetic-fixture'}
    }
}
try{
    foreach($profile in @('2019-CU32','2022-CU27','2025-CU9')){
        Check ("Explicit Linux shape resolves only catalogue profile "+$profile) {
            $p=& $module {param($Profile)Get-LabTlsBindingSqlProfile ([pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.4';SqlProfileId=$Profile;ClientPlatform='linux';LinuxClientRef='22222222-2222-2222-2222-222222222222'})} $profile
            Assert ($p.Version-ceq$profile) 'Profile mismatch'
        }
    }
    foreach($mutation in @('wrong-platform','missing-ref','unknown-profile','array-platform','array-profile','array-contract')){
        Check ("Explicit Linux shape rejects "+$mutation) {
            Reject {& $module {param($Mutation)
                $r=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.4';SqlProfileId='2025-CU9';ClientPlatform='linux';LinuxClientRef='22222222-2222-2222-2222-222222222222'}
                switch($Mutation){
                    wrong-platform{$r.ClientPlatform='windows'};missing-ref{$r.LinuxClientRef=$null};unknown-profile{$r.SqlProfileId='2025-latest'}
                    array-platform{$r.ClientPlatform=@('linux')};array-profile{$r.SqlProfileId=@('2025-CU9')};array-contract{$r.ContractVersion=@($r.ContractVersion)}
                }
                Get-LabTlsBindingSqlProfile $r
            } $mutation}
        }
    }
    Check 'Fresh exact Linux qualification and entry compose with unchanged parent identity' {
        Fixture
        & $module {Assert-LabTlsLinuxExportQualification $script:Bound $null $script:Q $script:Entry
            if($script:Q.ParentControllerClientRef-ceq$script:Q.ClientRef){throw 'PARENT_COLLAPSED'}}
    }
    Fixture
    $fields=& $module {@($script:Q.PSObject.Properties|Where-Object {$_.Value-is[string]}|ForEach-Object {$_.Name})}
    foreach($field in $fields){
        Check ("Qualification scalar binding: "+$field) {
            Fixture
            Reject {& $module {param($Field)$script:Q.$Field=@($script:Q.$Field);Assert-LabTlsLinuxExportQualification $script:Bound $null $script:Q $script:Entry} $field}
        }
    }
    foreach($field in @('ClientRef','ClientContextDigest','ParentControllerClientRef','Store','TrustFileSha256','SqlClientSha256','LoadedOdbcSha256','StartedAt','ClientStartedAt')){
        Check ("Current child or parent drift: "+$field) {
            Fixture
            Reject {& $module {param($Field)$script:Q.$Field='changed';Assert-LabTlsLinuxExportQualification $script:Bound $null $script:Q $script:Entry} $field}
        }
    }
    foreach($field in @('host','port','encrypt','trustServerCertificate','provider','runId','instanceId','key')){
        Check ("Export endpoint and flags remain exact: "+$field) {
            Fixture
            Reject {& $module {param($Field)$script:Entry.$Field=@($script:Entry.$Field);Assert-LabTlsLinuxExportQualification $script:Bound $null $script:Q $script:Entry} $field}
        }
    }
    Check 'Extra qualification field and namespace changes reject' {
        Fixture
        Reject {& $module {$script:Q|Add-Member Unexpected $true;Assert-LabTlsLinuxExportQualification $script:Bound $null $script:Q $script:Entry}}
        Fixture
        Reject {& $module {$script:Q.Endpoint.Namespace='net:[4026539999]';Assert-LabTlsLinuxExportQualification $script:Bound $null $script:Q $script:Entry}}
    }
    Check 'Observed records compare names and typed values rather than JSON property order' {
        & $module {Assert-LabTlsLinuxObservedFields ([pscustomobject]@{A='text';B=[pscustomobject]@{X=1;Y=$true}}) ([pscustomobject]@{B=[pscustomobject]@{Y=$true;X=[long]1};A='text'})}
        Reject {& $module {Assert-LabTlsLinuxObservedFields ([pscustomobject]@{A=1}) ([pscustomobject]@{A='1'})}}
    }
    Check 'Fixed source closure holds all eight selected files and source hashes' {
        $tb=Join-Path $owned.Path 'toolbelt';$ci=Join-Path $tb 'Tests/CI';$null=[IO.Directory]::CreateDirectory($ci)
        foreach($name in @('LabLinuxQualifiedContract.ps1','Invoke-LabLinuxPreflight.ps1')){[IO.File]::WriteAllText((Join-Path $ci $name),'# synthetic source fixture')}
        $set=& $module {param($Root)Get-LabTlsLinuxConsumerSourceSet $Root} $tb
        try{
            Assert ($set.Count-eq8) 'Source count'
            foreach($e in $set){Assert ($e.Stream.CanRead-and$e.Bytes-gt0-and$e.Sha256-cmatch'\A[0-9a-f]{64}\z') 'Source not held'}
            if($IsWindows){Reject {[IO.File]::WriteAllText((Join-Path $ci 'LabLinuxQualifiedContract.ps1'),'changed')}}
        }finally{foreach($e in $set){$e.Stream.Dispose()}}
    }
    Check 'Fixed source closure rejects missing consumer dependency' {
        $empty=Join-Path $owned.Path 'empty';$null=[IO.Directory]::CreateDirectory($empty)
        Reject {& $module {param($Root)Get-LabTlsLinuxConsumerSourceSet $Root} $empty}
    }
    Check 'Ordinary Windows run without Linux state remains a cleanup no-op' {
        $root=Join-Path $owned.Path 'ordinary';$null=[IO.Directory]::CreateDirectory($root)
        & $module {param($Root)Remove-LabTlsLinuxClientIfPresent $Root '11111111-1111-1111-1111-111111111111'} $root
    }
    foreach($name in @('linux-client-context.json','linux-client-execution.json','tls-linux-process-recovery.json')){
        Check ("Missing intention blocks parent cleanup for "+$name) {
            $root=Join-Path $owned.Path $name.Replace('.json','');$null=[IO.Directory]::CreateDirectory($root)
            [IO.File]::WriteAllText((Join-Path $root $name),'{}')
            RejectCode {& $module {param($Root)Remove-LabTlsLinuxClientIfPresent $Root '11111111-1111-1111-1111-111111111111'} $root} 'TLS_LINUX_MISSING_INTENT_RECOVERY_REQUIRED'
            Assert ((& $module {$script:ProviderCalls})-eq0) 'Unexpected provider effect'
        }
    }
    Check 'Explicit 0.4 parent without child intention requires recovery before provider effects' {
        $root=Join-Path $owned.Path 'parent-only';$null=[IO.Directory]::CreateDirectory($root)
        $record=[ordered]@{}
        foreach($name in @('ContractVersion','AuditId','DataRoot','ControllerId','LocationId','AuthorityRef','ClientRef','RegistrySha256','RunId','InstanceId','ScopeId','ContainerId','ImageId','Port','CertificateSha256','CertificateDer','NotAfterUtc','StartedAt','ServerPath','Provider','RuntimeBinding','SqlProfileId','ClientPlatform','LinuxClientRef')){$record[$name]='synthetic'}
        $record.ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.4';$record.Provider='docker';$record.SqlProfileId='2025-CU9';$record.ClientPlatform='linux';$record.LinuxClientRef='22222222-2222-2222-2222-222222222222'
        [IO.File]::WriteAllText((Join-Path $root 'authenticated-tls-lab.json'),($record|ConvertTo-Json -Compress))
        RejectCode {& $module {param($Root)Remove-LabTlsLinuxClientIfPresent $Root '11111111-1111-1111-1111-111111111111'} $root} 'TLS_LINUX_MISSING_INTENT_RECOVERY_REQUIRED'
        Assert ((& $module {$script:ProviderCalls})-eq0) 'Unexpected provider effect'
    }
    Check 'Linux exported guidance selects isolated guest trust and the foreground consumer' {
        $text=& $module {Get-LabTlsLinuxExportUsageText}
        Assert ($text.Contains('Invoke-SqlServerLabLinuxPreflight')-and$text.Contains('Gastnamespace')-and$text.Contains('isoliertem CA-Truststore')-and-not$text.Contains('Windows CurrentUser/Root, SqlClient')) 'Wrong export reading path'
    }
    Check 'Default controller reader rejects a Linux namespace export before provider activity' {
        Fixture
        RejectCode {& $module {Read-LabTlsQualifiedExportSnapshot -ExportBytes ([Text.Encoding]::UTF8.GetBytes('synthetic')) -FromBytes -StateRoot 'synthetic' -RunId 'synthetic' -InstanceId primary}} 'TLS_LINUX_LIVE_SESSION_REQUIRED'
        Assert ((& $module {$script:ProviderCalls})-eq0) 'Unexpected provider effect'
    }
    foreach($mutation in @('none','missing','wrong-ref','wrong-root','wrong-run','wrong-instance','wrong-bytes','wrong-stack','not-in-verifier','not-in-flight','expired','wrong-process')){
        Check ("Private controller role binding: "+$mutation) {
            $root=$owned.Path
            $code=& $module {
                param($Root,$Mutation)
                $bytes=[Text.Encoding]::UTF8.GetBytes('synthetic')
                $live=@{Root=[IO.Path]::GetFullPath($Root);ProcessId=$PID;State='OPEN';InVerifier=$true;RunId='synthetic';InstanceId='primary';CurrentStack='SYSTEM_DATA_SQLCLIENT'
                    Session=@{State='OPEN';InFlight=$true;SessionRef=('a'*64);Lifetime=[Diagnostics.Stopwatch]::StartNew();MaximumElapsed=[TimeSpan]::FromMinutes(1);ExportSha256=(Get-LabTlsCaByteDigest $bytes)}}
                $script:SqlServerLabTlsLinuxLiveBridge=$live
                $ref='a'*64;$run='synthetic';$instance='primary';$stack='SYSTEM_DATA_SQLCLIENT'
                switch($Mutation){
                    missing{$script:SqlServerLabTlsLinuxLiveBridge=$null};wrong-ref{$ref='b'*64}
                    wrong-root{$live.Root=Join-Path $Root 'other'};wrong-run{$run='other'};wrong-instance{$instance='other'}
                    wrong-bytes{$bytes=[byte[]]@(1)};wrong-stack{$stack='ODBC_SQLCMD'};not-in-verifier{$live.InVerifier=$false}
                    not-in-flight{$live.Session.InFlight=$false};expired{$live.Session.MaximumElapsed=[TimeSpan]::Zero}
                    wrong-process{$live.ProcessId=-1}
                }
                try{Assert-LabTlsLinuxControllerSession $Root $run $instance $bytes $ref $stack;'ACCEPTED'}catch{$_.Exception.Message}
                finally{$script:SqlServerLabTlsLinuxLiveBridge=$null}
            } $root $mutation
            Assert ($code-ceq$(if($mutation-ceq'none'){'ACCEPTED'}else{'TLS_LINUX_CONTROLLER_SESSION_REQUIRED'})) 'Controller role decision mismatch'
        }
    }
    foreach($program in @('Get-LabTlsLinuxObservationProgram','Get-LabTlsLinuxQualificationProgram','Get-LabTlsLinuxPeerEntryProgram')){
        Check ("Fixed guest program parses without executing: "+$program) {
            $code=& $module {param($Name)& $Name} $program
            $errors=$null;$null=[Management.Automation.Language.Parser]::ParseInput($code,[ref]$null,[ref]$errors)
            Assert (@($errors).Count-eq0) 'Guest parse errors'
        }
    }
}finally{Remove-Module $module;Remove-TestTemporaryDirectory -OwnedDirectory $owned}
Write-Host ('Checks: '+$passed+' passed, '+$failures.Count+' failed; provider/SQL actions: 0')
if($failures.Count){exit 1}
