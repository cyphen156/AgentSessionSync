# Implementation Plan

Fixed requirements, the agreed composition, and the build order for the
rewrite of this tool. Recorded 2026-08-31 after cross review between the two
agents. Nothing here is a proposal: every item was confirmed by the user.

Do not add a policy that is not in this document. If a new decision is
genuinely needed, report only the point that conflicts with an existing
decision, with evidence, and do not reopen a settled item.

## Part 1. Fixed requirements

These did not change during the design discussion. Everything else is derived
from them.

1. **Sync Codex and Claude conversation sessions between PCs.** Not a single
   current file: the whole conversation from its origin to now, including
   lineage, attachments and the records the app needs to display it.
2. **It must be usable in the app.** A file existing is not the same as the
   conversation opening and continuing. Start must apply up to a usable state.
3. **Payloads move byte for byte.** No re-serialisation, no encoding, BOM or
   newline changes. gzip transport only when a Codex payload exceeds the
   existing 95 MiB threshold, and the restored payload is verified too.
4. **Three states: Active, Archived, Deleted.**
   - Archived after 30 days measured from the last valid conversation record
   - mtime, file name dates and Git timestamps are not the baseline
   - only a proven deletion propagates
   - inferring deletion without proof is forbidden
   - the same payload cannot be in Active and Archived at once
   - the app's own `isArchived` belongs to the app; the tool does not write it
5. **User entry points are exactly Start, Finish, Reactivate and Initialize.**
   Reactivate and Initialize were added because they serve a real user
   function; that set is now closed. There is no gate and no preflight concept.
6. **Finish closes every registered app first**, then prepares each app's data,
   and publishes once, jointly, only when everything verified. A partial Finish
   that publishes one app must not be constructible.
7. **Start and Finish are asymmetric.**
   - Start: partial application across apps can happen; report overall Failure
   - Finish: partial publication is impossible
   - always report which app applied and what failed
   - repeated runs must not create duplicates, fragments or loops
8. **The baton stays.** `ACTIVE_HOST.txt` is not a lock; it records which PC is
   in use.
   - dirty Vault fails before the claim
   - another PC holding it produces a warning, then the current PC takes over
     automatically
   - the claim commit is pushed and verified against the remote
   - failure recovery only when every safety condition holds
   - a normal Finish releases to `NONE`; `KeepBaton` keeps the current PC
9. **The checkpoint is a deletion safety net, not an ownership lock.** Missing
   or stale means warn and stop deletion inference; it does not by itself block
   a Finish. Absence that has not been verified never deletes a payload.
10. **Git conflict policy is already decided.** On a rejected push, fetch and
    merge up to three times. Different paths union, the same path warns and
    prefers the current host's copy, and merge parents are preserved.
11. **A structural change is surveyed by a person.** The tool reports the
    difference and its impact. The user reads that and explicitly asks for a
    full survey. There is no automatic survey.
12. **There is no format conversion feature.** An unknown structure is never
    converted. If it cannot be handled safely the result is Failure. Payloads
    stay byte-preserved.
13. **Public and private are separated.**
    - public AgentSessionSync: tool code, synthetic structure examples,
      per-version structural changes, the survey guide
    - private AgentSessionVault: real sessions, real identifiers, paths, hashes
      and survey records
    - agent memory, workbench state and project sources are not session data
14. **Other tools are not touched.** MultiAgentCrossReview only aggregates each
    tool's result. A WorkbenchStateSync failure does not block AgentSessionSync.
    ProjectSync is separate.
15. **Three results.** `Success` / `Failure` / `Skipped` with a concrete reason.
    Partial success is an overall Failure. A normal Skipped is not a failure.

## Part 2. Composition

### 2.1 Scope

Modified: `AgentSessionSync` only.
Data store: `AgentSessionVault`.
Not modified: MultiAgentCrossReview, WorkbenchStateSync, ProjectSync, the Codex
and Claude apps themselves, agent memory, general application settings.

### 2.2 Files

```
AgentSessionSync/
  Launchers/
    Start.ps1
    Finish.ps1
    Reactivate.ps1
    Initialize-AgentSessionSync.ps1
    Codex/
      Start.ps1
      Finish.ps1
      Reactivate.ps1
    Claude/
      Start.ps1
      Finish.ps1
      Reactivate.ps1
  docs/
    CODEX_SESSION_STRUCTURE.md
    CLAUDE_SESSION_STRUCTURE.md
    SURVEY_GUIDE.md
    IMPLEMENTATION_PLAN.md
  AgentSessionSync.config.example.psd1
  .gitattributes
  .gitignore
  README.md
  LICENSE
```

Ten PowerShell entry files. No common script, no gate, no preflight entry
point, option or mode, no conflict-resolution script, no separate PowerShell
test file in this repository.

### 2.3 Responsibilities

Root scripts own execution order, Vault Git, the baton, closing and launching
apps, staging creation and cleanup, joint publication, and result aggregation.

Per-app scripts own their app's storage format, identifiers and lineage,
deletion and archival decisions, app records and placement, local application
and per-app recovery, and the data for their checkpoint.

Per-app scripts never touch Git and never stop or start an app process.

### 2.4 Public and private boundary

Remove these session payload allowances from the public `.gitignore`:

```
Claude/**/*.jsonl
Claude/**/*.entry.json
Codex/**/*.jsonl
Codex/**/*.jsonl.gz
Codex/**/*.jsonl.gz.integrity.json
```

Session payload allowances exist only in the private Vault.

### 2.5 Configuration

```powershell
@{
    VaultRoot = '<path to AgentSessionVault>'

    ActiveWindowDays = 30
    TransportFileLimitBytes = 99614720

    Codex = @{
        Enabled = $true
        Home = ''
        AppId = ''
        ProcessNames = @()
    }

    Claude = @{
        Enabled = $true
        Home = ''
        AppData = ''
        AppId = ''
        ProcessNames = @()
    }

    GracefulCloseTimeoutSeconds = 8
}
```

`Enabled` is the registration. An unregistered app is not executed even if its
files exist. A registered app whose scripts or required paths are missing is a
Failure. The real per-machine file is excluded from Git. There is no
`SessionDataPushEnabled`.

Initialize verifies: `VaultRoot` differs from the public tool root, the Vault is
a separate Git repository, the required Git attributes are applied, app paths
and registration, and the local checkpoint directory.

### 2.6 Vault layout

```
AgentSessionVault/
  ACTIVE_HOST.txt
  Codex/
    Active/
    Archived/
    Deleted/
  Claude/
    Active/
    Archived/
    Deleted/
  Surveys/
    Codex/
    Claude/
```

The same session cannot be in Active and Archived at once. Deleted holds no
payload, only the minimal deletion record. Surveys are dated Markdown. Every
registered app's Finish data is published in one joint commit.

### 2.7 Local checkpoint

```
%LOCALAPPDATA%\AgentSessionSync\State\
  Codex.json
  Claude.json
```

Holds the last applied Vault commit, the last Active id set, the app id to
`vaultSessionId` mapping, the last synchronised lineage, the last valid
conversation record position or fingerprint, and the prior existence state
needed for deletion decisions.

It is not an ownership lock. Missing or stale means warn and stop
checkpoint-based deletion inference; that alone does not block the whole Finish.
A session that cannot be judged is neither deleted nor uploaded. Nothing
advances before publication is confirmed. Start advances only the apps that
succeeded.

### 2.8 Start

```
 1  Load configuration, confirm registered apps
 2  Check Vault worktree and remote
 3  Join with the remote
 4  Read-only check of known structure, lineage and payload integrity
 5  Read the baton
 6  Warn if another PC holds it
 7  Claim for this PC
 8  Push the claim commit and verify against the remote
 9  Check registered app run state
10  Request a graceful close for running apps
11  Confirm close per app
12  Let file handles settle for closed apps
13  Create the Start staging area
14  Codex Start
        place Vault Active locally
        remove local active data for Vault Archived
        remove verified local data for Vault Deleted
15  Claude Start
        same three steps
16  Update checkpoints for apps that succeeded
17  Clean up staging
18  Launch apps that succeeded
19  Report per-app and overall results
```

Partial application across apps is possible.

```
Codex : Success
Claude: Failure
Overall: Failure
```

A successful app's application is kept. A failed app restores what it changed.
A failed app's checkpoint does not advance. An incomplete application inside a
single app is a Failure, not a Success. Repeated runs do not duplicate an
already applied app. While applied work remains, the baton stays with this PC.

The previous baton is restored only when all five hold:

```
zero applications remain from this run
local HEAD  == claim commit
remote HEAD == claim commit
ACTIVE_HOST == this PC
Vault worktree clean
```

**Close failure.** Start and Reactivate never force-close. Per app:

```
Codex closed        -> Codex Start may apply
Claude did not close -> no local file, app state or checkpoint change for Claude
                        Claude is Failure
                        Codex's success is kept
                        Overall Failure, baton stays with this PC
```

An app that is already closed skips the close request and goes straight to
confirmation and handle settling.

**Why Start now closes apps.** Earlier versions only added and overwrote, so a
running app was tolerable. Steps 14 and 15 now remove local data, and removal
is irreversible. If the app is holding those files while updating its index,
the payload and the index diverge. Finish already waits for handles to settle
after killing the process tree because the kernel releases session file handles
late; deletion is more exposed than reading.

**Local removal conditions.**

```
Archived
    Vault Archived vaultSessionId
    + local checkpoint mapping matches
        -> remove local active data

Deleted
    Vault Deleted vaultSessionId
    + local mapping matches
    + lineageFingerprint matches
        -> apply the app's deletion state
        -> remove current and prior lineage payloads
        -> remove app records, placement and verified linked data
```

On any mismatch nothing is removed and the app reports Failure. File absence,
sidebar absence or a missing database row never justify removal on their own. A
local session that was never in the Vault is preserved.

### 2.9 Finish

```
 1  Load configuration, confirm registered apps
 2  Check Vault state, remote and any unpublished commit
 3  Confirm this process is outside the app process trees
 4  Request a graceful close for every registered app
 5  Handle remaining registered app process trees
 6  Confirm every registered app is closed
 7  Let file handles settle
 8  Create the Finish staging area
 9  Codex Finish
10  Claude Finish
11  Verify every registered app's readiness and its staged data
12  Stage the baton value: NONE, or this PC with KeepBaton
13  Create one joint commit only when all are ready
14  Push
15  On rejection, join with the remote and retry up to three times
16  Verify the published commit against the remote
17  After confirmation, clean up locally and advance checkpoints
18  Clean up staging
19  Report per-app and overall results
```

The baton value is staged at step 12 so that it is part of the same joint
commit. Releasing it after publication would require a second commit, and the
published commit would not carry the new baton value.

```
every registered app Ready
    -> publication may proceed

any registered app Failed
    -> the commit and push steps cannot be entered
```

A disabled app is not a target. If only one app is registered, publishing that
app in full is a normal Finish and not a partial publication.

### 2.10 Staging

```
%TEMP%\AgentSessionSync\<phase>-<run-id>\
  Codex\
  Claude\
  Backup\
```

The root script creates it; each per-app script uses only its own subtree. It
holds pre-application data and the local backups needed for recovery. A failed
app restores its own changes from there. It is cleaned up regardless of the
outcome, and a cleanup failure is included in the overall Failure reason. It
never holds the only copy of an original or the only recovery copy.

### 2.11 Baton

```
AgentSessionVault/ACTIVE_HOST.txt      value: NONE or <COMPUTERNAME>
```

A dirty Vault fails before the Start claim. Another PC holding it warns, and
the current PC takes over without asking. The claim commit is pushed and
verified. A Finish whose owner differs warns but continues. A normal Finish
releases to `NONE`; `KeepBaton` keeps this PC. A Finish that did not publish
never releases the baton as if it had succeeded. The baton is a record of which
PC is in use, not a lock. Git conflict checking is separate.

### 2.12 Git conflicts

Start joins with the remote before claiming. On a rejected push, fetch and then
merge and push up to three times. Different paths union. The same path warns and
prefers the current host's copy. Merge commits keep both parents. The final
remote commit is verified. Nothing is cleaned up locally and no checkpoint
advances before that confirmation.

**This applies to file path conflicts only.** It does not apply to semantic
state conflicts: Deleted and Active existing together, a Deleted session
continued on another PC, or the same `vaultSessionId` in different survival
states. Those are detected before the merge and are never auto-merged.

### 2.13 States

```
Active   --30 days elapsed------> Archived
Active   --verified app delete--> Deleted
Archived --verified app delete--> Deleted
Archived --Reactivate----------> Active
Deleted  ----------------------> restoration not supported
```

Priority is **verified delete > 30-day archive > active**. A session proven
deleted is never sent to Archived by the 30-day rule.

Archived is not applied to the local active store by a normal Start.

Deleted removes the payload from the latest Vault tree. Purging it from past
Git history is not performed.

### 2.14 Delete

Delete is not a separate command.

```
the user deletes in the app
  -> the next Finish confirms the deletion signal
  -> links it to the vaultSessionId and the whole lineage
  -> stages removal of the Active/Archived payloads
  -> joint Finish publication
  -> applied locally by the next Start on other PCs
```

Never delete on file absence alone, sidebar absence alone, or a missing
database row alone. If the deletion relationship cannot be proven, preserve the
payload. Nothing is cleaned up locally before publication is confirmed.

### 2.15 Deleted record

```
Codex/Deleted/<vaultSessionId>.json
Claude/Deleted/<vaultSessionId>.json
```

```json
{
  "schemaVersion": 1,
  "vaultSessionId": "...",
  "lineageFingerprint": "...",
  "lineageIds": ["..."],
  "deletedAt": "...",
  "source": "verified-app-delete"
}
```

`vaultSessionId` is the only key deletion is applied by. `lineageFingerprint`
identifies the session state at deletion time. `lineageIds` is reference
information for conflict detection and reporting, and never deletes another
session by itself. There is no `generation` field.

`lineageFingerprint` is the SHA-256 of a serialised, ordered record of each
lineage payload's identifier, relative path, raw length, raw SHA-256, and the
identifying information of its last valid conversation record.

The record is kept for as long as the Vault exists: no expiry, no archival, no
compaction, no cleanup. It holds no conversation text, title, attachment or MCP
configuration. It never permanently blocks an app identifier.

### 2.16 Delete and continuation conflict

Finish classifies a session in this order:

```
look in Active
  -> look in Archived
    -> look in Deleted
      -> only if absent from all three is it a new session candidate
```

A `vaultSessionId` present in Deleted therefore never reaches the new-session
branch and is never re-uploaded by a stale machine.

```
fingerprint matches      -> apply deletion, do not upload,
                            remove app state and local data, advance checkpoint
fingerprint differs      -> Failure
cannot be determined     -> preserve, warn; that alone does not block the Finish
```

On a differing fingerprint the session was continued elsewhere after the
deletion. Nothing is deleted, nothing is uploaded, no new id is issued, the
current-host merge preference is not applied, both sides are preserved, and the
commit step cannot be entered.

```
RESULT: Failure
REASON: Delete conflict
DETAIL: The session was deleted on another machine but contains newer local
        activity. Nothing was deleted or published. User review is required.
PUBLISHED_COMMIT: NONE
```

**The tool has no automatic conflict resolution.** It reports and the user
decides in the app.

Start behaves the same: matching fingerprint applies the deletion, a differing
or undeterminable one preserves the session and fails that app.

### 2.17 Claude

Owns `cliSessionId`, `priorCliSessionIds`, `local_*.json`, the
`deleted_<cliSessionId>` tombstone, `.desktop-released.json`, groups,
assignments and order, and the target machine's app id, path and MCP mapping.

The tombstone is the deletion signal. Payload absence is not deletion. The
tombstones of the whole lineage are checked. A tombstone that cannot be
interpreted fails the Finish. `isArchived` is read only; Vault Archived is the
tool's transport state.

Portable sidecar, replacing the old `schemaVersion: 1`:

```json
{
  "schemaVersion": 2,
  "vaultSessionId": "...",
  "currentCliSessionId": "...",
  "priorCliSessionIds": [],
  "display": {
    "title": "",
    "titleSource": "",
    "createdAt": 0,
    "lastActivityAt": 0,
    "completedTurns": 0
  }
}
```

It excludes the source machine's `accountId/deviceId` path, the source
`appSessionId`, MCP definitions and machine runtime settings. The target
machine's app id mapping lives in the local checkpoint.

See `CLAUDE_SESSION_STRUCTURE.md` for the measured structure.

### 2.18 Codex

Structures confirmed by survey: legacy and paginated forms, `history_base`,
predecessor ordinal and byte offset, canonical thread and physical page alias,
fork, guardian parent relationships, database projection, attachments, embedded
images and visualisations, and project, order and tab links.

**The Codex deletion signal is not established.**

```
deletion cannot be proven
    -> do not delete
    -> preserve the payload
    -> report SURVEY_REQUIRED
```

Absence-based deletion is forbidden. New, updated and archived sessions are
handled normally.

See `CODEX_SESSION_STRUCTURE.md` for the measured structure.

### 2.19 Payload transport

Read and write JSONL and attachments as bytes only. Never re-serialise.
Preserve encoding, BOM, newlines and the final newline. Verify raw length and
SHA-256. Check the effective Git text, EOL and content filters.

A Codex JSONL above `99614720` bytes (95 MiB) is transported as:

```
.jsonl.gz
.jsonl.gz.integrity.json    raw length, raw SHA-256, gzip length, gzip SHA-256
```

Start and Reactivate verify both the compressed file and the restored payload.

No Claude compression threshold is established.

### 2.20 Reactivate

Named `Reactivate` rather than `Recovery` or `Restore`, because the operation is
a state transition to Active and does not recover from damage.

Handles `Archived -> Active` only. Deleted restoration is not supported.

```
1  Select the app
2  Search Archived
3  Show id, title, project and last activity
4  The user selects
5  Verify the whole lineage and linked data
6  Archived -> Active
7  Commit, push, verify the remote
8  Request a graceful close if the app is running
9  Apply locally once closed
10 Update the checkpoint
11 Relaunch the app
12 Report
```

If the app does not close: no force close, nothing written locally, the Vault
Active transition stands, the result is Failure, and the published commit and
the reason for non-application are reported. The next Start can apply it.

Reactivate does not alter activity timestamps and introduces no grace field. A
session with no new activity may be archived again by the next Finish.

### 2.21 Structural change and survey

The tool reports the difference, its impact, and `SURVEY_REQUIRED`. It does not
survey, does not guess what a structure means, and does not change payload
format.

The user reads the report and explicitly asks; then an agent performs a full
survey. Measured evidence goes to the Vault; confirmed structure, synthetic
examples and the change log go to the public documents. If it cannot be handled
safely the result is Failure.

### 2.22 Results

```
Success   exit 0
Skipped   exit 200
Failure   any other exit code
```

```
RESULT
AGENT
PHASE
REASON
DETAIL
PUBLISHED_COMMIT
SURVEY_REQUIRED
```

Any Failure makes the overall result Failure. A normal Skipped is not a failure.
All Skipped makes the overall result Skipped. Partial application is a Failure
that states its scope. A local failure after a successful publication is a
Failure. An unconfirmed publication is a Failure.

### 2.23 PowerShell and encoding

Windows PowerShell 5.1 is the minimum compatible version. Both the 5.1 and the
PowerShell 7 execution paths must be verified; neither has been verified yet,
because no new code exists. New code, comments and messages are English ASCII. Existing
files are not bulk converted for encoding, BOM or newlines. New log and report
JSON is UTF-8 without BOM. Session payloads are transported as bytes.

### 2.24 Invariants

- Never infer a deletion that has not been verified
- A Finish that publishes only some registered apps must be impossible
- Never re-serialise a payload or convert its encoding
- Never guess what an unknown structure means
- Never blanket-overwrite an app database or global state
- Never clean up locally or advance a checkpoint before publication is confirmed
- Never treat the only original or the only recovery copy as scratch
- Never resolve a delete-and-continuation state conflict automatically

### 2.25 Features that do not exist

- A preflight entry point, option or mode
- A separate gate
- Automatic survey
- Automatic conflict resolution
- Generic agent auto-registration
- Background automatic synchronisation

## Part 3. Build order

Finish first: nothing can be received by Start until something can be
published.

```
 1  Launchers/Codex/Finish.ps1
        Codex lineage, attachments and state decisions
        byte-exact staging
        95 MiB gzip and integrity data
        Codex deletion stays unproven: preserve and report

 2  Launchers/Claude/Finish.ps1
        current and prior CLI lineage
        tombstones, delete and continuation conflict
        portable sidecar v2
        Active / Archived / Deleted staging

 3  Launchers/Finish.ps1
        close every registered app
        run both app Finish scripts
        all-ready gate
        joint commit and push
        baton, checkpoint, cleanup, reporting

 4  Launchers/Codex/Start.ps1
 5  Launchers/Claude/Start.ps1
 6  Launchers/Start.ps1
 7  Launchers/Codex/Reactivate.ps1
 8  Launchers/Claude/Reactivate.ps1
 9  Launchers/Reactivate.ps1
10  Launchers/Initialize-AgentSessionSync.ps1
```

Each step is checked for completeness inside its own script before the root
script integrates it. The first implementation target is Codex Finish.

### Removing the previous implementation

The previous implementation is still present in `Launchers/` and is not adapted.
It is not removed piecemeal: the three externally registered entry points
(`Start.ps1`, `Finish.ps1`, `Initialize-AgentSessionSync.ps1`) currently call the
old shared scripts, so deleting their dependencies first would leave the
registered tool half broken.

The old runtime therefore stays in place until all ten new scripts exist. One
final transition commit then replaces the contents of the three registered entry
points and deletes everything else from the previous implementation in a single
step:

```
Launchers/ old scripts   12   4 shared modules, Pull, Push, 3 Codex-only,
                              Restore-ArchivedSession, Test-SessionSecrets,
                              Create-Shortcuts
Launchers/tests/          7
Agents/                   2   registration now lives in the machine configuration
                        ----
                         21
```

The same transition commit also clears the remaining non-code leftovers of the
previous contract: the public `ACTIVE_HOST.txt` (the baton belongs to the
Vault), `docs/SETUP_WINDOWS.md` and `docs/TROUBLESHOOTING.md`, the
`examples/session-store/` tree built on the old `sessions/archive` layout, and
the `Agents/`, `ACTIVE_HOST.txt` and `examples/` allowances in `.gitignore`.
`README.md` and `AgentSessionSync.config.example.psd1` are rewritten for the new
contract in that commit.

Until then the repository intentionally holds both the previous implementation
and the documents describing the new one.
