function New-AiPodmanSamplesReferenceRoot {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ai-podman-samples-reference-'+[guid]::NewGuid().ToString('N'))
    $item=New-Item -ItemType Directory -Path $root -ErrorAction Stop
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'ACCEPTANCE_ROOT_INVALID'}
    if($IsWindows){
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl=Get-Acl -LiteralPath $root;$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner($identity)
        $acl.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
        Set-Acl -LiteralPath $root -AclObject $acl
    }
    else {
        $chmod=(Get-Command chmod -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        & $chmod 700 $root
        if($LASTEXITCODE -ne 0){throw 'ACCEPTANCE_ROOT_PERMISSIONS_FAILED'}
    }
    return $root
}

function Invoke-AiPodmanSamplesReferenceChild {
    [CmdletBinding()]
    param([string]$EvidenceRoot,[guid]$OperationId,[string]$WorkerPath,
        [ValidateSet('ACCEPTANCE','CLEANUP')][string]$Stage,[ValidateRange(1,3600)][int]$TimeoutSeconds,
        [hashtable]$Control=@{TerminationConfirmed=$true})
    $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$WorkerPath,
        '-EvidenceRoot',$EvidenceRoot,'-OperationId',$OperationId.ToString('D'),'-Stage',$Stage)){$start.ArgumentList.Add($argument)}
    $process=$null;$stdout=$null;$stderr=$null;$outTask=$null;$errTask=$null
    $status='FAILED';$reason='START_FAILED';$confirmed=$true;$assertions=0
    try {
        $stdout=[IO.File]::Create((Join-Path $EvidenceRoot ($Stage+'.stdout.log')))
        $stderr=[IO.File]::Create((Join-Path $EvidenceRoot ($Stage+'.stderr.log')))
        $process=[Diagnostics.Process]::Start($start);$confirmed=$false;$Control.TerminationConfirmed=$false
        $outTask=$process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errTask=$process.StandardError.BaseStream.CopyToAsync($stderr)
        if(-not $process.WaitForExit($TimeoutSeconds*1000)){$reason='TIMEOUT'}
        else {
            $confirmed=$true;$reason='CHILD_FAILED'
            $path=Join-Path $EvidenceRoot ($Stage+'.receipt.json')
            if($process.ExitCode -eq 0 -and (Test-Path -LiteralPath $path)){
                $item=Get-Item -LiteralPath $path
                if($item.Length -gt 1024 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'RECEIPT_INVALID'}
                $receipt=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -Depth 5
                $properties=@($receipt.PSObject.Properties.Name)
                if($properties.Count -ne 4 -or @($properties|Where-Object {$_ -cnotin @('OperationId','Stage','Status','Assertions')}).Count -or
                    $receipt.OperationId -cne $OperationId.ToString('D') -or $receipt.Stage -cne $Stage -or
                    $receipt.Status -cne 'COMPLETED' -or $receipt.Assertions -isnot [long] -and $receipt.Assertions -isnot [int] -or
                    $receipt.Assertions -lt 0 -or $receipt.Assertions -gt 100){throw 'RECEIPT_INVALID'}
                $status='COMPLETED';$reason='NONE';$assertions=[int]$receipt.Assertions
            }
        }
    }
    catch {$status='FAILED';$reason='SUPERVISOR_FAILED'}
    finally {
        if($process -and -not $confirmed){
            try {
                if(-not $process.HasExited){$process.Kill($true)}
                $confirmed=$process.WaitForExit(15000)
            }
            catch {$confirmed=$false}
        }
        if(-not $confirmed){$status='FAILED';$reason='TERMINATION_UNCONFIRMED'}
        if($confirmed){
            foreach($task in @($outTask,$errTask)){
                if($task){try{if(-not $task.Wait(5000)){$status='FAILED';$reason='OUTPUT_FAILED';$confirmed=$false}}catch{$status='FAILED';$reason='OUTPUT_FAILED';$confirmed=$false}}
            }
            if($stdout){$stdout.Dispose()};if($stderr){$stderr.Dispose()}
        }
        $Control.TerminationConfirmed=$confirmed
        if($process){$process.Dispose()}
    }
    [pscustomobject]@{Status=$status;Reason=$reason;TerminationConfirmed=$confirmed;Assertions=$assertions}
}

function Invoke-AiPodmanSamplesReferenceSequence {
    [CmdletBinding()]
    param([string]$EvidenceRoot,[guid]$OperationId,[string]$WorkerPath,
        [ValidateRange(1,3600)][int]$TimeoutSeconds,[ValidateRange(1,900)][int]$CleanupTimeoutSeconds)
    $parameters=@{EvidenceRoot=$EvidenceRoot;OperationId=$OperationId;WorkerPath=$WorkerPath}
    $primary=[pscustomobject]@{Status='FAILED';Reason='NOT_STARTED';TerminationConfirmed=$false;Assertions=0}
    $cleanup=[pscustomobject]@{Status='NOT_EXECUTED';Reason='TERMINATION_UNCONFIRMED';TerminationConfirmed=$false;Assertions=0}
    $control=@{TerminationConfirmed=$true}
    try {$primary=Invoke-AiPodmanSamplesReferenceChild @parameters -Stage ACCEPTANCE -TimeoutSeconds $TimeoutSeconds -Control $control}
    finally {
        if($control.TerminationConfirmed){
            $cleanup=Invoke-AiPodmanSamplesReferenceChild @parameters -Stage CLEANUP -TimeoutSeconds $CleanupTimeoutSeconds
        }
        [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'result.json'),
            ([ordered]@{OperationId=$OperationId.ToString('D');Primary=$primary;Cleanup=$cleanup}|ConvertTo-Json -Depth 5 -Compress))
    }
    [pscustomobject]@{Primary=$primary;Cleanup=$cleanup}
}

