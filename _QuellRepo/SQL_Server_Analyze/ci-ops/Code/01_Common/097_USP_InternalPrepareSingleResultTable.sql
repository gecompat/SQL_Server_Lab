USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.InternalPrepareSingleResultTable
Version      : 1.0.0
Stand        : 2026-07-20
Typ          : Interne Stored Procedure
Zweck        : Führt den benannten TABLE-Preflight für eine Procedure mit genau
               einem exportierbaren Resultset aus und gibt das validierte lokale
               Ziel zurück. Fachliche Systemquellen werden nicht gelesen.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[InternalPrepareSingleResultTable]
      @ResultTablesJson  nvarchar(max)
    , @ResultName        sysname
    , @TargetTable       sysname        OUTPUT
    , @ThrowOnError      bit            = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;
    SET @TargetTable=NULL;

    CREATE TABLE [#InternalPrepareSingleResultTable_Map]
    (
          [ResultName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL PRIMARY KEY
        , [TargetTable] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL UNIQUE
    );

    DECLARE @StatusCode varchar(40),@ErrorMessage nvarchar(2048);
    EXEC [monitor].[InternalPrepareResultTables]
          @ResultTablesJson=@ResultTablesJson
        , @AllowedResultNames=@ResultName
        , @MappingTable=N'#InternalPrepareSingleResultTable_Map'
        , @StatusCode=@StatusCode OUTPUT
        , @ErrorMessage=@ErrorMessage OUTPUT
        , @ThrowOnError=@ThrowOnError;

    IF @StatusCode='AVAILABLE'
        SELECT @TargetTable=[TargetTable]
        FROM [#InternalPrepareSingleResultTable_Map]
        WHERE [ResultName]=@ResultName COLLATE SQL_Latin1_General_CP1_CS_AS;
END;
GO
