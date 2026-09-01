# Claude Session Structure

How the Claude desktop app composes one conversation session on disk, and what
a complete session unit consists of.

This document records **structure only**. Measured values - session counts,
sizes, real identifiers, machine paths, hashes - belong to the private Vault
survey, not here. Every statement below is scoped to what was actually observed
on the versions listed; nothing is asserted as universal app behaviour.

Derived from survey `Surveys/Claude/2026-08-31.md` (baseline date 2026-08-31,
one machine). See `SURVEY_GUIDE.md` for what a survey is and when a new one is
required. Where this document and that survey disagree, the survey is the
evidence and this document is corrected.

## 1. Observed versions

| Component | Version | First observed | Last confirmed |
|---|---|---|---|
| Desktop app | `Claude_1.40609.0.0_x64` | 2026-08-31 | 2026-08-31 |
| CLI engine | `2.1.247` | 2026-08-31 | 2026-08-31 |
| App record | no schema version field present | 2026-08-31 | 2026-08-31 |
| Sidecar | `"v": 1` | 2026-08-31 | 2026-08-31 |
| Tombstone | 13-byte ASCII epoch milliseconds | 2026-08-31 | 2026-08-31 |

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

The field is **optional and uncommon** in the surveyed sample - most records do
not have it. The conditions under which the app adds an entry have not been
determined. Absence must not be read as "this conversation has no history".

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
```

Per-field frequencies are in the Vault survey.

Notes:

- Record size is dominated by `remoteMcpServersConfig`, which holds tool
  schemas for the machine's MCP servers.
- A record without `title` is displayed by the app as `General coding session`.
- `isArchived` is written by the app. A sync tool should read it, not write it.
- `titleSource` was observed with the values `auto` and `custom`.

## 7. Deletion signal

Observed once: deleting a single conversation from the sidebar produced all of
the following in one operation.

| Step | Target | Effect |
|---|---|---|
| 1 | `local_<appSessionId>.json` | removed |
| 2 | `deleted_<cliSessionId>` | created, one per identifier in the lineage |
| 3 | `<cliSessionId>.desktop-released.json` | created |
| 4 | `<cliSessionId>.jsonl` | untouched; still present afterwards |
| 5 | `dframe-group-scopes` assignments and order | entry removed |

### Tombstone

13 bytes, ASCII, Unix epoch milliseconds, no trailing newline.

```
deleted_dddddddd-dddd-dddd-dddd-dddddddddddd
1788175963002
```

In the observed deletion, two tombstones were written and both carried the same
value. Whether that holds for every deletion has not been established.

### Sidecar

```json
{
  "v": 1,
  "releasedAt": "2026-08-31T11:32:43.008Z",
  "reason": "delete"
}
```

`releasedAt` trailed the tombstone value by a few milliseconds. `reason` is a
field, so values other than `delete` may exist; none have been observed.

### Consequence

In the observed deletion the transcript was **not** removed. A tool that treats
"present on disk" as "live" will republish conversations the user deleted. A
tombstone may exist for an identifier that has no transcript; one such case was
observed and its cause is unknown.

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
- The same group data was also found in `Local Storage\leveldb`. At the time of
  observation the LevelDB files had a newer modification time than the config
  file. Whether LevelDB overwrites the config file, and under what conditions,
  was not tested. Until that is established, treat editing the config file
  while the app is running as unsafe.

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
- Why a lineage identifier can have a tombstone but no transcript.
- The conditions under which the app adds a `priorCliSessionIds` entry.
- On-disk representation of an archived session (`isArchived: true`).
- Whether LevelDB overwrites the config file, and when.
- Which process writes which storage layer.
- Any behaviour on a second machine; only one machine has been surveyed.

## 12. Structure change log

Baseline row only. Nothing here is a change from an earlier release; no earlier
release of this app has been surveyed.

| Date | Versions | Change | Survey |
|---|---|---|---|
| 2026-08-31 | app `Claude_1.40609.0.0_x64`, engine `2.1.247` | Baseline. First survey of this agent. | `Surveys/Claude/2026-08-31.md` |

Add one row per confirmed structural change, newest last. A row is added only
after a survey establishes the change; a version bump with no observed
structural difference gets a new date in the version table of section 1, not a
row here.
