#!/usr/bin/env python3
"""Validate the Analysis Navigator metadata, discovery and documentation contract."""

from __future__ import annotations

import argparse
import csv
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path


CATALOG_PATH = Path("Code/01_Common/021_VW_AnalysisCatalog.sql")
SEARCH_TERM_PATH = Path("Code/01_Common/022_VW_AnalysisSearchTerm.sql")
RELATION_PATH = Path("Code/01_Common/023_VW_AnalysisRelation.sql")
NAVIGATOR_PATH = Path("Code/01_Common/100_USP_AnalysisNavigator.sql")
ANALYSIS_CLASS_PATH = Path("Code/01_Common/020_VW_AnalyseClassCatalog.sql")
OBJECT_INVENTORY_PATH = Path("Metadata/Inventory/Objects.csv")
PARAMETER_INVENTORY_PATH = Path("Metadata/Inventory/Parameters.csv")
RESULT_SET_INVENTORY_PATH = Path("Metadata/Inventory/ResultSets.csv")
INSTALLER_PATH = Path("Code/Install/Install_All.sql")
PLAN_INSTALLER_PATH = Path("Code/Install/Install_ExecutionPlanAnalysis.sql")

CATALOG_COLUMNS = (
    "ProcedureName",
    "DisplayName",
    "PrimaryAreaCode",
    "PrimaryAreaName",
    "NavigationRole",
    "ScopeCode",
    "EvidenceType",
    "CostRangeCode",
    "RepresentativeAnalysisClass",
    "RequiresKnownTarget",
    "RequiresHighImpactForSafeStart",
    "HighImpactPathAvailable",
    "PackageCode",
    "DefaultRank",
    "Purpose",
    "PrerequisiteSummary",
    "SafeCall",
    "DocumentationPath",
    "RunbookPath",
)

SEARCH_TERM_COLUMNS = (
    "ProcedureName",
    "SearchTerm",
    "LanguageCode",
    "SearchWeight",
    "MatchReason",
)

RELATION_COLUMNS = (
    "FromProcedureName",
    "RelationType",
    "ToProcedureName",
    "RelationPriority",
    "ConditionSummary",
)

ALLOWED_ROLES = {"ENTRY", "FOLLOW_UP", "TARGETED", "SETUP", "SUPPORT"}
ALLOWED_PACKAGES = {"CORE", "CORE_PLAN_STANDALONE", "SNAPSHOT_OPTIONAL"}
ALLOWED_AREAS = {
    "NAVIGATION",
    "FRAMEWORK",
    "LIVE",
    "OBJECT",
    "PLAN",
    "QUERY_STORE",
    "EXTENDED_EVENTS",
    "OPERATIONS",
    "SERVER",
    "SPECIAL_FEATURE",
    "SNAPSHOT",
}
ALLOWED_SCOPES = {
    "FRAMEWORK",
    "SERVER",
    "DATABASE",
    "MULTI_DATABASE",
    "SESSION_REQUEST",
    "OBJECT",
    "QUERY",
    "PLAN_XML",
    "EVENT_SESSION",
    "EVENT_HISTORY",
    "INFRASTRUCTURE",
    "SNAPSHOT_TARGET",
}
ALLOWED_EVIDENCE_TYPES = {
    "FRAMEWORK_METADATA",
    "LIVE_SNAPSHOT",
    "SAMPLE_DELTA",
    "CUMULATIVE_DMV",
    "PERSISTED_HISTORY",
    "EVENT_HISTORY",
    "CATALOG_CONFIGURATION",
    "STATIC_INPUT",
    "MIXED",
    "PERSISTED_SNAPSHOT",
}
ALLOWED_COST_RANGES = {
    "LOW",
    "LOW_MEDIUM",
    "MEDIUM",
    "LOW_HIGH_OPT_IN",
    "MEDIUM_HIGH_OPT_IN",
    "HIGH_OPT_IN",
}
ALLOWED_RELATIONS = {"REFINE_WITH", "CONFIRM_WITH", "ALTERNATIVE_TO", "PREPARE_WITH"}
RELATION_EXEMPT_PROCEDURES = {
    "USP_AnalysisNavigator",
    "USP_PrepareDatabaseCandidates",
    "USP_PrepareNameFilters",
}
HIGH_IMPACT_SAFE_ENTRY_PROCEDURES = {
    "USP_DataCaptureDeepAnalysis",
    "USP_ExtendedEventsBlockedProcesses",
    "USP_ExtendedEventsDeadlocks",
    "USP_ExtendedEventsReadEvents",
    "USP_ExtendedEventsTargetRuntime",
    "USP_FullTextAnalysis",
    "USP_IndexPhysicalStats",
    "USP_IntelligentQueryProcessingAnalysis",
    "USP_PlanDetails",
    "USP_PlanCacheAnalysis",
    "USP_QueryHashAnalysis",
    "USP_SchemaDesignAnalysis",
    "USP_ServiceBrokerAnalysis",
    "USP_StatisticsDistributionAnalysis",
    "USP_TemporalAnalysis",
}

EXPECTED_SEARCH_CASES = {
    "Benutzer warten": "USP_CurrentBlocking",
    "CPU hoch": "USP_CurrentRequests",
    "TempDB wächst": "USP_CurrentTempDB",
    "Log voll": "USP_CurrentLog",
    "Query plötzlich langsamer": "USP_QueryStoreRegressions",
    "Plan XML analysieren": "USP_ExecutionPlanAnalysis",
    "Index ungenutzt": "USP_IndexUsage",
    "AG Lag Redo Queue Send Queue": "USP_AvailabilityDeepAnalysis",
    "Deadlock": "USP_ExtendedEventsDeadlocks",
    "SQL Server Version CU Lifecycle": "USP_ServerVersionInformation",
    "JSON-Index Pfade inventarisieren": "USP_ObjectInventory",
    "JSON-Index Capability Preview": "USP_ServerFeatureCapabilities",
    "TempDB Workload Group Limit Verletzung": "USP_CurrentTempDB",
    "TempDB Resource Governance Wirksamkeit": "USP_ResourceGovernorAnalysis",
    "lesbare Secondary Statistik Replikat Herkunft": "USP_Statistics",
}

PUBLIC_DOCUMENTATION_FORBIDDEN = (
    re.compile(r"AI_Metadata", re.IGNORECASE),
    re.compile(r"Internal_Documentation", re.IGNORECASE),
    re.compile(r"Documentation/(?:Research|Development|Requirements)/", re.IGNORECASE),
    re.compile(r"Analysis_Guides/Authoring", re.IGNORECASE),
    re.compile(r"\bChatGPT\b", re.IGNORECASE),
    re.compile(r"(?<![A-Za-zÄÖÜäöüß])KI(?![A-Za-zÄÖÜäöüß])"),
    re.compile(r"\bEntstehungsnachweis\b", re.IGNORECASE),
    re.compile(r"\bImplementierungswelle\b", re.IGNORECASE),
    re.compile(r"\bImplementierungsweg\b", re.IGNORECASE),
    re.compile(r"\bRedaktions(?:prozess|hinweis|status)\b", re.IGNORECASE),
    re.compile(r"\b[0-9a-f]{40}\b", re.IGNORECASE),
    re.compile(r"\bMigrationsumfang\b", re.IGNORECASE),
    re.compile(r"\bReihenfolge der Einführung\b", re.IGNORECASE),
    re.compile(r"\bvor Beginn der Migration\b", re.IGNORECASE),
)


def normalize_ci_ai(value: str) -> str:
    decomposed = unicodedata.normalize("NFKD", value)
    without_accents = "".join(char for char in decomposed if not unicodedata.combining(char))
    return re.sub(r"\s+", " ", without_accents.casefold().strip())


def split_top_level(text: str, delimiter: str = ",") -> list[str]:
    values: list[str] = []
    start = 0
    depth = 0
    in_string = False
    index = 0
    while index < len(text):
        char = text[index]
        if in_string:
            if char == "'":
                if index + 1 < len(text) and text[index + 1] == "'":
                    index += 2
                    continue
                in_string = False
        elif char == "'":
            in_string = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == delimiter and depth == 0:
            values.append(text[start:index].strip())
            start = index + 1
        index += 1
    values.append(text[start:].strip())
    return values


def decode_sql_value(value_expression: str) -> str | int | None:
    value_expression = value_expression.strip()
    if value_expression.upper() == "NULL":
        return None
    if re.fullmatch(r"-?[0-9]+", value_expression):
        return int(value_expression)

    cast_match = re.fullmatch(
        r"CAST\s*\(\s*(N?'(?:''|[^'])*)'\s+AS\s+[^)]+\)",
        value_expression,
        re.IGNORECASE | re.DOTALL,
    )
    if cast_match:
        value_expression = cast_match.group(1) + "'"

    string_match = re.fullmatch(r"N?'((?:''|[^'])*)'", value_expression, re.DOTALL)
    if string_match:
        return string_match.group(1).replace("''", "'")
    raise ValueError(f"Unsupported SQL VALUES scalar: {value_expression!r}")


def extract_values_rows(sql_text: str, columns: tuple[str, ...]) -> list[dict[str, str | int | None]]:
    marker = re.search(r"\bFROM\s*\(\s*VALUES\s*", sql_text, re.IGNORECASE | re.DOTALL)
    if not marker:
        raise ValueError("VALUES block marker not found")
    suffix = re.search(r"\)\s+AS\s+\[v\]\s*\(", sql_text[marker.end() :], re.IGNORECASE)
    if not suffix:
        raise ValueError("VALUES block suffix not found")
    block = sql_text[marker.end() : marker.end() + suffix.start()]

    raw_rows: list[str] = []
    index = 0
    while index < len(block):
        while index < len(block) and (block[index].isspace() or block[index] == ","):
            index += 1
        if index >= len(block):
            break
        if block[index] != "(":
            raise ValueError(f"Unexpected character before VALUES row: {block[index:index + 30]!r}")
        row_start = index + 1
        depth = 1
        in_string = False
        index += 1
        while index < len(block) and depth:
            char = block[index]
            if in_string:
                if char == "'":
                    if index + 1 < len(block) and block[index + 1] == "'":
                        index += 2
                        continue
                    in_string = False
            elif char == "'":
                in_string = True
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    raw_rows.append(block[row_start:index])
                    index += 1
                    break
            index += 1
        if depth:
            raise ValueError("Unclosed VALUES row")

    rows: list[dict[str, str | int | None]] = []
    for row_number, raw_row in enumerate(raw_rows, start=1):
        tokens = split_top_level(raw_row)
        if len(tokens) != len(columns):
            raise ValueError(
                f"VALUES row {row_number} has {len(tokens)} fields; expected {len(columns)}"
            )
        rows.append(dict(zip(columns, (decode_sql_value(token) for token in tokens))))
    return rows


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def strip_sql_comments_and_literals(sql_text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", sql_text, flags=re.DOTALL)
    text = re.sub(r"--[^\r\n]*", " ", text)
    return re.sub(r"N?'(?:''|[^'])*'", "''", text, flags=re.DOTALL)


def validate(repository_root: Path) -> list[str]:
    errors: list[str] = []

    required_paths = (
        CATALOG_PATH,
        SEARCH_TERM_PATH,
        RELATION_PATH,
        NAVIGATOR_PATH,
        ANALYSIS_CLASS_PATH,
        OBJECT_INVENTORY_PATH,
        PARAMETER_INVENTORY_PATH,
        RESULT_SET_INVENTORY_PATH,
        INSTALLER_PATH,
        PLAN_INSTALLER_PATH,
        Path("Documentation/Analysis_Guides/Start_Here.md"),
        Path("Documentation/Reference/Analysis_Navigator.md"),
        Path("Documentation/Analysis_Guides/Procedures/USP_AnalysisNavigator.md"),
    )
    for relative_path in required_paths:
        if not (repository_root / relative_path).is_file():
            errors.append(f"Missing Analysis Navigator contract file: {relative_path}")
    if errors:
        return errors

    try:
        catalog_rows = extract_values_rows(
            (repository_root / CATALOG_PATH).read_text(encoding="utf-8-sig"),
            CATALOG_COLUMNS,
        )
        term_rows = extract_values_rows(
            (repository_root / SEARCH_TERM_PATH).read_text(encoding="utf-8-sig"),
            SEARCH_TERM_COLUMNS,
        )
        relation_rows = extract_values_rows(
            (repository_root / RELATION_PATH).read_text(encoding="utf-8-sig"),
            RELATION_COLUMNS,
        )
    except ValueError as exc:
        return [f"Analysis Navigator metadata cannot be parsed: {exc}"]

    object_rows = read_csv(repository_root / OBJECT_INVENTORY_PATH)
    public_rows = [row for row in object_rows if row["ObjectType"] == "PROCEDURE"]
    public_procedures = {row["ObjectName"] for row in public_rows}
    catalog_names = [str(row["ProcedureName"]) for row in catalog_rows]
    catalog_procedures = set(catalog_names)

    if len(public_rows) != 97:
        errors.append(f"Public procedure inventory has {len(public_rows)} rows; expected 97.")
    if len(catalog_rows) != len(public_rows):
        errors.append(
            f"Analysis catalog has {len(catalog_rows)} rows; public inventory has {len(public_rows)}."
        )
    duplicate_catalog_names = sorted(
        name for name, count in Counter(catalog_names).items() if count != 1
    )
    if duplicate_catalog_names:
        errors.append("Duplicate catalog procedures: " + ", ".join(duplicate_catalog_names))
    missing_catalog = sorted(public_procedures - catalog_procedures)
    extra_catalog = sorted(catalog_procedures - public_procedures)
    if missing_catalog:
        errors.append("Public procedures missing from catalog: " + ", ".join(missing_catalog))
    if extra_catalog:
        errors.append("Catalog procedures absent from inventory: " + ", ".join(extra_catalog))

    class_text = (repository_root / ANALYSIS_CLASS_PATH).read_text(encoding="utf-8-sig")
    analysis_classes = set(
        re.findall(r"CAST\('([A-Z0-9_]+)'\s+AS\s+varchar\(64\)\)", class_text, re.IGNORECASE)
    )
    default_ranks: list[int] = []
    for row in catalog_rows:
        procedure = str(row["ProcedureName"])
        role = str(row["NavigationRole"])
        package = str(row["PackageCode"])
        cost = str(row["CostRangeCode"])
        area = str(row["PrimaryAreaCode"])
        scope = str(row["ScopeCode"])
        evidence_type = str(row["EvidenceType"])
        representative_class = row["RepresentativeAnalysisClass"]
        if role not in ALLOWED_ROLES:
            errors.append(f"Unknown navigation role for {procedure}: {role}")
        if package not in ALLOWED_PACKAGES:
            errors.append(f"Unknown package for {procedure}: {package}")
        if area not in ALLOWED_AREAS:
            errors.append(f"Unknown primary area for {procedure}: {area}")
        if scope not in ALLOWED_SCOPES:
            errors.append(f"Unknown scope for {procedure}: {scope}")
        if evidence_type not in ALLOWED_EVIDENCE_TYPES:
            errors.append(f"Unknown evidence type for {procedure}: {evidence_type}")
        if cost not in ALLOWED_COST_RANGES:
            errors.append(f"Unknown cost range for {procedure}: {cost}")
        if representative_class is not None and representative_class not in analysis_classes:
            errors.append(
                f"Unknown RepresentativeAnalysisClass for {procedure}: {representative_class}"
            )
        for bit_column in (
            "RequiresKnownTarget",
            "RequiresHighImpactForSafeStart",
            "HighImpactPathAvailable",
        ):
            if row[bit_column] not in (0, 1):
                errors.append(f"{procedure}.{bit_column} is not a bit literal.")
        if row["RequiresHighImpactForSafeStart"] == 1 and row["HighImpactPathAvailable"] != 1:
            errors.append(f"{procedure} requires High Impact but does not expose a High-Impact path.")
        expected_safe_high_impact = procedure in HIGH_IMPACT_SAFE_ENTRY_PROCEDURES
        if bool(row["RequiresHighImpactForSafeStart"]) != expected_safe_high_impact:
            errors.append(f"High-Impact safe-entry classification differs for {procedure}.")
        if bool(row["HighImpactPathAvailable"]) != ("HIGH" in cost):
            errors.append(f"High-Impact path flag and cost range differ for {procedure}.")
        if not str(row["DisplayName"] or "").strip():
            errors.append(f"Missing display name: {procedure}")
        if not str(row["Purpose"] or "").strip():
            errors.append(f"Missing purpose: {procedure}")
        if not str(row["PrerequisiteSummary"] or "").strip():
            errors.append(f"Missing prerequisite summary: {procedure}")
        safe_call = str(row["SafeCall"] or "")
        if role == "SUPPORT":
            if "[monitor].[USP_AnalysisNavigator]" not in safe_call:
                errors.append(f"Support SafeCall does not route through the Navigator: {procedure}")
        elif f"[monitor].[{procedure}]" not in safe_call:
            errors.append(f"SafeCall does not reference its procedure: {procedure}")

        documentation_path = Path(str(row["DocumentationPath"] or ""))
        if not documentation_path.as_posix().startswith(
            "Documentation/Analysis_Guides/Procedures/"
        ) or not (repository_root / documentation_path).is_file():
            errors.append(f"Invalid documentation path for {procedure}: {documentation_path}")
        runbook_value = row["RunbookPath"]
        if runbook_value is not None and not (repository_root / str(runbook_value)).is_file():
            errors.append(f"Invalid runbook path for {procedure}: {runbook_value}")

        rank = row["DefaultRank"]
        if rank is not None:
            if not isinstance(rank, int) or rank < 1:
                errors.append(f"Invalid DefaultRank for {procedure}: {rank}")
            else:
                default_ranks.append(rank)

    if sorted(default_ranks) != list(range(1, 17)):
        errors.append("DefaultRank must be unique and contiguous from 1 through 16.")

    term_names = [str(row["ProcedureName"]) for row in term_rows]
    term_procedures = set(term_names)
    if term_procedures != public_procedures:
        missing = sorted(public_procedures - term_procedures)
        extra = sorted(term_procedures - public_procedures)
        if missing:
            errors.append("Procedures without search terms: " + ", ".join(missing))
        if extra:
            errors.append("Search terms reference unknown procedures: " + ", ".join(extra))

    terms_by_procedure: dict[str, list[dict[str, str | int | None]]] = defaultdict(list)
    normalized_term_keys: Counter[tuple[str, str]] = Counter()
    exact_term_targets: dict[str, list[tuple[int, str]]] = defaultdict(list)
    for row in term_rows:
        procedure = str(row["ProcedureName"])
        language = str(row["LanguageCode"])
        term = str(row["SearchTerm"] or "")
        weight = row["SearchWeight"]
        terms_by_procedure[procedure].append(row)
        if language not in {"de", "en"}:
            errors.append(f"Invalid language for {procedure}: {language}")
        if not isinstance(weight, int) or not 1 <= weight <= 100:
            errors.append(f"Invalid search weight for {procedure}/{term}: {weight}")
            weight = 0
        if not term.strip() or not str(row["MatchReason"] or "").strip():
            errors.append(f"Incomplete search term metadata for {procedure}.")
        normalized = normalize_ci_ai(term)
        normalized_term_keys[(procedure, normalized)] += 1
        exact_term_targets[normalized].append((int(weight), procedure))

    duplicates = [key for key, count in normalized_term_keys.items() if count > 1]
    if duplicates:
        errors.append(
            "Duplicate CI/AI search terms: "
            + ", ".join(f"{procedure}/{term}" for procedure, term in duplicates)
        )
    for procedure in sorted(public_procedures):
        procedure_terms = terms_by_procedure.get(procedure, [])
        languages = {str(row["LanguageCode"]) for row in procedure_terms}
        if len(procedure_terms) < 2 or languages != {"de", "en"}:
            errors.append(f"{procedure} requires at least one German and one English search term.")

    for search_term, expected_procedure in EXPECTED_SEARCH_CASES.items():
        matches = exact_term_targets.get(normalize_ci_ai(search_term), [])
        if not matches:
            errors.append(f"Missing canonical search case: {search_term}")
            continue
        top_weight = max(weight for weight, _procedure in matches)
        top_targets = sorted(procedure for weight, procedure in matches if weight == top_weight)
        if top_targets != [expected_procedure]:
            errors.append(
                f"Canonical search case {search_term!r} resolves to {top_targets}, "
                f"expected {expected_procedure}."
            )

    relation_keys: Counter[tuple[str, str, str]] = Counter()
    relation_priorities: Counter[tuple[str, str, int]] = Counter()
    relation_sources: set[str] = set()
    for row in relation_rows:
        source = str(row["FromProcedureName"])
        target = str(row["ToProcedureName"])
        relation_type = str(row["RelationType"])
        priority = row["RelationPriority"]
        relation_sources.add(source)
        relation_keys[(source, relation_type, target)] += 1
        if source not in public_procedures or target not in public_procedures:
            errors.append(f"Relation has unknown endpoint: {source} -> {target}")
        if source == target:
            errors.append(f"Self relation is not allowed: {source}")
        if relation_type not in ALLOWED_RELATIONS:
            errors.append(f"Unknown relation type: {relation_type}")
        if not isinstance(priority, int) or not 1 <= priority <= 255:
            errors.append(f"Invalid relation priority: {source}/{relation_type}/{priority}")
        else:
            relation_priorities[(source, relation_type, priority)] += 1
        if not str(row["ConditionSummary"] or "").strip():
            errors.append(f"Missing relation condition: {source} -> {target}")

    duplicate_relations = [key for key, count in relation_keys.items() if count > 1]
    if duplicate_relations:
        errors.append("Duplicate analysis relations: " + ", ".join(map(str, duplicate_relations)))
    duplicate_priorities = [key for key, count in relation_priorities.items() if count > 1]
    if duplicate_priorities:
        errors.append(
            "Duplicate relation priorities per source/type: " + ", ".join(map(str, duplicate_priorities))
        )
    expected_relation_sources = public_procedures - RELATION_EXEMPT_PROCEDURES
    if relation_sources != expected_relation_sources:
        missing = sorted(expected_relation_sources - relation_sources)
        extra = sorted(relation_sources - expected_relation_sources)
        if missing:
            errors.append("Procedures without a next-step relation: " + ", ".join(missing))
        if extra:
            errors.append("Unexpected relation sources: " + ", ".join(extra))

    navigator_text = (repository_root / NAVIGATOR_PATH).read_text(encoding="utf-8-sig")
    executable_navigator = strip_sql_comments_and_literals(navigator_text)
    required_fragments = (
        "Latin1_General_100_CI_AI",
        "[monitor].[VW_AnalysisCatalog]",
        "[monitor].[VW_AnalysisSearchTerm]",
        "[monitor].[VW_AnalysisRelation]",
        "[monitor].[VW_AnalyseClassCatalog]",
        "[c].[ProcedureName] <> N'USP_AnalysisNavigator'",
        "@NurInstallierte",
        "@ResultSetArt",
        "@JsonErzeugen",
        "@MaxZeilen IS NULL OR @MaxZeilen = 0 THEN 2147483647",
        "TOP (@MaxZeilenEffektiv)",
        "COLLATE Latin1_General_100_CI_AI",
    )
    for fragment in required_fragments:
        if fragment not in navigator_text:
            errors.append(f"Navigator source is missing contract fragment: {fragment}")
    for forbidden_source in ("sys.dm_", "sys.query_store_", "fn_xe_file_target_read_file", "sp_executesql"):
        if forbidden_source.casefold() in executable_navigator.casefold():
            errors.append(f"Navigator executes a diagnostic/runtime source: {forbidden_source}")
    executable_calls = re.findall(
        r"\bEXEC(?:UTE)?\s+\[monitor\]\.\[([A-Za-z0-9_]+)\]",
        executable_navigator,
        re.IGNORECASE,
    )
    allowed_helper_calls = {
        "internalpreparesingleresulttable",
        "internalemitconsoleresult",
        "internalwriteresulttable",
    }
    unexpected_calls = sorted(
        {call for call in executable_calls if call.casefold() not in allowed_helper_calls}
    )
    if unexpected_calls:
        errors.append("Navigator executes non-renderer procedures: " + ", ".join(unexpected_calls))

    parameter_rows = read_csv(repository_root / PARAMETER_INVENTORY_PATH)
    parameters_by_procedure: dict[str, set[str]] = defaultdict(set)
    for parameter_row in parameter_rows:
        parameters_by_procedure[parameter_row["ProcedureName"]].add(parameter_row["ParameterName"])

    for row in catalog_rows:
        procedure = str(row["ProcedureName"])
        safe_call = str(row["SafeCall"] or "")
        call_match = re.search(
            r"\bEXEC(?:UTE)?\s+\[monitor\]\.\[([A-Za-z0-9_]+)\]",
            safe_call,
            re.IGNORECASE,
        )
        if not call_match:
            errors.append(f"SafeCall is not an executable monitor call: {procedure}")
            continue
        called_procedure = call_match.group(1)
        if called_procedure not in public_procedures:
            errors.append(f"SafeCall references an unknown procedure: {procedure}/{called_procedure}")
            continue
        assigned_parameters = set(re.findall(r"@([A-Za-z_][A-Za-z0-9_]*)\s*=", safe_call))
        unknown_parameters = sorted(
            assigned_parameters - parameters_by_procedure.get(called_procedure, set())
        )
        if unknown_parameters:
            errors.append(
                f"SafeCall uses unknown parameters for {called_procedure}: "
                + ", ".join(unknown_parameters)
            )

    navigator_parameters = [
        row["ParameterName"] for row in parameter_rows if row["ProcedureName"] == "USP_AnalysisNavigator"
    ]
    expected_parameters = [
        "Suchbegriff",
        "Bereich",
        "Scope",
        "Navigationsrolle",
        "NurInstallierte",
        "MaxZeilen",
        "ResultSetArt",
        "ResultTablesJson",
        "JsonErzeugen",
        "Json",
        "PrintMeldungen",
        "Hilfe",
    ]
    if navigator_parameters != expected_parameters:
        errors.append("Navigator parameter inventory differs from the public signature.")

    result_rows = read_csv(repository_root / RESULT_SET_INVENTORY_PATH)
    navigator_results = [
        row for row in result_rows if row["ProcedureName"] == "USP_AnalysisNavigator"
    ]
    if len(navigator_results) != 1 or navigator_results[0]["ResultName"] != "navigation":
        errors.append("Navigator must expose exactly the named navigation result-set contract.")

    installer_text = (repository_root / INSTALLER_PATH).read_text(encoding="utf-8-sig")
    installer_files = (
        "021_VW_AnalysisCatalog.sql",
        "022_VW_AnalysisSearchTerm.sql",
        "023_VW_AnalysisRelation.sql",
        "100_USP_AnalysisNavigator.sql",
    )
    installer_positions = [installer_text.find(file_name) for file_name in installer_files]
    if any(position < 0 for position in installer_positions):
        errors.append("Install_All.sql does not install the complete Analysis Navigator object set.")
    elif installer_positions != sorted(installer_positions):
        errors.append("Analysis Navigator objects are not installed in dependency order.")

    standalone_text = (repository_root / PLAN_INSTALLER_PATH).read_text(encoding="utf-8-sig")
    if re.search(r"Analysis(?:Catalog|SearchTerm|Relation|Navigator)", standalone_text, re.IGNORECASE):
        errors.append("PLAN-001 standalone installer depends on the Analysis Navigator.")

    procedure_index = (
        repository_root / "Documentation/Analysis_Guides/Procedures/README.md"
    ).read_text(encoding="utf-8-sig")
    for procedure in sorted(public_procedures):
        if procedure not in procedure_index:
            errors.append(f"Procedure index does not reference {procedure}.")

    object_reference = (
        repository_root / "Documentation/Reference/Object_Reference.md"
    ).read_text(encoding="utf-8-sig")
    supporting_objects = {
        row["ObjectName"] for row in object_rows if row["ObjectType"] != "PROCEDURE"
    }
    for object_name in sorted(supporting_objects):
        if object_name not in object_reference:
            errors.append(f"Supporting-object reference does not mention {object_name}.")

    for object_name, source_path in (
        ("VW_AnalysisCatalog", CATALOG_PATH),
        ("VW_AnalysisSearchTerm", SEARCH_TERM_PATH),
        ("VW_AnalysisRelation", RELATION_PATH),
    ):
        section_match = re.search(
            rf"^### `\[monitor\]\.\[{re.escape(object_name)}\]`\s*$"
            rf"(.*?)(?=^### `\[monitor\]\.\[|\Z)",
            object_reference,
            re.MULTILINE | re.DOTALL,
        )
        if not section_match:
            errors.append(f"Missing detailed supporting-object section: {object_name}")
            continue
        section = section_match.group(1)
        if f"Quelle: `{source_path.as_posix()}`" not in section:
            errors.append(f"Supporting-object source path differs: {object_name}")
        for dimension in ("Aufgabe", "Schnittstelle", "Verwendung", "Last und Sperren", "Vertrag"):
            if not re.search(rf"^\|\s*{re.escape(dimension)}\s*\|\s*\S", section, re.MULTILINE):
                errors.append(f"{object_name} is missing documentation dimension: {dimension}")
        if len(re.findall(r"[^\W_][\w-]*", section, re.UNICODE)) < 90:
            errors.append(f"Supporting-object section is below the 90-word floor: {object_name}")

    navigator_reference = (
        repository_root / "Documentation/Reference/Analysis_Navigator.md"
    ).read_text(encoding="utf-8-sig")
    documented_taxonomy = (
        ALLOWED_AREAS
        | ALLOWED_ROLES
        | ALLOWED_SCOPES
        | ALLOWED_EVIDENCE_TYPES
        | ALLOWED_COST_RANGES
        | ALLOWED_PACKAGES
        | ALLOWED_RELATIONS
    )
    for code in sorted(documented_taxonomy):
        if f"`{code}`" not in navigator_reference:
            errors.append(f"Analysis Navigator reference does not document taxonomy code: {code}")

    navigator_page = (
        repository_root / "Documentation/Analysis_Guides/Procedures/USP_AnalysisNavigator.md"
    ).read_text(encoding="utf-8-sig")
    required_navigator_headings = (
        "## Entscheidungsfrage und Einsatz",
        "## Nicht beantwortete Fragen",
        "## Sicherer Einstieg",
        "## Resultsets und Leserichtung",
        "## Eine Zeile bedeutet",
        "## So lesen",
        "## Warum kann das problematisch sein?",
        "## Wann ist es kein Problem?",
        "## Beispiele und Gegenbeispiele",
        "## Leere oder partielle Ausgabe",
        "## Eigenlast und Grenzen",
        "## Technische Vertiefung",
        "### Leitfrage",
        "### Technischer Hintergrund",
        "### Datenkette",
        "### Zeit- und Scope-Modell",
        "### Bewertung und Gegenprobe",
        "### Typische Fehlinterpretation",
        "### Folgeanalyse",
        "## Primärquellen",
    )
    for heading in required_navigator_headings:
        if heading not in navigator_page:
            errors.append(f"Navigator procedure page is missing heading: {heading}")
    for cost_dimension in (
        "Kostenklasse",
        "Standardpfad",
        "Teuerster Pfad",
        "Haupttreiber",
        "Skalierung",
        "Ressourcen",
        "Begrenzungswirkung",
        "Locking und Nebenwirkungen",
        "Schutzmechanismus",
        "Sicherer Einsatz",
        "Aussagegrenze",
    ):
        if not re.search(rf"^\|\s*{re.escape(cost_dimension)}\s*\|", navigator_page, re.MULTILINE):
            errors.append(f"Navigator procedure page is missing cost dimension: {cost_dimension}")
    for fragment in (
        "[Technische Detailbeschreibung](../../Reference/Analysis_Navigator.md)",
        "[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)",
        "https://learn.microsoft.com/",
        "Example",
    ):
        if fragment not in navigator_page:
            errors.append(f"Navigator procedure page is missing documentation marker: {fragment}")
    if len(re.findall(r"[^\W_][\w-]*", navigator_page, re.UNICODE)) < 700:
        errors.append("Navigator procedure page is below the 700-word substantive floor.")

    public_documents = sorted(
        document
        for document in repository_root.rglob("*.md")
        if "AI_Metadata" not in document.relative_to(repository_root).parts
        and ".git" not in document.relative_to(repository_root).parts
    )
    stale_count = re.compile(
        r"\b(?:85|88|90|93|94)\s+(?:(?:öffentliche|inventarisierte|dokumentierte)\s+)?Procedures\b",
        re.IGNORECASE,
    )
    for document in public_documents:
        text = document.read_text(encoding="utf-8-sig")
        relative = document.relative_to(repository_root)
        for forbidden_pattern in PUBLIC_DOCUMENTATION_FORBIDDEN:
            match = forbidden_pattern.search(text)
            if match:
                line = text.count("\n", 0, match.start()) + 1
                errors.append(
                    f"Public documentation boundary violated in {relative}:{line}: {match.group(0)}"
                )
        match = stale_count.search(text)
        if match:
            line = text.count("\n", 0, match.start()) + 1
            errors.append(f"Stale procedure count in {relative}:{line}: {match.group(0)}")

    public_source_inventory = (
        repository_root / "Metadata/Inventory/SystemSources.csv"
    ).read_text(encoding="utf-8-sig")
    for historical_marker in (
        "sanitized prior research",
        "historical source paths",
        "Current canonical code",
        "Canonical implementation",
    ):
        if historical_marker.casefold() in public_source_inventory.casefold():
            errors.append(
                "Public system-source inventory contains an authoring-history marker: "
                + historical_marker
            )

    root_readme = (repository_root / "README.md").read_text(encoding="utf-8-sig")
    documentation_readme = (repository_root / "Documentation/README.md").read_text(
        encoding="utf-8-sig"
    )
    expected_public_count = str(len(public_rows))
    expected_inventory_count = str(len(object_rows))
    for label, text in (("README.md", root_readme), ("Documentation/README.md", documentation_readme)):
        for fragment in (
            expected_public_count,
            expected_inventory_count,
            "Start_Here.md",
            "USP_AnalysisNavigator",
        ):
            if fragment not in text:
                errors.append(f"{label} is missing discovery/inventory marker: {fragment}")

    return errors


def run_self_test() -> None:
    sample = """
CREATE OR ALTER VIEW [monitor].[VW_Example] AS
SELECT *
FROM
(
    VALUES
      (N'USP_One',N'Text, with comma','de',100,N'It''s valid.')
    , (N'USP_Two',N'Parentheses (inside text)','en',95,NULL)
) AS [v]([ProcedureName],[SearchTerm],[LanguageCode],[SearchWeight],[MatchReason]);
"""
    rows = extract_values_rows(sample, SEARCH_TERM_COLUMNS)
    expected = [
        {
            "ProcedureName": "USP_One",
            "SearchTerm": "Text, with comma",
            "LanguageCode": "de",
            "SearchWeight": 100,
            "MatchReason": "It's valid.",
        },
        {
            "ProcedureName": "USP_Two",
            "SearchTerm": "Parentheses (inside text)",
            "LanguageCode": "en",
            "SearchWeight": 95,
            "MatchReason": None,
        },
    ]
    if rows != expected:
        raise AssertionError(f"VALUES parser self-test failed: {rows!r}")
    if normalize_ci_ai("BENÚTZER   WARTEN") != normalize_ci_ai("Benutzer warten"):
        raise AssertionError("CI/AI normalizer self-test failed.")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=Path, default=Path("."))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        print("Analysis Navigator validator self-test passed.")
        return 0

    errors = validate(args.repository_root.resolve())
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("Analysis Navigator metadata, discovery and documentation contracts passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
