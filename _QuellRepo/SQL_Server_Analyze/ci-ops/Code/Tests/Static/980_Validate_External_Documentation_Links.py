#!/usr/bin/env python3
"""Validate external documentation links without turning transient outages into failures."""

from __future__ import annotations

import argparse
import concurrent.futures
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


URL_PATTERN = re.compile(r"https?://[^\s<>()\]]+", re.IGNORECASE)
PERMANENT_FAILURES = {404, 410}
NETWORK_SCOPES = (
    pathlib.PurePosixPath("Documentation/Analysis_Guides"),
    pathlib.PurePosixPath("AI_Metadata/Internal_Documentation/Research/Sources.md"),
)


def normalize_url(raw: str) -> str:
    return raw.rstrip(".,;:'\"")


def extract_urls(text: str) -> set[str]:
    return {normalize_url(match.group(0)) for match in URL_PATTERN.finditer(text)}


def is_network_scope(relative_path: pathlib.PurePosixPath) -> bool:
    return any(
        relative_path == scope or scope in relative_path.parents
        for scope in NETWORK_SCOPES
    )


def check_url(url: str, timeout_seconds: float) -> tuple[str, str, int | None]:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "SQL_Server_Analyze-documentation-link-validator/1.0",
            "Range": "bytes=0-1023",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            status = response.getcode()
            if 200 <= status < 400:
                return url, "OK", status
            return url, "TRANSIENT", status
    except urllib.error.HTTPError as error:
        if error.code in PERMANENT_FAILURES:
            return url, "PERMANENT", error.code
        return url, "TRANSIENT", error.code
    except (urllib.error.URLError, TimeoutError, OSError):
        return url, "TRANSIENT", None


def run_self_test() -> None:
    sample = "[A](https://learn.microsoft.com/sql/a) und https://example.invalid/b."
    expected = {"https://learn.microsoft.com/sql/a", "https://example.invalid/b"}
    if extract_urls(sample) != expected:
        raise AssertionError("URL extraction or trailing-punctuation normalization failed")
    if not is_network_scope(pathlib.PurePosixPath("Documentation/Analysis_Guides/A.md")):
        raise AssertionError("Analysis guide network scope was not recognized")
    if is_network_scope(pathlib.PurePosixPath("Documentation/Quality/A.md")):
        raise AssertionError("Unrelated documentation entered the network scope")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    parser.add_argument("--check-network", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--timeout-seconds", type=float, default=12.0)
    parser.add_argument("--workers", type=int, default=12)
    args = parser.parse_args()

    if args.self_test:
        run_self_test()

    root = pathlib.Path(args.repository_root).resolve()
    documentation_root = root / "Documentation"
    errors: list[str] = []
    references: dict[str, set[str]] = {}
    network_urls: set[str] = set()

    for path in sorted(documentation_root.rglob("*.md")):
        relative = pathlib.PurePosixPath(path.relative_to(root).as_posix())
        for url in extract_urls(path.read_text(encoding="utf-8")):
            parsed = urllib.parse.urlsplit(url)
            if parsed.scheme not in {"http", "https"} or not parsed.netloc:
                errors.append(f"INVALID_EXTERNAL_URL path={relative}")
                continue
            references.setdefault(url, set()).add(str(relative))
            if is_network_scope(relative):
                network_urls.add(url)

    transient_count = 0
    if args.check_network:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
            results = executor.map(
                lambda url: check_url(url, args.timeout_seconds), sorted(network_urls)
            )
        for url, result, status in results:
            if result == "PERMANENT":
                paths = ",".join(sorted(references[url]))
                errors.append(f"BROKEN_EXTERNAL_URL status={status} paths={paths} url={url}")
            elif result == "TRANSIENT":
                transient_count += 1

    if errors:
        for error in sorted(errors):
            print(error, file=sys.stderr)
        return 1

    print(
        "External documentation link validation passed: "
        f"references={sum(len(paths) for paths in references.values())} "
        f"unique={len(references)} network_scope={len(network_urls)} "
        f"transient_warnings={transient_count}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
