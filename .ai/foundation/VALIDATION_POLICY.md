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

## Installed provenance and drift classification

Every manifest transfer row carries a portable SHA-256 computed with the same LF/CRLF rule. A completed deterministic installation or direct semantic transfer records `.ai/foundation/installation-provenance.json` using `foundation-installation-provenance/v1`. The receipt identifies the exact ruleset, source repository, source commit when available, source-manifest hash, selected modules, and the source/installed hash of every selected target.

Classify installed content as exactly one of:

- `UNCHANGED_CURRENT_BASELINE`: content equals the current manifest source hash;
- `INTENTIONAL_OVERRIDE`: content differs from the current source but equals a current-version receipt that explicitly records the target, installed hash, and non-empty semantic-merge reason;
- `PREVIOUS_FOUNDATION_VERSION`: content equals its internally consistent receipt and that receipt identifies an older ruleset;
- `UNKNOWN_DRIFT`: content, receipt, version, manifest hash, or file metadata cannot be reconciled with the other classifications.

Missing or malformed provenance never upgrades a difference into an intentional override. A receipt is content provenance, not semantic approval, authority, a signature, or proof that project validation passed. Record an override only after the semantic merge is complete; a later unrecorded edit becomes `UNKNOWN_DRIFT`. Never include prompts, responses, credentials, host paths, or private runtime state in the receipt.

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

## Phases and repeated execution

Distinguish diagnosis/development, integration of a bounded change, qualification of the declared support scope, and release. A focused diagnosis does not claim qualification. A bounded fix does not automatically acquire all still-open module/platform/release obligations; run the checks needed for its affected contract and retain unperformed qualification cases as open. Qualification matrices, required statistical repetitions, version coverage, and release gates remain project-owned until explicitly amended.

Map expensive checks to affected inputs, contracts, and consumers using existing project selectors/workflows. Include source, tests, fixtures, generators, configuration, common dependencies, and relevant environment/freshness in the binding. A wide path filter alone should not force unrelated runtime matrices when a reliable narrower selector exists. Unknown dependency or effect information falls back conservatively to the broader check. Test selector changes with relevant positive, negative, common-dependency, and unknown-input cases; do not simply suppress required CI statuses.

Distinguish a validator's self-test from running that validator against current project inputs. Self-tests are warranted by changes to the tool, its dependencies/configuration/runtime, a new finding, or an explicit periodic/qualification requirement; an unrelated PR alone does not establish that need. Combine identical direct/suite validator executions at the same binding without dropping distinct assertions or negative controls. A repeated expensive check requires a changed relevant binding, new finding, required freshness/repetition, or previously unmet gate.

Keep required current-head/integration checks visible. Only an explicitly supported gate may reuse prior evidence after proving relevant input/environment/freshness equivalence; record the original execution and current applicability, never claim a fresh execution. Preserve failed results and safe cleanup/cancellation boundaries. Workflow summaries distinguish executed, reused, not applicable, failed, and unknown work without treating skipped or inconclusive checks as validated.

The REQUIRED overhead assessment in `PROCESSING_EFFICIENCY_POLICY.md` checks whether target rules and actual execution implement these defaults or justify compatible exceptions. It covers tests and the log/review/model work surrounding them; fewer tests do not justify weaker correctness claims.

## Review effort

Independent review is required when selected by the project, user, or affected risk. Additional reviewers need a distinct unresolved question, stable inputs, and acceptance criteria. A review report does not automatically require review of that report. Verify hashes, counts, manifest consistency, exact commit binding, and repeatable receipt properties deterministically. Review semantic changes and genuinely new findings with the appropriate model/human capability. Preserve required gates and source-bound evidence; never treat model agreement as deterministic proof.

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
