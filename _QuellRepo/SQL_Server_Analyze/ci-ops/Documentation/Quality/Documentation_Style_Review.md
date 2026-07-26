# Bestandsprüfung des Dokumentationsstils

**Status:** abgeschlossen

**Stand:** 22. Juli 2026
**Maßgebliche Richtlinie:** [Verbindlicher Schreibstil für Dokumentation](Documentation_Writing_Style.md)

## Geprüfter Umfang

Die Bestandsprüfung umfasst alle redaktionellen Markdown-Dateien des Repositorys sowie dokumentierende Dateiköpfe und Hilfeausgaben in den SQL-Dateien.

Ausdrücklich als persönliche oder externe Notizen gekennzeichnete Dateien bleiben entsprechend ihren ordnerspezifischen Anweisungen unberührt. Die Lizenz, ausführbarer T-SQL-Code, technische Literale, maschinenlesbare Vertragswerte und synthetische Testdaten sind keine redaktionellen Freitexte und wurden nicht allein aus Stilgründen verändert.

Eine Bestandsprüfung bedeutet nicht, dass jede geprüfte Datei geändert werden muss. Bereits richtlinienkonforme Texte bleiben unverändert, damit keine fachlich bedeutungslosen Diffs entstehen.

## Durchgeführte Überarbeitung

Die Überarbeitung beseitigt insbesondere wiederholte Standardabsätze, die den verfahrensspezifischen Inhalt überlagerten. Leseanleitungen, Beispiele, Folgeanalysen und Einschränkungen sind als vollständige Sätze formuliert. Die Runbooks, Bereichsleitfäden und der Einsteigerleitfaden verwenden nun konsistente Bezeichnungen für Auswertung, Interpretation und nächste Schritte.

Die internen Authoring-Archive behalten ihre historischen Aussagen und Statuswerte. Ihre wiederkehrenden Felder zu Datenquellen, Zeit- und Scopemodell, Bewertung und weiterführender Analyse besitzen jedoch einen vollständigen sprachlichen Rahmen. Dateiköpfe und zentrale `@Hilfe=1`-Ausgaben der SQL-Module beschreiben ihren Zweck ebenfalls in vollständigen Sätzen.

Die redaktionelle Überarbeitung ändert keine Objekt- oder Parameternamen, Datentypen, Defaults, Statuscodes, Resultsets, Kostenklassen, Berechtigungen, Analyse-Gates oder fachlichen Ausführungspfade. Wenn ein bestehender Text eine Aussagegrenze enthielt, bleibt diese Grenze erhalten.

## Automatische Rückfallprüfung

`Code/Tests/Static/915_Validate_Documentation_Style.py` durchsucht alle nicht ausdrücklich ausgeschlossenen Markdown- und SQL-Dateien und blockiert konkret bekannte Rückfälle. Dazu gehören die entfernten generischen Procedure-Absätze, frühere fragmentarische Leserichtungsbezeichnungen, nominale Zweckangaben in SQL-Dateiköpfen und ausgewählte fragmentarische Hilfeformulierungen. Die Prüfung läuft mit Selbsttest im Workflow `documentation-validation.yml`.

Die automatische Prüfung bewertet keine fachliche Richtigkeit und ersetzt kein sprachliches Review. Neue Texte müssen weiterhin vollständig gegen die Schreibstilrichtlinie und die jeweiligen technischen Quellen geprüft werden.
