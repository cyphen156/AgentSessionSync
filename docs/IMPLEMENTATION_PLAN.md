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
   - Start success means the data was placed by the known structure rules and
     the app can be launched
   - it does not mean the app displayed the session, read every record as
     intended, or wrote its database as expected
   - nothing observable before the app runs can establish that, so the tool
     never claims it
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
   - a dirty Vault fails before Start runs at all
   - Start reads it before joining with the remote, and acts on what it says
   - **this PC** means the last Start was never finished, so Start asks before
     replacing local work that was never published
   - another PC produces a warning and no question; the run continues
   - Start updates it last, and only when every registered app succeeded
   - a partial application does not touch it; the next Start settles that locally
   - a normal Finish releases to `NONE`, or keeps this PC with `KeepBaton`
   - Finish only releases a baton this PC holds; another PC's value is left alone
9. **There is no local checkpoint file.** The Vault worktree is a Git clone, so
   the commit this PC last received is its `HEAD`, and what changed remotely
   since then is `git diff HEAD origin/main`. Nothing about session state is
   duplicated into a side file.
   - per-app results live in the current run and are reported, not persisted
   - a failed app rolls back its own changes; the next run judges every
     registered app again against the current remote
   - safety across repeated runs comes from per-app atomicity and idempotence,
     not from remembered state
   - persisting "this app already succeeded" would skip an app after the remote
     moved, which contradicts requirement 16
   - absence that has not been verified never deletes a payload
10. **Git conflict policy is already decided.** `origin/main` is the source of
    truth. On a non-fast-forward rejection, fetch, have each app judge again
    against the new remote, rebuild its contribution on that base and push
    again, up to three times. **Git is never asked to merge payload content.**
    Work on paths the remote has not itself changed since this worktree's
    `HEAD` can be rebuilt on top of it. Where both sides changed the same
    `vaultSessionId`, neither side is chosen: nothing is overwritten in either
    direction, nothing is published, and the whole joint Finish fails with the
    conflict reported.
    A push that fails for any other reason - authentication, permissions,
    network, a server hook - is an ordinary operational failure and is not
    evidence that the remote advanced. Force push and rewriting remote history
    are forbidden.
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
16. **The Vault's `origin/main` is the source of truth, and the guaranteed
    sequence is Start, then app use, then Finish.** Local state is a working
    copy that a later Start overwrites. A wrong state published to the remote
    spreads to every other PC and stays in the Git history, so the remote wins
    wherever the two disagree.
    - work made without a preceding Start is not a preservation target
    - Start applies the remote state over whatever is local
    - Finish publishes only changes made on top of the commit the last Start
      applied
    - the one exception is the first Finish against an empty Vault, which
      establishes the baseline from the complete local state
    - the cost is accepted: if two PCs touch the same session, the one that
      finishes later loses its conflicting work

Requirement 16 was added on 2026-09-02 after the user stated it explicitly.
Requirements 9 and 10 were amended in the same pass to agree with it. Every
other item is unchanged.

## Part 2. Composition

### 2.1 Scope

The public `AgentSessionSync` repository is the distribution original. A user
copies it, and **that copy is both the tool and the private Vault**: the
launchers, the session states and the survey records live in one repository.
There is no second checkout at runtime.

`
public AgentSessionSync     distribution original, holds no session
the user's copy             the installation, and the private Vault
`

Modified: `AgentSessionSync` only.
Not modified: MultiAgentCrossReview, WorkbenchStateSync, ProjectSync, the Codex
and Claude apps themselves, agent memory, general application settings.

### 2.2 Files

```
AgentSessionSync/
  Launchers/
    Start.ps1
    Finish.ps1
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

Nine PowerShell entry files. No common script, no gate, no preflight entry
point, option or mode, no conflict-resolution script, no separate PowerShell
test file in this repository.

**There is no root `Reactivate.ps1`.** Reactivate is a per-app user action, not
a joint operation: the user runs `Codex/Reactivate.ps1` or
`Claude/Reactivate.ps1` directly. A root script would only have asked which app
to use. Requirement 5 still holds - Reactivate remains a user entry point.

Initialize creates the session state directories inside this same repository:

```
Codex/Active   Codex/Archived   Codex/Deleted
Claude/Active  Claude/Archived  Claude/Deleted
Surveys/Codex  Surveys/Claude
ACTIVE_HOST.txt
```

### 2.3 Responsibilities

Root scripts own execution order, Vault Git, the baton, closing and launching
apps, staging creation and cleanup, joint publication, and result aggregation.

Per-app scripts own their app's storage format, identifiers and lineage,
deletion and archival decisions, app records and placement, local application
and per-app recovery.

Per-app scripts never touch Git and never stop or start an app process.

### 2.4 Public and private boundary

The boundary is between the distribution original and the user's copy, not
between two folders on one machine.

```
public original    session paths blocked. no conversation can be committed
user's copy        Initialize turns those paths on for the private Vault
```

The same `.gitignore` cannot serve both, so Initialize rewrites it. It keeps
deny-by-default, keeps the machine-local configuration excluded, and re-includes
the state directories - including their intermediate directories, without which
Git never descends far enough for the rule to apply.

The public original keeps these session payload allowances out:

```
Claude/**/*.jsonl
Claude/**/*.entry.json
Codex/**/*.jsonl
Codex/**/*.jsonl.gz
Codex/**/*.jsonl.gz.integrity.json
```

Session payload allowances are added by Initialize, in the user's copy only.

### 2.5 Configuration

```powershell
@{
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

There is no `VaultRoot`. The repository the scripts run from is the Vault, so
every Vault path is relative to it.

Initialize verifies and creates. It touches no session data and reaches no
remote.

```
verifies
    this copy is the root of its own Git repository
    the effective Git attributes preserve bytes, read with git check-attr
    the registered apps' Home and AppData paths exist
    AppId and ProcessNames are set for each enabled app

creates
    the six state directories and Surveys/Codex, Surveys/Claude
    ACTIVE_HOST.txt with NONE, when absent
    the .gitattributes byte-preserving rule
    the .gitignore private-Vault form
    the machine-local configuration, when absent
    the Start and Finish shortcuts

never
    session judgement, upload, deletion, survey
    running Start or Finish
    touching any remote
    editing the workbench registration, which lives in another repository
```

Checking the `.gitattributes` text is not enough: a global attributes file or
`.git/info/attributes` can override it, so the effective value is read per path.

### 2.6 Vault layout

```
<the user's copy of AgentSessionSync>/
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

This sits alongside `Launchers/` and `docs/` in the same repository. Initialize
creates all of it; no other step does.

The same session cannot be in Active and Archived at once. Deleted holds no
payload, only the minimal deletion record. Surveys are dated Markdown. Every
registered app's Finish data is published in one joint commit.

### 2.7 Where the reference state lives

There is no local checkpoint file and no `%LOCALAPPDATA%` state directory. The
Vault worktree is a Git clone of the private repository, and Git already holds
everything a run needs to judge against.

```
HEAD                              the commit this PC last received
origin/main                       the current remote, the source of truth
git diff HEAD origin/main -- <p>  what changed remotely under <p> since then
```

Finish asks exactly one question per session, and Git answers it:

```
the remote entry is unchanged since HEAD, local differs
    -> this PC's own work, publishable

the remote entry changed since HEAD
    -> this PC is behind, the remote wins
```

Session identity comes from `vaultSessionId` and, where a local record must be
matched to it, from the intersection of the local lineage identifiers with the
`lineageIds` in the Vault manifest. Those identifiers are globally unique and
the payloads are byte-identical across machines, so nothing has to be
remembered between runs to recover the mapping.

Per-app results belong to the run that produced them. They are aggregated and
reported, and then they are gone. A failed app rolls back its own changes and
the next run judges it again from scratch. Remembering that an app succeeded
would make a later run skip it after the remote had moved on.

A session that cannot be judged is neither deleted nor uploaded. Nothing is
cleaned up locally before publication is confirmed.

### 2.8 Start

```
 1  Load configuration, confirm registered apps
 2  Confirm the Vault worktree is clean, fetch origin/main, verify the Git result
 3  Read ACTIVE_HOST from origin/main
 4  Branch on the baton
        this PC    ask before discarding local work
        another PC warn, do not wait, continue
        NONE       continue
 5  Only once the run is confirmed: join the worktree with origin/main
 6  Close every running registered app and let file handles settle
 7  Codex Start
        place Vault Active locally
        remove local active data for Vault Archived
        remove verified local data for Vault Deleted
 8  Claude Start
        same three steps
 9  Only when every registered app succeeded: set ACTIVE_HOST.txt to this PC
10  Commit, push and verify against the remote
11  Launch apps that succeeded
12  Report per-app and overall results
```

**Step 2 fetches; step 5 joins.** They are separate because step 4 can stop the
run. Joining first would move the worktree `HEAD` before the user has answered,
losing the base commit the work in progress was built on - the very thing the
question exists to protect.

**Step 4, baton is this PC.** It means the last Start was never followed by a
Finish, so there may be local work that was never published. Continuing replaces
it with the remote state and it cannot be recovered, so the run asks first.

```
Local work that was never published will be replaced by the remote
state and cannot be recovered. Continue?
```

The other two branches never wait. Another PC holding the baton costs this run
nothing right now: it only means that PC has unpublished work, and its own user
finds out at their next Finish. Blocking here would strand this PC whenever the
other one is switched off.

Step 2 verifies the Git operation itself and the resulting commit. **It does not
inspect session content.** The root cannot: interpreting a rollout, a lineage or
a transcript requires app knowledge that section 2.3 places in the per-app
scripts, and steps 7 and 8 check it there.

Step 9 comes last, and only on full success. Claiming the baton before the work
would publish a commit for a run that may not happen, and would then need its own
conditional rollback. The baton is a record, not a lock (requirement 8), so an
early claim prevents nothing.

Partial application across apps is possible.

```
Codex : Success
Claude: Failure
Overall: Failure
```

A successful app's application is kept. A failed app restores what it changed.
An incomplete application inside a single app is a Failure, not a Success.

```
one or more apps failed
    -> the successful apps keep what they applied
    -> the failed app changed nothing
    -> the baton is not touched at all
    -> Overall Failure
    -> only the successful apps are launched
```

The baton is left alone because a partial application is a local matter. The
next Start judges every registered app against the current remote again and
overwrites or skips accordingly. There is nothing for the remote to know.

Nothing about that outcome is written down for the next run. Re-applying a state
that is already in place is a no-op or an identical overwrite, so repeated runs
do not duplicate or fragment anything; that is what makes remembering
unnecessary.

Because the baton is never claimed before the work, there is no claim to undo
and no restore procedure.

**Close failure.** Start and Reactivate never force-close. Per app:

```
Codex closed        -> Codex Start may apply
Claude did not close -> no local file or app state change for Claude
                        Claude is Failure
                        Codex's success is kept
                        Overall Failure, the baton is not touched
```

An app that is already closed skips the close request and goes straight to
confirmation and handle settling.

**Why Start now closes apps.** Earlier versions only added and overwrote, so a
running app was tolerable. Steps 7 and 8 now remove local data, and removal
is irreversible. If the app is holding those files while updating its index,
the payload and the index diverge. Finish already waits for handles to settle
after killing the process tree because the kernel releases session file handles
late; deletion is more exposed than reading.

**Start applies the remote state over the local one.** Requirement 16 makes the
fetched `origin/main` the reference. Local content that differs is not a reason
to stop: it is the state being replaced. What must be proven is *which session*
is being touched, never *whether its bytes still agree*.

```
Active
    Vault Active vaultSessionId
    + trusted local mapping
        -> place the Vault payload over the local one

Archived
    Vault Archived vaultSessionId
    + trusted local mapping
        -> remove local active data

Deleted
    Vault Deleted vaultSessionId
    + trusted local mapping
        -> apply the app's deletion state
        -> remove current and prior lineage payloads
        -> remove app records, placement and verified linked data
```

The removal conditions compare no payload contents at all. A local payload that
differs from the published one was made outside the guaranteed sequence, or was
superseded by another PC, and is not a preservation target.

"Trusted local mapping" means the local record can be tied to that
`vaultSessionId` by identifiers that exist in both places - the lineage ids in
the Vault manifest against the lineage ids the local app record declares. It is
not read from remembered state.

Three outcomes, and they must not be collapsed into one:

```
mapping proven, local content differs
    -> apply the remote state, discard the local content

nothing left to remove or replace
    -> Success, nothing to do
    -> this is what a second Start after an applied deletion looks like

mapping absent or contradictory
    -> the session cannot be identified
    -> remove nothing, report Failure with the actual difference
```

The last case is the only one that fails. Removing on an unproven mapping would
delete a different session. File absence, sidebar absence or a missing database
row never justify removal on their own. A local session that was never in the
Vault is preserved.

### 2.9 Finish

```
 1  Load configuration, confirm registered apps
 2  Check the Vault worktree and the remote Git state
 3  Confirm this process is outside the app process trees
 4  Close every registered app and let file handles settle
 5  Codex Finish
 6  Claude Finish
 7  Verify every registered app reports Ready
 8  If any failed, tell each app to cancel and clean up its own preparation
 9  Only when all are ready: set ACTIVE_HOST.txt to NONE, or to this PC with
    KeepBaton, or leave another PC's value untouched
10  Create one joint commit
11  Push
12  On a non-fast-forward rejection, fetch
13  Have each app re-judge and rebuild against the new remote
14  Retry up to three times while nothing conflicts
15  On a session changed on both sides, choose nothing and fail
16  Verify the published commit against the remote
17  After confirmation, tell each app to finish its local work
18  Report per-app and overall results
```

**The root owns no staging.** Each per-app script keeps whatever temporary area
and backups it needs, under paths of its own choosing, and the root never learns
their layout. It only sends `Prepare`, `Cancel` and `Complete`, and reads back
`Ready`, `Failure` with a reason, or `Complete`.

**The baton is written at step 9, not staged earlier.** It is one file in the
same worktree, so setting it immediately before the joint commit puts it in that
commit without any separate mechanism.

**Steps 12 to 15 do not merge file content.** A rejection means the remote moved,
so each app judges again against what is now there and rebuilds its own
contribution on the new base. Git is never asked to reconcile a payload; see
section 2.12 for why.

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

**Step 5 in detail.** Finish is the only phase that force-terminates; Start and
Reactivate never do. The procedure below is not a preference. Each line records
a failure the previous implementation actually produced.

```
 1  post WM_CLOSE to every top-level window the registered tree owns
 2  wait GracefulCloseTimeoutSeconds for the whole tree to exit
 3  a tree with zero top-level windows skips straight to termination
 4  after the timeout, or with no window at all, terminate the tree
 5  retry for up to ten seconds
 6  re-enumerate the process tree on every iteration
 7  re-validate process name and the WindowsApps path each time
 8  terminate only tree roots; /T already takes the descendants
 9  a single taskkill exit code is not a failure verdict
10  the deadline and the final tree state decide
11  any registered process still alive at the deadline is a Failure
12  only then wait for file handles to settle
```

Line 3 and 4: these are packaged Store apps, and processes with no top-level
window remain in the tree. `WM_CLOSE` has nothing to post to, so window
disappearance is not the success condition; an empty registered process tree is.

Line 9: `taskkill` reports `ERROR_NOT_SUPPORTED` while the app lifetime manager
holds a packaged process suspended, and it clears on its own moments later.
Treating that one exit code as fatal unwound the retry loop that exists to
absorb it and failed a Finish for a tree that did die.

Line 6 and 7: Windows reuses freed PIDs immediately and this step frees many at
once. A PID remembered across iterations can name an unrelated process seconds
later - terminating it, or making the final check report a still-running agent
and cancel a push that should have succeeded.

In-flight data lost to termination is accepted. Once Finish has been requested
there is no other way to reach a consistent snapshot.

### 2.10 Staging

**The root creates none.** Staging exists so that a step which changes local data
can put it back, and only the per-app scripts change local data. Each keeps
whatever temporary area and backups it needs, chooses its own paths, and cleans
up after itself on success, cancellation and failure alike.

```
root       sends Prepare / Cancel / Complete
           reads back Ready / Failure + reason / Complete
per-app    owns its temporary area, its backups and their layout
```

The root never learns those paths, so it can neither help nor interfere. What it
does require of every per-app script:

```
a change is completed or rolled back, never left half applied
the only copy of an original is never a temporary file
the only recovery copy is never a temporary file
a cleanup failure is reported, and counts toward the overall Failure
```

### 2.11 Baton

```
AgentSessionVault/ACTIVE_HOST.txt      value: NONE or <COMPUTERNAME>
```

A dirty Vault fails before Start runs. Start reads the baton before it joins with
the remote, updates it last, and only when every registered app succeeded. A run
that failed or applied only some apps leaves it untouched, so there is never a
claim to roll back.

```
Start   this PC     ask before discarding unpublished local work
        another PC  warn, do not wait, continue, take over on success
        NONE        continue

Finish  this PC     release to NONE, or keep it with KeepBaton
        another PC  warn, continue, leave the value alone
        NONE        nothing to release
```

**Finish never releases a baton it does not hold.** Setting `NONE` on another
PC's behalf would erase the one signal that makes that PC's next Start stop and
ask, and its unpublished work would then be replaced without a word.

A Finish that did not publish never releases the baton as if it had succeeded.
The baton is a record of which PC is in use, not a lock. Git conflict checking is
separate.

### 2.12 Git conflicts

`origin/main` is the source of truth (requirement 16). Start joins with the
remote before claiming. Nothing is cleaned up locally
before the final remote commit is verified.

**Not every push failure means the remote advanced.**

```
non-fast-forward rejection, or a remote ref mismatch
    -> the remote did advance
    -> fetch, merge, push again, up to three times
    -> merge commits keep both parents

authentication, permissions, network, a server hook, any other error
    -> an ordinary operational failure
    -> Failure with the reason
    -> not evidence about the remote state, and not retried as if it were
```

**A rejection is not resolved by merging file content.** Each app judges again
against the new remote and rebuilds its own contribution on that base.

```
the remote has not changed this session since this worktree's HEAD
    -> rebuild on the new base and publish

both sides changed the same vaultSessionId
    -> neither side is chosen
    -> the remote is not written over the local copy
    -> the local copy is not written over the remote
    -> both stay exactly as they are
    -> the whole joint Finish fails, nothing local is cleaned up
    -> report which session, and what differs
```

```
Session conflict: <vaultSessionId>

The remote session and this PC's local session were both changed.
Neither version was modified or published.

Resolve the conflict, then run Finish again.
```

Other sessions that were ready are not published either. A Finish that publishes
part of what it prepared is exactly what requirement 6 forbids.

How the user resolves it, and whether the tool ever helps with that, is not
decided here.

**Finish does not resolve the conflict, and no later step resolves it silently.**
Because the Finish did not publish, it does not release the baton, so the baton
still names this PC. The next Start reads that, sees the unpublished local work,
and asks before replacing anything.

```
Finish      conflict found, nothing changed on either side, Failure
            the baton is not released
the user    reads the report and decides
a later
Start       the baton names this PC, so it asks first
            only on an explicit yes is the remote state applied and the
            unpublished local work discarded
```

A later Start may discard the unpublished local state, but only after the user
explicitly confirms the destructive reset that the current-PC baton prompts.

**Why Git must not merge these files.** Measured on 2026-09-02 against this
Vault's own `.gitattributes`: merging two versions of one transcript produced a
file with a conflict marker inside the JSONL, and silently combined the regions
that did not collide - a conversation that never happened. `* -text` stops
newline conversion, not content merging. Requirement 3 rules both out.

A **non-fast-forward rejection** means the remote moved after this worktree's
`HEAD`, so the host being rejected is the stale one. Having worked more recently
confers no authority. Every other push error says nothing about the remote state
and is reported as an operational failure.

One conflicting session fails the entire joint Finish even when every other
session merged cleanly, because a Finish that publishes only part of the
registered apps must not be constructible (requirement 6).

Force push and rewriting remote history are forbidden.

**Semantic state conflicts are not resolved here at all.** Deleted and Active
existing together, a Deleted session that still exists locally, or the same
`vaultSessionId` in different survival states are detected before the merge and
are never auto-merged. They resolve the same way: Finish refuses to publish, and
the next Start applies the remote state.

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

`ActiveWindowDays = 30` is the value the user chose. There is no derived
rationale behind the number, and none is to be invented for it. What is
specified is how the age is measured: from the last valid conversation record,
never from mtime, a file name date or a Git timestamp.

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
  "lineageIds": ["..."],
  "deletedAt": "...",
  "source": "verified-app-delete"
}
```

`vaultSessionId` is the only key deletion is applied by. `lineageIds` comes from
the last published manifest for that session and is how a local record is
recognised as this session; it never deletes another session by itself.
`deletedAt` comes from the verified app deletion signal. There is no
`generation` field and no state fingerprint.

**There is no `lineageFingerprint`.** Once `origin/main` is the source of truth
(requirement 16), nothing compares a stored state signature: Start applies the
remote state once the session is identified, and Finish refuses to publish a
session the remote has already deleted. A signature that no branch reads would
be permanent storage for a value with no reader.

A Deleted record therefore requires an existing `vaultSessionId` and a published
manifest to take `lineageIds` from. A deletion of a session that was never
published creates no record: see section 2.16.

The record is kept for as long as the Vault exists: no expiry, no archival, no
compaction, no cleanup. It holds no conversation text, title, attachment or MCP
configuration. It never permanently blocks an app identifier.

The field list above is fixed. The agent is already distinguished by the
`Codex/Deleted/` and `Claude/Deleted/` paths and is not repeated as a field.

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

**A deletion that was never published creates no record.** When a verified
deletion signal exists but there is no app record, no trusted mapping to a
`vaultSessionId`, and no entry in any of the three states, nothing is written:

```
no Deleted file is created
no new vaultSessionId is issued
not a Failure
not SURVEY_REQUIRED
reported as a previously deleted session that was never published
```

Such a record could not serve any of the purposes above. The session was never
shared, so no machine can re-upload it, and there is no published state to
compare against. This is the normal state of a first run against an empty Vault
on a machine where conversations were deleted beforehand.

**Finish and Start resolve this differently, because one publishes and the other
receives.**

```
Finish      the session is Deleted on the remote and still present locally

    mapping proven
        -> Failure. publish nothing, change nothing locally
        -> the joint commit step cannot be entered
        -> report what differs

    mapping cannot be determined
        -> preserve, warn; that alone does not block the Finish
```

```
Start       the same session, now being received

    trusted mapping
        -> apply the remote deletion regardless of local content
        -> remove app records, lineage payloads, placement and linked data

    nothing left to remove
        -> Success, nothing to do

    mapping absent or contradictory
        -> remove nothing, Failure
```

**Finish never removes local data and never resolves this.** Finish publishes;
Start receives. Leaving the local payload in place is not a preservation
decision - the next Start discards it. A Finish branch that staged the local
removal would be doing Start's work from the publishing phase.

The remote saying Deleted while the session is still present locally means this
PC has not received that deletion yet. There is nothing here to publish for that
session and no state comparison that changes the answer.

**Report what differs, and do not name a cause that has not been shown.** New
activity, a partial change, a missing payload, corruption and a wrong mapping
all look alike from here.

```
RESULT: Failure
REASON: Session conflict
DETAIL: The remote session and this PC's local session were both changed.
        Neither version was modified or published.
        vaultSessionId, this worktree's HEAD, the current origin/main, the
        lineage ids that differ, and the payloads that are missing, added or
        changed.
        Resolve the conflict, then run Finish again.
PUBLISHED_COMMIT: NONE
```

Neither side is preferred. The remote is not written over the local copy and the
local copy is not written over the remote; both stay exactly as they are until
the user decides. How they decide, and whether the tool ever helps with it, is
not settled here.

**The tool has no automatic conflict resolution.** It stops and reports. The
resolution is the user choosing to run Start, which applies the remote state.
There is no branch where a stale local continuation is kept, published, or
carried over under a new `vaultSessionId`.

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
machine's app id mapping is resolved from the lineage identifiers, not stored.

See `CLAUDE_SESSION_STRUCTURE.md` for the measured structure.

### 2.18 Codex

Structures confirmed by survey: legacy and paginated forms, `history_base`,
predecessor ordinal and byte offset, canonical thread and physical page alias,
fork, guardian parent relationships, database projection, attachments, embedded
images and visualisations, and project, order and tab links.

**The measured Codex versions expose no durable deletion signal that Finish can
use.** This is now a surveyed result, not an open question.

```
deletion cannot be proven
    -> do not delete
    -> preserve the payload
    -> report the known limitation
    -> do not set SURVEY_REQUIRED on a normal run
```

The 2026-09-01 Codex survey observed two deletion paths, a user deletion from
the UI and the app-server `thread/delete` request. Both removed the rollout, the
canonical state row, the history projection and turns, and the session index
entry. Only global-state references remained, and those were present before the
deletion as well. No tombstone or other durable marker was created.

Because the survey is complete, a run that merely reports this limitation is a
normal run. Setting `SURVEY_REQUIRED` every time would mark every Finish as
needing a survey that has already been performed. `SURVEY_REQUIRED` stays for
structures this document does not describe.

Absence-based deletion is forbidden. A Deleted record that already exists in the
Vault is still honoured for the ordered lookup in section 2.16 and still blocks
re-upload; Codex Finish does not invent new Deleted records. New, updated and
archived sessions are handled normally.

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

**Per app, run directly by the user.** There is no root Reactivate: the user runs
`Codex/Reactivate.ps1` or `Claude/Reactivate.ps1`. It is not part of Start or
Finish, its result is not aggregated with the other app, and nothing recommends
or triggers it when a conflict is found elsewhere.

```
1  Search this app's Archived
2  Show id, title, project and last activity
3  The user selects
4  Verify the whole lineage and linked data
5  Archived -> Active
6  Commit, push, verify the remote
7  Request a graceful close if the app is running
8  Apply locally once closed
9  Relaunch the app
10 Report
```

If the app does not close: no force close, nothing written locally, the Vault
Active transition stands, the result is Failure, and the published commit and
the reason for non-application are reported. The next Start can apply it.

Reactivate does not alter activity timestamps and introduces no grace field. A
session with no new activity may be archived again by the next Finish.

### 2.21 Structural change and survey

**Checking and surveying are different things.**

```
checking    every run, by the per-app Start and Finish
            against rules this document already states
              required files present
              known record shapes and fields
              identifier and lineage links
              payload length and hash
              duplicate identifiers
              whether it can be placed into the app index safely
            stop writing on a mismatch, Failure, SURVEY_REQUIRED where the
            structure itself is unknown

survey      only when the user asks, after the app was run and something
            looked wrong
              a conversation missing from the list
              the wrong branch shown
              sessions linked to each other
              archived or deleted state behaving oddly
              the app rewriting data into a new shape
              an index or database relationship nobody has recorded
            a full sweep of the current version, with what the app did to the
            data, recorded in the Vault survey
```

Checking sees the bytes on disk. It cannot see what the app will make of them.

```
app is run
  -> something looks wrong
  -> close the app
  -> the user asks for a survey
  -> measure the state before and after, and what the app displayed
  -> record it in Surveys/<Agent>/<date>.md
  -> correct the public structure document
  -> correct the per-app scripts
```

**Running a full survey on every Start would not close this gap.** Until the app
runs, how it will read the data cannot be observed. The cost would rise and the
same blind spot would remain.

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
Failure   any other exit code
```

**`Skipped` and exit 200 belong to the workbench adapter, not to these scripts.**
The adapter answers "is this tool registered at all" before the tool is called.
Registration inside the tool is a filter in front of the loop: a disabled app
never enters the list, so no step ever has to decide that it is skipping one.

```
Packages/AgentSessionSync/Start.ps1
    no ToolRoot registered  ->  exit 200, the tool is not called
    ToolRoot registered     ->  run the tool
                                    |
                               Launchers/Start.ps1
                                    0, or a failure code. never 200
```

A registered app with nothing to do is `Success`. A registered app whose script
or required path is missing is `Failure`.

```
RESULT
AGENT
PHASE
REASON
DETAIL
PUBLISHED_COMMIT
SURVEY_REQUIRED
```

Aggregation, at both levels: any Failure makes the overall result Failure, and a
normal Skipped is not a failure. All Skipped makes the overall result Skipped -
which only ever arises in the workbench, since these scripts do not emit
Skipped. Partial application is a Failure
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
- Never clean up locally before publication is confirmed
- Never treat the only original or the only recovery copy as scratch
- Never resolve a delete-and-continuation state conflict automatically
- Never overwrite a remote path from a local state built on an older commit
- Never prefer the local copy on a same-path or same-session conflict
- Never force push or rewrite remote history
- Never remove local data on a mapping that has not been proven
- Never state a cause for a state difference that has not been shown
- Never persist per-app success across runs

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
        baton, cleanup, reporting

 4  Launchers/Codex/Start.ps1
 5  Launchers/Claude/Start.ps1
 6  Launchers/Start.ps1
 7  Launchers/Codex/Reactivate.ps1
 8  Launchers/Claude/Reactivate.ps1
 9  Launchers/Initialize-AgentSessionSync.ps1
```

Each step is checked for completeness inside its own script before the root
script integrates it. The first implementation target is Codex Finish.

### Verification

An author who writes both the code and its fixtures can pass every one of them
while misreading the contract, because the fixtures encode the same misreading.

```
a fixture pass rate is not evidence of contract compliance
the other agent verifies by reading the code against the clauses
both Windows PowerShell 5.1 and PowerShell 7 are exercised
fixtures live in a temporary directory; no test file is committed
```

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
