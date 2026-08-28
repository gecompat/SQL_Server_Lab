<#
.SYNOPSIS
    Interaktives Menue fuer SQL_Server_Lab.
.DESCRIPTION
    Single-Entry-Point mit Menue-Loop. Zeigt aktive Labs und bietet
    alle Operationen ueber nummerierte Auswahl an.
.PARAMETER Action
    Optionale Direkt-Aktion (ueberspringt das Menue).
.PARAMETER ConsoleMode
    Waehlt die Cursoransicht automatisch oder erzwingt den diagnostischen
    nummerierten Fallback im selben PowerShell-7-Terminal.
.OUTPUTS
    Keine. Die Funktion ist eine interaktive Benutzeroberflaeche und delegiert
    die gewaehlte Aktion an die entsprechenden SqlServerLab-Commands.
.EXAMPLE
    Invoke-SqlServerLab
.EXAMPLE
    Invoke-SqlServerLab -Action Status
#>
function Invoke-SqlServerLab {
    [CmdletBinding()]
    param(
        [ValidateSet('New', 'BatchPlan', 'Queue', 'AutomatedTestEnvironment', 'ClearAutomatedTestEnvironment', 'Manifest', 'Status', 'Stop', 'Start', 'Restart', 'Remove', 'Clear', 'CleanupAudit', 'Script', 'Database', 'Image', 'MediaRoot', 'DataRoot', 'TestDataRoot', 'Rename', 'UpdateContainer', 'Resources', 'Manage', 'Install7Zip', 'Catalog', 'ConnectionCenter')]
        [string]$Action,

        [ValidateSet('Auto', 'Fallback')]
        [string]$ConsoleMode = 'Auto'
    )

    $previousConsoleMode = $script:LabConsoleMode
    $script:LabConsoleMode = $ConsoleMode
    try {
    # Das Modul darf sich waehrend einer laufenden Modul-Funktion nicht selbst
    # mit -Force neu laden. Dabei werden die aktuelle Funktion und ihre
    # Hilfsfunktionen aus dem Session-State entfernt.

    # Direkt-Aktion ohne Menue
    if ($Action) {
        try {
            if ($Action -eq 'BatchPlan') { Invoke-LabBatchComposerInteractive; return }
            if ($Action -eq 'Queue') { Invoke-LabQueueInteractive; return }
            $null = Invoke-LabActionWithResult -ActionName $Action
        }
        catch { if (-not (Test-LabConsoleInputCancellation -InputObject $_)) { throw } }
        return
    }

    # Interaktiver Menue-Loop
    $exit = $false
    while (-not $exit) {
        $choice = Show-LabMenu

        try {
            switch ($choice) {
                'plan' { Invoke-LabBatchComposerInteractive }
                'queue' { Invoke-LabQueueInteractive }
                'environment' { Invoke-LabAreaMenuInteractive -Area Environment }
                'hyperv' { Invoke-LabAreaMenuInteractive -Area HyperV }
                'storage' { Invoke-LabAreaMenuInteractive -Area Storage }
                'database' { Invoke-LabAreaMenuInteractive -Area Database }
                'system' { Invoke-LabAreaMenuInteractive -Area System }
                '0' { $exit = $true }
                'q' { $exit = $true }
                default { Write-Host "  Ungueltige Auswahl: $choice" -ForegroundColor Red }
            }
        }
        catch { if (-not (Test-LabConsoleInputCancellation -InputObject $_)) { throw } }

    }

    Write-Host ""
    Write-LabInfo "Auf Wiedersehen."
    }
    finally {
        $script:LabConsoleMode = $previousConsoleMode
    }
}

# =============================================================================
# Interne Hilfsfunktionen
# =============================================================================

function Sync-LabConnectionCenterAfterLifecycle {
    <# .SYNOPSIS Synchronisiert Verbindungszentrale und einen eingerichteten CMS nach einer Lifecycle-Aktion. #>
    [CmdletBinding()]
    param()

    try { $null = Sync-SqlServerLabConnectionCenter -Quiet }
    catch { Write-LabWarning "Verbindungszentrale konnte nicht synchronisiert werden: $($_.Exception.Message)"; return }

    try {
        $cms = Get-LabConnectionCenterCmsConfiguration
        if ($cms) {
            $result = Sync-SqlServerLabCms -Quiet
            Write-LabInfo "CMS automatisch synchronisiert: $($result.Entries) Endpunkt(e)."
        }
    }
    catch {
        Write-LabWarning "CMS-Synchronisation fehlgeschlagen: $($_.Exception.Message). Unter [k] -> [4] erneut ausführen."
    }
}

function Invoke-LabActionWithResult {
    <# .SYNOPSIS Fuehrt eine UI-Aktion aus und synchronisiert nur nach dem ActionResult-Vertrag. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ActionName)

    $privilegeClass = Get-LabActionPrivilegeClass -Action $ActionName
    Write-Verbose "UI-Aktion '$ActionName' verwendet Privilegklasse '$privilegeClass'."
    $before = Get-LabWorkflowLifecycleFingerprint
    $rawResult = @(Invoke-LabAction -ActionName $ActionName)
    $after = Get-LabWorkflowLifecycleFingerprint
    $actionResult = ConvertTo-LabActionResult -Action $ActionName -InputObject $rawResult `
        -BeforeFingerprint $before -AfterFingerprint $after
    $actionResult | Add-Member -NotePropertyName PrivilegeClass -NotePropertyValue $privilegeClass -Force
    $null = Invoke-LabActionResultSynchronization -ActionResult $actionResult `
        -SynchronizationAction { Sync-LabConnectionCenterAfterLifecycle }
    return $actionResult
}

function Invoke-LabMenuAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ActionName)

    if ([string]::IsNullOrWhiteSpace($ActionName) -or $ActionName -eq 'back') {
        return
    }

    if ($ActionName -eq 'BatchPlan') { Invoke-LabBatchComposerInteractive; return }
    if ($ActionName -eq 'BulkSlots') { Invoke-LabBatchComposerInteractive -SlotMode; return }
    if ($ActionName -eq 'queue') { Invoke-LabQueueInteractive; return }

    if ($ActionName -eq 'HyperVManage') {
        Manage-LabHyperVEnvironmentInteractive
    }
    else {
        $null = Invoke-LabActionWithResult -ActionName $ActionName
    }

    if ($ActionName -in @('Status', 'CleanupAudit', 'Catalog')) {
        Wait-LabConsoleAcknowledgement
    }

}

function Show-LabSubMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScreenId,
        [Parameter(Mandatory)][string]$Title,
        [string]$Subtitle = '',
        [Parameter(Mandatory)][object[]]$Items
    )

    $result = Invoke-LabConsoleMenu -ScreenId $ScreenId -Title $Title -Subtitle $Subtitle -Items $Items -Footer 'Pfeile: Navigation  Enter/Shortcut: Auswahl  Esc: Zurueck'

    if ($result.Status -eq 'Cancelled') { return $null }
    if ($result.Status -ne 'Selected') { return $null }
    return [string]$result.SelectedItem.Id
}

function Show-LabEnvironmentMenu {
    $runs = try { @(Get-LabActiveRuns) } catch { @() }
    $states = @($runs | ForEach-Object { [string](Get-LabWorkflowValue -InputObject $_.runtime -Name 'state' -Default (Get-LabWorkflowValue -InputObject $_ -Name 'state' -Default '')) })
    $hasRuns = $runs.Count -gt 0
    $hasRunning = @($states | Where-Object { $_ -eq 'RUNNING' }).Count -gt 0
    $hasStopped = @($states | Where-Object { $_ -eq 'STOPPED' }).Count -gt 0
    $hasAutomatedTestEnvironments = try { [int](Get-LabAutomatedTestEnvironmentStatus).Total -gt 0 } catch { $false }
    $items = @(
        New-LabConsoleItem -Id 'Manage' -Label 'Umgebung auswaehlen und verwalten' -Value 'Start, Stopp, Name, CPU, Speicher, Entfernen' -Shortcut '1' -Disabled:(-not $hasRuns)
        New-LabConsoleItem -Id 'Status' -Label 'Status aller Umgebungen anzeigen' -Shortcut '2' -Disabled:(-not $hasRuns)
        New-LabConsoleItem -Id 'Stop' -Label 'Umgebung stoppen' -Shortcut '3' -Disabled:(-not $hasRunning)
        New-LabConsoleItem -Id 'Start' -Label 'Umgebung starten' -Shortcut '4' -Disabled:(-not $hasStopped)
        New-LabConsoleItem -Id 'Restart' -Label 'Umgebung neustarten' -Shortcut '5' -Disabled:(-not ($hasRunning -or $hasStopped))
        New-LabConsoleItem -Id 'Rename' -Label 'Umgebung umbenennen' -Shortcut 'n' -Disabled:(-not $hasRuns)
        New-LabConsoleItem -Id 'Resources' -Label 'CPU und Speicher aendern' -Shortcut 'r' -Disabled:(-not $hasRuns)
        New-LabConsoleItem -Id 'CleanupAudit' -Label 'Cleanup-Audit anzeigen (read-only)' -Shortcut 'a'
        New-LabConsoleItem -Id 'Remove' -Label 'Umgebung entfernen' -Shortcut '6' -Disabled:(-not $hasRuns)
        New-LabConsoleItem -Id 'ClearAutomatedTestEnvironment' -Label 'Alle automatisierten Testumgebungen loeschen' -Value 'geschuetzte Gruppe' -Shortcut 'x' -Disabled:(-not $hasAutomatedTestEnvironments)
        New-LabConsoleItem -Id 'Clear' -Label 'Alle Lab-Ressourcen aufraeumen' -Value 'Recovery und verwaiste Ressourcen' -Shortcut '7'
        New-LabConsoleItem -Id 'back' -Label 'Zurueck' -Shortcut '0'
    )

    return Show-LabSubMenu -ScreenId 'environment-menu' -Title 'Umgebungen' -Subtitle 'Provisionierung, Lifecycle und Wartung' -Items $items
}

function Show-LabHyperVMenu {
    $items = @(
        New-LabConsoleItem -Id 'Image' -Label 'Hyper-V Infrastruktur: OS-Images und ISOs verwalten' -Value 'Windows-/SQL-Basen, ISO-Download und Baseline-Builds' -Shortcut '1'
        New-LabConsoleItem -Id 'HyperVManage' -Label 'Hyper-V Slots und Infrastrukturverwaltung' -Value 'OS-/SQL-Slots übernehmen, freigeben, fortsetzen' -Shortcut '2'
        New-LabConsoleItem -Id 'BulkSlots' -Label 'Mehrere Slots gemeinsam bereitstellen' -Value 'Mengenfaehiger Composer · gemeinsame Vorlagenabhaengigkeiten' -Shortcut '3'
        New-LabConsoleItem -Id 'back' -Label 'Zurueck' -Shortcut '0'
    )

    return Show-LabSubMenu -ScreenId 'hyperv-menu' -Title 'Hyper-V' -Subtitle 'Infrastruktur: OS-Vorlage, Slots, Builds und ISO-Quellen' -Items $items
}

function Show-LabStorageMenu {
    $items = @(
        New-LabConsoleItem -Id 'MediaRoot' -Label 'Lab_Base / Media-Root konfigurieren' -Value 'ISO-, Win-/SQL-Medien, Sidecar-Hashes' -Shortcut 'p'
        New-LabConsoleItem -Id 'DataRoot' -Label 'Lab_Data verwalten' -Value 'Lab_Data je Volume' -Shortcut 'd'
        New-LabConsoleItem -Id 'TestDataRoot' -Label 'Testdaten-Bibliothek konfigurieren' -Shortcut 't'
        New-LabConsoleItem -Id 'back' -Label 'Zurueck' -Shortcut '0'
    )

    return Show-LabSubMenu -ScreenId 'storage-menu' -Title 'Storage & Medien' -Subtitle 'Lab_Base, Lab_Data und Testdaten' -Items $items
}

function Show-LabDatabaseMenu {
    $items = @(
        New-LabConsoleItem -Id 'Manifest' -Label 'Container-Manifest erstellen und pruefen' -Shortcut 'm'
        New-LabConsoleItem -Id 'Database' -Label 'Datenbank anlegen' -Shortcut '8'
        New-LabConsoleItem -Id 'Script' -Label 'SQL-Skript ausfuehren' -Shortcut '9'
        New-LabConsoleItem -Id 'ConnectionCenter' -Label 'Verbindungszentrale und SSMS-Endpunkte' -Shortcut 'c'
        New-LabConsoleItem -Id 'Catalog' -Label 'CMS- und Katalogstatus' -Shortcut 'k'
        New-LabConsoleItem -Id 'back' -Label 'Zurueck' -Shortcut '0'
    )

    return Show-LabSubMenu -ScreenId 'database-menu' -Title 'Datenbank & Skripte' -Subtitle 'Artefakte, Datenbanken und SQL-Ausfuehrung' -Items $items
}

function Show-LabToolsMenu {
    $sevenZip = Get-Lab7ZipExecutable
    $sevenZipLabel = if ($sevenZip) { '7-Zip fuer .7z-Backups verfügbar' } else { '7-Zip fuer .7z-Backups optional installieren' }

    $items = @(
        New-LabConsoleItem -Id 'ConnectionCenter' -Label 'SQL-Verbindungszentrale' -Value 'SSMS, CMS, Export' -Shortcut 'k'
        New-LabConsoleItem -Id 'Install7Zip' -Label $sevenZipLabel -Shortcut 'z'
        New-LabConsoleItem -Id 'back' -Label 'Zurueck' -Shortcut '0'
    )

    return Show-LabSubMenu -ScreenId 'tools-menu' -Title 'Werkzeuge & Verbindungen' -Subtitle 'Utilities und Verbindungs-Workflow' -Items $items
}

function Write-LabProviderList {
    [CmdletBinding()]
    param(
        [string[]]$Providers,
        [switch]$AsBanner,
        [string]$HeaderLabel = '  Provider:'
    )

    $providerColorMap = @{
        docker = 'DarkCyan'
        podman = 'DarkGreen'
        hyperv = 'DarkYellow'
    }
    $entries = @(
        foreach ($provider in @($Providers | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            [PSCustomObject]@{
                Display = [string]$provider
                SortKey = [string]$provider.ToLowerInvariant().Trim()
            }
        }
    )
    $entries = @(
        $entries |
            Sort-Object SortKey |
            Group-Object SortKey |
            ForEach-Object { $_.Group | Select-Object -First 1 }
    )

    if ($entries.Count -eq 0) {
        if ($AsBanner) {
            Write-Host '  Provider: KEINER VERFUEGBAR' -ForegroundColor Red
        }
        else {
            Write-Host '  Provider: n/a' -ForegroundColor Gray
        }
        return
    }

    $headerColor = if ($AsBanner) { 'DarkGray' } else { 'White' }
    Write-Host $HeaderLabel -ForegroundColor $headerColor
    foreach ($entry in $entries) {
        $provider = $entry.Display
        $providerToken = ($provider -split '\s+')[0].ToLowerInvariant()
        $providerColor = if ($providerColorMap.ContainsKey($providerToken)) { $providerColorMap[$providerToken] } else { 'Gray' }
        Write-Host ('    - {0}' -f $provider) -ForegroundColor $providerColor
    }
}

function Show-LabBanner {
    Clear-Host
    Write-Host ""
    Write-Host "  =====================================================================" -ForegroundColor Cyan
    Write-Host "   SQL Server Lab" -ForegroundColor White
    Write-Host "   Isolierte, reproduzierbare SQL-Server-Testumgebungen" -ForegroundColor DarkGray
    $build = Get-LabBuildInfo
    Write-Host "   Build: $($build.Display) | Quelle: $($build.Source)" -ForegroundColor DarkGray
    try {
        $module = Get-Module SqlServerLab
        $queue = Get-SqlServerLabQueue
        $consoleMode = if ((Test-LabConsoleCapability).Supported) { 'Cursor' } else { 'Fallback' }
        Write-Host "   Modul: $($module.Version) | Pfad: $($module.Path) | Konsole: $consoleMode" -ForegroundColor DarkGray
        Write-Host "   Worker: $($queue.runningWorkers)/$($queue.maxWorkers) | User-Gates: $($queue.waitingUserGates) | Queue: $($queue.length)" -ForegroundColor $(if ($queue.waitingUserGates -gt 0) { 'Yellow' } else { 'DarkGray' })
    }
    catch { }
    Write-Host "  =====================================================================" -ForegroundColor Cyan

    # Verfuegbare Provider anzeigen
    $providers = @(Get-AvailableLabProviders)
    $hyperVCheck = if ($IsWindows) { Test-HyperVAvailable } else { $null }
    $hyperVInstalled = $null -ne (Get-Command Get-VM -ErrorAction SilentlyContinue)

    $providerEntries = @(
        foreach ($provider in @($providers | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            [PSCustomObject]@{ Display = $provider; SortKey = [string]$provider.ToLowerInvariant().Trim() }
        }
    )
    if ($hyperVInstalled -and $hyperVCheck -and $hyperVCheck.Available -and -not ($providerEntries.SortKey -contains 'hyperv')) {
        $providerEntries = @($providerEntries + @(@{ Display = 'hyperv'; SortKey = 'hyperv' }))
    }
    if ($hyperVInstalled -and $null -ne $hyperVCheck -and -not $hyperVCheck.Available) {
        $providerEntries = @($providerEntries + @(@{ Display = 'hyperv (UAC erforderlich)'; SortKey = 'hyperv' }))
    }

    $providerEntries = @(
        $providerEntries |
            Sort-Object SortKey |
            Group-Object SortKey |
            ForEach-Object { $_.Group | Select-Object -First 1 }
            | Select-Object -ExpandProperty Display
    )
    Write-LabProviderList -Providers $providerEntries -AsBanner

    # Aktive Labs kurz anzeigen
    $stateRoot = Get-LabStateRoot
    $runs = @(Get-LabActiveRuns -StateRoot $stateRoot)

    if ($runs.Count -gt 0) {
        Write-Host ""
        Write-Host "  Aktive Umgebungen: $($runs.Count)" -ForegroundColor Green
        foreach ($run in $runs) {
            $prefix = $run.runId.Substring(0, 8)
            $name = $run.metadata.name
            $synced = Sync-LabRunRuntimeState -Run $run -StateRoot $stateRoot
            $runtime = $synced.Runtime
            Write-Host "    [$(($runtime.State).PadRight(11))] ${prefix}... - $name" -ForegroundColor Gray
            $connections = @(Get-LabRunConnectionStrings -RunId $run.runId -StateRoot $stateRoot)
            if ($connections.Count -eq 0) {
                Write-Host '        SQL: Connection String noch nicht ermittelt.' -ForegroundColor DarkGray
            }
            foreach ($connection in $connections) {
                Write-Host "        SQL ($($connection.Provider)/$($connection.InstanceId)): $($connection.Value)" -ForegroundColor DarkGray
            }
        }
    }
    else {
        Write-Host ""
        Write-Host "  Keine aktiven Umgebungen." -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Get-LabRunConnectionStrings {
    <# .SYNOPSIS Liefert SQL-Connection-Strings; automatisch erzeugte Kennwörter dürfen sichtbar sein. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $connectionInfoPath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') $RunId) 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionInfoPath -PathType Leaf)) { return @() }
    try { $connectionInfo = Get-Content -LiteralPath $connectionInfoPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 }
    catch { return @() }

    $generatedPassword = Get-LabAutomaticallyGeneratedRunSaPassword -RunId $RunId -StateRoot $StateRoot
    $result = @()
    foreach ($instance in @($connectionInfo.instances)) {
        $value = [string]$instance.connectionString
        if (-not $value -and [string]$instance.provider -in @('docker', 'podman') -and $instance.port) {
            $value = New-SqlConnectionString -HostName $(if ($instance.host) { [string]$instance.host } else { '127.0.0.1' }) -Port ([int]$instance.port)
        }
        if ($value) {
            if ($generatedPassword) {
                $value = [regex]::Replace($value, '(?i)(Password|Pwd)\s*=\s*[^;]*', ('Password={0}' -f $generatedPassword))
            }
            $result += [PSCustomObject]@{ Provider = [string]$instance.provider; InstanceId = [string]$instance.id; Value = $value }
        }
    }
    return @($result)
}

function Show-LabEnvironmentStatusInteractive {
    <# .SYNOPSIS Zeigt den dauerhaften Status samt bewusst eingeblendeten generierten SQL-Zugangsdaten. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $null = Get-SqlServerLab -RunId $RunId -Detailed
    $connections = @(Get-LabRunConnectionStrings -RunId $RunId -StateRoot $StateRoot)
    $generatedAccess = try { Get-SqlServerLabGeneratedSqlAccess -RunId $RunId -StateRoot $StateRoot } catch { $null }
    $generatedPassword = if ($generatedAccess -and $generatedAccess.Generated -and $generatedAccess.Persisted) {
        [string]$generatedAccess.Password
    }
    else {
        Get-LabAutomaticallyGeneratedRunSaPassword -RunId $RunId -StateRoot $StateRoot
    }

    if ($generatedAccess -and $generatedAccess.ConnectionString) {
        $hyperVConnection = @($connections | Where-Object { [string]$_.Provider -eq 'hyperv' } | Select-Object -First 1)
        if ($hyperVConnection.Count -eq 1) {
            $hyperVConnection[0].Value = [string]$generatedAccess.ConnectionString
        }
        else {
            $connections += [pscustomobject]@{ Provider='hyperv'; InstanceId='sql'; Value=[string]$generatedAccess.ConnectionString }
        }
    }

    Write-Host ''
    Write-Host '  SQL-Zugang' -ForegroundColor Cyan
    if ($connections.Count -eq 0) {
        Write-LabStatus -Label 'Connection String' -Value 'noch nicht ermittelt' -Color DarkGray
    }
    else {
        foreach ($connection in $connections) {
            Write-LabStatus -Label ("Connection String ({0}/{1})" -f $connection.Provider, $connection.InstanceId) -Value ([string]$connection.Value)
        }
    }
    if ($generatedPassword) {
        Write-LabStatus -Label 'SA-Passwort (automatisch erzeugt)' -Value $generatedPassword -Color Yellow
        Write-Host '  Das Passwort wird nur in dieser ausdrücklich geöffneten Statusansicht entschlüsselt angezeigt.' -ForegroundColor DarkGray
    }
    else {
        Write-LabStatus -Label 'SA-Passwort' -Value 'nicht automatisch gespeichert oder für diese Umgebung nicht abrufbar' -Color DarkGray
    }
}

function Get-LabWindowsMediaOperatingSystemLabel {
    <# .SYNOPSIS Erzeugt eine lesbare, versionsdynamische Windows-Gruppenüberschrift. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OperatingSystemId)

    if ($OperatingSystemId -match '^windows-server-(?<version>[0-9]+)$') {
        return "Windows Server $($Matches.version)"
    }
    if ($OperatingSystemId -match '^windows-(?<version>[0-9]+)$') {
        return "Windows $($Matches.version)"
    }
    return $OperatingSystemId
}

function Get-LabWindowsMediaOperatingSystemSortKey {
    <# .SYNOPSIS Sortiert Server vor Clients und jüngere Versionen vor älteren. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OperatingSystemId)

    if ($OperatingSystemId -match '^windows-server-(?<version>[0-9]+)$') {
        return ('0-{0:D4}' -f (9999 - [int]$Matches.version))
    }
    if ($OperatingSystemId -match '^windows-(?<version>[0-9]+)$') {
        return ('1-{0:D4}' -f (9999 - [int]$Matches.version))
    }
    return "9-$OperatingSystemId"
}

function ConvertTo-LabWindowsMediaDisplayText {
    <# .SYNOPSIS Formatiert dynamisch erkannte Editions- und Installationswerte lesbar. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)

    $normalized = (($Value -replace '-evaluation$', '') -replace '-', ' ')
    $words = $normalized.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries) |
        ForEach-Object {
            if ($_ -in @('ltsc', 'n')) { $_.ToUpperInvariant() }
            else { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1).ToLowerInvariant() }
        }
    return ($words -join ' ')
}

function Write-LabWindowsMediaSelectionGroups {
    <# .SYNOPSIS Gibt erkannte Windows-Medien automatisch nach OS und Lizenztyp gruppiert aus. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Candidates,
        [switch]$Numbered,
        [string]$ItemPrefix = '    ',
        [ConsoleColor]$Color = [ConsoleColor]::White
    )

    $numberByMedia = @{}
    for ($index = 0; $index -lt $Candidates.Count; $index++) {
        $numberByMedia[[string]$Candidates[$index].MediaId + '|' + [string]$Candidates[$index].ImageIndex] = $index + 1
    }
    foreach ($osGroup in @($Candidates | Group-Object OperatingSystemId | Sort-Object { Get-LabWindowsMediaOperatingSystemSortKey -OperatingSystemId ([string]$_.Name) })) {
        $osLabel = Get-LabWindowsMediaOperatingSystemLabel -OperatingSystemId ([string]$osGroup.Name)
        Write-Host ("{0}{1}" -f $ItemPrefix, $osLabel) -ForegroundColor Cyan
        foreach ($licenseGroup in @(
            [PSCustomObject]@{ Label = 'Reguläre Medien'; Items = @($osGroup.Group | Where-Object { [string]$_.WindowsEdition -notmatch '-evaluation$' }) },
            [PSCustomObject]@{ Label = 'Evaluation'; Items = @($osGroup.Group | Where-Object { [string]$_.WindowsEdition -match '-evaluation$' }) }
        )) {
            if ($licenseGroup.Items.Count -eq 0) { continue }
            Write-Host ("{0}  {1}" -f $ItemPrefix, $licenseGroup.Label) -ForegroundColor DarkGray
            foreach ($candidate in $licenseGroup.Items) {
                $edition = ConvertTo-LabWindowsMediaDisplayText -Value ([string]$candidate.WindowsEdition)
                $installation = ConvertTo-LabWindowsMediaDisplayText -Value ([string]$candidate.InstallationType)
                $number = $numberByMedia[[string]$candidate.MediaId + '|' + [string]$candidate.ImageIndex]
                $selectionPrefix = if ($Numbered) { ('[{0}] ' -f $number) } else { '- ' }
                Write-Host ("{0}    {1}{2} · {3} · {4}" -f $ItemPrefix, $selectionPrefix, $edition, $installation, $candidate.MediaId) -ForegroundColor $Color
            }
        }
    }
}

function Get-LabRunsByRuntimeState {
    <# .SYNOPSIS Wählt aktive Runs anhand des echten Runtime-Status aus. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$State, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $matches = @()
    foreach ($run in @(Get-LabActiveRuns -StateRoot $StateRoot)) {
        $synced = Sync-LabRunRuntimeState -Run $run -StateRoot $StateRoot
        if ([string]$synced.Runtime.State -in $State) { $matches += $synced.Run }
    }
    return @($matches)
}

function Show-LabMenu {
    try { $snapshot = Update-LabConsoleAttentionSnapshot } catch { $snapshot = $null }
    while ($true) {
        $hyperVAvailability = try {
            if ($IsWindows) { Test-HyperVAvailable }
            else { [pscustomobject]@{ Available = $false; Message = 'Hyper-V ist nur unter Windows verfuegbar.' } }
        }
        catch { [pscustomobject]@{ Available = $false; Message = $_.Exception.Message } }
        $hyperVAvailable = $null -ne $hyperVAvailability -and [bool]$hyperVAvailability.Available
        $hyperVMenuValue = if ($hyperVAvailable) {
            'Vorlagen · ISOs · Slots · Bulk-Bereitstellung · Recovery'
        }
        else {
            $reason = [string]$hyperVAvailability.Message
            if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'Hyper-V ist nicht installiert oder in dieser Sitzung nicht verwendbar.' }
            "Nicht verfuegbar: $reason"
        }
        $items = @(
            New-LabConsoleItem -Id 'plan' -Label 'Umgebungen planen und erstellen' -Value 'SQL/Windows · Einzelposition oder Batch · Provider Auto' -Shortcut '1'
            New-LabConsoleItem -Id 'queue' -Label 'Vorgaenge, Queue und Benutzeraktionen' -Value 'Fortschritt · Prioritaet · Resume · User-Gates' -Shortcut '2'
            New-LabConsoleItem -Id 'environment' -Label 'Umgebungen verwalten' -Value 'Status · Start · Stopp · Name · CPU/RAM · Entfernen' -Shortcut '3'
            New-LabConsoleItem -Id 'hyperv' -Label 'Hyper-V-Infrastruktur' -Value $hyperVMenuValue -Shortcut '4' -Disabled:(-not $hyperVAvailable)
            New-LabConsoleItem -Id 'storage' -Label 'Medien, Testdaten und Speicher' -Value 'Lab_Base · Lab_Data · Testdatenbibliothek · Storage' -Shortcut '5'
            New-LabConsoleItem -Id 'database' -Label 'Datenbanken und Verbindungen' -Value 'Samples · Restore · Skripte · Endpunkte · SSMS · CMS' -Shortcut '6'
            New-LabConsoleItem -Id 'system' -Label 'Systemstatus und Einstellungen' -Value 'Provider · Scheduler · Ton · Ruhemodus · Audit' -Shortcut '7'
            New-LabConsoleItem -Id 'exit' -Label 'Beenden' -Shortcut '0' -Aliases @('q')
        )
        $result = Invoke-LabConsoleMenu -ScreenId 'main-menu' -Title 'SQL Server Lab' -Subtitle 'Providerneutraler Batch-, Queue- und Resume-Workflow' -Items $items -Snapshot $snapshot -Footer 'Pfeile: Navigation  Enter/Shortcut: Auswahl  F5: Status aktualisieren  Esc: Beenden' -FallbackPrompt '  Auswahl'
        if ($result.Status -eq 'Refresh') { $snapshot = Get-LabConsoleAttentionSnapshot; continue }
        if ($result.Status -eq 'Cancelled') { return '0' }
        if ($result.Status -eq 'Selected') { return [string]$result.SelectedItem.Id }
        Write-LabWarning 'Ungueltige Auswahl.'
    }
}

function Invoke-LabAction {
    param([Parameter(Mandatory)][string]$ActionName)

    Write-Host ""

    switch ($ActionName) {
        'MediaRoot' {
            $currentMediaRoot = Get-LabMediaRootDefault
            $prompt = if ($currentMediaRoot) { "  Neuer Media Root [$currentMediaRoot]" } else { '  Neuer Media Root' }
            $candidate = Read-Host $prompt
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                Write-LabInfo 'Media Root unverändert.'
                return
            }
            try {
                $savedMediaRoot = Set-LabMediaRootDefault -MediaRoot $candidate
                Write-LabSuccess "Media Root gespeichert: $savedMediaRoot"
            }
            catch {
                Write-LabError "Media Root konnte nicht gespeichert werden: $($_.Exception.Message)"
            }
        }
        'DataRoot' {
            Invoke-LabStorageInteractive
        }
        'CleanupAudit' {
            $result = Get-SqlServerLabCleanupAudit
            Write-LabStatus -Label 'Audit-Status' -Value $result.Audit.Status -Color $(if ($result.Audit.Status -eq 'CLEAN') { 'Green' } else { 'Yellow' })
            Write-LabStatus -Label 'Verbleibende Ressourcen' -Value $result.Audit.Summary.ResidualCount
            Write-LabStatus -Label 'Nicht pruefbare Provider' -Value $result.Audit.Summary.UnverifiableProviders
            if ($result.Path) { Write-LabInfo "Audit gespeichert: $($result.Path)" }
        }
        'TestDataRoot' {
            $currentTestDataRoot = Get-LabTestDataRootDefault
            $prompt = if ($currentTestDataRoot) { "  Testdaten-Root [$currentTestDataRoot]" } else { '  Testdaten-Root' }
            $candidate = Read-Host $prompt
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                Write-LabInfo 'Testdaten-Root unverändert.'
                return
            }
            try {
                $savedTestDataRoot = Set-LabTestDataRootDefault -TestDataRoot $candidate
                Write-LabSuccess "Testdaten-Bibliothek gespeichert: $savedTestDataRoot"
            }
            catch { Write-LabError "Testdaten-Root konnte nicht gespeichert werden: $($_.Exception.Message)" }
        }
        'Install7Zip' {
            $existing = Get-Lab7ZipExecutable
            if ($existing) {
                Write-LabSuccess "7-Zip verfügbar: $($existing.Path)"
                return
            }
            Write-LabWarning '7-Zip wird ausschließlich für explizit katalogisierte .7z-Backups benötigt.'
            Write-Host '  Die Installation erfolgt nur nach dieser Bestätigung über winget (Paket 7zip.7zip).' -ForegroundColor DarkGray
            if (-not (Read-LabConfirm -Prompt '  7-Zip jetzt optional installieren?' -Default $false)) { return }
            try {
                $result = Install-SqlServerLab7Zip -Confirm:$false
                Write-LabSuccess $result.Message
            }
            catch { Write-LabError $_.Exception.Message }
        }
        'Manifest' {
            $manifestPath = Read-Host '  Manifest-Zielpfad [.\lab-manifest.json]'
            if (-not $manifestPath) {
                $manifestPath = '.\lab-manifest.json'
            }

            $null = New-SqlServerLabManifest -Path $manifestPath
            if ((Test-Path -LiteralPath $manifestPath -PathType Leaf) -and
                (Read-LabConfirm -Prompt 'Umgebung jetzt aus diesem Manifest erstellen?' -Default $false)) {
                $lab = New-SqlServerLab -Manifest $manifestPath
                Write-LabSuccess "Lab erstellt. RunId: $($lab.RunId)"
            }
        }
        'UpdateContainer' { Update-LabContainerEnvironmentInteractive }
        'Manage' { Manage-LabEnvironmentInteractive }
        'Resources' { Set-LabResourcesInteractive }
        'Rename' { Rename-LabEnvironmentInteractive }
        'New' { Invoke-LabNewEnvironmentInteractive }
        'AutomatedTestEnvironment' { Invoke-LabAutomatedTestEnvironmentInteractive }
        'ClearAutomatedTestEnvironment' { Invoke-LabClearAutomatedTestEnvironmentInteractive }

        'Status' {
            $runs = @(Get-LabActiveRuns)
            if ($runs.Count -eq 0) {
                Write-LabInfo "Keine aktiven Labs."
                return
            }
            $cmsRunId = try { [string](Get-LabConnectionCenterCmsConfiguration).RunId } catch { '' }
            $statusRuns = @($runs | Where-Object { [string]$_.runId -ne $cmsRunId })
            if ($statusRuns.Count -eq 0) {
                Write-LabInfo 'Keine normalen Lab-Umgebungen vorhanden. Der CMS-Systemdienst wird unter Datenbanken und Verbindungen verwaltet.'
                return
            }

            $statusItems = [System.Collections.Generic.List[object]]::new()
            $statusItems.Add((New-LabConsoleItem -Id '__all' -Label 'Alle Umgebungen' -Value "$($statusRuns.Count) Umgebung(en)" -Shortcut 'a'))
            for ($index = 0; $index -lt $statusRuns.Count; $index++) {
                $run = $statusRuns[$index]
                $presentation = Get-LabRunSelectorPresentation -Run $run -RuntimeState ([string]$run.runtime.state)
                $statusItems.Add((New-LabConsoleItem -Id ([string]$run.runId) -Label $presentation.Label -Value $presentation.Value -Shortcut ([string]($index + 1))))
            }
            $selection = Invoke-LabConsoleMenu -ScreenId 'environment-status-select' -Title 'Umgebungsstatus anzeigen' -Subtitle 'Eine Umgebung oder Alle auswaehlen' -Items $statusItems.ToArray() -Footer 'Pfeile: Navigation  Enter/Shortcut: Auswahl  Esc: Zurueck'
            if ($selection.Status -ne 'Selected') { return }

            $selectedRuns = if ([string]$selection.SelectedItem.Id -eq '__all') {
                @($statusRuns)
            }
            else {
                @($statusRuns | Where-Object { [string]$_.runId -eq [string]$selection.SelectedItem.Id })
            }
            foreach ($run in $selectedRuns) {
                Write-Host ''
                Write-Host ("  Umgebung: {0} ({1})" -f ([string]$run.metadata.name), ([string]$run.runId)) -ForegroundColor Cyan
                Write-Host '  ---------------------------------------------------------------------' -ForegroundColor DarkCyan
                Show-LabEnvironmentStatusInteractive -RunId ([string]$run.runId)
            }
        }

        'Stop' {
            $runs = @(Get-LabRunsByRuntimeState -State 'RUNNING')
            if ($runs.Count -eq 0) {
                Write-LabInfo "Keine laufenden Labs."
                return
            }
            $runId = Select-LabRun -Runs $runs -Prompt "Stoppen" -DisableAutomatedTestEnvironments -DisableSystemServices
            if ($runId) { Stop-SqlServerLab -RunId $runId }
        }

        'Start' {
            $runs = @(Get-LabRunsByRuntimeState -State 'STOPPED')
            if ($runs.Count -eq 0) {
                Write-LabInfo "Keine gestoppten Labs."
                return
            }
            $runId = Select-LabRun -Runs $runs -Prompt "Starten" -DisableAutomatedTestEnvironments -DisableSystemServices
            if ($runId) { Start-SqlServerLab -RunId $runId }
        }

        'Restart' {
            $runs = @(Get-LabRunsByRuntimeState -State @('RUNNING', 'STOPPED'))
            if ($runs.Count -eq 0) {
                Write-LabInfo "Keine Labs zum Neustarten."
                return
            }
            $runId = Select-LabRun -Runs $runs -Prompt "Neustarten" -DisableAutomatedTestEnvironments -DisableSystemServices
            if ($runId) { Restart-SqlServerLab -RunId $runId }
        }

        'Remove' {
            $runs = @(Get-LabActiveRuns)
            if ($runs.Count -eq 0) {
                Write-LabInfo "Keine aktiven Labs."
                return
            }
            $runId = Select-LabRun -Runs $runs -Prompt "Entfernen" -DisableAutomatedTestEnvironments -DisableSystemServices
            if ($runId) {
                $confirm = Read-Host "  Wirklich entfernen? (j/n) [n]"
                if ($confirm -eq 'j') { Remove-SqlServerLab -RunId $runId -Force }
            }
        }

        'Clear' {
            Clear-SqlServerLab
        }

        'Database' {
            $runs = @(Get-LabRunsByRuntimeState -State 'RUNNING')
            if ($runs.Count -eq 0) {
                Write-LabInfo "Keine laufenden Labs."
                return
            }
            $runId = Select-LabRun -Runs $runs -Prompt "Datenbank anlegen auf" -DisableAutomatedTestEnvironments -DisableSystemServices
            if (-not $runId) { return }

            $stateRoot = Get-LabStateRoot
            $connectionInfoPath = Join-Path (Join-Path (Join-Path $stateRoot 'runs') $runId) 'connection-info.json'
            if (-not (Test-Path -LiteralPath $connectionInfoPath -PathType Leaf)) { Write-LabError 'Connection-Info nicht gefunden.'; return }
            $connectionInfo = Get-Content -LiteralPath $connectionInfoPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
            $instanceId = [string](@($connectionInfo.instances | Select-Object -First 1)[0].id)
            if (-not $instanceId) { Write-LabError 'Keine Container-Instanz im Run gespeichert.'; return }
            try { $target = Resolve-LabRunInstance -RunId $runId -InstanceId $instanceId -StateRoot $stateRoot }
            catch { Write-LabError $_.Exception.Message; return }

            if (Read-LabConfirm -Prompt '  Testdatenbank aus dem Katalog wiederherstellen?' -Default $false) {
                $selectedSamples = @(Select-LabSampleSelection -SqlVersion $target.Version -SkipInitialConfirm)
                if ($selectedSamples.Count -eq 0) { return }
                $pw = Read-Host '  SA-Passwort' -AsSecureString
                $runDirectory = Join-Path (Join-Path $stateRoot 'runs') $runId
                foreach ($sampleSpec in $selectedSamples) {
                    $parts = ([string]$sampleSpec).Split(':', 2)
                    $sample = Get-LabSampleDatabase -Id $parts[0]
                    $variantName = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { 'full' }
                    if (-not $sample) { Write-LabError "Sample nicht gefunden: $sampleSpec"; continue }
                    $variant = @($sample.versions.PSObject.Properties | Where-Object Name -eq $variantName | Select-Object -First 1)
                    if ($variant.Count -ne 1) { Write-LabError "Sample-Variante nicht gefunden: $sampleSpec"; continue }
                    $outputs = @($variant[0].Value.expectedOutputs)
                    if ($outputs.Count -eq 0 -or @($outputs | Where-Object { $_.kind -ne 'database' -or -not $_.name }).Count -gt 0) { Write-LabError "Sample besitzt keine eindeutige Datenbank-Outputliste: $sampleSpec"; continue }
                    try {
                        $restoreDefinition = Resolve-LabSampleRestore -SampleDefinition ([PSCustomObject]@{ id = $parts[0]; variant = $variantName }) -SqlVersion $target.Version -TargetDatabaseName ([string]$outputs[0].name)
                        $result = Install-LabSampleDatabase -HostName $target.HostName -Port $target.Port -SaPassword $pw -ContainerName $target.ContainerName -RestoreDefinition $restoreDefinition -RunDirectory $runDirectory -StateRoot $stateRoot
                        if ($result.Success) { Write-LabSuccess $result.Message } else { Write-LabError "$($result.Status): $($result.Message)" }
                    }
                    catch { Write-LabError $_.Exception.Message }
                }
                return
            }

            $dbName = Read-Host "  Datenbankname"
            if (-not $dbName) { return }

            $pw = Read-Host "  SA-Passwort" -AsSecureString
            New-SqlServerLabDatabase -HostName $target.HostName -Port $target.Port -SaPassword $pw -DatabaseName $dbName
        }

        'Script' {
            $runs = @(Get-LabRunsByRuntimeState -State 'RUNNING')
            if ($runs.Count -eq 0) {
                Write-LabInfo "Keine laufenden Labs."
                return
            }
            $runId = Select-LabRun -Runs $runs -Prompt "Skript ausfuehren auf" -DisableAutomatedTestEnvironments -DisableSystemServices
            if (-not $runId) { return }

            # Port aus connection-info lesen
            $stateRoot = Get-LabStateRoot
            $connInfoPath = Join-Path $stateRoot "runs/$runId/connection-info.json"
            $connInfo = Get-Content $connInfoPath -Raw | ConvertFrom-Json
            $port = $connInfo.instances[0].port

            $scriptPath = Read-Host "  Skript-Pfad"
            if (-not $scriptPath -or -not (Test-Path $scriptPath)) {
                Write-LabError "Skript nicht gefunden: $scriptPath"
                return
            }

            $db = Read-Host "  Datenbank [master]"
            if (-not $db) { $db = 'master' }

            $pw = Read-Host "  SA-Passwort" -AsSecureString
            Invoke-SqlServerLabScript -ScriptPath $scriptPath -Port $port -SaPassword $pw -Database $db
        }

        'Image' {
            Invoke-LabHyperVImageAction
        }
        'Catalog' {
            $stateRoot = Get-LabStateRoot
            $defaultPath = Join-Path (Join-Path $stateRoot 'catalog') 'sql-server-lab-catalog.json'
            $catalogPath = Read-Host "  Katalog-Zielpfad [$defaultPath]"
            if ([string]::IsNullOrWhiteSpace($catalogPath)) {
                $catalogPath = $defaultPath
            }
            try {
                $catalog = Get-SqlServerLabCatalog -Path $catalogPath -StateRoot $stateRoot
                $path = $catalog.Path
                $workflow = $catalog.Catalog
                $summary = $workflow.Summary
                $providerValues = @($workflow.Host.Providers | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
                $providerColorMap = @{
                    docker = 'DarkCyan'
                    podman = 'DarkGreen'
                    hyperv = 'DarkYellow'
                }
                $fallbackMediaRoot = Get-LabMediaRootDefault
                $mediaRootText = if ([string]::IsNullOrWhiteSpace($workflow.Defaults.MediaRoot)) {
                    if ([string]::IsNullOrWhiteSpace($fallbackMediaRoot)) { 'nicht gesetzt' } else { "nicht gesetzt (Standard: $fallbackMediaRoot)" }
                } else {
                    [string]$workflow.Defaults.MediaRoot
                }
                Write-LabSuccess "SQL-Server-Lab-Katalog erstellt: $path"
                Write-Host ('  Erzeugt: {0} · Katalog-Format: {1} · Module: {2}' -f
                    $catalog.GeneratedAt, $catalog.Catalog.CatalogFormat, $catalog.Catalog.Module.Version) -ForegroundColor White
                Write-Host ('  StateRoot: {0}' -f $workflow.StateRoot) -ForegroundColor White
                Write-Host ('  Medienroot: {0}' -f $mediaRootText) -ForegroundColor White
                Write-LabProviderList -Providers $providerValues
                Write-Host ('  Windows-Baselines: {0} · SQL-Prepared-Images: {1}' -f $summary.WindowsBaselines, $summary.SqlPreparedImages) -ForegroundColor White
                Write-Host ('  Offene Builds: Windows {0}, SQL {1} · aktive Hyper-V-Labs: {2}' -f
                    $summary.PendingWindowsBuilds, $summary.PendingSqlBuilds, @($workflow.HyperVLabs).Count) -ForegroundColor White
                Write-Host ('  Aktive Container-Labs: {0} · SQL-Medien: {1} · Windows-Medien: {2}' -f
                    $summary.ActiveContainerLabs, @($workflow.SqlInstallationMedia).Count, @($workflow.WindowsInstallationMedia).Count) -ForegroundColor White
                try {
                    $file = Get-Item -LiteralPath $path -ErrorAction Stop
                    Write-Host ('  Dateigröße: {0} KB' -f [Math]::Round($file.Length / 1KB, 2)) -ForegroundColor White
                }
                catch {
                    Write-LabInfo "Datei konnte zur Größenbestimmung nicht gelesen werden: $($_.Exception.Message)"
                }
            }
            catch {
                Write-LabError $_.Exception.Message
            }
        }
        'ConnectionCenter' {
            Invoke-LabConnectionCenterInteractive
        }
    }
}

function Get-LabAutomaticallyGeneratedRunSaPassword {
    <#
    .SYNOPSIS
        Liefert ausschließlich ein vom Lab selbst erzeugtes SA-Passwort im Klartext.
    .DESCRIPTION
        Manuell eingegebene oder manifestbasierte Kennwörter werden nie angezeigt.
        Bestehende CMS-Konfigurationen vor PasswordOrigin/1.0 gelten aufgrund ihres
        ausschließlich generatorbasierten CMS-Workflows ebenfalls als erzeugt.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    try {
        $cms = Get-LabConnectionCenterCmsConfiguration -StateRoot $StateRoot
        $isGeneratedCms = $cms -and [string]$cms.RunId -eq $RunId -and (
            [string]$cms.PasswordOrigin -eq 'Generated' -or
            ([string]::IsNullOrWhiteSpace([string]$cms.PasswordOrigin) -and [string]$cms.Purpose -eq 'Central Management Server')
        )
        if ($isGeneratedCms) {
            $secret = Get-LabSecret -Path (Join-Path (Join-Path $StateRoot 'runs') $RunId) -Name 'sa-password'
            if ($secret) {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
                try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
                finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            }
        }
    }
    catch { }

    try {
        if (Test-LabAutomatedTestEnvironmentRun -RunId $RunId) {
            $secret = Get-LabSecret -Path (Join-Path (Join-Path $StateRoot 'runs') $RunId) -Name 'sa-password'
            if (-not $secret) { $secret = Get-LabSecret -Path (Join-Path (Join-Path $StateRoot 'runs') $RunId) -Name 'generated-sql-sa-password' }
            if ($secret) {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
                try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
                finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            }
        }
    }
    catch { }

    try {
        $generatedAccess = Get-SqlServerLabGeneratedSqlAccess -RunId $RunId -StateRoot $StateRoot
        if ($generatedAccess -and $generatedAccess.Generated -and $generatedAccess.Persisted -and $generatedAccess.Password) {
            return [string]$generatedAccess.Password
        }
    }
    catch { }
    return $null
}

function Get-LabHostPhysicalMemoryMB {
    [CmdletBinding()]
    param()
    try {
        [long]$bytes = 0
        if ($env:OS -eq 'Windows_NT') {
            $bytes = [long](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
        }
        elseif (Test-Path -LiteralPath '/proc/meminfo' -PathType Leaf) {
            $line = Get-Content -LiteralPath '/proc/meminfo' | Where-Object { $_ -match '^MemTotal:\s+(\d+)\s+kB$' } | Select-Object -First 1
            if ($line -match '^MemTotal:\s+(\d+)\s+kB$') { $bytes = [long]$Matches[1] * 1KB }
        }
        if ($bytes -gt 0) { return [long][Math]::Floor($bytes / 1MB) }
    }
    catch { Write-Verbose $_.Exception.Message }
    return [long]0
}

function Read-LabIntegerIntentValue {
    [CmdletBinding()]
    param([string]$Prompt, [int]$Default, [int]$Minimum, [int]$Maximum)
    while ($true) {
        $raw = Read-Host "  $Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        $value = 0
        if ([int]::TryParse($raw, [ref]$value) -and $value -ge $Minimum -and $value -le $Maximum) { return $value }
        Write-LabWarning "$Prompt muss eine ganze Zahl zwischen $Minimum und $Maximum sein."
    }
}

function Read-LabDecimalIntentValue {
    [CmdletBinding()]
    param([string]$Prompt, [decimal]$Default, [decimal]$Minimum, [decimal]$Maximum)
    $culture = [Globalization.CultureInfo]::InvariantCulture
    while ($true) {
        $raw = Read-Host ("  {0} [{1}]" -f $Prompt, $Default.ToString('0.##', $culture))
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        $value = [decimal]0
        if ($raw -notmatch ',' -and [decimal]::TryParse($raw, [Globalization.NumberStyles]::Number, $culture, [ref]$value) -and $value -ge $Minimum -and $value -le $Maximum) { return $value }
        Write-LabWarning "$Prompt muss zwischen $Minimum und $Maximum liegen; Dezimaltrennzeichen ist ein Punkt, z. B. 1.5."
    }
}

function New-LabWindowsBaseSqlPatchIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BaseVersion)

    return [PSCustomObject]@{
        VersionId = $BaseVersion
        BaseVersion = $BaseVersion
        Cu = $null
        Build = $null
        Kb = $null
        Released = $null
        ArticleUrl = $null
        WindowsStatus = 'NOT_APPLICABLE'
        WindowsRelativePath = $null
        WindowsPath = $null
        CanAutoDownload = $false
        Floating = $false
        Reproducible = $true
        PatchMode = 'base'
    }
}

function Select-LabSqlPatchIntent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseVersion,
        [ValidateSet('linux','windows')][string]$Platform = 'linux'
    )
    $mediaRoot = Get-LabMediaRootDefault
    $patches = @(Get-SqlServerPatchOptions -VersionId $BaseVersion -MediaRoot $mediaRoot)
    $windowsBase = New-LabWindowsBaseSqlPatchIntent -BaseVersion $BaseVersion
    $floatingLatest = [PSCustomObject]@{
        VersionId = $BaseVersion
        BaseVersion = $BaseVersion
        Cu = $null
        Build = $null
        Kb = $null
        Released = $null
        ArticleUrl = $null
        WindowsStatus = 'NOT_APPLICABLE'
        WindowsRelativePath = $null
        CanAutoDownload = $false
        Floating = $true
        Reproducible = $false
        PatchMode = 'latest'
    }
    if ($patches.Count -eq 0) {
        if ($Platform -eq 'windows') {
            Write-LabInfo "Für SQL Server $BaseVersion sind keine einzelnen CUs katalogisiert; die Windows-Basisinstallation ohne separates CU wird verwendet."
            return $windowsBase
        }
        Write-LabInfo "Für SQL Server $BaseVersion sind keine einzelnen CUs katalogisiert; der veränderliche Microsoft-Tag latest wird verwendet."
        return $floatingLatest
    }
    $catalogLatest = $patches[0]
    $floatingImage = Get-SqlServerDockerImage -VersionId $BaseVersion
    $catalogDate = [string]$script:VersionCatalog.catalogMetadata.lastVerified
    Write-Host "  Katalogisierte Patchstände (Stand $catalogDate):" -ForegroundColor White
    if ($Platform -eq 'windows') {
        Write-Host '    base · SQL-Installationsmedium ohne separates CU-Paket' -ForegroundColor Green
    }
    else {
        Write-Host "    latest (gleitend) · $floatingImage · nicht reproduzierbar" -ForegroundColor Green
    }
    Write-Host "    aktuell katalogisiert: $($catalogLatest.Cu) · Build $($catalogLatest.Build) · $($catalogLatest.Kb)" -ForegroundColor DarkGreen
    foreach ($patch in $patches) {
        $windowsText = if ($patch.WindowsStatus -like 'PRESENT*') { 'Windows-Paket vorhanden' } else { "Windows-Paket fehlt: $($patch.WindowsRelativePath)" }
        Write-Host "    $($patch.Cu) · Build $($patch.Build) · $($patch.Kb) · $($patch.Released) · $windowsText" -ForegroundColor $(if ($patch.WindowsStatus -like 'PRESENT*') { 'White' } else { 'DarkYellow' })
    }
    Write-Host '  Fehlende Windows-Pakete verhindern weder Container noch die Windows-Basisinstallation; sie werden nur für ein ausdrücklich gewähltes Hyper-V-CU benötigt.' -ForegroundColor DarkGray
    while ($true) {
        if ($Platform -eq 'windows') {
            Write-Host '  [base]   Basisinstallation vom SQL-Medium ohne separates CU (Default)' -ForegroundColor Green
        }
        else {
            Write-Host '  [latest] Gleitender Microsoft-Tag; bei jeder neuen Erstellung aktuell (Default, nicht reproduzierbar)' -ForegroundColor Green
        }
        Write-Host "  [CU]     Fixierter Stand: $(@($patches.Cu | Sort-Object { [int]($_ -replace '^CU','') }) -join ', ')" -ForegroundColor White
        $selection = Read-Host $(if ($Platform -eq 'windows') { '  Patchstand [base]' } else { '  Patchstand [latest]' })
        if ($Platform -eq 'windows' -and (-not $selection -or $selection -in @('base','latest'))) {
            if ($selection -eq 'latest') { Write-LabWarning 'Windows latest wird aus Kompatibilitätsgründen als base interpretiert: Basisinstallation ohne separates CU.' }
            return $windowsBase
        }
        if ($Platform -eq 'linux' -and (-not $selection -or $selection -eq 'latest')) {
            Write-LabWarning 'latest ist ein gleitender Microsoft-Tag. Eine spätere Erstellung kann einen neueren CU-Stand verwenden.'
            return $floatingLatest
        }
        $selected = $patches | Where-Object { $_.Cu -eq $selection.ToUpperInvariant() } | Select-Object -First 1
        if ($selected) { return $selected }
        Write-LabWarning 'Patchstand ist nicht im lokalen Agent-Katalog enthalten.'
    }
}

function Read-LabSqlEnvironmentIntentInteractive {
    [CmdletBinding()]
    param()
    $versions = @(Get-SqlServerVersions | Where-Object { $_.status -ne 'BLOCKED' } | Sort-Object { [int]$_.id } -Descending)
    $selectOption = {
        param([string]$ScreenId, [string]$Title, [object[]]$Options, [string]$CurrentId)
        $items = for ($index = 0; $index -lt $Options.Count; $index++) {
            New-LabConsoleItem -Id ([string]$Options[$index].Id) -Label ([string]$Options[$index].Label) -Value $Options[$index].Value -Shortcut ([string]($index + 1))
        }
        $result = Invoke-LabConsoleMenu -ScreenId $ScreenId -Title $Title -Items $items -SelectedId $CurrentId -Footer 'Pfeile: Navigation  Enter: Auswahl  Esc: bisherigen Wert behalten' -FallbackPrompt '  Auswahl'
        if ($result.Status -eq 'Selected') { return [string]$result.SelectedItem.Id }
        return $CurrentId
    }
    $mode = & $selectOption -ScreenId 'sql-intent-mode' -Title 'SQL-Zielkonfiguration' -CurrentId 'quick' -Options @(
        [PSCustomObject]@{ Id='quick'; Label='Schnellkonfiguration'; Value='sichtbare Standardwerte' }
        [PSCustomObject]@{ Id='custom'; Label='Benutzerdefiniert'; Value='OS, Edition, Netzwerk, Storage, I/O, TempDB und Collation' }
    )
    $custom = $mode -eq 'custom'
    $versionOptions = @($versions | ForEach-Object { [PSCustomObject]@{ Id=[string]$_.id; Label="SQL Server $($_.id)"; Value=[string]$_.status } })
    $baseVersion = & $selectOption -ScreenId 'sql-intent-version' -Title 'SQL Server Version' -Options $versionOptions -CurrentId '2025'
    if ($baseVersion -notin @($versions.id)) { Write-LabWarning 'SQL-Version ist nicht im Agent-Katalog enthalten.'; return $null }
    $patch = Select-LabSqlPatchIntent -BaseVersion $baseVersion
    $physicalMemoryMB = Get-LabHostPhysicalMemoryMB
    $memoryPrompt = if ($physicalMemoryMB -gt 0) { "RAM MB (Minimum 2048; Host physisch: $physicalMemoryMB; technisches Limit: 1048576)" } else { 'RAM MB (2048..1048576; Host-RAM nicht ermittelbar)' }
    $defaultCpu = [decimal]4
    $defaultMemoryMB = 4096
    $defaultMaxDop = [Math]::Min(8, [int][Math]::Ceiling([double]$defaultCpu))
    $defaultName = 'sql-lab-{0}' -f (Get-Date -Format 'yyyy-MM-dd-HHmmss')
    $defaultStorage = [PSCustomObject]@{ Mode='standard'; TempDbVolumeCount=1; Drives=@() }

    $selectVersion = {
        param($current, $values)
        $selected = & $selectOption -ScreenId 'sql-intent-version-edit' -Title 'SQL Server Version bearbeiten' -Options $versionOptions -CurrentId ([string]$current)
        if ($selected -ne [string]$current) { $values['patch'] = Select-LabSqlPatchIntent -BaseVersion $selected }
        $selected
    }
    $selectPatch = { param($current, $values) Select-LabSqlPatchIntent -BaseVersion ([string]$values['baseVersion']) }
    $selectPurpose = { param($current, $values) & $selectOption -ScreenId 'sql-intent-purpose' -Title 'Verwendung' -CurrentId ([string]$current) -Options @([PSCustomObject]@{Id='adhoc';Label='Fertige Ad-hoc-Umgebung';Value=$null},[PSCustomObject]@{Id='sql-pool-slot';Label='Ausgeschalteter SQL-Pool-Slot';Value=$null}) }
    $selectWindows = { param($current, $values) [bool]::Parse((& $selectOption -ScreenId 'sql-intent-windows' -Title 'Windows-Gast erforderlich' -CurrentId ([string]$current).ToLowerInvariant() -Options @([PSCustomObject]@{Id='false';Label='Nein';Value='Container ist zulässig'},[PSCustomObject]@{Id='true';Label='Ja';Value='Hyper-V erforderlich'}))) }
    $selectEdition = { param($current, $values) & $selectOption -ScreenId 'sql-intent-edition' -Title 'SQL-Edition' -CurrentId ([string]$current) -Options @([PSCustomObject]@{Id='Developer';Label='Developer';Value=$null},[PSCustomObject]@{Id='Standard';Label='Standard';Value=$null},[PSCustomObject]@{Id='Enterprise';Label='Enterprise';Value=$null}) }
    $selectNetwork = {
        param($current, $values)
        $selected = & $selectOption -ScreenId 'sql-intent-network' -Title 'Netzwerkmodus' -CurrentId ([string]$current) -Options @([PSCustomObject]@{Id='host-access';Label='Hostzugriff';Value='SQL-Port am Host'},[PSCustomObject]@{Id='isolated';Label='Vollstaendig isoliert';Value='kein Hostport'},[PSCustomObject]@{Id='external';Label='Externes LAN';Value='expliziter Netzwerkvertrag erforderlich'})
        if ($selected -ne 'host-access') { $values['hostPort'] = 0 }
        $selected
    }
    $editStorage = {
        param($current, $values)
        $modeSelection = & $selectOption -ScreenId 'sql-intent-storage' -Title 'Storage-Layout' -CurrentId ([string]$current.Mode) -Options @([PSCustomObject]@{Id='standard';Label='Standardlayout';Value='Framework-Defaults'},[PSCustomObject]@{Id='separated';Label='Getrennte Datentraeger';Value='Data, Log, TempDB und Backup'})
        if ($modeSelection -eq 'standard') { return [PSCustomObject]@{ Mode='standard'; TempDbVolumeCount=1; Drives=@() } }
        $volumeCount = Read-LabIntegerIntentValue -Prompt 'Anzahl verteilter TempDB-Datentraeger' -Default ([Math]::Max(1,[int]$current.TempDbVolumeCount)) -Minimum 1 -Maximum 8
        $drives = @()
        $specs = @([PSCustomObject]@{Id='data';Role='sqlData';Size=128;Count=1},[PSCustomObject]@{Id='log';Role='sqlLog';Size=64;Count=1},[PSCustomObject]@{Id='tempdb';Role='tempdb';Size=32;Count=$volumeCount},[PSCustomObject]@{Id='backup';Role='backup';Size=64;Count=1})
        foreach ($spec in $specs) {
            for ($index=1; $index -le $spec.Count; $index++) {
                $label = "$($spec.Id)$(if ($spec.Count -gt 1) { $index } else { '' })"
                $size = Read-LabIntegerIntentValue -Prompt "$label Groesse GB" -Default $spec.Size -Minimum 1 -Maximum 4096
                $iops = Read-LabIntegerIntentValue -Prompt "$label maximale IOPS (0 = unbegrenzt)" -Default 0 -Minimum 0 -Maximum 1000000
                $drives += [PSCustomObject]@{ Id=$label; Role=$spec.Role; SizeGB=$size; MaximumIops=$iops }
            }
        }
        [PSCustomObject]@{ Mode='separated'; TempDbVolumeCount=$volumeCount; Drives=$drives }
    }
    $formatStorage = { param($value) if ([string]$value.Mode -eq 'standard') { 'Standardlayout' } else { "Getrennt: $(@($value.Drives | ForEach-Object { "$($_.Id)=$($_.SizeGB)GB/$($_.MaximumIops)IOPS" }) -join ', ')" } }

    $fields = @(
        New-LabConsoleField -Id 'labName' -Label 'Labname' -Value $defaultName -Shortcut '1' -Editor { param($current,$values) $candidate=Read-Host "  Labname [$current]"; if($candidate){$candidate}else{$current} } -Validator { param($value,$values) if([string]$value -notmatch '^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$'){'Labname ist ungueltig.'} } -Required
        New-LabConsoleField -Id 'baseVersion' -Label 'SQL Server Version' -Value $baseVersion -Shortcut '2' -Editor $selectVersion -Validator { param($value,$values) if([string]$value -notin @($versions.id)){'SQL-Version fehlt im Agent-Katalog.'} }
        New-LabConsoleField -Id 'patch' -Label 'Patchstand' -Value $patch -Shortcut '3' -Editor $selectPatch -Formatter { param($value) [string]$value.VersionId }
        New-LabConsoleField -Id 'cpu' -Label 'vCPU (1..64)' -Value $defaultCpu -Shortcut '4' -Editor { param($current,$values) Read-LabDecimalIntentValue -Prompt 'vCPU (1..64)' -Default ([decimal]$current) -Minimum 1 -Maximum 64 }
        New-LabConsoleField -Id 'memoryMB' -Label $memoryPrompt -Value $defaultMemoryMB -Shortcut '5' -Editor { param($current,$values) Read-LabIntegerIntentValue -Prompt $memoryPrompt -Default ([int]$current) -Minimum 2048 -Maximum 1048576 }
        New-LabConsoleField -Id 'hostPort' -Label 'SQL-Hostport (0 = automatisch)' -Value 0 -Shortcut '6' -Editor { param($current,$values) if([string]$values['networkMode'] -ne 'host-access'){0}else{Read-LabIntegerIntentValue -Prompt 'SQL-Hostport (0 = automatisch)' -Default ([int]$current) -Minimum 0 -Maximum 65535} } -Validator { param($value,$values) if([string]$values['networkMode'] -eq 'host-access' -and [int]$value -gt 0 -and [int]$value -lt 1024){'Ports unter 1024 sind nicht zulaessig.'}elseif([string]$values['networkMode'] -ne 'host-access' -and [int]$value -ne 0){'Ohne Hostzugriff muss der Hostport 0 sein.'}elseif([string]$values['networkMode'] -eq 'host-access' -and [int]$value -gt 0){$binding=Test-LabEndpointBinding -Port ([int]$value);if(-not $binding.Available){"Port $value ist belegt. Besitzer: $($binding.Owner). Grund: $($binding.Reason)"}} }
    )
    if ($custom) {
        $fields += @(
            New-LabConsoleField -Id 'purpose' -Label 'Verwendung' -Value 'adhoc' -Shortcut '7' -Editor $selectPurpose
            New-LabConsoleField -Id 'requiresWindows' -Label 'Windows-Gast erforderlich' -Value $false -Shortcut '8' -Editor $selectWindows -Formatter { param($value) if([bool]$value){'Ja'}else{'Nein'} }
            New-LabConsoleField -Id 'edition' -Label 'SQL-Edition' -Value 'Developer' -Shortcut '9' -Editor $selectEdition
            New-LabConsoleField -Id 'networkMode' -Label 'Netzwerkmodus' -Value 'host-access' -Shortcut 'n' -Editor $selectNetwork
            New-LabConsoleField -Id 'collation' -Label 'Server-Collation' -Value 'SQL_Latin1_General_CP1_CI_AS' -Shortcut 'c' -Editor { param($current,$values) $candidate=Read-Host "  Server-Collation [$current]";if($candidate){$candidate}else{$current} } -Validator { param($value,$values) if([string]$value -notmatch '^[A-Za-z0-9_]{1,128}$'){'Collation darf nur Buchstaben, Zahlen und Unterstriche enthalten.'} }
            New-LabConsoleField -Id 'sqlMaxMemoryMB' -Label 'SQL max server memory MB' -Value ([Math]::Max(1024,$defaultMemoryMB-1024)) -Shortcut 's' -Editor { param($current,$values) Read-LabIntegerIntentValue -Prompt 'SQL max server memory MB' -Default ([int]$current) -Minimum 512 -Maximum ([Math]::Max(512,[int]$values['memoryMB']-256)) } -Validator { param($value,$values) if([int]$value -gt ([Math]::Max(512,[int]$values['memoryMB']-256))){'SQL max memory muss mindestens 256 MB unter dem Lab-RAM bleiben.'} }
            New-LabConsoleField -Id 'maxDop' -Label 'MAXDOP (0..64)' -Value $defaultMaxDop -Shortcut 'm' -Editor { param($current,$values) Read-LabIntegerIntentValue -Prompt 'MAXDOP (0..64)' -Default ([int]$current) -Minimum 0 -Maximum 64 }
            New-LabConsoleField -Id 'costThreshold' -Label 'Cost Threshold for Parallelism' -Value 50 -Shortcut 'o' -Editor { param($current,$values) Read-LabIntegerIntentValue -Prompt 'Cost Threshold for Parallelism (0..32767)' -Default ([int]$current) -Minimum 0 -Maximum 32767 }
            New-LabConsoleField -Id 'tempDbFileCount' -Label 'Anzahl TempDB-Datendateien' -Value $defaultMaxDop -Shortcut 't' -Editor { param($current,$values) Read-LabIntegerIntentValue -Prompt 'Anzahl TempDB-Datendateien' -Default ([int]$current) -Minimum 1 -Maximum 32 }
            New-LabConsoleField -Id 'tempDbFileSizeMB' -Label 'TempDB-Dateigroesse MB' -Value 256 -Shortcut 'g' -Editor { param($current,$values) Read-LabIntegerIntentValue -Prompt 'TempDB-Dateigroesse MB' -Default ([int]$current) -Minimum 8 -Maximum 1048576 }
            New-LabConsoleField -Id 'tempDbGrowthMB' -Label 'TempDB-Wachstum MB' -Value 64 -Shortcut 'w' -Editor { param($current,$values) Read-LabIntegerIntentValue -Prompt 'TempDB-Wachstum MB' -Default ([int]$current) -Minimum 1 -Maximum 1048576 }
            New-LabConsoleField -Id 'storage' -Label 'Storage-Layout und IOPS' -Value $defaultStorage -Shortcut 'd' -Editor $editStorage -Formatter $formatStorage
        )
    }
    if (-not $custom) {
        $fields += New-LabConsoleField -Id 'networkMode' -Label 'Netzwerkmodus' -Value 'host-access' -Editor { param($current,$values) $current }
    }
    $formResult = Invoke-LabConsoleForm -ScreenId 'sql-target-configuration' -Title 'SQL-Zielkonfiguration bearbeiten' -Subtitle $(if($custom){'Benutzerdefiniert - alle Werte vor Providerentscheidung'}else{'Schnellkonfiguration - sichtbare Standardwerte'}) -Fields $fields
    if ($formResult.Status -ne 'Confirmed') { Write-LabInfo 'SQL-Zielkonfiguration abgebrochen.'; return $null }
    $values = $formResult.Values
    $cpu = [decimal]$values['cpu']; $memoryMB = [int]$values['memoryMB']; $patch = $values['patch']
    if ($physicalMemoryMB -gt 0 -and $memoryMB -gt $physicalMemoryMB) { Write-LabWarning "RAM-Overcommit: $memoryMB MB angefordert, physisch $physicalMemoryMB MB. Auslagerung ist nicht garantiert; Runtime kann OOM oder Startfehler liefern." }
    $storage = if($custom){$values['storage']}else{$defaultStorage}
    $profile = if ($cpu -le 2 -and $memoryMB -le 2048) {'compact'} elseif ($cpu -le 4 -and $memoryMB -le 4096) {'standard'} else {'performance'}
    return [PSCustomObject]@{
        Contract='SqlServerLab.InteractiveSqlIntent/1.1'; CustomConfiguration=$custom; LabName=[string]$values['labName']; InstanceId='primary'
        BaseVersion=[string]$values['baseVersion']; VersionId=[string]$patch.VersionId; Patch=$patch
        Purpose=if($custom){[string]$values['purpose']}else{'adhoc'}; RequiresWindows=if($custom){[bool]$values['requiresWindows']}else{$false}; Edition=if($custom){[string]$values['edition']}else{'Developer'}
        Cpu=$cpu; MemoryMB=$memoryMB; Profile=$profile; NetworkMode=[string]$values['networkMode']; HostPort=[int]$values['hostPort']
        Collation=if($custom){[string]$values['collation']}else{'SQL_Latin1_General_CP1_CI_AS'}
        SqlMaxMemoryMB=if($custom){[int]$values['sqlMaxMemoryMB']}else{[Math]::Max(1024,$memoryMB-1024)}
        MaxDop=if($custom){[int]$values['maxDop']}else{[Math]::Min(8,[int][Math]::Ceiling([double]$cpu))}; CostThreshold=if($custom){[int]$values['costThreshold']}else{50}
        StorageMode=[string]$storage.Mode; Drives=@($storage.Drives)
        TempDbFileCount=if($custom){[int]$values['tempDbFileCount']}else{[Math]::Min(8,[int][Math]::Ceiling([double]$cpu))}
        TempDbFileSizeMB=if($custom){[int]$values['tempDbFileSizeMB']}else{256}; TempDbGrowthMB=if($custom){[int]$values['tempDbGrowthMB']}else{64}; TempDbVolumeCount=[int]$storage.TempDbVolumeCount
    }
}

function Resolve-LabSqlIntentProvider {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Intent,[Parameter(Mandatory)][string[]]$AvailableProviders)
    $reasons=[Collections.Generic.List[string]]::new()
    if ([int]$Intent.BaseVersion -lt 2017) {$reasons.Add('Für diese SQL-Version ist kein unterstütztes Containerimage katalogisiert.')}
    if ($Intent.RequiresWindows) {$reasons.Add('Windows-Gast wurde angefordert.')}
    if ($Intent.Edition -ne 'Developer') {$reasons.Add("Edition $($Intent.Edition) benötigt den Windows-/ISO-Pfad.")}
    if ($Intent.Purpose -eq 'sql-pool-slot') {$reasons.Add('Ein SQL-Pool-Slot benötigt Hyper-V.')}
    if ($Intent.NetworkMode -in @('isolated','external')) {$reasons.Add("Netzwerkmodus $($Intent.NetworkMode) benötigt Hyper-V.")}
    if (@($Intent.Drives | Where-Object {[long]$_.MaximumIops -gt 0}).Count -gt 0) {$reasons.Add('Datenträgerbezogene IOPS-Limits benötigen Hyper-V.')}
    if ($Intent.NetworkMode -eq 'external') { return [PSCustomObject]@{Supported=$false;Provider=$null;Reasons=@('Externes LAN benötigt zuerst einen vollständigen IP-/Gateway-/DNS-Vertrag.')} }
    if ($reasons.Count -gt 0) {
        if ($Intent.Patch.Floating) { $reasons.Add('Der für Container gleitende Stand latest wird bei Hyper-V als Windows-Basisinstallation ohne separates CU ausgeführt.') }
        if ([decimal]$Intent.Cpu % 1 -ne 0) { return [PSCustomObject]@{Supported=$false;Provider=$null;Reasons=@('Hyper-V benötigt ganzzahlige vCPU.')} }
        if ($Intent.Patch.Cu -and $Intent.Patch.WindowsStatus -ne 'PRESENT_HASH_CATALOGUED' -and -not $Intent.Patch.CanAutoDownload) { return [PSCustomObject]@{Supported=$false;Provider=$null;Reasons=@($reasons + "Windows-Paket fehlt oder besitzt keinen katalogisierten SHA-256: $($Intent.Patch.WindowsRelativePath)" + "Quelle: $($Intent.Patch.ArticleUrl)")} }
        if ('hyperv' -notin $AvailableProviders) { return [PSCustomObject]@{Supported=$false;Provider=$null;Reasons=@($reasons + 'Hyper-V ist nicht verfügbar.')} }
        return [PSCustomObject]@{Supported=$true;Provider='hyperv';Reasons=@($reasons)}
    }
    foreach ($candidate in @('docker','podman')) { if ($candidate -in $AvailableProviders) { try {$null=Get-SqlServerDockerImage -VersionId $Intent.VersionId; return [PSCustomObject]@{Supported=$true;Provider=$candidate;Reasons=@('Linux-Container erfüllt alle Anforderungen und wird bevorzugt.')}} catch {} } }
    return [PSCustomObject]@{Supported=$false;Provider=$null;Reasons=@('Kein Provider kann den Sollzustand reproduzieren.')}
}

function Confirm-LabSqlWindowsPatchMediaInteractive {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Intent)
    if (-not $Intent.Patch.Cu) { return $true }
    $mediaRoot = Get-LabMediaRootDefault
    if (-not $mediaRoot) { Write-LabError 'Für ein Windows-CU ist ein konfigurierter Media Root erforderlich.'; return $false }
    if ($Intent.Patch.WindowsStatus -ne 'PRESENT_HASH_CATALOGUED') {
        if (-not $Intent.Patch.CanAutoDownload) {
            Write-LabError "Windows-CU nicht sicher verfügbar: $($Intent.Patch.WindowsRelativePath)"
            if ($Intent.Patch.ArticleUrl) { Write-Host "  Quelle: $($Intent.Patch.ArticleUrl)" -ForegroundColor DarkYellow }
            return $false
        }
        Write-LabInfo "Windows-Paket $($Intent.Patch.Cu) kann über die katalogisierte HTTPS-Quelle mit SHA-256-Prüfung geladen werden."
        if (-not (Read-LabConfirm -Prompt '  Fehlendes SQL-CU-Paket jetzt sicher herunterladen?' -Default $true)) { return $false }
        $path = Save-SqlServerWindowsPatchPackage -Patch $Intent.Patch -MediaRoot $mediaRoot
        $Intent.Patch | Add-Member -NotePropertyName WindowsPath -NotePropertyValue $path -Force
        $Intent.Patch | Add-Member -NotePropertyName WindowsStatus -NotePropertyValue 'PRESENT_HASH_CATALOGUED' -Force
    }
    try { $null = Confirm-SqlServerWindowsPatchPackage -Patch $Intent.Patch; return $true }
    catch { Write-LabError $_.Exception.Message; return $false }
}

function New-LabHyperVDrivesFromIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Intent)
    if ($Intent.StorageMode -ne 'separated') { return @() }
    $letters=@('T','U','V','W','X','Y','Z','Q');$tempIndex=0
    return @($Intent.Drives | ForEach-Object {
        $guestPath=switch($_.Role){'sqlData'{'E:\SQLData'}'sqlLog'{'L:\SQLLog'}'backup'{'R:\SQLBackup'}'tempdb'{$letter=$letters[$tempIndex];$tempIndex++;"${letter}:\TempDB"}}
        [PSCustomObject]@{id=[string]$_.Id;role=[string]$_.Role;sizeBytes=[long]$_.SizeGB*1GB;vhdType='dynamic';guestPath=$guestPath;allocationUnitKB=64;fileSystem='NTFS';maximumIops=[long]$_.MaximumIops}
    })
}

function New-LabIntentServerConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Intent,
        [ValidateSet('container', 'hyperv')][string]$Target = 'container'
    )
    $roots = if ($Intent.StorageMode -eq 'separated') {
        if ($Target -eq 'hyperv') {
            $letters = @('T','U','V','W','X','Y','Z','Q')
            @(0..([int]$Intent.TempDbVolumeCount - 1) | ForEach-Object { "$($letters[$_]):\TempDB" })
        }
        else {
            @(1..[int]$Intent.TempDbVolumeCount | ForEach-Object { "/sqltemp$_" })
        }
    }
    elseif ($Target -eq 'hyperv') { @('C:\SQLData\TempDB') }
    else { @('/var/opt/mssql/data') }
    $roots=@($roots)
    $files=@()
    for($i=0;$i -lt [int]$Intent.TempDbFileCount;$i++){
        $name=if($i -eq 0){'tempdev.mdf'}else{"temp$($i+1).ndf"}
        $path = if ($Target -eq 'hyperv') { Join-Path $roots[$i % $roots.Count] $name } else { "$($roots[$i % $roots.Count])/$name" }
        $files += [PSCustomObject]@{path=$path;sizeMB=[int]$Intent.TempDbFileSizeMB;growth="$($Intent.TempDbGrowthMB)MB"}
    }
    $logPath = if ($Target -eq 'hyperv') { Join-Path $roots[0] 'templog.ldf' } else { "$($roots[0])/templog.ldf" }
    return [PSCustomObject]@{memory=[PSCustomObject]@{minMB=0;maxMB=[int]$Intent.SqlMaxMemoryMB};maxDop=[int]$Intent.MaxDop;costThreshold=[int]$Intent.CostThreshold;tempdb=[PSCustomObject]@{dataFiles=$files;logFile=[PSCustomObject]@{path=$logPath;sizeMB=[int]$Intent.TempDbFileSizeMB;growth="$($Intent.TempDbGrowthMB)MB"};equalSize=$true};traceFlags=@();spConfigure=[PSCustomObject]@{'optimize for ad hoc workloads'=1}}
}

function New-LabContainerDrivesFromIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Intent)
    if ($Intent.StorageMode -ne 'separated') {return @()}
    return @($Intent.Drives | ForEach-Object { $path=switch($_.Role){'sqlData'{'/sqldata'}'sqlLog'{'/sqllog'}'backup'{'/sqlbackup'}'tempdb'{"/sqltemp$(([string]$_.Id -replace '^tempdb',''))"}}; if($path -eq '/sqltemp'){$path='/sqltemp1'}; [PSCustomObject]@{id=[string]$_.Id;containerPath=$path;type='ssd';sizeLimitGB=[int]$_.SizeGB;readOnly=$false} })
}

function Invoke-LabNewEnvironmentInteractive {
    <#
    .SYNOPSIS
        Zentraler Interaktionspfad für "Neue Umgebung erstellen".
    .DESCRIPTION
        Ermittelt anhand der Ziel-Spezifikation automatisch den passenden Anbieter
        und startet direkt den SQL-Umgebungs-Workflow.
    #>
    [CmdletBinding()]
    param()

    Invoke-LabBatchComposerInteractive
}

function Invoke-LabClearAutomatedTestEnvironmentInteractive {
    <# .SYNOPSIS Entfernt ausschließlich die vollständige automatisierte Testgruppe. #>
    [CmdletBinding()]
    param()

    try { $registry = Get-LabTestEnvironmentRegistry }
    catch { Write-LabError $_.Exception.Message; return }
    $entries = @($registry.environments)
    if ($entries.Count -eq 0) { Write-LabInfo 'Keine automatisierten Testumgebungen registriert.'; return }
    Write-Host ''
    Write-Host '  Folgende geschützte Testumgebungen werden gemeinsam gelöscht:' -ForegroundColor Yellow
    foreach ($entry in $entries) {
        $runLabel = if ($entry.runId) { ([string]$entry.runId).Substring(0, [Math]::Min(8, ([string]$entry.runId).Length)) } else { 'noch nicht erstellt' }
        Write-Host "    $($entry.key) · $($entry.platform) · SQL $($entry.sqlVersion) · $($entry.patch) · $runLabel" -ForegroundColor White
    }
    if (-not (Read-LabConfirm -Prompt '  Wirklich ALLE automatisierten Testumgebungen löschen?' -Default $false)) { return }
    $result = Clear-SqlServerLabAutomatedTestEnvironment -Force -Confirm:$false
    if ([string]$result.Status -eq 'REMOVED') {
        Write-LabSuccess "Alle automatisierten Testumgebungen wurden gelöscht ($($result.Removed))."
    }
    else {
        Write-LabError "Gruppenlöschung unvollständig: $($result.Remaining) verblieben, $($result.Errors) Fehler."
    }
}

function Invoke-LabAutomatedTestEnvironmentInteractive {
    <# .SYNOPSIS Erfasst mehrere automatisierte Linux-/Windows-SQL-Testziele und erstellt den Lab_Data-Vertrag. #>
    [CmdletBinding()]
    param()

    $dataRoot = Get-LabDataRootDefault
    if (-not $dataRoot) { Write-LabError 'Für TestUmgebung.env muss zuerst unter [d] ein Data Root konfiguriert werden.'; return }
    $queue = [Collections.Generic.List[object]]::new()
    while ($true) {
        Write-Host ''
        Write-Host '  Umgebung für automatisierte Tests anlegen' -ForegroundColor Cyan
        Write-Host "  Export: $(Join-Path $dataRoot 'Exports')" -ForegroundColor DarkGray
        $existingStatus = Get-LabAutomatedTestEnvironmentStatus
        Write-Host ("  Bestehende Testgruppe: {0} · {1}/{2} bereit" -f $existingStatus.GroupStatus, $existingStatus.Ready, $existingStatus.Total) -ForegroundColor $(if ($existingStatus.GroupStatus -eq 'READY') { 'Green' } elseif ($existingStatus.GroupStatus -eq 'EMPTY') { 'DarkGray' } else { 'Yellow' })
        if ($existingStatus.Total -eq 0) { Write-Host '    Keine Testumgebung registriert.' -ForegroundColor DarkGray }
        else {
            foreach ($existing in @($existingStatus.Entries)) {
                $statusColor = if ($existing.StatusCode -eq 'READY') { 'Green' } elseif ($existing.StatusCode -in @('INSTALLING','CONFIGURATION_PENDING','INSTALL_RETRY_PENDING','PLANNED','WINDOWS_READY','OOBE_PENDING','STOPPED')) { 'Yellow' } else { 'Red' }
                Write-Host ("    {0} · {1} · SQL {2} · {3} · {4}" -f $existing.Key, $existing.Platform, $existing.SqlVersion, $existing.Patch, $existing.DisplayStatus) -ForegroundColor $statusColor
            }
        }
        Write-Host '  Neuer Auftrag:' -ForegroundColor Cyan
        if ($queue.Count -eq 0) { Write-Host '    Noch keine neue Umgebung hinzugefügt.' -ForegroundColor DarkGray }
        else {
            for ($index = 0; $index -lt $queue.Count; $index++) {
                $item = $queue[$index]
                Write-Host ("    [{0}] {1} · SQL {2} · {3} · Schlüssel {4}" -f ($index + 1), $item.Platform, $item.SqlVersion, $item.Patch, $item.Key) -ForegroundColor White
            }
        }
        Write-Host '  [l] Linux hinzufügen  [w] Windows hinzufügen  [d] letzten Eintrag entfernen' -ForegroundColor White
        Write-Host '  [a] Alle erstellen  [r] Export aktualisieren  [x] Alle Testumgebungen löschen  [0] Zurück' -ForegroundColor White
        $choice = (Read-Host '  Auswahl').ToLowerInvariant()
        if ($choice -eq '0') { return }
        if ($choice -eq 'd') { if ($queue.Count -gt 0) { $queue.RemoveAt($queue.Count - 1) }; continue }
        if ($choice -eq 'r') {
            $export = Export-SqlServerLabTestEnvironment
            Write-LabSuccess "Testumgebungsvertrag aktualisiert: $($export.EnvPath) ($($export.Ready)/$($export.Entries) bereit)"
            continue
        }
        if ($choice -eq 'x') {
            Invoke-LabClearAutomatedTestEnvironmentInteractive
            continue
        }
        if ($choice -in @('l','w')) {
            $platform = if ($choice -eq 'l') { 'linux' } else { 'windows' }
            $versions = @(Get-SqlServerVersions -Status SUPPORTED | Where-Object {
                if ($platform -eq 'linux') { $_.docker -and $_.docker.image } else { [string]$_.id -in @('2019','2022','2025') }
            } | Sort-Object { [int]$_.id })
            Write-Host "  Verfügbare SQL-Versionen: $(@($versions.id) -join ', ')" -ForegroundColor DarkGray
            $sqlVersion = Read-Host "  SQL Server Version [$($versions[-1].id)]"
            if (-not $sqlVersion) { $sqlVersion = [string]$versions[-1].id }
            if ($sqlVersion -notin @($versions.id)) { Write-LabWarning 'SQL-Version ist für diese Plattform nicht katalogisiert.'; continue }
            $patchIntent = Select-LabSqlPatchIntent -BaseVersion $sqlVersion -Platform $platform
            $requestedPatch = if ($patchIntent.Cu) { ([string]$patchIntent.Cu).ToLowerInvariant() } elseif ([string]$patchIntent.PatchMode -eq 'base') { 'base' } else { 'latest' }
            if ($platform -eq 'windows' -and -not (Confirm-LabSqlWindowsPatchMediaInteractive -Intent ([PSCustomObject]@{ Patch=$patchIntent }))) { continue }
            $baseKey = ConvertTo-LabTestEnvironmentKey -Platform $platform -SqlVersion $sqlVersion -Patch $requestedPatch
            $key = $baseKey; $suffix = 2
            while (@($queue | Where-Object Key -eq $key).Count -gt 0) { $key = "${baseKey}_$suffix"; $suffix++ }
            $queue.Add([PSCustomObject]@{
                Platform=$platform; SqlVersion=$sqlVersion; Patch=$requestedPatch; PatchIntent=$patchIntent
                Key=$key; Name=("test-{0}-{1}-{2}-{3}" -f $platform,$sqlVersion,$requestedPatch,(Get-Date -Format 'HHmmss'))
                InstanceId='primary'
            })
            continue
        }
        if ($choice -ne 'a') { Write-LabWarning 'Ungültige Auswahl.'; continue }
        if ($queue.Count -eq 0) { Write-LabWarning 'Zuerst mindestens eine Umgebung hinzufügen.'; continue }

        foreach ($request in @($queue)) {
            $intentRegistration = Register-LabTestEnvironmentIntent -Platform ([string]$request.Platform) `
                -SqlVersion ([string]$request.SqlVersion) -Patch ([string]$request.Patch) `
                -InstanceId ([string]$request.InstanceId) -Name ([string]$request.Key) `
                -ReuseExisting:([string]$request.Platform -eq 'windows')
            $request.Key = [string]$intentRegistration.key
        }
        $null = Export-SqlServerLabTestEnvironment

        foreach ($request in @($queue)) {
            try {
                if ([string]$request.Platform -eq 'linux') {
                    Write-LabInfo "Erstelle $($request.Key) vollständig automatisiert mit eigenem Zufallskennwort."
                    $creation = New-SqlServerLabAutomatedTestEnvironment -Specification @([PSCustomObject]@{
                        Platform='linux'; SqlVersion=$request.SqlVersion; Patch=$request.Patch; Name=$request.Name
                        Key=$request.Key; InstanceId=$request.InstanceId
                    })
                    if (@($creation.Errors).Count -gt 0 -or @($creation.Environments).Count -eq 0) {
                        throw "TEST_ENVIRONMENT_CREATION_FAILED: $(@($creation.Errors.Message) -join '; ')"
                    }
                    continue
                }
                Write-LabInfo "Erstelle $($request.Key) über Hyper-V. Nur Windows-OOBE und erste Anmeldung können manuell erforderlich sein."
                $before = @(Get-LabActiveRuns | ForEach-Object { [string]$_.runId })
                $intent = [PSCustomObject]@{
                    Contract='SqlServerLab.AutomatedTestIntent/1.0'; TestAutomation=$true
                    TestEnvironmentKey=$request.Key; TestEnvironmentPatch=$request.Patch
                    LabName=$request.Name; InstanceId=$request.InstanceId; BaseVersion=$request.SqlVersion
                    VersionId=[string]$request.PatchIntent.VersionId; Patch=$request.PatchIntent; Purpose='adhoc-install'
                    RequiresWindows=$true; RequiresFreshSqlInstall=$true; PreferExistingWindowsSlot=$true; Edition='Developer'; Cpu=[decimal]4; MemoryMB=4096
                    Profile='standard'; NetworkMode='host-access'; HostPort=0; Collation='SQL_Latin1_General_CP1_CI_AS'
                    SqlMaxMemoryMB=3072; MaxDop=4; CostThreshold=50; StorageMode='standard'; Drives=@()
                    TempDbFileCount=4; TempDbFileSizeMB=256; TempDbGrowthMB=64; TempDbVolumeCount=1; AutoStart='on'
                }
                Invoke-LabNewHyperVSqlEnvironmentWorkflowInteractive -Intent $intent
                $reusedRunId = if ($intent.PSObject.Properties['ReusedWindowsSlotRunId']) { [string]$intent.ReusedWindowsSlotRunId } else { $null }
                $createdRun = if ($reusedRunId) {
                    @(Get-LabActiveRuns | Where-Object { [string]$_.runId -eq $reusedRunId } | Select-Object -First 1)[0]
                }
                else {
                    @(Get-LabActiveRuns | Where-Object {
                        [string]$_.runId -notin $before -and [string]$_.metadata.name -eq [string]$request.Name
                    } | Sort-Object createdAt -Descending | Select-Object -First 1)[0]
                }
                if (-not $createdRun) { throw 'TEST_ENVIRONMENT_HYPERV_RUN_NOT_CREATED' }
                $null = Register-LabTestEnvironmentRun -RunId ([string]$createdRun.runId) -Platform windows `
                    -SqlVersion ([string]$request.SqlVersion) -Patch ([string]$request.Patch) -InstanceId ([string]$request.InstanceId) -Name ([string]$request.Key)
            }
            catch { Write-LabError "$($request.Key) konnte nicht vollständig erstellt werden: $($_.Exception.Message)" }
        }
        $export = Export-SqlServerLabTestEnvironment
        $null = Sync-LabAutomatedTestEnvironmentConnectionCenter
        Write-LabSuccess "TestUmgebung.env geschrieben: $($export.EnvPath)"
        Write-LabSuccess "Kanonischer Maschinenvertrag: $($export.JsonPath)"
        Write-LabInfo "Bereit: $($export.Ready) von $($export.Entries). Nicht bereite Hyper-V-Runs später fortsetzen und mit [e] -> [r] neu exportieren."
        return
    }
}

function Invoke-LabNewContainerEnvironmentInteractive {
    <#
    .SYNOPSIS
        Interaktiver Hyper-V-unabhängiger Container-Erstellungsfluss.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Provider, $Intent)

    if ($Intent) {
        $version = [string]$Intent.VersionId
        Write-LabInfo "Container-Image: $(Get-SqlServerDockerImage -VersionId $version)"
        $selectedSamples = @(Select-LabSampleSelection -SqlVersion $version)
        try {
            $arguments = @{
                Version=$version; Provider=$Provider; Profile=[string]$Intent.Profile; LabName=[string]$Intent.LabName
                InstanceId=[string]$Intent.InstanceId; Port=[int]$Intent.HostPort; Cpu=[decimal]$Intent.Cpu
                MemoryMB=[int]$Intent.MemoryMB; Collation=[string]$Intent.Collation
                AutoStart=if ($Intent.PSObject.Properties['AutoStart']) { [string]$Intent.AutoStart } else { 'off' }
                ServerConfig=(New-LabIntentServerConfig -Intent $Intent -Target container -ErrorAction Stop)
                Drives=@(New-LabContainerDrivesFromIntent -Intent $Intent -ErrorAction Stop)
            }
            if ($selectedSamples.Count -gt 0) { $arguments.Sample = $selectedSamples }
            $lab = New-SqlServerLab @arguments -ErrorAction Stop
            if (-not $lab -or [string]::IsNullOrWhiteSpace([string]$lab.RunId)) {
                throw 'LAB_CREATION_RESULT_INVALID: New-SqlServerLab lieferte keine RunId.'
            }
        }
        catch {
            Write-LabError "Lab-Erstellung fehlgeschlagen: $($_.Exception.Message)"
            return
        }
        Write-Host ''
        Write-LabSuccess "Lab erstellt auf $Provider. RunId: $($lab.RunId)"
        return
    }

    # Basisversion und optional einen reproduzierbar fixierten CU-Stand abfragen.
    $containerVersions = @(
        Get-SqlServerVersions -Status SUPPORTED |
            Where-Object { $_.docker -and $_.docker.image } |
            Sort-Object { [int]$_.id }
    )
    if ($containerVersions.Count -eq 0) {
        Write-LabError 'Keine unterstützte SQL-Server-Container-Version im Versionskatalog vorhanden.'
        return
    }
    $versionIds = @($containerVersions | ForEach-Object { [string]$_.id })
    $defaultVersion = $versionIds[-1]
    while ($true) {
        Write-Host ("  Verfügbare {0}-Image-Versionen: {1}" -f $Provider, ($versionIds -join ', ')) -ForegroundColor DarkGray
        $baseVersion = Read-Host "  SQL-Server-Version [$defaultVersion]"
        if (-not $baseVersion) { $baseVersion = $defaultVersion }
        if ($baseVersion -in $versionIds) { break }
        Write-LabWarning "SQL Server $baseVersion ist für $Provider nicht katalogisiert. Verfügbar: $($versionIds -join ', ')."
    }

    $builds = @(Get-SqlServerBuilds -VersionId $baseVersion | Sort-Object {
        if ([string]$_.cu -match '^CU(\d+)$') { [int]$Matches[1] } else { -1 }
    } -Descending)
    $selectedBuild = $null
    if ($builds.Count -gt 0) {
        $cuNumbers = @($builds | ForEach-Object {
            if ([string]$_.cu -match '^CU(\d+)$') { [int]$Matches[1] }
        } | Sort-Object)
        $isContiguous = $cuNumbers.Count -gt 0 -and
            $cuNumbers.Count -eq $cuNumbers[-1] -and
            (($cuNumbers -join ',') -eq ((1..$cuNumbers[-1]) -join ','))
        $cuSummary = if ($isContiguous) {
            "CU1..CU$($cuNumbers[-1])"
        }
        else {
            (@($builds.cu) -join ', ')
        }
        while ($true) {
            Write-Host "  Verfügbare CU-Stände für SQL Server ${baseVersion}: $cuSummary" -ForegroundColor DarkGray
            Write-Host '  [Enter] verwendet den veränderlichen Microsoft-Tag latest.' -ForegroundColor DarkGray
            $buildSelection = Read-Host '  CU-Stand, z. B. CU7 oder 7 [latest]'
            if (-not $buildSelection -or $buildSelection -eq 'latest') { break }
            $requestedCu = if ($buildSelection -match '^\d+$') { "CU$buildSelection" } else { $buildSelection.ToUpperInvariant() }
            $selectedBuild = $builds | Where-Object { [string]$_.cu -eq $requestedCu } | Select-Object -First 1
            if ($selectedBuild) { break }
            Write-LabWarning "CU '$buildSelection' ist für SQL Server $baseVersion nicht katalogisiert. Verfügbar: $cuSummary oder latest."
        }
    }
    $version = if ($selectedBuild) { "$baseVersion-$($selectedBuild.cu)" } else { $baseVersion }
    $containerImage = Get-SqlServerDockerImage -VersionId $version
    Write-LabInfo "Container-Image: $containerImage"

    $profile = Read-Host '  Ressourcenprofil: compact, standard, performance [standard]'
    if (-not $profile) { $profile = 'standard' }
    if ($profile -notin @('compact', 'standard', 'performance')) {
        Write-LabError "Ungültiges Ressourcenprofil: $profile"
        return
    }
    $labName = Read-Host "  Labname [adhoc-$version-$provider]"
    if (-not $labName) { $labName = "adhoc-$version-$provider" }
    $instanceId = Read-Host '  Instanzname [primary]'
    if (-not $instanceId) { $instanceId = 'primary' }

    # Testdatenbanken (optional, Mehrfachauswahl)
    $selectedSamples = @(Select-LabSampleSelection -SqlVersion $version)

    $newLabArguments = @{
        Version     = $version
        Provider    = $Provider
        Profile     = $profile
        LabName     = $labName
        InstanceId   = $instanceId
        AutoStart    = if (Read-LabConfirm -Prompt '  Instanz nach einem Host-Neustart automatisch starten?' -Default $false) { 'on' } else { 'off' }
    }
    if($Intent){$newLabArguments.Cpu=[decimal]$Intent.Cpu;$newLabArguments.MemoryMB=[int]$Intent.MemoryMB;$newLabArguments.Collation=[string]$Intent.Collation;$newLabArguments.ServerConfig=New-LabIntentServerConfig -Intent $Intent;$newLabArguments.Drives=@(New-LabContainerDrivesFromIntent -Intent $Intent)}
    $defaultDataRoot = Get-LabDataRootDefault
    if ($defaultDataRoot) {
        Write-LabInfo "Optionaler Data Root verfügbar: $defaultDataRoot"
        if (Read-LabConfirm -Prompt '  SQL-System- und Datenbanken persistent im Data Root einbinden?' -Default $false) {
            $newLabArguments.PersistentData = $true
            $newLabArguments.DataRoot = $defaultDataRoot
        }
    }
    else {
        Write-LabInfo 'Kein initialisierter Data Root gespeichert; die Containerdaten bleiben run-lokal und werden beim Cleanup entfernt.'
    }
    if ($selectedSamples.Count -gt 0) {
        $newLabArguments.Sample = $selectedSamples
    }

    try {
        $lab = New-SqlServerLab @newLabArguments -ErrorAction Stop
        if (-not $lab -or [string]::IsNullOrWhiteSpace([string]$lab.RunId)) {
            throw 'LAB_CREATION_RESULT_INVALID: New-SqlServerLab lieferte keine RunId.'
        }
    }
    catch {
        Write-LabError "Lab-Erstellung fehlgeschlagen: $($_.Exception.Message)"
        return
    }
    Write-Host ''
    Write-LabSuccess "Lab erstellt auf $Provider. RunId: $($lab.RunId)"
}

function Invoke-LabNewHyperVEnvironmentInteractive {
    <#
    .SYNOPSIS
        Startet den Hyper-V-spezifischen Bereitstellungsdialog aus dem Hauptmenü.
    #>
    [CmdletBinding()]
    param($Intent)

    $availability = Test-HyperVAvailable
    if (-not $availability.Available) {
        Write-LabError "Hyper-V ist aktuell nicht verfügbar: $($availability.Message)"
        return
    }

    if($Intent){New-LabHyperVEnvironmentInteractive -WindowsOnly -Intent $Intent;return}
    Write-Host "  Bereitstellungsziel:" -ForegroundColor DarkGray
    Write-Host '    [1] Sofortige SQL-Umgebung aus SQL-Prepared-Image' -ForegroundColor White
    Write-Host '    [2] Windows-OS-Slot für spätere Anpassung/Installation' -ForegroundColor DarkGray
    $mode = Read-Host '  Modus [1]'

    if (-not $mode) { $mode = '1' }
    switch ($mode) {
        '1' {
            Invoke-LabNewHyperVSqlEnvironmentWorkflowInteractive
        }
        '2' {
            New-LabHyperVEnvironmentInteractive -WindowsOnly
        }
        default {
            Write-LabError "Ungültige Auswahl: $mode"
        }
    }
}

function Invoke-LabNewHyperVSqlEnvironmentWorkflowInteractive {
    <#
    .SYNOPSIS
        Führt den interaktiven Hyper-V-SQL-Pfad bis zum nächsten ausführbaren Schritt.
    .DESCRIPTION
        Verwendet eine vorhandene SQL-Vorlage direkt. Fehlt sie, wird aus einer
        OS-Vorlage ein manueller Windows-Slot begonnen. Fehlt auch die OS-Vorlage,
        wird ein vorhandener OS-Builder fortgesetzt oder ein neuer aus DVD erzeugt.
        Dieser Fallback ist bewusst nur interaktiv; Manifeste bleiben fail-closed.
    #>
    [CmdletBinding()]
    param($Intent)

    $artifacts = @(Get-HyperVImageArtifact -SkipIntegrityCheck)
    $sqlArtifacts = @($artifacts | Where-Object { [string]$_.artifactState -eq 'SQL_PREPARED_SEALED' })
    if ($Intent -and $Intent.RequiresFreshSqlInstall) { $sqlArtifacts = @() }
    if ($sqlArtifacts.Count -gt 0) {
        New-LabHyperVEnvironmentInteractive -SqlOnly -Intent $Intent
        Write-LabInfo 'Kapazitätshinweis: Für besondere SQL-Konfigurationen kann zusätzlich ein Windows-OS-Slot aus der OS-Vorlage vorbereitet werden.'
        return
    }

    Write-LabWarning 'Keine veröffentlichte SQL-Prepared-Vorlage vorhanden. Der interaktive Workflow wechselt auf den Windows-OS-Pfad.'
    $reusableSlot = if ($Intent -and $Intent.PSObject.Properties['ForceNewWindowsSlot'] -and $Intent.ForceNewWindowsSlot) {
        $null
    }
    else {
        $automaticSlotSelection = [bool]($Intent -and $Intent.PSObject.Properties['PreferExistingWindowsSlot'] -and $Intent.PreferExistingWindowsSlot)
        Select-LabReusableHyperVWindowsSlotInteractive -Intent $Intent -Automatic:$automaticSlotSelection
    }
    if ($reusableSlot) {
        if ($Intent) { $Intent | Add-Member -NotePropertyName ReusedWindowsSlotRunId -NotePropertyValue ([string]$reusableSlot.RunId) -Force }
        if ($Intent -and $Intent.TestAutomation) {
            $null = Register-LabTestEnvironmentRun -RunId ([string]$reusableSlot.RunId) -Platform windows `
                -SqlVersion ([string]$Intent.BaseVersion) -Patch ([string]$Intent.TestEnvironmentPatch) `
                -InstanceId ([string]$Intent.InstanceId) -Name ([string]$Intent.TestEnvironmentKey)
        }
        Invoke-LabReusableHyperVWindowsSlotInteractive -Slot $reusableSlot -Intent $Intent
        return
    }
    $osArtifacts = @($artifacts | Where-Object {
        [string]$_.artifactState -eq 'OS_SEALED' -and
        [string]$_.operatingSystem.id -match '^windows-(server-)?[0-9]+$'
    })

    if ($osArtifacts.Count -eq 0) {
        Write-LabWarning 'Auch keine veröffentlichte Windows-OS-Vorlage vorhanden.'
        Write-Host '  Notwendiger Ablauf:' -ForegroundColor Yellow
        Write-Host '    1. Windows-OS-Vorlage aus DVD erstellen und veröffentlichen.' -ForegroundColor White
        Write-Host '    2. Daraus einen Windows-Slot für diese SQL-Umgebung erzeugen.' -ForegroundColor White
        Write-Host '    3. OOBE abschließen; danach übernimmt das Framework Netzwerk und SQL-Ausbau.' -ForegroundColor White

        $openBuilds = @(Get-HyperVImageBuildPlans | Where-Object {
            [string]$_.state -notin @('OS_SEALED', 'TEST_ARTIFACT_PUBLISHED', 'FAILED', 'CLEANED_UP')
        })
        if ($openBuilds.Count -gt 0) {
            Write-LabInfo "Ein offener Windows-OS-Builder ist vorhanden ($($openBuilds.Count)); dieser wird statt eines doppelten Builds fortgesetzt."
            if (Read-LabConfirm -Prompt '  Windows-OS-Vorlagen-Workflow jetzt fortsetzen?' -Default $true) {
                Invoke-LabHyperVWindowsBaselineMenu
            }
        }
        elseif (Read-LabConfirm -Prompt '  Windows-OS-Vorlage jetzt aus DVD beginnen?' -Default $true) {
            New-LabHyperVImageBuildInteractive
        }

        $osArtifacts = @(Get-HyperVImageArtifact -SkipIntegrityCheck | Where-Object {
            [string]$_.artifactState -eq 'OS_SEALED' -and
            [string]$_.operatingSystem.id -match '^windows-(server-)?[0-9]+$'
        })
        if ($osArtifacts.Count -eq 0) {
            Write-LabInfo 'Die OS-Vorlage benötigt noch die angezeigten manuellen Windows-Schritte.'
            Write-LabInfo 'Danach erneut [1] „Neue Umgebung erstellen“ wählen; der Workflow setzt automatisch beim Windows-Slot fort.'
            return
        }
        Write-LabSuccess 'Windows-OS-Vorlage ist jetzt verfügbar; der SQL-Umgebungsworkflow wird fortgesetzt.'
    }

    Write-LabInfo 'Eine Windows-OS-Vorlage ist verfügbar. Daraus wird jetzt der Betriebssystem-Slot für die gewünschte SQL-Umgebung angelegt.'
    Write-LabInfo 'SQL Server wird erst nach der manuellen OOBE installiert; es erfolgt kein zusätzlicher Sysprep-Lauf.'
    New-LabHyperVEnvironmentInteractive -WindowsOnly -ContinueSqlWorkflow -Intent $Intent
}

function Invoke-LabHyperVImageAction {
    [CmdletBinding()]
    param()

    if (-not (Test-LabAdministrator)) {
        try {
            $elevation = Start-LabElevatedAction -Action Image
            if ($elevation.Started) {
                Write-LabInfo 'Hyper-V-Aktion wird in einem erhoehten PowerShell-Fenster fortgesetzt.'
            }
            return $elevation
        }
        catch {
            Write-LabError "Hyper-V-Aktion benoetigt Administratorrechte: $($_.Exception.Message)"
        }
        return
    }

    $availability = Test-HyperVAvailable
    if (-not $availability.Available) {
        $installCapability = Test-LabHyperVInstallCapability
        if ($installCapability.Supported) {
            Write-LabWarning "Hyper-V ist noch nicht bereit: $($availability.Message)"
            Write-Host '  Die Installation umfasst Hyper-V-Plattform, PowerShell-Modul und Verwaltungstools; ein Neustart kann erforderlich sein.' -ForegroundColor DarkGray
            if (Read-LabConfirm -Prompt '  Fehlende Hyper-V-Komponenten jetzt installieren?' -Default $false) {
                try {
                    $install = Install-LabHyperVPrerequisites
                    if (-not $install.Succeeded) { Write-LabError 'Die Hyper-V-Installation wurde nicht erfolgreich abgeschlossen.'; return }
                    if ($install.RestartRequired) {
                        Write-LabWarning 'Hyper-V wurde installiert. Windows jetzt neu starten und danach den Image-Menuepunkt erneut waehlen.'
                        return
                    }
                    $availability = Test-HyperVAvailable
                }
                catch { Write-LabError "Hyper-V-Installation fehlgeschlagen: $($_.Exception.Message)"; return }
            }
        }
    }
    if (-not $availability.Available) {
        Write-LabError "Hyper-V nicht verfuegbar: $($availability.Message)"
        return
    }

    $exitImageMenu = $false
    while (-not $exitImageMenu) {
        $items = @(
            New-LabConsoleItem -Id '1' -Label 'Windows-OS-Vorlage aus DVD erstellen oder fortsetzen' -Shortcut '1' -Value 'Standardpfad'
            New-LabConsoleItem -Id '2' -Label 'Betriebssystem-Slot aus Windows-OS-Vorlage erstellen' -Shortcut '2'
            New-LabConsoleItem -Id '3' -Label 'Neue SQL-Prepared-Vorlage aus DVD erstellen' -Shortcut '3' -Value 'optional'
            New-LabConsoleItem -Id 's' -Label 'Offenen SQL-Prepared-Builder fortsetzen' -Shortcut 's'
            New-LabConsoleItem -Id '4' -Label 'Betriebssystem- und SQL-Slots verwalten' -Shortcut '4'
            New-LabConsoleItem -Id '5' -Label 'Veröffentlichte Vorlagen verwalten oder gezielt löschen' -Shortcut '5'
            New-LabConsoleItem -Id 'e' -Label 'Erweitert: OS-Baselines, Abnahme und Reparatur' -Shortcut 'e'
            New-LabConsoleItem -Id '0' -Label 'Zurueck' -Shortcut '0'
        )
        $menuResult = Invoke-LabConsoleMenu -ScreenId 'hyperv-images' -Title 'Hyper-V' -Subtitle 'Windows-Vorlage -> Betriebssystem-Slot -> optionaler SQL-Ausbau' -Items $items
        if ($menuResult.Status -eq 'Cancelled') { $exitImageMenu = $true; continue }
        if ($menuResult.Status -ne 'Selected') { continue }
        $choice = [string]$menuResult.SelectedItem.Id
        switch ($choice) {
            '0' { $exitImageMenu = $true }
            '1' { Invoke-LabHyperVWindowsBaselineMenu }
            '2' { Invoke-LabHyperVMenuAction -Title 'Betriebssystem-Slot aus Windows-OS-Vorlage' -Action { New-LabHyperVEnvironmentInteractive -WindowsOnly } }
            '3' { Invoke-LabHyperVMenuAction -Title 'Neue SQL-Prepared-Vorlage' -Action { New-LabHyperVSqlImageBuildInteractive } }
            's' { Invoke-LabHyperVPreparedImageWorkflowMenu }
            '4' { Invoke-LabHyperVMenuAction -Title 'Betriebssystem- und SQL-Slots verwalten' -Action { Manage-LabHyperVEnvironmentInteractive } }
            '5' { Invoke-LabHyperVPublishedImageMenu }
            'e' { Invoke-LabHyperVAdvancedMenu }
            default { Write-LabWarning "Ungueltige Auswahl: $choice" }
        }
    }
}

function Show-LabHyperVMenuActionHeader {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title)

    Clear-Host
    Write-Host ''
    Write-Host "  Hyper-V – $Title" -ForegroundColor Cyan
    Write-Host '  ---------------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host ''
}

function Invoke-LabHyperVMenuAction {
    <#
    .SYNOPSIS
        Führt eine Hyper-V-Menüaktion sichtbar aus und kehrt erst nach Enter
        zu einem anschließend bereinigten Menü zurück.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    Show-LabHyperVMenuActionHeader -Title $Title
    & $Action
    $null = Read-Host '  [Enter] für Menü ...'
}

function Invoke-LabHyperVPreparedImageWorkflowMenu {
    [CmdletBinding()]
    param()

    $exitMenu = $false
    while (-not $exitMenu) {
        $items = @(
            New-LabConsoleItem -Id '1' -Label 'Builder starten und VMConnect öffnen' -Shortcut '1'
            New-LabConsoleItem -Id '2' -Label 'Windows-Installation bestätigen und automatisch fertigstellen' -Shortcut '2'
            New-LabConsoleItem -Id '3' -Label 'Automatischen Abschluss fortsetzen' -Shortcut '3' -Value 'nur nach Unterbrechung'
            New-LabConsoleItem -Id '4' -Label 'Prepared-Image manuell veröffentlichen' -Shortcut '4' -Value 'nur Diagnose'
            New-LabConsoleItem -Id '5' -Label 'Builder-Status anzeigen' -Shortcut '5'
            New-LabConsoleItem -Id 'r' -Label 'Sysprep offline prüfen und Wiederaufnahme versuchen' -Shortcut 'r'
            New-LabConsoleItem -Id 'c' -Label 'Unfertigen Builder aufräumen' -Shortcut 'c'
            New-LabConsoleItem -Id '0' -Label 'Zurück' -Shortcut '0'
        )
        $menuResult = Invoke-LabConsoleMenu -ScreenId 'hyperv-prepared-workflow' -Title 'Prepared-Image-Builder fortsetzen' -Subtitle 'Nach Windows-Installation laufen PrepareImage, Neustarts, Sysprep und Veröffentlichung automatisch.' -Items $items
        if ($menuResult.Status -eq 'Cancelled') { $exitMenu = $true; continue }
        if ($menuResult.Status -ne 'Selected') { continue }
        $choice = [string]$menuResult.SelectedItem.Id
        switch ($choice) {
            '0' { $exitMenu = $true }
            '1' { Invoke-LabHyperVMenuAction -Title 'Builder starten' -Action { Start-LabHyperVSqlImageBuildInteractive } }
            '2' { Invoke-LabHyperVMenuAction -Title 'Windows bestätigen und automatisch fertigstellen' -Action { Confirm-LabHyperVSqlWindowsInstallationInteractive } }
            '3' { Invoke-LabHyperVMenuAction -Title 'Automatischen Abschluss fortsetzen' -Action { Invoke-LabHyperVSqlPrepareInteractive } }
            '4' { Invoke-LabHyperVMenuAction -Title 'Prepared-Image manuell veröffentlichen' -Action { Publish-LabHyperVSqlImageBuildInteractive } }
            '5' { Invoke-LabHyperVMenuAction -Title 'Builder-Status' -Action { $null = Show-LabHyperVSqlImageBuilds } }
            'r' { Invoke-LabHyperVMenuAction -Title 'Sysprep-Recovery' -Action { Resume-LabHyperVSqlPreparedImageGeneralizationInteractive } }
            'c' { Invoke-LabHyperVMenuAction -Title 'Unfertigen Builder aufräumen' -Action { Remove-LabHyperVSqlImageBuildInteractive } }
            default { Write-LabWarning "Ungueltige Auswahl: $choice" }
        }
    }
}

function Invoke-LabHyperVPublishedImageMenu {
    [CmdletBinding()]
    param()

    $exitMenu = $false
    while (-not $exitMenu) {
        $items = @(
            New-LabConsoleItem -Id '1' -Label 'Namen ändern' -Shortcut '1'
            New-LabConsoleItem -Id '2' -Label 'Vorlage gezielt löschen' -Shortcut '2'
            New-LabConsoleItem -Id '0' -Label 'Zurück' -Shortcut '0'
        )
        $menuResult = Invoke-LabConsoleMenu -ScreenId 'hyperv-published-images' -Title 'Veröffentlichte Vorlagen verwalten' -Items $items
        if ($menuResult.Status -eq 'Cancelled') { $exitMenu = $true; continue }
        if ($menuResult.Status -ne 'Selected') { continue }
        $choice = [string]$menuResult.SelectedItem.Id
        switch ($choice) {
            '0' { $exitMenu = $true }
            '1' { Invoke-LabHyperVMenuAction -Title 'Image-Namen ändern' -Action { Rename-LabHyperVImageArtifactInteractive } }
            '2' { Invoke-LabHyperVMenuAction -Title 'Image löschen' -Action { Remove-LabHyperVImageArtifactInteractive } }
            default { Write-LabWarning "Ungueltige Auswahl: $choice" }
        }
    }
}

function Invoke-LabHyperVAdvancedMenu {
    [CmdletBinding()]
    param()

    $exitMenu = $false
    while (-not $exitMenu) {
        $items = @(
            New-LabConsoleItem -Id '1' -Label 'Windows-OS-Baselines verwalten' -Shortcut '1' -Value 'Expertenpfad'
            New-LabConsoleItem -Id '2' -Label 'SQL-Builder aus einer OS-Baseline erstellen' -Shortcut '2' -Value 'Expertenpfad'
            New-LabConsoleItem -Id '3' -Label 'Run-lokale Windows-/SQL-Abnahmeumgebung' -Shortcut '3'
            New-LabConsoleItem -Id '4' -Label 'Sysprep offline prüfen und Wiederaufnahme versuchen' -Shortcut '4'
            New-LabConsoleItem -Id '5' -Label 'Neue Umgebung aus vorhandener ausgeschalteter Windows-VM' -Shortcut '5'
            New-LabConsoleItem -Id '0' -Label 'Zurück' -Shortcut '0'
        )
        $menuResult = Invoke-LabConsoleMenu -ScreenId 'hyperv-advanced' -Title 'Hyper-V - Erweitert / Reparatur' -Items $items
        if ($menuResult.Status -eq 'Cancelled') { $exitMenu = $true; continue }
        if ($menuResult.Status -ne 'Selected') { continue }
        $choice = [string]$menuResult.SelectedItem.Id
        switch ($choice) {
            '0' { $exitMenu = $true }
            '1' { Invoke-LabHyperVWindowsBaselineMenu }
            '2' { Invoke-LabHyperVMenuAction -Title 'SQL-Builder aus OS-Baseline' -Action { New-LabHyperVSqlAcceptanceBuildInteractive } }
            '3' { Invoke-LabHyperVSqlAcceptanceMenu }
            '4' { Invoke-LabHyperVMenuAction -Title 'Sysprep-Recovery' -Action { Resume-LabHyperVSqlPreparedImageGeneralizationInteractive } }
            '5' { Invoke-LabHyperVMenuAction -Title 'Neue Umgebung aus vorhandener Windows-VM' -Action { New-LabHyperVEnvironmentFromExistingVmInteractive } }
            default { Write-LabWarning "Ungueltige Auswahl: $choice" }
        }
    }
}

function Invoke-LabHyperVWindowsBaselineMenu {
    [CmdletBinding()]
    param()

    $exitMenu = $false
    while (-not $exitMenu) {
        $items = @(
            New-LabConsoleItem -Id '1' -Label 'Windows-Builder aus Media Root vorbereiten' -Shortcut '1'
            New-LabConsoleItem -Id '2' -Label 'Windows-Build-Status anzeigen' -Shortcut '2'
            New-LabConsoleItem -Id '3' -Label 'Windows-Builder starten und VMConnect öffnen' -Shortcut '3'
            New-LabConsoleItem -Id '4' -Label 'Installiertes Windows generalisieren' -Shortcut '4'
            New-LabConsoleItem -Id '5' -Label 'Windows-Image veröffentlichen' -Shortcut '5'
            New-LabConsoleItem -Id '6' -Label 'Unfertigen Windows-Builder aufräumen' -Shortcut '6'
            New-LabConsoleItem -Id '0' -Label 'Zurück' -Shortcut '0'
        )
        $menuResult = Invoke-LabConsoleMenu -ScreenId 'hyperv-windows-baselines' -Title 'Windows-OS-Baselines - Expertenpfad' -Items $items
        if ($menuResult.Status -eq 'Cancelled') { $exitMenu = $true; continue }
        if ($menuResult.Status -ne 'Selected') { continue }
        $choice = [string]$menuResult.SelectedItem.Id
        switch ($choice) {
            '0' { $exitMenu = $true }
            '1' { Invoke-LabHyperVMenuAction -Title 'Windows-Builder vorbereiten' -Action { New-LabHyperVImageBuildInteractive } }
            '2' { Invoke-LabHyperVMenuAction -Title 'Windows-Build-Status' -Action { $null = Show-LabHyperVImageBuilds } }
            '3' { Invoke-LabHyperVMenuAction -Title 'Windows-Builder starten' -Action { Start-LabHyperVImageBuildInteractive } }
            '4' { Invoke-LabHyperVMenuAction -Title 'Windows generalisieren' -Action { Invoke-LabHyperVImageGeneralizationInteractive } }
            '5' { Invoke-LabHyperVMenuAction -Title 'Windows-Image veröffentlichen' -Action { Publish-LabHyperVImageBuildInteractive } }
            '6' { Invoke-LabHyperVMenuAction -Title 'Windows-Builder aufräumen' -Action { Remove-LabHyperVImageBuildInteractive } }
            default { Write-LabWarning "Ungueltige Auswahl: $choice" }
        }
    }
}

function Invoke-LabHyperVSqlAcceptanceMenu {
    [CmdletBinding()]
    param()

    $exitMenu = $false
    while (-not $exitMenu) {
        $items = @(
            New-LabConsoleItem -Id '1' -Label 'OOBE und vollständiges SQL automatisch installieren' -Shortcut '1'
            New-LabConsoleItem -Id '2' -Label 'SQL-Abnahmetest ausführen' -Shortcut '2'
            New-LabConsoleItem -Id '3' -Label 'SQL-2019/2022/2025-Abnahmematrix anzeigen' -Shortcut '3'
            New-LabConsoleItem -Id '4' -Label 'Manuell abgeschlossene OOBE übernehmen und vollständiges SQL installieren' -Shortcut '4'
            New-LabConsoleItem -Id '0' -Label 'Zurück' -Shortcut '0'
        )
        $menuResult = Invoke-LabConsoleMenu -ScreenId 'hyperv-sql-acceptance' -Title 'Run-lokale Windows-/SQL-Abnahmeumgebung' -Subtitle 'Vollständige Testinstanz; kein Prepared-Image-Pfad.' -Items $items
        if ($menuResult.Status -eq 'Cancelled') { $exitMenu = $true; continue }
        if ($menuResult.Status -ne 'Selected') { continue }
        $choice = [string]$menuResult.SelectedItem.Id
        switch ($choice) {
            '0' { $exitMenu = $true }
            '1' { Invoke-LabHyperVMenuAction -Title 'OOBE und SQL-Setup' -Action { Invoke-LabHyperVSqlAcceptanceInstallInteractive } }
            '2' { Invoke-LabHyperVMenuAction -Title 'SQL-Abnahmetest' -Action { Test-LabHyperVSqlAcceptanceInteractive } }
            '3' { Invoke-LabHyperVMenuAction -Title 'SQL-Abnahmematrix' -Action { Show-LabHyperVSqlAcceptanceMatrix } }
            '4' { Invoke-LabHyperVMenuAction -Title 'Manuelle OOBE übernehmen' -Action { Invoke-LabHyperVSqlManualOobeAcceptanceInstallInteractive } }
            default { Write-LabWarning "Ungueltige Auswahl: $choice" }
        }
    }
}

function Show-LabHyperVImageBuilds {
    [CmdletBinding()]
    param()

    $builds = @(Get-HyperVImageBuildPlans)
    if ($builds.Count -eq 0) {
        Write-LabInfo 'Keine Hyper-V-Image-Builds vorhanden.'
        return @()
    }

    Write-Host ''
    Write-Host '  Image-Builds:' -ForegroundColor White
    for ($i = 0; $i -lt $builds.Count; $i++) {
        $build = $builds[$i]
        $vmName = if ($build.builder -and $build.builder.vmName) { [string]$build.builder.vmName } else { '-' }
        Write-Host ("    [{0}] {1}  {2}" -f ($i + 1), $build.buildId, $build.state) -ForegroundColor White
        Write-Host ("        OS: {0} | Edition: {1} | Typ: {2} | VM: {3}" -f `
            $build.operatingSystem.id, $build.operatingSystem.edition, $build.operatingSystem.installationType, $vmName) -ForegroundColor DarkGray
    }
    return $builds
}

function Select-LabHyperVImageBuild {
    [CmdletBinding()]
    param([string[]]$AllowedStates = @())

    $builds = @(Get-HyperVImageBuildPlans)
    if ($AllowedStates.Count -gt 0) {
        $builds = @($builds | Where-Object { $_.state -in $AllowedStates })
    }
    if ($builds.Count -eq 0) {
        Write-LabInfo 'Kein passender Image-Build vorhanden.'
        return $null
    }
    if ($builds.Count -eq 1) {
        Write-LabInfo "Build: $($builds[0].buildId) [$($builds[0].state)]"
        return $builds[0]
    }

    Write-Host ''
    for ($i = 0; $i -lt $builds.Count; $i++) {
        Write-Host "    [$($i + 1)] $($builds[$i].buildId) [$($builds[$i].state)]" -ForegroundColor White
    }
    $selection = Read-Host '  Build (Nummer)'
    if ($selection -notmatch '^\d+$') {
        Write-LabWarning 'Ungueltige Auswahl.'
        return $null
    }
    $index = [int]$selection - 1
    if ($index -lt 0 -or $index -ge $builds.Count) {
        Write-LabWarning 'Ungueltige Auswahl.'
        return $null
    }
    return $builds[$index]
}

function New-LabHyperVImageBuildInteractive {
    [CmdletBinding()]
    param()

    $defaultRoot = Get-LabMediaRootDefault
    $rootPrompt = if ($defaultRoot) { "  Media Root [$defaultRoot]" } else { '  Media Root' }
    $mediaRoot = Read-Host $rootPrompt
    if (-not $mediaRoot) { $mediaRoot = $defaultRoot }
    if (-not $mediaRoot) {
        Write-LabError 'Media Root ist erforderlich.'
        return
    }
    try { $mediaRoot = Set-LabMediaRootDefault -MediaRoot $mediaRoot }
    catch { Write-LabError "Media Root ist ungueltig: $($_.Exception.Message)"; return }

    $candidates = @(Get-HyperVWindowsInstallationMediaCandidates -MediaRoot $mediaRoot | Where-Object { $_.State -eq 'READY' })
    if ($candidates.Count -eq 0) {
        Write-LabError 'Kein erkennbares Windows-Installationsmedium im Media Root gefunden.'
        return
    }
    Write-Host '  Erkannte Windows-Installationsmedien:' -ForegroundColor White
    Write-LabWindowsMediaSelectionGroups -Candidates $candidates -Numbered
    $selection = Read-Host '  Windows-Installationsmedium (Nummer) [1]'
    if (-not $selection) { $selection = '1' }
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $candidates.Count) {
        Write-LabError 'Ungültige Medienauswahl.'
        return
    }
    $selectedMedia = $candidates[[int]$selection - 1]
    $operatingSystemId = [string]$selectedMedia.OperatingSystemId
    $edition = [string]$selectedMedia.WindowsEdition
    $installationType = [string]$selectedMedia.InstallationType
    $windowsMediaPath = [string]$selectedMedia.MediaId

    try {
        $media = Resolve-HyperVWindowsInstallationMedia `
            -MediaRoot $mediaRoot `
            -OperatingSystemId $operatingSystemId -WindowsEdition $edition -InstallationType $installationType -WindowsMediaPath $windowsMediaPath
        if ($media.HashStatus -eq 'MISSING') {
            Write-LabWarning 'Fuer die ISO existiert noch kein SHA-256-Sidecar.'
            Write-Host "  ISO: $($media.IsoPath)" -ForegroundColor DarkGray
            if (-not (Read-LabConfirm -Prompt '  SHA-256 jetzt berechnen und lokal festschreiben?' -Default $false)) {
                Write-LabInfo 'Ohne SHA-256 wurde kein Build angelegt.'
                return
            }
            Write-LabInfo 'SHA-256 wird berechnet; grosse ISOs benoetigen mehrere Minuten.'
            $media = New-HyperVWindowsMediaHashSidecar `
                -MediaRoot $mediaRoot `
                -OperatingSystemId $operatingSystemId -WindowsEdition $edition -InstallationType $installationType -WindowsMediaPath $windowsMediaPath
        }

        Write-Host ''
        Write-Host "  ISO:       $($media.IsoPath)" -ForegroundColor DarkGray
        Write-Host "  SHA-256:   $($media.ExpectedSha256)" -ForegroundColor DarkGray
        Write-Host "  Ziel:      $operatingSystemId / $edition / $installationType" -ForegroundColor DarkGray
        Write-Host '  Ressourcen: 80 GB dynamische OS-VHDX, 4 GB RAM, 4 vCPU' -ForegroundColor DarkGray
        if (-not (Read-LabConfirm -Prompt '  Resumierbaren Hyper-V-Builder jetzt erzeugen?' -Default $false)) {
            return
        }

        $build = Initialize-HyperVWindowsImageBuild `
            -MediaRoot $mediaRoot `
            -OperatingSystemId $operatingSystemId `
            -Edition $edition `
            -InstallationType $installationType `
            -WindowsMediaPath $windowsMediaPath `
            -LicenseType (Get-HyperVWindowsMediaLicenseType -WindowsEdition $edition)
        Write-LabSuccess "Builder erstellt. BuildId: $($build.buildId)"
        Show-LabHyperVManualInstallInstructions -Build $build

        if (Read-LabConfirm -Prompt '  Builder starten und VMConnect oeffnen?' -Default $true) {
            Open-LabHyperVImageBuildConsole -Build $build
            Start-Sleep -Milliseconds 1500
            $null = Start-HyperVWindowsImageBuildVM -BuildId $build.buildId
        }
    }
    catch {
        Write-LabError $_.Exception.Message
    }
}

function Show-LabHyperVManualInstallInstructions {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Build)

    Write-Host ''
    Write-Host '  Manuelle Windows-Installation:' -ForegroundColor Yellow
    Write-Host "    1. VM '$($Build.builder.vmName)' in VMConnect oeffnen." -ForegroundColor White
    Write-Host "    2. $($Build.operatingSystem.edition) mit '$($Build.operatingSystem.installationType)' auswaehlen." -ForegroundColor White
    Write-Host '    3. Benutzerdefinierte Installation auf die einzige leere OS-Disk ausfuehren.' -ForegroundColor White
    Write-Host '    4. Ein lokales Administrator-Passwort setzen und sicher verwahren.' -ForegroundColor White
    Write-Host '    5. Nach dem ersten vollstaendigen Login zum Image-Menue zurueckkehren.' -ForegroundColor White
    Write-Host '  Der Builder besitzt absichtlich keinen Netzwerkadapter.' -ForegroundColor DarkGray
}

function Open-LabHyperVImageBuildConsole {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Build)

    $vmConnect = Join-Path $env:SystemRoot 'System32/vmconnect.exe'
    if (-not (Test-Path -LiteralPath $vmConnect -PathType Leaf)) {
        Write-LabWarning "VMConnect nicht gefunden. Manuell verbinden mit VM: $($Build.builder.vmName)"
        return
    }
    Start-Process -FilePath $vmConnect `
        -ArgumentList @($env:COMPUTERNAME, [string]$Build.builder.vmName)
}

function Start-LabHyperVImageBuildInteractive {
    [CmdletBinding()]
    param()

    $build = Select-LabHyperVImageBuild -AllowedStates @('BUILDER_READY', 'MANUAL_ACTION_REQUIRED')
    if (-not $build) { return }
    try {
        Show-LabHyperVManualInstallInstructions -Build $build
        Open-LabHyperVImageBuildConsole -Build $build
        Start-Sleep -Milliseconds 1500
        $null = Start-HyperVWindowsImageBuildVM -BuildId $build.buildId
    }
    catch { Write-LabError $_.Exception.Message }
}

function Invoke-LabHyperVImageGeneralizationInteractive {
    [CmdletBinding()]
    param()

    $build = Select-LabHyperVImageBuild -AllowedStates @('MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED')
    if (-not $build) { return }
    $credential = $null
    if ($build.state -eq 'MANUAL_ACTION_REQUIRED') {
        $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
        if (-not $userName) { $userName = 'Administrator' }
        $password = Read-Host '  Gastpasswort' -AsSecureString
        $credential = [PSCredential]::new($userName, $password)
        try {
            $build = Confirm-HyperVWindowsImageInstallation `
                -BuildId $build.buildId `
                -Credential $credential
        }
        catch {
            if ($_.Exception.Message -notmatch '^HYPERV_IMAGE_INSTALLATION_TYPE_MISMATCH:') {
                Write-LabError $_.Exception.Message
                return
            }
            Write-LabWarning $_.Exception.Message
            if (-not (Read-LabConfirm -Prompt '  Erkannten Installationstyp fuer diesen Build uebernehmen?' -Default $false)) {
                return
            }
            try {
                $build = Confirm-HyperVWindowsImageInstallation `
                    -BuildId $build.buildId `
                    -Credential $credential `
                    -AcceptDetectedInstallationType
            }
            catch {
                Write-LabError $_.Exception.Message
                return
            }
        }
        Write-LabSuccess ("Windows verifiziert: {0}, {1}, Build {2}" -f `
            $build.installationEvidence.editionId,
            $build.installationEvidence.installationType,
            $build.installationEvidence.currentBuild)
    }
    if (-not (Read-LabConfirm -Prompt '  Sysprep /generalize ausfuehren und Gast herunterfahren?' -Default $false)) {
        return
    }
    try {
        $result = Invoke-HyperVWindowsImageGeneralization `
            -BuildId $build.buildId `
            -Credential $credential
        Write-LabSuccess "Generalisierung verifiziert. State: $($result.state)"
    }
    catch { Write-LabError $_.Exception.Message }
}

function Publish-LabHyperVImageBuildInteractive {
    [CmdletBinding()]
    param()

    $build = Select-LabHyperVImageBuild -AllowedStates @('RESUME_PENDING')
    if (-not $build) { return }
    $expiry = $null
    if ($build.license.type -eq 'evaluation') {
        $defaultExpiry = (Get-Date).Date.AddDays(180).ToString('yyyy-MM-dd')
        $expiryInput = Read-Host "  Evaluation endet am [$defaultExpiry]"
        if (-not $expiryInput) { $expiryInput = $defaultExpiry }
        $parsedExpiry = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($expiryInput, 'yyyy-MM-dd', $null, 'AssumeLocal', [ref]$parsedExpiry)) {
            Write-LabError 'Datum muss YYYY-MM-DD entsprechen.'
            return
        }
        $expiry = $parsedExpiry
    }
    if (-not (Read-LabConfirm -Prompt '  Generalisierte VHDX immutable in der Registry veroeffentlichen?' -Default $false)) {
        return
    }
    try {
        $result = Publish-HyperVWindowsImageBuild `
            -BuildId $build.buildId `
            -EvaluationExpiresAt $expiry
        Write-LabSuccess "Image veroeffentlicht. ArtifactId: $($result.Artifact.artifactId)"
    }
    catch { Write-LabError $_.Exception.Message }
}

function Remove-LabHyperVImageBuildInteractive {
    [CmdletBinding()]
    param()

    $allowedStates = @(
        'MEDIA_VERIFIED', 'BUILDER_READY', 'MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED', 'RESUME_PENDING', 'FAILED'
    )
    $builds = @(Get-HyperVImageBuildPlans | Where-Object state -In $allowedStates)
    if ($builds.Count -eq 0) { Write-LabInfo 'Kein unfertiger Windows-Image-Builder vorhanden.'; return }

    Write-Host ''
    for ($i = 0; $i -lt $builds.Count; $i++) {
        Write-Host "    [$($i + 1)] Windows [$($builds[$i].state)] $($builds[$i].buildId)" -ForegroundColor White
    }
    Write-Host "    [ALL] Alle $($builds.Count) angezeigten unfertigen Windows-Builder aufraeumen" -ForegroundColor Yellow
    $selection = Read-Host '  Build (Nummer oder ALL)'
    if ($selection -ieq 'ALL') {
        Write-LabWarning "Alle $($builds.Count) angezeigten Builder inklusive VMs und buildlokaler VHDX werden entfernt."
        if (-not (Read-LabConfirm -Prompt '  WIRKLICH ALLE Windows-Builder aufraeumen?' -Default $false)) { return }
        $succeeded = 0; $failed = 0
        foreach ($candidate in $builds) {
            Write-LabInfo "Cleanup $($succeeded + $failed + 1)/$($builds.Count): $($candidate.buildId)"
            try {
                $result = Remove-HyperVWindowsImageBuild -BuildId $candidate.buildId
                if ($result.Status -eq 'CLEANUP_SUCCEEDED') { $succeeded++ }
                else { $failed++; Write-LabError "$($candidate.buildId): Cleanup-Status $($result.Status)" }
            }
            catch { $failed++; Write-LabError "$($candidate.buildId): $($_.Exception.Message)" }
        }
        if ($failed -eq 0) { Write-LabSuccess "Alle $succeeded Windows-Builder-Ressourcen wurden entfernt." }
        else { Write-LabWarning "Cleanup abgeschlossen: $succeeded erfolgreich, $failed fehlgeschlagen." }
        return
    }
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $builds.Count) {
        Write-LabWarning 'Ungueltige Auswahl.'; return
    }
    $build = $builds[[int]$selection - 1]
    Write-LabWarning "VM und buildlokale VHDX von '$($build.buildId)' werden entfernt."
    if (-not (Read-LabConfirm -Prompt '  Builder wirklich aufraeumen?' -Default $false)) { return }
    try {
        $result = Remove-HyperVWindowsImageBuild -BuildId $build.buildId
        if ($result.Status -eq 'CLEANUP_SUCCEEDED') {
            Write-LabSuccess 'Builder-Ressourcen wurden entfernt und aus der offenen Liste ausgeblendet.'
        }
        else {
            Write-LabError "Cleanup-Status: $($result.Status)"
        }
    }
    catch { Write-LabError $_.Exception.Message }
}

function Show-LabHyperVSqlImageBuilds {
    [CmdletBinding()]
    param()

    $builds = @(Get-HyperVSqlImageBuildPlans)
    if ($builds.Count -eq 0) {
        Write-LabInfo 'Keine Hyper-V-SQL-Image-Builds vorhanden.'
        return @()
    }
    Write-Host ''
    Write-Host '  SQL-Image-Builds:' -ForegroundColor White
    for ($i = 0; $i -lt $builds.Count; $i++) {
        $build = $builds[$i]
        $vmName = if ($build.builder) { [string]$build.builder.vmName } else { '-' }
        Write-Host ("    [{0}] {1}  {2}" -f ($i + 1), $build.buildId, $build.state) -ForegroundColor White
        Write-Host ("        SQL {0} {1} | VM: {2} | Parent: {3}" -f `
            $build.sql.version, $build.sql.edition, $vmName, $build.parentArtifact.artifactId) -ForegroundColor DarkGray
        Write-Host ("        Naechster Schritt: {0}" -f (Get-LabHyperVSqlImageNextStep -Build $build)) -ForegroundColor Yellow
    }
    return $builds
}

function Get-LabHyperVSqlImageNextStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Build)

    $isFreshPreparedImage = [string]$Build.provisioningMode -eq 'fresh-windows-media'
    switch ([string]$Build.state) {
        'MANUAL_ACTION_REQUIRED' {
            if ($isFreshPreparedImage) { return 'Prepared-Image-Builder fortsetzen: VMConnect öffnen, Windows installieren und einmal als Administrator anmelden.' }
            return 'Prepared-Image-Builder fortsetzen: VMConnect öffnen, OOBE der OS-Baseline abschließen und danach SQL PrepareImage ausführen.'
        }
        'OOBE_AUTOMATION_RUNNING' { return 'Erweitert -> Abnahmeumgebung öffnen und den OOBE-Fortschritt fortsetzen.' }
        'OOBE_COMPLETED' { return 'Erweitert -> Abnahmeumgebung: vollständiges SQL installieren.' }
        'REBOOT_REQUIRED' { return 'Automatischen Abschluss fortsetzen; der von SQL angeforderte Neustart wird geprüft und der Ablauf fortgesetzt.' }
        'RESUME_PENDING' { return 'Automatischen Abschluss fortsetzen; das Prepared-Image wird veröffentlicht.' }
        'SQL_INSTALL_RUNNING' { return 'Erweitert -> Abnahmeumgebung erneut aufrufen; der Installationsfortschritt wird fortgesetzt.' }
        'SQL_INSTALL_REBOOT_REQUIRED' { return 'Erweitert -> Abnahmeumgebung: VM booten und SQL-Setup fortsetzen.' }
        'SQL_READY_RUN' { return 'Erweitert -> Abnahmeumgebung: SQL-Abnahmetest ausführen.' }
        'TESTS_PASSED' { return 'Fertig. Bei Bedarf den run-lokalen Abnahme-Builder aufräumen.' }
        'SQL_PREPARED_SEALED' { return 'Fertig. Das immutable Prepared-Image wurde veroeffentlicht.' }
        'FAILED' { return 'Fehler prüfen; nach fehlgeschlagenem Sysprep im Prepared-Image-Builder die Offline-Recovery wählen, andernfalls aufräumen.' }
        default { return 'Builder-Status prüfen oder den zuletzt ausgegebenen Hinweis befolgen.' }
    }
}

function Show-LabHyperVSqlNextActions {
    [CmdletBinding()]
    param()

    $builds = @(Get-HyperVSqlImageBuildPlans | Where-Object {
        [string]$_.state -notin @('SQL_PREPARED_SEALED', 'TESTS_PASSED')
    })
    if ($builds.Count -eq 0) { return }
    Write-Host ''
    Write-Host '    Offene SQL-Builder – naechster Schritt:' -ForegroundColor Cyan
    foreach ($build in $builds) {
        $shortId = ([string]$build.buildId).Substring(0, 8)
        Write-Host ("      SQL {0} ({1}...): {2}" -f $build.sql.version, $shortId, (Get-LabHyperVSqlImageNextStep -Build $build)) -ForegroundColor Yellow
    }
}

function Format-LabMenuDateTime {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return '-' }
    $parsed = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)) {
        return [string]$Value
    }
    return $parsed.ToLocalTime().ToString(
        'yyyy-MM-dd HH:mm:ss',
        [Globalization.CultureInfo]::InvariantCulture)
}

function Select-LabHyperVSqlImageBuild {
    [CmdletBinding()]
    param(
        [string[]]$AllowedStates = @(),
        [switch]$RequireExistingVm
    )

    $builds = @(Get-HyperVSqlImageBuildPlans)
    if ($AllowedStates.Count -gt 0) { $builds = @($builds | Where-Object state -In $AllowedStates) }
    if ($RequireExistingVm) {
        $availableBuilds = [System.Collections.Generic.List[object]]::new()
        foreach ($candidate in $builds) {
            if (-not $candidate.builder -or -not [string]$candidate.builder.vmName) { continue }
            try {
                $managed = Get-HyperVManagedVM -VMName ([string]$candidate.builder.vmName) `
                    -ExpectedRunId ([string]$candidate.buildId) -ExpectedScopeId ([string]$candidate.scopeId)
                if ($managed) { $availableBuilds.Add($candidate) }
            }
            catch { }
        }
        $builds = @($availableBuilds)
    }
    if ($builds.Count -eq 0) { Write-LabInfo 'Kein passender SQL-Image-Build vorhanden.'; return $null }
    if ($builds.Count -eq 1) { return $builds[0] }
    Write-Host ''
    for ($i = 0; $i -lt $builds.Count; $i++) {
        $candidate = $builds[$i]
        $imageName = if ([string]::IsNullOrWhiteSpace([string]$candidate.displayName)) { '(ohne Image-Name)' } else { [string]$candidate.displayName }
        $vmName = if ($candidate.builder -and $candidate.builder.vmName) { [string]$candidate.builder.vmName } else { '-' }
        $vmState = '-'
        if ($vmName -ne '-') {
            try { $vmState = [string](Get-VM -Name $vmName -ErrorAction Stop).State } catch { $vmState = 'nicht gefunden' }
        }
        $createdAt = if ($candidate.manualAction -and $candidate.manualAction.requestedAt) {
            [string]$candidate.manualAction.requestedAt
        }
        elseif ($candidate.stateHistory -and @($candidate.stateHistory).Count -gt 0) {
            [string]@($candidate.stateHistory)[0].timestamp
        }
        else { '-' }
        $createdAt = Format-LabMenuDateTime -Value $createdAt
        Write-Host ("    [{0}] {1} | SQL {2} {3} | {4}" -f `
            ($i + 1), $imageName, $candidate.sql.version, $candidate.sql.edition, $candidate.state) -ForegroundColor White
        Write-Host ("        VM: {0} [{1}] | Windows: {2} / {3}" -f `
            $vmName, $vmState, $candidate.operatingSystem.edition, $candidate.operatingSystem.installationType) -ForegroundColor DarkGray
        Write-Host ("        Erstellt: {0} | BuildId: {1}" -f $createdAt, $candidate.buildId) -ForegroundColor DarkGray
    }
    $selection = Read-Host '  Build (Nummer)'
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $builds.Count) {
        Write-LabWarning 'Ungueltige Auswahl.'; return $null
    }
    return $builds[[int]$selection - 1]
}

function Rename-LabHyperVImageArtifactInteractive {
    [CmdletBinding()]
    param()

    # Die Auswahl darf nicht jede große Parent-VHDX erneut hashen. Die
    # referenzgeprüfte Entfernung validiert Besitz und Ziel anschließend
    # selbst; für die Anzeige reicht die lokale Registry.
    $artifacts = @(Get-HyperVImageArtifact -SkipIntegrityCheck | Where-Object { $_.artifactState -in @('OS_SEALED', 'SQL_PREPARED_SEALED') })
    if ($artifacts.Count -eq 0) {
        Write-LabInfo 'Keine veröffentlichten OS- oder SQL-Images vorhanden.'
        return
    }
    Write-Host '  Veröffentlichte Images:' -ForegroundColor White
    for ($i = 0; $i -lt $artifacts.Count; $i++) {
        $artifact = $artifacts[$i]
        $fallback = if ($artifact.artifactState -eq 'SQL_PREPARED_SEALED') {
            "SQL Server $($artifact.sql.version) · $($artifact.sql.edition)"
        } else {
            "$($artifact.operatingSystem.id) · $($artifact.operatingSystem.edition)"
        }
        $name = if ($artifact.displayName) { [string]$artifact.displayName } else { $fallback }
        Write-Host ("    [{0}] {1}" -f ($i + 1), $name) -ForegroundColor White
        Write-Host ("        {0}" -f $artifact.artifactId) -ForegroundColor DarkGray
    }
    $selection = Read-Host '  Image (Nummer)'
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $artifacts.Count) {
        Write-LabWarning 'Keine gültige Image-Auswahl.'
        return
    }
    $newName = Read-Host '  Neuer Anzeigename'
    if ([string]::IsNullOrWhiteSpace($newName)) { Write-LabWarning 'Ein Name ist erforderlich.'; return }
    if ($newName.Trim().Length -gt 80) { Write-LabWarning 'Der Name darf höchstens 80 Zeichen enthalten.'; return }
    try {
        $renamed = Rename-HyperVImageArtifact -ArtifactId $artifacts[[int]$selection - 1].artifactId -DisplayName $newName
        Write-LabSuccess "Image-Name gespeichert: $($renamed.displayName)"
    }
    catch { Write-LabError $_.Exception.Message }
}

function Remove-LabHyperVImageArtifactInteractive {
    <#
    .SYNOPSIS Entfernt ein veröffentlichtes Hyper-V-Image nach expliziter Auswahl.
    .DESCRIPTION Die Registry verweigert die Entfernung weiterhin, solange ein
    aktiver Builder oder Lab-Run das immutable Parent-Image referenziert.
    #>
    [CmdletBinding()]
    param()

    # Die Auswahl darf nicht jede große Parent-VHDX erneut hashen. Die
    # referenzgeprüfte Entfernung validiert Besitz und Ziel anschließend
    # selbst; für die Anzeige reicht die lokale Registry.
    $artifacts = @(Get-HyperVImageArtifact -SkipIntegrityCheck | Where-Object { $_.artifactState -in @('OS_SEALED', 'SQL_PREPARED_SEALED') })
    if ($artifacts.Count -eq 0) {
        Write-LabInfo 'Keine veröffentlichten OS- oder SQL-Images vorhanden.'
        return
    }
    Write-Host '  Veröffentlichte Images:' -ForegroundColor White
    for ($i = 0; $i -lt $artifacts.Count; $i++) {
        $artifact = $artifacts[$i]
        $operatingSystemLabel = Get-LabWindowsMediaOperatingSystemLabel -OperatingSystemId ([string]$artifact.operatingSystem.id)
        $isSqlPrepared = [string]$artifact.artifactState -eq 'SQL_PREPARED_SEALED'
        $fallbackName = if ($isSqlPrepared) {
            "{0} · SQL Server {1} {2}" -f $operatingSystemLabel, $artifact.sql.version, $artifact.sql.edition
        }
        else { "{0} · reine Windows-OS-Baseline" -f $operatingSystemLabel }
        $displayName = if ([string]::IsNullOrWhiteSpace([string]$artifact.displayName)) { $fallbackName } else { [string]$artifact.displayName }
        $shortArtifactId = if ([string]$artifact.artifactId -match '([a-f0-9]{12,})$') { $Matches[1].Substring(0, 12) } else { [string]$artifact.artifactId }
        $registeredAt = if ([string]::IsNullOrWhiteSpace([string]$artifact.registeredAt)) { 'unbekannt' } else { Format-LabMenuDateTime -Value $artifact.registeredAt }
        $workload = if ($isSqlPrepared) {
            "Windows: {0} {1} · SQL Server: {2} {3}" -f $operatingSystemLabel, $artifact.operatingSystem.installationType, $artifact.sql.version, $artifact.sql.edition
        }
        else { "Windows: {0} {1} · Reine Windows-VM ohne SQL Server" -f $operatingSystemLabel, $artifact.operatingSystem.installationType }
        Write-Host ("    [{0}] {1}" -f ($i + 1), $displayName) -ForegroundColor White
        Write-Host ("        {0}" -f $workload) -ForegroundColor Gray
        Write-Host ("        Veröffentlicht: {0} · Kennung: {1}" -f $registeredAt, $shortArtifactId) -ForegroundColor DarkGray
    }
    Write-Host '    [ALL] Alle oben angezeigten Images löschen' -ForegroundColor Red
    $selection = Read-Host '  Image auswählen'
    if ([string]::IsNullOrWhiteSpace($selection)) { return }
    $selected = if ($selection -ieq 'ALL') { @($artifacts) }
    elseif ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $artifacts.Count) { @($artifacts[[int]$selection - 1]) }
    else { Write-LabWarning 'Ungültige Auswahl.'; return }

    $countText = if ($selected.Count -eq 1) { 'dieses Image' } else { "alle $($selected.Count) Images" }
    Write-LabWarning "Es werden $countText inklusive ihrer schreibgeschützten Parent-VHDX entfernt. Referenzierte Images werden sicher übersprungen."
    if (-not (Read-LabConfirm -Prompt '  Wirklich löschen?' -Default $false)) { return }
    $removed = 0; $blocked = 0
    foreach ($artifact in $selected) {
        try {
            Remove-HyperVImageArtifact -ArtifactId ([string]$artifact.artifactId) | Out-Null
            $removed++
            Write-LabSuccess "Image entfernt: $($artifact.artifactId)"
        }
        catch {
            $blocked++
            Write-LabWarning "Image nicht entfernt: $($artifact.artifactId) – $($_.Exception.Message)"
        }
    }
    if ($blocked -eq 0) { Write-LabSuccess "$removed Image(s) entfernt." }
    else { Write-LabWarning "Löschen abgeschlossen: $removed entfernt, $blocked nicht entfernt." }
}

function Select-LabHyperVOsArtifact {
    [CmdletBinding()]
    param()

    $artifacts = @(Get-HyperVImageArtifact -SkipIntegrityCheck | Where-Object {
        $_.artifactState -eq 'OS_SEALED' -and [string]$_.operatingSystem.id -match '^windows-(server-)?[0-9]+$'
    })
    if ($artifacts.Count -eq 0) { Write-LabError 'Keine veröffentlichte Windows-OS-Baseline vorhanden.'; return $null }
    if ($artifacts.Count -eq 1) { return $artifacts[0] }
    Write-Host ''
    for ($i = 0; $i -lt $artifacts.Count; $i++) {
        $operatingSystemLabel = Get-LabWindowsMediaOperatingSystemLabel -OperatingSystemId ([string]$artifacts[$i].operatingSystem.id)
        Write-Host "    [$($i + 1)] $operatingSystemLabel / $($artifacts[$i].operatingSystem.edition) / $($artifacts[$i].operatingSystem.installationType)" -ForegroundColor White
        Write-Host "        $($artifacts[$i].artifactId)" -ForegroundColor DarkGray
    }
    $selection = Read-Host '  OS-Baseline (Nummer)'
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $artifacts.Count) {
        Write-LabWarning 'Ungueltige Auswahl.'; return $null
    }
    return $artifacts[[int]$selection - 1]
}

function Show-LabHyperVSqlManualInstructions {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Build)

    Write-Host ''
    if ([string]$Build.provisioningMode -eq 'fresh-windows-media') {
        Write-Host '  Frische Windows-Installation fuer das SQL-Prepared-Image:' -ForegroundColor Yellow
        Write-Host "    VM: $($Build.builder.vmName)" -ForegroundColor White
        $operatingSystemLabel = Get-LabWindowsMediaOperatingSystemLabel -OperatingSystemId ([string]$Build.operatingSystem.id)
        Write-Host "    1. $operatingSystemLabel in VMConnect auf der leeren OS-Disk installieren." -ForegroundColor White
        $editionBase = ([string]$Build.operatingSystem.edition -replace '-evaluation$', '')
        $editionLabel = "$operatingSystemLabel $((Get-Culture).TextInfo.ToTitleCase(($editionBase -replace '-', ' ')))"
        if ([string]$Build.license.type -eq 'evaluation') { $editionLabel += ' Evaluation' }
        $typeLabel = if ([string]$Build.operatingSystem.installationType -eq 'core') { 'Server Core Installation' } else { 'Desktop Experience' }
        Write-Host "    2. Im Windows-Setup exakt '$editionLabel ($typeLabel)' auswählen und OOBE abschließen." -ForegroundColor White
    Write-Host '    3. Lokales Administratorpasswort setzen und einmal anmelden.' -ForegroundColor White
    Write-Host '       Bleibt VMConnect nach einem Setup-Reboot schwarz: Fenster schliessen und erneut verbinden; keinen Reset ausloesen.' -ForegroundColor DarkGray
    Write-Host '    4. Im Untermenü „Prepared-Image-Builder fortsetzen“ „Windows-Installation bestätigen und automatisch fertigstellen“ wählen.' -ForegroundColor White
        Write-Host '  Die zweite DVD enthält bereits die verifizierte SQL-ISO; sie wird von diesem Schritt verwendet.' -ForegroundColor DarkGray
        return
    }
    Write-Host '  SQL-Prepared-Image aus OS-Baseline:' -ForegroundColor Yellow
    Write-Host "    VM: $($Build.builder.vmName)" -ForegroundColor White
    Write-Host '    1. VMConnect öffnen, die kurze OOBE der OS-Baseline abschließen und lokales Administratorpasswort setzen.' -ForegroundColor White
    Write-Host '    2. Im Untermenü „Prepared-Image-Builder fortsetzen“ „Windows-Installation bestätigen und automatisch fertigstellen“ wählen.' -ForegroundColor White
    Write-Host '  Windows wird nicht erneut installiert: Die OS-Baseline bleibt unverändert, der Builder verwendet nur eine eigene differenzierende VHDX.' -ForegroundColor DarkGray
}

function Select-LabSqlInstallationMedia {
    <#
    .SYNOPSIS
        Wählt ein tatsächlich vorhandenes SQL-Installationsmedium aus dem Media Root.
    .DESCRIPTION
        Die Auswahl leitet Version und Medienedition direkt aus dem Pfad der ISO
        ab. Damit funktionieren auch Developer-, Enterprise_Developer- und
        Standard_Developer-Ordner, ohne dass der Benutzer einen künstlichen
        Verzeichnisnamen eingeben muss.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [string]$SqlVersion,
        [ValidateSet('Enterprise','Standard')][string]$MediaEdition
    )

    $sqlRoot = Join-Path $MediaRoot 'SQL'
    if (-not (Test-Path -LiteralPath $sqlRoot -PathType Container)) {
        Write-LabError "SQL-Medienverzeichnis nicht gefunden: $sqlRoot"
        return $null
    }

    $choices = @(
        Get-ChildItem -LiteralPath $sqlRoot -File -Recurse -Filter '*.iso' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $mediaId = [IO.Path]::GetRelativePath($MediaRoot, $_.FullName).Replace('\', '/')
                if ($mediaId -notmatch '^SQL/(?<version>\d{4})/') { return }
                $edition = Get-HyperVSqlMediaEditionFromPath -Path $mediaId
                if (-not $edition) { return }
                [PSCustomObject]@{
                    SqlVersion = $Matches.version
                    MediaEdition = $edition
                    MediaId = $mediaId
                    FileName = $_.Name
                }
            } |
            Sort-Object @{ Expression = { [int]$_.SqlVersion }; Descending = $true }, MediaEdition, FileName
    )
    if ($choices.Count -eq 0) {
        Write-LabError "Keine SQL-ISOs unter $sqlRoot gefunden. Erwartet werden z. B. SQL/2025/Enterprise_Developer/ISO/*.iso."
        return $null
    }

    $versions = @($choices.SqlVersion | Select-Object -Unique | Sort-Object { [int]$_ } -Descending)
    $defaultVersion = $versions[0]
    Write-Host "  Verfügbare SQL Server Versionen: $($versions -join ', ')" -ForegroundColor White
    if (-not $SqlVersion) { $SqlVersion = Read-Host "  SQL Server Version [$defaultVersion]" }
    if (-not $SqlVersion) { $SqlVersion = $defaultVersion }
    if ($SqlVersion -notin $versions) {
        Write-LabError "SQL-Version ist nicht als ISO verfügbar: $SqlVersion"
        return $null
    }

    $versionChoices = @($choices | Where-Object SqlVersion -eq $SqlVersion)
    if ($MediaEdition) { $versionChoices = @($versionChoices | Where-Object MediaEdition -eq $MediaEdition) }
    if ($versionChoices.Count -eq 0) { Write-LabError "Kein SQL-$SqlVersion-Medium für Edition $MediaEdition verfügbar."; return $null }
    if ($versionChoices.Count -eq 1) {
        Write-LabInfo "SQL-Medium automatisch gewählt: $($versionChoices[0].MediaId)"
        return $versionChoices[0]
    }
    Write-Host '  Verfügbare SQL-Installationsmedien:' -ForegroundColor White
    for ($i = 0; $i -lt $versionChoices.Count; $i++) {
        $choice = $versionChoices[$i]
        $mediaSegments = @([string]$choice.MediaId -split '/')
        $mediaLabel = if ($mediaSegments.Count -ge 3) { $mediaSegments[2].Replace('_', ' ') } else { [string]$choice.MediaEdition }
        Write-Host ("    [{0}] {1} · {2}" -f ($i + 1), $mediaLabel, $choice.MediaId) -ForegroundColor White
    }
    $selection = Read-Host '  SQL-Installationsmedium (Nummer) [1]'
    if (-not $selection) { $selection = '1' }
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $versionChoices.Count) {
        Write-LabError 'Ungültige SQL-Medienauswahl.'
        return $null
    }
    return $versionChoices[[int]$selection - 1]
}

function New-LabHyperVSqlImageBuildInteractive {
    [CmdletBinding()]
    param()

    $defaultRoot = Get-LabMediaRootDefault
    $mediaRoot = Read-Host $(if ($defaultRoot) { "  Media Root [$defaultRoot]" } else { '  Media Root' })
    if (-not $mediaRoot) { $mediaRoot = $defaultRoot }
    if (-not $mediaRoot) { Write-LabError 'Media Root ist erforderlich.'; return }
    try { $mediaRoot = Set-LabMediaRootDefault -MediaRoot $mediaRoot }
    catch { Write-LabError "Media Root ist ungueltig: $($_.Exception.Message)"; return }

    $allWindowsMedia = @(Get-HyperVWindowsInstallationMediaCandidates -MediaRoot $mediaRoot)
    $allWindowsCandidates = @($allWindowsMedia | Where-Object { $_.State -eq 'READY' })
    $windowsCandidates = @($allWindowsCandidates | Where-Object { (Test-HyperVSqlPreparedWindowsMediaCompatibility -OperatingSystemId ([string]$_.OperatingSystemId)).Compatible })
    if ($windowsCandidates.Count -eq 0) { Write-LabError 'Kein erkanntes Windows-Installationsmedium vorhanden.'; return }
    Write-Host '  Erkannte Windows-Installationsvarianten:' -ForegroundColor White
    Write-LabWindowsMediaSelectionGroups -Candidates $windowsCandidates -Numbered
    $unrecognizedWindowsMedia = @($allWindowsMedia | Where-Object { $_.State -ne 'READY' })
    if ($unrecognizedWindowsMedia.Count -gt 0) {
        Write-Host '  Nicht auswertbare Windows-Medien (werden nicht verwendet):' -ForegroundColor Yellow
        foreach ($candidate in $unrecognizedWindowsMedia) {
            Write-Host ("    - {0}: {1}" -f $candidate.MediaId, $candidate.Message) -ForegroundColor Yellow
        }
    }
    $windowsSelection = Read-Host '  Windows-Variante (Nummer) [1]'
    if (-not $windowsSelection) { $windowsSelection = '1' }
    if ($windowsSelection -notmatch '^\d+$' -or [int]$windowsSelection -lt 1 -or [int]$windowsSelection -gt $windowsCandidates.Count) { Write-LabError 'Ungültige Windows-Medienauswahl.'; return }
    $selectedWindowsMedia = $windowsCandidates[[int]$windowsSelection - 1]
    $operatingSystemId = [string]$selectedWindowsMedia.OperatingSystemId
    $windowsEdition = [string]$selectedWindowsMedia.WindowsEdition
    $installationType = [string]$selectedWindowsMedia.InstallationType
    $windowsMediaPath = [string]$selectedWindowsMedia.MediaId
    $selectedSqlMedia = Select-LabSqlInstallationMedia -MediaRoot $mediaRoot
    if (-not $selectedSqlMedia) { return }
    $sqlVersion = [string]$selectedSqlMedia.SqlVersion
    $mediaEdition = [string]$selectedSqlMedia.MediaEdition
    $sqlMediaPath = [string]$selectedSqlMedia.MediaId
    $imageName = Read-Host '  Frei wählbarer Image-Name (optional)'
    if ($imageName -and $imageName.Trim().Length -gt 80) { Write-LabError 'Der Image-Name darf höchstens 80 Zeichen enthalten.'; return }

    try {
        $windowsMedia = Resolve-HyperVWindowsInstallationMedia -MediaRoot $mediaRoot -OperatingSystemId $operatingSystemId -WindowsMediaPath $windowsMediaPath -WindowsEdition $windowsEdition -InstallationType $installationType
        if ($windowsMedia.HashStatus -eq 'MISSING') {
            Write-LabWarning 'Fuer die Windows-ISO existiert noch kein SHA-256-Sidecar.'
            if (-not (Read-LabConfirm -Prompt '  Windows-SHA-256 jetzt berechnen und lokal festschreiben?' -Default $false)) { return }
            Write-LabInfo 'Windows-SHA-256 wird berechnet; grosse ISOs benoetigen mehrere Minuten.'
            $windowsMedia = New-HyperVWindowsMediaHashSidecar -MediaRoot $mediaRoot -OperatingSystemId $operatingSystemId -WindowsMediaPath $windowsMediaPath -WindowsEdition $windowsEdition -InstallationType $installationType
        }
        $sqlMedia = Resolve-HyperVSqlInstallationMedia -MediaRoot $mediaRoot -SqlVersion $sqlVersion -MediaEdition $mediaEdition -SqlMediaPath $sqlMediaPath
        if ($sqlMedia.HashStatus -eq 'MISSING') {
            Write-LabWarning 'Fuer die SQL-ISO existiert noch kein SHA-256-Sidecar.'
            if (-not (Read-LabConfirm -Prompt '  SQL-SHA-256 jetzt berechnen und lokal festschreiben?' -Default $false)) { return }
            Write-LabInfo 'SQL-SHA-256 wird berechnet; grosse ISOs benoetigen mehrere Minuten.'
            $sqlMedia = New-HyperVSqlMediaHashSidecar -MediaRoot $mediaRoot -SqlVersion $sqlVersion -MediaEdition $mediaEdition -SqlMediaPath $sqlMediaPath
        }
        Write-Host ''
        $windowsLicenseType = Get-HyperVWindowsMediaLicenseType -WindowsEdition $windowsEdition
        $operatingSystemLabel = Get-LabWindowsMediaOperatingSystemLabel -OperatingSystemId $operatingSystemId
        Write-Host "  Windows: $operatingSystemLabel / $windowsEdition / $installationType / $windowsLicenseType" -ForegroundColor DarkGray
        Write-Host "  SQL:     $sqlVersion $mediaEdition; SQLENGINE, FULLTEXT, REPLICATION" -ForegroundColor DarkGray
        Write-Host '  Ablauf: Windows installieren -> SQL PrepareImage -> ein finaler Sysprep.' -ForegroundColor Yellow
        if ($operatingSystemId -ne 'windows-server-2025') {
            Write-LabWarning "Die Kombination $operatingSystemLabel / SQL Server $sqlVersion wird auf Ihre Entscheidung gebaut; Installation und Sysprep liefern bei echter Inkompatibilität die konkrete Diagnose."
        }
        if (-not (Read-LabConfirm -Prompt '  Frischen SQL-Prepared-Image-Builder jetzt erzeugen?' -Default $false)) { return }
        $buildArguments = @{
            MediaRoot = $mediaRoot
            OperatingSystemId = $operatingSystemId
            WindowsEdition = $windowsEdition
            InstallationType = $installationType
            WindowsMediaPath = $windowsMediaPath
            SqlVersion = $sqlVersion
            MediaEdition = $mediaEdition
            SqlMediaPath = $sqlMediaPath
        }
        if (-not [string]::IsNullOrWhiteSpace($imageName)) {
            $buildArguments.ImageName = $imageName.Trim()
        }
        $build = Initialize-HyperVSqlFreshPreparedImageBuild @buildArguments
        Write-LabSuccess "Frischer SQL-Builder erstellt. BuildId: $($build.buildId)"
        Show-LabHyperVSqlManualInstructions -Build $build
        if (Read-LabConfirm -Prompt '  Builder starten und VMConnect oeffnen?' -Default $true) {
            Open-LabHyperVImageBuildConsole -Build $build
            Start-Sleep -Milliseconds 1500
            $null = Start-HyperVSqlImageBuildVM -BuildId $build.buildId
        }
    }
    catch { Write-LabError $_.Exception.Message }
}

function New-LabHyperVSqlAcceptanceBuildInteractive {
    [CmdletBinding()]
    param()

    $defaultRoot = Get-LabMediaRootDefault
    $mediaRoot = Read-Host $(if ($defaultRoot) { "  Media Root [$defaultRoot]" } else { '  Media Root' })
    if (-not $mediaRoot) { $mediaRoot = $defaultRoot }
    if (-not $mediaRoot) { Write-LabError 'Media Root ist erforderlich.'; return }
    try { $mediaRoot = Set-LabMediaRootDefault -MediaRoot $mediaRoot }
    catch { Write-LabError "Media Root ist ungueltig: $($_.Exception.Message)"; return }
    $selectedSqlMedia = Select-LabSqlInstallationMedia -MediaRoot $mediaRoot
    if (-not $selectedSqlMedia) { return }
    $sqlVersion = [string]$selectedSqlMedia.SqlVersion
    $mediaEdition = [string]$selectedSqlMedia.MediaEdition
    $sqlMediaPath = [string]$selectedSqlMedia.MediaId
    $artifact = Select-LabHyperVOsArtifact
    if (-not $artifact) { return }
    $imageName = Read-Host '  Frei wählbarer Image-Name (optional)'
    if ($imageName -and $imageName.Trim().Length -gt 80) { Write-LabError 'Der Image-Name darf höchstens 80 Zeichen enthalten.'; return }

    try {
        $media = Resolve-HyperVSqlInstallationMedia -MediaRoot $mediaRoot -SqlVersion $sqlVersion -MediaEdition $mediaEdition -SqlMediaPath $sqlMediaPath
        if ($media.HashStatus -eq 'MISSING') {
            Write-LabWarning 'Fuer die SQL-ISO existiert noch kein SHA-256-Sidecar.'
            Write-Host "  ISO: $($media.IsoPath)" -ForegroundColor DarkGray
            if (-not (Read-LabConfirm -Prompt '  SHA-256 jetzt berechnen und lokal festschreiben?' -Default $false)) { return }
            $media = New-HyperVSqlMediaHashSidecar -MediaRoot $mediaRoot -SqlVersion $sqlVersion -MediaEdition $mediaEdition -SqlMediaPath $sqlMediaPath
        }
        Write-Host "  Parent: $($artifact.artifactId)" -ForegroundColor DarkGray
        Write-Host "  SQL:    $sqlVersion $mediaEdition; SQLENGINE, FULLTEXT, REPLICATION" -ForegroundColor DarkGray
        Write-Host '  Die OS-Baseline bleibt unverändert; Windows wird nicht erneut installiert.' -ForegroundColor DarkGray
        Write-Host '  Die Evaluation-Ablaufzeit der OS-Baseline wird in das neue Artifact übernommen.' -ForegroundColor DarkGray
        if (-not (Read-LabConfirm -Prompt '  SQL-Prepared-Image-Builder aus OS-Baseline jetzt erzeugen?' -Default $false)) { return }
        $build = Initialize-HyperVSqlPreparedImageBuild -MediaRoot $mediaRoot -ImageArtifactId $artifact.artifactId `
            -SqlVersion $sqlVersion -MediaEdition $mediaEdition -SqlMediaPath $sqlMediaPath -ImageName $imageName
        Write-LabSuccess "SQL-Prepared-Image-Builder aus OS-Baseline erstellt. BuildId: $($build.buildId)"
        Show-LabHyperVSqlManualInstructions -Build $build
        if (Read-LabConfirm -Prompt '  Builder starten und VMConnect oeffnen?' -Default $true) {
            Open-LabHyperVImageBuildConsole -Build $build
            Start-Sleep -Milliseconds 1500
            $null = Start-HyperVSqlImageBuildVM -BuildId $build.buildId
        }
    }
    catch { Write-LabError $_.Exception.Message }
}

function Start-LabHyperVSqlImageBuildInteractive {
    [CmdletBinding()]
    param()
    $build = Select-LabHyperVSqlImageBuild -AllowedStates @('MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED') -RequireExistingVm
    if (-not $build) { return }
    Show-LabHyperVSqlManualInstructions -Build $build
    Open-LabHyperVImageBuildConsole -Build $build
    Start-Sleep -Milliseconds 1500
    try { $null = Start-HyperVSqlImageBuildVM -BuildId $build.buildId } catch { Write-LabError $_.Exception.Message }
}

function Confirm-LabHyperVSqlWindowsInstallationInteractive {
    [CmdletBinding()]
    param()

    $build = Select-LabHyperVSqlImageBuild -AllowedStates @('MANUAL_ACTION_REQUIRED') -RequireExistingVm
    if (-not $build) { return }
    $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
    if (-not $userName) { $userName = 'Administrator' }
    $password = Read-Host '  Gastpasswort' -AsSecureString
    $credential = [PSCredential]::new($userName, $password)
    try {
        $confirmed = if ([string]$build.provisioningMode -eq 'fresh-windows-media') {
            Confirm-HyperVSqlFreshWindowsInstallation -Build $build -Credential $credential
        }
        else {
            Write-LabInfo 'Die veröffentlichte OS-Baseline wurde bereits geprüft; der automatische SQL-Abschluss wird gestartet.'
            $build
        }
        Write-LabSuccess ("Windows bereit: {0} / {1}. SQL PrepareImage, Neustarts, Sysprep und Veröffentlichung starten jetzt automatisch." -f $confirmed.operatingSystem.edition, $confirmed.operatingSystem.installationType)
        $result = Complete-HyperVSqlPreparedImageBuild -BuildId $confirmed.buildId -Credential $credential
        Write-LabSuccess "SQL-Prepared-Image automatisch veröffentlicht: $($result.Artifact.artifactId)"
    }
    catch { Write-LabError $_.Exception.Message }
}

function Invoke-LabHyperVSqlPrepareInteractive {
    [CmdletBinding()]
    param()
    $build = Select-LabHyperVSqlImageBuild -AllowedStates @('MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED') -RequireExistingVm
    if (-not $build) { return }
    Write-Host ''
    Write-Host ("  Ziel-Builder: SQL {0} {1} | VM: {2}" -f $build.sql.version, $build.sql.edition, $build.builder.vmName) -ForegroundColor Yellow
    Write-Host ("  Build-ID: {0}" -f $build.buildId) -ForegroundColor DarkGray
    $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
    if (-not $userName) { $userName = 'Administrator' }
    $password = Read-Host '  Gastpasswort' -AsSecureString
    $credential = [PSCredential]::new($userName, $password)
    try {
        Write-LabInfo 'Automatischer Abschluss wird wiederaufgenommen: SQL PrepareImage, erforderliche Neustarts, Sysprep und Veröffentlichung.'
        $result = Complete-HyperVSqlPreparedImageBuild -BuildId $build.buildId -Credential $credential
        Write-LabSuccess "SQL-Prepared-Image automatisch veröffentlicht: $($result.Artifact.artifactId)"
    }
    catch {
        Write-LabError $_.Exception.Message
        if ($_.Exception.Message -match '^WINDOWS_SYSPREP_STATE_INVALID: IMAGE_STATE_UNDEPLOYABLE') {
            Write-LabWarning 'Sysprep hat innerhalb des Wartefensters keinen finalen Zustand gemeldet. Aktion [17] prueft den ausgeschalteten Builder offline und zeigt gegebenenfalls die konkrete Sysprep-Ursache an. Den Builder davor nicht erneut starten.'
        }
    }
}

function Publish-LabHyperVSqlImageBuildInteractive {
    [CmdletBinding()]
    param()
    $build = Select-LabHyperVSqlImageBuild -AllowedStates @('RESUME_PENDING') -RequireExistingVm
    if (-not $build) { return }
    $expiry = $null
    if ([string]$build.license.type -eq 'evaluation' -and -not $build.parentArtifact.license.evaluationExpiresAt) {
        $defaultExpiry = (Get-Date).Date.AddDays(180).ToString('yyyy-MM-dd')
        $expiryInput = Read-Host "  Windows-Evaluation endet am [$defaultExpiry]"
        if (-not $expiryInput) { $expiryInput = $defaultExpiry }
        $parsedExpiry = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($expiryInput, 'yyyy-MM-dd', $null, 'AssumeLocal', [ref]$parsedExpiry)) {
            Write-LabError 'Datum muss YYYY-MM-DD entsprechen.'; return
        }
        $expiry = $parsedExpiry
    }
    if (-not (Read-LabConfirm -Prompt '  SQL-Prepared-Image flatten und immutable veroeffentlichen?' -Default $false)) { return }
    try {
        $result = Publish-HyperVSqlPreparedImageBuild -BuildId $build.buildId -EvaluationExpiresAt $expiry
        Write-LabSuccess "SQL-Prepared-Image veroeffentlicht: $($result.Artifact.artifactId)"
    }
    catch { Write-LabError $_.Exception.Message }
}

function Remove-LabHyperVSqlImageBuildInteractive {
    [CmdletBinding()]
    param()
    $allowedStates = @(
        'MEDIA_VERIFIED', 'MANUAL_ACTION_REQUIRED', 'OOBE_AUTOMATION_RUNNING', 'OOBE_COMPLETED',
        'REBOOT_REQUIRED', 'RESUME_PENDING', 'SQL_INSTALL_RUNNING', 'SQL_INSTALL_REBOOT_REQUIRED', 'FAILED'
    )
    $builds = @(Get-HyperVSqlImageBuildPlans | Where-Object state -In $allowedStates)
    if ($builds.Count -eq 0) { Write-LabInfo 'Kein unfertiger SQL-Image-Builder vorhanden.'; return }

    Write-Host ''
    for ($i = 0; $i -lt $builds.Count; $i++) {
        Write-Host "    [$($i + 1)] SQL $($builds[$i].sql.version) [$($builds[$i].state)] $($builds[$i].buildId)" -ForegroundColor White
    }
    Write-Host "    [ALL] Alle $($builds.Count) angezeigten unfertigen SQL-Builder aufraeumen" -ForegroundColor Yellow
    $selection = Read-Host '  Build (Nummer oder ALL)'
    if ($selection -ieq 'ALL') {
        Write-LabWarning "Alle $($builds.Count) angezeigten Builder inklusive VMs und buildlokaler VHDX werden entfernt."
        if (-not (Read-LabConfirm -Prompt '  WIRKLICH ALLE SQL-Builder aufraeumen?' -Default $false)) { return }
        $succeeded = 0; $failed = 0
        foreach ($build in $builds) {
            Write-LabInfo "Cleanup $($succeeded + $failed + 1)/$($builds.Count): $($build.buildId)"
            try {
                $result = Remove-HyperVSqlImageBuild -BuildId $build.buildId
                if ($result.Status -eq 'CLEANUP_SUCCEEDED') { $succeeded++ }
                else { $failed++; Write-LabError "$($build.buildId): Cleanup-Status $($result.Status)" }
            }
            catch { $failed++; Write-LabError "$($build.buildId): $($_.Exception.Message)" }
        }
        if ($failed -eq 0) { Write-LabSuccess "Alle $succeeded SQL-Builder-Ressourcen wurden entfernt." }
        else { Write-LabWarning "Cleanup abgeschlossen: $succeeded erfolgreich, $failed fehlgeschlagen." }
        return
    }
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $builds.Count) {
        Write-LabWarning 'Ungueltige Auswahl.'; return
    }
    $build = $builds[[int]$selection - 1]
    Write-LabWarning "VM und buildlokale VHDX von '$($build.buildId)' werden entfernt."
    if (-not (Read-LabConfirm -Prompt '  SQL-Builder wirklich aufraeumen?' -Default $false)) { return }
    try {
        $result = Remove-HyperVSqlImageBuild -BuildId $build.buildId
        if ($result.Status -eq 'CLEANUP_SUCCEEDED') { Write-LabSuccess 'SQL-Builder-Ressourcen wurden entfernt und aus der offenen Liste ausgeblendet.' }
        else { Write-LabError "Cleanup-Status: $($result.Status)" }
    }
    catch { Write-LabError $_.Exception.Message }
}

function Resume-LabHyperVSqlPreparedImageGeneralizationInteractive {
    [CmdletBinding()]
    param()

    $build = Select-LabHyperVSqlImageBuild -AllowedStates @('MANUAL_ACTION_REQUIRED') -RequireExistingVm
    if (-not $build) { return }
    if (-not $build.setupEvidence -or [string]$build.setupEvidence.action -ne 'PrepareImage') {
        Write-LabInfo 'Dieser Builder besitzt noch kein erfolgreiches SQL-PrepareImage und kann nicht offline uebernommen werden.'
        return
    }
    Write-LabWarning "Die VM '$($build.builder.vmName)' wird ausgeschaltet und ihr Windows-ImageState offline geprueft."
    Write-Host '  Diese Aktion ist nur fuer eine unterbrochene Wiederaufnahme nach SQL PrepareImage/Sysprep gedacht.' -ForegroundColor DarkGray
    if (-not (Read-LabConfirm -Prompt '  Offline-Wiederaufnahme jetzt ausfuehren?' -Default $false)) { return }
    try {
        $result = Resume-HyperVSqlPreparedImageGeneralization -BuildId $build.buildId
        Write-LabSuccess "Generalisierung offline verifiziert. State: $($result.state). Als Nächstes im Builder-Untermenü Prepared-Image veröffentlichen wählen."
    }
    catch { Write-LabError $_.Exception.Message }
}

function Invoke-LabHyperVSqlAcceptanceInstallInteractive {
    [CmdletBinding()]
    param()

    $build = Select-LabHyperVSqlImageBuild -AllowedStates @(
        'MANUAL_ACTION_REQUIRED', 'OOBE_AUTOMATION_RUNNING', 'OOBE_COMPLETED',
        'SQL_INSTALL_RUNNING', 'SQL_INSTALL_REBOOT_REQUIRED', 'SQL_READY_RUN', 'TESTS_PASSED'
    ) -RequireExistingVm
    if (-not $build) { return }
    if ([string]$build.provisioningMode -eq 'fresh-windows-media') {
        Write-LabInfo 'Dieser frische Builder ist für SQL PrepareImage bestimmt. Zuerst Windows manuell installieren, dann im Builder-Untermenü „SQL PrepareImage und finalen Sysprep ausführen“ wählen.'
        return
    }
    Write-Host ("  Ziel: SQL {0} | VM {1}" -f $build.sql.version, $build.builder.vmName) -ForegroundColor White
    Write-Host '  Windows: Region Deutschland, UI en-US, Tastatur Deutsch, Zeitzone Wien/Berlin.' -ForegroundColor DarkGray
    Write-Host '  Netzwerk bleibt getrennt; Setup wird ausschliesslich vom eingebundenen ISO ausgefuehrt.' -ForegroundColor DarkGray
    if (-not (Read-LabConfirm -Prompt '  OOBE und SQL-Installation jetzt unbeaufsichtigt ausfuehren?' -Default $false)) { return }
    try {
        if ($build.state -in @('MANUAL_ACTION_REQUIRED', 'OOBE_AUTOMATION_RUNNING')) {
            $build = Invoke-HyperVSqlUnattendedOobe -BuildId $build.buildId
            Write-LabSuccess "Windows-OOBE verifiziert. State: $($build.state)"
        }
        $credential = Get-HyperVSqlGuestCredential -Build $build
        $saPassword = Get-LabSecret -Path $build.BuildDirectory -Name 'sa-password'
        if (-not $saPassword) { $saPassword = New-HyperVSqlUnattendedPassword }
        $result = Invoke-HyperVSqlTestEnvironmentInstall -BuildId $build.buildId `
            -Credential $credential -SaPassword $saPassword
        if ($result.state -eq 'SQL_INSTALL_REBOOT_REQUIRED') {
            Write-LabInfo 'SQL Setup hat einen Neustart angefordert. Aktion 13 nach dem Gast-Neustart erneut ausfuehren.'
        }
        else { Write-LabSuccess "Windows-SQL-Testumgebung ist bereit. State: $($result.state)" }
    }
    catch { Write-LabError $_.Exception.Message }
}

function Test-LabHyperVSqlAcceptanceInteractive {
    [CmdletBinding()]
    param()

    $build = Select-LabHyperVSqlImageBuild -AllowedStates @('SQL_READY_RUN', 'TESTS_PASSED') -RequireExistingVm
    if (-not $build) { return }
    if (-not (Read-LabConfirm -Prompt '  Create/Insert/Backup/Restore-Verify/Drop-Abnahmetest ausfuehren?' -Default $true)) { return }
    try {
        $credential = Get-HyperVSqlGuestCredential -Build $build
        $result = Test-HyperVSqlAcceptanceEnvironment -BuildId $build.buildId -Credential $credential
        Write-LabSuccess "SQL $($result.sql.version) wurde abgenommen. State: $($result.state)"
    }
    catch { Write-LabError $_.Exception.Message }
}

function Invoke-LabHyperVSqlManualOobeAcceptanceInstallInteractive {
    [CmdletBinding()]
    param()

    $build = Select-LabHyperVSqlImageBuild -AllowedStates @('MANUAL_ACTION_REQUIRED') -RequireExistingVm
    if (-not $build) { return }
    $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
    if (-not $userName) { $userName = 'Administrator' }
    $guestPassword = Read-Host '  Gastpasswort' -AsSecureString
    $credential = [PSCredential]::new($userName, $guestPassword)
    $saPassword = Get-LabSecret -Path $build.BuildDirectory -Name 'sa-password'
    if (-not $saPassword) { $saPassword = New-HyperVSqlUnattendedPassword }
    if (-not (Read-LabConfirm -Prompt '  OOBE ist abgeschlossen; SQL jetzt unbeaufsichtigt installieren?' -Default $false)) { return }
    try {
        $result = Invoke-HyperVSqlTestEnvironmentInstall -BuildId $build.buildId `
            -Credential $credential -SaPassword $saPassword
        if ($result.state -eq 'SQL_INSTALL_REBOOT_REQUIRED') {
            Write-LabInfo 'SQL Setup hat einen Neustart angefordert. Danach Aktion 13 erneut ausfuehren.'
        }
        else { Write-LabSuccess "Windows-SQL-Testumgebung ist bereit. State: $($result.state)" }
    }
    catch { Write-LabError $_.Exception.Message }
}

function Show-LabHyperVSqlAcceptanceMatrix {
    [CmdletBinding()]
    param()

    $matrix = @(Get-HyperVSqlAcceptanceMatrix)
    if ($matrix.Count -eq 0) { Write-LabInfo 'Keine SQL-Abnahmeumgebungen vorhanden.'; return @() }
    Write-Host ''
    Write-Host '  Windows-SQL-Abnahmematrix:' -ForegroundColor White
    foreach ($entry in $matrix) {
        $marker = if ($entry.TestsPassed) { '[PASS]' } elseif ($entry.Ready) { '[READY]' } else { '[----]' }
        $color = if ($entry.TestsPassed) { 'Green' } elseif ($entry.Ready) { 'Yellow' } else { 'DarkGray' }
        Write-Host ("    {0} SQL {1} | {2} | {3}" -f $marker, $entry.SqlVersion, $entry.State, $entry.VMName) -ForegroundColor $color
        if ($entry.ProductVersion) {
            Write-Host ("           {0} | {1} | Computer: {2}" -f $entry.ProductVersion, $entry.Edition, $entry.ComputerName) -ForegroundColor DarkGray
        }
    }
    return $matrix
}

function Select-LabSampleSelection {
    <#
    .SYNOPSIS Menuegefuehrte Mehrfachauswahl katalogisierter Testdatenbanken.
    .DESCRIPTION Zeigt alle mit dem Sample-Handler installierbaren Varianten
                 einschliesslich Groesse, Lizenz, Trust- und Cache-Status und
                 verhindert kollidierende Zieldatenbanken.
    .OUTPUTS String-Array im Format 'sampleId:variante' fuer New-SqlServerLab -Sample.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SqlVersion,
        [switch]$SkipInitialConfirm
    )

    $variants = @(Get-LabExecutableSampleVariant -SqlVersion $SqlVersion)
    if ($variants.Count -eq 0) {
        return @()
    }
    if (-not $SkipInitialConfirm -and -not (Read-LabConfirm -Prompt '  Testdatenbanken aus dem Katalog hinzufuegen?' -Default $false)) {
        return @()
    }

    # Trust- und Cache-Status einmalig ermitteln; die Cache-Pruefung hasht
    # vorhandene Artefakte und ist fuer grosse Backups nicht kostenlos.
    $localStatus = @{}
    foreach ($variant in $variants) {
        $key = "$($variant.SampleId):$($variant.Variant)"
        $localStatus[$key] = Get-LabSampleArtifactLocalStatus `
            -Source $variant.Source `
            -SampleId $variant.SampleId `
            -SampleVariant $variant.Variant `
            -ExpectedSha256 $variant.ExpectedSha256
    }

    $items = @(
        for ($index = 0; $index -lt $variants.Count; $index++) {
            $variant = $variants[$index]
            $key = "$($variant.SampleId):$($variant.Variant)"
            $status = $localStatus[$key]
            $value = "DB: $(@($variant.ExpectedDatabases) -join ', ') | $($variant.DownloadSizeMB) MB | Trust: $($status.TrustStatus) | Cache: $($status.CacheStatus)"
            New-LabConsoleItem -Id $key -Label "$($variant.DisplayName) ($($variant.Variant))" -Value $value -Shortcut ([string]($index + 1)) `
                -Data ([PSCustomObject]@{ Variant=$variant; Status=$status })
        }
    )
    $validateToggle = {
        param($candidate, $selectedItems)
        foreach ($selectedItem in @($selectedItems)) {
            $database = @($selectedItem.Data.Variant.ExpectedDatabases | Where-Object { @($candidate.Data.Variant.ExpectedDatabases) -contains $_ } | Select-Object -First 1)
            if ($database.Count -gt 0) {
                return "SAMPLE_OUTPUT_CONFLICT: '$($candidate.Id)' und '$($selectedItem.Id)' erzeugen beide '$($database[0])'."
            }
        }
        return ''
    }
    $showDetails = {
        param($item)
        $variant = $item.Data.Variant
        $status = $item.Data.Status
        Write-Host ''
        Write-Host "  $($variant.DisplayName) ($($item.Id))" -ForegroundColor White
        Write-Host "    $($variant.Description)" -ForegroundColor DarkGray
        Write-Host "    Erwartete Datenbanken: $(@($variant.ExpectedDatabases) -join ', ')" -ForegroundColor DarkGray
        Write-Host "    Quellseite: $($variant.SourcePage)" -ForegroundColor DarkGray
        Write-Host "    Artifact-URL: $($variant.Source)" -ForegroundColor DarkGray
        Write-Host "    Download: $($variant.DownloadSizeMB) MB | Lizenz: $($variant.License) | Mindest-SQL: $($variant.MinSqlVersion)" -ForegroundColor DarkGray
        Write-Host "    Trust: $($status.TrustStatus) | Cache: $($status.CacheStatus)" -ForegroundColor DarkGray
        if ($status.TrustStatus -eq 'TRUST_REQUIRED') { Write-Host '    Ohne bekannte SHA-256 fragt die Provisionierung einmalig nach Vertrauen.' -ForegroundColor Yellow }
        $null = Read-Host '  [Enter] für Auswahl ...'
    }
    $selectionResult = Invoke-LabConsoleMultiSelect -ScreenId 'sample-selection' -Title 'Testdatenbanken (Sample-Handler)' `
        -Subtitle "SQL Server $SqlVersion" -Items $items -ValidateToggle $validateToggle -ShowDetails $showDetails
    if ($selectionResult.Status -ne 'Confirmed') { return @() }
    return @($selectionResult.SelectedItems | ForEach-Object { [string]$_.Id })
}

function Select-LabHyperVPreparedArtifact {
    [CmdletBinding()]
    param()

    # Die Auswahl liest nur die kleine Registry. Die vollständige VHDX-Integrität
    # wird erst unmittelbar vor dem Klonen geprüft; dadurch bleibt das Menü auch
    # mit mehreren großen Vorlagen ohne minutenlanges Hashing responsiv.
    $artifacts = @(Get-HyperVImageArtifact -SkipIntegrityCheck | Where-Object { $_.artifactState -in @('OS_SEALED', 'SQL_PREPARED_SEALED') })
    if ($artifacts.Count -eq 0) { Write-LabInfo 'Keine veröffentlichte Windows- oder SQL-Vorlage vorhanden.'; return $null }
    Write-Host '  Veröffentlichte Windows- und SQL-Vorlagen:' -ForegroundColor White
    Write-Host '  Windows-OS-Baselines ergeben reine Windows-VMs; SQL-Prepared-Images ergänzen automatisch SQL, WMI und TCP/IP.' -ForegroundColor DarkGray
    Write-Host '  Der Anzeigename ist frei wählbar; bei gleichen technischen Varianten helfen Zeitpunkt und Kurzkennung bei der eindeutigen Auswahl.' -ForegroundColor DarkGray
    for ($i = 0; $i -lt $artifacts.Count; $i++) {
        $artifact = $artifacts[$i]
        $operatingSystemLabel = Get-LabWindowsMediaOperatingSystemLabel -OperatingSystemId ([string]$artifact.operatingSystem.id)
        $isSqlPrepared = [string]$artifact.artifactState -eq 'SQL_PREPARED_SEALED'
        $fallbackName = if ($isSqlPrepared) { "{0} · SQL Server {1} {2}" -f $operatingSystemLabel, $artifact.sql.version, $artifact.sql.edition } else { "{0} · reine Windows-OS-Baseline" -f $operatingSystemLabel }
        $displayName = if ([string]::IsNullOrWhiteSpace([string]$artifact.displayName)) { $fallbackName } else { [string]$artifact.displayName }
        $shortArtifactId = if ([string]$artifact.artifactId -match '([a-f0-9]{12,})$') { $Matches[1].Substring(0, 12) } else { [string]$artifact.artifactId }
        $registeredAt = if ([string]::IsNullOrWhiteSpace([string]$artifact.registeredAt)) { 'unbekannt' } else { Format-LabMenuDateTime -Value $artifact.registeredAt }
        Write-Host ("    [{0}] {1}" -f ($i + 1), $displayName) -ForegroundColor White
        $workload = if ($isSqlPrepared) { "Windows: {0} {1} · SQL Server: {2} {3}" -f $operatingSystemLabel, $artifact.operatingSystem.installationType, $artifact.sql.version, $artifact.sql.edition } else { "Windows: {0} {1} · Reine Windows-VM ohne SQL Server" -f $operatingSystemLabel, $artifact.operatingSystem.installationType }
        Write-Host ("        {0}" -f $workload) -ForegroundColor Gray
        Write-Host ("        Veröffentlicht: {0} · Kennung: {1}" -f $registeredAt, $shortArtifactId) -ForegroundColor DarkGray
    }
    $selection = Read-Host '  Vorlage auswählen [1]'
    if (-not $selection) { $selection = '1' }
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $artifacts.Count) { Write-LabWarning 'Ungültige Auswahl.'; return $null }
    return $artifacts[[int]$selection - 1]
}

function Select-LabHyperVSqlPreparedArtifact {
    <#
    .SYNOPSIS
        Wählt explizit nur veröffentlichte SQL-Prepared-Images aus.
    #>
    [CmdletBinding()]
    param()

    $artifacts = @(Get-HyperVImageArtifact -SkipIntegrityCheck | Where-Object { $_.artifactState -eq 'SQL_PREPARED_SEALED' })
    if ($artifacts.Count -eq 0) {
        Write-LabInfo 'Keine veröffentlichte SQL-Prepared-Vorlage vorhanden.'
        return
    }
    if ($artifacts.Count -eq 1) {
        return $artifacts[0]
    }
    Write-Host '  SQL-Prepared-Vorlagen:' -ForegroundColor White
    for ($i = 0; $i -lt $artifacts.Count; $i++) {
        $artifact = $artifacts[$i]
        $operatingSystemLabel = Get-LabWindowsMediaOperatingSystemLabel -OperatingSystemId ([string]$artifact.operatingSystem.id)
        $displayVersion = if ([string]$artifact.sql.version) { [string]$artifact.sql.version } else { 'unbekannt' }
        $displayEdition = if ([string]$artifact.sql.edition) { [string]$artifact.sql.edition } else { 'unbekannt' }
        Write-Host "    [$($i + 1)] $operatingSystemLabel · SQL $displayVersion $displayEdition" -ForegroundColor White
    }
    $selection = Read-Host '  Vorlage auswählen [1]'
    if (-not $selection) { $selection = '1' }
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $artifacts.Count) {
        Write-LabWarning 'Ungültige Auswahl.'; return
    }
    return $artifacts[[int]$selection - 1]
}

function Select-LabHyperVVirtualSwitch {
    <#
    .SYNOPSIS
        Wählt einen vorhandenen Hyper-V-Switch oder bewusst keine Anbindung.
    .DESCRIPTION
        Die Switch-Liste wird erst unmittelbar vor der Lab-Erstellung gelesen,
        damit zwischenzeitlich neu angelegte oder entfernte Switches korrekt
        berücksichtigt werden. Die Standardauswahl verwendet den verwalteten
        internen Lab-Switch; Isolation muss bewusst gewählt werden.
    #>
    [CmdletBinding()]
    param()

    try {
        $switches = @(Get-VMSwitch -ErrorAction Stop | Sort-Object Name)
    }
    catch {
        Write-LabWarning "Virtuelle Hyper-V-Switches konnten nicht gelesen werden: $($_.Exception.Message)"
        return $null
    }

    Write-Host ''
    Write-Host '  Virtueller Switch:' -ForegroundColor White
    Write-Host '    [Enter] Verwalteter SQL_Server_Lab-Internal-Switch (empfohlen, Hostzugriff möglich)' -ForegroundColor Green
    Write-Host '    [0] Kein Switch = bewusst isoliert' -ForegroundColor DarkGray
    for ($i = 0; $i -lt $switches.Count; $i++) {
        $switch = $switches[$i]
        Write-Host ("    [{0}] {1} · {2}" -f ($i + 1), $switch.Name, $switch.SwitchType) -ForegroundColor White
    }
    $selection = Read-Host '  Virtuellen Switch auswählen [Enter]'
    if (-not $selection) { return [PSCustomObject]@{ SwitchName = $null; Isolated = $false } }
    if ($selection -eq '0') { return [PSCustomObject]@{ SwitchName = $null; Isolated = $true } }
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $switches.Count) {
        Write-LabWarning 'Ungültige Auswahl.'
        return $null
    }
    return [PSCustomObject]@{ SwitchName = [string]$switches[[int]$selection - 1].Name; Isolated = $false }
}

function Read-LabHyperVSqlSaPassword {
    <# Liest bewusst ein separates SA-Passwort oder übernimmt das Gastpasswort. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][SecureString]$GuestPassword)

    Write-Host '  SQL-SA-Passwort: [1] selbst festlegen, [2] vorhandenes Gastpasswort übernehmen [2]' -ForegroundColor White
    $choice = Read-Host '  Auswahl'
    if (-not $choice) { $choice = '2' }
    if ($choice -eq '2') { return $GuestPassword }
    if ($choice -ne '1') { Write-LabWarning 'Ungültige Auswahl.'; return $null }

    $saPassword = Read-Host '  Eigenes SQL-SA-Passwort' -AsSecureString
    $confirmation = Read-Host '  SQL-SA-Passwort bestätigen' -AsSecureString
    $firstBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($saPassword)
    $secondBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmation)
    try {
        if ([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($firstBstr) -ne [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($secondBstr)) {
            Write-LabWarning 'SQL-SA-Passwörter stimmen nicht überein.'
            return $null
        }
        return $saPassword
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstBstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondBstr)
    }
}

function Read-LabHyperVLocaleSettings {
    [CmdletBinding()]
    param()

    $region = Read-Host '  Region (z. B. DE, AT oder de-AT) [DE]'
    if (-not $region) { $region = 'DE' }

    $systemLocale = Read-Host '  System-Locale (z. B. de-DE, en-US oder de-AT) [de-DE]'
    if (-not $systemLocale) { $systemLocale = 'de-DE' }

    $uiLanguage = Read-Host '  UI-Language (z. B. de-DE oder en-US) [en-US]'
    if (-not $uiLanguage) { $uiLanguage = 'en-US' }

    $inputLocale = Read-Host '  Input-Locale [0407:00000407]'
    if (-not $inputLocale) { $inputLocale = '0407:00000407' }

    $timeZone = Read-Host '  Zeitzone [W. Europe Standard Time]'
    if (-not $timeZone) { $timeZone = 'W. Europe Standard Time' }

    return [PSCustomObject]@{
        Region = $region
        SystemLocale = $systemLocale
        UiLanguage = $uiLanguage
        InputLocale = $inputLocale
        TimeZone = $timeZone
    }
}

function New-LabHyperVSqlDeploymentPlanInteractive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, $Intent)

    if ($Intent) {
        $deploymentMode = [string]$Intent.Purpose
    }
    else {
        $mode = Read-Host '  Ausbau: [1] fertiger SQL-Pool-Slot, [2] vollständige SQL-Ad-hoc-Umgebung [1]'
        if (-not $mode) { $mode = '1' }
        if ($mode -notin @('1', '2')) { Write-LabWarning 'Ungültige Auswahl.'; return $null }
        $deploymentMode = if ($mode -eq '1') { 'sql-pool-slot' } else { 'adhoc-install' }
    }
    $mediaRoot = Get-LabMediaRootDefault
    if (-not $mediaRoot) { throw 'Kein Media Root gespeichert. Zuerst Hauptmenü [r] konfigurieren.' }
    $mediaArguments = @{ MediaRoot=$mediaRoot }
    if ($Intent) {
        $mediaArguments.SqlVersion = [string]$Intent.BaseVersion
        if ([string]$Intent.Edition -in @('Standard','Enterprise')) { $mediaArguments.MediaEdition = [string]$Intent.Edition }
    }
    $selectedSqlMedia = Select-LabSqlInstallationMedia @mediaArguments
    if (-not $selectedSqlMedia) { return $null }
    $processorDefault = if ($deploymentMode -eq 'adhoc-install') { 8 } else { 4 }
    $processorCount = if ($Intent) { [int]$Intent.Cpu } else { Read-Host "  vCPU [$processorDefault]" }
    if (-not $processorCount) { $processorCount = $processorDefault }
    $maximumIops = 0
    if (-not $Intent -and $deploymentMode -eq 'adhoc-install') {
        $maximumIops = Read-Host '  Maximale IOPS der SQL-Datenplatte (0 = unbegrenzt) [100]'
        if ([string]::IsNullOrWhiteSpace($maximumIops)) { $maximumIops = 100 }
    }
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId
    $vmStatus = Get-HyperVInstanceStatus -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if (-not $vmStatus -or -not $vmStatus.Exists) { throw 'HYPERV_LAB_VM_NOT_FOUND' }
    if ([string]$vmStatus.State -ne 'Off') {
        Write-LabInfo 'Für die SQL-Ressourcenplanung muss die VM ausgeschaltet sein; sie wird jetzt automatisch sauber heruntergefahren.'
        $stopped = Stop-HyperVLabEnvironment -RunId $RunId
        Write-LabSuccess "VM für SQL-Planung ausgeschaltet: $($stopped.VMName)"
    }
    else {
        Write-LabInfo 'VM ist bereits ausgeschaltet und für die SQL-Ressourcenplanung bereit.'
    }
    $planArguments = @{
        RunId=$RunId; SqlVersion=[string]$selectedSqlMedia.SqlVersion; DeploymentMode=$deploymentMode
        MediaEdition=[string]$selectedSqlMedia.MediaEdition; SqlMediaPath=[string]$selectedSqlMedia.MediaId
        ProcessorCount=[int]$processorCount; MaximumDataIops=[long]$maximumIops
    }
    if ($Intent) {
        $planArguments.MemoryStartupMB = [int]$Intent.MemoryMB
        $planArguments.Collation = [string]$Intent.Collation
        $planArguments.SqlPort = if ([int]$Intent.HostPort -gt 0) { [int]$Intent.HostPort } else { 1433 }
        $planArguments.NetworkMode = [string]$Intent.NetworkMode
        $planArguments.ServerConfig = New-LabIntentServerConfig -Intent $Intent -Target hyperv
        if ($Intent.Patch -and $Intent.Patch.Cu) {
            $planArguments.SqlPatch = [string]$Intent.Patch.Cu
            $planArguments.SqlUpdatePath = [string]$Intent.Patch.WindowsPath
            $planArguments.ExpectedSqlBuild = [string]$Intent.Patch.Build
        }
        $tempPaths = if ([string]$Intent.StorageMode -eq 'separated') {
            @(@('T','U','V','W','X','Y','Z','Q')[0..([int]$Intent.TempDbVolumeCount - 1)] | ForEach-Object { "${_}:\TempDB" })
        } else { @('C:\SQLData\TempDB') }
        $planArguments.StorageConfiguration = [PSCustomObject]@{
            dataPath=if ([string]$Intent.StorageMode -eq 'separated') { 'E:\SQLData' } else { 'C:\SQLData\Data' }
            logPath=if ([string]$Intent.StorageMode -eq 'separated') { 'L:\SQLLog' } else { 'C:\SQLData\Log' }
            tempDbPaths=$tempPaths
            backupPath=if ([string]$Intent.StorageMode -eq 'separated') { 'R:\SQLBackup' } else { 'C:\SQLData\Backup' }
        }
    }
    $plan = Set-HyperVLabSqlDeploymentPlan @planArguments
    Write-LabSuccess "SQL-Ausbau gespeichert: SQL $($plan.sqlVersion) · $($plan.deploymentMode) · $($plan.processorCount) vCPU"
    if ([long]$plan.maximumDataIops -gt 0) {
        $dataRoot = Get-LabDataRootDefault
        if (-not $dataRoot) { throw 'Kein Data Root gespeichert. Zuerst Hauptmenü [d] konfigurieren.' }
        $storage = Enable-HyperVLabPersistentData -RunId $RunId -DataRoot $dataRoot -SizeGB 128 -MaximumIops ([long]$plan.maximumDataIops)
        Write-LabSuccess "Gedrosselte SQL-Datenplatte angehängt: max. $($plan.maximumDataIops) IOPS · $($storage.hostPath)"
    }
    return $plan
}

function Invoke-LabHyperVSqlSlotInstallInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSObject]$Plan,
        [Parameter(Mandatory)][string]$RunId
    )

    if ([string]$Plan.deploymentMode -notin @('sql-pool-slot', 'adhoc-install') -or
        [string]$Plan.state -notin @('PLANNED', 'INSTALL_RETRY_PENDING', 'CONFIGURATION_PENDING')) {
        Write-LabWarning 'Kein ausführbarer vollständiger SQL-Installationsplan vorhanden.'
        return $false
    }
    $mediaRoot = Get-LabMediaRootDefault
    if (-not $mediaRoot) { throw 'Kein Media Root gespeichert. Zuerst Hauptmenü [r] konfigurieren.' }
    Write-Host "  SQL: $($Plan.sqlVersion) · $($Plan.deploymentMode) · Medium $($Plan.mediaEdition)" -ForegroundColor White
    Write-Host '  SQL wird vollständig installiert. Es wird kein Sysprep ausgeführt und dieser Slot wird nicht geklont.' -ForegroundColor Yellow
    if (-not (Read-LabConfirm -Prompt '  Vollständige SQL-Installation jetzt ausführen?' -Default $true)) { return $false }
    $result = Invoke-HyperVLabSqlSlotInstall -RunId $RunId -MediaRoot $mediaRoot
    Write-LabSuccess "SQL-Slot ist bereit: SQL $($result.SqlVersion) · $($result.DeploymentMode)"
    if ($result.GeneratedSqlAccess) {
        Write-Host "  Connection String: $($result.GeneratedSqlAccess.connectionString)" -ForegroundColor White
        Write-Host "  SA-Passwort: $($result.GeneratedSqlAccess.password)" -ForegroundColor Yellow
        Write-Host "  Später abrufbar: Get-SqlServerLabGeneratedSqlAccess -RunId $RunId" -ForegroundColor DarkGray
    }
    return $true
}

function Complete-LabHyperVManualWindowsWorkflowInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [switch]$ContinueWithSql,
        $Intent
    )

    Write-Host ''
    Write-Host '  Bitte jetzt in VMConnect erledigen:' -ForegroundColor White
    Write-Host '    1. Windows-OOBE vollständig abschließen.' -ForegroundColor White
    Write-Host '    2. Lokales Administratorpasswort setzen.' -ForegroundColor White
    Write-Host '    3. Einmal vollständig als Administrator anmelden.' -ForegroundColor White
    Write-Host '    4. Danach hier mit [a] bestätigen; der Workflow läuft automatisch weiter.' -ForegroundColor White
    Write-Host '  Falls VMConnect nach einem Neustart schwarz bleibt, VMConnect schließen und erneut verbinden.' -ForegroundColor DarkYellow
    do {
        $done = Read-Host '  [a] Alles erledigt / [b] Problem - Workflow abbrechen [b]'
        if (-not $done) { $done = 'b' }
        $done = $done.ToLowerInvariant()
        if ($done -notin @('a', 'b')) { Write-LabWarning 'Ungültige Auswahl. Bitte [a] oder [b] eingeben.' }
    } while ($done -notin @('a', 'b'))
    if ($done -eq 'b') {
        Write-LabWarning 'Workflow angehalten. Der Slot bleibt erhalten; Wiederaufnahme unter [i] -> [4] mit [o] „Windows-Grundinstallation übernehmen“.'
        return $false
    }

    $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
    if (-not $userName) { $userName = 'Administrator' }
    $credential = [PSCredential]::new($userName, (Read-Host '  Gastpasswort' -AsSecureString))
    Write-LabInfo 'Windows-Grundinstallation wird jetzt geprüft und das Labnetz eingerichtet.'
    $result = Complete-HyperVLabManualWindowsSlot -RunId $RunId -Credential $credential
    Write-LabSuccess "Windows-Slot übernommen: $($result.VMName) · $($result.ComputerName)"
    if (-not $ContinueWithSql) { return $true }

    Write-LabInfo 'Der Workflow fährt ohne Menüwechsel mit der SQL-Konfiguration fort.'
    $plan = New-LabHyperVSqlDeploymentPlanInteractive -RunId $RunId -Intent $Intent
    if (-not $plan) { return $false }
    return Invoke-LabHyperVSqlSlotInstallInteractive -Plan $plan -RunId $RunId
}

function Select-LabReusableHyperVWindowsSlotInteractive {
    [CmdletBinding()]
    param($Intent, [switch]$Automatic)

    $candidates = @()
    $protectedTestRunIds = @(Get-LabAutomatedTestEnvironmentRunIds)
    $intendedTestRunId = $null
    if ($Intent -and $Intent.TestAutomation -and [string]$Intent.TestEnvironmentKey) {
        try {
            $testRegistry = Get-LabTestEnvironmentRegistry
            $intendedRegistration = @($testRegistry.environments | Where-Object {
                [string]$_.key -eq [string]$Intent.TestEnvironmentKey -and [string]$_.runId
            } | Select-Object -First 1)[0]
            if ($intendedRegistration) { $intendedTestRunId = [string]$intendedRegistration.runId }
        }
        catch { Write-LabWarning "Registrierter Test-Slot konnte nicht auf Wiederaufnahme geprüft werden: $($_.Exception.Message)" }
    }
    foreach ($run in @(Get-LabActiveRuns)) {
        if ([string]$run.metadata.workflowKind -ne 'hyperv-lab') { continue }
        if ($intendedTestRunId -and [string]$run.runId -ne $intendedTestRunId) { continue }
        if (-not $intendedTestRunId -and [string]$run.runId -in $protectedTestRunIds) { continue }
        try {
            $lab = Get-HyperVLabWorkflowRun -RunId ([string]$run.runId)
            $plan = $lab.Instance.sqlDeploymentPlan
            $resumableSqlPlan = $plan -and
                [string]$plan.deploymentMode -in @('sql-pool-slot', 'adhoc-install') -and
                [string]$plan.state -in @('PLANNED', 'INSTALL_RETRY_PENDING', 'CONFIGURATION_PENDING')
            $readySqlPlan = $intendedTestRunId -and $plan -and
                [string]$plan.deploymentMode -in @('sql-pool-slot', 'adhoc-install') -and
                [string]$plan.state -eq 'SQL_SLOT_READY'
            $unusedWindowsSlot = [string]$lab.Instance.workload -eq 'windows' -and -not $plan
            if ($Intent -and $resumableSqlPlan -and [string]$plan.sqlVersion -ne [string]$Intent.BaseVersion) { $resumableSqlPlan = $false }
            if ($Intent -and $unusedWindowsSlot -and [string]$Intent.StorageMode -eq 'separated' -and
                @($lab.Instance.additionalDrives).Count -ne @($Intent.Drives).Count) { $unusedWindowsSlot = $false }
            if (-not $unusedWindowsSlot -and -not $resumableSqlPlan -and -not $readySqlPlan) { continue }
            $status = Get-HyperVInstanceStatus -VMName ([string]$lab.Instance.vmName) `
                -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
            if (-not $status -or -not $status.Exists) { continue }
            $phase = if ($readySqlPlan) {
                'SQL_READY'
            }
            elseif ($resumableSqlPlan) {
                'SQL_RESUME'
            }
            elseif ($lab.Instance.windowsProvisioning -and [string]$lab.Instance.windowsProvisioning.state -eq 'COMPLETE') {
                'WINDOWS_READY'
            }
            else {
                'OOBE_PENDING'
            }
            $candidates += [PSCustomObject]@{
                RunId = [string]$lab.Run.runId
                VMName = [string]$lab.Instance.vmName
                Phase = $phase
                LiveState = [string]$status.State
                CreatedAt = [datetime]$lab.Run.createdAt
                Plan = $plan
            }
        }
        catch {
            Write-LabWarning "Windows-Slot $($run.runId) konnte nicht als Wiederverwendungskandidat geprüft werden: $($_.Exception.Message)"
        }
    }
    $candidates = @($candidates | Sort-Object CreatedAt -Descending)
    if ($candidates.Count -eq 0) { return $null }
    if ($Automatic) {
        $selected = $candidates[-1]
        Write-LabInfo "Freier Windows-Slot wird automatisch aus dem Pool entnommen: $($selected.VMName) (Run $($selected.RunId))."
        return $selected
    }

    $items = @(
        for ($index = 0; $index -lt $candidates.Count; $index++) {
            $candidate = $candidates[$index]
            $phaseLabel = switch ($candidate.Phase) {
                'SQL_RESUME' { if ([string]$candidate.Plan.state -eq 'CONFIGURATION_PENDING') { 'SQL installiert, Konfiguration fortsetzen' } else { 'SQL-Ausbau geplant, Installation fortsetzen' } }
                'SQL_READY' { 'SQL-Testumgebung bereits vollständig bereit' }
                'WINDOWS_READY' { 'Windows übernommen, SQL offen' }
                default { 'OOBE noch offen' }
            }
            New-LabConsoleItem -Id ([string]$candidate.RunId) -Label ([string]$candidate.VMName) -Value "$phaseLabel | Live: $($candidate.LiveState)" -Shortcut ([string]($index + 1)) -Data $candidate
        }
        New-LabConsoleItem -Id 'new' -Label 'Keinen Slot verwenden; neuen Slot aus OS-Vorlage erzeugen' -Shortcut 'n'
    )
    $selectionResult = Invoke-LabConsoleMenu -ScreenId 'hyperv-reusable-windows-slot' -Title 'Vorhandenen Windows-Slot verwenden' -Items $items -SelectedId ([string]$candidates[0].RunId)
    if ($selectionResult.Status -ne 'Selected' -or [string]$selectionResult.SelectedItem.Id -eq 'new') { return $null }
    return $selectionResult.SelectedItem.Data
}

function Invoke-LabReusableHyperVWindowsSlotInteractive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSObject]$Slot, $Intent)

    Write-LabSuccess "Vorhandener Windows-Slot wird für den SQL-Workflow verwendet: $($Slot.VMName)"
    if ($Intent -and $Intent.PSObject.Properties['AutoStart']) {
        $autoStart = Set-HyperVLabAutoStart -RunId ([string]$Slot.RunId) -AutoStart ([string]$Intent.AutoStart)
        Write-LabInfo "VM-Autostart für übernommenen Slot: $($autoStart.AutoStart)."
    }
    if ([string]$Slot.Phase -eq 'SQL_READY') {
        Write-LabSuccess 'Die registrierte SQL-Testumgebung ist bereits vollständig bereit; es wird kein weiterer Pool-Slot belegt.'
        return
    }
    if ([string]$Slot.Phase -eq 'SQL_RESUME') {
        Write-LabInfo 'Ein unterbrochener SQL-Ausbau wurde erkannt und wird ohne erneute Installation am gespeicherten Schritt fortgesetzt.'
        $null = Invoke-LabHyperVSqlSlotInstallInteractive -Plan $Slot.Plan -RunId ([string]$Slot.RunId)
        return
    }
    if ([string]$Slot.Phase -eq 'OOBE_PENDING') {
        if ([string]$Slot.LiveState -ne 'Running') {
            $null = Start-HyperVLabEnvironment -RunId ([string]$Slot.RunId)
        }
        $null = Open-HyperVLabEnvironmentConsole -RunId ([string]$Slot.RunId)
        $null = Complete-LabHyperVManualWindowsWorkflowInteractive -RunId ([string]$Slot.RunId) -ContinueWithSql -Intent $Intent
        return
    }

    Write-LabInfo 'Windows ist bereits übernommen; der Workflow fährt direkt mit SQL-Konfiguration und Installation fort.'
    $plan = New-LabHyperVSqlDeploymentPlanInteractive -RunId ([string]$Slot.RunId) -Intent $Intent
    if (-not $plan) { return }
    $null = Invoke-LabHyperVSqlSlotInstallInteractive -Plan $plan -RunId ([string]$Slot.RunId)
}

function New-LabHyperVEnvironmentInteractive {
    [CmdletBinding()]
    param(
        [switch]$WindowsOnly,
        [switch]$SqlOnly,
        [switch]$ContinueSqlWorkflow,
        $Intent
    )

    if ($WindowsOnly -and $SqlOnly) {
        Write-LabError 'Ungültige Kombination: -WindowsOnly und -SqlOnly.'
        return
    }
    if ($ContinueSqlWorkflow -and -not $WindowsOnly) {
        Write-LabError '-ContinueSqlWorkflow benötigt -WindowsOnly.'
        return
    }

    $artifact = if ($WindowsOnly) { Select-LabHyperVOsArtifact }
    elseif ($SqlOnly) { Select-LabHyperVSqlPreparedArtifact }
    else { Select-LabHyperVPreparedArtifact }
    if (-not $artifact) { return }
    $isSqlPrepared = [string]$artifact.artifactState -eq 'SQL_PREPARED_SEALED'
    $defaultLabNamePrefix = if ($isSqlPrepared) { 'hyperv-sql-lab' } else { 'hyperv-windows-lab' }
    $defaultLabName = '{0}-{1}' -f $defaultLabNamePrefix, (Get-Date -Format 'yyyy-MM-dd-HHmmss')
    $name = if ($Intent) { [string]$Intent.LabName } else { Read-Host "  Labname [$defaultLabName]" }
    if (-not $name) { $name = $defaultLabName }
    $instanceId = if ($Intent) { [string]$Intent.InstanceId } else { Read-Host '  Instanzname [primary]' }
    if (-not $instanceId) { $instanceId = 'primary' }
    $memory = if ($Intent) { [int]$Intent.MemoryMB } else { Read-Host '  Startspeicher MB [4096]' }
    if (-not $memory) { $memory = 4096 }
    $cpu = if ($Intent) { [int]$Intent.Cpu } else { Read-Host '  vCPU [4]' }
    if (-not $cpu) { $cpu = 4 }
    $autoStart = if ($Intent -and $Intent.PSObject.Properties['AutoStart']) { [string]$Intent.AutoStart }
        elseif (Read-LabConfirm -Prompt '  VM beim Hochfahren des Hyper-V-Hosts automatisch starten?' -Default $false) { 'on' }
        else { 'off' }
    $switch = if ($Intent -and [string]$Intent.NetworkMode -eq 'isolated') { [PSCustomObject]@{ SwitchName=$null; Isolated=$true } }
        elseif ($Intent -and [string]$Intent.NetworkMode -eq 'host-access') { [PSCustomObject]@{ SwitchName=$null; Isolated=$false } }
        else { Select-LabHyperVVirtualSwitch }
    if (-not $switch) { return }
    # Eine leere Array-Ausgabe innerhalb einer PowerShell-if-Zuweisung wird zu
    # $null. Der Provider wuerde dieses $null sonst als einen leeren Drive-
    # Eintrag binden. Deshalb den leeren Fall explizit als Array erhalten.
    $additionalDrives = @()
    if ($Intent) {
        $additionalDrives = @(New-LabHyperVDrivesFromIntent -Intent $Intent)
    }
    if (-not $isSqlPrepared) {
        Write-Host "  Image: $($artifact.artifactId)" -ForegroundColor DarkGray
        Write-Host '  Es wird nur ein ausgeschalteter Betriebssystem-Slot als differenzierende VHDX erstellt.' -ForegroundColor Yellow
        Write-Host '  Windows-Grundeinrichtung und OOBE erfolgen anschließend manuell; SQL Server wird nicht installiert.' -ForegroundColor DarkGray
        if (-not (Read-LabConfirm -Prompt '  Windows-Slot jetzt erstellen?' -Default $false)) { return }
        try {
            $lab = New-HyperVLabEnvironment -ArtifactId $artifact.artifactId -LabName $name -InstanceId $instanceId `
                -MemoryStartupMB ([int]$memory) -ProcessorCount ([int]$cpu) -AutoStart $autoStart `
                -SwitchName $switch.SwitchName -Isolated:$switch.Isolated -AdditionalDrives $additionalDrives
            Write-LabSuccess "Windows-Slot erstellt: $($lab.VMName) (Run $($lab.RunId))"
            Write-LabInfo 'Windows-Slot wird jetzt automatisch gestartet und VMConnect geöffnet.'
            $null = Start-HyperVLabEnvironment -RunId $lab.RunId
            $null = Open-HyperVLabEnvironmentConsole -RunId $lab.RunId
            Write-LabSuccess "Windows-Slot läuft; VMConnect ist geöffnet: $($lab.VMName)"
            if ($ContinueSqlWorkflow) {
                $null = Complete-LabHyperVManualWindowsWorkflowInteractive -RunId $lab.RunId -ContinueWithSql -Intent $Intent
            }
            else {
                Write-LabInfo 'Windows-OOBE jetzt manuell abschließen, Administratorpasswort setzen und einmal vollständig anmelden.'
                Write-LabInfo 'Dieser bewusst einzeln erzeugte OS-Slot kann danach unter [i] -> [4] mit [o] übernommen werden.'
            }
        }
        catch { Write-LabError $_.Exception.Message }
        return
    }
    $persistentData = $false
    $dataRoot = Get-LabDataRootDefault
    $persistentDataDiskGB = 128
    if ($isSqlPrepared -and $dataRoot) {
        Write-LabInfo "Optionaler Data Root verfügbar: $dataRoot"
        $persistentData = Read-LabConfirm -Prompt '  Langlebige Daten-VHDX im Data Root anhängen?' -Default $false
        if ($persistentData) {
            $persistentDataDiskGB = Read-Host '  Größe Daten-VHDX in GB [128]'
            if (-not $persistentDataDiskGB) { $persistentDataDiskGB = 128 }
        }
    }
    Write-Host '  Gastpasswort: [1] selbst festlegen, [2] zufällig erzeugen und anzeigen [2]' -ForegroundColor White
    $passwordMode = Read-Host '  Auswahl'
    if (-not $passwordMode) { $passwordMode = '2' }
    if ($passwordMode -notin @('1', '2')) { Write-LabWarning 'Ungültige Auswahl.'; return }
    $passwordSource = if ($passwordMode -eq '2') { 'generated' } else { 'user' }
    if ($passwordSource -eq 'generated') {
        $guestPassword = New-HyperVSqlUnattendedPassword
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($guestPassword)
        try { Write-Host ("  Einmaliges Administratorpasswort (jetzt kopieren): {0}" -f [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)) -ForegroundColor Yellow }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    else {
        $guestPassword = Read-Host '  Lokales Administratorpasswort' -AsSecureString
        $confirmation = Read-Host '  Passwort bestätigen' -AsSecureString
        $firstBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($guestPassword)
        $secondBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmation)
        try {
            if ([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($firstBstr) -ne [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($secondBstr)) {
                Write-LabWarning 'Passwörter stimmen nicht überein.'
                return
            }
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstBstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondBstr)
        }
    }
    $sqlSaPassword = $null
    if ($isSqlPrepared) {
        $sqlSaPassword = Read-LabHyperVSqlSaPassword -GuestPassword $guestPassword
        if (-not $sqlSaPassword) { return }
    }
    $localeSettings = Read-LabHyperVLocaleSettings
    Write-Host "  Image: $($artifact.artifactId)" -ForegroundColor DarkGray
    if ($isSqlPrepared) {
        Write-Host '  Es wird eine differenzierende VM erstellt, automatisch per Unattend.xml eingerichtet und anschließend mit SQL CompleteImage vervollständigt.' -ForegroundColor DarkGray
    }
    else {
        Write-Host '  Es wird eine reine differenzierende Windows-VM erstellt und automatisch per Unattend.xml eingerichtet. SQL, WMI und SQL-TCP werden bewusst nicht angefasst.' -ForegroundColor DarkGray
    }
    if (-not (Read-LabConfirm -Prompt '  Hyper-V-Umgebung jetzt erstellen?' -Default $false)) { return }
    try {
        $lab = New-HyperVLabEnvironment -ArtifactId $artifact.artifactId -LabName $name -InstanceId $instanceId -MemoryStartupMB ([int]$memory) -ProcessorCount ([int]$cpu) -AutoStart $autoStart -SwitchName $switch.SwitchName -Isolated:$switch.Isolated
        if ($persistentData) {
            $null = Enable-HyperVLabPersistentData -RunId $lab.RunId -DataRoot $dataRoot -SizeGB ([int]$persistentDataDiskGB)
        }
        $null = Invoke-HyperVLabUnattendedProvision `
            -RunId $lab.RunId `
            -AdministratorPassword $guestPassword `
            -SqlSaPassword $sqlSaPassword `
            -PasswordSource $passwordSource `
            -Region $localeSettings.Region `
            -SystemLocale $localeSettings.SystemLocale `
            -UiLanguage $localeSettings.UiLanguage `
            -InputLocale $localeSettings.InputLocale `
            -TimeZone $localeSettings.TimeZone
        Write-LabSuccess "Hyper-V-Umgebung bereitgestellt: $($lab.VMName) (Run $($lab.RunId))"
        if ($isSqlPrepared) {
            Write-LabInfo 'Die OOBE, SQL CompleteImage und eine optionale Daten-VHDX-Initialisierung wurden automatisch ausgeführt.'
        }
        else {
            Write-LabInfo 'Die OOBE wurde automatisch ausgeführt. Die VM ist als reine Windows-Umgebung einsatzbereit.'
        }
    }
    catch { Write-LabError $_.Exception.Message }
}

function New-LabHyperVEnvironmentFromExistingVmInteractive {
    [CmdletBinding()]
    param()

    $sources = @(Get-HyperVExistingVmLabSource)
    if ($sources.Count -eq 0) {
        Write-LabInfo 'Keine kompatible Quell-VM gefunden. Erforderlich: ausgeschaltet, Generation 2, nicht durch SQL_Server_Lab verwaltet und genau eine System-VHDX.'
        return
    }
    Write-Host ''
    Write-Host '  Sichere vorhandene Windows-VM als Basis:' -ForegroundColor White
    for ($i = 0; $i -lt $sources.Count; $i++) {
        $source = $sources[$i]
        Write-Host ("    [{0}] {1} · {2} MB · {3} vCPU" -f ($i + 1), $source.VMName, $source.MemoryStartupMB, $source.ProcessorCount) -ForegroundColor White
        Write-Host ("        {0}" -f $source.LicenseNotice) -ForegroundColor DarkYellow
    }
    $selection = Read-Host '  Quell-VM auswählen [1]'
    if (-not $selection) { $selection = '1' }
    if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $sources.Count) { Write-LabWarning 'Ungültige Auswahl.'; return }
    $source = $sources[[int]$selection - 1]
    $name = Read-Host '  Labname [windows-dev-lab]'
    if (-not $name) { $name = 'windows-dev-lab' }
    $instanceId = Read-Host '  Instanzname [primary]'
    if (-not $instanceId) { $instanceId = 'primary' }
    $memory = Read-Host "  Startspeicher MB [$($source.MemoryStartupMB)]"
    if (-not $memory) { $memory = $source.MemoryStartupMB }
    $cpu = Read-Host "  vCPU [$($source.ProcessorCount)]"
    if (-not $cpu) { $cpu = $source.ProcessorCount }
    $autoStart = if (Read-LabConfirm -Prompt '  VM beim Hochfahren des Hyper-V-Hosts automatisch starten?' -Default $false) { 'on' } else { 'off' }
    $switch = Select-LabHyperVVirtualSwitch
    if (-not $switch) { return }
    $persistentData = $false
    $dataRoot = Get-LabDataRootDefault
    $persistentDataDiskGB = 128
    if ($dataRoot) {
        Write-LabInfo "Optionaler Data Root verfügbar: $dataRoot"
        $persistentData = Read-LabConfirm -Prompt '  Langlebige Daten-VHDX im Data Root anhängen?' -Default $false
        if ($persistentData) {
            $persistentDataDiskGB = Read-Host '  Größe Daten-VHDX in GB [128]'
            if (-not $persistentDataDiskGB) { $persistentDataDiskGB = 128 }
        }
    }
    Write-LabWarning 'Die Original-VM und ihre VHDX bleiben unverändert. Es wird eine eigene, schreibgeschützte Arbeitskopie als Parent erstellt.'
    if (-not (Read-LabConfirm -Prompt '  Lizenz- und Ablaufstatus der Quell-VM geprüft und Lab-VM erstellen?' -Default $false)) { return }
    try {
        $lab = New-HyperVLabEnvironmentFromExistingVm -SourceVMName $source.VMName -LabName $name -InstanceId $instanceId -MemoryStartupMB ([int]$memory) -ProcessorCount ([int]$cpu) -AutoStart $autoStart -SwitchName $switch.SwitchName -Isolated:$switch.Isolated -ConfirmSourceLicense
        if ($persistentData) {
            $null = Enable-HyperVLabPersistentData -RunId $lab.RunId -DataRoot $dataRoot -SizeGB ([int]$persistentDataDiskGB)
        }
        Write-LabSuccess "Hyper-V-Umgebung erstellt: $($lab.VMName) (Run $($lab.RunId)); Quelle '$($lab.SourceVMName)' blieb unverändert."
        Write-LabInfo 'Nächster Schritt: [19] wählen, VM starten und VMConnect öffnen.'
    }
    catch { Write-LabError $_.Exception.Message }
}

function Manage-LabHyperVEnvironmentInteractive {
    [CmdletBinding()]
    param([string]$RunId)

    $runs = @(Get-LabActiveRuns | Where-Object { [string]$_.metadata.workflowKind -eq 'hyperv-lab' })
    $protectedRunIds = @(Get-LabAutomatedTestEnvironmentRunIds)
    if ($runs.Count -eq 0) { Write-LabInfo 'Keine regulären Hyper-V-Umgebungen vorhanden.'; return }
    for ($i = 0; $i -lt $runs.Count; $i++) {
        try {
            $lab = Get-HyperVLabWorkflowRun -RunId $runs[$i].runId
            $status = Get-HyperVInstanceStatus -VMName $lab.Instance.vmName -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
            $protectionLabel = if ([string]$runs[$i].runId -in $protectedRunIds) { ' · TESTGRUPPE GESCHÜTZT' } else { '' }
            Write-Host ("    [{0}] {1} · Live: {2} · Workflow: {3} · VM {4}{5}" -f ($i + 1), $runs[$i].metadata.name, $status.State, $runs[$i].state, $lab.Instance.vmName, $protectionLabel) -ForegroundColor White
            $windowsState = if ($lab.Instance.windowsProvisioning -and [string]$lab.Instance.windowsProvisioning.state -eq 'COMPLETE') { 'bereit' } else { 'OOBE/Übernahme ausständig' }
            $sqlState = 'nicht installiert'
            $sqlColor = 'DarkGray'
            if ($lab.Instance.sqlDeploymentPlan) {
                $sqlPlan = $lab.Instance.sqlDeploymentPlan
                switch ([string]$sqlPlan.state) {
                    'PLANNED' { $sqlState = "geplant: SQL $($sqlPlan.sqlVersion) · $($sqlPlan.deploymentMode)"; $sqlColor = 'Yellow' }
                    'INSTALLING' { $sqlState = "Installation läuft oder wurde unterbrochen: SQL $($sqlPlan.sqlVersion)"; $sqlColor = 'Yellow' }
                    'INSTALL_RETRY_PENDING' { $sqlState = "Setup fehlgeschlagen, erneute Installation möglich: SQL $($sqlPlan.sqlVersion)"; $sqlColor = 'Yellow' }
                    'CONFIGURATION_PENDING' { $sqlState = "installiert, Abschlusskonfiguration ausständig: SQL $($sqlPlan.sqlVersion)"; $sqlColor = 'Yellow' }
                    'SQL_SLOT_READY' { $sqlState = "bereit und verwendbar: SQL $($sqlPlan.sqlVersion) · $($sqlPlan.deploymentMode)"; $sqlColor = 'Green' }
                    'PREPARE_RUNNING' { $sqlState = 'nicht verwendbar: alter PrepareImage-/Sysprep-Versuch'; $sqlColor = 'Red' }
                    'GENERALIZED_READY_TO_PUBLISH' { $sqlState = 'veralteter generalisierter PrepareImage-Zustand; kein SQL-Pool-Slot'; $sqlColor = 'Red' }
                    default { $sqlState = "unbekannter Zustand: $($sqlPlan.state)"; $sqlColor = 'Red' }
                }
            }
            elseif ([string]$lab.Instance.workload -eq 'sql') {
                $sqlState = if ($lab.Instance.sqlVersion) { "SQL $($lab.Instance.sqlVersion), Status nicht vollständig katalogisiert" } else { 'SQL-Workload, Version unbekannt' }
                $sqlColor = 'Yellow'
            }
            Write-Host "        Windows: $windowsState · SQL: $sqlState" -ForegroundColor $sqlColor
            if ($lab.Instance.connectionString) { Write-Host "        Connection String (Host-SSMS): $($lab.Instance.connectionString)" -ForegroundColor DarkGray }
            if ($lab.Instance.persistentStorage) {
                Write-Host "        Persistente Daten: Host-VHDX $($lab.Instance.persistentStorage.hostPath) -> Gast $($lab.Instance.persistentStorage.guestPath) [$($lab.Instance.persistentStorage.state)]" -ForegroundColor DarkGray
                if ($lab.Instance.persistentStorage.backupGuestPath) { Write-Host "        Backup-Arbeitsbereich: Gast $($lab.Instance.persistentStorage.backupGuestPath) (eigene Daten-VHDX)" -ForegroundColor DarkGray }
            }
        }
        catch { Write-Host ("    [{0}] {1} · {2}" -f ($i + 1), $runs[$i].metadata.name, $runs[$i].state) -ForegroundColor Yellow }
    }
    if (-not $RunId) {
        $runItems = @(
            for ($index = 0; $index -lt $runs.Count; $index++) {
                $run = $runs[$index]
                $protected = [string]$run.runId -in $protectedRunIds
                try {
                    $lab = Get-HyperVLabWorkflowRun -RunId $run.runId
                    $status = Get-HyperVInstanceStatus -VMName $lab.Instance.vmName -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
                    $value = "Live: $($status.State) | Workflow: $($run.state) | VM: $($lab.Instance.vmName)"
                    if ($protected) { $value += ' | geschützte Testgruppe' }
                    New-LabConsoleItem -Id ([string]$run.runId) -Label ([string]$run.metadata.name) -Value $value -Shortcut ([string]($index + 1)) -Data $run -Disabled:$protected
                }
                catch { New-LabConsoleItem -Id ([string]$run.runId) -Label ([string]$run.metadata.name) -Value ([string]$run.state) -Shortcut ([string]($index + 1)) -Data $run -Disabled:$protected }
            }
        )
        $runSelection = Invoke-LabConsoleMenu -ScreenId 'hyperv-environment-selection' -Title 'Hyper-V-Umgebung verwalten' -Items $runItems
        if ($runSelection.Status -ne 'Selected') { return }
        $RunId = [string]$runSelection.SelectedItem.Id
    }
    elseif (@($runs | Where-Object { [string]$_.runId -eq $RunId }).Count -ne 1) {
        Write-LabWarning 'Die ausgewählte Hyper-V-Umgebung existiert nicht mehr.'
        return
    }
    if ([string]$RunId -in $protectedRunIds) {
        Write-LabWarning 'Diese Hyper-V-Umgebung gehört zur geschützten Testgruppe und ist hier nicht einzeln verwaltbar.'
        return
    }
    $selectedLab = Get-HyperVLabWorkflowRun -RunId $runId
    $isSqlLab = if ($selectedLab.Instance.workload) { [string]$selectedLab.Instance.workload -eq 'sql' } else { [bool]$selectedLab.Instance.sqlVersion }
    $persistentStorage = $selectedLab.Instance.persistentStorage
    $persistentStoragePending = $persistentStorage -and [string]$persistentStorage.state -eq 'ATTACHED_PENDING_INITIALIZATION'
    Write-Host ''
    Write-Host '  Aktion auswählen:' -ForegroundColor White
    Write-Host '    [s] VM starten' -ForegroundColor Yellow
    Write-Host '        Startet die ausgewählte, ausgeschaltete Lab-VM.' -ForegroundColor DarkGray
    Write-Host '    [v] VMConnect öffnen' -ForegroundColor White
    Write-Host '        Öffnet die lokale VM-Konsole für sichtbare Windows-Arbeiten.' -ForegroundColor DarkGray
    Write-Host '    [p] VM stoppen' -ForegroundColor White
    Write-Host '        Fährt die Lab-VM sauber herunter; Image und Daten bleiben erhalten.' -ForegroundColor DarkGray
    Write-Host '    [r] CPU und Speicher ändern' -ForegroundColor White
    Write-Host '        Setzt vCPU und einen sinnvollen dynamischen Speicherbereich; VM muss ausgeschaltet sein.' -ForegroundColor DarkGray
    if (-not $persistentStorage) {
        Write-Host '    [d] Daten-VHDX anhängen' -ForegroundColor White
        Write-Host '        Optional: Erstellt eine eigene langlebige Datenplatte im Data Root und hängt sie an.' -ForegroundColor DarkGray
    }
    elseif ($persistentStoragePending) {
        Write-Host '    [i] Daten-VHDX initialisieren' -ForegroundColor White
        Write-Host '        Formatiert ausschließlich die neu angehängte Lab-Datenplatte; nutzt einen freien Gastbuchstaben (bevorzugt S:\SQLData).' -ForegroundColor DarkGray
    }
    else {
        Write-Host "        Persistente Daten sind bereit: $($persistentStorage.guestPath)" -ForegroundColor DarkGray
    }
    if ($isSqlLab) {
        Write-Host '    [c] SQL CompleteImage ausführen' -ForegroundColor Yellow
        Write-Host '        Vervollständigt SQL Server im Klon. Erforderlich, wenn MSSQLSERVER noch fehlt.' -ForegroundColor DarkGray
        Write-Host '    [h] Host-SSMS einrichten' -ForegroundColor Yellow
        Write-Host '        Richtet Labnetz, feste Gast-IP, SQL-TCP und die Host-Verbindung mit SA ein.' -ForegroundColor DarkGray
        Write-Host '    [q] SQL-Instanzen prüfen' -ForegroundColor White
        Write-Host '        Liest Dienste, Instanzen und TCP-Ports aus; verändert die VM nicht.' -ForegroundColor DarkGray
        Write-Host '    [w] SQL-WMI reparieren' -ForegroundColor White
        Write-Host '        Repariert den SQL-WMI-Provider – nur bei Fehlern im SQL Configuration Manager.' -ForegroundColor DarkGray
    }
    else {
        $windowsSlotReady = $selectedLab.Instance.windowsProvisioning -and [string]$selectedLab.Instance.windowsProvisioning.state -eq 'COMPLETE'
        if (-not $windowsSlotReady) {
            Write-Host '    [o] Windows-Grundinstallation übernehmen' -ForegroundColor Yellow
            Write-Host '        Startet die VM falls erforderlich, öffnet VMConnect und prüft danach die abgeschlossene OOBE.' -ForegroundColor DarkGray
            Write-Host '        Nach OOBE und Admin-Anmeldung hier mit [o] bestätigen, anschließend wird optional direkt SQL-Inbetriebnahme angeboten.' -ForegroundColor DarkGray
        }
        else {
            Write-Host '        Windows-Slot ist übernommen und für einen späteren SQL-Ausbau bereit.' -ForegroundColor Green
            if ($selectedLab.Instance.sqlDeploymentPlan) {
                $plan = $selectedLab.Instance.sqlDeploymentPlan
                $iopsLabel = if ([long]$plan.maximumDataIops -gt 0) { [string]$plan.maximumDataIops } else { 'unbegrenzt' }
                Write-Host ("        SQL-Ziel: {0} · {1} · {2} vCPU · Data-I/O max. {3} IOPS" -f $plan.sqlVersion, $plan.deploymentMode, $plan.processorCount, $iopsLabel) -ForegroundColor Cyan
                if ([string]$plan.deploymentMode -in @('sql-pool-slot','adhoc-install') -and [string]$plan.state -in @('PLANNED','INSTALL_RETRY_PENDING','CONFIGURATION_PENDING')) {
                    Write-Host '    [x] SQL vollständig installieren und konfigurieren' -ForegroundColor Yellow
                    Write-Host '        Installiert eine fertige SQL-Instanz in diesen eindeutigen Slot. Kein Sysprep und kein anschließendes Klonen.' -ForegroundColor DarkGray
                }
                elseif ([string]$plan.state -eq 'SQL_SLOT_READY') {
                    Write-Host '        SQL-Slot ist vollständig installiert und einsatzbereit.' -ForegroundColor Green
                }
                elseif ([string]$plan.state -in @('PLANNED', 'PREPARE_RUNNING') -and [string]$plan.deploymentMode -eq 'prepared-template') {
                    $resumeLabel = if ([string]$plan.state -eq 'PREPARE_RUNNING') { 'SQL-Generalize sicher fortsetzen' } else { 'SQL PrepareImage und Windows-Generalize ausführen' }
                    Write-Host "    [r] $resumeLabel" -ForegroundColor Yellow
                    if ([string]$plan.state -eq 'PREPARE_RUNNING') {
                        Write-Host '        Startet weder SQL Setup noch Sysprep erneut; überwacht ausschließlich den bereits laufenden Generalize-Vorgang.' -ForegroundColor DarkGray
                    }
                    else {
                        Write-Host '        Verwendet das gespeicherte Gastpasswort, bindet die SQL-ISO ein und fährt die VM danach ausgeschaltet herunter.' -ForegroundColor DarkGray
                    }
                }
                elseif ([string]$plan.state -eq 'GENERALIZED_READY_TO_PUBLISH') {
                    Write-Host '        SQL-Prepared-VHDX ist generalisiert und wartet auf Veröffentlichung. VM ausgeschaltet lassen.' -ForegroundColor Green
                }
            }
            else {
                Write-Host '    [a] SQL-Ausbau festlegen und direkt ausführen' -ForegroundColor Yellow
                Write-Host '        Legt SQL-Version, Installationsart und CPU fest. Danach optional sofortige Installation im selben Schritt.' -ForegroundColor DarkGray
            }
        }
        Write-Host '        Reine Windows-Umgebung: SQL Server ist nicht installiert.' -ForegroundColor DarkGray
    }
    Write-Host '    [e] Umgebung entfernen' -ForegroundColor Red
    Write-Host '        Löscht VM und run-lokale differenzierende VHDX nach Bestätigung.' -ForegroundColor DarkGray
    $actionItems = @(
        New-LabConsoleItem -Id 's' -Label 'VM starten' -Shortcut 's' -Value 'ausgeschaltete Lab-VM starten'
        New-LabConsoleItem -Id 'v' -Label 'VMConnect öffnen' -Shortcut 'v' -Value 'lokale VM-Konsole öffnen'
        New-LabConsoleItem -Id 'p' -Label 'VM stoppen' -Shortcut 'p' -Value 'sauber herunterfahren'
        New-LabConsoleItem -Id 'resources' -Label 'CPU und Speicher ändern' -Shortcut 'r' -Value 'VM muss ausgeschaltet sein'
        if (-not $persistentStorage) { New-LabConsoleItem -Id 'd' -Label 'Daten-VHDX anhängen' -Shortcut 'd' }
        elseif ($persistentStoragePending) { New-LabConsoleItem -Id 'i' -Label 'Daten-VHDX initialisieren' -Shortcut 'i' }
        if ($isSqlLab) {
            New-LabConsoleItem -Id 'c' -Label 'SQL CompleteImage ausführen' -Shortcut 'c' -Value 'MSSQLSERVER vervollständigen'
            New-LabConsoleItem -Id 'h' -Label 'Host-SSMS einrichten' -Shortcut 'h' -Value 'Netzwerk, SQL-TCP und Host-Verbindung'
            New-LabConsoleItem -Id 'q' -Label 'SQL-Instanzen prüfen' -Shortcut 'q'
            New-LabConsoleItem -Id 'w' -Label 'SQL-WMI reparieren' -Shortcut 'w'
        }
        else {
            if (-not $windowsSlotReady) { New-LabConsoleItem -Id 'o' -Label 'Windows-Grundinstallation übernehmen' -Shortcut 'o' }
            elseif (-not $selectedLab.Instance.sqlDeploymentPlan) { New-LabConsoleItem -Id 'a' -Label 'SQL-Ausbau festlegen und direkt ausführen' -Shortcut 'a' }
            elseif ([string]$selectedLab.Instance.sqlDeploymentPlan.deploymentMode -in @('sql-pool-slot','adhoc-install') -and [string]$selectedLab.Instance.sqlDeploymentPlan.state -in @('PLANNED','INSTALL_RETRY_PENDING','CONFIGURATION_PENDING')) {
                New-LabConsoleItem -Id 'x' -Label 'SQL vollständig installieren und konfigurieren' -Shortcut 'x'
            }
            elseif ([string]$selectedLab.Instance.sqlDeploymentPlan.deploymentMode -eq 'prepared-template' -and [string]$selectedLab.Instance.sqlDeploymentPlan.state -in @('PLANNED','PREPARE_RUNNING')) {
                New-LabConsoleItem -Id 'prepared' -Label 'SQL PrepareImage/Generalize ausführen oder fortsetzen' -Shortcut 'g'
            }
        }
        New-LabConsoleItem -Id 'e' -Label 'Umgebung entfernen' -Shortcut 'e' -Value 'VM und run-lokale VHDX löschen'
    )
    $actionResult = Invoke-LabConsoleMenu -ScreenId 'hyperv-environment-actions' -Title 'Hyper-V-Umgebung verwalten' -Subtitle "$($selectedLab.Run.name) | VM: $($selectedLab.Instance.vmName)" -Items $actionItems
    if ($actionResult.Status -ne 'Selected') { return }
    $action = [string]$actionResult.SelectedItem.Id
    $actionBefore = Get-LabWorkflowLifecycleFingerprint
    $connectionCenterImpact = switch ($action) {
        { $_ -in @('s', 'p') } { 'RuntimeState'; break }
        'e' { 'EndpointSet'; break }
        'h' { 'EndpointSet'; break }
        default { 'None' }
    }
    $planSqlDeployment = {
        param([Parameter(Mandatory)] [string] $RunId)
        New-LabHyperVSqlDeploymentPlanInteractive -RunId $RunId
    }
    $executeSqlSlotInstall = {
        param(
            [Parameter(Mandatory)] [PSObject] $Plan,
            [Parameter(Mandatory)] [string] $RunId
        )

        return Invoke-LabHyperVSqlSlotInstallInteractive -Plan $Plan -RunId $RunId
    }

    try {
        switch ($action) {
            's' { $result = Start-HyperVLabEnvironment -RunId $runId; Write-LabSuccess "VM gestartet: $($result.VMName)" }
            'v' { $result = Open-HyperVLabEnvironmentConsole -RunId $runId; Write-LabInfo "VMConnect geöffnet: $($result.VMName)" }
            'p' { $result = Stop-HyperVLabEnvironment -RunId $runId; Write-LabSuccess "VM gestoppt: $($result.VMName)" }
            'resources' { Set-LabResourcesInteractive -RunId $runId }
            'd' {
                if ($persistentStorage) { Write-LabWarning 'Für diese Umgebung ist bereits eine Daten-VHDX angehängt.'; return }
                $dataRoot = Get-LabDataRootDefault
                if (-not $dataRoot) { Write-LabError 'Kein Data Root gespeichert. Zuerst Hauptmenü [d] konfigurieren.'; return }
                $sizeGB = Read-Host '  Größe Daten-VHDX in GB [128]'
                if (-not $sizeGB) { $sizeGB = 128 }
                $storage = Enable-HyperVLabPersistentData -RunId $runId -DataRoot $dataRoot -SizeGB ([int]$sizeGB)
                Write-LabSuccess "Daten-VHDX angehängt: $($storage.hostPath)"
            }
            'i' {
                if (-not $persistentStoragePending) { Write-LabWarning 'Keine neu angehängte Daten-VHDX wartet auf Initialisierung.'; return }
                $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
                if (-not $userName) { $userName = 'Administrator' }
                $credential = [PSCredential]::new($userName, (Read-Host '  Gastpasswort' -AsSecureString))
                $result = Initialize-HyperVLabPersistentData -RunId $runId -Credential $credential
                $dataDrive = @($result.Drives | Where-Object id -EQ 'persistent-sql-data') | Select-Object -First 1
                Write-LabSuccess "Daten-VHDX wurde im Gast als $($dataDrive.guestPath) initialisiert."
            }
            'o' {
                if ($isSqlLab) { Write-LabWarning 'Diese Aktion gilt nur für reine Windows-Slots.'; return }
                if ($windowsSlotReady) { Write-LabWarning 'Dieser Windows-Slot wurde bereits übernommen.'; return }
                $vmStatus = Get-HyperVInstanceStatus -VMName $selectedLab.Instance.vmName `
                    -ExpectedRunId $selectedLab.Run.runId -ExpectedScopeId $selectedLab.Run.scopeId
                if (-not $vmStatus -or [string]$vmStatus.State -ne 'Running') {
                    Write-LabInfo 'Manuelle Grundinstallation: VM wird gestartet...'
                    $result = Start-HyperVLabEnvironment -RunId $runId
                    Write-LabSuccess "VM gestartet: $($result.VMName)"
                }
                else {
                    Write-LabInfo "VM bereits laufend: $($selectedLab.Instance.vmName)"
                }
                $console = Open-HyperVLabEnvironmentConsole -RunId $runId
                Write-LabInfo "VMConnect ist geöffnet: $($console.VMName)"
                Write-Host '  Bitte in VM Connect fortfahren:' -ForegroundColor White
                Write-Host '    1. Windows OOBE vollständig abschließen.' -ForegroundColor White
                Write-Host '    2. Lokales Administrator-Kennwort setzen.' -ForegroundColor White
                Write-Host '    3. Erstanmeldung als Administrator durchführen.' -ForegroundColor White
                Write-Host '    4. Mit Netzwerk/Hostname-Einstellungen hier die manuelle Erledigung bestätigen.' -ForegroundColor White
                Write-Host '  Hast du die Windows-Grundinstallation vollständig abgeschlossen?' -ForegroundColor White
                $done = Read-Host '  [a] Ja / [b] Problem - jetzt abbrechen [b]'
                if (-not $done) { $done = 'b' }
                if ($done.ToLowerInvariant() -eq 'b') { Write-LabWarning 'Abbruch: Bitte Windows-OOBE in der VM vollständig beenden und anschließend erneut [o] wählen.'; return }
                if ($done.ToLowerInvariant() -ne 'a') { Write-LabWarning 'Ungültige Auswahl.'; return }
                $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
                if (-not $userName) { $userName = 'Administrator' }
                $credential = [PSCredential]::new($userName, (Read-Host '  Gastpasswort' -AsSecureString))
                $result = Complete-HyperVLabManualWindowsSlot -RunId $runId -Credential $credential
                Write-LabSuccess "Windows-Slot übernommen: $($result.VMName) · $($result.ComputerName)"
                $selectedPlan = $selectedLab.Instance.sqlDeploymentPlan
                if ($selectedPlan -and [string]$selectedPlan.deploymentMode -in @('sql-pool-slot', 'adhoc-install') -and
                    [string]$selectedPlan.state -in @('PLANNED', 'INSTALL_RETRY_PENDING', 'CONFIGURATION_PENDING')) {
                    if (Read-LabConfirm -Prompt '  Windows ist übernommen. Soll jetzt der SQL-Ausbau automatisch abgeschlossen werden?' -Default $true) {
                        if (-not (& $executeSqlSlotInstall $selectedPlan $runId)) { return }
                    }
                }
                else {
                    if (Read-LabConfirm -Prompt '  SQL-Ausbau ist noch nicht geplant. Jetzt direkt mit Standardfragen erstellen?' -Default $true) {
                        $newPlan = & $planSqlDeployment $runId
                        if (-not $newPlan) { return }
                        if (Read-LabConfirm -Prompt '  SQL jetzt direkt installieren und Umgebung fertigstellen?' -Default $true) {
                            if (-not (& $executeSqlSlotInstall $newPlan $runId)) { return }
                        }
                    }
                    else {
                        Write-LabInfo 'SQL-Ausbau noch offen. Nutze [a], um SQL-Version/Modus festzulegen.'
                    }
                }
            }
            'a' {
                if ($isSqlLab) { Write-LabWarning 'Diese Aktion gilt nur für reine Windows-Slots.'; return }
                if (-not $windowsSlotReady) { Write-LabWarning 'Zuerst Windows-Grundinstallation übernehmen.'; return }
                if ($selectedLab.Instance.sqlDeploymentPlan) { Write-LabWarning 'Für diesen Slot ist bereits ein SQL-Ausbau gespeichert.'; return }
                $plan = & $planSqlDeployment $runId
                if (-not $plan) { return }
                Write-LabSuccess "SQL-Ausbau gespeichert: SQL $($plan.sqlVersion) · $($plan.deploymentMode) · $($plan.processorCount) vCPU"
                Write-LabInfo 'Der gespeicherte Sollzustand ist die Grundlage für den folgenden automatischen SQL-Installationsschritt.'
                if (Read-LabConfirm -Prompt '  SQL jetzt direkt installieren und Umgebung fertigstellen?' -Default $true) {
                    if (-not (& $executeSqlSlotInstall $plan $runId)) { return }
                }
            }
            'x' {
                if ($isSqlLab -or -not $windowsSlotReady) { Write-LabWarning 'Diese Aktion benötigt einen übernommenen Windows-Slot.'; return }
                $plan = $selectedLab.Instance.sqlDeploymentPlan
                if (-not (& $executeSqlSlotInstall $plan $runId)) { return }
            }
            'prepared' {
                if ($isSqlLab -or -not $windowsSlotReady) { Write-LabWarning 'Diese Aktion benötigt einen übernommenen Windows-Slot.'; return }
                $plan = $selectedLab.Instance.sqlDeploymentPlan
                if (-not $plan -or [string]$plan.state -notin @('PLANNED', 'PREPARE_RUNNING') -or [string]$plan.deploymentMode -ne 'prepared-template') {
                    Write-LabWarning 'Kein ausführbarer SQL-Prepared-Ausbauplan vorhanden.'; return
                }
                $mediaRoot = Get-LabMediaRootDefault
                if (-not $mediaRoot) { throw 'Kein Media Root gespeichert. Zuerst Hauptmenü [r] konfigurieren.' }
                Write-Host "  SQL: $($plan.sqlVersion) · Medium $($plan.mediaEdition) · Features $(@($plan.features) -join ', ')" -ForegroundColor White
                if ([string]$plan.state -eq 'PREPARE_RUNNING') {
                    Write-Host '  SQL PrepareImage und Sysprep werden nicht wiederholt; nur der laufende Generalize-Vorgang wird übernommen.' -ForegroundColor Yellow
                    if (-not (Read-LabConfirm -Prompt '  SQL-Generalize jetzt sicher fortsetzen?' -Default $false)) { return }
                }
                else {
                    Write-Host '  Die VM wird gestartet, generalisiert und danach ausgeschaltet. Nicht manuell eingreifen.' -ForegroundColor Yellow
                    if (-not (Read-LabConfirm -Prompt '  SQL PrepareImage jetzt ausführen?' -Default $false)) { return }
                }
                $result = Invoke-HyperVLabSqlPreparedSlot -RunId $runId -MediaRoot $mediaRoot
                Write-LabSuccess "SQL-Prepared-Slot ist veröffentlichungsbereit: SQL $($result.SqlVersion) · $($result.SetupVersion)"
                Write-LabInfo 'Die VM muss ausgeschaltet bleiben. Nächster Schritt: immutable SQL-Vorlage veröffentlichen.'
            }
            'c' {
                if (-not $isSqlLab) { Write-LabWarning 'Diese reine Windows-Umgebung enthält keine SQL-Prepared-Instanz.'; return }
                $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
                if (-not $userName) { $userName = 'Administrator' }
                $credential = [PSCredential]::new($userName, (Read-Host '  Gastpasswort' -AsSecureString))
                $sqlSaPassword = Read-LabHyperVSqlSaPassword -GuestPassword $credential.Password
                if (-not $sqlSaPassword) { return }
                $result = Complete-HyperVLabSqlImage -RunId $runId -Credential $credential -SqlSaPassword $sqlSaPassword
                Write-LabSuccess "SQL CompleteImage abgeschlossen. State: $($result.State)"
            }
            'h' {
                if (-not $isSqlLab) { Write-LabWarning 'Host-SSMS ist nur für SQL-Prepared-Umgebungen verfügbar.'; return }
                $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
                if (-not $userName) { $userName = 'Administrator' }
                $credential = [PSCredential]::new($userName, (Read-Host '  Gastpasswort' -AsSecureString))
                $sqlSaPassword = Read-LabHyperVSqlSaPassword -GuestPassword $credential.Password
                if (-not $sqlSaPassword) { return }
                $switch = Select-LabHyperVVirtualSwitch
                if (-not $switch) { return }
                if ($switch.Isolated) { throw 'HYPERV_LAB_HOST_SQL_REQUIRES_NETWORK' }
                $result = Enable-HyperVLabHostSqlAccess -RunId $runId -Credential $credential -SqlSaPassword $sqlSaPassword -SwitchName $switch.SwitchName
                Write-LabSuccess "Host-SSMS bereit: $($result.ConnectionString)"
            }
            'q' {
                if (-not $isSqlLab) { Write-LabWarning 'SQL-Instanzen prüfen ist für reine Windows-Umgebungen nicht anwendbar.'; return }
                $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
                if (-not $userName) { $userName = 'Administrator' }
                $credential = [PSCredential]::new($userName, (Read-Host '  Gastpasswort' -AsSecureString))
                $instances = @(Inspect-HyperVLabSqlInstances -RunId $runId -Credential $credential)
                foreach ($instance in $instances) {
                    Write-Host ("    {0} · Dienst {1} · TCP {2}" -f $instance.Name, $instance.ServiceStatus, $instance.TcpPort) -ForegroundColor White
                    Write-Host "      Connection String: $($instance.ConnectionString)" -ForegroundColor DarkGray
                }
            }
            'w' {
                if (-not $isSqlLab) { Write-LabWarning 'SQL-WMI reparieren ist für reine Windows-Umgebungen nicht anwendbar.'; return }
                $userName = Read-Host '  Lokaler Gast-Administrator [Administrator]'
                if (-not $userName) { $userName = 'Administrator' }
                $credential = [PSCredential]::new($userName, (Read-Host '  Gastpasswort' -AsSecureString))
                $result = Repair-HyperVLabSqlWmiProvider -RunId $runId -Credential $credential
                Write-LabSuccess "SQL-WMI-Provider geprüft. Repariert: $($result.repaired)"
            }
            'e' {
                if (Read-LabConfirm -Prompt '  VM und run-lokale differenzierende VHDX wirklich entfernen?' -Default $false) {
                    $result = Remove-SqlServerLab -RunId $runId -Force -Confirm:$false
                    Write-LabSuccess "Entfernt: $($result.RunId)"
                }
            }
            default { Write-LabWarning 'Ungültige Aktion.' }
        }
    }
    catch {
        Write-LabError $_.Exception.Message
        return New-LabActionResult -Action Manage -Status Failed -ErrorCode 'LAB_HYPERV_MANAGE_ACTION_FAILED'
    }

    $actionAfter = Get-LabWorkflowLifecycleFingerprint
    $status = if ($actionBefore -ne $actionAfter) { 'Changed' } else { 'NoChange' }
    return New-LabActionResult -Action Manage -Status $status -ConnectionCenterImpact $connectionCenterImpact
}

function Get-AvailableLabProviders {
    <#
    .SYNOPSIS Ermittelt alle lokal verfuegbaren und implementierten Provider.
    .DESCRIPTION Prueft dynamisch, welche implementierten Container-Runtimes erreichbar sind.
    .OUTPUTS String-Array der verfuegbaren Provider-Namen.
    #>
    [CmdletBinding()]
    param()

    $available = @()

    if (Get-Command 'docker' -ErrorAction SilentlyContinue) {
        $null = docker version --format '{{.Server.Version}}' 2>&1
        if ($LASTEXITCODE -eq 0) { $available += 'docker' }
    }
    if (Get-Command 'podman' -ErrorAction SilentlyContinue) {
        $null = podman info 2>&1
        if ($LASTEXITCODE -eq 0) { $available += 'podman' }
    }

    # Hyper-V steht nur dann als Provider bereit, wenn es in dieser Sitzung
    # vollständig nutzbar ist (Cmdlets vorhanden, erhöhte Sitzung, Host offen).
    $hyperv = Test-HyperVAvailable
    if ($hyperv.Available) { $available += 'hyperv' }

    # Hyper-V wird nur angeboten, wenn der Provider verfügbar ist.
    return @($available | Sort-Object -Unique)
}

function Get-LabRunSelectorPresentation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [string]$RuntimeState,
        [switch]$Protected,
        [switch]$SystemService
    )

    $runId = [string]$Run.runId
    $shortRunId = if ($runId.Length -gt 8) { $runId.Substring(0, 8) + '...' } else { $runId }
    $name = [string]$Run.metadata.name
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Unbenannte Umgebung' }

    $providers = @(
        @($Run.providerSubRuns | ForEach-Object { [string]$_.provider })
        @($Run.metadata.desiredState.Instances | ForEach-Object { [string]$_.Provider })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
    $workflowKind = [string]$Run.metadata.workflowKind
    $baseKind = [string]$Run.metadata.baseKind
    if ($workflowKind -eq 'hyperv-lab' -and $providers -notcontains 'hyperv') {
        $providers = @($providers) + 'hyperv'
    }

    $role = if ($SystemService) {
        'CMS-Systemdienst'
    }
    elseif ($Protected) {
        'Automatisierte Testumgebung'
    }
    elseif ($workflowKind -eq 'hyperv-lab' -and $baseKind -eq 'windows-baseline' -and $null -eq $Run.metadata.desiredState) {
        'Hyper-V-Windows-Slot'
    }
    elseif ($workflowKind -eq 'hyperv-lab') {
        'Hyper-V-Umgebung'
    }
    else {
        'Lab-Umgebung'
    }

    $details = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($RuntimeState)) { $details.Add($RuntimeState.ToUpperInvariant()) }
    $details.Add($role)
    if (@($providers).Count -gt 0) { $details.Add(('Provider {0}' -f (@($providers) -join '/'))) }
    if (-not [string]::IsNullOrWhiteSpace($shortRunId)) { $details.Add(('Run {0}' -f $shortRunId)) }
    if ($SystemService) { $details.Add('unter Datenbanken und Verbindungen verwalten') }
    elseif ($Protected) { $details.Add('nur als Testgruppe verwaltbar') }

    [pscustomobject]@{
        Label = $name
        Value = ($details -join ' | ')
    }
}

function Select-LabRun {
    param(
        [Parameter(Mandatory)][array]$Runs,
        [string]$Prompt = "Auswahl",
        [switch]$DisableAutomatedTestEnvironments,
        [switch]$DisableSystemServices
    )

    $protectedRunIds = if ($DisableAutomatedTestEnvironments) { @(Get-LabAutomatedTestEnvironmentRunIds) } else { @() }
    $cmsRunId = try { [string](Get-LabConnectionCenterCmsConfiguration).RunId } catch { '' }
    $singleRunIsSystemService = -not [string]::IsNullOrWhiteSpace($cmsRunId) -and [string]$Runs[0].runId -eq $cmsRunId
    if ($Runs.Count -eq 1 -and [string]$Runs[0].runId -notin $protectedRunIds -and -not ($DisableSystemServices -and $singleRunIsSystemService)) {
        $presentation = Get-LabRunSelectorPresentation -Run $Runs[0] -RuntimeState ([string]$Runs[0].runtime.state) -SystemService:$singleRunIsSystemService
        Write-LabInfo ("Einzige Umgebung: {0} ({1})" -f $presentation.Label, $presentation.Value)
        return $Runs[0].runId
    }

    while ($true) {
        $items = for ($i = 0; $i -lt $Runs.Count; $i++) {
            $synced = Sync-LabRunRuntimeState -Run $Runs[$i]
            $protected = [string]$Runs[$i].runId -in $protectedRunIds
            $systemService = -not [string]::IsNullOrWhiteSpace($cmsRunId) -and [string]$Runs[$i].runId -eq $cmsRunId
            $presentation = Get-LabRunSelectorPresentation -Run $Runs[$i] -RuntimeState ([string]$synced.Runtime.State) -Protected:$protected -SystemService:$systemService
            New-LabConsoleItem -Id ([string]$Runs[$i].runId) -Label $presentation.Label -Value $presentation.Value -Shortcut ([string]($i + 1)) -Data $Runs[$i] -Disabled:($protected -or ($DisableSystemServices -and $systemService))
        }
        $result = Invoke-LabConsoleMenu -ScreenId 'active-run-selection' -Title $Prompt -Subtitle 'Aktive SQL_Server_Lab-Umgebungen' -Items $items -Footer 'Pfeile: Navigation  Enter: Auswahl  F5: Runtime-Status aktualisieren  Esc: Zurueck' -FallbackPrompt "  $Prompt (Nummer)"
        if ($result.Status -eq 'Refresh') { continue }
        if ($result.Status -eq 'Selected') { return [string]$result.SelectedItem.Id }
        if ($result.Status -eq 'Invalid') { Write-LabWarning 'Ungueltige Auswahl.' }
        return $null
    }
}

function Set-LabResourcesInteractive {
    <#
    .SYNOPSIS
        Ändert CPU und Speicher einer Docker-, Podman- oder Hyper-V-Umgebung.
    .DESCRIPTION
        Die angezeigten Werte stammen aus der Runtime. Container werden direkt
        aktualisiert; eine Hyper-V-VM muss vor der Änderung ausgeschaltet sein.
    #>
    [CmdletBinding()]
    param([string]$RunId)

    $runs = @(Get-LabActiveRuns)
    if ($runs.Count -eq 0) { Write-LabInfo 'Keine aktiven Lab-Umgebungen vorhanden.'; return }
    if (-not $RunId) { $RunId = Select-LabRun -Runs $runs -Prompt 'Umgebung für CPU/Speicher' -DisableAutomatedTestEnvironments -DisableSystemServices }
    if (-not $RunId) { return }
    if (Test-LabAutomatedTestEnvironmentRun -RunId $RunId) { Write-LabWarning 'Automatisierte Testumgebungen sind als Gruppe geschützt; Ressourcenänderung ist gesperrt.'; return }

    try {
        $run = Get-LabRunState -RunId $RunId
        $resources = Get-LabEnvironmentResources -RunId $RunId
        $instances = @($resources.Instances | Where-Object { $_.Available -ne $false })
        if ($instances.Count -eq 0) {
            Write-LabError 'Die Runtime-Objekte dieser Umgebung sind nicht erreichbar.'
            $null = Wait-LabConsoleAcknowledgement
            return
        }
        $first = $instances[0]
        $isHyperV = [string]$run.metadata.workflowKind -eq 'hyperv-lab'
        $memory = if ($isHyperV) { [int]$first.MemoryStartupMB } else { [int]$first.MemoryLimitMB }
        $cpu = if ($first.ProcessorCount) { [int][math]::Ceiling([decimal]$first.ProcessorCount) } else { 4 }

        Write-Host ''
        Write-Host "  Ressourcen: $($run.metadata.name)" -ForegroundColor Cyan
        foreach ($instance in $instances) {
            $instanceMemory = if ($isHyperV) { $instance.MemoryStartupMB } else { $instance.MemoryLimitMB }
            Write-Host "    $($instance.Provider): $instanceMemory MB · $($instance.ProcessorCount) CPU · $($instance.RuntimeState)" -ForegroundColor DarkGray
        }
        if ($isHyperV -and [string]$first.RuntimeState -ne 'Off') {
            Write-LabWarning 'Hyper-V-Ressourcen können sicher nur bei ausgeschalteter VM geändert werden. Zuerst im Verwalten-Menü stoppen.'
            $null = Wait-LabConsoleAcknowledgement
            return
        }
        Write-Host '  Container übernehmen die Limits sofort; Hyper-V erhält einen dynamischen Bereich von mindestens 1 GB/halber Startwert bis zum Doppelten.' -ForegroundColor DarkGray
        $newMemory = Read-Host "  Neuer Speicher in MB [$memory]"
        if (-not $newMemory) { $newMemory = $memory }
        $newCpu = Read-Host "  Neue CPU-Anzahl [$cpu]"
        if (-not $newCpu) { $newCpu = $cpu }
        if ($newMemory -notmatch '^\d+$' -or [int]$newMemory -lt 512 -or $newCpu -notmatch '^\d+$' -or [int]$newCpu -lt 1 -or [int]$newCpu -gt 64) {
            Write-LabError 'Ungültige Ressourcenwerte. Speicher mindestens 512 MB, CPU 1 bis 64.'
            $null = Wait-LabConsoleAcknowledgement
            return
        }
        if (-not (Read-LabConfirm -Prompt '  Ressourcen jetzt am Runtime-Objekt ändern?' -Default $false)) { return }
        $result = Set-LabEnvironmentResources -RunId $RunId -MemoryMB ([int]$newMemory) -ProcessorCount ([int]$newCpu)
        if ($result.NoChange) { Write-LabInfo "Ressourcen unverändert: $($result.Provider), $newMemory MB, $newCpu CPU." }
        else { Write-LabSuccess "Ressourcen aktualisiert: $($result.Provider), $newMemory MB, $newCpu CPU." }
        $null = Wait-LabConsoleAcknowledgement
    }
    catch {
        Write-LabError $_.Exception.Message
        $null = Wait-LabConsoleAcknowledgement
    }
}

function Manage-LabEnvironmentInteractive {
    <#
    .SYNOPSIS
        Einheitlicher Einstieg zur Verwaltung aller Laufzeitprovider.
    .DESCRIPTION
        Führt Docker und Podman direkt; Hyper-V wechselt erst nach der Auswahl
        in seine zusätzlichen Windows-/SQL-spezifischen Aktionen.
    #>
    [CmdletBinding()]
    param()

    $runs = @(Get-LabActiveRuns)
    if ($runs.Count -eq 0) { Write-LabInfo 'Keine aktiven Lab-Umgebungen vorhanden.'; return }
    $runId = Select-LabRun -Runs $runs -Prompt 'Umgebung verwalten' -DisableAutomatedTestEnvironments -DisableSystemServices
    if (-not $runId) { return }
    $run = Get-LabRunState -RunId $runId
    if ([string]$run.metadata.workflowKind -eq 'hyperv-lab') {
        Manage-LabHyperVEnvironmentInteractive -RunId $runId
        return
    }

    $synced = Sync-LabRunRuntimeState -Run $run
    $connectionLabel = @((Get-LabRunConnectionStrings -RunId $runId) | ForEach-Object Value) -join ', '
    $actionItems = @(
        New-LabConsoleItem -Id 'lifecycle' -Label 'Starten oder stoppen' -Value 'abhängig vom aktuellen Zustand' -Shortcut 's'
        New-LabConsoleItem -Id 'resources' -Label 'CPU und Speicher aendern' -Value 'Docker-/Podman-Limits' -Shortcut 'r'
        New-LabConsoleItem -Id 'rename' -Label 'Anzeigename aendern' -Shortcut 'n'
        New-LabConsoleItem -Id 'remove' -Label 'Umgebung entfernen' -Value 'erfordert Bestaetigung' -Shortcut 'e'
    )
    $actionResult = Invoke-LabConsoleMenu -ScreenId 'environment-actions' -Title ("Umgebung verwalten: {0}" -f $run.metadata.name) -Subtitle ("Status: {0}{1}" -f $synced.Runtime.State, $(if ($connectionLabel) { " - SQL: $connectionLabel" } else { '' })) -Items $actionItems -Footer 'Pfeile: Navigation  Enter/Shortcut: Aktion  Esc: Zurueck' -FallbackPrompt '  Aktion (Buchstabe)'
    if ($actionResult.Status -ne 'Selected') { return }
    $action = [string]$actionResult.SelectedItem.Shortcut
    $actionBefore = Get-LabWorkflowLifecycleFingerprint
    $connectionCenterImpact = switch ($action) {
        's' { 'RuntimeState'; break }
        'n' { 'DisplayMetadata'; break }
        'e' { 'EndpointSet'; break }
        default { 'None' }
    }
    try {
        switch ($action) {
            's' { if ([string]$synced.Runtime.State -eq 'RUNNING') { Stop-SqlServerLab -RunId $runId } else { Start-SqlServerLab -RunId $runId } }
            'r' { Set-LabResourcesInteractive -RunId $runId }
            'n' {
                $name = Read-Host "  Neuer Anzeigename [$($run.metadata.name)]"
                if ($name) { $renamed = Rename-ContainerLabEnvironment -RunId $runId -DisplayName $name; Write-LabSuccess "Umbenannt: $($renamed.Name)" }
            }
            'e' { if (Read-LabConfirm -Prompt '  Umgebung wirklich entfernen?' -Default $false) { Remove-SqlServerLab -RunId $runId -Force } }
            default { Write-LabWarning 'Ungültige Aktion.' }
        }
    }
    catch {
        Write-LabError $_.Exception.Message
        return New-LabActionResult -Action Manage -Status Failed -ErrorCode 'LAB_CONTAINER_MANAGE_ACTION_FAILED'
    }

    $actionAfter = Get-LabWorkflowLifecycleFingerprint
    $status = if ($actionBefore -ne $actionAfter) { 'Changed' } else { 'NoChange' }
    return New-LabActionResult -Action Manage -Status $status -ConnectionCenterImpact $connectionCenterImpact
}

function Rename-LabEnvironmentInteractive {
    <#
    .SYNOPSIS
        Ändert den Anzeigenamen einer laufenden oder gestoppten Lab-Umgebung.
    .DESCRIPTION
        Die Runtime-Objekte werden zusammen mit den Metadaten als
        <Name>-<RunId-Präfix> umbenannt. Bei Hyper-V ist das nur für eine
        ausgeschaltete VM möglich; Docker und Podman erlauben es auch laufend.
    #>
    [CmdletBinding()]
    param()

    $runs = @(Get-LabActiveRuns)
    if ($runs.Count -eq 0) { Write-LabInfo 'Keine aktiven Lab-Umgebungen vorhanden.'; return }
    $runId = Select-LabRun -Runs $runs -Prompt 'Umgebung zum Umbenennen' -DisableAutomatedTestEnvironments -DisableSystemServices
    if (-not $runId) { return }
    $run = Get-LabRunState -RunId $runId
    $currentName = [string]$run.metadata.name
    $newName = Read-Host "  Neuer Anzeigename [$currentName]"
    if (-not $newName) { Write-LabInfo 'Name unverändert.'; return }
    try {
        $renamed = if ([string]$run.metadata.workflowKind -eq 'hyperv-lab') {
            Rename-HyperVLabEnvironment -RunId $runId -DisplayName $newName
        }
        else {
            Rename-ContainerLabEnvironment -RunId $runId -DisplayName $newName
        }
        if ($renamed.Changed) {
            Write-LabSuccess "Umgebung umbenannt: $($renamed.PreviousName) -> $($renamed.Name)"
            if ($renamed.PSObject.Properties['VMRenamed'] -and $renamed.VMRenamed) { Write-LabInfo "Hyper-V-VM umbenannt: $($renamed.PreviousVMName) -> $($renamed.VMName)" }
            if ($renamed.PSObject.Properties['RuntimeRenamed'] -and $renamed.RuntimeRenamed) { Write-LabInfo 'Docker-/Podman-Container wurden synchron umbenannt.' }
        }
        else { Write-LabInfo 'Name unverändert.' }
    }
    catch { Write-LabError $_.Exception.Message }
}
