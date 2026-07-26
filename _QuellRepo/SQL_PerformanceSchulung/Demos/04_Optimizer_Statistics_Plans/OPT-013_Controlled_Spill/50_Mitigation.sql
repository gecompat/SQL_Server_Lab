/* OPT-013 mitigation: materialize the same rows in a statistics-visible staging table. */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DROP TABLE IF EXISTS lab.SpillStage;
CREATE TABLE lab.SpillStage
(
    SpillDataId int NOT NULL CONSTRAINT PK_SpillStage PRIMARY KEY CLUSTERED,
    SortKey int NOT NULL,
    Payload char(200) NOT NULL,
    MeasureValue int NOT NULL
);

INSERT lab.SpillStage(SpillDataId,SortKey,Payload,MeasureValue)
SELECT SpillDataId,SortKey,Payload,MeasureValue
FROM lab.SpillData;

CREATE STATISTICS ST_SpillStage_Payload_SortKey
ON lab.SpillStage(Payload,SortKey)
WITH FULLSCAN;

DECLARE @Rows bigint=(SELECT COUNT_BIG(*) FROM lab.SpillStage);
IF @Rows<>300000
    THROW 51006,'FAIL_RESULT_CONTRACT: Die Staging-Tabelle enthält nicht dieselben 300000 Zeilen.',1;

SELECT 1 Sequence,'MITIGATION' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,
       CONCAT(N'SpillStageRows=',@Rows,N'; Fullscan-Statistik auf Payload/SortKey') ObservedValue,
       N'gleiche Daten in einer statistisch sichtbaren relationalen Tabelle' RequiredValue,
       N'Die Gegenmaßnahme ersetzt die cardinality-blinde Table Variable durch eine Staging-Tabelle.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
