# Privater TLS-Anfragevertrag

| Merkmal | Wert |
|---|---|
| Status | `implemented`; reine Formprüfung im Speicher |
| Stand | 2026-10-16 |
| Scope | `TLS001-REQUEST-01`, erster Code-Slice aus [TLS-001a](../Project_Planning/TLS_001_ISOLATED_CA_DESIGN.md) |
| Implementierung | [`Private/AuthenticatedTlsRequest.ps1`](../../Private/AuthenticatedTlsRequest.ps1) |
| Prüfung | [`Invoke-AuthenticatedTlsRequestChecks.ps1`](../../Tests/Static/Invoke-AuthenticatedTlsRequestChecks.ps1) |

## Bedeutung und Grenze

`Test-LabAuthenticatedTlsRequest` ist eine private, nicht exportierte
Formprüfung. Sie akzeptiert ausschließlich ein natives `PSCustomObject` mit
geschlossenen `PSNoteProperty`-Feldern und gibt genau ein Objekt mit
`Success`, `Value` und `ErrorCode` zurück. Ungültige Eingaben liefern
`false`, `null` und `TLS_REQUEST_INVALID`; Rohwerte oder Fehler werden nicht
geloggt. Erfolg liefert eine frische, geordnet projizierte Objektstruktur.
Callerobjekte und deren Arrays werden nicht verändert oder geteilt.

Erfolg belegt ausschließlich die Anfrageform. Referenzen, Zertifikatsdigest,
Backend, SQL-Version und Clientkontext werden nicht aufgelöst oder als vorhanden,
besessen, verfügbar, freigegeben oder qualifiziert attestiert. Die Funktion
liest keine Schlüssel, Dateien, Stores, DNS-, Host-, Runtime- oder SQL-Daten
und erzeugt weder CA noch Zertifikat, Trustimport, Journal oder Export. Sie
dekodiert kein JSON und erteilt keine Ausführungsautorität. Eine spätere
Transportgrenze muss Bytes, Duplicate Keys und sichere Dekodierung selbst
prüfen, bevor eine solche Anfrage entsteht.

## Geschlossene Formen

Alle Feldnamen und Enums sind ordinal und case-sensitiv; Werte werden nicht
getrimmt, umbenannt oder in andere Typen konvertiert. Unbekannte, fehlende,
anders geschriebene und zusätzliche Felder werden auf jeder Objektebene
abgewiesen. Script-/Alias-/CodeProperties werden vor dem Lesen abgewiesen.
Methoden eines Callerobjekts werden nicht für die Typprüfung verwendet.

Gemeinsame Pflichtfelder:

| Feld | Form |
|---|---|
| `ContractVersion` | exakt `SqlServerLab.AuthenticatedTlsRequest/0.1` |
| `RequestId`, `AuthorityRef` | nichtleere kanonische UUID in kleinem D-Format, kein nativer GUID-/Objektcast |
| `Kind` | `CA_PROFILE`, `LEAF_PROFILE` oder `CLIENT_TRUST` |

`CA_PROFILE` ergänzt ausschließlich `Profile`. Das Profil hat exakt
`Algorithm=RSA`, `RsaBits=3072`, `Signature=SHA256`, `ValidityDays` und
`RenewBeforeDays`. Die Zahlen sind echte `Int32`, keine Strings, Booleans,
Fließkommawerte oder anderen Integerbreiten. Gültigkeit: 2 bis 365 Tage;
Erneuerung: mindestens ein Tag und strikt vor Gültigkeitsende. Diese enge
Form beschreibt ein angefragtes Labprofil, noch keine produktive Festlegung
oder erfolgreiche CSP-/KeySpec-/Providerqualifikation.

`LEAF_PROFILE` ergänzt ausschließlich:

| Feld | Form |
|---|---|
| `TargetRef` | kanonische nichtleere UUID; der optionale [Metadatenresolver](AUTHENTICATED_TLS_TARGET_METADATA.md) bindet sie an eine vorhandene RunId mit zusätzlicher ausdrücklicher Instanzwahl; Runtime-/Ownershipprüfung offen |
| `Provider` | `docker`, `podman` oder `hyperv` als angefordertes Tupel |
| `SqlVersion` | String `2019`, `2022` oder `2025`; bei Docker/Podman auch die begrenzte Form `Jahr-CUn` oder `Jahr-CUn-tag` dieser drei Jahre |
| `Port` | echter `Int32`, 1 bis 65535 |
| `Identity` | exakt `Kind` und `Value`; eine explizite Verbindungsidentität |
| `Profile` | obige geschlossene Profilform mit höchstens 30 Tagen |

CU-Formen haben eine positive CU-Nummer mit höchstens vier Ziffern ohne
führende Null und optional einen Suffix mit 1 bis 64 ASCII-Zeichen
`[a-z0-9][a-z0-9.-]*`. Groß-/Kleinschreibung und vollständiger Selektor bleiben
erhalten. Die Formprüfung liest keinen Katalog: Auch eine syntaktisch gültige
unbekannte CU kann eine Anfrage sein. Erst der lesende Metadatenresolver
verlangt die exakte Katalogbindung. Für Hyper-V bleiben nur die drei Basisjahre
zulässig; es entsteht kein Windows-CU-Provisionierungsvertrag.

`Identity.Kind=IP` verlangt eine kanonische numerische IP-Adresse, deren
Darstellung ordinal mit `IPAddress.ToString()` übereinstimmt. Abgekürzte,
hexadezimale, geklammerte oder gescopte Adressen sowie die unspezifizierten
Adressen werden abgewiesen. `Kind=DNS` verlangt 1 bis 253 ASCII-Zeichen,
Labels von 1 bis 63 kleinen Buchstaben/Ziffern mit nur inneren Bindestrichen,
ohne abschließenden Punkt. Numerische IP-Aliasse werden nicht als DNS-SAN
akzeptiert. Keine Auflösung und kein Wechsel zwischen IP- und DNS-Identität.
Zusätzliche SANs, Windows-CN, vollständige Runbindung, Erreichbarkeit und native
Clientunterstützung gehören zu späteren Verträgen.

`CLIENT_TRUST` ergänzt ausschließlich:

| Feld | Form |
|---|---|
| `ClientRef` | kanonische nichtleere UUID; spätere Client-/Identitätsbindung offen |
| `Platform`, `Store` | `windows` mit `CURRENT_USER_ROOT` oder `linux` mit `ISOLATED_CLIENT_CA_STORE` |
| `CertificateSha256` | exakt 64 kleine Hexzeichen; keine Prüfung der zugehörigen Zertifikatsbytes |
| `ClientStacks` | natives `Object[]` oder `String[]` mit exakt `SYSTEM_DATA_SQLCLIENT` und `ODBC_SQLCMD`, jeweils einmal |

Die Ausgabe ordnet die beiden Stacks in dieser Reihenfolge, unabhängig von
deren Eingabereihenfolge. Die Trustform beschreibt die gewünschte Preview;
Freigabe, Store-/Accountauflösung, Vorzustand, gemeinsame Nutzung, Import,
Journal, Ownership, Cleanup und Recovery sind noch nicht implementiert.
Insbesondere entsteht aus `CURRENT_USER_ROOT` keine Importfreigabe.

## Tests und Integration

Die synthetische Suite prüft unabhängige Sollprojektionen, Pflichtfelder,
Typ-/Frist-/Port-/DNSgrenzen, IP-SAN-Verwechslung, beide Clientstacks,
unveränderte Eingaben, tiefe Kopien und ausbleibende fremde Getter. Der
geschlossene Commandgraph und reine Funktionsdefinitionen beim Dot-Sourcing
werden separat geprüft. Der erforderliche Modulimport wird durch die
bestehende Pester-Modulprüfung abgedeckt; öffentliche Exporte bleiben unverändert.

Nur die exakte neue Produktdatei erhält im Selektor eine Offline-Ausnahme.
Ähnliche Pfade und gemischte Diffs erhalten ihre konservative Runtime- und
Capabilityauswahl. Die Suite ist zusätzlich im vollständigen statischen
Nightly-Gate registriert. Das ergänzt einen kurzen benötigten Vertragstest;
eine erneute vollständige Runtime-Matrix wird daraus nicht abgeleitet.
Tatsächlich ausgeführte Ergebnisse stehen in der
[Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md); native CA-,
Trust-, Erneuerungs-, SQL- und TLS-Matrixnachweise bleiben offen.
