:ON ERROR EXIT

USE [DeineDatenbank];
GO

/*
SQLCMD-Teilinstaller für die eigenständig nutzbare Execution-Plan-Analyse.
Er installiert ausschließlich das Schema, die interne High-Impact-/Gruppenprüfung, die drei allgemeinen Ausgabehelper
und die für PLAN-001 benötigten Plananalyseobjekte. Er installiert weder die
übrigen Plan-Cache- noch Query-Store-, Current-State- oder Server-Health-Module.
*/

:r ../00_Setup/000_Preflight_und_Schema.sql
:r ../01_Common/020_VW_AnalyseClassCatalog.sql
:r ../01_Common/030_VW_AnalyseAccessPolicy.sql
:r ../01_Common/040_VW_AnalyseAccessCurrent.sql
:r ../01_Common/078_TVF_ParsePipeList.sql
:r ../01_Common/085_TVF_ParseBigintList.sql
:r ../01_Common/083a_USP_InternalCheckAnalysisPath.sql
:r ../01_Common/095_USP_InternalWriteResultTable.sql
:r ../01_Common/096_USP_InternalPrepareResultTables.sql
:r ../01_Common/098_USP_InternalEmitConsoleResult.sql
:r ../04_PlanCache/041_PlanAnalysisProfile.sql
:r ../04_PlanCache/042_PlanAnalysisRuleThreshold.sql
:r ../04_PlanCache/043_PlanAnalysisProfileAssignment.sql
:r ../04_PlanCache/044_TVF_ParseStatisticsIoText.sql
:r ../04_PlanCache/045_TVF_ParseStatisticsTimeText.sql
:r ../04_PlanCache/046_TVF_ExecutionPlanObjectReferences.sql
:r ../04_PlanCache/047_TVF_ExecutionPlanStatisticsUsage.sql
:r ../04_PlanCache/048_TVF_ExecutionPlanColumnReferences.sql
:r ../04_PlanCache/049_InternalCollectExecutionPlanMetadata.sql
:r ../04_PlanCache/051_InternalAnalyzeExecutionPlan.sql
:r ../04_PlanCache/052_USP_CreateExecutionEvidenceJson.sql
:r ../04_PlanCache/053_USP_ExecutionPlanAnalysis.sql
