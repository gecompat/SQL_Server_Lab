function Get-LabWorkflowLifecycleFingerprint {
    [CmdletBinding()]
    param()

    try {
        $runs = @(Get-LabActiveRuns -StateRoot (Get-LabStateRoot) | ForEach-Object {
            [pscustomobject]@{
                runId = $_.runId
                name = Get-LabWorkflowValue -InputObject $_.metadata -Name 'name' -Default ''
                state = Get-LabWorkflowValue -InputObject $_.runtime -Name 'state' -Default ''
                updatedAt = Get-LabWorkflowValue -InputObject $_ -Name 'updatedAt' -Default ''
            }
        } | Sort-Object runId)
        return Get-LabWorkflowHash -Text ($runs | ConvertTo-Json -Depth 10 -Compress) -Length 24
    }
    catch {
        return $null
    }
}

function Select-LabWorkflowItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScreenId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Source,
        [Parameter(Mandatory)][scriptblock]$Label,
        [Parameter(Mandatory)][scriptblock]$Value
    )

    if ($Source.Count -eq 0) { return @() }
    $items = for ($index = 0; $index -lt $Source.Count; $index++) {
        New-LabConsoleItem -Id ([string]$index) -Label ([string](& $Label $Source[$index])) -Value ([string](& $Value $Source[$index])) -Shortcut ([string]($index + 1)) -Data $Source[$index]
    }
    $selection = Invoke-LabConsoleMultiSelect -ScreenId $ScreenId -Title $Title -Items $items
    if ($selection.Status -ne 'Confirmed') { return @() }
    return @($selection.SelectedItems | ForEach-Object Data)
}

function New-LabComposerItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Name,
        [ValidateRange(1, 100)][int]$Count = 1,
        [object]$Intent = ([pscustomobject]@{}),
        [object]$Overrides = ([pscustomobject]@{})
    )

    return [pscustomobject][ordered]@{
        id = ConvertTo-LabWorkflowSlug -Text $Name -Fallback ('item-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
        kind = $Kind
        count = $Count
        intent = $Intent
        overrides = $Overrides
    }
}

function Read-LabComposerInteger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][int]$Default,
        [int]$Minimum = 1
    )

    $text = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
    $number = 0
    if (-not [int]::TryParse($text, [ref]$number) -or $number -lt $Minimum) {
        throw "'$text' ist keine gueltige Zahl ab $Minimum."
    }
    return $number
}

function Get-LabBatchSecretVariableName {
    <#
    .SYNOPSIS Leitet den eng benannten Variablennamen aus einem Positionsnamen ab.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ItemName)

    $slug = (([string]$ItemName).ToUpperInvariant() -replace '[^A-Z0-9]+', '_').Trim('_')
    if (-not $slug) { $slug = 'BATCH' }
    return "SQL_SERVER_LAB_SECRET_$slug"
}

function Get-LabAvailableSecretVariableName {
    <#
    .SYNOPSIS Listet die in dieser Sitzung gesetzten Secret-Prozessvariablen.
    #>
    [CmdletBinding()]
    param()

    return @([Environment]::GetEnvironmentVariables('Process').GetEnumerator() |
        Where-Object { [string]$_.Key -match '^SQL_SERVER_LAB_SECRET_[A-Z0-9_]+$' -and -not [string]::IsNullOrWhiteSpace([string]$_.Value) } |
        ForEach-Object { [string]$_.Key } |
        Sort-Object)
}

function Set-LabBatchSaSecretInteractive {
    <#
    .SYNOPSIS Setzt die Secret-Prozessvariable und liefert nur den Erfolg zurueck.
    .DESCRIPTION Das Kennwort verlaesst diese Funktion nicht. Der Batch haelt
    ausschliesslich den Variablennamen.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VariableName)

    $first = Read-Host "  SA-Kennwort fuer $VariableName" -AsSecureString
    $second = Read-Host '  SA-Kennwort bestaetigen' -AsSecureString
    $firstPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($first)
    $secondPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($second)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($firstPointer)
        if ($plain -ne [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secondPointer)) {
            Write-LabWarning 'Die Kennwoerter stimmen nicht ueberein.'
            return $false
        }
        if ([string]::IsNullOrWhiteSpace($plain)) {
            Write-LabWarning 'Ein leeres Kennwort ist nicht zulaessig.'
            return $false
        }
        [Environment]::SetEnvironmentVariable($VariableName, $plain, 'Process')
        Write-LabSuccess "Prozessvariable '$VariableName' ist fuer diese Sitzung gesetzt."
        return $true
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstPointer)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondPointer)
    }
}

function Resolve-LabBatchSaSecretInteractive {
    <#
    .SYNOPSIS Bestimmt die Secret-Referenz einer Containerposition.
    .DESCRIPTION Ohne diesen Schritt scheitert die Uebergabe im Preflight, ohne
    dass die Oberflaeche einen Weg zur Behebung anbietet.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ItemName)

    $suggested = Get-LabBatchSecretVariableName -ItemName $ItemName
    $items = [Collections.Generic.List[object]]::new()
    $shortcut = 0
    foreach ($existing in (Get-LabAvailableSecretVariableName)) {
        $shortcut++
        $items.Add((New-LabConsoleItem -Id $existing -Label $existing -Value 'in dieser Sitzung gesetzt' -Shortcut ([string]$shortcut)))
    }
    $items.Add((New-LabConsoleItem -Id '__new' -Label "Neue Referenz anlegen: $suggested" -Value 'Kennwort wird nur als Prozessvariable gehalten' -Shortcut 'n'))
    $items.Add((New-LabConsoleItem -Id '__none' -Label 'Ohne Referenz fortfahren' -Value 'Position bleibt bis zur Nachpflege nicht uebergebbar' -Shortcut '0'))

    $choice = Invoke-LabConsoleMenu -ScreenId 'batch-sa-secret' -Title 'SA-Kennwort der Containerposition' `
        -Subtitle 'Der Batch speichert nur den Variablennamen, niemals das Kennwort' -Items @($items)
    if ($choice.Status -ne 'Selected') { return '' }
    switch ([string]$choice.SelectedItem.Id) {
        '__none' { return '' }
        '__new' { if (Set-LabBatchSaSecretInteractive -VariableName $suggested) { return $suggested } else { return '' } }
        default { return [string]$choice.SelectedItem.Id }
    }
}

function Add-LabSqlComposerItemInteractive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Basket)

    $intent = Read-LabSqlEnvironmentIntentInteractive
    if ($null -eq $intent) { return }
    if ([string]$intent.Platform -eq 'Windows' -and $intent.Patch -and $intent.Patch.Cu -and
        -not (Confirm-LabSqlWindowsPatchMediaInteractive -Intent $intent)) {
        return
    }
    $name = Read-Host '  Name der Umgebung beziehungsweise Gruppe'
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = 'sql-' + ([string](Get-LabWorkflowValue -InputObject $intent -Name 'VersionId' -Default 'environment')).ToLowerInvariant()
    }
    try { $count = Read-LabComposerInteger -Prompt '  Anzahl identischer Positionen' -Default 1 }
    catch { Write-LabWarning $_.Exception.Message; return }
    $table = ConvertTo-LabWorkflowHashtable -InputObject $intent
    $table['ProviderPreference'] = 'Auto'
    $platform = [string](Get-LabWorkflowValue -InputObject $intent -Name 'Platform' -Default (Get-LabWorkflowValue -InputObject $intent -Name 'OperatingSystem' -Default ''))
    $kind = if ($platform -match 'Windows') { 'SqlWindowsEnvironment' } else { 'SqlEnvironment' }
    if ($kind -eq 'SqlEnvironment') {
        $secretVariable = Resolve-LabBatchSaSecretInteractive -ItemName $name
        if ($secretVariable) { $table['SaPasswordEnvironmentVariable'] = $secretVariable }
        else { Write-LabWarning "Position '$name' hat keine Secret-Referenz und kann so nicht uebergeben werden." }
    }
    $Basket.Add((New-LabComposerItem -Kind $kind -Name $name -Count $count -Intent ([pscustomobject]$table)))
}

function Add-LabWindowsComposerItemInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Basket,
        [switch]$Slot
    )

    $name = Read-Host '  Name der Windows-Umgebung beziehungsweise Gruppe'
    if ([string]::IsNullOrWhiteSpace($name)) { Write-LabWarning 'Ein Name ist erforderlich.'; return }
    $os = Read-Host '  Betriebssystem [Windows Server 2025]'
    if ([string]::IsNullOrWhiteSpace($os)) { $os = 'Windows Server 2025' }
    $variantChoice = Invoke-LabConsoleMenu -ScreenId 'batch-windows-variant' -Title 'Windows-Variante' -Items @(
        New-LabConsoleItem -Id 'Desktop' -Label 'Desktop Experience' -Shortcut '1'
        New-LabConsoleItem -Id 'Core' -Label 'Server Core' -Shortcut '2'
    )
    if ($variantChoice.Status -ne 'Selected') { return }
    try {
        $count = Read-LabComposerInteger -Prompt '  Anzahl identischer Positionen' -Default 1
        $cpu = Read-LabComposerInteger -Prompt '  CPU pro Position' -Default 4
        $memory = Read-LabComposerInteger -Prompt '  RAM in MB pro Position' -Default 8192 -Minimum 512
    }
    catch { Write-LabWarning $_.Exception.Message; return }
    $kind = if ($Slot) { 'WindowsSlot' } else { 'WindowsEnvironment' }
    $intent = [pscustomobject][ordered]@{
        OperatingSystem = $os
        Variant = [string]$variantChoice.SelectedItem.Id
        Cpu = $cpu
        MemoryMB = $memory
        ProviderPreference = 'Auto'
        RequiresUserSetup = $true
    }
    $Basket.Add((New-LabComposerItem -Kind $kind -Name $name -Count $count -Intent $intent))
}

function Add-LabMatrixComposerItemsInteractive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Basket)

    $parse = { param($Text, $Default) $values = @(([string]$Text).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }); if ($values.Count -eq 0) { @($Default) } else { $values } }
    # Der Matrixpfad kann derzeit nur Linux-Container oder Windows über Hyper-V
    # planen. Die Auswahl steht im Prompt, damit kein implizites Raten nötig ist.
    $osValues = @(& $parse (Read-Host '  Betriebssysteme, kommagetrennt (Linux, Windows) [Linux]') 'Linux')
    $sqlValues = @(& $parse (Read-Host '  SQL-Versionen, kommagetrennt [2022]') '2022')
    $cuValues = @(& $parse (Read-Host '  CU/Patchstaende, kommagetrennt [latest]') 'latest')
    $platformValues = @(& $parse (Read-Host '  Plattformen, kommagetrennt [Auto]') 'Auto')
    $total = $osValues.Count * $sqlValues.Count * $cuValues.Count * $platformValues.Count
    if ($total -gt 100) { Write-LabWarning "Die Matrix wuerde $total Positionen erzeugen; maximal 100 sind zulaessig."; return }
    # Eine Matrix erzeugt viele gleichartige Containerpositionen; eine gemeinsame Referenz genuegt.
    $matrixSecretVariable = ''
    if (@($osValues | Where-Object { $_ -notmatch 'Windows' }).Count -gt 0) {
        $matrixSecretVariable = Resolve-LabBatchSaSecretInteractive -ItemName 'matrix'
        if (-not $matrixSecretVariable) { Write-LabWarning 'Die Container-Positionen der Matrix haben keine Secret-Referenz und koennen so nicht uebergeben werden.' }
    }
    foreach ($os in $osValues) { foreach ($sql in $sqlValues) { foreach ($cu in $cuValues) { foreach ($platform in $platformValues) {
        $name = ConvertTo-LabWorkflowSlug -Text "sql-$sql-$cu-$os-$platform"
        $kind = if ($os -match 'Windows') { 'SqlWindowsEnvironment' } else { 'SqlEnvironment' }
        $matrixIntent = [ordered]@{
            OperatingSystem = $os; SqlVersion = $sql; Version = $sql; Patch = $cu; Platform = $platform
            ProviderPreference = 'Auto'; RequiresUserSetup = $os -match 'Windows'
        }
        if ($kind -eq 'SqlEnvironment' -and $matrixSecretVariable) { $matrixIntent['SaPasswordEnvironmentVariable'] = $matrixSecretVariable }
        $Basket.Add((New-LabComposerItem -Kind $kind -Name $name -Intent ([pscustomobject]$matrixIntent)))
    } } } }
}

function Edit-LabComposerItemsInteractive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Basket)

    $selected = Select-LabWorkflowItems -ScreenId 'batch-bulk-edit' -Title 'Positionen fuer gemeinsame Aenderung auswaehlen' -Source @($Basket) -Label { param($x) "$($x.id) · $($x.kind)" } -Value { param($x) "Anzahl $($x.count)" }
    if ($selected.Count -eq 0) { return }
    $choice = Invoke-LabConsoleMenu -ScreenId 'batch-bulk-property' -Title 'Gemeinsame Eigenschaft' -Items @(
        New-LabConsoleItem -Id 'Cpu' -Label 'CPU' -Shortcut '1'
        New-LabConsoleItem -Id 'MemoryMB' -Label 'RAM in MB' -Shortcut '2'
        New-LabConsoleItem -Id 'Priority' -Label 'Prioritaet' -Shortcut '3'
        New-LabConsoleItem -Id 'ProviderPreference' -Label 'Providerpraeferenz (Erweitert)' -Value 'Auto bleibt Standard' -Shortcut '4'
        New-LabConsoleItem -Id 'AutoStart' -Label 'Autostart' -Shortcut '5'
    )
    if ($choice.Status -ne 'Selected') { return }
    $property = [string]$choice.SelectedItem.Id
    if ($property -eq 'ProviderPreference') {
        $provider = Invoke-LabConsoleMenu -ScreenId 'batch-provider-advanced' -Title 'Erweiterte Providerpraeferenz' -Items @(
            New-LabConsoleItem -Id 'Auto' -Label 'Auto (Standard)' -Shortcut '1'
            New-LabConsoleItem -Id 'docker' -Label 'Docker explizit' -Shortcut '2'
            New-LabConsoleItem -Id 'podman' -Label 'Podman explizit' -Shortcut '3'
            New-LabConsoleItem -Id 'hyperv' -Label 'Hyper-V explizit' -Shortcut '4'
        )
        if ($provider.Status -ne 'Selected') { return }
        $value = [string]$provider.SelectedItem.Id
    }
    else {
        $value = Read-Host "  Neuer Wert fuer $property"
        if ($property -in @('Cpu', 'MemoryMB')) { $number = 0; if (-not [int]::TryParse($value, [ref]$number) -or $number -lt 1) { Write-LabWarning 'Ungueltige Zahl.'; return }; $value = $number }
        elseif ($property -eq 'AutoStart') { $value = $value -match '^(1|j|ja|y|yes|true)$' }
        elseif ($property -eq 'Priority' -and $value -notin @('High', 'Normal', 'Low')) { Write-LabWarning 'Prioritaet muss High, Normal oder Low sein.'; return }
    }
    foreach ($item in $selected) {
        $table = ConvertTo-LabWorkflowHashtable -InputObject $item.overrides
        $table[$property] = $value
        $item.overrides = [pscustomobject]$table
    }
}

function Show-LabBatchReviewInteractive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Batch)

    Clear-Host
    Write-Host "  Batch-Review: $($Batch.name)" -ForegroundColor Cyan
    Write-Host "  BatchId: $($Batch.batchId) | Prioritaet: $($Batch.priority)" -ForegroundColor DarkGray
    Write-Host ''
    foreach ($item in @($Batch.items)) {
        Write-Host "  [$($item.itemId)] $($item.name)" -ForegroundColor White
        Write-Host "      $($item.kind) · Provider $($item.provider) · CPU $($item.resourceEstimate.cpu) · RAM $($item.resourceEstimate.memoryMB) MB · Storage $($item.resourceEstimate.storageGB) GB" -ForegroundColor Gray
        Write-Host "      Entscheidung: $($item.providerReason)" -ForegroundColor DarkGray
        $overrideProperties = @($item.overrides.PSObject.Properties)
        if ($overrideProperties.Count -gt 0) { Write-Host ("      Abweichend: " + (($overrideProperties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ')) -ForegroundColor Yellow }
        else { Write-Host '      Werte: gemeinsam' -ForegroundColor DarkGray }
    }
    if (@($Batch.sharedDependencies).Count -gt 0) {
        Write-Host ''; Write-Host '  Gemeinsame Abhaengigkeiten:' -ForegroundColor Yellow
        foreach ($dependency in @($Batch.sharedDependencies)) { Write-Host "    - eine Vorlage fuer: $(@($dependency.itemIds) -join ', ')" -ForegroundColor Gray }
    }
    $r = $Batch.preflight.estimatedResources
    Write-Host ''; Write-Host "  Gesamtbedarf: CPU $($r.cpu) · RAM $($r.memoryMB) MB · Storage $($r.storageGB) GB" -ForegroundColor Cyan
    Write-Host '  Scheduler: maximal 2 Worker, maximal 1 HyperVHeavy; User-Gates belegen keinen Worker.' -ForegroundColor DarkGray
    Write-Host '  Cleanup entfernt nur batch-eigene Ressourcen; Vorlagen, Medien und geschuetzte Daten bleiben erhalten.' -ForegroundColor DarkGray
    foreach ($warning in @($Batch.preflight.warnings)) { Write-Host "  WARNUNG: $warning" -ForegroundColor Yellow }
    return (Read-LabConfirm -Prompt '  Gesamten Plan in die Queue stellen?' -Default $false)
}

function Invoke-LabBatchComposerInteractive {
    [CmdletBinding()]
    param([switch]$SlotMode)

    $basket = [Collections.Generic.List[object]]::new()
    $nameInput = Read-LabConsoleTextInput -Prompt '  Batch-Name' -Default 'Neue Umgebungen'
    if ($nameInput.Status -ne 'Confirmed') { return }
    $name = [string]$nameInput.Value
    while ($true) {
        $expandedCount = if ($basket.Count -eq 0) { 0 } else { [int](@($basket | Measure-Object -Property count -Sum).Sum) }
        $summary = "$($basket.Count) Gruppen · $expandedCount Positionen"
        $choice = Invoke-LabConsoleMenu -ScreenId 'batch-composer' -Title "Batch planen: $name" -Subtitle "$summary · Prioritaet Normal" -Items @(
            New-LabConsoleItem -Id 'add-sql' -Label 'SQL-Umgebung hinzufuegen' -Value 'Linux oder Windows · Provider Auto' -Shortcut '1'
            New-LabConsoleItem -Id 'add-windows' -Label $(if ($SlotMode) { 'Windows-Slot-Gruppe hinzufuegen' } else { 'Reine Windows-Umgebung hinzufuegen' }) -Value 'Anzahl, OS, CPU und RAM' -Shortcut '2'
            New-LabConsoleItem -Id 'matrix' -Label 'Testmatrix erzeugen' -Value 'OS × SQL-Version × CU × Plattform' -Shortcut '3'
            New-LabConsoleItem -Id 'duplicate' -Label 'Position duplizieren' -Shortcut '4' -Disabled:($basket.Count -eq 0)
            New-LabConsoleItem -Id 'count' -Label 'Anzahl einer Position aendern' -Shortcut '5' -Disabled:($basket.Count -eq 0)
            New-LabConsoleItem -Id 'bulk' -Label 'Ausgewaehlte Positionen gemeinsam aendern' -Value 'Abweichungen bleiben sichtbar' -Shortcut '6' -Disabled:($basket.Count -eq 0)
            New-LabConsoleItem -Id 'remove' -Label 'Positionen entfernen' -Shortcut '7' -Disabled:($basket.Count -eq 0)
            New-LabConsoleItem -Id 'reorder' -Label 'Position umsortieren' -Shortcut '8' -Disabled:($basket.Count -lt 2)
            New-LabConsoleItem -Id 'review' -Label 'Gesamtplan pruefen und zur Queue uebergeben' -Value $summary -Shortcut '9' -Disabled:($basket.Count -eq 0)
            New-LabConsoleItem -Id 'save' -Label 'Validiert speichern und spaeter fortsetzen' -Shortcut 's' -Disabled:($basket.Count -eq 0)
            New-LabConsoleItem -Id 'discard' -Label 'Entwurf verwerfen' -Shortcut '0'
        )
        if ($choice.Status -ne 'Selected' -or $choice.SelectedItem.Id -eq 'discard') { return }
        switch ([string]$choice.SelectedItem.Id) {
            'add-sql' { Add-LabSqlComposerItemInteractive -Basket $basket }
            'add-windows' { Add-LabWindowsComposerItemInteractive -Basket $basket -Slot:$SlotMode }
            'matrix' { Add-LabMatrixComposerItemsInteractive -Basket $basket }
            'duplicate' {
                $selected = @(Select-LabWorkflowItems -ScreenId 'batch-duplicate' -Title 'Position auswaehlen' -Source @($basket) -Label { param($x) $x.id } -Value { param($x) "$($x.kind) · Anzahl $($x.count)" }) | Select-Object -First 1
                if ($null -ne $selected) { $copy = $selected | ConvertTo-Json -Depth 30 | ConvertFrom-Json; $copy.id += '-copy'; $basket.Add($copy) }
            }
            'count' {
                $selected = @(Select-LabWorkflowItems -ScreenId 'batch-count' -Title 'Position auswaehlen' -Source @($basket) -Label { param($x) $x.id } -Value { param($x) "Anzahl $($x.count)" }) | Select-Object -First 1
                if ($null -ne $selected) { try { $selected.count = Read-LabComposerInteger -Prompt '  Neue Anzahl' -Default ([int]$selected.count) } catch { Write-LabWarning $_.Exception.Message } }
            }
            'bulk' { Edit-LabComposerItemsInteractive -Basket $basket }
            'remove' { foreach ($entry in @(Select-LabWorkflowItems -ScreenId 'batch-remove' -Title 'Positionen entfernen' -Source @($basket) -Label { param($x) $x.id } -Value { param($x) "$($x.kind) · Anzahl $($x.count)" })) { $null = $basket.Remove($entry) } }
            'reorder' {
                $selected = @(Select-LabWorkflowItems -ScreenId 'batch-reorder' -Title 'Position auswaehlen' -Source @($basket) -Label { param($x) $x.id } -Value { param($x) $x.kind }) | Select-Object -First 1
                if ($null -ne $selected) {
                    $direction = Invoke-LabConsoleMenu -ScreenId 'batch-reorder-direction' -Title 'Verschieben' -Items @(
                        New-LabConsoleItem -Id 'Up' -Label 'Nach oben' -Shortcut '1'; New-LabConsoleItem -Id 'Down' -Label 'Nach unten' -Shortcut '2'
                    )
                    if ($direction.Status -eq 'Selected') { $index = $basket.IndexOf($selected); $target = if ($direction.SelectedItem.Id -eq 'Up') { [Math]::Max(0, $index - 1) } else { [Math]::Min($basket.Count - 1, $index + 1) }; if ($target -ne $index) { $basket.RemoveAt($index); $basket.Insert($target, $selected) } }
                }
            }
            { $_ -in @('review', 'save') } {
                try {
                    $batch = New-SqlServerLabBatch -Name $name -Priority Normal -Defaults ([pscustomobject]@{ ProviderPreference = 'Auto' }) -Items @($basket) -Queue:$false
                    if ($_ -eq 'save') { Write-LabSuccess "Batch '$($batch.batchId)' wurde validiert gespeichert."; return }
                    if (Show-LabBatchReviewInteractive -Batch $batch) {
                        $batch = Submit-SqlServerLabBatch -BatchId $batch.batchId
                        Write-LabSuccess "Batch '$($batch.batchId)' ist persistent und eingereiht."
                        try { Start-SqlServerLabOperationHost } catch { Write-LabWarning "Scheduler-Host konnte nicht gestartet werden: $($_.Exception.Message)" }
                    }
                    else { Write-LabInfo "Batch '$($batch.batchId)' bleibt validiert gespeichert." }
                    return
                }
                catch { Write-LabError $_.Exception.Message }
            }
        }
    }
}

function Show-LabOperationGateInteractive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Operation)

    $gate = $Operation.userGate
    Clear-Host
    Write-Host "  Benutzeraktion: $($Operation.title)" -ForegroundColor $(if ($Operation.status -eq 'CandidateSatisfied') { 'Yellow' } else { 'Cyan' })
    Write-Host "  Ressource: $($gate.resource)" -ForegroundColor White
    Write-Host "  Grund: $($gate.reason)" -ForegroundColor Gray
    Write-Host ''; Write-Host '  Vollstaendige Arbeitsschritte:' -ForegroundColor White
    $number = 0; foreach ($instruction in @($gate.instructions)) { $number++; Write-Host "    $number. $instruction" -ForegroundColor Gray }
    Write-Host ''; Write-Host "  Erwartetes Ergebnis: $($gate.expectedResult)" -ForegroundColor White
    Write-Host "  Technische Verifikation: $($gate.verification.type)" -ForegroundColor DarkGray
    if ($Operation.status -eq 'CandidateSatisfied') { Write-Host '  Read-only-Probe: vermutlich erreicht. Ohne Ihr Okay wird nichts fortgesetzt.' -ForegroundColor Yellow }
    $gate.lastShownAt = Get-LabWorkflowUtcNow
    Write-LabOperationState -Operation $Operation -StateRoot (Get-LabStateRoot) | Out-Null
}

function Select-LabQueueOperationInteractive {
    [CmdletBinding()]
    param(
        [string]$Title = 'Vorgang auswaehlen',
        [scriptblock]$Filter = { $true }
    )

    $source = @((Get-SqlServerLabQueue).items | Where-Object $Filter)
    if ($source.Count -eq 0) { Write-LabInfo 'Keine passenden Vorgaenge vorhanden.'; return $null }
    $items = for ($index = 0; $index -lt $source.Count; $index++) {
        New-LabConsoleItem -Id $source[$index].operationId -Label "$($source[$index].title) [$($source[$index].status)]" -Value "$($source[$index].priority) · $($source[$index].resourceClass) · $($source[$index].progress)%" -Shortcut ([string]($index + 1))
    }
    $selection = Invoke-LabConsoleMenu -ScreenId 'queue-select' -Title $Title -Items $items
    if ($selection.Status -ne 'Selected') { return $null }
    return Get-SqlServerLabOperation -OperationId $selection.SelectedItem.Id
}

function Confirm-LabCandidateOperationsInteractive {
    [CmdletBinding()]
    param()

    $candidates = @((Get-SqlServerLabQueue).items | Where-Object status -eq 'CandidateSatisfied')
    if ($candidates.Count -eq 0) { Write-LabInfo 'Keine vermutlich erledigten User-Gates vorhanden.'; return }
    $selected = Select-LabWorkflowItems -ScreenId 'queue-confirm-bulk' -Title 'Tatsaechlich bearbeitete Positionen auswaehlen' -Source $candidates -Label { param($x) $x.title } -Value { param($x) "$($x.userGate.resource) · technische Einzelpruefung" }
    foreach ($candidate in $selected) {
        $operation = Get-SqlServerLabOperation -OperationId $candidate.operationId
        Show-LabOperationGateInteractive -Operation $operation
        $credential = if ($operation.userGate.verification.type -eq 'HyperVWindowsSetup') { Get-Credential -Message "Windows-Konto fuer $($operation.userGate.resource)" } else { $null }
        $result = Confirm-SqlServerLabOperationUserAction -OperationId $operation.operationId -Credential $credential
        if ($result.success) { Write-LabSuccess "[$($operation.itemId)] verifiziert und wieder eingereiht." } else { Write-LabWarning "[$($operation.itemId)] bleibt im User-Gate: $($result.message)" }
    }
}

function Get-LabQueueMenuAvailability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Queue,
        [object[]]$Batches = @()
    )

    $items = @($Queue.items)
    $priorityCandidates = @($items | Where-Object status -ne 'Running')
    $movableItems = @($priorityCandidates | Group-Object priority | Where-Object Count -ge 2 | ForEach-Object { @($_.Group) })
    $pausableItems = @($items | Where-Object status -in @('Queued','WaitingForDependency','Paused'))
    $activeBatches = @($Batches | Where-Object status -ne 'Cancelled')
    [PSCustomObject]@{
        HasOverview = $items.Count -gt 0
        HasUserGates = [int]$Queue.waitingUserGates -gt 0
        HasCandidates = @($items | Where-Object status -eq 'CandidateSatisfied').Count -gt 0
        CanChangePriority = $priorityCandidates.Count -ge 2
        PriorityOperationIds = @($priorityCandidates.operationId)
        CanMove = $movableItems.Count -ge 2
        MovableOperationIds = @($movableItems.operationId)
        CanPauseOrResume = $pausableItems.Count -gt 0
        CanStopOperation = $items.Count -gt 0
        CanStopBatch = $activeBatches.Count -gt 0
        CanRunScheduler = $items.Count -gt 0
    }
}

function New-LabQueueStatusProvider {
    <#
    .SYNOPSIS Liefert den gedrosselten Fortschrittslieferanten fuer das Statusband der Queue.
    .DESCRIPTION Die Queue-Projektion fuehrt keine Schritt- und Laufzeitfelder,
    deshalb werden die laufenden Operationen direkt gelesen. Der Lesevorgang ist
    gedrosselt, damit der Heartbeat den State-Store nicht bei jedem Tick belastet.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 50)][int]$Height = 5,
        [ValidateRange(200, 10000)][int]$RefreshMilliseconds = 1000,
        [ValidateRange(0, 1000)][int]$Width = 0,
        [AllowNull()][scriptblock]$OperationReader,
        [AllowNull()][scriptblock]$Clock
    )

    $reader = if ($OperationReader) { $OperationReader } else { { @(Get-SqlServerLabOperation) } }
    $now = if ($Clock) { $Clock } else { { [datetime]::UtcNow } }
    $fixedWidth = $Width
    $cache = [PSCustomObject]@{ Running = @(); LastRead = [datetime]::MinValue; Reads = 0 }
    return {
        param($Tick)
        $current = & $now
        if (($current - $cache.LastRead).TotalMilliseconds -ge $RefreshMilliseconds) {
            try {
                $cache.Running = @((& $reader) | Where-Object { [string]$_.status -eq 'Running' })
                $cache.Reads++
            }
            catch { }
            $cache.LastRead = $current
        }
        # Ein Host ohne echte Fenstergroesse meldet 0; dann gilt eine tragfaehige Vorgabe.
        $bandWidth = 78
        if ($fixedWidth -gt 20) { $bandWidth = $fixedWidth }
        else { try { $detected = [int][Console]::WindowWidth; if ($detected -gt 20) { $bandWidth = $detected - 1 } } catch { } }
        Get-LabConsoleStatusBand -Operation @($cache.Running) -Tick $Tick -Width $bandWidth -Height $Height -Now $current
    }.GetNewClosure()
}

function Invoke-LabQueueInteractive {
    [CmdletBinding()]
    param()

    $statusProvider = New-LabQueueStatusProvider -Height 5
    while ($true) {
        $queue = Get-SqlServerLabQueue
        $batches = @(Get-SqlServerLabBatch)
        $availability = Get-LabQueueMenuAvailability -Queue $queue -Batches $batches
        $subtitle = "$($queue.runningWorkers)/$($queue.maxWorkers) Worker · $($queue.waitingUserGates) User-Gates · Queue $($queue.length)"
        $choice = Invoke-LabConsoleMenu -ScreenId 'queue-menu' -Title 'Vorgaenge, Queue und Benutzeraktionen' -Subtitle $subtitle -StatusHeight 5 -StatusProvider $statusProvider -Items @(
            New-LabConsoleItem -Id 'overview' -Label 'Queue-Uebersicht und Details' -Value $subtitle -Shortcut '1' -Disabled:(-not $availability.HasOverview) -DisabledReason 'Die Queue enthaelt derzeit keinen Vorgang.'
            New-LabConsoleItem -Id 'gates' -Label 'Benutzeraktionen oeffnen' -Value 'Schritte werden immer vollstaendig angezeigt' -Shortcut '2' -Disabled:(-not $availability.HasUserGates) -DisabledReason 'Kein Vorgang wartet auf eine Benutzerbestaetigung.'
            New-LabConsoleItem -Id 'bulk-confirm' -Label 'Vermutlich erledigte Positionen auswaehlen, pruefen und fortsetzen' -Shortcut '3' -Disabled:(-not $availability.HasCandidates) -DisabledReason 'Kein Vorgang steht im Status CandidateSatisfied.'
            New-LabConsoleItem -Id 'priority' -Label 'Prioritaet aendern' -Value 'Mindestens zwei noch nicht laufende Vorgaenge' -Shortcut '4' -Disabled:(-not $availability.CanChangePriority) -DisabledReason 'Eine Priorisierung wirkt erst ab zwei noch nicht laufenden Vorgaengen.'
            New-LabConsoleItem -Id 'move' -Label 'Wartenden Vorgang umreihen' -Value 'Mindestens zwei Vorgaenge derselben Prioritaet' -Shortcut '5' -Disabled:(-not $availability.CanMove) -DisabledReason 'Umreihen wirkt erst ab zwei wartenden Vorgaengen derselben Prioritaet.'
            New-LabConsoleItem -Id 'pause' -Label 'Vorgang pausieren oder freigeben' -Shortcut '6' -Disabled:(-not $availability.CanPauseOrResume) -DisabledReason 'Kein Vorgang ist wartend, blockiert oder pausiert.'
            New-LabConsoleItem -Id 'stop' -Label 'Vorgang endgueltig stoppen und aufraeumen' -Shortcut '7' -Disabled:(-not $availability.CanStopOperation) -DisabledReason 'Die Queue enthaelt derzeit keinen Vorgang, der gestoppt werden koennte.'
            New-LabConsoleItem -Id 'batch-stop' -Label 'Batch stoppen oder vollstaendig zurueckbauen' -Shortcut '8' -Disabled:(-not $availability.CanStopBatch) -DisabledReason 'Es existiert kein aktiver Batch.'
            New-LabConsoleItem -Id 'quiet' -Label 'Ton und Ruhemodus' -Value 'Globale Einstellung, auch fuer kuenftige Vorgaenge' -Shortcut '9'
            New-LabConsoleItem -Id 'run' -Label 'Scheduler jetzt ausfuehren' -Value '2 Worker · 1 HyperVHeavy' -Shortcut 'r' -Disabled:(-not $availability.CanRunScheduler) -DisabledReason 'Die Queue enthaelt keinen Vorgang. Ein Batch im Status Draft erscheint hier nicht; er muss zuvor uebergeben werden.'
            New-LabConsoleItem -Id 'back' -Label 'Zurueck' -Shortcut '0'
        )
        if ($choice.Status -ne 'Selected' -or $choice.SelectedItem.Id -eq 'back') { return }
        switch ([string]$choice.SelectedItem.Id) {
            'overview' {
                $operation = Select-LabQueueOperationInteractive -Title 'Queue-Uebersicht'
                if ($null -ne $operation) {
                    Clear-Host
                    $operation | Select-Object operationId,batchId,itemId,title,status,progress,priority,queuePosition,provider,providerReason,resourceClass,locks,dependencies,error | Format-List | Out-Host
                    if ($operation.status -in @('WaitingForUser','CandidateSatisfied')) { Show-LabOperationGateInteractive -Operation $operation }
                    Wait-LabConsoleAcknowledgement
                }
            }
            'gates' {
                $operation = Select-LabQueueOperationInteractive -Title 'Offene Benutzeraktion' -Filter { $_.status -in @('WaitingForUser','CandidateSatisfied') }
                if ($null -ne $operation) {
                    Show-LabOperationGateInteractive -Operation $operation
                    $action = Invoke-LabConsoleMenu -ScreenId 'user-gate-actions' -Title 'Benutzeraktion' -Items @(
                        New-LabConsoleItem -Id 'confirm' -Label 'Erledigt - pruefen und fortsetzen' -Shortcut '1'
                        New-LabConsoleItem -Id 'later' -Label 'Spaeter fortsetzen' -Shortcut '2'
                        New-LabConsoleItem -Id 'mute' -Label 'Ton fuer diesen Vorgang ausschalten' -Shortcut '3'
                        New-LabConsoleItem -Id 'stop' -Label 'Vorgang endgueltig stoppen und aufraeumen' -Shortcut '4'
                    )
                    if ($action.Status -eq 'Selected' -and $action.SelectedItem.Id -eq 'confirm') { $credential = if ($operation.userGate.verification.type -eq 'HyperVWindowsSetup') { Get-Credential -Message "Windows-Konto fuer $($operation.userGate.resource)" } else { $null }; $result = Confirm-SqlServerLabOperationUserAction -OperationId $operation.operationId -Credential $credential; if ($result.success) { Write-LabSuccess 'Technisch verifiziert und wieder eingereiht.' } else { Write-LabWarning $result.message } }
                    elseif ($action.Status -eq 'Selected' -and $action.SelectedItem.Id -eq 'mute') { Set-SqlServerLabAttention -OperationId $operation.operationId -Muted $true | Out-Null }
                    elseif ($action.Status -eq 'Selected' -and $action.SelectedItem.Id -eq 'stop') { Stop-SqlServerLabOperation -OperationId $operation.operationId -Cleanup -Confirm | Out-Null }
                }
            }
            'bulk-confirm' { Confirm-LabCandidateOperationsInteractive }
            'priority' { $operationIds = @($availability.PriorityOperationIds); $operation = Select-LabQueueOperationInteractive -Filter { $_.operationId -in $operationIds }; if ($null -ne $operation) { $p = Invoke-LabConsoleMenu -ScreenId 'queue-priority' -Title 'Prioritaet' -Subtitle "Aktuell: $($operation.priority)" -Items @(New-LabConsoleItem -Id High -Label High -Shortcut 1 -Disabled:($operation.priority -eq 'High'); New-LabConsoleItem -Id Normal -Label Normal -Shortcut 2 -Disabled:($operation.priority -eq 'Normal'); New-LabConsoleItem -Id Low -Label Low -Shortcut 3 -Disabled:($operation.priority -eq 'Low')); if ($p.Status -eq 'Selected') { Set-SqlServerLabOperationPriority -OperationId $operation.operationId -Priority $p.SelectedItem.Id | Out-Null } } }
            'move' { $operationIds = @($availability.MovableOperationIds); $operation = Select-LabQueueOperationInteractive -Filter { $_.operationId -in $operationIds }; if ($null -ne $operation) { $peers = @($queue.items | Where-Object { $_.priority -eq $operation.priority -and $_.status -ne 'Running' } | Sort-Object queuePosition); $current = [Array]::IndexOf([string[]]@($peers.operationId), [string]$operation.operationId); $d = Invoke-LabConsoleMenu -ScreenId 'queue-move' -Title 'Umreihen' -Items @(New-LabConsoleItem -Id Up -Label 'Nach oben' -Shortcut 1 -Disabled:($current -le 0); New-LabConsoleItem -Id Down -Label 'Nach unten' -Shortcut 2 -Disabled:($current -ge $peers.Count - 1)); if ($d.Status -eq 'Selected') { Move-SqlServerLabOperation -OperationId $operation.operationId -Direction $d.SelectedItem.Id | Out-Null } } }
            'pause' { $operation = Select-LabQueueOperationInteractive -Filter { $_.status -in @('Queued','WaitingForDependency','Paused') }; if ($null -ne $operation) { if ($operation.status -eq 'Paused') { Resume-SqlServerLabOperation -OperationId $operation.operationId | Out-Null } else { Suspend-SqlServerLabOperation -OperationId $operation.operationId | Out-Null } } }
            'stop' { $operation = Select-LabQueueOperationInteractive; if ($null -ne $operation) { Stop-SqlServerLabOperation -OperationId $operation.operationId -Cleanup -Confirm | Out-Null } }
            'batch-stop' { Invoke-LabBatchStopInteractive }
            'quiet' { $q = Invoke-LabConsoleMenu -ScreenId 'queue-quiet' -Title 'Ruhemodus' -Items @(New-LabConsoleItem -Id Off -Label 'Ruhemodus aufheben' -Shortcut 1; New-LabConsoleItem -Id OneHour -Label 'Eine Stunde Ruhe' -Shortcut 2; New-LabConsoleItem -Id EightHours -Label 'Acht Stunden Ruhe' -Shortcut 3; New-LabConsoleItem -Id Indefinite -Label 'Bis zur Aufhebung stummschalten' -Shortcut 4); if ($q.Status -eq 'Selected') { Set-SqlServerLabAttention -QuietMode $q.SelectedItem.Id | Out-Null } }
            'run' {
                $started = @(Invoke-SqlServerLabScheduler -UntilIdle)
                if ($started.Count -gt 0) {
                    Write-LabSuccess "Scheduler hat $($started.Count) Vorgang/Vorgaenge ausgefuehrt."
                }
                else {
                    # Ohne diesen Hinweis kehrt der Menuepunkt wortlos zurueck und der Grund bleibt unsichtbar.
                    $blocked = @((Get-SqlServerLabQueue).items | Where-Object { $_.blockedReason })
                    if ($blocked.Count -eq 0) { Write-LabInfo 'Kein Vorgang war startbereit.' }
                    else {
                        Write-LabWarning "Kein Vorgang wurde gestartet. $($blocked.Count) Vorgang/Vorgaenge sind blockiert:"
                        foreach ($item in $blocked | Select-Object -First 5) { Write-LabStatus -Label $item.itemId -Value $item.blockedReason }
                    }
                }
                Wait-LabConsoleAcknowledgement
            }
        }
    }
}

function Invoke-LabBatchStopInteractive {
    [CmdletBinding()]
    param()

    $batches = @(Get-SqlServerLabBatch | Where-Object status -notin @('Cancelled'))
    if ($batches.Count -eq 0) { Write-LabInfo 'Keine Batches vorhanden.'; return }
    $items = for ($index = 0; $index -lt $batches.Count; $index++) { New-LabConsoleItem -Id $batches[$index].batchId -Label "$($batches[$index].name) [$($batches[$index].status)]" -Value "$($batches[$index].progress.percent)%" -Shortcut ([string]($index + 1)) }
    $selection = Invoke-LabConsoleMenu -ScreenId 'batch-stop-select' -Title 'Batch auswaehlen' -Items $items
    if ($selection.Status -ne 'Selected') { return }
    $mode = Invoke-LabConsoleMenu -ScreenId 'batch-stop-mode' -Title 'Abbruchwirkung' -Items @(
        New-LabConsoleItem -Id unfinished -Label 'Unfertige Positionen stoppen' -Shortcut 1
        New-LabConsoleItem -Id all -Label 'Gesamten Batch zurueckbauen' -Value 'zweite Review listet alle Umgebungen' -Shortcut 2
    )
    if ($mode.Status -ne 'Selected') { return }
    if ($mode.SelectedItem.Id -eq 'all') {
        $batch = Get-SqlServerLabBatch -BatchId $selection.SelectedItem.Id
        Clear-Host; Write-Host '  Vollstaendiger Rueckbau entfernt diese batch-eigenen Positionen:' -ForegroundColor Yellow
        foreach ($item in @($batch.items)) { Write-Host "    - $($item.itemId): $($item.name)" }
        if (Read-LabConfirm -Prompt '  Wirklich vollstaendig zurueckbauen?' -Default $false) { Stop-SqlServerLabBatch -BatchId $batch.batchId -Cleanup -IncludeCompleted -Confirm:$false | Out-Null }
    }
    else { Stop-SqlServerLabBatch -BatchId $selection.SelectedItem.Id -Cleanup -Confirm | Out-Null }
}

function Get-LabMessageJournalMarker {
    <#
    .SYNOPSIS Merkt sich den Journalstand vor einer Aktion.
    #>
    [CmdletBinding()]
    param()

    $entries = @(Get-LabMessage)
    if ($entries.Count -eq 0) { return 0 }
    return [int]$entries[-1].sequence
}

function Copy-LabMessageReportToClipboard {
    <#
    .SYNOPSIS Legt den Klartextbericht in die Zwischenablage, sofern der Host das unterstuetzt.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Message)

    if (@($Message).Count -eq 0) { Write-LabInfo 'Keine Meldung zum Kopieren vorhanden.'; return $false }
    $report = Format-LabMessageReport -Message $Message
    if (-not (Get-Command -Name Set-Clipboard -ErrorAction SilentlyContinue)) {
        Write-LabWarning 'Dieser Host bietet keine Zwischenablage. Der Bericht steht im Meldungsjournal.'
        return $false
    }
    try {
        Set-Clipboard -Value $report
        Write-LabSuccess "$(@($Message).Count) Meldung(en) in die Zwischenablage kopiert."
        return $true
    }
    catch {
        Write-LabWarning "Zwischenablage nicht beschreibbar: $($_.Exception.Message)"
        return $false
    }
}

function Show-LabMessagesInteractive {
    <#
    .SYNOPSIS Zeigt das Meldungsjournal und macht es kopierbar.
    .DESCRIPTION Ohne diese Ansicht bleibt eine journalisierte Meldung fuer den
    Bediener unerreichbar, sobald der Bildschirm neu gezeichnet wurde.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Message)

    $explicit = @($Message).Count -gt 0
    while ($true) {
        $entries = if ($explicit) { @($Message) } else { @(Get-LabMessage) }
        $recent = @($entries | Select-Object -Last 200)
        $problems = @($recent | Where-Object { $_.severity -in @('Warning', 'Error') })
        $journalPath = Get-LabMessageJournalPath

        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in ($problems | Select-Object -Last 12)) {
            $items.Add((New-LabConsoleItem -Id $entry.messageId -Label ('{0}  {1}' -f $entry.messageId, $entry.message) `
                -Value ([string]$entry.code) -Data $entry))
        }
        $items.Add((New-LabConsoleItem -Id '__copyProblems' -Label 'Warnungen und Fehler in die Zwischenablage' -Shortcut 'c' `
            -Disabled:($problems.Count -eq 0) -DisabledReason 'Es liegt keine Warnung und kein Fehler vor.'))
        $items.Add((New-LabConsoleItem -Id '__copyAll' -Label 'Gesamtes Sitzungsjournal in die Zwischenablage' -Shortcut 'a' `
            -Disabled:($recent.Count -eq 0) -DisabledReason 'Das Journal ist leer.'))
        $items.Add((New-LabConsoleItem -Id '__path' -Label 'Pfad des Journals anzeigen' -Value ([string]$journalPath) -Shortcut 'd' `
            -Disabled:(-not $journalPath) -DisabledReason 'Ohne absoluten State-Root bleibt das Journal rein speicherbasiert.'))
        $items.Add((New-LabConsoleItem -Id 'back' -Label 'Zurueck' -Shortcut '0'))

        $subtitle = '{0} Meldung(en) · {1} Warnung/Fehler' -f $recent.Count, $problems.Count
        $choice = Invoke-LabConsoleMenu -ScreenId 'messages' -Title 'Meldungen dieser Sitzung' -Subtitle $subtitle -Items @($items)
        if ($choice.Status -ne 'Selected' -or [string]$choice.SelectedItem.Id -eq 'back') { return }
        switch ([string]$choice.SelectedItem.Id) {
            '__copyProblems' { $null = Copy-LabMessageReportToClipboard -Message $problems; Wait-LabConsoleAcknowledgement }
            '__copyAll' { $null = Copy-LabMessageReportToClipboard -Message $recent; Wait-LabConsoleAcknowledgement }
            '__path' { Write-LabStatus -Label 'Journal' -Value ([string]$journalPath); Wait-LabConsoleAcknowledgement }
            default {
                # Der volle Satz bleibt markierbar im Scrollback stehen, nicht nur in der Liste.
                Write-Host ''
                Write-Host (Format-LabMessageReport -Message @($choice.SelectedItem.Data))
                Write-Host ''
                Wait-LabConsoleAcknowledgement
            }
        }
    }
}

function Show-LabActionMessagesInteractive {
    <#
    .SYNOPSIS Erzwingt nach einer Aktion die Sichtbarkeit neuer Warnungen und Fehler.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Marker)

    $new = @(Get-LabMessage | Where-Object { [int]$_.sequence -gt $Marker -and $_.severity -in @('Warning', 'Error') })
    if ($new.Count -eq 0) { return }
    Write-Host ''
    Write-Host (Format-LabMessageReport -Message $new)
    Write-Host ''
    Write-LabInfo "[c] kopiert diese Meldungen, [m] oeffnet das Sitzungsjournal."
    $choice = Invoke-LabConsoleMenu -ScreenId 'action-messages' -Title 'Offene Meldungen der letzten Aktion' `
        -Subtitle ('{0} Warnung(en) oder Fehler' -f $new.Count) -Items @(
        New-LabConsoleItem -Id 'copy' -Label 'In die Zwischenablage kopieren' -Shortcut 'c'
        New-LabConsoleItem -Id 'journal' -Label 'Sitzungsjournal oeffnen' -Shortcut 'm'
        New-LabConsoleItem -Id 'back' -Label 'Weiter' -Shortcut '0'
    )
    if ($choice.Status -ne 'Selected') { return }
    switch ([string]$choice.SelectedItem.Id) {
        'copy' { $null = Copy-LabMessageReportToClipboard -Message $new; Wait-LabConsoleAcknowledgement }
        'journal' { Show-LabMessagesInteractive }
    }
}

function Show-LabCreateMenu {
    [CmdletBinding()]
    param()

    return Show-LabSubMenu -ScreenId 'create-menu' -Title 'Umgebung erstellen' -Subtitle 'Zusammenstellen, pruefen und uebergeben' -Items @(
        New-LabConsoleItem -Id BatchPlan -Label 'SQL- oder Windows-Umgebung zusammenstellen' -Value 'Einzelposition oder mehrere · Provider Auto · Pruefung vor der Uebergabe' -Shortcut 1
        New-LabConsoleItem -Id BulkSlots -Label 'Mehrere Windows-Slots gemeinsam bereitstellen' -Value 'Mengenfaehiger Composer · gemeinsame Vorlagenabhaengigkeiten' -Shortcut 2
        New-LabConsoleItem -Id back -Label 'Zurueck' -Shortcut 0
    )
}

function Show-LabCmsMenu {
    [CmdletBinding()]
    param()

    return Show-LabSubMenu -ScreenId 'cms-menu' -Title 'Zentrale Verwaltung (CMS)' -Subtitle 'Registrierte Server, Endpunkte und SSMS-Export' -Items @(
        New-LabConsoleItem -Id ConnectionCenter -Label 'Verbindungszentrale und CMS' -Value 'Endpunkte · registrierte Server · SSMS-Export' -Shortcut 1
        New-LabConsoleItem -Id back -Label 'Zurueck' -Shortcut 0
    )
}

function Show-LabInfrastructureMenu {
    [CmdletBinding()]
    param()

    $availability = try {
        if ($IsWindows) { Test-HyperVAvailable }
        else { [pscustomobject]@{ Available = $false; Message = 'Hyper-V ist nur unter Windows verfuegbar.' } }
    }
    catch { [pscustomobject]@{ Available = $false; Message = $_.Exception.Message } }
    $hyperVAvailable = $null -ne $availability -and [bool]$availability.Available
    $disabledReason = ''
    if (-not $hyperVAvailable) {
        $reason = [string]$availability.Message
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'Hyper-V ist nicht installiert oder in dieser Sitzung nicht verwendbar.' }
        $disabledReason = "$reason Abhilfe: Windows-Feature Hyper-V aktivieren und den Host neu starten."
    }
    return Show-LabSubMenu -ScreenId 'infrastructure-menu' -Title 'Infrastruktur und Medien' -Subtitle 'Hyper-V-Bestand sowie Lab_Base, Lab_Data und Testdaten' -Items @(
        New-LabConsoleItem -Id HyperVArea -Label 'Hyper-V-Infrastruktur' -Value 'OS-Vorlagen · Slots · Builds · ISO-Quellen' -Shortcut 1 `
            -Disabled:(-not $hyperVAvailable) -DisabledReason $disabledReason
        New-LabConsoleItem -Id StorageArea -Label 'Medien, Testdaten und Speicher' -Value 'Lab_Base · Lab_Data · CU-Pakete · Testdatenbibliothek' -Shortcut 2
        New-LabConsoleItem -Id back -Label 'Zurueck' -Shortcut 0
    )
}

function Show-LabMaintenanceMenu {
    [CmdletBinding()]
    param()

    return Show-LabSubMenu -ScreenId 'maintenance-menu' -Title 'Wartung und Diagnose' -Subtitle 'Read-only Pruefungen und Aufraeumbefunde' -Items @(
        New-LabConsoleItem -Id Status -Label 'System- und Providerstatus' -Value 'read-only' -Shortcut 1
        New-LabConsoleItem -Id CleanupAudit -Label 'Cleanup-Audit anzeigen' -Value 'read-only · verbliebene Ressourcen und Recovery' -Shortcut 2
        New-LabConsoleItem -Id Catalog -Label 'Katalogstatus pruefen' -Value 'Katalogdatei validieren' -Shortcut 3
        New-LabConsoleItem -Id Messages -Label 'Meldungen dieser Sitzung' -Value 'Warnungen und Fehler · kopierbar · Journalpfad' -Shortcut 4
        New-LabConsoleItem -Id back -Label 'Zurueck' -Shortcut 0
    )
}

function Show-LabSettingsMenu {
    [CmdletBinding()]
    param()

    $sevenZip = Get-Lab7ZipExecutable
    return Show-LabSubMenu -ScreenId 'settings-menu' -Title 'Einstellungen' -Subtitle 'Scheduler, Benachrichtigung und Ersteinrichtung' -Items @(
        New-LabConsoleItem -Id queue -Label 'Scheduler, Parallelitaet, Ton und Ruhemodus' -Shortcut 1
        New-LabConsoleItem -Id Setup -Label 'Ersteinrichtung fuer Lab_Base und Lab_Data' -Value 'fragt nur fehlende oder ungueltige Angaben ab' -Shortcut 2
        New-LabConsoleItem -Id Install7Zip -Label $(if ($sevenZip) { '7-Zip fuer .7z-Backups verfuegbar' } else { '7-Zip fuer .7z-Backups optional installieren' }) -Shortcut 3
        New-LabConsoleItem -Id back -Label 'Zurueck' -Shortcut 0
    )
}

function Show-LabSystemMenu {
    [CmdletBinding()]
    param()

    return Show-LabSubMenu -ScreenId 'system-menu' -Title 'Systemstatus und Einstellungen' -Subtitle 'Provider, Scheduler, Audit und Verbindungen' -Items @(
        New-LabConsoleItem -Id Status -Label 'System- und Providerstatus' -Shortcut 1
        New-LabConsoleItem -Id CleanupAudit -Label 'Cleanup-Audit anzeigen (read-only)' -Shortcut 2
        New-LabConsoleItem -Id Catalog -Label 'Katalogstatus' -Shortcut 3
        New-LabConsoleItem -Id ConnectionCenter -Label 'Connection Center' -Shortcut 4
        New-LabConsoleItem -Id queue -Label 'Scheduler, Parallelitaet, Ton und Ruhemodus' -Shortcut 5
        New-LabConsoleItem -Id back -Label 'Zurueck' -Shortcut 0
    )
}

function Invoke-LabAreaMenuInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Environment', 'HyperV', 'Storage', 'Database', 'Cms', 'Infrastructure', 'Maintenance', 'Settings', 'System')]
        [string]$Area
    )

    while ($true) {
        $action = switch ($Area) {
            'Create' { Show-LabCreateMenu }
            'Environment' { Show-LabEnvironmentMenu }
            'HyperV' { Show-LabHyperVMenu }
            'Storage' { Show-LabStorageMenu }
            'Database' { Show-LabDatabaseMenu }
            'Cms' { Show-LabCmsMenu }
            'Infrastructure' { Show-LabInfrastructureMenu }
            'Maintenance' { Show-LabMaintenanceMenu }
            'Settings' { Show-LabSettingsMenu }
            'System' { Show-LabSystemMenu }
        }
        if ([string]::IsNullOrWhiteSpace([string]$action) -or $action -eq 'back') { return }
        # Gruppen delegieren an den jeweiligen Bereich, statt Aktionen zu duplizieren.
        if ($action -eq 'HyperVArea') { Invoke-LabAreaMenuInteractive -Area HyperV; continue }
        if ($action -eq 'StorageArea') { Invoke-LabAreaMenuInteractive -Area Storage; continue }
        if ($action -eq 'Messages') { Show-LabMessagesInteractive; continue }
        $marker = Get-LabMessageJournalMarker
        try { Invoke-LabMenuAction -ActionName $action }
        catch { if (-not (Test-LabConsoleInputCancellation -InputObject $_)) { throw } }
        # Eine Warnung oder ein Fehler darf nicht vom naechsten Menueaufbau verdeckt werden.
        Show-LabActionMessagesInteractive -Marker $marker
    }
}

