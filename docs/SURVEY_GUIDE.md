# Survey Guide

What a survey is, where it goes, what it must contain, and when a new one is
made. Applies to every agent this tool supports.

## 1. What a survey is

A **survey** is a dated record of what was actually measured on one machine at
one point in time: real identifiers, real paths, real sizes, real field
frequencies, and the raw evidence behind them.

It is not a design document and not a specification. It answers one question:

> On this machine, on this date, with these app versions, what did the storage
> actually look like?

## 2. Why it is split from the structure document

| | Structure document | Survey |
|---|---|---|
| Location | This repository, `docs/<AGENT>_SESSION_STRUCTURE.md` | Private Vault, `Surveys/<Agent>/<YYYY-MM-DD>.md` |
| Visibility | Public | Private |
| Content | Shapes, field names, relationships, synthetic examples | Real identifiers, paths, counts, sizes, hashes |
| Lifetime | Updated when the structure changes | Immutable once written; a new date makes a new file |
| Repeats per version | No | Yes, once per survey run |

The structure document describes the shape. The survey is the evidence that the
shape was observed. Publishing the evidence would publish the user's real
session identifiers and machine layout, so it stays in the Vault.

A claim in the structure document that no survey supports is not a fact. A
survey that restates the structure without measured values is not a survey.

## 3. Location and naming

```
<VaultRoot>/Surveys/<Agent>/<YYYY-MM-DD>.md
```

- `<Agent>` matches the agent registration key in the machine configuration,
  `Claude` or `Codex`.
- `<YYYY-MM-DD>` is the **baseline date**: the date the measurement was taken,
  not the date the file was written or edited. If a survey spans midnight, use
  the date the run started.
- One file per survey run. Never overwrite an earlier date.
- If two surveys are taken on the same date on different machines, append the
  machine name: `<YYYY-MM-DD>-<MACHINE>.md`.

The corresponding structure document is named:

```
docs/<AGENT>_SESSION_STRUCTURE.md
```

with `<AGENT>` upper case, for example `CLAUDE_SESSION_STRUCTURE.md`.

## 4. Required content

A survey must open with the baseline and then carry the measured values. The
following sections are required. Omit a section only by stating that it was not
measured and why.

### 4.1 Baseline

- Baseline date
- Machine name
- App version and engine version, exactly as reported by the system
- Install-scoped identifiers, if the agent has them
- Absolute storage roots as they exist on that machine

### 4.2 Scale

Counts and sizes: number of sessions, number of payload files, total bytes,
largest single payload, typical record size.

### 4.3 Field frequencies

For every record type with a variable shape, the observed field list with
counts, in the form `<field> N/M`. This is what proves which fields are
optional. The structure document may only say "present in every sampled record"
or "optional"; the numbers live here.

### 4.4 Lineage and linkage

Real identifier chains as observed, so that a later run can confirm the linkage
rules still hold.

### 4.5 Signals

Deletion, archival, release or any other state transition observed during the
survey. Record the exact bytes, timestamps and file names, not a paraphrase.

### 4.6 Incidents

Anything that went wrong during or because of the survey: data lost,
misclassification, a tool that corrupted what it read. State the cause. An
incident that is not recorded will be repeated.

### 4.7 Open items

What could not be determined, and what the next survey should look for. These
become the "Not yet observed" list in the structure document.

## 5. Evidence rules

- Record what was observed, not what it implies. `mtime was newer` is an
  observation; `it overwrites the other file` is a conclusion and needs its own
  evidence.
- State the sample size next to any frequency or ratio.
- Quote exact bytes for small binary or opaque payloads, in hex and in text.
- Do not round away the units of a measurement.
- If a value was read through a tool that may have altered it, say so.

## 6. When a new survey is made

Two triggers:

1. An app or engine version listed in the structure document changes.
2. Start or Finish encounters data that does not match the structure document.

On either trigger the tool **reports the difference and states that a survey is
needed**. It does not survey by itself and does not convert formats by itself.

A survey is a full sweep, not a diff of the changed area, and it runs only when
the user asks for one.

After a survey:

- The measured evidence goes to a new dated file in the Vault.
- Only a confirmed structural change is then written into the public structure
  document, together with a new row in its version table.
- The previous version row stays, so the difference between versions remains
  readable.

## 7. Cross-reference

Each structure document names the survey it was derived from. Each survey names
the structure document it supports. When they disagree, the survey is the
evidence and the structure document is corrected.


## 8. Artifact format and common structure layout

Guide baseline: 2026-08-31. A private survey artifact is a UTF-8 Markdown report,
not an executable input or a runtime JSON schema. Public structure documents use
English ASCII. Existing private reports may keep their detailed sections when an
opening metadata block maps them to the required content above. Missing
measurements must be identified as not measured, never filled with guessed values.
A structure survey is not proof of a consistent backup or a successful restore.

Record observation start/end and timezone as well as the baseline date. Distinguish
the documentation date from the observation date. For another run on the same
machine and date, append the local start time to avoid a collision:
YYYY-MM-DD-MACHINE-HHMMSS.md. Keep earlier measured evidence; append dated
corrections instead of silently replacing an observation with a later one.
Survey files must be committed and pushed to the private Vault to be shared;
placing a file there alone does not publish it.

Both docs/<AGENT>_SESSION_STRUCTURE.md files use these sections:

1. Observed versions (including re-survey triggers)
2. Storage layers
3. Identifiers
4. Lineage / continuation
5. Example compositions
6. Record fields
7. Deletion signal
8. Placement
9. Portability
10. Transport
11. Not yet observed
12. Structure change log

Keep an unmeasured section and state what remains unknown; do not invent facts
to make the two applications look identical. The initial change-log row is a
baseline, not an assumed change from an unmeasured older release.

On a version/structure mismatch, completion is valid only if originals and the
required work remain verifiable; report the difference and survey request too.
If lineage, deletion targets or restoration integrity cannot be established,
report Failure and the survey request. The documentation of this behaviour
does not establish that runtime detection has been implemented.
