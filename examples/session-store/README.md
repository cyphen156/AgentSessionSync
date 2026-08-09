# examples/session-store

This is the **directory layout AgentSessionSync transports** between machines via
`Launchers\Start.ps1` (pull) and `Launchers\Finish.ps1` (push). It shows *what gets
synchronized* — not a working store.

> All file content here is **synthetic placeholder**, not a real session. Real
> conversation JSONL lives only in your private `AgentSessionVault`, never in a public
> repository. See [`../../SESSION_MANIFEST.schema.md`](../../SESSION_MANIFEST.schema.md)
> for the full include/exclude rules.

```text
session-store/
  ACTIVE_HOST.txt                                             # single-writer baton (lock holder)
  Claude/
    projects/                                                 # active tier - Pull restores this
      example-project/
        example-session.jsonl                                 # Claude Code project session
    archive/                                                  # permanent tier - Pull never restores
      example-project/
        archived-session.jsonl                                # moved out of the working set, not deleted
  ClaudeApp/
    claude-code-sessions/
      example-workspace/
        deleted_retired-session                               # tombstone written by the app
        example-session/
          local_example.json                                  # Claude desktop app session registry
    archive/
      example-workspace/
        retired-session/
          local_retired.json                                  # retired list entry (transcript preserved)
  Codex/
    session_index.jsonl                                       # active session index
    archive_index.jsonl                                       # archived session index
    session_projects.jsonl                                    # semantic project tags (many-to-many)
    sessions/                                                 # active tier
      C--Projects-ExampleProject/2026/01/01/
        rollout-example.jsonl                                 # Codex rollout session
    archive/                                                  # permanent tier
      C--Projects-ExampleProject/2025/11/02/
        rollout-archived-example.jsonl
```

Two things in this tree are easy to misread.

**The `<cwd-key>` folder is a transport axis, not the app's layout.** Codex stores
rollouts locally as a plain `~/.codex/sessions/YYYY/MM/DD/` tree. Push derives the key
from the first `session_meta.payload.cwd` inside the rollout and adds it to the vault
copy only; Pull strips it back off. Rollouts whose cwd cannot be read land under
`_no-cwd`, which is isolation, not classification. Semantic project membership lives in
`session_projects.jsonl` instead, so re-tagging never moves a large file. Claude's
folder name is the app's own key and is carried verbatim.

**The archive tier is not a delete.** The agent apps prune their own working set; if the
vault fed everything back on every Pull, the app index could never shrink. So Push
*moves* aged or explicitly-discarded sessions into `archive/` and Pull leaves them
there. Nothing is ever removed from the vault. `Launchers\Restore-ArchivedSession.ps1`
pulls one back into the active tier — an archive with no way out is a grave.

Excluded from transport: credentials (`auth.json`), databases (`*.sqlite`, incl. Codex
`state_5.sqlite`), keys, machine-local config, machine-local agent memory, and the
workbench state that `MultiAgentWorkbenchStateSync` owns.
