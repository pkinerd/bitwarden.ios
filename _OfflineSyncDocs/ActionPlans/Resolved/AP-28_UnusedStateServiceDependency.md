# AP-28: Unused `stateService` Dependency in `DefaultOfflineSyncResolver`

> **Issue:** #28 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Resolved
> **Source:** ReviewSection_OfflineSyncResolver.md, Review2/02_OfflineSyncResolver_Review.md, Review2/00_Main_Review.md

## Problem Statement

The original review identified that `stateService` was injected into `DefaultOfflineSyncResolver` but never referenced in any resolution method. The `userId` is instead passed as a parameter from `SyncService` to `processPendingChanges(userId:)`, making the `stateService` dependency unnecessary. The review estimated a ~4-line cleanup to remove it.

## Current Code

The `DefaultOfflineSyncResolver` at `BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift` has been examined. The current implementation:

- **Does NOT contain `stateService`** in its properties (lines 64-74)
- **Does NOT reference `stateService`** in its initializer (lines 86-96)
- Has only 4 dependencies: `cipherAPIService`, `cipherService`, `clientService`, `pendingCipherChangeDataStore`

The `ServiceContainer.swift` convenience initializer at line 631-636 confirms the wiring:
```swift
let preSyncOfflineSyncResolver = DefaultOfflineSyncResolver(
    cipherAPIService: apiService,
    cipherService: cipherService,
    clientService: clientService,
    pendingCipherChangeDataStore: dataStore,
)
```

No `stateService` is passed.

## Assessment

**This issue has already been resolved.** The `stateService` dependency was removed from `DefaultOfflineSyncResolver` at some point after the initial review. The current code shows only 4 dependencies, all actively used. The grep search for `stateService` in the file returned zero matches.

The review documents note that `timeProvider` was also removed (commit `a52d379`) and `folderService` was removed when the conflict folder feature was eliminated. The `stateService` removal appears to have been part of this same cleanup effort.

## Options

### Option A: Close as Resolved (Recommended)
- **Effort:** None
- **Description:** Mark this issue as resolved. No code changes needed.
- **Pros:** Accurate reflection of current state
- **Cons:** None

## Recommendation

Close this issue as **Resolved**. The `stateService` dependency has already been removed from `DefaultOfflineSyncResolver`. The current implementation has exactly 4 dependencies, all of which are actively used in resolution methods.

## Dependencies

None.
