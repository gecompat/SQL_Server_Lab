function New-LabSqlGuestEvaluationEvidenceReadResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('VALID', 'EVIDENCE_MISSING', 'EVIDENCE_INVALID')][string]$Status,
        [AllowNull()][string]$RunId,
        [AllowNull()][string]$InstanceId,
        [AllowNull()][string]$ArtifactId,
        [AllowNull()]$Evidence
    )

    [PSCustomObject]@{
        Status = $Status
        RunId = $RunId
        InstanceId = $InstanceId
        ArtifactId = $ArtifactId
        Evidence = $Evidence
    }
}

function ConvertFrom-LabSqlGuestEvaluationEvidenceUtcTimestamp {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text) -or
        $text -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$') {
        return $null
    }

    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse(
            $text,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)) {
        return $null
    }
    return $parsed.ToUniversalTime()
}

function Test-LabSqlGuestEvaluationEvidenceSemantics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)]$Instance
    )

    $observedAt = ConvertFrom-LabSqlGuestEvaluationEvidenceUtcTimestamp -Value $Evidence.ObservedAt
    $freshUntil = ConvertFrom-LabSqlGuestEvaluationEvidenceUtcTimestamp -Value $Evidence.EvidenceFreshUntil
    if ($null -eq $observedAt -or $null -eq $freshUntil -or $freshUntil -lt $observedAt -or
        ($freshUntil - $observedAt).TotalHours -gt 168) {
        return $false
    }

    $expiresAt = $null
    if ($null -ne $Evidence.EvaluationExpiresAt) {
        $expiresAt = ConvertFrom-LabSqlGuestEvaluationEvidenceUtcTimestamp -Value $Evidence.EvaluationExpiresAt
        if ($null -eq $expiresAt) { return $false }
    }

    if ([string]$Evidence.EvidenceId -eq [string]$Evidence.PreviousEvidenceId) { return $false }
    if ([string]$Evidence.RunId -ne [string]$Run.runId -or
        [string]$Evidence.ScopeId -ne [string]$Run.scopeId -or
        [string]$Evidence.InstanceId -ne [string]$Instance.id -or
        [string]$Evidence.VmId -ne [string]$Instance.vmId -or
        [string]$Evidence.ImageArtifactId -ne [string]$Run.metadata.imageArtifactId -or
        [string]$Evidence.ImageArtifactId -ne [string]$Instance.imageArtifactId -or
        [string]$Evidence.Provider -ne 'hyperv') {
        return $false
    }

    $readiness = $Instance.sqlReadiness
    if ($readiness) {
        if ([string]$readiness.status -ne 'SQL_READY_RUN' -or
            [string]$Evidence.SqlInstanceName -ne [string]$readiness.instanceName -or
            [int]$Evidence.SqlMajorVersion -ne [int]$readiness.majorVersion -or
            [string]$Evidence.SqlEdition -ne [string]$readiness.edition) {
            return $false
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Instance.sqlEdition) -and
        [string]$Evidence.SqlEdition -ne [string]$Instance.sqlEdition) {
        return $false
    }

    $classification = [string]$Evidence.LicenseClassification
    $source = [string]$Evidence.DeadlineSource
    $observation = [string]$Evidence.ObservationStatus
    if ($classification -eq 'EVALUATION' -and $source -eq 'SQL_GUEST_OBSERVED' -and $observation -eq 'CAPTURED') {
        return $null -ne $expiresAt
    }
    if ($classification -in @('EVALUATION', 'NOT_EVALUATION') -and
        $source -eq 'SQL_GUEST_NO_DEADLINE' -and $observation -eq 'NO_DEADLINE') {
        return $null -eq $expiresAt
    }
    if ($classification -in @('EVALUATION', 'UNKNOWN') -and
        $source -eq 'SQL_GUEST_UNAVAILABLE' -and $observation -in @('UNAVAILABLE', 'FAILED')) {
        return $null -eq $expiresAt
    }
    return $false
}

function Get-LabSqlGuestEvaluationEvidence {
    <#
    .SYNOPSIS
        Liest einen gebundenen SQL-Gast-Evaluations-Receipt ohne Gast- oder Runtimezugriff.
    .DESCRIPTION
        Akzeptiert ausschließlich `SqlServerLab.SqlGuestEvaluationEvidence/1.0`
        unterhalb des runlokalen State-Roots. Fehlende, mehrdeutige oder
        inkonsistente Bindungen werden fail-closed als Evidence-Status
        zurückgegeben; Details aus der lokalen Quelle werden nicht projiziert.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $runStatePath = Join-Path $runDirectory 'run-state.json'
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    $evidencePath = Join-Path $runDirectory 'sql-guest-evaluation-evidence.json'
    foreach ($path in @($runStatePath, $connectionPath, $evidencePath)) {
        $safety = Test-LabPathWithinRoot -Root $StateRoot -Path $path
        if (-not $safety.Valid) {
            return New-LabSqlGuestEvaluationEvidenceReadResult -Status EVIDENCE_INVALID -RunId $RunId
        }
    }
    if (-not (Test-Path -LiteralPath $runStatePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) {
        return New-LabSqlGuestEvaluationEvidenceReadResult -Status EVIDENCE_INVALID -RunId $RunId
    }

    try {
        $run = Get-Content -LiteralPath $runStatePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    }
    catch {
        return New-LabSqlGuestEvaluationEvidenceReadResult -Status EVIDENCE_INVALID -RunId $RunId
    }

    if ([string]$run.runId -ne $RunId -or [string]$run.state -notin @('RUNNING', 'STOPPED') -or
        [string]$run.metadata.workflowKind -ne 'hyperv-lab' -or
        [string]::IsNullOrWhiteSpace([string]$run.scopeId) -or
        [string]::IsNullOrWhiteSpace([string]$run.metadata.imageArtifactId)) {
        return New-LabSqlGuestEvaluationEvidenceReadResult -Status EVIDENCE_INVALID -RunId $RunId
    }

    $instances = @($connection.instances | Where-Object {
        [string]$_.provider -eq 'hyperv' -and [string]$_.workload -eq 'sql'
    })
    if ($instances.Count -ne 1) {
        return New-LabSqlGuestEvaluationEvidenceReadResult -Status EVIDENCE_INVALID -RunId ([string]$run.runId) -ArtifactId ([string]$run.metadata.imageArtifactId)
    }
    $instance = $instances[0]
    if ([string]::IsNullOrWhiteSpace([string]$instance.id) -or
        [string]::IsNullOrWhiteSpace([string]$instance.vmId) -or
        [string]$instance.imageArtifactId -ne [string]$run.metadata.imageArtifactId) {
        return New-LabSqlGuestEvaluationEvidenceReadResult -Status EVIDENCE_INVALID -RunId ([string]$run.runId) -InstanceId ([string]$instance.id) -ArtifactId ([string]$run.metadata.imageArtifactId)
    }

    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
        return New-LabSqlGuestEvaluationEvidenceReadResult -Status EVIDENCE_MISSING -RunId ([string]$run.runId) -InstanceId ([string]$instance.id) -ArtifactId ([string]$run.metadata.imageArtifactId)
    }

    try {
        $rawEvidence = Get-Content -LiteralPath $evidencePath -Raw -Encoding utf8
        if (@([regex]::Matches($rawEvidence, '"EvidenceId"\s*:')).Count -ne 1) { throw 'SQL_GUEST_EVALUATION_EVIDENCE_ID_DUPLICATE' }
        $evidence = $rawEvidence | ConvertFrom-Json -Depth 20
        $schemaPath = Join-Path $script:SchemasPath 'sql-guest-evaluation-evidence.schema.json'
        if (-not ($rawEvidence | Test-Json -SchemaFile $schemaPath -ErrorAction Stop)) { throw 'SQL_GUEST_EVALUATION_EVIDENCE_SCHEMA_INVALID' }
        if (-not (Test-LabSqlGuestEvaluationEvidenceSemantics -Evidence $evidence -Run $run -Instance $instance)) {
            throw 'SQL_GUEST_EVALUATION_EVIDENCE_SEMANTICS_INVALID'
        }
    }
    catch {
        return New-LabSqlGuestEvaluationEvidenceReadResult -Status EVIDENCE_INVALID -RunId ([string]$run.runId) -InstanceId ([string]$instance.id) -ArtifactId ([string]$run.metadata.imageArtifactId)
    }

    return New-LabSqlGuestEvaluationEvidenceReadResult -Status VALID -RunId ([string]$run.runId) -InstanceId ([string]$instance.id) -ArtifactId ([string]$run.metadata.imageArtifactId) -Evidence $evidence
}

function ConvertTo-LabSqlGuestEvaluationWatchItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ReaderResult,
        [Parameter(Mandatory)][ValidateSet('RUNNING', 'STOPPED')][string]$RegistrationState,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][int]$WarningDaysRemaining,
        [Parameter(Mandatory)][int]$CriticalDaysRemaining
    )

    $status = 'UNKNOWN'
    $evidenceStatus = [string]$ReaderResult.Status
    $deadlineSource = $evidenceStatus
    $evaluationExpiresAt = $null
    $daysRemaining = $null
    $refreshAction = 'CAPTURE_REQUIRED'
    $refreshStatus = 'REFRESH_BLOCKED'

    if ($ReaderResult.Status -eq 'VALID') {
        $evidence = $ReaderResult.Evidence
        $deadlineSource = [string]$evidence.DeadlineSource
        if ([string]$evidence.LicenseClassification -eq 'NOT_EVALUATION') {
            $evidenceStatus = 'NOT_EVALUATION'
            $status = 'NOT_APPLICABLE'
            $refreshAction = 'NO_ACTION'
            $refreshStatus = 'NOT_APPLICABLE'
        }
        else {
            $freshUntil = ConvertFrom-LabSqlGuestEvaluationEvidenceUtcTimestamp -Value $evidence.EvidenceFreshUntil
            if ($freshUntil -lt $Now) {
                $evidenceStatus = 'EVIDENCE_STALE'
                $refreshAction = 'CAPTURE_REQUIRED'
            }
            elseif ([string]$evidence.LicenseClassification -ne 'EVALUATION' -or
                [string]$evidence.DeadlineSource -ne 'SQL_GUEST_OBSERVED') {
                $evidenceStatus = 'DEADLINE_UNKNOWN'
                $refreshAction = 'CAPTURE_REQUIRED'
            }
            else {
                $expiresAt = ConvertFrom-LabSqlGuestEvaluationEvidenceUtcTimestamp -Value $evidence.EvaluationExpiresAt
                $evaluationExpiresAt = $expiresAt.ToString('o')
                $daysRemaining = [Math]::Max(0, [int][Math]::Ceiling(($expiresAt - $Now).TotalDays))
                $evidenceStatus = 'CURRENT'
                if ($expiresAt -le $Now) {
                    $status = 'EXPIRED'
                    $refreshAction = 'MANUAL_REBUILD_REQUIRED'
                }
                elseif ($daysRemaining -le $CriticalDaysRemaining) {
                    $status = 'CRITICAL'
                    $refreshAction = 'MANUAL_REBUILD_RECOMMENDED'
                }
                elseif ($daysRemaining -le $WarningDaysRemaining) {
                    $status = 'WARNING'
                    $refreshAction = 'MANUAL_REBUILD_RECOMMENDED'
                }
                else {
                    $status = 'OK'
                    $refreshAction = 'NO_ACTION'
                    $refreshStatus = 'NOT_REQUIRED'
                }
            }
        }
    }

    $eventId = $null
    if ($status -notin @('OK', 'NOT_APPLICABLE')) {
        $fingerprint = "{0}|{1}|SqlServer|{2}|{3}|{4}" -f $ReaderResult.RunId, $ReaderResult.InstanceId, $evidenceStatus, $status, $evaluationExpiresAt
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fingerprint))).ToLowerInvariant()
        $eventId = "evaluation-$hash"
    }

    return [PSCustomObject]@{
        RunId = [string]$ReaderResult.RunId
        InstanceId = [string]$ReaderResult.InstanceId
        ArtifactId = [string]$ReaderResult.ArtifactId
        Component = 'SqlServer'
        RegistrationState = $RegistrationState
        DeadlineSource = $deadlineSource
        EvidenceStatus = $evidenceStatus
        Status = $status
        EvaluationExpiresAt = $evaluationExpiresAt
        DaysRemaining = $daysRemaining
        RefreshAction = $refreshAction
        RefreshStatus = $refreshStatus
        EventId = $eventId
    }
}
