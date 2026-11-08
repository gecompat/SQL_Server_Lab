# SqlPackage DACPAC DeployReport: No-op-Plan vor Wiederholungspublish

## Umfang und Quellbindung

Am 2026-11-08 wurde der vorhandene DACPAC-Akzeptanzlauf um einen echten
`DeployReport`-Preflight ergänzt. Docker und Podman liefen getrennt mit
SQL Server 2022 und SqlPackage `170.5.96.0`. Die Läufe basieren auf
`Tests/Integration/Invoke-ContainerToolAcceptance.ps1` mit SHA-256
`BD4B0D92241EA8EA6D53885257A0132F4D1DAC2524B9FB83488B3B1C528CA75E` auf
Basiscommit `43346aa67952ee544a5ec5d5e957108e6a7bd333`; der geprüfte Quellstand
enthielt die unten beschriebene DeployReport-Assertion.

| Provider | Assertions | DeployReport | Wiederholtes Publish / Datenerhalt | Run-/Image-Cleanup |
|---|---:|---|---|---|
| Docker | 41 | `PASS`, keine Schemaoperationen | `PASS`, synthetische Zielzeile erhalten | `PASS` |
| Podman | 41 | `PASS`, keine Schemaoperationen | `PASS`, synthetische Zielzeile erhalten | `PASS` |

Zwei vorangegangene Docker-Entwicklungsversuche scheiterten an einer zu strengen
Testannahme: SqlPackage lässt den leeren XML-Abschnitt `Operations` weg. Beide
eigenen Runs wurden trotzdem regulär entfernt. Die abschließende Assertion prüft
deshalb das `DeploymentReport`-Root und das Fehlen von `Operation`-Elementen;
die tatsächlich erzeugten Berichte werden nicht versioniert. Die endgültigen
Docker- und Podman-Läufe bestanden mit demselben Skript-Hash.

## Geprüfter Ablauf

Nach dem ersten Publish fügt der Test eine synthetische Zeile in die
Zieldatenbank ein. Der kataloggebundene SqlPackage-Aufruf erzeugt danach einen
`DeployReport` mit denselben expliziten Eigenschaften
`BlockOnPossibleDataLoss=True` und `DropObjectsNotInSource=False`. Der Test
verlangt valides XML mit dem Root `DeploymentReport` und null
`Operation`-Elementen. Das belegt, dass für den wiederholten Publish keine
Schemaoperation geplant ist, obwohl die Zieldatenzeile erhalten bleiben muss.

Der Bericht wird aus dem eigenen Container in das eigene temporäre
Testverzeichnis kopiert, sicher als XML eingelesen und von beiden Orten
entfernt. Rohbericht, lokale Logs, Run-IDs, Hostpfade und Credentials bleiben
außerhalb des Repositories. Die Tests entfernten je Provider ihren Run, das
Volume und ausschließlich das test-eigene Derived-Image-Tag; vorhandene Images
blieben erhalten.

## Grenzen

Dieser Slice prüft nur einen No-op-Plan nach dem eigenen ersten Publish und
einer synthetischen Datenänderung. Er belegt keine tatsächliche Schema-Drift,
keine Korrektur von Drift, keine Datenmigration und keine fehlgeschlagenen
Releases. Es entsteht kein öffentlicher Deployment-Handler. Die ältere
[DACPAC-Publish-Abnahme](SQLPACKAGE_DACPAC_PUBLISH_ACCEPTANCE_2026-11-08.md)
bleibt als Quell- und Laufzeitnachweis für den ersten Slice erhalten.
