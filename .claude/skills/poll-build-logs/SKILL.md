---
name: poll-build-logs
description: Polls for CI build log branches matching changes from the current session. Use after pushing code to monitor build results automatically. Keeps the web session active while waiting for CI to complete, then fetches and analyzes the build logs when they appear.
---

# Poll Build Logs

## Instructions

After pushing code changes, use this process to monitor for CI build results and analyze them when available.

### Step 1: Identify the Commit

Determine the commit SHA that was pushed. Use the most recent commit on the current branch:

```bash
git rev-parse HEAD
```

Also note the branch name for correlation:

```bash
git branch --show-current
```

### Step 2: Start Background Polling

Launch the polling script as a **background task** so the session stays active while waiting:

```bash
./Scripts/poll-build-logs.sh <commit_sha> --interval 60 --delay 180 --timeout 2700
```

**IMPORTANT:** Use `run_in_background: true` when calling the Bash tool. This is what keeps the Claude Code web session alive during the wait.

#### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--delay` | 180s (3 min) | Initial wait before first poll. iOS CI needs at least a few minutes to start producing results. |
| `--interval` | 60s | Time between polls. `git ls-remote` is lightweight, so 60s is a good balance. |
| `--timeout` | 2700s (45 min) | Maximum wait. Covers typical iOS CI builds (15-40 min) with margin. |

#### Tuning for different scenarios

- **Quick lint/compile check**: `--delay 60 --interval 30 --timeout 600`
- **Full test suite**: `--delay 180 --interval 60 --timeout 2700` (default)
- **Known slow build**: `--delay 300 --interval 90 --timeout 3600`

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
2. Records commit SHA: abc1234def
3. Starts background polling:
   ./Scripts/poll-build-logs.sh abc1234def --interval 60 --delay 180 --timeout 2700
4. [Background task runs, session stays active]
5. [~20 minutes later, task completes with match]
6. Reports: "CI build passed for commit abc1234. Build log: build-logs/142-123456-20260221T150000Z-pass"
```

## Important Notes

- The script uses `git ls-remote` which only fetches ref names — it is very lightweight and safe to run frequently.
- The background task **keeps the web session alive**. Without it, the session may time out before CI completes.
- Only the 10 most recent build-log branches are retained by CI, so poll promptly after pushing.
- If multiple pushes happen in quick succession, the script matches on commit SHA, so it will find the correct build.
