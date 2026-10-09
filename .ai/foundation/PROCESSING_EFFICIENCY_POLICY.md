# Processing Efficiency Policy

Status: AUTHORITATIVE — REQUIRED overhead assessment; DEFAULT workflow; protected authority and evidence remain REQUIRED

## Routine workflow

Start with the native instruction chain, the short Foundation ruleset, and the affected project sources. Read additional policies only when their boundary or capability is relevant. Discoverability is not an instruction to ingest every linked document, schema, capability, or repository map entry. An unchanged rule already analyzed in the active session need not be read again when its applicable authority, content, scope, and dependencies have been locally verified.

For a bounded routine task: inspect affected sources, make the coherent change, run the smallest sufficient checks plus required gates, and report the result. A WorkRequest, execution DAG, receipt, custom reader, handoff, or new review agent is not required for each ordinary action. Use those contracts when the selected executable capability or material risk actually requires them. Small scope does not waive safety, privacy, licensing, authorization, or truthful validation.

## Session-local rule reuse

Native discovery still runs at every new session and applicable scope change. Establish effective discovery settings once from trusted client/configuration evidence; unknown settings are not defaults to guess. Keep a content-free inventory of the current applicable instruction chain and selected rule sources. Hash actual working-tree bytes, including dirty/untracked rules, and track transitive semantic dependencies.

Reuse only analysis actually available in the same session under its exact content/authority/scope/dependency key. Revalidate current authority before reuse. A new worktree or Git commit requires a fresh binding check, but does not alone erase identical rule analysis when repository identity, effective instruction chain, discovery settings, semantic scope, selected sources, and dependencies remain demonstrably equivalent. Changed instructions invalidate dependent analysis; changed rules invalidate themselves and their transitive dependents. Missing analysis requires reading, not a fabricated hit.

The core `runtime/processing_efficiency.py` provides an in-memory reference implementation without any optional planner, persistent cache, model, network, or service. A client may implement the same procedure in another language. Python is not a Foundation prerequisite. The optional persistent `foundation-rule-context-cache/v1` remains unchanged and keeps its stricter record/binding checks. Never treat a persistent cache miss as permission to skip current authority validation.

The reference caller supplies a complete selected dependency inventory and a current `authority_key` fingerprint covering trusted native instruction precedence/content and effective discovery configuration. `capture_context` reads selected bytes locally; `SessionContext.acknowledge` retains the actually performed analyses in memory, and `analysis_for` retrieves them only at the current exact key. A digest supplied by an untrusted source does not attest discovery. Recapture before a new wave, and recheck before an effect if sources may have changed; never serialize retained analyses as durable authority.

Incomplete discovery disables reuse. Report the missing configuration once per unchanged condition and use the applicable full-read path; do not add recurring semantic rediscovery merely to diagnose the same unknown setting. Check configuration again on an actual change or new session. Checkpoints and context compaction do not reconstruct lost analysis.

## Review and delegation

One implementation owner handles a coherent slice. Use independent review when required by risk, project policy, or the user. Every additional reviewer has a distinct unresolved question and acceptance criteria. Reviewing a review, receipt, CI reader, or PR wording is not automatically a new model task. Deterministic tools check hashes, manifests, exact revision bindings, counts, and repeatable structural properties; models judge semantic changes and unresolved findings.

Delegate only when expected benefit exceeds context and coordination cost. Supply the stable base, allowed scope, relevant contract, acceptance criteria, and deduplicated findings. Do not fork whole histories by default. Reuse verified results at the same source/input binding. Additional evidence requires changed input, a new finding, a distinct risk, or an explicit test requirement. These defaults never remove a mandated independent review or required gate.

## Logs and model calls

Prefer existing local tools to inspect exit status, failed steps, error locations, counts, and relevant source bindings before sending diagnostic text to a model. Keep original evidence locally under the applicable retention/privacy rules; extract bounded, deduplicated findings with source locations and limitations. A green log is not automatically model input. Expand the inspected region only for a concrete unresolved question, and retain enough surrounding context to avoid hiding failures, skips, truncation, or cleanup problems. When a parser cannot establish the result, report that uncertainty and inspect the necessary original evidence; an empty error search is not proof of success.

For each additional model call or review, identify the unresolved semantic question, changed input, new finding, required independent judgment, or authorized retry that makes it useful. Mechanical receipt, hash, exact-revision, CI-status, and count checks use deterministic processing where available. A review report, reader script, PR wording change, successful check, or timer does not by itself justify another model call. If local tooling is unavailable or inadequate, use bounded inspection or a bounded model task and state the limitation instead of building a new reader/review pipeline for each slice. Separate mandatory safety/independence review from incidental administrative review. No automatic review-of-review chain is required by Foundation.

Reuse verified findings only for unchanged relevant sources, tools, configuration, evidence, and scope. New commits require current binding checks; failures and missing evidence never become success through reuse. Provide only the relevant contract, stable diff, unresolved findings, and evidence references to another reviewer. Do not repeatedly forward full histories, full green logs, or cumulative receipt summaries.

## Test-cycle overhead

Apply the progression and phase separation in `VALIDATION_POLICY.md`. Determine the affected contracts and consumers rather than triggering a full suite or runtime matrix solely because a broad directory changed. Keep a conservative larger fallback when dependencies or effects are unknown. An identical validator need not run both directly and through a suite for the same input binding; its distinct negative/regression assertions remain required. Distinguish validator self-tests from validation of project inputs. Never change test oracles, qualification claims, required repetitions, or safe cleanup merely to reduce cycles.

Batch coherent local corrections into a stable candidate before pushing where the project workflow permits. A repeated expensive test, capture, or model diagnosis needs changed relevant input/environment, a new finding, an explicit freshness/repetition requirement, or a previously unmet gate. Retain current-head/integration and mutating-runtime protections. A post-merge check may reuse evidence only when the project gate permits it and relevant inputs/environment/freshness are demonstrably equivalent; identical product bytes alone are insufficient.

Count test/CI time, local log processing, and model/coordination consumption separately when trustworthy measurements exist. Less CI runtime does not prove fewer model tokens. Unknown measurements remain unknown; prefer a short factual assessment of avoided duplicate work over new continuous telemetry or per-call paperwork.

## Shared wave budget

Before sustained autonomous work, select a project budget and its unit, measurement/estimate source, checkpoint threshold, hard ceiling, and stopping behavior. Do not invent account quotas, prices, usage, or universal percentage limits. If reliable metering is unavailable, report that limitation and choose an authorized finite task/agent bound rather than claim monetary enforcement.

The coordinator accounts for its own work, all descendants, retries, and coordination in one ledger. Count an invocation once using its stable identifier; aggregate root and child totals must not also be counted as separate invocations. Keep measured, estimated, and unknown consumption distinct. Reserve expected next-step cost before dispatch under one serialized authority; a pure budget decision is not an atomic reservation or provider spending cap.

At the checkpoint threshold, finish the bounded current step and checkpoint at a safe boundary. At the hard ceiling or an unverifiable required ceiling, admit no new work or agent; preserve pending work and perform only already-authorized safety/recovery actions. Never omit a required test and call the slice complete. Budget records and actual runtime/model/account metadata stay local and outside version control.

## Waiting and checkpoints

Heartbeats are recovery mechanisms, not a demand for repeated model work. Prefer completion events and deterministic status checks with backoff. An unchanged blocked state carries one current blocker/checkpoint; avoid rereading rules, repeating green checks, or adding summaries solely because a timer fired. Resume on relevant state change or an authorized bounded recheck. Checkpoint at coherent boundaries with changed durable facts and short references, not accumulated whole-chat or summary-of-summary text.

## Integration audit

Preserve stricter project governance. During installation/upgrade, flag rules that force broad reading before every edit, duplicate governance, recurring unchanged polling, or additional reviewer chains without a stated purpose. Record an efficiency recommendation separately from semantic compatibility; a compatible `PROJECT_STRONGER` rule may still be expensive. The deterministic core auditor returns advisory locations only. It does not prove a conflict, approve a rewrite, weaken a gate, or override user instructions. Review recommendations in the target's upgrade assessment and amend local rules only within authorized scope.

The overhead assessment is REQUIRED at installation/upgrade and when affected workflow rules materially change. Inspect actual instruction/adaptor rules, test selectors and workflows, review/delegation routes, log handling, and scheduled continuation prompts where accessible. Assess broad test triggers, duplicate validators/self-tests, development-versus-qualification confusion, full-log ingestion, review chains, repeated model calls, and unchanged-state polling. A compatible `PROJECT_STRONGER` classification does not waive this assessment.

Use the existing project assessment/decision record, not a new per-action receipt system. For each applicable area, identify the source/trigger, relevant contract or risk, and disposition: implemented efficiency behavior, a justified exception with bounded trigger and reason why a smaller alternative is insufficient, or an explicitly pending decision/blocker with impact and resumption condition. Areas that genuinely do not apply may be marked not applicable with a reason. For unresolved authority or material choices, ask a targeted question explaining the context, effect, options, and recommended next step; continue independent authorized work.

Do not claim completed efficiency integration while a material area is unassessed or has an unresolved disposition. Preserve the existing gate until an authorized amendment; pending remediation does not authorize omission or silent weakening. Verify affected selectors, diagnostic summaries, and reuse/invalidations with proportionate existing checks. The Foundation integrity validator and heuristic auditor do not attest actual target workflow efficiency, metering, or provider enforcement.
