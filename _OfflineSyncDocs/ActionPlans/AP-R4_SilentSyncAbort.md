# Action Plan: R4 (SS-3) — Silent Sync Abort (No Logging)

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | R4 / SS-3 |
| **Component** | `SyncService` |
| **Severity** | Low |
| **Type** | Observability |
| **File** | `BitwardenShared/Core/Vault/Services/SyncService.swift` |

## Description

When `SyncService.fetchSync()` aborts the sync due to remaining pending offline changes (after resolution attempt), the method returns silently (`return`) with no logging. The caller has no way to distinguish between a successful sync, a skipped sync (no changes needed), or an aborted sync (pending changes remain). This makes production debugging difficult.

---

## Options

### Option A: Add Logger.application.info() on Abort (Recommended)

Add a log line before the early return when pending changes remain.

**Approach (at `SyncService.swift` line ~339, before `return`):**
```swift
if remainingCount > 0 {
    Logger.application.info(
        "Sync aborted: \(remainingCount) pending offline changes remain unresolved"
    )
    return
}
```

**Codebase precedent:** `Logger.application` is already used in 22+ files. The resolver itself logs errors at `OfflineSyncResolver.swift:132` using `Logger.application.error()`. This would add a complementary `.info()` level log at the sync orchestration layer.

**Pros:**
- Minimal change — one line added at the existing `return` statement in `SyncService.swift:339`
- Provides visibility into sync behavior in production logs
- Uses existing `Logger.application` infrastructure (OSLog-based, zero setup)
- Aids debugging without changing behavior
- Complements the existing error-level logging in the resolver

**Cons:**
- Log line could be noisy if the user is offline for an extended period (logged on every sync attempt)
- No user-visible indication (just internal logging)

### Option B: Add Logging at Multiple Points

Add logging at all the decision points in the pre-sync resolution flow:
1. "Vault locked, skipping offline resolution"
2. "No pending changes, proceeding to sync"
3. "Resolving N pending offline changes"
4. "Resolution complete, M of N changes remain"
5. "Sync aborted: M pending changes remain"

**Pros:**
- Full observability of the pre-sync decision flow
- Makes it easy to trace the exact path taken
- Useful for debugging complex scenarios

**Cons:**
- 5 log lines added — more verbose
- Some may be too noisy for normal operation
- Log level selection matters: `info` vs `debug` vs `warning`

### Option C: Return a Status Enum from fetchSync

Change `fetchSync` to return a status enum indicating the outcome:
```swift
enum SyncResult {
    case completed
    case skipped
    case abortedPendingChanges(remaining: Int)
}
```

**Pros:**
- Callers can react to the outcome programmatically
- Type-safe indication of what happened
- Could enable UI notifications (ties into U3)

**Cons:**
- API change — all callers of `fetchSync` must handle the return value
- More invasive change than just logging
- Current callers likely don't need this information

---

## Recommendation

**Option A** — Add a single `Logger.application.info()` log line when sync is aborted. This is the minimum viable improvement for observability with zero risk of behavioral change. If more detailed logging is needed during debugging, Option B can be considered.

## Estimated Impact

- **Files changed:** 1 (`SyncService.swift`)
- **Lines added:** 1-2
- **Risk:** None — logging only

## Related Issues

- **R3 (SS-5)**: Retry backoff — if retry backoff causes items to be skipped or expired, those events should also be logged.
- **S8**: Feature flag — when a feature flag controls offline sync behavior, logging the flag state during sync decisions is valuable.
- **U3 (VR-4)**: Pending changes indicator — Option C (return status) could be the foundation for a user-visible indicator.
- **T8 (SS-1)**: Hard error in pre-sync resolution — logging should distinguish between "aborted due to remaining items" and "failed due to error."

## Updated Review Findings

The review confirms the original assessment. After reviewing the implementation:

1. **Code verification**: `SyncService.swift:338-340` shows:
   ```swift
   if remainingCount > 0 {
       return
   }
   ```
   No logging, no notification, just a bare `return`. This makes it impossible to distinguish between "sync completed normally", "sync was skipped because nothing changed", and "sync was aborted due to pending changes" from logs alone.

2. **Existing logging patterns**: The resolver already logs at `OfflineSyncResolver.swift:132-134` with `Logger.application.error()`. Adding a `.info()` level log at the SyncService abort point follows the established pattern and provides the orchestration-level counterpart.

3. **Logger import**: `SyncService.swift` imports `OSLog` (confirmed by reviewing imports). `Logger.application` is available.

4. **Proposed insertion point**: The log should be added immediately before the `return` at line 339:
   ```swift
   if remainingCount > 0 {
       Logger.application.info("SyncService: Sync aborted — \(remainingCount) pending offline changes remain unresolved")
       return
   }
   ```

**Updated conclusion**: Original recommendation (Option A - single log line) confirmed. This is a trivial 1-line addition with zero risk and significant debugging value. Priority: Low but should be implemented as part of any commit touching SyncService.
