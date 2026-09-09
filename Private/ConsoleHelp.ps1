<#
.SYNOPSIS
    Kontexthilfe fuer die Konsolenoberflaeche (CUI-024).
.DESCRIPTION
    Hilfe ist ein Datenkatalog je ScreenId und nicht verstreuter Text im
    Ablaufcode. Voraussetzungen werden bei jedem Aufruf ausgewertet, damit die
    Hilfe gleichzeitig als Diagnose dient.
#>

function Get-LabConsoleHelpCatalog {
    <#
    .SYNOPSIS Liefert den Hilfekatalog der Konsolenbildschirme.
    #>
    [CmdletBinding()]
    param()

    if ($script:LabConsoleHelpCatalog) { return $script:LabConsoleHelpCatalog }

    $dataRootPrecondition = @{
        Label = 'Lab_Data ist konfiguriert'
        Test  = { [bool](Get-LabDataRootDefault) }
        Fix   = 'Im Menue "Medien, Testdaten und Speicher" den Lab_Base/Media-Root setzen.'
    }
    $stateRootPrecondition = @{
        Label = 'State-Root ist beschreibbar'
        Test  = { $root = Get-LabStateRoot; [bool]$root -and [IO.Path]::IsPathRooted($root) }
        Fix   = 'SQL_SERVER_LAB_STATE auf einen absoluten Pfad setzen.'
    }

    $catalog = @{
        'main-menu' = @{
            Title   = 'Hauptmenue'
            Purpose = 'Einstieg in alle Bereiche des Labs. Die Auswahl oeffnet nur einen Unterbereich und veraendert nichts.'
            Effects = 'Keine Mutation. Jede veraendernde Aktion wird erst im jeweiligen Unterbereich ausdruecklich bestaetigt.'
            Related = @('F5 laedt den Attention-Status neu.', 'Esc beendet die Oberflaeche.')
            Command = 'Invoke-SqlServerLab'
            Preconditions = @($dataRootPrecondition, $stateRootPrecondition)
            Items   = @{
                'create'         = @{ Purpose = 'Neue SQL- oder Windows-Umgebungen zusammenstellen, pruefen und uebergeben.'; Command = 'New-SqlServerLabBatch' }
                'environment'    = @{ Purpose = 'Vorhandene Umgebungen starten, stoppen, aendern und entfernen.'; Command = 'Get-SqlServerLab' }
                'queue'          = @{ Purpose = 'Laufende, wartende und fehlgeschlagene Vorgaenge einsehen und steuern.'; Command = 'Get-SqlServerLabQueue' }
                'database'       = @{ Purpose = 'Datenbanken, Pakete, Skripte und Endpunkte erreichen.'; Command = 'Get-SqlServerLabConnectionCenter' }
                'cms'            = @{ Purpose = 'Registrierte Server der zentralen Verwaltung und den SSMS-Export erreichen.'; Command = 'Sync-SqlServerLabCms' }
                'infrastructure' = @{ Purpose = 'Hyper-V-Bestand sowie Lab_Base, Lab_Data, CU-Pakete und Testdaten verwalten.'; Command = 'Get-SqlServerLabResourcePlan' }
                'maintenance'    = @{ Purpose = 'Providerstatus, Cleanup-Audit und Katalog read-only pruefen.'; Command = 'Test-SqlServerLabPrerequisite' }
                'settings'       = @{ Purpose = 'Scheduler, Parallelitaet, Ton, Ruhemodus und Ersteinrichtung.'; Command = 'Invoke-SqlServerLabScheduler' }
            }
        }
        'create-menu' = @{
            Title   = 'Umgebung erstellen'
            Purpose = 'Erstellt eine einzelne Umgebung sofort oder stellt mehrere zusammen und uebergibt sie an die Queue.'
            Effects = 'Der Sofortweg legt nach einer ausdruecklichen Rueckfrage unmittelbar Runtime-Ressourcen an. Beim Zusammenstellen entsteht bis zur Uebergabe keine Ressource.'
            Related = @(
                'Sofort erstellen entscheidet den Provider automatisch und zeigt die Begruendung vor der Rueckfrage.',
                'Container-Positionen im Batch benoetigen eine Referenz auf eine SQL_SERVER_LAB_SECRET_*-Prozessvariable.',
                'Ein nur gespeicherter Batch bleibt Draft und wird vom Scheduler nicht gestartet.'
            )
            Command = 'New-SqlServerLab'
            Preconditions = @($dataRootPrecondition, $stateRootPrecondition)
        }
        'create-sa-password' = @{
            Title   = 'SA-Kennwort der neuen Umgebung'
            Purpose = 'Legt fest, ob das SA-Kennwort erzeugt oder selbst vergeben wird.'
            Effects = 'Ein erzeugtes Kennwort wird verschluesselt run-lokal hinterlegt. Ein selbst vergebenes Kennwort bleibt ein SecureString und wird nicht gespeichert.'
            Related = @(
                'Ein selbst vergebenes Kennwort wird nicht als lab-generiert ausgewiesen und ist spaeter nicht abrufbar.',
                'Die Eingabe erfolgt zweifach; bei Abweichung bricht der Schritt ohne Mutation ab.'
            )
            Command = 'New-SqlServerLab -SaPassword'
        }
        'cms-menu' = @{
            Title   = 'Zentrale Verwaltung (CMS)'
            Purpose = 'Zugang zu registrierten Servern, Endpunkten und dem SSMS-Export.'
            Effects = 'Anzeigen veraendert nichts. Der Export erzeugt eine Registrierungsdatei fuer SSMS.'
            Command = 'Get-SqlServerLabConnectionCenter'
        }
        'infrastructure-menu' = @{
            Title   = 'Infrastruktur und Medien'
            Purpose = 'Buendelt den Hyper-V-Bestand und die Medien-, Speicher- und Testdatenverwaltung.'
            Effects = 'Die Auswahl oeffnet nur einen Unterbereich. Downloads, Builds und Verschiebungen werden dort einzeln bestaetigt.'
            Related = @('Hyper-V-Aktionen fordern bei Bedarf automatisch eine UAC-Erhoehung an.')
            Command = 'Get-SqlServerLabResourcePlan'
            Preconditions = @($dataRootPrecondition)
        }
        'maintenance-menu' = @{
            Title   = 'Wartung und Diagnose'
            Purpose = 'Read-only Pruefungen zu Providerstatus, verbliebenen Ressourcen und Katalog.'
            Effects = 'Keine Mutation. Ergebnisse werden bis zur Rueckkehrbestaetigung angezeigt.'
            Command = 'Test-SqlServerLabPrerequisite / Get-SqlServerLabCleanupAudit'
        }
        'settings-menu' = @{
            Title   = 'Einstellungen'
            Purpose = 'Scheduler und Parallelitaet, Ton und Ruhemodus sowie die Ersteinrichtung von Lab_Base und Lab_Data.'
            Effects = 'Aenderungen gelten global, auch fuer kuenftige Vorgaenge.'
            Command = 'Invoke-SqlServerLabScheduler'
            Preconditions = @($dataRootPrecondition, $stateRootPrecondition)
        }
        'queue-menu' = @{
            Title   = 'Vorgaenge und Queue'
            Purpose = 'Zeigt alle Vorgaenge mit Status, Prioritaet und Blockierungsgrund und erlaubt deren Steuerung.'
            Effects = 'Anzeigen veraendert nichts. Umreihen, Pausieren, Stoppen und Aufraeumen wirken sofort auf den betroffenen Vorgang.'
            Related = @(
                'Ein Batch im Status Draft wird vom Scheduler nicht gestartet.',
                'Container-Vorgaenge benoetigen eine SQL_SERVER_LAB_SECRET_*-Prozessvariable.'
            )
            Command = 'Get-SqlServerLabQueue'
            Preconditions = @($stateRootPrecondition)
            Items   = @{
                'run'      = @{ Purpose = 'Fuehrt den Scheduler einmal aus und startet startbereite Vorgaenge.'; Effects = 'Startet Provider-Arbeit. Vorgaenge in Draft-Batches bleiben unberuehrt.'; Command = 'Invoke-SqlServerLabScheduler' }
                'overview' = @{ Purpose = 'Read-only Uebersicht ueber Queue, Worker und Blockierungen.'; Command = 'Get-SqlServerLabQueue' }
                'priority' = @{ Purpose = 'Aendert die Prioritaet eines wartenden Vorgangs.'; Command = 'Set-SqlServerLabOperationPriority' }
                'move'     = @{ Purpose = 'Verschiebt einen wartenden Vorgang in der Reihenfolge.'; Command = 'Move-SqlServerLabOperation' }
                'stop'     = @{ Purpose = 'Stoppt einen Vorgang und raeumt die bereits erzeugten Ressourcen auf.'; Effects = 'Irreversibel fuer die betroffene Umgebung.'; Command = 'Stop-SqlServerLabOperation' }
            }
        }
        'environment-menu' = @{
            Title   = 'Umgebungen verwalten'
            Purpose = 'Auswahl einer vorhandenen Umgebung fuer Statusanzeige, Lebenszyklus und Aenderungen.'
            Effects = 'Die Auswahl allein veraendert nichts.'
            Command = 'Get-SqlServerLab'
            Preconditions = @($stateRootPrecondition)
        }
        'environment-actions' = @{
            Title   = 'Aktionen fuer die gewaehlte Umgebung'
            Purpose = 'Starten, Stoppen, Neustarten, Aendern, Entfernen und Statusabruf einer konkreten Umgebung.'
            Effects = 'Starten und Stoppen wirken sofort. Entfernen loescht Container beziehungsweise VM und den zugehoerigen Run-State.'
            Related = @('Persistente Daten werden nur nach ausdruecklicher Bestaetigung entfernt.')
            Command = 'Start-SqlServerLab / Stop-SqlServerLab / Remove-SqlServerLab'
        }
        'sql-target-configuration' = @{
            Title   = 'SQL-Zielkonfiguration'
            Purpose = 'Legt Version, Ressourcen, Port, Collation und Speicher der neuen Umgebung fest.'
            Effects = 'Reine Eingabe. Es wird nichts erzeugt, bevor der Plan bestaetigt wurde.'
            Related = @('Port 0 waehlt automatisch einen freien Loopback-Port.')
            Command = 'New-SqlServerLab'
            Preconditions = @($dataRootPrecondition)
        }
        'batch-composer' = @{
            Title   = 'Batch zusammenstellen'
            Purpose = 'Stellt mehrere Umgebungen als gemeinsamen Batch zusammen und uebergibt ihn an die Queue.'
            Effects = 'Bis zur Uebergabe entsteht keine Runtime-Ressource.'
            Related = @(
                'Ein nur gespeicherter Batch bleibt Draft und wird nicht ausgefuehrt.',
                'Fuer eine einzelne Umgebung ist der direkte Weg ueber das Erstellen-Menue schneller.'
            )
            Command = 'New-SqlServerLabBatch'
            Preconditions = @($stateRootPrecondition)
        }
        'batch-sa-secret' = @{
            Title   = 'SA-Kennwort der Containerposition'
            Purpose = 'Bindet die Position an eine SQL_SERVER_LAB_SECRET_*-Prozessvariable. Der Batch speichert nur den Namen, niemals das Kennwort.'
            Effects = 'Beim Anlegen wird die Prozessvariable fuer diese Sitzung gesetzt. Sie wird nicht dauerhaft gespeichert und nicht in den State geschrieben.'
            Related = @(
                'Ohne Referenz lehnt der Preflight die Uebergabe des Batches ab.',
                'Die Variable gilt nur im aktuellen Prozess; ein neues Fenster benoetigt sie erneut.'
            )
            Command = '$env:SQL_SERVER_LAB_SECRET_<NAME> = <Kennwort>'
        }
        'storage-menu' = @{
            Title   = 'Medien, Testdaten und Speicher'
            Purpose = 'Verwaltet Lab_Base, Medienquellen, CU-Pakete, Beispieldatenbanken und Speicherorte.'
            Effects = 'Downloads und Verschiebungen werden einzeln bestaetigt.'
            Command = 'Get-SqlServerLabResourcePlan'
            Preconditions = @($dataRootPrecondition)
        }
        'database-menu' = @{
            Title   = 'Datenbanken und Verbindungen'
            Purpose = 'Zugriff auf Verbindungszentrale, CMS, Datenbankpakete, Backup und Restore.'
            Effects = 'Anzeigen veraendert nichts. Restore und Attach wirken auf die Zielinstanz.'
            Command = 'Get-SqlServerLabConnectionCenter'
            Items   = @{
                'DatabaseBackup' = @{ Purpose = 'Sichert eine gebundene Datenbank als wiederverwendbares BackupSet in der registrierten Lab_Data-Bibliothek.'; Effects = 'Mutiert SQL durch COPY_ONLY BACKUP und veröffentlicht erst nach CHECKSUM, VERIFYONLY und SHA-256; temporäre Dateien werden bereinigt, TDE bleibt ohne Recovery-Vertrag gesperrt.'; Command = 'Backup-SqlServerLabDatabase' }
                'DatabaseRestore' = @{ Purpose = 'Stellt ein vollständig revalidiertes BackupSet aus der registrierten Lab_Data-Bibliothek auf einer gebundenen Zielinstanz wieder her.'; Effects = 'Mutiert SQL erst nach Konfliktprüfung und Bestätigung; WITH REPLACE wird bei vorhandenem Ziel separat bestätigt, der Cleanup versucht temporäre Kopien zu entfernen und SQL-Teilfehler verlangen eine gezielte Recovery-Prüfung.'; Command = 'Restore-SqlServerLabDatabase' }
                'DatabasePackageExport' = @{ Purpose = 'Veröffentlicht eine exakt an Run und Instanz gebundene Docker-/Podman-Datenbank als unveränderliches Paket in Lab_Data.'; Effects = 'Schaltet die Quelle exklusiv offline; sie bleibt auch nach Erfolg offline. FILESTREAM und TDE ohne Recovery-Nachweis werden vorher abgelehnt, temporäre Kopien werden bereinigt.'; Command = 'Export-SqlServerLabDatabasePackage' }
                'DatabasePackageAttach' = @{ Purpose = 'Kopiert ein vollständig verifiziertes Datenbankpaket in das live ermittelte SQL-Default-Data-Verzeichnis eines gebundenen Hyper-V-Gasts und attached es dort.'; Effects = 'Mutiert Zielablage und SQL erst nach Vorprüfung und Bestätigung. Ein getrennter, journalgebundener Recovery-Modus detacht nur nach erneuter Zielbindung und bereinigt die Gastkopie.'; Command = 'Invoke-SqlServerLabDatabasePackageAttach' }
                'DatabasePackageInventory' = @{ Purpose = 'Listet katalogisierte Datenbankpakete mit stabiler ID, Verfuegbarkeit und Migrationsgrenzen pfadfrei auf.'; Effects = 'Read-only; grosse Paketobjekte werden ohne ausdrueckliche Integritaetspruefung nicht erneut gehasht.'; Command = 'Get-SqlServerLabDatabasePackage' }
                'DatabaseMigrationDependency' = @{ Purpose = 'Inventarisiert SQL-seitig beobachtbare Migrationsabhaengigkeiten als sanitisierte Kategorien und Counts.'; Effects = 'Read-only; exportiert weder Datenbank noch Serverobjekte, Secrets oder TDE-Schluessel.'; Command = 'Get-SqlServerLabDatabaseMigrationDependency' }
            }
        }
        'ai-guided-demo-menu' = @{
            Title   = 'Gefuehrte SQL Server 2025 KI-Demos'
            Purpose = 'Fuehrt vier kuratierte Lernpfade ueber dieselben versionierten Szenarien, Datensaetze und Sicherheitsvertraege wie Entwicklung und CI.'
            Effects = 'Retrieval-Metriken laufen offline. Vector, Golden-RAG und Diagnose fragen Ziel und Kennwort ab und fuehren den jeweiligen bestehenden Produktpfad aus.'
            Related = @(
                'Vector-Core verwendet vector-core-ci/1.0 und dessen Assertions samt Cleanup.',
                'Golden-RAG und Diagnose verwenden die kleinsten katalogisierten lokalen Modelle; Cloud-Egress ist nicht Bestandteil der Demos.'
            )
            Command = 'Invoke-SqlServerLab'
            Preconditions = @($stateRootPrecondition)
            Items   = @{
                'vector'    = @{ Purpose = 'Fuehrt den deterministischen SQL-2025-Vector-Core mit festen Assertions aus.'; Command = 'Invoke-SqlServerLabAiScenario' }
                'retrieval' = @{ Purpose = 'Erklaert Recall, MRR und nDCG am versionierten Golden Dataset ohne Modell- oder Netzaufruf.'; Command = 'Measure-SqlServerLabAiRetrieval' }
                'rag'       = @{ Purpose = 'Fuehrt den hashgebundenen Golden-RAG-Fall mit echter SQL-Vektorsuche aus.'; Command = 'Invoke-SqlServerLabAiRag / Measure-SqlServerLabAiRetrieval' }
                'agent'     = @{ Purpose = 'Fuehrt eine feste read-only Diagnose ueber zwei katalogisierte SELECT-Werkzeuge aus.'; Command = 'Invoke-SqlServerLabAiDiagnosticAgent' }
            }
        }
        'connection-center' = @{
            Title   = 'Verbindungszentrale'
            Purpose = 'Zeigt alle erreichbaren Endpunkte mit Servernamen, Port und hinterlegtem Zugang.'
            Effects = 'Read-only. Der Export erzeugt eine Registrierungsdatei fuer SSMS.'
            Command = 'Get-SqlServerLabConnectionCenter'
        }
        'hyperv-menu' = @{
            Title   = 'Hyper-V-Infrastruktur'
            Purpose = 'Verwaltet Windows-Baselines, vorbereitete Images, Slots und SQL-Builds.'
            Effects = 'Builds und Klone belegen erheblichen Speicher und erfordern erhoehte Rechte.'
            Related = @('Hyper-V-Aktionen fordern bei Bedarf automatisch eine UAC-Erhoehung an.')
            Command = 'Get-SqlServerLabHyperVImageArtifact'
        }
        'system-menu' = @{
            Title   = 'System, Wartung und Diagnose'
            Purpose = 'Prueft Voraussetzungen, fuehrt Wartung aus und sammelt Diagnoseinformationen.'
            Effects = 'Die Pruefung ist read-only. Wartungsaktionen werden einzeln bestaetigt.'
            Command = 'Test-SqlServerLabPrerequisite / Get-SqlServerLabMaintenancePlan'
        }
    }

    $selectionHelp = @{
        Title   = 'Auswahl'
        Purpose = 'Wählt ein vorhandenes, bereits inventarisiertes Objekt für den nächsten beschriebenen Schritt aus.'
        Effects = 'Die Auswahl selbst mutiert nichts. Erst die nachfolgende Aktion zeigt ihre Wirkung und fordert bei Änderungen eine Bestätigung an.'
        Related = @('Esc kehrt ohne Auswahl zurück.', 'Deaktivierte Einträge nennen die noch fehlende Voraussetzung.')
        Command = 'Get-SqlServerLab'
        Preconditions = @($stateRootPrecondition)
    }
    foreach ($screenId in @(
        'active-run-selection', 'cms-adopt-select', 'container-update-environment',
        'database-package-attach-select', 'database-restore-backup-select',
        'environment-status-select', 'external-runtime-instance-selection',
        'hyperv-environment-selection', 'hyperv-existing-vm-source-select',
        'hyperv-image-remove-select', 'hyperv-image-rename-select', 'hyperv-images',
        'hyperv-os-artifact-select', 'hyperv-prepared-artifact-select',
        'hyperv-published-images', 'hyperv-reusable-windows-slot',
        'hyperv-sql-build-cleanup-select', 'hyperv-sql-build-select',
        'hyperv-sql-license-profile-select', 'hyperv-sql-media-select',
        'hyperv-sql-media-version-select', 'hyperv-sql-prepared-artifact-select',
        'hyperv-sql-windows-media-select', 'hyperv-switch-select',
        'hyperv-windows-baselines', 'hyperv-windows-build-cleanup-select',
        'hyperv-windows-build-select', 'hyperv-windows-media-select',
        'queue-select', 'sample-selection', 'storage-location-select',
        'storage-provider-select'
    )) { $catalog[$screenId] = $selectionHelp }

    $configurationHelp = @{
        Title   = 'Konfiguration'
        Purpose = 'Erfasst oder ändert einen begrenzten Teil des gewünschten Lab-Plans und zeigt die gültigen Optionen.'
        Effects = 'Die Eingabe allein erzeugt keine Runtime-Ressource. Sie wird erst nach Review, Preflight und ausdrücklicher Bestätigung wirksam.'
        Related = @('Esc verwirft die Eingabe dieses Schritts.', 'Secrets bleiben flüchtig und werden nicht im Menü-State gespeichert.')
        Command = 'New-SqlServerLabManifest / New-SqlServerLabBatch'
        Preconditions = @($dataRootPrecondition, $stateRootPrecondition)
    }
    foreach ($screenId in @(
        'automated-test-environment-compose', 'batch-bulk-edit',
        'batch-bulk-property', 'batch-count', 'batch-duplicate',
        'batch-provider-advanced', 'batch-remove', 'batch-reorder',
        'batch-reorder-direction', 'batch-windows-variant',
        'container-update-form', 'cu-resource-patch', 'cu-resource-platform',
        'cu-resource-provider', 'cu-resource-version', 'hyperv-advanced',
        'hyperv-guest-password-mode', 'hyperv-provisioning-target',
        'hyperv-sql-deployment-mode', 'hyperv-sql-sa-password-mode',
        'initial-setup-default-data-root', 'sql-intent-edition',
        'sql-intent-mode', 'sql-intent-network', 'sql-intent-purpose',
        'sql-intent-storage', 'sql-intent-version', 'sql-intent-version-edit',
        'sql-intent-windows', 'windows-slot-pool-password-mode'
    )) { $catalog[$screenId] = $configurationHelp }

    $hyperVWorkflowHelp = @{
        Title   = 'Hyper-V-Ablauf'
        Purpose = 'Führt durch einen zustandsgebundenen Hyper-V-Schritt für Windows-, Image- oder SQL-Bereitstellung.'
        Effects = 'Je nach Auswahl werden VM-, VHDX-, Medien- oder Gastressourcen verändert. Der Ablauf prüft Scope und Recovery-Grenzen vor der Mutation.'
        Related = @('Lange Builds können mehrere Neustarts enthalten.', 'Cleanup gilt nur für exakt gebundene Lab-Ressourcen.')
        Command = 'Get-SqlServerLabHyperVImageArtifact / New-SqlServerLab'
        Preconditions = @($dataRootPrecondition, $stateRootPrecondition)
    }
    foreach ($screenId in @(
        'hyperv-environment-actions', 'hyperv-managed-windows-completion',
        'hyperv-manual-windows-completion', 'hyperv-prepared-workflow',
        'hyperv-sql-acceptance'
    )) { $catalog[$screenId] = $hyperVWorkflowHelp }

    $queueActionHelp = @{
        Title   = 'Queue-Aktion'
        Purpose = 'Steuert einen bereits bekannten Queue-Vorgang innerhalb seiner aktuellen Zustandsgrenzen.'
        Effects = 'Priorität, Position, Bestätigung, Ruhemodus oder Stopp wirken unmittelbar auf Queue- beziehungsweise Vorgangsstate.'
        Related = @('Nicht verfügbare Aktionen sind mit dem konkreten Grund deaktiviert.', 'Stoppen mit Cleanup kann erzeugte Ressourcen entfernen.')
        Command = 'Get-SqlServerLabQueue'
        Preconditions = @($stateRootPrecondition)
    }
    foreach ($screenId in @(
        'batch-stop-mode', 'batch-stop-select', 'queue-confirm-bulk',
        'queue-move', 'queue-priority', 'queue-quiet', 'user-gate-actions'
    )) { $catalog[$screenId] = $queueActionHelp }

    $catalog['action-messages'] = @{
        Title = 'Fehler der letzten Aktion'; Purpose = 'Zeigt neue Fehler vollständig und kopierbar an; reine Warnungen erscheinen nur als Text im Scrollback.'
        Effects = 'Read-only; Journal und Runtime bleiben unverändert.'; Command = 'Get-LabMessage'
    }
    $catalog['messages'] = @{
        Title = 'Sitzungsmeldungen'; Purpose = 'Zeigt das sanitisierte Meldungsjournal dieser Sitzung.'
        Effects = 'Read-only; Kopieren verändert den Journalinhalt nicht.'; Command = 'Get-LabMessage'
    }
    $catalog['ai-menu'] = @{
        Title = 'SQL Server 2025 KI'; Purpose = 'Bündelt Szenarien, Modellaufrufe, RAG, Retrieval-Evaluierung und read-only Diagnose.'
        Effects = 'Offline-Auswertungen mutieren nichts; SQL- und Modellpfade verwenden die jeweils angezeigten Sicherheits- und Egress-Verträge.'
        Command = 'Get-SqlServerLabAiScenario / Invoke-SqlServerLabAiModel'; Preconditions = @($stateRootPrecondition)
    }
    $catalog['connection-center-cms'] = @{
        Title = 'CMS-Verwaltung'; Purpose = 'Erstellt, übernimmt oder synchronisiert den zentralen Verwaltungsserver.'
        Effects = 'Erstellen legt eine persistente SQL-Umgebung an; Übernehmen bindet eine vorhandene Umgebung; Export bleibt kennwortfrei.'
        Command = 'Sync-SqlServerLabCms'; Preconditions = @($stateRootPrecondition)
    }
    $catalog['cms-create-menu'] = $catalog['connection-center-cms']
    $catalog['database-package-attach-mode'] = @{
        Title = 'Datenbankpaket-Attach'; Purpose = 'Wählt zwischen neuer Attach-Ausführung und einer exakt journalgebundenen Recovery.'
        Effects = 'Attach kopiert Dateien und mutiert SQL; Recovery arbeitet ausschließlich das passende RECOVERY_REQUIRED-Journal ab.'
        Command = 'Invoke-SqlServerLabDatabasePackageAttach'; Preconditions = @($dataRootPrecondition, $stateRootPrecondition)
    }
    $catalog['hyperv-prepared-workflow'] = $hyperVWorkflowHelp
    $catalog['storage-management'] = @{
        Title = 'Storage verwalten'; Purpose = 'Registriert und verwaltet Lab_Data-Locations sowie sichere Migrations- und Dateiplatzierungspläne.'
        Effects = 'Anzeigen ist read-only. Registrierung, Deregistrierung und freigegebene Migration ändern den Storage-Katalog beziehungsweise gebundene Dateien.'
        Command = 'Get-SqlServerLabResourcePlan'; Preconditions = @($dataRootPrecondition)
    }
    $catalog['tools-menu'] = @{
        Title = 'Werkzeuge'; Purpose = 'Bündelt geprüfte Hilfswerkzeuge für Medien, Hostauflösung und Wartung.'
        Effects = 'Die Auswahl allein mutiert nichts; jedes Werkzeug beschreibt und bestätigt seine eigene Wirkung.'
        Command = 'Invoke-SqlServerLab'
    }

    $script:LabConsoleHelpPatternCatalog = [ordered]@{
        '*-review' = $configurationHelp
        'container-cu-*' = $configurationHelp
        'container-password-*' = $configurationHelp
        'container-profile-*' = $configurationHelp
        'container-version-*' = $configurationHelp
        'sql-patch-*' = $configurationHelp
        'test-environment-version-*' = $configurationHelp
    }
    $script:LabConsoleHelpCatalog = $catalog
    return $script:LabConsoleHelpCatalog
}

function Get-LabConsoleHelpTopic {
    <#
    .SYNOPSIS Loest die Hilfe fuer einen Bildschirm und optional den markierten Eintrag auf.
    .DESCRIPTION Ohne Katalogeintrag entsteht eine generische Auskunft. Ein
    deaktivierter Eintrag nennt immer einen Grund; fehlt er, wird das als Luecke
    ausgewiesen statt verschwiegen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScreenId,
        [AllowNull()][object]$Item,
        [AllowNull()][hashtable]$Catalog
    )

    $source = if ($null -ne $Catalog) { $Catalog } else { Get-LabConsoleHelpCatalog }
    $screen = $source[$ScreenId]
    if (-not $screen -and $null -eq $Catalog) {
        $null = Get-LabConsoleHelpCatalog
        foreach ($pattern in @($script:LabConsoleHelpPatternCatalog.Keys)) {
            if ($ScreenId -like $pattern) { $screen = $script:LabConsoleHelpPatternCatalog[$pattern]; break }
        }
    }
    $itemHelp = $null
    if ($Item -and $screen -and $screen.Items) { $itemHelp = $screen.Items[[string]$Item.Id] }
    if ($Item -and -not $itemHelp -and $Item.PSObject.Properties['Help'] -and $Item.Help) { $itemHelp = @{ Purpose = [string]$Item.Help } }

    $preconditions = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in @($screen.Preconditions)) {
        if (-not $candidate) { continue }
        $ok = $false
        $detail = ''
        try { $ok = [bool](& $candidate.Test) } catch { $detail = $_.Exception.Message }
        $preconditions.Add([PSCustomObject]@{
            Label = [string]$candidate.Label
            Ok    = $ok
            Fix   = [string]$candidate.Fix
            Detail = $detail
        })
    }

    $disabledReason = ''
    if ($Item -and [bool]$Item.Disabled) {
        $disabledReason = if ($Item.PSObject.Properties['DisabledReason'] -and [string]$Item.DisabledReason) {
            [string]$Item.DisabledReason
        }
        else {
            'Grund ist an diesem Eintrag noch nicht hinterlegt.'
        }
    }

    [PSCustomObject]@{
        ScreenId       = $ScreenId
        Title          = if ($screen -and $screen.Title) { [string]$screen.Title } else { $ScreenId }
        Curated        = [bool]$screen
        ItemId         = if ($Item) { [string]$Item.Id } else { '' }
        ItemLabel      = if ($Item) { [string]$Item.Label } else { '' }
        Purpose        = [string]$(if ($itemHelp -and $itemHelp.Purpose) { $itemHelp.Purpose } elseif ($screen) { $screen.Purpose } else { 'Fuer diesen Bildschirm ist noch keine Hilfe hinterlegt.' })
        Effects        = [string]$(if ($itemHelp -and $itemHelp.Effects) { $itemHelp.Effects } elseif ($screen) { $screen.Effects } else { '' })
        Command        = [string]$(if ($itemHelp -and $itemHelp.Command) { $itemHelp.Command } elseif ($screen) { $screen.Command } else { '' })
        Related        = @($(if ($screen) { $screen.Related } else { @() }))
        Preconditions  = @($preconditions)
        DisabledReason = $disabledReason
    }
}

function Split-LabConsoleHelpText {
    <#
    .SYNOPSIS Bricht Hilfetext auf die Breite um, statt ihn abzuschneiden.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [ValidateRange(10, 1000)][int]$Width,
        [AllowEmptyString()][string]$Indent = '  '
    )

    $clean = ([string]$Text) -replace '[\r\n\t]', ' ' -replace '\s{2,}', ' '
    if (-not $clean.Trim()) { return @() }
    $available = [Math]::Max(10, $Width - $Indent.Length)
    $lines = [System.Collections.Generic.List[string]]::new()
    $current = ''
    foreach ($word in $clean.Trim() -split ' ') {
        if (-not $current) { $current = $word; continue }
        if (($current.Length + 1 + $word.Length) -le $available) { $current = "$current $word"; continue }
        $lines.Add($Indent + $current)
        $current = $word
    }
    if ($current) { $lines.Add($Indent + $current) }
    return @($lines)
}

function Format-LabConsoleHelp {
    <#
    .SYNOPSIS Rendert eine Hilfe als Textzeilen fuer die Overlay-Ansicht.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Topic,
        [ValidateRange(20, 1000)][int]$Width = 78
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Hilfe: $($Topic.Title)")
    $lines.Add("Bildschirm $($Topic.ScreenId)$(if ($Topic.ItemId) { " - Eintrag $($Topic.ItemLabel)" })")
    $lines.Add('')
    if ($Topic.DisabledReason) {
        $lines.Add('Nicht verfuegbar, weil')
        foreach ($line in (Split-LabConsoleHelpText -Text $Topic.DisabledReason -Width $Width)) { $lines.Add($line) }
        $lines.Add('')
    }
    $lines.Add('Zweck')
    foreach ($line in (Split-LabConsoleHelpText -Text $Topic.Purpose -Width $Width)) { $lines.Add($line) }
    if (@($Topic.Preconditions).Count -gt 0) {
        $lines.Add('')
        $lines.Add('Voraussetzungen')
        foreach ($precondition in $Topic.Preconditions) {
            $marker = if ($precondition.Ok) { '[ok]' } else { '[!] ' }
            $lines.Add("  $marker $($precondition.Label)")
            if (-not $precondition.Ok -and $precondition.Fix) {
                foreach ($line in (Split-LabConsoleHelpText -Text "Abhilfe: $($precondition.Fix)" -Width $Width -Indent '       ')) { $lines.Add($line) }
            }
        }
    }
    if ($Topic.Effects) {
        $lines.Add('')
        $lines.Add('Was danach passiert')
        foreach ($line in (Split-LabConsoleHelpText -Text $Topic.Effects -Width $Width)) { $lines.Add($line) }
    }
    if (@($Topic.Related).Count -gt 0) {
        $lines.Add('')
        $lines.Add('Zu beachten')
        foreach ($related in $Topic.Related) {
            $wrapped = @(Split-LabConsoleHelpText -Text $related -Width $Width -Indent '    ')
            for ($index = 0; $index -lt $wrapped.Count; $index++) {
                $lines.Add($(if ($index -eq 0) { '  - ' + $wrapped[$index].TrimStart() } else { $wrapped[$index] }))
            }
        }
    }
    if ($Topic.Command) {
        $lines.Add('')
        $lines.Add('Als Befehl')
        foreach ($line in (Split-LabConsoleHelpText -Text $Topic.Command -Width $Width)) { $lines.Add($line) }
    }
    $lines.Add('')
    $lines.Add('Beliebige Taste schliesst die Hilfe')
    return @($lines | ForEach-Object { Format-LabConsoleText -Text $_ -Width $Width })
}

function Show-LabConsoleHelp {
    <#
    .SYNOPSIS Zeigt die Kontexthilfe als Overlay und wartet auf eine Taste.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][object]$Topic,
        [ValidateRange(20, 1000)][int]$Width = 80,
        [ValidateRange(6, 500)][int]$Height = 25,
        [AllowNull()][scriptblock]$ReadKey,
        [AllowNull()][scriptblock]$FrameWriter
    )

    $usableWidth = [Math]::Max(20, $Width - 1)
    $helpLines = @(Format-LabConsoleHelp -Topic $Topic -Width $usableWidth)
    $visible = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $helpLines) {
        if ($visible.Count -ge $Height) { break }
        $visible.Add($line)
    }
    while ($visible.Count -lt $Height) { $visible.Add('') }
    $frame = [PSCustomObject]@{
        Lines = @($visible)
        LineColors = @($visible | ForEach-Object { '' })
        Width = $usableWidth
        Height = $Height
        ViewportHeight = $Height
        StatusHeight = 0
        StatusOffset = $Height
    }
    if ($FrameWriter) { & $FrameWriter $Session $frame } else { Write-LabConsoleFrame -Session $Session -Frame $frame }
    $key = Read-LabConsoleKey -ReadKey $ReadKey
    Assert-LabConsoleKeyNotInterrupted -Key $key
    return $key
}
