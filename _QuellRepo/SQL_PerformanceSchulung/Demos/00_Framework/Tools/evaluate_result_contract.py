#!/usr/bin/env python3
"""Evaluate FWK-011 result contracts using only the Python standard library."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Mapping


class ContractError(ValueError):
    """Raised when contract or evidence input is structurally invalid."""


def reject_constant(value: str) -> None:
    raise ContractError(f"non-finite JSON number is not allowed: {value}")


def load_json(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle, parse_float=Decimal, parse_constant=reject_constant)
    except OSError as exc:
        raise ContractError("input file could not be read") from exc
    except json.JSONDecodeError as exc:
        raise ContractError("input file is not valid JSON") from exc

    if not isinstance(value, dict):
        raise ContractError("top-level JSON value must be an object")
    return value


def finite_number(value: Any, label: str) -> Decimal:
    if isinstance(value, bool) or not isinstance(value, (int, Decimal)):
        raise ContractError(f"{label} must be numeric")
    try:
        number = value if isinstance(value, Decimal) else Decimal(value)
    except InvalidOperation as exc:
        raise ContractError(f"{label} must be numeric") from exc
    if not number.is_finite():
        raise ContractError(f"{label} must be finite")
    return number


def number_text(value: Decimal) -> str:
    normalized = format(value, "f")
    if "." in normalized:
        normalized = normalized.rstrip("0").rstrip(".")
    return normalized or "0"


def ratio_text(value: Decimal) -> str:
    try:
        return number_text(value.quantize(Decimal("0.000001")))
    except InvalidOperation:
        return format(value, ".6E")


def text(value: Any, label: str, allowed: set[str] | None = None) -> str:
    if not isinstance(value, str) or not value:
        raise ContractError(f"{label} must be a non-empty string")
    if allowed is not None and value not in allowed:
        raise ContractError(f"{label} has unsupported value")
    return value


def mapping(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be an object")
    return value


@dataclass(frozen=True)
class AssertionResult:
    assertion_id: str
    outcome: str
    code: str
    observed: str
    required: str
    message: str

    def as_dict(self, sequence: int) -> dict[str, Any]:
        return {
            "sequence": sequence,
            "phase": "RESULT_CONTRACT",
            "check_id": self.assertion_id,
            "outcome": self.outcome,
            "code": self.code,
            "observed_value": self.observed,
            "required_value": self.required,
            "message": self.message,
        }


def get_metric(
    evidence: Mapping[str, Any],
    phase: str,
    metric: str,
    assertion_id: str,
    on_missing: str,
) -> tuple[Decimal | None, AssertionResult | None]:
    phase_data = evidence.get(phase)
    if not isinstance(phase_data, dict) or metric not in phase_data:
        outcome = "SKIP" if on_missing == "SKIP" else "FAIL"
        code = "SKIP_EVIDENCE_MISSING" if outcome == "SKIP" else "FAIL_RESULT_CONTRACT"
        return None, AssertionResult(
            assertion_id=assertion_id,
            outcome=outcome,
            code=code,
            observed=f"{phase}.{metric}=missing",
            required=f"{phase}.{metric}=numeric",
            message="Die für die Assertion erforderliche Evidenz fehlt.",
        )
    return finite_number(phase_data[metric], f"{phase}.{metric}"), None


def breach_result(
    assertion_id: str,
    severity: str,
    observed: str,
    required: str,
) -> AssertionResult:
    if severity == "WARN":
        return AssertionResult(
            assertion_id,
            "WARN",
            "WARN_EMPIRICAL_VARIANCE",
            observed,
            required,
            "Die empirische Erwartung wurde außerhalb der Warnbandbreite beobachtet.",
        )
    return AssertionResult(
        assertion_id,
        "FAIL",
        "FAIL_RESULT_CONTRACT",
        observed,
        required,
        "Die verpflichtende Ergebnisbedingung wurde verletzt.",
    )


def pass_result(assertion_id: str, observed: str, required: str) -> AssertionResult:
    return AssertionResult(
        assertion_id,
        "PASS",
        "OK",
        observed,
        required,
        "Die Ergebnisbedingung ist erfüllt.",
    )


def evaluate_assertion(
    assertion: Mapping[str, Any],
    evidence: Mapping[str, Any],
) -> AssertionResult:
    assertion_id = text(assertion.get("id"), "assertion.id")
    kind = text(
        assertion.get("kind"),
        f"{assertion_id}.kind",
        {"EXACT", "RANGE", "RATIO_MAX", "RATIO_MIN", "DIRECTION"},
    )
    severity = text(
        assertion.get("severity", "FAIL"),
        f"{assertion_id}.severity",
        {"FAIL", "WARN"},
    )
    on_missing = text(
        assertion.get("on_missing", "FAIL"),
        f"{assertion_id}.on_missing",
        {"FAIL", "SKIP"},
    )

    if kind in {"EXACT", "RANGE"}:
        phase = text(assertion.get("phase"), f"{assertion_id}.phase", {"baseline", "comparison"})
        metric = text(assertion.get("metric"), f"{assertion_id}.metric")
        value, missing = get_metric(evidence, phase, metric, assertion_id, on_missing)
        if missing is not None:
            return missing
        assert value is not None

        if kind == "EXACT":
            expected = finite_number(assertion.get("expected"), f"{assertion_id}.expected")
            observed = f"{phase}.{metric}={number_text(value)}"
            required = f"exactly {number_text(expected)}"
            return pass_result(assertion_id, observed, required) if value == expected else breach_result(
                assertion_id, severity, observed, required
            )

        minimum = finite_number(assertion.get("minimum"), f"{assertion_id}.minimum")
        maximum = finite_number(assertion.get("maximum"), f"{assertion_id}.maximum")
        if minimum > maximum:
            raise ContractError(f"{assertion_id}: minimum must not exceed maximum")
        observed = f"{phase}.{metric}={number_text(value)}"
        required = f"{number_text(minimum)} <= value <= {number_text(maximum)}"
        return pass_result(assertion_id, observed, required) if minimum <= value <= maximum else breach_result(
            assertion_id, severity, observed, required
        )

    baseline_metric = text(assertion.get("baseline_metric"), f"{assertion_id}.baseline_metric")
    comparison_metric = text(assertion.get("comparison_metric"), f"{assertion_id}.comparison_metric")
    baseline, missing = get_metric(evidence, "baseline", baseline_metric, assertion_id, on_missing)
    if missing is not None:
        return missing
    comparison, missing = get_metric(evidence, "comparison", comparison_metric, assertion_id, on_missing)
    if missing is not None:
        return missing
    assert baseline is not None and comparison is not None

    if kind in {"RATIO_MAX", "RATIO_MIN"}:
        if baseline <= 0:
            raise ContractError(f"{assertion_id}: ratio baseline must be greater than zero")
        ratio = comparison / baseline
        observed = (
            f"comparison.{comparison_metric}/baseline.{baseline_metric}={ratio_text(ratio)}"
        )
        if kind == "RATIO_MAX":
            limit = finite_number(assertion.get("maximum_ratio"), f"{assertion_id}.maximum_ratio")
            if limit < 0:
                raise ContractError(f"{assertion_id}: maximum_ratio must be non-negative")
            required = f"ratio <= {number_text(limit)}"
            return pass_result(assertion_id, observed, required) if ratio <= limit else breach_result(
                assertion_id, severity, observed, required
            )

        limit = finite_number(assertion.get("minimum_ratio"), f"{assertion_id}.minimum_ratio")
        if limit < 0:
            raise ContractError(f"{assertion_id}: minimum_ratio must be non-negative")
        required = f"ratio >= {number_text(limit)}"
        return pass_result(assertion_id, observed, required) if ratio >= limit else breach_result(
            assertion_id, severity, observed, required
        )

    direction = text(
        assertion.get("direction"),
        f"{assertion_id}.direction",
        {"LESS", "LESS_OR_EQUAL", "GREATER", "GREATER_OR_EQUAL", "UNCHANGED"},
    )
    tolerance = finite_number(assertion.get("tolerance", 0), f"{assertion_id}.tolerance")
    if tolerance < 0:
        raise ContractError(f"{assertion_id}: tolerance must be non-negative")

    delta = comparison - baseline
    observed = (
        f"baseline.{baseline_metric}={number_text(baseline)}; "
        f"comparison.{comparison_metric}={number_text(comparison)}; delta={number_text(delta)}"
    )
    required = f"direction={direction}; tolerance={number_text(tolerance)}"

    passed = {
        "LESS": comparison < baseline - tolerance,
        "LESS_OR_EQUAL": comparison <= baseline + tolerance,
        "GREATER": comparison > baseline + tolerance,
        "GREATER_OR_EQUAL": comparison >= baseline - tolerance,
        "UNCHANGED": abs(delta) <= tolerance,
    }[direction]
    return pass_result(assertion_id, observed, required) if passed else breach_result(
        assertion_id, severity, observed, required
    )


def validate_metadata(contract: Mapping[str, Any], evidence: Mapping[str, Any]) -> tuple[str, str]:
    contract_version = text(contract.get("contract_version"), "contract_version")
    evidence_version = text(evidence.get("contract_version"), "evidence.contract_version")
    if contract_version != "1.0" or evidence_version != contract_version:
        raise ContractError("contract versions are inconsistent or unsupported")

    demo_id = text(contract.get("demo_id"), "demo_id")
    evidence_demo_id = text(evidence.get("demo_id"), "evidence.demo_id")
    profile = text(contract.get("profile"), "profile")
    evidence_profile = text(evidence.get("profile"), "evidence.profile")
    if not re.fullmatch(r"(STL|OPT|QRY|IDX|CON|RES|DGN)-[0-9]{3}", demo_id):
        raise ContractError("demo_id is not canonical")
    if not re.fullmatch(r"[A-Z0-9_]{1,32}", profile):
        raise ContractError("profile is not canonical")
    if evidence_demo_id != demo_id or evidence_profile != profile:
        raise ContractError("contract and evidence metadata do not match")
    return demo_id, profile


def summarize(results: list[AssertionResult], demo_id: str, profile: str) -> dict[str, Any]:
    priority = {"PASS": 0, "WARN": 1, "SKIP": 2, "FAIL": 3}
    outcome = max((result.outcome for result in results), key=priority.__getitem__)
    code = {
        "PASS": "OK",
        "WARN": "WARN_EMPIRICAL_VARIANCE",
        "SKIP": "SKIP_EVIDENCE_MISSING",
        "FAIL": "FAIL_RESULT_CONTRACT",
    }[outcome]
    return {
        "sequence": len(results) + 1,
        "phase": "RESULT_CONTRACT",
        "check_id": "SUMMARY",
        "outcome": outcome,
        "code": code,
        "observed_value": f"demo_id={demo_id}; profile={profile}; assertions={len(results)}",
        "required_value": "FAIL > SKIP > WARN > PASS",
        "message": "Die Ergebnisassertionen wurden ausgewertet.",
    }


def run(contract_path: Path, evidence_path: Path) -> tuple[list[dict[str, Any]], int]:
    contract = load_json(contract_path)
    evidence = load_json(evidence_path)
    demo_id, profile = validate_metadata(contract, evidence)

    assertions = contract.get("assertions")
    if not isinstance(assertions, list) or not assertions:
        raise ContractError("assertions must be a non-empty array")

    seen: set[str] = set()
    results: list[AssertionResult] = []
    for raw in assertions:
        assertion = mapping(raw, "assertion")
        assertion_id = text(assertion.get("id"), "assertion.id")
        if assertion_id in seen:
            raise ContractError("assertion IDs must be unique")
        seen.add(assertion_id)
        results.append(evaluate_assertion(assertion, evidence))

    output = [result.as_dict(index) for index, result in enumerate(results, start=1)]
    summary = summarize(results, demo_id, profile)
    output.append(summary)
    return output, 1 if summary["outcome"] == "FAIL" else 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate an FWK-011 result contract.")
    parser.add_argument("contract", type=Path)
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()

    try:
        output, exit_code = run(args.contract, args.evidence)
    except ContractError as exc:
        output = [
            {
                "sequence": 1,
                "phase": "RESULT_CONTRACT",
                "check_id": "SUMMARY",
                "outcome": "FAIL",
                "code": "FAIL_RESULT_CONTRACT",
                "observed_value": "input rejected",
                "required_value": "valid FWK-011 contract and evidence",
                "message": str(exc),
            }
        ]
        exit_code = 2

    json.dump(output, sys.stdout, ensure_ascii=False, indent=2, allow_nan=False)
    sys.stdout.write("\n")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
