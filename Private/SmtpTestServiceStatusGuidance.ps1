function Get-LabSmtpStatusGuidanceCandidates {
    param([Parameter(Mandatory)][string]$StateRoot)

    $candidates = foreach ($run in @(Get-LabActiveRuns -StateRoot $StateRoot -NoWrite)) {
        $runId = [string]$run.runId
        if ($runId -cnotmatch '^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$') { continue }
        $connectionPath = Join-Path $StateRoot "runs/$runId/connection-info.json"
        if (-not (Test-LabPathWithinRoot -Root $StateRoot -Path $connectionPath).Valid -or
            -not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { continue }
        try { $connection = Read-LabWorkflowJson -Path $connectionPath }
        catch { continue }
        if ($null -eq $connection.smtpTestService) { continue }
        [pscustomobject]@{ RunId=$runId; Name=([string]$run.metadata.name -replace '[\x00-\x1f\x7f-\x9f]',' ') }
    }
    $candidates | Sort-Object Name,RunId -Unique
}

function Get-LabSmtpStatusGuidance {
    param([string]$RunId, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $candidates = @(Get-LabSmtpStatusGuidanceCandidates -StateRoot $StateRoot)
    $contract = 'SqlServerLab.SmtpStatusGuidance/1.0'
    if (-not $RunId) { return [pscustomobject]@{ContractVersion=$contract; Candidates=$candidates} }
    if (@($candidates | Where-Object RunId -CEQ $RunId).Count -ne 1) { throw 'SMTP_STATUS_SELECTION_UNAVAILABLE' }
    $observed = Get-SqlServerLabSmtpTestServiceStatus -RunId $RunId -StateRoot $StateRoot
    [pscustomobject]@{
        ContractVersion=$contract; RunId=$observed.RunId; Provider=$observed.Provider
        ReceiverStatus=$observed.ReceiverStatus; Status=$observed.Status; Reason=$observed.Reason
    }
}

function Invoke-LabSmtpStatusGuidanceRequest {
    param([string]$Method, [Collections.Specialized.NameValueCollection]$Query)

    if ($Method -cne 'GET') { return @{StatusCode=405; View=@{Code='SMTP_STATUS_REQUEST_INVALID'}} }
    $runId = [string]$Query['runId']
    if (@($Query.AllKeys | Where-Object { $_ -cne 'runId' }).Count -or
        ($Query.Count -and $runId -cnotmatch '^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$')) {
        return @{StatusCode=400; View=@{Code='SMTP_STATUS_REQUEST_INVALID'}}
    }
    try { return @{StatusCode=200; View=(Get-LabSmtpStatusGuidance -RunId $runId)} }
    catch { return @{StatusCode=503; View=@{Code='SMTP_STATUS_UNAVAILABLE'}} }
}

function Open-LabGuidedSmtpWebMail {
    param([string]$RunId, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $selected = @(Get-LabSmtpStatusGuidanceCandidates -StateRoot $StateRoot | Where-Object RunId -CEQ $RunId)
    if ($selected.Count -ne 1) { throw 'SMTP_STATUS_SELECTION_UNAVAILABLE' }
    $access = Open-SqlServerLabSmtpTestServiceWebMail -RunId $RunId -StateRoot $StateRoot -Confirm:$false
    if ($access.Status -cne 'OPENED' -or $access.BrowserStarted -ne $true) { throw 'SMTP_WEBMAIL_OPEN_UNCONFIRMED' }
    [pscustomobject]@{ContractVersion='SqlServerLab.GuidedSmtpWebMailOpen/1.0';RunId=$RunId;Status='OPENED'}
}

function Invoke-LabGuidedSmtpWebMailRequest {
    param([string]$Json)

    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse($Json)
        $body = $document.RootElement
        if ($body.ValueKind -ne [Text.Json.JsonValueKind]::Object -or @($body.EnumerateObject()).Count -ne 2 -or
            $body.GetProperty('RunId').ValueKind -ne [Text.Json.JsonValueKind]::String -or
            $body.GetProperty('Confirmed').ValueKind -ne [Text.Json.JsonValueKind]::True) { throw 'SMTP_WEBMAIL_OPEN_REQUEST_INVALID' }
        $runId = $body.GetProperty('RunId').GetString()
        if ($runId -cnotmatch '^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$') { throw 'SMTP_WEBMAIL_OPEN_REQUEST_INVALID' }
    }
    catch { return @{StatusCode=400; View=@{Code='SMTP_WEBMAIL_OPEN_REQUEST_INVALID'}} }
    finally { if ($document) { $document.Dispose() } }
    try { return @{StatusCode=200; View=(Open-LabGuidedSmtpWebMail -RunId $runId)} }
    catch { return @{StatusCode=503; View=@{Code='SMTP_WEBMAIL_OPEN_UNAVAILABLE'}} }
}

function Show-LabSmtpStatusGuidanceInteractive {
    $stateRoot = Get-LabStateRoot
    $items = @(foreach ($run in @(Get-LabSmtpStatusGuidanceCandidates -StateRoot $stateRoot)) {
        New-LabConsoleItem -Id $run.RunId -Label $(if ($run.Name) { $run.Name } else { 'SMTP-Lab' }) -Value $run.RunId -Data $run.RunId
    })
    if (-not $items.Count) {
        Write-LabInfo 'Es ist kein Lab mit SMTP-Testdienst registriert.'
        $null = Wait-LabConsoleAcknowledgement
        return
    }
    $selected = Select-LabConsoleDataItem -ScreenId 'smtp-status-target' -Title 'SMTP-Testdienst prüfen' -Items $items
    if (-not $selected) { return }
    try {
        $result = Get-LabSmtpStatusGuidance -RunId $selected -StateRoot $stateRoot
        Write-LabInfo ('{0} · Mailpit: {1} · {2}' -f $result.Provider,$result.ReceiverStatus,$result.Reason)
        Write-LabInfo 'Der Befund prüft die Receiver-Bindung und den Containerzustand. Die Zustellung von Testmails wird separat geprüft.'
        if ($result.Status -ceq 'READY') {
            $next = Show-LabSubMenu -ScreenId 'smtp-webmail-action' -Title 'Lokaler Mailpit-Zugang' -Items @(
                New-LabConsoleItem -Id 'open' -Label 'WebMail für 15 Minuten öffnen' -Value 'Testmails lesen und löschen'
                New-LabConsoleItem -Id 'back' -Label 'Zurück' -Shortcut 0
            )
            if ($next -cne 'open') { return }
            $null = Open-LabGuidedSmtpWebMail -RunId $selected -StateRoot $stateRoot
            Write-LabInfo 'WebMail wurde im Standardbrowser geöffnet.'
        }
    }
    catch { Write-LabError 'Der SMTP-Testdienst des ausgewählten Labs konnte nicht eindeutig geprüft werden.' }
    $null = Wait-LabConsoleAcknowledgement
}
