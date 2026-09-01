# Codex Session Structure

Baseline date: 2026-08-31.
Recording conventions: [Session Survey Guide](SURVEY_GUIDE.md).
Private baseline: AgentSessionVault/Surveys/Codex/2026-08-31.md.

This is a structure reference for Finish and Start, not a completed adapter or
a declaration of cross-machine compatibility. Observations are scoped to the
versions below. A, B, C, G and P are synthetic identifiers. Examples show selected
fields and relationships, not complete application records or runnable fixtures.

## 1. Observed versions

| Component | Version | First observed | Last confirmed |
|---|---|---|---|
| Desktop package | 26.825.6671.0 | 2026-08-31 | 2026-08-31 |
| Internal app | 26.825.51511 | 2026-08-31 | 2026-08-31 |
| Active backend | 0.151.0-alpha.7.2 | 2026-08-31 | 2026-08-31 |

Versions recorded in the first session_meta of existing transcripts:

| cli_version | Observed shape | First observed | Last confirmed |
|---|---|---|---|
| 0.146.0-alpha.9.2 | user / legacy, embedded fork history | 2026-08-31 | 2026-08-31 |
| 0.147.0-alpha.6.6 | user / legacy | 2026-08-31 | 2026-08-31 |
| 0.149.0-alpha.4.3 | user / paginated, no initial history_base | 2026-08-31 | 2026-08-31 |
| 0.150.0-alpha.8 | user / paginated continuation with history_base | 2026-08-31 | 2026-08-31 |
| 0.151.0-alpha.7.1 | user / paginated, no initial history_base | 2026-08-31 | 2026-08-31 |
| 0.151.0-alpha.7.2 | user / paginated initial and continuation pages; guardian_review / legacy | 2026-08-31 | 2026-08-31 |

These are observations of stored metadata, not separate execution tests of each
historical app version. They do not establish a feature's first release.
Even the same backend version can produce different user and guardian shapes.

### When to re-survey

Reuse this reference for known versions and structures. On a new version or a
structural mismatch, Start/Finish should report the difference and request a survey.
Re-survey is a full sweep only when the user instructs it; never an automatic
conversion or background investigation.

If originals and required work remain verifiable, report completion and the
difference. If lineage, deletion targets or restore integrity cannot be verified,
report Failure and the difference. Copyable bytes alone do not prove intact links.
This describes the agreed behaviour, not an implementation verification.

## 2. Storage layers

Paths below are relative to the discovered <CODEX_HOME> unless stated otherwise.

| Location | Observed role |
|---|---|
| sessions/**/*.jsonl | Conversation records, tool calls/results, lineage, some embedded images |
| archived_sessions | Application archive location |
| state_5.sqlite | Threads, latest rollout_path, projects and related state |
| thread_history_1.sqlite | Turn/item projections and history offsets |
| session_index.jsonl | Index including display titles |
| sqlite/codex-dev.db | App catalog containing local and ChatGPT records |
| .codex-global-state.json | Project placement, order, tabs, host mappings and unrelated settings |
| attachments and pasted-text-attachments.json | Pasted text and its path index |
| visualizations/.../<thread-id>/ | Session-related generated artifacts; intermediate directories vary |
| browser/sessions/<thread-id>.toml | Some session-specific browser settings |
| %APPDATA%/Codex/web/Codex/browser-sidebar-page-states.json | Browser page state with client-thread references |

Numbered database filenames are observed names, not permanent cross-version APIs.
Memory, log and queue databases are not included in session transport merely
because they exist. Browser cookies and credentials are not session attachments.

## 3. Identifiers

| Identifier | Meaning in observed cases |
|---|---|
| User thread ID A | Canonical identity retained across continuation pages |
| Physical storage alias P | May appear in a continuation filename and history projection key |
| Guardian ID G | Own subagent identity, distinct from parent A |
| session_meta.id / session_id | Interpretation depends on user versus guardian structure |
| forked_from_id | Parent thread reference in fork history |
| parent_thread_id | Parent reference observed for guardian sessions |
| Project and client IDs | Additional mapping layers for placement and tabs |

Do not assume the last UUID in a filename is a user thread ID.
Do not universally prefer session_id over id: it can refer to the parent of a guardian.
Multiple past session_meta records in one transcript do not each create a new live thread.

## 4. Lineage / continuation

A user thread can have an earlier physical page and a later continuation.
The state row retains the canonical identity but points to the latest file.
history_base refers to a predecessor history boundary, expressed in both record
ordinal and original byte offset. Verify the actual line boundary and ordinal,
not just whether the offset is below file size.

Forked transcripts may include parent history without retaining a standalone
parent file. Embedded history does not prove an exact recoverable parent original.
Corresponding parent/child records were not all equal in the observed sample;
do not remove a parent as a duplicate merely because a child exists.

A guardian can have its own physical file and ID while referencing a user parent.
An empty thread_spawn_edges table does not prove that no subagent relationship exists.

## 5. Example compositions

### Case 1: legacy user session

~~~text
state.threads.id = A
  rollout_path -> sessions/.../rollout-...-A.jsonl
session_index entry A -> display title
first session_meta -> A
~~~

~~~json
{"id":"A","session_id":"A","thread_source":"user","history_mode":"legacy"}
~~~

Finish checks the original against its references. Start must restore app-facing
links as well as file bytes. state.title may contain the initial prompt rather
than the display title.

### Case 2: paginated continuation

~~~text
User thread A
  earlier page: rollout-...-A.jsonl
  later page:   rollout-...-A_P.jsonl
  state.threads.id = A
  state.threads.rollout_path -> later page
  thread_history projection key = P
~~~

~~~json
{
  "id": "A",
  "session_id": "A",
  "thread_source": "user",
  "history_mode": "paginated",
  "history_base": {
    "thread_id": "A",
    "end_ordinal_exclusive": 2,
    "end_byte_offset": 17
  }
}
~~~

The numbers are synthetic: these two illustrative UTF-8 JSONL lines occupy
17 bytes when each displayed \n denotes one actual LF byte.

~~~text
{"n":1}\n
{"n":22}\n
~~~

The first line is 8 bytes and the second 9. These are not real application records.
An initial page may omit history_base. Finish must collect the required earlier
page; Start must preserve both pages and the reference. Do not merge pages or
rename A_P to A as a shortcut.

### Case 3: fork history

~~~text
A -> fork B -> fork C
     B.forked_from_id = A
               C.forked_from_id = B
~~~

A parent's metadata may remain inside B or C even if its standalone file is missing.
Keep standalone files distinct from embedded history. Do not create empty parent
files to make reference checks appear complete. Report unresolved history.

### Case 4: guardian

~~~text
User A <- parent reference from guardian G
Guardian G has its own transcript.
~~~

~~~json
{
  "id": "G",
  "session_id": "A",
  "parent_thread_id": "A",
  "thread_source": "guardian_review",
  "history_mode": "legacy",
  "source": {"subagent":{"other":"guardian"}}
}
~~~

Finish follows the relationship even if G is not directly visible in the sidebar.
Start must not merge G into A or recreate G as a duplicate user conversation.

### Case 5: app placement

~~~text
User A
  -> transcript
  -> state row and latest path
  -> session_index title
  -> local app catalog entry
  -> project, order and tab references in global state
~~~

A NULL state.threads.project_id did not mean the app lacked a project group.
Project migration and thread-assignment migration can have different states.
File placement alone is not proof of app visibility or resumability.

### Case 6: attachments

~~~text
User record -> text attachment path
  <- attachmentPaths in pasted-text-attachments.json
  <- textExcerptsByPath
User image event -> embedded input_image in a nearby response_item
~~~

The index can hold absolute paths. A tool result quoting a path does not establish
user attachment ownership. A missing temporary PNG does not prove image loss when
the transcript embeds the image, but embedded bytes do not prove equality with
the unavailable external original. Preserve references without inventing ownership.

## 6. Record fields

Selected observed fields, not a complete or required schema:

| Record / source | Fields or relationships |
|---|---|
| session_meta | id, session_id, cli_version, source, thread_source, history_mode |
| Continuation metadata | history_base.thread_id, end_ordinal_exclusive, end_byte_offset |
| Fork / guardian metadata | forked_from_id, parent_thread_id |
| state thread row | id, rollout_path, title, name, project_id |
| Pasted text index | attachmentPaths, pendingRemovalPaths, textExcerptsByPath |

history_base was absent from initial pages. Fork and guardian fields depend on the
record kind. state.name was NULL for some older threads. Do not turn sample field
presence or counts into a fixed schema validation rule.

Observed JSONL record types include session_meta, event_msg, response_item,
world_state, turn_context, compacted and inter_agent_communication_metadata.

## 7. Deletion signal

A durable Codex deletion tombstone has not been established.
The installed app contained thread/delete calls and missing-rollout recovery logic.
A writing block's deleted flag was also present for a live thread; it is not a
thread-deletion tombstone.

File absence, sidebar absence or a missing DB row alone does not establish final
deletion. The app's archive and a tool-defined Vault archive are separate concepts.
Legacy checkpoint-based deletion inference is not validated by this survey.

## 8. Placement

Observed keys and relationships include:

- thread-project-assignments
- sidebar-project-thread-orders
- thread-writable-roots
- local-projects
- Client/thread bindings and canonical/client references in tabs
- Host-specific mappings from earlier project IDs to state.projects UUIDs

The index can contain duplicate thread IDs. state.title and state.name do not
universally provide the sidebar title. App catalog records include other backing
types, not just local Codex threads.

Restoring global state or a catalog database wholesale can replace unrelated
target-machine state. No safe catalog reconstruction API or direct DB edit
procedure is established by this document.

## 9. Portability

| Item | Established observation / boundary |
|---|---|
| Transcript and attachment payloads | Preserve existing bytes; this is not proof of path portability |
| Canonical, alias and guardian identities | Different roles must remain distinguishable |
| Attachment indexes and working paths | Can contain machine-specific absolute paths |
| Host/project/client mappings | Need target-machine handling; cross-machine behaviour not verified |
| Global state and app catalog | Mix session links with unrelated application state |
| Browser profiles | Credentials and cookies are not automatically session payloads |

Whether to rebuild or merge app-owned state, and how to bind target paths without
changing originals, remain implementation decisions requiring verification.

## 10. Transport

Preserve original bytes, encoding, BOM, line endings and final newline. Do not
re-serialize JSONL to inspect or copy it. Recompute hashes for the actual run rather
than using an old survey hash as a permanent expectation for a growing transcript.

With a nonempty SQLite WAL, copying the main database alone while the app runs
does not establish a consistent snapshot. Read-only integrity checks on individual
databases do not prove consistency across them.

Git -text disables text normalization; it does not force LF or disable every
other content filter. Verify effective transport attributes.

Ordinary GitHub Git has a 100 MiB single-file limit. Oversized originals were
observed, but gzip, LFS, splitting or another transport has not been selected.
No compression threshold is established here.

## 11. Not yet observed

- Historical app versions executed separately to establish introduction dates.
- A reliable final-deletion signal.
- Complete recovery of absent standalone parents and unresolved subagent references.
- Ownership of every unassigned attachment.
- Safe app catalog/index creation or update on the target machine.
- Cross-machine host, project, client and path mapping.
- A selected transport for oversized originals.
- Failure recovery and repeated runs without duplication or fragmentation.
- End-to-end restore and continued conversation on a second machine.

A structure survey does not prove Finish/Start implementation or round-trip success.

## 12. Structure change log

| Date | Version / comparison | Confirmed structure | Finish / Start impact |
|---|---|---|---|
| 2026-08-31 | Versions in section 1; initial baseline | Legacy, continuation, fork, guardian, placement and attachment relationships | Preserve related originals and distinguish identity layers; restoration remains unverified |

This baseline came from one observed environment, not an execution comparison
against a prior app release. Add confirmed changes and corrections with evidence
in the matching private survey report.

References used in the original survey:
- [Codex App Server](https://learn.chatgpt.com/docs/app-server): thread behaviour, not a local DB restore guarantee.
- [GitHub file limits](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github).
