---
name: sql-server-lab-operate
description: Operate existing SQL_Server_Lab public workflows for creating labs, inspecting status and connection information, starting, stopping or removing owned runs; use for lab lifecycle requests rather than repository implementation.
---

Discover the repository root through [AGENTS.md](../../../AGENTS.md), then use
[client readiness](../../../Tools/Test-SqlServerLabClientReadiness.ps1) for the
requested provider and operation. Follow the existing authorization in the
user's request; readiness grants no additional mutation authority.

Import [SqlServerLab.psd1](../../../SqlServerLab.psd1). Resolve current exports
and parameters with `Get-Command` and `Get-Help`; use
[the public reference](../../../Public/README.md) and
[Getting Started](../../../Documentation/User/Getting_Started.md) for the
selected workflow. Creation, inspection and lifecycle use the existing public
`New-SqlServerLab`, `Get-SqlServerLab`, `Start-SqlServerLab`, `Stop-SqlServerLab`
and `Remove-SqlServerLab` contracts. Determine the supported connection output
from that reference rather than reading secret-store files directly.

Bind existing targets through stable run/instance identifiers and their current
state, not a display name alone. Obtain the applicable preview or resource
assessment before mutation. Use [repo_map.yaml](../../../.ai/repo_map.yaml)
to find the chosen provider's ownership, persistence, cleanup and recovery
contracts. Persistent data retention and grouped runs follow those contracts;
removing a lab does not authorize deleting unrelated stores or runtime objects.

Execute the requested action through the public core and verify its returned
status and postconditions. For a partial failure, preserve the operation's
recovery evidence and use its supported resume path. Missing secrets, UAC or
an unresolved user decision block only the affected action. Keep passwords,
secret references and raw diagnostics out of summaries and versioned files.
