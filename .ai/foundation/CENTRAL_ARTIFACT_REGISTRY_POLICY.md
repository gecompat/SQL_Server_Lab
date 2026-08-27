# Central Artifact Registry and Semantic Merge Policy

Status: AUTHORITATIVE

## Purpose

This policy defines the Foundation default for repository-native planning and governance artifact registration when a project chooses a JSON-file Registration Authority.

The default central profile is `foundation-artifact-registry/v2`. It stores the complete registered artifact records in one canonical JSON object. The human reference is the key in `artifacts`; it is not duplicated as a mutable field inside the record.

The older `foundation-artifact-registry/v1` allocation-only profile remains a compatible legacy profile. Existing projects are not forced to migrate merely by upgrading the Foundation.

## Canonical state

A v2 registry contains:

- `schema_version: 2`;
- `profile: foundation-artifact-registry/v2`;
- `prefixes`, mapping each allowed human-reference prefix to its stable artifact kind and presentation width;
- `artifacts`, mapping each canonical human reference to its complete registered record.

A repository may choose its registry path. The path itself is a locator, not identity.

`next_sequence` MUST NOT be persisted in the v2 profile. The next candidate sequence for a prefix is derived as `MAX(existing canonical sequences for that prefix) + 1`; when no canonical reference exists for a prefix, the first candidate is `1`. `RETIRED` artifacts remain in `artifacts` and therefore continue to reserve their references permanently.

A Git-native v2 registry also does not require a mutable global `registry_revision` counter. Git commit/blob identity is the concurrency token. A non-Git implementation MAY expose an external ETag/revision token, but it MUST NOT create an independent competing truth for the artifact set.

## Allocation

Allocation MUST use the current authoritative registry state plus any reservations that the active Registration Authority treats as live.

For repository workflows:

1. load the authoritative registry;
2. include canonical references already reserved by other open work when the project uses cross-PR reservation/preflight;
3. derive the maximum sequence for the requested prefix;
4. select the next unused sequence;
5. validate prefix, kind, UID, aliases, relations, and no-reuse invariants;
6. persist the complete artifact atomically or submit it through the repository merge workflow.

Scanning Markdown, filenames, chat history, or model memory is never an allocation authority.

Parallel branches MAY use `DEFERRED` creation with a permanent machine UID and no final human reference. A project that publishes provisional human references in open PRs MUST define whether abandoned, never-merged reservations are permanently retired or may be reused. Registered or retired canonical references MUST never be reused.

## Structural and semantic integrity

A v2 validator MUST check at least:

- valid JSON and schema/profile;
- canonical human-reference syntax and registered prefix;
- prefix width/presentation consistency;
- artifact kind matches the configured prefix kind;
- every `artifact_uid` is valid and globally unique;
- aliases are unique and do not collide with another canonical reference;
- a canonical reference is never reassigned to another UID;
- registered/retired references are not silently removed;
- a `RETIRED` artifact is not silently reactivated;
- relation targets resolve when the relation contract requires an internal artifact;
- forbidden self-relations are rejected;
- relation types that require acyclic graphs, including `parent` and `depends_on`, are cycle-checked;
- generated project views declared authoritative-by-projection are reproducible from the registry.

JSON Schema proves structure only. Cross-record uniqueness, transition integrity, graph rules, and comparison with the merge base are semantic validator responsibilities.

## Object-level three-way merge

A canonical central registry MUST NOT rely on Git's line-oriented textual merge semantics for correctness.

For a pull request, compute a three-way merge from:

- `BASE`: registry at the merge base;
- `MAIN`: registry at the current target branch head;
- `HEAD`: registry in the pull-request head.

Merge recursively by JSON object/property semantics:

- if only one side changed a value relative to `BASE`, take that change;
- if both sides changed to the same value, take that value;
- if both sides changed the same scalar/list/property differently, report a semantic conflict;
- independent object-property changes may be combined;
- concurrent creation of the same canonical reference with different content is a conflict;
- lists are atomic by default unless a narrower project contract defines a deterministic merge for that field.

After the structural merge, run the complete semantic integrity validator on the candidate result.

## Git merge verification

A GitHub merge gate SHOULD additionally simulate Git's actual three-way merge for the registry file and compare its parsed JSON result with the object-level semantic merge result.

If Git reports a textual conflict, the gate fails. If Git produces valid JSON that differs semantically from the expected object-level result, the gate fails with a merge-result mismatch. Therefore a syntactically valid but incorrectly line-merged registry cannot be accepted merely because Git reported no conflict.

## Early cross-PR preflight

Projects using GitHub SHOULD run an early preflight whenever a pull request is opened, reopened, or synchronized. The preflight compares the current PR with other open PRs and reports at least:

- duplicate newly introduced canonical human references;
- duplicate newly introduced artifact UIDs;
- alias collisions;
- overlapping edits to the same existing artifact;
- dependencies on artifacts that exist only in another unmerged PR when detectable.

Hard identity collisions are blocking. Overlapping edits that may still be object-mergeable SHOULD be surfaced early as warnings so the PR can be corrected before the final merge gate.

The cross-PR preflight is advisory evidence about current open work; it does not replace the authoritative merge check against the current target branch.

## Deterministic serialization

Registry writers SHOULD serialize deterministically: UTF-8, LF line endings, stable key ordering, consistent indentation, and exactly one final newline. Canonical serialization reduces irrelevant Git diffs but is not a substitute for semantic merge validation.

## Generated views

A project MAY generate `BACKLOG.md`, status tables, roadmap views, or other human-readable projections from the central registry. When a view is declared generated, CI SHOULD regenerate it and fail when the committed projection differs. The JSON registry remains the canonical state; generated views are not independent planning authorities.

## GitHub capability

The optional `artifact-registry-github` capability provides a reference object-level validator/merger and a GitHub Actions workflow template. It is an implementation aid, not a requirement to use Python or GitHub. Another platform/language is compatible when it enforces the same contract.
