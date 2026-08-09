@{
    # Quality baseline for local/static PowerShell linting.
    # Intentionally start with a conservative rule set; add additional suppressions
    # only when they are project-justified and tracked via plan/commit.
    IncludeDefaultRules = $true
    Severity = @(
        'Error'
        'Warning'
    )
    # Existing security-rule debt. The analyzer runner fails when a rule exceeds
    # its recorded count, so new findings cannot silently enter the repository.
    ErrorBaseline = @{
        PSAvoidUsingConvertToSecureStringWithPlainText = 21
        PSAvoidUsingUsernameAndPasswordParams = 1
        PSAvoidUsingComputerNameHardcoded = 2
    }
    ExcludeRules = @()
}
