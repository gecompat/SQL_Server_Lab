# Interner Capability-Entscheid für Szenarien

Status: `IMPLEMENTED_INTERNAL_SLICE` für SCN-803. Der private Einstieg
`Get-LabScenarioCapabilityDecision` in `Private/ScenarioCapabilityDecision.ps1`
bewertet eine mögliche Szenarioausführung ausschließlich read-only. SCN-801
bleibt unverändert `ExecutionImplemented=false`; der SCN-802-Executor wird
nicht aufgerufen oder verändert. SQL-/Providerbindung und öffentliche
Scenario-Identitäten sind nicht Teil dieses Vertrags.

## Eingaben und Bindung

Der vertrauenswürdige lokale Aufrufer übergibt einen SCN-801-Contract und einen
`SqlServerLab.InternalScenarioCapabilityPlan/0.1` als getrennte JSON-Strings
sowie einen expliziten UTC-Auswertungszeitpunkt. Beide JSON-Dokumente sind auf
65.536 Zeichen und Tiefe 20 begrenzt. Doppelte Schlüssel einschließlich
abweichender Großschreibung, Steuerzeichen, unbekannte Felder und ungültige
Referenzen werden abgewiesen. Schema-Dateien werden ausschließlich aus dem
Repository gelesen. Ein optionaler SCN-801-Schemahinweis darf nur
`scenario-contract.schema.json` lauten; externe Quellen werden nicht aufgelöst.

Der Capability-Plan bindet `ScenarioId`, `ScenarioVersion` und die vollständige
Menge `RequiredCapabilities` exakt an `Scenario.RequiredSqlCapabilities` des
Contracts. `AvailableCapabilityIds` ist eine deklarierte, eindeutige Menge,
kein Ergebnis einer Runtimeabfrage. Die Entscheidung beweist weder aktuelle
Verfügbarkeit noch Ownership, Rechte oder Sicherheit einer späteren Ausführung.

Jede `AlternativeEvidence` bindet genau eine fehlende Capability an eine
vorhandene synthetische Evidence-ID des Contracts, dasselbe Scenario und
dieselbe Version. Klassifikation und Ergebnis müssen `SYNTHETIC` beziehungsweise
`PASSED` sein. Evidence- und Capability-IDs dürfen nicht mehrfach verwendet
werden. Evidence für bereits verfügbare oder fremde Capabilities wird abgewiesen.
Der feste UTC-Zeitbereich erfüllt `ObservedAtUtc <= EvaluationTimeUtc <
ExpiresAtUtc` und ist höchstens 24 Stunden lang. Zeitstempel besitzen exakt
Sekundenauflösung mit abschließendem `Z`; ungültige Kalenderdaten scheitern.
Diese Metadaten sind ausschließlich synthetische Prüfbehauptungen und keine
signierten, authentifizierten oder unabhängig erhobenen Runtime-Receipts.

## Entscheidungen

| Bedingung | Status | AlternativeEvidenceUsed |
|---|---|---|
| Alle deklarierten Capabilities vorhanden, keine Alternative erforderlich | `ELIGIBLE` | `false` |
| Jede fehlende Capability besitzt exakt eine valide synthetische Alternative | `NOT_EXECUTED` | `true` |
| Fehlende Capability ohne vollständige Alternative | `UNSUPPORTED` | `false` |
| Irgendeine ungültige Eingabe oder Evidence, auch wenn sie nicht benötigt würde | `BLOCKED` | `false` |

`ELIGIBLE` erteilt keine Ausführungsfreigabe. Alle Ergebnisse halten
`ExecutionPerformed=false` und `RuntimeEvidenceVerified=false`. Eine Alternative
verwandelt fehlende Runtime-Evidence niemals in `PASSED`. Teilweise valide
AlternativeEvidence bleibt ungenutzt. Ausgaben enthalten nur feste Status- und
ReasonCodes sowie validierte IDs; `BLOCKED` reflektiert keine Eingabewerte.
Ordinal sortierte Mengen und der explizite Zeitpunkt machen Entscheidungen
reproduzierbar. Es gibt keine Uhrabfrage, Persistenz, Journale, Commands,
Secretwerte, frei auflösbare Pfade, Netzwerkabfragen oder Provideraktionen.

## Validierung und offene Integration

`Tests/Static/Invoke-ScenarioCapabilityDecisionChecks.ps1` prüft positive,
negative, mehrdeutige und abgelaufene Eingaben, partielle Abdeckung,
Umordnungsinvarianz, Schemaausgaben, private Exportgrenze und unveränderte
Aufrufereingaben. Die Tests führen ausschließlich lokale deterministische
Auswertung durch. Der CI-Selektor bindet die neue Suite und den bestehenden
SCN-801-Vertrag; unbekannte Produktdateien behalten ihren Runtime-Fallback.
Die Suite ist auch im vollständigen statischen Gate registriert.

Die produktive Ermittlung aktueller Capabilities, authentifizierte externe
Evidence, Provider-/SQL-Zielbindung und die verbindliche Integration in einen
späteren fachlichen Executor bleiben offen. Dieser Teilscope schließt weder
SCN-803 als Ganzes noch Gate M8 ab.
