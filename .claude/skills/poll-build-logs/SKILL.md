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

iOS CI builds typically take **15-30 minutes**. Use a repeating check pattern:

1. **Wait 1 minute** using a background sleep to keep the session alive:
   ```bash
   sleep 60 && git ls-remote --heads origin 'refs/heads/build-logs/*'
   ```
   Run this with `run_in_background: true`.

2. When the background task completes, **read the output** and check for new branches (run numbers higher than the snapshot).

3. If no new branches yet, **repeat step 1** — launch another background sleep+check.

4. If a new branch appeared, proceed to Step 4.

5. **Give up after ~45 minutes** of checking (roughly 45 cycles).

**Why short-lived background tasks:** The Claude Code web platform kills long-running background processes (~8-10 min). A 60-second sleep+check completes well within this limit.

### Step 4: Fetch and Analyze the Build Log

When a new build-log branch appears with a run number higher than your snapshot:

```bash
git fetch origin build-logs/<new-branch>
git show origin/build-logs/<new-branch>:build-summary.md
```

**Verify it matches** your branch by checking the `Branch` or `PR` field in build-summary.md. For PR builds, match on **branch name** (not commit SHA, since CI uses a merge commit).

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

```
User: Push my changes and let me know if the build passes.

Claude:
1. Commits and pushes to the PR branch
2. Records: BRANCH=claude/my-feature, latest run=150
3. Launches: sleep 60 && git ls-remote ... (background)
4. [1 minute later, checks output — no new branches]
5. Repeats sleep 60 && git ls-remote ... cycles
6. [~20 minutes later — new branch: build-logs/151-...-pass!]
7. Fetches build-summary.md, confirms Branch matches
8. Reports: "CI build passed on branch claude/my-feature.
   Build log: build-logs/151-123456-20260221T150000Z-pass"
```

## Important Notes

- `git ls-remote` only fetches ref names — very lightweight, safe to run every minute.
- Only the 10 most recent build-log branches are retained by CI, so poll promptly after pushing.
- The `Branch` field in build-summary.md is only present for `pull_request` events (not `push` events to dev/main).
