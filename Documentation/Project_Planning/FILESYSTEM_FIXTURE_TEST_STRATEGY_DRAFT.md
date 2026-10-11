# FSF-06 – Teststrategie für getrennte OS-/SQL-Identitäten

| Merkmal | Wert |
|---|---|
| Status | `TEST_STRATEGY_DECISION_DRAFT` – zur Abstimmung, nicht freigegeben |
| Entwurf | `FSF-06`, Revision `0.1`, Stand 2026-10-11 |
| Grundlagen | [FSF-01](FILESYSTEM_FIXTURE_ARCHITECTURE_DRAFT.md) Revision `0.2`; [FSF-02](FILESYSTEM_FIXTURE_CAPABILITY_DRAFT.md), [FSF-03](FILESYSTEM_FIXTURE_HANDLE_DRAFT.md), [FSF-04](FILESYSTEM_FIXTURE_OWNERSHIP_CLEANUP_DRAFT.md) und [FSF-05](FILESYSTEM_FIXTURE_SECURITY_DRAFT.md) jeweils Revision `0.1`, ausdrücklich freigegeben am 2026-10-11 |
| Anforderungsquelle | [Fixture-Verwaltungs-Backlog](FILESYSTEM_FIXTURE_MANAGEMENT_BACKLOG.md); eigenständige manuelle Schulungs-/Rekonstruktionsbenutzer und automatisierte Szenarien |
| Repositorybasis | `a6b5a6b3`; keine Fixture-Implementierung oder ausgeführte Fixture-Abnahme |
| Autorität | Teststrategieentwurf; keine Implementierungs-, Harness-, Kontoanlage-, Runtime-, Fehlerinjektions- oder Löschfreigabe |

F1 bis F10 sind Vorschläge. FSF-01 bis FSF-05 sind freigegeben; FSF-06 bleibt
einzeln abzustimmen. Dieser Slice erzeugt keine Testscripts, Testaccounts,
Schlüssel, Schemas, Providerjobs oder Änderungen an bestehenden Gates.
Die Fall-IDs beschreiben spätere Abnahmepflichten, keine vorhandenen Tests.

## 1. Nachweisebenen und unverwechselbare Ergebnisse

| Ebene | Belegt | Belegt ausdrücklich nicht |
|---|---|---|
| Dokumentationsprüfung dieses Slices | konsistente Freigaben, auffindbare Quellen, Privacy und ausgewählte statische Bestandschecks | irgendeine Fixture-Capability oder native Benutzeranlage |
| Künftige Offline-Vertragstests | Request-/Handle-/Plan-/Journalregeln, deterministische Faults, Fristen/Quotas und gezählte Adapterdispatches mit synthetischen Doubles | Konto-/SQL-/Dateirechte, native Generationsbindung, Transport oder Quieszenz |
| Künftige native Hosttests | tatsächliches Crypto-/Wrapping-/Ankerverhalten der exakt gebundenen Host-OS-/PowerShell-/.NET-Kombination | Windowsgast-, Linuxcontainer- oder SQL-Rechte |
| Künftige Provider-/SQL-Abnahme | tatsächliche Erzeugung, Rechte, Driftblockade, eigene Entfernung und Absenz auf einer konkreten Zielkombination | andere Provider, Images, SQL-Builds, rootless- oder Hostprofile |
| Künftige manuelle Abnahme | echter bereits vorhandener Zugangsweg, echte Nutzung als Szenariobenutzer, Aufbewahrung und kooperativer Abschluss | vollständige Automation oder Cleanup beliebiger unverwalteter Sitzungen |

Jeder Fall hat getrennt Assertionsergebnis und Cleanupstatus. `PASS`, `FAIL`,
`BLOCKED`, `NOT_EXECUTED` und `SKIP` sind Evidencekategorien, keine neuen
Fixture-DTO-Zustände. Ein korrekter fachlicher `BLOCKED`-Outcome kann ein
bestandener Negativtest sein. Ein infrastrukturell nicht ausgeführter Test
bleibt fehlende Evidence. `UNSUPPORTED`/`DEFERRED` aus FSF-02 wird nur mit
Begründung als nicht beanspruchter Umfang ausgewiesen, niemals als positiver PASS.

Eine Capability ist erst qualifiziert, wenn alle für sie einschlägigen
positiven, negativen, Host-/Provider-/SQL-/Nutzungs- und Cleanupnachweise an
derselben deklarierten Kombination bestehen. Erwartetes `RECOVERY_REQUIRED`
belegt eine Schutzreaktion, keinen abgeschlossenen Rückbau. Teilbestehen wird
pro Capability sichtbar geführt; daraus folgt keine pauschale Providerfreigabe.

## 2. Auswahl, Isolation und sichere Testvoraussetzungen

Nach einer späteren gesonderten Implementierungsbeauftragung gilt die
[lokale Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md): kleinste
Reproduktion, fokussierte Einheit, betroffene statische Suites, betroffene
native Fähigkeiten, stabiler Abschluss-Gate einmal. Auswahl durch
[Get-CiTestSelection](../../Tools/Get-CiTestSelection.ps1), Ausführung der
statischen Auswahl durch [Invoke-ImpactedChecks](../../Tests/Static/Invoke-ImpactedChecks.ps1).
Künftige neue Harnesses und Selektormappings benötigen einen eigenen
Implementierungsscope; die heutigen Tools wählen keine fertige Fixture-Suite.

Vor nativen Läufen: Werkzeuge im jeweiligen neuen Prozess über
[Hosttools-Initialisierung](../../Tools/Initialize-SqlServerLabHostTools.ps1)
auflösen und den zurückgegebenen Invocation-Pfad nutzen; betroffene
[Client-/Providerreadiness](../../Tools/Test-SqlServerLabClientReadiness.ps1)
prüfen. Fehlendes Werkzeug, Runtimezugriff und fehlende Berechtigung getrennt
führen. Kein Runtimeautostart, Toolinstall oder persistenter PATH-Wechsel zur
Behebung einer Testvoraussetzung.

Nur eigene isolierte synthetische Testruns verwenden, getrennt von vorhandenen
Benutzerruns und paralleler Entwicklungswelle. Ein separat autorisierter
Testharness kann seine Infrastruktur und synthetischen Datenbanken/Objekte
vorbereiten. Die Fixturefunktion selbst startet nichts, legt keine Datenbank
an und verändert keinen Authentisierungsmodus, Truststore oder Sicherheitsdienst.
Der bereits laufende verwaltete Zielrun muss qualifiziertes SQL-TLS, READY und
alle angeforderten Fähigkeiten vorweisen. Vorbereitete Fehlkonfigurationen
gehören ausschließlich zum eigenen separat gebundenen Testziel.

„Fremde“ Kontrollkonten, Principals, Dateien und Roots werden vom Testharness
vorab in dessen eigenem synthetischen Scope erstellt, bleiben aber fremd zur
Fixture-Ownership. Keine realen Hostkonten, produktiven Daten oder fremden
laufenden Labs als Negativfixture benutzen. Vorher-/Nachher-Schutzwerte bleiben
lokal: native Objektidentitäten, Hashes synthetischer Inhalte, relevante Rechte,
Gruppen/Mappings und erlaubte Scopegrenzen. Der Fixture-Handle ist kein Oracle.

Ein Fehler-/Crashfall, der Restressourcen hinterlassen kann, braucht vor
Dispatch einen separat geprüften begrenzten Eindämmungs-/Recoveryplan und
reservierte Kapazität. Fehlt ein sicherer Abschlussweg, bleibt der native Fall
`NOT_EXECUTED` und die betreffende Qualifikation offen; Offline-Faulttests
bleiben möglich. Keine VM-/Containerentfernung, fremde Löschung oder manuelle
Recordbereinigung als stiller Ersatz für Fixture-Cleanup. Eine eventuelle
separate Infrastruktur-Recovery braucht eigene Autorität und wird niemals
als bestätigte Fixture-Absenz verbucht. FSF-04s offener Vertrag für endgültig
verlorene Ziele wird durch diesen Testentwurf nicht eingeführt.

## 3. Getrennte Kombinationen statt übertragener Providerfreigabe

Jede Abnahme bindet Code-/Testrevision, FSF-Revisionen, Host-OS/PowerShell/.NET,
Crypto-/Secretprofil, Provider-/Clientversion, gepinntes Image beziehungsweise
VM-Artefakt, Gast-OS/Dateisystem/Kontohelper, Namespace/rootful/rootless,
SQL-Version/-Build/SqlClient/TLSprofil, angeforderte Fähigkeiten und Nutzungsart.
Reale Pins und IDs verbleiben privat; veröffentlichte Evidence verwendet
freigegebene Katalogreferenzen, Fall-IDs und opaque eigene Operation-/ResourceRefs.

| Abnahmespur | Verpflichtender eigener Umfang |
|---|---|
| Windows / Hyper-V | VM-ID/PowerShell Direct; lokale SID-Konten, NTFS/Reparse Points, vorhandener manueller Gastzugang und eigene Profilnebenwirkung; SQL-Logins/DB-Benutzer, SQL-TLS und Lifecycleblocker |
| Linux / Docker rootful | vollständige Container-ID/Endpunkt, benannte Konten und numerische Kontexte getrennt, NSS/UID/GID/Gruppen, Mode-Bits/Symlinks/Mounts, Exec als Szenariobenutzer; eigener SQL-/Cleanupnachweis |
| Linux / Docker rootless | eigener Mapping-/Kollisions-/Rechte-/Cleanupnachweis für jede beanspruchte Fähigkeit; kein Übertrag aus rootful, fehlende IDs ergeben BLOCKED |
| Linux / Podman rootful | dieselben fachlichen Pflichten, tatsächlicher Podman-Nachweis statt Docker-Doubles oder Docker-Evidence |
| Linux / Podman rootless | eigenständiger Mapping-/Namespace-/Rechte-/Cleanupnachweis; kein Host-Subuid-/Policybootstrap |
| Host Windows | tatsächliches DPAPI CurrentUser, keine LocalMachine-Ausweichroute; qualifizierte Crypto-/Anker-/Dauerhaftigkeits- und Wiederanlaufprüfungen |
| Host Linux | tatsächliches maskiertes Unlock/KDF/Wrapping, Relock und Anker-/Dauerhaftigkeitsprüfungen; unattended ohne qualifizierten Provider blockiert |

Die Hostspuren sind zusätzliche Dimensionen, keine vierten/fünften Runtimeprovider.
Manuell/automatisiert und mit/ohne Dateien werden jeweils beanspruchungsgemäß
belegt. SQL-only, OS-only und kombinierte Anfragen besitzen eigene Fälle;
OS-only benötigt weiterhin sicheren authentisierten SQL-READY-Zugang.

Der aktuelle [SQL-Katalog](../../Catalogs/sql-server-versions.json) führt 2019,
2022 und 2025 als SUPPORTED. Dies belegt keine Fixturefähigkeit. Die erste
native Referenz wird pro Provider/Host/Fähigkeit gegen den dann gültigen
Katalog ausdrücklich ausgewählt; weitere unterstützte Versionen dürfen erst
nach ihrem eigenen Nachweis als Fixtureunterstützung veröffentlicht werden.
Eine gemeinsame dreiversionige Freigabe verlangt alle einschlägigen Fälle je
Version. Keine erfundenen Images, neueste Tags als Pin oder pauschale Übernahme
vorhandener Hyper-V-/SQL-2025-Lifecyclebelege.

## 4. Offline-Vertrag, Autorisierung und native Host-Sicherheit

T-C01 bis T-C08 zunächst offline; T-C09 bis T-C12 zusätzlich auf jedem
beanspruchten Hostprofil nativ. Lokale synthetische Testschlüssel/Anker bleiben
im eigenen ignorierten Testscope; keine echten Betreibersecrets als Testdaten.

| Fall | Konkreter Reiz | Erwarteter Nachweis |
|---|---|---|
| `T-C01` | OS-only, SQL-only, kombiniert, ohne Dateien; mehrere unterschiedliche Identitäten | exakter Ressourcensatz und getrennte Arten; kein Executor, keine implizite OS-/SQL-Verknüpfung oder Dateianlage |
| `T-C02` | Fremder/unbekannter Owner/Consumer/Handle; gleiche ID in kopiertem Store | gleiche begrenzte Ablehnung ohne Existenz-/Eingabeecho; null Zielmutation, keine Storesuche/Adoption |
| `T-C03` | alte InventoryRevision, geänderter Plan/Profil/Retention, abgelaufener/verbrauchter Grant, duplizierter RequestRef | Ablehnung beziehungsweise nur gebundene Beobachtung; kein Rebase, zweiter Create oder neue Kompensation |
| `T-C04` | zwei konkurrierende Planannahmen/Mutationen auf derselben Instanz | genau eine wirksame Annahme/Reservierung; kein Doppelverbrauch und keine überlappende Wirkung |
| `T-C05` | unbekannte Version/Felder, Duplicate Keys, freie Metadaten/Pfade/SQL/Shell, Overflow und manipulierte Dependencies | geschlossene begrenzte Decoder-/Planablehnung vor Adapterdispatch |
| `T-C06` | Ressourcenteilfehler, selektive Entfernung, Revisionwechsel | kein falscher Gesamterfolg; CREATED/REMOVED/UNCERTAIN korrekt projiziert; nicht erzeugte Ressourcen nicht als CREATED ausgeben |
| `T-C07` | manipulierte Requests/native Fehler mit synthetischen Secret-/Endpoint-/Namen-/Pfadmarkern | Marker fehlen in normalen Ergebnissen, Logs, Events, Transcripts, Export-/Evidenceprojektion; privater Zugang separat empfängergebunden |
| `T-C08` | Simulierte Clock-/Frist-/Quota-/Retentionübergänge aus Abschnitt 9 | exakte Grenzen, keine stille Kürzung/Override/TTL-Löschung; Dispatch- und Probeanzahl deterministisch prüfen |
| `T-C09` | bekannte öffentliche AES-GCM-Testvektoren, falscher Tag/KeyId/AAD/Zweck/Owner/Run/Ziel/Revision | richtige Entschlüsselung nur im gebundenen Fall; manipulierte Hülle abgelehnt, kein Fallback oder Zielzugriff |
| `T-C10` | Nonceverbrauch, Prozesscrash vor/nach Verschlüsselung, Lücken, Hochstandverlust/Überlauf, parallele Writer | kein Nonce-Reuse; dauerhafter Hochstand und exklusive Veröffentlichung; unbekannte Dauerhaftigkeit blockiert |
| `T-C11` | alter gültiger Record gegen aktuellen Anker; Record-/Anker-Crashlücke; fehlender Schlüssel/Anker, Storecopy/bekanntes Restore | UNCERTAIN/Recoveryblockade; kein Neuschlüssel mit Adoption, Indexreset oder blinder Replay |
| `T-C12` | falscher Windowsbenutzer/DPAPI-Verlust; Linuxpassphrase falsch, Salt/Parameter-/Wrappingdrift, Relock; fehlender unattended Provider | nur qualifiziertes Unlock; kein LocalMachine/Base64/Klartextfallback; keine Kontolöschung durch Relock, Schlüssel für offene Recovery erhalten |

Vollständiger gemeinsamer Host-/Anker-/Schlüsselrollback und privilegierte
Kompromittierung liegen gemäß FSF-05 außerhalb der Garantie. Sie werden als
Threatgrenze dokumentiert, nicht durch einen scheinbar bestandenen Mock
„nachgewiesen“. Hosttests dürfen keine Passwörter zurücksetzen oder globale
Keystores/Policies ändern, um DPAPI-Verlust künstlich zu erzeugen; isolierte
Kontexte/Hüllen und begrenzte Faultpunkte verwenden.
Ein echter DPAPI-Cross-User-Nachweis verlangt vorhandene freigegebene
synthetische CI-Benutzerkontexte auf einem eigenen isolierten Testhost.
Fehlen sie, ist dieser Hostnachweis NOT_EXECUTED; keine persönlichen Hostkonten
als Fixture und keine Kontoanlage auf dem gemeinsam genutzten Entwicklerhost.

## 5. Native OS- und SQL-Identitäten mit unabhängigen Oracles

OS-Nachweise werden im tatsächlichen unprivilegierten Szenariokontext geführt,
nicht nur im Betreiber-Exec. SQL-Prüfungen verwenden echte neue physische
Verbindungen mit den einzelnen Szenariocredentials, keine SA-Verbindung mit
`EXECUTE AS` als Ersatz. Pooling wird für Identitätsoracles ausgeschlossen;
seine Effekte sind eigener Cleanupfall. Private Sollidentitäten werden mit
nativen Beobachtungen verglichen; veröffentlicht werden nur Assertions.

| Fall | OS-Reiz auf der zutreffenden Plattform | Erwarteter Nachweis |
|---|---|---|
| `T-O01` | benanntes Konto ohne Dateien anlegen und als eigener Nutzer verwenden | tatsächliche eigene neue SID beziehungsweise NSS-Name/UID/GID; keine Dateien außer ausdrücklich erlaubten Kontonebenwirkungen; keine Hostkonten |
| `T-O02` | numerischer Linuxkontext ohne Konto wählen | tatsächliche freie gemappte UID/GID, kein behaupteter Name/Passwort-/SSH-Zugang; Windowsvariante UNSUPPORTED |
| `T-O03` | zwei Benutzer mit unterschiedlichen geschlossenen Rechteprofilen | tatsächliche effektive Token-/Gruppen-/UID-/GID-/Capabilitygrenze; kein Admin/root/sudo oder verdeckte Zusatzgruppe |
| `T-O04` | vorhandener Name, SID-/UID-/GID-/Case-/Namespacekonflikt | gesamte neue Anfrage vor Mutation blockiert; vorhandene Konten/Gruppen unverändert, kein numerischer Fallback |
| `T-O05` | Kontohelper/NSS fehlt, Kontodatenbank read-only/shared/hostgebunden, Mapping ungeeignet | passende Capabilityblockade; keine Installation, Mount-/Subuid-/Policyänderung |
| `T-O06` | Konto löschen/ersetzen beziehungsweise ID innerhalb kontrolliertem Testziel wiederverwenden | qualifizierte Inkarnationsprüfung erkennt Drift oder die Kombination bleibt blockiert; Ersatzressource unverändert, keine Markeradoption |
| `T-O07` | eigene notwendige Hilfsgruppe/Home, begrenzte Helperhooks/-backups | nur bestätigte eigene Datensätze/Nebenwirkungen; fremde Gruppe/Mitgliedschaften und Kontodatenbank unverändert; kein Vollbackup/-rollback |
| `T-O08` | erfolgreicher eigener Rückbau, zweiter Cleanup und fremder gleichnamiger Ersatz | gebundene eigene Absenz und null zweite Löschwirkung; Ersatz nicht entfernen; keine Absenzbehauptung bei fehlendem eigenen Deletebeleg |

| Fall | SQL-Reiz in ausdrücklich gebundenen bestehenden synthetischen Datenbanken | Erwarteter Nachweis |
|---|---|---|
| `T-S01` | eigener SQL-Login ohne OS-Konto/Dateien/zusätzlichen DB-Benutzer | frische echte Anmeldung an der ausgewählten Instanz; eigene Loginidentität und qualifizierte Basisrechte, keine globale Rolle oder Gastadminabhängigkeit |
| `T-S02` | einen eigenen Login auf zwei eigene Benutzer in zwei Datenbanken mappen; später zweiten Benutzer ergänzen | private Login-/SID-/DB-Generationsbindung und echter Datenbankkontext je Verbindung; unterschiedliche DB-Ressourcen, kein automatisch erzeugtes Mapping |
| `T-S03` | Leser A und Benutzer B ohne ausgewähltes Leserecht auf derselben synthetischen Tabelle | A erhält exakt erwartete synthetische Zeilen; B erhält eine fachlich eindeutige Zugriffsverweigerung, keine Daten und keine Rechteänderung am Objekt |
| `T-S04` | exakt freigegebene SELECT/INSERT/UPDATE/DELETE-Teilmenge | erlaubte Aktion wirkt auf genau die eigenen synthetischen Testzeilen; nicht freigegebene Aktion scheitert ohne Änderung; Trigger-/View-/Ownershipwirkung bleibt im qualifizierten Rahmen |
| `T-S05` | DDL, EXECUTE/Impersonation, Rechtevergabe, Admin-/db_owner-Recht oder Zugriff auf nicht ausgewähltes Objekt versuchen | tatsächliche fehlende effektive Rechte und konkrete verweigerte Aktion; kein privilegierter Testkontext oder pauschale Rollenfreigabe |
| `T-S06` | vorbereitete unzulässige public/guest-/Rollen-/Trigger-/signierte Modulwirkung | Admission vor Anlage blockiert; keine Änderung der gemeinsamen Rechte/Objekte, um den Test passend zu machen |
| `T-S07` | fremder Login/DB-Benutzer, gleiche Namen/SIDs, unbekannte fremde Mappings oder fehlende Beobachtungsrechte | keine Adoption; vollständige neue Anfrage beziehungsweise Cleanup blockiert; fremde Principals unverändert, keine orphaned Users erzeugen |
| `T-S08` | Datenbankrestore, Dienst-/Zielwechsel oder Principalersetzung im eigenen separat kontrollierten Testziel | frische Generationsprüfung blockiert; kein Rebinding an Name/Port/principal_id oder Löschen der Ersatzressource |
| `T-S09` | ausgewählten DB-Benutzer entfernen, anderen Benutzer/Login bewusst erhalten; danach vollständiger eigener Cleanup | erster Outcome betrifft nur gewählten Satz; Loginentfernung mit verbliebener Abhängigkeit blockiert; später eigene Benutzer vor Login, bestätigte native Absenz und sichere zweite Beobachtung |

Die SQL-Oracles unterscheiden ursprünglichen Login und aktuellen Ausführungs-
beziehungsweise Datenbankkontext: `ORIGINAL_LOGIN`, aktuelle Login-SID und
aktueller DB-Benutzer/DB-Kontext werden privat gegen Sollbindung geprüft.
`HAS_PERMS_BY_NAME` und `sys.fn_my_permissions` ergänzen tatsächliche erlaubte
und verweigerte Zugriffsversuche. Ein NULL/Fehler bei der Berechtigungsprüfung
ist kein bewiesenes DENY. Ein Metadaten-GRANT oder ein erwarteter Rowcount
allein reicht nicht. Siehe
[ORIGINAL_LOGIN](https://learn.microsoft.com/en-us/sql/t-sql/functions/original-login-transact-sql?view=sql-server-ver17),
[HAS_PERMS_BY_NAME](https://learn.microsoft.com/en-us/sql/t-sql/functions/has-perms-by-name-transact-sql?view=sql-server-ver17) und
[sys.fn_my_permissions](https://learn.microsoft.com/en-us/sql/relational-databases/system-functions/sys-fn-my-permissions-transact-sql?view=sql-server-ver17).
Die Primärquellen wurden am 2026-10-11 geprüft; keine dortigen
Impersonation-/Klartextpasswortbeispiele werden als Fixtureworkflow übernommen.
Negative SQL-Versuche müssen syntaktisch gültige Aktionen auf nachweislich
vorhandenen gebundenen Testobjekten verwenden. Syntaxfehler, fehlende Tabelle,
falsche Datenbank, TLSfehler oder Timeout gelten nicht als Rechteverweigerung.

## 6. Manuelle Nutzung, Zugang und Transport

| Fall | Reiz | Erwarteter Nachweis |
|---|---|---|
| `T-M01` | eigenständige Windows-Gastanmeldung beziehungsweise Linux-Exec als benannter Benutzer, ohne Testexecutor | echter vorhandener qualifizierter Zugang und native Identität; fehlender Kanal blockiert ohne RDP/SSH/Firewall-/Anmelderechtebootstrap |
| `T-M02` | zwei echte manuelle SQL-Clientverbindungen für Schulung/Rekonstruktion, unabhängig von OS-Konten | identitätsabhängiger erlaubter/verweigerter Zugriff wie T-S03/T-S04; manuell maskiert gewählte getrennte Credentials; private Route ohne Passwortanzeige |
| `T-M03` | Benutzer nach Test-/Dateiende aufbewahren; neue lokale Sitzung/Relock/Retentionablauf und bewusste Verlängerung | Benutzer bleiben angelegt; nur eigene neue Labhandoffs gesperrt; kein Passwortreset/Logout/TTL-Delete; erneute Nutzung nach frischer gebundener Freigabe |
| `T-M04` | kooperativ alle manuellen Sessions, Queryfenster, Pools und OS-Programme schließen; danach Cleanup | positive vollständige Quieszenz und Racekontrolle im qualifizierten Profil; andernfalls sichtbarer Blocker, kein ForceLogout/KILL; eigener vollständiger Rückbau getrennt belegt |
| `T-N01` | richtige/falsche/abgelaufene Serveridentität, fehlende CA-/Namens-/Pinbindung, TrustOverride/TOFU | nur qualifiziertes Mandatory-TLS mit geprüfter Serveridentität; unsicherer Fall vor Secret-/Mutationsdispatch blockiert, auch OS-only |
| `T-N02` | Endpunkt/Container-ID/VM-ID/Zielgeneration zwischen Plan, READY und Dispatch wechseln | kein Wechsel/Fallback oder neuer Peer; auf tatsächlichem Ziel null unzulässige Wirkung; Reservierung/Recovery gemäß FSF-04 |
| `T-N03` | generiertes Credential an qualifizierten Speicherkanal; fremder Empfänger, Replay oder Secretmarker in Ausgaben | genau einmaliger kontextgebundener Handoff; fremde/repetierte Übergabe blockiert; kein SA-/Gastadminsecret, argv/env/Clipboard/Datei-/Browserklartext |

Manuelle Abnahme besteht aus nachvollziehbaren menschlichen Schritten plus
nativen maschinellen Identitäts-/Rechte-/Absenzprüfungen. Eine bloße Aussage
„Anmeldung ging“ reicht nicht. Private Sessiondetails bleiben lokal; keine
Screenshots mit Zugangsdaten oder kopierten Connectionstrings. Der Witness
wird öffentlich nur als eigener Fallabschluss geführt, ohne Personenbezug.
GUI-Automation, automatischer Testexecutor oder Toolbeltaufruf ersetzt diese
Abnahme nicht. Unqualifizierter manueller Zugang bleibt bedingt geplant.

## 7. Optionale Dateien, SQL-Dienstzugriff und Windowsprofile

Dateifälle sind eigene Ergänzungen, keine Voraussetzung für T-O/T-S/T-M.
Windows und Linux besitzen unterschiedliche native Oracles; Mode-Bits werden
nicht als NTFS-ACL-Evidence ausgegeben. Außenressourcen sind ausschließlich
synthetische eigene Kontrollressourcen des separat verantwortlichen Harnesses.

| Fall | Reiz | Erwarteter Nachweis |
|---|---|---|
| `T-F01` | eigene Verzeichnisse/Inhalte und erlaubte/verweigerte Benutzerrechte | tatsächlicher Zugriff als Szenariobenutzer, unveränderte native Grenzen und Inhalts-/Rechte-Sollwerte; Betreiberzugriff allein reicht nicht |
| `T-F02` | vereinbartes Dateiprofil für ausgewählte bestehende SQL-Dienstidentität | tatsächlicher qualifizierter nativer Dienstzugriff mit erlaubtem/verweigertem Ergebnis; kein SA/root-Dateizugriff als Ersatz, keine Dienstkonto-/Featureänderung |
| `T-F03` | erlaubter synthetischer Link zum eigenen Outside-Sentinel; Junction/Reparse-/Symlinkwechsel und Pfadtraversal | kein Linkzielzugriff beim Cleanup; Sentinel innerhalb äußerem Root unverändert; unerwartete Links blockieren |
| `T-F04` | bind mount/Volume-/Parent-/Objektwechsel, Hardlink, Host-/Sharedstorage oder unbekanntes Kind | kein rekursiver Escape/Adoption; vor beziehungsweise während Mutation fail-closed, fremde Inhalte/Rechte/Objektidentitäten unverändert |
| `T-F05` | kontrollierte eigene Windows-Erstanmeldung mit neuem Profil; geladenes/spezielles/fremdes/ersetztes Profil als Gegenfall | eigener vorab gebundener SID-/Erzeugungs-/Registry-/Datei-/Linkbeleg, native sichere Entfernung nur nach Quieszenz; Gegenfall blockiert, kein Ordnerfallback |
| `T-F06` | eigenes Home/Hilfsressourcen, Dateiänderung innerhalb erlaubtem Scope und selektives Datei-Cleanup | bestätigte eigene Manifestobjekte entfernt; unbekannte Workloaddateien nicht per UID adoptiert; aufbewahrte OS-/SQL-Benutzer bleiben verwendbar; äußerer Root nur leer entfernt |

## 8. Crash, Teilfehler, Cleanup und Lifecycle

Alle R-/L-Fälle werden offline mit gezählten Dispatches geprüft und für jede
betroffene beanspruchte native Fähigkeit separat bestätigt. Native Injektionen
liegen nur an kontrollierten eigenen Harnessgrenzen; keine Fehlersimulation
auf realen Benutzer-/Parallelruns. Keine automatischen mutierenden Retries.

| Fall | Reiz | Erwarteter Nachweis |
|---|---|---|
| `T-R01` | Erzeugung/Erweiterung scheitert bei einer späteren Ressource | COMPENSATE_NEW entfernt nur bestätigte neue Ressourcen/Effects; KEEP_CONFIRMED bleibt ausdrücklich erhalten; vorhandene behaltene Identitäten/Rechte nicht global zurücksetzen |
| `T-R02` | Cleanup mit fremder Abhängigkeit, aktivem/unbekanntem SQL-/OS-/Profilgebrauch | Gesamtpreflight blockiert vor erster Deletewirkung; keine Sitzung beenden, Kontosperre oder Passwortänderung |
| `T-R03` | Drift nach Gesamtpreflight beziehungsweise Nutzung/Objektwechsel unmittelbar vor Delete | Guard und native Racebarriere stoppen unsichere Wirkung; kein Name-only-Delete oder Lock/Snapshot als alleiniger Beleg |
| `T-R04` | zweiter Delete-/Journalstep scheitert nach bestätigtem ersten Delete | erster Fortschritt bleibt belegt; keine weiteren Zielmutationen/Recreation; PARTIAL/RECOVERY_REQUIRED und gehaltene Reservierung |
| `T-R05` | Createantwort/Client verloren; mutierender Timeout und spätere Antwort/Wirkung | vorhandene unbestätigte Ressource UNCERTAIN, keine Adoption/zweite Anlage; maximal eine zusätzliche lesende Probe je Ressource/Operation innerhalb Deadline; kein Unlock ohne Dispatchendebeleg |
| `T-R06` | eigene bestätigte Deletewirkung mit gebundener Absenz, unbestätigtes externes Verschwinden, fremder Ersatz oder unreachable Ziel | vier unterschiedliche Bewertungen gemäß FSF-04; nur eigener Delete plus gleiche Zielgeneration bestätigt Entfernung; fremder Ersatz unverändert |
| `T-R07` | derselbe Create-/Cleanuprequest nach Erfolg/Teilfehler/Crash erneut | nur gebundene Beobachtung beziehungsweise neuer expliziter Recoveryplan; keine Wiederverwendung von IDs, neuer Create oder ungebundener Löschretry |
| `T-R08` | Secret-/Record-/Indexretention bei lebenden, unklaren und bestätigten abgeschlossenen Ressourcen | offene Recoverydaten/Schlüssel erhalten; Secrets erst nach Ende ihrer Verwendung entfernen; detaillierte Records erst nach bestätigtem Run-Ende plus 30 Tage; Nichtwiederverwendung bleibt |
| `T-R09` | automatisierter Szenariotest erfolgreich, fehlgeschlagen oder abgebrochen; OPERATION und SCENARIO gemischt | vorab genehmigtes OPERATION-Cleanup unabhängig vom Testergebnis innerhalb Plan/Deadline versuchen; SCENARIO-Benutzer erhalten; fehlendes READY/Quieszenz oder Deadline bleibt Recovery statt Erfolg |
| `T-L01` | Stop/Remove/Recreate/Reattach/Reconcile und zweiter Scope während offener Fixture-Reservierung | jeder relevante Lifecycle-/Aufruferpfad blockiert; kein Providerfallback oder Umgehen über direkte Nebenroute |
| `T-L02` | SQL-READY/TLS fällt nach Plan beziehungsweise zwischen zwei Schritten aus | nächste Mutation auch bei OS-only/Cleanup blockiert; bestätigter Teilstand erhalten; kein Start/Repair/Infrastruktur-Cleanup |
| `T-L03` | Scope-/Runende nach vollständigem eigenerzeugtem Rückbau | gesicherter Fixtureabschluss vor separat autorisierter Infrastrukturaktion; kein noch lebender Benutzer/Secret oder offene Wirkung verschwiegen |
| `T-L04` | Ziel extern endgültig entfernt beziehungsweise wieder angehängt | keine individuelle Absenz oder automatische neue Ownershipgeneration behaupten; Recovery offen, kein neuer Verlustabschlussvertrag |

Die Faultserie deckt jeden tatsächlichen persistenten Übergang ab, nicht nur
ein allgemeines „Crash irgendwann“. Mindestens folgende Grenzen sind einzeln
zu instrumentieren; jede beanspruchte schreibende Adapterfamilie muss betroffen sein:

| Faultgrenze | Mindestoracle nach Restart im gleichen gebundenen Kontext |
|---|---|
| Nonce im Anker verbraucht, Record noch nicht veröffentlicht | Lücke zulässig, niemals gleicher Nonce bei neuem Encrypt; kein Ziel-Dispatch ohne vollständigen Intent |
| Intent gespeichert, Grantverbrauch noch nicht bestätigt | kein unbestätigtes Grant-Replay; Anker-/Journalabgleich blockiert jede unklare Annahme |
| Grant verbraucht, Dispatch noch nicht bestätigt | kein zweiter Create; tatsächliches Ende/Nichtdispatch getrennt beweisen, keine Mutationsfreigabe allein aus fehlendem Receipt |
| native Erzeugung erfolgt, Ownershipreceipt fehlt | UNCERTAIN; gleicher Name/SID/UID/Marker erlaubt keine Adoption oder Delete |
| eigenes Receipt gespeichert, Inventarrevision/Antwort fehlt | gebundenen Teilstand beobachten; keine Neuanlage; neuer expliziter Plan nur nach vollständig stimmiger Kette |
| eigene Rechte-/Mitgliedschaft geändert, Effectreceipt fehlt | unklare Wirkung nicht durch Gesamt-ACL-/Kontodatenbankrollback kompensieren |
| Delete dispatcht, Absenzreceipt fehlt | Ausführungsende und gebundene Absenz lesend klären; kein mutierender Delete-Retry |
| Absenzreceipt gespeichert, Abschluss-/Index-/Secretbereinigung fehlt | bestätigt entfernte Ressource nicht erneut löschen; IDs nicht wiederverwenden; offene Abschlusslücke sichtbar behandeln |

Rennen werden über kontrollierte Barrieren an der Prüfen-/Mutieren-Grenze
hergestellt, nicht mit zufälligen Sleeps „erhofft“. Alle festgelegten
Interleavings müssen mindestens einmal deterministisch geprüft werden.
Vor einer Qualifikationsfreigabe werden dieselben kritischen Native-Fault- und
Racefälle in zwei unabhängigen eigenen Scopes bestätigt. Das ist eine
begrenzte Reproduzierbarkeitsforderung, kein statistischer Beweis für Racefreiheit.
Der zweite Scope prüft insbesondere Nichtwiederverwendung und erhaltenen
Controller-/Abschlusszustand des ersten Laufs; die Pflicht gilt für die
Qualifikation der betroffenen Fähigkeit, nicht nach jedem unveränderten Textfix.
Eine unveränderte grüne Diagnose wird nicht zusätzlich wiederholt, wenn sie
bereits exakt einen dieser Pflichtnachweise erfüllt.

## 9. Grenzwerte, Fristen und unveränderte Außenressourcen

| Fall | Prüfung | Erwarteter Nachweis |
|---|---|---|
| `T-Q01` | Request/Handle/Inventar/Names/Count/Size/Depth/Steps an, unter und über jeder FSF-03-/FSF-05-Grenze | exakter erlaubter Rand, Überschreitung vor neuer Mutation abgewiesen; kein stilles Kürzen, fremdes Purge oder unbegrenzter Override |
| `T-Q02` | Grant/Unlock/READY/Probe-/Mutations-/Gesamtdeadline sowie Retention/30-Tage-Frist unmittelbar vor, an und nach Grenze | READY-Maximalalter von 5 Sekunden eingeschlossen, Fristen beim Erreichen abgelaufen; rechtzeitig verbrauchter Grant trägt nur festen begonnenen Plan; Deadline stoppt neue Dispatches, spät laufende Wirkung bleibt unklar |
| `T-Q03` | Journal-/Anker-/Indexkapazität erschöpft, Crashreserve fehlt; Cleanup offener Ressourcen unter Admissionsperre | neue Anlage blockiert; vorab reservierte Abschluss-/Recoverykapazität bleibt nutzbar; keine Daten-/Schlüssel-/Tombstoneentfernung zur Quotaheilung |

Größen-/Zählgrenzen: 16 KiB Request, Tiefe 8/128 Felder; 256 Byte Handle;
64 KiB Result/Einzelrecord, 64 Ressourcen/Dependencies je Ressource und 16
ReasonCodes; 16 OS-/numerische, 16 Login- und 32 DB-Benutzerressourcen innerhalb
der gemeinsamen 64er-Grenze; Alias/Windows/Linux/SQL-Namen 32/20/32/64 Zeichen;
1.024 eigene Datei-/Profilobjekte, 256 MiB/Tiefe 16; 16 MiB Journal, 64 offene
Controllerscopes; Index 100.000 Einträge und 64 MiB; 2.048 Operationsschritte.
Isolierte Validatorprüfungen testen Limits unabhängig; ein nativer End-to-End-
Fall überschreitet nicht andere Limits versehentlich und erklärt dies als
Beweis des ausgewählten Limits. Kein Anlegen hunderttausender nativer Accounts.

Zeitgrenzen: Grant/Handoff 60 Sekunden, Unlock 30 Minuten, READY-Alter höchstens
5 Sekunden, Probe höchstens 5 Sekunden, nativer Mutationsaufruf höchstens
30 Sekunden, Operation höchstens 120 Sekunden; SCENARIO standardmäßig 4 Stunden
und höchstens 24 Stunden je genehmigtem Zeitraum innerhalb desselben Runs.
Monotone eigene Testclock für kurzlebige Deadlines; UTC für dokumentierte
Retention, unsicherer Clock-/Restartsprung darf keine Freigabe verlängern.
Keine Änderung der Host-/Gastsystemzeit für Tests. Lange Fristen werden lokal
über kontrollierte Clockinjektion geprüft, nicht durch tagelanges Warten.
Native Tests bestätigen zusätzlich tatsächliche Deadline-/Relock-/Spätwirkungs-
Grenzen; ein Clockmock beweist keine Beendigung eines nativen Aufrufs.

Jeder mutierende native Fall prüft seinen lokalen Schutzsnapshot vor und nach
der Operation und nach Cleanup: synthetische fremde Accounts/Principals,
Gruppen/Rechte/Mappings, Außen-/Sentinelobjekte sowie eigene Ziel-/Namespace-
und Konfigurationsgrenzen. Änderungen an Hostkonten, Provider-/Securitypolicy,
Dienst-/Authmodus, fremden ACLs oder Außenressourcen sind FAIL, auch wenn
funktionale Assertions grün sind. Unlesbarer oder unvollständiger Schutz-
snapshot ist fehlende Evidence; kein leerer Diff als Erfolg ohne Beobachtungsbeleg.
Eine gezielte separat autorisierte Harness-Drift besitzt einen eigenen
begrenzten Sollwechsel und Beobachtungsbeleg unmittelbar vor dem Fixtureguard.
Verglichen wird zusätzlich gegen diesen Zustand: keine weitere unzulässige
Fixturewirkung. Pauschale Ausnahmen für „Teständerungen“ sind ausgeschlossen.

## 10. Evidence, Cleanupabnahme und betroffener Gate

Ein künftiger Fallabschluss benennt Fall-/Capability-ID, geprüfte Kombination,
exakte Source-/Test-/Vertragsbindung, tatsächliche Ebene, Zeitpunkt,
Assertionsergebnis, Outcome-/ReasonCode-Erwartung, Mutations-/Probeanzahl,
Schutzvergleich, Cleanupstatus und verbleibende Grenzen. Das sind fachliche
Mindestinhalte für Evidence, kein neues Schema oder öffentliche API.
Secrets, rohe native IDs/Namen/Pfade/Endpunkte und vollständige Logs bleiben
lokal ignoriert. Öffentliche Ergebnisse sind begrenzt, synthetisch und
bereinigt; ein Upload benötigt den bestehenden Privacyvertrag.

Ein normaler positiver Fall ist erst abgeschlossen, wenn eigene native
Ressourcenabsenz, unveränderte Kontrollressourcen, keine offenen Dispatches,
gesicherter Journal-/Indexabschluss und erforderliche Secretbereinigung belegt
sind. Bei Retentionfällen ist die bewusst erhaltene Nutzung Zwischenziel;
vollständiger finaler Cleanup bleibt Teil desselben Abnahmenachweises.
Keine globale Prune-/Wildcard-Löschung oder Löschung durch Hostpfadfallback.

Bei negativen Crash-/Driftfällen darf die Assertion PASS lauten, während
Cleanup RECOVERY_REQUIRED bleibt. Die Gesamtabnahme bleibt dann offen, bis
der vorab erlaubte Abschlussweg belegt ist. Unbekannte Ressourcen und fehlende
Absenz dürfen nicht durch neue Logs, manuelle Journalkorrektur oder Scopewechsel
verdeckt werden. Ein entfernter Container ist kein eigenes Konto-Delete-Receipt.

Ein Gate für eine deklarierte Capability enthält alle einschlägigen Fälle
dieses Entwurfs, deren Host-/Provider-/SQL-/Nutzungsbelege und Cleanupabschluss.
Betroffene gemeinsame Ownership-/Security-/Lifecycleänderungen ziehen die
entsprechenden gemeinsamen Spuren mit. Keine pauschale volle Produktmatrix
nach jedem Textfix; volle deklarierte Qualifikation und bestehende Nightly-/
Releasepflichten bleiben erhalten. Ein Gate mit FAIL, notwendigem SKIP oder
fehlender Native-Evidence qualifiziert die Capability nicht.

| Freigegebene Entscheidungen | Zugeordnete Mindestfallgruppen |
|---|---|
| A1–A4, A6–A7, A9–A10; B1–B5/B7 | C01–C04, O01–O08, S01–S09, M01–M04, N01–N03, L01–L04 und Kombinationen aus Abschnitt 3 |
| A5; B6; D6–D7; E8 | F01–F06, O07, R01–R04 und unveränderte Schutzsnapshots |
| C1–C8; D1–D4/D8–D9 | C01–C12, S07–S09, R01–R09, L01–L04 und jede Faultgrenze aus Abschnitt 8 |
| D5; E6–E7 | O03–O08, S03–S08, M04, R02–R06 und native Rechte-/Quieszenz-/Raceoracles |
| E1–E5/E9 | C02–C12, N01–N03, Q01–Q03, R05/R08 und explizite Threat-/Retentiongrenzen |
| A8, B8, C9, D10, E10 | Freigabestatus und Autoritätsgrenze: Planung/Evidence erteilt keine automatische Zielmutation |

Die Gruppenreferenzen verwenden dieselben T-Präfix-IDs aus den Tabellen.
Vor jeder späteren Implementierungsabnahme wird geprüft, ob konkrete
Assertions alle betroffenen Entscheidungen tragen; Gruppenzuordnung allein
ist kein Coveragebeweis. Offene Fälle werden nicht aus der Matrix entfernt.

## 11. Entscheidungen zur Abstimmung und nächster Schritt

| ID | Vorschlag für FSF-06 | Konsequenz |
|---|---|---|
| `F1` | Offline-, native Host-, Provider-/SQL- und manuelle Evidence getrennt führen | Mocks/Bestandschecks qualifizieren keine Fixturefähigkeiten; erwartete Ablehnung ist kein Positivnachweis. |
| `F2` | Eigene isolierte synthetische Testruns und vorab begrenzter Recoveryplan | Keine Benutzer-/Parallelruns als Testziel; unsicher abschließbare Native-Faultfälle bleiben offen. |
| `F3` | Exakte Kombination pro Provider/rootful/rootless/Host/SQL/Nutzungsart deklarieren | Kein Docker→Podman-, Host→Gast- oder SQL-Versionsübertrag; Erweiterungen brauchen eigene Evidence. |
| `F4` | Konkrete Autorisierungs-/Handle-/Crypto-/Anker-/Secret-/TLS-Negativfälle C/N/Q | Null unzulässiger Dispatch; kein Replay/Fallback oder private Ausgabe. |
| `F5` | Eigenständige OS-only-/SQL-only-/kombinierte Anlage und echte Identitäts-/Rechteoracles | Mehrere manuelle Schulungsbenutzer und Automationsbenutzer bleiben gleichberechtigt; keine SA-Impersonation als Ersatz. |
| `F6` | Separate manuelle Abnahme mit Retention, sicherem Zugang und kooperativem Abschluss | Kein Testexecutor nötig; native Nutzung und finaler Cleanup sind beide zu belegen. |
| `F7` | Optionale Dateien/SQL-Dienstzugriff und enge Windowsprofil-Ausnahme separat prüfen | Keine fremde Link-/Mount-/Profilwirkung, kein Dienstkonto-/Featurebootstrap oder Ordnerfallback. |
| `F8` | Jede Journal-/Dispatch-/Absenzgrenze und deterministische Raceinterleavings prüfen; kritische native Fälle in zwei eigenen Scopes | Erwartete Recovery sichtbar, keine blinden Retries oder statistische Racefreiheitsbehauptung. |
| `F9` | Exakte Grenzwert-/Frist-/Privacy-/Schutzsnapshot- und Cleanupabnahme | Fehlende Beobachtung, Restressourcen oder notwendige Skips halten Qualifikation offen. |
| `F10` | FSF-06-Freigabe genehmigt ausschließlich diese Teststrategie | Kein automatischer Implementierungs-/Runtimebeginn; konkreten Folgescope mit aktueller Planung und paralleler Welle abstimmen. |

Vor einem späteren Implementierungsauftrag werden die sechs freigegebenen
Modelle, aktuelle Quellen und Wellenzuständigkeiten erneut abgeglichen.
Dabei zuerst einen kleinen kohärenten Slice samt zugehörigen Fällen auswählen;
noch offene native Fähigkeiten, Cleanup-/Recoverygrenzen und Infrastruktur-
voraussetzungen sichtbar blockieren. Dieser Entwurf ändert weder Priorität
noch Zuständigkeit der parallelen Entwicklungswelle.

Der Abstimmungsstatus ist `PENDING`. Sämtliche hier geplanten Fixturetests,
nativen Benutzer-/SQL-/Dateinachweise und manuellen Abnahmen sind
`NOT_EXECUTED`; bestehende Lifecycle-/Cleanup-/Dokumentationschecks werden
nicht umgedeutet. Gekoppelte Quellen sind FSF-01 bis FSF-05,
[Repo-Map](../../.ai/repo_map.yaml), [Arbeitsregeln](../../.ai/WORKING_RULES.md),
[Known Limitations](../Quality/KNOWN_LIMITATIONS.md),
[Kosten-/Prüfpolitik](../Quality/COST_EFFICIENT_DEVELOPMENT.md) und
[Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md).
