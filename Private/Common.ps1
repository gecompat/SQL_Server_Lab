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
# Logging
# =============================================================================

function Write-LabInfo {
    <#
    .SYNOPSIS Informationsmeldung (cyan).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    if ($global:SqlServerLabUiCaptureOutput) {
        # Information-Records bleiben auch dann sofort sichtbar, wenn der
        # aufrufende Fachbefehl sein Erfolgsobjekt intern zwischenspeichert.
        # Das ist fuer die UI wichtig: Write-Output wuerde erst am Ende eines
        # langen Aufrufs im Live-Log ankommen.
        Write-Information "[INFO]    $Message" -Tags 'SqlServerLabUi' -InformationAction Continue
        return
    }
    Write-Host "[INFO]    $Message" -ForegroundColor $script:Colors.Info
}

function Write-LabSuccess {
    <#
    .SYNOPSIS Erfolgsmeldung (gruen).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    if ($global:SqlServerLabUiCaptureOutput) {
        Write-Information "[OK]      $Message" -Tags 'SqlServerLabUi' -InformationAction Continue
        return
    }
    Write-Host "[OK]      $Message" -ForegroundColor $script:Colors.Success
}

function Write-LabWarning {
    <#
    .SYNOPSIS Warnmeldung (gelb).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    if ($global:SqlServerLabUiCaptureOutput) {
        Write-Information "[WARNUNG] $Message" -Tags 'SqlServerLabUi' -InformationAction Continue
        return
    }
    Write-Host "[WARNUNG] $Message" -ForegroundColor $script:Colors.Warning
}

function Write-LabError {
    <#
    .SYNOPSIS Fehlermeldung (rot).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    if ($global:SqlServerLabUiCaptureOutput) {
        Write-Information "[FEHLER]  $Message" -Tags 'SqlServerLabUi' -InformationAction Continue
        return
    }
    Write-Host "[FEHLER]  $Message" -ForegroundColor $script:Colors.Error
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
    Write-Host "  $($Label.PadRight(24))" -NoNewline -ForegroundColor $script:Colors.Muted
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
