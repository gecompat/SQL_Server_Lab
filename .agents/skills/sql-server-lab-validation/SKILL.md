---
name: sql-server-lab-validation
description: Select and execute SQL_Server_Lab validation for a concrete code or contract change, and distinguish executed evidence from missing provider proofs; use for testing changes or assessing validation gaps.
---

Resolve [AGENTS.md](../../../AGENTS.md) and the affected contracts through
[repo_map.yaml](../../../.ai/repo_map.yaml). Follow the current
[local validation strategy](../../../Documentation/Quality/LOCAL_VALIDATION_STRATEGY.md)
and [cost policy](../../../Documentation/Quality/COST_EFFICIENT_DEVELOPMENT.md).

Use [client readiness](../../../Tools/Test-SqlServerLabClientReadiness.ps1)
for the requested provider before a runtime-dependent check. A blocked runtime
does not prevent independent offline tests. Static-only work needs no runtime
start. Readiness is not evidence that the client loaded this skill.

Determine changed tracked and untracked files against the actual requested
baseline. Use [Get-CiTestSelection.ps1](../../../Tools/Get-CiTestSelection.ps1)
to inspect the impact selection, and
[Invoke-ImpactedChecks.ps1](../../../Tests/Static/Invoke-ImpactedChecks.ps1)
to execute it after the smallest relevant reproduction and focused checks.
Read their current parameter metadata instead of copying a signature here.

Run selected provider proofs against isolated, owned test resources with their
documented cleanup path. Docker, Podman and Hyper-V evidence are separate.
Keep complete logs local and ignored; summarize new failure signatures and the
decisive evidence. Do not rerun an unchanged green check or identical failure
without new evidence. Run the required final gate on the stable package.

Report what actually ran, its outcome and cleanup status. `SKIP`, `NOT_EXECUTED`
and an infrastructure blocker remain missing evidence. A Foundation integrity
pass does not establish product behavior.
