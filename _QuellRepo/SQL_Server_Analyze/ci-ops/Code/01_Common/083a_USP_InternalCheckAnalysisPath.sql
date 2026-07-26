USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.InternalCheckAnalysisPath
Version      : 1.1.0
Stand        : 2026-07-21
Typ          : Interne Stored Procedure
Zweck        : Prüft einen tatsächlich aktivierten Analysepfad auf bekannte
               Klasse, High-Impact-Bestätigung und aktuelle Freigabe, bevor
               fachliche DMV-, Cache-, Query-Store- oder Katalogzugriffe
               beginnen.
Fallback     : Kann der serverseitige Login-Token unter EXECUTE AS USER oder
               einem vergleichbaren datenbankgebundenen Kontext nicht gelesen
               werden, bleiben ungeschützte Klassen, sysadmin und offene Policy
               erlaubt. Eine aktive gruppengeschützte Policy wird konservativ
               als DENIED_GROUP behandelt; sie wird niemals still umgangen.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[InternalCheckAnalysisPath]
      @AnalysisClass        varchar(64)
    , @HighImpactConfirmed  bit
    , @StatusCode           varchar(40)    OUTPUT
    , @ErrorMessage         nvarchar(2048) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;

    SELECT @StatusCode='AVAILABLE',@ErrorMessage=NULL;

    IF NULLIF(@AnalysisClass,'') IS NULL
       OR @HighImpactConfirmed IS NULL
       OR @HighImpactConfirmed NOT IN (0,1)
    BEGIN
        SET @StatusCode='INVALID_PARAMETER';
        SET @ErrorMessage=N'Analyseklasse oder High-Impact-Bestätigung ist ungültig.';
        RETURN;
    END;

    DECLARE
          @RequiresHighImpact bit=0
        , @Allowed bit=0
        , @UsedDatabaseOnlyFallback bit=0
        , @IsSysadmin bit=CONVERT(bit,CASE WHEN IS_SRVROLEMEMBER(N'sysadmin')=1 THEN 1 ELSE 0 END);

    BEGIN TRY
        SELECT
              @RequiresHighImpact=COALESCE(MAX(CONVERT(tinyint,[c].[RequiresGroupGate])),0)
            , @Allowed=COALESCE(MAX(CONVERT(tinyint,[a].[IsAllowed])),0)
        FROM [monitor].[VW_AnalyseClassCatalog] AS [c]
        LEFT JOIN [monitor].[VW_AnalyseAccessCurrent] AS [a]
          ON [a].[AnalysisClass]=[c].[AnalysisClass]
        WHERE [c].[AnalysisClass]=@AnalysisClass;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (229,371,916)
            THROW;

        SET @UsedDatabaseOnlyFallback=1;

        SELECT @RequiresHighImpact=COALESCE(MAX(CONVERT(tinyint,[c].[RequiresGroupGate])),0)
        FROM [monitor].[VW_AnalyseClassCatalog] AS [c]
        WHERE [c].[AnalysisClass]=@AnalysisClass;

        SET @Allowed=CONVERT(bit,CASE
              WHEN @RequiresHighImpact=0 THEN 1
              WHEN @IsSysadmin=1 THEN 1
              WHEN NOT EXISTS
                   (
                       SELECT 1
                       FROM [monitor].[VW_AnalyseAccessPolicy] AS [p]
                       WHERE [p].[IsEnabled]=1
                         AND ([p].[ValidFromUtc] IS NULL OR [p].[ValidFromUtc]<=SYSUTCDATETIME())
                         AND ([p].[ValidToUtc] IS NULL OR [p].[ValidToUtc]>SYSUTCDATETIME())
                         AND NULLIF(LTRIM(RTRIM([p].[AnalysisClass])),N'') IS NOT NULL
                         AND NULLIF(LTRIM(RTRIM([p].[ADGroupName])),N'') IS NOT NULL
                   ) THEN 1
              ELSE 0 END);
    END CATCH;

    IF NOT EXISTS
       (
           SELECT 1
           FROM [monitor].[VW_AnalyseClassCatalog]
           WHERE [AnalysisClass]=@AnalysisClass
       )
    BEGIN
        SET @StatusCode='INVALID_PARAMETER';
        SET @ErrorMessage=CONCAT(N'Unbekannte Analyseklasse: ',@AnalysisClass,N'.');
        RETURN;
    END;

    IF @RequiresHighImpact=1 AND @HighImpactConfirmed<>1
    BEGIN
        SET @StatusCode='HIGH_IMPACT_CONFIRMATION_REQUIRED';
        SET @ErrorMessage=CONCAT(N'Der aktivierte Analysepfad ',@AnalysisClass,N' erfordert @HighImpactConfirmed=1.');
        RETURN;
    END;

    IF @Allowed<>1
    BEGIN
        SET @StatusCode='DENIED_GROUP';
        SET @ErrorMessage=CASE WHEN @UsedDatabaseOnlyFallback=1
                              THEN CONCAT(@AnalysisClass,N' ist nicht freigegeben; der serverseitige Gruppentoken war im aktuellen Datenbankkontext nicht lesbar.')
                              ELSE CONCAT(@AnalysisClass,N' ist nicht freigegeben.') END;
    END;
END;
GO
