# Read-only Diagnosebundle

`Get-SqlServerLabDiagnosticBundle` liefert `SqlServerLab.DiagnosticBundle/1.0`
mit Ergebnisversion `1.0` für genau einen ausdrücklich angeforderten modernen
Run und eine Instanz. Das geschlossene
[Schema](../../Schemas/diagnostic-bundle.schema.json) ist der Ausgabeumfang.
Der Befehl schreibt keine Dateien und exportiert oder versendet kein Bundle.

```powershell
Get-SqlServerLabDiagnosticBundle -RunId $runId -InstanceId primary `
    -DataRoot $dataRoot -Operation Inspect

# Ausschließlich historische Metadaten, ohne Providerprobe:
Get-SqlServerLabDiagnosticBundle -RunId $runId -InstanceId primary `
    -DataRoot $dataRoot -Operation Inspect -SkipReadiness
```

## Bindung und Grenzen

`RunId`, `InstanceId` und `DataRoot` sind erforderliche Eingabewerte; fehlende
oder ungültige Werte liefern eine geschlossene `BLOCKED`-Antwort ohne Echo der
Eingabe. `Provider` ist eine optionale Erwartung, kein Auto-Detect. `Operation`
akzeptiert ausschließlich `Inspect`, `Validate`, `Create`, `Start`, `Stop`,
`Remove` oder `PrepareImage` und beschreibt den Diagnoseanlass. Kein dieser
Werte führt die bezeichnete Operation aus.

Der interne Reader liest ausschließlich feste, begrenzte Metadaten unter
`DataRoot`: den modernen Controller-Marker, dessen Storage-Katalog sowie
`State/runs/<RunId>/run-state.json`, den exakten Scope-Marker und optional den
Cleanupplan und die rückgebundene Workflow-Operation. Root, Controller,
registrierte Location und Volume-Verweis müssen übereinstimmen. Run, Scope,
Sollinstanz und Provider-Teilruns werden gemeinsam aus einem Run-Snapshot
validiert. Persistente Runs benötigen zusätzlich dieselbe persistierte
DataRoot-Bindung. Der Marker-Eigentümername ist kein Ownership-Nachweis.

Ein vollständig gebundener `INITIALIZING`-Run kann historischen Sollzustand
liefern, auch wenn noch keine Runtimeinstanz besteht. Fehlende oder veraltete
Bindungen werden weder ergänzt noch migriert. Freie StateRoots, Legacy-Roots,
Netzwerkpfade, Traversierung, Reparse-Pfade und nicht registrierte Roots sind
ausgeschlossen. Der Storage-Katalog des angeforderten Roots wird gelesen;
globale Storage-Konfiguration und fremde Runs werden nicht inventarisiert.
Dies ist lokale Metadatenkonsistenz, keine kryptographische Vertrauens- oder
Live-Runtimeprüfung gegen einen Angreifer mit Schreibrechten auf diese Dateien.

## Abschnitte und Bedeutung

| Abschnitt | Beobachtung und Grenze |
|---|---|
| `Request` | Feste Operationskategorie und Einzelzieltyp; keine Eingabewerte |
| `Binding` | Provider, katalogisierte SQL-Version, OS-Klasse, Persistenz und Erstellungsmodus |
| `History` | Persistierter Run-State, Fehleranzahl und expliziter Recoverybedarf; keine freien Fehlertexte |
| `Cleanup` | Gebundener historischer Planstatus und Schrittanzahlen; keine Aussage über aktuelle Runtime-Reste |
| `Operation` | Exakte bidirektional rückgebundene Workflow-Operation mit Status, Schrittanzahl und Cleanupwunsch |
| `Readiness` | Optionaler, isolierter Provider-Bootstrap; keine SQL- oder Zielprüfung |
| `Capabilities` | Feste Grenzen einschließlich `MutationAllowed=false` |
| `SpecializedRecovery` | Spezialjournale bleiben `UNSUPPORTED` |
| `Reproduction` | SHA-256 des öffentlichen SQL-Versionskatalogs; bei fehlendem oder unlesbarem Katalog `UNAVAILABLE` mit `DIAGNOSTIC_CATALOG_UNAVAILABLE` und leerem Hash; kein Hash privater State-Inhalte |
| `Exclusions` | Maschinenlesbare ausgeschlossene Datengruppen |

`OBSERVED` am Gesamtergebnis bedeutet, dass die angeforderte Metadatenbindung
beobachtet wurde. Jeder Abschnitt behält seinen eigenen Evidence-Status.
Ein fehlender optionaler Record ist `UNAVAILABLE`, ein nicht verifizierbarer
Record `BLOCKED`. Historische Fehler werden nicht als reproduzierte
Produktfehler ausgegeben. Eine genaue Fehlerphase oder Ursache aus Rohlogs,
SQL-Fehlern oder Spezialjournalen ist in diesem engen Vertrag nicht verfügbar.
`REMOVED` beziehungsweise `Cleanup.Status=COMPLETED` beweist keine heutige
Restfreiheit. `RecoveryStatus=NOT_RECORDED` bedeutet nicht, dass keine Recovery
erforderlich sein kann.

## Provider-Readiness

Erst nach vollständiger Bindungsprüfung startet ein unsichtbarer Kindprozess
die bestehende private `Get-LabClientRuntimeReadiness`-Logik. Deren
Host-Tool-Resolver und klassifizierte Providerprüfung bleiben maßgeblich.
Der umfassende `Test-SqlServerLabClientReadiness.ps1`-Einstieg wird bewusst
nicht aufgerufen: Er liest zusätzlich globale Storage-Konfiguration.
`Capabilities.ClientReadiness=UNSUPPORTED` macht diese Einschränkung sichtbar.
Der Providercheck bezieht sich auf den aktuellen Clientkontext und beweist
nicht, dass dieser Kontext die historische Runtime des angeforderten Runs ist.

Fehlende Installation (`TOOL_NOT_INSTALLED` beziehungsweise
`PROVIDER_NOT_INSTALLED`), Ausführungsrechte (`TOOL_EXECUTION_DENIED`),
Providerrechte (`PROVIDER_ACCESS_DENIED`), Nichterreichbarkeit
(`PROVIDER_UNREACHABLE`), Timeout (`PROVIDER_PROBE_TIMEOUT`) und ungültige
Antwort (`PROVIDER_RESPONSE_INVALID`) bleiben getrennte Codes. Native Rohtexte
und Pfade werden weder zurückgegeben noch protokolliert. `READY` ist keine
Mutationsfreigabe und keine SQL-Readiness. Docker, Podman und Hyper-V bleiben
getrennte Provider; die OS-Klasse beschreibt die gebundene SQL-Lane.

## Größen-, Zeit- und Privacygrenzen

Metadaten: höchstens 1 MiB je Run-/Cleanup-/Operation-Datei, 64 KiB für den
Root-Katalog, 16 KiB je Marker; JSON-Tiefe höchstens 32 beziehungsweise 12/8
für Root-Katalog/Marker und 16.384 JSON-Knoten. Doppelte Schlüssel einschließlich
Groß-/Kleinschreibungsvarianten werden abgewiesen. Listen sind auf 32 Locations,
64 Instanzen, drei Provider-Teilruns, 256 Fehler-/Historieneinträge beziehungsweise
Cleanupschritte und 64 Operationsschritte begrenzt.

Readiness: maximal 45 Sekunden einschließlich Modulimport, zusätzlich höchstens
fünf Sekunden für bestätigte Prozessterminierung; stdout und stderr teilen ein
64-KiB-Limit. JSON-Antworten haben höchstens Tiefe acht und 24 klassifizierte
Checks. Timeout, Ausgabeüberschreitung oder unbestätigte Terminierung ergeben
`UNAVAILABLE` mit eigenem Code, niemals einen grünen Abschluss.

Keine Secretstores, `connection-info.json`, freien Logdateien, SQL-Inhalte,
Provider-Inspect-Inventare oder Spezialjournale werden gelesen. Run-/Instanz- und
Runtime-IDs, Namen, Endpunkte, Ports, Hostpfade, Secret-Aliasse, Exceptions und
Rohlogs fehlen in allen Ausgabekanälen. Reproduktionshashes beziehen sich
ausschließlich auf den öffentlichen Katalog. Ein automatischer Supportexport
und die Operator-Agent-Integration gehören nicht zu diesem API-Slice.

## Validierung

[Invoke-DiagnosticBundleChecks.ps1](../../Tests/Static/Invoke-DiagnosticBundleChecks.ps1)
prüft reale lokale State-/Sollzustandsproduzenten mit synthetischem Storage,
Ownership- und Fremdobjektfehler vor Providerproben, Schema, Canarywerte,
Dateibytegleichheit, gesperrte Connection-Datei, Reparse-/Traversierungsabwehr,
Größen-/Tiefenlimits und echte begrenzte synthetische Kindprozesse. Provider-
Readiness wird für diese Offlineprüfung simuliert. Sie erzeugt und entfernt
nur ihre eigenen temporären Dateien und Prozesse; sie startet keine Lab-Runtime.
Die bestehende Client-Readiness-Suite prüft zusätzlich die klassifizierten
Resolver-/Prozessgrenzen. Native SQL- oder Providerabnahmen werden dadurch
nicht behauptet.
