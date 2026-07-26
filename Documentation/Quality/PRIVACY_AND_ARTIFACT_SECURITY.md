# Privacy- und Artefaktsicherheitsvertrag

| Merkmal | Wert |
|---|---|
| Status | `BINDING` |
| Stand | 2026-07-26 |
| Geltungsbereich | Repository, GitHub-Inhalte, Packages, Dokumentation, Tests und downloadbare Artefakte |
| Nicht automatisch exportierbar | lokale Runtime States, technische Evidence, Logs, Endpunkte, Pfade und Bindings |
| Zulässige öffentliche Attribution | `gecompat - Gerhard Pisch` |

## 1. Entscheidung

Reale personen-, benutzer-, kunden-, firmen-, organisations-, betriebs-, host- oder umgebungsbezogene Informationen dürfen niemals Bestandteil eines Repository-, GitHub-, Package- oder Downloadartefakts werden.

Das gilt unabhängig davon, ob die Informationen aus:

- Screenshots oder Hardcopys;
- Chats oder Uploads;
- vorhandenen Repositories;
- Logs und Diagnoseausgaben;
- Querytexten und Ausführungsplänen;
- Container-, VM-, Netzwerk- oder Storagezuständen;
- REST-Responses;
- lokalen Package- oder Runtime States

stammen.

Alle versionierten Beispiele, Testdaten, Namen, Endpunkte und Topologien verwenden ausschließlich eindeutig synthetische, generische Werte, die keine reale interne Struktur nachbilden.

## 2. Grenze zwischen Laufzeit und Artefakt

Das Lab muss reale lokale Runtimewerte verarbeiten können, um Ressourcen sicher zu verwalten. Dazu können gehören:

- lokale Hostpfade;
- tatsächliche Container-, VM-, Netzwerk- und Volume-IDs;
- lokale Ports und Endpunkte;
- Host-Capabilities;
- Prozess- und Healthinformationen;
- lokale Secret-Referenzen;
- technische SQL-, HTTP-, Hadoop- oder Betriebssystemevidenz.

Diese Werte sind innerhalb des lokalen, ignorierten Run Scopes zulässig. Sie werden dadurch nicht zu Repositoryinhalten.

Die verbindliche Grenze liegt beim Übergang zu einem persistierbaren oder übertragbaren Artefakt:

| Datenfluss | Reale lokale Werte zulässig? | Regel |
|---|---:|---|
| lokaler read-only Preflight | Ja | ausschließlich lokal, keine automatische Übertragung |
| lokaler Runtime State | Ja | ignorierter Scope, restriktive Rechte, kein Package-Inhalt |
| lokale technische Evidence | Ja, soweit für den Test erforderlich | nicht automatisch exportierbar |
| Konsolenausgabe | begrenzt | Secrets immer redigieren; schutzwürdige Werte nicht unnötig vervielfältigen |
| Sanitized Summary | Nein, außer ausdrücklich öffentliche Produktinformationen | nur synthetische IDs, Statuscodes und geprüfte Aggregate |
| Repository, Commit, PR, Issue oder Review | Nein | keine realen Identitäten, Umgebungen oder proprietären Strukturen |
| Lab Package | Nein | ausschließlich synthetische oder öffentliche freigegebene Inhalte |
| Testfixture oder Golden File | Nein | ausschließlich synthetisch oder öffentliche Fixture |
| Release- oder Downloadartefakt | Nein | vollständige Inhalts-, Metadaten- und Paketprüfung erforderlich |

## 3. Betroffene Informationsklassen

### 3.1 Identitäten

- Namen, Logins, Benutzer, Rollen, Gruppen und Service Accounts;
- E-Mail-Adressen, Telefonnummern und Adressen;
- Client-, Workstation-, Application- und Programmnamen;
- Session-, Request- oder Connectionkennungen aus realen Umgebungen;
- Zertifikatsinhaber und Kontoinformationen.

### 3.2 Organisation und Umgebung

- Firmen-, Kunden-, Mandanten-, Abteilungs- und Projektnamen;
- reale Hosts, Instanzen, Cluster, Domains, Listener und Netzwerke;
- reale IP-Adressen, DNS-Namen, URLs und API-Endpunkte;
- lokale Pfade, Shares, Laufwerksnamen und Gerätekennungen;
- reale Datenbank-, Schema-, Tabellen-, Spalten-, Job- oder Queue-Namen;
- proprietäre Topologien, Namenskonventionen und interne Metadatenstrukturen.

### 3.3 Secrets und Sicherheitsmaterial

- Passwörter;
- Tokens und API Keys;
- private Schlüssel;
- Zertifikate mit privatem Material;
- vollständige Connection Strings;
- SSH-Schlüssel;
- Cloud Credentials;
- Secret-Store-Exports;
- Zugangsdaten in URL, Header, Environment oder Command Line.

### 3.4 Benutzerdefinierte und technische Inhalte

- Querytexte mit Literalen oder Kommentaren;
- Ausführungspläne und Planparameter;
- REST-Request- und Responseinhalte;
- Hadoop-, Spark- oder Job-Payloads;
- Logs, Error-Outputs und Stack Traces;
- Extended-Events-, Query-Store- oder Trace-Daten;
- Screenshots von Verwaltungs- oder Monitoringtools;
- Dateiinhalte, Backups und Exporte.

## 4. Zulässige Inhalte

Zulässig sind:

- öffentliche Produkt-, Hersteller- und Projektnamen;
- öffentliche Quellenangaben;
- die beabsichtigte Attribution `gecompat - Gerhard Pisch`;
- generische technische Begriffe und Feldnamen;
- synthetische IDs wie `LAB-CORE-001`;
- generische Components wie `sql-primary`, `analytics-cluster` oder `api-under-test`;
- reservierte Testdomains wie `.test`, sofern keine reale Umgebung nachgebildet wird;
- eindeutig synthetische Ports, Versionen und Größenbeispiele;
- öffentliche und lizenzkonform verwendete Fixtures.

Öffentliche Attribution und Quellenangaben werden nicht als versehentlich extrahierte Umgebungsdaten behandelt.

## 5. Package-Regeln

Ein Lab Package darf enthalten:

- deklarative Manifeste;
- synthetische DataSet Generatoren;
- generische Installations- und Workloadskripte;
- öffentliche Referenzen;
- hashgebundene synthetische Artefakte;
- Assertions und Dokumentation.

Ein Lab Package darf nicht enthalten:

- lokale `.env`-Dateien;
- Runtime State;
- Secret-Dateien;
- reale Backups;
- reale Querypläne oder Logs;
- reale API-Responses;
- Hostbindings;
- lokale Zertifikate oder Schlüssel;
- Base Images, ISOs oder lizenzpflichtige Installationsmedien;
- exportierte Providerzustände.

## 6. Runtime-Binding-Regeln

Runtime Bindings besitzen eine `SensitivityClass` und `ExportPolicy`.

Vorgesehene Klassen:

```text
PUBLIC_SYNTHETIC
LOCAL_TECHNICAL
LOCAL_SENSITIVE
SECRET_REFERENCE
SECRET_VALUE
```

Regeln:

- `SECRET_VALUE` wird nicht im normalen Runtime State, Event oder Evidenceobjekt persistiert;
- `SECRET_REFERENCE` darf lokal persistiert werden, wenn sie keinen Secret-Wert offenlegt;
- `LOCAL_SENSITIVE` darf nicht in eine Sanitized Summary übernommen werden;
- `LOCAL_TECHNICAL` benötigt vor Export eine feldbezogene Prüfung;
- `PUBLIC_SYNTHETIC` ist nur zulässig, wenn der Wert tatsächlich synthetisch und nicht rückführbar ist.

## 7. Secret-Vertrag

- Secrets werden interaktiv, über einen lokalen Secret Store oder kurzlebige Prozessvariablen bezogen.
- Manifeste enthalten nur Secret Requirements und Referenzen.
- Ein Handler erhält nur die für seine Action erforderlichen Secrets.
- Secrets werden nicht in Command-Line-Argumenten verwendet, wenn ein sichererer Injection-Weg verfügbar ist.
- Logs und Events redigieren Secretwerte.
- Fehlerausgaben dürfen keine vollständigen Request Header, Connection Strings oder Environment-Dumps enthalten.
- Temporäre Secret-Dateien liegen ausschließlich unter einem ignorierten Run Scope, besitzen restriktive Rechte und werden im Cleanup entfernt.
- Beispielkonfigurationen enthalten kein funktionsfähiges Standardpasswort.

## 8. Externe Endpunkte

Für `ATTACHED`, `EXTERNAL_READ_ONLY` und `EXTERNAL_MUTABLE` gilt:

- konkrete Endpunkte stehen nur in lokaler Binding-Konfiguration;
- Packages referenzieren logische Component- und Interface-IDs;
- Egress, Protokoll und Secret Requirements sind im Plan sichtbar;
- produktive Endpunkte sind kein zulässiger Standardtarget;
- Responses werden nicht automatisch gespeichert oder exportiert;
- `EXTERNAL_MUTABLE` benötigt eine ausdrückliche lokale Freigabe und einen Cleanup-/Reversibility-Vertrag.

## 9. Lokale Laufzeitpfade

Mindestens folgende Pfade sind vollständig aus Git auszuschließen:

```text
.state/
.secrets/
.artifacts/
.cache/
.local/
.env
.env.*
```

Zusätzlich ausgeschlossen werden:

- VM- und Datenträgerimages;
- Containerexporte;
- Backups und Transaction-Log-Backups;
- Logs und Dumps;
- Zertifikate und private Schlüssel;
- generierte Plans und Runtime-Binding-Dateien;
- lokale Package Registries mit Hostbindings.

## 10. Logs und Fehlerausgaben

Ein Fehlerbericht enthält nur:

- Scope;
- stabilen Regel- oder Statuscode;
- betroffenen logischen Pfad oder Component-Bezug;
- Trefferanzahl;
- redigierte technische Ursache;
- nächsten Prüfschritt.

Der gefundene Secretwert, reale Endpoint, Benutzername oder sonstige Schutzwert wird nicht in ein neues Log kopiert.

## 11. Screenshots, Office-Dateien und Medien

Jedes Bild, Video, Office- oder PDF-Artefakt benötigt zusätzlich zur Textprüfung:

- visuelle Prüfung;
- Metadatenprüfung;
- Prüfung von Author, Company, Template und Last Modified By;
- Prüfung eingebetteter Medien und externer Beziehungen;
- Prüfung von Taskleisten, Fensterüberschriften, Browserleisten und Toolverbindungen;
- Prüfung von Alt-Text, Speaker Notes und Kommentaren;
- vollständige Entfernung nicht zulässiger Inhalte, nicht bloße optische Überdeckung.

Ein realer Screenshot wird nicht teilweise geschwärzt und als Beispiel übernommen. Sicherer ist eine vollständig synthetische Rekonstruktion.

## 12. Quellcode- und Scriptregeln

- Keine hart codierten realen Hosts, Endpunkte, Logins, Pfade oder Datenbanken.
- Keine Secrets in Kommentaren oder Testfixtures.
- Keine Debugausgabe vollständiger Environment- oder Stateobjekte.
- Keine Wildcard- oder Namenslöschung fremder Ressourcen.
- Beispielwerte sind eindeutig synthetisch.
- Tests erzeugen sensible Negativfixtures ausschließlich zur Laufzeit in temporären Verzeichnissen.
- Prüfergebnisse enthalten keine Fundwerte.

## 13. Sanitized Summary

Eine exportierbare Summary darf enthalten:

- Contract-, Package- und Scenario-Versionen;
- synthetische Run- und Component-IDs;
- Providerklasse, nicht konkrete Hostidentität;
- öffentliche Produktversionen;
- Status- und Finding-Codes;
- aggregierte oder normalisierte Messwerte;
- Assertionsergebnisse;
- Aussagegrenzen;
- Cleanupstatus.

Sie darf nicht enthalten:

- reale Endpunkte;
- lokale Pfade;
- Providerobjekt-IDs;
- Benutzer- oder Hostidentitäten;
- Secrets oder Secret Store References mit internem Bezug;
- ungeprüfte Logs, Querytexte, Pläne oder Responses.

## 14. Prüfvertrag vor Datei- und Git-Operationen

Vor dem Schreiben oder Versionieren werden mindestens geprüft:

1. beabsichtigter Zielpfad und Dateityp;
2. Ursprung der Inhalte;
3. Personen-, Firmen-, Kunden- und Organisationsbezüge;
4. Host-, Netzwerk-, Endpoint-, Pfad- und Gerätewerte;
5. Secrets, Tokens, Connection Strings und Schlüsselmaterial;
6. reale Datenbank- und Objektstrukturen;
7. Logs, Pläne, Responses und Diagnosewerte;
8. Metadaten und eingebettete Artefakte;
9. synthetische Eindeutigkeit aller Beispiele;
10. vollständiger Git-Diff und Lieferumfang.

Ist ein Treffer nicht eindeutig klassifizierbar, wird die Datei- oder Git-Operation angehalten und eine nicht sensitive Alternative verwendet.

## 15. Automatisierte Prüfung

Die spätere lokale Privacy-Prüfung soll mindestens erkennen:

- E-Mail-Adressen;
- IP-Adressen;
- GUIDs, soweit sie nicht explizit synthetisch erzeugt werden;
- UNC-, Benutzerprofil- und Home-Pfade;
- Private-Key-Marker;
- verdächtige Secret-Zuweisungen;
- vollständige Connection Strings;
- nicht generische Host- und Endpointmuster;
- binäre oder nicht erwartete Dateien;
- verbotene Runtime- und Medienartefakte;
- unerwartete Archiveinträge und Pfadtraversierung.

Die automatisierte Prüfung ist ein Blockierfilter und ersetzt keine kontextbezogene Review.

## 16. Vorgehen bei einem Fund

1. Verarbeitung vor Schreiben oder Git-Operation stoppen.
2. Fund nicht in ein neues Log kopieren.
3. Inhalt vollständig entfernen oder synthetisch rekonstruieren.
4. Falls das Artefakt nicht sicher neutralisierbar ist, verwerfen.
5. Alle betroffenen Prüfschichten erneut ausführen.
6. Bereits veröffentlichte Secrets zusätzlich außerhalb von Git widerrufen oder rotieren.

Eine Zustimmung hebt das Repositoryverbot für reale interne Informationen nicht auf. Die richtige Lösung ist eine nicht sensitive Fassung.

## 17. Abnahmekriterien

- Repository- und Runtime-Datenfluss sind klar getrennt.
- Packages und Beispiele sind ausschließlich synthetisch oder öffentlich freigegeben.
- Secrets gelangen weder in Manifeste noch in Events oder Evidence.
- Runtime Bindings besitzen Sensitivity und Export Policy.
- externe Endpunkte werden nur lokal gebunden.
- lokale State-, Secret-, Artifact- und Cachepfade sind ignoriert.
- Sanitized Summary und technische Evidence sind getrennt.
- Prüfberichte vervielfältigen keine Schutzwerte.
- eine unklare Klassifikation blockiert die Operation.
- öffentliche Attribution und Lizenztexte bleiben erhalten.
