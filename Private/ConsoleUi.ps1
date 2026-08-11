function Test-LabConsoleCapability {
    [CmdletBinding()]
    param()

    $reasons = [System.Collections.Generic.List[string]]::new()
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

function New-LabConsoleItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()][object]$Value,
        [AllowEmptyString()][string]$Shortcut = '',
        [string[]]$Aliases = @(),
        [switch]$Disabled,
        [AllowNull()][object]$Data
    )

    [PSCustomObject]@{
        Id = $Id
        Label = $Label
        Value = $Value
        Shortcut = $Shortcut
        Aliases = @($Aliases)
        Disabled = $Disabled.IsPresent
        Data = $Data
    }
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
        [string]$Footer = 'Pfeile: Navigation  Enter: Auswahl  Esc: Zurueck  F5: Aktualisieren',
        [ValidateRange(20, 1000)][int]$Width = 80,
        [ValidateRange(6, 500)][int]$Height = 25
    )

    $usableWidth = [Math]::Max(20, $Width - 1)
    $header = [System.Collections.Generic.List[string]]::new()
    $header.Add($Title)
    if ($Subtitle) { $header.Add($Subtitle) }
    $header.Add('')
    $attentionItems = if ($State.Snapshot -and $State.Snapshot.PSObject.Properties['AttentionItems']) { @($State.Snapshot.AttentionItems) } else { @() }
    $footerLines = [System.Collections.Generic.List[string]]::new()
    $footerLines.Add('')
    $attentionLimit = [Math]::Min(2, $attentionItems.Count)
    for ($index = 0; $index -lt $attentionLimit; $index++) {
        $attention = $attentionItems[$index]
        $marker = switch ([string]$attention.Severity) { 'Critical' { '[!]' } 'Warning' { '[!]' } default { '[i]' } }
        $footerLines.Add("Offen $marker $($attention.Message)")
    }
    if ($attentionItems.Count -gt $attentionLimit) { $footerLines.Add("Weitere offene Punkte: $($attentionItems.Count - $attentionLimit)") }
    if ($State.Message) { $footerLines.Add("Hinweis: $($State.Message)") }
    $footerLines.Add($Footer)
    $viewportHeight = [Math]::Max(1, $Height - $header.Count - $footerLines.Count)
    $null = Set-LabConsoleViewport -State $State -ViewportHeight $viewportHeight

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $header) { $lines.Add((Format-LabConsoleText -Text $line -Width $usableWidth)) }
    for ($row = 0; $row -lt $viewportHeight; $row++) {
        $itemIndex = $State.TopIndex + $row
        if ($itemIndex -ge $State.Items.Count) { $lines.Add(''); continue }
        $item = $State.Items[$itemIndex]
        $focus = if ($itemIndex -eq $State.SelectedIndex) { '>' } else { ' ' }
        $shortcut = if ([string]$item.Shortcut) { "[$($item.Shortcut)] " } else { '' }
        $value = if ($null -ne $item.Value -and [string]$item.Value) { ": $($item.Value)" } else { '' }
        $disabled = if ([bool]$item.Disabled) { ' (nicht verfuegbar)' } else { '' }
        $lines.Add((Format-LabConsoleText -Text ("{0} {1}{2}{3}{4}" -f $focus, $shortcut, $item.Label, $value, $disabled) -Width $usableWidth))
    }
    foreach ($line in $footerLines) { $lines.Add((Format-LabConsoleText -Text $line -Width $usableWidth)) }

    [PSCustomObject]@{ Lines=@($lines); Width=$usableWidth; Height=$Height; ViewportHeight=$viewportHeight }
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

function Write-LabConsoleFrame {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session, [Parameter(Mandatory)][object]$Frame)

    $width = [Math]::Max(1, [Console]::WindowWidth - 1)
    $height = [Console]::WindowHeight
    if ($Session.Width -ne [Console]::WindowWidth -or $Session.Height -ne $height) {
        $Session.OriginTop = [Console]::WindowTop
        $Session.Width = [Console]::WindowWidth
        $Session.Height = $height
    }
    $lineCount = [Math]::Min(@($Frame.Lines).Count, $height)
    $clearThrough = [Math]::Min([Math]::Max($lineCount, [int]$Session.PreviousLineCount), $height)
    for ($row = 0; $row -lt $clearThrough; $row++) {
        [Console]::SetCursorPosition(0, $Session.OriginTop + $row)
        $text = if ($row -lt $lineCount) { Format-LabConsoleText -Text ([string]$Frame.Lines[$row]) -Width $width } else { '' }
        [Console]::Write($text.PadRight($width))
    }
    $Session.PreviousLineCount = $lineCount
    [Console]::SetCursorPosition(0, [Math]::Min($Session.OriginTop + [Math]::Max(0, $lineCount - 1), [Console]::BufferHeight - 1))
}

function Complete-LabConsoleSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session)

    try {
        [Console]::ForegroundColor = $Session.ForegroundColor
        [Console]::BackgroundColor = $Session.BackgroundColor
        [Console]::CursorVisible = $true
        $targetTop = [Math]::Min($Session.OriginTop + [int]$Session.PreviousLineCount, [Console]::BufferHeight - 1)
        [Console]::SetCursorPosition(0, [Math]::Max(0, $targetTop))
        [Console]::WriteLine()
    }
    catch {
        try { [Console]::CursorVisible = $true } catch {}
    }
}

function Invoke-LabConsoleMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScreenId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items,
        [string]$Subtitle = '',
        [string]$Footer = 'Pfeile: Navigation  Enter: Auswahl  Esc: Zurueck  F5: Aktualisieren',
        [string]$SelectedId,
        [AllowNull()][object]$Snapshot,
        [string]$FallbackPrompt = '  Auswahl',
        [switch]$ForceFallback,
        [AllowNull()][object]$Capability,
        [scriptblock]$ReadInput,
        [scriptblock]$ReadKey,
        [scriptblock]$FrameWriter
    )

    if (-not $PSBoundParameters.ContainsKey('Snapshot') -and (Get-Command Get-LabConsoleAttentionSnapshot -ErrorAction SilentlyContinue)) {
        try { $Snapshot = Get-LabConsoleAttentionSnapshot } catch { $Snapshot = $null }
    }
    if (-not $Capability) { $Capability = Test-LabConsoleCapability }
    if ($ForceFallback -or -not [bool]$Capability.Supported) {
        if ($Snapshot -and @($Snapshot.AttentionItems).Count -gt 0) {
            Write-Host "  Offene Punkte: $(@($Snapshot.AttentionItems).Count)"
            foreach ($attention in @($Snapshot.AttentionItems | Select-Object -First 3)) { Write-Host "    [$($attention.Severity)] $($attention.Message)" }
        }
        for ($index = 0; $index -lt $Items.Count; $index++) {
            $item = $Items[$index]
            $shortcut = if ([string]$item.Shortcut) { [string]$item.Shortcut } else { [string]($index + 1) }
            $value = if ($null -ne $item.Value -and [string]$item.Value) { " - $($item.Value)" } else { '' }
            Write-Host ("    [{0}] {1}{2}" -f $shortcut, $item.Label, $value)
        }
        $answer = if ($ReadInput) { & $ReadInput $FallbackPrompt } else { Read-Host $FallbackPrompt }
        if (-not $answer) { return [PSCustomObject]@{ Status='Cancelled'; SelectedItem=$null; State=$null } }
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
    $session = if ($FrameWriter) { [PSCustomObject]@{ PreviousLineCount=0 } } else { New-LabConsoleSession }
    try {
        while ($true) {
            $width = if ($FrameWriter) { 80 } else { [Console]::WindowWidth }
            $height = if ($FrameWriter) { 25 } else { [Console]::WindowHeight }
            $frame = Get-LabConsoleFrame -State $state -Title $Title -Subtitle $Subtitle -Footer $Footer -Width $width -Height $height
            if ($FrameWriter) { & $FrameWriter $session $frame } else { Write-LabConsoleFrame -Session $session -Frame $frame }
            $key = if ($ReadKey) { & $ReadKey } else { [Console]::ReadKey($true) }
            $keyName = [string]$key.Key
            $keyCharacter = [string]$key.KeyChar
            switch ($keyName) {
                'UpArrow'   { $null = Move-LabConsoleSelection -State $state -Direction Up }
                'DownArrow' { $null = Move-LabConsoleSelection -State $state -Direction Down }
                'PageUp'    { $null = Move-LabConsoleSelection -State $state -Direction PageUp }
                'PageDown'  { $null = Move-LabConsoleSelection -State $state -Direction PageDown }
                'Home'      { $null = Move-LabConsoleSelection -State $state -Direction Home }
                'End'       { $null = Move-LabConsoleSelection -State $state -Direction End }
                'Enter' {
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
                default {
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
    finally {
        if (-not $FrameWriter) { Complete-LabConsoleSession -Session $session }
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
        [scriptblock]$FrameWriter
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
                -Shortcut ([string]$_.Shortcut) -Aliases @($_.Aliases) -Disabled:([bool]$_.Disabled) -Data $_
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
            foreach ($attention in @($Snapshot.AttentionItems | Select-Object -First 3)) { Write-Host "    [$($attention.Severity)] $($attention.Message)" }
        }
        while ($true) {
            $displayItems = & $getDisplayItems
            for ($index = 0; $index -lt $displayItems.Count; $index++) {
                $item = $displayItems[$index]
                $shortcut = if ([string]$item.Shortcut) { [string]$item.Shortcut } else { [string]($index + 1) }
                $value = if ($null -ne $item.Value -and [string]$item.Value) { " - $($item.Value)" } else { '' }
                Write-Host ("    [{0}] {1}{2}" -f $shortcut, $item.Label, $value)
            }
            $answer = if ($ReadInput) { & $ReadInput '  Auswahl' } else { Read-Host '  Auswahl' }
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
    $session = if ($FrameWriter) { [PSCustomObject]@{ PreviousLineCount=0 } } else { New-LabConsoleSession }
    try {
        while ($true) {
            $width = if ($FrameWriter) { 80 } else { [Console]::WindowWidth }
            $height = if ($FrameWriter) { 25 } else { [Console]::WindowHeight }
            $frame = Get-LabConsoleFrame -State $state -Title $Title -Subtitle $Subtitle -Footer $Footer -Width $width -Height $height
            if ($FrameWriter) { & $FrameWriter $session $frame } else { Write-LabConsoleFrame -Session $session -Frame $frame }
            $key = if ($ReadKey) { & $ReadKey } else { [Console]::ReadKey($true) }
            $selectedDisplayItem = if ($state.SelectedIndex -ge 0) { $state.Items[$state.SelectedIndex] } else { $null }
            switch ([string]$key.Key) {
                'UpArrow'   { $null = Move-LabConsoleSelection -State $state -Direction Up }
                'DownArrow' { $null = Move-LabConsoleSelection -State $state -Direction Down }
                'PageUp'    { $null = Move-LabConsoleSelection -State $state -Direction PageUp }
                'PageDown'  { $null = Move-LabConsoleSelection -State $state -Direction PageDown }
                'Home'      { $null = Move-LabConsoleSelection -State $state -Direction Home }
                'End'       { $null = Move-LabConsoleSelection -State $state -Direction End }
                'Spacebar'  { if ($selectedDisplayItem) { $null = & $toggle $selectedDisplayItem.Data $state } }
                'Enter'     { return [PSCustomObject]@{ Status='Confirmed'; SelectedItems=(& $getSelectedItems); State=$state } }
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
                    $matched = @($Items | Where-Object {
                        -not [bool]$_.Disabled -and (([string]$_.Shortcut -and [string]$_.Shortcut -ieq $character) -or @($_.Aliases | Where-Object { [string]$_ -ieq $character }).Count -gt 0)
                    }) | Select-Object -First 1
                    if ($matched) { $null = & $toggle $matched $state } else { $state.Message = 'Taste ist in dieser Ansicht nicht belegt.' }
                }
            }
        }
    }
    finally {
        if (-not $FrameWriter) { Complete-LabConsoleSession -Session $session }
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
        [scriptblock]$FrameWriter
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
        $formResult = Invoke-LabConsoleMenu -ScreenId $ScreenId -Title $Title -Subtitle $(if ($message) { "$Subtitle - $message" } else { $Subtitle }) -Items $items -SelectedId $SelectedId -Footer 'Pfeile: Navigation  Enter: Bearbeiten  F10/f: Pruefen  Esc: Abbruch' -ForceFallback:$ForceFallback -Capability $Capability -ReadInput $ReadInput -ReadKey $ReadKey -FrameWriter $FrameWriter
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
        $reviewResult = Invoke-LabConsoleMenu -ScreenId "$ScreenId-review" -Title "$Title - Pruefen" -Subtitle 'Noch wurde keine Runtime-Mutation ausgefuehrt.' -Items $reviewItems -SelectedId '__apply' -Footer 'Pfeile: Pruefen  a: Anwenden  b: Bearbeiten  q/Esc: Abbruch' -ForceFallback:$ForceFallback -Capability $Capability -ReadInput $ReadInput -ReadKey $ReadKey -FrameWriter $FrameWriter
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
