# Repository Continuity and Break-Glass Policy

Status: AUTHORITATIVE
Rule class: DEFAULT with REQUIRED safety boundaries

## Purpose

Repository protection must preserve integrity without making an external validation service a permanent single point of failure for the project's durable coordination channel. A project MAY define a controlled break-glass path for infrastructure outages. The path is an availability mechanism, not a way to ignore failed validation.

## Required safety boundaries

A break-glass merge MUST NOT be used when a required check completed and reported a project, code, schema, registry, security, or other substantive validation failure.

A break-glass merge MAY be used only when the required validation cannot obtain a trustworthy result because its execution infrastructure is unavailable, materially degraded, stuck, or otherwise incapable of running the check in a reasonable project-defined interval.

The repository MUST preserve an auditable change path during break-glass operation. For Git-hosted projects this normally means:

- a pull request remains required;
- direct pushes to the protected branch remain prohibited;
- force pushes and protected-branch deletion remain prohibited;
- the bypass is limited to explicitly authorized maintainers/roles;
- where the hosting platform supports it, bypass permission is limited to pull requests rather than `always` bypass;
- the PR records the outage reason, checks bypassed, local/manual evidence, residual risk, and required post-recovery validation.

Break-glass does not convert `failed` validation into `validated`. Validation that could not run remains pending until successfully executed after service recovery.

## Required decision rule

Classify the blocked check before bypass:

- `VALIDATION_FAILURE`: the check ran and found a substantive defect. Break-glass is prohibited.
- `INFRASTRUCTURE_UNAVAILABLE`: the check cannot produce a trustworthy result because the execution service/platform is unavailable or degraded. Break-glass may be used when the project has authorized it.
- `UNKNOWN`: the cause cannot be established. Treat as non-bypassable until classified.

Examples of infrastructure unavailability include a documented CI-platform incident, jobs that cannot start because runners/services are unavailable, or a platform failure that prevents status production. A timeout caused by the project's own test/code defect is not infrastructure unavailability.

## Break-glass evidence

Before merge, record at minimum:

- reason and observed infrastructure failure;
- affected required checks;
- PR/head/base references;
- locally executable deterministic checks that were run and their results;
- checks that could not be reproduced locally;
- residual risk;
- who/what authorized the bypass under project governance;
- obligation to rerun the missing validation after recovery.

Prefer existing deterministic project commands locally when their environment is available. Do not fabricate a green status or create a synthetic success check merely to satisfy branch protection.

## Recovery

After the validation infrastructure recovers:

1. run the bypassed checks against the merged state or an equivalent immutable revision;
2. record the result as post-recovery evidence;
3. if a substantive failure is found, open an incident/correction work item and restore a known-good state or merge a corrective change according to project policy;
4. close the break-glass event only when deferred validation has a truthful outcome.

## GitHub recommendation

For GitHub projects that want both hard normal-mode enforcement and availability, prefer layered repository Rulesets:

1. an always-enforced core-safety ruleset requiring PR-based changes, linear history, no force pushes, and no branch deletion, with no bypass;
2. a CI-gates ruleset requiring project status checks and up-to-date validation, with a narrowly scoped bypass actor configured as `For pull requests only`.

This keeps the audit trail and core branch safety active while allowing an authorized PR to bypass unavailable CI gates. The Foundation does not silently configure target repository administration; the target project decides whether and how to enable this recommendation.

## Scope

This policy defines repository-governance semantics. It does not require GitHub, GitHub Actions, a specific CI vendor, or any specific administrator identity. Equivalent or stronger availability/integrity controls on another platform are compatible.
