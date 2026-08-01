<#
.SYNOPSIS
    Aufloesung und Validierung von Project Adaptern (Vertragsversion 0.1).
.DESCRIPTION
    Liest adapter.json eines konsumierenden Projekts, validiert gegen
    Schemas/project-adapter.schema.json und erzwingt die Sicherheitsregeln des
    Projektintegrationsvertrags: nur relative T-SQL-Entrypoints innerhalb des
    Adapter-Roots, keine Pfad-Traversierung, keine Reparse Points, Ablehnung
    unbekannter Major-Vertragsversionen. Ergebnisse verwenden stabile
    Statusklassen (ADAPTER_READY, ADAPTER_INVALID,
    ADAPTER_UNSUPPORTED_CONTRACT, PROJECT_ARTIFACT_SCOPE_VIOLATION).
#>

function Get-LabProjectAdapterSchemaPath {
    [CmdletBinding()]
    param()

    $schemaPath = Join-Path $script:SchemasPath 'project-adapter.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        throw "Adapter-Schema nicht gefunden: $schemaPath"
    }
    return $schemaPath
}

function Read-LabProjectAdapter {
    <#
    .SYNOPSIS
        Loest einen Project Adapter read-only in einen strukturierten Vertrag auf.
    .DESCRIPTION
        Fuehrt keine SQL- oder Providerzugriffe aus. Validierungsfehler werden
        als strukturierte Errors mit Statusklasse zurueckgegeben, nicht als
        Exception.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $status = 'ADAPTER_READY'

    $definitionPath = if (Test-Path -LiteralPath $Path -PathType Container) {
        Join-Path $Path 'adapter.json'
    }
    else {
        $Path
    }

    if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) {
        return [PSCustomObject]@{
            Status   = 'ADAPTER_INVALID'
            Errors   = @("Adapterdefinition nicht gefunden: $definitionPath")
            Warnings = @()
            Adapter  = $null
            Root     = $null
        }
    }

    $definitionPath = (Resolve-Path -LiteralPath $definitionPath).Path
    $adapterRoot = Split-Path -Parent $definitionPath
    $raw = Get-Content -LiteralPath $definitionPath -Raw -Encoding utf8

    try {
        $adapter = $raw | ConvertFrom-Json -Depth 30
    }
    catch {
        return [PSCustomObject]@{
            Status   = 'ADAPTER_INVALID'
            Errors   = @("Adapter-JSON ungueltig: $($_.Exception.Message)")
            Warnings = @()
            Adapter  = $null
            Root     = $adapterRoot
        }
    }

    $schemaErrors = @()
    $schemaValid = Test-Json `
        -Json $raw `
        -SchemaFile (Get-LabProjectAdapterSchemaPath) `
        -ErrorAction SilentlyContinue `
        -ErrorVariable schemaErrors
    if (-not $schemaValid) {
        foreach ($schemaError in @($schemaErrors | ForEach-Object { $_.Exception.Message } | Select-Object -Unique)) {
            $errors.Add("Schema: $schemaError")
        }
        $status = 'ADAPTER_INVALID'
    }

    if ($adapter.adapterContractVersion) {
        $majorText = ([string]$adapter.adapterContractVersion).Split('.', 2)[0]
        $majorVersion = 0
        if (-not [int]::TryParse($majorText, [ref]$majorVersion)) {
            # Werte, die dem Schema-Pattern ^\d+\.\d+$ genuegen, aber Int32
            # ueberlaufen (z. B. '99999999999.0'), erreichen diesen Zweig ohne
            # Schemafehler. Ohne eigene Meldung bliebe Errors leer und der
            # Aufrufer meldete eine Ablehnung ohne Begruendung.
            $errors.Add("Adapter-Vertragsversion '$($adapter.adapterContractVersion)' konnte nicht als Major-Version interpretiert werden.")
            if ($status -eq 'ADAPTER_READY') {
                $status = 'ADAPTER_INVALID'
            }
        }
        elseif ($majorVersion -ne 0) {
            $errors.Add("Adapter-Vertragsversion '$($adapter.adapterContractVersion)' wird nicht unterstuetzt; der Runtimepfad akzeptiert Major-Version 0.")
            $status = 'ADAPTER_UNSUPPORTED_CONTRACT'
        }
    }

    $coreVersion = [version]$script:LabVersion
    $coreSupported = $false
    $declaredCoreVersions = @($adapter.supportedLabCoreVersions | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    foreach ($supportedCore in $declaredCoreVersions) {
        $parts = ([string]$supportedCore).Split('.', 2)
        $coreMajor = 0
        if ($parts.Count -lt 2 -or -not [int]::TryParse($parts[0], [ref]$coreMajor)) {
            # Formatfehler meldet bereits die Schemapruefung.
            continue
        }
        if ($coreMajor -ne $coreVersion.Major) {
            continue
        }
        $coreMinor = 0
        if ($parts[1] -eq 'x' -or ([int]::TryParse($parts[1], [ref]$coreMinor) -and $coreMinor -eq $coreVersion.Minor)) {
            $coreSupported = $true
            break
        }
    }
    if (-not $coreSupported -and $declaredCoreVersions.Count -gt 0) {
        $errors.Add("Adapter unterstuetzt die Lab-Core-Version $($script:LabVersion) nicht (deklariert: $($declaredCoreVersions -join ', ')).")
        if ($status -eq 'ADAPTER_READY') {
            $status = 'ADAPTER_UNSUPPORTED_CONTRACT'
        }
    }

    $resolvedEntrypoints = [ordered]@{}
    foreach ($entrypointProperty in @($adapter.entrypoints.PSObject.Properties)) {
        $entrypointName = $entrypointProperty.Name
        $relativeValue = [string]$entrypointProperty.Value
        if ([string]::IsNullOrWhiteSpace($relativeValue)) {
            continue
        }

        if ([System.IO.Path]::IsPathRooted($relativeValue) -or
            ($relativeValue -split '[\\/]') -contains '..') {
            $errors.Add("Entrypoint '$entrypointName' verletzt die Pfadgrenze des Adapter-Roots: $relativeValue")
            $status = 'PROJECT_ARTIFACT_SCOPE_VIOLATION'
            continue
        }

        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $adapterRoot $relativeValue))
        $boundary = Test-LabPathWithinRoot -Root $adapterRoot -Path $fullPath
        if (-not $boundary.Valid) {
            $errors.Add("Entrypoint '$entrypointName' verletzt die Pfadgrenze des Adapter-Roots ($($boundary.Reason)): $relativeValue")
            $status = 'PROJECT_ARTIFACT_SCOPE_VIOLATION'
            continue
        }

        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            $errors.Add("Entrypoint '$entrypointName' nicht gefunden: $relativeValue")
            if ($status -eq 'ADAPTER_READY') {
                $status = 'ADAPTER_INVALID'
            }
            continue
        }

        $resolvedEntrypoints[$entrypointName] = $fullPath
    }

    foreach ($reservedField in @('sqlPackageCatalogs', 'defaultPackageRefs')) {
        if ($null -ne $adapter.$reservedField -and @($adapter.$reservedField).Count -gt 0) {
            $warnings.Add("$reservedField ist fuer den Projektintegrationsvertrag reserviert und wird noch nicht ausgewertet.")
        }
    }

    return [PSCustomObject]@{
        Status         = $status
        Errors         = @($errors)
        Warnings       = @($warnings)
        Adapter        = $adapter
        Root           = $adapterRoot
        DefinitionPath = $definitionPath
        Entrypoints    = $resolvedEntrypoints
        TargetDatabase = if ($adapter.targetDatabase) { [string]$adapter.targetDatabase } else { 'master' }
    }
}

function Test-LabProjectAdapterRunCompatibility {
    <#
    .SYNOPSIS
        Prueft Adapteranforderungen gegen eine konkrete Run-Instanz read-only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Adapter,
        [Parameter(Mandatory)]$RunTarget,
        [Parameter(Mandatory)][AllowEmptyString()][string]$InstanceVersion
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    $declaredSqlVersions = @($Adapter.supportedSqlVersions | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $baseVersion = ([string]$InstanceVersion -split '-', 2)[0]
    if ($declaredSqlVersions.Count -gt 0) {
        if ([string]::IsNullOrWhiteSpace($baseVersion)) {
            $errors.Add("Instanzversion ist unbekannt; der Adapter deklariert unterstuetzte Versionen ($($declaredSqlVersions -join ', ')).")
        }
        elseif ($declaredSqlVersions -notcontains $baseVersion) {
            $errors.Add("Instanzversion $InstanceVersion wird vom Adapter nicht unterstuetzt (deklariert: $($declaredSqlVersions -join ', ')).")
        }
    }

    foreach ($capability in @($Adapter.requiredCapabilities | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        switch ($capability) {
            'sqlcmd' {
                if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
                    $errors.Add("Capability 'sqlcmd' ist auf diesem Host nicht verfuegbar.")
                }
            }
            'container-linux' {
                if ([string]$RunTarget.Provider -notin @('docker', 'podman')) {
                    $errors.Add("Capability 'container-linux' erfordert eine Docker- oder Podman-Instanz; gefunden: $($RunTarget.Provider).")
                }
            }
            default {
                $errors.Add("Capability '$capability' wird vom Runtimepfad nicht unterstuetzt.")
            }
        }
    }

    return [PSCustomObject]@{
        IsCompatible = $errors.Count -eq 0
        Errors       = @($errors)
    }
}
