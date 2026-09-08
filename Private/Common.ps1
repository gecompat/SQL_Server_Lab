<#
.SYNOPSIS
    Gemeinsame Hilfsfunktionen fuer SQL_Server_Lab.
.DESCRIPTION
    Logging, Farbausgabe, Eingabe-Prompts, Encoding-Hilfsmittel.
    Wird von SqlServerLab.psm1 automatisch geladen.
#>

# --- Modul-weite Konfiguration ---
$script:LabModuleName = 'SqlServerLab'
$script:LabVersion = '0.1.0'
$script:LabConsoleInputCancellationCode = 'LAB_CONSOLE_INPUT_CANCELLED'

function Test-LabConsoleInputCancellation {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject) { return $false }
    $candidate = if ($InputObject -is [Management.Automation.ErrorRecord]) { $InputObject.Exception } else { $InputObject }
    while ($candidate -is [Exception]) {
        if ([string]$candidate.Message -match [regex]::Escape($script:LabConsoleInputCancellationCode)) { return $true }
        $candidate = $candidate.InnerException
    }
    return ([string]$InputObject -match [regex]::Escape($script:LabConsoleInputCancellationCode))
}

function New-LabConsoleInputCancellationException {
    [CmdletBinding()]
    param()

    return [OperationCanceledException]::new($script:LabConsoleInputCancellationCode)
}

function Read-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Prompt = '',
        [switch]$AsSecureString,
        [switch]$MaskInput,
        [AllowNull()][object]$Capability,
        [scriptblock]$ReadInput,
        [scriptblock]$ReadKey,
        [scriptblock]$WriteText
    )

    $arguments = @{
        Prompt = [string]$Prompt
        AsSecureString = $AsSecureString
        MaskInput = $MaskInput
    }
    if ($PSBoundParameters.ContainsKey('Capability')) { $arguments.Capability = $Capability }
    if ($ReadInput) { $arguments.ReadInput = $ReadInput }
    if ($ReadKey) { $arguments.ReadKey = $ReadKey }
    if ($WriteText) { $arguments.WriteText = $WriteText }
    $result = Read-LabConsoleTextInput @arguments
    if ($result.Status -ne 'Confirmed') { throw (New-LabConsoleInputCancellationException) }
    return $result.Value
}

function Get-LabBuildInfo {
    <#
    .SYNOPSIS Liefert die tatsächlich geladene Modulversion und Quellrevision.
    .DESCRIPTION Die Information wird pro Modulsitzung einmal ermittelt. Damit
    zeigt das Konsolenbanner nach einem Import direkt, aus welchem Checkout die
    gerade ausgeführten Funktionen stammen.
    #>
    [CmdletBinding()]
    param()

    if ($script:LabBuildInfo) { return $script:LabBuildInfo }
    $revision = 'ohne-git-revision'
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git -and $script:ModuleRoot -and (Test-Path -LiteralPath (Join-Path $script:ModuleRoot '.git'))) {
        try {
            $candidate = @(& $git.Source -C $script:ModuleRoot rev-parse --short=8 HEAD 2>$null | Select-Object -First 1)[0]
            if ($candidate -match '^[a-f0-9]{7,40}$') { $revision = [string]$candidate }
        }
        catch { }
    }
    $script:LabBuildInfo = [PSCustomObject]@{
        Version = $script:LabVersion
        Revision = $revision
        Source = [string]$script:ModuleRoot
        Display = "$($script:LabVersion) · $revision"
    }
    return $script:LabBuildInfo
}

# --- Farbdefinitionen ---
$script:Colors = @{
    Info    = 'Cyan'
    Success = 'Green'
    Warning = 'Yellow'
    Error   = 'Red'
    Prompt  = 'White'
    Header  = 'Magenta'
    Muted   = 'DarkGray'
}

# =============================================================================
# Meldungsjournal
# =============================================================================

# Meldungen sind Daten, nicht Bildschirmausgabe: ein neu gezeichneter Rahmen darf
# keine Warnung oder Fehlermeldung vernichten.
$script:LabMessageJournal = [System.Collections.Generic.List[object]]::new()
$script:LabMessageJournalLimit = 2000
$script:LabMessageSequence = 0
$script:LabMessageSessionId = $null
$script:LabMessageJournalPath = $null
$script:LabMessageJournalDisabled = $false
$script:LabProviderLogDisabled = $false

function Get-LabMessageSessionId {
    <#
    .SYNOPSIS Stabile Kennung der laufenden Modulsitzung fuer das Meldungsjournal.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:LabMessageSessionId) {
        $script:LabMessageSessionId = '{0:yyyyMMdd-HHmmss}-{1}' -f [datetime]::UtcNow, [guid]::NewGuid().ToString('N').Substring(0, 8)
    }
    return $script:LabMessageSessionId
}

function Get-LabMessageJournalPath {
    <#
    .SYNOPSIS Pfad der Append-only-Journaldatei der aktuellen Sitzung.
    .DESCRIPTION Liefert $null, solange kein State-Root aufloesbar ist. Das
    Journal bleibt dann rein speicherbasiert; Logging darf nie scheitern.
    #>
    [CmdletBinding()]
    param()

    if ($script:LabMessageJournalPath) { return $script:LabMessageJournalPath }
    if (-not (Get-Command -Name Get-LabStateRoot -ErrorAction SilentlyContinue)) { return $null }
    try {
        $stateRoot = Get-LabStateRoot
        # Ein relativer State-Root wuerde Journale in das jeweilige Arbeitsverzeichnis streuen.
        if (-not $stateRoot -or -not [IO.Path]::IsPathRooted($stateRoot)) { return $null }
        $sessionDir = Join-Path (Join-Path $stateRoot 'session') (Get-LabMessageSessionId)
        $script:LabMessageJournalPath = Join-Path $sessionDir 'messages.jsonl'
        return $script:LabMessageJournalPath
    }
    catch { return $null }
}

function Protect-LabMessageText {
    <#
    .SYNOPSIS Entfernt Secrets aus Text, bevor er journalisiert oder kopiert wird.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $result = $Text
    foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
        if ([string]$entry.Key -notlike 'SQL_SERVER_LAB_SECRET_*') { continue }
        $secret = [string]$entry.Value
        if ($secret.Length -lt 4) { continue }
        $result = $result.Replace($secret, '***')
    }
    return [regex]::Replace(
        $result,
        '(?i)\b(SA_PASSWORD|MSSQL_SA_PASSWORD|PASSWORD|PWD)\s*[=:]\s*("[^"]*"|''[^'']*''|\S+)',
        '$1=***')
}

function Write-LabMessageJournalRecord {
    <#
    .SYNOPSIS Haengt einen Meldungssatz an die Journaldatei an.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Record)

    if ($script:LabMessageJournalDisabled) { return }
    $path = Get-LabMessageJournalPath
    if (-not $path) { return }
    try {
        $directory = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $directory)) { New-Item -Path $directory -ItemType Directory -Force | Out-Null }
        $line = ($Record | ConvertTo-Json -Depth 6 -Compress) + [Environment]::NewLine
        [IO.File]::AppendAllText($path, $line, [Text.UTF8Encoding]::new($false))
    }
    catch {
        # Ein nicht schreibbares Journal darf die Bedienung nie unterbrechen.
        $script:LabMessageJournalDisabled = $true
    }
}

function Add-LabMessage {
    <#
    .SYNOPSIS Journalisiert eine Meldung und liefert den Satz mit stabiler MessageId.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Info', 'Success', 'Warning', 'Error')][string]$Severity,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [string]$Code = '',
        [string]$Detail = '',
        [string]$ScreenId = '',
        [string]$OperationId = '',
        [string]$RunId = ''
    )

    $script:LabMessageSequence++
    $prefix = switch ($Severity) { 'Error' { 'E' } 'Warning' { 'W' } 'Success' { 'S' } default { 'I' } }
    $safeMessage = Protect-LabMessageText -Text $Message
    if (-not $Code -and $safeMessage -match '^([A-Z][A-Z0-9]*(?:_[A-Z0-9]+){2,})\b') { $Code = $Matches[1] }
    $record = [PSCustomObject]@{
        contract    = 'SqlServerLab.Message/1.0'
        sequence    = $script:LabMessageSequence
        messageId   = '{0}-{1:x4}' -f $prefix, $script:LabMessageSequence
        timestamp   = [datetime]::UtcNow.ToString('o')
        severity    = $Severity
        code        = [string]$Code
        message     = $safeMessage
        detail      = [string](Protect-LabMessageText -Text $Detail)
        screenId    = $ScreenId
        operationId = $OperationId
        runId       = $RunId
    }
    $script:LabMessageJournal.Add($record)
    while ($script:LabMessageJournal.Count -gt $script:LabMessageJournalLimit) { $script:LabMessageJournal.RemoveAt(0) }
    Write-LabMessageJournalRecord -Record $record
    return $record
}

function Get-LabMessage {
    <#
    .SYNOPSIS Liest das Meldungsjournal der laufenden Sitzung.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Info', 'Success', 'Warning', 'Error')][string[]]$Severity,
        [string]$MessageId
    )

    $items = @($script:LabMessageJournal)
    if ($MessageId) { $items = @($items | Where-Object { $_.messageId -eq $MessageId }) }
    if ($Severity) { $items = @($items | Where-Object { $_.severity -in $Severity }) }
    return $items
}

function Get-LabProviderLogPath {
    <#
    .SYNOPSIS Pfad des Provider-Diagnoselogs eines Runs oder der Sitzung.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$RunId = '', [AllowEmptyString()][string]$StateRoot = '')

    $root = $StateRoot
    if (-not $root) {
        if (-not (Get-Command -Name Get-LabStateRoot -ErrorAction SilentlyContinue)) { return $null }
        try { $root = Get-LabStateRoot } catch { return $null }
    }
    if (-not $root -or -not [IO.Path]::IsPathRooted($root)) { return $null }
    if ($RunId) { return Join-Path (Join-Path (Join-Path (Join-Path $root 'runs') $RunId) 'log') 'provider.log' }
    return Join-Path (Join-Path (Join-Path $root 'session') (Get-LabMessageSessionId)) 'provider.log'
}

function Write-LabProviderLog {
    <#
    .SYNOPSIS Persistiert Provider-Ausgabe fuer die spaetere Diagnose.
    .DESCRIPTION Ohne diese Persistenz ist die Ausgabe eines erfolgreichen Laufs
    verloren und nur ein Fehlschlag hinterlaesst Text in der Ausnahme. Kommando
    und Ausgabe werden vor dem Schreiben von Secrets bereinigt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Phase,
        [AllowEmptyString()][string]$Command = '',
        [AllowNull()][object]$Output,
        [int]$ExitCode = 0,
        [AllowEmptyString()][string]$RunId = '',
        [AllowEmptyString()][string]$StateRoot = '',
        [ValidateRange(1, 1073741824)][long]$MaximumBytes = 4194304,
        [ValidateRange(1, 20)][int]$ArchiveCount = 3
    )

    if ($script:LabProviderLogDisabled) { return $null }
    $path = Get-LabProviderLogPath -RunId $RunId -StateRoot $StateRoot
    if (-not $path) { return $null }
    try {
        $directory = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $directory)) { New-Item -Path $directory -ItemType Directory -Force | Out-Null }
        $builder = [System.Text.StringBuilder]::new()
        $null = $builder.AppendLine(('=== {0} {1} {2} exit={3}' -f @([datetime]::UtcNow.ToString('o'), $Provider, $Phase, $ExitCode)))
        if ($Command) { $null = $builder.AppendLine('$ ' + (Protect-LabMessageText -Text $Command)) }
        foreach ($line in @($Output)) {
            if ($null -eq $line) { continue }
            $null = $builder.AppendLine((Protect-LabMessageText -Text ([string]$line)))
        }
        $encoding = [Text.UTF8Encoding]::new($false)
        $entry = $builder.ToString()
        $entryBytes = $encoding.GetByteCount($entry)
        if ($entryBytes -gt $MaximumBytes) {
            $truncationMarker = "`n... [provider log entry truncated] ...`n"
            $markerBytes = $encoding.GetByteCount($truncationMarker)
            if ($MaximumBytes -le $markerBytes) {
                $entry = $truncationMarker.Substring(0, [int]$MaximumBytes)
            }
            else {
                # Vier Bytes pro UTF-16-Zeichen sind eine konservative
                # Obergrenze fuer UTF-8 und verhindern ein Auftrennen der Bytes.
                $retainedCharacters = [int][Math]::Floor(($MaximumBytes - $markerBytes) / 4)
                $headCharacters = [int][Math]::Floor($retainedCharacters / 2)
                $tailCharacters = $retainedCharacters - $headCharacters
                $entry = $entry.Substring(0, $headCharacters) + $truncationMarker +
                    $entry.Substring($entry.Length - $tailCharacters, $tailCharacters)
            }
            $entryBytes = $encoding.GetByteCount($entry)
        }
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and
            ((Get-Item -LiteralPath $path).Length + $entryBytes) -gt $MaximumBytes) {
            for ($index = $ArchiveCount; $index -ge 1; $index--) {
                $archivePath = "$path.$index"
                if ($index -eq $ArchiveCount) {
                    if (Test-Path -LiteralPath $archivePath) {
                        Remove-Item -LiteralPath $archivePath -Force -ErrorAction Stop
                    }
                    continue
                }
                $nextArchivePath = "$path.$($index + 1)"
                if (Test-Path -LiteralPath $archivePath) {
                    Move-Item -LiteralPath $archivePath -Destination $nextArchivePath -Force -ErrorAction Stop
                }
            }
            Move-Item -LiteralPath $path -Destination "$path.1" -Force -ErrorAction Stop
        }
        [IO.File]::AppendAllText($path, $entry, $encoding)
        return $path
    }
    catch {
        # Ein nicht schreibbares Diagnoselog darf keinen Providerlauf abbrechen.
        $script:LabProviderLogDisabled = $true
        return $null
    }
}

function Invoke-LabProviderOperation {
    <#
    .SYNOPSIS Fuehrt eine Provider-Operation aus und persistiert ihre Ausgabe.
    .DESCRIPTION Der Wrapper bewahrt die originale Ausgabe fuer den Aufrufer,
    protokolliert Erfolg und Fehler secretbereinigt und veraendert die fachliche
    Fehlerbehandlung des Providers nicht.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][scriptblock]$Action,
        [AllowEmptyString()][string]$Command = '',
        [AllowEmptyString()][string]$RunId = '',
        [AllowEmptyString()][string]$StateRoot = '',
        [switch]$Native
    )

    $output = @()
    $exitCode = 0
    try {
        $output = @(& $Action)
        if ($Native) { $exitCode = $LASTEXITCODE }
    }
    catch {
        $exitCode = 1
        $output = @($_.Exception.Message)
        $null = Write-LabProviderLog -Provider $Provider -Phase $Phase -Command $Command `
            -Output $output -ExitCode $exitCode -RunId $RunId -StateRoot $StateRoot
        throw
    }

    $logPath = Write-LabProviderLog -Provider $Provider -Phase $Phase -Command $Command `
        -Output $output -ExitCode $exitCode -RunId $RunId -StateRoot $StateRoot
    return [PSCustomObject]@{
        Output = @($output)
        ExitCode = $exitCode
        LogPath = $logPath
        Succeeded = $exitCode -eq 0
    }
}

function Format-LabMessageReport {    <#
    .SYNOPSIS Erzeugt einen kopierbaren Klartextbericht zu Meldungen.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Message)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Message) {
        $severityLabel = ([string]$item.severity).ToUpperInvariant()
        $lines.Add('--- {0}  {1}  {2}' -f @($item.messageId, $severityLabel, $item.timestamp))
        if ($item.code) { $lines.Add('Code        {0}' -f $item.code) }
        $lines.Add('Meldung     {0}' -f $item.message)
        if ($item.detail) { $lines.Add('Detail      {0}' -f $item.detail) }
        if ($item.screenId) { $lines.Add('Bildschirm  {0}' -f $item.screenId) }
        if ($item.operationId) { $lines.Add('Operation   {0}' -f $item.operationId) }
        if ($item.runId) { $lines.Add('Run         {0}' -f $item.runId) }
    }
    $lines.Add('Modul       {0}' -f (Get-LabBuildInfo).Display)
    $journalPath = Get-LabMessageJournalPath
    if ($journalPath) { $lines.Add('Journal     {0}' -f $journalPath) }
    return ($lines -join [Environment]::NewLine)
}

# =============================================================================
# Logging
# =============================================================================

function Write-LabInfo {
    <#
    .SYNOPSIS Informationsmeldung (cyan).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    $record = Add-LabMessage -Severity Info -Message $Message
    if ($global:SqlServerLabUiCaptureOutput) {
        # Information-Records bleiben auch dann sofort sichtbar, wenn der
        # aufrufende Fachbefehl sein Erfolgsobjekt intern zwischenspeichert.
        # Das ist fuer die UI wichtig: Write-Output wuerde erst am Ende eines
        # langen Aufrufs im Live-Log ankommen.
        Write-Information "[INFO]    $($record.message)" -Tags 'SqlServerLabUi' -InformationAction Continue
        return
    }
    Write-Host "[INFO]    $($record.message)" -ForegroundColor $script:Colors.Info
}

function Write-LabSuccess {
    <#
    .SYNOPSIS Erfolgsmeldung (gruen).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    $record = Add-LabMessage -Severity Success -Message $Message
    if ($global:SqlServerLabUiCaptureOutput) {
        Write-Information "[OK]      $($record.message)" -Tags 'SqlServerLabUi' -InformationAction Continue
        return
    }
    Write-Host "[OK]      $($record.message)" -ForegroundColor $script:Colors.Success
}

function Write-LabWarning {
    <#
    .SYNOPSIS Warnmeldung (gelb).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    if (Test-LabConsoleInputCancellation -InputObject $Message) { throw (New-LabConsoleInputCancellationException) }
    $record = Add-LabMessage -Severity Warning -Message $Message
    if ($global:SqlServerLabUiCaptureOutput) {
        Write-Information "[WARNUNG] $($record.messageId)  $($record.message)" -Tags 'SqlServerLabUi' -InformationAction Continue
        return
    }
    Write-Host "[WARNUNG] $($record.messageId)  $($record.message)" -ForegroundColor $script:Colors.Warning
}

function Write-LabError {
    <#
    .SYNOPSIS Fehlermeldung (rot).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    if (Test-LabConsoleInputCancellation -InputObject $Message) { throw (New-LabConsoleInputCancellationException) }
    $record = Add-LabMessage -Severity Error -Message $Message
    if ($global:SqlServerLabUiCaptureOutput) {
        Write-Information "[FEHLER]  $($record.messageId)  $($record.message)" -Tags 'SqlServerLabUi' -InformationAction Continue
        return
    }
    Write-Host "[FEHLER]  $($record.messageId)  $($record.message)" -ForegroundColor $script:Colors.Error
}

function Write-LabHeader {
    <#
    .SYNOPSIS Abschnitts-Header mit Trennlinie.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Title)
    if ($global:SqlServerLabUiCaptureOutput) {
        Write-Information "[AKTION] $Title" -Tags 'SqlServerLabUi' -InformationAction Continue
        return
    }
    $line = '=' * 60
    Write-Host ""
    Write-Host $line -ForegroundColor $script:Colors.Header
    Write-Host "  $Title" -ForegroundColor $script:Colors.Header
    Write-Host $line -ForegroundColor $script:Colors.Header
    Write-Host ""
}

function Write-LabStatus {
    <#
    .SYNOPSIS Status-Tabelle mit Label und Wert.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Value,
        [string]$Color = 'White'
    )
    if ($global:SqlServerLabUiCaptureOutput) {
        Write-Information "[STATUS] ${Label}: $Value" -Tags 'SqlServerLabUi' -InformationAction Continue
        return
    }
    Write-Host "  $($Label.PadRight(24)) " -NoNewline -ForegroundColor $script:Colors.Muted
    Write-Host $Value -ForegroundColor $Color
}

# =============================================================================
# Eingabe-Prompts
# =============================================================================

function Read-LabChoice {
    <#
    .SYNOPSIS Zeigt nummerierte Optionen und liest die Auswahl.
    .PARAMETER Options Array von Strings (Optionen).
    .PARAMETER Prompt Frage-Text.
    .PARAMETER Default 1-basierter Default-Index.
    .OUTPUTS 0-basierter Index der Auswahl.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Options,
        [Parameter(Mandatory)][string]$Prompt,
        [int]$Default = 1
    )

    Write-Host ""
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $marker = if ($i + 1 -eq $Default) { '*' } else { ' ' }
        Write-Host "  [$($i + 1)]$marker $($Options[$i])" -ForegroundColor $script:Colors.Prompt
    }
    Write-Host ""

    do {
        $input = Read-Host "$Prompt [Standard: $Default]"
        if ([string]::IsNullOrWhiteSpace($input)) { $input = $Default.ToString() }
        $parsed = 0
        $valid = [int]::TryParse($input, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $Options.Count
        if (-not $valid) {
            Write-LabWarning "Bitte eine Zahl zwischen 1 und $($Options.Count) eingeben."
        }
    } while (-not $valid)

    return $parsed - 1
}

function Read-LabConfirm {
    <#
    .SYNOPSIS Ja/Nein-Bestaetigung.
    .OUTPUTS $true bei Ja, $false bei Nein.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$Default = $true
    )

    $hint = if ($Default) { '[J/n]' } else { '[j/N]' }
    $answer = Read-Host "$Prompt $hint"

    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim().ToLower() -in @('j', 'ja', 'y', 'yes')
}

function Read-LabString {
    <#
    .SYNOPSIS Texteingabe mit optionalem Default.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default = '',
        [switch]$AsSecureString
    )

    $hint = if ($Default) { " [Standard: $Default]" } else { '' }

    if ($AsSecureString) {
        $secure = Read-Host "$Prompt$hint" -AsSecureString
        if ($secure.Length -eq 0 -and $Default) {
            return (ConvertTo-SecureString $Default -AsPlainText -Force)
        }
        return $secure
    }
    else {
        $value = Read-Host "$Prompt$hint"
        if ([string]::IsNullOrWhiteSpace($value) -and $Default) { return $Default }
        return $value
    }
}

# =============================================================================
# Hilfsfunktionen
# =============================================================================

function New-LabGuid {
    <#
    .SYNOPSIS Erzeugt eine neue GUID als String (ohne Klammern).
    #>
    [System.Guid]::NewGuid().ToString('D')
}

function Get-LabTimestamp {
    <#
    .SYNOPSIS UTC-Zeitstempel im ISO-8601-Format.
    #>
    [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Test-CommandExists {
    <#
    .SYNOPSIS Prueft ob ein Befehl verfuegbar ist (ohne Ausfuehrung).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Command)
    if ($Command -in @('docker','podman','python')) {
        return [bool](Resolve-LabHostTool -Name $Command).Available
    }
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}


# =============================================================================
# Container-Runtime-Erkennung
# =============================================================================

function Get-ContainerRuntime {
    <#
    .SYNOPSIS Erkennt welche Container-Runtime verfuegbar ist.
    .DESCRIPTION Prueft docker und podman, gibt den Befehlsnamen zurueck.
                 Lifecycle-Cmdlets nutzen dies fuer provider-agnostische Aufrufe.
    .OUTPUTS String: 'docker', 'podman', oder $null.
    #>
    [CmdletBinding()]
    param(
        [string]$PreferredRuntime
    )

    # Wenn explizit gewuenscht, pruefen ob verfuegbar
    if ($PreferredRuntime -eq 'podman') {
        if (Test-CommandExists 'podman') { return 'podman' }
    }
    if ($PreferredRuntime -eq 'docker') {
        if (Test-CommandExists 'docker') { return 'docker' }
    }

    # Auto-Detect: docker bevorzugt (verbreiteter)
    if (Test-CommandExists 'docker') { return 'docker' }
    if (Test-CommandExists 'podman') { return 'podman' }

    return $null
}
