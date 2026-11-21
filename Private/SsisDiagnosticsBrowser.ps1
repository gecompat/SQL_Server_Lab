function Read-LabSsisDiagnosticBrowserFields {
    param(
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][string[]]$Fields,
        [string]$BooleanField
    )
    $values = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $document = [Text.Json.JsonDocument]::Parse($Json)
    try {
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw 'SSIS_DIAGNOSTIC_HTTP_INVALID'
        }
        foreach ($field in $document.RootElement.EnumerateObject()) {
            if ($field.Name -cnotin $Fields -or $values.ContainsKey($field.Name)) {
                throw 'SSIS_DIAGNOSTIC_HTTP_INVALID'
            }
            if ($BooleanField -and $field.Name -ceq $BooleanField) {
                if ($field.Value.ValueKind -notin @([Text.Json.JsonValueKind]::True, [Text.Json.JsonValueKind]::False)) {
                    throw 'SSIS_DIAGNOSTIC_HTTP_INVALID'
                }
                $values.Add($field.Name, $field.Value.GetBoolean())
            }
            else {
                if ($field.Value.ValueKind -ne [Text.Json.JsonValueKind]::String) {
                    throw 'SSIS_DIAGNOSTIC_HTTP_INVALID'
                }
                $values.Add($field.Name, $field.Value.GetString())
            }
        }
        if ($values.Count -ne $Fields.Count) { throw 'SSIS_DIAGNOSTIC_HTTP_INVALID' }
    }
    finally { $document.Dispose() }
    $values
}

function Invoke-LabSsisExecutionDiagnosticBrowser {
    param([Parameter(Mandatory)][string]$Json)
    $values = Read-LabSsisDiagnosticBrowserFields -Json $Json -Fields @('RunId', 'InstanceId', 'ExecutionId', 'ProjectLsn', 'CatalogDatabaseGuid')
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

function Invoke-LabSsisPackageDiagnosticBrowser {
    param([Parameter(Mandatory)][string]$Json)

    $values = Read-LabSsisDiagnosticBrowserFields -Json $Json -Fields @('RunId', 'InstanceId', 'PackagePath', 'PackageName', 'ExpectedSha256', 'TrustConfirmed') -BooleanField 'TrustConfirmed'
    if (-not $values['TrustConfirmed'] -or $values['ExpectedSha256'] -cnotmatch '^[a-fA-F0-9]{64}$' -or
        -not [IO.Path]::IsPathFullyQualified($values['PackagePath'])) {
        throw 'SSIS_DIAGNOSTIC_HTTP_INVALID'
    }
    $parameters = @{
        RunId = Assert-LabSsisDiagnosticGuid $values['RunId']
        InstanceId = Assert-LabSsisDiagnosticInstanceId $values['InstanceId']
        ExpectedSha256 = $values['ExpectedSha256']
        ErrorAction = 'Stop'
    }
    switch ([IO.Path]::GetExtension($values['PackagePath']).ToLowerInvariant()) {
        '.dtsx' {
            if ($values['PackageName']) { throw 'SSIS_DIAGNOSTIC_HTTP_INVALID' }
            $parameters.PackagePath = $values['PackagePath']
        }
        '.ispac' {
            if ($values['PackageName'] -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\.dtsx$') {
                throw 'SSIS_DIAGNOSTIC_HTTP_INVALID'
            }
            $parameters.IspacPath = $values['PackagePath']
            $parameters.PackageName = $values['PackageName']
        }
        default { throw 'SSIS_DIAGNOSTIC_HTTP_INVALID' }
    }

    $result = Get-SqlServerLabSsisPackageDiagnostic @parameters
    [pscustomobject]@{
        Status = $result.Status
        LoadStatus = $result.Observation.LoadStatus
        EventCodes = @($result.Observation.Events | Where-Object { $null -ne $_ } | ForEach-Object { $_.Code })
    }
}
