---
id: 17
title: "[R2-SS-6] Pre-sync resolution extraction — 8 lines of actual code, well-commented"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

Pre-sync resolution extraction suggestion. Block is only 8 lines of actual code and well-commented — accepted as-is.

**Disposition:** Accepted
**Action Plan:** AP-73 (Accepted)

**Related Documents:** Review2

## Action Plan

*Source: `ActionPlans/Accepted/AP-73_PreSyncResolutionExtraction.md`*

> **Issue:** #73 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/04_SyncService_Review.md

## Problem Statement

The review (R2-SS-6) suggests extracting the 15-line pre-sync resolution block in `SyncService.fetchSync(forceSync:isPeriodic:)` into a private method such as `resolveOfflineChangesIfNeeded(userId:isVaultLocked:) -> Bool`. This would improve readability by separating the offline resolution concern from the main sync flow.

## Current Code

`BitwardenShared/Core/Vault/Services/SyncService.swift:329-351`:
```swift
// Resolve any pending offline changes before syncing. If pending changes
// remain after resolution, abort to prevent replaceCiphers from overwriting
// local offline edits. Resolution is skipped when the vault is locked since
// the SDK crypto context is needed for conflict resolution.
//
// The enableOfflineSyncResolution flag controls whether this entire block
// runs. When disabled, resolution is skipped and replaceCiphers proceeds
// normally — pending change records stay in the database for future
// resolution when the flag is re-enabled. The offlineSync flag (which gates
// new offline saves in VaultRepository) is also implicitly disabled when
// resolution is off, so no new pending changes accumulate.
let isVaultLocked = await vaultTimeoutService.isLocked(userId: userId)
if await configService.getFeatureFlag(.offlineSyncEnableResolution),
   !isVaultLocked {
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

The `fetchSync` method is in an extension on `DefaultSyncService` (line 324). The `isVaultLocked` variable is reused later at line 367 for `initializeOrganizationCrypto`.

## Assessment

**This issue is valid but the benefit is marginal.** The pre-sync resolution block is self-contained and well-commented. Extracting it would:

1. **Improve readability** of the `fetchSync` method by reducing its length and nesting.
2. **Encapsulate** the offline resolution concern behind a named method.
3. **Allow reuse** if a future code path also needs pre-sync resolution.

However:
1. The block is only 8 lines of actual code (the rest is the comment explaining the feature flag behavior, which should remain near the logic it describes).
2. The `isVaultLocked` variable is computed here but reused later in `fetchSync`, so the extraction would either need to return both a boolean and the locked state, or the locked state would need to be computed separately.
3. The `return` statement inside the block exits `fetchSync` entirely, which would need to become a return value from the helper method that the caller checks.

## Options

### Option A: Extract with Boolean Return
- **Effort:** ~30 minutes, ~20 lines modified in 1 file
- **Description:** Create a private method:
  ```swift
  /// Resolves pending offline changes if any exist and the vault is unlocked.
  ///
  /// - Parameters:
  ///   - userId: The user ID.
  ///   - isVaultLocked: Whether the vault is currently locked.
  /// - Returns: `true` if sync should proceed, `false` if sync should be aborted
  ///   due to unresolved pending changes.
  ///
  private func resolveOfflineChangesIfNeeded(
      userId: String,
      isVaultLocked: Bool
  ) async throws -> Bool {
      guard await configService.getFeatureFlag(.offlineSyncEnableResolution),
            !isVaultLocked else {
          return true
      }
      let pendingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
      guard pendingCount > 0 else { return true }
      try await offlineSyncResolver.processPendingChanges(userId: userId)
      let remainingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
      return remainingCount == 0
  }
  ```
  The call site would be:
  ```swift
  let isVaultLocked = await vaultTimeoutService.isLocked(userId: userId)
  guard try await resolveOfflineChangesIfNeeded(userId: userId, isVaultLocked: isVaultLocked) else {
      return
  }
  ```
- **Pros:** Cleaner `fetchSync` method; named method conveys intent; encapsulates the feature flag check, count checks, and resolution
- **Cons:** The detailed block comment about feature flag behavior would either move to the helper (losing proximity to `fetchSync`) or be split between both locations; minor indirection

### Option B: Accept As-Is (Recommended)
- **Rationale:** The block is well-commented, self-contained, and only 8 lines of actual code. The `fetchSync` method is not excessively long. Extracting would create indirection for a block that appears exactly once and whose behavior is best understood inline alongside the rest of the sync flow. The detailed comment about feature flag behavior is most useful right where the logic lives.

## Recommendation

**Option B: Accept As-Is.** The pre-sync resolution block is well-commented and only appears once. The inline placement makes the sync flow's behavior immediately clear without having to navigate to a separate method. If the `fetchSync` method grows significantly in the future, Option A would be a reasonable refactoring step.

If Option A is implemented, the detailed block comment about feature flag behavior should be preserved in the DocC documentation of the new helper method.

## Dependencies

- Related to Issue #72 (replacing two `pendingChangeCount` calls with resolver boolean return) -- if both are implemented, they should be coordinated. Implementing both would produce a minimal `resolveOfflineChangesIfNeeded` method.

## Comments
