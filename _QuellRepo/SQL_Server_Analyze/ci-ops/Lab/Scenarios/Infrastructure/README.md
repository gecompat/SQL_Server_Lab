# LAB-001 Welle 4 multi-container runtime

This directory contains the validated contracts, executable multi-container
foundation, and the first bounded Welle 4 infrastructure scenario. Docker on
native Linux supports the `CTR-PAIR` and `CTR-TRIPLE` topology actions in
addition to the existing `CTR-SINGLE` path. Native host evidence is not included
in the repository, so the Welle 4 runtime status remains
`IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING` and the external gates remain
`NOT_EXECUTED`.

The registry `wave4-contracts.csv` binds all 18 catalog scenarios to
`CTR-SINGLE`, `CTR-PAIR`, `CTR-TRIPLE`, and `HV-CROSS-PLATFORM`.
`LAB-LS-001` is the only implemented Welle 4 scenario action in this delivery.
The remaining 17 scenario actions, the network-fault layer, and the
`HV-CROSS-PLATFORM` runtime remain `PLANNED_NOT_IMPLEMENTED`.

## Implemented topology boundary

`Invoke-LabMultiContainerUp` accepts `CTR-PAIR` or `CTR-TRIPLE` with SQL Server
2019, 2022, or 2025 and the `Standard` resource profile. Docker is the executable
runtime lane. Podman remains visible as `NOT_EXECUTED` and assigned to Welle 9.

The runtime:

- performs the existing read-only LAB preflight;
- checks aggregate host memory and storage reserve before mutation;
- writes `TOPOLOGY_CREATING` before image pull or Compose mutation;
- pulls one digest-bound SQL Server image;
- starts primary, secondary, and optional tertiary nodes sequentially;
- registers every container immediately by its canonical 64-character object ID;
- creates and registers exactly one `LAB_MANAGEMENT` and one `LAB_DATA` network;
- verifies run, framework-owner, topology, role, and segment labels;
- waits for SQL health, verifies `ProductMajorVersion`, installs the current
  repository framework, and requires `FRAMEWORK_READY` before starting the next
  node;
- enables SQL Server Agent on Welle 4 SQL nodes for bounded infrastructure jobs;
- measures effective per-container limits and writes only ignored local runtime
  measurements;
- registers discovered resources and invokes exact-ID recovery cleanup after a
  partial failure.

The management and data networks are separate internal Docker segments. LAB
control uses Docker exec as the out-of-band management path, so SQL data-path
configuration can later be changed without selecting or deleting resources by
name. This is a management-path contract, not proof of a physical independent
network.

## LAB-LS-001 Log Shipping

`LAB-LS-001` uses an already ready `CTR-PAIR` scope. The dedicated entrypoint is:

```powershell
./Lab/Run-LogShipping-Lab.ps1 `
  -Action Run `
  -LabRunId LAB-20000101T000000Z-00000041
```

Validation of the resulting local contract is separate:

```powershell
./Lab/Run-LogShipping-Lab.ps1 `
  -Action Validate `
  -LabRunId LAB-20000101T000000Z-00000041
```

The scenario creates only the synthetic database `LabLs001` and the exact jobs
`LAB_LS_001_Backup`, `LAB_LS_001_Copy`, and `LAB_LS_001_Restore`. It uses the
SQL Server Log Shipping system procedures to configure the primary and secondary
metadata. No existing database, job, schedule, Log Shipping configuration, or
server timeout is selected by a partial name or changed.

The action performs:

1. exact scenario cleanup on both registered containers;
2. synthetic primary creation, full backup, and primary configuration;
3. secondary initialization with `NORECOVERY` and secondary configuration;
4. one successful backup, copy, and restore cycle;
5. analyzer observation of the healthy cycle;
6. one later log backup without copy or restore;
7. analyzer observation of visible lag;
8. exact configuration, job, database, and transfer-directory cleanup.

Portable evidence is based on ordered file identity. During the healthy cycle,
the primary backup leaf name must match the secondary copied and restored leaf
names. For the visible-lag state, the primary backup leaf must change while the
secondary copied and restored leaves remain on the previously verified file.
The scenario does not assert an exact number of minutes, job duration, file
timestamp, LSN, row order, retry count, or throughput.

The framework observations use:

- `monitor.USP_LogShippingStatus` on the primary and secondary;
- `monitor.USP_BackupChainAnalysis` for `LabLs001` on the primary;
- `monitor.USP_InfrastructureAnalysis` with only Log Shipping and backup-chain
  modules enabled.

A successful action returns the finding codes
`LOG_SHIPPING_HEALTHY_CYCLE_OBSERVED`, `LOG_SHIPPING_LAG_VISIBLE`, and
`BACKUP_CHAIN_VISIBLE`. Static and synthetic tests do not replace native Docker
or SQL Server 2019, 2022, and 2025 evidence.

## Safety boundary

Every mutable Docker resource carries the active run ID and the generic
`SQL_SERVER_ANALYZE` owner label. Containers additionally carry exact topology
and role labels; networks carry topology and segment labels. Cleanup uses only
registered complete object IDs. Name-only deletion, wildcard deletion, Compose
project-wide deletion, broad prune operations, and recursive root deletion are
forbidden.

The scenario transfer directory is below the ignored run-specific runtime path.
It carries an exact run-and-scenario marker and is removed only after boundary
and marker verification. Repository files contain no runtime path, credential,
server identity, backup payload, or execution output from a real environment.

Aggregate reserve checks multiply the `Standard` SQL-container memory and
storage budget by the selected node count. Nodes start sequentially. Welle 4
does not automatically escalate to a Stress profile.

`LAB-LS-002` and all other network or endpoint faults remain outside this slice.
Any later fault that can cut a data path must have explicit approval, bounded
duration, a registered exact cleanup object, and a proven management path before
activation. Exact packet counts, waits, queue sizes, durations, and throughput
remain non-portable assertions.

## Dependency boundary

`LAB-LINK-001` remains blocked by `OPS-005`. The contract records the intended
`USP_LinkedServerAnalysis` dependency, but neither that analyzer nor the linked
server scenario is represented as implemented. The contract does not promise a
per-call timeout for `sp_testlinkedserver` and does not change server timeout
configuration.
