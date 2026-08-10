#Requires -Version 7.2
<#
.SYNOPSIS
    Startet die lokale SQL_Server_Lab-Workflow-Oberflaeche.
.DESCRIPTION
    Stellt ausschliesslich auf 127.0.0.1 eine kleine Browser-Oberflaeche bereit.
    Aktionen laufen als Thread-Jobs im selben erhöhten Prozess; Geheimnisse
    werden nicht geloggt oder persistiert.
.EXAMPLE
    ./Tools/Start-SqlServerLabUi.ps1
#>
[CmdletBinding()]
param(
    [ValidateRange(1025, 65535)][int]$Port = 8484,
    [switch]$NoBrowser
)

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
    $state = [string]$Record.Job.State
    $startedAt = [datetimeoffset]::Parse(
        [string]$Record.StartedAt,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).UtcDateTime
    if ($state -eq 'Failed' -and $lines.Count -eq 0) {
        $lines = @('[FEHLER] Hintergrundaktion wurde abgebrochen.')
    }
    if ($Record.LastObservedLineCount -lt $lines.Count) {
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
        Lines = $lines
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
if (-not $NoBrowser) { Start-Process $url }

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
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
                Write-UiResponse -Context $context -Body ($snapshot | ConvertTo-Json -Depth 8) -ContentType 'application/json; charset=utf-8'
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
                # Unabhängige Workflows (etwa Image-Build und Container-Lab)
                # dürfen parallel gestartet werden. Fachbefehle prüfen ihre
                # jeweiligen Ressourcen weiterhin selbst.
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
    if ($workflowInventory.Job) {
        if ($workflowInventory.Job.State -eq 'Running') { Stop-Job -Job $workflowInventory.Job -ErrorAction SilentlyContinue }
        Remove-Job -Job $workflowInventory.Job -Force -ErrorAction SilentlyContinue
    }
    foreach ($record in $jobs.Values) {
        if ($record.Job.State -eq 'Running') { Stop-Job -Job $record.Job -ErrorAction SilentlyContinue }
        Remove-Job -Job $record.Job -Force -ErrorAction SilentlyContinue
    }
    $listener.Stop()
    $listener.Close()
}
