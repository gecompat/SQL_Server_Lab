USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.InternalParseXmlText
Version      : 1.0.0
Stand        : 2026-07-21
Typ          : Interne Stored Procedure
Zweck        : Konvertiert einen vollständigen nvarchar(max)-Quellwert ohne
               vorherige Kürzung in natives xml und klassifiziert Ausfälle.
Resultsets   : Keine; ausschließlich OUTPUT-Parameter.
Grenze       : Die aufrufende Procedure materialisiert den Quelltext genau
               einmal und entscheidet, ob ein Textfallback exportiert wird.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[InternalParseXmlText]
      @XmlText       nvarchar(max)
    , @XmlValue      xml            = NULL OUTPUT
    , @StatusCode    varchar(40)    = NULL OUTPUT
    , @ErrorNumber   int            = NULL OUTPUT
    , @ErrorMessage  nvarchar(2048) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;

    SELECT @XmlValue=NULL,@ErrorNumber=NULL,@ErrorMessage=NULL,
           @StatusCode=CASE WHEN @XmlText IS NULL THEN 'SOURCE_NULL' ELSE 'PENDING' END;

    IF @XmlText IS NULL RETURN;

    BEGIN TRY
        SET @XmlValue=CONVERT(xml,@XmlText);
        SET @StatusCode=CASE
            WHEN NULLIF(LTRIM(RTRIM(@XmlText)),N'') IS NULL THEN 'XML_EMPTY'
            ELSE 'AVAILABLE' END;
    END TRY
    BEGIN CATCH
        SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),
               @StatusCode=CASE
                   WHEN ERROR_NUMBER() IN(6335,6336,6337) THEN 'XML_UNAVAILABLE_LIMIT'
                   ELSE 'XML_INVALID' END;
    END CATCH;
END;
GO
