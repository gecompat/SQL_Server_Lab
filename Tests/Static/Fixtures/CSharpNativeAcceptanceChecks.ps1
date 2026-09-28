# Dot-sourced by the Windows external-runtime contract suite. No VM or SQL access.
. (Join-Path $repoRoot 'Tests/Common/CSharpNativeAcceptance.ps1')
$dispatch=[pscustomobject]@{EventName='workflow_dispatch';Ref='refs/heads/main';Repository='gecompat/SQL_Server_Lab';EventRepository='gecompat/SQL_Server_Lab';ExpectedCommit=('a'*40);CheckoutCommit=('a'*40);Dirty=$false;ArtifactId=('hyperv-os-sealed-'+('b'*64))}
$caught='';try{Assert-CSharpNativeDispatch $dispatch}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp native: manueller sauberer Main-Checkout akzeptiert' -Success (-not $caught)
foreach($case in @(
    @{Property='EventName';Value='pull_request'},@{Property='Ref';Value='refs/heads/feature'},
    @{Property='Repository';Value='synthetic/fork'},@{Property='EventRepository';Value='synthetic/fork'},
    @{Property='ExpectedCommit';Value='bad'},@{Property='CheckoutCommit';Value=('c'*40)},
    @{Property='Dirty';Value=$true},@{Property='ArtifactId';Value=('hyperv-sql-prepared-sealed-'+('b'*64))})){
    $copy=$dispatch.PSObject.Copy();$copy.($case.Property)=$case.Value
    $caught='';try{Assert-CSharpNativeDispatch $copy}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name ('CSharp native: Dispatch sperrt '+$case.Property) -Success ($caught -like 'CSHARP_NATIVE_*')
}
$nativeRoot=Join-Path $temporaryRoot 'native-tests';$null=New-Item -ItemType Directory -Path $nativeRoot
$syntheticFile=Join-Path $nativeRoot 'payload';[IO.File]::WriteAllText($syntheticFile,'synthetic')
$hash=(Get-FileHash $syntheticFile).Hash.ToLowerInvariant()
$caught='';try{Assert-CSharpNativeFile $syntheticFile $hash}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp native: gebundene Datei akzeptiert' -Success (-not $caught)
$caught='';try{Assert-CSharpNativeFile $syntheticFile ('0'*64)}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp native: Hashdrift vor Verwendung abgewiesen' -Success ($caught -ceq 'CSHARP_NATIVE_FILE_HASH')
$caught='';try{Assert-CSharpNativeFile $syntheticFile $hash -MaximumBytes 1}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp native: Größenlimit vor Verwendung' -Success ($caught -ceq 'CSHARP_NATIVE_FILE_SIZE')
$syntheticWorker=Join-Path $nativeRoot 'worker.ps1'
'param($PlanPath) Write-Output "synthetic stdout"; [Console]::Error.WriteLine("synthetic stderr"); exit 7'|Set-Content $syntheticWorker
$child=Invoke-CSharpNativeChild -Worker $syntheticWorker -PlanPath $syntheticFile -OutputRoot $nativeRoot -TimeoutSeconds 10
Add-CheckResult -Name 'CSharp native: echter Kindprozess bewahrt Exitcode und lokale Logs' -Success ($child.Terminated -and $child.ExitCode -eq 7 -and ([IO.File]::ReadAllText((Join-Path $nativeRoot 'worker.stderr.log'))) -match 'synthetic stderr')
'param($PlanPath) Write-Output "synthetic before timeout"; Start-Sleep -Seconds 30'|Set-Content $syntheticWorker
$timeoutRoot=Join-Path $nativeRoot 'timeout-output';$null=[IO.Directory]::CreateDirectory($timeoutRoot)
$caught='';$terminated=$false
try{Invoke-CSharpNativeChild -Worker $syntheticWorker -PlanPath $syntheticFile -OutputRoot $timeoutRoot -TimeoutSeconds 1}catch{$caught=$_.Exception.Message;$terminated=$_.Exception.Data['CSharpChildTerminated']}
Add-CheckResult -Name 'CSharp native: echter Timeout bestätigt Kindprozessende vor Cleanup' -Success ($caught -ceq 'CSHARP_NATIVE_CHILD_TIMEOUT' -and $terminated -and ([IO.File]::ReadAllText((Join-Path $timeoutRoot 'worker.stdout.log'))) -match 'synthetic before timeout')
$nativeModule=New-Module -ScriptBlock {
    $script:Removed=$false;$script:Foreign=$false
    $script:Owned=[pscustomobject]@{runId='11111111-1111-1111-1111-111111111111';scopeId='22222222-2222-2222-2222-222222222222';metadata=@{workflowOperationId='synthetic-operation';workflowKind='hyperv-lab'}}
    function Get-LabOperationOwnedRun {param($OperationId,$StateRoot) $script:Owned}
    function Get-LabProviderSubRuns {param($RunId,$StateRoot) [pscustomobject]@{provider='hyperv'}}
    function Get-CleanupPlan {param($RunDir) [pscustomobject]@{runId=$script:Owned.runId;scopeId=$script:Owned.scopeId;steps=@([pscustomobject]@{provider='hyperv';resourceType='vm';resourceId='synthetic-own-vm'})}}
    function Get-VM {param($Name) if($script:Foreign){[pscustomobject]@{Id='33333333-3333-3333-3333-333333333333'}}}
    function Get-HyperVManagedVM {param($VMName,$ExpectedRunId,$ExpectedScopeId) throw 'CSHARP_NATIVE_FOREIGN_VM'}
    function Remove-SqlServerLab {[CmdletBinding(SupportsShouldProcess)]param($RunId,$StateRoot,[switch]$Force) $script:Removed=$true;[pscustomobject]@{RunId=$RunId;Status='REMOVED';Cleanup='CLEANUP_SUCCEEDED'}}
}
$null=Invoke-CSharpNativeCleanup -Module $nativeModule -OperationId 'synthetic-operation' -StateRoot $nativeRoot
Add-CheckResult -Name 'CSharp native: partieller Arrange ohne Connection-Info scopegebunden bereinigt' -Success (& $nativeModule {$script:Removed})
& $nativeModule {$script:Removed=$false;$script:Foreign=$true}
$caught='';try{Invoke-CSharpNativeCleanup -Module $nativeModule -OperationId 'synthetic-operation' -StateRoot $nativeRoot}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp native: fremde VM sperrt Remove' -Success ($caught -ceq 'CSHARP_NATIVE_FOREIGN_VM' -and -not(& $nativeModule {$script:Removed}))
& $nativeModule {$script:Foreign=$false;$script:Owned.metadata.workflowOperationId='another-operation'}
$caught='';try{Invoke-CSharpNativeCleanup -Module $nativeModule -OperationId 'synthetic-operation' -StateRoot $nativeRoot}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp native: fremde Operation sperrt Remove' -Success ($caught -ceq 'CSHARP_NATIVE_OWNED_RUN_STATE_INVALID' -and -not(& $nativeModule {$script:Removed}))
& $nativeModule {
    $script:Owned.metadata.workflowOperationId='synthetic-operation';$script:Removed=$false
    Set-Item -LiteralPath Function:script:Get-CleanupPlan -Value {param($RunDir)[pscustomobject]@{runId=$script:Owned.runId;scopeId=$script:Owned.scopeId;steps=@()}}
    Set-Item -LiteralPath Function:script:Get-VM -Value {param($Name)throw 'An empty VM plan must not enumerate VMs'}
}
$null=Invoke-CSharpNativeCleanup -Module $nativeModule -OperationId 'synthetic-operation' -StateRoot $nativeRoot
Add-CheckResult -Name 'CSharp native: früher Arrange ohne VM-Schritt bleibt bereinigbar' -Success (& $nativeModule {$script:Removed})
& $nativeModule {
    Set-Item -LiteralPath Function:script:Remove-SqlServerLab -Value {param($RunId,$StateRoot,[switch]$Force,[switch]$Confirm)[pscustomobject]@{RunId=$RunId;Status='REMOVED';Cleanup='CLEANUP_FAILED'}}
}
$caught='';try{Invoke-CSharpNativeCleanup -Module $nativeModule -OperationId 'synthetic-operation' -StateRoot $nativeRoot}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp native: Cleanupfehler bleibt trotz REMOVED sichtbar' -Success ($caught -ceq 'CSHARP_NATIVE_OWNED_RUN_CLEANUP_FAILED')
Remove-Module $nativeModule -Force -ErrorAction SilentlyContinue
foreach($path in @('Tests/Common/CSharpNativeAcceptance.ps1','Tests/Integration/Invoke-CSharpHyperVAcceptance.ps1','Tests/Integration/Invoke-CSharpHyperVAcceptanceWorker.ps1','Tests/Integration/Fixtures/CSharp/guest.ps1')){
    $parseErrors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $path),[ref]$null,[ref]$parseErrors)
    Add-CheckResult -Name ('CSharp native: Parser '+$path) -Success (@($parseErrors).Count -eq 0)
}
$guestAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tests/Integration/Fixtures/CSharp/guest.ps1'),[ref]$null,[ref]$null)
$credentialFunction=$guestAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-CSharpNativeSqlCredential'},$true)
. ([scriptblock]::Create($credentialFunction.Extent.Text))
$mutable=[Security.SecureString]::new();$mutable.AppendChar('x')
$login=New-CSharpNativeSqlCredential $mutable
try{
    Add-CheckResult -Name 'CSharp native: SQL-Credential kopiert veränderliches Gastsecret read-only' -Success ($login.Secret.IsReadOnly() -and -not $mutable.IsReadOnly() -and $login.Credential.UserId -ceq 'sa')
}finally{$login.Secret.Dispose();$mutable.Dispose()}
& {
    $script:copyService=@([pscustomobject]@{Id='synthetic-6C09BB55-D683-4DA0-8931-C9BF705F6480';Enabled=$false})
    $script:copyEnabled=$false
    function Get-VMIntegrationService {param($VM)$script:copyService}
    function Enable-VMIntegrationService {param($VMIntegrationService)$script:copyEnabled=$true}
    Enable-CSharpNativeGuestCopy -VM ([pscustomobject]@{Id='synthetic'})
    Add-CheckResult -Name 'CSharp native: deaktivierten Dateikopierdienst einschalten' -Success $script:copyEnabled
    $script:copyService=@();$script:copyEnabled=$false
    $caught='';try{Enable-CSharpNativeGuestCopy -VM ([pscustomobject]@{Id='synthetic'})}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name 'CSharp native: fehlenden Dateikopierdienst nicht übergehen' -Success ($caught -ceq 'CSHARP_NATIVE_GUEST_COPY_SERVICE_MISSING' -and -not $script:copyEnabled)
}
& {
    $script:guestServiceTouched=$false
    # The guest contract uses C:; supply only a temporary provider mapping on Linux.
    $temporaryGuestDrive=$false
    if(-not (Get-PSDrive -Name C -ErrorAction SilentlyContinue)){
        $null=New-PSDrive -Name C -PSProvider FileSystem -Root $nativeRoot
        $temporaryGuestDrive=$true
    }
    function Get-FileHash {param($LiteralPath,$Algorithm)[pscustomobject]@{Hash=('0'*64)}}
    function Get-Service {param($Name)$script:guestServiceTouched=$true;throw 'Unexpected guest service access'}
    $caught=''
    try{& (Join-Path $repoRoot 'Tests/Integration/Fixtures/CSharp/guest.ps1') -Stage Configure -Root ('C:\SqlServerLab\CSharpAcceptance\'+('a'*32)) -PackageSha256 ('b'*64) -ProbeSha256 ('c'*64) -SqlSha256 ('d'*64)}catch{$caught=$_.Exception.Message}
    finally{if($temporaryGuestDrive){Remove-PSDrive -Name C}}
    Add-CheckResult -Name 'CSharp native: Gastkopie-Hashdrift stoppt vor Dienst oder SQL' -Success ($caught -ceq 'CSHARP_NATIVE_GUEST_HASH' -and -not $script:guestServiceTouched)
}
$nativeWorkflow=Get-Content (Join-Path $repoRoot '.github/workflows/csharp-native-acceptance.yml') -Raw
Add-CheckResult -Name 'CSharp native: Workflow bindet Main-SHA, eigenen Runner und kein hartes Cancel' -Success (
    $nativeWorkflow.Contains("github.ref == 'refs/heads/main'") -and $nativeWorkflow.Contains('ref: ${{ github.sha }}') -and
    $nativeWorkflow.Contains('runs-on: [self-hosted, SQL_Lab, Hyper-V]') -and $nativeWorkflow.Contains('cancel-in-progress: false') -and
    $nativeWorkflow.Contains('timeout-minutes: 180') -and $nativeWorkflow.Contains('Get-CSharpNativeRequestFailureDiagnostic'))
$failureException=New-CSharpNativeFailureException -PrimaryFailure 'CSHARP_NATIVE_CHILD_TIMEOUT' -CleanupFailure 'CSHARP_NATIVE_CHILD_TERMINATION_UNCONFIRMED'
try{throw $failureException}catch{$diagnostic=Get-CSharpNativeFailureDiagnostic $_}
Add-CheckResult -Name 'CSharp native: Remote-Diagnose bewahrt Recovery getrennt vom Hauptfehler' -Success ($diagnostic.RecoveryRequired -and $diagnostic.ReasonCode -ceq 'CSHARP_NATIVE_RECOVERY_REQUIRED' -and $diagnostic.PrimaryFailure -ceq 'CSHARP_NATIVE_CHILD_TIMEOUT' -and $diagnostic.CleanupFailure -ceq 'CSHARP_NATIVE_CHILD_TERMINATION_UNCONFIRMED')
try{throw (New-CSharpNativeFailureException -PrimaryFailure 'synthetic private path' -CleanupFailure 'synthetic private detail')}catch{$diagnostic=Get-CSharpNativeFailureDiagnostic $_}
Add-CheckResult -Name 'CSharp native: Remote-Diagnose gibt keine privaten Fehlerdetails aus' -Success (($diagnostic|ConvertTo-Json -Compress) -notmatch 'synthetic private' -and $diagnostic.RecoveryRequired)
$attemptPath=Join-Path $nativeRoot 'native-attempt.json'
Add-CheckResult -Name 'CSharp native: Infrastrukturfehler ohne Sprachprobe bleibt NOT_EXECUTED' -Success ((Get-CSharpNativeSqlStatus -AttemptPath $attemptPath -OperationId 'synthetic' -Commit ('a'*40) -Passed $false) -ceq 'NOT_EXECUTED')
@{Status='SQL_PROBE_STARTED';OperationId='synthetic';Commit=('a'*40)}|ConvertTo-Json|Set-Content $attemptPath
Add-CheckResult -Name 'CSharp native: begonnene fehlgeschlagene Probe bleibt FAILED' -Success ((Get-CSharpNativeSqlStatus -AttemptPath $attemptPath -OperationId 'synthetic' -Commit ('a'*40) -Passed $false) -ceq 'FAILED')
Add-CheckResult -Name 'CSharp native: vollständiger eigener SQL-Nachweis PASSED' -Success ((Get-CSharpNativeSqlStatus -AttemptPath $attemptPath -OperationId 'synthetic' -Commit ('a'*40) -Passed $true) -ceq 'PASSED')

# Runner-local profile parsing uses only synthetic data; no installed profile is read.
$syntheticProfile=[ordered]@{SchemaVersion='1';ArtifactId=('hyperv-os-sealed-'+('b'*64));PayloadRoot='C:\Synthetic\Payload';PackageSha256=('a'*64);ProbeSha256=('c'*64);SqlMediaPath='Sql\setup.iso';MediaEdition='Eval';StateRoot='C:\Synthetic\State';MediaRoot='C:\Synthetic\Media'}
$profileJson=$syntheticProfile|ConvertTo-Json -Compress
$parsed=ConvertFrom-CSharpNativeProfile $profileJson
Add-CheckResult -Name 'CSharp profile: echter JSON-Parser erhält explizite Bindungen' -Success ($parsed.ArtifactId -ceq $syntheticProfile.ArtifactId -and $parsed.PackageSha256 -ceq ('a'*64) -and $parsed.StateRoot -ceq 'C:\Synthetic\State')
foreach($case in @(
    @{Name='Syntax';Json='{synthetic private path'},
    @{Name='Array';Json='[]'},
    @{Name='Null';Json='null'},
    @{Name='Duplikat';Json=$profileJson.Replace('"SchemaVersion":"1"','"SchemaVersion":"1","SchemaVersion":"1"')},
    @{Name='Case alias';Json=$profileJson.Replace('"SchemaVersion":"1"','"SchemaVersion":"1","schemaversion":"1"')},
    @{Name='Zusatzfeld';Json=$profileJson.Replace('"SchemaVersion":"1"','"SchemaVersion":"1","Command":"synthetic"')},
    @{Name='Fehlender Hash';Json=$profileJson.Replace('"PackageSha256":"'+('a'*64)+'",','')},
    @{Name='Hashdefault';Json=$profileJson.Replace(('a'*64),'latest')},
    @{Name='Falscher Typ';Json=$profileJson.Replace('"SchemaVersion":"1"','"SchemaVersion":1')},
    @{Name='Netzpfad';Json=$profileJson.Replace('C:\\Synthetic\\Payload','\\\\synthetic\\payload')},
    @{Name='Traversal';Json=$profileJson.Replace('Sql\\setup.iso','..\\setup.iso')},
    @{Name='Absolutes Medium';Json=$profileJson.Replace('Sql\\setup.iso','C:\\setup.iso')},
    @{Name='Größe';Json=(' '*16385)})){
    $outputs=@(& {try{ConvertFrom-CSharpNativeProfile $case.Json}catch{$_.Exception.Message}} *>&1)
    Add-CheckResult -Name ('CSharp profile: sperrt '+$case.Name+' ohne private Parserdetails') -Success ($outputs.Count -eq 1 -and [string]$outputs[0] -cmatch '^CSHARP_NATIVE_PROFILE_[A-Z_]+$')
}
$aclDescriptor=[pscustomobject]@{Owner='S-1-5-18';DaclPresent=$true;Rules=@([pscustomobject]@{Sid='S-1-5-32-544';Rights=2032127;Allow=$true;InheritOnly=$false})}
$caught='';try{Assert-CSharpNativeProfileAcl $aclDescriptor}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp profile: vertrauenswürdige ACL akzeptiert' -Success (-not $caught)
foreach($case in @(
    @{Name='Fremder Owner';Owner='S-1-5-21-1-2-3-1001';Dacl=$true;Rights=0;Inherit=$false;Ancestor=$false;Reject=$true},
    @{Name='Null-DACL';Owner='S-1-5-18';Dacl=$false;Rights=0;Inherit=$false;Ancestor=$false;Reject=$true},
    @{Name='Dateischreiber';Owner='S-1-5-18';Dacl=$true;Rights=2;Inherit=$false;Ancestor=$false;Reject=$true},
    @{Name='Nur vererbbarer Dateischreiber';Owner='S-1-5-18';Dacl=$true;Rights=2;Inherit=$true;Ancestor=$false;Reject=$false},
    @{Name='Vorfahre DeleteChild';Owner='S-1-5-18';Dacl=$true;Rights=64;Inherit=$false;Ancestor=$true;Reject=$true},
    @{Name='Vorfahre Delete';Owner='S-1-5-18';Dacl=$true;Rights=65536;Inherit=$false;Ancestor=$true;Reject=$true},
    @{Name='Vorfahre WriteDacl';Owner='S-1-5-18';Dacl=$true;Rights=262144;Inherit=$false;Ancestor=$true;Reject=$true},
    @{Name='Vorfahre WriteOwner';Owner='S-1-5-18';Dacl=$true;Rights=524288;Inherit=$false;Ancestor=$true;Reject=$true},
    @{Name='Vorfahre nur neue Kinder';Owner='S-1-5-18';Dacl=$true;Rights=6;Inherit=$false;Ancestor=$true;Reject=$false},
    @{Name='Unbekannter Writer';Owner='S-1-5-18';Dacl=$true;Rights=2;Inherit=$false;Ancestor=$false;Reject=$true})){
    $descriptor=[pscustomobject]@{Owner=$case.Owner;DaclPresent=$case.Dacl;Rules=@([pscustomobject]@{Sid='S-1-5-21-9-9-9-9999';Rights=$case.Rights;Allow=$true;InheritOnly=$case.Inherit})}
    $caught='';try{Assert-CSharpNativeProfileAcl $descriptor -Ancestor:$case.Ancestor}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name ('CSharp profile: ACL '+$case.Name) -Success ($(if($case.Reject){$caught -ceq 'CSHARP_NATIVE_PROFILE_ACL'}else{-not $caught}))
}
& {
    $priorRoot=$env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT
    $profileRoot=Join-Path $nativeRoot 'profiles';$null=New-Item -ItemType Directory $profileRoot
    $env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT=$profileRoot
    $syntheticProfilePath=Join-Path $profileRoot 'csharp-sql2025.json'
    [IO.File]::WriteAllText($syntheticProfilePath,$profileJson)
    $script:profilePathChecked=$false
    function Assert-CSharpNativeProfilePath {param($Path) $script:profilePathChecked=$true;if($Path -cne $syntheticProfilePath){throw 'synthetic private path'}}
    try{
        $resolved=Get-CSharpNativeProfile -Name 'csharp-sql2025'
        Add-CheckResult -Name 'CSharp profile: begrenztes Dateilesen ruft Pfadschutz vor Parser auf' -Success ($script:profilePathChecked -and $resolved.ProbeSha256 -ceq ('c'*64))
        $script:profilePathChecked=$false
        $outputs=@(& {try{Get-CSharpNativeProfile -Name '../synthetic-private'}catch{$_.Exception.Message}} *>&1)
        Add-CheckResult -Name 'CSharp profile: unbekannter Name vor Dateizugriff gesperrt' -Success (-not $script:profilePathChecked -and $outputs.Count -eq 1 -and $outputs[0] -ceq 'CSHARP_NATIVE_PROFILE_NAME')
        [IO.File]::WriteAllText($syntheticProfilePath,('x'*16385))
        $caught='';try{Get-CSharpNativeProfile -Name 'csharp-sql2025'}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name 'CSharp profile: Dateigröße vor Parser begrenzt' -Success ($caught -ceq 'CSHARP_NATIVE_PROFILE_SIZE')
        function Assert-CSharpNativeProfilePath {param($Path) throw 'synthetic private ACL failure'}
        $outputs=@(& {try{Get-CSharpNativeProfile -Name 'csharp-sql2025'}catch{$_.Exception.Message}} *>&1)
        Add-CheckResult -Name 'CSharp profile: private ACL-Auflösungsfehler bleiben bereinigt' -Success ($outputs.Count -eq 1 -and $outputs[0] -ceq 'CSHARP_NATIVE_PROFILE_READ_FAILED')
    }finally{$env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT=$priorRoot}
}
$supervisorText=Get-Content (Join-Path $repoRoot 'Tests/Integration/Invoke-CSharpHyperVAcceptance.ps1') -Raw
Add-CheckResult -Name 'CSharp profile: Checkout vor Profil und Artifactguard danach' -Success (
    $supervisorText.IndexOf('Assert-CSharpNativeCheckout $dispatch') -lt $supervisorText.IndexOf('Get-CSharpNativeProfile -Name $Profile') -and
    $supervisorText.IndexOf('Get-CSharpNativeProfile -Name $Profile') -lt $supervisorText.IndexOf('Assert-CSharpNativeDispatch $dispatch'))
$inputReferences=@([regex]::Matches($nativeWorkflow,'inputs\.([a-z0-9_]+)')|ForEach-Object {$_.Groups[1].Value})
Add-CheckResult -Name 'CSharp profile: Workflow überträgt ausschließlich Profilnamen und Requesthash' -Success (
    $inputReferences.Count -eq 2 -and ($inputReferences -join ',') -ceq 'profile,request_sha256' -and $nativeWorkflow.Contains('options: [csharp-sql2025]') -and
    $nativeWorkflow.Contains('-Profile $env:CSHARP_PROFILE -RequestSha256 $env:CSHARP_REQUEST_HASH | Out-Null') -and $nativeWorkflow -notmatch 'SQL_SERVER_LAB_CSHARP_PROFILE_ROOT|payload_root:|state_root:|media_root:|sql_media_path:')

if($IsWindows){
    & {
        # Exercise the real Windows ACL adapter and real ancestor walk using only synthetic ACL objects.
        $profilePath=Join-Path $nativeRoot 'acl-profile.json'
        [IO.File]::WriteAllText($profilePath,$profileJson)
        $script:aclSeen=[Collections.Generic.List[string]]::new()
        $script:unsafeAncestor=''
        function Get-Acl {
            [CmdletBinding()]param($LiteralPath)
            $script:aclSeen.Add($LiteralPath)
            $acl=[Security.AccessControl.DirectorySecurity]::new()
            $sddl='O:SYG:SYD:(A;;FA;;;SY)(A;;FR;;;WD)'
            if($LiteralPath -eq $script:unsafeAncestor){$sddl='O:SYG:SYD:(A;;FA;;;SY)(A;;0x40;;;WD)'}
            $acl.SetSecurityDescriptorSddlForm($sddl)
            return $acl
        }
        $caught='';try{Assert-CSharpNativeProfilePath $profilePath}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name 'CSharp profile: Windows-ACL-Adapter prüft tatsächliche Vorfahrenkette' -Success (-not $caught -and $script:aclSeen.Contains([IO.Path]::GetPathRoot($profilePath)) -and $script:aclSeen.Contains($nativeRoot))
        $script:unsafeAncestor=[IO.Path]::GetDirectoryName($nativeRoot)
        $caught='';try{Assert-CSharpNativeProfilePath $profilePath}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name 'CSharp profile: Windows-ACL-Adapter sperrt ersetzbaren Vorfahren' -Success ($caught -ceq 'CSHARP_NATIVE_PROFILE_ACL')
        foreach($path in @('relative.json','\\synthetic\share\profile.json','C:\synthetic\profile.json:stream')){
            $script:aclSeen.Clear();$caught=''
            try{Assert-CSharpNativeProfilePath $path}catch{$caught=$_.Exception.Message}
            Add-CheckResult -Name ('CSharp profile: Windows-Pfadsyntax gesperrt '+$path.Split(':').Count) -Success ($caught -ceq 'CSHARP_NATIVE_PROFILE_PATH' -and $script:aclSeen.Count -eq 0)
        }
    }
}

if($IsWindows){
    $aclFixture=Join-Path $nativeRoot 'actual-unprivileged-acl.json'
    [IO.File]::WriteAllText($aclFixture,$profileJson)
    $fixtureOwner=(Get-Acl -LiteralPath $aclFixture).GetOwner([Security.Principal.SecurityIdentifier]).Value
    if($fixtureOwner -cnotin @('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')){
        $caught='';try{Assert-CSharpNativeProfilePath $aclFixture}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name 'CSharp profile: echte unprivilegierte Fixture-ACL abgewiesen' -Success ($caught -ceq 'CSHARP_NATIVE_PROFILE_ACL')
    }
    & {
        function Get-Item {[CmdletBinding()]param($LiteralPath,[switch]$Force) [pscustomobject]@{Attributes=[IO.FileAttributes]::ReparsePoint}}
        $caught='';try{Assert-CSharpNativeProfilePath $aclFixture}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name 'CSharp profile: Reparse Point vor ACL und Lesen gesperrt' -Success ($caught -ceq 'CSHARP_NATIVE_REPARSE_POINT')
    }
}

if($IsWindows){
    foreach($genericRight in @('GW','GA')){
        $acl=[Security.AccessControl.DirectorySecurity]::new()
        $acl.SetSecurityDescriptorSddlForm(('O:SYG:SYD:(A;;'+$genericRight+';;;WD)'))
        $descriptor=[pscustomobject]@{
            Owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value;DaclPresent=$true
            Rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|ForEach-Object {
                [pscustomobject]@{Sid=$_.IdentityReference.Value;Rights=[long]$_.FileSystemRights;Allow=($_.AccessControlType -eq 'Allow');InheritOnly=[bool]($_.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)}
            })
        }
        foreach($ancestor in @($false,$true)){
            $caught='';try{Assert-CSharpNativeProfileAcl $descriptor -Ancestor:$ancestor}catch{$caught=$_.Exception.Message}
            Add-CheckResult -Name ('CSharp profile: echter generischer ACL-Writer '+$genericRight+' Ancestor='+$ancestor) -Success ($caught -ceq 'CSHARP_NATIVE_PROFILE_ACL')
        }
    }
}

# Test-only profile evidence; never invokes the SQL/VM supervisor.
function Get-CSharpProfileEvidenceDiagnostic {
    param([Parameter(Mandatory)]$Record,[Parameter(Mandatory)][string]$Stage)
    $stages=@('SETUP','ANCESTOR_PREFLIGHT','SECURE_DIRECTORY_CREATE','NEW_ROOT_CHECK','SECURE_FILE_CREATE','PROFILE_RESOLVE','CLEANUP_CHECK','DELETE_FILE','DELETE_DIRECTORY')
    $reported=[string]$Record.Exception.Data['EvidenceStage']
    if($reported -cnotin $stages){$reported=$(if($Stage -cin $stages){$Stage}else{'SETUP'})}
    $class=[string]$Record.Exception.Data['EvidenceAclClass']
    if($class -cnotin @('BASE','ANCESTOR')){$class=$null}
    $reason=[string]$Record.Exception.Data['EvidenceAclReason']
    if($reason -cnotin @('OWNER','DACL','WRITER')){$reason=$null}
    [pscustomobject]@{Code=(Get-CSharpNativeFailureCode $Record);Stage=$reported;AclClass=$class;AclReason=$reason}
}
function New-CSharpProfileEvidenceAclFailure {
    param([Parameter(Mandatory)]$Descriptor,[Parameter(Mandatory)][string]$Stage,[Parameter(Mandatory)][string]$TargetClass)
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $reason=if(-not $Descriptor.DaclPresent){'DACL'}elseif($Descriptor.Owner -cnotin $trusted){'OWNER'}else{'WRITER'}
    $failure=[InvalidOperationException]::new('CSHARP_NATIVE_PROFILE_ACL')
    $failure.Data['EvidenceStage']=$Stage
    $failure.Data['EvidenceAclClass']=$TargetClass
    $failure.Data['EvidenceAclReason']=$reason
    return $failure
}
function Invoke-CSharpProfileAclEvidenceCore {
    param([Parameter(Mandatory)][hashtable]$Operations)
    $ownership=[pscustomobject]@{DirectoryOwned=$false;FileOwned=$false}
    $primary=$null;$cleanup=$null;$primaryDetail=$null;$cleanupDetail=$null;$stage='SETUP'
    try{
        $stage='SECURE_DIRECTORY_CREATE'
        & $Operations.CreateDirectory $ownership
        if(-not $ownership.DirectoryOwned){throw 'CSHARP_NATIVE_ACL_EVIDENCE_OWNERSHIP'}
        $stage='SECURE_FILE_CREATE'
        & $Operations.CreateFile $ownership
        if(-not $ownership.FileOwned){throw 'CSHARP_NATIVE_ACL_EVIDENCE_OWNERSHIP'}
        $stage='PROFILE_RESOLVE'
        & $Operations.Check $ownership
    }catch{$primaryDetail=Get-CSharpProfileEvidenceDiagnostic $_ $stage;$primary=$primaryDetail.Code}
    finally{
        if($ownership.DirectoryOwned){
            try{
                $stage='CLEANUP_CHECK'
                & $Operations.ValidateCleanup $ownership
                if($ownership.FileOwned){$stage='DELETE_FILE';& $Operations.DeleteFile $ownership}
                $stage='DELETE_DIRECTORY'
                & $Operations.DeleteDirectory $ownership
            }catch{$cleanupDetail=Get-CSharpProfileEvidenceDiagnostic $_ $stage;$cleanup=$cleanupDetail.Code}
        }
    }
    [pscustomobject]@{Status=$(if($primary -or $cleanup){'FAILED'}else{'PASSED'});PrimaryFailure=$primary;CleanupFailure=$cleanup;PrimaryDiagnostic=$primaryDetail;CleanupDiagnostic=$cleanupDetail}
}
function Assert-CSharpProfileEvidencePath {
    param([Parameter(Mandatory)][string]$Path,[switch]$AncestorsOnly,[ValidateSet('ANCESTOR_PREFLIGHT','NEW_ROOT_CHECK','CLEANUP_CHECK')][string]$Stage='ANCESTOR_PREFLIGHT')
    Assert-CSharpNativeLocalPath $Path
    $cursor=[IO.Path]::GetFullPath($Path)
    while($cursor){
        $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if(-not $item.PSIsContainer){throw 'CSHARP_NATIVE_ACL_EVIDENCE_PATH'}
        $acl=Get-Acl -LiteralPath $cursor -ErrorAction Stop
        $raw=[Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(),0)
        $descriptor=[pscustomobject]@{
            Owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value;DaclPresent=($null -ne $raw.DiscretionaryAcl)
            Rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|ForEach-Object {
                [pscustomobject]@{Sid=$_.IdentityReference.Value;Rights=[long]$_.FileSystemRights;Allow=($_.AccessControlType -eq 'Allow');InheritOnly=[bool]($_.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)}
            })
        }
        try{Assert-CSharpNativeProfileAcl $descriptor -Ancestor:($AncestorsOnly -or $cursor -ine $Path)}catch{
            if((Get-CSharpNativeFailureCode $_) -cne 'CSHARP_NATIVE_PROFILE_ACL'){throw}
            throw (New-CSharpProfileEvidenceAclFailure -Descriptor $descriptor -Stage $Stage -TargetClass $(if($cursor -ieq $Path){'BASE'}else{'ANCESTOR'}))
        }
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
}
# Fault injection needs neither filesystem mutation nor admin rights.
foreach($fault in @('None','Collision','PartialFile','Check','Reparse','DeleteFile','DeleteDirectory')){
    & {
        $trace=[Collections.Generic.List[string]]::new()
        $operations=@{
            CreateDirectory={param($owned) $trace.Add('CreateDirectory');if($fault -eq 'Collision'){throw 'CSHARP_NATIVE_ACL_EVIDENCE_EXISTS'};$owned.DirectoryOwned=$true}
            CreateFile={param($owned) $trace.Add('CreateFile');$owned.FileOwned=$true;if($fault -eq 'PartialFile'){throw 'CSHARP_NATIVE_ACL_EVIDENCE_WRITE'}}
            Check={param($owned) $trace.Add('Check');if($fault -eq 'Check'){throw 'synthetic private diagnostic'}}
            ValidateCleanup={param($owned) $trace.Add('ValidateCleanup');if($fault -eq 'Reparse'){throw 'CSHARP_NATIVE_REPARSE_POINT'}}
            DeleteFile={param($owned) $trace.Add('DeleteFile');if($fault -eq 'DeleteFile'){throw 'CSHARP_NATIVE_ACL_EVIDENCE_DELETE_FILE'}}
            DeleteDirectory={param($owned) $trace.Add('DeleteDirectory');if($fault -eq 'DeleteDirectory'){throw 'CSHARP_NATIVE_ACL_EVIDENCE_DELETE_DIRECTORY'}}
        }
        $outcome=Invoke-CSharpProfileAclEvidenceCore $operations
        $good=switch($fault){
            'None' {$outcome.Status -eq 'PASSED' -and ($trace -join ',') -eq 'CreateDirectory,CreateFile,Check,ValidateCleanup,DeleteFile,DeleteDirectory'}
            'Collision' {$outcome.Status -eq 'FAILED' -and ($trace -join ',') -eq 'CreateDirectory'}
            'PartialFile' {$outcome.Status -eq 'FAILED' -and $trace.Contains('DeleteFile') -and $trace.Contains('DeleteDirectory') -and -not $trace.Contains('Check')}
            'Check' {$outcome.Status -eq 'FAILED' -and $trace.Contains('DeleteDirectory') -and ($outcome|ConvertTo-Json -Compress) -notmatch 'synthetic private'}
            'Reparse' {$outcome.CleanupFailure -eq 'CSHARP_NATIVE_REPARSE_POINT' -and -not $trace.Contains('DeleteFile') -and -not $trace.Contains('DeleteDirectory')}
            'DeleteFile' {$outcome.CleanupFailure -eq 'CSHARP_NATIVE_ACL_EVIDENCE_DELETE_FILE' -and -not $trace.Contains('DeleteDirectory')}
            'DeleteDirectory' {$outcome.CleanupFailure -eq 'CSHARP_NATIVE_ACL_EVIDENCE_DELETE_DIRECTORY' -and $outcome.Status -eq 'FAILED'}
        }
        Add-CheckResult -Name ('CSharp profile ACL evidence: synthetic '+$fault) -Success $good
        $expectedStage=switch($fault){'Collision'{'SECURE_DIRECTORY_CREATE'}'PartialFile'{'SECURE_FILE_CREATE'}'Check'{'PROFILE_RESOLVE'}'Reparse'{'CLEANUP_CHECK'}'DeleteFile'{'DELETE_FILE'}'DeleteDirectory'{'DELETE_DIRECTORY'}default{$null}}
        if($expectedStage){
            $diagnostic=if($outcome.CleanupDiagnostic){$outcome.CleanupDiagnostic}else{$outcome.PrimaryDiagnostic}
            Add-CheckResult -Name ('CSharp profile ACL evidence: stage '+$fault) -Success ($diagnostic.Stage -ceq $expectedStage)
        }
    }
}
foreach($case in @(@{Owner='synthetic private owner';DaclPresent=$true;Expected='OWNER'},@{Owner='S-1-5-18';DaclPresent=$false;Expected='DACL'},@{Owner='S-1-5-18';DaclPresent=$true;Expected='WRITER'})){
    try{throw (New-CSharpProfileEvidenceAclFailure -Descriptor $case -Stage 'ANCESTOR_PREFLIGHT' -TargetClass 'ANCESTOR')}catch{$diagnostic=Get-CSharpProfileEvidenceDiagnostic $_ 'SETUP'}
    Add-CheckResult -Name ('CSharp profile ACL evidence: sanitized ACL reason '+$case.Expected) -Success ($diagnostic.Stage -ceq 'ANCESTOR_PREFLIGHT' -and $diagnostic.AclReason -ceq $case.Expected -and $diagnostic.AclClass -ceq 'ANCESTOR' -and ($diagnostic|ConvertTo-Json -Compress) -notmatch 'synthetic private')
}
try{throw (New-CSharpProfileEvidenceAclFailure -Descriptor @{Owner='S-1-5-18';DaclPresent=$true} -Stage 'synthetic private stage' -TargetClass 'synthetic private class')}catch{$diagnostic=Get-CSharpProfileEvidenceDiagnostic $_ 'PROFILE_RESOLVE'}
Add-CheckResult -Name 'CSharp profile ACL evidence: unknown diagnostic metadata sanitized' -Success ($diagnostic.Stage -ceq 'PROFILE_RESOLVE' -and $null -eq $diagnostic.AclClass -and ($diagnostic|ConvertTo-Json -Compress) -notmatch 'synthetic private')
$profileEvidenceElevated=$false
if($IsWindows){
    $profileEvidenceIdentity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{$profileEvidenceElevated=([Security.Principal.WindowsPrincipal]::new($profileEvidenceIdentity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}finally{$profileEvidenceIdentity.Dispose()}
}
if(-not $IsWindows -or -not $profileEvidenceElevated){
    Write-Host '  NOT_EXECUTED  CSharp profile ACL evidence: real protected profile and exact cleanup (elevated Windows required)'
}else{
    $savedProfileRoot=$env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT
    $evidenceOutcome=$null;$evidenceStage='SETUP'
    try{
        $commonData=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        if([string]::IsNullOrWhiteSpace($commonData)){throw 'CSHARP_NATIVE_ACL_EVIDENCE_BASE'}
        # One deterministic local volume root, never a search for a less restricted ACL.
        $evidenceBase=[IO.Path]::GetPathRoot($commonData)
        if([string]::IsNullOrWhiteSpace($evidenceBase)){throw 'CSHARP_NATIVE_ACL_EVIDENCE_BASE'}
        $evidenceStage='ANCESTOR_PREFLIGHT'
        Assert-CSharpProfileEvidencePath $evidenceBase -AncestorsOnly -Stage 'ANCESTOR_PREFLIGHT'
        $evidenceStage='SETUP'
        $evidenceRoot=Join-Path $evidenceBase ('SqlServerLab-CSharpProfileEvidence-'+[guid]::NewGuid().ToString('N'))
        $evidenceFile=Join-Path $evidenceRoot 'csharp-sql2025.json'
        $directorySecurity=[Security.AccessControl.DirectorySecurity]::new()
        $directorySecurity.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)')
        $fileSecurity=[Security.AccessControl.FileSecurity]::new()
        $fileSecurity.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;BA)(A;;FA;;;SY)')
        if(-not ('SqlServerLab.Tests.CSharpProfileDirectoryNative' -as [type])){
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace SqlServerLab.Tests {
    public static class CSharpProfileDirectoryNative {
        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes {
            public int Length;
            public IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateDirectoryW(string path, ref SecurityAttributes attributes);
        public static int Create(string path, byte[] descriptor) {
            IntPtr memory=Marshal.AllocHGlobal(descriptor.Length);
            try {
                Marshal.Copy(descriptor,0,memory,descriptor.Length);
                var attributes=new SecurityAttributes {Length=Marshal.SizeOf<SecurityAttributes>(), SecurityDescriptor=memory, InheritHandle=false};
                if(CreateDirectoryW(path,ref attributes)) return 0;
                int error=Marshal.GetLastWin32Error(); return error == 0 ? -1 : error;
            } finally { Marshal.FreeHGlobal(memory); }
        }
    }
}
"@
        }
        $evidenceJson=[ordered]@{SchemaVersion='1';ArtifactId=('hyperv-os-sealed-'+('b'*64));PayloadRoot='C:\Synthetic\Payload';PackageSha256=('a'*64);ProbeSha256=('c'*64);SqlMediaPath='Sql\setup.iso';MediaEdition='Eval';StateRoot='C:\Synthetic\State';MediaRoot='C:\Synthetic\Media'}|ConvertTo-Json -Compress
        $operations=@{
            CreateDirectory={
                param($owned)
                $creation=[SqlServerLab.Tests.CSharpProfileDirectoryNative]::Create($evidenceRoot,$directorySecurity.GetSecurityDescriptorBinaryForm())
                if($creation -eq 183){throw 'CSHARP_NATIVE_ACL_EVIDENCE_EXISTS'}
                if($creation -ne 0){throw 'CSHARP_NATIVE_ACL_EVIDENCE_CREATE'}
                $owned.DirectoryOwned=$true
            }
            CreateFile={
                param($owned)
                Assert-CSharpProfileEvidencePath $evidenceRoot -Stage 'NEW_ROOT_CHECK'
                $stream=$null
                try{
                    $stream=[IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($evidenceFile),[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::Read -bor [Security.AccessControl.FileSystemRights]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::None,$fileSecurity)
                    $owned.FileOwned=$true
                    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($evidenceJson)
                    $stream.Write($bytes,0,$bytes.Length)
                }finally{if($stream){$stream.Dispose()}}
            }
            Check={
                param($owned)
                $env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT=$evidenceRoot
                $actual=Get-CSharpNativeProfile -Name 'csharp-sql2025'
                if($actual.ArtifactId -cne ('hyperv-os-sealed-'+('b'*64)) -or $actual.PackageSha256 -cne ('a'*64) -or $actual.ProbeSha256 -cne ('c'*64) -or $actual.PayloadRoot -cne 'C:\Synthetic\Payload'){throw 'CSHARP_NATIVE_ACL_EVIDENCE_CONTENT'}
            }
            ValidateCleanup={
                param($owned)
                if([IO.Path]::GetDirectoryName($evidenceRoot) -ine $evidenceBase -or [IO.Path]::GetFileName($evidenceRoot) -cnotmatch '^SqlServerLab-CSharpProfileEvidence-[a-f0-9]{32}$' -or $evidenceFile -cne (Join-Path $evidenceRoot 'csharp-sql2025.json')){throw 'CSHARP_NATIVE_ACL_EVIDENCE_BINDING'}
                Assert-CSharpProfileEvidencePath $evidenceRoot -Stage 'CLEANUP_CHECK'
                if($owned.FileOwned -and [IO.File]::Exists($evidenceFile)){Assert-CSharpNativeProfilePath $evidenceFile}
            }
            DeleteFile={param($owned) [IO.File]::Delete($evidenceFile)}
            DeleteDirectory={param($owned) [IO.Directory]::Delete($evidenceRoot,$false)}
        }
        $evidenceOutcome=Invoke-CSharpProfileAclEvidenceCore $operations
    }catch{$detail=Get-CSharpProfileEvidenceDiagnostic $_ $evidenceStage;$evidenceOutcome=[pscustomobject]@{Status='FAILED';PrimaryFailure=$detail.Code;CleanupFailure=$null;PrimaryDiagnostic=$detail;CleanupDiagnostic=$null}}
    finally{$env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT=$savedProfileRoot}
    Add-CheckResult -Name 'CSharp profile ACL evidence: real protected profile and exact cleanup' -Success ($evidenceOutcome.Status -eq 'PASSED') -Message ($evidenceOutcome|ConvertTo-Json -Compress)
}

. (Join-Path $PSScriptRoot 'CSharpNativeRequestChecks.ps1')

# Characterize the real read-only producer with deterministic module/storage dependencies.
& {
    . (Join-Path $repoRoot 'Private/ClientReadiness.ps1')
    $readinessModule=New-Module -ScriptBlock {
        $script:ModuleLoadErrors=@();$script:MissingStorage=$false
        function SyntheticReadinessExport {}
        function Get-LabClientRuntimeReadiness {param($Provider) [pscustomobject]@{Category='Reachability';Code='PROVIDER_REACHABLE';Status='PASS';MissingPrerequisite=$null;Warning=$null;NextStep=''}}
        function Get-LabStorageConfiguration {if($script:MissingStorage){return [pscustomobject]@{DefaultLocationId=$null;ControllerId=$null}};[pscustomobject]@{DefaultLocationId='synthetic';ControllerId='synthetic'}}
        Export-ModuleMember -Function SyntheticReadinessExport
    }
    function Test-ModuleManifest {[CmdletBinding()]param($Path) [pscustomobject]@{Name='synthetic'}}
    function Import-Module {[CmdletBinding()]param($Name,[switch]$Force,[switch]$PassThru) $readinessModule}
    function Import-PowerShellDataFile {param($Path) @{FunctionsToExport=@('SyntheticReadinessExport')}}
    try{
        $actualReadiness=Test-LabClientReadiness -RepositoryRoot $repoRoot -Provider hyperv -Operation Create
        Add-CheckResult -Name 'CSharp readiness: actual Create producer retains mandatory authorization warning' -Success ($actualReadiness.Status -ceq 'READY_WITH_WARNINGS' -and @($actualReadiness.MissingPrerequisites).Count -eq 0 -and @($actualReadiness.Warnings).Count -eq 1 -and $actualReadiness.Warnings[0] -ceq 'TARGET_AUTHORIZATION_REQUIRED' -and @($actualReadiness.Checks|Where-Object Status -eq 'PASS').Count -eq 8 -and -not $actualReadiness.MutationAllowed)
        $before=$actualReadiness|ConvertTo-Json -Depth 6 -Compress
        $caught='';try{Assert-CSharpNativeClientReadiness $actualReadiness}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name 'CSharp readiness: exact healthy Create result accepted without granting mutation' -Success (-not $caught -and ($actualReadiness|ConvertTo-Json -Depth 6 -Compress) -ceq $before -and -not $actualReadiness.MutationAllowed)
        & $readinessModule {$script:MissingStorage=$true}
        $missing=Test-LabClientReadiness -RepositoryRoot $repoRoot -Provider hyperv -Operation Create
        $caught='';try{Assert-CSharpNativeClientReadiness $missing}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name 'CSharp readiness: actual Create producer still blocks missing storage' -Success ($missing.Status -ceq 'NOT_READY' -and $missing.MissingPrerequisites -contains 'STORAGE_CONFIGURATION_REQUIRED' -and $caught -ceq 'CSHARP_NATIVE_CLIENT_NOT_READY')
        foreach($case in @('Contract','Provider','Operation','Status','MissingPrerequisite','UnknownWarning','DuplicateWarning','WarningMissing','ChecksEmpty','MissingStorageCheck','DuplicateCategory','Blocked','NotChecked','UnknownStatus','UnknownPassCode','CheckWarning','RightsWarning','MutationAllowed','MissingMutationFlag')){
            $copy=$before|ConvertFrom-Json -Depth 6
            switch($case){
                'Contract' {$copy.ContractVersion='SqlServerLab.ClientReadiness/2.0'}
                'Provider' {$copy.Provider='docker'}
                'Operation' {$copy.Operation='Inspect'}
                'Status' {$copy.Status='READY'}
                'MissingPrerequisite' {$copy.MissingPrerequisites=@('UNKNOWN')}
                'UnknownWarning' {$copy.Warnings+=@('UNKNOWN')}
                'DuplicateWarning' {$copy.Warnings+=@('TARGET_AUTHORIZATION_REQUIRED')}
                'WarningMissing' {$copy.Warnings=@()}
                'ChecksEmpty' {$copy.Checks=@()}
                'MissingStorageCheck' {$copy.Checks=@($copy.Checks|Where-Object Category -ne 'Storage')}
                'DuplicateCategory' {$copy.Checks[7]=$copy.Checks[0]}
                'Blocked' {$copy.Checks[7].Status='BLOCKED'}
                'NotChecked' {$copy.Checks[7].Status='NOT_CHECKED'}
                'UnknownStatus' {$copy.Checks[7].Status='UNKNOWN'}
                'UnknownPassCode' {$copy.Checks[7].Code='UNVERIFIED_STORAGE'}
                'CheckWarning' {$copy.Checks[7].Warning='UNKNOWN'}
                'RightsWarning' {$copy.Checks[8].Warning='UNKNOWN'}
                'MutationAllowed' {$copy.MutationAllowed=$true}
                'MissingMutationFlag' {$copy.PSObject.Properties.Remove('MutationAllowed')}
            }
            $caught='';try{Assert-CSharpNativeClientReadiness $copy}catch{$caught=$_.Exception.Message}
            Add-CheckResult -Name ('CSharp readiness: rejects '+$case) -Success ($caught -ceq 'CSHARP_NATIVE_CLIENT_NOT_READY')
        }
        $caught='';try{Assert-CSharpNativeClientReadiness $null}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name 'CSharp readiness: missing result rejected' -Success ($caught -ceq 'CSHARP_NATIVE_CLIENT_NOT_READY')
    }finally{Remove-Module $readinessModule -Force -ErrorAction SilentlyContinue}
}

# Real SqlClient parsing only: never Open a connection or execute SQL.
& {
    Add-Type -AssemblyName System.Data
    $legacyBuilder=[Data.SqlClient.SqlConnectionStringBuilder]::new()
    $reproduced=$false
    try{$legacyBuilder.DataSource='localhost'}catch{$reproduced=$_.Exception.Message -match 'DataSource'}
    Add-CheckResult -Name 'CSharp SQL connection: real IDictionary property assignment reproduces rejected keyword' -Success $reproduced
    $connectionAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tests/Integration/Fixtures/CSharp/guest.ps1'),[ref]$null,[ref]$null)
    $connectionFactory=$connectionAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'New-CSharpNativeSqlConnectionString'},$true)
    . ([scriptblock]::Create($connectionFactory.Extent.Text))
    $text=New-CSharpNativeSqlConnectionString
    $parsed=[Data.SqlClient.SqlConnectionStringBuilder]::new($text)
    Add-CheckResult -Name 'CSharp SQL connection: actual guest builder preserves local endpoint and timeout' -Success ($parsed['Data Source'] -ceq 'localhost' -and $parsed['Initial Catalog'] -ceq 'master' -and $parsed['Connect Timeout'] -eq 15)
    Add-CheckResult -Name 'CSharp SQL connection: actual guest builder preserves encryption and disabled pooling' -Success ($parsed['Encrypt'] -and $parsed['TrustServerCertificate'] -and -not $parsed['Pooling'])
    Add-CheckResult -Name 'CSharp SQL connection: authentication stays outside connection string' -Success (-not $parsed['Integrated Security'] -and -not $parsed.ShouldSerialize('User ID') -and -not $parsed.ShouldSerialize('Password'))
    $password=[Security.SecureString]::new();$password.AppendChar('x')
    $login=New-CSharpNativeSqlCredential $password
    $connection=[Data.SqlClient.SqlConnection]::new($text)
    try{
        $connection.Credential=$login.Credential
        Add-CheckResult -Name 'CSharp SQL connection: credential assignment succeeds without opening SQL' -Success ($connection.State -eq [Data.ConnectionState]::Closed -and $connection.Credential.UserId -ceq 'sa' -and $login.Secret.IsReadOnly())
    }finally{$connection.Dispose();$login.Secret.Dispose();$password.Dispose()}
}
if($IsWindows){
    $windowsPowerShell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    if(Test-Path -LiteralPath $windowsPowerShell -PathType Leaf){
        $harness=Join-Path $nativeRoot 'legacy-sql-builder.ps1'
        @'
param([string]$GuestScript)
$ErrorActionPreference='Stop'
try{
    if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'CSHARP_NATIVE_BUILDER_HOST'}
    Add-Type -AssemblyName System.Data
    $ast=[Management.Automation.Language.Parser]::ParseFile($GuestScript,[ref]$null,[ref]$null)
    foreach($name in @('New-CSharpNativeSqlConnectionString','New-CSharpNativeSqlCredential')){
        $definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $text=New-CSharpNativeSqlConnectionString
    $parsed=New-Object Data.SqlClient.SqlConnectionStringBuilder $text
    if($parsed['Data Source'] -cne 'localhost' -or $parsed['Initial Catalog'] -cne 'master' -or $parsed['Connect Timeout'] -ne 15 -or -not $parsed['Encrypt'] -or -not $parsed['TrustServerCertificate'] -or $parsed['Pooling'] -or $parsed['Integrated Security'] -or $parsed.ShouldSerialize('User ID') -or $parsed.ShouldSerialize('Password')){throw 'CSHARP_NATIVE_BUILDER_CONTRACT'}
    $password=New-Object Security.SecureString;$password.AppendChar('x')
    $login=New-CSharpNativeSqlCredential $password
    $connection=New-Object Data.SqlClient.SqlConnection $text
    try{$connection.Credential=$login.Credential;if($connection.State -ne [Data.ConnectionState]::Closed -or -not $login.Secret.IsReadOnly()){throw 'CSHARP_NATIVE_BUILDER_CREDENTIAL'}}
    finally{$connection.Dispose();$login.Secret.Dispose();$password.Dispose()}
    Write-Output 'CSHARP_NATIVE_BUILDER_WINDOWS_POWERSHELL_PASS'
}catch{Write-Output 'CSHARP_NATIVE_BUILDER_WINDOWS_POWERSHELL_FAILED';exit 1}
'@|Set-Content -LiteralPath $harness
        $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$windowsPowerShell;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($argument in @('-NoProfile','-NonInteractive','-File',$harness,'-GuestScript',(Join-Path $repoRoot 'Tests/Integration/Fixtures/CSharp/guest.ps1'))){$start.ArgumentList.Add($argument)}
        $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$legacySuccess=$false
        try{
            $null=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(30000)){$process.Kill($true);$null=$process.WaitForExit(15000)}
            if($process.HasExited){
                $out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
                [IO.File]::WriteAllText((Join-Path $nativeRoot 'legacy-sql-builder.stdout.log'),$out)
                [IO.File]::WriteAllText((Join-Path $nativeRoot 'legacy-sql-builder.stderr.log'),$err)
                $legacySuccess=$process.ExitCode -eq 0 -and $out.Trim() -ceq 'CSHARP_NATIVE_BUILDER_WINDOWS_POWERSHELL_PASS' -and -not $err
            }
        }finally{$process.Dispose()}
        Add-CheckResult -Name 'CSharp SQL connection: real Windows PowerShell guest-compatible constructor and credential' -Success $legacySuccess
    }else{Write-Host '  NOT_EXECUTED  CSharp SQL connection: Windows PowerShell unavailable'}
}else{Write-Host '  NOT_EXECUTED  CSharp SQL connection: Windows PowerShell requires Windows'}

. (Join-Path $PSScriptRoot 'CSharpNativeEvidenceChecks.ps1')

. (Join-Path $PSScriptRoot 'CSharpNativeGuestDiagnosticsChecks.ps1')
. (Join-Path $PSScriptRoot 'CSharpNativeTraceFileChecks.ps1')
