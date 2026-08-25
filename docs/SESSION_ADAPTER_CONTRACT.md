# Session adapter contract

This document defines the runtime boundary between the AgentSessionSync orchestrators,
the shared transaction engine, and each application adapter. Legacy transport layouts
are migration inputs only; they are not part of the runtime contract.

The supported adapters are Claude and Codex. This is an internal boundary for those two
implementations, not a plugin discovery API or a promise of registration-based expansion.

## Dependency boundary

- `AgentSessionSync.Common.ps1` owns configuration, Git coordination, path validation,
  immutable file snapshots, plan validation, transactions, publishing, and rollback.
- `CodexSessionState.Common.ps1` and `ClaudeSessionState.Common.ps1` only inspect their
  application and Vault state and return declarative plans.
- Adapters never dot-source or call another adapter.
- Adapters never write to the Vault, application storage, or checkpoint storage.

## Adapter entry points

Each adapter exposes four functions:

```text
New-<Agent>StartPlan
New-<Agent>FinishPlan
New-<Agent>RestorePlan
New-<Agent>CheckpointPlan
```

Plan creation may read live state and create immutable artifacts below `PlanRoot`.
A terminating error is the official abort channel. Warnings are reserved for cases
where continuing cannot violate the data contract.

## Plan schema

```text
SchemaVersion          1
Agent                  Codex | Claude
Phase                  Start | Finish | Restore | Checkpoint
ExpectedVaultCommit    full commit id
RootBindings           logical target roots used by this plan
VaultOperations        file operations
LocalOperations        file operations
Result                 final adapter state
Warnings               non-fatal messages
```

The operation key is `TargetRoot + RelativePath` and may appear only once across all
plans in one run. Adapters emit the difference between the initial and final inventory,
never intermediate moves.

`RootBindings` maps logical names such as `CodexHome`, `ClaudeHome`, and
`ClaudeRegistry` to absolute roots discovered while reading application state. The
orchestrator supplies `Vault` and `CheckpointRoot`. Conflicting bindings for the same
logical name abort the run before any file is changed.

Supported operations:

- `Put` from an immutable `StagedFile`.
- `Put` from a `VaultFile` at `ExpectedVaultCommit`, with SHA-256 verification.
- `Delete`.

Move is represented by one final Put and one Delete on different operation keys.

## Transaction ownership

The orchestrator also verifies that every `StagedFile` is below the run's `PlanRoot`.
The shared engine validates every plan before applying any operation. It backs up the
exact target files, applies operations, and restores only those targets in reverse order
when a pre-commit failure occurs. It never uses broad checkout, reset, or clean commands.

Before the first operation, every `VaultFile` source is checked against the expected
commit, a clean Vault worktree, and its planned SHA-256. Once application begins, the
engine rechecks the source commit and file hash but does not require the tree to remain
clean, because earlier operations in the same transaction may already have changed it.

After a Vault commit exists, a rejected push keeps that commit for retry. Local cleanup
and checkpoint updates occur only after the pushed commit is verified at the upstream.

Checkpoint plans are created after post-publish local operations have been applied.
They may read that resulting local state but still return writes as plan operations.
Every Vault-changing publish advances both application checkpoints to the same commit.

## Restore ordering

Restore commits and verifies the Vault change before requesting a graceful application
shutdown. If shutdown fails, local materialization is skipped; the Vault remains valid
and the next Start applies it. Applications are never force-terminated.
