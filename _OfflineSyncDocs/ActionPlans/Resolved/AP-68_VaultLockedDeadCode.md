# AP-68: `.vaultLocked` Error Case Defined but Never Thrown — Dead Code

> **Issue:** #68 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Resolved (Option B implemented)
> **Source:** ReviewSection_OfflineSyncResolver.md

## Problem Statement

The `OfflineSyncError` enum defines a `.vaultLocked` error case with a user-facing message ("The vault is locked. Please unlock to sync offline changes."), but this case is never thrown anywhere in the current codebase. The vault-locked guard is implemented in `SyncService.fetchSync()` (line 342), where it checks `isVaultLocked` and skips the entire resolution block if the vault is locked — it returns early rather than throwing `.vaultLocked`.

The `.vaultLocked` case appears to be defensive code reserved for potential future use.

## Current Code

- Error definition: `BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift:16-17`
```swift
/// The vault is locked; sync resolution cannot proceed without an active crypto context.
case vaultLocked
```

- Error description: `OfflineSyncResolver.swift:29-30`
```swift
case .vaultLocked:
    "The vault is locked. Please unlock to sync offline changes."
```

- Vault-locked guard (does NOT throw `.vaultLocked`): `SyncService.swift:340-342`
```swift
let isVaultLocked = await vaultTimeoutService.isLocked(userId: userId)
if await configService.getFeatureFlag(.offlineSyncEnableResolution),
   !isVaultLocked {
```

- Test for error description: `OfflineSyncResolverTests.swift` — `test_offlineSyncError_vaultLocked_localizedDescription` verifies the error message

## Assessment

**Still valid.** A grep of the codebase confirms that `.vaultLocked` is referenced in only two places:
1. The `OfflineSyncError` enum definition and `errorDescription` switch case
2. The test that verifies its localized description

It is never instantiated with `throw OfflineSyncError.vaultLocked` anywhere.

**Actual impact:** Minimal. The dead code is 4 lines (2 in the enum, 2 in the switch). It does not affect functionality, performance, or security. The test for the error description provides marginal coverage of unreachable code.

**Hidden risks:** None. The dead code does not introduce any bugs or confusion. It is clearly documented with a DocC comment explaining its purpose.

**Potential future use:** If the resolver were ever called directly (outside the `SyncService.fetchSync()` guard), the `.vaultLocked` case could be thrown by the resolver itself to signal that it cannot proceed. This would make the resolver self-protective rather than relying on the caller to check vault lock status.

## Options

### Option A: Keep As Defensive Code (Recommended)
- **Effort:** None
- **Description:** Keep the `.vaultLocked` case as a defensive error for potential future use. The cost is 4 lines of code.
- **Pros:** Zero effort, provides a well-defined error for a common failure mode, enables future self-protective resolver design
- **Cons:** 4 lines of technically unreachable code

### Option B: Remove Dead Code
- **Effort:** Low (~15 minutes)
- **Description:** Remove the `.vaultLocked` case from `OfflineSyncError` and its associated test.
- **Pros:** Code cleanliness, eliminates dead code
- **Cons:** If the resolver is later enhanced to check vault lock status internally (e.g., as suggested in Issue #65 Option C), the error case would need to be re-added

### Option C: Use It — Add Vault Lock Check to Resolver
- **Effort:** Medium (~1-2 hours)
- **Description:** Move the vault-locked check from `SyncService` into `DefaultOfflineSyncResolver.processPendingChanges()`, making the resolver self-protective. The resolver would throw `.vaultLocked` if the vault is locked.
- **Pros:** Makes the resolver reusable from any caller without requiring external vault-lock checks, justifies the error case
- **Cons:** Requires injecting `VaultTimeoutService` into the resolver (adding a dependency), introduces the `@MainActor` concern from Issue #60

## Recommendation

**Option B: Remove Dead Code.** The `.vaultLocked` case is never thrown and adds cruft. Clean it up along with its associated test to keep the error enum honest. If a self-protective resolver is needed later, the case can be re-added at that time with a concrete caller.

## Dependencies

- Related to Issue #65 (TC-4): `isVaultLocked` caching. Option C of this issue would move the vault lock check into the resolver.
- Related to Issue #60 (TC-5): `@MainActor` annotation. Adding `VaultTimeoutService` to the resolver would inherit the `@MainActor` isolation concerns.
