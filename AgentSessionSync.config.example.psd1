@{
    # The project whose Claude/Codex conversations should follow you.
    ProjectRoot = 'C:\Projects\MyProject'

    # Optional: also git pull/push the target project from Start/Finish.
    SyncProjectGit = $false

    # Include Claude worktree session folders derived from the project path.
    IncludeClaudeWorktrees = $true

    # Leave empty to use %USERPROFILE%\.claude and %USERPROFILE%\.codex.
    ClaudeHome = ''
    CodexHome = ''

    # Safety gate. Enable only in your own PRIVATE transport repository.
    SessionDataPushEnabled = $false
}

