# Interner Fortschritt fuer direkte Aktionen. Nur feste Phasen und Messwerte
# gelangen in die Anzeige; Pfade, Argumente und native Ausgaben bleiben draussen.
function Start-LabActionProgress {
    [CmdletBinding()]
    param(
        [ValidateSet('Download','SqlReadiness','SqlQuery','ImageBuild','Copy','Hash','Extract','Transfer','Restore','Import','GuestWait')]
        [string]$Phase,
        [datetime]$Now = [datetime]::UtcNow
    )
    $enabled = $false
    try { $enabled = -not [Console]::IsOutputRedirected -and $Host.Name -notin @('ServerRemoteHost','Default Host') } catch { }
    [pscustomobject]@{
        Id = [System.Random]::Shared.Next(10000, [int]::MaxValue)
        Phase = $Phase; StartedAt = $Now; LastShownAt = $null
        LastPhase = ''; Tick = 0; Enabled = $enabled; Shown = $false; Completed = $false
    }
}

function Update-LabActionProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Progress,
        [ValidateSet('Download','SqlReadiness','SqlQuery','ImageBuild','Copy','Hash','Extract','Transfer','Restore','Import','GuestWait')]
        [string]$Phase,
        [ValidateRange(0, [long]::MaxValue)][long]$CompletedBytes = 0,
        [ValidateRange(0, [long]::MaxValue)][long]$TotalBytes = 0,
        [ValidateRange(0, [int]::MaxValue)][int]$ProbeCount = 0,
        [datetime]$Now = [datetime]::UtcNow
    )
    if ($Progress.Completed -or -not $Progress.Enabled) { return }
    if ($Phase) { $Progress.Phase = $Phase }
    if (($Now - $Progress.StartedAt).TotalSeconds -lt 5) { return }
    if ($null -ne $Progress.LastShownAt -and ($Now - $Progress.LastShownAt).TotalSeconds -lt 1 -and
        $Progress.LastPhase -eq $Progress.Phase) { return }
    $labels = @{
        Download='Download'; SqlReadiness='SQL-Bereitschaft'; SqlQuery='SQL ausfuehren'; ImageBuild='Container-Image bauen'
        Copy='Dateien kopieren'; Hash='Integritaet pruefen'; Extract='Archiv entpacken'
        Transfer='Daten uebertragen'; Restore='Datenbank wiederherstellen'
        Import='Datenbank importieren'; GuestWait='Auf Gast warten'
    }
    # Allowlist erneut anwenden: auch ein manipuliertes Contextobjekt darf keine
    # freien Texte als Phase in den Renderer einschleusen.
    $label = $labels[[string]$Progress.Phase]
    if (-not $label) { $label = 'Vorgang' }
    $percent = -1
    if ($TotalBytes -gt 0) { $percent = [int][Math]::Floor([Math]::Min(100, 100.0 * $CompletedBytes / $TotalBytes)) }
    $operation = [pscustomobject]@{
        title='SQL Server Lab'; startedAt=$Progress.StartedAt; updatedAt=$Now
        progress=$(if ($percent -ge 0) { $percent } else { $null })
        steps=@([pscustomobject]@{title=$label}); currentStep=0; probe=$null
    }
    $rendered = @(Format-LabProgressStatus -Operation $operation -Tick $Progress.Tick -Now $Now)
    $detail = Format-LabElapsedTime -Elapsed ($Now - $Progress.StartedAt)
    if ($CompletedBytes -gt 0 -or $TotalBytes -gt 0) {
        $detail += " | $CompletedBytes Bytes"
        if ($TotalBytes -gt 0) { $detail += " / $TotalBytes Bytes" }
    }
    if ($ProbeCount -gt 0) { $detail += " | Probes: $ProbeCount" }
    Write-Progress -Id $Progress.Id -Activity 'SQL Server Lab' -Status ([string]$rendered[0]) `
        -CurrentOperation $detail -PercentComplete $percent
    $Progress.LastShownAt = $Now; $Progress.LastPhase = $Progress.Phase
    $Progress.Tick++; $Progress.Shown = $true
}

function Stop-LabActionProgress {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Progress)
    if ($Progress.Completed) { return }
    $Progress.Completed = $true
    if ($Progress.Shown) { Write-Progress -Id $Progress.Id -Activity 'SQL Server Lab' -Completed }
}

function Wait-LabProgressTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Threading.Tasks.Task]$Task,
        [Parameter(Mandatory)][object]$Progress,
        [long]$CompletedBytes = 0,
        [long]$TotalBytes = 0
    )
    while (-not $Task.IsCompleted) {
        Update-LabActionProgress -Progress $Progress -CompletedBytes $CompletedBytes -TotalBytes $TotalBytes
        # Sofort fortsetzen, sobald I/O fertig ist. Ein festes Sleep pro Block
        # wuerde grosse Downloads und VHDX-Kopien kuenstlich ausbremsen.
        try { $null = $Task.Wait(200) }
        catch [System.AggregateException] { }
    }
    # GetResult preserves the original failure, unlike Task.Wait's AggregateException.
    $Task.GetAwaiter().GetResult()
}

function Save-LabProgressDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [ValidateRange(1,86400)][int]$TimeoutSec = 1800,
        [ValidateRange(0,50)][int]$MaximumRedirection = 5,
        [ValidateRange(0,5)][int]$MaximumRetryCount = 0,
        [ValidateRange(1,60)][int]$RetryIntervalSec = 2
    )
    if ($Uri.Scheme -notin @('http','https') -or $Uri.UserInfo) { throw 'LAB_DOWNLOAD_URI_INVALID' }
    $progress = Start-LabActionProgress -Phase Download
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $MaximumRedirection -gt 0
    if ($MaximumRedirection -gt 0) { $handler.MaxAutomaticRedirections = $MaximumRedirection }
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    try {
        for ($attempt = 0; $attempt -le $MaximumRetryCount; $attempt++) {
            $cancellation = [System.Threading.CancellationTokenSource]::new([timespan]::FromSeconds($TimeoutSec))
            $response = $null; $source = $null; $destination = $null
            try {
                $request = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancellation.Token)
                $response = Wait-LabProgressTask -Task $request -Progress $progress
                $null = $response.EnsureSuccessStatusCode()
                $total = [long]$response.Content.Headers.ContentLength
                $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $destination = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
                $buffer = [byte[]]::new(1048576)
                $bytes = 0L
                while ($true) {
                    $read = Wait-LabProgressTask -Task ($source.ReadAsync($buffer, 0, $buffer.Length, $cancellation.Token)) `
                        -Progress $progress -CompletedBytes $bytes -TotalBytes $total
                    if ($read -eq 0) { break }
                    $null = Wait-LabProgressTask -Task ($destination.WriteAsync($buffer, 0, $read, $cancellation.Token)) `
                        -Progress $progress -CompletedBytes $bytes -TotalBytes $total
                    $bytes += $read
                    Update-LabActionProgress -Progress $progress -CompletedBytes $bytes -TotalBytes $total
                }
                if ($total -gt 0 -and $bytes -ne $total) { throw 'LAB_DOWNLOAD_LENGTH_MISMATCH' }
                return
            }
            catch {
                $cause = $_.Exception.GetBaseException()
                $retryable = $cause -is [System.Net.Http.HttpRequestException] -or $cause -is [System.OperationCanceledException]
                if ($attempt -ge $MaximumRetryCount -or -not $retryable) { throw }
            }
            finally {
                $cancellation.Cancel()
                if ($destination) { $destination.Dispose() }
                if ($source) { $source.Dispose() }
                if ($response) { $response.Dispose() }
                $cancellation.Dispose()
            }
            $delay = [System.Threading.Tasks.Task]::Delay($RetryIntervalSec * 1000)
            $null = Wait-LabProgressTask -Task $delay -Progress $progress
        }
    }
    finally { $client.Dispose(); Stop-LabActionProgress -Progress $progress }
}

function Invoke-LabProgressNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$ArgumentList,
        [ValidateSet('ImageBuild','Transfer','Restore','Import','GuestWait','Extract','SqlReadiness','SqlQuery')][string]$Phase = 'ImageBuild',
        [ValidateRange(1,86400)][int]$TimeoutSeconds = 3600,
        [object]$Progress
    )
    $ownsProgress = $null -eq $Progress
    if ($ownsProgress) { $Progress = Start-LabActionProgress -Phase $Phase }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo.FileName = $FilePath
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.WorkingDirectory = (Get-Location).ProviderPath
    foreach ($argument in $ArgumentList) { $process.StartInfo.ArgumentList.Add($argument) }
    $started = $false
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $started = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(200)) {
            Update-LabActionProgress -Progress $progress
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'LAB_NATIVE_OPERATION_TIMEOUT' }
        }
        $remaining = [timespan]::FromSeconds([Math]::Max(0.1, $TimeoutSeconds - $clock.Elapsed.TotalSeconds))
        $text = Wait-LabProgressTask -Task ($stdout.WaitAsync($remaining)) -Progress $progress
        $remaining = [timespan]::FromSeconds([Math]::Max(0.1, $TimeoutSeconds - $clock.Elapsed.TotalSeconds))
        $errorText = Wait-LabProgressTask -Task ($stderr.WaitAsync($remaining)) -Progress $progress
        $lines = @()
        if ($text.Length -gt 0) { $lines += @($text.TrimEnd("`r", "`n") -split '\r?\n') }
        if ($errorText.Length -gt 0) { $lines += @($errorText.TrimEnd("`r", "`n") -split '\r?\n') }
        [pscustomobject]@{ ExitCode=$process.ExitCode; Output=$lines }
    }
    finally {
        try {
            if ($started -and -not $process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(5000) }
        }
        finally {
            $process.StartInfo.ArgumentList.Clear()
            $ArgumentList = $null
            $process.Dispose()
            if ($ownsProgress) { Stop-LabActionProgress -Progress $Progress }
        }
    }
}
