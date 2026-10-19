#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$passed=0;$failures=[Collections.Generic.List[string]]::new()
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
foreach($name in @('AuthenticatedTlsRequest','AuthenticatedTlsRegistryIndex','AuthenticatedTlsRootAnchor','AuthenticatedTlsConsumerJournal')){. (Join-Path $repo "Private/$name.ps1")}
$ids=@{OperationId='11111111-1111-4111-8111-111111111111';RunId='22222222-2222-4222-8222-222222222222';ScopeId='33333333-3333-4333-8333-333333333333';VmId='44444444-4444-4444-8444-444444444444';RootDigest=('a'*64);SourceDigest=('b'*64);WorkerDigest=('c'*64)}
function New-ConsumerFixture {
    param([string[]]$Phase=@('PREPARED'))
    $events=@();$previous='0'*64
    foreach($p in $Phase){
        $event=[ordered]@{Sequence=$events.Count;Phase=$p;EffectEntered=($p -cin @('DISPATCHED','REPLY_OBSERVED','RECOVERY_REQUIRED'));PreviousSha256=$previous}
        $previous=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($event|ConvertTo-Json -Compress)))).ToLowerInvariant()
        $events+=,$event
    }
    $doc=[ordered]@{ContractVersion='SqlServerLab.TlsSqlConsumerJournal/0.1'}
    foreach($key in $ids.Keys){$doc[$key]=$ids[$key]};$doc.Events=$events
    return $doc
}
function Get-ConsumerFixtureResult {param($Value) Read-LabTlsSqlConsumerJournal -Utf8Json ([Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 6 -Compress))) @ids}
function Test-ConsumerFixtureRejected {param($Value) $r=Get-ConsumerFixtureResult $Value; -not $r.Success -and $null -eq $r.Value -and $r.ErrorCode -ceq 'TLS_CONSUMER_JOURNAL_INVALID'}
foreach($phases in @(@('PREPARED'),@('PREPARED','ABORTED_NO_EFFECT'),@('PREPARED','DISPATCHED'),@('PREPARED','DISPATCHED','REPLY_OBSERVED'),@('PREPARED','DISPATCHED','RECOVERY_REQUIRED'),@('PREPARED','DISPATCHED','REPLY_OBSERVED','RECOVERY_REQUIRED'))){
    $r=Get-ConsumerFixtureResult (New-ConsumerFixture $phases)
    Add-CheckResult ('TLS-CG closed phase chain '+($phases -join '/')) ($r.Success -and -not $r.Value.MutationAllowed -and -not $r.Value.CleanupAllowed -and -not $r.Value.StopAllowed -and -not $r.Value.RetryAllowed -and $r.Value.ConsumerEnd -ceq 'NOT_PROVEN')
}
foreach($phases in @(@('DISPATCHED'),@('PREPARED','REPLY_OBSERVED'),@('PREPARED','DISPATCHED','PREPARED'),@('PREPARED','DISPATCHED','CLEANED'),@('PREPARED','DISPATCHED','COMPLETED'),@('PREPARED','ABORTED_NO_EFFECT','DISPATCHED'),@('PREPARED','DISPATCHED','RECOVERY_REQUIRED','REPLY_OBSERVED'))){Add-CheckResult 'TLS-CG no replay/forged end transition' (Test-ConsumerFixtureRejected (New-ConsumerFixture $phases))}
foreach($key in $ids.Keys){$d=New-ConsumerFixture;$d[$key]=if($key -like '*Digest'){'d'*64}else{'55555555-5555-4555-8555-555555555555'};Add-CheckResult ('TLS-CG exact binding '+$key) (Test-ConsumerFixtureRejected $d)}
foreach($change in @('Sequence','EffectEntered','PreviousSha256','Extra')){
    $d=New-ConsumerFixture @('PREPARED','DISPATCHED')
    switch($change){'Sequence'{$d.Events[1].Sequence=0};'EffectEntered'{$d.Events[1].EffectEntered=$false};'PreviousSha256'{$d.Events[1].PreviousSha256='f'*64};'Extra'{$d.Events[1].Extra='ignored?'}}
    Add-CheckResult ('TLS-CG invalid event '+$change) (Test-ConsumerFixtureRejected $d)
}
$text=New-ConsumerFixture|ConvertTo-Json -Compress -Depth 6
foreach($invalid in @($text.Replace('"ContractVersion":','"contractversion":'),$text.Replace('"Events":','"Events":[],"Events":'),('['+$text+']'),($text+' ' +$text))){$r=Read-LabTlsSqlConsumerJournal -Utf8Json ([Text.Encoding]::UTF8.GetBytes($invalid)) @ids;Add-CheckResult 'TLS-CG duplicate/case/array/trailing JSON rejected' (-not $r.Success)}
function Invoke-TlsAnchorCaseProbe {
param([string]$SourcePath,[string]$FixtureRoot)
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($SourcePath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'CASE_SOURCE_PARSE'}
$literals=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('public sealed class TlsReadAnchor')},$true))
if($literals.Count -ne 1){throw 'CASE_NATIVE_SOURCE_NOT_UNIQUE'}
$name='TlsCaseProbe'+[guid]::NewGuid().ToString('N')
$code=$literals[0].Value.Replace('TlsReadAnchor',$name)
$createPattern='\[DllImport\("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true\)\]\r?\n        static extern SafeFileHandle CreateFileW'
$finalPattern='\[DllImport\("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true\)\]\r?\n        static extern uint GetFinalPathNameByHandleW'
if([regex]::Matches($code,$createPattern).Count -ne 1 -or [regex]::Matches($code,$finalPattern).Count -ne 1){throw 'CASE_NATIVE_LEAF_NOT_UNIQUE'}
$code=[regex]::Replace($code,$createPattern,('[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, EntryPoint="CreateFileW")]'+"`n"+'        static extern SafeFileHandle CoreCreate'))
$code=[regex]::Replace($code,$finalPattern,('[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, EntryPoint="GetFinalPathNameByHandleW")]'+"`n"+'        static extern uint CoreFinal'))
$proxy=@'
        static readonly Dictionary<IntPtr,string> logicalNames=new Dictionary<IntPtr,string>();
        public static int LogicalFileOpens;
        static SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template) {
            string physical=path;bool mapped=false;
            if(path.EndsWith("\\input.json",StringComparison.Ordinal)){physical=path.Substring(0,path.Length-10)+"lower.bin";mapped=true;}
            else if(path.EndsWith("\\INPUT.json",StringComparison.Ordinal)){physical=path.Substring(0,path.Length-10)+"upper.bin";mapped=true;}
            var handle=CoreCreate(physical,access,share,security,disposition,flags,template);
            if(mapped && !handle.IsInvalid){logicalNames[handle.DangerousGetHandle()]=path;LogicalFileOpens++;}
            return handle;
        }
        static uint GetFinalPathNameByHandleW(SafeFileHandle handle,StringBuilder text,uint capacity,uint flags) {
            string logical;
            if(logicalNames.TryGetValue(handle.DangerousGetHandle(),out logical)){text.Clear();text.Append(logical);return (uint)logical.Length;}
            return CoreFinal(handle,text,capacity,flags);
        }
'@
$code=$code.Replace(($name+'() {}'),($name+'() {}'+"`n"+$proxy))
Add-Type -TypeDefinition $code -ErrorAction Stop
$root=Join-Path $FixtureRoot 'case-model';$null=New-Item -ItemType Directory -Path $root
[IO.File]::WriteAllText((Join-Path $root 'lower.bin'),'synthetic-lower')
[IO.File]::WriteAllText((Join-Path $root 'upper.bin'),'synthetic-upper')
$type=('SqlServerLab.'+$name) -as [type]
$lease=$type::Open($root)
try{
    $lower=[Text.Encoding]::UTF8.GetString($type::Read($lease,'input.json',128))
    $upper=[Text.Encoding]::UTF8.GetString($type::Read($lease,'INPUT.json',128))
    [pscustomobject]@{Lower=$lower;Upper=$upper;DistinctCorrect=($lower -ceq 'synthetic-lower' -and $upper -ceq 'synthetic-upper');LogicalFileOpens=$type::LogicalFileOpens;SourceSha256=(Get-FileHash -LiteralPath $SourcePath).Hash;NativeBoundary='Actual class and Read/cache/handle identity logic; only CreateFile/finalpath leaves map two logical case-only names to two actual own files. No filesystem case flag changed.'}
}finally{$lease.Dispose()}

}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-tls-anchor-'+[guid]::NewGuid().ToString('N'))
$lease=$null;$writer=$null
try {
    $windows=[Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)
    if($windows){
        $case=Invoke-TlsAnchorCaseProbe -SourcePath (Join-Path $repo 'Private/AuthenticatedTlsRootAnchor.ps1') -FixtureRoot $fixture
        Add-CheckResult 'TLS-RA actual cache distinguishes case-only logical file identities' ($case.DistinctCorrect -and $case.LogicalFileOpens -eq 2)
        $root=Join-Path $fixture 'root';$child=Join-Path $root 'metadata';$outside=Join-Path $fixture 'outside'
        $null=New-Item -ItemType Directory -Path $child,$outside
        $inputFile=Join-Path $child 'input.json';[IO.File]::WriteAllText($inputFile,'synthetic-input')
        $journalDir=Join-Path $root 'State/authenticated-tls/sql-completion';$null=New-Item -ItemType Directory -Path $journalDir
        $journalFile=Join-Path $journalDir ($ids.OperationId+'.json')
        [IO.File]::WriteAllText($journalFile,((New-ConsumerFixture @('PREPARED','DISPATCHED','REPLY_OBSERVED'))|ConvertTo-Json -Compress -Depth 6))
        $lease=Open-LabTlsRootAnchor $root
        $status=Get-LabTlsSqlConsumerRecoveryStatus -Anchor $lease @ids
        Add-CheckResult 'TLS-CG actual fixed anchored journal never treats reply as end' ($status.Success -and $status.Value.Status -ceq 'RECOVERY_REQUIRED' -and -not $status.Value.CleanupAllowed)
        $missing=@{};foreach($k in $ids.Keys){$missing[$k]=$ids[$k]};$missing.OperationId='55555555-5555-4555-8555-555555555555'
        $status=Get-LabTlsSqlConsumerRecoveryStatus -Anchor $lease @missing
        Add-CheckResult 'TLS-CG absent journal is unknown rather than no-effect permission' (-not $status.Success -and $null -eq $status.Value)
        $blocked=$false;try{[IO.File]::WriteAllText($journalFile,'{}')}catch [IO.IOException]{$blocked=$true}
        Add-CheckResult 'TLS-CG anchored journal cannot be rewritten while observed' $blocked
        $bytes=Read-LabTlsAnchoredFile $lease 'metadata/input.json' 128
        Add-CheckResult 'TLS-RA actual anchored bytes' ([Text.Encoding]::UTF8.GetString($bytes) -ceq 'synthetic-input')
        $blocked=$false;try{[IO.File]::WriteAllText($inputFile,'overwrite')}catch [IO.IOException]{$blocked=$true}
        Add-CheckResult 'TLS-RA pinned input cannot be written' $blocked
        $blocked=$false;try{[IO.File]::Move($inputFile,($inputFile+'.moved'))}catch [IO.IOException]{$blocked=$true}
        Add-CheckResult 'TLS-RA pinned input cannot be renamed' $blocked
        foreach($dir in @($child,$root)){$blocked=$false;try{[IO.Directory]::Move($dir,($dir+'-moved'))}catch [IO.IOException]{$blocked=$true};Add-CheckResult 'TLS-RA pinned root/ancestor cannot be renamed' $blocked}
        foreach($relative in @('','../input.json','metadata/../input.json','/metadata/input.json','metadata/input.json:stream','metadata/NUL','metadata/input.json.','metadata/input.json ',('x'*4097))){$blocked=$false;try{$null=Read-LabTlsAnchoredFile $lease $relative}catch{$blocked=$true};Add-CheckResult 'TLS-RA invalid relative selector rejected' $blocked}
        $blocked=$false;try{$null=Read-LabTlsAnchoredFile $lease 'metadata/input.json' 1}catch{$blocked=$true};Add-CheckResult 'TLS-RA byte cap enforced on actual file' $blocked
        [SqlServerLab.TlsReadAnchor]::Verify($lease)
        $lease.Dispose();$blocked=$false;try{$null=Read-LabTlsAnchoredFile $lease 'metadata/input.json'}catch{$blocked=$true};Add-CheckResult 'TLS-RA disposed lease rejected' $blocked;$lease=$null
        [IO.File]::WriteAllText($inputFile,'released')
        Add-CheckResult 'TLS-RA own handle release restores write access' ([IO.File]::ReadAllText($inputFile) -ceq 'released')
        $lease=Open-LabTlsRootAnchor $root
        $writer=[IO.File]::Open($inputFile,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
        $blocked=$false;try{$null=Read-LabTlsAnchoredFile $lease 'metadata/input.json'}catch{$blocked=$true};Add-CheckResult 'TLS-RA existing writer blocks read lease' $blocked
        $writer.Dispose();$writer=$null;$lease.Dispose();$lease=$null
        $junction=Join-Path $fixture 'junction';$null=New-Item -ItemType Junction -Path $junction -Target $root
        try{$blocked=$false;try{$lease=Open-LabTlsRootAnchor $junction}catch{$blocked=$true};Add-CheckResult 'TLS-RA actual junction root rejected' $blocked}finally{if($lease){$lease.Dispose();$lease=$null};[IO.Directory]::Delete($junction)}
        $link=Join-Path $child 'hardlink.json';$null=New-Item -ItemType HardLink -Path $link -Target $inputFile
        $lease=Open-LabTlsRootAnchor $root;$blocked=$false;try{$null=Read-LabTlsAnchoredFile $lease 'metadata/input.json'}catch{$blocked=$true};Add-CheckResult 'TLS-RA multiply-linked input rejected' $blocked
        $lease.Dispose();$lease=$null
    }else{
        $blocked=$false;try{$null=Open-LabTlsRootAnchor '/synthetic/root'}catch{$blocked=$_.Exception.Message -ceq 'TLS_ANCHOR_WINDOWS_REQUIRED'}
        Add-CheckResult 'TLS-RA unsupported platform blocks without native I/O' $blocked
        Write-Host 'Windows NTFS handle fixtures NOT_EXECUTED on this platform.'
    }
    Write-Host "Authenticated TLS Consumer Guard: $passed PASS, $($failures.Count) FAIL"
    if($failures.Count){throw 'AUTHENTICATED_TLS_CONSUMER_GUARD_CHECKS_FAILED'}
} finally {
    if($writer){$writer.Dispose()};if($lease){$lease.Dispose()}
    $full=[IO.Path]::GetFullPath($fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '\Asql-lab-tls-anchor-[a-f0-9]{32}\z'){throw 'TLS_ANCHOR_FIXTURE_CLEANUP_BOUNDARY'}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
