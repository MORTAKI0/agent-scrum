# agent-scrum v1

`agent-scrum` v1 is a local Codex-driven run workflow that takes one user story, creates one run folder, executes one implementation/review cycle with retries, and records one append-only log entry for that run.

## Scope

v1 does:

- create or use a run at `workspace/runs/<RUN_ID>/`
- store the story in `workspace/runs/<RUN_ID>/user-story.md`
- write the plan to `workspace/runs/<RUN_ID>/PLAN.md`
- implement the planned changes
- generate `workspace/runs/<RUN_ID>/changed-files.txt` after implementation
- run `npm test`
- store `npm test` output in `workspace/runs/<RUN_ID>/validation-output.txt`
- use `workspace/runs/<RUN_ID>/FIX-NOTES.md` for retry attempts
- write `workspace/runs/<RUN_ID>/REVIEW.md` on success
- write `workspace/runs/<RUN_ID>/FAILURE-REPORT.md` on final failure
- store run metadata in `workspace/runs/<RUN_ID>/run-meta.env`
- store the most recent run id in `workspace/latest-run.txt`
- append exactly one entry per run to `story-log.md`

v1 does not:

- push commits
- deploy anything
- open pull requests
- send Telegram messages
- define or use any v2 workflow in the main operating flow

## Run Contract

Each run uses exactly one active run directory:

```text
workspace/runs/<RUN_ID>/
```

The active run directory contains the run artifacts for that run. The required artifact locations are:

```text
workspace/latest-run.txt
workspace/runs/<RUN_ID>/run-meta.env
workspace/runs/<RUN_ID>/user-story.md
workspace/runs/<RUN_ID>/PLAN.md
workspace/runs/<RUN_ID>/changed-files.txt
workspace/runs/<RUN_ID>/validation-output.txt
workspace/runs/<RUN_ID>/FIX-NOTES.md
workspace/runs/<RUN_ID>/REVIEW.md
workspace/runs/<RUN_ID>/FAILURE-REPORT.md
story-log.md
```

Rules:

- `user-story.md` is stored inside the active run folder.
- `PLAN.md` must be written inside the active run folder.
- `PLAN.md` must never be written at `workspace/runs/PLAN.md`.
- `changed-files.txt` must be generated after implementation.
- `validation-output.txt` must store the output from `npm test`.
- `FIX-NOTES.md` must be used for retry attempts.
- `REVIEW.md` is the success artifact.
- `FAILURE-REPORT.md` is the final failure artifact.
- `run-meta.env` stores run metadata.
- `workspace/latest-run.txt` stores the most recent run id.
- `story-log.md` gets one append-only entry per run.

## Artifact Flow

The v1 artifact flow is exact:

```text
story
-> workspace/runs/<RUN_ID>/user-story.md
-> workspace/runs/<RUN_ID>/PLAN.md
-> implementation
-> workspace/runs/<RUN_ID>/changed-files.txt
-> npm test
-> workspace/runs/<RUN_ID>/validation-output.txt
-> retry via workspace/runs/<RUN_ID>/FIX-NOTES.md
-> workspace/runs/<RUN_ID>/REVIEW.md or workspace/runs/<RUN_ID>/FAILURE-REPORT.md
-> story-log.md
```

## Success Path

The success path is:

1. Create or select `workspace/runs/<RUN_ID>/`.
2. Write the story to `workspace/runs/<RUN_ID>/user-story.md`.
3. Write the plan to `workspace/runs/<RUN_ID>/PLAN.md`.
4. Implement the planned changes.
5. Generate `workspace/runs/<RUN_ID>/changed-files.txt`.
6. Run `npm test`.
7. Write test output to `workspace/runs/<RUN_ID>/validation-output.txt`.
8. Write `workspace/runs/<RUN_ID>/REVIEW.md`.
9. Append one entry to `story-log.md`.

`REVIEW.md` is the terminal success artifact for the run.

## Failure Path

The failure path is:

1. Create or select `workspace/runs/<RUN_ID>/`.
2. Write the story to `workspace/runs/<RUN_ID>/user-story.md`.
3. Write the plan to `workspace/runs/<RUN_ID>/PLAN.md`.
4. Implement the planned changes.
5. Generate `workspace/runs/<RUN_ID>/changed-files.txt`.
6. Run `npm test`.
7. Write test output to `workspace/runs/<RUN_ID>/validation-output.txt`.
8. If the run cannot be recovered within the retry loop, write `workspace/runs/<RUN_ID>/FAILURE-REPORT.md`.
9. Append one entry to `story-log.md`.

`FAILURE-REPORT.md` is the terminal failure artifact for the run.

## Retry Loop

The retry loop is:

1. A run fails validation or review.
2. Write or update `workspace/runs/<RUN_ID>/FIX-NOTES.md`.
3. Retry implementation using `FIX-NOTES.md`.
4. Regenerate `changed-files.txt` after the retry implementation.
5. Run `npm test` again.
6. Overwrite or refresh `validation-output.txt` with the latest `npm test` output.
7. End with `REVIEW.md` on success or `FAILURE-REPORT.md` on final failure.

`FIX-NOTES.md` exists only to drive retry attempts inside the same run.

## Command Usage

v1 is operated through the local shell entrypoint:

```bash
./agent-scrum.sh "<story text>"
```

Or:

```bash
./agent-scrum.sh /path/to/story.txt
```

The command must:

- resolve or create a `RUN_ID`
- write `workspace/latest-run.txt`
- create `workspace/runs/<RUN_ID>/`
- write `run-meta.env`
- write `user-story.md`
- execute the v1 artifact flow exactly as defined above

## Assumptions

v1 assumes:

- Codex is available locally and can be invoked by the shell workflow.
- `git` is installed and the repository is already present locally.
- Node.js is installed.
- `npm` is installed.
- `npm test` is the required validation command.
- the workflow runs locally in the checked-out repository.

## Non-Goals

v1 does not:

- push branches or commits to a remote
- deploy builds or services
- open pull requests
- post to Telegram
- add v2 behavior to the main operating flow
