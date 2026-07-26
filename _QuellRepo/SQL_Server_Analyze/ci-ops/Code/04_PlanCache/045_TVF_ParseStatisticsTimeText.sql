USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_ParseStatisticsTimeText
Version      : 1.0.1
Stand        : 2026-07-21
Typ          : Multi-statement Table-valued Function
Zweck        : Parst bereits vorliegenden SET STATISTICS TIME-Meldungstext ohne
               SQL auszuführen. Parse-/Compile- und Execution-Blöcke bleiben
               getrennt; mehrdeutige Formate werden als partiell markiert.
SQL-Version  : SQL Server 2019 oder neuer.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_ParseStatisticsTimeText]
(
      @StatisticsTimeText nvarchar(max)
    , @StatisticsLanguage varchar(16) = 'AUTO'
)
RETURNS @Result TABLE
(
      [StatementOrdinal] int           NULL
    , [MessageOrdinal]   int           NOT NULL
    , [TimeCategory]     varchar(24)   NOT NULL
    , [CpuMs]            bigint        NULL
    , [ElapsedMs]        bigint        NULL
    , [LanguageDetected] varchar(16)   NOT NULL
    , [ParseStatus]      varchar(40)   NOT NULL
    , [RawLine]          nvarchar(4000) NULL
)
AS
BEGIN
    DECLARE @Text nvarchar(max)=COALESCE(@StatisticsTimeText,N'');
    SET @Text=REPLACE(REPLACE(@Text,NCHAR(13)+NCHAR(10),NCHAR(10)),NCHAR(13),NCHAR(10));

    DECLARE
          @Start int=1
        , @Next int
        , @Length int=LEN(@Text)
        , @Line nvarchar(4000)
        , @LowerLine nvarchar(4000)
        , @Category varchar(24)='UNKNOWN'
        , @Detected varchar(16)='EN'
        , @MessageOrdinal int=0
        , @CpuPosition int
        , @ElapsedPosition int
        , @NumericText nvarchar(100)
        , @NumericTextLength int
        , @CpuMs bigint
        , @ElapsedMs bigint;

    WHILE @Start<=@Length+1
    BEGIN
        SET @Next=CHARINDEX(NCHAR(10),@Text,@Start);
        IF @Next=0 SET @Next=@Length+1;
        SET @Line=LTRIM(RTRIM(SUBSTRING(@Text,@Start,@Next-@Start)));
        SET @Start=@Next+1;
        IF @Line=N'' CONTINUE;

        SET @LowerLine=LOWER(@Line);

        IF CHARINDEX(N'parse and compile time',@LowerLine)>0
           OR CHARINDEX(N'analyse- und kompilierzeit',@LowerLine)>0
           OR CHARINDEX(N'parse- und kompilierzeit',@LowerLine)>0
        BEGIN
            SET @Category='PARSE_COMPILE';
            SET @Detected=CASE WHEN CHARINDEX(N'compile time',@LowerLine)>0 THEN 'EN' ELSE 'DE' END;
            IF CHARINDEX(N'cpu time =',@LowerLine)=0 AND CHARINDEX(N'cpu-zeit =',@LowerLine)=0 CONTINUE;
        END;

        IF CHARINDEX(N'execution times',@LowerLine)>0
           OR CHARINDEX(N'ausführungszeiten',@LowerLine)>0
           OR CHARINDEX(N'ausführungszeit',@LowerLine)>0
        BEGIN
            SET @Category='EXECUTION';
            SET @Detected=CASE WHEN CHARINDEX(N'execution times',@LowerLine)>0 THEN 'EN' ELSE 'DE' END;
            IF CHARINDEX(N'cpu time =',@LowerLine)=0 AND CHARINDEX(N'cpu-zeit =',@LowerLine)=0 CONTINUE;
        END;

        SET @CpuPosition=CHARINDEX(N'cpu time =',@LowerLine);
        IF @CpuPosition=0 SET @CpuPosition=CHARINDEX(N'cpu-zeit =',@LowerLine);
        SET @ElapsedPosition=CHARINDEX(N'elapsed time =',@LowerLine);
        IF @ElapsedPosition=0 SET @ElapsedPosition=CHARINDEX(N'verstrichene zeit =',@LowerLine);

        IF @CpuPosition=0 AND @ElapsedPosition=0 CONTINUE;

        SELECT @CpuMs=NULL,@ElapsedMs=NULL;
        IF @CpuPosition>0
        BEGIN
            SET @NumericText=LTRIM(SUBSTRING(@LowerLine,@CpuPosition+CASE WHEN SUBSTRING(@LowerLine,@CpuPosition,8)=N'cpu time' THEN LEN(N'cpu time =') ELSE LEN(N'cpu-zeit =') END,100));
            SET @NumericTextLength=1;
            WHILE @NumericTextLength<=LEN(@NumericText)
              AND SUBSTRING(@NumericText,@NumericTextLength,1) LIKE N'[0-9-]'
                SET @NumericTextLength+=1;
            SET @CpuMs=TRY_CONVERT(bigint,NULLIF(LEFT(@NumericText,@NumericTextLength-1),N''));
        END;

        IF @ElapsedPosition>0
        BEGIN
            SET @NumericText=LTRIM(SUBSTRING(@LowerLine,@ElapsedPosition+CASE WHEN SUBSTRING(@LowerLine,@ElapsedPosition,7)=N'elapsed' THEN LEN(N'elapsed time =') ELSE LEN(N'verstrichene zeit =') END,100));
            SET @NumericTextLength=1;
            WHILE @NumericTextLength<=LEN(@NumericText)
              AND SUBSTRING(@NumericText,@NumericTextLength,1) LIKE N'[0-9-]'
                SET @NumericTextLength+=1;
            SET @ElapsedMs=TRY_CONVERT(bigint,NULLIF(LEFT(@NumericText,@NumericTextLength-1),N''));
        END;

        SET @MessageOrdinal+=1;
        INSERT @Result
        (
              [StatementOrdinal],[MessageOrdinal],[TimeCategory]
            , [CpuMs],[ElapsedMs],[LanguageDetected],[ParseStatus],[RawLine]
        )
        VALUES
        (
              NULL,@MessageOrdinal,@Category,@CpuMs,@ElapsedMs,@Detected
            , CASE WHEN @Category<>'UNKNOWN' AND @CpuMs IS NOT NULL AND @ElapsedMs IS NOT NULL
                   THEN 'PARSED' ELSE 'PARSED_PARTIAL' END
            , LEFT(@Line,4000)
        );
    END;

    RETURN;
END;
GO
