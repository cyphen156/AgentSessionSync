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
    projects/
      example-project/
        example-session.jsonl                                 # Claude Code project session
  ClaudeApp/
    claude-code-sessions/
      example-workspace/
        example-session/
          local_example.json                                  # Claude desktop app session registry
  Codex/
    session_index.jsonl                                       # Codex session index
    sessions/
      2026/01/01/
        rollout-example.jsonl                                 # Codex rollout session
```

On a real store the Claude project folder is named with a **path-neutral key** (not the
literal project path), so two machines with different local paths still resolve to the
same session. Excluded from transport: credentials (`auth.json`), databases
(`*.sqlite`, incl. Codex `state_5.sqlite`), keys, machine-local config, and the
workbench state that `MultiAgentWorkbenchStateSync` owns.
