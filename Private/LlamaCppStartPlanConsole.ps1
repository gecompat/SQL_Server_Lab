# Guided preview only. Input values stay in this call; no session or execute token.
function Select-LabLlamaStartPlanValue {
    param([string]$Title,[string[]]$Allowed)
    $items=@($Allowed | ForEach-Object { New-LabConsoleItem -Id $_ -Label $_ })
    $choice=Invoke-LabConsoleMenu -ScreenId 'llama-start-plan-choice' -Title $Title -Subtitle 'Nur Vorschau. Esc: Abbruch.' -Items $items
    if ($choice.Status -ne 'Selected') { return $null }
    $matched=@($Allowed | Where-Object { $_ -ceq [string]$choice.SelectedItem.Id })
    if ($matched.Count -ne 1) { throw 'LLAMA_START_PLAN_CONSOLE_INPUT_INVALID' }
    $matched[0]
}

function Read-LabLlamaStartPlanNumber {
    param([string]$Prompt,[int]$Minimum,[int]$Maximum,[string]$Default='')
    $inputResult=Read-LabConsoleTextInput -Prompt $Prompt -Default $Default
    if ($inputResult.Status -ne 'Confirmed') { return $null }
    $value=0
    if ([string]$inputResult.Value -cnotmatch '^[0-9]{1,5}$' -or
        -not [int]::TryParse([string]$inputResult.Value,[ref]$value) -or $value -lt $Minimum -or $value -gt $Maximum) {
        throw 'LLAMA_START_PLAN_CONSOLE_INPUT_INVALID'
    }
    $value
}

function Assert-LabLlamaStartPlanConsoleResult {
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][hashtable]$Arguments)
    $fixed=@{Mode='PLAN_ONLY';Status='BLOCKED';RuntimeEvidence='FILES_ONLY';ModelFormat='GGUF';InputObservation='METADATA_STABLE_NOT_CAS';DeviceReadiness='NOT_CHECKED';PortAvailability='NOT_CHECKED';EmbeddingReadiness='NOT_CHECKED';TlsReadiness='NOT_CHECKED';PrivateKeyMatch='NOT_CHECKED';SanTrust='NOT_CHECKED';SqlReadiness='NOT_CHECKED'}
    $numeric=@('Dimension','Port','StartTimeoutSeconds','LeaseSeconds','ContextSize')
    $enums=@('Backend','Accelerator','Pooling')
    $expected=@($fixed.Keys)+$numeric+$enums+@('Contract','Actions','ExecutionSupported','MutationAllowed','Blockers','NextSteps')
    if ($Plan -isnot [pscustomobject] -or @(Compare-Object ($expected|Sort-Object) ($Plan.PSObject.Properties.Name|Sort-Object)).Count) { throw 'LLAMA_START_PLAN_CONSOLE_RESULT_INVALID' }
    if ($Plan.Contract -isnot [pscustomobject] -or
        @(Compare-Object @('Name','Version') @($Plan.Contract.PSObject.Properties.Name|Sort-Object)).Count -or
        $Plan.Contract.Name -isnot [string] -or $Plan.Contract.Name -cne 'SqlServerLab.LlamaCppStartPlan' -or
        $Plan.Contract.Version -isnot [string] -or $Plan.Contract.Version -cne '1.0') { throw 'LLAMA_START_PLAN_CONSOLE_RESULT_INVALID' }
    foreach ($name in $fixed.Keys) {
        if ($Plan.$name -isnot [string] -or $Plan.$name -cne $fixed[$name]) { throw 'LLAMA_START_PLAN_CONSOLE_RESULT_INVALID' }
    }
    foreach ($name in $enums) {
        if ($Plan.$name -isnot [string] -or $Plan.$name -cne $Arguments[$name]) { throw 'LLAMA_START_PLAN_CONSOLE_RESULT_INVALID' }
    }
    foreach ($name in $numeric) {
        if ($Plan.$name -isnot [int] -or $Plan.$name -ne $Arguments[$name]) { throw 'LLAMA_START_PLAN_CONSOLE_RESULT_INVALID' }
    }
    if ($Plan.Actions -isnot [array] -or $Plan.Actions.Count -ne 0 -or
        $Plan.ExecutionSupported -isnot [bool] -or $Plan.ExecutionSupported -or
        $Plan.MutationAllowed -isnot [bool] -or $Plan.MutationAllowed) { throw 'LLAMA_START_PLAN_CONSOLE_RESULT_INVALID' }
    $arrays=@{
        Blockers=@('LIVE_READINESS_NOT_CHECKED','TLS_AND_SECRETS_NOT_SUPPLIED','SQL_EMBEDDING_NOT_CHECKED')
        NextSteps=@('SELECT_EXPLICIT_START_INPUTS','VALIDATE_TLS_AND_DEVICE_READINESS_SEPARATELY','USE_EXISTING_START_WITH_FRESH_INPUT_VALIDATION')
    }
    foreach ($name in $arrays.Keys) {
        if ($Plan.$name -isnot [array] -or $Plan.$name.Count -ne $arrays[$name].Count) { throw 'LLAMA_START_PLAN_CONSOLE_RESULT_INVALID' }
        for ($i=0;$i -lt $arrays[$name].Count;$i++) {
            if ($Plan.$name[$i] -isnot [string] -or $Plan.$name[$i] -cne $arrays[$name][$i]) { throw 'LLAMA_START_PLAN_CONSOLE_RESULT_INVALID' }
        }
    }
}

function Invoke-LabLlamaCppStartPlanInteractive {
    [CmdletBinding()]
    param()
    try {
        Write-LabInfo 'llama.cpp für SQL-Embeddings: reine Dateivorschau. Keine Runtime, Geräte-, Port-, TLS- oder SQL-Prüfung.'
        $arguments=@{}
        # Masked fallback uses Ctrl+C, not the unmasked "0" cancellation convention.
        foreach ($field in @(@{Name='RuntimeDirectory';Prompt='Explizites lokales Runtimeverzeichnis (max. 4096 Zeichen)'},@{Name='ModelPath';Prompt='Explizite lokale GGUF-Datei (max. 4096 Zeichen)'})) {
            $inputResult=Read-LabConsoleTextInput -Prompt $field.Prompt -MaskInput
            if ($inputResult.Status -ne 'Confirmed') { return }
            if ($inputResult.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($inputResult.Value) -or $inputResult.Value.Length -gt 4096) { throw 'LLAMA_START_PLAN_CONSOLE_INPUT_INVALID' }
            $arguments[$field.Name]=$inputResult.Value
        }
        foreach ($field in @(@{Name='Backend';Title='Backend ausdrücklich wählen';Values=@('LlamaCppCuda','LlamaCppOpenVino')},@{Name='Accelerator';Title='Gewünschter Accelerator (nicht geprüft)';Values=@('CPU','GPU','NPU')},@{Name='Pooling';Title='Gewünschtes Pooling (nicht geprüft)';Values=@('mean','cls','last')})) {
            $value=Select-LabLlamaStartPlanValue -Title $field.Title -Allowed $field.Values
            if ($null -eq $value) { return }
            $arguments[$field.Name]=$value
        }
        if ($arguments.Backend -ceq 'LlamaCppCuda' -and $arguments.Accelerator -ceq 'NPU') { throw 'LLAMA_START_PLAN_ACCELERATOR_UNSUPPORTED' }
        foreach ($field in @(
            @{Name='Dimension';Prompt='Gewünschte Dimension: 1 bis 1998 (nicht geprüft)';Min=1;Max=1998;Default=''},
            @{Name='Port';Prompt='Gewünschter Port: 1024 bis 65535 (nicht geprüft)';Min=1024;Max=65535;Default=''},
            @{Name='StartTimeoutSeconds';Prompt='Vorgesehenes Startbudget: 1 bis 600 Sekunden';Min=1;Max=600;Default='120'},
            @{Name='LeaseSeconds';Prompt='Vorgesehene Lease: 30 bis 3600 Sekunden, größer als Startbudget';Min=30;Max=3600;Default='900'},
            @{Name='ContextSize';Prompt='Gewünschtes Kontextbudget: 32 bis 8192';Min=32;Max=8192;Default='512'}
        )) {
            $value=Read-LabLlamaStartPlanNumber -Prompt $field.Prompt -Minimum $field.Min -Maximum $field.Max -Default $field.Default
            if ($null -eq $value) { return }
            $arguments[$field.Name]=$value
        }
        if ($arguments.LeaseSeconds -le $arguments.StartTimeoutSeconds) { throw 'LLAMA_START_PLAN_LEASE_INVALID' }
        $choice=Invoke-LabConsoleMenu -ScreenId 'llama-start-plan-preview' -Title 'llama.cpp: reine Startvorschau' -Subtitle 'Pfade gesetzt; noch keine Dateien gelesen. Vorschau bleibt PLAN_ONLY/BLOCKED.' -Items @(
            New-LabConsoleItem -Id preview -Label 'Vorschau anzeigen (nur Dateien lesen)'
            New-LabConsoleItem -Id back -Label 'Zurück / Abbrechen'
        )
        if ($choice.Status -ne 'Selected' -or $choice.SelectedItem.Id -ceq 'back') { return }
        if ($choice.SelectedItem.Id -cne 'preview') { throw 'LLAMA_START_PLAN_CONSOLE_INPUT_INVALID' }
        $results=@(Get-SqlServerLabLlamaCppStartPlan @arguments)
        if ($results.Count -ne 1) { throw 'LLAMA_START_PLAN_CONSOLE_RESULT_INVALID' }
        $plan=$results[0]
        Assert-LabLlamaStartPlanConsoleResult -Plan $plan -Arguments $arguments
        Write-LabInfo 'PLAN_ONLY/BLOCKED · Actions: 0 · Ausführung: nein · Mutation: nein.'
        Write-LabInfo ("Backend: {0} · Accelerator: {1} · Dimension: {2} · Pooling: {3} · Port: {4}" -f $plan.Backend,$plan.Accelerator,$plan.Dimension,$plan.Pooling,$plan.Port)
        Write-LabInfo 'Runtime: FILES_ONLY · Modellheader: GGUF · Metadaten stabil, kein CAS- oder Kompatibilitätsnachweis.'
        Write-LabInfo 'Geräte, Port, Embedding, TLS, Keymatching, SAN/Trust und SQL: NOT_CHECKED.'
        Write-LabInfo 'Ein späterer Start benötigt eigene vollständige Eingaben und frische Validierung. Hier wird nichts gespeichert oder gestartet.'
        $null=Wait-LabConsoleAcknowledgement
    } catch [Management.Automation.PipelineStoppedException] { throw }
    catch {
        $message=switch -CaseSensitive ([string]$_.Exception.Message) {
            'LLAMA_START_PLAN_CONSOLE_INPUT_INVALID' { 'Eingabe ungültig. Feste Auswahl und angezeigte Wertebereiche verwenden.' }
            'LLAMA_START_PLAN_ACCELERATOR_UNSUPPORTED' { 'CUDA mit NPU ist für diese Vorschau ausgeschlossen.' }
            'LLAMA_START_PLAN_LEASE_INVALID' { 'Die Lease muss größer als das Startbudget sein.' }
            'LLAMA_START_PLAN_INPUT_DRIFT' { 'Dateimetadaten haben sich geändert. Eingaben neu wählen und erneut vorprüfen.' }
            'LLAMA_START_PLAN_REPARSE_REJECTED' { 'Reparse-Pfade sind für diese Vorschau ausgeschlossen.' }
            'LLAMA_START_PLAN_RUNTIME_MISMATCH' { 'Die explizite Installation passt nicht eindeutig zum gewählten Backend.' }
            'LLAMA_START_PLAN_GGUF_REQUIRED' { 'Eine reguläre Datei mit vier GGUF-Headerbytes ist erforderlich.' }
            'LLAMA_START_PLAN_DIRECTORY_LIMIT' { 'Die Runtimewurzel überschreitet 16 direkte Unterordner.' }
            'LLAMA_START_PLAN_FILE_LIMIT' { 'Ein betrachtetes Verzeichnis überschreitet 256 Dateien.' }
            'LLAMA_START_PLAN_PATH_INVALID' { 'Explizite lokale absolute Dateipfade sind erforderlich.' }
            'LLAMA_START_PLAN_FILE_INVALID' { 'Runtimeverzeichnis und reguläre Modelldatei sind erforderlich.' }
            default { 'Vorschau nicht bestätigt. Eingaben und Dateien prüfen; es wurde nichts gestartet.' }
        }
        Write-LabWarning $message
        $null=Wait-LabConsoleAcknowledgement
    }
}
