#!/usr/bin/env python3
"""Plan and record a fail-closed cache for repository rule-context analysis.

The cache never replaces native Codex instruction discovery or repository
sources.  It stores content fingerprints and dependency metadata only; callers
keep semantic analysis in session memory under the emitted analysis keys.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlsplit, urlunsplit

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python 3.11+ is the supported reference runtime
    tomllib = None  # type: ignore[assignment]


CONTRACT = "foundation-rule-context-cache/v1"
SCHEMA_VERSION = 1
GENERATOR_NAME = "foundation-rule-context-cache"
GENERATOR_VERSION = "1.0.0"
NORMALIZATION_POLICY = "foundation-utf8-crlf-lf/v1"
DEFAULT_PROJECT_DOC_MAX_BYTES = 32 * 1024
INSTRUCTION_NAMES = ("AGENTS.override.md", "AGENTS.md")
PATH_SUFFIXES = (".md", ".json", ".yaml", ".yml", ".toml")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_OBJECT_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
MARKDOWN_LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+[\"'][^)]*)?\)")
INLINE_CODE_RE = re.compile(r"`([^`\r\n]+)`")
WINDOWS_ABSOLUTE_RE = re.compile(r"^[A-Za-z]:[\\/]")
URL_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")


class CacheError(RuntimeError):
    """Bounded operational failure while building or recording a cache."""


@dataclass(frozen=True)
class DiscoveryOptions:
    repository: Path
    cwd: Path
    codex_home: Path | None
    include_global: bool
    fallback_filenames: tuple[str, ...]
    project_doc_max_bytes: int
    discovery_config_tag: str | None = None
    extra_rules: tuple[str, ...] = ()


@dataclass(frozen=True)
class SourceLocation:
    canonical_path: str
    filesystem_path: Path
    source_kind: str
    instruction_scope: str | None = None
    precedence: int | None = None


@dataclass(frozen=True)
class SnapshotResult:
    record: dict[str, Any]
    complete: bool
    reason_codes: tuple[str, ...]


def _canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_json(value: Any) -> str:
    return _sha256_bytes(_canonical_json(value).encode("utf-8"))


def _canonical_host_path(path: Path) -> str:
    return os.path.normcase(str(path.resolve())).replace("\\", "/")


def _run_git(repository: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repository), *args],
        text=True,
        capture_output=True,
        check=False,
        encoding="utf-8",
        errors="replace",
    )


def _git_output(repository: Path, *args: str) -> str | None:
    completed = _run_git(repository, *args)
    if completed.returncode != 0:
        return None
    return completed.stdout.strip()


def _normalize_remote(remote: str) -> str:
    value = remote.strip().replace("\\", "/")
    if "://" in value:
        parsed = urlsplit(value)
        host = (parsed.hostname or "").lower()
        if parsed.port is not None:
            host = f"{host}:{parsed.port}"
        value = urlunsplit((parsed.scheme.lower(), host, parsed.path, "", ""))
    else:
        scp_remote = re.fullmatch(r"(?:[^@/:]+@)?([^:]+):(.+)", value)
        if scp_remote:
            value = f"{scp_remote.group(1).lower()}:{scp_remote.group(2)}"
    if value.endswith(".git"):
        value = value[:-4]
    return value.rstrip("/")


def _repository_identity(repository: Path) -> dict[str, str]:
    origin = _normalize_remote(_git_output(repository, "config", "--get", "remote.origin.url") or "")
    roots_text = _git_output(repository, "rev-list", "--max-parents=0", "HEAD") or ""
    roots = sorted(line for line in roots_text.splitlines() if line)
    root_digest = _sha256_bytes(_canonical_host_path(repository).encode("utf-8"))
    if origin or roots:
        repository_id = _sha256_json({"origin": origin, "root_commits": roots})
        identity_method = "origin_and_root_commits_sha256"
    else:
        repository_id = _sha256_json({"unborn_repository_root_digest": root_digest})
        identity_method = "unborn_root_digest_sha256"

    common_dir_text = _git_output(repository, "rev-parse", "--git-common-dir")
    if common_dir_text:
        common_dir = Path(common_dir_text)
        if not common_dir.is_absolute():
            common_dir = repository / common_dir
        common_dir_digest = _sha256_bytes(_canonical_host_path(common_dir).encode("utf-8"))
    else:
        common_dir_digest = root_digest

    return {
        "repository_id": repository_id,
        "identity_method": identity_method,
        "canonical_root_digest": root_digest,
        "worktree_id": _sha256_json(
            {"canonical_root_digest": root_digest, "git_common_dir_digest": common_dir_digest}
        ),
        "git_common_dir_digest": common_dir_digest,
    }


def _relative_cwd(repository: Path, cwd: Path) -> str:
    resolved_repository = repository.resolve()
    resolved_cwd = cwd.resolve()
    try:
        relative = resolved_cwd.relative_to(resolved_repository)
    except ValueError as exc:
        raise CacheError("working directory must be inside the canonical repository root") from exc
    return "." if not relative.parts else relative.as_posix()


def _logical_content(data: bytes) -> tuple[str, str]:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return "BYTE_EXACT", _sha256_bytes(data)
    if "\x00" in text:
        return "BYTE_EXACT", _sha256_bytes(data)
    normalized = text.replace("\r\n", "\n").encode("utf-8")
    return "UTF8_CRLF_LF_NORMALIZED", _sha256_bytes(normalized)


def _read_nonempty(path: Path) -> bytes | None:
    if not path.is_file():
        return None
    data = path.read_bytes()
    return data if data.strip() else None


def _load_codex_discovery_settings(
    codex_home: Path | None,
    fallback_override: tuple[str, ...] | None,
    max_bytes_override: int | None,
) -> tuple[tuple[str, ...], int]:
    config: dict[str, Any] = {}
    config_path = codex_home / "config.toml" if codex_home else None
    if config_path and config_path.is_file():
        if tomllib is None:
            raise CacheError("tomllib is unavailable; effective Codex discovery settings are unknown")
        try:
            with config_path.open("rb") as handle:
                loaded = tomllib.load(handle)
        except (OSError, ValueError) as exc:
            raise CacheError(f"cannot read Codex discovery configuration: {exc}") from exc
        if isinstance(loaded, dict):
            config = loaded

    if fallback_override is None:
        raw_fallbacks = config.get("project_doc_fallback_filenames", [])
        if not isinstance(raw_fallbacks, list) or any(not isinstance(item, str) for item in raw_fallbacks):
            raise CacheError("project_doc_fallback_filenames must be a string array")
        fallbacks = tuple(raw_fallbacks)
    else:
        fallbacks = fallback_override

    if len(fallbacks) != len(set(fallbacks)) or any(
        not name or "/" in name or "\\" in name for name in fallbacks
    ):
        raise CacheError("fallback filenames must be unique plain filenames")
    if any(name in INSTRUCTION_NAMES for name in fallbacks):
        raise CacheError("fallback filenames must not duplicate AGENTS.override.md or AGENTS.md")

    raw_limit = (
        max_bytes_override
        if max_bytes_override is not None
        else config.get("project_doc_max_bytes", DEFAULT_PROJECT_DOC_MAX_BYTES)
    )
    if not isinstance(raw_limit, int) or isinstance(raw_limit, bool) or raw_limit <= 0:
        raise CacheError("project_doc_max_bytes must be a positive integer")
    return fallbacks, raw_limit


def make_options(
    repository: Path,
    cwd: Path,
    *,
    codex_home: Path | None = None,
    include_global: bool = True,
    fallback_filenames: tuple[str, ...] | None = None,
    project_doc_max_bytes: int | None = None,
    discovery_config_tag: str | None = None,
    extra_rules: tuple[str, ...] = (),
) -> DiscoveryOptions:
    repository = repository.resolve()
    cwd = cwd.resolve()
    top = _git_output(repository, "rev-parse", "--show-toplevel")
    if not top:
        raise CacheError("repository is not a Git worktree")
    repository = Path(top).resolve()
    fallbacks, max_bytes = _load_codex_discovery_settings(
        codex_home,
        fallback_filenames,
        project_doc_max_bytes,
    )
    _relative_cwd(repository, cwd)
    return DiscoveryOptions(
        repository=repository,
        cwd=cwd,
        codex_home=codex_home.resolve() if codex_home else None,
        include_global=include_global,
        fallback_filenames=fallbacks,
        project_doc_max_bytes=max_bytes,
        discovery_config_tag=discovery_config_tag,
        extra_rules=extra_rules,
    )


def _instruction_chain(options: DiscoveryOptions) -> tuple[list[SourceLocation], list[str]]:
    chain: list[SourceLocation] = []
    reasons: list[str] = []

    if options.include_global:
        if options.codex_home is None:
            reasons.append("GLOBAL_DISCOVERY_UNAVAILABLE")
        else:
            for name in INSTRUCTION_NAMES:
                candidate = options.codex_home / name
                if _read_nonempty(candidate) is not None:
                    chain.append(
                        SourceLocation(
                            canonical_path=f"@global/{name}",
                            filesystem_path=candidate,
                            source_kind="instruction",
                            instruction_scope="global",
                            precedence=len(chain),
                        )
                    )
                    break

    relative = Path(_relative_cwd(options.repository, options.cwd))
    directories = [options.repository]
    if str(relative) != ".":
        cursor = options.repository
        for part in relative.parts:
            cursor = cursor / part
            directories.append(cursor)

    names = (*INSTRUCTION_NAMES, *options.fallback_filenames)
    for directory in directories:
        for name in names:
            candidate = directory / name
            try:
                candidate.resolve().relative_to(options.repository)
            except ValueError:
                if candidate.exists():
                    reasons.append("INSTRUCTION_OUTSIDE_REPOSITORY")
                continue
            if _read_nonempty(candidate) is None:
                continue
            canonical = candidate.relative_to(options.repository).as_posix()
            chain.append(
                SourceLocation(
                    canonical_path=canonical,
                    filesystem_path=candidate,
                    source_kind="instruction",
                    instruction_scope="repository",
                    precedence=len(chain),
                )
            )
            break

    combined = 0
    project_entries = [entry for entry in chain if entry.instruction_scope == "repository"]
    for index, entry in enumerate(project_entries):
        size = len(entry.filesystem_path.read_bytes())
        combined += size + (2 if index else 0)
    if combined > options.project_doc_max_bytes:
        reasons.append("DISCOVERY_SIZE_LIMIT_EXCEEDED")
    if not any(entry.instruction_scope == "repository" for entry in chain):
        reasons.append("REPOSITORY_INSTRUCTION_CHAIN_EMPTY")
    return chain, reasons


def _repo_file_index(repository: Path) -> dict[str, list[Path]]:
    result: dict[str, list[Path]] = {}
    for path in repository.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(repository)
        if any(part in {".git", ".local", "__pycache__"} for part in relative.parts):
            continue
        result.setdefault(path.name, []).append(path)
    return result


def _looks_like_rule_path(value: str) -> bool:
    lowered = value.lower().split("#", 1)[0].split("?", 1)[0]
    return lowered.endswith(PATH_SUFFIXES)


def _clean_reference(value: str) -> str:
    return value.strip().strip("<>\"'").rstrip(".,;:").replace("\\", "/")


def _markdown_references(text: str) -> list[tuple[str, bool]]:
    references = [(_clean_reference(match.group(1)), True) for match in MARKDOWN_LINK_RE.finditer(text)]
    for match in INLINE_CODE_RE.finditer(text):
        value = _clean_reference(match.group(1))
        if _looks_like_rule_path(value) and not any(character.isspace() for character in value):
            references.append((value, False))
    return references


def _repo_map_references(text: str) -> list[tuple[str, bool]]:
    references: list[tuple[str, bool]] = []
    authority_indent: int | None = None
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if stripped == "authority:":
            authority_indent = indent
            continue
        if authority_indent is None:
            continue
        if indent <= authority_indent:
            authority_indent = None
            continue
        if stripped.startswith("- "):
            value = _clean_reference(stripped[2:].split(" #", 1)[0])
            if _looks_like_rule_path(value):
                references.append((value, True))
    return references


def _resolve_reference(
    reference: str,
    source: Path,
    repository: Path,
    file_index: dict[str, list[Path]],
) -> Path | None:
    value = reference.split("#", 1)[0].split("?", 1)[0]
    if not value or URL_RE.match(value) or WINDOWS_ABSOLUTE_RE.match(value) or value.startswith("/"):
        return None
    if any(token in value for token in ("*", "{", "}", "<", ">")):
        return None

    candidates: list[Path] = []
    raw = Path(value)
    if value.startswith((".ai/", "foundation/", "Documentation/", "tools/", "tests/", ".github/")):
        candidates.append(repository / raw)
    candidates.extend((source.parent / raw, repository / raw))
    for candidate in candidates:
        resolved = candidate.resolve()
        try:
            resolved.relative_to(repository)
        except ValueError:
            continue
        if resolved.is_file():
            return resolved

    if "/" not in value:
        matches = file_index.get(Path(value).name, [])
        if len(matches) == 1:
            return matches[0].resolve()
    return None


def _source_kind(path: Path, repository: Path) -> str:
    relative = path.relative_to(repository).as_posix()
    if "repo_map" in path.name:
        return "rule_index"
    if "/schemas/" in f"/{relative}" or path.name.endswith(".schema.json"):
        return "schema"
    if relative in {".ai/PROJECT_STATUS.md", ".ai/HANDOVER.md", ".ai/BACKLOG.md", ".ai/ROADMAP.md"}:
        return "context"
    return "rule"


def _git_fingerprint(repository: Path, canonical_path: str) -> dict[str, Any]:
    if canonical_path.startswith("@global/"):
        return {
            "head_blob_id": None,
            "index_blob_id": None,
            "working_tree_state": ["EXTERNAL_GLOBAL"],
        }

    head_blob = _git_output(repository, "rev-parse", "--verify", f"HEAD:{canonical_path}")
    stage = _git_output(repository, "ls-files", "--stage", "--", canonical_path)
    index_blob: str | None = None
    if stage:
        for line in stage.splitlines():
            fields = line.split(maxsplit=3)
            if len(fields) >= 3 and fields[2] == "0":
                index_blob = fields[1]
                break

    status = _run_git(repository, "status", "--porcelain=v1", "--untracked-files=all", "--", canonical_path)
    states: set[str] = set()
    for line in status.stdout.splitlines() if status.returncode == 0 else []:
        if line.startswith("??"):
            states.add("UNTRACKED")
            continue
        if len(line) >= 2:
            if line[0] != " ":
                states.add("STAGED")
            if line[1] != " ":
                states.add("UNSTAGED")
    if not states:
        states.add("TRACKED_CLEAN" if index_blob else "UNTRACKED")
    return {
        "head_blob_id": head_blob or None,
        "index_blob_id": index_blob,
        "working_tree_state": sorted(states),
    }


def _fingerprint_source(location: SourceLocation, repository: Path) -> dict[str, Any]:
    data = location.filesystem_path.read_bytes()
    normalization, semantic_hash = _logical_content(data)
    result: dict[str, Any] = {
        "source_kind": location.source_kind,
        "raw_sha256": _sha256_bytes(data),
        "semantic_sha256": semantic_hash,
        "size_bytes": len(data),
        "normalization": normalization,
        "git": _git_fingerprint(repository, location.canonical_path),
        "dependencies": [],
        "analysis_key": "",
    }
    if location.source_kind == "instruction":
        result["instruction_scope"] = location.instruction_scope
        result["precedence"] = location.precedence
    return result


def _discover_sources(
    options: DiscoveryOptions,
    instruction_chain: list[SourceLocation],
) -> tuple[dict[str, SourceLocation], dict[str, set[str]], list[str]]:
    locations = {entry.canonical_path: entry for entry in instruction_chain}
    dependencies: dict[str, set[str]] = {entry.canonical_path: set() for entry in instruction_chain}
    reasons: list[str] = []
    queue = list(instruction_chain)
    file_index = _repo_file_index(options.repository)

    for raw_rule in options.extra_rules:
        resolved = _resolve_reference(raw_rule, options.repository / "AGENTS.md", options.repository, file_index)
        if resolved is None:
            reasons.append("UNRESOLVED_REFERENCE")
            continue
        canonical = resolved.relative_to(options.repository).as_posix()
        if canonical not in locations:
            location = SourceLocation(canonical, resolved, _source_kind(resolved, options.repository))
            locations[canonical] = location
            dependencies[canonical] = set()
            queue.append(location)

    processed: set[str] = set()
    while queue:
        location = queue.pop(0)
        if location.canonical_path in processed:
            continue
        processed.add(location.canonical_path)
        if location.canonical_path.startswith("@global/"):
            # Global instructions participate in exact chain fingerprints, but
            # this repository cache never follows user-level relative links.
            continue
        try:
            text = location.filesystem_path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            # Ordinary rule payloads remain safely fingerprintable as opaque
            # bytes. Discovery-bearing instruction, index, and context files
            # must stay parseable or the dependency graph is uncertain.
            if location.source_kind in {"instruction", "rule_index", "context"}:
                reasons.append("RULE_SOURCE_ENCODING_UNSUPPORTED")
            continue

        references = _markdown_references(text)
        if location.filesystem_path.name in {"repo_map.yaml", "repo_map.yml"}:
            references.extend(_repo_map_references(text))
        for reference, strong in references:
            if URL_RE.match(reference) or reference.startswith(("#", "/")) or WINDOWS_ABSOLUTE_RE.match(reference):
                continue
            resolved = _resolve_reference(
                reference,
                location.filesystem_path,
                options.repository,
                file_index,
            )
            if resolved is None:
                if strong and _looks_like_rule_path(reference):
                    reasons.append("UNRESOLVED_REFERENCE")
                continue
            canonical = resolved.relative_to(options.repository).as_posix()
            dependencies.setdefault(location.canonical_path, set()).add(canonical)
            if canonical not in locations:
                child = SourceLocation(canonical, resolved, _source_kind(resolved, options.repository))
                locations[canonical] = child
                dependencies[canonical] = set()
                queue.append(child)

    return locations, dependencies, reasons


def _transitive_dependencies(path: str, graph: dict[str, set[str]]) -> set[str]:
    result: set[str] = set()
    pending = list(graph.get(path, set()))
    while pending:
        current = pending.pop()
        if current in result:
            continue
        result.add(current)
        pending.extend(graph.get(current, set()))
    result.discard(path)
    return result


def _finalize_record(
    options: DiscoveryOptions,
    identity: dict[str, str],
    cwd_relative: str,
    instruction_chain: list[SourceLocation],
    locations: dict[str, SourceLocation],
    graph: dict[str, set[str]],
) -> dict[str, Any]:
    sources = {
        canonical: _fingerprint_source(location, options.repository)
        for canonical, location in sorted(locations.items())
    }
    for canonical, source in sources.items():
        source["dependencies"] = sorted(graph.get(canonical, set()))

    discovery = {
        "global_scope_included": options.include_global,
        "fallback_filenames": list(options.fallback_filenames),
        "project_doc_max_bytes": options.project_doc_max_bytes,
        "discovery_config_tag_sha256": (
            _sha256_bytes(options.discovery_config_tag.encode("utf-8"))
            if options.discovery_config_tag is not None
            else None
        ),
    }
    chain_paths = [entry.canonical_path for entry in instruction_chain]
    instruction_fingerprint = [
        {
            "path": path,
            "semantic_sha256": sources[path]["semantic_sha256"],
            "precedence": sources[path]["precedence"],
        }
        for path in chain_paths
    ]
    scope_id = _sha256_json({"cwd": cwd_relative})
    scope_context = _sha256_json(
        {
            "cwd": cwd_relative,
            "instruction_chain": instruction_fingerprint,
            "discovery": discovery,
        }
    )
    for canonical, source in sources.items():
        closure = sorted(_transitive_dependencies(canonical, graph))
        dependency_fingerprints = [
            {
                "path": dependency,
                "semantic_sha256": sources[dependency]["semantic_sha256"],
                "dependencies": sorted(graph.get(dependency, set())),
            }
            for dependency in closure
            if dependency in sources
        ]
        source["analysis_key"] = _sha256_json(
            {
                "contract": CONTRACT,
                "scope_context": scope_context,
                "path": canonical,
                "semantic_sha256": source["semantic_sha256"],
                "dependencies": dependency_fingerprints,
            }
        )

    record: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "contract": CONTRACT,
        "generator": {"name": GENERATOR_NAME, "version": GENERATOR_VERSION},
        "normalization_policy": NORMALIZATION_POLICY,
        "repository": identity,
        "scope": {
            "scope_id": scope_id,
            "cwd": cwd_relative,
            "instruction_chain": chain_paths,
            "discovery": discovery,
        },
        "sources": sources,
    }
    record["record_digest"] = _sha256_json(record)
    return record


def _capture_once(options: DiscoveryOptions) -> SnapshotResult:
    identity = _repository_identity(options.repository)
    cwd_relative = _relative_cwd(options.repository, options.cwd)
    chain, reasons = _instruction_chain(options)
    locations, graph, reference_reasons = _discover_sources(options, chain)
    reasons.extend(reference_reasons)
    record = _finalize_record(options, identity, cwd_relative, chain, locations, graph)
    unique_reasons = tuple(sorted(set(reasons)))
    return SnapshotResult(record, not unique_reasons, unique_reasons)


def capture_snapshot(options: DiscoveryOptions) -> SnapshotResult:
    first = _capture_once(options)
    if not first.complete:
        return first
    second = _capture_once(options)
    if first.record["record_digest"] != second.record["record_digest"]:
        return SnapshotResult(second.record, False, ("SOURCE_CHANGED_DURING_DISCOVERY",))
    return second


def cache_record_key(record: dict[str, Any]) -> str:
    repository = record["repository"]
    scope = record["scope"]
    identity = _sha256_json(
        {
            "repository_id": repository["repository_id"],
            "worktree_id": repository["worktree_id"],
            "scope_id": scope["scope_id"],
        }
    )
    return f"v1/{identity}.json"


def cache_record_path(cache_dir: Path, record: dict[str, Any]) -> Path:
    return cache_dir.resolve().joinpath(*cache_record_key(record).split("/"))


def _ensure_nonversioned_destination(options: DiscoveryOptions, path: Path) -> None:
    resolved = path.resolve()
    try:
        relative = resolved.relative_to(options.repository).as_posix()
    except ValueError:
        return
    if relative == ".git" or relative.startswith(".git/"):
        raise CacheError("cache record destinations must not use Git administrative storage")
    tracked = _run_git(options.repository, "ls-files", "--error-unmatch", "--", relative)
    ignored = _run_git(options.repository, "check-ignore", "-q", "--", relative)
    if tracked.returncode == 0 or ignored.returncode != 0:
        raise CacheError(
            "cache record destinations inside the repository must be untracked and covered by Git ignore rules"
        )


def _record_digest_is_valid(record: dict[str, Any]) -> bool:
    digest = record.get("record_digest")
    if not isinstance(digest, str) or not HEX64_RE.fullmatch(digest):
        return False
    unsigned = dict(record)
    unsigned.pop("record_digest", None)
    return digest == _sha256_json(unsigned)


def _is_record_path(value: Any, *, allow_global: bool = True) -> bool:
    if not isinstance(value, str) or not value or "\\" in value or value.startswith("/"):
        return False
    if WINDOWS_ABSOLUTE_RE.match(value):
        return False
    if value.startswith("@global/"):
        return allow_global and value in {"@global/AGENTS.override.md", "@global/AGENTS.md"}
    return all(part not in {"", ".", ".."} for part in value.split("/"))


def _is_digest(value: Any) -> bool:
    return isinstance(value, str) and HEX64_RE.fullmatch(value) is not None


def _is_git_object(value: Any) -> bool:
    return value is None or (isinstance(value, str) and GIT_OBJECT_RE.fullmatch(value) is not None)


def _validate_record_shape(record: Any) -> tuple[bool, str | None]:
    if not isinstance(record, dict):
        return False, "CACHE_RECORD_CORRUPT"
    if record.get("schema_version") != SCHEMA_VERSION:
        return False, "CACHE_SCHEMA_CHANGED"
    if record.get("contract") != CONTRACT:
        return False, "CACHE_CONTRACT_CHANGED"
    if record.get("generator") != {"name": GENERATOR_NAME, "version": GENERATOR_VERSION}:
        return False, "CACHE_GENERATOR_CHANGED"
    if record.get("normalization_policy") != NORMALIZATION_POLICY:
        return False, "CACHE_NORMALIZATION_POLICY_CHANGED"
    if set(record) != {
        "schema_version",
        "contract",
        "generator",
        "normalization_policy",
        "repository",
        "scope",
        "sources",
        "record_digest",
    }:
        return False, "CACHE_RECORD_CORRUPT"

    repository = record.get("repository")
    scope = record.get("scope")
    if not isinstance(repository, dict) or not isinstance(scope, dict):
        return False, "CACHE_RECORD_CORRUPT"
    if set(repository) != {
        "repository_id",
        "identity_method",
        "canonical_root_digest",
        "worktree_id",
        "git_common_dir_digest",
    }:
        return False, "CACHE_RECORD_CORRUPT"
    if repository.get("identity_method") not in {
        "origin_and_root_commits_sha256",
        "unborn_root_digest_sha256",
    }:
        return False, "CACHE_RECORD_CORRUPT"
    if not all(
        _is_digest(repository.get(key))
        for key in ("repository_id", "canonical_root_digest", "worktree_id", "git_common_dir_digest")
    ):
        return False, "CACHE_RECORD_CORRUPT"
    if repository["worktree_id"] != _sha256_json(
        {
            "canonical_root_digest": repository["canonical_root_digest"],
            "git_common_dir_digest": repository["git_common_dir_digest"],
        }
    ):
        return False, "CACHE_RECORD_CORRUPT"

    if set(scope) != {"scope_id", "cwd", "instruction_chain", "discovery"}:
        return False, "CACHE_RECORD_CORRUPT"
    cwd = scope.get("cwd")
    if cwd != "." and not _is_record_path(cwd, allow_global=False):
        return False, "CACHE_RECORD_CORRUPT"
    if not _is_digest(scope.get("scope_id")) or scope["scope_id"] != _sha256_json({"cwd": cwd}):
        return False, "CACHE_RECORD_CORRUPT"
    instruction_chain = scope.get("instruction_chain")
    if (
        not isinstance(instruction_chain, list)
        or not instruction_chain
        or instruction_chain != list(dict.fromkeys(instruction_chain))
        or not all(_is_record_path(path) for path in instruction_chain)
    ):
        return False, "CACHE_RECORD_CORRUPT"
    discovery = scope.get("discovery")
    if not isinstance(discovery, dict) or set(discovery) != {
        "global_scope_included",
        "fallback_filenames",
        "project_doc_max_bytes",
        "discovery_config_tag_sha256",
    }:
        return False, "CACHE_RECORD_CORRUPT"
    fallbacks = discovery.get("fallback_filenames")
    if (
        not isinstance(discovery.get("global_scope_included"), bool)
        or not isinstance(fallbacks, list)
        or fallbacks != list(dict.fromkeys(fallbacks))
        or any(
            not isinstance(name, str)
            or not name
            or "/" in name
            or "\\" in name
            or name in INSTRUCTION_NAMES
            for name in fallbacks
        )
        or not isinstance(discovery.get("project_doc_max_bytes"), int)
        or isinstance(discovery.get("project_doc_max_bytes"), bool)
        or discovery["project_doc_max_bytes"] <= 0
        or (
            discovery.get("discovery_config_tag_sha256") is not None
            and not _is_digest(discovery.get("discovery_config_tag_sha256"))
        )
    ):
        return False, "CACHE_RECORD_CORRUPT"

    sources = record.get("sources")
    if not isinstance(sources, dict) or not sources:
        return False, "CACHE_RECORD_CORRUPT"
    if not all(_is_record_path(path) for path in sources):
        return False, "CACHE_RECORD_CORRUPT"
    source_kinds = {"instruction", "rule", "rule_index", "schema", "context"}
    normalizations = {"UTF8_CRLF_LF_NORMALIZED", "BYTE_EXACT"}
    git_states = {"TRACKED_CLEAN", "STAGED", "UNSTAGED", "UNTRACKED", "EXTERNAL_GLOBAL"}
    instruction_sources: set[str] = set()
    for path, source in sources.items():
        if not isinstance(source, dict):
            return False, "CACHE_RECORD_CORRUPT"
        base_keys = {
            "source_kind",
            "raw_sha256",
            "semantic_sha256",
            "size_bytes",
            "normalization",
            "git",
            "dependencies",
            "analysis_key",
        }
        if source.get("source_kind") == "instruction":
            expected_keys = base_keys | {"instruction_scope", "precedence"}
            instruction_sources.add(path)
        else:
            expected_keys = base_keys
        if set(source) != expected_keys or source.get("source_kind") not in source_kinds:
            return False, "CACHE_RECORD_CORRUPT"
        if (
            not _is_digest(source.get("raw_sha256"))
            or not _is_digest(source.get("semantic_sha256"))
            or not _is_digest(source.get("analysis_key"))
            or not isinstance(source.get("size_bytes"), int)
            or isinstance(source.get("size_bytes"), bool)
            or source["size_bytes"] < 0
            or source.get("normalization") not in normalizations
        ):
            return False, "CACHE_RECORD_CORRUPT"
        dependencies = source.get("dependencies")
        if (
            not isinstance(dependencies, list)
            or dependencies != sorted(set(dependencies))
            or any(dependency not in sources for dependency in dependencies)
        ):
            return False, "CACHE_RECORD_CORRUPT"
        git = source.get("git")
        if not isinstance(git, dict) or set(git) != {
            "head_blob_id",
            "index_blob_id",
            "working_tree_state",
        }:
            return False, "CACHE_RECORD_CORRUPT"
        states = git.get("working_tree_state")
        if (
            not _is_git_object(git.get("head_blob_id"))
            or not _is_git_object(git.get("index_blob_id"))
            or not isinstance(states, list)
            or not states
            or states != sorted(set(states))
            or any(state not in git_states for state in states)
        ):
            return False, "CACHE_RECORD_CORRUPT"
        if path.startswith("@global/"):
            if source.get("instruction_scope") != "global" or states != ["EXTERNAL_GLOBAL"]:
                return False, "CACHE_RECORD_CORRUPT"
        elif "EXTERNAL_GLOBAL" in states:
            return False, "CACHE_RECORD_CORRUPT"

    if instruction_sources != set(instruction_chain):
        return False, "CACHE_RECORD_CORRUPT"
    global_paths = [path for path in instruction_chain if path.startswith("@global/")]
    if (
        len(global_paths) > 1
        or (bool(global_paths) and not discovery["global_scope_included"])
        or (global_paths and instruction_chain[0] != global_paths[0])
    ):
        return False, "CACHE_RECORD_CORRUPT"
    for precedence, path in enumerate(instruction_chain):
        source = sources[path]
        if (
            source.get("precedence") != precedence
            or source.get("instruction_scope") not in {"global", "repository"}
        ):
            return False, "CACHE_RECORD_CORRUPT"

    instruction_fingerprint = [
        {
            "path": path,
            "semantic_sha256": sources[path]["semantic_sha256"],
            "precedence": sources[path]["precedence"],
        }
        for path in instruction_chain
    ]
    scope_context = _sha256_json(
        {"cwd": cwd, "instruction_chain": instruction_fingerprint, "discovery": discovery}
    )
    graph = {path: set(source["dependencies"]) for path, source in sources.items()}
    for path, source in sources.items():
        closure = sorted(_transitive_dependencies(path, graph))
        dependency_fingerprints = [
            {
                "path": dependency,
                "semantic_sha256": sources[dependency]["semantic_sha256"],
                "dependencies": sorted(graph.get(dependency, set())),
            }
            for dependency in closure
        ]
        expected_analysis_key = _sha256_json(
            {
                "contract": CONTRACT,
                "scope_context": scope_context,
                "path": path,
                "semantic_sha256": source["semantic_sha256"],
                "dependencies": dependency_fingerprints,
            }
        )
        if source["analysis_key"] != expected_analysis_key:
            return False, "CACHE_RECORD_CORRUPT"
    if not _record_digest_is_valid(record):
        return False, "CACHE_RECORD_CORRUPT"
    return True, None


def _read_record(path: Path) -> tuple[dict[str, Any] | None, str | None]:
    if not path.is_file():
        return None, "CACHE_RECORD_NOT_FOUND"
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None, "CACHE_RECORD_CORRUPT"
    valid, reason = _validate_record_shape(record)
    return (record if valid else None), reason


def _dependent_closure(changed: set[str], sources: dict[str, Any]) -> set[str]:
    invalidated = set(changed)
    progress = True
    while progress:
        progress = False
        for path, source in sources.items():
            if path in invalidated:
                continue
            if invalidated.intersection(source.get("dependencies", [])):
                invalidated.add(path)
                progress = True
    return invalidated


def compare_records(previous: dict[str, Any] | None, current: SnapshotResult, read_reason: str | None = None) -> dict[str, Any]:
    current_record = current.record
    current_sources = current_record["sources"]
    all_current = sorted(current_sources)
    record_key = cache_record_key(current_record)

    if not current.complete:
        return _plan_payload(
            "CACHE_MISS",
            list(current.reason_codes),
            current_record,
            all_current,
            [],
            record_key,
        )
    if previous is None:
        missing_reasons = [read_reason or "CACHE_RECORD_NOT_FOUND"]
        if read_reason in {None, "CACHE_RECORD_NOT_FOUND"}:
            missing_reasons.append("SCOPE_UNKNOWN")
        return _plan_payload(
            "CACHE_MISS",
            missing_reasons,
            current_record,
            all_current,
            [],
            record_key,
        )

    reasons: list[str] = []
    for key, reason in (
        ("repository_id", "REPOSITORY_CHANGED"),
        ("canonical_root_digest", "CANONICAL_ROOT_CHANGED"),
        ("worktree_id", "WORKTREE_CHANGED"),
        ("git_common_dir_digest", "WORKTREE_CHANGED"),
    ):
        if previous["repository"].get(key) != current_record["repository"].get(key):
            reasons.append(reason)
    if previous["scope"].get("cwd") != current_record["scope"].get("cwd"):
        reasons.append("WORKING_DIRECTORY_CHANGED")
    if previous["scope"].get("discovery") != current_record["scope"].get("discovery"):
        reasons.append("DISCOVERY_CONFIGURATION_CHANGED")
    if previous["scope"].get("instruction_chain") != current_record["scope"].get("instruction_chain"):
        reasons.append("INSTRUCTION_CHAIN_CHANGED")
    if reasons:
        return _plan_payload("CACHE_MISS", reasons, current_record, all_current, [], record_key)

    previous_sources = previous["sources"]
    old_paths = set(previous_sources)
    new_paths = set(current_sources)
    added = new_paths - old_paths
    removed = old_paths - new_paths
    if added or removed:
        reasons = ["SOURCE_SET_CHANGED"]
        if added:
            reasons.append("SOURCE_ADDED")
        if removed:
            reasons.append("SOURCE_REMOVED")
        if any(
            previous_sources[path].get("dependencies") != current_sources[path].get("dependencies")
            for path in old_paths.intersection(new_paths)
        ):
            reasons.append("DEPENDENCY_GRAPH_CHANGED")
        if added and removed:
            old_hashes = {previous_sources[path]["semantic_sha256"] for path in removed}
            new_hashes = {current_sources[path]["semantic_sha256"] for path in added}
            if old_hashes.intersection(new_hashes):
                reasons.append("SOURCE_RENAMED_OR_MOVED")
        return _plan_payload("CACHE_MISS", reasons, current_record, all_current, [], record_key)

    instruction_paths = set(current_record["scope"]["instruction_chain"])
    instruction_changed: set[str] = set()
    content_changed: set[str] = set()
    git_changed: set[str] = set()
    eol_equivalent: set[str] = set()
    dependency_changed: set[str] = set()

    for path in sorted(new_paths):
        old = previous_sources[path]
        new = current_sources[path]
        if old.get("source_kind") != new.get("source_kind") or old.get("dependencies") != new.get("dependencies"):
            dependency_changed.add(path)
        if old.get("semantic_sha256") != new.get("semantic_sha256") or old.get("normalization") != new.get("normalization"):
            content_changed.add(path)
            if path in instruction_paths:
                instruction_changed.add(path)
        elif old.get("raw_sha256") != new.get("raw_sha256"):
            eol_equivalent.add(path)
        raw_eol_only = (
            old.get("raw_sha256") != new.get("raw_sha256")
            and old.get("semantic_sha256") == new.get("semantic_sha256")
            and old.get("normalization") == "UTF8_CRLF_LF_NORMALIZED"
            and new.get("normalization") == "UTF8_CRLF_LF_NORMALIZED"
        )
        if old.get("git") != new.get("git") and not raw_eol_only:
            git_changed.add(path)
            if path in instruction_paths:
                instruction_changed.add(path)

    if dependency_changed:
        return _plan_payload(
            "CACHE_MISS",
            ["DEPENDENCY_GRAPH_CHANGED"],
            current_record,
            all_current,
            [],
            record_key,
        )
    if instruction_changed:
        return _plan_payload(
            "CACHE_MISS",
            ["INSTRUCTION_CONTENT_OR_GIT_STATE_CHANGED", "INSTRUCTION_CHAIN_FULL_INVALIDATION"],
            current_record,
            all_current,
            [],
            record_key,
        )

    changed = content_changed | git_changed
    if changed:
        invalidated = _dependent_closure(changed, current_sources)
        reasons = []
        if content_changed:
            reasons.append("RULE_CONTENT_CHANGED")
        if git_changed:
            reasons.append("RULE_GIT_STATE_CHANGED")
        if invalidated - changed:
            reasons.append("TRANSITIVE_DEPENDENT_INVALIDATED")
        reused = sorted(new_paths - invalidated)
        return _plan_payload(
            "PARTIAL_INVALIDATION",
            reasons,
            current_record,
            sorted(invalidated),
            reused,
            record_key,
        )

    hit_reasons = ["CACHE_RECORD_VALID"]
    if eol_equivalent:
        hit_reasons.append("EOL_REPRESENTATION_EQUIVALENT")
    return _plan_payload("CACHE_HIT", hit_reasons, current_record, [], all_current, record_key)


def _plan_payload(
    status: str,
    reasons: Iterable[str],
    record: dict[str, Any],
    reanalyze: list[str],
    reuse: list[str],
    record_key: str,
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "status": status,
        "reason_codes": sorted(set(reasons)),
        "record_key": record_key,
        "repository_id": record["repository"]["repository_id"],
        "worktree_id": record["repository"]["worktree_id"],
        "scope_id": record["scope"]["scope_id"],
        "cwd": record["scope"]["cwd"],
        "instruction_chain": list(record["scope"]["instruction_chain"]),
        "reanalyze": reanalyze,
        "reuse": reuse,
        "analysis_keys": {path: record["sources"][path]["analysis_key"] for path in sorted(record["sources"])},
        "fingerprint_source_count": len(record["sources"]),
        "analysis_full_read_count": len(reanalyze),
    }


def check_cache(options: DiscoveryOptions, cache_dir: Path) -> dict[str, Any]:
    snapshot = capture_snapshot(options)
    path = cache_record_path(cache_dir, snapshot.record)
    _ensure_nonversioned_destination(options, path)
    previous, read_reason = _read_record(path)
    return compare_records(previous, snapshot, read_reason)


class _ExclusiveLock:
    def __init__(self, path: Path, timeout_seconds: float) -> None:
        self.path = path
        self.timeout_seconds = timeout_seconds
        self.handle: int | None = None

    def __enter__(self) -> "_ExclusiveLock":
        deadline = time.monotonic() + self.timeout_seconds
        while True:
            try:
                self.handle = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                return self
            except FileExistsError:
                if time.monotonic() >= deadline:
                    raise CacheError("cache record lock is unavailable")
                time.sleep(0.05)

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        if self.handle is not None:
            os.close(self.handle)
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass


def _atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    payload = (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with temporary.open("xb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def record_cache(options: DiscoveryOptions, cache_dir: Path, *, lock_timeout_seconds: float = 5.0) -> dict[str, Any]:
    initial = capture_snapshot(options)
    if not initial.complete:
        return compare_records(None, initial, "CACHE_RECORD_NOT_WRITTEN")
    path = cache_record_path(cache_dir, initial.record)
    _ensure_nonversioned_destination(options, path)
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_suffix(path.suffix + ".lock")
    with _ExclusiveLock(lock_path, lock_timeout_seconds):
        current = capture_snapshot(options)
        if not current.complete or current.record["record_digest"] != initial.record["record_digest"]:
            unstable = SnapshotResult(current.record, False, ("SOURCE_CHANGED_DURING_DISCOVERY",))
            return compare_records(None, unstable, "CACHE_RECORD_NOT_WRITTEN")
        _atomic_write_json(path, current.record)
    payload = compare_records(current.record, current)
    payload["recorded"] = True
    payload["reason_codes"] = sorted(set(payload["reason_codes"] + ["CACHE_RECORD_WRITTEN"]))
    return payload


def _print_human(payload: dict[str, Any]) -> None:
    print(f"[{payload['status']}] reasons={','.join(payload['reason_codes'])}")
    print(f"[SCOPE] cwd={payload['cwd']} instructions={len(payload['instruction_chain'])} sources={payload['fingerprint_source_count']}")
    if payload["reanalyze"]:
        print("[REANALYZE] " + ", ".join(payload["reanalyze"]))
    if payload["reuse"]:
        print("[REUSE] " + ", ".join(payload["reuse"]))
    print(f"[RECORD] {payload['record_key']}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "record"])
    parser.add_argument("--repository", type=Path, default=Path.cwd())
    parser.add_argument("--cwd", type=Path)
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--codex-home", type=Path)
    parser.add_argument("--fallback-filename", action="append", dest="fallback_filenames")
    parser.add_argument("--project-doc-max-bytes", type=int)
    parser.add_argument("--discovery-config-tag")
    parser.add_argument("--extra-rule", action="append", default=[])
    parser.add_argument("--lock-timeout-seconds", type=float, default=5.0)
    parser.add_argument("--json", action="store_true", dest="json_output")
    args = parser.parse_args(argv)

    repository = args.repository.resolve()
    cwd = (args.cwd or repository).resolve()
    codex_home = args.codex_home
    if codex_home is None:
        configured_home = os.environ.get("CODEX_HOME")
        codex_home = Path(configured_home) if configured_home else Path.home() / ".codex"

    try:
        options = make_options(
            repository,
            cwd,
            codex_home=codex_home,
            include_global=True,
            fallback_filenames=(
                tuple(args.fallback_filenames) if args.fallback_filenames is not None else None
            ),
            project_doc_max_bytes=args.project_doc_max_bytes,
            discovery_config_tag=args.discovery_config_tag,
            extra_rules=tuple(args.extra_rule),
        )
        if args.command == "check":
            payload = check_cache(options, args.cache_dir)
        else:
            if args.lock_timeout_seconds < 0:
                raise CacheError("lock timeout must be non-negative")
            payload = record_cache(
                options,
                args.cache_dir,
                lock_timeout_seconds=args.lock_timeout_seconds,
            )
    except (CacheError, OSError, ValueError) as exc:
        payload = {
            "schema_version": 1,
            "status": "CACHE_MISS",
            "reason_codes": ["CACHE_OPERATION_FAILED"],
            "message": str(exc),
        }
        if args.json_output:
            print(json.dumps(payload, indent=2, sort_keys=True))
        else:
            print(f"[CACHE_MISS] CACHE_OPERATION_FAILED: {exc}")
        return 2

    if args.json_output:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        _print_human(payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
