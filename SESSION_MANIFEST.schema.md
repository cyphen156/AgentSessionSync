# AgentSessionSync Manifest Schema

The current implementation uses a fixed built-in manifest so a session vault can
transport agent conversations without extra configuration. Paths are relative to the
session store root (the repository this tool runs in — normally your private
`AgentSessionVault`).

Default included (transported) session state:

```text
Claude/projects/<project-key>/*.jsonl        # Claude Code project sessions (path-neutral key)
ClaudeApp/claude-code-sessions/**/*.json     # Claude desktop app session registry
Codex/sessions/YYYY/MM/DD/*.jsonl            # Codex rollout sessions
Codex/session_index.jsonl                    # Codex session index
ACTIVE_HOST.txt                              # single-writer baton (which host holds the lock)
```

Default excluded (never transported):

```text
auth.json, config.toml                       # credentials
*.db, *.sqlite, *.sqlite3                    # local databases (incl. Codex state_5.sqlite)
*.key, *.pem, *.pfx, *.env                   # keys / secrets / environment
AgentSessionSync.config.psd1                 # machine-local tool configuration
UserSettings/**/*.md, Projects/<name>/RULES.md   # owned by MultiAgentWorkbenchStateSync, not this tool
```

Rules:

- The Claude project folder is transported under a **path-neutral key** so two machines
  with different project paths still map to the same session on each side.
- Push scans for common secret token shapes before committing; a match aborts the push.
  It is a guard, not a guarantee — keep the session vault private.
- Raw conversation JSONL can contain system instructions, tool output, absolute paths,
  and private code. It belongs only in a private vault, never in a public repository.
- A concrete example of this layout (with synthetic, non-real content) lives in
  [`examples/session-store/`](examples/session-store/).
