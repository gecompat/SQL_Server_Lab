# Model and Resource Routing Policy

Status: AUTHORITATIVE

Choose per work step, not per project. Safety, privacy, authorization, correctness, and validation outrank cost.

Automatic end-to-end dispatch uses fresh source-backed model evidence in addition to a live catalog. Catalog presence alone does not establish quality, price, resource use, context, capability, or model aliases. When that evidence is missing, the correct fallback is an explicit manual model-selection prompt/handoff, not a fabricated automatic choice.

- `LOCAL`: deterministic local processing; no generative model required.
- `ECONOMICAL`: bounded, low-risk, clearly specified, cheaply verifiable work.
- `BALANCED`: integrates multiple contracts, files, layers, or competing sources; diagnosis is not obvious.
- `FRONTIER`: an unresolved, critical or hard-to-verify decision involving architecture, security, privacy, authorization, data loss, persistence boundaries, or another high-impact conclusion.

Routine work involving an already-defined security, privacy, authorization, or architecture contract does not become `FRONTIER` merely because that domain is involved. Tier selection is based on unresolved risk, complexity, criticality, and verifiability—not human review effort. A stronger model does not replace required human review or approval.

Human review effort is an execution-efficiency factor only after the required capability tier has been established. It may motivate better automation, clearer evidence, or a better model within the same tier; it must not by itself escalate the tier or remove a required review.

## Existing project routing policies

A target repository may already have a more detailed model, provider, quota, cost, or tool-selection policy. Preserve it when it is compatible. Do not replace a mature project policy merely to introduce Foundation tier names.

When Foundation tiers overlap an existing project taxonomy, maintain an explicit semantic mapping where needed:

- each project category used for AI/model selection should map to the closest Foundation capability tier or state that no direct mapping is needed;
- concrete model names, providers, current prices, quotas, and product-specific features remain runtime/project facts, not Foundation contracts;
- a target policy may split one Foundation tier into several project-specific categories;
- a target policy must not use human review effort alone to justify a higher Foundation capability tier;
- after a difficult decision, reassess and downgrade subsequent mechanical or deterministic work even when the project uses different local tier names.

The Foundation tiers provide a portable semantic abstraction. The target project's detailed routing remains authoritative for concrete runtime selection when compatible with these semantics.

## Dynamic routing contract

When a target selects dynamic routing, use a provider-neutral request/decision contract. `foundation-model-router/v1` remains compatible. New orchestration should use `foundation-model-router/v2`, which adds data classification, execution boundaries, independently refreshed provider fragments, health evidence, quality/resource provenance, and hard resource/latency limits. The decision records the selected provider/model, expected cost and success, reasoning effort, fallback chain, pricing epoch, expiry, execution boundary, resource evidence, fragment source, and auditable exclusion reasons.

Apply privacy, authorization, capability, context, quality, price-freshness, and budget constraints before comparing economics. `LOCAL` means deterministic local processing and must not silently authorize a remote model. Concrete providers, model identifiers, capabilities, availability, quotas, and prices are runtime facts and are not hard-coded into this policy.

For feasible candidates, minimize expected cost of success rather than headline token price:

```text
expected_chain_spend = sum(probability_reached * estimated_attempt_cost)
chain_success = 1 - product(1 - predicted_attempt_success)
cost_of_success = (expected_chain_spend + expected_switching_cost
                   + final_failure_probability * failure_cost) / chain_success
                  + expected_latency * latency_value
```

Success estimates may combine explicit project quality priors with aggregate observed outcomes. A fallback is admitted only when the resulting prefix improves expected cost of success by at least the greater of USD `0.000000000001` and `0.1%` of the preceding prefix objective, and the complete chain remains inside the expected-spend bound. The bounded reference router exhaustively evaluates every ordered chain up to `max_fallbacks + 1`; when that declared search would exceed its safety bound it returns `CHAIN_SEARCH_BOUND_EXCEEDED` rather than claiming a heuristic optimum. Context eligibility reserves both input context and expected output tokens. Session/cache affinity may reduce switching cost, but it is conditional and never overrides safety, capability, quality, freshness, or budget constraints.

Model resource estimates under a hard limit require measured or configured provenance. A project may provide a per-attempt USD resource cost only with measured/configured provenance and a documented source; that value then participates in complete-chain expected spend. Without a defensible monetary conversion, no money value is invented: normalized resource pressure is only an explainable tie-breaker after the monetary cost-of-success objective. Host-local models retain `ECONOMICAL`, `BALANCED`, or `FRONTIER` tiers with an explicit `HOST` boundary; `LOCAL` always means no generative model is required.

## Price epochs, discovery, and evaluation

Remote catalogs and prices require source timestamps and expiry. A routing decision carries the applicable `pricing_epoch` and expires no later than the next price boundary of any eligible candidate; a rate change therefore invalidates cached rankings even when the previously selected model's own price is unchanged. If live refresh fails, retain an unexpired last-known-good catalog or fail closed—never invent a current price.

Newly discovered models start `UNASSESSED`. They may become eligible only through an explicitly allowed, bounded evaluation plan with task set, sample count, spend ceiling, stopping rules, and atomic reservation where concurrent evaluators could overspend. Candidate and incumbent arms receive distinct linked reservations. Actual spend is settled to its own arm, and only a completely settled valid pair counts toward candidate graduation. Expired/incomplete pairs do not become evidence. Graduation requires the project's minimum evidence; discovery alone is not a quality claim.

## Runtime state and graceful degradation

Catalogs, outcome aggregates, session hashes, evaluation reservations, and snapshots are runtime state. Keep them outside the repository and version control, write them atomically under a lock, store no credentials, and avoid retaining prompt or response content. Credentials are supplied by the target environment at execution time.

Thin integrations consume the same deterministic decision contract. The preferred order is local MCP, then the CLI, then a shell-free launcher or unexpired generated snapshot, then an expiring manual handoff, and finally the portable Foundation tier without an invented concrete model. Each lower layer must preserve the same authorization and fail-closed semantics.

A requested model, accepted model parameter, advertised catalog entry, or created subagent is not evidence that the requested model performed the work. Record requested and actual model separately. Treat an automatic switch as `ATTESTED` only when an explicitly trusted host/adapter issuer supplies execution or response metadata that identifies the actual model and it matches the request; an `evidence_kind` label alone is not a trust anchor. Otherwise report `REQUESTED_NOT_ATTESTED`. When automatic dispatch is unavailable or unattested, emit `MANUAL_DISPATCH_REQUIRED` with an external content handle, required tier/capabilities, acceptance and validation criteria, expiry, and privacy boundary. Name a concrete model only from fresh eligible runtime evidence. The user may then select that model manually, but the recommendation still does not attest the resulting execution.

Minimize context: use relevant diffs, deduplicated error signatures, compact confirmed facts, and repository maps where available. After one complete rule analysis for a scope, use the deterministic `RULE_CONTEXT_CACHE_POLICY.md` contract between later change waves so unchanged additional rules are not repeatedly ingested or semantically analyzed. Cache fingerprinting never replaces native instruction discovery and uncertainty remains a full-read miss. Do not load entire repositories, chats, logs, or research collections by default. Do not repeat an identical failed attempt without new evidence.
