# Artifact Registration and Allocation Policy

Status: AUTHORITATIVE

## Purpose

This policy defines how humans, AI systems, scripts, services, issue trackers, and other clients create and register durable artifacts without depending on one programming language or vendor. It operationalizes `PERSISTENT_IDENTITY_POLICY.md`.

The registration contract is normative. Python, PowerShell, a GUI, an IDE extension, a REST service, Jira, GitHub Issues, Azure DevOps, Linear, or a project-specific tool may implement the contract. No implementation language or storage technology is part of the Foundation identity semantics.

## Core rule

A project or identifier scope has one **Registration Authority** for final project-local human-reference allocation.

The Registration Authority is a logical role, not a specific executable. Humans and AI systems MUST use the same authority for the same identifier scope. A client MUST NOT invent the next sequence independently when a Registration Authority exists.

A project may use multiple authorities only for explicitly disjoint namespaces/scopes whose collision rules are documented.

## Rule classes

### REQUIRED

- Persistent artifact UIDs follow the active persistent-identity contract and are never reused.
- Published human references are stable and are never reused for another artifact.
- Humans and AI systems use the same Registration Authority for a given scope.
- The authority, allocation mode, prefix registry, and collision behavior are discoverable from project-owned governance or machine-readable configuration.
- Final human references are allocated by the authority, not guessed by scanning Markdown, filenames, Git history, chat history, or a model's memory.
- Concurrent creation MUST NOT allow two logical artifacts to receive the same final human reference.
- Registration never confers authorization to modify, approve, execute, or delete the artifact.

### DEFAULT

For a new project using the Foundation profile:

- machine UID: RFC 9562 UUIDv7 represented as `urn:uuid:<uuid>`;
- final human reference: `<PREFIX>-<SEQUENCE>`;
- final sequence width: at least four digits for display, expanding without truncation;
- repository-native JSON authority profile: `foundation-artifact-registry/v2`;
- v2 stores complete registered artifact records in one central JSON registry and uses the canonical human reference as the artifact object key;
- v2 derives the next sequence from canonical references instead of persisting `next_sequence`;
- Git-native v2 concurrency uses Git commit/blob state rather than a second mutable global registry revision counter;
- direct allocation: serialized or equivalently unique;
- concurrent/offline creation: `DEFERRED` until a safe registration point when final allocation cannot be made safely.

The detailed v2 storage, validation, object-level merge, Git-result verification, cross-PR preflight, and generated-view contract is defined in `CENTRAL_ARTIFACT_REGISTRY_POLICY.md`.

### PROJECT_SELECTABLE

A project may instead use an existing issue tracker, database sequence, internal service, PowerShell module, Python tool, .NET application, shell tool, the Foundation legacy v1 JSON profile, or another allocator when it satisfies the required invariants. Existing repositories should preserve a mature compatible authority rather than replacing it merely to match Foundation tooling.

## Registration states

The Foundation distinguishes logical identity from registration state.

An artifact may exist with a permanent machine UID but without a final human reference. This is `DEFERRED`/`DRAFT` creation; the UID is already final even though the final project-local human reference has not yet been allocated.

After final allocation, the published human reference is reserved permanently for that logical artifact. Retirement preserves the canonical reference, UID, aliases, and traceability; it does not free the number for reuse.

## Allocation modes

### `DIRECT`

`DIRECT` allocates the machine UID and final human reference during the same registration operation.

Use `DIRECT` only when the Registration Authority serializes allocation or otherwise provides equivalent atomic uniqueness. Examples include a central database/issue tracker, a single-writer local workflow, or a repository integration point that re-evaluates allocation against the current authoritative state.

A client that cannot establish safe serialized allocation MUST NOT emulate `DIRECT` by scanning Markdown, filenames, or model-visible task lists for the highest number.

For a v2 central JSON registry, deriving `MAX(canonical sequence)+1` is part of the Registration Authority operation over the canonical registry state. This is different from scanning non-authoritative files. Open-PR reservations may also be included when the project uses that policy.

### `DEFERRED`

`DEFERRED` creates the durable machine UID immediately while leaving the final human reference unset. It is the safe default for concurrent branches, offline work, forks, or multiple humans/AI agents when no authority can safely allocate the final sequence at creation time.

The final human reference is allocated later by `register` at a serialized integration point. Temporary display labels may be used by a client, but they are not stable references unless the project explicitly publishes them as aliases.

## Language-neutral operations

An implementation may expose different commands or UI, but it maps to these semantic operations:

- `create` — create a durable artifact, using `DIRECT` or `DEFERRED`;
- `register` — allocate the final human reference for an existing UID;
- `resolve` — resolve a stable human reference or alias to the machine UID;
- `add_alias` — add a durable historical/project alias without changing identity;
- `add_relation` — add an explicit relationship without encoding hierarchy in the ID;
- `retire` — mark an artifact inactive while preserving all identifiers;
- `supersede` — link a replacement artifact while retaining both identities;
- `validate` — verify registry and artifact invariants.

Projects may expose richer operations, but these meanings must not be silently redefined when interoperating with Foundation tooling.

## Registration Authority contract

A Registration Authority MUST provide or preserve equivalent semantics for:

1. uniqueness of final human references within its declared scope;
2. stable mapping from each allocated final human reference to exactly one artifact UID;
3. non-reuse of registered or retired references;
4. explicit prefix-to-kind meaning;
5. deterministic formatting of the final human reference;
6. collision detection;
7. durable history sufficient to resolve published references;
8. concurrency control appropriate to the selected allocation mode;
9. recovery behavior after partial failure.

A project may keep these semantics in an issue tracker or database instead of a JSON file.

## Registry profiles

### `foundation-artifact-registry/v2` — default repository-native JSON profile

The v2 profile is the Foundation default when the Registration Authority is a JSON file versioned with the repository.

- Complete artifact records live in the central `artifacts` object.
- The canonical human reference is the object key and is not redundantly stored in each record.
- Prefix configuration stores stable `kind` and display `width` only.
- `next_sequence` is derived, not persisted.
- `RETIRED` records remain present and reserve their canonical references permanently.
- A Git-native v2 registry does not need a mutable `registry_revision`; Git state is the stale-reader/concurrency token.
- Central-registry changes use the object-level semantic merge and validation contract from `CENTRAL_ARTIFACT_REGISTRY_POLICY.md` rather than trusting Git's line merge for correctness.

### `foundation-artifact-registry/v1` — compatible legacy allocation profile

The v1 profile stores prefix allocation state, `next_sequence`, `registry_revision`, and human-ref-to-UID allocations separately from complete artifact records. It remains compatible for existing repositories and for the current optional Python/PowerShell `artifact-registration-clients` reference implementations.

Foundation upgrade to v1.6 MUST NOT silently rewrite an existing v1 authority to v2. Migration of an established Registration Authority storage model is a project decision and must preserve canonical references, UIDs, aliases, and no-reuse history.

## Concurrency

Concurrency control belongs to the selected authority rather than to the identifier syntax.

- A database/service may use transactions, unique constraints, sequences, compare-and-swap, or another appropriate mechanism.
- The legacy v1 local registry uses an exclusive lock plus `registry_revision` stale-reader checks.
- The Git-native v2 profile uses current Git state, semantic three-way merge, and merge-time revalidation; optional cross-PR preflight provides earlier collision feedback.
- Neither local JSON profile is a distributed database. Projects needing high-frequency multi-host allocation may prefer a central service or issue tracker.

## Prefix allocation

Prefix meaning is stable after publication. Width is presentation only and expands when necessary. Current parent, phase, wave, status, owner, date, or repository location do not change the human reference.

For v2, the next candidate for a prefix is:

`MAX(sequence of existing canonical references for that prefix, plus live reservations when applicable) + 1`.

When no canonical reference exists for the prefix, the first candidate is `1`. Gaps are valid and are not repaired by reusing registered or retired references.

For v1, `next_sequence` remains explicit legacy allocation state. Clients using v1 must follow the v1 authority state and must not substitute visible-file scanning.

## Schemas

The Foundation ships JSON Schemas for interoperable profiles:

- `artifact-record.schema.json` — standalone logical artifact record contract;
- `artifact-registry.schema.json` — legacy v1 allocation registry;
- `artifact-registry-v2.schema.json` — central v2 complete-record registry;
- `artifact-registration-request.schema.json` — language-neutral mutation request envelope.

A compatible project authority may use a different internal representation if it preserves equivalent semantics and exposes enough mapping for AI/human continuation.

## Optional reference tooling

Foundation tooling is convenience implementation, not normative runtime.

### `artifact-registration-clients`

The official Python and PowerShell clients implement the v1 compatibility profile and shared language-neutral creation/registration fixtures. Python is not required. PowerShell is a first-class implementation, not a wrapper around Python.

### `artifact-registry-github`

The optional GitHub capability implements reference v2 validation, derived allocation, object-level three-way merge, Git-result comparison, generated backlog checking, and early open-PR collision preflight. It includes a GitHub Actions workflow template.

A project may implement v2 in PowerShell, another language, another CI platform, or a central service. Selecting v2 does not require Python or GitHub.

## Existing repositories

During Foundation integration or upgrade:

1. discover whether the target already has an identifier allocator/issue tracker/registry;
2. preserve it if it satisfies the required identity invariants;
3. document it as the Registration Authority when needed for AI discovery;
4. do not install or activate optional Foundation clients merely because they exist;
5. if the project adopts the Foundation human-reference profile prospectively, choose the authority and allocation mode explicitly;
6. if the target already uses a JSON registry, assess whether v2 central storage materially improves consistency/query/merge behavior;
7. treat migration from v1 or split-artifact storage to v2 as an explicit project choice, not an automatic Foundation upgrade side effect;
8. historical references remain governed by `PRESERVE`, `ADOPT_FORWARD`, or `MIGRATE_EXPLICIT` from `PERSISTENT_IDENTITY_POLICY.md`.

Foundation installation MUST NOT silently replace an existing project allocator.

## AI behavior

Before creating a durable project artifact, an AI MUST determine the project's Registration Authority for that scope.

- If an authority exists and is callable, use it.
- If an authority exists but is not callable, do not invent a final sequence; create only what the project permits or report the registration step as pending.
- If the project explicitly uses `DEFERRED`, mint the permanent UID and leave the final human reference unallocated.
- For v2, derive a final sequence only as an authority operation over the canonical registry/current reservations, never from Markdown or model memory.
- If no authority exists in a new Foundation-default project, the project should establish one before publishing final sequence references.
- Do not assume Python is preferred merely because the actor is an AI.

## Human behavior

A human should be able to create an artifact through the same authority using a client natural to the environment: PowerShell, a CLI, a GUI, an issue form, an IDE action, or another project-selected interface.

The human is not expected to calculate UUID bits, manually edit counters, reason about Git line merges, or understand concurrency internals for ordinary creation.

## Failure and recovery

Registration favors durable traceability over compact numbering.

- If a published human reference exists, do not recycle it even if later work is abandoned; retain or retire it according to the authority contract.
- If an artifact UID is created in `DEFERRED` mode and later abandoned, keep the UID non-reusable.
- If two external systems already allocated colliding local references, preserve both machine identities and disambiguate with namespace/alias mapping rather than collapsing them.
- For v2 Git workflows, a failed semantic merge leaves both branch states intact; resolve the object-level conflict explicitly and re-run validation rather than accepting a textually convenient merge.

## Validation expectations

`FOUNDATION_INTEGRITY` validates that the transferred registration/central-registry policies and schemas are internally consistent and that selected Foundation capabilities match the declared transfer contract.

`PROJECT_SEMANTIC` should validate, when applicable:

- exactly one authority per overlapping allocation scope;
- documented mapping from kinds to prefixes;
- no duplicate final human references or artifact UIDs;
- no reuse or reassignment of registered/retired references;
- valid aliases and relation targets;
- project-selected client/authority behavior consistent with local governance;
- v2 generated projections are not maintained as competing authorities.

`RUNTIME_EMPIRICAL` should test actual concurrent allocation, issue-tracker/service integration, filesystem locking, database constraints, GitHub Actions behavior, semantic merge execution, or recovery behavior where those mechanisms are relied upon.

## Security and privacy

Registration identifiers are not authorization tokens. Registry files and request envelopes must not contain secrets merely because they are machine-readable.

UUIDv7 privacy considerations from `PERSISTENT_IDENTITY_POLICY.md` continue to apply. Projects may select UUIDv4 when creation chronology is sensitive.
