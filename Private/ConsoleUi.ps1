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
        [switch]$Disabled,
        [AllowNull()][object]$Data
    )

    [PSCustomObject]@{
        Id = $Id
        Label = $Label
        Value = $Value
        Shortcut = $Shortcut
        Disabled = $Disabled.IsPresent
        Data = $Data
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
    $footerLines = @('', $(if ($State.Message) { "Hinweis: $($State.Message)" } else { '' }), $Footer)
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
        [string]$FallbackPrompt = '  Auswahl',
        [switch]$ForceFallback,
        [AllowNull()][object]$Capability,
        [scriptblock]$ReadInput,
        [scriptblock]$ReadKey,
        [scriptblock]$FrameWriter
    )

    if (-not $Capability) { $Capability = Test-LabConsoleCapability }
    if ($ForceFallback -or -not [bool]$Capability.Supported) {
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
            if ([string]$answer -eq [string]($index + 1) -or ([string]$item.Shortcut -and [string]$answer -ieq [string]$item.Shortcut)) {
                return [PSCustomObject]@{ Status='Selected'; SelectedItem=$item; State=$null }
            }
        }
        return [PSCustomObject]@{ Status='Invalid'; SelectedItem=$null; State=$null }
    }

    $state = New-LabConsoleState -ScreenId $ScreenId -Items $Items -SelectedId $SelectedId
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
                'F5' { return [PSCustomObject]@{ Status='Refresh'; SelectedItem=$null; State=$state } }
                default {
                    if ($keyCharacter) {
                        $match = @($state.Items | Where-Object { -not [bool]$_.Disabled -and [string]$_.Shortcut -and [string]$_.Shortcut -ieq $keyCharacter }) | Select-Object -First 1
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
