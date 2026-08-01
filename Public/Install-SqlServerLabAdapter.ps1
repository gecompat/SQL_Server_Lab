function Install-SqlServerLabAdapter {
    <#
    .SYNOPSIS
        Wendet einen Project Adapter auf eine laufende Labinstanz an.
    .DESCRIPTION
        Fuehrt den gewaehlten T-SQL-Entrypoint eines validierten Adapters gegen
        die per RunId aufgeloeste Instanz aus. Ein deklarierter
        Preflight-Entrypoint laeuft zuerst. Der Aufruf hat keinen
        Lifecycle-Seiteneffekt: Container, Volumes, Ports und Run-State werden
        weder erzeugt noch veraendert; es werden ausschliesslich
        SQL-Anweisungen des Adapters ausgefuehrt. Fehler werden mit stabilen
        Statusklassen gemeldet (PROJECT_CONTENT_FAILED,
        PROJECT_ASSERTION_FAILED, PROJECT_CLEANUP_FAILED).
    .PARAMETER Path
        Adapterverzeichnis oder direkter Pfad zur adapter.json.
    .PARAMETER RunId
        RunId der provisionierten Labumgebung. Host, Port, Provider und Version
        werden aus connection-info.json aufgeloest.
    .PARAMETER InstanceId
        Instanz-ID innerhalb des Runs. Standard ist primary.
    .PARAMETER SaPassword
        SA-Passwort als SecureString.
    .PARAMETER Entrypoint
        Auszufuehrender Adapter-Entrypoint: install, update, validate oder
        cleanup. Standard ist install.
    .PARAMETER SkipPreflight
        Ueberspringt den deklarierten Preflight-Entrypoint.
    .PARAMETER StateRoot
        Optionales State-Stammverzeichnis. Ohne Angabe wird der
        Framework-Default verwendet.
    .OUTPUTS
        System.Management.Automation.PSCustomObject. Liefert Status
        (ADAPTER_APPLIED oder eine Fehlerstatusklasse), ProjectId, Entrypoint,
        RunId, InstanceId und Dauer.
    .EXAMPLE
        Install-SqlServerLabAdapter -Path '.\Adapters\Examples\synthetic-demo' -RunId $lab.RunId -SaPassword $pw

        Fuehrt Preflight und Install des synthetischen Beispieladapters gegen
        die primaere Instanz des Runs aus.
    .EXAMPLE
        Install-SqlServerLabAdapter -Path '.\Adapters\Examples\synthetic-demo' -RunId $lab.RunId -SaPassword $pw -Entrypoint validate

        Prueft eine vorhandene Installation fachlich; ein Fehler wird als
        PROJECT_ASSERTION_FAILED gemeldet.
    .NOTES
        Das Cmdlet veraendert ausschliesslich SQL-Inhalte innerhalb der
        gebundenen Instanz. Provider-Ressourcen und Run-State bleiben
        unveraendert.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunId,
        [string]$InstanceId = 'primary',
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [ValidateSet('install', 'update', 'validate', 'cleanup')]
        [string]$Entrypoint = 'install',
        [switch]$SkipPreflight,
        [string]$StateRoot
    )

    $ErrorActionPreference = 'Stop'

    $resolution = Read-LabProjectAdapter -Path $Path
    if ($resolution.Status -ne 'ADAPTER_READY' -or $resolution.Errors.Count -gt 0) {
        throw "$($resolution.Status): Adapter kann nicht angewendet werden.`n  - $($resolution.Errors -join "`n  - ")"
    }
    foreach ($warning in $resolution.Warnings) {
        Write-LabWarning $warning
    }

    if (-not $resolution.Entrypoints.Contains($Entrypoint)) {
        throw "ADAPTER_INVALID: Adapter '$($resolution.Adapter.projectId)' deklariert keinen Entrypoint '$Entrypoint'."
    }

    $runTarget = Resolve-LabAdapterRunTarget `
        -RunId $RunId `
        -InstanceId $InstanceId `
        -StateRoot $StateRoot

    $compatibility = Test-LabProjectAdapterRunCompatibility `
        -Adapter $resolution.Adapter `
        -RunTarget $runTarget `
        -InstanceVersion $runTarget.Version
    if (-not $compatibility.IsCompatible) {
        throw "ADAPTER_UNSUPPORTED_CONTRACT: $($compatibility.Errors -join '; ')"
    }

    $projectId = [string]$resolution.Adapter.projectId
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $messages = [System.Collections.Generic.List[string]]::new()

    $failureStatus = switch ($Entrypoint) {
        'validate' { 'PROJECT_ASSERTION_FAILED' }
        'cleanup'  { 'PROJECT_CLEANUP_FAILED' }
        default    { 'PROJECT_CONTENT_FAILED' }
    }

    if (-not $SkipPreflight -and $resolution.Entrypoints.Contains('preflight')) {
        Write-LabInfo "Adapter '$projectId': Preflight..."
        $preflightResult = Invoke-LabSqlScript `
            -ScriptPath $resolution.Entrypoints['preflight'] `
            -HostName $runTarget.HostName `
            -Port $runTarget.Port `
            -SaPassword $SaPassword `
            -Database $resolution.TargetDatabase `
            -KeepConnection
        if (-not $preflightResult.Success) {
            return [PSCustomObject]@{
                Status     = 'PROJECT_CONTENT_FAILED'
                Success    = $false
                ProjectId  = $projectId
                Entrypoint = 'preflight'
                RunId      = $RunId
                InstanceId = $InstanceId
                Message    = $preflightResult.Message
                Duration   = $stopwatch.Elapsed
            }
        }
        $messages.Add("Preflight erfolgreich ($($preflightResult.Batches) Batches).")
    }

    Write-LabInfo "Adapter '$projectId': Entrypoint '$Entrypoint' auf Run $RunId/$InstanceId..."
    $entrypointResult = Invoke-LabSqlScript `
        -ScriptPath $resolution.Entrypoints[$Entrypoint] `
        -HostName $runTarget.HostName `
        -Port $runTarget.Port `
        -SaPassword $SaPassword `
        -Database $resolution.TargetDatabase `
        -KeepConnection
    $stopwatch.Stop()

    if (-not $entrypointResult.Success) {
        return [PSCustomObject]@{
            Status     = $failureStatus
            Success    = $false
            ProjectId  = $projectId
            Entrypoint = $Entrypoint
            RunId      = $RunId
            InstanceId = $InstanceId
            Message    = $entrypointResult.Message
            Duration   = $stopwatch.Elapsed
        }
    }

    $messages.Add("Entrypoint '$Entrypoint' erfolgreich ($($entrypointResult.Batches) Batches).")
    Write-LabSuccess "Adapter '$projectId' angewendet: $Entrypoint ($($stopwatch.Elapsed.TotalSeconds.ToString('F1'))s)"

    return [PSCustomObject]@{
        Status     = 'ADAPTER_APPLIED'
        Success    = $true
        ProjectId  = $projectId
        Entrypoint = $Entrypoint
        RunId      = $RunId
        InstanceId = $InstanceId
        Message    = $messages -join ' '
        Duration   = $stopwatch.Elapsed
    }
}
