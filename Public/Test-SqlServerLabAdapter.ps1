function Test-SqlServerLabAdapter {
    <#
    .SYNOPSIS
        Prueft einen Project Adapter ohne SQL- oder Providerzugriff.
    .DESCRIPTION
        Liest adapter.json, validiert gegen Schemas/project-adapter.schema.json
        und erzwingt die Sicherheitsregeln des Adaptervertrags: nur relative
        T-SQL-Entrypoints innerhalb des Adapter-Roots, keine Pfad-Traversierung,
        keine Reparse Points, Ablehnung unbekannter Major-Vertragsversionen.
        Optional werden die Anforderungen gegen eine konkrete Run-Instanz
        geprueft. Der Aufruf mutiert nichts.
    .PARAMETER Path
        Adapterverzeichnis oder direkter Pfad zur adapter.json.
    .PARAMETER RunId
        Optionale RunId einer provisionierten Umgebung. Bei Angabe werden
        SQL-Version und Capabilities der Zielinstanz zusaetzlich geprueft.
    .PARAMETER InstanceId
        Instanz-ID innerhalb des Runs. Standard ist primary.
    .PARAMETER StateRoot
        Optionales State-Stammverzeichnis. Ohne Angabe wird der
        Framework-Default verwendet.
    .OUTPUTS
        System.Management.Automation.PSCustomObject. Liefert Status
        (ADAPTER_READY, ADAPTER_INVALID, ADAPTER_UNSUPPORTED_CONTRACT,
        PROJECT_ARTIFACT_SCOPE_VIOLATION), Errors, Warnings und den
        aufgeloesten Adaptervertrag.
    .EXAMPLE
        Test-SqlServerLabAdapter -Path '.\Adapters\Examples\synthetic-demo'

        Prueft den synthetischen Beispieladapter gegen Schema und Pfadregeln.
    .EXAMPLE
        Test-SqlServerLabAdapter -Path '.\Adapters\Examples\synthetic-demo' -RunId $lab.RunId

        Prueft zusaetzlich, ob die Zielinstanz des Runs die deklarierten
        SQL-Versionen und Capabilities erfuellt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$RunId,
        [string]$InstanceId = 'primary',
        [string]$StateRoot
    )

    $ErrorActionPreference = 'Stop'
    $resolution = Read-LabProjectAdapter -Path $Path

    $errors = [System.Collections.Generic.List[string]]::new()
    $errors.AddRange([string[]]@($resolution.Errors))
    $status = $resolution.Status

    if ($RunId -and $resolution.Adapter) {
        $runTarget = Resolve-LabAdapterRunTarget `
            -RunId $RunId `
            -InstanceId $InstanceId `
            -StateRoot $StateRoot
        $compatibility = Test-LabProjectAdapterRunCompatibility `
            -Adapter $resolution.Adapter `
            -RunTarget $runTarget `
            -InstanceVersion $runTarget.Version
        if (-not $compatibility.IsCompatible) {
            $errors.AddRange([string[]]@($compatibility.Errors))
            if ($status -eq 'ADAPTER_READY') {
                $status = 'ADAPTER_UNSUPPORTED_CONTRACT'
            }
        }
    }

    return [PSCustomObject]@{
        Status      = $status
        IsReady     = ($status -eq 'ADAPTER_READY' -and $errors.Count -eq 0)
        ProjectId   = if ($resolution.Adapter) { [string]$resolution.Adapter.projectId } else { $null }
        Errors      = @($errors)
        Warnings    = @($resolution.Warnings)
        Adapter     = $resolution.Adapter
        Root        = $resolution.Root
        Entrypoints = $resolution.Entrypoints
    }
}
