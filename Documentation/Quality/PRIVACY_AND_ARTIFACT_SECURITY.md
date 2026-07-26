# Privacy- und Artefaktsicherheitsvertrag

| Merkmal | Wert |
|---|---|
| Status | `BINDING` |
| Stand | 2026-07-26 |
| Geltungsbereich | Repository, GitHub-Inhalte, Packages, Dokumentation, Tests und downloadbare Artefakte |
| Lokaler Sonderbereich | Runtime State, technische Evidence, zulässige lokale Database Artifacts, Logs, Endpunkte, Pfade und Bindings |
| Zulässige öffentliche Attribution | `gecompat - Gerhard Pisch` |

## 1. Entscheidung

Reale personen-, benutzer-, kunden-, firmen-, organisations-, betriebs-, host- oder umgebungsbezogene Informationen dürfen niemals ungeprüft Bestandteil eines Repository-, GitHub-, Package- oder Downloadartefakts werden.

Das Verbot richtet sich gegen die **Persistierung und Übertragung schutzwürdiger Inhalte**, nicht gegen die technisch notwendige lokale Verarbeitung zulässiger Labartefakte.

Insbesondere wird unterschieden zwischen:

1. **versionierbaren Projektartefakten**;
2. **lokalen, ignorierten Runtime- und Artifact-Stores**;
3. **öffentlichen, lizenzkonform referenzierten Beispieldatenbanken**.

## 2. Grenze zwischen Laufzeit und Projektartefakt

Das Lab muss reale lokale Runtimewerte verarbeiten können, um Ressourcen sicher zu verwalten. Dazu können gehören:

- lokale Hostpfade;
- tatsächliche Container-, VM-, Netzwerk- und Volume-IDs;
- lokale Ports und Endpunkte;
- Host-Capabilities;
- Prozess- und Healthinformationen;
- lokale Secret-Referenzen;
- technische SQL-, HTTP-, Hadoop- oder Betriebssystemevidenz;
- lokale, ausdrücklich klassifizierte Nicht-Produktionsbackups.

Diese Werte sind innerhalb des lokalen, ignorierten Run- oder Artifact-Scopes zulässig. Sie werden dadurch nicht zu Repositoryinhalten.

| Datenfluss | Lokale reale Werte zulässig? | Regel |
|---|---:|---|
| lokaler read-only Preflight | Ja | ausschließlich lokal, keine automatische Übertragung |
| lokaler Runtime State | Ja | ignorierter Scope, restriktive Rechte, kein Package-Inhalt |
| lokaler Database-Artifact-Store | Ja, nach Klassifikation | keine automatische Git-, Issue-, PR- oder Downloadübernahme |
| lokale technische Evidence | Ja, soweit für den Test erforderlich | nicht automatisch exportierbar |
| Konsolenausgabe | begrenzt | Secrets redigieren; Schutzwerte nicht unnötig vervielfältigen |
| Sanitized Summary | nur freigegebene Felder | synthetische IDs, Statuscodes und geprüfte Aggregate |
| Repository, Commit, PR, Issue oder Review | Nein | keine realen Identitäten, Umgebungen oder proprietären Strukturen |
| Lab Package | nur deklarativ oder öffentlich freigegeben | keine lokalen Backupbytes oder Hostbindings |
| Testfixture oder Golden File | synthetisch oder öffentlich | Herkunft und Lizenz dokumentieren |
| Release- oder Downloadartefakt | nur nach vollständiger Prüfung | Inhalts-, Metadaten-, Lizenz- und Paketprüfung erforderlich |

## 3. Datenbankartefakte und Backups

### 3.1 Zulässige Klassen

```text
LAB_GENERATED
PUBLIC_SAMPLE
USER_PROVIDED_NON_PRODUCTION
```

#### `LAB_GENERATED`

Ein Backup einer synthetischen oder anderweitig zulässigen Labdatenbank darf lokal erzeugt, gehasht, im ignorierten Artifact Store aufbewahrt und in späteren Runs wiederverwendet werden.

#### `PUBLIC_SAMPLE`

Eine öffentliche Demo- oder Beispieldatenbank darf über einen Katalog referenziert, automatisiert heruntergeladen, lokal gecacht und wiederhergestellt werden, wenn Quelle, Lizenz, Hash, Größe und Versionskompatibilität dokumentiert sind.

#### `USER_PROVIDED_NON_PRODUCTION`

Ein lokales Entwicklungs-, Test- oder Lab-Backup darf angebunden werden, wenn der Benutzer es ausdrücklich als Nicht-Produktionsartefakt klassifiziert. Das Lab erfasst Hash, Größe, Restore-Kompatibilität, lokale Retention und Cleanup Policy.

### 3.2 Blockierte Klassen

```text
PRODUCTION_DATA
UNKNOWN
```

Blockiert sind:

- Produktionsbackups;
- aus Produktivsystemen extrahierte reale Daten;
- Artefakte unbekannter Herkunft;
- nicht ausreichend klassifizierte Backups;
- Backups mit nicht freigegebenen Personen-, Kunden-, Firmen-, Organisations- oder Umgebungsdaten;
- Backups mit eingebetteten Secrets oder Schlüsselmaterial, soweit diese nicht über einen getrennten zulässigen Secret-Vertrag sicher auflösbar sind.

### 3.3 Repositorygrenze

Ein Lab Package darf eine `DatabaseArtifactDefinition`, Hashes, öffentliche Quellen und logische lokale Requirements enthalten. Es darf nicht automatisch enthalten:

- lokale Backupbytes;
- absolute lokale Backup- oder Restorepfade;
- reale Datenbank- oder Objektinventare aus einem lokalen Backup;
- Backupmetadaten mit internen Identitäten;
- aus dem Restore abgeleitete ungeprüfte Beispielausgaben.

Die Übergabe eines lokalen Backups erfolgt über eine lokale Binding-Konfiguration oder einen ignorierten Artifact Store.

## 4. Betroffene Informationsklassen

### 4.1 Identitäten

- Namen, Logins, Benutzer, Rollen, Gruppen und Service Accounts;
- E-Mail-Adressen, Telefonnummern und Adressen;
- Client-, Workstation-, Application- und Programmnamen;
- Session-, Request- oder Connectionkennungen aus realen Umgebungen;
- Zertifikatsinhaber und Kontoinformationen.

### 4.2 Organisation und Umgebung

- Firmen-, Kunden-, Mandanten-, Abteilungs- und Projektnamen;
- reale Hosts, Instanzen, Cluster, Domains, Listener und Netzwerke;
- reale IP-Adressen, DNS-Namen, URLs und API-Endpunkte;
- lokale Pfade, Shares, Laufwerksnamen und Gerätekennungen;
- reale Datenbank-, Schema-, Tabellen-, Spalten-, Job- oder Queue-Namen;
- proprietäre Topologien, Namenskonventionen und interne Metadatenstrukturen.

### 4.3 Secrets und Sicherheitsmaterial

- Passwörter;
- Tokens und API Keys;
- private Schlüssel;
- Zertifikate mit privatem Material;
- vollständige Connection Strings;
- SSH-Schlüssel;
- Cloud Credentials;
- Secret-Store-Exports;
- Zugangsdaten in URL, Header, Environment oder Command Line.

### 4.4 Benutzerdefinierte und technische Inhalte

- Querytexte mit Literalen oder Kommentaren;
- Ausführungspläne und Planparameter;
- REST-Request- und Responseinhalte;
- Hadoop-, Spark- oder Job-Payloads;
- Logs, Error-Outputs und Stack Traces;
- Extended-Events-, Query-Store- oder Trace-Daten;
- Screenshots von Verwaltungs- oder Monitoringtools;
- lokale Backups, Exporte und Restore-Ausgaben.

## 5. Zulässige versionierbare Inhalte

Zulässig sind:

- öffentliche Produkt-, Hersteller- und Projektnamen;
- öffentliche Quellen- und Lizenzangaben;
- die beabsichtigte Attribution `gecompat - Gerhard Pisch`;
- generische technische Begriffe und Feldnamen;
- synthetische IDs wie `LAB-CORE-001`;
- generische Components wie `sql-primary`, `hadoop-support` oder `api-mock`;
- reservierte Testdomains wie `.test`;
- eindeutig synthetische Ports, Versionen und Größenbeispiele;
- öffentliche und lizenzkonform verwendete Fixtures;
- deklarative Public-Sample-Katalogeinträge;
- Hashes lokaler Artefakte, sofern dadurch keine schutzwürdige Information offengelegt wird.

## 6. Package-Regeln

Ein Lab Package darf enthalten:

- deklarative Manifeste;
- synthetische DataSet Generatoren;
- generische Installations- und Workloadskripte;
- öffentliche Referenzen;
- Public-Sample-Katalogeinträge;
- hashgebundene synthetische Artefakte;
- lokale Artifact Requirements ohne reale Pfade;
- Assertions und Dokumentation.

Ein Lab Package darf nicht enthalten:

- lokale `.env`-Dateien;
- Runtime oder Recovery State;
- Secret-Dateien;
- Produktions- oder unbekannte Backups;
- lokale Backupbytes ohne eigenen geprüften Liefervertrag;
- reale Querypläne oder Logs;
- reale API-Responses;
- Hostbindings;
- lokale Zertifikate oder Schlüssel;
- Base Images, ISOs oder lizenzpflichtige Installationsmedien;
- exportierte Providerzustände.

## 7. Runtime-Binding- und Secret-Regeln

Runtime Bindings besitzen `SensitivityClass` und `ExportPolicy`.

```text
PUBLIC_SYNTHETIC
PUBLIC_REFERENCE
LOCAL_TECHNICAL
LOCAL_SENSITIVE
SECRET_REFERENCE
SECRET_VALUE
```

- `SECRET_VALUE` wird nicht in normalem Runtime State, Event oder Evidenceobjekt persistiert;
- `SECRET_REFERENCE` darf lokal persistiert werden, wenn sie keinen Secret-Wert offenlegt;
- `LOCAL_SENSITIVE` darf nicht in eine Sanitized Summary übernommen werden;
- `LOCAL_TECHNICAL` benötigt vor Export eine feldbezogene Prüfung;
- `PUBLIC_REFERENCE` ist für geprüfte Quellen-, Lizenz- und Katalogreferenzen vorgesehen;
- `PUBLIC_SYNTHETIC` ist nur zulässig, wenn der Wert tatsächlich synthetisch und nicht rückführbar ist.

Secrets werden interaktiv, über einen lokalen Secret Store oder kurzlebige Prozessvariablen bezogen. Temporäre Secret-Dateien liegen ausschließlich unter einem ignorierten Run Scope und werden im Cleanup entfernt.

## 8. Externe Endpunkte und Downloads

Für externe Endpunkte und öffentliche Artifact-Downloads gilt:

- konkrete lokale oder private Endpunkte stehen nur in lokaler Binding-Konfiguration;
- Packages referenzieren logische Component-, Interface- oder öffentliche Katalog-IDs;
- Egress, Protokoll, Quelle, Lizenz und Secret Requirements sind im Plan sichtbar;
- produktive Endpunkte sind kein zulässiges Standardtarget;
- Responses werden nicht automatisch gespeichert oder exportiert;
- Downloads werden vor Verwendung gegen Hash oder Prüfsumme validiert;
- öffentliche Caches liegen ausschließlich unter ignorierten Pfaden.

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
- heruntergeladene öffentliche Beispieldatenbanken;
- Restore- und Backupmetadaten aus lokalen Runs;
- Logs und Dumps;
- Zertifikate und private Schlüssel;
- generierte Plans und Runtime-Binding-Dateien;
- lokale Package Registries mit Hostbindings.

## 10. Logs, Screenshots und Fehlerausgaben

Ein Fehlerbericht enthält nur Scope, stabilen Regel- oder Statuscode, betroffenen logischen Pfad, Trefferanzahl, redigierte technische Ursache und nächsten Prüfschritt.

Der gefundene Secretwert, reale Endpoint, Benutzername, lokale Backupinhalt oder sonstige Schutzwert wird nicht in ein neues Log kopiert.

Bilder, Office- und PDF-Artefakte benötigen zusätzlich visuelle, Paket-, Metadaten- und Beziehungsprüfung. Reale Screenshots werden nicht bloß teilweise geschwärzt und als Beispiel übernommen.

## 11. Sanitized Summary

Eine exportierbare Summary darf enthalten:

- Contract-, Package-, Scenario- und SQL-Katalogversionen;
- synthetische Run- und Component-IDs;
- Providerklasse, nicht konkrete Hostidentität;
- öffentliche Produktversionen;
- Artifact Class und öffentliche Katalog-ID, nicht lokalen Pfad oder Inhalt;
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
- Secrets oder interne Secret Store References;
- lokale Backupinhalte oder interne Backupmetadaten;
- ungeprüfte Logs, Querytexte, Pläne oder Responses.

## 12. Prüfvertrag vor Datei- und Git-Operationen

Vor dem Schreiben oder Versionieren werden mindestens geprüft:

1. beabsichtigter Zielpfad und Dateityp;
2. Ursprung und Klassifikation der Inhalte;
3. Personen-, Firmen-, Kunden- und Organisationsbezüge;
4. Host-, Netzwerk-, Endpoint-, Pfad- und Gerätewerte;
5. Secrets, Tokens, Connection Strings und Schlüsselmaterial;
6. reale Datenbank- und Objektstrukturen;
7. Produktions-, unbekannte oder lokal eingebettete Backups;
8. Logs, Pläne, Responses und Diagnosewerte;
9. Metadaten und eingebettete Artefakte;
10. synthetische Eindeutigkeit aller Beispiele;
11. vollständiger Git-Diff und Lieferumfang.

Ist ein Treffer nicht eindeutig klassifizierbar, wird die Datei- oder Git-Operation angehalten und eine nicht sensitive Alternative verwendet.

## 13. Automatisierte Prüfung

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
- Backup-, Runtime- und Medienartefakte an versionierbaren Pfaden;
- unerwartete Archiveinträge und Pfadtraversierung.

Die automatisierte Prüfung ist ein Blockierfilter und ersetzt keine kontextbezogene Review.

## 14. Abnahmekriterien

- Repository-, Runtime- und Artifact-Datenfluss sind klar getrennt.
- Lab-erzeugte Backups können lokal gespeichert und wiederverwendet werden.
- öffentliche Beispieldatenbanken können katalogisiert, geladen und verifiziert werden.
- lokale Nicht-Produktionsbackups können gebunden werden, ohne sie zu versionieren.
- Produktions- und unbekannte Backups bleiben blockiert.
- Packages und Beispiele sind synthetisch, deklarativ oder öffentlich freigegeben.
- Secrets gelangen weder in Manifeste noch in Events oder Evidence.
- Runtime Bindings besitzen Sensitivity und Export Policy.
- externe Endpunkte werden nur lokal gebunden.
- lokale State-, Secret-, Artifact- und Cachepfade sind ignoriert.
- Sanitized Summary und technische Evidence sind getrennt.
- Prüfberichte vervielfältigen keine Schutzwerte.
- eine unklare Klassifikation blockiert die Operation.
- öffentliche Attribution und Lizenztexte bleiben erhalten.
