# Lokaler Diagnose-Handoff für genau eine Instanz

Der Readiness-Skill, der Betriebsskill und der SQL Server Lab Operator benutzen
für einen ausdrücklich angeforderten Diagnose-Handoff die vorhandene öffentliche
`Get-SqlServerLabDiagnosticBundle`-API. Dies erweitert keine Rollen- oder
Ausführungsberechtigung. Ein Bootstrapfehler sammelt nicht automatisch ein Bundle.

Vor dem Rezept das reale Modul aus dem durch AGENTS.md bestimmten Repository
importieren und seine öffentliche Hilfe lesen. `$repositoryRoot` bezeichnet nur
dieses Repository. Run-ID, exakte Instanz und registrierter DataRoot müssen aus
der ausdrücklich ausgewählten Benutzeroperation stammen; weder Namen raten noch
State-/Connection-/Secretdateien lesen. Fehlende Angaben bleiben gesperrt.
`$diagnosticHandoffRequested` ist nur bei einer tatsächlich gewünschten lokalen
Übergabe true. `$includeProviderReadiness` ist standardmäßig false; true setzt
zusätzlich eine bewusst gewünschte Providerprobe voraus. Die Diagnosekategorie
führt keine gleichnamige Create-/Start-/Stop-/Remove-Aktion aus.

## Kanonisches ausführbares Rezept

Das Ergebnis bleibt ausschließlich im aktuellen erlaubten lokalen Benutzerkontext.
Kein Export, Upload, Clipboard, Issue, Dateischreiben oder Modell-Dispatch gehört
zum Rezept. Übertragungen brauchen ihre eigene vorhandene Nutzerautorität.

<!-- OPERATOR_DIAGNOSTIC_RECIPE:BEGIN -->
```powershell
& {
    param($Requested,$RunId,$InstanceId,$DataRoot,$ExpectedProvider,$Operation,$IncludeProviderReadiness,$RepositoryRoot)
    if($Requested -isnot [bool] -or -not $Requested){return 'DIAGNOSTIC_HANDOFF_NOT_REQUESTED'}
    if($RunId -isnot [string] -or [string]::IsNullOrWhiteSpace($RunId) -or
        $InstanceId -isnot [string] -or [string]::IsNullOrWhiteSpace($InstanceId) -or
        $DataRoot -isnot [string] -or [string]::IsNullOrWhiteSpace($DataRoot) -or
        $IncludeProviderReadiness -isnot [bool]){return 'DIAGNOSTIC_HANDOFF_TARGET_REQUIRED'}
    try {
        $bundle=Get-SqlServerLabDiagnosticBundle -RunId $RunId -InstanceId $InstanceId -DataRoot $DataRoot `
            -Provider $ExpectedProvider -Operation $Operation -SkipReadiness:(-not $IncludeProviderReadiness) `
            2>$null 3>$null 4>$null 5>$null 6>$null
        $json=ConvertTo-Json -InputObject $bundle -Depth 16 -Compress -ErrorAction Stop
        $schema=Join-Path $RepositoryRoot 'Schemas/diagnostic-bundle.schema.json'
        if($json.Length -gt 32768 -or -not (Test-Json -Json $json -SchemaFile $schema -ErrorAction Stop 2>$null 3>$null 4>$null 5>$null 6>$null)){
            return 'DIAGNOSTIC_HANDOFF_UNVERIFIABLE'
        }
        # Only the closed API DTO is returned; input locators and exceptions stay local.
        $json
    }catch{return 'DIAGNOSTIC_HANDOFF_UNVERIFIABLE'}
} $diagnosticHandoffRequested $selectedRunId $selectedInstanceId $selectedDataRoot $expectedProvider $diagnosticOperation $includeProviderReadiness $repositoryRoot
```
<!-- OPERATOR_DIAGNOSTIC_RECIPE:END -->

## Bedeutung für den bestehenden Operator-Handoff

Die JSON-Ausgabe ist die einzige Evidencequelle dieses Pfads. Freie Eingabewerte,
ältere Readiness-Rohtexte und ungeprüftes eingefügtes JSON werden nicht ergänzt.
Der bestehende Handoff mit Reproduziert, Geaendert, Validiert, Offen und Pull Request
bleibt erhalten. Er nennt bekannte Abschnittstatus und feste Reason-/Checkcodes,
keine Namen, IDs, Endpunkte, Pfade, SQL, Logs oder Secrets. Unter Geaendert steht
weiterhin Keine Codeänderung durch den Operator. Eine beobachtete Metadatenbindung
ist keine Reproduktion eines Produktfehlers; fehlende Ursache bleibt unbekannt.

`OBSERVED` betrifft die Metadatenbindung. `History` und `Cleanup` sind historisch;
`REMOVED` oder `COMPLETED` beweist keine aktuelle Restfreiheit. `NOT_RECORDED`
schließt Recovery nicht aus. Readiness betrifft den aktuellen Clientkontext,
keine historische Zielruntime. `READY` beweist keine SQL-Bereitschaft und erlaubt
keine Mutation. `SqlProbe=NOT_EXECUTED`, `ClientReadiness=UNSUPPORTED`,
`MutationAllowed=false` und ausgeschlossene Spezialjournale bleiben sichtbar.
Der öffentliche Kataloghash ist keine private State- oder Reproduktionsidentität.

Der [API-Vertrag](../Architecture/DIAGNOSTIC_BUNDLE.md) einschließlich vorhandener
Ownership-, Größen-, Zeit- und Privacygrenzen bleibt unverändert. Die Skillwahl
bleibt wie bisher möglich; nur die tatsächliche Handoffaktion benötigt ihren
konkreten Nutzerauftrag. Ein Test des Rezepts beweist keine Skillloader- oder
Modellausführung. Eigenständige Entwicklung, Shellausweitung und automatische
Übermittlung gehören nicht zu diesem Slice.
