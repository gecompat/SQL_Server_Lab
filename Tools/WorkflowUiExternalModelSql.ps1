function Get-UiExternalModelSqlJobReceipt {
    param([Parameter(Mandatory)]$Record,[Parameter(Mandatory)][string]$ExpectedAction)

    if ($Record.Action -cne $ExpectedAction -or $Record.Job.State -ne 'Completed') {
        throw 'AI_EXTERNAL_MODEL_SQL_BROWSER_SOURCE_UNAVAILABLE'
    }
    $records = @(Receive-Job -Job $Record.Job -Keep -ErrorAction SilentlyContinue 2>$null 6>$null |
        Where-Object { $_.PSObject.Properties['UiExternalModelSqlReceipt'] })
    if ($records.Count -ne 1) { throw 'AI_EXTERNAL_MODEL_SQL_BROWSER_SOURCE_UNAVAILABLE' }
    $receipt = $records[0].UiExternalModelSqlReceipt
    $status = if ($ExpectedAction -ceq 'ReadExternalModelSqlPreflight') { 'SQL_PREFLIGHT_VERIFIED' } else { 'SQL_EXTERNAL_MODEL_APPLIED' }
    $binding = $Record.ExternalModelSqlBinding
    if ($receipt.Status -cne $status -or $receipt.SqlPlanKey -cne $binding.SqlPlan.SqlPlanKey -or
        $receipt.RunId -cne $binding.RunId -or $receipt.InstanceId -cne $binding.InstanceId -or
        $receipt.DatabaseName -cne $binding.SqlPlan.DatabaseName) {
        throw 'AI_EXTERNAL_MODEL_SQL_BROWSER_SOURCE_UNAVAILABLE'
    }
    $receipt
}

function Get-UiExternalModelSqlLifecycleRequest {
    param([string]$Body,[ValidateSet('apply','embedding','cleanup')][string]$Stage)

    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 2
    $document = [Text.Json.JsonDocument]::Parse($Body,$options)
    try {
        Assert-UiCommandJsonUnique $document.RootElement
        $expected = @(if ($Stage -ceq 'apply') { 'SourceJobId','Confirmed','CredentialSecret' } else { 'SourceJobId','Confirmed' })
        $fields = @($document.RootElement.EnumerateObject())
        if ($fields.Count -ne $expected.Count -or @($fields | Where-Object Name -CNotIn $expected).Count) {
            throw 'AI_EXTERNAL_MODEL_SQL_BROWSER_FORM_INVALID'
        }
        $source = $document.RootElement.GetProperty('SourceJobId').GetString()
        if ($source -cnotmatch '^[a-f0-9]{32}$' -or
            $document.RootElement.GetProperty('Confirmed').ValueKind -ne [Text.Json.JsonValueKind]::True) {
            throw 'AI_EXTERNAL_MODEL_SQL_BROWSER_FORM_INVALID'
        }
        $secret = $null
        if ($Stage -ceq 'apply') {
            $value = $document.RootElement.GetProperty('CredentialSecret').GetString()
            if ($value.Length -lt 1 -or $value.Length -gt 4000) { throw 'AI_EXTERNAL_MODEL_SQL_BROWSER_FORM_INVALID' }
            $secret = [SecureString]::new()
            try {
                for ($index = 0; $index -lt $value.Length; $index++) { $secret.AppendChar($value[$index]) }
                $secret.MakeReadOnly()
            } catch { $secret.Dispose(); throw }
            finally { $value = $null }
        }
        [pscustomobject]@{SourceJobId=$source;CredentialSecret=$secret}
    } finally { $document.Dispose() }
}

function Start-UiExternalModelSqlLifecycle {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Jobs,
        [Parameter(Mandatory)][ValidateSet('apply','embedding','cleanup')][string]$Stage,
        [Parameter(Mandatory)]$Request
    )

    $source = $Jobs[$Request.SourceJobId]
    if (-not $source) {
        throw 'AI_EXTERNAL_MODEL_SQL_BROWSER_SOURCE_UNAVAILABLE'
    }
    $sourceAction = if ($Stage -ceq 'apply') { 'ReadExternalModelSqlPreflight' } else { 'ApplyExternalModelSql' }
    $receipt = Get-UiExternalModelSqlJobReceipt -Record $source -ExpectedAction $sourceAction
    if ($source.ExternalModelSqlMutationSubmitted) { throw 'AI_EXTERNAL_MODEL_SQL_BROWSER_SOURCE_UNAVAILABLE' }
    $action = switch -CaseSensitive ($Stage) {
        'apply' { 'ApplyExternalModelSql' }
        'embedding' { 'ReadExternalModelSqlEmbedding' }
        'cleanup' { 'RemoveExternalModelSql' }
    }
    if (@($Jobs.Values | Where-Object {
        $_.Action -cin @('ApplyExternalModelSql','ReadExternalModelSqlEmbedding','RemoveExternalModelSql') -and
        $_.Job.State -in @('NotStarted','Running')
    }).Count) {
        throw 'AI_EXTERNAL_MODEL_SQL_BROWSER_ACTIVE'
    }
    $binding = $source.ExternalModelSqlBinding
    $parameters = @{SqlPlan=$binding.SqlPlan;RunId=$binding.RunId;InstanceId=$binding.InstanceId}
    $secret = $null
    $started = $false
    try {
        if ($Stage -ceq 'apply') {
            $parameters.PreflightReceipt = $receipt
            $secret = $Request.CredentialSecret.Copy()
            $secret.MakeReadOnly()
            $parameters.CredentialSecret = $secret
        } else { $parameters.ApplyReceipt = $receipt }
        # A lost acknowledgement requires inspection of the original operation.
        if ($Stage -cne 'embedding') { $source.ExternalModelSqlMutationSubmitted = $true }
        $record = Start-UiWorkflowJob -Action $action -Parameters $parameters
        $started = $true
        $Jobs[$record.Id] = $record
        $record
    } finally {
        if (-not $started -and $secret) { $secret.Dispose() }
    }
}
