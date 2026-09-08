#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Private/Common.ps1')
. (Join-Path $repoRoot 'Private/ConsoleUi.ps1')
. (Join-Path $repoRoot 'Private/ConsoleHelp.ps1')
. (Join-Path $repoRoot 'Public/BatchConsole.ps1')
. (Join-Path $repoRoot 'Public/Sync-SqlServerLabConnectionCenter.ps1')

$passed = 0
$failed = 0
function Add-ConsoleUiCheck {
    param([string]$Name, [bool]$Success)
    if ($Success) { $script:passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}

Write-Host "`nSQL_Server_Lab - Console UI Checks" -ForegroundColor Cyan
$statusLine = @(& { Write-LabStatus -Label 'Nicht pruefbare Provider' -Value '0' } 6>&1) -join ''
Add-ConsoleUiCheck 'Statuszeilen trennen auch lange Labels sichtbar vom Wert' ($statusLine -match 'Provider\s+0')
$previousConsoleMode = $script:LabConsoleMode
$script:LabConsoleMode = 'Fallback'
$forcedFallbackCapability = Test-LabConsoleCapability
$script:LabConsoleMode = $previousConsoleMode
Add-ConsoleUiCheck 'Diagnostischer ConsoleMode erzwingt Fallback ohne Host-Raten' (
    -not $forcedFallbackCapability.Supported -and
    $forcedFallbackCapability.Mode -eq 'READ_HOST' -and
    @($forcedFallbackCapability.Reasons) -contains 'FORCED_FALLBACK'
)

$ctrlCKey = [PSCustomObject]@{ Key='C'; KeyChar=[char]3; Modifiers=[ConsoleModifiers]::Control }
Add-ConsoleUiCheck 'Ctrl+C wird als globaler Pipeline-Interrupt erkannt' (Test-LabConsoleInterruptKey -Key $ctrlCKey)

# CUI-023: Meldungen sind Daten. Ein Neuzeichnen darf keine Warnung oder Fehlermeldung vernichten.
$previousSecret = [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_SECRET_CUI_TEST', 'Process')
try {
    [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_SECRET_CUI_TEST', 'Geheim_Kennwort_42', 'Process')
    $errorOutput = @(& { Write-LabError 'LAB_MESSAGE_JOURNAL_TEST_CODE: Fehler mit Geheim_Kennwort_42 im Text.' } 6>&1) -join ''
    $warningOutput = @(& { Write-LabWarning 'Verbindung nutzt SA_PASSWORD: hunter2' } 6>&1) -join ''
    $errorRecord = @(Get-LabMessage -Severity Error)[-1]
    $warningRecord = @(Get-LabMessage -Severity Warning)[-1]

    Add-ConsoleUiCheck 'Fehler und Warnung landen mit stabiler MessageId im Meldungsjournal' (
        $errorRecord.contract -eq 'SqlServerLab.Message/1.0' -and
        $errorRecord.messageId -match '^E-[0-9a-f]{4}$' -and
        $warningRecord.messageId -match '^W-[0-9a-f]{4}$' -and
        $errorOutput -match [regex]::Escape($errorRecord.messageId) -and
        $warningOutput -match [regex]::Escape($warningRecord.messageId)
    )
    Add-ConsoleUiCheck 'Fehlercode wird ohne Zusatzangabe aus der Meldung uebernommen' (
        $errorRecord.code -eq 'LAB_MESSAGE_JOURNAL_TEST_CODE'
    )
    Add-ConsoleUiCheck 'Secrets werden vor Journal und Anzeige entfernt' (
        $errorRecord.message -notmatch 'Geheim_Kennwort_42' -and $errorOutput -notmatch 'Geheim_Kennwort_42' -and
        $warningRecord.message -notmatch 'hunter2' -and $warningOutput -notmatch 'hunter2' -and
        $errorRecord.message -match '\*\*\*'
    )
    $report = Format-LabMessageReport -Message @($errorRecord)
    Add-ConsoleUiCheck 'Meldungsbericht bleibt als Klartext kopierbar und nennt Code und Modulstand' (
        $report -match [regex]::Escape($errorRecord.messageId) -and
        $report -match 'LAB_MESSAGE_JOURNAL_TEST_CODE' -and
        $report -match '(?m)^Modul\s' -and $report -notmatch 'Geheim_Kennwort_42'
    )
    Add-ConsoleUiCheck 'Meldung bleibt nach dem Rendern ueber die MessageId auffindbar' (
        @(Get-LabMessage -MessageId $errorRecord.messageId).Count -eq 1
    )

    $blockSession = [PSCustomObject]@{ OriginTop=4; PreviousLineCount=7; ForegroundColor='Gray' }
    $blockPlan = Get-LabConsolePersistentBlockPlan -Session $blockSession -Line @('kurz', 'zweite Zeile') -Width 20 -Height 25
    Add-ConsoleUiCheck 'Persistenzblock loescht den Rahmen vollstaendig und bleibt in der Breite' (
        $blockPlan.ClearRows -eq 7 -and $blockPlan.ClearText.Length -eq 19 -and
        $blockPlan.Lines.Count -eq 2 -and @($blockPlan.Lines | Where-Object { $_.Length -gt 19 }).Count -eq 0
    )
    $shortSession = [PSCustomObject]@{ OriginTop=0; PreviousLineCount=40; ForegroundColor='Gray' }
    $shortPlan = Get-LabConsolePersistentBlockPlan -Session $shortSession -Line @('x') -Width 20 -Height 10
    Add-ConsoleUiCheck 'Persistenzblock loescht nie ueber den sichtbaren Bereich hinaus' ($shortPlan.ClearRows -eq 10)
}
finally { [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_SECRET_CUI_TEST', $previousSecret, 'Process') }

$consoleUiSource = Get-Content (Join-Path $repoRoot 'Private/ConsoleUi.ps1') -Raw
Add-ConsoleUiCheck 'Persistenzblock verankert den Rahmen unter der Ausgabe statt sie zu ueberschreiben' (
    $consoleUiSource -match '\$Session\.OriginTop = \[Console\]::CursorTop' -and
    $consoleUiSource -match 'Write-LabConsoleMessageBlock' -and
    $consoleUiSource -match 'Format-LabMessageReport'
)

# CUI-022: Der Statusbereich hat feste Hoehe und darf das Menue nie verschieben.
$bandState = New-LabConsoleState -ScreenId 'status-band' -Items @(
    New-LabConsoleItem -Id 'a' -Label 'Alpha' -Shortcut '1'
    New-LabConsoleItem -Id 'b' -Label 'Beta' -Shortcut '2'
) -SelectedId 'a'
$idleFrame = Get-LabConsoleFrame -State $bandState -Title 'Band' -Status @() -StatusHeight 3 -Width 60 -Height 14
$busyFrame = Get-LabConsoleFrame -State $bandState -Title 'Band' -Status @('erste', 'zweite') -StatusHeight 3 -Width 60 -Height 14
Add-ConsoleUiCheck 'Statusband bleibt auch leer reserviert und haelt den Viewport konstant' (
    $idleFrame.StatusHeight -eq 3 -and $busyFrame.StatusHeight -eq 3 -and
    $idleFrame.Lines.Count -eq $busyFrame.Lines.Count -and
    $idleFrame.ViewportHeight -eq $busyFrame.ViewportHeight
)
$idleMenuRows = @(0..($idleFrame.Lines.Count - 1) | Where-Object { $idleFrame.Lines[$_] -match 'Alpha' })
$busyMenuRows = @(0..($busyFrame.Lines.Count - 1) | Where-Object { $busyFrame.Lines[$_] -match 'Alpha' })
Add-ConsoleUiCheck 'Fortschrittsausgabe verschiebt keine Menuezeile und ueberschreibt keinen Eintrag' (
    $idleMenuRows.Count -eq 1 -and $busyMenuRows.Count -eq 1 -and $idleMenuRows[0] -eq $busyMenuRows[0] -and
    @($busyFrame.Lines | Where-Object { $_ -match '^erste' }).Count -eq 1
)
$noBandFrame = Get-LabConsoleFrame -State $bandState -Title 'Band' -Width 60 -Height 14
Add-ConsoleUiCheck 'Bildschirme ohne Statusband behalten ihr bisheriges Layout' (
    $noBandFrame.StatusHeight -eq 0 -and $noBandFrame.ViewportHeight -eq ($idleFrame.ViewportHeight + 3)
)

$determinateOperation = [PSCustomObject]@{
    itemId='SQL2025latest'; progress=48; currentStep=1; startedAt=([datetime]'2026-09-07T12:00:00Z')
    updatedAt=([datetime]'2026-09-07T12:01:10Z')
    steps=@(
        [PSCustomObject]@{ id='create-runtime'; title='Container erstellen'; status='Completed' }
        [PSCustomObject]@{ id='wait'; title='Image laden'; status='Running' }
        [PSCustomObject]@{ id='complete'; title='Abschluss'; status='Pending' }
    )
}
$determinateStatus = Format-LabProgressStatus -Operation $determinateOperation -Width 78 -Now ([datetime]'2026-09-07T12:01:14Z')
Add-ConsoleUiCheck 'Bestimmbarer Fortschritt zeigt Balken, Prozent und Schrittzaehler' (
    $determinateStatus.Determinate -and -not $determinateStatus.Stalled -and
    $determinateStatus.Lines[0] -match '\[.+\]\s+48%' -and $determinateStatus.Lines[0] -match 'Image laden' -and
    $determinateStatus.Lines[1] -match 'Schritt 2/3' -and $determinateStatus.Lines[1] -match '01:14'
)

$indeterminateOperation = [PSCustomObject]@{
    itemId='win2025-slot-1'; progress=[double]::NaN; currentStep=0
    startedAt=([datetime]'2026-09-07T12:00:00Z'); updatedAt=([datetime]'2026-09-07T12:04:00Z')
    steps=@([PSCustomObject]@{ id='setup'; title='Windows-Setup'; status='Running' })
    probe=[PSCustomObject]@{ failures=5 }
}
$firstTick = Format-LabProgressStatus -Operation $indeterminateOperation -Tick 0 -Width 78 -Now ([datetime]'2026-09-07T12:04:52Z')
$secondTick = Format-LabProgressStatus -Operation $indeterminateOperation -Tick 1 -Width 78 -Now ([datetime]'2026-09-07T12:04:52Z')
Add-ConsoleUiCheck 'Unbestimmter Vorgang beweist Lebendigkeit ueber Heartbeat, Laufzeit und Versuchszaehler' (
    -not $firstTick.Determinate -and $firstTick.Lines[0] -match '04:52' -and
    $firstTick.Lines[0] -ne $secondTick.Lines[0] -and $firstTick.Lines[1] -match 'Versuch 6'
)
$stalledStatus = Format-LabProgressStatus -Operation $indeterminateOperation -Width 78 -Now ([datetime]'2026-09-07T12:12:00Z') -StalledAfterSeconds 300
Add-ConsoleUiCheck 'Stillstand wird benannt statt endlos gedreht' (
    $stalledStatus.Stalled -and $stalledStatus.Lines[1] -match 'keine Aenderung seit 08:00'
)

$emptyBand = Get-LabConsoleStatusBand -Operation @() -Width 78 -Height 3
$filledBand = Get-LabConsoleStatusBand -Operation @($determinateOperation, $indeterminateOperation) -Width 78 -Height 3 -Now ([datetime]'2026-09-07T12:01:14Z')
Add-ConsoleUiCheck 'Statusband liefert immer exakt die reservierte Zeilenzahl' (
    $emptyBand.Count -eq 3 -and $filledBand.Count -eq 3 -and
    $emptyBand[0] -match 'Bereit' -and $filledBand[0] -match 'SQL2025latest'
)
$headlineBand = Get-LabConsoleStatusBand -Operation @($determinateOperation) -Width 78 -Height 3 `
    -Now ([datetime]'2026-09-07T12:01:14Z') -Headline 'Queue 4 · Worker 1/2 · Blockiert 2'
$headlineIdleBand = Get-LabConsoleStatusBand -Operation @() -Width 78 -Height 3 -Headline 'Queue 0 · Worker 0/2 · Blockiert 0'
Add-ConsoleUiCheck 'Statusband fuehrt die Kopfzeile ueber Laufzeit und Leerlauf hinweg in fester Hoehe' (
    $headlineBand.Count -eq 3 -and $headlineIdleBand.Count -eq 3 -and
    $headlineBand[0] -match 'Queue 4 · Worker 1/2 · Blockiert 2' -and
    $headlineBand[1] -match 'SQL2025latest' -and
    $headlineIdleBand[0] -match 'Queue 0 · Worker 0/2 · Blockiert 0' -and
    $headlineIdleBand[1] -match 'Bereit'
)
Add-ConsoleUiCheck 'Fortschrittsbalken und Heartbeat bleiben ohne UTF-8-Konsole darstellbar' (
    $consoleUiSource -match 'Test-LabConsoleUnicodeSupport' -and
    $consoleUiSource -match "CodePage -eq 65001" -and
    (Get-LabProgressBar -Percent 50 -Width 10).Length -eq 10
)

$statusWritePlan = Get-LabConsoleStatusWritePlan -Frame $busyFrame -Status @('nur eine Zeile')
Add-ConsoleUiCheck 'Statusaktualisierung schreibt ausschliesslich in die reservierten Zeilen' (
    $statusWritePlan.Count -eq 3 -and
    $statusWritePlan[0].Row -eq $busyFrame.StatusOffset -and
    $statusWritePlan[-1].Row -eq ($busyFrame.StatusOffset + 2) -and
    $busyFrame.Lines[$busyFrame.StatusOffset] -match '^erste' -and
    @($statusWritePlan | Where-Object { $_.Text.Length -ne $busyFrame.Width }).Count -eq 0
)

# CUI-029: Ein deaktivierter Eintrag muss als solcher erkennbar bleiben, auch wenn der Grund lang ist.
$longReason = 'Schritte werden immer vollstaendig angezeigt; es wartet gerade kein Vorgang auf eine ausdrueckliche Benutzerbestaetigung.'
$disabledItemText = Get-LabConsoleItemText -Width 92 -Focus ' ' -Shortcut '[2] ' `
    -Item (New-LabConsoleItem -Id 'gates' -Label 'Benutzeraktionen oeffnen' -Value 'Schritte werden immer vollstaendig angezeigt' -Disabled -DisabledReason $longReason)
$narrowItemText = Get-LabConsoleItemText -Width 40 -Focus ' ' -Shortcut '[2] ' `
    -Item (New-LabConsoleItem -Id 'gates' -Label 'Benutzeraktionen oeffnen' -Disabled -DisabledReason $longReason)
$enabledItemText = Get-LabConsoleItemText -Width 92 -Focus '>' -Shortcut '[r] ' `
    -Item (New-LabConsoleItem -Id 'run' -Label 'Scheduler jetzt ausfuehren' -Value '2 Worker')
Add-ConsoleUiCheck 'Deaktivierter Eintrag behaelt die Marke und zeigt den Grund statt eines abgeschnittenen Value' (
    $disabledItemText -match '\(nicht verfuegbar\)' -and
    $disabledItemText -match '\(nicht verfuegbar\) - Schritte werden' -and
    $disabledItemText.Length -le 92 -and
    $disabledItemText -notmatch 'Value'
)
Add-ConsoleUiCheck 'Auf schmalen Fenstern weicht der Grund, niemals die Marke' (
    $narrowItemText -match '\(nicht verfuegbar\)$' -and $narrowItemText.Length -le 40
)
Add-ConsoleUiCheck 'Aktiver Eintrag zeigt unveraendert Fokus, Shortcut und Value' (
    $enabledItemText -eq '> [r] Scheduler jetzt ausfuehren: 2 Worker'
)
Add-ConsoleUiCheck 'Rahmen und Statusband bereinigen die nicht beschreibbare letzte Spalte' (
    $consoleUiSource -match 'function Test-LabConsoleVirtualTerminal' -and
    $consoleUiSource -match 'SupportsVirtualTerminal' -and
    ([regex]::Matches($consoleUiSource, '\$eraseToEnd = if \(Test-LabConsoleVirtualTerminal\)')).Count -eq 2 -and
    ([regex]::Matches($consoleUiSource, '\[Console\]::Write\(\[string\]\$row\.Text \+ \$eraseToEnd\)')).Count -eq 2
)

$heartbeatTicks = [System.Collections.Generic.List[int]]::new()
$statusWrites = [System.Collections.Generic.List[string]]::new()
$keyProbeCalls = 0
$liveMenu = Invoke-LabConsoleMenu -ScreenId 'live-status' -Title 'Live' -Items @(
    New-LabConsoleItem -Id 'go' -Label 'Weiter' -Shortcut '1'
) -StatusHeight 2 -StatusIntervalMilliseconds 50 -Snapshot $null `
    -Capability ([PSCustomObject]@{ Supported=$true; Mode='CURSOR'; Reasons=@() }) `
    -StatusProvider { param($tick) $heartbeatTicks.Add([int]$tick); @("heartbeat $tick", '') } `
    -KeyAvailable { $script:keyProbeCalls++; $script:keyProbeCalls -gt 3 } `
    -StatusWriter { param($s, $f, $t) $statusWrites.Add([string]$t[0]) } `
    -ReadKey { [PSCustomObject]@{ Key='Enter'; KeyChar=[char]13; Modifiers=0 } } `
    -FrameWriter { param($s, $f) } -GetViewport { [PSCustomObject]@{ Width=60; Height=14 } } `
    -SessionFactory { [PSCustomObject]@{ OriginTop=0; PreviousLineCount=0; ForegroundColor='Gray' } } `
    -SessionCompleter { }
Add-ConsoleUiCheck 'Menue haelt den Heartbeat lebendig und reagiert danach sofort auf die Taste' (
    $liveMenu.Status -eq 'Selected' -and $liveMenu.SelectedItem.Id -eq 'go' -and
    $heartbeatTicks[0] -eq 0 -and $heartbeatTicks[-1] -eq ($heartbeatTicks.Count - 1) -and
    $statusWrites.Count -eq ($heartbeatTicks.Count - 1) -and $statusWrites[0] -eq 'heartbeat 1'
)

$blockingKeyReads = 0
$blockingMenu = Invoke-LabConsoleMenu -ScreenId 'blocking' -Title 'Blockierend' -Items @(
    New-LabConsoleItem -Id 'go' -Label 'Weiter' -Shortcut '1'
) -Snapshot $null `
    -Capability ([PSCustomObject]@{ Supported=$true; Mode='CURSOR'; Reasons=@() }) `
    -KeyAvailable { throw 'darf ohne StatusProvider nicht abgefragt werden' } `
    -ReadKey { $script:blockingKeyReads++; [PSCustomObject]@{ Key='Enter'; KeyChar=[char]13; Modifiers=0 } } `
    -FrameWriter { param($s, $f) } -GetViewport { [PSCustomObject]@{ Width=60; Height=14 } } `
    -SessionFactory { [PSCustomObject]@{ OriginTop=0; PreviousLineCount=0; ForegroundColor='Gray' } } `
    -SessionCompleter { }
Add-ConsoleUiCheck 'Bildschirme ohne Statusband warten unveraendert blockierend ohne Polling' (
    $blockingMenu.Status -eq 'Selected' -and $blockingKeyReads -eq 1
)

# CUI-024: Kontexthilfe je ScreenId, live geprueft, mit Begruendung deaktivierter Eintraege.
$helpCatalog = Get-LabConsoleHelpCatalog
$criticalScreens = @('main-menu', 'queue-menu', 'environment-menu', 'environment-actions',
    'sql-target-configuration', 'batch-composer', 'create-menu', 'create-sa-password', 'cms-menu',
    'infrastructure-menu', 'maintenance-menu', 'settings-menu', 'storage-menu', 'database-menu',
    'connection-center', 'hyperv-menu', 'system-menu')
Add-ConsoleUiCheck 'Alle Bildschirme des kritischen Pfads besitzen einen kuratierten Hilfeeintrag' (
    @($criticalScreens | Where-Object { -not $helpCatalog.ContainsKey($_) }).Count -eq 0 -and
    @($criticalScreens | Where-Object { -not $helpCatalog[$_].Purpose -or -not $helpCatalog[$_].Title }).Count -eq 0
)

$screenIdPattern = '-ScreenId\s+[''"]([^''"]+)[''"]'
$usedScreenIds = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Public') -Filter '*.ps1' -File -Recurse
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Private') -Filter '*.ps1' -File -Recurse
) | Select-String -Pattern $screenIdPattern -AllMatches |
    ForEach-Object { $_.Matches.Groups[1].Value } |
    Sort-Object -Unique
$uncuratedScreenIds = @($usedScreenIds | Where-Object {
    $topic = Get-LabConsoleHelpTopic -ScreenId $_
    -not $topic.Curated -or -not $topic.Title -or -not $topic.Purpose -or -not $topic.Effects
})
Add-ConsoleUiCheck 'Alle statisch verwendeten ScreenIds besitzen kuratierte Hilfe mit Zweck und Folgewirkung' (
    $usedScreenIds.Count -gt 100 -and $uncuratedScreenIds.Count -eq 0 -and
    -not (Get-LabConsoleHelpTopic -ScreenId 'synthetic-uncurated-screen').Curated
)

$testCatalog = @{
    'demo' = @{
        Title = 'Demo'
        Purpose = 'Bildschirmzweck.'
        Effects = 'Folgewirkung.'
        Command = 'New-SqlServerLab'
        Related = @('Hinweis eins.')
        Preconditions = @(
            @{ Label = 'Erfuellt'; Test = { $true }; Fix = 'nichts zu tun' }
            @{ Label = 'Offen'; Test = { $false }; Fix = 'Konkrete Abhilfe.' }
            @{ Label = 'Fehlerhaft'; Test = { throw 'kaputt' }; Fix = 'Trotzdem sichtbar.' }
        )
        Items = @{ 'a' = @{ Purpose = 'Eintragszweck.'; Command = 'Get-SqlServerLabQueue' } }
    }
}
$screenTopic = Get-LabConsoleHelpTopic -ScreenId 'demo' -Catalog $testCatalog
$itemTopic = Get-LabConsoleHelpTopic -ScreenId 'demo' -Item (New-LabConsoleItem -Id 'a' -Label 'Alpha') -Catalog $testCatalog
Add-ConsoleUiCheck 'Hilfe unterscheidet Bildschirm- und Eintragszweck' (
    $screenTopic.Purpose -eq 'Bildschirmzweck.' -and $itemTopic.Purpose -eq 'Eintragszweck.' -and
    $itemTopic.Command -eq 'Get-SqlServerLabQueue' -and $itemTopic.Effects -eq 'Folgewirkung.'
)
Add-ConsoleUiCheck 'Voraussetzungen werden live ausgewertet und scheitern nicht an einer defekten Pruefung' (
    @($screenTopic.Preconditions).Count -eq 3 -and
    $screenTopic.Preconditions[0].Ok -and -not $screenTopic.Preconditions[1].Ok -and
    -not $screenTopic.Preconditions[2].Ok -and $screenTopic.Preconditions[2].Detail -match 'kaputt'
)

$disabledWithReason = Get-LabConsoleHelpTopic -ScreenId 'demo' -Catalog $testCatalog `
    -Item (New-LabConsoleItem -Id 'x' -Label 'Hyper-V' -Disabled -DisabledReason 'Hyper-V ist auf diesem Host nicht aktiviert.')
$disabledWithoutReason = Get-LabConsoleHelpTopic -ScreenId 'demo' -Catalog $testCatalog `
    -Item (New-LabConsoleItem -Id 'y' -Label 'Ohne Grund' -Disabled)
Add-ConsoleUiCheck 'Deaktivierte Eintraege nennen immer einen Grund oder weisen die Luecke aus' (
    $disabledWithReason.DisabledReason -eq 'Hyper-V ist auf diesem Host nicht aktiviert.' -and
    $disabledWithoutReason.DisabledReason -match 'noch nicht hinterlegt'
)

$unknownTopic = Get-LabConsoleHelpTopic -ScreenId 'gibt-es-nicht' -Catalog $testCatalog
Add-ConsoleUiCheck 'Unbekannte Bildschirme liefern eine ehrliche generische Auskunft statt eines Fehlers' (
    -not $unknownTopic.Curated -and $unknownTopic.ScreenId -eq 'gibt-es-nicht' -and
    $unknownTopic.Purpose -match 'noch keine Hilfe'
)

$helpText = Format-LabConsoleHelp -Topic $disabledWithReason -Width 70
Add-ConsoleUiCheck 'Hilfetext nennt Grund, Zweck, offene Voraussetzung samt Abhilfe und Befehl' (
    @($helpText | Where-Object { $_ -match 'Nicht verfuegbar, weil' }).Count -eq 1 -and
    @($helpText | Where-Object { $_ -match 'Hyper-V ist auf diesem Host nicht aktiviert' }).Count -eq 1 -and
    @($helpText | Where-Object { $_ -match '^\s+\[!\]\s+Offen' }).Count -eq 1 -and
    @($helpText | Where-Object { $_ -match 'Abhilfe: Konkrete Abhilfe' }).Count -eq 1 -and
    @($helpText | Where-Object { $_ -match 'New-SqlServerLab' }).Count -eq 1 -and
    @($helpText | Where-Object { $_.Length -gt 70 }).Count -eq 0
)

$longTopic = Get-LabConsoleHelpTopic -ScreenId 'queue-menu' -Item (New-LabConsoleItem -Id 'run' -Label 'Scheduler')
$wrappedHelp = Format-LabConsoleHelp -Topic $longTopic -Width 60
Add-ConsoleUiCheck 'Lange Hilfetexte werden umgebrochen statt abgeschnitten' (
    @($wrappedHelp | Where-Object { $_ -match '\.\.\.$' }).Count -eq 0 -and
    @($wrappedHelp | Where-Object { $_.Length -gt 60 }).Count -eq 0 -and
    ($wrappedHelp -join ' ') -match 'SQL_SERVER_LAB_SECRET_\*-Prozessvariable'
)

$helpFrames = [System.Collections.Generic.List[object]]::new()
$helpMenuKeys = [System.Collections.Generic.Queue[object]]::new()
@(
    [PSCustomObject]@{ Key='F1'; KeyChar=[char]0; Modifiers=0 }
    [PSCustomObject]@{ Key='Spacebar'; KeyChar=' '; Modifiers=0 }
    [PSCustomObject]@{ Key='Enter'; KeyChar=[char]13; Modifiers=0 }
) | ForEach-Object { $helpMenuKeys.Enqueue($_) }
$helpMenu = Invoke-LabConsoleMenu -ScreenId 'main-menu' -Title 'Hauptmenue' -Items @(
    New-LabConsoleItem -Id 'create' -Label 'Umgebung erstellen' -Shortcut '1'
) -Snapshot $null -Capability ([PSCustomObject]@{ Supported=$true; Mode='CURSOR'; Reasons=@() }) `
    -ReadKey { $helpMenuKeys.Dequeue() } `
    -FrameWriter { param($s, $f) $helpFrames.Add($f) } `
    -GetViewport { [PSCustomObject]@{ Width=80; Height=24 } } `
    -SessionFactory { [PSCustomObject]@{ OriginTop=0; PreviousLineCount=0; ForegroundColor='Gray' } } `
    -SessionCompleter { }
$helpOverlay = @($helpFrames | Where-Object { @($_.Lines | Where-Object { $_ -match '^Hilfe: ' }).Count -eq 1 })
Add-ConsoleUiCheck 'F1 oeffnet die Kontexthilfe zum markierten Eintrag und kehrt danach ins Menue zurueck' (
    $helpOverlay.Count -eq 1 -and
    @($helpOverlay[0].Lines | Where-Object { $_ -match 'Eintrag Umgebung erstellen' }).Count -eq 1 -and
    @($helpOverlay[0].Lines | Where-Object { $_ -match 'New-SqlServerLabBatch' }).Count -eq 1 -and
    $helpMenu.Status -eq 'Selected' -and $helpMenu.SelectedItem.Id -eq 'create'
)
Add-ConsoleUiCheck 'Hilfeoverlay behaelt die Rahmenhoehe und verschiebt das Menue nicht' (
    $helpOverlay[0].Lines.Count -eq 24 -and $helpFrames[-1].Lines.Count -eq 24
)
Add-ConsoleUiCheck 'Fusszeile weist die Kontexthilfe aus' (
    ([regex]::Matches($consoleUiSource, 'F1/\?: Hilfe')).Count -eq 2
)
$mainMenuSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1') -Raw
$batchConsoleSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/BatchConsole.ps1') -Raw
Add-ConsoleUiCheck 'Haupt- und Umgebungsmenue begruenden jeden deaktivierten Eintrag' (
    $batchConsoleSource -match "Id HyperVArea[\s\S]{0,300}?-DisabledReason \`$disabledReason" -and
    $batchConsoleSource -match 'Windows-Feature Hyper-V aktivieren' -and
    ([regex]::Matches($mainMenuSource, "New-LabConsoleItem -Id '(?:Manage|Status|SyncRuntime|Stop|Start|Restart|Rename|Resources|Remove|ClearAutomatedTestEnvironment)'[^\n]+-DisabledReason ")).Count -eq 10 -and
    $mainMenuSource -match "ScreenId 'main-menu'[^\n]+F1/\?: Hilfe"
)

function Get-ConsoleItemDisabledReasonViolation {
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)

    return @($Ast.FindAll({
        param($node)
        if ($node -isnot [System.Management.Automation.Language.CommandAst] -or
            $node.GetCommandName() -ne 'New-LabConsoleItem') { return $false }
        $parameterNames = @($node.CommandElements |
            Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
            ForEach-Object { $_.ParameterName })
        return 'Disabled' -in $parameterNames -and 'DisabledReason' -notin $parameterNames
    }, $true))
}

$disabledReasonViolations = @()
$consoleSourceFiles = @(
    Get-ChildItem -LiteralPath $repoRoot -Filter '*.ps1' -File
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Public') -Filter '*.ps1' -File -Recurse
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Private') -Filter '*.ps1' -File -Recurse
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Providers') -Filter '*.ps1' -File -Recurse
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Tools') -Filter '*.ps1' -File -Recurse
)
foreach ($sourceFile in $consoleSourceFiles) {
    $sourceTokens = $null
    $sourceErrors = $null
    $sourceAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $sourceFile.FullName, [ref]$sourceTokens, [ref]$sourceErrors)
    foreach ($violation in @(Get-ConsoleItemDisabledReasonViolation -Ast $sourceAst)) {
        $disabledReasonViolations += '{0}:{1}' -f $sourceFile.FullName, $violation.Extent.StartLineNumber
    }
}
$counterexampleTokens = $null
$counterexampleErrors = $null
$counterexampleAst = [System.Management.Automation.Language.Parser]::ParseInput(
    "New-LabConsoleItem -Id 'x' -Label 'X' -Disabled", [ref]$counterexampleTokens, [ref]$counterexampleErrors)
Add-ConsoleUiCheck 'Jeder deaktivierbare Produkt-Menueeintrag besitzt explizit einen DisabledReason' (
    $disabledReasonViolations.Count -eq 0 -and
    @(Get-ConsoleItemDisabledReasonViolation -Ast $counterexampleAst).Count -eq 1
)

# CUI-022: Vorgangs- und Hauptmenue nutzen den reservierten Statusbereich fuer echten Fortschritt.
Add-ConsoleUiCheck 'Vorgangsmenue reserviert das Statusband und liefert laufenden Fortschritt' (
    $batchConsoleSource -match "ScreenId 'queue-menu'[^\n]+-StatusHeight 5 -StatusProvider \`$statusProvider" -and
    $batchConsoleSource -match '\$statusProvider = New-LabQueueStatusProvider -Height 5'
)
Add-ConsoleUiCheck 'Hauptmenue zeigt laufenden Fortschritt im reservierten Statusband' (
    $mainMenuSource -match "ScreenId 'main-menu'[^\n]+-StatusHeight 3 -StatusProvider \`$mainMenuStatusProvider" -and
    $mainMenuSource -match '\$mainMenuStatusProvider = New-LabQueueStatusProvider -Height 3'
)
Add-ConsoleUiCheck 'Interaktive Sitzung verankert einen Statuslieferanten fuer alle untergeordneten Bildschirme' (
    $mainMenuSource -match '\$script:LabConsoleDefaultStatusProvider = New-LabQueueStatusProvider -Height 3' -and
    $mainMenuSource -match 'Remove-Variable -Name LabConsoleDefaultStatusProvider -Scope Script'
)
$ambientStatusTicks = [Collections.Generic.List[int]]::new()
$ambientFrames = [Collections.Generic.List[object]]::new()
$script:LabConsoleDefaultStatusProvider = { param($tick) $ambientStatusTicks.Add([int]$tick); @('Sitzungsstatus', '', '') }
try {
    $ambientMenu = Invoke-LabConsoleMenu -ScreenId 'ambient-status' -Title 'Untermenue' -Items @(
        New-LabConsoleItem -Id 'go' -Label 'Weiter' -Shortcut '1'
    ) -Capability ([PSCustomObject]@{ Supported=$true; Mode='CURSOR'; Reasons=@() }) `
        -ReadKey { [PSCustomObject]@{ Key='Enter'; KeyChar=[char]13; Modifiers=0 } } `
        -FrameWriter { param($s, $f) $ambientFrames.Add($f) } `
        -GetViewport { [PSCustomObject]@{ Width=60; Height=14 } } `
        -SessionFactory { [PSCustomObject]@{ OriginTop=0; PreviousLineCount=0; ForegroundColor='Gray' } } `
        -SessionCompleter { }
}
finally {
    Remove-Variable -Name LabConsoleDefaultStatusProvider -Scope Script -ErrorAction SilentlyContinue
}
Add-ConsoleUiCheck 'Untergeordnete Menues erben Statusband und echten Sitzungsstatus ohne Einzelverdrahtung' (
    $ambientMenu.Status -eq 'Selected' -and $ambientStatusTicks.Count -eq 1 -and
    $ambientFrames.Count -eq 1 -and $ambientFrames[0].StatusHeight -eq 3 -and
    @($ambientFrames[0].Lines | Where-Object { $_ -match '^Sitzungsstatus' }).Count -eq 1
)
Add-ConsoleUiCheck 'Hauptmenue folgt der acht Gruppen umfassenden Struktur' (
    ([regex]::Matches($mainMenuSource, "New-LabConsoleItem -Id '(?:create|environment|queue|database|cms|infrastructure|maintenance|settings)' -Label ")).Count -eq 8 -and
    ([regex]::Matches($mainMenuSource, "'(?:create|cms|infrastructure|maintenance|settings)' \{ Invoke-LabAreaMenuInteractive -Area ")).Count -eq 5 -and
    $mainMenuSource -notmatch "New-LabConsoleItem -Id 'plan' -Label" -and
    $mainMenuSource -notmatch "New-LabConsoleItem -Id 'system' -Label"
)

# CUI-023: Eine Warnung oder ein Fehler darf nicht vom naechsten Menueaufbau verdeckt werden.
Add-ConsoleUiCheck 'Jede Menueaktion zeigt neue Warnungen und Fehler erzwungen an' (
    $batchConsoleSource -match '\$marker = Get-LabMessageJournalMarker' -and
    $batchConsoleSource -match 'Show-LabActionMessagesInteractive -Marker \$marker' -and
    $batchConsoleSource -match "function Show-LabActionMessagesInteractive[\s\S]{0,900}?severity -in @\('Warning', 'Error'\)" -and
    $batchConsoleSource -match "function Show-LabActionMessagesInteractive[\s\S]{0,900}?Format-LabMessageReport -Message \`$new"
)
Add-ConsoleUiCheck 'Meldungen sind aus Hauptmenue und Wartung erreichbar und kopierbar' (
    $mainMenuSource -match "New-LabConsoleItem -Id 'messages' -Label 'Meldungen dieser Sitzung'" -and
    $mainMenuSource -match "'messages' \{ Show-LabMessagesInteractive \}" -and
    $batchConsoleSource -match "New-LabConsoleItem -Id Messages -Label 'Meldungen dieser Sitzung'" -and
    $batchConsoleSource -match "ScreenId 'messages'" -and
    $batchConsoleSource -match 'Copy-LabMessageReportToClipboard' -and
    $batchConsoleSource -match 'Set-Clipboard -Value \$report'
)
Add-ConsoleUiCheck 'Ein Host ohne Zwischenablage verweist auf das Journal statt zu scheitern' (
    $batchConsoleSource -match "Get-Command -Name Set-Clipboard -ErrorAction SilentlyContinue[\s\S]{0,200}?return \`$false" -and
    $batchConsoleSource -match 'Der Bericht steht im Meldungsjournal'
)
Add-ConsoleUiCheck 'Vorgangsmenue begruendet jeden deaktivierten Eintrag' (
    ([regex]::Matches($batchConsoleSource, "New-LabConsoleItem -Id '(?:overview|gates|bulk-confirm|priority|move|pause|stop|batch-stop|run)'[^\n]+-DisabledReason ")).Count -eq 9 -and
    $batchConsoleSource -match 'Ein Batch im Status Draft erscheint hier nicht'
)

$statusClock = [datetime]'2026-09-07T12:00:00Z'
$statusReads = 0
$runningOperation = [PSCustomObject]@{
    itemId='SQL2025latest'; status='Running'; progress=50; currentStep=1
    startedAt=([datetime]'2026-09-07T11:58:00Z'); updatedAt=([datetime]'2026-09-07T11:59:50Z')
    steps=@(
        [PSCustomObject]@{ id='create-runtime'; title='Container erstellen'; status='Completed' }
        [PSCustomObject]@{ id='complete'; title='Abschluss'; status='Running' }
    )
}
$queueProjection = [PSCustomObject]@{
    maxWorkers = 2; runningWorkers = 1
    items = @(
        [PSCustomObject]@{ operationId = 'a'; status = 'Running'; blockedReason = $null }
        [PSCustomObject]@{ operationId = 'b'; status = 'Queued'; blockedReason = 'Batch ist noch nicht uebergeben.' }
        [PSCustomObject]@{ operationId = 'c'; status = 'Queued'; blockedReason = '   ' }
    )
}
Add-ConsoleUiCheck 'Kopfzeile verdichtet Laenge, Worker und Blockierungen aus dem Queue-Vertrag' (
    (Get-LabQueueHeadline -Queue $queueProjection) -eq 'Queue 3 · Worker 1/2 · Blockiert 1' -and
    (Get-LabQueueHeadline -Queue $null) -match 'nicht lesbar'
)
$queueStatus = New-LabQueueStatusProvider -Height 5 -RefreshMilliseconds 1000 -Width 78 `
    -OperationReader { $script:statusReads++; @($runningOperation, [PSCustomObject]@{ itemId='fertig'; status='Completed' }) } `
    -QueueReader { $queueProjection } `
    -Clock { $script:statusClock }
$firstBand = & $queueStatus 0
$null = & $queueStatus 1
$null = & $queueStatus 2
$readsBeforeAdvance = $script:statusReads
$statusClock = $statusClock.AddSeconds(5)
$null = & $queueStatus 3
Add-ConsoleUiCheck 'Statuslieferant drosselt den State-Zugriff und liest erst nach Ablauf erneut' (
    $readsBeforeAdvance -eq 1 -and $script:statusReads -eq 2
)
Add-ConsoleUiCheck 'Statusband der Queue fuehrt die Kopfzeile und zeigt darunter nur laufende Vorgaenge' (
    $firstBand.Count -eq 5 -and
    $firstBand[0] -match 'Queue 3 · Worker 1/2 · Blockiert 1' -and
    $firstBand[1] -match 'SQL2025latest' -and
    @($firstBand | Where-Object { $_ -match 'fertig' }).Count -eq 0 -and
    $firstBand[1] -match '50%' -and $firstBand[2] -match 'Schritt 2/2'
)
Add-ConsoleUiCheck 'Eine nicht lesbare Queue benennt das statt die Kopfzeile leer zu lassen' (
    (& (New-LabQueueStatusProvider -Height 3 -Width 78 -OperationReader { @() } `
                -QueueReader { throw 'State-Store nicht erreichbar' } -Clock { $statusClock }) 0)[0] -match 'nicht lesbar'
)
$narrowStatus = New-LabQueueStatusProvider -Height 3 -Width 0 `
    -OperationReader { @($runningOperation) } -QueueReader { $queueProjection } -Clock { $statusClock }
$narrowBand = & $narrowStatus 0
Add-ConsoleUiCheck 'Statusband bleibt auch ohne ermittelbare Fensterbreite lesbar' (
    $narrowBand.Count -eq 3 -and $narrowBand[0] -match '^Queue 3' -and $narrowBand[1] -match '^SQL2025latest' -and
    @($narrowBand | Where-Object { $_.Length -gt 0 }).Count -ge 2
)

# CUI-025: Provider-Ausgabe wird fuer die Diagnose persistiert, ohne Secrets zu schreiben.
$providerLogRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-provider-log-$([guid]::NewGuid().ToString('N'))"
try {
    $runLogPath = Write-LabProviderLog -Provider podman -Phase 'container-create' `
        -Command 'podman run -d --name lab-x -e MSSQL_SA_PASSWORD=Str3ng-Geheim! -e ACCEPT_EULA=Y image:tag' `
        -Output @('abc123def456', 'Error: port is already allocated') -ExitCode 125 `
        -RunId 'run-demo' -StateRoot $providerLogRoot
    $logText = if ($runLogPath) { Get-Content -LiteralPath $runLogPath -Raw } else { '' }
    Add-ConsoleUiCheck 'Provider-Ausgabe wird runbezogen persistiert und bleibt secretfrei' (
        $runLogPath -and (Split-Path -Leaf $runLogPath) -eq 'provider.log' -and
        $runLogPath -match 'runs[\\/]run-demo[\\/]log' -and
        $logText -match 'podman container-create exit=125' -and
        $logText -match 'Error: port is already allocated' -and
        $logText -notmatch 'Str3ng-Geheim' -and $logText -match 'MSSQL_SA_PASSWORD=\*\*\*'
    )
    $sessionLogPath = Get-LabProviderLogPath -RunId '' -StateRoot $providerLogRoot
    Add-ConsoleUiCheck 'Ohne Run-Bezug landet Provider-Ausgabe im Sitzungslog' (
        $sessionLogPath -match 'session' -and (Split-Path -Leaf $sessionLogPath) -eq 'provider.log'
    )
    Add-ConsoleUiCheck 'Ein relativer State-Root erzeugt kein Provider-Log im Arbeitsverzeichnis' (
        $null -eq (Get-LabProviderLogPath -RunId 'run-demo' -StateRoot 'relativer-pfad')
    )

    $wrapped = Invoke-LabProviderOperation -Provider docker -Phase 'container-start' `
        -Command 'docker start lab-x' -RunId 'run-wrapper' -StateRoot $providerLogRoot `
        -Action { 'container-output' }
    $wrappedText = Get-Content -LiteralPath $wrapped.LogPath -Raw
    Add-ConsoleUiCheck 'Gemeinsamer Provider-Wrapper bewahrt Ausgabe und protokolliert Erfolg' (
        $wrapped.Succeeded -and $wrapped.ExitCode -eq 0 -and
        @($wrapped.Output).Count -eq 1 -and $wrapped.Output[0] -eq 'container-output' -and
        $wrappedText -match 'docker container-start exit=0'
    )

    $nativeWrapped = Invoke-LabProviderOperation -Provider docker -Phase 'native-counterexample' -Native `
        -RunId 'run-native-wrapper' -StateRoot $providerLogRoot `
        -Action { pwsh -NoLogo -NoProfile -Command 'Write-Output native-output; exit 7' 2>&1 }
    Add-ConsoleUiCheck 'Gemeinsamer Provider-Wrapper uebernimmt Exitcode und Ausgabe nativer Prozesse' (
        -not $nativeWrapped.Succeeded -and $nativeWrapped.ExitCode -eq 7 -and
        @($nativeWrapped.Output) -contains 'native-output'
    )

    $wrapperFailed = $false
    try {
        $null = Invoke-LabProviderOperation -Provider hyperv -Phase 'vm-start' `
            -Command 'Start-VM -Name lab-x' -RunId 'run-wrapper-failure' -StateRoot $providerLogRoot `
            -Action { throw 'controlled-provider-failure' }
    }
    catch { $wrapperFailed = $_.Exception.Message -eq 'controlled-provider-failure' }
    $failureLog = Get-LabProviderLogPath -RunId 'run-wrapper-failure' -StateRoot $providerLogRoot
    Add-ConsoleUiCheck 'Gemeinsamer Provider-Wrapper protokolliert Fehler und reicht sie weiter' (
        $wrapperFailed -and (Get-Content -LiteralPath $failureLog -Raw) -match 'hyperv vm-start exit=1'
    )

    $rotationPath = $null
    1..6 | ForEach-Object {
        $rotationPath = Write-LabProviderLog -Provider podman -Phase 'image-build' `
            -Output ("rotation-entry-{0}-{1}" -f $_, ('x' * 90)) -RunId 'run-rotation' `
            -StateRoot $providerLogRoot -MaximumBytes 180 -ArchiveCount 3
    }
    Add-ConsoleUiCheck 'Provider-Logs rotieren begrenzt und behalten das aktuelle Log' (
        (Test-Path -LiteralPath $rotationPath -PathType Leaf) -and
        (Test-Path -LiteralPath "$rotationPath.1" -PathType Leaf) -and
        (Test-Path -LiteralPath "$rotationPath.3" -PathType Leaf) -and
        -not (Test-Path -LiteralPath "$rotationPath.4") -and
        (Get-Content -LiteralPath $rotationPath -Raw) -match 'rotation-entry-6'
    )
    $boundedPath = Write-LabProviderLog -Provider docker -Phase 'oversized-entry' `
        -Output ('x' * 2000) -RunId 'run-bounded-entry' -StateRoot $providerLogRoot `
        -MaximumBytes 180 -ArchiveCount 1
    Add-ConsoleUiCheck 'Ein einzelner grosser Provider-Eintrag bleibt innerhalb der Loggrenze' (
        (Get-Item -LiteralPath $boundedPath).Length -le 180 -and
        (Get-Content -LiteralPath $boundedPath -Raw) -match 'provider log entry truncated'
    )
}
finally { Remove-Item -LiteralPath $providerLogRoot -Recurse -Force -ErrorAction SilentlyContinue }

$dockerProviderSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Docker/DockerProvider.ps1') -Raw
$podmanProviderSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Podman/PodmanProvider.ps1') -Raw
$containerToolImageSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ContainerToolImage.ps1') -Raw
$hyperVProviderSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/HyperV/HyperVProvider.ps1') -Raw
Add-ConsoleUiCheck 'Beide Container-Provider persistieren Erstellung, Lifecycle und Volumes ueber den gemeinsamen Wrapper' (
    $dockerProviderSource -match "Invoke-LabProviderOperation -Provider docker -Phase 'container-create'" -and
    $podmanProviderSource -match "Invoke-LabProviderOperation -Provider podman -Phase 'container-create'" -and
    $dockerProviderSource -match "-Phase 'volume-create'" -and $podmanProviderSource -match "-Phase 'volume-create'" -and
    $dockerProviderSource -match "-Phase 'volume-initialize'" -and $podmanProviderSource -match "-Phase 'volume-initialize'" -and
    $dockerProviderSource -match "-Phase 'container-start'" -and $podmanProviderSource -match "-Phase 'container-start'" -and
    $dockerProviderSource -match "-Phase 'container-stop'" -and $podmanProviderSource -match "-Phase 'container-stop'" -and
    $dockerProviderSource -match 'Diagnoselog: \$providerLogPath' -and
    $podmanProviderSource -match 'Diagnoselog: \$providerLogPath'
)
Add-ConsoleUiCheck 'Image-Builds und Hyper-V-Lifecycle verwenden den gemeinsamen Provider-Wrapper' (
    $containerToolImageSource -match 'Invoke-LabProviderOperation -Provider \$provider -Phase ''image-build''' -and
    $hyperVProviderSource -match "-Provider hyperv -Phase 'vm-create'" -and
    $hyperVProviderSource -match "-Provider hyperv -Phase 'vm-start'" -and
    $hyperVProviderSource -match "-Provider hyperv -Phase 'vm-stop'" -and
    $hyperVProviderSource -match "-Provider hyperv -Phase 'vm-remove'"
)

$items = @(
    New-LabConsoleItem -Id 'one' -Label 'One' -Shortcut '1'
    New-LabConsoleItem -Id 'two' -Label 'Two' -Shortcut '2'
    New-LabConsoleItem -Id 'three' -Label 'Three' -Shortcut '3'
)
$state = New-LabConsoleState -ScreenId 'test' -Items $items -SelectedId 'two' -ViewportHeight 2
Add-ConsoleUiCheck 'State verwendet stabile SelectedId' ($state.SelectedId -eq 'two' -and $state.SelectedIndex -eq 1)

$null = Move-LabConsoleSelection -State $state -Direction Down
Add-ConsoleUiCheck 'Down bewegt Auswahl ohne externen Refresh' ($state.SelectedId -eq 'three')
$null = Move-LabConsoleSelection -State $state -Direction Home
Add-ConsoleUiCheck 'Home springt zum ersten Element' ($state.SelectedId -eq 'one')

$null = Sync-LabConsoleState -State $state -Items @($items[2], $items[0], $items[1])
Add-ConsoleUiCheck 'Sortierung erhaelt Auswahl ueber ID' ($state.SelectedId -eq 'one' -and $state.SelectedIndex -eq 1)

$null = Sync-LabConsoleState -State $state -Items @($items[2], $items[1])
Add-ConsoleUiCheck 'Entfernte Auswahl wechselt kontrolliert zum naechsten gueltigen Element' ($state.SelectedId -eq 'two' -and $state.SelectedIndex -eq 1)

$frame = Get-LabConsoleFrame -State $state -Title 'Test' -Width 30 -Height 8
Add-ConsoleUiCheck 'Frame besitzt begrenzten Viewport und Fokusmarker' ($frame.Lines.Count -eq 8 -and @($frame.Lines | Where-Object { $_ -match '^>' }).Count -eq 1)
Add-ConsoleUiCheck 'Framezeilen bleiben innerhalb der Breite' (@($frame.Lines | Where-Object Length -gt 29).Count -eq 0)

$disabledState = New-LabConsoleState -ScreenId 'disabled-color' -Items @(
    New-LabConsoleItem -Id 'enabled' -Label 'Enabled' -Shortcut '1'
    New-LabConsoleItem -Id 'disabled' -Label 'Disabled' -Shortcut '2' -Disabled
)
$disabledFrame = Get-LabConsoleFrame -State $disabledState -Title 'Disabled' -Width 40 -Height 8
$disabledLineIndex = @(0..($disabledFrame.Lines.Count - 1) | Where-Object { $disabledFrame.Lines[$_] -match '\[2\].*Disabled' } | Select-Object -First 1)[0]
Add-ConsoleUiCheck 'Deaktivierte Menuepunkte werden dunkelgrau gerendert' ($null -ne $disabledLineIndex -and $disabledFrame.LineColors[$disabledLineIndex] -eq 'DarkGray')

$writeSession = [PSCustomObject]@{ PreviousLineCount=5 }
$writePlan = Get-LabConsoleWritePlan -Session $writeSession -Frame ([PSCustomObject]@{ Lines=@('kurz','neu') }) -Width 12 -Height 6
Add-ConsoleUiCheck 'Write-Plan ueberschreibt alte Restzeilen vollstaendig' ($writePlan.Rows.Count -eq 5 -and @($writePlan.Rows | Where-Object ClearsPrevious).Count -eq 3 -and @($writePlan.Rows | Where-Object { $_.Text.Length -ne 11 }).Count -eq 0)

$state.Snapshot = [PSCustomObject]@{ AttentionItems=@(
    [PSCustomObject]@{ Severity='Critical'; Message='Recovery erforderlich.'; ActionHint='Recovery-Pfad fortsetzen.' }
    [PSCustomObject]@{ Severity='Warning'; Message='CU-Paket fehlt.'; ActionHint='CU im Storage-Menue laden.' }
) }
$attentionFrame = Get-LabConsoleFrame -State $state -Title 'Attention' -Width 50 -Height 10
Add-ConsoleUiCheck 'Footer zeigt read-only Attention Items aus dem Snapshot' (@($attentionFrame.Lines | Where-Object { $_ -match '^Offen \[!\]' }).Count -eq 2)
Add-ConsoleUiCheck 'Attention Items nennen direkt den Loesungsweg' (@($attentionFrame.Lines | Where-Object { $_ -match '^Loesung:' }).Count -eq 2)
$smallAttentionFrame = Get-LabConsoleFrame -State $state -Title 'Attention klein' -Width 50 -Height 6
Add-ConsoleUiCheck 'Attention verdraengt in kleinem Terminal weder Viewport noch Navigation' (
    $smallAttentionFrame.Lines.Count -eq 6 -and
    @($smallAttentionFrame.Lines | Where-Object { $_ -match '^Loesung:' }).Count -eq 1 -and
    @($smallAttentionFrame.Lines | Where-Object { $_ -match '^Pfeile:' }).Count -eq 1
)
$state.Snapshot = $null

$textEscapeKeys = [System.Collections.Generic.Queue[object]]::new()
$textEscapeKeys.Enqueue([PSCustomObject]@{ Key='Escape'; KeyChar=[char]27 })
$textEscapeWrites = [System.Collections.Generic.List[string]]::new()
$textEscapeResult = Read-LabConsoleTextInput -Prompt 'Batch-Name' -Default 'Neue Umgebungen' -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $textEscapeKeys.Dequeue() } -WriteText { param($text) $textEscapeWrites.Add([string]$text) }
Add-ConsoleUiCheck 'Texteingabe bricht mit Escape ohne Wert ab' ($textEscapeResult.Status -eq 'Cancelled' -and $null -eq $textEscapeResult.Value)
Add-ConsoleUiCheck 'Escape schreibt einen echten Zeilenumbruch statt des Property-Ausdrucks' (
    $textEscapeWrites.Count -eq 2 -and
    $textEscapeWrites[$textEscapeWrites.Count - 1] -ceq [Environment]::NewLine -and
    (@($textEscapeWrites) -join '') -notmatch '\[Environment\]::NewLine'
)

$textDefaultKeys = [System.Collections.Generic.Queue[object]]::new()
$textDefaultKeys.Enqueue([PSCustomObject]@{ Key='Enter'; KeyChar=[char]13 })
$textDefaultResult = Read-LabConsoleTextInput -Prompt 'Batch-Name' -Default 'Neue Umgebungen' -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $textDefaultKeys.Dequeue() } -WriteText { param($text) }
Add-ConsoleUiCheck 'Texteingabe bestaetigt mit Enter den Default' ($textDefaultResult.Status -eq 'Confirmed' -and $textDefaultResult.Value -eq 'Neue Umgebungen')

$fallbackTextPrompt = ''
$fallbackTextResult = Read-LabConsoleTextInput -Prompt 'Batch-Name' -Default 'Neue Umgebungen' -Capability ([PSCustomObject]@{ Supported=$false }) -ReadInput { param($prompt) $script:fallbackTextPrompt=$prompt; '0' }
Add-ConsoleUiCheck 'Fallback-Texteingabe dokumentiert und akzeptiert 0 als Abbruch' (
    $fallbackTextResult.Status -eq 'Cancelled' -and $null -eq $fallbackTextResult.Value -and $fallbackTextPrompt -match '0: Abbruch'
)

$fallbackMaskedPrompt = ''
$fallbackMaskedResult = Read-LabConsoleTextInput -Prompt 'Maskierter Wert' -MaskInput -Capability ([PSCustomObject]@{ Supported=$false }) -ReadInput { param($prompt) $script:fallbackMaskedPrompt=$prompt; '0' }
Add-ConsoleUiCheck 'Fallback verwechselt die Ziffer 0 in maskierten Eingaben nicht mit Abbruch' (
    $fallbackMaskedResult.Status -eq 'Confirmed' -and $fallbackMaskedResult.Value -eq '0' -and $fallbackMaskedPrompt -match 'Ctrl\+C: Abbruch'
)

$emptyComposerBasket = [Collections.Generic.List[object]]::new()
$originalSqlIntentReader = ${function:Read-LabSqlEnvironmentIntentInteractive}
try {
    Set-Item -LiteralPath Function:\Read-LabSqlEnvironmentIntentInteractive -Value { return $null }
    Add-LabSqlComposerItemInteractive -Basket $emptyComposerBasket
    $emptyComposerAccepted = $true
}
catch { $emptyComposerAccepted = $false }
finally {
    if ($originalSqlIntentReader) { Set-Item -LiteralPath Function:\Read-LabSqlEnvironmentIntentInteractive -Value $originalSqlIntentReader }
    else { Remove-Item -LiteralPath Function:\Read-LabSqlEnvironmentIntentInteractive -ErrorAction SilentlyContinue }
}
Add-ConsoleUiCheck 'Erste SQL-Position akzeptiert den noch leeren Batch-Warenkorb' ($emptyComposerAccepted -and $emptyComposerBasket.Count -eq 0)

$hostEscapeKeys = [System.Collections.Generic.Queue[object]]::new()
$hostEscapeKeys.Enqueue([PSCustomObject]@{ Key='Escape'; KeyChar=[char]27 })
$hostEscapeDetected = $false
try { $null = Read-Host 'Beliebiges Feld' -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $hostEscapeKeys.Dequeue() } -WriteText { param($text) } }
catch { $hostEscapeDetected = Test-LabConsoleInputCancellation -InputObject $_ }
Add-ConsoleUiCheck 'Jede modulinterne Read-Host-Eingabe liefert bei Escape das gemeinsame Abbruchsignal' $hostEscapeDetected

$secureEscapeKeys = [System.Collections.Generic.Queue[object]]::new()
$secureEscapeKeys.Enqueue([PSCustomObject]@{ Key='A'; KeyChar='x' })
$secureEscapeKeys.Enqueue([PSCustomObject]@{ Key='Escape'; KeyChar=[char]27 })
$secureWrites = [System.Collections.Generic.List[string]]::new()
$secureEscapeDetected = $false
try { $null = Read-Host 'Passwort' -AsSecureString -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $secureEscapeKeys.Dequeue() } -WriteText { param($text) $secureWrites.Add([string]$text) } }
catch { $secureEscapeDetected = Test-LabConsoleInputCancellation -InputObject $_ }
Add-ConsoleUiCheck 'Escape verwirft auch sichere Eingaben ohne Klartextausgabe' ($secureEscapeDetected -and (@($secureWrites) -join '') -notmatch 'x')

$acknowledgementKeys = [System.Collections.Generic.Queue[object]]::new()
$acknowledgementKeys.Enqueue([PSCustomObject]@{ Key='A'; KeyChar='a' })
$acknowledgementKeys.Enqueue([PSCustomObject]@{ Key='Enter'; KeyChar=[char]13 })
$acknowledgementWrites = [System.Collections.Generic.List[string]]::new()
Wait-LabConsoleAcknowledgement -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $acknowledgementKeys.Dequeue() } -WriteText { param($text) $acknowledgementWrites.Add([string]$text) }
Add-ConsoleUiCheck 'Informationsansicht wartet genau bis Enter oder Escape' ($acknowledgementKeys.Count -eq 0 -and @($acknowledgementWrites).Count -eq 2)
Add-ConsoleUiCheck 'Informationsansicht beendet mit einem echten Zeilenumbruch' (
    $acknowledgementWrites[$acknowledgementWrites.Count - 1] -ceq [Environment]::NewLine -and
    (@($acknowledgementWrites) -join '') -notmatch '\[Environment\]::NewLine'
)

$fallback = Invoke-LabConsoleMenu -ScreenId 'fallback' -Title 'Fallback' -Items $items -ForceFallback -ReadInput { param($prompt) '2' }
Add-ConsoleUiCheck 'Read-Host-Fallback waehlt nummeriert' ($fallback.Status -eq 'Selected' -and $fallback.SelectedItem.Id -eq 'two')
$cancelledFallback = Invoke-LabConsoleMenu -ScreenId 'fallback-cancel' -Title 'Fallback' -Items $items -ForceFallback -ReadInput { param($prompt) '0' }
Add-ConsoleUiCheck 'Read-Host-Fallback bricht mit 0 kontrolliert ab' ($cancelledFallback.Status -eq 'Cancelled' -and $null -eq $cancelledFallback.SelectedItem)

$fallbackRendering = @(& { Invoke-LabConsoleMenu -ScreenId 'fallback-visible-cancel' -Title 'Fallback' -Items $items -ForceFallback -ReadInput { param($prompt) '0' } } 6>&1)
Add-ConsoleUiCheck 'Read-Host-Fallback zeigt den Abbruchpunkt auch ohne explizites 0-Item' (
    (@($fallbackRendering | ForEach-Object { [string]$_ }) -join "`n") -match '\[0\] Zurueck'
)

$invalidFallback = Invoke-LabConsoleMenu -ScreenId 'fallback-invalid' -Title 'Fallback' -Items $items -ForceFallback -ReadInput { param($prompt) '99' }
$disabledFallback = Invoke-LabConsoleMenu -ScreenId 'fallback-disabled' -Title 'Fallback' -Items @(
    New-LabConsoleItem -Id 'disabled' -Label 'Disabled' -Shortcut '1' -Disabled
    New-LabConsoleItem -Id 'enabled' -Label 'Enabled' -Shortcut '2'
) -ForceFallback -ReadInput { param($prompt) '1' }
Add-ConsoleUiCheck 'Fallback lehnt unbekannte und deaktivierte Auswahl kontrolliert ab' ($invalidFallback.Status -eq 'Invalid' -and $disabledFallback.Status -eq 'Invalid')

$keys = [System.Collections.Generic.Queue[object]]::new()
$keys.Enqueue([PSCustomObject]@{ Key='DownArrow'; KeyChar=[char]0 })
$keys.Enqueue([PSCustomObject]@{ Key='Enter'; KeyChar=[char]13 })
$renderCount = 0
$cursorResult = Invoke-LabConsoleMenu -ScreenId 'cursor' -Title 'Cursor' -Items $items -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $keys.Dequeue() } -FrameWriter { param($session, $renderedFrame) $script:renderCount++ }
Add-ConsoleUiCheck 'Key-Loop navigiert und rendert lokal neu' ($cursorResult.SelectedItem.Id -eq 'two' -and $renderCount -eq 2)

$numberedItems = @(1..12 | ForEach-Object { New-LabConsoleItem -Id "number-$_" -Label "Number $_" -Shortcut ([string]$_) })
$numberKeys = [System.Collections.Generic.Queue[object]]::new()
$numberKeys.Enqueue([PSCustomObject]@{ Key='D1'; KeyChar='1' })
$numberKeys.Enqueue([PSCustomObject]@{ Key='D1'; KeyChar='1' })
$numberRenderCount = 0
$numberResult = Invoke-LabConsoleMenu -ScreenId 'number-11' -Title 'Number 11' -Items $numberedItems -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $numberKeys.Dequeue() } -FrameWriter { param($session, $renderedFrame) $script:numberRenderCount++ }
Add-ConsoleUiCheck 'Mehrstellige Auswahl 11 wartet nach erster 1 und wählt Eintrag 11' ($numberResult.SelectedItem.Id -eq 'number-11' -and $numberRenderCount -eq 2)

$singleDigitKeys = [System.Collections.Generic.Queue[object]]::new()
$singleDigitKeys.Enqueue([PSCustomObject]@{ Key='D1'; KeyChar='1' })
$singleDigitKeys.Enqueue([PSCustomObject]@{ Key='Enter'; KeyChar=[char]13 })
$singleDigitResult = Invoke-LabConsoleMenu -ScreenId 'number-1' -Title 'Number 1' -Items $numberedItems -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $singleDigitKeys.Dequeue() } -FrameWriter { param($session, $renderedFrame) }
Add-ConsoleUiCheck 'Mehrdeutige einstellige Auswahl 1 wird mit Enter bestätigt' ($singleDigitResult.SelectedItem.Id -eq 'number-1')

$resizeKeys = [System.Collections.Generic.Queue[object]]::new()
$resizeKeys.Enqueue([PSCustomObject]@{ Key='DownArrow'; KeyChar=[char]0 })
$resizeKeys.Enqueue([PSCustomObject]@{ Key='Enter'; KeyChar=[char]13 })
$viewports = [System.Collections.Generic.Queue[object]]::new()
$viewports.Enqueue([PSCustomObject]@{ Width=80; Height=25 })
$viewports.Enqueue([PSCustomObject]@{ Width=32; Height=9 })
$resizeFrames = [System.Collections.Generic.List[object]]::new()
$resizeResult = Invoke-LabConsoleMenu -ScreenId 'resize' -Title 'Resize' -Items $items -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $resizeKeys.Dequeue() } -GetViewport { $viewports.Dequeue() } -FrameWriter { param($session, $renderedFrame) $resizeFrames.Add($renderedFrame) }
Add-ConsoleUiCheck 'Resize berechnet Layout neu und erhaelt stabile Auswahl' ($resizeResult.SelectedItem.Id -eq 'two' -and $resizeFrames.Count -eq 2 -and $resizeFrames[0].Width -eq 79 -and $resizeFrames[1].Width -eq 31 -and $resizeFrames[1].Height -eq 9)

$longItems = @(1..30 | ForEach-Object { New-LabConsoleItem -Id "item-$_" -Label "Item $_" })
$longState = New-LabConsoleState -ScreenId 'long' -Items $longItems -ViewportHeight 4
$null = Move-LabConsoleSelection -State $longState -Direction PageDown
$null = Move-LabConsoleSelection -State $longState -Direction End
$longFrame = Get-LabConsoleFrame -State $longState -Title 'Long' -Width 24 -Height 8
Add-ConsoleUiCheck 'Kleiner Viewport erreicht per PageDown und End das Listenende' ($longState.SelectedId -eq 'item-30' -and $longState.TopIndex -gt 0 -and @($longFrame.Lines | Where-Object { $_ -match '^>' }).Count -eq 1)

$recoveryCompleted = $false
$recoveryResult = Invoke-LabConsoleMenu -ScreenId 'recovery' -Title 'Recovery' -Items $items -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { throw 'SIMULATED_CONSOLE_FAILURE' } -ReadInput { param($prompt) '2' } -FrameWriter { param($session, $renderedFrame) } -SessionFactory { [PSCustomObject]@{ PreviousLineCount=0 } } -SessionCompleter { param($session) $script:recoveryCompleted=$true }
Add-ConsoleUiCheck 'Konsolenfehler beendet Session und wechselt in Fallback' ($recoveryCompleted -and $recoveryResult.Status -eq 'Selected' -and $recoveryResult.SelectedItem.Id -eq 'two')

$refreshKeys = [System.Collections.Generic.Queue[object]]::new()
$refreshKeys.Enqueue([PSCustomObject]@{ Key='F5'; KeyChar=[char]0 })
$refreshResult = Invoke-LabConsoleMenu -ScreenId 'refresh' -Title 'Refresh' -Items $items -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $refreshKeys.Dequeue() } -FrameWriter { param($session, $renderedFrame) }
Add-ConsoleUiCheck 'F5 fordert Refresh an statt Runtime selbst aufzurufen' ($refreshResult.Status -eq 'Refresh')

$multiKeys = [System.Collections.Generic.Queue[object]]::new()
$multiKeys.Enqueue([PSCustomObject]@{ Key='Spacebar'; KeyChar=' ' })
$multiKeys.Enqueue([PSCustomObject]@{ Key='DownArrow'; KeyChar=[char]0 })
$multiKeys.Enqueue([PSCustomObject]@{ Key='Spacebar'; KeyChar=' ' })
$multiKeys.Enqueue([PSCustomObject]@{ Key='Enter'; KeyChar=[char]13 })
$multiResult = Invoke-LabConsoleMultiSelect -ScreenId 'multi' -Title 'Multi' -Items $items -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $multiKeys.Dequeue() } -FrameWriter { param($session, $renderedFrame) }
Add-ConsoleUiCheck 'Mehrfachauswahl schaltet per Space um und bestätigt gesammelt' ($multiResult.Status -eq 'Confirmed' -and @($multiResult.SelectedItems).Count -eq 2 -and @($multiResult.SelectedItems).Id -contains 'one' -and @($multiResult.SelectedItems).Id -contains 'two')

$multiNumberKeys = [System.Collections.Generic.Queue[object]]::new()
$multiNumberKeys.Enqueue([PSCustomObject]@{ Key='D1'; KeyChar='1' })
$multiNumberKeys.Enqueue([PSCustomObject]@{ Key='D1'; KeyChar='1' })
$multiNumberKeys.Enqueue([PSCustomObject]@{ Key='Enter'; KeyChar=[char]13 })
$multiNumberResult = Invoke-LabConsoleMultiSelect -ScreenId 'multi-number-11' -Title 'Multi Number 11' -Items $numberedItems -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $multiNumberKeys.Dequeue() } -FrameWriter { param($session, $renderedFrame) }
Add-ConsoleUiCheck 'Mehrfachauswahl interpretiert 11 ebenfalls als Eintrag 11' ($multiNumberResult.Status -eq 'Confirmed' -and @($multiNumberResult.SelectedItems).Count -eq 1 -and $multiNumberResult.SelectedItems[0].Id -eq 'number-11')

$multiFallbackInputs = [System.Collections.Generic.Queue[string]]::new()
$multiFallbackInputs.Enqueue('1')
$multiFallbackInputs.Enqueue('')
$multiFallbackResult = Invoke-LabConsoleMultiSelect -ScreenId 'multi-fallback' -Title 'Multi Fallback' -Items $items -ForceFallback -ReadInput { param($prompt) $multiFallbackInputs.Dequeue() }
Add-ConsoleUiCheck 'Mehrfachauswahl bleibt im Read-Host-Fallback vollstaendig bedienbar' ($multiFallbackResult.Status -eq 'Confirmed' -and @($multiFallbackResult.SelectedItems).Id -contains 'one')

$formKeys = [System.Collections.Generic.Queue[object]]::new()
$formKeys.Enqueue([PSCustomObject]@{ Key='Enter'; KeyChar=[char]13 })
$formKeys.Enqueue([PSCustomObject]@{ Key='F10'; KeyChar=[char]0 })
$formKeys.Enqueue([PSCustomObject]@{ Key='Enter'; KeyChar=[char]13 })
$fields = @(
    New-LabConsoleField -Id 'cpu' -Label 'CPU' -Value 2 -Editor { param($current, $values) 4 } -Validator { param($value, $values) if ([int]$value -lt 1) { 'CPU muss positiv sein.' } }
)
$formResult = Invoke-LabConsoleForm -ScreenId 'form' -Title 'Form' -Fields $fields -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $formKeys.Dequeue() } -FrameWriter { param($session, $renderedFrame) }
Add-ConsoleUiCheck 'Formular bearbeitet, validiert und reviewed vor Bestaetigung' ($formResult.Status -eq 'Confirmed' -and [int]$formResult.Values['cpu'] -eq 4)

$secretKeys = [System.Collections.Generic.Queue[object]]::new()
$secretKeys.Enqueue([PSCustomObject]@{ Key='Enter'; KeyChar=[char]13 })
$secretKeys.Enqueue([PSCustomObject]@{ Key='F10'; KeyChar=[char]0 })
$secretKeys.Enqueue([PSCustomObject]@{ Key='Enter'; KeyChar=[char]13 })
$secretFrames = [System.Collections.Generic.List[string]]::new()
$secretFields = @(New-LabConsoleField -Id 'password' -Label 'Passwort' -Sensitive -Required -Editor {
    param($current, $values)
    $secureValue = [Security.SecureString]::new()
    foreach ($character in 'CUI011-Not-In-Frame'.ToCharArray()) { $secureValue.AppendChar($character) }
    $secureValue.MakeReadOnly()
    return $secureValue
})
$secretResult = Invoke-LabConsoleForm -ScreenId 'secret-form' -Title 'Secret Form' -Fields $secretFields -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $secretKeys.Dequeue() } -FrameWriter { param($session, $renderedFrame) $secretFrames.Add((@($renderedFrame.Lines) -join "`n")) }
Add-ConsoleUiCheck 'Secrets bleiben in Formular-, Review- und Frame-Snapshots maskiert' ($secretResult.Status -eq 'Confirmed' -and $secretResult.SecureValues.ContainsKey('password') -and (@($secretFrames) -join "`n") -notmatch 'CUI011-Not-In-Frame' -and (@($secretFrames) -join "`n") -match '<gesetzt>')

$sensitiveFieldRejected = $false
try { $null = New-LabConsoleField -Id 'secret' -Label 'Secret' -Value 'plaintext' -Sensitive } catch { $sensitiveFieldRejected = $_.Exception.Message -eq 'CONSOLE_UI_SENSITIVE_INITIAL_VALUE_NOT_ALLOWED' }
Add-ConsoleUiCheck 'Sensitive Klartextwerte gelangen nicht in den UI-State' $sensitiveFieldRejected

# Steuerflusstest: Ausgabeaktionen dürfen nicht direkt in die Menüschleife
# zurückfallen. Die Stubs bilden Auswahl -> Aktion -> Rückkehr ab und zählen
# ausschließlich die zentrale Bestätigung.
$script:connectionCenterMenuResults = [System.Collections.Generic.Queue[object]]::new()
$script:connectionCenterAcknowledgements = 0
function Get-LabStateRoot { 'test-state-root' }
function Get-SqlServerLabConnectionCenter {
    [PSCustomObject]@{
        Grouping = [PSCustomObject]@{ RootGroupName='SQL Server Lab' }
        Entries = @([PSCustomObject]@{ RuntimeState='RUNNING'; DisplayName='Test'; Server='127.0.0.1,14330'; Group='DOCKER' })
    }
}
function Invoke-LabConsoleMenu {
    [PSCustomObject]$ignored = $null
    return $script:connectionCenterMenuResults.Dequeue()
}
function Sync-SqlServerLabConnectionCenter {
    [PSCustomObject]@{ ConnectionCenter=(Get-SqlServerLabConnectionCenter) }
}
function Export-SqlServerLabSsmsRegistration {
    [PSCustomObject]@{ Path='test-state-root/exports/sql-server-lab.regsrvr' }
}
function Read-LabConnectionCenterSsmsExportPath {
    'test-data-root/Exports/sql-server-lab.regsrvr'
}
function Wait-LabConsoleAcknowledgement {
    $script:connectionCenterAcknowledgements++
}

$connectionCenterFlowResults = @()
foreach ($action in @('1', '2', '3', '6', '7')) {
    $script:connectionCenterAcknowledgements = 0
    $script:connectionCenterMenuResults.Clear()
    $script:connectionCenterMenuResults.Enqueue([PSCustomObject]@{ Status='Selected'; SelectedItem=[PSCustomObject]@{ Id=$action } })
    $script:connectionCenterMenuResults.Enqueue([PSCustomObject]@{ Status='Selected'; SelectedItem=[PSCustomObject]@{ Id='0' } })
    Invoke-LabConnectionCenterInteractive
    $connectionCenterFlowResults += [PSCustomObject]@{ Action=$action; Acknowledgements=$script:connectionCenterAcknowledgements; RemainingSelections=$script:connectionCenterMenuResults.Count }
}
Add-ConsoleUiCheck 'Verbindungszentrale durchläuft jede Ausgabeaktion mit einer Rückkehrbestätigung' (
    @($connectionCenterFlowResults).Count -eq 5 -and
    @($connectionCenterFlowResults | Where-Object { $_.Acknowledgements -ne 1 -or $_.RemainingSelections -ne 0 }).Count -eq 0
)

$consoleSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ConsoleUi.ps1') -Raw
$consoleHelpSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ConsoleHelp.ps1') -Raw
$containerSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Update-SqlServerLabContainer.ps1') -Raw
$entryScriptPath = Join-Path $repoRoot 'Invoke-SqlServerLab.ps1'
$publicEntryPath = Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1'
$entryTokens = $null; $entryErrors = $null
$entryAst = [Management.Automation.Language.Parser]::ParseFile($entryScriptPath, [ref]$entryTokens, [ref]$entryErrors)
$publicTokens = $null; $publicErrors = $null
$publicEntryAst = [Management.Automation.Language.Parser]::ParseFile($publicEntryPath, [ref]$publicTokens, [ref]$publicErrors)
$getActionValues = {
    param($Ast)
    $parameter = @($Ast.FindAll({ param($node) $node -is [Management.Automation.Language.ParameterAst] -and $node.Name.VariablePath.UserPath -eq 'Action' }, $true))[0]
    $validation = @($parameter.Attributes | Where-Object { $_.TypeName.FullName -eq 'ValidateSet' })[0]
    return @($validation.PositionalArguments | ForEach-Object { [string]$_.SafeGetValue() } | Sort-Object)
}
$entryActions = @(& $getActionValues $entryAst)
$publicActions = @(& $getActionValues $publicEntryAst)
Add-ConsoleUiCheck 'Standalone-Einstieg und Modul bieten dieselben Direktaktionen an' (
    @($entryErrors).Count -eq 0 -and @($publicErrors).Count -eq 0 -and
    ($entryActions -join '|') -eq ($publicActions -join '|')
)
Add-ConsoleUiCheck 'Key-Loops verwenden kein Clear-Host' ($consoleSource -notmatch 'Clear-Host' -and $containerSource -notmatch 'Clear-Host')
Add-ConsoleUiCheck 'Alle Console-Key-Loops reichen Ctrl+C als PipelineStoppedException durch' (
    ([regex]::Matches($consoleSource, 'Assert-LabConsoleKeyNotInterrupted -Key \$key')).Count -eq 4 -and
    ([regex]::Matches($consoleSource, '\$key = (?:Read-LabConsoleKey -ReadKey \$ReadKey|Wait-LabConsoleKey )')).Count -eq 4 -and
    $consoleSource -match 'function Wait-LabConsoleKey[\s\S]+?Read-LabConsoleKey -ReadKey \$ReadKey' -and
    $consoleHelpSource -match 'Read-LabConsoleKey -ReadKey \$ReadKey[\s\S]{0,120}Assert-LabConsoleKeyNotInterrupted -Key \$key' -and
    $consoleSource -match '\[Console\]::TreatControlCAsInput = \$true' -and
    $consoleSource -match '\[Console\]::TreatControlCAsInput = \$previousTreatControlCAsInput' -and
    $consoleSource -match 'throw \[Management\.Automation\.PipelineStoppedException\]::new\(\)' -and
    ([regex]::Matches($consoleSource, 'catch \[Management\.Automation\.PipelineStoppedException\]')).Count -eq 2
)

$entrySource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1') -Raw
$standaloneEntrySource = Get-Content -LiteralPath (Join-Path $repoRoot 'Invoke-SqlServerLab.ps1') -Raw
Add-ConsoleUiCheck 'PowerShell-7-Einstieg reicht ConsoleMode Auto oder Fallback durch' (
    $entrySource -match "ValidateSet\('Auto', 'Fallback'\)" -and
    $standaloneEntrySource -match "ValidateSet\('Auto', 'Fallback'\)" -and
    $standaloneEntrySource -match 'Invoke-SqlServerLab -ConsoleMode \$ConsoleMode'
)
$connectionCenterSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Sync-SqlServerLabConnectionCenter.ps1') -Raw
    $sqlIntentMatch = [regex]::Match($entrySource, 'function Read-LabSqlEnvironmentIntentInteractive \{[\s\S]+?\n\}(?=\r?\n\r?\nfunction Resolve-LabSqlIntentProvider)')
Add-ConsoleUiCheck 'SQL-Zielkonfiguration verwendet gemeinsames Formular und Review' ($sqlIntentMatch.Success -and $sqlIntentMatch.Value -match 'Invoke-LabConsoleForm' -and $sqlIntentMatch.Value -match 'New-LabConsoleField')
Add-ConsoleUiCheck 'Providerentscheidung bleibt ausserhalb der Formularnavigation' ($sqlIntentMatch.Success -and $sqlIntentMatch.Value -notmatch 'Resolve-LabSqlIntentProvider|Invoke-LabNewContainerEnvironmentInteractive|Invoke-LabNewHyperVEnvironmentInteractive')
$batchConsoleSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/BatchConsole.ps1') -Raw
Add-ConsoleUiCheck 'Testmatrix nennt die unterstützten Betriebssysteme direkt im Eingabeprompt' (
    $batchConsoleSource -match 'Betriebssysteme, kommagetrennt \(Linux, Windows\) \[Linux\]'
)

# CUI-027: Der synchrone Einzelweg ist im Produktivcode verdrahtet und bleibt es.
$createMenuMatch = [regex]::Match($batchConsoleSource, 'function Show-LabCreateMenu \{[\s\S]+?(?=\r?\nfunction )')
Add-ConsoleUiCheck 'Erstellen-Menue bietet den synchronen Einzelweg als erste Wahl' (
    $createMenuMatch.Success -and
    $createMenuMatch.Value -match 'New-LabConsoleItem -Id New\b' -and
    $createMenuMatch.Value -match '-Shortcut 1\b' -and
    $createMenuMatch.Value -match 'ohne Queue'
)

$newEnvironmentMatch = [regex]::Match($entrySource, 'function Invoke-LabNewEnvironmentInteractive \{[\s\S]+?(?=\r?\nfunction Invoke-LabClearAutomatedTestEnvironmentInteractive)')
Add-ConsoleUiCheck 'Sofortweg entscheidet den Provider und erstellt selbst statt an den Composer zu delegieren' (
    $newEnvironmentMatch.Success -and
    $newEnvironmentMatch.Value -match 'Read-LabSqlEnvironmentIntentInteractive' -and
    $newEnvironmentMatch.Value -match 'Get-LabProviderAvailabilityMap' -and
    $newEnvironmentMatch.Value -match 'Resolve-LabSqlIntentProvider' -and
    $newEnvironmentMatch.Value -match 'Invoke-LabNewContainerEnvironmentInteractive' -and
    $newEnvironmentMatch.Value -match 'Invoke-LabNewHyperVEnvironmentInteractive'
)
Add-ConsoleUiCheck 'Sofortweg fragt vor der Mutation ausdruecklich zurueck und zeigt die Dauer' (
    $newEnvironmentMatch.Success -and
    $newEnvironmentMatch.Value -match 'Read-LabConfirm[^\r\n]+jetzt auf' -and
    $newEnvironmentMatch.Value -match 'Format-LabElapsedTime'
)

# Ein Baustein ohne Aufrufstelle im Produktivcode ist eine tote Funktion und keine Funktion der Oberflaeche.
$synchronousWiring = @(
    'Invoke-LabNewContainerEnvironmentInteractive'
    'Invoke-LabNewHyperVEnvironmentInteractive'
    'Resolve-LabSqlIntentProvider'
    'Resolve-LabDirectSaPasswordInteractive'
    'Show-LabSqlProviderDecision'
)
$productionSource = $entrySource + "`n" + $batchConsoleSource
$unwiredBuildingBlocks = @($synchronousWiring | Where-Object {
        ([regex]::Matches($productionSource, [regex]::Escape($_))).Count -lt 2
    })
Add-ConsoleUiCheck 'Bausteine des Sofortwegs werden aus Produktivcode aufgerufen und bleiben keine tote Funktion' (
    $unwiredBuildingBlocks.Count -eq 0
)

$containerCreationMatch = [regex]::Match($entrySource, 'function Invoke-LabNewContainerEnvironmentInteractive \{[\s\S]+?(?=\r?\nfunction Invoke-LabNewHyperVEnvironmentInteractive)')
Add-ConsoleUiCheck 'Containerpfad setzt entweder das uebergebene SA-Kennwort oder die Erzeugung, niemals beides' (
    $containerCreationMatch.Success -and
    $containerCreationMatch.Value -match '\[SecureString\]\$SaPassword' -and
    $containerCreationMatch.Value -match 'if \(\$SaPassword\)' -and
    $containerCreationMatch.Value -match 'GenerateSaPassword' -and
    $containerCreationMatch.Value -notmatch 'GenerateSaPassword=\$true'
)

$cui008Functions = @('Invoke-LabHyperVImageAction','Invoke-LabHyperVPreparedImageWorkflowMenu','Invoke-LabHyperVPublishedImageMenu','Invoke-LabHyperVAdvancedMenu','Invoke-LabHyperVWindowsBaselineMenu','Invoke-LabHyperVSqlAcceptanceMenu','Select-LabReusableHyperVWindowsSlotInteractive','Manage-LabHyperVEnvironmentInteractive')
$cui008MenuCoverage = @($cui008Functions | Where-Object {
    $match = [regex]::Match($entrySource, "function $([regex]::Escape($_)) \{[\s\S]+?(?=\r?\nfunction |\z)")
    -not $match.Success -or $match.Value -notmatch 'Invoke-LabConsoleMenu'
}).Count -eq 0
$sampleSelectionMatch = [regex]::Match($entrySource, 'function Select-LabSampleSelection \{[\s\S]+?(?=\r?\nfunction Select-LabHyperVPreparedArtifact)')
Add-ConsoleUiCheck 'CUI-008 migriert Hyper-V-Image-, Slot- und Verwaltungsmenüs' $cui008MenuCoverage
Add-ConsoleUiCheck 'Sample-Auswahl verwendet gemeinsame Mehrfachauswahl' ($sampleSelectionMatch.Success -and $sampleSelectionMatch.Value -match 'Invoke-LabConsoleMultiSelect')

$selectionPromptFindings = [Collections.Generic.List[string]]::new()
$selectionPromptPattern = '(?i)(Auswahl|auswählen|Nummer|\bModus\b|Patchstand|CU-Stand|Ressourcenprofil|Installationsmedium|Windows-Variante|Vorlage)'
$productFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Public') -Filter '*.ps1' -File
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Private') -Filter '*.ps1' -File |
        Where-Object Name -notin @('Common.ps1', 'ConsoleUi.ps1')
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Tools') -Filter '*.ps1' -File
    Get-Item -LiteralPath (Join-Path $repoRoot 'Invoke-SqlServerLab.ps1')
)
foreach ($file in $productFiles) {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($command in $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Read-Host'
    }, $true)) {
        if ($command.Extent.Text -match $selectionPromptPattern) {
            $selectionPromptFindings.Add(("{0}:{1}: {2}" -f $file.Name, $command.Extent.StartLineNumber, $command.Extent.Text))
        }
    }
}
Add-ConsoleUiCheck 'CUI-012-Inventar verbietet direkte Read-Host-Auswahlprompts' ($selectionPromptFindings.Count -eq 0)
if ($selectionPromptFindings.Count -gt 0) {
    foreach ($finding in $selectionPromptFindings) { Write-Host "    $finding" -ForegroundColor Yellow }
}
Add-ConsoleUiCheck 'CUI-014 migriert Connection Center und CMS auf gemeinsame Menüs' (
    ([regex]::Matches($connectionCenterSource, "Invoke-LabConsoleMenu -ScreenId 'connection-center")).Count -eq 2 -and
    $connectionCenterSource -notmatch 'Read-Host\s+.*Auswahl'
)
Add-ConsoleUiCheck 'CUI-015 und CUI-016 migrieren Erstellungs-, Patch-, Medien- und Builderauswahlen' (
    $entrySource -match 'function Select-LabConsoleDataItem' -and
    $entrySource -match "ScreenId 'hyperv-switch-select'" -and
    $entrySource -match "ScreenId 'hyperv-existing-vm-source-select'" -and
    $entrySource -match 'container-version-\$Provider' -and
    $entrySource -match 'sql-patch-\$Platform-\$BaseVersion'
)
Add-ConsoleUiCheck 'CUI-017 verwendet nur explizite Ergebnisansichten statt roher Enter-Pausen' (
    $entrySource -notmatch '\[Enter\] für Menü' -and
    $entrySource -notmatch '\[Enter\] für Auswahl' -and
    $entrySource -match 'Enter oder Escape: Zurück zum Hyper-V-Menü'
)

$attentionSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/AttentionStatus.ps1') -Raw
Add-ConsoleUiCheck 'CUI-010 besitzt gemeinsamen read-only Attention-Snapshot' ($attentionSource -match 'function Get-LabAttentionSnapshot' -and $attentionSource -match 'Get-SqlServerPatchOptions' -and $attentionSource -match 'SQL_SLOT_READY' -and $attentionSource -match 'RECOVERY_REQUIRED')
Add-ConsoleUiCheck 'Hauptmenü bindet Attention-Snapshot an gemeinsamen Renderer' ($entrySource -match 'Update-LabConsoleAttentionSnapshot' -and $entrySource -match 'Invoke-LabConsoleMenu[^\r\n]+-Snapshot \$snapshot')
$environmentMenuMatch = [regex]::Match($entrySource, 'function Show-LabEnvironmentMenu \{[\s\S]+?(?=\r?\nfunction Show-LabHyperVMenu)')
Add-ConsoleUiCheck 'Umgebungsmenue beginnt mit Verwaltung und gruppiert destruktive Sammelaktionen am Ende' ($environmentMenuMatch.Success -and $environmentMenuMatch.Value.IndexOf("-Id 'Manage'") -lt $environmentMenuMatch.Value.IndexOf("-Id 'ClearAutomatedTestEnvironment'") -and $environmentMenuMatch.Value.IndexOf("-Id 'ClearAutomatedTestEnvironment'") -lt $environmentMenuMatch.Value.IndexOf("-Id 'Clear'") -and $environmentMenuMatch.Value.IndexOf("-Id 'Clear'") -lt $environmentMenuMatch.Value.IndexOf("-Id 'back'"))
Add-ConsoleUiCheck 'Umgebungsmenue bietet genau einen zustandsabhaengigen Testgruppen-Lifecyclepunkt' (
    $entrySource -match 'function Get-LabAutomatedTestEnvironmentMenuState' -and
    $entrySource -match 'Action=if \(\$allStopped\) \{ ''Start'' \} else \{ ''Stop'' \}' -and
    $entrySource -match '-Id ''AutomatedTestEnvironmentLifecycle''' -and
    $entrySource -match 'Start-SqlServerLabAutomatedTestEnvironment -Force -Confirm:\$false' -and
    $entrySource -match 'Stop-SqlServerLabAutomatedTestEnvironment -Force -Confirm:\$false'
)
Add-ConsoleUiCheck 'Read-only Menueaktionen warten zentral auf genau eine Rueckkehrbestaetigung' ($entrySource -match '\$ActionName -in @\(''Status'', ''CleanupAudit'', ''Catalog'', ''DatabasePackageInventory'', ''DatabaseMigrationDependency''\)[\s\S]+?Wait-LabConsoleAcknowledgement')
Add-ConsoleUiCheck 'Cleanup-Audit-Menue bleibt read-only und zeigt Befunde mit Loesungsweg' (
    $entrySource -match "'CleanupAudit' \{[\s\S]+?Get-SqlServerLabCleanupAudit -NoWrite" -and
    $entrySource -match 'Show-LabCleanupAuditFindings -Findings \$result\.Audit\.Findings' -and
    $entrySource -match 'Loesung: \$\(\$finding\.Guidance\)'
)
Add-ConsoleUiCheck 'Umgebungsauswahl verwendet Namen als Primaertext und weist die technische Run-ID als Detail aus' ($entrySource -match 'function Get-LabRunSelectorPresentation' -and $entrySource -match 'Label = \$name' -and $entrySource -match "\('Run \{0\}'")
Add-ConsoleUiCheck 'Connection-Center-CMS ist als nicht mutierbarer Systemdienst klassifiziert' ($entrySource -match "'CMS-Systemdienst'" -and $entrySource -match '-Disabled:\(\$protected -or \(\$DisableSystemServices -and \$systemService\)\)')
Add-ConsoleUiCheck 'Containerverwaltung macht External-Languages-Erstinstallation und Reconcile sichtbar' (
    $entrySource -match 'function Manage-LabExternalRuntimeInteractive' -and
    $entrySource -match "-Id 'external-runtime' -Label 'External Languages installieren oder aendern'" -and
    $entrySource -match 'Get-SqlServerLabReconcilePlan[\s\S]+?Invoke-SqlServerLabReconcileAction'
)
Add-ConsoleUiCheck 'External-Languages-Menü behandelt Docker und Podman gleichwertig' (
    $entrySource -match "provider -in @\('docker', 'podman'\)" -and
    $entrySource -match "version -in @\('2019','2022','2025'\)"
)
Add-ConsoleUiCheck 'Hyper-V zeigt die derzeit nicht atomare External-Languages-Nachinstallation begründet deaktiviert' (
    $entrySource -match "-Label 'External Languages nachinstallieren'[\s\S]+?-Disabled"
)
Add-ConsoleUiCheck 'Hauptmenue startet ohne vorab ausgegebene und sofort ueberschriebene Umgebungsuebersicht' ([regex]::Match($entrySource, 'function Invoke-SqlServerLab \{[\s\S]+?(?=\r?\n# =+)').Value -notmatch 'Show-LabBanner')
Add-ConsoleUiCheck 'Interaktiver Status zeigt Connection String und gespeichertes generiertes SA-Passwort' ($entrySource -match 'function Show-LabEnvironmentStatusInteractive' -and $entrySource -match "'SA-Passwort \(automatisch erzeugt\)'" -and $entrySource -match 'Show-LabEnvironmentStatusInteractive -RunId')
Add-ConsoleUiCheck 'Infrastrukturmenue deaktiviert Hyper-V begruendet wenn der Provider nicht verwendbar ist' ($batchConsoleSource -match '-Id HyperVArea[\s\S]{0,300}?-Disabled:\(-not \$hyperVAvailable\)' -and $batchConsoleSource -match 'Test-HyperVAvailable')
Add-ConsoleUiCheck 'Statusauswahl bietet Alle und einzelne Umgebungen an' ($entrySource -match "-Id '__all' -Label 'Alle Umgebungen'" -and $entrySource -match "-ScreenId 'environment-status-select'" -and $entrySource -match '\$selectedRuns = if')
Add-ConsoleUiCheck 'Datenbankmenue trennt Verbindungszentrale und reinen Lab-Katalog klar' ($entrySource -match "-Id 'ConnectionCenter' -Label 'Verbindungszentrale und SSMS-Endpunkte'.*-Shortcut 'c'" -and $entrySource -match "-Id 'Catalog' -Label 'Lab-Katalog prüfen'.*-Shortcut 'k'" -and $entrySource -match "Katalogdatei validieren; kein CMS-Zugang")
Add-ConsoleUiCheck 'CU-Status ist im Medienmenü sichtbar und seine Ergebnisansicht wartet auf eine Rückkehrbestätigung' ($entrySource -match "-Id 'CuStatus' -Label 'Aktuelle CUs bei Microsoft prüfen'.*-Shortcut 'w'" -and $entrySource -match "function Show-LabCuStatusInteractive \{[\s\S]+?Get-SqlServerLabCuStatus[\s\S]+?Wait-LabConsoleAcknowledgement -Prompt ' Enter oder Escape: Zurück zu Storage & Medien'")
Add-ConsoleUiCheck 'Betriebssystem-Downloadquellen sind ohne Hyper-V-Menü erreichbar und bleiben lesbar' (
    $entrySource -match "-Id 'OperatingSystemSources' -Label 'Betriebssystem-Downloadquellen anzeigen'.*-Shortcut 'o'" -and
    $entrySource -match "function Show-LabOperatingSystemSourcesInteractive \{[\s\S]+?Get-LabMediaSourceCatalog[\s\S]+?Where-Object[\s\S]+?Wait-LabConsoleAcknowledgement -Prompt '  Enter oder Escape: Zurück zu Storage & Medien'"
)
Add-ConsoleUiCheck 'Verbindungszentrale hält Ausgabeaktionen lesbar bis zur Rückkehrbestätigung' ($connectionCenterSource -match "\$choice -in @\('1', '2', '3', '5', '6', '7'\)[\s\S]+?Wait-LabConsoleAcknowledgement -Prompt '  Enter oder Escape: Zurück zur SQL-Verbindungszentrale'")
Add-ConsoleUiCheck 'CMS bevorzugt Container, kann vorhandene Hyper-V-SQL-Umgebung uebernehmen und zeigt Zugang lesbar an' ($connectionCenterSource -match "@\('docker', 'podman'" -and $connectionCenterSource -match "-Id adopt -Label 'Bestehende SQL-Umgebung als CMS verwenden'" -and $connectionCenterSource -match "workflowKind -eq 'hyperv-lab'" -and $connectionCenterSource -match 'function Register-SqlServerLabCmsEnvironment' -and $connectionCenterSource -match "-Id '5' -Label 'CMS-Zugang anzeigen'" -and $connectionCenterSource -match 'Show-LabEnvironmentStatusInteractive -RunId' -and $connectionCenterSource -match "Wait-LabConsoleAcknowledgement -Prompt '  Enter oder Escape: Zurück zur CMS-Verwaltung'")
Add-ConsoleUiCheck 'CMS-Menue steuert generierte Passwoerter im Anzeigenamen mit Klartextwarnung' ($connectionCenterSource -match "-Id '4' -Label 'Generiertes Passwort im CMS-Namen anzeigen'" -and $connectionCenterSource -match 'CmsShowGeneratedPasswordInName' -and $connectionCenterSource -match 'Screenshots und CMS-Backups')
Add-ConsoleUiCheck 'Manuell bereitgestelltes CMS-Passwort wird nicht als generiert markiert' ($connectionCenterSource -match 'PasswordOrigin = \$passwordOrigin' -and $connectionCenterSource -match '\$passwordOrigin = ''ProvidedForCms''' -and $entrySource -match 'IsNullOrWhiteSpace\(\[string\]\$cms.PasswordOrigin\)')
Add-ConsoleUiCheck 'Generierter Passwortabruf umfasst Hyper-V- und automatisierte Testumgebungen' ($entrySource -match 'Get-SqlServerLabGeneratedSqlAccess -RunId \$RunId' -and $entrySource -match 'Test-LabAutomatedTestEnvironmentRun -RunId \$RunId')
Add-ConsoleUiCheck 'CUI-011 besitzt Resize-, Write-Plan- und Recovery-Injektionspunkte' ($consoleSource -match 'function Get-LabConsoleWritePlan' -and $consoleSource -match '\[scriptblock\]\$GetViewport' -and $consoleSource -match '\[scriptblock\]\$SessionCompleter' -and $consoleSource -match 'Cursoransicht nicht verfügbar')
Add-ConsoleUiCheck 'Session stellt urspruengliche Cursorsichtbarkeit wieder her' ($consoleSource -match '\[Console\]::CursorVisible = \[bool\]\$Session\.CursorVisible')

$emptyQueue = [PSCustomObject]@{ items=@(); waitingUserGates=0 }
$emptyAvailability = Get-LabQueueMenuAvailability -Queue $emptyQueue -Batches @()
Add-ConsoleUiCheck 'Leere Queue deaktiviert alle auftragsbezogenen Aktionen' (-not $emptyAvailability.HasOverview -and -not $emptyAvailability.HasUserGates -and -not $emptyAvailability.HasCandidates -and -not $emptyAvailability.CanChangePriority -and -not $emptyAvailability.CanMove -and -not $emptyAvailability.CanPauseOrResume -and -not $emptyAvailability.CanStopOperation -and -not $emptyAvailability.CanStopBatch -and -not $emptyAvailability.CanRunScheduler)

$singleQueue = [PSCustomObject]@{ items=@([PSCustomObject]@{ operationId='one'; status='Queued'; priority='Normal' }); waitingUserGates=0 }
$singleAvailability = Get-LabQueueMenuAvailability -Queue $singleQueue -Batches @()
Add-ConsoleUiCheck 'Ein einzelner Vorgang kann pausiert oder gestoppt, aber nicht priorisiert oder umgereiht werden' ($singleAvailability.CanPauseOrResume -and $singleAvailability.CanStopOperation -and -not $singleAvailability.CanChangePriority -and -not $singleAvailability.CanMove)

$pairQueue = [PSCustomObject]@{ items=@([PSCustomObject]@{ operationId='one'; status='Queued'; priority='Normal' }, [PSCustomObject]@{ operationId='two'; status='Paused'; priority='Normal' }); waitingUserGates=0 }
$pairAvailability = Get-LabQueueMenuAvailability -Queue $pairQueue -Batches @([PSCustomObject]@{ status='Queued' })
Add-ConsoleUiCheck 'Zwei wartende Vorgaenge derselben Prioritaet aktivieren Priorisierung, Umreihung und Batch-Aktionen' ($pairAvailability.CanChangePriority -and $pairAvailability.CanMove -and $pairAvailability.CanStopBatch -and @($pairAvailability.MovableOperationIds).Count -eq 2)

function Read-LabConsoleTextInput { [PSCustomObject]@{ Status='Cancelled'; Value=$null } }
$composerCancelled = $true
try { Invoke-LabBatchComposerInteractive } catch { $composerCancelled = $false }
Add-ConsoleUiCheck 'Batch-Composer kehrt nach Escape am Namen ohne weitere Aktion zurueck' $composerCancelled

# CUI-028: Das Statusband muss im importierten Modul funktionieren, nicht nur im flachen Testscope.
# Diese Datei dot-sourced die Konsolenquellen und macht sie damit global sichtbar. Eine Closure im
# Modul findet sie dann selbst dann, wenn sie modulprivat waeren. Der Nachweis muss deshalb in einem
# eigenen Prozess ohne dot-sourced Funktionen laufen; genau daran ist die Cursoransicht von Haupt-
# und Vorgangsmenue unbemerkt in den nummerierten Fallback gekippt.
$moduleProbePath = Join-Path ([IO.Path]::GetTempPath()) ("console-ui-module-probe-$([guid]::NewGuid().ToString('N')).ps1")
$moduleProbe = @'
$ErrorActionPreference = 'Stop'
$module = Import-Module '__MODULE__' -Force -PassThru
$result = & $module {
    function Test-LabStatusProviderInModule {
        $provider = New-LabQueueStatusProvider -Height 3 -Width 78 `
            -OperationReader { @() } `
            -QueueReader { [PSCustomObject]@{ maxWorkers = 2; runningWorkers = 0; items = @() } } `
            -Clock { [datetime]'2026-09-07T12:00:00Z' }
        & $provider 0
    }
    $band = @()
    $bandError = ''
    try { $band = @(Test-LabStatusProviderInModule) } catch { $bandError = [string]$_.Exception.Message }

    # Ein selbst vergebenes Kennwort liegt DPAPI-geschuetzt im Run und muss dem Eigentuemer
    # zugaenglich bleiben, sonst ist die Umgebung nicht mehr benutzbar.
    $passwordRoot = Join-Path ([IO.Path]::GetTempPath()) ("sa-fact-$([guid]::NewGuid().ToString('N'))")
    $passwordFact = [PSCustomObject]@{ Available = $false; Origin = 'None'; Length = 0 }
    try {
        $runId = '11111111-2222-3333-4444-555555555555'
        $runDirectory = Join-Path (Join-Path $passwordRoot 'runs') $runId
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
        $secret = ConvertTo-SecureString 'Str3ng-Selbst-Vergeben!' -AsPlainText -Force
        $null = Save-LabSecret -Path $runDirectory -Name 'sa-password' -Secret $secret
        $fact = Get-LabRunSaPasswordFact -RunId $runId -StateRoot $passwordRoot
        $passwordFact = [PSCustomObject]@{
            Available = [bool]$fact.Available
            Origin    = [string]$fact.Origin
            Length    = if ($fact.Password) { ([string]$fact.Password).Length } else { 0 }
        }
    }
    catch { $passwordFact = [PSCustomObject]@{ Available = $false; Origin = "FEHLER: $($_.Exception.Message)"; Length = 0 } }
    finally { Remove-Item -LiteralPath $passwordRoot -Recurse -Force -ErrorAction SilentlyContinue }

    $frames = [Collections.Generic.List[object]]::new()
    $menu = Invoke-LabConsoleMenu -ScreenId 'status-resilience' -Title 'Resilienz' -Items @(
        New-LabConsoleItem -Id 'go' -Label 'Weiter' -Shortcut '1'
    ) -StatusHeight 3 -StatusProvider { throw 'Statusquelle kaputt' } -Snapshot $null `
        -Capability ([PSCustomObject]@{ Supported = $true; Mode = 'CURSOR'; Reasons = @() }) `
        -ReadKey { [PSCustomObject]@{ Key = 'Enter'; KeyChar = [char]13; Modifiers = 0 } } `
        -FrameWriter { param($s, $f) $frames.Add($f) } `
        -GetViewport { [PSCustomObject]@{ Width = 80; Height = 20 } } `
        -SessionFactory { [PSCustomObject]@{ OriginTop = 0; PreviousLineCount = 0; ForegroundColor = 'Gray' } } `
        -SessionCompleter { }

    $script:databasePackageInventoryCalls = 0
    $script:databasePackageExportCalls = 0
    $script:databasePackageAttachCalls = 0
    $script:databaseMigrationDependencyCalls = 0
    $script:databaseBackupCalls = 0
    $script:databaseRestoreCalls = 0
    Set-Item Function:script:Get-SqlServerLabDatabasePackage -Value {
        $script:databasePackageInventoryCalls++
        [PSCustomObject]@{
            DatabasePackageId='11111111-2222-4333-8444-555555555555';Availability='SELECTABLE'
            IntegrityValidation='DEFERRED_UNTIL_USE';DatabaseName='Evidence';SourceSqlMajorVersion='17'
            ObjectCount=2;Bytes=1048576;AttachStatus='TARGET_BINDING_REQUIRED';DependencyCategories=@()
        }
    }
    Set-Item Function:script:Get-SqlServerLabDatabaseMigrationDependency -Value {
        $script:databaseMigrationDependencyCalls++
        [PSCustomObject]@{
            DatabaseName='Evidence';ObservationStatus='SQL_ENGINE_COMPLETE_EXTERNAL_REVIEW_REQUIRED'
            Dependencies=@([PSCustomObject]@{Category='SERVER_LOGIN_MAPPING';Status='NOT_DETECTED';Count=0;RequiredAction='SCRIPT_AND_REMAP'})
            MigrationBoundary=[PSCustomObject]@{PortableRestoreStatus='MANUAL_REVIEW';Blockers=@()}
        }
    }
    $script:databaseTargetProvider = 'docker'
    Set-Item Function:script:Resolve-LabRunInstance -Value {
        [PSCustomObject]@{HostName='127.0.0.1';Port=14330;Provider=$script:databaseTargetProvider;ContainerName='synthetic-runtime';Version='2025'}
    }
    Set-Item Function:script:Resolve-LabDataRootForUse -Value { param($DataRoot) [string]$DataRoot }
    $script:restoreConfirmAnswers = [Collections.Generic.Queue[bool]]::new()
    Set-Item Function:script:Read-LabConfirm -Value {
        if ($script:restoreConfirmAnswers.Count -gt 0) { return $script:restoreConfirmAnswers.Dequeue() }
        $true
    }
    Set-Item Function:script:Get-LabDatabaseBackupSelection -Value {
        [PSCustomObject]@{
            BackupSetId='11111111-2222-4333-8444-555555555555';Availability='SELECTABLE'
            DatabaseName='Evidence';SourceSqlMajorVersion='17';Bytes=1048576;CreatedAt='2026-09-08T00:00:00Z'
        }
    }
    Set-Item Function:script:Get-LabDatabaseBackup -Value { [PSCustomObject]@{ Record=[PSCustomObject]@{ BackupSetId='11111111-2222-4333-8444-555555555555' } } }
    $script:databaseRestoreTargetExists = $false
    Set-Item Function:script:Test-LabDatabaseExists -Value { [bool]$script:databaseRestoreTargetExists }
    Set-Item Function:script:Backup-SqlServerLabDatabase -Value {
        $script:databaseBackupCalls++
        [PSCustomObject]@{
            Status='BACKUP_REUSABLE';DatabaseName='Evidence';Bytes=1048576
            BackupSetId='11111111-2222-4333-8444-555555555555'
            PersistentStorageId='22222222-3333-4444-8555-666666666666'
        }
    }
    Set-Item Function:script:Export-SqlServerLabDatabasePackage -Value {
        $script:databasePackageExportCalls++
        [PSCustomObject]@{
            Status='REUSABLE';DatabaseName='Evidence';Provider='docker'
            DatabasePackageId='33333333-4444-4555-8666-777777777777'
            PersistentStorageId='44444444-5555-4666-8777-888888888888'
        }
    }
    Set-Item Function:script:Invoke-SqlServerLabDatabasePackageAttach -Value {
        [CmdletBinding(SupportsShouldProcess)]
        param($DatabasePackageId,$RunId,$InstanceId,$GuestCredential,$DataRoot,[switch]$Recover)
        $script:databasePackageAttachCalls++
        [PSCustomObject]@{
            Status=if($WhatIfPreference){'PLANNED'}else{'ATTACHED'};DatabaseName='Evidence'
            DatabasePackageId=$DatabasePackageId;TargetRunId=$RunId;TargetInstanceId=$InstanceId
            Provider='hyperv';TargetSqlMajorVersion=17;TargetFileStreamCapable=$true
            TargetCopyVerified=(-not $WhatIfPreference);AttachInvoked=(-not $WhatIfPreference)
            PostconditionVerified=(-not $WhatIfPreference);Blockers=@();Recovery='NOT_REQUIRED'
        }
    }
    Set-Item Function:script:Restore-SqlServerLabDatabase -Value {
        $script:databaseRestoreCalls++
        [PSCustomObject]@{
            Success=$true;DatabaseName='Evidence';Files=2;Duration=[TimeSpan]::FromSeconds(1)
            Provider='docker';BackupSetId='11111111-2222-4333-8444-555555555555'
        }
    }
    $probePassword = ConvertTo-SecureString 'synthetic-only' -AsPlainText -Force
    & { Invoke-LabDatabasePackageInventoryInteractive -DataRoot 'synthetic-root' } 6>$null
    & { Invoke-LabDatabaseMigrationDependencyInteractive -RunId '11111111-2222-4333-8444-555555555555' `
        -InstanceId primary -DatabaseName Evidence -SaPassword $probePassword -TdeRecoveryEvidenceVerified } 6>$null
    & { Invoke-LabDatabaseBackupInteractive -RunId '11111111-2222-4333-8444-555555555555' `
        -InstanceId primary -DatabaseName Evidence -SaPassword $probePassword -DataRoot 'synthetic-root' } 6>$null
    & { Invoke-LabDatabasePackageExportInteractive -RunId '11111111-2222-4333-8444-555555555555' `
        -InstanceId primary -DatabaseName Evidence -DataRoot 'synthetic-root' } 6>$null
    $script:databaseTargetProvider = 'hyperv'
    & { Invoke-LabDatabasePackageExportInteractive -RunId '11111111-2222-4333-8444-555555555555' `
        -InstanceId primary -DatabaseName Evidence -DataRoot 'synthetic-root' } 6>$null
    $probeGuestCredential = [PSCredential]::new('Administrator', $probePassword)
    & { Invoke-LabDatabasePackageAttachInteractive -RunId '11111111-2222-4333-8444-555555555555' `
        -InstanceId primary -DatabasePackageId '11111111-2222-4333-8444-555555555555' `
        -GuestCredential $probeGuestCredential -DataRoot 'synthetic-root' -Recover:$false } 6>$null
    $script:databaseTargetProvider = 'docker'
    & { Invoke-LabDatabasePackageAttachInteractive -RunId '11111111-2222-4333-8444-555555555555' `
        -InstanceId primary -DatabasePackageId '11111111-2222-4333-8444-555555555555' `
        -GuestCredential $probeGuestCredential -DataRoot 'synthetic-root' -Recover:$false } 6>$null
    & { Invoke-LabDatabaseRestoreInteractive -RunId '11111111-2222-4333-4444-555555555555' `
        -InstanceId primary -BackupSetId '11111111-2222-4333-8444-555555555555' `
        -DatabaseName Evidence -SaPassword $probePassword -DataRoot 'synthetic-root' } 6>$null
    $script:databaseRestoreTargetExists = $true
    $script:restoreConfirmAnswers.Enqueue($false)
    & { Invoke-LabDatabaseRestoreInteractive -RunId '11111111-2222-4333-4444-555555555555' `
        -InstanceId primary -BackupSetId '11111111-2222-4333-8444-555555555555' `
        -DatabaseName Evidence -SaPassword $probePassword -DataRoot 'synthetic-root' } 6>$null

    [PSCustomObject]@{
        BandLines    = $band.Count
        BandHeadline = if ($band.Count -gt 0) { [string]$band[0] } else { '' }
        BandError    = $bandError
        MenuStatus   = [string]$menu.Status
        MenuFrames   = $frames.Count
        Degraded     = @($frames[0].Lines | Where-Object { $_ -match 'Statusband nicht verfuegbar: Statusquelle kaputt' }).Count
        Journal      = @(Get-LabMessage | Where-Object { $_.message -match 'CONSOLE_STATUS_PROVIDER_FAILED' }).Count
        PasswordFact = $passwordFact
        PackageInventoryCalls = $script:databasePackageInventoryCalls
        MigrationDependencyCalls = $script:databaseMigrationDependencyCalls
        DatabaseBackupCalls = $script:databaseBackupCalls
        DatabasePackageExportCalls = $script:databasePackageExportCalls
        DatabasePackageExportHyperVRejected = $script:databasePackageExportCalls -eq 1
        DatabasePackageAttachCalls = $script:databasePackageAttachCalls
        DatabasePackageAttachDockerRejected = $script:databasePackageAttachCalls -eq 2
        DatabaseRestoreCalls = $script:databaseRestoreCalls
        DatabaseRestoreReplaceRejected = $script:databaseRestoreCalls -eq 1
    }
}
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
$result | ConvertTo-Json -Compress -Depth 6
'@
$moduleProbe = $moduleProbe.Replace('__MODULE__', (Join-Path $repoRoot 'SqlServerLab.psd1'))
Set-Content -LiteralPath $moduleProbePath -Value $moduleProbe -Encoding utf8
try {
    $probeRaw = & pwsh -NoProfile -File $moduleProbePath 2>&1
    $probeJson = @($probeRaw | Where-Object { "$_" -match '^\{' } | Select-Object -Last 1)
    $probe = if ($probeJson.Count -eq 1) { "$($probeJson[0])" | ConvertFrom-Json } else { $null }

    Add-ConsoleUiCheck 'Statuslieferant loest seine Funktionen auch ohne dot-sourced Scope im Modul auf' (
        $null -ne $probe -and [string]::IsNullOrEmpty($probe.BandError) -and
        $probe.BandLines -eq 3 -and $probe.BandHeadline -match 'Queue 0 · Worker 0/2 · Blockiert 0'
    )
    Add-ConsoleUiCheck 'Ein defektes Statusband benennt den Ausfall und kostet weder Cursoransicht noch Auswahl' (
        $null -ne $probe -and $probe.MenuStatus -eq 'Selected' -and $probe.MenuFrames -ge 1 -and
        $probe.Degraded -eq 1 -and $probe.Journal -ge 1
    )
    Add-ConsoleUiCheck 'Ein selbst vergebenes SA-Kennwort bleibt dem Eigentuemer zugaenglich und wird als solches ausgewiesen' (
        $null -ne $probe -and $probe.PasswordFact.Available -and
        $probe.PasswordFact.Origin -eq 'UserSupplied' -and $probe.PasswordFact.Length -eq 23
    )
    Add-ConsoleUiCheck 'Datenbankmenue ruft Paketbestand und Migrationsinventur im echten Modulscope auf' (
        $null -ne $probe -and $probe.PackageInventoryCalls -eq 2 -and $probe.MigrationDependencyCalls -eq 1
    )
    Add-ConsoleUiCheck 'Datenbankmenue ruft den bestätigten Backup-Pfad im echten Modulscope auf' (
        $null -ne $probe -and $probe.DatabaseBackupCalls -eq 1
    )
    Add-ConsoleUiCheck 'Datenbankmenue ruft den bestätigten Paketexport im echten Modulscope auf' (
        $null -ne $probe -and $probe.DatabasePackageExportCalls -eq 1
    )
    Add-ConsoleUiCheck 'Paketexport-Gegenbeweis verweigert Hyper-V vor dem mutierenden Core-Aufruf' (
        $null -ne $probe -and $probe.DatabasePackageExportHyperVRejected
    )
    Add-ConsoleUiCheck 'Datenbankmenue ruft Attach-Vorprüfung und bestätigten Attach im echten Modulscope auf' (
        $null -ne $probe -and $probe.DatabasePackageAttachCalls -eq 2
    )
    Add-ConsoleUiCheck 'Paket-Attach-Gegenbeweis verweigert Docker vor dem Core-Aufruf' (
        $null -ne $probe -and $probe.DatabasePackageAttachDockerRejected
    )
    Add-ConsoleUiCheck 'Datenbankmenue ruft den bestätigten Restore-Pfad im echten Modulscope auf' (
        $null -ne $probe -and $probe.DatabaseRestoreCalls -eq 1
    )
    Add-ConsoleUiCheck 'Restore-Gegenbeweis verweigert ein vorhandenes Ziel ohne WITH-REPLACE-Bestaetigung' (
        $null -ne $probe -and $probe.DatabaseRestoreReplaceRejected
    )
}
finally { Remove-Item -LiteralPath $moduleProbePath -Force -ErrorAction SilentlyContinue }

# CUI-031: Die Statusansicht darf ein hinterlegtes Kennwort nicht als fehlend ausgeben.
Add-ConsoleUiCheck 'Statusansicht nennt Verfuegbarkeit und Herkunft des SA-Kennworts wahrheitsgemaess' (
    $mainMenuSource -match 'function Get-LabRunSaPasswordFact' -and
    $mainMenuSource -match '\$passwordFact = Get-LabRunSaPasswordFact -RunId \$RunId -StateRoot \$StateRoot' -and
    $mainMenuSource -match "SA-Passwort \(selbst vergeben\)" -and
    $mainMenuSource -match 'im Run kein Kennwort hinterlegt' -and
    $mainMenuSource -notmatch 'nicht automatisch gespeichert oder f'
)
Add-ConsoleUiCheck 'Connection-Center-Exporte betten weiterhin ausschliesslich selbst erzeugte Kennwoerter ein' (
    $connectionCenterSource -match 'Get-LabAutomaticallyGeneratedRunSaPassword' -and
    $connectionCenterSource -notmatch 'Get-LabRunSaPasswordFact'
)

# CUI-030: Jede angebotene Aktion muss aus der Oberflaeche erreichbar sein.
# Eine Aktion, die nur ueber -Action existiert, ist fuer die Konsole eine tote Funktion.
$connectionCenterMenuSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Sync-SqlServerLabConnectionCenter.ps1') -Raw
$containerUpdateSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Update-SqlServerLabContainer.ps1') -Raw
$menuSourceAll = $mainMenuSource + "`n" + $batchConsoleSource + "`n" + $connectionCenterMenuSource + "`n" + $containerUpdateSource
$actionValidateSet = [regex]::Match($mainMenuSource, "ValidateSet\('New',[^)]+\)").Value
$declaredActions = @([regex]::Matches($actionValidateSet, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
$reachableIds = @([regex]::Matches($menuSourceAll, "New-LabConsoleItem -Id '?([A-Za-z][A-Za-z0-9]*)'?") |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
# Diese beiden werden vor dem Aktionsschalter abgefangen und tragen eigene Menue-Ids.
$dispatchedBeforeSwitch = @('BatchPlan', 'Queue')
$unreachableActions = @($declaredActions | Where-Object { $_ -notin $reachableIds -and $_ -notin $dispatchedBeforeSwitch })
Add-ConsoleUiCheck 'Jede Aktion der ValidateSet ist ueber einen Menueeintrag erreichbar' (
    $declaredActions.Count -ge 30 -and $unreachableActions.Count -eq 0
)
if ($unreachableActions.Count -gt 0) {
    Write-Host ('        Nicht erreichbar: ' + ($unreachableActions -join ', ')) -ForegroundColor Red
}

$rootEntrySource = Get-Content -LiteralPath (Join-Path $repoRoot 'Invoke-SqlServerLab.ps1') -Raw
$rootValidateSet = [regex]::Match($rootEntrySource, "ValidateSet\('New',[^)]+\)").Value
Add-ConsoleUiCheck 'Wurzeleinstieg und Modulfunktion bieten dieselbe Aktionsliste an' (
    $rootValidateSet -eq $actionValidateSet
)

Add-ConsoleUiCheck 'Flache Bereichsmenues bieten mehr als eine Handlungsmoeglichkeit' (
    ([regex]::Matches([regex]::Match($batchConsoleSource, "function Show-LabCmsMenu \{[\s\S]+?(?=\r?\nfunction )").Value, 'New-LabConsoleItem')).Count -ge 3 -and
    ([regex]::Matches([regex]::Match($batchConsoleSource, "function Show-LabCreateMenu \{[\s\S]+?(?=\r?\nfunction )").Value, 'New-LabConsoleItem')).Count -ge 5 -and
    ([regex]::Matches([regex]::Match($batchConsoleSource, "function Show-LabMaintenanceMenu \{[\s\S]+?(?=\r?\nfunction )").Value, 'New-LabConsoleItem')).Count -ge 7
)

Add-ConsoleUiCheck 'SQL-2025-KI bleibt innerhalb der achtteiligen Menuestruktur erreichbar' (
    $mainMenuSource -match "function Show-LabDatabaseMenu[\s\S]{0,1600}?New-LabConsoleItem -Id 'AiArea'" -and
    $batchConsoleSource -match "'Ai' \{ Show-LabAiMenu \}" -and
    $batchConsoleSource -match "\`$action -eq 'AiArea'.+Invoke-LabAreaMenuInteractive -Area Ai" -and
    $mainMenuSource -match "function Show-LabAiMenu[\s\S]{0,2500}?New-LabConsoleItem -Id 'AiScenarioPlan'" -and
    $mainMenuSource -match "function Show-LabAiMenu[\s\S]{0,3000}?New-LabConsoleItem -Id 'AiRetrievalEvaluation'" -and
    $mainMenuSource -match "function Show-LabAiMenu[\s\S]{0,3000}?New-LabConsoleItem -Id 'AiGoldenRagEvaluation'" -and
    $mainMenuSource -match "function Show-LabAiMenu[\s\S]{0,3000}?New-LabConsoleItem -Id 'AiGuidedDemo'"
)
$databaseMenuSource = [regex]::Match($mainMenuSource, "function Show-LabDatabaseMenu \{[\s\S]+?(?=\r?\nfunction )").Value
$databaseReadOnlyActions = @('DatabasePackageInventory', 'DatabaseMigrationDependency')
$databaseMutationActions = @('DatabaseBackup', 'DatabaseRestore', 'DatabasePackageExport', 'DatabasePackageAttach')
$databaseRequiredActions = @($databaseReadOnlyActions + $databaseMutationActions)
$missingDatabaseReadOnlyHandlers = @($databaseRequiredActions | Where-Object {
        $databaseMenuSource -notmatch "New-LabConsoleItem -Id '$_'" -or
        $mainMenuSource -notmatch "'$_' \{ [A-Za-z0-9-]+ \}"
    })
Add-ConsoleUiCheck 'Datenbankmenue bietet Backup, Restore, beide Paketmutationen und beide Inventuren mit echten Handlern an' (
    $missingDatabaseReadOnlyHandlers.Count -eq 0 -and
    @($databaseRequiredActions | Where-Object { $_ -in $declaredActions }).Count -eq 6
)
$missingDatabaseHandlerCounterexample = @(@($databaseRequiredActions) + 'DatabaseMissingHandler' | Where-Object {
        $databaseMenuSource -notmatch "New-LabConsoleItem -Id '$_'" -or
        $mainMenuSource -notmatch "'$_' \{ [A-Za-z0-9-]+ \}"
    })
Add-ConsoleUiCheck 'Datenbank-Anti-Waisen-Vertrag erkennt einen fehlenden Handler als Gegenbeweis' (
    $missingDatabaseHandlerCounterexample.Count -eq 1 -and $missingDatabaseHandlerCounterexample[0] -eq 'DatabaseMissingHandler'
)
Add-ConsoleUiCheck 'Read-only Datenbankaktionen halten ihre Ausgabe bis zur Rueckkehr sichtbar' (
    $mainMenuSource -match "@\('Status', 'CleanupAudit', 'Catalog', 'DatabasePackageInventory', 'DatabaseMigrationDependency'\)"
)
$backupCommandSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Backup-SqlServerLabDatabase.ps1') -Raw
$backupUiSource = [regex]::Match($mainMenuSource, "function Invoke-LabDatabaseBackupInteractive \{[\s\S]+?(?=\r?\nfunction )").Value
Add-ConsoleUiCheck 'Backup-Menue bindet Ziel, fluechtige Credentials, Lab_Data und explizite Bestaetigung vor Mutation' (
    $backupUiSource -match 'Resolve-LabRunInstance -RunId \$RunId -InstanceId \$InstanceId' -and
    $backupUiSource -match 'Resolve-LabDataRootForUse -DataRoot \$DataRoot' -and
    $backupUiSource -match "Read-Host '  SA-Passwort' -AsSecureString" -and
    $backupUiSource -match "Provider -eq 'hyperv'.+GuestCredential" -and
    $backupUiSource -match "Read-LabConfirm -Prompt '  Verifiziertes Backup jetzt erstellen" -and
    $backupUiSource -match 'Backup-SqlServerLabDatabase @arguments'
)
Add-ConsoleUiCheck 'Oeffentliches Backup besitzt WhatIf und UI unterdrueckt erst nach eigener Bestaetigung den zweiten Prompt' (
    $backupCommandSource -match "CmdletBinding\(DefaultParameterSetName='Direct',SupportsShouldProcess,ConfirmImpact='Medium'\)" -and
    $backupCommandSource -match '\$PSCmdlet\.ShouldProcess\(' -and
    $backupCommandSource.IndexOf('$PSCmdlet.ShouldProcess') -lt $backupCommandSource.IndexOf('New-LabDatabaseLibraryBackup @arguments') -and
    $backupUiSource -match 'DataRoot=\$DataRoot;Confirm=\$false'
)
Add-ConsoleUiCheck 'Backup-Ergebnis bleibt sichtbar und gibt weder Pfad noch Hash aus' (
    $mainMenuSource -match 'if \(\$ActionName -in @\(''DatabaseBackup'', ''DatabaseRestore'', ''DatabasePackageExport'', ''DatabasePackageAttach''\)\) \{ Wait-LabConsoleAcknowledgement \}' -and
    $backupUiSource -match 'BackupSetId' -and $backupUiSource -match 'PersistentStorageId' -and
    $backupUiSource -notmatch '\$result\.(Path|Sha256)'
)
$packageExportCommandSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Export-SqlServerLabDatabasePackage.ps1') -Raw
$packageExportUiSource = [regex]::Match($mainMenuSource, "function Invoke-LabDatabasePackageExportInteractive \{[\s\S]+?(?=\r?\nfunction )").Value
Add-ConsoleUiCheck 'Paketexport-Menue bindet Containerquelle, Run-Secret, Lab_Data und Offline-Folge vor Mutation' (
    $packageExportUiSource -match 'Resolve-LabRunInstance -RunId \$RunId -InstanceId \$InstanceId' -and
    $packageExportUiSource -match "Provider -notin @\('docker', 'podman'\)" -and
    $packageExportUiSource -match 'Resolve-LabDataRootForUse -DataRoot \$DataRoot' -and
    $packageExportUiSource -match 'zum Run gehörende SA-Secret' -and
    $packageExportUiSource -match 'bleibt nach erfolgreichem Export offline' -and
    $packageExportUiSource -match "Read-LabConfirm -Prompt '  Datenbank jetzt exklusiv offline schalten" -and
    $packageExportUiSource -match 'Export-SqlServerLabDatabasePackage -RunId \$RunId'
)
Add-ConsoleUiCheck 'Oeffentlicher Paketexport besitzt WhatIf und UI unterdrueckt erst nach eigener Bestaetigung den zweiten Prompt' (
    $packageExportCommandSource -match "CmdletBinding\(SupportsShouldProcess, ConfirmImpact='High'\)" -and
    $packageExportCommandSource -match '\$PSCmdlet\.ShouldProcess\(' -and
    $packageExportCommandSource.IndexOf('$PSCmdlet.ShouldProcess') -lt $packageExportCommandSource.IndexOf('Export-LabContainerDatabasePackage') -and
    $packageExportUiSource -match '-DataRoot \$DataRoot -Confirm:\$false'
)
Add-ConsoleUiCheck 'Paketexport-Ergebnis bleibt sichtbar und gibt weder Pfad, Hash noch Secret aus' (
    $packageExportUiSource -match 'DatabasePackageId' -and $packageExportUiSource -match 'PersistentStorageId' -and
    $packageExportUiSource -notmatch '\$result\.(Path|Sha256|Password|Credential|Secret)'
)
$packageAttachCommandSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLabDatabasePackageAttach.ps1') -Raw
$packageAttachUiSource = [regex]::Match($mainMenuSource, "function Invoke-LabDatabasePackageAttachInteractive \{[\s\S]+?(?=\r?\nfunction )").Value
Add-ConsoleUiCheck 'Paket-Attach-Menue bindet Paket, Hyper-V-Ziel, fluechtiges Gastcredential und SQL-Default-Data vor Mutation' (
    $packageAttachUiSource -match 'Resolve-LabRunInstance -RunId \$RunId -InstanceId \$InstanceId' -and
    $packageAttachUiSource -match "Provider -ne 'hyperv'" -and
    $packageAttachUiSource -match 'Get-SqlServerLabDatabasePackage -DataRoot \$DataRoot' -and
    $packageAttachUiSource -match "Read-Host '  Gastpasswort für PowerShell Direct' -AsSecureString" -and
    $packageAttachUiSource -match 'Invoke-SqlServerLabDatabasePackageAttach @arguments -WhatIf' -and
    $packageAttachUiSource -match 'live aus SQL Server' -and
    $packageAttachUiSource -match 'Invoke-SqlServerLabDatabasePackageAttach @arguments -Confirm:\$false'
)
Add-ConsoleUiCheck 'Paket-Attach trennt Recovery, bestätigt standardmäßig ablehnend und benennt Cleanup' (
    $packageAttachUiSource -match "Recovery nur für einen vorhandenen RECOVERY_REQUIRED-Journalstand" -and
    $packageAttachUiSource -match '\$arguments\.Recover = \$true' -and
    $packageAttachUiSource -match 'Detach und Cleanup' -and
    $packageAttachUiSource -match 'Gebundenes Attach-Journal jetzt recovern' -and
    $packageAttachUiSource -match 'Verifiziertes Paket jetzt kopieren und an SQL Server anhängen' -and
    $packageAttachUiSource -match '-Default \$false'
)
Add-ConsoleUiCheck 'Oeffentliches Paket-Attach besitzt WhatIf vor Kopie und getrennte journalgebundene Recovery' (
    $packageAttachCommandSource -match "CmdletBinding\(SupportsShouldProcess, ConfirmImpact = 'High'\)" -and
    $packageAttachCommandSource -match 'Get-LabDatabasePackage -DatabasePackageId \$DatabasePackageId' -and
    $packageAttachCommandSource -match 'Test-LabDatabasePackageAttachJournal -Journal \$journal' -and
    $packageAttachCommandSource -match 'Invoke-LabHyperVDatabasePackageAttachRecovery' -and
    $packageAttachCommandSource.IndexOf('$PSCmdlet.ShouldProcess') -lt $packageAttachCommandSource.IndexOf('Invoke-LabHyperVDatabasePackageAttachPlan')
)
Add-ConsoleUiCheck 'Paket-Attach-Ergebnis bleibt sichtbar und gibt weder Pfad, Hash noch Credential aus' (
    $packageAttachUiSource -match 'DatabasePackageId' -and $packageAttachUiSource -match 'Postcondition' -and
    $packageAttachUiSource -notmatch '\$result\.(Path|Sha256|Password|Credential|Secret|Journal)'
)
$restoreCommandSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Restore-SqlServerLabDatabase.ps1') -Raw
$restoreUiSource = [regex]::Match($mainMenuSource, "function Invoke-LabDatabaseRestoreInteractive \{[\s\S]+?(?=\r?\nfunction )").Value
Add-ConsoleUiCheck 'Restore-Menue bindet Ziel, verifiziertes BackupSet, Credentials und Konfliktmodus vor Mutation' (
    $restoreUiSource -match 'Resolve-LabRunInstance -RunId \$RunId -InstanceId \$InstanceId' -and
    $restoreUiSource -match 'Get-LabDatabaseBackupSelection -DataRoot \$DataRoot' -and
    $restoreUiSource -match 'Get-LabDatabaseBackup -BackupSetId \$BackupSetId -DataRoot \$DataRoot' -and
    $restoreUiSource -match 'Test-LabDatabaseExists -HostName \$target.HostName -Port \$target.Port' -and
    $restoreUiSource -match 'WITH REPLACE überschreiben' -and
    $restoreUiSource -match "Read-LabConfirm -Prompt '  Gebundenes BackupSet jetzt" -and
    $restoreUiSource -match 'Restore-SqlServerLabDatabase @arguments'
)
Add-ConsoleUiCheck 'Oeffentlicher Restore besitzt WhatIf und UI unterdrueckt erst nach eigener Bestaetigung den zweiten Prompt' (
    $restoreCommandSource -match "CmdletBinding\(DefaultParameterSetName = 'Direct', SupportsShouldProcess, ConfirmImpact = 'Medium'\)" -and
    $restoreCommandSource -match '\$PSCmdlet\.ShouldProcess\(' -and
    $restoreCommandSource.IndexOf('$PSCmdlet.ShouldProcess') -lt $restoreCommandSource.IndexOf('Resolve-LabArtifact') -and
    $restoreCommandSource.IndexOf('$PSCmdlet.ShouldProcess') -lt $restoreCommandSource.IndexOf('Start-LabStorageSqlOperation') -and
    $restoreUiSource -match 'NonInteractive=\$true;Confirm=\$false'
)
Add-ConsoleUiCheck 'Restore-Ergebnis bleibt sichtbar und gibt weder Pfad noch Hash aus' (
    $restoreUiSource -match 'BackupSetId' -and $restoreUiSource -match 'Files' -and
    $restoreUiSource -notmatch '\$result\.(Path|Sha256|Artifact)'
)
Add-ConsoleUiCheck 'Restore-Core entfernt die exakt gebundene temporaere Containerkopie im finally-Pfad' (
    $restoreCommandSource -match 'finally \{' -and
    $restoreCommandSource -match 'elseif \(\$runtimeBackupCopied[\s\S]+?rm -f -- \$runtimeBackupPath'
)
$aiMenuSource = [regex]::Match($mainMenuSource, "function Show-LabAiMenu \{[\s\S]+?(?=\r?\nfunction )").Value
$offeredAiActions = @([regex]::Matches($aiMenuSource, "New-LabConsoleItem -Id '([^']+)'") |
        ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne 'back' })
$unhandledAiActions = @($offeredAiActions | Where-Object { $mainMenuSource -notmatch "'$_' \{ [A-Za-z0-9-]+ \}" })
Add-ConsoleUiCheck 'Alle angebotenen KI-Menueaktionen besitzen einen Handler' (
    $offeredAiActions.Count -ge 8 -and $unhandledAiActions.Count -eq 0
)
$missingAiHandlerCounterexample = @(@($offeredAiActions) + 'AiMissingHandler' |
        Where-Object { $mainMenuSource -notmatch "'$_' \{ [A-Za-z0-9-]+ \}" })
Add-ConsoleUiCheck 'KI-Anti-Waisen-Vertrag erkennt einen fehlenden Handler als Gegenbeweis' (
    $missingAiHandlerCounterexample.Count -eq 1 -and $missingAiHandlerCounterexample[0] -eq 'AiMissingHandler'
)

$guidedDemoSource = [regex]::Match($mainMenuSource, "function Invoke-LabAiGuidedDemoInteractive \{[\s\S]+?(?=\r?\nfunction )").Value
$guidedDemoIds = @([regex]::Matches($guidedDemoSource, "New-LabConsoleItem -Id '([^']+)'") |
        ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne 'back' })
$unhandledGuidedDemoIds = @($guidedDemoIds | Where-Object { $guidedDemoSource -notmatch "'$_' \{" })
Add-ConsoleUiCheck 'Gefuehrte KI-Demos bieten Vector, Retrieval, Golden-RAG und read-only Agent ohne Waisen an' (
    $guidedDemoIds.Count -eq 4 -and
    @($guidedDemoIds | Where-Object { $_ -in @('vector','retrieval','rag','agent') }).Count -eq 4 -and
    $unhandledGuidedDemoIds.Count -eq 0
)
Add-ConsoleUiCheck 'Gefuehrte KI-Demos verwenden die bestehenden Szenario-, Metrik-, RAG- und Agent-Vertraege' (
    $guidedDemoSource -match "Invoke-LabAiScenarioRunInteractive -ScenarioId 'vector-core-ci'" -and
    $guidedDemoSource -match "Read-LabAiRetrievalGoldenDataset -DatasetId 'sql-lab-rag-de' -Version '1.0'" -and
    $guidedDemoSource -match 'Measure-SqlServerLabAiRetrieval' -and
    $guidedDemoSource -match "Invoke-LabAiGoldenRagEvaluationInteractive -CaseId 'backup-frequency'" -and
    $guidedDemoSource -match 'Invoke-LabAiDiagnosticInteractive -Guided'
)
Add-ConsoleUiCheck 'Gefuehrte KI-Demos fuehren weder Cloudmodell noch teures gpt-oss ein' (
    $guidedDemoSource -notmatch 'ollama-gpt-oss|gpt-oss:120b|AiCloud'
)

Write-Host "`nErgebnis: $passed PASS, $failed FAIL"
if ($failed -gt 0) { exit 1 }
