USE [SQLServerAnalyzeTest];
GO
SET NOCOUNT ON;
DECLARE @Result int;
EXEC @Result=[sys].[sp_getapplock]
     @Resource=N'SQL_Server_Analyze.SC023.CollectionCycle',@LockMode='Exclusive',
     @LockOwner='Session',@LockTimeout=0,@DbPrincipal=N'public';
IF @Result<0 THROW 53740,N'SC023_CONCURRENCY_HOLDER_FAILED',1;
WAITFOR DELAY '00:00:12';
EXEC [sys].[sp_releaseapplock]
     @Resource=N'SQL_Server_Analyze.SC023.CollectionCycle',@LockOwner='Session',@DbPrincipal=N'public';
GO
