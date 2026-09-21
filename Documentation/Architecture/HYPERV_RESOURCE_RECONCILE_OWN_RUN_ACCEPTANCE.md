# Hyper-V Resource Reconcile Own-Run Acceptance

`resource-reconcile-own-run-acceptance` is separate from the existing
main-only `resource-reconcile-acceptance` mode. It accepts only a manual
dispatch from the workflow repository, an explicit SQL-2025
`SQL_PREPARED_SEALED` artifact ID, and the actual checked-out commit matching
`GITHUB_SHA`. A clone-source run ID is rejected.

The route invokes the existing supervisor and native runner to create and
clean up two operation-owned clones. It writes a local runner-temp receipt
with the artifact and checkout commit. The test-only pre-start interruption is
an injected executor failure, not evidence of a Hyper-V platform failure.

This route is implemented and offline-validated. Native evidence remains
`NOT_EXECUTED` until a trusted manual dispatch completes.
