#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Private/ConsoleUi.ps1')

$passed = 0
$failed = 0
function Add-ConsoleUiCheck {
    param([string]$Name, [bool]$Success)
    if ($Success) { $script:passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}

Write-Host "`nSQL_Server_Lab - Console UI Checks" -ForegroundColor Cyan
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

$writeSession = [PSCustomObject]@{ PreviousLineCount=5 }
$writePlan = Get-LabConsoleWritePlan -Session $writeSession -Frame ([PSCustomObject]@{ Lines=@('kurz','neu') }) -Width 12 -Height 6
Add-ConsoleUiCheck 'Write-Plan ueberschreibt alte Restzeilen vollstaendig' ($writePlan.Rows.Count -eq 5 -and @($writePlan.Rows | Where-Object ClearsPrevious).Count -eq 3 -and @($writePlan.Rows | Where-Object { $_.Text.Length -ne 11 }).Count -eq 0)

$state.Snapshot = [PSCustomObject]@{ AttentionItems=@(
    [PSCustomObject]@{ Severity='Critical'; Message='Recovery erforderlich.' }
    [PSCustomObject]@{ Severity='Warning'; Message='CU-Paket fehlt.' }
) }
$attentionFrame = Get-LabConsoleFrame -State $state -Title 'Attention' -Width 50 -Height 10
Add-ConsoleUiCheck 'Footer zeigt read-only Attention Items aus dem Snapshot' (@($attentionFrame.Lines | Where-Object { $_ -match '^Offen \[!\]' }).Count -eq 2)
$state.Snapshot = $null

$fallback = Invoke-LabConsoleMenu -ScreenId 'fallback' -Title 'Fallback' -Items $items -ForceFallback -ReadInput { param($prompt) '2' }
Add-ConsoleUiCheck 'Read-Host-Fallback waehlt nummeriert' ($fallback.Status -eq 'Selected' -and $fallback.SelectedItem.Id -eq 'two')

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

$consoleSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ConsoleUi.ps1') -Raw
$containerSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Update-SqlServerLabContainer.ps1') -Raw
Add-ConsoleUiCheck 'Key-Loops verwenden kein Clear-Host' ($consoleSource -notmatch 'Clear-Host' -and $containerSource -notmatch 'Clear-Host')

$entrySource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1') -Raw
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

$attentionSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/AttentionStatus.ps1') -Raw
Add-ConsoleUiCheck 'CUI-010 besitzt gemeinsamen read-only Attention-Snapshot' ($attentionSource -match 'function Get-LabAttentionSnapshot' -and $attentionSource -match 'Get-SqlServerPatchOptions' -and $attentionSource -match 'SQL_SLOT_READY' -and $attentionSource -match 'RECOVERY_REQUIRED')
Add-ConsoleUiCheck 'Hauptmenü bindet Attention-Snapshot an gemeinsamen Renderer' ($entrySource -match 'Update-LabConsoleAttentionSnapshot' -and $entrySource -match 'Invoke-LabConsoleMenu[^\r\n]+-Snapshot \$snapshot')
Add-ConsoleUiCheck 'CUI-011 besitzt Resize-, Write-Plan- und Recovery-Injektionspunkte' ($consoleSource -match 'function Get-LabConsoleWritePlan' -and $consoleSource -match '\[scriptblock\]\$GetViewport' -and $consoleSource -match '\[scriptblock\]\$SessionCompleter' -and $consoleSource -match 'Cursoransicht nicht verfügbar')
Add-ConsoleUiCheck 'Session stellt urspruengliche Cursorsichtbarkeit wieder her' ($consoleSource -match '\[Console\]::CursorVisible = \[bool\]\$Session\.CursorVisible')

Write-Host "`nErgebnis: $passed PASS, $failed FAIL"
if ($failed -gt 0) { exit 1 }
