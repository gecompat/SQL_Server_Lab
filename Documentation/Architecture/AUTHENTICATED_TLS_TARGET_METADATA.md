# Private TLS-Zielmetadaten

| Merkmal | Wert |
|---|---|
| Status | `implemented`; lesende Metadatenbindung, keine Runtime- oder Mutationsautorität |
| Stand | 2026-10-16 |
| Scope | `TLS001-BINDING-01`, begrenzter Folgeschritt aus [TLS-001a](../Project_Planning/TLS_001_ISOLATED_CA_DESIGN.md) |
| Implementierung | [`Private/AuthenticatedTlsTarget.ps1`](../../Private/AuthenticatedTlsTarget.ps1) |
| Prüfung | [`Invoke-AuthenticatedTlsTargetChecks.ps1`](../../Tests/Static/Invoke-AuthenticatedTlsTargetChecks.ps1) |

## Auswahl und Ergebnis

`Get-LabAuthenticatedTlsTargetMetadata` ist privat und nicht exportiert.
Erforderlich sind eine gültige `LEAF_PROFILE`-Anfrage aus dem
[Formvertrag](AUTHENTICATED_TLS_REQUEST.md), eine ausdrückliche `InstanceId`
und der registrierte `DataRoot`. In diesem Resolver bedeutet `TargetRef`
genau die vorhandene moderne `RunId`; es entsteht keine weitere UUID-Registry.
Die Instanzwahl bleibt zusätzlich erforderlich, auch bei nur einer Instanz.
Kein Defaultziel, kein CMS-, Testgruppen- oder Exportfallback.
`AuthorityRef` bleibt unaufgelöst und erteilt keine CA-Autorität.

Der gemeinsame [Diagnose-Reader](DIAGNOSTIC_BUNDLE.md#bindung-und-grenzen)
prüft Controller, registrierten Root mit Location-/Volume-Verweis, Run,
Scope-Marker, Sollinstanz, Provider-Teilruns und persistente Rootbindung.
Seine bestehenden Byte-, JSON-, Pfad- und Reparsegrenzen gelten auch hier.
Die Identitätsvergleiche der gemeinsam verwendeten Root-/Scope-/Vertragsbindung
sind ordinal; kulturell ignorierbare Zusatzzeichen werden nicht als identisch
übernommen. Globale Storage-Konfiguration, andere Runs, Connection-Dateien,
Secrets, Cleanuppläne und Workflow-Operationen werden nicht gelesen.

Dieser erste Resolver unterstützt ausschließlich Docker und Podman.
Angeforderter Provider und SQL-Version müssen ordinal mit Soll- und
Istinstanz übereinstimmen. Bei katalogisierten CU-Kurzbezeichnern und exakten
CU-Tags bleibt `SqlVersion` der vollständige ursprüngliche Runselektor.
Der gemeinsame Reader bindet intern zusätzlich Basisjahr, exaktes Katalogimage
und Katalogbuild. CU-Kurzbezeichner verwenden dieselbe geordnete Auswahl wie
`Get-SqlServerDockerImage`; der ausgewählte Tag muss eindeutig katalogisiert
sein und zu Jahr und CU passen. Ein unbekannter Tag, widersprüchlicher oder
doppelter Katalogeintrag sperrt die Bindung; kein Rückfall auf Basisjahr oder
`latest`. Alias und exakter Tag sind keine austauschbaren Runidentitäten.
Katalogbuild und Tag sind Sollmetadaten, keine native Build-/Imagebeobachtung.
Diese Bindung wurde synthetisch geprüft; frühere native CU-Fixtures erhalten
dadurch keinen nachträglichen Nachweis dieses Produktpfads.
Genau eine gespeicherte Instanz mit genau der
ausgewählten ID, eine vollständige kleine 64-stellige Hex-Container-ID und
gespeichertes `RUNNING` im Run sowie passenden Provider-Teilrun sind nötig.
Ein gespeichertes `RUNNING` ist keine Beobachtung einer laufenden Runtime.
Hyper-V wird vor Metadatenzugriff ausdrücklich als nicht unterstützt abgewiesen;
seine VM-/Gastbindung braucht einen eigenen nachgewiesenen Adapter.

Gespeicherter Host und Port müssen exakt der bereits typisierten angeforderten
IP-/DNS-Identität und dem Port entsprechen. Native JSON-Integer werden
akzeptiert, Strings, Booleans und Fließkommazahlen nicht. Kein DNSzugriff,
keine IP-/DNS- oder localhost-Ersetzung, keine Portsuche und kein anderer
Hostname bei einer Abweichung. Änderungen benötigen eine neue Auswahl.

Das Ergebnis enthält ausschließlich `Success`, `Value`, `ErrorCode`.
Bei Erfolg ist `Value` eine frische private Projektion mit:

- `ContractVersion=SqlServerLab.AuthenticatedTlsTargetMetadata/0.1`,
  `Status=RECORDED`;
- `TargetRef`, `InstanceId`, `ScopeId`, `Provider`, `SqlVersion`, `ContainerId`,
  `Port` und einer kopierten `Identity` mit `Kind` und `Value`;
- `RuntimeStatus=NOT_EXECUTED`, `AuthorizationStatus=NOT_EVALUATED` und
  `MutationAllowed=false`.

Diese Projektion enthält lokale IDs und den ausgewählten Endpoint. Sie bleibt
im privaten Aufrufkontext und ist weder öffentlicher DTO noch Export-, Log-
oder Uploadformat. Run-/Sollobjekte, Hostpfade, freie Metadaten und Secrets
werden nicht weitergegeben. `ErrorCode` ist bei Erfolg `null`; Ablehnung
liefert `Success=false`, `Value=null` und einen festen Code ohne Rohdiagnose.

| Fehlercode | Bedeutung |
|---|---|
| `TLS_TARGET_REQUEST_INVALID` | Ungültige oder andere Anfrageform |
| `TLS_TARGET_SELECTOR_INVALID` | Ungültiger Typ oder Form der ausdrücklichen Instanz-/Rootauswahl |
| `TLS_TARGET_PROVIDER_UNSUPPORTED` | Gültige Hyper-V-Anfrage außerhalb dieses Adapters |
| `TLS_TARGET_METADATA_UNAVAILABLE` | Fehlende, unlesbare, ungültige oder inkonsistente Reader-Evidence; keine Weitergabe des Rohfehlers |
| `TLS_TARGET_METADATA_MISMATCH` | Ausgewählte Soll-/Istinstanz, Container-ID, Provider, Version oder Endpoint passen nicht |
| `TLS_TARGET_STATE_UNSUPPORTED` | Run oder passender Provider-Teilrun nicht als `RUNNING` gespeichert |

## Getrennte aufgezeichnete Hyper-V-Zielbindung

`Get-LabAuthenticatedTlsHyperVTargetMetadata` ist eine zusätzliche private
lesende Lane. Sie verlangt dieselbe geschlossene Hyper-V-`LEAF_PROFILE`-Form,
registrierten Root und ausdrückliche VM-Instanzwahl sowie eine zusätzliche
`SqlInstanceId` des SQL-Dienstes. Der Containerresolver bleibt unverändert.
Hyper-V akzeptiert nur katalogisierte Basisjahre; ein Container-CU-Tag
qualifiziert kein Prepared-Image und wird nicht auf ein Jahr reduziert.

Nach der gemeinsamen Root-/Run-/Scope-/Sollbindung muss der gespeicherte
Workflow `hyperv-lab` sein und Run sowie Teilrun müssen `RUNNING` melden.
Gelesen wird zusätzlich ausschließlich die feste `connection-info.json`
dieses Runs: höchstens 256 KiB, JSON-Tiefe 20, Schema 1 und genau eine VM.
Provider, Instanz, SQL-Workload, SQL-Jahr und angeforderter Endpoint müssen
ordinal passen. Die VM-ID ist eine kanonische nichtleere UUID. Der Anzeigename
ersetzt sie nicht und verlässt den Adapter nicht. Der reguläre Producer lässt
`run.instances` leer; zusätzliche Istrecords müssen dieselbe VM-ID tragen.

Die SQL-Auswahl ist zwingend, auch bei einem Dienst. Maximal 64 aufgezeichnete
SQL-Instanzen mit eindeutigen IDs werden gelesen; Groß-/Kleinschreibungsaliases
gelten als Duplikate. Der ausgewählte Record braucht einen begrenzten
SQL-Dienstnamen, Status `Running` und denselben numerischen TCP-Port.
`Name` und das native Boolean `IsDefault` müssen den gespeicherten Dienst
eindeutig ergeben: `MSSQLSERVER` oder `MSSQL$<Name>`. Die interne SQL-Instanz-ID
bleibt ein opaker Selektor; ihr Suffix wird nicht als Instanzname geraten.
Verbindungsstrings, Kennwörter, VM-Namen, Imagepfade und übrige Records werden
nicht zurückgegeben. Das geschlossene DTO
`SqlServerLab.AuthenticatedTlsHyperVTargetMetadata/0.1` enthält ausschließlich
Run-/Scope-/VM-/SQL-Instanz-ID, Provider, SQL-Jahr, Dienstname und Endpoint
sowie `Status=RECORDED`, `RuntimeStatus=NOT_EXECUTED`,
`AuthorizationStatus=NOT_EVALUATED` und `MutationAllowed=false`.

Die Lane ruft keine Hyper-V-Workflowfunktion auf: Diese kann veraltete
VM-Namen reparieren. Sie liest weder VM-Notes noch Gastzustand oder separate
Credential-, Key- oder Storedateien. Die begrenzt geladene Verbindungsdatei kann
sensible Felder enthalten; diese verlassen weder DTO noch Fehler- oder
Nebenstreams. Es gibt keine VM-Abfrage, Verbindung oder Resolveränderung.
Die Dateibeobachtungen sind nicht atomar. Vor späterer Mutation müssen native
VM-ID/Ownership, Gast-/SQL-Dienst, CSP/KeySpec und Zertifikatsbindung frisch
geprüft werden. Diese Metadaten erweitern die öffentliche operative
False-Capability nicht; sie bleibt Windows/Docker/SQL 2025 CU9.

## Autoritätsgrenze und nächster vertikaler Schritt

Die Prüfung zeigt ausschließlich lokale Metadatenkonsistenz. Schreibrechte
auf State-Dateien können diese Daten verändern; es gibt keine kryptographische
Attestation, atomare Dateisystemsicht oder reservierte Runtime. Das Ergebnis
darf weder gecacht als spätere Mutationsfreigabe verwendet werden noch eine
Keyöffnung, Signierung, Installation oder SQL-Verbindung auslösen.
Vor solchen Aktionen sind neue Bindungsprüfung, tatsächliche native Provider-
Namespace-/Runtimeidentität, exakte Containerlabels und Endpointbeobachtung
sowie die konkrete Autorisierung erforderlich. Die vorhandene CMS-Probe ist
kein TLS-Ownershipadapter und wird dafür nicht aufgerufen.

Für `ClientRef` und `AuthorityRef` existiert noch keine produktive Registry.
Es wird keine Bindung an den gerade angemeldeten Benutzer, einen zufälligen
Prozess oder eine installierte Clientversion erfunden. Der
[Registrierungsentwurf](../Project_Planning/TLS_001_CONTEXT_REGISTRATION_DESIGN.md)
trennt diese Identitäten; die [Backendmetadaten](AUTHENTICATED_TLS_BACKEND_METADATA.md)
entdecken ausschließlich API-Signaturen im ausdrücklich gewählten Prozess.
Die tatsächliche Registrierung bleibt offen. Installierte .NET-/ODBC-Komponenten
beweisen weder Keyschutz/Signierfähigkeit noch den tatsächlich von sqlcmd
geladenen Treiber. CA-/Leafkey, Storepreview, Trustimport, Journal, Abbruch/
Recovery und Exportcutover bleiben nachfolgende getrennte Verträge.

## Prüfung und Integrationsaufwand

Die synthetische Suite verwendet die wirklichen modernen Run-/Sollproduzenten
unter einem eigenen temporären registrierten Root. Sie prüft Sollprojektionen,
Provider-/Versions-/IP-/DNSfälle, fehlende und widersprüchliche Bindungen,
kulturell ignorierbare Zeichen, StrictMode, unveränderte Dateien, gesperrte
Connection-/Secretdateien sowie den geschlossenen lesenden Commandgraph.
Dies sind Offlinefälle und keine native Provider-/SQL-/TLS-Matrix.
Der temporäre eigene Root wird nach geprüftem Pfad entfernt.

Nur die exakte neue Produktdatei erhält die lesende Offline-Ausnahme im
Selektor. Der gemeinsame Reader und der Anfragevertrag wählen zusätzlich die
neue Suite; ähnliche Pfade und gemischte Runtimeänderungen behalten ihre
konservative Auswahl. Nightly nimmt die Suite ebenfalls auf. Die notwendige
unabhängige Prüfung und der Pflichtgate bleiben bestehen. Ausgeführte
Ergebnisse stehen in der [Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md).
