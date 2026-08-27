# Repository-Continuity bei Ausfall der Validierungsinfrastruktur

| Merkmal | Wert |
|---|---|
| Status | `BINDING_IMPLEMENTED` |
| Stand | 2026-08-27 |
| Zielbranch | `main` |
| Normaler Pflichtcheck | `PR Gate` |

## Zweck

Der geschützte Branch bleibt der dauerhafte Koordinationskanal des Projekts.
Ein Ausfall von GitHub Actions oder der Self-hosted Runner darf diesen Kanal
nicht dauerhaft blockieren. Der Notfallpfad erhält trotzdem den Pull Request,
die Auditspur und den Schutz vor direkten oder destruktiven Änderungen.

Break-Glass ist ausschließlich ein Verfügbarkeitsverfahren. Es macht eine
nicht ausgeführte Prüfung nicht grün und schwächt keinen festgestellten Fehler
ab.

## Aktive GitHub-Regeln

Auf `refs/heads/main` wirken zwei aktive Repository-Rulesets zusätzlich zur
bestehenden Branch Protection:

| Ruleset | Regeln | Bypass |
|---|---|---|
| `Core safety - main` | Pull Request erforderlich, Branch-Löschung blockiert, Force-Push blockiert | keiner |
| `CI gates - main` | strikter, aktueller Statuscheck `PR Gate` | ausschließlich Repository-Eigentümer, `For pull requests only` |

Der CI-Bypass erlaubt keinen direkten Push. Auch im Notfall muss eine Änderung
über einen Pull Request nach `main` gelangen. Die Core-Safety-Regeln können
nicht umgangen werden. Die bestehende Merge-Commit-Konvention bleibt zulässig;
lineare Historie wird deshalb nicht zusätzlich erzwungen.

## Entscheidung vor einem Bypass

Der blockierte Check erhält genau eine Klassifikation:

| Klassifikation | Bedeutung | Bypass |
|---|---|---|
| `VALIDATION_FAILURE` | Der Check lief und fand einen inhaltlichen Fehler. | verboten |
| `INFRASTRUCTURE_UNAVAILABLE` | Actions, Runner oder Plattform können kein vertrauenswürdiges Ergebnis erzeugen. | nach diesem Runbook zulässig |
| `UNKNOWN` | Ursache oder Aussagekraft ist nicht geklärt. | verboten |

`INFRASTRUCTURE_UNAVAILABLE` erfordert konkrete Infrastruktur-Evidence, zum
Beispiel einen bestätigten GitHub-Statusvorfall, einen nachgewiesen offline
befindlichen erforderlichen Runner oder einen Job, der wegen der
Ausführungsinfrastruktur nicht starten kann. Ein Timeout oder Absturz durch
Projektcode ist ein `VALIDATION_FAILURE`, kein Infrastrukturvorfall.

## Pflichtablauf

1. Pull Request mit unverändertem Head-Commit und aktuellem `main` verwenden.
2. Blockierten Check und Ursache klassifizieren.
3. Lokal ausführbare deterministische Prüfungen gegen genau diesen Head-Commit
   ausführen; Provider-Nachweise bleiben getrennt.
4. Im Pull Request dokumentieren:
   - betroffene Checks und beobachtete Infrastrukturstörung;
   - Head- und Base-Commit;
   - lokal ausgeführte Prüfungen und Ergebnisse;
   - nicht reproduzierbare Prüfungen;
   - Restrisiko;
   - Entscheidung des Repository-Eigentümers;
   - verpflichtende Nachholvalidierung nach Wiederherstellung.
5. Nur der Repository-Eigentümer darf im Pull Request den CI-Ruleset-Bypass
   auswählen und den PR mergen.
6. Kein grünes Statussignal erzeugen, simulieren oder manuell fälschen.

## Nachholvalidierung

Sobald die Infrastruktur wieder verfügbar ist:

1. alle umgangenen Checks gegen den gemergten Commit oder eine nachweislich
   identische Revision ausführen;
2. Ergebnis im ursprünglichen Pull Request oder einem verknüpften
   Korrekturvorgang dokumentieren;
3. bei einem inhaltlichen Fehler sofort einen Korrektur- oder
   Wiederherstellungs-PR öffnen;
4. den Notfall erst schließen, wenn jede ausgesetzte Prüfung ein wahrheitsgetreues
   Ergebnis besitzt.

## Administrative Verifikation

Die tatsächliche GitHub-Konfiguration ist die Runtime-Autorität. Sie wird über
die Repository-Rulesets-API oder die GitHub-Oberfläche geprüft. Erwartet werden
genau die oben genannten aktiven Rulesets, kein Core-Safety-Bypass und
`pull_request` als Bypass-Modus des CI-Rulesets. Ruleset-IDs werden nicht im
Repository festgeschrieben, weil sie GitHub-interne, ersetzbare Identitäten
sind.
