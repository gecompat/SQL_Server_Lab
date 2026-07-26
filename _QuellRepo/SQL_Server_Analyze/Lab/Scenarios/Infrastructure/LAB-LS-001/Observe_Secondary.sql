SET NOCOUNT ON;

DECLARE @LogShippingJson nvarchar(max);
EXEC [LabAnalyze].[monitor].[USP_LogShippingStatus]
      @MaxZeilen = 100
    , @ResultSetArt = 'NONE'
    , @JsonErzeugen = 1
    , @Json = @LogShippingJson OUTPUT
    , @PrintMeldungen = 0;

SELECT N'LAB_ANALYZER_JSON=' +
(
    SELECT JSON_QUERY(@LogShippingJson) AS [logShipping]
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
);
