if ([string]::IsNullOrWhiteSpace([string]$script:LabConsoleMode)) {
    $script:LabConsoleMode = 'Auto'
}

function Test-LabConsoleCapability {
    [CmdletBinding()]
    param()

    $reasons = [System.Collections.Generic.List[string]]::new()
    if ([string]$script:LabConsoleMode -eq 'Fallback') {
        $reasons.Add('FORCED_FALLBACK')
        return [PSCustomObject]@{
            Supported = $false
            Mode = 'READ_HOST'
            Reasons = @($reasons)
        }
    }
    try {
        if ([Console]::IsInputRedirected) { $reasons.Add('INPUT_REDIRECTED') }
        if ([Console]::IsOutputRedirected) { $reasons.Add('OUTPUT_REDIRECTED') }
        if (-not $Host.UI -or -not $Host.UI.RawUI) { $reasons.Add('RAW_UI_UNAVAILABLE') }
        if ($Host.Name -in @('ServerRemoteHost', 'Default Host')) { $reasons.Add('HOST_NOT_INTERACTIVE') }

        $null = [Console]::WindowWidth
        $null = [Console]::WindowHeight
        $null = [Console]::CursorLeft
        $null = [Console]::CursorTop
        $cursorVisible = [Console]::CursorVisible
        [Console]::CursorVisible = $cursorVisible
    }
    catch {
        $reasons.Add('SYSTEM_CONSOLE_UNAVAILABLE')
    }

    [PSCustomObject]@{
        Supported = ($reasons.Count -eq 0)
        Mode = if ($reasons.Count -eq 0) { 'CURSOR' } else { 'READ_HOST' }
        Reasons = @($reasons)
    }
}

function Test-LabConsoleInterruptKey {
    [CmdletBinding()]
    param([AllowNull()][object]$Key)

    if ($null -eq $Key) { return $false }
    $keyCharacter = [string]$Key.KeyChar
    $isControlCharacter = $keyCharacter.Length -gt 0 -and [int][char]$keyCharacter[0] -eq 3
    $isModifiedC = [string]$Key.Key -eq 'C' -and [string]$Key.Modifiers -match 'Control'
    return $isControlCharacter -or $isModifiedC
}

function Assert-LabConsoleKeyNotInterrupted {
    [CmdletBinding()]
    param([AllowNull()][object]$Key)

    if (Test-LabConsoleInterruptKey -Key $Key) {
        throw [Management.Automation.PipelineStoppedException]::new()
    }
}

function Read-LabConsoleKey {
    [CmdletBinding()]
    param([scriptblock]$ReadKey)

    if ($ReadKey) { return & $ReadKey }
    $previousTreatControlCAsInput = [Console]::TreatControlCAsInput
    try {
        [Console]::TreatControlCAsInput = $true
        return [Console]::ReadKey($true)
    }
    finally {
        [Console]::TreatControlCAsInput = $previousTreatControlCAsInput
    }
}

function Read-LabConsoleTextInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [AllowEmptyString()][string]$Default = '',
        [switch]$AsSecureString,
        [switch]$MaskInput,
        [AllowNull()][object]$Capability,
        [scriptblock]$ReadInput,
        [scriptblock]$ReadKey,
        [scriptblock]$WriteText
    )

    if (-not $Capability) { $Capability = Test-LabConsoleCapability }
    $promptText = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    if (-not [bool]$Capability.Supported) {
        $fallbackPrompt = if ($AsSecureString -or $MaskInput) { "$promptText (Ctrl+C: Abbruch)" } else { "$promptText (0: Abbruch)" }
        $value = if ($ReadInput) { & $ReadInput $fallbackPrompt } elseif ($AsSecureString) { Microsoft.PowerShell.Utility\Read-Host $fallbackPrompt -AsSecureString } elseif ($MaskInput) { Microsoft.PowerShell.Utility\Read-Host $fallbackPrompt -MaskInput } else { Microsoft.PowerShell.Utility\Read-Host $fallbackPrompt }
        if ($null -eq $value) { return [PSCustomObject]@{ Status='Cancelled'; Value=$null } }
        if ($AsSecureString) { return [PSCustomObject]@{ Status='Confirmed'; Value=$value } }
        if (-not $MaskInput -and ([string]$value -eq '0' -or [string]$value -eq [string][char]27)) {
            return [PSCustomObject]@{ Status='Cancelled'; Value=$null }
        }
        return [PSCustomObject]@{ Status='Confirmed'; Value=$(if ([string]::IsNullOrWhiteSpace([string]$value)) { $Default } else { [string]$value }) }
    }

    $write = {
        param([string]$Text)
        if ($WriteText) { & $WriteText $Text } else { [Console]::Write($Text) }
    }
    $value = ''
    $secureValue = if ($AsSecureString) { [Security.SecureString]::new() } else { $null }
    $length = 0
    & $write "$promptText (Esc: Abbruch): "
    while ($true) {
        $key = Read-LabConsoleKey -ReadKey $ReadKey
        Assert-LabConsoleKeyNotInterrupted -Key $key
        switch ([string]$key.Key) {
            'Escape' {
                if ($secureValue) { $secureValue.Dispose() }
                & $write ([Environment]::NewLine)
                return [PSCustomObject]@{ Status='Cancelled'; Value=$null }
            }
            'Enter' {
                & $write ([Environment]::NewLine)
                if ($secureValue) {
                    $secureValue.MakeReadOnly()
                    return [PSCustomObject]@{ Status='Confirmed'; Value=$secureValue }
                }
                return [PSCustomObject]@{ Status='Confirmed'; Value=$(if ([string]::IsNullOrWhiteSpace($value)) { $Default } else { $value }) }
            }
            'Backspace' {
                if ($length -gt 0) {
                    $length--
                    if ($secureValue) { $secureValue.RemoveAt($length) }
                    else { $value = $value.Substring(0, $value.Length - 1) }
                    & $write "`b `b"
                }
            }
            default {
                $character = [char]$key.KeyChar
                if (-not [char]::IsControl($character)) {
                    $length++
                    if ($secureValue) { $secureValue.AppendChar($character) } else { $value += $character }
                    & $write $(if ($AsSecureString -or $MaskInput) { '*' } else { [string]$character })
                }
            }
        }
    }
}

function Wait-LabConsoleAcknowledgement {
    [CmdletBinding()]
    param(
        [string]$Prompt = '  Enter oder Escape: Zurueck',
        [AllowNull()][object]$Capability,
        [scriptblock]$ReadKey,
        [scriptblock]$WriteText
    )

    if (-not $Capability) { $Capability = Test-LabConsoleCapability }
    if (-not [bool]$Capability.Supported) {
        $null = Microsoft.PowerShell.Utility\Read-Host $Prompt
        return
    }
    $write = {
        param([string]$Text)
        if ($WriteText) { & $WriteText $Text } else { [Console]::Write($Text) }
    }
    & $write "$Prompt "
    while ($true) {
        $key = Read-LabConsoleKey -ReadKey $ReadKey
        Assert-LabConsoleKeyNotInterrupted -Key $key
        if ([string]$key.Key -in @('Enter','Escape')) {
            & $write ([Environment]::NewLine)
            return
        }
    }
}

function New-LabConsoleItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()][object]$Value,
        [AllowEmptyString()][string]$Shortcut = '',
        [string[]]$Aliases = @(),
        [switch]$Disabled,
        [AllowEmptyString()][string]$DisabledReason = '',
        [AllowEmptyString()][string]$Help = '',
        [AllowNull()][object]$Data
    )

    [PSCustomObject]@{
        Id = $Id
        Label = $Label
        Value = $Value
        Shortcut = $Shortcut
        Aliases = @($Aliases)
        Disabled = $Disabled.IsPresent
        DisabledReason = $DisabledReason
        Help = $Help
        Data = $Data
    }
}

function Resolve-LabConsoleNumericShortcut {
    <# .SYNOPSIS Löst eine gepufferte mehrstellige numerische Menüauswahl auf. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Buffer
    )

    $prefixMatches = @()
    foreach ($item in $Items) {
        if ([bool]$item.Disabled) { continue }
        $tokens = @([string]$item.Shortcut) + @($item.Aliases | ForEach-Object { [string]$_ })
        foreach ($token in @($tokens | Where-Object { $_ -match '^\d+$' } | Sort-Object -Unique)) {
            if ($token.StartsWith($Buffer, [StringComparison]::OrdinalIgnoreCase)) {
                $prefixMatches += [PSCustomObject]@{ Item=$item; Token=$token; Exact=($token -eq $Buffer) }
            }
        }
    }
    $exactMatch = @($prefixMatches | Where-Object Exact | Select-Object -First 1)[0]
    $exactItem = if ($exactMatch) { $exactMatch.Item } else { $null }
    $hasLongerMatch = @($prefixMatches | Where-Object { -not $_.Exact }).Count -gt 0
    $status = if ($prefixMatches.Count -eq 0) { 'Invalid' }
        elseif ($exactItem -and -not $hasLongerMatch) { 'Selected' }
        else { 'Pending' }
    return [PSCustomObject]@{ Status=$status; Item=$exactItem; HasLongerMatch=$hasLongerMatch; Matches=$prefixMatches.Count }
}

function New-LabConsoleField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()][object]$Value,
        [AllowEmptyString()][string]$Shortcut = '',
        [scriptblock]$Editor,
        [scriptblock]$Validator,
        [scriptblock]$Formatter,
        [switch]$Sensitive,
        [switch]$Required
    )

    if ($Sensitive -and $null -ne $Value) {
        throw 'CONSOLE_UI_SENSITIVE_INITIAL_VALUE_NOT_ALLOWED'
    }
    [PSCustomObject]@{
        Id = $Id
        Label = $Label
        Value = $Value
        Shortcut = $Shortcut
        Editor = $Editor
        Validator = $Validator
        Formatter = $Formatter
        Sensitive = $Sensitive.IsPresent
        Required = $Required.IsPresent
    }
}

function New-LabConsoleState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScreenId,
        [Parameter(Mandatory)][object[]]$Items,
        [string]$SelectedId,
        [ValidateRange(1, 200)][int]$ViewportHeight = 10
    )

    $normalizedItems = @($Items)
    $selectedIndex = -1
    if ($SelectedId) {
        for ($index = 0; $index -lt $normalizedItems.Count; $index++) {
            if ([string]$normalizedItems[$index].Id -eq $SelectedId -and -not [bool]$normalizedItems[$index].Disabled) {
                $selectedIndex = $index
                break
            }
        }
    }
    if ($selectedIndex -lt 0) {
        for ($index = 0; $index -lt $normalizedItems.Count; $index++) {
            if (-not [bool]$normalizedItems[$index].Disabled) {
                $selectedIndex = $index
                break
            }
        }
    }

    [PSCustomObject]@{
        ScreenId = $ScreenId
        Items = $normalizedItems
        SelectedId = if ($selectedIndex -ge 0) { [string]$normalizedItems[$selectedIndex].Id } else { $null }
        SelectedIndex = $selectedIndex
        TopIndex = 0
        ViewportHeight = $ViewportHeight
        Values = @{}
        Validation = @{}
        Message = ''
        Snapshot = $null
        Dirty = $false
    }
}

function Set-LabConsoleViewport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [ValidateRange(1, 200)][int]$ViewportHeight
    )

    $State.ViewportHeight = $ViewportHeight
    $maximumTop = [Math]::Max(0, @($State.Items).Count - $ViewportHeight)
    if ($State.SelectedIndex -lt $State.TopIndex) {
        $State.TopIndex = [Math]::Max(0, $State.SelectedIndex)
    }
    elseif ($State.SelectedIndex -ge ($State.TopIndex + $ViewportHeight)) {
        $State.TopIndex = $State.SelectedIndex - $ViewportHeight + 1
    }
    $State.TopIndex = [Math]::Min([Math]::Max(0, $State.TopIndex), $maximumTop)
    $State
}

function Sync-LabConsoleState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][object[]]$Items
    )

    $previousId = [string]$State.SelectedId
    $previousIndex = [int]$State.SelectedIndex
    $State.Items = @($Items)
    $State.SelectedIndex = -1

    for ($index = 0; $index -lt $State.Items.Count; $index++) {
        if ([string]$State.Items[$index].Id -eq $previousId -and -not [bool]$State.Items[$index].Disabled) {
            $State.SelectedIndex = $index
            break
        }
    }
    if ($State.SelectedIndex -lt 0 -and $State.Items.Count -gt 0) {
        $start = [Math]::Min([Math]::Max(0, $previousIndex), $State.Items.Count - 1)
        foreach ($index in @($start..($State.Items.Count - 1)) + @(0..$start)) {
            if (-not [bool]$State.Items[$index].Disabled) {
                $State.SelectedIndex = $index
                break
            }
        }
    }
    $State.SelectedId = if ($State.SelectedIndex -ge 0) { [string]$State.Items[$State.SelectedIndex].Id } else { $null }
    Set-LabConsoleViewport -State $State -ViewportHeight $State.ViewportHeight
}

function Move-LabConsoleSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][ValidateSet('Up','Down','PageUp','PageDown','Home','End')][string]$Direction
    )

    $selectable = [System.Collections.Generic.List[int]]::new()
    for ($index = 0; $index -lt @($State.Items).Count; $index++) {
        if (-not [bool]$State.Items[$index].Disabled) { $selectable.Add($index) }
    }
    if ($selectable.Count -eq 0) { return $State }

    $slot = 0
    for ($index = 0; $index -lt $selectable.Count; $index++) {
        if ($selectable[$index] -eq [int]$State.SelectedIndex) { $slot = $index; break }
    }
    $page = [Math]::Max(1, [int]$State.ViewportHeight)
    $slot = switch ($Direction) {
        'Up'       { [Math]::Max(0, $slot - 1) }
        'Down'     { [Math]::Min($selectable.Count - 1, $slot + 1) }
        'PageUp'   { [Math]::Max(0, $slot - $page) }
        'PageDown' { [Math]::Min($selectable.Count - 1, $slot + $page) }
        'Home'     { 0 }
        'End'      { $selectable.Count - 1 }
    }
    $State.SelectedIndex = $selectable[$slot]
    $State.SelectedId = [string]$State.Items[$State.SelectedIndex].Id
    Set-LabConsoleViewport -State $State -ViewportHeight $State.ViewportHeight
}

function Format-LabConsoleText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text, [ValidateRange(1, 1000)][int]$Width)

    $clean = ([string]$Text) -replace '[\r\n\t]', ' '
    if ($clean.Length -le $Width) { return $clean }
    if ($Width -le 3) { return $clean.Substring(0, $Width) }
    return $clean.Substring(0, $Width - 3) + '...'
}

function Get-LabConsoleFrame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$Title,
        [string]$Subtitle = '',
        [string]$Footer = 'Pfeile: Navigation  Enter: Auswahl  F1/?: Hilfe  Esc: Zurueck  F5: Aktualisieren',
        [AllowEmptyCollection()][string[]]$Status = @(),
        [ValidateRange(0, 50)][int]$StatusHeight = -1,
        [ValidateRange(20, 1000)][int]$Width = 80,
        [ValidateRange(6, 500)][int]$Height = 25
    )

    $usableWidth = [Math]::Max(20, $Width - 1)
    # Feste Bandhoehe: der Bereich bleibt auch leer reserviert, damit Fortschritt das Menue nie verschiebt.
    $bandHeight = if ($StatusHeight -ge 0) { $StatusHeight } else { @($Status).Count }
    $header = [System.Collections.Generic.List[string]]::new()
    $header.Add($Title)
    if ($Subtitle) { $header.Add($Subtitle) }
    $header.Add('')
    $attentionItems = if ($State.Snapshot -and $State.Snapshot.PSObject.Properties['AttentionItems']) { @($State.Snapshot.AttentionItems) } else { @() }
    $footerLines = [System.Collections.Generic.List[string]]::new()
    $baseFooterLineCount = 1 + $(if ($State.Message) { 1 } else { 0 })
    $availableAttentionLines = [Math]::Max(0, $Height - $header.Count - 1 - $bandHeight - $baseFooterLineCount)
    $attentionShown = 0
    for ($index = 0; $index -lt [Math]::Min(2, $attentionItems.Count); $index++) {
        $attention = $attentionItems[$index]
        $requiredLines = 1 + $(if ([string]$attention.ActionHint) { 1 } else { 0 })
        if ($footerLines.Count + $requiredLines -gt $availableAttentionLines) { break }
        $marker = switch ([string]$attention.Severity) { 'Critical' { '[!]' } 'Warning' { '[!]' } default { '[i]' } }
        $footerLines.Add("Offen $marker $($attention.Message)")
        if ([string]$attention.ActionHint) { $footerLines.Add("Loesung: $($attention.ActionHint)") }
        $attentionShown++
    }
    if ($attentionItems.Count -gt $attentionShown -and $footerLines.Count -lt $availableAttentionLines) { $footerLines.Add("Weitere offene Punkte: $($attentionItems.Count - $attentionShown)") }
    if ($State.Message) { $footerLines.Add("Hinweis: $($State.Message)") }
    $footerLines.Add($Footer)
    $viewportHeight = [Math]::Max(1, $Height - $header.Count - $footerLines.Count - $bandHeight)
    $null = Set-LabConsoleViewport -State $State -ViewportHeight $viewportHeight

    $lines = [System.Collections.Generic.List[string]]::new()
    $lineColors = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $header) { $lines.Add((Format-LabConsoleText -Text $line -Width $usableWidth)); $lineColors.Add('') }
    for ($row = 0; $row -lt $viewportHeight; $row++) {
        $itemIndex = $State.TopIndex + $row
        if ($itemIndex -ge $State.Items.Count) { $lines.Add(''); $lineColors.Add(''); continue }
        $item = $State.Items[$itemIndex]
        $focus = if ($itemIndex -eq $State.SelectedIndex) { '>' } else { ' ' }
        $shortcut = if ([string]$item.Shortcut) { "[$($item.Shortcut)] " } else { '' }
        $lines.Add((Format-LabConsoleText -Text (Get-LabConsoleItemText -Item $item -Focus $focus -Shortcut $shortcut -Width $usableWidth) -Width $usableWidth))
        $lineColors.Add($(if ([bool]$item.Disabled) { 'DarkGray' } else { '' }))
    }
    for ($row = 0; $row -lt $bandHeight; $row++) {
        $bandText = if ($row -lt @($Status).Count) { [string]$Status[$row] } else { '' }
        $lines.Add((Format-LabConsoleText -Text $bandText -Width $usableWidth))
        $lineColors.Add('')
    }
    foreach ($line in $footerLines) { $lines.Add((Format-LabConsoleText -Text $line -Width $usableWidth)); $lineColors.Add('') }

    [PSCustomObject]@{ Lines=@($lines); LineColors=@($lineColors); Width=$usableWidth; Height=$Height; ViewportHeight=$viewportHeight; StatusHeight=$bandHeight; StatusOffset=($header.Count + $viewportHeight) }
}

function Get-LabConsoleItemText {
    <#
    .SYNOPSIS Setzt die Zeile eines Menueeintrags zusammen.
    .DESCRIPTION Bei einem deaktivierten Eintrag weicht der Grund der Marke und
    nicht umgekehrt. Frueher hat der Value die Zeile ueberlaufen lassen, sodass
    ausgerechnet "(nicht verfuegbar)" und die Begruendung abgeschnitten wurden.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Item,
        [string]$Focus = ' ',
        [string]$Shortcut = '',
        [ValidateRange(20, 1000)][int]$Width = 80
    )

    $head = '{0} {1}{2}' -f @($Focus, $Shortcut, [string]$Item.Label)
    if (-not [bool]$Item.Disabled) {
        $value = if ($null -ne $Item.Value -and [string]$Item.Value) { ": $([string]$Item.Value)" } else { '' }
        return $head + $value
    }

    $marker = ' (nicht verfuegbar)'
    $reason = if ($Item.PSObject.Properties['DisabledReason']) { [string]$Item.DisabledReason } else { '' }
    $marked = $head + $marker
    if ($marked.Length -gt $Width) {
        # Auf schmalen Fenstern weicht das Label; die Marke entscheidet ueber die Bedienbarkeit.
        $allowance = $Width - $marker.Length
        if ($allowance -lt 8) { return $head }
        return $head.Substring(0, $allowance - 3) + '...' + $marker
    }
    if ([string]::IsNullOrWhiteSpace($reason)) { return $marked }
    $remaining = $Width - $marked.Length - 3
    if ($remaining -lt 12) { return $marked }
    $trimmed = if ($reason.Length -le $remaining) { $reason } else { $reason.Substring(0, [Math]::Max(1, $remaining - 3)) + '...' }
    return $marked + ' - ' + $trimmed
}

function New-LabConsoleSession {
    [CmdletBinding()]
    param()

    $cursorVisible = [Console]::CursorVisible
    $session = [PSCustomObject]@{
        OriginTop = [Console]::WindowTop
        PreviousLineCount = 0
        Width = [Console]::WindowWidth
        Height = [Console]::WindowHeight
        ForegroundColor = [Console]::ForegroundColor
        BackgroundColor = [Console]::BackgroundColor
        CursorVisible = $cursorVisible
    }
    [Console]::CursorVisible = $false
    $session
}

function Get-LabConsoleWritePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][object]$Frame,
        [ValidateRange(2, 1000)][int]$Width,
        [ValidateRange(1, 500)][int]$Height
    )

    $usableWidth = [Math]::Max(1, $Width - 1)
    $lineCount = [Math]::Min(@($Frame.Lines).Count, $Height)
    $clearThrough = [Math]::Min([Math]::Max($lineCount, [int]$Session.PreviousLineCount), $Height)
    $rows = [System.Collections.Generic.List[object]]::new()
    for ($row = 0; $row -lt $clearThrough; $row++) {
        $text = if ($row -lt $lineCount) { Format-LabConsoleText -Text ([string]$Frame.Lines[$row]) -Width $usableWidth } else { '' }
        $color = if ($row -lt $lineCount -and $Frame.PSObject.Properties['LineColors'] -and $row -lt @($Frame.LineColors).Count) { [string]$Frame.LineColors[$row] } else { '' }
        $rows.Add([PSCustomObject]@{ Row=$row; Text=$text.PadRight($usableWidth); Color=$color; ClearsPrevious=($row -ge $lineCount) })
    }
    [PSCustomObject]@{ Rows=@($rows); LineCount=$lineCount; Width=$usableWidth; Height=$Height }
}

function Test-LabConsoleVirtualTerminal {
    <#
    .SYNOPSIS Prueft einmalig, ob Steuersequenzen gefahrlos ausgegeben werden koennen.
    #>
    [CmdletBinding()]
    param()

    if ($null -ne $script:LabConsoleVirtualTerminal) { return $script:LabConsoleVirtualTerminal }
    $script:LabConsoleVirtualTerminal = $false
    try { $script:LabConsoleVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { }
    return $script:LabConsoleVirtualTerminal
}

function Write-LabConsoleFrame {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session, [Parameter(Mandatory)][object]$Frame)

    $width = [Console]::WindowWidth
    $height = [Console]::WindowHeight
    if ($Session.Width -ne $width -or $Session.Height -ne $height) {
        $Session.OriginTop = [Console]::WindowTop
        $Session.Width = $width
        $Session.Height = $height
    }
    # Die letzte Spalte wird bewusst nicht beschrieben, sonst scrollt die Konsole.
    # Ohne Loeschsequenz bliebe dort jedes Fremdzeichen dauerhaft stehen.
    $eraseToEnd = if (Test-LabConsoleVirtualTerminal) { "$([char]27)[K" } else { '' }
    $plan = Get-LabConsoleWritePlan -Session $Session -Frame $Frame -Width $width -Height $height
    foreach ($row in $plan.Rows) {
        [Console]::SetCursorPosition(0, $Session.OriginTop + [int]$row.Row)
        [Console]::ForegroundColor = if ([string]$row.Color) { [ConsoleColor]$row.Color } else { [ConsoleColor]$Session.ForegroundColor }
        [Console]::Write([string]$row.Text + $eraseToEnd)
    }
    [Console]::ForegroundColor = [ConsoleColor]$Session.ForegroundColor
    $Session.PreviousLineCount = [int]$plan.LineCount
    [Console]::SetCursorPosition(0, [Math]::Min($Session.OriginTop + [Math]::Max(0, [int]$plan.LineCount - 1), [Console]::BufferHeight - 1))
}

function Test-LabConsoleUnicodeSupport {
    <#
    .SYNOPSIS Prueft einmalig, ob Blockgrafik gefahrlos ausgegeben werden kann.
    #>
    [CmdletBinding()]
    param()

    if ($null -ne $script:LabConsoleUnicodeSupport) { return $script:LabConsoleUnicodeSupport }
    $script:LabConsoleUnicodeSupport = $false
    try { $script:LabConsoleUnicodeSupport = ([Console]::OutputEncoding.CodePage -eq 65001) } catch { }
    return $script:LabConsoleUnicodeSupport
}

function Get-LabProgressBar {
    <#
    .SYNOPSIS Rendert einen Fortschrittsbalken fester Breite.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(0, 100)][int]$Percent,
        [ValidateRange(4, 200)][int]$Width = 16
    )

    $unicode = Test-LabConsoleUnicodeSupport
    $filledChar = if ($unicode) { [char]0x2588 } else { '=' }
    $emptyChar = if ($unicode) { [char]0x2591 } else { '-' }
    $inner = $Width - 2
    $filled = [int][Math]::Round($inner * $Percent / 100.0)
    $filled = [Math]::Max(0, [Math]::Min($inner, $filled))
    return '[' + ([string]$filledChar * $filled) + ([string]$emptyChar * ($inner - $filled)) + ']'
}

function Get-LabHeartbeatMarker {
    <#
    .SYNOPSIS Liefert das rotierende Lebenszeichen fuer unbestimmte Vorgaenge.
    #>
    [CmdletBinding()]
    param([int]$Tick = 0)

    $frames = if (Test-LabConsoleUnicodeSupport) { @([char]0x25D0, [char]0x25D3, [char]0x25D1, [char]0x25D2) } else { @('|', '/', '-', '\') }
    return [string]$frames[[Math]::Abs($Tick) % $frames.Count]
}

function Format-LabElapsedTime {
    [CmdletBinding()]
    param([timespan]$Elapsed)

    if ($Elapsed.Ticks -lt 0) { $Elapsed = [timespan]::Zero }
    # [int] rundet in PowerShell; fuer Laufzeiten muss abgeschnitten werden.
    if ($Elapsed.TotalHours -ge 1) { return '{0}:{1:00}:{2:00}' -f @([int][Math]::Floor($Elapsed.TotalHours), $Elapsed.Minutes, $Elapsed.Seconds) }
    return '{0:00}:{1:00}' -f @([int][Math]::Floor($Elapsed.TotalMinutes), $Elapsed.Seconds)
}

function Format-LabProgressStatus {
    <#
    .SYNOPSIS Projiziert eine Operation auf zwei Statuszeilen.
    .DESCRIPTION Bestimmbarer Fortschritt kommt aus steps/progress. Fehlt er,
    beweist ein Heartbeat mit Laufzeit und Versuchszaehler die Lebendigkeit.
    Bleibt die Operation unveraendert, wird der Stillstand benannt statt gedreht.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Operation,
        [int]$Tick = 0,
        [ValidateRange(20, 1000)][int]$Width = 78,
        [AllowNull()][object]$Now,
        [ValidateRange(5, 86400)][int]$StalledAfterSeconds = 300
    )

    $reference = if ($Now -is [datetime]) { ([datetime]$Now).ToUniversalTime() } else { [datetime]::UtcNow }
    $properties = $Operation.PSObject.Properties
    $label = [string]$(if ($properties['itemId'] -and $Operation.itemId) { $Operation.itemId } elseif ($properties['title']) { $Operation.title } else { 'Vorgang' })

    $percent = $null
    if ($properties['progress'] -and $null -ne $Operation.progress) {
        try {
            $value = [double]$Operation.progress
            if (-not [double]::IsNaN($value)) { $percent = [int][Math]::Round([Math]::Max(0, [Math]::Min(100, $value))) }
        }
        catch { }
    }
    $steps = if ($properties['steps']) { @($Operation.steps) } else { @() }
    $stepIndex = if ($properties['currentStep']) { [int]$Operation.currentStep } else { 0 }
    $phase = ''
    if ($steps.Count -gt 0 -and $stepIndex -ge 0 -and $stepIndex -lt $steps.Count) { $phase = [string]$steps[$stepIndex].title }

    $elapsed = [timespan]::Zero
    if ($properties['startedAt'] -and $Operation.startedAt) {
        try { $elapsed = $reference - ([datetime]$Operation.startedAt).ToUniversalTime() } catch { }
    }
    $elapsedText = Format-LabElapsedTime -Elapsed $elapsed

    $idleFor = [timespan]::Zero
    if ($properties['updatedAt'] -and $Operation.updatedAt) {
        try { $idleFor = $reference - ([datetime]$Operation.updatedAt).ToUniversalTime() } catch { }
    }
    $stalled = $idleFor.TotalSeconds -ge $StalledAfterSeconds

    $determinate = ($null -ne $percent) -and $steps.Count -gt 0
    $first = if ($determinate) {
        '{0}  {1} {2,3}%  {3}' -f @($label, (Get-LabProgressBar -Percent $percent), $percent, $phase)
    }
    else {
        '{0}  {1} {2}  {3}' -f @($label, (Get-LabHeartbeatMarker -Tick $Tick), $elapsedText, $phase)
    }

    $details = [System.Collections.Generic.List[string]]::new()
    if ($steps.Count -gt 0) { $details.Add('Schritt {0}/{1}' -f @([Math]::Min($stepIndex + 1, $steps.Count), $steps.Count)) }
    $details.Add($elapsedText)
    if ($Operation.probe -and $Operation.probe.PSObject.Properties['failures'] -and [int]$Operation.probe.failures -gt 0) {
        $details.Add('Versuch {0}' -f ([int]$Operation.probe.failures + 1))
    }
    if ($stalled) { $details.Add('keine Aenderung seit {0}' -f (Format-LabElapsedTime -Elapsed $idleFor)) }

    [PSCustomObject]@{
        Lines       = @(
            (Format-LabConsoleText -Text $first -Width $Width)
            (Format-LabConsoleText -Text ('    ' + ($details -join ' - ')) -Width $Width)
        )
        Determinate = $determinate
        Stalled     = $stalled
        Percent     = $percent
        Label       = $label
    }
}

function Get-LabConsoleStatusBand {
    <#
    .SYNOPSIS Erzeugt den Inhalt des reservierten Statusbereichs mit exakter Hoehe.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Operation = @(),
        [int]$Tick = 0,
        [ValidateRange(20, 1000)][int]$Width = 78,
        [ValidateRange(1, 50)][int]$Height = 3,
        [AllowNull()][object]$Now,
        [string]$Headline = ''
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Headline)) { $lines.Add((Format-LabConsoleText -Text $Headline -Width $Width)) }
    if (@($Operation).Count -eq 0) {
        if ($lines.Count -lt $Height) { $lines.Add('Bereit - keine laufenden Vorgaenge') }
    }
    else {
        foreach ($item in $Operation) {
            $status = Format-LabProgressStatus -Operation $item -Tick $Tick -Width $Width -Now $Now
            foreach ($line in $status.Lines) {
                if ($lines.Count -ge $Height) { break }
                $lines.Add($line)
            }
            if ($lines.Count -ge $Height) { break }
        }
    }
    while ($lines.Count -lt $Height) { $lines.Add('') }
    return @($lines[0..($Height - 1)])
}

function Get-LabConsoleStatusWritePlan {
    <#
    .SYNOPSIS Plant das Neuzeichnen ausschliesslich der reservierten Statuszeilen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Frame,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Status
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt [int]$Frame.StatusHeight; $index++) {
        $text = if ($index -lt @($Status).Count) { [string]$Status[$index] } else { '' }
        $rows.Add([PSCustomObject]@{
            Row  = [int]$Frame.StatusOffset + $index
            Text = (Format-LabConsoleText -Text $text -Width $Frame.Width).PadRight($Frame.Width)
        })
    }
    return @($rows)
}

function Update-LabConsoleStatusBand {
    <#
    .SYNOPSIS Schreibt den Statusbereich neu, ohne Menue oder Fusszeile zu beruehren.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][object]$Frame,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Status
    )

    $eraseToEnd = if (Test-LabConsoleVirtualTerminal) { "$([char]27)[K" } else { '' }
    foreach ($row in (Get-LabConsoleStatusWritePlan -Frame $Frame -Status $Status)) {
        [Console]::SetCursorPosition(0, $Session.OriginTop + [int]$row.Row)
        [Console]::Write([string]$row.Text + $eraseToEnd)
    }
}

function Get-LabConsoleStatusSafely {
    <#
    .SYNOPSIS Holt den Statusinhalt, ohne dass ein Ausfall die Cursoransicht kostet.
    .DESCRIPTION Ein Fehler im Statuslieferanten hat den gesamten Bildschirm in den
    nummerierten Fallback gezwungen. Der Ausfall bleibt sichtbar und wird
    journalisiert, die Navigation bleibt erhalten.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][scriptblock]$StatusProvider,
        [int]$Tick = 0,
        [ValidateRange(0, 50)][int]$Height = 3
    )

    if (-not $StatusProvider) { return @() }
    try { return @(& $StatusProvider $Tick) }
    catch {
        $reason = [string]$_.Exception.Message
        if ($script:LabConsoleStatusFailureReason -ne $reason) {
            $script:LabConsoleStatusFailureReason = $reason
            try { $null = Add-LabMessage -Severity Warning -Message "CONSOLE_STATUS_PROVIDER_FAILED: Statusband ausgefallen: $reason" } catch { }
        }
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("Statusband nicht verfuegbar: $reason")
        while ($lines.Count -lt $Height) { $lines.Add('') }
        if ($Height -le 0) { return @($lines[0]) }
        return @($lines[0..($Height - 1)])
    }
}

function Wait-LabConsoleKey {
    <#
    .SYNOPSIS Wartet auf eine Taste und haelt dabei den Statusbereich lebendig.
    .DESCRIPTION Ohne StatusProvider bleibt das Verhalten exakt blockierend wie
    bisher. Mit StatusProvider wird ausschliesslich das Statusband neu gezeichnet.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Session,
        [AllowNull()][object]$Frame,
        [AllowNull()][scriptblock]$StatusProvider,
        [ValidateRange(50, 5000)][int]$IntervalMilliseconds = 400,
        [AllowNull()][scriptblock]$ReadKey,
        [AllowNull()][scriptblock]$KeyAvailable,
        [AllowNull()][scriptblock]$StatusWriter
    )

    if (-not $StatusProvider -or -not $Frame -or [int]$Frame.StatusHeight -le 0) {
        return Read-LabConsoleKey -ReadKey $ReadKey
    }
    if ($ReadKey -and -not $KeyAvailable) {
        return Read-LabConsoleKey -ReadKey $ReadKey
    }
    $probe = if ($KeyAvailable) { $KeyAvailable } else { { [Console]::KeyAvailable } }
    $writer = if ($StatusWriter) { $StatusWriter } else { { param($s, $f, $t) Update-LabConsoleStatusBand -Session $s -Frame $f -Status $t } }
    $tick = 0
    while ($true) {
        $ready = $true
        # Ein Host ohne Tastaturabfrage darf nicht in eine Endlosschleife laufen.
        try { $ready = [bool](& $probe) } catch { return Read-LabConsoleKey -ReadKey $ReadKey }
        if ($ready) { break }
        $tick++
        # Nur ein Schreibfehler rechtfertigt den Rueckfall; ein defektes Statusband nicht.
        $statusLines = Get-LabConsoleStatusSafely -StatusProvider $StatusProvider -Tick $tick -Height ([int]$Frame.StatusHeight)
        try { & $writer $Session $Frame @($statusLines) } catch { return Read-LabConsoleKey -ReadKey $ReadKey }
        Start-Sleep -Milliseconds $IntervalMilliseconds
    }
    return Read-LabConsoleKey -ReadKey $ReadKey
}

function Get-LabConsolePersistentBlockPlan {
    <#
    .SYNOPSIS Plant einen dauerhaften Ausgabeblock oberhalb des Menuerahmens.
    .DESCRIPTION Der Rahmen wird geloescht, der Block in den normalen Scrollback
    geschrieben und der Rahmen darunter neu verankert. Dadurch bleibt die Meldung
    terminaleigen markierbar und kopierbar, waehrend das Menue stabil bleibt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Line,
        [ValidateRange(2, 1000)][int]$Width,
        [ValidateRange(1, 500)][int]$Height
    )

    $usableWidth = [Math]::Max(1, $Width - 1)
    $clearRows = [Math]::Min([Math]::Max(0, [int]$Session.PreviousLineCount), $Height)
    $blockLines = [System.Collections.Generic.List[string]]::new()
    foreach ($text in $Line) { $blockLines.Add((Format-LabConsoleText -Text $text -Width $usableWidth)) }
    [PSCustomObject]@{
        ClearRows = $clearRows
        ClearText = ''.PadRight($usableWidth)
        Lines     = @($blockLines)
        Width     = $usableWidth
    }
}

function Write-LabConsolePersistentBlock {
    <#
    .SYNOPSIS Schreibt einen Block dauerhaft in den Scrollback und verankert den Rahmen neu.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Line,
        [string]$Color = ''
    )

    $plan = Get-LabConsolePersistentBlockPlan -Session $Session -Line $Line -Width ([Console]::WindowWidth) -Height ([Console]::WindowHeight)
    for ($row = 0; $row -lt $plan.ClearRows; $row++) {
        [Console]::SetCursorPosition(0, $Session.OriginTop + $row)
        [Console]::Write($plan.ClearText)
    }
    [Console]::SetCursorPosition(0, $Session.OriginTop)
    if ($Color) { [Console]::ForegroundColor = [ConsoleColor]$Color }
    foreach ($text in $plan.Lines) { [Console]::WriteLine($text) }
    [Console]::ForegroundColor = [ConsoleColor]$Session.ForegroundColor
    $Session.OriginTop = [Console]::CursorTop
    $Session.PreviousLineCount = 0
    $plan
}

function Write-LabConsoleMessageBlock {
    <#
    .SYNOPSIS Gibt journalisierte Meldungen dauerhaft und kopierbar aus.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Message
    )

    if (@($Message).Count -eq 0) { return }
    $severities = @($Message | ForEach-Object { [string]$_.severity })
    $color = if ($severities -contains 'Error') { 'Red' } elseif ($severities -contains 'Warning') { 'Yellow' } else { '' }
    $lines = @('') + @((Format-LabMessageReport -Message $Message) -split "`r?`n") + @('')
    Write-LabConsolePersistentBlock -Session $Session -Line $lines -Color $color
}

function Complete-LabConsoleSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session)

    try {
        [Console]::ForegroundColor = $Session.ForegroundColor
        [Console]::BackgroundColor = $Session.BackgroundColor
        [Console]::CursorVisible = [bool]$Session.CursorVisible
        $targetTop = [Math]::Min($Session.OriginTop + [int]$Session.PreviousLineCount, [Console]::BufferHeight - 1)
        [Console]::SetCursorPosition(0, [Math]::Max(0, $targetTop))
        [Console]::WriteLine()
    }
    catch {
        try { [Console]::CursorVisible = [bool]$Session.CursorVisible } catch {}
    }
}

function Invoke-LabConsoleMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScreenId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items,
        [string]$Subtitle = '',
        [string]$Footer = 'Pfeile: Navigation  Enter: Auswahl  F1/?: Hilfe  Esc: Zurueck  F5: Aktualisieren',
        [string]$SelectedId,
        [AllowNull()][object]$Snapshot,
        [string]$FallbackPrompt = '  Auswahl',
        [switch]$ForceFallback,
        [AllowNull()][object]$Capability,
        [ValidateRange(0, 50)][int]$StatusHeight = 0,
        [AllowNull()][scriptblock]$StatusProvider,
        [ValidateRange(50, 5000)][int]$StatusIntervalMilliseconds = 400,
        [scriptblock]$ReadInput,
        [scriptblock]$ReadKey,
        [scriptblock]$KeyAvailable,
        [scriptblock]$StatusWriter,
        [scriptblock]$FrameWriter,
        [scriptblock]$GetViewport,
        [scriptblock]$SessionFactory,
        [scriptblock]$SessionCompleter
    )

    # Eine interaktive Produktsitzung kann einen gemeinsamen Statuslieferanten
    # bereitstellen. Explizite Parameter bleiben autoritativ, damit einzelne
    # Bildschirme ein groesseres Band nutzen oder es bewusst abschalten koennen.
    if (-not $PSBoundParameters.ContainsKey('StatusProvider')) {
        $defaultStatusProvider = Get-Variable -Name LabConsoleDefaultStatusProvider -Scope Script -ErrorAction SilentlyContinue
        if ($defaultStatusProvider -and $defaultStatusProvider.Value) {
            $StatusProvider = [scriptblock]$defaultStatusProvider.Value
            if (-not $PSBoundParameters.ContainsKey('StatusHeight')) { $StatusHeight = 3 }
        }
    }

    if (-not $PSBoundParameters.ContainsKey('Snapshot') -and (Get-Command Get-LabConsoleAttentionSnapshot -ErrorAction SilentlyContinue)) {
        try { $Snapshot = Get-LabConsoleAttentionSnapshot } catch { $Snapshot = $null }
    }
    if (-not $Capability) { $Capability = Test-LabConsoleCapability }
    if ($ForceFallback -or -not [bool]$Capability.Supported) {
        if ($Snapshot -and @($Snapshot.AttentionItems).Count -gt 0) {
            Write-Host "  Offene Punkte: $(@($Snapshot.AttentionItems).Count)"
            foreach ($attention in @($Snapshot.AttentionItems | Select-Object -First 3)) {
                Write-Host "    [$($attention.Severity)] $($attention.Message)"
                if ([string]$attention.ActionHint) { Write-Host "      Loesung: $($attention.ActionHint)" }
            }
        }
        for ($index = 0; $index -lt $Items.Count; $index++) {
            $item = $Items[$index]
            $shortcut = if ([string]$item.Shortcut) { [string]$item.Shortcut } else { [string]($index + 1) }
            $value = if ($null -ne $item.Value -and [string]$item.Value) { " - $($item.Value)" } else { '' }
            $disabled = if ([bool]$item.Disabled) { ' (nicht verfuegbar)' } else { '' }
            Write-Host ("    [{0}] {1}{2}{3}" -f $shortcut, $item.Label, $value, $disabled) -ForegroundColor $(if ([bool]$item.Disabled) { 'DarkGray' } else { 'Gray' })
        }
        if (@($Items | Where-Object { [string]$_.Shortcut -eq '0' }).Count -eq 0) {
            Write-Host '    [0] Zurueck' -ForegroundColor Gray
        }
        $answer = if ($ReadInput) { & $ReadInput "$FallbackPrompt (0: Zurueck)" } else { Read-Host "$FallbackPrompt (0: Zurueck)" }
        if (-not $answer) { return [PSCustomObject]@{ Status='Cancelled'; SelectedItem=$null; State=$null } }
        if ([string]$answer -eq '0') { return [PSCustomObject]@{ Status='Cancelled'; SelectedItem=$null; State=$null } }
        for ($index = 0; $index -lt $Items.Count; $index++) {
            $item = $Items[$index]
            if ([bool]$item.Disabled) { continue }
            $displayShortcut = if ([string]$item.Shortcut) { [string]$item.Shortcut } else { [string]($index + 1) }
            if ([string]$answer -ieq $displayShortcut -or @($item.Aliases | Where-Object { [string]$_ -ieq [string]$answer }).Count -gt 0) {
                return [PSCustomObject]@{ Status='Selected'; SelectedItem=$item; State=$null }
            }
        }
        return [PSCustomObject]@{ Status='Invalid'; SelectedItem=$null; State=$null }
    }

    $state = New-LabConsoleState -ScreenId $ScreenId -Items $Items -SelectedId $SelectedId
    $state.Snapshot = $Snapshot
    $numericShortcutBuffer = ''
    $session = if ($SessionFactory) { & $SessionFactory } elseif ($FrameWriter) { [PSCustomObject]@{ PreviousLineCount=0 } } else { New-LabConsoleSession }
    $consoleFailure = $null
    try {
        while ($true) {
            $viewport = if ($GetViewport) { & $GetViewport } else { $null }
            $width = if ($viewport) { [Math]::Max(20, [int]$viewport.Width) } elseif ($FrameWriter) { 80 } else { [Console]::WindowWidth }
            $height = if ($viewport) { [Math]::Max(6, [int]$viewport.Height) } elseif ($FrameWriter) { 25 } else { [Console]::WindowHeight }
            $status = Get-LabConsoleStatusSafely -StatusProvider $StatusProvider -Tick 0 -Height $StatusHeight
            $frame = Get-LabConsoleFrame -State $state -Title $Title -Subtitle $Subtitle -Footer $Footer -Status $status -StatusHeight $StatusHeight -Width $width -Height $height
            if ($FrameWriter) { & $FrameWriter $session $frame } else { Write-LabConsoleFrame -Session $session -Frame $frame }
            $key = Wait-LabConsoleKey -Session $session -Frame $frame -StatusProvider $StatusProvider `
                -IntervalMilliseconds $StatusIntervalMilliseconds -ReadKey $ReadKey -KeyAvailable $KeyAvailable -StatusWriter $StatusWriter
            Assert-LabConsoleKeyNotInterrupted -Key $key
            $keyName = [string]$key.Key
            $keyCharacter = [string]$key.KeyChar
            switch ($keyName) {
                'UpArrow'   { $numericShortcutBuffer=''; $null = Move-LabConsoleSelection -State $state -Direction Up }
                'DownArrow' { $numericShortcutBuffer=''; $null = Move-LabConsoleSelection -State $state -Direction Down }
                'PageUp'    { $numericShortcutBuffer=''; $null = Move-LabConsoleSelection -State $state -Direction PageUp }
                'PageDown'  { $numericShortcutBuffer=''; $null = Move-LabConsoleSelection -State $state -Direction PageDown }
                'Home'      { $numericShortcutBuffer=''; $null = Move-LabConsoleSelection -State $state -Direction Home }
                'End'       { $numericShortcutBuffer=''; $null = Move-LabConsoleSelection -State $state -Direction End }
                'Backspace' {
                    if ($numericShortcutBuffer.Length -gt 0) {
                        $numericShortcutBuffer = $numericShortcutBuffer.Substring(0, $numericShortcutBuffer.Length - 1)
                        $state.Message = if ($numericShortcutBuffer) { "Nummer: $numericShortcutBuffer" } else { '' }
                    }
                }
                'Enter' {
                    if ($numericShortcutBuffer) {
                        $numericResolution = Resolve-LabConsoleNumericShortcut -Items $state.Items -Buffer $numericShortcutBuffer
                        if ($numericResolution.Item) {
                            return [PSCustomObject]@{ Status='Selected'; SelectedItem=$numericResolution.Item; State=$state }
                        }
                        $state.Message = "Nummer '$numericShortcutBuffer' ist nicht belegt."
                        $numericShortcutBuffer = ''
                        continue
                    }
                    $selected = if ($state.SelectedIndex -ge 0) { $state.Items[$state.SelectedIndex] } else { $null }
                    return [PSCustomObject]@{ Status='Selected'; SelectedItem=$selected; State=$state }
                }
                'Escape' { return [PSCustomObject]@{ Status='Cancelled'; SelectedItem=$null; State=$state } }
                'F5' {
                    if (Get-Command Update-LabConsoleAttentionSnapshot -ErrorAction SilentlyContinue) {
                        try { $state.Snapshot = Update-LabConsoleAttentionSnapshot } catch { $state.Message = "Attention-Status konnte nicht aktualisiert werden: $($_.Exception.Message)" }
                    }
                    return [PSCustomObject]@{ Status='Refresh'; SelectedItem=$null; State=$state }
                }
                'F10' { return [PSCustomObject]@{ Status='Review'; SelectedItem=$null; State=$state } }
                'F1' {
                    $numericShortcutBuffer = ''
                    $helpItem = if ($state.SelectedIndex -ge 0) { $state.Items[$state.SelectedIndex] } else { $null }
                    $null = Show-LabConsoleHelp -Session $session -Topic (Get-LabConsoleHelpTopic -ScreenId $ScreenId -Item $helpItem) `
                        -Width $width -Height $height -ReadKey $ReadKey -FrameWriter $FrameWriter
                    continue
                }
                default {
                    if ($keyCharacter -eq '?') {
                        $numericShortcutBuffer = ''
                        $helpItem = if ($state.SelectedIndex -ge 0) { $state.Items[$state.SelectedIndex] } else { $null }
                        $null = Show-LabConsoleHelp -Session $session -Topic (Get-LabConsoleHelpTopic -ScreenId $ScreenId -Item $helpItem) `
                            -Width $width -Height $height -ReadKey $ReadKey -FrameWriter $FrameWriter
                        continue
                    }
                    if ($keyCharacter -match '^\d$') {
                        $numericShortcutBuffer += $keyCharacter
                        $numericResolution = Resolve-LabConsoleNumericShortcut -Items $state.Items -Buffer $numericShortcutBuffer
                        if ($numericResolution.Status -eq 'Selected') {
                            return [PSCustomObject]@{ Status='Selected'; SelectedItem=$numericResolution.Item; State=$state }
                        }
                        if ($numericResolution.Status -eq 'Pending') {
                            $state.Message = "Nummer: $numericShortcutBuffer"
                            continue
                        }
                        $state.Message = "Nummer '$numericShortcutBuffer' ist nicht belegt."
                        $numericShortcutBuffer = ''
                        continue
                    }
                    $numericShortcutBuffer = ''
                    if ($keyCharacter) {
                        $match = @($state.Items | Where-Object {
                            -not [bool]$_.Disabled -and (
                                ([string]$_.Shortcut -and [string]$_.Shortcut -ieq $keyCharacter) -or
                                @($_.Aliases | Where-Object { [string]$_ -ieq $keyCharacter }).Count -gt 0
                            )
                        }) | Select-Object -First 1
                        if ($match) { return [PSCustomObject]@{ Status='Selected'; SelectedItem=$match; State=$state } }
                    }
                    $state.Message = 'Taste ist in dieser Ansicht nicht belegt.'
                }
            }
        }
    }
    catch [Management.Automation.PipelineStoppedException] {
        throw
    }
    catch {
        $consoleFailure = $_
    }
    finally {
        if ($SessionCompleter) { & $SessionCompleter $session }
        elseif (-not $FrameWriter) { Complete-LabConsoleSession -Session $session }
    }
    if ($consoleFailure) {
        Write-Host "  Cursoransicht nicht verfügbar; nummerierter Fallback wird verwendet: $($consoleFailure.Exception.Message)"
        return Invoke-LabConsoleMenu -ScreenId $ScreenId -Title $Title -Subtitle $Subtitle -Items $Items -SelectedId $SelectedId -Snapshot $Snapshot -Footer $Footer -FallbackPrompt $FallbackPrompt -ForceFallback -ReadInput $ReadInput
    }
}

function Invoke-LabConsoleMultiSelect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScreenId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items,
        [string[]]$SelectedIds = @(),
        [string]$Subtitle = '',
        [AllowNull()][object]$Snapshot,
        [string]$Footer = 'Pfeile: Navigation  Space: Umschalten  Enter: Uebernehmen  D: Details  Esc: Keine Auswahl',
        [switch]$ForceFallback,
        [AllowNull()][object]$Capability,
        [scriptblock]$ValidateToggle,
        [scriptblock]$ShowDetails,
        [scriptblock]$ReadInput,
        [scriptblock]$ReadKey,
        [scriptblock]$FrameWriter,
        [scriptblock]$GetViewport,
        [scriptblock]$SessionFactory,
        [scriptblock]$SessionCompleter
    )

    $selected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($SelectedIds)) { if ($id) { $null = $selected.Add([string]$id) } }
    $itemById = @{}
    foreach ($item in $Items) { $itemById[[string]$item.Id] = $item }
    $getSelectedItems = {
        @($Items | Where-Object { $selected.Contains([string]$_.Id) })
    }
    $getDisplayItems = {
        @($Items | ForEach-Object {
            $marker = if ($selected.Contains([string]$_.Id)) { '[x]' } else { '[ ]' }
            New-LabConsoleItem -Id ([string]$_.Id) -Label "$marker $($_.Label)" -Value $_.Value `
                -Shortcut ([string]$_.Shortcut) -Aliases @($_.Aliases) -Disabled:([bool]$_.Disabled) `
                -DisabledReason ([string]$_.DisabledReason) -Data $_
        })
    }
    $toggle = {
        param([Parameter(Mandatory)][object]$Item, [AllowNull()][object]$State)
        $id = [string]$Item.Id
        if ($selected.Contains($id)) {
            $null = $selected.Remove($id)
        }
        else {
            if ($ValidateToggle) {
                $message = [string](& $ValidateToggle $Item (& $getSelectedItems))
                if ($message) {
                    if ($State) { $State.Message = $message }
                    return $false
                }
            }
            $null = $selected.Add($id)
        }
        if ($State) {
            $State.Message = ''
            $null = Sync-LabConsoleState -State $State -Items (& $getDisplayItems)
        }
        return $true
    }

    if (-not $PSBoundParameters.ContainsKey('Snapshot') -and (Get-Command Get-LabConsoleAttentionSnapshot -ErrorAction SilentlyContinue)) {
        try { $Snapshot = Get-LabConsoleAttentionSnapshot } catch { $Snapshot = $null }
    }
    if (-not $Capability) { $Capability = Test-LabConsoleCapability }
    if ($ForceFallback -or -not [bool]$Capability.Supported) {
        if ($Snapshot -and @($Snapshot.AttentionItems).Count -gt 0) {
            Write-Host "  Offene Punkte: $(@($Snapshot.AttentionItems).Count)"
            foreach ($attention in @($Snapshot.AttentionItems | Select-Object -First 3)) {
                Write-Host "    [$($attention.Severity)] $($attention.Message)"
                if ([string]$attention.ActionHint) { Write-Host "      Loesung: $($attention.ActionHint)" }
            }
        }
        while ($true) {
            $displayItems = & $getDisplayItems
            for ($index = 0; $index -lt $displayItems.Count; $index++) {
                $item = $displayItems[$index]
                $shortcut = if ([string]$item.Shortcut) { [string]$item.Shortcut } else { [string]($index + 1) }
                $value = if ($null -ne $item.Value -and [string]$item.Value) { " - $($item.Value)" } else { '' }
                Write-Host ("    [{0}] {1}{2}" -f $shortcut, $item.Label, $value)
            }
            if (@($displayItems | Where-Object { [string]$_.Shortcut -eq '0' }).Count -eq 0) {
                Write-Host '    [0] Abbrechen' -ForegroundColor Gray
            }
            $answer = if ($ReadInput) { & $ReadInput '  Auswahl (Enter: Uebernehmen, 0: Abbrechen)' } else { Read-Host '  Auswahl (Enter: Uebernehmen, 0: Abbrechen)' }
            if ([string]::IsNullOrWhiteSpace([string]$answer)) {
                return [PSCustomObject]@{ Status='Confirmed'; SelectedItems=(& $getSelectedItems); State=$null }
            }
            if ([string]$answer -eq '0') {
                return [PSCustomObject]@{ Status='Cancelled'; SelectedItems=@(); State=$null }
            }
            $detailRequested = [string]$answer -match '^[dD]\s*(.+)$'
            $lookup = if ($detailRequested) { [string]$Matches[1] } else { [string]$answer }
            $matched = $null
            for ($index = 0; $index -lt $Items.Count; $index++) {
                $item = $Items[$index]
                $shortcut = if ([string]$item.Shortcut) { [string]$item.Shortcut } else { [string]($index + 1) }
                if ($lookup -ieq $shortcut -or @($item.Aliases | Where-Object { [string]$_ -ieq $lookup }).Count -gt 0) { $matched = $item; break }
            }
            if (-not $matched) { Write-Host '  Ungueltige Auswahl.'; continue }
            if ($detailRequested -and $ShowDetails) { & $ShowDetails $matched; continue }
            $null = & $toggle $matched $null
        }
    }

    $state = New-LabConsoleState -ScreenId $ScreenId -Items (& $getDisplayItems) -SelectedId $(if ($SelectedIds.Count -gt 0) { $SelectedIds[0] } else { '' })
    $state.Snapshot = $Snapshot
    $numericShortcutBuffer = ''
    $session = if ($SessionFactory) { & $SessionFactory } elseif ($FrameWriter) { [PSCustomObject]@{ PreviousLineCount=0 } } else { New-LabConsoleSession }
    $consoleFailure = $null
    try {
        while ($true) {
            $viewport = if ($GetViewport) { & $GetViewport } else { $null }
            $width = if ($viewport) { [Math]::Max(20, [int]$viewport.Width) } elseif ($FrameWriter) { 80 } else { [Console]::WindowWidth }
            $height = if ($viewport) { [Math]::Max(6, [int]$viewport.Height) } elseif ($FrameWriter) { 25 } else { [Console]::WindowHeight }
            $frame = Get-LabConsoleFrame -State $state -Title $Title -Subtitle $Subtitle -Footer $Footer -Width $width -Height $height
            if ($FrameWriter) { & $FrameWriter $session $frame } else { Write-LabConsoleFrame -Session $session -Frame $frame }
            $key = Read-LabConsoleKey -ReadKey $ReadKey
            Assert-LabConsoleKeyNotInterrupted -Key $key
            $selectedDisplayItem = if ($state.SelectedIndex -ge 0) { $state.Items[$state.SelectedIndex] } else { $null }
            switch ([string]$key.Key) {
                'UpArrow'   { $numericShortcutBuffer=''; $null = Move-LabConsoleSelection -State $state -Direction Up }
                'DownArrow' { $numericShortcutBuffer=''; $null = Move-LabConsoleSelection -State $state -Direction Down }
                'PageUp'    { $numericShortcutBuffer=''; $null = Move-LabConsoleSelection -State $state -Direction PageUp }
                'PageDown'  { $numericShortcutBuffer=''; $null = Move-LabConsoleSelection -State $state -Direction PageDown }
                'Home'      { $numericShortcutBuffer=''; $null = Move-LabConsoleSelection -State $state -Direction Home }
                'End'       { $numericShortcutBuffer=''; $null = Move-LabConsoleSelection -State $state -Direction End }
                'Backspace' {
                    if ($numericShortcutBuffer.Length -gt 0) {
                        $numericShortcutBuffer = $numericShortcutBuffer.Substring(0, $numericShortcutBuffer.Length - 1)
                        $state.Message = if ($numericShortcutBuffer) { "Nummer: $numericShortcutBuffer" } else { '' }
                    }
                }
                'Spacebar'  { $numericShortcutBuffer=''; if ($selectedDisplayItem) { $null = & $toggle $selectedDisplayItem.Data $state } }
                'Enter'     {
                    if ($numericShortcutBuffer) {
                        $numericResolution = Resolve-LabConsoleNumericShortcut -Items $state.Items -Buffer $numericShortcutBuffer
                        if ($numericResolution.Item) {
                            $null = & $toggle $numericResolution.Item.Data $state
                            $numericShortcutBuffer = ''
                            continue
                        }
                        $state.Message = "Nummer '$numericShortcutBuffer' ist nicht belegt."
                        $numericShortcutBuffer = ''
                        continue
                    }
                    return [PSCustomObject]@{ Status='Confirmed'; SelectedItems=(& $getSelectedItems); State=$state }
                }
                'Escape'    { return [PSCustomObject]@{ Status='Cancelled'; SelectedItems=@(); State=$state } }
                'F5'        {
                    if (Get-Command Update-LabConsoleAttentionSnapshot -ErrorAction SilentlyContinue) {
                        try { $state.Snapshot = Update-LabConsoleAttentionSnapshot } catch { $state.Message = "Attention-Status konnte nicht aktualisiert werden: $($_.Exception.Message)" }
                    }
                    $null = Sync-LabConsoleState -State $state -Items (& $getDisplayItems)
                }
                'D'         { if ($selectedDisplayItem -and $ShowDetails) { & $ShowDetails $selectedDisplayItem.Data } }
                default {
                    $character = [string]$key.KeyChar
                    if ($character -match '^\d$') {
                        $numericShortcutBuffer += $character
                        $numericResolution = Resolve-LabConsoleNumericShortcut -Items $state.Items -Buffer $numericShortcutBuffer
                        if ($numericResolution.Status -eq 'Selected') {
                            $null = & $toggle $numericResolution.Item.Data $state
                            $numericShortcutBuffer = ''
                            continue
                        }
                        if ($numericResolution.Status -eq 'Pending') {
                            $state.Message = "Nummer: $numericShortcutBuffer"
                            continue
                        }
                        $state.Message = "Nummer '$numericShortcutBuffer' ist nicht belegt."
                        $numericShortcutBuffer = ''
                        continue
                    }
                    $numericShortcutBuffer = ''
                    $matched = @($Items | Where-Object {
                        -not [bool]$_.Disabled -and (([string]$_.Shortcut -and [string]$_.Shortcut -ieq $character) -or @($_.Aliases | Where-Object { [string]$_ -ieq $character }).Count -gt 0)
                    }) | Select-Object -First 1
                    if ($matched) { $null = & $toggle $matched $state } else { $state.Message = 'Taste ist in dieser Ansicht nicht belegt.' }
                }
            }
        }
    }
    catch [Management.Automation.PipelineStoppedException] {
        throw
    }
    catch {
        $consoleFailure = $_
    }
    finally {
        if ($SessionCompleter) { & $SessionCompleter $session }
        elseif (-not $FrameWriter) { Complete-LabConsoleSession -Session $session }
    }
    if ($consoleFailure) {
        Write-Host "  Cursoransicht nicht verfügbar; Mehrfachauswahl-Fallback wird verwendet: $($consoleFailure.Exception.Message)"
        return Invoke-LabConsoleMultiSelect -ScreenId $ScreenId -Title $Title -Subtitle $Subtitle -Items $Items -SelectedIds @($selected) -Snapshot $Snapshot -Footer $Footer -ForceFallback -ValidateToggle $ValidateToggle -ShowDetails $ShowDetails -ReadInput $ReadInput
    }
}

function Test-LabConsoleFormValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Fields,
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][hashtable]$SecureValues
    )

    $validation = @{}
    foreach ($field in $Fields) {
        $id = [string]$field.Id
        $hasValue = if ([bool]$field.Sensitive) { $SecureValues.ContainsKey($id) } else { $Values.ContainsKey($id) -and $null -ne $Values[$id] -and [string]$Values[$id] }
        if ([bool]$field.Required -and -not $hasValue) {
            $validation[$id] = 'Pflichtfeld ist nicht ausgefuellt.'
            continue
        }
        if ($field.Validator) {
            $message = [string](& $field.Validator $(if ([bool]$field.Sensitive) { $SecureValues[$id] } else { $Values[$id] }) $Values)
            if ($message) { $validation[$id] = $message }
        }
    }
    $validation
}

function Invoke-LabConsoleForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScreenId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Fields,
        [string]$Subtitle = '',
        [string]$SelectedId,
        [switch]$ForceFallback,
        [AllowNull()][object]$Capability,
        [scriptblock]$ReadInput,
        [scriptblock]$ReadKey,
        [scriptblock]$FrameWriter,
        [scriptblock]$GetViewport,
        [scriptblock]$SessionFactory,
        [scriptblock]$SessionCompleter
    )

    $values = @{}
    $secureValues = @{}
    foreach ($field in $Fields) {
        if (-not [bool]$field.Sensitive) { $values[[string]$field.Id] = $field.Value }
    }
    if (-not $SelectedId -and $Fields.Count -gt 0) { $SelectedId = [string]$Fields[0].Id }
    $message = ''

    while ($true) {
        $items = foreach ($field in $Fields) {
            $id = [string]$field.Id
            $displayValue = if ([bool]$field.Sensitive) {
                if ($secureValues.ContainsKey($id)) { '<gesetzt>' } else { '<nicht gesetzt>' }
            }
            elseif ($field.Formatter) { [string](& $field.Formatter $values[$id]) }
            else { [string]$values[$id] }
            New-LabConsoleItem -Id $id -Label ([string]$field.Label) -Value $displayValue -Shortcut ([string]$field.Shortcut) -Data $field
        }
        $items = @($items) + @(New-LabConsoleItem -Id '__review' -Label 'Eingaben pruefen und anwenden' -Shortcut 'f')
        $formResult = Invoke-LabConsoleMenu -ScreenId $ScreenId -Title $Title -Subtitle $(if ($message) { "$Subtitle - $message" } else { $Subtitle }) -Items $items -SelectedId $SelectedId -Footer 'Pfeile: Navigation  Enter: Bearbeiten  F10/f: Pruefen  Esc: Abbruch' -ForceFallback:$ForceFallback -Capability $Capability -ReadInput $ReadInput -ReadKey $ReadKey -FrameWriter $FrameWriter -GetViewport $GetViewport -SessionFactory $SessionFactory -SessionCompleter $SessionCompleter
        if ($formResult.Status -eq 'Cancelled') {
            return [PSCustomObject]@{ Status='Cancelled'; Values=$values; SecureValues=$secureValues; Validation=@{} }
        }
        $reviewRequested = $formResult.Status -eq 'Review' -or ($formResult.Status -eq 'Selected' -and [string]$formResult.SelectedItem.Id -eq '__review')
        if (-not $reviewRequested) {
            if ($formResult.Status -ne 'Selected') { $message = 'Ungueltige Auswahl.'; continue }
            $field = $formResult.SelectedItem.Data
            $SelectedId = [string]$field.Id
            $currentValue = if ([bool]$field.Sensitive) { $null } else { $values[$SelectedId] }
            $newValue = if ($field.Editor) {
                & $field.Editor $currentValue $values
            }
            elseif ($ReadInput) {
                & $ReadInput $field $currentValue
            }
            else {
                Read-Host ("  {0} [{1}]" -f $field.Label, $currentValue)
            }
            if ([bool]$field.Sensitive) {
                if ($null -ne $newValue) { $secureValues[$SelectedId] = $newValue }
            }
            else { $values[$SelectedId] = $newValue }
            $validation = Test-LabConsoleFormValues -Fields @($field) -Values $values -SecureValues $secureValues
            $message = if ($validation.ContainsKey($SelectedId)) { [string]$validation[$SelectedId] } else { '' }
            continue
        }

        $validation = Test-LabConsoleFormValues -Fields $Fields -Values $values -SecureValues $secureValues
        if ($validation.Count -gt 0) {
            $SelectedId = [string]@($Fields | Where-Object { $validation.ContainsKey([string]$_.Id) } | Select-Object -First 1).Id
            $message = [string]$validation[$SelectedId]
            continue
        }

        $reviewItems = foreach ($field in $Fields) {
            $id = [string]$field.Id
            $displayValue = if ([bool]$field.Sensitive) { if ($secureValues.ContainsKey($id)) { '<gesetzt>' } else { '<nicht gesetzt>' } }
                elseif ($field.Formatter) { [string](& $field.Formatter $values[$id]) }
                else { [string]$values[$id] }
            New-LabConsoleItem -Id "review-$id" -Label ([string]$field.Label) -Value $displayValue -Data $field
        }
        $reviewItems = @($reviewItems) + @(
            New-LabConsoleItem -Id '__apply' -Label 'Aenderungen jetzt anwenden' -Shortcut 'a'
            New-LabConsoleItem -Id '__back' -Label 'Zurueck zur Bearbeitung' -Shortcut 'b'
            New-LabConsoleItem -Id '__cancel' -Label 'Abbrechen' -Shortcut 'q'
        )
        $reviewResult = Invoke-LabConsoleMenu -ScreenId "$ScreenId-review" -Title "$Title - Pruefen" -Subtitle 'Noch wurde keine Runtime-Mutation ausgefuehrt.' -Items $reviewItems -SelectedId '__apply' -Footer 'Pfeile: Pruefen  a: Anwenden  b: Bearbeiten  q/Esc: Abbruch' -ForceFallback:$ForceFallback -Capability $Capability -ReadInput $ReadInput -ReadKey $ReadKey -FrameWriter $FrameWriter -GetViewport $GetViewport -SessionFactory $SessionFactory -SessionCompleter $SessionCompleter
        if ($reviewResult.Status -eq 'Cancelled' -or [string]$reviewResult.SelectedItem.Id -eq '__cancel') {
            return [PSCustomObject]@{ Status='Cancelled'; Values=$values; SecureValues=$secureValues; Validation=$validation }
        }
        if ([string]$reviewResult.SelectedItem.Id -eq '__apply') {
            return [PSCustomObject]@{ Status='Confirmed'; Values=$values; SecureValues=$secureValues; Validation=$validation }
        }
        if ([string]$reviewResult.SelectedItem.Id -like 'review-*') { $SelectedId = [string]$reviewResult.SelectedItem.Data.Id }
        $message = ''
    }
}
