# Current Request Context Contract

Status: `IMPLEMENTED_ACTIONS_GATE`  
Work item: `DIAG-004`  
Public contract: `Metadata/Quality/CurrentRequestContext_Public_Contract.json`

## Purpose

`monitor.USP_CurrentRequests` exposes a stable request-evidence contract without replacing its legacy `requests` output. The additive result sets separate request context, statement text, batch text, input-buffer text, source status and warnings so that unavailable evidence cannot be mistaken for an empty value.

`monitor.USP_CurrentOverview` owns the shared invocation snapshot. The same snapshot can be consumed by Current Sessions, Requests, Blocking, Waits, Transactions, Memory Grants, TempDB and I/O.

## Canonical result sets

| Result name | Meaning | Cardinality |
|---|---|---|
| `requestContext` | Request, connection, wait, task, scheduler, transaction, memory-grant, TempDB, Resource-Governor and query identity context | Zero or one row per retained request |
| `snapshotStatus` | Provenance, capture interval, row count and status per source | One row per captured or explicitly omitted source |
| `statements` | Offset-validated current-statement evidence | One row per retained request |
| `batches` | Optional full-batch evidence | One row per retained request |
| `inputBuffers` | Optional post-candidate input-buffer evidence | One row per retained request |
| `warnings` | Structured non-fatal findings | Zero or more rows |

All canonical evidence rows carry the request identity and, where applicable, the shared `SnapshotId`. RAW, JSON and named TABLE output use the same source tables. JSON schema version 4 adds these arrays while preserving `requests`.

## Source and time semantics

The snapshot owner uses contract version 2. It materializes only the source groups required by enabled consumers. Every requested DMV or DMF is read at most once by the owner during an Overview invocation. SQL text is deduplicated by handle and bounded before the DMF call.

`CapturedAtUtc` and `CompletedAtUtc` belong to the individual source. The resulting evidence is intentionally not described as transactionally atomic: a request can finish between two source reads. Each consumer therefore exposes the shared snapshot identity plus source-specific time and availability.

Standalone procedure calls always read fresh local sources. A parent snapshot is accepted only when its ID, owner session and contract version match the current invocation.

## Text boundaries

- Statement text is derived only when SQL text was requested and the recorded byte offsets are valid.
- Full batch text is independent from statement text and remains opt-in.
- Input buffers are read only after filtering and row limiting. They are text evidence, not complete parameter evidence.
- `IsTruncated`, character count and byte count describe every returned text payload.
- `NOT_COLLECTED`, `ENCRYPTED`, `INVALID_OFFSETS`, `TEXT_UNAVAILABLE`, `TEXT_TRUNCATED` and `REQUEST_FINISHED` remain distinguishable.

`NULL` text combined with a status code expresses unavailable or omitted evidence; it is never silently interpreted as an empty executed statement.

## Partiality and errors

Every source has a `StatusCode`, `IsPartial`, row count and optional SQL error. Permission failures, lock timeouts and handled source errors remain local to their source whenever possible. `NOT_COLLECTED` means the caller did not request that source and does not by itself make the overall result partial.

The framework does not start Extended Events sessions, change server configuration or persist runtime payloads for this contract.

## Compatibility

The legacy `requests` result is unchanged. Existing callers can continue consuming it. New callers should use the canonical result sets and treat `SnapshotId`, source times and status fields as the evidence boundary.
