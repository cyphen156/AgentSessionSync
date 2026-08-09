@{
    # Anchor project for Start/Finish. This does NOT limit which conversations are
    # transported: the transport unit is the agent app index, so every folder under
    # ~/.claude/projects and ~/.codex/sessions travels regardless of this value.
    ProjectRoot = 'C:\Projects\MyProject'

    # Optional: also git pull/push the target project from Start/Finish.
    SyncProjectGit = $false

    # Legacy. Worktree session folders are always transported now; kept for
    # backward-compatible config files.
    IncludeClaudeWorktrees = $true

    # Working-window in days. Claude sessions absent from the local app index and
    # Codex sessions whose last top-level event timestamp is older than this are
    # MOVED to their archive tier (never deleted). Restore-ArchivedSession.ps1 can
    # bring them back.
    ActiveWindowDays = 30

    # Raw Codex JSONL files above this transport threshold are stored as .jsonl.gz
    # and expanded back to JSONL during Pull. The default leaves margin below
    # GitHub's hard 100MiB per-file limit.
    TransportFileLimitBytes = 99614720

    # Leave empty to use %USERPROFILE%\.claude and %USERPROFILE%\.codex.
    ClaudeHome = ''
    CodexHome = ''

    # Safety gate. Enable only in your own PRIVATE transport repository.
    SessionDataPushEnabled = $false

    # Seconds to wait for every registered desktop agent to close cleanly.
    GracefulCloseTimeoutSeconds = 20
}
