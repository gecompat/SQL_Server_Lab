param([Parameter(Mandatory)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$sourcePaths=@('Private/SmtpTestServiceMimeProcess.ps1','Tests/Static/Fixtures/SmtpTestServiceMimeParentChecks.ps1','Tests/Static/Invoke-SmtpTestServiceMimeParentChecks.ps1','Tools/SmtpTestServiceMime.py','Tools/Initialize-SqlServerLabHostTools.ps1','Private/HostToolResolution.ps1')
$before=@{}
$passed=0;$failed=0;$runtimeChildren=0;$records=[Collections.Generic.List[object]]::new();$temp=$null;$python=$null;$pythonSHA=$null;$pythonVersion=$null;$tempRetained=$false;$inventoryBound=$false;$recoveryRequired=$false;$tempFailure=$null;$generated=[Collections.Generic.List[object]]::new();$tempInventory=@();$tempInventorySHA=$null
$savedProcessPath=[Environment]::GetEnvironmentVariable('PATH','Process')
function Assert-Focal($Condition){if(-not $Condition){throw 'MIME_PARENT_FIXTURE_ASSERTION_FAILED'}}
function Read-FocalFailure([Management.Automation.ErrorRecord]$ErrorRecord){
    $allowed=@('MIME_PARENT_FIXTURE_ASSERTION_FAILED','MIME_PARENT_FIXTURE_FAILED','MIME_PARENT_TEMP_BOUNDARY','MIME_PARENT_TEMP_CUSTODY_UNKNOWN','SMTP_MIME_PROCESS_BUSY','SMTP_MIME_PROCESS_RECOVERY_REQUIRED','SMTP_MIME_RUNTIME_UNAVAILABLE','SMTP_MIME_RESPONSE_INVALID','SMTP_MIME_PROCESS_INVALID','SMTP_MIME_PROCESS_TIMEOUT','SMTP_MIME_PROCESS_OUTPUT_LIMIT','SMTP_MIME_PROCESS_FAILED','SMTP_MIME_PROCESS_TERMINATION_UNKNOWN','SMTP_MIME_PROCESS_CLEANUP_FAILED','SMTP_MIME_INPUT_INVALID','SMTP_MIME_LIMIT_EXCEEDED','SMTP_MIME_INVALID','SMTP_MIME_INVALID_ENCODING','SMTP_MIME_UNSUPPORTED_CHARSET','SMTP_MIME_UNSUPPORTED_ENCODING','SMTP_MIME_UNSUPPORTED_ADDRESS','SMTP_MIME_PARSE_FAILED','SMTP_MIME_TIMEOUT')
    $code=if($ErrorRecord.Exception.Message -cin $allowed){$ErrorRecord.Exception.Message}else{'MIME_PARENT_FIXTURE_FAILED'}
    $observed=$null;$cleanupCode=$null;$fault=$false
    if($ErrorRecord.Exception.Data.Contains('SqlServerLab.SmtpMimeCustody')){
        $c=$ErrorRecord.Exception.Data['SqlServerLab.SmtpMimeCustody']
        if($c -is [pscustomobject]){
            $r=$c.PSObject.Properties['RecoveryRequired'];$f=$c.PSObject.Properties['CleanupFailureCode']
            if($null -ne $r -and $r.MemberType -eq 'NoteProperty' -and $r.Value -is [bool] -and $null -ne $f -and $f.MemberType -eq 'NoteProperty' -and ($null -eq $f.Value -or ($f.Value -is [string] -and $f.Value -cin @('SMTP_MIME_PROCESS_TERMINATION_UNKNOWN','SMTP_MIME_PROCESS_CLEANUP_FAILED'))) -and ($r.Value -eq ($null -ne $f.Value))){$observed=$r.Value;$cleanupCode=$f.Value}else{$fault=$true}
        }else{$fault=$true}
    }
    if($observed -eq $true -or $fault){$script:recoveryRequired=$true}
    return [ordered]@{Code=$code;CustodyRecoveryObserved=$observed;CleanupCode=$cleanupCode;CustodyProjectionFault=$fault}
}
function Expect-Fixed($Code,[scriptblock]$Action){
    $caught=$null;try{$null=& $Action}catch{$projection=Read-FocalFailure $_;$caught=$projection.Code}
    Assert-Focal ($caught -ceq $Code)
}
function Case([string]$Id,[scriptblock]$Action){
    try{& $Action;$script:passed++;$script:records.Add([ordered]@{Id=$Id;Status='PASS'})}
    catch{$script:failed++;$p=Read-FocalFailure $_;$script:records.Add([ordered]@{Id=$Id;Status='FAIL';Code=$p.Code;CleanupCode=$p.CleanupCode;CustodyRecoveryObserved=$p.CustodyRecoveryObserved;CustodyProjectionFault=$p.CustodyProjectionFault})}
}
function Assert-OwnTempBoundary {
    param([switch]$BeforeCreate)
    $full=[IO.Path]::GetFullPath($script:temp);$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^smtp-mime-parent-[a-f0-9]{32}$'){throw 'MIME_PARENT_TEMP_BOUNDARY'}
    $ancestor=if($BeforeCreate){[IO.Path]::GetDirectoryName($full)}else{$full}
    while($ancestor){$entry=Get-Item -LiteralPath $ancestor -Force;if(-not $entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)-ne0){throw 'MIME_PARENT_TEMP_BOUNDARY'};$parent=[IO.Path]::GetDirectoryName($ancestor);if($parent -ceq $ancestor){break};$ancestor=$parent}
    if($IsWindows -and -not $BeforeCreate){$owner=(Get-Acl -LiteralPath $full).GetOwner([Security.Principal.SecurityIdentifier]);if($owner.Value -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'MIME_PARENT_TEMP_BOUNDARY'}}
}
function New-OwnStart([string]$File){
    $s=[Diagnostics.ProcessStartInfo]::new();$s.FileName=$script:python;$s.UseShellExecute=$false;$s.CreateNoWindow=$true;$s.WorkingDirectory=$script:temp
    $s.RedirectStandardInput=$true;$s.RedirectStandardOutput=$true;$s.RedirectStandardError=$true;$s.Environment.Clear()
    foreach($n in @('SystemRoot','WINDIR','ComSpec')){$v=[Environment]::GetEnvironmentVariable($n);if($null -ne $v){$s.Environment[$n]=$v}}
    foreach($v in @('-I','-B',$File)){$s.ArgumentList.Add($v)};return $s
}
function Child([string]$Name,[string]$Program,[byte[]]$OwnedBytes,[int]$Limit){
    # Fixed synthetic programs only, in the new owned fixture scope; never mail files.
    Assert-OwnTempBoundary
    if($Name -cnotmatch '^[A-Za-z]+$'){throw 'MIME_PARENT_TEMP_BOUNDARY'}
    $file=Join-Path $script:temp ($Name+'.py');$codeBytes=[Text.UTF8Encoding]::new($false).GetBytes($Program)
    if($codeBytes.Length -gt 4096 -or $script:generated.Count -ge 16){throw 'MIME_PARENT_TEMP_BOUNDARY'}
    $stream=[IO.File]::Open($file,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($codeBytes,0,$codeBytes.Length);$stream.Flush($true)}finally{$stream.Dispose();[Array]::Clear($codeBytes,0,$codeBytes.Length)}
    $script:generated.Add([ordered]@{Name=($Name+'.py');SHA=(Get-FileHash -LiteralPath $file).Hash;Bytes=(Get-Item -LiteralPath $file).Length})
    $script:runtimeChildren++
    try{return ,(Invoke-LabSmtpMimeByteProcess (New-OwnStart $file) $OwnedBytes $Limit)}
    catch{$null=Read-FocalFailure $_;throw}
}
function New-ValidDecoded{
    [ordered]@{SchemaVersion=1;Subject=$null;From=$null;To=$null;MissingHeaders=@('Subject','From','To');BodyKind='PLAIN_TEXT';BodyStatus='TEXT';Body='synthetic';SelectionRule='LEAF';PartCount=1;IgnoredPartCount=0}
}
function To-Bytes($Value){return ,([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Value -Depth 6 -Compress)))}
try{
    . (Join-Path $RepoRoot 'Private/SmtpTestServiceMimeProcess.ps1')
    foreach($p in $sourcePaths){$before[$p]=(Get-FileHash -LiteralPath (Join-Path $RepoRoot $p)).Hash}
    Case 'MP01_SELECTOR_PRESTART' {
        foreach($v in @($null,'','decoded','MIME','Summary',@('Decoded'),1)){
            Expect-Fixed 'SMTP_MIME_INPUT_INVALID' {Invoke-LabSmtpTestServiceMimeProjection -Format $v -InputBytes ([byte[]]::new(0))}
        }
    }
    Case 'MP02_INPUT_PRESTART' {
        foreach($v in @($null,'','text',@([byte]1))){Expect-Fixed 'SMTP_MIME_INPUT_INVALID' {Invoke-LabSmtpTestServiceMimeProjection 'Mime' $v}}
        foreach($pair in @(@('Decoded',1048577),@('Mime',8388609))){
            $b=[byte[]]::new($pair[1]);try{Expect-Fixed 'SMTP_MIME_LIMIT_EXCEEDED' {Invoke-LabSmtpTestServiceMimeProjection $pair[0] $b}}finally{[Array]::Clear($b,0,$b.Length)}
        }
    }
    Case 'MP03_DTO_CLOSED_TYPES' {
        $b=To-Bytes (New-ValidDecoded);try{$v=Read-LabSmtpMimeDecodedBytes $b;Assert-Focal ($v.BodyKind -ceq 'PLAIN_TEXT')}finally{[Array]::Clear($b,0,$b.Length)}
        $v=New-ValidDecoded;$v.BodyKind=$null;$v.Body=$null;$v.BodyStatus='NO_READABLE_BODY';$v.SelectionRule='RELATED_ROOT';$v.IgnoredPartCount=1
        $b=To-Bytes $v;try{$v=Read-LabSmtpMimeDecodedBytes $b;Assert-Focal ($null -eq $v.BodyKind -and $v.SelectionRule -ceq 'RELATED_ROOT')}finally{[Array]::Clear($b,0,$b.Length)}
        foreach($n in @('SchemaVersion','PartCount','Body','BodyKind','BodyStatus','SelectionRule')){
            $v=New-ValidDecoded;$v[$n]=@($v[$n]);$b=To-Bytes $v
            try{Expect-Fixed 'SMTP_MIME_RESPONSE_INVALID' {Read-LabSmtpMimeDecodedBytes $b}}finally{[Array]::Clear($b,0,$b.Length)}
        }
        $b=[Text.Encoding]::UTF8.GetBytes('{"SchemaVersion":1,"schemaversion":1}')
        try{Expect-Fixed 'SMTP_MIME_RESPONSE_INVALID' {Read-LabSmtpMimeDecodedBytes $b}}finally{[Array]::Clear($b,0,$b.Length)}
    }
    Case 'MP04_DTO_SEMANTIC_PAIRS' {
        foreach($mutation in @('Missing','BodyNull','WrongEmpty','WrongCount','WrongRule')){
            $v=New-ValidDecoded
            switch($mutation){'Missing'{$v.MissingHeaders=@()};'BodyNull'{$v.Body=$null};'WrongEmpty'{$v.BodyStatus='EMPTY_TEXT'};'WrongCount'{$v.IgnoredPartCount=1};'WrongRule'{$v.SelectionRule='ALTERNATIVE_LAST_HTML'}}
            $b=To-Bytes $v;try{Expect-Fixed 'SMTP_MIME_RESPONSE_INVALID' {Read-LabSmtpMimeDecodedBytes $b}}finally{[Array]::Clear($b,0,$b.Length)}
        }
    }
    # Every new test process resolves Python centrally; no installation or provider probe.
    $resolved=@(& (Join-Path $RepoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name python)
    Assert-Focal ($resolved.Count -eq 1 -and $resolved[0].Available -is [bool] -and $resolved[0].Available)
    $python=$resolved[0].Invocation;Assert-Focal ([IO.Path]::IsPathRooted($python));$pythonSHA=(Get-FileHash -LiteralPath $python).Hash
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('smtp-mime-parent-'+[guid]::NewGuid().ToString('N'));Assert-OwnTempBoundary -BeforeCreate;$null=New-Item -ItemType Directory -Path $temp
    if($IsWindows){$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User;$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false);$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'));Set-Acl -LiteralPath $temp -AclObject $acl}
    Assert-OwnTempBoundary
    Case 'MP05_ACTUAL_RUNTIME' {
        $b=Child 'version' "import sys`nsys.stdout.write('.'.join(map(str,sys.version_info[:3])))`n" ([byte[]]::new(0)) 128
        try{$script:pythonVersion=[Text.UTF8Encoding]::new($false,$true).GetString($b);Assert-Focal ($script:pythonVersion -cmatch '^\d+\.\d+\.\d+$')}finally{[Array]::Clear($b,0,$b.Length)}
    }
    Case 'MP06_REAL_RAW_BINARY' {
        $b=[byte[]]@(0,255,128,13,10,1);$expected=[byte[]]$b.Clone();$out=$null
        try{$script:runtimeChildren++;$out=Invoke-LabSmtpTestServiceMimeProjection 'Mime' $b;Assert-Focal ($out -is [byte[]] -and [Linq.Enumerable]::SequenceEqual[byte]($out,$expected));Assert-Focal ([Linq.Enumerable]::SequenceEqual[byte]($b,$expected))}
        finally{foreach($v in @($b,$expected,$out)){if($null-ne$v){[Array]::Clear($v,0,$v.Length)}}}
    }
    Case 'MP07_REAL_DECODED_PLAIN_HTML' {
        $domain='example.invalid';$sender='sender'+'@'+$domain;$receiver='receiver'+'@'+$domain
        foreach($type in @('text/plain','text/html')){
            $b=[Text.Encoding]::UTF8.GetBytes("Subject: synthetic`r`nFrom: $sender`r`nTo: $receiver`r`nContent-Type: $type; charset=utf-8`r`n`r`nsynthetic")
            try{$script:runtimeChildren++;$v=Invoke-LabSmtpTestServiceMimeProjection 'Decoded' $b;Assert-Focal ($v.Body -ceq 'synthetic' -and $v.BodyKind -ceq $(if($type -ceq 'text/plain'){'PLAIN_TEXT'}else{'HTML_SOURCE'}))}
            finally{[Array]::Clear($b,0,$b.Length);$v=$null}
        }
    }
    Case 'MP08_ASYNC_DUPLEX_AND_INPUT_CLEAR' {
        $b=[byte[]]::new(131072);$b[0]=255;$out=$null
        try{$out=Child 'duplex' "import sys`nwhile True:`n b=sys.stdin.buffer.read(4096)`n if not b: break`n sys.stdout.buffer.write(b)`n sys.stdout.buffer.flush()`n" $b 131072;Assert-Focal ($out.Length -eq 131072 -and $out[0] -eq 255 -and @($b|Where-Object{$_ -ne 0}).Count -eq 0)}finally{[Array]::Clear($b,0,$b.Length);if($out){[Array]::Clear($out,0,$out.Length)}}
    }
    Case 'MP09_OUTPUT_LIMIT_PAIR' {
        $out=Child 'exact' "import sys`nsys.stdout.buffer.write(b'x'*4096)`n" ([byte[]]::new(0)) 4096
        try{Assert-Focal ($out.Length -eq 4096)}finally{[Array]::Clear($out,0,$out.Length)}
        Expect-Fixed 'SMTP_MIME_PROCESS_OUTPUT_LIMIT' {Child 'overflow' "import sys`nsys.stdout.buffer.write(b'x'*4097)`n" ([byte[]]::new(0)) 4096}
        Expect-Fixed 'SMTP_MIME_PROCESS_OUTPUT_LIMIT' {Child 'stderrOverflow' "import sys`nsys.stderr.buffer.write(b'x'*257)`n" ([byte[]]::new(0)) 4096}
    }
    Case 'MP10_NO_PARTIAL_AND_FIXED_ERRORS' {
        Expect-Fixed 'SMTP_MIME_PROCESS_FAILED' {Child 'partial' "import sys`nsys.stdout.buffer.write(b'synthetic')`nsys.stdout.buffer.flush()`nsys.stderr.write('SMTP_MIME_PARSE_FAILED\n')`nsys.exit(1)`n" ([byte[]]::new(0)) 4096}
        Expect-Fixed 'SMTP_MIME_PARSE_FAILED' {Child 'fixedError' "import sys`nsys.stderr.write('SMTP_MIME_PARSE_FAILED\n')`nsys.exit(1)`n" ([byte[]]::new(0)) 4096}
    }
    Case 'MP11_TIMEOUT_OWN_CHILD_CLOSED' {
        $caught=$null
        try{$null=Child 'timeout' "import time`ntime.sleep(30)`n" ([byte[]]::new(0)) 4096}catch{$caught=$_}
        Assert-Focal ($null -ne $caught -and $caught.Exception.Message -ceq 'SMTP_MIME_PROCESS_TIMEOUT')
        $c=$caught.Exception.Data['SqlServerLab.SmtpMimeCustody'];Assert-Focal ($c.TerminationStatus -ceq 'CONFIRMED_EXIT' -and $c.PipeDrainStatus -ceq 'CONFIRMED_EOF' -and $c.DisposeStatus -ceq 'CONFIRMED' -and -not $c.RecoveryRequired);$caught=$null
    }
    Case 'MP12_GENUINE_CUSTODY_KILL_FAILURE_WAIT' {
        $p=[pscustomobject]@{HasExited=$false;WaitCalled=$false;Disposed=$false}
        $p|Add-Member ScriptMethod Kill {param($Tree)throw 'synthetic'}
        $p|Add-Member ScriptMethod WaitForExit {param($Ms)$this.WaitCalled=$true;$this.HasExited=$true;return $true}
        $p|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
        $scratch=@([byte[]]@(1,2),[byte[]]@(3,4));$done=@($true,$true);$tasks=@([Threading.Tasks.Task]::FromResult(0),[Threading.Tasks.Task]::FromResult(0));$streams=@([IO.MemoryStream]::new(),[IO.MemoryStream]::new());$streams[0].WriteByte(7);$held=$streams[0].GetBuffer()
        $c=Complete-LabSmtpMimeProcessCustody $p $null $null @($null,$null) $tasks $done $scratch $streams ([Diagnostics.ProcessStartInfo]::new())
        Assert-Focal ($c.KillFailed -and $p.WaitCalled -and $p.Disposed -and $c.TerminationStatus -ceq 'CONFIRMED_EXIT' -and $c.PipeDrainStatus -ceq 'CONFIRMED_EOF' -and $c.RecoveryRequired -and $c.CleanupFailureCode -ceq 'SMTP_MIME_PROCESS_CLEANUP_FAILED' -and $held[0] -eq 0 -and $scratch[0][0] -eq 0)
        $p=[pscustomobject]@{HasExited=$true;Disposed=$false};$p|Add-Member ScriptMethod WaitForExit {param($Ms)throw 'synthetic'};$p|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
        $c=Complete-LabSmtpMimeProcessCustody $p $null $null @($null,$null) @($null,$null) @($true,$true) @([byte[]]::new(4096),[byte[]]::new(4096)) @() ([Diagnostics.ProcessStartInfo]::new())
        Assert-Focal ($c.WaitFailed -and $p.Disposed -and $c.RecoveryRequired -and $c.CleanupFailureCode -ceq 'SMTP_MIME_PROCESS_TERMINATION_UNKNOWN')
    }
    Case 'MP13_GENUINE_CUSTODY_UNKNOWN_RECOVERY' {
        $p=[pscustomobject]@{HasExited=$false;Disposed=$false};$p|Add-Member ScriptMethod Kill {param($Tree)throw 'synthetic'};$p|Add-Member ScriptMethod WaitForExit {param($Ms)return $false};$p|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
        $c=Complete-LabSmtpMimeProcessCustody $p $null $null @($null,$null) @($null,$null) @($false,$false) @([byte[]]::new(4096),[byte[]]::new(4096)) @() ([Diagnostics.ProcessStartInfo]::new())
        Assert-Focal ($c.TerminationStatus -ceq 'UNKNOWN' -and $c.RecoveryRequired -and $c.CleanupFailureCode -ceq 'SMTP_MIME_PROCESS_TERMINATION_UNKNOWN' -and $p.Disposed)
        $p=[pscustomobject]@{HasExited=$true};$p|Add-Member ScriptMethod WaitForExit {param($Ms)return $true};$p|Add-Member ScriptMethod Dispose {throw 'synthetic'}
        $input=[pscustomobject]@{};$input|Add-Member ScriptMethod Dispose {throw 'synthetic'}
        $pipeA=[pscustomobject]@{Disposed=$false};$pipeA|Add-Member ScriptMethod Dispose {$this.Disposed=$true;throw 'synthetic'}
        $pipeB=[pscustomobject]@{Disposed=$false};$pipeB|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
        $c=Complete-LabSmtpMimeProcessCustody $p $input $null @($pipeA,$pipeB) @($null,$null) @($true,$true) @([byte[]]::new(4096),[byte[]]::new(4096)) @() ([Diagnostics.ProcessStartInfo]::new())
        Assert-Focal ($c.InputFailed -and $c.DisposeFailed -and $c.PipeDisposeFailed -and $pipeA.Disposed -and $pipeB.Disposed -and $c.RecoveryRequired -and $c.CleanupFailureCode -ceq 'SMTP_MIME_PROCESS_CLEANUP_FAILED')
        $p=[pscustomobject]@{HasExited=$true};$p|Add-Member ScriptMethod WaitForExit {param($Ms)return $true};$p|Add-Member ScriptMethod Dispose {}
        $fault=[Threading.Tasks.Task]::FromException[int]([InvalidOperationException]::new('synthetic'))
        $c=Complete-LabSmtpMimeProcessCustody $p $null $null @($null,$null) @($fault,$fault) @($false,$false) @([byte[]]::new(4096),[byte[]]::new(4096)) @() ([Diagnostics.ProcessStartInfo]::new())
        Assert-Focal ($c.DrainFailed -and $c.PipeDrainStatus -ceq 'UNKNOWN' -and $c.RecoveryRequired)
        # Genuine custody/retention branches with an owned synthetic pending Task;
        # no native IO, process, global owner, or physical-erasure claim.
        $pending=[Threading.Tasks.TaskCompletionSource[int]]::new();$inputPending=[Threading.Tasks.TaskCompletionSource[int]]::new()
        $scratch=@([byte[]]::new(4096),[byte[]]::new(4096));$scratch[0][0]=7;$owned=[byte[]]@(8);$owner=$null
        [Threading.Monitor]::Enter($script:LabSmtpMimeProcessState.Gate)
        try{
            $p=[pscustomobject]@{HasExited=$false};$p|Add-Member ScriptMethod Kill {param($Tree)throw 'synthetic'};$p|Add-Member ScriptMethod WaitForExit {param($Ms)return $false};$p|Add-Member ScriptMethod Dispose {}
            $c=Complete-LabSmtpMimeProcessCustody $p $null $inputPending.Task @($null,$null) @($pending.Task,$null) @($false,$true) $scratch @() ([Diagnostics.ProcessStartInfo]::new())
            Assert-Focal ($c.PendingIO -and $c.BufferCustody -ceq 'UNKNOWN' -and $scratch[0][0]-eq7 -and -not$c.InputBufferClearAllowed)
            Protect-LabSmtpMimePendingBuffers $c $owned $scratch @($pending.Task,$null) $inputPending.Task @($null,$null) $null $p @()
            $owner=$script:LabSmtpMimeProcessState.PendingOwner;Assert-Focal ([object]::ReferenceEquals($owner.Input,$owned) -and $owned[0]-eq8)
            $s=[Diagnostics.ProcessStartInfo]::new();$s.FileName='NEVER_STARTED';$s.UseShellExecute=$false;$s.RedirectStandardInput=$true;$s.RedirectStandardOutput=$true;$s.RedirectStandardError=$true
            Expect-Fixed 'SMTP_MIME_PROCESS_RECOVERY_REQUIRED' {Invoke-LabSmtpMimeByteProcess $s ([byte[]]::new(0)) 4096}
            Assert-Focal ([object]::ReferenceEquals($owner,$script:LabSmtpMimeProcessState.PendingOwner))
            $pending.SetResult(0);$inputPending.SetResult(0)
            $c=Complete-LabSmtpMimeProcessCustody $null $null $inputPending.Task @($null,$null) @($pending.Task,$null) @($true,$true) $scratch @() ([Diagnostics.ProcessStartInfo]::new())
            Protect-LabSmtpMimePendingBuffers $c $owned $scratch @($pending.Task,$null) $inputPending.Task @($null,$null) $null $null @()
            Assert-Focal (-not$c.PendingIO -and $owned[0]-eq0 -and $scratch[0][0]-eq0)
        }finally{
            # Only this fake owner is retired after its tasks are completed.
            if(-not$pending.Task.IsCompleted){$pending.SetResult(0)};if(-not$inputPending.Task.IsCompleted){$inputPending.SetResult(0)}
            [Array]::Clear($owned,0,$owned.Length);foreach($v in $scratch){[Array]::Clear($v,0,$v.Length)}
            if($null-ne$owner-and[object]::ReferenceEquals($owner,$script:LabSmtpMimeProcessState.PendingOwner)){$script:LabSmtpMimeProcessState.PendingOwner=$null}
            [Threading.Monitor]::Exit($script:LabSmtpMimeProcessState.Gate)
        }
    }
}catch{$failed++;$p=Read-FocalFailure $_;$records.Add([ordered]@{Id='HARNESS_SETUP';Status='FAIL';Code=$p.Code;CleanupCode=$p.CleanupCode;CustodyRecoveryObserved=$p.CustodyRecoveryObserved;CustodyProjectionFault=$p.CustodyProjectionFault})}
finally{
    try{[Environment]::SetEnvironmentVariable('PATH',$savedProcessPath,'Process')}catch{$p=Read-FocalFailure $_;$tempFailure=$p.Code;$recoveryRequired=$true}
    if($null -ne $temp){
        try{
            Assert-OwnTempBoundary;$all=[Collections.Generic.List[object]]::new()
            foreach($path in [IO.Directory]::EnumerateFileSystemEntries($temp)){if($all.Count-ge16){throw 'MIME_PARENT_TEMP_CUSTODY_UNKNOWN'};$all.Add((Get-Item -LiteralPath $path -Force))}
            if($all.Count -gt 16 -or $all.Count -ne $generated.Count){throw 'MIME_PARENT_TEMP_CUSTODY_UNKNOWN'}
            $sum=0L;$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach($i in $all){
                if($i.PSIsContainer -or ($i.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0 -or $i.Name-cnotmatch '^[A-Za-z]+\.py$' -or $i.Length-gt4096 -or -not$seen.Add($i.Name)){throw 'MIME_PARENT_TEMP_CUSTODY_UNKNOWN'}
                if($IsWindows -and (Get-Acl -LiteralPath $i.FullName).GetOwner([Security.Principal.SecurityIdentifier]).Value-cne[Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'MIME_PARENT_TEMP_CUSTODY_UNKNOWN'}
                $expected=@($generated|Where-Object{$_.Name-ceq$i.Name});$sha=(Get-FileHash -LiteralPath $i.FullName).Hash
                if($expected.Count-ne1-or$expected[0].SHA-cne$sha-or$expected[0].Bytes-ne$i.Length){throw 'MIME_PARENT_TEMP_CUSTODY_UNKNOWN'}
                $sum+=$i.Length;if($sum-gt65536){throw 'MIME_PARENT_TEMP_CUSTODY_UNKNOWN'};$tempInventory+=@([ordered]@{Name=$i.Name;Bytes=$i.Length;SHA=$sha})
            }
            $inventoryBytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject @($tempInventory|Sort-Object Name) -Compress));try{$tempInventorySHA=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($inventoryBytes))}finally{[Array]::Clear($inventoryBytes,0,$inventoryBytes.Length)}
            $inventoryBound=$true;$tempRetained=$true
        }catch{$p=Read-FocalFailure $_;$tempFailure=$p.Code;$recoveryRequired=$true}
    }
}
$stable=$true;try{foreach($p in $sourcePaths){if((Get-FileHash -LiteralPath (Join-Path $RepoRoot $p)).Hash-cne$before[$p]){$stable=$false}};if($python -and (Get-FileHash -LiteralPath $python).Hash -cne $pythonSHA){$stable=$false}}catch{$p=Read-FocalFailure $_;$tempFailure=$p.Code;$stable=$false}
foreach($row in $records){[Console]::WriteLine((ConvertTo-Json -InputObject $row -Compress))}
[Console]::WriteLine((ConvertTo-Json -InputObject ([ordered]@{Schema='SMTP_MIME_PARENT_FOCAL/v2';Passed=$passed;Failed=$failed;Inventory=$records.Count;SourceStable=$stable;OwnGeneratedTempRoot=$temp;TempRetainedUntilFull=$tempRetained;GeneratedInventoryBound=$inventoryBound;GeneratedInventorySHA=$tempInventorySHA;GeneratedSources=$tempInventory;TempFailureCode=$tempFailure;RecoveryRequired=$recoveryRequired;Python=$pythonVersion;PythonExeSHA=$pythonSHA;PowerShell=$PSVersionTable.PSVersion.ToString();Framework=[Runtime.InteropServices.RuntimeInformation]::FrameworkDescription;RuntimeChildAttempts=$runtimeChildren;ProviderCalls=0;SQLCalls=0;HardRSSCPU='NOT_IMPLEMENTED';Existing63Replayed=0}) -Depth 5 -Compress))
if($passed-ne13-or$failed-ne0-or$records.Count-ne13-or-not$stable-or-not$tempRetained-or-not$inventoryBound-or$recoveryRequired){exit 1}
exit 0
