USE [DeineDatenbank];
GO

-- Parservertrag: Pipe innerhalb von Brackets ist kein Trenner.
SELECT * FROM [monitor].[TVF_ParseSqlNameList](N'[ColumnOne]|[Column With Spaces]|[Column|WithPipe]');
SELECT * FROM [monitor].[TVF_ParseSqlNameList](N'[Das ist | ein komischer Objektname]|[der auch]|[der_nicht]|der_auch_nicht');
SELECT * FROM [monitor].[TVF_ParseFullObjectNameList](N'[DeineDatenbank].dbo.[IrgendeinObjekt]|und.noch.eines');
SELECT * FROM [monitor].[TVF_ParsePattern](N'regexi:^(dbo|monitor)$');
-- Steuerwerte case-insensitiv.
DECLARE @Json nvarchar(max);
EXEC [monitor].[USP_CheckAnalyseAccess] @ResultSetArt='raw',@JsonErzeugen=1,@Json=@Json OUTPUT;
SELECT @Json AS [Json];
GO
