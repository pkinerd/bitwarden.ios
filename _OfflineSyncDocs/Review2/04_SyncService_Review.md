# Review: SyncService Integration

## Files Reviewed

| File | Status | Lines Changed |
|------|--------|--------------|
| `BitwardenShared/Core/Vault/Services/SyncService.swift` | Modified | +33/-3 |
| `BitwardenShared/Core/Vault/Services/SyncServiceTests.swift` | Modified | +90 |

## Overview

The `SyncService` is modified to resolve pending offline changes before performing a full vault sync. This is the critical integration point that ensures offline edits are pushed to the server before the full sync overwrites local data with server state.

## Architecture Compliance

### Service Layer (Architecture.md)

- **Compliant**: `SyncService` remains a service with its existing responsibility (managing vault sync). The offline resolution is invoked as a pre-sync step, maintaining the service's coherent responsibility.
- **Compliant**: New dependencies (`offlineSyncResolver`, `pendingCipherChangeDataStore`) are injected through the initializer with proper DocC documentation.

## Code Change Walkthrough

### New Dependencies — Lines 155-170

```swift
private let offlineSyncResolver: OfflineSyncResolver
private let pendingCipherChangeDataStore: PendingCipherChangeDataStore
```

Added to the service's private properties and initializer.

### Pre-sync Resolution — Lines 326-347

```swift
let isVaultLocked = await vaultTimeoutService.isLocked(userId: userId)
if !isVaultLocked {
    let pendingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
    if pendingCount > 0 {
        try await offlineSyncResolver.processPendingChanges(userId: userId)
        let remainingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
        if remainingCount > 0 {
            return
        }
    }
}
```

**Assessment**:

1. **Vault lock check**: Resolution is skipped when the vault is locked since the SDK crypto context is needed for conflict resolution (decrypting ciphers). This is correct — without the crypto context, the resolver can't compare cipher contents or create backups.

2. **Count-then-process pattern**: The code first checks if there are any pending changes before invoking the resolver. This avoids unnecessary work when there are no offline changes, which is the common case.

3. **Abort-on-remaining pattern**: After resolution, the code checks if any pending changes remain. If they do (i.e., some resolutions failed due to network errors), the full sync is aborted. This is critical — if `replaceCiphers` runs with unresolved pending changes, it would overwrite the local offline edits with server state, losing user data.

4. **Silent abort concern**: When the sync aborts because pending changes remain, the method simply `return`s without logging or notifying. The caller (`needsSync` flow) won't know that sync was skipped. This is documented in `AP-R4_SilentSyncAbort.md`. For a production feature, telemetry or user notification should be considered.

### Reuse of `isVaultLocked` — Line 356-379

```swift
if !isVaultLocked {
    try await organizationService.initializeOrganizationCrypto(...)
}
```

The `isVaultLocked` variable is now computed once at the beginning of `_syncAccountData` and reused later where it was previously called inline (`await !vaultTimeoutService.isLocked(userId:)`). This is a minor refactor that avoids a redundant async call.

### Typo fix — Line 429

```swift
// If the local data is more recent than the notification, skip the sync.
```

Changed "nofication" to "notification" — a minor upstream-style typo fix included in the offline sync changes.

## Security Assessment

- **Compliant**: The pre-sync resolution uses the same `offlineSyncResolver` that operates within the existing security boundaries. No new security surface is introduced.
- **Good**: The vault lock check prevents resolution when crypto context is unavailable, which could otherwise cause decryption failures.

## Data Safety (User Data Loss Prevention)

This is the **most critical data safety mechanism** in the entire offline sync feature:

- **The abort-on-remaining-changes pattern prevents data loss**: If `replaceCiphers` (called later in `_syncAccountData`) ran while there were unresolved pending changes, it would replace ALL local ciphers with server state. Any offline edits that hadn't been synced would be permanently lost.
- **By returning early, the sync is deferred** until the pending changes can be fully resolved. The user's offline edits remain safely in local storage.
- **Trade-off**: This means the vault may be slightly stale (not receiving server updates) while there are unresolved pending changes. For a password manager, this trade-off (stale vault over lost edits) is strongly preferred.

## Reliability Concerns

1. **Silent sync abort**: As noted, the sync silently aborts when pending changes remain. The user has no visibility into why their vault isn't updating. For a production feature, consider:
   - Logging the abort reason
   - Showing a UI indicator that sync is paused due to pending changes
   - Reporting telemetry

2. **Error propagation from resolver**: If `offlineSyncResolver.processPendingChanges()` throws an error (not caught by the per-change error handling inside the resolver), the entire `_syncAccountData` method will throw, potentially preventing sync entirely. However, the resolver's `processPendingChanges` is designed to catch per-change errors internally, so a top-level throw from it indicates a more severe issue (e.g., Core Data failure).

3. **Locked vault timing**: The `isVaultLocked` check happens at the beginning of sync. If the vault locks during sync (e.g., timeout), the resolution may have already started and could encounter crypto errors. However, the resolver processes changes in the actor's serialized context, so this race is unlikely.

## Test Coverage

The `SyncServiceTests.swift` adds 90 lines of test coverage:

- Sync with pending changes: resolution runs, then full sync proceeds
- Sync with remaining changes after resolution: sync aborts
- Sync with locked vault: resolution skipped, sync proceeds normally
- Sync with no pending changes: normal sync flow

**Assessment**: Key scenarios are well covered. The tests use `MockOfflineSyncResolver` and `MockPendingCipherChangeDataStore` to control the resolution outcome.

## Cross-Component Dependencies

The sync service now depends on:
- `OfflineSyncResolver` — new dependency
- `PendingCipherChangeDataStore` — new dependency

Both are within the Vault domain, so no cross-domain coupling is introduced. The sync service already depended on `CipherService` and `VaultTimeoutService`, so the new dependencies are natural extensions.

## Simplification Opportunities

1. **Combine count checks**: The two `pendingChangeCount` calls (before and after resolution) could be replaced by having the resolver return a boolean indicating whether all changes were resolved. This would save one Core Data query. However, the current approach is more robust (it checks actual state rather than trusting the resolver's return value).

2. **The pre-sync block could be extracted**: The 15-line pre-sync resolution block could be extracted into a private method like `resolveOfflineChangesIfNeeded(userId:isVaultLocked:) -> Bool` for clarity.

## Summary

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Architecture compliance | **Good** | Natural extension of sync service |
| Data safety | **Critical — Good** | Abort pattern prevents replaceCiphers from overwriting offline edits |
| Security | **Good** | Vault lock check prevents crypto errors |
| Code style | **Good** | Clean integration, proper documentation |
| Reliability | **Adequate** | Silent abort could confuse users |
| Test coverage | **Good** | Key scenarios covered |
