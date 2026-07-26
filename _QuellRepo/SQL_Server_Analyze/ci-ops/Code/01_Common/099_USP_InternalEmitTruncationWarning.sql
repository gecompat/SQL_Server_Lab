USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.InternalEmitTruncationWarning
Version      : 1.0.0
Stand        : 2026-07-21
Typ          : Interne Stored Procedure
Zweck        : Gibt höchstens eine technische Severity-10-Warning für alle im
               Aufruf sichtbar gekürzten Werte aus.
Resultsets   : Keine.
Nebenwirkung : Ausschließlich RAISERROR Severity 10 WITH NOWAIT, wenn die
               Ausgabe aktiviert und mindestens ein Wert gekürzt ist.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[InternalEmitTruncationWarning]
      @TruncatedValueCount       bigint
    , @ParameterName             sysname
    , @ParameterValue            int
    , @LargestRequiredCharacters bigint
    , @PrintMeldungen            bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;

    IF COALESCE(@PrintMeldungen,0) <> 1
       OR COALESCE(@TruncatedValueCount,0) <= 0
        RETURN;

    DECLARE @Message nvarchar(2048) = LEFT
    (
        CONCAT
        (
              N'OUTPUT_VALUE_TRUNCATED: '
            , CONVERT(nvarchar(30),@TruncatedValueCount)
            , N' Wert(e) wurden durch '
            , COALESCE(@ParameterName,N'<unbekannter Parameter>')
            , N'='
            , COALESCE(CONVERT(nvarchar(30),@ParameterValue),N'NULL')
            , N' gekürzt. Der größte Wert benötigt '
            , COALESCE(CONVERT(nvarchar(30),@LargestRequiredCharacters),N'NULL')
            , N' Zeichen. Verwenden Sie '
            , COALESCE(@ParameterName,N'den begrenzenden Parameter')
            , N'='
            , COALESCE(CONVERT(nvarchar(30),@LargestRequiredCharacters),N'0')
            , N' oder 0 für eine vollständige Ausgabe.'
        ),
        2048
    );

    RAISERROR(N'%s',10,1,@Message) WITH NOWAIT;
END;
GO
