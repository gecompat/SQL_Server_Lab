#Requires -Version 7.5
# Synthetic ownership/error checks and actual local controller-process custody.
# No provider, SQL, key, trust-store or namespace action is performed.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsLinuxObserver.ps1')
$passed=0;$failures=[Collections.Generic.List[string]]::new()
$observerSource=Get-Content -LiteralPath (Join-Path $repo 'Private/AuthenticatedTlsLinuxObserver.ps1') -Raw
$observerProgram=Get-LabTlsLinuxObservationProgram
$observerTokens=$null;$observerParseErrors=$null
$observerAst=[Management.Automation.Language.Parser]::ParseInput($observerProgram,'<Linux observer>',[ref]$observerTokens,[ref]$observerParseErrors)
$homeAssignments=@($observerAst.FindAll({param($node)
    $node-is[Management.Automation.Language.AssignmentStatementAst]-and
    $node.Left-is[Management.Automation.Language.VariableExpressionAst]-and
    $node.Left.VariablePath.UserPath-ieq'HOME'
},$true))
Add-CheckResult 'Linux observer avoids assigning to PowerShell automatic HOME' ($observerParseErrors.Count-eq0-and$homeAssignments.Count-eq0-and$observerProgram.Contains('$env:HOME-cne$clientHome'))
Add-CheckResult 'Linux observer parses the exact CA PEM text with the same API as the TLS probe' (
    $observerSource.Contains('$caPem=[IO.File]::ReadAllText($ca)') -and
    $observerSource.Contains('X509Certificate2]::CreateFromPem($caPem)') -and
    -not $observerSource.Contains('X509Certificate2]::CreateFromPemFile($ca)'))
Add-CheckResult 'Linux observer emits fixed sanitized CA PEM stat, access, read and parse tokens' (
    $observerSource.Contains('TLS_LINUX_CA_PEM_STAT_FAILED') -and $observerSource.Contains('TLS_LINUX_CA_PEM_ACCESS_DENIED') -and
    $observerSource.Contains('TLS_LINUX_CA_PEM_READ_FAILED') -and $observerSource.Contains('TLS_LINUX_CA_PEM_PARSE_FAILED') -and
    $observerSource.Contains("-- `$Path 2>`$null") -and $observerSource.Contains('$exception=$_.Exception;while($null-ne$exception.InnerException){$exception=$exception.InnerException}'))
$module=New-Module -ArgumentList $repo -ScriptBlock {
    param($Root)
    . (Join-Path $Root 'Private/ContainerOwnedHostIntegration.ps1')
    . (Join-Path $Root 'Tests/Integration/Fixtures/TlsLinuxClientProbe.ps1')
    . (Join-Path $Root 'Tests/Common/AuthenticatedTlsLinuxClient.ps1')
    $script:intent=[pscustomobject]@{InstanceId='tls-linux-client';ContainerName='synthetic-tls-client';Provider='docker';RunId='11111111-1111-1111-1111-111111111111';ScopeId='synthetic-scope';IntentId='22222222-2222-2222-2222-222222222222';PolicyId='synthetic-policy';RootScopeId='synthetic-root'}
    $script:sqlId='a'*64;$script:image='sha256:'+('b'*64);$script:own=$true;$script:primary=$true;$script:running=$true
    function Get-LabOwnedHostRunPolicy {param($StateRoot,$RunId) $null=$StateRoot,$RunId;[pscustomobject]@{PolicyId=$script:intent.PolicyId;RootScopeId=$script:intent.RootScopeId}}
    function Read-LabOwnedHostRecord {param($Path) $null=$Path;return $script:intent}
    function Assert-LabOwnedHostContainerEffect {param($StateRoot,$RunId,$Provider,$ContainerId) $null=$StateRoot,$RunId,$Provider;if(-not $script:own -or $ContainerId -cne $script:sqlId){throw 'SYNTHETIC_FOREIGN_SQL_REJECTED'}}
    function Invoke-LabOwnedHostPinnedCommand {
        param($StateRoot,$Provider,$Arguments) $null=$StateRoot,$Provider
        if(($Arguments -join ' ') -cne ('inspect '+$script:sqlId)){throw 'SYNTHETIC_NO_PROVIDER_TRIPWIRE'}
        return @{ExitCode=0;Stdout=(@(@{Config=@{Labels=@{'sql-server-lab.instance-id'=$(if($script:primary){'primary'}else{'other'})}};State=@{Running=$script:running}})|ConvertTo-Json -Depth 5 -Compress)}
    }
    function Get-LabOwnedHostImageObservation {param($StateRoot,$Provider,$Image) $null=$StateRoot,$Provider;if($Image -cne 'mcr.microsoft.com/mssql/server:2025-CU9-ubuntu-24.04'){throw 'SYNTHETIC_WRONG_CLIENT_PROFILE'};@{Id=$script:image}}
    function Write-TlsLinuxProof {param($Context,$Name,$Value) $null=$Context,$Value;if($Name -cnotmatch '\Aclient-isolation-[0-9]+\.private\.json\z'){throw 'SYNTHETIC_ISOLATION_PROOF_NO_IO'}}
    function Test-Reject([string[]]$Vector,[string]$Provider='docker'){try{Assert-LabOwnedHostContainerCreateInputs -StateRoot 'synthetic-root' -Provider $Provider -Arguments $Vector;return $false}catch{return $true}}
    $script:FixtureChecks={
    $clientId='c'*64;$intentName='tls-client-'+('d'*32)
    foreach($hostname in @($clientId.Substring(0,12),$intentName)){
        $bound=Get-TlsLinuxBoundClientHostname $hostname $hostname $clientId $intentName
        [pscustomobject]@{Name='NSS accepts only freshly observed own short-CID or intent hostname';Pass=($bound -ceq $hostname)}
    }
    foreach($mode in @('foreign','config-mismatch','empty','shell-text','bad-id','bad-intent')){
        $hostname=$clientId.Substring(0,12);$observed=$hostname;$id=$clientId;$name=$intentName
        switch($mode){
            'foreign'{$hostname='foreign';$observed=$hostname}
            'config-mismatch'{$observed=$intentName}
            'empty'{$hostname='';$observed=''}
            'shell-text'{$hostname='name;command';$observed=$hostname}
            'bad-id'{$id='c'*63}
            'bad-intent'{$name='-invalid'}
        }
        $rejected=$false;try{$null=Get-TlsLinuxBoundClientHostname $hostname $observed $id $name}catch{$rejected=$_.Exception.Message -ceq 'TLS_LINUX_CLIENT_HOSTNAME_BINDING_INVALID'}
        [pscustomobject]@{Name=('NSS hostname binding rejects '+$mode);Pass=$rejected}
    }
    $nssGood="HOSTS_READABLE=1`nHOSTS_ACTUAL=0`nHOSTS_INTENT=1`nLOCALHOST_EXIT=0`nHOSTNAME_EXIT=2`n"
    $nss=Read-TlsLinuxNssFacts $nssGood
    [pscustomobject]@{Name='Closed NSS parser preserves failed own-hostname observation without inventing TLS proof';Pass=($nss.Count -eq 5 -and $nss.HOSTS_ACTUAL -eq 0 -and $nss.LOCALHOST_EXIT -eq 0 -and $nss.HOSTNAME_EXIT -eq 2)}
    foreach($text in @('',($nssGood+"HOSTS_ACTUAL=0`n"),($nssGood.Replace('HOSTS_ACTUAL=0','HOSTS_ACTUAL=2')),($nssGood.Replace('HOSTNAME_EXIT=2','HOSTNAME_EXIT=256')),($nssGood.Replace('HOSTNAME_EXIT=2','HOSTNAME_EXIT=02')),($nssGood.Replace('HOSTNAME_EXIT=2','HOSTNAME_EXIT=private')),($nssGood.Replace("HOSTNAME_EXIT=2`n",'')),($nssGood.Replace('HOSTNAME_EXIT=2','FOREIGN=2')),($nssGood.Replace('HOSTS_ACTUAL=0',"HOSTS_ACTUAL=0`r0")))){
        $rejected=$false;try{$null=Read-TlsLinuxNssFacts $text}catch{$rejected=$_.Exception.Message -ceq 'TLS_LINUX_NSS_DIAGNOSTIC_INVALID'}
        [pscustomobject]@{Name='NSS parser rejects missing, duplicate, unknown, nonscalar and out-of-range facts';Pass=$rejected}
    }
    $nssModule=New-Module -ArgumentList $Root -ScriptBlock {
        param($Source)
        . (Join-Path $Source 'Tests/Common/AuthenticatedTlsLinuxClient.ps1')
        # Exercise the actual helper from a CRLF source independently of the
        # checkout's own line-ending configuration. No shell is executed.
        $parseTokens=$null;$parseErrors=$null
        $sourceAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Source 'Tests/Common/AuthenticatedTlsLinuxClient.ps1'),[ref]$parseTokens,[ref]$parseErrors)
        $definition=$sourceAst.Find({param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq 'Assert-TlsLinuxClientNameResolution'},$true)
        . ([scriptblock]::Create($definition.Extent.Text.Replace("`r`n","`n").Replace("`n","`r`n")))
        $script:mode='valid';$script:proof=$null;$script:calls=0
        function Invoke-TlsLinuxNative {
            param($Context,$Arguments,$DiagnosticOperation)
            $script:calls++
            $hostname=if($script:mode -ceq 'hostname-not-applied'){$Context.ClientId.Substring(0,12)}else{$Context.ClientIntent.ContainerName}
            if($Arguments.Count -eq 4 -and ($Arguments -join '|') -ceq ('exec|'+$Context.ClientId+'|/usr/bin/cat|/proc/sys/kernel/hostname')){return $hostname}
            if($DiagnosticOperation -cne 'CLIENT_NSS' -or $Arguments.Count -ne 8 -or $Arguments[0] -cne 'exec' -or $Arguments[1] -cne $Context.ClientId -or $Arguments[2] -cne '/bin/sh' -or $Arguments[3] -cne '-c' -or $Arguments[5] -cne 'tls-linux-nss' -or $Arguments[6] -cne $hostname -or $Arguments[7] -cne $Context.ClientIntent.ContainerName -or $Arguments[4].Contains("`r") -or $Arguments[4] -cnotmatch '/usr/bin/timeout --signal=KILL 3s /usr/bin/getent ahostsv4 localhost' -or $Arguments[4] -cnotmatch '/usr/bin/getent ahostsv4 "\$1"' -or $Arguments[4] -match 'chown|chmod|tee|sed -i|>>|cat >'){throw 'SYNTHETIC_NSS_NO_PROVIDER_TRIPWIRE'}
            $local=if($script:mode -ceq 'localhost-fail'){2}else{0};$own=if($script:mode -ceq 'hostname-fail'){2}else{0}
            return "HOSTS_READABLE=1`nHOSTS_ACTUAL=0`nHOSTS_INTENT=1`nLOCALHOST_EXIT=$local`nHOSTNAME_EXIT=$own"
        }
        function Write-TlsLinuxProof {param($Context,$Name,$Value) $null=$Context;if($Name -cne 'client-synthetic-nss.private.json'){throw 'SYNTHETIC_NSS_PROOF_INVALID'};$script:proof=$Value}
        Export-ModuleMember -Function @()
    }
    try{
        foreach($mode in @('valid','localhost-fail','hostname-fail','hostname-not-applied','config-mismatch')){
            & $nssModule {param($Mode) $script:mode=$Mode;$script:proof=$null;$script:calls=0} $mode
            $context=@{ClientId=$clientId;ClientIntent=@{ContainerName=$intentName}}
            $observation=@{Config=@{Hostname=$(if($mode -ceq 'config-mismatch'){'foreign'}elseif($mode -ceq 'hostname-not-applied'){$clientId.Substring(0,12)}else{$intentName})}}
            $code='PASS';try{& $nssModule {param($C,$O) Assert-TlsLinuxClientNameResolution $C $O 'synthetic'} $context $observation}catch{$code=$_.Exception.Message}
            $facts=& $nssModule {@{Proof=$script:proof;Calls=$script:calls}}
            $expected=switch($mode){'valid'{'PASS'};'localhost-fail'{'TLS_LINUX_CLIENT_LOCALHOST_NSS_UNRESOLVED'};'hostname-fail'{'TLS_LINUX_CLIENT_HOSTNAME_NSS_UNRESOLVED'};'hostname-not-applied'{'TLS_LINUX_CLIENT_HOSTNAME_NOT_APPLIED'};'config-mismatch'{'TLS_LINUX_CLIENT_HOSTNAME_BINDING_INVALID'}}
            $safe=if($mode -ceq 'config-mismatch'){$facts.Calls -eq 1 -and $null -eq $facts.Proof}else{$facts.Calls -eq 2 -and $facts.Proof.OdbcResolverParameters -ceq 'NOT_OBSERVED' -and $facts.Proof.TlsQualification -ceq 'NOT_CLAIMED' -and ($facts.Proof|ConvertTo-Json -Compress) -notmatch ($clientId+'|'+$intentName)}
            [pscustomobject]@{Name=('Actual NSS helper bounded argv, closed proof and fail-closed preflight: '+$mode);Pass=($code -ceq $expected -and $safe)}
        }
    }finally{Remove-Module $nssModule -Force}
    $failureModule=New-Module -ArgumentList $Root -ScriptBlock {
        param($Source)
        . (Join-Path $Source 'Tests/Common/AuthenticatedTlsLinuxClient.ps1')
        $script:proof=$null;$script:actual=$null
        function Enter-TlsLinuxCommandBudget {param($Context) $Context.Commands++}
        function Assert-LabTlsRuntimeBudget {param($Budget,$Count) $null=$Budget,$Count}
        function New-LabTlsRuntimeProcessInfo {
            param($Arguments,$Budget) $null=$Budget;$script:actual=$Arguments
            $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})))
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true
            $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            foreach($arg in @('-NoLogo','-NoProfile','-Command','[Console]::Error.Write("synthetic failure"); exit 3')){$start.ArgumentList.Add($arg)}
            return $start
        }
        function Get-LabTlsWindowsProcessFacts {@{UserSid='synthetic'}}
        function ConvertTo-LabTlsRegistryWriterBytes {param($Value) return $Value}
        function Write-LabTlsCaPrivateFile {param($Path,$Sid,$Bytes) $null=$Path,$Sid;$script:proof=$Bytes}
        Export-ModuleMember -Function @()
    }
    try{
        foreach($operation in @('','CLIENT_NSS')){
            $context=@{Module=$failureModule;Commands=0;Evidence=$Root;Budget=@{};Deadline=[DateTimeOffset]::UtcNow.AddSeconds(30)}
            $argsVector=@('exec',$clientId,'synthetic-private-hostname')
            $failed=$false;try{& $failureModule {param($C,$A,$Op) if($Op){Invoke-TlsLinuxNative $C $A -DiagnosticOperation $Op}else{Invoke-TlsLinuxNative $C $A}} $context $argsVector $operation}catch{$failed=$_.Exception.Message -ceq 'TLS_LINUX_NATIVE_COMMAND_FAILED:UNCLASSIFIED_NATIVE_EXIT'}
            $captured=& $failureModule {@{Actual=$script:actual;Proof=$script:proof}}
            $expected=if($operation){'OPERATION|CLIENT_NSS'}else{$argsVector -join '|'}
            [pscustomobject]@{Name=('Actual failed local subprocess keeps execution argv and sanitizes only fixed NSS proof: '+$operation);Pass=($failed -and ($captured.Actual -join '|') -ceq ($argsVector -join '|') -and ($captured.Proof.Arguments -join '|') -ceq $expected -and $captured.Proof.ExitCode -eq 3)}
        }
    }finally{Remove-Module $failureModule -Force}
    foreach($case in @(
        @{Text='tls-linux-nss: 12: Syntax error: end of file unexpected';Code='TLS_LINUX_NSS_SHELL_SYNTAX'},
        @{Text='tls-linux-nss: 4: /usr/bin/getent: not found';Code='TLS_LINUX_NSS_TOOL_UNAVAILABLE'},
        @{Text='No such file or directory';Code='UNCLASSIFIED_NATIVE_EXIT'},
        @{Text='syntax error; tool not found';Code='UNCLASSIFIED_NATIVE_EXIT'},
        @{Text='host not found';Code='UNCLASSIFIED_NATIVE_EXIT'},
        @{Text='container not found';Code='UNCLASSIFIED_NATIVE_EXIT'},
        @{Text='configuration syntax error';Code='UNCLASSIFIED_NATIVE_EXIT'},
        @{Text='tls-linux-nss: 4: /foreign/tool: not found';Code='UNCLASSIFIED_NATIVE_EXIT'},
        @{Text="tls-linux-nss: 12: Syntax error: unexpected token`ntls-linux-nss: 4: /usr/bin/getent: not found";Code='UNCLASSIFIED_NATIVE_EXIT'},
        @{Text='synthetic private diagnostic';Code='UNCLASSIFIED_NATIVE_EXIT'})){
        $diagnostic=Get-TlsLinuxNssFailureDiagnostic -Stdout '{"Status":"PASS"}' -Stderr $case.Text
        [pscustomobject]@{Name='NSS shell failures retain only unambiguous closed codes and never successful stdout';Pass=($diagnostic.Count -eq 2 -and $diagnostic.Code -ceq $case.Code -and ($diagnostic|ConvertTo-Json -Compress) -notmatch [regex]::Escape($case.Text))}
    }
    $vector=@(Get-LabOwnedHostTlsLinuxClientArguments $script:intent $script:sqlId $script:image)
    $pass=$true;try{Assert-LabOwnedHostContainerCreateInputs -StateRoot 'synthetic-root' -Provider docker -Arguments $vector}catch{$pass=$false}
    [pscustomobject]@{Name='Exact receipt-bound TLS Linux fixture accepted without native actions';Pass=$pass}
    $script:intent.Provider='podman'
    $podman=@(Get-LabOwnedHostTlsLinuxClientArguments $script:intent $script:sqlId $script:image)
    $podmanMount='/opt/tls-client:rw,exec,nosuid,nodev,size=512m,mode=0700,U'
    $dockerMount='/opt/tls-client:rw,exec,nosuid,nodev,size=512m,mode=0700,uid=10001,gid=0'
    $expectedPodman=[string[]](@($vector[0..2])+@('--hostname',$script:intent.ContainerName)+@($vector[3..($vector.Count-1)]));$expectedPodman[[Array]::IndexOf($expectedPodman,$dockerMount)]=$podmanMount
    [pscustomobject]@{Name='Podman adds only bound own hostname and tmpfs ownership spelling; Docker vector remains unchanged';Pass=(($podman -join '|') -ceq ($expectedPodman -join '|') -and $vector -cnotcontains '--hostname')}
    [pscustomobject]@{Name='Podman exact nonroot tmpfs profile accepted by receipt-bound guard';Pass=(-not(Test-Reject $podman 'podman'))}
    [pscustomobject]@{Name='Podman rejects Docker tmpfs uid options';Pass=(Test-Reject $vector 'podman')}
    foreach($hostname in @('localhost','foreign','-invalid','name.example.invalid')){
        $changed=[string[]]$podman.Clone();$changed[[Array]::IndexOf($changed,'--hostname')+1]=$hostname
        [pscustomobject]@{Name='Podman rejects hostname differing from exact own intent';Pass=(Test-Reject $changed 'podman')}
    }
    $withoutHostname=@($podman[0..2])+@($podman[5..($podman.Count-1)])
    [pscustomobject]@{Name='Podman requires own hostname argument exactly once';Pass=((Test-Reject $withoutHostname 'podman') -and (Test-Reject (@($podman)+@('--hostname',$script:intent.ContainerName)) 'podman'))}
    $originalName=$script:intent.ContainerName
    foreach($invalidName in @('-invalid','invalid-','name.example.invalid',('n'*64),'name;command',@('name'),$null)){
        $script:intent.ContainerName=$invalidName;$rejected=$false
        try{$null=Get-LabOwnedHostTlsLinuxClientArguments $script:intent $script:sqlId $script:image}catch{$rejected=$_.Exception.Message -ceq 'OWNED_HOST_TLS_LINUX_CLIENT_INPUT_INVALID'}
        [pscustomobject]@{Name='Podman rejects non-DNS-label or nonscalar intent hostname before native work';Pass=$rejected}
    }
    $script:intent.ContainerName=$originalName
    foreach($badMount in @('/opt/tls-client:rw,exec,nosuid,nodev,size=512m,mode=0777,U','/foreign:rw,U','/opt/tls-client:rw,exec,nosuid,nodev,size=4g,mode=0700,U')){
        $changed=[string[]]$podman.Clone();$changed[[Array]::IndexOf($changed,$podmanMount)]=$badMount
        [pscustomobject]@{Name='Podman rejects broader mode, host path and memory profile';Pass=(Test-Reject $changed 'podman')}
    }
    foreach($provider in @('Podman','other',@('podman'),$null)){
        $script:intent.Provider=$provider;$rejected=$false
        try{$null=Get-LabOwnedHostTlsLinuxClientArguments $script:intent $script:sqlId $script:image}catch{$rejected=$_.Exception.Message -ceq 'OWNED_HOST_TLS_LINUX_CLIENT_INPUT_INVALID'}
        [pscustomobject]@{Name='Fixture rejects unknown, wrong-case and nonscalar provider before native work';Pass=$rejected}
    }
    $script:intent.Provider='docker'
    [pscustomobject]@{Name='Docker rejects Podman tmpfs spelling';Pass=(Test-Reject $podman)}
    $isolation=New-Module -ArgumentList $Root -ScriptBlock {
        param($Source)
        . (Join-Path $Source 'Tests/Common/AuthenticatedTlsLinuxClient.ps1')
        function Write-TlsLinuxProof {param($Context,$Name,$Value) $null=$Context;if($Name -cne 'client-isolation-1.private.json'){throw 'SYNTHETIC_ISOLATION_PROOF_INVALID'};$script:proof=$Value}
        Export-ModuleMember -Function @()
    }
    try{
        foreach($provider in @('docker','podman')){
            $modes=@('valid','stopped','writable-root','root-user','foreign-namespace','host-bind','host-port','privileged','missing-nnp','nonzero-caps')
            if($provider -ceq 'podman'){$modes+=@('nonzero-bounding','missing-effective','scalar-effective')}
            foreach($mode in $modes){
                $observed=@{State=@{Running=$true};Config=@{User='10001:0'};HostConfig=@{ReadonlyRootfs=$true;NetworkMode=('container:'+('a'*64));Binds=$null;PortBindings=$null;CapDrop=@('ALL');SecurityOpt=@('no-new-privileges');Privileged=$false};EffectiveCaps=@();BoundingCaps=@()}|ConvertTo-Json -Depth 8|ConvertFrom-Json
                if($provider -ceq 'podman'){$observed.HostConfig.CapDrop=@('CAP_CHOWN','CAP_NET_BIND_SERVICE')}
                switch($mode){
                    'stopped'{$observed.State.Running=$false};'writable-root'{$observed.HostConfig.ReadonlyRootfs=$false};'root-user'{$observed.Config.User='0'}
                    'foreign-namespace'{$observed.HostConfig.NetworkMode='container:foreign'};'host-bind'{$observed.HostConfig.Binds=@('foreign:/host')}
                    'host-port'{$observed.HostConfig.PortBindings=[pscustomobject]@{'1433/tcp'=@()}};'privileged'{$observed.HostConfig.Privileged=$true}
                    'missing-nnp'{$observed.HostConfig.SecurityOpt=@()};'nonzero-caps'{if($provider -ceq 'podman'){$observed.EffectiveCaps=@('CAP_CHOWN')}else{$observed.HostConfig.CapDrop=@('CAP_CHOWN')}}
                    'nonzero-bounding'{$observed.BoundingCaps=@('CAP_CHOWN')};'missing-effective'{$observed.PSObject.Properties.Remove('EffectiveCaps')}
                    'scalar-effective'{$observed.EffectiveCaps=''}
                }
                $accepted=$true;try{& $isolation {param($C,$O) Assert-TlsLinuxClientIsolation $C $O} @{Provider=$provider;SqlId=('a'*64);Commands=1} $observed}catch{$accepted=$false}
                [pscustomobject]@{Name=($provider+' isolation metadata and bounded diagnostics: '+$mode);Pass=($accepted -eq ($mode -ceq 'valid'))}
            }
        }
    }finally{Remove-Module $isolation -Force}
    $zero='CapInh:'+('0'*16)+"`nCapPrm:"+('0'*16)+"`nCapEff:"+('0'*16)+"`nCapBnd:"+('0'*16)+"`nCapAmb:"+('0'*16)+"`nNoNewPrivs:1"
    foreach($text in @($zero,$zero.Replace("`n","`r`n"))){$accepted=$true;try{Assert-TlsLinuxKernelCapabilities $text}catch{$accepted=$false};[pscustomobject]@{Name='All five actual kernel capability masks and NNP must be exact';Pass=$accepted}}
    $badStatus=@($zero.Replace('NoNewPrivs:1','NoNewPrivs:0'),($zero+"`nCapEff:"+('0'*16)),$zero.Replace('CapBnd:','Unexpected:'),$zero.Replace('CapAmb:'+('0'*16),'CapAmb:0'))
    foreach($name in @('CapInh','CapPrm','CapEff','CapBnd','CapAmb')){$badStatus+=$zero.Replace(($name+':'+('0'*16)),($name+':'+('0'*15)+'1'))}
    foreach($text in $badStatus){$rejected=$false;try{Assert-TlsLinuxKernelCapabilities $text}catch{$rejected=$_.Exception.Message -ceq 'TLS_LINUX_KERNEL_ISOLATION_INVALID'};[pscustomobject]@{Name='Any nonzero mask, missing/duplicate field or absent NNP fails closed';Pass=$rejected}}
    foreach($pair in @(@('--network','host'),@('--user','0'),@('--memory','4096m'),@('--pids-limit','1024'),@('--entrypoint','/bin/sh'),@('--security-opt','seccomp=unconfined'),@('--cap-drop','NET_ADMIN'),@('--tmpfs','/opt/tls-client:rw,exec,size=4g'))){
        $changed=[string[]]$vector.Clone();$index=[Array]::IndexOf($changed,$pair[0]);$changed[$index+1]=$pair[1]
        [pscustomobject]@{Name=('Fixture rejects altered '+$pair[0]);Pass=(Test-Reject $changed)}
    }
    foreach($addition in @(@('--privileged'),@('--volume','synthetic:/host:rw'),@('--publish','1433:1433'),@('--env','SSL_CERT_FILE=/foreign'),@('--network',('container:'+('c'*64))))){
        [pscustomobject]@{Name=('Fixture rejects extra '+$addition[0]);Pass=(Test-Reject ($vector+$addition))}
    }
    $withoutLabel=@($vector|Where-Object{$_ -cne 'sql-server-lab.fixture-kind=tls-linux-client-v1'})
    [pscustomobject]@{Name='Generic create path retains its restrictive tmpfs contract';Pass=(Test-Reject $withoutLabel)}
    $script:own=$false
    [pscustomobject]@{Name='Foreign namespace rejected before fixture creation';Pass=(Test-Reject $vector)}
    $script:own=$true;$script:primary=$false
    [pscustomobject]@{Name='Other instance namespace rejected';Pass=(Test-Reject $vector)}
    $script:primary=$true;$script:running=$false
    [pscustomobject]@{Name='Stopped SQL namespace rejected';Pass=(Test-Reject $vector)}
    $script:running=$true
    $mismatch=[string[]]$vector.Clone();$mismatch[[Array]::IndexOf($mismatch,$script:image)]='sha256:'+('c'*64)
    [pscustomobject]@{Name='Unselected immutable client image rejected';Pass=(Test-Reject $mismatch)}
    $types=@('System.Data.SqlClient.SqlException','System.Security.Authentication.AuthenticationException')
    [pscustomobject]@{Name='Typed native certificate rejection recognized';Pass=(Test-TlsLinuxCertificateFailure $types 'The remote certificate was rejected by RemoteCertificateValidationCallback')}
    foreach($case in @(@(@('System.Data.SqlClient.SqlException'),'certificate failure'),@($types,'Login failed'),@(@('System.Net.Sockets.SocketException'),'certificate network timeout'))){
        [pscustomobject]@{Name='Network/login/untyped failures never become TLS negatives';Pass=(-not(Test-TlsLinuxCertificateFailure $case[0] $case[1]))}
    }
    foreach($version in @('2019-CU32')){
        $identityContext=@{Version=$version;SqlExecutionUser=$null}
        Initialize-TlsLinuxSqlExecutionIdentity $identityContext
        [pscustomobject]@{Name=('SQL identity preserves the existing fixed argv for '+$version+' without native calls');Pass=((Get-TlsLinuxSqlExecutionUser $identityContext) -ceq '10001:0')}
    }
    foreach($version in @('2022-CU27','2025-CU9')){foreach($bad in @('0','root','10001:0',@('10001'),$null)){
        $rejected=$false;try{$null=Get-TlsLinuxSqlExecutionUser @{Version=$version;SqlExecutionUser=$bad}}catch{$rejected=$_.Exception.Message -ceq 'TLS_LINUX_SQL_IDENTITY_UNQUALIFIED'}
        [pscustomobject]@{Name=($version+' rejects root, forced group, nonscalar and unqualified identity');Pass=$rejected}
    }
    }
    foreach($text in @('0:0:0:0:1','10001:65536:10001:0:1','10001:0:10001:65536:1','10001:0:10001:0:2','10001:0:10001:0:1:extra','private invalid text')){
        $rejected=$false;try{$null=Read-TlsLinuxSqlIdentity $text}catch{$rejected=$_.Exception.Message -ceq 'TLS_LINUX_SQL_IDENTITY_INVALID'}
        [pscustomobject]@{Name='SQL identity rejects invalid UID, group bounds and record shapes';Pass=$rejected}
    }
    $identityModule=New-Module -ArgumentList $Root -ScriptBlock {
        param($Source)
        . (Join-Path $Source 'Tests/Common/AuthenticatedTlsLinuxClient.ps1')
        $script:users=[Collections.Generic.List[string]]::new();$script:proof=$null;$script:mode='valid'
        function Invoke-TlsLinuxNative {
            param($Context,$Arguments)
            if($Arguments.Count -ne 7 -or $Arguments[0] -cne 'exec' -or $Arguments[1] -cne '--user' -or
                $Arguments[2] -cnotin @('10001:0','10001') -or $Arguments[3] -cne $Context.SqlId -or
                $Arguments[4] -cne '/bin/sh' -or $Arguments[5] -cne '-c' -or
                $Arguments[6] -match 'mkdir|openssl|mssql-conf|chmod|chown|cat >'){throw 'SYNTHETIC_IDENTITY_NO_PROVIDER_TRIPWIRE'}
            $script:users.Add($Arguments[2])
            if($Arguments[2] -ceq '10001:0'){return '10001:0:10001:10001:0'}
            switch($script:mode){
                'valid'{return '10001:10001:10001:10001:1'}
                'unwritable'{return '10001:10001:10001:10001:0'}
                'group-mismatch'{return '10001:0:10001:10001:1'}
                'root'{return '0:0:0:0:1'}
                'malformed'{return 'invalid'}
            }
        }
        function Write-TlsLinuxProof {param($Context,$Name,$Value) $null=$Context;if($Name -cne 'sql-execution-identity.private.json'){throw 'SYNTHETIC_IDENTITY_PROOF_INVALID'};$script:proof=$Value}
        Export-ModuleMember -Function @()
    }
    try{
        foreach($version in @('2022-CU27','2025-CU9')){foreach($mode in @('valid','unwritable','group-mismatch','root','malformed')){
            & $identityModule {param($Mode) $script:mode=$Mode;$script:users.Clear();$script:proof=$null} $mode
            $identityContext=@{Version=$version;SqlId=('a'*64);SqlExecutionUser='stale'}
            $accepted=$true;try{& $identityModule {param($C) Initialize-TlsLinuxSqlExecutionIdentity $C} $identityContext}catch{$accepted=$false}
            $facts=& $identityModule {@{Users=$script:users.ToArray();Proof=$script:proof}}
            $correct=if($mode -ceq 'valid'){$accepted -and $identityContext.SqlExecutionUser -ceq '10001' -and $facts.Proof.Qualified -and $facts.Proof.ReadOnly}else{-not $accepted -and $null -eq $identityContext.SqlExecutionUser}
            [pscustomobject]@{Name=($version+' read-only identity differential fails closed before leaf work: '+$mode);Pass=($correct -and ($facts.Users -join '|') -ceq '10001:0|10001')}
        }
        }
    }finally{Remove-Module $identityModule -Force}
    $priorCulture=[Globalization.CultureInfo]::CurrentCulture
    try{
        foreach($culture in @('de-AT','en-US')){
            [Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($culture)
            foreach($stamp in @('2026-10-22T19:13:46.0000000+02:00','2026-10-22T17:13:46Z')){
                $json=@{Status='PASS';UtcNow=$stamp;Results=@(@{Stack='System.Data.SqlClient'},@{Stack='ODBC-sqlcmd'})}|ConvertTo-Json -Compress
                $observed=Read-TlsLinuxPairResult $json
                $instant=[DateTimeOffset]::Parse($observed.UtcNow,[Globalization.CultureInfo]::InvariantCulture)
                [pscustomobject]@{Name=('Native probe time remains exact RFC3339 text and UTC instant in '+$culture+' '+$stamp);Pass=($observed.UtcNow -is [string] -and $observed.UtcNow -ceq $stamp -and $instant.UtcDateTime -eq [datetime]::new(2026,10,22,17,13,46,[DateTimeKind]::Utc))}
            }
        }
        foreach($stamp in @('10/22/2026 19:13:46','2026-02-30T17:13:46Z',@('2026-10-22T17:13:46Z'),42,$true)){
            $json=@{Status='PASS';UtcNow=$stamp;Results=@(@{Stack='System.Data.SqlClient'},@{Stack='ODBC-sqlcmd'})}|ConvertTo-Json -Compress
            $rejected=$false;try{$null=Read-TlsLinuxPairResult $json}catch{$rejected=$_.Exception.Message -ceq 'TLS_LINUX_PAIR_RESULT_INVALID'}
            [pscustomobject]@{Name='Probe rejects local, invalid and nonscalar times with fixed failure';Pass=$rejected}
        }
    }finally{[Globalization.CultureInfo]::CurrentCulture=$priorCulture}
    foreach($trust in @($false,$true)){
        $connection=$null;$observed=$null
        try{
            $connection=New-TlsLinuxClrConnection @{TrustServerCertificate=$trust;Password='synthetic-offline-noncredential'}
            $observed=[Data.SqlClient.SqlConnectionStringBuilder]::new($connection.ConnectionString)
            $correct=$connection.State -eq [Data.ConnectionState]::Closed -and $connection.DataSource -ceq 'tcp:localhost,1433' -and
                $observed['Initial Catalog'] -ceq 'master' -and $observed['User ID'] -ceq 'sa' -and $observed['Encrypt'] -eq $true -and
                $observed['TrustServerCertificate'] -eq $trust -and $observed['Pooling'] -eq $false -and
                $observed['Connect Timeout'] -eq 5 -and $observed['ConnectRetryCount'] -eq 0
            [pscustomobject]@{Name=('Actual CLR construction uses canonical keywords with trust '+$trust+' and never opens SQL');Pass=$correct}
        }finally{if($observed){$observed.Clear()};if($connection){$connection.Dispose()}}
    }
    foreach($case in @(
        @{Types=@('System.PlatformNotSupportedException');Message='synthetic private detail';Code='PLATFORM_UNSUPPORTED'},
        @{Types=@('System.IO.FileNotFoundException');Message='synthetic private path';Code='ASSEMBLY_UNAVAILABLE'},
        @{Types=$types;Message='synthetic certificate failure';Code='CERTIFICATE'},
        @{Types=@('System.Data.SqlClient.SqlException');Message='Login failed for synthetic-private-user';Code='LOGIN'},
        @{Types=@('System.TimeoutException');Message='synthetic private endpoint';Code='TIMEOUT'},
        @{Types=@('System.Net.Sockets.SocketException');Message='synthetic private endpoint';Code='NETWORK'},
        @{Types=@('System.Exception');Message='TLS_LINUX_SQL_RESULT_INVALID';Code='SQL_RESULT'},
        @{Types=@('System.Exception');Message='synthetic-private-password-not-to-emit';Code='UNCLASSIFIED'}
    )){
        $actual=Get-TlsLinuxClrFailureCode $case.Types $case.Message
        [pscustomobject]@{Name=('Unexpected CLR '+$case.Code+' emits only its fixed diagnostic category');Pass=($actual -is [string] -and $actual -ceq $case.Code)}
    }
    foreach($exit in @(0,1)){foreach($stderr in @('','synthetic-private-warning')){foreach($output in @('15.0.4430.1|TRUE','synthetic-private-output')){foreach($driverSeen in @($false,$true)){
        $code=Get-TlsLinuxOdbcPositiveFailureCode -ExitCode $exit -Stderr $stderr -Stdout $output -ExpectedBuild '15.0.4430.1' -DriverObserved $driverSeen
        $originalAccept=$exit -eq 0 -and -not $stderr -and $output -ceq '15.0.4430.1|TRUE' -and $driverSeen
        [pscustomobject]@{Name='ODBC diagnostic split preserves every original positive acceptance condition';Pass=([string]::IsNullOrEmpty($code) -eq $originalAccept)}
    }}}}
    foreach($case in @(
        @{Exit=1;Error='certificate verify failed synthetic-private';Output='';Driver=$true;Maps='READABLE';Suffix='EXIT_CERTIFICATE'},
        @{Exit=1;Error='Login failed synthetic-private';Output='';Driver=$true;Maps='READABLE';Suffix='EXIT_LOGIN'},
        @{Exit=1;Error='Login timeout expired synthetic-private';Output='';Driver=$true;Maps='READABLE';Suffix='EXIT_LOGIN_TIMEOUT'},
        @{Exit=1;Error='Login operation timed out synthetic-private';Output='';Driver=$true;Maps='READABLE';Suffix='EXIT_LOGIN_TIMEOUT'},
        @{Exit=1;Error='Query timeout expired synthetic-private';Output='';Driver=$true;Maps='READABLE';Suffix='EXIT_QUERY_TIMEOUT'},
        @{Exit=1;Error='Statement operation timed out synthetic-private';Output='';Driver=$true;Maps='READABLE';Suffix='EXIT_QUERY_TIMEOUT'},
        @{Exit=1;Error='connection timeout synthetic-private';Output='';Driver=$true;Maps='READABLE';Suffix='EXIT_TIMEOUT'},
        @{Exit=1;Error='TCP Provider connection refused synthetic-private';Output='';Driver=$true;Maps='READABLE';Suffix='EXIT_NETWORK'},
        @{Exit=1;Error='synthetic-private-password';Output='';Driver=$true;Maps='READABLE';Suffix='EXIT_UNCLASSIFIED'},
        @{Exit=0;Error='synthetic-private-warning';Output='15.0.4430.1|TRUE';Driver=$true;Maps='READABLE';Suffix='STDERR'},
        @{Exit=0;Error='';Output='synthetic-private-result';Driver=$true;Maps='READABLE';Suffix='SQL_RESULT'},
        @{Exit=0;Error='';Output='15.0.4430.1|TRUE';Driver=$false;Maps='NOT_OBSERVED';Suffix='DRIVER_NOT_OBSERVED'},
        @{Exit=0;Error='';Output='15.0.4430.1|TRUE';Driver=$false;Maps='UNREADABLE';Suffix='DRIVER_MAPS_UNREADABLE'},
        @{Exit=0;Error='';Output='15.0.4430.1|TRUE';Driver=$false;Maps='READABLE';Suffix='DRIVER_PATTERN_MISSING'}
    )){
        $code=Get-TlsLinuxOdbcPositiveFailureCode -ExitCode $case.Exit -Stderr $case.Error -Stdout $case.Output -ExpectedBuild '15.0.4430.1' -DriverObserved $case.Driver -Maps $case.Maps
        [pscustomobject]@{Name=('ODBC diagnostic contains only closed category '+$case.Suffix);Pass=($code -is [string] -and $code -ceq ('TLS_LINUX_ODBC_POSITIVE_'+$case.Suffix))}
    }
    foreach($suffix in @('EXIT_CERTIFICATE','EXIT_LOGIN','EXIT_LOGIN_TIMEOUT','EXIT_QUERY_TIMEOUT','EXIT_TIMEOUT','EXIT_NETWORK','EXIT_UNCLASSIFIED','STDERR','SQL_RESULT','DRIVER_NOT_OBSERVED','DRIVER_MAPS_UNREADABLE','DRIVER_PATTERN_MISSING')){
        $code='TLS_LINUX_ODBC_POSITIVE_'+$suffix
        $record=@{Schema='SqlServerLab.TlsLinuxProbeFailure/1.0';Status='FAIL';Code=(Get-TlsLinuxProbeFailureCode $code)}|ConvertTo-Json -Compress
        $diagnostic=Get-TlsLinuxNativeFailureDiagnostic $record 'synthetic private stderr'
        [pscustomobject]@{Name=('Only fixed ODBC failure category crosses structured boundary '+$suffix);Pass=($diagnostic.Code -ceq $code -and $diagnostic.Source -ceq 'STRUCTURED_PROBE_FAILURE')}
    }
    foreach($category in @('PLATFORM_UNSUPPORTED','ASSEMBLY_UNAVAILABLE','CERTIFICATE','LOGIN','TIMEOUT','NETWORK','SQL_RESULT','UNCLASSIFIED')){
        foreach($stage in @('CONSTRUCT','OPEN','QUERY')){
            $code='TLS_LINUX_CLR_CLIENT_'+$category+'_'+$stage
            $record=@{Schema='SqlServerLab.TlsLinuxProbeFailure/1.0';Status='FAIL';Code=(Get-TlsLinuxProbeFailureCode $code)}|ConvertTo-Json -Compress
            $diagnostic=Get-TlsLinuxNativeFailureDiagnostic $record 'synthetic private formatted stderr'
            [pscustomobject]@{Name=('Structured failure survives independent stderr rendering '+$category+' '+$stage);Pass=($diagnostic.Code -ceq $code -and $diagnostic.Source -ceq 'STRUCTURED_PROBE_FAILURE')}
        }
    }
    $facts=@{OdbcExitCode=1;ChildElapsedMilliseconds=5010L;DriverMaps='READABLE';DriverObserved=$true;
        ActualOdbcAddressFamily='NOT_OBSERVED';LoopbackIpv4='CONNECTED';LoopbackIpv6='REFUSED'}
    $failureV2=@{Schema='SqlServerLab.TlsLinuxProbeFailure/2.0';Status='FAIL';Code='TLS_LINUX_ODBC_POSITIVE_EXIT_LOGIN_TIMEOUT';Facts=$facts}
    foreach($v4 in @('NOT_RESOLVED','CONNECTED','REFUSED','TIMEOUT','ERROR')){foreach($v6 in @('NOT_RESOLVED','CONNECTED','REFUSED','TIMEOUT','ERROR')){
        $facts.LoopbackIpv4=$v4;$facts.LoopbackIpv6=$v6
        $diagnostic=Get-TlsLinuxNativeFailureDiagnostic ($failureV2|ConvertTo-Json -Depth 4 -Compress) ''
        [pscustomobject]@{Name='Closed TCP diagnostics retain failure and never claim the ODBC address family';Pass=($diagnostic.Code -ceq $failureV2.Code -and $diagnostic.Source -ceq 'STRUCTURED_PROBE_FAILURE' -and $diagnostic.Facts.LoopbackIpv4 -ceq $v4 -and $diagnostic.Facts.LoopbackIpv6 -ceq $v6 -and $diagnostic.Facts.ActualOdbcAddressFamily -ceq 'NOT_OBSERVED')}
    }}
    $facts.LoopbackIpv4='CONNECTED';$facts.LoopbackIpv6='REFUSED'
    $jsonV2=$failureV2|ConvertTo-Json -Depth 4 -Compress
    foreach($bad in @('missing-fact','extra-fact','extra-root','wrong-schema','v1-with-facts','pass','clr-code','facts-null','facts-array','exit-string','exit-negative','exit-overflow','elapsed-fraction','elapsed-string','elapsed-negative','elapsed-overflow','driver-string','driver-contradiction','maps-unknown','actual-family-claimed','ipv4-raw','ipv6-raw','case-key','duplicate-fact','duplicate-root')){
        $changed=$jsonV2|ConvertFrom-Json -AsHashtable -DateKind String
        switch($bad){
            missing-fact{$null=$changed.Facts.Remove('OdbcExitCode')}
            extra-fact{$changed.Facts.Secret='synthetic-private-password'}
            extra-root{$changed.Secret='synthetic-private-password'}
            wrong-schema{$changed.Schema='unknown'}
            v1-with-facts{$changed.Schema='SqlServerLab.TlsLinuxProbeFailure/1.0'}
            pass{$changed.Status='PASS'}
            clr-code{$changed.Code='TLS_LINUX_CLR_CHILD_FAILED'}
            facts-null{$changed.Facts=$null}
            facts-array{$changed.Facts=@($changed.Facts)}
            exit-string{$changed.Facts.OdbcExitCode='1'}
            exit-negative{$changed.Facts.OdbcExitCode=-1}
            exit-overflow{$changed.Facts.OdbcExitCode=256}
            elapsed-fraction{$changed.Facts.ChildElapsedMilliseconds=1.5}
            elapsed-string{$changed.Facts.ChildElapsedMilliseconds='5010'}
            elapsed-negative{$changed.Facts.ChildElapsedMilliseconds=-1}
            elapsed-overflow{$changed.Facts.ChildElapsedMilliseconds=90001}
            driver-string{$changed.Facts.DriverObserved='true'}
            driver-contradiction{$changed.Facts.DriverMaps='UNREADABLE'}
            maps-unknown{$changed.Facts.DriverMaps='synthetic-private-path'}
            actual-family-claimed{$changed.Facts.ActualOdbcAddressFamily='IPv4'}
            ipv4-raw{$changed.Facts.LoopbackIpv4='synthetic-private-address'}
            ipv6-raw{$changed.Facts.LoopbackIpv6='synthetic-private-address'}
            case-key{$null=$changed.Facts.Remove('OdbcExitCode');$changed.Facts.odbcExitCode=1}
        }
        $badJson=$changed|ConvertTo-Json -Depth 5 -Compress
        if($bad -ceq 'duplicate-fact'){$badJson=$jsonV2.Replace('"DriverMaps":"READABLE"','"DriverMaps":"READABLE","DriverMaps":"READABLE"')}
        if($bad -ceq 'duplicate-root'){$badJson=$jsonV2.Replace('"Status":"FAIL"','"Status":"FAIL","Status":"FAIL"')}
        $diagnostic=Get-TlsLinuxNativeFailureDiagnostic $badJson 'synthetic-private-stderr'
        [pscustomobject]@{Name=('Malformed TCP diagnostic stays failed and unclassified: '+$bad);Pass=($diagnostic.Code -ceq 'UNCLASSIFIED_NATIVE_EXIT' -and $diagnostic.Source -ceq 'UNCLASSIFIED' -and -not $diagnostic.ContainsKey('Facts'))}
    }
    $notResolved=Get-TlsLinuxLoopbackTcpDiagnostic @([Net.IPAddress]::Loopback) ([Net.Sockets.AddressFamily]::InterNetworkV6)
    [pscustomobject]@{Name='Absent loopback family is reported without any socket creation';Pass=($notResolved -ceq 'NOT_RESOLVED')}
    foreach($case in @(
        @{Text='Login timeout expired synthetic-private';Kind='LOGIN_TIMEOUT'},
        @{Text='Query timeout expired synthetic-private';Kind='QUERY_TIMEOUT'},
        @{Text='certificate verify failed synthetic-private';Kind='CERTIFICATE'},
        @{Text='SSL Provider synthetic-private';Kind='SSL_PROVIDER'},
        @{Text='unsupported protocol synthetic-private';Kind='SSL_PROTOCOL'},
        @{Text='no shared cipher synthetic-private';Kind='SSL_CIPHER'},
        @{Text='unexpected EOF synthetic-private';Kind='SSL_EOF'},
        @{Text='pre-login handshake synthetic-private';Kind='PRELOGIN'},
        @{Text='TCP Provider synthetic-private';Kind='TCP_PROVIDER'},
        @{Text='network-related synthetic-private';Kind='NETWORK_INSTANCE'},
        @{Text='name or service not known synthetic-private';Kind='NAME_RESOLUTION'},
        @{Text='Password: synthetic-private-password';Kind='PASSWORD_PROMPT'},
        @{Text='Login failed synthetic-private';Kind='LOGIN_FAILED'}
    )){
        $kinds=@(Get-TlsLinuxOdbcDiagnosticKinds $case.Text)
        [pscustomobject]@{Name=('ODBC text reduces only to fixed kind '+$case.Kind);Pass=($kinds.Count -eq 1 -and $kinds[0] -ceq $case.Kind)}
    }
    $none=@(Get-TlsLinuxOdbcDiagnosticKinds 'synthetic-private-password')
    [pscustomobject]@{Name='Unknown ODBC text never crosses the classified boundary';Pass=($none.Count -eq 0)}
    $combined=@(Get-TlsLinuxOdbcDiagnosticKinds 'Login timeout expired. TCP Provider: network-related error. SSL Provider: unsupported protocol. Login timeout expired. TCP Provider synthetic-private-password.')
    $expectedKinds=@('LOGIN_TIMEOUT','TCP_PROVIDER','NETWORK_INSTANCE','SSL_PROVIDER','SSL_PROTOCOL')
    [pscustomobject]@{Name='Actual ODBC producer preserves every simultaneous diagnostic kind exactly once';Pass=($combined.Count -eq 5 -and (($combined|Sort-Object -CaseSensitive) -join '|') -ceq (($expectedKinds|Sort-Object -CaseSensitive) -join '|'))}
    foreach($case in @(
        @{Text='TCP Provider: Error code 0x2749';Expected='0x00002749'},
        @{Text='TCP Provider: Error code 0x2749 TCP Provider: Error code 0x00002749';Expected='0x00002749'},
        @{Text='TCP Provider: Error code 0x2749 TCP Provider: Error code 0x2746';Expected='AMBIGUOUS'},
        @{Text='synthetic-private-password 0x2749';Expected='NOT_OBSERVED'},
        @{Text='TCP Provider: Error code 0x123456789';Expected='NOT_OBSERVED'}
    )){
        [pscustomobject]@{Name='Only bounded explicitly labelled TCP provider hex codes are reduced';Pass=((Get-TlsLinuxTcpProviderErrorCode $case.Text) -ceq $case.Expected)}
    }
    $extended=$jsonV2|ConvertFrom-Json -AsHashtable -DateKind String
    $extended.Schema='SqlServerLab.TlsLinuxProbeFailure/2.1'
    $extended.Facts.SqlcmdSha256='A'*64;$extended.Facts.DriverSha256='B'*64
    $extended.Facts.TcpProviderErrorCode='0x00002749'
    $extended.Facts.PasswordEnvironmentPresentAtStart=$true
    $extended.Facts.DiagnosticKinds=@('LOGIN_TIMEOUT','QUERY_TIMEOUT','CERTIFICATE','SSL_PROVIDER','SSL_PROTOCOL','SSL_CIPHER','SSL_EOF','PRELOGIN','TCP_PROVIDER','NETWORK_INSTANCE','NAME_RESOLUTION','PASSWORD_PROMPT','LOGIN_FAILED')
    $extendedJson=$extended|ConvertTo-Json -Depth 5 -Compress
    $diagnostic=Get-TlsLinuxNativeFailureDiagnostic $extendedJson ''
    [pscustomobject]@{Name='Version2.1 retains only fixed client hashes, kinds and numeric code with original failure';Pass=($diagnostic.Code -ceq $extended.Code -and $diagnostic.Facts.SqlcmdSha256 -ceq ('A'*64) -and @($diagnostic.Facts.DiagnosticKinds).Count -eq 13 -and $diagnostic.Facts.TcpProviderErrorCode -ceq '0x00002749')}
    foreach($bad in @('missing-extra','old-version','kinds-string','kind-unknown','kinds-duplicate','kinds-number','kinds-overbound','kind-case','driver-short','driver-null','tool-unobserved','tool-raw','tcp-decimal','tcp-raw','tcp-short','hash-bool','false-driver-hash','true-driver-missing','password-string')){
        $changed=$extendedJson|ConvertFrom-Json -AsHashtable -DateKind String
        switch($bad){
            missing-extra{$null=$changed.Facts.Remove('DiagnosticKinds')}
            old-version{$changed.Schema='SqlServerLab.TlsLinuxProbeFailure/2.0'}
            kinds-string{$changed.Facts.DiagnosticKinds='LOGIN_TIMEOUT'}
            kind-unknown{$changed.Facts.DiagnosticKinds=@('synthetic-private-password')}
            kinds-duplicate{$changed.Facts.DiagnosticKinds=@('LOGIN_TIMEOUT','LOGIN_TIMEOUT')}
            kinds-number{$changed.Facts.DiagnosticKinds=@(1)}
            kinds-overbound{$changed.Facts.DiagnosticKinds=@('LOGIN_TIMEOUT')*14}
            kind-case{$changed.Facts.DiagnosticKinds=@('login_timeout')}
            driver-short{$changed.Facts.DriverSha256='B'*63}
            driver-null{$changed.Facts.DriverSha256=$null}
            tool-unobserved{$changed.Facts.SqlcmdSha256='NOT_OBSERVED'}
            tool-raw{$changed.Facts.SqlcmdSha256='synthetic-private-path'}
            tcp-decimal{$changed.Facts.TcpProviderErrorCode=10057}
            tcp-raw{$changed.Facts.TcpProviderErrorCode='synthetic-private-address'}
            tcp-short{$changed.Facts.TcpProviderErrorCode='0x2749'}
            hash-bool{$changed.Facts.DriverSha256=$true}
            false-driver-hash{$changed.Facts.DriverObserved=$false}
            true-driver-missing{$changed.Facts.DriverSha256='NOT_OBSERVED'}
            password-string{$changed.Facts.PasswordEnvironmentPresentAtStart='synthetic-private-password'}
        }
        $diagnostic=Get-TlsLinuxNativeFailureDiagnostic ($changed|ConvertTo-Json -Depth 5 -Compress) ''
        [pscustomobject]@{Name=('Version2.1 rejects unbounded or contradictory facts: '+$bad);Pass=($diagnostic.Code -ceq 'UNCLASSIFIED_NATIVE_EXIT' -and -not $diagnostic.ContainsKey('Facts'))}
    }
    $extended.Facts.DriverObserved=$false;$extended.Facts.DriverSha256='NOT_OBSERVED';$extended.Facts.DriverMaps='NOT_OBSERVED';$extended.Facts.DiagnosticKinds=@();$extended.Facts.TcpProviderErrorCode='NOT_OBSERVED'
    $diagnostic=Get-TlsLinuxNativeFailureDiagnostic ($extended|ConvertTo-Json -Depth 5 -Compress) ''
    [pscustomobject]@{Name='Absent driver and unclassified text remain explicitly unobserved in failed probe';Pass=($diagnostic.Code -ceq $extended.Code -and $diagnostic.Facts.DriverSha256 -ceq 'NOT_OBSERVED' -and @($diagnostic.Facts.DiagnosticKinds).Count -eq 0)}
    foreach($record in @(
        '{"Schema":"SqlServerLab.TlsLinuxProbeFailure/1.0","Status":"PASS","Code":"TLS_LINUX_CLR_CHILD_FAILED"}',
        '{"Schema":"SqlServerLab.TlsLinuxProbeFailure/1.0","Status":"FAIL","Code":"synthetic-private-password"}',
        '{"Schema":"SqlServerLab.TlsLinuxProbeFailure/1.0","Status":"FAIL","Code":"TLS_LINUX_CLR_CHILD_FAILED","Extra":"synthetic-private-password"}',
        '{"Schema":["wrong","SqlServerLab.TlsLinuxProbeFailure/1.0"],"Status":"FAIL","Code":"TLS_LINUX_CLR_CHILD_FAILED"}',
        '{"Schema":"SqlServerLab.TlsLinuxProbeFailure/1.0","Status":["PASS","FAIL"],"Code":"TLS_LINUX_CLR_CHILD_FAILED"}',
        '{"Schema":"SqlServerLab.TlsLinuxProbeFailure/1.0","Status":"FAIL","Code":["TLS_LINUX_CLR_CHILD_FAILED"]}',
        '{"Schema":"SqlServerLab.TlsLinuxProbeFailure/1.0","Status":"FAIL","Status":"FAIL","Code":"TLS_LINUX_CLR_CHILD_FAILED"}',
        '{"Schema":"SqlServerLab.TlsLinuxProbeFailure/1.0","Status":1,"Code":"TLS_LINUX_CLR_CHILD_FAILED"}',
        'synthetic-private-password',
        ('x'*4097)
    )){
        $diagnostic=Get-TlsLinuxNativeFailureDiagnostic $record 'synthetic private stderr TLS_LINUX_CLR_CHILD_FAILED'
        [pscustomobject]@{Name='Malformed or unbounded structured diagnostic remains failed and unclassified';Pass=($diagnostic.Code -ceq 'UNCLASSIFIED_NATIVE_EXIT' -and $diagnostic.Source -ceq 'UNCLASSIFIED')}
    }
    $isolation='{"State":{"Running":true},"Config":{"User":"10001:0"},"HostConfig":{"ReadonlyRootfs":true,"NetworkMode":"container:SQL_CID","Binds":null,"PortBindings":null,"CapDrop":["ALL"],"SecurityOpt":["no-new-privileges"],"Privileged":false}}'.Replace('SQL_CID',$script:sqlId)
    $ctx=@{SqlId=$script:sqlId;Provider='docker';Commands=1}
    foreach($shape in @('null','empty')){
        $record=$isolation|ConvertFrom-Json
        if($shape -ceq 'empty'){$record.HostConfig.Binds=@();$record.HostConfig.PortBindings=[pscustomobject]@{}}
        $accepted=$true;try{Assert-TlsLinuxClientIsolation $ctx $record}catch{$accepted=$false}
        [pscustomobject]@{Name=('Actual isolation guard accepts '+$shape+' mount/port fields');Pass=$accepted}
    }
    foreach($field in @('Binds','PortBindings')){
        $record=$isolation|ConvertFrom-Json
        if($field -ceq 'Binds'){$record.HostConfig.Binds=@('synthetic:/data:rw')}else{$record.HostConfig.PortBindings=[pscustomobject]@{'1433/tcp'=@([pscustomobject]@{HostPort='14333'})}}
        $rejected=$false;try{Assert-TlsLinuxClientIsolation $ctx $record}catch{$rejected=$true}
        [pscustomobject]@{Name=('Actual isolation guard rejects real '+$field);Pass=$rejected}
    }
    $budgetContext=@{Evidence=$Root;StopFile=(Join-Path $Root '.artifacts/nonexistent-tls-stop');Commands=400;Deadline=[DateTimeOffset]::UtcNow.AddMinutes(1);CleanupDeadline=[DateTimeOffset]::UtcNow.AddMinutes(2)}
    $rejected=$false;try{Enter-TlsLinuxCommandBudget $budgetContext}catch{$rejected=$true}
    [pscustomobject]@{Name='Ordinary calls stop with 50 cleanup dispatches still reserved';Pass=($rejected -and $budgetContext.Commands -eq 400)}
    Enter-TlsLinuxCommandBudget $budgetContext -Cleanup
    [pscustomobject]@{Name='Cleanup consumes original total counter without reset';Pass=($budgetContext.Commands -eq 401)}
    $budgetContext.Commands=450;$rejected=$false;try{Enter-TlsLinuxCommandBudget $budgetContext -Cleanup}catch{$rejected=$true}
    [pscustomobject]@{Name='Cleanup cannot exceed total 450 ceiling';Pass=($rejected -and $budgetContext.Commands -eq 450)}
    $budgetModule=New-Module -ScriptBlock {
        $script:changed=$false;$script:discoveryCalls=0;$script:incarnationCalls=0
        function Get-LabOwnedHostPolicy {param($StateRoot,[switch]$Required) $null=$StateRoot,$Required;@{Pin='original'}}
        function New-LabTlsRuntimeBudget {param($Provider) @{Provider=$Provider;StateRoot='';Commands=0;DeadlineUtc=[datetime]::UtcNow;RuntimeContext=$null}}
        function Get-LabTlsRuntimePin {param($Budget) if($Budget.StateRoot){throw 'SYNTHETIC_POLICY_PROJECTION_IS_NOT_PHYSICAL'};$script:discoveryCalls++;$p=[pscustomobject]@{Provider='podman';Invocation='synthetic-podman';Endpoint='synthetic-original';IdentityPath='synthetic-key';IdentitySha256='synthetic-hash';MachineName='synthetic-machine';IncarnationKey='original-generation';StateRoot=$null};$Budget.RuntimeContext=$p;return $p}
        function Assert-LabTlsPolicyPin {param($Policy,$Context) if($Policy.Pin -cne 'original' -or $Context.Endpoint -cne 'synthetic-original'){throw 'SYNTHETIC_PIN_DRIFT'}}
        function Assert-LabTlsRuntimeBudget {param($Budget,$Commands) $Budget.Commands+=$Commands}
        function Get-LabRunArtifactRuntimeIncarnation {param($Context,$Invocation) if($Context.StateRoot -or $Context.MachineName -cne 'synthetic-machine' -or $Invocation -cne 'synthetic-podman'){throw 'SYNTHETIC_WRONG_PHYSICAL_CONTEXT'};$script:incarnationCalls++;if($script:changed){return 'other-generation'};return 'original-generation'}
    }
    try{
        $bc=@{Module=$budgetModule;Provider='podman';StateRoot='synthetic-owned-root';RuntimePin=$null;Deadline=[DateTimeOffset]::UtcNow.AddMinutes(1);CleanupDeadline=[DateTimeOffset]::UtcNow.AddMinutes(2)}
        New-TlsLinuxPolicyBudget $bc
        [pscustomobject]@{Name='Podman physical pin retains MachineName while effects retain owned root';Pass=($bc.RuntimePin.MachineName -ceq 'synthetic-machine' -and -not $bc.RuntimePin.StateRoot -and $bc.Budget.StateRoot -ceq 'synthetic-owned-root')}
        New-TlsLinuxPolicyBudget $bc -Cleanup
        $counts=& $budgetModule {@($script:discoveryCalls,$script:incarnationCalls)}
        [pscustomobject]@{Name='Cleanup reuses original physical pin without default rediscovery';Pass=($counts[0] -eq 1 -and $counts[1] -eq 1)}
        & $budgetModule {$script:changed=$true}
        $rejected=$false;try{New-TlsLinuxPolicyBudget $bc}catch{$rejected=$true}
        [pscustomobject]@{Name='Changed original incarnation rejects phase before dispatch';Pass=$rejected}
    }finally{Remove-Module $budgetModule -Force}
    $cleanupModule=New-Module -ArgumentList $Root -ScriptBlock {
        param($Source)
        . (Join-Path $Source 'Tests/Common/AuthenticatedTlsLinuxClient.ps1')
        $script:sqlRemoved=0
        function Invoke-TlsLinuxNative {param($Context,$Arguments,[switch]$Cleanup) $null=$Arguments;Enter-TlsLinuxCommandBudget $Context -Cleanup:$Cleanup;return ''}
        function Remove-SqlServerLab {
            param($RunId,$StateRoot,[switch]$Force,[switch]$Confirm)
            $null=$RunId,$StateRoot,$Force,$Confirm
            $script:sqlRemoved++
            @{Status='REMOVED';Errors=0}
        }
    }
    $removalModule=New-Module -ScriptBlock {
        function Remove-LabOwnedHostFailedContainer {
            param($StateRoot,$Intent)
            $null=$StateRoot,$Intent
        }
    }
    try{
        $cc=@{Module=$removalModule;StateRoot='synthetic-root';StopFile=(Join-Path $Root '.artifacts/nonexistent-tls-stop');Commands=400;Deadline=[DateTimeOffset]::UtcNow.AddMinutes(1);CleanupDeadline=[DateTimeOffset]::UtcNow.AddMinutes(2);Run=@{RunId='synthetic-run';ScopeId='synthetic-scope'};ClientIntent=@{IntentId='synthetic-intent'};ClientId='synthetic-client';Removed=$false}
        & $cleanupModule {param($C) Remove-TlsLinuxOwnedFixture $C} $cc
        $count=& $cleanupModule {$script:sqlRemoved}
        [pscustomobject]@{Name='Actual cleanup path reaches SQL removal after ordinary call exhaustion';Pass=($cc.Removed -and -not $cc.ClientIntent -and $count -eq 1 -and $cc.Commands -gt 400 -and $cc.Commands -le 450)}
    }finally{Remove-Module $cleanupModule -Force;Remove-Module $removalModule -Force}
    }
}
try{$checks=@(& $module {& $script:FixtureChecks});foreach($check in $checks){Add-CheckResult $check.Name $check.Pass}}
finally{Remove-Module $module -Force}
if(-not $checks.Count){throw 'TLS_LINUX_FIXTURE_CHECKS_NOT_EXECUTED'}
. (Join-Path $repo 'Tests/Common/AuthenticatedTlsLinuxClient.ps1')
$temp=Join-Path $repo ('.artifacts/test-runs/tls-linux-supervisor-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temp
try{
    $transport=New-Module -ArgumentList (Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})) -ScriptBlock {
        param($Invocation)
        $script:invocation=$Invocation
        function Assert-LabTlsRuntimeBudget {param($Budget,$Commands) $null=$Budget,$Commands}
        function New-LabTlsRuntimeProcessInfo {
            param($Arguments,$Budget)
            $null=$Budget
            if(($Arguments -join ' ') -cnotin @('synthetic-echo','synthetic-empty','synthetic-failure')){throw 'SYNTHETIC_NO_PROVIDER_TRIPWIRE'}
            $s=[Diagnostics.ProcessStartInfo]::new($script:invocation);$s.UseShellExecute=$false;$s.CreateNoWindow=$true
            $s.RedirectStandardInput=$true;$s.RedirectStandardOutput=$true;$s.RedirectStandardError=$true
            $command=switch($Arguments[0]){
                'synthetic-echo'{'[Console]::Out.Write([Console]::In.ReadToEnd())'}
                'synthetic-empty'{'$null=[Console]::In.ReadToEnd()'}
                'synthetic-failure'{'$null=[Console]::In.ReadToEnd();[Console]::Out.Write(''{"Schema":"SqlServerLab.TlsLinuxProbeFailure/1.0","Status":"FAIL","Code":"TLS_LINUX_CLR_CLIENT_CERTIFICATE_OPEN"}'');[Console]::Error.Write("synthetic-private-rendered-error");exit 17'}
            }
            foreach($a in @('-NoLogo','-NoProfile','-Command',$command)){$s.ArgumentList.Add($a)}
            return $s
        }
        function Get-LabTlsWindowsProcessFacts {@{UserSid='synthetic-no-real-ca'}}
        function ConvertTo-LabTlsRegistryWriterBytes {param($Data) $Data|ConvertTo-Json -Depth 8 -Compress}
        function Write-LabTlsCaPrivateFile {param($Path,$Owner,$Data) $null=$Owner;[IO.File]::WriteAllText($Path,$Data)}
    }
    try{
        $tc=@{Module=$transport;Budget=@{};Commands=0;Deadline=[DateTimeOffset]::UtcNow.AddMinutes(2);CleanupDeadline=[DateTimeOffset]::UtcNow.AddMinutes(3);StopFile=(Join-Path $temp 'nonexistent-stop');Evidence=$temp}
        $value=Invoke-TlsLinuxNative $tc @('synthetic-echo') -InputText 'aGVsbG8='
        Add-CheckResult 'Actual async stdin transport returns only the stdout string' ($value -is [string] -and $value -ceq 'aGVsbG8=')
        Add-CheckResult 'Actual transported base64 decodes without task result contamination' ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value)) -ceq 'hello')
        $empty=Invoke-TlsLinuxNative $tc @('synthetic-empty') -Cleanup
        Add-CheckResult 'Actual empty stdout remains false for cleanup absence guards' ($empty -is [string] -and $empty.Length -eq 0 -and -not [bool]$empty)
        $rejected=$false
        try{$null=Invoke-TlsLinuxNative $tc @('synthetic-failure') -InputText 'synthetic-private-input'}catch{$rejected=$_.Exception.Message -ceq 'TLS_LINUX_NATIVE_COMMAND_FAILED:TLS_LINUX_CLR_CLIENT_CERTIFICATE_OPEN'}
        $proofPath=Join-Path $temp ('native-command-failure-'+$tc.Commands+'.private.json')
        $proofText=Get-Content -LiteralPath $proofPath -Raw;$proof=$proofText|ConvertFrom-Json
        Add-CheckResult 'Actual failed child uses structured stdout independently of stderr formatting' ($rejected -and $proof.ExitCode -eq 17 -and $proof.DiagnosticSource -ceq 'STRUCTURED_PROBE_FAILURE')
        Add-CheckResult 'Actual failed child proof excludes input and raw stderr' (-not $proofText.Contains('synthetic-private-input') -and -not $proofText.Contains('synthetic-private-rendered-error'))
    }finally{Remove-Module $transport -Force}
    $invalidPackage=Join-Path $temp 'invalid-package.tar.gz';[IO.File]::WriteAllText($invalidPackage,'synthetic')
    $rejected=$false;try{Assert-TlsLinuxPowerShellPackage $invalidPackage}catch{$rejected=$_.Exception.Message -ceq 'TLS_LINUX_PINNED_POWERSHELL_PACKAGE_INVALID'}
    Add-CheckResult 'Package guard rejects an actual invalid local file' $rejected
    $code='TLS_LINUX_PINNED_POWERSHELL_PACKAGE_INVALID'
    Add-CheckResult 'Worker failure classification retains only fixed known code' ((Get-TlsLinuxWorkerFailureCode ('synthetic-prefix '+$code+' synthetic-suffix')) -ceq $code)
    Add-CheckResult 'Repeated same worker code remains one classification' ((Get-TlsLinuxWorkerFailureCode ($code+' '+$code)) -ceq $code)
    Add-CheckResult 'Unknown worker text is never persisted as a diagnostic value' ((Get-TlsLinuxWorkerFailureCode 'synthetic private detail TLS_LINUX_UNRECOGNIZED_VALUE') -ceq 'UNCLASSIFIED_PRIVATE_HASH_ONLY')
    Add-CheckResult 'Conflicting worker codes remain unclassified' ((Get-TlsLinuxWorkerFailureCode ($code+' TLS_LINUX_READINESS_BLOCKED')) -ceq 'UNCLASSIFIED_PRIVATE_HASH_ONLY')
    if($IsWindows){
        Assert-TlsLinuxNoRecoveryCustody
        $previousCustody=Get-Variable -Name SqlServerLabTlsLinuxRecoveryCustody -Scope Global -ErrorAction SilentlyContinue
        try{
            $global:SqlServerLabTlsLinuxRecoveryCustody=@(@{Synthetic=$true})
            $rejected=$false;try{Assert-TlsLinuxNoRecoveryCustody}catch{$rejected=$true}
            Add-CheckResult 'Retained recovery custody blocks same-process reentry' $rejected
        }finally{
            if($previousCustody){Set-Variable -Name SqlServerLabTlsLinuxRecoveryCustody -Scope Global -Value $previousCustody.Value}
            else{Remove-Variable -Name SqlServerLabTlsLinuxRecoveryCustody -Scope Global}
        }
        $published=Join-Path $temp 'published.ready';$ticks=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks
        Publish-TlsLinuxWorkerReady $published $PID $ticks
        $readyRecord=Get-Content -LiteralPath $published -Raw|ConvertFrom-Json
        Add-CheckResult 'Atomic Ready publishes complete bound bytes and removes pending name' ($readyRecord.WorkerId -eq $PID -and $readyRecord.WorkerStartTicks -eq $ticks -and -not(Test-Path -LiteralPath ($published+'.pending')))
        $before=(Get-FileHash -LiteralPath $published).Hash;$rejected=$false
        try{Publish-TlsLinuxWorkerReady $published ($PID+1) $ticks}catch{$rejected=$true}
        Add-CheckResult 'Atomic Ready refuses replacement without changing original bytes' ($rejected -and (Get-FileHash -LiteralPath $published).Hash -ceq $before)
        foreach($mode in @('held-once','released','wrong-pid','wrong-start','closed','missing-ticket')){
            $case=Join-Path $temp $mode;$null=New-Item -ItemType Directory -Path $case
            $ticketPath=Join-Path $case 'ticket';[IO.File]::WriteAllText($ticketPath,'synthetic')
            $ticket=@{ReadyFile=(Join-Path $case 'custody-assigned');ClaimFile=(Join-Path $case 'worker-claimed');ClosedFile=(Join-Path $case 'custody-closed')}
            $ticks=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks
            @{WorkerId=$(if($mode -ceq 'wrong-pid'){$PID+1}else{$PID});WorkerStartTicks=$(if($mode -ceq 'wrong-start'){$ticks+1}else{$ticks})}|ConvertTo-Json|Set-Content -LiteralPath $ticket.ReadyFile
            $ticketLock=$null
            try{
                if($mode -notin @('released','missing-ticket')){$ticketLock=[IO.File]::Open($ticketPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}
                if($mode -ceq 'missing-ticket'){Remove-Item -LiteralPath $ticketPath}
                if($mode -ceq 'closed'){[IO.File]::WriteAllText($ticket.ClosedFile,'closed')}
                $accepted=$true;try{Enter-TlsLinuxWorkerCustody $ticketPath $ticket $PID $ticks}catch{$accepted=$false}
                Add-CheckResult ('Actual file-lock and one-worker admission '+$mode) ($accepted -eq ($mode -ceq 'held-once'))
                if($mode -ceq 'held-once'){
                    $accepted=$true;try{Enter-TlsLinuxWorkerCustody $ticketPath $ticket $PID $ticks}catch{$accepted=$false}
                    Add-CheckResult 'Actual second claim rejected while parent ticket remains held' (-not $accepted)
                }
            }finally{if($ticketLock){$ticketLock.Dispose()}}
        }
    }
    $child=Join-Path $temp 'child.ps1'
    [IO.File]::WriteAllText($child,'param([string]$StopFile,[switch]$IgnoreStop); if($IgnoreStop){Start-Sleep -Seconds 60}else{while(-not(Test-Path -LiteralPath $StopFile)){Start-Sleep -Milliseconds 20}}')
    foreach($mode in @('cooperative','hard-stop')){
        $stop=Join-Path $temp ($mode+'.stop');$job=$null
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})));$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($arg in @('-NoLogo','-NoProfile','-File',$child,'-StopFile',$stop)){$start.ArgumentList.Add($arg)}
        if($mode -ceq 'hard-stop'){$start.ArgumentList.Add('-IgnoreStop')}
        if($IsWindows){$job=New-TlsLinuxWorkerJob}
        try{
            $now=[DateTimeOffset]::UtcNow
            $result=Invoke-TlsLinuxSupervisedProcess -StartInfo $start -StopAt $now.AddSeconds(1) -Deadline $now.AddSeconds(10) -StopFile $stop -WorkerJob $job -ReadyFile (Join-Path $temp ($mode+'.ready'))
            Add-CheckResult ('Actual subprocess '+$mode+' custody') ($result.ExitConfirmed -and (-not $IsWindows -or $result.JobEmptyConfirmed) -and $result.StopRequested -and $result.HardStopped -eq ($mode -ceq 'hard-stop') -and ($mode -ceq 'hard-stop' -or $result.ExitCode -eq 0) -and $result.ElapsedSeconds -lt 16)
        }finally{if($job){$job.Dispose()}}
    }
    if($IsWindows){
        $treeChild=Join-Path $temp 'tree-child.ps1'
        [IO.File]::WriteAllText($treeChild,@'
param([string]$Ready,[string]$Identity,[switch]$ExitParent)
while(-not(Test-Path -LiteralPath $Ready)){Start-Sleep -Milliseconds 10}
$assigned=Get-Content -LiteralPath $Ready -Raw|ConvertFrom-Json
if($assigned.WorkerId -ne $PID -or $assigned.WorkerStartTicks -ne [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks){throw 'SYNTHETIC_WORKER_READY_INVALID'}
$start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
$start.UseShellExecute=$false;$start.CreateNoWindow=$true
foreach($arg in @('-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 60')){$start.ArgumentList.Add($arg)}
$descendant=[Diagnostics.Process]::Start($start)
@{Id=$descendant.Id;StartTicks=$descendant.StartTime.ToUniversalTime().Ticks}|ConvertTo-Json|Set-Content -LiteralPath $Identity
if(-not $ExitParent){Start-Sleep -Seconds 60}
'@)
        foreach($mode in @('orphan-descendant','hard-stop-descendant')){
            $ready=Join-Path $temp ($mode+'.ready');$identity=Join-Path $temp ($mode+'.identity');$stop=Join-Path $temp ($mode+'.stop')
            $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'));$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            foreach($arg in @('-NoLogo','-NoProfile','-File',$treeChild,'-Ready',$ready,'-Identity',$identity)){$start.ArgumentList.Add($arg)}
            if($mode -ceq 'orphan-descendant'){$start.ArgumentList.Add('-ExitParent')}
            $job=New-TlsLinuxWorkerJob
            try{
                $now=[DateTimeOffset]::UtcNow
                $result=Invoke-TlsLinuxSupervisedProcess -StartInfo $start -StopAt $now.AddSeconds(4) -Deadline $now.AddSeconds(10) -StopFile $stop -WorkerJob $job -ReadyFile $ready
                $record=Get-Content -LiteralPath $identity -Raw|ConvertFrom-Json
                $remaining=Get-Process -Id $record.Id -ErrorAction SilentlyContinue
                $sameAlive=$remaining -and $remaining.StartTime.ToUniversalTime().Ticks -eq $record.StartTicks -and -not $remaining.HasExited
                Add-CheckResult ('Actual whole Windows job empty after '+$mode) ($result.ExitConfirmed -and $result.JobEmptyConfirmed -and -not $sameAlive -and $result.HardStopped -eq ($mode -ceq 'hard-stop-descendant'))
            }finally{$job.Dispose()}
        }
    }
}finally{
    $full=[IO.Path]::GetFullPath($temp);$parent=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/test-runs'))
    if([IO.Path]::GetDirectoryName($full) -cne $parent -or (Get-Item -LiteralPath $full).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'TLS_LINUX_SYNTHETIC_CLEANUP_SCOPE_INVALID'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
Write-Host "TLS Linux Client: $passed PASS / $($failures.Count) FAIL"
if($failures.Count){exit 1}
