# Deklarative Windows-Sprach- und Regionalkonfiguration – Backlog

## Status

`BACKLOG` – fachlich akzeptiert, nicht als wiederverwendbarer
Manifest-/Batch-Vertrag implementiert. Reihenfolge und Priorität richten sich
nach dem kanonischen Entwicklungs- und Ausführungsplan.

## Ausgangslage

Der direkte Hyper-V-Klonpfad kann Region, System-Locale, UI-Sprache,
Eingabemethode und Zeitzone bereits über Parameter beziehungsweise die
interaktive Workflow-Oberfläche übernehmen. Diese Werte sind jedoch nicht Teil
des portablen Lab-Manifests. Eine gespeicherte Labkonfiguration kann deshalb
noch nicht vollständig festlegen, mit welchen Sprach-, Regions- und
Tastatureinstellungen ein Windows-Gast erstellt wird.

## Ziel

Eine Windows-Instanz soll ihre regionalen Einstellungen deklarativ und
run-unabhängig in der Labkonfiguration beschreiben können. Der Vertrag muss
mindestens folgende voneinander getrennte Intents abbilden:

- Heimatregion;
- System-Locale beziehungsweise Systemkultur;
- Windows-UI-Sprache;
- standardmäßiges Tastaturlayout beziehungsweise Windows-Eingabemethode;
- Windows-Zeitzone als bereits heute mit der OOBE gekoppelten Wert.

Die Werte gelten pro Windows-Instanz und müssen sowohl für reine
`OS_SEALED`-Klone als auch für `SQL_PREPARED_SEALED`-Klone konsistent an den
bestehenden OOBE-/Specialization-Pfad übergeben werden. Der genaue Schemapfad
wird bei der Umsetzung festgelegt; er darf die portablen Windows-Intents nicht
unnötig an lokale Hyper-V-Ressourcen binden.

## Vertragsgrenzen

- UI-Sprache, System-Locale, Region, Benutzerkultur, Eingabemethode und Sprache
  des Installationsmediums dürfen nicht stillschweigend gleichgesetzt werden.
- Die gewählte UI-Sprache muss durch das selektierte Image oder durch
  hashverifizierte, katalogisierte Offline-Sprachmedien unterstützt werden.
  Fehlende Language Packs oder ungültige Kombinationen werden vor der ersten
  VM-Mutation mit einer konkreten Meldung abgewiesen.
- Es gibt keinen stillen Rückfall auf deutsche Einstellungen, die Hostregion
  oder das Host-Tastaturlayout. Fehlt die Konfiguration, bleiben ausschließlich
  die ausdrücklich dokumentierten Kompatibilitätsdefaults wirksam.
- Portable Werte verwenden dokumentierte Windows-/Locale-Bezeichner. Lokale
  GeoIds oder vom Host abgeleitete Werte sind kein alleiniger
  Manifestvertrag.
- Das immutable Parent-Image bleibt unverändert. Die Einstellungen werden nur
  im run-eigenen Child und in der Gastspezialisierung angewendet.
- Manifest-Lock, Run-State und Receipt halten den normalisierten Intent und die
  tatsächlich beobachteten Werte ohne Secrets oder lokale Rohdaten fest.
- Manifest-, Batch-, Konsolen- und Workflow-UI-Pfade müssen denselben Resolver
  und dieselbe Validierung verwenden.

## Erwarteter Umsetzungsumfang

1. Schema und Parser um einen versionierbaren Windows-Locale-Intent ergänzen.
2. Manifest-Wizard und Batch-Normalisierung ohne eigene Defaultlogik anbinden.
3. Vorhandene Parameter des Hyper-V-OOBE-Pfads über den normalisierten Intent
   speisen und direkte Aufrufe kompatibel halten.
4. Image-/Medien-Capabilities für verfügbare UI-Sprachen vor der Mutation
   prüfen; nicht verfügbare Kombinationen fail-closed behandeln.
5. Ein portables Beispiel mit nicht deutschem Profil dokumentieren.
6. Known Limitations, Benutzerreferenz und gekoppelte Manifestverträge
   gemeinsam aktualisieren.

## Abnahmekriterien

- Ein Manifest mit Region `US`, System-Locale und UI-Sprache `en-US` sowie
  Eingabemethode `0409:00000409` erzeugt einen Windows-Gast, dessen
  Postconditions nach vollständigem Cold Start exakt diese Werte bestätigen.
- Derselbe Intent liefert über direkten Manifestlauf und Batch-Ausführung
  dieselbe normalisierte Planung und dasselbe Ergebnis.
- Eine vom gewählten Image nicht unterstützte UI-Sprache oder ungültige
  Eingabemethode wird vor der ersten Provider-Mutation nachvollziehbar
  abgewiesen.
- Ein Manifest ohne Locale-Intent behält die dokumentierte
  Rückwärtskompatibilität; es übernimmt keine impliziten Hostwerte.
- Statische Tests decken Schema, Normalisierung, Wizard/Batch-Weitergabe,
  Fail-closed-Validierung und Receipt-Bindung ab.
- Mindestens ein realer Hyper-V-Nachweis mit einem nicht deutschen Profil
  bestätigt OOBE, Region, UI-Sprache, Tastatur, Zeitzone, Cold Start und
  scopegebundenen Cleanup. Erst dieser Lauf darf als Runtime-Validierung
  bezeichnet werden.
