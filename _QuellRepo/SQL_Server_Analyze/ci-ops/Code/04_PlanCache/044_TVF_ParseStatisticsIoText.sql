USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_ParseStatisticsIoText
Version      : 1.0.1
Stand        : 2026-07-21
Typ          : Multi-statement Table-valued Function
Zweck        : Parst bereits vorliegenden SET STATISTICS IO-Meldungstext ohne
               eine Query auszuführen. Die Ausgabe bleibt statement-/zeilenbezogen
               und kennzeichnet unvollständig erkannte Formate.
SQL-Version  : SQL Server 2019 oder neuer.
Grenzen      : SQL Server liefert menschenorientierten Meldungstext. Der Parser
               unterstützt das dokumentierte englische Format und gebräuchliche
               deutsche Bezeichner; unbekannte Formate werden nicht erfunden.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_ParseStatisticsIoText]
(
      @StatisticsIoText   nvarchar(max)
    , @StatisticsLanguage varchar(16) = 'AUTO'
)
RETURNS @Result TABLE
(
      [StatementOrdinal]             int            NULL
    , [MessageOrdinal]               int            NOT NULL
    , [ObjectOrdinal]                int            NOT NULL
    , [ObjectDisplayName]            nvarchar(512)  NULL
    , [ScanCount]                    bigint         NULL
    , [LogicalReads]                 bigint         NULL
    , [PhysicalReads]                bigint         NULL
    , [PageServerReads]              bigint         NULL
    , [ReadAheadReads]               bigint         NULL
    , [PageServerReadAheadReads]     bigint         NULL
    , [LobLogicalReads]              bigint         NULL
    , [LobPhysicalReads]             bigint         NULL
    , [LobPageServerReads]           bigint         NULL
    , [LobReadAheadReads]            bigint         NULL
    , [LobPageServerReadAheadReads]  bigint         NULL
    , [LanguageDetected]             varchar(16)     NOT NULL
    , [ParseStatus]                  varchar(40)     NOT NULL
    , [RawLine]                      nvarchar(4000)  NULL
)
AS
BEGIN
    DECLARE @Text nvarchar(max)=COALESCE(@StatisticsIoText,N'');
    DECLARE @Language varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@StatisticsLanguage,'AUTO'))));
    IF @Language NOT IN ('AUTO','EN','DE') SET @Language='AUTO';

    SET @Text=REPLACE(REPLACE(@Text,NCHAR(13)+NCHAR(10),NCHAR(10)),NCHAR(13),NCHAR(10));

    DECLARE @Labels TABLE
    (
          [LabelOrdinal] int IDENTITY(1,1) NOT NULL PRIMARY KEY
        , [MetricCode] varchar(40) NOT NULL
        , [LabelText] nvarchar(100) NOT NULL
    );

    INSERT @Labels([MetricCode],[LabelText])
    VALUES
      ('SCAN_COUNT',N'scan count '),('SCAN_COUNT',N'scananzahl '),
      ('LOGICAL_READS',N'logical reads '),('LOGICAL_READS',N'logische lesevorgänge '),
      ('PHYSICAL_READS',N'physical reads '),('PHYSICAL_READS',N'physische lesevorgänge '),
      ('PAGE_SERVER_READS',N'page server reads '),('PAGE_SERVER_READS',N'seitenserver-lesevorgänge '),
      ('READ_AHEAD_READS',N'read-ahead reads '),('READ_AHEAD_READS',N'vorausgelesene seiten '),('READ_AHEAD_READS',N'lesevorgänge im voraus '),
      ('PAGE_SERVER_READ_AHEAD_READS',N'page server read-ahead reads '),('PAGE_SERVER_READ_AHEAD_READS',N'seitenserver-vorauslesevorgänge '),
      ('LOB_LOGICAL_READS',N'lob logical reads '),('LOB_LOGICAL_READS',N'logische lob-lesevorgänge '),
      ('LOB_PHYSICAL_READS',N'lob physical reads '),('LOB_PHYSICAL_READS',N'physische lob-lesevorgänge '),
      ('LOB_PAGE_SERVER_READS',N'lob page server reads '),('LOB_PAGE_SERVER_READS',N'lob-seitenserver-lesevorgänge '),
      ('LOB_READ_AHEAD_READS',N'lob read-ahead reads '),('LOB_READ_AHEAD_READS',N'lob-vorauslesevorgänge '),
      ('LOB_PAGE_SERVER_READ_AHEAD_READS',N'lob page server read-ahead reads '),('LOB_PAGE_SERVER_READ_AHEAD_READS',N'lob-seitenserver-vorauslesevorgänge ');

    DECLARE
          @Start int=1
        , @Next int
        , @Length int=LEN(@Text)
        , @Line nvarchar(4000)
        , @LowerLine nvarchar(4000)
        , @MessageOrdinal int=0
        , @ObjectOrdinal int=0
        , @Quote1 int
        , @Quote2 int
        , @ObjectName nvarchar(512)
        , @Detected varchar(16)
        , @MetricOrdinal int
        , @MetricMax int=(SELECT MAX([LabelOrdinal]) FROM @Labels)
        , @MetricCode varchar(40)
        , @LabelText nvarchar(100)
        , @MetricPosition int
        , @NumericText nvarchar(100)
        , @NumericTextLength int
        , @MetricValue bigint
        , @ScanCount bigint
        , @LogicalReads bigint
        , @PhysicalReads bigint
        , @PageServerReads bigint
        , @ReadAheadReads bigint
        , @PageServerReadAheadReads bigint
        , @LobLogicalReads bigint
        , @LobPhysicalReads bigint
        , @LobPageServerReads bigint
        , @LobReadAheadReads bigint
        , @LobPageServerReadAheadReads bigint;

    WHILE @Start<=@Length+1
    BEGIN
        SET @Next=CHARINDEX(NCHAR(10),@Text,@Start);
        IF @Next=0 SET @Next=@Length+1;
        SET @Line=LTRIM(RTRIM(SUBSTRING(@Text,@Start,@Next-@Start)));
        SET @Start=@Next+1;
        IF @Line=N'' CONTINUE;

        SET @LowerLine=LOWER(@Line);
        IF CHARINDEX(N'scan count ',@LowerLine)=0
           AND CHARINDEX(N'scananzahl ',@LowerLine)=0
            CONTINUE;

        SET @MessageOrdinal+=1;
        SET @ObjectOrdinal+=1;
        SET @Detected=CASE WHEN CHARINDEX(N'scananzahl ',@LowerLine)>0 THEN 'DE' ELSE 'EN' END;

        SELECT
              @ObjectName=NULL
            , @Quote1=CHARINDEX(N'''',@Line)
            , @Quote2=0
            , @ScanCount=NULL
            , @LogicalReads=NULL
            , @PhysicalReads=NULL
            , @PageServerReads=NULL
            , @ReadAheadReads=NULL
            , @PageServerReadAheadReads=NULL
            , @LobLogicalReads=NULL
            , @LobPhysicalReads=NULL
            , @LobPageServerReads=NULL
            , @LobReadAheadReads=NULL
            , @LobPageServerReadAheadReads=NULL;

        IF @Quote1>0 SET @Quote2=CHARINDEX(N'''',@Line,@Quote1+1);
        IF @Quote2>@Quote1 SET @ObjectName=SUBSTRING(@Line,@Quote1+1,@Quote2-@Quote1-1);

        SET @MetricOrdinal=1;
        WHILE @MetricOrdinal<=@MetricMax
        BEGIN
            SELECT @MetricCode=[MetricCode],@LabelText=[LabelText]
            FROM @Labels
            WHERE [LabelOrdinal]=@MetricOrdinal;

            SET @MetricPosition=CHARINDEX(@LabelText,@LowerLine);
            IF @MetricPosition>0
            BEGIN
                SET @NumericText=LTRIM(SUBSTRING(@LowerLine,@MetricPosition+LEN(@LabelText),100));
                SET @NumericTextLength=1;
                WHILE @NumericTextLength<=LEN(@NumericText)
                  AND SUBSTRING(@NumericText,@NumericTextLength,1) LIKE N'[0-9-]'
                    SET @NumericTextLength+=1;
                SET @MetricValue=TRY_CONVERT(bigint,NULLIF(LEFT(@NumericText,@NumericTextLength-1),N''));

                IF @MetricCode='SCAN_COUNT' AND @ScanCount IS NULL SET @ScanCount=@MetricValue;
                IF @MetricCode='LOGICAL_READS' AND @LogicalReads IS NULL SET @LogicalReads=@MetricValue;
                IF @MetricCode='PHYSICAL_READS' AND @PhysicalReads IS NULL SET @PhysicalReads=@MetricValue;
                IF @MetricCode='PAGE_SERVER_READS' AND @PageServerReads IS NULL SET @PageServerReads=@MetricValue;
                IF @MetricCode='READ_AHEAD_READS' AND @ReadAheadReads IS NULL SET @ReadAheadReads=@MetricValue;
                IF @MetricCode='PAGE_SERVER_READ_AHEAD_READS' AND @PageServerReadAheadReads IS NULL SET @PageServerReadAheadReads=@MetricValue;
                IF @MetricCode='LOB_LOGICAL_READS' AND @LobLogicalReads IS NULL SET @LobLogicalReads=@MetricValue;
                IF @MetricCode='LOB_PHYSICAL_READS' AND @LobPhysicalReads IS NULL SET @LobPhysicalReads=@MetricValue;
                IF @MetricCode='LOB_PAGE_SERVER_READS' AND @LobPageServerReads IS NULL SET @LobPageServerReads=@MetricValue;
                IF @MetricCode='LOB_READ_AHEAD_READS' AND @LobReadAheadReads IS NULL SET @LobReadAheadReads=@MetricValue;
                IF @MetricCode='LOB_PAGE_SERVER_READ_AHEAD_READS' AND @LobPageServerReadAheadReads IS NULL SET @LobPageServerReadAheadReads=@MetricValue;
            END;
            SET @MetricOrdinal+=1;
        END;

        INSERT @Result
        (
              [StatementOrdinal],[MessageOrdinal],[ObjectOrdinal],[ObjectDisplayName]
            , [ScanCount],[LogicalReads],[PhysicalReads],[PageServerReads]
            , [ReadAheadReads],[PageServerReadAheadReads]
            , [LobLogicalReads],[LobPhysicalReads],[LobPageServerReads]
            , [LobReadAheadReads],[LobPageServerReadAheadReads]
            , [LanguageDetected],[ParseStatus],[RawLine]
        )
        VALUES
        (
              NULL,@MessageOrdinal,@ObjectOrdinal,@ObjectName
            , @ScanCount,@LogicalReads,@PhysicalReads,@PageServerReads
            , @ReadAheadReads,@PageServerReadAheadReads
            , @LobLogicalReads,@LobPhysicalReads,@LobPageServerReads
            , @LobReadAheadReads,@LobPageServerReadAheadReads
            , @Detected
            , CASE WHEN @ObjectName IS NOT NULL AND @ScanCount IS NOT NULL AND @LogicalReads IS NOT NULL
                   THEN 'PARSED' ELSE 'PARSED_PARTIAL' END
            , LEFT(@Line,4000)
        );
    END;

    RETURN;
END;
GO
