function New-LabGuidedExternalModelPlan {
    param([hashtable]$Values)

    $parameters = $Values.Clone()
    $receiptJson = $parameters.GatewayBindingJson
    $parameters.Remove('GatewayBindingJson')
    if ($receiptJson) {
        if ($receiptJson.Length -gt 4096) { throw 'AI_EXTERNAL_MODEL_PLAN_FORM_INVALID' }
        $parameters.GatewayBinding = $receiptJson | ConvertFrom-Json -Depth 4 -ErrorAction Stop
        if ($parameters.GatewayBinding -isnot [pscustomobject]) { throw 'AI_EXTERNAL_MODEL_PLAN_FORM_INVALID' }
    }
    $plan = Get-SqlServerLabAiExternalModelPlan @parameters
    if ($plan.Status -ceq 'BLOCKED') {
        # A rejected location can contain user input that must not appear in a plan result.
        return [pscustomobject]@{Status='BLOCKED';Plan=$null;Blockers=@($plan.Blockers)}
    }
    if ($plan.Status -cne 'NOT_PROBED') { throw 'AI_EXTERNAL_MODEL_PLAN_FORM_INVALID' }
    $canonical = Resolve-LabAiExternalModelPlan -Plan $plan
    [pscustomobject]@{Status='NOT_PROBED';Plan=$canonical;Blockers=@()}
}

function Invoke-LabGuidedExternalModelPlanHttp {
    param([string]$Body)

    if (-not $Body -or [Text.Encoding]::UTF8.GetByteCount($Body) -gt 16384) { throw 'AI_EXTERNAL_MODEL_PLAN_FORM_INVALID' }
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 2
    $document = [Text.Json.JsonDocument]::Parse($Body,$options)
    try {
        $fields = @{Dimension=[Text.Json.JsonValueKind]::Number}
        foreach ($field in @('Backend','Accelerator','Location','ExternalModelName','RuntimeModel','ModelSha256',
            'RuntimeSha256','ServerCertificateSha256','TlsMode','InputProfile','GatewayBindingJson')) {
            $fields[$field] = [Text.Json.JsonValueKind]::String
        }
        $form = ConvertFrom-LabAiSharedGatewayFormObject -Object $document.RootElement -Fields $fields
        $dimension = 0
        if (-not $form.Dimension.TryGetInt32([ref]$dimension)) { throw 'AI_EXTERNAL_MODEL_PLAN_FORM_INVALID' }
        $values = @{Dimension=$dimension}
        foreach ($field in $fields.Keys) {
            if ($field -cne 'Dimension') { $values[$field] = $form[$field].GetString() }
        }
        New-LabGuidedExternalModelPlan -Values $values
    } finally { $document.Dispose() }
}

function Invoke-LabGuidedExternalModelPlanInteractive {
    try {
        $values = @{}
        $choices = [ordered]@{
            Backend=@('LlamaCppOpenVino','OpenVinoModelServer','LlamaCppRocm','LlamaCppCuda','LlamaCppSnapdragonOpenCl','LlamaCppSnapdragonHexagon')
            Accelerator=@('CPU','GPU','NPU')
            TlsMode=@('Direct','Gateway')
            InputProfile=@('raw','nomic-search','snowflake-search')
        }
        foreach ($name in $choices.Keys) {
            $items = @(foreach ($option in $choices[$name]) { New-LabConsoleItem -Id $option -Label $option -Data $option })
            $choice = Select-LabConsoleDataItem -ScreenId ("external-model-plan-"+$name.ToLowerInvariant()) -Title $name -Items $items
            if (-not $choice) { return }
            $values[$name] = $choice
        }
        $labels = [ordered]@{
            Location='Lokale HTTPS-Adresse des Embedding-Endpunkts'
            ExternalModelName='SQL-Name für das External Model'
            RuntimeModel='Modellname des lokalen Dienstes'
            Dimension='Embedding-Dimension (1 bis 1998)'
            ModelSha256='SHA-256 der Modelldatei'
            RuntimeSha256='SHA-256 der Serverruntime'
            ServerCertificateSha256='SHA-256 des Serverzertifikats'
        }
        if ($values.Backend -ceq 'OpenVinoModelServer') { $labels.GatewayBindingJson='OVMS-Gateway-Bindung (JSON in einer Zeile)' }
        foreach ($name in $labels.Keys) {
            $inputValue = Read-LabConsoleTextInput -Prompt $labels[$name] -MaskInput:($name -cin @('GatewayBindingJson','Location'))
            if ($inputValue.Status -cne 'Confirmed') { return }
            $values[$name] = $inputValue.Value
        }
        $dimension = 0
        if (-not [int]::TryParse([string]$values.Dimension,[ref]$dimension)) { throw 'AI_EXTERNAL_MODEL_PLAN_FORM_INVALID' }
        $values.Dimension = $dimension
        $result = New-LabGuidedExternalModelPlan -Values $values
        if ($result.Status -ceq 'BLOCKED') {
            Write-LabWarning ("Plan blockiert · " + ($result.Blockers -join ' · '))
        } else {
            Write-LabInfo ($result.Plan | ConvertTo-Json -Depth 8)
            if (Read-LabConfirm -Prompt 'Zur separaten Bestätigung der Endpunktprüfung weitergehen?' -Default $false) {
                Invoke-LabGuidedExternalModelEndpointInteractive -PreparedPlan $result.Plan
                return
            }
        }
    } catch [Management.Automation.PipelineStoppedException] { throw }
    catch { Write-LabWarning 'External-Model-Plan unbestätigt. Prüfe Felder und gegebenenfalls die Gateway-Bindung.' }
    $null = Wait-LabConsoleAcknowledgement
}

function ConvertFrom-LabGuidedExternalModelReceipt {
    param([Text.Json.JsonElement]$Element)

    if ($Element.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'AI_EXTERNAL_MODEL_SQL_PLAN_FORM_INVALID' }
    $timestamp = $Element.GetProperty('VerifiedAtUtc')
    if ($timestamp.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'AI_EXTERNAL_MODEL_SQL_PLAN_FORM_INVALID' }
    $receipt = $Element.GetRawText() | ConvertFrom-Json -Depth 6 -ErrorAction Stop
    # The receipt hash includes the exact serialized timestamp, including fractional seconds.
    $receipt.VerifiedAtUtc = $timestamp.GetString()
    return $receipt
}

function Invoke-LabGuidedExternalModelSqlPlanHttp {
    param([string]$Body)

    if (-not $Body -or [Text.Encoding]::UTF8.GetByteCount($Body) -gt 32768) { throw 'AI_EXTERNAL_MODEL_SQL_PLAN_FORM_INVALID' }
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 8
    $document = [Text.Json.JsonDocument]::Parse($Body,$options)
    try {
        $fields = @{Plan=[Text.Json.JsonValueKind]::Object;EndpointReceipt=[Text.Json.JsonValueKind]::Object
            DatabaseName=[Text.Json.JsonValueKind]::String;MaxEndpointAgeSeconds=[Text.Json.JsonValueKind]::Number}
        $values = ConvertFrom-LabAiSharedGatewayFormObject -Object $document.RootElement -Fields $fields
        $age = 0
        if (-not $values.MaxEndpointAgeSeconds.TryGetInt32([ref]$age)) { throw 'AI_EXTERNAL_MODEL_SQL_PLAN_FORM_INVALID' }
        $plan = $values.Plan.GetRawText() | ConvertFrom-Json -Depth 6 -ErrorAction Stop
        $receipt = ConvertFrom-LabGuidedExternalModelReceipt -Element $values.EndpointReceipt
        Get-SqlServerLabAiExternalModelSqlPlan -Plan $plan -EndpointReceipt $receipt -DatabaseName $values.DatabaseName.GetString() -MaxEndpointAgeSeconds $age
    } finally { $document.Dispose() }
}

function Invoke-LabGuidedExternalModelSqlPlanInteractive {
    param($PreparedPlan,$PreparedReceipt)

    try {
        if (-not $PreparedPlan -or -not $PreparedReceipt) {
            $planPath = Read-LabConsoleTextInput -Prompt 'Absoluter lokaler Pfad zum External-Model-Plan (JSON)' -MaskInput
            if ($planPath.Status -cne 'Confirmed') { return }
            $receiptPath = Read-LabConsoleTextInput -Prompt 'Absoluter lokaler Pfad zur passenden HTTPS-Endpunktquittung (JSON)' -MaskInput
            if ($receiptPath.Status -cne 'Confirmed') { return }
            $PreparedPlan = (Read-LabGuidedExternalModelFile -Path $planPath.Value) | ConvertFrom-Json -Depth 6 -ErrorAction Stop
            $options = [Text.Json.JsonDocumentOptions]::new()
            $options.MaxDepth = 6
            $document = [Text.Json.JsonDocument]::Parse((Read-LabGuidedExternalModelFile -Path $receiptPath.Value),$options)
            try { $PreparedReceipt = ConvertFrom-LabGuidedExternalModelReceipt -Element $document.RootElement }
            finally { $document.Dispose() }
        }
        $database = Read-LabConsoleTextInput -Prompt 'Ziel-Datenbankname für die reine Vorschau'
        if ($database.Status -cne 'Confirmed') { return }
        $age = Read-LabConsoleTextInput -Prompt 'Maximales Quittungsalter in Sekunden (30 bis 3600)' -Default '300'
        if ($age.Status -cne 'Confirmed') { return }
        $ageSeconds = 0
        if (-not [int]::TryParse([string]$age.Value, [ref]$ageSeconds)) { throw 'AI_EXTERNAL_MODEL_SQL_PLAN_FORM_INVALID' }
        $sqlPlan = Get-SqlServerLabAiExternalModelSqlPlan -Plan $PreparedPlan -EndpointReceipt $PreparedReceipt -DatabaseName $database.Value -MaxEndpointAgeSeconds $ageSeconds
        Write-LabInfo ($sqlPlan | ConvertTo-Json -Depth 8)
        Write-LabInfo 'SQL-Objekte sind geplant. SQL-Bindung, Rechte und Datenbank-Master-Key werden separat geprüft.'
    } catch [Management.Automation.PipelineStoppedException] { throw }
    catch {
        if ($_.Exception.Message -ceq 'AI_EXTERNAL_MODEL_ENDPOINT_RECEIPT_EXPIRED') {
            Write-LabWarning 'Die Endpunktquittung ist abgelaufen. Prüfe den Endpunkt erneut.'
        } else { Write-LabWarning 'SQL-Plan unbestätigt. Prüfe Datenbankname, External-Model-Plan und zugehörige Endpunktquittung.' }
    }
    $null = Wait-LabConsoleAcknowledgement
}
