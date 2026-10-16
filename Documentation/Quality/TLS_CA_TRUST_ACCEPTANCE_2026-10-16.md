# TLS-001: lokale native CA-Trust-Abnahme vom 2026-10-16

## Nachgewiesener Scope

Die ausdrücklich freigegebene öffentliche isolierte Lab-CA wurde durch genau
einen separat geprüften sichtbaren Recoveryworker in `CurrentUser/Root` des
freigegebenen Windows-Benutzers importiert. Der Benutzer bestätigte die sichtbare
Fensteranzeige. Der Worker endete innerhalb seines begrenzten Zeitfensters mit
Exitcode 0. Die anschließende frische lesende Prüfung bestätigte die exakten
freigegebenen Zertifikatsbytes und `RECOVERY_IMPORT_RECORDED`.

Der ursprüngliche unterbrochene Importintent blieb bytegleich erhalten. Ein
ursprünglicher Commit wurde nicht nachträglich erzeugt; der eigene passende
Recoverycommit wurde über den zentralen Status bestätigt. Nach Abschluss blieb
kein kooperativer Lock zurück. Kein weiterer Importversuch, keine Entfernung,
keine Schlüsselöffnung durch die lesende Nachprüfung und kein Maschinen-Trust.

## Quellen und Ausführung

Der private [Recoveryvertrag](../Architecture/AUTHENTICATED_TLS_TRUST_RECOVERY.md)
ist mit [PR 769](https://github.com/gecompat/SQL_Server_Lab/pull/769) integriert.
Der Pflichtgate [38961189309](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38961189309)
bestand am exakten Head `46b3aabb92a759452e996d17780a493576ed6184` unter Windows
und Ubuntu sowie im PR-Gate. Die integrierte Baumgleichheit wurde geprüft.
Diese synthetische CI-Evidence ist von der anschließenden lokalen nativen
Ausführung getrennt.

Ein unabhängiger Review des stabilen Ausführungsadapters prüfte Freigabe,
Quellenbindung, geschützte Dateien, tatsächliche Worker-PID/Startbindung,
einmalige Ausführung und begrenzten Abbruch. Ein bestätigter Skalargrenzenfehler
bei Singletonarrays wurde korrigiert und unabhängig verifiziert. Der endgültige
Worker wurde bytegleich mit Schutz-ACL, CreateNew, Flush und Rücklesen abgelegt.
Vor dem Produktaufruf waren seine exakte Prozessidentität und sein Permit
dauerhaft festgehalten. Der historische ursprüngliche Worker hatte keine
persistierte PID; daraus wurde keine globale Quieszenzbehauptung abgeleitet.

Reale CA-Identitäten, Fingerprints, Benutzer-/Hostwerte, Prozesskennungen,
Freigaben, geschützte Workerquellen und Rohbefunde bleiben ausschließlich in
lokalen ignorierten Artefakten. Dieses Dokument enthält nur bereinigte Befunde.
Tatsächliche Kosten und Tokenverbrauch sind unbekannt.

## Aussagegrenzen und nächster Nachweis

Nachgewiesen ist die konkrete lokale native Trusttransaktion. Es gibt keine
allgemeine Laufzeit-/Policy-/UI-Garantie, globale Store-Atomizität, exklusive
Nutzung oder neue Removalautorität. Die CA bleibt operativ unregistriert;
`Ready=false`; dieser Trustnachweis allein qualifiziert keine SQL-/Client-/Provider-TLS-Abnahme.
Toolbelt SC-2026-045 ist dadurch noch nicht freigegeben.

Die erste nachfolgende native Probe verwendete ausschließlich ein frisches
eigenes Docker-SQL-2025-CU9-Lab. Ein echter Windows-System.Data.SqlClient-
Verbindungsversuch mit `Encrypt=True`, `TrustServerCertificate=False` und
`Pooling=False` wurde vor jeder SQL-Abfrage mit `SEC_E_UNTRUSTED_ROOT`
abgelehnt. Im eigenen Container entstanden RSA-3072-Key und öffentlicher
OpenSSL-CSR; der Leafissuer wies ihn wegen UTF8 statt BCL-Subjectkodierung ab.
Es gab keine Server-TLS-Konfiguration, keinen Neustart und keine positive Probe.
Der öffentliche Lifecycle entfernte den eigenen Run vollständig; keine eigenen
Container/Volumes verblieben. Alle vorher erfassten Run-, Root-, Katalog- und
Exportdateien blieben bytegleich. Reale Identitäten und CSR bleiben lokal privat.

Die eng korrigierte Readerprüfung akzeptiert zusätzlich ausschließlich das
exakt konstruierte UTF8-DER desselben festen einzelnen CN. Der erhaltene
öffentliche OpenSSL-CSR besteht danach DER-/RSA-/SAN-/POP-Prüfung ohne
Keyöffnung oder Store-/Runtimezugriff. Eigene synthetische Crypto-/DPAPI-/
ACL-Fixtures bestanden 55/0 und wurden vollständig entfernt; Gegenfälle
bewahren die Sperre für falschen/zusätzlichen Subject, Signaturdrift und Extensions.
Dies ist keine nachträgliche native Signierung oder positive SQL-Abnahme.

Die spätere getrennte [Windows-Probe](TLS_WINDOWS_SQL2025_PARTIAL_ACCEPTANCE_2026-10-16.md)
bestand mit beiden strikten positiven Stacks und .NET-Gegenfällen für unvertraute
Kette und falsches SAN am gleichen IPv4-Endpunkt. Ihr eigener Run ist entfernt;
dies qualifiziert nicht die vollständige Matrix oder Registry.
Die sechs geschützten Testumgebungen,
die erhaltene SSISDB-Quelle und bestehende Exporte werden dabei bewahrt.
Die anschließenden eigenen [Docker-Ablauf-/Erneuerungsfälle](TLS_WINDOWS_SQL2025_EXPIRY_RENEWAL_2026-10-16.md)
und die getrennte [Podman-Probe](TLS_PODMAN_WINDOWS_SQL2025_ACCEPTANCE_2026-10-16.md)
bestanden inzwischen jeweils alle acht Windows-Clientfälle für SQL 2025 CU9.
Die spätere [Container-Versionsmatrix](TLS_WINDOWS_CONTAINER_VERSION_MATRIX_2026-10-16.md)
bestand dieselben acht Windows-Clientfälle separat für SQL 2019 CU32 und
SQL 2022 CU27 mit Docker und Podman, jeweils mit eigenem Cleanup.
Linuxclients, Hyper-V, Trustdrift, TLS-Abbruch/Resume, operative Registry und
V2-Export bleiben getrennte offene Nachweise.

Die [Microsoft-Anleitung für SQL Server unter Linux](https://learn.microsoft.com/en-us/sql/linux/security/encrypted-connections?view=sql-server-ver17)
ist die externe Referenz für den anschließenden nativen SQL-Konfigurationsscope;
sie ersetzt keine tatsächlich ausgeführte Lab-Abnahme.
