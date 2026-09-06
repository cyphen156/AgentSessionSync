# Claude Session Structure

How the Claude desktop app composes one conversation session on disk, and what
a complete session unit consists of.

This document records **structure only**. Measured values - session counts,
sizes, real identifiers, machine paths, hashes - belong to the private Vault
survey, not here. Every statement below is scoped to what was actually observed
on the versions listed; nothing is asserted as universal app behaviour.

Derived from surveys `Surveys/Claude/2026-08-31.md` and
`Surveys/Claude/2026-09-01.md`, both on one machine. See `SURVEY_GUIDE.md` for
what a survey is and when a new one is required. Where this document and a
survey disagree, the survey is the evidence and this document is corrected.

The 2026-09-01 survey found the same app and engine versions but corrected
several claims that the 2026-08-31 survey had inferred rather than measured:
the trigger that extends a lineage (section 4), how many tombstones a deletion
writes and which files it touches (section 7). Those corrections are not app
behaviour changing; they are this document being wrong earlier. The version
table below therefore gains no new row and section 12 gains none either.

## 1. Observed versions

| Component | Version | First observed | Last confirmed |
|---|---|---|---|
| Desktop app | `Claude_1.40609.0.0_x64` | 2026-08-31 | 2026-09-01 |
| CLI engine | `2.1.247` | 2026-08-31 | 2026-09-01 |
| App record | no schema version field present | 2026-08-31 | 2026-09-01 |
| Sidecar | `"v": 1` | 2026-08-31 | 2026-09-01 |
| Tombstone | 13-byte ASCII epoch milliseconds | 2026-08-31 | 2026-09-01 |

Add a new row when a version changes; keep the previous row so the difference
between versions stays readable.

### Re-survey triggers

The app record carries no schema version, so a version number alone cannot
prove the structure is unchanged. Two triggers:

1. An observed version above changes.
2. Start or Finish encounters data that does not match the structure described
   here.

On either trigger the tool **reports the difference and states that a survey is
needed**. It does not re-survey by itself and does not convert formats by
itself. A re-survey is a full sweep, performed only when the user asks for one.
Evidence goes to the Vault survey; a confirmed structural change is then
recorded in this document.

Encountering an unknown field or shape is not by itself a failure, and it is
not by itself safe either:

| Situation | Run result |
|---|---|
| The difference does not prevent preserving the originals and completing the required work | Report completion, plus the difference and the need for a survey |
| The difference makes lineage, deletion targets or restore integrity unverifiable | **Failure**, stating the difference and the need for a survey |

Being able to copy the transcript bytes does not by itself mean the linkage is
intact.

## 2. Storage layers

A session is split across three locations.

```
(1) App record      %APPDATA%\Claude\claude-code-sessions\<accountId>\<deviceId>\
                        local_<appSessionId>.json
                        deleted_<cliSessionId>
                        scheduled-tasks.json

(2) Transcript      %USERPROFILE%\.claude\projects\<cwdSlug>\
                        <cliSessionId>.jsonl
                        <cliSessionId>.desktop-released.json

(3) Placement       %APPDATA%\Claude\claude_desktop_config.json
                        preferences.epitaxyPrefs["dframe-group-scopes"]
                                                ["<accountId>/<deviceId>"]
                    %APPDATA%\Claude\Local Storage\leveldb\
```

`<accountId>` and `<deviceId>` are GUIDs that appear in both the layer 1 path
and the layer 3 scope key. Their values on the surveyed machine are recorded in
the Vault survey. Whether and how they differ across machines has not been
observed, since only one machine has been surveyed.

Which process writes which layer has not been verified.

## 3. Identifiers

Two identifier spaces. No overlap was found between them in the surveyed
sample.

| ID | Appears in |
|---|---|
| `appSessionId` | `local_<id>.json` filename, `sessionId` field, group assignment keys |
| `cliSessionId` | `.jsonl` filename, `cliSessionId` field, tombstone filename |

The only join between layer 1 and layer 2 is the `cliSessionId` field inside
the app record.

### Stability

The two identifiers do not have the same lifetime.

| ID | Lifetime |
|---|---|
| `appSessionId` | Stable. Survived three lineage extensions of one conversation in the surveyed sample; the record file was never renamed |
| `cliSessionId` | Rotates. A new value is issued every time the lineage is extended (see section 4), and the previous value moves into `priorCliSessionIds` |

A tool that keys a conversation by `cliSessionId` loses the mapping the first
time the user extends the lineage. `appSessionId` is the stable key.

`appSessionId` never names a transcript file. Only `cliSessionId` values do.

### Transcript directory name

Derived from the session `cwd` by replacing every character outside
`[A-Za-z0-9]` with `-`. Verified against every directory in the sample.

```
C:\Example Project                 ->  C--Example-Project
C:\Work\SomeRepo                   ->  C--Work-SomeRepo
C:\Work\Nested\DeeperRepo          ->  C--Work-Nested-DeeperRepo
```

## 4. Lineage / continuation

Some app records carry a `priorCliSessionIds` array holding earlier
`cliSessionId` values for the same conversation. Each entry has its own
`.jsonl` file in the same transcript directory.

```
local_<appSessionId>.json
    cliSessionId        = "dddddddd-dddd-dddd-dddd-dddddddddddd"
    priorCliSessionIds  = [ "aaaaaaaa-...",   earliest
                            "bbbbbbbb-...",
                            "cccccccc-..." ]  most recent before current
```

**A complete session unit is the current transcript plus every transcript named
in `priorCliSessionIds`.** Matching only on `cliSessionId` and treating the rest
as unreferenced discards the live conversation's own history.

### When a lineage transcript is gone

The app does not record the absence. In the surveyed sample one conversation
referred to two `priorCliSessionIds` whose files no longer existed, and the app
carried on across 48 turns without marking that anywhere: no file, no sidecar,
no field. Absence is only visible by resolving `priorCliSessionIds` against the
transcript directory.

A tool therefore cannot learn from the app which losses are known and which are
new. That judgement belongs to the user, and the sync contract keeps it in the
private configuration rather than inferring it. See "Confirmed lineage loss" in
`IMPLEMENTATION_PLAN.md`.

The field is **optional and uncommon** in the surveyed sample - most records do
not have it. Absence must not be read as "this conversation has no history".

### What extends a lineage

Measured by controlled comparison on 2026-09-01: two conversations in the same
app over the same minutes, one given a rejected tool call only, the other a
rejected tool call followed by a rewind.

| Action | Effect on the app record |
|---|---|
| Rejecting a tool call | `completedTurns`, `lastFocusedAt`, `lastActivityAt` only. Identifiers unchanged, no new transcript |
| **Rewinding and resending** | New `cliSessionId` issued; the previous one is appended to the end of `priorCliSessionIds`; a new transcript file is created |

Observed three times in a row on one conversation. Other triggers may exist;
these two are what has been tested.

Two things a rewind does **not** do: it does not increment `completedTurns`,
and it does not change `createdAt`.

Compaction is **not** the trigger. In the surveyed sample five transcripts
carried a compaction record without any lineage entry existing, and six lineage
entries existed in transcripts carrying no compaction record.

### A continuation is not distinguishable from a new session by its transcript

The transcript created by a rewind opens the same way a brand new conversation
does: the first user record carries `parentUuid: null`.

More than that, the record graph does not cross the file boundary at all. Every
`parentUuid` in one seven-transcript lineage was resolved against both its own
file and its immediate predecessor:

```
parentUuid resolved inside the same transcript   690
parentUuid resolved in the predecessor             0
unresolved                                         0
```

The lineage exists **only** in the app record's `priorCliSessionIds`. It cannot
be reconstructed from transcript content. Once the app record is gone - which
is what deletion does, see section 7 - the on-disk lineage is unrecoverable
from the transcripts alone.

A compaction record can appear in two consecutive transcripts of one lineage.
That is not evidence that compaction split them: in the observed case the
record's timestamp preceded the split by 2 h 25 min, so the new transcript
carried a copy of an earlier compaction forward rather than being created by
it.

This is why "does not appear in the sidebar" is not a safe basis for treating a
transcript as unreferenced. The question that can be answered is "does any app
record claim this identifier in its lineage", and it can only be asked while
that record exists.

## 5. Example compositions

Synthetic identifiers. Not measured values.

```
%APPDATA%\Claude\claude-code-sessions\<accountId>\<deviceId>\
    local_11111111-1111-1111-1111-111111111111.json
        {
          "sessionId":          "local_11111111-...",
          "cliSessionId":       "dddddddd-...",
          "priorCliSessionIds": ["aaaaaaaa-...", "bbbbbbbb-...", "cccccccc-..."],
          "cwd":                "C:\\Example Project",
          "originCwd":          "C:\\Example Project",
          "title":              "Example conversation",
          "titleSource":        "auto",
          "isArchived":         false,
          "completedTurns":     42,
          "createdAt":          1780000000000,
          "lastActivityAt":     1788000000000,
          "lastFocusedAt":      1788000000000,
          "model":              "<model id>",
          "effort":             "medium",
          "permissionMode":     "default",
          "enabledMcpTools":    { },
          "remoteMcpServersConfig": [ ]
        }

%USERPROFILE%\.claude\projects\C--Example-Project\
    aaaaaaaa-....jsonl        prior, earliest
    bbbbbbbb-....jsonl        prior
    cccccccc-....jsonl        prior
    dddddddd-....jsonl        current

%APPDATA%\Claude\claude_desktop_config.json
    dframe-group-scopes["<accountId>/<deviceId>"]
        groups      : [ { "id": "cg-...", "name": "Example Group" } ]
        assignments : { "code:local_11111111-...": "cg-..." }
        order       : { "cg-...": [ "code:local_11111111-..." ] }
```

Complete unit for transport: four transcripts, one app record, one group
assignment.

## 6. Record fields

The list below is the **union observed across the sampled records**, not a
fixed schema. The app declares no schema version. Do not use field count as a
validation rule.

Present in every sampled record:

```
sessionId              cliSessionId           cwd
originCwd              createdAt              lastActivityAt
lastFocusedAt          completedTurns         isArchived
model                  effort                 permissionMode
enabledMcpTools        remoteMcpServersConfig alwaysAllowedReasons
classifierSummaryEnabled  lastSpawnRootDetected
sessionPermissionUpdates  spawnSeed
```

Present in only some records (optional):

```
title                  titleSource            reportFindingsCard
remoteControlAutoEligible                     chromePermissionMode
priorCliSessionIds     writtenBranches        sessionSettings
promptAppendSnapshot   bridgeSessionIds       contextExceededCount
```

The last three appeared in the 2026-09-05 survey and were absent from both
earlier ones. No field has disappeared. Their measured forms:

```
bridgeSessionIds       array of "session_" + exactly 24 alphanumerics, not UUIDs
promptAppendSnapshot   object: append, cliVersion, cwd, settingsKey; all strings
contextExceededCount   non-negative integer
```

Per-field frequencies are in the Vault survey.

Notes:

- Record size is dominated by `remoteMcpServersConfig`, which holds tool
  schemas for the machine's MCP servers.
- A record without `title` is displayed by the app as `General coding session`.
- `isArchived` is written by the app. A sync tool should read it, not write it.
- `titleSource` was observed with the values `auto` and `custom`.
- `createdAt`, `lastActivityAt` and `lastFocusedAt` hold epoch milliseconds as
  numbers, not strings.
- **`bridgeSessionIds` is not evidence of a transcript lineage.** Its values
  match no `cliSessionId`, no `appSessionId`, no `priorCliSessionIds` entry, no
  transcript file name, and appear in no transcript record or LevelDB file. What
  they refer to is not established. A sync tool must carry them and must not use
  them for session identity, lineage or deletion.
- `promptAppendSnapshot.append` held the app's injected system prompt and
  contained no path, account, device, MCP or URL string. Its sibling fields do
  carry machine state: `cwd` is an absolute path and `cliVersion` is the local
  app version. `settingsKey` was one value across every record that had it; what
  it keys is not established.

## 7. Deletion signal

Observed twice: once on a conversation with a single `cliSessionId`
(2026-08-31), once on a conversation whose lineage held four (2026-09-01, with
a full before-and-after snapshot). Deleting from the sidebar produced all of
the following in one operation.

| Step | Target | Effect |
|---|---|---|
| 1 | `local_<appSessionId>.json` | removed |
| 2 | `deleted_<id>` | created: one per `cliSessionId` in the lineage, **plus one for the `appSessionId`** |
| 3 | `<currentCliSessionId>.desktop-released.json` | created, for the current identifier only |
| 4 | `<currentCliSessionId>.jsonl` | still present, but **appended to**: one `last-prompt` record |
| 5 | prior `<cliSessionId>.jsonl` | still present, byte-identical, mtime unchanged |
| 6 | `dframe-group-scopes` assignments and order | not established, see below |

The second deletion wrote **five** tombstones for a four-identifier lineage.

```
deleted_<currentCliSessionId>
deleted_<priorCliSessionId>     x3
deleted_<appSessionId>          <- not a lineage member
```

### Tombstone

13 bytes, ASCII, Unix epoch milliseconds, no trailing newline.

```
deleted_dddddddd-dddd-dddd-dddd-dddddddddddd
1788175963002
```

Every tombstone written by one deletion carried the identical value, in both
observed deletions.

**One tombstone names an `appSessionId`, not a `cliSessionId`.** Because an
`appSessionId` never names a transcript, that tombstone has no `.jsonl` beside
it and matches no lineage identifier in any surviving record - the record that
carried it was removed by the same operation. This is a normal, fully explained
outcome of every deletion, not an anomaly. A tool that treats "a tombstone
nothing claims" as a fault will fault on every deleted conversation.

The 2026-08-31 deletion is explained by the same rule: that conversation had
one `cliSessionId` and one `appSessionId`, so it produced two tombstones, and
the second one had no transcript.

### What deletion does not do

- It does not remove any transcript, current or prior.
- It does not modify prior transcripts at all.
- It does not remove the tombstones it wrote; they persist.

### Sidecar

```json
{
  "v": 1,
  "releasedAt": "2026-08-31T11:32:43.008Z",
  "reason": "delete"
}
```

`releasedAt` trailed the tombstone value by 6 ms in both observed deletions,
and matched the current transcript's mtime to the millisecond in the second.
`reason` is a field, so values other than `delete` may exist; none have been
observed.

One sidecar per deletion, next to the current transcript. Prior transcripts do
not get one.

### Group assignment

The 2026-08-31 survey recorded the deleted session's entry disappearing from
`dframe-group-scopes`. The 2026-09-01 deletion could not confirm it: that
conversation had never been assigned to a group, the assignment count did not
change, and the configuration file was not written at all during the deletion.
What happens to an assigned session's placement on deletion is therefore not
established by a snapshotted observation.

### Consequence

In both observed deletions no transcript was removed. A tool that treats
"present on disk" as "live" will republish conversations the user deleted.

The signal to read is the tombstone, and reading it requires knowing which
identifier space it belongs to. Of the five tombstones written by one deletion,
four named transcripts and one named an app record that no longer exists.

## 8. Placement

```
preferences.epitaxyPrefs["dframe-group-scopes"]["<accountId>/<deviceId>"]
    groups      : [ { id: "cg-<uuid>", name: "<display name>" } ]
    assignments : { "code:local_<appSessionId>": "cg-<uuid>" }
    order       : { "cg-<uuid>": [ "code:local_<appSessionId>", ... ] }
```

- The scope key embeds `accountId` and `deviceId`.
- Assignment keys use `appSessionId`, not `cliSessionId`.
- A session absent from `assignments` is displayed under an ungrouped section.
- Rechecked on 2026-09-06: editing only the config while Claude was fully
  closed did not persist. After relaunch, the two removed assignments and
  order entries returned, and the parsed config equalled the pre-edit backup.
- The installed renderer persists `dframe-store` in Chromium Local Storage.
  Its version-1 envelope contains `state.customGroupsByScope`, including the
  assignments and order. `LSS-persisted.dframe-group-scopes` carries a second
  copy in its `value` member. The `dframe-local-slice` preference and its
  `LSS-persisted.dframe-local-slice` copy also carry pin arrays.
- Startup hydrates `dframe-store`, combines it with the preference scopes,
  and writes the resulting scopes back through `AppPreferences.setPreference`.
  Therefore config-only removal cannot establish persistent cleanup.
- The evidence is the installed renderer's `NO` / `MO` hydration and merge
  path in `shared-20-BuOxByKU.js`, the version-1 `dframe-store` persistence in
  `shared-2-DD9M-xj-.js`, and the `epitaxyPrefs` write bridge in
  `shared-12-RJIRw5sU.js`. These filenames identify the inspected build, not
  an allowed-app-version gate.
- Start must prepare browser-storage cleanup before changing app data, keep
  a backup of the complete original database file set, and remove only the
  selected app identities from the measured scope and pin lists. Group
  definitions, other identities, foreign scopes, and unrelated storage keys
  must remain intact. Unsettled legacy migration or an unknown shape fails.
- The current implementation uses the installed Microsoft Edge Chromium
  storage engine on an isolated copy under the app-owned run directory.
  It does not load the Claude application or contact claude.ai: every page
  request is fulfilled locally and external name resolution is disabled.
  It changes values through `localStorage`, closes and reopens the copy to
  verify persistence, then replaces the closed app's database with verified
  file backups. No LevelDB bytes are patched by hand. An unavailable engine,
  occupied database, or changed source aborts without accepting the cleanup.
- Isolated Chromium reopen and byte-exact rollback were verified in both
  PowerShell 5.1 and 7. On 2026-09-06 the two stale placements were then
  removed with a full storage backup and the actual Claude app was relaunched.
  Neither the config nor either persisted storage key regained the references.
  All app-record and tombstone files remained byte-identical. This verifies
  persistence of this cleanup, not every session UI or the full sync round trip.

## 9. Portability

Structural facts observed:

| Item | Observation |
|---|---|
| Transcripts | Carry machine absolute paths. In the sampled files most records include a `cwd` holding the session's absolute working directory, and records also carry `gitBranch` and an engine `version`. Bytes transfer unchanged; how a target machine should treat those paths is a separate question, not settled here |
| `cliSessionId`, `priorCliSessionIds` | Identify the conversation, not the machine |
| `enabledMcpTools`, `remoteMcpServersConfig` | Describe the machine's MCP servers |
| `cwd`, `originCwd` | Absolute paths; identical only if the target machine uses the same path |
| Group scope key | Contains `accountId` and `deviceId` |
| `appSessionId` | Names a file inside a specific `<accountId>\<deviceId>` directory |

Decisions that follow from these facts are **not** settled here. Whether to
issue a new `appSessionId` or reuse an existing mapping, whether to carry over
`model`, `effort` and `permissionMode` or take the target machine's values, and
how to remap the group scope key are implementation choices for the tool
design, not properties of the storage.

What is established: copying `enabledMcpTools` and `remoteMcpServersConfig`
from another machine would replace the target machine's own MCP configuration.

## 10. Transport

Transcripts are byte payloads. Read and write them as bytes; do not round-trip
them through a text encoding. This is not theoretical: reading a sampled
transcript with PowerShell 5.1 default encoding corrupted non-ASCII content and
made the line unparseable as JSON.

Transferring the bytes unchanged is necessary but not sufficient. Records carry
machine-specific values (see section 8), so byte-identical transport does not
by itself mean the transcript is usable as-is on another machine.

No compression threshold is established by this document.

## 11. Not yet observed

- Values of `reason` other than `delete`.
- On-disk representation of an archived session (`isArchived: true`). Every
  record in both surveys carried `isArchived: false`.
- What happens to an assigned session's `dframe-group-scopes` entry on
  deletion, under a before-and-after snapshot.
- Writer behaviour outside the measured dframe hydration/repersistence path
  in section 8. That specific path was checked on 2026-09-06; other keys and
  future renderer behaviour remain unverified.
- Which process writes which storage layer.
- Triggers that extend a lineage other than a rewind.
- Whether a prior transcript is ever written to after it becomes a prior. The
  one observed write to a transcript that was about to become a prior happened
  3.8 seconds before the new transcript opened, so it belongs to the old
  session, not to its life as a prior.
- Why `titleSource: custom` was present in the 2026-08-31 sample and absent
  from the 2026-09-01 one.
- Any behaviour on a second machine; only one machine has been surveyed.

Resolved since the 2026-08-31 survey, and no longer open: why a tombstone can
exist for an identifier with no transcript (it names an `appSessionId`), how
many tombstones a deletion writes, what deletion does to transcripts, and what
extends a lineage.

## 12. Structure change log

The baseline row records the initial survey. Later dated observations and
implementation checks are scoped separately; none establish an unknown
feature introduction date.

| Date | Versions | Change | Survey |
|---|---|---|---|
| 2026-08-31 | app `Claude_1.40609.0.0_x64`, engine `2.1.247` | Baseline. First survey of this agent. | `Surveys/Claude/2026-08-31.md` |

| 2026-09-05 | Stored records; version identity remains supplementary | Observed optional bridgeSessionIds, promptAppendSnapshot and contextExceededCount. Preserve opaque values; do not infer transcript lineage from bridge IDs. | `Surveys/Claude/2026-09-05.md` |
| 2026-09-06 | Installed renderer, targeted placement verification | Section 8 records dframe LocalStorage hydration and verified persistent placement removal; not a full new survey. | Private closeout evidence and section 8 |

For implementation and operational validation scope, see
[the closeout](IMPLEMENTATION_CLOSEOUT_2026-09-06.md).

Add one row per confirmed structural change, newest last. A row is added only
after a survey establishes the change; a version bump with no observed
structural difference gets a new date in the version table of section 1, not a
row here.
