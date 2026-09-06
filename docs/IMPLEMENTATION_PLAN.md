# Implementation Plan

Effective requirements and implementation boundaries for the rewrite.
Updated 2026-09-06 for implementation closeout. See
IMPLEMENTATION_CLOSEOUT_2026-09-06.md for evidence and the open Reactivate mismatch.
The latest requirements below supersede earlier contradictory design text.
Implementation details are mechanisms for these requirements, not additional
user policies. Structure documents and private Surveys remain the evidence for
app-specific decisions; this plan does not replace that evidence.

Do not add a policy that is not in this document. If a new decision is
genuinely needed, report only the point that conflicts with an existing
decision, with evidence, and do not reopen a settled item.

## Part 1. Fixed requirements

These describe the current requirements. Superseded mechanisms must not be
reintroduced merely because they appeared in an earlier revision.

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
   newline changes. gzip transport only when a payload exceeds the 95 MiB
   destination threshold, and the restored payload is verified too.
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
8. **The baton records use and gates Finish when another PC owns it.** `ACTIVE_HOST.txt` is not
   a lock, a local comparison basis, or proof that work finished.
   - a dirty Vault fails before Start changes anything
   - Start fetches before reading the remote baton, without moving HEAD
   - this PC's baton is reason to ask before discarding unpublished work;
     it is not proof that such work exists (KeepBaton can also leave it set)
   - Start warns about another PC's baton, then takes over only on full success
   - losing the baton does not complete or invalidate this PC's work
   - actual unpublished local work still needs reset confirmation even when
     another PC owns the remote baton, or that baton is NONE
   - Start claims only after all registered apps have applied successfully
   - a successful baton push response completes that notification; no mandatory
     post-push remote query is added
   - partial Start is overall Failure: no claim and no normal basis advance;
     the next Start reprocesses every registered app
   - Finish proceeds only when the fetched baton is this PC or NONE; another
     PC's baton means Failure with a request to run Start first
   - Finish never invokes Start automatically or discards unpublished work;
     preservation or reconciliation requires subsequent user instructions
   - successful Finish releases this PC's baton unless KeepBaton is set
9. **Remember the actual local comparison basis.** HEAD and the final published
   remote tree are not substitutes for the state this PC's apps actually used.
   The app compares its accepted local basis, current local data, and the
   fetched remote session data. The root cannot make this decision from commit
   age, baton ownership, or whether Start was called recently.
   - a normal first Finish is not an exception and does not need a fake basis
   - missing basis does not make a complete new conversation an orphan
   - an existing session with an unprovable relationship is reported, not guessed
   - successful Finish accepts the app's actual local state returned after Prepare completed its work;
     it does not pretend that unrelated remote sessions were applied locally
   - no persisted app-success flags are used to skip later runs
   - partial Start is overall Failure; run Start again for every app
10. **Preserve already published work; report actual conflicts.** Fetch obtains
    remote objects without replacing local files. Each app decides which
    sessions changed from its local basis. Remote-only changes stay remote;
    local-only changes may be published; incompatible changes to the same
    session fail the joint Finish and are reported for the user to resolve.
    Neither version is silently chosen or rewritten. Git never text-merges
    payloads. A non-fast-forward rejection causes fetch, app re-evaluation,
    and reconstruction, at most three publication attempts. Authentication,
    permissions, network and hook failures do not prove a session conflict.
    Force push and rewriting remote history are forbidden. Existing local-only
    commits, including Surveys, must not be silently dropped.
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
15. **Report actual results with reasons.** Root and app scripts emit Success
    (exit 0) or Failure (nonzero). Skipped/exit 200 belongs only to the workbench
    adapter before this tool is called. Partial application is overall Failure;
    a normal adapter Skipped is not a failure.
16. **Start receives; Finish publishes.** The remote is the accepted shared
    state. Start applies it to the local apps, with confirmation before
    discarding unpublished work. Finish expects local changes and prepares
    them for publication. It does not reset local work to the remote first.
    - Start -> work -> Finish is normal usage
    - Finish -> more work -> Finish is also valid
    - Start omitted or baton NONE does not itself forbid Finish; another host
      holding the fetched baton blocks Finish and requires Start first
    - a first Finish into an empty session Vault is normal new publication
    - remote priority means not undoing already published work with an unchanged
      stale local copy; it does not mean discarding every later publisher's work
    - a conflict is reported; the user decides how to resolve it
    - Finish checks surveyed structure and performs only app-local changes that
      the measured app contract requires before constructing and publishing the
      result; Claude Vault Archive performs no Claude app-local write

## Part 2. Composition

### 2.1 Scope

The public `AgentSessionSync` repository is the distribution original. A user
copies it, and **that copy is both the tool and the private Vault**: the
launchers, the session states and the survey records live in one repository.
There is no second checkout at runtime.

```
public AgentSessionSync     distribution original, holds no session
the user's copy             the installation, and the private Vault
```

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

Root Start/Finish own settings, the Enabled filter, execution order, app
processes, network Git operations, publication, the baton, and result reporting.
They fetch and pass immutable object references. They do not inspect session
payloads or make session decisions from Git ancestry.

Per-app Start/Finish own identity, lineage, structure validation, raw integrity,
three-way session comparison, Active/Archived/Deleted decisions, app indexes and
records, any measured app-local change, private scratch, backups and recovery of
their own changes. Git object reads and creation of their own prepared trees are allowed;
network fetch/push, shared refs, and process control belong to root Start/Finish.
Standalone per-app Reactivate owns its separate user-invoked workflow.

The root creates no payload staging directory and knows no app backup paths.
An opaque Git tree is the app's prepared output, not a root-defined session
format. The root checks that it is a tree, not that its session contents are valid.

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
prepares the empty layout. Runtime output can create its required descendants.

The same session cannot be in Active and Archived at once. Deleted holds no
payload, only the minimal deletion record. Surveys are dated Markdown. Every
registered app's Finish data is published in one joint commit.

### 2.7 Local comparison basis

Three inputs have different meanings:

```
local comparison basis   what this PC last successfully handled in its apps
current app data          what is actually on this PC now
fetched remote commit     what is already published, pinned for this attempt
```

HEAD can move because of Survey commits or publication. It is not the first
input. Commit ordering cannot tell whether a conversation changed.

The implementation stores the comparison snapshot in the local-only Git ref
`refs/agent-session-sync/local-base`. Its commit has app-named tree entries whose
contents are produced and interpreted by the apps. This ref is never pushed by
the tool. There is no checkpoint JSON, generation field, or app-success flag.
Start accepts the returned trees only after all registered apps succeed. Finish
accepts them after all Prepare calls succeed and publication is verified, before
Complete discards backups. An absent ref is passed as an absent basis, never
fabricated from HEAD.
Old comparison commits remain reachable through the local ref's history.

Start partial application is overall Failure. Successful app changes may remain,
but the normal basis is not advanced. The next Start applies every registered
app again. A successful Start returns snapshots of what it actually applied.

Finish Prepare returns snapshots of the actual local state after any measured
app-local work required by that app is complete. The root composes the next comparison
snapshot before pushing, but advances the accepted ref only after verified
publication. It records that ref before Complete cleanup and Vault checkout
advancement. Do not use the final remote tree as the local snapshot.

For Codex Start's unpublished-local-change check, compare the archived flag in
the saved projection.state with the current app projection, alongside the
content/metadata comparison. Do not compare the Vault Active/Archived tier to
the native app archive flag: a recently active conversation may already be
archived in the app while its Vault policy tier remains Active. A real change
to that app flag or to the recorded content/metadata still requires confirmation.

Example (PC-A and PC-B are computers; Travel and Code are conversations):

```
PC-A basis                  Travel v0 / Code v0
PC-A actual apps            Travel v0 / Code v1
remote after PC-B Finish    Travel v1 / Code v0
app-approved publication    Travel v1 / Code v1
PC-A apps after Finish      Travel v0 / Code v1
PC-A new comparison basis   Travel v0 / Code v1
```

PC-A never received Travel v1. Recording that as its basis would make its next
Finish mistake unchanged Travel v0 for an intentional reversal. On the next
Finish, Code v2 can be published while the remote Travel v1 remains intact.
This mixed local basis can be represented by one local Git snapshot; it need
not be a commit that ever existed on origin/main.

Identity must be proved by the app using the surveyed mapping and full context.
A lineage intersection is candidate evidence, not authority to join two branches
or delete another session. Ambiguity is reported without guessing.

### 2.8 Start

```
1  Read settings and select registered apps
2  Require a clean Vault worktree; retain its current HEAD
3  Fetch origin/main without checkout; pin the remote commit
4  Read local/remote baton. Warn for another host. Ask before destructive reset
5  For each registered app, request graceful close and wait for handle release
6  Call its Start with the pinned remote and local comparison-basis references
7  Collect all results; partial application is overall Failure, no whole rollback
8  Only after all apps apply, receive the pinned tree into the Vault worktree
9  Push this PC's baton; on a successful response finish local baton/basis storage
10 Launch successful apps and report actual application/launch/publication results
```

The root checks Git results only. Each app checks structure, identity, lineage,
payload integrity, and safe app placement before changing its own data.
The app reads the pinned remote directly from fetched Git objects, so HEAD need
not move before its checks and any local discard question.

Current-host local OR remote baton is reason to ask. Local-only Vault commits
also require explicit confirmation before removal from the checked-out branch.
If neither identifies the risk, app Start must detect unpublished local changes
using its basis and ask before replacing them. A root confirmation is forwarded
as `-DiscardLocalChanges`; without it the app has no blanket discard permission.
Unattended execution with no affirmative answer must not imply consent.

Another host's baton alone is warning-only. It does not prove this PC has no
unpublished data. Baton NONE is not such proof either.

Start only force-resets the Vault branch when local-only commits exist and the
user explicitly approved their discard. Otherwise the pinned tree is installed
by fast-forward. The app store is always handled by its app script, not by Git.

Start never force-closes. A close failure leaves that app's data unchanged.
An app failing during application restores its own change scope, retaining
recovery material if restoration fails. Other successful applications remain.
The result reports what remains and requires another full Start, not a persisted
success flag or a cross-app rollback. Failed/partial application does not claim
the baton or advance the normal comparison basis.

Active is applied; Archived is absent from the active app store; Deleted removes
only a proved matching local target. Already-absent targets are successful no-ops.
Unknown/contradictory mapping is not permission to delete. All removal, including
indexes and shared lineage dependencies, is the app's responsibility.

Start success means known-rule application completed and app launch was requested
successfully, not that the UI, DB interpretation or every session was observed.
The initial fetch supplies the remote snapshot the apps apply. After all apps
apply, the baton push notifies the remote that this PC has started use. A
successful push response completes that notification; Start does not fetch again
to recheck an acknowledged push. The baton is a record, not a lock or a promise
that the remote cannot change later.

If push does not report success, report overall Failure, the Git error, the
candidate commit, and that app data was already applied. Do not claim publication
was confirmed, advance the normal basis, retry the push automatically, or undo
the applied apps. If push reports success but a local finalisation or app launch
fails, report overall Failure with that acknowledged published commit and the
specific unfinished work. No partial-success result is introduced.

### 2.9 Finish

```
1  Read settings and select registered apps; retain original HEAD
2  Read the local comparison basis; fetch and pin remote objects, no checkout
   Require the baton to be this PC or NONE before closing apps; otherwise report
   Failure and request Start, warning about possible loss of unpublished work
   Record the current working tree and staging for change detection; do not
   create a preliminary commit or alter the real index, HEAD or working files
3  Verify this process is outside every app process tree
4  Request normal close; terminate remaining registered app trees; verify release
5  Call each app Prepare: check structure, perform only measured app-local work,
   and return both trees
6  Require every app Ready. Otherwise Cancel all attempted apps and report Failure
7  Only after all apps are Ready, compose one joint commit from the remote, app
   trees, pending Vault changes, existing local history and baton
8  Push candidate; read back the remote to verify publication
9  On non-fast-forward rejection, Cancel; check the refreshed baton before
   asking all apps to prepare again. Another PC's baton stops the retry
10 After verified publication accept the actual local comparison trees from Prepare
11 Call every app Complete: discard backups/scratch only; after all succeed,
   install the verified candidate and advance HEAD, preserving existing ancestry
12 Report app and overall results
```

At most three publication attempts. Apps run sequentially. All registered apps
must prepare successfully, even when only one is enabled. A no-change Prepare
still returns the app's complete intended tree and is Success.

No Finish reset to origin/main. No pre-publication checkout replacement. A local
Survey commit is real work, not an obstacle to discard. Non-session Git changes
are combined without text conflict resolution (section 2.12). Uncommitted Vault
work is normal Finish input. Record it without a commit using a private Git
index; the real index and worktree remain untouched. This temporary Git index is
not an app staging area. Include tracked/non-ignored additions, edits and removals
in the joint candidate only after every app prepares successfully. No preliminary
collection commit is created. Do not force-add ignored configuration or scratch.
An unresolved Git merge is reported, not automatically resolved. Existing staged
work is collected with the current worktree state, as normal Git add would do.

Prepare failure creates no publication commit and preserves pre-run HEAD,
working files and staged entries. A failed push leaves the candidate object and
app recovery report, but does not advance HEAD or reset pending local work.
Existing local-only commits remain parents of the joint publication candidate.
Check both working files and staged entries for concurrent changes; report later
edits rather than silently including or replacing them. After verified publication
and app Complete, align the index to the captured worktree, install the candidate
with Git restore, then advance HEAD with an expected-old-value update. No app
script is replaced before its Complete call. No Git content merge is performed.
Start's clean-worktree requirement is unchanged by this Finish correction.
App-local work lives outside that Git worktree and is expected to have changed.

Process rules retained from the measured previous implementation:

- Enumerate real app process trees, protecting this process and its ancestors
- Request WM_CLOSE on all discovered top-level windows
- Allow GracefulCloseTimeoutSeconds (8 by default) when normal close is possible
- Zero windows is not successful closure; proceed to remaining-tree termination
- Do not retain PID decisions between termination iterations; re-enumerate
- Target tree roots with taskkill /T /F, not every child independently
- One taskkill exit code is not the result; check actual remaining trees
- Allow the existing 10-second termination deadline and verify every app is gone
- Revalidate registered process names and WindowsApps paths each iteration
- Allow handles to settle before invoking app Prepare
- Force closure belongs to Finish only; Start/Reactivate never force-close

The accepted Finish force-close policy can lose in-flight app work. A window
closing is not evidence that its app process tree stopped.

An app preparation failure is about its input/operation, not proof of a Git
failure. A Git error is not proof of a session conflict. Report them separately.
If preparation failed, Cancel all attempted apps, including the failed one.
Apps run sequentially: an earlier app may already have performed measured local
changes when a later app fails. Restoring the earlier app is required, not partial success.
This rollback cost is accepted. Cancel restores the state immediately before this
Finish, not the last Start or the remote state. Rollback failure retains recovery
material and is reported; never report success merely because Cancel was called.

Prepare first checks the measured structure without modifying app data. A
structural mismatch stops that app with Failure and SURVEY_REQUIRED. Only after
that check may it secure backups, perform app-local changes supported by measured
evidence, and build PREPARED_TREE and LOCAL_BASE_TREE. Claude Finish currently
performs no app-local change: its Archive is a Vault transport tier and its Delete
was already performed by the user in Claude. The Vault
worktree, shared index and branch refs remain unchanged during preparation.
A definitely unpublished failed attempt is cancelled before retry or return.

After publication, the root saves the Prepare comparison snapshots before
calling Complete. If saving the basis fails, Complete is not called and the
backups remain. Cleanup failure does not undo the published work or saved basis.

Complete only verifies the run/publication linkage and
discards backups and private temporary material that are no longer needed.
Any permitted app-local work was already handled by Prepare. Complete runs before receiving repository code updates, so it uses the
same app script version that prepared this attempt. Moving checkout advancement
ahead of Complete could replace that script with a different remote version.
The final checkout installs the exact verified publication in the Vault; it does
not apply remote sessions to app storage or perform a payload content merge.
Failure here is overall
Failure with the published commit and remaining cleanup details. Do not undo
the remote publication, repeat app-local work, or erase a needed recovery copy.

If push outcome cannot be verified, report unknown plus the candidate commit,
retain recovery material, and do not run destructive Complete or blind Cancel.

### 2.10 App-owned preparation and recovery

The root owns no payload staging directory. Each app may use private scratch
and backups as needed; the root neither creates them nor interprets their paths.

Prepare checks structure and, only when the measured app contract requires a
local write, secures backups and finishes that work before creating the complete
intended app tree in the local Git object store,
using byte-preserving Git plumbing or app-owned scratch/index. It does not
write the Vault worktree, the shared index, or branch refs.
Because plumbing bypasses .gitignore, the root first checks that the installation
allows the registered app directories. Each app must also honour allowed payload
paths, excluded machine settings and effective attributes when producing its tree.
It returns PREPARED_TREE and LOCAL_BASE_TREE and retains its own run-bound
backups and recovery data through publication verification.
This is actual prepared data, not a new abstract planning-object layer.

Cancel restores all this attempt's app writes from backup, including partial
writes from a failed Prepare. It is cancellation with rollback, not Skip. It
never resets pre-existing local work. No-op Cancel success requires evidence
that this RunId made no changes, not a stub's assumption. Retain needed backups
until restoration succeeds. Complete is bound to the same RunId and preparation;
a supplied hash alone is not evidence that the corresponding app tree was
published. The app verifies that linkage before discarding backups/scratch.
Complete does not apply app changes or construct a new local comparison basis.

The root composes tree object references and creates a candidate commit. It does
not read raw session content, manage app temporary files, or text-merge payloads.
No branch/worktree update precedes publication in Finish.

Automatic recovery covers this invocation's own writes, not damage/conflicts
that existed before it. The only original or recovery copy is never disposable
scratch. Report cleanup/recovery failure and retain the data needed to recover.

### 2.11 Baton

ACTIVE_HOST.txt records use; it does not serialize PCs or determine conflicts.

```
successful Start       set this PC after all apps applied; require push success
partial/failed apply   do not claim
Finish, own baton     release to NONE with joint publication, or KeepBaton
Finish, another PC    Failure; report owner and require Start, do not take over
Finish, NONE          publish if apps permit; there is no baton to release
```

A different PC taking the baton does not complete or invalidate this PC's work
or replace its local basis. It does block Finish while that PC owns the fetched
baton. Finish reports the owner and requires Start first, but never runs Start
automatically. The report warns that Start may discard unpublished local work.
Preserving or reconciling that work is handed to the user for subsequent
instructions; it is not an automatic recovery branch inside Finish.
NONE permits app-level judgement, but does not prove no other PC worked since
the local basis. Session conflicts and Deleted/local discrepancies still require
app-level checking and reporting.
Read both the local and fetched baton for Start's conservative reset warning.
Actual local change detection remains with the app; baton alone is insufficient.

Finish builds the next baton value in the candidate Git tree. It does not write
the worktree file and later reset it on failure. The value arrives in the local
worktree when the verified publication is installed. There is no separate
preparation directory or early claim to roll back.

### 2.12 Comparison and publication

The root fetches once per attempt and passes immutable RemoteCommit and
BaselineCommit references. Apps can read Git objects locally; they need no
network access. A newer remote commit is not itself a session conflict.

The app compares actual semantic session states and byte-preserved payloads:

| Local vs accepted local basis | Remote vs that basis | App decision |
| --- | --- | --- |
| unchanged | unchanged | no-op |
| changed | unchanged | contribute the local change |
| unchanged | changed | keep remote, do not upload the stale local version |
| changed | changed to the same result | no conflict |
| changed | incompatibly changed | report conflict, no joint publication |
| basis absent | session absent from all remote states | validate normal new session |
| relationship unknown | existing session | report uncertainty, do not guess |

These rows do not turn missing files into deletion proof, a shared ancestor into
session identity, or an archive into an implicit reactivation. App-specific
structure and state rules still apply. Missing evidence is not a diagnosed
two-sided conflict; the report must say which it is.

Example: PC-B already published a change to conversation Travel. PC-A changed
only Code. Its app preparation retains remote Travel and contributes local Code.
If both PCs changed Travel incompatibly, the app reports the actual differences.
Neither conversation version is overwritten and no other app is partially
published. The user chooses how to resolve it; no duplicate vaultSessionId,
automatic Reactivate, or automatic reset is created as a solution.

Finish failure does not discard PC-A's app data or its pre-run Vault commits.
A later user-invoked Start can replace the local state after required discard
confirmation. This is not automatic conflict resolution by Finish.

Git composition is separate from this decision. Each app returns its complete
prepared subtree. The root inserts these opaque subtrees into a candidate.
For non-app files such as Surveys, exact Git entries are compared to the common
Git ancestor: one-side-only changes combine, identical results combine, and
incompatible same-file changes are reported. No text is merged. Git ancestry
here describes repository file history, not session activity or identity.

The candidate's first parent is the fetched remote. If pre-existing local commits
are not ancestors of it, they are also retained as a parent so local Survey/code
history is not silently dropped. This constructs an explicitly approved tree;
it does not ask Git merge to produce session content. After verified publication,
Finish installs the verified candidate tree and advances HEAD only after app
Complete, checking that the captured worktree and real index have not changed.
Start and standalone Reactivate have their own checkout paths; this is not
Git text merging and does not create a preliminary collection commit.

Finish sends the candidate to refs/heads/main without force. Verify the fetched
remote contains the exact candidate; a lost push response may still have
published. Only a confirmed unpublished non-fast-forward rejection retries.
Ordinary operational errors are reported without inferred session conclusions.
Unknown publication retains app preparation for review. No remote rollback.

Git text merging remains forbidden: the previous experiment produced JSONL
conflict markers and mixed non-overlapping turns into a conversation that never
happened. App preparation must preserve complete records and original bytes.

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
  -> performs only remaining app-local work proven necessary by that app survey
  -> builds the result with removal of the Active/Archived payloads
  -> joint Finish publication and verification
  -> app Complete discards no-longer-needed backups and temporary material
  -> next Start applies the state on other PCs
```

Never delete on file absence alone, sidebar absence alone, or a missing
database row alone. If the deletion relationship cannot be proven, preserve the
payload. Recovery backups and pending publication material are not discarded
before publication is confirmed; this does not prohibit backed-up app changes.

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
`deletedAt` comes from the verified app deletion signal (for Codex, the native
archive deletion-transit request timestamp, after Finish verifies removal). There is no
`generation` field and no state fingerprint.

There is no persisted lineageFingerprint in this minimal record. Comparison
uses the separately retained actual local basis and the app's surveyed rules;
absence of a fingerprint here does not mean comparison is unnecessary.

A Deleted record therefore requires an existing `vaultSessionId` and a published
manifest to take `lineageIds` from. A deletion of a session that was never
published creates no record: see section 2.16.

The record is kept for as long as the Vault exists: no expiry, no archival, no
compaction, no cleanup. It holds no conversation text, title, attachment or MCP
configuration. It never permanently blocks an app identifier.

The field list above is fixed. The agent is already distinguished by the
`Codex/Deleted/` and `Claude/Deleted/` paths and is not repeated as a field.

### 2.16 State lookup, deletion and conflict

Always establish identity and look in Active, Archived, and Deleted before
classifying an absent remote Active entry as a new session. A complete genuinely
new conversation is normal, not an orphan. A referenced but missing required
part is a different condition and is reported without guessing.

Archived is retained. A normal Finish may transition Active to Archived using
the 30-day rule. Only explicit per-app Reactivate changes Archived to Active.
Do not upload a stale local Active copy as a new conversation because the
remote has moved it to Archived or Deleted.

Use section 2.12's three inputs for active work and relevant state transitions.
Remote Archived plus unchanged stale local data is not automatically a conflict:
retain the remote state. Remote Deleted plus a locally present conversation must
be reported and stops joint Finish, even if that conversation was not edited.
Do not silently skip it, republish it or delete it automatically. The user decides
the next action. This is a state disagreement, not by itself SURVEY_REQUIRED.
A changed local continuation incompatible with the remote state is a conflict. A verified local deletion incompatible with a remote
continuation also requires user review. App metadata added by deletion is not
automatically a new conversation turn; interpretation needs surveyed evidence.

If deletion/mapping cannot be proved, do not delete or invent a record. Preserve
and report the unresolved relationship. This is not a blanket exception allowing
an incomplete active payload to be published or a conflict to be ignored.

A verified historical deletion with no published session identity produces a
report only: no new vaultSessionId, no Deleted file, no Failure or SURVEY_REQUIRED
solely for this normal condition. Old unrelated tombstones are not a global gate.

```
RESULT: Failure
REASON: Session conflict
DETAIL: app, vaultSessionId, comparison basis, pinned remote commit,
        actual local/remote state changes and affected payloads.
        Neither version was overwritten or published. User resolution required.
PUBLISHED_COMMIT: NONE
```

Finish does not solve that conflict. Prepare performs only app-local work that
the measured app contract proves necessary, after checking structure and securing
any required backups, before constructing the result for publication. It preserves
shared lineage needed by surviving sessions. No speculative record, index or DB
edits are allowed. A permitted app-local operation failure prevents joint
publication and cancels this attempt's writes for all attempted apps. Complete
only discards no-longer-needed recovery
and temporary material after publication is verified.

### 2.17 Claude

Owns `cliSessionId`, `priorCliSessionIds`, `local_*.json`, the
measured app-id and CLI-id tombstones, `.desktop-released.json`, groups,
assignments and order, and the target machine's app id, path and MCP mapping.

The tombstone is the deletion signal. Payload absence is not deletion. The
tombstones of the whole lineage are checked. A tombstone that cannot be
interpreted fails the Finish. `isArchived` is read only; Vault Archived is the
tool's transport state.

Claude Finish does not implement Claude's native Archive operation. The 30-day
transition moves the portable payload between `Claude/Active` and
`Claude/Archived` in the prepared Vault tree only. It does not write
`isArchived`, remove `local_*.json`, change groups or order, edit LevelDB, or
modify transcripts. A measured user deletion has already removed the app record;
Finish records that verified result in the Vault and performs no additional
Claude app-local deletion.

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

One optional field, `unavailablePriorCliSessionIds`, is added only for a
confirmed historical loss. It is a non-empty array of earlier lineage
identifiers; a session with nothing lost omits the field rather than carrying
an empty one.

### Confirmed lineage loss

A session whose lineage names a transcript that no longer exists is incomplete
and is not published. That stays the default. The one exception is a loss the
user has confirmed: it is recorded rather than hidden, and the rest of the
session is published as it actually is.

The approval is written by the user, in the private configuration only:

```
Claude = @{
    AcknowledgedMissingLineage = @{
        '<appSessionId>' = @( '<cliSessionId>', ... )
    }
}
```

Keyed by `appSessionId` because `cliSessionId` rotates on every rewind and
would stop naming the conversation the user approved. Nothing is added
automatically; a later loss needs a new explicit entry.

```
first publication   the private configuration supplies the approval
after publication   the manifest's unavailablePriorCliSessionIds supplies it
```

The published record travels with the session, so a second machine, whose
`appSessionId` for the same conversation may differ, is never asked to approve
the same loss again.

The rules are:

```
approved ids must be earlier lineage entries; never the current transcript
approved set and actually absent set must be exactly equal
a recorded loss whose transcript is present again is a Failure, not a survey
an unapproved absence stays a Failure
the app record and every surviving transcript move byte for byte
Start creates nothing for a recorded loss and issues no new approval
```

The equality is checked even when nothing is absent, because that is the only
way a reappeared transcript is noticed. Neither disagreement sets
`SURVEY_REQUIRED`: the structure is known, and what differs is state.

The version 2 manifest excludes the source machine's `accountId/deviceId`
path, `appSessionId`, MCP definitions and machine runtime settings. It is the
portable comparison and display metadata, not a replacement for the app's own
record.

The private Vault also carries the measured `local_<appSessionId>.json` app
record as an opaque byte payload under
`Claude/<state>/<vaultSessionId>/record/`. Start places that same app-issued
record under the target machine's configured account/device directory; the
source account/device directory names themselves are not transported. The tool
does not mint or rewrite an `appSessionId`, and does not reinterpret or
selectively reconstruct fields inside the app record. This preserves the app's
issued identity and the original record rather than inventing values the
storage survey did not establish.

The `vaultSessionId` is resolved from lineage identity. For a new Claude
conversation it is the oldest app-issued `cliSessionId`; an existing Vault
mapping wins when a later lineage member overlaps it. If a target machine ever
presents the same lineage under a different app-issued `appSessionId`, Start
reports the observed mismatch with `SURVEY_REQUIRED` and changes nothing. The
current surveys do not establish a safe remapping operation.

See `CLAUDE_SESSION_STRUCTURE.md` for the measured structure.

### 2.18 Codex

Structures confirmed by survey: legacy and paginated forms, `history_base`,
predecessor ordinal and byte offset, canonical thread and physical page alias,
fork, guardian parent relationships, database projection, attachments, embedded
images and visualisations, and project, order and tab links.

The app has no durable final-deletion tombstone after a complete thread/delete.
That measured limitation does not remove the user's deletion workflow:
native Codex Archived is reserved as the user's deletion transit. The tool's
30-day Vault Archived tier is a separate preservation policy.

For a native deletion transit, Finish validates archived=1, an integer positive
archived_at (epoch seconds), the canonical rollout in archived_sessions, and the
existing original/lineage/database structure. After three-way conflict checks it
secures rollback material, removes the app originals and measured projection,
and returns Ready with only the minimal Deleted record for a published session.
The record uses the last published vaultSessionId and lineageIds. deletedAt is
the app's deletion-transit request time. Publication still requires every app
Ready; failure before confirmed publication invokes Cancel to restore this
Finish's exact pre-run session state. Complete only disposes recovery material.
A never-published conversation is removed with the same backup protection but
creates no Vault Deleted record.

A remote change since the accepted basis blocks local deletion and reports the
conflict before app writes. Without an accepted basis, an existing remote session
must match the local content/metadata before this tool completes deletion.
Remote Deleted plus a locally present session continues to report and block;
it is never silently republished or automatically removed.

If an accepted Active session is wholly absent without a verifiable transit,
Finish stops and reports the unresolved state. It neither guesses a deletion
nor silently republishes a stale Active copy. This state discrepancy alone is
not SURVEY_REQUIRED; unknown structure still is. Remote-only sessions on a PC
that never accepted them are retained, with a report, without absence inference.
Already-Deleted and deliberately removed Vault-Archived sessions remain normal.

The earlier controlled thread/delete observations removed rollouts, the canonical
state row, history, session index and catalog, while old global references remained.
Those leftover references and absence alone are not a deletion signal.

See `CODEX_SESSION_STRUCTURE.md` for the measured structure.

Codex Vault Archive is not the app's native archive operation. Once the
complete publication payload and rollback material are secured, Codex Finish
removes the selected session's rollouts, state row, measured dependent rows,
history projection, catalog and session-index entries from app storage. It does
not set `threads.archived=1` or move files into `archived_sessions`. Native-archived data is handled by the validated user deletion-transit path
above, not reclassified as Vault Archived from its app flag.
The prepared tree retains the full Archived session; the local comparison tree
omits the removed app session. Cancel restores the immediate before-images with
byte/row checks. Backups remain until successful publication and Complete.

The 2026-09-06 read-only schema check also found the exact
`thread_realtime_items_projection_cleanup` trigger: deleting a row from
`thread_history_projection_state` deletes `thread_realtime_items` with the same
thread_id. Finish records and removes realtime rows first, then the projection;
Cancel restores them in reverse order. Changed trigger bodies remain a
SURVEY_REQUIRED failure before any app writes.

### 2.19 Payload transport

Read and write JSONL and attachments as bytes only. Never re-serialise.
Preserve encoding, BOM, newlines and the final newline. Verify raw length and
SHA-256. Check the effective Git text, EOL and content filters.

A payload above `99614720` bytes (95 MiB) is transported as:

```
.jsonl.gz
.jsonl.gz.integrity.json    raw length, raw SHA-256, gzip length, gzip SHA-256
```

Start and Reactivate verify both the compressed file and the restored payload;
a matching local verified marker avoids repeating that decompression.

Codex transport also handles gzip streams that still exceed the ceiling. Split
the single gzip byte stream into ordered parts of at most 99614720 bytes (or the
smaller configured transport limit); do not recompress the parts. The logical
payload and original app file remain unchanged. The transportPath then names
<path>.gz.parts.json instead of <path>.gz. The descriptor has schemaVersion 1,
encoding "gzip", partSize, rawLength/rawSha256, gzipLength/gzipSha256 and a
non-empty ordered parts array (at least two). Each part has path, length, sha256;
names are <path>.gz.part000001, .part000002, and so on. The oversized .gz blob
is NOT included in the publication tree. Existing raw/single-gzip transport stays
readable. All Codex payload kinds use this size ceiling, including attachments.

Finish checks both its new output and stored remote/basis split transports.
Start and Reactivate verify every part, count and order, reassemble into app-owned
scratch, verify the whole gzip, then decompress and verify the original length
and SHA-256. Missing, reordered or damaged parts stop before app application.
This changes byte transport only, not session identity, Archive or Delete policy.

Gzip is marker-first: local refs under refs/agent-session-sync/codex-gzip-v1/
point to verified transport trees with marker.json (schemaVersion 1, codec
gzip-split-v1, and the logical payload path/raw length/raw SHA-256/transportPath).
Each tree also retains every compressed blob and its integrity/parts descriptor.
These refs are local cache markers, never a session identity or publication gate,
and are not pushed. Keeping the tree reachable prevents Git GC from dropping a
transport that a failed publication may reuse. Cancel does not erase these
verified transports; it still restores only this run's app-local changes.

Compare the raw identity and all transport Git object IDs first. A matching
verified marker skips recompression and verification decompression. An absent or
changed marker requires full byte verification before recording a new marker.
No timestamp or app version is a substitute for the raw hash. Finish's second
Archive scan and later retries reuse unchanged compressed output. Start reuses
an already verified raw file within the run, or an identical local original;
only data actually missing/different on that PC needs decompression for placement.
Markers can be discarded without data loss; their absence causes revalidation.



Compression output must also be deterministic across Windows PowerShell 5.1 and
PowerShell 7. The implementation uses Git for Windows `gzip.exe` with source
name and timestamp suppressed; identical raw bytes must produce the same blob
and tree object in both hosts.

The limit belongs to the destination repository, not to either app: it sits
under GitHub's per-file ceiling so that a large payload is carried compressed
instead of through Git LFS. Both apps therefore use the same value. Only Codex
has been observed to exceed it; the largest measured Claude transcript is far
below it. That is an observation about sizes, not a different threshold.

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
7  Report the Vault transition; a separate Start applies it to the app
```

The user's later clarification limits Reactivate to the Vault transition.
It must not call app Start, control app processes, or advance the local app
comparison basis. Implementation mismatch at closeout: both current scripts
still contain those post-publication calls. Do not use Reactivate until that
bounded correction is implemented and verified. This document records the
requirement; the closeout did not silently change runtime behaviour.

Reactivate does not alter activity timestamps and introduces no grace field. A
session with no new activity may be archived again by the next Finish.

### 2.21 Structural change and survey

App/backend version identifiers are supplementary observations, not permission
lists. A version change suggests that storage may have changed; it alone must
not cause Failure. Check the actual structure and required operations. Report
unfamiliar versions without weakening identifier, lineage, deletion, integrity
or database checks. A new survey runs only on the user's instruction.


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
            before Finish app changes, compare with the surveyed structure
            any structural mismatch: stop, Failure, SURVEY_REQUIRED, ask for survey
            new conversations and normal content growth are not structural mismatch
            SURVEY_REQUIRED means structural investigation is needed, not every
            ordinary I/O failure or a missing file in an otherwise known format

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

#### Root-to-app calls (implementation mechanism)

```
App Start
    -RunId <guid> -RemoteCommit <oid> [-BaselineCommit <oid>]
    [-DiscardLocalChanges]
    Success: LOCAL_BASE_TREE: <tree-oid>

App Finish
    -Operation Prepare|Cancel|Complete -RunId <guid>
    -RemoteCommit <oid> [-BaselineCommit <oid>] [-PublishedCommit <oid>]
    Prepare Success: PREPARED_TREE: <tree-oid>
                     LOCAL_BASE_TREE: <tree-oid>
    Cancel Success: this run's app changes restored; no tree required
    Complete Success: publication checked, backup/scratch cleanup done; no tree
```

Each call runs in a child PowerShell process. It prints the normal RESULT fields
once; exit 0 and RESULT Success are both required. The root prefixes displayed
child output with its app name. The workbench still aggregates the root exit code.
Missing/malformed/duplicate required object fields are failures, not success.

Prepared tree is the complete intended contents below that app's Vault directory.
Local basis tree is the app-defined actual local comparison snapshot, interpreted
only by that app. Object IDs refer to this installation's local Git object store.
No scratch paths or raw payloads pass through the root protocol. RunId binds
separate calls to app-owned preparation and recovery data. Retrying after a new
remote uses a fresh RunId and the same unchanged accepted local basis.

The root updates only its local comparison ref; apps must not advance it on their
own. This records comparison input, not an application-success cache. App Complete
must verify the passed publication actually includes its prepared contribution.

### 2.23 PowerShell and encoding

Windows PowerShell 5.1 is the minimum. Verify both 5.1 and PowerShell 7 against
the same cases; report the actual versions and limits of the evidence. A common
script tested with substitute app outputs is not an app implementation or a
verified two-PC round trip. New code, comments and messages are English ASCII,
LF, no BOM. Generated metadata JSON is UTF-8 without BOM. Payloads remain bytes.

### 2.24 Invariants

- Never infer a deletion that has not been verified
- A Finish that publishes only some registered apps must be impossible
- Never re-serialise a payload or convert its encoding
- Never guess what an unknown structure means
- Never blanket-overwrite an app database or global state
- Never discard needed backups or pending publication material before publication
  is confirmed; any measured backed-up app write belongs before publication
- Never treat the only original or the only recovery copy as scratch
- Never resolve a delete-and-continuation state conflict automatically
- Never undo an accepted remote session using an unchanged stale local copy
- Never prefer the local copy on a same-path or same-session conflict
- Never force push or rewrite remote history
- Never remove local data on a mapping that has not been proven
- Never state a cause for a state difference that has not been shown
- Never persist per-app success flags to skip subsequent runs
- Never reset the Vault to origin/main in Finish
- Never equate Git HEAD or the merged published tree with actual app-local basis
- Block Finish for another PC's fetched baton; never use the baton to decide session conflicts
- Never discard pre-existing local-only commits as part of publication preparation

### 2.25 Features that do not exist

- A preflight entry point, option or mode
- A separate gate
- Automatic survey
- Automatic conflict resolution
- Generic agent auto-registration
- Background automatic synchronisation

## Part 3. Implementation closeout - 2026-09-06

The nine entry files now contain app implementations rather than provisional
success stubs. Common and app Start/Finish ran against the installation; the
latest provided All-Start log reports Success for both apps and the root.
Reactivate remains a known call-scope mismatch described in section 2.20;
file presence and successful parsing are not completion of that requirement.

See [Implementation closeout](IMPLEMENTATION_CLOSEOUT_2026-09-06.md) for the full
requirements, fixes, evidence boundaries, failure handling and unimplemented
full-scan improvement candidates. Private logs, IDs and recovery paths live
only in the installed Vault's closeout evidence document.

The nine entry files do not depend on the former support scripts, tests,
Agents configuration or old layout examples. Removal of that obsolete set was
blocked by approval review because explicit deletion authority was not granted.
Those files remain as unsupported legacy material pending user approval; do not
run their tests as evidence for the new implementation. A pre-closeout backup
exists. No new test framework is added to the public distribution.

Verification distinguishes parser checks, isolated real-entry execution,
single-machine app observations and an actual second-machine UI round trip.
The last item is not established by an isolated fixture or the latest log.
Do not weaken payload integrity, deletion evidence, conflict reporting or Cancel
to reduce runtime. Do not introduce automatic surveys or version-number gates.

### Approved incremental processing direction - 2026-09-06 follow-up

This revises the optimization design, not the runtime implementation. Both
Start and Finish should complete as quickly as possible. One minute is a target,
not a timeout or failure gate. Initial full transfer and bulk changes must be
measured separately from unchanged runs and small conversational updates.

For Codex, resolve each canonical session's current latest rollout path, then
compare that local path and its full SHA-256 with the previous verified state.
Do not keep reading a fixed former path after a new physical page is selected.
The path comparison is within this machine, not a cross-machine path identity.
A path/hash change selects the conversation for required analysis; it does not
mean all predecessor bytes or all other sessions changed. A new page requires
checking its history_base linkage and the necessary referenced boundaries.

An unchanged latest path/hash with unchanged related state may reuse existing
verified conversation analysis and transport. It is not a signature proving
every predecessor, attachment or database unchanged. Remote Git object changes,
deletion, movement, indexes and placement remain separate inputs. This does not
replace three-way session conflict decisions with a hash-only publication gate.
No prior verification, changed actual validation rules or unprovable relationships
require validation, not silently manufactured cache success. App version alone
is not an invalidation or permission rule.

Start should reuse identical verified Git objects and unaffected local comparison
material; after applying, validate changed targets and affected relationships
instead of unconditionally rebuilding everything. Finish should analyse changed
conversations, handle independent state transitions, reuse unchanged output and
retain the joint publication/Cancel/Complete contract.

Measured locally: ten app-listed latest rollouts totalled 463.44 MiB. Shared-read
SHA-256 passes took 1.147/0.770/0.706 seconds in PowerShell 5.1 and
0.691/0.638/0.636 seconds in PowerShell 7.6.5, with OS cache not flushed.
This excludes process startup, path lookup and JSON analysis. An edited/resubmitted
question was followed by a new latest page linked to a prefix of its predecessor;
path/hash comparison detected the change even though the question text repeated.
This is a scoped observation, not proof that editing always rolls over a page.

Claude requires its own measured record/lineage change selector; the Codex result
does not establish a Claude single-latest-page model. No new cache/config file,
background watcher, app-success flag or root-owned app policy is specified here.
Use existing verified basis/transport mechanisms first. Record any additional
state requirement and its necessity before expanding that design.

Cross-review unchanged and small-update Start/Finish, edits/rewinds/page changes,
new sessions, remote changes, deletion/Archive, failures and rollback. Compare
semantic/byte results and total duration, not just cache hit counts. See closeout
section 6 and the private evidence for the measured data. Optimization remains
unimplemented; no end-to-end runtime improvement has yet been demonstrated.
