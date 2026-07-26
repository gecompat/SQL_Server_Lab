# Quellenmanifest – Performance-Schulung

| Merkmal | Wert |
|---|---|
| Arbeitspaket | `W0-001`, Klassifikation aktualisiert durch `W2-001` |
| Status | `VALIDATED` |
| Stand | 2026-07-25 |
| Referenz-Commit | `b70cd8acc7c348c09e2234fb8c0d8ea8cb52677b` |
| Datenschutz | ausschließlich neutralisierte Bestandsquellen und freigegebene Namensangabe |

## 1. Zweck und Geltungsbereich

Dieses Manifest identifiziert die vorhandenen fachlichen Ausgangsartefakte über Inhaltshashes und legt deren Rolle im Projekt fest. Ein Eintrag bedeutet nicht, dass eine fachliche Aussage oder ein Beispiel als ausführbares Artefakt freigegeben ist. Die fachliche Entscheidung für SQL- und Textbeispiele steht in der [W2-001-Klassifikation](LEGACY_EXAMPLE_CLASSIFICATION.md).

Die ursprünglichen, nicht neutralisierten Uploads sind keine Repository-Quellen. Maßgeblich sind ausschließlich das neutralisierte Archiv unter `Presentations/old` und der neu erstellte Foliensatz unter `Presentations`.

## 2. Repository-Artefakte

| ID | Repository-Pfad | Typ | Umfang | SHA-256 | Git-Blob | Herkunftsklasse | Privacy-Status | Importentscheidung |
|---|---|---|---:|---|---|---|---|---|
| `SRC-ARCHIVE-001` | `Presentations/old/Performance Grundlagen V-2024.zip` | ZIP | 16.742.690 Byte; 30 Dateien | `78e3d1d708758d1115a066eca1df2c66d6f26ba57903b764c98e901506892041` | `f38de84504679595ef2068d21a42f62aa78f7727` | neutralisierter Altbestand | `PASS` | nur als Referenzarchiv; keine direkte Ausführung |
| `SRC-DECK-001` | `Presentations/Performance_Schulung_Chat_2026-07-23_2146_SQL_Server_Performance_Grundlagen.pptx` | PPTX | 84 Folien | `3ad528c2eb6ad531c1bbf5a26bee17e35004f764357b5061c9fc15bc04807a18` | `48e479c56691c6fb5b91818e59ab7c05bb18dbed` | neutraler Neuaufbau | `PASS` | aktive Präsentationsbasis; 84 Claims durch `W2-007` als `KEEP` validiert |

## 3. Inhaltsübersicht des Referenzarchivs

| Artefaktgruppe | Anzahl | Projektrolle |
|---|---:|---|
| Präsentationsmodule | 5 | historische Themen- und Aussagenquelle; durch `SRC-DECK-001` ersetzt |
| Begleitdokumente | 2 | Referenz für später neu aufzubauende Teilnehmer- und Trainerunterlagen |
| SQL-Beispiele | 19 | durch `W2-001` klassifiziert; keine direkte Ausführung |
| Textbasierte Diagnosebeispiele | 4 | durch `W2-001` als `DIAGNOSTIC_ONLY` klassifiziert |

Die Dateien des Referenzarchivs werden nicht einzeln in aktive Projektpfade kopiert. Dadurch bleibt erkennbar, welche Inhalte historische Quellen und welche Inhalte geprüfte Projektartefakte sind.

## 4. Einzelmanifest des Referenzarchivs

Alle Pfade in der folgenden Tabelle sind relativ zum Archivwurzelverzeichnis `Performance Grundlagen V-2024/`.

| ID | Pfad | Typ | Byte | SHA-256 | Herkunft | Entscheidung |
|---|---|---|---:|---|---|---|
| `SRC-LEGACY-001` | `Performance Grundlagen 2024 - 0 Einführung.pptx` | PPTX | 384.245 | `19c9414d9e686040b5a75baddaa4a196d52ea4366629382a17fdb87d5651d836` | Altmodul | `REBUILD`; durch neues Deck ersetzt |
| `SRC-LEGACY-002` | `Performance Grundlagen 2024 - 1 Data Storage Internals.pptx` | PPTX | 1.593.282 | `f4cdf41d346e1233c026000e68d500eb64e71d04660bfa6488f4bfaee744c684` | Altmodul | `REBUILD`; durch neues Deck ersetzt |
| `SRC-LEGACY-003` | `Performance Grundlagen 2024 - 2 Processing Internals.pptx` | PPTX | 8.071.235 | `02e8e59fb6357f2d6bdc7188088c8afb2425a0fcaec8801043a36fb4f2fd6801` | Altmodul | `REBUILD`; durch neues Deck ersetzt |
| `SRC-LEGACY-004` | `Performance Grundlagen 2024 - 3 Abfrageperformance und Fallen.pptx` | PPTX | 2.190.515 | `f724b960d482a87d8a2bdba28e42b6ec88fa31b533c40df8de5f0892943a178e` | Altmodul | `REBUILD`; durch neues Deck ersetzt |
| `SRC-LEGACY-005` | `Performance Grundlagen 2024 - 4 Index.pptx` | PPTX | 4.614.275 | `0192bfcf1d1a707d35046887d0050fdeb396bd80c1480e5b5837b1b9484eada0` | Altmodul | `REBUILD`; durch neues Deck ersetzt |
| `SRC-LEGACY-006` | `SQL Server Isolation Levels Te.docx` | DOCX | 12.492 | `4e2d64ff9d17ab7ffac96c559ad2a58274befe30545c47a249414dba9dc26d6c` | Begleitdokument | fachliche Referenz; Teilnehmerunterlage neu aufbauen |
| `SRC-LEGACY-007` | `SQL Server Performance Checklist.docx` | DOCX | 17.916 | `5f1754591b459600b7dfc12b172c6192077625eec5e599c6a3985c420847219b` | Begleitdokument | fachliche Referenz; Teilnehmerunterlage neu aufbauen |
| `SRC-LEGACY-008` | `tsql_isolation_demo.sql` | SQL | 1.452 | `d639f8697f210a6a40c5380ecae3dc3e2196d61d20aaa37c160e1e2e3fb54310` | Beispiel | `REBUILD`; CON-001/CON-002/CON-003 |
| `SRC-LEGACY-009` | `Beispiele/Apply.sql` | SQL | 1.666 | `30bc796a8ce4780fd5bdd4de22ec45bba2aebde5121c282067ca43d53632e654` | Beispiel | `REFACTOR`; QRY-009/QRY-010 |
| `SRC-LEGACY-010` | `Beispiele/BufferPool füllt sich.sql` | SQL | 637 | `f869e205d839cdef07b634a0afd0ac206cc2c28f0813d4520bdc65ecbe47b77a` | Beispiel | `REBUILD`; STL-006/DGN-001 |
| `SRC-LEGACY-011` | `Beispiele/DMV_Count_Rows_in_Table.txt` | TXT | 336 | `5588ce942df598e0b8f99683d9eef55e2ad610b01e84bcc7c05e129500e82efe` | Diagnosebeispiel | `DIAGNOSTIC_ONLY`; DGN-002/STL-004 |
| `SRC-LEGACY-012` | `Beispiele/DMV_MemoryGrant.txt` | TXT | 2.923 | `42a618cc41894c803bf7c938d0b1c6252f1232d92a6dd42cc1ae8ca95daed93e` | Diagnosebeispiel | `DIAGNOSTIC_ONLY`; DGN-002/OPT-014/RES-004 |
| `SRC-LEGACY-013` | `Beispiele/DMV_Requests_text.txt` | TXT | 613 | `ac0c2f0499a59efad687e90eab6fd681a6a2250da9031062d50a60aade87b233` | Diagnosebeispiel | `DIAGNOSTIC_ONLY`; DGN-002 |
| `SRC-LEGACY-014` | `Beispiele/DMV_WaitStats.txt` | TXT | 1.230 | `f169803a9cf254783f6cd3b00bc85c1d9dc3385905ca5051e26292b720fae252` | Diagnosebeispiel | `DIAGNOSTIC_ONLY`; RES-007/DGN-002 |
| `SRC-LEGACY-015` | `Beispiele/for xml path.sql` | SQL | 1.206 | `9f88dc791795390dd0636043c807401651b46932f5ddcd26152f1177472b6e40` | Beispiel | `REMOVE`; QRY-012 |
| `SRC-LEGACY-016` | `Beispiele/functions_1.sql` | SQL | 4.209 | `46a0b4e4e9b04a96bbd4fb498f9d04f06e590cc058a67df026c6ec7e26616f69` | Beispiel | `REMOVE`; keine aktive Ziel-Demo |
| `SRC-LEGACY-017` | `Beispiele/Index_usage_partition.sql` | SQL | 764 | `4e730d5c65548d88793946fecc4fd1aae3cac5bfd101c658a94114b784ba7e52` | Beispiel | `REBUILD`; QRY-012 |
| `SRC-LEGACY-018` | `Beispiele/Join Typen.sql` | SQL | 1.402 | `aaee60eed936338c779d5edb5d2f8b0197e956227cee53d4c3d472055e945c0a` | Beispiel | `REBUILD`; OPT-012 |
| `SRC-LEGACY-019` | `Beispiele/json_parallel.sql` | SQL | 1.180 | `dd8d8d50b2c63358dc5036b64ce88f8048d6b575414a2f61d832c8f62980e6d7` | Beispiel | `REBUILD`; QRY-012/RES-002 |
| `SRC-LEGACY-020` | `Beispiele/NON-Sargable.sql` | SQL | 2.977 | `c57fc476c08af4dcca75210983965fec832a38a87f46afa32e5eff7fbb2992b6` | Beispiel | `REBUILD`; QRY-001/QRY-002/QRY-003/QRY-004 |
| `SRC-LEGACY-021` | `Beispiele/Page Größe bzw. Max Spalten.sql` | SQL | 149.709 | `390f67fa080758a0ddbf5fd6266e78240a0a5635edabe269b0a227237b784c62` | Beispiel | `REMOVE`; STL-001 |
| `SRC-LEGACY-022` | `Beispiele/Parameter Sniffing.sql` | SQL | 3.550 | `5dfb6db7959e6ef92f72fa09a3397a2963bf10d1492d42154cd69a0191611864` | Beispiel | `REBUILD`; OPT-008/OPT-009 |
| `SRC-LEGACY-023` | `Beispiele/Partition Elimination.sql` | SQL | 1.815 | `8f4d6bc1238300b88a85eba0f8031459f90ac6d756d9a9d6ac429c6e1a32956c` | Beispiel | `REBUILD`; QRY-012/RES-002 |
| `SRC-LEGACY-024` | `Beispiele/Partition Views.sql` | SQL | 6.107 | `5d21e5c943155b1bcb6d77bfdbe10afbfbaca36aa72eea583768ceef4dd7ee2b` | Beispiel | `REMOVE`; QRY-012 |
| `SRC-LEGACY-025` | `Beispiele/perfSubsel.sql` | SQL | 8.718 | `d6cb421e9dd017659b6bc5ebbfda178dace3d395427fcdfd285cd28d37afc2ac` | Beispiel | `REBUILD`; QRY-005/QRY-010 |
| `SRC-LEGACY-026` | `Beispiele/schnell ist nicht immer Ressourcen schonend.sql` | SQL | 1.654 | `295df9271e44e9869dfbd6742e114b3a251a325348c61cdc88c4799621205799` | Beispiel | `REBUILD`; RES-002/QRY-001 |
| `SRC-LEGACY-027` | `Beispiele/SearchNull.sql` | SQL | 1.605 | `7597da803785b628586e5db7eea5918c879508309d75446a47a4c9d86a01fd2a` | Beispiel | `REBUILD`; QRY-006/IDX-003 |
| `SRC-LEGACY-028` | `Beispiele/Tipping Point AdventureWorks2022.sql` | SQL | 750 | `83952cb811e55f6b94c92b2d262b6644cfbbc5378232547784f5d7eb5eee6312` | Beispiel | `REBUILD`; IDX-004 |
| `SRC-LEGACY-029` | `Beispiele/uniquifier.sql` | SQL | 15.582 | `19c5cb0b65a96898a852a3b6652500144a5bea00c25d010d39b5e3d7de2140fb` | Beispiel | `REBUILD`; IDX-002/STL-001 |
| `SRC-LEGACY-030` | `Beispiele/Was_weiß_der_Optimizer_TagID.sql` | SQL | 7.120 | `133da0f29792e501c5a74e758944e1adbf4d657c66cae41fede6201e0d5a6baa` | Beispiel | `REBUILD`; OPT-002/OPT-003/OPT-004 |

## 5. Status- und Änderungsregeln

Der Hash bezieht sich jeweils auf die unveränderten Bytes des Repository-Artefakts beziehungsweise des Eintrags im Referenzarchiv. Jede inhaltliche Änderung erzeugt ein neues Artefakt oder einen neuen Hash und muss dieses Manifest aktualisieren.

Die W2-001-Entscheidungen sind Migrationsentscheidungen, keine Runtime-Freigabe der historischen Skripte. Vor einer Übernahme in aktive Demos sind fachliche Prüfung, synthetische Daten, Demo-Vertrag, Privacy-Prüfung und die zutreffende SQL-Server-Versionsmatrix erforderlich. `DIAGNOSTIC_ONLY` erlaubt nur einen später neu dokumentierten read-only Diagnosepfad; die historische Datei bleibt nicht direkt ausführbar.

## 6. Validierungsnachweis

- Das Git-Blob des Referenzarchivs stimmt mit dem neutralisierten Archiv-Hash überein.
- Die 23 SQL-/TXT-Einträge wurden durch `W2-001` inhaltlich geprüft und maschinenlesbar klassifiziert.
- Der Validator liest das verschachtelte ZIP direkt und gleicht jeden Archivpfad, Byteumfang und SHA-256-Wert ab.
- Das Referenzarchiv enthält 30 Dateien: 5 PPTX, 2 DOCX, 19 SQL und 4 TXT.
- Der aktive Foliensatz enthält 84 Folien und keine eingebetteten Medien.
- Nicht neutralisierte Originaluploads sind nicht als zulässige Projektquelle eingetragen.
