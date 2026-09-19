# Deklarative Instanzbewertung

Der private CORE-102-Teilvertrag `SqlServerLab.InstanceCapabilityAssessment/1.0`
fasst beim Erstellen des Desired-State-Snapshots die vorhandenen Metadaten
zusammen. `Intents.CapabilityAssessment` ist ein optionales Feld des unverändert
versionierten `SqlServerLab.InstanceIntent/1.0` im `RunDesiredState/1.0`.

Die geschlossene Projektion enthält:

- Providername und deklarierte Verfügbarkeit;
- aufgelöstes OS und dessen bestehende Docker-/Podman-Linux- beziehungsweise
  Hyper-V-Windows-Grenze;
- angeforderten SQL-Bezeichner, Katalog-ID und den bestehenden
  `Test-SqlServerVersionSupported`-Entscheid ohne zusätzliche Freigabeschalter;
- erforderliche Network-Capability, Intentstatus und festen Reason-Code;
- sortierte Drive-Bindingklassen und erforderliche Storage-Capabilities;
- sortierte Software-Capabilities und Reason-Codes des vorhandenen Resolvers;
- Gesamtstatus und höchstens sechs sortierte, eindeutige Blockercodes.

`DECLARED_SUPPORTED` beschreibt ausschließlich die Grenze
`catalog-and-provider-metadata`. Es ist weder ein aktueller Runtime-Nachweis
noch eine Ausführungsfreigabe. SQL-Deprecation wird unabhängig von einer
anderweitig ausdrücklich erteilten Erstellungsausnahme sichtbar belassen.
Ohne SQL-, Drive- oder Softwareanforderung ist die jeweilige Dimension
`NOT_REQUESTED`. SQL-Bezeichner außerhalb der begrenzten Versionsgrammatik
werden ohne Spiegelung als `UNKNOWN` projektiert. Netzwerk und Software
behalten die Entscheidungen ihrer bestehenden Resolver.

Die Storage-Projektion bewertet nur die vorhandenen Drive-Intents. Sie trifft
keine Aussage über physische Datenträger, freie Kapazität, lokale Bindings oder
die Ausführbarkeit eines Storage-Plans. Es werden keine Host-/Gastpfade,
Ports, Secrets, Runtime-IDs, Softwarebefehle oder Rohfehler übernommen.
Unbekannte Capability- oder Reason-Werte werden durch das geschlossene Schema
abgewiesen; sie müssen bei einer bewussten Vertragserweiterung geprüft werden.

`Get-LabPersistedDesiredState` akzeptiert alte Snapshots ohne dieses Feld
unverändert. Ein vorhandener ungültiger, nullwertiger oder anders versionierter
Assessment-Vertrag ergibt `INVALID` mit `INSTANCE_CAPABILITY_ASSESSMENT_INVALID`.
Der Reader ergänzt oder migriert keine Daten. Die Validierung prüft Schema,
Sortierung und interne Statuskonsistenz, ohne historische Daten erneut gegen
den aktuellen Katalog auszuwerten.

Die manifestgebundenen Hyper-V-Reconcile-Pfade für External Runtimes,
Testdatenbanken und SQL-Konfiguration übergeben ihren validierten bisherigen
Snapshot an den Target-Rebuild. Dieser bewahrt bei exakt ID-/Provider-gleichen
Legacy-Instanzen die Abwesenheit des optionalen Felds. Dadurch bleiben die
vollständigen JSON-Vergleiche anderer Instanzen unverändert wirksam und ein
späterer Commit ergänzt dort keine Metadaten. Neue Instanzen erhalten das
Assessment; vorhandene Assessment-Felder bleiben Bestandteil des Vergleichs.

Die Offline-Suite `Tests/Static/Invoke-InstanceCapabilityAssessmentChecks.ps1`
prüft positive Providerfälle, unsupported Tuple, unbekanntes SQL, fehlende
Anforderungen, deterministische Mengen, Sanitierung und den tatsächlichen
Desired-State-Reader mit synthetischem Run-Transport. Runtime-Probes,
öffentliche API, Manifestvalidierung, Reconcile-Plan und SCN-803 bleiben
außerhalb dieses Vertrags.
