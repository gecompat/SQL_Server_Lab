# TLS-001: Abschlusskriterien und verbleibende Arbeit

Stand: 2026-10-26. Gesamtstatus: **partial**.

Diese Arbeitsübersicht leitet sich aus den D1–D4-Entscheidungen, Slices und
sechs Akzeptanzkriterien des [kanonischen TLS-001-Backlogs](NEW_SQL_LAB_USE_CASES_BACKLOG.md#tls-001--authentifizierte-tls-verbindungen-der-testumgebungen)
ab. Sie ergänzt keine weiteren Pflichtachsen. Fachverträge und tatsächlich
ausgeführte datierte Nachweise bleiben maßgeblich; eine Planung ist kein PASS.

## Endliche Abschlussliste

| Pflichtblock | Bereits belegt oder entschieden | Für den vollständigen Abschluss noch nötig |
|---|---|---|
| D1–D4 und konkrete Clientkontexte | Operative Windows-Containerverträge und qualifizierte CA-/Clientbindung; V1/True und V2/False bleiben gemäß Projektentscheidung vom 2026-10-25 die ausreichende Vertragsbasis. | Noch benötigte Identitäten, Zugriffswege, Trust- und Lifecycle-/Retirementregeln für die offenen Kontexte konkret abschließen. D4-Consumerinventur und Cutovernachweise bleiben erforderlich. |
| Mindestmatrix und öffentlicher Hyper-V-Pfad | Drei operative SQL-Generationen mit Docker/Podman und beiden Windows-Clientstacks; sechs getrennte Linux-Kryptozellen; private Hyper-V-/SQL-2025-RTM-Referenz mit Windowsclients. | Hyper-V 2019/2022, fehlende Linux-Clientzellen an Windows-SQL-Zielen und die öffentliche Hyper-V-False-/Exportlane. Nicht zutreffende Kombinationen brauchen eine begründete Capabilitygrenze, keinen fingierten PASS. |
| Öffentlicher Linux-Pfad | Die Linux-Kryptomatrix belegt beide echten Stacks einschließlich negativer Zertifikatsfälle. | Öffentliche Registry-/Reader-/Export-/Consumerfähigkeit im vereinbarten Linux-Ausführungskontext implementieren und abnehmen. Kryptoproben allein schließen diesen Pfad nicht. |
| Operativer Zertifikatslebenszyklus | Zertifikatsnegativfälle, Container-Start-Epochen-Rebind und die [gezielte Metadaten-Recovery](../Quality/TLS_REBIND_RECOVERY_ACCEPTANCE_2026-10-25.md) für Docker/SQL 2025 CU9 und Podman/SQL 2019 CU32 sind getrennt belegt. | Reproduzierbare Erneuerung mit neuer Qualifikation, Fehlern, Abbruch/Resume und eigener Recovery/Rücknahme. Nur eigene journalisierte Bindungen zurücknehmen; vorbestehende Schlüssel und gemeinsam verwendeten Trust erhalten. |
| Consumer und gekoppelter Preflight | Windows-Toolbelt-Cutover für sechs Containerprofile ist abgenommen. Die Consumerinventur und die reparierten isolierten Reader besitzen einen begrenzten echten Windows-/Docker-V1-Preflight mit zehn Readerfamilien, zwei funktionalen Clients und eigenem Cleanup; der übergeordnete Kontroll-FAIL bleibt separat erhalten. | Verbleibende Analyze-/Schulungs-, öffentliche Linux-/Hyper-V- und weitere ausdrücklich behauptete Consumerkontexte gemäß Inventur abschließen. |
| Integration, Betrieb und Abschlusszuordnung | Implementierte Teilverträge und datierte Nachweise sind getrennt verlinkt. | Jedem Pflichtkriterium Vertrag, ausgeführten Nachweis oder offene Grenze zuordnen; erforderliche finale Gates, Integration sowie Betriebs-, Migrations- und Fehlerdiagnose abschließen. Eigenen Cleanup erledigen oder ausdrücklich genehmigten offenen Cleanup transparent ausweisen. |

Die [D4-Festlegung](TLS_001_ISOLATED_CA_DESIGN.md#d4--koordinierter-nachfolgevertrag)
verlangt keinen zusätzlichen gemeinsamen Exportnachfolger. Sie verändert
weder die bestehenden Schemas noch die übrigen Sicherheits-, Lifecycle-,
Matrix- und Consumerpflichten. Die nötige Toolbelt-Arbeit ist nach der direkten
menschlichen Anweisung vom 2026-10-25 innerhalb der
[aktuellen Arbeitsgrenze](../../.ai/PROJECT_CONTEXT.md#aktuelle-ki-arbeitsgrenze-für-tls-001)
wieder freigegeben. Der bereits abgenommene Windows-Cutover bleibt gültig.
Die [Consumerinventur](TLS_001_CONSUMER_INVENTORY.md) konkretisiert Reader-,
API-, Versions- und noch offene Preflightgrenzen.

## Mindestmatrix richtig lesen

Das vierte Akzeptanzkriterium verlangt die drei SQL-Generationen und getrennte
Docker-/Podman-/Hyper-V-Nachweise in den vereinbarten tatsächlichen Windows-
und Linux-Clientkontexten, jeweils mit beiden Clientstacks. Rechnerisch sind
das 18 Ziel-/Client-OS-Kombinationen, **keine 18 neuen Labs**. Ressourcen dürfen
nur innerhalb ihrer tatsächlich geprüften eigenen Bindung zusammengesetzt
genutzt werden; Ergebnisse verschiedener Quellstände bleiben getrennt.

Die direkte Projektentscheidung vom 2026-10-26 begrenzt generische Abläufe auf
einen repräsentativen gepinnten SQL-Build je tatsächlich anderer Implementierungs-,
Provider- und Clientgrenze. Die Tabelle verlangt keine vollständige Wiederholung
aller Funktionsfälle pro SQL-Generation. Fehlende Mindestzellen erhalten gezielte
Versionsnachweise; gemeinsame UI-, Lifecycle-, Export-, Recovery- und Consumerlogik
wird nach der [Versionsauswahl](../Quality/COST_EFFICIENT_DEVELOPMENT.md#sql-versionen-nach-tatsächlicher-abhängigkeit-auswählen)
zusammengefasst. Versionsabhängige Metadatenprüfungen bleiben kleine Offlinefälle.
Die laufende öffentliche Linux-Welle plant ausschließlich SQL 2025 CU9, getrennt
mit Docker und Podman. Das ist eine Planung, kein neuer Laufzeitnachweis.

| SQL-Generation | Docker / Windowsclient | Docker / Linuxclient | Podman / Windowsclient | Podman / Linuxclient | Hyper-V / Windowsclient | Hyper-V / Linuxclient |
|---|---|---|---|---|---|---|
| 2019 | belegt | Kryptonachweis belegt | belegt | Kryptonachweis belegt | offen | offen |
| 2022 | belegt | Kryptonachweis belegt | belegt | Kryptonachweis belegt | offen | offen |
| 2025 | belegt | Kryptonachweis belegt | belegt | Kryptonachweis belegt | private RTM-Referenz belegt | offen |

Die Tabelle ordnet Client-/Ziel-Kryptobelege zu. Sie behauptet keine
öffentliche Linux-Registry-/Export-/Consumerfähigkeit und keine öffentliche
Hyper-V-False-/Exportlane. Die Containerprofile sind konkret 2019 CU32,
2022 CU27 und 2025 CU9; die private Hyper-V-Referenz ist SQL 2025 RTM.
Quellen: [Windows-Container-Kryptomatrix](../Quality/TLS_WINDOWS_CONTAINER_VERSION_MATRIX_2026-10-16.md),
[operative Profile](../Architecture/AUTHENTICATED_TLS_OPERATIONAL_LAB.md),
[Linux-Kryptomatrix](../Quality/TLS_LINUX_CLIENT_MATRIX_ACCEPTANCE_2026-10-22.md),
[private Hyper-V-Referenz](../Quality/TLS_HYPERV_NATIVE_ACCEPTANCE_2026-10-20.md).

## Erreichte UI- und Consumergrenzen

Default- und authentifizierte Browser-Erstellung sowie die separate Liveaktion
sind für die drei operativen Containerprofile unter Windows mit compact und
getrennt standard/performance belegt. Die
[Clipboardabnahme](../Quality/TLS_UI_CONNECTION_CLIPBOARD_ACCEPTANCE_2026-10-25.md)
belegt vier kompakte Windows-/Docker-/Podman-SQL-2025-CU9-Zellen in beiden
Modi mit isolierter Browserzwischenablage. Der
[Windows-V2-Cutover](../Quality/TLS_V2_CONSUMER_CUTOVER_ACCEPTANCE_2026-10-22.md)
belegt seinen eigenen Consumerkontext. Diese Ergebnisse schließen ihre
Teilschritte; sie ersetzen nicht die offenen Pflichtblöcke oben.

## Was den Pflichtumfang nicht automatisch erweitert

Nicht jeder weitere CU, Browser, Ressourcenwert oder Erstellungsparameter
benötigt allein wegen seiner Existenz eine neue Abschlusswelle. Weitere
Varianten werden nur bei einer vereinbarten Capability, einer tatsächlich
anderen Implementierungsgrenze oder einer neuen ausdrücklichen Scopeentscheidung
zu Pflichtnachweisen. Unbekannte Kombinationen werden dadurch nicht als
abgenommen dargestellt.

Ein Hintergrunddaemon, `Encrypt=Strict`, globale CRL-/OCSP-Infrastruktur,
Wire-Mitschnitt und ein zwingend nativer Linuxhost folgen nicht automatisch
aus den bestehenden Kriterien. Ein tatsächlicher passender Clientkontext
und verschlüsselter SQL-Transport bleiben erforderlich. Der Wire-Fingerprint
bleibt `NOT_OBSERVED`. Restdauer, zusätzliche PRs und Labanzahl sind derzeit
nicht belastbar bestimmt; diese Übersicht ist keine Fertigstellungszusage
und keine Budget- oder Ausführungsfreigabe.
