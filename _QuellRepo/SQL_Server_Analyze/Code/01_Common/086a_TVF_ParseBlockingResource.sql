USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_ParseBlockingResource
Version      : 1.0.0
Stand        : 2026-07-20
Typ          : Multi-statement Table-valued Function
Zweck        : Zerlegt die von Requests und Waiting Tasks gelieferten
               Blocking-Ressourcen ohne Katalog- oder DMV-Zugriff. Die Funktion
               liefert ausschließlich syntaktische IDs und bewahrt den Rohwert.
SQL-Version  : SQL Server 2019 oder neuer.
Eigenlast    : Sehr gering; maximal vier numerische Bestandteile werden gelesen.
Hinweis      : Namen werden bewusst erst vom aufrufenden Modul für die bereits
               begrenzte und deduplizierte Kandidatenmenge aufgelöst.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_ParseBlockingResource]
(
    @WaitResource nvarchar(3072)
)
RETURNS @Result TABLE
(
      [RawResource]       nvarchar(3072) NULL
    , [ResourceType]      nvarchar(60)   NULL
    , [FormatCode]        varchar(40)    NOT NULL
    , [DatabaseId]        int            NULL
    , [EntityId]          bigint         NULL
    , [SubEntityId]       bigint         NULL
    , [FileId]            int            NULL
    , [PageId]            bigint         NULL
    , [RowId]             int            NULL
    , [MetadataSubtype]   nvarchar(60)   NULL
    , [ResourceQualifier] nvarchar(512)  NULL
    , [ParseStatus]       varchar(40)    NOT NULL
)
AS
BEGIN
    DECLARE @Raw nvarchar(3072) = NULLIF(LTRIM(RTRIM(@WaitResource)), N'');

    IF @Raw IS NULL
    BEGIN
        INSERT @Result ([RawResource], [FormatCode], [ParseStatus])
        VALUES (@WaitResource, 'EMPTY', 'EMPTY');
        RETURN;
    END;

    DECLARE @Upper nvarchar(3072) = UPPER(@Raw);
    DECLARE @Compact nvarchar(3072) = REPLACE(@Upper, N' ', N'');
    DECLARE @ResourceType nvarchar(60) = NULL;
    DECLARE @FormatCode varchar(40) = 'PREFIXED';
    DECLARE @DatabaseId int = NULL;
    DECLARE @EntityId bigint = NULL;
    DECLARE @SubEntityId bigint = NULL;
    DECLARE @FileId int = NULL;
    DECLARE @PageId bigint = NULL;
    DECLARE @RowId int = NULL;
    DECLARE @MetadataSubtype nvarchar(60) = NULL;
    DECLARE @Qualifier nvarchar(512) = NULL;
    DECLARE @ParseStatus varchar(40) = 'UNRECOGNIZED';
    DECLARE @Start int;
    DECLARE @NumericSegment nvarchar(128);
    DECLARE @NumericSegmentLength int;

    IF LEFT(@Compact, 9) = N'METADATA:'
    BEGIN
        SET @ResourceType = N'METADATA';
        SET @FormatCode = 'METADATA';
        SET @MetadataSubtype =
            CASE WHEN CHARINDEX(N'STATS(', @Compact) > 0 THEN N'STATS'
                 WHEN CHARINDEX(N'SCHEMA(', @Compact) > 0 THEN N'SCHEMA'
                 WHEN CHARINDEX(N'AUDIT(', @Compact) > 0 THEN N'AUDIT'
                 WHEN CHARINDEX(N'SECURITY_CACHE(', @Compact) > 0 THEN N'SECURITY_CACHE'
                 WHEN CHARINDEX(N'METADATA_CACHE(', @Compact) > 0 THEN N'METADATA_CACHE'
                 WHEN CHARINDEX(N'QDS_STATEMENT_STABILITY(', @Compact) > 0 THEN N'QDS_STATEMENT_STABILITY'
                 ELSE N'OTHER' END;

        SET @Start = CHARINDEX(N'DATABASE_ID=', @Compact);
        IF @Start > 0
        BEGIN
            SET @NumericSegment = SUBSTRING(@Compact, @Start + LEN(N'DATABASE_ID='), 128);
            SET @NumericSegmentLength = PATINDEX(N'%[^0-9]%', @NumericSegment + N'X') - 1;
            SET @DatabaseId = TRY_CONVERT(int, LEFT(@NumericSegment, @NumericSegmentLength));
        END;

        IF @MetadataSubtype = N'STATS'
        BEGIN
            SET @Start = CHARINDEX(N'OBJECT_ID=', @Compact);
            IF @Start > 0
            BEGIN
                SET @NumericSegment = SUBSTRING(@Compact, @Start + LEN(N'OBJECT_ID='), 128);
                SET @NumericSegmentLength = PATINDEX(N'%[^0-9]%', @NumericSegment + N'X') - 1;
                SET @EntityId = TRY_CONVERT(bigint, LEFT(@NumericSegment, @NumericSegmentLength));
            END;

            SET @Start = CHARINDEX(N'STATS_ID=', @Compact);
            IF @Start > 0
            BEGIN
                SET @NumericSegment = SUBSTRING(@Compact, @Start + LEN(N'STATS_ID='), 128);
                SET @NumericSegmentLength = PATINDEX(N'%[^0-9]%', @NumericSegment + N'X') - 1;
                SET @SubEntityId = TRY_CONVERT(bigint, LEFT(@NumericSegment, @NumericSegmentLength));
            END;
        END;
        ELSE IF @MetadataSubtype = N'SCHEMA'
        BEGIN
            SET @Start = CHARINDEX(N'SCHEMA_ID=', @Compact);
            IF @Start > 0
            BEGIN
                SET @NumericSegment = SUBSTRING(@Compact, @Start + LEN(N'SCHEMA_ID='), 128);
                SET @NumericSegmentLength = PATINDEX(N'%[^0-9]%', @NumericSegment + N'X') - 1;
                SET @EntityId = TRY_CONVERT(bigint, LEFT(@NumericSegment, @NumericSegmentLength));
            END;
        END;
        ELSE IF @MetadataSubtype = N'AUDIT'
        BEGIN
            SET @Start = CHARINDEX(N'AUDIT_ID=', @Compact);
            IF @Start > 0
            BEGIN
                SET @NumericSegment = SUBSTRING(@Compact, @Start + LEN(N'AUDIT_ID='), 128);
                SET @NumericSegmentLength = PATINDEX(N'%[^0-9]%', @NumericSegment + N'X') - 1;
                SET @EntityId = TRY_CONVERT(bigint, LEFT(@NumericSegment, @NumericSegmentLength));
            END;
        END;

        SET @Qualifier = LEFT(@Raw, 512);
        SET @ParseStatus = CASE WHEN @DatabaseId IS NULL THEN 'PARTIAL' ELSE 'PARSED' END;
    END;
    ELSE
    BEGIN
        DECLARE @Payload nvarchar(3072);
        DECLARE @FirstColon int = CHARINDEX(N':', @Raw);

        IF TRY_CONVERT(int, LEFT(@Raw, 1)) IS NOT NULL
        BEGIN
            SET @ResourceType = N'PAGE';
            SET @FormatCode = 'NUMERIC_PAGE';
            SET @Payload = @Raw;
        END;
        ELSE IF @FirstColon > 0
        BEGIN
            SET @ResourceType = LEFT(UPPER(LTRIM(RTRIM(LEFT(@Raw, @FirstColon - 1)))), 60);
            SET @Payload = LTRIM(SUBSTRING(@Raw, @FirstColon + 1, 3072));
        END;
        ELSE
        BEGIN
            DECLARE @NameEnd int = NULLIF(CHARINDEX(N' ', @Raw + N' '), 0);
            DECLARE @Paren int = NULLIF(CHARINDEX(N'(', @Raw), 0);
            IF @Paren IS NOT NULL AND (@NameEnd IS NULL OR @Paren < @NameEnd)
                SET @NameEnd = @Paren;

            SET @ResourceType = LEFT(UPPER(LEFT(@Raw, COALESCE(@NameEnd - 1, LEN(@Raw)))), 60);
            SET @FormatCode = 'NAMED_RESOURCE';
            SET @Qualifier = LEFT(@Raw, 512);
            SET @ParseStatus = 'RAW_ONLY';
        END;

        IF @Payload IS NOT NULL
        BEGIN
            DECLARE @Parts TABLE
            (
                  [Ordinal] int NOT NULL PRIMARY KEY
                , [Value] nvarchar(128) NULL
            );
            DECLARE @Ordinal int = 1;
            DECLARE @Colon int;
            DECLARE @Space int;
            DECLARE @OpenParen int;
            DECLARE @OpenBracket int;
            DECLARE @End int;

            WHILE @Ordinal <= 4 AND NULLIF(LTRIM(@Payload), N'') IS NOT NULL
            BEGIN
                SET @Payload = LTRIM(@Payload);
                SET @Colon = NULLIF(CHARINDEX(N':', @Payload), 0);
                SET @Space = NULLIF(CHARINDEX(N' ', @Payload), 0);
                SET @OpenParen = NULLIF(CHARINDEX(N'(', @Payload), 0);
                SET @OpenBracket = NULLIF(CHARINDEX(N'[', @Payload), 0);

                SELECT @End = MIN([Position])
                FROM (VALUES (@Colon), (@Space), (@OpenParen), (@OpenBracket)) AS [d]([Position])
                WHERE [Position] IS NOT NULL;

                INSERT @Parts ([Ordinal], [Value])
                VALUES
                (
                      @Ordinal
                    , NULLIF(LTRIM(RTRIM(CASE WHEN @End IS NULL THEN @Payload
                                               ELSE LEFT(@Payload, @End - 1) END)), N'')
                );

                IF @End IS NULL
                    SET @Payload = N'';
                ELSE IF @Colon = @End
                    SET @Payload = SUBSTRING(@Payload, @End + 1, 3072);
                ELSE
                BEGIN
                    SET @Qualifier = LEFT(LTRIM(SUBSTRING(@Payload, @End, 3072)), 512);
                    SET @Payload = N'';
                END;

                SET @Ordinal += 1;
            END;

            DECLARE @Part1 nvarchar(128) = (SELECT [Value] FROM @Parts WHERE [Ordinal] = 1);
            DECLARE @Part2 nvarchar(128) = (SELECT [Value] FROM @Parts WHERE [Ordinal] = 2);
            DECLARE @Part3 nvarchar(128) = (SELECT [Value] FROM @Parts WHERE [Ordinal] = 3);
            DECLARE @Part4 nvarchar(128) = (SELECT [Value] FROM @Parts WHERE [Ordinal] = 4);

            IF @ResourceType IN
               (
                   N'OBJECT', N'KEY', N'HOBT', N'OIB', N'ALLOCATION_UNIT',
                   N'DATABASE', N'FILE', N'PAGE', N'RID', N'EXTENT',
                   N'APPLICATION', N'XACT'
               )
            BEGIN
                SET @DatabaseId = TRY_CONVERT(int, @Part1);
                SET @EntityId = CASE WHEN @ResourceType IN (N'OBJECT', N'KEY', N'HOBT', N'OIB', N'ALLOCATION_UNIT')
                                     THEN TRY_CONVERT(bigint, @Part2) END;
                SET @SubEntityId = CASE WHEN @ResourceType = N'OBJECT'
                                        THEN TRY_CONVERT(bigint, @Part3) END;
                SET @FileId = CASE WHEN @ResourceType IN (N'FILE', N'PAGE', N'RID', N'EXTENT')
                                   THEN TRY_CONVERT(int, @Part2) END;
                SET @PageId = CASE WHEN @ResourceType IN (N'PAGE', N'RID', N'EXTENT')
                                   THEN TRY_CONVERT(bigint, @Part3) END;
                SET @RowId = CASE WHEN @ResourceType = N'RID'
                                  THEN TRY_CONVERT(int, @Part4) END;
                IF @ResourceType IN (N'APPLICATION', N'XACT')
                    SET @Qualifier = LEFT(LTRIM(SUBSTRING(@Raw, CHARINDEX(N':', @Raw) + 1, 3072)), 512);
                SET @ParseStatus =
                    CASE WHEN @DatabaseId IS NULL THEN 'INVALID_FORMAT'
                         WHEN @ResourceType IN (N'OBJECT', N'KEY', N'HOBT', N'OIB', N'ALLOCATION_UNIT')
                              AND @EntityId IS NULL THEN 'INVALID_FORMAT'
                         WHEN @ResourceType IN (N'PAGE', N'RID', N'EXTENT')
                              AND (@FileId IS NULL OR @PageId IS NULL) THEN 'INVALID_FORMAT'
                         WHEN @ResourceType = N'FILE' AND @FileId IS NULL THEN 'PARTIAL'
                         WHEN @ResourceType IN (N'APPLICATION', N'XACT') THEN 'PARTIAL'
                         ELSE 'PARSED' END;
            END;
            ELSE
            BEGIN
                SET @Qualifier = LEFT(COALESCE(@Qualifier, @Raw), 512);
                SET @ParseStatus = 'RAW_ONLY';
            END;
        END;
    END;

    INSERT @Result
    (
          [RawResource], [ResourceType], [FormatCode], [DatabaseId]
        , [EntityId], [SubEntityId], [FileId], [PageId], [RowId]
        , [MetadataSubtype], [ResourceQualifier], [ParseStatus]
    )
    VALUES
    (
          @Raw, @ResourceType, @FormatCode, @DatabaseId
        , @EntityId, @SubEntityId, @FileId, @PageId, @RowId
        , @MetadataSubtype, @Qualifier, @ParseStatus
    );

    RETURN;
END;
GO
