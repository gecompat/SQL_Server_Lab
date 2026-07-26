USE [DeineDatenbank];
GO

SET NOCOUNT ON;

DECLARE @Fehler TABLE
(
      [ObjectName] sysname NOT NULL
    , [Finding] varchar(80) NOT NULL
    , [Detail] nvarchar(1000) NULL
);

INSERT @Fehler ([ObjectName],[Finding],[Detail])
SELECT [o].[name], 'LEGACY_PARAMETER', [p].[name]
FROM [sys].[objects] AS [o] WITH (NOLOCK)
JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
JOIN [sys].[parameters] AS [p] WITH (NOLOCK) ON [p].[object_id]=[o].[object_id]
WHERE [s].[name]=N'monitor'
  AND [o].[type]=N'P'
  AND [p].[name] IN
  (
      N'@AlleDatenbanken',N'@EmitResultsets',N'@MaxEvents',N'@MaxDeadlocks',
      N'@MaxReports',N'@MaxPlaene',N'@MaxErgebniszeilen',N'@MaxLockZeilen',
      N'@MaxDetailZeilen',N'@DatabaseName',N'@SessionId'
  );

INSERT @Fehler ([ObjectName],[Finding],[Detail])
SELECT [o].[name], 'MISSING_OUTPUT_CONTRACT', [v].[ParameterName]
FROM [sys].[objects] AS [o] WITH (NOLOCK)
JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
CROSS APPLY (VALUES(N'@ResultSetArt'),(N'@ResultTablesJson'),(N'@JsonErzeugen'),(N'@Json')) AS [v]([ParameterName])
WHERE [s].[name]=N'monitor'
  AND [o].[type]=N'P'
  AND [o].[name] NOT LIKE N'Internal%'
  AND [o].[name] NOT LIKE N'USP_Prepare%'
  AND NOT EXISTS
      (
          SELECT 1
          FROM [sys].[parameters] AS [p] WITH (NOLOCK)
          WHERE [p].[object_id]=[o].[object_id]
            AND [p].[name]=[v].[ParameterName]
      );

SELECT * FROM @Fehler ORDER BY [ObjectName],[Finding],[Detail];
IF EXISTS(SELECT 1 FROM @Fehler)
    THROW 51000, N'Der öffentliche Parameter-API-Vertrag ist verletzt.', 1;
GO
