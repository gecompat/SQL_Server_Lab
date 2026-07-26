-- ============================================================================
-- PostProvision: ML Services Demo-Setup
-- Validiert External Scripts und erstellt Demo-Objekte
-- ============================================================================

USE MLWorkspace;
GO

-- 1. Validierung: External Scripts aktiv?
EXEC sp_execute_external_script
    @language = N'Python',
    @script = N'
import sys
import pandas
OutputDataSet = pandas.DataFrame({"Version": [sys.version], "Pandas": [pandas.__version__]})
',
    @output_data_1_name = N'OutputDataSet'
WITH RESULT SETS ((PythonVersion NVARCHAR(200), PandasVersion NVARCHAR(50)));
GO

-- 2. R-Validierung
EXEC sp_execute_external_script
    @language = N'R',
    @script = N'
OutputDataSet <- data.frame(Version = R.version.string, Platform = R.version$platform)
',
    @output_data_1_name = N'OutputDataSet'
WITH RESULT SETS ((RVersion NVARCHAR(200), Platform NVARCHAR(100)));
GO

-- 3. Demo-Tabelle fuer ML-Predictions
CREATE TABLE dbo.MLPredictions (
    PredictionId    INT IDENTITY(1,1) PRIMARY KEY,
    ModelName       NVARCHAR(100) NOT NULL,
    InputData       NVARCHAR(MAX),
    Prediction      FLOAT,
    Confidence      FLOAT,
    CreatedAt       DATETIME2 DEFAULT GETDATE()
);
GO

-- 4. Demo: Python-basierte Regression auf AdventureWorks-Daten
-- (Zeigt Integration von ML in T-SQL Queries)
CREATE OR ALTER PROCEDURE dbo.usp_PredictSalesAmount
    @ProductCategory NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    EXEC sp_execute_external_script
        @language = N'Python',
        @script = N'
from sklearn.linear_model import LinearRegression
import numpy as np

# Einfaches Demo-Modell
X = InputDataSet[["ListPrice"]].values
y = InputDataSet["LineTotal"].values

if len(X) > 10:
    model = LinearRegression()
    model.fit(X, y)
    InputDataSet["Prediction"] = model.predict(X)
    InputDataSet["Confidence"] = model.score(X, y)
else:
    InputDataSet["Prediction"] = 0
    InputDataSet["Confidence"] = 0

OutputDataSet = InputDataSet[["ProductName", "ListPrice", "LineTotal", "Prediction", "Confidence"]]
',
        @input_data_1 = N'
            SELECT TOP 1000
                p.Name AS ProductName,
                p.ListPrice,
                sod.LineTotal
            FROM AdventureWorks2022.Sales.SalesOrderDetail sod
            JOIN AdventureWorks2022.Production.Product p ON p.ProductID = sod.ProductID
            JOIN AdventureWorks2022.Production.ProductSubcategory psc ON psc.ProductSubcategoryID = p.ProductSubcategoryID
            JOIN AdventureWorks2022.Production.ProductCategory pc ON pc.ProductCategoryID = psc.ProductCategoryID
            WHERE pc.Name = @cat
        ',
        @input_data_1_name = N'InputDataSet',
        @output_data_1_name = N'OutputDataSet',
        @params = N'@cat NVARCHAR(50)',
        @cat = @ProductCategory
    WITH RESULT SETS ((
        ProductName NVARCHAR(100),
        ListPrice MONEY,
        LineTotal MONEY,
        Prediction FLOAT,
        Confidence FLOAT
    ));
END;
GO

-- 5. Demo: R-basierte Zeitreihenanalyse
CREATE OR ALTER PROCEDURE dbo.usp_ForecastSales
    @MonthsAhead INT = 6
AS
BEGIN
    SET NOCOUNT ON;

    EXEC sp_execute_external_script
        @language = N'R',
        @script = N'
library(forecast)

ts_data <- ts(InputDataSet$MonthlySales, frequency=12)
fit <- auto.arima(ts_data)
fc <- forecast(fit, h=months_ahead)

OutputDataSet <- data.frame(
    Period = seq_len(months_ahead),
    Forecast = as.numeric(fc$mean),
    Lower95 = as.numeric(fc$lower[,2]),
    Upper95 = as.numeric(fc$upper[,2])
)
',
        @input_data_1 = N'
            SELECT
                CAST(SUM(soh.SubTotal) AS FLOAT) AS MonthlySales
            FROM AdventureWorks2022.Sales.SalesOrderHeader soh
            GROUP BY YEAR(soh.OrderDate), MONTH(soh.OrderDate)
            ORDER BY YEAR(soh.OrderDate), MONTH(soh.OrderDate)
        ',
        @input_data_1_name = N'InputDataSet',
        @output_data_1_name = N'OutputDataSet',
        @params = N'@months_ahead INT',
        @months_ahead = @MonthsAhead
    WITH RESULT SETS ((
        Period INT,
        Forecast FLOAT,
        Lower95 FLOAT,
        Upper95 FLOAT
    ));
END;
GO

PRINT 'ML Services Demo-Setup abgeschlossen.';
PRINT 'Testen mit: EXEC dbo.usp_PredictSalesAmount ''Bikes''';
PRINT '            EXEC dbo.usp_ForecastSales @MonthsAhead = 12';
GO
