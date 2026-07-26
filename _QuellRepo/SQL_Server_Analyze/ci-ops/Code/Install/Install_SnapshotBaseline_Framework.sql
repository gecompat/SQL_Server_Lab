:ON ERROR EXIT

USE [DeineDatenbank];
GO

/*
Installiert ausschließlich die Frameworkseite des optionalen SC-023-Pakets.
Install_All.sql bleibt bewusst zustandslos. Zuerst muss das Zielschema mit
Install_SnapshotBaseline_Target.sql in einer eigenen Datenbank installiert sein.
*/

:r ../00_Setup/000_Preflight_und_Schema.sql
:r ../10_SnapshotBaseline/010_SnapshotTargetConfiguration.sql
:r ../10_SnapshotBaseline/080_USP_ConfigureSnapshotTarget.sql
:r ../10_SnapshotBaseline/090_USP_RunSnapshotCollectionCycle.sql
:r ../10_SnapshotBaseline/100_USP_PurgeSnapshotData.sql
