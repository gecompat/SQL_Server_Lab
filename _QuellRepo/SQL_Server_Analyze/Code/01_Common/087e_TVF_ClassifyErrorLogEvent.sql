USE [DeineDatenbank];
GO

/* Reine Klassifizierung; liest und persistiert selbst keine Errorlogdaten. */
CREATE OR ALTER FUNCTION [monitor].[TVF_ClassifyErrorLogEvent]
(
      @ProductName varchar(32)
    , @RuleCategory varchar(80)
    , @MessageText nvarchar(max)
)
RETURNS TABLE
AS
RETURN
(
    SELECT CONVERT(varchar(80),
        CASE
          WHEN @ProductName='SQL_AGENT' THEN 'AGENT_ERROR'
          WHEN @MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%Error: 823%'
            OR @MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%Error: 824%'
            OR @MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%Error: 825%' THEN 'IO_ERROR'
          WHEN @MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%taking longer than 15 seconds%' THEN 'LONG_IO'
          WHEN (@MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%Backup%'
             OR @MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%Restore%')
           AND (@MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%fail%'
             OR @MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%error%') THEN 'BACKUP_RESTORE'
          WHEN @MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%cachestore flush%'
            OR @MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%FlushCache%' THEN 'CACHE_FLUSH'
          WHEN @MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%Autogrow%' THEN 'AUTOGROWTH'
          WHEN @MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%Stack Dump%'
            OR @MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%Assertion%' THEN 'DUMP_ASSERTION'
          WHEN @MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%Login failed%'
            OR @MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%17830%' THEN 'LOGIN_CONNECTIVITY'
          WHEN @MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%Log Shipping%' THEN 'LOG_SHIPPING'
          WHEN @MessageText COLLATE SQL_Latin1_General_CP1_CI_AS LIKE N'%Replication%' THEN 'REPLICATION'
          ELSE COALESCE(@RuleCategory,'UNCLASSIFIED')
        END) AS [Category]
);
GO
