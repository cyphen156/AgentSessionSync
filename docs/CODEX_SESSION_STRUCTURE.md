# Codex Session Structure

Baseline date: 2026-08-31.
Recording conventions: [Session Survey Guide](SURVEY_GUIDE.md).
Private surveys: AgentSessionVault/Surveys/Codex/2026-08-31.md,
AgentSessionVault/Surveys/Codex/2026-09-01.md, and
AgentSessionVault/Surveys/Codex/2026-09-03.md (targeted archive/restore only),
and AgentSessionVault/Surveys/Codex/2026-09-05.md.

This is a structure reference for Finish and Start, not by itself a declaration
of cross-machine compatibility. Implementation status is recorded separately in
[the closeout](IMPLEMENTATION_CLOSEOUT_2026-09-06.md). Observations are scoped to the
versions below. A, B, C, G and P are synthetic identifiers. Examples show selected
fields and relationships, not complete application records or runnable fixtures.

## 1. Observed versions

| Component | Version | First observed | Last confirmed |
|---|---|---|---|
| Desktop package | 26.825.6671.0 | 2026-08-31 | 2026-09-01 |
| Internal app | 26.825.51511 | 2026-08-31 | 2026-09-01 |
| Active backend | 0.151.0-alpha.7.2 | 2026-08-31 | 2026-09-01 |
| App-server executable | 0.152.0 | 2026-09-02 | 2026-09-02 |
| Backend of one archive/restore test thread and installed executable | 0.153.0-alpha.5 | 2026-09-03 | 2026-09-03 |
| Desktop package | 26.901.4073.0 | 2026-09-05 | 2026-09-05 |
| Internal app executable | 152.0.7977.64 | 2026-09-05 | 2026-09-05 |
| Installed app-server executable | 0.153.1 | 2026-09-05 | 2026-09-05 |

Versions recorded in the first session_meta of existing transcripts:

| cli_version | Observed shape | First observed | Last confirmed |
|---|---|---|---|
| 0.146.0-alpha.9.2 | user / legacy, embedded fork history | 2026-08-31 | 2026-08-31 |
| 0.147.0-alpha.6.6 | user / legacy | 2026-08-31 | 2026-08-31 |
| 0.149.0-alpha.4.3 | user / paginated, no initial history_base | 2026-08-31 | 2026-08-31 |
| 0.150.0-alpha.8 | user / paginated continuation with history_base | 2026-08-31 | 2026-08-31 |
| 0.151.0-alpha.7.1 | user / paginated, no initial history_base | 2026-08-31 | 2026-08-31 |
| 0.151.0-alpha.7.2 | user / multi-page paginated; guardian_review / legacy | 2026-08-31 | 2026-09-01 |
| 0.152.0 | user / paginated continuation with predecessor physical alias and dynamic_tools | 2026-09-05 | 2026-09-05 |
| 0.153.0-alpha.5 | one agent-created paginated initial page; token_usage_record observed | 2026-09-03 | 2026-09-03 |
| 0.153.1 | one guardian_review / legacy file; same selected first-meta shape as the 0.153.0-alpha.5 guardian sample | 2026-09-05 | 2026-09-05 |

These are observations of stored metadata, not separate execution tests of each
historical app version. They do not establish a feature's first release.
Even the same backend version can produce different user and guardian shapes.
The version rows describe observed samples, not an execution allowlist.
Versions and version/source combinations alone must not reject a session.
The actual history mode, source, identifiers, predecessor linkage, record shapes
and database structures remain subject to validation.

### When to re-survey

Use this reference to check actual structures. A new app/backend version is
supplementary information: report that storage may have changed, not that it did.
Version alone never blocks Start/Finish. Report actual structural mismatches and
the need for a survey; do not invent a compatible shape from a version number.
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
| thread-writer-locks/<thread-id>.lock | Empty coordination lock observed for the active canonical thread; not a conversation payload |
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
ordinal and original byte offset. Its thread_id can be the canonical ID on an
early continuation or the immediately preceding physical page alias on a later
continuation. Verify the physical alias, the actual line boundary and ordinal,
not just whether the offset is below file size. Do not restrict predecessor
lookup to files whose canonical ID equals history_base.thread_id.

Forked transcripts may include parent history without retaining a standalone
parent file. Embedded history does not prove an exact recoverable parent original.
Corresponding parent/child records were not all equal in the observed sample;
do not remove a parent as a duplicate merely because a child exists.

A guardian can have its own physical file and ID while referencing a user parent.
An empty thread_spawn_edges table does not prove that no subagent relationship exists.

An agent-created thread can carry its source relation only inside the
create_thread function output as a source_thread_id value. The source need not
appear in session_meta or thread_spawn_edges. In one controlled deletion, the
app removed the source thread and every one of its physical pages while leaving
the agent-created thread, its rollout, state, history projection, catalog,
index and worktree intact. Direct lookup of the child continued to work.

This is a surviving branch with an explicit deleted-source relation. Preserve
the branch and the source identifier. Do not recreate the deleted source and do
not cascade the source deletion into the child. A missing source does not make
an otherwise complete and readable child an unknown new session. Transport can
keep the source relation as provenance without requiring the source payload.

A newly created logical session is not unresolved merely because it is absent
from the Vault or the accepted local comparison basis. When its local transcript, canonical
state row, history projection and app catalog relationships are internally
consistent, Finish treats it as new upload material. An unresolved or orphaned
classification requires a concrete dangling or contradictory relationship.

An undo and retry can create another physical page with the same canonical ID
without history_base. The new page can restart ordinals and contain different
records while the canonical state row moves to it and history projections retain
both physical keys. Preserve both originals. Do not classify the older page as
a duplicate or orphan only because it is no longer the latest path.

A later continuation after that retry can reference the retry page's physical
alias in history_base at an early truncated boundary. Resolve that alias and
verify the byte and ordinal boundary just as for an ordinary continuation.

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

### Paginated history restoration check (2026-09-06)

With installed backend 0.153.4, four sidebar-visible paginated conversations
had intact originals and catalog/state rows but no local history rows.
The matching published projections still contained their turns and items.
On isolated copies, thread/read with includeTurns and thread/turns/list both
returned empty results and did not reconstruct these rows. thread/resume
reconstructed a single physical page, but did not reconstruct missing
predecessor projections for a multi-page conversation; a stale predecessor
path was explicitly refused. Do not bypass that refusal or change originals.

Restoring the already transported history rows, keyed by their original
canonical/physical identifiers, restored app-server content reads without
changing original bytes. Start must restore those rows after clearing the old
projection and before thread/read. Its applied-state check must compare the
restored history values, not only state-row and rollout-path existence.
This is an application/reconstruction observation, not a change to session
identity, app archive state, Vault tiers, or deletion evidence. One of the four
conversations was an existing archive/restore test; its original single turn
was preserved, not replaced by an invented normal-session shape.

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

A later survey observed a third physical page for the same canonical thread:

~~~text
canonical A
  page 1 key A
  page 2 alias P2, history_base.thread_id = A
  page 3 alias P3, history_base.thread_id = P2
  state latest rollout_path -> page 3
  history projection keys -> A, P2, P3
~~~

The third page still recorded A in session_meta.id and session_id. The
predecessor reference alone used P2. Each boundary was verified against the
predecessor's original byte offset and record ordinal.

The 2026-09-05 full sweep confirmed the same form on a second canonical
thread. Its 0.152.0 third page used the immediately preceding physical alias
in `history_base.thread_id`; the referenced byte offset ended on LF and the
last preceding ordinal was exactly `end_ordinal_exclusive - 1`.

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

history_base was absent from initial pages. Its thread_id role depends on the
continuation depth as described in section 4. Fork and guardian fields depend on
the record kind. state.name was NULL for some older threads. Do not turn sample
field presence or counts into a fixed schema validation rule.

Observed JSONL record types include session_meta, event_msg, response_item,
world_state, turn_context, compacted and inter_agent_communication_metadata.

`dynamic_tools` is optional session metadata. In the observed 0.152.0 user
continuation it was an array with two tool-provider descriptions. Its presence
does not change canonical identity or continuation resolution.

The 2026-09-03 targeted sample also contains one `token_usage_record`. Its outer
keys are timestamp, ordinal, type and payload. Observed payload keys are
thread_id, turn_id, session_id, root_turn_id, response_id, usage,
turn_token_usage and thread_token_usage. Each usage object contains input_tokens,
cached_input_tokens, cache_write_input_tokens, output_tokens,
reasoning_output_tokens and total_tokens. This is one observed record, not a
complete required schema or proof of the type's introduction version. Preserve
its original bytes. This targeted sample does not validate every new-version
record or replace a full structure survey.

## 7. Deletion signal

A durable Codex deletion tombstone has not been established.
The installed app contained thread/delete calls and missing-rollout recovery logic.
A writing block's deleted flag was also present for a live thread; it is not a
thread-deletion tombstone.

File absence, sidebar absence or a missing DB row alone does not establish final
deletion. The app's archive and a tool-defined Vault archive are separate concepts.
Start retains the accepted Vault tier when collecting the pre-apply comparison
snapshot, falling back to the received tier when no accepted entry exists.
After application it records the received tier with the actual app metadata.
The native archived flag is preserved in projection.state; it never selects
an Archived path in the Start comparison tree. Untracked local sessions are
inventoried as Active, without deciding Finish's age policy or final deletion.
Legacy checkpoint-based deletion inference is not validated by this survey.

The implementation contract reserves native Codex Archived as user deletion
transit; this is a user policy, not a claim that archive is a native tombstone.
Finish validates archived=1, archived_at and the archived rollout relation before
completing removal with the same verified backup/Cancel path as Vault Archive.
A published session then contributes only Deleted, with the prior published
identity and lineage and the app's archive-request timestamp. The 30-day Vault
Archived policy still preserves full originals and never selects native archive.
A wholly missing accepted Active without this signal stops for user review.

In one observed archive operation on an agent-created thread, the app moved the
rollout byte-identically from sessions to archived_sessions, retained its state
row with archived=1 and a new rollout_path, retained its history projection and
session index entry, and removed its local app catalog row. The worktree and
other app-state references remained. The archived thread did not appear in the
archived-thread listing, but direct lookup by ID still returned its turns. An
active agent-created comparison thread was also absent from the general listing
and remained directly readable. Listing or catalog absence is therefore not a
deletion signal. Finish must inspect both rollout roots and the state relation.

Deletion was not executed in this experiment, so it did not establish a final
deletion signal.

A later controlled delete of a user thread with three physical pages removed
all three rollouts, the canonical state row, all three history projections and
their turns/items, the session index entry and the local app catalog row. Global
state still retained permissions, description, binding, project/order and path
references. Its writing-block deleted flag had already been present while the
thread was live and is not a final-deletion tombstone. No durable catalog removal
record was found. The before-and-after operation establishes what the app
removed, but a later snapshot still has no unique standalone deletion marker.

The archive-listing failure was reproduced with a second agent-created thread.
Its rollout moved byte-identically to archived_sessions, state changed to
archived=1, history and the session index remained, the local catalog row was
absent, direct lookup still worked, and the archived list still returned no
entry. Both observed failures involved agent-created threads, but that does not
establish thread_source as the cause or prove that every such thread is hidden.

The installed app-server protocol exposed thread/delete with a single threadId
parameter. Calling that official request for the hidden archived branch returned
success and a thread/deleted notification. It removed the rollout, canonical
state row, history projection, turns/items and session index entry. Direct lookup
then failed. Eight global-state references remained, and no new unique deletion
tombstone was found. The deleted source_thread_id relationship disappeared with
the branch payload and history; this was an explicit delete of the branch, not a
cascade from deleting its source thread. Direct SQLite/WAL edits were not used.

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

### Targeted archive and restore observation (2026-09-03)

One projectless agent-created thread on backend 0.153.0-alpha.5 was archived and
unarchived twice through the Codex app. In each cycle its original bytes, history
and session-index records survived; the state path/archive flag changed, and the
desktop catalog row was removed then recreated. Direct lookup returned its
completed response after restoration. General/archived listing did not expose
this sample, so sidebar visibility and its cause remain unproven.

Unarchive was not an exact inverse: state updated_at/updated_at_ms and catalog
source_updated_at/observation_sequence differed after both cycles. The first
cycle also changed pending_observed_title and removed the unread-thread entry;
that unread entry was not restored. App-wide catalog revision also advanced.
These observations do not permit rewinding shared metadata or unrelated threads.

A separate synthetic, standalone app-server archive probe changed the payload
and state but did not maintain the desktop catalog. Do not conflate that call
path with the desktop app operation, which did maintain it. Neither probe proves
a closed-desktop normalisation or exact backup-based Cancel implementation.
Calling unarchive alone is not evidence that this Finish's writes were rolled
back. The root/app responsibility boundary is unchanged.

### Archive trigger definitions checked on 2026-09-05

The earlier private sweep counted five state_5.sqlite triggers without recording
their bodies. A read-only follow-up inspected these definitions:

- threads_created_at_ms_after_insert: after INSERT, fills a NULL created_at_ms.
- threads_updated_at_ms_after_insert: after INSERT, fills a NULL updated_at_ms.
- threads_recency_at_after_insert: after INSERT, fills zero recency_at_ms.
- threads_created_at_ms_after_update: after UPDATE OF created_at, updates its
  millisecond value only when the seconds changed and milliseconds did not.
- threads_updated_at_ms_after_update: the corresponding updated_at rule.

The Finish Archive and reverse statements update only rollout_path, archived and
archived_at. An isolated in-memory DB with the actual five trigger SQL bodies
confirmed no triggered writes for either statement and exact row restoration.
A positive control updating updated_at did fire its timestamp trigger.
This verifies these statements only, not app UI behaviour or unrelated writes.
The installed local_thread_catalog table had no triggers. Finish compares both
trigger name and whitespace-normalized SQL body; unrecognized/changed definitions
still stop before app writes with SURVEY_REQUIRED. Mere trigger presence is not
evidence of an unsupported Archive operation.

### Split gzip transport (tool format, not an app structure change)

When a gzip payload still exceeds the transport ceiling, Codex Finish/Start
package it as numbered .gz.part000001 byte slices and a .gz.parts.json descriptor.
No slice exceeds 95 MiB; a lower configured limit is also honored. No oversized
whole-gzip blob is published. The manifest transportPath points to the descriptor;
logical path, original length and SHA-256 do not change. Finish, Start and
Reactivate read the descriptor, verify the ordered slices, concatenate, verify
the gzip and finally verify the decompressed original before any app placement.
Local gzip markers bind the raw hash and all stored transport object IDs.
Unchanged verified transports are reused without repeated compression or
verification decompression; missing/changed markers trigger full validation.
Start only decompresses when verified/local original bytes are not available.
Existing raw and single-gzip payloads remain supported. See plan section 2.19
for the descriptor fields. This is a transport extension, not a new survey claim.

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
observed in the survey. The subsequent user-selected transport is 95 MiB,
gzip with integrity metadata, split gzip when necessary, and verified reuse
markers. See implementation plan section 2.19. This is a tool policy, not an
app storage fact inferred from the survey.

## 11. Not yet observed

- Historical app versions executed separately to establish introduction dates.
- A reliable final-deletion signal.
- Complete recovery of absent standalone parents and unresolved subagent references.
- Ownership of every unassigned attachment.
- Full generalisation of catalog/index reconstruction and rollback to other
  environments. Single-machine reconstruction and isolated rollback evidence
  now exist; the older archive/unarchive survey alone did not prove them.
- Cross-machine host, project, client and path mapping.
- Broader multi-machine rollback and transport behaviour. Isolated Finish
  rollback/repetition and the local operational sequence are recorded in the
  closeout; they do not establish all other machine configurations.
- End-to-end restore and continued conversation on a second machine.
- A newly created 0.153.1 user or agent-created canonical thread. The 2026-09-05
  direct 0.153.1 sample was guardian_review only.

A structure survey does not prove Finish/Start implementation or round-trip success.

The 2026-09-06 operational Start log also records backend 0.153.4 and desktop
package 26.901.6511.0. This is execution provenance, not a fresh full survey or
an extension of a version allowlist. The history restoration and deletion
corrections above are scoped evidence, not proof of every backend behaviour.

## 12. Structure change log

| Date | Version / comparison | Confirmed structure | Finish / Start impact |
|---|---|---|---|
| 2026-08-31 | Versions in section 1; initial baseline | Legacy, continuation, fork, guardian, placement and attachment relationships | Preserve related originals and distinguish identity layers; restoration remains unverified |
| 2026-09-01 | Codex 0.151.0-alpha.7.2 survey continued; deletion completed with app-server 0.152.0 | A third paginated page can reference the preceding physical page alias in history_base.thread_id; undo/retry can create another physical page with the same canonical ID and no history_base; archiving two agent-created threads moved each rollout byte-identically while neither appeared in archived listing; deleting a three-page source left a complete usable branch with embedded source_thread_id; an explicit thread/delete of that hidden branch removed its payload and primary projections but left global-state references; a per-thread writer lock was observed | Resolve physical predecessor aliases, preserve every physical original and surviving branch, retain source provenance without resurrecting a deleted source, inspect sessions and archived_sessions with state, require an actual unexplained broken relationship before classifying an orphan, and verify each byte/ordinal boundary; do not infer final deletion from list/catalog absence, stale global references or the writing-block flag, do not infer UI-listing causation from thread_source, and do not transport the empty lock as conversation payload |
| 2026-09-03 | 0.153.0-alpha.5, targeted sample only | One agent-created initial page includes token_usage_record; two app archive/unarchive cycles preserve raw bytes/history/index and remove/recreate the catalog, but change state/catalog timestamps and other app state | Keep standalone backend and desktop operation scopes distinct; unarchive alone is not exact Cancel; closed-desktop rollback and full-version compatibility remain unverified |
| 2026-09-05 | Desktop 26.901.4073.0, internal app 152.0.7977.64, installed backend 0.153.1; full sweep of 37 rollout files | The previously unlisted 0.152.0 user rollout is a valid third paginated page with a predecessor physical alias and verified byte/ordinal boundary. One 0.153.1 guardian_review rollout has the same selected first-meta shape as the 0.153.0-alpha.5 guardian sample. No new record type, required DB-column mismatch or deletion signal was found. | Add 0.152.0 and 0.153.1 to the surveyed rollout versions and use 0.153.1 as the target reconstruction backend. Session identity, lineage, archive and deletion rules do not change. |

This baseline came from one observed environment, not an execution comparison
against a prior app release. Add confirmed changes and corrections with evidence
in the matching private survey report.

References used in the original survey:
- [Codex App Server](https://learn.chatgpt.com/docs/app-server): thread behaviour, not a local DB restore guarantee.
- [GitHub file limits](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github).


### Unread reference receive clarification (2026-09-07)

The 2026-09-03 controlled archive observation already recorded a local unread
membership removal. The private 2026-09-07 published corpus contains one
/electron-persisted-atom-state/unread-thread-ids-by-host-v1/local/<index>
reference whose string value matches the session canonical ID. A missing receive
branch, not an unrecognized app version, caused Start to reject it.
The implementation treats this as local unread membership, never as transcript
lineage, a portable array slot, or deletion evidence. Target other-host entries
are retained. This clarification does not establish which UI event creates the
membership or claim that every app-version field has been surveyed.
