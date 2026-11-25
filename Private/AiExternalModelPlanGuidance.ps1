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
