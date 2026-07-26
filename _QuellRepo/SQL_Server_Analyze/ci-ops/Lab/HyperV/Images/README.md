# LAB-001 Welle 5 image-pipeline foundation

This directory contains the validated contract foundation for the planned
Hyper-V image pipeline. It contains no Windows or SQL Server installation
media, no built image, no local checksum, no product key, no credential, and no
host-specific path. The global Welle 5 status remains `PLANNED`, and runtime
remains `NOT_EXECUTED`.

The canonical contract is `image-pipeline-contract.json`. It defines a required
native PowerShell adapter, an optional Packer adapter, the SQL Server 2019,
2022, and 2025 parent matrix, the ordered build stages, immutable-parent rules,
PowerShell Direct verification, child-disk reset behavior, and external
evidence gates.

## Media and checksum boundary

Versioned files contain logical media IDs only. Local operators bind those IDs
to lawfully available media outside the repository. Every Windows and SQL
Server medium requires a complete SHA-256 checksum before it may be mounted or
used. The public image-lock example deliberately contains only unresolved
placeholders and never a local path or a fabricated checksum.

The pipeline must reject a missing, malformed, changed, or unapproved checksum.
A readable product name, file name, timestamp, or directory is not sufficient
identity evidence.

## Parent-image boundary

Each parent is built from verified local media into an ignored local build
area. After the supported Windows sealing step, the parent receives a complete
checksum, is registered by its platform object ID, and becomes read-only. The
pipeline must not patch, start, or otherwise mutate a registered parent in
place. A changed software baseline requires a new logical parent generation.

A parent image is a local implementation artifact, not repository evidence.
Image bytes, mounted-media state, build logs, answer files containing runtime
values, and host inventory remain outside Git.

## Child-reset boundary

Every scenario receives a new differencing disk based on the exact registered
read-only parent. Hyper-V checkpoints are not the canonical SQL data or guest
reset mechanism. Failed or interrupted children are discarded and recreated;
they are never promoted to parents or reused as a clean input.

Cleanup stops only the VM registered for the active run and removes only the
registered child resources. Names, partial paths, wildcard searches, recursive
root deletion, and broad Hyper-V cleanup are insufficient deletion authority.
The parent must survive every child cleanup unchanged.

## Management boundary

PowerShell Direct is the required guest-management channel for the canonical
Windows single-host path. Its readiness is tested independently of the Lab data
network, so network-fault scenarios cannot remove the only recovery path.
PowerShell Direct availability is a host capability and remains
`NOT_EXECUTED` until verified on an approved Hyper-V host.

All values in this directory are public technical identifiers or clearly
synthetic contract terms. No real user, host, company, environment, network,
media, license, or infrastructure value is stored here.
