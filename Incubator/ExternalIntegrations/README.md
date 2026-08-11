# External Integrations Incubator

## Status

`INCUBATING_IN_MAIN_REPOSITORY`

Dieser Ordner bündelt begrenzte Untersuchungen zu externen Projekten, die
einzelne Ausführungs- oder Unterstützungsfunktionen von `SQL_Server_Lab`
übernehmen könnten.

Der Inkubator ist kein eigenständiges Produkt und kein zweiter
Orchestrierungs-Core. Er wird gemeinsam mit `SQL_Server_Lab` geplant,
versioniert und gepflegt.

## Verbindliche Eigentumsgrenze

`SQL_Server_Lab` bleibt Eigentümer von:

- Environment Blueprint und Desired State;
- Resource Assessment und Capability Resolution;
- Run-ID, Scope und Ressourcenbesitz;
- State, Runtime Bindings und Operation Journal;
- Action Preview und Benutzerbestätigung;
- Artifact Trust und Medienfreigabe;
- Cleanup, Recovery und Evidence;
- CLI-, Console- und Browser-Workflow.

Ein externes Projekt darf ausschließlich hinter einem Adapter begrenzte,
explizit angeforderte Operationen ausführen. Sein eigener State darf eine
technische Ausführungshilfe sein, aber niemals die einzige Wahrheit über eine
`SQL_Server_Lab`-Umgebung.

## Statusmodell

```text
candidate
   |
   v
spike
   |
   +--> rejected
   |
   +--> accepted-monorepo
   |
   +--> extraction-candidate
```

| Status | Bedeutung |
|---|---|
| `candidate` | möglicher Nutzen ist beschrieben, aber nicht praktisch belegt |
| `spike` | zeitlich und funktional begrenzter Vergleich wird durchgeführt |
| `rejected` | Nutzen, Sicherheit oder Wartbarkeit rechtfertigen die Integration nicht |
| `accepted-monorepo` | Adapter bleibt Bestandteil von `SQL_Server_Lab` |
| `extraction-candidate` | getrenntes Projekt wird anhand zusätzlicher Kriterien geprüft |

`extraction-candidate` bedeutet nicht automatisch Auskopplung. Ein eigenes
Projekt wird erst erwogen, wenn ein stabiler Vertrag, ein abweichender
Release-Zyklus, weitere Nutzer oder ein nachweisbarer Wartungsvorteil bestehen.

## Regeln für Inkubator-Arbeit

- keine parallele Produkt-Roadmap;
- keine eigene Version oder Release-Pipeline;
- keine eigene Lizenzentscheidung während des Spikes;
- keine Fremdquellen oder Binärdateien im Repository;
- keine automatische Installation externer Abhängigkeiten;
- keine Zugriffe auf beliebige private Core-Funktionen;
- keine Mutation ohne `SQL_Server_Lab`-Scope und Cleanup-Plan;
- jeder Spike besitzt Annahme- und Ablehnungskriterien;
- ein nicht überzeugender Spike wird beendet statt dauerhaft parallel gepflegt;
- eine spätere Extraktion muss technisch möglich sein, wird aber nicht vorweggenommen.

## Aktive Kandidaten

| Kandidat | Status | Zweck |
|---|---|---|
| [AutomatedLabProvider](AutomatedLabProvider/README.md) | `candidate` | möglicher optionaler Hyper-V-/Windows-Ausführungsadapter |

Die breitere Projektanalyse bleibt in
`Documentation/Research/EXISTING_LAB_AND_ORCHESTRATION_PROJECTS_REVIEW.md`
dokumentiert. Ein Kandidat wird erst in diesen Inkubator aufgenommen, wenn ein
konkreter, messbarer Spike sinnvoll ist.
