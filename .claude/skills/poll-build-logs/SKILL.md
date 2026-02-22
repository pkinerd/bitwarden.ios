---
name: poll-build-logs
description: Polls for CI build log branches matching changes from the current session. Use after pushing code to monitor build results automatically. Checks periodically for build logs, then fetches and analyzes them when they appear.
---

# Poll Build Logs

## Instructions

After pushing code changes, use this process to monitor for CI build results and analyze them when available.

### Step 1: Identify the Branch

Note the current branch name for matching later:

```bash
git branch --show-current
```

### Step 2: Snapshot Existing Branches

Record the current build-log branches so you can detect new ones:

```bash
git ls-remote --heads origin 'refs/heads/build-logs/*'
```

Note the highest run number (e.g., `build-logs/150-...`).

### Step 3: Wait and Check Periodically

iOS CI builds typically take **15-30 minutes**, but builds with early errors can fail in under 5 minutes. Use a repeating check pattern:

1. **Launch ONE background task** to sleep and then check:
   ```bash
   sleep 180 && git ls-remote --heads origin 'refs/heads/build-logs/*'
   ```
   Run this with `run_in_background: true`.

2. **STOP and WAIT for the `task-notification`** that signals the background task completed. Do NOT read the output file, do NOT launch another cycle, and do NOT send any message to the user until you receive the `task-notification` for this specific task ID. The sleep takes 3 minutes — you must wait the full duration.

3. **Only after receiving the `task-notification`**, read the output file and check for new branches (run numbers higher than the snapshot).

4. If no new branches yet, **go back to step 1** — launch another single background sleep+check.

5. If new branches appeared, proceed to Step 4.

6. **Give up after ~45 minutes** of checking (roughly 15 cycles).

**CRITICAL — One task at a time:** Launch exactly ONE background task per cycle. After launching it, you MUST wait for its `task-notification` before doing anything else related to polling. Do NOT:
- Read the output file immediately after launching (it will be empty — the task is still sleeping)
- Launch multiple background tasks in rapid succession
- Try to "check" on the task before it completes

**Why short-lived background tasks:** The Claude Code web platform kills long-running background processes (~8-10 min). A 3-minute sleep+check completes well within this limit.

**Silence between polls:** Do NOT send a message to the user for each intermediate check. Only notify the user when a matching build result is found or when giving up after timeout. Between polls, continue working on other tasks if available, or remain silent.

**No duplicate polling:** Do NOT invoke this skill if polling is already in progress. Before starting, check whether there are active background poll tasks from a previous invocation. Only one polling loop should be active at a time.

### Step 4: Fetch and Analyze the Build Log

When a new build-log branch appears with a run number higher than your snapshot:

```bash
git fetch origin build-logs/<new-branch>
git show origin/build-logs/<new-branch>:build-summary.md
```

**Verify it matches** your branch by checking the `Branch` or `PR` field in build-summary.md. For PR builds, match on **branch name** (not commit SHA, since CI uses a merge commit).

**If multiple new branches appeared** since your last check, pick the one with the highest run number that matches your branch.

**If the new branch does not match** your branch (i.e., it belongs to a different PR or push), ignore it and continue polling — another PR's build completing should not terminate your poll loop.

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
2. Records: BRANCH=claude/my-feature, latest run=150
3. Launches ONE background task: sleep 180 && git ls-remote ...
4. STOPS and WAITS — does nothing until task-notification arrives
5. [3 min later] Receives task-notification, reads output — no new branches
6. Launches another ONE background task, WAITS again
7. [repeats silently for several cycles]
8. [~18 min later] Receives task-notification — new branch: build-logs/151-...-pass!
9. Fetches build-summary.md, confirms Branch matches
10. Reports: "CI build passed on branch claude/my-feature."
```

### Non-matching branch (another PR's build)

```
Claude:
1. Polling for BRANCH=claude/my-feature, latest run=150
2. [6 min later] Receives task-notification — new branch: build-logs/151-...-fail
3. Fetches build-summary.md, sees Branch=claude/other-pr — no match
4. Ignores it, launches next background task, WAITS
5. [15 min later] Receives task-notification — new branch: build-logs/152-...-pass
6. Fetches build-summary.md, sees Branch=claude/my-feature — match!
7. Reports result to user
```

## Important Notes

- `git ls-remote` only fetches ref names — very lightweight, safe to run frequently.
- Only the 10 most recent build-log branches are retained by CI, so poll promptly after pushing.
- The `Branch` field in build-summary.md is only present for `pull_request` events (not `push` events to dev/main).
