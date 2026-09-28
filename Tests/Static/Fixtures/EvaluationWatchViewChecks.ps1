param($Module, $Watch, [string]$Repository)

$ErrorActionPreference = 'Stop'
& $Module {
    param($Fixture, $Repo)
    $original = ${function:Get-SqlServerLabEvaluationWatch}
    $script:evaluationViewFixture = $Fixture
    $script:evaluationViewCalls = 0
    $script:evaluationViewMode = 'normal'
    function Assert-View { param([bool]$Condition, [string]$Name)
        if (-not $Condition) { throw "EVALUATION_VIEW_CHECK_FAILED: $Name" }
        Write-Host "PASS: $Name"
    }
    try {
        function script:Get-SqlServerLabEvaluationWatch {
            param($WarningDaysRemaining, $CriticalDaysRemaining, [switch]$RecordEvents)
            if ($RecordEvents -or $WarningDaysRemaining -ne 30 -or $CriticalDaysRemaining -ne 7) { throw 'UNSAFE_VIEW_ARGUMENTS' }
            $script:evaluationViewCalls++
            if ($script:evaluationViewMode -eq 'error') { throw 'CANARY_PRIVATE_SOURCE_ERROR' }
            if ($script:evaluationViewMode -eq 'empty') { return [pscustomobject]@{ GeneratedAt='2026-01-01T00:00:00Z'; Items=@(); InstanceItems=@() } }
            $script:evaluationViewFixture
        }
        function Start-SqlServerLab { throw 'UNEXPECTED_START' }
        function Invoke-SqlServerLabEvaluationWatchTrigger { throw 'UNEXPECTED_TRIGGER' }
        function Test-HyperVAvailable { throw 'UNEXPECTED_RUNTIME_PROBE' }
        function Sync-LabConnectionCenterAfterLifecycle { throw 'UNEXPECTED_SYNC' }
        $view = Get-LabEvaluationWatchView
        Assert-View ($view.Rows.Count -eq (@($Fixture.Items).Count + @($Fixture.InstanceItems).Count)) 'Alle Core-Einträge bleiben getrennt auswählbar'
        $unknown = @($view.Rows | Where-Object Summary -like 'Unbekannt*')
        Assert-View ($unknown.Count -gt 0 -and @($unknown.Fields | Where-Object Label -eq 'Nächster Schritt').Count -gt 0) 'Unbekannte Fristen besitzen Hinweis und nächsten Schritt'
        $historical = @($view.Rows | Where-Object { $_.Label -like 'Vorlage*' -or $_.Label -like 'Registrierte Instanz · Windows*' })
        Assert-View (@($historical | Where-Object { @($_.Fields | Where-Object { $_.Label -eq 'Aktualität' -and $_.Value -eq 'Historische Metadaten; Evidencezeit und Aktualität unbekannt, nicht live geprüft' }).Count -ne 1 }).Count -eq 0) 'Lesezeit ersetzt keine Evidenceaktualität'
        Assert-View ($view.Scope -match 'RUNNING oder STOPPED' -and $view.Notice -match 'keine Ereignisse') 'Begrenzter Scope und read-only Wirkung bleiben sichtbar'

        $script:evaluationMenuChoices = [Collections.Generic.Queue[string]]::new()
        $script:evaluationMenuSubtitles = [Collections.Generic.List[string]]::new()
        function Invoke-LabConsoleMenu {
            param($ScreenId,$Title,$Subtitle,$Items)
            if ($ScreenId -ne 'evaluation-watch-menu') { throw 'UNEXPECTED_SCREEN' }
            $script:evaluationMenuSubtitles.Add([string]$Subtitle)
            $choice = $script:evaluationMenuChoices.Dequeue()
            if ($choice -eq 'cancel') { return [pscustomobject]@{Status='Cancelled'} }
            $item = @($Items | Where-Object Id -eq $choice)
            if ($item.Count -ne 1) { throw "UNEXPECTED_CHOICE: $choice" }
            [pscustomobject]@{ Status='Selected'; SelectedItem=$item[0] }
        }
        function Wait-LabConsoleAcknowledgement { param($Prompt) $null }
        $before = $script:evaluationViewCalls
        $script:evaluationMenuChoices.Enqueue('cancel')
        Show-LabEvaluationWatchInteractive
        Assert-View ($script:evaluationViewCalls -eq $before) 'Abbruch vor Lesen ruft weder Core noch Runtime auf'
        $script:evaluationMenuChoices.Enqueue('read')
        $script:evaluationMenuChoices.Enqueue('entry-0')
        $script:evaluationMenuChoices.Enqueue('entry-1')
        $script:evaluationMenuChoices.Enqueue('back')
        $output = @(Show-LabEvaluationWatchInteractive 6>&1) -join "`n"
        Assert-View ($script:evaluationViewCalls -eq $before + 1 -and $output -match 'Quelle:' -and $output -match 'Aktualität:') 'Importierter Dialog: Lesen, Details, Zielwechsel und Zurück ohne erneuten Coreaufruf'
        $script:evaluationViewMode = 'empty'
        $script:evaluationMenuChoices.Enqueue('read'); $script:evaluationMenuChoices.Enqueue('back')
        Show-LabEvaluationWatchInteractive
        Assert-View ($script:evaluationMenuSubtitles[-1] -match 'kein Nachweis gültiger Lizenzen') 'Leere CLI-Sicht ist kein grüner Fristnachweis'
        $script:evaluationViewMode = 'error'
        $script:evaluationMenuChoices.Enqueue('read'); $script:evaluationMenuChoices.Enqueue('back')
        Show-LabEvaluationWatchInteractive
        Assert-View ($script:evaluationMenuSubtitles[-1] -match 'nicht gelesen' -and ($script:evaluationMenuSubtitles -join '|') -notmatch 'CANARY') 'Lesefehler zeigt Abhilfe ohne Rohfehler'

        # Der echte Bereichsdispatcher muss den Fachdialog und nicht generische Befehle öffnen.
        $script:evaluationAreaCalls = 0
        function Show-LabMaintenanceMenu {
            $script:evaluationAreaCalls++
            if ($script:evaluationAreaCalls -eq 1) { 'EvaluationWatch' } else { 'back' }
        }
        $script:evaluationMenuChoices.Enqueue('cancel')
        Invoke-LabAreaMenuInteractive -Area Maintenance
        Assert-View ($script:evaluationAreaCalls -eq 2 -and $script:evaluationMenuChoices.Count -eq 0) 'Echter Wartungsdispatcher öffnet den Fachdialog und kehrt zurück'

        # Ausführung des unveränderten GET-Routenrumpfs mit synthetischem Response-Adapter.
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'Tools/Start-SqlServerLabUi.ps1'), [ref]$tokens, [ref]$parseErrors)
        $route = $ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -match "^\`$path -eq '/api/evaluation-watch'"}, $true)
        Assert-View ($null -ne $route -and $route.Clauses[0].Item1.Extent.Text -match "HttpMethod -eq 'GET'") 'GET-Route ist auf lesende HTTP-Methode begrenzt'
        $routeScript = [scriptblock]::Create('foreach ($once in @(1)) ' + $route.Clauses[0].Item2.Extent.Text)
        $context = [pscustomobject]@{}
        function Write-UiResponse { param($Context,$Body,$ContentType,[int]$StatusCode=200) $script:evaluationResponse = [pscustomobject]@{ Body=$Body; Status=$StatusCode } }
        $script:evaluationViewMode = 'normal'
        & $routeScript
        $response = $script:evaluationResponse.Body | ConvertFrom-Json
        Assert-View ($script:evaluationResponse.Status -eq 200 -and $response.Rows.Count -eq $view.Rows.Count) 'Echte GET-Route nutzt dieselbe importierte Projektion ohne Provider-Gate'
        $script:evaluationViewMode = 'error'
        & $routeScript
        Assert-View ($script:evaluationResponse.Status -eq 503 -and $script:evaluationResponse.Body -eq 'EVALUATION_WATCH_READ_UNAVAILABLE') 'GET-Lesefehler bleibt bereinigt und nicht erfolgreich'
    }
    finally {
        Set-Item Function:script:Get-SqlServerLabEvaluationWatch $original
        Remove-Variable -Scope Script -Name evaluationViewFixture,evaluationViewCalls,evaluationViewMode,evaluationMenuChoices,evaluationMenuSubtitles,evaluationAreaCalls,evaluationResponse -ErrorAction SilentlyContinue
    }
} $Watch $Repository
