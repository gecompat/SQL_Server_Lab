# Persistierte SQL-Gast-Evaluations-Evidence – Vertrags-Backlog

| Merkmal | Wert |
|---|---|
| Status | `BACKLOG` |
| Stand | 2026-09-11 |
| Scope | Hyper-V-Run mit SQL-Gast; nur Evaluationsermittlung und read-only Projektion |
| Ziel | Versionsgebundene, frische und geheimnisfreie SQL-Gast-Frist für Watch und Refresh |
| Autorität | Vertrag und Abnahmeplan; keine neue Gastabfrage, Lizenz-, Refresh-, Netzwerk- oder Runtime-Mutation |

## Ausgangslage und Lücke

`Get-SqlServerLabEvaluationWatch` bewertet Image-Metadaten und für laufende
Hyper-V-Instanzen ausschließlich die persistierte Windows-Aktivierungsevidenz.
Der SQL-Readiness-Receipt bestätigt nur Instanz, Version, Edition und vier
online Systemdatenbanken. Er enthält keine SQL-Lizenz- oder Evaluationsfrist.
Bei SQL-Evaluation-Images kann die Image-Frist bewusst leer bleiben, weil ihr
Beginn erst im Gast eintritt. Daraus darf keine Frist abgeleitet werden.

Es gibt daher derzeit **keinen** persistierten Produktionsvertrag für eine
SQL-Gast-Evaluationsfrist. Image-Lizenzmetadaten, Windows-Aktivierung,
SQL-Readiness und eine aus einer Buildzeit berechnete Schätzung sind kein
Ersatz. Der bestehende Watch darf diesen Zustand nicht als `OK` oder als
aktuelle SQL-Gastfrist ausgeben.

## Minimaler Zielvertrag

Der erste Slice ergänzt genau einen kanonischen, runlokalen Receipt:

- Pfad: `runs/<RunId>/sql-guest-evaluation-evidence.json` unter dem gebundenen lokalen State-Root;
- Vertrag: `SqlServerLab.SqlGuestEvaluationEvidence/1.0`;
- Provider: ausschließlich `hyperv`; Container und andere Provider erhalten keine implizite Parität;
- Erfassung: eine spätere explizite Capture-Aktion darf nur nach erfolgreicher Live-Prüfung des gebundenen SQL-Gastes atomar schreiben;
- Projektion: der Watch liest nur Receipt, Run-State und Connection-State. Er startet keine VM, öffnet keine SQL-Verbindung und repariert nichts.

Der Receipt ist die alleinige Quelle für die SQL-Gastfrist.
`connection-info.json` bleibt Verbindungs- und Instanzbindung; es erhält keine
zweite, auseinanderlaufende Kopie der Frist. Image-Registry und SQL-Readiness
bleiben getrennte Quellen mit ihren heutigen Zwecken.

### Pflichtfelder und stabile Bindung

| Gruppe | Pflichtinhalt | Zweck |
|---|---|---|
| Vertrag | `Contract.Name`, `Contract.Version`, `EvidenceId`, `ObservedAt` | Typ, Version, eindeutige Beobachtung und zeitliche Einordnung |
| Bindung | `RunId`, `ScopeId`, `InstanceId`, `Provider`, `VmId`, `ImageArtifactId` | Bindung an den aktuellen registrierten Hyper-V-Run, seine Instanz, VM und Parent-Artefakt |
| SQL-Identität | `SqlInstanceName`, `SqlMajorVersion`, `SqlEdition` | Übereinstimmung mit erwartetem SQL-Run und SQL-Readiness |
| Evaluation | `LicenseClassification`, `EvaluationExpiresAt`, `DeadlineSource` | nur beobachtete SQL-Lizenzklasse und Frist |
| Gültigkeit | `ObservationStatus`, `EvidenceFreshUntil`, `PreviousEvidenceId` | Ergebnis, begrenzte Aktualität und Folgebeobachtung |

`EvidenceId`, `RunId`, `ScopeId`, `InstanceId` und `ImageArtifactId` sind
stabile IDs. `VmId` bleibt lokal und wird nicht öffentlich projiziert. Beim
Schreiben und Lesen müssen `RunId`, `ScopeId`, `InstanceId`, Provider, `VmId`
und `ImageArtifactId` exakt mit `run-state.json` und der genau einen passenden
Hyper-V-Instanz in `connection-info.json` übereinstimmen. Fehlt eine Quelle,
gibt es mehrere Instanzen oder ändert sich eine Bindung, ist der Receipt
ungültig; ein älterer Receipt darf nicht weiterverwendet werden.

`SqlInstanceName`, `SqlMajorVersion` und `SqlEdition` werden gegen den
persistierten SQL-Readiness-Receipt geprüft, soweit er für denselben Run/VM
vorliegt. Fehlende Readiness-Evidence ist ein Capture-Blocker, keine Erlaubnis
für eine anhand von Image-Metadaten geschätzte Frist.

Die erste Version akzeptiert nur:

- `LicenseClassification`: `EVALUATION`, `NOT_EVALUATION` oder `UNKNOWN`;
- `DeadlineSource`: `SQL_GUEST_OBSERVED`, `SQL_GUEST_NO_DEADLINE` oder `SQL_GUEST_UNAVAILABLE`;
- `ObservationStatus`: `CAPTURED`, `NO_DEADLINE`, `UNAVAILABLE` oder `FAILED`.

`EvaluationExpiresAt` ist für `EVALUATION` mit `SQL_GUEST_OBSERVED` ein
UTC-RFC-3339-Zeitpunkt. Ein leeres Datum bei `EVALUATION` ist nur mit
`SQL_GUEST_NO_DEADLINE` zulässig und wird als `UNKNOWN`, nie als `OK`,
projiziert. `EvidenceFreshUntil` ist UTC-RFC-3339 und darf höchstens 168
Stunden nach `ObservedAt` liegen. Die Capture-Implementierung muss die
konkrete, hersteller- und versionsgerechte Gastabfrage mit eigener Native-
Evidence belegen; dieser Backlog erfindet keine Abfrage und keine Fristwerte.

### Versionierung, Austausch und Grenzen

`1.0` erlaubt nur additive optionale Felder. Eine Änderung von Bedeutung,
Bindungsregeln, Statuswerten oder Zeitsemantik erfordert eine neue
Major-Version mit Reader-Migrationspfad. Reader akzeptieren nur unterstützte
Major-Versionen und melden unbekannte, malformed oder doppelte `EvidenceId`
als `EVIDENCE_INVALID`.

Ein neuer Receipt ersetzt den alten atomar erst nach vollständiger Validierung.
`PreviousEvidenceId` verweist nur auf dieselbe vollständige Bindung; bei der
ersten Erfassung bleibt es leer. Der Writer darf weder `run-state.json` noch
`connection-info.json`, Image-Registry, Lizenzstatus, VM, SQL-Konfiguration
oder Netzwerk ändern. Ein fehlgeschlagener Capture lässt den letzten gültigen
Receipt unverändert und schreibt höchstens einen geheimnisfreien,
bindungsbezogenen Fehlerstatus in ein eigenes versioniertes Capture-Journal.

Receipt, Journal und Projektion enthalten nie Passwörter, Connection Strings,
SQL-Texte, Produktkeys, VM-/Hostnamen, IP-Adressen, Ports, lokale Pfade,
Datenbanknamen, vollständige Fehlerantworten oder Gast-/Hostdiagnosen. Eine
Hash- oder Redaktionsregel darf eine fehlende Frist nicht in eine Frist
umdeuten.

## Read-only Projektion und Statuswahrheit

Der Watch erhält erst mit diesem Slice eine SQL-Gast-Instanzprojektion. Sie
gilt nur für registrierte `RUNNING`- oder `STOPPED`-Hyper-V-SQL-Runs; andere
Run-Zustände liefern keine aktuelle Gastfrist. Sie veröffentlicht nur `RunId`,
`InstanceId`, `ArtifactId`, `Component=SqlServer`, `RegistrationState`,
`DeadlineSource`, `EvidenceStatus`, optional `EvaluationExpiresAt`,
`DaysRemaining`, abgeleiteten Fälligkeitsstatus und stabile Event-ID.

| Bedingung | `EvidenceStatus` | Watch-Status | Wirkung |
|---|---|---|---|
| Gültig, frisch, zukünftige Frist | `CURRENT` | `OK`, `WARNING` oder `CRITICAL` | Fälligkeit darf dedupliziert werden |
| Gültig, frisch, Frist abgelaufen | `CURRENT` | `EXPIRED` | nur manueller Rebuild-/Refreshplan |
| Gültig `NOT_EVALUATION` | `NOT_EVALUATION` | `NOT_APPLICABLE` | keine Evaluation-Warnung |
| Kein Receipt, falsche Bindung/Version/Pflichtfeld | `EVIDENCE_MISSING` oder `EVIDENCE_INVALID` | `UNKNOWN` | `REFRESH_BLOCKED`; kein Image-/Windows-Fallback |
| Nach `EvidenceFreshUntil` | `EVIDENCE_STALE` | `UNKNOWN` | `REFRESH_BLOCKED`; Capture erforderlich |
| Evaluation ohne beobachtbares Datum | `DEADLINE_UNKNOWN` | `UNKNOWN` | `REFRESH_BLOCKED`; keine Restlaufzeitberechnung |

`RecordEvents` darf nur den vorhandenen lokalen, deduplizierten Watch-
Event-State ergänzen. Es darf niemals SQL-Gast-Evidence erfassen, verlängern,
löschen oder auffrischen. Ein Event bindet mindestens Run, Instanz, Komponente,
EvidenceStatus und Frist-/Statusfingerprint.

## Negative Vertragsprüfungen

1. Kein Receipt, leere SQL-Imagefrist oder fehlende SQL-Readiness-Evidence ergibt keine SQL-Gastfrist und keinen `OK`-Status.
2. Falscher Run, Scope, Instanz, Provider, VM oder Imageartefakt ergibt `EVIDENCE_INVALID`.
3. Doppeltes `EvidenceId`, unbekannte Major-Version, ungültige Zeit oder `EvidenceFreshUntil` vor `ObservedAt` beziehungsweise über 168 Stunden wird abgewiesen.
4. `EVALUATION` ohne zulässige Quelle/Frist, eine Frist für `NOT_EVALUATION` oder eine aus Windows-/Image-Metadaten kopierte Frist ergibt `UNKNOWN` oder `EVIDENCE_INVALID`, nie eine aktuelle Frist.
5. Ein veralteter Receipt, ein nicht berechtigter Run oder ein ersetzter VM-Bezug kann keinen vorherigen `OK`-Status wiederbeleben.
6. Die Projektion öffnet keine SQL-Verbindung, ruft keine Runtime auf, schreibt ohne `-RecordEvents` nichts und gibt keine ausgeschlossenen Daten aus.

## Erforderliche native Evidence

Vor `IMPLEMENTED_READ_ONLY` ist ein isolierter Hyper-V-Lauf mit tatsächlich als
Evaluation erkannter SQL-Instanz erforderlich. Er muss einen verwalteten
SQL-Evaluations-Run mit SQL-Readiness und Cleanup bereitstellen, Capture mit
flüchtigem Credential ausführen, die Bindung gegen Run/VM/Image/Readiness
prüfen und den Watch anschließend ohne Credential, Gastzugriff oder Mutation
ausführen. Zu belegen sind Aktualität, Warn-/Ablaufklassifikation,
Event-Deduplizierung, Sanitierung und vollständiger Cleanup von Run, VM,
temporären Disks, Netz/Lease, Credentials und Teststate.

Fehlt für eine unterstützte SQL-Version eine tatsächlich beobachtbare Frist,
endet die Native-Evidence als `NOT_EXECUTED` oder `UNSUPPORTED` mit Grund;
sie darf keine synthetische Produktionsfrist oder erfolgreichen Gast-Capture
behaupten.

## Abgrenzung und Folgearbeit

Dieser Slice implementiert weder Capture noch neue SQL- oder Hyper-V-Abfragen.
Er schafft keine Lizenzverlängerung, keinen automatischen Refresh, Cutover,
Export, Import, Notification-Service oder Windows-Aufgabe. Der vollständige
Evaluation-Refresh darf erst eine frische, gültig gebundene SQL-Gast-Evidence
als Preflight verwenden und muss bei `UNKNOWN`, `EVIDENCE_INVALID` oder
`EVIDENCE_STALE` blockieren.

Abhängigkeiten:

- [Evaluation-Watchdog und Benachrichtigung](CROSS_CUTTING_PLATFORM_CAPABILITIES_BACKLOG.md)
- [Vollständiger Instanz-Refresh vor Evaluation-Ablauf](FULL_INSTANCE_EVALUATION_REFRESH_BACKLOG.md)
- [Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrag](../Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md)
- [Bekannte Grenzen](../Quality/KNOWN_LIMITATIONS.md)
