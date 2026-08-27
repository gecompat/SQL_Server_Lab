# Validation Policy

Status: AUTHORITATIVE

## Validation scopes

Validation is layered. The Foundation does not replace the target repository's own validation system.

- `FOUNDATION_INTEGRITY`: installation structure, required Foundation rules/provenance, adapters, deterministic Foundation contracts, and detectable drift.
- `PROJECT_SEMANTIC`: project-specific rules, local overrides, architecture, domain behavior, documentation contracts, data/model invariants, and other repository-specific semantics.
- `RUNTIME_EMPIRICAL`: tests, builds, integrations, runtime behavior, operational checks, research/data verification, and manual validation.

The Foundation validator establishes only `FOUNDATION_INTEGRITY` for an installed Foundation ruleset. It may detect that a local override or drift exists, but it cannot prove that the override is semantically correct for the target project. A green Foundation validator therefore does **not** mean that project-specific validation is green.

Existing target-project validators, static contracts, tests, reviews, and manual validation remain authoritative for their respective scopes. Installing or upgrading the Foundation must not delete, disable, weaken, or silently replace them. Select `PROJECT_SEMANTIC` and `RUNTIME_EMPIRICAL` checks impact-by-impact when the affected contract requires them.

## Portable text representation and drift

Foundation installation planning and installed-rule drift detection distinguish logical text content from platform-specific Git working-tree representation.

For UTF-8 text managed by Foundation, CRLF line endings produced by Git checkout settings such as `core.autocrlf` are normalized to LF before deciding whether content is unchanged or drifted. An LF/CRLF-only difference is therefore **not** `LOCAL_OVERRIDE_OR_DRIFT` and must not make an otherwise valid Foundation integration incomplete.

The normalization is deliberately narrow:

- CRLF and LF are treated as equivalent for UTF-8 text;
- lone CR characters remain significant;
- final-newline presence remains significant;
- non-UTF-8 or binary content remains byte-exact;
- any textual content change that remains after EOL normalization is real drift and must still be surfaced.

Do not create, replace, or modify a target repository's `.gitattributes` merely to make Foundation validation green when the only difference is LF versus CRLF. Preserve existing target line-ending governance. A target project may independently choose a namespaced `eol=lf` policy or stronger byte-stability rule when its own build/runtime/repository semantics require one; that choice belongs to `PROJECT_SEMANTIC`/repository administration rather than the Foundation integrity floor.

## Validation infrastructure availability

A required validation service can fail independently of the project being validated. Repository protection should therefore distinguish validation outcome from validation infrastructure availability according to `REPOSITORY_CONTINUITY_POLICY.md`.

Classify a blocked required check as one of:

- `VALIDATION_FAILURE`: the check ran and found a substantive defect. This result may not be converted into success or bypassed under break-glass policy.
- `INFRASTRUCTURE_UNAVAILABLE`: the check cannot produce a trustworthy result because the CI/runners/platform are unavailable or materially degraded. A project-defined break-glass path may be used when authorized.
- `UNKNOWN`: the cause is not established. Treat as non-bypassable until classified.

A break-glass merge does not make missing validation green. The bypassed validation remains pending and must be executed after service recovery. Record the outage evidence, locally reproduced checks, residual risk, immutable revision, and post-recovery validation obligation.

Projects may use stronger continuity controls or no break-glass path at all. Foundation transfer does not silently create repository bypass permissions or weaken existing branch/ruleset protection.

## Validation progression

Use the smallest local, reproducible method that reliably tests the affected contract:

1. reproduction or characterization;
2. focused validation;
3. affected regression or consistency checks;
4. structural/static checks;
5. integration or runtime validation;
6. stable completion gate.

Determine affected artifacts and consumers before selecting checks. Prefer existing tools, synthetic/redistributable fixtures where suitable, mocks, and offline checks. CI confirms a stable result; it is not the primary debugging environment.

Validation applies equally to software, data, research, and documentation: tests, schemas, calculations, links, sources, citations, dates/versions, samples, consistency, reproducibility, and review may all be evidence.

## Evidence

Evidence records contain, as relevant:

- method;
- validation scope (`FOUNDATION_INTEGRITY`, `PROJECT_SEMANTIC`, or `RUNTIME_EMPIRICAL`);
- affected contract;
- environment/platform;
- command or procedure;
- result;
- date;
- limitations.

## Status vocabulary

The following Foundation meanings are reserved and must not be weakened or redefined:

- `not executed`: no required procedure was run.
- `pending manual validation`: an executable manual plan exists but has not been completed.
- `validated`: the stated procedure actually ran and met its pass criteria for the stated scope only.

Target repositories may define additional statuses such as `partially validated`, `failed`, `not applicable`, `inconclusive`, or domain-specific equivalents. Such extensions are compatible when their meanings are documented and they do not cause unexecuted, failed, partial, or inapplicable work to be represented as `validated`.

A project may keep an existing richer status vocabulary; it does not need to replace it with only the three Foundation terms. When reporting across repositories, preserve the exact target status and map to a Foundation reserved meaning only when the semantics genuinely match.

When human execution is required, create an exact step-by-step manual validation plan containing: ID, objective, contract/risk, prerequisites, environment, initial state, ordered steps, exact commands/UI actions, expected results, pass/fail criteria, outputs to return, cleanup/recovery, limitations, and residual risk. A plan is not evidence that the test passed.

A test with external effects, cost, production impact, or mutation may run without an additional confirmation when that effect is an ordinary and clearly authorized part of the current task's authorization envelope. Gate only effects that exceed the envelope, have ambiguous targets, introduce material unapproved cost, or are destructive/irreversible without exact authority.
