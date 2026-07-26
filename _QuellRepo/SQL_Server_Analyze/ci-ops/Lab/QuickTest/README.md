# Docker/Podman quick-test system

The [canonical Docker-/Podman-Quick-Testsystem requirements](../../Documentation/Architecture/Docker_Podman_Quick_Test_System_Requirements.md)
define the complete target contract. This directory documents the currently
implemented, deliberately bounded subset.

The public entrypoints are:

- `Lab/Install-Lab.ps1` for `Preflight`, `Install`, `Status`, `Stop`, `Restart`, `Reset`, `Down`, `Start`, and `Destroy`;
- `Lab/Update-Framework.ps1` for the separate `UpdateFramework` action;
- `Lab/Uninstall-Lab.ps1` for confirmed destruction of one exact quick-test scope.

The first executable runtime delivery is limited to native x86-64 Linux. It
uses the shared Compose core for Docker or Podman and supports SQL Server 2019,
2022, and 2025 independently or together. It does not replace Windows, WSFC,
FCI, or hardware-specific test environments.

A green static or synthetic lifecycle test is not a native container-host run.
External Docker and Podman evidence remains `NOT_EXECUTED` until a suitable host
is available.

## Interactive Preflight

```powershell
./Lab/Install-Lab.ps1
```

The script asks for:

- Docker or Podman;
- one or more SQL Server versions from 2019, 2022, and 2025;
- one host port per selected version;
- a generic administrative SQL login;
- a masked SQL credential or ephemeral generated credential;
- resource profile `SMALL`, `MEDIUM`, or `LARGE`;
- persistence intent `PERSISTENT` or `TEMPORARY`;
- local data root;
- SQL Server container EULA acceptance.

Preflight is read-only. It checks operating system, architecture, runtime,
Compose, ports, memory, writable storage ancestry, generic scope conflicts,
image availability, EULA acceptance, and credential complexity. The result is
`READY` or `PREFLIGHT_FAILED` with structured reason codes and
`MutationBoundary = READ_ONLY_PREFLIGHT`.

## Non-interactive Preflight

```powershell
$adminCredential = Read-Host 'SQL credential' -AsSecureString
./Lab/Install-Lab.ps1 `
  -Action Preflight `
  -Runtime DOCKER `
  -SqlVersions 2019,2022,2025 `
  -Ports @{ 2019 = 14331; 2022 = 14332; 2025 = 14335 } `
  -AdminLogin ExampleSqlAdmin `
  -AdminSecret $adminCredential `
  -ResourceProfile SMALL `
  -PersistenceMode TEMPORARY `
  -AcceptEula `
  -NonInteractive
```

For automation, the credential may be provided through a named process
environment variable using `-SecretEnvironmentVariable`. The value is converted
to a read-only `SecureString` without using a plain-text conversion cmdlet.

## Install

Install always runs the same read-only Preflight before the first mutation.
Selected versions are started sequentially to reduce peak host pressure. Each
container must become healthy, answer a SQL query, and report the expected
major version before the next selected version is started.

```powershell
$adminCredential = Read-Host 'SQL credential' -AsSecureString
./Lab/Install-Lab.ps1 `
  -Action Install `
  -Runtime DOCKER `
  -SqlVersions 2022,2025 `
  -Ports @{ 2022 = 14332; 2025 = 14335 } `
  -AdminLogin ExampleSqlAdmin `
  -AdminSecret $adminCredential `
  -ResourceProfile SMALL `
  -PersistenceMode PERSISTENT `
  -AcceptEula `
  -NonInteractive
```

Use `-Runtime PODMAN` for the Podman lane. Both lanes use the same Compose core
and separate resource-limit overrides.

`-GenerateSecret` creates an ephemeral generated credential. For `Install`, that
value is stored only under the ignored local `.secrets/quick-test/<scope>` path
with owner-only directory and file permissions. The command returns the local
file path, not the value. User-supplied credentials are not persisted.

`-InstallFramework` invokes the existing canonical standalone framework builder,
installs `SQL_Server_Analyze` into the synthetic database `LabAnalyze`, and
verifies that the database and `monitor` schema exist.

## Resource and load boundary

The `SMALL` profile is the default. CPU and memory limits are passed to every
selected container. Install and Start process selected versions sequentially;
they do not start all versions concurrently. Stop processes versions in reverse
order and waits for every container to reach a stopped state. Restart composes
that ordered Stop with the credential-free Start of the same containers. Reset
performs a fresh Install only after the previous temporary scope has been removed.
UpdateFramework processes registered SQL Server versions sequentially and never
starts, stops, or recreates containers. The system never changes global Docker
or Podman settings, never raises host limits, and never touches unrelated runtime
objects.

## Local state and ownership

Before the first Compose mutation, Install writes a local recovery state under
`.state/quick-test/<scope>` and creates an owner marker containing the synthetic
run ID. Data is stored under `.artifacts/quick-test/<scope>` by default.

The state stores only local runtime metadata such as:

- generic scope and run ID;
- Docker or Podman;
- selected SQL versions, ports, image references, and resource profile;
- full current and previous container and network object IDs;
- owner-bound local roots;
- framework-installation and per-instance update status.

It does not contain the SQL credential or a connection string containing a
credential. Install refuses pre-existing unmarked local scope directories; it
does not adopt or overwrite them.

Install, Stop, and both Start paths persist their transition state before the
first Runtime mutation. Restart uses those existing transition contracts and
does not add a parallel direct Runtime path. Reset validates the complete saved
scope before confirmation and then delegates destruction and recreation to the
existing exact-scope Destroy and Install contracts. UpdateFramework validates the
complete runtime identity before recording `IN_PROGRESS`; it restores the
container lifecycle state to `READY` and records success or failure per instance.
Failed transitions never widen the scope beyond owner-validated full object IDs.

## Status

```powershell
./Lab/Install-Lab.ps1 `
  -Action Status `
  -ScopeName sql-analyze-quicktest
```

For an active scope, Status reads the owner-bound local state and validates each
stored full container ID. It reports runtime state, health state, port, SQL
version, and run-label ownership.

- `READY` requires every registered container to be running, healthy, and owned.
- `STOPPED` requires every registered container to remain present, owned, and in
  an exited or stopped Runtime state. The registered network remains present.
- `DOWN` means the containers and network were removed while local data and
  state were preserved.

Status performs no lifecycle mutation.

## Stop

`Stop` performs an ordered shutdown of the existing containers. It does not remove
containers, the registered network, data, credentials, state, or full object IDs.

```powershell
./Lab/Install-Lab.ps1 `
  -Action Stop `
  -ScopeName sql-analyze-quicktest
```

Before the first `container stop`, the state is written as `STOPPING`. All
run-ID-discovered resources must exactly match the full IDs in state. Every
container and the network are revalidated through both the run-ID label and the
generic `SQL_SERVER_ANALYZE` owner label.

Containers are stopped sequentially in descending SQL Server version order.
The default Runtime timeout is 30 seconds per container. The final state is
`STOPPED`; failures are recorded as `STOP_FAILED`. Repeating Stop for a fully
validated stopped scope is idempotent and returns `AlreadyStopped = true`.

## Restart

`Restart` is allowed only for a fully verified `READY` scope. It performs one
confirmation-bound `Stop` followed by the existing stopped-container `Start`.
It restarts the same full container IDs without recreating containers, without
recreating the network, and without requiring the SQL credential.

```powershell
./Lab/Install-Lab.ps1 `
  -Action Restart `
  -ScopeName sql-analyze-quicktest
```

Before Stop, Restart records the current run ID, network ID, and ordered container
IDs. Stop writes `STOPPING`, preserves every Runtime object, and finishes as
`STOPPED`. Start then writes `STARTING`, starts the same containers sequentially,
waits for health, verifies each SQL Server major version, and checks the preserved
framework when it was installed.

After Start returns `READY`, Restart rereads the state and verifies that the
complete runtime identity is unchanged: run ID, network ID, number of containers,
and every ordered full container ID must match the pre-Restart state. A mismatch
fails the action instead of silently accepting newly created resources.

`-WhatIf` returns before Stop. A Stop failure is reported as
`RESTART_STOP_FAILED`; a non-ready Start result is reported as
`RESTART_START_FAILED`. Failures inside the shared Start recovery path retain its
explicit `STOPPED` or `START_STOPPED_RECOVERY_FAILED` state.

## Reset

`Reset` reproducibly discards and recreates a complete **temporary** quick-test
scope. It is intentionally destructive and is not an alias for Restart.

```powershell
./Lab/Install-Lab.ps1 `
  -Action Reset `
  -ScopeName sql-analyze-quicktest
```

Before confirmation, Reset performs `READ_ONLY_RESET_PREFLIGHT`. It validates the
state and data path boundaries, owner marker, stable lifecycle state, Runtime,
selected versions, ports, resource profile, existing SQL credential, and the
exact match between saved full IDs and run-ID-discovered objects. Unexpected or
missing objects block Reset before any mutation.

Only `PersistenceMode = TEMPORARY` may be reset. A `PERSISTENT` scope returns
`RESET_PERSISTENT_SCOPE_BLOCKED` without deleting data or Runtime objects. To
remove a persistent scope, use the separately confirmed `Destroy` action.

For a temporary scope, Reset requires the existing SQL credential. A generated
credential previously saved by Install is loaded only after path and owner-marker
validation. A user-supplied credential must be provided again. `-GenerateSecret`
is rejected because existing configuration must not silently change before the
old scope is destroyed.

After confirmation, Reset delegates complete removal to `Destroy` and then calls
fresh `Install` with the same Runtime, SQL Server versions, ports, login,
resource profile, framework-installation choice, and temporary persistence mode.
The previous data, credential directory, state, containers, and network are
removed. The fresh installation creates a new run ID, new container IDs, a new
network ID, and empty data/log/backup directories. A successful result reports
`ResetPerformed = true` and `DataRecreated = true`.

`-WhatIf` returns `RESET_CONFIRMATION_REQUIRED` without mutation. `-Force` is
available only for a documented unattended Reset and bypasses confirmation; it
does not bypass the persistent-scope, ownership, path, credential, or exact-ID
checks. If the fresh Install fails after destruction, Reset reports
`RESET_INSTALL_FAILED`; the former temporary environment is not restored.

## Down

`Down` removes the registered containers and registered network while preserving
the marked data directory, generated local credential, and state. It is intended
for releasing Runtime objects without destroying reusable test data.

```powershell
./Lab/Install-Lab.ps1 `
  -Action Down `
  -ScopeName sql-analyze-quicktest
```

The command requires confirmation unless `-Force` is supplied for a documented
unattended run. Down preserves both `PERSISTENT` and `TEMPORARY` local data; the
complete local scope remains available for `Start` or for an explicit `Destroy`.

Before removal, `DOWN_IN_PROGRESS` and the full registered object IDs are written
to state. Down rejects unexpected objects, verifies ownership, and removes only
the registered full object IDs. The final state is `DOWN`; current Runtime IDs
are cleared and previous IDs remain for diagnosis.

## Start

`Start` handles two different preserved states:

1. From `STOPPED`, it starts the existing containers by their full IDs without requiring the SQL credential and without recreating containers or the network.
2. From `DOWN`, it recreates containers and the network from preserved state and
   therefore requires the original SQL Server credential.

```powershell
./Lab/Install-Lab.ps1 `
  -Action Start `
  -ScopeName sql-analyze-quicktest
```

For `STOPPED`, Start writes `STARTING` before the first `container start`, starts
containers sequentially in ascending SQL Server version order, waits for health,
and verifies the expected major version. It also verifies the preserved framework
when it was installed. Runtime IDs and network identity remain unchanged. A
failure attempts an owner-validated reverse stop and returns to `STOPPED`; a
rollback failure remains explicit as `START_STOPPED_RECOVERY_FAILED`.

For `DOWN`, a generated credential stored by Install is loaded only after its
path and owner marker are validated. A user-supplied credential must be provided
again. `-GenerateSecret` is rejected because existing SQL Server system databases
require the original credential. The containers are recreated sequentially and
the final state is `READY`.

Calling Start for a fully verified `READY` scope remains idempotent.

## UpdateFramework

`UpdateFramework` installs or updates the current repository framework artifacts
on every registered SQL Server container of a fully verified `READY` scope. It
is deliberately separate from the container lifecycle.

```powershell
./Lab/Update-Framework.ps1 `
  -ScopeName sql-analyze-quicktest
```

Before confirmation, the action validates state and path ownership, final
`READY` status, the exact run-ID scope, full container and network IDs, both
owner labels, and the registered SQL Server major version for every instance.
It does not recreate containers, change ports, alter resource limits, or change
the run or network identity.

The action does not require an externally supplied SQL credential. The canonical
container installer uses the credential already present inside the owned SQL
Server container environment. No credential value is returned or persisted in
framework update state.

Each instance is processed sequentially. Before installation, the canonical
wrapper classifies the instance:

- `INSTALLED` means `LabAnalyze` and the `monitor` schema were not both present;
- `UPDATED` means an existing framework installation was found.

Both paths rebuild the standalone installer from current repository artifacts,
run the same idempotent installer, and require the final marker
`FRAMEWORK_READY`. Per-instance results include SQL version, action status,
verification status, and a bounded runtime error message on failure.

The overall result is `READY` only when every selected instance is verified.
One or more failed instances produce `FRAMEWORK_UPDATE_FAILED`; successful and
failed counts plus all instance results are returned separately. The scope's
container lifecycle remains `READY`, while `FrameworkUpdateStatus` and
`FrameworkInstances` record the framework-specific outcome. `-WhatIf` returns
before the first framework mutation.

## Destroy and uninstall

`Destroy` means complete destruction of the selected quick-test scope. It
removes registered containers, the registered network, generated local
credential, state, and all marked local data. It requires confirmation unless
`-Force` is supplied.

```powershell
./Lab/Install-Lab.ps1 `
  -Action Destroy `
  -ScopeName sql-analyze-quicktest
```

The dedicated wrapper performs the same operation:

```powershell
./Lab/Uninstall-Lab.ps1 `
  -ScopeName sql-analyze-quicktest
```

Destroy uses full object IDs and verifies current run-label and framework-owner
labels before deletion. Unexpected run-labeled objects stop the operation. It
never performs a global prune or a name-only delete.

Stop and Restart preserve Runtime objects. Down preserves the complete local
scope. Reset replaces only a temporary scope. UpdateFramework preserves the
complete runtime identity. Destroy always removes the complete scope, independent
of `PERSISTENT` or `TEMPORARY`.

## Connection information

A successful Install, Start, Restart, or Reset returns one entry per SQL Server
version with:

- `localhost` and the configured host port;
- the generic login name;
- a `sqlcmd` command without an embedded credential;
- a connection-string template without an embedded credential;
- `LabAnalyze` when framework installation was requested.

UpdateFramework returns framework action and verification results instead of new
connection information. The credential is never printed again.

## Current boundary

The following remain open after this delivery:

- native UpdateFramework execution evidence;
- native Docker and Podman execution evidence;
- end-to-end SQL Server 2019, 2022, and 2025 host evidence.
