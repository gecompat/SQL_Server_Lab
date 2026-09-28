# Synthetic evidence only; no SQL, VM, real profile or runtime input.
. (Join-Path $repoRoot 'Tests/Common/CSharpNativeEvidence.ps1')
& {
    $collision=Join-Path $nativeRoot 'output-collision';$null=[IO.Directory]::CreateDirectory($collision)
    $existing=Join-Path $collision 'worker.stdout.log';[IO.File]::WriteAllText($existing,'preserve synthetic log')
    $started=Join-Path $collision 'started';$worker=Join-Path $collision 'worker.ps1'
    [IO.File]::WriteAllText($worker,'param($PlanPath) [IO.File]::WriteAllText($PlanPath,"unexpected start")')
    $caught=$null
    try{Invoke-CSharpNativeChild -Worker $worker -PlanPath $started -OutputRoot $collision -TimeoutSeconds 2}catch{$caught=$_}
    Add-CheckResult -Name 'CSharp evidence: actual output collision preserves log and never starts child' -Success ($caught -and $caught.Exception.Data['EvidenceFailure'] -ceq 'CSHARP_NATIVE_EVIDENCE_OUTPUT_FAILED' -and $caught.Exception.Data['CSharpChildTerminated'] -eq $true -and -not(Test-Path -LiteralPath $started) -and [IO.File]::ReadAllText($existing) -ceq 'preserve synthetic log')
}
& {
    # Execute the actual supervisor receipt-write/catch block with a synthetic failing writer.
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tests/Integration/Invoke-CSharpHyperVAcceptance.ps1'),[ref]$null,[ref]$null)
    $receiptTry=$ast.Find({param($node)$node -is [Management.Automation.Language.TryStatementAst] -and $node.Body.Extent.Text -match '^\{\$receipt\|ConvertTo-Json\|Set-Content'},$true)
    function Set-Content {[CmdletBinding()]param([Parameter(ValueFromPipeline)]$Value,$LiteralPath)process{throw 'synthetic private receipt failure'}}
    foreach($prior in @($null,'CSHARP_NATIVE_CHILD_TIMEOUT')){
        $failure=$prior;$cleanupFailure='CSHARP_NATIVE_OWNED_RUN_CLEANUP_FAILED';$evidenceFailure=$null
        $root=$nativeRoot;$receipt=[pscustomobject]@{Status='FAILED'}
        . ([scriptblock]::Create($receiptTry.Extent.Text))
        Add-CheckResult -Name ('CSharp evidence: actual receipt failure preserves cleanup and prior='+[bool]$prior) -Success ($failure -ceq $(if($prior){$prior}else{'CSHARP_NATIVE_EVIDENCE_RECEIPT_FAILED'}) -and $cleanupFailure -ceq 'CSHARP_NATIVE_OWNED_RUN_CLEANUP_FAILED' -and $evidenceFailure -ceq 'CSHARP_NATIVE_EVIDENCE_RECEIPT_FAILED')
    }
}
& {
    $streamRoot=Join-Path $nativeRoot 'live-stream';$null=[IO.Directory]::CreateDirectory($streamRoot)
    $worker=Join-Path $streamRoot 'worker.ps1';$gate=Join-Path $streamRoot 'release'
    [IO.File]::WriteAllText($worker,'param($PlanPath) [Console]::Out.WriteLine("synthetic live output"); [Console]::Out.Flush(); $deadline=[datetime]::UtcNow.AddSeconds(20); while(-not [IO.File]::Exists($PlanPath) -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}; if(-not [IO.File]::Exists($PlanPath)){exit 9}')
    $supervisor=Join-Path $streamRoot 'supervisor.ps1'
    [IO.File]::WriteAllText($supervisor,'param($Helper,$Worker,$Gate,$Root) $ErrorActionPreference="Stop"; . $Helper; $result=Invoke-CSharpNativeChild -Worker $Worker -PlanPath $Gate -OutputRoot $Root -TimeoutSeconds 25; exit $result.ExitCode')
    $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($arg in @('-NoProfile','-File',$supervisor,'-Helper',(Join-Path $repoRoot 'Tests/Common/CSharpNativeAcceptance.ps1'),'-Worker',$worker,'-Gate',$gate,'-Root',$streamRoot)){$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$visible=$false;$ended=$false;$terminated=$false
    try{
        $null=$process.Start();$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
        $deadline=[datetime]::UtcNow.AddSeconds(15);$path=Join-Path $streamRoot 'worker.stdout.log'
        while([datetime]::UtcNow -lt $deadline -and -not $process.HasExited){
            if([IO.File]::Exists($path)){
                $read=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
                try{$reader=[IO.StreamReader]::new($read);try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$read.Dispose()}
                if($text.Contains('synthetic live output')){$visible=-not $process.HasExited;break}
            }
            Start-Sleep -Milliseconds 50
        }
        [IO.File]::WriteAllText($gate,'release synthetic child')
        $terminated=$process.WaitForExit(15000);$ended=$terminated -and $process.ExitCode -eq 0
    }finally{
        if(-not $terminated){try{$process.Kill($true);$terminated=$process.WaitForExit(15000)}catch{$terminated=$false}}
        $process.Dispose()
    }
    Add-CheckResult -Name 'CSharp evidence: actual output visible before child exit and bounded cleanup' -Success ($visible -and $ended -and $terminated)
}
Add-CheckResult -Name 'CSharp evidence: read grant is explicit optional internal switch' -Success ((Get-Command New-CSharpNativeTemporaryDirectory).Parameters.ContainsKey('CurrentIdentityRead') -and (Get-Command Write-CSharpNativeTemporaryProfile).Parameters.ContainsKey('CurrentIdentityRead'))
& {
    $volume=Join-Path $nativeRoot 'evidence-volume';$null=[IO.Directory]::CreateDirectory($volume)
    function Get-CSharpNativeRequestVolumeRoot {$volume}
    function Assert-CSharpNativeRequestDirectory {param($Path) Assert-CSharpNativeLocalPath $Path}
    function Assert-CSharpNativeProfilePath {param($Path) Assert-CSharpNativeLocalPath $Path}
    function New-CSharpNativeTemporaryDirectory {param($Path,[switch]$CurrentIdentityRead) if(Test-Path -LiteralPath $Path){throw 'COLLISION'};$null=[IO.Directory]::CreateDirectory($Path)}
    function Write-CSharpNativeTemporaryProfile {param($Owned,$Json,[switch]$CurrentIdentityRead) $stream=[IO.File]::Open($Owned.File,[IO.FileMode]::CreateNew);try{$bytes=[Text.Encoding]::UTF8.GetBytes($Json);$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}
    $root=New-CSharpNativeEvidence -Commit ('a'*40) -WorkflowRun '123'
    $binding=Get-CSharpNativeEvidence $root ('a'*40) '123'
    Add-CheckResult -Name 'CSharp evidence: real bounded marker parser binds commit/run/operation' -Success ($binding.OperationId -cmatch '^csharp-native-[a-f0-9]{32}$')
    foreach($case in @('Commit','WorkflowRun','OperationId','Extra','Malformed','Oversized')){
        $copy=$binding.PSObject.Copy()
        switch($case){'Commit'{$copy.Commit='b'*40};'WorkflowRun'{$copy.WorkflowRun='124'};'OperationId'{$copy.OperationId='csharp-native-'+('f'*32)};'Extra'{$copy|Add-Member extra bad}}
        $json=$copy|ConvertTo-Json -Compress
        if($case -eq 'Malformed'){$json='{'};if($case -eq 'Oversized'){$json='x'*4097}
        [IO.File]::WriteAllText((Join-Path $root 'binding.json'),$json)
        $caught='';try{Get-CSharpNativeEvidence $root ('a'*40) '123'|Out-Null}catch{$caught=$_.Exception.Message}
        Add-CheckResult -Name ('CSharp evidence: rejects marker '+$case) -Success ($caught -ceq 'CSHARP_NATIVE_EVIDENCE_BINDING')
    }
    [IO.File]::WriteAllText((Join-Path $root 'binding.json'),($binding|ConvertTo-Json -Compress))
    $null=Claim-CSharpNativeEvidence $root ('a'*40) '123'
    $caught='';try{Claim-CSharpNativeEvidence $root ('a'*40) '123'|Out-Null}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name 'CSharp evidence: exclusive claim blocks replay without replacing marker' -Success ($caught -ceq 'CSHARP_NATIVE_EVIDENCE_ALREADY_CLAIMED' -and [IO.File]::ReadAllText((Join-Path $root 'supervisor.claim')) -ceq $binding.OperationId)
    function New-CSharpNativeTemporaryDirectory {param($Path) throw 'synthetic private collision'}
    $caught='';try{New-CSharpNativeEvidence ('a'*40) '123'}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name 'CSharp evidence: atomic creation collision is sanitized, no adoption' -Success ($caught -ceq 'CSHARP_NATIVE_EVIDENCE_CREATE')
    function Assert-CSharpNativeRequestDirectory {param($Path) throw 'CSHARP_NATIVE_REPARSE_POINT'}
    $caught='';try{Get-CSharpNativeEvidence $root ('a'*40) '123'}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name 'CSharp evidence: reparse/ACL guard failure rejects existing root' -Success ($caught -ceq 'CSHARP_NATIVE_EVIDENCE_BINDING')
    # A subsequent checkout/temp cleanup cannot delete this distinct durable location.
    foreach($name in @('checkout','runner-temp')){
        $other=Join-Path $nativeRoot $name;$null=[IO.Directory]::CreateDirectory($other)
        [IO.Directory]::Delete($other,$false)
    }
    Add-CheckResult -Name 'CSharp evidence: receipt survives separate checkout/temp cleanup' -Success ([IO.File]::Exists((Join-Path $root 'binding.json')))
}
try{throw (New-CSharpNativeFailureException -PrimaryFailure 'CSHARP_NATIVE_CHILD_TIMEOUT' -CleanupFailure 'CSHARP_NATIVE_OWNED_RUN_CLEANUP_FAILED' -EvidenceFailure 'synthetic private evidence path')}catch{$diagnostic=Get-CSharpNativeRequestFailureDiagnostic $_}
Add-CheckResult -Name 'CSharp evidence: evidence fault preserves primary/run-cleanup and sanitizes detail' -Success ($diagnostic.PrimaryFailure -ceq 'CSHARP_NATIVE_CHILD_TIMEOUT' -and $diagnostic.CleanupFailure -ceq 'CSHARP_NATIVE_OWNED_RUN_CLEANUP_FAILED' -and $diagnostic.EvidenceFailure -ceq 'CSHARP_NATIVE_UNCLASSIFIED_FAILURE' -and $diagnostic.RecoveryRequired)
$evidenceWrapper=Get-Content (Join-Path $repoRoot 'Tests/Integration/Invoke-CSharpNativeRequestAcceptance.ps1') -Raw
$evidenceSupervisor=Get-Content (Join-Path $repoRoot 'Tests/Integration/Invoke-CSharpHyperVAcceptance.ps1') -Raw
Add-CheckResult -Name 'CSharp evidence: guarded wrapper allocates once before request and passes root internally' -Success ($evidenceWrapper.IndexOf('Assert-CSharpNativeCheckout') -lt $evidenceWrapper.IndexOf('$evidenceRoot=New-CSharpNativeEvidence') -and $evidenceWrapper.IndexOf('$evidenceRoot=New-CSharpNativeEvidence') -lt $evidenceWrapper.IndexOf('$volume=Get-CSharpNativeRequestVolumeRoot') -and $evidenceWrapper.Contains('-EvidenceRoot $evidenceRoot') -and $evidenceWrapper.Contains('*> $localLog') -and $evidenceSupervisor.Contains('$root=$EvidenceRoot') -and $evidenceSupervisor -notmatch '\.artifacts/test-runs')
if(-not $IsWindows -or -not $profileEvidenceElevated){
    Write-Host '  NOT_EXECUTED  CSharp evidence: real durable protected root (elevated Windows required)'
}else{
    $root=$null;$good=$false;$cleanupGood=$false
    try {
        $root=New-CSharpNativeEvidence ('a'*40) '123'
        $binding=Get-CSharpNativeEvidence $root ('a'*40) '123'
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $grants=@((Get-Acl -LiteralPath $root).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.IdentityReference -eq $identity.User -and $_.AccessControlType -eq 'Allow'})
            $fileGrants=@((Get-Acl -LiteralPath (Join-Path $root 'binding.json')).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.IdentityReference -eq $identity.User -and $_.AccessControlType -eq 'Allow'})
            $good=$binding.Commit -ceq ('a'*40) -and $grants.Count -eq 1 -and $fileGrants.Count -eq 1 -and
                ($grants[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [Security.AccessControl.FileSystemRights]::ReadAndExecute -and
                ($fileGrants[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::Read) -eq [Security.AccessControl.FileSystemRights]::Read -and
                ([long]$grants[0].FileSystemRights -band 0x500D0156) -eq 0 -and ([long]$fileGrants[0].FileSystemRights -band 0x500D0156) -eq 0
        } finally {$identity.Dispose()}
    }catch{$good=$false}
    finally{
        if($root){
            try {
                $null=Get-CSharpNativeEvidence $root ('a'*40) '123'
                [IO.File]::Delete((Join-Path $root 'binding.json'))
                [IO.Directory]::Delete($root,$false)
                $cleanupGood=-not(Test-Path -LiteralPath $root)
            }catch{$cleanupGood=$false}
        }
    }
    Add-CheckResult -Name 'CSharp evidence: real durable protected root and exact synthetic cleanup' -Success ($good -and $cleanupGood)
}
