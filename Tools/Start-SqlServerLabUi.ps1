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
        $output = @(Receive-Job -Job $Record.Job -Keep -ErrorAction SilentlyContinue 2>&1)
    }
    catch { $output = @($_) }
    $lines = @($output | ForEach-Object {
        $line = ($_ | Out-String).Trim()
        if ($line) { $line }
    })
    $state = [string]$Record.Job.State
    if ($state -eq 'Failed' -and $lines.Count -eq 0) {
        $lines = @('[FEHLER] Hintergrundaktion wurde abgebrochen.')
    }
    [PSCustomObject]@{
        Id = $Record.Id
        Action = $Record.Action
        State = $state
        StartedAt = $Record.StartedAt
        ElapsedSeconds = [math]::Max(0, [math]::Floor(((Get-Date).ToUniversalTime() - [datetime]$Record.StartedAt).TotalSeconds))
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
    }
    return [PSCustomObject]@{
        Id = $id; Action = $Action; StartedAt = (Get-Date).ToUniversalTime().ToString('o'); Job = $job
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
                Write-UiResponse -Context $context -Body (Get-SqlServerLabWorkflow | ConvertTo-Json -Depth 12) -ContentType 'application/json; charset=utf-8'
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
                $running = @($jobs.Values | Where-Object { $_.Job.State -in @('Running', 'NotStarted') })
                if ($running.Count -gt 0) {
                    Write-UiResponse -Context $context -Body 'Eine Hintergrundaktion läuft bereits. Bitte ihren Abschluss abwarten.' -StatusCode 409
                    continue
                }
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
    foreach ($record in $jobs.Values) {
        if ($record.Job.State -eq 'Running') { Stop-Job -Job $record.Job -ErrorAction SilentlyContinue }
        Remove-Job -Job $record.Job -Force -ErrorAction SilentlyContinue
    }
    $listener.Stop()
    $listener.Close()
}
