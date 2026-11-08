# SqlPackage DACPAC: kontrollierte Schema-Drift erkennen und korrigieren

## Umfang und Quellbindung

Am 2026-11-08 wurde der SQL-2022-Container-Akzeptanzlauf um einen begrenzten
Driftfall erweitert. Docker und Podman liefen getrennt mit SqlPackage
`170.5.96.0`. Beide Läufe verwendeten
`Tests/Integration/Invoke-ContainerToolAcceptance.ps1` mit SHA-256
`1CA4867CC096113AFC63E6BA7172BDA6F46D8C0F08A1999BA74F4D319FD3C2E2` auf
Basiscommit `32946d27e4166e47099a97c1093166a49989fa56`.

| Provider | Ergebnis | Erkannte Drift | Korrektur und Datenerhalt | Eigener Cleanup |
|---|---|---|---|---|
| Docker | PASS | `DeployReport` plante Operationen nach sicherer Verengung von `nvarchar(40)` auf `nvarchar(24)` | Publish stellte `nvarchar(40)` wieder her; synthetische Zielzeile blieb erhalten | PASS |
| Podman | PASS | `DeployReport` plante Operationen nach derselben kontrollierten Drift | Publish stellte `nvarchar(40)` wieder her; synthetische Zielzeile blieb erhalten | PASS |

Die vorherige No-op-Assertion bleibt erhalten. Der Driftfall verändert nur die
eigene temporäre Testdatenbank. Vor der Verengung bestätigt der Test, dass die
vorhandenen Markerwerte in `nvarchar(24)` passen. Das Wiederherstellungspublish
behält `BlockOnPossibleDataLoss=True` und `DropObjectsNotInSource=False` bei.

## Geprüfter Ablauf

Nach dem ersten Publish und einer synthetischen Zielzeile erzeugt SqlPackage
einen gültigen `DeploymentReport` ohne Schemaoperationen. Anschließend verengt
der Test die Zielspalte auf `nvarchar(24)` und prüft ihre tatsächliche Breite
sowie die maximale Länge der vorhandenen Testwerte. Ein zweiter
`DeployReport` muss mindestens eine `Operation` enthalten. Das erneute Publish
stellt die Modellbreite von `nvarchar(40)` wieder her und erhält die
synthetische Zielzeile.

Beide XML-Berichte werden mit deaktivierten DTDs und begrenzter Dokumentgröße
eingelesen. Host- und Runkopien werden auch im Fehlerpfad entfernt; Run,
Volume und ausschließlich das test-eigene Derived Image werden nach jedem
Providerlauf bereinigt. Laufzeit-Receipts und vollständige Logs bleiben in
ignorierten lokalen Testartefakten; keine Rohberichte oder Runtimewerte sind
versioniert.

## Grenzen

Der Nachweis umfasst genau eine synthetische Spaltenbreiten-Drift auf SQL 2022
unter Docker und Podman. Er belegt weder beliebige Driftkorrekturen noch
Datenmigration, fehlgeschlagene Releases, Rollback oder Repair nach
Teilpublikation. SQL Server 2019/2025, weitere DACPAC-Modelle und
Windows-Toolchains benötigen getrennte Nachweise. Es entsteht kein öffentlicher
DACPAC-Deployment-Handler.

Der frühere [No-op-DeployReport-Nachweis](SQLPACKAGE_DACPAC_DEPLOY_REPORT_ACCEPTANCE_2026-11-08.md)
und die [erste DACPAC-Publish-Abnahme](SQLPACKAGE_DACPAC_PUBLISH_ACCEPTANCE_2026-11-08.md)
bleiben als getrennte historische Quellstände erhalten.
