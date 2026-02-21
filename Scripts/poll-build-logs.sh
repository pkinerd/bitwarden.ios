#!/usr/bin/env bash
# poll-build-logs.sh — Poll for CI build-log branches matching a commit or branch.
#
# Usage:
#   ./Scripts/poll-build-logs.sh <commit_sha> [--branch <name>] [--interval <s>] [--delay <s>] [--timeout <s>]
#
# Arguments:
#   commit_sha       The full or short commit SHA to look for in build logs.
#
# Options:
#   --branch <name>  Also match on this branch name in build-summary.md (recommended
#                    for PRs, where the CI commit SHA is a merge commit, not the HEAD).
#   --interval <s>   Seconds between polls (default: 60)
#   --delay <s>      Initial delay before first poll (default: 60)
#   --timeout <s>    Maximum total wait time in seconds (default: 2700 = 45 min)
#
# Matching:
#   The script matches if build-summary.md contains the commit SHA OR the branch name.
#   For pull_request events, GitHub CI records a merge commit SHA (not the branch HEAD),
#   so matching on branch name is essential for PR builds.
#
# Output:
#   Prints status lines prefixed with [poll] for progress.
#   On match, prints the matching branch name and fetches + displays
#   the build-summary.md content. Exits 0 on match, 1 on timeout.
#
# Example:
#   ./Scripts/poll-build-logs.sh abc1234 --branch claude/my-feature-branch
#   ./Scripts/poll-build-logs.sh abc1234 --branch claude/my-feature-branch --interval 60 --delay 60 --timeout 2700

set -euo pipefail

# --- Parse arguments ---

if [ $# -lt 1 ]; then
    echo "Usage: $0 <commit_sha> [--branch <name>] [--interval <s>] [--delay <s>] [--timeout <s>]"
    exit 2
fi

COMMIT_SHA="$1"
shift

POLL_INTERVAL=60
INITIAL_DELAY=60
MAX_TIMEOUT=2700
MATCH_BRANCH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --interval) POLL_INTERVAL="$2"; shift 2 ;;
        --delay)    INITIAL_DELAY="$2"; shift 2 ;;
        --timeout)  MAX_TIMEOUT="$2"; shift 2 ;;
        --branch)   MATCH_BRANCH="$2"; shift 2 ;;
        *)          echo "Unknown option: $1"; exit 2 ;;
    esac
done

# --- Snapshot existing build-log branches ---

echo "[poll] Watching for build logs matching commit: ${COMMIT_SHA}"
if [ -n "$MATCH_BRANCH" ]; then
    echo "[poll] Also matching on branch: ${MATCH_BRANCH}"
fi
echo "[poll] Config: initial_delay=${INITIAL_DELAY}s, interval=${POLL_INTERVAL}s, timeout=${MAX_TIMEOUT}s"

KNOWN_BRANCHES=$(git ls-remote --heads origin 'refs/heads/build-logs/*' 2>/dev/null \
    | awk '{print $2}' | sed 's|refs/heads/||' | sort)

echo "[poll] Snapshot: $(echo "$KNOWN_BRANCHES" | grep -c . || echo 0) existing build-log branch(es)"

# --- Initial delay ---

if [ "$INITIAL_DELAY" -gt 0 ]; then
    echo "[poll] Waiting ${INITIAL_DELAY}s before first poll..."
    sleep "$INITIAL_DELAY"
fi

# --- Poll loop ---

ELAPSED=$INITIAL_DELAY

while [ "$ELAPSED" -lt "$MAX_TIMEOUT" ]; do
    echo "[poll] Polling... (elapsed: ${ELAPSED}s / ${MAX_TIMEOUT}s)"

    CURRENT_BRANCHES=$(git ls-remote --heads origin 'refs/heads/build-logs/*' 2>/dev/null \
        | awk '{print $2}' | sed 's|refs/heads/||' | sort)

    # Find new branches not in the snapshot
    NEW_BRANCHES=$(comm -13 <(echo "$KNOWN_BRANCHES") <(echo "$CURRENT_BRANCHES"))

    if [ -n "$NEW_BRANCHES" ]; then
        echo "[poll] Found $(echo "$NEW_BRANCHES" | wc -l | tr -d ' ') new build-log branch(es)"

        while IFS= read -r branch; do
            [ -z "$branch" ] && continue
            echo "[poll] Checking branch: $branch"

            # Fetch the branch
            if ! git fetch origin "$branch" 2>/dev/null; then
                echo "[poll]   fetch failed, skipping"
                continue
            fi

            # Read build-summary.md and check for our commit SHA or branch name
            SUMMARY=$(git show "origin/${branch}:build-summary.md" 2>/dev/null || echo "")

            MATCHED=false
            if echo "$SUMMARY" | grep -qi "$COMMIT_SHA"; then
                MATCHED=true
                echo "[poll]   matched on commit SHA"
            elif [ -n "$MATCH_BRANCH" ] && echo "$SUMMARY" | grep -qi "$MATCH_BRANCH"; then
                MATCHED=true
                echo "[poll]   matched on branch name: $MATCH_BRANCH"
            fi

            if [ "$MATCHED" = true ]; then
                echo ""
                echo "[poll] ===== MATCH FOUND ====="
                echo "[poll] Branch: $branch"
                echo "[poll] Commit: $COMMIT_SHA"
                if [ -n "$MATCH_BRANCH" ]; then
                    echo "[poll] Match branch: $MATCH_BRANCH"
                fi

                # Extract result (pass/fail) from branch name
                RESULT=$(echo "$branch" | grep -oE '(pass|fail)$' || echo "unknown")
                echo "[poll] Result: $RESULT"
                echo ""
                echo "--- build-summary.md ---"
                echo "$SUMMARY"
                echo "--- end build-summary.md ---"
                echo ""

                # Also show failing tests / errors if result is fail
                if [ "$RESULT" = "fail" ]; then
                    echo "--- errors from test.log ---"
                    TEST_LOG=$(git show "origin/${branch}:test.log" 2>/dev/null || echo "")
                    if [ -n "$TEST_LOG" ]; then
                        echo "$TEST_LOG" | grep -E '✖︎|error:' || echo "(no error lines found)"
                    else
                        echo "(test.log not available)"
                    fi
                    echo "--- end errors ---"
                fi

                echo ""
                echo "[poll] Build log branch: $branch"
                exit 0
            else
                echo "[poll]   no match, skipping"
            fi
        done <<< "$NEW_BRANCHES"

        # Update snapshot so we don't re-check these branches
        KNOWN_BRANCHES="$CURRENT_BRANCHES"
    else
        echo "[poll] No new branches yet"
    fi

    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

echo ""
echo "[poll] ===== TIMEOUT ====="
echo "[poll] No matching build-log branch found after ${MAX_TIMEOUT}s"
echo "[poll] Commit: ${COMMIT_SHA}"
if [ -n "$MATCH_BRANCH" ]; then
    echo "[poll] Branch: ${MATCH_BRANCH}"
fi
echo "[poll] Check manually: git ls-remote --heads origin 'refs/heads/build-logs/*'"
exit 1
