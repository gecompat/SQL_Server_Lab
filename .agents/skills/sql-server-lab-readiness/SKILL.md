---
name: sql-server-lab-readiness
description: Diagnose SQL_Server_Lab client and provider readiness without starting runtimes or changing configuration; use for bootstrap failures, missing prerequisites, or a pre-operation readiness check.
---

Use the repository root discovered through [AGENTS.md](../../../AGENTS.md).
Follow its applicable rules; this skill adds no separate authorization policy.

Run [Test-SqlServerLabClientReadiness.ps1](../../../Tools/Test-SqlServerLabClientReadiness.ps1)
from that root with the provider and operation matching the request. Read the
script's current help for supported operations. It works without this skill.

Interpret `Status`, `Checks`, `MissingPrerequisites`, `Warnings` and `NextSteps`.
Keep installation, execution permission, runtime access, reachability, timeout
and storage failures distinct. Report the smallest concrete next step for each
blocking prerequisite. A returned record never proves skill-loader discovery;
`SkillLoaderVerified` remains false.

For capacity or manifest-specific prerequisites after bootstrap, import
[SqlServerLab.psd1](../../../SqlServerLab.psd1), inspect `Get-Command` and
`Get-Help` for `Test-SqlServerLabPrerequisite`, and use its current public
contract. Follow [repo_map.yaml](../../../.ai/repo_map.yaml) to the relevant
provider or storage documentation when a result requires explanation.

Readiness itself performs no setup, runtime start, elevation or configuration
write. Such follow-up work must be within the user's current request and the
existing project contracts. Successful bootstrap does not replace the target's
ownership, resources, cleanup and recovery checks.
