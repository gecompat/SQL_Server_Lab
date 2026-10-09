# AI Work Orchestration Policy

Status: AUTHORITATIVE

This policy defines `foundation-ai-work/v1`, a runtime- and vendor-neutral control plane for AI-assisted development, research, documentation, structured data, media, and project-defined work. It governs planning and evidence even when no executable AI component exists. Models, deterministic tools, retrieval sources, renderers, validators, external services, human review points, transports, and runtimes are discoverable capabilities, not Foundation prerequisites.

## Scope and proportionality

Routine repository work follows `PROCESSING_EFFICIENCY_POLICY.md`. The structured requests, plans, receipts, and dispatch evidence below govern the corresponding selected orchestration/execution operations; they are not mandatory paperwork for every ordinary edit. Session-local rule reuse needs no optional component. Additional agents/reviews need distinct acceptance questions. Sustained autonomous work shares one coordinator-owned budget across root, descendants, retries, and coordination. `foundation-processing-budget/v1` provides content-free decision input; atomic reservations and provider enforcement remain caller responsibilities. Missing/estimated telemetry must not be reported as measured enforcement. Heartbeats use bounded rechecks/backoff and do not require renewed model work at an unchanged blocker.

## Invariants

- Foundation rules, installation, upgrade assessment, and `FOUNDATION_INTEGRITY` validation MUST remain usable when Python, MCP, a model, a provider, a network, an executor, or every optional capability is unavailable.
- Planning MUST apply data handling, authorization, required capability, quality, health/freshness, validation, time, money, and resource constraints before economic ranking.
- Discovery, routing, code generation, adapter synthesis, and model agreement grant no file, network, credential, spend, Git, push, pull-request, publication, or approval authority.
- Effective authority is the intersection of the request, project policy, caller authority, adapter requirements, and execution environment. Missing authority fails closed.
- Payload content is separate from the control plane. Requests use short-lived `stdin`, file, or opaque handles. Prompts and responses are not persisted or logged by default.
- Concrete model names, prices, endpoints, host paths, credentials, health observations, and runtime inventories are expiring runtime facts and MUST NOT become Foundation policy.
- A component failure invalidates only evidence or catalog material derived from that component. Healthy alternatives remain eligible.
- A planner or executor MUST report `MANUAL_REQUIRED`, `UNAVAILABLE`, or `BLOCKED` honestly. It MUST NOT convert absence, timeout, inconclusive evidence, or unknown state into success.

## WorkRequest

A `WorkRequest` declares an open `task_class`, data class, risk, input/output handles, required capabilities, execution-boundary constraints, authorization envelope, resource/cost/time limits, and validation contract. Project-specific task classes are allowed without changing the Foundation schema.

Data classes are `PUBLIC`, `INTERNAL`, `CONFIDENTIAL`, and `RESTRICTED`. A project may map a richer taxonomy while preserving or strengthening these boundaries. Remote or unknown-boundary processing of non-public data requires explicit project permission for that data class and destination. A product name, loopback address, process name, or successful probe is not proof of a trusted boundary.

## CapabilityDescriptor

A descriptor identifies a capability type, protocol/version, supported functions, deterministic status, execution boundary, requested authorities, data-class allowance, health/freshness window, provenance, and evidenced cost/resource model. Capability types include `DETERMINISTIC_TOOL`, `MODEL`, `RETRIEVAL`, `RENDERER`, `VALIDATOR`, `EXTERNAL_SERVICE`, and `HUMAN`.

Execution boundaries are `PROCESS`, `HOST`, `LOCAL_NETWORK`, `REMOTE`, `UNKNOWN`, and `HUMAN`. `HOST` means execution on the current trusted host only when project policy and runtime evidence establish that fact. `localhost`, a local client process, or an Ollama product label alone is insufficient.

Health is scoped and expiring. Expired or malformed health excludes that descriptor without making unrelated descriptors unavailable. Aggregators keep provider fragments and last-known-good records separately; stale material remains identifiable and is not silently treated as current.

## Planning and degradation

An `ExecutionPlan` is a directed acyclic graph of steps, alternatives, fallbacks, budgets, validation requirements, and grouped approval points. The planner performs no invocation. It returns:

- `EXECUTABLE` only when a complete bounded plan exists under current constraints and authority;
- `MANUAL_REQUIRED` when a human capability or decision can safely close a known gap;
- `UNAVAILABLE` when required capabilities or validators are not currently available;
- `BLOCKED` when policy, privacy, authority, or a hard limit prohibits execution.

When a deterministic capability sufficiently and verifiably fulfills the task, select it ahead of a model. “Local first” is not a fixed rule: data sovereignty, total expected cost, quality, availability, validation, and measured resource pressure decide together.

## Session lifecycle and orchestrator rotation

Long-lived AI work MAY rotate the active session while preserving the same logical role. The orchestrator is a role over durable project state, not the identity of one chat or conversation. Session rotation MUST NOT make chat history the source of truth.

A rotation decision MUST be cheap enough not to defeat the context savings it seeks. Continuous semantic rescanning of the conversation, recurring whole-chat summarization, implicit topic clustering, or another model call solely to decide whether context is "healthy" is prohibited by the Foundation reference contract. The decision uses deterministic metadata already available to the caller: estimated context tokens when known, the model/client context window when known, tokens since the last checkpoint when known, an explicit natural work boundary, project-selected soft/hard ratios, and an attested successor-session capability.

Threshold values are project policy and MUST NOT be presented as universal model limits. A soft threshold SHOULD create a checkpoint and defer rotation until a natural boundary such as a completed work item, completed milestone, or explicit major topic change. A hard threshold or explicit user rotation request MAY require immediate rotation. Unknown measurements remain unknown; they are not replaced with estimates derived from a semantic scan. Response latency MAY be diagnostic evidence but MUST NOT be an authoritative automatic rotation trigger because provider load, tools, networking, and reasoning effort also affect it.

Checkpointing is event-driven rather than periodic. A client SHOULD NOT summarize every N messages. When a checkpoint or rotation is actually selected, consolidation is limited to the delta since the prior checkpoint and references durable repository state. The repository, registered work items, decisions, tests, documentation, and other project-authoritative artifacts remain the durable truth. Repeated summary-of-summary chains SHOULD be avoided.

A `foundation-session-handoff/v1` record is content-minimized control data. It names the predecessor, successor role, checkpoint, durable-state references, changed-state references, current work references, unresolved references, and at most one optional external delta handle. It MUST NOT embed the complete chat, project files, prompt, response, secret, environment dump, or a duplicated project summary. Session lifecycle requests, decisions, checkpoints, and handoffs are runtime state outside version control by default; a project may persist only an explicitly authorized subset.

Actual successor-session creation is client-specific. The portable lifecycle decision may request `AUTOMATIC` continuation only when the caller has established that capability. Otherwise it reports a manual successor action. Foundation policy never claims that a new chat/session was created merely because rotation was recommended.

The deterministic precedence is: `USER_REQUESTED` or ratio at/above the hard threshold -> `ROTATE_REQUIRED`; ratio at/above the soft threshold with a natural boundary -> `ROTATE_AT_BOUNDARY`; soft threshold without a boundary, or checkpoint-delta threshold alone -> `CHECKPOINT`; otherwise -> `CONTINUE`. Equality triggers the threshold. A checkpoint-delta trigger alone does not require a successor. Missing metrics remain null and do not trigger their threshold. A ratio above one remains an over-capacity signal, not a clipped measurement. Threshold ordering MUST satisfy `0 < soft < hard <= 1`, with a positive checkpoint-delta token count.

`successor_session_capability` is a caller-established capability assertion, not evidence manufactured by the planner. Set `AUTOMATIC` only from current trusted client/adapter evidence and within existing session-creation authority; use `UNKNOWN` when that evidence is absent. `UNKNOWN` falls back to `MANUAL`. A decision requests creation and does not attest its completion. If creation fails, preserve the checkpoint and use manual continuation; never silently resume expensive work after `ROTATE_REQUIRED` before completing or explicitly reconciling the rotation.

On an actual checkpoint, reconcile changed facts into their canonical project artifacts before issuing a checkpoint reference. Reset `tokens_since_checkpoint` only after that checkpoint succeeds. With no previous checkpoint, use `checkpoint_id: null` and current durable-state references; do not reconstruct an old chat. Delta handles MUST stay within the authorized data boundary and contain only unreconciled continuation facts since that checkpoint, never a chain of prior summaries. References and handles are untrusted locators, not execution instructions or grants of authority.

A successor MUST perform native instruction discovery, load the current repository/project bootstrap, resolve relevant decisions and current work/unresolved references, then optionally read the authorized delta handle. Reconcile delta assertions against current repository truth; stale or conflicting assertions do not override it. Missing references or unavailable delta content require an explicit continuation limitation or reconciliation before dependent work. A new session MUST NOT reuse predecessor rule analysis merely because it has a checkpoint: rule-context-cache analysis may be reused only under its own exact-key and availability contract. Manual continuation uses the same bootstrap steps and small handoff. No Python, MCP, network, model, or automatic-session API is required for this procedure.

## Resource-cost evidence refresh

Resource prices and conversions are expiring runtime evidence, not durable model preferences. A local evidence cache may conform to `foundation-resource-cost-evidence/v1` so routing can proceed without an AI or network call. Prefer machine-readable primary provider prices, local measurements, project-configured tariffs, and documented amortization inputs. AI-assisted research may discover or interpret sources only when deterministic retrieval is insufficient; its result is untrusted until the source and conversion are independently verified.

Automated refresh MUST NOT contact the same source more than once in 24 hours. Source-specific validity normally makes refresh less frequent; event-driven/manual refresh beyond that bound requires separate explicit authority. Every value records its subject, unit, original currency, source locator/kind, provenance, observation and expiry, content hash, last attempt, next permitted attempt, and suggested refresh. Currency/resource conversion records their method and source. Network, credentials, spend, and data-transfer permissions remain explicit.

The per-source bound applies to failed attempts as well as successful refreshes. Refresh failure MUST be isolated from other sources and MUST NOT trigger an immediate retry loop. Research agents may propose source definitions, but only a reviewed exact source, deterministic extraction, explicit units and provenance may update usable evidence. Routing and policy evaluation MUST remain possible from unexpired cached evidence or without a monetary conversion when research, AI, Python, or network access is unavailable.

Only unexpired measured or configured per-attempt USD values with traceable evidence enter the monetary routing objective. Research evidence becomes usable only through an explicit verified project configuration. If refresh fails, an unexpired last-known-good value may remain available. After expiry, the router omits the monetary conversion and uses evidenced resource consumption only as a hard constraint and explainable tie-breaker; it never invents a price.

## Validation and human approval

Validation evidence states its method, producer, independence, scope, provenance, freshness, and result: `PASSED`, `FAILED`, `INCONCLUSIVE`, or `UNAVAILABLE`. Missing evidence is not passing evidence. Model self-review or agreement between non-independent attempts is not deterministic proof.

Reversible drafts and intermediate work may proceed within the authorization envelope. Deterministically validated outputs may continue automatically. Source checking or genuinely independent comparison may increase confidence for nondeterministic work, but high-impact or insufficiently verifiable conclusions require a human checkpoint.

Human approval is grouped at risk boundaries rather than requested after every operation. It is required before irreversible publication or mutation, sensitive data transmission, unplanned spend, high-impact action, privilege expansion, or acceptance without required evidence. Approval applies only to the described checkpoint and does not grant broader future authority.

Retries require changed inputs, a different capability, or new evidence. A resumable executor must use stable operation/idempotency keys so restart cannot duplicate external effects. `PREPARED` must mean invocation has not begun; an `IN_PROGRESS` external operation after a crash is ambiguous. It may be replayed only when the capability explicitly attests idempotent replay using the same operation key, otherwise execution stops for reconciliation. Foundation never claims exactly-once delivery without target-system evidence.

An optional executor revalidates the exact request, capability catalog, plan hash, expiry, handles, and approvals before invoking an adapter. Approval receipts are bound to the complete plan hash, exact grouped approval point, required authority, and validity window. Cancellation is cooperative at bounded adapter-call boundaries; a timeout or cancellation request is not evidence that an uncooperative external system reversed an operation.

Actual money and cumulative resource use count even when an attempt later fails. RAM and VRAM are peak limits; CPU/GPU time, disk, network, and energy are cumulative. Adapter-reported output hashes must be checked against output-handle bytes where the reference transport exposes files. Every required validation scope needs passing evidence; failed, missing, malformed, duplicate, non-independent, inconclusive, or unavailable evidence is not a pass.

## Persistence and reporting

Runtime state lives outside version control. By default it contains only identifiers, hashes, statuses, timestamps, attempt metadata, cost/resource measurements, approval references, and validation provenance. It contains no prompt, response, retrieved document, secret, environment dump, absolute host path, or payload content unless an explicit target rule authorizes that exact retention.

An `ExecutionReport` records attempts, validation, limits, costs/resources, constraints, and remaining actions without inventing success. A `GapReport` identifies a missing capability, tested alternatives, an optional least-privilege local remedy, and the authority needed to apply it. Without repository authority, gap reports remain local/stdout; they do not create issues, commits, branches, pushes, or pull requests.

## End-to-end orchestration and model evidence

An optional `foundation-ai-orchestration/v1` facade MAY compose runtime catalog discovery, `foundation-model-router/v2`, content-handle invocation, deterministic output validation, and the router's bounded fallback chain. Composition does not merge authority: every layer revalidates its own narrower boundary. The facade MUST remain unconfigured-safe and content-free, isolate each catalog and invocation failure, preserve requested/actual model distinction, and return a manual or unavailable status when any claim needed for safe automation is missing.

A live catalog proves only the facts it directly observes, normally model identifier and endpoint availability. Automatic routing MUST NOT convert that observation into price, quality, context, resource, capability, or alias evidence. Such facts MAY be supplied by fresh external `foundation-model-runtime-evidence/v1` records with exact connection/model identity, provenance, locator, content hash, observation time, and expiry. Expired or invalid records are excluded independently.

A different response-reported model identifier is not automatically an alias. Alias acceptance requires fresh provider documentation or provider-signed metadata identifying the exact requested and actual pair. Name similarity, suffix removal, a single successful response, client configuration, or model self-report is insufficient. Without strong alias evidence the generated output remains available through its handle, but orchestration stops as `MANUAL_REQUIRED` and does not pretend that the requested model executed.

Evidence collection MAY be refresh-on-plan rather than scheduled. A configured source is an exact shell-free argv with a narrow environment allowlist, bounded output, timeout, and minimum interval of 86,400 seconds. Every attempt, successful or failed, advances the same limit; independent sources remain isolated. Only strict fresh output updates last-known-good external evidence. AI-assisted research is one optional source implementation, never a mandatory planning dependency or an authority shortcut.

## Runtime connection configuration and bootstrap

Runtime connections MAY use the external `foundation-ai-runtime-configuration/v1` contract. It records named adapter connections, exact credential-free endpoint origins including hostname/IP and port, asserted execution boundary, network and data-class authority, content-handle roots, timeouts, remote-model policy, a credential reference, and model-selection behavior. The document is runtime state outside version control; it MUST NOT contain a credential value.

An interactive configurator MAY perform bounded read-only discovery before proposing a default. Automatic discovery MUST be local and narrow: known loopback defaults may be probed, but a non-loopback environment/configuration candidate MUST NOT be contacted without separate network authority. Discovery, a successful probe, `localhost`, or a product/version response does not itself prove `HOST`, authorize a data class, enable cloud tags, or save a configuration. The user or target authority confirms those boundaries once in the complete visible plan.

The lifecycle is `detect -> propose -> edit -> test -> save -> verify -> rollback`. Existing named connections are edited semantically, writes are atomic, and rollback is allowed only while the applied configuration still matches its recorded hash. Invalid connections are reported separately and MUST NOT hide or block valid connections. If no valid connection exists, CLI use SHOULD offer the configurator automatically. A non-interactive protocol server MUST still start without configuration and return `CONFIGURATION_REQUIRED`, safe unverified proposals, and a setup action; it MUST NOT put questions or diagnostics on protocol stdout or silently persist a default.

Credential sources are `NONE`, an allowlisted environment-variable reference, or an allowlisted dotenv file/key reference. A dotenv reference records only its absolute path, key name, and adapter export name. The value is loaded only for the bounded adapter call, is neither expanded nor evaluated as shell input, and is removed from the temporary process environment afterward. Configuration summaries, MCP results, logs, catalogs, receipts, and repository files MUST NOT contain the value.

Model-selection modes are `ROUTER`, `MANUAL`, and `PINNED`. `ROUTER` means a separately validated routing decision supplies the concrete model; it is not permission for the runtime bridge to invent a choice. `MANUAL` requires an explicit model. `PINNED` uses only its configured default. If an automatic route cannot be dispatched, the manual-handoff behavior below remains the truthful fallback. Every invocation records requested and actual model separately when the runtime response provides such evidence; cloud-tag and other remote use still requires per-call remote authority.

## Client integration and model-dispatch evidence

Client integration follows `detect -> plan -> apply -> verify -> rollback`. Existing configuration is read and merged semantically; wholesale replacement, unreviewed key collision, or erasure of unrelated configuration is prohibited. Apply revalidates the observed file and executable hashes. Rollback restores only an exact recorded predecessor while the applied output remains unchanged. Configuration writes, repository writes, push, pull request, and publication remain separate authorities.

Client support is capability-based. Codex may use policy plus CLI/launcher/snapshot; Visual Studio and GitHub Copilot may use their distinct MCP configuration shapes; generic clients may use any attested compatible transport. Native role, agent, subagent, invocation, and session model-selection surfaces MAY be preferred over an adapter when current client evidence establishes them. Such evidence is recorded as an expiring `foundation-client-model-routing-capability/v1` descriptor with source, binding scope, authority, fallback semantics, and available actual-model evidence. Product-specific keys and precedence are adapter data, not Foundation-wide assumptions. A client session, advertised model list, accepted model parameter, requested subagent model, model self-report, or untrusted evidence label does not prove a switch. Actual automatic dispatch requires a receipt identifying requested and actual model from host execution/response evidence issued by a target-configured trusted runtime identity. Otherwise the result is `REQUESTED_NOT_ATTESTED`.

When automatic dispatch is unavailable or unattested, create an expiring content-free `ManualHandoff` with `MANUAL_DISPATCH_REQUIRED`. It identifies tier, capabilities, data/risk classification, acceptance and validation requirements, and a separate prompt handle. A fresh concrete model may be suggested from catalog/configuration evidence but MUST remain marked as not execution-attested until the subsequent receipt. Without such evidence, recommend only the portable tier/capabilities. `LOCAL` never recommends a generative model. Non-public content MUST NOT be handed to a remote or unknown boundary without explicit transfer authority.

## Provisioning and local adapter synthesis

A `ProvisionPlan` is read-only until explicitly approved. It is content-addressed, expires, and lists exact source, artifact/model identifier, target runtime, license/use notice, expected transfer/disk/memory, network destination, monetary ceiling, verification, rollback, and recovery. Automated provisioning may perform only actions included in the approved plan; partial failure must not look complete.

Host preparation follows `doctor -> inventory -> plan-provision -> approve -> provision -> verify`. Discovery SHOULD check project-configured absolute locations as well as `PATH`, isolate each runtime failure, and treat product/process/loopback identity as insufficient execution-boundary evidence. One approval may cover the complete bounded plan, but never actions, destinations, downloads, costs, credentials, or validity outside its exact hash. Installers that may contact the network require a stronger separately authorized execution boundary; the optional reference provisioner accepts only reviewed offline install commands over an already verified artifact.

Provision state and targets remain outside version control. A completed exact plan may be read or verified again without repeating the download. A failed plan requires changed inputs, adapter, or evidence and a newly approved plan. An interrupted non-idempotent action is `MANUAL_REQUIRED` until reconciled. Cleanup MUST identify exact staged/target artifacts and MUST NOT delete an unknown or pre-existing target.

Local adapter synthesis requires explicit `allow_local_adapter_synthesis` authority. Generated material remains outside the repository, starts without network, credentials, or repository write access, includes its source hash, and is quarantined until protocol conformance passes. Durable repository adoption is a separate authorized workflow.

Reference synthesis SHOULD materialize reviewed sources rather than executing unconstrained generated code. Conformance MUST revalidate source/configuration hashes and least privilege, exercise the required protocol operations through bounded content handles, and leave any failing adapter quarantined. Conformance proves protocol behavior, not capability quality or a safe execution boundary for an arbitrary child command.

## Compatibility

`foundation-model-router/v1` remains valid. New orchestration may consume `foundation-model-router/v2`, but must preserve v1 request/decision behavior and the existing tier meanings. `LOCAL` always means deterministic work for which no generative model is required. A model executing on the host remains `ECONOMICAL`, `BALANCED`, or `FRONTIER` with `execution_boundary=HOST`; target aliases such as `LOCAL_ECONOMICAL` require an explicit semantic mapping and do not redefine Foundation tiers.

Reference implementations are optional and replaceable. Another language, client, adapter, provider, transport, executor, or project-specific planner is compatible when it enforces at least these contracts and reports unavailable states truthfully.
