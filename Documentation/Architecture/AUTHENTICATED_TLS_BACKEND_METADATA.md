# Private TLS-Backendmetadaten

| Merkmal | Wert |
|---|---|
| Status | `implemented`; ausschließlich API-Metadaten im ausgewählten Prozess |
| Stand | 2026-10-16 |
| Scope | `TLS001-BACKEND-01` aus [TLS-001a](../Project_Planning/TLS_001_ISOLATED_CA_DESIGN.md) |
| Implementierung | [`Private/AuthenticatedTlsBackend.ps1`](../../Private/AuthenticatedTlsBackend.ps1) |
| Prüfung | [`Invoke-AuthenticatedTlsBackendChecks.ps1`](../../Tests/Static/Invoke-AuthenticatedTlsBackendChecks.ps1) |

## Ausdrückliche Prozesswahl und Aussage

Die private Funktion `Get-LabAuthenticatedTlsBackendMetadata` verlangt
`Context=CURRENT_PROCESS` als echten String mit ordinal exakter Schreibweise.
Fehlende Werte, andere Kontexte, Casts und automatische Benutzer-/Hostwahl
werden abgewiesen. Sie besitzt keine Referenz-, Pfad- oder Remoteparameter und
erzeugt keine Client-, Signierer- oder CA-Registrierung. Der aktuelle Prozess
wird dadurch keinem `ClientRef` oder `AuthorityRef` zugeordnet.

Der Reader prüft ausschließlich öffentliche CLR-Metadaten für den Kandidaten
`DOTNET_X509`. Der interne Helper `Test-LabTlsBackendApi` prüft deklarierte
öffentliche Konstruktoren beziehungsweise Methoden mit exakten Parameter- und
Rückgabetypen sowie Instanz-/Staticzuordnung. Geerbte Methoden, offene Generics
und durch den Reflection-Binder angenäherte Basistypen zählen nicht. Kein
entdeckter PKI-Konstruktor und keine entdeckte PKI-Methode wird ausgeführt.

| API-ID | Geprüfte Oberfläche |
|---|---|
| `REQUEST_RSA_CONSTRUCTOR` | `CertificateRequest(String, RSA, HashAlgorithmName, RSASignaturePadding)` |
| `CSR_CREATE_DER` | `CertificateRequest.CreateSigningRequest()` mit Rückgabe `Byte[]` |
| `CSR_LOAD_DER` | statisches `LoadSigningRequest(Byte[], HashAlgorithmName, CertificateRequestLoadOptions, RSASignaturePadding)` mit Rückgabe `CertificateRequest` |
| `CERTIFICATE_CREATE` | `Create(X509Certificate2, DateTimeOffset, DateTimeOffset, Byte[])` mit Rückgabe `X509Certificate2` |
| `SAN_IP` | `SubjectAlternativeNameBuilder.AddIpAddress(IPAddress)` mit Rückgabe `Void` |
| `SAN_DNS` | `SubjectAlternativeNameBuilder.AddDnsName(String)` mit Rückgabe `Void` |

Die Microsoft-Referenzen beschreiben den
[RSA-Konstruktor](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.x509certificates.certificaterequest.-ctor?view=net-10.0)
und den [PKCS#10-Reader](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.x509certificates.certificaterequest.loadsigningrequest?view=net-10.0).
Die Loader-Optionen werden über den Typnamen in der vorhandenen Assembly
entdeckt. Fehlt der Typ auf einer älteren CLR, bleibt die Loader-API fehlend;
kein statischer Typverweis verhindert dann schon den Modulimport.
Es gibt weder Download noch OpenSSL-/certreq-Fallback oder Versionsannahme
als Ersatz für die tatsächliche API-Präsenz.

## Geschlossenes Ergebnis

Das Ergebnis hat ausschließlich `Success`, `Value`, `ErrorCode`. Eine gültige
Abfrage liefert `Success=true` mit `ErrorCode=null` und einer frischen
Projektion mit genau diesen Feldern:

- `ContractVersion=SqlServerLab.AuthenticatedTlsBackendMetadata/0.1`,
  `Context=CURRENT_PROCESS`, `Backend=DOTNET_X509`, `Status=METADATA_ONLY`;
- `Platform` als `windows`, `linux` oder `other`, die tatsächliche
  `RuntimeVersion` und die feste geordnete Liste `Apis` mit `Id` und echtem
  Boolean `Present`;
- `ApiStatus=COMPLETE`, wenn alle sechs Signaturen vorliegen, sonst
  `INCOMPLETE`;
- `RegistrationStatus=NOT_EVALUATED`, `KeyProtectionStatus=NOT_EXECUTED`,
  `SigningStatus=NOT_EXECUTED`, `ClientStatus=NOT_EVALUATED`, `Ready=false`
  und `MutationAllowed=false`.

Eine unvollständige API-Liste ist ein gültiger Metadatenbefund. Sie wird nicht
als erfolgreiche Backendqualifikation interpretiert. Ungültige Kontextwahl
liefert `TLS_BACKEND_CONTEXT_INVALID`, ein nicht lesbarer Metadatenbefund
`TLS_BACKEND_METADATA_UNAVAILABLE`; jeweils `Success=false` und `Value=null`.
Exceptions und rohe Diagnosewerte werden nicht weitergegeben.

API-Präsenz beweist keine RSA-/SHA-256-Ausführung, CSR-Signaturprüfung,
Keyablage/-schutz, Windows-CSP-/KeySpec-Eignung, Dateirechte, effektiven
Truststore oder SQL-Clientkompatibilität. Keine Identitäten, Zertifikate,
Schlüssel, Stores, Signiererdateien, Clientbinaries oder geladenen ODBC-Treiber
werden gelesen. Die Projektion enthält keine User-/Hostnamen, IDs, Pfade oder
Zertifikatswerte. Sie ist ein flüchtiger privater Befund ohne dauerhafte
Kontextbindung, Frischegarantie oder Mutationsautorität. Für spätere Aktionen
bleiben registrierter Kontext, frische native Bindung, konkrete Autorisierung
und die jeweilige Backend-/Clientqualifikation erforderlich.

## Tests und nächster Schritt

Die Tests verwenden eine PowerShell-Canaryklasse mit werfenden Konstruktoren
und Methoden. Metadatenabfragen lassen ihren Aufrufzähler bei null. Sie prüfen
abweichende Signaturen, geerbte/generische Methoden, StrictMode, geschlossene
Projektionen, getrennte Arrays, falsche Kontexttypen, fremde Getter, kulturell
ignorierbare Zusatzzeichen, sanitisierten Fehler und `INCOMPLETE` ohne Freigabe.
Der erlaubte Command-/Methodengraph und reine Definitionen beim Laden werden
separat geprüft. Ausgeführte Ergebnisse stehen in der
[Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md).

Nur die exakte neue Produktdatei erhält eine Offline-Ausnahme. Die fokussierte
Suite und ihre exakte Selektorregression kommen zusätzlich ins statische
Nightly-Gate; ähnliche Pfade und gemischte Runtimeänderungen behalten ihre
konservative Auswahl. Diese reine Metadatenprüfung braucht keine zusätzliche
Provider- oder Modellrunde. Unabhängiger Review und exakter CI-Pflichtgate
bleiben erforderlich.

Der [Registrierungsentwurf](../Project_Planning/TLS_001_CONTEXT_REGISTRATION_DESIGN.md)
konkretisiert die getrennten Client-, Signierkontext- und CA-Identitäten.
Registry, Keyschutz, CSR-Verarbeitung und alle PKI-/Trustaktionen sind noch
nicht implementiert.
