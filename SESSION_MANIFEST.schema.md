# AgentSessionSync Manifest Schema

The current implementation uses a fixed built-in manifest so a session vault can
transport agent conversations without extra configuration. Paths are relative to the
session store root (the repository this tool runs in — normally your private
`AgentSessionVault`).

The transport unit is the **agent app index, not a project**. `ProjectRoot` anchors
Start/Finish only; it never narrows what is carried. Every folder under
`~/.claude/projects` travels under its own name.

Default included (transported) session state:

```text
Claude/projects/<cwd-key>/*.jsonl                  # Claude Code project sessions (active tier)
Claude/archive/<cwd-key>/*.jsonl                   # Claude sessions kept forever (never restored)
ClaudeApp/claude-code-sessions/**/*.json           # Claude desktop app session registry
ClaudeApp/claude-code-sessions/**/deleted_<id>     # app-written deletion markers (tombstones)
ClaudeApp/archive/**/*.json                        # retired list entries (never restored)
Codex/sessions/<cwd-key>/YYYY/MM/DD/*.jsonl[.gz]   # Codex rollout sessions (active tier)
Codex/archive/<cwd-key>/YYYY/MM/DD/*.jsonl[.gz]    # Codex rollouts kept forever (never restored)
Codex/session_index.jsonl                          # Codex active session index
Codex/archive_index.jsonl                          # Codex archived session index
Codex/session_projects.jsonl                       # semantic project tags for Codex sessions
ACTIVE_HOST.txt                                    # single-writer baton (which host holds the lock)
```

Default excluded (never transported):

```text
auth.json, config.toml                       # credentials
*.db, *.sqlite, *.sqlite3                    # local databases (incl. Codex state_5.sqlite)
*.key, *.pem, *.pfx, *.env                   # keys / secrets / environment
AgentSessionSync.config.psd1                 # machine-local tool configuration
~/.claude/**/memory/*.md, ~/.codex/memories  # machine-local agent memory, owned by the agent
UserSettings/**/*.md, Projects/<name>/RULES.md   # owned by MultiAgentWorkbenchStateSync, not this tool
```

Rules:

- **Two retention tiers.** `Claude/projects`, `ClaudeApp/claude-code-sessions`, and
  `Codex/sessions` are the active working set and the only thing Pull restores.
  `Claude/archive`, `ClaudeApp/archive`, and `Codex/archive` are permanent storage and
  are never restored automatically. Push **moves** into the archive tier; it never
  deletes from the vault.
- **`<cwd-key>` is a deterministic key derived from the originating absolute path.**
  For Claude it is the app's own folder name, carried verbatim. For Codex it is derived
  from the first `session_meta.payload.cwd` inside the rollout and exists only in the
  vault copy — Pull strips it and restores the app's plain `YYYY/MM/DD` tree. Rollouts
  whose cwd cannot be read go under the technical key `_no-cwd`, which is isolation,
  not classification.
- **Physical path and semantic project are separate.** Many-to-many project tagging
  lives in `Codex/session_projects.jsonl`, so re-classifying a session never moves a
  large rollout file.
- **The app registry merges per entry, not per file.** An entry that still holds its
  `cliSessionId` beats one that has lost it, in both directions. Whole-file copy would
  let a half-written host destroy the other host's bindings.
- **`deleted_<id>` markers are tombstones and are transported.** They retire the list
  entry on both hosts; the transcript itself is preserved in the archive tier.
- **Entries whose transcript is present in neither tier are left alone** — not deleted,
  not auto-archived. The other host may hold the only copy.
- Push scans for common secret token shapes on the local source **before** copying into
  the vault worktree; a match aborts the push. It is a guard, not a guarantee — keep the
  session vault private.
- Raw conversation JSONL can contain system instructions, tool output, absolute paths,
  and private code. It belongs only in a private vault, never in a public repository.
- A concrete example of this layout (with synthetic, non-real content) lives in
  [`examples/session-store/`](examples/session-store/).
