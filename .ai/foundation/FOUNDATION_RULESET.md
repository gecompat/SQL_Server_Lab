# AI Repository Foundation Ruleset

Status: AUTHORITATIVE BASELINE
Ruleset version: 1.18.0

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
- repository/CI availability, break-glass safety boundaries, deferred validation, and project-selectable supersession/queue controls: `REPOSITORY_CONTINUITY_POLICY.md`
- rule-context discovery, cache keys, dirty-worktree invalidation, partial reanalysis, and local-record safety: `RULE_CONTEXT_CACHE_POLICY.md`
- runtime-neutral AI work requests, capability discovery, isolated degradation, risk-gated validation, and provisioning boundaries: `AI_WORK_ORCHESTRATION_POLICY.md`
- semantic feature catalog: `feature_catalog.json`
- registration schemas: `schemas/artifact-record.schema.json`, `schemas/artifact-registry.schema.json`, `schemas/artifact-registry-v2.schema.json`, `schemas/artifact-registration-request.schema.json`
- upgrade schemas: `schemas/feature-catalog.schema.json`, `schemas/upgrade-assessment.schema.json`
- installed provenance schema: `schemas/installation-provenance.schema.json`
- rule-context cache record schema: `schemas/rule-context-cache.schema.json`
- model-routing schemas: v1 request/decision/catalog/snapshot/profiles plus `schemas/model-routing-request-v2.schema.json`, `schemas/model-routing-decision-v2.schema.json`, and `schemas/model-router-catalog-fragment-v2.schema.json`
- AI work schemas: `schemas/ai-work-request.schema.json`, `schemas/capability-descriptor.schema.json`, `schemas/execution-plan.schema.json`, `schemas/execution-report.schema.json`, `schemas/execution-checkpoint.schema.json`, `schemas/approval-receipt.schema.json`, `schemas/validation-evidence.schema.json`, `schemas/gap-report.schema.json`, `schemas/provision-plan.schema.json`, `schemas/provision-request.schema.json`, `schemas/provision-approval.schema.json`, `schemas/provision-report.schema.json`, `schemas/runtime-inventory.schema.json`, `schemas/ai-adapter-protocol.schema.json`, `schemas/ai-runtime-configuration.schema.json`, `schemas/resource-cost-evidence.schema.json`, `schemas/client-integration-plan.schema.json`, `schemas/client-model-routing-capability.schema.json`, `schemas/vscode-model-routing-plan.schema.json`, `schemas/manual-handoff.schema.json`, `schemas/dispatch-receipt.schema.json`, `schemas/adapter-synthesis-report.schema.json`, `schemas/model-runtime-evidence.schema.json`, `schemas/model-evidence-sources.schema.json`, `schemas/ai-orchestration-request.schema.json`, and `schemas/ai-orchestration-report.schema.json`
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

Every selected transfer file has a portable source hash in the source manifest. `.ai/foundation/installation-provenance.json` records the exact ruleset/manifest identity and installed hashes after deterministic installation or completed semantic integration. Validation distinguishes `UNCHANGED_CURRENT_BASELINE`, `INTENTIONAL_OVERRIDE`, `PREVIOUS_FOUNDATION_VERSION`, and `UNKNOWN_DRIFT`. A receipt or override classification identifies provenance only; it is not semantic approval or project validation. A green Foundation validator must never be used as evidence that the entire target project is validated.

## Model-routing boundary

The portable routing tiers do not name a provider or current model. If dynamic routing is selected, filter privacy, authorization, capability, context, quality, price freshness, and budget before minimizing expected cost of success. Decisions carry a pricing epoch and expiry, session affinity remains conditional, and new models remain `UNASSESSED` until bounded project-authorized evaluation provides enough evidence.

The optional `model-router` capability keeps `foundation-model-router/v1` compatible and adds a v2 facade with explicit execution boundaries, evidenced resources, and independently expiring provider fragments. Complete bounded attempt chains minimize expected cost of success. Documented measured/configured resource costs may enter that monetary objective; otherwise resource pressure is a tie-breaker only. The capability includes runtime Ollama Cloud discovery, CLI, local stdio MCP, shell-free launcher, and expiring snapshots. Runtime state stays outside version control, credentials are never stored, and lower integration layers preserve the same fail-closed decision contract. A requested model is not an actual-model attestation; absent matching host execution/response evidence from an explicitly trusted issuer, report `REQUESTED_NOT_ATTESTED` and fall back to a privacy-safe expiring manual handoff or portable tier.

## AI work orchestration boundary

`foundation-ai-work/v1` describes work, capabilities, plans, reports, evidence, gaps, and provisioning without requiring an executable runtime. Payload content travels through short-lived handles outside the control plane and is not logged or persisted by default. Capability discovery never grants authority; effective permissions remain the intersection of project policy, caller authorization, request effects, adapter needs, and the execution environment.

Apply privacy, authorization, capability, health/freshness, validation, time, money, and resource limits before ranking. One failing or expired component excludes only that component. Return `EXECUTABLE`, `MANUAL_REQUIRED`, `UNAVAILABLE`, or `BLOCKED` truthfully. Deterministic tools precede models when they sufficiently and verifiably perform the work. Human approval is grouped at irreversible, sensitive, unbudgeted, high-impact, privilege-expanding, or insufficient-evidence boundaries.

The optional `ai-work` capability is a decision-only Python reference planner. The separately selectable `ai-runtime-adapters` capability implements the content-free JSONL/stdio protocol for Ollama local/cloud, OpenAI-compatible HTTP, and shell-free command clients. It also offers an external named-connection store, a detect/propose/edit/test/save/verify/rollback question-and-answer assistant, and a failure-isolated stdio MCP invocation bridge. With no configuration the MCP server remains available and reports `CONFIGURATION_REQUIRED`; discovery may probe only bounded loopback defaults automatically and never saves, asserts trust, enables remote models, or contacts a non-loopback candidate without authority. Credential values are never stored—only explicit environment or dotenv path/key references—and `ROUTER`/`MANUAL` model modes never invent a model. The `ai-executor` capability optionally adds exact-plan revalidation, grouped approval receipts, content-free checkpoints, bounded alternatives, idempotency-aware recovery, measured limits, and validation evidence. The optional `ai-provisioning` capability diagnoses and inventories runtimes, creates expiring content-addressed provision plans, executes only exactly approved bounded downloads/offline installation, verifies results, and refreshes isolated cost evidence no more than once per source per day. The optional `ai-client-integration` capability semantically integrates distinct Codex/Visual Studio/GitHub Copilot/generic paths, consumes expiring native client-model-routing capabilities, creates read-only VS Code role/subagent plans from live inventories, verifies requested-versus-actual dispatch evidence, emits content-separated manual handoffs, and materializes explicitly authorized least-privilege local adapters outside Git in quarantine until conformance succeeds. The optional `ai-orchestrator` capability composes isolated live catalogs, fresh external source-backed model evidence, router-v2 selection, content-handle invocation, deterministic validation, bounded fallbacks, and content-free reports; missing evidence, runtime configuration, or model attestation yields a truthful manual/unavailable result rather than an invented route or execution claim. Python, MCP, Ollama, models, providers, adapters, executors, provisioners, client integrators, and orchestration remain optional; rules and schemas stay valid without all of them. Runtime state, payloads, credentials, host paths, client backups, live inventories, model evidence, and orchestration reports stay outside version control.

## Repository continuity boundary

Mandatory CI can become an availability single point of failure when the repository is also the durable coordination channel. `REPOSITORY_CONTINUITY_POLICY.md` allows a narrowly audited break-glass path for infrastructure unavailability only. Preserve an auditable PR path, core branch safety, local evidence where available, residual-risk recording, and post-recovery validation. Never fabricate a successful check or silently configure target repository bypass permissions.

## Provenance and license notice

`AI_REPOSITORY_FOUNDATION_NOTICE.md` is not a target-project license. It preserves the MIT notice for the Foundation material copied into this repository. Keep that notice with the installed Foundation rules and any selected Foundation capability files; do not use it to replace or reinterpret the target project's own root license.

Read only the rules relevant to the current task. Repository-specific instructions and facts remain in the target repository; these Foundation files are a reusable baseline, not a replacement for project context.
