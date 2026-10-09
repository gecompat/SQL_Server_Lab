#Requires -Version 7.2
# Only source-only checks are eligible. Runtime/provider, Pester, Python and
# analyzer evidence are deliberately not reused by this implementation.
function Get-LocalStaticEvidenceBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$Check,[string[]]$ChangedPath,
        [string]$RunnerInvocation=(Get-Command pwsh -ErrorAction Stop).Source)
    if ($Check -notin @('Invoke-DocumentationChecks.ps1','Invoke-CiStrategyChecks.ps1')) { return $null }
    try {
        $git=Get-Command git -ErrorAction Stop
        $files=@(& $git.Source -c core.quotepath=false -C $RepoRoot ls-files --cached --others --exclude-standard)
        if ($LASTEXITCODE -ne 0) { return $null }
        $index=@(& $git.Source -C $RepoRoot ls-files --stage)
        if ($LASTEXITCODE -ne 0) { return $null }
        $rows=[Collections.Generic.List[string]]::new()
        # Bind ignored active sources too. Documentation scanners explicitly
        # exclude ephemeral roots; active files do not acquire immunity by ignore.
        $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($RepoRoot)
        $active=[Collections.Generic.List[string]]::new()
        $excluded=@('.git','.artifacts','.cache','.local','.runtime','.state','.secrets','_QuellRepo','private_Note')
        while ($pending.Count) {
            foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
                $relative=[IO.Path]::GetRelativePath($RepoRoot,$item.FullName).Replace('\','/')
                if ($relative.Split('/')[0] -in $excluded) { continue }
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
                if ($item.PSIsContainer) { $pending.Push($item.FullName) } else { $active.Add($relative) }
            }
        }
        $files=@($files)+@($active)
        foreach ($path in @($files | Sort-Object -Unique)) {
            $file=Join-Path $RepoRoot $path
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
            $item=Get-Item -LiteralPath $file -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
            $rows.Add("$path=$((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash)")
        }
        $exe=(Get-Process -Id $PID).Path
        $runnerRoot=Split-Path -Parent $RunnerInvocation
        $runtimePending=[Collections.Generic.Stack[string]]::new();$runtimePending.Push($runnerRoot)
        while($runtimePending.Count) {
          foreach($runtimeFile in Get-ChildItem -LiteralPath $runtimePending.Pop() -Force) {
            if (($runtimeFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
            if ($runtimeFile.PSIsContainer) { $runtimePending.Push($runtimeFile.FullName);continue }
            $runtimeRelative=[IO.Path]::GetRelativePath($runnerRoot,$runtimeFile.FullName)
            $rows.Add('CHILD_RUNTIME:'+ $runtimeRelative +'='+(Get-FileHash -LiteralPath $runtimeFile.FullName -Algorithm SHA256).Hash)
          }
        }
        $rows.Add('CHILD_EXECUTABLE='+$RunnerInvocation+'='+(Get-FileHash -LiteralPath $RunnerInvocation -Algorithm SHA256).Hash)
        $environment=@(Get-ChildItem Env: | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join "`n"
        $sha=[Security.Cryptography.SHA256]::Create()
        try {
            # Broad source/index/environment binding is intentionally conservative
            # until per-suite transitive dependency catalogs are established.
            $text=@('LOCAL_STATIC_EVIDENCE/v1',$RepoRoot,$Check,($ChangedPath | Sort-Object -Unique) -join ',',
                $PSVersionTable.PSVersion.ToString(),[Environment]::Version.ToString(),
                (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash,
                (Get-FileHash -LiteralPath $git.Source -Algorithm SHA256).Hash,
                ($index -join "`n"),($rows -join "`n"),$environment) -join "`n"
            return [Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))
        } finally { $sha.Dispose() }
    } catch { return $null }
}

function Test-LocalStaticEvidence {
    [CmdletBinding()]
    param([string]$Path,[string]$Binding,[datetime]$Now=[datetime]::UtcNow)
    if (-not $Binding -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        if (((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if ((Get-Item -LiteralPath $Path).Length -gt 16384) { return $false }
        $json=Get-Content -LiteralPath $Path -Raw
        $document=[System.Text.Json.JsonDocument]::Parse([string]$json)
        try {
            if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $false }
            $expected=@('Schema','Status','Binding','ExitCode','SourceStable','CompletedUtc','Log','LogSHA256')
            $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($property in $document.RootElement.EnumerateObject()) {
                if ($property.Name -cnotin $expected -or -not $seen.Add($property.Name)) { return $false }
                $kind=if ($property.Name -ceq 'ExitCode') { [System.Text.Json.JsonValueKind]::Number } elseif ($property.Name -ceq 'SourceStable') { [System.Text.Json.JsonValueKind]::True } else { [System.Text.Json.JsonValueKind]::String }
                if ($property.Value.ValueKind -ne $kind) { return $false }
                if ($property.Name -ceq 'ExitCode') { $exitValue=0; if (-not $property.Value.TryGetInt32([ref]$exitValue) -or $exitValue -ne 0) { return $false } }
            }
            if ($seen.Count -ne $expected.Count) { return $false }
        } finally { $document.Dispose() }
        $record=$json | ConvertFrom-Json -ErrorAction Stop
        $ordinal=[StringComparer]::Ordinal
        if (-not $ordinal.Equals($record.Schema,'LOCAL_STATIC_EVIDENCE/v1') -or -not $ordinal.Equals($record.Status,'EXECUTED_PASS') -or
            -not $ordinal.Equals($record.Binding,$Binding) -or $record.ExitCode -ne 0 -or $record.SourceStable -ne $true) { return $false }
        $time=[datetime]::Parse($record.CompletedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if ($time -gt $Now -or ($Now-$time).TotalHours -gt 4) { return $false }
        $expectedRoot=[IO.Path]::GetFullPath((Split-Path -Parent $Path))
        $logRoot=[IO.Path]::GetFullPath((Split-Path -Parent $record.Log))
        if ($expectedRoot -cne $logRoot -or $record.Log -notmatch '\.private\.log$') { return $false }
        if (-not (Test-Path -LiteralPath $record.Log -PathType Leaf)) { return $false }
        if (((Get-Item -LiteralPath $record.Log).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        return $ordinal.Equals((Get-FileHash -LiteralPath $record.Log -Algorithm SHA256).Hash,$record.LogSHA256)
    } catch { return $false }
}
