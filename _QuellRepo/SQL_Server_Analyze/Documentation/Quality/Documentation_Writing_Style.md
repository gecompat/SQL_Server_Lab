# Verbindlicher Schreibstil für Dokumentation

**Status:** verbindlich  
**Geltungsbereich:** alle neuen oder überarbeiteten Freitexte der Repository-Dokumentation

## Ziel

Die Dokumentation wird in einem fachlichen, sachlichen und professionellen Stil verfasst. Sie vermittelt technische Inhalte so knapp wie möglich und so ausführlich wie für ein eindeutiges fachliches Verständnis erforderlich.

Der Text muss Zweck, Funktionsweise, Voraussetzungen, wesentliche Abhängigkeiten und relevante Auswirkungen nachvollziehbar erklären. Zusätzliche Länge ist nur gerechtfertigt, wenn sie das technische Verständnis verbessert oder eine Fehlinterpretation verhindert.

## Formulierung

Freitexte verwenden vollständige, grammatikalisch korrekte Sätze und logisch zusammenhängende Absätze. Technische Begriffe, Objektbezeichnungen, Parameter, Statuswerte und Ausgabearten werden präzise, eindeutig und innerhalb des Repositorys konsistent verwendet.

Aussagen werden konkret formuliert. Unbestimmte Verweise wie „dies“, „normalerweise“ oder „problematisch“ erhalten den erforderlichen technischen Bezug, sofern dieser nicht aus dem unmittelbar vorhergehenden Satz eindeutig hervorgeht.

Technische Zusammenhänge beschreiben mindestens die für die jeweilige Aussage relevanten Bedingungen und Folgen. Bei Analyseverfahren gehören dazu insbesondere Datenquelle, Scope, Zeitbezug, Berechtigung, Eigenlast, Aussagegrenze und mögliche Gegenprüfung, soweit diese Aspekte fachlich zutreffen.

## Zu vermeidende Ausdrucksformen

Die Dokumentation enthält keine:

- werblichen, übertriebenen oder unbelegten Qualitätsversprechen;
- Metaphern, Floskeln oder rhetorischen Ausschmückungen;
- inhaltsarmen Einleitungen, Zusammenfassungen ohne zusätzlichen Erkenntniswert oder unnötigen Wiederholungen;
- subjektiven Wertungen ohne fachliche Begründung;
- Satzfragmente, Telegrammstil oder unverbundene Stichwortsammlungen;
- erfundenen Fakten, Kausalitäten, Abhängigkeiten, Quellen oder Ausführungsergebnissen.

Formulierungen wie „einfach“, „offensichtlich“, „optimal“, „immer“, „nie“ oder „vollständig“ werden nur verwendet, wenn die Aussage fachlich belegt und innerhalb des beschriebenen Scopes tatsächlich uneingeschränkt gültig ist.

## Listen und Tabellen

Listen und Tabellen sind zulässig, wenn sie Aufzählungen, Abläufe, Zuordnungen oder Vergleiche übersichtlicher darstellen als Fließtext. Überschriften und Spaltenbezeichnungen müssen die dargestellte Beziehung eindeutig benennen.

Listen und Tabellen ersetzen den erklärenden Fließtext nicht, wenn Zweck, Ursache, Abhängigkeit oder Interpretation sonst unklar bleiben. Einzelne Tabellenzellen und gleichartig aufgebaute Listeneinträge dürfen kompakt formuliert sein, sofern ihre Bedeutung durch Einleitung, Überschriften und Kontext eindeutig ist.

## Fachliche Nachvollziehbarkeit

Dokumentierte Tatsachen, Frameworkverträge, empirische Beobachtungen, Heuristiken, Annahmen und Empfehlungen werden sprachlich voneinander getrennt. Annahmen, Einschränkungen, Unsicherheiten und Empfehlungen sind ausdrücklich als solche zu kennzeichnen.

Eine Empfehlung nennt die fachliche Begründung und die wesentlichen Auswirkungen. Eine Unsicherheit wird nicht durch eine scheinbar genaue Aussage verdeckt. Fehlt eine belastbare Quelle oder ein Laufzeitnachweis, wird diese Grenze genannt; sie darf nicht durch eine Vermutung ersetzt werden.

Versions-, Berechtigungs-, Plattform-, Locking- und Kostenangaben werden mit dem aktuellen T-SQL, den Repositoryverträgen und geeigneten Primärquellen abgeglichen. Quellen werden nur angegeben, wenn sie die konkrete Aussage tatsächlich stützen.

## Erhaltung technischer Verträge

Eine rein redaktionelle Überarbeitung darf die fachliche Bedeutung nicht verändern. Dies gilt insbesondere für:

- Objekt- und Parameternamen;
- Datentypen, Defaults und Rückgabewerte;
- Status-, Fehler- und Reason-Codes;
- Resultsetnamen, Spalten und Ausgabereihenfolgen;
- Kostenklassen, Berechtigungen und High-Impact-Gates;
- Scope-, Reset-, Retention- und Partialitätsaussagen;
- dokumentierte Einschränkungen und Sicherheitsgrenzen.

Falls eine sprachliche Korrektur einen möglichen fachlichen Widerspruch sichtbar macht, wird der Widerspruch geprüft oder ausdrücklich als offene Unsicherheit festgehalten. Er wird nicht stillschweigend durch eine stilistische Umformulierung entschieden.

## Geschützter Lizenzblock der Root-README

Der am Anfang der Root-`README.md` vorhandene englische und deutsche Lizenzblock ist von stilistischen, redaktionellen und allgemeinen README-Änderungen ausgenommen. Diese Richtlinie erteilt insbesondere keine Berechtigung, Wortlaut, Formatierung, Reihenfolge, Links, Überschriften, Listen, Trennlinien oder Leerzeilen dieses Blocks anzupassen.

Maßgeblich ist der zu Beginn der jeweiligen Aufgabe im Zielbranch vorhandene Stand. Ein automatisiertes Bearbeitungssystem darf den Lizenzblock nur bearbeiten, wenn der Benutzer ausdrücklich und unmittelbar eine Änderung dieses Blocks verlangt. Bei allen anderen Änderungen der Root-`README.md` muss der Block inhaltlich und formal unverändert bleiben.

## Anwendungsumfang

Die Vorgabe gilt unter anderem für:

- Root- und bereichsspezifische README-Dateien;
- Inhalte unter `Documentation/`;
- maßgebliche Architektur-, Analyse-, Betriebs-, Referenz-, Release- und Qualitätsdokumente;
- dokumentierende Header, Kommentare und Hilfetexte in SQL- oder Skriptdateien;
- neu erzeugte Dokumentation und textliche Teile maschinenlesbarer Nachweise.

Unveränderbare technische Literale, Codebeispiele, synthetische Testwerte und maschinenlesbare Vertragswerte müssen nicht in natürliche Sätze umgeformt werden.

Die Richtlinie verpflichtet dazu, berührte Freitexte korrekt zu verfassen. Sie ist keine Erlaubnis für eine unaufgeforderte Gesamtüberarbeitung außerhalb des sachlichen Aufgabenbereichs.

## Prüfkriterien vor einer Änderung

Vor dem Commit ist für jeden berührten Dokumentationsfreitext zu prüfen:

1. Ist der Zweck ohne inhaltsarme Einleitung erkennbar?
2. Sind Funktionsweise und wesentliche Abhängigkeiten ausreichend erklärt?
3. Sind technische Begriffe und Vertragswerte korrekt und konsistent?
4. Sind Annahmen, Einschränkungen, Unsicherheiten und Empfehlungen ausdrücklich gekennzeichnet?
5. Enthalten Listen und Tabellen genügend Kontext für eine eindeutige Interpretation?
6. Wurden Wiederholungen, Floskeln, Übertreibungen, Satzfragmente und unbelegte Wertungen entfernt?
7. Bleibt der Text so knapp wie möglich, ohne erforderliche fachliche Erklärung auszulassen?
8. Wurden keine Fakten, Quellen, Zusammenhänge oder Nachweise erfunden?
