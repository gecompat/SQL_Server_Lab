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
'param($PlanPath) Start-Sleep -Seconds 30'|Set-Content $syntheticWorker
$caught='';$terminated=$false
try{Invoke-CSharpNativeChild -Worker $syntheticWorker -PlanPath $syntheticFile -OutputRoot $nativeRoot -TimeoutSeconds 1}catch{$caught=$_.Exception.Message;$terminated=$_.Exception.Data['CSharpChildTerminated']}
Add-CheckResult -Name 'CSharp native: echter Timeout bestätigt Kindprozessende vor Cleanup' -Success ($caught -ceq 'CSHARP_NATIVE_CHILD_TIMEOUT' -and $terminated)
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
    $nativeWorkflow.Contains('timeout-minutes: 180') -and $nativeWorkflow.Contains('*> $localLog'))
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
$inputReferences=@([regex]::Matches($nativeWorkflow,'inputs\.([a-z_]+)')|ForEach-Object {$_.Groups[1].Value})
Add-CheckResult -Name 'CSharp profile: Workflow überträgt ausschließlich festen Profilnamen' -Success (
    $inputReferences.Count -eq 1 -and $inputReferences[0] -ceq 'profile' -and $nativeWorkflow.Contains('options: [csharp-sql2025]') -and
    $nativeWorkflow.Contains('-Profile $env:CSHARP_PROFILE *> $localLog') -and $nativeWorkflow -notmatch 'SQL_SERVER_LAB_CSHARP_PROFILE_ROOT|payload_root:|state_root:|media_root:|sql_media_path:')

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
