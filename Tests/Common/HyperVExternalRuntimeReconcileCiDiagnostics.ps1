function Get-HyperVExternalRuntimeCiFailureCode {
    <#
    .SYNOPSIS
        Classifies a captured external-runtime acceptance failure without returning its raw output.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object[]]$InputObject
    )

    $matches = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($InputObject)) {
        if ($null -eq $item) { continue }
        $candidates = if ($item -is [System.Management.Automation.ErrorRecord]) {
            @([string]$item.FullyQualifiedErrorId, [string]$item)
        }
        else {
            @([string]$item)
        }
        foreach ($candidate in $candidates) {
            foreach ($match in [regex]::Matches($candidate, '(?<![A-Z0-9_])(HYPERV_EXTERNAL_RUNTIME(?:_CI)?_[A-Z0-9_]+)(?![A-Z0-9_])')) {
                $matches.Add($match.Groups[1].Value)
            }
        }
    }
    if ($matches.Count -eq 0) { return 'UNCLASSIFIED' }
    return $matches[$matches.Count - 1]
}

function Test-HyperVExternalRuntimeCiRunnerOutputFailure {
    <#
    .SYNOPSIS
        Detects an error record captured from the private acceptance runner.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object[]]$InputObject
    )

    return @($InputObject | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count -gt 0
}

function Get-HyperVExternalRuntimeCiFailureDiagnosticLine {
    <#
    .SYNOPSIS
        Produces the sole public diagnostic line for a classified CI failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('PRIMARY', 'CLEANUP')]
        [string]$FailureKind,

        [Parameter(Mandatory)]
        [string]$FailureCode
    )

    $safeCode = if ($FailureCode -match '^(?:HYPERV_EXTERNAL_RUNTIME(?:_CI)?_[A-Z0-9_]+|UNCLASSIFIED)$') {
        $FailureCode
    }
    else {
        'UNCLASSIFIED'
    }
    return "HYPERV_EXTERNAL_RUNTIME_CI_${FailureKind}_FAILURE_CODE=$safeCode"
}
