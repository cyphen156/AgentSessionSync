# Private Vault layout example

This directory contains synthetic placeholders only. It demonstrates the current-tree contract of a private
AgentSessionVault; it is not a second specification.

```text
Claude/projects/<cwd-key>/*.jsonl
Claude/archive/<cwd-key>/*.jsonl
ClaudeApp/claude-code-sessions/**/*.json
Codex/session_index.jsonl
Codex/session_projects.jsonl
Codex/sessions/<cwd-key>/YYYY/MM/DD/*.jsonl[.gz]
Codex/archive/<cwd-key>/YYYY/MM/DD/*.jsonl[.gz]
```

Active and Archived are mutually exclusive. A deleted session is absent from the current tree; Git history may
still contain an older copy. Codex native `archived_sessions` is not part of this Vault layout.

Never place real conversations, credentials, app databases, machine-local configuration, or agent memory in the
public repository.
