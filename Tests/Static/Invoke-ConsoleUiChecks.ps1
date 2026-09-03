#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Private/Common.ps1')
. (Join-Path $repoRoot 'Private/ConsoleUi.ps1')
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
    ([regex]::Matches($consoleSource, 'Read-LabConsoleKey -ReadKey \$ReadKey')).Count -eq 4 -and
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
Add-ConsoleUiCheck 'Read-only Menueaktionen warten zentral auf genau eine Rueckkehrbestaetigung' ($entrySource -match '\$ActionName -in @\(''Status'', ''CleanupAudit'', ''Catalog''\)[\s\S]+?Wait-LabConsoleAcknowledgement')
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
Add-ConsoleUiCheck 'Hauptmenue deaktiviert Hyper-V-Infrastruktur wenn der Provider nicht verwendbar ist' ($entrySource -match '-Id ''hyperv''.*-Disabled:\(-not \$hyperVAvailable\)' -and $entrySource -match 'Test-HyperVAvailable')
Add-ConsoleUiCheck 'Statusauswahl bietet Alle und einzelne Umgebungen an' ($entrySource -match "-Id '__all' -Label 'Alle Umgebungen'" -and $entrySource -match "-ScreenId 'environment-status-select'" -and $entrySource -match '\$selectedRuns = if')
Add-ConsoleUiCheck 'Datenbankmenue trennt Verbindungszentrale und reinen Lab-Katalog klar' ($entrySource -match "-Id 'ConnectionCenter' -Label 'Verbindungszentrale und SSMS-Endpunkte'.*-Shortcut 'c'" -and $entrySource -match "-Id 'Catalog' -Label 'Lab-Katalog prüfen'.*-Shortcut 'k'" -and $entrySource -match "Katalogdatei validieren; kein CMS-Zugang")
Add-ConsoleUiCheck 'CU-Status ist im Medienmenü sichtbar und seine Ergebnisansicht wartet auf eine Rückkehrbestätigung' ($entrySource -match "-Id 'CuStatus' -Label 'Aktuelle CUs bei Microsoft prüfen'.*-Shortcut 'w'" -and $entrySource -match "function Show-LabCuStatusInteractive \{[\s\S]+?Get-SqlServerLabCuStatus[\s\S]+?Wait-LabConsoleAcknowledgement -Prompt ' Enter oder Escape: Zurück zu Storage & Medien'")
Add-ConsoleUiCheck 'Betriebssystem-Downloadquellen sind ohne Hyper-V-Menü erreichbar und bleiben lesbar' (
    $entrySource -match "-Id 'OperatingSystemSources' -Label 'Betriebssystem-Downloadquellen anzeigen'.*-Shortcut 'o'" -and
    $entrySource -match "function Show-LabOperatingSystemSourcesInteractive \{[\s\S]+?Get-LabMediaSourceCatalog[\s\S]+?Where-Object[\s\S]+?Wait-LabConsoleAcknowledgement -Prompt '  Enter oder Escape: Zurück zu Storage & Medien'"
)
Add-ConsoleUiCheck 'Verbindungszentrale hält Ausgabeaktionen lesbar bis zur Rückkehrbestätigung' ($connectionCenterSource -match "\$choice -in @\('1', '2', '3', '5', '6', '7'\)[\s\S]+?Wait-LabConsoleAcknowledgement -Prompt '  Enter oder Escape: Zurück zur SQL-Verbindungszentrale'")
Add-ConsoleUiCheck 'CMS bevorzugt Container, kann vorhandene Hyper-V-SQL-Umgebung uebernehmen und zeigt Zugang lesbar an' ($connectionCenterSource -match "@\('docker', 'podman'" -and $connectionCenterSource -match "-Id adopt -Label 'Bestehende SQL-Umgebung als CMS verwenden'" -and $connectionCenterSource -match "workflowKind -eq 'hyperv-lab'" -and $connectionCenterSource -match 'function Register-SqlServerLabCmsEnvironment' -and $connectionCenterSource -match "-Id '4' -Label 'CMS-Zugang anzeigen'" -and $connectionCenterSource -match 'Show-LabEnvironmentStatusInteractive -RunId' -and $connectionCenterSource -match "Wait-LabConsoleAcknowledgement -Prompt '  Enter oder Escape: Zurück zur CMS-Verwaltung'")
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

Write-Host "`nErgebnis: $passed PASS, $failed FAIL"
if ($failed -gt 0) { exit 1 }
