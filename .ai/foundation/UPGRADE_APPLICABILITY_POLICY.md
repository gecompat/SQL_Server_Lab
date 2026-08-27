# Semantic Upgrade Applicability Policy

Status: AUTHORITATIVE

## Purpose

A Foundation upgrade is not complete merely because newer files can be copied into a target repository. The upgrade must also identify Foundation features introduced or materially changed since the target's installed ruleset version, assess each feature against the target repository, and surface relevant improvements or decisions explicitly.

This policy prevents a feature from being silently skipped because an AI, human, installer, or review process did not infer that the feature was relevant.

## Rule classes

- `REQUIRED`: every upgrade from an older installed Foundation version evaluates the complete semantic feature delta and records one assessment classification for every candidate feature.
- `DEFAULT`: relevant backward-compatible improvements are recommended rather than silently ignored; existing compatible project governance remains preserved.
- `PROJECT_SELECTABLE`: the project decides selectable governance choices such as future identifier convention, Registration Authority, optional capabilities, or an explicitly planned migration.

## Sources of truth

For an upgrade:

1. `foundation/manifest.json#ruleset_version` at the exact Foundation source ref is the source version authority.
2. `foundation/feature_catalog.json` at that same source ref is the semantic feature catalog.
3. The target's installed `.ai/foundation/repo_map.yaml` provides the installed target Foundation version when available.
4. Target repository state provides applicability evidence and remains authoritative for project-specific facts and existing governance.

Do not use an older installed target copy as evidence of what the current Foundation source contains.

## Complete feature-delta invariant

For an upgrade from version `A` to version `B`, a catalog feature is a candidate when:

- its `introduced_in` version is greater than `A` and less than or equal to `B`; or
- a `change_history` entry with `impact: MATERIAL` has a version greater than `A` and less than or equal to `B`.

Every candidate MUST receive exactly one assessment classification before the semantic upgrade plan is considered complete.

A candidate MUST NOT be omitted merely because:

- its policy file was not already installed in the target;
- the target uses different terminology;
- the AI did not spontaneously infer its relevance;
- another feature appears more important;
- the feature is project-selectable rather than mandatory;
- the target already has a superficially similar mechanism.

`not assessed`, omission, silence, or absence from the report are not valid classifications.

## Assessment classifications

Use exactly one classification for every candidate:

- `NOT_APPLICABLE`: the feature does not apply to the target, with repository evidence explaining why.
- `ALREADY_EQUIVALENT`: target governance already provides materially equivalent behavior; preserve the target's canonical implementation.
- `PROJECT_STRONGER`: the target intentionally provides stricter or stronger compatible behavior; preserve it.
- `APPLY_DEFAULT`: the Foundation behavior applies without a material project choice and should be integrated normally.
- `RECOMMENDED`: the feature is applicable and beneficial; surface the recommendation explicitly even if adoption remains optional.
- `DECISION_REQUIRED`: the feature is applicable but a durable project choice must be resolved before the affected behavior changes.
- `CONFLICT`: target behavior and the Foundation requirement/default cannot be safely reconciled without explicit resolution.

A classification requires evidence or rationale sufficient for another human or AI to understand why it was selected.

## Recommendation and decision separation

Applicability, recommendation, and authorization are different concepts.

A feature can be `RECOMMENDED` without being automatically adopted. A feature can be `DECISION_REQUIRED` while the safest current behavior remains preservation. Existing migration and authorization boundaries continue to apply.

Examples:

- A better future identifier convention may be recommended while historical identifiers remain unchanged.
- A stronger project-specific validator may be retained as `PROJECT_STRONGER`.
- An optional reference-client capability may be `NOT_APPLICABLE` when an existing central Registration Authority is preferable.

## Applicability evidence

The feature catalog provides structured signals and questions. Consumers use repository evidence to answer them; signal names are semantic hints, not a requirement for one implementation or scanner.

Evidence may come from:

- planning/backlog identifiers and naming rules;
- decisions, requirements, risks, tests, releases, and incident records;
- root/scoped AI governance and repo maps;
- issue trackers and Registration Authority configuration;
- validation/model/privacy/security/dependency policies;
- actual file/tool/runtime structure when relevant.

Do not classify a feature `NOT_APPLICABLE` merely because evidence was not searched. If required evidence is genuinely unavailable, report the uncertainty and use `DECISION_REQUIRED` when the unresolved choice materially affects adoption.

## Persistent identity and nomenclature

The `persistent-identity` feature MUST be assessed when a target contains durable planning, decision, requirement, risk, test, release, incident, operational, or similar cross-referenced identifiers.

When the existing convention is compatible but materially weaker than the Foundation layered model, surface `ADOPT_FORWARD` as the preferred recommendation: preserve all historical references and use the improved convention prospectively. Do not require the user to remember to ask about nomenclature.

When the existing convention is materially equivalent or stronger, classify it `ALREADY_EQUIVALENT` or `PROJECT_STRONGER` and preserve it. Historical migration remains `MIGRATE_EXPLICIT` only.

## Artifact registration

The `artifact-registration` feature MUST be assessed when humans or AI create durable artifacts with final human references, especially sequential references.

If a compatible centralized issue tracker, database, service, or project allocator already provides safe uniqueness, classify it according to its semantics rather than replacing it with Foundation reference clients. If the project adopts Foundation-style sequential references without a safe allocator, recommend establishing one Registration Authority and use `DEFERRED` where allocation cannot safely be serialized at creation time.

## Material changes versus non-material maintenance

Each catalog feature records `change_history` entries. `MATERIAL` changes re-enter the upgrade delta for targets older than that change. `NON_MATERIAL` entries record review/maintenance without forcing target reassessment.

A Foundation source change to transferable material MUST be reviewed against the feature catalog in the same ruleset version. The source-project feature-catalog guard enforces this review contract for managed transferable files.

## Upgrade assessment output

An upgrade assessment SHOULD use the transferred `upgrade-assessment.schema.json` or an equivalent project representation containing at least:

- installed Foundation version;
- source Foundation version/ref;
- every candidate feature ID and candidate reason;
- exactly one classification per candidate;
- repository evidence/rationale;
- recommendation when applicable;
- any required project decision;
- selected optional capabilities when relevant.

The assessment may be ephemeral for a trivial upgrade. It becomes durable project governance when it records a material project choice, migration mode, permanent override, or another decision that future work must know.

## AI upgrade behavior

When an AI upgrades an existing repository:

1. resolve the exact Foundation source ref/version;
2. determine the target's installed Foundation version;
3. compute the complete feature delta from `foundation/feature_catalog.json`;
4. inspect target evidence for every candidate feature;
5. assign exactly one assessment classification to every candidate;
6. explicitly surface all `RECOMMENDED`, `DECISION_REQUIRED`, and `CONFLICT` items;
7. do not silently adopt a project-selectable change or historical migration;
8. preserve `ALREADY_EQUIVALENT` and `PROJECT_STRONGER` target behavior;
9. integrate `APPLY_DEFAULT` items through normal semantic merge rules;
10. report the completed assessment together with the file/transfer plan and validation scopes.

If the target version is unknown, do not assume it equals the source version. Treat all catalog features as requiring version-baseline resolution or conservative assessment; never use uncertainty to silently skip newer governance.

## Completion

A Foundation upgrade is semantically complete only when:

- source and installed target versions are distinguished;
- the complete catalog delta is computed;
- every candidate has exactly one valid classification;
- relevant recommendations and decisions are surfaced;
- explicit project choices are recorded when durable;
- normal semantic integration and validation requirements are satisfied.

A green file-transfer plan without this assessment is not sufficient evidence of a complete upgrade from an older Foundation version.
