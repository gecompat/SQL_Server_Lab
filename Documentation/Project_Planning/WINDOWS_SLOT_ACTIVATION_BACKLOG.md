# Automatische Windows-Slot-Aktivierung – Backlog

## Status

`BACKLOG` – fachlich akzeptiert, für automatisierte Windows-Testumgebungen
teilweise implementiert, noch kein allgemeiner Windows-Slot-Lifecycle-Vertrag.
Reihenfolge und Priorität richten sich nach dem kanonischen Entwicklungs- und
Ausführungsplan.

## Ausgangslage

SQL_Server_Lab kann den Windows-Lizenzstatus eines eindeutigen Hyper-V-Child-
Slots bereits live prüfen, eine noch nicht aktivierte Windows-Server-Evaluation
online aktivieren und das Ergebnis im Run-State festhalten. Dieser Ablauf wird
derzeit nur über den speziellen Intent automatisierter Testumgebungen
angefordert. Reguläre Windows- und SQL-Slots besitzen noch kein gemeinsames
Aktivierungs-Reconcile vor ihrem Bereitstatus.

Der heutige Evaluationspfad hängt bei Aktivierungsbedarf immer eine zusätzliche
NIC mit temporärem Eigentum an und entfernt genau diese danach wieder. Ein
künftiger allgemeiner Vertrag muss zusätzlich berücksichtigen, dass eine
External-NIC bereits zum gewünschten dauerhaften Netzwerkzustand des Slots
gehören kann.

## Ziel

Jeder eindeutige, verwendbare Windows-Child-Slot soll nach OOBE beziehungsweise
Specialization und vor SQL Setup oder Veröffentlichung als `READY` automatisch
einen live bestätigten Lizenzzustand erreichen. Das gilt für reine Windows-
Slots und SQL-Slots unabhängig davon, ob sie über Konsole, Workflow-UI,
Manifest, Batch oder Testumgebung erzeugt beziehungsweise wiederaufgenommen
werden.

Immutable Parent-Images, generalisierte Vorlagen und Builder vor ihrer
Publikation sind keine aktivierungspflichtigen Slots. Die Aktivierung erfolgt
ausschließlich im eindeutigen run-eigenen Child und verändert niemals das
Parent-Artifact.

## Zustands- und Strategievertrag

- `EVALUATION_ACTIVE` und `LICENSED` sind idempotente No-op-Ziele; eine bereits
  aktive Lizenz löst weder erneute Aktivierung noch Netzwerkmutation aus.
- Eine noch nicht aktivierte, gültige Windows-Server-Evaluation wird
  standardmäßig online aktiviert und anschließend erneut live verifiziert.
- Eine abgelaufene Evaluation wird nicht verlängert, manipuliert oder als
  bereit veröffentlicht.
- Eine nicht aktivierte Vollversion wird nicht blind über die öffentliche
  Microsoft-Aktivierung behandelt. Sie benötigt eine ausdrücklich
  konfigurierte und für Edition sowie Medium geeignete Strategie, zum Beispiel
  KMS, ADBA oder MAK. Fehlt diese, bleibt der Slot fail-closed
  `ACTIVATION_REQUIRED`.
- Product Keys, Aktivierungs-Credentials und private Aktivierungsendpunkte
  werden nicht im Manifest, Run-State, Log oder Receipt gespeichert. Eine
  spätere Strategie verwendet ausschließlich den bestehenden Secret- und
  lokalen Konfigurationsvertrag.
- Der normalisierte Aktivierungsintent, der beobachtete Lizenzstatus, die
  angewandte Strategie und das sanitisiert klassifizierte Ergebnis werden
  persistiert. Ein Plan oder gespeichertes Ablaufdatum ersetzt keine Live-
  Prüfung.

## Netzwerk- und NIC-Eigentum

Vor jeder Netzwerkmutation werden gewünschte und tatsächlich vorhandene
Adapter nach stabiler VM-/Adapteridentität und Eigentum klassifiziert:

- Eine External-NIC, die Teil des gewünschten dauerhaften Slotnetzwerks ist,
  wird für die Aktivierung verwendet, sofern sie bereits geeignete
  Konnektivität besitzt. Sie bleibt nach Erfolg, Fehler, Resume und Cleanup des
  Aktivierungsschritts unverändert am Slot.
- Eine vorhandene dauerhafte External-NIC wird niemals deshalb entfernt,
  umbenannt oder auf DHCP zurückgesetzt, weil der Aktivierungsschritt endet.
- Nur wenn keine geeignete dauerhafte Verbindung vorhanden ist und die
  Aktivierungs-Egress-Policy es erlaubt, darf der Aktivierungsschritt eine
  zusätzliche run- und scopegebundene temporäre NIC erzeugen.
- Ausschließlich eine nachweislich vom Aktivierungsschritt erzeugte temporäre
  NIC wird im `finally`-/Recovery-Pfad wieder entfernt. Name allein genügt
  nicht als Eigentumsnachweis.
- Ist eine dauerhafte External-NIC vorhanden, aber für die Aktivierung nicht
  verwendbar, bleibt sie bestehen. Eine gegebenenfalls zusätzlich erzeugte
  temporäre NIC besitzt eine getrennte Identität und Cleanup-Verantwortung.
- Ein ausdrücklich isolierter Slot erhält keinen stillen Internetzugriff. Die
  Planung muss vor der ersten Mutation zwischen erlaubtem temporärem
  Aktivierungs-Egress, ausschließlich vorhandenem persistentem Egress und
  verbotenem Egress unterscheiden. Ein unauflösbarer Konflikt bleibt
  `ACTIVATION_REQUIRED` statt die Isolation zu umgehen.

## Erwarteter Umsetzungsumfang

1. Den vorhandenen Lizenz-Probe- und Evaluationspfad zu einem allgemeinen,
   idempotenten Windows-Slot-Aktivierungs-Reconcile erweitern.
2. Aktivierungsstrategie und Egress-Policy als versionierten, portablen Intent
   modellieren; den endgültigen Schemapfad bei der Umsetzung festlegen.
3. Den Reconcile nach OOBE/Specialization sowie bei Resume, Start und Repair an
   alle Windows-Child-Slot-Pfade binden.
4. Gewünschte persistente, vorhandene fremde und aktivierungseigene temporäre
   NICs anhand stabiler Identität unterscheiden und getrennt quittieren.
5. Manifest-, Batch-, Konsolen-, Workflow-UI- und Testumgebungspfade über
   denselben Resolver führen; das heutige spezielle
   `WindowsActivationRequired`-Verhalten kompatibel übernehmen.
6. Benutzerreferenz, Known Limitations, Netzwerkvertrag, Manifestbeispiele und
   gekoppelte statische sowie reale Hyper-V-Prüfungen gemeinsam aktualisieren.

## Abnahmekriterien

- Ein neuer Evaluations-Child-Slot wird nach OOBE automatisch aktiviert, live
  als `EVALUATION_ACTIVE` bestätigt und erst danach für SQL Setup oder `READY`
  freigegeben.
- Ein bereits `EVALUATION_ACTIVE` oder `LICENSED` gemeldeter Slot erzeugt bei
  Erstellung, Resume, Start und Repair keine Aktivierungs- oder
  Netzwerkmutation.
- Besitzt der Sollzustand eine dauerhafte External-NIC, verwendet der
  Aktivierungspfad diese bei vorhandener Konnektivität. Adapter-ID, Switch-
  Bindung und Vorhandensein sind vor und nach der Aktivierung identisch.
- Ohne dauerhafte geeignete Verbindung wird eine erlaubte temporäre
  Aktivierungs-NIC nach Erfolg und nach kontrolliert induziertem Fehler exakt
  entfernt; persistente und fremde NICs bleiben unangetastet.
- Ein isolierter Slot ohne erlaubten Aktivierungs-Egress wird vor der
  Netzwerkmutation nachvollziehbar blockiert und nicht als `READY`
  veröffentlicht.
- Eine nicht aktivierte Vollversion ohne konfigurierte geeignete Strategie
  bleibt `ACTIVATION_REQUIRED`; es wird weder ein Schlüssel geraten noch eine
  öffentliche Aktivierung blind ausgelöst.
- Manifestlauf, Batch, interaktiver Workflow und automatisierte Testumgebung
  liefern für denselben Intent denselben Plan, Status und NIC-Cleanup-Vertrag.
- Statische Tests decken Zustandsmatrix, Strategieauflösung, NIC-Eigentum,
  No-op, Fehlerkompensation und Secret-Freiheit ab. Reale Hyper-V-Nachweise
  bestätigen mindestens Evaluation mit persistenter External-NIC sowie
  Evaluation mit temporärer Aktivierungs-NIC und Cleanup. Erst diese Läufe
  dürfen als Runtime-Validierung bezeichnet werden.
