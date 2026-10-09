"""Core, dependency-free session reuse, shared budget decisions, and advisory audit.

Pure decisions do not attest native discovery, enforce provider limits, reserve
money atomically, or create semantic analysis. Callers supply trusted current
authority evidence and acknowledge analysis only after actually reading rules.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
from typing import Any


def digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     allow_nan=False).encode()).hexdigest()


def capture_context(root: Path, dependencies: dict[str, list[str]], *,
                    repository_identity: str, authority_key: str, scope_key: str,
                    discovery_complete: bool) -> dict:
    """Capture selected rule bytes locally; authority_key binds native discovery.

    It must fingerprint the effective instruction chain/order and discovery
    configuration from trusted current client evidence, not an assumed default.
    Source ids are repository-relative; no content/absolute path is retained.
    """
    if type(discovery_complete) is not bool:
        raise ValueError("discovery_complete must be boolean")
    if not all(isinstance(x, str) and x for x in
               (repository_identity, scope_key)) or not re.fullmatch(r"[0-9a-f]{64}", authority_key):
        raise ValueError("repository/scope identity and authority digest are required")
    root = root.resolve()
    if not isinstance(dependencies, dict) or not dependencies:
        raise ValueError("selected source inventory must be nonempty")
    hashes = {}
    for source, deps in dependencies.items():
        if (not isinstance(source, str) or "\\" in source or not source or
                Path(source).is_absolute() or Path(source).drive or Path(source).as_posix() != source):
            raise ValueError("source must be a canonical relative path")
        path = (root / source).resolve()
        if not path.is_relative_to(root) or ".." in Path(source).parts:
            raise ValueError("source escapes repository")
        if not isinstance(deps, list) or any(d not in dependencies for d in deps):
            raise ValueError("dependency inventory is incomplete")
        raw = path.read_bytes()
        try:
            text = raw.decode("utf-8")
            if "\0" not in text:
                raw = text.replace("\r\n", "\n").encode("utf-8")
        except UnicodeDecodeError:
            pass
        hashes[source] = hashlib.sha256(raw).hexdigest()
    # Recheck the selected bytes to reject mutations during capture.
    for source, expected in hashes.items():
        raw = (root / source).read_bytes()
        try:
            text = raw.decode("utf-8")
            if "\0" not in text:
                raw = text.replace("\r\n", "\n").encode("utf-8")
        except UnicodeDecodeError:
            pass
        if hashlib.sha256(raw).hexdigest() != expected:
            raise ValueError("source changed during capture")
    keys = {}
    for source in dependencies:
        reached = set()
        pending = [source]
        while pending:
            item = pending.pop()
            if item not in reached:
                reached.add(item)
                pending.extend(dependencies[item])
        keys[source] = digest([repository_identity, authority_key, scope_key,
                               {p: [hashes[p], sorted(dependencies[p])] for p in sorted(reached)}])
    return {"discovery_complete": discovery_complete, "analysis_keys": keys}


class SessionContext:
    """Ephemeral availability index: never persist this as rule authority."""
    def __init__(self) -> None:
        self._available: dict[str, Any] = {}

    def check(self, snapshot: dict) -> dict:
        keys = snapshot["analysis_keys"]
        reuse = sorted(p for p, k in keys.items()
                       if snapshot["discovery_complete"] and k in self._available)
        reread = sorted(set(keys) - set(reuse))
        return {"status": "REUSE" if not reread else "PARTIAL" if reuse else "READ",
                "reuse": reuse, "reread": reread,
                "reason": "DISCOVERY_INCOMPLETE" if not snapshot["discovery_complete"]
                else "ANALYSIS_AVAILABLE" if not reread else "ANALYSIS_REQUIRED"}

    def acknowledge(self, snapshot: dict, analyses: dict[str, Any]) -> None:
        """Retain actual session analysis, not just evidence that it once existed."""
        if not snapshot["discovery_complete"]:
            raise ValueError("cannot acknowledge reusable analysis with incomplete discovery")
        if not isinstance(analyses, dict) or any(v is None for v in analyses.values()):
            raise ValueError("actual session analyses are required")
        for source, analysis in analyses.items():
            self._available[snapshot["analysis_keys"][source]] = analysis

    def analysis_for(self, snapshot: dict, source: str) -> Any:
        if not snapshot["discovery_complete"]:
            raise ValueError("current authority discovery is incomplete")
        return self._available[snapshot["analysis_keys"][source]]


def _amount(value: Any, *, nullable: bool = False) -> float | int | None:
    if value is None and nullable:
        return None
    if type(value) not in (int, float) or value < 0:
        raise ValueError("amount must be a finite nonnegative number")
    try:
        finite = math.isfinite(value)
    except OverflowError:
        finite = False
    if not finite:
        raise ValueError("amount must be a finite nonnegative number")
    return value


def budget_decision(request: dict) -> dict:
    required = {"schema_version", "contract", "wave_id", "unit", "soft_limit", "hard_limit",
                "next_reservation", "entries"}
    if set(request) != required or type(request["schema_version"]) is not int or request["schema_version"] != 1:
        raise ValueError("invalid budget request shape")
    if request["contract"] != "foundation-processing-budget/v1" or request["unit"] not in ("TOKENS", "CREDITS", "USD"):
        raise ValueError("invalid budget contract or unit")
    if not isinstance(request["wave_id"], str) or not request["wave_id"]:
        raise ValueError("wave identity is required")
    soft = _amount(request["soft_limit"], nullable=True)
    hard = _amount(request["hard_limit"], nullable=True)
    next_cost = _amount(request["next_reservation"])
    if soft is not None and hard is not None and soft > hard:
        raise ValueError("soft limit exceeds hard limit")
    if not isinstance(request["entries"], list):
        raise ValueError("entries must be a list")
    seen = {}
    measured = estimated = reserved = 0
    unknown = has_estimates = False
    for entry in request["entries"]:
        if not isinstance(entry, dict) or set(entry) != {"invocation_id", "actor", "consumed", "reserved", "provenance"}:
            raise ValueError("invalid ledger entry shape")
        if not all(isinstance(entry[k], str) and entry[k] for k in ("invocation_id", "actor")):
            raise ValueError("entry identity is required")
        previous = seen.get(entry["invocation_id"])
        if previous is not None:
            if previous != entry:
                raise ValueError("conflicting duplicate invocation")
            continue
        seen[entry["invocation_id"]] = entry
        consumed = _amount(entry["consumed"], nullable=True)
        reserved += _amount(entry["reserved"])
        provenance = entry["provenance"]
        if provenance not in ("MEASURED", "ESTIMATED", "UNKNOWN") or (consumed is None) != (provenance == "UNKNOWN"):
            raise ValueError("consumption and provenance disagree")
        if provenance == "MEASURED":
            measured += consumed
        elif provenance == "ESTIMATED":
            estimated += consumed
            has_estimates = True
        else:
            unknown = True
    projected = _amount(measured + estimated + reserved + next_cost)
    action = "ALLOW_NEW_WORK"
    if hard is not None and (unknown or has_estimates):
        action = "BUDGET_UNVERIFIED"
    if hard is not None and projected >= hard:
        action = "STOP_NEW_WORK"
    elif action == "ALLOW_NEW_WORK" and soft is not None and projected >= soft:
        action = "CHECKPOINT"
    return {"action": action, "wave_id": request["wave_id"], "unit": request["unit"], "measured": measured,
            "estimated": estimated, "reserved": reserved, "projected": projected,
            "unknown_consumption": unknown, "unique_invocations": len(seen),
            "reservation_applied": False, "provider_limit_enforced": False}


def audit_governance(sources: dict[str, str]) -> list[dict]:
    """Heuristic advice, never semantic classification or permission to rewrite."""
    patterns = {
        "BROAD_READING_PER_EDIT": r"before (?:every|each) (?:edit|change)|vor jeder (?:änderung|bearbeitung)",
        "RECURRING_POLLING": r"every \d+ minutes|alle \d+ minuten",
        "REVIEW_CHAIN": r"review (?:the|each|every) review|review of (?:the )?review|review des reviews",
    }
    return [{"source": source, "line": n, "code": code, "advisory": True}
            for source, text in sources.items() for n, line in enumerate(text.splitlines(), 1)
            for code, pattern in patterns.items() if re.search(pattern, line, re.I)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["budget", "audit"])
    parser.add_argument("--request", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        value = json.loads(args.request.read_text(encoding="utf-8"))
        if args.command == "audit" and (not isinstance(value, dict) or
                                        not all(isinstance(k, str) and isinstance(v, str) for k, v in value.items())):
            raise ValueError("audit requires source ids mapped to rule text")
        result = budget_decision(value) if args.command == "budget" else audit_governance(value)
        print(json.dumps(result, sort_keys=True, allow_nan=False))
        return 0
    except (ValueError, TypeError, OSError, KeyError) as exc:
        print(json.dumps({"error": str(exc)}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
