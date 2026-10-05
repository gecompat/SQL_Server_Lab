# SA-Passwort vor der Containererstellung pruefen

Status: Backend, CLI und Browser offline implementiert; native Erststartabnahme
fuer Docker und Podman auf SQL2025-CU9 mit Mindestlaenge drei bestanden.
Gerenderter Browser, positiver HTTP-Creationjob und PR-Abschlussgate bleiben offen.

## Gemeinsame Barriere

`Private/SaPasswordPolicy.ps1` definiert mindestens acht, hoechstens 128 Zeichen
und mindestens drei der vier Gruppen Grossbuchstaben, Kleinbuchstaben, Ziffern
und Sonderzeichen. Der Check liefert nur `Valid` und feste `ReasonCodes`, keine
Passwortwerte, Hashes, gemessenen Laengen oder Gruppenbelegungen.
`New-SqlServerLab` prueft explizite, generierte und Manifestpasswoerter vor
Run-State, Secretpersistierung, Imagebuild und Providermutation. SQL-Readiness
bleibt erforderlich.

Nach erfolgreicher Vorpruefung legt der bestehende Erstellungsweg jedes
SA-Passwort verschluesselt run-lokal fuer Start und Restart ab. Nur ein vom Lab
erzeugtes Passwort erhaelt zusaetzlich den getrennten Herkunftsnachweis fuer
den oeffentlichen Abruf. Browserjob und Live-Log zeigen den Wert nicht an.

## Bewusster Ad-hoc-Entscheid

Der manuelle Konsolendialog fragt maskiert ab und erlaubt nach einem
Kriterienfehler Korrektur oder Abbruch zur neuen Zielauswahl. Bei reinem
Mindestlaengenfehler auf geeignetem Ziel kann der Benutzer eine Mindestlaenge
eins bis acht waehlen und bestaetigen. Passwortbestaetigung bleibt erforderlich
und vergleicht Gross-/Kleinschreibung. Es gibt keine abgeleitete Relaxation.

Der Browser zeigt katalogisierte SQL-2025-CUs neben den bisherigen gleitenden
Versionen. Er prueft Laenge und drei Zeichengruppen vor der Jobanlage. Nur bei
einem reinen Mindestlaengenfehler auf einem geeigneten neuen, kurzlebigen
Container zeigt er die getrennte Mindestlaengenauswahl und verlangt deren
ausdrueckliche Bestaetigung. Manifeststarts behalten die Standardkriterien.
Der Server prueft die begrenzte JSON-Form einschliesslich doppelter Felder,
unbekannter Parameter und Datentypen und fuehrt dieselbe Policy vor dem
Start eines Creationjobs erneut aus. Der oeffentliche Fachbefehl prueft sie
vor State und Provider. Fehlermeldungen enthalten keine Passwortwerte.

Der ausschliessliche AdHoc-Parameter `SaPasswordMinimumLength` besitzt Default
acht. Kleinere Werte beschreiben dieselbe ausdrueckliche Entscheidung. Zulaessig
sind nur Docker/Podman, exakt katalogisierte SQL2025-CUs, Standardlaunch und
neue runeigene kurzlebige Systemvolumes. Latest, andere Versionen, Manifest,
PersistentData, vorhandene Stores, Derived Images und kollidierende oder
mehrdeutige Mountziele erlauben nur Standardpolicy mit Passwortkorrektur.
Drei Gruppen und maximal 128 bleiben unveraendert. Mindestlaenge eins erlaubt
deshalb kein Ein-Zeichen-Passwort.

## Config und Recovery

Die bestehenden Volumeinitializer erzeugen vor SQLstart ausschliesslich in der
frischen eigenen `/var/opt/mssql`-Volume die feste Sektion `[passwordpolicy]`
mit `passwordminimumlength`. Nur der validierte Integer wird formatiert.
Vorhandene Dateien/Symlinks werden nicht ersetzt; Eigentum `10001:0`, Modus
`0660`. Keine neue Hostdatei, globale Hostpolicy oder Config-Bind-Mount.

OwnedHost verwendet denselben Seed im bestehenden gebundenen eigenen
ephemeral Container. Sein Created-Receipt beweist keinen erfolgreichen Seed:
Custominitialisierung einer vorhandenen Volume bleibt auch nach Teilfehlern
gesperrt. Configfehler melden `SA_PASSWORD_POLICY_CONFIG_SEED_FAILED`.
Der vorlaufende Cleanupplan entfernt Container vor eigener Volume; Cleanupfehler
bleiben getrennt sichtbar. Der SQL2025-State115-Erstellungsretry wird bei
Customminimum nicht ausgefuehrt. Neue Erstellung verlangt abgeschlossenen
Cleanup beziehungsweise geklaertes Recovery.

Start/Restart und bestehende Recreatewege erhalten die Volumeconfig. Kein
Manifest-/DesiredStateausbau, kein Policywechsel bestehender Labs und kein
SQL-`ALTER LOGIN`- oder Bootstrap-Passwortumweg.

## Quelle und Nachweisgrenze

[Microsofts Linux-Passwortpolicy](https://learn.microsoft.com/en-us/sql/linux/security/authentication/custom-password-policy?view=sql-server-ver17)
unterstuetzt Mindestlaengen unter acht ab SQL2022 CU23 und SQL2025. Das belegt
keinen initialen SA-Erststart des konkreten Containerimages.

`Invoke-SaPasswordPolicyChecks.ps1` fuehrt Check, Publicbarriere, maskierten
Dialog, echte CLI-Route, beide Providerinitializer und OwnedHost-Teilreceipt
synthetisch aus. Die WorkflowUI-Fixtures fuehren den echten Browserdialog und
den serverseitigen Action-Routebody mit synthetischen Jobs aus. Kein
Providerprozess, SQL, Listener oder echte Secretquelle.
Am 2026-10-06 bestand `Invoke-SaPasswordPolicyAcceptance.ps1` auf dem
Produktstand `12af45ed` getrennt fuer Docker und Podman: ein frischer eigener
SQL2025-CU9-Run mit bewusst ausgewaehlter Mindestlaenge drei, tatsaechlicher
SA-Anmeldung, unveraenderter Config nach Restart und bestaetigtem Cleanup von
Run, Container, Volume und temporaerem Root. Vorher und nachher waren alle
sechs geschuetzten Umgebungen laufend und gebunden; der Vergleich ergab null
Findings. Der erste Docker-Testlauf scheiterte an einer zu engen
Test-Bindungsannahme fuer die run-spezifische Volume und wurde nach erneuter
Ownershippruefung vollstaendig aufgeraeumt; der korrigierte Test bestand.
Andere Mindestlaengen und CU-Images sind damit nicht empirisch abgenommen.
`Invoke-SaPasswordHttpNetworkAcceptance.ps1` bestand am 2026-10-06 mit
eigenem Loopback-Listener: drei ungueltige bzw. doppelte Requests wurden
vor der Jobanlage abgewiesen, ohne Passwortwert in der Antwort. Der Listener
und sein Testroot wurden entfernt. Ein gueltiger Creationjob ueber echten
HTTP-Transport und die gerenderte Browserbedienung bleiben `NOT_EXECUTED`.
Impactselektion und PR-Abschlussgate benoetigen den vollstaendigen stabilen Stand.
