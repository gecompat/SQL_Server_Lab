<#
.SYNOPSIS
    Privater Entscheidungs- und Persistenzvertrag fuer den Erstellungs-Preflight.
.DESCRIPTION
    Messwerte bleiben im lokalen Run. Die read-only Projektion gibt nur feste
    Statuswerte aus und veraendert weder Messungen noch den Desired-Snapshot.
#>

function Get-LabResourceAssessmentStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Details)

    $statuses = @($Details | ForEach-Object { [string]$_.Status })
    if ($statuses.Count -eq 0 -or @($statuses | Where-Object {
        $_ -notin @('RESOURCE_OK', 'RESOURCE_WARNING', 'RESOURCE_INSUFFICIENT_OVERRIDABLE', 'RESOURCE_HARD_BLOCK')
    }).Count -gt 0) { throw 'RESOURCE_ASSESSMENT_STATUS_INVALID' }
    foreach ($status in @('RESOURCE_HARD_BLOCK', 'RESOURCE_INSUFFICIENT_OVERRIDABLE', 'RESOURCE_WARNING', 'RESOURCE_OK')) {
        if ($statuses -contains $status) { return $status }
    }
}

function New-LabResourceAssessmentRecord {
    [CmdletBinding()]
    param(
        $Assessment,
        [switch]$SkipAssessment,
        [switch]$AllowResourceOvercommit
    )

    $execution = 'SKIPPED'
    $status = 'NOT_EXECUTED'
    $allowed = $true
    $reason = 'ASSESSMENT_SKIPPED_EXPLICITLY'
    $snapshot = $null
    if ($SkipAssessment) {
        if ($null -ne $Assessment) { throw 'RESOURCE_ASSESSMENT_SKIP_WITH_MEASUREMENTS_INVALID' }
    }
    else {
        if ($null -eq $Assessment) { throw 'RESOURCE_ASSESSMENT_REQUIRED' }
        $status = Get-LabResourceAssessmentStatus -Details @($Assessment.Details)
        if ([string]$Assessment.Status -cne $status) { throw 'RESOURCE_ASSESSMENT_AGGREGATE_INVALID' }
        $execution = 'EXECUTED'
        $reason = 'ASSESSMENT_ACCEPTED'
        if ($status -eq 'RESOURCE_HARD_BLOCK') {
            $allowed = $false
            $reason = 'RESOURCE_HARD_BLOCK'
        }
        elseif ($status -eq 'RESOURCE_INSUFFICIENT_OVERRIDABLE') {
            if ($AllowResourceOvercommit) {
                $execution = 'OVERRIDDEN'
                $reason = 'RESOURCE_OVERCOMMIT_EXPLICITLY_ALLOWED'
            }
            else {
                $allowed = $false
                $reason = 'RESOURCE_OVERCOMMIT_REQUIRES_OPT_IN'
            }
        }
        # Eine unabhängige Momentaufnahme verhindert spätere Änderungen am
        # Messobjekt durch einen Aufrufer. Keine Umdeutung der Detailstatuses.
        $snapshot = $Assessment | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    }
    return [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.ResourceAssessmentRecord/1.0'
        RecordedAt = Get-LabTimestamp
        Execution = $execution
        Status = $status
        Allowed = $allowed
        ReasonCode = $reason
        AllowResourceOvercommit = [bool]$AllowResourceOvercommit
        Assessment = $snapshot
    }
}

function Assert-LabResourceAssessmentRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)

    $json = $Record | ConvertTo-Json -Depth 30 -Compress
    $schemaPath = Join-Path $script:SchemasPath 'resource-assessment-record.schema.json'
    if (-not (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'RESOURCE_ASSESSMENT_RECORD_INVALID'
    }
    $expected = New-LabResourceAssessmentRecord -Assessment $Record.Assessment `
        -SkipAssessment:([string]$Record.Execution -eq 'SKIPPED') `
        -AllowResourceOvercommit:([bool]$Record.AllowResourceOvercommit)
    foreach ($field in @('Execution', 'Status', 'Allowed', 'ReasonCode')) {
        if ($Record.$field -cne $expected.$field) { throw 'RESOURCE_ASSESSMENT_RECORD_INCONSISTENT' }
    }
}

function Assert-LabResourceAssessmentAllowed {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)

    Assert-LabResourceAssessmentRecord -Record $Record
    if (-not $Record.Allowed) { throw "Resource Assessment blockiert: $($Record.ReasonCode)" }
}

function Invoke-LabResourceAssessmentPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Instances,
        [Parameter(Mandatory)][string[]]$Provider,
        [switch]$SkipAssessment,
        [switch]$AllowResourceOvercommit
    )

    $assessment = $null
    if (-not $SkipAssessment) {
        Write-LabInfo 'Resource Assessment...'
        $assessment = Test-SqlServerLabPrerequisite -Instances $Instances -Provider $Provider
        foreach ($detail in $assessment.Details) {
            $color = switch ($detail.Status) {
                'RESOURCE_OK' { 'Green' }
                'RESOURCE_WARNING' { 'Yellow' }
                default { 'Red' }
            }
            Write-LabStatus -Label $detail.Category -Value "$($detail.Status): $($detail.Message)" -Color $color
        }
    }
    $record = New-LabResourceAssessmentRecord -Assessment $assessment `
        -SkipAssessment:$SkipAssessment -AllowResourceOvercommit:$AllowResourceOvercommit
    Assert-LabResourceAssessmentAllowed -Record $record
    return $record
}

function Get-LabResourceAssessmentSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run)

    $summary = [PSCustomObject]@{
        RecordStatus = 'NOT_RECORDED_LEGACY'
        Execution = $null
        Status = $null
        Allowed = $null
        ReasonCode = $null
    }
    $hasRecord = if ($Run.metadata -is [System.Collections.IDictionary]) {
        $Run.metadata.Contains('resourceAssessment')
    }
    else {
        $null -ne $Run.metadata -and $null -ne $Run.metadata.PSObject.Properties['resourceAssessment']
    }
    if (-not $hasRecord) { return $summary }
    try {
        $record = $Run.metadata.resourceAssessment
        Assert-LabResourceAssessmentRecord -Record $record
        $summary.RecordStatus = 'RECORDED'
        $summary.Execution = [string]$record.Execution
        $summary.Status = [string]$record.Status
        $summary.Allowed = [bool]$record.Allowed
        $summary.ReasonCode = [string]$record.ReasonCode
    }
    catch {
        # Auch manipulierte Legacy-/Local-State-Werte und Rohfehler gelangen
        # nicht in die oeffentliche, hostwertfreie Ansicht.
        $summary.RecordStatus = 'INVALID_RECORD'
    }
    return $summary
}
