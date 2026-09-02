# Rule Context Cache Policy

Status: AUTHORITATIVE — REQUIRED when rule-context caching is used

## Purpose and authority boundary

A Rule Context Cache may reduce repeated model ingestion and semantic analysis of unchanged repository governance and context. It is an optional acceleration mechanism, never a source of rules or authority.

The repository files at the current working tree remain the source of truth. System/developer/current-user messages and platform, permission, and runtime instructions supplied outside discovered instruction files remain outside this cache. Native client instruction discovery is not replaced: at the start of every run or TUI session, Codex still discovers and applies its applicable `AGENTS.override.md`/`AGENTS.md` chain. The cache independently fingerprints those files and the resulting scope only so reuse of additional repository analysis can be rejected safely.

## Smallest safe architecture

Keep semantic rule analysis in session memory, keyed by the record's per-source `analysis_key`. This is sufficient to avoid repeated analysis between change waves in one run and does not create a second durable store of rule meaning.

A local persistent record is useful only as a non-authoritative fingerprint and dependency index across checks or runs. It stores no rule text, semantic summary, prompt, secret, or absolute host path. A later run may reuse an analysis only when that analysis is actually available under the exact validated `analysis_key`; a fingerprint hit does not invent or reconstruct missing analysis.

Persistent records must remain local and non-versioned. Store them in a project-authorized cache location outside version control. Never commit a cache record or use it as validation evidence. A pure cache check is read-only; only an explicit record operation may create or replace a local record.

The reference planner rejects an in-repository check or write destination unless the exact record path is untracked and covered by the repository's existing Git ignore rules. It never changes `.gitignore` on the caller's behalf. A cache directory outside the repository remains the preferred default when the project's handling policy permits it.

## Discovery and cache identity

For every check, resolve and fingerprint:

1. stable repository identity derived from the normalized origin locator and root commit identity when available;
2. a digest of the canonical repository root and a separate worktree identity, without storing the absolute path;
3. the current working directory as a canonical repository-relative path;
4. the complete applicable instruction chain in exact precedence order: global instruction first when included, then one discovered project instruction per directory from repository root through the current working directory;
5. instruction discovery settings, including ordered fallback filenames, the effective `project_doc_max_bytes`, and an optional effective-configuration tag;
6. every additional rule/context source reached through authoritative repo-map entries, explicit rule inputs, and supported repository-relative discovery links;
7. every source's canonical relative path, actual working-tree content fingerprints, Git `HEAD` and index blob IDs when present, tracking/dirty state, and dependency edges;
8. cache schema, contract, generator, and text-normalization versions.

Global instruction sources use logical names such as `@global/AGENTS.md`; their host locations are not recorded. Their content participates in the exact instruction-chain fingerprint, but the repository cache does not follow user-level relative links from them. Repository instruction sources anchor transitive repository-rule discovery and all repository sources use canonical forward-slash relative paths. Instructions supplied outside discovered instruction files are always applied directly by the runtime and are never represented as reusable repository analysis.

If effective discovery configuration cannot be established, a recognized reference cannot be resolved, the working directory is outside the repository, sources change during discovery, or the instruction byte limit is exceeded, discovery is incomplete and the result is `CACHE_MISS`.

## Content and Git fingerprints

The actual working-tree bytes are hashed on every check. Hashing is local deterministic I/O; the saved cost is repeated model-context ingestion and semantic analysis, not filesystem reads.

Each record keeps both:

- `raw_sha256` for the exact working-tree bytes; and
- `semantic_sha256` under the Foundation portable-text policy.

For valid UTF-8 text, CRLF is normalized to LF before the semantic hash is calculated. UTF-8 LF/CRLF-only representation changes are therefore equivalent. Lone CR, final-newline presence, encoding changes, NUL-containing data, non-UTF-8/binary data, and actual text changes remain significant. Git blob IDs and dirty state supplement rather than replace the working-tree hashes; `HEAD` alone can never establish a hit.

Staged, unstaged, and untracked relevant sources are valid inputs and are fingerprinted as they exist. A record may be created from a dirty worktree after the caller has analyzed that exact state. Any later semantic content or relevant Git-state change invalidates the corresponding analysis. Unrelated working-tree changes do not affect the rule cache.

## Decision states

### `CACHE_HIT`

Use only when repository/worktree identity, working-directory scope, discovery configuration, instruction paths/order/content, source set, dependency graph, semantic content, and relevant Git state all match a structurally valid record. Reuse only analyses whose exact `analysis_key` is available. No unchanged additional rule requires renewed semantic reading.

An LF/CRLF-only byte-representation difference may still be a hit and is explained by `EOL_REPRESENTATION_EQUIVALENT`.

### `PARTIAL_INVALIDATION`

Use only when the instruction chain, scope, source set, and dependency topology are unchanged, while one or more non-instruction rule/context sources changed. Fully reread and analyze each changed source plus every transitive semantic dependent. Reuse independent sources whose analysis keys remain available.

### `CACHE_MISS`

Fully rebuild the rule context when any global invariant is unknown or changed, including:

- new/unknown working-directory scope;
- any instruction-chain path, order, content, or Git-state change;
- a newly applicable scoped instruction or override;
- repository, canonical-root, or worktree mismatch;
- discovery fallback/limit/effective-configuration change;
- source addition, removal, rename, move, or delete;
- repo-map/reference topology change or unresolved reference;
- schema, contract, generator, or normalization-policy change;
- malformed, incomplete, digest-invalid, or missing cache record;
- instruction byte-limit overflow; or
- concurrent source mutation during discovery/recording.

Uncertainty always resolves to `CACHE_MISS`, never to a hit or partial reuse.

## Required reason codes

Implementations may add codes but must preserve these meanings:

| Code | Meaning |
|---|---|
| `CACHE_RECORD_VALID` | All hit invariants matched. |
| `CACHE_RECORD_NOT_FOUND`, `SCOPE_UNKNOWN` | No validated record exists for the current repository/worktree/working-directory key. |
| `CACHE_RECORD_WRITTEN`, `CACHE_RECORD_NOT_WRITTEN` | An explicit record operation completed, or safely declined because no stable complete snapshot existed. |
| `EOL_REPRESENTATION_EQUIVALENT` | Only permitted UTF-8 LF/CRLF representation differed. |
| `RULE_CONTENT_CHANGED` | A non-instruction source's semantic content changed. |
| `RULE_GIT_STATE_CHANGED` | A relevant source's index/HEAD/tracking state changed materially. |
| `TRANSITIVE_DEPENDENT_INVALIDATED` | A dependent analysis must be rebuilt because an input changed. |
| `INSTRUCTION_CHAIN_CHANGED` | Applicable instruction paths or order changed. |
| `INSTRUCTION_CONTENT_OR_GIT_STATE_CHANGED`, `INSTRUCTION_CHAIN_FULL_INVALIDATION` | An instruction source changed and the complete context is invalid. |
| `SOURCE_SET_CHANGED`, `SOURCE_ADDED`, `SOURCE_REMOVED`, `SOURCE_RENAMED_OR_MOVED` | The source identity set changed. |
| `DEPENDENCY_GRAPH_CHANGED`, `UNRESOLVED_REFERENCE` | Discovery dependencies changed or could not be resolved. |
| `DISCOVERY_CONFIGURATION_CHANGED`, `DISCOVERY_SIZE_LIMIT_EXCEEDED` | Effective discovery configuration changed or made discovery incomplete. |
| `GLOBAL_DISCOVERY_UNAVAILABLE`, `REPOSITORY_INSTRUCTION_CHAIN_EMPTY`, `INSTRUCTION_OUTSIDE_REPOSITORY`, `RULE_SOURCE_ENCODING_UNSUPPORTED` | Required discovery could not be modeled completely and safely. |
| `CACHE_SCHEMA_CHANGED`, `CACHE_CONTRACT_CHANGED`, `CACHE_GENERATOR_CHANGED`, `CACHE_NORMALIZATION_POLICY_CHANGED` | The record is from another contract implementation/normalization version. |
| `CACHE_RECORD_CORRUPT` | Parsing, shape, or self-digest validation failed. |
| `REPOSITORY_CHANGED`, `CANONICAL_ROOT_CHANGED`, `WORKTREE_CHANGED`, `WORKING_DIRECTORY_CHANGED` | Repository or scope identity differs. |
| `SOURCE_CHANGED_DURING_DISCOVERY` | A stable snapshot could not be established. |
| `CACHE_OPERATION_FAILED` | The planner could not complete a bounded local operation; the CLI returns nonzero and no reuse is allowed. |

## Persistence, concurrency, and recovery

Serialize records deterministically. Writers use a per-record exclusive lock, write a complete temporary file in the destination directory, flush it, and atomically replace the record. Recheck the source snapshot while holding the lock. A lock timeout or concurrent change is a miss and must not leave a partially trusted record.

Do not silently break or delete a lock whose owner is unknown. After confirming no writer remains, recovery consists of removing the local lock/record through the project's normal local-cache procedure and running a full discovery/read/analysis before recording again. A damaged record is disposable; repository files require no recovery because cache operations never mutate them.

## Privacy and evidence

Records contain digests, canonical repository-relative paths, source roles, sizes, Git object IDs, state labels, dependency edges, and analysis keys only. They contain no source bytes, summaries, prompts, environment values, usernames, home paths, cache-directory paths, credentials, or other runtime state.

Hash values are integrity metadata, not authorization credentials and not proof of semantic correctness. Do not publish a local cache as evidence. If a project's relative filenames themselves are confidential, keep the entire record within that project's authorized local handling boundary.

## Reference capability and adoption

The optional `rule-context-cache` capability installs the dependency-free reference planner and validator. It exposes read-only `check` and explicit atomic `record` operations with JSON or explain output. Projects may implement the same contract in another language or integrate it into an agent/session manager.

For adoption:

1. keep native client instruction discovery active on every new run;
2. configure the effective fallback names and size limit;
3. perform the first complete rule read and semantic analysis for the scope;
4. write the local record only after that analysis succeeds;
5. before every later change wave, run `check`;
6. on `CACHE_HIT`, reuse available analysis keys;
7. on `PARTIAL_INVALIDATION`, reread the reported sources and transitive dependents, then record the new analyzed state;
8. on `CACHE_MISS`, fully rediscover/read/analyze and record again.

Caching remains optional. If the capability is absent or any invariant cannot be demonstrated, use the safe full-read path.
