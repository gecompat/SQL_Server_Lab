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

$frame = Get-LabConsoleFrame -State $state -Title 'Test' -Width 30 -Height 8
Add-ConsoleUiCheck 'Frame besitzt begrenzten Viewport und Fokusmarker' ($frame.Lines.Count -eq 8 -and @($frame.Lines | Where-Object { $_ -match '^>' }).Count -eq 1)
Add-ConsoleUiCheck 'Framezeilen bleiben innerhalb der Breite' (@($frame.Lines | Where-Object Length -gt 29).Count -eq 0)

$fallback = Invoke-LabConsoleMenu -ScreenId 'fallback' -Title 'Fallback' -Items $items -ForceFallback -ReadInput { param($prompt) '2' }
Add-ConsoleUiCheck 'Read-Host-Fallback waehlt nummeriert' ($fallback.Status -eq 'Selected' -and $fallback.SelectedItem.Id -eq 'two')

$keys = [System.Collections.Generic.Queue[object]]::new()
$keys.Enqueue([PSCustomObject]@{ Key='DownArrow'; KeyChar=[char]0 })
$keys.Enqueue([PSCustomObject]@{ Key='Enter'; KeyChar=[char]13 })
$renderCount = 0
$cursorResult = Invoke-LabConsoleMenu -ScreenId 'cursor' -Title 'Cursor' -Items $items -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $keys.Dequeue() } -FrameWriter { param($session, $renderedFrame) $script:renderCount++ }
Add-ConsoleUiCheck 'Key-Loop navigiert und rendert lokal neu' ($cursorResult.SelectedItem.Id -eq 'two' -and $renderCount -eq 2)

$refreshKeys = [System.Collections.Generic.Queue[object]]::new()
$refreshKeys.Enqueue([PSCustomObject]@{ Key='F5'; KeyChar=[char]0 })
$refreshResult = Invoke-LabConsoleMenu -ScreenId 'refresh' -Title 'Refresh' -Items $items -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $refreshKeys.Dequeue() } -FrameWriter { param($session, $renderedFrame) }
Add-ConsoleUiCheck 'F5 fordert Refresh an statt Runtime selbst aufzurufen' ($refreshResult.Status -eq 'Refresh')

$formKeys = [System.Collections.Generic.Queue[object]]::new()
$formKeys.Enqueue([PSCustomObject]@{ Key='Enter'; KeyChar=[char]13 })
$formKeys.Enqueue([PSCustomObject]@{ Key='F10'; KeyChar=[char]0 })
$formKeys.Enqueue([PSCustomObject]@{ Key='Enter'; KeyChar=[char]13 })
$fields = @(
    New-LabConsoleField -Id 'cpu' -Label 'CPU' -Value 2 -Editor { param($current, $values) 4 } -Validator { param($value, $values) if ([int]$value -lt 1) { 'CPU muss positiv sein.' } }
)
$formResult = Invoke-LabConsoleForm -ScreenId 'form' -Title 'Form' -Fields $fields -Capability ([PSCustomObject]@{ Supported=$true }) -ReadKey { $formKeys.Dequeue() } -FrameWriter { param($session, $renderedFrame) }
Add-ConsoleUiCheck 'Formular bearbeitet, validiert und reviewed vor Bestaetigung' ($formResult.Status -eq 'Confirmed' -and [int]$formResult.Values['cpu'] -eq 4)

$sensitiveFieldRejected = $false
try { $null = New-LabConsoleField -Id 'secret' -Label 'Secret' -Value 'plaintext' -Sensitive } catch { $sensitiveFieldRejected = $_.Exception.Message -eq 'CONSOLE_UI_SENSITIVE_INITIAL_VALUE_NOT_ALLOWED' }
Add-ConsoleUiCheck 'Sensitive Klartextwerte gelangen nicht in den UI-State' $sensitiveFieldRejected

$consoleSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ConsoleUi.ps1') -Raw
$containerSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Update-SqlServerLabContainer.ps1') -Raw
Add-ConsoleUiCheck 'Key-Loops verwenden kein Clear-Host' ($consoleSource -notmatch 'Clear-Host' -and $containerSource -notmatch 'Clear-Host')

$entrySource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1') -Raw
$sqlIntentMatch = [regex]::Match($entrySource, 'function Read-LabSqlEnvironmentIntentInteractive \{[\s\S]+?\n\}\r?\n\r?\nfunction Resolve-LabSqlIntentProvider')
Add-ConsoleUiCheck 'SQL-Zielkonfiguration verwendet gemeinsames Formular und Review' ($sqlIntentMatch.Success -and $sqlIntentMatch.Value -match 'Invoke-LabConsoleForm' -and $sqlIntentMatch.Value -match 'New-LabConsoleField')
Add-ConsoleUiCheck 'Providerentscheidung bleibt ausserhalb der Formularnavigation' ($sqlIntentMatch.Success -and $sqlIntentMatch.Value -notmatch 'Resolve-LabSqlIntentProvider|Invoke-LabNewContainerEnvironmentInteractive|Invoke-LabNewHyperVEnvironmentInteractive')

Write-Host "`nErgebnis: $passed PASS, $failed FAIL"
if ($failed -gt 0) { exit 1 }
