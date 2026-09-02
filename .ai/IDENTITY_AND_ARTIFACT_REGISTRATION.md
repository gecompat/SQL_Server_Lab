# Persistent Identity and Artifact Registration

Status: AUTHORITATIVE PROJECT MAPPING
Stand: 2026-08-27

## Purpose

This document maps the Foundation 1.8 identity and registration baseline to
SQL_Server_Lab. It preserves established project identities and local runtime
registries; it does not introduce a global sequential identifier scheme.

## Adoption decision

Existing durable project references use `PRESERVE`. Published wave, decision,
requirement, test, release, operation, run, build and artifact references are
not renamed, reused or reinterpreted by this integration. Hierarchy, status,
owner, path and display name are mutable metadata, not authorization or a
reason to change an existing reference.

The Foundation UUIDv7 and flat typed human-reference defaults are not selected
for this existing repository. Any prospective change requires an explicit
`ADOPT_FORWARD` decision. Historical migration requires a separately authorized
`MIGRATE_EXPLICIT` plan with durable old-to-new mappings and recovery evidence.

## Scoped authorities

| Scope | Canonical identity and authority | Allocation and persistence |
|---|---|---|
| Hyper-V sealed images | `artifactId` is an immutable content-addressed `hyperv-<state>-<sha256>` value. `Import-HyperVImageArtifact` is the Registration Authority. | The local artifact store serializes writes with `Invoke-LabArtifactStoreLock`; SHA-256 is verified and the stored VHDX is read-only. |
| Lab-generated sample baselines | `baselineId` and `keyId` are allocated by `Register-LabSampleBaseline`. | Local `<StateRoot>/_baselines/registry.json`, atomic writes and content-hash evidence; never versioned. |
| Runs and scopes | `runId` and `scopeId` are generated and persisted by `New-LabRunState`. | Local StateRoot only; operational identities, not a project decision registry. |
| Trust/cache and manifest locks | Project artifact resolver and manifest-lock writers are authoritative for their local records. | Local StateRoot/cache only; SHA-256 and lock-based provenance, never versioned. |

Humans and AI use the same project code path for each listed scope. The
Foundation reference-client capability is intentionally unselected; Python is
not required and no Foundation client replaces a project authority.

## Central registry applicability

SQL_Server_Lab has no repository-native JSON Registration Authority for final
human references. The Foundation-v2 central-registry profile therefore does
not migrate or replace the scoped runtime authorities listed above. Their
registries remain non-versioned operational State outside the repository.

The optional `artifact-registry-github` capability is not selected. Introducing
a central project-artifact registry, generated planning views or semantic
GitHub merge gates requires a separate project decision that defines scope,
authority, migration, concurrency and recovery. Foundation installation alone
does not authorize that storage-model change.

## Human-reference boundary

SQL_Server_Lab currently has no project-wide allocator for new final sequential
human references. Existing historical labels remain preserved. Humans and AI
MUST NOT infer or allocate a new final sequence from Markdown, filenames, Git
history or model memory. A change that introduces such a scope must first name
a single Registration Authority, its uniqueness/concurrency behavior and its
`DIRECT` or `DEFERRED` allocation mode in this document and `.ai/repo_map.yaml`.

## Validation boundary

The Foundation schemas under `.ai/foundation/schemas/` are portable baseline
contracts. They do not replace SQL_Server_Lab runtime schemas or require local
runtime state to be versioned. Foundation validation proves installation
integrity only; project static checks validate this mapping, and runtime tests
remain required if an affected runtime authority changes.
