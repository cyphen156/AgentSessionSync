@{
    # Active window in days. Age comes from the last valid conversation record,
    # not file mtime or Git history. Aged sessions move to the Vault archive tier.
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
    # Timeout aborts the operation; the tool does not force-terminate the app.
    GracefulCloseTimeoutSeconds = 8
}
