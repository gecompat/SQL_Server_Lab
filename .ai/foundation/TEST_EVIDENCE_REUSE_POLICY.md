# Test Evidence Reuse Policy

Status: AUTHORITATIVE — REQUIRED evidence floor when reuse is selected; DEFAULT economic selection; PROJECT_SELECTABLE activation

## Scope and ownership

A project MAY recognize a completed test in a different validation context without repeating its native execution. Reuse requires an explicitly supported project gate and independently verified evidence for the current request. Ordinary local and CI execution remain available without a reuse adapter, trust service, model, network, or particular implementation language.

Foundation defines the proof obligations below. The project selects test scopes, oracles, relevant environments, freshness, trust authorities, integration gates and any mandatory independent review. A protected host/CI adapter authenticates execution evidence and publishes status only under existing project authority. Installing this policy neither implements such an adapter nor activates reuse or repository permissions.

Use this policy with `VALIDATION_POLICY.md`, `PROCESSING_EFFICIENCY_POLICY.md`, `SOURCE_AND_EVIDENCE_POLICY.md`, and the existing privacy/security rules. It does not replace qualification, statistical repetition, release, cleanup, or human-acceptance requirements.

## Separate the claims

Preserve four distinct assertions: a test executed and produced a result; its producer and evidence are trusted for the scope; the evidence is equivalent for the current gate; and that gate accepted reuse. None implies the next without verification. Reuse is not a second execution and must not be reported as remote execution.

A content hash proves a content binding, not trustworthy execution. A self-written PASS file, model statement, `independent: true`, installation receipt, checkpoint or signed statement from an unauthorized identity is insufficient. Artifact build provenance alone does not prove test oracles, runtime behavior or cleanup. Required failed, incomplete, inconclusive, unavailable or unexecuted work cannot become a pass through aggregation or reuse.

## Trust boundary

Assume an author or model can modify proposed source, tests, result files and PR workflow code. The producer's execution observation, signing/attestation authority, trust configuration and verifier must be protected from that control. Independence is an enforced authority boundary, not a second process, machine name, role label or model agreeing with the first.

Authenticate the evidence bytes and issuer using the project's existing trust mechanism. Verify that the issuer is authorized for this repository, test and execution environment, with applicable expiry, revocation and replay rules. A valid signature without issuer authority is insufficient. Do not invent a key service or universal trust infrastructure. When no appropriate protected producer/verifier exists, retain ordinary validation and report reuse as unavailable.

The verifier and its policy must come from a trusted context; unreviewed PR code must not authorize itself. Do not expose privileged verifier credentials to candidate code. Recheck trust validity and current request binding before accepting or publishing the result. A changed request, runtime or trust configuration invalidates a prepared decision when it affects its proof obligations. Ambiguous outcomes require reconciliation, not a fabricated status or blind replay of effects.

## Required equivalence

The project gate defines a complete, deterministic dependency/impact mapping. Bind evidence to all relevant inputs below; unknown dependencies require broader validation rather than an optimistic exclusion.

| Binding | Required proof |
| --- | --- |
| Request | Repository identity, required gate IDs and current revision/integration context, including event/ref when material. |
| Source and build | Effective source/build tree, generated artifacts, configuration, lockfiles and transitive dependencies actually consumed. Include dirty/untracked inputs when they can affect local execution; a commit alone does not describe them. |
| Test contract | Stable test IDs, test/oracle implementation, runner/harness version, selected scope, parameters, fixtures, expected outputs, required repetitions and negative controls. |
| Environment | Relevant OS, runtime/provider/engine versions, image digest, permissions, security/TLS/credential-policy profile and external state. Domain-specific dimensions such as database build, compatibility level and collation are project-owned. Never record credential values. |
| Result and completion | Actual complete outcomes for every required oracle, including result counts where material, final status, resource ownership, termination and required cleanup. Exit code zero alone is insufficient. |
| Origin and validity | Authorized producer and execution identity, integrity of the complete evidence, observation time, freshness/expiry and current trust/revocation checks. Environment drift must be detectable independently of Git changes. |

Environment equivalence need not mean identical machines, but a project-approved equivalence rule must justify every admitted difference. Unknown or unobserved state does not match. Irrelevant changes may be ignored only through the trusted dependency mapping. A change to the verifier, trust policy or mapping itself requires authorized validation before the changed rule can recognize evidence.

Freeze or identify the inputs actually tested and revalidate their binding at acceptance to prevent time-of-check/time-of-use substitution. Bind the accepted decision to the current gate request even when test inputs legitimately remain equivalent across revisions. Combine evidence per gate without hiding failed or missing obligations; invalidate and rerun only affected gates when the mapping is complete. Required fresh executions and repetitions remain required.

## Deterministic decision procedure

Use existing runners and report interfaces. Equivalent project vocabulary is allowed when its semantics are documented; these are reuse decisions, not additions to an existing test-result enum.

| Decision | Conditions and next action |
| --- | --- |
| `NOT_REQUIRED` | Trusted impact selection establishes that this gate does not apply. Record why; do not count an executed or passed test. |
| `REUSED_VERIFIED` | The gate permits reuse and all trust, successful completion, equivalence and freshness obligations pass. Record original execution and current acceptance separately. Satisfy the current required status through the authorized adapter. |
| `EXECUTE_REQUIRED` | Reuse is unsupported, uneconomic, missing, expired, invalid or non-equivalent, or a fresh execution is required. Run the existing check when authorized. An invalid reuse candidate never authorizes success. |
| `UNAVAILABLE`, `BLOCKED` or `UNKNOWN` | The required evidence, capability, authority or cause cannot be established and normal execution cannot resolve it within the current envelope. Keep the gate unmet and expose the actual reason. |

Evaluate applicability, reuse support/economics, authenticity/authority, complete successful results, equivalence, freshness and current gate binding deterministically. Preserve rejection reasons and any known failures. A fallback execution must meet the existing gate's retry and failure-resolution rules. A model may diagnose an unresolved semantic problem; it cannot attest execution or replace a required proof.

For inexpensive static checks, fresh independent execution often costs less than collecting and verifying attestations. Prefer reuse for expensive checks only when the avoided work justifies verification, transport and maintenance. Local-first is a default when the authorized local environment is suitable, not a requirement to move trusted CI work onto an unsuitable or untrusted host.

## Adapter interface and result reporting

A project adapter accepts the current gate request, original evidence and protected trust/equivalence policy. It returns a decision, stable reason codes, verified bindings, original execution reference/time, verification reference/time, limitations and outstanding obligations. These are semantic interface requirements, not a new Foundation wire schema or executable verifier. Reject unknown or incompatible evidence versions safely. Do not add a second evidence or planning registry merely to implement this interface.

Keep execution result, execution origin, reuse decision and current CI publication state separate. `REUSED_VERIFIED` alone is not evidence that the required CI check was published or completed. A compact report contains required/completed/failed/unresolved gates and test counts where reliably available, source/test binding, cleanup, duration and evidence references. Never copy example counts into real results or count a reused test twice.

On complete deterministic success, use a short machine-readable result without an additional model call solely to confirm PASS. Diagnose failures locally first with existing tools: failed step, actual/expected values, timeout, infrastructure, permissions and cleanup. Send only bounded, sanitized unresolved findings to a model. Identical blockers do not justify periodic model calls; mandated independent reviews remain intact.

Measure queue, setup, test, cleanup, verification, local diagnostic and model/review consumption separately when available. Unknown costs remain unknown. Do not add expensive telemetry solely to claim savings.

## Platform adapters

CI-specific events, check sources and permissions belong in the adapter, not the portable equivalence rule. A valid current status must come from the permitted identity for the revision/integration context required by the platform and project gate. Reuse does not authorize branch-protection changes, bypass permissions, workflow credentials or status fabrication.

For a GitHub adapter, determine whether the PR head, test merge or merge-group revision must pass, verify the allowed check source, and use an eligible event. A merge queue has its own `merge_group` event and revision; PR-head evidence does not automatically validate that integration. Do not use commit-message or workflow path/branch skips to simulate a successful required check. Distinguish a skipped workflow from a conditionally skipped job and from genuinely verified reuse. A short trusted verifier job may satisfy a supported gate without duplicating native tests, but a green skipped job proves no test execution.

These GitHub details are adapter guidance verified against primary documentation on 2026-10-19; recheck them before platform implementation: [required checks](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks), [workflow skipping](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/skip-workflow-runs), [artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations). Build provenance must be supplemented with the test-specific evidence above.

## Privacy, compatibility and activation

Classify evidence and its destination under `DATA_PRIVACY_AND_CONFIDENTIALITY.md`; use authorized, minimized metadata and synthetic fixtures for examples. Public or repository-intended information is not a privacy stop by itself. Stop for unresolved classification/handling authority or an unauthorized destination. Do not version secrets, private host inventories, absolute host paths, raw private logs or credential-bearing artifacts. A hash or signature is not anonymization. Uploading evidence needs the applicable transfer authority.

The existing `foundation-ai-work/v1` validation-evidence schema and its consumers remain unchanged. Its result, independence and provenance fields do not establish cross-host trust. Do not insert reuse decisions into its closed result enum or silently upgrade old evidence. If an executable adapter needs new material fields, select a compatible separate/versioned envelope, feature/manifest registration, upgrade assessment and positive/negative regressions before activation.

During upgrade, assess this policy even when no adapter is installed. Integrate truthful evidence/default reporting normally; make producer trust, equivalence criteria, gate selection and activation explicit project decisions. Preserve equivalent or stronger project validation. Without an adapter, continue existing tests and CI; no target upgrade or host/platform change is implied.

## Acceptance for an executable adapter

Before activation, use a synthetic offline profile to verify the decision logic and then validate the actual protected host/CI boundary. Cover successful reuse and ordinary execution, plus rejection of tampered or self-asserted PASS, unauthorized issuers/verifiers, invalid/revoked signatures where applicable, replay/expiry, changed source/build/test/oracles/dependencies, external environment drift, different runtime/security profiles, incomplete results or cleanup, mocks substituted for native tests, wrong revision/event/check source, and incompatible versions. Cover mixed changed/unchanged gates and conservative unknown-dependency fallback.

Check that complete success requires no additional model confirmation, unchanged blockers stay quiet and missing adapters retain existing CI. Synthetic fixtures prove decision behavior only; they do not prove real cryptography, OS isolation, native acceptance, platform publication or deployment. Record those as not executed or pending until actually validated.
