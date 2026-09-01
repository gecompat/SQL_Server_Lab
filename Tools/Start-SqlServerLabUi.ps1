#Requires -Version 7.2
<#
.SYNOPSIS
    Startet die lokale SQL_Server_Lab-Workflow-Oberflaeche.
.DESCRIPTION
    Stellt ausschliesslich auf 127.0.0.1 eine kleine Browser-Oberflaeche bereit.
    Aktionen laufen als Thread-Jobs im selben erhöhten Prozess; Geheimnisse
    werden nicht geloggt oder persistiert.
.PARAMETER Port
    Lauscht auf diesem TCP-Port (Standard: 8484).
.PARAMETER JobStopTimeoutSeconds
    Legt fest, wie lange auf das beendende Herunterfahren offener
    Hintergrundjobs gewartet wird, bevor hart aufgeräumt wird.
.PARAMETER JobLogBurstLimit
    Begrenzt die Anzahl neuer Log-Zeilen, die pro Polling-Schritt in der UI
    angezeigt werden.
.PARAMETER NoBrowser
    Unterdrueckt den automatischen Aufruf von Browser/Startseite.
.PARAMETER ShowHelp
    Zeigt diese Hilfeseite an.
.EXAMPLE
    ./Tools/Start-SqlServerLabUi.ps1
.EXAMPLE
    ./Tools/Start-SqlServerLabUi.ps1 -Port 8080 -JobStopTimeoutSeconds 10 -JobLogBurstLimit 500
.EXAMPLE
    ./Tools/Start-SqlServerLabUi.ps1 -NoBrowser
.EXAMPLE
    ./Tools/Start-SqlServerLabUi.ps1 -ShowHelp
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Port = '8484',
    [Parameter(Position = 1)][string]$JobStopTimeoutSeconds = '5',
    [Parameter(Position = 2)][string]$JobLogBurstLimit = '300',
    [Alias('h', 'help', '?')][switch]$ShowHelp,
    [switch]$NoBrowser,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$extraArgs = @($RemainingArgs)
$helpTokens = @('/?', '-?', '-h', '--help', '-help')
$showHelpRequested = $ShowHelp.IsPresent -or
    $extraArgs -contains '/?' -or
    $extraArgs -contains '-?' -or
    $extraArgs -contains '-h' -or
    $extraArgs -contains '--help' -or
    ($null -ne $Port -and $Port -in $helpTokens) -or
    ($null -ne $JobStopTimeoutSeconds -and $JobStopTimeoutSeconds -in $helpTokens) -or
    ($null -ne $JobLogBurstLimit -and $JobLogBurstLimit -in $helpTokens)

function Show-Usage {
param(
    [string]$ScriptName = 'Start-SqlServerLabUi.ps1'
)
    Write-Host "$ScriptName" -ForegroundColor Cyan
    Write-Host 'Funktion:' -ForegroundColor Magenta
    Write-Host '  Startet die lokale Workflow-UI fuer SQL_Server_Lab auf 127.0.0.1.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Aufruf:' -ForegroundColor Magenta
    Write-Host "  .\$ScriptName [-Port <Int>] [-JobStopTimeoutSeconds <Int>] [-JobLogBurstLimit <Int>] [-NoBrowser] [-ShowHelp]" -ForegroundColor Cyan
    Write-Host "  .\$ScriptName -ShowHelp" -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Parameter:' -ForegroundColor Magenta
    Write-Host '  -Port <int>                 Listener-Port (Default: 8484).' -ForegroundColor Cyan
    Write-Host '  -JobStopTimeoutSeconds <int> Timeout beim Stoppen von Jobs (0..300). Default: 5.' -ForegroundColor Cyan
    Write-Host '  -JobLogBurstLimit <int>      Max neue Log-Zeilen pro Poll (1..2000). Default: 300.' -ForegroundColor Cyan
    Write-Host '  -NoBrowser                  Startet keinen Browser automatisch.' -ForegroundColor Cyan
    Write-Host '  -ShowHelp                   Zeigt diese Hilfe.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Beispiele:' -ForegroundColor Magenta
    Write-Host "  .\$ScriptName" -ForegroundColor Cyan
    Write-Host '  -> Startet die UI auf Port 8484.' -ForegroundColor Green
    Write-Host "  .\$ScriptName -Port 8080 -JobStopTimeoutSeconds 10" -ForegroundColor Cyan
    Write-Host '  -> Startet auf alternativem Port mit längerem Job-Stop-Timeout.' -ForegroundColor Green
    Write-Host "  .\$ScriptName -NoBrowser" -ForegroundColor Cyan
    Write-Host '  -> Startet die UI ohne automatischen Browseraufruf.' -ForegroundColor Green
    Write-Host "  .\$ScriptName -ShowHelp" -ForegroundColor Cyan
}

if ($showHelpRequested) {
    Show-Usage -ScriptName (Split-Path -Leaf $PSCommandPath)
    return
}

$parsedPort = 0
if (-not [int]::TryParse([string]$Port, [ref]$parsedPort)) {
    throw 'Parameter Port muss eine Ganzzahl zwischen 1025 und 65535 sein.'
}
if ($parsedPort -lt 1025 -or $parsedPort -gt 65535) {
    throw 'Parameter Port muss im Bereich 1025..65535 liegen.'
}
$Port = $parsedPort

$parsedJobStopTimeoutSeconds = 0
if (-not [int]::TryParse([string]$JobStopTimeoutSeconds, [ref]$parsedJobStopTimeoutSeconds)) {
    throw 'Parameter JobStopTimeoutSeconds muss eine Ganzzahl zwischen 0 und 300 sein.'
}
if ($parsedJobStopTimeoutSeconds -lt 0 -or $parsedJobStopTimeoutSeconds -gt 300) {
    throw 'Parameter JobStopTimeoutSeconds muss im Bereich 0..300 liegen.'
}
$JobStopTimeoutSeconds = $parsedJobStopTimeoutSeconds

$parsedJobLogBurstLimit = 0
if (-not [int]::TryParse([string]$JobLogBurstLimit, [ref]$parsedJobLogBurstLimit)) {
    throw 'Parameter JobLogBurstLimit muss eine Ganzzahl zwischen 1 und 2000 sein.'
}
if ($parsedJobLogBurstLimit -lt 1 -or $parsedJobLogBurstLimit -gt 2000) {
    throw 'Parameter JobLogBurstLimit muss im Bereich 1..2000 liegen.'
}
$JobLogBurstLimit = $parsedJobLogBurstLimit

$ErrorActionPreference = 'Stop'
$uiRoot = Join-Path $PSScriptRoot '..\Ui'
$modulePath = Join-Path $PSScriptRoot '..\SqlServerLab.psd1'
Import-Module $modulePath -Force 6>$null

function Write-UiResponse {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Body,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [int]$StatusCode = 200
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentEncoding = [Text.Encoding]::UTF8
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Get-UiJobSnapshot {
    param([Parameter(Mandatory)]$Record)

    $output = @()
    try {
        # Die UI-Meldungen sind Information-Records, damit sie nicht in der
        # Ergebnisvariable eines langen Fachbefehls verschwinden. Hier werden
        # sie bewusst in den Snapshot aufgenommen.
        $output = @(Receive-Job -Job $Record.Job -Keep -ErrorAction SilentlyContinue 2>&1 6>&1)
    }
    catch { $output = @($_) }
    $lines = @($output | ForEach-Object {
        $line = ($_ | Out-String).Trim()
        if ($line) { $line }
    })
    $burstLimit = [int]$JobLogBurstLimit
    if ($burstLimit -lt 1) { $burstLimit = 1 }
    $observed = [int]$Record.LastObservedLineCount
    if ($observed -lt 0) { $observed = 0 }
    if ($observed -gt $lines.Count) { $observed = 0 }
    $newLines = @()
    if ($lines.Count -gt $observed) {
        $newLines = $lines[$observed..($lines.Count - 1)]
        if ($newLines.Count -gt $burstLimit) {
            $newLines = $newLines[($newLines.Count - $burstLimit)..($newLines.Count - 1)]
        }
    }
    $state = [string]$Record.Job.State
    $startedAt = [datetimeoffset]::Parse(
        [string]$Record.StartedAt,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).UtcDateTime
    if ($state -eq 'Failed' -and $lines.Count -eq 0 -and $observed -eq 0) {
        $newLines = @('[FEHLER] Hintergrundaktion wurde abgebrochen.')
    }
    if ($observed -lt $lines.Count) {
        $Record.LastObservedLineCount = $lines.Count
        $Record.LastActivityAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    [PSCustomObject]@{
        Id = $Record.Id
        Action = $Record.Action
        State = $state
        StartedAt = $Record.StartedAt
        ElapsedSeconds = [math]::Max(0, [math]::Floor(((Get-Date).ToUniversalTime() - $startedAt).TotalSeconds))
        LastActivityAt = $Record.LastActivityAt
        Lines = $newLines
    }
}

function Start-UiWorkflowJob {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $id = [guid]::NewGuid().ToString('n')
    $job = Start-ThreadJob -Name "sql-lab-ui-$id" -ArgumentList $modulePath, $Action, $Parameters -ScriptBlock {
        param($JobModulePath, $JobAction, $JobParameters)
        $ErrorActionPreference = 'Stop'
        # Die Modul-Lader geben bewusst Information-Records aus. In einem
        # Hintergrundjob würden sie sonst bei jedem Poll im Host-Terminal landen.
        $InformationPreference = 'SilentlyContinue'
        $WarningPreference = 'SilentlyContinue'
        try {
            Import-Module $JobModulePath -Force 6>$null
            # Thread-Jobs teilen sich den Host mit der UI. Die zentralen
            # Lab-Ausgaben werden deshalb in Job-Pipeline-Records umgeleitet,
            # nicht in das Terminal des UI-Servers geschrieben.
            $global:SqlServerLabUiCaptureOutput = $true
            $invokeParameters = @{}
            foreach ($key in $JobParameters.Keys) { $invokeParameters[$key] = $JobParameters[$key] }
            if ($invokeParameters.ContainsKey('GuestPassword')) {
                $plainPassword = [string]$invokeParameters['GuestPassword']
                $invokeParameters.Remove('GuestPassword')
                $invokeParameters['GuestPassword'] = ConvertTo-SecureString -String $plainPassword -AsPlainText -Force
            }
            if ($invokeParameters.ContainsKey('SaPassword')) {
                $plainPassword = [string]$invokeParameters['SaPassword']
                $invokeParameters.Remove('SaPassword')
                $invokeParameters['SaPassword'] = ConvertTo-SecureString -String $plainPassword -AsPlainText -Force
            }
            Write-Output "[START] $JobAction"
            $null = Invoke-SqlServerLabWorkflowAction -Action $JobAction @invokeParameters
            Write-Output '[OK] Aktion erfolgreich abgeschlossen. Die Workflow-Ansicht wird aktualisiert.'
        }
        catch {
            Write-Output "[FEHLER] $($_.Exception.Message)"
            throw
        }
        finally {
            Remove-Variable -Name SqlServerLabUiCaptureOutput -Scope Global -ErrorAction SilentlyContinue
        }
    }
    return [PSCustomObject]@{
        Id = $id; Action = $Action; StartedAt = (Get-Date).ToUniversalTime().ToString('o')
        LastActivityAt = (Get-Date).ToUniversalTime().ToString('o'); LastObservedLineCount = 0; Job = $job
    }
}

# Die Medien- und Image-Erkennung kann große ISOs kurz einbinden und ist damit
# wesentlich teurer als ein Browser-Klick. Sie läuft deshalb separat; der
# HTTP-Listener bleibt für Jobs, Live-Log und weitere Klicks ansprechbar.
$workflowInventory = [PSCustomObject]@{
    Job = $null; Snapshot = $null; MediaRoot = $null; RequestedAt = $null
}

function Update-UiWorkflowInventory {
    if (-not $workflowInventory.Job) { return }
    if ($workflowInventory.Job.State -notin @('Completed', 'Failed', 'Stopped')) { return }
    try {
        if ($workflowInventory.Job.State -eq 'Completed') {
            $snapshot = @(Receive-Job -Job $workflowInventory.Job -ErrorAction Stop)
            if ($snapshot.Count -gt 0) { $workflowInventory.Snapshot = $snapshot[-1] }
        }
    }
    finally {
        Remove-Job -Job $workflowInventory.Job -Force -ErrorAction SilentlyContinue
        $workflowInventory.Job = $null
    }
}

function Get-UiWorkflowInventoryResponse {
    param([string]$MediaRoot)

    Update-UiWorkflowInventory
    $normalizedRoot = [string]$MediaRoot
    $requestedAt = if ($workflowInventory.RequestedAt) { [datetime]$workflowInventory.RequestedAt } else { [datetime]::MinValue }
    # Kurz cachen, damit das wiederholte Polling keine ISO-Scans auslöst, aber
    # nach einer Aktion neue Labs und Zustände rasch sichtbar werden.
    $isFresh = $workflowInventory.Snapshot -and $workflowInventory.MediaRoot -eq $normalizedRoot -and ((Get-Date) - $requestedAt).TotalSeconds -lt 5
    if (-not $isFresh -and -not $workflowInventory.Job) {
        $workflowInventory.MediaRoot = $normalizedRoot
        $workflowInventory.RequestedAt = Get-Date
        $workflowInventory.Job = Start-ThreadJob -Name 'sql-lab-ui-workflow-inventory' -ArgumentList $modulePath, $normalizedRoot -ScriptBlock {
            param($JobModulePath, $JobMediaRoot)
            $InformationPreference = 'SilentlyContinue'
            $WarningPreference = 'SilentlyContinue'
            Import-Module $JobModulePath -Force 6>$null
            Get-SqlServerLabWorkflow -MediaRoot $JobMediaRoot
        }
    }
    return [PSCustomObject]@{
        Refreshing = [bool]$workflowInventory.Job
        Snapshot = $workflowInventory.Snapshot
    }
}

if (-not (Test-Path -LiteralPath $uiRoot -PathType Container)) {
    throw "UI_ROOT_NOT_FOUND: $uiRoot"
}

$listener = [Net.HttpListener]::new()
$url = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($url)
$listener.Start()
$jobs = @{}

Write-Host "SQL_Server_Lab Workflow UI: $url" -ForegroundColor Green
Write-Host 'Zum Beenden Strg+C druecken.' -ForegroundColor DarkGray
Write-Host "Job-Stop-Timeout beim Beenden: ${JobStopTimeoutSeconds}s (Parameter: -JobStopTimeoutSeconds)." -ForegroundColor DarkGray
Write-Host "Log-Burst-Limit pro Snapshot: ${JobLogBurstLimit} Zeilen (Parameter: -JobLogBurstLimit)." -ForegroundColor DarkGray
if (-not $NoBrowser) { Start-Process $url }

try {
    while ($listener.IsListening) {
        try {
            $context = $listener.GetContext()
        }
        catch {
            if (-not $listener.IsListening) { break }
            if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) { break }
            throw
        }
        try {
            if (-not [Net.IPAddress]::IsLoopback($context.Request.RemoteEndPoint.Address)) {
                Write-UiResponse -Context $context -Body 'Nur lokaler Zugriff ist erlaubt.' -StatusCode 403
                continue
            }

            $path = $context.Request.Url.AbsolutePath
            if ($path -eq '/api/workflow' -and $context.Request.HttpMethod -eq 'GET') {
                $mediaRoot = [string]$context.Request.QueryString['mediaRoot']
                Write-UiResponse -Context $context -Body (Get-UiWorkflowInventoryResponse -MediaRoot $mediaRoot | ConvertTo-Json -Depth 12) -ContentType 'application/json; charset=utf-8'
                continue
            }
            if ($path -eq '/api/jobs' -and $context.Request.HttpMethod -eq 'GET') {
                $snapshot = @($jobs.Values | ForEach-Object { Get-UiJobSnapshot -Record $_ } | Sort-Object StartedAt -Descending)
                Write-UiResponse -Context $context -Body (ConvertTo-Json -InputObject $snapshot -Depth 8) -ContentType 'application/json; charset=utf-8'
                continue
            }
            if ($path -eq '/api/config' -and $context.Request.HttpMethod -eq 'GET') {
                Write-UiResponse -Context $context -Body (@{ jobLogBurstLimit = $JobLogBurstLimit } | ConvertTo-Json -Depth 4) -ContentType 'application/json; charset=utf-8'
                continue
            }
            if ($path -eq '/api/queue' -and $context.Request.HttpMethod -eq 'GET') {
                Write-UiResponse -Context $context -Body (Get-SqlServerLabQueue | ConvertTo-Json -Depth 20) -ContentType 'application/json; charset=utf-8'
                continue
            }
            if ($path -eq '/api/batches' -and $context.Request.HttpMethod -eq 'POST') {
                $body = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding).ReadToEnd()
                $request = $body | ConvertFrom-Json -Depth 30
                $batch = New-SqlServerLabBatch -Name ([string]$request.name) -Priority $(if ($request.priority) { [string]$request.priority } else { 'Normal' }) -Defaults $request.defaults -Items @($request.items) -Queue:$false
                Write-UiResponse -Context $context -Body ($batch | ConvertTo-Json -Depth 30) -ContentType 'application/json; charset=utf-8' -StatusCode 201
                continue
            }
            if ($path -eq '/api/operations' -and $context.Request.HttpMethod -eq 'POST') {
                $body = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding).ReadToEnd()
                $request = $body | ConvertFrom-Json -Depth 12
                $operationId = [string]$request.operationId
                $result = switch ([string]$request.command) {
                    'Confirm' {
                        $credential = $null
                        if ($request.userName -and $request.password) {
                            $secure = [SecureString]::new()
                            foreach ($character in ([string]$request.password).ToCharArray()) { $secure.AppendChar($character) }
                            $secure.MakeReadOnly()
                            $credential = [PSCredential]::new([string]$request.userName, $secure)
                        }
                        Confirm-SqlServerLabOperationUserAction -OperationId $operationId -Credential $credential
                    }
                    'Probe' { & (Get-Module SqlServerLab) { param($Id) Invoke-SqlServerLabOperationProbe -OperationId $Id } $operationId }
                    'Suspend' { Suspend-SqlServerLabOperation -OperationId $operationId }
                    'Resume' { Resume-SqlServerLabOperation -OperationId $operationId }
                    'MoveUp' { Move-SqlServerLabOperation -OperationId $operationId -Direction Up }
                    'MoveDown' { Move-SqlServerLabOperation -OperationId $operationId -Direction Down }
                    'PriorityHigh' { Set-SqlServerLabOperationPriority -OperationId $operationId -Priority High }
                    'PriorityNormal' { Set-SqlServerLabOperationPriority -OperationId $operationId -Priority Normal }
                    'PriorityLow' { Set-SqlServerLabOperationPriority -OperationId $operationId -Priority Low }
                    'StopCleanup' { Stop-SqlServerLabOperation -OperationId $operationId -Cleanup -Confirm:$false }
                    'SubmitBatch' { & (Get-Module SqlServerLab) { param($Id) Submit-SqlServerLabBatch -BatchId $Id } ([string]$request.batchId) }
                    default { throw "Unbekanntes Operation-Kommando '$($request.command)'." }
                }
                try { & (Get-Module SqlServerLab) { Start-SqlServerLabOperationHost } } catch { }
                Write-UiResponse -Context $context -Body ($result | ConvertTo-Json -Depth 20) -ContentType 'application/json; charset=utf-8'
                continue
            }
            if ($path -eq '/api/persistent-storage/removal-plan' -and $context.Request.HttpMethod -eq 'POST') {
                $body = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding).ReadToEnd()
                $request = $body | ConvertFrom-Json -Depth 30
                $runId = [string]$request.runId
                $selections = @($request.selections)
                if (-not $runId -or $selections.Count -eq 0) {
                    throw 'PERSISTENT_STORAGE_REMOVAL_PREVIEW_INPUT_REQUIRED'
                }
                $plan = Get-SqlServerLabPersistentStorageRemovalPlan -RunId $runId -Selection $selections
                Write-UiResponse -Context $context -Body ($plan | ConvertTo-Json -Depth 30) -ContentType 'application/json; charset=utf-8'
                continue
            }
            if ($path -eq '/api/actions' -and $context.Request.HttpMethod -eq 'POST') {
                $body = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding).ReadToEnd()
                $request = $body | ConvertFrom-Json -Depth 8
                $action = [string]$request.action
                $parameters = @{}
                if ($request.parameters) {
                    foreach ($property in $request.parameters.PSObject.Properties) {
                        if ($property.Name -notin @('Action', 'GuestPassword', 'SaPassword')) {
                            $parameters[$property.Name] = $property.Value
                        }
                    }
                    if ($request.parameters.PSObject.Properties.Name -contains 'GuestPassword') {
                        $parameters['GuestPassword'] = [string]$request.parameters.GuestPassword
                    }
                    if ($request.parameters.PSObject.Properties.Name -contains 'SaPassword') {
                        $parameters['SaPassword'] = [string]$request.parameters.SaPassword
                    }
                }
                $hasTransientSecret = $parameters.ContainsKey('GuestPassword') -or $parameters.ContainsKey('SaPassword')
                if (-not $hasTransientSecret -and $action -ne 'Refresh') {
                    $resourceClass = if ($action -match 'WindowsBuild|SqlBuild|HyperVLab|HyperVImage') { 'HyperVHeavy' } elseif ($action -match 'MediaRoot|DataRoot|Storage') { 'ExclusiveStorage' } else { 'LifecycleLight' }
                    $targetId = if ($parameters.ContainsKey('BuildId')) { [string]$parameters.BuildId } elseif ($parameters.ContainsKey('ArtifactId')) { [string]$parameters.ArtifactId } elseif ($parameters.ContainsKey('LabName')) { [string]$parameters.LabName } else { $action }
                    $batch = New-SqlServerLabBatch -Name "Browser: $action" -Items @([pscustomobject]@{
                        id = ("ui-$action-" + [guid]::NewGuid().ToString('n').Substring(0, 6)).ToLowerInvariant()
                        kind = 'Action'
                        count = 1
                        intent = [pscustomobject]@{
                            WorkflowAction = $action
                            WorkflowParameters = [pscustomobject]$parameters
                            ResourceClass = $resourceClass
                            Locks = @("ui-resource:$targetId")
                            ProviderPreference = 'Auto'
                        }
                    })
                    try { & (Get-Module SqlServerLab) { Start-SqlServerLabOperationHost } } catch { }
                    Write-UiResponse -Context $context -Body (@{ id = $batch.batchId; action = $action; persistent = $true; operationIds = $batch.operationIds } | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 202
                    continue
                }
                # Geheimnisse werden niemals im persistenten Batch abgelegt.
                $record = Start-UiWorkflowJob -Action $action -Parameters $parameters
                $jobs[$record.Id] = $record
                Write-UiResponse -Context $context -Body (@{ id = $record.Id; action = $action } | ConvertTo-Json -Compress) -ContentType 'application/json; charset=utf-8' -StatusCode 202
                continue
            }

            $relativePath = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
            if ($relativePath -notmatch '^[a-zA-Z0-9._-]+$') {
                Write-UiResponse -Context $context -Body 'Nicht gefunden.' -StatusCode 404
                continue
            }
            $filePath = Join-Path $uiRoot $relativePath
            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                Write-UiResponse -Context $context -Body 'Nicht gefunden.' -StatusCode 404
                continue
            }
            $contentType = switch ([IO.Path]::GetExtension($filePath)) {
                '.html' { 'text/html; charset=utf-8' }
                '.css' { 'text/css; charset=utf-8' }
                '.js' { 'application/javascript; charset=utf-8' }
                default { 'application/octet-stream' }
            }
            Write-UiResponse -Context $context -Body (Get-Content -LiteralPath $filePath -Raw -Encoding utf8) -ContentType $contentType
        }
        catch {
            try { Write-UiResponse -Context $context -Body ("Fehler: " + $_.Exception.Message) -StatusCode 500 } catch { }
        }
    }
}
finally {
    if ($jobs.Count -gt 0) { Write-Host "Beende $($jobs.Count) UI-Job(s)..." -ForegroundColor DarkGray }
    if ($workflowInventory.Job) {
        if ($workflowInventory.Job.State -eq 'Running') { Stop-Job -Job $workflowInventory.Job -ErrorAction SilentlyContinue }
        Remove-Job -Job $workflowInventory.Job -Force -ErrorAction SilentlyContinue
    }
    foreach ($record in $jobs.Values) {
        $job = $record.Job
        $state = [string]$job.State
        if ($state -eq 'Running' -or $state -eq 'NotStarted') {
            Write-Host "Job $($record.Id) ($($record.Action)) beendet: Zustand '$state'..." -ForegroundColor DarkGray
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            if (-not (Wait-Job -Job $job -Timeout $JobStopTimeoutSeconds)) {
                Write-Host "Job $($record.Id) reagierte nicht auf Stop; wird hart bereinigt." -ForegroundColor DarkYellow
            }
        }
        elseif ($state -eq 'Blocked') {
            Write-Host "Job $($record.Id) ($($record.Action)) ist blockiert; warte auf Beendigung..." -ForegroundColor DarkYellow
            if (-not (Wait-Job -Job $job -Timeout $JobStopTimeoutSeconds)) {
                Write-Host "Job $($record.Id) reagierte nicht auf Beendigung; wird hart bereinigt." -ForegroundColor DarkYellow
            }
        }
        else {
            Write-Host "Job $($record.Id) ($($record.Action)) bereits abgeschlossen (Zustand '$state')." -ForegroundColor DarkGray
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
    if ($jobs.Count -gt 0) { Write-Host 'UI-Job-Bereinigung abgeschlossen.' -ForegroundColor DarkGray }
    $listener.Stop()
    $listener.Close()
}
