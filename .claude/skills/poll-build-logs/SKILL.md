---
name: poll-build-logs
description: Polls for CI build log branches matching changes from the current session. Use after pushing code to monitor build results automatically. Checks periodically for build logs, then fetches and analyzes them when they appear.
---

# Poll Build Logs

## Instructions

After pushing code changes, use this process to monitor for CI build results and analyze them when available.

### Step 1: Identify the Commit and Branch

Determine the commit SHA and branch name:

```bash
git rev-parse HEAD
git branch --show-current
```

**Both are needed.** For `pull_request` CI events, GitHub records a merge commit SHA (not the branch HEAD), so matching on branch name is essential.

### Step 2: Snapshot Existing Branches

Before waiting, record the current build-log branches so you can detect new ones:

```bash
git ls-remote --heads origin 'refs/heads/build-logs/*'
```

Note the highest run number (e.g., `build-logs/150-...`).

### Step 3: Wait and Check Periodically

iOS CI builds typically take **15-30 minutes**. Use a repeating check pattern:

1. **Wait 5 minutes** using a background sleep to keep the session alive:
   ```bash
   sleep 300 && git ls-remote --heads origin 'refs/heads/build-logs/*'
   ```
   Run this with `run_in_background: true`.

2. When the background task completes, **read the output** and check for new branches (run numbers higher than the snapshot).

3. If no new branches yet, **repeat step 1** — launch another background sleep+check.

4. If a new branch appeared, proceed to Step 4.

5. **Give up after ~45 minutes** of checking (roughly 9 cycles).

**Why this approach:** Long-running background scripts (like the poll-build-logs.sh script) can be killed by the Claude Code web platform. Short-lived background tasks (sleep + single check) are more reliable because each completes within the platform's timeout window.

#### Alternative: Use the polling script locally

The `Scripts/poll-build-logs.sh` script works well in local/terminal Claude Code sessions where background processes are not killed:

```bash
./Scripts/poll-build-logs.sh <commit_sha> --branch <branch_name>
```

### Step 4: Fetch and Analyze the Build Log

When a new build-log branch appears with a run number higher than your snapshot:

```bash
git fetch origin build-logs/<new-branch>
git show origin/build-logs/<new-branch>:build-summary.md
```

**Verify it matches** your branch by checking the `Branch` or `PR` field in build-summary.md.

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
2. Records: SHA=abc1234, BRANCH=claude/my-feature, latest run=150
3. Launches: sleep 300 && git ls-remote ... (background)
4. [5 minutes later, checks output — no new branches]
5. Launches another sleep 300 && git ls-remote ... (background)
6. [5 more minutes — still nothing]
7. Launches another sleep 300 && git ls-remote ... (background)
8. [5 more minutes — new branch: build-logs/151-...-pass!]
9. Fetches build-summary.md, confirms Branch matches
10. Reports: "CI build passed on branch claude/my-feature.
    Build log: build-logs/151-123456-20260221T150000Z-pass"
```

## Important Notes

- `git ls-remote` only fetches ref names — very lightweight and safe to run frequently.
- For web sessions, prefer the **sleep + check pattern** over long-running scripts, as the platform may kill long background processes.
- For local/terminal sessions, the `Scripts/poll-build-logs.sh` script with `--branch` works reliably.
- Only the 10 most recent build-log branches are retained by CI, so poll promptly after pushing.
- The build-summary.md `Branch` field is only present for `pull_request` events (not `push` events to dev/main).
