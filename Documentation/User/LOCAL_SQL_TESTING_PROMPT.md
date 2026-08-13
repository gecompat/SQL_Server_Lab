# Prompt: lokale SQL-Server-Tests mit SQL_Server_Lab

Dieser Prompt ist für KI-Agenten und automatisierte Werkzeuge in konsumierenden
Projekten bestimmt. Er enthält bewusst keine installationsabhängigen absoluten
Pfade und keine Zugangsdaten. Beim Export automatisierter Testumgebungen wird
eine identische lokale Kopie als `TestUmgebung.prompt.md` bereitgestellt.

## Vollständiger Prompt

```text
Verwende für alle geeigneten SQL-Server-Integrations-, Kompatibilitäts- und
Regressionstests dieses Projekts vorrangig die bereits vorhandenen lokalen
Testumgebungen von SQL_Server_Lab.

DISCOVERY

1. Ermittle den kanonischen Vertrag zuerst aus der Prozessvariable
   SQL_SERVER_LAB_TEST_ENV_FILE.
2. Ist sie nicht gesetzt, lies die gleichnamige Benutzervariable des
   Betriebssystems.
3. Ist auch diese nicht gesetzt, ermittle SQL_SERVER_LAB_DATA_ROOT zuerst aus
   der Prozess- und danach aus der Benutzervariable und bilde daraus:

   <DataRoot>/Exports/TestUmgebung.json

4. Das Schema liegt standardmäßig daneben als TestUmgebung.schema.json. Eine
   explizite Variable SQL_SERVER_LAB_TEST_ENV_SCHEMA_FILE hat Vorrang.
5. Keine Laufwerks-, Home- oder Repositorysuche durchführen. Keine festen
   Pfade wie D:\Lab_Data voraussetzen.
6. Fehlt der Vertrag, beende den SQL-Integrationstest mit einer verständlichen
   Meldung. Erzeuge, starte oder lösche keine Lab-Ressourcen selbst.

VERTRAG UND AUSWAHL

7. Validiere TestUmgebung.json vor der Verwendung gegen das JSON Schema.
8. Verwende die Gruppe nur, wenn groupStatus exakt READY ist.
9. Verwende ausschließlich Einträge mit status exakt READY.
10. Wähle Ziele explizit nach platform, sqlVersion und patch. Verwende bei
    mehreren vom Projekt unterstützten SQL-Versionen alle passenden Ziele als
    Testmatrix. Kein stillschweigender Wechsel auf eine andere Version,
    Plattform oder Patchstufe.
11. Übernimm die Verbindung ausschließlich aus connectionString oder aus host,
    port, database, username, password, encrypt und trustServerCertificate des
    ausgewählten Eintrags. Werte nicht raten und keine Defaultkennwörter nutzen.
12. Verwende Encrypt=True und TrustServerCertificate=True entsprechend dem
    Vertrag. Verwende nicht Encrypt=Strict.

ERREICHBARKEIT UND AUSFÜHRUNG

13. Führe vor dem eigentlichen Test eine echte SQL-Anmeldung aus und prüfe:

    SELECT @@VERSION;
    SELECT name, state_desc FROM sys.databases ORDER BY database_id;

14. Ping allein ist kein SQL-Erreichbarkeitstest. Maßgeblich sind TCP-Verbindung
    und erfolgreiche SQL-Anmeldung.
15. Linux-Ziele können über Loopback und unterschiedliche Ports veröffentlicht
    sein. Windows-Ziele können in einem internen Hyper-V-Netz liegen und sind
    normalerweise nur vom lokalen Hyper-V-Host erreichbar.
16. Schlägt der Zugriff aus einer eingeschränkten Agenten-Sandbox fehl, wiederhole
    die Datei-, TCP- oder SQL-Operation mit der dafür vorgesehenen lokalen
    Sandbox-Freigabe. Weiche nicht automatisch auf einen entfernten Runner aus.
17. Unterscheide Treiber-, TLS-, Sandbox- und Netzwerkprobleme eindeutig von
    fachlichen Testfehlern.

SICHERHEIT UND ISOLIERUNG

18. Gib niemals password oder vollständige Connection Strings in Chat,
    Terminalprotokollen, Testreports oder Exceptions aus. Kopiere
    TestUmgebung.json und TestUmgebung.env niemals in das Projekt oder nach Git.
19. Halte Zugangsdaten nur im Speicher oder in kurzlebigen Prozessvariablen und
    entferne temporäre Variablen anschließend.
20. Lege verändernde Testobjekte nicht dauerhaft in master an. Verwende eine
    eindeutig benannte projektspezifische Testdatenbank, möglichst mit
    Projektkennung und eindeutiger Testlauf-ID.
21. Verändere oder lösche nur Datenbanken und Objekte, die der aktuelle Testlauf
    nachweislich selbst erzeugt hat. Fremde Datenbanken und Lab-Ressourcen dürfen
    weder verändert noch gestoppt oder gelöscht werden.

ERGEBNIS

22. Dokumentiere pro Ziel nur Testumgebungsschlüssel, Plattform, angeforderte
    Version/Patchstufe, tatsächlich erkannte SQL-Version, Status, Dauer und eine
    secretfreie Fehlerursache.
23. Melde explizit, wenn kein passendes READY-Ziel vorhanden ist. Behaupte in
    diesem Fall nicht, die fachlichen SQL-Tests seien erfolgreich gewesen.

Beginne jetzt mit Discovery, Schema-Validierung und SQL-Preflight. Führe danach
die Tests des aktuellen Projekts gegen alle passend ausgewählten Ziele aus.
```

## Kurzer Eintrag für `AGENTS.md`

```markdown
## Lokale SQL-Server-Tests

SQL-Server-Integrations- und Kompatibilitätstests sollen vorrangig die lokalen
SQL_Server_Lab-Testumgebungen verwenden. Der Vertrag wird portabel über
`SQL_SERVER_LAB_TEST_ENV_FILE` ermittelt; Fallback ist
`SQL_SERVER_LAB_DATA_ROOT/Exports/TestUmgebung.json`. Vor Verwendung muss er
gegen das danebenliegende Schema validiert werden und `groupStatus = READY`
besitzen. Zugangsdaten oder vollständige Connection Strings dürfen nicht
protokolliert, kopiert oder committed werden. Falls vorhanden, ist zusätzlich
der Prompt aus `SQL_SERVER_LAB_TEST_ENV_PROMPT_FILE` zu befolgen.
```
