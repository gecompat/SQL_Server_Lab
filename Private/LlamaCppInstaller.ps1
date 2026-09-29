function Get-LabLlamaInstallerDigest {
    param([Parameter(Mandatory)][string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}
# Curated binary acquisition for SQL Server AI integrations. No model or service activation.
function Get-LabLlamaInstallerCatalog {
    $path=Join-Path $script:CatalogsPath 'llama-cpp-runtime-packages.json'
    $text=[IO.File]::ReadAllText($path)
    $document=$text | ConvertFrom-Json -Depth 12
    if ($document.Contract -cne 'SqlServerLab.LlamaCppInstallerCatalog/1.0' -or @($document.Items).Count -ne 1) { throw 'LLAMA_INSTALL_CATALOG_INVALID' }
    $item=$document.Items[0]
    if ($item.Id -cne 'llama-b11247-win-x64-cpu' -or $item.ReleaseId -ne 398909727 -or $item.AssetId -ne 597579591 -or
        $item.Tag -cne 'b11247' -or $item.Build -ne 11247 -or $item.Commit -cne '0bc845d356f437d5ce4fe975c36428f7522829cb' -or
        $item.AssetName -cne 'llama-b11247-bin-win-cpu-x64.zip' -or $item.Bytes -ne 19163423 -or
        $item.Sha256 -cne '4c66724cbbe89614d53a0e68a88a470d2982bc314525eff45df37e422a7cc685' -or
        $item.OS -cne 'Windows' -or $item.Architecture -cne 'x64' -or $item.Backend -cne 'CPU' -or @($item.Files).Count -ne 51) { throw 'LLAMA_INSTALL_CATALOG_INVALID' }
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($file in $item.Files) {
        if ($file.Name -cnotmatch '^(?:[a-zA-Z0-9][a-zA-Z0-9.-]*\.(?:exe|dll)|LICENSE-LLVM-OpenMP)$' -or
            -not $names.Add($file.Name) -or $file.Bytes -le 0 -or $file.Bytes -gt 134217728 -or $file.Sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'LLAMA_INSTALL_CATALOG_INVALID' }
    }
    [pscustomobject]@{Item=$item;Key=(Get-LabLlamaInstallerDigest -Text $text)}
}

function Assert-LabLlamaInstallerPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'LLAMA_INSTALL_ROOT_INVALID' }
    $full=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Path))
    if($IsWindows -and ($full.StartsWith('\\') -or [IO.DriveInfo]::new([IO.Path]::GetPathRoot($full)).DriveType -eq [IO.DriveType]::Network)){throw 'LLAMA_INSTALL_LOCAL_ROOT_REQUIRED'}
    if ($full -eq [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetPathRoot($full))) { throw 'LLAMA_INSTALL_ROOT_INVALID' }
    $current=$full
    while($current) {
        $item=$null
        try{$item=Get-Item -LiteralPath $current -Force -ErrorAction Stop}catch [Management.Automation.ItemNotFoundException]{}
        if($item) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $item.PSIsContainer) { throw 'LLAMA_INSTALL_PATH_ALIAS' }
        }
        $parent=[IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }; $current=$parent
    }
    $full
}

function Get-LabLlamaInstallerRoots {
    $rows=@(Get-LabMediaRootCandidates)
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($row in $rows) {
        try {
            $path=Assert-LabLlamaInstallerPath -Path $row.Path
            $repo=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($script:ModuleRoot))
            if ($path.Equals($repo,[StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($repo+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $path -PathType Container)) { continue }
            if ($seen.Add($path)) { [pscustomobject]@{Id=(Get-LabLlamaInstallerDigest -Text $path.ToLowerInvariant());Path=$path;Label=$path} }
        } catch { continue }
    }
}

function Get-LabLlamaInstallerPrerequisite {
    if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'X64') { return 'WINDOWS_X64_REQUIRED' }
    $system=[Environment]::GetFolderPath([Environment+SpecialFolder]::System)
    foreach($name in @('MSVCP140.dll','VCRUNTIME140.dll','VCRUNTIME140_1.dll','ucrtbase.dll')) {
        $path=Join-Path $system $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 'NATIVE_PREREQUISITE_MISSING' }
    }
    'PRESENT_VERSION_COMPATIBILITY_UNKNOWN'
}

function Test-LabLlamaInstallerFiles {
    param([string]$Path,[object]$Catalog)
    $null=Assert-LabLlamaInstallerPath -Path $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw 'LLAMA_INSTALL_FILES_MISSING' }
    $actual=@(Get-ChildItem -LiteralPath $Path -Force)
    if ($actual.Count -ne @($Catalog.Files).Count) { throw 'LLAMA_INSTALL_FILESET_MISMATCH' }
    foreach($expected in $Catalog.Files) {
        $matches=@($actual|Where-Object Name -CEQ $expected.Name)
        if ($matches.Count -ne 1 -or $matches[0].PSIsContainer -or ($matches[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $matches[0].Length -ne $expected.Bytes -or (Get-FileHash -LiteralPath $matches[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected.Sha256) { throw 'LLAMA_INSTALL_FILESET_MISMATCH' }
    }
}

function Get-LabLlamaInstallerPlan {
    param([Parameter(Mandatory)][string]$CandidateId,[Parameter(Mandatory)][string]$RootId)
    $catalog=Get-LabLlamaInstallerCatalog
    if ($CandidateId -cne $catalog.Item.Id) { throw 'LLAMA_INSTALL_CANDIDATE_INVALID' }
    $roots=@(Get-LabLlamaInstallerRoots|Where-Object Id -CEQ $RootId)
    if ($roots.Count -ne 1) { throw 'LLAMA_INSTALL_ROOT_UNAVAILABLE' }
    $root=$roots[0].Path
    $parent=Join-Path $root 'AI/Runtimes/llama.cpp'
    $leaf=$catalog.Item.Tag+'-'+$catalog.Item.Sha256.Substring(0,12)
    $target=Join-Path $parent $leaf
    $operation=Join-Path $parent ($leaf+'.operation')
    $packageLeaf=[IO.Path]::GetFileNameWithoutExtension($catalog.Item.AssetName)
    $package=Join-Path $target $packageLeaf
    $null=Assert-LabLlamaInstallerPath -Path $target
    $null=Assert-LabLlamaInstallerPath -Path $operation
    $state='ABSENT';$installedKey='';$canApply=$true
    $prerequisite=Get-LabLlamaInstallerPrerequisite
    if ($prerequisite -ne 'PRESENT_VERSION_COMPATIBILITY_UNKNOWN') {$canApply=$false}
    if (Test-Path -LiteralPath $operation) {$state='RECOVERY_REQUIRED';$canApply=$false}
    elseif(Test-Path -LiteralPath $target) {
        try {
            $items=@(Get-ChildItem -LiteralPath $target -Force)
            if ($items.Count -ne 2 -or @($items|Where-Object Name -CEQ 'receipt.json').Count -ne 1 -or @($items|Where-Object Name -CEQ $packageLeaf).Count -ne 1) { throw 'LLAMA_INSTALL_RECEIPT_INVALID' }
            $receiptItem=Get-Item -LiteralPath (Join-Path $target 'receipt.json') -Force
            if ($receiptItem.PSIsContainer -or ($receiptItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $receiptItem.Length -gt 4096) {throw 'LLAMA_INSTALL_RECEIPT_INVALID'}
            $receiptText=[IO.File]::ReadAllText($receiptItem.FullName);$receipt=$receiptText|ConvertFrom-Json
            if ($receipt.Contract -cne 'SqlServerLab.LlamaCppInstallerReceipt/1.0' -or $receipt.CatalogKey -cne $catalog.Key -or $receipt.CandidateId -cne $CandidateId -or $receipt.RootId -cne $RootId -or $receipt.Status -cne 'BINARY_PROBE_PASSED') {throw 'LLAMA_INSTALL_RECEIPT_INVALID'}
            Test-LabLlamaInstallerFiles -Path $package -Catalog $catalog.Item
            $installedKey=Get-LabLlamaInstallerDigest -Text $receiptText
            $state='INSTALLED_VERIFIED'
        } catch {$state='DRIFT';$canApply=$false}
    }
    $key=Get-LabLlamaInstallerDigest -Text (@($catalog.Key,$RootId,$root.ToLowerInvariant(),$target.ToLowerInvariant(),$state,$installedKey,$prerequisite)-join '|')
    [pscustomobject]@{CandidateId=$CandidateId;RootId=$RootId;ExpectedKey=$key;State=$state;CanApply=$canApply;IsNoOp=($state -eq 'INSTALLED_VERIFIED');Root=$root;Target=$target;Operation=$operation;Package=$package;PackageLeaf=$packageLeaf;Catalog=$catalog
        Prerequisite=$prerequisite;Notice='Experimentell: Download und SHA256-Prüfung; vollständiges Paket versioniert entpacken; llama-server.exe --version maximal 15 Sekunden/64 KiB ausführen. Keine Modelle, Listener, Dienste, Treiber oder PATH-Änderung. Mindest-OS/CPU/VC-Version unbekannt; Compute und SQL nicht geprüft.'}
}

function ConvertTo-LabLlamaInstallerPlanView {
    param([object]$Plan)
    [pscustomobject]@{CandidateId=$Plan.CandidateId;RootId=$Plan.RootId;ExpectedKey=$Plan.ExpectedKey;State=$Plan.State;CanApply=$Plan.CanApply;IsNoOp=$Plan.IsNoOp;Prerequisite=$Plan.Prerequisite;Notice=$Plan.Notice;Target=$Plan.Target;Bytes=$Plan.Catalog.Item.Bytes;Sha256=$Plan.Catalog.Item.Sha256;Probe='llama-server.exe --version';Evidence='Compute/SQL/Modelle: NOT_CHECKED'}
}

function Get-LabLlamaInstallerView {
    $catalog=Get-LabLlamaInstallerCatalog
    [pscustomobject]@{Items=@([pscustomobject]@{Id=$catalog.Item.Id;Release=$catalog.Item.Tag;OS='Windows';Architecture='x64';Backend='CPU';Catalogued=$true;Status='EXPERIMENTAL';Recommendation='UNASSESSED';Prerequisites='VC140/UCRT erforderlich; Mindestversion/OS-/CPU-Unterstützung UNKNOWN'});Roots=@(Get-LabLlamaInstallerRoots);Upstream='NOT_REFRESHED';Notice='Nur kuratierter Windows-x64-CPU-Pin installierbar. Upstreamverfügbarkeit, installierte Dateien, Paketprobe und Empfehlung sind getrennte Nachweise.'}
}

function Invoke-LabLlamaInstallerProbe {
    param([Parameter(Mandatory)][object]$Plan,[Parameter(Mandatory)][string]$OperationId)
    $probe=Join-Path $Plan.Operation 'probe'
    $null=[IO.Directory]::CreateDirectory($probe)
    $request=[ordered]@{Contract='SqlServerLab.LlamaCppInstallerProbe/1.0';OperationId=$OperationId;Invocation='';Arguments=@();StartTimeoutSeconds=15;LeaseSeconds=15}
    $requestPath=Join-Path $probe 'request.json'
    [IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json -Compress))
    $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application|Select-Object -First 1).Source)
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($arg in @('-NoProfile','-NonInteractive','-File',(Join-Path $script:ModuleRoot 'Tools/Invoke-LlamaCppOwnedWorker.ps1'),'-RequestPath',$requestPath)){$start.ArgumentList.Add($arg)}
    $worker=$null;$nativeEndConfirmed=$false
    try {
        $worker=[Diagnostics.Process]::Start($start)
        # The worker emits fixed receipts; native output stays within its 64 KiB files.
        $stdout=$worker.StandardOutput.ReadToEndAsync();$stderr=$worker.StandardError.ReadToEndAsync()
        if(-not $worker.WaitForExit(45000)) {
            $worker.StandardInput.Close()
            if(-not $worker.WaitForExit(17000)){$worker.Kill($true);if(-not $worker.WaitForExit(5000)){throw 'LLAMA_INSTALL_TERMINATION_UNCONFIRMED'}}
            throw 'LLAMA_INSTALL_TERMINATION_UNCONFIRMED'
        }
        $null=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult()
        $receiptPath=Join-Path $probe 'receipt.json'
        $receipt=Read-LabLlamaInstallerProbeReceipt -Path $receiptPath -OperationId $OperationId
        $nativeEndConfirmed=$true
        Assert-LabLlamaInstallerProbeResult -Receipt $receipt
    } catch {
        if(-not $nativeEndConfirmed){throw 'LLAMA_INSTALL_TERMINATION_UNCONFIRMED'}
        throw
    } finally {
        if($worker){
            try {
                if(-not $worker.HasExited){$worker.StandardInput.Close();if(-not $worker.WaitForExit(17000)){$worker.Kill($true);if(-not $worker.WaitForExit(5000)){throw 'LLAMA_INSTALL_TERMINATION_UNCONFIRMED'}}}
            }catch{throw 'LLAMA_INSTALL_TERMINATION_UNCONFIRMED'}finally{$worker.Dispose()}
        }
    }
}

function Assert-LabLlamaInstallerProbeResult {
    param([Parameter(Mandatory)][object]$Receipt)
    # Called only after the bounded receipt reader validated the fixed-code DTO.
    if($Receipt.Status -cne 'BINARY_PROBE_PASSED'){
        $failure=[InvalidOperationException]::new($Receipt.Code)
        $failure.Data['ChildTerminationConfirmed']=$Receipt.ChildTerminationConfirmed
        $failure.Data['ProbeStarted']=$Receipt.ProbeStarted
        $failure.Data['ExitCode']=$Receipt.ExitCode
        throw $failure
    }
}

function Read-LabLlamaInstallerProbeReceipt {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$OperationId)
    try {
        $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 4096){throw 'INVALID'}
        $receipt=[IO.File]::ReadAllText($Path)|ConvertFrom-Json -ErrorAction Stop
        $codes=@('LLAMA_INSTALL_PROBE_PACKAGE_FAILED','LLAMA_INSTALL_PROBE_SETUP_FAILED','LLAMA_INSTALL_PROBE_START_FAILED','LLAMA_INSTALL_PROBE_OUTPUT_LIMIT','LLAMA_INSTALL_PROBE_TIMEOUT','LLAMA_INSTALL_PROBE_OWNER_CLOSED','LLAMA_INSTALL_PROBE_NONZERO_EXIT','LLAMA_INSTALL_PROBE_VERSION_MISMATCH','LLAMA_INSTALL_PROBE_FAILED')
        if($receipt.OperationId -cne $OperationId -or $receipt.ChildTerminationConfirmed -isnot [bool] -or -not $receipt.ChildTerminationConfirmed -or $receipt.ProbeStarted -isnot [bool] -or $receipt.LaunchAttempted -isnot [bool] -or
            $receipt.Status -eq 'RECOVERY_REQUIRED' -or $receipt.Code -eq 'LLAMA_TERMINATION_UNCONFIRMED' -or $receipt.Status -cnotin @('BINARY_PROBE_PASSED','FAILED')){throw 'INVALID'}
        if($receipt.ProbeStarted){if(-not $receipt.LaunchAttempted -or ($receipt.ExitCode -isnot [long] -and $receipt.ExitCode -isnot [int]) -or $receipt.ExitCode -lt [int]::MinValue -or $receipt.ExitCode -gt [int]::MaxValue){throw 'INVALID'}}
        elseif($null -ne $receipt.ExitCode){throw 'INVALID'}
        if(($receipt.Status -ceq 'FAILED' -and $receipt.Code -cnotin $codes) -or ($receipt.Status -ceq 'BINARY_PROBE_PASSED' -and ($receipt.Code -cne 'COMPUTE_SQL_NOT_CHECKED' -or -not $receipt.ProbeStarted -or $receipt.ExitCode -ne 0))){throw 'INVALID'}
        return $receipt
    }catch{throw 'LLAMA_INSTALL_TERMINATION_UNCONFIRMED'}
}

function Remove-LabLlamaInstallerOwnedStage {
    param([object]$Plan,[string]$OperationId)
    $path=Assert-LabLlamaInstallerPath -Path $Plan.Operation
    $expected=$Plan.Catalog.Item.Tag+'-'+$Plan.Catalog.Item.Sha256.Substring(0,12)+'.operation'
    if((Split-Path -Leaf $path) -cne $expected -or (Split-Path -Parent $path) -cne (Split-Path -Parent $Plan.Target)){throw 'LLAMA_INSTALL_CLEANUP_SCOPE'}
    $journalPath=Join-Path $path 'journal.json'
    $journalItem=Get-Item -LiteralPath $journalPath -Force
    if(($journalItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $journalItem.Length -gt 4096){throw 'LLAMA_INSTALL_CLEANUP_SCOPE'}
    $journal=[IO.File]::ReadAllText($journalPath)|ConvertFrom-Json
    if($journal.OperationId -cne $OperationId -or $journal.ExpectedKey -cne $Plan.ExpectedKey -or $journal.RootId -cne $Plan.RootId){throw 'LLAMA_INSTALL_CLEANUP_SCOPE'}
    # Enumerate without traversing a reparse point. Unknown links never authorize deletion.
    $pending=[Collections.Generic.Queue[string]]::new();$pending.Enqueue($path)
    while($pending.Count){foreach($item in Get-ChildItem -LiteralPath $pending.Dequeue() -Force){
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'LLAMA_INSTALL_CLEANUP_SCOPE'}
        if($item.PSIsContainer){$pending.Enqueue($item.FullName)}
    }}
    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
    if(Test-Path -LiteralPath $path){throw 'LLAMA_INSTALL_CLEANUP_UNCONFIRMED'}
}

function Invoke-LabLlamaInstaller {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$CandidateId,[Parameter(Mandatory)][string]$RootId,[Parameter(Mandatory)][string]$ExpectedKey,[switch]$Confirmed)
    if(-not $Confirmed){return [pscustomobject]@{Status='CANCELLED';Mutated=$false}}
    $plan=Get-LabLlamaInstallerPlan -CandidateId $CandidateId -RootId $RootId
    $mutex=Enter-LabLlamaInstallerLock -Target $plan.Target
    try {
        $fresh=Get-LabLlamaInstallerPlan -CandidateId $CandidateId -RootId $RootId
        if($fresh.ExpectedKey -cne $ExpectedKey -or $fresh.Target -cne $plan.Target){throw 'LLAMA_INSTALL_PREVIEW_STALE'}
        $plan=$fresh
        if(-not $plan.CanApply){throw 'LLAMA_INSTALL_BLOCKED'}
        if($plan.IsNoOp){return [pscustomobject]@{Status='NO_CHANGE';Mutated=$false;SearchRoot=$plan.Package;Evidence='BINARY_PROBE_PASSED; Compute/SQL/Modelle NOT_CHECKED'}}
        if(-not $PSCmdlet.ShouldProcess('Kuratierte llama.cpp-Runtime', 'Download, versionierte Extraktion und feste --version-Probe')){return [pscustomobject]@{Status='CANCELLED';Mutated=$false}}
        $null=Get-LabLlamaInstallerUpstream
        $null=Assert-LabLlamaInstallerPath -Path $plan.Operation
        if(Test-Path -LiteralPath $plan.Operation){throw 'LLAMA_INSTALL_RECOVERY_REQUIRED'}
        $null=[IO.Directory]::CreateDirectory($plan.Operation)
        Protect-LabLlamaCppOperationPath -Path $plan.Operation
        $operationId=[guid]::NewGuid().ToString('D')
        $journal=[ordered]@{Contract='SqlServerLab.LlamaCppInstallerJournal/1.0';OperationId=$operationId;ExpectedKey=$plan.ExpectedKey;RootId=$plan.RootId;CandidateId=$CandidateId;Phase='PREPARED'}
        $journalPath=Join-Path $plan.Operation 'journal.json'
        [IO.File]::WriteAllText($journalPath,($journal|ConvertTo-Json -Compress))
        $terminationConfirmed=$true;$probeFailed=$false
        try {
            $item=$plan.Catalog.Item
            $data=Receive-LabLlamaInstallerBytes -Uri ('https://github.com/ggml-org/llama.cpp/releases/download/'+$item.Tag+'/'+$item.AssetName) -MaximumBytes $item.Bytes
            if($data.Length -ne $item.Bytes -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($data)).ToLowerInvariant() -cne $item.Sha256){throw 'LLAMA_INSTALL_ARCHIVE_HASH'}
            $archive=Join-Path $plan.Operation 'package.zip'
            $file=[IO.File]::Open($archive,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$file.Write($data,0,$data.Length)}finally{$file.Dispose();$data=$null}
            $stage=Join-Path $plan.Operation 'stage';$null=[IO.Directory]::CreateDirectory($stage)
            $package=Join-Path $stage $plan.PackageLeaf
            Expand-LabLlamaInstallerArchive -ArchivePath $archive -Destination $package -Catalog $item
            if((Get-LabLlamaInstallerCatalog).Key -cne $plan.Catalog.Key -or @((Get-LabLlamaInstallerRoots)|Where-Object {$_.Id -ceq $RootId -and $_.Path -ceq $plan.Root}).Count -ne 1 -or (Test-Path -LiteralPath $plan.Target)){throw 'LLAMA_INSTALL_PREVIEW_STALE'}
            $journal.Phase='PROBE_STARTED';[IO.File]::WriteAllText($journalPath,($journal|ConvertTo-Json -Compress))
            $locks=[Collections.Generic.List[IO.FileStream]]::new()
            try {
                foreach($entry in $item.Files){$locks.Add([IO.File]::Open((Join-Path $package $entry.Name),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))}
                Test-LabLlamaInstallerFiles -Path $package -Catalog $item
                try{Invoke-LabLlamaInstallerProbe -Plan $plan -OperationId $operationId}
                catch{$probeFailed=$true;if($_.Exception.Message -eq 'LLAMA_INSTALL_TERMINATION_UNCONFIRMED'){$terminationConfirmed=$false};throw}
                Test-LabLlamaInstallerFiles -Path $package -Catalog $item
            }finally{foreach($fileLock in $locks){$fileLock.Dispose()}}
            $receipt=[ordered]@{Contract='SqlServerLab.LlamaCppInstallerReceipt/1.0';OperationId=$operationId;CandidateId=$CandidateId;RootId=$RootId;CatalogKey=$plan.Catalog.Key;Status='BINARY_PROBE_PASSED';Compute='NOT_CHECKED';SQL='NOT_CHECKED'}
            [IO.File]::WriteAllText((Join-Path $stage 'receipt.json'),($receipt|ConvertTo-Json -Compress))
            $null=Assert-LabLlamaInstallerPath -Path $plan.Target
            if((Get-LabLlamaInstallerCatalog).Key -cne $plan.Catalog.Key -or @((Get-LabLlamaInstallerRoots)|Where-Object {$_.Id -ceq $RootId -and $_.Path -ceq $plan.Root}).Count -ne 1){throw 'LLAMA_INSTALL_PREVIEW_STALE'}
            Test-LabLlamaInstallerFiles -Path $package -Catalog $item
            [IO.Directory]::Move($stage,$plan.Target)
            Remove-LabLlamaInstallerOwnedStage -Plan $plan -OperationId $operationId
            [pscustomobject]@{Status='BINARY_PROBE_PASSED';Mutated=$true;SearchRoot=$plan.Package;Evidence='Paketausführbarkeit; Compute/SQL/Modelle NOT_CHECKED'}
        } catch {
            $code=if($_.Exception.Message -cmatch '^LLAMA_INSTALL_[A-Z_]+$'){$_.Exception.Message}else{'LLAMA_INSTALL_FAILED'}
            if($terminationConfirmed -and -not $probeFailed){try{Remove-LabLlamaInstallerOwnedStage -Plan $plan -OperationId $operationId}catch{throw 'LLAMA_INSTALL_RECOVERY_REQUIRED'}}
            else{
                $recovery=[InvalidOperationException]::new('LLAMA_INSTALL_RECOVERY_REQUIRED')
                $recovery.Data['FailureCode']=$code
                $recovery.Data['ChildTerminationConfirmed']=if($_.Exception.Data.Contains('ChildTerminationConfirmed')){$_.Exception.Data['ChildTerminationConfirmed']}else{$null}
                throw $recovery
            }
            throw $code
        }
    }finally{$mutex.ReleaseMutex();$mutex.Dispose()}
}

function Enter-LabLlamaInstallerLock {
    param([Parameter(Mandatory)][string]$Target,[ValidateRange(100,30000)][int]$TimeoutMilliseconds=30000)
    $canonical=Assert-LabLlamaInstallerPath -Path $Target
    $name='SqlServerLab.LlamaInstaller.'+(Get-LabLlamaInstallerDigest -Text $canonical.ToLowerInvariant())
    if($IsWindows){$name='Global\'+$name}
    $mutex=[Threading.Mutex]::new($false,$name)
    try {
        $held=$false
        try{$held=$mutex.WaitOne($TimeoutMilliseconds)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw 'LLAMA_INSTALL_LOCK_TIMEOUT'}
        return $mutex
    }catch{$mutex.Dispose();throw}
}

function Show-LabLlamaInstallerInteractive {
    while($true){
        $view=Get-LabLlamaInstallerView
        $items=@($view.Items|ForEach-Object{New-LabConsoleItem -Id $_.Id -Label ($_.Release+' · '+$_.OS+' / '+$_.Architecture+' / '+$_.Backend) -Value 'EXPERIMENTAL · Empfehlung UNASSESSED'})
        $items+=New-LabConsoleItem -Id refresh-local -Label 'Lokalen Katalog und Roots erneut lesen' -Shortcut r
        $items+=New-LabConsoleItem -Id refresh-upstream -Label 'Offizielle Metadaten des Pins online prüfen (kein Binärdownload)'
        $items+=New-LabConsoleItem -Id back -Label 'Zurück' -Shortcut 0
        $choice=Invoke-LabConsoleMenu -ScreenId llama-installer -Title 'llama.cpp-Runtime für SQL-KI' -Subtitle 'Nur Windows / x64 / CPU verfügbar; weitere OS/Backends offen. Noch keine Installation.' -Items $items
        if($choice.Status -eq 'Refresh'){continue}
        if($choice.Status -ne 'Selected' -or $choice.SelectedItem.Id -eq 'back'){return}
        if($choice.SelectedItem.Id -eq 'refresh-local'){continue}
        if($choice.SelectedItem.Id -eq 'refresh-upstream'){
            try{Write-Host ((Get-LabLlamaInstallerUpstream)|ConvertTo-Json -Depth 4)}catch{Write-LabWarning 'Offizielle Metadaten nicht bestätigt; kein Download.'}
            Wait-LabConsoleAcknowledgement;continue
        }
        $candidate=$choice.SelectedItem.Id
        $rootItems=@($view.Roots|ForEach-Object{New-LabConsoleItem -Id $_.Id -Label $_.Label})
        $rootItems+=New-LabConsoleItem -Id back -Label 'Abbrechen' -Shortcut 0
        $rootChoice=Invoke-LabConsoleMenu -ScreenId llama-installer-root -Title 'Vorhandenen Lab_Base wählen' -Subtitle 'Fehlende Roots zuerst in Grundkonfiguration einrichten. Keine automatische Defaultänderung.' -Items $rootItems
        if($rootChoice.Status -ne 'Selected' -or $rootChoice.SelectedItem.Id -eq 'back'){continue}
        try{
            $plan=Get-LabLlamaInstallerPlan -CandidateId $candidate -RootId $rootChoice.SelectedItem.Id
            Write-Host ((ConvertTo-LabLlamaInstallerPlanView $plan)|ConvertTo-Json -Depth 4)
            if(-not $plan.CanApply){Write-LabWarning 'Installation blockiert; prerequisites/Recovery getrennt klären.'}
            elseif($plan.IsNoOp){Write-LabInfo 'Dateimenge und Receipt revalidiert: keine Änderung, kein Download, keine Probe.'}
            elseif(Read-LabConfirm -Prompt 'Angezeigten Download, Extraktion und genau llama-server.exe --version ausführen? Laufender Vorgang kann nicht per Zurück abgebrochen werden.' -Default $false){
                $result=Invoke-LabLlamaInstaller -CandidateId $candidate -RootId $plan.RootId -ExpectedKey $plan.ExpectedKey -Confirmed
                Write-Host ($result|ConvertTo-Json -Depth 4)
            }
        }catch{Write-LabWarning 'Installation nicht bestätigt. Frisch vorprüfen; bei RECOVERY_REQUIRED den eigenen Vorgang separat untersuchen, niemals automatisch erneut ausführen.'}
        Wait-LabConsoleAcknowledgement
    }
}
