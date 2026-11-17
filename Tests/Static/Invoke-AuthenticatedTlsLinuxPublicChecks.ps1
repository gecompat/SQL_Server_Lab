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
    $script:ClientBindingCalls=0
    $script:ObservationStages=[Collections.Generic.List[string]]::new()
    $script:ContainerArguments=$null
    $script:ContainerOperationStage=$null
    foreach($p in @('AuthenticatedTlsRequest.ps1','AuthenticatedTlsRegistryIndex.ps1','AuthenticatedTlsCaCandidate.ps1','DiagnosticBundleReader.ps1',
        'AuthenticatedTlsLab.ps1','AuthenticatedTlsQualification.ps1','AuthenticatedTlsLinuxClient.ps1','AuthenticatedTlsLinuxExecution.ps1','AuthenticatedTlsLinuxObserver.ps1','AuthenticatedTlsLinuxQualification.ps1','AuthenticatedTlsLinuxBootstrap.ps1')){
        . (Join-Path $Repo ('Private/'+$p))
    }
    $script:ActualAssertLabTlsSqlCertificateBinding=(Get-Command Assert-LabTlsSqlCertificateBinding -CommandType Function).ScriptBlock
    function Get-LabTlsLinuxClientBinding {param($Bound,$Budget)$script:ClientBindingCalls++;$script:Client}
    function Assert-LabTlsSqlCertificateBinding {
        param($Record,$StateRoot,$Budget,[switch]$IncludeNetworkNamespace)
        $script:ObservationStages.Add('parent-certificate')
        if($IncludeNetworkNamespace){return [pscustomobject]@{Context=$script:ObservationInspect;NetworkNamespace=$script:ObservationFacts.NetNamespace}}
        return $script:ObservationInspect
    }
    function Get-LabOwnedHostContainerObservation {param($StateRoot,$Intent,$ContainerId)$script:ObservationStages.Add('client-inspect');$script:ObservationInspect}
    function Assert-LabOwnedHostContainerEffect {param($StateRoot,$RunId,$Provider,$ContainerId)$script:ObservationStages.Add('client-effect')}
    function Get-LabTlsLinuxObservationProgram {'synthetic-read-only-observer'}
    function Invoke-LabTlsLinuxObservedProgram {param($Bound,$Budget,$ContainerId,$Program,$InputText)$script:ObservationStages.Add('guest-observation');$script:ObservationFacts|ConvertTo-Json -Compress -Depth 8}
    function Invoke-LabTlsContainer {
        param([string[]]$Arguments,$InputText,$Budget,$OperationStage)
        $script:ObservationStages.Add('sql-namespace')
        if($Arguments.Count-ge10-and$Arguments[0]-ceq'exec'-and$Arguments[2]-ceq'/bin/sh'){
            $script:ContainerArguments=@($Arguments)
            $script:ContainerOperationStage=$OperationStage
            if($Arguments[9]-ceq'1'){return "CERTIFICATE`n__TLS_LAB_CERTIFICATE_END__`n600:10001`n__TLS_LAB_KEY_MODE_END__`n[network]`n__TLS_LAB_CONFIGURATION_END__`nnet:[4026533333]`n__TLS_LAB_NETWORK_NAMESPACE_END__"}
            return "CERTIFICATE`n__TLS_LAB_CERTIFICATE_END__`n600:10001`n__TLS_LAB_KEY_MODE_END__`n[network]`n__TLS_LAB_CONFIGURATION_END__"
        }
        $script:ContainerOperationStage=$OperationStage
        return $script:ObservationFacts.NetNamespace
    }
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
        $script:ClientBindingCalls=0
        $script:ObservationStages.Clear()
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
        $client=& $module {Assert-LabTlsLinuxExportQualification $script:Bound $null $script:Q $script:Entry
            if($script:Q.ParentControllerClientRef-ceq$script:Q.ClientRef){throw 'PARENT_COLLAPSED'}}
        Assert ($client.Sha256-ceq('3'*64)-and(& $module {$script:ClientBindingCalls})-eq1) 'Fresh Linux binding was not returned exactly once'
    }
    Check 'Linux parent certificate observation follows fresh child trust and namespace checks' {
        $stages=& $module {
            $script:ObservationStages.Clear()
            $parent='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            $script:ObservationFacts=[pscustomobject]@{NetNamespace='net:[4026533333]';Trust=[pscustomobject]@{CertificateSha256=('d'*64)};Binaries=[pscustomobject]@{}}
            $script:ObservationInspect=[pscustomobject]@{Id='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
                State=[pscustomobject]@{Running=$true};Config=[pscustomobject]@{User='10001:0'}
                HostConfig=[pscustomobject]@{ReadonlyRootfs=$true;Privileged=$false;NetworkMode=('container:'+$parent);Binds=$null;PortBindings=$null;SecurityOpt=@('no-new-privileges')}}
            $record=[pscustomobject]@{RunId='11111111-1111-1111-1111-111111111111';InstanceId='primary';Provider='docker';ContainerId=$parent;CertificateSha256=('c'*64)}
            $bound=[pscustomobject]@{Record=$record;StateRoot=$script:FixtureRoot;Authority=[pscustomobject]@{Authority=[pscustomobject]@{CertificateSha256=('d'*64)}}}
            $intent=[pscustomobject]@{IntentId='22222222-2222-2222-2222-222222222222'}
            $null=Get-LabTlsLinuxClientObservation $bound $null $intent $script:ObservationInspect.Id
            $script:ObservationStages -join ','
        }
        Assert ($stages-ceq'client-inspect,client-effect,guest-observation,parent-certificate') ('Unexpected observation order: '+$stages)
    }
    Check 'Batched Linux SQL observation parser binds all read-only fields and namespace' {
        $parsed=& $module {
            $text="CERTIFICATE`n__TLS_LAB_CERTIFICATE_END__`n600:10001`n__TLS_LAB_KEY_MODE_END__`n[network]`ntlscert = /var/opt/mssql/tls-11111111111111111111111111111111/server.pem`ntlskey = /var/opt/mssql/tls-11111111111111111111111111111111/server.key`nforceencryption = 1`n__TLS_LAB_CONFIGURATION_END__`nnet:[4026533333]`n__TLS_LAB_NETWORK_NAMESPACE_END__`n"
            ConvertFrom-LabTlsSqlCertificateObservation $text -IncludeNetworkNamespace
        }
        Assert ($parsed.CertificatePem-ceq'CERTIFICATE'-and$parsed.KeyMode-ceq'600:10001'-and$parsed.Configuration.Contains('forceencryption = 1')-and$parsed.NetworkNamespace-ceq'net:[4026533333]') 'Batched observation fields did not round-trip'
        $trimmed=& $module {
            $text="CERTIFICATE`n__TLS_LAB_CERTIFICATE_END__`n600:10001`n__TLS_LAB_KEY_MODE_END__`n[network]`ntlscert = /var/opt/mssql/tls-11111111111111111111111111111111/server.pem`ntlskey = /var/opt/mssql/tls-11111111111111111111111111111111/server.key`nforceencryption = 1`n__TLS_LAB_CONFIGURATION_END__`nnet:[4026533333]`n__TLS_LAB_NETWORK_NAMESPACE_END__`n"
            ConvertFrom-LabTlsSqlCertificateObservation $text.TrimEnd("`r","`n") -IncludeNetworkNamespace
        }
        Assert ($trimmed.NetworkNamespace-ceq'net:[4026533333]') 'Trailing newline normalization broke the final framed field'
        & $module {
            $text="CERTIFICATE`n__TLS_LAB_CERTIFICATE_END__`n600:10001`n__TLS_LAB_KEY_MODE_END__`n[network]`n__TLS_LAB_CONFIGURATION_END__`n"
            $withoutNamespace=ConvertFrom-LabTlsSqlCertificateObservation $text
            if($withoutNamespace.PSObject.Properties['NetworkNamespace']){throw 'UNEXPECTED_NETWORK_NAMESPACE'}
        }
        RejectCode {& $module {ConvertFrom-LabTlsSqlCertificateObservation "CERTIFICATE`n__TLS_LAB_CERTIFICATE_END__`n777:10001`n__TLS_LAB_KEY_MODE_END__`nconfig`n__TLS_LAB_CONFIGURATION_END__`n" -IncludeNetworkNamespace}} 'TLS_LAB_SQL_OBSERVATION_INVALID'
        RejectCode {& $module {ConvertFrom-LabTlsSqlCertificateObservation "CERTIFICATE`n__TLS_LAB_CERTIFICATE_END__`n600:10001`n__TLS_LAB_KEY_MODE_END__`nconfig`n__TLS_LAB_CONFIGURATION_END__`nnot-a-namespace`n__TLS_LAB_NETWORK_NAMESPACE_END__`n" -IncludeNetworkNamespace}} 'TLS_LAB_SQL_OBSERVATION_INVALID'
        RejectCode {& $module {ConvertFrom-LabTlsSqlCertificateObservation "CERTIFICATE`n__TLS_LAB_KEY_MODE_END__`n600:10001`n__TLS_LAB_CERTIFICATE_END__`nconfig`n__TLS_LAB_CONFIGURATION_END__`nnet:[4026533333]`n__TLS_LAB_NETWORK_NAMESPACE_END__" -IncludeNetworkNamespace}} 'TLS_LAB_SQL_OBSERVATION_INVALID'
        RejectCode {& $module {ConvertFrom-LabTlsSqlCertificateObservation "CERTIFICATE`n__TLS_LAB_CERTIFICATE_END__`n600:10001`n__TLS_LAB_KEY_MODE_END__`nconfig`n__TLS_LAB_CONFIGURATION_END__unexpected"}} 'TLS_LAB_SQL_OBSERVATION_INVALID'
        RejectCode {& $module {ConvertFrom-LabTlsSqlCertificateObservation "CERTIFICATE`n__TLS_LAB_CERTIFICATE_END__`n600:10001`n__TLS_LAB_KEY_MODE_END__`nconfig`n__TLS_LAB_CONFIGURATION_END__`nconfig`n__TLS_LAB_CONFIGURATION_END__"}} 'TLS_LAB_SQL_OBSERVATION_INVALID'
        RejectCode {& $module {ConvertFrom-LabTlsSqlCertificateObservation "CERTIFICATE`n__TLS_LAB_KEY_MODE_END__`nforged`n__TLS_LAB_CERTIFICATE_END__`n600:10001`n__TLS_LAB_KEY_MODE_END__`nconfig`n__TLS_LAB_CONFIGURATION_END__"}} 'TLS_LAB_SQL_OBSERVATION_INVALID'
        RejectCode {& $module {ConvertFrom-LabTlsSqlCertificateObservation '' -IncludeNetworkNamespace}} 'TLS_LAB_SQL_OBSERVATION_INVALID'
    }
    Check 'Batched SQL observation passes LF-only fixed shell and validated path arguments' {
        $captured=& $module {
            $script:ContainerArguments=$null
            $linux=Get-LabTlsSqlCertificateObservation -ContainerId ('a'*64) -ServerPath ('/var/opt/mssql/tls-'+('b'*32)) -Budget ([pscustomobject]@{Provider='docker';Commands=0;DeadlineUtc=[datetime]::UtcNow.AddMinutes(1)}) -IncludeNetworkNamespace -OperationStage 'linux-client-observation'
            $linuxArgs=@($script:ContainerArguments);$linuxStage=$script:ContainerOperationStage
            $ordinary=Get-LabTlsSqlCertificateObservation -ContainerId ('a'*64) -ServerPath ('/var/opt/mssql/tls-'+('b'*32)) -Budget ([pscustomobject]@{Provider='docker';Commands=0;DeadlineUtc=[datetime]::UtcNow.AddMinutes(1)})
            [pscustomobject]@{LinuxArgs=$linuxArgs;LinuxStage=$linuxStage;OrdinaryStage=$script:ContainerOperationStage;LinuxNamespace=$linux.NetworkNamespace;Ordinary=$ordinary}
        }
        $arguments=@($captured.LinuxArgs)
        Assert ($arguments.Count-eq10) 'Unexpected shell argument count'
        Assert ($arguments[0]-ceq'exec'-and$arguments[2]-ceq'/bin/sh'-and$arguments[3]-ceq'-c'-and$arguments[5]-ceq'tls-sql-observation') 'Shell executable or fixed argv binding changed'
        Assert (-not$arguments[4].Contains("`r")-and$arguments[4].StartsWith("set -eu`n",[StringComparison]::Ordinal)) 'Shell script was not normalized to LF'
        Assert ($arguments[6]-ceq('/var/opt/mssql/tls-'+('b'*32)+'/server.pem')-and$arguments[7]-ceq('/var/opt/mssql/tls-'+('b'*32)+'/server.key')-and$arguments[8]-ceq'/var/opt/mssql/mssql.conf'-and$arguments[9]-ceq'1') 'Validated file paths or namespace flag changed'
        Assert ($captured.LinuxStage-ceq'linux-client-observation'-and$captured.OrdinaryStage-ceq'unspecified'-and$captured.LinuxNamespace-ceq'net:[4026533333]') 'Runtime operation stage classification changed'
    }
    Check 'Legacy TLS record without ClientPlatform retains unspecified observation stage' {
        & $module {
            $ownBinding=(Get-Command Assert-LabTlsOwnContainer -CommandType Function).ScriptBlock
            $observation=(Get-Command Get-LabTlsSqlCertificateObservation -CommandType Function).ScriptBlock
            $script:ObservedBindingStage=$null
            Set-Item Function:Assert-LabTlsOwnContainer -Value {param($Record,$StateRoot,$Budget)[pscustomobject]@{ContainerId=('a'*64);Inspect=[pscustomobject]@{State=[pscustomobject]@{StartedAt='2026-11-16T00:00:00Z'}}}}
            Set-Item Function:Get-LabTlsSqlCertificateObservation -Value {param($ContainerId,$ServerPath,$Budget,$IncludeNetworkNamespace,$OperationStage)$script:ObservedBindingStage=$OperationStage;[pscustomobject]@{CertificatePem='invalid'}}
            $record=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.3';StartedAt='2026-11-16T00:00:00Z';ServerPath='/var/opt/mssql/tls-11111111111111111111111111111111'}
            try{$null=& $script:ActualAssertLabTlsSqlCertificateBinding $record 'synthetic-state' $null}catch{}
            $stage=$script:ObservedBindingStage
            Set-Item Function:Assert-LabTlsOwnContainer -Value $ownBinding
            Set-Item Function:Get-LabTlsSqlCertificateObservation -Value $observation
            if($stage-cne'unspecified'){throw 'LEGACY_TLS_OBSERVATION_STAGE_CHANGED'}
        }
    }
    Check 'Linux observation batches namespace into the final certificate binding' {
        $source=[IO.File]::ReadAllText((Join-Path $repo 'Private/AuthenticatedTlsLinuxClient.ps1'))
        $start=$source.IndexOf('function Get-LabTlsLinuxClientObservation',[StringComparison]::Ordinal)
        $end=$source.IndexOf('function Initialize-LabTlsLinuxClient',[StringComparison]::Ordinal)
        Assert ($start-ge0-and$end-gt$start) 'Linux observation source boundary missing'
        $body=$source.Substring($start,$end-$start)
        Assert ($body.Contains('Assert-LabTlsSqlCertificateBinding $r $root $Budget -IncludeNetworkNamespace')-and-not$body.Contains("/usr/bin/readlink")) 'Namespace was not supplied by the batched parent observation'
    }
    Check 'Linux public read verifies signed bytes before one final fresh provider observation' {
        $source=[IO.File]::ReadAllText((Join-Path $repo 'Private/AuthenticatedTlsQualification.ps1'))
        $start=$source.IndexOf('function Read-LabTlsQualifiedExportSnapshot',[StringComparison]::Ordinal)
        $end=$source.IndexOf('function Test-LabTlsQualifiedExport',[StringComparison]::Ordinal)
        Assert ($start-ge0-and$end-gt$start) 'Qualified snapshot reader source boundary missing'
        $reader=$source.Substring($start,$end-$start)
        $signature=$reader.IndexOf('VerifyData($signed',[StringComparison]::Ordinal)
        $linuxBinding=$reader.IndexOf('$linuxClient=Assert-LabTlsLinuxExportQualification',[StringComparison]::Ordinal)
        $certificateCalls=[regex]::Matches($reader,'Assert-LabTlsSqlCertificateBinding')
        $certificateCall=$reader.IndexOf('$null=Assert-LabTlsSqlCertificateBinding',[StringComparison]::Ordinal)
        $linuxElse=$reader.LastIndexOf('}else{',$certificateCall,[StringComparison]::Ordinal)
        Assert ($signature-ge0-and$linuxBinding-gt$signature-and$certificateCalls.Count-eq1-and$certificateCall-gt$linuxBinding-and$linuxElse-gt$linuxBinding-and$certificateCall-gt$linuxElse) 'Linux read repeated or ran provider checks before signed static validation'
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
            if($program-ceq'Get-LabTlsLinuxPeerEntryProgram'){
                Assert ($code.Contains('$failureFrame=& $module {param($ErrorRecord)New-LabTlsLinuxBridgeFailureFrame $ErrorRecord} $_')) 'Peer entry must create its failure frame in the loaded module scope'
                $frame=& $module {
                    try{throw [InvalidOperationException]::new('certificate authority is not trusted; synthetic-private-detail')}catch{New-LabTlsLinuxBridgeFailureFrame $_}
                }
                Assert ($frame.Code-ceq'TLS_CERTIFICATE'-and$frame.Frame.StartsWith('FAILURE ',[StringComparison]::Ordinal)-and$frame.Frame -notmatch 'synthetic-private-detail') 'Peer entry failure frame must contain only its safe class'
                $bytes=[Convert]::FromBase64String($frame.Frame.Substring(8))
                $parsed=& $module {param($EnvelopeBytes)Get-LabTlsLinuxBridgeFailureCode $EnvelopeBytes} $bytes
                Assert ($parsed-ceq'TLS_CERTIFICATE') 'Peer entry failure frame must satisfy the strict controller parser'
                $typedTimeout=& $module {
                    try{throw [InvalidOperationException]::new('operation timed out; synthetic-private-detail',[TimeoutException]::new('synthetic-private-detail'))}catch{New-LabTlsLinuxBridgeFailureFrame $_}
                }
                $typedTimeoutBytes=[Convert]::FromBase64String($typedTimeout.Frame.Substring(8))
                $typedTimeoutParsed=& $module {param($EnvelopeBytes)Get-LabTlsLinuxBridgeFailureCode $EnvelopeBytes} $typedTimeoutBytes
                Assert ($typedTimeout.Code-ceq'RUNTIME_TIMEOUT_TIMEOUT_EXCEPTION'-and$typedTimeoutParsed-ceq$typedTimeout.Code-and$typedTimeout.Frame -notmatch 'synthetic-private-detail') 'Timeout exception kind must survive the private peer frame without raw details'
                $phaseCodes=& $module {
                    $codes=[Collections.Generic.List[string]]::new()
                    foreach($stage in @('CONSTRUCT','OPEN','QUERY','CLEANUP')){$categories=@('PLATFORM_UNSUPPORTED','ASSEMBLY_UNAVAILABLE','AUTHENTICATION','TIMEOUT','NETWORK','SQL','UNCLASSIFIED');if($stage-ceq'CONSTRUCT'){$categories+= 'INVALID_ARGUMENT'};foreach($category in $categories){
                        $code='TLS_SQLCLIENT_'+$stage+'_'+$category
                        $failure=[InvalidOperationException]::new($code+' synthetic-private-detail')
                        $frame=New-LabTlsLinuxBridgeFailureFrame ([Management.Automation.ErrorRecord]::new($failure,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
                        if($frame.Code-cne$code){throw 'SYNTHETIC_PHASE_FRAME_CODE_INVALID'}
                        $bytes=[Convert]::FromBase64String($frame.Frame.Substring(8))
                        if((Get-LabTlsLinuxBridgeFailureCode $bytes)-cne$code){throw 'SYNTHETIC_PHASE_FRAME_PARSE_INVALID'}
                        if($frame.Frame -match 'synthetic-private-detail'){throw 'SYNTHETIC_PHASE_FRAME_LEAKED_DETAIL'}
                        $codes.Add($code)
                    }}
                    return ,$codes.ToArray()
                }
                Assert (@($phaseCodes).Count-eq29-and@($phaseCodes|Sort-Object -Unique).Count-eq29) 'SqlClient phase and category codes must round-trip through the strict peer failure envelope'
                $socketTimeout=& $module {
                    try{throw [InvalidOperationException]::new('network operation timed out; synthetic-private-detail',[Net.Sockets.SocketException]::new([Net.Sockets.SocketError]::TimedOut))}catch{New-LabTlsLinuxBridgeFailureFrame $_}
                }
                $socketTimeoutBytes=[Convert]::FromBase64String($socketTimeout.Frame.Substring(8))
                $socketTimeoutParsed=& $module {param($EnvelopeBytes)Get-LabTlsLinuxBridgeFailureCode $EnvelopeBytes} $socketTimeoutBytes
                Assert ($socketTimeout.Code-ceq'RUNTIME_TIMEOUT_SOCKET_TIMEOUT'-and$socketTimeoutParsed-ceq$socketTimeout.Code-and$socketTimeout.Frame -notmatch 'synthetic-private-detail') 'Socket timeout kind must survive the private peer frame without raw details'
                $taskCancellation=& $module {
                    try{throw [InvalidOperationException]::new('operation timeout; synthetic-private-detail',[Threading.Tasks.TaskCanceledException]::new('synthetic-private-detail'))}catch{New-LabTlsLinuxBridgeFailureFrame $_}
                }
                $taskCancellationBytes=[Convert]::FromBase64String($taskCancellation.Frame.Substring(8))
                $taskCancellationParsed=& $module {param($EnvelopeBytes)Get-LabTlsLinuxBridgeFailureCode $EnvelopeBytes} $taskCancellationBytes
                Assert ($taskCancellation.Code-ceq'RUNTIME_TIMEOUT_OPERATION_CANCELED'-and$taskCancellationParsed-ceq$taskCancellation.Code-and$taskCancellation.Frame -notmatch 'synthetic-private-detail') 'Task cancellation subtype must map to its base safe category without raw details'
                $powershellTimeout=& $module {
                    try{throw 'operation timed out; synthetic-private-detail'}catch{New-LabTlsLinuxBridgeFailureFrame $_}
                }
                $powershellTimeoutBytes=[Convert]::FromBase64String($powershellTimeout.Frame.Substring(8))
                $powershellTimeoutParsed=& $module {param($EnvelopeBytes)Get-LabTlsLinuxBridgeFailureCode $EnvelopeBytes} $powershellTimeoutBytes
                Assert ($powershellTimeout.Code-ceq'RUNTIME_TIMEOUT_POWERSHELL_RUNTIME_EXCEPTION'-and$powershellTimeoutParsed-ceq$powershellTimeout.Code-and$powershellTimeout.Frame -notmatch 'synthetic-private-detail') 'PowerShell runtime timeout wrapper must preserve a safe fixed type code without raw details'
                $otherTypedTimeout=& $module {
                    try{throw [InvalidOperationException]::new('operation timeout; synthetic-private-detail')}catch{New-LabTlsLinuxBridgeFailureFrame $_}
                }
                $otherTypedTimeoutBytes=[Convert]::FromBase64String($otherTypedTimeout.Frame.Substring(8))
                $otherTypedTimeoutParsed=& $module {param($EnvelopeBytes)Get-LabTlsLinuxBridgeFailureCode $EnvelopeBytes} $otherTypedTimeoutBytes
                Assert ($otherTypedTimeout.Code-ceq'RUNTIME_TIMEOUT_INVALID_OPERATION_EXCEPTION'-and$otherTypedTimeoutParsed-ceq$otherTypedTimeout.Code-and$otherTypedTimeout.Frame -notmatch 'synthetic-private-detail') 'Other typed timeout failure must preserve its safe exception category without raw details'
            }
        }
    }
    Check 'Public Linux boundary preserves only fixed safe codes and canonical runtime summaries' {
        $values=& $module {
            $runtime=[InvalidOperationException]::new('TLS_LAB_RUNTIME_COMMAND_FAILED|exitCode=1|stderrClass=TLS_CA_PEM_PARSE_FAILED|stderrBytes=32|stdoutChars=0|operationStage=linux-client-observation')
            $wrapped=[InvalidOperationException]::new('wrapper password=synthetic-secret',$runtime)
            $safe=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($wrapped,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $sqlClient=[InvalidOperationException]::new('TLS_LAB_RUNTIME_COMMAND_FAILED|exitCode=1|stderrClass=TLS_SQLCLIENT_OPEN_AUTHENTICATION|stderrBytes=32|stdoutChars=0|operationStage=linux-client-qualification')
            $sqlClientSafe=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($sqlClient,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $raw=[InvalidOperationException]::new('path=C:\private\ca.pem password=synthetic-secret')
            $redacted=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($raw,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $malformed=[InvalidOperationException]::new('TLS_LAB_RUNTIME_COMMAND_FAILED|exitCode=1|stderrClass=TLS_CA_PEM_PARSE_FAILED|stderrBytes=32|stdoutChars=0|operationStage=linux-client-observation host=private')
            $rejected=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($malformed,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $prefixedSecret=[InvalidOperationException]::new('TLS_LINUX_CA_PEM_PARSE_FAILED_PASSWORD_SECRET')
            $tokenRejected=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($prefixedSecret,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $longToken=[InvalidOperationException]::new(('TLS_LINUX_CA_PEM_PARSE_FAILED_'+('X'*2048)))
            $longTokenRejected=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($longToken,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $unknownSqlClient=[InvalidOperationException]::new('TLS_SQLCLIENT_OPEN_SYNTHETIC_SECRET')
            $sqlClientRejected=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($unknownSqlClient,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $classSecret=[InvalidOperationException]::new('TLS_LAB_RUNTIME_COMMAND_FAILED|exitCode=1|stderrClass=PASSWORD_SECRET|stderrBytes=32|stdoutChars=0|operationStage=linux-client-observation')
            $classRejected=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($classSecret,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $bridgeProtocol=[InvalidOperationException]::new('TLS_LINUX_BRIDGE_PROTOCOL')
            $bridgeProtocolSafe=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($bridgeProtocol,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $bridgeExit=[InvalidOperationException]::new('TLS_LINUX_CHILD_EXIT_NONZERO|exitCode=7|hello=1|verifierRequests=2|resultSeen=1|lastVerifiedStack=ODBC_SQLCMD|nextExpectedFrame=none|stderrClass=TLS_CA_PEM_PARSE_FAILED|stderrBytes=19')
            $bridgeExitSafe=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($bridgeExit,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $bridgeExitSecret=[InvalidOperationException]::new('TLS_LINUX_CHILD_EXIT_NONZERO|exitCode=7|hello=1|verifierRequests=2|resultSeen=1|stderrClass=TLS_CA_PEM_PARSE_FAILED|stderrBytes=19 password=synthetic-secret')
            $bridgeExitSecretRejected=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($bridgeExitSecret,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $bridgeExitRange=[InvalidOperationException]::new('TLS_LINUX_CHILD_EXIT_NONZERO|exitCode=7|hello=1|verifierRequests=17|resultSeen=1|stderrClass=TLS_CA_PEM_PARSE_FAILED|stderrBytes=19')
            $bridgeExitRangeRejected=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($bridgeExitRange,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $bridgeExitUnicode=[InvalidOperationException]::new('TLS_LINUX_CHILD_EXIT_NONZERO|exitCode=٧|hello=1|verifierRequests=2|resultSeen=1|stderrClass=TLS_CA_PEM_PARSE_FAILED|stderrBytes=19')
            $bridgeExitUnicodeRejected=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($bridgeExitUnicode,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $bridgeExitProgress=[InvalidOperationException]::new('TLS_LINUX_CHILD_EXIT_NONZERO|exitCode=1|hello=1|verifierRequests=1|resultSeen=0|lastVerifiedStack=SYSTEM_DATA_SQLCLIENT|nextExpectedFrame=VERIFY_ODBC_SQLCMD|stderrClass=RUNTIME_TIMEOUT|stderrBytes=0')
            $bridgeExitProgressSafe=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($bridgeExitProgress,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $bridgeExitProgressInvalid=[InvalidOperationException]::new('TLS_LINUX_CHILD_EXIT_NONZERO|exitCode=1|hello=1|verifierRequests=1|resultSeen=0|lastVerifiedStack=SYSTEM_DATA_SQLCLIENT|nextExpectedFrame=RESULT|stderrClass=RUNTIME_TIMEOUT|stderrBytes=0')
            $bridgeExitProgressInvalidSafe=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($bridgeExitProgressInvalid,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
                $constructArgument=[InvalidOperationException]::new('TLS_SQLCLIENT_CONSTRUCT_INVALID_ARGUMENT')
                $constructArgumentSafe=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($constructArgument,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $constructPhaseCode='TLS_SQLCLIENT_CONSTRUCT_PLATFORM_UNSUPPORTED_AT_INITIAL_CATALOG'
            $constructPhaseExit=[InvalidOperationException]::new('TLS_LINUX_CHILD_EXIT_NONZERO|exitCode=1|hello=1|verifierRequests=1|resultSeen=0|lastVerifiedStack=SYSTEM_DATA_SQLCLIENT|nextExpectedFrame=VERIFY_ODBC_SQLCMD|stderrClass='+$constructPhaseCode+'|stderrBytes=0')
            $constructPhaseSafe=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($constructPhaseExit,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
                $invalidArgumentOtherStages=foreach($stage in @('OPEN','QUERY','CLEANUP')){
                    $invalidStage=[InvalidOperationException]::new(('TLS_SQLCLIENT_'+$stage+'_INVALID_ARGUMENT'))
                    Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($invalidStage,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
                }
            $bridgeWithSecret=[InvalidOperationException]::new('TLS_LINUX_BRIDGE_PROTOCOL password=synthetic-secret')
            $bridgeSecretRejected=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($bridgeWithSecret,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $hostAcl=[InvalidOperationException]::new('TLS_CA_ACL_INVALID')
            $hostAclSafe=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($hostAcl,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $bootstrap=[InvalidOperationException]::new('TLS_LINUX_BOOTSTRAP_LIMIT')
            $bootstrapSafe=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($bootstrap,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $session=[InvalidOperationException]::new('TLS_LINUX_SESSION_REJECTED')
            $sessionSafe=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($session,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $qualification=[InvalidOperationException]::new('TLS_QUALIFICATION_SQLCMD_TIMEOUT')
            $qualificationSafe=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($qualification,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            $fixedLinuxCodes=@(
                'TLS_LINUX_CLIENT_BINDING_INVALID','TLS_LINUX_CONTEXT_RECORD_INVALID',
                'TLS_LINUX_EXPORT_BINDING_INVALID','TLS_LINUX_EXPORT_DOCUMENT_INVALID','TLS_LINUX_EXPORT_PAYLOAD_INVALID',
                'TLS_LINUX_VERIFIER_REPLY_REJECTED','TLS_LINUX_PEER_REJECTED',
                'TLS_LINUX_PINNED_PACKAGE_INVALID','TLS_LINUX_PINNED_PACKAGE_REQUIRED',
                'TLS_LINUX_PROCESS_RECOVERY_REQUIRED','TLS_LINUX_QUALIFICATION_BINDING_CHANGED',
                'TLS_LINUX_TERMINATION_UNCONFIRMED','TLS_LINUX_TRANSFER_COMMAND_FAILED',
                'TLS_LINUX_TRANSFER_INPUT_INVALID','TLS_LINUX_TRANSFER_OUTPUT_LIMIT',
                'TLS_LINUX_TRANSFER_SOURCE_CHANGED','TLS_LINUX_TRANSFER_TIMEOUT',
                'TLS_LINUX_CHILD_EXIT_NONZERO','TLS_LINUX_BRIDGE_PROTOCOL_BYTES_PENDING',
                'TLS_LINUX_RESULT_MISSING','TLS_LINUX_CHILD_STDERR_NONEMPTY'
            )
            $fixedLinuxResults=foreach($token in $fixedLinuxCodes){
                $failure=[InvalidOperationException]::new($token)
                Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($failure,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            }
            $hostWithSecret=[InvalidOperationException]::new('TLS_CA_ACL_INVALID password=synthetic-secret')
            $hostSecretRejected=Get-LabTlsSafePublicLinuxFailureCode ([Management.Automation.ErrorRecord]::new($hostWithSecret,'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null))
            @($safe,$sqlClientSafe,$redacted,$rejected,$tokenRejected,$longTokenRejected,$sqlClientRejected,$classRejected,
                $bridgeProtocolSafe,$bridgeSecretRejected,$hostAclSafe,$bootstrapSafe,$sessionSafe,$qualificationSafe,$hostSecretRejected,
                $bridgeExitSafe,$bridgeExitSecretRejected,$bridgeExitRangeRejected,$bridgeExitUnicodeRejected,
                ($fixedLinuxCodes-join','),($fixedLinuxResults-join','),$bridgeExitProgressSafe,$bridgeExitProgressInvalidSafe,$constructArgumentSafe,($invalidArgumentOtherStages-join','),$constructPhaseSafe)
        }
        Assert ($values[0]-ceq'TLS_LAB_RUNTIME_COMMAND_FAILED|exitCode=1|stderrClass=TLS_CA_PEM_PARSE_FAILED|stderrBytes=32|stdoutChars=0|operationStage=linux-client-observation') 'Safe summary was not preserved'
        Assert ($values[1]-ceq'TLS_LAB_RUNTIME_COMMAND_FAILED|exitCode=1|stderrClass=TLS_SQLCLIENT_OPEN_AUTHENTICATION|stderrBytes=32|stdoutChars=0|operationStage=linux-client-qualification') 'SQLClient summary class was not preserved'
        Assert ($values[8]-ceq'TLS_LINUX_BRIDGE_PROTOCOL') 'Safe bridge protocol code was not preserved'
        Assert ($values[9]-ceq'TLS_LINUX_CONSUMER_REJECTED_OR_RECOVERY_REQUIRED') 'A suffix on a safe bridge token was exposed'
        Assert ($values[10]-ceq'TLS_CA_ACL_INVALID'-and$values[11]-ceq'TLS_LINUX_BOOTSTRAP_LIMIT'-and
            $values[12]-ceq'TLS_LINUX_SESSION_REJECTED'-and$values[13]-ceq'TLS_QUALIFICATION_SQLCMD_TIMEOUT') 'A fixed CA, bootstrap, session, or qualification code was not preserved'
        Assert ($values[14]-ceq'TLS_LINUX_CONSUMER_REJECTED_OR_RECOVERY_REQUIRED') 'A suffix on a safe CA token was exposed'
        Assert ($values[15]-ceq'TLS_LINUX_CHILD_EXIT_NONZERO|exitCode=7|hello=1|verifierRequests=2|resultSeen=1|lastVerifiedStack=ODBC_SQLCMD|nextExpectedFrame=none|stderrClass=TLS_CA_PEM_PARSE_FAILED|stderrBytes=19') 'Safe bridge exit metadata was not preserved'
        Assert ($values[16]-ceq'TLS_LINUX_CONSUMER_REJECTED_OR_RECOVERY_REQUIRED'-and$values[17]-ceq$values[16]-and$values[18]-ceq$values[16]) 'Malformed bridge exit metadata was exposed'
        Assert ($values[19]-ceq$values[20]) 'A fixed Linux binding, transfer, or qualification code was not preserved'
        Assert ($values[21]-ceq'TLS_LINUX_CHILD_EXIT_NONZERO|exitCode=1|hello=1|verifierRequests=1|resultSeen=0|lastVerifiedStack=SYSTEM_DATA_SQLCLIENT|nextExpectedFrame=VERIFY_ODBC_SQLCMD|stderrClass=RUNTIME_TIMEOUT|stderrBytes=0') 'Bound next-protocol-frame diagnostic was not preserved'
        Assert ($values[22]-ceq'TLS_LINUX_CONSUMER_REJECTED_OR_RECOVERY_REQUIRED') 'Inconsistent peer progress was exposed'
        Assert ($values[23]-ceq'TLS_SQLCLIENT_CONSTRUCT_INVALID_ARGUMENT') 'Safe SqlClient construction classification was not preserved through the public App boundary'
        Assert ($values[24]-ceq'TLS_LINUX_CONSUMER_REJECTED_OR_RECOVERY_REQUIRED,TLS_LINUX_CONSUMER_REJECTED_OR_RECOVERY_REQUIRED,TLS_LINUX_CONSUMER_REJECTED_OR_RECOVERY_REQUIRED') 'Constructor-only argument category must not be accepted for other SQLClient phases'
        Assert ($values[25]-ceq'TLS_LINUX_CHILD_EXIT_NONZERO|exitCode=1|hello=1|verifierRequests=1|resultSeen=0|lastVerifiedStack=SYSTEM_DATA_SQLCLIENT|nextExpectedFrame=VERIFY_ODBC_SQLCMD|stderrClass=TLS_SQLCLIENT_CONSTRUCT_PLATFORM_UNSUPPORTED_AT_INITIAL_CATALOG|stderrBytes=0') 'Longest closed SqlClient construction phase was not preserved at the public bridge boundary'
        Assert (@($values[2..7]+$values[9]+$values[14]+$values[16..18]|Where-Object {$_-cne'TLS_LINUX_CONSUMER_REJECTED_OR_RECOVERY_REQUIRED'}).Count-eq0) 'Malformed or secret-bearing diagnostics were exposed'
    }
    Check 'Public preflight catch emits the safe category while hiding the inner exception' {
        $message=& $module {
            . (Join-Path $script:ModuleRoot 'Public/Invoke-SqlServerLabLinuxPreflight.ps1')
            function Assert-LabTlsLiveQualificationHost {}
            function Invoke-LabTlsLinuxConsumerBridge {
                $inner=[InvalidOperationException]::new($script:PublicFailure)
                throw [InvalidOperationException]::new('wrapper path=C:\private\ca.pem password=synthetic-secret',$inner)
            }
            $script:PublicFailure='TLS_LAB_RUNTIME_COMMAND_FAILED|exitCode=1|stderrClass=TLS_CA_PEM_PARSE_FAILED|stderrBytes=32|stdoutChars=0|operationStage=linux-client-observation'
            $caResult=$null
            try{Invoke-SqlServerLabLinuxPreflight -ExportBytes ([byte[]]@(1)) -StateRoot 'synthetic' -RunId 'synthetic' -InstanceId primary -ToolbeltRoot 'synthetic'}catch{$caResult=$_.Exception.Message}
            $script:PublicFailure='TLS_LAB_RUNTIME_COMMAND_FAILED|exitCode=1|stderrClass=TLS_SQLCLIENT_OPEN_AUTHENTICATION|stderrBytes=32|stdoutChars=0|operationStage=linux-client-qualification'
            $sqlClientResult=$null
            try{Invoke-SqlServerLabLinuxPreflight -ExportBytes ([byte[]]@(1)) -StateRoot 'synthetic' -RunId 'synthetic' -InstanceId primary -ToolbeltRoot 'synthetic'}catch{$sqlClientResult=$_.Exception.Message}
            $script:PublicFailure='TLS_LINUX_BRIDGE_PROTOCOL'
            $bridgeProtocolResult=$null
            try{Invoke-SqlServerLabLinuxPreflight -ExportBytes ([byte[]]@(1)) -StateRoot 'synthetic' -RunId 'synthetic' -InstanceId primary -ToolbeltRoot 'synthetic'}catch{$bridgeProtocolResult=$_.Exception.Message}
            $script:PublicFailure='TLS_CA_ACL_INVALID'
            $caAclResult=$null
            try{Invoke-SqlServerLabLinuxPreflight -ExportBytes ([byte[]]@(1)) -StateRoot 'synthetic' -RunId 'synthetic' -InstanceId primary -ToolbeltRoot 'synthetic'}catch{$caAclResult=$_.Exception.Message}
            $script:PublicFailure='TLS_LAB_RUNTIME_RECOVERY_REQUIRED'
            $runtimeRecoveryResult=$null
            try{Invoke-SqlServerLabLinuxPreflight -ExportBytes ([byte[]]@(1)) -StateRoot 'synthetic' -RunId 'synthetic' -InstanceId primary -ToolbeltRoot 'synthetic'}catch{$runtimeRecoveryResult=$_.Exception.Message}
            @($caResult,$sqlClientResult,$bridgeProtocolResult,$caAclResult,$runtimeRecoveryResult)
        }
        Assert ($message[0]-ceq'TLS_LAB_RUNTIME_COMMAND_FAILED|exitCode=1|stderrClass=TLS_CA_PEM_PARSE_FAILED|stderrBytes=32|stdoutChars=0|operationStage=linux-client-observation'-and
            $message[1]-ceq'TLS_LAB_RUNTIME_COMMAND_FAILED|exitCode=1|stderrClass=TLS_SQLCLIENT_OPEN_AUTHENTICATION|stderrBytes=32|stdoutChars=0|operationStage=linux-client-qualification' -and
            $message[2]-ceq'TLS_LINUX_BRIDGE_PROTOCOL' -and
            $message[3]-ceq'TLS_CA_ACL_INVALID' -and $message[4]-ceq'TLS_LAB_RUNTIME_RECOVERY_REQUIRED' -and
            ($message-join' ')-notmatch'synthetic-secret|C:\\private') 'Public catch did not preserve only the sanitized summaries'
    }
}finally{Remove-Module $module;Remove-TestTemporaryDirectory -OwnedDirectory $owned}
Write-Host ('Checks: '+$passed+' passed, '+$failures.Count+' failed; provider/SQL actions: 0')
if($failures.Count){exit 1}
