#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Common/CSharpNativeEvidenceArchive.ps1')
$parent=Join-Path ([IO.Path]::GetTempPath()) ('csharp-archive-check-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $parent
$passed=0
# Only authorization/ACL adapters are doubled; ZIP, hashes, files and deletion
# execute for real, exclusively under the fresh synthetic parent.
function Get-CSharpNativeEvidence {param($Root,$Commit,$WorkflowRun)[pscustomobject]@{OperationId=(Split-Path $Root -Leaf)}}
function Assert-CSharpNativeProfilePath {param($Path)}
function Assert-CSharpNativeRequestDirectory {param($Path,[switch]$AncestorsOnly)
    if($script:testVolumeRoot -and $Path -eq $script:testVolumeRoot -and -not $AncestorsOnly){throw 'Volume root must be validated as an ancestor'}
}
function Get-CSharpNativeRequestVolumeRoot {$script:testVolumeRoot}
function New-CSharpNativeTemporaryDirectory {param($Path,[switch]$CurrentIdentityRead)
    # Match CreateDirectoryW: it cannot create absent parents recursively.
    if(-not(Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($Path)))){throw 'Missing native directory parent'}
    $null=New-Item -ItemType Directory -Path $Path
}
function Read-CSharpNativeRequestBytes {param($Path,$ExpectedHash)
    if((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedHash){throw 'Synthetic request hash mismatch'}
}
try{
    foreach($scenario in @('success','first-run','failed-completed','cleanup-unknown','commit-drift','link','collision')){
        $root=Join-Path $parent ('csharp-native-'+[guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory -Path $root
        $commit='a'*40
        $receipt=[pscustomobject]@{Contract='SqlServerLab.CSharpNativeAcceptance/1.0';Commit=$commit;Status=$(if($scenario -eq 'failed-completed'){'FAILED'}else{'PASSED'});CleanupFailure=$(if($scenario -eq 'cleanup-unknown'){'UNCONFIRMED'}else{$null});EvidenceFailure=$null}
        if($scenario -eq 'commit-drift'){$receipt.Commit='b'*40}
        $receipt|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root 'receipt.json')
        $payload=Join-Path $root 'payload.bin';[IO.File]::WriteAllBytes($payload,[byte[]](1,2,3,255))
        $archiveParent=Join-Path $parent 'archive';$null=New-Item -ItemType Directory -Path $archiveParent -Force
        if($scenario -eq 'first-run'){
            $script:testVolumeRoot=Join-Path $parent 'synthetic-volume';$null=New-Item -ItemType Directory -Path $script:testVolumeRoot
            $archiveParent=Join-Path $script:testVolumeRoot 'SqlServerLab-CSharpEvidenceArchive'
        }
        $archive=Join-Path $archiveParent ((Split-Path $root -Leaf)+'.zip')
        if($scenario -eq 'collision'){[IO.File]::WriteAllText($archive,'preserve')}
        $foreign=Join-Path $parent 'foreign';$null=New-Item -ItemType Directory -Path $foreign -Force
        Set-Content -LiteralPath (Join-Path $foreign 'sentinel') -Value 'preserve'
        $link=Join-Path $root 'linked'
        if($scenario -eq 'link'){$kind=if($IsWindows){'Junction'}else{'SymbolicLink'};$null=New-Item -ItemType $kind -Path $link -Target $foreign}
        $blocked=$false
        try{
            if($scenario -eq 'first-run'){$result=Complete-CSharpNativeEvidence -Root $root -Commit $commit -WorkflowRun 123}
            else{$result=Complete-CSharpNativeEvidence -Root $root -Commit $commit -WorkflowRun 123 -ArchiveParent $archiveParent}
        }catch{$blocked=$true}
        $shouldArchive=$scenario -in @('success','first-run','failed-completed')
        if($blocked -eq $shouldArchive -or (Test-Path -LiteralPath $root) -eq $shouldArchive){throw "Archive disposition wrong: $scenario"}
        if($shouldArchive){
            $zip=[IO.Compression.ZipFile]::OpenRead($archive)
            try{if($zip.Entries.Count -ne 2 -or $zip.GetEntry('payload.bin').Length -ne 4){throw 'Archived payload missing'}}finally{$zip.Dispose()}
        }
        if($scenario -eq 'collision' -and [IO.File]::ReadAllText($archive) -cne 'preserve'){throw 'Existing archive changed'}
        if($scenario -eq 'link'){Remove-Item -LiteralPath $link -Force;if((Get-Content -LiteralPath (Join-Path $foreign 'sentinel') -Raw).Trim() -cne 'preserve'){throw 'Foreign target changed'}}
        $passed++
    }
    & {
        $scriptPath=Join-Path $PSScriptRoot '../Integration/Invoke-CSharpNativeRequestAcceptance.ps1'
        $ast=[Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$null,[ref]$null)
        $outer=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst] -and $_.Finally.Extent.Text -match 'Complete-CSharpNativeEvidence'})
        if($outer.Count -ne 1){throw 'Request wrapper cleanup boundary changed'}
        $body=$outer[0].Finally.Extent.Text;$actualFinally=[scriptblock]::Create($body.Substring(1,$body.Length-2))
        function Complete-CSharpNativeEvidence {param($Root,$Commit,$WorkflowRun)$script:archiveCalls++;[pscustomobject]@{Status='ARCHIVED'}}
        function Remove-CSharpNativeConsumedRequest {param($RequestPath,$ExpectedHash)$script:requestCalls++}
        $evidenceRoot=Join-Path $parent 'wrapper';$null=New-Item -ItemType Directory -Path $evidenceRoot
        Set-Content -LiteralPath (Join-Path $evidenceRoot 'receipt.json') -Value '{}'
        $requestPath='synthetic';$RequestSha256='a'*64
        foreach($key in @('none','ProfileCleanupFailure','RecoveryRecordFailure','CleanupFailure','EvidenceFailure')){
            $failure=$null
            if($key -ne 'none'){
                $exception=[InvalidOperationException]::new('synthetic primary failure');$exception.Data[$key]='synthetic recovery failure'
                $failure=[Management.Automation.ErrorRecord]::new($exception,'test',[Management.Automation.ErrorCategory]::OperationStopped,$null)
            }
            $script:archiveCalls=0;$script:requestCalls=0
            . $actualFinally
            $expected=if($key -eq 'none'){1}else{0}
            if($script:archiveCalls -ne $expected -or $script:requestCalls -ne $expected){throw "Outer recovery state was not preserved: $key"}
            $script:wrapperChecks++
        }
    }
    $passed+=$script:wrapperChecks
    foreach($scenario in @('consumed','changed','extra-content')){
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('synthetic'))).ToLowerInvariant()
        $requestRoot=Join-Path $parent ('SqlServerLab-CSharpRequest-'+$hash)
        $null=New-Item -ItemType Directory -Path $requestRoot -Force
        $request=Join-Path $requestRoot 'request.json';[IO.File]::WriteAllText($request,$(if($scenario -eq 'changed'){'foreign'}else{'synthetic'}))
        if($scenario -eq 'extra-content'){Set-Content -LiteralPath (Join-Path $requestRoot 'foreign') -Value 'preserve'}
        $blocked=$false;try{Remove-CSharpNativeConsumedRequest -RequestPath $request -ExpectedHash $hash}catch{$blocked=$true}
        if($blocked -ne ($scenario -ne 'consumed') -or (Test-Path -LiteralPath $requestRoot) -ne $blocked){throw "Request disposition wrong: $scenario"}
        if(Test-Path -LiteralPath $requestRoot){Remove-Item -LiteralPath $requestRoot -Recurse -Force}
        $passed++
    }
}finally{Remove-Item -LiteralPath $parent -Recurse -Force}
Write-Host "CSHARP NATIVE EVIDENCE ARCHIVE: PASS ($passed scenarios; exact payload retained, recovery preserved)"
