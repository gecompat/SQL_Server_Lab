# Autorisierte Penetrationstest-Werkzeuge: Beschaffungsbacklog

| Merkmal | Stand |
|---|---|
| Status | `PLANNED` – konkretisierter Implementierungszielvertrag |
| Stand | 2026-09-11 |
| Umfang | Automatisierbare Beschaffung per Manifest UND direkt aufrufbarer öffentlicher API; getrennte Windows-/Linux-Artefakte |
| Implementierung / Runtime-Abnahme | `NOT_IMPLEMENTED` / `NOT_EXECUTED` |
| Freigegebene Werkzeuge | Keine; dieser Slice enthält weder reale Katalogeinträge noch Beschaffungsfreigaben |

## Zweck und Grenze

Das Lab soll geprüfte Werkzeugartefakte für ausdrücklich autorisierte
Sicherheitsprüfungen eigener, isolierter SQL-Server-Labs reproduzierbar
beschaffen können. Zulässige Zwecke sind beispielsweise die Prüfung der
SQL-TLS-Konfiguration oder der für eine Labinstanz vorgesehenen Erreichbarkeit.
Ein katalogisierter Zweck beschreibt den späteren Testbedarf; er führt keinen
Test aus und erteilt keine Berechtigung für ein Zielsystem.

Beschaffung endet mit verifizierten, geschützt aufbewahrten Bytes und einem
lokalen Receipt. Installation, Entpacken, Gasttransfer, Image-Build, Ausführung
(auch Versionsproben), Scans, Exploitation und Änderungen an Firewall, Netzwerken
oder Schutzsoftware gehören nicht zu diesem Slice. Es gibt keine automatische
Hostinstallation, keinen Autostart und keine Schutzsoftware-Ausnahme. Fachliche
Szenarien verbleiben entsprechend dem [Projektkontext](../../.ai/PROJECT_CONTEXT.md)
beim jeweiligen Consumer; Lab verantwortet den generischen Beschaffungsvertrag.

Die nachfolgend genannten neuen Felder, Verträge und Cmdlets sind
**Entwurfsnamen, keine verfügbare API**. Bestehende Schemas, Kataloge, Exports
und Handler werden durch dieses Dokument nicht erweitert. Die Arbeitspakete
verwenden beschreibende Namen, keine neu zugeteilten fortlaufenden Projekt-IDs.

## Geprüfter Ist-Stand und Wiederverwendung

| Quelle | Vorhandener Vertrag und verbleibende Lücke |
|---|---|
| [Softwarekatalog](../../Catalogs/software.json), [Schema](../../Schemas/software-catalog.schema.json), [Resolver](../../Private/SoftwareCatalog.ps1) | SQL-External-Runtimes und SqlPackage mit Varianten, Plattform, Provider und Hashbindung. Kein Pentest-Katalog; die bestehende ID-Auswahl ist geschlossen. |
| [ResourceSet-Kern](../../Private/ResourceSet.ps1), [Plan](../../Public/Get-SqlServerLabResourcePlan.ps1), [Save](../../Public/Save-SqlServerLabResourceSet.ps1) | Direkter Prefetch für Samples und unterstützte Windows-/Hyper-V-External-Runtimes; Planung, Cacheprüfung und Beschaffung getrennt. Keine allgemeine Linux- oder Pentest-Beschaffung. |
| [Manifestschema](../../Schemas/lab-manifest.schema.json), [Parser](../../Private/ManifestParser.ps1), [Exports](../../SqlServerLab.psd1) | Vorhandene Software-Intents sind keine Beschaffungsfreigabe. Es gibt keinen dedizierten Pentest-Intent oder öffentlichen Pentest-Befehl. |
| [Artefaktzielvertrag](../Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md), [Privacyvertrag](../Quality/PRIVACY_AND_ARTIFACT_SECURITY.md) | Hash, Quarantäne, lokale Aufbewahrung und sanitisierte Projektionen sind Anknüpfungspunkte. Sample-Trust und bestehende lokale Receipts autorisieren keine Sicherheitswerkzeuge. |
| [Interner Scenario-Slice](SCENARIO_CONTRACT_BACKLOG.md) | Nicht ausführbare Metadaten; kein geeignetes Transportmittel für freie Commands oder zusätzliche Ausführungsrechte. |

Wiederverwendet werden sollen geprüfte Primitive für Pfadsicherheit, Transfers,
Hashing, Locks und atomare Veröffentlichung. Der neue Beschaffungsdienst erhält
eine eigene strikte Policy. Er darf keine permissiveren Sample-Fallbacks erben.
Insbesondere gelten `TrustUnknownArtifact`, `SUPPORTED` im Softwarekatalog und
ein normaler Provider-Start nicht als Pentest-Freigabe. Die bestehenden
Standardauswahlen der Ressourcen-API bleiben ohne Sicherheitswerkzeuge.

## Gemeinsamer Vertrag für Manifest und Direktaufruf

Ein neuer typisierter Beschaffungsdienst normalisiert beide Eingänge auf
denselben Request, prüft dieselbe Policy und erzeugt denselben PlanHash.
Interne Funktionen werden nicht als Benutzer-API angeboten.

| Geplanter Eingang | Zulässige Angaben und Verhalten |
|---|---|
| `instances[].toolAcquisition[]` | Explizite `toolId`, exakte `variantId`, `purposeId`, Aktion ausschließlich `acquire`. SQL-Version, Zielbetriebssystem und Provider werden aus derselben Instanz aufgelöst; bei Auto-Auswahl muss die Bindung vor der Freigabe feststehen. |
| `Get-SqlServerLabSecurityToolPlan` | Direkte IDs wie im Manifest plus typisierter Zielbeschreibung (SQL-Version, OS/Distribution, Architektur, exakter Provider) oder lokaler Run-/Instanzbindung. Ohne laufendes Lab möglich. Keine Hostnamen, IPs oder Commands als Zielangaben. Read-only und ohne Netzwerkaufruf. |
| `Save-SqlServerLabSecurityTool` | Exakte lokale Plan-ID und separate Approval-ID; kein freies Planobjekt als Autorität. Beschafft nur den erneut validierten Plan. `WhatIf` darf weder Netzwerkzugriff noch State-, Cache- oder Trust-Schreibzugriffe auslösen. |
| Manifest-/Batch-Ausführung | Vor Provider-Arrange denselben Dienst mit separat lokal gebundener Approval-ID aufrufen. Ein Manifest enthält niemals seine eigene Freigabe. Fehlende Freigabe ergibt einen sichtbaren Blocker, im unbeaufsichtigten Lauf ohne Prompt oder Download. |

Entwurfsverträge: `SqlServerLab.SecurityToolRequest/1.0`,
`SqlServerLab.SecurityToolPlan/1.0` und
`SqlServerLab.SecurityToolReceipt/1.0`. Alle Objekte erhalten geschlossene
Feldmengen; unbekannte Felder, doppelte widersprüchliche Anforderungen,
Wildcard-IDs, implizites `latest` und freie URLs, Pfade, Header, Shelltexte,
Installationsargumente oder Post-Hooks werden vor Seiteneffekten abgelehnt.

Der portable Request bindet Zweck, vollständige Artefaktmenge und Zieltuple.
Der lokale Plan ergänzt Katalog-/Policy-Revision samt Hash, Quell-IDs,
SHA-256-Werte, Signaturanforderungen, Speicherbinding, Größen-/Zeit-/Retrylimits,
Netzwerkziele, Retention, Cleanup, Ablaufzeit und Operations-ID. Eine kanonische,
versionierte Serialisierung erzeugt den PlanHash; Laufzeitstempel oder die
Herkunft des Eingangs dürfen äquivalente Requests nicht fachlich verändern.
Gleiche Inputs einschließlich lokaler Bindung müssen über beide Eingänge
denselben wirksamen Plan ergeben.

Eine Approval-ID reist nur über lokale Aufruf-/Queue-Bindings; exportierbare
Manifeste und Locks enthalten keine lokale Autorität. Ein manifestgebundener
Prefetch darf ausdrücklich auch ohne anschließende Laberstellung enden.
Ein fehlgeschlagenes Required-Artefakt blockiert die Provisionierung; es gibt
keinen stillen Best-Effort-Erfolg. Bereits beschaffte Bytes eines Teilplans
erteilen keine Installations- oder Ausführungsfreigabe.

## Allowlist, Herkunft und Integrität

Der geplante dedizierte Sicherheitswerkzeugkatalog beginnt leer. Eine Aufnahme
benötigt Review durch die Projektverantwortlichen und folgende Pflichtdaten:

| Bereich | Pflichtbindung |
|---|---|
| Identität und Nutzen | Unveränderliche Tool-/Varianten-ID, exakte Version, konkreter SQL-Labzweck, Reviewstatus `APPROVED`, `BLOCKED` oder `RETIRED`; unbekannt bedeutet blockiert. |
| Plattform | Ziel-OS, Windows-Version beziehungsweise Linux-Distribution/-Version, Architektur, SQL-Kompatibilität und ausdrücklich zulässige Provider. |
| Quelle | Geprüfte offizielle Releasequelle oder separat genehmigter Mirror, exakter credentialfreier HTTPS-Locator, feste Quell-ID, erlaubte Redirectziele und Authentizitätsquelle. Keine benutzerdefinierte URLauflösung. |
| Integrität | Erwarteter SHA-256 vor Download, erwartete Länge und harte Maximalgröße für jedes Artefakt; Hashherkunft, Signaturverfahren, gebundener Publisher/Schlüssel und Trust-Policy-Revision. |
| Rechte und Pflege | Primäre Lizenz-/Nutzungsquelle, geprüfte Version/Datum, erforderliche Hinweise, lokale Nutzung und Weitergaberechte getrennt, Reviewgültigkeit, Widerruf und verantwortliche Reviewrolle. |
| Abhängigkeiten | Vollständig geschlossene, versions-/hash-/quellgebundene Artefaktliste; keine Laufzeitauflösung durch Paketmanager, Plugins, Bootstrapper oder Selbstupdates. |

Ein Hash aus derselben ungeprüften Antwort beweist keine Herkunft. Dieser
erste automatisierte Slice verlangt zusätzlich verifizierbare Herausgeber-
Authentizität: unter Windows Authenticode oder ein separat signiertes
Release-Inventar, unter Linux eine signierte Release-/Paketmetadatenkette, die
den exakten Artefakthash bindet. Ein Windows-Archiv benötigt die signierte
äußere Hashliste; es wird nicht zur Signaturprüfung ausgeführt oder entpackt.
Fehlende Signatur oder unbekannter Herausgeber ergibt `BLOCKED`, ohne
Trust-on-first-use-Schalter. Signaturprüfung ersetzt niemals den exakten Hash.

Trust Anchors und Schlüsselfingerprints stammen aus dem geprüften Katalog-
Review, nicht aus dem Download selbst. Rotation, Widerruf, abgelaufene Reviews,
fehlende oder veraltete Revocation-Evidence und nicht eindeutig prüfbare
Signaturen sperren die Beschaffung beziehungsweise Wiederverwendung. Zulässige
Zeitstempelregeln sind pro Verfahren im Review festzulegen. Verifikatoren
dürfen keine versteckten OCSP-/CRL- oder Schlüsselabrufe durchführen: notwendige
Abrufe werden als gebundene Planaktionen freigegeben; ohne frische lokale
Evidence bleibt Offline-Verifikation blockiert.

HTTPS erzwingt normale Zertifikatsprüfung. Redirects sind standardmäßig aus;
ein katalogisierter Redirect wird bei jedem Hop erneut auf exaktes Ziel und
Transport geprüft. Loopback, private/link-local Ziele, Metadatendienste,
TLS-Downgrade und DNS-Rebinding müssen im Produktionspfad vor Verbindung
abgelehnt werden; Tests verwenden ausschließlich einen injizierten Transport.
Keine globalen Proxy-/Zertifikatsänderungen, keine Ambient-Credentials und
keine automatischen Login- oder EULA-Aktionen. Ein blockierter Eintrag darf
nicht durch Mirror-, Versions- oder Provider-Fallback ersetzt werden.

## Plattform- und Providerbindung

Beschaffung läuft auf dem Controller. Zielplattform bezeichnet die spätere
Werkzeugverwendung, nicht das Controller-OS. Der Controller lädt beispielsweise
Linux-Bytes unter Windows, ohne sie zu starten. Die Matrix ist ein
Implementierungsziel und behauptet keine bereits belegte Unterstützung.

| Zielvariante | Geplanter erster Providerpfad | Separat benötigte Evidence |
|---|---|---|
| Windows, exakt katalogisierte Version und Architektur | `hyperv` | Windows-Controller: NTFS-ACL, Reparse-Point-Schutz, Windows-Signaturprüfung und lokaler Receipt; spätere Gastnutzung separat. |
| Linux, exakt katalogisierte Distribution und Architektur | `docker` | Controller unter Windows und Linux: Hash-/Signaturkette, Pfadschutz und jeweilige Aufbewahrungsrechte; Docker-Zielbindung separat geprüft. |
| Linux, exakt katalogisierte Distribution und Architektur | `podman` | Eigene Podman-Zielbindungsprüfung; Docker-Evidence wird nicht übernommen. Controller-Abnahme wie oben. |
| Linux unter Hyper-V, Windows-Container, native Hostinstallation, entfernte Controller | Im ersten Slice `UNSUPPORTED` | Eigener späterer Capability-/Ownership-/Abnahmevertrag erforderlich. |

Der Offline-Plan benötigt keinen laufenden Provider. Er beweist lediglich die
katalogisierte Zielkompatibilität. Bei existierenden Runs gilt ausschließlich
die gespeicherte Provider-/Scope-/Instanzbindung; Auto-Detect ersetzt sie nicht.
Fehlende oder widersprüchliche Bindung ergibt einen Blocker. Eine spätere
Übergabe an einen Gast/Container muss dessen aktuelle Identität gesondert
prüfen und liegt außerhalb dieser Beschaffungsabnahme.

## Freigabe und unbeaufsichtigte Verarbeitung

Katalogaufnahme und konkrete Beschaffungsfreigabe sind getrennt. Die erste
prüft Werkzeug, Rechte, Quelle und Verifikationsverfahren; die zweite erlaubt
die im vollständigen lokalen Plan dargestellten Datei- und Netzwerkeffekte.
Sie bestätigt auch die Beschränkung auf autorisierte SQL-Labs. Keine davon
autorisiert Installation, Toolausführung oder Tests gegen Systeme.

Ein lokaler Freigabedienst erzeugt den Receipt erst nach ausdrücklicher
Bestätigung durch den berechtigten Operator. Er bindet PlanHash, Operations-ID,
Katalog-/Policy-Hash, Controller-/Speicherbinding, Zieltuple, Zweck, Artefakte,
Netzwerk-/Speicherlimits und Ablaufzeit. JSON aus einem Manifest, ein Boolean
`approved`, `-Force` oder `-Confirm:$false` sind keine Autorität. Issuer und
Integrität müssen über einen geschützten lokalen Store beziehungsweise eine
verifizierte Signatur/MAC geprüft werden. Private Schlüssel und Operatorwerte
bleiben lokal. Ein lokaler Administrator liegt außerhalb der Schutzgrenze;
der Slice verspricht keine Isolation gegen einen kompromittierten Controller.

Eine ausdrückliche Freigabe darf den vollständigen begrenzten Plan einschließlich
definierter Retries und Resume abdecken. Unbeaufsichtigte Läufe nutzen sie ohne
erneute Rückfrage nur innerhalb dieser Bindung und Gültigkeit. Die Verwendung
wird operationsgebunden atomar registriert; Replay darf keine neue Operation
autorisieren. Ablauf, Widerruf, andere Bytes, Quelle, Zielbindung, Policy oder
zusätzliche Effekte verlangen einen neuen Plan und eine neue Freigabe.
Auch ein Cache-Hit muss aktuelle Policy und diese lokale Autorität erfüllen.

## Aufbewahrung, Fehler und Recovery

Payloads liegen in einer eigens registrierten, ausschließlich lokalen
Security-Tool-Ablage außerhalb des Checkouts und außerhalb gemeinsam genutzter
Sample-/Release-Bibliotheken. Der Speicherplan bindet einen stabilen lokalen
Location-Identifier; Dateipfade werden ausschließlich intern abgeleitet.
StateRoot enthält Journal und Receipts, keine automatisch exportierten Bytes.
Windows verwendet restriktive ACLs für Operator/Dienst, Linux private
Verzeichnisse und Dateien ohne Execute-Bit. `noexec` kann zusätzlich schützen,
ist aber kein Nachweis, dass ein Interpreter Bytes nicht laden kann. Unsichere
ACLs, nicht prüfbare Rechte oder ein nicht lokal gebundener Store blockieren.

Der Ablauf lautet:

1. Request, Policy, Zieltuple, Approval, Grenzen und Store vor Mutation prüfen.
2. Operationslock und Artefaktlease erwerben; Ownership, Vorgängerzustand und
   Cleanup vor dem ersten Schreibzugriff im lokalen Journal festhalten.
3. In eine exklusive, operationsgebundene Staging-Datei laden; feste Timeouts,
   Maximalbytes, begrenzte Retries und Abbruch anwenden. Keine Archive öffnen.
4. Länge, vollständigen Hash und Signatur prüfen. Fehlerbytes bleiben gesperrt
   in Quarantäne oder werden nach der freigegebenen Retention entfernt.
5. Unmittelbar vor Veröffentlichung Pfadbindung, Linkfreiheit und Rechte erneut
   prüfen; verifizierte Bytes atomar in den inhaltsadressierten Store übernehmen.
6. Receipt atomar committen, eigene temporäre Dateien entfernen und Lease lösen.

Gegen Pfadwechsel sind Symlinks, Junctions, Reparse Points, Hardlinks,
Windows-ADS, UNC-Ziele und Traversal zu sperren; Handle-/Identitätsprüfung muss
das Rennen zwischen Prüfung und Schreiben abdecken. Fremde vorhandene Dateien
werden nie überschrieben oder gelöscht. Gleiche Hashes erlauben Byte-Deduplikation,
aber keine gemeinsame Freigabe für andere Varianten, Plattformen oder Zwecke.

Ein Abbruch hinterlässt einen journalisierten Zustand. Resume prüft Ownership,
Lease, vollständige Bytes und aktuelle Freigabe erneut. Unvollständige Downloads
werden im ersten Slice nicht per HTTP-Range fortgesetzt. Nach Veröffentlichung
ohne Receipt darf Resume nur dieselben revalidierten Bytes derselben Operation
abschließen. Unklarer Zustand ergibt `RECOVERY_REQUIRED`; parallele Operationen
dürfen sich weder überschreiben noch gegenseitig bereinigen.

Das Ergebnis unterscheidet `PLANNED`, `APPROVAL_REQUIRED`, `BLOCKED`,
`UNSUPPORTED`, `ACQUIRED`, `FAILED` und `RECOVERY_REQUIRED`. `ACQUIRED` verlangt
alle vorgesehenen Postconditions und erfolgreiches temporäres Cleanup;
es bedeutet weder installiert noch ausführbar getestet. Fehlerursache und
Cleanupstatus bleiben getrennt. Quarantäne wird nie automatisch promoviert.
Persistente Bytes haben eine explizite Retention; ihre Entfernung benötigt
exakte Ownership und Referenz-/Leaseprüfung und ist kein Nebeneffekt von
Run-Remove. Widerruf sperrt vorhandene Bytes sofort für weitere Übergaben,
ohne fremde Dateien zu löschen.

Öffentliche Ergebnisse verwenden eine Feld-Allowlist aus synthetischen
Referenzen, Status, Counts und freigegebenen Metadaten. Lokale Pfade,
Operatoridentitäten, reale Runbindings, Rohfehler, HTTP-Header und Zugangsdaten
werden weder in Git noch PR, Manifestexport oder Release übernommen. Logs,
Freigaben und Receipt-Rohdaten bleiben in geschütztem lokalem State.

## Umsetzungsreihenfolge und Abnahmekriterien

Alle folgenden Arbeitspakete sind `PLANNED`. Die Reihenfolge beschreibt
Abhängigkeiten; keine Tabellenzeile ist eine Implementierungsfreigabe für
Downloads, Installationen oder Ausführung in dieser Dokumentationswelle.

| Arbeitspaket | Ergebnis und Abnahmegrenze | Abhängigkeit |
|---|---|---|
| Katalog- und Trust-Vertrag | Dediziertes geschlossenes Schema mit synthetischen Fixtures; leere produktive Allowlist; explizite Trust-Anchor-/Review-/Widerrufsregeln. Alte Software- und Sampleverträge bleiben unverändert gültig. | Dieser Zielvertrag |
| Read-only Plan | Gemeinsame Requestnormalisierung, reproduzierbarer PlanHash, Quellen-/Plattform-/Providerblocker und mutationsfreies Preview. Plan darf keine Transport- oder Prozessaufrufe auslösen. | Katalog- und Trust-Vertrag |
| Lokale Freigabe | Geschützter Issuer, vollständige Planbindung, Ablauf, Widerruf, atomare Verwendung und Resume; manipulierte Receipts scheitern vor Datei-/Netzwerkeffekt. | Read-only Plan |
| Beschaffungskern | Injizierbarer begrenzter Transport, Signatur-/Hashprüfung, geschützter Store, Journale, Locks, Quarantäne und Recovery. Kein Payloadprozess. | Lokale Freigabe |
| Manifest UND öffentliche Direktbedienung | Beide Eingänge nutzen denselben Kern; Manifestparser, Export/Help, User-Doku, Batch-/Queue-Verhalten und Tests gemeinsam liefern. Keine Freischaltung nur im Schema. | Beschaffungskern |
| Windows-Abnahme | Synthetisch signierte Bytes, ACL-/Link-/Abbruchtests und direkte/manifestgestützte Parität auf Windows; `hyperv`-Zielbindung ohne VM-Start. | Beide Eingänge |
| Linux-Abnahme | Synthetisch signierte Release-Metadaten, Linux-Dateirechte und Windows-Controller-Cross-Download; Docker und Podman getrennt als Zielbindung, ohne Runtime-Start. | Beide Eingänge |
| Erste reale Katalogaufnahme | Für je eine ausgewählte Windows-/Linux-Variante aktuelle Primärquellen, Lizenzreview, exakte Hash-/Signaturbelege und explizit genehmigte reale Beschaffungsabnahme. Keine Toolausführung; keine Produkte vorab als freigegeben nennen. | Alle vorherigen Prüfungen |

Die Schema-/API-Arbeit muss [CONTRIBUTING](../../CONTRIBUTING.md) erfüllen:
Implementierung, Parser, Exports, Help, ausführbare synthetische Beispiele,
Front Door, Known Limitations, Repo-Map und passende Tests bilden einen
gemeinsamen Slice. Bei Wiederverwendung geteilter Primitive sind deren
bestehende Suites zusätzlich über den Impact-Selektor zu prüfen.

## Verbindliche Testfälle für die spätere Implementierung

| Testgruppe | Geforderte Beobachtung |
|---|---|
| Eingänge und Parität | Direkte und Manifestanforderung ergeben identische effektive Pläne, Hashes, Fehler und Receipts. Unbekannte Felder, IDs, Versionen, Zwecke, URLs/Commands und doppelte Konflikte scheitern vor jeder Mutation. |
| Plattform und Provider | Windows/Linux, Architektur, Distribution, SQL-Version und falsche Provider werden tabellarisch geprüft. Ein Docker-Erfolg ersetzt weder Podman noch Hyper-V. Ein Providerwechsel im bestehenden Run blockiert. |
| Autorität | Fehlende, gefälschte, abgelaufene, widerrufene oder für andere Pläne ausgestellte Freigaben sowie Replay werden verworfen. Sample-Trust, Force und Confirm-Unterdrückung umgehen nichts. Noninteractive wartet nicht auf Eingabe. |
| Integrität | Fehlender/falscher Hash, Längenüberschreitung, falscher Publisher, ungültige Signatur, widerrufener Schlüssel und stale Evidence blockieren; Cache-Hit wird erneut vollständig geprüft. Keine Ausführung zur Versionsprüfung. |
| Transport | Redirect, DNS-/Zielwechsel, TLS-Fehler, versteckte Verifikator-Egressversuche, Timeout, Cancel und Retrylimit über injizierte synthetische Antworten prüfen; keine öffentliche Quelle im statischen Test. |
| Store und Recovery | Rechtefehler, Traversal, Links/ADS, TOCTOU, Fremdvorbestand, Quarantäne, konkurrierende Leser/Schreiber sowie Abbruch vor/nach Veröffentlichung und vor Receipt prüfen; fremde Bytes unverändert. |
| Privacy und Nebenwirkungen | Keine Secrets/Pfade in exportierbaren Ergebnissen; Payloads/Receipts fehlen in Release und Git. Prozess-/Installations-/Provider-/Netzwerkkonfigurationsaufrufe müssen in jeder Beschaffungsprüfung null bleiben. |
| WhatIf und Wiederholung | Bytegenauer Vorher-/Nachhervergleich lokaler Ablagen bei Preview/WhatIf; null Transportaufrufe. Idempotenter Erfolg benötigt keinen erneuten Download; neuer Zweck benötigt eigene Autorität. |

Tests verwenden ausschließlich inert erzeugte Bytes und eigene synthetische
Signatur-Fixtures; Testschlüssel dürfen keine produktiven Trust Anchors sein.
Kryptographische Fehlerfälle werden auch gegen die reale Verifikationsbibliothek
offline geprüft. Produktionslogik erhält keinen Testschalter für freie Quellen
oder abgeschaltete Integritätsprüfung. Native Controller-Dateirechte und
Signaturverfahren benötigen eigene Windows-/Linux-Nachweise; Mocks ersetzen
diese nicht. Provider-Runtime-Smokes sind erst bei späteren Gast-/Container-
Mutationen erforderlich und bleiben getrennt von der Beschaffungsabnahme.

## Abschluss dieser Dokumentationswelle und verbleibende Grenzen

Dieser Slice ist als Backlog vollständig, wenn Zielvertrag, Auffindbarkeit,
Ist-Stand und Abnahmegrenzen konsistent dokumentiert sind und die
Dokumentations-/betroffenen statischen Prüfungen bestanden haben. Das gibt
keinen ausführbaren Pentest-Workflow frei.

Noch offen sind konkrete Werkzeug-/Versionsauswahl, Primärquellen- und
Lizenzreview, reale Trust Anchors, produktive Katalogeinträge, Implementierung
aller Entwurfsverträge sowie sämtliche Windows-/Linux-Beschaffungsnachweise.
Installation, Ausführung und fachliche Security-Szenarien benötigen später
eigene autorisierte Ziel-, Isolations-, Secret-, Cleanup- und Abnahmeverträge.
Es wird kein anderer Provider, keine Source-Fallback-Funktion und keine
bereits vorhandene Sicherheitsfreigabe aus diesem Plan abgeleitet.
