<#
.SYNOPSIS
    Erstellt interaktiv ein JSON-Manifest fuer SQL Server Lab.
.DESCRIPTION
    Liest alle Eingabefelder dynamisch aus dem Manifest-Schema, validiert Typen
    bereits bei der Eingabe und prueft den fertigen Entwurf gegen Schema,
    Kataloge und bekannte Runtime-Grenzen.
.PARAMETER Path
    Zielpfad der Manifestdatei.
.PARAMETER InputObject
    Optionaler nichtinteraktiver Manifestentwurf, beispielsweise fuer Automation.
.PARAMETER Force
    Ueberschreibt eine vorhandene Datei.
.PARAMETER PassThru
    Gibt das gespeicherte Manifestobjekt zurueck.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Nur mit PassThru wird das
    validierte und gespeicherte Manifestobjekt ausgegeben.
.EXAMPLE
    New-SqlServerLabManifest -Path '.\mein-lab.json'
.EXAMPLE
    Test-SqlServerLabManifest -Path '.\mein-lab.json'
#>
function New-SqlServerLabManifest {
    [CmdletBinding(DefaultParameterSetName = 'Interactive', SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [string]$Path = (Join-Path $PWD 'lab-manifest.json'),

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'InputObject')]
        [object]$InputObject,

        [switch]$Force,
        [switch]$PassThru
    )

    process {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $parentPath = Split-Path -Parent $fullPath
        if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
            throw "Zielverzeichnis nicht gefunden: $parentPath"
        }
        if ((Test-Path -LiteralPath $fullPath -PathType Leaf) -and -not $Force) {
            throw "Manifest existiert bereits: $fullPath. Zum Ueberschreiben -Force verwenden."
        }

        $relativeSchemaPath = [System.IO.Path]::GetRelativePath(
            $parentPath,
            (Join-Path $script:SchemasPath 'lab-manifest.schema.json')
        ).Replace([System.IO.Path]::DirectorySeparatorChar, '/')
        if ($relativeSchemaPath -notmatch '^\.') {
            $relativeSchemaPath = "./$relativeSchemaPath"
        }

        $draft = if ($PSCmdlet.ParameterSetName -eq 'Interactive') {
            Write-LabHeader 'SQL Server Lab - Manifest erstellen'
            Write-LabInfo 'Optionale Felder koennen einzeln aktiviert werden. Eingaben werden sofort typgeprueft.'
            New-LabManifestDraft -SchemaReference $relativeSchemaPath
        }
        else {
            $InputObject
        }

        $json = $draft | ConvertTo-Json -Depth 100
        $manifest = $json | ConvertFrom-Json -Depth 100
        $validation = Get-LabManifestValidationResult `
            -Manifest $manifest `
            -Json $json `
            -ManifestPath $fullPath

        foreach ($warning in $validation.Warnings) {
            Write-LabWarning $warning
        }
        if (-not $validation.IsValid) {
            foreach ($validationError in $validation.Errors) {
                Write-LabError $validationError
            }
            throw "Manifest wurde wegen $($validation.Errors.Count) Validierungsfehler(n) nicht gespeichert."
        }

        if ($PSCmdlet.ParameterSetName -eq 'Interactive' -and
            $validation.Warnings.Count -gt 0 -and
            -not (Read-LabConfirm -Prompt 'Manifest trotz Warnungen speichern?' -Default $false)) {
            Write-LabInfo 'Manifest wurde nicht gespeichert.'
            return
        }

        if ($PSCmdlet.ShouldProcess($fullPath, 'Validiertes Lab-Manifest speichern')) {
            $temporaryPath = "$fullPath.$([System.Guid]::NewGuid().ToString('N')).tmp"
            try {
                [System.IO.File]::WriteAllText(
                    $temporaryPath,
                    "$json$([Environment]::NewLine)",
                    [System.Text.UTF8Encoding]::new($false)
                )
                Move-Item -LiteralPath $temporaryPath -Destination $fullPath -Force
            }
            finally {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
            Write-LabSuccess "Manifest gespeichert: $fullPath"
        }

        if ($PassThru) {
            return $manifest
        }
    }
}

function Test-SqlServerLabManifest {
    <#
    .SYNOPSIS
        Prueft ein Lab-Manifest ohne Provisionierung.
    .DESCRIPTION
        Prueft genau eine JSON-Manifestdatei oder ein uebergebenes Manifestobjekt
        gegen das mit dem Modul ausgelieferte Schema. Danach folgen fachliche
        Pruefungen anhand der Versions- und Sample-Kataloge sowie der aktuell
        implementierten Provider- und Runtime-Grenzen.

        Die Funktion erstellt oder veraendert keine Labressourcen und schreibt
        das Manifest nicht. Schema-Defaults werden bei der Validierung nicht in
        die Eingabe eingefuegt. Effektive Runtime-Defaults werden erst beim
        spaeteren Einlesen durch New-SqlServerLab -Manifest aufgeloest.
    .PARAMETER Path
        Dateisystempfad zu genau einer vorhandenen JSON-Manifestdatei. Relative
        Pfade werden gegen das aktuelle PowerShell-Verzeichnis aufgeloest. Der
        Pfad wird literal ausgewertet; Platzhalter wie * und ? werden daher nicht
        expandiert. Verzeichnisse, URLs und mehrere Pfade werden nicht akzeptiert.
        Eine bestimmte Dateiendung ist nicht vorgeschrieben, der Inhalt muss aber
        gueltiges UTF-8-JSON sein.

        Relative lokale Pfade innerhalb des Manifests, insbesondere
        restore.source und postProvision, werden fuer die Pruefung relativ zum
        Verzeichnis dieser Manifestdatei interpretiert.
    .PARAMETER InputObject
        Manifestentwurf als Hashtable, OrderedDictionary oder PSCustomObject.
        Der Wert kann ueber die Pipeline uebergeben werden und wird vor der
        Pruefung per ConvertTo-Json und ConvertFrom-Json normalisiert.

        Da bei diesem Parametersatz keine Manifestdatei als Bezugspunkt existiert,
        werden relative lokale Pfade im Objekt gegen das aktuelle
        PowerShell-Verzeichnis aufgeloest.
    .PARAMETER Quiet
        Gibt nur Boolean zurueck: True bei einem gueltigen Manifest, andernfalls
        False. Ohne Quiet wird ein Ergebnisobjekt mit IsValid, Errors und Warnings
        ausgegeben. Der Switch ist standardmaessig ausgeschaltet.
    .INPUTS
        System.Object. Ein Manifestobjekt kann an InputObject gebunden werden.
    .OUTPUTS
        System.Management.Automation.PSCustomObject. Ohne Quiet enthaelt das
        Ergebnis IsValid (Boolean), Errors (String[]) und Warnings (String[]).

        System.Boolean. Mit Quiet wird nur IsValid zurueckgegeben.
    .EXAMPLE
        $validation = Test-SqlServerLabManifest -Path '.\mein-lab.json'
        $validation | Format-List IsValid, Errors, Warnings

        Prueft eine Datei. Relative Restore- und Skriptpfade beziehen sich auf
        das Verzeichnis von mein-lab.json.
    .EXAMPLE
        Test-SqlServerLabManifest -Path 'C:\Lab Manifeste\vergleich.json' -Quiet

        Prueft einen absoluten Pfad und liefert nur True oder False.
    .EXAMPLE
        $draft = [ordered]@{
            name = 'minimal'
            instances = @(
                [ordered]@{ id = 'primary'; version = '2025' }
            )
        }
        $draft | Test-SqlServerLabManifest

        Prueft einen Entwurf aus der Pipeline. Das Originalobjekt wird nicht um
        Schema- oder Runtime-Defaults ergaenzt.
    .NOTES
        Ein nicht vorhandener Path fuehrt zu einem terminierenden Fehler. Bei
        syntaktisch ungueltigem JSON wird dagegen ein ungueltiges Ergebnis mit
        einem Eintrag unter Errors zurueckgegeben; mit Quiet ist das Ergebnis
        False. Warnings allein setzen IsValid nicht auf False.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Path')]
        [string]$Path,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'InputObject')]
        [object]$InputObject,

        [switch]$Quiet
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'Path') {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                throw "Manifest nicht gefunden: $Path"
            }
            $fullPath = (Resolve-Path -LiteralPath $Path).Path
            $json = Get-Content -LiteralPath $fullPath -Raw -Encoding utf8
            try {
                $manifest = $json | ConvertFrom-Json -Depth 100
            }
            catch {
                $result = [PSCustomObject]@{
                    IsValid  = $false
                    Errors   = @("JSON: $($_.Exception.Message)")
                    Warnings = @()
                }
                if ($Quiet) { return $false }
                return $result
            }
        }
        else {
            $fullPath = $null
            $json = $InputObject | ConvertTo-Json -Depth 100
            $manifest = $json | ConvertFrom-Json -Depth 100
        }

        $result = Get-LabManifestValidationResult `
            -Manifest $manifest `
            -Json $json `
            -ManifestPath $fullPath

        if ($Quiet) {
            return $result.IsValid
        }
        return $result
    }
}