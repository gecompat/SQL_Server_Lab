#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference='Stop'
$passed=0;$failures=[Collections.Generic.List[string]]::new()
. (Join-Path $PSScriptRoot '../../Common/CheckResult.ps1')
. (Join-Path $RepoRoot 'Private/AuthenticatedTlsHyperVSqlConsumer.ps1')
# Run actual host control flow. Native leaves never execute a guest block.
function Assert-LabTlsRegistryWriterBinding {}
function Get-HyperVLabWorkflowRun {
    [pscustomobject]@{Run=[pscustomobject]@{runId=$session.Ids.RunId;scopeId=$session.Ids.ScopeId};Instance=[pscustomobject]@{vmName='synthetic';sqlCompletion=$null;imageArtifactId='synthetic';labNetwork=[pscustomobject]@{address='synthetic';hostAddress='synthetic'};windowsActivationIntent=[pscustomobject]@{Strategy='VerifyOnly';EgressPolicy='Denied'}};RunDirectory='synthetic';Connection=[pscustomobject]@{}}
}
function Assert-HyperVLabSqlVmBinding {[pscustomobject]@{VM=[pscustomobject]@{State='Running'}}}
function Assert-HyperVLabSqlExistingNetwork {}
function Get-HyperVImageArtifact {[pscustomobject]@{artifactState='SQL_PREPARED_SEALED';sql=[pscustomobject]@{version='2025';build='2025.0170.1000.07';edition='EnterpriseDeveloper'}}}
function ConvertTo-HyperVSqlMediaEdition {'Enterprise'}
function Get-HyperVSqlInstallationMediaCandidates {[pscustomobject]@{State='READY';SqlVersion='2025';MediaEdition='Enterprise';MediaId='synthetic'}}
function Resolve-HyperVSqlInstallationMedia {[pscustomobject]@{HashStatus='SIDECAR_READY';IsoPath='synthetic';ExpectedSha256=('a'*64)}}
function Get-FileHash {[pscustomobject]@{Hash=('a'*64)}}
function Get-VMDvdDrive {}
function Add-VMDvdDrive {$script:effects.Add('DVD')}
function Save-LabHyperVSqlSaPassword {}
function Write-LabTlsSqlConsumerStage($Session,$Phase){$script:stages.Add($Phase)}
function Write-LabTlsSqlConsumerEvidence($Session,$Name,$Value){$script:evidence.Add($Name);$script:proofs[$Name]=$Value}
function Write-LabArtifactJsonAtomic {$script:effects.Add('STATE')}
function Save-HyperVLabSqlInstanceReceipt {}
function Start-Sleep {}
function Test-Path {param($LiteralPath)if($LiteralPath -ceq 'synthetic-cancel'){return $script:cancelled};throw 'FIXTURE_UNEXPECTED_PATH_READ'}
function Invoke-HyperVPowerShellDirect {
    param($ScriptBlock,$ArgumentList,$VMName,$ExpectedRunId,$ExpectedScopeId,$ExpectedVmId,$Credential,[switch]$NoRetry,$TimeoutSeconds)
    if(-not $NoRetry -or $ExpectedVmId -ne [guid]$session.Ids.VmId){throw 'FIXTURE_TRANSPORT_BINDING_LOST'}
    if($ScriptBlock.ToString().Contains('Win32Shutdown')){
        $script:effects.Add('REBOOT')
        if($scenario -ceq 'LostRebootReply'){throw 'synthetic lost reboot reply'}
        return [pscustomobject]@{Accepted=$true}
    }
    if($ScriptBlock.ToString().Contains('Assert-InstallerIdle')){
        $script:effects.Add('SETUP')
        if($scenario -cin @('LostSetupReply','ParentTimeout','InstallerUnknown')){throw $scenario}
        if($scenario -ceq 'CancelAfterSetup'){$script:cancelled=$true}
        return [pscustomobject]@{operationId=$(if($scenario -ceq 'WrongReceipt'){'rebound'}else{$session.Ids.OperationId});runId=$session.Ids.RunId;scopeId=$session.Ids.ScopeId;exitCode=0;installerIdle=$true;summarySha256=('A'*64);bootTimeBeforeRestart='2000-01-01T00:00:00Z'}
    }
    if($ScriptBlock.ToString().Contains('POST_SETUP')){$script:effects.Add('POST_SETUP');return [pscustomobject]@{Success=$true;ConsumerEnded=$true;OnlineSystemDatabases=4;Build='17.0.1000.7';inspectedAt='2000-01-02T00:00:00Z'}}
    if($scenario -ceq 'OldBoot'){return [pscustomobject]@{InstallerIdle=$true;Boot='2000-01-01T00:00:00Z'}}
    return [pscustomobject]@{InstallerIdle=$true;Boot='2000-01-02T00:00:00Z'}
}
$session=[pscustomobject]@{Ids=@{RunId='11111111-1111-4111-8111-111111111111';ScopeId='22222222-2222-4222-8222-222222222222';VmId='33333333-3333-4333-8333-333333333333';OperationId='44444444-4444-4444-8444-444444444444';RootDigest=('a'*64)};Binding=[pscustomobject]@{Root=[pscustomobject]@{DataRoot='synthetic'};ActorDigest=('b'*64)}}
$password=[Security.SecureString]::new();$password.AppendChar([char]33);$password.MakeReadOnly()
try{
    foreach($scenario in @('LostSetupReply','ParentTimeout','InstallerUnknown','WrongReceipt','OldBoot','LostRebootReply','Success','CancelAfterSetup')){
        $script:cancelled=$false
        $script:effects=[Collections.Generic.List[string]]::new();$script:stages=[Collections.Generic.List[string]]::new();$script:evidence=[Collections.Generic.List[string]]::new();$script:proofs=@{};$failed=$false
        try{$null=Invoke-LabTlsHyperVSqlCompletion -Session $session -Credential ([pscredential]::new('synthetic',$password)) -SqlSaPassword $password -MediaRoot 'synthetic' -BootTimeoutSeconds 1 -CancellationPath 'synthetic-cancel'}catch{$failed=$true}
        $success=$scenario -cin @('LostRebootReply','Success')
        Add-CheckResult ('TLS-HVC '+$scenario+' obeys success/recovery boundary') ($failed -ne $success -and @($effects|Where-Object {$_ -ceq 'SETUP'}).Count -eq 1 -and @($effects|Where-Object {$_ -ceq 'REBOOT'}).Count -le 1)
        if($success){
            Add-CheckResult ('TLS-HVC '+$scenario+' proves new epoch before post-setup') ($evidence.Contains('consumer-end.json') -and $proofs['consumer-end.json'].OldEpochEnded -and $effects.Contains('POST_SETUP') -and $stages.Contains('RECOVERY_REQUIRED'))
        }else{
            Add-CheckResult ('TLS-HVC '+$scenario+' preserves without followup or end claim') (-not $evidence.Contains('consumer-end.json') -and -not $effects.Contains('POST_SETUP') -and $stages.Contains('RECOVERY_REQUIRED'))
        }
    }
    $script:effects.Clear();$script:stages.Clear();$failed=$false
    try{$null=Invoke-LabTlsHyperVSqlCompletion -Session $session -Credential ([pscredential]::new('synthetic',$password)) -SqlSaPassword $password -MediaRoot 'synthetic' -DeadlineUtc ([datetimeoffset]::UtcNow.AddSeconds(-1))}catch{$failed=$true}
    Add-CheckResult 'TLS-HVC exhausted budget admits no dispatch or guest effect' ($failed -and $effects.Count -eq 0 -and $stages.Count -eq 0)
    . (Join-Path $RepoRoot 'Tests/Common/AuthenticatedTlsHyperVAcceptance.ps1')
    . (Join-Path $RepoRoot 'Private/AuthenticatedTlsHyperVLeaf.ps1')
    $csrAst=(Get-LabTlsHyperVCsrGuestScript).Ast
    $creation=$csrAst.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$creationSettings'},$true)
    $template=$csrAst.Find({param($n)$n -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $n.Value.Contains('[NewRequest]')},$true)
    $ExpectedMachineName='TEST-HVSQL';$Container='SQLServerLab-CSP-11111111-1111-4111-8111-111111111111';$Address='192.0.2.10'
    foreach($CreateKey in @($false,$true)){
        . ([scriptblock]::Create($creation.Extent.Text))
        $inf=& ([scriptblock]::Create($template.Extent.Text))
        $correct=if($CreateKey){$inf -match '(?m)^KeyLength=3072\s*$' -and $inf -match '(?m)^Exportable=FALSE\s*$' -and $inf -match '(?m)^UseExistingKeySet=FALSE\s*$'}else{$inf -notmatch '(?m)^(?:KeyLength|Exportable)=' -and $inf -match '(?m)^UseExistingKeySet=TRUE\s*$'}
        Add-CheckResult ('TLS-HVC actual INF keeps key creation properties exclusive to new key '+$CreateKey) $correct
    }
    $inventoryRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-tls-inventory-'+[guid]::NewGuid().ToString('N'))
    $encoding=[Console]::OutputEncoding
    try{
        $null=New-Item -ItemType Directory -Path $inventoryRoot
        & git init --quiet $inventoryRoot
        if($LASTEXITCODE -ne 0){throw 'FIXTURE_GIT_INIT_FAILED'}
        [IO.File]::WriteAllText((Join-Path $inventoryRoot 'größer.ps1'),'# synthetic')
        [Console]::OutputEncoding=[Text.Encoding]::ASCII
        $actualInventory=@(Get-TlsHyperVSourceInventory $inventoryRoot)
        Add-CheckResult 'TLS-HVC source inventory decodes actual git UTF8 independently of console encoding' ($actualInventory.Count -eq 1 -and $actualInventory[0] -ceq 'größer.ps1')
    }finally{
        [Console]::OutputEncoding=$encoding
        $absolute=[IO.Path]::GetFullPath($inventoryRoot);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $absolute.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -notmatch '^sql-lab-tls-inventory-[0-9a-f]{32}$'){throw 'FIXTURE_INVENTORY_CLEANUP_BOUNDARY_INVALID'}
        if([IO.Directory]::Exists($absolute)){Remove-Item -LiteralPath $absolute -Recurse -Force}
    }
    foreach($sample in @(@('certificate chain was issued by an authority that is not trusted','UNTRUSTED'),@('SSL Provider: The target principal name is incorrect','WRONG_SAN'),@('certificate has expired','EXPIRED'),@('TCP connection refused','OTHER'),@('Login failed','OTHER'),@('Login failed. The password has expired.','OTHER'),@('SQL login rejected: account is not trusted.','OTHER'),@('TLS SSL Provider: 0x80090325','UNTRUSTED'),@('SSL Provider: 0x80090322','WRONG_SAN'),@('SSL Provider: 0x80090328','EXPIRED'))){Add-CheckResult ('TLS-HVC distinguishes certificate failure from unrelated failure '+$sample[1]) ((Get-TlsHyperVFailureCategory $sample[0]) -ceq $sample[1])}
    foreach($fault in @('LaunchWrite','MissingResult','WrongBinding','ResultWrite','Success')){
        $script:supervisorWrites=[Collections.Generic.List[string]]::new();$script:disposed=$false
        $child=[pscustomobject]@{Id=42;StartTime=[datetime]::UtcNow;ExitCode=0;StandardOutput=[IO.StringReader]::new('');StandardError=[IO.StringReader]::new('')}
        $child|Add-Member ScriptMethod Start {$true};$child|Add-Member ScriptMethod WaitForExit {param($ms)$true};$child|Add-Member ScriptMethod Dispose {$script:disposed=$true}
        $failed=$false
        try{
            Invoke-TlsHyperVSupervisedProcess $child ([datetimeoffset]::UtcNow.AddMinutes(1)) 'synthetic' ('a'*64) {
                param($name,$value)
                if(($fault -ceq 'LaunchWrite' -and $name -ceq 'worker-launch.private.json') -or ($fault -ceq 'ResultWrite' -and $name -ceq 'supervisor-result.private.json' -and $value.Status -ceq 'PASS')){throw 'synthetic write failure'}
                $script:supervisorWrites.Add($name+':'+$value.Status)
            } {
                if($fault -ceq 'MissingResult'){throw 'synthetic missing result'}
                [pscustomobject]@{ContractVersion='SqlServerLab.TlsHyperVResult/0.1';OperationId=$(if($fault -ceq 'WrongBinding'){'rebound'}else{'synthetic'});SourceDigest=('a'*64);WorkerPid=42;Status='PASS';Phase='COMPLETED';NativeEndKnown=$true;Cases=@(1..9|ForEach-Object {@{Results=@('a','b')}})}
            }
        }catch{$failed=$true}
        $success=$fault -ceq 'Success'
        Add-CheckResult ('TLS-HVC supervisor '+$fault+' requires durable bound result') ($failed -ne $success -and $script:disposed -and ($success -or ($script:supervisorWrites.Contains('cancel.private.json:') -and $script:supervisorWrites.Contains('supervisor-result.private.json:RECOVERY_REQUIRED'))))
    }
    if($PSVersionTable.PSVersion -ge [version]'7.5'){
    $crypto=New-Module -ScriptBlock {param($root)foreach($file in @('AuthenticatedTlsRequest','AuthenticatedTlsCaCandidate','AuthenticatedTlsLeafCsr')){. (Join-Path $root "Private/$file.ps1")}} -ArgumentList $RepoRoot
    $rsa=[Security.Cryptography.RSA]::Create(3072);$leaf=$null
    try{
        $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=TEST-HVSQL',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new();$san.AddIpAddress([Net.IPAddress]::Parse('192.0.2.10'));$request.CertificateExtensions.Add($san.Build($false))
        $csr=$request.CreateSigningRequest()
        $der=New-TlsHyperVUntrustedLeaf $csr '192.0.2.10' 'TEST-HVSQL' $crypto
        $leaf=[Security.Cryptography.X509Certificates.X509Certificate2]::new($der)
        Add-CheckResult 'TLS-HVC untrusted case builds actual public RSA leaf with isolated issuer' (-not $leaf.HasPrivateKey -and $leaf.Subject -ceq 'CN=TEST-HVSQL' -and $leaf.Issuer -ceq 'CN=SqlServerLab HyperV Acceptance Untrusted CA' -and $leaf.Extensions.Count -eq 4)
        $csr[$csr.Length-1]=$csr[$csr.Length-1] -bxor 1
        $blocked=$false;try{$null=New-TlsHyperVUntrustedLeaf $csr '192.0.2.10' 'TEST-HVSQL' $crypto}catch{$blocked=$true}
        Add-CheckResult 'TLS-HVC negative helper still rejects actual broken proof of possession' $blocked
    }finally{if($leaf){$leaf.Dispose()};$rsa.Dispose();Remove-Module $crypto -Force}
    }else{Write-Host 'TLS-HVC cryptographic cases: NOT_EXECUTED (requires PowerShell 7.5); host boundary cases executed.'}
    Write-Host "TLS HyperV SQL Consumer Boundary: $passed PASS, $($failures.Count) FAIL"
    if($failures.Count){throw 'TLS_HYPERV_SQL_CONSUMER_BOUNDARY_CHECKS_FAILED'}
}finally{$password.Dispose()}
