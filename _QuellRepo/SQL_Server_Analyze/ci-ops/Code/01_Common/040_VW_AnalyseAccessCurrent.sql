USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.VW_AnalyseAccessCurrent
Version      : 1.0.0
Stand        : 2026-07-14
Typ          : View
Zweck        : Ermittelt den effektiven Zugriff des aktuellen Logins auf jede
               Analyseklasse.
Priorität    : 1. ungeschützte Klasse, 2. sysadmin-Bypass, 3. offene Policy bei
               null aktiven Regeln, 4. Match über sys.login_token, 5. IS_MEMBER.
Parameter    : Keine.
Resultset    : Login-/Policy-/Matchinformationen und IsAllowed je Analyseklasse.
Berechtigung : Benötigt Lesbarkeit der Framework-Views und der für den aktuellen
               Login verfügbaren Tokeninformationen. Keine Rechtevergabe.
Eigenlast    : Sehr gering; liest nur kleine konstante Views, sys.login_token
               und führt IS_MEMBER ausschließlich für aktive Policyzeilen aus.
Locking      : Keine Benutzerobjekte; keine persistierenden Schreibzugriffe.
Hinweis      : AD-Tokenänderungen werden erst bei einer neuen Anmeldung sicher
               sichtbar. IS_MEMBER liefert bei SQL Logins typischerweise NULL.
Aufruf       : SELECT * FROM monitor.VW_AnalyseAccessCurrent;
Änderungen   : 1.0.0 - Erstfassung Phase 1A.
===============================================================================
*/
CREATE OR ALTER VIEW [monitor].[VW_AnalyseAccessCurrent]
AS
    WITH ActivePolicy AS
    (
        SELECT
            [p].[AnalysisClass],
            [p].[ADGroupName],
            [p].[Priority]
        FROM [monitor].[VW_AnalyseAccessPolicy] AS [p]
        WHERE [p].[IsEnabled] = 1
          AND ([p].[ValidFromUtc] IS NULL OR [p].[ValidFromUtc] <= SYSUTCDATETIME())
          AND ([p].[ValidToUtc]   IS NULL OR [p].[ValidToUtc]   >  SYSUTCDATETIME())
          AND NULLIF(LTRIM(RTRIM([p].[AnalysisClass])), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM([p].[ADGroupName])), '') IS NOT NULL
    ),
    PolicyState AS
    (
        SELECT COUNT_BIG(*) AS [ActivePolicyCount]
        FROM [ActivePolicy]
    ),
    LoginTokenMatches AS
    (
        SELECT DISTINCT
            [p].[AnalysisClass],
            [p].[ADGroupName]
        FROM [ActivePolicy] AS [p]
        INNER JOIN [sys].[login_token] AS [lt] WITH (NOLOCK)
            ON UPPER(CONVERT(nvarchar(256), [lt].[name])) COLLATE Latin1_General_100_CI_AS
             = UPPER([p].[ADGroupName]) COLLATE Latin1_General_100_CI_AS
        WHERE [lt].[type] = N'WINDOWS GROUP'
    ),
    IsMemberMatches AS
    (
        SELECT DISTINCT
            [p].[AnalysisClass],
            [p].[ADGroupName]
        FROM [ActivePolicy] AS [p]
        WHERE IS_MEMBER([p].[ADGroupName]) = 1
    ),
    MatchRollup AS
    (
        SELECT
            [m].[AnalysisClass],
            COUNT_BIG(*) AS [MatchCount],
            MAX(CASE WHEN [m].[MatchSource] = 'LOGIN_TOKEN' THEN 1 ELSE 0 END) AS [HasLoginTokenMatch],
            MAX(CASE WHEN [m].[MatchSource] = 'IS_MEMBER'   THEN 1 ELSE 0 END) AS [HasIsMemberMatch]
        FROM
        (
            SELECT [ltm].[AnalysisClass], [ltm].[ADGroupName], CAST('LOGIN_TOKEN' AS varchar(20)) AS [MatchSource]
            FROM [LoginTokenMatches] AS [ltm]
            UNION ALL
            SELECT [imm].[AnalysisClass], [imm].[ADGroupName], CAST('IS_MEMBER' AS varchar(20)) AS [MatchSource]
            FROM [IsMemberMatches] AS [imm]
            WHERE NOT EXISTS
            (
                SELECT 1
                FROM [LoginTokenMatches] AS [ltm]
                WHERE [ltm].[AnalysisClass] = [imm].[AnalysisClass]
                  AND UPPER([ltm].[ADGroupName]) COLLATE Latin1_General_100_CI_AS
                    = UPPER([imm].[ADGroupName]) COLLATE Latin1_General_100_CI_AS
            )
        ) AS [m]
        GROUP BY [m].[AnalysisClass]
    )
    SELECT
        [c].[AnalysisClass],
        [c].[AnalysisLevel],
        [c].[RequiresGroupGate],
        ORIGINAL_LOGIN() AS [OriginalLoginName],
        SUSER_SNAME() AS [EffectiveLoginName],
        CAST(CASE WHEN IS_SRVROLEMEMBER(N'sysadmin') = 1 THEN 1 ELSE 0 END AS bit) AS [IsSysadmin],
        [ps].[ActivePolicyCount],
        CAST
        (
            (
                SELECT COUNT_BIG(*)
                FROM [ActivePolicy] AS [p]
                WHERE [p].[AnalysisClass] IN ([c].[AnalysisClass], '*')
            ) AS bigint
        ) AS [RelevantPolicyCount],
        CAST
        (
            CASE
                WHEN [c].[RequiresGroupGate] = 0 THEN 1
                WHEN IS_SRVROLEMEMBER(N'sysadmin') = 1 THEN 1
                WHEN [ps].[ActivePolicyCount] = 0 THEN 1
                WHEN EXISTS
                (
                    SELECT 1
                    FROM [MatchRollup] AS [mr]
                    WHERE [mr].[AnalysisClass] IN ([c].[AnalysisClass], '*')
                      AND [mr].[MatchCount] > 0
                ) THEN 1
                ELSE 0
            END
            AS bit
        ) AS [IsAllowed],
        CAST
        (
            CASE
                WHEN [c].[RequiresGroupGate] = 0 THEN 'NOT_REQUIRED'
                WHEN IS_SRVROLEMEMBER(N'sysadmin') = 1 THEN 'SYSADMIN'
                WHEN [ps].[ActivePolicyCount] = 0 THEN 'OPEN_POLICY'
                WHEN EXISTS
                (
                    SELECT 1
                    FROM [MatchRollup] AS [mr]
                    WHERE [mr].[AnalysisClass] IN ([c].[AnalysisClass], '*')
                      AND [mr].[HasLoginTokenMatch] = 1
                ) THEN 'LOGIN_TOKEN'
                WHEN EXISTS
                (
                    SELECT 1
                    FROM [MatchRollup] AS [mr]
                    WHERE [mr].[AnalysisClass] IN ([c].[AnalysisClass], '*')
                      AND [mr].[HasIsMemberMatch] = 1
                ) THEN 'IS_MEMBER'
                ELSE 'NO_MATCH'
            END
            AS varchar(20)
        ) AS [AccessReason],
        CAST
        (
            COALESCE
            (
                (
                    SELECT SUM([mr].[MatchCount])
                    FROM [MatchRollup] AS [mr]
                    WHERE [mr].[AnalysisClass] IN ([c].[AnalysisClass], '*')
                ),
                0
            ) AS bigint
        ) AS [MatchedGroupCount]
    FROM [monitor].[VW_AnalyseClassCatalog] AS [c]
    CROSS JOIN [PolicyState] AS [ps];
GO
