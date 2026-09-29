# Real menu/dispatcher functions, with only terminal and action boundaries replaced.
& {
    . (Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1')
    function New-LabQueueStatusProvider { param($Height) return { } }
    function Update-LabConsoleAttentionSnapshot { return $null }
    function Get-LabConsoleAttentionSnapshot { $script:navigationRefresh++; return $null }
    function Write-LabInfo { param($Message) }
    $script:navigationChoices = [Collections.Generic.Queue[string]]::new()
    $script:navigationDestinations = [Collections.Generic.List[string]]::new()
    $script:navigationRefresh = 0
    function Invoke-LabConsoleMenu {
        param($ScreenId,$Title,$Subtitle,$Items,$Snapshot,$StatusHeight,$StatusProvider,$Footer,$FallbackPrompt)
        $choice = $script:navigationChoices.Dequeue()
        if ($choice -eq 'Refresh' -or $choice -eq 'Cancelled') { return @{Status=$choice} }
        $item = @($Items | Where-Object { $_.Id -eq $choice -or $_.Shortcut -eq $choice -or $_.Aliases -contains $choice })[0]
        if (-not $item) { throw "Missing real menu destination: $choice" }
        return @{Status='Selected'; SelectedItem=$item}
    }
    function Invoke-LabAreaMenuInteractive { param($Area) $script:navigationDestinations.Add($Area) }
    function Invoke-LabQueueInteractive { $script:navigationDestinations.Add('Queue') }
    function Manage-LabPublicCommandsInteractive { $script:navigationDestinations.Add('Commands') }
    function Show-LabMessagesInteractive { $script:navigationDestinations.Add('Messages') }
    function Invoke-LabActionWithResult { throw 'Navigation must not dispatch a mutation' }
    foreach ($choice in @('labs','testmatrix','templates','resources','hostmodels','connections','configuration','maintenance','queue','commands','messages','exit')) { $script:navigationChoices.Enqueue($choice) }
    $null = Invoke-SqlServerLab 6>$null
    Add-ConsoleUiCheck 'Neun echte Hauptmenueauswahlen dispatchen in richtige Bereiche; Experten/Meldungen separat' (($script:navigationDestinations -join ',') -eq 'Labs,TestMatrix,HyperV,Resources,HostModels,Cms,Configuration,Maintenance,Queue,Commands,Messages')
    foreach ($exitChoice in @('exit','0','q','Cancelled')) {
        $script:navigationChoices.Enqueue($exitChoice)
        $null = Invoke-SqlServerLab 6>$null
        Add-ConsoleUiCheck "Hauptmenue beendet echte Auswahl $exitChoice ohne weiteren Dispatch" ($script:navigationChoices.Count -eq 0 -and $script:navigationDestinations.Count -eq 11)
    }
    $script:navigationChoices.Enqueue('Refresh'); $script:navigationChoices.Enqueue('labs')
    Add-ConsoleUiCheck 'F5 aktualisiert Status und behaelt danach Menueauswahl' ((Show-LabMenu) -eq 'labs' -and $script:navigationRefresh -eq 1)
    $script:navigationChoices.Enqueue('7'); $script:navigationChoices.Enqueue('exit')
    $null = Invoke-SqlServerLab 6>$null
    Add-ConsoleUiCheck 'Echter Hauptmenü-Shortcut 7 dispatcht Grundkonfiguration' ($script:navigationDestinations.Count -eq 12 -and $script:navigationDestinations[-1] -eq 'Configuration')
}
& {
    . (Join-Path $repoRoot 'Public/BatchConsole.ps1')
    $script:navigationScreens = [Collections.Generic.List[string]]::new()
    $script:navigationSteps = [Collections.Generic.Queue[string]]::new()
    foreach ($step in @('CreateArea','back','EnvironmentArea','back','DatabaseArea','back','AiArea','back','back')) { $script:navigationSteps.Enqueue($step) }
    function Show-LabSubMenu {
        param($ScreenId,$Title,$Subtitle,$Items)
        $script:navigationScreens.Add($ScreenId)
        return $script:navigationSteps.Dequeue()
    }
    function Show-LabEnvironmentMenu { Show-LabSubMenu -ScreenId 'environment-menu' }
    function Show-LabDatabaseMenu { Show-LabSubMenu -ScreenId 'database-menu' }
    function Show-LabAiMenu { Show-LabSubMenu -ScreenId 'ai-menu' }
    function Invoke-LabMenuAction { throw 'Back or area navigation must not dispatch an action' }
    Invoke-LabAreaMenuInteractive -Area Labs
    Add-ConsoleUiCheck 'Lab-Unterbereiche kehren in Labs zurueck ohne generischen ActionDispatch' (($script:navigationScreens -join ',') -eq 'labs-menu,create-menu,labs-menu,environment-menu,labs-menu,database-menu,labs-menu,ai-menu,labs-menu')
    $script:navigationSteps.Enqueue('')
    Invoke-LabAreaMenuInteractive -Area Resources
    Add-ConsoleUiCheck 'Bereichsabbruch verlaesst den Bereich ohne Aktion' ($script:navigationSteps.Count -eq 0)
    $script:setupDispatch = [Collections.Generic.List[string]]::new()
    $script:setupMenuCount = 0
    function Show-LabSubMenu {
        param($ScreenId, $Title, $Subtitle, $Items)
        if ($ScreenId -ne 'configuration-menu') { throw 'UNEXPECTED_CONFIGURATION_SCREEN' }
        $script:setupMenuCount++
        if ($script:setupMenuCount -gt 1) { return 'back' }
        $item = @($Items | Where-Object Shortcut -eq '1')[0]
        if (-not $item -or $item.Disabled) { throw 'SETUP_MENU_NOT_AVAILABLE' }
        return [string]$item.Id
    }
    function Get-LabMessageJournalMarker { return $null }
    function Show-LabActionMessagesInteractive { param($Marker) }
    function Invoke-LabMenuAction { param($ActionName) $script:setupDispatch.Add($ActionName) }
    Invoke-LabAreaMenuInteractive -Area Configuration
    Add-ConsoleUiCheck 'Grundkonfigurations-Shortcut 1 dispatcht Setup und kehrt in denselben Bereich zurück' (($script:setupDispatch -join ',') -eq 'Setup' -and $script:setupMenuCount -eq 2)
    function Get-LabAutomatedTestEnvironmentMenuState { return @{Available=$false; Value=''; Label=''} }
    function Show-LabSubMenu { param($ScreenId,$Title,$Subtitle,$Items) return ,$Items }
    $items = Show-LabTestMatrixMenu
    Add-ConsoleUiCheck 'Leere Testmatrix lässt lesbaren Fachdialog offen und sperrt Entfernen mit Abhilfe' (@($items | Where-Object { $_.Id -eq 'ClearAutomatedTestEnvironment' -and $_.Disabled -and $_.DisabledReason }).Count -eq 1 -and @($items | Where-Object { $_.Id -eq 'AutomatedTestEnvironmentLifecycle' -and -not $_.Disabled }).Count -eq 1)
    $items = Show-LabHostModelsMenu
    Add-ConsoleUiCheck 'Fehlende Hostdienst- und Modell-Lifecycle bleiben explizit deaktiviert' (@($items | Where-Object { $_.Id -in @('HostServiceLifecycle','ModelLifecycle') -and $_.Disabled -and $_.DisabledReason }).Count -eq 2)
}
