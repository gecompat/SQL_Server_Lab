function Invoke-LabSsisExecutionDiagnosticBrowser {
    param([Parameter(Mandatory)][string]$Json)

    $fields = @('RunId', 'InstanceId', 'ExecutionId', 'ProjectLsn', 'CatalogDatabaseGuid')
    $values = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $document = [Text.Json.JsonDocument]::Parse($Json)
    try {
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw 'SSIS_EXECUTION_DIAGNOSTIC_HTTP_INVALID'
        }
        foreach ($field in $document.RootElement.EnumerateObject()) {
            if ($field.Name -cnotin $fields -or $field.Value.ValueKind -ne [Text.Json.JsonValueKind]::String -or
                -not $values.TryAdd($field.Name, $field.Value.GetString())) {
                throw 'SSIS_EXECUTION_DIAGNOSTIC_HTTP_INVALID'
            }
        }
        if ($values.Count -ne $fields.Count) { throw 'SSIS_EXECUTION_DIAGNOSTIC_HTTP_INVALID' }
    }
    finally { $document.Dispose() }

    $parameters = @{
        RunId = Assert-LabSsisDiagnosticGuid $values['RunId']
        InstanceId = Assert-LabSsisDiagnosticInstanceId $values['InstanceId']
        ExecutionId = ConvertTo-LabSsisDiagnosticPositiveInt64 $values['ExecutionId']
        ExpectedProjectLsn = ConvertTo-LabSsisDiagnosticPositiveInt64 $values['ProjectLsn']
        ExpectedCatalogDatabaseGuid = Assert-LabSsisDiagnosticGuid $values['CatalogDatabaseGuid']
        ErrorAction = 'Stop'
    }
    $result = Get-SqlServerLabSsisExecutionDiagnostic @parameters
    [pscustomobject]@{
        Status = $result.Status
        Reason = $result.ReasonCode
        ExecutionStatus = $result.Observation.Snapshot.ObservedExecutionStatus
        Worker = $result.Observation.Worker.Status
        ErrorCodes = @($result.Observation.ErrorCodes | Where-Object { $null -ne $_ })
    }
}
