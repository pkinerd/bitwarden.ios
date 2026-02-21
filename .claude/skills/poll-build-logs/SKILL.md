---
name: poll-build-logs
description: Polls for CI build log branches matching changes from the current session. Use after pushing code to monitor build results automatically. Keeps the web session active while waiting for CI to complete, then fetches and analyzes the build logs when they appear.
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

### Step 2: Start Background Polling

Launch the polling script as a **background task** so the session stays active while waiting:

```bash
./Scripts/poll-build-logs.sh <commit_sha> --branch <branch_name>
```

**IMPORTANT:** Always pass `--branch` with the current branch name. Use `run_in_background: true` when calling the Bash tool — this keeps the Claude Code web session alive during the wait.

#### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--branch` | _(none)_ | **Recommended.** Branch name to match in build-summary.md. Essential for PR builds where the CI commit SHA differs from branch HEAD. |
| `--delay` | 60s (1 min) | Initial wait before first poll. Gives CI a moment to start before checking. |
| `--interval` | 60s | Time between polls. `git ls-remote` is lightweight, so 60s is a good balance. |
| `--timeout` | 2700s (45 min) | Maximum wait. Covers typical iOS CI builds (15-40 min) with margin. |

#### Tuning for different scenarios

- **Quick lint/compile check**: `--delay 30 --interval 30 --timeout 600`
- **Full test suite**: `--delay 60 --interval 60 --timeout 2700` (default)
- **Known slow build**: `--delay 120 --interval 90 --timeout 3600`

### Step 3: Monitor Progress

The background task writes to an output file. Check progress periodically:

```bash
tail -20 <output_file>
```

You do **not** need to check constantly — you will be notified when the background task completes.

### Step 4: Analyze Results

When the polling script finds a matching build-log branch, it outputs:
- The branch name
- The build result (pass/fail)
- The full `build-summary.md` content
- For failures: error lines from `test.log`

#### On success (pass)

Report to the user that the build passed. Optionally fetch full logs for details:

```bash
git fetch origin <build-log-branch>
git show origin/<build-log-branch>:build-summary.md
```

#### On failure (fail)

1. Fetch the full test log:
   ```bash
   git fetch origin <build-log-branch>
   git show origin/<build-log-branch>:test.log
   ```

2. Search for specific failures:
   ```bash
   git show origin/<build-log-branch>:test.log | grep '✖︎\|error:'
   ```

3. Analyze the failures and determine if they are related to the session's changes.

4. If failures are related to the session's changes, fix them, commit, push, and restart polling.

#### On timeout

If no matching build-log branch appeared within the timeout:

1. Check if the CI workflow was triggered:
   ```bash
   git ls-remote --heads origin 'refs/heads/build-logs/*'
   ```

2. The build may still be running — the user can restart polling with a longer timeout or check manually.

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
2. Records commit SHA and branch name:
   SHA=abc1234def  BRANCH=claude/my-feature-branch
3. Starts background polling:
   ./Scripts/poll-build-logs.sh abc1234def --branch claude/my-feature-branch
4. [Background task runs, session stays active]
5. [~20 minutes later, task completes with match]
6. Reports: "CI build passed on branch claude/my-feature-branch.
   Build log: build-logs/142-123456-20260221T150000Z-pass"
```

## Important Notes

- The script matches on **commit SHA or branch name** — this handles both `push` events (exact SHA) and `pull_request` events (merge commit SHA differs from branch HEAD).
- The script uses `git ls-remote` which only fetches ref names — very lightweight and safe to run frequently.
- The background task **keeps the web session alive**. Without it, the session may time out before CI completes.
- Only the 10 most recent build-log branches are retained by CI, so poll promptly after pushing.
