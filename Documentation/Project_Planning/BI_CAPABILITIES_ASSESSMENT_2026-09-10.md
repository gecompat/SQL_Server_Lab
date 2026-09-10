# Bewertung von SSIS, SSAS und der BI-Pipeline

| Merkmal | Wert |
|---|---|
| Status | `validated` (Bewertung; keine neue Runtimefähigkeit) |
| Stand | 2026-09-10 |
| Quellstand | `cff7aac6537fc63525747d33e0e49b33fca63a36` |
| Auftrag | Drei Bewertungszeilen des [Arbeitsplans](AUTONOMOUS_DEVELOPMENT_WAVE_2026-09-10.md) |

## Entscheidung und vorhandene Grundlage

Die drei Erweiterungen sind als SQL-zentrierte Testszenarien sinnvoll. Die
Umsetzung folgt nach den offenen Hyper-V-, State-, Recovery- und allgemeinen
Szenarioabnahmen in der Reihenfolge SSIS, SSAS, gemeinsame Pipeline. Der erste
Referenzstand bleibt Windows Server 2025 mit SQL Server 2025 Developer in einer
eigenen Hyper-V-VM. Edition, Features und Medien werden vor Umsetzung konkret
gebunden; eine erfolgreiche Database-Engine-Installation belegt keine
SSIS- oder SSAS-Installation.

Im untersuchten `Public/`-/`Private/`-Code werden SSISDB und SSAS im
[Migrationsabhängigkeitsvertrag](../../Private/DatabaseMigrationDependency.ps1)
als externe, separat zu behandelnde Komponenten geführt. Ein ausführbarer
SSIS-Deployment-/Execution- oder SSAS-Processing-Pfad ist dort nicht vorhanden.
Der [interne Szenariovertrag](SCENARIO_CONTRACT_BACKLOG.md) und die vorhandenen
SQL-/Hyper-V-Lifecycleverträge sind wiederzuverwenden; der geplante allgemeine
Executor bleibt eine Abhängigkeit. Ein neues Schema allein schließt keine
dieser Fähigkeiten ab.

Der relative Aufwand ist **L** für jeden einzelnen Dienst: Installation,
Artefakte, Identität, fachliche Assertions und Recovery müssen gemeinsam
funktionieren. Die kombinierte Pipeline ist ebenfalls **L**, zusätzlich zu
beiden Diensten, weil phasenübergreifende Wiederaufnahme eigene Fehlerfälle
besitzt. Eine belastbare Zeitangabe benötigt zunächst die Medien-/Toolprüfung.

## SSIS: begrenzter Warehouse-Durchstich

Der [SSIS-Backlog](SSIS_ETL_DATA_WAREHOUSE_BACKLOG.md) wird bestätigt. Der erste
Slice verwendet das Project-Deployment-Modell mit einem digestgebundenen
synthetischen Projekt, SSISDB und logisch getrennten Quell-/Warehouse-Datenbanken.
Zunächst werden SQL-Quellen und eine kontrollierte Änderungsfolge verwendet;
beliebige Connectoren, CDC und Scale Out bleiben spätere eigene Fähigkeiten.

| Grenze / Nutzen | Entscheidung, Risiko und Abnahme |
|---|---|
| Reproduzierbares Deployment | Runtime, Projekt-Zielversion und benötigte Client-/Buildwerkzeuge katalogisieren. Wiederholtes Deployment derselben Revision muss dieselbe Bindung liefern; geänderte Revision verlangt einen sichtbaren Plan. Freie fremde Packages bleiben ausgeschlossen. |
| Nachvollziehbare Datenänderung | Einen kleinen Full Load, unveränderten Rerun sowie Insert/Update/Delete aus einer synthetischen, monoton nummerierten Änderungsfolge prüfen. Erwartete Schlüssel, Zeilen, Summen und Rejects gehören zum Dataset. Ein bloßer Zeitstempel ohne Delete-/Gleichzeitigkeitsschutz reicht nicht. |
| Wiederaufnahme ohne Datenverlust | Staging-Batch und Ziel-Commit besitzen stabile Identitäten. Den bestätigten Fortschritt erst zusammen mit erfolgreicher Zielwirkung fortschreiben. Fehler vor und nach Commit sowie verlorene Antwort gezielt induzieren; erneute Ausführung darf weder Fakten verdoppeln noch Änderungen überspringen. Package-Checkpoints allein belegen diese Eigenschaft nicht. |
| Identität und Secrets | Eigene Folder/Projekte/Environments verwenden; Secretwerte nur lokal binden. SSISDB-Schlüssel und sensitive Parameter sind eigene Recovery-Grenzen. Rechte positiv und negativ prüfen; keine Werte in Command Lines, Logs oder portablen Receipts. |
| Betrieb und Cleanup | Zeitlimits, terminalen SSISDB-Ausführungsstatus, Stop/Start und VM-Neustart prüfen. Vor Objektentfernung aktive Executions beenden und Eigentum nachweisen. Ursprünglichen Fehler und Cleanupfehler getrennt erhalten. |

Der nächste Umsetzungsschritt ist eine isolierte Abnahme, die diese komplette
Folge vom installierten Dienst bis zum bereinigten Warehouse ausführt. Vorher
sind freigegebene Medien, Toolversionen, Ressourcenbudget und der ausführbare
Szenariokern erforderlich. SQL Agent Scheduling erhält einen eigenen Test,
bevor eine zeitgesteuerte Ausführung behauptet wird.

## SSAS: Tabular vor weiteren Modi

Der [SSAS-Backlog](SSAS_ANALYTICS_SEMANTIC_MODEL_BACKLOG.md) wird mit Import als
erster Lane bestätigt. Das Warehouse kann für die getrennte SSAS-Abnahme direkt
aus einer synthetischen SQL-Fixture stammen; ein noch fehlender ETL-Pfad darf
dadurch nicht als vorhanden erscheinen. Ein Modellartefakt und dessen
Compatibility Level, Clientbibliothek und Deploymentverfahren werden festgelegt.
Multidimensional und DirectQuery bleiben getrennte spätere Abnahmen.

| Grenze / Nutzen | Entscheidung, Risiko und Abnahme |
|---|---|
| Fachlicher Modellnutzen | Ein Star Schema mit Zeitdimension, einer Partition und wenigen Measures deployen und vollständig verarbeiten. DAX-Ergebnisse nach Baseline und kontrollierter Quelländerung exakt prüfen. Erfolgreiches Deployment allein genügt nicht. |
| Rechte und Datenfilter | Einen berechtigten, nicht administrativen Windows-Testbenutzer und einen unberechtigten Benutzer verwenden. Rollenmitgliedschaft und DAX-Zeilenfilter prüfen; zusätzliche freigebende Rollen müssen im Test ausgeschlossen werden. Administrative Abfragen belegen keine RLS-Wirkung. |
| Processing und Fehler | Quellzugriff und Processing gezielt unterbrechen; terminalen Fehler sichtbar führen. Wiederaufnahme muss einen vollständig abfragbaren Modellstand herstellen. Ein alter, weiterhin abfragbarer Stand ist noch kein erfolgreicher Refresh. |
| Wiederherstellung | Modellbackup auf ein unabhängiges eigenes Ziel restaurieren, Quellen-/Credential-Bindung prüfen und dieselben DAX-/Rechte-Assertions ausführen. Service-/VM-Neustart und Cleanup aller eigenen Modell-, Konto- und Artefaktbindungen gehören zur Abnahme. |

Der nächste Schritt ist ein eigenständiger Tabular-Referenzlauf mit diesen
Assertions. Domäne, Kerberos und mehrere Rechner werden erst in einer späteren
Topologie ergänzt; lokale Testidentitäten belegen diese Fähigkeiten nicht.

## BI-Pipeline: gemeinsame fachliche Abnahme

Der [Pipeline-Backlog](END_TO_END_BI_PIPELINE_BACKLOG.md) bleibt eine Komposition
der beiden Dienste. Nach ihren getrennten Abnahmen bindet ein Run Quellfolge,
SSIS-Projektrevision, Warehouse-Batch, Modellrevision und Processing-Ergebnis.
Nur wenn die erwartete Quellrevision im Warehouse und im DAX-Ergebnis sichtbar
ist, gilt die Pipeline als bereit. Ein grüner Dienststatus reicht nicht.

Der erste Lauf verwendet eine eigene VM und getrennte Datenbanken. Er prüft
Full Load, No-op, Delta, einen Abbruch vor dem Fakt-Commit und einen nach dem
Warehouse-Commit vor dem Processing. Resume verwendet den bereits bestätigten
Warehouse-Batch und verarbeitet den fehlenden Modellschritt weiter. Nach
VM-Neustart müssen dieselben fachlichen Ergebnisse und Generationen nachweisbar
sein. Fremde Ressourcen bleiben bei Cleanup erhalten; Teilbereitschaft und
Recoverybedarf bleiben sichtbar.

Der Nutzen ist eine durchgehende Regression vom SQL-Quellereignis bis zur
Analyse. Hauptrisiken sind doppelte Ladeeffekte, verlorene Deltas, veraltete
Modelldaten und überbreite Rechte. Der nächste Schritt nach beiden Dienstabnahmen
ist genau dieser gemeinsame Fehler-/Resume-Lauf. Mehrere Provider, Cluster,
Cloud, Reporting und Performanceverallgemeinerungen gehören nicht dazu.

## Herstellerabgleich und Prüfgrenze

Die folgenden Primärquellen wurden am 2026-09-10 gelesen. Die oben gewählte
Reihenfolge und Abnahme sind Projektentscheidungen; hier wurde kein Dienst
installiert und kein ETL-/DAX-Lauf ausgeführt.

- Microsoft trennt die vollständige [SSIS-Installation](https://learn.microsoft.com/en-us/sql/integration-services/install-windows/install-integration-services?view=sql-server-ver17), die Database Engine für SSISDB und zusätzliche Entwicklungswerkzeuge.
- Die [Linux-Grenzen](https://learn.microsoft.com/en-us/sql/linux/migrate/ssis-known-issues?view=sql-server-ver17) schließen unter anderem SSISDB aus; SSIS ist für SQL Server 2025 auf Linux nicht verfügbar. Docker-/Podman-SQL-Quellen erhalten deshalb keine implizite SSIS-Parität.
- Die [SSAS-Installation](https://learn.microsoft.com/en-us/analysis-services/instances/install-windows/install-analysis-services?view=sql-analysis-services-2025) legt einen Modus pro Instanz fest; Tabular und Multidimensional benötigen getrennte Instanzen.
- [Tabular-Rollen](https://learn.microsoft.com/en-us/analysis-services/tabular-models/roles-ssas-tabular?view=sql-analysis-services-2025) binden Windows-Benutzer oder -Gruppen. Rechte mehrerer Rollen sind kumulativ; administrative Rechte liefern keinen Nachweis wirksamer Zeilenfilter.
