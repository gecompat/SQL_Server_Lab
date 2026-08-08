@{
    # Quality baseline for local/static PowerShell linting.
    # Intentionally start with a conservative rule set; add additional suppressions
    # only when they are project-justified and tracked via plan/commit.
    IncludeDefaultRules = $true
    Severity = @(
        'Error'
        'Warning'
    )
    ExcludeRules = @()
}
