@{
    # Active window in days. Age comes from the last valid conversation record,
    # not file mtime or Git history. Aged sessions move to the Vault Archived
    # tier. Codex removes the measured app-local state with rollback protection;
    # Claude Finish does not change its app-local store for Vault Archive.
    ActiveWindowDays = 30

    # Payloads above this transport threshold are stored as .jsonl.gz with an
    # integrity sidecar and expanded back during Start. The limit belongs to the
    # destination repository, not to either app: it sits under GitHub's hard
    # 100 MiB per-file ceiling so a large payload is carried compressed instead
    # of through Git LFS. Both apps use the same value.
    TransportFileLimitBytes = 99614720

    # Seconds to wait for every registered app to close cleanly. Finish
    # terminates whatever remains after this; Start and Reactivate never do.
    GracefulCloseTimeoutSeconds = 8

    # One block per app. Enabled is the registration: an app that is not
    # enabled is never called, even if its scripts exist. Initialize writes the
    # real paths for this machine.
    Codex = @{
        Enabled = $true
        Home = ''
        # Optional environment mappings, recorded by Initialize. No session IDs.
        # PathMappings maps source workspace prefixes to existing local roots.
        # ProjectIdMappings maps source project registrations to local ones.
        # Leave empty when the existing target registration/path is unambiguous.
        PathMappings = @{}
        ProjectIdMappings = @{}
        AppId = ''
        ProcessNames = @()
    }

    Claude = @{
        Enabled = $true
        Home = ''
        AppData = ''
        AppId = ''
        ProcessNames = @()

        # Lineage transcripts the user has confirmed are gone, keyed by the
        # appSessionId of the conversation that refers to them. Keyed that way
        # because cliSessionId rotates on every rewind and would stop naming
        # the approved conversation.
        #
        # Finish publishes such a session only when the listed identifiers are
        # exactly the ones actually absent, and records them in the published
        # manifest so other machines inherit the approval instead of being
        # asked again. Nothing is added here automatically; a new loss needs a
        # new explicit entry. Leave it empty unless a loss has been confirmed.
        #
        #   AcknowledgedMissingLineage = @{
        #       '00000000-0000-4000-8000-000000000000' = @(
        #           '11111111-1111-4111-8111-111111111111'
        #       )
        #   }
        AcknowledgedMissingLineage = @{}
    }
}
