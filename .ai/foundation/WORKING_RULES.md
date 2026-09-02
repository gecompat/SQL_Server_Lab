# Working Rules

Status: AUTHORITATIVE

## Authorization envelope

The current explicit task, project rules, selected environment, configured permissions, scope, and budgets form the authorization envelope.

A concrete task authorizes ordinary, reasonably expected and proportionate operations required to complete it. Normal operations inside that envelope are executed without additional confirmation merely because they write files, commit, push, call an API, run a test, create a branch, or otherwise mutate state.

Additional authorization is required only when an operation materially exceeds the envelope, targets an unexpected resource or environment, introduces a material unapproved cost, or is destructive/irreversible without sufficiently explicit current authority.

## Action classes

- `READ_ONLY`: inspection, analysis, comparison, planning.
- `NORMAL_OPERATION`: ordinary task-authorized work with expected effects and bounded scope.
- `HIGH_IMPACT_OPERATION`: operation with material external, financial, production, permission, publication, or broad-scope effects. It may proceed when the current task or project policy clearly authorizes that effect.
- `DESTRUCTIVE_OR_IRREVERSIBLE`: deletion, unrecoverable overwrite, force operations, irreversible publication/execution, or realistic data-loss actions. Require exact target authority and recovery analysis; do not ask again when the current task already explicitly and unambiguously authorizes the exact action unless circumstances changed.

## Preflight

1. Determine the current scoped instruction chain and read the smallest additional authoritative scope needed.
2. Classify relevant information and destination.
3. Establish the authorization envelope and action class.
4. Identify affected contracts, dependencies, recovery needs, and validation.
5. Identify local overrides and real conflicts.

## Rule-context reuse between waves

At the start of every new run or TUI session, let the active client rebuild its native `AGENTS.override.md`/`AGENTS.md` chain. Repository caching does not replace that discovery or any system, developer, current user, permission, or runtime instruction.

After the applicable additional repository rules have been fully read and analyzed once for a scope, later change waves may reuse that session analysis only under `RULE_CONTEXT_CACHE_POLICY.md`:

- before each wave, re-run deterministic instruction/source discovery and fingerprint the actual working tree, index/HEAD state, dependencies, scope, schema, generator, and discovery configuration;
- on `CACHE_HIT`, reuse only analysis present under the exact validated analysis key;
- on `PARTIAL_INVALIDATION`, fully reread changed rules and reanalyze every transitive dependent while retaining independent unchanged analyses;
- on `CACHE_MISS`, incomplete discovery, corruption, or uncertainty, fully rediscover, reread, and analyze the applicable context;
- keep cache records local, non-versioned, content-free, non-authoritative, and separate from validation evidence.

Fingerprint checks still read source bytes locally. They save repeated model-context ingestion and semantic analysis; they never justify using `HEAD` alone or overlooking staged, unstaged, untracked, moved, deleted, or newly scoped rules.

## Implementation

- One responsible implementation owner per coherent scope.
- Parallel work only for independent, disjoint, separately validated areas.
- Prefer existing project functions and local deterministic tools where suitable.
- Do not introduce dependencies or services without proportionate review.
- No blind overwrite, semantic guessing, or unrelated refactoring.
- Retry only after changed input, artifacts, evidence, environment, or an explicit stability test.

## Git default

- `main` is stable.
- Use a feature branch and pull request unless the project documents another workflow.
- Use small coherent commits with factual messages.
- Do not force-push shared branches by default.
- Validate the relevant scope before merge, or document what remains pending.
- Never describe unexecuted checks as passed.

## Completion and handover

Review the stable diff, run the smallest sufficient checks followed by the applicable completion gate, update factual state when needed, and record pending manual validation precisely. A handover is useful only when continuation facts changed; do not create administrative churn for trivial completed work.
