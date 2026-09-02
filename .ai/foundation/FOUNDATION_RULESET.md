# AI Repository Foundation Ruleset

Status: AUTHORITATIVE BASELINE
Ruleset version: 1.8.0

This directory contains reusable governance rules, machine-readable schemas, the semantic feature catalog, and the source-license notice required for transferred Foundation material. Optional capability files are installed only when explicitly selected. The ruleset does not describe the Foundation source project and does not define the target project's README, root license, architecture, backlog, status, or release state.

## Rule classes

- `REQUIRED`: minimum protected behavior that may not be silently weakened; a target project may be stricter.
- `DEFAULT`: applies unless an intentional project-specific override exists.
- `PROJECT_SELECTABLE`: selected by the project when relevant.

Existing project rules do not need to be rewritten into these labels. Use semantic integration classes instead.

## Read by scope

- project/baseline rules: `PROJECT_RULES.md`
- semantic integration, compatibility, discovery, and adapter migration: `SEMANTIC_INTEGRATION_POLICY.md`
- persistent artifact identity, human references, aliases, relations, revisions, and legacy-safe adoption: `PERSISTENT_IDENTITY_POLICY.md`
- language-neutral artifact creation, Registration Authority, `DIRECT`/`DEFERRED`, concurrency, and human/AI allocation: `ARTIFACT_REGISTRATION_POLICY.md`
- central JSON registry v2, derived sequence allocation, object-level merge, Git-merge verification, cross-PR preflight, and generated planning views: `CENTRAL_ARTIFACT_REGISTRY_POLICY.md`
- semantic upgrade delta/applicability and mandatory recommendation surfacing: `UPGRADE_APPLICABILITY_POLICY.md`
- repository/CI availability, break-glass safety boundaries, and deferred validation: `REPOSITORY_CONTINUITY_POLICY.md`
- rule-context discovery, cache keys, dirty-worktree invalidation, partial reanalysis, and local-record safety: `RULE_CONTEXT_CACHE_POLICY.md`
- semantic feature catalog: `feature_catalog.json`
- registration schemas: `schemas/artifact-record.schema.json`, `schemas/artifact-registry.schema.json`, `schemas/artifact-registry-v2.schema.json`, `schemas/artifact-registration-request.schema.json`
- upgrade schemas: `schemas/feature-catalog.schema.json`, `schemas/upgrade-assessment.schema.json`
- rule-context cache record schema: `schemas/rule-context-cache.schema.json`
- authorization and working behavior: `WORKING_RULES.md`
- model/resource selection and target-policy mapping: `MODEL_ROUTING_POLICY.md`
- validation, status vocabulary, portable LF/CRLF drift semantics, infrastructure availability, and manual test plans: `VALIDATION_POLICY.md`
- data handling and narrow provenance exceptions: `DATA_PRIVACY_AND_CONFIDENTIALITY.md`
- safe operations: `SECURITY_AND_SAFE_OPERATIONS.md`
- documentation truth: `DOCUMENTATION_POLICY.md`
- third-party/licensing: `THIRD_PARTY_AND_LICENSING.md`
- evidence/sources: `SOURCE_AND_EVIDENCE_POLICY.md`
- dependencies/services: `DEPENDENCY_POLICY.md`
- machine-readable authority, integration, identity, registration, central-registry, upgrade, continuity, and validation index: `repo_map.yaml`

## Discovery boundary

Foundation rules are discoverable through root `AGENTS.md`. Active target-project governance must also remain transitively discoverable from the root repository instruction tree. Keep project discovery links outside the managed Foundation block and point to canonical project sources rather than copying their rule text.

An active authoritative target rule that is not discoverable is `ORPHANED_AUTHORITY` and is an integration defect even if the Foundation files themselves are present.

## Rule-context cache boundary

Native client discovery of the applicable global/project `AGENTS.override.md`/`AGENTS.md` chain runs again at the start of every new run or TUI session. A repository cache may accelerate only additional rule/context analysis after that chain and the complete applicable scope have been established.

`CACHE_HIT` requires exact validated repository/worktree/scope identity, instruction order, discovery configuration, source set, logical content, Git state, and dependency topology. `PARTIAL_INVALIDATION` rereads changed non-instruction rules plus every transitive semantic dependent. Instruction/scope/topology/source-set/schema/generator/corruption/uncertainty changes are `CACHE_MISS` and require a full context rebuild. UTF-8 LF/CRLF-only representation follows the portable text rule; all other content/encoding/final-newline differences remain significant.

Semantic analyses stay session-local under deterministic analysis keys. Optional persistent records contain fingerprints and dependency metadata only, remain local/non-versioned/non-authoritative, and are atomically replaced under a per-record lock. A hit cannot reuse an analysis that is not actually available under its validated key.

## Semantic integration boundary

Foundation integration supplements existing governance. Preserve `PROJECT_STRONGER`, `PROJECT_SELECTABLE_OVERRIDE`, and `COMPLEMENTARY` project behavior. Resolve `FOUNDATION_REQUIRED_CONFLICT`, distinguish `TARGET_INTERNAL_CONFLICT`, and do not remove adapter governance until it has been safely rehomed.

Existing identifier conventions and Registration Authorities are project governance. Preserve them by default when compatible. The Foundation identity default applies automatically only when no established convention exists, or prospectively after an explicit `ADOPT_FORWARD` decision. A historical migration requires `MIGRATE_EXPLICIT`; Foundation installation never performs one implicitly.

## Upgrade applicability boundary

When the target has an older installed Foundation version, compute the complete semantic feature delta from `feature_catalog.json` before declaring the upgrade complete. Every feature introduced or materially changed in the version interval receives exactly one applicability classification. `RECOMMENDED`, `DECISION_REQUIRED`, and `CONFLICT` results are surfaced explicitly; no feature may be silently skipped because its relevance was not inferred.

This requirement does not auto-authorize project-selectable changes. In particular, a relevant persistent-identity/nomenclature improvement may result in an `ADOPT_FORWARD` recommendation while historical identifiers remain untouched.

## Identity boundary

Persistent identity, human-readable reference, aliases/external references, mutable relations/classification, revision identity, and current locator are distinct concerns. Stable references are never reused for different artifacts. Hierarchy/status/location changes must not force canonical identity changes. Identifiers never grant authorization.

## Registration boundary

Humans and AI systems use the same project-selected Registration Authority for a given identifier scope. Final sequence references are allocated by that authority, not guessed by individual clients. `DIRECT` requires serialized or equivalent uniqueness; `DEFERRED` creates the final machine UID first and allocates the human reference later.

For repository-native JSON Registration Authorities, the Foundation default is `foundation-artifact-registry/v2`: complete artifact records are stored centrally, the canonical human reference is the object key, and the next sequence is derived from existing canonical keys rather than persisted as `next_sequence`. The v1 allocation-only registry remains a compatible legacy profile.

A central JSON registry is merged on JSON object/property semantics. Git's line-oriented merge result must be compared with the expected object-level three-way merge and rejected when the two differ. GitHub projects may select the optional `artifact-registry-github` capability for reference preflight and merge-gate tooling.

Python is not a required runtime. PowerShell remains a first-class supported reference client for the v1 compatibility profile. The optional capabilities are implementation aids; a project-specific compatible authority or implementation language takes precedence.

## Validation boundary

Foundation validation supplements rather than replaces the target repository's validation system. The Foundation validator covers `FOUNDATION_INTEGRITY` only. Project-specific semantic correctness remains under `PROJECT_SEMANTIC`; executable/empirical behavior remains under `RUNTIME_EMPIRICAL`. Existing project validators, static contracts, tests, reviews, and manual validation remain authoritative for those scopes when affected.

For UTF-8 Foundation text, LF and CRLF-only working-tree representations are equivalent for installation planning and drift detection. Do not create or modify target `.gitattributes` solely to silence Git EOL conversion. Lone CR, final-newline changes, actual content changes, and binary/non-UTF-8 differences remain significant.

A required check that ran and found a substantive defect is `VALIDATION_FAILURE` and must not be bypassed under break-glass policy. A check that cannot produce a trustworthy result because its external execution infrastructure is unavailable may be classified `INFRASTRUCTURE_UNAVAILABLE`; a project-defined break-glass path may then preserve repository continuity while keeping missing validation pending for post-recovery execution. `UNKNOWN` is non-bypassable until classified.

A local override or drift warning identifies a difference; it is not semantic approval of that difference. A green Foundation validator must never be used as evidence that the entire target project is validated.

## Repository continuity boundary

Mandatory CI can become an availability single point of failure when the repository is also the durable coordination channel. `REPOSITORY_CONTINUITY_POLICY.md` allows a narrowly audited break-glass path for infrastructure unavailability only. Preserve an auditable PR path, core branch safety, local evidence where available, residual-risk recording, and post-recovery validation. Never fabricate a successful check or silently configure target repository bypass permissions.

## Provenance and license notice

`AI_REPOSITORY_FOUNDATION_NOTICE.md` is not a target-project license. It preserves the MIT notice for the Foundation material copied into this repository. Keep that notice with the installed Foundation rules and any selected Foundation capability files; do not use it to replace or reinterpret the target project's own root license.

Read only the rules relevant to the current task. Repository-specific instructions and facts remain in the target repository; these Foundation files are a reusable baseline, not a replacement for project context.
