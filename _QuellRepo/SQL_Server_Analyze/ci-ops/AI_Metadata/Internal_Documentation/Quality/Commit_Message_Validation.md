# Kontextabhängiger Commit-Message-Vertrag

**Stand:** 21. Juli 2026
**Anforderung:** `AI_Metadata/Internal_Documentation/Requirements/Requirements_and_Decisions.md`, Abschnitt 8
**Prüfskript:** `Code/Tests/Static/930_Validate_Commit_Message.py`
**Workflow:** `.github/workflows/commit-message-validation.yml`
**Status:** IMPLEMENTED_AUTOMATED_GATE
**Erster grüner Lauf:** [Run 29634126487](https://github.com/gecompat/SQL_Server_Analyze/actions/runs/29634126487)

## Vertrag

Der Vertrag unterscheidet den tatsächlichen Lieferweg:

| Modus | Verwendung | Vertrag |
|---|---|---|
| `MANUAL_ZIP` | Das Repository wird aus einem downloadbaren ZIP manuell gepflegt. | Die bereitgestellte Commit Message ist nicht leer, UTF-8-lesbar und exakt einzeilig. |
| `DIRECT_GIT` | Die KI committet und pusht direkt. | Die Commit Message ist nicht leer und UTF-8-lesbar. Ein mehrzeiliger Body ist zulässig. |

Der technisch übliche abschließende LF- beziehungsweise CRLF-Terminator zählt im Modus `MANUAL_ZIP` nicht als zweite Zeile. Ein Message Body, eine zusätzliche Leerzeile oder ein eingebettetes Carriage Return blockiert nur diesen manuellen Modus. Eine automatisch erzeugte mehrzeilige Squash-Message ist im Modus `DIRECT_GIT` zulässig und darf keinen leeren Korrekturcommit oder ein History-Rewrite auslösen.

Historische Commits werden weder umgeschrieben noch bei jedem Lauf vollständig neu bewertet. Das GitHub-Actions-Gate verwendet ausdrücklich `DIRECT_GIT`. Ein Pull-Request-Lauf prüft alle durch `base..head` neu eingebrachten Commits; ein Push auf `main` prüft den Bereich `before..head`. Ein manueller Lauf ohne Basissha prüft nur `HEAD`.

## Lokale Prüfung

Generische Selbsttests:

```text
python3 Code/Tests/Static/930_Validate_Commit_Message.py --repository-root . --self-test
```

Direkt durch die KI eingebrachten Commit prüfen:

```text
python3 Code/Tests/Static/930_Validate_Commit_Message.py --repository-root . --delivery-mode DIRECT_GIT --base-sha <BASIS-SHA> --head-sha <HEAD-SHA>
```

Für eine manuelle ZIP-Übernahme den Einzeilenvertrag prüfen:

```text
python3 Code/Tests/Static/930_Validate_Commit_Message.py --repository-root . --delivery-mode MANUAL_ZIP --base-sha <BASIS-SHA> --head-sha <HEAD-SHA>
```

Die zwölf eingebauten Fälle decken beide Modi ab: gültige LF-, CRLF- und terminatorlose Einzeiler, zulässige Direct-Git-Bodies sowie leere, mehrzeilige manuelle, nachgestellte Leerzeilen, eingebettete Carriage Returns und nicht als UTF-8 lesbare Messages.

## Datenschutzkonforme Ausgabe

Bei einem Fehler werden ausschließlich Scope, stabiler Regelcode, Commit-SHA und Anzahl ausgegeben. Die Commit Message selbst wird niemals wiedergegeben oder als separates Prüfartefakt hochgeladen.
