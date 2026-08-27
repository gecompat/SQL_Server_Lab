# Semantic Integration Policy

Status: AUTHORITATIVE

## Purpose

Installing or upgrading the Foundation in an existing repository is a semantic integration, not a text-replacement exercise. The Foundation adds a reusable baseline while the target repository remains authoritative for project facts, domain rules, architecture, project-selected policies, validation, implementation, established identifier history, and compatible Registration Authorities.

Existing project rules do not need to be renamed or rewritten into Foundation terminology merely to integrate the Foundation.

## Discovery invariant

Root `AGENTS.md` is the canonical AI discovery entry point after integration.

- Foundation rules must be reachable from root `AGENTS.md` through `.ai/foundation/FOUNDATION_RULESET.md`.
- Active project-specific authoritative governance must be transitively discoverable from root `AGENTS.md`, either by direct links, an existing project router/index, or an explicitly documented scoped-`AGENTS.md` convention.
- Keep discovery concise. Link to canonical project sources; do not duplicate their rule text into the Foundation block.
- Historical, superseded, examples, generated evidence, and other non-authoritative material do not need to be promoted into the active discovery tree.
- `ORPHANED_AUTHORITY` means an active authoritative project rule exists but is not discoverable through the repository instruction/discovery tree. Resolve it before declaring semantic integration complete.

If the target already has a machine-readable repository map, preserve its schema and content. Add a minimal reference to `.ai/foundation/repo_map.yaml` only when the target map's schema safely supports such an extension; otherwise rely on the root discovery path. Never replace a target repo map with the Foundation map.

## Semantic compatibility classes

Classify meaningful overlaps between Foundation and target governance with one of these classes:

- `EQUIVALENT`: materially equivalent semantics; keep the target's canonical wording.
- `PROJECT_STRONGER`: the target intentionally imposes a stricter compatible constraint; preserve it.
- `PROJECT_SELECTABLE_OVERRIDE`: the target intentionally chooses a different value for a Foundation `DEFAULT` or `PROJECT_SELECTABLE` area; preserve the choice.
- `COMPLEMENTARY`: both rules apply to different aspects and can coexist.
- `DUPLICATE_GOVERNANCE`: the same active rule is maintained independently in multiple places; choose a canonical source and reduce duplication.
- `FOUNDATION_REQUIRED_CONFLICT`: the target weakens or contradicts a Foundation `REQUIRED` minimum in safety, privacy, integrity, evidence, authorization, identity, registration, or upgrade completeness; resolve before completion.
- `TARGET_INTERNAL_CONFLICT`: target-project rules already contradict each other independently of the Foundation; report separately.
- `ORPHANED_AUTHORITY`: active project governance is not discoverable from the instruction tree.
- `ADAPTER_GOVERNANCE_MISPLACED`: a tool adapter contains substantive governance; preserve/rehome it before thinning the adapter.

## Stricter project rules

Foundation `REQUIRED` rules define a minimum protected behavior, not a maximum level of restriction. A project may intentionally be stricter. A stricter rule is not a conflict merely because it permits fewer actions; it becomes a conflict only when the combined rules are logically incompatible or the target weakens a protected Foundation minimum.

## Semantic upgrade applicability

Read `UPGRADE_APPLICABILITY_POLICY.md` and `feature_catalog.json` whenever the target has an older installed Foundation version than the exact source ref being applied.

Before deciding which new Foundation behavior to adopt:

1. determine installed target and source Foundation versions separately;
2. compute every feature introduced or materially changed in the version interval;
3. inspect target evidence for every candidate;
4. assign exactly one upgrade assessment classification to every candidate;
5. explicitly surface `RECOMMENDED`, `DECISION_REQUIRED`, and `CONFLICT` results;
6. only then apply normal semantic compatibility and file-merge rules.

No candidate may disappear from the assessment merely because an AI did not infer its relevance. `NOT_APPLICABLE` requires evidence/rationale; silence is not a classification.

The upgrade applicability classification and the semantic compatibility class answer different questions. For example, `persistent-identity` may be `RECOMMENDED` as an upgrade feature while the existing project naming rules are simultaneously `PROJECT_SELECTABLE_OVERRIDE` or `ALREADY_EQUIVALENT` at the feature-assessment layer.

## Persistent identifier interoperability

Read `PERSISTENT_IDENTITY_POLICY.md` when the target uses durable planning, decision, requirement, risk, test, release, incident, operational, or other cross-referenced identifiers.

Existing identifier history is target-owned governance and traceability. Distinguish:

- no established durable convention: the Foundation default applies unless another compatible profile is selected;
- established convention: default to `PRESERVE` unless an explicit project decision selects prospective adoption;
- explicit migration decision: use `MIGRATE_EXPLICIT` with durable old-to-new mappings and validation.

Do not treat a more descriptive Foundation reference as justification to rename historical IDs. When the Foundation model is materially better for future work, recommend `ADOPT_FORWARD`: preserve historical IDs and use the improved profile prospectively. A missing user/project decision is not permission to migrate: `unknown -> PRESERVE`.

Identifier syntax and current hierarchy are separate concerns. Existing forms such as `W3-017`, `S-FUT11-04`, Jira-style keys, or project-specific decision IDs may remain valid even when encoded phase/parent information becomes historical. Add explicit metadata/relations instead of rewriting identity merely to make the string reflect current structure.

## Registration Authority interoperability

Read `ARTIFACT_REGISTRATION_POLICY.md` when the target allocates or creates final human references.

An existing issue tracker, database allocator, local registry, project application, PowerShell module, Python tool, or other allocator is project governance when it is the established Registration Authority. Preserve it when compatible.

- Do not install Foundation reference clients merely because the registration policy is transferred.
- Do not replace an existing allocator with Python, PowerShell, or a Foundation registry for terminology consistency.
- Humans and AI systems must resolve to the same authority for the same identifier scope.
- A project may select a different implementation language without creating a Foundation conflict.
- If multiple allocators overlap the same final-reference scope, determine whether the target already has a `TARGET_INTERNAL_CONFLICT`; do not choose one silently.
- If the target adopts Foundation sequential references but lacks a safe allocator, establish the Registration Authority before publishing final references.
- `DIRECT` and `DEFERRED` are semantic allocation modes, not requirements to use Foundation reference clients.

A richer central issue tracker or service may be preferable to the Foundation local reference registry for multi-user/network-concurrent repositories. That is compatible.

## Adapter migration

When an existing adapter contains substantive project rules:

1. identify unique governance content before editing the adapter;
2. preserve it in an existing canonical project source, or create a project-owned canonical source when authorized;
3. update discovery so the relocated rule remains reachable;
4. only then reduce the adapter to a thin discovery bridge;
5. if safe rehoming cannot be determined, keep the existing rule and report `ADAPTER_GOVERNANCE_MISPLACED`.

## Existing policy interoperability

More detailed target policies remain valid. The Foundation provides stable cross-project semantics, not a requirement to discard richer project policy.

- Existing validation statuses may extend Foundation reserved meanings as defined by `VALIDATION_POLICY.md`.
- Existing model/cost policies may remain more detailed and map semantically to Foundation routing tiers.
- Existing privacy scanners may be stricter; legally required Foundation provenance uses the narrow exception described by `DATA_PRIVACY_AND_CONFIDENTIALITY.md`, not a global weakening.
- Existing identifier conventions remain valid when they preserve stable meaning and no-reuse.
- Existing Registration Authorities remain valid when they preserve uniqueness, no-reuse, mapping durability, and safe concurrency for their scope.

## Completion

Semantic integration is complete only when:

- selected Foundation core material and explicitly selected optional capabilities are installed or intentionally merged;
- when upgrading from an older Foundation version, the complete semantic feature delta is assessed with no silent omissions;
- all `RECOMMENDED`, `DECISION_REQUIRED`, and `CONFLICT` feature results are surfaced and durable project choices are recorded when required;
- active project governance remains intact and discoverable;
- meaningful overlaps have a compatible classification or resolved conflict;
- unique adapter governance has not been lost;
- project-specific validation/model/privacy/license/identifier/registration contracts remain preserved;
- any identifier adoption mode is explicit and historical references remain resolvable;
- the Registration Authority is discoverable when final project references are created or allocated;
- optional Foundation reference clients have not displaced a compatible project allocator without an explicit decision;
- `FOUNDATION_INTEGRITY` validation remains separated from `PROJECT_SEMANTIC` and `RUNTIME_EMPIRICAL` validation.
