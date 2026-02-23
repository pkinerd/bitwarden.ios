---
name: poll-build-logs
description: Polls for CI build log branches matching changes from the current session. Use after pushing code to monitor build results automatically. Checks periodically for build logs, then fetches and analyzes them when they appear.
---

# Poll Build Logs

## Instructions

After pushing code changes, use this process to monitor for CI build results and analyze them when available.

### Step 1: Identify the Branch and Commit

Note the current branch name and HEAD commit SHA for matching later:

```bash
git branch --show-current
git rev-parse HEAD
```

Record both values — `BRANCH` and `HEAD_SHA`. The branch is used for initial matching, and the commit SHA is used to verify the build covers the current code (not a stale push).

### Step 2: Snapshot Existing Branches and Check for Existing Match

Record the current build-log branches:

```bash
git ls-remote --heads origin 'refs/heads/build-logs/*'
```

Note the highest run number (e.g., `build-logs/150-...`).

**Before polling, check if the most recent build-log branch already matches the current branch and commit.** Fetch the branch with the highest run number and verify it matches using the process described in Step 4 (branch name AND commit SHA). If it matches, **skip polling entirely** and proceed directly to reporting the result.

This handles the common case where CI has already completed before polling starts — for example, when resuming a session where a previous push already triggered and completed a build.

### Step 3: Wait and Check Periodically

iOS CI builds typically take **15-30 minutes**, but builds with early errors can fail in under 5 minutes. Use a repeating check pattern with **60-second intervals for 45 cycles** (~45 minutes total):

1. **Launch ONE background task** to sleep and then check:
   ```bash
   sleep 60 && git ls-remote --heads origin 'refs/heads/build-logs/*'
   ```
   Run this with `run_in_background: true`.

2. **STOP and WAIT for the `task-notification`** that signals the background task completed. Do NOT read the output file, do NOT launch another cycle, and do NOT send any message to the user until you receive the `task-notification` for this specific task ID. The sleep takes 60 seconds — you must wait the full duration.

3. **Only after receiving the `task-notification`**, read the output file and check for new branches (run numbers higher than the snapshot).

4. If no new branches yet, **go back to step 1** — launch another single background sleep+check.

5. If new branches appeared, proceed to Step 4.

6. **Give up after 45 cycles** (~45 minutes of checking). You MUST run all 45 cycles before giving up — do NOT stop early.

**CRITICAL — One task at a time:** Launch exactly ONE background task per cycle. After launching it, you MUST wait for its `task-notification` before doing anything else related to polling. Do NOT:
- Read the output file immediately after launching (it will be empty — the task is still sleeping)
- Launch multiple background tasks in rapid succession
- Try to "check" on the task before it completes

**CRITICAL — Run all 45 cycles:** You MUST keep polling for the full 45 cycles before giving up. Track your cycle count (e.g., "Poll cycle 7/45"). Do NOT give up early because "no changes were detected" — CI builds take 15-30 minutes, so it is normal to see no new branches for many cycles.

**Why 60-second intervals:** The Claude Code web platform requires background tasks to complete within 90 seconds. A 60-second sleep+check completes well within this limit while providing frequent updates.

**Silence between polls:** Do NOT send a message to the user for each intermediate check. Only notify the user when a matching build result is found or when giving up after timeout. Between polls, continue working on other tasks if available, or remain silent.

**No duplicate polling:** Do NOT invoke this skill if polling is already in progress. Before starting, check whether there are active background poll tasks from a previous invocation. Only one polling loop should be active at a time.

### Step 4: Fetch and Analyze the Build Log

When a build-log branch is found (either pre-existing from Step 2 or newly appeared during polling):

```bash
git fetch origin build-logs/<branch>
git show origin/build-logs/<branch>:build-summary.md
```

**Verify it matches** using two checks:

1. **Branch match**: Check the `Branch` or `PR` field in build-summary.md matches the current branch name.
2. **Commit match**: Extract the `head_sha` from `jobs.json` to verify the build was triggered by the current HEAD commit:
   ```bash
   git show origin/build-logs/<branch>:jobs.json | python3 -c "import sys,json; print(json.load(sys.stdin)['jobs'][0]['head_sha'])"
   ```
   Compare this value against `HEAD_SHA` recorded in Step 1. The `head_sha` in `jobs.json` is the actual branch HEAD commit (not the merge commit shown in build-summary.md), so it can be compared directly with `git rev-parse HEAD`.

**Both checks must pass.** If the branch matches but the commit does not, the build is stale (from a previous push) — ignore it and continue polling for a newer build.

**If multiple new branches appeared** since your last check, pick the one with the highest run number that matches both branch and commit.

**If the new branch does not match** your branch or commit, ignore it and continue polling — another PR's build or a stale build should not terminate your poll loop.

#### On success (pass)

Report to the user that the build passed.

#### On failure (fail)

1. Fetch the full test log:
   ```bash
   git show origin/build-logs/<new-branch>:test.log | grep '✖︎\|error:'
   ```

2. Analyze the failures and determine if they are related to the session's changes.

3. If failures are related, fix them, commit, push, and restart polling from Step 1.

### Step 5: Report to User

Provide a clear summary:
- **Pass**: "CI build passed for commit `<sha>` on branch `<branch>`."
- **Fail**: Include the specific errors/test failures and whether they relate to session changes.
- **Timeout**: Explain that CI hasn't completed yet and suggest next steps.

## Example Flow

### Happy path

```
User: Push my changes and let me know if the build passes.

Claude:
1. Commits and pushes to the PR branch
2. Records: BRANCH=claude/my-feature, HEAD_SHA=abc1234, latest run=150
3. Checks run 150 — branch doesn't match, proceeds to polling
4. Launches ONE background task: sleep 60 && git ls-remote ...
5. STOPS and WAITS — does nothing until task-notification arrives
6. [1 min later] Receives task-notification (cycle 1/45), reads output — no new branches
7. Launches another ONE background task, WAITS again
8. [repeats silently for many cycles — this is normal]
9. [~20 min later, cycle 20/45] Receives task-notification — new branch: build-logs/151-...-pass!
10. Fetches build-summary.md — Branch matches. Checks jobs.json head_sha — matches abc1234.
11. Reports: "CI build passed for commit abc1234 on branch claude/my-feature."
```

### Non-matching branch (another PR's build)

```
Claude:
1. Polling for BRANCH=claude/my-feature, latest run=150
2. [5 min later, cycle 5/45] Receives task-notification — new branch: build-logs/151-...-fail
3. Fetches build-summary.md, sees Branch=claude/other-pr — no match
4. Ignores it, launches next background task, WAITS
5. [18 min later, cycle 18/45] Receives task-notification — new branch: build-logs/152-...-pass
6. Fetches build-summary.md, sees Branch=claude/my-feature — match!
7. Reports result to user
```

### Existing build already matches (resumed session)

```
User: [Resumes session] Poll for build logs.

Claude:
1. Records: BRANCH=claude/my-feature, HEAD_SHA=abc1234
2. Snapshots existing branches — highest is build-logs/177-...-pass
3. Fetches build-summary.md for run 177, sees Branch=claude/my-feature — branch matches
4. Checks jobs.json head_sha for run 177 — abc1234 — commit matches!
5. Skips polling entirely, reports: "CI build already passed for commit abc1234 on branch claude/my-feature (run #177)."
```

### Stale build (new commits pushed after previous build)

```
User: [Resumes session, pushes new commit] Poll for build logs.

Claude:
1. Records: BRANCH=claude/my-feature, HEAD_SHA=def5678
2. Snapshots existing branches — highest is build-logs/177-...-pass
3. Fetches build-summary.md for run 177, sees Branch=claude/my-feature — branch matches
4. Checks jobs.json head_sha for run 177 — abc1234 — does NOT match def5678
5. Build is stale, proceeds to polling loop for a newer build
6. [~20 min later] New branch: build-logs/178-...-pass
7. Verifies branch AND commit match — reports result
```

## Important Notes

- `git ls-remote` only fetches ref names — very lightweight, safe to run frequently.
- Only the 10 most recent build-log branches are retained by CI, so poll promptly after pushing.
- The `Branch` field in build-summary.md is only present for `pull_request` events (not `push` events to dev/main).
