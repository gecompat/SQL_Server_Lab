SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @CapabilityJson nvarchar(max);

EXEC [LabAnalyze].[sys].[sp_executesql]
      N'
IF DATABASE_PRINCIPAL_ID(N''LabRestrictedUser'') IS NULL
    CREATE USER [LabRestrictedUser] WITHOUT LOGIN;

GRANT EXECUTE ON [monitor].[USP_CheckFrameworkCapabilities]
TO [LabRestrictedUser];

BEGIN TRY
    EXECUTE AS USER = N''LabRestrictedUser'';

    EXEC [monitor].[USP_CheckFrameworkCapabilities]
          @DatabaseNames = N''[Lab001Synthetic]''
        , @AnalyseKlasse = ''STANDARD_CURRENT''
        , @ResultSetArt = ''NONE''
        , @JsonErzeugen = 1
        , @Json = @CapabilityJson OUTPUT
        , @PrintMeldungen = 0;

    REVERT;
END TRY
BEGIN CATCH
    IF USER_NAME() = N''LabRestrictedUser''
        REVERT;
    THROW;
END CATCH;'
    , N'@CapabilityJson nvarchar(max) OUTPUT'
    , @CapabilityJson = @CapabilityJson OUTPUT;

IF COALESCE(ISJSON(@CapabilityJson), 0) <> 1
    THROW 55011, N'LAB-BASE-002 did not receive valid JSON.', 1;

IF JSON_VALUE(@CapabilityJson, N'$.meta.statusCode')
   NOT IN (N'AVAILABLE', N'AVAILABLE_LIMITED')
    THROW 55012, N'LAB-BASE-002 returned an unexpected status.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM OPENJSON(@CapabilityJson, N'$.capabilities')
    WITH
    (
          [StatusCode] varchar(40) N'$.StatusCode'
        , [HasRequiredPermission] bit N'$.HasRequiredPermission'
        , [IsQueryable] bit N'$.IsQueryable'
        , [IsUsable] bit N'$.IsUsable'
    ) AS [c]
    WHERE [c].[StatusCode] IN
          (
              'DENIED_PERMISSION',
              'AVAILABLE_LIMITED',
              'AVAILABLE_UNVERIFIED',
              'ERROR_HANDLED'
          )
       OR [c].[HasRequiredPermission] = 0
       OR [c].[IsQueryable] = 0
       OR [c].[IsUsable] = 0
)
    THROW 55013, N'LAB-BASE-002 did not observe a permission boundary.', 1;

SELECT CONCAT
(
      N'LAB_ASSERTION_JSON='
    , (
        SELECT
              N'LAB-BASE-002' AS [ScenarioId]
            , N'PASS' AS [Status]
            , JSON_VALUE(@CapabilityJson, N'$.meta.statusCode') AS [AnalyzerStatus]
            , JSON_QUERY(N'["PERMISSION_BOUNDARY_OBSERVED"]') AS [FindingCodes]
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
      )
);
