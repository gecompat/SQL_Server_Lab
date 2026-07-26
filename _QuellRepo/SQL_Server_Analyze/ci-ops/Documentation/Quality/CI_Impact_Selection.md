# CI impact selection

The pull-request checks distinguish repository-wide invariants, static contracts,
and SQL Server runtime contracts.

## Always-required checks

Repository privacy and commit-message validation remain repository-wide. They
protect the complete delivery tree and the commit history and therefore cannot
be selected from SQL object dependencies.

## Documentation and metadata

Documentation validation runs without a SQL Server instance. The external-link
network check runs only when a changed line introduces or modifies an HTTP(S)
reference, when its validator changes, or when the workflow is started manually.

Snapshot Baseline documentation and general metadata do not start the Snapshot
Baseline runtime matrix. Its static public and installer contracts run separately
from its SQL Server runtime contracts.

## Executable SQL

`Code/Tests/Static/925_Select_CI_Impact.py` compares the base and head revisions.
It removes SQL comments and normalizes formatting outside quoted literals and
identifiers. A SQL file whose executable representation is unchanged is treated
as documentation-only.

For executable changes, the selector:

1. extracts changed `monitor` and `snapshot` objects;
2. builds reverse dependencies from production SQL;
3. includes transitively dependent objects;
4. selects tests that reference an affected object;
5. adds the relevant area test and the core smoke test; and
6. selects permission, regex, standalone, Snapshot Baseline runtime, and
   concurrency contracts only when affected.

The full runtime gate remains mandatory when the change affects setup, a central
installer, a workflow, the canonical release runner, or the selector itself. It
is also the fallback when a production change cannot be mapped safely. Manual
workflow execution has no comparison base and therefore uses the full gate.

All supported SQL Server versions still evaluate an executable core change. The
optimization reduces the executed contracts, not the supported-version boundary.
This preserves compatibility evidence while avoiding unrelated runtime fixtures
and their resource use.
