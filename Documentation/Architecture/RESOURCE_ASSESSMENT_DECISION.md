# Resource-Assessment-Entscheidung und Persistenz

Status: `implemented_partial` für CORE-111.

`New-SqlServerLab` verwendet für Docker, Podman und den manifestgebundenen
Hyper-V-Pfad denselben Erstellungs-Preflight. Der Gesamtstatus übernimmt alle
Details mit der Priorität `RESOURCE_HARD_BLOCK`,
`RESOURCE_INSUFFICIENT_OVERRIDABLE`, `RESOURCE_WARNING`, `RESOURCE_OK`.
Insbesondere bleiben RAM-Unterversorgung und fehlende freie Container-Hostports
sichtbar. Reine Hyper-V-Labs verwenden Gastadressen und brauchen keine
Container-Hostports; gemischte Assessments zählen nur Containerinstanzen.
Die gemessenen Detailwerte werden durch eine Freigabe nicht verändert.

Der private Vertrag `SqlServerLab.ResourceAssessmentRecord/1.0` unterscheidet:

| Execution | Bedeutung |
|---|---|
| `EXECUTED` | Assessment ausgeführt; zulässige Werte oder Warnungen erlauben die Erstellung. Unterversorgung ohne Freigabe und harte Sperren blockieren. |
| `OVERRIDDEN` | Tatsächlich gemessene übersteuerbare Unterversorgung mit explizitem `-AllowResourceOvercommit` oder `resourceOverrides.allowResourceOvercommit=true`. |
| `SKIPPED` | Bestehendes `-SkipAssessment` beziehungsweise `resourceOverrides.skipAssessment=true`; keine Messung und kein Nachweis ausreichender Ressourcen. |

Ein ungenutztes Overcommit-Opt-in macht weder einen normalen noch einen
übersprungenen Preflight zu `OVERRIDDEN`. Harte Sperren eines ausgeführten
Assessments bleiben auch bei Overcommit blockierend. Skip führt das Assessment
weiterhin nicht aus; nachfolgende Provider-, Pfad- und SQL-Prüfungen bleiben
aktiv. Unbekannte Messstatus und widersprüchliche Records werden abgewiesen.

Erlaubte Entscheidungen werden einschließlich Timestamp, vollständigem lokalen
Assessment und explizitem Opt-in in `run-state.json` unter
`metadata.resourceAssessment` vor der ersten Providermutation gespeichert.
Abgewiesene Entscheidungen erzeugen keinen Run. Lokale Messungen können
Hostwerte enthalten und dürfen nicht als Repository-Evidence exportiert werden.
Eigenständige interne Image-/VM-Builder behalten ihren bisherigen Preflight;
der optionale interne Hyper-V-Parameter erweitert ausschließlich die
Durchreichung des öffentlichen `New-SqlServerLab`-Pfads.

Der read-only Lifecycle-Reconcile zeigt unter `Desired.ResourceAssessment`
nur feste Status-, Entscheidungs- und ReasonCode-Werte. Messwerte, Texte,
Kategorien, Provider-Versionen, Zeitstempel und Pfade werden nicht projiziert.
Fehlende Records liefern `NOT_RECORDED_LEGACY`, ungültige `INVALID_RECORD`.
Lesen schreibt keine Records nach. Die strikte persistierte Form
`SqlServerLab.RunDesiredState/1.0` bleibt unverändert. Die Projektion bewertet
historischen Erstellungs-Preflight; sie ist keine aktuelle Kapazitätsmessung
und erteilt keine Reconcile-Ausführungsfreigabe.

Der Slice ändert die vorhandenen Kapazitätsmodelle nicht: RAM verwendet
weiterhin Ressourcenprofile, Storage eine grobe Schätzung, Ports die
verfügbare Anzahl im Lab-Bereich. Angeforderte Einzelports, explizite
Runtime-RAM-Werte, Hostreserve, CPU-Kapazität und rollenbezogener Peakbedarf
sind damit nicht vollständig bewertet. Spezialisierte Reconcile-Pläne erhalten
in diesem Slice keine zusätzliche Assessment-Projektion.

Offline-Einstieg: `Tests/Static/Invoke-ResourceAssessmentChecks.ps1`.
Die Suite prüft Entscheidungen, unveränderte Messungen, lokale Persistenz,
hostwertfreie Projektion, Legacy-Byteidentität, Manifestauflösung und die drei
öffentlichen Provider-Erstellungspfade bis zur Persistenzgrenze mit
synthetischen Providergrenzen. Native Docker-, Podman-, Mixed- und Hyper-V-
Nachweise bleiben getrennte Validierung.
