# Detailed Review: SyncService Offline Integration

## Files Covered

| File | Type | Lines Changed |
|------|------|---------------|
| `BitwardenShared/Core/Vault/Services/SyncService.swift` | Service (modified) | +32 lines |
| `BitwardenShared/Core/Vault/Services/SyncServiceTests.swift` | Tests (modified) | +67 lines |

---

## End-to-End Walkthrough

### 1. New Dependencies Added to `DefaultSyncService`

| Dependency | Type | Purpose |
|------------|------|---------|
| `offlineSyncResolver: OfflineSyncResolver` | Protocol-typed | Resolves pending changes before sync |
| `pendingCipherChangeDataStore: PendingCipherChangeDataStore` | Protocol-typed | Queries pending change count |

Both are injected via the initializer and documented with DocC parameter docs.

### 2. Pre-Sync Resolution Logic in `fetchSync()`

The core change is a block inserted at the top of `fetchSync(forceSync:isPeriodic:)`, just after obtaining the `userId`, before the `needsSync()` check:

**[Updated]** A pre-count check was re-added as an optimization so the common case (no pending changes) skips the resolver entirely. The resolver is only called when pending changes actually exist. Both pre-count and post-resolution count checks use `pendingCipherChangeDataStore.pendingChangeCount(userId:)`.

```swift
// Process any pending offline changes before syncing.
let isVaultLocked = await vaultTimeoutService.isLocked(userId: userId)
if !isVaultLocked {
    let pendingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
    if pendingCount > 0 {
        try await offlineSyncResolver.processPendingChanges(userId: userId)
        let remainingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
        if remainingCount > 0 {
            return   // ← Abort sync to prevent data loss
        }
    }
}
```

**Flow diagram: [Updated]**

```
fetchSync() called
│
├── Get userId from active account
│
├── Check vault lock state
│   └── If locked → skip resolution (can't decrypt/resolve)
│
├── Pre-count check: pendingChangeCount(userId:)
│   └── If 0 → skip resolution entirely (optimization)
│
├── Attempt resolution: offlineSyncResolver.processPendingChanges(userId:)
│
├── Post-resolution count check: pendingChangeCount(userId:)
│   ├── If 0 → continue to normal sync (all resolved)
│   └── If > 0 → ABORT SYNC (return early)
│
└── Continue to normal sync: needsSync check → API call → replace data
```

**Critical Safety Property:** If any pending changes remain after resolution (e.g., the server is still unreachable, or resolution failed for some items), the sync is **aborted entirely**. This prevents `replaceCiphers()` (called later in `fetchSync`) from overwriting locally-stored offline edits with the server's version. Without this guard, a background sync could silently discard the user's offline changes.

### 3. Minor Optimization: Reuse `isVaultLocked`

The diff shows that the `isVaultLocked` variable (computed for the pre-sync check) is reused later in `fetchSync` where the original code called `await vaultTimeoutService.isLocked(userId: userId)` a second time. The original inline call at line 355 is replaced with the captured `isVaultLocked` value, eliminating a redundant async call.

### 4. Whitespace-Only Change

A blank line is added at line 381 (before `try await checkVaultTimeoutPolicy()`). This is cosmetic only.

---

## Test Coverage

### New Tests Added

| Test | Scenario | Verification |
|------|----------|-------------|
| `test_fetchSync_preSyncResolution_triggersPendingChanges` | Pending changes exist → resolve → 0 remaining | Resolver called, sync proceeds (1 API request) |
| `test_fetchSync_preSyncResolution_skipsWhenVaultLocked` | Vault locked + pending changes | Resolver NOT called |
| `test_fetchSync_preSyncResolution_skipsWhenNoPendingChanges` | 0 pending changes | Pre-count check returns 0, resolver NOT called (optimization), sync proceeds normally |
| `test_fetchSync_preSyncResolution_abortsWhenPendingChangesRemain` | Pending changes → resolve → some remaining | Resolver called, sync ABORTED (0 API requests) |

**[Updated]** A pre-count check was re-added as an optimization. The sync flow now calls `pendingChangeCount` twice: once before resolution (to skip the resolver when no pending changes exist) and once after resolution (to determine whether to abort). The `pendingChangeCountResults` sequential-return pattern in `MockPendingCipherChangeDataStore` supports this two-call flow.

---

## Compliance Assessment

### Architecture Compliance

| Guideline | Status | Details |
|-----------|--------|---------|
| Service layer responsibility | **Pass** | `SyncService` orchestrates the sync workflow; resolution logic is delegated to `OfflineSyncResolver` |
| No business logic leakage | **Pass** | Conflict resolution is not in `SyncService`; it only checks count and triggers resolver |
| Protocol-based DI | **Pass** | Both new dependencies injected as protocols |

### Code Style Compliance

| Guideline | Status | Details |
|-----------|--------|---------|
| DocC parameter docs | **Pass** | Both new init parameters documented |
| Comments explain "why" | **Pass** | Comment block explains the abort rationale |
| Guard/early-return pattern | **Pass** | Uses early `return` to abort sync on remaining changes |

### Security Compliance

| Principle | Status | Details |
|-----------|--------|---------|
| Vault lock guard | **Pass** | Resolution skipped when vault is locked (no crypto context available) |
| Data loss prevention | **Pass** | Sync aborted when pending changes remain |

---

## Issues and Observations

### Issue SS-1: Pre-Sync Resolution Error Propagation (Medium)

The `try await offlineSyncResolver.processPendingChanges(userId: userId)` call uses `try`. If the resolver throws an error (e.g., a programming error in the resolver, not a per-item resolution failure), the error propagates up through `fetchSync` and the entire sync fails.

However, `DefaultOfflineSyncResolver.processPendingChanges` internally catches per-item errors and logs them. It would only throw if `pendingCipherChangeDataStore.fetchPendingChanges` fails (Core Data error) or an unexpected error occurs. So in practice, the `try` is correct — if we can't even read the pending changes, the sync should fail rather than potentially overwrite data.

### Issue SS-2: Race Condition Between Count Check and Sync (Low)

There's a theoretical time-of-check-time-of-use (TOCTOU) gap between checking `remainingCount` and proceeding to the sync API call. If a new offline change is queued between these two points (e.g., by another async task), the sync could proceed and overwrite it.

**Mitigation:** In practice, `fetchSync` is called from a serial context (the sync workflow), and user operations that queue pending changes go through `VaultRepository` methods which are separate async flows. The risk is very low.

### Issue SS-3: Abort Sync is Silent (Low)

When the sync is aborted due to remaining pending changes, the method returns silently (`return`). There's no logging, no error, and no notification to the caller. The caller (`AppProcessor` or any sync trigger) has no way to know whether the sync succeeded, was skipped due to `needsSync`, or was aborted due to pending changes.

**Recommendation:** Add a `Logger.application.info()` log line when aborting to aid debugging in production.

### Issue SS-4: Full Pre-Sync Resolution On Every Sync Attempt (Low)

Every `fetchSync` call attempts full offline resolution before proceeding. If the resolver fails for some changes (e.g., server returns 500 for a specific cipher), these will be retried on every subsequent sync attempt, which may be frequent (triggered by connectivity changes, app foregrounding, etc.).

**Assessment:** This is acceptable behavior. The resolver's per-item error handling (catch-and-continue) means failed items don't block resolution of other items. The retry overhead is minimal (count check + failed API calls for the remaining items).

### Observation SS-5: No Retry Backoff for Failed Resolution Items

Failed resolution items are retried on the next sync with no backoff. If a specific cipher consistently fails to resolve (e.g., server returns 404 because it was deleted via another device), the resolver will attempt it every sync indefinitely.

**Possible improvement:** Add a retry count or timestamp to `PendingCipherChangeData` and skip/expire items that have failed too many times or are too old. This would prevent perpetual retry loops. However, for the initial implementation, the current approach is simpler and the impact is limited to extra API calls.
