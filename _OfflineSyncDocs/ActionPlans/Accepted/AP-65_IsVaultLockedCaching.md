# AP-65: `isVaultLocked` Value Is Cached and Reused Across Potentially Long-Running API Calls

> **Issue:** #65 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** ReviewSection_TestChanges.md (Deep Dive 4)

## Problem Statement

In `DefaultSyncService.fetchSync()`, the vault lock status is checked once at the beginning of the method and stored in a local variable `isVaultLocked`. This cached value is then used in two places:

1. To decide whether to run the pre-sync resolution block (line 342)
2. To decide whether to initialize organization crypto (line 367)

Between these two usages, several potentially long-running operations may occur: pending change resolution (involving multiple API calls), the `needsSync` check, and the `syncAPIService.getSync()` API call. The vault could theoretically lock during these operations (e.g., due to a vault timeout), making the cached value stale.

## Current Code

- `BitwardenShared/Core/Vault/Services/SyncService.swift:340-367`
```swift
let isVaultLocked = await vaultTimeoutService.isLocked(userId: userId)
if await configService.getFeatureFlag(.offlineSyncEnableResolution),
   !isVaultLocked {
    let pendingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
    if pendingCount > 0 {
        try await offlineSyncResolver.processPendingChanges(userId: userId)
        // ... potentially long-running operations ...
    }
}

// ... needsSync check, API call ...

if let organizations = response.profile?.organizations {
    if !isVaultLocked {
        try await organizationService.initializeOrganizationCrypto(...)
    }
    // ...
}
```

## Assessment

**Still valid but consistent with original design.** The pre-existing `fetchSync` method already cached `isVaultLocked` before the offline sync changes. The organization crypto initialization at line 367 was already using the cached value. The offline sync changes add a second usage of the same cached value, which is consistent with the original pattern.

**Actual impact:** Extremely low. For the vault to lock between the initial check and the resolution block, the user would need to trigger a vault timeout during an active sync operation. `VaultTimeoutService.isLocked()` reads from a `CurrentValueSubject` dictionary (a synchronous in-memory read), and the vault locks only on explicit user action or session timeout. The timing window is small.

**If the value becomes stale:**
- If vault locks after the check but before resolution: Resolution will attempt SDK operations that require an unlocked vault. These will fail with SDK errors, which are caught by the per-change error handler in `processPendingChanges`. The pending changes remain for the next sync attempt. No data loss.
- If vault locks after resolution but before organization crypto init: The pre-existing behavior (initializing org crypto with a locked vault) would fail, which was already a risk before offline sync.

**Hidden risks:** None beyond the pre-existing risk in the original code.

## Options

### Option A: Accept As-Is (Recommended)
- **Rationale:** The caching is consistent with the original `fetchSync` implementation. Re-checking the vault lock status mid-method would add overhead and potentially introduce inconsistent behavior (e.g., resolution starts with an unlocked vault, vault locks mid-resolution, and then the method decides to skip org crypto init despite having already performed resolution). The cached-value approach provides a consistent view of the vault state for the duration of the method.

### Option B: Re-Check Before Each Usage
- **Effort:** Low (~5 minutes, 2 lines)
- **Description:** Call `vaultTimeoutService.isLocked(userId: userId)` again before the organization crypto initialization block, instead of reusing the cached value.
- **Pros:** More accurate vault state for later operations
- **Cons:** Inconsistent: resolution may have run with unlocked vault, but org crypto init skipped if vault locked mid-sync. Creates a partially-completed state that is harder to reason about.

### Option C: Add Vault Lock Check Inside Resolver
- **Effort:** Medium (~1-2 hours)
- **Description:** Have the `OfflineSyncResolver` check vault lock status before each individual change resolution, providing more granular protection.
- **Pros:** Most accurate vault state checking
- **Cons:** Requires injecting `VaultTimeoutService` into the resolver, increases coupling, adds the `@MainActor` complication for resolver tests

## Recommendation

**Option A: Accept As-Is.** The cached `isVaultLocked` value is consistent with the pre-existing pattern in `fetchSync()`. Re-checking mid-method would create inconsistent state handling. The risk of vault locking during a sync operation is extremely low, and the failure mode (SDK errors caught by per-change error handler) is safe.

## Dependencies

- Related to Issue #60 (TC-5): The `@MainActor` annotation issue. If the resolver were to check `isLocked` directly, it would inherit the same `@MainActor` isolation concerns.
