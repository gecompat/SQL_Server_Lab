<#
.SYNOPSIS
    Gemeinsames PASS/FAIL-Reporting fuer die statischen und Integrations-Checks.
.DESCRIPTION
    Wird per Dot-Sourcing in ein Check-Skript geladen, nachdem dieses die
    Skript-Variablen $passed (int) und $failures ([List[string]]) definiert hat.
    Die Funktion schreibt in genau diese Variablen im Skript-Scope des
    aufrufenden Skripts, sodass dessen Ergebnis-/Exit-Auswertung unveraendert
    bleibt.
#>

function Add-CheckResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Success,
        [string]$Message
    )

    if ($Success) {
        $script:passed++
        Write-Host "  PASS  $Name" -ForegroundColor Green
        return
    }

    $failure = if ($Message) { "$Name - $Message" } else { $Name }
    $script:failures.Add($failure)
    Write-Host "  FAIL  $failure" -ForegroundColor Red
}
